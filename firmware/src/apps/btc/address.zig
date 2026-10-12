//! Bitcoin のアドレス生成（P2PKH / P2SH-P2WPKH / P2WPKH / P2TR）。
//!
//! **設計上の要点**
//! - Bech32（v0）と Bech32m（v1）の取り違えを構造的に防ぐため、エンコードは
//!   core.encoding.bech32.encodeSegwit に一元化する
//! - ネットワークは mainnet / testnet / signet / regtest に対応する
//! - P2TR は BIP341 の鍵パス（内部鍵 + TapTweak）のみを扱う
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const base58 = @import("../../core/encoding/base58.zig");
const bech32 = @import("../../core/encoding/bech32.zig");

pub const Network = enum {
    mainnet,
    testnet,
    signet,
    regtest,

    /// P2PKH のバージョンバイト。
    pub fn p2pkhPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x00,
            .testnet, .signet, .regtest => 0x6F,
        };
    }

    /// P2SH のバージョンバイト。
    pub fn p2shPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x05,
            .testnet, .signet, .regtest => 0xC4,
        };
    }

    /// WIF のバージョンバイト。
    pub fn wifPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x80,
            .testnet, .signet, .regtest => 0xEF,
        };
    }

    /// Bech32 の HRP。
    pub fn hrp(self: Network) []const u8 {
        return switch (self) {
            .mainnet => "bc",
            .testnet, .signet => "tb",
            .regtest => "bcrt",
        };
    }
};

fn checkPubKey(pub_key: [33]u8) Error!void {
    if (pub_key[0] != 2 and pub_key[0] != 3) return error.InvalidKey;
}

/// BIP44 の P2PKH アドレス（'1...'）。
pub fn p2pkh(out: []u8, pub_key: [33]u8, network: Network) Error![]u8 {
    try checkPubKey(pub_key);
    var payload: [21]u8 = undefined;
    payload[0] = network.p2pkhPrefix();
    hashes.hash160(payload[1..21], &pub_key);
    return base58.checkEncode(out, &payload);
}

/// BIP49 の P2SH-P2WPKH アドレス（'3...' / testnet は '2...'）。
///
/// redeemScript = 0x0014 || HASH160(pubkey)、その HASH160 を P2SH で包む。
pub fn p2shP2wpkh(out: []u8, pub_key: [33]u8, network: Network) Error![]u8 {
    try checkPubKey(pub_key);
    var redeem_script: [22]u8 = undefined;
    redeem_script[0] = 0x00;
    redeem_script[1] = 0x14;
    hashes.hash160(redeem_script[2..22], &pub_key);

    var payload: [21]u8 = undefined;
    payload[0] = network.p2shPrefix();
    hashes.hash160(payload[1..21], &redeem_script);
    return base58.checkEncode(out, &payload);
}

/// BIP84 の P2WPKH アドレス（'bc1q...'、Bech32 / witness v0）。
pub fn p2wpkh(out: []u8, pub_key: [33]u8, network: Network) Error![]u8 {
    try checkPubKey(pub_key);
    var program: [20]u8 = undefined;
    hashes.hash160(&program, &pub_key);
    return bech32.encodeSegwit(out, network.hrp(), 0, &program);
}

/// BIP86 の P2TR アドレス（'bc1p...'、Bech32m / witness v1）。
///
/// `internal_xonly` は 32 バイトの x-only 公開鍵。
pub fn p2tr(out: []u8, internal_xonly: [32]u8, network: Network) Error![]u8 {
    const output_key = try secp256k1.taprootOutputKey(internal_xonly);
    return bech32.encodeSegwit(out, network.hrp(), 1, &output_key);
}

/// 秘密鍵の WIF 表現（テストベクタとの突合用）。
pub fn wif(out: []u8, priv: [32]u8, network: Network, compressed: bool) Error![]u8 {
    if (!secp256k1.isValidPrivateKey(priv)) return error.InvalidKey;
    var payload: [34]u8 = undefined;
    payload[0] = network.wifPrefix();
    @memcpy(payload[1..33], &priv);
    if (compressed) {
        payload[33] = 0x01;
        return base58.checkEncode(out, payload[0..34]);
    }
    return base58.checkEncode(out, payload[0..33]);
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "ネットワークごとのプレフィクス" {
    try testing.expectEqual(@as(u8, 0x00), Network.mainnet.p2pkhPrefix());
    try testing.expectEqual(@as(u8, 0xC4), Network.testnet.p2shPrefix());
    try testing.expectEqualStrings("bc", Network.mainnet.hrp());
    try testing.expectEqualStrings("tb", Network.testnet.hrp());
    try testing.expectEqualStrings("bcrt", Network.regtest.hrp());
}

test "同一公開鍵から 4 種類のアドレスを生成する" {
    // BIP49 テストベクタの公開鍵
    var pub_key: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &pub_key,
        "03a1af804ac108a8a51782198c2d034b28bf90c8803f5a53f76276fa69a4eae77f",
    );

    var buf: [90]u8 = undefined;
    try testing.expectEqualStrings(
        "2Mww8dCYPUpKHofjgcXcBCEGmniw9CoaiD2",
        try p2shP2wpkh(&buf, pub_key, .testnet),
    );
    // mainnet では '3...' になる（同じ鍵素材）
    try testing.expectEqual(@as(u8, '3'), (try p2shP2wpkh(&buf, pub_key, .mainnet))[0]);
    // P2WPKH は 'bc1q'、P2TR は 'bc1p'
    try testing.expect(std.mem.startsWith(u8, try p2wpkh(&buf, pub_key, .mainnet), "bc1q"));
    try testing.expect(std.mem.startsWith(u8, try p2tr(&buf, pub_key[1..33].*, .mainnet), "bc1p"));
}

test "WIF の圧縮・非圧縮" {
    var priv: [32]u8 = @splat(0);
    priv[31] = 0x01;
    var buf: [64]u8 = undefined;
    const compressed = try wif(&buf, priv, .mainnet, true);
    try testing.expectEqual(@as(u8, 'K'), compressed[0]);

    const uncompressed = try wif(&buf, priv, .testnet, false);
    try testing.expectEqual(@as(u8, '9'), uncompressed[0]);
}
