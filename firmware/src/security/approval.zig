//! Secure-world approval logic prototype. Not wired to the CLI signing APIs.
//! All calls must originate in trusted code; Zig visibility is NOT a TrustZone boundary.
//! Renderer acknowledges a page only after successful physical display transfer.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{ InvalidState, InvalidRequest, DisplayMismatch, Timeout, ClockRollback, RequestMismatch };
pub const State = enum { idle, reviewing, waiting_release, armed, holding, approved, consumed, fault };
pub const hold_ms: u64 = 1000;
pub const review_timeout_ms: u64 = 120_000;

/// Fixed capacity, owned request bytes. No external slices survive preparation.
/// Page commitments bind exact rendered-page bytes; the trusted renderer must ensure
/// those bytes include every destination, amount, fee, chain/network and warning.
pub fn Gate(comptime capacity: usize, comptime max_pages: usize) type {
    return struct {
        const Self = @This();
        state: State = .idle,
        request: [capacity]u8 = @splat(0),
        request_len: usize = 0,
        request_hash: [32]u8 = @splat(0),
        page_hashes: [max_pages][32]u8 = undefined,
        page_count: usize = 0,
        next_page: usize = 0,
        started_at: u64 = 0,
        last_at: u64 = 0,
        pressed_at: u64 = 0,

        pub fn prepare(self: *Self, bytes: []const u8, pages: []const []const u8, now: u64) Error!void {
            if (self.state != .idle and self.state != .consumed) return error.InvalidState;
            if (bytes.len == 0 or bytes.len > capacity or pages.len == 0 or pages.len > max_pages)
                return error.InvalidRequest;
            for (pages) |page| if (page.len == 0) return error.InvalidRequest;
            self.wipe();
            @memcpy(self.request[0..bytes.len], bytes);
            self.request_len = bytes.len;
            self.request_hash = commitment("zhww-request-v1", bytes);
            for (pages, 0..) |page, i| self.page_hashes[i] = commitment("zhww-page-v1", page);
            self.page_count = pages.len;
            self.next_page = 0;
            self.started_at = now;
            self.last_at = now;
            self.state = .reviewing;
        }

        /// Strictly sequential traversal: duplicate/skipped/stale page receipts fault the gate.
        pub fn displayed(self: *Self, index: usize, rendered: []const u8, now: u64) Error!void {
            try self.tick(now);
            if (self.state != .reviewing) return self.fail(error.InvalidState);
            if (index != self.next_page or index >= self.page_count or
                !equal(commitment("zhww-page-v1", rendered), self.page_hashes[index]))
                return self.fail(error.DisplayMismatch);
            self.next_page += 1;
            if (self.next_page == self.page_count) self.state = .waiting_release;
        }

        /// Debounced GPIO sample from Secure-world HAL, never from transport/NS code.
        /// A held button during review cannot approve: release then a fresh press is required.
        /// Approval occurs on release after holding, not while still pressed.
        pub fn button(self: *Self, down: bool, now: u64) Error!void {
            try self.tick(now);
            switch (self.state) {
                .reviewing => {},
                .waiting_release => if (!down) {
                    self.state = .armed;
                },
                .armed => if (down) {
                    self.pressed_at = now;
                    self.state = .holding;
                },
                .holding => if (!down) {
                    self.state = if (now - self.pressed_at >= hold_ms) .approved else .armed;
                },
                else => return self.fail(error.InvalidState),
            }
        }

        /// Re-check exact input at the signing boundary; consume BEFORE any signing starts.
        /// Caller must sign the owned bytes, never re-read the card. One consume per request.
        /// A failed signature still consumes approval. No public approval token can be replayed.
        pub fn consume(self: *Self, bytes: []const u8, now: u64) Error![]const u8 {
            try self.tick(now);
            if (self.state != .approved) return self.fail(error.InvalidState);
            if (!equal(commitment("zhww-request-v1", bytes), self.request_hash) or
                !equal(commitment("zhww-request-v1", self.request[0..self.request_len]), self.request_hash))
                return self.fail(error.RequestMismatch);
            self.state = .consumed;
            return self.request[0..self.request_len];
        }

        /// Call periodically even with no button/display events.
        pub fn poll(self: *Self, now: u64) Error!void {
            if (self.state == .idle or self.state == .consumed or self.state == .fault)
                return error.InvalidState;
            try self.tick(now);
        }

        /// Cancel, media removal, display failure, session end or watchdog fault.
        /// Parent must also wipe its secret session. Fault is terminal for this instance.
        pub fn invalidate(self: *Self) void {
            self.wipe();
            self.state = .fault;
        }

        fn fail(self: *Self, err: Error) Error {
            self.invalidate();
            return err;
        }

        fn tick(self: *Self, now: u64) Error!void {
            if (now < self.last_at) return self.fail(error.ClockRollback);
            self.last_at = now;
            if (now - self.started_at >= review_timeout_ms) return self.fail(error.Timeout);
        }

        fn wipe(self: *Self) void {
            std.crypto.secureZero(u8, &self.request);
            std.crypto.secureZero(u8, &self.request_hash);
            for (&self.page_hashes) |*page| std.crypto.secureZero(u8, page);
            self.request_len = 0;
            self.page_count = 0;
            self.next_page = 0;
            self.pressed_at = 0;
        }
    };
}

fn commitment(domain: []const u8, bytes: []const u8) [32]u8 {
    var h = Sha256.init(.{});
    h.update(domain);
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, @intCast(bytes.len), .little);
    h.update(&length);
    h.update(bytes);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn equal(a: [32]u8, b: [32]u8) bool {
    return std.crypto.timing_safe.eql([32]u8, a, b);
}

const TestGate = Gate(128, 4);
fn reviewed(g: *TestGate) !void {
    try g.prepare("psbt", &.{ "destination", "fee" }, 10);
    try g.displayed(0, "destination", 11);
    try g.displayed(1, "fee", 12);
}
fn approved(g: *TestGate) !void {
    try reviewed(g);
    try g.button(false, 13);
    try g.button(true, 14);
    try g.button(false, 1014);
}

test "complete review, fresh hold and release, exact request, one use" {
    var g: TestGate = .{};
    try approved(&g);
    try std.testing.expectEqualStrings("psbt", try g.consume("psbt", 1015));
    try std.testing.expectError(error.InvalidState, g.consume("psbt", 1016));
    try std.testing.expectEqual(State.fault, g.state);
    try std.testing.expectEqualSlices(u8, &@as([128]u8, @splat(0)), &g.request);
}

test "skipped, duplicate and modified display pages fail closed" {
    for (0..3) |scenario| {
        var g: TestGate = .{};
        try g.prepare("psbt", &.{ "destination", "fee" }, 10);
        switch (scenario) {
            0 => try std.testing.expectError(error.DisplayMismatch, g.displayed(1, "fee", 11)),
            1 => {
                try g.displayed(0, "destination", 11);
                try std.testing.expectError(error.DisplayMismatch, g.displayed(0, "destination", 12));
            },
            else => try std.testing.expectError(error.DisplayMismatch, g.displayed(0, "fake", 11)),
        }
        try std.testing.expectEqual(State.fault, g.state);
    }
}

test "held button and short press never approve" {
    var g: TestGate = .{};
    try reviewed(&g);
    try g.button(true, 13);
    try g.button(true, 2013);
    try std.testing.expectEqual(State.waiting_release, g.state);
    try g.button(false, 2014);
    try g.button(true, 2015);
    try g.button(false, 3014); // 999ms
    try std.testing.expectEqual(State.armed, g.state);
    try std.testing.expectError(error.InvalidState, g.consume("psbt", 3015));
}

test "external request mutation, owned mutation, and reprepare cannot reuse approval" {
    var g: TestGate = .{};
    try approved(&g);
    try std.testing.expectError(error.InvalidState, g.prepare("evil", &.{"evil"}, 1015));
    try std.testing.expectError(error.RequestMismatch, g.consume("evil", 1016));
    g = .{};
    try approved(&g);
    g.request[0] ^= 1;
    try std.testing.expectError(error.RequestMismatch, g.consume("psbt", 1015));
}

test "timeout, clock rollback and cancellation invalidate approval" {
    var g: TestGate = .{};
    try approved(&g);
    try std.testing.expectError(error.Timeout, g.consume("psbt", 120010));
    g = .{};
    try approved(&g);
    try std.testing.expectError(error.ClockRollback, g.consume("psbt", 1013));
    g = .{};
    try approved(&g);
    g.invalidate();
    try std.testing.expectError(error.InvalidState, g.consume("psbt", 1015));
    try std.testing.expectError(error.InvalidState, g.prepare("psbt", &.{"page"}, 1016));
}

test "preparation owns bytes and rejects empty or oversized material" {
    var g: TestGate = .{};
    try std.testing.expectError(error.InvalidRequest, g.prepare("", &.{"page"}, 0));
    try std.testing.expectError(error.InvalidRequest, g.prepare("psbt", &.{}, 0));
    try std.testing.expectError(error.InvalidRequest, g.prepare("psbt", &.{""}, 0));
    try std.testing.expectError(error.InvalidRequest, g.prepare(&@as([129]u8, @splat(1)), &.{"page"}, 0));
    var bytes = [_]u8{ 'p', 's', 'b', 't' };
    try g.prepare(&bytes, &.{"page"}, 0);
    bytes[0] = 'x';
    try std.testing.expectEqualStrings("psbt", g.request[0..g.request_len]);
}
