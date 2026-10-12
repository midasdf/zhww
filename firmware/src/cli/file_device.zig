//! ファイルをブロックデバイスとして扱う実装。
//!
//! **host（PC）専用**。microSD の実物が無くても、FAT32 のイメージファイルに対して
//! カード上の操作を再現できるようにするためのもの（開発用 CLI の `card` コマンドで使う）。
//! 実機では SPI / SDIO 経由の実装に差し替える（同じ `BlockDevice` の口を使う）。
//!
//! 読み書きは位置指定（`readPositionalAll` / `writePositionalAll`）で行うので、
//! ファイル位置に依存しない。

const std = @import("std");
const block_device = @import("zhww").block_device;

pub const sector_size = block_device.sector_size;

pub const FileDevice = struct {
    file: std.Io.File,
    io: std.Io,
    sectors: u64,

    pub fn init(file: std.Io.File, io: std.Io, size_bytes: u64) FileDevice {
        return .{
            .file = file,
            .io = io,
            .sectors = size_bytes / sector_size,
        };
    }

    /// `BlockDevice` として使うための口を作る。
    pub fn device(self: *FileDevice) block_device.BlockDevice {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = block_device.BlockDevice.VTable{
        .readSectors = readSectors,
        .writeSectors = writeSectors,
        .sectorCount = sectorCount,
    };

    fn readSectors(context: *anyopaque, lba: u32, buffer: []u8) block_device.Error!void {
        const self: *FileDevice = @ptrCast(@alignCast(context));
        const offset = @as(u64, lba) * sector_size;
        const read = std.Io.File.readPositionalAll(self.file, self.io, buffer, offset) catch {
            return error.DeviceFailure;
        };
        if (read != buffer.len) return error.DeviceFailure;
    }

    fn writeSectors(context: *anyopaque, lba: u32, data: []const u8) block_device.Error!void {
        const self: *FileDevice = @ptrCast(@alignCast(context));
        const offset = @as(u64, lba) * sector_size;
        std.Io.File.writePositionalAll(self.file, self.io, data, offset) catch {
            return error.DeviceFailure;
        };
    }

    fn sectorCount(context: *anyopaque) u64 {
        const self: *FileDevice = @ptrCast(@alignCast(context));
        return self.sectors;
    }
};
