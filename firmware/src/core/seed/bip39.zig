//! BIP39 mnemonic generation, validation and seed derivation.
//!
//! Reference: https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
//!
//! **Design points**
//! - Entropy is produced and passed in by the caller (the entropy module) from dice, camera and TRNG.
//!   This module never generates randomness itself
//! - The word list is embedded in the binary (no runtime dependency on a filesystem)
//! - Passphrases and mnemonics need NFKD normalization, but v0.1 supports ASCII only, and
//!   non-ASCII is made an **explicit error** (so we never silently build a different seed)
//! - The mnemonic is whitespace-normalized before PBKDF2 (so the seed cannot change on trailing whitespace)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("../crypto/hashes.zig");

const pbkdf2 = std.crypto.pwhash.pbkdf2;
const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

/// BIP39 word list size.
pub const wordlist_len = 2048;

/// Supported mnemonic word counts.
pub const valid_word_counts = [_]usize{ 12, 15, 18, 21, 24 };

/// Word list embedded in the binary. BIP39 English edition (2048 words).
const english_words: [wordlist_len][]const u8 = blk: {
    @setEvalBranchQuota(200_000);
    var list: [wordlist_len][]const u8 = undefined;
    var it = std.mem.tokenizeAny(u8, @embedFile("english.txt"), "\r\n");
    var count: usize = 0;
    while (it.next()) |raw| {
        if (count >= wordlist_len) @compileError("the BIP39 word list has more than 2048 words");
        list[count] = std.mem.trim(u8, raw, " \t\r");
        count += 1;
    }
    if (count != wordlist_len) @compileError("the BIP39 word list must have exactly 2048 words");
    break :blk list;
};

/// Word list (read-only).
pub fn wordlist() [wordlist_len][]const u8 {
    return english_words;
}

/// Return the word's index, or null if it is not found.
pub fn wordIndex(word: []const u8) ?u11 {
    for (english_words, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, word)) return @intCast(i);
    }
    return null;
}

/// Convert entropy (16/20/24/28/32 bytes) into a mnemonic.
pub fn entropyToMnemonic(out: []u8, entropy: []const u8) Error![]u8 {
    const bits = entropy.len * 8;
    if (bits != 128 and bits != 160 and bits != 192 and bits != 224 and bits != 256) {
        return error.InvalidMnemonic;
    }
    const checksum_bits: u9 = @intCast(bits / 32);
    const checksum_shift: u3 = @intCast(8 - checksum_bits);

    var digest: [32]u8 = undefined;
    hashes.Sha256.hash(entropy, &digest, .{});

    var value: u264 = 0;
    for (entropy) |byte| value = (value << 8) | byte;
    value = (value << checksum_bits) | (digest[0] >> checksum_shift);

    const count = (bits + @as(usize, checksum_bits)) / 11;
    var pos: usize = 0;
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const shift: u9 = @intCast(11 * i);
        const index: u11 = @truncate((value >> shift) & 0x7FF);
        const word = english_words[index];
        if (pos + word.len + 1 > out.len) return error.BufferTooSmall;
        if (pos != 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos..][0..word.len], word);
        pos += word.len;
    }
    return out[0..pos];
}

/// Validate a mnemonic and turn it back into entropy. A checksum mismatch is error.ChecksumMismatch.
pub fn mnemonicToEntropy(out: []u8, mnemonic: []const u8) Error![]u8 {
    var it = std.mem.tokenizeAny(u8, mnemonic, " \t\r\n");
    var value: u264 = 0;
    var count: usize = 0;
    while (it.next()) |word| {
        const index = wordIndex(word) orelse return error.InvalidMnemonic;
        count += 1;
        if (count > 24) return error.InvalidMnemonic;
        value = (value << 11) | index;
    }

    var valid = false;
    for (valid_word_counts) |allowed| {
        if (count == allowed) valid = true;
    }
    if (!valid) return error.InvalidMnemonic;

    const total_bits = count * 11;
    const checksum_bits = total_bits / 33;
    const entropy_len = (total_bits - checksum_bits) / 8;
    if (out.len < entropy_len) return error.BufferTooSmall;

    const checksum_mask: u264 = (@as(u264, 1) << @intCast(checksum_bits)) - 1;
    const checksum: u8 = @intCast(value & checksum_mask);
    const entropy_value = value >> @intCast(checksum_bits);

    // write big-endian (out[0] is the most significant byte)
    var i: usize = 0;
    while (i < entropy_len) : (i += 1) {
        const shift: u9 = @intCast(8 * (entropy_len - 1 - i));
        out[i] = @truncate(entropy_value >> shift);
    }

    var digest: [32]u8 = undefined;
    hashes.Sha256.hash(out[0..entropy_len], &digest, .{});
    const expected: u8 = digest[0] >> @intCast(8 - checksum_bits);
    if (checksum != expected) return error.ChecksumMismatch;

    return out[0..entropy_len];
}

/// Whether this is a valid mnemonic.
pub fn isValid(mnemonic: []const u8) bool {
    var buf: [32]u8 = undefined;
    _ = mnemonicToEntropy(&buf, mnemonic) catch return false;
    return true;
}

/// Derive a 64-byte seed with PBKDF2-HMAC-SHA512.
///
/// The passphrase is optional (an empty string is allowed). The mnemonic's vocabulary and
/// checksum are not validated (call `mnemonicToEntropy` first if validation is needed).
pub fn mnemonicToSeed(out: *[64]u8, mnemonic: []const u8, passphrase: []const u8) Error!void {
    if (!isAscii(mnemonic) or !isAscii(passphrase)) return error.UnsupportedNormalization;

    var normalized: [24 * 9]u8 = undefined;
    defer std.crypto.secureZero(u8, &normalized);
    const mnemonic_normalized = try normalizeWhitespace(&normalized, mnemonic);
    if (passphrase.len > 128) return error.BufferTooSmall;

    var salt: [8 + 128]u8 = undefined;
    defer std.crypto.secureZero(u8, &salt);
    @memcpy(salt[0..8], "mnemonic");
    @memcpy(salt[8..][0..passphrase.len], passphrase);
    const salt_slice = salt[0 .. 8 + passphrase.len];

    // rounds=2048 with 64-byte output is always valid, so no error can occur
    pbkdf2(out, mnemonic_normalized, salt_slice, 2048, HmacSha512) catch return error.InvalidMnemonic;
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

/// Collapse runs of whitespace into one and trim leading/trailing whitespace.
fn normalizeWhitespace(out: []u8, text: []const u8) Error![]const u8 {
    var pos: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |word| {
        if (pos != 0) {
            if (pos >= out.len) return error.BufferTooSmall;
            out[pos] = ' ';
            pos += 1;
        }
        if (pos + word.len > out.len) return error.BufferTooSmall;
        @memcpy(out[pos..][0..word.len], word);
        pos += word.len;
    }
    return out[0..pos];
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "word list has 2048 words and starts and ends with known words" {
    const words = wordlist();
    try testing.expectEqual(@as(usize, 2048), words.len);
    try testing.expectEqualStrings("abandon", words[0]);
    try testing.expectEqualStrings("zoo", words[2047]);
    try testing.expectEqual(@as(?u11, 0), wordIndex("abandon"));
    try testing.expectEqual(@as(?u11, 2047), wordIndex("zoo"));
    try testing.expectEqual(@as(?u11, null), wordIndex("notaword"));
}

test "mnemonic can be generated from entropy and converted back" {
    var mnemonic: [256]u8 = undefined;
    var entropy: [32]u8 = undefined;

    // all-zero entropy yields a known mnemonic
    const zeros: [16]u8 = @splat(0);
    const text = try entropyToMnemonic(&mnemonic, &zeros);
    try testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        text,
    );

    const round_trip = try mnemonicToEntropy(&entropy, text);
    try testing.expectEqualSlices(u8, &zeros, round_trip);

    // Round-trip asymmetric entropy too, to detect byte-order mistakes
    // (all-identical entropy has no detection power since reversing it gives the same result)
    var asymmetric: [32]u8 = undefined;
    for (&asymmetric, 0..) |*byte, i| byte.* = @intCast(i + 1);
    for ([_]usize{ 16, 20, 24, 28, 32 }) |length| {
        const words = try entropyToMnemonic(&mnemonic, asymmetric[0..length]);
        const back = try mnemonicToEntropy(&entropy, words);
        try testing.expectEqualSlices(u8, asymmetric[0..length], back);
    }
}

test "rejects invalid word counts, vocabulary and checksums" {
    var entropy: [32]u8 = undefined;
    try testing.expectError(
        error.InvalidMnemonic,
        mnemonicToEntropy(&entropy, "abandon abandon abandon"),
    );
    try testing.expectError(
        error.InvalidMnemonic,
        mnemonicToEntropy(&entropy, "notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword notaword"),
    );
    // changing the last word from about to abandon breaks the checksum
    try testing.expectError(
        error.ChecksumMismatch,
        mnemonicToEntropy(&entropy, "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon"),
    );
    try testing.expectEqual(false, isValid("abandon abandon abandon"));
}

test "entropy length validation" {
    var mnemonic: [256]u8 = undefined;
    const fifteen: [15]u8 = @splat(0);
    try testing.expectError(error.InvalidMnemonic, entropyToMnemonic(&mnemonic, &fifteen));
}

test "known passphrase vector (TREZOR example from the BIP39 spec)" {
    var seed: [64]u8 = undefined;
    try mnemonicToSeed(
        &seed,
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "TREZOR",
    );
    const expected = "c55257c360c07c72029aebc1b53c05ed0362ada38ead3e3e9efa3708e53495531f09a6987599d18264c1e1c92f2cf141630c7a3c4ab7c81b2f001698e7463b04";
    var hex: [128]u8 = undefined;
    const encoded = std.fmt.bytesToHex(seed, .lower);
    @memcpy(hex[0..encoded.len], &encoded);
    try testing.expectEqualStrings(expected, &hex);
}

test "whitespace variations do not affect the seed" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var seed_a: [64]u8 = undefined;
    var seed_b: [64]u8 = undefined;
    try mnemonicToSeed(&seed_a, mnemonic, "");
    try mnemonicToSeed(&seed_b, "  abandon  abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon   about  ", "");
    try testing.expectEqualSlices(u8, &seed_a, &seed_b);
}

test "explicitly rejects non-ASCII (NFKD is not implemented)" {
    var seed: [64]u8 = undefined;
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    try testing.expectError(error.UnsupportedNormalization, mnemonicToSeed(&seed, mnemonic, "パスフレーズ"));
}
