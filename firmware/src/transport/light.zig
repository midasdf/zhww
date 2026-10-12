//! Light-link framing and Manchester coding: the digital half of the light input channel.
//!
//! A host screen flickers, an LM393 module turns the light into a level the firmware samples, and
//! the samples become one payload:
//!
//!     light levels -> Manchester symbols -> frame bytes -> CRC-32 -> payload -> ur_receive
//!
//! **This module is everything above the analog front end and below the UR layer.** `modulate` and
//! `demodulate` are the *clean-channel* pair: `demodulate` needs an exact `samples_per_symbol` and
//! reads the middle sample of each symbol period. ADC sampling, ambient removal, an adaptive
//! threshold with hysteresis and bit-clock recovery are the next layer's job
//! (docs/09-light-audio-input.md §6) and are deliberately absent - which is what makes this module
//! testable on a PC with synthetic samples and no hardware.
//!
//! **Wire format** (docs/09-light-audio-input.md §3):
//!
//!     preamble 0xAA 0xAA | version (1 byte) | length (2 bytes, LE) | payload | CRC-32 (4 bytes, LE)
//!     \________________ header (5 bytes) ________________/                   \__ trailer (4) __/
//!
//! - `version` is 1; any other value is `error.UnsupportedVersion`, never guessed at.
//! - `length` counts payload bytes, so a frame is `length + 9` bytes long.
//! - The CRC-32 is the standard IEEE one (reflected, init/final 0xFFFFFFFF - `bytewords.crc32`,
//!   the same function the UR layer uses) over the **body**: version | length | payload. The
//!   preamble is outside it on purpose: it is a light-layer sync pattern, not data, and a receiver
//!   that acquires the clock part-way through it has lost nothing the CRC covers.
//! - The payload is the UR string itself (a `ur:bytes/...` or `ur:crypto-psbt/...` part, or a
//!   single-part UR). Those bytes are what `ur_receive.Receiver` takes, so the light channel and
//!   the camera channel share the whole UR layer.
//!
//! **Manchester convention: IEEE 802.3.** A sender has to match this exactly, because the two
//! conventions in the wild are each other's inverse:
//!
//!     bit 1 = dark, then light   (a rising edge in the middle of the bit period)
//!     bit 0 = light, then dark   (a falling edge in the middle of the bit period)
//!
//! One bit is two symbols, most significant bit first within a byte. A symbol is a light level:
//! `light_level` (0xFF) is a lit screen, `dark_level` (0x00) is dark. Every bit has a transition in
//! its middle, so a receiver can recover the clock from the data and runs of 0x00 or 0xFF stay
//! unambiguous. The opposite convention (G. E. Thomas: rising edge = 0) decodes as every bit
//! inverted and is caught only by the CRC - do not mix them up.
//!
//! **Supported payload limit: 65535 bytes**, what the 2-byte length field can say. Note this is one
//! byte short of `ur_receive.max_payload_len` (64 KB = 65536): a 64 KB payload cannot be framed as
//! it stands. That needs a format change (a wider length field, or segmentation), not a bigger
//! buffer.
//!
//! **No allocation; the caller's buffers are the bounds.** Every function is a pure function over
//! caller-owned slices. `frame_buf` caps the length field (a frame declaring more is
//! `error.TooLarge`), `payload_buf` caps the payload. `Receiver` is a fixed-size struct of two
//! slices and a counter - this module owns no memory at all.
//!
//! **API**
//!     encodeFrame / decodeFrame      payload <-> frame bytes (CRC-32 verified)
//!     encodeSymbols / decodeSymbols  bytes <-> Manchester symbols
//!     modulate / demodulate          frame bytes <-> light-level samples
//!     Receiver                       one frame out of a sample stream, buffers included
//!
//! **Deliberate limits (the next layer's job)**
//! - Bit-clock recovery: an exact `samples_per_symbol` is required and the middle of each symbol
//!   period is read. Jitter, a rate mismatch, a phase offset and inverted polarity are not handled.
//! - Analog effects: noise, ambient level, gain drift and hysteresis. Levels are split at a fixed
//!   mid-scale `slice_level` here.
//! - Resynchronisation: after `error.BadPreamble` or `error.InvalidSymbol` the stream position is
//!   unknown (`Receiver.samples_used` stays 0) and the analog layer has to find the next preamble in
//!   the sample domain. There is no preamble search, no auto-baud and no inter-frame gap handling.
//! - Fountain codes and multiple senders: one frame carries one payload from one sender; redundancy
//!   and part mixing are `ur_receive`'s business (MUR is unsupported there too).
//! - No encryption or authentication: light is line-of-sight, and the user still confirms on the
//!   device screen what is about to be signed - the CRC only catches corruption.
//!
//! Reference: docs/09-light-audio-input.md §3 (frame format), §6 (sampling and decoding plan)
//! SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const bytewords = @import("bytewords.zig");

// ---------------------------------------------------------------- the frame

/// Frame format version this module writes, and the only one it accepts.
pub const version: u8 = 1;

/// The frame preamble: two 0xAA bytes.
///
/// Its job is clock acquisition by the analog layer. 0xAA is alternating bits, so in Manchester it
/// also breaks the symbol pairing immediately when a receiver is one symbol (half a bit) out of
/// phase, instead of silently decoding every bit inverted.
pub const preamble = [2]u8{ 0xaa, 0xaa };

/// Bytes of preamble.
pub const preamble_len: usize = preamble.len;
/// Bytes of the little-endian length field.
pub const length_len: usize = 2;
/// Bytes of the little-endian CRC-32 trailer.
pub const crc_len: usize = 4;
/// Bytes before the payload: preamble | version | length.
pub const header_len: usize = preamble_len + 1 + length_len;
/// Largest payload the 2-byte length field can describe.
pub const max_payload_len: usize = 0xffff;
/// Whole frame carrying `max_payload_len` bytes.
pub const max_frame_len: usize = header_len + max_payload_len + crc_len;

/// Errors the sending side can return.
///
/// `error.BufferTooSmall` - the caller's output buffer cannot hold what was asked for.
/// `error.TooLarge` - the payload does not fit the 2-byte length field.
pub const EncodeError = Error || error{
    /// The payload does not fit the 2-byte length field (or a frame length was asked for that
    /// could not).
    TooLarge,
};

/// Errors the receiving side can return.
///
/// A superset of the shared `Error` (which already carries `error.Truncated`,
/// `error.ChecksumMismatch`, `error.BufferTooSmall`) with the states a light receiver has to tell
/// apart. Every rejection is an error: a frame is never decoded "best effort".
pub const DecodeError = Error || error{
    /// The first two bytes are not 0xAA 0xAA: these are not frame bytes, or the caller started in
    /// the middle of a stream.
    BadPreamble,
    /// The version byte is not `version`: a sender whose format this firmware does not know.
    UnsupportedVersion,
    /// The length field needs more payload bytes than the caller's buffer holds. The frame is well
    /// formed; the receiver was simply not sized for it.
    TooLarge,
    /// Two consecutive symbols are equal, so they are not a Manchester pair. Either the samples are
    /// misaligned (a clock problem) or they were never a Manchester stream.
    InvalidSymbol,
};

/// Total bytes of a frame carrying `payload_len` bytes.
pub fn frameLength(payload_len: usize) EncodeError!usize {
    if (payload_len > max_payload_len) return error.TooLarge;
    return header_len + payload_len + crc_len;
}

/// CRC-32 over the frame body (version | length | payload).
fn bodyCrc(body: []const u8) u32 {
    return bytewords.crc32(body);
}

/// Encodes one frame into `out` and returns it (preamble through CRC).
///
/// `error.BufferTooSmall` if `out` cannot hold `frameLength(payload.len)` bytes, `error.TooLarge`
/// if the payload exceeds `max_payload_len`.
pub fn encodeFrame(payload: []const u8, out: []u8) EncodeError![]u8 {
    const total = try frameLength(payload.len);
    if (out.len < total) return error.BufferTooSmall;

    out[0] = preamble[0];
    out[1] = preamble[1];
    out[2] = version;
    std.mem.writeInt(u16, out[3..5], @intCast(payload.len), .little);
    @memcpy(out[header_len..][0..payload.len], payload);
    const body = out[2 .. header_len + payload.len]; // version | length | payload
    std.mem.writeInt(u32, out[header_len + payload.len ..][0..crc_len], bodyCrc(body), .little);
    return out[0..total];
}

/// Decodes the frame at the front of `frame` into `payload` and returns the payload slice.
///
/// `frame` may be a longer stream slice: only the frame the header describes is read, and trailing
/// bytes are left to the next call (so back-to-back frames are walked with `frameLength`).
///
/// Verification order - and it matters, because **nothing is written to `payload` until the whole
/// frame has passed**:
///   1. at least a header and a trailer  -> `error.Truncated`
///   2. preamble                         -> `error.BadPreamble`
///   3. version                          -> `error.UnsupportedVersion`
///   4. length field vs `payload.len`    -> `error.TooLarge`
///   5. the whole frame is present       -> `error.Truncated`
///   6. CRC-32                           -> `error.ChecksumMismatch`
/// Only then is the payload copied out, so a rejected frame can never hand back data - not even the
/// part of it that was already on the wire. The decoder keeps no state, so the next good frame is
/// accepted immediately, whatever the previous call returned.
pub fn decodeFrame(frame: []const u8, payload: []u8) DecodeError![]const u8 {
    if (frame.len < header_len + crc_len) return error.Truncated;
    if (frame[0] != preamble[0] or frame[1] != preamble[1]) return error.BadPreamble;
    if (frame[2] != version) return error.UnsupportedVersion;

    const declared = std.mem.readInt(u16, frame[3..5], .little);
    if (declared > payload.len) return error.TooLarge;

    const total = header_len + @as(usize, declared) + crc_len;
    if (frame.len < total) return error.Truncated;

    const crc_at = header_len + @as(usize, declared);
    if (std.mem.readInt(u32, frame[crc_at..][0..crc_len], .little) != bodyCrc(frame[2..crc_at])) {
        return error.ChecksumMismatch;
    }

    // Everything checked: this is where the caller's buffer is first touched.
    @memcpy(payload[0..declared], frame[header_len..][0..declared]);
    return payload[0..declared];
}

// ---------------------------------------------------------------- Manchester

/// One Manchester half-bit ("chip"): a light level, before analog effects.
pub const Symbol = enum(u1) { dark = 0, light = 1 };

/// Symbols per bit: two, one for each half of the bit period.
pub const symbols_per_bit = 2;

/// Symbols `byte_len` bytes occupy. `byte_len` is a frame length here (bounded by `max_frame_len`).
pub fn symbolLength(byte_len: usize) usize {
    return byte_len * 8 * symbols_per_bit;
}

/// The two symbols of one bit, in transmission order - the convention, in one place.
///
/// IEEE 802.3: bit 1 is a rising edge in the middle of the bit period (dark, then light), bit 0 a
/// falling one (light, then dark).
pub fn symbolsForBit(bit: u1) [symbols_per_bit]Symbol {
    return if (bit == 1) .{ .dark, .light } else .{ .light, .dark };
}

/// The bit a Manchester pair encodes.
///
/// `error.InvalidSymbol` when the two symbols are equal: that pair cannot come from
/// `symbolsForBit`, so the samples are misaligned or were never Manchester.
pub fn bitForSymbols(first: Symbol, second: Symbol) DecodeError!u1 {
    if (first == second) return error.InvalidSymbol;
    return if (first == .dark) 1 else 0;
}

/// Encodes `bytes` as Manchester symbols, MSB first, and returns them.
///
/// `error.BufferTooSmall` unless `out` holds `symbolLength(bytes.len)` symbols.
pub fn encodeSymbols(bytes: []const u8, out: []Symbol) EncodeError![]Symbol {
    const needed = symbolLength(bytes.len);
    if (out.len < needed) return error.BufferTooSmall;

    var at: usize = 0;
    for (bytes) |byte| {
        for (0..8) |k| {
            out[at..][0..symbols_per_bit].* = symbolsForBit(bitAt(byte, k));
            at += symbols_per_bit;
        }
    }
    return out[0..needed];
}

/// Decodes Manchester symbols back to bytes.
///
/// `error.Truncated` when the symbol count is not a whole number of bytes, `error.InvalidSymbol`
/// for a pair that is not a pair, `error.BufferTooSmall` when `out` is too small.
pub fn decodeSymbols(symbols: []const Symbol, out: []u8) DecodeError![]u8 {
    const per_byte = symbolLength(1);
    if (symbols.len % per_byte != 0) return error.Truncated;
    const byte_len = symbols.len / per_byte;
    if (out.len < byte_len) return error.BufferTooSmall;

    for (out[0..byte_len], 0..) |*byte, i| {
        byte.* = try decodeByte(symbols[i * per_byte ..][0..per_byte]);
    }
    return out[0..byte_len];
}

/// Bit `index` of a byte, 0 = most significant (the wire order).
fn bitAt(byte: u8, index: usize) u1 {
    return @intCast((byte >> @intCast(7 - index)) & 1);
}

/// One byte from sixteen consecutive symbols (eight pairs).
fn decodeByte(symbols: []const Symbol) DecodeError!u8 {
    var byte: u8 = 0;
    for (0..8) |k| {
        const pair = symbols[k * symbols_per_bit ..][0..symbols_per_bit];
        byte = (byte << 1) | try bitForSymbols(pair[0], pair[1]);
    }
    return byte;
}

// ---------------------------------------------------------------- light levels

/// Level a lit symbol is transmitted as.
pub const light_level: u8 = 0xff;
/// Level a dark symbol is transmitted as.
pub const dark_level: u8 = 0x00;
/// Level at or above which a sample counts as light.
///
/// The fixed mid-scale split stands in for the next layer's ambient removal and hysteresis: it is
/// exact for clean input, and a real ADC's mid-scale drift is that layer's problem, not this one's.
pub const slice_level: u8 = 0x80;

/// The transmitted level of a symbol.
pub fn levelFor(symbol: Symbol) u8 {
    return if (symbol == .light) light_level else dark_level;
}

/// The symbol a sampled level means, by the fixed `slice_level` split.
pub fn symbolFor(level: u8) Symbol {
    return if (level >= slice_level) .light else .dark;
}

/// Samples a frame of `frame_len` bytes occupies at `samples_per_symbol`.
pub fn sampleLength(frame_len: usize, samples_per_symbol: usize) usize {
    return symbolLength(frame_len) * samples_per_symbol;
}

/// Modulates frame bytes into light-level samples: each Manchester symbol becomes
/// `samples_per_symbol` identical samples, so the two directions stay exactly symmetric.
///
/// `error.InvalidEncoding` for a nominal rate of 0 (a caller bug, not a channel condition),
/// `error.BufferTooSmall` when `out` cannot hold `sampleLength(frame.len, samples_per_symbol)`.
pub fn modulate(frame: []const u8, out: []u8, samples_per_symbol: usize) EncodeError![]u8 {
    if (samples_per_symbol == 0) return error.InvalidEncoding;
    const needed = sampleLength(frame.len, samples_per_symbol);
    if (out.len < needed) return error.BufferTooSmall;

    var at: usize = 0;
    for (frame) |byte| {
        for (0..8) |k| {
            for (symbolsForBit(bitAt(byte, k))) |symbol| {
                @memset(out[at..][0..samples_per_symbol], levelFor(symbol));
                at += samples_per_symbol;
            }
        }
    }
    return out[0..needed];
}

/// One demodulated frame and how much of the sample stream it used.
pub const Demodulated = struct {
    /// Frame bytes (preamble through CRC), a slice of the caller's `out` buffer. Not yet verified:
    /// `decodeFrame` is what turns these into a payload.
    frame: []const u8,
    /// Samples consumed. The caller advances its stream by exactly this much to reach the next
    /// frame, which is what makes back-to-back frames walkable.
    samples_used: usize,
};

/// Demodulates one frame from the front of `samples`.
///
/// The frame's own header says where it ends, so the header is decoded first (from a small local
/// buffer) and the rest of the stream is only touched once the length is known. `error.BadPreamble`
/// when the samples do not start at a frame, `error.InvalidSymbol` when they are not a Manchester
/// stream, `error.Truncated` when the stream ends inside the frame (or before the header, or when
/// `samples_per_symbol` cannot even fit one symbol in `samples`), `error.TooLarge` when the frame
/// does not fit the caller's `out` buffer. This function does not check the version or the CRC:
/// `decodeFrame` does, on the bytes that come back.
pub fn demodulate(samples: []const u8, out: []u8, samples_per_symbol: usize) DecodeError!Demodulated {
    if (samples_per_symbol == 0) return error.InvalidEncoding;
    // Also keeps the symbol arithmetic below in range for a nonsense nominal rate.
    if (samples_per_symbol > samples.len) return error.Truncated;

    if (samples.len < sampleLength(header_len, samples_per_symbol)) return error.Truncated;
    var header: [header_len]u8 = undefined;
    for (&header, 0..) |*byte, i| {
        byte.* = try decodeByteAt(samples, i, samples_per_symbol);
    }

    if (header[0] != preamble[0] or header[1] != preamble[1]) return error.BadPreamble;
    const declared = std.mem.readInt(u16, header[3..5], .little);

    const total = header_len + @as(usize, declared) + crc_len;
    if (total > out.len) return error.TooLarge;
    const needed = sampleLength(total, samples_per_symbol);
    if (samples.len < needed) return error.Truncated;

    for (out[0..total], 0..) |*byte, i| {
        byte.* = try decodeByteAt(samples, i, samples_per_symbol);
    }
    return .{ .frame = out[0..total], .samples_used = needed };
}

/// One byte from the sample stream at byte `byte_index`, by Manchester pairs.
///
/// @pre `samples.len >= sampleLength(byte_index + 1, samples_per_symbol)`.
fn decodeByteAt(samples: []const u8, byte_index: usize, samples_per_symbol: usize) DecodeError!u8 {
    var byte: u8 = 0;
    for (0..8) |k| {
        const pair_at = byte_index * 8 + k;
        const first = symbolAt(samples, pair_at * symbols_per_bit, samples_per_symbol);
        const second = symbolAt(samples, pair_at * symbols_per_bit + 1, samples_per_symbol);
        byte = (byte << 1) | try bitForSymbols(first, second);
    }
    return byte;
}

/// The symbol at `symbol_index`, read from the middle of its period (the point furthest from both
/// edges). Clock recovery proper is the analog layer's: here the nominal rate has to be exact.
fn symbolAt(samples: []const u8, symbol_index: usize, samples_per_symbol: usize) Symbol {
    return symbolFor(samples[symbol_index * samples_per_symbol + samples_per_symbol / 2]);
}

// ---------------------------------------------------------------- receiver

/// One-frame receiver over a caller-owned sample stream.
///
/// The whole of its state is the two slices the caller passed plus `samples_used`; it allocates
/// nothing and it can be reused for the next frame whatever the previous call returned.
pub const Receiver = struct {
    /// Destination for the demodulated frame (preamble through CRC). Its length is the bound on the
    /// accepted frame length, i.e. on the payload.
    frame_buf: []u8,
    /// Destination for the verified payload. Its length is the bound on the payload.
    payload_buf: []u8,
    /// Samples the last `receive` consumed. Set to the frame's sample count once the header has
    /// been read and found plausible - so it is valid after `error.ChecksumMismatch`,
    /// `error.UnsupportedVersion` and `error.TooLarge`, where the caller can advance past the bad
    /// frame and try the next one. It stays 0 when the stream position is unknown
    /// (`error.BadPreamble`, `error.InvalidSymbol`, `error.Truncated`), which tells the caller to
    /// resynchronise rather than to advance. 0 before the first call.
    samples_used: usize = 0,

    /// The receiver never copies the buffers: they must outlive it.
    pub fn init(frame_buf: []u8, payload_buf: []u8) Receiver {
        return .{ .frame_buf = frame_buf, .payload_buf = payload_buf };
    }

    /// Demodulates and verifies the frame at the front of `samples`, returning its payload.
    ///
    /// On error, `payload_buf` is untouched - a rejected frame never yields a payload. `frame_buf`
    /// may hold the rejected frame's bytes (the demodulated symbols), which are not a payload and
    /// are never handed out as one.
    pub fn receive(self: *Receiver, samples: []const u8, samples_per_symbol: usize) DecodeError![]const u8 {
        const got = demodulate(samples, self.frame_buf, samples_per_symbol) catch |err| {
            self.samples_used = 0;
            return err;
        };
        self.samples_used = got.samples_used;
        return decodeFrame(got.frame, self.payload_buf);
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ur = @import("ur.zig");
const ur_receive = @import("ur_receive.zig");

/// A copy of `frame` with one byte flipped - the tests' corruption primitive.
fn flipByte(frame: []const u8, into: []u8, index: usize) []u8 {
    @memcpy(into[0..frame.len], frame);
    into[index] ^= 0xff;
    return into[0..frame.len];
}

test "a real UR string survives frame, Manchester and samples byte for byte" {
    // The bc-ur reference message (the same 259-byte CBOR message ur.zig's tests use), as a real
    // single-part UR string: exactly what the light channel is supposed to deliver.
    var message_buf: [259]u8 = undefined;
    const message = ur.makeUrMessage(&message_buf);
    var text_buf: [1024]u8 = undefined;
    const text = try ur.encodeSingleByteString(&text_buf, ur.type_bytes, message, .lower);
    try testing.expect(std.mem.startsWith(u8, text, "ur:bytes/"));

    var frame_buf: [1024]u8 = undefined;
    const frame = try encodeFrame(text, &frame_buf);
    try testing.expectEqual(header_len + text.len + crc_len, frame.len);
    try testing.expectEqualSlices(u8, &preamble, frame[0..preamble_len]);
    try testing.expectEqual(version, frame[2]);
    try testing.expectEqual(@as(u8, @intCast(text.len & 0xff)), frame[3]);
    try testing.expectEqual(@as(u8, @intCast(text.len >> 8)), frame[4]);

    const samples_per_symbol = 4;
    const samples = try testing.allocator.alloc(u8, sampleLength(frame.len, samples_per_symbol));
    defer testing.allocator.free(samples);
    const modulated = try modulate(frame, samples, samples_per_symbol);
    try testing.expectEqual(samples.len, modulated.len);

    const rx_frame = try testing.allocator.alloc(u8, frame.len);
    defer testing.allocator.free(rx_frame);
    var payload_buf: [1024]u8 = undefined;

    const got = try demodulate(modulated, rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, frame, got.frame); // the sample path is exactly symmetric
    try testing.expectEqual(modulated.len, got.samples_used);

    const delivered = try decodeFrame(got.frame, &payload_buf);
    try testing.expectEqualSlices(u8, text, delivered);
    // What came out is still a UR string the UR layer accepts: the next step of the pipeline.
    try testing.expect(ur.typeEql((try ur.parse(delivered)).ur_type, ur.type_bytes));
}

test "a zero-length payload is a valid nine-byte frame" {
    var frame_buf: [16]u8 = undefined;
    const frame = try encodeFrame(&.{}, &frame_buf);
    try testing.expectEqual(@as(usize, 9), frame.len);
    try testing.expectEqualSlices(u8, &preamble, frame[0..preamble_len]);
    try testing.expectEqual(version, frame[2]);
    try testing.expectEqual(@as(u8, 0), frame[3]);
    try testing.expectEqual(@as(u8, 0), frame[4]);

    // An empty payload is legal, not an error, all the way through the sample path.
    const samples_per_symbol = 2;
    var samples: [sampleLength(9, 2)]u8 = undefined;
    const modulated = try modulate(frame, &samples, samples_per_symbol);
    var rx_frame: [16]u8 = undefined;
    var payload_buf: [8]u8 = undefined;
    const got = try demodulate(modulated, &rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, frame, got.frame);
    try testing.expectEqual(@as(usize, 0), (try decodeFrame(got.frame, &payload_buf)).len);
}

test "the wire format is exactly what the spec says (literal bytes)" {
    // What a sender has to build by hand: preamble, version, little-endian length, payload, and a
    // little-endian CRC-32 over `version | length | payload`. The CRC values are the standard ones
    // (cross-checked against `bytewords.crc32` and an independent zlib CRC-32).
    var frame_buf: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &.{
        0xaa, 0xaa, // preamble
        0x01, // version
        0x02, 0x00, // length 2, little endian
        'a', 'b', // payload
        0xb4, 0x4c, 0x11, 0x8e, // CRC-32 0x8e114cb4, little endian
    }, try encodeFrame("ab", &frame_buf));

    // An empty payload: CRC-32 0xfe83b325 of {01, 00, 00}.
    try testing.expectEqualSlices(u8, &.{
        0xaa, 0xaa, 0x01, 0x00, 0x00, 0x25, 0xb3, 0x83, 0xfe,
    }, try encodeFrame(&.{}, &frame_buf));
}

test "the maximum payload round-trips, and one byte more is refused" {
    const allocator = testing.allocator;
    const payload = try allocator.alloc(u8, max_payload_len);
    defer allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @intCast((i * 131 + 7) % 256);

    const frame = try allocator.alloc(u8, max_frame_len);
    defer allocator.free(frame);
    const encoded = try encodeFrame(payload, frame);
    try testing.expectEqual(max_frame_len, encoded.len);

    // The whole sample path at the maximum, at one sample per symbol (65535*16 samples).
    const samples_per_symbol = 1;
    const samples = try allocator.alloc(u8, sampleLength(encoded.len, samples_per_symbol));
    defer allocator.free(samples);
    const modulated = try modulate(encoded, samples, samples_per_symbol);

    const rx_frame = try allocator.alloc(u8, max_frame_len);
    defer allocator.free(rx_frame);
    const rx_payload = try allocator.alloc(u8, max_payload_len);
    defer allocator.free(rx_payload);
    const got = try demodulate(modulated, rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, payload, try decodeFrame(got.frame, rx_payload));

    // One byte more does not fit the 2-byte length field, on either side.
    const too_long = try allocator.alloc(u8, max_payload_len + 1);
    defer allocator.free(too_long);
    try testing.expectError(error.TooLarge, encodeFrame(too_long, frame));
    try testing.expectError(error.TooLarge, frameLength(max_payload_len + 1));
    try testing.expectError(error.BufferTooSmall, encodeFrame(payload, frame[0 .. max_frame_len - 1]));

    // A caller's buffer that cannot hold the declared payload is TooLarge, not a short read.
    try testing.expectError(error.TooLarge, decodeFrame(encoded, rx_payload[0 .. max_payload_len - 1]));
}

test "two frames back to back, at the byte level and in one sample stream" {
    const first = "ur:bytes/1-9/lpadascfadaxcywenbpljkhdcahkadaemejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtdkgslpgh";
    const second = "the second frame";

    var f1_buf: [256]u8 = undefined;
    var f2_buf: [256]u8 = undefined;
    const f1 = try encodeFrame(first, &f1_buf);
    const f2 = try encodeFrame(second, &f2_buf);

    // Byte level: one buffer, walked with `frameLength`, nothing left over.
    var stream: [512]u8 = undefined;
    @memcpy(stream[0..f1.len], f1);
    @memcpy(stream[f1.len..][0..f2.len], f2);
    const stream_len = f1.len + f2.len;

    var payload_buf: [256]u8 = undefined;
    var offset: usize = 0;
    const got1 = try decodeFrame(stream[offset..], &payload_buf);
    try testing.expectEqualSlices(u8, first, got1);
    offset += try frameLength(got1.len);
    const got2 = try decodeFrame(stream[offset..], &payload_buf);
    try testing.expectEqualSlices(u8, second, got2);
    offset += try frameLength(got2.len);
    try testing.expectEqual(stream_len, offset);

    // Sample level: the two frames' samples concatenated as one flickering stream.
    const samples_per_symbol = 3;
    const samples = try testing.allocator.alloc(u8, sampleLength(f1.len, samples_per_symbol) + sampleLength(f2.len, samples_per_symbol));
    defer testing.allocator.free(samples);
    const s1 = try modulate(f1, samples, samples_per_symbol);
    const s2 = try modulate(f2, samples[s1.len..], samples_per_symbol);
    const all = samples[0 .. s1.len + s2.len];
    try testing.expectEqual(all.len, s1.len + s2.len);

    var rx_frame: [256]u8 = undefined;
    var at: usize = 0;
    const r1 = try demodulate(all[at..], &rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, first, try decodeFrame(r1.frame, &payload_buf));
    at += r1.samples_used;
    const r2 = try demodulate(all[at..], &rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, second, try decodeFrame(r2.frame, &payload_buf));
    at += r2.samples_used;
    try testing.expectEqual(all.len, at);
}

test "every rejection is a distinct error and none of them yields a payload" {
    const payload = "hello light";
    var frame_buf: [64]u8 = undefined;
    const good = try encodeFrame(payload, &frame_buf);
    try testing.expectEqual(@as(usize, header_len + payload.len + crc_len), good.len);

    var payload_buf: [64]u8 = undefined;
    @memset(&payload_buf, 0xee);
    const sentinel = payload_buf;

    var work: [64]u8 = undefined;

    // 1. Bad preamble (either byte).
    try testing.expectError(error.BadPreamble, decodeFrame(flipByte(good, &work, 0), &payload_buf));
    try testing.expectError(error.BadPreamble, decodeFrame(flipByte(good, &work, 1), &payload_buf));

    // 2. Unknown version, including one that is merely a future version.
    try testing.expectError(error.UnsupportedVersion, decodeFrame(flipByte(good, &work, 2), &payload_buf));
    @memcpy(work[0..good.len], good);
    work[2] = version + 1;
    try testing.expectError(error.UnsupportedVersion, decodeFrame(work[0..good.len], &payload_buf));

    // 3. Length larger than the caller's buffer: a hostile maximum, and one byte too many.
    @memcpy(work[0..good.len], good);
    work[3] = 0xff;
    work[4] = 0xff;
    try testing.expectError(error.TooLarge, decodeFrame(work[0..good.len], &payload_buf));
    try testing.expectError(error.TooLarge, decodeFrame(good, payload_buf[0 .. payload.len - 1]));

    // 4. Truncated: nothing there, less than a header, less than the declared frame.
    try testing.expectError(error.Truncated, decodeFrame(&.{}, &payload_buf));
    try testing.expectError(error.Truncated, decodeFrame(good[0 .. header_len - 1], &payload_buf));
    try testing.expectError(error.Truncated, decodeFrame(good[0 .. good.len - 1], &payload_buf));
    @memcpy(work[0..good.len], good);
    work[3] = payload.len + 1; // declares one byte that is not there
    work[4] = 0;
    try testing.expectError(error.Truncated, decodeFrame(work[0..good.len], &payload_buf));

    // 5. CRC mismatch: a flipped payload byte, a flipped CRC byte, and a length that was shortened
    //    without recomputing the CRC (the body no longer matches).
    try testing.expectError(error.ChecksumMismatch, decodeFrame(flipByte(good, &work, header_len), &payload_buf));
    try testing.expectError(error.ChecksumMismatch, decodeFrame(flipByte(good, &work, good.len - 1), &payload_buf));
    @memcpy(work[0..good.len], good);
    work[3] = payload.len - 1;
    try testing.expectError(error.ChecksumMismatch, decodeFrame(work[0..good.len], &payload_buf));

    // A rejected frame never yields a payload: not one byte of the caller's buffer was written.
    try testing.expectEqualSlices(u8, &sentinel, &payload_buf);

    // The five rejections are five different errors: the UI can say which one happened.
    const rejections = [_]DecodeError{
        error.BadPreamble,
        error.UnsupportedVersion,
        error.TooLarge,
        error.Truncated,
        error.ChecksumMismatch,
    };
    for (rejections, 0..) |a, i| {
        for (rejections[i + 1 ..]) |b| try testing.expect(a != b);
    }

    // ...and the next good frame is accepted immediately: the decoder keeps no state.
    try testing.expectEqualSlices(u8, payload, try decodeFrame(good, &payload_buf));
}

test "a corrupt frame followed immediately by a good one yields the good payload" {
    const bad_payload = "corrupt me";
    const good_payload = "and this one is fine";

    var bad_buf: [64]u8 = undefined;
    const bad_frame = try encodeFrame(bad_payload, &bad_buf);
    bad_buf[header_len + 2] ^= 0xff; // the frame stays well formed; only the CRC can notice

    var good_buf: [64]u8 = undefined;
    const good_frame = try encodeFrame(good_payload, &good_buf);

    var payload_buf: [64]u8 = undefined;

    // Byte level: both frames in one stream; the caller advances past the rejected one by its
    // length (which the header still states correctly).
    var stream: [128]u8 = undefined;
    @memcpy(stream[0..bad_frame.len], bad_frame);
    @memcpy(stream[bad_frame.len..][0..good_frame.len], good_frame);
    try testing.expectError(error.ChecksumMismatch, decodeFrame(&stream, &payload_buf));
    try testing.expectEqualSlices(
        u8,
        good_payload,
        try decodeFrame(stream[bad_frame.len..], &payload_buf),
    );

    // Sample level: the corrupt frame occupies exactly the samples its header says, so the good
    // frame still starts where the walk expects it.
    const samples_per_symbol = 2;
    var samples: [4 * 1024]u8 = undefined;
    const s1 = try modulate(bad_frame, &samples, samples_per_symbol);
    const s2 = try modulate(good_frame, samples[s1.len..], samples_per_symbol);
    const all = samples[0 .. s1.len + s2.len];

    var rx_frame: [64]u8 = undefined;
    try testing.expectError(
        error.ChecksumMismatch,
        decodeFrame((try demodulate(all, &rx_frame, samples_per_symbol)).frame, &payload_buf),
    );
    const second = try demodulate(all[s1.len..], &rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, good_payload, try decodeFrame(second.frame, &payload_buf));

    // Through `Receiver`: the error still leaves `samples_used` past the rejected frame, because
    // its header was read, so the caller can advance without recomputing anything.
    var receiver = Receiver.init(&rx_frame, &payload_buf);
    try testing.expectError(error.ChecksumMismatch, receiver.receive(all, samples_per_symbol));
    try testing.expectEqual(s1.len, receiver.samples_used);
    const after_bad = receiver.samples_used;
    try testing.expectEqualSlices(
        u8,
        good_payload,
        try receiver.receive(all[after_bad..], samples_per_symbol),
    );
    try testing.expectEqual(s2.len, receiver.samples_used);
}

test "the Manchester convention is stated, and asserted explicitly" {
    // 0xAA = 1 0 1 0 ...: every 1 is dark,light and every 0 is light,dark (IEEE 802.3).
    var symbols: [16]Symbol = undefined;
    try testing.expectEqualSlices(Symbol, &.{
        .dark, .light, .light, .dark, .dark, .light, .light, .dark,
        .dark, .light, .light, .dark, .dark, .light, .light, .dark,
    }, try encodeSymbols(&.{0xaa}, &symbols));

    // The polarity is not a detail: the other convention is the exact inverse, and decoding it
    // gives every bit flipped (only the CRC catches that).
    for (&symbols) |*symbol| symbol.* = if (symbol.* == .light) .dark else .light;
    var inverted: [1]u8 = undefined;
    try testing.expectEqual(@as(u8, 0x55), (try decodeSymbols(&symbols, &inverted))[0]);

    // A symbol is a light level, and the fixed slice point is mid-scale.
    try testing.expectEqual(light_level, levelFor(.light));
    try testing.expectEqual(dark_level, levelFor(.dark));
    try testing.expectEqual(Symbol.light, symbolFor(slice_level));
    try testing.expectEqual(Symbol.dark, symbolFor(slice_level - 1));

    // Every bit has a transition in its middle, for all 256 byte values: the self-clocking
    // property that is the reason to use Manchester at all.
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @intCast(i);
    var all: [symbolLength(256)]Symbol = undefined;
    const encoded = try encodeSymbols(&bytes, &all);
    for (0..encoded.len / symbols_per_bit) |bit| {
        try testing.expect(encoded[bit * symbols_per_bit] != encoded[bit * symbols_per_bit + 1]);
    }

    // ...and encoding is exactly inverted by decoding.
    var decoded: [256]u8 = undefined;
    try testing.expectEqualSlices(u8, &bytes, try decodeSymbols(encoded, &decoded));

    // A pair that is not a pair cannot have come from a Manchester stream. The first pair here is
    // valid, so the check really is per pair; the second case is a stuck channel.
    var not_manchester: [16]Symbol = undefined;
    for (&not_manchester) |*symbol| symbol.* = .light;
    not_manchester[0] = .dark; // (dark, light) is a valid pair, (light, light) is not
    try testing.expectError(error.InvalidSymbol, decodeSymbols(&not_manchester, &decoded));
    var stuck: [16]Symbol = undefined;
    for (&stuck) |*symbol| symbol.* = .dark;
    try testing.expectError(error.InvalidSymbol, decodeSymbols(&stuck, &decoded));
    try testing.expectError(error.InvalidSymbol, bitForSymbols(.light, .light));
    // ...and a stream that stops mid-bit or mid-byte is truncated, not padded.
    try testing.expectError(error.Truncated, decodeSymbols(encoded[0..3], &decoded));
    try testing.expectError(error.Truncated, decodeSymbols(encoded[0..8], &decoded));
}

test "runs of 0x00 and 0xFF stay self-clocked, and a flipped bit is caught by the CRC" {
    var payload: [64]u8 = undefined;
    @memset(payload[0..32], 0x00);
    @memset(payload[32..], 0xff);

    // Without Manchester these are long constant levels: no edges, so no clock to recover. Every
    // Manchester bit has a mid-bit transition, and no level lasts longer than one bit period.
    var symbols: [symbolLength(64)]Symbol = undefined;
    const encoded = try encodeSymbols(&payload, &symbols);
    try testing.expectEqual(symbolLength(payload.len), encoded.len);
    var run: usize = 1;
    for (encoded, 0..) |symbol, i| {
        if (i > 0) run = if (symbol == encoded[i - 1]) run + 1 else 1;
        try testing.expect(run <= symbols_per_bit);
    }

    var frame_buf: [128]u8 = undefined;
    const frame = try encodeFrame(&payload, &frame_buf);
    const samples_per_symbol = 2;
    var samples: [8 * 1024]u8 = undefined;
    const modulated = try modulate(frame, &samples, samples_per_symbol);

    var rx_frame: [128]u8 = undefined;
    var payload_out: [128]u8 = undefined;
    const got = try demodulate(modulated, &rx_frame, samples_per_symbol);
    try testing.expectEqualSlices(u8, frame, got.frame);
    try testing.expectEqualSlices(u8, &payload, try decodeFrame(got.frame, &payload_out));

    // A one-symbol (half-bit) clock offset is not silently decoded as inverted bits: the 0xAA
    // preamble is alternating, so the Manchester pairing breaks immediately.
    try testing.expectError(
        error.InvalidSymbol,
        demodulate(modulated[samples_per_symbol..], &rx_frame, samples_per_symbol),
    );

    // Flipping one bit's pair keeps a *valid* Manchester stream; only the CRC can catch it, and it
    // does - the corrupted payload never comes back.
    const pair = header_len * 8 + 10 * 8 + 3; // a bit inside the payload
    const pair_at = pair * symbols_per_bit * samples_per_symbol;
    for (modulated[pair_at..][0 .. symbols_per_bit * samples_per_symbol]) |*level| {
        level.* = if (level.* >= slice_level) dark_level else light_level;
    }
    const corrupted = try demodulate(modulated, &rx_frame, samples_per_symbol);
    try testing.expect(!std.mem.eql(u8, corrupted.frame, frame)); // the bit really changed
    try testing.expectError(error.ChecksumMismatch, decodeFrame(corrupted.frame, &payload_out));
}

test "the bc-ur reference multipart transfer arrives frame by frame over the light path" {
    var message_buf: [259]u8 = undefined;
    const message = ur.makeUrMessage(&message_buf);
    try testing.expectEqual(@as(usize, 9), ur.expected_parts.len);

    // The UR receiver is the step after this module, already written and tested.
    var message_area: [512]u8 = undefined;
    var bits: [2]u8 = undefined;
    var part_buf: [256]u8 = undefined;
    var ur_receiver = try ur_receive.Receiver.init(ur.type_bytes, &message_area, &bits, &part_buf);

    const samples_per_symbol = 2;
    var frame_buf: [256]u8 = undefined;
    var payload_buf: [256]u8 = undefined;
    var rx_frame: [256]u8 = undefined;

    var completions: usize = 0;
    for (ur.expected_parts) |part| {
        // One part per frame: the sender's screen flashes exactly this, and nothing else.
        var samples: [8 * 1024]u8 = undefined;
        const modulated = try modulate(try encodeFrame(part, &frame_buf), &samples, samples_per_symbol);

        var receiver = Receiver.init(&rx_frame, &payload_buf);
        const delivered = try receiver.receive(modulated, samples_per_symbol);
        try testing.expectEqualSlices(u8, part, delivered);

        switch (try ur_receiver.receive(delivered)) {
            .accepted => {},
            .complete => completions += 1,
            .duplicate => return error.TestUnexpectedResult,
        }
    }

    try testing.expectEqual(@as(usize, 1), completions);
    try testing.expect(ur_receiver.isComplete());
    try testing.expectEqualSlices(u8, message, try ur_receiver.result());
    try testing.expectEqualSlices(u8, &ur.message_256, try ur_receiver.payload());
}

test "sizing helpers and the standard CRC-32 check value" {
    try testing.expectEqual(@as(usize, 2), preamble_len);
    try testing.expectEqual(@as(usize, 5), header_len);
    try testing.expectEqual(@as(usize, 4), crc_len);
    try testing.expectEqual(@as(u8, 1), version);
    try testing.expectEqual(@as(usize, 0xffff), max_payload_len);

    try testing.expectEqual(@as(usize, 9), try frameLength(0));
    try testing.expectEqual(@as(usize, 19), try frameLength(10));
    try testing.expectEqual(max_frame_len, try frameLength(max_payload_len));
    try testing.expectEqual(@as(usize, 65544), max_frame_len);
    try testing.expectError(error.TooLarge, frameLength(max_payload_len + 1));

    try testing.expectEqual(@as(usize, 16), symbolLength(1));
    try testing.expectEqual(@as(usize, 0), symbolLength(0));
    try testing.expectEqual(@as(usize, 16), sampleLength(1, 1));
    try testing.expectEqual(@as(usize, 64), sampleLength(1, 4));

    // The CRC on the wire is the standard IEEE CRC-32: its published check value for "123456789".
    try testing.expectEqual(@as(u32, 0xcbf4_3926), bytewords.crc32("123456789"));
}

test "the sample path is symmetric at every nominal rate" {
    const payload = "rate test";
    var frame_buf: [64]u8 = undefined;
    const frame = try encodeFrame(payload, &frame_buf);

    for ([_]usize{ 1, 2, 3, 8, 16 }) |samples_per_symbol| {
        var samples: [8 * 1024]u8 = undefined;
        const modulated = try modulate(frame, &samples, samples_per_symbol);
        try testing.expectEqual(sampleLength(frame.len, samples_per_symbol), modulated.len);
        var rx_frame: [64]u8 = undefined;
        var payload_buf: [64]u8 = undefined;
        const got = try demodulate(modulated, &rx_frame, samples_per_symbol);
        try testing.expectEqualSlices(u8, frame, got.frame);
        try testing.expectEqualSlices(u8, payload, try decodeFrame(got.frame, &payload_buf));
    }
}

test "hostile arguments are bounded errors, and a stuck channel is not a frame" {
    var frame_buf: [256]u8 = undefined;
    var payload_buf: [256]u8 = undefined;
    var samples: [256]u8 = undefined;

    // A nominal rate of zero is a caller bug, not a channel condition.
    try testing.expectError(error.InvalidEncoding, modulate(&.{ 0xaa, 0xaa }, &samples, 0));
    try testing.expectError(error.InvalidEncoding, demodulate(&samples, &frame_buf, 0));

    // A rate that cannot fit even one symbol period in the buffer is a truncated frame, not a read
    // past the end.
    var receiver = Receiver.init(&frame_buf, &payload_buf);
    try testing.expectError(error.Truncated, receiver.receive(&samples, samples.len + 1));
    try testing.expectEqual(@as(usize, 0), receiver.samples_used);

    // A channel that never changes level cannot be Manchester: the pairs would be equal.
    var stuck: [128]u8 = undefined;
    @memset(&stuck, light_level);
    try testing.expectError(error.InvalidSymbol, demodulate(&stuck, &frame_buf, 1));
    @memset(&stuck, dark_level);
    try testing.expectError(error.InvalidSymbol, demodulate(&stuck, &frame_buf, 1));

    // Valid Manchester that does not start with the preamble is a bad preamble, not a guess.
    const not_a_frame = [9]u8{ 0xab, 0xaa, version, 0x00, 0x00, 0, 0, 0, 0 };
    try testing.expectError(error.BadPreamble, demodulate(try modulate(&not_a_frame, &samples, 1), &frame_buf, 1));

    // The caller's buffers are the bounds, and the error names the bound that was hit.
    var link_frame: [64]u8 = undefined;
    const frame = try encodeFrame("payload", &link_frame);
    var out_buf: [64]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, encodeFrame("payload", out_buf[0 .. frame.len - 1]));
    var symbols: [512]Symbol = undefined;
    try testing.expectError(error.BufferTooSmall, encodeSymbols("payload", symbols[0..111]));
    const two = try encodeSymbols(&.{ 0x01, 0x02 }, &symbols);
    try testing.expectError(error.BufferTooSmall, decodeSymbols(two, out_buf[0..1]));
    try testing.expectError(error.BufferTooSmall, modulate(frame, &out_buf, out_buf.len));
    const too_short = try modulate(frame, &samples, 1);
    try testing.expectError(error.TooLarge, demodulate(too_short, out_buf[0..4], 1));
}
