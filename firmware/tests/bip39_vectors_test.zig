//! BIP39 公式テストベクタ（24 件）。
//!
//! ベクタ: tests/vectors/bip39.json（https://github.com/trezor/python-mnemonic の公式ベクタ）
//! 各要素は [entropy, mnemonic, seed, xprv] の 4 つ組。
//! 最後の xprv まで一致させることで BIP39 → BIP32 の連結も同時に検証する。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip39.json");

fn hexTo(out: []u8, hex: []const u8) ![]u8 {
    return std.fmt.hexToBytes(out, hex);
}

test "BIP39 公式テストベクタ 24 件" {
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

        // mnemonic → entropy（チェックサム検証を含む）
        var back_buf: [32]u8 = undefined;
        const back = try zhww.bip39.mnemonicToEntropy(&back_buf, mnemonic);
        try testing.expectEqualSlices(u8, entropy, back);

        // mnemonic → seed
        //
        // 注意: このベクタ集（Trezor / python-mnemonic の公式ベクタ）の seed は
        // パスフレーズ "TREZOR" を使って導出された値である。空のパスフレーズでは
        // 一致しない（BIP39 仕様のテストベクタも同様）。
        var seed: [64]u8 = undefined;
        try zhww.bip39.mnemonicToSeed(&seed, mnemonic, "TREZOR");
        var seed_hex: [128]u8 = undefined;
        const encoded = std.fmt.bytesToHex(seed, .lower);
        @memcpy(seed_hex[0..encoded.len], &encoded);
        try testing.expectEqualStrings(expected_seed_hex, &seed_hex);

        // seed → マスター拡張秘密鍵（BIP32 との連結）
        const master = try zhww.bip32.ExtendedKey.fromSeed(&seed, .xprv);
        var xprv_buf: [128]u8 = undefined;
        try testing.expectEqualStrings(expected_xprv, try master.serialize(&xprv_buf));
    }
}
