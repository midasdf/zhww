//! 画面（240×240）のレイアウト。
//!
//! 実機の LCD に何をどう出すかを、ハードウェアから切り離して組み立てる層。
//! PC 上で `framebuffer` と一緒に走らせれば、画像として確認できる
//! （開発用 CLI の `screen` コマンド）。
//!
//! 画面の文字は **ASCII** で扱う（240×240 に日本語を出すにはフォント同梱が必要なため。
//! 方針は [docs/08-rp2350-pizero.md] を参照）。

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

/// モノクロのドット列（QR コードなど）。1 バイト 1 モジュール（0 以外は黒）。
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
    /// 画面下部に出す QR（あれば）。
    qr: ?Bitmap = null,
    footer_left: []const u8 = "",
    footer_right: []const u8 = "",

    /// 描画する。`fb` は 240×240 を想定するが、他の大きさでも破綻しない。
    pub fn render(self: *const Screen, fb: *Framebuffer) void {
        fb.clear(background);

        // タイトル
        fb.fillRect(0, 0, fb.width, title_height, title_background);
        const title_scale: usize = if (fb.width >= 200) 2 else 1;
        const title_width = Framebuffer.textWidth(self.title, title_scale);
        const title_x = if (title_width < fb.width) (fb.width - title_width) / 2 else margin;
        _ = fb.drawText(title_x, 5, self.title, framebuffer.white, null, title_scale);

        // 本文
        var y: usize = title_height + margin;
        for (self.lines) |line| {
            y = drawLine(fb, y, line);
            if (y >= fb.height - footer_height) return self.drawFooter(fb);
        }

        // 警告（赤字）
        for (self.warnings) |warning| {
            y = wrapText(fb, margin, y, warning, warning_color, 1) + 2;
            if (y >= fb.height - footer_height) return self.drawFooter(fb);
        }

        // QR（フッターの上に、中央寄せで最大サイズ）
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

                // 白地（静穏域）
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

/// 幅に収まるように折り返して描く。描いた次の y を返す。
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
        // 収まる範囲に空白があれば、そこで折る（単語の途中で切らない）
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

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn testFramebuffer(storage: []u16) Framebuffer {
    return Framebuffer.init(storage, 240, 240) catch unreachable;
}

test "タイトル・本文・フッターが描かれる" {
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

    // タイトルバーとフッターが塗られている
    try testing.expectEqual(title_background, fb.getPixel(0, 0));
    try testing.expectEqual(footer_background, fb.getPixel(0, 239));

    // 本文に何か描かれている（タイトルバーの下）
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

test "長い値は折り返され、画面外にはみ出さない" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    const screen = Screen{
        .title = "ADDRESS",
        .lines = &.{.{
            .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" ++ "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
        }},
    };
    screen.render(&fb);

    // 右端の 1 列と下端のフッター内以外は背景のまま（＝はみ出していない）
    // 文字が右端を越えないことを、右端 4 ドットの本文領域で確認する
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

test "QR が描かれ、黒モジュールの数が合う" {
    var storage: [240 * 240]u16 = @splat(0);
    var fb = testFramebuffer(&storage);

    // 3×3 で四隅と中心が黒のドット列
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

    // 画面に黒いドットが描かれている（QR の黒モジュール × 拡大率^2）
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

test "警告は赤で描かれる" {
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
