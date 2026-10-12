//! Ethereum addresses (EIP-55 checksummed hexadecimal notation).
//!
//! - An address is the **low-order 20 bytes** of `keccak256(X || Y of the uncompressed public key)`
//! - EIP-55 expresses the checksum through the **letter case** of the hex notation. It takes
//!   the keccak256 of the input (40 lowercase characters) and uppercases a character when
//!   the corresponding nibble is 8 or greater
//! - Note that the hash used for signature verification is Keccak-256 (not SHA3-256)
//!
//! References: https://github.com/ethereum/ercs/blob/master/ERCS/erc-55.md
//!             https://ethereum.org/en/developers/docs/accounts/
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

/// Address length in bytes.
pub const address_len = 20;
/// Length of `0x` plus 40 checksummed hex characters.
pub const checksummed_len = 42;

/// Derives an address (20 bytes) from an uncompressed public key (65 bytes, first byte 0x04).
///
/// Does not check whether the point is on the curve (keys we generated ourselves are assumed.
/// When handling public keys from outside, the key code must verify them).
pub fn addressBytes(pub_key: [65]u8) Error![20]u8 {
    if (pub_key[0] != 0x04) return error.InvalidKey;
    var hash: [32]u8 = undefined;
    hashes.Keccak256.hash(pub_key[1..65], &hash, .{});
    return hash[12..32].*;
}

/// Derives an address (20 bytes) from a private key.
pub fn addressBytesFromPrivateKey(priv: [32]u8) Error![20]u8 {
    return addressBytes(try secp256k1.pubKeyUncompressed(priv));
}

/// Writes the EIP-55 checksummed hex notation (`0x` + 40 characters) to `out`.
pub fn checksum(out: []u8, address: [20]u8) Error![]u8 {
    if (out.len < checksummed_len) return error.BufferTooSmall;

    // First build the 40 lowercase hex characters. The keccak256 of this string is the basis of the checksum.
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
        // Digits cannot be uppercased, so only letters are uppercased
        out[2 + i] = if (nibble >= 8 and character >= 'a') character - 32 else character;
    }
    return out[0..checksummed_len];
}

/// Builds an EIP-55 checksummed address string from an uncompressed public key.
pub fn fromPublicKey(out: []u8, pub_key: [65]u8) Error![]u8 {
    return checksum(out, try addressBytes(pub_key));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Converts a hex string (without 0x) into a fixed-length byte array.
fn hexBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "EIP-55 official test cases (8 vectors)" {
    // Test Cases from https://github.com/ethereum/ercs/blob/master/ERCS/erc-55.md
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

test "derives addresses from known private keys" {
    var buf: [checksummed_len]u8 = undefined;

    // The key used in the EIP-155 example (verified to match eth_account)
    const eip155_priv = hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646");
    try testing.expectEqualStrings(
        "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F",
        try fromPublicKey(&buf, try secp256k1.pubKeyUncompressed(eip155_priv)),
    );

    // The key used by MetaMask's personal-sign tests
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

    // Build the checksummed notation from the raw 20-byte address
    try testing.expectEqualStrings(
        "0xbE93f9BacBcFFC8ee6663f2647917ed7A20a57BB",
        try checksum(&buf, try addressBytesFromPrivateKey(kumavis_priv)),
    );
}

test "rejects a key that is not an uncompressed public key" {
    var pub_key: [65]u8 = @splat(0);
    pub_key[0] = 0x02; // compressed public key prefix
    var buf: [checksummed_len]u8 = undefined;
    try testing.expectError(error.InvalidKey, fromPublicKey(&buf, pub_key));
    try testing.expectError(error.InvalidKey, addressBytes(pub_key));
}

test "rejects an output buffer that is too small" {
    const priv = hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646");
    var small: [checksummed_len - 1]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        fromPublicKey(&small, try secp256k1.pubKeyUncompressed(priv)),
    );
}
