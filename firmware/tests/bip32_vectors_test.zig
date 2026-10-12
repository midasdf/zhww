//! BIP32 official test vectors (the derivation chain of test vector 1).
//!
//! Vector: tests/vectors/bip32.json
//! Source: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip32.json");

test "BIP32 test vector 1 derivation chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    var seed_buf: [64]u8 = undefined;
    const seed = try std.fmt.hexToBytes(&seed_buf, root.get("seed").?.string);

    const chains = root.get("chains").?.array.items;
    try testing.expect(chains.len >= 6);

    const master = try zhww.bip32.ExtendedKey.fromSeed(seed, .xprv);

    for (chains) |entry| {
        const fields = entry.object;
        const path = fields.get("path").?.string;
        const expected_xprv = fields.get("xprv").?.string;
        const expected_xpub = fields.get("xpub").?.string;

        const node = try master.derivePath(path);
        var buf: [128]u8 = undefined;
        try testing.expectEqualStrings(expected_xprv, try node.serialize(&buf));

        const public_node = try node.neuter();
        try testing.expectEqualStrings(expected_xpub, try public_node.serialize(&buf));
    }
}

test "public-only derivation matches private derivation (non-hardened part)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    var seed_buf: [64]u8 = undefined;
    const seed = try std.fmt.hexToBytes(&seed_buf, parsed.value.object.get("seed").?.string);

    const master = try zhww.bip32.ExtendedKey.fromSeed(seed, .xprv);
    const account = try master.derivePath("m/0'");
    const account_pub = try account.neuter();

    // Derive m/0'/1 from both the private and the public side and confirm they match
    // (relative paths are used for non-master keys)
    const from_private = try account.derivePath("1");
    const from_public = try account_pub.derivePath("1");

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    try testing.expectEqualStrings(
        try (try from_private.neuter()).serialize(&buf_a),
        try from_public.serialize(&buf_b),
    );

    // A public-only node cannot do hardened derivation
    try testing.expectError(error.InvalidPath, account_pub.derivePath("0'"));
    // The private side can (confirming that the public key carries no hardened information)
    _ = try account.derivePath("0'");
}
