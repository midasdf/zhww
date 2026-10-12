//! 240×240 の LCD に描くためのフレームバッファ（RGB565）。
//!
//! **なぜ最初にこれを作るのか**: 実機が無くても画面の中身を組み立てて検証できるようにするため。
//! PC 上で同じコードを走らせて画像に書き出せるので、UI を先に固められる
//! （プロジェクトの原則「表示できないものには署名しない」の土台）。
//!
//! 色は RGB565（16bit）。LCD へはこのバッファをそのまま SPI で送る。
//! 描画は**範囲外を無視する**（クリップする）ので、呼び出し側で座標を気にしすぎなくてよい。

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const font = @import("font.zig");

/// RGB565 の色。
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

/// RGB888 から RGB565 を作る（デザイン時に色を指定しやすくするため）。
pub fn rgb(r: u8, g: u8, b: u8) Color {
    return (@as(u16, r >> 3) << 11) | (@as(u16, g >> 2) << 5) | @as(u16, b >> 3);
}

/// テキスト描画の 1 文字あたりの幅（8 ドット + 1 ドットの間隔）。
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

    /// 1 ドット。範囲外は無視する。
    pub fn setPixel(self: *Framebuffer, x: usize, y: usize, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.width + x] = color;
    }

    pub fn getPixel(self: *const Framebuffer, x: usize, y: usize) Color {
        if (x >= self.width or y >= self.height) return black;
        return self.pixels[y * self.width + x];
    }

    /// 矩形を塗る。範囲外はクリップする。
    pub fn fillRect(self: *Framebuffer, x: usize, y: usize, w: usize, h: usize, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        const x_end = @min(self.width, x + w);
        const y_end = @min(self.height, y + h);
        var row = y;
        while (row < y_end) : (row += 1) {
            @memset(self.pixels[row * self.width + x .. row * self.width + x_end], color);
        }
    }

    /// 矩形の枠線を描く。
    pub fn strokeRect(self: *Framebuffer, x: usize, y: usize, w: usize, h: usize, color: Color) void {
        if (w == 0 or h == 0) return;
        self.fillRect(x, y, w, 1, color); // 上
        self.fillRect(x, y + h - 1, w, 1, color); // 下
        self.fillRect(x, y, 1, h, color); // 左
        self.fillRect(x + w - 1, y, 1, h, color); // 右
    }

    /// 1 文字を描く。`background` が null なら背景を塗らない（重ね書き）。
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

    /// 文字列を描く。描いた次の x 座標を返す。
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

    /// 改行（`\n`）を考慮して文字列を描く。描いた行数を返す。
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

    /// 文字列の幅（ドット数）。
    pub fn textWidth(text: []const u8, scale: usize) usize {
        const s = if (scale == 0) 1 else scale;
        return text.len * char_advance * s;
    }

    /// 白黒のドット列を `scale` 倍で描く（QR コードの描画に使う）。
    ///
    /// `sample` は「(x, y) が黒かどうか」を返す関数。QR モジュール側の型に依存しないため。
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

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn testBuffer(storage: []u16) Framebuffer {
    return Framebuffer.init(storage, 240, 240) catch unreachable;
}

test "範囲外の書き込みは無視され、クリップされる" {
    var storage: [16]u16 = @splat(black);
    var fb = try Framebuffer.init(&storage, 4, 4);

    fb.setPixel(0, 0, white);
    try testing.expectEqual(white, fb.getPixel(0, 0));
    fb.setPixel(10, 10, white); // 範囲外 → 無視
    try testing.expectEqual(black, fb.getPixel(3, 3));

    fb.fillRect(3, 3, 10, 10, blue); // はみ出す → クリップ
    try testing.expectEqual(blue, fb.getPixel(3, 3));
    try testing.expectEqual(black, fb.getPixel(2, 2));
    try testing.expectEqual(blue, storage[15]);
}

test "init はサイズ不足を拒否する" {
    var storage: [4]u16 = @splat(black);
    try testing.expectError(error.BufferTooSmall, Framebuffer.init(&storage, 240, 240));
}

test "文字の描画（'A' の 1 行目は bit2 と bit3）" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    // 'A' の 1 行目は 0x0C（bit2, bit3）
    fb.drawGlyph(0, 0, 'A', white, null, 1);
    try testing.expectEqual(black, fb.getPixel(0, 0));
    try testing.expectEqual(black, fb.getPixel(1, 0));
    try testing.expectEqual(white, fb.getPixel(2, 0));
    try testing.expectEqual(white, fb.getPixel(3, 0));
    try testing.expectEqual(black, fb.getPixel(4, 0));

    // 2 倍で描くと 2×2 ドットになる
    fb.clear(black);
    fb.drawGlyph(0, 0, 'A', white, null, 2);
    try testing.expectEqual(white, fb.getPixel(4, 0));
    try testing.expectEqual(white, fb.getPixel(5, 0));
    try testing.expectEqual(white, fb.getPixel(4, 1));
    // bit2 は x=4〜5、bit3 は x=6〜7 を占める。その次は塗られない
    try testing.expectEqual(white, fb.getPixel(6, 0));
    try testing.expectEqual(black, fb.getPixel(8, 0));
}

test "文字列は 9 ドットずつ進み、幅が計算できる" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    const next = fb.drawText(10, 20, "AB", white, null, 1);
    try testing.expectEqual(@as(usize, 10 + 9 * 2), next);
    try testing.expectEqual(@as(usize, 18), Framebuffer.textWidth("AB", 1));
    try testing.expectEqual(@as(usize, 36), Framebuffer.textWidth("AB", 2));

    // 最初の文字は (10, 20) から描かれる
    try testing.expectEqual(white, fb.getPixel(12, 20)); // 'A' の bit2
}

test "改行つきの文字列と、背景の塗りつぶし" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    const lines = fb.drawTextLines(0, 0, "A\nB", white, black, 1);
    try testing.expectEqual(@as(usize, 2), lines); // "A" と "B"
    try testing.expectEqual(white, fb.getPixel(2, 0)); // 'A'
    try testing.expectEqual(white, fb.getPixel(2, 9)); // 'B' は 9 ドット下

    // 背景を指定すると、字形でない部分も塗られる
    fb.clear(black);
    _ = fb.drawText(0, 0, "A", white, red, 1);
    try testing.expectEqual(red, fb.getPixel(0, 0));
    try testing.expectEqual(white, fb.getPixel(2, 0));
}

test "drawBitmap でドット列を描ける（QR 用の入口）" {
    var storage: [240 * 240]u16 = @splat(black);
    var fb = testBuffer(&storage);

    // 市松模様（2×2 モジュール）を 4 倍で描く
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
    // モジュールの外は触らない
    try testing.expectEqual(black, fb.getPixel(8, 8));
}
