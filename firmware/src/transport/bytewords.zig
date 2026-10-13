//! Bytewords (BCR-2020-012): encodes binary data as a sequence of four-letter English words.
//!
//! **Design policy**
//! - The vocabulary is the 256 words from the spec. Every word is four letters and is uniquely
//!   distinguishable by first+last, first three, or last three letters (verified by tests).
//! - The checksum is the body's CRC-32 appended at the end as **four big-endian (network order)
//!   bytes**. No API returns the body without verifying it.
//! - Case-insensitive (QR codes use uppercase; URIs and screen output use lowercase).
//! - No memory allocation, because no secrets are handled (the caller provides the output).
//! - Every malformed input (word outside the vocabulary, odd length, checksum mismatch, too short)
//!   is rejected with an error.
//!
//! Reference: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-012-bytewords.md
//!
//! Test vector sources (all are third-party public vectors, used as-is):
//!   - BCR-2020-012 §Example/Test Vector (a 16-byte seed) and §Brutal Encoding
//!   - the bc-ur (C++ reference implementation) test/test.cpp,
//!     test_crc32 / test_bytewords_1 / test_bytewords_2
//!     https://github.com/BlockchainCommons/bc-ur/blob/master/test/test.cpp
//!   - test_ur in bc-ur-rust src/ur.rs ("ur:test/lsadaoaxjygonesw")
//!     https://github.com/BlockchainCommons/bc-ur-rust/blob/master/src/ur.rs
//!   - the BCR-2024-001 (MUR) §CRC-32 Checksum test vector
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// Encoding style.
pub const Style = enum {
    /// Words separated by spaces (for humans to read, or to stamp into metal).
    standard,
    /// Words separated by hyphens (embeddable in a URI).
    uri,
    /// Only the first and last letter of each word, concatenated (for QR codes; same length as hex).
    minimal,
};

/// Number of words in the vocabulary (one byte = one word).
pub const alphabet_size = 256;
/// Letters per word (all words are four letters).
pub const word_len = 4;
/// Letters in the minimal representation (first + last).
pub const minimal_len = 2;
/// Checksum length in bytes (CRC-32).
pub const checksum_len = 4;

/// The BCR-2020-012 vocabulary (alphabetical, all 256 words).
/// As in the spec, the comment at the start of each line gives the first byte value of that line.
pub const words: [alphabet_size][]const u8 = .{
    "able", "acid", "also", "apex", "aqua", "arch", "atom", "aunt", // 0x00
    "away", "axis", "back", "bald", "barn", "belt", "beta", "bias", // 0x08
    "blue", "body", "brag", "brew", "bulb", "buzz", "calm", "cash", // 0x10
    "cats", "chef", "city", "claw", "code", "cola", "cook", "cost", // 0x18
    "crux", "curl", "cusp", "cyan", "dark", "data", "days", "deli", // 0x20
    "dice", "diet", "door", "down", "draw", "drop", "drum", "dull", // 0x28
    "duty", "each", "easy", "echo", "edge", "epic", "even", "exam", // 0x30
    "exit", "eyes", "fact", "fair", "fern", "figs", "film", "fish", // 0x38
    "fizz", "flap", "flew", "flux", "foxy", "free", "frog", "fuel", // 0x40
    "fund", "gala", "game", "gear", "gems", "gift", "girl", "glow", // 0x48
    "good", "gray", "grim", "guru", "gush", "gyro", "half", "hang", // 0x50
    "hard", "hawk", "heat", "help", "high", "hill", "holy", "hope", // 0x58
    "horn", "huts", "iced", "idea", "idle", "inch", "inky", "into", // 0x60
    "iris", "iron", "item", "jade", "jazz", "join", "jolt", "jowl", // 0x68
    "judo", "jugs", "jump", "junk", "jury", "keep", "keno", "kept", // 0x70
    "keys", "kick", "kiln", "king", "kite", "kiwi", "knob", "lamb", // 0x78
    "lava", "lazy", "leaf", "legs", "liar", "limp", "lion", "list", // 0x80
    "logo", "loud", "love", "luau", "luck", "lung", "main", "many", // 0x88
    "math", "maze", "memo", "menu", "meow", "mild", "mint", "miss", // 0x90
    "monk", "nail", "navy", "need", "news", "next", "noon", "note", // 0x98
    "numb", "obey", "oboe", "omit", "onyx", "open", "oval", "owls", // 0xa0
    "paid", "part", "peck", "play", "plus", "poem", "pool", "pose", // 0xa8
    "puff", "puma", "purr", "quad", "quiz", "race", "ramp", "real", // 0xb0
    "redo", "rich", "road", "rock", "roof", "ruby", "ruin", "runs", // 0xb8
    "rust", "safe", "saga", "scar", "sets", "silk", "skew", "slot", // 0xc0
    "soap", "solo", "song", "stub", "surf", "swan", "taco", "task", // 0xc8
    "taxi", "tent", "tied", "time", "tiny", "toil", "tomb", "toys", // 0xd0
    "trip", "tuna", "twin", "ugly", "undo", "unit", "urge", "user", // 0xd8
    "vast", "very", "veto", "vial", "vibe", "view", "visa", "void", // 0xe0
    "vows", "wall", "wand", "warm", "wasp", "wave", "waxy", "webs", // 0xe8
    "what", "when", "whiz", "wolf", "work", "yank", "yawn", "yell", // 0xf0
    "yoga", "yurt", "zaps", "zero", "zest", "zinc", "zone", "zoom", // 0xf8
};

/// The four-letter word for a byte value.
pub fn wordFor(byte: u8) []const u8 {
    return words[byte];
}

/// The minimal representation for a byte value (first letter of the word + last letter).
pub fn minimalFor(byte: u8) [minimal_len]u8 {
    const word = words[byte];
    return .{ word[0], word[word_len - 1] };
}

/// Incremental CRC-32 update (pass 0xFFFFFFFF as the initial value and invert at the end).
fn crc32Update(state: u32, data: []const u8) u32 {
    var crc = state;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

/// CRC-32 (IEEE 802.3 / zlib).
///
/// Reflected polynomial 0xEDB88320, initial value 0xFFFFFFFF, all bits inverted at the end.
/// BCR-2020-012 refers to "MSDN: 32-Bit CRC Algorithm".
///
/// Known values (test_crc32 in bc-ur test/test.cpp and BCR-2024-001):
///   "Wolf" → 0x598c84dc, "Hello, world!" → 0xebe6c6e6
pub fn crc32(data: []const u8) u32 {
    return ~crc32Update(0xFFFFFFFF, data);
}

/// The CRC-32 as four big-endian (network order) bytes.
fn checksumBytes(checksum: u32) [checksum_len]u8 {
    var out: [checksum_len]u8 = undefined;
    std.mem.writeInt(u32, &out, checksum, .big);
    return out;
}

/// String length of `data_len` bytes encoded as a body (checksum excluded).
fn bodyLength(data_len: usize, style: Style) usize {
    return switch (style) {
        .minimal => std.math.mul(usize, data_len, minimal_len) catch std.math.maxInt(usize),
        .standard, .uri => if (data_len == 0) 0 else blk: {
            const words_len = std.math.mul(usize, data_len, word_len) catch break :blk std.math.maxInt(usize);
            break :blk std.math.add(usize, words_len, data_len - 1) catch std.math.maxInt(usize);
        },
    };
}

/// String length of `data_len` bytes encoded with a checksum.
///
/// Used to size the output buffer.
pub fn encodedLength(data_len: usize, style: Style) usize {
    const total = std.math.add(usize, data_len, checksum_len) catch return std.math.maxInt(usize);
    return bodyLength(total, style);
}

/// Writes one word (or minimal representation). `pos` is the write position.
/// Assumes the caller has checked the buffer length with `encodedLength`.
fn appendWord(out: []u8, pos: *usize, byte: u8, style: Style, first: bool) void {
    switch (style) {
        .minimal => {
            const minimal = minimalFor(byte);
            out[pos.*] = minimal[0];
            out[pos.* + 1] = minimal[1];
            pos.* += minimal_len;
        },
        .standard, .uri => {
            if (!first) {
                out[pos.*] = if (style == .standard) ' ' else '-';
                pos.* += 1;
            }
            @memcpy(out[pos.*..][0..word_len], wordFor(byte));
            pos.* += word_len;
        },
    }
}

/// Encodes without a checksum.
///
/// Use `encodeWithChecksum` except when checking the vocabulary table.
pub fn encode(out: []u8, data: []const u8, style: Style) Error![]u8 {
    if (out.len < bodyLength(data.len, style)) return error.BufferTooSmall;

    var pos: usize = 0;
    for (data, 0..) |byte, i| appendWord(out, &pos, byte, style, i == 0);
    return out[0..pos];
}

/// Encodes with the body's CRC-32 (four bytes, big-endian) appended at the end.
///
/// This is the BCR-2020-012 Bytewords body. The UR `<message>` part is built with it too.
pub fn encodeWithChecksum(out: []u8, data: []const u8, style: Style) Error![]u8 {
    return encodeWithChecksumParts(out, &.{data}, style);
}

/// Encodes several byte strings as if concatenated (no intermediate copy is made).
///
/// Used when the CBOR header and body are held separately (`encodeSingleByteString` in `ur.zig`).
pub fn encodeWithChecksumParts(out: []u8, parts: []const []const u8, style: Style) Error![]u8 {
    var total: usize = 0;
    for (parts) |part| total = std.math.add(usize, total, part.len) catch return error.BufferTooSmall;
    if (out.len < encodedLength(total, style)) return error.BufferTooSmall;

    var pos: usize = 0;
    var index: usize = 0;
    for (parts) |part| {
        for (part) |byte| {
            appendWord(out, &pos, byte, style, index == 0);
            index += 1;
        }
    }

    var crc: u32 = 0xFFFFFFFF;
    for (parts) |part| crc = crc32Update(crc, part);
    const checksum = checksumBytes(~crc);
    for (checksum, 0..) |byte, i| appendWord(out, &pos, byte, style, (total + i) == 0);
    return out[0..pos];
}

/// Decoding work state.
///
/// The last four bytes are the checksum, so only bytes that are certainly not part of the
/// checksum are written to `out` (no four bytes of slack are required in the body buffer).
const DecoderState = struct {
    out: []u8,
    body_len: usize = 0,
    total: usize = 0,
    tail: [checksum_len]u8 = undefined,

    fn push(self: *DecoderState, byte: u8) Error!void {
        if (self.total >= checksum_len) {
            if (self.body_len >= self.out.len) return error.BufferTooSmall;
            self.out[self.body_len] = self.tail[0];
            self.body_len += 1;
            self.tail[0] = self.tail[1];
            self.tail[1] = self.tail[2];
            self.tail[2] = self.tail[3];
            self.tail[3] = byte;
        } else {
            self.tail[self.total] = byte;
        }
        self.total += 1;
    }

    fn finish(self: *DecoderState) Error![]u8 {
        // Require four checksum bytes plus at least one body byte.
        if (self.total < checksum_len + 1) return error.Truncated;
        var expected: [checksum_len]u8 = undefined;
        std.mem.writeInt(u32, &expected, crc32(self.out[0..self.body_len]), .big);
        if (!std.mem.eql(u8, &expected, &self.tail)) return error.ChecksumMismatch;
        return self.out[0..self.body_len];
    }
};

fn sameLetters(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// Converts a four-letter word to a byte value. error.InvalidEncoding if it is not in the vocabulary.
fn lookupWord(token: []const u8) Error!u8 {
    if (token.len != word_len) return error.InvalidEncoding;
    for (words, 0..) |word, i| {
        if (sameLetters(word, token)) return @intCast(i);
    }
    return error.InvalidEncoding;
}

/// Converts a two-letter minimal representation (first + last) to a byte value.
fn lookupMinimal(token: []const u8) Error!u8 {
    if (token.len != minimal_len) return error.InvalidEncoding;
    const first = std.ascii.toLower(token[0]);
    const last = std.ascii.toLower(token[minimal_len - 1]);
    for (words, 0..) |word, i| {
        if (word[0] == first and word[word_len - 1] == last) return @intCast(i);
    }
    return error.InvalidEncoding;
}

/// Converts three letters (first three or last three) to a byte value.
///
/// The first-three and last-three sets can overlap ("ice" is both the first three letters of
/// iced and the last three of dice). **When in doubt, do not guess**: return error.InvalidEncoding.
fn lookupTriple(token: []const u8) Error!u8 {
    if (token.len != 3) return error.InvalidEncoding;
    var found: ?u8 = null;
    for (words, 0..) |word, i| {
        if (sameLetters(word[0..3], token) or sameLetters(word[1..4], token)) {
            const byte: u8 = @intCast(i);
            if (found) |previous| {
                if (previous != byte) return error.InvalidEncoding;
            } else {
                found = byte;
            }
        }
    }
    return found orelse error.InvalidEncoding;
}

/// Verifies the checksum and writes the body, with the checksum removed, to `out`.
///
/// - standard / uri: split into words on the separator (space / hyphen); runs of separators are ignored.
/// - minimal: split into pairs of letters (odd length is error.InvalidEncoding).
/// - Words outside the vocabulary, too-short input, and checksum mismatches are all rejected with an error.
pub fn decode(out: []u8, text: []const u8, style: Style) Error![]u8 {
    var state = DecoderState{ .out = out };

    switch (style) {
        .minimal => {
            if (text.len % minimal_len != 0) return error.InvalidEncoding;
            var i: usize = 0;
            while (i < text.len) : (i += minimal_len) {
                try state.push(try lookupMinimal(text[i..][0..minimal_len]));
            }
        },
        .standard, .uri => {
            const separator: u8 = if (style == .standard) ' ' else '-';
            var tokens = std.mem.tokenizeScalar(u8, text, separator);
            while (tokens.next()) |token| {
                try state.push(try lookupWord(token));
            }
        },
    }
    return state.finish();
}

/// Normalizes a word copied by hand or read by OCR into a byte value.
///
/// Thanks to the vocabulary criteria (BCR-2020-012 §Word selection criteria), a word can be
/// identified uniquely by the word itself (four letters) or by first+last (two letters).
/// Three letters (first three / last three) are accepted as well, but if the two collide,
/// error.InvalidEncoding is returned instead of guessing.
pub fn canonicalize(token: []const u8) Error!u8 {
    return switch (token.len) {
        minimal_len => lookupMinimal(token),
        3 => lookupTriple(token),
        word_len => lookupWord(token),
        else => error.InvalidEncoding,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// BCR-2020-012 §Example/Test Vector: the 16-byte seed as a tagged-CBOR body (27 bytes).
const spec_body_hex = "d99d6ca20150c7098580125e2ab0981253468b2dbc5202c11947da";

fn decodeHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

test "the vocabulary satisfies the BCR-2020-012 criteria" {
    try testing.expectEqual(@as(usize, 256), words.len);

    // All are four lowercase ASCII letters, in alphabetical order.
    for (words, 0..) |word, i| {
        try testing.expectEqual(@as(usize, word_len), word.len);
        for (word) |c| try testing.expect(c >= 'a' and c <= 'z');
        if (i > 0) try testing.expect(std.mem.order(u8, words[i - 1], word) == .lt);
    }

    // First+last, first three letters, and last three letters are all unique.
    for (words, 0..) |a, i| {
        for (words[i + 1 ..]) |b| {
            try testing.expect(!(a[0] == b[0] and a[3] == b[3]));
            try testing.expect(!std.mem.eql(u8, a[0..3], b[0..3]));
            try testing.expect(!std.mem.eql(u8, a[1..4], b[1..4]));
        }
    }
}

test "matches known CRC-32 values" {
    // bc-ur test/test.cpp test_crc32
    try testing.expectEqual(@as(u32, 0xebe6c6e6), crc32("Hello, world!"));
    // BCR-2024-001 §CRC-32 Checksum (test vector from the Swift reference implementation)
    try testing.expectEqual(@as(u32, 0x598c84dc), crc32("Wolf"));

    // Body and checksum from BCR-2020-012 §Example/Test Vector
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0xc904f40b), crc32(decodeHex(&buf, spec_body_hex)));

    // Payload and checksum from BCR-2020-012 §Brutal Encoding
    try testing.expectEqual(
        @as(u32, 0xfeac0dea),
        crc32(decodeHex(&buf, "c7098580125e2ab0981253468b2dbc52")),
    );

    // CBOR [1, 2, 3] from bc-ur-rust test_ur (the last four bytes of "ur:test/lsadaoaxjygonesw")
    try testing.expectEqual(@as(u32, 0x74559fc6), crc32(decodeHex(&buf, "83010203")));
}

test "matches the BCR-2020-012 examples (standard / uri / minimal)" {
    var body_buf: [64]u8 = undefined;
    const body = decodeHex(&body_buf, spec_body_hex);

    const expected_standard =
        "tuna next jazz oboe acid good slot axis limp lava brag holy door puff monk brag " ++
        "guru frog luau drop roof grim also safe chef fuel twin solo aqua work bald";
    const expected_uri =
        "tuna-next-jazz-oboe-acid-good-slot-axis-limp-lava-brag-holy-door-puff-monk-brag-" ++
        "guru-frog-luau-drop-roof-grim-also-safe-chef-fuel-twin-solo-aqua-work-bald";
    const expected_minimal =
        "tantjzoeadgdstaslplabghydrpfmkbggufgludprfgmaosecffltnsoaawkbd";

    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(expected_standard, try encodeWithChecksum(&out, body, .standard));
    try testing.expectEqualStrings(expected_uri, try encodeWithChecksum(&out, body, .uri));
    try testing.expectEqualStrings(expected_minimal, try encodeWithChecksum(&out, body, .minimal));

    // Round trip (27-byte body; the checksum is stripped)
    var decoded: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 27), (try decode(&decoded, expected_standard, .standard)).len);
    try testing.expectEqualStrings(body, try decode(&decoded, expected_standard, .standard));
    try testing.expectEqualStrings(body, try decode(&decoded, expected_uri, .uri));
    try testing.expectEqualStrings(body, try decode(&decoded, expected_minimal, .minimal));
}

test "matches the BCR-2020-012 brutal example" {
    var body_buf: [64]u8 = undefined;
    const payload = decodeHex(&body_buf, "c7098580125e2ab0981253468b2dbc52");

    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "slot axis limp lava brag holy door puff monk brag guru frog luau drop roof grim " ++
            "zone plus belt wand",
        try encodeWithChecksum(&out, payload, .standard),
    );
    try testing.expectEqualStrings(
        "staslplabghydrpfmkbggufgludprfgmzepsbtwd",
        try encodeWithChecksum(&out, payload, .minimal),
    );

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(payload, try decode(&decoded, "staslplabghydrpfmkbggufgludprfgmzepsbtwd", .minimal));
}

test "bc-ur Bytewords test vector 1" {
    // bc-ur test/test.cpp test_bytewords_1
    const input = [_]u8{ 0, 1, 2, 128, 255 };

    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "able acid also lava zoom jade need echo taxi",
        try encodeWithChecksum(&out, &input, .standard),
    );
    try testing.expectEqualStrings(
        "able-acid-also-lava-zoom-jade-need-echo-taxi",
        try encodeWithChecksum(&out, &input, .uri),
    );
    try testing.expectEqualStrings(
        "aeadaolazmjendeoti",
        try encodeWithChecksum(&out, &input, .minimal),
    );

    var decoded: [8]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, "able acid also lava zoom jade need echo taxi", .standard));
    try testing.expectEqualStrings(&input, try decode(&decoded, "able-acid-also-lava-zoom-jade-need-echo-taxi", .uri));
    try testing.expectEqualStrings(&input, try decode(&decoded, "aeadaolazmjendeoti", .minimal));

    // Input differing only in the checksum (zoom taxi -> zero wolf).
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "able acid also lava zero jade need echo wolf", .standard),
    );
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "able-acid-also-lava-zero-jade-need-echo-wolf", .uri),
    );
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "aeadaolazojendeowf", .minimal),
    );

    // Input with a single word leaves the body empty, so it is rejected.
    try testing.expectError(error.Truncated, decode(&decoded, "wolf", .standard));
    try testing.expectError(error.Truncated, decode(&decoded, "", .standard));
    try testing.expectError(error.Truncated, decode(&decoded, "", .minimal));
}

test "bc-ur Bytewords test vector 2 (100 bytes)" {
    // bc-ur test/test.cpp test_bytewords_2
    const input = [100]u8{
        0xf5, 0xd7, 0x14, 0xc6, 0xf1, 0xeb, 0x45, 0x3b, 0xd1, 0xcd, 0xa5, 0x12, 0x96, 0x9e, 0x74, 0x87,
        0xe5, 0xd4, 0x13, 0x9f, 0x11, 0x25, 0xef, 0xf0, 0xfd, 0x0b, 0x6d, 0xbf, 0x25, 0xf2, 0x26, 0x78,
        0xdf, 0x29, 0x9c, 0xbd, 0xf2, 0xfe, 0x93, 0xcc, 0x42, 0xa3, 0xd8, 0xaf, 0xbf, 0x48, 0xa9, 0x36,
        0x20, 0x3c, 0x90, 0xe6, 0xd2, 0x89, 0xb8, 0xc5, 0x21, 0x71, 0x58, 0x0e, 0x9d, 0x1f, 0xb1, 0x2e,
        0x01, 0x73, 0xcd, 0x45, 0xe1, 0x96, 0x41, 0xeb, 0x3a, 0x90, 0x41, 0xf0, 0x85, 0x45, 0x71, 0xf7,
        0x3f, 0x35, 0xf2, 0xa5, 0xa0, 0x90, 0x1a, 0x0d, 0x4f, 0xed, 0x85, 0x47, 0x52, 0x45, 0xfe, 0xa5,
        0x8a, 0x29, 0x55, 0x18,
    };

    const expected_standard =
        "yank toys bulb skew when warm free fair tent swan open brag mint noon jury list view tiny " ++
        "brew note body data webs what zinc bald join runs data whiz days keys user diet news ruby " ++
        "whiz zone menu surf flew omit trip pose runs fund part even crux fern math visa tied loud " ++
        "redo silk curl jugs hard beta next cost puma drum acid junk swan free very mint flap warm " ++
        "fact math flap what limp free jugs yell fish epic whiz open numb math city belt glow wave " ++
        "limp fuel grim free zone open love diet gyro cats fizz holy city puff";
    const expected_minimal =
        "yktsbbswwnwmfefrttsnonbgmtnnjyltvwtybwnebydawswtzcbdjnrsdawzdsksurdtnsrywzzemusf" ++
        "fwottppersfdptencxfnmhvatdldroskcljshdbantctpadmadjksnfevymtfpwmftmhfpwtlpfejsyl" ++
        "fhecwzonnbmhcybtgwwelpflgmfezeonledtgocsfzhycypf";

    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(expected_standard, try encodeWithChecksum(&out, &input, .standard));
    try testing.expectEqualStrings(expected_minimal, try encodeWithChecksum(&out, &input, .minimal));

    var decoded: [128]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, expected_standard, .standard));
    try testing.expectEqualStrings(&input, try decode(&decoded, expected_minimal, .minimal));
}

test "bc-ur-rust UR test vector (minimal)" {
    // bc-ur-rust src/ur.rs test_ur: minimal Bytewords for CBOR [1, 2, 3].
    var decoded: [8]u8 = undefined;
    const body = try decode(&decoded, "lsadaoaxjygonesw", .minimal);
    var expected: [4]u8 = undefined;
    try testing.expectEqualStrings(decodeHex(&expected, "83010203"), body);

    var out: [64]u8 = undefined;
    const input = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
    try testing.expectEqualStrings("lsadaoaxjygonesw", try encodeWithChecksum(&out, &input, .minimal));
}

test "round trip over every byte value" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    var encoded: [2048]u8 = undefined;
    var decoded: [256]u8 = undefined;

    for ([_]Style{ .standard, .uri, .minimal }) |style| {
        const text = try encodeWithChecksum(&encoded, &input, style);
        try testing.expectEqual(encodedLength(input.len, style), text.len);
        try testing.expectEqualStrings(&input, try decode(&decoded, text, style));
    }

    // One byte at a time (the checksum makes even a one-byte body valid).
    for (0..256) |i| {
        const one = [_]u8{@intCast(i)};
        const text = try encodeWithChecksum(&encoded, &one, .minimal);
        try testing.expectEqual(@as(usize, 10), text.len);
        try testing.expectEqualStrings(&one, try decode(&decoded, text, .minimal));
    }
}

test "accepts uppercase input (for QR codes)" {
    var input: [32]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 256);

    var encoded: [256]u8 = undefined;
    const text = try encodeWithChecksum(&encoded, &input, .minimal);

    var upper: [256]u8 = undefined;
    for (text, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const upper_text = upper[0..text.len];

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, upper_text, .minimal));

    // standard / uri accept uppercase as well.
    const standard = try encodeWithChecksum(&encoded, &input, .standard);
    var upper_standard: [256]u8 = undefined;
    for (standard, 0..) |c, i| upper_standard[i] = std.ascii.toUpper(c);
    try testing.expectEqualStrings(
        &input,
        try decode(&decoded, upper_standard[0..standard.len], .standard),
    );
}

test "rejects malformed input" {
    var out: [128]u8 = undefined;

    // Words outside the vocabulary, words of the wrong length (standard / uri)
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo xxxx", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo taxi extra", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "ableacid also lava zoom jade need echo taxi", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able-acid-also-lava-zoom-jade-need-echo-tax", .uri));
    // Swapped separators (reading uri as standard, and the other way round)
    try testing.expectError(error.InvalidEncoding, decode(&out, "able-acid-also-lava-zoom-jade-need-echo-taxi", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo taxi", .uri));

    // minimal: two letters outside the vocabulary, odd length
    try testing.expectError(error.InvalidEncoding, decode(&out, "aeadaolazmjendeotx", .minimal));
    try testing.expectError(error.InvalidEncoding, decode(&out, "aeadaolazmjendeoti0", .minimal));

    // Too short (not even the four checksum bytes)
    try testing.expectError(error.Truncated, decode(&out, "aeadao", .minimal));
    try testing.expectError(error.Truncated, decode(&out, "able acid also", .standard));

    // Checksum mismatch (the last four bytes differ, not the body)
    try testing.expectError(error.ChecksumMismatch, decode(&out, "aeadaolazmjendeotl", .minimal));
}

test "BufferTooSmall when the body buffer is too small" {
    const input = [_]u8{ 0, 1, 2, 128, 255 };
    var encoded: [128]u8 = undefined;
    const text = try encodeWithChecksum(&encoded, &input, .minimal);

    // Encoding: one byte short in the output
    try testing.expectError(error.BufferTooSmall, encodeWithChecksum(encoded[0 .. encodedLength(input.len, .minimal) - 1], &input, .minimal));
    try testing.expectError(error.BufferTooSmall, encode(encoded[0 .. input.len * minimal_len - 1], &input, .minimal));

    // Decoding: no room for the five body bytes
    var small: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, decode(&small, text, .minimal));
    var exact: [5]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&exact, text, .minimal));
}

test "canonicalize accepts 2 / 3 / 4 letters" {
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ae")); // able's first+last
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("abl")); // able's first three letters
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ble")); // able's last three letters
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("able"));
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ABLE"));

    for (words, 0..) |word, i| {
        // The word itself and first+last are always unique.
        try testing.expectEqual(@as(u8, @intCast(i)), try canonicalize(word));
        try testing.expectEqual(@as(u8, @intCast(i)), try canonicalize(&minimalFor(@intCast(i))));

        // Three letters must either "return the right word" or "reject as ambiguous".
        for ([_][]const u8{ word[0..3], word[1..4] }) |triple| {
            if (canonicalize(triple)) |byte| {
                try testing.expectEqual(@as(u8, @intCast(i)), byte);
            } else |err| {
                try testing.expectEqual(Error.InvalidEncoding, err);
            }
        }
    }

    // A real ambiguity: "ice" is the first three letters of iced and the last three of dice.
    try testing.expectError(error.InvalidEncoding, canonicalize("ice"));
    try testing.expectError(error.InvalidEncoding, canonicalize("axi")); // axis / taxi

    try testing.expectError(error.InvalidEncoding, canonicalize(""));
    try testing.expectError(error.InvalidEncoding, canonicalize("a"));
    try testing.expectError(error.InvalidEncoding, canonicalize("aaaaa"));
    try testing.expectError(error.InvalidEncoding, canonicalize("zz"));
}
