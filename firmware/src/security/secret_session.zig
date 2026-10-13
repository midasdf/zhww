//! Session-owned backing memory for secret material. A building block, not a claim
//! that existing BIP32/libsecp256k1 stacks or the development CLI are fully erased.
//! Keep the instance at a stable address in Secure SRAM; never copy it by value.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");

pub fn Session(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        memory: [capacity]u8 = @splat(0),
        used: usize = 0,
        active: bool = false,

        pub fn begin(self: *Self) error{AlreadyActive}!void {
            if (self.active) return error.AlreadyActive;
            self.end();
            self.active = true;
        }

        /// Reserved regions start zeroed. Use for seed/passphrase/derivation scratch.
        /// Returned borrows expire at end(); never export them to Non-secure code.
        pub fn reserve(self: *Self, len: usize) error{ Inactive, InvalidLength, Full }![]u8 {
            if (!self.active) return error.Inactive;
            if (len == 0) return error.InvalidLength;
            if (len > capacity - self.used) return error.Full;
            const start = self.used;
            self.used += len;
            return self.memory[start..self.used];
        }

        /// One idempotent transition for cancellation, timeout, entropy/display failure,
        /// successful signing, and shutdown. Wipe capacity, not only the used prefix.
        /// This does not erase compiler spills, registers, C context or caller copies.
        pub fn end(self: *Self) void {
            std.crypto.secureZero(u8, &self.memory);
            self.used = 0;
            self.active = false;
        }
    };
}

test "session termination wipes all backing memory and existing borrows" {
    var s: Session(256) = .{};
    try s.begin();
    const seed = try s.reserve(64);
    @memset(seed, 0xab);
    const scratch = try s.reserve(32);
    @memset(scratch, 0xcd);
    s.memory[255] = 0xef; // unused tail must also be erased
    s.end();
    try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0)), &s.memory);
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), seed);
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(usize, 0), s.used);
    s.end();
    try s.begin();
    try std.testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), try s.reserve(64));
    s.end();
}

test "inactive, repeated begin, zero size and exhausted session fail without overflow" {
    var s: Session(64) = .{};
    try std.testing.expectError(error.Inactive, s.reserve(1));
    try s.begin();
    try std.testing.expectError(error.AlreadyActive, s.begin());
    try std.testing.expectError(error.InvalidLength, s.reserve(0));
    _ = try s.reserve(64);
    try std.testing.expectError(error.Full, s.reserve(std.math.maxInt(usize)));
    try std.testing.expectEqual(@as(usize, 64), s.used);
    s.end();
    try std.testing.expectError(error.Inactive, s.reserve(1));
}
