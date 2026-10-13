//! QR Code (ISO/IEC 18004) encoder. Display only; **it does not include a decoder**.
//!
//! Its purpose is to show UR strings, addresses and signing results as QR codes on a 240x240 LCD.
//! It supports versions 1-40 so that it can handle the several-hundred-byte UR strings passed in by the signing flow.
//!
//! **Scope of the implementation**
//! - Modes: numeric / alphanumeric / byte (one symbol = one segment; no mixed-segment optimization)
//! - Error correction: L / M / Q / H (no automatic "boost error" promotion; the symbol is built exactly as requested)
//! - Versions: 1-40. The smallest is chosen automatically from the input length and EC level (it can also be requested)
//! - Mask: all 8 patterns are tried and the one with the smallest total of the 4 penalties (N1-N4) of the
//!   standard's Table 11 is chosen (ties go to the smaller number)
//! - Output: a module matrix (one byte per module, 0=light 1=dark) and an RGB565 drawing helper
//!
//! **Mask evaluation convention (the biggest branch point in the implementation)**
//! The standard's 6.8 specifies that masking is applied to the encoding region excluding the format/version
//! information, but **whether the matrix evaluated by the 4 penalties includes the format/version
//! information** is not stated explicitly. By default (`MaskEval.final_symbol`) this implementation
//! evaluates the "final symbol" with the candidate mask's format information written in. This convention
//! reproduces the worked example in the standard's Annex I.2 (encoding "01234567" at version 1-M selects
//! mask 010 = 2). In verification, 20 interpretations (writing / not writing the format information
//! x 5 variants of N3 x 2 variants of N4) were enumerated exhaustively, and this was the only combination
//! that reproduced mask 2 of Annex I.2. The other option, `MaskEval.encoding_region_only` (evaluating with
//! the format/version information left blank), is the convention taken by segno 1.6.6 and python-qrcode 8.2
//! and is used for cross-checking against third-party implementations. Under either convention the
//! generated symbol conforms to the standard and can be decoded (because the mask number is recorded in
//! the format information).
//!
//! **Known differences from third-party implementations (important)**
//! - segno 1.6.6 has a bug where it appends 8 zero bits that the standard does not require when the
//!   terminator lands exactly on a codeword boundary (heuer/segno#123, reported 2023-05, unfixed at the
//!   time of this implementation). As a result segno replaces one 0xEC pad codeword with 0x00 and shifts
//!   every following pad codeword by one byte. Byte mode hits this condition almost always, so the
//!   matrices produced by segno and by this implementation do not match in the padding region. This
//!   implementation follows the standard's 7.4.9 / 7.4.10 and adds no padding bits when the boundary is
//!   reached. (Only the position of 0xEC changes and the symbol still decodes, but this is not required
//!   by the standard.)
//! - Automatic mask selection interprets N3 differently from implementation to implementation. Following
//!   the wording of the standard's Table 11, this implementation counts "four light modules either before
//!   or after 1011101" and treats the area outside the symbol (the quiet zone) as light (the same as
//!   segno). Nayuki qrcodegen interprets it as the 1:1:3:1:1 ratio scaled up n times, and zxing /
//!   python-qrcode do not treat the area outside the symbol as light.
//! - N4 (dark module ratio) is the integer division `k = |dark% - 50%| / 5%`. Implementations vary in how
//!   they treat a boundary that is exactly a multiple of 5% in the standard's Table 11, but this
//!   implementation agrees with segno (it differs from qrcodegen's `ceil(...) - 1` only at the boundary).
//!
//! **Memory**
//! The matrix (177x177 = 31 KB at version 40) and the temporary buffers (2956 B of data codewords,
//! 3706 B of final message, 4 KB of function module flags) come from the allocator.
//! No secret data is handled (the caller is responsible for choosing the string carried in the QR code).
//!
//! **Where the test expectations come from**
//! Every embedded expectation was obtained from a third-party implementation or from the standard itself
//! (stated in each test's comments). No expectations of our own making are used. The implementations used
//! for verification:
//!   - The body and annexes of ISO/IEC 18004:2006(E) (Table C.1 / Table D.1 / the worked example in Annex I.2)
//!   - Nayuki qrcodegen 1.8.0 (Python version)
//!   - python-qrcode 8.2
//!   - segno 1.6.6 (run with only the padding bug above corrected to follow the standard)
//!
//! **Cross-check results (performed during development; also used to generate the test vectors)**
//! - Full module matrix with a forced mask: exact match with qrcodegen in all 320 cases
//!   (all 40 versions x 4 EC levels x masks {0,7}, compared by SHA-256). For the representative 56 cases
//!   (short alphanumeric, numeric, boundary lengths, Japanese UTF-8, a UR-like 700 characters, 1000 random
//!   bytes, etc. x 4 EC) it matched all three implementations: qrcodegen / python-qrcode / segno (padding
//!   corrected).
//! - Automatic version selection: exact match with the 3 implementations in the 124 cases above
//!   (31 inputs x 4 EC). The 7 cases that exceed capacity were also confirmed to error out like the 3
//!   implementations.
//! - Automatic mask selection: `MaskEval.encoding_region_only` (the same convention as segno) matched
//!   segno 117/117. The default `MaskEval.final_symbol` is the only convention that reproduces the worked
//!   example in the standard's Annex I.2 ("01234567" 1-M gives mask 2), but it can disagree on the mask with
//!   segno / python-qrcode, which do not include the format information in the evaluation (even with a
//!   different mask the output conforms to the standard and decodes to the same result).
//!
//! Reference: ISO/IEC 18004:2015/2006, https://www.qrcode.com/en/about/standards.html
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const CoreError = @import("../core/errors.zig").Error;

/// Encoding errors. QR-specific cases added to the core shared `Error`.
pub const Error = CoreError || error{
    /// Exceeds the capacity of the error correction level and version (does not fit even at version 40)
    DataTooLong,
    /// The requested version is out of range (1-40)
    InvalidVersion,
    /// The input contains characters that cannot be represented in the requested mode
    /// (non-digits in numeric mode, characters outside the standard's Table 5 in alphanumeric mode)
    InvalidCharacter,
};

/// Smallest supported version.
pub const min_version: u8 = 1;
/// Largest supported version.
pub const max_version: u8 = 40;
/// Modules per side of a version 1 symbol.
pub const min_size: usize = 17 + 4 * min_version;
/// Modules per side of a version 40 symbol.
pub const max_size: usize = 17 + 4 * max_version;
/// Number of mask patterns (standard, Table 10).
pub const mask_count: usize = 8;
/// Minimum quiet zone required by the standard's 8.1 (in modules).
pub const min_quiet_zone: u8 = 4;

/// Error correction level (standard, Table 12). The value is the 2 bits of the format information itself.
pub const EcLevel = enum(u2) {
    /// About 7% recovery
    l = 0b01,
    /// About 15% recovery
    m = 0b00,
    /// About 25% recovery
    q = 0b11,
    /// About 30% recovery
    h = 0b10,

    /// Index into the capacity tables (L=0, M=1, Q=2, H=3).
    pub fn index(self: EcLevel) usize {
        return switch (self) {
            .l => 0,
            .m => 1,
            .q => 2,
            .h => 3,
        };
    }

    /// The 2 bits placed in the format information (standard, Table 12).
    pub fn formatBits(self: EcLevel) u3 {
        return @backingInt(self);
    }

    /// Parses a single character ('l' / 'm' / 'q' / 'h'; upper case also accepted).
    pub fn fromChar(c: u8) ?EcLevel {
        return switch (c) {
            'l', 'L' => .l,
            'm', 'M' => .m,
            'q', 'Q' => .q,
            'h', 'H' => .h,
            else => null,
        };
    }

    /// Name used for on-screen display and similar.
    pub fn name(self: EcLevel) []const u8 {
        return switch (self) {
            .l => "L",
            .m => "M",
            .q => "Q",
            .h => "H",
        };
    }
};

/// Data mode (the mode indicator of the standard's Table 2).
pub const Mode = enum {
    numeric,
    alphanumeric,
    byte,

    /// Mode indicator (4 bits, standard Table 2).
    pub fn indicator(self: Mode) u4 {
        return switch (self) {
            .numeric => 0b0001,
            .alphanumeric => 0b0010,
            .byte => 0b0100,
        };
    }

    /// Bit width of the character count indicator (standard, Table 3).
    pub fn charCountBits(self: Mode, version: u8) usize {
        return switch (self) {
            .numeric => if (version <= 9) 10 else if (version <= 26) 12 else 14,
            .alphanumeric => if (version <= 9) 9 else if (version <= 26) 11 else 13,
            .byte => if (version <= 9) 8 else 16,
        };
    }

    /// Name used for on-screen display and similar.
    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .numeric => "numeric",
            .alphanumeric => "alphanumeric",
            .byte => "byte",
        };
    }

    /// Whether `text` can be represented in this mode (byte mode is always true).
    pub fn canEncode(self: Mode, text: []const u8) bool {
        return switch (self) {
            .numeric => isNumeric(text),
            .alphanumeric => isAlphanumeric(text),
            .byte => true,
        };
    }
};

/// Kind of matrix that penalty evaluation is applied to during automatic mask selection.
pub const MaskEval = enum {
    /// Evaluates the "final symbol" with the candidate mask's format information (and the dark module
    /// and version information) written in. This is the default and reproduces the worked example in the
    /// standard's Annex I.2.
    final_symbol,
    /// Evaluates with the format/version information area left blank (light). The same convention as
    /// segno 1.6.6 / python-qrcode 8.2. It does not reproduce the Annex I.2 worked example. Used for
    /// cross-checking against third-party implementations.
    encoding_region_only,
};

/// Encoding options.
pub const Options = struct {
    /// If null, the smallest version is chosen from the input length and EC level.
    version: ?u8 = null,
    /// If null, the 8 masks are evaluated and one is chosen automatically.
    mask: ?u3 = null,
    /// If null, it is detected from the input (choosing the narrowest mode: numeric, then alphanumeric, then byte).
    mode: ?Mode = null,
    /// Evaluation convention for automatic mask selection.
    mask_eval: MaskEval = .final_symbol,
};

/// Module matrix produced by encoding.
///
/// `modules` holds one byte per module (row-major, 0 = light / 1 = dark) and can be passed straight to
/// the UI layer's `screen.Bitmap` (`modules: []const u8`; anything non-zero is black).
pub const Matrix = struct {
    /// Version (1-40).
    version: u8,
    /// Modules per side (17 + 4 * version).
    size: usize,
    /// Error correction level.
    ec: EcLevel,
    /// Mask number actually used (0-7).
    mask: u3,
    /// Data mode actually used.
    mode: Mode,
    /// Modules (one byte per module, row-major, 0 = light / 1 = dark).
    modules: []u8,

    /// Width (= height; a QR symbol is square).
    pub fn width(self: *const Matrix) usize {
        return self.size;
    }

    /// Height (= width).
    pub fn height(self: *const Matrix) usize {
        return self.size;
    }

    /// Module at (x, y). Out-of-range coordinates are treated as light (false).
    pub fn get(self: *const Matrix, x: usize, y: usize) bool {
        if (x >= self.size or y >= self.size) return false;
        return self.modules[y * self.size + x] != 0;
    }

    /// Total number of dark modules.
    pub fn darkCount(self: *const Matrix) usize {
        var count: usize = 0;
        for (self.modules) |m| {
            if (m != 0) count += 1;
        }
        return count;
    }

    /// Frees the memory allocated for the matrix. `self` must not be used afterwards.
    pub fn deinit(self: *const Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
    }
};

// ---------------------------------------------------------------- public API

/// Builds a matrix with the smallest version and an automatic mask (the most common entry point).
pub fn encode(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{});
}

/// Builds a matrix with a fixed mask (for verification and comparison).
pub fn encodeWithMask(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, mask: u3) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{ .mask = mask });
}

/// Builds a matrix with a fixed version (returns `DataTooLong` if it does not fit).
pub fn encodeVersion(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, version: u8) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{ .version = version });
}

/// Builds a matrix with the given options.
pub fn encodeOptions(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, opts: Options) Error!Matrix {
    const mode = opts.mode orelse detectMode(text);
    // When a mode is requested explicitly, characters that the mode cannot represent are rejected
    // (never silently build a broken symbol; even for display only, failing is better than showing a wrong QR code).
    if (!mode.canEncode(text)) return Error.InvalidCharacter;
    const version = opts.version orelse try selectVersion(mode, text.len, ec);
    if (version < min_version or version > max_version) return Error.InvalidVersion;

    const count_bits = mode.charCountBits(version);
    if (text.len >= (@as(usize, 1) << @intCast(count_bits))) return Error.DataTooLong;
    const capacity_bits = dataCodewords(ec, version) * 8;
    if (4 + count_bits + dataBitLength(mode, text.len) > capacity_bits) return Error.DataTooLong;

    const size = versionSize(version);
    const data_len = dataCodewords(ec, version);
    const raw_len = rawCodewords(version);

    // Data codewords
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    @memset(data, 0);
    var bit_len: usize = 0;
    writeData(data, &bit_len, mode, text, version);
    writePadding(data, &bit_len, capacity_bits);

    // Final message with error correction added and interleaved
    const message = try allocator.alloc(u8, raw_len);
    defer allocator.free(message);
    try buildMessage(allocator, data, message, ec, version);

    // The matrix itself and the function module flags (one bit per module)
    const modules = try allocator.alloc(u8, size * size);
    errdefer allocator.free(modules);
    const func = try allocator.alloc(u8, (size * size + 7) / 8);
    defer allocator.free(func);
    @memset(func, 0);
    @memset(modules, 0);

    var builder = Builder{ .size = size, .modules = modules, .func = func };
    buildMatrix(&builder, message, ec, version, opts);

    return Matrix{
        .version = version,
        .size = size,
        .ec = ec,
        .mask = builder.mask,
        .mode = mode,
        .modules = modules,
    };
}

/// Chooses the best single mode for the input.
///
/// Digits only means numeric mode, only the 45 alphanumeric characters of the standard's Table 5 means
/// alphanumeric mode, and anything else (Japanese UTF-8, for example) means byte mode. No mixed-mode
/// optimization is done.
pub fn detectMode(text: []const u8) Mode {
    if (isNumeric(text)) return .numeric;
    if (isAlphanumeric(text)) return .alphanumeric;
    return .byte;
}

// ---------------------------------------------------------------- RGB565 drawing

/// RGB565 drawing options.
pub const DrawOptions = struct {
    /// Color of dark modules (black by default).
    dark: u16 = 0x0000,
    /// Color of light modules and the quiet zone (white by default).
    light: u16 = 0xFFFF,
    /// Pixels per module (scale factor). 0 draws nothing.
    scale: u8 = 1,
    /// Quiet zone (in modules). The standard requires 4 or more.
    quiet_zone: u8 = min_quiet_zone,
    /// Drawing origin (top-left pixel coordinate). Negative values are allowed and overflow is clipped.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
};

/// Drawing size including the quiet zone (pixels per side).
pub fn pixelSize(m: *const Matrix, opts: DrawOptions) usize {
    if (opts.scale == 0) return 0;
    return (m.size + 2 * @as(usize, opts.quiet_zone)) * @as(usize, opts.scale);
}

/// Whether the whole drawing including the quiet zone fits in the framebuffer. A negative origin (implying clipping) is false.
pub fn fitsIn(m: *const Matrix, fb_width: usize, fb_height: usize, opts: DrawOptions) bool {
    if (opts.scale == 0) return false;
    if (opts.origin_x < 0 or opts.origin_y < 0) return false;
    const px = pixelSize(m, opts);
    const x: usize = @intCast(opts.origin_x);
    const y: usize = @intCast(opts.origin_y);
    if (x >= fb_width or y >= fb_height) return false;
    return px <= fb_width - x and px <= fb_height - y;
}

/// Draws the matrix into an RGB565 framebuffer (row-major, one u16 per pixel).
///
/// - The quiet zone (`opts.quiet_zone`) and the scale factor (`opts.scale`) can be specified.
/// - Only the square "quiet zone + symbol" area is drawn. Pixels outside it are left untouched.
/// - Parts that overflow the framebuffer are clipped (a negative origin is allowed).
/// - If `buffer.len` is smaller than `fb_width * fb_height`, only the rows that fit are drawn.
pub fn drawRgb565(
    m: *const Matrix,
    buffer: []u16,
    fb_width: usize,
    fb_height: usize,
    opts: DrawOptions,
) void {
    if (fb_width == 0 or fb_height == 0 or opts.scale == 0) return;
    const rows = @min(fb_height, buffer.len / fb_width);
    if (rows == 0) return;

    const total = m.size + 2 * @as(usize, opts.quiet_zone);
    const scale: i64 = opts.scale;

    var my: usize = 0;
    while (my < total) : (my += 1) {
        const py0 = clipStart(@as(i64, opts.origin_y) + @as(i64, @intCast(my)) * scale, rows);
        const py1 = clipEnd(@as(i64, opts.origin_y) + (@as(i64, @intCast(my)) + 1) * scale, rows);
        if (py1 <= py0) continue;

        var mx: usize = 0;
        while (mx < total) : (mx += 1) {
            const px0 = clipStart(@as(i64, opts.origin_x) + @as(i64, @intCast(mx)) * scale, fb_width);
            const px1 = clipEnd(@as(i64, opts.origin_x) + (@as(i64, @intCast(mx)) + 1) * scale, fb_width);
            if (px1 <= px0) continue;

            const dark = if (mx >= opts.quiet_zone and my >= opts.quiet_zone)
                m.get(mx - opts.quiet_zone, my - opts.quiet_zone)
            else
                false;
            const color = if (dark) opts.dark else opts.light;

            var py = py0;
            while (py < py1) : (py += 1) {
                @memset(buffer[py * fb_width + px0 .. py * fb_width + px1], color);
            }
        }
    }
}

/// Clamps values below 0 to 0 and values above `limit` to `limit` (clip start position).
fn clipStart(value: i64, limit: usize) usize {
    if (value <= 0) return 0;
    const v: usize = @intCast(value);
    return @min(v, limit);
}

/// Clamps values below 0 to 0 and values above `limit` to `limit` (clip end position).
fn clipEnd(value: i64, limit: usize) usize {
    if (value <= 0) return 0;
    const v: usize = @intCast(value);
    return @min(v, limit);
}

// ---------------------------------------------------------------- capacity tables

/// Error correction codewords per block (standard, Table 9). Indexed by [EC][version].
/// version 0 is unused (0). The values were confirmed to match exactly between segno 1.6.6's
/// `consts.ECC` and qrcodegen 1.8.0's `_ECC_CODEWORDS_PER_BLOCK`.
const ecc_codewords_per_block = [4][max_version + 1]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// Number of error correction blocks (standard, Table 9). Indexed by [EC][version].
const num_ec_blocks = [4][max_version + 1]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// Returns the number of modules per side of the symbol for a version.
pub fn versionSize(version: u8) usize {
    return 17 + 4 * @as(usize, version);
}

/// Number of modules available for data and error correction (including remainder bits).
///
/// Formula derived from the standard's placement rules (the same as Nayuki qrcodegen's `getNumRawDataModules`).
fn numRawDataModules(version: u8) usize {
    const v: usize = version;
    var result: usize = (16 * v + 128) * v + 64;
    if (version >= 2) {
        const num_align: usize = v / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

/// Total number of codewords (data + error correction).
pub fn rawCodewords(version: u8) usize {
    return numRawDataModules(version) / 8;
}

/// Number of data codewords (excluding error correction).
pub fn dataCodewords(ec: EcLevel, version: u8) usize {
    const i = ec.index();
    return rawCodewords(version) - @as(usize, ecc_codewords_per_block[i][version]) * num_ec_blocks[i][version];
}

/// Largest number of data bits that fits within the data codewords available to hold them.
pub fn capacityBits(ec: EcLevel, version: u8) usize {
    return dataCodewords(ec, version) * 8;
}

/// Data bits needed to store `len` characters in the given mode (including the mode and character count indicators).
pub fn requiredBits(mode: Mode, len: usize, version: u8) usize {
    return 4 + mode.charCountBits(version) + dataBitLength(mode, len);
}

/// Chooses the smallest version from the input length and EC level.
fn selectVersion(mode: Mode, len: usize, ec: EcLevel) Error!u8 {
    var version: u8 = min_version;
    while (version <= max_version) : (version += 1) {
        const count_bits = mode.charCountBits(version);
        // If it does not fit in the character count indicator, skip ahead to a version with a wider indicator.
        if (len >= (@as(usize, 1) << @intCast(count_bits))) continue;
        if (requiredBits(mode, len, version) <= capacityBits(ec, version)) return version;
    }
    return Error.DataTooLong;
}

/// Data bits per mode (excluding the mode indicator and character count indicator).
fn dataBitLength(mode: Mode, len: usize) usize {
    return switch (mode) {
        .numeric => 10 * (len / 3) + switch (len % 3) {
            0 => @as(usize, 0),
            1 => @as(usize, 4),
            else => @as(usize, 7),
        },
        .alphanumeric => 11 * (len / 2) + 6 * (len % 2),
        .byte => 8 * len,
    };
}

// ---------------------------------------------------------------- mode detection

/// Whether all characters are ASCII digits (an empty slice is true).
fn isNumeric(text: []const u8) bool {
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Whether all characters are among the 45 alphanumeric characters of the standard's Table 5 (an empty slice is true).
fn isAlphanumeric(text: []const u8) bool {
    for (text) |c| {
        if (alphanumericValue(c) == null) return false;
    }
    return true;
}

/// Value in alphanumeric mode (standard, Table 5). 0-44.
fn alphanumericValue(c: u8) ?u6 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'Z' => @intCast(c - 'A' + 10),
        ' ' => 36,
        '$' => 37,
        '%' => 38,
        '*' => 39,
        '+' => 40,
        '-' => 41,
        '.' => 42,
        '/' => 43,
        ':' => 44,
        else => null,
    };
}

// ---------------------------------------------------------------- bit stream

/// Appends to the bit stream. `buf` must be initialized to zero.
fn appendBits(buf: []u8, bit_len: *usize, value: u32, count: usize) void {
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const bit = (value >> @intCast(i)) & 1;
        if (bit != 0) {
            buf[bit_len.* >> 3] |= @as(u8, 1) << @intCast(7 - (bit_len.* & 7));
        }
        bit_len.* += 1;
    }
}

/// Writes the mode indicator, the character count indicator and the data payload.
fn writeData(buf: []u8, bit_len: *usize, mode: Mode, text: []const u8, version: u8) void {
    appendBits(buf, bit_len, mode.indicator(), 4);
    appendBits(buf, bit_len, @intCast(text.len), mode.charCountBits(version));

    switch (mode) {
        .numeric => {
            var i: usize = 0;
            while (i + 3 <= text.len) : (i += 3) {
                const v: u32 = @as(u32, text[i] - '0') * 100 +
                    @as(u32, text[i + 1] - '0') * 10 +
                    @as(u32, text[i + 2] - '0');
                appendBits(buf, bit_len, v, 10);
            }
            const rest = text.len - i;
            if (rest == 1) {
                appendBits(buf, bit_len, @as(u32, text[i] - '0'), 4);
            } else if (rest == 2) {
                appendBits(buf, bit_len, @as(u32, text[i] - '0') * 10 + @as(u32, text[i + 1] - '0'), 7);
            }
        },
        .alphanumeric => {
            var i: usize = 0;
            while (i + 2 <= text.len) : (i += 2) {
                const a = alphanumericValue(text[i]).?;
                const b = alphanumericValue(text[i + 1]).?;
                appendBits(buf, bit_len, @as(u32, a) * 45 + @as(u32, b), 11);
            }
            if (i < text.len) {
                appendBits(buf, bit_len, alphanumericValue(text[i]).?, 6);
            }
        },
        .byte => {
            for (text) |c| appendBits(buf, bit_len, c, 8);
        },
    }
}

/// Terminator, zero padding up to the boundary and pad codewords (standard, 7.4.9 / 7.4.10).
fn writePadding(buf: []u8, bit_len: *usize, capacity: usize) void {
    // Terminator (at most 4 bits; if less than 4 bits of capacity remain, stop there).
    const terminator = @min(@as(usize, 4), capacity - bit_len.*);
    appendBits(buf, bit_len, 0, terminator);

    // Pad with zeros up to the codeword boundary. **Do nothing if already on the boundary** (standard, 7.4.10).
    // Adding 8 bits here is the segno 1.6.6 bug (heuer/segno#123).
    if (bit_len.* % 8 != 0) {
        appendBits(buf, bit_len, 0, 8 - (bit_len.* % 8));
    }

    // The rest alternates the pad codewords 11101100 / 00010001.
    var pad: u8 = 0xEC;
    while (bit_len.* + 8 <= capacity) {
        appendBits(buf, bit_len, pad, 8);
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }
}

// ---------------------------------------------------------------- error correction

/// Arithmetic in GF(2^8) (primitive polynomial 0x11D). QR error correction is done over this field.
const Gf = struct {
    const exp: [512]u8 = blk: {
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

    const log: [256]u8 = blk: {
        var table: [256]u8 = @splat(0);
        for (0..255) |i| table[exp[i]] = @intCast(i);
        break :blk table;
    };

    fn multiply(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return exp[@as(usize, log[a]) + @as(usize, log[b])];
    }
};

/// Coefficients of the degree-`degree` generator polynomial (x - α^0)(x - α^1)... (excluding the leading 1).
fn rsDivisor(degree: usize, out: []u8) void {
    std.debug.assert(out.len == degree);
    @memset(out, 0);
    out[degree - 1] = 1;
    var root: u8 = 1;
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = 0;
        while (j < degree) : (j += 1) {
            out[j] = Gf.multiply(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = Gf.multiply(root, 0x02);
    }
}

/// Writes the remainder of `data` divided by the generator polynomial (= the error correction codewords) to `out`.
fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    std.debug.assert(out.len == divisor.len);
    @memset(out, 0);
    for (data) |b| {
        const factor = b ^ out[0];
        var i: usize = 0;
        while (i + 1 < out.len) : (i += 1) out[i] = out[i + 1];
        out[out.len - 1] = 0;
        i = 0;
        while (i < out.len) : (i += 1) out[i] ^= Gf.multiply(divisor[i], factor);
    }
}

/// Splits the data codewords into blocks, adds error correction and interleaves them in the order of the
/// standard's 7.6.
fn buildMessage(
    allocator: std.mem.Allocator,
    data: []const u8,
    message: []u8,
    ec: EcLevel,
    version: u8,
) Error!void {
    const i = ec.index();
    const blocks: usize = num_ec_blocks[i][version];
    const ecc_len: usize = ecc_codewords_per_block[i][version];
    const raw_len = message.len;
    const short_len = raw_len / blocks; // "data + EC" length of a short block
    const num_short = blocks - raw_len % blocks;

    const ecc_all = try allocator.alloc(u8, blocks * ecc_len);
    defer allocator.free(ecc_all);

    var divisor_buf: [30]u8 = undefined;
    const divisor = divisor_buf[0..ecc_len];
    rsDivisor(ecc_len, divisor);

    // Per-block data length: long blocks get short_len - ecc_len + 1.
    var offset: usize = 0;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const data_len = short_len - ecc_len + @as(usize, if (b < num_short) 0 else 1);
        rsRemainder(data[offset .. offset + data_len], divisor, ecc_all[b * ecc_len ..][0..ecc_len]);
        offset += data_len;
    }

    // Interleave the data codewords (short blocks skip their last byte).
    var out: usize = 0;
    var k: usize = 0;
    const max_data_len = short_len - ecc_len + 1;
    while (k < max_data_len) : (k += 1) {
        offset = 0;
        b = 0;
        while (b < blocks) : (b += 1) {
            const data_len = short_len - ecc_len + @as(usize, if (b < num_short) 0 else 1);
            if (k < data_len) {
                message[out] = data[offset + k];
                out += 1;
            }
            offset += data_len;
        }
    }

    // Interleave the error correction codewords.
    k = 0;
    while (k < ecc_len) : (k += 1) {
        b = 0;
        while (b < blocks) : (b += 1) {
            message[out] = ecc_all[b * ecc_len + k];
            out += 1;
        }
    }
    std.debug.assert(out == raw_len);
}

// ---------------------------------------------------------------- bit operations

fn getBit(buf: []const u8, index: usize) bool {
    return (buf[index >> 3] >> @intCast(7 - (index & 7))) & 1 != 0;
}

fn setBit(buf: []u8, index: usize, dark: bool) void {
    const mask: u8 = @as(u8, 1) << @intCast(7 - (index & 7));
    if (dark) {
        buf[index >> 3] |= mask;
    } else {
        buf[index >> 3] &= ~mask;
    }
}

// ---------------------------------------------------------------- matrix construction

/// Working struct used while building the matrix. `modules` holds one byte per module, and
/// `func` holds one bit per module marking function modules (excluded from masking).
const Builder = struct {
    size: usize,
    modules: []u8,
    func: []u8,
    mask: u3 = 0,

    fn isFunc(self: *const Builder, x: usize, y: usize) bool {
        return getBit(self.func, y * self.size + x);
    }

    fn setFunc(self: *const Builder, x: usize, y: usize, dark: bool) void {
        setBit(self.func, y * self.size + x, true);
        self.modules[y * self.size + x] = @intFromBool(dark);
    }

    fn setData(self: *const Builder, x: usize, y: usize, dark: bool) void {
        self.modules[y * self.size + x] = @intFromBool(dark);
    }

    /// Flips a module between light and dark (for masking).
    /// `modules` holds one byte per module, so the value itself is swapped rather than a bit being toggled.
    fn toggleModule(self: *const Builder, x: usize, y: usize) void {
        const i = y * self.size + x;
        self.modules[i] = if (self.modules[i] != 0) 0 else 1;
    }
};

/// Builds the matrix, chooses and applies a mask, and writes the format/version information.
fn buildMatrix(b: *Builder, message: []const u8, ec: EcLevel, version: u8, opts: Options) void {
    drawFinderPatterns(b);
    drawTimingPatterns(b);
    drawAlignmentPatterns(b, version);
    reserveFormatInfo(b);
    if (version >= 7) reserveVersionInfo(b);
    placeData(b, message);

    // Under the final-symbol evaluation convention, write the version information (mask-independent) first.
    if (version >= 7 and opts.mask_eval == .final_symbol) drawVersionInfo(b, version);

    b.mask = chooseMask(b, ec, opts);
    applyMask(b, b.mask);
    if (version >= 7) drawVersionInfo(b, version);
    drawFormatInfo(b, ec, b.mask);
}

/// Tries the 8 masks and returns the one with the smallest penalty (not applied at this point).
fn chooseMask(b: *Builder, ec: EcLevel, opts: Options) u3 {
    if (opts.mask) |forced| return forced;

    var best: u3 = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var candidate: u3 = 0;
    while (true) : (candidate += 1) {
        applyMask(b, candidate);
        if (opts.mask_eval == .final_symbol) drawFormatInfo(b, ec, candidate);
        const score = penaltyScore(b.size, b.modules);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
        applyMask(b, candidate); // XOR, so applying it once more restores the original
        if (candidate == mask_count - 1) break;
    }
    return best;
}

/// Mask conditions of the standard's Table 10 (x = column = j, y = row = i). True means the module is flipped.
fn maskCondition(mask: u3, x: usize, y: usize) bool {
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

/// XORs the mask onto the encoding region (everything except function modules). Calling it twice restores the original.
fn applyMask(b: *Builder, mask: u3) void {
    var y: usize = 0;
    while (y < b.size) : (y += 1) {
        var x: usize = 0;
        while (x < b.size) : (x += 1) {
            if (b.isFunc(x, y)) continue;
            if (maskCondition(mask, x, y)) b.toggleModule(x, y);
        }
    }
}

/// Finder patterns in the three corners (8x8 areas including the separators).
fn drawFinderPatterns(b: *Builder) void {
    const size = b.size;
    const corners = [3][2]usize{
        .{ 0, 0 },
        .{ size - 7, 0 },
        .{ 0, size - 7 },
    };
    for (corners) |corner| {
        const cx = corner[0];
        const cy = corner[1];
        var dy: isize = -1;
        while (dy <= 7) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 7) : (dx += 1) {
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x < 0 or y < 0 or x >= @as(isize, @intCast(size)) or y >= @as(isize, @intCast(size))) continue;
                const inner = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6;
                const dark = inner and (dx == 0 or dx == 6 or dy == 0 or dy == 6 or
                    (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4));
                b.setFunc(@intCast(x), @intCast(y), dark);
            }
        }
    }
}

/// Timing patterns (row 6 and column 6, even indices dark).
fn drawTimingPatterns(b: *Builder) void {
    var i: usize = 0;
    while (i < b.size) : (i += 1) {
        if (!b.isFunc(i, 6)) b.setFunc(i, 6, i % 2 == 0);
        if (!b.isFunc(6, i)) b.setFunc(6, i, i % 2 == 0);
    }
}

/// Alignment patterns (positions from the standard's Annex E; absent in version 1).
fn drawAlignmentPatterns(b: *Builder, version: u8) void {
    if (version == 1) return;
    var positions: [7]usize = undefined;
    const count = alignmentPositions(version, &positions);
    const size = b.size;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = 0;
        while (j < count) : (j += 1) {
            const cx = positions[j];
            const cy = positions[i];
            // Do not place them at the three positions that overlap the finder patterns.
            const near_finder = (cx == 6 and cy == 6) or
                (cx == 6 and cy == size - 7) or
                (cx == size - 7 and cy == 6);
            if (near_finder) continue;

            var dy: isize = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: isize = -2;
                while (dx <= 2) : (dx += 1) {
                    const x = @as(isize, @intCast(cx)) + dx;
                    const y = @as(isize, @intCast(cy)) + dy;
                    const dark = dx == -2 or dx == 2 or dy == -2 or dy == 2 or (dx == 0 and dy == 0);
                    b.setFunc(@intCast(x), @intCast(y), dark);
                }
            }
        }
    }
}

/// Center coordinates of the alignment patterns (standard, Annex E). Writes them to `out` in ascending order and returns the count.
fn alignmentPositions(version: u8, out: *[7]usize) usize {
    if (version == 1) return 0;
    const v: usize = version;
    const size = versionSize(version);
    const num_align: usize = v / 7 + 2;
    const step: usize = if (version == 32)
        26
    else
        (v * 4 + num_align * 2 + 1) / (num_align * 2 - 2) * 2;

    // 6 and the values obtained by subtracting step repeatedly from size-7. Sorted into ascending order at the end.
    var buffer: [7]usize = undefined;
    buffer[0] = 6;
    var pos = size - 7;
    var n: usize = num_align;
    while (n > 1) {
        n -= 1;
        buffer[n] = pos;
        if (n > 1) pos -= step;
    }
    for (0..num_align) |i| out[i] = buffer[i];
    return num_align;
}

/// Reserves the format information area as function modules (value light; written later).
fn reserveFormatInfo(b: *Builder) void {
    const size = b.size;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (i != 6) b.setFunc(8, i, false);
        if (i != 6) b.setFunc(i, 8, false);
    }
    i = 0;
    while (i < 8) : (i += 1) b.setFunc(size - 1 - i, 8, false);
    i = 0;
    while (i < 7) : (i += 1) b.setFunc(8, size - 1 - i, false);
    b.setFunc(8, size - 8, false); // dark module (always made dark later)
}

/// Reserves the version information area (version 7 and above) as function modules.
fn reserveVersionInfo(b: *Builder) void {
    const size = b.size;
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const a = size - 11 + i % 3;
        const c = i / 3;
        b.setFunc(a, c, false);
        b.setFunc(c, a, false);
    }
}

/// Places the data codewords in the order of the standard's 7.7 (two columns at a time, zigzagging from the bottom right).
fn placeData(b: *Builder, message: []const u8) void {
    const size = b.size;
    const total_bits = message.len * 8;
    var bit: usize = 0;

    var right: usize = size - 1;
    while (true) {
        if (right == 6) right = 5; // skip the timing column
        var vert: usize = 0;
        while (vert < size) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x = right - j;
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) size - 1 - vert else vert;
                if (b.isFunc(x, y)) continue;
                var dark = false;
                if (bit < total_bits) dark = getBit(message, bit);
                b.setData(x, y, dark);
                bit += 1;
            }
        }
        if (right < 2) break;
        right -= 2;
    }
}

/// Writes the format information (15 bits, the standard's 7.9) and the dark module.
fn drawFormatInfo(b: *Builder, ec: EcLevel, mask: u3) void {
    const size = b.size;
    const bits = formatBits(ec, mask);

    var i: usize = 0;
    while (i < 6) : (i += 1) b.setFunc(8, i, getBit15(bits, i));
    b.setFunc(8, 7, getBit15(bits, 6));
    b.setFunc(8, 8, getBit15(bits, 7));
    b.setFunc(7, 8, getBit15(bits, 8));
    i = 9;
    while (i < 15) : (i += 1) b.setFunc(14 - i, 8, getBit15(bits, i));

    i = 0;
    while (i < 8) : (i += 1) b.setFunc(size - 1 - i, 8, getBit15(bits, i));
    i = 8;
    while (i < 15) : (i += 1) b.setFunc(8, size - 15 + i, getBit15(bits, i));

    // Standard 6.9.1: the module at (4V+9, 8) is always dark.
    b.setFunc(8, size - 8, true);
}

/// Version information (18 bits, the standard's 7.10). Does nothing below version 7.
fn drawVersionInfo(b: *Builder, version: u8) void {
    if (version < 7) return;
    const size = b.size;
    const bits = versionBits(version);
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const a = size - 11 + i % 3;
        const c = i / 3;
        b.setFunc(a, c, getBit18(bits, i));
        b.setFunc(c, a, getBit18(bits, i));
    }
}

/// Bit sequence of the format information (5 data bits + 10 BCH bits, XORed with 0x5412).
fn formatBits(ec: EcLevel, mask: u3) u15 {
    const data: u32 = (@as(u32, ec.formatBits()) << 3) | @as(u32, mask);
    var rem: u32 = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return @intCast(((data << 10) | rem) ^ 0x5412);
}

/// Bit sequence of the version information (6 data bits + 12 Golay bits).
fn versionBits(version: u8) u18 {
    const data: u32 = version;
    var rem: u32 = data;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return @intCast((data << 12) | rem);
}

fn getBit15(bits: u15, index: usize) bool {
    return (bits >> @intCast(index)) & 1 != 0;
}

fn getBit18(bits: u18, index: usize) bool {
    return (bits >> @intCast(index)) & 1 != 0;
}

// ---------------------------------------------------------------- penalties

/// Total of the 4 penalties of the standard's Table 11.
fn penaltyScore(size: usize, modules: []const u8) u32 {
    return penaltyRuns(size, modules) + penaltyBlocks(size, modules) +
        penaltyFinderLike(size, modules) + penaltyBalance(size, modules);
}

/// N1: rows and columns with 5 or more consecutive same-color modules (3 points at 5, +1 for each extra module).
fn penaltyRuns(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var run: usize = 1;
        var x: usize = 1;
        while (x < size) : (x += 1) {
            if (modules[y * size + x] == modules[y * size + x - 1]) {
                run += 1;
            } else {
                if (run >= 5) score += @intCast(run - 2);
                run = 1;
            }
        }
        if (run >= 5) score += @intCast(run - 2);
    }

    var x: usize = 0;
    while (x < size) : (x += 1) {
        var run: usize = 1;
        var yy: usize = 1;
        while (yy < size) : (yy += 1) {
            if (modules[yy * size + x] == modules[(yy - 1) * size + x]) {
                run += 1;
            } else {
                if (run >= 5) score += @intCast(run - 2);
                run = 1;
            }
        }
        if (run >= 5) score += @intCast(run - 2);
    }

    return score;
}

/// N2: 2x2 blocks of the same color (3 points each; overlaps are also counted).
fn penaltyBlocks(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;
    var y: usize = 0;
    while (y + 1 < size) : (y += 1) {
        var x: usize = 0;
        while (x + 1 < size) : (x += 1) {
            const c = modules[y * size + x];
            if (c == modules[y * size + x + 1] and
                c == modules[(y + 1) * size + x] and
                c == modules[(y + 1) * size + x + 1])
            {
                score += 3;
            }
        }
    }
    return score;
}

/// N3: 1:1:3:1:1 (1011101) with four light modules either before or after it (40 points each).
/// The area outside the symbol is the quiet zone, so it is treated as light.
///
/// Scanning follows segno 1.6.6: advance 7 after a match, advance 4 when the condition is not met.
/// 1011101 can appear overlapping itself when shifted by 4 or more modules (for example the 0 and 4 of
/// 1011101 1101), but to avoid counting the same 1:1:3:1:1 region twice, reading advances past the
/// occurrence that was counted.
fn penaltyFinderLike(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;
    var line: usize = 0;
    while (line < size) : (line += 1) {
        score += penaltyFinderLikeLine(size, modules, line, true);
        score += penaltyFinderLikeLine(size, modules, line, false);
    }
    return score;
}

fn moduleAt(size: usize, modules: []const u8, line: usize, index: usize, comptime row: bool) bool {
    const v = if (row) modules[line * size + index] else modules[index * size + line];
    return v != 0;
}

fn penaltyFinderLikeLine(size: usize, modules: []const u8, line: usize, comptime row: bool) u32 {
    if (size < 7) return 0;
    const pattern = [7]bool{ true, false, true, true, true, false, true };
    var score: u32 = 0;

    var i: usize = 0;
    while (i + 7 <= size) {
        var matches = true;
        for (pattern, 0..) |want, k| {
            if (moduleAt(size, modules, line, i + k, row) != want) {
                matches = false;
                break;
            }
        }
        if (!matches) {
            i += 1;
            continue;
        }

        if (lightBefore(size, modules, line, i, row) or lightAfter(size, modules, line, i + 7, row)) {
            score += 40;
            i += 7;
        } else {
            i += 4;
        }
    }
    return score;
}

/// Whether the 4 modules immediately before `index` (only those that exist) are all light.
fn lightBefore(size: usize, modules: []const u8, line: usize, index: usize, comptime row: bool) bool {
    const start = if (index >= 4) index - 4 else 0;
    var j = start;
    while (j < index) : (j += 1) {
        if (moduleAt(size, modules, line, j, row)) return false;
    }
    return true;
}

/// Whether the 4 modules starting at `from` (only those that exist) are all light.
fn lightAfter(size: usize, modules: []const u8, line: usize, from: usize, comptime row: bool) bool {
    const end = @min(from + 4, size);
    var j = from;
    while (j < end) : (j += 1) {
        if (moduleAt(size, modules, line, j, row)) return false;
    }
    return true;
}

/// N4: deviation of the dark module ratio from 50% (10 points for every 5%).
/// Integer division (truncating): `k = |dark% - 50%| / 5%`.
fn penaltyBalance(size: usize, modules: []const u8) u32 {
    const total = size * size;
    var dark: usize = 0;
    for (modules) |m| {
        if (m != 0) dark += 1;
    }
    const scaled_dark = dark * 100;
    const scaled_half = total * 50;
    const diff = if (scaled_dark > scaled_half) scaled_dark - scaled_half else scaled_half - scaled_dark;
    const k = diff / (5 * total);
    return @intCast(k * 10);
}

// ---------------------------------------------------------------- tests
//
// The source of each expectation is stated in the test. Every value was obtained from a third party
// (the standard itself or an independent implementation); this implementation's own output is never
// used as an expectation.

const testing = std.testing;

test "detect mode: numeric, alphanumeric or byte is chosen from the input" {
    try testing.expectEqual(Mode.numeric, detectMode("0123456789"));
    try testing.expectEqual(Mode.alphanumeric, detectMode("HELLO WORLD $%*+-./:"));
    try testing.expectEqual(Mode.alphanumeric, detectMode("UR:BYTES/ABCDEFG"));
    // Japanese UTF-8 goes to byte mode
    try testing.expectEqual(Mode.byte, detectMode("日本語"));
    try testing.expectEqual(Mode.byte, detectMode("hello"));
    // Empty input goes to numeric mode (the smallest)
    try testing.expectEqual(Mode.numeric, detectMode(""));
}

test "alphanumeric mode values are the 45 characters of the standard's Table 5" {
    try testing.expectEqual(@as(?u6, 0), alphanumericValue('0'));
    try testing.expectEqual(@as(?u6, 9), alphanumericValue('9'));
    try testing.expectEqual(@as(?u6, 10), alphanumericValue('A'));
    try testing.expectEqual(@as(?u6, 35), alphanumericValue('Z'));
    try testing.expectEqual(@as(?u6, 36), alphanumericValue(' '));
    try testing.expectEqual(@as(?u6, 44), alphanumericValue(':'));
    try testing.expectEqual(@as(?u6, null), alphanumericValue('a'));
    try testing.expectEqual(@as(?u6, null), alphanumericValue('_'));
}

test "character count indicator widths follow the standard's Table 3" {
    try testing.expectEqual(@as(usize, 10), Mode.numeric.charCountBits(1));
    try testing.expectEqual(@as(usize, 12), Mode.numeric.charCountBits(10));
    try testing.expectEqual(@as(usize, 14), Mode.numeric.charCountBits(27));
    try testing.expectEqual(@as(usize, 9), Mode.alphanumeric.charCountBits(9));
    try testing.expectEqual(@as(usize, 11), Mode.alphanumeric.charCountBits(26));
    try testing.expectEqual(@as(usize, 13), Mode.alphanumeric.charCountBits(27));
    try testing.expectEqual(@as(usize, 8), Mode.byte.charCountBits(9));
    try testing.expectEqual(@as(usize, 16), Mode.byte.charCountBits(10));
    try testing.expectEqual(@as(usize, 16), Mode.byte.charCountBits(40));
}

test "total codewords and data codewords" {
    // Values from the standard's Table 1 / Table 9 (third party: segno 1.6.6's consts.ECC and
    // qrcodegen 1.8.0's _ECC_CODEWORDS_PER_BLOCK / _NUM_ERROR_CORRECTION_BLOCKS were confirmed
    // to match for all 40 versions x 4 levels)
    try testing.expectEqual(@as(usize, 26), rawCodewords(1));
    try testing.expectEqual(@as(usize, 44), rawCodewords(2));
    try testing.expectEqual(@as(usize, 3706), rawCodewords(40));

    try testing.expectEqual(@as(usize, 19), dataCodewords(.l, 1));
    try testing.expectEqual(@as(usize, 16), dataCodewords(.m, 1));
    try testing.expectEqual(@as(usize, 13), dataCodewords(.q, 1));
    try testing.expectEqual(@as(usize, 9), dataCodewords(.h, 1));
    try testing.expectEqual(@as(usize, 2956), dataCodewords(.l, 40));
    try testing.expectEqual(@as(usize, 2334), dataCodewords(.m, 40));
    try testing.expectEqual(@as(usize, 1666), dataCodewords(.q, 40));
    try testing.expectEqual(@as(usize, 1276), dataCodewords(.h, 40));
}

test "automatic version selection boundaries (capacities of the standard's Table 7)" {
    // Third party: boundaries on which segno 1.6.6 / qrcodegen 1.8.0 / python-qrcode 8.2 agree.
    // Byte mode capacity at version 1 is L=17, M=14, Q=11, H=7 bytes.
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 17, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 18, .l));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 14, .m));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 15, .m));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 11, .q));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 12, .q));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 7, .h));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 8, .h));
    // Alphanumeric mode capacity at version 1 is L=25, M=20, Q=16, H=10 characters.
    try testing.expectEqual(@as(u8, 1), try selectVersion(.alphanumeric, 25, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.alphanumeric, 26, .l));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.alphanumeric, 20, .m));
    // Numeric mode capacity at version 1 is L=41, M=34, Q=27, H=17 digits.
    try testing.expectEqual(@as(u8, 1), try selectVersion(.numeric, 41, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.numeric, 42, .l));
    // Byte mode capacity at version 40-L is 2953 bytes.
    try testing.expectEqual(@as(u8, 40), try selectVersion(.byte, 2953, .l));
    try testing.expectError(Error.DataTooLong, selectVersion(.byte, 2954, .l));
}

test "Reed-Solomon: error correction codewords of the standard's Annex I.2" {
    // ISO/IEC 18004:2006(E) Annex I.2 (encoding "01234567" at version 1-M).
    // 16 data codewords (including pad codewords) and the 10 EC codewords generated.
    const data = [16]u8{
        0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11,
        0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
    };
    const expected = [10]u8{
        0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55,
    };
    var divisor: [10]u8 = undefined;
    var out: [10]u8 = undefined;
    rsDivisor(10, &divisor);
    rsRemainder(&data, &divisor, &out);
    try testing.expectEqualSlices(u8, &expected, &out);
}

test "data encoding: data codeword sequence of the standard's Annex I.2" {
    // ISO/IEC 18004:2006(E) Annex I.2: encoding "01234567" at version 1-M gives
    // 16 data codewords (6 + 10 pad codewords).
    // This example is also the basis for adding padding bits to the 8-bit boundary "only when needed".
    var buf: [16]u8 = @splat(0);
    var bit_len: usize = 0;
    writeData(&buf, &bit_len, .numeric, "01234567", 1);
    writePadding(&buf, &bit_len, 16 * 8);
    const expected = [16]u8{
        0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11,
        0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
    };
    try testing.expectEqualSlices(u8, &expected, &buf);
}

test "format information: the 32 cases of the standard's Table C.1" {
    // The "Sequence after masking (QR Code symbols)" column (hexadecimal) of the
    // ISO/IEC 18004:2006(E) Table C.1 "Valid format information bit sequences".
    // The index is the value of the 5 data bits (the top 2 bits are the EC level, the bottom 3 the mask).
    const table = [32]u16{
        0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0,
        0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976,
        0x1689, 0x13BE, 0x1CE7, 0x19D0, 0x0762, 0x0255, 0x0D0C, 0x083B,
        0x355F, 0x3068, 0x3F31, 0x3A06, 0x24B4, 0x2183, 0x2EDA, 0x2BED,
    };
    const levels = [4]EcLevel{ .m, .l, .h, .q }; // order of the top 2 data bits (00, 01, 10, 11)
    for (levels, 0..) |ec, ec_bits| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            const data = ec_bits * 8 + @as(usize, mask);
            try testing.expectEqual(table[data], formatBits(ec, mask));
            if (mask == 7) break;
        }
    }
}

test "version information: all 34 versions of the standard's Table D.1" {
    // ISO/IEC 18004:2006(E) Table D.1 "Version information bit stream for each version".
    const table = [41]u32{
        0,       0,       0,       0,       0,       0,       0,
        0x07C94, 0x085BC, 0x09A99, 0x0A4D3, 0x0BBF6, 0x0C762, 0x0D847,
        0x0E60D, 0x0F928, 0x10B78, 0x1145D, 0x12A17, 0x13532, 0x149A6,
        0x15683, 0x168C9, 0x177EC, 0x18EC4, 0x191E1, 0x1AFAB, 0x1B08E,
        0x1CC1A, 0x1D33F, 0x1ED75, 0x1F250, 0x209D5, 0x216F0, 0x228BA,
        0x2379F, 0x24B0B, 0x2542E, 0x26A64, 0x27541, 0x28C69,
    };
    var version: u8 = 7;
    while (version <= 40) : (version += 1) {
        try testing.expectEqual(table[version], versionBits(version));
    }
}

test "errors: capacity exceeded and version out of range" {
    const allocator = testing.allocator;
    // 0x80 is neither alphanumeric nor numeric, so byte mode is used. This exceeds the 2953 bytes of version 40-L.
    var too_long: [2954]u8 = @splat(0x80);
    try testing.expectError(Error.DataTooLong, encode(allocator, &too_long, .l));
    try testing.expectError(Error.InvalidVersion, encodeVersion(allocator, "A", .m, 0));
    try testing.expectError(Error.InvalidVersion, encodeVersion(allocator, "A", .m, 41));
    // When it does not fit in the requested version
    try testing.expectError(Error.DataTooLong, encodeVersion(allocator, "0123456789ABCDEF", .h, 1));
    // When a mode is requested explicitly, characters that the mode cannot represent are rejected
    // (lower-case letters in alphanumeric mode, non-digits in numeric mode)
    try testing.expectError(Error.InvalidCharacter, encodeOptions(allocator, "ur:bytes/abc", .m, .{ .mode = .alphanumeric }));
    try testing.expectError(Error.InvalidCharacter, encodeOptions(allocator, "12a", .m, .{ .mode = .numeric }));
    // The same input is accepted in byte mode
    var as_bytes = try encodeOptions(allocator, "ur:bytes/abc", .m, .{ .mode = .byte });
    defer as_bytes.deinit(allocator);
    try testing.expectEqual(as_bytes.size * as_bytes.size, as_bytes.modules.len);

    // The same boundary applies when byte mode is requested explicitly (2953 fits, 2954 does not)
    var max_byte: [2953]u8 = @splat(0x80);
    var m = try encodeOptions(allocator, &max_byte, .l, .{ .mode = .byte });
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 40), m.version);
}

test "drawing: quiet zone, scale and clipping" {
    const allocator = testing.allocator;
    var m = try encodeOptions(allocator, "HELLO", .m, .{ .version = 1, .mask = 0 });
    defer m.deinit(allocator);

    // 21 modules + quiet zone 4 x 2 = 29 modules. At scale 1 that is 29x29 pixels.
    try testing.expectEqual(@as(usize, 29), pixelSize(&m, .{ .scale = 1, .quiet_zone = 4 }));
    try testing.expectEqual(@as(usize, 58), pixelSize(&m, .{ .scale = 2, .quiet_zone = 4 }));
    try testing.expect(fitsIn(&m, 240, 240, .{ .scale = 2, .quiet_zone = 4 }));
    try testing.expect(!fitsIn(&m, 240, 240, .{ .scale = 2, .quiet_zone = 4, .origin_x = 200 }));

    // Fit it exactly into a 29x29 area. The quiet zone is light, the corner of the finder pattern is dark and the separator is light.
    var buffer: [31 * 31]u16 = @splat(0x1234);
    drawRgb565(&m, &buffer, 31, 31, .{ .scale = 1, .quiet_zone = 4, .dark = 0x0000, .light = 0xFFFF });
    try testing.expectEqual(@as(u16, 0xFFFF), buffer[0]);
    try testing.expectEqual(@as(u16, 0x0000), buffer[4 * 31 + 4]);
    try testing.expectEqual(@as(u16, 0xFFFF), buffer[(4 + 7) * 31 + (4 + 7)]);
    // Only 29 modules were drawn, so column 30 and row 30 (outside the area) are untouched.
    try testing.expectEqual(@as(u16, 0x1234), buffer[30]);
    try testing.expectEqual(@as(u16, 0x1234), buffer[30 * 31 + 0]);
    // Shifting the origin draws from that position.
    var offset: [31 * 31]u16 = @splat(0x1234);
    drawRgb565(&m, &offset, 31, 31, .{ .scale = 1, .quiet_zone = 4, .origin_x = 2, .origin_y = 1 });
    try testing.expectEqual(@as(u16, 0x1234), offset[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), offset[1 * 31 + 2]);

    // A negative origin is clipped and still draws (no exception is raised).
    var small: [4]u16 = @splat(0x1234);
    drawRgb565(&m, &small, 2, 2, .{ .scale = 4, .quiet_zone = 0, .origin_x = -8, .origin_y = -8 });
    try testing.expectEqual(@as(u16, 0x0000), small[0]);

    // If buffer is smaller than the framebuffer, only the rows that fit are drawn.
    var tiny: [3]u16 = @splat(0x1234);
    drawRgb565(&m, &tiny, 3, 3, .{ .scale = 1, .quiet_zone = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), tiny[0]);
}

/// hello_world_m: alphanumeric / EC M / version 1 / mask 0
const expect_hello_world_m = [_][]const u8{
    "#######...#.#.#######",
    "#.....#.###...#.....#",
    "#.###.#...#.#.#.###.#",
    "#.###.#...#.#.#.###.#",
    "#.###.#.#.###.#.###.#",
    "#.....#..###..#.....#",
    "#######.#.#.#.#######",
    ".....................",
    "#.#.#.#..#..#...#..#.",
    ".####...#..#....#...#",
    "...#######.#..#.##...",
    "####.#.##..###.#.###.",
    ".#..####.#.#..###.#.#",
    "........#.#...#...#.#",
    "#######.....#..#.##..",
    "#.....#..##...##.#...",
    "#.###.#.##..#.#######",
    "#.###.#...##.#.#...#.",
    "#.###.#.####.###.#..#",
    "#.....#....###...#.##",
    "#######.##.#.###....#",
};

/// iso_01234567_m_mask2: numeric / EC M / version 1 / mask 2
const expect_iso_01234567_m_mask2 = [_][]const u8{
    "#######..#.##.#######",
    "#.....#..####.#.....#",
    "#.###.#.#.....#.###.#",
    "#.###.#.##....#.###.#",
    "#.###.#.#.###.#.###.#",
    "#.....#.#...#.#.....#",
    "#######.#.#.#.#######",
    "........#..##........",
    "#.#####..#..#.#####..",
    "...#.#.##.#.#..#.##..",
    "..#...##.#.#.#..#####",
    "....#....#.....####..",
    "...######..#.#..#....",
    "........#.#####..##..",
    "#######..##.#.##.....",
    "#.....#.#.#####...#.#",
    "#.###.#.#...#..#.##..",
    "#.###.#.##..#..#.....",
    "#.###.#.#.##.#..#.#..",
    "#.....#........##.##.",
    "#######.####.#..#.#..",
};

/// jp_utf8_q_mask5: byte / EC Q / version 3 / mask 5
const expect_jp_utf8_q_mask5 = [_][]const u8{
    "#######.#.##...#.#.##.#######",
    "#.....#.###.#.###.#.#.#.....#",
    "#.###.#..######.##....#.###.#",
    "#.###.#..##.#.#.###.#.#.###.#",
    "#.###.#...#.#..#.##...#.###.#",
    "#.....#..#..#..###.##.#.....#",
    "#######.#.#.#.#.#.#.#.#######",
    ".........##..##..###.........",
    ".#....#####..##.#....#.....##",
    "..#.....#..#..#..##...##...##",
    "..#..##.#....#...#.#..#..#.##",
    "#.#.##.####..#.#.####..#.##.#",
    "#.#####......#......#..#.#..#",
    "...###.#..##.####.###.#..#.##",
    "##.#..#...##.#..#.##.#..#####",
    ".###...##.#..#.....#.###.....",
    "#...###.#.#.###...####..#.##.",
    "##.###...######.#....#..#...#",
    "####.##.....##..#.##.#.##....",
    "#..#.#.....#.#####........##.",
    "#.##.##.#.#.#.#...#.#####....",
    "........####...#.####...###.#",
    "#######.####..#..#..#.#.##.##",
    "#.....#........####.#...#####",
    "#.###.#..#.#.#.#.#..######.##",
    "#.###.#..#....#...#.#.###..#.",
    "#.###.#....##.#####.###..###.",
    "#.....#.####....##..##......#",
    "#######..###.###..#######....",
};

/// ur300_l_mask0: alphanumeric / EC L / version 9 / mask 0
const expect_ur300_l_mask0 = [_][]const u8{
    "#######..##.###.#.###.###.#.#####.###.##..#...#######",
    "#.....#...##.......#.......####.##.#.#.#.###..#.....#",
    "#.###.#.#.##..#.#.#.###..###.#.######.##...#..#.###.#",
    "#.###.#....###...######..#.###...#.....#..#.#.#.###.#",
    "#.###.#......####.##.#.######...#...##....#...#.###.#",
    "#.....#.......#..#.....##...##...#...###.##...#.....#",
    "#######.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#######",
    "........##.#######.#.#.##...##...####.##.#..#........",
    "###.########.#..#.#.....#####.#....###..##.####...#..",
    "##.###.##..#.#..##....#...#.##..#......#.##.##.##.#..",
    "#.#...##.##.#.#..###...#.#.##...######.#.#.#..#.####.",
    "##.##..##.#..#..#####.#####...#.##..#####.#.####.#...",
    ".####.##.#..#.####..#..##.##..#...#...#.#####...#####",
    "#.#.#...####.#.##.....###.###..##..#.###...#.#.##..##",
    "..#...###.##..#..#..#......#...####...##...#.##...#..",
    "#.####..#..#...#####.##..#.#####.###.#..#####.##.##..",
    "..#####.####..####.#.....#...###....#####.....#..##..",
    "#..#...##.###..#.#...##..##.....##....#.#.##.##....#.",
    ".#.#.###.###..#####.#..#######..#####.####.####..#...",
    ".###...#.###...#.###.#....#.###.#.....#....###.#..#.#",
    "###...#..##.#...#.##.....#..#.#####.#...#..#..#.#.##.",
    "#.#.##.#..#.###.#...#...####.......####..#...#.....#.",
    "####.#####...#.#..#..#..##.####.###....#.####.#..#..#",
    "###.##..##...###...###...#.##.......#.##.#..##..###..",
    "#########.##.#..#.#..#.#########.#..#.#.#.#.########.",
    "##..#...######..#....##.#...##....####..#####...#..#.",
    "#.###.#.###.##.....###.##.#.##..#########.###.#.##...",
    "###.#...#..###..######.##...#######..#.#.####...#.#.#",
    "###.#####...###.##..#..###########..#..#.########.##.",
    "..###....###...###..###.##.#.###.#.#.####..#.##.#...#",
    "#.#..#####.##.#.##..#.#....#.#..#.....###...#..#.....",
    "######.#####.....####.##.####..######...#.#.#.#.##.##",
    ".#.#.##.##..#.####..###..#....##..####.#.##...#.#.#.#",
    "...#.#.####.#..#.#.####.#..##..###.###...#.####.###..",
    "#..#..##.....#.##.#.##..####..#.....###.####..#.#...#",
    ".#.#.#.#.#.###.#..#..###....####..###.####.###.###.##",
    "#.##..#.##.#..##.#.....###.##.###.#.#.###.#.##.######",
    "#.#..#...##.####.#....####..###.#....#....##.........",
    "#...#.#..##.##..#.#......#.........##..##.###..#.#.#.",
    ".##.##...#.######..#..##..##.####........#..###...#..",
    "##..#.##.#.###..#.##.####.....###.#......#.##...#.#..",
    "######..#....#..#.....##.#.#.#.#..#.#.##.####..####..",
    "##.#######...#......#.###.###..#...##.####.#.#####.#.",
    ".##....#..#.....#..#.....##..##.####..#.###.#....#.##",
    "...#..##...#.#.#####..#.#######.#...#.#.###.######...",
    "........#.#.##.#..##.####...##.#.###......###...####.",
    "#######.#.#.#..###.#.####.#.###..##.#......##.#.#..##",
    "#.....#.#.##.##.######.##...##....#.#####...#...#.#.#",
    "#.###.#.##.....###..###.######...#.##...##..#####.#..",
    "#.###.#..####..#.#.#..##.####..#..##.#..##.###..#.#..",
    "#.###.#.#..##..##.###.##.#....###.#.#..#.######...#..",
    "#.....#.#...#.##..##.###..####.##.#..#.###....##..###",
    "#######.#####.#######..##..###.##.##..#.#...#.#####.#",
};

/// Checks that it matches the embedded matrix ('#' is dark, '.' is light).
fn expectMatrix(m: *const Matrix, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, m.size);
    for (expected, 0..) |row, y| {
        try testing.expectEqual(m.size, row.len);
        for (row, 0..) |c, x| {
            try testing.expectEqual(c == '#', m.get(x, y));
        }
    }
}

/// Checks that two matrices are exactly the same.
fn expectSameMatrix(a: *const Matrix, b: *const Matrix) !void {
    try testing.expectEqual(a.size, b.size);
    try testing.expectEqualSlices(u8, a.modules, b.modules);
}

/// UR-like string used by the embedded vectors (assuming upper-case bytewords are shown as a QR code).
const ur_long_vector = "UR:BYTES/71HFE86Y5R215DEW1ZCYQESH0ARLH9DL65O6MMG2TY7O5ZINC42EI5E6OHTNANMDH4AYFATOHZEK3E2KPH4DKDVPT9G8FZYGRPNE8WV5379AR4OOTXGZ07YHL7IRAT0GWBW6JWC9NAYX0KV17NJF3F55V4Y88UZAGXRDYCJPNSXS7FE4L1ZEE043E42L4WFHVDY8UFUQC66RMRQT363PL6FCCYS8RBHTF4SZ63Y05FAQVUDP3AO0OGTIRZV9CID3Y3K33UWXA3W5B44FP7F25QXKGDKFGP8JTK40T64YDWG8";

test "matrix: HELLO WORLD (alphanumeric / EC M / automatic mask)" {
    // Source: the 3 implementations Nayuki qrcodegen 1.8.0, python-qrcode 8.2 and segno 1.6.6 (with
    // only the padding corrected to match the standard) were all confirmed to choose version 1 and
    // mask 0 automatically and to output the same matrix.
    const allocator = testing.allocator;
    var m = try encode(allocator, "HELLO WORLD", .m);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), m.version);
    try testing.expectEqual(@as(u3, 0), m.mask);
    try testing.expectEqual(Mode.alphanumeric, m.mode);
    try testing.expectEqual(@as(usize, 21), m.size);
    try expectMatrix(&m, &expect_hello_world_m);
}

test "matrix: 01234567 (numeric / EC M / worked example of the standard's Annex I.2)" {
    // ISO/IEC 18004:2006(E) Annex I.2 encodes "01234567" at version 1-M and states in Step 4 that
    // "the data mask selected is 010 (= 2)". It also states the format information in Step 5 as
    // 101111001111100 (= 0x5E7C; data bits 00010 in Table C.1). The expected matrix is the one
    // qrcodegen 1.8.0 / python-qrcode 8.2 / segno 1.6.6 (padding corrected) output identically with
    // mask 2 forced, which is the same symbol as the worked example in the standard.
    const allocator = testing.allocator;

    var m = try encode(allocator, "01234567", .m);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), m.version);
    try testing.expectEqual(@as(u3, 2), m.mask);
    try testing.expectEqual(Mode.numeric, m.mode);
    try expectMatrix(&m, &expect_iso_01234567_m_mask2);

    // Reference: under the convention that evaluates with the format/version information left blank
    // (`encoding_region_only`, the same as segno 1.6.6) mask 3 is chosen. Under either convention the
    // generated symbol conforms to the standard and can be decoded (the mask number goes into the format information).
    var compat = try encodeOptions(allocator, "01234567", .m, .{ .mask_eval = .encoding_region_only });
    defer compat.deinit(allocator);
    try testing.expectEqual(@as(u3, 3), compat.mask);
    var forced = try encodeWithMask(allocator, "01234567", .m, 3);
    defer forced.deinit(allocator);
    try expectSameMatrix(&compat, &forced);
}

test "matrix: Japanese UTF-8 (byte / EC Q / mask 5 forced)" {
    // Source: the matrix that qrcodegen 1.8.0 / python-qrcode 8.2 / segno 1.6.6 (padding corrected)
    // output identically with mask 5 forced. Byte mode, version 3
    // (a size that includes an alignment pattern).
    const allocator = testing.allocator;
    var m = try encodeWithMask(allocator, "日本語のテスト", .q, 5);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 3), m.version);
    try testing.expectEqual(Mode.byte, m.mode);
    try testing.expectEqual(@as(u3, 5), m.mask);
    try expectMatrix(&m, &expect_jp_utf8_q_mask5);
}

test "matrix: long UR-like string (alphanumeric / EC L / mask 0 forced)" {
    // Source: the matrix that the same 3 implementations output identically with mask 0 forced.
    // version 9 (includes the version information blocks and alignment patterns).
    // zhww displays bytewords in upper case for the QR code, so alphanumeric mode is chosen.
    const allocator = testing.allocator;
    var m = try encodeWithMask(allocator, ur_long_vector, .l, 0);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 9), m.version);
    try testing.expectEqual(Mode.alphanumeric, m.mode);
    try testing.expectEqual(@as(usize, 309), ur_long_vector.len);
    try expectMatrix(&m, &expect_ur300_l_mask0);
}
