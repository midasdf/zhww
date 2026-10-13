//! Host-testable orchestration prototype for a future Secure-world entry point.
//! NOT a secure gateway, target main loop, or replacement for the existing CLI.
//! Production must collect boot evidence, seed and GPIO events inside Secure world.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const boot = @import("boot_policy.zig");
const approval = @import("approval.zig");
const secrets = @import("secret_session.zig");

pub fn SigningSession(comptime request_capacity: usize, comptime max_pages: usize) type {
    return struct {
        const Self = @This();
        gate: approval.Gate(request_capacity, max_pages) = .{},
        secret: secrets.Session(64) = .{},
        ready: bool = false,

        /// Own a BIP39 seed for exactly one signing attempt. The caller must separately
        /// erase the input and all BIP39/KDF temporaries. Failed begin also aborts.
        pub fn begin(self: *Self, evidence: boot.Evidence, seed: *const [64]u8, request: []const u8, pages: []const []const u8, now: u64) !void {
            errdefer self.abort();
            if (self.ready or self.gate.state == .fault) return error.InvalidState;
            try boot.validate(evidence);
            try self.secret.begin();
            @memcpy(try self.secret.reserve(64), seed);
            try self.gate.prepare(request, pages, now);
            self.ready = true;
        }

        pub fn displayed(self: *Self, index: usize, rendered: []const u8, now: u64) !void {
            errdefer self.abort();
            if (!self.ready) return error.InvalidState;
            try self.gate.displayed(index, rendered, now);
        }

        pub fn button(self: *Self, down: bool, now: u64) !void {
            errdefer self.abort();
            if (!self.ready) return error.InvalidState;
            try self.gate.button(down, now);
        }

        pub fn poll(self: *Self, now: u64) !void {
            errdefer self.abort();
            if (!self.ready) return error.InvalidState;
            try self.gate.poll(now);
        }

        /// Signer is TRUSTED code. It must parse the owned request, enforce supported
        /// sighash/network policy, verify signatures and erase all derived/C secrets.
        /// It must not retain request/seed borrows or publish partial output on error.
        /// Callback is never called before approval; all exits wipe the owned session.
        pub fn sign(self: *Self, request: []const u8, now: u64, signer: anytype) !void {
            defer self.abort();
            if (!self.ready) return error.InvalidState;
            const owned = try self.gate.consume(request, now);
            try signer.sign(owned, self.secret.memory[0..64]);
        }

        /// Call on card removal, renderer/I/O failure, periodic timeout or shutdown.
        /// Aborted instances are terminal; create a new zeroed instance for a new session.
        pub fn abort(self: *Self) void {
            self.gate.invalidate();
            self.secret.end();
            self.ready = false;
        }
    };
}

const TestSession = SigningSession(128, 4);
const MockSigner = struct {
    calls: usize = 0,
    fail: bool = false,
    pub fn sign(self: *@This(), request: []const u8, seed: []const u8) !void {
        self.calls += 1;
        try std.testing.expectEqualStrings("psbt", request);
        try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0xab)), seed);
        if (self.fail) return error.SigningFailed;
    }
};
fn fixtureEvidence() boot.Evidence {
    var e: boot.Evidence = .{ .stepping = .a4 };
    inline for (comptime std.meta.fieldNames(boot.Evidence)) |name| {
        if (@TypeOf(@field(e, name)) == bool) @field(e, name) = true;
    }
    return e;
}
fn begin(s: *TestSession) !void {
    try s.begin(fixtureEvidence(), &@as([64]u8, @splat(0xab)), "psbt", &.{ "destination", "fee" }, 0);
}
fn approve(s: *TestSession) !void {
    try s.displayed(0, "destination", 1);
    try s.displayed(1, "fee", 2);
    try s.button(false, 3);
    try s.button(true, 4);
    try s.button(false, 1004);
}
fn expectWiped(s: *TestSession) !void {
    try std.testing.expect(!s.ready);
    try std.testing.expectEqual(approval.State.fault, s.gate.state);
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &s.secret.memory);
    try std.testing.expectEqualSlices(u8, &@as([128]u8, @splat(0)), &s.gate.request);
}

test "callback called once only after approval and all owned secrets erased" {
    for ([_]bool{ false, true }) |fail| {
        var s: TestSession = .{};
        var signer: MockSigner = .{ .fail = fail };
        try begin(&s);
        try approve(&s);
        if (fail) try std.testing.expectError(error.SigningFailed, s.sign("psbt", 1005, &signer)) else try s.sign("psbt", 1005, &signer);
        try std.testing.expectEqual(@as(usize, 1), signer.calls);
        try expectWiped(&s);
        try std.testing.expectError(error.InvalidState, s.sign("psbt", 1006, &signer));
        try std.testing.expectEqual(@as(usize, 1), signer.calls);
    }
}

test "unapproved, modified request, timeout, cancellation never invoke signer" {
    for (0..4) |scenario| {
        var s: TestSession = .{};
        var signer: MockSigner = .{};
        try begin(&s);
        if (scenario != 0) try approve(&s);
        switch (scenario) {
            0 => try std.testing.expectError(error.InvalidState, s.sign("psbt", 5, &signer)),
            1 => try std.testing.expectError(error.RequestMismatch, s.sign("evil", 1005, &signer)),
            2 => try std.testing.expectError(error.Timeout, s.sign("psbt", 120000, &signer)),
            else => {
                s.abort();
                try std.testing.expectError(error.InvalidState, s.sign("psbt", 1005, &signer));
            },
        }
        try std.testing.expectEqual(@as(usize, 0), signer.calls);
        try expectWiped(&s);
    }
}

test "periodic polling erases abandoned sessions without user interaction" {
    var s: TestSession = .{};
    try begin(&s);
    try s.poll(119999);
    try std.testing.expectError(error.Timeout, s.poll(120000));
    try expectWiped(&s);
}

test "bad boot evidence and display failures wipe without signing" {
    var s: TestSession = .{};
    try std.testing.expectError(error.UnsupportedSilicon, s.begin(.{}, &@as([64]u8, @splat(0xab)), "psbt", &.{"page"}, 0));
    try expectWiped(&s);
    s = .{};
    try begin(&s);
    try std.testing.expectError(error.DisplayMismatch, s.displayed(0, "evil", 1));
    try expectWiped(&s);
}
