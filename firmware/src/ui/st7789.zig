//! ST7789（240×240 IPS LCD）のドライバ。
//!
//! Waveshare の 1.3inch LCD HAT（型番 SKU:14972）に載っているコントローラ。
//!
//! **設計**: 実際の配線（SPI・DC・CS・RST・バックライト）は `Transport` として外から渡す。
//! こうしておくと、実機が無くても**モックの転送層**でコマンド列を検証できる。
//! RP2350 側の実装は `platform/rp2350/` に置く。
//!
//! 初期化シーケンスは ST7789 の一般的な 240×240 向けの値を使っている。
//! **実機ではパネル個別の調整が必要になる可能性がある**（ポーチングやガンマ）。
//! 表示が乱れる場合は [docs/08-rp2350-pizero.md] の手順で 1 つずつ確認する。

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const framebuffer = @import("framebuffer.zig");

pub const width = 240;
pub const height = 240;

// コマンド（ST7789 データシート）
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

/// 画面の向き。
pub const Rotation = enum(u8) {
    /// 0 度（左上が原点）
    deg0 = 0x00,
    /// 90 度
    deg90 = 0x60,
    /// 180 度
    deg180 = 0xC0,
    /// 270 度
    deg270 = 0xA0,
};

/// 転送層。SPI と制御ピンをまとめたもの。
///
/// 実装側が用意する関数:
/// - `writeAll(bytes)`: SPI へ送る
/// - `setDataMode(is_data)`: DC ピン（false = コマンド、true = データ）
/// - `setChipSelect(selected)`: CS ピン
/// - `setReset(high)`: RST ピン
/// - `setBacklight(on)`: バックライト
/// - `delayMs(ms)`: 待つ
pub fn Driver(comptime Transport: type) type {
    return struct {
        transport: Transport,
        x_offset: u16 = 0,
        y_offset: u16 = 0,

        const Self = @This();

        /// 画面を初期化する。
        pub fn init(self: *Self) !void {
            self.transport.setChipSelect(true);
            self.transport.setDataMode(true);

            // ハードウェアリセット
            self.transport.setReset(false);
            self.transport.delayMs(10);
            self.transport.setReset(true);
            self.transport.delayMs(120);

            try self.command(cmd_swreset, &.{});
            self.transport.delayMs(150);

            try self.command(cmd_slpout, &.{});
            self.transport.delayMs(120);

            // 色の並びとフレームレート
            try self.command(cmd_colmod, &[_]u8{0x55}); // 16bit/pixel（RGB565）
            try self.command(cmd_madctl, &[_]u8{0x00});

            // ポーチング・電源・ガンマ（一般的な 240×240 向けの値）
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

        /// 画面の向きを変える（表示領域も入れ替える）。
        pub fn setRotation(self: *Self, rotation: Rotation) !void {
            const value: u8 = switch (rotation) {
                .deg0 => 0x00,
                .deg90 => 0x60,
                .deg180 => 0xC0,
                .deg270 => 0xA0,
            };
            try self.command(cmd_madctl, &[_]u8{value});

            // 240×240 なので 90/270 度でもオフセットは 0
            self.x_offset = 0;
            self.y_offset = 0;
        }

        /// 描画範囲を指定する（両端を含む）。
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

        /// ピクセルを書き込む（指定範囲の続きから）。RGB565 を上位バイト先で送る。
        pub fn writePixels(self: *Self, pixels: []const u16) !void {
            try self.commandStart(cmd_ramwr);
            for (pixels) |pixel| {
                const bytes = [_]u8{ @intCast(pixel >> 8), @intCast(pixel & 0xFF) };
                self.transport.writeAll(&bytes);
            }
            try self.commandEnd();
        }

        /// フレームバッファ全体を送る。
        pub fn drawFramebuffer(self: *Self, fb: *const framebuffer.Framebuffer) !void {
            if (fb.width != width or fb.height != height) return error.InvalidEncoding;
            try self.setWindow(0, 0, width - 1, height - 1);
            try self.writePixels(fb.pixels);
        }

        /// 1 つのコマンドとデータを送る。
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

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// 送った内容を記録するモックの転送層。
pub const MockTransport = struct {
    /// 送った内容（コマンドは `!`、データはそのまま）を 1 本の列にしたもの。
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

test "初期化で期待したコマンドが順に出る" {
    var transport = MockTransport{};
    var driver = Driver(MockTransport){ .transport = transport };
    try driver.init();
    transport = driver.transport;

    // ソフトウェアリセット → スリープ解除 → 色形式（RGB565）→ 表示オン
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_swreset }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_slpout }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_colmod, 'D', 0x55 }));
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_dispon }));

    // リセットは一度下げてから上げる
    try testing.expect(transport.reset_high);
    try testing.expect(transport.backlight);
    try testing.expect(transport.delay_count >= 4);

    // コマンドの後は必ずデータモードに戻る（最後の状態）
    try testing.expect(transport.data_mode);
}

test "ウィンドウ指定は 4 バイトずつ上位バイト先で出る" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.setWindow(10, 20, 30, 40);
    const transport = driver.transport;

    // CASET（列）: 10 → 30
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_caset, 'D', 0x00, 0x0A, 0x00, 0x1E }));
    // RASET（行）: 20 → 40
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_raset, 'D', 0x00, 0x14, 0x00, 0x28 }));
}

test "範囲外のウィンドウは拒否する" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try testing.expectError(error.InvalidEncoding, driver.setWindow(0, 0, 240, 239));
    try testing.expectError(error.InvalidEncoding, driver.setWindow(10, 10, 5, 20));
}

test "ピクセルは上位バイト先（RGB565）で送られる" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.writePixels(&[_]u16{ 0xF800, 0x07E0, 0x001F });
    const transport = driver.transport;

    // RAMWR の後に 6 バイト
    try testing.expect(transport.contains(&[_]u8{
        'C', cmd_ramwr, 'D', 0xF8, 0x00, 0x07, 0xE0, 0x00, 0x1F,
    }));
}

test "フレームバッファ全体を送ると 240×240 ピクセル分になる" {
    var storage: [width * height]u16 = @splat(0x1234);
    var fb = try framebuffer.Framebuffer.init(&storage, width, height);
    fb.setPixel(0, 0, 0xFFFF);

    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.drawFramebuffer(&fb);
    const transport = driver.transport;

    // 先頭は (0,0) の白
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_ramwr, 'D', 0xFF, 0xFF }));
    // ウィンドウは全画面
    try testing.expect(transport.contains(&[_]u8{ 'C', cmd_caset, 'D', 0x00, 0x00, 0x00, 0xEF }));

    // 大きさが違うフレームバッファは拒否する
    var small: [16]u16 = @splat(0);
    var small_fb = try framebuffer.Framebuffer.init(&small, 4, 4);
    try testing.expectError(error.InvalidEncoding, driver.drawFramebuffer(&small_fb));
}

test "向きを変えると MADCTL が更新される" {
    var driver = Driver(MockTransport){ .transport = .{} };
    try driver.setRotation(.deg90);
    try testing.expect(driver.transport.contains(&[_]u8{ 'C', cmd_madctl, 'D', 0x60 }));
    try driver.setRotation(.deg270);
    try testing.expect(driver.transport.contains(&[_]u8{ 'C', cmd_madctl, 'D', 0xA0 }));
}
