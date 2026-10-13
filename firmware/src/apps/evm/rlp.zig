//! RLP (Recursive Length Prefix) encoding and decoding.
//!
//! The serialization format used by Ethereum transactions, blocks, and the state trie.
//!
//! **Design policy**
//! - **Strict about canonical form.** RLP allows several encodings of the same value
//!   (a 1-byte value (< 0x80) written with a length prefix, a length not written in the
//!   minimum number of bytes, and so on). A signing hash becomes a different hash if a
//!   single byte differs, so every non-canonical encoding is rejected with error.InvalidEncoding.
//! - No memory allocation, because no secrets are handled (the caller provides the output).
//!
//! References: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
//!             https://github.com/ethereum/tests/blob/develop/RLPTests/rlptest.json
//!             https://ethereum.github.io/yellowpaper/paper.pdf (Appendix B)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;

/// Maximum nesting depth allowed when decoding.
///
/// A normal transaction nests only about three levels deep. Processing deep input
/// recursively as-is would exhaust the stack, so a limit is imposed and it is rejected.
pub const max_depth = 16;

/// Maximum byte length of an RLP length header (1 kind byte + 8 length bytes).
/// Usable as the size of a temporary buffer that holds only a length header.
pub const max_header_len = 9;

// ---------------------------------------------------------------- encoding

/// Minimum number of bytes needed to represent a value (0 for the value 0).
fn byteLen(value: usize) usize {
    if (value == 0) return 0;
    return (@bitSizeOf(usize) - @clz(value) + 7) / 8;
}

/// Writes a length header to `out`. `offset` is the kind: byte string (0x80) or list (0xC0).
///
/// For 55 or less, one byte (`offset + len`); above that, `offset + 55 + length byte count`
/// followed by the length in big-endian. The length always uses the minimum byte count.
fn encodeLenHeader(out: []u8, payload_len: usize, offset: u8) Error![]u8 {
    if (payload_len < 56) {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = offset + @as(u8, @intCast(payload_len));
        return out[0..1];
    }
    const length_bytes = byteLen(payload_len);
    if (out.len < 1 + length_bytes) return error.BufferTooSmall;

    var length_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_buf, @intCast(payload_len), .big);
    out[0] = offset + 55 + @as(u8, @intCast(length_bytes));
    @memcpy(out[1..][0..length_bytes], length_buf[8 - length_bytes ..]);
    return out[0 .. 1 + length_bytes];
}

/// Writes the RLP header for a byte string (excluding the body) to `out`.
///
/// An empty returned slice means the "a single byte < 0x80 encodes itself" case, where
/// **the body should simply be emitted as-is**. Use this when streaming without copying
/// the body, as when computing a hash.
pub fn encodeBytesHeader(out: []u8, data: []const u8) Error![]u8 {
    if (data.len == 1 and data[0] < 0x80) return out[0..0];
    return encodeLenHeader(out, data.len, 0x80);
}

/// Encodes a byte string.
///
/// For a single byte in 0x00 to 0x7F, that byte is the encoding itself (no `0x80` prefix).
/// The empty string is `0x80`.
pub fn encodeBytes(out: []u8, data: []const u8) Error![]u8 {
    const header = try encodeBytesHeader(out, data);
    if (header.len == 0) {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = data[0];
        return out[0..1];
    }
    if (out.len < header.len + data.len) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..data.len], data);
    return out[0 .. header.len + data.len];
}

/// Encodes an integer (Ethereum's rule: integers are big-endian with no leading zeros).
///
/// 0 is the empty string `0x80`; values that fit in one byte get no length header.
pub fn encodeUint(out: []u8, value: u256) Error![]u8 {
    if (value == 0) return encodeBytes(out, &.{});
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, value, .big);
    const leading_zero_bytes: usize = @clz(value) / 8;
    return encodeBytes(out, buf[leading_zero_bytes..]);
}

/// Writes a list header (the caller writes the `payload_len` bytes of body).
pub fn encodeListHeader(out: []u8, payload_len: usize) Error![]u8 {
    return encodeLenHeader(out, payload_len, 0xC0);
}

// ---------------------------------------------------------------- decoding

/// A decoded token.
pub const Item = union(enum) {
    /// A byte string (integer, address, data, and so on).
    bytes: []const u8,
    /// Start of a list. `payload` is the whole list body (header excluded).
    list: []const u8,
    /// End of a list.
    list_end,
};

/// Iterator that returns the token sequence from the start.
///
/// A list appears as `.list`, then its body, then `.list_end`. After the whole input has
/// been read it returns `null`. When done, always call `finish()` to confirm that there is
/// no leftover data and no unclosed list.
pub const Iterator = struct {
    data: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    /// End position of each currently open list.
    ends: [max_depth]usize = @splat(0),

    pub fn open(data: []const u8) Iterator {
        return .{ .data = data };
    }

    /// End of the current nesting (the innermost list, or the whole input if none).
    fn currentEnd(self: *const Iterator) usize {
        if (self.depth == 0) return self.data.len;
        return self.ends[self.depth - 1];
    }

    /// Validates the range of `len` bytes starting at `start` and returns its end.
    fn checkedEnd(self: *const Iterator, start: usize, len: usize) Error!usize {
        if (start > self.data.len or len > self.data.len - start) return error.Truncated;
        const end = start + len;
        // An element reaching past the end of the parent list is structurally invalid
        if (end > self.currentEnd()) return error.InvalidEncoding;
        return end;
    }

    /// Reads a long-form length (0xB8 to 0xBF / 0xF8 to 0xFF).
    fn readLongLength(self: *const Iterator, length_bytes: usize) Error!usize {
        const start = self.pos + 1;
        if (start + length_bytes > self.data.len) return error.Truncated;
        // A length not written in the minimum number of bytes (leading byte 0) is non-canonical
        if (self.data[start] == 0) return error.InvalidEncoding;

        var value: u64 = 0;
        for (self.data[start .. start + length_bytes]) |byte| {
            value = (value << 8) | byte;
        }
        if (value < 56) return error.InvalidEncoding;
        if (value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(value);
    }

    pub fn next(self: *Iterator) Error!?Item {
        // Return list_end once the end of the open list is reached
        if (self.depth > 0 and self.pos == self.ends[self.depth - 1]) {
            self.depth -= 1;
            return .list_end;
        }
        if (self.pos >= self.data.len) return null;

        const prefix = self.data[self.pos];
        // A single byte (0x00 to 0x7F) is its own encoding
        if (prefix < 0x80) {
            const item = self.data[self.pos .. self.pos + 1];
            self.pos += 1;
            return .{ .bytes = item };
        }

        switch (prefix) {
            // Short string: 0x80 + length (0 to 55)
            0x80...0xB7 => {
                const length = prefix - 0x80;
                const start = self.pos + 1;
                const end = try self.checkedEnd(start, length);
                // A single byte (< 0x80) must not be written with a length (non-canonical)
                if (length == 1 and self.data[start] < 0x80) return error.InvalidEncoding;
                self.pos = end;
                return .{ .bytes = self.data[start..end] };
            },
            // Long string: 0xB7 + number of length bytes (1 to 8)
            0xB8...0xBF => {
                const length = try self.readLongLength(prefix - 0xB7);
                const start = self.pos + 1 + (prefix - 0xB7);
                const end = try self.checkedEnd(start, length);
                self.pos = end;
                return .{ .bytes = self.data[start..end] };
            },
            // Short list: 0xC0 + payload length (0 to 55)
            0xC0...0xF7 => {
                const length = prefix - 0xC0;
                return try self.openList(length);
            },
            // Long list: 0xF7 + number of length bytes (1 to 8)
            0xF8...0xFF => {
                const length = try self.readLongLength(prefix - 0xF7);
                return try self.openList(length);
            },
            // 0x00 to 0x7F was handled above
            else => unreachable,
        }
    }

    fn openList(self: *Iterator, payload_len: usize) Error!Item {
        if (self.depth >= max_depth) return error.InvalidEncoding;
        const length_bytes: usize = if (payload_len < 56)
            0
        else
            byteLen(payload_len);
        const start = self.pos + 1 + length_bytes;
        const end = try self.checkedEnd(start, payload_len);
        self.ends[self.depth] = end;
        self.depth += 1;
        self.pos = start;
        return .{ .list = self.data[start..end] };
    }

    /// Confirms that the whole input was consumed consistently.
    pub fn finish(self: *const Iterator) Error!void {
        if (self.depth != 0) return error.Truncated;
        if (self.pos != self.data.len) return error.InvalidEncoding;
    }
};

/// Decodes as a single byte string (integer, address, data).
pub fn decodeBytes(data: []const u8) Error![]const u8 {
    var it = Iterator.open(data);
    const first = (try it.next()) orelse return error.Truncated;
    const payload = switch (first) {
        .bytes => |bytes| bytes,
        else => return error.InvalidEncoding,
    };
    if ((try it.next()) != null) return error.InvalidEncoding;
    try it.finish();
    return payload;
}

/// Decodes as a single list and returns the payload.
pub fn decodeList(data: []const u8) Error![]const u8 {
    var it = Iterator.open(data);
    const first = (try it.next()) orelse return error.Truncated;
    const payload = switch (first) {
        .list => |bytes| bytes,
        else => return error.InvalidEncoding,
    };
    // Confirm that the leading list spans the whole input (reject trailing extra data)
    if (@intFromPtr(payload.ptr) + payload.len != @intFromPtr(data.ptr) + data.len) {
        return error.InvalidEncoding;
    }
    // Read all of the body and confirm that the structure is canonical
    while ((try it.next()) != null) {}
    try it.finish();
    return payload;
}

/// Reads an RLP payload (the bytes after the length header) as an integer.
///
/// A representation with a leading zero byte is non-canonical and rejected (a lone `0x00`
/// byte is rejected too). The empty string is accepted as the canonical form of 0.
pub fn decodeUintPayload(payload: []const u8) Error!u256 {
    if (payload.len == 0) return 0;
    if (payload.len > 32) return error.InvalidEncoding;
    if (payload[0] == 0) return error.InvalidEncoding;

    var buf: [32]u8 = @splat(0);
    @memcpy(buf[32 - payload.len ..], payload);
    return std.mem.readInt(u256, &buf, .big);
}

/// Decodes as a single integer.
pub fn decodeUint(data: []const u8) Error!u256 {
    return decodeUintPayload(try decodeBytes(data));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Converts to a hex string so that test failures can be read as a diff.
fn toHex(buf: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0x0F];
    }
    return buf[0 .. bytes.len * 2];
}

fn expectHex(expected: []const u8, actual: []const u8) !void {
    var buf: [8192]u8 = undefined;
    try testing.expectEqualStrings(expected, toHex(&buf, actual));
}

/// Value type that allows the official test vector inputs to be written verbatim.
const Value = union(enum) {
    bytes: []const u8,
    uint: u256,
    list: []const Value,
};

fn encodeValue(out: []u8, value: Value) Error![]u8 {
    switch (value) {
        .bytes => |bytes| return encodeBytes(out, bytes),
        .uint => |number| return encodeUint(out, number),
        .list => |items| {
            var payload_buf: [4096]u8 = undefined;
            var payload_len: usize = 0;
            for (items) |item| {
                payload_len += (try encodeValue(payload_buf[payload_len..], item)).len;
            }
            const header = try encodeListHeader(out, payload_len);
            if (out.len < header.len + payload_len) return error.BufferTooSmall;
            @memcpy(out[header.len..][0..payload_len], payload_buf[0..payload_len]);
            return out[0 .. header.len + payload_len];
        },
    }
}

/// Rebuilds a decoded token sequence into canonical RLP.
///
/// The iterator returns tokens depth-first, so writing them out in that order is enough
/// (a list appears as "header -> body -> end"). Given non-canonical input, the rebuilt
/// result differs from the original bytes. So a matching "decode -> re-encode" confirms
/// that the accepted input was canonical and that the iterator returned the correct
/// boundaries.
fn reencode(out: []u8, it: *Iterator) Error![]u8 {
    var pos: usize = 0;
    while (try it.next()) |item| {
        pos += switch (item) {
            .bytes => |bytes| (try encodeBytes(out[pos..], bytes)).len,
            .list => |payload| (try encodeListHeader(out[pos..], payload.len)).len,
            .list_end => 0,
        };
    }
    return out[0..pos];
}

/// Official test vectors (RLPTests/rlptest.json). `in` is copied verbatim to `input` and
/// `out` to `encoded` (hex strings are the part without 0x).
///
/// - `bigint` (2^256) does not fit in u256, so it holds not an integer but the
///   **big-endian representation of that value (33 bytes)** as a byte string (RLP integers
///   are big-endian without leading zeros, so the official `out` compares the same way)
const vectors = [_]struct {
    name: []const u8,
    input: Value,
    encoded: []const u8,
}{
    .{
        .name = "emptystring",
        .input = .{ .bytes = "" },
        .encoded = "80",
    },
    .{
        .name = "bytestring00",
        .input = .{ .bytes = "\x00" },
        .encoded = "00",
    },
    .{
        .name = "bytestring01",
        .input = .{ .bytes = "\x01" },
        .encoded = "01",
    },
    .{
        .name = "bytestring7F",
        .input = .{ .bytes = "\x7f" },
        .encoded = "7f",
    },
    .{
        .name = "shortstring",
        .input = .{ .bytes = "dog" },
        .encoded = "83646f67",
    },
    .{
        .name = "shortstring2",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipisicing eli" },
        .encoded = "b74c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c69",
    },
    .{
        .name = "longstring",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipisicing elit" },
        .encoded = "b8384c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c6974",
    },
    .{
        .name = "longstring2",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Curabitur mauris magna, suscipit sed vehicula non, iaculis faucibus tortor. Proin suscipit ultricies malesuada. Duis tortor elit, dictum quis tristique eu, ultrices at risus. Morbi a est imperdiet mi ullamcorper aliquet suscipit nec lorem. Aenean quis leo mollis, vulputate elit varius, consequat enim. Nulla ultrices turpis justo, et posuere urna consectetur nec. Proin non convallis metus. Donec tempor ipsum in mauris congue sollicitudin. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia Curae; Suspendisse convallis sem vel massa faucibus, eget lacinia lacus tempor. Nulla quis ultricies purus. Proin auctor rhoncus nibh condimentum mollis. Aliquam consequat enim at metus luctus, a eleifend purus egestas. Curabitur at nibh metus. Nam bibendum, neque at auctor tristique, lorem libero aliquet arcu, non interdum tellus lectus sit amet eros. Cras rhoncus, metus ac ornare cursus, dolor justo ultrices metus, at ullamcorper volutpat" },
        .encoded = "b904004c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742e20437572616269747572206d6175726973206d61676e612c20737573636970697420736564207665686963756c61206e6f6e2c20696163756c697320666175636962757320746f72746f722e2050726f696e20737573636970697420756c74726963696573206d616c6573756164612e204475697320746f72746f7220656c69742c2064696374756d2071756973207472697374697175652065752c20756c7472696365732061742072697375732e204d6f72626920612065737420696d70657264696574206d6920756c6c616d636f7270657220616c6971756574207375736369706974206e6563206c6f72656d2e2041656e65616e2071756973206c656f206d6f6c6c69732c2076756c70757461746520656c6974207661726975732c20636f6e73657175617420656e696d2e204e756c6c6120756c74726963657320747572706973206a7573746f2c20657420706f73756572652075726e6120636f6e7365637465747572206e65632e2050726f696e206e6f6e20636f6e76616c6c6973206d657475732e20446f6e65632074656d706f7220697073756d20696e206d617572697320636f6e67756520736f6c6c696369747564696e2e20566573746962756c756d20616e746520697073756d207072696d697320696e206661756369627573206f726369206c756374757320657420756c74726963657320706f737565726520637562696c69612043757261653b2053757370656e646973736520636f6e76616c6c69732073656d2076656c206d617373612066617563696275732c2065676574206c6163696e6961206c616375732074656d706f722e204e756c6c61207175697320756c747269636965732070757275732e2050726f696e20617563746f722072686f6e637573206e69626820636f6e64696d656e74756d206d6f6c6c69732e20416c697175616d20636f6e73657175617420656e696d206174206d65747573206c75637475732c206120656c656966656e6420707572757320656765737461732e20437572616269747572206174206e696268206d657475732e204e616d20626962656e64756d2c206e6571756520617420617563746f72207472697374697175652c206c6f72656d206c696265726f20616c697175657420617263752c206e6f6e20696e74657264756d2074656c6c7573206c65637475732073697420616d65742065726f732e20437261732072686f6e6375732c206d65747573206163206f726e617265206375727375732c20646f6c6f72206a7573746f20756c747269636573206d657475732c20617420756c6c616d636f7270657220766f6c7574706174",
    },
    .{
        .name = "zero",
        .input = .{ .uint = 0 },
        .encoded = "80",
    },
    .{
        .name = "smallint",
        .input = .{ .uint = 1 },
        .encoded = "01",
    },
    .{
        .name = "smallint2",
        .input = .{ .uint = 16 },
        .encoded = "10",
    },
    .{
        .name = "smallint3",
        .input = .{ .uint = 79 },
        .encoded = "4f",
    },
    .{
        .name = "smallint4",
        .input = .{ .uint = 127 },
        .encoded = "7f",
    },
    .{
        .name = "mediumint1",
        .input = .{ .uint = 128 },
        .encoded = "8180",
    },
    .{
        .name = "mediumint2",
        .input = .{ .uint = 1000 },
        .encoded = "8203e8",
    },
    .{
        .name = "mediumint3",
        .input = .{ .uint = 100000 },
        .encoded = "830186a0",
    },
    // in = 83729609699884896815286331701780722 (15 bytes)
    .{
        .name = "mediumint4",
        .input = .{ .uint = 0x102030405060708090a0b0c0d0e0f2 },
        .encoded = "8f102030405060708090a0b0c0d0e0f2",
    },
    // in = 105315505618206987246253880190783558935785933862974822347068935681 (29 bytes)
    .{
        .name = "mediumint5",
        .input = .{ .uint = 0x100020003000400050006000700080009000a000b000c000d000e01 },
        .encoded = "9c0100020003000400050006000700080009000a000b000c000d000e01",
    },
    .{
        .name = "emptylist",
        .input = .{ .list = &.{  } },
        .encoded = "c0",
    },
    .{
        .name = "stringlist",
        .input = .{ .list = &.{ .{ .bytes = "dog" }, .{ .bytes = "god" }, .{ .bytes = "cat" } } },
        .encoded = "cc83646f6783676f6483636174",
    },
    .{
        .name = "multilist",
        .input = .{ .list = &.{ .{ .bytes = "zw" }, .{ .list = &.{ .{ .uint = 4 } } }, .{ .uint = 1 } } },
        .encoded = "c6827a77c10401",
    },
    .{
        .name = "shortListMax1",
        .input = .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" } } },
        .encoded = "f784617364668471776572847a78637684617364668471776572847a78637684617364668471776572847a78637684617364668471776572",
    },
    .{
        .name = "longList1",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } } } },
        .encoded = "f840cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376",
    },
    .{
        .name = "longList2",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } } } },
        .encoded = "f90200cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376",
    },
    .{
        .name = "listsoflists",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{  } } } }, .{ .list = &.{  } } } },
        .encoded = "c4c2c0c0c0",
    },
    .{
        .name = "listsoflists2",
        .input = .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{ .{ .list = &.{  } } } }, .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{ .{ .list = &.{  } } } } } } } },
        .encoded = "c7c0c1c0c3c0c1c0",
    },
    .{
        .name = "dictTest1",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "key1" }, .{ .bytes = "val1" } } }, .{ .list = &.{ .{ .bytes = "key2" }, .{ .bytes = "val2" } } }, .{ .list = &.{ .{ .bytes = "key3" }, .{ .bytes = "val3" } } }, .{ .list = &.{ .{ .bytes = "key4" }, .{ .bytes = "val4" } } } } },
        .encoded = "ecca846b6579318476616c31ca846b6579328476616c32ca846b6579338476616c33ca846b6579348476616c34",
    },
    // The official vector's `bigint`: in = 2^256, out = 0xa1 0100...00 (a 33-byte integer)
    .{
        .name = "bigint",
        .input = .{ .bytes = "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" },
        .encoded = "a1010000000000000000000000000000000000000000000000000000000000000000",
    },
};

test "official vectors: encoding" {
    var buf: [4096]u8 = undefined;
    for (vectors) |vector| {
        const encoded = encodeValue(&buf, vector.input) catch |err| {
            std.debug.print("vector {s}: encoding failed ({s})\n", .{ vector.name, @errorName(err) });
            return err;
        };
        expectHex(vector.encoded, encoded) catch |err| {
            std.debug.print("vector {s}: does not match the official `out`\n", .{vector.name});
            return err;
        };
    }
}

test "official vectors: decoding (canonical round trip)" {
    var encoded_buf: [4096]u8 = undefined;
    var decoded_buf: [4096]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    for (vectors) |vector| {
        const encoded = try encodeValue(&encoded_buf, vector.input);

        // 1) For byte string vectors, decodeBytes returns the input itself
        // 2) For integer vectors, decodeUint returns the original value
        // 3) For list vectors, decodeList returns the length without the header
        switch (vector.input) {
            .bytes => |bytes| {
                const decoded = decodeBytes(encoded) catch |err| {
                    std.debug.print("vector {s}: decodeBytes failed ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                try testing.expectEqualSlices(u8, bytes, decoded);
            },
            .uint => |number| {
                const decoded = decodeUint(encoded) catch |err| {
                    std.debug.print("vector {s}: decodeUint failed ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                try testing.expectEqual(number, decoded);
            },
            .list => |items| {
                const payload = decodeList(encoded) catch |err| {
                    std.debug.print("vector {s}: decodeList failed ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                var payload_len: usize = 0;
                for (items) |item| {
                    payload_len += (try encodeValue(payload_buf[payload_len..], item)).len;
                }
                try testing.expectEqual(payload_len, payload.len);
            },
        }

        // 4) Reading the whole token sequence and rebuilding it restores the original bytes
        var it = Iterator.open(encoded);
        const reencoded = reencode(&decoded_buf, &it) catch |err| {
            std.debug.print("vector {s}: re-encode failed ({s})\n", .{ vector.name, @errorName(err) });
            return err;
        };
        try testing.expectEqualSlices(u8, encoded, reencoded);

        // 5) The input reads to the end (no leftover data and no unclosed list)
        var walk = Iterator.open(encoded);
        while ((try walk.next()) != null) {}
        try walk.finish();
    }
}

test "rejects non-canonical encodings" {
    // A single byte (< 0x80) written with a length
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x81, 0x7f }));
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x81, 0x00 }));

    // 55 bytes or less written in long form (0xB8)
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0xb8, 0x01, 0x80 }));
    var short_long: [2 + 55]u8 = undefined;
    short_long[0] = 0xb8;
    short_long[1] = 55;
    @memset(short_long[2..], 0x41);
    try testing.expectError(error.InvalidEncoding, decodeBytes(&short_long));

    // The length is not written in the minimum number of bytes (leading byte 0)
    var padded: [3 + 56]u8 = undefined;
    padded[0] = 0xb9;
    padded[1] = 0x00;
    padded[2] = 56;
    @memset(padded[3..], 0x41);
    try testing.expectError(error.InvalidEncoding, decodeBytes(&padded));

    // The same rule applies to lists
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xf8, 0x01, 0x80 }));
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xf9, 0x00, 0x38, 0xc0 }));

    // Non-canonical as an integer (leading zero byte, 33 bytes)
    try testing.expectError(error.InvalidEncoding, decodeUint(&[_]u8{0x00}));
    try testing.expectError(error.InvalidEncoding, decodeUint(&[_]u8{ 0x82, 0x00, 0x01 }));
    var too_large: [34]u8 = undefined;
    too_large[0] = 0xa1;
    @memset(too_large[1..], 0x01);
    try testing.expectError(error.InvalidEncoding, decodeUint(&too_large));
}

test "rejects truncated input" {
    // Declares 3 bytes but has only 2
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{ 0x83, 0x61, 0x62 }));
    // Not enough length bytes
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{ 0xb9, 0x01 }));
    // The list payload is short
    try testing.expectError(error.Truncated, decodeList(&[_]u8{ 0xc2, 0x80 }));
    try testing.expectError(error.Truncated, decodeList(&[_]u8{ 0xf8, 0x40, 0xc0 }));
    // Empty input
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{}));
    try testing.expectError(error.Truncated, decodeList(&[_]u8{}));
}

test "rejects input that crosses list boundaries" {
    // A child list longer than its parent is placed inside a parent list (1-byte payload)
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xc1, 0xc2, 0x80, 0x80 }));

    // Correct nesting (parent and child ends coincide) is accepted: [ [ [ "" ] ] ]
    var it = Iterator.open(&[_]u8{ 0xc3, 0xc2, 0xc1, 0x80 });
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.bytes, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(@as(?Item, null), try it.next());
    try it.finish();
}

test "rejects input that is nested too deeply" {
    // Each level is a list whose payload is "all the rest" (depth = array length - 1)
    var ok: [max_depth + 1]u8 = undefined;
    for (0..ok.len - 1) |i| ok[i] = 0xc0 + @as(u8, @intCast(ok.len - 1 - i));
    ok[ok.len - 1] = 0x80;
    _ = try decodeList(&ok);

    var too_deep: [max_depth + 2]u8 = undefined;
    for (0..too_deep.len - 1) |i| too_deep[i] = 0xc0 + @as(u8, @intCast(too_deep.len - 1 - i));
    too_deep[too_deep.len - 1] = 0x80;
    try testing.expectError(error.InvalidEncoding, decodeList(&too_deep));
}

test "rejects extra data" {
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x80, 0x80 }));
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xc0, 0x80 }));
}

test "integer boundaries (0, 1 byte, the 55/56 byte boundary)" {
    var buf: [64]u8 = undefined;
    var expected: [64]u8 = undefined;
    var hex_buf: [256]u8 = undefined;

    try expectHex("80", try encodeUint(&buf, 0));
    try expectHex("7f", try encodeUint(&buf, 0x7f));
    try expectHex("8180", try encodeUint(&buf, 0x80));
    try expectHex("820400", try encodeUint(&buf, 0x400));
    try expectHex(
        "a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        try encodeUint(&buf, std.math.maxInt(u256)),
    );

    // A single 0x80 byte gets a length header (0x80 alone is the empty string)
    try expectHex("8180", try encodeBytes(&buf, &[_]u8{0x80}));
    try expectHex("80", try encodeBytes(&buf, &.{}));

    // 55 bytes uses short form (0xB7 = 0x80 + 55)
    var data: [56]u8 = undefined;
    @memset(&data, 0xaa);
    expected[0] = 0xb7;
    @memset(expected[1..56], 0xaa);
    try expectHex(toHex(&hex_buf, expected[0..56]), try encodeBytes(&buf, data[0..55]));

    // 56 bytes uses long form (0xB8 + one length byte 0x38 = 56)
    expected[0] = 0xb8;
    expected[1] = 56;
    @memset(expected[2..58], 0xaa);
    try expectHex(toHex(&hex_buf, expected[0..58]), try encodeBytes(&buf, &data));
}
