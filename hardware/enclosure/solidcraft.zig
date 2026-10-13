//! A small writer for SolidCraft command scripts (`{"commands": [...]}`), the format
//! `solidcraft-cli run` and the SolidCraft app open. `case.zig` describes the enclosure with it.
//!
//! Every helper emits exactly one SolidCraft command, under the command's own name and with its
//! own parameter names (see `solidcraft-cli commands`), so the generated script reads like the
//! timeline the app shows. Numbers are written with at most three decimals, which keeps the
//! committed scripts stable and diffable.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: CERN-OHL-S-2.0

const std = @import("std");

pub const Vec3 = [3]f64;

/// A number as JSON: at most three decimals, trailing zeros dropped (`12`, `0.4`, `-3.175`).
pub const Num = struct {
    v: f64,

    pub fn format(self: Num, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const scaled = @round(self.v * 1000.0);
        const milli: i64 = @intFromFloat(if (scaled == 0) 0 else scaled);
        const sign = if (milli < 0) "-" else "";
        const abs: u64 = @abs(milli);
        const whole = abs / 1000;
        var frac = abs % 1000;
        if (frac == 0) return w.print("{s}{d}", .{ sign, whole });
        var digits: usize = 3;
        while (frac % 10 == 0) : (digits -= 1) frac /= 10;
        try w.print("{s}{d}.", .{ sign, whole });
        switch (digits) {
            1 => try w.print("{d}", .{frac}),
            2 => try w.print("{d:0>2}", .{frac}),
            else => try w.print("{d:0>3}", .{frac}),
        }
    }
};

pub fn n(v: f64) Num {
    return .{ .v = v };
}

pub const P3 = struct {
    p: Vec3,

    pub fn format(self: P3, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("[{f}, {f}, {f}]", .{ n(self.p[0]), n(self.p[1]), n(self.p[2]) });
    }
};

pub fn p3(x: f64, y: f64, z: f64) P3 {
    return .{ .p = .{ x, y, z } };
}

/// A list of points, as a JSON array (fillet and chamfer edge picks).
pub const Points = struct {
    items: []const Vec3,

    pub fn format(self: Points, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("[");
        for (self.items, 0..) |p, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("{f}", .{P3{ .p = p }});
        }
        try w.writeAll("]");
    }
};

/// A list of names, as a JSON array of strings (names are ours: plain ASCII, no escaping needed).
pub const Names = struct {
    items: []const []const u8,

    pub fn format(self: Names, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("[");
        for (self.items, 0..) |name, i| {
            if (i != 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{name});
        }
        try w.writeAll("]");
    }
};

pub const Operation = enum { new, join, cut };

pub const Script = struct {
    w: *std.Io.Writer,
    count: usize = 0,

    pub fn begin(w: *std.Io.Writer, comment: []const u8) !Script {
        // SolidCraft ignores unknown top-level keys, so the provenance travels with the file.
        try w.print("{{\"generated_by\": \"{s}\",\n \"commands\": [\n", .{comment});
        return .{ .w = w };
    }

    pub fn end(self: *Script) !void {
        try self.w.writeAll("\n]}\n");
    }

    /// One command; `fmt` is the inside of its params object.
    pub fn cmd(self: *Script, name: []const u8, comptime fmt: []const u8, args: anytype) !void {
        if (self.count != 0) try self.w.writeAll(",\n");
        try self.w.print("  {{\"command\": \"{s}\", \"params\": {{", .{name});
        try self.w.print(fmt, args);
        try self.w.writeAll("}}");
        self.count += 1;
    }

    pub fn box(self: *Script, body: []const u8, corner: Vec3, size: Vec3, op: Operation) !void {
        try self.cmd("solid.box", "\"length\": {f}, \"width\": {f}, \"height\": {f}, \"corner\": {f}, \"operation\": \"{s}\", \"body_name\": \"{s}\"", .{
            n(size[0]), n(size[1]), n(size[2]), P3{ .p = corner }, @tagName(op), body,
        });
    }

    /// A cylinder along +Z (or `axis`) whose bottom centre is `base`.
    pub fn cylinder(self: *Script, body: []const u8, base: Vec3, d: f64, h: f64, axis: Vec3, op: Operation) !void {
        try self.cmd("solid.cylinder", "\"diameter\": {f}, \"height\": {f}, \"base\": {f}, \"axis\": {f}, \"operation\": \"{s}\", \"body_name\": \"{s}\"", .{
            n(d), n(h), P3{ .p = base }, P3{ .p = axis }, @tagName(op), body,
        });
    }

    pub fn fillet(self: *Script, body: []const u8, edges: []const Vec3, radius: f64) !void {
        try self.cmd("solid.fillet", "\"body\": \"{s}\", \"edges\": {f}, \"radius\": {f}", .{ body, Points{ .items = edges }, n(radius) });
    }

    pub fn chamfer(self: *Script, body: []const u8, edges: []const Vec3, distance: f64) !void {
        try self.cmd("solid.chamfer", "\"body\": \"{s}\", \"edges\": {f}, \"distance\": {f}", .{ body, Points{ .items = edges }, n(distance) });
    }

    pub fn combine(self: *Script, target: []const u8, tools: []const []const u8, op: Operation) !void {
        try self.cmd("solid.combine", "\"target\": \"{s}\", \"tools\": {f}, \"operation\": \"{s}\"", .{ target, Names{ .items = tools }, @tagName(op) });
    }

    pub fn move(self: *Script, bodies: []const []const u8, translate: Vec3) !void {
        try self.cmd("solid.move", "\"bodies\": {f}, \"translate\": {f}", .{ Names{ .items = bodies }, P3{ .p = translate } });
    }

    /// Rotation about a world axis through the origin, in degrees.
    pub fn rotate(self: *Script, bodies: []const []const u8, axis: Vec3, degrees: f64) !void {
        try self.cmd("solid.move", "\"bodies\": {f}, \"axis\": {f}, \"angle\": \"{f} deg\"", .{ Names{ .items = bodies }, P3{ .p = axis }, n(degrees) });
    }

    pub fn appearance(self: *Script, bodies: []const []const u8, color: []const u8, opacity: f64) !void {
        try self.cmd("appearance.assign", "\"bodies\": {f}, \"color\": \"{s}\", \"opacity\": {f}", .{ Names{ .items = bodies }, color, n(opacity) });
    }

    pub fn material(self: *Script, bodies: []const []const u8, name: []const u8) !void {
        try self.cmd("material.assign", "\"bodies\": {f}, \"material\": \"{s}\"", .{ Names{ .items = bodies }, name });
    }

    pub fn parameter(self: *Script, name: []const u8, value_mm: f64, comment: []const u8) !void {
        try self.cmd("parameters.change", "\"name\": \"{s}\", \"expression\": \"{f} mm\", \"comment\": \"{s}\"", .{ name, n(value_mm), comment });
    }

    pub fn exportFile(self: *Script, path: []const u8, bodies: []const []const u8) !void {
        try self.cmd("file.export", "\"path\": \"{s}\", \"bodies\": {f}", .{ path, Names{ .items = bodies } });
    }

    pub fn interference(self: *Script, bodies: []const []const u8) !void {
        try self.cmd("inspect.interference", "\"bodies\": {f}", .{Names{ .items = bodies }});
    }
};

test "numbers: three decimals at most, no trailing zeros, no negative zero" {
    var buffer: [64]u8 = undefined;
    const cases = [_]struct { v: f64, s: []const u8 }{
        .{ .v = 12, .s = "12" },
        .{ .v = 0.4, .s = "0.4" },
        .{ .v = -3.175, .s = "-3.175" },
        .{ .v = 2.05, .s = "2.05" },
        .{ .v = 1.0004, .s = "1" },
        .{ .v = -0.0001, .s = "0" },
        .{ .v = 65.0 / 3.0, .s = "21.667" },
        .{ .v = 0.007, .s = "0.007" },
    };
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buffer);
        try w.print("{f}", .{n(c.v)});
        try std.testing.expectEqualStrings(c.s, w.buffered());
    }
}

test "a script is valid JSON with the commands in order" {
    var buffer: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    var s = try Script.begin(&w, "test");
    try s.box("Base", .{ 0, 0, 0 }, .{ 70, 35, 11 }, .new);
    try s.fillet("Base", &.{ .{ 0, 0, 5 }, .{ 70, 0, 5 } }, 5);
    try s.combine("Base", &.{"Cavity"}, .cut);
    try s.end();

    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const commands = parsed.value.object.get("commands").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), commands.len);
    try std.testing.expectEqualStrings("solid.fillet", commands[1].object.get("command").?.string);
    const params = commands[0].object.get("params").?.object;
    try std.testing.expectEqualStrings("Base", params.get("body_name").?.string);
}
