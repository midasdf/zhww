//! The part of CBOR (RFC 8949) that UR needs, plus its deterministic profile dCBOR.
//!
//! **Scope**
//! - Encoding: unsigned integers, byte strings, text strings, arrays, and tagged types.
//!   Integers and lengths are always written in the shortest form (dCBOR / RFC 8949 §4.1 determinism).
//! - Decoding: besides the above, maps, negative integers, and simple values/floats can be
//!   **skipped over** (`skipItem` / `isWellFormed`). Used to check that a UR message (a PSBT, say)
//!   is not broken as dCBOR, without interpreting its contents.
//! - Indefinite length (additional information 31) is not supported. UR messages are dCBOR, and
//!   dCBOR forbids indefinite length, so it never occurs.
//!
//! **Design policy**
//! - Strict about determinism: with `Reader.strict` (true by default), an integer or length that is
//!   not in the shortest form is rejected with error.InvalidEncoding. Several encodings of the same
//!   value would leave room to slip past UR type or checksum verification.
//! - So that deep nesting does not eat the stack, `skipItem` rejects past a depth limit (`max_depth`).
//! - No memory allocation, because no secrets are handled (the caller provides the output).
//!
//! Reference: https://www.rfc-editor.org/rfc/rfc8949.html
//!            https://datatracker.ietf.org/doc/draft-mcnally-deterministic-cbor/
//! Test vector sources: RFC 8949 §Appendix A (the diagnostic notation / hex table) and the CBOR
//! examples in BCR-2020-012 / BCR-2024-001.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// Maximum byte length of a header (type + argument). Size of a header-only temporary buffer.
pub const max_header_len = 9;

/// Maximum nesting depth. Input deeper than this is rejected with error.InvalidEncoding.
pub const max_depth = 32;

/// Major type (RFC 8949 §3.1).
pub const MajorType = enum(u3) {
    unsigned_int = 0,
    negative_int = 1,
    byte_string = 2,
    text_string = 3,
    array = 4,
    map = 5,
    tag = 6,
    simple = 7,
};

/// Number of header bytes needed to write `value` in the shortest form.
pub fn headLength(value: u64) usize {
    if (value < 24) return 1;
    if (value <= 0xff) return 2;
    if (value <= 0xffff) return 3;
    if (value <= 0xffff_ffff) return 5;
    return 9;
}

/// Length when encoded as a byte string (header + body).
pub fn bytesLength(data_len: usize) usize {
    return std.math.add(usize, headLength(data_len), data_len) catch std.math.maxInt(usize);
}

/// Smallest value that n bytes can represent (used for the determinism check).
fn minimalValueForWidth(width: usize) u64 {
    return switch (width) {
        1 => 24,
        2 => 0x100,
        4 => 0x1_0000,
        8 => 0x1_0000_0000,
        else => unreachable,
    };
}

fn writeBigEndian(out: []u8, value: u64, width: usize) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    @memcpy(out[0..width], buf[8 - width ..]);
}

// ---------------------------------------------------------------- encoding

/// Writes a header (type + argument in the shortest form).
///
/// For a tagged type, write the contents after `writeTag` (in CBOR a tag applies to
/// "the next single item", so the length of the contents is not part of the header).
pub fn writeHead(out: []u8, major: MajorType, value: u64) Error![]u8 {
    const width = headLength(value);
    if (out.len < width) return error.BufferTooSmall;

    const prefix: u8 = @as(u8, @backingInt(major)) << 5;
    switch (width) {
        1 => out[0] = prefix | @as(u8, @intCast(value)),
        2 => {
            out[0] = prefix | 24;
            writeBigEndian(out[1..], value, 1);
        },
        3 => {
            out[0] = prefix | 25;
            writeBigEndian(out[1..], value, 2);
        },
        5 => {
            out[0] = prefix | 26;
            writeBigEndian(out[1..], value, 4);
        },
        9 => {
            out[0] = prefix | 27;
            writeBigEndian(out[1..], value, 8);
        },
        else => unreachable,
    }
    return out[0..width];
}

/// Unsigned integer (major type 0).
pub fn writeUint(out: []u8, value: u64) Error![]u8 {
    return writeHead(out, .unsigned_int, value);
}

/// Tag (major type 6). For `6.40300`, write the contents after `writeTag(out, 40300)`.
pub fn writeTag(out: []u8, tag: u64) Error![]u8 {
    return writeHead(out, .tag, tag);
}

/// Array header (major type 4). The caller writes `length` items as the contents.
pub fn writeArrayHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .array, length);
}

/// Byte string header (major type 2). The caller writes the contents.
pub fn writeBytesHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .byte_string, length);
}

/// Text string header (major type 3).
pub fn writeTextHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .text_string, length);
}

/// Byte string (major type 2).
pub fn writeBytes(out: []u8, data: []const u8) Error![]u8 {
    const header = try writeBytesHeader(out, data.len);
    const total = std.math.add(usize, header.len, data.len) catch return error.BufferTooSmall;
    if (out.len < total) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..data.len], data);
    return out[0..total];
}

/// Text string (major type 3). UTF-8 validity is not checked.
pub fn writeText(out: []u8, text: []const u8) Error![]u8 {
    const header = try writeTextHeader(out, text.len);
    const total = std.math.add(usize, header.len, text.len) catch return error.BufferTooSmall;
    if (out.len < total) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..text.len], text);
    return out[0..total];
}

// ---------------------------------------------------------------- decoding

/// A header that has been read.
pub const Head = struct {
    major: MajorType,
    /// The argument value (integer value, length, or tag number).
    value: u64,
    /// Byte length of the header.
    len: usize,
};

/// CBOR decoder that reads forward from the beginning.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    /// If true, an integer or length not in the shortest form is rejected (dCBOR determinism).
    strict: bool = true,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    /// Whether the whole input has been read.
    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    /// Confirms the whole input has been read (trailing data is not allowed).
    pub fn finish(self: *const Reader) Error!void {
        if (self.pos != self.data.len) return error.InvalidEncoding;
    }

    /// Reads the next header.
    ///
    /// Additional information 31 (indefinite length) and 28-30 (reserved) give error.InvalidEncoding.
    pub fn readHead(self: *Reader) Error!Head {
        if (self.pos >= self.data.len) return error.Truncated;

        const first = self.data[self.pos];
        const major: MajorType = @fromBackingInt(@intCast(@as(u3, @intCast(first >> 5))));
        const additional: u8 = first & 0x1f;

        var width: usize = 0;
        var value: u64 = additional;
        var len: usize = 1;

        switch (additional) {
            0...23 => {},
            24, 25, 26, 27 => {
                width = switch (additional) {
                    24 => 1,
                    25 => 2,
                    26 => 4,
                    else => 8,
                };
                if (self.data.len - self.pos < 1 + width) return error.Truncated;
                value = 0;
                for (self.data[self.pos + 1 ..][0..width]) |byte| value = (value << 8) | byte;
                len = 1 + width;
                // dCBOR: a value that could be written in fewer bytes is rejected.
                // Major type 7 (simple values/floats) has an argument that is not a length, so it is excluded.
                if (self.strict and major != .simple and value < minimalValueForWidth(width)) {
                    return error.InvalidEncoding;
                }
            },
            else => return error.InvalidEncoding,
        }

        self.pos += len;
        return .{ .major = major, .value = value, .len = len };
    }

    /// Reads an unsigned integer (major type 0).
    pub fn readUint(self: *Reader) Error!u64 {
        const head = try self.readHead();
        if (head.major != .unsigned_int) return error.InvalidEncoding;
        return head.value;
    }

    /// Reads a tag (major type 6). Read the contents that follow.
    pub fn readTag(self: *Reader) Error!u64 {
        const head = try self.readHead();
        if (head.major != .tag) return error.InvalidEncoding;
        return head.value;
    }

    /// Reads an array header (major type 4) and returns the element count.
    pub fn readArrayHeader(self: *Reader) Error!usize {
        const head = try self.readHead();
        if (head.major != .array) return error.InvalidEncoding;
        if (head.value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(head.value);
    }

    /// Reads a map header (major type 5) and returns the pair count.
    pub fn readMapHeader(self: *Reader) Error!usize {
        const head = try self.readHead();
        if (head.major != .map) return error.InvalidEncoding;
        if (head.value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(head.value);
    }

    fn readString(self: *Reader, major: MajorType) Error![]const u8 {
        const head = try self.readHead();
        if (head.major != major) return error.InvalidEncoding;
        if (head.value > self.data.len - self.pos) return error.Truncated;
        const length: usize = @intCast(head.value);
        const body = self.data[self.pos..][0..length];
        self.pos += length;
        return body;
    }

    /// Reads a byte string (major type 2). The returned slice points into the input.
    pub fn readBytes(self: *Reader) Error![]const u8 {
        return self.readString(.byte_string);
    }

    /// Reads a text string (major type 3). The returned slice points into the input.
    pub fn readText(self: *Reader) Error![]const u8 {
        return self.readString(.text_string);
    }

    fn skipItemDepth(self: *Reader, depth: usize) Error!void {
        if (depth > max_depth) return error.InvalidEncoding;

        const head = try self.readHead();
        switch (head.major) {
            .unsigned_int, .negative_int, .simple => {},
            .byte_string, .text_string => {
                if (head.value > self.data.len - self.pos) return error.Truncated;
                self.pos += @intCast(head.value);
            },
            .array => {
                var i: u64 = 0;
                while (i < head.value) : (i += 1) try self.skipItemDepth(depth + 1);
            },
            .map => {
                var i: u64 = 0;
                while (i < head.value) : (i += 1) {
                    try self.skipItemDepth(depth + 1); // key
                    try self.skipItemDepth(depth + 1); // value
                }
            },
            .tag => try self.skipItemDepth(depth + 1),
        }
    }

    /// Skips the next single item (its contents are not interpreted).
    pub fn skipItem(self: *Reader) Error!void {
        return self.skipItemDepth(0);
    }
};

/// Checks that the whole input is intact as "exactly one CBOR item".
///
/// If `strict` is true, the dCBOR shortest form is required as well.
pub fn isWellFormed(data: []const u8, strict: bool) bool {
    var reader = Reader{ .data = data, .strict = strict };
    reader.skipItem() catch return false;
    return reader.pos == data.len;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn asHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

fn expectEncoded(expected_hex: []const u8, actual: []const u8) !void {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(asHex(&buf, expected_hex), actual);
}

test "matches the RFC 8949 Appendix A integer encodings" {
    // Diagnostic notation -> hex (RFC 8949 §Appendix A)
    const vectors = [_]struct { value: u64, hex: []const u8 }{
        .{ .value = 0, .hex = "00" },
        .{ .value = 10, .hex = "0a" },
        .{ .value = 23, .hex = "17" },
        .{ .value = 24, .hex = "1818" },
        .{ .value = 25, .hex = "1819" },
        .{ .value = 100, .hex = "1864" },
        .{ .value = 255, .hex = "18ff" },
        .{ .value = 256, .hex = "190100" },
        .{ .value = 1000, .hex = "1903e8" },
        .{ .value = 65535, .hex = "19ffff" },
        .{ .value = 65536, .hex = "1a00010000" },
        .{ .value = 1000000, .hex = "1a000f4240" },
        .{ .value = 4294967295, .hex = "1affffffff" },
        .{ .value = 4294967296, .hex = "1b0000000100000000" },
        .{ .value = 1000000000000, .hex = "1b000000e8d4a51000" },
        .{ .value = 18446744073709551615, .hex = "1bffffffffffffffff" },
    };

    for (vectors) |vector| {
        var out: [16]u8 = undefined;
        const encoded = try writeUint(&out, vector.value);
        try expectEncoded(vector.hex, encoded);

        // round trip
        var reader = Reader.init(encoded);
        try testing.expectEqual(vector.value, try reader.readUint());
        try reader.finish();
    }
}

test "matches the RFC 8949 Appendix A arrays, byte strings, text and tags" {
    var out: [64]u8 = undefined;

    // h'' / h'01020304'
    try expectEncoded("40", try writeBytes(&out, ""));
    var four: [4]u8 = undefined;
    try expectEncoded("4401020304", try writeBytes(&out, asHex(&four, "01020304")));

    // "" / "a" / "IETF"
    try expectEncoded("60", try writeText(&out, ""));
    try expectEncoded("6161", try writeText(&out, "a"));
    try expectEncoded("6449455446", try writeText(&out, "IETF"));

    // [] / [1, 2, 3] / [1, [2, 3], [4, 5]] / {}
    try expectEncoded("80", try writeArrayHeader(&out, 0));
    var pos: usize = 0;
    pos += (try writeArrayHeader(out[pos..], 3)).len;
    for ([_]u64{ 1, 2, 3 }) |value| pos += (try writeUint(out[pos..], value)).len;
    try expectEncoded("83010203", out[0..pos]);

    pos = 0;
    pos += (try writeArrayHeader(out[pos..], 3)).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeArrayHeader(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 3)).len;
    pos += (try writeArrayHeader(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 4)).len;
    pos += (try writeUint(out[pos..], 5)).len;
    try expectEncoded("8301820203820405", out[0..pos]);

    try expectEncoded("a0", try writeHead(&out, .map, 0));

    // Tags: 0("2013-03-21T20:04:00Z") and 40300 (the BCR-2020-012 seed)
    try expectEncoded("c0", try writeTag(&out, 0));
    try expectEncoded("d99d6c", try writeTag(&out, 40300));

    pos = 0;
    pos += (try writeTag(out[pos..], 40300)).len;
    pos += (try writeHead(out[pos..], .map, 1)).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeBytes(out[pos..], asHex(&four, "deadbeef"))).len;
    try expectEncoded("d99d6ca10144deadbeef", out[0..pos]);
}

test "reads the part CBOR of BCR-2024-001" {
    // FountainEncoder::Part(seqNum: 1, seqLen: 9, messageLen: 256, checksum: 0x0167aa07,
    // data: 29 bytes) in CBOR (from testEncoderCBOR in BCR-2024-001 §5).
    var buf: [128]u8 = undefined;
    const part = asHex(
        &buf,
        "8501091901001a0167aa07581d916ec65cf77cadf55cd7f9cda1a1030026ddd42e905b77adc36e4f2d3c",
    );

    var reader = Reader.init(part);
    try testing.expectEqual(@as(usize, 5), try reader.readArrayHeader());
    try testing.expectEqual(@as(u64, 1), try reader.readUint());
    try testing.expectEqual(@as(u64, 9), try reader.readUint());
    try testing.expectEqual(@as(u64, 256), try reader.readUint());
    try testing.expectEqual(@as(u64, 0x0167aa07), try reader.readUint());
    const data = try reader.readBytes();
    try testing.expectEqual(@as(usize, 29), data.len);
    try testing.expectEqual(@as(u8, 0x91), data[0]);
    try testing.expectEqual(@as(u8, 0x3c), data[28]);
    try reader.finish();

    // The document as a whole is intact as well.
    try testing.expect(isWellFormed(part, true));
}

test "reads a tagged type (the BCR-2020-012 seed)" {
    var buf: [64]u8 = undefined;
    const seed = asHex(&buf, "d99d6ca20150c7098580125e2ab0981253468b2dbc5202c11947da");

    var reader = Reader.init(seed);
    try testing.expectEqual(@as(u64, 40300), try reader.readTag());
    try testing.expectEqual(@as(usize, 2), try reader.readMapHeader());
    try testing.expectEqual(@as(u64, 1), try reader.readUint());
    try testing.expectEqual(@as(usize, 16), (try reader.readBytes()).len);
    try testing.expectEqual(@as(u64, 2), try reader.readUint());
    try testing.expectEqual(@as(u64, 1), try reader.readTag());
    try testing.expectEqual(@as(u64, 18394), try reader.readUint());
    try reader.finish();
}

test "skips over maps, negative integers, simple values and floats" {
    // {"a": 1, "b": [-1, null, true, 1.5]}
    var out: [64]u8 = undefined;
    var pos: usize = 0;
    pos += (try writeHead(out[pos..], .map, 2)).len;
    pos += (try writeText(out[pos..], "a")).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeText(out[pos..], "b")).len;
    pos += (try writeArrayHeader(out[pos..], 4)).len;
    pos += (try writeHead(out[pos..], .negative_int, 0)).len; // -1
    pos += (try writeHead(out[pos..], .simple, 22)).len; // null
    pos += (try writeHead(out[pos..], .simple, 21)).len; // true
    out[pos] = 0xf9;
    out[pos + 1] = 0x3e;
    out[pos + 2] = 0x00; // 1.5 (float16)
    pos += 3;
    const document = out[0..pos];

    // Exactly as RFC 8949 represents them (-1 is 0x20, null is 0xf6, true is 0xf5, 1.5 is 0xf93e00).
    try expectEncoded("a261610161628420f6f5f93e00", document);

    try testing.expect(isWellFormed(document, true));
    var reader = Reader.init(document);
    try reader.skipItem();
    try reader.finish();

    // Floats (major type 7) are not subject to the shortest-form check.
    var float_buf: [16]u8 = undefined;
    const float32 = asHex(&float_buf, "fa00000000"); // 0.0 written as float32
    var float_reader = Reader.init(float32);
    try testing.expectEqual(@as(u64, 0), (try float_reader.readHead()).value);
    try float_reader.finish();
}

test "rejects non-shortest forms (dCBOR determinism)" {
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;
    var buf_c: [16]u8 = undefined;

    // 0 written in two bytes (correctly 0x00)
    const non_minimal_zero = asHex(&buf_a, "1800");
    var reader = Reader.init(non_minimal_zero);
    try testing.expectError(error.InvalidEncoding, reader.readHead());
    try testing.expect(!isWellFormed(non_minimal_zero, true));
    // Readable when relaxed (strict = false is available for interoperability).
    try testing.expect(isWellFormed(non_minimal_zero, false));

    // 255 written in four bytes (correctly 0x18ff)
    reader = Reader.init(asHex(&buf_b, "1a000000ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());

    // A byte string of length 2 written with a two-byte length (correctly 0x42)
    reader = Reader.init(asHex(&buf_c, "58020203"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
}

test "rejects indefinite lengths and reserved values" {
    var buf: [16]u8 = undefined;

    // An indefinite-length byte string (0x5f ... 0xff) and an indefinite-length array (0x9f ... 0xff)
    var reader = Reader.init(asHex(&buf, "5f420102ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
    reader = Reader.init(asHex(&buf, "9f0102ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());

    // Additional information 28 (reserved)
    reader = Reader.init(asHex(&buf, "1c"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
}

test "rejects truncation, wrong types and trailing data" {
    var buf: [16]u8 = undefined;

    // Header only, no body
    var reader = Reader.init(asHex(&buf, "44"));
    try testing.expectError(error.Truncated, reader.readBytes());
    var reader2 = Reader.init(asHex(&buf, "58"));
    try testing.expectError(error.Truncated, reader2.readHead());
    var reader3 = Reader.init(asHex(&buf, ""));
    try testing.expectError(error.Truncated, reader3.readHead());
    try testing.expect(!isWellFormed(asHex(&buf, "1901"), true));

    // Wrong type
    var reader4 = Reader.init(asHex(&buf, "6161"));
    try testing.expectError(error.InvalidEncoding, reader4.readUint());
    var reader5 = Reader.init(asHex(&buf, "4401020304"));
    try testing.expectError(error.InvalidEncoding, reader5.readArrayHeader());
    var reader6 = Reader.init(asHex(&buf, "00"));
    try testing.expectError(error.InvalidEncoding, reader6.readTag());

    // Trailing data
    try testing.expect(!isWellFormed(asHex(&buf, "0000"), true));
    var reader7 = Reader.init(asHex(&buf, "0000"));
    try testing.expectEqual(@as(u64, 0), try reader7.readUint());
    try testing.expectError(error.InvalidEncoding, reader7.finish());
}

test "rejects input that nests too deeply" {
    // 0x81 (one-element array) stacked 64 deep, followed by 0x00
    var deep: [65]u8 = @splat(0x81);
    deep[64] = 0x00;
    try testing.expect(!isWellFormed(&deep, true));

    // Within max_depth it passes
    var shallow: [max_depth + 1]u8 = @splat(0x81);
    shallow[max_depth] = 0x00;
    try testing.expect(isWellFormed(&shallow, true));
}

test "BufferTooSmall when the output buffer is too small" {
    var short: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, writeUint(&short, 65536));
    try testing.expectError(error.BufferTooSmall, writeHead(&short, .tag, 40300));
    try testing.expectError(error.BufferTooSmall, writeBytes(short[0..1], &.{ 1, 2 }));
    try testing.expectError(error.BufferTooSmall, writeText(short[0..1], "abc"));
}
