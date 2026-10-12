//! ブロックデバイスの抽象（512 バイトセクタ単位の読み書き）。
//!
//! 実機では microSD を SPI で駆動する HAL が、テストではメモリ上の実装
//! （`MemoryDevice`）がこのインターフェースを満たす。FAT32 の実装はデバイスの
//! 種類を知らない。
//!
//! **方針**
//! - セクタ長は 512 バイト固定（SD カードのブロック長も 512 バイト）。
//! - 転送長はセクタ長の倍数でなければならない。部分セクタの読み書きは実機で
//!   できないため、端数は呼び出し側が 1 セクタに組み立てる。
//! - 範囲チェックは `BlockDevice` 側で行う。各実装が自前で持つ必要はない。
//! - 値渡しのコピーで受け渡してよい（実体は `context` が指す外部のメモリにある）。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");

/// セクタ長。SD カードのブロック長に合わせる。
pub const sector_size = 512;

/// ブロックデバイスのエラー。FAT32 側のエラー集合（`fat32.Error`）に含まれる。
pub const Error = error{
    /// デバイスが応答しない、または読み書きに失敗した
    DeviceFailure,
    /// セクタ番号がデバイスの範囲外
    OutOfRange,
    /// 転送長が 0、またはセクタ長の倍数でない
    InvalidLength,
    /// 書き込み禁止のデバイス
    ReadOnly,
};

/// セクタ単位の読み書き。実装は `context` + `vtable` で差し替える。
pub const BlockDevice = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// `lba` から `buffer.len / sector_size` セクタを読む。
        readSectors: *const fn (context: *anyopaque, lba: u32, buffer: []u8) Error!void,
        /// `lba` から `data.len / sector_size` セクタを書く。
        writeSectors: *const fn (context: *anyopaque, lba: u32, data: []const u8) Error!void,
        /// デバイスの総セクタ数。
        sectorCount: *const fn (context: *anyopaque) u64,
    };

    /// `buffer.len` はセクタ長の倍数でなければならない（`error.InvalidLength`）。
    pub fn readSectors(self: BlockDevice, lba: u32, buffer: []u8) Error!void {
        try checkTransfer(lba, buffer.len, self.sectorCount());
        return self.vtable.readSectors(self.context, lba, buffer);
    }

    /// `data.len` はセクタ長の倍数でなければならない（`error.InvalidLength`）。
    pub fn writeSectors(self: BlockDevice, lba: u32, data: []const u8) Error!void {
        try checkTransfer(lba, data.len, self.sectorCount());
        return self.vtable.writeSectors(self.context, lba, data);
    }

    /// 1 セクタを読む便宜関数。
    pub fn readSector(self: BlockDevice, lba: u32, buffer: *[sector_size]u8) Error!void {
        return self.readSectors(lba, buffer);
    }

    /// 1 セクタを書く便宜関数。
    pub fn writeSector(self: BlockDevice, lba: u32, data: *const [sector_size]u8) Error!void {
        return self.writeSectors(lba, data);
    }

    pub fn sectorCount(self: BlockDevice) u64 {
        return self.vtable.sectorCount(self.context);
    }

    /// 転送がデバイスの範囲に収まるかを調べる。`lba` とセクタ数は u64 で計算する
    /// （u32 の加算が溢れると範囲外を見逃すため）。
    fn checkTransfer(lba: u32, length: usize, count: u64) Error!void {
        if (length == 0 or length % sector_size != 0) return error.InvalidLength;
        const sectors: u64 = length / sector_size;
        if (@as(u64, lba) + sectors > count) return error.OutOfRange;
    }
};

/// テスト用のインメモリ実装。
///
/// `storage.len` はセクタ長の倍数であること（端数はセクタとして数えない）。
/// 実機の代わりに、実イメージや合成イメージを載せて使う。
pub const MemoryDevice = struct {
    storage: []u8,
    /// 読み出したセクタ数の累計（テストで I/O の回数を確認するため）。
    sectors_read: u64 = 0,
    /// 書き込んだセクタ数の累計。
    sectors_written: u64 = 0,

    /// 既存のメモリをデバイスとして使う。
    pub fn init(storage: []u8) MemoryDevice {
        return .{ .storage = storage };
    }

    /// ゼロ初期化したストレージを確保して返す。`deinit` で解放する。
    pub fn create(allocator: std.mem.Allocator, byte_len: usize) std.mem.Allocator.Error!MemoryDevice {
        const storage = try allocator.alloc(u8, byte_len);
        @memset(storage, 0);
        return .{ .storage = storage };
    }

    pub fn deinit(self: *MemoryDevice, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.storage = self.storage[0..0];
        self.sectors_read = 0;
        self.sectors_written = 0;
    }

    /// このデバイスを指す `BlockDevice` を作る。`self` は動かさないこと
    /// （`context` が `self` を指すため）。
    pub fn device(self: *MemoryDevice) BlockDevice {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = BlockDevice.VTable{
        .readSectors = readSectors,
        .writeSectors = writeSectors,
        .sectorCount = sectorCount,
    };

    fn readSectors(context: *anyopaque, lba: u32, buffer: []u8) Error!void {
        const self: *MemoryDevice = @ptrCast(@alignCast(context));
        const start = @as(usize, lba) * sector_size;
        @memcpy(buffer, self.storage[start .. start + buffer.len]);
        self.sectors_read += buffer.len / sector_size;
    }

    fn writeSectors(context: *anyopaque, lba: u32, data: []const u8) Error!void {
        const self: *MemoryDevice = @ptrCast(@alignCast(context));
        const start = @as(usize, lba) * sector_size;
        @memcpy(self.storage[start .. start + data.len], data);
        self.sectors_written += data.len / sector_size;
    }

    fn sectorCount(context: *anyopaque) u64 {
        const self: *MemoryDevice = @ptrCast(@alignCast(context));
        return self.storage.len / sector_size;
    }
};

test "MemoryDevice は書いたものを読み戻す" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 4 * sector_size);
    defer memory.deinit(allocator);
    const device = memory.device();

    var written: [sector_size]u8 = @splat(0);
    for (&written, 0..) |*byte, i| byte.* = @intCast(i % 251);
    try device.writeSector(2, &written);

    const zeros: [sector_size]u8 = @splat(0);
    var read_back: [sector_size]u8 = @splat(0);
    try device.readSector(2, &read_back);
    try std.testing.expectEqualSlices(u8, &written, &read_back);

    // 隣のセクタは変わらない
    try device.readSector(1, &read_back);
    try std.testing.expectEqualSlices(u8, &zeros, &read_back);
}

test "MemoryDevice は複数セクタをまとめて読み書きできる" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 8 * sector_size);
    defer memory.deinit(allocator);
    const device = memory.device();

    var written: [3 * sector_size]u8 = @splat(0);
    for (&written, 0..) |*byte, i| byte.* = @intCast((i * 7) % 256);
    try device.writeSectors(3, &written);

    var read_back: [3 * sector_size]u8 = @splat(0);
    try device.readSectors(3, &read_back);
    try std.testing.expectEqualSlices(u8, &written, &read_back);
}

test "MemoryDevice は範囲外と不正な長さを拒否する" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 4 * sector_size);
    defer memory.deinit(allocator);
    const device = memory.device();

    var sector: [sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSector(4, &sector));
    try std.testing.expectError(error.OutOfRange, device.writeSector(4, &sector));

    // 端をまたぐ転送
    var two: [2 * sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSectors(3, &two));

    // セクタ長の倍数でない長さ
    var odd: [100]u8 = @splat(0);
    try std.testing.expectError(error.InvalidLength, device.readSectors(0, &odd));
    try std.testing.expectError(error.InvalidLength, device.writeSectors(0, &odd));

    // 長さ 0
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.InvalidLength, device.readSectors(0, &empty));
}

test "MemoryDevice は読み書きしたセクタ数を数える" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 4 * sector_size);
    defer memory.deinit(allocator);
    const device = memory.device();

    var buffer: [2 * sector_size]u8 = @splat(0);
    try device.readSectors(0, &buffer);
    var sector: [sector_size]u8 = @splat(0);
    try device.writeSector(1, &sector);

    try std.testing.expectEqual(@as(u64, 2), memory.sectors_read);
    try std.testing.expectEqual(@as(u64, 1), memory.sectors_written);
    try std.testing.expectEqual(@as(u64, 4), device.sectorCount());
}

test "MemoryDevice はセクタ長に満たない端数を無視する" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 3 * sector_size + 7);
    defer memory.deinit(allocator);
    const device = memory.device();

    try std.testing.expectEqual(@as(u64, 3), device.sectorCount());
    var sector: [sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSector(3, &sector));
}

test "BlockDevice は値渡しのコピーでも同じデバイスを指す" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 2 * sector_size);
    defer memory.deinit(allocator);

    const original = memory.device();
    const copy = original;

    var written: [sector_size]u8 = @splat(0x5A);
    try copy.writeSector(1, &written);

    var read_back: [sector_size]u8 = @splat(0);
    try original.readSector(1, &read_back);
    try std.testing.expectEqualSlices(u8, &written, &read_back);
}
