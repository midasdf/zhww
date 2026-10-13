//! Driver for the ST7789 (240x240 IPS LCD).
//!
//! The controller mounted on Waveshare's 1.3inch LCD HAT (SKU:14972).
//!
//! **Design**: the actual wiring (SPI, DC, CS, RST, backlight) is passed in from outside as a `Transport`.
//! That way the command sequence can be verified with a **mock transport** even without the real board.
//! The RP2350-side implementation lives in `platform/rp2350/`.
//!
//! The initialization sequence uses the values commonly used for 240x240 ST7789 panels.
//! **Panel-specific tuning may be needed on the real device** (porching and gamma).
//! If the display is disturbed, check the settings one by one following [docs/08-rp2350-pizero.md].
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const framebuffer = @import("framebuffer.zig");

pub const width = 240;
pub const height = 240;

// Commands (ST7789 datasheet)
pub const cmd_swreset: u8 = 0x01;
pub const cmd_slpin: u8 = 0x10;
pub const cmd_slpout: u8 = 0x11;
pub const cmd_noron: u8 = 0x13;
pub const cmd_invoff: u8 = 0x20;
pub const cmd_invon: u8 = 0x21;
pub const cmd_dispoff: u8 = 0x28;
pub const cmd_dispon: u8 = 0x29;
pub const cmd_caset: u8 = 0x2A;
pub const cmd_raset: u8 = 0x2B;
pub const cmd_ramwr: u8 = 0x2C;
pub const cmd_madctl: u8 = 0x36;
pub const cmd_colmod: u8 = 0x3A;
pub const cmd_porctrl: u8 = 0xB2;
pub const cmd_gctrl: u8 = 0xB7;
pub const cmd_vcoms: u8 = 0xBB;
pub const cmd_lcmctrl: u8 = 0xC0;
pub const cmd_vdvvrhen: u8 = 0xC2;
pub const cmd_vrhs: u8 = 0xC3;
pub const cmd_vdvs: u8 = 0xC4;
pub const cmd_frctrl2: u8 = 0xC6;
pub const cmd_pwctrl1: u8 = 0xD0;
pub const cmd_pvgamctrl: u8 = 0xE0;
pub const cmd_nvgamctrl: u8 = 0xE1;

/// Screen orientation.
pub const Rotation = enum(u8) {
    /// 0 degrees (origin at the top left)
    deg0 = 0x00,
    /// 90 degrees
    deg90 = 0x60,
    /// 180 degrees
    deg180 = 0xC0,
    /// 270 degrees
    deg270 = 0xA0,
};

/// Transport layer. SPI and the control pins grouped together.
///
/// Functions the implementation must provide:
/// - `writeAll(bytes)`: send over SPI
/// - `setDataMode(is_data)`: DC pin (false = command, true = data)
/// - `setChipSelect(selected)`: CS pin
/// - `setReset(high)`: RST pin
/// - `setBacklight(on)`: backlight
/// - `delayMs(ms)`: wait
pub fn Driver(comptime Transport: type) type {
    return struct {
        transport: Transport,
        x_offset: u16 = 0,
        y_offset: u16 = 0,

        const Self = @This();

        /// Initializes the display.
        pub fn init(self: *Self) !void {
            self.transport.setChipSelect(true);
            self.transport.setDataMode(true);

            // Hardware reset
            self.transport.setReset(false);
            self.transport.delayMs(10);
            self.transport.setReset(true);
            self.transport.delayMs(120);

            try self.command(cmd_swreset, &.{});
            self.transport.delayMs(150);

            try self.command(cmd_slpout, &.{});
            self.transport.delayMs(120);

            // Color order and frame rate
            try self.command(cmd_colmod, &[_]u8{0x55}); // 16bit/pixel (RGB565)
            try self.command(cmd_madctl, &[_]u8{0x00});

            // Porching, power and gamma (values commonly used for 240x240)
            try self.command(cmd_porctrl, &[_]u8{ 0x0C, 0x0C, 0x00, 0x33, 0x33 });
            try self.command(cmd_gctrl, &[_]u8{0x35});
            try self.command(cmd_vcoms, &[_]u8{0x19});
            try self.command(cmd_lcmctrl, &[_]u8{0x2C});
            try self.command(cmd_vdvvrhen, &[_]u8{0x01});
            try self.command(cmd_vrhs, &[_]u8{0x12});
            try self.command(cmd_vdvs, &[_]u8{0x20});
            try self.command(cmd_frctrl2, &[_]u8{0x0F});
            try self.command(cmd_pwctrl1, &[_]u8{ 0xA4, 0xA1 });
            try self.command(cmd_pvgamctrl, &[_]u8{
                0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F, 0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23,
            });
            try self.command(cmd_nvgamctrl, &[_]u8{
                0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F, 0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23,
            });

            try self.command(cmd_invon, &.{});
            try self.command(cmd_noron, &.{});
            try self.command(cmd_dispon, &.{});
            self.transport.delayMs(20);

            self.transport.setBacklight(true);
        }

        /// Changes the screen orientation (the display window is switched as well).
        pub fn setRotation(self: *Self, rotation: Rotation) !void {
            const value: u8 = switch (rotation) {
                .deg0 => 0x00,
                .deg90 => 0x60,
                .deg180 => 0xC0,
                .deg270 => 0xA0,
            };
            try self.command(cmd_madctl, &[_]u8{value});

            // 240x240, so the offset is 0 even at 90/270 degrees
            self.x_offset = 0;
            self.y_offset = 0;
        }

        /// Sets the drawing window (both ends inclusive).
        pub fn setWindow(self: *Self, x0: u16, y0: u16, x1: u16, y1: u16) !void {
            if (x1 >= width or y1 >= height) return error.InvalidEncoding;
            if (x0 > x1 or y0 > y1) return error.InvalidEncoding;

            const xs: u16 = x0 + self.x_offset;
            const xe: u16 = x1 + self.x_offset;
            const ys: u16 = y0 + self.y_offset;
            const ye: u16 = y1 + self.y_offset;

            try self.command(cmd_caset, &[_]u8{
                @intCast(xs >> 8), @intCast(xs & 0xFF),
                @intCast(xe >> 8), @intCast(xe & 0xFF),
            });
            try self.command(cmd_raset, &[_]u8{
                @intCast(ys >> 8), @intCast(ys & 0xFF),
                @intCast(ye >> 8), @intCast(ye & 0xFF),
            });
        }

        /// Writes pixels (continuing from the set window). RGB565 is sent high byte first.
        pub fn writePixels(self: *Self, pixels: []const u16) !void {
            try self.commandStart(cmd_ramwr);
            for (pixels) |pixel| {
                const bytes = [_]u8{ @intCast(pixel >> 8), @intCast(pixel & 0xFF) };
                self.transport.writeAll(&bytes);
            }
            try self.commandEnd();
        }

        /// Sends the whole framebuffer.
        pub fn drawFramebuffer(self: *Self, fb: *const framebuffer.Framebuffer) !void {
            if (fb.width != width or fb.height != height) return error.InvalidEncoding;
            try self.setWindow(0, 0, width - 1, height - 1);
            try self.writePixels(fb.pixels);
        }

        /// Sends one command together with its data.
        fn command(self: *Self, code: u8, data: []const u8) !void {
            try self.commandStart(code);
            if (data.len > 0) self.transport.writeAll(data);
            try self.commandEnd();
        }

        fn commandStart(self: *Self, code: u8) !void {
            self.transport.setDataMode(false);
            const bytes = [_]u8{code};
            self.transport.writeAll(&bytes);
            self.transport.setDataMode(true);
        }

        fn commandEnd(self: *Self) !void {
            self.transport.setDataMode(true);
        }
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Mock transport that records everything sent.
pub const MockTransport = struct {
    /// Everything sent, as one sequence: each command or data byte, with `C` / `D` markers
    /// where the data/command line changed (see `setDataMode`).
    log: [4096]u8 = @splat(0),
    log_len: usize = 0,
    data_mode: bool = true,
    chip_select: bool = true,
    reset_high: bool = true,
    backlight: bool = false,
    delays: [32]u32 = @splat(0),
    delay_count: usize = 0,

    pub fn writeAll(self: *MockTransport, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.log_len < self.log.len) {
                self.log[self.log_len] = byte;
                self.log_len += 1;
            }
        }
    }

    pub fn setDataMode(self: *MockTransport, is_data: bool) void {
        self.data_mode = is_data;
        self.mark(if (is_data) 'D' else 'C');
    }

    pub fn setChipSelect(self: *MockTransport, selected: bool) void {
        self.chip_select = selected;
    }

    pub fn setReset(self: *MockTransport, high: bool) void {
        self.reset_high = high;
    }

    pub fn setBacklight(self: *MockTransport, on: bool) void {
        self.backlight = on;
    }

    pub fn delayMs(self: *MockTransport, ms: u32) void {
        if (self.delay_count < self.delays.len) {
            self.delays[self.delay_count] = ms;
            self.delay_count += 1;
        }
    }

    fn mark(self: *MockTransport, tag: u8) void {
        if (self.log_len < self.log.len) {
            self.log[self.log_len] = tag;
            self.log_len += 1;
        }
    }

    pub fn contains(self: *const MockTransport, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.log[0..self.log_len], needle) != null;
    }
};

test "initialization emits the expected commands in order" {
    var transport = MockTransport{};
    var driver = Driver(MockTransport){ .transport = transport };
    try driver.init();
    transport = driver.transport;

    // Software reset, sleep out, color format (RGB565), display on
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_swreset }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_slpout }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_colmod, 'D', 0x55 }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_dispon }));

    // Reset is pulled low once and then raised
    try testing.expect(transport.reset_high);
    try testing.expect(transport.backlight);
    try testing.expect(transport.delay_count >= 4);

    // Data mode is always restored after a command (the final state)
    try testing.expect(transport.data_mode);
}

test "window setup emits four bytes, high byte first" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.setWindow(10, 20, 30, 40);
    const transport = driver.transport;

    // CASET (columns): 10 to 30
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_caset, 'D', 0x00, 0x0A, 0x00, 0x1E }));
    // RASET (rows): 20 to 40
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_raset, 'D', 0x00, 0x14, 0x00, 0x28 }));
}

test "out-of-range windows are rejected" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try testing.expectError(error.InvalidEncoding, driver.setWindow(0, 0, 240, 239));
    try testing.expectError(error.InvalidEncoding, driver.setWindow(10, 10, 5, 20));
}

test "pixels are sent high byte first (RGB565)" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.writePixels(&[_]u16{ 0xF800, 0x07E0, 0x001F });
    const transport = driver.transport;

    // Six bytes after RAMWR
    try testing.expect(transport.contains(&[_]u8{
        'C', cmd_ramwr, 'D', 0xF8, 0x00, 0x07, 0xE0, 0x00, 0x1F,
    }));
}

test "sending the whole framebuffer covers 240x240 pixels" {
    var storage: [width * height]u16 = @splat(0x1234);
    var fb = try framebuffer.Framebuffer.init(&storage, width, height);
    fb.setPixel(0, 0, 0xFFFF);

    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.drawFramebuffer(&fb);
    const transport = driver.transport;

    // The start is white at (0,0)
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_ramwr, 'D', 0xFF, 0xFF }));
    // The window is the full screen
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_caset, 'D', 0x00, 0x00, 0x00, 0xEF }));

    // A framebuffer of a different size is rejected
    var small: [16]u16 = @splat(0);
    var small_fb = try framebuffer.Framebuffer.init(&small, 4, 4);
    try testing.expectError(error.InvalidEncoding, driver.drawFramebuffer(&small_fb));
}

test "changing the orientation updates MADCTL" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.setRotation(.deg90);
    try testing.expect(driver.transport.contains(&[_]u8{ 'C', cmd_madctl, 'D', 0x60 }));
    try driver.setRotation(.deg270);
    try testing.expect(driver.transport.contains(&[_]u8{ 'C', cmd_madctl, 'D', 0xA0 }));
}
