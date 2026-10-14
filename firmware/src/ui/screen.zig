//! Screen layout for the **Adafruit Mini PiTFT #4393 (240×135)**.
//!
//! The layer that assembles what the real LCD shows, decoupled from the hardware.
//! Run it together with `framebuffer` on a PC and it can be checked as an image
//! (the development CLI's `screen` command).
//!
//! **Layout**: a 20-dot title bar, a 14-dot footer, a label sharing the line with its value, and
//! the QR in a column beside the text. The boxes follow the framebuffer size (`Layout.forSize`).
//! When the text still does not fit it is **paged** (with a visible `1/2` indicator in the
//! footer) rather than truncated: on a 135-dot-tall screen there are only about ten text
//! lines, and silently dropping a warning would be a safety problem.
//!
//! **Safety**: warnings (`Screen.warnings`, red) are pinned to the first page whenever they
//! fit there, so "No signing was performed." is never hidden behind a page turn.
//!
//! On-screen text is **ASCII** (showing Japanese on a screen this small would require bundling a
//! font; see [docs/08-rp2350-pizero.md] for the policy).
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const font = @import("font.zig");
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
/// Page indicator ("1/2") shown when the body does not fit on one screen.
pub const page_color = framebuffer.yellow;

/// Vertical advance of one line of text (8-dot glyph plus 1 dot of leading).
pub const line_advance = font.glyph_height + 1;

/// Metrics of the layout (Adafruit Mini PiTFT, 240×135).
pub const margin = 4;
pub const title_height = 20;
pub const footer_height = 14;

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

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

/// Metrics and geometry for one framebuffer size.
///
/// The renderer only asks this struct for numbers and geometry. The bars, margins and QR rules
/// are the Mini PiTFT's; the body and QR boxes follow the framebuffer's width and height.
pub const Layout = struct {
    width: usize,
    height: usize,
    /// Left and right margin of the body text.
    margin: usize,
    title_height: usize,
    footer_height: usize,
    /// Distance from the top of the footer bar to the footer text.
    footer_text_y: usize,
    /// Dots between two body entries (label/value blocks and warnings).
    entry_gap: usize,
    /// Dots per QR module below which the symbol is not worth drawing (a phone camera needs
    /// at least two dots per module to resolve it reliably).
    min_qr_scale: usize,
    /// Quiet zone around the QR, in modules (the standard's 4).
    quiet_modules: usize,
    /// Preferred title text scale.
    title_scale: usize,

    pub fn forSize(width: usize, height: usize) Layout {
        return .{
            .width = width,
            .height = height,
            .margin = margin,
            .title_height = title_height,
            .footer_height = footer_height,
            .footer_text_y = 3,
            .entry_gap = 2,
            .min_qr_scale = 2,
            .quiet_modules = 4,
            .title_scale = if (width >= 200) 2 else 1,
        };
    }

    /// Vertical position of the title text for a given text scale (centred in the bar).
    pub fn titleTextY(self: Layout, scale: usize) usize {
        const text_height = font.glyph_height * scale;
        return if (self.title_height > text_height) (self.title_height - text_height) / 2 else 0;
    }

    /// Title text scale. 2× is the design; a title that would run off the right edge falls
    /// back to 1× instead of being clipped.
    pub fn titleScale(self: Layout, title: []const u8) usize {
        if (Framebuffer.textWidth(title, self.title_scale) + 2 * self.margin <= self.width) return self.title_scale;
        return 1;
    }

    /// First dot row of the body text.
    pub fn bodyTop(self: Layout) usize {
        return self.title_height + self.margin;
    }

    /// The body text must end by here (the footer bar starts below).
    pub fn bodyBottom(self: Layout) usize {
        return self.height -| (self.footer_height + self.margin);
    }

    /// Area a QR may occupy: a full-height column on the right (its width is capped at half
    /// the screen so the text keeps a usable column).
    pub fn qrBox(self: Layout) Rect {
        const pad: usize = 2;
        const half = self.width / 2;
        return .{
            .x = half,
            .y = self.title_height + pad,
            .width = self.width -| half,
            .height = self.height -| (self.title_height + self.footer_height + 2 * pad),
        };
    }

    /// Largest QR module count that still fits the QR box at `scale` dots per module,
    /// including a quiet zone of `quiet_modules` on each side.
    ///
    /// This is what a caller should use to pick how much data to put in one QR code (for
    /// example the UR fragment length): a symbol larger than this can only be drawn below
    /// the scannable minimum.
    pub fn maxQrModules(self: Layout, scale: usize) usize {
        const box = self.qrBox();
        const quiet = self.quiet_modules * scale;
        const side = @min(box.width, box.height);
        if (side <= 2 * quiet) return 0;
        return (side - 2 * quiet) / scale;
    }

    /// Largest scale at which `bitmap` (with its quiet zone) fits the QR box.
    pub fn maxQrScale(self: Layout, bitmap: Bitmap) usize {
        if (bitmap.width == 0 or bitmap.height == 0) return 1;
        const box = self.qrBox();
        var scale: usize = 1;
        while (true) {
            const next = scale + 1;
            const quiet = 2 * self.quiet_modules * next;
            if (bitmap.width * next + quiet > box.width) break;
            if (bitmap.height * next + quiet > box.height) break;
            scale = next;
        }
        return scale;
    }

    /// Quiet zone (in dots) actually available for a QR of `bitmap` drawn at `scale`.
    fn quietFor(self: Layout, bitmap: Bitmap, scale: usize) usize {
        const box = self.qrBox();
        const drawn = bitmap.height * scale;
        const free = box.height -| drawn;
        return @min(self.quiet_modules * scale, free / 2);
    }
};

/// One page of the body.
pub const Page = struct {
    /// 1-based number of the page this plan draws.
    number: usize = 1,
    /// Total number of pages.
    count: usize = 1,
    line_start: usize = 0,
    line_end: usize = 0,
    warning_start: usize = 0,
    warning_end: usize = 0,
};

pub const QrPlacement = struct {
    x: usize,
    y: usize,
    /// Dots per module.
    scale: usize,
    /// Quiet zone (white) around the symbol, in dots.
    quiet: usize,
};

/// Everything the renderer needs for one screen at one framebuffer size.
pub const Plan = struct {
    layout: Layout,
    text_x: usize,
    text_width: usize,
    qr: ?QrPlacement = null,
    page: Page = .{},
};

pub const Screen = struct {
    title: []const u8,
    lines: []const Line = &.{},
    warnings: []const []const u8 = &.{},
    /// QR to show (in a column beside the text).
    qr: ?Bitmap = null,
    footer_left: []const u8 = "",
    footer_right: []const u8 = "",
    /// Which page of the body to draw (1-based). Only meaningful when the content does not
    /// fit; `pageCount` says how many pages there are.
    page: usize = 1,

    /// Work out where everything goes for this framebuffer size (measure only, no drawing):
    /// a QR column on the right, text pages on the left.
    pub fn plan(self: *const Screen, fb: *const Framebuffer) Plan {
        const layout = Layout.forSize(fb.width, fb.height);
        const text_x = layout.margin;
        var plan_ = Plan{
            .layout = layout,
            .text_x = text_x,
            .text_width = fb.width -| (text_x + layout.margin),
        };

        if (self.qr) |bitmap| {
            if (bitmap.width > 0 and bitmap.height > 0) {
                // Take the largest QR that fits the box, but give up size (down to the
                // scannable minimum) while that is what it takes to keep the text on one
                // page: paging a confirmation screen hides content behind a button press.
                var scale = layout.maxQrScale(bitmap);
                while (scale > layout.min_qr_scale) : (scale -= 1) {
                    const width = textWidthBesideQr(fb, layout, bitmap, scale);
                    if (self.paginate(layout, text_x, width, 1).count == 1) break;
                }
                const quiet = layout.quietFor(bitmap, scale);
                const column = bitmap.width * scale + 2 * quiet;
                const box = layout.qrBox();
                const drawn_height = bitmap.height * scale;
                plan_.qr = .{
                    .x = fb.width -| (layout.margin + column),
                    .y = box.y + (box.height -| drawn_height) / 2,
                    .scale = scale,
                    .quiet = quiet,
                };
                plan_.text_width = textWidthBesideQr(fb, layout, bitmap, scale);
            }
        }
        plan_.page = self.paginate(layout, plan_.text_x, plan_.text_width, self.page);
        return plan_;
    }

    /// Total number of pages this screen needs at this framebuffer size.
    pub fn pageCount(self: *const Screen, fb: *const Framebuffer) usize {
        return self.plan(fb).page.count;
    }

    /// Render into the framebuffer (its size decides the boxes).
    pub fn render(self: *const Screen, fb: *Framebuffer) void {
        const plan_ = self.plan(fb);
        const layout = plan_.layout;

        fb.clear(background);
        self.drawTitle(fb, layout);

        var y = layout.bodyTop();
        for (self.lines[plan_.page.line_start..plan_.page.line_end]) |line| {
            y = drawLine(fb, layout, plan_.text_x, y, plan_.text_width, line);
        }
        for (self.warnings[plan_.page.warning_start..plan_.page.warning_end]) |warning| {
            y = drawWarning(fb, layout, plan_.text_x, y, plan_.text_width, warning);
        }

        if (plan_.qr) |qr| drawQr(fb, self.qr.?, qr);
        self.drawFooter(fb, layout, plan_.page);
    }

    // ------------------------------------------------------------ planning

    /// Split the body into pages.
    ///
    /// Warnings are kept on the first page whenever they fit there (a red "no signing was
    /// performed" must never hide behind a page turn); the lines that do not fit follow on
    /// the next pages. Entries are never dropped: the pages together cover every line and
    /// every warning.
    fn paginate(
        self: *const Screen,
        layout: Layout,
        x: usize,
        width: usize,
        wanted: usize,
    ) Page {
        const area = layout.bodyBottom() -| layout.bodyTop();
        const line_count = self.lines.len;
        const warning_count = self.warnings.len;

        var warnings_height: usize = 0;
        for (self.warnings) |warning| warnings_height += warningHeight(layout, x, width, warning);

        var result = Page{ .number = 1 };
        var page: usize = 1;
        var line_i: usize = 0;
        var warning_i: usize = 0;
        const wanted_page = @max(@as(usize, 1), wanted);

        while (true) : (page += 1) {
            const start_line = line_i;
            const start_warning = warning_i;
            var used: usize = 0;

            if (page == 1 and warnings_height <= area) {
                // Reserve the whole warning block, then fill the rest with lines.
                while (line_i < line_count) {
                    const height = lineHeight(layout, x, width, self.lines[line_i]);
                    if (used + height + warnings_height > area) break;
                    used += height;
                    line_i += 1;
                }
            } else {
                while (line_i < line_count) {
                    const height = lineHeight(layout, x, width, self.lines[line_i]);
                    if (used + height > area) break;
                    used += height;
                    line_i += 1;
                }
            }
            while (warning_i < warning_count) {
                const height = warningHeight(layout, x, width, self.warnings[warning_i]);
                if (used + height > area) break;
                used += height;
                warning_i += 1;
            }

            // An entry taller than the body would otherwise loop forever: take it anyway
            // (the framebuffer clips) and let the next page continue.
            if (line_i == start_line and warning_i == start_warning) {
                if (line_i < line_count) {
                    line_i += 1;
                } else if (warning_i < warning_count) {
                    warning_i += 1;
                } else break;
            }

            if (page <= wanted_page) {
                result.number = page;
                result.line_start = start_line;
                result.line_end = line_i;
                result.warning_start = start_warning;
                result.warning_end = warning_i;
            }
            if (line_i == line_count and warning_i == warning_count) {
                result.count = page;
                break;
            }
        }
        return result;
    }

    // ------------------------------------------------------------ drawing

    fn drawTitle(self: *const Screen, fb: *Framebuffer, layout: Layout) void {
        const scale = layout.titleScale(self.title);
        fb.fillRect(0, 0, fb.width, layout.title_height, title_background);
        const width = Framebuffer.textWidth(self.title, scale);
        const x = if (width < fb.width) (fb.width - width) / 2 else layout.margin;
        _ = fb.drawText(x, layout.titleTextY(scale), self.title, framebuffer.white, null, scale);
    }

    fn drawFooter(self: *const Screen, fb: *Framebuffer, layout: Layout, page: Page) void {
        const y = fb.height -| layout.footer_height;
        fb.fillRect(0, y, fb.width, layout.footer_height, footer_background);
        const text_y = y + layout.footer_text_y;
        if (self.footer_left.len > 0) {
            _ = fb.drawText(layout.margin, text_y, self.footer_left, framebuffer.white, null, 1);
        }
        if (self.footer_right.len > 0) {
            const width = Framebuffer.textWidth(self.footer_right, 1);
            const x = if (width + layout.margin < fb.width) fb.width - width - layout.margin else layout.margin;
            _ = fb.drawText(x, text_y, self.footer_right, framebuffer.white, null, 1);
        }
        if (page.count > 1) {
            var buffer: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "{d}/{d}", .{ page.number, page.count }) catch "?";
            const width = Framebuffer.textWidth(text, 1);
            _ = fb.drawText((fb.width -| width) / 2, text_y, text, page_color, null, 1);
        }
    }
};

/// Text width available beside a QR column drawn at `scale`.
fn textWidthBesideQr(fb: *const Framebuffer, layout: Layout, bitmap: Bitmap, scale: usize) usize {
    const quiet = layout.quietFor(bitmap, scale);
    const column = bitmap.width * scale + 2 * quiet;
    const gap: usize = 6;
    return fb.width -| (layout.margin + column + gap + layout.margin);
}

/// Draw one body line. Returns the y coordinate after it.
fn drawLine(fb: *Framebuffer, layout: Layout, x: usize, y: usize, width: usize, line: Line) usize {
    const color = switch (line.kind) {
        .label_value => value_color,
        .strong => strong_color,
        .warning => warning_color,
    };
    return y + flow(fb, x, y, width, line.label, line.value, color) * line_advance + layout.entry_gap;
}

/// Draw one warning (red). Returns the y coordinate after it.
fn drawWarning(fb: *Framebuffer, layout: Layout, x: usize, y: usize, width: usize, warning: []const u8) usize {
    return y + flow(fb, x, y, width, "", warning, warning_color) * line_advance + layout.entry_gap;
}

fn lineHeight(layout: Layout, x: usize, width: usize, line: Line) usize {
    const color = switch (line.kind) {
        .label_value => value_color,
        .strong => strong_color,
        .warning => warning_color,
    };
    return flow(null, x, 0, width, line.label, line.value, color) * line_advance + layout.entry_gap;
}

fn warningHeight(layout: Layout, x: usize, width: usize, warning: []const u8) usize {
    return flow(null, x, 0, width, "", warning, warning_color) * line_advance + layout.entry_gap;
}

/// Lay out one entry (a label and a value) and return how many text lines it takes.
///
/// With a null framebuffer this only measures, so the renderer and the paginator always agree.
/// The label shares the first line ("To: bc1q…") when that still leaves room for the value;
/// otherwise it gets a line of its own.
fn flow(
    fb: ?*Framebuffer,
    x: usize,
    y: usize,
    width: usize,
    label: []const u8,
    value: []const u8,
    color: Color,
) usize {
    const usable = @max(width, framebuffer.char_advance);
    var lines: usize = 0;
    var line_y = y;
    var cursor_x = x;
    var first_usable = usable;

    if (label.len > 0) {
        const label_width = Framebuffer.textWidth(label, 1);
        const prefix = label_width + 2 * framebuffer.char_advance; // ": "
        if (prefix < usable) {
            if (fb) |surface| {
                _ = surface.drawText(x, line_y, label, label_color, null, 1);
                _ = surface.drawText(x + label_width, line_y, ":", label_color, null, 1);
            }
            cursor_x = x + prefix;
            first_usable = usable - prefix;
        } else {
            if (fb) |surface| _ = surface.drawText(x, line_y, label, label_color, null, 1);
            lines += 1;
            line_y += line_advance;
        }
    }

    var rest = value;
    var first = true;
    while (rest.len > 0) {
        const take = takeLine(rest, if (first) first_usable else usable);
        if (fb) |surface| _ = surface.drawText(cursor_x, line_y, rest[0..take], color, null, 1);
        rest = std.mem.trimStart(u8, rest[take..], " ");
        line_y += line_advance;
        lines += 1;
        first = false;
        cursor_x = x;
    }
    // An empty value still occupies a line (it is used as a blank spacer).
    if (lines == 0) lines = 1;
    return lines;
}

/// How much of `text` fits in `usable` dots, breaking at a space when there is one
/// (never splits a word).
fn takeLine(text: []const u8, usable: usize) usize {
    const per_line = @max(@as(usize, 1), usable / framebuffer.char_advance);
    var take = @min(text.len, per_line);
    if (take < text.len) {
        if (std.mem.lastIndexOfScalar(u8, text[0..take], ' ')) |at| {
            if (at > 0) take = at;
        }
    }
    return take;
}

/// Draw the QR (white backing = quiet zone, then one filled square per dark module).
fn drawQr(fb: *Framebuffer, bitmap: Bitmap, placement: QrPlacement) void {
    const scale = placement.scale;
    const drawn_width = bitmap.width * scale;
    const drawn_height = bitmap.height * scale;
    if (placement.quiet > 0) {
        fb.fillRect(
            placement.x -| placement.quiet,
            placement.y -| placement.quiet,
            drawn_width + 2 * placement.quiet,
            drawn_height + 2 * placement.quiet,
            framebuffer.white,
        );
    }
    var row: usize = 0;
    while (row < bitmap.height) : (row += 1) {
        var col: usize = 0;
        while (col < bitmap.width) : (col += 1) {
            const color = if (bitmap.isDark(col, row)) framebuffer.black else framebuffer.white;
            fb.fillRect(placement.x + col * scale, placement.y + row * scale, scale, scale, color);
        }
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testFramebuffer(storage: []u16) Framebuffer {
    return Framebuffer.init(storage, 240, 135) catch unreachable;
}

/// Count dots of `color` in the body (between the title bar and the footer).
fn countColor(fb: *const Framebuffer, layout: Layout, color: Color) usize {
    return countColorInRows(fb, layout.title_height, fb.height -| layout.footer_height, color);
}

fn countColorInRows(fb: *const Framebuffer, y_start: usize, y_end: usize, color: Color) usize {
    var count: usize = 0;
    var y = y_start;
    while (y < y_end) : (y += 1) {
        var x: usize = 0;
        while (x < fb.width) : (x += 1) {
            if (fb.getPixel(x, y) == color) count += 1;
        }
    }
    return count;
}

/// Count dots that are not background in the 8-dot strip along the right edge of the body.
fn rightEdgeOverflow(fb: *const Framebuffer) usize {
    var overflow: usize = 0;
    var y: usize = title_height + 1;
    while (y < 135 - footer_height) : (y += 1) {
        var x: usize = 232;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) != background) overflow += 1;
        }
    }
    return overflow;
}

test "the layout metrics are the Mini PiTFT's" {
    const layout = Layout.forSize(240, 135);
    try testing.expectEqual(@as(usize, 20), layout.title_height);
    try testing.expectEqual(@as(usize, 14), layout.footer_height);
    try testing.expectEqual(@as(usize, 4), layout.margin);
    // the 16-dot title text at 2× is centred in the 20-dot bar
    try testing.expectEqual(@as(usize, 2), layout.titleTextY(2));
    // a title too wide for the bar is shrunk rather than clipped
    // (252 dots at 2× does not fit 240, so this is 1×)
    try testing.expectEqual(@as(usize, 1), layout.titleScale("PSBT TOO LARGE"));
    try testing.expectEqual(@as(usize, 2), layout.titleScale("CONFIRM"));
}

test "a confirmation screen with a warning fits on one page, in red" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "CONFIRM",
        .lines = &.{
            .{ .label = "To", .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" },
            .{ .label = "Amount", .value = "0.00100000 BTC", .kind = .strong },
            .{ .label = "Fee", .value = "1234 sats (0.12%)" },
        },
        .warnings = &.{"Check the address on your own screen"},
        .footer_left = "OK",
        .footer_right = "CANCEL",
    };
    const layout = Layout.forSize(240, 135);
    try testing.expectEqual(@as(usize, 1), screen.pageCount(&fb));
    screen.render(&fb);

    // the red warning is on screen
    try testing.expect(countColor(&fb, layout, warning_color) > 20);

    // the title bar and the footer are filled, and the body is not empty
    try testing.expectEqual(title_background, fb.getPixel(0, 0));
    try testing.expectEqual(footer_background, fb.getPixel(0, 134));
    var body_pixels: usize = 0;
    var y: usize = title_height + 1;
    while (y < 135 - footer_height) : (y += 1) {
        var x: usize = 0;
        while (x < 240) : (x += 1) {
            if (fb.getPixel(x, y) != background) body_pixels += 1;
        }
    }
    try testing.expect(body_pixels > 200);

    // nothing is drawn across the right edge (this screen has no QR)
    try testing.expectEqual(@as(usize, 0), rightEdgeOverflow(&fb));
}

test "a long value wraps and does not run off screen" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "ADDRESS",
        .lines = &.{.{
            .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" ++ "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        }},
    };
    screen.render(&fb);
    try testing.expect(countColor(&fb, Layout.forSize(240, 135), value_color) > 20);
    try testing.expectEqual(@as(usize, 0), rightEdgeOverflow(&fb));
}

test "the QR is drawn and the dark module count matches" {
    var storage: [240 * 135]u16 = @splat(0);
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
    try testing.expect(countColor(&fb, Layout.forSize(240, 135), framebuffer.black) >= 5);
}

test "no body entry is dropped (paging covers every line and warning)" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const lines = [_]Line{
        .{ .value = "LINE 01" }, .{ .value = "LINE 02" }, .{ .value = "LINE 03" },
        .{ .value = "LINE 04" }, .{ .value = "LINE 05" }, .{ .value = "LINE 06" },
        .{ .value = "LINE 07" }, .{ .value = "LINE 08" }, .{ .value = "LINE 09" },
        .{ .value = "LINE 10" }, .{ .value = "LINE 11" }, .{ .value = "LINE 12 END" },
    };
    const screen = Screen{
        .title = "PAGED",
        .lines = &lines,
        .warnings = &.{"No signing was performed."},
        .footer_left = "BACK",
    };

    const pages = screen.pageCount(&fb);
    try testing.expect(pages > 1);

    // the pages together cover every line, in order, and the warning stays on page 1
    var covered: usize = 0;
    var page: usize = 1;
    while (page <= pages) : (page += 1) {
        var paged = screen;
        paged.page = page;
        const plan_ = paged.plan(&fb);
        try testing.expectEqual(covered, plan_.page.line_start);
        try testing.expect(plan_.page.line_end >= plan_.page.line_start);
        covered = plan_.page.line_end;
        if (page == 1) {
            try testing.expectEqual(@as(usize, 1), plan_.page.warning_end);
        }
    }
    try testing.expectEqual(lines.len, covered);

    // page 2 draws body text of its own and the footer carries the page indicator
    var paged = screen;
    paged.page = 2;
    paged.render(&fb);
    const layout = Layout.forSize(240, 135);
    try testing.expect(countColor(&fb, layout, value_color) > 20);
    const footer_top = 135 - footer_height;
    try testing.expect(countColorInRows(&fb, footer_top, 135, page_color) > 0);
}

test "the warning is pinned to the first page" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    // Enough lines to overflow, plus a warning: the warning must be on page 1 even though
    // it comes last in the entry order.
    const lines = [_]Line{
        .{ .value = "ONE" },   .{ .value = "TWO" },    .{ .value = "THREE" },
        .{ .value = "FOUR" },  .{ .value = "FIVE" },   .{ .value = "SIX" },
        .{ .value = "SEVEN" }, .{ .value = "EIGHT" },  .{ .value = "NINE" },
        .{ .value = "TEN" },   .{ .value = "ELEVEN" },
    };
    const screen = Screen{
        .title = "PINNED",
        .lines = &lines,
        .warnings = &.{"No signing was performed."},
    };
    try testing.expect(screen.pageCount(&fb) > 1);
    screen.render(&fb);
    try testing.expect(countColor(&fb, Layout.forSize(240, 135), warning_color) > 20);
}

test "a long title is shrunk instead of clipped" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{ .title = "PSBT TOO LARGE", .lines = &.{.{ .value = "too big" }} };
    screen.render(&fb);

    // 2× would be 252 dots wide; at 1× nothing touches the last dot column of the title bar
    const layout = Layout.forSize(240, 135);
    var y: usize = 0;
    while (y < layout.title_height) : (y += 1) {
        try testing.expectEqual(title_background, fb.getPixel(239, y));
    }
}

test "the QR stays at 2 dots per module with a quiet zone" {
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    // a version-5 symbol (37x37 modules): with the standard 4-module quiet zone this is the
    // largest that still fits the QR box at 2 dots per module (2*37 + 2*8 = 90 <= 97)
    const side = 37;
    var modules: [side * side]u8 = @splat(0);
    modules[0] = 1;
    modules[side * side - 1] = 1;
    const screen = Screen{
        .title = "SIGNED",
        .lines = &.{.{ .value = "part 1/9" }},
        .qr = .{ .width = side, .height = side, .modules = &modules },
        .footer_left = "BACK",
        .footer_right = "NEXT PART",
    };

    const layout = Layout.forSize(240, 135);
    const plan_ = screen.plan(&fb);
    const qr = plan_.qr orelse return error.NoQrDrawn;
    try testing.expectEqual(@as(usize, 2), qr.scale);
    try testing.expect(qr.quiet >= 4 * qr.scale); // the standard 4-module quiet zone

    screen.render(&fb);
    // dark module 0 is a scale×scale block of black dots, surrounded by white
    try testing.expectEqual(framebuffer.black, fb.getPixel(qr.x, qr.y));
    try testing.expectEqual(framebuffer.black, fb.getPixel(qr.x + qr.scale - 1, qr.y + qr.scale - 1));
    if (qr.quiet > 0) try testing.expectEqual(framebuffer.white, fb.getPixel(qr.x - 1, qr.y - 1));
    // the symbol plus its quiet zone stays between the bars and inside the screen
    try testing.expect(qr.y >= layout.title_height);
    try testing.expect(qr.y + side * qr.scale + qr.quiet <= 135 - layout.footer_height);
    try testing.expect(qr.x + side * qr.scale + qr.quiet <= 240);
    // and the text is still there beside it
    try testing.expect(countColor(&fb, layout, value_color) > 20);
}

test "the QR capacity the layout offers to a caller" {
    // what a caller (the device) may ask for without going below 2 dots/module
    try testing.expectEqual(@as(usize, 40), Layout.forSize(240, 135).maxQrModules(2));
    // and the box really cannot hold one more
    try testing.expectEqual(@as(usize, 1), Layout.forSize(240, 135).maxQrScale(.{
        .width = 45,
        .height = 45,
        .modules = "",
    }));
}

test "every error screen says no signing was performed, in red, on one page" {
    // The non-negotiable rule: an error screen must never drop the red line saying that
    // nothing was signed, and at 135 dots it must not end up behind a page turn either.
    const device = @import("../app/device.zig");
    var storage: [240 * 135]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    for (std.enums.values(device.Problem)) |problem| {
        if (problem == .waiting_scan) continue; // the only screen that is not an error
        var lines: [8]Line = undefined;
        var warnings: [4][]const u8 = undefined;
        const screen = device.screenFor(device.noticeFor(problem), &lines, &warnings);

        try testing.expectEqual(@as(usize, 1), screen.pageCount(&fb));
        screen.render(&fb);
        try testing.expect(countColor(&fb, Layout.forSize(240, 135), warning_color) > 20);
    }
}
