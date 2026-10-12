const std = @import("std");
const qr = @import("src/ui/qr.zig");
const dec = @import("src/ui/qr_decode.zig");
const testing = std.testing;

fn renderMatrix(allocator: std.mem.Allocator, m: *const qr.Matrix, scale: usize, quiet: usize, dark: u8, light: u8) !dec.Image {
    const total = (m.size + 2 * quiet) * scale;
    const pixels = try allocator.alloc(u8, total * total);
    @memset(pixels, light);
    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        var x: usize = 0;
        while (x < m.size) : (x += 1) {
            if (!m.get(x, y)) continue;
            var py: usize = 0;
            while (py < scale) : (py += 1) {
                var px: usize = 0;
                while (px < scale) : (px += 1) {
                    pixels[((quiet + y) * scale + py) * total + (quiet + x) * scale + px] = dark;
                }
            }
        }
    }
    return .{ .width = total, .height = total, .pixels = pixels };
}

test "modes/ec" {
    const allocator = testing.allocator;
    const cases = [_]struct { text: []const u8, ec: qr.EcLevel }{
        .{ .text = "0123456789012345678901234567890", .ec = .l },
        .{ .text = "HELLO WORLD $%*+-./: 1234", .ec = .m },
        .{ .text = "Hello, QR decoder! zig 0.17", .ec = .q },
        .{ .text = "日本語のテスト/QRデコーダ", .ec = .h },
        .{ .text = "12345", .ec = .h },
        .{ .text = "A", .ec = .l },
    };
    for (cases) |c| {
        const m = try qr.encode(allocator, c.text, c.ec);
        defer m.deinit(allocator);
        const img = try renderMatrix(allocator, &m, 4, 4, 0, 255);
        defer allocator.free(img.pixels);
        const text = dec.decode(allocator, img) catch |e| {
            std.debug.print("FAIL {s} ec={s} v={d} size={d} err={any}\n", .{ c.text, c.ec.name(), m.version, m.size, e });
            continue;
        };
        defer allocator.free(text);
        if (!std.mem.eql(u8, text, c.text)) {
            std.debug.print("MISMATCH {s} -> {s}\n", .{ c.text, text });
        } else {
            std.debug.print("ok {s} ec={s} v={d} mask={d}\n", .{ c.text, c.ec.name(), m.version, m.mask });
        }
    }
}

test "versions" {
    const allocator = testing.allocator;
    var v: u8 = 1;
    while (v <= 40) : (v += 1) {
        const m = try qr.encodeVersion(allocator, "ABCDEF123456", .l, v);
        defer m.deinit(allocator);
        const scale: usize = if (v <= 10) 3 else 2;
        const img = try renderMatrix(allocator, &m, scale, 4, 0, 255);
        defer allocator.free(img.pixels);
        const text = dec.decode(allocator, img) catch |e| {
            std.debug.print("FAIL v={d} size={d} err={any}\n", .{ v, m.size, e });
            continue;
        };
        defer allocator.free(text);
        if (!std.mem.eql(u8, text, "ABCDEF123456")) std.debug.print("MISMATCH v={d}\n", .{v});
    }
}

test "scales" {
    const allocator = testing.allocator;
    const m = try qr.encode(allocator, "SCALE 0123456789", .m);
    defer m.deinit(allocator);
    var scale: usize = 1;
    while (scale <= 6) : (scale += 1) {
        const img = try renderMatrix(allocator, &m, scale, 4, 10, 240);
        defer allocator.free(img.pixels);
        const text = dec.decode(allocator, img) catch |e| {
            std.debug.print("FAIL scale={d} err={any}\n", .{ scale, e });
            continue;
        };
        defer allocator.free(text);
        std.debug.print("ok scale={d} ({s})\n", .{ scale, text });
    }
    // quiet 0, scale 4
    const img2 = try renderMatrix(allocator, &m, 4, 0, 10, 240);
    defer allocator.free(img2.pixels);
    if (dec.decode(allocator, img2)) |t| {
        defer allocator.free(t);
        std.debug.print("ok quiet0 ({s})\n", .{t});
    } else |e| std.debug.print("FAIL quiet0 err={any}\n", .{e});
}

fn dumpExpected(m: *const qr.Matrix) void {
    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        var buf: [200]u8 = @splat('.');
        var x: usize = 0;
        while (x < m.size) : (x += 1) {
            if (m.get(x, y)) buf[x] = '#';
        }
        std.debug.print("EXP  {s}\n", .{buf[0..m.size]});
    }
}

test "dump v3" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .q);
    defer m.deinit(allocator);
    std.debug.print("== v={d} size={d} mask={d} ec={s}\n", .{ m.version, m.size, m.mask, m.ec.name() });
    dumpExpected(&m);
    const img = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer allocator.free(img.pixels);
    _ = dec.decode(allocator, img) catch {};
}
