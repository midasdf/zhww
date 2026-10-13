//! Hash function collection point. Everything Bitcoin and Ethereum need is gathered here.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Ripemd160 = @import("ripemd160.zig").Ripemd160;

pub const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Sha512 = std.crypto.hash.sha2.Sha512;
pub const Keccak256 = std.crypto.hash.sha3.Keccak256;

/// Double SHA-256 (used for Bitcoin checksums and BIP32).
pub fn sha256d(out: *[32]u8, data: []const u8) void {
    var first: [32]u8 = undefined;
    Sha256.hash(data, &first, .{});
    Sha256.hash(&first, out, .{});
}

/// RIPEMD160(SHA256(data)). Used for Bitcoin addresses and BIP32 fingerprints.
pub fn hash160(out: *[20]u8, data: []const u8) void {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    Ripemd160.hash(&digest, out, .{});
}

/// BIP340 tagged hash. Used for Taproot tweak computation.
///
/// SHA256(SHA256(tag) || SHA256(tag) || msg)
pub fn taggedHash(out: *[32]u8, comptime tag: []const u8, data: []const u8) void {
    var tag_digest: [32]u8 = undefined;
    Sha256.hash(tag, &tag_digest, .{});
    var ctx = Sha256.init(.{});
    ctx.update(&tag_digest);
    ctx.update(&tag_digest);
    ctx.update(data);
    ctx.final(out);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "sha256d is a double hash" {
    var expected: [32]u8 = undefined;
    var once: [32]u8 = undefined;
    Sha256.hash("hello", &once, .{});
    Sha256.hash(&once, &expected, .{});

    var actual: [32]u8 = undefined;
    sha256d(&actual, "hello");
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "hash160 is RIPEMD160(SHA256(x))" {
    var sha: [32]u8 = undefined;
    Sha256.hash("zhww", &sha, .{});
    var expected: [20]u8 = undefined;
    Ripemd160.hash(&sha, &expected, .{});

    var actual: [20]u8 = undefined;
    hash160(&actual, "zhww");
    try testing.expectEqualSlices(u8, &expected, &actual);
}

test "taggedHash follows the BIP340 definition" {
    var tag_digest: [32]u8 = undefined;
    Sha256.hash("TapTweak", &tag_digest, .{});

    var expected: [32]u8 = undefined;
    const zeros: [32]u8 = @splat(0);
    var ctx = Sha256.init(.{});
    ctx.update(&tag_digest);
    ctx.update(&tag_digest);
    ctx.update(&zeros);
    ctx.final(&expected);

    var actual: [32]u8 = undefined;
    taggedHash(&actual, "TapTweak", &zeros);
    try testing.expectEqualSlices(u8, &expected, &actual);
}
