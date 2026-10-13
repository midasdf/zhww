//! Policy for status indication (LED and screen backlight).
//!
//! **Why put a "policy" in code**: whether the board LED can be controlled over GPIO is still
//! undecided while we wait for the board schematic (the RP2350-PiZero has a "Power LED", but it is
//! likely wired straight to the power rail). How each state should light up, on the other hand, does
//! not depend on the hardware, so deciding it up front in a testable form means that once the board
//! arrives, all that is left is connecting the GPIO.
//!
//! **Power consumption matters because it runs on dry cells**: idle is limited to "a brief flash now
//! and then", and the average duty cycle is kept to a few percent or less (so that the average blinking
//! current can be computed, the patterns are expressed as a sequence of on/off states and durations).
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// State of the device.
pub const State = enum {
    /// Idle (screen off; a heartbeat-like flash now and then)
    idle,
    /// Busy (computing a signature, for example)
    busy,
    /// Waiting for the user to confirm (the details are shown on screen)
    confirm,
    /// Error (the reason is shown on screen). Named failure because `error` is a Zig keyword
    failure,
    /// Battery expected to be low (an estimate, not a measurement)
    battery_low,
};

/// One step of a blink pattern.
pub const Step = struct {
    on: bool,
    ms: u32,
};

/// One full period of a pattern.
pub const Pattern = struct {
    steps: []const Step,

    /// Period length (milliseconds).
    pub fn periodMs(self: Pattern) u32 {
        var total: u32 = 0;
        for (self.steps) |step| total += step.ms;
        return total;
    }

    /// Total time lit (milliseconds).
    pub fn onMs(self: Pattern) u32 {
        var total: u32 = 0;
        for (self.steps) |step| {
            if (step.on) total += step.ms;
        }
        return total;
    }

    /// Average duty cycle (%). Used to evaluate battery life.
    pub fn dutyPercent(self: Pattern) u32 {
        const period = self.periodMs();
        if (period == 0) return 0;
        return self.onMs() * 100 / period;
    }

    /// Whether it is lit at `elapsed_ms`.
    pub fn isOnAt(self: Pattern, elapsed_ms: u64) bool {
        const period = self.periodMs();
        if (period == 0) return false;
        var position: u32 = @intCast(elapsed_ms % period);
        for (self.steps) |step| {
            if (position < step.ms) return step.on;
            position -= step.ms;
        }
        return false;
    }
};

// Idle: lights for 20ms every 3 seconds (heartbeat). Average duty cycle below 0.7%.
const idle_steps = [_]Step{
    .{ .on = true, .ms = 20 },
    .{ .on = false, .ms = 2980 },
};

// Busy: stays lit (the user is watching).
const busy_steps = [_]Step{
    .{ .on = true, .ms = 1000 },
    .{ .on = false, .ms = 0 },
};

// Confirming: slow blink (a cue to look at the screen).
const confirm_steps = [_]Step{
    .{ .on = true, .ms = 400 },
    .{ .on = false, .ms = 600 },
};

// Error: fast blink.
const error_steps = [_]Step{
    .{ .on = true, .ms = 100 },
    .{ .on = false, .ms = 100 },
};

// Battery low: two flashes then a long off period (distinguishable from the idle heartbeat).
const battery_low_steps = [_]Step{
    .{ .on = true, .ms = 60 },
    .{ .on = false, .ms = 140 },
    .{ .on = true, .ms = 60 },
    .{ .on = false, .ms = 3740 },
};

/// The blink pattern for a state.
pub fn patternFor(state: State) Pattern {
    return switch (state) {
        .idle => .{ .steps = &idle_steps },
        .busy => .{ .steps = &busy_steps },
        .confirm => .{ .steps = &confirm_steps },
        .failure => .{ .steps = &error_steps },
        .battery_low => .{ .steps = &battery_low_steps },
    };
}

/// Whether to turn the screen backlight on.
///
/// **Turned off while idle** (the backlight draws the most power).
pub fn backlightOn(state: State) bool {
    return state != .idle;
}

/// Human-readable label for a state (for on-screen display; an ASCII-only screen uses Latin letters).
pub fn label(state: State) []const u8 {
    return switch (state) {
        .idle => "STAND BY",
        .busy => "WORKING",
        .confirm => "CONFIRM",
        .failure => "ERROR",
        .battery_low => "BATTERY LOW",
    };
}

/// Returns whether anything needs to light up when the state changes.
///
/// Lighting up only right after a state change lowers the average consumption while idle even further.
pub fn shouldPulseOnChange(previous: State, next: State) bool {
    if (previous == next) return false;
    return next == .battery_low or next == .failure;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "idle has a very low duty cycle (battery life comes first)" {
    const pattern = patternFor(.idle);
    try testing.expect(pattern.dutyPercent() <= 1);
    try testing.expect(pattern.isOnAt(0));
    try testing.expect(!pattern.isOnAt(20));
    try testing.expect(!pattern.isOnAt(1500));
    // It lights again after 3 seconds
    try testing.expect(pattern.isOnAt(3000));
}

test "busy does not go out and confirming blinks slowly" {
    const busy = patternFor(.busy);
    try testing.expectEqual(@as(u32, 100), busy.dutyPercent());
    try testing.expect(busy.isOnAt(0));
    try testing.expect(busy.isOnAt(999));

    const confirm = patternFor(.confirm);
    try testing.expect(confirm.isOnAt(0));
    try testing.expect(!confirm.isOnAt(400));
    try testing.expect(confirm.isOnAt(1000));
    try testing.expectEqual(@as(u32, 40), confirm.dutyPercent());
}

test "error blinks fast and battery low is distinguishable from idle" {
    const error_pattern = patternFor(.failure);
    try testing.expect(error_pattern.isOnAt(0));
    try testing.expect(!error_pattern.isOnAt(100));
    try testing.expect(error_pattern.isOnAt(200));

    const low = patternFor(.battery_low);
    // Two flashes, then a long off period
    try testing.expect(low.isOnAt(0));
    try testing.expect(!low.isOnAt(60));
    try testing.expect(low.isOnAt(200));
    try testing.expect(!low.isOnAt(260));
    try testing.expect(!low.isOnAt(2000));
    try testing.expect(low.isOnAt(4000));
    // More noticeable than idle (0.7%) but not lit continuously
    try testing.expect(low.dutyPercent() < 10);
}

test "the backlight is off only while idle" {
    try testing.expect(!backlightOn(.idle));
    try testing.expect(backlightOn(.busy));
    try testing.expect(backlightOn(.confirm));
    try testing.expect(backlightOn(.failure));
    try testing.expect(backlightOn(.battery_low));
}

test "it signals only when the state changes" {
    try testing.expect(!shouldPulseOnChange(.idle, .idle));
    try testing.expect(!shouldPulseOnChange(.idle, .confirm));
    try testing.expect(shouldPulseOnChange(.confirm, .failure));
    try testing.expect(shouldPulseOnChange(.confirm, .battery_low));
}

test "a pattern with period 0 does not crash" {
    const empty = Pattern{ .steps = &.{} };
    try testing.expectEqual(@as(u32, 0), empty.periodMs());
    try testing.expectEqual(@as(u32, 0), empty.dutyPercent());
    try testing.expect(!empty.isOnAt(1234));
}
