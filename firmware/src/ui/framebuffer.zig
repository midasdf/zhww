//! Framebuffer for drawing on the 240×240 LCD (RGB565).
//!
//! **Why build this first**: so the screen contents can be assembled and checked without real
//! hardware. The same code runs on a PC and can be written out as an image, which lets the UI be
//! settled first (the foundation for the project's principle "do not sign anything that cannot be displayed").
//!
//! Colors are RGB565 (16 bit). The LCD takes this buffer as-is over SPI.
//! Drawing **ignores anything out of range** (it clips), so callers need not fret over coordinates.

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const font = @import("font.zig");

/// An RGB565 color.
pub const Color = u16;

pub const black: Color = 0x0000;
pub const white: Color = 0xFFFF;
pub const red: Color = 0xF800;
pub const green: Color = 0x07E0;
pub const blue: Color = 0x001F;
pub const yellow: Color = 0xFFE0;
pub const orange: Color = 0xFD20;
pub const gray: Color = 0x8410;
pub const dark_gray: Color = 0x4208;

/// Build an RGB565 color from RGB888 (makes colors easier to pick while designing).
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// Width taken by one character of text (8 dots + 1 dot of spacing).
pub const char_advance = font.glyph_width + 1;

pub const Framebuffer = struct {
    width: usize,
    height: usize,
    pixels: []u16,

    pub fn init(pixels: []u16, width: usize, height: usize) Error!Framebuffer {
        if (pixels.len < width * height) return error.BufferTooSmall;
        return .{ .width = width, .height = height, .pixels = pixels[0 .. width * height] };
    }

    pub fn clear(self: *Framebuffer, color: Color) void {
        @memset(self.pixels, color);
    }

    /// One dot. Out-of-range coordinates are ignored.
    pub fn setPixel(self: *Framebuffer, x: usize, y: usize, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = color;
    }

    pub fn getPixel(self: *const Framebuffer, x: usize, y: usize) Color {
        if (x >= self.width or y >= self.height) return black;
        return self.pixels[y * self.width + x];
    }

    /// Fill a rectangle. Out-of-range parts are clipped.
    pub fn fillRect(self: *Framebuffer, x: usize, y: usize, w: usize, h: usize, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        const x_end = @min(self.width, x + w);
        const y_end = @min(self.height, y + h);
        var row = y;
        while (row < y_end) : (row += 1) {
            @memset(self.pixels[row * self.width + x .. row * self.width + x_end], color);
        }
    }

    /// Stroke the outline of a rectangle.
    pub fn strokeRect(self: *Framebuffer, x: usize, y: usize, w: usize, h: usize, color: Color) void {
        if (w == 0 or h == 0) return;
        self.fillRect(x, y, w, 1, color); // top
        self.fillRect(x, y + h - 1, w, 1, color); // bottom
        self.fillRect(x, y, 1, h, color); // left
        self.fillRect(x + w - 1, y, 1, h, color); // right
    }

    /// Draw one character. If `background` is null the background is not painted (it draws over instead).
    pub fn drawGlyph(
        self: *Framebuffer,
        x: usize,
        y: usize,
        code: u8,
        color: Color,
        background: ?Color,
        scale: usize,
    ) void {
        const glyph = font.glyph(code);
        const s = if (scale == 0) 1 else scale;
        for (glyph, 0..) |row_bits, row| {
            var col: usize = 0;
            while (col < font.glyph_width) : (col += 1) {
                const on = (row_bits >> @intCast(col)) & 1 == 1;
                if (on) {
                    self.fillRect(x + col * s, y + row * s, s, s, color);
                } else if (background) |bg| {
                    self.fillRect(x + col * s, y + row * s, s, s, bg);
                }
            }
        }
    }

    /// Draw a string. Returns the x coordinate just past what was drawn.
    pub fn drawText(
        self: *Framebuffer,
        x: usize,
        y: usize,
        text: []const u8,
        color: Color,
        background: ?Color,
        scale: usize,
    ) usize {
        const s = if (scale == 0) 1 else scale;
        var cursor = x;
        for (text) |code| {
            self.drawGlyph(cursor, y, code, color, background, s);
            cursor += char_advance * s;
        }
        return cursor;
    }

    /// Draw a string, honoring newlines (`\n`). Returns the number of lines drawn.
    pub fn drawTextLines(
        self: *Framebuffer,
        x: usize,
        y: usize,
        text: []const u8,
        color: Color,
        background: ?Color,
        scale: usize,
    ) usize {
        const s = if (scale == 0) 1 else scale;
        var line_y = y;
        var lines: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line| {
            _ = self.drawText(x, line_y, line, color, background, s);
            line_y += (font.glyph_height + 1) * s;
            lines += 1;
        }
        return lines;
    }

    /// Width of a string in dots.
    pub fn textWidth(text: []const u8, scale: usize) usize {
        const s = if (scale == 0) 1 else scale;
        return text.len * char_advance * s;
    }

    /// Draw a black-and-white dot matrix at `scale`× (used to draw QR codes).
    ///
    /// `sample` returns whether (x, y) is dark. It keeps this code independent of the QR module's type.
    pub fn drawBitmap(
        self: *Framebuffer,
        x: usize,
        y: usize,
        width: usize,
        height: usize,
        scale: usize,
        foreground: Color,
        background: ?Color,
        sample: anytype,
    ) void {
        const s = if (scale == 0) 1 else scale;
        var row: usize = 0;
        while (row < height) : (row += 1) {
            var col: usize = 0;
            while (col < width) : (col += 1) {
                const on = sample(col, row);
                const color = if (on) foreground else (background orelse continue);
                self.fillRect(x + col * s, y + row * s, s, s, color);
            }
        }
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testBuffer(storage: []u16) Framebuffer {
    return Framebuffer.init(storage, 240, 240) catch unreachable;
}

test "out-of-range writes are ignored and clipped" {
    var storage: [16]u16 = @splat(black);
    var fb = try Framebuffer.init(&storage, 4, 4);

    fb.setPixel(0, 0, white);
    try testing.expectEqual(white, fb.getPixel(0, 0));
    fb.setPixel(10, 10, white); // out of range → ignored
    try testing.expectEqual(black, fb.getPixel(3, 3));

    fb.fillRect(3, 3, 10, 10, blue); // overflows → clipped
    try testing.expectEqual(blue, fb.getPixel(3, 3));
    try testing.expectEqual(black, fb.getPixel(2, 2));
    try testing.expectEqual(blue, storage[15]);
}

test "init rejects a buffer that is too small" {
    var storage: [4]u16 = @splat(black);
    try testing.expectError(error.BufferTooSmall, Framebuffer.init(&storage, 240, 240));
}

test "drawing a character (row 0 of 'A' is bit2 and bit3)" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    // row 0 of 'A' is 0x0C (bit2, bit3)
    fb.drawGlyph(0, 0, 'A', white, null, 1);
    try testing.expectEqual(black, fb.getPixel(0, 0));
    try testing.expectEqual(black, fb.getPixel(1, 0));
    try testing.expectEqual(white, fb.getPixel(2, 0));
    try testing.expectEqual(white, fb.getPixel(3, 0));
    try testing.expectEqual(black, fb.getPixel(4, 0));

    // at 2× each dot becomes a 2×2 block
    fb.clear(black);
    fb.drawGlyph(0, 0, 'A', white, null, 2);
    try testing.expectEqual(white, fb.getPixel(4, 0));
    try testing.expectEqual(white, fb.getPixel(5, 0));
    try testing.expectEqual(white, fb.getPixel(4, 1));
    // bit2 covers x=4-5 and bit3 covers x=6-7; the next dot is not painted
    try testing.expectEqual(white, fb.getPixel(6, 0));
    try testing.expectEqual(black, fb.getPixel(8, 0));
}

test "a string advances 9 dots at a time and its width can be computed" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    const next = fb.drawText(10, 20, "AB", white, null, 1);
    try testing.expectEqual(@as(usize, 10 + 9 * 2), next);
    try testing.expectEqual(@as(usize, 18), Framebuffer.textWidth("AB", 1));
    try testing.expectEqual(@as(usize, 36), Framebuffer.textWidth("AB", 2));

    // the first character is drawn from (10, 20)
    try testing.expectEqual(white, fb.getPixel(12, 20)); // bit2 of 'A'
}

test "strings with newlines, and background filling" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    const lines = fb.drawTextLines(0, 0, "A\nB", white, black, 1);
    try testing.expectEqual(@as(usize, 2), lines); // "A" and "B"
    try testing.expectEqual(white, fb.getPixel(2, 0)); // 'A'
    try testing.expectEqual(white, fb.getPixel(2, 9)); // 'B' is 9 dots lower

    // with a background, the parts that are not the glyph are painted too
    fb.clear(black);
    _ = fb.drawText(0, 0, "A", white, red, 1);
    try testing.expectEqual(red, fb.getPixel(0, 0));
    try testing.expectEqual(white, fb.getPixel(2, 0));
}

test "drawBitmap draws a dot matrix (the entry point for QR)" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    // draw a checkerboard (2×2 modules) at 4×
    const Sample = struct {
        fn get(x: usize, y: usize) bool {
            return (x + y) % 2 == 0;
        }
    };
    fb.drawBitmap(0, 0, 2, 2, 4, white, black, Sample.get);
    try testing.expectEqual(white, fb.getPixel(0, 0));
    try testing.expectEqual(black, fb.getPixel(4, 0));
    try testing.expectEqual(black, fb.getPixel(0, 4));
    try testing.expectEqual(white, fb.getPixel(4, 4));
    // nothing outside the modules is touched
    try testing.expectEqual(black, fb.getPixel(8, 8));
}
