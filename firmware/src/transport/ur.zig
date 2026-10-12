//! UR (Uniform Resource): an encoding that carries binary data in the form
//! `ur:<type>/<bytewords>` on QR codes and URIs.
//!
//! **Scope**
//! - Single part: `ur:<type>/<bytewords>` (BCR-2020-005 §UR Encoding).
//! - Multipart: `ur:<type>/<seqNum>-<seqLen>/<bytewords>`.
//!   `bytewords` encodes the part CBOR `[seqNum, seqLen, messageLen, checksum, data]`.
//! - **Only sequential parts (seqNum = 1..seqLen) are supported**. Fountain-code redundant parts
//!   (seqNum > seqLen, several fragments XORed together) are **never generated**.
//!   The decoder accepts a redundant part structurally but does not use it for recovery
//!   (it returns `Status.fountain_unsupported`). Full MUR support from BCR-2024-001 is not implemented.
//! - Type names (`bytes` / `crypto-psbt` etc.) are just strings; their contents are not interpreted.
//!
//! **Design policy**
//! - Part numbers are **one-based**, as the spec requires. The zero-based fragment index is `seqNum - 1`.
//! - The decoder accepts out-of-order and duplicate input, and verifies the CRC-32 and completes
//!   only when all `seqLen` parts are present. Until then it returns `Status.need_more` and
//!   **does not treat the message as complete**.
//! - The first accepted part fixes "message length, part count, checksum and fragment length".
//!   If a later part disagrees with them (for example, a part of another message was mixed in),
//!   it is rejected with error.InvalidEncoding (the reference implementation silently drops it,
//!   but this implementation rejects it strictly).
//! - UR is case-insensitive. It can be output in uppercase for QR codes (alphanumeric mode).
//! - The whole message must be dCBOR, so completion also checks its structure as CBOR.
//! - No memory allocation, because no secrets are handled (the caller provides the work area).
//!
//! Reference: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md
//!            https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2024-001-multipart-ur.md
//! Test vector sources:
//!   - the seed example in BCR-2020-005 §UR CBOR Tags (ur:seed/oyad...)
//!   - test_single_part_ur / test_ur_encoder in bc-ur (C++ reference implementation) test/test.cpp
//!     https://github.com/BlockchainCommons/bc-ur/blob/master/test/test.cpp
//!   - test_ur in bc-ur-rust src/ur.rs (ur:test/lsadaoaxjygonesw)
//!     https://github.com/BlockchainCommons/bc-ur-rust/blob/master/src/ur.rs
//!   - the findNominalFragmentLength test vectors in BCR-2024-001 §5
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const bytewords = @import("bytewords.zig");
const cbor = @import("cbor.zig");

/// Maximum UR type name length (in practice around `crypto-psbt`).
pub const max_type_len = 32;
/// The `bytes` type (described in the spec as being for testing and verification).
pub const type_bytes = "bytes";
/// The `crypto-psbt` type (carries a PSBT).
pub const type_crypto_psbt = "crypto-psbt";
/// URI scheme.
pub const scheme = "ur:";
/// Default lower bound for the fragment length (matches the bc-ur / URKit default).
pub const default_min_fragment_len = 10;

/// Case of the output string. UR is case agnostic, and in a QR code's alphanumeric mode
/// uppercase is more efficient.
pub const TextCase = enum { lower, upper };

/// seq (part number and part count).
pub const Seq = struct {
    /// Part number. **One-based**. A value above seqLen is a fountain-code redundant part.
    num: u32,
    /// Number of parts the message is split into.
    len: u32,
};

/// A parsed UR string.
pub const Uri = struct {
    /// Type name (with the case of the input, pointing into the input).
    ur_type: []const u8,
    /// The multipart seq. null for a single part.
    seq: ?Seq = null,
    /// The bytewords part of `<message>` or `<fragment>` (points into the input).
    body: []const u8,
};

/// A part (the contents of a multipart UR).
pub const Part = struct {
    seq_num: u32,
    seq_len: u32,
    /// Total message length in bytes (padding excluded).
    message_len: usize,
    /// CRC-32 of the whole message.
    checksum: u32,
    /// Fragment (the last part is zero-padded).
    data: []const u8,
};

// ---------------------------------------------------------------- type names

/// Whether this is a valid type name (letters, digits and hyphens only, 1 to max_type_len characters).
pub fn isValidType(ur_type: []const u8) bool {
    if (ur_type.len == 0 or ur_type.len > max_type_len) return false;
    for (ur_type) |c| {
        const lower = std.ascii.toLower(c);
        if (lower >= 'a' and lower <= 'z') continue;
        if (c >= '0' and c <= '9') continue;
        if (c == '-') continue;
        return false;
    }
    return true;
}

/// Compares type names case-insensitively.
pub fn typeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn upperCase(text: []u8) void {
    for (text) |*c| c.* = std.ascii.toUpper(c.*);
}

fn digitsLen(value: u32) usize {
    var len: usize = 1;
    var rest = value / 10;
    while (rest != 0) : (rest /= 10) len += 1;
    return len;
}

/// Writes a decimal number. Returns the number of bytes written. The area must hold at least `digitsLen`.
fn writeDigits(out: []u8, value: u32) usize {
    var buf: [10]u8 = undefined;
    var index: usize = buf.len;
    var rest = value;
    while (true) {
        index -= 1;
        buf[index] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    const len = buf.len - index;
    @memcpy(out[0..len], buf[index..]);
    return len;
}

fn parseDigits(text: []const u8) Error!u32 {
    if (text.len == 0 or text.len > 10) return error.InvalidEncoding;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidEncoding;
        const digit: u32 = c - '0';
        if (value > (std.math.maxInt(u32) - digit) / 10) return error.InvalidEncoding;
        value = value * 10 + digit;
    }
    return value;
}

// ---------------------------------------------------------------- single part

/// Builds a single-part UR `ur:<type>/<bytewords(message)>`.
///
/// `message` is tagless CBOR (for a PSBT, a CBOR byte string; for the `bytes` type, an arbitrary
/// byte string wrapped in CBOR). A CRC-32 is appended to the bytewords.
pub fn encodeSingle(out: []u8, ur_type: []const u8, message: []const u8, case: TextCase) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;
    // CBOR is at least one byte. An empty message cannot be decoded as a UR, so it is rejected.
    if (message.len == 0) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1;
    if (out.len < prefix_len + bytewords.encodedLength(message.len, .minimal)) {
        return error.BufferTooSmall;
    }

    @memcpy(out[0..scheme.len], scheme);
    @memcpy(out[scheme.len..][0..ur_type.len], ur_type);
    out[scheme.len + ur_type.len] = '/';

    const body = try bytewords.encodeWithChecksum(out[prefix_len..], message, .minimal);
    const total = prefix_len + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// Wraps a raw byte string in a CBOR byte string and makes it a single-part UR.
///
/// Used for types such as `ur:bytes` or `ur:crypto-psbt` whose contents are a single byte string.
/// The payload is not copied into a temporary buffer (the CBOR header and body are encoded together).
pub fn encodeSingleByteString(
    out: []u8,
    ur_type: []const u8,
    payload: []const u8,
    case: TextCase,
) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1;
    const message_len = cbor.bytesLength(payload.len);
    if (out.len < prefix_len + bytewords.encodedLength(message_len, .minimal)) {
        return error.BufferTooSmall;
    }

    var header: [cbor.max_header_len]u8 = undefined;
    const header_bytes = try cbor.writeBytesHeader(&header, payload.len);

    @memcpy(out[0..scheme.len], scheme);
    @memcpy(out[scheme.len..][0..ur_type.len], ur_type);
    out[scheme.len + ur_type.len] = '/';

    const body = try bytewords.encodeWithChecksumParts(out[prefix_len..], &.{ header_bytes, payload }, .minimal);
    const total = prefix_len + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// Splits a UR string into type name, seq and bytewords part (case is returned as-is).
///
/// The returned slices point into `text`.
pub fn parse(text: []const u8) Error!Uri {
    if (text.len < scheme.len + 3) return error.InvalidEncoding;
    if (!typeEql(text[0..scheme.len], scheme)) return error.InvalidEncoding;

    const rest = text[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidEncoding;

    const ur_type = rest[0..slash];
    if (!isValidType(ur_type)) return error.InvalidEncoding;

    const tail = rest[slash + 1 ..];
    if (tail.len == 0) return error.InvalidEncoding;

    if (std.mem.indexOfScalar(u8, tail, '/')) |sep| {
        const seq_text = tail[0..sep];
        const body = tail[sep + 1 ..];
        if (body.len == 0) return error.InvalidEncoding;
        if (std.mem.indexOfScalar(u8, body, '/') != null) return error.InvalidEncoding;

        const dash = std.mem.indexOfScalar(u8, seq_text, '-') orelse return error.InvalidEncoding;
        const num = try parseDigits(seq_text[0..dash]);
        const len = try parseDigits(seq_text[dash + 1 ..]);
        if (num == 0 or len == 0) return error.InvalidEncoding;
        return .{ .ur_type = ur_type, .seq = .{ .num = num, .len = len }, .body = body };
    }

    return .{ .ur_type = ur_type, .body = tail };
}

/// Decodes a single-part UR. If `expected_type` is given, the type name is checked too.
///
/// It also checks that the decoded message is not broken as dCBOR.
pub fn decodeSingle(out: []u8, text: []const u8, expected_type: ?[]const u8) Error![]u8 {
    const uri = try parse(text);
    if (uri.seq != null) return error.InvalidEncoding;
    if (expected_type) |wanted| {
        if (!typeEql(wanted, uri.ur_type)) return error.InvalidEncoding;
    }

    const message = try bytewords.decode(out, uri.body, .minimal);
    if (!cbor.isWellFormed(message, true)) return error.InvalidEncoding;
    return message;
}

// ---------------------------------------------------------------- parts

/// Length of a part's CBOR `[seqNum, seqLen, messageLen, checksum, data]`.
///
/// Used to size the work area (`scratch` of `Encoder.init`).
pub fn partCborLength(seq_num: u32, seq_len: u32, message_len: usize, checksum: u32, data_len: usize) usize {
    return 1 + cbor.headLength(seq_num) + cbor.headLength(seq_len) + cbor.headLength(message_len) +
        cbor.headLength(checksum) + cbor.headLength(data_len) + data_len;
}

/// Maximum length the part CBOR for fragment length `fragment_len` can take.
///
/// The work areas (`scratch` of `Encoder.init` / `part_buf` of `Decoder.init`) only need
/// to be at least this large.
pub fn maxPartCborLength(fragment_len: usize) usize {
    return partCborLength(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(usize),
        std.math.maxInt(u32),
        fragment_len,
    );
}

/// Writes a part's CBOR (a five-element array).
pub fn encodePart(out: []u8, part: Part) Error![]u8 {
    if (part.seq_num == 0 or part.seq_len == 0 or part.message_len == 0) return error.InvalidEncoding;

    var pos: usize = 0;
    pos += (try cbor.writeArrayHeader(out[pos..], 5)).len;
    pos += (try cbor.writeUint(out[pos..], part.seq_num)).len;
    pos += (try cbor.writeUint(out[pos..], part.seq_len)).len;
    pos += (try cbor.writeUint(out[pos..], part.message_len)).len;
    pos += (try cbor.writeUint(out[pos..], part.checksum)).len;
    pos += (try cbor.writeBytes(out[pos..], part.data)).len;
    return out[0..pos];
}

/// Reads a part's CBOR. The returned `data` points into the input.
pub fn decodePart(bytes: []const u8) Error!Part {
    var reader = cbor.Reader.init(bytes);
    if (try reader.readArrayHeader() != 5) return error.InvalidEncoding;

    const seq_num = try reader.readUint();
    const seq_len = try reader.readUint();
    const message_len = try reader.readUint();
    const checksum = try reader.readUint();
    const data = try reader.readBytes();
    try reader.finish();

    if (seq_num == 0 or seq_num > std.math.maxInt(u32)) return error.InvalidEncoding;
    if (seq_len == 0 or seq_len > std.math.maxInt(u32)) return error.InvalidEncoding;
    if (message_len == 0 or message_len > std.math.maxInt(usize)) return error.InvalidEncoding;
    if (checksum > std.math.maxInt(u32)) return error.InvalidEncoding;

    return .{
        .seq_num = @intCast(seq_num),
        .seq_len = @intCast(seq_len),
        .message_len = @intCast(message_len),
        .checksum = @intCast(checksum),
        .data = data,
    };
}

/// Turns encoded part CBOR into `ur:<type>/<seqNum>-<seqLen>/<bytewords>`.
pub fn encodePartUr(
    out: []u8,
    ur_type: []const u8,
    seq_num: u32,
    seq_len: u32,
    part_cbor: []const u8,
    case: TextCase,
) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;
    if (seq_num == 0 or seq_len == 0) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1 + digitsLen(seq_num) + 1 + digitsLen(seq_len) + 1;
    if (out.len < prefix_len + bytewords.encodedLength(part_cbor.len, .minimal)) return error.BufferTooSmall;

    var pos: usize = 0;
    @memcpy(out[pos..][0..scheme.len], scheme);
    pos += scheme.len;
    @memcpy(out[pos..][0..ur_type.len], ur_type);
    pos += ur_type.len;
    out[pos] = '/';
    pos += 1;
    pos += writeDigits(out[pos..], seq_num);
    out[pos] = '-';
    pos += 1;
    pos += writeDigits(out[pos..], seq_len);
    out[pos] = '/';
    pos += 1;

    const body = try bytewords.encodeWithChecksum(out[pos..], part_cbor, .minimal);
    const total = pos + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// Extracts a part from a multipart UR string.
pub const DecodedPart = struct {
    ur_type: []const u8,
    seq: Seq,
    part: Part,
};

/// Decodes a UR string (multipart) into a part.
///
/// If the path's `seq` and the CBOR's `seqNum` / `seqLen` disagree, error.InvalidEncoding.
/// The returned `part.data` points into `part_buf`.
pub fn decodePartUr(part_buf: []u8, text: []const u8) Error!DecodedPart {
    const uri = try parse(text);
    const seq = uri.seq orelse return error.InvalidEncoding;

    const part_bytes = try bytewords.decode(part_buf, uri.body, .minimal);
    const part = try decodePart(part_bytes);
    if (part.seq_num != seq.num or part.seq_len != seq.len) return error.InvalidEncoding;

    return .{ .ur_type = uri.ur_type, .seq = seq, .part = part };
}

// ---------------------------------------------------------------- splitting

/// Decides the actual fragment length from the message length and the fragment length bounds
/// (findNominalFragmentLength in BCR-2024-001 §5).
///
/// The fragment length is "the smallest part count that makes the message fit in `max_fragment_len`".
pub fn findFragmentLength(message_len: usize, min_fragment_len: usize, max_fragment_len: usize) Error!usize {
    if (message_len == 0) return error.InvalidEncoding;
    if (min_fragment_len == 0 or max_fragment_len < min_fragment_len) return error.InvalidEncoding;

    const max_fragment_count = message_len / min_fragment_len;
    var fragment_len = message_len;
    var count: usize = 1;
    while (count <= max_fragment_count) : (count += 1) {
        fragment_len = (message_len + count - 1) / count;
        if (fragment_len <= max_fragment_len) break;
    }
    return fragment_len;
}

/// Generates sequential parts (`seqNum` = 1, 2, ..., `seqLen`).
///
/// Fountain-code redundant parts are not generated. Once everything has been sent, they are sent
/// again from 1 in case the receiver missed some parts (this implementation supports the fixed-rate scheme only).
pub const Encoder = struct {
    /// Type name (the caller must keep it alive).
    ur_type: []const u8,
    /// The tagless CBOR message (the caller must keep it alive).
    message: []const u8,
    /// Bytes in one fragment.
    fragment_len: usize,
    /// Fragment count (= number of sequential parts).
    seq_len: u32,
    /// CRC-32 of the whole message.
    checksum: u32,
    /// The next part number to return (one-based). Complete once it exceeds `seq_len`.
    next_seq_num: u32,
    /// Work area for assembling the part CBOR (provided by the caller and outliving the `Encoder`).
    scratch: []u8,

    /// `message` is tagless CBOR. `max_fragment_len` is the maximum number of bytes to put in one
    /// part (decided by the QR code capacity). `min_fragment_len` is a lower bound to avoid splitting
    /// too finely (the bc-ur / URKit default is `default_min_fragment_len`).
    pub fn init(
        ur_type: []const u8,
        message: []const u8,
        max_fragment_len: usize,
        min_fragment_len: usize,
        scratch: []u8,
    ) Error!Encoder {
        if (!isValidType(ur_type)) return error.InvalidEncoding;

        const fragment_len = try findFragmentLength(message.len, min_fragment_len, max_fragment_len);
        const seq_len = (message.len + fragment_len - 1) / fragment_len;
        if (seq_len > std.math.maxInt(u32)) return error.InvalidEncoding;

        if (scratch.len < maxPartCborLength(fragment_len)) return error.BufferTooSmall;

        return .{
            .ur_type = ur_type,
            .message = message,
            .fragment_len = fragment_len,
            .seq_len = @intCast(seq_len),
            .checksum = bytewords.crc32(message),
            .next_seq_num = 1,
            .scratch = scratch,
        };
    }

    /// Whether every sequential part has been returned.
    pub fn isComplete(self: *const Encoder) bool {
        return self.next_seq_num > self.seq_len;
    }

    /// Sends them again from 1 (a fixed-rate scheme in place of a fountain code).
    pub fn restart(self: *Encoder) void {
        self.next_seq_num = 1;
    }

    /// Turns the next part into a UR string. null once every part has been returned.
    ///
    /// When the message fits in one fragment, the spec REQUIRES the single-part form, so
    /// `ur:<type>/<message>` is returned exactly once.
    pub fn next(self: *Encoder, out: []u8, case: TextCase) Error!?[]u8 {
        if (self.isComplete()) return null;

        if (self.seq_len == 1) {
            const single = try encodeSingle(out, self.ur_type, self.message, case);
            self.next_seq_num = 2;
            return single;
        }

        const seq_num = self.next_seq_num;
        const start = (seq_num - 1) * self.fragment_len;
        const take = @min(self.fragment_len, self.message.len - start);

        var pos: usize = 0;
        pos += (try cbor.writeArrayHeader(self.scratch[pos..], 5)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], seq_num)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.seq_len)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.message.len)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.checksum)).len;
        pos += (try cbor.writeBytesHeader(self.scratch[pos..], self.fragment_len)).len;
        @memcpy(self.scratch[pos..][0..take], self.message[start..][0..take]);
        @memset(self.scratch[pos + take ..][0 .. self.fragment_len - take], 0);
        pos += self.fragment_len;

        const encoded = try encodePartUr(out, self.ur_type, seq_num, self.seq_len, self.scratch[0..pos], case);
        self.next_seq_num += 1;
        return encoded;
    }

    /// Size of `out` needed to output the largest part.
    pub fn maxPartLength(ur_type_len: usize, fragment_len: usize) usize {
        const part_len = maxPartCborLength(fragment_len);
        return scheme.len + ur_type_len + 1 + 10 + 1 + 10 + 1 + bytewords.encodedLength(part_len, .minimal);
    }
};

// ---------------------------------------------------------------- decoder

/// Result of `Decoder.receive`.
pub const Status = enum {
    /// Taken in, but not all parts are present yet (the message is incomplete).
    need_more,
    /// The message became complete as a result (`Decoder.result` is valid).
    complete,
    /// A part already held (duplicate). The state does not change.
    duplicate,
    /// A fountain-code redundant part (seqNum > seqLen). Ignored: this implementation cannot use it to recover.
    fountain_unsupported,
};

/// Collects multipart (and single-part) URs and reconstructs the message.
///
/// Parts may be passed out of order and with duplicates. Only when all `seqLen` parts are present is the
/// CRC-32 verified; if it does not match, error.ChecksumMismatch (the message is not treated as complete).
pub const Decoder = struct {
    /// Bitmap of received fragments (at least `ceil(seqLen / 8)` bytes).
    bits: []u8,
    /// Storage for the reconstructed message (at least the maximum message length expected).
    message: []u8,
    /// Work area for decoding part CBOR (at least `maxPartCborLength(fragment_len)` bytes).
    part_buf: []u8,

    type_buf: [max_type_len]u8 = undefined,
    type_len: usize = 0,
    seq_len: u32 = 0,
    message_len: usize = 0,
    fragment_len: usize = 0,
    checksum: u32 = 0,
    received_count: usize = 0,
    fountain_parts: usize = 0,
    single_part: bool = false,
    complete: bool = false,

    pub fn init(bits: []u8, message: []u8, part_buf: []u8) Decoder {
        return .{ .bits = bits, .message = message, .part_buf = part_buf };
    }

    /// Discards the state so that it can start over from the beginning.
    pub fn reset(self: *Decoder) void {
        self.type_len = 0;
        self.seq_len = 0;
        self.message_len = 0;
        self.fragment_len = 0;
        self.checksum = 0;
        self.received_count = 0;
        self.fountain_parts = 0;
        self.single_part = false;
        self.complete = false;
        if (self.bits.len > 0) @memset(self.bits, 0);
    }

    /// Type name of the first accepted part (an empty slice if nothing has been received).
    pub fn urType(self: *const Decoder) []const u8 {
        return self.type_buf[0..self.type_len];
    }

    /// Returns the message if it is complete.
    pub fn result(self: *const Decoder) ?[]const u8 {
        if (!self.complete) return null;
        return self.message[0..self.message_len];
    }

    /// Number of parts needed (0 if nothing has been received).
    pub fn expectedFragmentCount(self: *const Decoder) usize {
        return self.seq_len;
    }

    /// Number of parts received.
    pub fn receivedFragmentCount(self: *const Decoder) usize {
        return self.received_count;
    }

    /// Number of fountain parts ignored.
    pub fn fountainPartCount(self: *const Decoder) usize {
        return self.fountain_parts;
    }

    fn isReceived(self: *const Decoder, index: usize) bool {
        return (self.bits[index / 8] >> @intCast(index % 8)) & 1 != 0;
    }

    fn setReceived(self: *Decoder, index: usize) void {
        self.bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }

    /// Takes in one UR string.
    ///
    /// After completion nothing is taken in and `Status.duplicate` is returned. Malformed input and
    /// metadata that disagrees with the first part (a part of another message, say) are rejected with an error.
    /// **When an error is returned, the state of parts not yet accepted (bitmap, received count) is not
    /// changed**, so a caller that ignores the error and keeps reading is not corrupted. However, the
    /// type name parsed from the first part is recorded (so that streams of different types are not mixed).
    /// Call `reset` to start over from the beginning.
    pub fn receive(self: *Decoder, text: []const u8) Error!Status {
        const uri = try parse(text);

        // The type name is fixed by the first part and must match afterwards.
        if (self.type_len == 0) {
            @memcpy(self.type_buf[0..uri.ur_type.len], uri.ur_type);
            self.type_len = uri.ur_type.len;
        } else if (!typeEql(self.type_buf[0..self.type_len], uri.ur_type)) {
            return error.InvalidEncoding;
        }

        if (self.complete) return .duplicate;

        if (uri.seq == null) return self.receiveSingle(uri.body);

        const decoded = try decodePartUr(self.part_buf, text);
        const part = decoded.part;

        if (self.seq_len == 0) {
            // The first part fixes the metadata for the whole message.
            const seq_len: usize = part.seq_len;
            if ((part.message_len + seq_len - 1) / seq_len != part.data.len) return error.InvalidEncoding;
            if ((part.message_len + part.data.len - 1) / part.data.len != seq_len) return error.InvalidEncoding;
            if (self.bits.len < (seq_len + 7) / 8) return error.BufferTooSmall;
            if (self.message.len < part.message_len) return error.BufferTooSmall;

            self.seq_len = part.seq_len;
            self.message_len = part.message_len;
            self.fragment_len = part.data.len;
            self.checksum = part.checksum;
            @memset(self.bits[0 .. (seq_len + 7) / 8], 0);
        } else if (part.seq_len != self.seq_len or
            part.message_len != self.message_len or
            part.checksum != self.checksum or
            part.data.len != self.fragment_len)
        {
            return error.InvalidEncoding;
        }

        if (part.seq_num > self.seq_len) {
            // A fountain-code redundant part. Not used for recovery.
            self.fountain_parts += 1;
            return .fountain_unsupported;
        }

        const index: usize = part.seq_num - 1;
        if (self.isReceived(index)) return .duplicate;

        // The last part contains padding, so anything beyond the message length is dropped
        // (the CRC-32 is computed over the whole message with the padding excluded).
        const offset = index * self.fragment_len;
        const take = @min(part.data.len, self.message_len - offset);
        @memcpy(self.message[offset..][0..take], part.data[0..take]);
        self.setReceived(index);
        self.received_count += 1;

        if (self.received_count < self.seq_len) return .need_more;

        const assembled = self.message[0..self.message_len];
        if (bytewords.crc32(assembled) != self.checksum) return error.ChecksumMismatch;
        if (!cbor.isWellFormed(assembled, true)) return error.InvalidEncoding;

        self.complete = true;
        return .complete;
    }

    /// Takes in a single-part UR.
    fn receiveSingle(self: *Decoder, body: []const u8) Error!Status {
        if (self.seq_len != 0 and !self.single_part) {
            // A single part in the middle of a multipart sequence is wrong.
            return error.InvalidEncoding;
        }

        const message = try bytewords.decode(self.part_buf, body, .minimal);
        if (!cbor.isWellFormed(message, true)) return error.InvalidEncoding;
        if (self.message.len < message.len) return error.BufferTooSmall;

        @memcpy(self.message[0..message.len], message);
        self.seq_len = 1;
        self.message_len = message.len;
        self.fragment_len = message.len;
        self.checksum = bytewords.crc32(message);
        self.single_part = true;
        self.complete = true;
        return .complete;
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn asHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

/// The message from the BCR-2024-001 §5 test vector (256 bytes, seed "Wolf").
///
/// Shared with `ur_receive.zig`'s tests, so the reference vector has a single definition.
pub const message_256 = [256]u8{
    0x91, 0x6e, 0xc6, 0x5c, 0xf7, 0x7c, 0xad, 0xf5, 0x5c, 0xd7, 0xf9, 0xcd, 0xa1, 0xa1, 0x03, 0x00,
    0x26, 0xdd, 0xd4, 0x2e, 0x90, 0x5b, 0x77, 0xad, 0xc3, 0x6e, 0x4f, 0x2d, 0x3c, 0xcb, 0xa4, 0x4f,
    0x7f, 0x04, 0xf2, 0xde, 0x44, 0xf4, 0x2d, 0x84, 0xc3, 0x74, 0xa0, 0xe1, 0x49, 0x13, 0x6f, 0x25,
    0xb0, 0x18, 0x52, 0x54, 0x59, 0x61, 0xd5, 0x5f, 0x7f, 0x7a, 0x8c, 0xde, 0x6d, 0x0e, 0x2e, 0xc4,
    0x3f, 0x3b, 0x2d, 0xcb, 0x64, 0x4a, 0x22, 0x09, 0xe8, 0xc9, 0xe3, 0x4a, 0xf5, 0xc4, 0x74, 0x79,
    0x84, 0xa5, 0xe8, 0x73, 0xc9, 0xcf, 0x5f, 0x96, 0x5e, 0x25, 0xee, 0x29, 0x03, 0x9f, 0xdf, 0x8c,
    0xa7, 0x4f, 0x1c, 0x76, 0x9f, 0xc0, 0x7e, 0xb7, 0xeb, 0xae, 0xc4, 0x6e, 0x06, 0x95, 0xae, 0xa6,
    0xcb, 0xd6, 0x0b, 0x3e, 0xc4, 0xbb, 0xff, 0x1b, 0x9f, 0xfe, 0x8a, 0x9e, 0x72, 0x40, 0x12, 0x93,
    0x77, 0xb9, 0xd3, 0x71, 0x1e, 0xd3, 0x8d, 0x41, 0x2f, 0xbb, 0x44, 0x42, 0x25, 0x6f, 0x1e, 0x6f,
    0x59, 0x5e, 0x0f, 0xc5, 0x7f, 0xed, 0x45, 0x1f, 0xb0, 0xa0, 0x10, 0x1f, 0xb7, 0x6b, 0x1f, 0xb1,
    0xe1, 0xb8, 0x8c, 0xfd, 0xfd, 0xaa, 0x94, 0x62, 0x94, 0xa4, 0x7d, 0xe8, 0xff, 0xf1, 0x73, 0xf0,
    0x21, 0xc0, 0xe6, 0xf6, 0x5b, 0x05, 0xc0, 0xa4, 0x94, 0xe5, 0x07, 0x91, 0x27, 0x0a, 0x00, 0x50,
    0xa7, 0x3a, 0xe6, 0x9b, 0x67, 0x25, 0x50, 0x5a, 0x2e, 0xc8, 0xa5, 0x79, 0x14, 0x57, 0xc9, 0x87,
    0x6d, 0xd3, 0x4a, 0xad, 0xd1, 0x92, 0xa5, 0x3a, 0xa0, 0xdc, 0x66, 0xb5, 0x56, 0xc0, 0xc2, 0x15,
    0xc7, 0xce, 0xb8, 0x24, 0x8b, 0x71, 0x7c, 0x22, 0x95, 0x1e, 0x65, 0x30, 0x5b, 0x56, 0xa3, 0x70,
    0x6e, 0x3e, 0x86, 0xeb, 0x01, 0xc8, 0x03, 0xbb, 0xf9, 0x15, 0xd8, 0x0e, 0xdc, 0xd6, 0x4d, 0x4d,
};

/// The nine sequential parts bc-ur's test_ur_encoder expects (`ur:bytes`, max_fragment_len = 30).
///
/// Shared with `ur_receive.zig`'s tests, so the reference vector has a single definition.
pub const expected_parts = [9][]const u8{
    "ur:bytes/1-9/lpadascfadaxcywenbpljkhdcahkadaemejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtdkgslpgh",
    "ur:bytes/2-9/lpaoascfadaxcywenbpljkhdcagwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsgmghhkhstlrdcxaefz",
    "ur:bytes/3-9/lpaxascfadaxcywenbpljkhdcahelbknlkuejnbadmssfhfrdpsbiegecpasvssovlgeykssjykklronvsjksopdzmol",
    "ur:bytes/4-9/lpaaascfadaxcywenbpljkhdcasotkhemthydawydtaxneurlkosgwcekonertkbrlwmplssjtammdplolsbrdzcrtas",
    "ur:bytes/5-9/lpahascfadaxcywenbpljkhdcatbbdfmssrkzmcwnezelennjpfzbgmuktrhtejscktelgfpdlrkfyfwdajldejokbwf",
    "ur:bytes/6-9/lpamascfadaxcywenbpljkhdcackjlhkhybssklbwefectpfnbbectrljectpavyrolkzczcpkmwidmwoxkilghdsowp",
    "ur:bytes/7-9/lpatascfadaxcywenbpljkhdcavszmwnjkwtclrtvaynhpahrtoxmwvwatmedibkaegdosftvandiodagdhthtrlnnhy",
    "ur:bytes/8-9/lpayascfadaxcywenbpljkhdcadmsponkkbbhgsoltjntegepmttmoonftnbuoiyrehfrtsabzsttorodklubbuyaetk",
    "ur:bytes/9-9/lpasascfadaxcywenbpljkhdcajskecpmdckihdyhphfotjojtfmlnwmadspaxrkytbztpbauotbgtgtaeaevtgavtny",
};

/// The UR message = CBOR byte string `59 0100` + 256 bytes (259 bytes in total).
///
/// Shared with `ur_receive.zig`'s tests, so the reference vector has a single definition.
pub fn makeUrMessage(buf: *[259]u8) []u8 {
    buf[0] = 0x59;
    buf[1] = 0x01;
    buf[2] = 0x00;
    @memcpy(buf[3..], &message_256);
    return buf;
}

test "matches the BCR-2020-005 single-part example" {
    // ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox
    // (Bytewords of the tagless CBOR a10150c7098580125e2ab0981253468b2dbc52)
    var message_buf: [32]u8 = undefined;
    const message = asHex(&message_buf, "a10150c7098580125e2ab0981253468b2dbc52");

    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox",
        try encodeSingle(&out, "seed", message, .lower),
    );

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(
        message,
        try decodeSingle(&decoded, "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "seed"),
    );

    // A different type name is rejected.
    try testing.expectError(
        error.InvalidEncoding,
        decodeSingle(&decoded, "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "bytes"),
    );
    // The multipart form is rejected by decodeSingle.
    try testing.expectError(
        error.InvalidEncoding,
        decodeSingle(&decoded, "ur:seed/1-9/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "seed"),
    );
}

test "matches the bc-ur-rust UR test vector" {
    // bc-ur-rust src/ur.rs test_ur: CBOR [1, 2, 3].
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("ur:test/lsadaoaxjygonesw", try encodeSingle(&out, "test", &message, .lower));
    // Uppercase form for QR codes ("UR:TEST/LSADAOAXJYGONESW" in bc-ur-rust test_ur).
    try testing.expectEqualStrings("UR:TEST/LSADAOAXJYGONESW", try encodeSingle(&out, "test", &message, .upper));

    // An uppercase UR decodes too (case agnostic).
    var decoded: [8]u8 = undefined;
    try testing.expectEqualStrings(&message, try decodeSingle(&decoded, "UR:TEST/LSADAOAXJYGONESW", "test"));
    try testing.expectEqualStrings(&message, try decodeSingle(&decoded, "ur:test/lsadaoaxjygonesw", null));
}

test "matches the bc-ur single-part UR test vector" {
    // bc-ur test/test.cpp test_single_part_ur: a 50-byte CBOR byte string.
    var payload_buf: [64]u8 = undefined;
    const payload = asHex(
        &payload_buf,
        "916ec65cf77cadf55cd7f9cda1a1030026ddd42e905b77adc36e4f2d3ccba44f7f04f2de44f42d84c374a0e1" ++
            "49136f25b018",
    );

    var out: [256]u8 = undefined;
    const text = try encodeSingleByteString(&out, type_bytes, payload, .lower);
    try testing.expectEqualStrings(
        "ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch",
        text,
    );

    var decoded: [64]u8 = undefined;
    const message = try decodeSingle(&decoded, text, type_bytes);
    // The ur:bytes message is a CBOR byte string, so extract the payload inside.
    var reader = cbor.Reader.init(message);
    try testing.expectEqualStrings(payload, try reader.readBytes());
    try reader.finish();
}

test "matches the findNominalFragmentLength test vectors" {
    // BCR-2024-001 §5 testFindFragmentLength
    try testing.expectEqual(@as(usize, 1764), try findFragmentLength(12345, 1005, 1955));
    try testing.expectEqual(@as(usize, 12345), try findFragmentLength(12345, 1005, 30000));
    // A 259-byte message in chunks of at most 30 bytes -> 29 bytes x 9 (the same as the test vector above)
    try testing.expectEqual(@as(usize, 29), try findFragmentLength(259, default_min_fragment_len, 30));

    try testing.expectError(error.InvalidEncoding, findFragmentLength(0, 10, 30));
    try testing.expectError(error.InvalidEncoding, findFragmentLength(100, 0, 30));
    try testing.expectError(error.InvalidEncoding, findFragmentLength(100, 30, 10));
}

test "matches the bc-ur multipart UR test vector (sequential parts)" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 9), encoder.seq_len);
    try testing.expectEqual(@as(usize, 29), encoder.fragment_len);

    var out: [256]u8 = undefined;
    for (expected_parts) |expected| {
        const part = (try encoder.next(&out, .lower)) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(expected, part);
    }
    try testing.expect(encoder.isComplete());
    try testing.expectEqual(@as(?[]u8, null), try encoder.next(&out, .lower));

    // Sending again returns the same sequence.
    encoder.restart();
    try testing.expectEqualStrings(expected_parts[0], (try encoder.next(&out, .lower)).?);
}

test "reconstructs a multipart message out of order and with duplicates" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var parts: [9][]u8 = undefined;
    var part_bufs: [9][256]u8 = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(part_bufs[i][0..part.len], part);
        slot.* = part_bufs[i][0..part.len];
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // Pass them out of order and with duplicates (3, 1, 3, 9, 5, ...).
    const order = [_]usize{ 2, 0, 2, 8, 4, 1, 6, 3, 7, 5 };
    for (order, 0..) |index, step| {
        const status = try decoder.receive(parts[index]);
        if (step < order.len - 1) {
            // Midway it can only be "not enough yet" or "duplicate".
            try testing.expect(status == .need_more or status == .duplicate);
            try testing.expect(decoder.result() == null);
        } else {
            try testing.expectEqual(Status.complete, status);
        }
    }

    try testing.expectEqual(@as(usize, 9), decoder.receivedFragmentCount());
    try testing.expectEqual(@as(usize, 0), decoder.fountainPartCount());
    try testing.expectEqualStrings(ur_message, decoder.result().?);
}

test "does not treat the message as complete while parts are missing" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // Pass only 1, 2, 4, 5 (3, 6..9 are missing).
    for ([_]usize{ 0, 1, 3, 4 }) |index| {
        try testing.expectEqual(Status.need_more, try decoder.receive(parts[index][0..lengths[index]]));
        try testing.expect(decoder.result() == null);
        try testing.expect(!decoder.complete);
    }
    try testing.expectEqual(@as(usize, 4), decoder.receivedFragmentCount());
    try testing.expectEqual(@as(usize, 9), decoder.expectedFragmentCount());

    // Passing the rest completes it.
    for ([_]usize{ 2, 5, 6, 7, 8 }) |index| {
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expectEqualStrings(ur_message, decoder.result().?);
    // A part received after completion is not taken in.
    try testing.expectEqual(Status.duplicate, try decoder.receive(parts[0][0..lengths[0]]));
}

test "round-trips with a two-digit seq and trims the padding" {
    // Split the CBOR byte string (59 012c + 300 bytes = 303 bytes) into 11 parts.
    var message: [303]u8 = undefined;
    message[0] = 0x59;
    message[1] = 0x01;
    message[2] = 0x2c;
    for (message[3..], 0..) |*byte, i| byte.* = @intCast((i * 31 + 7) % 256);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, &message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 11), encoder.seq_len);
    try testing.expectEqual(@as(usize, 28), encoder.fragment_len);

    var parts: [11][256]u8 = undefined;
    var lengths: [11]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }
    try testing.expect(std.mem.startsWith(u8, parts[0][0..lengths[0]], "ur:bytes/1-11/"));
    try testing.expect(std.mem.startsWith(u8, parts[10][0..lengths[10]], "ur:bytes/11-11/"));

    var bits: [8]u8 = undefined;
    var assembled_buf: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &assembled_buf, &part_buf);

    // Pass them in reverse order (11, 10, ..., 1).
    var index: usize = parts.len;
    while (index > 0) {
        index -= 1;
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expectEqualStrings(&message, decoder.result().?);
}

test "round-trips when the split is exact (no padding)" {
    // Split the CBOR byte string (58 1a + 26 bytes = 28 bytes) into 2 chunks of 14 bytes.
    var message: [28]u8 = undefined;
    message[0] = 0x58;
    message[1] = 0x1a;
    for (message[2..], 0..) |*byte, i| byte.* = @intCast((i * 17 + 3) % 256);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, &message, 14, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 2), encoder.seq_len);
    try testing.expectEqual(@as(usize, 14), encoder.fragment_len);

    var out: [256]u8 = undefined;
    const part1 = (try encoder.next(&out, .lower)).?;
    var part1_copy: [256]u8 = undefined;
    @memcpy(part1_copy[0..part1.len], part1);
    const part2 = (try encoder.next(&out, .lower)).?;
    var part2_copy: [256]u8 = undefined;
    @memcpy(part2_copy[0..part2.len], part2);

    var bits: [8]u8 = undefined;
    var assembled: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &assembled, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(part2_copy[0..part2.len]));
    try testing.expectEqual(Status.complete, try decoder.receive(part1_copy[0..part1.len]));
    try testing.expectEqualStrings(&message, decoder.result().?);
}

test "rejects broken parts and does not falsely declare completion" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // (1) A part with a broken bytewords checksum
    var broken = parts[0];
    broken[lengths[0] - 1] = if (broken[lengths[0] - 1] == 'a') 'b' else 'a';
    try testing.expectError(error.ChecksumMismatch, decoder.receive(broken[0..lengths[0]]));

    // (2) A part whose data alone was rewritten (the bytewords checksum is recomputed)
    var part_cbor: [128]u8 = undefined;
    const tampered = try decodePartUr(&part_buf, parts[3][0..lengths[3]]);
    var data: [32]u8 = undefined;
    @memcpy(data[0..tampered.part.data.len], tampered.part.data);
    data[0] ^= 0xff;
    const tampered_part = Part{
        .seq_num = tampered.part.seq_num,
        .seq_len = tampered.part.seq_len,
        .message_len = tampered.part.message_len,
        .checksum = tampered.part.checksum,
        .data = data[0..tampered.part.data.len],
    };
    const tampered_cbor = try encodePart(&part_cbor, tampered_part);
    var tampered_ur: [256]u8 = undefined;
    const tampered_text = try encodePartUr(
        &tampered_ur,
        type_bytes,
        tampered_part.seq_num,
        tampered_part.seq_len,
        tampered_cbor,
        .lower,
    );

    // Pass every remaining part, then the broken fourth one last.
    for ([_]usize{ 0, 1, 2, 4, 5, 6, 7, 8 }) |index| {
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expect(decoder.result() == null);
    try testing.expectError(error.ChecksumMismatch, decoder.receive(tampered_text));
    // The checksum does not match, so it never completes.
    try testing.expect(decoder.result() == null);
    try testing.expect(!decoder.complete);
}

test "rejects parts of another message and malformed input" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(parts[0][0..lengths[0]]));

    // A different type name
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:crypto-psbt/2-9/lpaoascfadaxcywenbpljkhdcagw"));
    // A different message (different checksum)
    var other_message: [259]u8 = undefined;
    _ = makeUrMessage(&other_message);
    other_message[3] ^= 0xff;
    var other_scratch: [128]u8 = undefined;
    var other_encoder = try Encoder.init(type_bytes, &other_message, 30, default_min_fragment_len, &other_scratch);
    var other_out: [256]u8 = undefined;
    _ = (try other_encoder.next(&other_out, .lower)).?;
    const other_part2 = (try other_encoder.next(&other_out, .lower)).?;
    try testing.expectError(error.InvalidEncoding, decoder.receive(other_part2));

    // Malformed syntax
    try testing.expectError(error.InvalidEncoding, decoder.receive(""));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("http://example.com/1-9/abcd"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/0-9/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1/1-9/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1-9/"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/x-y/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1-9/oooo")); // not in the vocabulary
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bad_type!/1-9/lpao"));

    // The state is unchanged (only one part received).
    try testing.expectEqual(@as(usize, 1), decoder.receivedFragmentCount());
    try testing.expect(decoder.result() == null);
}

test "accepts fountain-code redundant parts but does not use them for recovery" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    const part1 = (try encoder.next(&out, .lower)).?;
    var part1_copy: [256]u8 = undefined;
    @memcpy(part1_copy[0..part1.len], part1);

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(part1_copy[0..part1.len]));

    // Build a redundant part by hand (seqNum = 10 > seqLen = 9).
    const decoded = try decodePartUr(&part_buf, part1_copy[0..part1.len]);
    const fountain_part = Part{
        .seq_num = decoded.part.seq_len + 1,
        .seq_len = decoded.part.seq_len,
        .message_len = decoded.part.message_len,
        .checksum = decoded.part.checksum,
        .data = decoded.part.data,
    };
    var cbor_buf: [128]u8 = undefined;
    const fountain_cbor = try encodePart(&cbor_buf, fountain_part);
    var ur_buf: [256]u8 = undefined;
    const fountain_ur = try encodePartUr(
        &ur_buf,
        type_bytes,
        fountain_part.seq_num,
        fountain_part.seq_len,
        fountain_cbor,
        .lower,
    );

    try testing.expectEqual(Status.fountain_unsupported, try decoder.receive(fountain_ur));
    try testing.expectEqual(@as(usize, 1), decoder.fountainPartCount());
    try testing.expectEqual(@as(usize, 1), decoder.receivedFragmentCount());
    try testing.expect(decoder.result() == null);
}

test "a single-part UR can be received by Decoder too" {
    const payload = "00112233445566778899aabbccddeeff";

    var out: [256]u8 = undefined;
    const text = try encodeSingleByteString(&out, type_crypto_psbt, payload, .lower);

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.complete, try decoder.receive(text));
    try testing.expectEqualStrings(type_crypto_psbt, decoder.urType());

    // The contents are a CBOR byte string.
    var reader = cbor.Reader.init(decoder.result().?);
    const decoded_payload = try reader.readBytes();
    try reader.finish();
    try testing.expectEqualStrings(payload, decoded_payload);
}

test "a small message is output in single-part form" {
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    var scratch: [64]u8 = undefined;
    var encoder = try Encoder.init("test", &message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 1), encoder.seq_len);

    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("ur:test/lsadaoaxjygonesw", (try encoder.next(&out, .lower)).?);
    try testing.expect(encoder.isComplete());
    try testing.expectEqual(@as(?[]u8, null), try encoder.next(&out, .lower));
}

test "BufferTooSmall when the output buffer is too small" {
    var small: [8]u8 = undefined;
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    try testing.expectError(error.BufferTooSmall, encodeSingle(&small, "test", &message, .lower));
    try testing.expectError(error.BufferTooSmall, encodeSingleByteString(&small, type_bytes, "hello", .lower));

    // An Encoder with too small a work area cannot be created.
    var tiny_scratch: [8]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        Encoder.init(type_bytes, &message_256, 30, default_min_fragment_len, &tiny_scratch),
    );

    // A Decoder with too small a message area.
    var tiny_message: [4]u8 = undefined;
    var bits: [8]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &tiny_message, &part_buf);
    try testing.expectError(
        error.BufferTooSmall,
        decoder.receive("ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch"),
    );
}

test "type name and seq syntax" {
    try testing.expect(isValidType("bytes"));
    try testing.expect(isValidType("crypto-psbt"));
    try testing.expect(isValidType("crypto-account"));
    try testing.expect(isValidType("BYTES"));
    try testing.expect(!isValidType(""));
    try testing.expect(!isValidType("bad_type"));
    try testing.expect(!isValidType("bad type"));
    try testing.expect(!isValidType("crypto/psbt"));
    try testing.expect(!isValidType("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")); // 33 characters

    // A one-based seq can be read.
    const uri = try parse("ur:bytes/1-9/lpaoascf");
    try testing.expectEqual(@as(u32, 1), uri.seq.?.num);
    try testing.expectEqual(@as(u32, 9), uri.seq.?.len);
    try testing.expectEqualStrings("bytes", uri.ur_type);
    try testing.expectEqualStrings("lpaoascf", uri.body);

    const single = try parse("ur:seed/oyadgd");
    try testing.expect(single.seq == null);
    try testing.expectEqualStrings("seed", single.ur_type);
    // An uppercase UR can be parsed too.
    const upper = try parse("UR:BYTES/10-9/LPAOASCF");
    try testing.expectEqual(@as(u32, 10), upper.seq.?.num);
    try testing.expectEqual(@as(u32, 9), upper.seq.?.len);
}
