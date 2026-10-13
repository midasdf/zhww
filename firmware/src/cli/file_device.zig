//! A block device backed by a file.
//!
//! **Host (PC) only.** Lets you reproduce the on-card operations against a FAT32
//! image file without a real microSD card (used by the developer CLI's `card` command).
//! On the device it is swapped for an SPI / SDIO implementation (the same `BlockDevice`
//! interface).
//!
//! Reads and writes are positional (`readPositionalAll` / `writePositionalAll`),
//! so they do not depend on the file position.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

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

    /// Build the `BlockDevice` handle for this file device.
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
