//! Message hash for `personal_sign` (EIP-191 version `0x45`).
//!
//! ```text
//! keccak256("\x19Ethereum Signed Message:\n" + decimal byte length + message)
//! ```
//!
//! The leading `0x19` marks the data as an Ethereum signing target, so that it cannot
//! structurally collide with an RLP transaction (whose first byte is 0xC0 or above).
//! Note that the length is the **byte count** in decimal (not the character count).
//!
//! References: https://eips.ethereum.org/EIPS/eip-191
//!             https://eips.ethereum.org/EIPS/eip-712 (typed data; unsupported in v0.1)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const hashes = @import("../../core/crypto/hashes.zig");

/// Fixed prefix prepended to the message.
pub const prefix = "\x19Ethereum Signed Message:\n";

/// Maximum number of decimal digits (the largest usize has 20 digits).
const max_length_digits = 20;

/// Writes the decimal representation at the end of `buffer` and returns that slice.
fn decimal(value: usize, buffer: *[max_length_digits]u8) []const u8 {
    var index = buffer.len;
    var remaining = value;
    // Write 0 as a single digit too
    while (true) {
        index -= 1;
        buffer[index] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
        if (remaining == 0) break;
    }
    return buffer[index..];
}

/// Computes the `personal_sign` message hash.
///
/// The length is always the byte count (not the character count, even for UTF-8 messages).
pub fn personalSignHash(out: *[32]u8, message: []const u8) void {
    var length_buf: [max_length_digits]u8 = undefined;
    const length_text = decimal(message.len, &length_buf);

    var hasher = hashes.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(length_text);
    hasher.update(message);
    hasher.final(out);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
// Used in tests only (a matching signature confirms that the hash is correct).
// The module itself depends on Keccak-256 only.
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

/// Converts a hex string whose length is not known at compile time into bytes.
fn decodeHex(out: []u8, hex: []const u8) void {
    std.debug.assert(out.len * 2 == hex.len);
    _ = std.fmt.hexToBytes(out, hex) catch unreachable;
}

/// Builds the prefix and length by hand and hashes them (to check the decimal representation).
fn hashWithLengthText(out: *[32]u8, message: []const u8, length_text: []const u8) void {
    var hasher = hashes.Keccak256.init(.{});
    hasher.update(prefix);
    hasher.update(length_text);
    hasher.update(message);
    hasher.final(out);
}

test "personal_sign signatures published by MetaMask are valid (external known values)" {
    // https://github.com/MetaMask/eth-sig-util/blob/main/src/personal-sign.test.ts
    // the "message" and "signature (r || s || v)" pairs. It checks that r || s (the
    // signature without the 1-byte v) is **valid** for this hash and key
    // (a single differing hash byte makes ECDSA verification fail).
    //
    // Note: `EcdsaSignature.data` returned by `secp256k1.sign` is libsecp256k1's internal
    // representation, not big-endian r || s. Here the published r || s is converted
    // to the internal representation with `parseCompact` and then verified.
    const vectors = [_]struct {
        key_hex: []const u8,
        message_hex: []const u8,
        signature_hex: []const u8,
        v: u8,
    }{
        // "Hello, world!" (13 bytes)
        .{
            .key_hex = "4af1bceebf7f3634ec3cff8a2c38e51178d5d4ce585c52d6043e5e2cc3418bb0",
            .message_hex = "48656c6c6f2c20776f726c6421",
            .signature_hex = "90a938f7457df6e8f741264c32697fc52f9a8f867c52dd70713d9d2d472f2e41" ++
                "5d9c94148991bbe1f4a1818d1dff09165782749c877f5cf1eff4ef126e55714d",
            .v = 0x1c,
        },
        // "hello world" (11 bytes, test data generated from geth's internal implementation)
        .{
            .key_hex = "6969696969696969696969696969696969696969696969696969696969696969",
            .message_hex = "68656c6c6f20776f726c64",
            .signature_hex = "ce909e8ea6851bc36c007a0072d0524b07a3ff8d4e623aca4c71ca8e57250c4d" ++
                "0a3fc38fa8fbaaa81ead4b9f6bd03356b6f8bf18bccad167d78891636e1d6956",
            .v = 0x1b,
        },
        // 32-byte binary message (from parity's tests)
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

        // The v value is as expected too (27 = yParity 0 / 28 = yParity 1)
        try testing.expect(vector.v == 27 or vector.v == 28);
    }
}

test "hashes match an independent implementation (eth_account 0.13.7)" {
    // Values of Account.sign_message(encode_defunct(message)).message_hash.
    // Covers the digit-count boundaries (0 up to 4 digits) and UTF-8 (byte length != character count).
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

    // Long messages (lengths of 3 and 4 digits)
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

test "the decimal length is the byte count (matches hand-computed values)" {
    var expected: [32]u8 = undefined;
    var actual: [32]u8 = undefined;

    // 0 bytes
    hashWithLengthText(&expected, "", "0");
    personalSignHash(&actual, "");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // 9 bytes / 10 bytes (carry into a new digit)
    hashWithLengthText(&expected, "xxxxxxxxx", "9");
    personalSignHash(&actual, "xxxxxxxxx");
    try testing.expectEqualSlices(u8, &expected, &actual);

    hashWithLengthText(&expected, "yyyyyyyyyy", "10");
    personalSignHash(&actual, "yyyyyyyyyy");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // Byte count, not character count (the Japanese string below is 5 characters, 15 bytes)
    hashWithLengthText(&expected, "こんにちは", "15");
    personalSignHash(&actual, "こんにちは");
    try testing.expectEqualSlices(u8, &expected, &actual);

    // 1000 bytes
    var long_message: [1000]u8 = undefined;
    @memset(&long_message, 'a');
    hashWithLengthText(&expected, &long_message, "1000");
    personalSignHash(&actual, &long_message);
    try testing.expectEqualSlices(u8, &expected, &actual);
}
