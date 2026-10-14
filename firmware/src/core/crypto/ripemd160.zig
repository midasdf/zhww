//! RIPEMD-160 implementation.
//!
//! **Why we need our own implementation**: the Zig standard library has no RIPEMD-160,
//! and a bare-metal target has no OpenSSL to fall back on.
//! Bitcoin address generation and BIP32 fingerprints depend on
//! HASH160 = RIPEMD160(SHA256(x)), so we keep our own implementation that is guaranteed to
//! work on the target environment.
//!
//! It provides a streaming API (init/update/final), so it handles input of any length.
//!
//! Reference: ISO/IEC 10118-3, https://homes.esat.kuleuven.be/~bosselae/ripemd160.html
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");

pub const Ripemd160 = struct {
    pub const block_length = 64;
    pub const digest_length = 20;
    pub const Options = struct {};

    state: [5]u32,
    buf: [block_length]u8,
    buf_len: usize,
    total_len: u64,

    pub fn init(options: Options) Ripemd160 {
        _ = options;
        return .{
            .state = .{ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 },
            .buf = undefined,
            .buf_len = 0,
            .total_len = 0,
        };
    }

    pub fn update(self: *Ripemd160, input: []const u8) void {
        self.total_len +%= input.len;

        var rest = input;
        if (self.buf_len > 0) {
            const need = block_length - self.buf_len;
            if (rest.len < need) {
                @memcpy(self.buf[self.buf_len..][0..rest.len], rest);
                self.buf_len += rest.len;
                return;
            }
            @memcpy(self.buf[self.buf_len..][0..need], rest[0..need]);
            compress(&self.state, &self.buf);
            self.buf_len = 0;
            rest = rest[need..];
        }

        while (rest.len >= block_length) {
            var block: [block_length]u8 = undefined;
            @memcpy(&block, rest[0..block_length]);
            compress(&self.state, &block);
            rest = rest[block_length..];
        }

        if (rest.len > 0) {
            @memcpy(self.buf[0..rest.len], rest);
            self.buf_len = rest.len;
        }
    }

    pub fn final(self: *Ripemd160, out: *[digest_length]u8) void {
        const bit_len = self.total_len *% 8;

        // padding: 0x80, zero fill, little-endian bit length (8 bytes)
        var pad: [72]u8 = @splat(0);
        pad[0] = 0x80;
        const pad_len: usize = if (self.buf_len < 56) 56 - self.buf_len else 120 - self.buf_len;
        std.mem.writeInt(u64, pad[pad_len..][0..8], bit_len, .little);
        self.update(pad[0 .. pad_len + 8]);

        for (0..5) |i| {
            std.mem.writeInt(u32, out[i * 4 ..][0..4], self.state[i], .little);
        }
    }

    /// Same calling convention as std.crypto hashes.
    pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
        var ctx = init(options);
        ctx.update(b);
        ctx.final(out);
    }
};

const k_left = [5]u32{ 0x00000000, 0x5A827999, 0x6ED9EBA1, 0x8F1BBCDC, 0xA953FD4E };
const k_right = [5]u32{ 0x50A28BE6, 0x5C4DD124, 0x6D703EF3, 0x7A6D76E9, 0x00000000 };

const r_left = [80]u8{
    0,  1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15,
    7,  4,  13, 1,  10, 6,  15, 3,  12, 0,  9,  5,  2,  14, 11, 8,
    3,  10, 14, 4,  9,  15, 8,  1,  2,  7,  0,  6,  13, 11, 5,  12,
    1,  9,  11, 10, 0,  8,  12, 4,  13, 3,  7,  15, 14, 5,  6,  2,
    4,  0,  5,  9,  7,  12, 2,  10, 14, 1,  3,  8,  11, 6,  15, 13,
};
const r_right = [80]u8{
    5,  14, 7,  0,  9,  2,  11, 4,  13, 6,  15, 8,  1,  10, 3,  12,
    6,  11, 3,  7,  0,  13, 5,  10, 14, 15, 8,  12, 4,  9,  1,  2,
    15, 5,  1,  3,  7,  14, 6,  9,  11, 8,  12, 2,  10, 0,  4,  13,
    8,  6,  4,  1,  3,  11, 15, 0,  5,  12, 2,  13, 9,  7,  10, 14,
    12, 15, 10, 4,  1,  5,  8,  7,  6,  2,  13, 14, 0,  3,  9,  11,
};
const s_left = [80]u8{
    11, 14, 15, 12, 5,  8,  7,  9,  11, 13, 14, 15, 6,  7,  9,  8,
    7,  6,  8,  13, 11, 9,  7,  15, 7,  12, 15, 9,  11, 7,  13, 12,
    11, 13, 6,  7,  14, 9,  13, 15, 14, 8,  13, 6,  5,  12, 7,  5,
    11, 12, 14, 15, 14, 15, 9,  8,  9,  14, 5,  6,  8,  6,  5,  12,
    9,  15, 5,  11, 6,  8,  13, 12, 5,  12, 13, 14, 11, 8,  5,  6,
};
const s_right = [80]u8{
    8,  9,  9,  11, 13, 15, 15, 5,  7,  7,  8,  11, 14, 14, 12, 6,
    9,  13, 15, 7,  12, 8,  9,  11, 7,  7,  12, 7,  6,  15, 13, 11,
    9,  7,  15, 11, 8,  6,  6,  14, 12, 13, 5,  14, 13, 13, 7,  5,
    15, 5,  8,  11, 14, 14, 6,  14, 6,  9,  12, 9,  12, 5,  15, 8,
    8,  5,  12, 9,  12, 5,  14, 6,  8,  13, 6,  5,  15, 13, 11, 11,
};

inline fn rotateLeft(x: u32, n: u5) u32 {
    return std.math.rotl(u32, x, n);
}

fn f(j: usize, x: u32, y: u32, z: u32) u32 {
    if (j < 16) return x ^ y ^ z;
    if (j < 32) return (x & y) | (~x & z);
    if (j < 48) return (x | ~y) ^ z;
    if (j < 64) return (x & z) | (y & ~z);
    return x ^ (y | ~z);
}

fn compress(state: *[5]u32, block: *const [Ripemd160.block_length]u8) void {
    var x: [16]u32 = undefined;
    for (0..16) |i| {
        x[i] = std.mem.readInt(u32, block[i * 4 ..][0..4], .little);
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var ap = a;
    var bp = b;
    var cp = c;
    var dp = d;
    var ep = e;

    for (0..80) |j| {
        var t = a +% f(j, b, c, d) +% x[r_left[j]] +% k_left[j / 16];
        t = rotateLeft(t, @intCast(s_left[j])) +% e;
        a = e;
        e = d;
        d = rotateLeft(c, 10);
        c = b;
        b = t;

        t = ap +% f(79 - j, bp, cp, dp) +% x[r_right[j]] +% k_right[j / 16];
        t = rotateLeft(t, @intCast(s_right[j])) +% ep;
        ap = ep;
        ep = dp;
        dp = rotateLeft(cp, 10);
        cp = bp;
        bp = t;
    }

    const t = state[1] +% c +% dp;
    state[1] = state[2] +% d +% ep;
    state[2] = state[3] +% e +% ap;
    state[3] = state[4] +% a +% bp;
    state[4] = state[0] +% b +% cp;
    state[0] = t;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn hexToBuf(comptime hex: []const u8) [hex.len / 2]u8 {
    var out: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "official test vectors (ISO/IEC 10118-3)" {
    const cases = .{
        .{ "", "9c1185a5c5e9fc54612808977ee8f548b2258d31" },
        .{ "a", "0bdc9d2d256b3ee9daae347be6f4dc835a467ffe" },
        .{ "abc", "8eb208f7e05d987a9b044a8e98c6b087f15a0bfc" },
        .{ "message digest", "5d0689ef49d2fae572b881b123a85ffa21595f36" },
        .{ "abcdefghijklmnopqrstuvwxyz", "f71c27109c692c1b56bbdceb5b9d2865b3708dbc" },
        .{
            "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
            "12a053384a9c0c88e405a06c27dcf49ada62eb2b",
        },
        .{ "12345678901234567890123456789012345678901234567890123456789012345678901234567890", "9b752e45573d4b39f4dbd3323cab82bf63326bfb" },
    };

    inline for (cases) |case| {
        var digest: [20]u8 = undefined;
        Ripemd160.hash(case[0], &digest, .{});
        const expected = hexToBuf(case[1]);
        try testing.expectEqualSlices(u8, &expected, &digest);
    }
}

test "chunked updates match one-shot hashing for lengths spanning the 64-byte block boundary" {
    var message: [200]u8 = undefined;
    for (&message, 0..) |*byte, i| byte.* = @intCast(i % 251);
    for ([_]usize{ 0, 1, 55, 56, 57, 63, 64, 65, 127, 128, 199 }) |length| {
        var digest_all: [20]u8 = undefined;
        Ripemd160.hash(message[0..length], &digest_all, .{});

        var ctx = Ripemd160.init(.{});
        var offset: usize = 0;
        var chunk: usize = 1;
        while (offset < length) {
            const end = @min(offset + chunk, length);
            ctx.update(message[offset..end]);
            offset = end;
            chunk += 7;
        }
        var digest_chunked: [20]u8 = undefined;
        ctx.final(&digest_chunked);

        try testing.expectEqualSlices(u8, &digest_all, &digest_chunked);
    }
}

test "one million 'a' bytes (chunked processing of long input)" {
    var ctx = Ripemd160.init(.{});
    const chunk: [1000]u8 = @splat('a');
    for (0..1000) |_| ctx.update(&chunk);
    var digest: [20]u8 = undefined;
    ctx.final(&digest);
    const expected = hexToBuf("52783243c1697bdbe16d37f97f68f08325dc1528");
    try testing.expectEqualSlices(u8, &expected, &digest);
}
