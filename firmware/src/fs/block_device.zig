//! Block device abstraction (reads and writes in 512-byte sectors).
//!
//! On the real board an SPI-driven microSD HAL satisfies this interface; in tests an
//! in-memory implementation (`MemoryDevice`) does. The FAT32 implementation does not
//! know what kind of device it is talking to.
//!
//! **Policy**
//! - The sector size is fixed at 512 bytes (the SD card block length is 512 bytes too).
//! - Transfer lengths must be a multiple of the sector size. Real hardware cannot
//!   read or write partial sectors, so callers assemble remainders into one sector.
//! - Range checks are done by `BlockDevice` itself. Implementations need not carry
//!   their own.
//! - Passing copies by value is fine (the actual state lives in external memory that
//!   `context` points to).
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");

/// Sector size. Matches the SD card block length.
pub const sector_size = 512;

/// Block device errors. Included in the FAT32 error set (`fat32.Error`).
pub const Error = error{
    /// The device does not respond, or a read or write failed
    DeviceFailure,
    /// The sector number is outside the device
    OutOfRange,
    /// The transfer length is zero or not a multiple of the sector size
    InvalidLength,
    /// The device is write-protected
    ReadOnly,
};

/// Sector-granular reads and writes. Implementations are swapped in via `context` + `vtable`.
pub const BlockDevice = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read `buffer.len / sector_size` sectors starting at `lba`.
        readSectors: *const fn (context: *anyopaque, lba: u32, buffer: []u8) Error!void,
        /// Write `data.len / sector_size` sectors starting at `lba`.
        writeSectors: *const fn (context: *anyopaque, lba: u32, data: []const u8) Error!void,
        /// Total number of sectors on the device.
        sectorCount: *const fn (context: *anyopaque) u64,
    };

    /// `buffer.len` must be a multiple of the sector size (`error.InvalidLength`).
    pub fn readSectors(self: BlockDevice, lba: u32, buffer: []u8) Error!void {
        try checkTransfer(lba, buffer.len, self.sectorCount());
        return self.vtable.readSectors(self.context, lba, buffer);
    }

    /// `data.len` must be a multiple of the sector size (`error.InvalidLength`).
    pub fn writeSectors(self: BlockDevice, lba: u32, data: []const u8) Error!void {
        try checkTransfer(lba, data.len, self.sectorCount());
        return self.vtable.writeSectors(self.context, lba, data);
    }

    /// Convenience function that reads one sector.
    pub fn readSector(self: BlockDevice, lba: u32, buffer: *[sector_size]u8) Error!void {
        return self.readSectors(lba, buffer);
    }

    /// Convenience function that writes one sector.
    pub fn writeSector(self: BlockDevice, lba: u32, data: *const [sector_size]u8) Error!void {
        return self.writeSectors(lba, data);
    }

    pub fn sectorCount(self: BlockDevice) u64 {
        return self.vtable.sectorCount(self.context);
    }

    /// Check that a transfer fits within the device. `lba` and the sector count are
    /// computed as u64 (adding as u32 could overflow and miss an out-of-range transfer).
    fn checkTransfer(lba: u32, length: usize, count: u64) Error!void {
        if (length == 0 or length % sector_size != 0) return error.InvalidLength;
        const sectors: u64 = length / sector_size;
        if (@as(u64, lba) + sectors > count) return error.OutOfRange;
    }
};

/// In-memory implementation for tests.
///
/// `storage.len` must be a multiple of the sector size (a remainder is not counted as a sector).
/// Used in place of real hardware, loaded with a real or synthetic image.
pub const MemoryDevice = struct {
    storage: []u8,
    /// Cumulative number of sectors read (so tests can check the number of I/O operations).
    sectors_read: u64 = 0,
    /// Cumulative number of sectors written.
    sectors_written: u64 = 0,

    /// Use existing memory as a device.
    pub fn init(storage: []u8) MemoryDevice {
        return .{ .storage = storage };
    }

    /// Allocate zero-initialized storage and return it. Free it with `deinit`.
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

    /// Build a `BlockDevice` pointing at this device. Do not move `self`
    /// (because `context` points at `self`).
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

test "MemoryDevice reads back what was written" {
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

    // The neighbouring sector is unchanged
    try device.readSector(1, &read_back);
    try std.testing.expectEqualSlices(u8, &zeros, &read_back);
}

test "MemoryDevice reads and writes several sectors at once" {
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

test "MemoryDevice rejects out-of-range transfers and invalid lengths" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 4 * sector_size);
    defer memory.deinit(allocator);
    const device = memory.device();

    var sector: [sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSector(4, &sector));
    try std.testing.expectError(error.OutOfRange, device.writeSector(4, &sector));

    // A transfer that crosses the end
    var two: [2 * sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSectors(3, &two));

    // A length that is not a multiple of the sector size
    var odd: [100]u8 = @splat(0);
    try std.testing.expectError(error.InvalidLength, device.readSectors(0, &odd));
    try std.testing.expectError(error.InvalidLength, device.writeSectors(0, &odd));

    // Zero length
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.InvalidLength, device.readSectors(0, &empty));
}

test "MemoryDevice counts the sectors read and written" {
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

test "MemoryDevice ignores a remainder shorter than the sector size" {
    const allocator = std.testing.allocator;
    var memory = try MemoryDevice.create(allocator, 3 * sector_size + 7);
    defer memory.deinit(allocator);
    const device = memory.device();

    try std.testing.expectEqual(@as(u64, 3), device.sectorCount());
    var sector: [sector_size]u8 = @splat(0);
    try std.testing.expectError(error.OutOfRange, device.readSector(3, &sector));
}

test "A BlockDevice copied by value still points at the same device" {
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
