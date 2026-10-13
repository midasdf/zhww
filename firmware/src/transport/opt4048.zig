//! OPT4048 wideband-light front end: I2C registers in, `light_rx` samples out.
//!
//! `light_rx.zig` takes unsigned bytes - 0 = dark, 255 = saturated - and recovers a Manchester clock
//! from them. Something has to watch a phone screen flicker and produce that byte stream, and on this
//! board it is an **Adafruit OPT4048** breakout on the Qwiic port: I2C address 0x44, four channels
//! X/Y/Z/W of which **W is the wideband one**, conversion time down to 600 us per channel, one cable
//! for the whole receiver. This module is the adapter, and nothing else:
//!
//!     light_rx byte  <-  mantissa >> 12  <-  W result registers  <-  I2C (a mockable vtable)
//!
//! It owns the register layout, the configuration and the mapping. The RP2350 I2C driver is a later
//! task and a different file: here the bus is two function pointers, so every test below runs on a PC
//! with a mock in the sensor's place and this module knows nothing about pins, boards or time.
//!
//! **The part** (TI OPT4048, datasheet SBOSA84, December 2022; section numbers below are its).
//! Registers are 16 bits, most significant byte first, and the read pointer auto-increments after
//! each register, so consecutive registers are one burst read (`I2C_BURST`, register 0x0B bit 0,
//! is 1 at reset - §8.3.4.7.2.2):
//!
//!     0x00/0x01 X   0x02/0x03 Y   0x04/0x05 Z   0x06/0x07 W   (the wideband channel)
//!     0x08/0x09 thresholds   0x0A CONFIG   0x0B threshold cfg   0x0C STATUS   0x11 DEVICE_ID
//!
//! Each channel's result is four bytes: 4 bits of `EXPONENT_CHx`, 20 bits of `MANTISSA_CHx` split
//! 12 + 8 over the two registers, then a 4-bit sample counter and a 4-bit CRC (§8.3.4.5, §8.3.3).
//! Within one full-scale range the mantissa is linear in light; the exponent names *which* range
//! (§8.3.4.5: "EXPONENT_CHx represents the current full-scale range selected"). The seven manual
//! ranges are 2254 lux to 144284 lux, each 2x the last (Table 8-3).
//!
//! **Configuration: one write, pinned, continuous.** `init` checks DEVICE_ID and writes the whole
//! CONFIG word (§8.4.1.11): QWAKE 0 (one-shot only), reserved bit 14 as 0, RANGE from `Config`
//! (never 0xC auto - the auto logic changes the full-scale range between conversions, and a gain
//! step in the middle of a frame is a level step the receiver's DC tracker would faithfully follow;
//! the light signal would be destroyed), CONVERSION_TIME 600 us by default (the fastest of the
//! twelve, Table 8-4), OPERATING_MODE 3 (continuous), and the interrupt fields at their reset values
//! (LATCH 1, INT_POL 0, FAULT_COUNT 1 count) because this module never touches the INT pin.
//!
//! Continuous mode, not one-shot, because the sample stream has to be *steady*: the device converts
//! all four channels in a round robin on its own, paced by CONVERSION_TIME, so the W register is
//! refreshed every 4 x 600 us = 2.4 ms like clockwork and the firmware's only job is to notice the
//! refresh. One-shot would add a configuration write per sample - a write that also clears the
//! ready flag - and would still take four conversion times for the four channels (§8.3.4.1: "every
//! trigger generates one measurement for 4 channels"), i.e. the same rate for more traffic on the
//! bus and a jitterier stream. Nothing here sleeps or waits: `init` returns as soon as the device is
//! configured and `read` reports `error.NotReady` until the first conversion has landed.
//!
//! **The mapping, and threshold headroom.** A reading becomes one byte as
//!
//!     sample = mantissa >> 12
//!
//! the top eight of the mantissa's twenty bits. Within the pinned range the mantissa is the light
//! level and its own full scale is the range's full scale (at range 0, 2^20 codes span 2254 lux, i.e.
//! 2.15e-3 lux per code - the coefficient the vendor driver publishes), so the byte is 1/256 of the
//! pinned range, monotonic in light, and needs no clamp: twenty bits shifted right by twelve cannot
//! exceed 255. The exponent does not enter the mapping - it is the range, not the brightness, and
//! with the range pinned it is a constant - so `read` refuses an exponent that is not the pinned
//! range (`error.Malformed`) instead of mapping a brightness it cannot place in the range.
//!
//! What that means for `light_rx`, whose default hysteresis is 12 counts on 0..255:
//! - One count is 1/256 of the pinned full scale: 8.8 lux at range 0, 17.6 at range 1, ... 563.6 at
//!   range 6 (Table 8-3). A screen that swings S lux peak-to-peak inside the pinned range swings
//!   S / full_scale x 256 counts, so the swing has to be a few times the hysteresis for the slicer
//!   to see two levels - and the range has to be pinned so the screen sits in the upper part of it
//!   without reaching the top, because at 255 the top of the swing flattens into a constant.
//! - 600 us is the least sensitive setting: Table 8-5 gives 9 effective mantissa bits at range 0 and
//!   600 us, so the byte only takes even values there (128 levels over the range) - still six
//!   hysteresis steps, and a slower conversion time buys resolution at a proportionally lower
//!   sample rate.
//! - The byte is monotonic, not calibrated: nothing here converts to lux, and two different pinned
//!   ranges give two different bytes for the same light. The receiver only ever needs the order.
//!
//! **Rate.** One sample is two I2C transactions: STATUS (address, register, address, two data bytes
//! = 5 bytes) and the four W result bytes (7 bytes), i.e. 12 bytes = 114 bit times including
//! address bytes, acknowledge bits and the (RE)START/STOP conditions. At 400 kHz that is 285 us per
//! sample, 3508 samples/s; at 1 MHz, 114 us and 8771 samples/s. The device is the slower half by an
//! order of magnitude: a W conversion every 2400 us is 416.67 samples/s, so a sustained stream is
//! ~416 samples/s at either bus speed and the bus is ~12% busy. At `light_rx`'s floor of four
//! samples per symbol that is ~104 symbols/s; the documented 30 symbols/s link needs 120 samples/s
//! and has 3.5x to spare. Note the receiver's seed follows from this: 30 symbols/s at 416 samples/s
//! is ~13.9 samples per symbol, nowhere near its default 100 - a caller that leaves the default in
//! place gets nothing at all (`light_rx` says so itself, and `rates` below is what to compute it
//! from).
//!
//! **Not handled (deliberate limits)**
//! - No timing, no retries, no timeouts: there is no delay in this file. `error.NotReady` means
//!   "come back later", and how long to wait is the caller's scheduler's business. A retry policy
//!   belongs there too - the receiver would rather see a sample late than the same sample twice.
//! - The 4-bit output CRC (§8.3.3.2, the equations in the 0x01/0x03/0x05/0x07 register
//!   descriptions) is not verified. The published sources disagree about it: the register map feeds
//!   the CRC field back into the X[1]/X[2] terms, which is self-referential, while the vendor's
//!   driver feeds the *counter* into those terms instead. A wrong guess here would reject every
//!   sample on real hardware, so this module leaves the nibble alone rather than gamble on it. What
//!   it does check is the exponent against the pinned range, which catches the failures that matter
//!   for this link (a device that re-ranged, or is not an OPT4048 at all); a corrupted mantissa is a
//!   wrong light level, and the frame's own CRC-32 is the end-to-end check.
//! - `OVERLOAD_FLAG` (§8.4.1.13) is not read: a light level above the pinned full scale has already
//!   flat-topped into 255, which is exactly what the slicer needs to know, and re-ranging in the
//!   middle of a transfer is the one thing that must not happen. Whether the mantissa saturates or
//!   wraps at overload is not in the register text we have - a bench item.
//! - The device ID is checked against `chip_id` = 0x0821, the value the vendor driver checks. The
//!   datasheet's register map gives the 0x11 reset value as 0x0820, one bit different; if a real part
//!   disagrees, this is the first constant to revisit.
//! - Burst mode is assumed as reset leaves it (`I2C_BURST` = 1). The four-byte W read depends on the
//!   read pointer auto-incrementing; something else clearing that bit would make the read return
//!   register 0x06 twice. This module is the only writer of the device's configuration.
//! - Only the W channel is read: X, Y and Z cost twelve more bytes per sample for data the light
//!   link does not use. No colour, no lux, no CIE, no thresholds, no interrupts, no power
//!   management, no FIFO: the sample counter says how many conversions the caller missed, it does
//!   not buffer them.
//! - Nothing here has run against real hardware. The register layout, the bit fields, the timings
//!   and the mapping are from the datasheet and the vendor driver, and are asserted by the mock
//!   tests - which prove the firmware's arithmetic, not the silicon.
//!
//! **No allocation.** `Sensor` is a bus handle, a configuration, a 4-bit counter and a missed-sample
//! count. The register reads go into two fixed arrays on the stack and are shifted into a byte.
//!
//! Reference: docs/09-light-audio-input.md §6, docs/03-hardware-bom.md (the Qwiic OPT4048 entry),
//!            TI OPT4048 datasheet SBOSA84 (December 2022)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");

// ---------------------------------------------------------------- the part

/// I2C address with the ADDR pin tied to GND, which is how the Adafruit breakout ships (§8.3.4.7.1.1:
/// GND 0x44, VDD 0x45, SDA 0x46, SCL 0x45).
pub const default_address: u8 = 0x44;

/// DEVICE_ID (0x11) of an OPT4048. The vendor driver checks this value; the datasheet's register map
/// lists the reset value as 0x0820 - see the limits above.
pub const chip_id: u16 = 0x0821;

/// Channels the device converts in a round robin: X, Y, Z, W.
pub const channel_count: u32 = 4;

/// The wideband result registers, the only channel this module reads (§8.4.1.7/§8.4.1.8: 0x06 is
/// RESULT_MSB_CH3 = EXPONENT_CH3 + MANTISSA[19:8], 0x07 is MANTISSA[7:0] + COUNTER + CRC).
const register_w_msb: u8 = 0x06;
/// DEVICE_ID register (§8.4.1.14).
const register_device_id: u8 = 0x11;
/// CONFIG register (§8.4.1.11): QWAKE, RANGE, CONVERSION_TIME, OPERATING_MODE, interrupt fields.
const register_config: u8 = 0x0A;
/// STATUS register (§8.4.1.13). Reading or writing 0x0A clears CONVERSION_READY_FLAG.
const register_status: u8 = 0x0C;

/// CONVERSION_READY_FLAG in STATUS: 1 when a conversion has completed (§8.4.1.13).
const conversion_ready_flag: u16 = 1 << 2;
/// OPERATING_MODE 3: continuous (§8.4.1.11).
const operating_mode_continuous: u2 = 3;
/// The interrupt fields' reset value: LATCH = 1 (§8.4.1.11). INT_POL and FAULT_COUNT reset to 0.
const latch_default: u1 = 1;
/// Bit positions in CONFIG (§8.4.1.11).
const range_shift: u4 = 10;
const conversion_time_shift: u4 = 6;
const mode_shift: u4 = 4;
const latch_shift: u4 = 3;

/// Full-scale light range, pinned manually. Auto-range (RANGE = 12) is deliberately not
/// representable: every conversion would be taken at a range the previous one chose, and the gain
/// step between two conversions would destroy the signal the receiver is decoding.
///
/// The nominal values in the names are the datasheet's; `fullScaleLux` is the typical level.
pub const Range = enum(u4) {
    lux_2k2 = 0,
    lux_4k5 = 1,
    lux_9k = 2,
    lux_18k = 3,
    lux_36k = 4,
    lux_72k = 5,
    lux_144k = 6,

    /// Typical full-scale light level of this range, in lux (Table 8-3).
    pub fn fullScaleLux(self: Range) u32 {
        return switch (self) {
            .lux_2k2 => 2254,
            .lux_4k5 => 4509,
            .lux_9k => 9018,
            .lux_18k => 18036,
            .lux_36k => 36071,
            .lux_72k => 72142,
            .lux_144k => 144284,
        };
    }
};

/// Conversion time per channel (Table 8-4). The device converts four channels, so a W sample is one
/// `microseconds` x 4.
pub const ConversionTime = enum(u4) {
    us_600 = 0,
    ms_1 = 1,
    ms_1_8 = 2,
    ms_3_4 = 3,
    ms_6_5 = 4,
    ms_12_7 = 5,
    ms_25 = 6,
    ms_50 = 7,
    ms_100 = 8,
    ms_200 = 9,
    ms_400 = 10,
    ms_800 = 11,

    /// Typical conversion time for one channel, in microseconds (Table 8-4).
    pub fn microseconds(self: ConversionTime) u32 {
        return switch (self) {
            .us_600 => 600,
            .ms_1 => 1000,
            .ms_1_8 => 1800,
            .ms_3_4 => 3400,
            .ms_6_5 => 6500,
            .ms_12_7 => 12700,
            .ms_25 => 25000,
            .ms_50 => 50000,
            .ms_100 => 100000,
            .ms_200 => 200000,
            .ms_400 => 400000,
            .ms_800 => 800000,
        };
    }
};

// ---------------------------------------------------------------- configuration

/// What the caller decides: where the device is and how wide and how fast it measures. The mode and
/// the interrupt fields are not here because they are not choices - `init` writes continuous mode and
/// the reset defaults.
pub const Config = struct {
    /// 7-bit I2C address. 0x44 with ADDR to GND, the breakout's default.
    address: u8 = default_address,
    /// The pinned full-scale range. The default is 4.5 klux: a 1000 cd/m2 screen close enough to fill
    /// the sensor's view is roughly pi x luminance, a few thousand lux, so 2.2 klux would clip at
    /// full brightness while the higher ranges only throw resolution away. Which one the enclosure
    /// and the light guide actually need is a bench measurement.
    range: Range = .lux_4k5,
    /// Conversion time per channel. 600 us is the operating point - the fastest, and the only reason
    /// this sensor can carry the light link; a slower one is a proportionally slower sample stream.
    conversion_time: ConversionTime = .us_600,
};

/// The CONFIG word (0x0A) for `config`, every field spelled out (§8.4.1.11). One known word rather
/// than a read-modify-write: the module owns all of it and no field is left to chance.
fn configWord(config: Config) u16 {
    return (@as(u16, @backingInt(config.range)) << range_shift) |
        (@as(u16, @backingInt(config.conversion_time)) << conversion_time_shift) |
        (@as(u16, operating_mode_continuous) << mode_shift) |
        (@as(u16, latch_default) << latch_shift);
}

// ---------------------------------------------------------------- the bus

/// The I2C bus this module talks to, as two function pointers and a context pointer.
///
/// The real RP2350 driver is a later task: this module only needs "write these bytes to this
/// register" and "read these bytes from this register", which is also exactly what a test can mock.
/// Both calls are one complete I2C transaction - START, the address with the write bit, the register,
/// then [RESTART, the address with the read bit] and the data bytes, then STOP - and both return how
/// many bytes actually moved, so a transfer that stopped early cannot pass unnoticed: a shortfall is
/// `error.ShortRead` whether the implementation counted it or the driver chose to report it.
pub const Bus = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Writes `data` to `register`, most significant byte first, and returns how many of the
        /// bytes were acknowledged (fewer is `error.ShortRead`).
        writeRegisters: *const fn (context: *anyopaque, address: u8, register: u8, data: []const u8) Error!usize,
        /// Reads `out.len` bytes from `register`, most significant byte first, and returns how many
        /// arrived (fewer is `error.ShortRead`).
        readRegisters: *const fn (context: *anyopaque, address: u8, register: u8, out: []u8) Error!usize,
    };
};

// ---------------------------------------------------------------- errors

/// Everything this module can report.
///
/// The bus's own errors are in here too - there is one error set for callers - but the states are
/// kept apart because they mean different things to the caller: `Nack` is "no device on the bus",
/// `WrongChipId` is "a device, but not an OPT4048", `ShortRead` is "the right device, half an answer",
/// `Malformed` is "an answer that is not a measurement of the pinned range", and `NotReady` is "no
/// new measurement yet", which is not a failure at all but the normal state between conversions.
pub const Error = error{
    /// The device did not acknowledge its address or a data byte, or the bus itself failed
    /// (arbitration lost, a stuck line). Nothing is written to a device that does not answer.
    Nack,
    /// A transfer moved fewer bytes than it was asked for. Distinct from `Nack`: the address was
    /// acknowledged and the answer is simply incomplete - and half a CONFIG register is a
    /// misconfigured device rather than an absent one.
    ShortRead,
    /// DEVICE_ID (0x11) is not `chip_id`: there is no OPT4048 at `address`. Nothing was configured.
    WrongChipId,
    /// A sample read whose exponent is not the pinned range: the mantissa then belongs to a range
    /// this module did not pin (auto-ranging still active, another part, or a corrupted read), and
    /// mapping it would silently return a brightness from the wrong scale.
    Malformed,
    /// No new conversion of the W channel is available: the ready flag is clear, or the channel's
    /// counter has not moved since the last accepted sample. The caller comes back later; the
    /// receiver must never be fed the same sample twice.
    NotReady,
};

// ---------------------------------------------------------------- the mapping

/// One W-channel result as the device reports it (§8.3.4.5).
pub const Reading = struct {
    /// The 20-bit linear result within the pinned range: RESULT_MSB[11:0] << 8 | RESULT_LSB[7:0].
    mantissa: u20,
    /// The 4-bit exponent: which full-scale range the mantissa belongs to, not how bright it is.
    exponent: u4,
    /// The channel's 4-bit sample counter, one step per conversion, wrapping at 16 (§8.3.3.1).
    counter: u4,
};

/// The byte `light_rx` gets from one reading: the top eight bits of the 20-bit mantissa.
///
/// Monotonic in light within the pinned range, 1/256 of that range per count, and exact - the shift
/// cannot leave 0..255. The exponent is deliberately ignored: it names the range, `read` has already
/// refused anything but the pinned one, and folding it in would make the byte depend on the device's
/// gain instead of the light.
pub fn byteFor(reading: Reading) u8 {
    return @intCast(reading.mantissa >> 12);
}

// ---------------------------------------------------------------- the sensor

/// A configured OPT4048: hand it a bus and a configuration, then take samples off it.
///
/// `read` is one sample if there is one, `sample` is that sample as the byte `light_rx` wants. The
/// only state is the W channel's last counter, so a caller that polls faster than the device converts
/// is told `error.NotReady` instead of being handed the same conversion again, and the sample the
/// receiver does get is always the newest one.
pub const Sensor = struct {
    bus: Bus,
    config: Config,
    /// The W channel's counter at the last accepted sample; null before the first one, so a device
    /// that has been converting since before `init` is not mistaken for a stale one.
    last_counter: ?u4 = null,
    /// Conversions of the W channel that happened while nobody was reading: the counter's step when
    /// it is greater than one. The sample returned is still the newest one - this is how the caller
    /// learns its stream had a hole in it (a hole the receiver's clock then has to survive).
    missed: u32 = 0,

    /// Checks who the device is and writes the one CONFIG word.
    ///
    /// `error.WrongChipId` before anything is written: a device that is not an OPT4048 must not be
    /// configured. The configuration write clears the ready flag (§8.4.1.13 - any non-zero write to
    /// 0x0A does), so the first `read` reports `error.NotReady` until the first conversion has
    /// completed: there is no delay here, the caller polls.
    pub fn init(bus: Bus, config: Config) Error!Sensor {
        const self = Sensor{ .bus = bus, .config = config };

        var id: [2]u8 = undefined;
        try self.readRegister(register_device_id, &id);
        if (std.mem.readInt(u16, &id, .big) != chip_id) return error.WrongChipId;

        try self.writeRegister(register_config, configWord(config));
        return self;
    }

    /// One fresh W-channel reading, or the reason there is none.
    ///
    /// The STATUS register says a conversion has completed at all - it is set by any channel and, in
    /// continuous mode, is only ever cleared by an access to 0x0A, so on its own it cannot tell a new
    /// sample from the same one. The channel's own counter is what does that: it steps once per
    /// conversion, so an unchanged counter means this reading is the previous one and is refused with
    /// `error.NotReady` rather than handed to the receiver twice.
    pub fn read(self: *Sensor) Error!Reading {
        var status: [2]u8 = undefined;
        try self.readRegister(register_status, &status);
        if (std.mem.readInt(u16, &status, .big) & conversion_ready_flag == 0) return error.NotReady;

        var result: [4]u8 = undefined;
        try self.readRegister(register_w_msb, &result);

        // RESULT_MSB_CH3: EXPONENT[3:0] then MANTISSA[19:8]; RESULT_LSB_CH3: MANTISSA[7:0],
        // COUNTER[3:0], CRC[3:0].
        const exponent: u4 = @truncate(result[0] >> 4);
        if (exponent != @backingInt(self.config.range)) return error.Malformed;

        const counter: u4 = @truncate(result[3] >> 4);
        if (self.last_counter) |previous| {
            const step = counter -% previous;
            if (step == 0) return error.NotReady;
            self.missed +|= step - 1;
        }
        self.last_counter = counter;

        return .{
            .mantissa = (@as(u20, result[0] & 0x0f) << 16) |
                (@as(u20, result[1]) << 8) |
                @as(u20, result[2]),
            .exponent = exponent,
            .counter = counter,
        };
    }

    /// The next sample for `light_rx`: one fresh conversion of the wideband channel, as a byte.
    pub fn sample(self: *Sensor) Error!u8 {
        return byteFor(try self.read());
    }

    /// Reads `out.len` bytes and insists on all of them.
    fn readRegister(self: *const Sensor, register: u8, out: []u8) Error!void {
        const moved = try self.bus.vtable.readRegisters(
            self.bus.context,
            self.config.address,
            register,
            out,
        );
        if (moved != out.len) return error.ShortRead;
    }

    /// Writes one 16-bit register, most significant byte first, and insists on both bytes.
    fn writeRegister(self: *const Sensor, register: u8, value: u16) Error!void {
        const bytes = [2]u8{ @truncate(value >> 8), @truncate(value) };
        const moved = try self.bus.vtable.writeRegisters(
            self.bus.context,
            self.config.address,
            register,
            &bytes,
        );
        if (moved != bytes.len) return error.ShortRead;
    }
};

// ---------------------------------------------------------------- the rates

/// Bytes one sample moves on the bus: five for the STATUS read (address, register, address, two data
/// bytes) and seven for the four W result bytes (address, register, address, four data bytes).
pub const bytes_per_sample: u32 = 12;
/// A byte on the wire is eight data bits plus the acknowledge bit.
pub const bits_per_byte: u32 = 9;
/// (RE)START and STOP conditions per sample: three per transaction, two transactions.
pub const framing_bits_per_sample: u32 = 6;
/// Bit times one sample costs, address bytes and framing included.
pub const bits_per_sample: u32 = bytes_per_sample * bits_per_byte + framing_bits_per_sample;

/// How long the device takes to refresh the W register: every channel is converted once per round
/// robin, so four conversion times (§8.3.4.4).
pub fn channelCycleUs(config: Config) u32 {
    return channel_count * config.conversion_time.microseconds();
}

/// Samples per second the device can produce on the W channel: 416 at 600 us per channel, where the
/// exact rate is 416.67 - the integer is what a caller can count on over any whole number of seconds.
pub fn sensorSampleRateHz(config: Config) u32 {
    return 1_000_000 / channelCycleUs(config);
}

/// Samples per second a bus of `bus_hz` can carry: 3508 at 400 kHz, 8771 at 1 MHz.
pub fn busSampleRateHz(bus_hz: u32) u32 {
    return bus_hz / bits_per_sample;
}

/// What a sustained stream can actually be, and which half is in the way.
pub const Rates = struct {
    /// Samples per second the bus can carry.
    bus_samples_per_second: u32,
    /// Samples per second the device produces.
    sensor_samples_per_second: u32,
    /// The smaller of the two. At 600 us this is the sensor at either bus speed, and `light_rx`'s
    /// floor of four samples per symbol turns it into ~104 symbols/s.
    samples_per_second: u32,
};

/// The rate arithmetic, in one place: `samples_per_second` is what sets the symbol rate the light
/// link can use (divide it by the samples per symbol the receiver is seeded with).
pub fn rates(config: Config, bus_hz: u32) Rates {
    const bus = busSampleRateHz(bus_hz);
    const sensor = sensorSampleRateHz(config);
    return .{
        .bus_samples_per_second = bus,
        .sensor_samples_per_second = sensor,
        .samples_per_second = @min(bus, sensor),
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const light = @import("light.zig");
const light_rx = @import("light_rx.zig");
const ur = @import("ur.zig");

/// The OPT4048 as the tests need it: a big-endian 16-bit register file, the two behaviours that
/// matter here (the sample counter and the ready flag) and a short log of what crossed the bus.
///
/// Faults are armed by register, one shot, so a test reads as "the identity read NACKs" rather than
/// "transaction number three fails".
const MockBus = struct {
    /// 16-bit registers, most significant byte first. 0x00..0x11 covers everything this module
    /// touches.
    registers: [0x12]u16 = @splat(0),
    /// The last few transactions, oldest first.
    log: [8]Transaction = undefined,
    log_len: usize = 0,
    /// Transactions since the mock was made, not capped by the log.
    transactions: u32 = 0,
    /// The next access to this register fails with `error.Nack`, then disarms.
    nack_register: ?u8 = null,
    /// The next access to this register moves one byte fewer than asked, then disarms.
    short_register: ?u8 = null,

    const Transaction = struct {
        write: bool,
        address: u8,
        register: u8,
        /// Bytes the caller asked for, whether or not they all moved.
        len: usize,
        data: [4]u8 = @splat(0),
    };

    fn init() MockBus {
        var mock = MockBus{};
        mock.registers[register_device_id] = chip_id;
        return mock;
    }

    /// The bus handle to hand to `Sensor.init`.
    fn bus(self: *MockBus) Bus {
        return .{ .context = self, .vtable = &vtable };
    }

    /// One completed conversion of the W channel: the counter steps, the result registers are
    /// written and the ready flag goes up - what §8.3.3.1 and §8.4.1.13 describe the device doing
    /// every 4 x CONVERSION_TIME.
    fn convert(self: *MockBus, mantissa: u20, exponent: u4) void {
        const previous: u4 = @truncate(self.registers[register_w_msb + 1] >> 4);
        const low: u8 = @truncate(mantissa);
        self.registers[register_w_msb] = (@as(u16, exponent) << 12) |
            (@as(u16, @truncate(mantissa >> 8)));
        self.registers[register_w_msb + 1] = (@as(u16, low) << 8) |
            (@as(u16, previous +% 1) << 4);
        self.registers[register_status] |= conversion_ready_flag;
    }

    fn fault(self: *MockBus, register: u8) Error!void {
        if (self.nack_register) |at| {
            if (at == register) {
                self.nack_register = null;
                return error.Nack;
            }
        }
    }

    fn readRegisters(context: *anyopaque, address: u8, register: u8, out: []u8) Error!usize {
        const self: *MockBus = @ptrCast(@alignCast(context));
        // The attempt is on the bus whether or not the device answers it.
        self.note(false, address, register, out.len, &.{});
        try self.fault(register);

        var count = out.len;
        if (self.short_register) |at| {
            if (at == register) {
                self.short_register = null;
                count -|= 1;
            }
        }

        var moved: usize = 0;
        while (moved < count) : (moved += 1) {
            const at = @as(usize, register) + moved / 2;
            if (at >= self.registers.len) break;
            out[moved] = if (moved % 2 == 0)
                @truncate(self.registers[at] >> 8)
            else
                @truncate(self.registers[at]);
        }

        // Reading 0x0A clears the ready flag just as writing it does (§8.4.1.13) - the reason a
        // streaming caller must leave CONFIG alone.
        if (register == register_config) self.registers[register_status] &= ~conversion_ready_flag;
        return moved;
    }

    fn writeRegisters(context: *anyopaque, address: u8, register: u8, data: []const u8) Error!usize {
        const self: *MockBus = @ptrCast(@alignCast(context));
        self.note(true, address, register, data.len, data);
        try self.fault(register);

        var count = data.len;
        if (self.short_register) |at| {
            if (at == register) {
                self.short_register = null;
                count -|= 1;
            }
        }

        var moved: usize = 0;
        while (moved < count) : (moved += 1) {
            const at = @as(usize, register) + moved / 2;
            if (at >= self.registers.len) break;
            self.registers[at] = if (moved % 2 == 0)
                (@as(u16, data[moved]) << 8) | (self.registers[at] & 0x00ff)
            else
                (self.registers[at] & 0xff00) | data[moved];
        }

        // Any non-zero write to CONFIG clears the ready flag (§8.4.1.13).
        if (register == register_config and moved == 2) {
            if (std.mem.readInt(u16, data[0..2], .big) != 0) {
                self.registers[register_status] &= ~conversion_ready_flag;
            }
        }
        return moved;
    }

    fn note(self: *MockBus, write: bool, address: u8, register: u8, requested: usize, data: []const u8) void {
        self.transactions += 1;
        if (self.log_len == self.log.len) {
            std.mem.copyForwards(Transaction, self.log[0 .. self.log.len - 1], self.log[1..]);
            self.log_len -= 1;
        }
        var entry = Transaction{
            .write = write,
            .address = address,
            .register = register,
            .len = requested,
        };
        const copied = @min(data.len, entry.data.len);
        @memcpy(entry.data[0..copied], data[0..copied]);
        self.log[self.log_len] = entry;
        self.log_len += 1;
    }

    const vtable = Bus.VTable{
        .writeRegisters = writeRegisters,
        .readRegisters = readRegisters,
    };
};

test "init checks who-am-i and writes one known CONFIG word" {
    // The two transactions of init, against the register map: DEVICE_ID (0x11, two bytes) first and
    // nothing else - a device that is not an OPT4048 is never configured - then CONFIG (0x0A, two
    // bytes, most significant first).
    var mock = MockBus.init();
    var sensor = try Sensor.init(mock.bus(), .{});

    try testing.expectEqual(@as(u8, 0x44), default_address);
    try testing.expectEqual(@as(usize, 2), mock.log_len);
    // Seven manual ranges and no auto (0xC): the type is the pinning.
    try testing.expectEqual(@as(usize, 7), @typeInfo(Range).@"enum".field_names.len);

    try testing.expect(!mock.log[0].write);
    try testing.expectEqual(default_address, mock.log[0].address);
    try testing.expectEqual(@as(u8, 0x11), mock.log[0].register);
    try testing.expectEqual(@as(usize, 2), mock.log[0].len);

    try testing.expect(mock.log[1].write);
    try testing.expectEqual(default_address, mock.log[1].address);
    try testing.expectEqual(@as(u8, 0x0A), mock.log[1].register);
    try testing.expectEqual(@as(usize, 2), mock.log[1].len);
    try testing.expectEqual(@as(u8, 0x04), mock.log[1].data[0]);
    try testing.expectEqual(@as(u8, 0x38), mock.log[1].data[1]);

    // Field by field (§8.4.1.11), not just the word: QWAKE 0 (one-shot only), the reserved bit 14 as
    // 0, RANGE 1 (4.5 klux), CONVERSION_TIME 0 (600 us per channel), OPERATING_MODE 3 (continuous),
    // LATCH 1, INT_POL 0 and FAULT_COUNT 1 count (their reset values).
    const word = mock.registers[register_config];
    try testing.expectEqual(@as(u16, 0x0438), word);
    try testing.expectEqual(@as(u1, 0), @as(u1, @truncate(word >> 15)));
    try testing.expectEqual(@as(u1, 0), @as(u1, @truncate(word >> 14)));
    try testing.expectEqual(@as(u4, 1), @as(u4, @truncate(word >> range_shift)));
    try testing.expectEqual(@as(u4, 0), @as(u4, @truncate(word >> conversion_time_shift)));
    try testing.expectEqual(@as(u2, 3), @as(u2, @truncate(word >> mode_shift)));
    try testing.expectEqual(@as(u1, 1), @as(u1, @truncate(word >> latch_shift)));
    try testing.expectEqual(@as(u1, 0), @as(u1, @truncate(word >> 2)));
    try testing.expectEqual(@as(u2, 0), @as(u2, @truncate(word)));

    // The configuration write cleared the ready flag, so there is no sample yet, and asking for one
    // costs exactly one status read - the W registers are not touched.
    try testing.expectError(error.NotReady, sensor.sample());
    try testing.expectEqual(@as(usize, 3), mock.transactions);
    try testing.expectEqual(@as(u8, 0x0C), mock.log[2].register);
}

test "every pinned range and conversion time lands in its own CONFIG field" {
    // The seven manual ranges and a few conversion times, as whole words. Auto-range (0xC) is not in
    // the enum at all - that is the point of the type.
    const cases = [_]struct { range: Range, time: ConversionTime, word: u16 }{
        .{ .range = .lux_2k2, .time = .us_600, .word = 0x0038 },
        .{ .range = .lux_4k5, .time = .us_600, .word = 0x0438 },
        .{ .range = .lux_9k, .time = .us_600, .word = 0x0838 },
        .{ .range = .lux_18k, .time = .us_600, .word = 0x0c38 },
        .{ .range = .lux_36k, .time = .us_600, .word = 0x1038 },
        .{ .range = .lux_72k, .time = .us_600, .word = 0x1438 },
        .{ .range = .lux_144k, .time = .us_600, .word = 0x1838 },
        .{ .range = .lux_2k2, .time = .ms_25, .word = 0x01b8 },
        .{ .range = .lux_144k, .time = .ms_800, .word = 0x1af8 },
    };

    for (cases) |case| {
        var mock = MockBus.init();
        _ = try Sensor.init(mock.bus(), .{ .range = case.range, .conversion_time = case.time });
        try testing.expectEqual(case.word, mock.registers[register_config]);
    }
}

test "a sample is a status read and a four-byte W burst read" {
    var mock = MockBus.init();
    var sensor = try Sensor.init(mock.bus(), .{});

    // The device converts; the caller reads. Two transactions: STATUS (0x0C) to know a conversion
    // happened, then the wideband channel's four bytes from RESULT_MSB_CH3 (0x06), one burst.
    mock.convert(0x54321, @backingInt(Range.lux_4k5));
    try testing.expectEqual(@as(u8, 0x54), try sensor.sample());

    try testing.expectEqual(@as(u8, 0x0C), mock.log[mock.log_len - 2].register);
    try testing.expect(!mock.log[mock.log_len - 2].write);
    try testing.expectEqual(@as(usize, 2), mock.log[mock.log_len - 2].len);
    try testing.expectEqual(@as(u8, 0x06), mock.log[mock.log_len - 1].register);
    try testing.expect(!mock.log[mock.log_len - 1].write);
    try testing.expectEqual(@as(usize, 4), mock.log[mock.log_len - 1].len);

    // The wideband channel is the one read, and only it: no X, Y or Z register is ever touched.
    var saw_other_channel = false;
    for (mock.log[0..mock.log_len]) |entry| {
        if (entry.register < register_w_msb) saw_other_channel = true;
    }
    try testing.expect(!saw_other_channel);
}

test "the counter refuses a duplicate sample and counts the ones the caller missed" {
    var mock = MockBus.init();
    var sensor = try Sensor.init(mock.bus(), .{});
    const pinned = @backingInt(Range.lux_4k5);

    mock.convert(0x10000, pinned);
    try testing.expectEqual(@as(u8, 0x10), try sensor.sample());

    // In continuous mode the ready flag stays up (only an access to 0x0A clears it), so the counter
    // is what protects the receiver from being fed the same conversion twice.
    try testing.expectError(error.NotReady, sensor.sample());
    try testing.expectEqual(@as(u32, 0), sensor.missed);

    // Two conversions while the caller was away: the newest sample is still the right answer, and
    // the hole is reported - the receiver's clock has to survive it, so the caller should know.
    mock.convert(0x18000, pinned);
    mock.convert(0x1c000, pinned);
    try testing.expectEqual(@as(u8, 0x1c), try sensor.sample());
    try testing.expectEqual(@as(u32, 1), sensor.missed);

    // Back to back with no gap: no more misses.
    mock.convert(0x20000, pinned);
    try testing.expectEqual(@as(u8, 0x20), try sensor.sample());
    try testing.expectEqual(@as(u32, 1), sensor.missed);
}

test "the mapping is monotonic, spans the pinned range and ignores the exponent" {
    // Sweep the whole 20-bit mantissa in steps of 4096 (the size of one byte count) plus both
    // neighbours of every step, and require the byte never to go backwards.
    var previous: u8 = 0;
    var mantissa: u32 = 0;
    while (mantissa < (1 << 20)) : (mantissa += 4096) {
        for ([_]u32{ mantissa -| 1, mantissa, @min(mantissa + 1, (1 << 20) - 1) }) |raw| {
            const byte = byteFor(.{ .mantissa = @intCast(raw), .exponent = 1, .counter = 0 });
            try testing.expect(byte >= previous);
            previous = byte;
        }
    }

    // The ends of the pinned range: 0 is dark, the mantissa's own full scale is saturated, and one
    // count is 4096 codes of the range - the byte is the top eight of twenty bits.
    const pinned = Range.lux_4k5;
    try testing.expectEqual(@as(u8, 0), byteFor(.{ .mantissa = 0, .exponent = 1, .counter = 0 }));
    try testing.expectEqual(@as(u8, 0), byteFor(.{ .mantissa = 0xfff, .exponent = 1, .counter = 0 }));
    try testing.expectEqual(@as(u8, 1), byteFor(.{ .mantissa = 0x1000, .exponent = 1, .counter = 0 }));
    try testing.expectEqual(@as(u8, 128), byteFor(.{ .mantissa = 0x80000, .exponent = 1, .counter = 0 }));
    try testing.expectEqual(@as(u8, 255), byteFor(.{ .mantissa = 0xfffff, .exponent = 1, .counter = 0 }));
    try testing.expectEqual(@as(u32, 4509), pinned.fullScaleLux());
    try testing.expectEqual(@as(u32, 17), pinned.fullScaleLux() / 256); // ~17.6 lux per count

    // The exponent names the range, not the brightness: the same mantissa is the same byte in every
    // range, which is why `read` insists the exponent is the pinned one instead of folding it in.
    for (0..16) |exponent| {
        try testing.expectEqual(
            @as(u8, 128),
            byteFor(.{ .mantissa = 0x80000, .exponent = @intCast(exponent), .counter = 0 }),
        );
    }

    // The datasheet's full-scale table (Table 8-3) and the resolution table (Table 8-5, 600 us at
    // range 0: 9 effective mantissa bits, i.e. 4.4 lux per mantissa step, so the byte steps by two).
    const scales = [_]struct { range: Range, lux: u32 }{
        .{ .range = .lux_2k2, .lux = 2254 },
        .{ .range = .lux_4k5, .lux = 4509 },
        .{ .range = .lux_9k, .lux = 9018 },
        .{ .range = .lux_18k, .lux = 18036 },
        .{ .range = .lux_36k, .lux = 36071 },
        .{ .range = .lux_72k, .lux = 72142 },
        .{ .range = .lux_144k, .lux = 144284 },
    };
    for (scales) |scale| try testing.expectEqual(scale.lux, scale.range.fullScaleLux());
    // Table 8-5 at 600 us: range 0 resolves 4.4 lux, i.e. 2254 / 2^9 effective mantissa codes.
    try testing.expectEqual(@as(u32, 4), Range.lux_2k2.fullScaleLux() / 512);
}

test "nack, a wrong id, a short transfer, a re-ranged read and no conversion are told apart" {
    // A NACK on the identity read: no device, so nothing is configured - one transaction, no write.
    var silent = MockBus.init();
    silent.nack_register = register_device_id;
    try testing.expectError(error.Nack, Sensor.init(silent.bus(), .{}));
    try testing.expectEqual(@as(u32, 1), silent.transactions);

    // A device that answers but is not an OPT4048. 0x0820 is the reset value in the datasheet's
    // register map, which is exactly the kind of thing a who-am-i check is for.
    var stranger = MockBus.init();
    stranger.registers[register_device_id] = 0x0820;
    try testing.expectError(error.WrongChipId, Sensor.init(stranger.bus(), .{}));
    try testing.expectEqual(@as(u32, 1), stranger.transactions);

    // The configuration write itself can NACK or come up short: half a CONFIG word is a
    // misconfigured device, not an absent one.
    var no_config = MockBus.init();
    no_config.nack_register = register_config;
    try testing.expectError(error.Nack, Sensor.init(no_config.bus(), .{}));

    var half_id = MockBus.init();
    half_id.short_register = register_device_id;
    try testing.expectError(error.ShortRead, Sensor.init(half_id.bus(), .{}));

    var half_config = MockBus.init();
    half_config.short_register = register_config;
    try testing.expectError(error.ShortRead, Sensor.init(half_config.bus(), .{}));

    // The same on a sample: a short status read, a NACK on the status read, and a short four-byte W
    // burst (three of four bytes is not a reading).
    var mock = MockBus.init();
    var sensor = try Sensor.init(mock.bus(), .{});
    const pinned = @backingInt(Range.lux_4k5);
    mock.convert(0x12345, pinned);

    mock.short_register = register_status;
    try testing.expectError(error.ShortRead, sensor.sample());

    mock.nack_register = register_status;
    try testing.expectError(error.Nack, sensor.sample());

    mock.short_register = register_w_msb;
    try testing.expectError(error.ShortRead, sensor.sample());

    mock.nack_register = register_w_msb;
    try testing.expectError(error.Nack, sensor.sample());

    // An exponent that is not the pinned range: the mantissa is a brightness on another full scale,
    // and mapping it would be a plausible lie. The datasheet's exponents are the range numbers.
    mock.convert(0x12345, 2);
    try testing.expectError(error.Malformed, sensor.sample());

    // ...and with that range pinned instead, the same register contents are a sample: what makes a
    // read malformed is the disagreement, not the exponent.
    var other = MockBus.init();
    var ranged = try Sensor.init(other.bus(), .{ .range = .lux_9k });
    other.convert(0x30000, 2);
    try testing.expectEqual(@as(u8, 0x30), try ranged.sample());

    // The conversion has not happened yet: the ready flag is clear.
    var fresh = MockBus.init();
    var waiting = try Sensor.init(fresh.bus(), .{});
    try testing.expectError(error.NotReady, waiting.sample());

    // And nothing above poisoned the sensor: the good sample after all of it still arrives.
    mock.convert(0x23456, pinned);
    try testing.expectEqual(@as(u8, 0x23), try sensor.sample());
}

test "the rate arithmetic: 12 bytes a sample, the sensor as the limit" {
    const config = Config{};
    try testing.expectEqual(@as(u32, 12), bytes_per_sample);
    try testing.expectEqual(@as(u32, 114), bits_per_sample);

    // The bus, per sample: 12 bytes x (8 data bits + 1 acknowledge) plus the six (RE)START/STOP
    // conditions of the two transactions.
    try testing.expectEqual(@as(u32, 3508), busSampleRateHz(400_000));
    try testing.expectEqual(@as(u32, 8771), busSampleRateHz(1_000_000));

    // The device: one W conversion per 4 x 600 us, i.e. 2.4 ms, exactly 416.67 samples/s.
    try testing.expectEqual(@as(u32, 2400), channelCycleUs(config));
    try testing.expectEqual(@as(u32, 416), sensorSampleRateHz(config));

    const at_400k = rates(config, 400_000);
    const at_1m = rates(config, 1_000_000);
    try testing.expectEqual(@as(u32, 416), at_400k.samples_per_second);
    try testing.expectEqual(@as(u32, 416), at_1m.samples_per_second);
    // Either bus speed leaves the sensor as the limit - by 8x at 400 kHz.
    try testing.expect(at_400k.bus_samples_per_second > at_400k.sensor_samples_per_second);
    try testing.expect(at_1m.bus_samples_per_second > at_400k.bus_samples_per_second);

    // What that supports. The receiver's floor is four samples per symbol, so ~104 symbols/s; the
    // documented 30 symbols/s link wants 120 samples/s and has 3.5x to spare, and its seed is
    // samples / symbols = 13, not the receiver's default 100.
    try testing.expectEqual(@as(u32, 104), at_400k.samples_per_second / 4);
    try testing.expect(at_400k.samples_per_second >= 4 * 30);
    try testing.expectEqual(@as(u32, 13), at_400k.samples_per_second / 30);

    // A slower conversion time is a proportionally slower stream and nothing else.
    const slow = Config{ .conversion_time = .ms_1 };
    try testing.expectEqual(@as(u32, 250), sensorSampleRateHz(slow));
    try testing.expectEqual(@as(u32, 250), rates(slow, 400_000).samples_per_second);

    std.debug.print(
        "\nopt4048 rates (600 us per channel, four channels, 12 bytes per sample):\n" ++
            "  bus: {d} samples/s at 400 kHz, {d} samples/s at 1 MHz\n" ++
            "  sensor: {d} samples/s (exactly 416.67), so a sustained stream is {d} samples/s\n" ++
            "  {d} symbols/s at the receiver's floor of 4 samples/symbol; 30 symbols/s needs 120\n",
        .{
            at_400k.bus_samples_per_second,
            at_1m.bus_samples_per_second,
            at_400k.sensor_samples_per_second,
            at_400k.samples_per_second,
            at_400k.samples_per_second / 4,
        },
    );
}

test "a flickering screen read through the W registers decodes as a real UR frame" {
    // The test that proves the adapter fits the receiver. A channel at 400 samples/s and 30
    // symbols/s - the operating point the rate arithmetic documents, 13.33 samples per symbol
    // against the receiver's floor of four - flashes the bc-ur reference part that `light_rx`'s own
    // end-to-end test uses. Each light level goes into the mock as the mantissa a real OPT4048 would
    // report for it in the pinned range (the inverse of the mapping under test), comes out of
    // `sample` as a byte, and is fed to the receiver one byte at a time, as the firmware would.
    const channel = light_rx.Channel{ .sample_rate_hz = 400, .symbol_rate_hz = 30 };
    var frame_buf: [512]u8 = undefined;
    const frame = try light.encodeFrame(ur.expected_parts[0], &frame_buf);

    var samples: [24 * 1024]u8 = undefined;
    const emitted = try light_rx.emit(channel, frame, &samples);
    // The reference part is 105 payload bytes: a 114-byte frame, 1824 symbols, and at 13.33 samples
    // per symbol plus the channel's two-symbol tail that is 24347 samples. The tail is not padding
    // for the receiver's convenience - the frame's last chip only exists once its symbol boundary
    // has arrived.
    try testing.expectEqual(@as(usize, 24_347), emitted.len);

    var mock = MockBus.init();
    var sensor = try Sensor.init(mock.bus(), .{});
    const pinned = @backingInt(Range.lux_4k5);

    var rx_frame: [512]u8 = undefined;
    var rx_payload: [512]u8 = undefined;
    var receiver = try light_rx.Receiver.init(&rx_frame, &rx_payload, .{ .nominal_samples_per_symbol = 13 });

    var decoded: ?[]const u8 = null;
    for (emitted) |level| {
        mock.convert(@as(u20, level) << 12, pinned);
        const byte = try sensor.sample();
        // Byte for byte what the channel showed: the mapping has to be lossless at this scale, or
        // the receiver is not looking at the same waveform the sender drew.
        try testing.expectEqual(level, byte);
        if (try receiver.receive(&[1]u8{byte})) |payload| {
            decoded = payload;
            break;
        }
    }

    try testing.expectEqualSlices(u8, ur.expected_parts[0], decoded orelse return error.TestUnexpectedResult);
    try testing.expectEqual(@as(u32, 1), receiver.frames_accepted);
    try testing.expectEqual(@as(u32, 0), receiver.frames_rejected);
    // The stream had no holes: the receiver saw every conversion the device made.
    try testing.expectEqual(@as(u32, 0), sensor.missed);
}
