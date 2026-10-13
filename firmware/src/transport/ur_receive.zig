//! Multipart UR receiver: turns the sequence of QR strings a camera sees into one payload.
//!
//! The camera path is **one QR code per frame**, so a multi-part UR arrives as a sequence of
//! strings, one at a time, possibly with frames missed, repeated, or out of order:
//!
//!     qr_decode (image -> string) -> Receiver (strings -> message) -> btc_psbt.Psbt.parse
//!
//! **Relation to `ur.Decoder`**: this module sits on top of `ur.zig` (it uses `ur.parse`,
//! `ur.decodePartUr`, `ur.Part`, `bytewords` and `cbor`), but it is not a thin wrapper, because
//! `ur.Decoder` is deliberately permissive in ways a *signing* device cannot afford:
//!   - it accepts whatever type name arrives first, so two transfers can be merged into one message;
//!   - it treats a repeat of an index as a harmless duplicate **without comparing the bytes**, so
//!     two different fragments for one index are silently resolved by keeping the first one;
//!   - it reports every rejection as `error.InvalidEncoding`;
//!   - after a failed whole-message CRC it keeps every part marked as received, so the message can
//!     never be completed afterwards (a re-scan of the correct part is reported as a duplicate).
//! The receiver here instead fixes the type **before** anything arrives, compares duplicate bytes,
//! returns distinct errors the UI can explain, and drops the whole assembly when the checksum does
//! not match.
//!
//! **Scope / deliberate limits**
//! - Sequential parts only (`seqNum` = 1..seqLen). Fountain-code / MUR redundant parts
//!   (`seqNum` > `seqLen`, BCR-2024-001) are **not** implemented: this firmware's encoder never
//!   generates them, and receiving one is reported as `error.FountainUnsupported` (the caller may
//!   ignore that error and keep scanning, since the state does not change). There is no
//!   fountain-fragment mixing and no recovery from parts that were never scanned.
//! - A message that fails its final checksum is not repaired; the user re-scans.
//! - No allocation anywhere: the caller owns every buffer, so a receiver is a fixed-size struct
//!   and a sender can never ask the device for more memory than the caller prepared. The buffers
//!   are also the bounds: `message` caps `messageLen`, the `bits` bitmap caps `seqLen`.
//!
//! Reference: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md
//!            https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2024-001-multipart-ur.md
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const ur = @import("ur.zig");
const bytewords = @import("bytewords.zig");
const cbor = @import("cbor.zig");

/// Largest payload the rest of the firmware accepts (the PSBT / card file limit, 64 KB).
///
/// The receiver itself only enforces the caller's `message` buffer; this is the ceiling the
/// device-level code uses (`app/device.zig` `problemForFileSize`, `cli/main.zig`).
pub const max_payload_len = 64 * 1024;

/// Errors the receiver can return.
///
/// A superset of the shared `Error` (malformed encoding, exhausted buffers, checksum failures)
/// with the states a camera-driven UI has to tell apart. Every case is reported as an error:
/// a part is never merged "best effort".
pub const ReceiveError = Error || error{
    /// The assembled message was requested while parts are still missing (or after a failure).
    Incomplete,
    /// The message does not fit the caller's `message` buffer, or needs more parts than the
    /// `bits` bitmap can track.
    TooLarge,
    /// A part of a different UR type: another transfer, or a QR code that is not part of this one.
    WrongType,
    /// The same part index arrived again with different bytes. That is corruption or an attack,
    /// and silently keeping one of the two would mean signing a message nobody encoded.
    ConflictingDuplicate,
    /// Part metadata (seqLen, messageLen, checksum, fragment length) disagrees with the first
    /// accepted part: parts of another message were mixed into this one.
    MetadataMismatch,
    /// A fountain-code redundant part (`seqNum` > `seqLen`, BCR-2024-001 MUR). Deliberately
    /// unsupported; the state does not change, so the caller may ignore this and keep scanning.
    FountainUnsupported,
};

/// Result of `Receiver.receive`.
pub const Status = enum {
    /// The part was taken in, but the message is not complete yet.
    accepted,
    /// The part was taken in and verified the whole message (`result` / `payload` are valid).
    complete,
    /// An identical copy of a part that was already taken in. The state does not change.
    duplicate,
};

/// Bytes of bitmap needed to track `seq_len` parts.
pub fn bitsLength(seq_len: u32) usize {
    // 64-bit arithmetic: `seq_len + 7` overflows a 32-bit usize for a hostile part count.
    return @intCast((@as(u64, seq_len) + 7) / 8);
}

/// Largest part count a bitmap of `bits_len` bytes can track.
pub fn maxParts(bits_len: usize) usize {
    return bits_len * 8;
}

/// Collects the parts of one multi-part UR message (or one single-part UR) and hands back the
/// payload once the whole-message checksum has been verified.
///
/// Typical camera loop:
///
///     var receiver = try Receiver.init(ur.type_crypto_psbt, &message, &bits, &part_buf);
///     while (camera.nextFrame()) |text| {
///         const status = receiver.receive(text) catch |err| { show(err); continue; };
///         if (status == .complete) break;
///     }
///     const psbt_bytes = try receiver.payload();
///
/// The first accepted part fixes message length, part count, checksum and fragment length; every
/// later part must agree with them (`MetadataMismatch` otherwise). Completion means all indices
/// 1..seqLen are present **and** the message's CRC-32 matches, so a caller that sees `.complete`
/// has a fully verified message.
pub const Receiver = struct {
    /// The UR type this receiver accepts (`ur.type_crypto_psbt`, `ur.type_bytes`, ...).
    /// The caller must keep it alive.
    expected_type: []const u8,
    /// Destination for the assembled message (tagless CBOR; for a PSBT, a CBOR byte string).
    /// Its length is the payload ceiling.
    message: []u8,
    /// Bitmap of accepted part indices. `bitsLength(seq_len)` bytes are used, so this buffer is
    /// the part-count bound.
    bits: []u8,
    /// Work area for decoding one part (`bytewords` -> part CBOR). Must hold
    /// `ur.maxPartCborLength(fragment_len)` for a multi-part message, and a whole message for a
    /// single-part one (in practice both are bounded by the largest QR code the camera can read).
    part_buf: []u8,

    /// Number of parts the message is split into (0 until the first part is accepted).
    seq_len: u32 = 0,
    /// Total message length in bytes (padding excluded).
    message_len: usize = 0,
    /// Bytes in one fragment (the last part is zero-padded).
    fragment_len: usize = 0,
    /// CRC-32 of the whole message, from the part CBOR.
    checksum: u32 = 0,
    /// Number of distinct parts accepted.
    received_count: usize = 0,
    /// Whether the whole message has been verified. Only `acceptFragment` sets this.
    complete: bool = false,

    /// `expected_type` is the UR type this transfer must have. All buffers belong to the caller
    /// and must outlive the receiver (the receiver never allocates and never copies them).
    pub fn init(expected_type: []const u8, message: []u8, bits: []u8, part_buf: []u8) Error!Receiver {
        if (!ur.isValidType(expected_type)) return error.InvalidEncoding;
        return .{
            .expected_type = expected_type,
            .message = message,
            .bits = bits,
            .part_buf = part_buf,
        };
    }

    /// Forgets every accepted part so a new transfer can start. The buffers and the expected type
    /// stay; the caller must call this before scanning a new QR sequence.
    pub fn reset(self: *Receiver) void {
        self.seq_len = 0;
        self.message_len = 0;
        self.fragment_len = 0;
        self.checksum = 0;
        self.received_count = 0;
        self.complete = false;
        if (self.bits.len > 0) @memset(self.bits, 0);
    }

    /// Whether every part is present **and** the whole-message checksum has been verified.
    pub fn isComplete(self: *const Receiver) bool {
        return self.complete;
    }

    /// Number of parts the message needs (0 until the first part is accepted).
    pub fn expectedPartCount(self: *const Receiver) usize {
        return self.seq_len;
    }

    /// Number of distinct parts accepted so far.
    pub fn receivedPartCount(self: *const Receiver) usize {
        return self.received_count;
    }

    /// The assembled UR message (tagless CBOR). `error.Incomplete` until the receiver is complete.
    pub fn result(self: *const Receiver) ReceiveError![]const u8 {
        if (!self.complete) return error.Incomplete;
        return self.message[0..self.message_len];
    }

    /// The payload inside the message: the contents of its CBOR byte string (`ur:crypto-psbt` and
    /// `ur:bytes` carry their payload that way). The slice points into `message` - no copy.
    pub fn payload(self: *const Receiver) ReceiveError![]const u8 {
        const message = try self.result();
        var reader = cbor.Reader.init(message);
        const bytes = try reader.readBytes();
        // Exactly one byte string and nothing after it: if the message were a different CBOR shape,
        // this is not the payload the caller is expecting.
        try reader.finish();
        return bytes;
    }

    /// Takes in one scanned UR string.
    ///
    /// Parts may arrive in any order. On error the accepted state is left unchanged, **except**
    /// when the error comes from verifying a message that just became complete
    /// (`error.ChecksumMismatch`, or `error.InvalidEncoding` for a message that is not well-formed
    /// CBOR): there the whole assembly is dropped, because the checksum cannot say which part was
    /// wrong, and keeping it would make a re-scan of the correct part look like a duplicate.
    /// `error.Incomplete` from `result`/`payload` is the only error that is not about this call.
    pub fn receive(self: *Receiver, text: []const u8) ReceiveError!Status {
        const uri = try ur.parse(text);

        // The type is fixed by the caller, not by whatever arrives first: a QR code of another
        // transfer (or of another UR type entirely) must never be merged into this message.
        if (!ur.typeEql(self.expected_type, uri.ur_type)) return error.WrongType;

        if (uri.seq == null) return self.receiveSingle(uri.body);
        return self.receivePart(text);
    }

    /// Takes in a multipart part (`ur:<type>/<seqNum>-<seqLen>/<bytewords>`).
    fn receivePart(self: *Receiver, text: []const u8) ReceiveError!Status {
        const part = (try ur.decodePartUr(self.part_buf, text)).part;

        // A zero-length fragment carries nothing and would make the part arithmetic divide by zero.
        if (part.data.len == 0) return error.InvalidEncoding;

        if (self.seq_len == 0) {
            // Checked before the metadata is committed: an unusable fountain part must not fix the
            // message length / part count for the parts that follow.
            if (part.seq_num > part.seq_len) return error.FountainUnsupported;
            return self.startPart(part);
        }

        // Every part must agree with the first one. A part of another message (or of another split
        // of the same message) is rejected instead of being merged.
        if (part.seq_len != self.seq_len or
            part.message_len != self.message_len or
            part.checksum != self.checksum or
            part.data.len != self.fragment_len)
        {
            return error.MetadataMismatch;
        }
        // Fountain / MUR redundant parts: no recovery is implemented, so they are an error rather
        // than a silent no-op (the caller can ignore it and carry on).
        if (part.seq_num > self.seq_len) return error.FountainUnsupported;

        return self.acceptFragment(part);
    }

    /// Fixes the message metadata from the first accepted part and stores its fragment.
    fn startPart(self: *Receiver, part: ur.Part) ReceiveError!Status {
        // BCR-2024-001: the fragment length is `ceil(messageLen / seqLen)` and the last part is
        // zero-padded to it. These ceilings are computed without `(a + b - 1) / b`, which overflows
        // for hostile metadata (`messageLen` may be up to 2^64-1 in the CBOR).
        const fragment_len = ceilDiv(part.message_len, part.seq_len);
        if (fragment_len != part.data.len) return error.InvalidEncoding;
        if (ceilDiv(part.message_len, part.data.len) != part.seq_len) return error.InvalidEncoding;

        // The caller's buffers are the only bound: nothing is ever allocated, so a sender cannot
        // make the receiver hold more than the caller prepared.
        if (part.message_len > self.message.len) return error.TooLarge;
        if (@as(u64, part.seq_len) > @as(u64, self.bits.len) * 8) return error.TooLarge;

        self.seq_len = part.seq_len;
        self.message_len = part.message_len;
        self.fragment_len = part.data.len;
        self.checksum = part.checksum;
        @memset(self.bits[0..bitsLength(part.seq_len)], 0);
        return self.acceptFragment(part);
    }

    /// Stores one fragment (or refuses an identical/different repeat). `part.seq_num` must be
    /// within 1..seqLen and the metadata must already match.
    fn acceptFragment(self: *Receiver, part: ur.Part) ReceiveError!Status {
        const index: usize = part.seq_num - 1;
        const offset = index * self.fragment_len;
        // The last part is zero-padded, so only the bytes inside `messageLen` are part of the
        // message (the checksum covers the message with the padding excluded).
        const take = @min(part.data.len, self.message_len - offset);

        if (self.isReceived(index)) {
            // The same index twice is harmless only when it carries exactly the same bytes. Two
            // different fragments for one index would assemble a message no sender ever encoded,
            // so it is rejected rather than resolved by silently keeping the first one.
            if (!std.mem.eql(u8, self.message[offset..][0..take], part.data[0..take])) {
                return error.ConflictingDuplicate;
            }
            return .duplicate;
        }

        @memcpy(self.message[offset..][0..take], part.data[0..take]);
        self.setReceived(index);
        self.received_count += 1;

        if (self.received_count < self.seq_len) return .accepted;

        // Every sequential part is present. `messageLen` was respected while copying; the CRC-32
        // is what proves the sender encoded exactly this message (the bytewords checksum only
        // protects each part on its own, and is recomputed by anyone who alters a part).
        const assembled = self.message[0..self.message_len];
        if (bytewords.crc32(assembled) != self.checksum) {
            // The checksum cannot tell which part is at fault, so nothing is kept: a partial
            // assembly that kept all parts marked as received could never be completed afterwards.
            self.reset();
            return error.ChecksumMismatch;
        }
        if (!cbor.isWellFormed(assembled, true)) {
            // The checksum matched, so the sender really did send this byte string - it is just not
            // the dCBOR the UR layer requires. Unusable, and nothing partial may survive either.
            self.reset();
            return error.InvalidEncoding;
        }

        self.complete = true;
        return .complete;
    }

    /// Takes in a single-part UR (`ur:<type>/<bytewords>`), which carries the whole message.
    fn receiveSingle(self: *Receiver, body: []const u8) ReceiveError!Status {
        if (self.seq_len != 0) {
            // A single-part code in the middle of a multipart stream is a different transfer.
            if (!self.complete) return error.MetadataMismatch;
            // A repeat of a completed single message is harmless (the sender loops the same QR
            // code); a different one is not silently accepted as "already have it".
            const message = bytewords.decode(self.part_buf, body, .minimal) catch |err| switch (err) {
                error.BufferTooSmall => return error.TooLarge,
                else => |other| return other,
            };
            if (!std.mem.eql(u8, self.message[0..self.message_len], message)) {
                return error.ConflictingDuplicate;
            }
            return .duplicate;
        }

        // BCR-2020-005: the single-part form has no part CBOR and therefore no message-level
        // checksum - `bytewords` carries its own CRC-32 over the message, and `bytewords.decode`
        // only returns after verifying it. Decoding straight into the destination avoids a second
        // full-size buffer.
        const message = bytewords.decode(self.message, body, .minimal) catch |err| switch (err) {
            error.BufferTooSmall => return error.TooLarge,
            else => |other| return other,
        };
        // The whole message must be dCBOR, as everywhere else in the UR layer.
        if (!cbor.isWellFormed(message, true)) return error.InvalidEncoding;

        self.seq_len = 1;
        self.message_len = message.len;
        self.fragment_len = message.len;
        self.checksum = bytewords.crc32(message);
        self.complete = true;
        return .complete;
    }

    fn isReceived(self: *const Receiver, index: usize) bool {
        return (self.bits[index / 8] >> @intCast(index % 8)) & 1 != 0;
    }

    fn setReceived(self: *Receiver, index: usize) void {
        self.bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }
};

/// Ceiling division that cannot overflow (unlike `(a + b - 1) / b`). `b` must not be 0.
fn ceilDiv(a: usize, b: usize) usize {
    return a / b + @intFromBool(a % b != 0);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// The Bitcoin Core PSBT vector (same file the Core interop test uses).
const core_psbt_vector = @embedFile("../../tests/vectors/core_psbt.json");

/// Wraps `payload` the way `ur:crypto-psbt` / `ur:bytes` carry it: one CBOR byte string.
fn wrapByteString(out: []u8, payload: []const u8) Error![]u8 {
    var header: [cbor.max_header_len]u8 = undefined;
    const head = try cbor.writeBytesHeader(&header, payload.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..][0..payload.len], payload);
    return out[0 .. head.len + payload.len];
}

/// Deterministic Fisher-Yates shuffle (fixed seed on the caller's side: a failure is reproducible).
fn shuffle(random: std.Random, items: []usize) void {
    var i: usize = items.len;
    while (i > 1) {
        i -= 1;
        const j = random.uintLessThan(usize, i + 1);
        std.mem.swap(usize, &items[i], &items[j]);
    }
}

/// Whether the arrival order happens to be the identity order.
fn isIdentityOrder(items: []const usize) bool {
    for (items, 0..) |index, k| {
        if (index != k) return false;
    }
    return true;
}

/// Builds a camera-like arrival order for `seq_len` parts:
///   - the very first frame is repeated immediately (the camera read the same QR code twice),
///   - then two independently shuffled passes over every part (a fixed-rate sender, which sends
///     the sequence again from part 1 when not all parts were seen - see `ur.Encoder.restart`).
/// Every part is therefore present at least twice, and no part is in sequence order.
fn makeFeed(allocator: std.mem.Allocator, seq_len: usize, seed: u64) ![]usize {
    const feed = try allocator.alloc(usize, 2 * seq_len + 2);
    for (0..seq_len) |k| {
        feed[2 + k] = k;
        feed[2 + seq_len + k] = k;
    }

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    shuffle(random, feed[2..][0..seq_len]);
    shuffle(random, feed[2 + seq_len ..]);

    // The first scanned frame was seen twice in a row.
    feed[0] = feed[2];
    feed[1] = feed[2];
    return feed;
}

/// Rebuilds a part UR with one byte of its fragment flipped, recomputing the part's own bytewords
/// checksum: the part stays well-formed, so only the whole-message CRC-32 can notice.
fn flipPartByte(
    out: []u8,
    cbor_buf: []u8,
    decode_buf: []u8,
    data_buf: []u8,
    text: []const u8,
    byte_index: usize,
) Error![]u8 {
    const decoded = try ur.decodePartUr(decode_buf, text);
    const data = decoded.part.data;
    @memcpy(data_buf[0..data.len], data);
    data_buf[byte_index] ^= 0xff;

    const part = ur.Part{
        .seq_num = decoded.part.seq_num,
        .seq_len = decoded.part.seq_len,
        .message_len = decoded.part.message_len,
        .checksum = decoded.part.checksum,
        .data = data_buf[0..data.len],
    };
    const part_cbor = try ur.encodePart(cbor_buf, part);
    return ur.encodePartUr(out, decoded.ur_type, part.seq_num, part.seq_len, part_cbor, .lower);
}

/// Test-side receiver plus its buffers. `Receiver` holds slices into these arrays, so a fixture
/// must live at a stable address and must not be copied after `start`.
const Fixture = struct {
    message: [512]u8 = undefined,
    bits: [2]u8 = undefined, // 16 parts at most
    part_buf: [256]u8 = undefined,
    receiver: Receiver = undefined,

    fn start(self: *Fixture, expected_type: []const u8) Error!void {
        self.receiver = try Receiver.init(expected_type, &self.message, &self.bits, &self.part_buf);
    }
};

test "round-trips the Bitcoin Core PSBT as a shuffled multi-part UR with duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A real PSBT: Bitcoin Core (regtest) createpsbt + utxoupdatepsbt, tests/vectors/core_psbt.json.
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, core_psbt_vector, .{});
    const psbt_b64 = parsed.value.object.get("unsigned_psbt_base64").?.string;
    const psbt = try allocator.alloc(u8, try std.base64.standard.Decoder.calcSizeForSlice(psbt_b64));
    try std.base64.standard.Decoder.decode(psbt, psbt_b64);
    try testing.expect(psbt.len > 0);

    // `ur:crypto-psbt` carries the PSBT as a CBOR byte string; 30 bytes per QR forces a real
    // multi-part transfer instead of the single-part form.
    var message_buf: [256]u8 = undefined;
    const message = try wrapByteString(&message_buf, psbt);

    var scratch: [128]u8 = undefined;
    var encoder = try ur.Encoder.init(ur.type_crypto_psbt, message, 30, ur.default_min_fragment_len, &scratch);
    try testing.expect(encoder.seq_len > 1); // genuinely multi-part

    const part_count = encoder.seq_len;
    const part_texts = try allocator.alloc([]u8, part_count);
    const part_bufs = try allocator.alloc([256]u8, part_count);
    var out: [256]u8 = undefined;
    for (0..part_count) |i| {
        // Every other part uppercase: QR alphanumeric mode uses uppercase and UR is case agnostic.
        const text = (try encoder.next(&out, if (i % 2 == 0) .upper else .lower)).?;
        @memcpy(part_bufs[i][0..text.len], text);
        part_texts[i] = part_bufs[i][0..text.len];
    }
    try testing.expect(std.mem.indexOfScalar(u8, part_texts[0], '-') != null); // the `<num>-<len>` form

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);

    const feed = try makeFeed(allocator, part_count, 0x5eed_2024);
    // The shuffle is real: neither pass is in part order (with a fixed seed this is deterministic).
    try testing.expect(!isIdentityOrder(feed[2..][0..part_count]));
    try testing.expect(!isIdentityOrder(feed[2 + part_count ..]));

    var duplicates: usize = 0;
    var duplicates_before_complete: usize = 0;
    var completions: usize = 0;
    for (feed) |index| {
        const status = try fx.receiver.receive(part_texts[index]);
        switch (status) {
            .accepted => {},
            .duplicate => {
                duplicates += 1;
                if (!fx.receiver.isComplete()) duplicates_before_complete += 1;
            },
            .complete => completions += 1,
        }
    }

    // Two shuffled passes over every part plus the repeated first frame: every repeat was ignored.
    try testing.expectEqual(part_count + 2, duplicates);
    // At least one repeat arrived while parts were still missing: the byte comparison path ran.
    try testing.expect(duplicates_before_complete >= 1);
    try testing.expectEqual(@as(usize, 1), completions);
    try testing.expect(fx.receiver.isComplete());
    try testing.expectEqual(part_count, fx.receiver.expectedPartCount());
    try testing.expectEqual(part_count, fx.receiver.receivedPartCount());

    // The assembled CBOR message and the payload inside it are byte-for-byte what was encoded.
    try testing.expectEqualSlices(u8, message, try fx.receiver.result());
    try testing.expectEqualSlices(u8, psbt, try fx.receiver.payload());
    try testing.expectEqual(psbt.len, (try fx.receiver.payload()).len);
}

test "missing parts stay Incomplete and never expose a partial payload" {
    // A small PSBT-like payload encoded into five parts.
    var payload: [120]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast((i * 37 + 11) % 256);

    var message_buf: [256]u8 = undefined;
    const message = try wrapByteString(&message_buf, &payload);
    var scratch: [128]u8 = undefined;
    var encoder = try ur.Encoder.init(ur.type_crypto_psbt, message, 30, ur.default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 5), encoder.seq_len);

    var parts: [5][256]u8 = undefined;
    var lengths: [5]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const text = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..text.len], text);
        lengths[i] = text.len;
    }

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);

    // Parts 1, 2, 3, 5 - part 4 was never scanned (a missed frame).
    for ([_]usize{ 0, 1, 2, 4 }) |index| {
        try testing.expectEqual(Status.accepted, try fx.receiver.receive(parts[index][0..lengths[index]]));
    }
    try testing.expect(!fx.receiver.isComplete());
    try testing.expectEqual(@as(usize, 4), fx.receiver.receivedPartCount());
    try testing.expectEqual(@as(usize, 5), fx.receiver.expectedPartCount());
    // Asking for the message or the payload fails loudly instead of returning partial data.
    try testing.expectError(error.Incomplete, fx.receiver.result());
    try testing.expectError(error.Incomplete, fx.receiver.payload());

    // The missed frame completes the transfer.
    try testing.expectEqual(Status.complete, try fx.receiver.receive(parts[3][0..lengths[3]]));
    try testing.expectEqualSlices(u8, &payload, try fx.receiver.payload());
}

test "a corrupted part fails the whole-message checksum and drops the assembly" {
    var payload: [120]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast((i * 53 + 5) % 256);

    var message_buf: [256]u8 = undefined;
    const message = try wrapByteString(&message_buf, &payload);
    var scratch: [128]u8 = undefined;
    var encoder = try ur.Encoder.init(ur.type_crypto_psbt, message, 30, ur.default_min_fragment_len, &scratch);

    var parts: [5][256]u8 = undefined;
    var lengths: [5]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const text = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..text.len], text);
        lengths[i] = text.len;
    }

    // Corrupt part 3's fragment and recompute that part's own bytewords checksum, so nothing but
    // the whole-message CRC-32 can detect it (this is the realistic "QR misread into valid words"
    // and the attacker-controlled case alike).
    var corrupted: [256]u8 = undefined;
    var cbor_buf: [128]u8 = undefined;
    var decode_buf: [128]u8 = undefined;
    var data_buf: [64]u8 = undefined;
    const corrupted_text = try flipPartByte(
        &corrupted,
        &cbor_buf,
        &decode_buf,
        &data_buf,
        parts[2][0..lengths[2]],
        3,
    );

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);

    // Feed every part in order, with the corrupted third part in place.
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(parts[0][0..lengths[0]]));
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(parts[1][0..lengths[1]]));
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(corrupted_text));
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(parts[3][0..lengths[3]]));
    // The last part completes the set, so this is where the checksum is verified.
    try testing.expectError(error.ChecksumMismatch, fx.receiver.receive(parts[4][0..lengths[4]]));

    // Nothing partial survives: no completion, no payload, and no part left marked as received.
    try testing.expect(!fx.receiver.isComplete());
    try testing.expectError(error.Incomplete, fx.receiver.result());
    try testing.expectError(error.Incomplete, fx.receiver.payload());
    try testing.expectEqual(@as(usize, 0), fx.receiver.receivedPartCount());
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());

    // Consequently a clean re-scan of the same transfer succeeds (a receiver that kept the
    // corrupt assembly would report the corrected part as a duplicate and stall forever).
    for (&parts, 0..) |*slot, i| {
        _ = try fx.receiver.receive(slot[0..lengths[i]]);
    }
    try testing.expectEqualSlices(u8, &payload, try fx.receiver.payload());
}

test "a duplicate index with different bytes is rejected" {
    var payload: [120]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast((i * 29 + 3) % 256);

    var message_buf: [256]u8 = undefined;
    const message = try wrapByteString(&message_buf, &payload);
    var scratch: [128]u8 = undefined;
    var encoder = try ur.Encoder.init(ur.type_crypto_psbt, message, 30, ur.default_min_fragment_len, &scratch);

    var parts: [5][256]u8 = undefined;
    var lengths: [5]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const text = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..text.len], text);
        lengths[i] = text.len;
    }

    // A second, different fragment for index 1 (one payload byte flipped, part checksum recomputed).
    var conflicted: [256]u8 = undefined;
    var cbor_buf: [128]u8 = undefined;
    var decode_buf: [128]u8 = undefined;
    var data_buf: [64]u8 = undefined;
    const conflicted_text = try flipPartByte(
        &conflicted,
        &cbor_buf,
        &decode_buf,
        &data_buf,
        parts[0][0..lengths[0]],
        1,
    );

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);

    try testing.expectEqual(Status.accepted, try fx.receiver.receive(parts[0][0..lengths[0]]));
    // An identical repeat is ignored...
    try testing.expectEqual(Status.duplicate, try fx.receiver.receive(parts[0][0..lengths[0]]));
    // ...but the same index with different bytes must not be resolved by keeping one of them.
    try testing.expectError(error.ConflictingDuplicate, fx.receiver.receive(conflicted_text));
    try testing.expectEqual(@as(usize, 1), fx.receiver.receivedPartCount());

    // The conflict changed nothing: the genuine parts still assemble the genuine payload.
    for (parts[1..], 1..) |*slot, i| {
        _ = try fx.receiver.receive(slot[0..lengths[i]]);
    }
    try testing.expectEqualSlices(u8, &payload, try fx.receiver.payload());
}

test "a part of a different UR type is rejected" {
    // A `ur:bytes` transfer with the same shape as the expected `crypto-psbt` one.
    var payload: [100]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @intCast(i);
    var message_buf: [256]u8 = undefined;
    const message = try wrapByteString(&message_buf, &payload);

    var scratch: [128]u8 = undefined;
    var bytes_encoder = try ur.Encoder.init(ur.type_bytes, message, 30, ur.default_min_fragment_len, &scratch);
    var out: [256]u8 = undefined;
    var other_buf: [256]u8 = undefined;
    const other_part = (try bytes_encoder.next(&out, .lower)).?;
    @memcpy(other_buf[0..other_part.len], other_part);

    // The same message as the expected `crypto-psbt` type, to prove the rejection is about the
    // type name and not about the string shape.
    var psbt_scratch: [128]u8 = undefined;
    var psbt_encoder = try ur.Encoder.init(
        ur.type_crypto_psbt,
        message,
        30,
        ur.default_min_fragment_len,
        &psbt_scratch,
    );
    var psbt_out: [256]u8 = undefined;
    const psbt_part = (try psbt_encoder.next(&psbt_out, .lower)).?;

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);

    // The wrong type cannot start a message, and cannot be merged into one either.
    try testing.expectError(error.WrongType, fx.receiver.receive(other_buf[0..other_part.len]));
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());
    try testing.expectEqual(@as(usize, 0), fx.receiver.receivedPartCount());

    // A single-part UR of another type is rejected the same way.
    var single_buf: [256]u8 = undefined;
    const single = try ur.encodeSingleByteString(&single_buf, ur.type_bytes, &payload, .lower);
    try testing.expectError(error.WrongType, fx.receiver.receive(single));

    // A `crypto-psbt` part is accepted: the rejection was about the type.
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(psbt_part));
}

test "matches the bc-ur reference multipart vector" {
    // The 9 sequential parts of `ur:bytes` from bc-ur test/test.cpp test_ur_encoder, i.e. the
    // reference vector already used by ur.zig's tests (not a home-grown one).
    var expected_buf: [259]u8 = undefined;
    const expected = ur.makeUrMessage(&expected_buf);
    try testing.expectEqual(@as(usize, 9), ur.expected_parts.len);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const feed = try makeFeed(allocator, ur.expected_parts.len, 0xbc_9);

    var fx: Fixture = .{};
    try fx.start(ur.type_bytes);

    for (feed) |index| {
        _ = try fx.receiver.receive(ur.expected_parts[index]);
    }
    try testing.expect(fx.receiver.isComplete());
    try testing.expectEqual(@as(usize, 9), fx.receiver.receivedPartCount());
    try testing.expectEqualSlices(u8, expected, try fx.receiver.result());
    // The message is a CBOR byte string, so the payload is its 256 bytes.
    try testing.expectEqualSlices(u8, &ur.message_256, try fx.receiver.payload());
}

test "round-trips a single-part UR, in both forms the spec allows" {
    const payload = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };

    // (1) `ur:crypto-psbt/<bytewords>`: what `ur.Encoder` emits when the message fits one fragment.
    var single_buf: [256]u8 = undefined;
    const single = try ur.encodeSingleByteString(&single_buf, ur.type_crypto_psbt, &payload, .lower);

    var fx: Fixture = .{};
    try fx.start(ur.type_crypto_psbt);
    try testing.expectEqual(Status.complete, try fx.receiver.receive(single));
    try testing.expect(fx.receiver.isComplete());
    try testing.expectEqual(@as(usize, 1), fx.receiver.expectedPartCount());
    try testing.expectEqualSlices(u8, &payload, try fx.receiver.payload());

    // A repeat of the same single QR code is a harmless duplicate; a different one is not.
    try testing.expectEqual(Status.duplicate, try fx.receiver.receive(single));
    var other_buf: [256]u8 = undefined;
    const other = try ur.encodeSingleByteString(&other_buf, ur.type_crypto_psbt, "a different payload", .lower);
    try testing.expectError(error.ConflictingDuplicate, fx.receiver.receive(other));
    try testing.expectEqualSlices(u8, &payload, try fx.receiver.payload());

    // (2) The explicit `1-1` multipart form of the same message (a sender may choose it).
    var message_buf: [64]u8 = undefined;
    const message = try wrapByteString(&message_buf, &payload);
    var part_cbor_buf: [64]u8 = undefined;
    const part_cbor = try ur.encodePart(&part_cbor_buf, .{
        .seq_num = 1,
        .seq_len = 1,
        .message_len = message.len,
        .checksum = bytewords.crc32(message),
        .data = message,
    });
    var part_ur_buf: [256]u8 = undefined;
    const part_ur = try ur.encodePartUr(&part_ur_buf, ur.type_crypto_psbt, 1, 1, part_cbor, .upper);

    var fx2: Fixture = .{};
    try fx2.start(ur.type_crypto_psbt);
    try testing.expectEqual(Status.complete, try fx2.receiver.receive(part_ur));
    try testing.expectEqualSlices(u8, &payload, try fx2.receiver.payload());
}

test "accepts the largest payload the firmware supports (64 KB)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The payload ceiling used by the card path (`app/device.zig` problemForFileSize, 64 KB).
    const payload = try allocator.alloc(u8, max_payload_len);
    for (payload, 0..) |*byte, i| byte.* = @intCast((i * 131 + 7) % 256);

    const message_buf = try allocator.alloc(u8, payload.len + cbor.max_header_len);
    const message = try wrapByteString(message_buf, payload);

    // 1000-byte fragments: a QR-sized split, ~66 parts.
    const fragment_len = 1000;
    const scratch = try allocator.alloc(u8, ur.maxPartCborLength(fragment_len));
    var encoder = try ur.Encoder.init(
        ur.type_crypto_psbt,
        message,
        fragment_len,
        ur.default_min_fragment_len,
        scratch,
    );
    try testing.expect(encoder.seq_len > 60);

    const part_count = encoder.seq_len;
    const out = try allocator.alloc(u8, ur.Encoder.maxPartLength(ur.type_crypto_psbt.len, encoder.fragment_len));
    const part_texts = try allocator.alloc([]u8, part_count);
    for (0..part_count) |i| {
        const text = (try encoder.next(out, .lower)).?;
        part_texts[i] = try allocator.dupe(u8, text);
    }

    // The receiver is sized by the caller; nothing here is allocated by the receiver itself.
    const assembled = try allocator.alloc(u8, message.len);
    const bits = try allocator.alloc(u8, bitsLength(encoder.seq_len));
    const part_buf = try allocator.alloc(u8, ur.maxPartCborLength(encoder.fragment_len));
    var receiver = try Receiver.init(ur.type_crypto_psbt, assembled, bits, part_buf);

    const feed = try makeFeed(allocator, part_count, 0x40_40);
    for (feed) |index| {
        _ = try receiver.receive(part_texts[index]);
    }

    try testing.expect(receiver.isComplete());
    try testing.expectEqual(part_count, receiver.receivedPartCount());
    try testing.expectEqualSlices(u8, message, try receiver.result());
    try testing.expectEqualSlices(u8, payload, try receiver.payload());
}

test "the bitmap is the part-count bound (TooLarge, nothing allocated)" {
    var message_buf: [259]u8 = undefined;
    const message = ur.makeUrMessage(&message_buf);

    // This message splits into exactly 9 parts of 29 bytes.
    var scratch: [128]u8 = undefined;
    var encoder = try ur.Encoder.init(ur.type_bytes, message, 30, ur.default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 9), encoder.seq_len);

    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const text = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..text.len], text);
        lengths[i] = text.len;
    }

    // One byte of bitmap tracks 8 parts, so a 9-part transfer is refused before any state is kept.
    var small_bits: [1]u8 = undefined;
    var small_message: [512]u8 = undefined;
    var small_part_buf: [128]u8 = undefined;
    var small = try Receiver.init(ur.type_bytes, &small_message, &small_bits, &small_part_buf);
    try testing.expectError(error.TooLarge, small.receive(parts[0][0..lengths[0]]));
    try testing.expectEqual(@as(usize, 0), small.expectedPartCount());
    try testing.expectEqual(@as(usize, 0), small.receivedPartCount());
    try testing.expectError(error.Incomplete, small.result());

    // Two bytes track 16 parts: the same transfer goes through, so the bound is exactly the bitmap.
    var message_area: [512]u8 = undefined;
    var bits_two: [2]u8 = undefined;
    var part_scratch: [128]u8 = undefined;
    var receiver = try Receiver.init(ur.type_bytes, &message_area, &bits_two, &part_scratch);
    for (&parts, 0..) |*slot, i| {
        _ = try receiver.receive(slot[0..lengths[i]]);
    }
    try testing.expectEqualSlices(u8, message, try receiver.result());
    try testing.expectEqual(@as(usize, 9), receiver.receivedPartCount());
}

test "hostile part metadata is rejected, not merged and not a crash" {
    var fx: Fixture = .{};
    try fx.start(ur.type_bytes);

    // `messageLen` near 2^64 with seqLen 2: `(m + s - 1) / s` (the ceiling used by ur.Decoder)
    // overflows here. The receiver computes ceilings without overflow, so this is a plain error.
    var cbor_buf: [64]u8 = undefined;
    var ur_buf: [256]u8 = undefined;
    const huge_message = try ur.encodePart(&cbor_buf, .{
        .seq_num = 1,
        .seq_len = 2,
        .message_len = std.math.maxInt(usize),
        .checksum = 0,
        .data = "ab",
    });
    const huge_message_ur = try ur.encodePartUr(&ur_buf, ur.type_bytes, 1, 2, huge_message, .lower);
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive(huge_message_ur));
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());

    // Consistent but absurd: 100'000'000 one-byte parts of a 100'000'000-byte message. It is
    // consistent as CBOR (fragment length 1) and must hit the message/bitmap bounds, not allocate.
    const huge_count = try ur.encodePart(&cbor_buf, .{
        .seq_num = 1,
        .seq_len = 100_000_000,
        .message_len = 100_000_000,
        .checksum = 0,
        .data = "a",
    });
    const huge_count_ur = try ur.encodePartUr(&ur_buf, ur.type_bytes, 1, 100_000_000, huge_count, .lower);
    try testing.expectError(error.TooLarge, fx.receiver.receive(huge_count_ur));
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());

    // A part count that fits the message but not the caller's bitmap is TooLarge as well.
    const many_parts = try ur.encodePart(&cbor_buf, .{
        .seq_num = 1,
        .seq_len = 100,
        .message_len = 100,
        .checksum = 0,
        .data = "a",
    });
    const many_parts_ur = try ur.encodePartUr(&ur_buf, ur.type_bytes, 1, 100, many_parts, .lower);
    try testing.expectError(error.TooLarge, fx.receiver.receive(many_parts_ur));

    // A zero-length fragment is malformed (and would divide by zero downstream).
    const empty = try ur.encodePart(&cbor_buf, .{
        .seq_num = 1,
        .seq_len = 1,
        .message_len = 1,
        .checksum = 0,
        .data = "",
    });
    const empty_ur = try ur.encodePartUr(&ur_buf, ur.type_bytes, 1, 1, empty, .lower);
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive(empty_ur));
}

test "malformed input, fountain parts and inconsistent parts are distinct errors" {
    // A 28-byte message split two ways: the same bytes, the same checksum, a different seqLen.
    var message: [28]u8 = undefined;
    message[0] = 0x58;
    message[1] = 0x1a;
    for (message[2..], 0..) |*byte, i| byte.* = @intCast((i * 17 + 3) % 256);

    var scratch_a: [128]u8 = undefined;
    var encoder_a = try ur.Encoder.init(ur.type_bytes, &message, 14, ur.default_min_fragment_len, &scratch_a);
    try testing.expectEqual(@as(u32, 2), encoder_a.seq_len);
    var scratch_b: [128]u8 = undefined;
    // min_fragment_len 9 so that the same 28-byte message really splits into 3 parts of 10 bytes.
    var encoder_b = try ur.Encoder.init(ur.type_bytes, &message, 10, 9, &scratch_b);
    try testing.expectEqual(@as(u32, 3), encoder_b.seq_len);

    var out_a: [256]u8 = undefined;
    var out_b: [256]u8 = undefined;
    var a1_buf: [256]u8 = undefined;
    var b2_buf: [256]u8 = undefined;
    const a1_text = (try encoder_a.next(&out_a, .lower)).?;
    @memcpy(a1_buf[0..a1_text.len], a1_text);
    _ = (try encoder_a.next(&out_a, .lower)).?;
    _ = (try encoder_b.next(&out_b, .lower)).?;
    const b2_text = (try encoder_b.next(&out_b, .lower)).?;
    @memcpy(b2_buf[0..b2_text.len], b2_text);

    var fx: Fixture = .{};
    try fx.start(ur.type_bytes);

    // Malformed strings never start or extend a message.
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive(""));
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive("http://example.com/1-9/abcd"));
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive("ur:bytes/1-9/"));
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive("ur:bytes/0-9/lpaoascf"));
    try testing.expectError(error.InvalidEncoding, fx.receiver.receive("ur:bad_type!/1-9/lpao"));
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());

    // A fountain / MUR redundant part (seqNum > seqLen) is a distinct, ignorable error: the
    // metadata is not committed, so the genuine sequence can still be received afterwards.
    var fountain_buf: [256]u8 = undefined;
    var fountain_cbor: [128]u8 = undefined;
    const fountain = try ur.encodePart(&fountain_cbor, .{
        .seq_num = 4,
        .seq_len = 3,
        .message_len = 28,
        .checksum = 0,
        .data = "abcdefghij",
    });
    const fountain_ur = try ur.encodePartUr(&fountain_buf, ur.type_bytes, 4, 3, fountain, .lower);
    try testing.expectError(error.FountainUnsupported, fx.receiver.receive(fountain_ur));
    try testing.expectEqual(@as(usize, 0), fx.receiver.expectedPartCount());
    try testing.expectEqual(@as(usize, 0), fx.receiver.receivedPartCount());

    // The first part fixes the split; a part of the other split of the *same* message (same
    // messageLen, same checksum, different seqLen) is not merged into it.
    try testing.expectEqual(Status.accepted, try fx.receiver.receive(a1_buf[0..a1_text.len]));
    try testing.expectError(error.MetadataMismatch, fx.receiver.receive(b2_buf[0..b2_text.len]));
    try testing.expectEqual(@as(usize, 1), fx.receiver.receivedPartCount());

    // A single-part UR in the middle of a multipart stream is a different transfer.
    var single_buf: [128]u8 = undefined;
    const single = try ur.encodeSingleByteString(&single_buf, ur.type_bytes, "hello", .lower);
    try testing.expectError(error.MetadataMismatch, fx.receiver.receive(single));

    // A fountain part of the transfer in progress (real metadata, seqNum = seqLen + 1): the
    // metadata matches, so this is the fountain case and not "a part of another message".
    var decode_buf: [256]u8 = undefined;
    var fountain2_cbor: [128]u8 = undefined;
    var fountain2_buf: [256]u8 = undefined;
    const started = try ur.decodePartUr(&decode_buf, a1_buf[0..a1_text.len]);
    const fountain2 = try ur.encodePart(&fountain2_cbor, .{
        .seq_num = started.part.seq_len + 1,
        .seq_len = started.part.seq_len,
        .message_len = started.part.message_len,
        .checksum = started.part.checksum,
        .data = started.part.data,
    });
    const fountain2_ur = try ur.encodePartUr(
        &fountain2_buf,
        ur.type_bytes,
        started.part.seq_len + 1,
        started.part.seq_len,
        fountain2,
        .lower,
    );
    try testing.expectError(error.FountainUnsupported, fx.receiver.receive(fountain2_ur));
    try testing.expectEqual(@as(usize, 1), fx.receiver.receivedPartCount());
    try testing.expect(!fx.receiver.isComplete());
}

test "result is the raw message; payload requires a CBOR byte string" {
    // bc-ur-rust src/ur.rs test_ur: the message is CBOR [1, 2, 3], not a byte string.
    var fx: Fixture = .{};
    try fx.start("test");
    try testing.expectEqual(Status.complete, try fx.receiver.receive("UR:TEST/LSADAOAXJYGONESW"));
    try testing.expectEqualSlices(u8, &[_]u8{ 0x83, 0x01, 0x02, 0x03 }, try fx.receiver.result());
    try testing.expectError(error.InvalidEncoding, fx.receiver.payload());

    // An invalid expected type is refused when the receiver is created.
    var message: [16]u8 = undefined;
    var bits: [1]u8 = undefined;
    var part_buf: [16]u8 = undefined;
    try testing.expectError(error.InvalidEncoding, Receiver.init("bad type", &message, &bits, &part_buf));
    try testing.expectError(error.InvalidEncoding, Receiver.init("", &message, &bits, &part_buf));
}

test "bitmap sizing helpers" {
    try testing.expectEqual(@as(usize, 1), bitsLength(1));
    try testing.expectEqual(@as(usize, 1), bitsLength(8));
    try testing.expectEqual(@as(usize, 2), bitsLength(9));
    try testing.expectEqual(@as(usize, 8192), bitsLength(65536));
    try testing.expectEqual(@as(usize, 8), maxParts(1));
    try testing.expectEqual(@as(usize, 128), maxParts(16));

    // The bitmap a full 64 KB message needs at the finest allowed split (1-byte fragments).
    try testing.expect(bitsLength(@intCast(max_payload_len)) <= 8192);

    // Ceiling division never overflows, even at the edge of usize.
    const max = std.math.maxInt(usize);
    try testing.expectEqual(max, ceilDiv(max, 1));
    try testing.expectEqual(max / 2 + 1, ceilDiv(max, 2));
    try testing.expectEqual(@as(usize, 2), ceilDiv(3, 2));
    try testing.expectEqual(@as(usize, 1), ceilDiv(1, 2));
}
