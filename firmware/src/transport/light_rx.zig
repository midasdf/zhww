//! Light-channel analog receiver: ADC samples in, verified frame payloads out.
//!
//! `light.zig` is the *digital* half of the light channel: it demands a stream that is already
//! sliced at mid-scale and whose symbol period is exactly `samples_per_symbol`. A real LM393 board
//! on a real ADC is neither. The room light drifts, indoor lighting flickers at 100/120 Hz - the
//! same order as the data rate - the sender's clock is not the receiver's, and the first sample of
//! a frame is wherever the caller's buffer happened to start. This module is that missing layer:
//!
//!     ADC samples -> DC tracker -> hysteresis slicer -> clock recovery -> Manchester chips
//!                 -> bytes -> light.decodeFrame (preamble, version, length, CRC-32) -> payload
//!
//! **Signal model.** Samples are unsigned bytes: 0 = dark, 255 = saturated, one unit = one ADC
//! count for the whole layer (a 12-bit ADC such as the RP2350's must be shifted down before it is
//! handed in). A symbol is a constant light level for one symbol period, and a frame is
//! `light.modulate`'s waveform - IEEE 802.3 Manchester, `light_level`/`dark_level` - sitting on an
//! ambient level with a gain, gaussian noise, sinusoidal flicker and a slow drift on top, which is
//! exactly what `Channel`/`emit` below generate. The dark-to-light swing is expected to be several
//! times the hysteresis; a signal that never leaves the dead zone is not a signal.
//!
//! **What the receiver does**
//! - `dc`: a slow exponential moving average (the DC tracker) over a few symbol periods, seeded
//!   from the first sample. Ambient level, slow drift and gain changes move the slicing reference
//!   with them, so the decision is always taken against the middle of the *current* signal rather
//!   than against a fixed threshold that a lamp or a shadow would shift away.
//! - the slicer is a Schmitt trigger around `dc` with a dead zone of `hysteresis` counts: only a
//!   sample outside the dead zone moves the level, so noise near the reference cannot chatter the
//!   transitions the clock is recovered from.
//! - a symbol is not one sample: it is the *mean* of the samples in the middle half of the symbol
//!   period (at most `max_average_samples` of them), which averages the noise down before the
//!   decision. The per-sample slicer is used only to time edges.
//! - the clock is a digital PLL driven by the Manchester transitions. Every bit has a mid-bit
//!   transition and a bit boundary may add another, so transitions sit on symbol boundaries and
//!   nowhere else. A transition near the expected boundary pulls the phase; one a fifth of a period
//!   out is taken at face value (that is a rate error, not noise); and a run of transitions that
//!   stay outside the loop's trust window makes it give up and re-acquire, because in Manchester
//!   *every* transition is a boundary and so none of them is a guess.
//! - the symbol period is a Q8 fraction of a sample, measured from the phase error of those
//!   transitions *while a frame is being assembled*. A stretch of noise has no frame to measure,
//!   only transitions to be fooled by, so the clock re-seeds itself after `rearm_chips` chips
//!   without a frame: the seed is the one value known to be close, and the next preamble is what
//!   the loop re-acquires on.
//! - the frame is found by matching the 32-chip Manchester pattern of `light.preamble` in a sliding
//!   window, which also fixes the chip pairing: a chip-level match cannot be half a bit out of
//!   phase, so the frame can never come out inverted. One wrong chip is tolerated (a noise glitch
//!   inside the sync pattern). The version is checked the moment its byte arrives, the length as
//!   soon as the header is complete, and the finished frame goes through `light.decodeFrame`, so
//!   the frame format and the CRC have exactly one implementation.
//!
//! **Tolerances** - all of them measured by the tests at the bottom of this file, at 4000 samples
//! per second and 200 symbols per second with a 110-count swing, and asserted there against clearly
//! worse conditions that must fail:
//! - rate: the loop follows the sender over roughly -11% to +14% of the seed; the seed itself has
//!   to be within about ±10% of the truth, because the preamble has to be decoded with it before
//!   there is anything to measure. Within a few percent the round trip is reliable and the tracked
//!   period lands within a fraction of a percent of the sender's.
//! - phase: any sampling phase, including a fractional sample offset - the loop re-acquires over
//!   the first few transitions. An offset below half a symbol period never costs a chip.
//! - noise: gaussian noise up to ~40% of the half-swing (21.8 counts of 55 here), because a symbol
//!   is decided on the mean of up to 32 samples and the clock is timed on a hysteresis slicer.
//! - flicker: 100 Hz and 120 Hz together up to ~24% of the dark-to-light swing (26.7 counts of
//!   110) - in band, i.e. the hard case - and alone, and on top of drift, gain and rate error.
//! - drift: anything slow against the tracker's time constant (a few symbol periods); the tracker
//!   follows it, so the decision does not move.
//! - minimum frame: 9 bytes (an empty payload). Sync needs the two preamble bytes, so every
//!   well-formed frame is long enough; there is no separate minimum payload.
//!
//! **Not handled (deliberate limits)**
//! - A DC tracker is not a notch filter. Flicker at a frequency *near the symbol rate* is in band
//!   and no linear filter can separate it from the data: the tracker removes the flicker's mean,
//!   and the rest is rejected by the swing margin, not by filtering. Flicker comparable to the
//!   signal swing breaks the link, and the tests report where the line is.
//! - Inverted polarity (a channel that swaps light and dark) is *rejected*, not auto-detected: the
//!   inverted sync pattern can match two chips late, which decodes a frame slipped by one bit, and
//!   the version check and the CRC throw it away. Nothing is ever decoded from it.
//! - No operation without a seed. The preamble is alternating bits, so a run of it has no
//!   bit-boundary transitions and the chip rate cannot be told from half of it by the edges alone.
//!   The seed is what breaks that tie; it is a starting point the loop then measures away from, not
//!   a hard requirement on the rate.
//! - A burst of noise - enough transitions to walk the clock anywhere - costs the frame that
//!   follows it, not the ones after: the clock re-seeds after `rearm_chips` chips without a frame
//!   and re-acquires on the next preamble. A frame arriving while the clock is still polluted is
//!   missed (a retry), never mis-decoded (the CRC decides).
//! - The receiver needs the sample stream to continue for about one symbol period past the last
//!   chip of the frame: the last chip is only decided when its symbol boundary arrives. A real
//!   sender stops flashing and the screen stays dark, so the samples are there; a stream cut off
//!   exactly at the frame's last sample delivers the frame on the next chunk.
//! - A payload that itself contains the preamble's chip pattern starts a new frame (the newest sync
//!   wins, which is what keeps a phantom sync from swallowing the next real preamble). A `ur:`
//!   string cannot contain 0xAA at all - it is ASCII - so for this protocol the case does not
//!   arise; for a binary payload it would cost a retry.
//! - No automatic gain control: `hysteresis` is in ADC counts, so a channel much weaker than the
//!   configured hysteresis produces no clock at all, while a stronger one is fine (the tracker
//!   follows the gain; the hysteresis is only a dead zone). No AGC, no peak detector, no
//!   saturation recovery.
//! - No fountain codes, no encryption, no authentication, no multi-sender arbitration: one frame
//!   carries one payload and the CRC only catches corruption (`light.zig` owns those rules).
//! - No ADC driver, no DMA and no timing promises: this is the DSP over samples the caller already
//!   has. Interrupt and buffer handling stay outside, which is what keeps the layer host-testable.
//!
//! **No allocation.** Every buffer is the caller's: `frame_buf` caps the accepted frame length (and
//! so the payload), `payload_buf` caps the payload. The receiver is a fixed struct with no slices
//! of its own beyond those two, it never reads or writes outside them, and it can be reused for the
//! next frame whatever the previous call returned.
//!
//! Reference: docs/09-light-audio-input.md §3 (frame format), §6 (the LM393 module, sampling plan)
//! SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const light = @import("light.zig");

// ---------------------------------------------------------------- the analog model

/// Widest sample this layer takes, i.e. the assumed ADC width: 8 bits, one unit = one count.
pub const adc_max: u16 = 0xff;

/// Fixed-point fraction used for the period and the phase: Q8, 256 = one sample.
pub const q8_one: u32 = 256;

/// Samples per symbol the receiver is seeded with by default.
///
/// The documented operating point is an ADC sampled at a few kHz and a sender flashing at 30-60
/// symbols/s (docs/09-light-audio-input.md §3/§6), i.e. ~100 samples per symbol at 4 kHz. This is
/// only the seed; the PLL measures the real period from the transitions.
pub const default_nominal_samples_per_symbol: u16 = 100;

/// Dead zone of the Schmitt trigger, in ADC counts, by default.
///
/// Should be around a tenth of the expected dark-to-light swing and must stay well below half of
/// it, or the two levels never leave the dead zone and no edge is ever seen.
pub const default_hysteresis: u8 = 12;

/// How far the measured period may move from the seed, in percent, by default: the outer clamp.
/// The loop's real pull-in is a few percent (the tests measure it); this only stops a nonsense
/// value from ever being adopted.
pub const default_rate_tolerance_percent: u8 = 30;

/// Time constant of the DC tracker, in symbol periods.
const dc_tau_symbols: u32 = 4;
/// Smallest and largest symbol period the loop will ever settle on, in samples.
const min_period_samples: u32 = 4;
const max_period_samples: u32 = 4096;
/// Most samples averaged into one symbol decision (bounds the accumulator and the work per symbol).
const max_average_samples: u32 = 32;
/// Clock loop gains, as divisors: the phase is pulled by `error/phase_gain_div` while tracking,
/// the period by the same error over `period_gain_div`, and harder (over `acquire_gain_div`) while
/// re-acquiring, where being slow costs the preamble.
const phase_gain_div: i32 = 4;
const period_gain_div: i32 = 16;
const acquire_gain_div: i32 = 8;
/// The period integrator also leaks back toward the seed with this divisor, so noise cannot
/// random-walk the loop away from a measured period (a real rate error dwarfs the leak).
const period_leak_div: i32 = 128;
/// Bound on the period integrator's remainder, so a clamped period cannot wind it up.
const period_accum_limit: i32 = 4096;
/// Chips without a frame before the clock is re-seeded. A burst of noise can walk the period and
/// the phase anywhere; the seed is the one value known to be close, and the next frame's preamble
/// is what the loop re-acquires on, so forgetting a bad stretch costs nothing.
const rearm_chips: u32 = 512;
/// Transitions closer together than this many symbol periods keep a frame alive: in Manchester a
/// bit always has a mid-bit transition, so consecutive transitions are at most two periods apart.
const gap_symbols: u32 = 4;
/// Transitions in a row outside the loop's trust window before the clock gives up on its phase and
/// re-acquires: a clock that is out of step, rather than a glitch.
const snap_edges: u8 = 5;
/// Transitions the clock is re-acquired on after that: the phase is put straight onto the
/// transition, because in Manchester every transition *is* a symbol boundary, and only then does
/// the soft loop take over again.
const settle_edges: u8 = 3;
/// Chips of the preamble that may be wrong for the sync pattern to still match (a noise glitch).
const preamble_chip_tolerance: u32 = 1;

/// The 32 chips of `light.preamble` (two 0xAA bytes) as one bit pattern, most significant first.
pub const preamble_chips: u32 = blk: {
    var window: u32 = 0;
    for (light.preamble) |byte| {
        for (0..8) |k| {
            const bit: u1 = @intCast((byte >> @intCast(7 - k)) & 1);
            for (light.symbolsForBit(bit)) |symbol| {
                window = (window << 1) | @backingInt(symbol);
            }
        }
    }
    break :blk window;
};

/// Light level of chip `index` of `frame`, without materialising the whole symbol array - the
/// sender side needs one chip at a time and must not allocate 16 bytes per frame byte.
///
/// @pre `index < light.symbolLength(frame.len)`.
pub fn chipOf(frame: []const u8, index: usize) light.Symbol {
    const bit_index = (index % light.symbolLength(1)) / light.symbols_per_bit;
    const half = index % light.symbols_per_bit;
    const byte = frame[index / light.symbolLength(1)];
    const bit: u1 = @intCast((byte >> @intCast(7 - bit_index)) & 1);
    return light.symbolsForBit(bit)[half];
}

// ---------------------------------------------------------------- errors

/// Errors the receiver can return.
///
/// A superset of `light.DecodeError` - a frame that was found and rejected is reported with the
/// digital layer's own errors (`error.ChecksumMismatch`, `error.UnsupportedVersion`,
/// `error.TooLarge`, `error.InvalidSymbol`, `error.Truncated`) - with the one state only the analog
/// layer can see. Finding nothing is not an error: it is `null`.
pub const DecodeError = light.DecodeError || error{
    /// No level transition for several symbol periods: silence, a lamp shining on the sensor, or a
    /// signal that never leaves the hysteresis dead zone. There is no clock to recover from a
    /// constant, so this is reported instead of pretending to listen. It is never returned while a
    /// frame is being assembled (a gap inside a frame is a rejected frame, not a missing channel),
    /// and never for a short chunk that merely happens to contain no transition.
    NoSignal,
};

// ---------------------------------------------------------------- configuration

/// Receiver settings. Everything else is measured from the samples.
pub const Config = struct {
    /// Starting point for the symbol period, in samples per symbol. The clock loop measures the
    /// real period from the transitions and tracks it, but the *preamble* has to be decoded with
    /// this number before there is anything to measure: being a few percent off costs nothing,
    /// being more than about 10% off costs the frame (the tests measure both).
    nominal_samples_per_symbol: u16 = default_nominal_samples_per_symbol,
    /// Schmitt trigger dead zone around the DC tracker, in ADC counts. Around a tenth of the
    /// expected swing, and well below half of it.
    hysteresis: u8 = default_hysteresis,
    /// Outer bound on how far the measured period may move from the seed, in percent. A sanity
    /// clamp, not a promise: what the loop can actually follow is a few percent (measured -11% to
    /// +14% at 20 samples per symbol), and a period that has wandered further than that is one the
    /// receiver should not be trusting anyway.
    rate_tolerance_percent: u8 = default_rate_tolerance_percent,
};

// ---------------------------------------------------------------- sender side

/// One sinusoidal component of the channel: mains flicker, or the slow drift of the room light.
pub const Tone = struct {
    /// Frequency in Hz. 0 means "not present".
    hz: f32 = 0,
    /// Amplitude in ADC counts, peak.
    amplitude: f32 = 0,
    /// Phase in radians at t = 0.
    phase: f32 = 0,

    fn value(self: Tone, t: f32) f32 {
        if (self.amplitude == 0 or self.hz == 0) return 0;
        return self.amplitude * @sin(2 * std.math.pi * self.hz * t + self.phase);
    }
};

/// A simulated light channel: what a screen flicker looks like to an LM393 board on an ADC.
///
/// This is the sender side of the link: tests drive the receiver through it, and a future
/// device-to-device mode can reuse it to generate the samples that would drive a display. Every
/// field is a property of the channel, not of the firmware.
pub const Channel = struct {
    /// ADC sample rate, in samples per second. The receiver must be told the same rate only through
    /// `Config.nominal_samples_per_symbol` = `sample_rate_hz / symbol_rate_hz`.
    sample_rate_hz: u32 = 4000,
    /// Symbol (Manchester chip) rate, in symbols per second. May be fractional.
    symbol_rate_hz: f32 = 200,
    /// Mean light level, in ADC counts (the room light the screen flickers on top of).
    ambient: f32 = 127.5,
    /// Dark-to-light swing, in ADC counts, before `gain`. The dark level is
    /// `ambient - swing*gain/2` and the light level `ambient + swing*gain/2`.
    swing: f32 = 110,
    /// Channel gain, applied to the swing only (the ambient is not amplified).
    gain: f32 = 1,
    /// Standard deviation of the additive gaussian noise, in ADC counts.
    noise_sigma: f32 = 0,
    /// Mains flicker: 100 Hz (50 Hz mains) and 120 Hz (60 Hz mains) at once, if both are given.
    flicker: [2]Tone = .{ .{}, .{} },
    /// Slow drift of the ambient level (a shadow, a cloud, a hand).
    drift: Tone = .{},
    /// Sampling phase: where the first sample falls inside a symbol period, in samples. Fractional
    /// values are the point - a real receiver never starts on a symbol boundary.
    phase_samples: f32 = 0,
    /// Symbol periods of idle (dark) screen after the frame. Not padding for the receiver's
    /// convenience: a real sender stops flashing and the screen stays dark, and the receiver needs
    /// the samples of the last symbol period before it can decide the last chip. Set to 0 to get
    /// exactly the frame's own samples (`light.modulate`'s length).
    tail_symbols: f32 = 2,
    /// Seed of the noise generator: the same seed always produces the same stream.
    seed: u64 = 0x5eed_1234,
};

/// Samples a frame of `frame_len` bytes occupies on this channel (the same relation as
/// `light.sampleLength`, but with a fractional samples-per-symbol).
pub fn sampleCount(channel: Channel, frame_len: usize) usize {
    if (channel.sample_rate_hz == 0 or channel.symbol_rate_hz <= 0) return 0;
    const symbols: f32 = @floatFromInt(light.symbolLength(frame_len));
    const per_symbol = @as(f32, @floatFromInt(channel.sample_rate_hz)) / channel.symbol_rate_hz;
    return @intFromFloat(@ceil((symbols + @max(channel.tail_symbols, 0)) * per_symbol));
}

/// Sender-side sample generator: the ADC samples a screen showing `frame` would produce on this
/// channel.
///
/// Deterministic: the same channel and frame always give the same samples, so a test failure is
/// reproducible. `error.BufferTooSmall` when `out` cannot hold `sampleCount(channel, frame.len)`
/// samples, `error.InvalidEncoding` for a channel with no sample rate or no symbol rate.
pub fn emit(channel: Channel, frame: []const u8, out: []u8) light.EncodeError![]u8 {
    if (channel.sample_rate_hz == 0 or channel.symbol_rate_hz <= 0) return error.InvalidEncoding;
    const count = sampleCount(channel, frame.len);
    if (out.len < count) return error.BufferTooSmall;

    var prng = std.Random.DefaultPrng.init(channel.seed);
    const random = prng.random();
    const per_symbol = @as(f32, @floatFromInt(channel.sample_rate_hz)) / channel.symbol_rate_hz;
    const sample_rate: f32 = @floatFromInt(channel.sample_rate_hz);
    const chips = light.symbolLength(frame.len);
    const half_swing = 0.5 * channel.swing * channel.gain;

    for (out[0..count], 0..) |*slot, i| {
        const position = (@as(f32, @floatFromInt(i)) + channel.phase_samples) / per_symbol;
        var level = channel.ambient;
        // Before the frame the screen is dark (or has not started), and so it is after it.
        const started = position >= 0;
        const index: usize = if (started) @intFromFloat(position) else 0;
        if (started and index < chips) {
            level += if (chipOf(frame, index) == .light) half_swing else -half_swing;
        } else {
            level -= half_swing;
        }

        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        for (channel.flicker) |tone| level += tone.value(t);
        level += channel.drift.value(t);
        if (channel.noise_sigma > 0) level += random.floatNorm(f32) * channel.noise_sigma;

        slot.* = clampSample(level);
    }
    return out[0..count];
}

/// One level rounded and clamped into the 8-bit ADC range. Clipping at the rails is what a real ADC
/// does, and the tests' channels stay clear of it except where they mean to.
fn clampSample(level: f32) u8 {
    if (!(level > 0)) return 0; // also catches NaN
    if (level >= @as(f32, @floatFromInt(adc_max))) return @intCast(adc_max);
    return @intFromFloat(@round(level));
}

// ---------------------------------------------------------------- receiver

/// Streaming light-channel receiver: ADC samples in, verified payloads out.
///
/// Feed it the sample stream in any chunking; it keeps the tracker, the clock and the half-assembled
/// frame across calls. Nothing is allocated and nothing outside `frame_buf`/`payload_buf` is
/// written, so the caller's buffers are the bound on what a sender can make the device hold.
pub const Receiver = struct {
    /// Destination for the assembled frame (preamble through CRC). Its length caps the frame, and
    /// so the payload, that a sender can get the device to assemble.
    frame_buf: []u8,
    /// Destination for the verified payload. Its length caps the payload.
    payload_buf: []u8,

    // ---- clock recovery
    /// Symbol period in Q8 samples: the measured value, seeded from the configuration.
    period_q8: u32,
    /// The seed, kept so the period integrator can leak back to it and the clock can re-arm.
    seed_period_q8: u32,
    min_period_q8: u32,
    max_period_q8: u32,
    /// Remainder of the period integrator, in Q8 samples.
    period_accum: i32 = 0,
    /// Chips since the last frame was in progress, for the clock re-arm.
    idle_chips: u32 = 0,
    /// Samples (Q8) since the last declared symbol boundary: the phase of the symbol clock.
    phase_q8: i32 = 0,
    /// Transitions seen in a row that were too far from a boundary to trust.
    far_edges: u8 = 0,
    /// Transitions left in which the phase is hard-set from the transition itself: re-acquisition.
    settle: u8 = 0,
    edges: u32 = 0,

    // ---- DC tracker and slicer
    /// Ambient tracker in Q8 ADC counts. The slicing reference.
    dc_q8: i32 = 0,
    dc_shift: u5,
    hysteresis: u8,
    primed: bool = false,
    /// Output of the Schmitt trigger: the level the clock's edges are taken from.
    level: light.Symbol = .dark,

    // ---- symbol decision
    chip_sum: u32 = 0,
    chip_n: u32 = 0,

    // ---- chip stream and frame assembly
    chip_window: u32 = 0,
    chips: u32 = 0,
    in_frame: bool = false,
    frame_len: usize = 0,
    frame_total: usize = 0,
    pairing: bool = false,
    pending_chip: light.Symbol = .dark,
    bit_acc: u8 = 0,
    bit_count: u4 = 0,
    samples_since_edge_q8: u32 = 0,

    // ---- results
    payload: []const u8 = &.{},
    delivered: bool = false,
    pending_error: ?DecodeError = null,
    /// Samples the last `receive` consumed. On success it ends at the last sample of the frame that
    /// was returned, so the caller can walk a stream of frames by feeding `samples[samples_used..]`
    /// again. 0 before the first call.
    samples_used: usize = 0,
    frames_accepted: u32 = 0,
    frames_rejected: u32 = 0,

    /// `frame_buf` and `payload_buf` belong to the caller and must outlive the receiver: the
    /// receiver never copies or allocates them.
    ///
    /// `error.InvalidEncoding` for a zero (or absurd) nominal rate - a caller bug in the same sense
    /// as `light.modulate`'s - and `error.TooLarge` when `frame_buf` cannot hold even the smallest
    /// frame, because then no sender could ever get through.
    pub fn init(frame_buf: []u8, payload_buf: []u8, config: Config) DecodeError!Receiver {
        if (config.nominal_samples_per_symbol < min_period_samples or
            config.nominal_samples_per_symbol > max_period_samples) return error.InvalidEncoding;
        if (frame_buf.len < light.header_len + light.crc_len) return error.TooLarge;

        const seed: u32 = @as(u32, config.nominal_samples_per_symbol) * q8_one;
        // Explicit type: `@min` narrows its result to the smallest type that fits the bound.
        const tolerance: u8 = @min(config.rate_tolerance_percent, 90);
        return .{
            .frame_buf = frame_buf,
            .payload_buf = payload_buf,
            .period_q8 = seed,
            .seed_period_q8 = seed,
            .min_period_q8 = seed * (100 - tolerance) / 100,
            .max_period_q8 = seed * (100 + tolerance) / 100,
            .dc_shift = dcShiftFor(config.nominal_samples_per_symbol),
            .hysteresis = config.hysteresis,
        };
    }

    /// Forgets the half-assembled frame, the clock and the tracker, keeping the buffers and the
    /// configuration. The caller uses this before a new transfer (the next frame is found from
    /// scratch); it is not needed between frames, which the receiver already walks by itself.
    pub fn reset(self: *Receiver) void {
        self.phase_q8 = 0;
        self.far_edges = 0;
        self.edges = 0;
        self.dc_q8 = 0;
        self.primed = false;
        self.level = .dark;
        self.chip_sum = 0;
        self.chip_n = 0;
        self.chip_window = 0;
        self.chips = 0;
        self.period_accum = 0;
        self.idle_chips = 0;
        self.settle = settle_edges;
        self.forgetFrame();
        self.samples_since_edge_q8 = 0;
        self.payload = &.{};
        self.delivered = false;
        self.pending_error = null;
        self.samples_used = 0;
        self.frames_accepted = 0;
        self.frames_rejected = 0;
    }

    /// The symbol period the clock has measured, in samples per symbol. The measured tolerance of
    /// this number against the sender's real rate is reported by the tests.
    pub fn measuredSamplesPerSymbol(self: *const Receiver) f32 {
        return @as(f32, @floatFromInt(self.period_q8)) / @as(f32, @floatFromInt(q8_one));
    }

    /// Whether a frame is half-assembled right now (the receiver is past a preamble and waiting for
    /// the rest of the bytes).
    pub fn isInFrame(self: *const Receiver) bool {
        return self.in_frame;
    }

    /// Pushes one chunk of samples through the receiver.
    ///
    /// Returns the payload of the first frame that is completed and verified inside `samples`, or
    /// null when no frame finished in this chunk (the rest of a frame may still be on its way; the
    /// receiver keeps it). `samples_used` says how much of the chunk that took, so a stream with
    /// several frames can be walked by feeding `samples[samples_used..]` again.
    ///
    /// A frame that is found and rejected is reported with the digital layer's error
    /// (`error.ChecksumMismatch` and friends) and the receiver immediately carries on scanning, so
    /// a corrupt frame followed by a good one in the same chunk still returns the good payload. If
    /// nothing completes, the *first* rejection in the chunk is the error; only when the stream has
    /// carried no transition for several symbol periods is it `error.NoSignal`. On error
    /// `payload_buf` is only ever touched by `light.decodeFrame`, which writes nothing until a
    /// frame has fully passed its checks.
    pub fn receive(self: *Receiver, samples: []const u8) DecodeError!?[]const u8 {
        self.samples_used = 0;
        self.pending_error = null;
        self.delivered = false;
        if (samples.len == 0) return null;

        for (samples, 0..) |sample, i| {
            self.pushSample(sample);
            self.samples_used = i + 1;
            if (self.delivered) {
                self.delivered = false;
                self.frames_accepted += 1;
                return self.payload;
            }
        }

        if (self.pending_error) |err| return err;
        // Nothing for several symbol periods is not a slow frame, it is no channel at all: say so
        // instead of returning "nothing yet" forever. A short chunk mid-frame is not this - the
        // receiver has transitions in living memory, so it is simply still listening.
        if (!self.in_frame and self.samples_since_edge_q8 > gap_symbols * self.period_q8) {
            return error.NoSignal;
        }
        return null;
    }

    // ------------------------------------------------------------ per-sample pipeline

    /// One ADC sample through tracker, slicer, symbol window and clock.
    fn pushSample(self: *Receiver, sample: u8) void {
        const x: i32 = @as(i32, sample) << 8;

        // 1. Ambient removal: the slow moving average the decision is taken against.
        if (!self.primed) {
            self.dc_q8 = x;
            self.primed = true;
        } else {
            self.dc_q8 += (x - self.dc_q8) >> self.dc_shift;
        }

        // 2. Hysteresis slicer: only a sample outside the dead zone moves the level, so noise
        //    around the reference does not chatter the edge stream the clock is recovered from.
        //    The time since the last transition counts *this* sample first, so the interval the
        //    period is measured from is the distance between the two transitions and not one sample
        //    short (a one-sample bias would be a 5% rate error at 20 samples per symbol).
        if (self.samples_since_edge_q8 < std.math.maxInt(u32) - q8_one) {
            self.samples_since_edge_q8 += @intCast(q8_one);
        }
        const dead: i32 = @as(i32, self.hysteresis) << 8;
        var level = self.level;
        if (x > self.dc_q8 + dead) {
            level = .light;
        } else if (x < self.dc_q8 - dead) {
            level = .dark;
        }
        if (level != self.level) {
            self.level = level;
            self.onEdge();
            self.samples_since_edge_q8 = 0;
        }

        // 3. Symbol clock and symbol window.
        const period: i32 = @intCast(self.period_q8);
        self.phase_q8 += @intCast(q8_one);
        if (self.phase_q8 >= period) self.crossBoundary();
        const quarter = period >> 2;
        if (self.phase_q8 >= quarter and self.phase_q8 < period - quarter) {
            if (self.chip_n < max_average_samples) {
                self.chip_sum += sample;
                self.chip_n += 1;
            }
        }

        // 4. A frame whose transitions stopped is dead, not patiently awaited: the sender went away
        //    or the sensor was covered. In Manchester consecutive transitions are at most two
        //    symbol periods apart, so a gap of several is not a frame any more. (A frozen level
        //    usually shows up first as two equal chips, i.e. `error.InvalidSymbol`; this is the
        //    backstop for a clock that has stopped producing chips at all.)
        if (self.in_frame and self.samples_since_edge_q8 > gap_symbols * self.period_q8) {
            self.reject(error.Truncated);
        }
    }

    /// A Manchester transition: every transition sits on a symbol boundary, so it is both a phase
    /// reference and the measurement the symbol period is taken from.
    fn onEdge(self: *Receiver) void {
        if (self.edges != std.math.maxInt(u32)) self.edges += 1;

        const period: i32 = @intCast(self.period_q8);
        // Signed error of this transition against the nearest symbol boundary, in Q8 samples.
        var error_q8 = self.phase_q8;
        if (2 * error_q8 >= period) error_q8 -= period;

        // Transitions are trusted while they are near the boundary the loop expects (within a
        // quarter of a period). A far one is either a glitch or a clock that is out of step, and
        // treating it like a trusted one is how a phase detector slips a cycle: one noisy sample
        // just past the half-period mark would otherwise yank the clock by half a symbol.
        const distance: u32 = @intCast(@abs(error_q8));
        if (self.settle > 0) {
            // Re-acquisition: in Manchester every transition is a symbol boundary, so putting the
            // phase on this one is not a guess - it is the definition. Only the noise on the
            // transition itself is injected, which is why the soft loop takes over again after a
            // few of them.
            self.settle -= 1;
            self.phase_q8 -= error_q8;
            self.far_edges = 0;
            self.integratePeriod(error_q8, acquire_gain_div);
        } else if (distance * 4 <= @as(u32, @intCast(period))) {
            // Near enough to trust. A small error is averaged - that is what keeps the sampling
            // window from following every noisy transition - but a large one is taken at face
            // value, because a clock that is a fifth of a symbol out is not being nudged by noise,
            // it is running at a different rate than the sender.
            if (distance * 16 <= @as(u32, @intCast(period))) {
                self.phase_q8 -= @divTrunc(error_q8, phase_gain_div);
            } else {
                self.phase_q8 -= error_q8;
            }
            self.far_edges = 0;
            self.integratePeriod(error_q8, period_gain_div);
        } else if (self.far_edges > 0) {
            // Consecutive far transitions, whatever their sign: a phase stuck near half a period
            // flips the sign of the error from one transition to the next, and waiting for a run of
            // one sign would wait forever. Any of them is still a symbol boundary.
            self.far_edges += 1;
            if (self.far_edges < snap_edges) return;
            self.far_edges = 0;
            self.settle = settle_edges;
            self.phase_q8 -= error_q8;
            self.integratePeriod(error_q8, acquire_gain_div);
        } else {
            self.far_edges = 1;
            return;
        }

        if (self.phase_q8 < 0) self.phase_q8 = 0;
        if (self.phase_q8 >= period) self.crossBoundary();
    }

    /// Pulls the period estimate toward the rate the transitions imply, by `error/gain_div`.
    ///
    /// The integrator keeps a remainder, so a fraction of a Q8 count per transition is not rounded
    /// away, and it leaks slowly back toward the seed so that a run of noise cannot walk it off on
    /// its own. A real rate error is far larger than the leak, so the measured value stands.
    fn integratePeriod(self: *Receiver, error_q8: i32, gain_div: i32) void {
        // Only while a frame is being assembled. The clock is measured on frames; a stretch of
        // noise has no frame to measure, only transitions to be fooled by, and a period that
        // random-walked through it would leave the next real preamble undecodable.
        if (!self.in_frame) return;

        const period: i32 = @intCast(self.period_q8);
        self.period_accum += error_q8;
        self.period_accum += @divTrunc(
            @as(i32, @intCast(self.seed_period_q8)) - period,
            period_leak_div,
        );
        self.period_accum = std.math.clamp(self.period_accum, -period_accum_limit, period_accum_limit);
        const step = @divTrunc(self.period_accum, gain_div);
        self.period_q8 = @intCast(std.math.clamp(
            @as(i64, self.period_q8) + step,
            @as(i64, self.min_period_q8),
            @as(i64, self.max_period_q8),
        ));
        if (step != 0) self.period_accum -= step * gain_div;
        // Wound up against a clamp: do not carry the remainder into the next transition.
        if (self.period_q8 == self.min_period_q8 or self.period_q8 == self.max_period_q8) {
            self.period_accum = 0;
        }
    }

    /// The symbol clock reached the end of a symbol period: decide the symbol that just ended and
    /// start the next one.
    fn crossBoundary(self: *Receiver) void {
        self.phase_q8 -= @intCast(self.period_q8);
        if (self.phase_q8 < 0) self.phase_q8 = 0;
        self.emitChip();
        self.chip_sum = 0;
        self.chip_n = 0;
    }

    /// The symbol value: the mean of the samples in the middle half of the period against the DC
    /// tracker, not one sample. Averaging is what buys the noise margin; the slicer is only there
    /// to time edges. (With no samples in the window - only possible for an absurdly short period -
    /// the slicer state stands in.)
    fn emitChip(self: *Receiver) void {
        const chip: light.Symbol = if (self.chip_n == 0)
            self.level
        else
            (if (@as(i32, @intCast((self.chip_sum << 8) / self.chip_n)) > self.dc_q8) .light else .dark);
        self.onChip(chip);
    }

    // ------------------------------------------------------------ chip stream -> frame

    /// One Manchester chip (half a bit) of the recovered symbol stream.
    fn onChip(self: *Receiver, chip: light.Symbol) void {
        if (self.chips != std.math.maxInt(u32)) self.chips += 1;
        self.chip_window = (self.chip_window << 1) | @as(u32, @backingInt(chip));

        // The preamble's own chip pattern is the frame's sync mark, and matching it at the chip
        // level fixes the pairing too: a window match cannot be half a bit out of phase, so the
        // frame can never come out inverted. One wrong chip is tolerated: a noise glitch inside the
        // sync pattern must not cost the whole frame.
        //
        // The newest sync wins, even in the middle of a frame. A phantom frame - the idle chips of
        // an inter-frame gap lining up with the pattern's dark pair, or a burst of noise - would
        // otherwise swallow the real preamble that arrives a few chips later, and the receiver
        // would sit on a frame that cannot be valid instead of taking the one that can. Restarting
        // costs a payload that contains the pattern itself (a `ur:` string never can: it is ASCII,
        // and 0xAA is not), and that frame would only have been a coin toss anyway.
        if (@popCount(self.chip_window ^ preamble_chips) <= preamble_chip_tolerance) {
            self.startFrame();
            return;
        }
        if (!self.in_frame) {
            // A long stretch without a frame is where noise does its damage: a few thousand random
            // transitions can leave the period and the phase anywhere, and a good frame arriving
            // after that would be missed by a clock that is nowhere near it. Re-seeding throws the
            // bad stretch away, and the next preamble re-acquires in a few transitions.
            self.idle_chips +|= 1;
            if (self.idle_chips >= rearm_chips) self.rearmClock();
            return;
        }

        if (!self.pairing) {
            self.pending_chip = chip;
            self.pairing = true;
            return;
        }
        self.pairing = false;
        const bit = light.bitForSymbols(self.pending_chip, chip) catch {
            // Two equal symbols are not a Manchester pair: the clock slipped or the channel is not
            // Manchester at all. Either way the frame cannot be trusted.
            self.reject(error.InvalidSymbol);
            return;
        };
        self.pushBit(bit);
    }

    /// The preamble has been recognised: the two bytes are known, so the frame buffer is seeded with
    /// them and the version byte starts at the next chip.
    fn startFrame(self: *Receiver) void {
        self.in_frame = true;
        self.idle_chips = 0;
        self.frame_len = light.preamble_len;
        self.frame_total = 0;
        self.frame_buf[0] = light.preamble[0];
        self.frame_buf[1] = light.preamble[1];
        self.pairing = false;
        self.bit_acc = 0;
        self.bit_count = 0;
        self.samples_since_edge_q8 = 0;
    }

    fn pushBit(self: *Receiver, bit: u1) void {
        self.bit_acc = (self.bit_acc << 1) | @as(u8, bit);
        self.bit_count += 1;
        if (self.bit_count < 8) return;
        self.bit_count = 0;
        self.pushByte(self.bit_acc);
    }

    /// One more byte of the frame being assembled. The version is checked as its byte arrives and
    /// the length as soon as the header is complete, so neither a stranger's frame nor a runaway
    /// length can make the receiver collect kilobytes of noise, and the finished frame goes to
    /// `light.decodeFrame`: the frame format and the CRC have one implementation, there.
    fn pushByte(self: *Receiver, byte: u8) void {
        if (self.frame_len >= self.frame_buf.len) {
            self.reject(error.TooLarge);
            return;
        }
        self.frame_buf[self.frame_len] = byte;
        self.frame_len += 1;

        // The version is checked the moment it arrives rather than at the end of the header: a
        // wrong one means this is not a frame of ours, and saying so early is what lets the
        // receiver get back to hunting for a real preamble instead of finishing a header it
        // already knows is not one.
        if (self.frame_len == light.preamble_len + 1 and byte != light.version) {
            self.reject(error.UnsupportedVersion);
            return;
        }

        if (self.frame_len == light.header_len) {
            const declared = std.mem.readInt(u16, self.frame_buf[3..5], .little);
            self.frame_total = light.header_len + @as(usize, declared) + light.crc_len;
            if (self.frame_total > self.frame_buf.len) {
                self.reject(error.TooLarge);
                return;
            }
        }

        if (self.frame_total != 0 and self.frame_len == self.frame_total) self.completeFrame();
    }

    fn completeFrame(self: *Receiver) void {
        const frame = self.frame_buf[0..self.frame_total];
        self.forgetFrame();
        self.payload = light.decodeFrame(frame, self.payload_buf) catch |err| {
            self.frames_rejected += 1;
            self.noteError(err);
            return;
        };
        self.delivered = true;
    }

    /// A frame that was found and rejected: report it, drop the assembly and keep scanning, so the
    /// very next frame in the same chunk is still received.
    fn reject(self: *Receiver, err: DecodeError) void {
        self.frames_rejected += 1;
        self.noteError(err);
        self.forgetFrame();
    }

    fn noteError(self: *Receiver, err: DecodeError) void {
        if (self.pending_error == null) self.pending_error = err;
    }

    /// Puts the clock back on its seed: the receiver has seen nothing frame-shaped for long enough
    /// that the tracked values are more likely to be noise than signal.
    fn rearmClock(self: *Receiver) void {
        self.period_q8 = self.seed_period_q8;
        self.period_accum = 0;
        self.phase_q8 = 0;
        self.far_edges = 0;
        self.settle = settle_edges;
        self.idle_chips = 0;
    }

    fn forgetFrame(self: *Receiver) void {
        self.in_frame = false;
        self.frame_len = 0;
        self.frame_total = 0;
        self.pairing = false;
        self.bit_acc = 0;
        self.bit_count = 0;
    }
};

/// DC tracker shift (its time constant is `2^shift` samples) for a nominal symbol period: a few
/// symbol periods, so the reference follows the room light but not the data.
fn dcShiftFor(nominal_samples_per_symbol: u16) u5 {
    const tau = dc_tau_symbols * @as(u32, nominal_samples_per_symbol);
    const shift = std.math.log2_int_ceil(u32, tau);
    return @intCast(std.math.clamp(shift, 3, 14));
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const ur = @import("ur.zig");

/// The sample rate every test in this file simulates. Rates are stated per test as well: a number
/// without its sample rate means nothing here.
const test_sample_rate_hz: u32 = 4000;

/// The bc-ur reference part from `ur.expected_parts[0]`: a real 101-byte UR string, i.e. exactly
/// what the light channel exists to deliver, at a size that keeps the sweeps quick.
const test_ur = ur.expected_parts[0];

/// A channel with every impairment switched off: 200 symbols/s at 4000 samples/s.
fn cleanChannel() Channel {
    return .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200 };
}

/// The configuration matching `cleanChannel`, i.e. a seed that is exactly right.
fn cleanConfig() Config {
    return .{ .nominal_samples_per_symbol = 20 };
}

/// One end-to-end trial without allocating: does this payload survive this channel?
fn roundTrips(payload: []const u8, channel: Channel, config: Config) bool {
    var frame_buf: [512]u8 = undefined;
    const frame = light.encodeFrame(payload, &frame_buf) catch return false;

    var samples: [128 * 1024]u8 = undefined;
    const emitted = emit(channel, frame, &samples) catch return false;

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = Receiver.init(&rx_frame, &rx_payload, config) catch return false;
    const got = receiver.receive(emitted) catch return false;
    const delivered = got orelse return false;
    return std.mem.eql(u8, payload, delivered);
}

/// Asserts a full round trip and returns nothing; on failure the message names the channel, because
/// "it did not decode" is useless without knowing what the channel was doing.
fn expectRoundTrip(payload: []const u8, channel: Channel, config: Config) !void {
    var frame_buf: [1024]u8 = undefined;
    const frame = try light.encodeFrame(payload, &frame_buf);

    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    const emitted = try emit(channel, frame, samples);
    try testing.expectEqual(samples.len, emitted.len);

    var rx_frame: [1024]u8 = undefined;
    var rx_payload: [1024]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, config);
    const got = (try receiver.receive(emitted)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, payload, got);
    try testing.expectEqual(@as(usize, 1), receiver.frames_accepted);
}

/// The largest value of `x` (bisected over `[x_lo, x_hi]`, either direction) at which `works(x)`
/// still holds. `x_lo` is known to work and `x_hi` known not to; the answer is deterministic, and
/// the tests that use it report it.
fn largestWorking(x_lo: f32, x_hi: f32, comptime works: fn (f32) bool) f32 {
    var lo = x_lo;
    var hi = x_hi;
    if (!works(lo)) return lo; // nothing works: report the bottom of the range
    var step: usize = 0;
    while (step < 40 and @abs(hi - lo) > 0.05) : (step += 1) {
        const mid = (lo + hi) / 2;
        if (works(mid)) lo = mid else hi = mid;
    }
    return lo;
}

test "the sender's chips are exactly light.modulate's waveform" {
    // The generator and the digital layer have to agree on the waveform, or nothing below means
    // anything. With a whole number of samples per symbol and a full-scale swing, the sender must
    // reproduce `light.modulate` sample for sample - that is the cross-check.
    var frame_buf: [64]u8 = undefined;
    const frame = try light.encodeFrame("cross-check", &frame_buf);

    const samples_per_symbol = 4;
    var reference: [light.sampleLength(64, 4)]u8 = undefined;
    const modulated = try light.modulate(frame, &reference, samples_per_symbol);

    const channel = Channel{
        .sample_rate_hz = 4000,
        .symbol_rate_hz = 1000, // 4 samples per symbol
        .ambient = 127.5,
        .swing = 255,
        .tail_symbols = 0, // exactly the frame's own samples, so the lengths must agree
    };
    try testing.expectEqual(modulated.len, sampleCount(channel, frame.len));
    var generated: [reference.len]u8 = undefined;
    const emitted = try emit(channel, frame, &generated);
    try testing.expectEqualSlices(u8, modulated, emitted);
    try testing.expectEqual(modulated.len, emitted.len);

    // The chip lookup agrees with the symbol array, chip by chip.
    var symbols: [light.symbolLength(64)]light.Symbol = undefined;
    const encoded = try light.encodeSymbols(frame, &symbols);
    for (encoded, 0..) |symbol, i| try testing.expectEqual(symbol, chipOf(frame, i));

    // The preamble pattern really is the preamble's own chips.
    for (0..32) |i| {
        const expected = chipOf(&light.preamble, i);
        const bit = (preamble_chips >> @intCast(31 - i)) & 1;
        try testing.expectEqual(@backingInt(expected), bit);
    }

    // The generator is deterministic and bounded, and says which bound it hit.
    var again: [reference.len]u8 = undefined;
    const repeated = try emit(channel, frame, &again);
    try testing.expectEqualSlices(u8, emitted, repeated);
    try testing.expectError(error.BufferTooSmall, emit(channel, frame, generated[0 .. emitted.len - 1]));
    try testing.expectError(error.InvalidEncoding, emit(.{ .symbol_rate_hz = 0 }, frame, &generated));
    try testing.expectEqual(@as(usize, 0), sampleCount(.{ .sample_rate_hz = 0 }, frame.len));
}

test "a real UR string round-trips byte for byte through the simulated channel" {
    // The round trip the whole layer exists for: a real UR string (the bc-ur reference message,
    // 259 bytes) as frame bytes, through a screen-and-sensor channel, back as the payload the UR
    // receiver would take. 4000 samples/s, 200 symbols/s.
    var message_buf: [259]u8 = undefined;
    const message = ur.makeUrMessage(&message_buf);
    var text_buf: [1024]u8 = undefined;
    const text = try ur.encodeSingleByteString(&text_buf, ur.type_bytes, message, .lower);
    try testing.expect(std.mem.startsWith(u8, text, "ur:bytes/"));

    const channel = cleanChannel();
    var frame_buf: [1024]u8 = undefined;
    const frame = try light.encodeFrame(text, &frame_buf);
    try testing.expectEqual(light.header_len + text.len + light.crc_len, frame.len);

    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    const emitted = try emit(channel, frame, samples);
    // The simulated rate is 20.0 samples per symbol exactly; the receiver is seeded with 20. The
    // stream is the frame plus the channel's idle tail, so the last symbol boundary is in it.
    try testing.expectEqual(@as(usize, light.symbolLength(frame.len) * 20 + 40), emitted.len);

    var rx_frame: [1024]u8 = undefined;
    var rx_payload: [1024]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    const got = (try receiver.receive(emitted)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, text, got);
    // Byte for byte, and still something the UR layer accepts: the next step of the pipeline.
    try testing.expectEqual(text.len, got.len);
    try testing.expect(ur.typeEql((try ur.parse(got)).ur_type, ur.type_bytes));

    // The clock was measured, not assumed: the estimate is the real rate.
    try testing.expectApproxEqAbs(@as(f32, 20), receiver.measuredSamplesPerSymbol(), 0.02);
    try testing.expect(receiver.edges > 0);
    try testing.expect(receiver.frames_rejected == 0);
}

test "each analog impairment on its own still round-trips" {
    // One at a time: 100 Hz and 120 Hz flicker, noise, drift, gain, and a symbol rate a few percent
    // off the seed. 4000 samples/s.
    const cases = [_]struct { name: []const u8, channel: Channel, config: Config }{
        .{ .name = "100 Hz flicker", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .flicker = .{ .{ .hz = 100, .amplitude = 22 }, .{} } }, .config = cleanConfig() },
        .{ .name = "120 Hz flicker", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .flicker = .{ .{ .hz = 120, .amplitude = 22 }, .{} } }, .config = cleanConfig() },
        .{ .name = "noise sigma 8", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .noise_sigma = 8 }, .config = cleanConfig() },
        .{ .name = "noise sigma 14", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .noise_sigma = 14 }, .config = cleanConfig() },
        .{ .name = "noise sigma 20", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .noise_sigma = 20 }, .config = cleanConfig() },
        .{ .name = "drifting ambient", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .drift = .{ .hz = 0.7, .amplitude = 35 } }, .config = cleanConfig() },
        .{ .name = "gain 0.6", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .gain = 0.6 }, .config = cleanConfig() },
        .{ .name = "gain 1.5", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .gain = 1.5 }, .config = cleanConfig() },
        .{ .name = "ambient 200 (bright room)", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .ambient = 200, .swing = 100 }, .config = cleanConfig() },
        // 200 * 1.04 = 208 symbols/s against a 20.0 samples/symbol seed (3.8% rate error).
        .{ .name = "rate +4%", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 208 }, .config = cleanConfig() },
        .{ .name = "rate -4%", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 192 }, .config = cleanConfig() },
        // A sampling phase that is not on a symbol boundary, and not a whole sample either.
        .{ .name = "phase offset 7.3 samples", .channel = .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .phase_samples = 7.3 }, .config = cleanConfig() },
    };

    for (cases) |case| {
        expectRoundTrip(test_ur, case.channel, case.config) catch |err| {
            std.debug.print("impairment case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "all impairments combined still round-trip" {
    // 100 Hz *and* 120 Hz flicker, noise, drift, gain, a phase offset and a symbol rate that is
    // 4.5% off the seed - the realistic bad case, not a clean one. 4000 samples/s.
    const channel = Channel{
        .sample_rate_hz = test_sample_rate_hz,
        .symbol_rate_hz = 209,
        .ambient = 118,
        .swing = 120,
        .gain = 1.2,
        .noise_sigma = 14,
        .flicker = .{ .{ .hz = 100, .amplitude = 18, .phase = 0.4 }, .{ .hz = 120, .amplitude = 18, .phase = 2.1 } },
        .drift = .{ .hz = 0.4, .amplitude = 25 },
        .phase_samples = 3.7,
        .seed = 0x0c0f_fee1,
    };
    // The seed is the nominal 20.0 samples/symbol: the channel is 209 symbols/s, i.e. 19.1.
    try expectRoundTrip(test_ur, channel, cleanConfig());

    // ...and the same on the other side of nominal, with the seed merely close.
    var mirrored = channel;
    mirrored.symbol_rate_hz = 191;
    mirrored.gain = 0.8;
    mirrored.ambient = 140;
    try expectRoundTrip(test_ur, mirrored, .{ .nominal_samples_per_symbol = 21 });
}

test "a gain change in mid-frame is followed, not remembered" {
    // A hand moving over the sensor: the swing changes half-way through the frame while the ambient
    // stays put. The tracker sees both levels of every symbol, so its reference is the middle of the
    // signal either way; a fixed threshold would lose the frame here. 4000 samples/s.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);

    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    _ = try emit(channel, frame, samples);

    const ambient = channel.ambient;
    for (samples[samples.len / 2 ..]) |*sample| {
        const scaled = ambient + (@as(f32, @floatFromInt(sample.*)) - ambient) * 0.55;
        sample.* = clampSample(scaled);
    }

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    const got = (try receiver.receive(samples)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, test_ur, got);
}

test "chunked feeding gives the same payload as one call" {
    // The receiver is a stream, not a block decoder: a caller that hands over 7 samples at a time
    // (an ADC interrupt, say) must get exactly the same frame. 4000 samples/s.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);

    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    _ = try emit(channel, frame, samples);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());

    var at: usize = 0;
    var answer: ?[]const u8 = null;
    while (at < samples.len) : (at += 7) {
        const chunk = samples[at..@min(at + 7, samples.len)];
        // Silence inside a frame is truncated, so "no frame yet" is null here, never NoSignal.
        if (try receiver.receive(chunk)) |payload| {
            answer = payload;
            break;
        }
    }
    const got = answer orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, test_ur, got);
}

test "silence, a lamp and noise are rejected, and the next good frame still arrives" {
    // 4000 samples/s. Three ways a channel can carry no frame, and then a real one right after:
    // rejection must not poison the receiver.
    const allocator = testing.allocator;
    const silence = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(silence);
    @memset(silence, 40);
    const lamp = try allocator.alloc(u8, 20 * 1024);
    defer allocator.free(lamp);
    @memset(lamp, 255);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;

    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    try testing.expectError(error.NoSignal, receiver.receive(silence));
    try testing.expectEqual(@as(usize, 0), receiver.frames_accepted);

    // A constant bright signal is the same non-event: a lamp over the sensor, already on when the
    // receiver starts. (Starting from a dark stream would make the lamp's own switch-on the one
    // transition in the chunk, which is a transition, not a frame.)
    var lamp_receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    try testing.expectError(error.NoSignal, lamp_receiver.receive(lamp));

    // Random noise for a long stretch: plenty of transitions, so not "no signal", but no preamble,
    // no length that fits and no CRC that matches - it must never produce a payload.
    var prng = std.Random.DefaultPrng.init(0xf00d_1234);
    const noise = try allocator.alloc(u8, 40 * 1024);
    defer allocator.free(noise);
    for (noise) |*sample| sample.* = prng.random().int(u8);
    const noisy = receiver.receive(noise) catch |err| {
        // A rejection here is acceptable (a chance preamble-sized pattern in the noise); it must
        // just be a real rejection, not a payload and not a crash.
        try testing.expect(err == error.TooLarge or err == error.ChecksumMismatch or
            err == error.UnsupportedVersion or err == error.InvalidSymbol or err == error.Truncated);
        return;
    };
    try testing.expect(noisy == null);
    try testing.expectEqual(@as(usize, 0), receiver.frames_accepted);

    // The good frame after all that still decodes: the clock was re-measured, not lost.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    _ = try emit(channel, frame, samples);
    try testing.expectEqualSlices(u8, test_ur, (try receiver.receive(samples)) orelse return error.TestUnexpectedResult);
}

test "a corrupt frame followed immediately by a good one yields the good payload" {
    // Both frames in one sample stream, fed in one call: the CRC rejects the first, and the second
    // must still be found - the receiver resynchronises on the next preamble by itself. 4000
    // samples/s.
    const channel = cleanChannel();
    var bad_buf: [512]u8 = undefined;
    var good_buf: [512]u8 = undefined;
    const bad = try light.encodeFrame("a payload that will be corrupted", &bad_buf);
    const good = try light.encodeFrame(test_ur, &good_buf);
    bad[light.header_len + 3] ^= 0xff; // still a well-formed frame: only the CRC can notice

    const allocator = testing.allocator;
    const bad_samples = try allocator.alloc(u8, sampleCount(channel, bad.len));
    defer allocator.free(bad_samples);
    const good_samples = try allocator.alloc(u8, sampleCount(channel, good.len));
    defer allocator.free(good_samples);
    _ = try emit(channel, bad, bad_samples);
    _ = try emit(channel, good, good_samples);

    const stream = try allocator.alloc(u8, bad_samples.len + good_samples.len);
    defer allocator.free(stream);
    @memcpy(stream[0..bad_samples.len], bad_samples);
    @memcpy(stream[bad_samples.len..], good_samples);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    const got = (try receiver.receive(stream)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, test_ur, got);
    try testing.expectEqual(@as(usize, 1), receiver.frames_accepted);
    // The rejected one was counted, not hidden: the caller can tell the user a frame was lost.
    try testing.expectEqual(@as(usize, 1), receiver.frames_rejected);

    // And when the corrupt frame is the last thing in the chunk, the rejection is the answer.
    var second = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    try testing.expectError(error.ChecksumMismatch, second.receive(bad_samples));
    try testing.expectEqual(@as(usize, 0), second.frames_accepted);
    try testing.expectEqual(@as(usize, 1), second.frames_rejected);
}

test "two frames in one stream are walked with samples_used" {
    // Back-to-back frames (a sender looping its screen) are not lost: the first call stops at the
    // end of the first frame and `samples_used` says where the second one starts. 4000 samples/s.
    const channel = cleanChannel();
    var first_buf: [512]u8 = undefined;
    var second_buf: [512]u8 = undefined;
    const first = try light.encodeFrame(test_ur, &first_buf);
    const second = try light.encodeFrame("the second frame", &second_buf);

    const allocator = testing.allocator;
    const first_samples = try allocator.alloc(u8, sampleCount(channel, first.len));
    defer allocator.free(first_samples);
    const second_samples = try allocator.alloc(u8, sampleCount(channel, second.len));
    defer allocator.free(second_samples);
    _ = try emit(channel, first, first_samples);
    _ = try emit(channel, second, second_samples);

    const stream = try allocator.alloc(u8, first_samples.len + second_samples.len);
    defer allocator.free(stream);
    @memcpy(stream[0..first_samples.len], first_samples);
    @memcpy(stream[first_samples.len..], second_samples);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    try testing.expectEqualSlices(
        u8,
        test_ur,
        (try receiver.receive(stream)) orelse return error.TestUnexpectedResult,
    );
    // The frame is delivered as soon as its last chip is decided, which is where the frame's own
    // samples end; the channel's idle tail is still unread, and it is exactly what the caller
    // re-feeds along with the second frame.
    try testing.expectEqual(light.symbolLength(first.len) * 20, receiver.samples_used);
    try testing.expect(receiver.samples_used <= first_samples.len);
    try testing.expectEqualSlices(
        u8,
        "the second frame",
        (try receiver.receive(stream[receiver.samples_used..])) orelse return error.TestUnexpectedResult,
    );
}

test "the caller's buffers are the bound, and a broken frame does not poison the receiver" {
    // A frame larger than `frame_buf` is TooLarge, and the next frame that does fit is still
    // received: the bound is the buffer, not a state the receiver gets stuck in.
    const channel = cleanChannel();
    var small_payload_buf: [16]u8 = undefined;
    var small_frame_buf: [32]u8 = undefined;
    var receiver = try Receiver.init(&small_frame_buf, &small_payload_buf, cleanConfig());

    var big_buf: [512]u8 = undefined;
    const big = try light.encodeFrame(test_ur, &big_buf); // 101 bytes of payload: over the 32-byte frame buffer
    const allocator = testing.allocator;
    const big_samples = try allocator.alloc(u8, sampleCount(channel, big.len));
    defer allocator.free(big_samples);
    _ = try emit(channel, big, big_samples);
    try testing.expectError(error.TooLarge, receiver.receive(big_samples));
    try testing.expect(!receiver.isInFrame());

    var small_sample_buf: [512]u8 = undefined;
    const small = try light.encodeFrame("fits", &small_sample_buf);
    const small_samples = try allocator.alloc(u8, sampleCount(channel, small.len));
    defer allocator.free(small_samples);
    _ = try emit(channel, small, small_samples);
    try testing.expectEqualSlices(u8, "fits", (try receiver.receive(small_samples)) orelse return error.TestUnexpectedResult);

    // A payload buffer that cannot hold the declared payload is the same kind of bound: the frame
    // fits the frame buffer, the payload does not fit its own.
    var roomy_frame: [512]u8 = undefined;
    var tight_payload: [8]u8 = undefined;
    var tight = try Receiver.init(&roomy_frame, &tight_payload, cleanConfig());
    var fits_buf: [512]u8 = undefined;
    const longer_than_eight = try light.encodeFrame("more than eight bytes", &fits_buf);
    const longer_samples = try allocator.alloc(u8, sampleCount(channel, longer_than_eight.len));
    defer allocator.free(longer_samples);
    _ = try emit(channel, longer_than_eight, longer_samples);
    try testing.expectError(error.TooLarge, tight.receive(longer_samples));

    // A receiver with nowhere to put even a nine-byte frame cannot be created.
    var none: [8]u8 = undefined;
    try testing.expectError(error.TooLarge, Receiver.init(&none, &none, cleanConfig()));
    try testing.expectError(error.InvalidEncoding, Receiver.init(&roomy_frame, &tight_payload, .{ .nominal_samples_per_symbol = 0 }));
}

test "a frame whose transitions stop is rejected, and the link recovers" {
    // The sender is switched off mid-frame (a hand over the sensor, a closed lid). The partial frame
    // is not an answer and not a hang: the frozen level makes two equal chips, which is not a
    // Manchester pair, so it is error.InvalidSymbol - and the next whole frame decodes. 4000
    // samples/s.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);
    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    _ = try emit(channel, frame, samples);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());

    // A little over half the frame, then a constant level.
    const half = samples.len / 2;
    var silence: [4096]u8 = undefined;
    @memset(&silence, 45);
    _ = receiver.receive(samples[0..half]) catch unreachable; // half a frame: not an error, just unfinished
    try testing.expect(receiver.isInFrame());
    try testing.expectError(error.InvalidSymbol, receiver.receive(&silence));
    try testing.expect(!receiver.isInFrame());

    // The next complete frame is received.
    try testing.expectEqualSlices(u8, test_ur, (try receiver.receive(samples)) orelse return error.TestUnexpectedResult);
}

test "an inverted channel is rejected, not decoded" {
    // A channel that swaps light and dark is the other Manchester convention, and `light.zig` is
    // explicit that the two are each other's inverse. It must never produce a payload: the inverted
    // chip pattern has no sync match at the right alignment, and the one it can match (two chips
    // later, i.e. a whole bit of slip) is caught by the version and CRC checks. 4000 samples/s.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);
    const allocator = testing.allocator;
    const samples = try allocator.alloc(u8, sampleCount(channel, frame.len));
    defer allocator.free(samples);
    _ = try emit(channel, frame, samples);
    for (samples) |*sample| sample.* = 255 - sample.*;

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    const got = receiver.receive(samples) catch |err| {
        // A rejection, not a decode: whichever check noticed the slip.
        try testing.expect(err == error.UnsupportedVersion or err == error.ChecksumMismatch or
            err == error.NoSignal or err == error.InvalidSymbol or err == error.TooLarge);
        try testing.expectEqual(@as(usize, 0), receiver.frames_accepted);
        return;
    };
    try testing.expect(got == null);
    try testing.expectEqual(@as(usize, 0), receiver.frames_accepted);
}

test "the measured limits: noise, flicker and rate error" {
    // The numbers the header quotes, measured here rather than claimed. Bisection on one channel
    // parameter at a time, fixed seeds, 4000 samples/s and 200 symbols/s nominal (20 samples per
    // symbol, which is what the receiver is seeded with).
    const swing = 110;
    const noise_limit = largestWorking(0, swing, struct {
        fn works(sigma: f32) bool {
            return roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .noise_sigma = sigma }, cleanConfig());
        }
    }.works);
    std.debug.print(
        "\nlight_rx measured limits (4000 samples/s, 200 symbols/s, swing {d}):\n" ++
            "  gaussian noise: sigma <= {d:.1} counts ({d:.0}% of the half-swing), fails at {d:.0}\n",
        .{ swing, noise_limit, 100 * noise_limit / (swing / 2), noise_limit * 2 },
    );
    try testing.expect(noise_limit >= swing / 8);
    try testing.expect(!roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 200, .noise_sigma = noise_limit * 2 }, cleanConfig()));

    // Flicker at 100 Hz and 120 Hz: the tracker removes its mean, the margin has to do the rest.
    const flicker_limit = largestWorking(0, swing, struct {
        fn works(amplitude: f32) bool {
            return roundTrips(test_ur, .{
                .sample_rate_hz = test_sample_rate_hz,
                .symbol_rate_hz = 200,
                .flicker = .{ .{ .hz = 100, .amplitude = amplitude }, .{ .hz = 120, .amplitude = amplitude } },
            }, cleanConfig());
        }
    }.works);
    std.debug.print(
        "  flicker (100 Hz + 120 Hz together): amplitude <= {d:.1} counts ({d:.0}% of the swing), fails at {d:.0}\n",
        .{ flicker_limit, 100 * flicker_limit / swing, flicker_limit * 1.7 },
    );
    try testing.expect(flicker_limit >= swing / 6);

    // Rate error, both sides. The seed stays at 20 samples per symbol; the sender is off.
    const fast_limit = largestWorking(200, 400, struct {
        fn works(symbol_rate: f32) bool {
            return roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = symbol_rate }, cleanConfig());
        }
    }.works);
    const slow_limit = largestWorking(200, 100, struct {
        fn works(symbol_rate: f32) bool {
            return roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = symbol_rate }, cleanConfig());
        }
    }.works);
    std.debug.print(
        "  symbol rate: {d:.0} to {d:.0} symbols/s around 200 ({d:.0}% / {d:.0}% offset), fails at {d:.0}% and {d:.0}%\n",
        .{
            slow_limit,
            fast_limit,
            100 * (fast_limit / 200 - 1),
            100 * (slow_limit / 200 - 1),
            100 * (1.25 * fast_limit / 200 - 1),
            100 * (1 - 0.75 * slow_limit / 200),
        },
    );
    // The "a few percent" the header promises, asserted with room to spare...
    try testing.expect(roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 206 }, cleanConfig()));
    try testing.expect(roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 194 }, cleanConfig()));
    // ...and clearly worse conditions really do fail, so nothing above is an overclaim.
    try testing.expect(!roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 320 }, cleanConfig()));
    try testing.expect(!roundTrips(test_ur, .{ .sample_rate_hz = test_sample_rate_hz, .symbol_rate_hz = 120 }, cleanConfig()));
    try testing.expect(fast_limit > 206 and slow_limit < 194);

    // The same frame at other sample rates and symbol rates: the loop measures the period, it does
    // not depend on the numbers this file happens to use. 8000 samples/s here.
    for ([_]struct { u32, f32 }{
        .{ 8000, 400 }, .{ 8000, 200 }, .{ 2000, 100 }, .{ 4000, 100 }, .{ 60000, 500 },
    }) |pair| {
        const rate: f32 = @floatFromInt(pair[0]);
        try expectRoundTrip(test_ur, .{ .sample_rate_hz = pair[0], .symbol_rate_hz = pair[1] }, .{
            .nominal_samples_per_symbol = @intFromFloat(rate / pair[1]),
        });
    }

    // A clean channel with no impairment at all is the ceiling, not the operating point: check the
    // receiver is not merely at the edge of everything above.
    try testing.expect(roundTrips(test_ur, cleanChannel(), cleanConfig()));
}

test "the seed only has to be close, and a wrong one is an error, not a wrong payload" {
    // The receiver is seeded, then measures. 4000 samples/s, 200 symbols/s: 20 samples per symbol.
    const channel = cleanChannel();
    try expectRoundTrip(test_ur, channel, .{ .nominal_samples_per_symbol = 18 });
    try expectRoundTrip(test_ur, channel, .{ .nominal_samples_per_symbol = 22 });

    // Measured, not assumed: a receiver seeded 5% off still ends up at the real period.
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);
    var samples: [128 * 1024]u8 = undefined;
    const emitted = try emit(channel, frame, &samples);
    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, .{ .nominal_samples_per_symbol = 21 });
    _ = (try receiver.receive(emitted)) orelse return error.TestUnexpectedResult;
    try testing.expectApproxEqAbs(@as(f32, 20), receiver.measuredSamplesPerSymbol(), 0.1);

    // A nominal rate that is nonsense is refused before any sample is seen.
    try testing.expectError(error.InvalidEncoding, Receiver.init(&rx_frame, &rx_payload, .{ .nominal_samples_per_symbol = 0 }));
    try testing.expectError(error.InvalidEncoding, Receiver.init(&rx_frame, &rx_payload, .{ .nominal_samples_per_symbol = 5000 }));
}

test "reset forgets the transfer but not the buffers" {
    // A new transfer starts from scratch: no half frame, no clock, no counters.
    const channel = cleanChannel();
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(test_ur, &frame_buf);
    var samples: [128 * 1024]u8 = undefined;
    const emitted = try emit(channel, frame, &samples);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try Receiver.init(&rx_frame, &rx_payload, cleanConfig());
    _ = receiver.receive(emitted[0 .. emitted.len / 2]) catch unreachable; // half a frame
    try testing.expect(receiver.isInFrame());
    receiver.reset();
    try testing.expect(!receiver.isInFrame());
    try testing.expectEqual(@as(u32, 0), receiver.edges);
    try testing.expectEqual(@as(usize, 0), receiver.frames_accepted);
    // The same samples now decode from the start, because nothing was remembered.
    try testing.expectEqualSlices(u8, test_ur, (try receiver.receive(emitted)) orelse return error.TestUnexpectedResult);
}
