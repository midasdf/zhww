//! Entropy generation and combination (dice, camera, TRNG).
//!
//! **Design policy**
//! - Dice rolls are a **required** input. Camera image entropy and the SoC TRNG are
//!   "additional contributions", not replacements for the dice ([docs/02-architecture.md] §3.1)
//! - All inputs are combined with HKDF-SHA256 (RFC 5869). Even if a single source is biased,
//!   the output stays unpredictable as long as the others are sound
//! - The path from rolls to the BIP39 mnemonic is **recomputable**. So that users can verify
//!   it themselves from their dice record, randomness is used only for the inputs
//!
//! Reference: RFC 5869 (HKDF), https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("../crypto/hashes.zig");
const bip39 = @import("bip39.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// Number of rolls needed for a 12-word mnemonic (6^50 ≒ 2^129 > 2^128).
pub const rolls_for_12_words: usize = 50;
/// Number of rolls needed for a 24-word mnemonic (6^99 ≒ 2^255.9).
pub const rolls_for_24_words: usize = 99;
/// Maximum number of rolls that can be stored.
pub const max_rolls: usize = 128;

/// Constants for domain separation of entropy combination.
const hkdf_salt = "zhww-entropy-v1";
const hkdf_info = "bip39-entropy";

// ---------------------------------------------------------------- HKDF

/// HKDF-Extract (RFC 5869 §2.2).
pub fn hkdfExtract(prk: *[32]u8, salt: []const u8, ikm: []const u8) void {
    HmacSha256.create(prk, ikm, salt);
}

/// HKDF-Expand (RFC 5869 §2.3).
pub fn hkdfExpand(out: []u8, prk: [32]u8, info: []const u8) Error!void {
    if (out.len > 255 * 32) return error.BufferTooSmall;

    var previous: [32]u8 = undefined;
    var have_previous = false;
    var offset: usize = 0;
    var counter: u8 = 1;

    while (offset < out.len) : (counter += 1) {
        var ctx = HmacSha256.init(&prk);
        if (have_previous) ctx.update(&previous);
        ctx.update(info);
        ctx.update(&[_]u8{counter});

        var block: [32]u8 = undefined;
        ctx.final(&block);

        const take = @min(@as(usize, 32), out.len - offset);
        @memcpy(out[offset..][0..take], block[0..take]);
        previous = block;
        have_previous = true;
        offset += take;
    }
}

// ---------------------------------------------------------------- dice

/// Record of dice rolls.
pub const Dice = struct {
    rolls: [max_rolls]u8 = undefined,
    len: usize = 0,

    /// Append one roll (1-6).
    pub fn roll(self: *Dice, value: u8) Error!void {
        if (value < 1 or value > 6) return error.InvalidEncoding;
        if (self.len >= max_rolls) return error.BufferTooSmall;
        self.rolls[self.len] = value;
        self.len += 1;
    }

    /// Ingest rolls from a string (e.g. "123456").
    pub fn rollString(self: *Dice, text: []const u8) Error!void {
        for (text) |ch| {
            if (ch < '1' or ch > '6') return error.InvalidEncoding;
            try self.roll(ch - '0');
        }
    }

    /// Turn the rolls into a 64-byte big-endian value as a large base-6 integer.
    ///
    /// The roll limit is 128, so 6^128 ≒ 2^331 always fits in a u512.
    pub fn toBytes(self: Dice) [64]u8 {
        var value: u512 = 0;
        for (self.rolls[0..self.len]) |roll_value| {
            value = value * 6 + (roll_value - 1);
        }
        var out: [64]u8 = undefined;
        std.mem.writeInt(u512, &out, value, .big);
        return out;
    }

    /// Return the recorded rolls as a string (for verification and record keeping).
    pub fn format(self: Dice, out: []u8) Error![]const u8 {
        if (out.len < self.len) return error.BufferTooSmall;
        for (self.rolls[0..self.len], 0..) |value, i| {
            out[i] = '0' + value;
        }
        return out[0..self.len];
    }
};

// ---------------------------------------------------------------- combination

/// Combine inputs such as dice, camera and TRNG to produce BIP39 entropy.
///
/// `out.len` is 16/20/24/28/32 bytes (corresponding to the BIP39 word counts).
/// **No dynamic memory** (fixed-size buffers only).
pub fn combine(
    out: []u8,
    dice: Dice,
    extra_sources: []const []const u8,
) Error!void {
    if (out.len != 16 and out.len != 20 and out.len != 24 and out.len != 28 and out.len != 32) {
        return error.InvalidMnemonic;
    }
    if (dice.len < 1) return error.UnsupportedNormalization; // dice are required

    // lay out the dice and all additional sources as HKDF-Extract input
    var ikm: [512]u8 = undefined;
    const dice_bytes = dice.toBytes();
    @memcpy(ikm[0..64], &dice_bytes);
    var len: usize = 64;
    for (extra_sources) |source| {
        if (len + source.len > ikm.len) return error.BufferTooSmall;
        @memcpy(ikm[len..][0..source.len], source);
        len += source.len;
    }

    var prk: [32]u8 = undefined;
    hkdfExtract(&prk, hkdf_salt, ikm[0..len]);
    var derived: [32]u8 = undefined;
    try hkdfExpand(&derived, prk, hkdf_info);

    @memcpy(out, derived[0..out.len]);
}

/// Build a mnemonic from rolls and additional sources.
///
/// `word_count` is 12 / 15 / 18 / 21 / 24.
pub fn mnemonicFromDice(
    out: []u8,
    dice: Dice,
    extra_sources: []const []const u8,
    word_count: usize,
) Error![]u8 {
    const entropy_len: usize = switch (word_count) {
        12 => 16,
        15 => 20,
        18 => 24,
        21 => 28,
        24 => 32,
        else => return error.InvalidMnemonic,
    };
    var entropy: [32]u8 = undefined;
    try combine(entropy[0..entropy_len], dice, extra_sources);
    return bip39.entropyToMnemonic(out, entropy[0..entropy_len]);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn hexToFixed(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "HKDF-SHA256 (RFC 5869 test case 1)" {
    const ikm: [22]u8 = @splat(0x0b);
    const salt = hexToFixed(13, "000102030405060708090a0b0c");
    const info = hexToFixed(10, "f0f1f2f3f4f5f6f7f8f9");

    var prk: [32]u8 = undefined;
    hkdfExtract(&prk, &salt, &ikm);
    const expected_prk = hexToFixed(32, "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5");
    try testing.expectEqualSlices(u8, &expected_prk, &prk);

    var okm: [42]u8 = undefined;
    try hkdfExpand(&okm, prk, &info);
    const expected_okm = hexToFixed(
        42,
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865",
    );
    try testing.expectEqualSlices(u8, &expected_okm, &okm);
}

test "HKDF-SHA256 (RFC 5869 test case 3: empty salt and info)" {
    const ikm: [22]u8 = @splat(0x0b);

    var prk: [32]u8 = undefined;
    hkdfExtract(&prk, "", &ikm);
    const expected_prk = hexToFixed(32, "19ef24a32c717b167f33a91d6f648bdf96596776afdb6377ac434c1c293ccb04");
    try testing.expectEqualSlices(u8, &expected_prk, &prk);

    var okm: [42]u8 = undefined;
    try hkdfExpand(&okm, prk, "");
    const expected_okm = hexToFixed(
        42,
        "8da4e775a563c18f715f802a063c5a31b8a11f5c5ee1879ec3454e5f3c738d2d9d201395faa4b61a96c8",
    );
    try testing.expectEqualSlices(u8, &expected_okm, &okm);
}

test "dice roll validation" {
    var dice: Dice = .{};
    try dice.roll(1);
    try dice.roll(6);
    try testing.expectEqual(@as(usize, 2), dice.len);

    try testing.expectError(error.InvalidEncoding, dice.roll(0));
    try testing.expectError(error.InvalidEncoding, dice.roll(7));

    var text: [8]u8 = undefined;
    try dice.rollString("345");
    try testing.expectEqualStrings("16345", try dice.format(&text));

    try testing.expectError(error.InvalidEncoding, dice.rollString("17"));
}

test "50 rolls produce a 12-word mnemonic and 99 rolls a 24-word one" {
    var dice: Dice = .{};
    var checked_12 = false;

    var i: usize = 0;
    while (i < rolls_for_24_words) : (i += 1) {
        try dice.roll(@intCast(1 + (i * 7 + 3) % 6));

        if (dice.len == rolls_for_12_words) {
            var mnemonic12: [256]u8 = undefined;
            const text12 = try mnemonicFromDice(&mnemonic12, dice, &.{}, 12);
            try testing.expectEqual(@as(usize, 12), std.mem.count(u8, text12, " ") + 1);
            try testing.expect(bip39.isValid(text12));
            checked_12 = true;
        }
    }
    try testing.expect(checked_12);

    var mnemonic24: [256]u8 = undefined;
    const text24 = try mnemonicFromDice(&mnemonic24, dice, &.{}, 24);
    try testing.expectEqual(@as(usize, 24), std.mem.count(u8, text24, " ") + 1);
    try testing.expect(bip39.isValid(text24));
}

test "the same rolls and extra inputs give the same mnemonic (recomputable)" {
    var dice: Dice = .{};
    try dice.rollString("12345612345612345612345612345612345612345612345612");

    const camera = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const trng = [_]u8{ 0x11, 0x22, 0x33, 0x44 };

    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    const a = try mnemonicFromDice(&first, dice, &.{ &camera, &trng }, 12);
    const b = try mnemonicFromDice(&second, dice, &.{ &camera, &trng }, 12);
    try testing.expectEqualStrings(a, b);
}

test "different rolls give a different mnemonic" {
    var dice_a: Dice = .{};
    var dice_b: Dice = .{};
    try dice_a.rollString("12345612345612345612345612345612345612345612345612");
    try dice_b.rollString("12345612345612345612345612345612345612345612345613");

    var first: [256]u8 = undefined;
    var second: [256]u8 = undefined;
    const a = try mnemonicFromDice(&first, dice_a, &.{}, 12);
    const b = try mnemonicFromDice(&second, dice_b, &.{}, 12);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "additional entropy sources affect the result" {
    var dice: Dice = .{};
    try dice.rollString("12345612345612345612345612345612345612345612345612");

    const camera = [_]u8{ 0xAA, 0xBB };

    var without: [256]u8 = undefined;
    var with_camera: [256]u8 = undefined;
    const a = try mnemonicFromDice(&without, dice, &.{}, 12);
    const b = try mnemonicFromDice(&with_camera, dice, &.{&camera}, 12);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "rejects input without dice (dice are required)" {
    const empty: Dice = .{};
    var entropy: [16]u8 = undefined;
    try testing.expectError(error.UnsupportedNormalization, combine(&entropy, empty, &.{}));
}

test "entropy length validation" {
    var dice: Dice = .{};
    try dice.rollString("123456");
    var wrong: [15]u8 = undefined;
    try testing.expectError(error.InvalidMnemonic, combine(&wrong, dice, &.{}));
}

test "end-to-end from dice to mnemonic, seed and address" {
    var dice: Dice = .{};
    try dice.rollString(
        "13524613524613524613524613524613524613524613524613",
    );

    var mnemonic: [256]u8 = undefined;
    const text = try mnemonicFromDice(&mnemonic, dice, &.{}, 12);
    try testing.expect(bip39.isValid(text));

    var seed: [64]u8 = undefined;
    try bip39.mnemonicToSeed(&seed, text, "");

    const bip32 = @import("../derive/bip32.zig");
    const address = @import("../../apps/btc/address.zig");
    const master = try bip32.ExtendedKey.fromSeed(&seed, .zprv);
    const node = try master.derivePath("m/84'/0'/0'/0/0");
    var address_buf: [90]u8 = undefined;
    const addr = try address.p2wpkh(&address_buf, try node.publicKey(), .mainnet);
    try testing.expect(std.mem.startsWith(u8, addr, "bc1q"));
}
