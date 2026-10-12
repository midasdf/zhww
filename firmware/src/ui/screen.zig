//! Screen layout (240×240).
//!
//! The layer that assembles what the real LCD shows, decoupled from the hardware.
//! Run it together with `framebuffer` on a PC and it can be checked as an image
//! (the development CLI's `screen` command).
//!
//! On-screen text is **ASCII** (showing Japanese on a 240×240 screen would require bundling a font;
//! see [docs/08-rp2350-pizero.md] for the policy).

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const framebuffer = @import("framebuffer.zig");
const Framebuffer = framebuffer.Framebuffer;
const Color = framebuffer.Color;

pub const background = framebuffer.rgb(16, 18, 24);
pub const title_background = framebuffer.rgb(32, 64, 128);
pub const footer_background = framebuffer.rgb(40, 40, 48);
pub const label_color = framebuffer.rgb(160, 168, 180);
pub const value_color = framebuffer.white;
pub const strong_color = framebuffer.rgb(120, 220, 160);
pub const warning_color = framebuffer.rgb(255, 96, 80);

pub const title_height = 26;
pub const footer_height = 20;
pub const margin = 6;

/// Monochrome dot matrix (QR codes and the like). One byte per module (any non-zero is dark).
pub const Bitmap = struct {
    width: usize,
    height: usize,
    modules: []const u8,

    pub fn isDark(self: Bitmap, x: usize, y: usize) bool {
        if (x >= self.width or y >= self.height) return false;
        return self.modules[y * self.width + x] != 0;
    }

    pub fn darkCount(self: Bitmap) usize {
        var count: usize = 0;
        for (self.modules[0 .. self.width * self.height]) |m| {
            if (m != 0) count += 1;
        }
        return count;
    }
};

pub const LineKind = enum { label_value, strong, warning };

pub const Line = struct {
    label: []const u8 = "",
    value: []const u8,
    kind: LineKind = .label_value,
};

pub const Screen = struct {
    title: []const u8,
    lines: []const Line = &.{},
    warnings: []const []const u8 = &.{},
    /// QR to show at the bottom of the screen (if any).
    qr: ?Bitmap = null,
    footer_left: []const u8 = "",
    footer_right: []const u8 = "",

    /// Render. `fb` is assumed to be 240×240, but other sizes do not fall apart.
    pub fn render(self: *const Screen, fb: *Framebuffer) void {
        fb.clear(background);

        // title
        fb.fillRect(0, 0, fb.width, title_height, title_background);
        const title_scale: usize = if (fb.width >= 200) 2 else 1;
        const title_width = Framebuffer.textWidth(self.title, title_scale);
        const title_x = if (title_width < fb.width) (fb.width - title_width) / 2 else margin;
        _ = fb.drawText(title_x, 5, self.title, framebuffer.white, null, title_scale);

        // body
        var y: usize = title_height + margin;
        for (self.lines) |line| {
            y = drawLine(fb, y, line);
            if (y >= fb.height - footer_height) return self.drawFooter(fb);
        }

        // warnings (in red)
        for (self.warnings) |warning| {
            y = wrapText(fb, margin, y, warning, warning_color, 1) + 2;
            if (y >= fb.height - footer_height) return self.drawFooter(fb);
        }

        // QR (above the footer, centered, as large as it fits)
        if (self.qr) |bitmap| {
            const available_top = y + 2;
            const available_height = fb.height - footer_height - margin - available_top;
            if (available_height > 20 and bitmap.width > 0 and bitmap.height > 0) {
                const scale_by_width = (fb.width - margin * 2) / bitmap.width;
                const scale_by_height = available_height / bitmap.height;
                const scale = @max(@as(usize, 1), @min(scale_by_width, scale_by_height));
                const drawn_width = bitmap.width * scale;
                const drawn_height = bitmap.height * scale;
                const qr_x = if (drawn_width < fb.width) (fb.width - drawn_width) / 2 else margin;
                const qr_y = if (drawn_height < available_height)
                    available_top + (available_height - drawn_height) / 2
                else
                    available_top;

                // white backing (quiet zone)
                fb.fillRect(qr_x -| 2, qr_y -| 2, drawn_width + 4, drawn_height + 4, framebuffer.white);
                var row: usize = 0;
                while (row < bitmap.height) : (row += 1) {
                    var col: usize = 0;
                    while (col < bitmap.width) : (col += 1) {
                        const color = if (bitmap.isDark(col, row)) framebuffer.black else framebuffer.white;
                        fb.fillRect(qr_x + col * scale, qr_y + row * scale, scale, scale, color);
                    }
                }
            }
        }

        self.drawFooter(fb);
    }

    fn drawLine(fb: *Framebuffer, y_start: usize, line: Line) usize {
        var y = y_start;
        const scale: usize = 1;
        const value_x = margin;

        if (line.label.len > 0) {
            _ = fb.drawText(margin, y, line.label, label_color, null, scale);
            y += 9;
        }

        const color = switch (line.kind) {
            .label_value => value_color,
            .strong => strong_color,
            .warning => warning_color,
        };
        y = wrapText(fb, value_x, y, line.value, color, scale) + 2;
        return y;
    }

    fn drawFooter(self: *const Screen, fb: *Framebuffer) void {
        const y = fb.height -| footer_height;
        fb.fillRect(0, y, fb.width, footer_height, footer_background);
        const text_y = y + 6;
        if (self.footer_left.len > 0) {
            _ = fb.drawText(margin, text_y, self.footer_left, framebuffer.white, null, 1);
        }
        if (self.footer_right.len > 0) {
            const width = Framebuffer.textWidth(self.footer_right, 1);
            const x = if (width + margin < fb.width) fb.width - width - margin else margin;
            _ = fb.drawText(x, text_y, self.footer_right, framebuffer.white, null, 1);
        }
    }
};

/// Wrap to fit the width and draw. Returns the y coordinate after drawing.
fn wrapText(
    fb: *Framebuffer,
    x: usize,
    y_start: usize,
    text: []const u8,
    color: Color,
    scale: usize,
) usize {
    const char_width = framebuffer.char_advance * scale;
    const usable = if (fb.width > x + margin) fb.width - x - margin else char_width;
    const per_line = @max(@as(usize, 1), usable / char_width);

    var y = y_start;
    var rest = text;
    while (rest.len > 0) {
        var take = @min(rest.len, per_line);
        // if there is a space within what fits, break there (never split a word)
        if (take < rest.len) {
            if (std.mem.lastIndexOfScalar(u8, rest[0..take], ' ')) |at| {
                if (at > 0) take = at;
            }
        }
        _ = fb.drawText(x, y, rest[0..take], color, null, scale);
        y += 9 * scale;
        rest = std.mem.trimStart(u8, rest[take..], " ");
    }
    if (text.len == 0) y += 9 * scale;
    return y;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testFramebuffer(storage: []u16) Framebuffer {
    return Framebuffer.init(storage, 240, 240) catch unreachable;
}

test "title, body and footer are drawn" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "CONFIRM",
        .lines = &.{
            .{ .label = "To", .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" },
            .{ .label = "Amount", .value = "0.001 BTC", .kind = .strong },
        },
        .footer_left = "OK",
        .footer_right = "CANCEL",
    };
    screen.render(&fb);

    // the title bar and the footer are filled
    try testing.expectEqual(title_background, fb.getPixel(0, 0));
    try testing.expectEqual(footer_background, fb.getPixel(0, 239));

    // something is drawn in the body (below the title bar)
    var body_pixels: usize = 0;
    var y: usize = title_height + 1;
    while (y < 200) : (y += 1) {
        var x: usize = 0;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) != background) body_pixels += 1;
        }
    }
    try testing.expect(body_pixels > 200);
}

test "a long value wraps and does not run off screen" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "ADDRESS",
        .lines = &.{.{
            .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" ++ "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        }},
    };
    screen.render(&fb);

    // apart from the rightmost column and the footer strip at the bottom, everything stays
    // background (= nothing overflows)
    // check that text does not cross the right edge, using the 4-dot body strip at the right edge
    var y: usize = title_height + 1;
    var overflow: usize = 0;
    while (y < 240 - footer_height) : (y += 1) {
        var x: usize = 232;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) != background) overflow += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), overflow);
}

test "the QR is drawn and the dark module count matches" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    // a 3×3 dot matrix with dark corners and center
    const modules = [_]u8{
        1, 0, 1,
        0, 1, 0,
        1, 0, 1,
    };
    const screen = Screen{
        .title = "SCAN",
        .lines = &.{.{ .value = "ur:crypto-psbt/1-4/lpad..." }},
        .qr = .{ .width = 3, .height = 3, .modules = &modules },
    };
    screen.render(&fb);

    try testing.expectEqual(@as(usize, 5), screen.qr.?.darkCount());

    // dark dots are drawn on screen (QR dark modules × scale^2)
    var black_pixels: usize = 0;
    var y: usize = title_height;
    while (y < 240 - footer_height) : (y += 1) {
        var x: usize = 0;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) == framebuffer.black) black_pixels += 1;
        }
    }
    try testing.expect(black_pixels >= 5);
}

test "warnings are drawn in red" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "CONFIRM",
        .lines = &.{.{ .label = "Fee", .value = "10000 sats" }},
        .warnings = &.{"WARNING: fee is more than 1% of the amount"},
    };
    screen.render(&fb);

    var warning_pixels: usize = 0;
    var y: usize = title_height;
    while (y < 240 - footer_height) : (y += 1) {
        var x: usize = 0;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) == warning_color) warning_pixels += 1;
        }
    }
    try testing.expect(warning_pixels > 20);
}
