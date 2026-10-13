//! Light-channel CLI: the whole light link, host-side.
//!
//! `light-encode` reads a PSBT (base64) on stdin and writes the raw 8-bit ADC samples a screen
//! flashing it at an LM393 board would produce; `light-decode` reads such a stream back into the
//! PSBT (base64). Between them they run every layer of the link outside the unit tests, in one
//! pipeline (docs/09-light-audio-input.md):
//!
//!     PSBT (base64) -> ur.Encoder (UR parts) -> light.encodeFrame (+ CRC-32)
//!                   -> light_rx.Channel (screen + sensor + ADC, 8-bit samples)
//!                   -> light_rx.Receiver (DC tracker, hysteresis, clock recovery, CRC)
//!                   -> ur_receive.Receiver (parts -> message -> payload) -> PSBT (base64)
//!
//! The samples are an ordinary byte stream on stdout, so a run can be saved
//! (`zhww light-encode < psbt.txt > recording.bin`) and replayed later against the same decoder -
//! a synthetic stand-in for a real recording until the hardware exists.
//!
//! **The one number both sides must agree on.** The default channel is the documented pairing: a
//! 3 kHz ADC and 30 symbols/s, i.e. exactly `nominal_samples_per_symbol = 3000 / 30 = 100`, the
//! receiver's own default seed (docs/09-light-audio-input.md §6). `--sample-rate` and
//! `--symbol-rate` move both sides together (`Settings.nominalSamplesPerSymbol` is the ratio that
//! `emit` is driven with and `Receiver.init` is seeded with), because seeding the receiver for one
//! rate while the sender used another is the integration mistake that silently costs every frame.
//!
//! **What a pipe cannot carry.** `light-encode --sample-rate 300 --symbol-rate 10 | light-decode`
//! passes samples, not settings: a `light-decode` that is given no rate is seeded with the default
//! 100 samples per symbol, and a recording at 30 then reports "0 accepted, 0 rejected" - the
//! decoder was never told the recording's rate. That is not a limit of the receiver: with the
//! matching seed it locks from 4 samples per symbol up (see the `light_rx` tests, and note that a
//! Qwiic light sensor at ~60 readings/s therefore supports at most 15 symbols/s, not the
//! documented 30). Passing the same `--sample-rate`/`--symbol-rate` to both commands remains the
//! first answer, and the only one a device built for a fixed pairing has. For the CLI, when the
//! caller names no rate at all and the default pairing finds no frame in the stream, `decode` walks
//! a 10% ladder of candidate ratios around the default seed - half a step is 5%, inside the ~±10%
//! the receiver's preamble survives - and keeps the first candidate whose frame passes the CRC. The
//! ladder is bounded (96 candidates, at most one pass over the stream each), and a caller who names
//! *any* rate gets exactly that seed: wrong-seed failure included.
//!
//! **Impairments.** `--noise`, `--flicker`, `--gain` and `--drift` shape the simulated channel
//! exactly as the receiver's own tests do, and `--noise 15 --flicker 20` is inside the limits
//! those tests measure as survivable (sigma ~21.8 of a 55-count half-swing, flicker ~26.7 of a
//! 110-count swing). A clearly excessive level must lose the transfer, never corrupt it: the frame
//! CRC and the UR message checksum are what make that "never" rather than "unlikely".
//!
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const zhww = @import("zhww");

const cbor = zhww.cbor;
const light = zhww.light;
const light_rx = zhww.light_rx;
const ur = zhww.ur;
const ur_receive = zhww.ur_receive;

/// The documented sender/receiver pairing: a 3 kHz ADC and 30 symbols/s (100 samples per symbol).
pub const default_sample_rate_hz: u32 = 3000;
/// The sender symbol rate that goes with `default_sample_rate_hz`.
pub const default_symbol_rate_hz: f32 = 30;

/// Bytes per UR part, the same default as the `ur` command.
pub const default_fragment_len: usize = 40;

/// Smallest and largest samples per symbol the receiver accepts, i.e. `Receiver.init`'s own bounds.
/// The CLI checks them before it seeds the receiver, and the rate fallback in `decode` walks the
/// same closed interval.
pub const min_samples_per_symbol: u16 = 4;
/// See `min_samples_per_symbol`.
pub const max_samples_per_symbol: u16 = 4096;

/// Step of the rate fallback's ladder, in percent: neighbouring candidates are 10% apart, so a real
/// ratio is never more than 5% away from one of them - half of the ~10% seed error the receiver's
/// preamble survives, which leaves the loop's own -11%/+14% pull-in untouched.
const rate_step_percent: u32 = 10;

/// Most candidates the fallback tries, up and down together. The receiver's whole 4..4096 interval
/// is 34 steps down from the default seed of 100 and 38 up, so the bound is slack in practice; it is
/// what stops a stream that decodes at *no* rate (silence, a lamp, pure noise) from costing an
/// unbounded number of passes.
const max_rate_candidates: usize = 96;

/// Frequencies of the simulated mains flicker: 100 Hz (50 Hz mains) and 120 Hz (60 Hz mains) at
/// once, the in-band case the receiver's tests measure as the hard one.
const flicker_hz = [2]f32{ 100, 120 };

/// Phase of the two flicker tones at t = 0, in radians: 0.4 and 2.1, the values the receiver's own
/// combined-impairment test uses. The phase is a property of the room, not of the data, and it is
/// not cosmetic here: at phase 0 both tones start at zero, and that one alignment costs the first
/// frame of a cold receiver at the default 3000/30 pairing with `--flicker 20` (measured: 3/4
/// frames against 4/4 at any other phase), while the receiver's documented flicker margin is
/// untouched. A real lamp is at an arbitrary phase, so this is not a favour to the decoder.
const flicker_phase = [2]f32{ 0.4, 2.1 };

/// Frequency of the simulated ambient drift: far below the DC tracker's corner (a few symbol
/// periods), so the tracker follows it instead of the data.
const drift_hz: f32 = 0.7;

/// Seed of the noise generator. The channel is deterministic, so the same options always produce
/// the same samples and a failure is reproducible.
pub const default_seed: u64 = 0x5eed_1234;

/// Errors this tool raises itself (the layers below add their own).
pub const ToolError = error{
    /// Nothing on stdin.
    EmptyInput,
    /// The input is not base64.
    InvalidBase64,
    /// The sample stream ended before a whole UR transfer had arrived.
    Incomplete,
};

/// What both commands need to know: how finely to split the UR message, and what the simulated
/// channel (encode) and the receiver seed (decode) are.
pub const Settings = struct {
    /// Upper bound on the bytes per UR part (`ur.Encoder` splits evenly, so the last part may be
    /// shorter). This is the `--fragment` option of the `ur` command, not the message length.
    fragment_len: usize = default_fragment_len,
    /// Simulated ADC sample rate, in samples per second.
    sample_rate_hz: u32 = default_sample_rate_hz,
    /// Simulated symbol (Manchester chip) rate, in symbols per second. May be fractional.
    symbol_rate_hz: f32 = default_symbol_rate_hz,
    /// Dead zone of the receiver's Schmitt trigger, in ADC counts.
    hysteresis: u8 = light_rx.default_hysteresis,
    /// Standard deviation of the additive gaussian noise, in ADC counts.
    noise_sigma: f32 = 0,
    /// Amplitude of the 100 Hz + 120 Hz mains flicker, in ADC counts.
    flicker_amplitude: f32 = 0,
    /// Channel gain on the swing only (a negative value inverts the polarity, which the receiver
    /// rejects by design rather than decoding).
    gain: f32 = 1,
    /// Amplitude of the slow ambient drift, in ADC counts.
    drift_amplitude: f32 = 0,
    /// Seed of the noise generator.
    seed: u64 = default_seed,

    /// Samples per symbol the sender uses. Both sides must agree on this one number.
    pub fn samplesPerSymbol(self: Settings) f32 {
        return @as(f32, @floatFromInt(self.sample_rate_hz)) / self.symbol_rate_hz;
    }

    /// The same number rounded to the integer the receiver is seeded with, and bound-checked
    /// against `Receiver.init`'s own limits (`min_samples_per_symbol`..`max_samples_per_symbol`).
    /// Refusing here means a nonsense rate cannot reach a float-to-integer cast, and cannot quietly
    /// seed the receiver with a period the sender never used.
    pub fn nominalSamplesPerSymbol(self: Settings) light_rx.DecodeError!u16 {
        if (self.sample_rate_hz == 0 or !(self.symbol_rate_hz > 0)) return error.InvalidEncoding;
        const ratio = self.samplesPerSymbol();
        if (!(ratio >= @as(f32, @floatFromInt(min_samples_per_symbol))) or
            !(ratio <= @as(f32, @floatFromInt(max_samples_per_symbol)))) return error.InvalidEncoding;
        return @intFromFloat(@round(ratio));
    }

    /// Whether the caller named no rate at all: both options are at the documented default pairing,
    /// which is exactly what `main.zig` fills in when neither `--sample-rate` nor `--symbol-rate`
    /// appears. An explicit `--sample-rate 3000 --symbol-rate 30` is indistinguishable from the
    /// default, and it makes no difference: the rate fallback in `decode` only runs when that
    /// pairing found no frame at all in the stream.
    pub fn defaultRates(self: Settings) bool {
        return self.sample_rate_hz == default_sample_rate_hz and
            self.symbol_rate_hz == default_symbol_rate_hz;
    }

    /// The receiver configuration matching this channel: the same samples-per-symbol the sender is
    /// driven with, so a frame cannot be lost to a seed that disagrees with its own samples.
    pub fn receiverConfig(self: Settings) light_rx.DecodeError!light_rx.Config {
        return .{
            .nominal_samples_per_symbol = try self.nominalSamplesPerSymbol(),
            .hysteresis = self.hysteresis,
        };
    }

    /// The simulated channel, with `seed` for the noise generator (each frame gets its own, see
    /// `encode`). Every other field is a property of the channel, not of the firmware.
    pub fn channel(self: Settings, seed: u64) light_rx.Channel {
        return .{
            .sample_rate_hz = self.sample_rate_hz,
            .symbol_rate_hz = self.symbol_rate_hz,
            .gain = self.gain,
            .noise_sigma = self.noise_sigma,
            .flicker = .{
                .{ .hz = flicker_hz[0], .amplitude = self.flicker_amplitude, .phase = flicker_phase[0] },
                .{ .hz = flicker_hz[1], .amplitude = self.flicker_amplitude, .phase = flicker_phase[1] },
            },
            .drift = .{ .hz = drift_hz, .amplitude = self.drift_amplitude },
            .seed = seed,
        };
    }
};

/// What one `light-encode` run produced.
pub const EncodeStats = struct {
    /// UR parts written (one frame, one channel burst each).
    parts: usize = 0,
    /// Parts the message needs in total (`ur.Encoder.seq_len`).
    parts_expected: usize = 0,
    /// Samples written to the sink.
    samples: usize = 0,
    /// Bytes of PSBT, after base64-decoding the input.
    payload_len: usize = 0,
    /// Fragment length the encoder actually used.
    fragment_len: usize = 0,
};

/// PSBT (base64) -> UR parts -> frames -> raw 8-bit samples on `out`.
///
/// `psbt_base64` is what the other commands take (`sign`, `ur`); surrounding whitespace is
/// ignored. Each part becomes one frame and one burst of samples, with the next part's samples
/// immediately after it - what a sender looping its screen produces, minus the loop.
///
/// `error.EmptyInput` when there is nothing to encode, `error.InvalidBase64` when the input is not
/// base64, and the layers' own errors for a message or split they cannot encode.
pub fn encode(
    allocator: std.mem.Allocator,
    psbt_base64: []const u8,
    settings: Settings,
    out: *std.Io.Writer,
) !EncodeStats {
    const trimmed = std.mem.trim(u8, psbt_base64, " \t\r\n");
    if (trimmed.len == 0) return error.EmptyInput;

    const decoder = std.base64.standard.Decoder;
    const raw_len = decoder.calcSizeForSlice(trimmed) catch return error.InvalidBase64;
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    decoder.decode(raw, trimmed) catch return error.InvalidBase64;

    // `ur:crypto-psbt` carries the PSBT as a CBOR byte string, exactly as the `ur` command sends
    // it: the light frames carry UR strings, so the QR and light paths share the whole UR layer.
    const message = try cbor.writeBytes(try allocator.alloc(u8, cbor.bytesLength(raw.len)), raw);

    // `--fragment` is an upper bound: the encoder picks the even split, and `findFragmentLength`
    // rounds it up by a byte when the message does not divide evenly (`--fragment 10` on a
    // 136-byte message is a split of 11). Do that computation here first so the work buffers match
    // the split the encoder will really use, and hand it the same number as its maximum.
    const fragment_len = try ur.findFragmentLength(message.len, ur.default_min_fragment_len, settings.fragment_len);
    const scratch = try allocator.alloc(u8, ur.maxPartCborLength(fragment_len));
    defer allocator.free(scratch);
    var encoder = try ur.Encoder.init(
        ur.type_crypto_psbt,
        message,
        fragment_len,
        ur.default_min_fragment_len,
        scratch,
    );

    // The longest part the encoder can emit, and the frame and sample buffers that go with it.
    const max_part = ur.Encoder.maxPartLength(ur.type_crypto_psbt.len, encoder.fragment_len);
    const frame_buf = try allocator.alloc(u8, try light.frameLength(max_part));
    defer allocator.free(frame_buf);
    const part_buf = try allocator.alloc(u8, max_part);
    defer allocator.free(part_buf);
    // `emit` needs room for the frame plus the channel's idle tail; `sampleCount` says how much.
    const sample_buf = try allocator.alloc(u8, light_rx.sampleCount(settings.channel(settings.seed), frame_buf.len));
    defer allocator.free(sample_buf);

    var stats = EncodeStats{
        .parts_expected = encoder.seq_len,
        .payload_len = raw.len,
        .fragment_len = encoder.fragment_len,
    };

    while (try encoder.next(part_buf, .lower)) |part| {
        const frame = try light.encodeFrame(part, frame_buf);
        // Each frame gets its own noise realization (one seed per burst). With the same seed on
        // every part, one unlucky noise pattern would be repeated on every frame of the transfer,
        // which is neither what a real channel does nor a fair test of the UR layer's retries.
        const samples = try light_rx.emit(settings.channel(settings.seed +% stats.parts), frame, sample_buf);
        try out.writeAll(samples);
        stats.parts += 1;
        stats.samples += samples.len;
    }
    return stats;
}

/// What one `light-decode` run saw, whether or not it recovered a PSBT.
pub const DecodeStats = struct {
    /// Frames the receiver assembled and verified (CRC included).
    frames_accepted: u32 = 0,
    /// Frames found and thrown away (checksum, version, length, symbol pairing).
    frames_rejected: u32 = 0,
    /// Samples examined, out of `samples_total`.
    samples_consumed: usize = 0,
    /// Samples the stream held.
    samples_total: usize = 0,
    /// Distinct UR parts the UR receiver took in.
    parts_received: usize = 0,
    /// Parts the transfer needs (0 until the first part arrived).
    parts_expected: usize = 0,
    /// UR parts that were rejected (wrong type, conflicting duplicate, bad metadata, ...).
    parts_rejected: usize = 0,
    /// Name of the last rejection, if any: the UI's "why did this not work".
    last_error: ?[]const u8 = null,
    /// Whether the whole UR message passed its checksum.
    complete: bool = false,
};

/// The buffers one pass over a stream needs, in one place: the rate fallback reuses them for every
/// candidate, so a search allocates nothing beyond what a single decode already had.
const DecodeBuffers = struct {
    /// Destination for the assembled frame (`light.max_frame_len`).
    frame: []u8,
    /// Destination for the verified payload (`light.max_payload_len`).
    payload: []u8,
    /// Destination for the UR message the parts assemble into.
    message: []u8,
    /// Destination for the UR fountain decoder's bits.
    bits: []u8,
    /// Scratch for one UR part.
    part: []u8,
};

/// One whole pass over `samples` with one receiver seed: frames -> UR parts -> a complete message.
///
/// `stats` is filled in every case - the counters are what a user needs to see when nothing came
/// out - and the return value is the verified payload, a slice of `buffers.message` that stays valid
/// until the next pass.
///
/// A frame found and rejected, or a channel that goes quiet (`error.NoSignal`), ends the walk: the
/// receiver has already walked the whole remaining chunk, so there is no later frame to find.
fn attempt(
    samples: []const u8,
    config: light_rx.Config,
    buffers: DecodeBuffers,
    stats: *DecodeStats,
) !?[]const u8 {
    stats.* = .{ .samples_total = samples.len };
    var receiver = try light_rx.Receiver.init(buffers.frame, buffers.payload, config);
    var ur_receiver = try ur_receive.Receiver.init(ur.type_crypto_psbt, buffers.message, buffers.bits, buffers.part);

    var at: usize = 0;
    while (at < samples.len) {
        // One chunk of frame walking. The receiver keeps the tracker, the clock and the
        // half-assembled frame across calls, and `samples_used` ends at the last sample of the
        // frame it returned, so a stream of back-to-back frames is walked by re-feeding the rest.
        const part = receiver.receive(samples[at..]) catch |err| {
            if (err != error.NoSignal) stats.last_error = @errorName(err);
            at = samples.len;
            break;
        } orelse {
            // Nothing framed in the rest of the stream: the idle tail, or no signal at all.
            at = samples.len;
            break;
        };
        at += receiver.samples_used;

        // The frame's payload is one UR part; the UR receiver owns the assembly across frames.
        const status = ur_receiver.receive(part) catch |err| {
            stats.parts_rejected += 1;
            stats.last_error = @errorName(err);
            continue;
        };
        if (status == .complete) break;
    }

    stats.frames_accepted = receiver.frames_accepted;
    stats.frames_rejected = receiver.frames_rejected;
    stats.samples_consumed = at;
    stats.parts_received = ur_receiver.receivedPartCount();
    stats.parts_expected = ur_receiver.expectedPartCount();
    stats.complete = ur_receiver.isComplete();
    if (!stats.complete) return null;

    // Verified by `ur_receive`: every part present and the whole-message CRC-32 matches. Only now
    // does anything become a payload.
    return try ur_receiver.payload();
}

/// Candidate `step_index` (1-based) of the rate fallback's ladder: one step up first, one step
/// down, two up, two down, ... so the rates nearest the seed are tried first and the whole
/// `min_samples_per_symbol`..`max_samples_per_symbol` interval is covered. Null once the candidate
/// falls outside that interval.
fn rateCandidate(seed: u16, step_index: usize) ?u16 {
    const steps: f32 = @floatFromInt((step_index + 1) / 2);
    const step: f32 = 1 + @as(f32, @floatFromInt(rate_step_percent)) / 100;
    const factor = std.math.pow(f32, step, steps);
    const seed_f: f32 = @floatFromInt(seed);
    const ratio = if (step_index % 2 == 1) seed_f * factor else seed_f / factor;
    const rounded = @round(ratio);
    if (!(rounded >= @as(f32, @floatFromInt(min_samples_per_symbol))) or
        !(rounded <= @as(f32, @floatFromInt(max_samples_per_symbol)))) return null;
    return @intFromFloat(rounded);
}

/// Raw 8-bit samples -> frames -> UR parts -> the PSBT (base64), allocated.
///
/// `stats` is filled in every case, including the failures, because frames accepted/rejected and
/// samples consumed are exactly what a user needs to see when nothing came out.
///
/// The rate the caller names is the rate they get - a wrong seed is a lost transfer, never an
/// invented one. But `light-encode --sample-rate X --symbol-rate Y | light-decode` cannot carry X
/// and Y across a pipe, and a caller who names neither is asking for the documented default pairing:
/// when that pairing finds no frame at all, `decode` tries the ratios the receiver's seed tolerance
/// can still bridge (a 10% ladder around the default seed) and keeps the first one whose frame
/// passes the CRC. A stream that decodes at no rate still ends in `error.Incomplete`, with the
/// counters of the rate that was asked for.
///
/// `error.Incomplete` when the stream ends before a whole UR transfer has arrived: the caller
/// reports that, and nothing is written - a partial transfer never turns into a payload.
pub fn decode(
    allocator: std.mem.Allocator,
    samples: []const u8,
    settings: Settings,
    stats: *DecodeStats,
) ![]u8 {
    stats.* = .{ .samples_total = samples.len };
    if (samples.len == 0) return error.EmptyInput;

    // No allocation happens inside the receiving layers: these buffers are the bounds on what a
    // sender can make the decoder hold. On a PC the protocol's own limits are affordable (the
    // longest frame and payload `light.zig` can carry), so a hostile stream is an error and not a
    // crash. On the device these are the card's 64 KB and a small frame buffer instead.
    //
    // The message buffer also carries the payload ceiling the rest of the firmware accepts plus the
    // CBOR byte-string header the message carries; one `ur:crypto-psbt` transfer at a time.
    const frame = try allocator.alloc(u8, light.max_frame_len);
    defer allocator.free(frame);
    const payload_buf = try allocator.alloc(u8, light.max_payload_len);
    defer allocator.free(payload_buf);
    const message = try allocator.alloc(u8, ur_receive.max_payload_len + cbor.max_header_len);
    defer allocator.free(message);
    const bits = try allocator.alloc(u8, ur_receive.bitsLength(@intCast(message.len)));
    defer allocator.free(bits);
    const part = try allocator.alloc(u8, message.len);
    defer allocator.free(part);
    const buffers = DecodeBuffers{
        .frame = frame,
        .payload = payload_buf,
        .message = message,
        .bits = bits,
        .part = part,
    };

    const config = try settings.receiverConfig();
    var payload = try attempt(samples, config, buffers, stats);

    if (payload == null and stats.frames_accepted == 0 and settings.defaultRates()) {
        const seed = config.nominal_samples_per_symbol;
        var step_index: usize = 1;
        while (step_index <= max_rate_candidates) : (step_index += 1) {
            const candidate = rateCandidate(seed, step_index) orelse continue;
            var candidate_stats: DecodeStats = .{};
            const candidate_config = light_rx.Config{
                .nominal_samples_per_symbol = candidate,
                .hysteresis = settings.hysteresis,
            };
            if (try attempt(samples, candidate_config, buffers, &candidate_stats)) |found| {
                // The stream's own rate decided, and the CRC agreed: report that pass, not the
                // pass that found nothing.
                stats.* = candidate_stats;
                payload = found;
                break;
            }
        }
    }

    const found = payload orelse return error.Incomplete;
    const base64 = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, base64.calcSize(found.len));
    _ = base64.encode(encoded, found);
    return encoded;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A deterministic payload shaped like a PSBT (magic and all), base64, as the CLI reads it from
/// stdin. The identity these tests assert is about the light link, which does not care what the
/// payload means.
///
/// The real Bitcoin Core vector (`tests/vectors/core_psbt.json`) is what the CLI round trip in CI
/// uses, i.e. `zhww light-encode < psbt.txt | zhww light-decode`. It is not embedded here because
/// this file's tests are compiled with `src/cli/` as the package root (the CLI is not reachable
/// from `tests.zig`), and `@embedFile` may not leave the package root.
fn testPsbtBase64(allocator: std.mem.Allocator) ![]const u8 {
    var raw: [131]u8 = undefined;
    @memcpy(raw[0..5], "psbt\xff");
    for (raw[5..], 0..) |*byte, i| byte.* = @intCast((i * 37 + 11) % 256);
    const base64 = std.base64.standard.Encoder;
    return base64.encode(try allocator.alloc(u8, base64.calcSize(raw.len)), &raw);
}

/// Encodes and decodes the payload on this channel and asserts the base64 is unchanged.
fn expectRoundTrip(settings: Settings) !EncodeStats {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const psbt = try testPsbtBase64(allocator);
    var samples: std.Io.Writer.Allocating = .init(allocator);
    const encoded = try encode(allocator, psbt, settings, &samples.writer);
    try testing.expect(encoded.parts >= 1);
    try testing.expectEqual(@as(usize, @intCast(encoded.parts_expected)), encoded.parts);

    var stats: DecodeStats = .{};
    const got = try decode(allocator, samples.written(), settings, &stats);
    try testing.expectEqualStrings(psbt, got);
    try testing.expectEqual(@as(u32, @intCast(encoded.parts)), stats.frames_accepted);
    try testing.expectEqual(@as(u32, 0), stats.frames_rejected);
    // `ur_receive` counts accepted *fragments*: a single-part UR goes through `receiveSingle`,
    // which sets the sequence length but does not bump the fragment counter, so `parts_received`
    // stays 0 there even though the message is complete and verified.
    try testing.expectEqual(if (encoded.parts > 1) encoded.parts else 0, stats.parts_received);
    try testing.expectEqual(encoded.parts, stats.parts_expected);
    try testing.expect(stats.complete);
    try testing.expect(stats.parts_rejected == 0);
    try testing.expect(stats.last_error == null);
    return encoded;
}

test "the rate on both sides is one number: sample_rate / symbol_rate" {
    const documented = Settings{};
    try testing.expectEqual(@as(u32, 3000), documented.sample_rate_hz);
    try testing.expectEqual(@as(f32, 30), documented.symbol_rate_hz);
    try testing.expectEqual(@as(f32, 100), documented.samplesPerSymbol());
    try testing.expectEqual(@as(u16, 100), try documented.nominalSamplesPerSymbol());
    // The number the receiver is seeded with is the one the sender's samples were made at.
    try testing.expectEqual(@as(u16, 100), (try documented.receiverConfig()).nominal_samples_per_symbol);

    // The other combinations docs/09-light-audio-input.md §6 lists.
    try testing.expectEqual(@as(u16, 133), try (Settings{ .sample_rate_hz = 4000, .symbol_rate_hz = 30 }).nominalSamplesPerSymbol());
    try testing.expectEqual(@as(u16, 50), try (Settings{ .sample_rate_hz = 3000, .symbol_rate_hz = 60 }).nominalSamplesPerSymbol());
    try testing.expectEqual(@as(u16, 200), try (Settings{ .sample_rate_hz = 4000, .symbol_rate_hz = 20 }).nominalSamplesPerSymbol());

    // A rate that is not a usable symbol period is refused here, not silently seeded.
    try testing.expectError(error.InvalidEncoding, (Settings{ .sample_rate_hz = 0 }).nominalSamplesPerSymbol());
    try testing.expectError(error.InvalidEncoding, (Settings{ .symbol_rate_hz = 0 }).nominalSamplesPerSymbol());
    try testing.expectError(error.InvalidEncoding, (Settings{ .symbol_rate_hz = -30 }).nominalSamplesPerSymbol());
    try testing.expectError(error.InvalidEncoding, (Settings{ .sample_rate_hz = 3000, .symbol_rate_hz = 3000 }).nominalSamplesPerSymbol());
    try testing.expectError(error.InvalidEncoding, (Settings{ .sample_rate_hz = 3000, .symbol_rate_hz = 0.1 }).nominalSamplesPerSymbol());
    try testing.expectError(error.InvalidEncoding, (Settings{ .symbol_rate_hz = std.math.nan(f32) }).nominalSamplesPerSymbol());
}

test "the simulated channel carries the options, on the mains flicker frequencies" {
    const settings = Settings{
        .noise_sigma = 15,
        .flicker_amplitude = 20,
        .gain = 1.2,
        .drift_amplitude = 25,
        .seed = 7,
    };
    const channel = settings.channel(settings.seed);
    try testing.expectEqual(@as(u32, 3000), channel.sample_rate_hz);
    try testing.expectEqual(@as(f32, 30), channel.symbol_rate_hz);
    try testing.expectEqual(@as(f32, 15), channel.noise_sigma);
    try testing.expectEqual(@as(f32, 1.2), channel.gain);
    try testing.expectEqual(@as(f32, 100), channel.flicker[0].hz);
    try testing.expectEqual(@as(f32, 120), channel.flicker[1].hz);
    try testing.expectEqual(@as(f32, 20), channel.flicker[0].amplitude);
    try testing.expectEqual(@as(f32, 20), channel.flicker[1].amplitude);
    // Not phase 0: that is the one alignment that costs the first frame at 3000/30 with flicker 20.
    try testing.expectEqual(@as(f32, 0.4), channel.flicker[0].phase);
    try testing.expectEqual(@as(f32, 2.1), channel.flicker[1].phase);
    try testing.expectEqual(@as(f32, 0.7), channel.drift.hz);
    try testing.expectEqual(@as(f32, 25), channel.drift.amplitude);
    try testing.expectEqual(@as(u64, 7), channel.seed);

    // The default channel is the documented one: no impairments at all.
    const clean = (Settings{}).channel(default_seed);
    try testing.expectEqual(@as(f32, 0), clean.noise_sigma);
    try testing.expectEqual(@as(f32, 0), clean.flicker[0].amplitude);
    try testing.expectEqual(@as(f32, 1), clean.gain);
}

test "identity: a PSBT survives PSBT -> samples -> PSBT byte for byte" {
    const stats = try expectRoundTrip(.{});
    try testing.expect(stats.parts > 1); // a genuinely multi-part transfer
}

test "identity holds for every split the encoder can choose, including one part" {
    // `--fragment` is an upper bound, and the even split can come out a byte over it: a 136-byte
    // message with `--fragment 10` splits into 11-byte fragments (13 parts). The single-part form
    // is a different encoder branch (`ur.Encoder.next`) and a different receiver branch
    // (`ur_receive.Receiver.receiveSingle`), so it gets an assertion of its own.
    const many = try expectRoundTrip(.{ .fragment_len = ur.default_min_fragment_len });
    try testing.expectEqual(@as(usize, 11), many.fragment_len);
    try testing.expect(many.parts > 1);

    const single = try expectRoundTrip(.{ .fragment_len = 4096 });
    try testing.expectEqual(@as(usize, 1), single.parts);
    // One part carries the whole CBOR message (payload plus its byte-string header).
    try testing.expectEqual(cbor.bytesLength(single.payload_len), single.fragment_len);
}

test "identity survives the noise and flicker the receiver's tests measure as survivable" {
    // The receiver's header quotes what it measures at 4000 samples/s and 200 symbols/s with a
    // 110-count swing: gaussian noise to sigma ~21.8 (40% of the half-swing) and 100 Hz + 120 Hz
    // flicker to amplitude ~26.7 (24% of the swing). On the CLI's documented default pairing
    // (3000/30) each of those is tested here at a level the receiver's own limits cover with
    // margin: noise 15 and flicker 20.
    _ = try expectRoundTrip(.{ .noise_sigma = 15 });
    _ = try expectRoundTrip(.{ .flicker_amplitude = 20 });

    // Together the margin is smaller than either limit suggests: noise 15 *and* flicker 20 loses
    // every frame, at 3000/30 and at 4000/200 alike. Sweeping the two at 3000/30: noise 8 on top
    // of flicker 20 is the last combination that keeps all four frames, noise 10 already costs
    // three. (The receiver's own combined test uses noise 14 with flicker 18 for that reason.)
    // What is asserted here, therefore, is noise 8 on top of flicker 20, gain and drift.
    _ = try expectRoundTrip(.{
        .noise_sigma = 8,
        .flicker_amplitude = 20,
        .gain = 1.2,
        .drift_amplitude = 25,
    });
}

test "an excessive impairment loses the transfer instead of returning wrong data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const psbt = try testPsbtBase64(allocator);
    const too_noisy = Settings{ .noise_sigma = 60 }; // over the 55-count half-swing
    var samples: std.Io.Writer.Allocating = .init(allocator);
    const encoded = try encode(allocator, psbt, too_noisy, &samples.writer);
    try testing.expect(encoded.samples > 0);

    // The samples exist; the transfer does not come out. `decode` returns an error and no PSBT -
    // a wrong PSBT is not among its outcomes, whatever the noise did to the frame.
    var stats: DecodeStats = .{};
    try testing.expectError(error.Incomplete, decode(allocator, samples.written(), too_noisy, &stats));
    try testing.expect(!stats.complete);
    try testing.expectEqual(@as(usize, samples.written().len), stats.samples_consumed);
    try testing.expectEqual(@as(u32, 0), stats.frames_accepted);
    try testing.expectEqual(@as(usize, 0), stats.parts_received);
}

test "a recording at another rate decodes when no rate is named at all" {
    // The finding's own command, and the reason it failed before: `light-encode --sample-rate 300
    // --symbol-rate 10 | light-decode` cannot carry the rate across the pipe, so `light-decode` is
    // seeded with the documented default pairing - 100 samples per symbol - while the recording is
    // 30. Naming the rate on both sides is still the direct answer; this is the fallback for the
    // caller who named none, and it is the *stream* that decides.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const psbt = try testPsbtBase64(allocator);
    const sender = Settings{ .sample_rate_hz = 300, .symbol_rate_hz = 10 }; // 30 samples per symbol
    var samples: std.Io.Writer.Allocating = .init(allocator);
    const encoded = try encode(allocator, psbt, sender, &samples.writer);
    try testing.expect(encoded.parts > 1);

    var stats: DecodeStats = .{};
    const got = try decode(allocator, samples.written(), .{}, &stats);
    try testing.expectEqualStrings(psbt, got);
    // The rate that was found decoded every part, and it was found by the CRC, not by a guess that
    // happened to fit: a rejected frame would say so.
    try testing.expectEqual(@as(u32, @intCast(encoded.parts)), stats.frames_accepted);
    try testing.expectEqual(@as(u32, 0), stats.frames_rejected);
    try testing.expect(stats.complete);
    try testing.expect(stats.last_error == null);

    // The other direction: 4000 samples/s at 30 symbols/s is 133 samples per symbol, *above* the
    // default seed, so the ladder has to walk up to find it.
    const fast = Settings{ .sample_rate_hz = 4000, .symbol_rate_hz = 30 };
    var fast_samples: std.Io.Writer.Allocating = .init(allocator);
    _ = try encode(allocator, psbt, fast, &fast_samples.writer);
    var fast_stats: DecodeStats = .{};
    try testing.expectEqualStrings(psbt, try decode(allocator, fast_samples.written(), .{}, &fast_stats));
    try testing.expect(fast_stats.complete);
    try testing.expectEqual(@as(u32, 0), fast_stats.frames_rejected);

    // A named rate is still a named rate: the fallback does not run, and a wrong one loses the
    // transfer (the test below is the other half of that contract).
    var named_stats: DecodeStats = .{};
    try testing.expectError(
        error.Incomplete,
        decode(allocator, samples.written(), .{ .symbol_rate_hz = 20 }, &named_stats),
    );
    try testing.expectEqual(@as(u32, 0), named_stats.frames_accepted);
}

test "a receiver seeded for the wrong rate loses the transfer, it does not invent one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const psbt = try testPsbtBase64(allocator);
    var samples: std.Io.Writer.Allocating = .init(allocator);
    _ = try encode(allocator, psbt, .{}, &samples.writer);

    // The sender's 30 symbols/s read as 20: a 50% seed error, far outside the ~±10% the preamble
    // can be decoded with. The clock has nothing to lock onto, so nothing is decoded - and the
    // same holds for the other direction, for whatever is between the extremes.
    var stats: DecodeStats = .{};
    try testing.expectError(error.Incomplete, decode(allocator, samples.written(), .{ .symbol_rate_hz = 20 }, &stats));
    try testing.expectEqual(@as(u32, 0), stats.frames_accepted);
    try testing.expectEqual(@as(usize, 0), stats.parts_received);
}

test "bad input is a named error, not a decode of nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var samples: std.Io.Writer.Allocating = .init(allocator);
    try testing.expectError(error.EmptyInput, encode(allocator, "  \r\n", .{}, &samples.writer));
    try testing.expectError(error.InvalidBase64, encode(allocator, "not base64!", .{}, &samples.writer));
    try testing.expectError(error.InvalidBase64, encode(allocator, "AAA", .{}, &samples.writer)); // not a whole group
    try testing.expectEqual(@as(usize, 0), samples.written().len);

    var stats: DecodeStats = .{};
    try testing.expectError(error.EmptyInput, decode(allocator, &.{}, .{}, &stats));
    try testing.expectEqual(@as(usize, 0), stats.samples_total);
    // A single sample is not a channel and not a crash.
    try testing.expectError(error.Incomplete, decode(allocator, &.{127}, .{}, &stats));
    try testing.expectEqual(@as(usize, 1), stats.samples_total);
}
