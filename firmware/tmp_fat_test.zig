//! 一時的な検証ハーネス（mtools との突き合わせ用）。
//!
//! 実イメージ（mkfs.fat が作った FAT32）を読み込み、`src/fs/` の実装で
//! 読み書きして書き戻す。mtools と突き合わせるための道具であり、
//! **完了時に削除する**一時ファイル。
//!
//! 使い方: zig run tmp_fat_test.zig -- <command> <image> [args...]

const std = @import("std");
const block_device = @import("src/fs/block_device.zig");
const fat32 = @import("src/fs/fat32.zig");

const Fat32 = fat32.Fat32;
const Entry = fat32.Entry;

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("harness error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    var iterator = std.process.Args.Iterator.init(init.minimal.args);
    _ = iterator.next(); // argv[0]
    while (iterator.next()) |arg| try args.append(allocator, arg);
    if (args.items.len < 2) {
        std.debug.print("usage: <command> <image> [args]\n", .{});
        return error.Usage;
    }

    const command = args.items[0];
    const image_path = args.items[1];
    const dir = std.Io.Dir.cwd();

    const bytes = try dir.readFileAlloc(io, image_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(bytes);

    var memory = block_device.MemoryDevice.init(bytes);
    const device = memory.device();

    if (std.mem.eql(u8, command, "info")) {
        var volume = try Fat32.mount(device, allocator);
        defer volume.deinit();
        const bpb = volume.bpb;
        std.debug.print(
            "mount: partition={d} spc={d} reserved={d} fats={d} fat_sectors={d} root={d} total={d} clusters={d} mirrored={} fs_info_valid={} free_count={d}\n",
            .{
                bpb.partition_sector,
                bpb.sectors_per_cluster,
                bpb.reserved_sectors,
                bpb.fat_count,
                bpb.sectors_per_fat,
                bpb.root_cluster,
                bpb.total_sectors,
                bpb.cluster_count,
                bpb.mirrored,
                volume.fs_info.valid,
                volume.fs_info.free_count,
            },
        );
        return;
    }

    var volume = try Fat32.mount(device, allocator);
    defer volume.deinit();

    if (std.mem.eql(u8, command, "list")) {
        if (args.items.len < 3) return error.Usage;
        var entry: Entry = .{};
        var walker = try volume.openDir(args.items[2]);
        while (try walker.next(&entry)) {
            std.debug.print(
                "entry: name=\"{s}\" len={d} lfn={} lfn_count={d} attr=0x{X:0>2} size={d} cluster={d} dot={}\n",
                .{
                    entry.nameSlice(),
                    entry.name_len,
                    entry.has_lfn,
                    entry.lfn_count,
                    entry.attr,
                    entry.size,
                    entry.first_cluster,
                    entry.isDot(),
                },
            );
        }
    } else if (std.mem.eql(u8, command, "cat")) {
        if (args.items.len < 4) return error.Usage;
        const data = try volume.readFileAlloc(allocator, args.items[2], 128 * 1024 * 1024);
        defer allocator.free(data);
        try dir.writeFile(io, .{ .sub_path = args.items[3], .data = data });
        std.debug.print("cat: {s} -> {d} bytes\n", .{ args.items[2], data.len });
    } else if (std.mem.eql(u8, command, "put")) {
        if (args.items.len < 4) return error.Usage;
        const data = try dir.readFileAlloc(io, args.items[3], allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(data);
        try volume.writeFile(args.items[2], data);
        std.debug.print("put: {s} <- {d} bytes\n", .{ args.items[2], data.len });
    } else if (std.mem.eql(u8, command, "putpat")) {
        // putpat <image> <path> <len> <seed> <pattern-out>
        if (args.items.len < 6) return error.Usage;
        const length = try std.fmt.parseInt(usize, args.items[3], 10);
        const seed = try std.fmt.parseInt(u32, args.items[4], 10);
        const data = try allocator.alloc(u8, length);
        defer allocator.free(data);
        fillPattern(data, seed);
        try volume.writeFile(args.items[2], data);
        try dir.writeFile(io, .{ .sub_path = args.items[5], .data = data });
        std.debug.print("putpat: {s} <- {d} bytes (seed {d})\n", .{ args.items[2], data.len, seed });
    } else if (std.mem.eql(u8, command, "rm")) {
        try volume.deleteFile(args.items[2]);
        std.debug.print("rm: {s}\n", .{args.items[2]});
    } else if (std.mem.eql(u8, command, "mv")) {
        if (args.items.len < 4) return error.Usage;
        try volume.rename(args.items[2], args.items[3]);
        std.debug.print("mv: {s} -> {s}\n", .{ args.items[2], args.items[3] });
    } else if (std.mem.eql(u8, command, "stat")) {
        const entry = try volume.stat(args.items[2]);
        std.debug.print(
            "stat: name=\"{s}\" lfn={} lfn_count={d} size={d} cluster={d} dir={} label={} index={d}\n",
            .{
                entry.nameSlice(),
                entry.has_lfn,
                entry.lfn_count,
                entry.size,
                entry.first_cluster,
                entry.isDirectory(),
                entry.isVolumeLabel(),
                entry.index,
            },
        );
    } else if (std.mem.eql(u8, command, "exists")) {
        const found = try volume.exists(args.items[2]);
        std.debug.print("exists: {s} = {}\n", .{ args.items[2], found });
    } else if (std.mem.eql(u8, command, "fsck")) {
        // 実装とは独立に、生のセクタから不変条件を確かめる
        try checkInvariants(memory.storage, &volume);
    } else {
        std.debug.print("unknown command: {s}\n", .{command});
        return error.Usage;
    }

    try dir.writeFile(io, .{ .sub_path = image_path, .data = bytes });
}

/// 実装とは独立に、イメージの不変条件を検査する（簡易 fsck）。
fn checkInvariants(storage: []const u8, volume: *const Fat32) !void {
    const bpb = volume.bpb;
    const total_free = try countFreeClusters(storage, bpb);
    std.debug.print("check: free_clusters={d} fs_info_free={d} fs_info_ok={}\n", .{
        total_free,
        volume.fs_info.free_count,
        volume.fs_info.valid,
    });

    // FAT 2 枚の一致
    const fat1 = @as(usize, bpb.fat_sector) * 512;
    const fat2 = fat1 + @as(usize, bpb.sectors_per_fat) * 512;
    const fat_bytes = @as(usize, bpb.sectors_per_fat) * 512;
    const same = std.mem.eql(u8, storage[fat1 .. fat1 + fat_bytes], storage[fat2 .. fat2 + fat_bytes]);
    std.debug.print("check: fat_copies_identical={}\n", .{same});
    if (!same) return error.FatCopiesDiffer;
    if (volume.fs_info.valid and volume.fs_info.free_count != total_free) return error.FreeCountMismatch;
}

fn countFreeClusters(storage: []const u8, bpb: fat32.Bpb) !u32 {
    var count: u32 = 0;
    var cluster: u32 = 2;
    const fat_start = @as(usize, bpb.fat_sector) * 512;
    while (cluster <= bpb.maxCluster()) : (cluster += 1) {
        const offset = fat_start + @as(usize, cluster) * 4;
        const value = std.mem.readInt(u32, storage[offset..][0..4], .little) & 0x0FFFFFFF;
        if (value == 0) count += 1;
    }
    return count;
}

fn fillPattern(out: []u8, seed: u32) void {
    var state = seed;
    for (out) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 16);
    }
}
