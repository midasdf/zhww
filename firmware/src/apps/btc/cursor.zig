//! バイト列を順に読むカーソル。Bitcoin のネットワーク直列化（リトルエンディアン +
//! CompactSize）を扱う。

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;

pub const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn remaining(self: Cursor) usize {
        return self.data.len - self.pos;
    }

    pub fn readBytes(self: *Cursor, count: usize) Error![]const u8 {
        if (self.remaining() < count) return error.Truncated;
        const slice = self.data[self.pos .. self.pos + count];
        self.pos += count;
        return slice;
    }

    pub fn readU8(self: *Cursor) Error!u8 {
        const bytes = try self.readBytes(1);
        return bytes[0];
    }

    /// 消費せずに次の 1 バイトを覗く。
    pub fn peekU8(self: Cursor) Error!u8 {
        if (self.remaining() < 1) return error.Truncated;
        return self.data[self.pos];
    }

    pub fn readU16(self: *Cursor) Error!u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], .little);
    }

    pub fn readU32(self: *Cursor) Error!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    pub fn readI32(self: *Cursor) Error!i32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(i32, bytes[0..4], .little);
    }

    pub fn readU64(self: *Cursor) Error!u64 {
        const bytes = try self.readBytes(8);
        return std.mem.readInt(u64, bytes[0..8], .little);
    }

    /// CompactSize（可変長整数）。**非正規な符号化は拒否する**（BIP144 / コンセンサス規則）。
    pub fn readVarInt(self: *Cursor) Error!u64 {
        const prefix = try self.readU8();
        if (prefix < 0xFD) return prefix;

        const value: u64 = switch (prefix) {
            0xFD => try self.readU16(),
            0xFE => try self.readU32(),
            else => try self.readU64(),
        };

        const minimum: u64 = switch (prefix) {
            0xFD => 0xFD,
            0xFE => 0x10000,
            else => 0x100000000,
        };
        if (value < minimum) return error.InvalidEncoding;
        return value;
    }

    /// CompactSize 長のプレフィクス付きバイト列。
    pub fn readVarBytes(self: *Cursor) Error![]const u8 {
        const length = try self.readVarInt();
        if (length > self.remaining()) return error.Truncated;
        return self.readBytes(@intCast(length));
    }
};

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "リトルエンディアンの読み出し" {
    var cursor = Cursor{ .data = &[_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x05, 0x06, 0x07, 0x08,
        0x09, 0x0a, 0x0b, 0x0c,
    } };
    try testing.expectEqual(@as(u32, 0x04030201), try cursor.readU32());
    try testing.expectEqual(@as(u64, 0x0c0b0a0908070605), try cursor.readU64());
    try testing.expectEqual(@as(usize, 0), cursor.remaining());
    try testing.expectError(error.Truncated, cursor.readU8());
}

test "CompactSize の正規形のみ受理する" {
    var single = Cursor{ .data = &[_]u8{0xFC} };
    try testing.expectEqual(@as(u64, 0xFC), try single.readVarInt());

    var two = Cursor{ .data = &[_]u8{ 0xFD, 0xFD, 0x00 } };
    try testing.expectEqual(@as(u64, 0xFD), try two.readVarInt());

    // 0xFD で 0xFC を表すのは非正規
    var non_canonical = Cursor{ .data = &[_]u8{ 0xFD, 0xFC, 0x00 } };
    try testing.expectError(error.InvalidEncoding, non_canonical.readVarInt());

    // 0xFE で 0xFFFF を表すのは非正規
    var non_canonical_4 = Cursor{ .data = &[_]u8{ 0xFE, 0xFF, 0xFF, 0x00, 0x00 } };
    try testing.expectError(error.InvalidEncoding, non_canonical_4.readVarInt());
}

test "可変長バイト列" {
    var cursor = Cursor{ .data = &[_]u8{ 0x03, 0xAA, 0xBB, 0xCC, 0xDD } };
    try testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, try cursor.readVarBytes());
    try testing.expectEqual(@as(u8, 0xDD), try cursor.readU8());

    var too_long = Cursor{ .data = &[_]u8{ 0x05, 0xAA } };
    try testing.expectError(error.Truncated, too_long.readVarBytes());
}
