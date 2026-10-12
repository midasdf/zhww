//! `personal_sign`（EIP-191 の version `0x45`）のメッセージハッシュ。
//!
//! ```text
//! keccak256("\x19Ethereum Signed Message:\n" + 十進のバイト長 + message)
//! ```
//!
//! 先頭の `0x19` は「Ethereum の署名対象である」ことを示すバイトで、RLP の
//! トランザクション（先頭が 0xC0 以上）と構造的に衝突しないようにしている。
//! 長さは**バイト数**の十進表記（文字数ではない）であることに注意。
//!
//! 参考: https://eips.ethereum.org/EIPS/eip-191
//!       https://eips.ethereum.org/EIPS/eip-712 （型付きデータ。v0.1 では未対応）
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const hashes = @import("../../core/crypto/hashes.zig");

/// メッセージの前に付ける固定プレフィクス。
pub const prefix = "\x19Ethereum Signed Message:\n";

/// 十進表記の最大桁数（usize の最大値は 20 桁）。
const max_length_digits = 20;

/// 十進表記を `buffer` の末尾に書き、そのスライスを返す。
fn decimal(value: usize, buffer: *[max_length_digits]u8) []const u8 {
    var index = buffer.len;
    var remaining = value;
    // 0 も 1 桁として書く
    while (true) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    return buffer[index..];
}

/// `personal_sign` のメッセージハッシュを計算する。
///
/// 長さは必ずバイト数で書く（UTF-8 のメッセージでも文字数ではない）。
pub fn personalSignHash(out: *[32]u8, message: []const u8) void {
    var length_buf: [max_length_digits]u8 = undefined;
    const length_text = decimal(message.len, &length_buf);

    var hasher = hashes.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(length_text);
    hasher.update(message);
    hasher.final(out);
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;
// テストでのみ使う（ハッシュが正しいことを署名の一致で確認する）。
// 本体の依存は Keccak-256 だけ。
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

/// 長さがコンパイル時に決まらない 16 進文字列をバイト列に直す。
fn decodeHex(out: []u8, hex: []const u8) void {
    std.debug.assert(out.len * 2 == hex.len);
    _ = std.fmt.hexToBytes(out, hex) catch unreachable;
}

/// 手でプレフィクスと長さを組み立ててハッシュする（十進表記の確認用）。
fn hashWithLengthText(out: *[32]u8, message: []const u8, length_text: []const u8) void {
    var hasher = hashes.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(length_text);
    hasher.update(message);
    hasher.final(out);
}

test "MetaMask が公開している personal_sign の署名が有効である（外部の既知値）" {
    // https://github.com/MetaMask/eth-sig-util/blob/main/src/personal-sign.test.ts
    // にある「メッセージ」と「署名（r || s || v）」の組。v の 1 バイトを除いた
    // r || s が、このハッシュと鍵に対して **有効** であることを確認する
    // （ハッシュが 1 バイトでも違えば ECDSA の検証に失敗する）。
    //
    // 注意: `secp256k1.sign` が返す `EcdsaSignature.data` は libsecp256k1 の内部表現で
    // あり、r || s のビッグエンディアンではない。ここでは公開されている r || s を
    // `parseCompact` で内部表現に直して検証する。
    const vectors = [_]struct {
        key_hex: []const u8,
        message_hex: []const u8,
        signature_hex: []const u8,
        v: u8,
    }{
        // "Hello, world!"（13 バイト）
        .{
            .key_hex = "4af1bceebf7f3634ec3cff8a2c38e51178d5d4ce585c52d6043e5e2cc3418bb0",
            .message_hex = "48656c6c6f2c20776f726c6421",
            .signature_hex = "90a938f7457df6e8f741264c32697fc52f9a8f867c52dd70713d9d2d472f2e41" ++
                "5d9c94148991bbe1f4a1818d1dff09165782749c877f5cf1eff4ef126e55714d",
            .v = 0x1c,
        },
        // "hello world"（11 バイト、geth の内部実装から作られたテストデータ）
        .{
            .key_hex = "6969696969696969696969696969696969696969696969696969696969696969",
            .message_hex = "68656c6c6f20776f726c64",
            .signature_hex = "ce909e8ea6851bc36c007a0072d0524b07a3ff8d4e623aca4c71ca8e57250c4d" ++
                "0a3fc38fa8fbaaa81ead4b9f6bd03356b6f8bf18bccad167d78891636e1d6956",
            .v = 0x1b,
        },
        // 32 バイトのバイナリメッセージ（parity のテスト由来）
        .{
            .key_hex = "4545454545454545454545454545454545454545454545454545454545454545",
            .message_hex = "0cc175b9c0f1b6a831c399e26977266192eb5ffee6ae2fec3ad71c777531578f",
            .signature_hex = "a2870db1d0c26ef93c7b72d2a0830fa6b841e0593f7186bc6c7cc317af8cf3a4" ++
                "2fda03bd589a49949aa05db83300cdb553116274518dbe9d90c65d0213f4af49",
            .v = 0x1b,
        },
    };

    for (vectors) |vector| {
        var key: [32]u8 = undefined;
        var message_buf: [64]u8 = undefined;
        var compact: [64]u8 = undefined;
        decodeHex(&key, vector.key_hex);
        decodeHex(message_buf[0 .. vector.message_hex.len / 2], vector.message_hex);
        decodeHex(&compact, vector.signature_hex);

        var hash: [32]u8 = undefined;
        personalSignHash(&hash, message_buf[0 .. vector.message_hex.len / 2]);

        const signature = try secp256k1.parseCompact(compact);
        try testing.expect(try secp256k1.verify(&signature, hash, try secp256k1.pubKeyCompressed(key)));

        // v の値も期待どおり（27 = yParity 0 / 28 = yParity 1）
        try testing.expect(vector.v == 27 or vector.v == 28);
    }
}

test "独立実装（eth_account 0.13.7）が計算したハッシュと一致する" {
    // Account.sign_message(encode_defunct(message)).message_hash の値。
    // 長さの桁数が変わる境界（0〜4 桁）と、UTF-8（バイト長 ≠ 文字数）を含む。
    const vectors = [_]struct { message: []const u8, hash_hex: []const u8 }{
        .{ .message = "", .hash_hex = "5f35dce98ba4fba25530a026ed80b2cecdaa31091ba4958b99b52ea1d068adad" },
        .{ .message = "xxxxxxxxx", .hash_hex = "9481e0d73ccde0e03d02ed91971f12e20877bd3bf6428f91be5a1d43e56bebc8" },
        .{ .message = "yyyyyyyyyy", .hash_hex = "cc8ad82ea7be944df2c23f4141f3481a26d91efa13d7ec4cb39dd83f8bb8aa13" },
        .{ .message = "hello world", .hash_hex = "d9eba16ed0ecae432b71fe008c98cc872bb4cc214d3220a36f365326cf807d68" },
        .{ .message = "Hello, world!", .hash_hex = "b453bd4e271eed985cbab8231da609c4ce0a9cf1f763b6c1594e76315510e0f1" },
        .{ .message = "こんにちは", .hash_hex = "dc0823221878132a64a0cbbe349ba3474bb7bef0c388a83c036a83805f28e3a5" },
    };

    for (vectors) |vector| {
        var hash: [32]u8 = undefined;
        personalSignHash(&hash, vector.message);

        var expected: [32]u8 = undefined;
        decodeHex(&expected, vector.hash_hex);
        try testing.expectEqualSlices(u8, &expected, &hash);
    }

    // 長いメッセージ（長さが 3 桁・4 桁）
    const long_vectors = [_]struct { byte: u8, len: usize, hash_hex: []const u8 }{
        .{ .byte = 'a', .len = 100, .hash_hex = "90b496d4433ae2fe10bba2f73ca6a210a57d8499db0ae5dfb05f3fbeeff2b0cf" },
        .{ .byte = 'z', .len = 200, .hash_hex = "69736edfdad41e48a3519e78332e2a13813a6d556cb5ff3b30e81e66b8d71250" },
        .{ .byte = 'a', .len = 1000, .hash_hex = "646dfe80977f3cb244f566d96cd3aabb891d47b9ba5159076d78e9999835e0d6" },
    };

    var buffer: [1000]u8 = undefined;
    for (long_vectors) |vector| {
        @memset(buffer[0..vector.len], vector.byte);
        var hash: [32]u8 = undefined;
        personalSignHash(&hash, buffer[0..vector.len]);

        var expected: [32]u8 = undefined;
        decodeHex(&expected, vector.hash_hex);
        try testing.expectEqualSlices(u8, &expected, &hash);
    }
}

test "長さの十進表記はバイト数（手計算との一致）" {
    var expected: [32]u8 = undefined;
    var actual: [32]u8 = undefined;

    // 0 バイト
    hashWithLengthText(&expected, "", "0");
    personalSignHash(&actual, "");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // 9 バイト / 10 バイト（桁上がり）
    hashWithLengthText(&expected, "xxxxxxxxx", "9");
    personalSignHash(&actual, "xxxxxxxxx");
    try testing.expectEqualSlices(u8, &expected, &actual);

    hashWithLengthText(&expected, "yyyyyyyyyy", "10");
    personalSignHash(&actual, "yyyyyyyyyy");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // 文字数ではなくバイト数（"こんにちは" は 5 文字・15 バイト）
    hashWithLengthText(&expected, "こんにちは", "15");
    personalSignHash(&actual, "こんにちは");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // 1000 バイト
    var long_message: [1000]u8 = undefined;
    @memset(&long_message, 'a');
    hashWithLengthText(&expected, &long_message, "1000");
    personalSignHash(&actual, &long_message);
    try testing.expectEqualSlices(u8, &expected, &actual);
}
