//! QR code decoder (for camera input).
//!
//! The input is only a grayscale image (one byte per pixel). Camera-specific work
//! (exposure, white balance, RGB conversion) is the caller's responsibility; this module
//! only turns an image buffer into text.
//!
//! Pipeline:
//!   1. Binarization — adaptive threshold from 8x8 block averages (the idea behind ZXing's
//!      HybridBinarizer). Small images fall back to Otsu's global threshold. On failure we
//!      retry with the other binarization, with a looser detection, and with inverted polarity.
//!   2. Find the three finder patterns with a 1:1:3:1:1 run scan and refine each center to
//!      sub-pixel accuracy with a perpendicular cross check. Candidates must be surrounded by
//!      the light separator and share a consistent module size. If that fails we relax the
//!      rules and rescan rows and columns.
//!   3. Fix the (top-left, top-right, bottom-left) assignment with a cross product and derive
//!      the version (= modules per side) by counting the light/dark transitions of the timing
//!      pattern. The count does not depend on distance, so perspective does not fool it.
//!      Several triples are tried; a triple whose timing size disagrees is tried last.
//!   4. Look for the bottom-right alignment pattern and solve a projective transform
//!      (homography) from four points. Without it, a parallelogram (affine) stands in.
//!   5. Sample the center of every module five times (majority vote) to build the matrix.
//!   6. Read EC level and mask from the format information (15 bits, corrected by Hamming
//!      distance) and read the data codewords in zigzag order while undoing the mask.
//!   7. Correct each block with Reed-Solomon and interpret the mode indicators.
//!
//! Supported: versions 1-40, EC levels L/M/Q/H, numeric/alphanumeric/byte modes.
//! ECI, Kanji mode, structured append and FNC1 return `Error.UnsupportedMode`.
//!
//! Memory: the binarized image and the module matrices use one bit per pixel. The `Image`
//! pixel buffer belongs to the caller and is never modified. Scratch memory comes from the
//! allocator passed to `decode` and is released inside this module.
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const qr = @import("qr.zig");
const CoreError = @import("../core/errors.zig").Error;

/// Decoding errors: the shared core `Error` plus QR-specific ones.
pub const Error = CoreError || error{
    /// No finder pattern triple (the three corners) was found in the image
    SymbolNotFound,
    /// A symbol was found but had more errors than the error correction could fix
    TooManyErrors,
    /// A symbol was found but its structure violates the standard (e.g. too few data modules)
    InvalidSymbol,
    /// Feature the standard defines but this decoder does not support (ECI, Kanji, structured append, FNC1)
    UnsupportedMode,
};

/// Lowest supported version.
pub const min_version: u8 = 1;
/// Highest supported version.
pub const max_version: u8 = 40;
/// Modules per side for version 1.
pub const min_size: usize = 17 + 4 * @as(usize, min_version);
/// Modules per side for version 40.
pub const max_size: usize = 17 + 4 * @as(usize, max_version);

/// Largest accepted image side. Bigger images are rejected (this also avoids overflowing width * height).
pub const max_image_dim: usize = 4096;

/// Grayscale image: one byte per pixel (0 = black, 255 = white), row-major.
pub const Image = struct {
    width: usize,
    height: usize,
    /// Must hold at least `width * height` bytes (row-major).
    pixels: []const u8,

    /// Pixel at (x, y). Out-of-range coordinates read as white (255).
    pub fn pixel(self: *const Image, x: usize, y: usize) u8 {
        if (x >= self.width or y >= self.height) return 255;
        return self.pixels[y * self.width + x];
    }
};

/// Metadata that comes with a successful decode.
pub const Info = struct {
    /// Decoded text: the start of the `out` buffer passed to `decodeTo`.
    text: []const u8,
    /// Symbol version (1-40).
    version: u8,
    /// Error correction level.
    ec: qr.EcLevel,
    /// Mask number that was in use (0-7).
    mask: u3,
};

// ---------------------------------------------------------------- public API

/// Decode an image and return its text.
///
/// The result is memory owned by `allocator`; the caller must release it with
/// `allocator.free(result)` using the same allocator. Byte-mode content is returned as is
/// (interpreting it as UTF-8 is up to the caller).
pub fn decode(allocator: std.mem.Allocator, image: Image) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var sink = Sink{ .allocator = allocator, .list = &out };
    var info: Info = undefined;
    try decodeInternal(allocator, &image, &sink, &info);
    return try out.toOwnedSlice(allocator);
}

/// Decode into `out`.
///
/// Returns `Error.BufferTooSmall` when `out` is too small. The result points into `out`.
pub fn decodeInto(allocator: std.mem.Allocator, image: Image, out: []u8) Error![]const u8 {
    return (try decodeTo(allocator, image, out)).text;
}

/// Decode into `out` and also report version, EC level and mask.
pub fn decodeTo(allocator: std.mem.Allocator, image: Image, out: []u8) Error!Info {
    var sink = Sink{ .allocator = allocator, .fixed = out };
    var info: Info = .{ .text = out[0..0], .version = 0, .ec = .l, .mask = 0 };
    try decodeInternal(allocator, &image, &sink, &info);
    return info;
}

// ---------------------------------------------------------------- output sink

/// Where decoded bytes go. Handles growable (ArrayList) and fixed buffers through one path.
const Sink = struct {
    allocator: std.mem.Allocator,
    list: ?*std.ArrayList(u8) = null,
    fixed: ?[]u8 = null,
    len: usize = 0,

    fn writeByte(self: *Sink, b: u8) Error!void {
        if (self.list) |l| {
            try l.append(self.allocator, b);
        } else if (self.fixed) |f| {
            if (self.len >= f.len) return Error.BufferTooSmall;
            f[self.len] = b;
        } else return Error.BufferTooSmall;
        self.len += 1;
    }

    /// Drop what the previous attempt wrote (each candidate starts over).
    fn reset(self: *Sink) void {
        if (self.list) |l| l.clearRetainingCapacity();
        self.len = 0;
    }

    fn text(self: *const Sink) []const u8 {
        if (self.list) |l| return l.items;
        if (self.fixed) |f| return f[0..self.len];
        return &.{};
    }
};

// ---------------------------------------------------------------- bit matrix

/// Binary matrix with one bit per cell, used for both the binarized image and module grids.
const BitMatrix = struct {
    width: usize,
    height: usize,
    words: []u64,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) Error!BitMatrix {
        const n = (width * height + 63) / 64;
        const words = try allocator.alloc(u64, n);
        @memset(words, 0);
        return .{ .width = width, .height = height, .words = words };
    }

    fn deinit(self: *const BitMatrix, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
    }

    fn get(self: *const BitMatrix, x: usize, y: usize) bool {
        if (x >= self.width or y >= self.height) return false;
        const i = y * self.width + x;
        return (self.words[i >> 6] >> @intCast(i & 63)) & 1 != 0;
    }

    fn set(self: *BitMatrix, x: usize, y: usize) void {
        if (x >= self.width or y >= self.height) return;
        const i = y * self.width + x;
        self.words[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
    }

    /// Flip every bit (last resort for images with inverted polarity).
    fn invert(self: *BitMatrix) void {
        for (self.words) |*w| w.* = ~w.*;
    }
};

// ---------------------------------------------------------------- binarization

/// How to binarize.
const BinarizePlan = struct {
    /// Use local 8x8 block averages (robust against uneven lighting). false uses Otsu's global threshold.
    adaptive: bool,
    /// Treat the image as inverted and flip it.
    invert: bool = false,
};

/// Same "flat block" dynamic range as ZXing.
const min_dynamic_range: u32 = 24;

fn clampUsize(value: usize, low: usize, high: usize) usize {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

/// Binarize `image` into `bin`, which must already be sized like the image.
fn binarize(bin: *BitMatrix, image: *const Image, plan: BinarizePlan, black_points: []u8) void {
    const sub_w = (image.width + 7) / 8;
    const sub_h = (image.height + 7) / 8;
    if (plan.adaptive and sub_w >= 5 and sub_h >= 5 and black_points.len >= sub_w * sub_h) {
        adaptiveBinarize(bin, image, black_points);
    } else {
        globalBinarize(bin, image);
    }
    if (plan.invert) bin.invert();
}

/// Binarize with a global Otsu threshold (for small images and evenly lit scenes).
fn globalBinarize(bin: *BitMatrix, image: *const Image) void {
    var histogram: [256]u32 = @splat(0);
    const n = image.width * image.height;
    for (image.pixels[0..n]) |p| histogram[p] += 1;

    var total: u32 = 0;
    var sum_all: f64 = 0;
    for (0..256) |i| {
        total += histogram[i];
        sum_all += @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(histogram[i]));
    }
    if (total == 0) return;

    var best_threshold: u8 = 0;
    var best_variance: f64 = -1.0;
    var sum_back: f64 = 0;
    var weight_back: u32 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        weight_back += histogram[i];
        if (weight_back == 0) continue;
        const weight_fore = total - weight_back;
        if (weight_fore == 0) break;
        sum_back += @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(histogram[i]));
        const mean_back = sum_back / @as(f64, @floatFromInt(weight_back));
        const mean_fore = (sum_all - sum_back) / @as(f64, @floatFromInt(weight_fore));
        const diff = mean_back - mean_fore;
        const variance = @as(f64, @floatFromInt(weight_back)) *
            @as(f64, @floatFromInt(weight_fore)) * diff * diff;
        if (variance > best_variance) {
            best_variance = variance;
            best_threshold = @intCast(i);
        }
    }

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        const row = image.pixels[y * image.width ..][0..image.width];
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            if (row[x] <= best_threshold) bin.set(x, y);
        }
    }
}

/// Binarize with local 8x8 block averages (equivalent to ZXing's HybridBinarizer).
///
/// Average each block (flat blocks borrow a value from their neighbours) and threshold with
/// the average of the surrounding 5x5 blocks. Even with a lighting gradient or a soft shadow,
/// black and white stay separated locally.
fn adaptiveBinarize(bin: *BitMatrix, image: *const Image, black_points: []u8) void {
    const w = image.width;
    const h = image.height;
    const sub_w = (w + 7) / 8;
    const sub_h = (h + 7) / 8;
    @memset(black_points[0 .. sub_w * sub_h], 0);

    var by: usize = 0;
    while (by < sub_h) : (by += 1) {
        var bx: usize = 0;
        while (bx < sub_w) : (bx += 1) {
            const x0 = bx * 8;
            const y0 = by * 8;
            const x1 = @min(x0 + 8, w);
            const y1 = @min(y0 + 8, h);
            var sum: u32 = 0;
            var min: u8 = 255;
            var max: u8 = 0;
            var count: u32 = 0;
            var y: usize = y0;
            while (y < y1) : (y += 1) {
                var x: usize = x0;
                while (x < x1) : (x += 1) {
                    const p = image.pixels[y * w + x];
                    sum += p;
                    if (p < min) min = p;
                    if (p > max) max = p;
                    count += 1;
                }
            }
            var average: u8 = if (count == 0) 255 else @intCast(sum / count);
            if (@as(u32, max) - @as(u32, min) <= min_dynamic_range) {
                // A flat block (uniform white or black) borrows the threshold of its neighbours.
                average = min / 2;
                if (by > 0 and bx > 0) {
                    const neighbor = (@as(u32, black_points[(by - 1) * sub_w + bx]) +
                        2 * @as(u32, black_points[by * sub_w + bx - 1]) +
                        @as(u32, black_points[(by - 1) * sub_w + bx - 1])) / 4;
                    if (min < neighbor) average = @intCast(neighbor);
                }
            }
            black_points[by * sub_w + bx] = average;
        }
    }

    by = 0;
    while (by < sub_h) : (by += 1) {
        var bx: usize = 0;
        while (bx < sub_w) : (bx += 1) {
            const left = clampUsize(bx, 2, sub_w - 3);
            const top = clampUsize(by, 2, sub_h - 3);
            var sum: u32 = 0;
            var z: usize = 0;
            while (z < 5) : (z += 1) {
                var xx: usize = 0;
                while (xx < 5) : (xx += 1) {
                    sum += black_points[(top + z - 2) * sub_w + (left + xx - 2)];
                }
            }
            const threshold: u8 = @intCast(sum / 25);

            const x0 = bx * 8;
            const y0 = by * 8;
            const x1 = @min(x0 + 8, w);
            const y1 = @min(y0 + 8, h);
            var y: usize = y0;
            while (y < y1) : (y += 1) {
                var x: usize = x0;
                while (x < x1) : (x += 1) {
                    if (image.pixels[y * w + x] <= threshold) bin.set(x, y);
                }
            }
        }
    }
}

// ---------------------------------------------------------------- geometry

const Point = struct { x: f64, y: f64 };

fn distance(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn cross(a: Point, b: Point, origin: Point) f64 {
    return (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
}

/// Projective transform (module coordinates -> pixel coordinates). With h[6] and h[7] zero it is affine.
const Homography = struct {
    h: [8]f64,

    fn map(self: *const Homography, u: f64, v: f64) Point {
        const denom = self.h[6] * u + self.h[7] * v + 1.0;
        const d = if (@abs(denom) < 1e-12) 1e-12 else denom;
        return .{
            .x = (self.h[0] * u + self.h[1] * v + self.h[2]) / d,
            .y = (self.h[3] * u + self.h[4] * v + self.h[5]) / d,
        };
    }
};

/// Solve a projective transform from four point correspondences. Returns null when degenerate.
fn solveHomography(src: [4]Point, dst: [4]Point) ?Homography {
    var m: [8][9]f64 = undefined;
    for (0..4) |k| {
        const u = src[k].x;
        const v = src[k].y;
        const x = dst[k].x;
        const y = dst[k].y;
        m[2 * k] = .{ u, v, 1.0, 0.0, 0.0, 0.0, -u * x, -v * x, x };
        m[2 * k + 1] = .{ 0.0, 0.0, 0.0, u, v, 1.0, -u * y, -v * y, y };
    }
    for (0..8) |col| {
        var pivot = col;
        var best = @abs(m[col][col]);
        var r = col + 1;
        while (r < 8) : (r += 1) {
            const a = @abs(m[r][col]);
            if (a > best) {
                best = a;
                pivot = r;
            }
        }
        if (best < 1e-9) return null;
        if (pivot != col) std.mem.swap([9]f64, &m[pivot], &m[col]);
        const d = m[col][col];
        var c = col;
        while (c < 9) : (c += 1) m[col][c] /= d;
        for (0..8) |row| {
            if (row == col) continue;
            const factor = m[row][col];
            if (factor == 0.0) continue;
            c = col;
            while (c < 9) : (c += 1) m[row][c] -= factor * m[col][c];
        }
    }
    var h: [8]f64 = undefined;
    for (0..8) |i| h[i] = m[i][8];
    return .{ .h = h };
}

// ---------------------------------------------------------------- run scanning

/// A candidate found by scanning (center of a finder or alignment pattern).
const Candidate = struct {
    x: f64,
    y: f64,
    module: f64,
    count: usize = 1,
};

/// Relative widths of five runs (dark, light, dark, light, dark): 1:1:3:1:1 for finders, 1:1:1:1:1 for alignment.
const finder_ratio = [5]f64{ 1, 1, 3, 1, 1 };
/// Upper bound on the finder candidate list (the weakest entries are dropped when full).
const max_finder_candidates: usize = 512;
const align_ratio = [5]f64{ 1, 1, 1, 1, 1 };

const RatioResult = struct { center: usize, module: f64 };

/// Center of a five-run pattern (along the scan axis, measured from its start) and module size. Null when the ratios do not fit.
fn ratioCenter(counts: [5]usize, expected: [5]f64, tolerance: f64) ?RatioResult {
    var total: usize = 0;
    for (counts) |c| total += c;
    if (total < 7) return null;
    const expected_total = expected[0] + expected[1] + expected[2] + expected[3] + expected[4];
    const module = @as(f64, @floatFromInt(total)) / expected_total;
    if (module < 1.0) return null;
    for (0..5) |i| {
        const want = expected[i] * module;
        const allowed = expected[i] * tolerance * module + 1.0;
        const got = @as(f64, @floatFromInt(counts[i]));
        if (@abs(got - want) > allowed) return null;
    }
    return .{ .center = counts[0] + counts[1] + counts[2] / 2, .module = module };
}

/// Run test for alignment patterns.
///
/// The dark center module and the light ring around it never merge with neighbouring data
/// modules, so they are checked strictly. The outer dark ring can merge with adjacent data and
/// grow, so it only has to be at least one module wide (the idea behind ZXing's
/// AlignmentPatternFinder).
fn alignRatio(counts: [5]usize, tolerance: f64) ?f64 {
    const inner = counts[1] + counts[2] + counts[3];
    if (inner < 3) return null;
    const module = @as(f64, @floatFromInt(inner)) / 3.0;
    if (module < 1.0) return null;
    const allowed = tolerance * module + 1.0;
    for (1..4) |i| {
        const got: f64 = @floatFromInt(counts[i]);
        if (@abs(got - module) > allowed) return null;
    }
    if (@as(f64, @floatFromInt(counts[0])) < 0.4 * module) return null;
    if (@as(f64, @floatFromInt(counts[4])) < 0.4 * module) return null;
    return module;
}

/// Scratch space for run scanning (run start positions of one row).
const RunScanner = struct {
    starts: []usize,

    fn init(allocator: std.mem.Allocator, max_len: usize) Error!RunScanner {
        return .{ .starts = try allocator.alloc(usize, max_len + 2) };
    }

    fn deinit(self: *const RunScanner, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
    }
};

/// Build the run start positions of one row (or column) along the scan axis `major` and return the run count.
fn buildRuns(self: *const RunScanner, bin: *const BitMatrix, vertical: bool, major: usize, lo: usize, hi: usize) usize {
    var n: usize = 0;
    self.starts[0] = lo;
    var p = lo + 1;
    while (p < hi) : (p += 1) {
        const prev = if (vertical) bin.get(major, p - 1) else bin.get(p - 1, major);
        const cur = if (vertical) bin.get(major, p) else bin.get(p, major);
        if (cur != prev) {
            n += 1;
            self.starts[n] = p;
        }
    }
    n += 1;
    self.starts[n] = hi;
    return n;
}

/// Read the pixel at (major, minor) along the scan axis.
fn runPixel(bin: *const BitMatrix, vertical: bool, major: isize, minor: isize) bool {
    if (major < 0 or minor < 0) return false;
    const ma: usize = @intCast(major);
    const mi: usize = @intCast(minor);
    if (vertical) {
        if (mi >= bin.width or ma >= bin.height) return false;
        return bin.get(mi, ma);
    }
    if (ma >= bin.width or mi >= bin.height) return false;
    return bin.get(ma, mi);
}

/// Measure five runs from a center pixel towards both sides of the scan axis and return the
/// refined center when the ratios fit.
///
/// Null when the center is not dark or the ratios do not fit. Passing `total_hint` rejects
/// candidates whose perpendicular length differs too much (a squareness check for finders).
const ScanKind = enum { finder, alignment };

fn crossCheck(
    bin: *const BitMatrix,
    cx: f64,
    cy: f64,
    horizontal: bool,
    kind: ScanKind,
    expected: [5]f64,
    tolerance: f64,
    total_hint: ?f64,
) ?Candidate {
    if (cx < 0.0 or cy < 0.0) return null;
    const cxi: isize = @intFromFloat(@floor(cx));
    const cyi: isize = @intFromFloat(@floor(cy));
    const c_major = if (horizontal) cxi else cyi;
    const c_minor = if (horizontal) cyi else cxi;
    if (!runPixel(bin, !horizontal, c_major, c_minor)) return null;

    var counts: [5]usize = @splat(0);
    counts[2] = 1;
    var center_neg: usize = 0;
    const limit: usize = 128;

    // Negative direction: dark (center run) -> light -> dark.
    {
        var k: isize = 1;
        while (k < @as(isize, @intCast(limit))) : (k += 1) {
            if (!runPixel(bin, !horizontal, c_major - k, c_minor)) break;
            counts[2] += 1;
            center_neg += 1;
        }
        var kk: isize = 1 + @as(isize, @intCast(center_neg));
        while (kk < @as(isize, @intCast(limit))) : (kk += 1) {
            if (runPixel(bin, !horizontal, c_major - kk, c_minor)) break;
            counts[1] += 1;
        }
        var k2: isize = 1 + @as(isize, @intCast(center_neg + counts[1]));
        while (k2 < @as(isize, @intCast(limit))) : (k2 += 1) {
            if (!runPixel(bin, !horizontal, c_major - k2, c_minor)) break;
            counts[0] += 1;
        }
    }
    // Positive direction: center run -> light -> dark.
    {
        var k: isize = 1;
        while (k < @as(isize, @intCast(limit))) : (k += 1) {
            if (!runPixel(bin, !horizontal, c_major + k, c_minor)) break;
            counts[2] += 1;
        }
        const center_pos = counts[2] - 1 - center_neg;
        var kk: isize = 1 + @as(isize, @intCast(center_pos));
        while (kk < @as(isize, @intCast(limit))) : (kk += 1) {
            if (runPixel(bin, !horizontal, c_major + kk, c_minor)) break;
            counts[3] += 1;
        }
        var k2: isize = 1 + @as(isize, @intCast(center_pos + counts[3]));
        while (k2 < @as(isize, @intCast(limit))) : (k2 += 1) {
            if (!runPixel(bin, !horizontal, c_major + k2, c_minor)) break;
            counts[4] += 1;
        }
    }

    const module = switch (kind) {
        .finder => (ratioCenter(counts, expected, tolerance) orelse return null).module,
        .alignment => alignRatio(counts, tolerance) orelse return null,
    };
    const total: f64 = @floatFromInt(counts[0] + counts[1] + counts[2] + counts[3] + counts[4]);
    if (total_hint) |hint| {
        if (@abs(total - hint) > 0.5 * hint + 1.0) return null;
    }
    // The center run covers pixels [c_major - center_neg, c_major + center_pos], so its
    // center in continuous coordinates is +0.5 (pixel i occupies [i, i+1)).
    const center_pos = counts[2] - 1 - center_neg;
    const t = (@as(f64, @floatFromInt(center_pos)) - @as(f64, @floatFromInt(center_neg))) / 2.0;
    const major_f = @as(f64, @floatFromInt(c_major)) + t + 0.5;
    const minor_f = @as(f64, @floatFromInt(c_minor)) + 0.5;
    return .{
        .x = if (horizontal) major_f else minor_f,
        .y = if (horizontal) minor_f else major_f,
        .module = module,
    };
}

/// Check that the outside of a finder pattern (four modules from its center) is light.
///
/// A real finder pattern is surrounded by the light separator and the quiet zone, so the four
/// points at +/-4 modules from the center are always light. The module size measured by the
/// scan is a length along the image axis, so those four points still land on the separator
/// even when the symbol is rotated.
fn hasLightRing(bin: *const BitMatrix, cx: f64, cy: f64, module: f64) bool {
    const d = 4.0 * module;
    const points = [4]Point{
        .{ .x = cx + d, .y = cy },
        .{ .x = cx - d, .y = cy },
        .{ .x = cx, .y = cy + d },
        .{ .x = cx, .y = cy - d },
    };
    var light: usize = 0;
    for (points) |p| {
        if (!samplePixel(bin, p)) light += 1;
    }
    return light >= 3;
}

/// Module size of a candidate already confirmed by several rows.
///
/// Accidental 1:1:3:1:1 patterns in the data area are usually much smaller (one to three
/// pixels) than a real finder, so dropping candidates far from this reference keeps the
/// candidate list from overflowing. All three finder patterns share one module size, so the
/// test works for rotated symbols too.
fn referenceModule(items: []const Candidate) ?f64 {
    var best_count: usize = 2; // only candidates with count >= 3 become the reference
    var best: ?f64 = null;
    for (items) |c| {
        if (c.count > best_count) {
            best_count = c.count;
            best = c.module;
        }
    }
    return best;
}

/// Merge into a nearby candidate, or append a new one.
fn mergeCandidate(list: *std.ArrayList(Candidate), allocator: std.mem.Allocator, c: Candidate) Error!void {
    for (list.items) |*p| {
        const near = @abs(p.x - c.x) <= p.module * 1.0 and @abs(p.y - c.y) <= p.module * 1.0;
        // Do not merge candidates whose module sizes differ a lot (a one-pixel pattern in the
        // data area must not stick to a real finder and spoil the size estimate).
        const similar = @abs(p.module - c.module) <= 0.35 * @max(p.module, c.module) + 0.3;
        if (near and similar) {
            const n = @as(f64, @floatFromInt(p.count));
            p.x = (p.x * n + c.x) / (n + 1.0);
            p.y = (p.y * n + c.y) / (n + 1.0);
            p.module = (p.module * n + c.module) / (n + 1.0);
            p.count += 1;
            return;
        }
    }
    // Once the list is full, evict the weakest (least confirmed) candidate.
    if (list.items.len >= max_finder_candidates) {
        var weakest: usize = 0;
        for (list.items, 0..) |p, i| {
            if (p.count < list.items[weakest].count) weakest = i;
        }
        if (list.items[weakest].count >= c.count) return;
        list.items[weakest] = c;
        return;
    }
    try list.append(allocator, c);
}

/// Collect center candidates by scanning five-run patterns.
///
/// With `vertical` true the scan runs along columns (a fallback for rotated symbols and for
/// cases the row scan misses). `minor` is the coordinate on the axis that is not scanned.
fn scanRuns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    scanner: *const RunScanner,
    vertical: bool,
    lo: usize,
    hi: usize,
    expected: [5]f64,
    tolerance: f64,
    relaxed_ring: bool,
    out: *std.ArrayList(Candidate),
) Error!void {
    const major_len = if (vertical) bin.height else bin.width;
    const minor_len = if (vertical) bin.width else bin.height;
    if (lo >= hi or hi > major_len) return;

    var minor: usize = 0;
    while (minor < minor_len) : (minor += 1) {
        const nruns = buildRuns(scanner, bin, vertical, minor, lo, hi);
        if (nruns < 5) continue;
        var i: usize = 0;
        while (i + 5 <= nruns) : (i += 1) {
            const first_dark = if (vertical)
                bin.get(minor, scanner.starts[i])
            else
                bin.get(scanner.starts[i], minor);
            if (!first_dark) continue;
            var counts: [5]usize = undefined;
            for (0..5) |k| counts[k] = scanner.starts[i + k + 1] - scanner.starts[i + k];
            _ = ratioCenter(counts, expected, tolerance) orelse continue;
            const major_center = (@as(f64, @floatFromInt(scanner.starts[i + 2])) +
                @as(f64, @floatFromInt(scanner.starts[i + 3]))) / 2.0;
            const minor_center = @as(f64, @floatFromInt(minor)) + 0.5;
            const cx = if (vertical) minor_center else major_center;
            const cy = if (vertical) major_center else minor_center;
            const total_px: f64 = @floatFromInt(counts[0] + counts[1] + counts[2] + counts[3] + counts[4]);
            // Perpendicular cross check, then refine the center along the scan axis.
            const first = crossCheck(bin, cx, cy, vertical, .finder, expected, tolerance, total_px) orelse continue;
            const second = crossCheck(bin, first.x, first.y, !vertical, .finder, expected, tolerance, total_px) orelse continue;
            const measured = (first.module + second.module) / 2.0;
            // Without a light separator around it, this is not a finder pattern.
            if (!relaxed_ring and !hasLightRing(bin, second.x, second.y, measured)) continue;
            // Once a candidate has been confirmed by several rows, drop candidates whose
            // module size differs a lot (small accidental 1:1:3:1:1 patterns in the data area).
            if (referenceModule(out.items)) |reference| {
                if (measured < 0.5 * reference or measured > 2.0 * reference) continue;
            }
            try mergeCandidate(out, allocator, .{
                .x = second.x,
                .y = second.y,
                .module = measured,
            });
        }
    }
}

// ---------------------------------------------------------------- finder detection

/// Find finder patterns, most confirmed first; the caller frees the result.
///
/// With `relaxed` false the separator test narrows candidates strictly. With `relaxed` true
/// that test is dropped, the tolerances widen, and both rows and columns are scanned (for
/// dirty or partially damaged images).
fn findFinderPatterns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    relaxed: bool,
) Error![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer out.deinit(allocator);
    const scanner = try RunScanner.init(allocator, @max(bin.width, bin.height));
    defer scanner.deinit(allocator);

    const tolerance: f64 = if (relaxed) 0.75 else 0.5;
    try scanRuns(allocator, bin, &scanner, false, 0, bin.width, finder_ratio, tolerance, relaxed, &out);
    if (relaxed or out.items.len < 3) {
        try scanRuns(allocator, bin, &scanner, true, 0, bin.height, finder_ratio, tolerance, relaxed, &out);
    }
    // Most confirmed first (a plain insertion sort; there are at most a few hundred candidates).
    const items = out.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].count < key.count) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }
    return try out.toOwnedSlice(allocator);
}

fn scoreTriple(p: Candidate, q: Candidate, r: Candidate, relaxed: bool) ?f64 {
    const mods = [3]f64{ p.module, q.module, r.module };
    const m_min = @min(mods[0], @min(mods[1], mods[2]));
    const m_max = @max(mods[0], @max(mods[1], mods[2]));
    if (m_min < 1.0) return null;
    // The three finder patterns must share a module size (up to some perspective).
    const module_ratio_limit: f64 = if (relaxed) 1.8 else 1.35;
    if (m_max > m_min * module_ratio_limit) return null;

    const pts = [3]Point{ .{ .x = p.x, .y = p.y }, .{ .x = q.x, .y = q.y }, .{ .x = r.x, .y = r.y } };
    const d01 = distance(pts[0], pts[1]);
    const d12 = distance(pts[1], pts[2]);
    const d02 = distance(pts[0], pts[2]);
    var vertex: usize = 0;
    var hyp_a: usize = 0;
    var hyp_b: usize = 0;
    if (d01 >= d12 and d01 >= d02) {
        vertex = 2;
        hyp_a = 0;
        hyp_b = 1;
    } else if (d12 >= d01 and d12 >= d02) {
        vertex = 0;
        hyp_a = 1;
        hyp_b = 2;
    } else {
        vertex = 1;
        hyp_a = 0;
        hyp_b = 2;
    }
    const v = pts[vertex];
    const e1 = Point{ .x = pts[hyp_a].x - v.x, .y = pts[hyp_a].y - v.y };
    const e2 = Point{ .x = pts[hyp_b].x - v.x, .y = pts[hyp_b].y - v.y };
    const l1 = @sqrt(e1.x * e1.x + e1.y * e1.y);
    const l2 = @sqrt(e2.x * e2.x + e2.y * e2.y);
    if (l1 < 1.0 or l2 < 1.0) return null;
    // The vertex of a right angle, so the two legs must meet at close to 90 degrees.
    const cos = (e1.x * e2.x + e1.y * e2.y) / (l1 * l2);
    const cos_limit: f64 = if (relaxed) 0.6 else 0.35;
    if (@abs(cos) > cos_limit) return null;
    const leg_ratio = @max(l1, l2) / @min(l1, l2);
    const leg_limit: f64 = if (relaxed) 3.0 else 2.2;
    if (leg_ratio > leg_limit) return null;
    // Both legs, measured in modules, must agree and be close to a valid size (17 + 4v).
    const module = (p.module + q.module + r.module) / 3.0;
    const dim_h = @max(l1, l2) / module + 7.0;
    const dim_v = @min(l1, l2) / module + 7.0;
    const dim_avg = (dim_h + dim_v) / 2.0;
    const dim_tol: f64 = if (relaxed) 8.0 else 4.0;
    if (@abs(dim_h - dim_v) > dim_tol) return null;
    const nearest = nearestDimension(dim_avg) orelse return null;
    const dim_dev = @abs(dim_avg - @as(f64, @floatFromInt(nearest)));
    if (dim_dev > dim_tol) return null;

    const counts: f64 = @floatFromInt(p.count + q.count + r.count);
    const spread = (m_max - m_min) / m_min;
    return counts - spread * 12.0 - dim_dev * 2.0 - @abs(cos) * 3.0;
}

/// Order three points as top-left, top-right and bottom-left, right-handed in image coordinates (y downwards).
fn orderPatterns(a: Candidate, b: Candidate, c: Candidate) [3]Candidate {
    const pts = [3]Candidate{ a, b, c };
    const d01 = distance(.{ .x = pts[0].x, .y = pts[0].y }, .{ .x = pts[1].x, .y = pts[1].y });
    const d12 = distance(.{ .x = pts[1].x, .y = pts[1].y }, .{ .x = pts[2].x, .y = pts[2].y });
    const d02 = distance(.{ .x = pts[0].x, .y = pts[0].y }, .{ .x = pts[2].x, .y = pts[2].y });
    var tl: usize = 0;
    var p: usize = 0;
    var q: usize = 0;
    if (d01 >= d12 and d01 >= d02) {
        tl = 2;
        p = 0;
        q = 1;
    } else if (d12 >= d01 and d12 >= d02) {
        tl = 0;
        p = 1;
        q = 2;
    } else {
        tl = 1;
        p = 0;
        q = 2;
    }
    const origin = Point{ .x = pts[tl].x, .y = pts[tl].y };
    const pa = Point{ .x = pts[p].x, .y = pts[p].y };
    const qa = Point{ .x = pts[q].x, .y = pts[q].y };
    if (cross(pa, qa, origin) >= 0.0) {
        return .{ pts[tl], pts[p], pts[q] };
    }
    return .{ pts[tl], pts[q], pts[p] };
}

// ---------------------------------------------------------------- size estimation

/// Measure the length of a dark-light-dark sequence from a center towards (dx, dy) (a unit vector).
///
/// Walking outwards from a finder center crosses the dark center run (1.5 modules), the light
/// ring (one module) and the dark outer border (one module): 3.5 modules in total. Same idea as
/// ZXing's `sizeOfBlackWhiteBlackRun`. Null when the image edge is reached first.
fn walkBlackWhiteBlack(bin: *const BitMatrix, cx: f64, cy: f64, dx: f64, dy: f64, max_len: f64) ?f64 {
    var t: f64 = 0.25;
    var state: u8 = 0; // 0 = dark center, 1 = light ring, 2 = dark outer border
    while (t <= max_len) : (t += 0.25) {
        const x = cx + dx * t;
        const y = cy + dy * t;
        if (x < 0.0 or y < 0.0) return null;
        const xi: usize = @intFromFloat(@floor(x));
        const yi: usize = @intFromFloat(@floor(y));
        if (xi >= bin.width or yi >= bin.height) return null;
        const dark = bin.get(xi, yi);
        switch (state) {
            0 => if (!dark) {
                state = 1;
            },
            1 => if (dark) {
                state = 2;
            },
            else => if (!dark) return t,
        }
    }
    return null;
}

/// Estimate the module size from the dark runs (seven modules' worth) on both sides of a finder
/// center along the given direction. The direction points at the neighbouring finder rather
/// than along an image axis, so the value stays correct for rotated symbols.
fn measureModuleAlong(bin: *const BitMatrix, c: Candidate, dx: f64, dy: f64, fallback: f64, max_len: f64) f64 {
    const plus = walkBlackWhiteBlack(bin, c.x, c.y, dx, dy, max_len) orelse return fallback;
    const minus = walkBlackWhiteBlack(bin, c.x, c.y, -dx, -dy, max_len) orelse return fallback;
    const total = plus + minus;
    if (total < 3.0) return fallback;
    return total / 7.0;
}

/// Count light/dark transitions along a line. Bouncing at boundaries is suppressed by only
/// counting a transition once the new color has held for a minimum distance.
fn countTransitions(bin: *const BitMatrix, from: Point, to: Point, hold_px: f64) ?usize {
    const dist = distance(from, to);
    if (dist < 8.0) return null;
    const steps: usize = @intFromFloat(@ceil(dist / 0.5));
    if (steps < 8) return null;
    const hold_steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(hold_px / 0.5))));

    const Sampler = struct {
        fn at(b: *const BitMatrix, a: Point, c: Point, i: usize, n: usize) bool {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const x = a.x + (c.x - a.x) * t;
            const y = a.y + (c.y - a.y) * t;
            const xi = clampUsize(@intFromFloat(@floor(x)), 0, b.width - 1);
            const yi = clampUsize(@intFromFloat(@floor(y)), 0, b.height - 1);
            return b.get(xi, yi);
        }
    };

    var transitions: usize = 0;
    var current = Sampler.at(bin, from, to, 0, steps);
    var candidate_color = current;
    var hold: usize = 0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const c = Sampler.at(bin, from, to, i, steps);
        if (c == current) {
            hold = 0;
            continue;
        }
        if (c == candidate_color) {
            hold += 1;
        } else {
            candidate_color = c;
            hold = 1;
        }
        if (hold >= hold_steps) {
            current = c;
            hold = 0;
            transitions += 1;
        }
    }
    return transitions;
}

/// Estimate the modules per side from the number of timing-pattern transitions.
///
/// Walk the straight line that runs along the timing pattern row (or column) from the
/// top-left center to the top-right (or bottom-left) center and count the light/dark changes.
/// The timing pattern alternates every module, so transitions = size - 13 (the finder patterns
/// and separators at both ends account for four of them). The count does not depend on
/// distance, so perspective and rotation rarely fool it.
fn timingDimension(bin: *const BitMatrix, tl: Point, other: Point, offset: Point, module: f64) ?usize {
    const hold = @max(1.0, module * 0.35);
    var counts: [3]usize = undefined;
    var n: usize = 0;
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const scale = 0.9 + 0.1 * @as(f64, @floatFromInt(k));
        const from = Point{ .x = tl.x + offset.x * scale, .y = tl.y + offset.y * scale };
        const to = Point{ .x = other.x + offset.x * scale, .y = other.y + offset.y * scale };
        const t = countTransitions(bin, from, to, hold) orelse continue;
        counts[n] = t + 13;
        n += 1;
    }
    if (n == 0) return null;
    var best = counts[0];
    var best_hits: usize = 0;
    for (counts[0..n]) |candidate| {
        var hits: usize = 0;
        for (counts[0..n]) |other_count| {
            const diff = if (candidate > other_count) candidate - other_count else other_count - candidate;
            if (diff <= 2) hits += 1;
        }
        if (hits > best_hits) {
            best_hits = hits;
            best = candidate;
        }
    }
    return best;
}

/// Nearest valid size (17 + 4v) to a raw estimate.
fn nearestDimension(raw: f64) ?usize {
    if (raw < 19.0 or raw > 179.0) return null;
    const rounded: isize = @intFromFloat(@round(raw));
    var v = @divTrunc(rounded - 17 + 2, 4);
    v = std.math.clamp(v, 1, 40);
    return 17 + 4 * @as(usize, @intCast(v));
}

/// List of size candidates (no duplicates, in priority order).
const DimensionCandidates = struct {
    dims: [4]usize = @splat(0),
    len: usize = 0,

    fn push(self: *DimensionCandidates, dim: usize) void {
        if (dim < min_size or dim > max_size) return;
        if ((dim - 17) % 4 != 0) return;
        for (self.dims[0..self.len]) |d| {
            if (d == dim) return;
        }
        if (self.len >= self.dims.len) return;
        self.dims[self.len] = dim;
        self.len += 1;
    }
};

// ---------------------------------------------------------------- alignment pattern

/// Inverse of the projective transform (pixel -> module coordinates), solved with Newton's method.
fn inverseMap(affine: *const Homography, px: f64, py: f64) ?Point {
    var u = px;
    var v = py;
    var iter: usize = 0;
    while (iter < 24) : (iter += 1) {
        const p = affine.map(u, v);
        const ex = p.x - px;
        const ey = p.y - py;
        if (@abs(ex) < 0.02 and @abs(ey) < 0.02) return .{ .x = u, .y = v };
        const eps = 0.25;
        const a = affine.map(u + eps, v);
        const b = affine.map(u, v + eps);
        const j00 = (a.x - p.x) / eps;
        const j10 = (a.y - p.y) / eps;
        const j01 = (b.x - p.x) / eps;
        const j11 = (b.y - p.y) / eps;
        const det = j00 * j11 - j01 * j10;
        if (@abs(det) < 1e-9) return null;
        u -= (j11 * ex - j01 * ey) / det;
        v -= (-j10 * ex + j00 * ey) / det;
    }
    return null;
}

/// Color at a pixel position. Out of range counts as light (false).
fn samplePixel(bin: *const BitMatrix, p: Point) bool {
    if (p.x < 0.0 or p.y < 0.0) return false;
    const xi: usize = @intFromFloat(@floor(p.x));
    const yi: usize = @intFromFloat(@floor(p.y));
    return bin.get(xi, yi);
}

/// Score from 0 to 1 how much a position looks like a 5x5 alignment pattern (dark center,
/// light ring, dark border).
fn scoreAlignment(bin: *const BitMatrix, affine: *const Homography, px: f64, py: f64) f64 {
    const base = inverseMap(affine, px, py) orelse return 0.0;
    var score: f64 = 0.0;
    var total: f64 = 0.0;
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const ring: u32 = @max(@abs(dx), @abs(dy));
            const want_dark = ring != 1;
            const weight: f64 = if (ring == 0) 4.0 else if (ring == 1) 2.0 else 1.0;
            const at = affine.map(
                base.x + @as(f64, @floatFromInt(dx)),
                base.y + @as(f64, @floatFromInt(dy)),
            );
            total += weight;
            if (samplePixel(bin, at) == want_dark) score += weight;
        }
    }
    return if (total == 0.0) 0.0 else score / total;
}

/// Pixel vector of one module step (from the partial derivatives of the projective transform).
fn moduleStepX(affine: *const Homography, u: f64, v: f64) Point {
    const eps = 0.5;
    const a = affine.map(u - eps, v);
    const b = affine.map(u + eps, v);
    const step = Point{ .x = (b.x - a.x) / (2 * eps), .y = (b.y - a.y) / (2 * eps) };
    if (@abs(step.x) + @abs(step.y) < 1e-9) return .{ .x = 1.0, .y = 0.0 };
    return step;
}

fn moduleStepY(affine: *const Homography, u: f64, v: f64) Point {
    const eps = 0.5;
    const a = affine.map(u, v - eps);
    const b = affine.map(u, v + eps);
    const step = Point{ .x = (b.x - a.x) / (2 * eps), .y = (b.y - a.y) / (2 * eps) };
    if (@abs(step.x) + @abs(step.y) < 1e-9) return .{ .x = 0.0, .y = 1.0 };
    return step;
}

/// Collect alignment pattern candidates by scanning runs inside a rectangle.
fn scanRunsInRect(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    scanner: *const RunScanner,
    vertical: bool,
    lo: usize,
    hi: usize,
    minor_lo: usize,
    minor_hi: usize,
    module_px: f64,
    out: *std.ArrayList(Candidate),
) Error!void {
    if (hi <= lo or minor_hi <= minor_lo) return;
    var minor = minor_lo;
    while (minor < minor_hi) : (minor += 1) {
        const nruns = buildRuns(scanner, bin, vertical, minor, lo, hi);
        if (nruns < 5) continue;
        var i: usize = 0;
        while (i + 5 <= nruns) : (i += 1) {
            const first_dark = if (vertical)
                bin.get(minor, scanner.starts[i])
            else
                bin.get(scanner.starts[i], minor);
            if (!first_dark) continue;
            var counts: [5]usize = undefined;
            for (0..5) |k| counts[k] = scanner.starts[i + k + 1] - scanner.starts[i + k];
            const module_est = alignRatio(counts, 0.7) orelse continue;
            // Drop candidates whose module size is far from the expectation (fewer accidents in the data area).
            if (module_est < module_px * 0.4 or module_est > module_px * 2.5) continue;
            // The center is the middle of the middle run (the dark center module).
            const major_center = (@as(f64, @floatFromInt(scanner.starts[i + 2])) +
                @as(f64, @floatFromInt(scanner.starts[i + 3]))) / 2.0;
            const minor_center = @as(f64, @floatFromInt(minor)) + 0.5;
            const cx = if (vertical) minor_center else major_center;
            const cy = if (vertical) major_center else minor_center;
            const first = crossCheck(bin, cx, cy, vertical, .alignment, align_ratio, 0.7, null) orelse continue;
            const second = crossCheck(bin, first.x, first.y, !vertical, .alignment, align_ratio, 0.7, null) orelse continue;
            if (out.items.len >= 512) return;
            try out.append(allocator, .{
                .x = second.x,
                .y = second.y,
                .module = (first.module + second.module) / 2.0,
            });
        }
    }
}

/// Look for the bottom-right alignment pattern (5x5). Returns the pixel center when found.
fn findAlignmentPattern(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    affine: *const Homography,
    expected: Point,
    module_px: f64,
    search_modules: f64,
) Error!?Point {
    const radius = @max(4.0, search_modules) * module_px;
    const x0f = @max(0.0, expected.x - radius);
    const y0f = @max(0.0, expected.y - radius);
    const x1f = @min(@as(f64, @floatFromInt(bin.width)), expected.x + radius);
    const y1f = @min(@as(f64, @floatFromInt(bin.height)), expected.y + radius);
    if (x1f - x0f < 3.0 or y1f - y0f < 3.0) return null;
    const lo_x: usize = @intFromFloat(x0f);
    const hi_x: usize = @intFromFloat(@ceil(x1f));
    const lo_y: usize = @intFromFloat(y0f);
    const hi_y: usize = @intFromFloat(@ceil(y1f));

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    const scanner = try RunScanner.init(allocator, @max(bin.width, bin.height));
    defer scanner.deinit(allocator);

    try scanRunsInRect(allocator, bin, &scanner, false, lo_x, hi_x, lo_y, hi_y, module_px, &candidates);
    try scanRunsInRect(allocator, bin, &scanner, true, lo_y, hi_y, lo_x, hi_x, module_px, &candidates);
    if (candidates.items.len == 0) return null;

    var best: ?Point = null;
    var best_score: f64 = 0.0;
    for (candidates.items) |c| {
        const score = scoreAlignment(bin, affine, c.x, c.y);
        const weighted = score - distance(.{ .x = c.x, .y = c.y }, expected) / @max(module_px, 1.0) * 0.05;
        if (score >= 0.72 and weighted > best_score) {
            best_score = weighted;
            best = .{ .x = c.x, .y = c.y };
        }
    }
    const coarse = best orelse return null;

    // Refine the center in 0.1 module steps towards the best template match.
    var refined = coarse;
    var best_raw = scoreAlignment(bin, affine, refined.x, refined.y);
    const step_x = moduleStepX(affine, coarse.x, coarse.y);
    const step_y = moduleStepY(affine, coarse.x, coarse.y);
    var du: f64 = -0.4;
    while (du <= 0.41) : (du += 0.1) {
        var dv: f64 = -0.4;
        while (dv <= 0.41) : (dv += 0.1) {
            const x = coarse.x + du * step_x.x + dv * step_y.x;
            const y = coarse.y + du * step_x.y + dv * step_y.y;
            const s = scoreAlignment(bin, affine, x, y);
            if (s > best_raw) {
                best_raw = s;
                refined = .{ .x = x, .y = y };
            }
        }
    }
    return refined;
}

// ---------------------------------------------------------------- grid sampling

/// Sample the center of every module five times (majority vote) according to the projective transform.
fn sampleGrid(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    transform: *const Homography,
    dim: usize,
) Error!BitMatrix {
    var grid = try BitMatrix.init(allocator, dim, dim);
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const u = @as(f64, @floatFromInt(x)) + 0.5;
            const v = @as(f64, @floatFromInt(y)) + 0.5;
            var dark: usize = 0;
            if (samplePixel(bin, transform.map(u, v))) dark += 1;
            if (samplePixel(bin, transform.map(u - 0.3, v))) dark += 1;
            if (samplePixel(bin, transform.map(u + 0.3, v))) dark += 1;
            if (samplePixel(bin, transform.map(u, v - 0.3))) dark += 1;
            if (samplePixel(bin, transform.map(u, v + 0.3))) dark += 1;
            if (dark >= 3) grid.set(x, y);
        }
    }
    return grid;
}

/// Build the transposed grid (a fallback for mirrored or flipped images).
fn transposeGrid(allocator: std.mem.Allocator, grid: *const BitMatrix) Error!BitMatrix {
    const dim = grid.width;
    var out = try BitMatrix.init(allocator, dim, dim);
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            if (grid.get(y, x)) out.set(x, y);
        }
    }
    return out;
}

// ---------------------------------------------------------------- function modules

/// Alignment pattern center positions (standard Annex E). Only `pos[0..len]` is used.
const AlignmentPositions = struct {
    pos: [7]usize = @splat(0),
    len: usize = 0,
};

/// Alignment pattern centers for a version (same derivation as qrcodegen).
fn alignmentPositions(version: u8) AlignmentPositions {
    const size = 17 + 4 * @as(usize, version);
    const num: usize = version / 7 + 2;
    const step: usize = if (version == 32)
        26
    else
        (@as(usize, version) * 4 + num * 2 + 1) / (num * 2 - 2) * 2;
    var out = AlignmentPositions{ .len = num };
    out.pos[0] = 6;
    // The last position is size - 7; earlier ones step back by `step`.
    var i: usize = 1;
    while (i < num) : (i += 1) {
        out.pos[i] = size - 7 - (num - 1 - i) * step;
    }
    return out;
}

fn markRect(func: *BitMatrix, x0: usize, y0: usize, w: usize, h: usize) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            func.set(x0 + x, y0 + y);
        }
    }
}

/// Build the map of function modules (modules that carry no data). Coordinates are (x = column, y = row).
fn buildFunctionMap(func: *BitMatrix, dim: usize, version: u8) void {
    // Finder patterns, separators and format information (a 9x9 square at three corners).
    markRect(func, 0, 0, 9, 9);
    markRect(func, dim - 8, 0, 8, 9);
    markRect(func, 0, dim - 8, 9, 8);
    // Timing patterns.
    var i: usize = 8;
    while (i < dim - 8) : (i += 1) {
        func.set(i, 6);
        func.set(6, i);
    }
    // Alignment patterns (the three that would overlap a finder pattern are not placed).
    if (version >= 2) {
        const ap = alignmentPositions(version);
        for (0..ap.len) |a| {
            for (0..ap.len) |b| {
                const skip = (a == 0 and b == 0) or (a == 0 and b == ap.len - 1) or
                    (a == ap.len - 1 and b == 0);
                if (skip) continue;
                markRect(func, ap.pos[a] - 2, ap.pos[b] - 2, 5, 5);
            }
        }
    }
    // Version information (version 7 and above).
    if (version >= 7) {
        for (0..18) |k| {
            const a = dim - 11 + k % 3;
            const c = k / 3;
            func.set(a, c);
            func.set(c, a);
        }
    }
}

// ---------------------------------------------------------------- format / version

const FormatResult = struct {
    ec: qr.EcLevel,
    mask: u3,
    distance: u3,
};

/// Module at (x, y) as 0 or 1 (x = column, y = row).
fn bitAt(grid: *const BitMatrix, x: usize, y: usize) u32 {
    return @intFromBool(grid.get(x, y));
}

/// The 32 valid format information values of standard Table C.1. Indexed by (EC bits << 3) | mask.
const format_codes: [32]u15 = blk: {
    var table: [32]u15 = undefined;
    for (0..32) |k| {
        const data: u32 = @intCast(k);
        var rem: u32 = data;
        for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        table[k] = @intCast(((data << 10) | rem) ^ 0x5412);
    }
    break :blk table;
};

/// Valid version information values of standard Table D.1 (versions 7-40). Indexed by version.
const version_codes: [41]u18 = blk: {
    var table: [41]u18 = @splat(0);
    for (7..41) |v| {
        const data: u32 = @intCast(v);
        var rem: u32 = data;
        for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        table[v] = @intCast((data << 12) | rem);
    }
    break :blk table;
};

fn ecFromFormatBits(bits: u2) qr.EcLevel {
    return switch (bits) {
        0b01 => .l,
        0b00 => .m,
        0b11 => .q,
        else => .h,
    };
}

/// Read the format information from both copies and return the valid combination with the smallest Hamming distance.
fn readFormat(grid: *const BitMatrix, dim: usize) ?FormatResult {
    var copy1: u32 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) copy1 |= bitAt(grid, 8, i) << @intCast(i);
    copy1 |= bitAt(grid, 8, 7) << 6;
    copy1 |= bitAt(grid, 8, 8) << 7;
    copy1 |= bitAt(grid, 7, 8) << 8;
    i = 9;
    while (i < 15) : (i += 1) copy1 |= bitAt(grid, 14 - i, 8) << @intCast(i);

    var copy2: u32 = 0;
    i = 0;
    while (i < 8) : (i += 1) copy2 |= bitAt(grid, dim - 1 - i, 8) << @intCast(i);
    i = 8;
    while (i < 15) : (i += 1) copy2 |= bitAt(grid, 8, dim - 15 + i) << @intCast(i);

    var best: ?FormatResult = null;
    var best_distance: u32 = 4;
    for (format_codes, 0..) |code, k| {
        const c: u32 = code;
        const d1: u32 = @popCount(c ^ copy1);
        const d2: u32 = @popCount(c ^ copy2);
        const d = @min(d1, d2);
        if (d < best_distance) {
            best_distance = d;
            best = .{
                .ec = ecFromFormatBits(@intCast(k >> 3)),
                .mask = @intCast(k & 7),
                .distance = @intCast(d),
            };
        }
    }
    return best;
}

const VersionResult = struct { version: u8, distance: u3 };

/// Read the version information (18 bits, two copies) and return the valid value with the smallest Hamming distance.
fn readVersionInfo(grid: *const BitMatrix, dim: usize) ?VersionResult {
    var copy1: u32 = 0;
    var copy2: u32 = 0;
    for (0..18) |i| {
        const a = dim - 11 + i % 3;
        const c = i / 3;
        copy1 |= bitAt(grid, a, c) << @intCast(i);
        copy2 |= bitAt(grid, c, a) << @intCast(i);
    }
    var best: ?VersionResult = null;
    var best_distance: u32 = 4;
    for (7..41) |v| {
        const code: u32 = version_codes[v];
        const d1: u32 = @popCount(code ^ copy1);
        const d2: u32 = @popCount(code ^ copy2);
        const d = @min(d1, d2);
        if (d < best_distance) {
            best_distance = d;
            best = .{ .version = @intCast(v), .distance = @intCast(d) };
        }
    }
    return best;
}

// ---------------------------------------------------------------- data extraction

/// Mask pattern (standard Table 10). True means flip. x = column, y = row.
fn maskBit(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    };
}

/// Read in zigzag order (two columns at a time from the right, alternating up and down) and undo the mask.
fn readCodewords(
    grid: *const BitMatrix,
    func: *const BitMatrix,
    dim: usize,
    mask: u3,
    out: []u8,
) Error!void {
    const total_bits = out.len * 8;
    var bit: usize = 0;
    var right: usize = dim - 1;
    while (true) {
        if (right == 6) right = 5; // skip the timing column
        var vert: usize = 0;
        while (vert < dim) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x = right - j;
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) dim - 1 - vert else vert;
                if (func.get(x, y)) continue;
                if (bit < total_bits) {
                    const dark = grid.get(x, y) != maskBit(mask, x, y);
                    if (dark) out[bit >> 3] |= @as(u8, 1) << @intCast(7 - (bit & 7));
                    bit += 1;
                }
            }
        }
        if (right < 2) break;
        right -= 2;
    }
    if (bit != total_bits) return Error.InvalidSymbol;
}

// ---------------------------------------------------------------- capacity tables

/// Error correction codewords per block (standard Table 9). Indexed by [EC][version].
/// Same values as qr.zig (a test cross-checks them against qr.zig's public API).
const ecc_codewords_per_block = [4][41]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// Number of error correction blocks (standard Table 9). Indexed by [EC][version].
const num_ec_blocks = [4][41]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// The longest QR block (data + ECC) is 186 codewords (version 40-L), so 255 is enough.
const max_block_len = 255;
const max_ec_codewords = 30;
const max_errors = max_ec_codewords / 2;
const max_blocks = 81;

// ---------------------------------------------------------------- GF(2^8) and Reed-Solomon

/// GF(2^8) with primitive polynomial 0x11D; generator roots start at alpha^0.
const gf_exp: [512]u8 = blk: {
    var table: [512]u8 = undefined;
    var x: u16 = 1;
    var i: usize = 0;
    while (i < 255) : (i += 1) {
        table[i] = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    i = 255;
    while (i < 512) : (i += 1) table[i] = table[i - 255];
    break :blk table;
};

const gf_log: [256]u8 = blk: {
    var table: [256]u8 = @splat(0);
    for (0..255) |i| table[gf_exp[i]] = @intCast(i);
    break :blk table;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + @as(usize, gf_log[b])];
}

fn gfInv(a: u8) u8 {
    return gf_exp[255 - @as(usize, gf_log[a])];
}

fn gfPow(a: u8, e: usize) u8 {
    if (a == 0) return 0;
    return gf_exp[(@as(usize, gf_log[a]) * e) % 255];
}

/// Scratch space for Reed-Solomon correction (all on the stack, no allocation).
const RsScratch = struct {
    syndromes: [max_ec_codewords]u8 = @splat(0),
    locator: [max_errors + 1]u8 = @splat(0),
    matrix: [max_errors * (max_errors + 1)]u8 = @splat(0),
    positions: [max_errors]usize = @splat(0),
    roots: [max_errors]u8 = @splat(0),
    magnitudes: [max_errors]u8 = @splat(0),
    work: [max_block_len]u8 = @splat(0),
};

/// Solve a linear system over GF(256) by Gaussian elimination. `a` is a row-major
/// rows x (cols+1) augmented matrix. False when the solution is not unique.
fn solveLinear(a: []u8, rows: usize, cols: usize, x: []u8) bool {
    const stride = cols + 1;
    var prow: usize = 0;
    var col: usize = 0;
    while (col < cols and prow < rows) : (col += 1) {
        var sel: ?usize = null;
        var r = prow;
        while (r < rows) : (r += 1) {
            if (a[r * stride + col] != 0) {
                sel = r;
                break;
            }
        }
        const p = sel orelse continue;
        if (p != prow) {
            var c: usize = col;
            while (c < stride) : (c += 1) {
                const tmp = a[p * stride + c];
                a[p * stride + c] = a[prow * stride + c];
                a[prow * stride + c] = tmp;
            }
        }
        const inv = gfInv(a[prow * stride + col]);
        var c: usize = col;
        while (c < stride) : (c += 1) a[prow * stride + c] = gfMul(a[prow * stride + c], inv);
        for (0..rows) |rr| {
            if (rr == prow) continue;
            const factor = a[rr * stride + col];
            if (factor == 0) continue;
            c = col;
            while (c < stride) : (c += 1) {
                a[rr * stride + c] ^= gfMul(factor, a[prow * stride + c]);
            }
        }
        prow += 1;
    }
    if (prow != cols) return false;
    for (0..cols) |i| x[i] = a[i * stride + cols];
    return true;
}

/// Try to correct assuming `nu` errors. Returns the number of errors, or null on failure.
fn tryCorrectCount(cw: []u8, nsym: usize, nu: usize, scratch: *RsScratch) ?usize {
    const n = cw.len;
    const stride = nu + 1;
    // Find the coefficients of the error locator polynomial (L_1..L_nu) from the PGZ system.
    for (0..nu) |i| {
        for (0..nu) |j| scratch.matrix[i * stride + j] = scratch.syndromes[i + nu - 1 - j];
        scratch.matrix[i * stride + nu] = scratch.syndromes[i + nu];
    }
    if (!solveLinear(scratch.matrix[0 .. nu * stride], nu, nu, scratch.locator[1 .. nu + 1])) return null;
    scratch.locator[0] = 1;

    // Chien search: find p with L(alpha^-p) = 0. The error position is the exponent p (X = alpha^p).
    var found: usize = 0;
    var p: usize = 0;
    while (p < n) : (p += 1) {
        const x = gf_exp[(255 - (p % 255)) % 255];
        var acc: u8 = 0;
        var k = nu + 1;
        while (k > 0) {
            k -= 1;
            acc = gfMul(acc, x) ^ scratch.locator[k];
        }
        if (acc == 0) {
            if (found >= nu) return null;
            scratch.positions[found] = n - 1 - p;
            scratch.roots[found] = gf_exp[p % 255];
            found += 1;
        }
    }
    if (found != nu) return null;

    // Error magnitudes: solve sum_k e_k X_k^i = S_i for i = 0..nu-1.
    for (0..nu) |i| {
        for (0..nu) |k| scratch.matrix[i * stride + k] = gfPow(scratch.roots[k], i);
        scratch.matrix[i * stride + nu] = scratch.syndromes[i];
    }
    if (!solveLinear(scratch.matrix[0 .. nu * stride], nu, nu, scratch.magnitudes[0..nu])) return null;

    @memcpy(scratch.work[0..n], cw);
    for (0..nu) |k| scratch.work[scratch.positions[k]] ^= scratch.magnitudes[k];
    // Verification: unless every syndrome is zero after the correction, the assumption was wrong.
    for (0..nsym) |i| {
        var s: u8 = 0;
        const x = gf_exp[i];
        for (scratch.work[0..n]) |c| s = gfMul(s, x) ^ c;
        if (s != 0) return null;
    }
    @memcpy(cw, scratch.work[0..n]);
    return nu;
}

/// Correct one block (data + ECC) in place. Returns how many errors were corrected.
fn rsCorrect(cw: []u8, nsym: usize, scratch: *RsScratch) Error!usize {
    const n = cw.len;
    if (n > max_block_len or nsym == 0 or nsym >= n) return Error.InvalidSymbol;
    var nonzero = false;
    for (0..nsym) |i| {
        var s: u8 = 0;
        const x = gf_exp[i];
        for (cw) |c| s = gfMul(s, x) ^ c;
        scratch.syndromes[i] = s;
        if (s != 0) nonzero = true;
    }
    if (!nonzero) return 0;

    const t = nsym / 2;
    var nu: usize = 1;
    while (nu <= t) : (nu += 1) {
        if (tryCorrectCount(cw, nsym, nu, scratch)) |count| return count;
    }
    return Error.TooManyErrors;
}

/// De-interleave, correct block by block, and concatenate the data codewords.
fn correctAndExtract(
    allocator: std.mem.Allocator,
    raw: []const u8,
    ec: qr.EcLevel,
    version: u8,
    data_out: []u8,
) Error!void {
    const ei = ec.index();
    const nblocks: usize = num_ec_blocks[ei][version];
    const ecc_per: usize = ecc_codewords_per_block[ei][version];
    if (nblocks == 0 or ecc_per == 0 or nblocks > max_blocks) return Error.InvalidSymbol;
    const total_data = qr.dataCodewords(ec, version);
    if (data_out.len != total_data) return Error.InvalidSymbol;
    if (raw.len < total_data + nblocks * ecc_per) return Error.InvalidSymbol;

    const short_len = total_data / nblocks;
    const num_long = total_data % nblocks;
    const max_dlen = short_len + @intFromBool(num_long > 0);
    // Standard 7.6: blocks with one extra data codeword come **last** (as in qr.zig, ZXing and segno).
    const first_long = nblocks - num_long;

    // Lay out the scratch space so each block is contiguous as [data | ECC].
    var region: [max_blocks]usize = @splat(0);
    var data_start: [max_blocks]usize = @splat(0);
    var acc: usize = 0;
    var dacc: usize = 0;
    for (0..nblocks) |b| {
        const dlen = short_len + @intFromBool(b >= first_long);
        region[b] = acc;
        data_start[b] = dacc;
        acc += dlen + ecc_per;
        dacc += dlen;
    }

    const work = try allocator.alloc(u8, raw.len);
    defer allocator.free(work);

    // De-interleave the data codewords.
    var pos: usize = 0;
    var k: usize = 0;
    while (k < max_dlen) : (k += 1) {
        for (0..nblocks) |b| {
            const dlen = short_len + @intFromBool(b >= first_long);
            if (k < dlen) {
                work[region[b] + k] = raw[pos];
                pos += 1;
            }
        }
    }
    // De-interleave the ECC codewords.
    for (0..ecc_per) |j| {
        for (0..nblocks) |b| {
            const dlen = short_len + @intFromBool(b >= first_long);
            work[region[b] + dlen + j] = raw[pos];
            pos += 1;
        }
    }

    var scratch: RsScratch = .{};
    for (0..nblocks) |b| {
        const dlen = short_len + @intFromBool(b >= first_long);
        const block = work[region[b] .. region[b] + dlen + ecc_per];
        _ = try rsCorrect(block, ecc_per, &scratch);
        @memcpy(data_out[data_start[b] .. data_start[b] + dlen], work[region[b] .. region[b] + dlen]);
    }
}

// ---------------------------------------------------------------- bit stream parsing

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const BitReader) usize {
        return self.data.len * 8 - self.pos;
    }

    fn read(self: *BitReader, count: usize) Error!u32 {
        if (count > 32) return Error.InvalidSymbol;
        if (self.pos + count > self.data.len * 8) return Error.Truncated;
        var v: u32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const bit = (self.data[self.pos >> 3] >> @intCast(7 - (self.pos & 7))) & 1;
            v = (v << 1) | bit;
            self.pos += 1;
        }
        return v;
    }
};

/// Alphanumeric mode character set (standard Table 5).
const alphanumeric_charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

fn parseNumeric(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.numeric.charCountBits(version));
    var left = count;
    while (left >= 3) : (left -= 3) {
        const v = try reader.read(10);
        if (v > 999) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v / 100));
        try sink.writeByte(@intCast('0' + (v / 10) % 10));
        try sink.writeByte(@intCast('0' + v % 10));
    }
    if (left == 2) {
        const v = try reader.read(7);
        if (v > 99) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v / 10));
        try sink.writeByte(@intCast('0' + v % 10));
    } else if (left == 1) {
        const v = try reader.read(4);
        if (v > 9) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v));
    }
}

fn parseAlphanumeric(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.alphanumeric.charCountBits(version));
    var left = count;
    while (left >= 2) : (left -= 2) {
        const v = try reader.read(11);
        if (v >= 45 * 45) return Error.InvalidSymbol;
        try sink.writeByte(alphanumeric_charset[v / 45]);
        try sink.writeByte(alphanumeric_charset[v % 45]);
    }
    if (left == 1) {
        const v = try reader.read(6);
        if (v >= 45) return Error.InvalidSymbol;
        try sink.writeByte(alphanumeric_charset[v]);
    }
}

fn parseByte(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.byte.charCountBits(version));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = try reader.read(8);
        try sink.writeByte(@intCast(b));
    }
}

/// Interpret the mode indicators in order and write the text out.
fn parseBitStream(data: []const u8, version: u8, sink: *Sink) Error!void {
    var reader = BitReader{ .data = data };
    while (reader.remaining() >= 4) {
        const mode = try reader.read(4);
        switch (mode) {
            0b0000 => return, // terminator
            0b0001 => try parseNumeric(&reader, version, sink),
            0b0010 => try parseAlphanumeric(&reader, version, sink),
            0b0100 => try parseByte(&reader, version, sink),
            // Structured append, FNC1, ECI and Kanji (JIS / GB2312) are not supported.
            0b0011, 0b0101, 0b0111, 0b1000, 0b1001, 0b1101 => return Error.UnsupportedMode,
            else => return Error.InvalidSymbol,
        }
    }
}

// ---------------------------------------------------------------- decoding one symbol

/// Check that the three corners of the grid really hold finder patterns (7x7).
///
/// This keeps a non-QR image (a screen full of text, say) from being reported as "something
/// QR-like was found but could not be read", and it discards obviously wrong grids early.
fn gridLooksLikeQr(grid: *const BitMatrix, dim: usize) bool {
    const origins = [3][2]usize{ .{ 0, 0 }, .{ dim - 7, 0 }, .{ 0, dim - 7 } };
    var mismatch: usize = 0;
    for (origins) |o| {
        var y: usize = 0;
        while (y < 7) : (y += 1) {
            var x: usize = 0;
            while (x < 7) : (x += 1) {
                // Chebyshev distance from the center (3,3): 0-1 dark, 2 light, 3 dark.
                const dx = if (x > 3) x - 3 else 3 - x;
                const dy = if (y > 3) y - 3 else 3 - y;
                const cheb = @max(dx, dy);
                const want = cheb != 2;
                if (grid.get(o[0] + x, o[1] + y) != want) mismatch += 1;
            }
        }
    }
    return mismatch <= 12;
}

/// Extract text from a grid (module matrix). False means "try another candidate".
fn decodeGrid(
    allocator: std.mem.Allocator,
    grid: *const BitMatrix,
    dim: usize,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!bool {
    if (dim < min_size or dim > max_size or (dim - 17) % 4 != 0) return false;
    if (!gridLooksLikeQr(grid, dim)) return false;
    confirmed.* = true;
    const version: u8 = @intCast((dim - 17) / 4);
    const fmt = readFormat(grid, dim) orelse {
        return false;
    };

    // From version 7 on, cross-check against the version information (a mismatch means the grid is suspect).
    if (version >= 7) {
        if (readVersionInfo(grid, dim)) |v| {
            if (v.distance <= 1 and v.version != version) return false;
        }
    }

    var func = try BitMatrix.init(allocator, dim, dim);
    defer func.deinit(allocator);
    buildFunctionMap(&func, dim, version);

    const raw_len = qr.rawCodewords(version);
    const data_len = qr.dataCodewords(fmt.ec, version);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    @memset(raw, 0);
    try readCodewords(grid, &func, dim, fmt.mask, raw);

    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    correctAndExtract(allocator, raw, fmt.ec, version, data) catch |e| switch (e) {
        Error.TooManyErrors => {
            return false;
        },
        else => return e,
    };

    parseBitStream(data, version, sink) catch |e| switch (e) {
        Error.UnsupportedMode, Error.BufferTooSmall, Error.OutOfMemory => return e,
        else => return false,
    };
    info.* = .{
        .text = sink.text(),
        .version = version,
        .ec = fmt.ec,
        .mask = fmt.mask,
    };
    return true;
}

/// Outcome of one attempt.
const AttemptResult = enum {
    /// No finder pattern triple was found
    not_found,
    /// Something was found but it could not be decoded
    corrupt,
    /// Decoded successfully
    ok,
};

/// A triple of points and its score (sorted by descending score).
const TripleScore = struct {
    score: f64,
    idx: [3]usize,
};

/// Score every triple and sort by descending score (only the best few are used).
fn collectTriples(
    allocator: std.mem.Allocator,
    pats: []const Candidate,
    relaxed: bool,
    out: *std.ArrayList(TripleScore),
) Error!void {
    if (pats.len < 3) return;
    const n = @min(pats.len, 24);
    var a: usize = 0;
    while (a < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            var c = b + 1;
            while (c < n) : (c += 1) {
                const score = scoreTriple(pats[a], pats[b], pats[c], relaxed) orelse continue;
                try out.append(allocator, .{ .score = score, .idx = .{ a, b, c } });
            }
        }
    }
    std.sort.pdq(TripleScore, out.items, {}, struct {
        fn lessThan(_: void, x: TripleScore, y: TripleScore) bool {
            return x.score > y.score;
        }
    }.lessThan);
}

/// Try to decode one symbol from the finder patterns that were found.
fn tryPatterns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    pats: []const Candidate,
    relaxed: bool,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!AttemptResult {
    var triples: std.ArrayList(TripleScore) = .empty;
    defer triples.deinit(allocator);
    try collectTriples(allocator, pats, relaxed, &triples);
    if (triples.items.len == 0) return .not_found;

    const limit = @min(triples.items.len, 6);
    var sampled = false;
    // First pass tries only triples consistent with the timing pattern; the second pass tries the rest.
    var phase: usize = 0;
    while (phase < 2) : (phase += 1) {
        const want_consistent = phase == 0;
        for (triples.items[0..limit]) |ts| {
            const ordered = orderPatterns(pats[ts.idx[0]], pats[ts.idx[1]], pats[ts.idx[2]]);
            const tl = ordered[0];
            const tr = ordered[1];
            const bl = ordered[2];

            const tl_pt = Point{ .x = tl.x, .y = tl.y };
            const tr_pt = Point{ .x = tr.x, .y = tr.y };
            const bl_pt = Point{ .x = bl.x, .y = bl.y };
            const dist_h = distance(tl_pt, tr_pt);
            const dist_v = distance(tl_pt, bl_pt);
            if (dist_h < 10.0 or dist_v < 10.0) continue;

            // Module size per direction (measured so that rotation does not distort it).
            const ux = (tr.x - tl.x) / dist_h;
            const uy = (tr.y - tl.y) / dist_h;
            const vx = (bl.x - tl.x) / dist_v;
            const vy = (bl.y - tl.y) / dist_v;
            const run_module = (tl.module + tr.module + bl.module) / 3.0;
            // A finder's dark run spans seven modules. Derive the walk limit from the distance
            // to its partner (even the shortest side is 14 modules, so 0.35x is enough).
            const walk_limit = @max(8.0, 0.35 * @min(dist_h, dist_v));
            const m_h_tl = measureModuleAlong(bin, tl, ux, uy, run_module, walk_limit);
            const m_h_tr = measureModuleAlong(bin, tr, ux, uy, run_module, walk_limit);
            const m_v_tl = measureModuleAlong(bin, tl, vx, vy, run_module, walk_limit);
            const m_v_bl = measureModuleAlong(bin, bl, vx, vy, run_module, walk_limit);
            const m_h = (m_h_tl + m_h_tr) / 2.0;
            const m_v = (m_v_tl + m_v_bl) / 2.0;
            if (m_h < 1.0 or m_v < 1.0) continue;

            // Basis of the module coordinate system (pixel vector of one module).
            const dm_h = dist_h / m_h;
            const dm_v = dist_v / m_v;
            if (dm_h < 10.0 or dm_v < 10.0) continue;
            const ex = Point{ .x = (tr.x - tl.x) / dm_h, .y = (tr.y - tl.y) / dm_h };
            const ey = Point{ .x = (bl.x - tl.x) / dm_v, .y = (bl.y - tl.y) / dm_v };

            // Measure the size from timing pattern transitions (independent of distance, so perspective is fine).
            const dim_timing_h = timingDimension(
                bin,
                tl_pt,
                tr_pt,
                .{ .x = ey.x * 3.0, .y = ey.y * 3.0 * (m_h_tr / @max(m_h_tl, 0.5)) },
                m_h,
            );
            const dim_timing_v = timingDimension(
                bin,
                tl_pt,
                bl_pt,
                .{ .x = ex.x * 3.0 * (m_v_bl / @max(m_v_tl, 0.5)), .y = ex.y * 3.0 },
                m_v,
            );
            const dim_geo_raw = (dm_h + dm_v) / 2.0 + 7.0;

            var timing_raw: ?f64 = null;
            if (dim_timing_h != null and dim_timing_v != null) {
                const ta: f64 = @floatFromInt(dim_timing_h.?);
                const tb: f64 = @floatFromInt(dim_timing_v.?);
                if (@abs(ta - tb) <= 4.0) timing_raw = (ta + tb) / 2.0;
            } else if (dim_timing_h) |t| {
                timing_raw = @floatFromInt(t);
            } else if (dim_timing_v) |t| {
                timing_raw = @floatFromInt(t);
            }
            const consistent = if (timing_raw) |t| @abs(t - dim_geo_raw) <= 5.0 else false;
            if (consistent != want_consistent) continue;

            // Size candidates in priority order: timing, geometry, then one step either way.
            var dims: DimensionCandidates = .{};
            if (timing_raw) |t| {
                if (nearestDimension(t)) |d| dims.push(d);
            }
            if (nearestDimension(dim_geo_raw)) |d| dims.push(d);
            if (dims.len > 0) {
                const first = dims.dims[0];
                if (first >= 25) {
                    dims.push(first - 4);
                    dims.push(first + 4);
                }
            }
            if (dims.len == 0) continue;

            for (dims.dims[0..dims.len]) |dim| {
                const df: f64 = @floatFromInt(dim);
                // The fourth point is the bottom-right corner (alignment center, else the parallelogram corner).
                const br = Point{ .x = tr.x + bl.x - tl.x, .y = tr.y + bl.y - tl.y };
                var transform = solveHomography(
                    .{ .{ .x = 3.5, .y = 3.5 }, .{ .x = df - 3.5, .y = 3.5 }, .{ .x = 3.5, .y = df - 3.5 }, .{ .x = df - 3.5, .y = df - 3.5 } },
                    .{ tl_pt, tr_pt, bl_pt, br },
                ) orelse continue;

                const module_px = (m_h + m_v) / 2.0;
                if (dim >= 25) {
                    const expected = transform.map(df - 6.5, df - 6.5);
                    const search_modules = @max(4.0, df / 8.0);
                    if (try findAlignmentPattern(allocator, bin, &transform, expected, module_px, search_modules)) |center| {
                        if (solveHomography(
                            .{ .{ .x = 3.5, .y = 3.5 }, .{ .x = df - 3.5, .y = 3.5 }, .{ .x = 3.5, .y = df - 3.5 }, .{ .x = df - 6.5, .y = df - 6.5 } },
                            .{ tl_pt, tr_pt, bl_pt, center },
                        )) |t2| {
                            transform = t2;
                        }
                    }
                }

                var grid = try sampleGrid(allocator, bin, &transform, dim);
                defer grid.deinit(allocator);
                sampled = true;

                sink.reset();
                if (try decodeGrid(allocator, &grid, dim, sink, info, confirmed)) return .ok;

                // Also try the transpose, as a fallback for mirrored or flipped images.
                var flipped = try transposeGrid(allocator, &grid);
                defer flipped.deinit(allocator);
                sink.reset();
                if (try decodeGrid(allocator, &flipped, dim, sink, info, confirmed)) return .ok;
            }
        }
    }
    return if (sampled) .corrupt else .not_found;
}

/// Extract one symbol from a binarized image.
///
/// Search strictly first (with the separator test) and, if that fails, search again loosely.
fn attemptDecode(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!AttemptResult {
    var detected = false;
    var relaxed = false;
    while (true) {
        const pats = try findFinderPatterns(allocator, bin, relaxed);
        defer allocator.free(pats);
        const result = try tryPatterns(allocator, bin, pats, relaxed, sink, info, confirmed);
        if (result == .ok) return .ok;
        if (result == .corrupt) detected = true;
        if (relaxed) break;
        relaxed = true;
    }
    return if (detected) .corrupt else .not_found;
}

/// Try decoding while varying the binarization settings.
fn decodeInternal(
    allocator: std.mem.Allocator,
    image: *const Image,
    sink: *Sink,
    info: *Info,
) Error!void {
    if (image.width == 0 or image.height == 0) return Error.SymbolNotFound;
    if (image.width > max_image_dim or image.height > max_image_dim) return Error.SymbolNotFound;
    const need = image.width * image.height;
    if (image.pixels.len < need) return Error.Truncated;

    var bin = try BitMatrix.init(allocator, image.width, image.height);
    defer bin.deinit(allocator);
    const sub_w = (image.width + 7) / 8;
    const sub_h = (image.height + 7) / 8;
    const black_points = try allocator.alloc(u8, sub_w * sub_h);
    defer allocator.free(black_points);

    const plans = [_]BinarizePlan{
        .{ .adaptive = true },
        .{ .adaptive = true, .invert = true },
        .{ .adaptive = false },
        .{ .adaptive = false, .invert = true },
    };
    // Marker for "a QR-like grid was sampled". When nothing was confirmed, a failure is
    // reported as "no symbol found" instead.
    var confirmed = false;
    var detected = false;
    for (plans) |plan| {
        binarize(&bin, image, plan, black_points);
        sink.reset();
        const result = try attemptDecode(allocator, &bin, sink, info, &confirmed);
        switch (result) {
            .ok => return,
            .corrupt => detected = true,
            .not_found => {},
        }
    }
    if (detected and confirmed) return Error.TooManyErrors;
    return Error.SymbolNotFound;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Test image (the pixel buffer is owned by the allocator).
const RenderedImage = struct {
    pixels: []u8,
    image: Image,

    fn deinit(self: *const RenderedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// Render a matrix into a grayscale image (test helper).
fn renderMatrix(
    allocator: std.mem.Allocator,
    m: *const qr.Matrix,
    scale: usize,
    quiet: usize,
    dark: u8,
    light: u8,
) Error!RenderedImage {
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
                    const gx = (quiet + x) * scale + px;
                    const gy = (quiet + y) * scale + py;
                    pixels[gy * total + gx] = dark;
                }
            }
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = total, .height = total, .pixels = pixels } };
}

/// Rotate an image by multiples of 90 degrees (test helper).
fn rotateQuarter(allocator: std.mem.Allocator, image: *const Image, quarters: usize) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    const q = quarters % 4;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            // The output is either (h, w) or (w, h).
            const src = image.pixels[y * w + x];
            switch (q) {
                0 => pixels[y * w + x] = src,
                1 => pixels[x * h + (h - 1 - y)] = src, // 90 degrees clockwise
                2 => pixels[(h - 1 - y) * w + (w - 1 - x)] = src,
                else => pixels[(w - 1 - x) * h + y] = src,
            }
        }
    }
    const out_w = if (q % 2 == 0) w else h;
    const out_h = if (q % 2 == 0) h else w;
    return .{ .pixels = pixels, .image = .{ .width = out_w, .height = out_h, .pixels = pixels } };
}

/// Simple test blur (one pass of a 3x3 average).
fn boxBlur(allocator: std.mem.Allocator, image: *const Image) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var sum: u32 = 0;
            var count: u32 = 0;
            var dy: isize = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: isize = -1;
                while (dx <= 1) : (dx += 1) {
                    const sx = @as(isize, @intCast(x)) + dx;
                    const sy = @as(isize, @intCast(y)) + dy;
                    if (sx < 0 or sy < 0 or sx >= @as(isize, @intCast(w)) or sy >= @as(isize, @intCast(h))) continue;
                    sum += image.pixels[@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))];
                    count += 1;
                }
            }
            pixels[y * w + x] = @intCast(sum / count);
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// Multiply by a local light gradient (test helper).
fn shade(allocator: std.mem.Allocator, image: *const Image, strength: f64) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const fx = 1.0 - strength * (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(w - 1)));
            const fy = 1.0 - strength * (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(h - 1)));
            const v = @as(f64, @floatFromInt(image.pixels[y * w + x])) * fx * fy;
            pixels[y * w + x] = @intFromFloat(std.math.clamp(v, 0.0, 255.0));
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// Scale an image up (test helper, nearest neighbour).
fn upscale(allocator: std.mem.Allocator, image: *const Image, factor: usize) Error!RenderedImage {
    const w = image.width * factor;
    const h = image.height * factor;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            pixels[y * w + x] = image.pixels[(y / factor) * image.width + (x / factor)];
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// Decode and compare against the expected text (shared test helper).
fn expectDecode(
    allocator: std.mem.Allocator,
    image: *const Image,
    expected: []const u8,
) !void {
    const text = try decode(allocator, image.*);
    defer allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "self-consistency: combinations of EC level and mode" {
    const allocator = testing.allocator;
    const cases = [_]struct { text: []const u8, ec: qr.EcLevel }{
        .{ .text = "0123456789012345678901234567890", .ec = .l },
        .{ .text = "HELLO WORLD $%*+-./: 1234", .ec = .m },
        .{ .text = "Hello, QR decoder! zig 0.17", .ec = .q },
        // Multi-byte UTF-8 payload: exercises byte mode with non-ASCII data.
        .{ .text = "日本語のテスト/QRデコーダ", .ec = .h },
        .{ .text = "12345", .ec = .h },
        .{ .text = "A", .ec = .l },
    };
    for (cases) |c| {
        const m = try qr.encode(allocator, c.text, c.ec);
        defer m.deinit(allocator);
        const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
        defer rendered.deinit(allocator);
        try expectDecode(allocator, &rendered.image, c.text);
    }
}

test "self-consistency: all eight masks" {
    const allocator = testing.allocator;
    const text = "MASK TEST 0123456789";
    var mask: u3 = 0;
    while (true) : (mask += 1) {
        const m = try qr.encodeWithMask(allocator, text, .m, mask);
        defer m.deinit(allocator);
        const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
        defer rendered.deinit(allocator);
        const info = try decodeTo(allocator, rendered.image, try allocator.alloc(u8, 64));
        defer allocator.free(info.text.ptr[0..64]);
        try testing.expectEqualStrings(text, info.text);
        try testing.expectEqual(mask, info.mask);
        try testing.expectEqual(qr.EcLevel.m, info.ec);
        if (mask == 7) break;
    }
}

test "self-consistency: versions 1 to 40" {
    const allocator = testing.allocator;
    const text = "ABCDEF123456";
    var version: u8 = 1;
    while (version <= 40) : (version += 1) {
        const m = try qr.encodeVersion(allocator, text, .l, version);
        defer m.deinit(allocator);
        const scale: usize = if (version <= 10) 3 else 2;
        const rendered = try renderMatrix(allocator, &m, scale, 4, 0, 255);
        defer rendered.deinit(allocator);
        const info_out = try allocator.alloc(u8, 64);
        defer allocator.free(info_out);
        const info = try decodeTo(allocator, rendered.image, info_out);
        try testing.expectEqualStrings(text, info.text);
        try testing.expectEqual(version, info.version);
    }
}

test "degradation: 90/180/270 degree rotation" {
    const allocator = testing.allocator;
    const text = "ROTATE ME 12345";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);
    var quarters: usize = 1;
    while (quarters < 4) : (quarters += 1) {
        const rotated = try rotateQuarter(allocator, &rendered.image, quarters);
        defer rotated.deinit(allocator);
        try expectDecode(allocator, &rotated.image, text);
    }
}

test "degradation: scaling" {
    const allocator = testing.allocator;
    const text = "SCALE 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const small = try renderMatrix(allocator, &m, 1, 4, 10, 240);
    defer small.deinit(allocator);
    try expectDecode(allocator, &small.image, text);

    const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
    defer rendered.deinit(allocator);
    const big = try upscale(allocator, &rendered.image, 3);
    defer big.deinit(allocator);
    try expectDecode(allocator, &big.image, text);
}

test "degradation: no quiet zone" {
    const allocator = testing.allocator;
    const text = "NO QUIET ZONE";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 0, 0, 255);
    defer rendered.deinit(allocator);
    try expectDecode(allocator, &rendered.image, text);
}

test "degradation: uneven lighting and blur" {
    const allocator = testing.allocator;
    const text = "ILLUMINATION 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);

    const shaded = try shade(allocator, &rendered.image, 0.7);
    defer shaded.deinit(allocator);
    try expectDecode(allocator, &shaded.image, text);

    const blurred = try boxBlur(allocator, &rendered.image);
    defer blurred.deinit(allocator);
    try expectDecode(allocator, &blurred.image, text);
}

test "degradation: paint over part of the symbol within the EC budget" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .h);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 6, 4, 0, 255);
    defer rendered.deinit(allocator);

    // Paint a black patch over the lower-right of the symbol center (away from the finders).
    var pixels = rendered.pixels;
    const side = rendered.image.width;
    const quiet_px = 4 * 6;
    const x0 = quiet_px + (m.size * 6 * 45) / 100;
    const x1 = quiet_px + (m.size * 6 * 75) / 100;
    const y0 = quiet_px + (m.size * 6 * 25) / 100;
    const y1 = quiet_px + (m.size * 6 * 45) / 100;
    var y = y0;
    while (y < y1) : (y += 1) {
        @memset(pixels[y * side + x0 .. y * side + x1], 0);
    }
    try expectDecode(allocator, &rendered.image, text);
}

test "degradation: painting beyond the EC budget fails with an error" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .l);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 6, 4, 0, 255);
    defer rendered.deinit(allocator);

    // Paint a large patch over the symbol center, away from the finders and format information.
    const side = rendered.image.width;
    const quiet_px = 4 * 6;
    const lo = quiet_px + (m.size * 6 * 25) / 100;
    const hi = quiet_px + (m.size * 6 * 75) / 100;
    var y = lo;
    while (y < hi) : (y += 1) {
        @memset(rendered.pixels[y * side + lo .. y * side + hi], 0);
    }
    // Decoding must fail with an error rather than crash.
    const result = decode(allocator, rendered.image);
    try testing.expectError(Error.TooManyErrors, result);
}

test "degradation: inverted image" {
    const allocator = testing.allocator;
    const text = "INVERTED 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);
    // Swap light and dark (some cameras deliver inverted polarity).
    for (rendered.pixels) |*p| p.* = 255 - p.*;
    try expectDecode(allocator, &rendered.image, text);
}

test "degradation: noise" {
    const allocator = testing.allocator;
    const text = "NOISE 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const noisy = try allocator.alloc(u8, rendered.pixels.len);
    defer allocator.free(noisy);
    for (rendered.pixels, 0..) |p, i| {
        const delta: i32 = @intCast(random.uintLessThan(u8, 61));
        const v = @as(i32, p) + delta - 30;
        noisy[i] = @intCast(std.math.clamp(v, 0, 255));
    }
    const image = Image{ .width = rendered.image.width, .height = rendered.image.height, .pixels = noisy };
    try expectDecode(allocator, &image, text);
}

test "broken input returns an error instead of crashing" {
    const allocator = testing.allocator;
    const empty = Image{ .width = 0, .height = 0, .pixels = &.{} };
    try testing.expectError(Error.SymbolNotFound, decode(allocator, empty));

    const short = Image{ .width = 4, .height = 4, .pixels = &[_]u8{ 0, 0 } };
    try testing.expectError(Error.Truncated, decode(allocator, short));

    const white = try allocator.alloc(u8, 64 * 64);
    defer allocator.free(white);
    @memset(white, 255);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 64, .pixels = white }));

    const black = try allocator.alloc(u8, 64 * 64);
    defer allocator.free(black);
    @memset(black, 0);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 64, .pixels = black }));

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const noise = try allocator.alloc(u8, 128 * 96);
    defer allocator.free(noise);
    for (noise) |*p| p.* = random.int(u8);
    // A random image either finds nothing or finds something unreadable; it must not crash.
    const noise_image = Image{ .width = 128, .height = 96, .pixels = noise };
    if (decode(allocator, noise_image)) |text| {
        allocator.free(text);
    } else |e| {
        try testing.expect(e == Error.SymbolNotFound or e == Error.TooManyErrors);
    }

    // Extremely thin images.
    const thin = try allocator.alloc(u8, 1 * 64);
    defer allocator.free(thin);
    @memset(thin, 0);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 1, .height = 64, .pixels = thin }));

    const thin2 = try allocator.alloc(u8, 64 * 1);
    defer allocator.free(thin2);
    @memset(thin2, 255);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 1, .pixels = thin2 }));
}

test "decodeInto: exact size and undersized buffer" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .q);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
    defer rendered.deinit(allocator);

    var buf: [64]u8 = undefined;
    const exact = try decodeInto(allocator, rendered.image, buf[0..text.len]);
    try testing.expectEqualStrings(text, exact);

    var small: [4]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, decodeInto(allocator, rendered.image, &small));
}

test "Reed-Solomon: corrects errors within capacity, fails beyond it" {
    const allocator = testing.allocator;
    _ = allocator;
    // Test-only RS encoding (remainder modulo the generator polynomial), independent of the decoder under test.
    const data = [_]u8{ 0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
    inline for (.{ 7, 10, 13, 17, 22, 30 }) |ecc_len| {
        var codeword: [16 + 30]u8 = @splat(0);
        @memcpy(codeword[0..data.len], &data);
        testRsEncode(&data, ecc_len, codeword[data.len .. data.len + ecc_len]);
        const total = data.len + ecc_len;

        // The syndromes of the codeword must all be zero (a valid codeword).
        var scratch: RsScratch = .{};
        var all_zero = true;
        for (0..ecc_len) |i| {
            var s: u8 = 0;
            const x = gf_exp[i];
            for (codeword[0..total]) |c| s = gfMul(s, x) ^ c;
            if (s != 0) all_zero = false;
        }
        try testing.expect(all_zero);

        // Errors within capacity (t = ecc/2) are corrected.
        var prng = std.Random.DefaultPrng.init(0x1234 + ecc_len);
        const random = prng.random();
        var trial: usize = 0;
        while (trial < 8) : (trial += 1) {
            var damaged: [16 + 30]u8 = @splat(0);
            @memcpy(damaged[0..total], codeword[0..total]);
            try testing.expectEqual(ecc_len / 2, corruptDistinct(&damaged, total, ecc_len / 2, random));
            const corrected = try rsCorrect(damaged[0..total], ecc_len, &scratch);
            try testing.expect(corrected <= ecc_len / 2 + 1);
            try testing.expectEqualSlices(u8, codeword[0..total], damaged[0..total]);
        }

        // Beyond capacity (t + 2 errors) the decoder either fails or lands on another codeword.
        var damaged: [16 + 30]u8 = @splat(0);
        @memcpy(damaged[0..total], codeword[0..total]);
        _ = corruptDistinct(&damaged, total, ecc_len / 2 + 2, random);
        const outcome = rsCorrect(damaged[0..total], ecc_len, &scratch);
        if (outcome) |_| {
            // When it turns into a different codeword, it must differ from the original.
            try testing.expect(!std.mem.eql(u8, codeword[0..total], damaged[0..total]));
        } else |e| {
            try testing.expectEqual(Error.TooManyErrors, e);
        }
    }
}

/// Test-only: corrupt `count` distinct positions and return how many were actually placed.
fn corruptDistinct(codeword: *[16 + 30]u8, total: usize, count: usize, random: std.Random) usize {
    var used: [16 + 30]bool = @splat(false);
    var placed: usize = 0;
    var attempts: usize = 0;
    while (placed < count and attempts < 200) : (attempts += 1) {
        const at = random.uintLessThan(usize, total);
        if (used[at]) continue;
        used[at] = true;
        const delta = random.int(u8) | 1;
        codeword[at] ^= delta;
        if (codeword[at] != 0 or delta != 0) placed += 1;
    }
    return placed;
}

/// Test-only: compute the RS ECC codewords for a data codeword sequence.
fn testRsEncode(data: []const u8, ecc_len: usize, out: []u8) void {
    // Hold the generator polynomial g(x) = prod (x - alpha^i) with ascending coefficients.
    var gen: [31]u8 = @splat(0);
    gen[0] = 1;
    var degree: usize = 0;
    for (0..ecc_len) |i| {
        const root = gf_exp[i];
        var k = degree + 1;
        while (k > 0) : (k -= 1) {
            gen[k] = gfMul(gen[k], root) ^ gen[k - 1];
        }
        gen[0] = gfMul(gen[0], root);
        degree += 1;
    }
    // Remainder by LFSR division (the data starts with the highest degree term).
    var rem: [30]u8 = @splat(0);
    for (data) |d| {
        const factor = d ^ rem[ecc_len - 1];
        var k = ecc_len - 1;
        while (k > 0) : (k -= 1) {
            rem[k] = rem[k - 1] ^ gfMul(factor, gen[k]);
        }
        rem[0] = gfMul(factor, gen[0]);
    }
    for (0..ecc_len) |k| out[k] = rem[ecc_len - 1 - k];
}

test "capacity tables agree with qr.zig's public API" {
    for (0..4) |i| {
        const ec: qr.EcLevel = switch (i) {
            0 => .l,
            1 => .m,
            2 => .q,
            else => .h,
        };
        var version: u8 = 1;
        while (version <= 40) : (version += 1) {
            const raw = qr.rawCodewords(version);
            const data = qr.dataCodewords(ec, version);
            const ecc_total = @as(usize, ecc_codewords_per_block[i][version]) * num_ec_blocks[i][version];
            try testing.expectEqual(raw, data + ecc_total);
            // The data codewords split into blocks that differ by one (the premise of standard Table 9).
            const blocks: usize = num_ec_blocks[i][version];
            try testing.expect(blocks >= 1);
            if (data / blocks < 1) return error.TestUnexpectedResult;
        }
    }
}

test "alignment pattern positions match the standard's table" {
    // Representative values from ISO/IEC 18004 Annex E.
    const expected_7 = [_]usize{ 6, 22, 38 };
    const ap7 = alignmentPositions(7);
    try testing.expectEqual(expected_7.len, ap7.len);
    for (expected_7, 0..) |v, i| try testing.expectEqual(v, ap7.pos[i]);

    const expected_32 = [_]usize{ 6, 34, 60, 86, 112, 138 };
    const ap32 = alignmentPositions(32);
    try testing.expectEqual(expected_32.len, ap32.len);
    for (expected_32, 0..) |v, i| try testing.expectEqual(v, ap32.pos[i]);

    const expected_40 = [_]usize{ 6, 30, 58, 86, 114, 142, 170 };
    const ap40 = alignmentPositions(40);
    try testing.expectEqual(expected_40.len, ap40.len);
    for (expected_40, 0..) |v, i| try testing.expectEqual(v, ap40.pos[i]);

    // The last position is always size - 7.
    var version: u8 = 2;
    while (version <= 40) : (version += 1) {
        const ap = alignmentPositions(version);
        try testing.expectEqual(17 + 4 * @as(usize, version) - 7, ap.pos[ap.len - 1]);
    }
}

test "format information: all 32 combinations" {
    const allocator = testing.allocator;
    // Build a matrix and read only its format information (the data area is irrelevant).
    const text = "FORMAT";
    for (0..32) |k| {
        const ec: qr.EcLevel = ecFromFormatBits(@intCast(k >> 3));
        const mask: u3 = @intCast(k & 7);
        const m = try qr.encodeWithMask(allocator, text, ec, mask);
        defer m.deinit(allocator);
        var grid = try BitMatrix.init(allocator, m.size, m.size);
        defer grid.deinit(allocator);
        var y: usize = 0;
        while (y < m.size) : (y += 1) {
            var x: usize = 0;
            while (x < m.size) : (x += 1) {
                if (m.get(x, y)) grid.set(x, y);
            }
        }
        const fmt = readFormat(&grid, m.size) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(ec, fmt.ec);
        try testing.expectEqual(mask, fmt.mask);
        try testing.expectEqual(@as(u3, 0), fmt.distance);
    }
}

test "version information: versions 7 to 40" {
    const allocator = testing.allocator;
    var version: u8 = 7;
    while (version <= 40) : (version += 1) {
        const m = try qr.encodeVersion(allocator, "V", .l, version);
        defer m.deinit(allocator);
        var grid = try BitMatrix.init(allocator, m.size, m.size);
        defer grid.deinit(allocator);
        var y: usize = 0;
        while (y < m.size) : (y += 1) {
            var x: usize = 0;
            while (x < m.size) : (x += 1) {
                if (m.get(x, y)) grid.set(x, y);
            }
        }
        const v = readVersionInfo(&grid, m.size) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(version, v.version);
        try testing.expectEqual(@as(u3, 0), v.distance);
    }
}
