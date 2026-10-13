//! BIP39 official test vectors (24 cases).
//!
//! Vector: tests/vectors/bip39.json (official vectors from https://github.com/trezor/python-mnemonic)
//! Each entry is a 4-tuple [entropy, mnemonic, seed, xprv].
//! Matching all the way to the final xprv also validates the BIP39 -> BIP32 link.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip39.json");

fn hexTo(out: []u8, hex: []const u8) ![]u8 {
    return std.fmt.hexToBytes(out, hex);
}

test "BIP39 official test vectors, 24 cases" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const english = parsed.value.object.get("english").?.array.items;
    try testing.expectEqual(@as(usize, 24), english.len);

    for (english) |entry| {
        const fields = entry.array.items;
        const entropy_hex = fields[0].string;
        const expected_mnemonic = fields[1].string;
        const expected_seed_hex = fields[2].string;
        const expected_xprv = fields[3].string;

        var entropy_buf: [32]u8 = undefined;
        const entropy = try hexTo(&entropy_buf, entropy_hex);

        // entropy → mnemonic
        var mnemonic_buf: [256]u8 = undefined;
        const mnemonic = try zhww.bip39.entropyToMnemonic(&mnemonic_buf, entropy);
        try testing.expectEqualStrings(expected_mnemonic, mnemonic);

        // mnemonic -> entropy (including checksum validation)
        var back_buf: [32]u8 = undefined;
        const back = try zhww.bip39.mnemonicToEntropy(&back_buf, mnemonic);
        try testing.expectEqualSlices(u8, entropy, back);

        // mnemonic → seed
        //
        // Note: the seed in this vector set (the official Trezor / python-mnemonic
        // vectors) was derived with the passphrase "TREZOR". It does not match an
        // empty passphrase (likewise for the BIP39 spec's own test vectors).
        var seed: [64]u8 = undefined;
        try zhww.bip39.mnemonicToSeed(&seed, mnemonic, "TREZOR");
        var seed_hex: [128]u8 = undefined;
        const encoded = std.fmt.bytesToHex(seed, .lower);
        @memcpy(seed_hex[0..encoded.len], &encoded);
        try testing.expectEqualStrings(expected_seed_hex, &seed_hex);

        // seed -> master extended private key (the link to BIP32)
        const master = try zhww.bip32.ExtendedKey.fromSeed(&seed, .xprv);
        var xprv_buf: [128]u8 = undefined;
        try testing.expectEqualStrings(expected_xprv, try master.serialize(&xprv_buf));
    }
}
