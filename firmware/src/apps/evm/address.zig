//! Ethereum のアドレス（EIP-55 のチェックサム付き 16 進表記）。
//!
//! - アドレスは `keccak256(非圧縮公開鍵の X || Y)` の**下位 20 バイト**
//! - EIP-55 は 16 進表記の**大文字小文字**でチェックサムを表す。入力（小文字の
//!   40 文字）の keccak256 をとり、対応するニブルが 8 以上なら大文字にする
//! - 署名検証に使うハッシュは Keccak-256（SHA3-256 ではない）であることに注意
//!
//! 参考: https://github.com/ethereum/ercs/blob/master/ERCS/erc-55.md
//!       https://ethereum.org/en/developers/docs/accounts/

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

/// アドレスのバイト長。
pub const address_len = 20;
/// `0x` + チェックサム付き 16 進 40 文字の長さ。
pub const checksummed_len = 42;

/// 非圧縮公開鍵（65 バイト、先頭は 0x04）からアドレス（20 バイト）を導出する。
///
/// 曲線上にあるかどうかの検証は行わない（自前で生成した鍵を渡す前提。
/// 外部から来た公開鍵を扱う場合は鍵側で検証すること）。
pub fn addressBytes(pub_key: [65]u8) Error![20]u8 {
    if (pub_key[0] != 0x04) return error.InvalidKey;
    var hash: [32]u8 = undefined;
    hashes.Keccak256.hash(pub_key[1..65], &hash, .{});
    return hash[12..32].*;
}

/// 秘密鍵からアドレス（20 バイト）を導出する。
pub fn addressBytesFromPrivateKey(priv: [32]u8) Error![20]u8 {
    return addressBytes(try secp256k1.pubKeyUncompressed(priv));
}

/// EIP-55 のチェックサム付き 16 進表記（`0x` + 40 文字）を `out` に書く。
pub fn checksum(out: []u8, address: [20]u8) Error![]u8 {
    if (out.len < checksummed_len) return error.BufferTooSmall;

    // まず小文字の 16 進 40 文字を作る。この文字列の keccak256 がチェックサムの根拠。
    const digits = "0123456789abcdef";
    var lowercase: [40]u8 = undefined;
    for (address, 0..) |byte, i| {
        lowercase[i * 2] = digits[byte >> 4];
        lowercase[i * 2 + 1] = digits[byte & 0x0F];
    }

    var hash: [32]u8 = undefined;
    hashes.Keccak256.hash(&lowercase, &hash, .{});

    out[0] = '0';
    out[1] = 'x';
    for (lowercase, 0..) |character, i| {
        const nibble = if (i % 2 == 0) hash[i / 2] >> 4 else hash[i / 2] & 0x0F;
        // 数字は大文字にできないので、英字のときだけ大文字化する
        out[2 + i] = if (nibble >= 8 and character >= 'a') character - 32 else character;
    }
    return out[0..checksummed_len];
}

/// 非圧縮公開鍵から EIP-55 チェックサム付きアドレス文字列を作る。
pub fn fromPublicKey(out: []u8, pub_key: [65]u8) Error![]u8 {
    return checksum(out, try addressBytes(pub_key));
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// 16 進文字列（0x 無し）を固定長のバイト列にする。
fn hexBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "EIP-55 の公式テストケース（8 件）" {
    // https://github.com/ethereum/ercs/blob/master/ERCS/erc-55.md の Test Cases
    const vectors = [_][]const u8{
        // All caps
        "0x52908400098527886E0F7030069857D2E4169EE7",
        "0x8617E340B3D01FA5F11F306F4090FD50E238070D",
        // All lower
        "0xde709f2102306220921060314715629080e2fb77",
        "0x27b1fdb04752bbc536007a920d24acb045561c26",
        // Normal
        "0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
        "0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
        "0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
        "0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
    };

    var buf: [checksummed_len]u8 = undefined;
    for (vectors) |expected| {
        var address: [20]u8 = undefined;
        _ = try std.fmt.hexToBytes(&address, expected[2..42]);
        try testing.expectEqualStrings(expected, try checksum(&buf, address));
    }
}

test "既知の秘密鍵からアドレスを導出する" {
    var buf: [checksummed_len]u8 = undefined;

    // EIP-155 の例で使われている鍵（eth_account と一致することを確認済み）
    const eip155_priv = hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646");
    try testing.expectEqualStrings(
        "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F",
        try fromPublicKey(&buf, try secp256k1.pubKeyUncompressed(eip155_priv)),
    );

    // MetaMask の personal-sign テストで使われている鍵
    // https://github.com/MetaMask/eth-sig-util/blob/main/src/personal-sign.test.ts
    const metamask_priv = hexBytes(32, "4af1bceebf7f3634ec3cff8a2c38e51178d5d4ce585c52d6043e5e2cc3418bb0");
    try testing.expectEqualStrings(
        "0x29C76e6aD8f28BB1004902578Fb108c507Be341b",
        try fromPublicKey(&buf, try secp256k1.pubKeyUncompressed(metamask_priv)),
    );

    const kumavis_priv = hexBytes(32, "6969696969696969696969696969696969696969696969696969696969696969");
    try testing.expectEqualStrings(
        "0xbE93f9BacBcFFC8ee6663f2647917ed7A20a57BB",
        try fromPublicKey(&buf, try secp256k1.pubKeyUncompressed(kumavis_priv)),
    );

    // 20 バイトの生アドレスからチェックサム表記を作る
    try testing.expectEqualStrings(
        "0xbE93f9BacBcFFC8ee6663f2647917ed7A20a57BB",
        try checksum(&buf, try addressBytesFromPrivateKey(kumavis_priv)),
    );
}

test "非圧縮公開鍵でない場合は拒否する" {
    var pub_key: [65]u8 = @splat(0);
    pub_key[0] = 0x02; // 圧縮公開鍵の接頭辞
    var buf: [checksummed_len]u8 = undefined;
    try testing.expectError(error.InvalidKey, fromPublicKey(&buf, pub_key));
    try testing.expectError(error.InvalidKey, addressBytes(pub_key));
}

test "出力バッファが足りない場合は拒否する" {
    const priv = hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646");
    var small: [checksummed_len - 1]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        fromPublicKey(&small, try secp256k1.pubKeyUncompressed(priv)),
    );
}
