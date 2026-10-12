//! フレームバッファ（RGB565）を PNG に書き出す。
//!
//! **開発用 CLI 専用**（ファームウェアには含めない）。実機の画面を PC 上で確認するために使う。
//!
//! 圧縮は行わず、zlib の「無圧縮ブロック（stored）」だけで PNG を作る。
//! そのため外部ライブラリが不要で、出力が決定的になる（テストしやすい）。

const std = @import("std");
const Allocator = std.mem.Allocator;

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };

/// RGB565 のフレームバッファを PNG として書き出す。
pub fn writeRgb565(
    writer: anytype,
    allocator: Allocator,
    pixels: []const u16,
    width: usize,
    height: usize,
) !void {
    if (pixels.len < width * height) return error.BufferTooSmall;

    try writer.writeAll(&signature);

    // IHDR: 8bit / カラータイプ 2（RGB）/ 圧縮 0 / フィルタ 0 / インタレース 0
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    try writeChunk(writer, "IHDR", &ihdr);

    // 生データ（各行の先頭にフィルタ種別 0 を置く）
    const stride = 1 + width * 3;
    const raw = try allocator.alloc(u8, stride * height);
    defer allocator.free(raw);
    for (0..height) |y| {
        const row = raw[y * stride .. (y + 1) * stride];
        row[0] = 0;
        for (0..width) |x| {
            const color = pixels[y * width + x];
            const r: u8 = @intCast(((color >> 11) & 0x1F) * 255 / 31);
            const g: u8 = @intCast(((color >> 5) & 0x3F) * 255 / 63);
            const b: u8 = @intCast((color & 0x1F) * 255 / 31);
            row[1 + x * 3] = r;
            row[2 + x * 3] = g;
            row[3 + x * 3] = b;
        }
    }

    // zlib ストリーム（ヘッダ + 無圧縮ブロック + Adler-32）
    const compressed = try allocator.alloc(u8, raw.len + raw.len / 65535 * 5 + 16);
    defer allocator.free(compressed);
    var z: usize = 0;
    compressed[z] = 0x78; // CMF: deflate, 32K window
    z += 1;
    compressed[z] = 0x01; // FLG（チェックビット。無圧縮）
    z += 1;

    var offset: usize = 0;
    while (offset < raw.len) {
        const take = @min(@as(usize, 65535), raw.len - offset);
        const is_last = offset + take == raw.len;
        compressed[z] = if (is_last) 1 else 0; // BFINAL / BTYPE=00（無圧縮）
        z += 1;
        std.mem.writeInt(u16, compressed[z..][0..2], @intCast(take), .little);
        z += 2;
        std.mem.writeInt(u16, compressed[z..][0..2], ~@as(u16, @intCast(take)), .little);
        z += 2;
        @memcpy(compressed[z .. z + take], raw[offset .. offset + take]);
        z += take;
        offset += take;
    }
    std.mem.writeInt(u32, compressed[z..][0..4], adler32(raw), .big);
    z += 4;

    try writeChunk(writer, "IDAT", compressed[0..z]);
    try writeChunk(writer, "IEND", &.{});
}

fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(data.len), .big);
    try writer.writeAll(&length);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var checksum: [4]u8 = undefined;
    std.mem.writeInt(u32, &checksum, crc.final(), .big);
    try writer.writeAll(&checksum);
}

fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "PNG の構造（シグネチャ・IHDR・IEND・CRC）" {
    var buffer: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    const pixels = [_]u16{ 0xF800, 0x07E0, 0x001F, 0xFFFF };
    try writeRgb565(&stream, testing.allocator, &pixels, 2, 2);

    const out = stream.buffered();
    try testing.expectEqualSlices(u8, &signature, out[0..8]);

    // 先頭チャンクは IHDR（長さ 13）
    try testing.expectEqualSlices(u8, "IHDR", out[12..16]);
    try testing.expectEqual(@as(u32, 13), std.mem.readInt(u32, out[8..12], .big));
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[16..20], .big)); // 幅
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, out[20..24], .big)); // 高さ

    // IHDR の CRC を検算する
    var crc = std.hash.Crc32.init();
    crc.update(out[12..29]);
    try testing.expectEqual(crc.final(), std.mem.readInt(u32, out[29..33], .big));

    // 末尾は IEND
    try testing.expectEqualSlices(u8, "IEND", out[out.len - 8 .. out.len - 4]);
}

test "無圧縮 zlib ストリームと Adler-32 が正しい" {
    var buffer: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);

    const pixels: [16]u16 = @splat(0x0000);
    try writeRgb565(&stream, testing.allocator, &pixels, 4, 4);
    const out = stream.buffered();

    // IDAT チャンクを探す
    var index: usize = 8;
    var idat: ?[]const u8 = null;
    while (index < out.len) {
        const length = std.mem.readInt(u32, out[index..][0..4], .big);
        const kind = out[index + 4 .. index + 8];
        if (std.mem.eql(u8, kind, "IDAT")) {
            idat = out[index + 8 .. index + 8 + length];
            break;
        }
        index += 12 + length;
    }
    const data = idat orelse return error.TestUnexpectedResult;

    // zlib ヘッダ
    try testing.expectEqual(@as(u8, 0x78), data[0]);
    try testing.expectEqual(@as(u8, 0x01), data[1]);

    // 無圧縮ブロック: [BFINAL/BTYPE 1 バイト][LEN 2][NLEN 2][生データ]
    const block_length = std.mem.readInt(u16, data[3..5], .little);
    try testing.expectEqual(@as(u16, 52), block_length); // 4 行 × (1 + 4*3)
    try testing.expectEqual(~@as(u16, 52), std.mem.readInt(u16, data[5..7], .little)); // 長さの補数

    // Adler-32（末尾 4 バイト）を検算する
    const raw = data[7 .. 7 + block_length];
    const expected = adler32(raw);
    try testing.expectEqual(expected, std.mem.readInt(u32, data[7 + block_length ..][0..4], .big));
}

test "小さすぎるバッファは拒否する" {
    var buffer: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buffer);
    const pixels: [3]u16 = @splat(0x0000);
    try testing.expectError(
        error.BufferTooSmall,
        writeRgb565(&stream, testing.allocator, &pixels, 2, 2),
    );
}
