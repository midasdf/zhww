//! QR camera path on a PC: a stored image in, a PSBT out.
//!
//! The device reads a QR code off a phone screen with an SPI camera and decodes it with
//! `ui/qr_decode.zig`. This command runs that whole chain against a file (or a pipe), so the
//! camera path can be exercised today and a real frame can be replayed and debugged later
//! without reflashing:
//!
//!     grayscale image -> qr_decode (ui/qr_decode.zig) -> UR string
//!         -> ur_receive.Receiver (one QR part per image) -> PSBT (base64)
//!
//! **Two modes, one question each.** Without `--assemble` the answer is "what does this frame
//! say": every image is decoded and its text is written to stdout, one line each (a real frame
//! can be checked against the string the sender showed). With `--assemble` the images are the
//! parts of one transfer, one QR code per image; nothing is written until `ur_receive` has every
//! part **and** the whole-message checksum has passed, and then the payload (the PSBT) is the
//! only thing on stdout, base64, exactly what `sign` and `show` take. The modes are separate
//! because stdout has to carry one kind of result: a pipeline cannot tell a decoded text line
//! from a PSBT line.
//!
//! **Image formats.** Both are read because both are what the camera path meets: a script or a
//! logic analyzer dump makes a PGM, and the SPI camera will hand over raw 8-bit pixels.
//! - **PGM (P5)**: `"P5"`, then width, height and a maxval of 1..255, whitespace and `#` comments
//!   allowed between them, then exactly one whitespace character and `width * height` bytes.
//!   The pixel data is used in place (P5 has no row padding), so nothing is copied. A trailing
//!   CRLF counts as the one separator; bytes after the image are ignored.
//! - **Raw 8-bit**: one byte per pixel, row-major, no header - `--width`/`--height` say how to cut
//!   it (`--format raw` forces this reading). A raw frame that happens to start with `"P5"` would
//!   be read as a PGM file, which is what `--format raw` is for.
//!   Anything else (P2/P3/P6, or data with no dimensions to go by) is refused by name instead of
//!   being cut into pixels that were never there.
//!
//! **Errors are distinct and stdout stays empty until there is a result.** "unsupported image
//! format", "malformed PGM header", "the pixel data is shorter than width * height", "image too
//! small" (the decoder needs a version-1 symbol: 21x21), "image too large" (4096x4096), "no QR
//! code found", "the code is damaged beyond repair", "wrong UR type", "checksum mismatch" and
//! "incomplete transfer" are all separate; a run that does not produce a result writes nothing to
//! stdout and exits nonzero. Diagnostics - frames, pixels, symbol version/EC/mask, part counts -
//! go to stderr, as in the rest of the CLI.
//!
//! The assembler's ceilings are the CLI's: a 64 KiB payload (`ur_receive.max_payload_len`, the
//! firmware's own card/PSBT limit) and 8192 parts. Both are bounds on the buffers, not allocations
//! per part: a sender cannot make the command hold more than that, and `ur_receive` never
//! allocates.
//!
//! SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("zhww");

const cbor = zhww.cbor;
const qr_decode = zhww.ui_qr_decode;
const ur = zhww.ur;
const ur_receive = zhww.ur_receive;

/// Smallest image side worth trying: a version-1 symbol is 21 modules, so 21x21 pixels is the
/// smallest frame that can physically hold one (at one pixel per module, with no quiet zone).
/// `qr_decode` would report `SymbolNotFound` for anything smaller; "image too small" says why.
pub const min_image_dim: usize = qr_decode.min_size;

/// Largest image side the decoder accepts (`qr_decode.max_image_dim`).
pub const max_image_dim: usize = qr_decode.max_image_dim;

/// Largest file this command reads: one byte per pixel at the decoder's largest image, plus room
/// for a PGM header. Anything bigger cannot be an image the decoder would agree to look at.
pub const max_file_len: usize = max_image_dim * max_image_dim + 1024;

/// Part-count bound of the assembler's bitmap: a 64 KiB message at the UR minimum fragment length
/// of 10 bytes is at most 6554 parts, so 8192 leaves margin (1 KiB of bitmap).
pub const max_parts: usize = 8192;

/// Message ceiling of the assembler: the payload ceiling plus the CBOR byte string header that
/// `ur:crypto-psbt` and `ur:bytes` wrap it in.
pub const max_message_len: usize = ur_receive.max_payload_len + cbor.max_header_len;

/// Destination the decoded text is written into, i.e. the largest QR text this command reads.
/// A version-40 symbol carries at most 7089 digits / 4296 alphanumeric characters / 2953 bytes,
/// so no decodable symbol is ever cut short, and one image cannot make the command allocate more
/// than this. It is also the part text the assembler's work area is sized for.
pub const max_text_len: usize = 8192;

/// The command's own errors. Kept apart from the decoder's (`qr_decode.Error`) and the
/// assembler's (`ur_receive.ReceiveError`) so that a script - and a reader of the exit status -
/// can tell "not an image I read", "no QR code in it" and "the transfer is not complete" apart.
pub const ToolError = error{
    /// Not a format this command reads: neither a P5 PGM nor raw 8-bit with dimensions.
    UnsupportedImageFormat,
    /// A PGM header that does not follow the format (missing field, stray byte, 0 dimension).
    InvalidImageHeader,
    /// The pixel data ends before `width * height` bytes have been read.
    TruncatedImage,
    /// Raw input with no `--width`/`--height` and no PGM magic to go by.
    MissingDimensions,
    /// Smaller than a version-1 symbol (`min_image_dim`).
    ImageTooSmall,
    /// Larger than the decoder's image limit (`max_image_dim`).
    ImageTooLarge,
};

// ---------------------------------------------------------------- images

/// How to read the bytes as an image (`--format`). Null means "decide from the data".
pub const Format = enum { pgm, raw };

/// Size of a raw 8-bit image (`--width`/`--height`).
pub const Dimensions = struct {
    width: usize,
    height: usize,
};

/// Reads a PGM (P5) file into an image.
///
/// The pixels are a slice of `bytes` (P5 stores rows back to back, with no padding), so `bytes`
/// must outlive the returned image. `#` comments and any whitespace may appear between header
/// fields; the header ends with exactly one whitespace character - consuming *all* whitespace
/// there would eat a first pixel that happens to be 0x20, 0x09 or 0x0A.
pub fn parsePgm(bytes: []const u8) ToolError!qr_decode.Image {
    if (bytes.len < 2 or bytes[0] != 'P') return error.InvalidImageHeader;
    if (bytes[1] != '5') {
        // The rest of the Netpbm family (P2/P3/P6/...) is a format this command can name as
        // unsupported rather than a PGM it cannot read.
        if (std.ascii.isDigit(bytes[1])) return error.UnsupportedImageFormat;
        return error.InvalidImageHeader;
    }

    var at: usize = 2;
    const width = try readNumber(bytes, &at);
    const height = try readNumber(bytes, &at);
    const maxval = try readNumber(bytes, &at);
    // A zero side is a broken header, not a small image; say so before the shared size check.
    if (width == 0 or height == 0) return error.InvalidImageHeader;
    // One byte per pixel means 8 bits: a 16-bit PGM (maxval > 255) needs two bytes per pixel and
    // is refused by name instead of being read as half an image.
    if (maxval == 0 or maxval > 255) return error.UnsupportedImageFormat;
    try checkDimensions(width, height);

    if (at >= bytes.len or !std.ascii.isWhitespace(bytes[at])) return error.InvalidImageHeader;
    // A CRLF line ending is one separator, not two.
    if (bytes[at] == '\r' and at + 1 < bytes.len and bytes[at + 1] == '\n') at += 1;
    at += 1;

    const need = width * height; // both sides are within max_image_dim here
    if (bytes.len - at < need) return error.TruncatedImage;
    return .{ .width = width, .height = height, .pixels = bytes[at..][0..need] };
}

/// Cuts a raw 8-bit buffer into an image: one byte per pixel, row-major, no header, no padding.
///
/// Bytes beyond `width * height` are ignored (a camera dump may be padded), and so is the rest of
/// the buffer after a short read only in the sense that it is an error - a truncated image is
/// never silently decoded as a shorter one.
pub fn parseRaw(bytes: []const u8, size: Dimensions) ToolError!qr_decode.Image {
    try checkDimensions(size.width, size.height);
    const need = size.width * size.height; // both sides are within max_image_dim here
    if (bytes.len < need) return error.TruncatedImage;
    return .{ .width = size.width, .height = size.height, .pixels = bytes[0..need] };
}

/// Reads `bytes` as an image.
///
/// With no `--format`, the `P5` magic wins (and another Netpbm format is named as unsupported);
/// failing that, raw 8-bit is read when dimensions are given. Without either, there is nothing to
/// go by and the bytes are refused.
pub fn parseImage(bytes: []const u8, format: ?Format, size: ?Dimensions) ToolError!qr_decode.Image {
    if (format) |explicit| {
        switch (explicit) {
            .pgm => return parsePgm(bytes),
            .raw => return parseRaw(bytes, size orelse return error.MissingDimensions),
        }
    }
    if (looksLikeNetpbm(bytes)) return parsePgm(bytes);
    if (size) |dims| return parseRaw(bytes, dims);
    return error.UnsupportedImageFormat;
}

/// Whether the data announces itself as Netpbm (`P` and a format digit).
fn looksLikeNetpbm(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes[0] == 'P' and std.ascii.isDigit(bytes[1]);
}

/// Rejects sizes the decoder cannot work with, by name, so a caller gets "image too small"
/// instead of a decode that never had a chance.
fn checkDimensions(width: usize, height: usize) ToolError!void {
    if (width < min_image_dim or height < min_image_dim) return error.ImageTooSmall;
    if (width > max_image_dim or height > max_image_dim) return error.ImageTooLarge;
}

/// Reads one header integer. Whitespace and `#` comments may precede it; the number must be
/// followed by a separator, so `"P5 4x4 255"` is a malformed header and not a 4-wide image.
fn readNumber(bytes: []const u8, at: *usize) ToolError!usize {
    try skipSeparators(bytes, at);
    const start = at.*;
    while (at.* < bytes.len and std.ascii.isDigit(bytes[at.*])) at.* += 1;
    if (at.* == start) return error.InvalidImageHeader;
    const parsed = std.fmt.parseInt(usize, bytes[start..at.*], 10) catch return error.InvalidImageHeader;
    if (at.* < bytes.len and !std.ascii.isWhitespace(bytes[at.*]) and bytes[at.*] != '#') {
        return error.InvalidImageHeader;
    }
    return parsed;
}

/// Skips whitespace and `#` comments (a comment runs to the end of its line).
fn skipSeparators(bytes: []const u8, at: *usize) ToolError!void {
    while (at.* < bytes.len) {
        if (std.ascii.isWhitespace(bytes[at.*])) {
            at.* += 1;
            continue;
        }
        if (bytes[at.*] != '#') return;
        while (at.* < bytes.len and bytes[at.*] != '\n') at.* += 1;
    }
}

// ---------------------------------------------------------------- decode

/// One decoded QR code: the text (owned by the allocator it was decoded with) and what the symbol
/// carried.
pub const Decoded = struct {
    /// The buffer `text` points into; release it with the allocator passed to `decodeImage`.
    buffer: []u8,
    /// Decoded text: the start of `buffer`.
    text: []const u8,
    /// Symbol version, error correction level and mask the decoder read.
    info: qr_decode.Info,

    pub fn deinit(self: *const Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }
};

/// Grayscale image -> QR text (`ui/qr_decode.zig`), the same call the device will make.
///
/// The destination is `max_text_len` bytes, which covers the largest text a version-40 symbol can
/// carry, so a decodable symbol is never cut short and one image cannot ask for unbounded memory.
pub fn decodeImage(allocator: std.mem.Allocator, image: qr_decode.Image) (qr_decode.Error || std.mem.Allocator.Error)!Decoded {
    const buffer = try allocator.alloc(u8, max_text_len);
    errdefer allocator.free(buffer);
    const info = try qr_decode.decodeTo(allocator, image, buffer);
    return .{ .buffer = buffer, .text = info.text, .info = info };
}

// ---------------------------------------------------------------- assembly

/// One UR transfer in progress: images (one QR part each) go in, the payload comes out once every
/// part has been seen.
///
/// The three buffers are sized once and belong to the session; `ur_receive.Receiver` is a
/// fixed-size struct pointing into them, and it never allocates, so a sender cannot make this
/// command hold more than it prepared. The buffers are heap slices, so a session may be moved
/// after `init` without invalidating the receiver.
pub const Session = struct {
    receiver: ur_receive.Receiver,
    message: []u8,
    bits: []u8,
    part_buf: []u8,

    /// A receiver for `ur_type` with the CLI's ceilings (`max_parts` parts, a 64 KiB payload).
    pub fn init(allocator: std.mem.Allocator, ur_type: []const u8) !Session {
        const message = try allocator.alloc(u8, max_message_len);
        errdefer allocator.free(message);
        const bits = try allocator.alloc(u8, ur_receive.bitsLength(max_parts));
        errdefer allocator.free(bits);
        const part_buf = try allocator.alloc(u8, ur.maxPartCborLength(max_text_len));
        errdefer allocator.free(part_buf);
        return .{
            .message = message,
            .bits = bits,
            .part_buf = part_buf,
            .receiver = try ur_receive.Receiver.init(ur_type, message, bits, part_buf),
        };
    }

    /// Releases the session's buffers. The session (and its receiver) must not be used afterwards.
    pub fn deinit(self: *const Session, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.bits);
        allocator.free(self.part_buf);
    }

    /// Takes in one decoded QR string - one camera frame. Parts may arrive in any order and be
    /// repeated; see `ur_receive.Receiver.receive` for what each error means.
    pub fn feed(self: *Session, text: []const u8) ur_receive.ReceiveError!ur_receive.Status {
        return self.receiver.receive(text);
    }

    /// The payload inside the verified message (the PSBT), or `error.Incomplete`.
    pub fn payload(self: *const Session) ur_receive.ReceiveError![]const u8 {
        return self.receiver.payload();
    }
};

// ---------------------------------------------------------------- command

/// What the command line asked for.
const Options = struct {
    /// `--assemble`: the images are the parts of one transfer and stdout carries the PSBT.
    assemble: bool = false,
    format: ?Format = null,
    size: ?Dimensions = null,
    ur_type: []const u8 = ur.type_crypto_psbt,
    /// Image files in the order they were given: bare arguments and `--image <file>` alike.
    images: []const []const u8 = &.{},
};

/// `zhww qr-decode [options] [image ...]`: image -> QR text -> UR parts -> PSBT (base64).
///
/// Reads files itself (`-` or no image at all is stdin) and writes results to `stdout`;
/// diagnostics go to stderr through `std.debug.print`, as the rest of the CLI does.
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    io: std.Io,
) !void {
    const options = try parseArgs(allocator, args);

    if (!options.assemble) {
        if (options.images.len == 0) {
            try decodeOne(allocator, io, null, options, stdout);
            return;
        }
        for (options.images) |path| try decodeOne(allocator, io, path, options, stdout);
        return;
    }

    if (options.images.len == 0) {
        stderrPrint("--assemble needs the images holding the UR parts, one QR code each\n", .{});
        return error.Usage;
    }
    try assemble(allocator, options, stdout, io);
}

/// One image, one answer: the decoded text on stdout, the symbol's parameters on stderr.
fn decodeOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
    options: Options,
    stdout: *std.Io.Writer,
) !void {
    const loaded = try loadImage(allocator, io, path, options.format, options.size);
    defer allocator.free(loaded.bytes);

    const decoded = decodeImage(allocator, loaded.image) catch |err| {
        stderrPrint("qr-decode: {s}: {s}\n", .{ loaded.name, decodeProblem(err) });
        return err;
    };
    defer decoded.deinit(allocator);

    stderrPrint(
        "qr-decode: {s}: {d}x{d} px, version {d}, EC {s}, mask {d}, {d} B text\n",
        .{
            loaded.name,
            loaded.image.width,
            loaded.image.height,
            decoded.info.version,
            decoded.info.ec.name(),
            decoded.info.mask,
            decoded.text.len,
        },
    );
    try stdout.print("{s}\n", .{decoded.text});
    try stdout.flush();
}

/// Every image is one QR part of one transfer; the PSBT (base64) is the only thing that reaches
/// stdout, and only after `ur_receive` has every part and the message checksum has passed.
///
/// A frame without a readable QR code, and a part the receiver refuses, are reported and skipped -
/// a camera misses frames, and a transfer that still completes must not be lost because of them.
/// An image that is not an image at all (unreadable file, unsupported format, malformed header) is
/// fatal: the caller asked for a file this command cannot interpret, and skipping it silently
/// would turn a typo into "incomplete transfer".
fn assemble(
    allocator: std.mem.Allocator,
    options: Options,
    stdout: *std.Io.Writer,
    io: std.Io,
) !void {
    var session = try Session.init(allocator, options.ur_type);
    defer session.deinit(allocator);

    var frames: usize = 0;
    var codes: usize = 0;
    var refused: usize = 0;
    var last_error: ?anyerror = null;

    for (options.images, 0..) |path, index| {
        const loaded = try loadImage(allocator, io, path, options.format, options.size);
        defer allocator.free(loaded.bytes);
        frames += 1;

        const decoded = decodeImage(allocator, loaded.image) catch |err| {
            last_error = err;
            stderrPrint(
                "qr-decode: frame {d}/{d} ({s}): {d}x{d} px: {s}\n",
                .{ index + 1, options.images.len, loaded.name, loaded.image.width, loaded.image.height, decodeProblem(err) },
            );
            continue;
        };
        defer decoded.deinit(allocator);
        codes += 1;

        const status = session.feed(decoded.text) catch |err| {
            refused += 1;
            last_error = err;
            stderrPrint(
                "qr-decode: frame {d}/{d} ({s}): version {d}, EC {s}, mask {d}: {s}\n",
                .{ index + 1, options.images.len, loaded.name, decoded.info.version, decoded.info.ec.name(), decoded.info.mask, receiveProblem(err) },
            );
            continue;
        };

        const word: []const u8 = switch (status) {
            .accepted => "accepted",
            .duplicate => "already seen",
            .complete => "complete",
        };
        if (status == .complete) {
            stderrPrint(
                "qr-decode: frame {d}/{d} ({s}): version {d}, EC {s}, mask {d} -> {s}\n",
                .{ index + 1, options.images.len, loaded.name, decoded.info.version, decoded.info.ec.name(), decoded.info.mask, word },
            );
            break;
        }
        stderrPrint(
            "qr-decode: frame {d}/{d} ({s}): version {d}, EC {s}, mask {d} -> {s} ({d}/{d} parts)\n",
            .{
                index + 1,            options.images.len,                   loaded.name,
                decoded.info.version, decoded.info.ec.name(),               decoded.info.mask,
                word,                 session.receiver.receivedPartCount(), session.receiver.expectedPartCount(),
            },
        );
    }

    if (!session.receiver.isComplete()) {
        if (session.receiver.expectedPartCount() == 0) {
            // Not one part was taken in: the per-frame errors above say why (no QR code found,
            // another UR type, ...), which is more use than the generic "incomplete".
            stderrPrint(
                "qr-decode: no UR part was taken in from {d} image(s) ({d} without a readable QR code, {d} refused)\n",
                .{ frames, frames - codes, refused },
            );
            if (last_error) |err| return err;
        } else {
            stderrPrint(
                "qr-decode: incomplete transfer: {d}/{d} parts from {d} images ({d} without a readable QR code, {d} refused)\n",
                .{
                    session.receiver.receivedPartCount(),
                    session.receiver.expectedPartCount(),
                    frames,
                    frames - codes,
                    refused,
                },
            );
        }
        return error.Incomplete;
    }

    const payload = try session.payload();
    const base64 = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, base64.calcSize(payload.len));
    _ = base64.encode(encoded, payload);
    try stdout.print("{s}\n", .{encoded});
    try stdout.flush();

    // A single-part UR (`ur:<type>/<bytewords>`) completes without going through the fragment
    // counter, so it is one part by definition.
    const parts = if (session.receiver.receivedPartCount() > 0) session.receiver.receivedPartCount() else 1;
    stderrPrint("qr-decode: assembled {d} UR part(s), {d} B payload\n", .{ parts, payload.len });
}

// ---------------------------------------------------------------- command line

/// Parses the command line. Bare arguments and `--image <file>` are the same thing to this
/// command, and the order they were written in is the order the frames are fed in (which matters
/// for `--assemble`: the receiver takes parts in any order, but a caller debugging one frame
/// sequence should see their own order in the diagnostics).
fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !Options {
    var options: Options = .{};
    var images: std.ArrayList([]const u8) = .empty;
    var width: ?usize = null;
    var height: ?usize = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--assemble")) {
            options.assemble = true;
        } else if (std.mem.eql(u8, arg, "--image")) {
            try images.append(allocator, try value(args, &i));
        } else if (std.mem.eql(u8, arg, "--format")) {
            const text = try value(args, &i);
            if (std.ascii.eqlIgnoreCase(text, "pgm")) {
                options.format = .pgm;
            } else if (std.ascii.eqlIgnoreCase(text, "raw")) {
                options.format = .raw;
            } else {
                stderrPrint("--format is pgm or raw, not: {s}\n", .{text});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--width")) {
            width = try number(args, &i, "--width");
        } else if (std.mem.eql(u8, arg, "--height")) {
            height = try number(args, &i, "--height");
        } else if (std.mem.eql(u8, arg, "--type")) {
            options.ur_type = try value(args, &i);
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            stderrPrint("unknown option: {s}\n", .{arg});
            return error.Usage;
        } else {
            try images.append(allocator, arg);
        }
    }

    options.images = try images.toOwnedSlice(allocator);
    if (width != null or height != null) {
        if (options.format == .pgm) {
            stderrPrint("--width/--height describe raw 8-bit input, not a PGM file\n", .{});
            return error.InvalidArgument;
        }
        const w = width orelse {
            stderrPrint("--width and --height go together\n", .{});
            return error.InvalidArgument;
        };
        const h = height orelse {
            stderrPrint("--width and --height go together\n", .{});
            return error.InvalidArgument;
        };
        if (w == 0 or h == 0) {
            stderrPrint("--width/--height must be at least 1\n", .{});
            return error.InvalidArgument;
        }
        options.size = .{ .width = w, .height = h };
    }
    if (!ur.isValidType(options.ur_type)) {
        stderrPrint("not a UR type: {s}\n", .{options.ur_type});
        return error.InvalidArgument;
    }
    return options;
}

/// The value of the option at `args[i]`; advances `i` past it.
fn value(args: []const []const u8, i: *usize) ![]const u8 {
    i.* += 1;
    if (i.* >= args.len) {
        stderrPrint("{s} needs a value\n", .{args[i.* - 1]});
        return error.Usage;
    }
    return args[i.*];
}

/// A decimal option value.
fn number(args: []const []const u8, i: *usize, name: []const u8) !usize {
    const text = try value(args, i);
    return std.fmt.parseInt(usize, text, 10) catch {
        stderrPrint("invalid value for {s}: {s}\n", .{ name, text });
        return error.InvalidArgument;
    };
}

// ---------------------------------------------------------------- files

/// One image, its bytes and where it came from.
const Loaded = struct {
    /// The file's bytes (or stdin's); `image.pixels` points into them.
    bytes: []u8,
    name: []const u8,
    image: qr_decode.Image,
};

/// Reads and parses one image. `path` null (or `-`) is stdin.
///
/// Image-level failures are named on stderr before the error is returned: they make the whole run
/// fail (nothing on stdout), because a file this command cannot interpret is a caller mistake,
/// unlike a frame the camera failed to see.
fn loadImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: ?[]const u8,
    format: ?Format,
    size: ?Dimensions,
) !Loaded {
    const from_stdin = path == null or std.mem.eql(u8, path.?, "-");
    const name: []const u8 = if (from_stdin) "<stdin>" else path.?;

    const bytes = if (from_stdin) try readStdin(allocator) else try readFile(allocator, io, path.?);
    errdefer allocator.free(bytes);

    const image = parseImage(bytes, format, size) catch |err| {
        stderrPrint("qr-decode: {s}: {s}\n", .{ name, imageProblem(err) });
        return err;
    };
    return .{ .bytes = bytes, .name = name, .image = image };
}

/// Reads a whole file, bounded by `max_file_len` (the largest image the decoder would accept).
fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_len + 1)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderrPrint("qr-decode: {s}: larger than the {d}x{d} image limit\n", .{ path, max_image_dim, max_image_dim });
            return error.ImageTooLarge;
        },
        else => {
            stderrPrint("qr-decode: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        },
    };
}

/// Reads stdin, bounded the same way (the same `std.posix` read the other commands use).
fn readStdin(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (read == 0) break;
        if (out.items.len + read > max_file_len) {
            stderrPrint("qr-decode: <stdin>: larger than the {d}x{d} image limit\n", .{ max_image_dim, max_image_dim });
            return error.ImageTooLarge;
        }
        try out.appendSlice(allocator, buffer[0..read]);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- diagnostics

/// The image-level errors, as one line each. The error itself is returned to the caller as well,
/// so its name is what a script sees.
fn imageProblem(err: ToolError) []const u8 {
    return switch (err) {
        error.UnsupportedImageFormat => "unsupported image format: pass a PGM (P5) file, or raw 8-bit pixels with --width/--height",
        error.InvalidImageHeader => "malformed PGM header: expected \"P5\", then width, height and a maxval of 1..255",
        error.TruncatedImage => "the pixel data is shorter than width * height",
        error.MissingDimensions => "raw 8-bit input needs --width and --height",
        // Spelled from the constants, so the message cannot go stale if the decoder's limits move.
        error.ImageTooSmall => std.fmt.comptimePrint(
            "image too small: the decoder needs at least {d}x{d} pixels (a version-1 symbol)",
            .{ min_image_dim, min_image_dim },
        ),
        error.ImageTooLarge => std.fmt.comptimePrint(
            "image too large: the decoder accepts at most {d}x{d} pixels",
            .{ max_image_dim, max_image_dim },
        ),
    };
}

/// The QR decoder's errors, as one line each.
fn decodeProblem(err: qr_decode.Error) []const u8 {
    return switch (err) {
        error.SymbolNotFound => "no QR code found in the image (the whole symbol and its quiet zone must be visible)",
        error.TooManyErrors => "a QR code was found but could not be read: more damage than the error correction can repair",
        error.InvalidSymbol => "a QR code was found but its structure is not a valid symbol",
        error.UnsupportedMode => "the QR code uses a mode this decoder does not support (ECI, Kanji, structured append, FNC1)",
        error.Truncated => "the image data ended early",
        error.BufferTooSmall => "the decoded text does not fit the command's buffer",
        else => @errorName(err),
    };
}

/// The assembler's errors, as one line each.
fn receiveProblem(err: ur_receive.ReceiveError) []const u8 {
    return switch (err) {
        error.Incomplete => "the transfer is not complete yet",
        error.TooLarge => std.fmt.comptimePrint(
            "the part needs more room than this command prepared ({d} KiB payload, {d} parts)",
            .{ ur_receive.max_payload_len / 1024, max_parts },
        ),
        error.WrongType => "the image holds a UR code of another type; pass --type to match it",
        error.ConflictingDuplicate => "the same part number arrived twice with different bytes (corruption, or two transfers mixed)",
        error.MetadataMismatch => "the part belongs to a different transfer than the one being assembled",
        error.FountainUnsupported => "a fountain (MUR) redundant part: this firmware does not implement fountain codes",
        error.ChecksumMismatch => "the whole-message checksum did not match, so the assembly was dropped; feed the parts again",
        else => @errorName(err),
    };
}

/// Diagnostics go to stderr; stdout carries results only, as in the rest of the CLI.
fn stderrPrint(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const qr = zhww.ui_qr;

/// A synthetic payload shaped like a PSBT (magic and all), the same stand-in `light_tool.zig`'s
/// tests use: the chain under test (image -> QR -> UR parts -> PSBT) does not care what the
/// payload means.
///
/// The real Bitcoin Core vector (`tests/vectors/core_psbt.json`) is what the CLI round trip uses
/// (`zhww ur < psbt.txt` -> one rendered image per part -> `zhww qr-decode --assemble`); it is not
/// embedded here because this file's tests are compiled with `src/cli/` as the package root (the
/// CLI is not reachable from `tests.zig`), and `@embedFile` may not leave the package root.
fn testPayload() [131]u8 {
    var payload: [131]u8 = undefined;
    @memcpy(payload[0..5], "psbt\xff");
    for (payload[5..], 0..) |*byte, i| byte.* = @intCast((i * 37 + 11) % 256);
    return payload;
}

/// One rendered QR symbol: a grayscale buffer and its side, as the camera would deliver it.
const Rendered = struct {
    pixels: []u8,
    side: usize,
};

/// Renders `text` with the project's own encoder (`ui/qr.zig`), `scale` pixels per module and
/// `quiet` modules of quiet zone, dark on light - what a screen showing the code looks like.
fn renderQr(allocator: std.mem.Allocator, text: []const u8, ec: qr.EcLevel, scale: usize, quiet: usize) !Rendered {
    var matrix = try qr.encode(allocator, text, ec);
    defer matrix.deinit(allocator);

    const side = (matrix.size + 2 * quiet) * scale;
    const pixels = try allocator.alloc(u8, side * side);
    @memset(pixels, 255);
    for (0..matrix.size) |my| {
        for (0..matrix.size) |mx| {
            if (!matrix.get(mx, my)) continue;
            for (0..scale) |dy| {
                for (0..scale) |dx| {
                    pixels[((quiet + my) * scale + dy) * side + (quiet + mx) * scale + dx] = 0;
                }
            }
        }
    }
    return .{ .pixels = pixels, .side = side };
}

/// The same pixels as a PGM (P5) file: what a camera dump or a script writes.
fn pgmBytes(allocator: std.mem.Allocator, pixels: []const u8, width: usize, height: usize) ![]u8 {
    const header = try std.fmt.allocPrint(allocator, "P5\n{d} {d}\n255\n", .{ width, height });
    const out = try allocator.alloc(u8, header.len + pixels.len);
    @memcpy(out[0..header.len], header);
    @memcpy(out[header.len..], pixels);
    return out;
}

/// Splits `payload` into the UR parts of a `crypto-psbt` transfer, exactly as the `ur` command
/// does (CBOR byte string, then sequential parts).
fn urParts(allocator: std.mem.Allocator, payload: []const u8, fragment_len: usize) ![]const []const u8 {
    const message = try cbor.writeBytes(try allocator.alloc(u8, cbor.bytesLength(payload.len)), payload);
    const scratch = try allocator.alloc(u8, ur.maxPartCborLength(fragment_len));
    var encoder = try ur.Encoder.init(ur.type_crypto_psbt, message, fragment_len, ur.default_min_fragment_len, scratch);
    const buffer = try allocator.alloc(u8, ur.Encoder.maxPartLength(ur.type_crypto_psbt.len, encoder.fragment_len));

    var parts: std.ArrayList([]const u8) = .empty;
    while (try encoder.next(buffer, .lower)) |part| {
        try parts.append(allocator, try allocator.dupe(u8, part));
    }
    return parts.toOwnedSlice(allocator);
}

/// Writes `data` into the test's temporary directory and returns the path `std.Io.Dir.cwd()`
/// opens it with (the directory lives under `.zig-cache/tmp`, which is where the test runs).
fn writeTemp(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) ![]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data });
    return std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name });
}

test "PGM (P5): header with comments, CRLF and whitespace; pixels are not copied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const side: usize = 24;
    const pixels = try allocator.alloc(u8, side * side);
    for (pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    // A camera dump: comments, tabs, and a CRLF line ending on the maxval line.
    var file: std.ArrayList(u8) = .empty;
    try file.appendSlice(allocator, "P5\r\n# camera dump, frame 7\n  24\t24\r\n255\r\n");
    try file.appendSlice(allocator, pixels);

    const image = try parsePgm(file.items);
    try testing.expectEqual(@as(usize, 24), image.width);
    try testing.expectEqual(@as(usize, 24), image.height);
    try testing.expectEqualSlices(u8, pixels, image.pixels);
    try testing.expectEqual(@as(usize, 24 * 24), image.pixels.len);
    // In place: no copy of an image the camera may have delivered at 4 MB.
    try testing.expect(@intFromPtr(image.pixels.ptr) >= @intFromPtr(file.items.ptr));
    try testing.expect(@intFromPtr(image.pixels.ptr) + image.pixels.len <= @intFromPtr(file.items.ptr) + file.items.len);

    // A comment directly after a field, before the next one.
    var commented: std.ArrayList(u8) = .empty;
    try commented.appendSlice(allocator, "P5 # after the magic\n24 24 # size\n255\n");
    try commented.appendSlice(allocator, pixels);
    const with_comments = try parsePgm(commented.items);
    try testing.expectEqualSlices(u8, pixels, with_comments.pixels);

    // The bytes after the image are ignored (a dump may be padded).
    try file.appendSlice(allocator, "\x00\x00\x00");
    const padded = try parsePgm(file.items);
    try testing.expectEqualSlices(u8, pixels, padded.pixels);
}

test "PGM (P5): malformed headers are named errors, not a decode of nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const side: usize = 24;
    const pixels = try allocator.alloc(u8, side * side);
    @memset(pixels, 127);

    const Case = struct { data: []const u8, expected: ToolError };
    const cases = [_]Case{
        // No magic at all (a PNG, a raw frame without --width/--height, ...).
        .{ .data = "\x89PNG\r\n\x1a\n", .expected = error.InvalidImageHeader },
        // Another Netpbm format, by name: ASCII PGM, PPM, 16-bit PGM.
        .{ .data = "P2\n24 24\n255\n", .expected = error.UnsupportedImageFormat },
        .{ .data = "P6\n24 24\n255\n", .expected = error.UnsupportedImageFormat },
        .{ .data = "P5\n24 24\n65535\n", .expected = error.UnsupportedImageFormat },
        .{ .data = "P5\n24 24\n0\n", .expected = error.UnsupportedImageFormat },
        // Broken headers: fields missing, a number that is not a number, a stray byte, a 0 side.
        .{ .data = "P5\n", .expected = error.InvalidImageHeader },
        .{ .data = "P5\n24\n", .expected = error.InvalidImageHeader },
        .{ .data = "P5\n24 24\n", .expected = error.InvalidImageHeader },
        .{ .data = "P5\n4x4 24\n255\n", .expected = error.InvalidImageHeader },
        .{ .data = "P5\n0 24\n255\n", .expected = error.InvalidImageHeader },
        .{ .data = "P5\n24 24\n255", .expected = error.InvalidImageHeader }, // no separator
        // Sizes the decoder will not work with.
        .{ .data = "P5\n20 24\n255\n", .expected = error.ImageTooSmall },
        .{ .data = "P5\n24 20\n255\n", .expected = error.ImageTooSmall },
        .{ .data = "P5\n4097 24\n255\n", .expected = error.ImageTooLarge },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, parsePgm(case.data));
    }

    // A well-formed header whose pixel data stops early: the error is about the data, not the
    // header. 24 * 24 - 1 bytes cannot describe a 24x24 image.
    var short: std.ArrayList(u8) = .empty;
    try short.appendSlice(allocator, "P5\n24 24\n255\n");
    try short.appendSlice(allocator, pixels[0 .. pixels.len - 1]);
    try testing.expectError(error.TruncatedImage, parsePgm(short.items));

    // The empty buffer is a header error, not a crash.
    try testing.expectError(error.InvalidImageHeader, parsePgm(&.{}));
}

test "raw 8-bit: --width/--height cut the buffer; P5 wins until --format raw" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const side: usize = 32;
    const pixels = try allocator.alloc(u8, side * side + 7); // padded, as a camera frame may be
    for (pixels, 0..) |*p, i| p.* = @intCast((i * 7 + 3) % 256);

    const image = try parseRaw(pixels, .{ .width = side, .height = side });
    try testing.expectEqual(@as(usize, side), image.width);
    try testing.expectEqual(@as(usize, side), image.height);
    try testing.expectEqualSlices(u8, pixels[0 .. side * side], image.pixels);

    // Auto-detection: no PGM magic, dimensions given -> raw.
    const auto = try parseImage(pixels, null, .{ .width = side, .height = side });
    try testing.expectEqual(@as(usize, side * side), auto.pixels.len);

    // Without dimensions and without a magic, there is nothing to go by.
    try testing.expectError(error.UnsupportedImageFormat, parseImage(pixels, null, null));
    try testing.expectError(error.MissingDimensions, parseImage(pixels, .raw, null));

    // Too few bytes for the size that was asked for, and sizes the decoder refuses.
    try testing.expectError(error.TruncatedImage, parseRaw(pixels[0 .. side * side - 1], .{ .width = side, .height = side }));
    try testing.expectError(error.ImageTooSmall, parseRaw(pixels, .{ .width = 20, .height = 20 }));
    try testing.expectError(error.ImageTooLarge, parseRaw(pixels, .{ .width = 5000, .height = 24 }));

    // A raw frame whose first two bytes happen to spell the PGM magic: the magic decides, and
    // `--format raw` is what overrides it (both readings are an error here, in different ways).
    const decoy = try allocator.dupe(u8, pixels);
    decoy[0] = 'P';
    decoy[1] = '5';
    try testing.expectError(error.InvalidImageHeader, parseImage(decoy, null, .{ .width = side, .height = side }));
    const forced = try parseImage(decoy, .raw, .{ .width = side, .height = side });
    try testing.expectEqualSlices(u8, decoy[0 .. side * side], forced.pixels);
}

test "synthetic round trip: a rendered QR decodes back to its text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const text = "ur:crypto-psbt/1-3/lpaxa";
    const rendered = try renderQr(allocator, text, .m, 4, qr.min_quiet_zone);
    const file = try pgmBytes(allocator, rendered.pixels, rendered.side, rendered.side);

    const image = try parseImage(file, null, null);
    const decoded = try decodeImage(allocator, image);
    try testing.expectEqualStrings(text, decoded.text);
    try testing.expect(decoded.info.version >= qr.min_version);
    try testing.expectEqual(qr.EcLevel.m, decoded.info.ec);

    // And the same buffer read as raw 8-bit with the dimensions of the rendered symbol.
    const raw = try parseImage(rendered.pixels, null, .{ .width = rendered.side, .height = rendered.side });
    const from_raw = try decodeImage(allocator, raw);
    try testing.expectEqualStrings(text, from_raw.text);
}

test "several parts assemble into the PSBT, duplicates and disorder included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    const payload = testPayload();
    const parts = try urParts(allocator, &payload, 40);
    try testing.expect(parts.len > 2); // a genuinely multi-part transfer

    var session = try Session.init(allocator, ur.type_crypto_psbt);
    defer session.deinit(allocator);

    // A camera's arrival order: the first frame seen twice, then the rest out of order, but with
    // no part missed. The repeat is harmless while parts are still missing.
    try testing.expectEqual(ur_receive.Status.accepted, try session.feed(parts[0]));
    try testing.expectEqual(ur_receive.Status.duplicate, try session.feed(parts[0]));
    try testing.expect(!session.receiver.isComplete());
    try testing.expectEqual(@as(usize, 1), session.receiver.receivedPartCount());

    var order: std.ArrayList(usize) = .empty;
    try order.append(allocator, 2);
    try order.append(allocator, 1);
    for (3..parts.len) |index| try order.append(allocator, index);
    for (order.items, 0..) |index, k| {
        const status = try session.feed(parts[index]);
        // The last part of the sequence is the one that completes the message.
        const last = k + 1 == order.items.len;
        try testing.expectEqual(if (last) ur_receive.Status.complete else ur_receive.Status.accepted, status);
    }
    try testing.expect(session.receiver.isComplete());
    try testing.expectEqual(parts.len, session.receiver.expectedPartCount());
    try testing.expectEqualSlices(u8, &payload, try session.payload());

    // A part of another UR type is refused by name, and does not touch the assembly.
    var other = try Session.init(allocator, ur.type_bytes);
    defer other.deinit(allocator);
    try testing.expectError(error.WrongType, other.feed(parts[0]));
    try testing.expectEqual(@as(usize, 0), other.receiver.receivedPartCount());

    // Asking for the payload before the transfer is complete is an error, never a partial PSBT.
    var partial = try Session.init(allocator, ur.type_crypto_psbt);
    defer partial.deinit(allocator);
    _ = try partial.feed(parts[0]);
    try testing.expectError(error.Incomplete, partial.payload());
}

test "the command: one image, the decoded text on stdout and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const text = "ur:crypto-psbt/1-3/lpaxa";
    const rendered = try renderQr(allocator, text, .q, 4, qr.min_quiet_zone);
    const path = try writeTemp(allocator, &tmp, "frame.pgm", try pgmBytes(allocator, rendered.pixels, rendered.side, rendered.side));

    var out: std.Io.Writer.Allocating = .init(allocator);
    try run(allocator, &.{ "--image", path }, &out.writer, std.testing.io);
    try testing.expectEqualStrings(text ++ "\n", out.written());

    // A second image is decoded too: one line per image, in the order given (bare arguments and
    // --image are the same thing, and the order is the caller's).
    const second = try renderQr(allocator, "SECOND FRAME", .m, 4, qr.min_quiet_zone);
    const second_path = try writeTemp(allocator, &tmp, "second.pgm", try pgmBytes(allocator, second.pixels, second.side, second.side));
    var both: std.Io.Writer.Allocating = .init(allocator);
    try run(allocator, &.{ "--image", path, second_path }, &both.writer, std.testing.io);
    try testing.expectEqualStrings(text ++ "\nSECOND FRAME\n", both.written());
}

test "the command: --assemble prints the PSBT once every part has been seen" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = testPayload();
    const parts = try urParts(allocator, &payload, 40);
    try testing.expect(parts.len > 2); // a genuinely multi-part transfer

    // One image per part, as a camera dump would be.
    const paths = try allocator.alloc([]const u8, parts.len);
    for (parts, 0..) |part, index| {
        const rendered = try renderQr(allocator, part, .m, 4, qr.min_quiet_zone);
        const name = try std.fmt.allocPrint(allocator, "part{d}.pgm", .{index + 1});
        paths[index] = try writeTemp(allocator, &tmp, name, try pgmBytes(allocator, rendered.pixels, rendered.side, rendered.side));
    }

    // A camera-like order: the first frame twice, then the parts from the last one backwards, so
    // the part that completes the transfer is the last argument (nothing is missed).
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, "--assemble");
    try args.appendSlice(allocator, &.{ paths[0], paths[0] });
    for (1..parts.len) |i| try args.append(allocator, paths[parts.len - i]);

    var out: std.Io.Writer.Allocating = .init(allocator);
    try run(allocator, args.items, &out.writer, std.testing.io);

    const expected = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(payload.len));
    _ = std.base64.standard.Encoder.encode(expected, &payload);
    var want: std.ArrayList(u8) = .empty;
    try want.appendSlice(allocator, expected);
    try want.append(allocator, '\n');
    try testing.expectEqualStrings(want.items, out.written());

    // One part missing: the answer is an error and stdout stays empty - a partial PSBT is worse
    // than no PSBT.
    var incomplete: std.Io.Writer.Allocating = .init(allocator);
    try testing.expectError(
        error.Incomplete,
        run(allocator, &.{ "--assemble", paths[0], paths[1] }, &incomplete.writer, std.testing.io),
    );
    try testing.expectEqualStrings("", incomplete.written());

    // --assemble with nothing to assemble, and a file that is not there, are usage errors.
    var none: std.Io.Writer.Allocating = .init(allocator);
    try testing.expectError(error.Usage, run(allocator, &.{"--assemble"}, &none.writer, std.testing.io));
    try testing.expectError(
        error.FileNotFound,
        run(allocator, &.{ "--assemble", ".zig-cache/tmp/does-not-exist.pgm" }, &none.writer, std.testing.io),
    );
    try testing.expectEqualStrings("", none.written());

    // Bad arguments are named, and nothing is decoded on their account.
    try testing.expectError(error.Usage, run(allocator, &.{"--wat"}, &none.writer, std.testing.io));
    try testing.expectError(error.InvalidArgument, run(allocator, &.{ "--format", "png" }, &none.writer, std.testing.io));
    try testing.expectError(error.InvalidArgument, run(allocator, &.{ "--width", "240" }, &none.writer, std.testing.io));
    try testing.expectError(error.Usage, run(allocator, &.{"--image"}, &none.writer, std.testing.io));
    try testing.expectEqualStrings("", none.written());
}

test "the command: an image without a QR code is a named error and an empty stdout" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A frame the camera saw nothing in (all white, all quiet zone).
    const blank = try allocator.alloc(u8, 64 * 64);
    @memset(blank, 255);
    const blank_path = try writeTemp(allocator, &tmp, "blank.pgm", try pgmBytes(allocator, blank, 64, 64));

    var out: std.Io.Writer.Allocating = .init(allocator);
    try testing.expectError(error.SymbolNotFound, run(allocator, &.{blank_path}, &out.writer, std.testing.io));
    try testing.expectEqualStrings("", out.written());

    // The same frame in --assemble: one frame, no part, and the reason is still "no QR code".
    try testing.expectError(error.SymbolNotFound, run(allocator, &.{ "--assemble", blank_path }, &out.writer, std.testing.io));
    try testing.expectEqualStrings("", out.written());

    // A PPM (P6) file is refused before any decoding, whatever the mode.
    const ppm = "P6\n24 24\n255\n" ++ blank[0 .. 24 * 24];
    const ppm_path = try writeTemp(allocator, &tmp, "frame.ppm", ppm);
    try testing.expectError(error.UnsupportedImageFormat, run(allocator, &.{ppm_path}, &out.writer, std.testing.io));
    try testing.expectEqualStrings("", out.written());

    // A raw frame without dimensions is refused by name, and with them it is decoded.
    const raw_path = try writeTemp(allocator, &tmp, "frame.raw", blank);
    try testing.expectError(error.UnsupportedImageFormat, run(allocator, &.{raw_path}, &out.writer, std.testing.io));
    try testing.expectError(
        error.ImageTooSmall,
        run(allocator, &.{ "--format", "raw", "--width", "20", "--height", "20", raw_path }, &out.writer, std.testing.io),
    );
    try testing.expectError(
        error.SymbolNotFound,
        run(allocator, &.{ "--format", "raw", "--width", "64", "--height", "64", raw_path }, &out.writer, std.testing.io),
    );
    try testing.expectEqualStrings("", out.written());
}
