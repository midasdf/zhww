//! Measured fixed-buffer workspace. No heap fallback. Not thread-safe.
//! Buffer and wrapper must remain at stable addresses while allocator/results live.
//! Parsed/public request data only: do not allocate private keys here.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Workspace = struct {
    fba: std.heap.FixedBufferAllocator,
    peak: usize = 0,
    failures: usize = 0,

    pub fn init(buffer: []u8) Workspace {
        return .{ .fba = .init(buffer) };
    }

    pub fn allocator(self: *Workspace) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    /// Invalidates EVERY outstanding borrow/result. Call only after publication or
    /// discarding outputs and after all parser arenas have been destroyed. Also clears
    /// data that a fixed-buffer free could not reclaim (non-LIFO fragmentation).
    pub fn reset(self: *Workspace) void {
        std.crypto.secureZero(u8, self.fba.buffer);
        self.fba.end_index = 0;
        self.peak = 0;
        self.failures = 0;
    }

    fn observe(self: *Workspace, success: bool) void {
        if (!success) self.failures +|= 1;
        self.peak = @max(self.peak, self.fba.end_index);
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        // FBA's addition must never overflow even for hostile maximum-sized requests.
        if (len > self.fba.buffer.len - self.fba.end_index) {
            self.observe(false);
            return null;
        }
        const result = self.fba.allocator().rawAlloc(len, alignment, ra);
        self.observe(result != null);
        return result;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) bool {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        if (len > memory.len and len - memory.len > self.fba.buffer.len - self.fba.end_index) {
            self.observe(false);
            return false;
        }
        const result = self.fba.allocator().rawResize(memory, alignment, len, ra);
        self.observe(result);
        return result;
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: Alignment, len: usize, ra: usize) ?[*]u8 {
        return if (resize(raw, memory, alignment, len, ra)) memory.ptr else null;
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *Workspace = @ptrCast(@alignCast(raw));
        self.fba.allocator().rawFree(memory, alignment, ra);
    }
};

test "workspace tracks alignment/growth peak and erases all backing bytes on reset" {
    var memory: [256]u8 align(64) = @splat(0xab);
    var workspace = Workspace.init(&memory);
    const a = workspace.allocator();
    const first = try a.alloc(u8, 3);
    const second = try a.alloc(u64, 2);
    try std.testing.expect(workspace.peak >= first.len + second.len * @sizeOf(u64));
    try std.testing.expect(a.resize(second, 4));
    const peak = workspace.peak;
    a.free(second.ptr[0..4]);
    a.free(first);
    try std.testing.expectEqual(peak, workspace.peak);
    workspace.reset();
    try std.testing.expectEqual(@as(usize, 0), workspace.fba.end_index);
    try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0)), &memory);
    try std.testing.expectEqual(@as(usize, 0), workspace.peak);
}

test "workspace refuses huge lengths and failed growth without overflow or fallback" {
    var memory: [32]u8 align(64) = undefined;
    var workspace = Workspace.init(&memory);
    defer workspace.reset();
    const a = workspace.allocator();
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, std.math.maxInt(usize)));
    const first = try a.alloc(u8, 16);
    try std.testing.expect(!a.resize(first, std.math.maxInt(usize)));
    try std.testing.expect(a.remap(first, 24) != null);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 16));
    try std.testing.expectEqual(@as(usize, 24), workspace.peak);
    try std.testing.expectEqual(@as(usize, 3), workspace.failures);
}
