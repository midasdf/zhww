//! Bitcoin address generation (P2PKH / P2SH-P2WPKH / P2WPKH / P2TR).
//!
//! **Design notes**
//! - To structurally prevent mixing up Bech32 (v0) and Bech32m (v1), encoding is
//!   centralized in core.encoding.bech32.encodeSegwit
//! - The networks mainnet / testnet / signet / regtest are supported
//! - P2TR handles only the BIP341 key path (internal key + TapTweak)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

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

    /// P2PKH version byte.
    pub fn p2pkhPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x00,
            .testnet, .signet, .regtest => 0x6F,
        };
    }

    /// P2SH version byte.
    pub fn p2shPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x05,
            .testnet, .signet, .regtest => 0xC4,
        };
    }

    /// WIF version byte.
    pub fn wifPrefix(self: Network) u8 {
        return switch (self) {
            .mainnet => 0x80,
            .testnet, .signet, .regtest => 0xEF,
        };
    }

    /// Bech32 HRP.
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

/// BIP44 P2PKH address ('1...').
pub fn p2pkh(out: []u8, pub_key: [33]u8, network: Network) Error![]u8 {
    try checkPubKey(pub_key);
    var payload: [21]u8 = undefined;
    payload[0] = network.p2pkhPrefix();
    hashes.hash160(payload[1..21], &pub_key);
    return base58.checkEncode(out, &payload);
}

/// BIP49 P2SH-P2WPKH address ('3...' / '2...' on testnet).
///
/// redeemScript = 0x0014 || HASH160(pubkey), whose HASH160 is then wrapped in P2SH.
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

/// BIP84 P2WPKH address ('bc1q...', Bech32 / witness v0).
pub fn p2wpkh(out: []u8, pub_key: [33]u8, network: Network) Error![]u8 {
    try checkPubKey(pub_key);
    var program: [20]u8 = undefined;
    hashes.hash160(&program, &pub_key);
    return bech32.encodeSegwit(out, network.hrp(), 0, &program);
}

/// BIP86 P2TR address ('bc1p...', Bech32m / witness v1).
///
/// `internal_xonly` is the 32-byte x-only public key.
pub fn p2tr(out: []u8, internal_xonly: [32]u8, network: Network) Error![]u8 {
    const output_key = try secp256k1.taprootOutputKey(internal_xonly);
    return bech32.encodeSegwit(out, network.hrp(), 1, &output_key);
}

/// WIF representation of a private key (for cross-checking against test vectors).
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


/// Derive the address from a scriptPubKey (for display; null for unknown types).
///
/// Supported: P2PKH / P2SH / P2WPKH / P2WSH / P2TR.
pub fn fromScriptPubKey(out: []u8, script: []const u8, network: Network) Error!?[]u8 {
    // P2PKH: 76 a9 14 {20} 88 ac
    if (script.len == 25 and script[0] == 0x76 and script[1] == 0xa9 and
        script[2] == 0x14 and script[23] == 0x88 and script[24] == 0xac)
    {
        const payload = [_]u8{network.p2pkhPrefix()} ++ script[3..23].*;
        return try base58.checkEncode(out, &payload);
    }
    // P2SH: a9 14 {20} 87
    if (script.len == 23 and script[0] == 0xa9 and script[1] == 0x14 and script[22] == 0x87) {
        const payload = [_]u8{network.p2shPrefix()} ++ script[2..22].*;
        return try base58.checkEncode(out, &payload);
    }
    // P2WPKH / P2WSH (witness v0)
    if (script.len == 22 and script[0] == 0x00 and script[1] == 0x14) {
        return try bech32.encodeSegwit(out, network.hrp(), 0, script[2..22]);
    }
    if (script.len == 34 and script[0] == 0x00 and script[1] == 0x20) {
        return try bech32.encodeSegwit(out, network.hrp(), 0, script[2..34]);
    }
    // P2TR (witness v1)
    if (script.len == 34 and script[0] == 0x51 and script[1] == 0x20) {
        return try bech32.encodeSegwit(out, network.hrp(), 1, script[2..34]);
    }
    return null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "prefixes per network" {
    try testing.expectEqual(@as(u8, 0x00), Network.mainnet.p2pkhPrefix());
    try testing.expectEqual(@as(u8, 0xC4), Network.testnet.p2shPrefix());
    try testing.expectEqualStrings("bc", Network.mainnet.hrp());
    try testing.expectEqualStrings("tb", Network.testnet.hrp());
    try testing.expectEqualStrings("bcrt", Network.regtest.hrp());
}

test "generates four kinds of address from the same public key" {
    // The public key from the BIP49 test vector
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
    // On mainnet this becomes '3...' (the same key material)
    try testing.expectEqual(@as(u8, '3'), (try p2shP2wpkh(&buf, pub_key, .mainnet))[0]);
    // P2WPKH is 'bc1q', P2TR is 'bc1p'
    try testing.expect(std.mem.startsWith(u8, try p2wpkh(&buf, pub_key, .mainnet), "bc1q"));
    try testing.expect(std.mem.startsWith(u8, try p2tr(&buf, pub_key[1..33].*, .mainnet), "bc1p"));
}

test "WIF compressed and uncompressed" {
    var priv: [32]u8 = @splat(0);
    priv[31] = 0x01;
    var buf: [64]u8 = undefined;
    const compressed = try wif(&buf, priv, .mainnet, true);
    try testing.expectEqual(@as(u8, 'K'), compressed[0]);

    const uncompressed = try wif(&buf, priv, .testnet, false);
    try testing.expectEqual(@as(u8, '9'), uncompressed[0]);
}

test "recovers the address from a scriptPubKey (official vector scriptPubKeys)" {
    var buf: [90]u8 = undefined;

    // The P2WPKH from the BIP84 test vector
    var wpkh: [22]u8 = undefined;
    _ = try std.fmt.hexToBytes(&wpkh, "0014c0cebcd6c3d3ca8c75dc5ec62ebe55330ef910e2");
    try testing.expectEqualStrings(
        "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        (try fromScriptPubKey(&buf, &wpkh, .mainnet)).?,
    );

    // The P2TR from the BIP86 test vector
    var tr: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &tr,
        "5120a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c",
    );
    try testing.expectEqualStrings(
        "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr",
        (try fromScriptPubKey(&buf, &tr, .mainnet)).?,
    );

    // The P2SH (testnet) from the BIP49 test vector
    var sh: [23]u8 = undefined;
    _ = try std.fmt.hexToBytes(&sh, "a914336caa13e08b96080a32b5d818d59b4ab3b3674287");
    try testing.expectEqualStrings(
        "2Mww8dCYPUpKHofjgcXcBCEGmniw9CoaiD2",
        (try fromScriptPubKey(&buf, &sh, .testnet)).?,
    );

    // P2WSH and an unsupported script
    var wsh: [34]u8 = @splat(0x22);
    wsh[0] = 0x00;
    wsh[1] = 0x20;
    try testing.expect((try fromScriptPubKey(&buf, &wsh, .mainnet)) != null);
    try testing.expect((try fromScriptPubKey(&buf, &[_]u8{0x6a}, .mainnet)) == null);
}
