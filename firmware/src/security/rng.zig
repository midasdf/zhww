//! Bounded, fail-closed entropy interface for a future Secure-world TRNG HAL.
//! Provider must report actual hardware health/ready status; this is NOT a TRNG,
//! entropy estimator or statistical health test. No clock/ADC/PRNG fallback.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");

pub const Error = error{ Unavailable, HealthFailure, Timeout, Latched, InvalidRequest };
pub const Word = union(enum) { not_ready, ready: u32, health_failure };
pub const Source = struct {
    context: *anyopaque,
    /// One NONBLOCKING hardware-status/read operation. Never wait inside the provider.
    read_word: *const fn (*anyopaque) error{Unavailable}!Word,
};
pub const max_bytes = 256;
pub const poll_budget = 1024;

pub const Rng = struct {
    source: Source,
    failed: bool = false,

    /// One hardware fault/timeout makes this instance terminal for the session.
    /// Entire output is erased on every error, including a previously latched fault.
    /// Output is raw provider words in little-endian order; unused trailing bytes
    /// are discarded, not reused. No data is returned before the request is complete.
    pub fn fill(self: *Rng, out: []u8) Error!void {
        errdefer {
            std.crypto.secureZero(u8, out);
            self.failed = true;
        }
        if (self.failed) return error.Latched;
        if (out.len == 0 or out.len > max_bytes) return error.InvalidRequest;
        var offset: usize = 0;
        for (0..poll_budget) |_| {
            switch (try self.source.read_word(self.source.context)) {
                .not_ready => {},
                .health_failure => return error.HealthFailure,
                .ready => |value| {
                    var word: [4]u8 = undefined;
                    defer std.crypto.secureZero(u8, &word);
                    std.mem.writeInt(u32, &word, value, .little);
                    const take = @min(word.len, out.len - offset);
                    @memcpy(out[offset..][0..take], word[0..take]);
                    offset += take;
                    if (offset == out.len) return;
                },
            }
        }
        return error.Timeout;
    }
};

const Mock = struct {
    calls: usize = 0,
    fail_at: ?usize = null,
    unavailable: bool = false,
    stalled: bool = false,
    startup_polls: usize = 0,
    fn read(raw: *anyopaque) error{Unavailable}!Word {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.unavailable) return error.Unavailable;
        if (self.fail_at == self.calls) return .health_failure;
        if (self.stalled or self.calls <= self.startup_polls) return .not_ready;
        return .{ .ready = 0x04030201 };
    }
    fn rng(self: *Mock) Rng {
        return .{ .source = .{ .context = self, .read_word = read } };
    }
};

test "bounded entropy read handles startup and non-word-aligned output" {
    var mock: Mock = .{ .startup_polls = 3 };
    var rng = mock.rng();
    var out: [7]u8 = undefined;
    try rng.fill(&out);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 1, 2, 3 }, &out);
    try std.testing.expectEqual(@as(usize, 5), mock.calls);
    try std.testing.expect(!rng.failed);
}

test "partial entropy health failure erases entire output and latches" {
    var mock: Mock = .{ .fail_at = 2 };
    var rng = mock.rng();
    var out: [32]u8 = @splat(0xff);
    try std.testing.expectError(error.HealthFailure, rng.fill(&out));
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &out);
    @memset(&out, 0xff);
    try std.testing.expectError(error.Latched, rng.fill(&out));
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &out);
}

test "unavailable and stalled sources never fall back and wipe output" {
    for ([_]bool{ false, true }) |stalled| {
        var mock: Mock = .{ .stalled = stalled, .unavailable = !stalled };
        var rng = mock.rng();
        var out: [32]u8 = @splat(0xff);
        if (stalled) try std.testing.expectError(error.Timeout, rng.fill(&out)) else try std.testing.expectError(error.Unavailable, rng.fill(&out));
        try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &out);
        try std.testing.expectEqual(if (stalled) poll_budget else @as(usize, 1), mock.calls);
    }
}

test "invalid entropy lengths fail before any provider read" {
    var mock: Mock = .{};
    var rng = mock.rng();
    var out: [max_bytes + 1]u8 = @splat(0xff);
    try std.testing.expectError(error.InvalidRequest, rng.fill(&out));
    try std.testing.expectEqualSlices(u8, &@as([max_bytes + 1]u8, @splat(0)), &out);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    rng = mock.rng();
    try std.testing.expectError(error.InvalidRequest, rng.fill(out[0..0]));
}
