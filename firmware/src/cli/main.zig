//! zhww developer CLI.
//!
//! A tool for generating addresses, signing PSBTs and checking dice rolls from
//! the terminal, before the on-device (Raspberry Pi) screen UI exists.
//!
//! **Output policy**: results go to stdout, diagnostics (fees, warnings, ...)
//! go to stderr. This allows pipelines like `zhww sign < psbt.txt > signed.txt`.
//!
//! In Zig 0.17 stdout goes through `std.Io`, and process arguments arrive via
//! `pub fn main(init: std.process.Init.Minimal)`.
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("zhww");

const usage =
    \\Usage: zhww <command> [options]
    \\
    \\Commands:
    \\  address     Show the address for a mnemonic
    \\  show        Show the contents of a PSBT in human-readable form
    \\  screen      Render the device screen (240x240) as a PNG
    \\  walkthrough Render the device screen flow (card, confirm, result QR) as PNGs
    \\  card        Work with a FAT32 image (a stand-in for the microSD card)
    \\  sign        Sign a PSBT (base64) read from stdin
    \\  ur          Convert a PSBT (base64) to UR (for QR transfer)
    \\  ur-decode   Read UR parts and turn them back into a PSBT (base64)
    \\  mnemonic    Build a mnemonic from dice rolls (for verifying your records)
    \\  evm-sign    Sign an EVM transaction (JSON)
    \\  evm-show    Show a signed or unsigned EVM transaction (raw hex)
    \\  version     Show the version
    \\
    \\address options:
    \\  --mnemonic "<12/24 words>"  Source mnemonic (required)
    \\  --passphrase "<string>"     Passphrase (optional)
    \\  --path "m/84'/0'/0'/0/0"    Derivation path (default: m/84'/0'/0'/0/0)
    \\  --network mainnet|testnet|signet|regtest (default: mainnet)
    \\  --kind p2wpkh|p2pkh|p2sh-p2wpkh|p2tr (default: p2wpkh)
    \\
    \\sign options:
    \\  --mnemonic "..."           Mnemonic to sign with (required)
    \\  --passphrase "..."         Passphrase (optional)
    \\
    \\show / screen options:
    \\  --network mainnet|testnet|signet|regtest (for address display; default: mainnet)
    \\  --mnemonic "..."           If given, detect the change output (optional)
    \\  --scale <n>                Scale each pixel by n (screen; default: 1)
    \\  --demo                     Draw a sample confirmation screen (screen; no input)
    \\  --qr                       Show the stdin text as a QR code (screen)
    \\  --ec l|m|q|h               QR error correction level (default: m)
    \\
    \\walkthrough options:
    \\  --image <file>             FAT32 image (required)
    \\  --mnemonic "..."           Mnemonic to sign with (required)
    \\  --out-dir <dir>            PNG output directory (default: current directory)
    \\  --scale <n>                Scale each pixel by n (default: 2)
    \\  --part <n>                 UR part to show in the result QR (default: 1)
    \\
    \\card usage (--image <file> is required; works without a physical card):
    \\  card list                    List files
    \\  card read  --name /IN.PSBT   Write the contents to stdout
    \\  card write --name /OUT.PSBT  Write stdin to the file
    \\  card rm    --name /OUT.PSBT  Delete
    \\  card mv    --name /OUT.TMP --to /OUT.PSBT   Rename
    \\  card sign  --mnemonic "..."  Sign /IN.PSBT and create /OUT.PSBT
    \\                               (write /OUT.TMP first, then rename)
    \\
    \\ur options:
    \\  --fragment <n>             Max bytes per QR code (default: 40)
    \\  --type <type name>         UR type (default: crypto-psbt)
    \\
    \\mnemonic options:
    \\  --dice "123456..."         Dice rolls (1-6)
    \\  --words 12|24              Word count (default: 24)
    \\  --camera <hex>             Extra entropy such as camera noise (optional)
    \\
    \\evm-sign options:
    \\  --mnemonic "..."           Mnemonic to sign with (required; uses 44h/60h/0h/0/0)
    \\  --passphrase "..."         Passphrase (optional)
    \\  Input (JSON): chainId / nonce / to / value / gasLimit / gasPrice,
    \\                or maxFeePerGas and maxPriorityFeePerGas (EIP-1559)
    \\
    \\evm-show options:
    \\  Input is a raw transaction in hex (the 0x prefix is optional)
    \\
;

const CliError = error{
    Usage,
    InvalidArgument,
    NotImplemented,
};

pub fn main(init: std.process.Init.Minimal) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();
    var stdout_buffer: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);

    run(init, &stdout, io) catch |err| {
        switch (err) {
            error.Usage => {
                stderrPrint("{s}", .{usage});
            },
            else => {
                stderrPrint("error: {s}\n", .{@errorName(err)});
            },
        }
        stdout.interface.flush() catch {};
        std.process.exit(1);
    };
    // Output is buffered, so always flush it
    stdout.interface.flush() catch {};
}

fn stderrPrint(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

fn run(init: std.process.Init.Minimal, stdout: anytype, io: std.Io) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayList([]const u8).empty;
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next(); // skip argv[0]
    while (iterator.next()) |arg| try args.append(allocator, arg);

    if (args.items.len == 0) return error.Usage;
    const command = args.items[0];

    if (std.mem.eql(u8, command, "version")) {
        try stdout.interface.print("zhww 0.1.0 (experimental)\n", .{});
        return;
    }
    if (std.mem.eql(u8, command, "address")) {
        try commandAddress(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "sign")) {
        try commandSign(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "evm-show")) {
        try commandEvmShow(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "walkthrough")) {
        try commandWalkthrough(allocator, args.items[1..], stdout, io);
        return;
    }
    if (std.mem.eql(u8, command, "card")) {
        try commandCard(allocator, args.items[1..], stdout, io);
        return;
    }
    if (std.mem.eql(u8, command, "evm-sign")) {
        try commandEvmSign(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "screen")) {
        try commandScreen(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "show")) {
        try commandShow(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "mnemonic")) {
        try commandMnemonic(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "ur")) {
        try commandUr(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "ur-decode")) {
        try commandUrDecode(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        return error.Usage;
    }
    return error.Usage;
}

// ---------------------------------------------------------------- arguments

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

/// Whether a value-less flag (such as `--demo`) was given.
///
/// `option()` reads the following argument as the flag's value, so it cannot be used for
/// value-less flags: passing `--demo` on its own would consume whatever argument happens to
/// follow it. This helper only checks for presence.
fn hasFlag(args: []const []const u8, name: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, name)) return true;
    }
    return false;
}

fn requiredOption(args: []const []const u8, name: []const u8) ![]const u8 {
    return option(args, name) orelse {
        stderrPrint("{s} is required\n", .{name});
        return error.Usage;
    };
}

fn networkOf(args: []const []const u8) !zhww.btc_address.Network {
    const name = option(args, "--network") orelse return .mainnet;
    if (std.mem.eql(u8, name, "mainnet")) return .mainnet;
    if (std.mem.eql(u8, name, "testnet")) return .testnet;
    if (std.mem.eql(u8, name, "signet")) return .signet;
    if (std.mem.eql(u8, name, "regtest")) return .regtest;
    stderrPrint("invalid value for --network: {s}\n", .{name});
    return error.InvalidArgument;
}

// ---------------------------------------------------------------- address

fn commandAddress(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const mnemonic = try requiredOption(args, "--mnemonic");
    const passphrase = option(args, "--passphrase") orelse "";
    const path = option(args, "--path") orelse "m/84'/0'/0'/0/0";
    const network = try networkOf(args);
    const kind = option(args, "--kind") orelse "p2wpkh";

    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const master = keys.master orelse return error.InvalidArgument;
    const node = try master.derivePath(path);
    const pub_key = try node.publicKey();

    var buffer: [90]u8 = undefined;
    const address = if (std.mem.eql(u8, kind, "p2wpkh"))
        try zhww.btc_address.p2wpkh(&buffer, pub_key, network)
    else if (std.mem.eql(u8, kind, "p2pkh"))
        try zhww.btc_address.p2pkh(&buffer, pub_key, network)
    else if (std.mem.eql(u8, kind, "p2sh-p2wpkh"))
        try zhww.btc_address.p2shP2wpkh(&buffer, pub_key, network)
    else if (std.mem.eql(u8, kind, "p2tr"))
        try zhww.btc_address.p2tr(&buffer, try zhww.secp256k1.xonly(pub_key), network)
    else {
        stderrPrint("invalid value for --kind: {s}\n", .{kind});
        return error.InvalidArgument;
    };

    try stdout.interface.print("{s}\n", .{address});
    _ = allocator;
}

// ---------------------------------------------------------------- sign

fn commandSign(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const mnemonic = try requiredOption(args, "--mnemonic");
    const passphrase = option(args, "--passphrase") orelse "";

    // Read the base64 PSBT from stdin
    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("pass a PSBT (base64) on stdin\n", .{});
        return error.Usage;
    }

    const decoder = std.base64.standard.Decoder;
    const raw_len = decoder.calcSizeForSlice(trimmed) catch {
        stderrPrint("cannot decode the base64 PSBT\n", .{});
        return error.InvalidArgument;
    };
    const raw = try allocator.alloc(u8, raw_len);
    try decoder.decode(raw, trimmed);

    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const outcome = try zhww.btc_sign.signPsbtBytes(allocator, raw, keys);

    // Diagnostics go to stderr
    stderrPrint(
        "signed inputs: {d} / unsigned inputs: {d}\n",
        .{ outcome.result.partial_sigs.len, outcome.result.unsigned_inputs.len },
    );
    if (outcome.result.total_input) |total| stderrPrint("input total: {d} sats\n", .{total});
    if (outcome.result.fee) |fee| {
        stderrPrint("fee: {d} sats\n", .{fee});
    } else {
        stderrPrint("fee: unknown (input amounts incomplete; not calculated)\n", .{});
    }
    if (outcome.result.change_outputs.len > 0) {
        stderrPrint("change: output #{d}\n", .{outcome.result.change_outputs[0]});
    }
    for (outcome.result.unsigned_inputs) |index| {
        stderrPrint("warning: input {d} could not be signed\n", .{index});
    }

    // Results go to stdout
    const encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, encoder.calcSize(outcome.signed_psbt.len));
    _ = encoder.encode(encoded, outcome.signed_psbt);
    try stdout.interface.print("SIGNED_PSBT={s}\n", .{encoded});

    if (outcome.result.final_tx) |final_tx| {
        const hex = try allocator.alloc(u8, final_tx.len * 2);
        try stdout.interface.print("FINAL_TX={s}\n", .{toHex(final_tx, hex)});
    }
    try stdout.interface.flush();
}

fn readAllStdin(allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const read = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (read == 0) break;
        try out.appendSlice(allocator, buffer[0..read]);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------- mnemonic

fn commandMnemonic(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const dice_text = try requiredOption(args, "--dice");
    const words_text = option(args, "--words") orelse "24";
    const word_count = std.fmt.parseInt(usize, words_text, 10) catch {
        stderrPrint("invalid value for --words: {s}\n", .{words_text});
        return error.InvalidArgument;
    };

    var dice: zhww.entropy.Dice = .{};
    dice.rollString(dice_text) catch {
        stderrPrint("use only digits 1-6 in --dice\n", .{});
        return error.InvalidArgument;
    };

    var camera_bytes: ?[]u8 = null;
    if (option(args, "--camera")) |camera_hex| {
        const cleaned = if (std.mem.startsWith(u8, camera_hex, "0x")) camera_hex[2..] else camera_hex;
        if (cleaned.len % 2 != 0) {
            stderrPrint("--camera must be hex\n", .{});
            return error.InvalidArgument;
        }
        const bytes = try allocator.alloc(u8, cleaned.len / 2);
        _ = std.fmt.hexToBytes(bytes, cleaned) catch {
            stderrPrint("--camera must be hex\n", .{});
            return error.InvalidArgument;
        };
        camera_bytes = bytes;
    }

    var sources: [1][]const u8 = undefined;
    const extra: []const []const u8 = if (camera_bytes) |bytes| blk: {
        sources[0] = bytes;
        break :blk sources[0..1];
    } else &.{};

    var mnemonic: [256]u8 = undefined;
    const text = try zhww.entropy.mnemonicFromDice(&mnemonic, dice, extra, word_count);

    // Also report the roll count and the required count (diagnostics go to stderr)
    const needed = if (word_count == 12)
        zhww.entropy.rolls_for_12_words
    else
        zhww.entropy.rolls_for_24_words;
    if (dice.len < needed) {
        stderrPrint("warning: {d} words need {d} rolls (only {d} given)\n", .{
            word_count,
            needed,
            dice.len,
        });
    }

    try stdout.interface.print("{s}\n", .{text});
}

// ---------------------------------------------------------------- EVM

/// Sign an EVM transaction (JSON) and output the raw tx.
///
/// Supported: EIP-155 (legacy) and EIP-1559 (type 2). `maxFeePerGas` means EIP-1559.
/// The key is `m/44'/60'/0'/0/0` (the standard EVM derivation path).
fn commandEvmSign(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const mnemonic = try requiredOption(args, "--mnemonic");
    const passphrase = option(args, "--passphrase") orelse "";

    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("pass the transaction JSON on stdin\n", .{});
        return error.Usage;
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        trimmed,
        .{ .parse_numbers = false },
    ) catch {
        stderrPrint("cannot parse the JSON\n", .{});
        return error.InvalidArgument;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArgument;
    const root = parsed.value.object;

    const chain_id = try jsonU256(root, "chainId");
    const nonce = try jsonU256(root, "nonce");
    const gas_limit = try jsonU256(root, "gasLimit");
    const value = try jsonU256(root, "value");
    const to = try jsonAddress(root, "to");
    const data = try jsonHex(allocator, root, "data");

    // Key (EVM uses m/44'/60'/0'/0/0)
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const node = try keys.derive(&[_]u32{
        44 | zhww.bip32.hardened,
        60 | zhww.bip32.hardened,
        0 | zhww.bip32.hardened,
        0,
        0,
    });
    const priv = node.key.priv;

    var buffer: [8192]u8 = undefined;
    var signed: []u8 = undefined;

    if (root.get("maxFeePerGas") != null) {
        const tx = zhww.evm_transaction.Eip1559Tx{
            .chain_id = chain_id,
            .nonce = nonce,
            .max_priority_fee_per_gas = try jsonU256(root, "maxPriorityFeePerGas"),
            .max_fee_per_gas = try jsonU256(root, "maxFeePerGas"),
            .gas_limit = gas_limit,
            .to = to,
            .value = value,
            .data = data,
            .access_list = &.{},
        };
        signed = try zhww.evm_transaction.signEip1559(&buffer, tx, priv);
        stderrPrint("type: EIP-1559 (type 2)\n", .{});
    } else {
        const tx = zhww.evm_transaction.LegacyTx{
            .nonce = nonce,
            .gas_price = try jsonU256(root, "gasPrice"),
            .gas_limit = gas_limit,
            .to = to,
            .value = value,
            .data = data,
            .chain_id = chain_id,
        };
        signed = try zhww.evm_transaction.signLegacy(&buffer, tx, priv);
        stderrPrint("type: legacy (EIP-155)\n", .{});
    }

    // Also print the sender address (for verification)
    const address_buffer = try allocator.alloc(u8, 42);
    const signer = try zhww.evm_address.fromPublicKey(
        address_buffer,
        try zhww.secp256k1.pubKeyUncompressed(priv),
    );
    stderrPrint("from: {s}\n", .{signer});

    const hex = try allocator.alloc(u8, signed.len * 2);
    try stdout.interface.print("{s}\n", .{toHex(signed, hex)});
}

fn jsonU256(root: std.json.ObjectMap, name: []const u8) !u256 {
    const value = root.get(name) orelse {
        stderrPrint("{s} is missing\n", .{name});
        return error.InvalidArgument;
    };
    const text = switch (value) {
        .number_string => |s| s,
        .string => |s| s,
        .integer => |n| return @intCast(n),
        else => return error.InvalidArgument,
    };
    if (std.mem.startsWith(u8, text, "0x")) {
        var bytes: [32]u8 = @splat(0);
        const hex_text = text[2..];
        if (hex_text.len == 0 or hex_text.len > 64 or hex_text.len % 2 != 0) {
            return error.InvalidArgument;
        }
        _ = std.fmt.hexToBytes(bytes[32 - hex_text.len / 2 ..], hex_text) catch {
            return error.InvalidArgument;
        };
        return std.mem.readInt(u256, &bytes, .big);
    }
    return std.fmt.parseInt(u256, text, 10) catch error.InvalidArgument;
}

fn jsonAddress(root: std.json.ObjectMap, name: []const u8) !?[20]u8 {
    const value = root.get(name) orelse return null;
    if (value != .string) return error.InvalidArgument;
    const text = value.string;
    if (text.len == 0) return null;
    const hex_text = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (hex_text.len != 40) return error.InvalidArgument;
    var out: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex_text) catch return error.InvalidArgument;
    return out;
}

fn jsonHex(allocator: std.mem.Allocator, root: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = root.get(name) orelse return &.{};
    if (value != .string) return error.InvalidArgument;
    const text = value.string;
    const hex_text = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
    if (hex_text.len == 0) return &.{};
    if (hex_text.len % 2 != 0) return error.InvalidArgument;
    const out = try allocator.alloc(u8, hex_text.len / 2);
    _ = std.fmt.hexToBytes(out, hex_text) catch return error.InvalidArgument;
    return out;
}

// ---------------------------------------------------------------- walkthrough

/// Write the device screen flow (insert card -> confirm -> sign -> show result QR)
/// to PNG files. Lets you check the UI and the handoff flow without a device.
fn commandWalkthrough(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    io: std.Io,
) !void {
    _ = stdout;
    const image_path = try requiredOption(args, "--image");
    const mnemonic = try requiredOption(args, "--mnemonic");
    const out_dir = option(args, "--out-dir") orelse ".";
    const scale_text = option(args, "--scale") orelse "2";
    const scale = try std.fmt.parseInt(usize, scale_text, 10);

    const file = std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_write }) catch {
        stderrPrint("cannot open image: {s}\n", .{image_path});
        return error.InvalidArgument;
    };
    defer file.close(io);
    const stat = std.Io.File.stat(file, io) catch return error.InvalidArgument;

    var device = file_device.FileDevice.init(file, io, stat.size);
    var fs = try zhww.fs_fat32.Fat32.mount(device.device(), allocator);
    defer fs.deinit();

    const width: usize = 240;
    const height: usize = 240;
    const pixels = try allocator.alloc(u16, width * height);
    const big = try allocator.alloc(u16, width * scale * height * scale);

    // --- Screen 1: waiting for the card ---
    try renderNotice(allocator, io, out_dir, "1-waiting.png",
        zhww.app_device.noticeFor(.waiting_card), pixels, big, width, height, scale);

    // --- Screens 2-5: errors (always show on screen that nothing is signed) ---
    try renderNotice(allocator, io, out_dir, "2-not-fat32.png",
        zhww.app_device.noticeFor(.not_fat32), pixels, big, width, height, scale);
    try renderNotice(allocator, io, out_dir, "3-no-input.png",
        zhww.app_device.noticeFor(.no_input), pixels, big, width, height, scale);
    try renderNotice(allocator, io, out_dir, "4-too-large.png",
        zhww.app_device.noticeFor(.file_too_large), pixels, big, width, height, scale);
    try renderNotice(allocator, io, out_dir, "5-invalid-psbt.png",
        zhww.app_device.noticeFor(.invalid_psbt), pixels, big, width, height, scale);

    // --- Screen 2: inspect the contents of the card ---
    {
        var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, width, height);
        var list_buffer: [4]zhww.ui_screen.Line = undefined;
        var count: usize = 0;
        var names: [4][]const u8 = undefined;
        var sizes: [4]u64 = undefined;

        var iterator = try fs.openDir("/");
        var entry: zhww.fs_fat32.Entry = .{};
        while (try iterator.next(&entry)) {
            if (entry.isDot() or entry.isDirectory()) continue;
            if (count >= list_buffer.len) break;
            names[count] = try allocator.dupe(u8, entry.nameSlice());
            sizes[count] = entry.size;
            count += 1;
        }
        for (0..count) |i| {
            list_buffer[i] = .{
                .label = "",
                .value = try std.fmt.allocPrint(allocator, "{s} ({d}B)", .{ names[i], sizes[i] }),
            };
        }
        const has_input = fs.exists("/IN.PSBT") catch false;
        const screen = zhww.ui_screen.Screen{
            .title = if (has_input) "SIGN THIS?" else "NO IN.PSBT",
            .lines = list_buffer[0..count],
            .warnings = if (has_input) &.{} else &.{"IN.PSBT was not found on the card"},
            .footer_left = "CANCEL",
            .footer_right = if (has_input) "SIGN" else "",
        };
        screen.render(&fb);
        try writeScreenPng(allocator, io, out_dir, "6-confirm.png", pixels, big, width, height, scale);
    }

    // --- Screen 3: show the result as a QR code (turn the signed PSBT into UR) ---
    {
        const raw = try fs.readFileAlloc(allocator, "/IN.PSBT", 64 * 1024);
        var psbt_bytes: []const u8 = raw;
        if (!std.mem.startsWith(u8, raw, "psbt\xff")) {
            var cleaned = std.ArrayList(u8).empty;
            for (raw) |c| {
                if (c != '\n' and c != '\r' and c != ' ' and c != '\t') try cleaned.append(allocator, c);
            }
            const decoder = std.base64.standard.Decoder;
            const decoded = try allocator.alloc(u8, try decoder.calcSizeForSlice(cleaned.items));
            try decoder.decode(decoded, cleaned.items);
            psbt_bytes = decoded;
        }
        const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, "");
        const outcome = try zhww.btc_sign.signPsbtBytes(allocator, psbt_bytes, keys);

        // Turn the signed PSBT into UR (show part 1 = same as the device's animated QR)
        var scratch: [8192]u8 = undefined;
        var encoder = try zhww.ur.Encoder.init(
            zhww.ur.type_crypto_psbt,
            outcome.signed_psbt,
            60,
            zhww.ur.default_min_fragment_len,
            &scratch,
        );
        // Build all parts and show the requested one (same as NEXT PART on the device)
        var parts = std.ArrayList([]const u8).empty;
        var part_buffer: [1024]u8 = undefined;
        while (try encoder.next(&part_buffer, .lower)) |part| {
            try parts.append(allocator, try allocator.dupe(u8, part));
            if (parts.items.len > 64) break; // just in case
        }
        const part_index_text = option(args, "--part") orelse "1";
        const part_index = @max(@as(usize, 1), std.fmt.parseInt(usize, part_index_text, 10) catch 1);
        const shown_index = @min(part_index, parts.items.len);
        const first_part = if (parts.items.len > 0) parts.items[shown_index - 1] else "";

        var matrix = try zhww.ui_qr.encode(allocator, first_part, .m);
        defer matrix.deinit(allocator);

        var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, width, height);
        const lines = [_]zhww.ui_screen.Line{
            .{ .label = "SCAN", .value = try std.fmt.allocPrint(
                allocator,
                "signed {d}/{d} inputs",
                .{ outcome.result.partial_sigs.len, outcome.result.partial_sigs.len + outcome.result.unsigned_inputs.len },
            ) },
            .{ .label = "", .value = try std.fmt.allocPrint(
                allocator,
                "part {d}/{d}",
                .{ shown_index, parts.items.len },
            ) },
            .{ .label = "", .value = try std.fmt.allocPrint(
                allocator,
                "fee {d} sats",
                .{outcome.result.fee orelse 0},
            ) },
        };
        const screen = zhww.ui_screen.Screen{
            .title = "SIGNED",
            .lines = &lines,
            .qr = .{ .width = matrix.size, .height = matrix.size, .modules = matrix.modules },
            .footer_left = "BACK",
            .footer_right = "NEXT PART",
        };
        screen.render(&fb);
        try writeScreenPng(allocator, io, out_dir, "7-signed.png", pixels, big, width, height, scale);
        stderrPrint("QR: part {d}/{d}, {d} chars, v{d}\n", .{ shown_index, parts.items.len, first_part.len, matrix.version });
    }
}

/// Render a status Notice on the screen and write it as a PNG.
fn renderNotice(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    name: []const u8,
    notice: zhww.app_device.Notice,
    pixels: []u16,
    big: []u16,
    width: usize,
    height: usize,
    scale: usize,
) !void {
    var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, width, height);
    var lines: [8]zhww.ui_screen.Line = undefined;
    var warnings: [4][]const u8 = undefined;
    const screen = zhww.app_device.screenFor(notice, &lines, &warnings);
    screen.render(&fb);
    try writeScreenPng(allocator, io, out_dir, name, pixels, big, width, height, scale);
}

/// Scale the framebuffer and write it to a file as a PNG.
fn writeScreenPng(
    allocator: std.mem.Allocator,
    io: std.Io,
    out_dir: []const u8,
    name: []const u8,
    pixels: []const u16,
    big: []u16,
    width: usize,
    height: usize,
    scale: usize,
) !void {
    const s = if (scale == 0) 1 else scale;
    for (0..height * s) |y| {
        for (0..width * s) |x| {
            big[y * width * s + x] = pixels[(y / s) * width + (x / s)];
        }
    }

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, name });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);

    var buffer: [8192]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try png.writeRgb565(&writer.interface, allocator, big, width * s, height * s);
    try writer.interface.flush();
    stderrPrint("wrote: {s} ({d}x{d})\n", .{ path, width * s, height * s });
}

// ---------------------------------------------------------------- card (FAT32 image)

const file_device = @import("file_device.zig");

/// Work with a FAT32 image file as a stand-in for the microSD card.
///
/// Reproduces the card handoff (docs/08, section 7b) end to end without a device.
fn commandCard(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    io: std.Io,
) !void {
    if (args.len == 0) {
        stderrPrint("usage: zhww card <list|read|write|rm|mv|sign> --image <file>\n", .{});
        return error.Usage;
    }
    const verb = args[0];
    const image_path = try requiredOption(args, "--image");

    const file = std.Io.Dir.cwd().openFile(io, image_path, .{ .mode = .read_write }) catch {
        stderrPrint("cannot open image: {s}\n", .{image_path});
        return error.InvalidArgument;
    };
    defer file.close(io);
    const stat = std.Io.File.stat(file, io) catch {
        stderrPrint("cannot get the image size\n", .{});
        return error.InvalidArgument;
    };

    var device = file_device.FileDevice.init(file, io, stat.size);
    var fs = try zhww.fs_fat32.Fat32.mount(device.device(), allocator);
    defer fs.deinit();

    if (std.mem.eql(u8, verb, "list")) {
        var iterator = try fs.openDir("/");
        var entry: zhww.fs_fat32.Entry = .{};
        while (try iterator.next(&entry)) {
            if (entry.isDot()) continue;
            try stdout.interface.print("{s: <40} {d: >10} bytes{s}\n", .{
                entry.nameSlice(),
                entry.size,
                if (entry.isDirectory()) "  (directory)" else "",
            });
        }
        return;
    }

    if (std.mem.eql(u8, verb, "read")) {
        const name = try requiredOption(args, "--name");
        const data = fs.readFileAlloc(allocator, name, 1024 * 1024) catch {
            stderrPrint("cannot read: {s}\n", .{name});
            return error.InvalidArgument;
        };
        try stdout.interface.writeAll(data);
        try stdout.interface.flush();
        return;
    }

    if (std.mem.eql(u8, verb, "write")) {
        const name = try requiredOption(args, "--name");
        const input = try readAllStdin(allocator);
        try fs.writeFile(name, input);
        stderrPrint("{s}: wrote {d} bytes\n", .{ name, input.len });
        return;
    }

    if (std.mem.eql(u8, verb, "rm")) {
        const name = try requiredOption(args, "--name");
        try fs.deleteFile(name);
        stderrPrint("deleted {s}\n", .{name});
        return;
    }

    if (std.mem.eql(u8, verb, "mv")) {
        const from = try requiredOption(args, "--name");
        const to = try requiredOption(args, "--to");
        if (try fs.exists(to)) try fs.deleteFile(to);
        try fs.rename(from, to);
        stderrPrint("{s} -> {s}\n", .{ from, to });
        return;
    }

    if (std.mem.eql(u8, verb, "sign")) {
        try cardSign(allocator, args, &fs, stdout);
        return;
    }

    stderrPrint("unknown operation: {s}\n", .{verb});
    return error.Usage;
}

/// Run the handoff protocol (docs/08, section 7b).
fn cardSign(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    fs: *zhww.fs_fat32.Fat32,
    stdout: anytype,
) !void {
    _ = stdout;
    const mnemonic = try requiredOption(args, "--mnemonic");
    const passphrase = option(args, "--passphrase") orelse "";
    const in_name = option(args, "--in") orelse "/IN.PSBT";
    const out_name = option(args, "--out") orelse "/OUT.PSBT";
    const tmp_name = option(args, "--tmp") orelse "/OUT.TMP";

    // 1. Read IN.PSBT (accepts either binary or base64)
    const raw = fs.readFileAlloc(allocator, in_name, 64 * 1024) catch {
        stderrPrint("cannot read {s} (64KB limit)\n", .{in_name});
        return error.InvalidArgument;
    };
    stderrPrint("{s}: {d} bytes\n", .{ in_name, raw.len });

    var psbt_bytes: []const u8 = raw;
    if (!std.mem.startsWith(u8, raw, "psbt\xff")) {
        // Parse as base64 (strip newlines and spaces)
        var cleaned = std.ArrayList(u8).empty;
        defer cleaned.deinit(allocator);
        for (raw) |c| {
            if (c == '\n' or c == '\r' or c == ' ' or c == '\t') continue;
            try cleaned.append(allocator, c);
        }
        const decoder = std.base64.standard.Decoder;
        const needed = decoder.calcSizeForSlice(cleaned.items) catch {
            stderrPrint("cannot parse as PSBT\n", .{});
            return error.InvalidArgument;
        };
        const decoded = try allocator.alloc(u8, needed);
        decoder.decode(decoded, cleaned.items) catch {
            stderrPrint("cannot decode the base64 PSBT\n", .{});
            return error.InvalidArgument;
        };
        psbt_bytes = decoded;
        stderrPrint("parsed as base64 ({d} bytes)\n", .{psbt_bytes.len});
    }

    // 2. Parse and sign (reuse the existing path that also verifies after signing)
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const outcome = zhww.btc_sign.signPsbtBytes(allocator, psbt_bytes, keys) catch |err| {
        stderrPrint("cannot sign: {s}\n", .{@errorName(err)});
        return error.InvalidArgument;
    };

    // 3. Write OUT.TMP first, then rename to OUT.PSBT (a power cut leaves no partial result)
    try fs.writeFile(tmp_name, outcome.signed_psbt);
    if (try fs.exists(out_name)) try fs.deleteFile(out_name);
    try fs.rename(tmp_name, out_name);

    // 4. Human-readable log
    const fee_text = if (outcome.result.fee) |fee|
        try std.fmt.allocPrint(allocator, "{d}", .{fee})
    else
        try allocator.dupe(u8, "unknown");
    const log = try std.fmt.allocPrint(
        allocator,
        "zhww sign log\n" ++
            "signed inputs: {d}\n" ++
            "unsigned inputs: {d}\n" ++
            "fee (sats): {s}\n" ++
            "final tx: {s}\n" ++
            "signed psbt bytes: {d}\n",
        .{
            outcome.result.partial_sigs.len,
            outcome.result.unsigned_inputs.len,
            fee_text,
            if (outcome.result.final_tx != null) "yes" else "no",
            outcome.signed_psbt.len,
        },
    );
    try fs.writeFile("/OUT.LOG", log);

    stderrPrint(
        "signed: {d} inputs ({d} unsigned) -> {s} ({d} bytes)\n",
        .{ outcome.result.partial_sigs.len, outcome.result.unsigned_inputs.len, out_name, outcome.signed_psbt.len },
    );
    if (outcome.result.fee) |fee| stderrPrint("fee: {d} sats\n", .{fee});
}

// ---------------------------------------------------------------- EVM display

/// Show an EVM transaction (raw hex) in human-readable form. Does not sign.
fn commandEvmShow(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    _ = args;
    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("pass a raw transaction (hex) on stdin\n", .{});
        return error.Usage;
    }
    const hex_text = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    if (hex_text.len % 2 != 0) {
        stderrPrint("cannot parse as hex\n", .{});
        return error.InvalidArgument;
    }
    const raw = try allocator.alloc(u8, hex_text.len / 2);
    _ = std.fmt.hexToBytes(raw, hex_text) catch {
        stderrPrint("cannot parse as hex\n", .{});
        return error.InvalidArgument;
    };

    const decoded = try zhww.evm_transaction.decode(allocator, raw);

    const kind_name = switch (decoded.kind) {
        .legacy => "legacy (EIP-155)",
        .eip2930 => "EIP-2930 (type 1)",
        .eip1559 => "EIP-1559 (type 2)",
    };
    try stdout.interface.print("type: {s}\n", .{kind_name});
    if (decoded.chain_id) |chain_id| {
        try stdout.interface.print("chain ID: {d}\n", .{chain_id});
    }
    if (decoded.nonce) |nonce| try stdout.interface.print("nonce: {d}\n", .{nonce});

    if (decoded.to) |to| {
        var buffer: [42]u8 = undefined;
        const address = try zhww.evm_address.checksum(&buffer, to);
        try stdout.interface.print("to: {s}\n", .{address});
    } else {
        try stdout.interface.print("to: none (contract creation)\n", .{});
        stderrPrint("warning: this transaction creates a contract\n", .{});
    }

    if (decoded.value) |value| {
        try stdout.interface.print("value: {d} wei", .{value});
        if (value > 0) {
            try stdout.interface.print(" ({d}.{d:0>18} ETH)", .{
                value / 1_000_000_000_000_000_000,
                value % 1_000_000_000_000_000_000,
            });
        }
        try stdout.interface.print("\n", .{});
    }
    if (decoded.gas_limit) |gas_limit| {
        try stdout.interface.print("gas limit: {d}\n", .{gas_limit});
    }
    if (decoded.gas_price) |gas_price| {
        try stdout.interface.print("gas price: {d} wei/gas\n", .{gas_price});
        if (decoded.gas_limit) |gas_limit| {
            try stdout.interface.print("max fee: {d} wei\n", .{gas_price * gas_limit});
        }
    }
    if (decoded.max_fee_per_gas) |max_fee| {
        try stdout.interface.print("max fee per gas: {d} wei/gas\n", .{max_fee});
        if (decoded.max_priority_fee_per_gas) |tip| {
            try stdout.interface.print("max priority fee: {d} wei/gas\n", .{tip});
        }
        if (decoded.gas_limit) |gas_limit| {
            try stdout.interface.print("max fee: {d} wei\n", .{max_fee * gas_limit});
        }
    }

    // data (calldata)
    if (decoded.data.len == 0) {
        try stdout.interface.print("data: none (plain transfer)\n", .{});
    } else if (zhww.evm_abi.selector(decoded.data)) |selector| {
        var selector_hex: [8]u8 = undefined;
        try stdout.interface.print("data: {d} bytes  selector: 0x{s}\n", .{
            decoded.data.len,
            toHex(&selector, &selector_hex),
        });
        if (zhww.evm_abi.knownFunction(selector)) |known| {
            try stdout.interface.print("  function: {s}\n", .{known.signature});
        } else {
            try stdout.interface.print("  function: unknown\n", .{});
            stderrPrint("warning: unknown function. Do not sign without verifying what it does\n", .{});
        }
        try warnDangerousCalldata(selector);
    } else {
        try stdout.interface.print("data: {d} bytes (no selector)\n", .{decoded.data.len});
    }

    try stdout.interface.print("signed: {s}\n", .{if (decoded.signed) "yes" else "no"});
    stderrPrint("this is display only; nothing was signed\n", .{});
}

/// Warn about dangerous operations (unlimited approve, full delegation, permit).
fn warnDangerousCalldata(selector: [4]u8) !void {
    // approve(address,uint256) / increaseAllowance / setApprovalForAll / permit
    const approve = [_]u8{ 0x09, 0x5e, 0xa7, 0xb3 };
    const set_approval_for_all = [_]u8{ 0xa2, 0x2c, 0xb4, 0x65 };
    const permit = [_]u8{ 0xd5, 0x05, 0xac, 0xcf };
    if (std.mem.eql(u8, &selector, &approve)) {
        stderrPrint("caution: approve. Check the amount (an unlimited allowance is dangerous)\n", .{});
    }
    if (std.mem.eql(u8, &selector, &set_approval_for_all)) {
        stderrPrint("warning: setApprovalForAll. This grants control over all your tokens\n", .{});
    }
    if (std.mem.eql(u8, &selector, &permit)) {
        stderrPrint("caution: permit (an off-chain signature that grants approval)\n", .{});
    }
}

// ---------------------------------------------------------------- screen

const png = @import("png.zig");

/// Build the device screen (240x240) and output it as a PNG.
///
/// A command for checking the UI without a device.
/// `--demo` draws a sample; passing a PSBT draws its confirmation screen.
fn commandScreen(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const network = try networkOf(args);
    const screen_width: usize = 240;
    const screen_height: usize = 240;

    const pixels = try allocator.alloc(u16, screen_width * screen_height);
    var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, screen_width, screen_height);

    var title: []const u8 = undefined;
    var lines_buf: [4]zhww.ui_screen.Line = undefined;
    var line_count: usize = 0;
    var warnings_buf: [3][]const u8 = undefined;
    var warning_count: usize = 0;

    const qr_mode = hasFlag(args, "--qr");
    const demo = hasFlag(args, "--demo");
    if (qr_mode) return commandScreenQr(allocator, args, stdout);
    var qr_modules: ?[]u8 = null;
    if (demo) {
        title = "CONFIRM";
        lines_buf[0] = .{ .label = "To", .value = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu" };
        lines_buf[1] = .{ .label = "Amount", .value = "0.00100000 BTC", .kind = .strong };
        lines_buf[2] = .{ .label = "Fee", .value = "1234 sats (0.12%)" };
        line_count = 3;
        warnings_buf[0] = "Check the address on your own screen";
        warning_count = 1;
    } else {
        const input = try readAllStdin(allocator);
        const trimmed = std.mem.trim(u8, input, " \t\r\n");
        if (trimmed.len == 0) {
            stderrPrint("pass a PSBT (base64), or specify --demo\n", .{});
            return error.Usage;
        }
        const decoder = std.base64.standard.Decoder;
        const raw = try allocator.alloc(u8, try decoder.calcSizeForSlice(trimmed));
        try decoder.decode(raw, trimmed);
        const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);

        // Find the recipient (the first output that is not change)
        const change = try changeOutputs(allocator, psbt, args);
        title = "CONFIRM";
        var to_address: []const u8 = "(unknown script)";
        var amount: u64 = 0;
        var found = false;
        for (psbt.unsigned_tx.outputs, 0..) |output, i| {
            var is_change = false;
            for (change) |index| {
                if (index == i) is_change = true;
            }
            if (is_change) continue;
            var buffer: [90]u8 = undefined;
            if (try zhww.btc_address.fromScriptPubKey(&buffer, output.script_pubkey, network)) |address| {
                to_address = try allocator.dupe(u8, address);
            }
            amount = output.value;
            found = true;
            break;
        }
        if (!found) {
            stderrPrint("no recipient output found\n", .{});
            return error.InvalidArgument;
        }

        lines_buf[0] = .{ .label = "To", .value = to_address };
        lines_buf[1] = .{ .label = "Amount", .value = try std.fmt.allocPrint(allocator, "{d} sats", .{amount}) , .kind = .strong };

        // Fee
        var total_input: u64 = 0;
        var unknown_value = false;
        for (0..psbt.inputs.len) |i| {
            const info = try inputInfo(allocator, psbt, i);
            if (info) |utxo| {
                total_input += utxo.value;
            } else {
                unknown_value = true;
            }
        }
        var total_output: u64 = 0;
        for (psbt.unsigned_tx.outputs) |output| total_output += output.value;

        if (unknown_value) {
            lines_buf[2] = .{ .label = "Fee", .value = "unknown" };
            warnings_buf[warning_count] = "Input amount unknown: cannot verify the fee";
            warning_count += 1;
            line_count = 3;
        } else if (total_input >= total_output) {
            const fee = total_input - total_output;
            lines_buf[2] = .{
                .label = "Fee",
                .value = try std.fmt.allocPrint(allocator, "{d} sats", .{fee}),
            };
            line_count = 3;
            if (fee * 100 > total_input) {
                warnings_buf[warning_count] = "Fee is more than 1% of the input";
                warning_count += 1;
            }
        } else {
            line_count = 2;
            warnings_buf[warning_count] = "Outputs exceed inputs";
            warning_count += 1;
        }
        if (change.len == 0 and psbt.unsigned_tx.outputs.len > 1) {
            warnings_buf[warning_count] = "Change could not be identified";
            warning_count += 1;
        }
    }

    // QR (a checkerboard in the demo; the real UR goes here once the encoder is wired in)
    var qr_bitmap: ?zhww.ui_screen.Bitmap = null;
    if (demo) {
        const size: usize = 25;
        qr_modules = try allocator.alloc(u8, size * size);
        for (0..size) |y| {
            for (0..size) |x| {
                const finder = (x < 7 and y < 7) or (x >= size - 7 and y < 7) or (x < 7 and y >= size - 7);
                const on = finder or (x + y) % 3 == 0;
                qr_modules.?[y * size + x] = if (on) 1 else 0;
            }
        }
        qr_bitmap = .{ .width = size, .height = size, .modules = qr_modules.? };
    }

    const screen = zhww.ui_screen.Screen{
        .title = title,
        .lines = lines_buf[0..line_count],
        .warnings = warnings_buf[0..warning_count],
        .qr = qr_bitmap,
        .footer_left = "OK",
        .footer_right = "CANCEL",
    };
    screen.render(&fb);

    // Scale up and output as a PNG (default is 1:1)
    const scale_text = option(args, "--scale") orelse "1";
    const scale = try std.fmt.parseInt(usize, scale_text, 10);
    if (scale <= 1) {
        try png.writeRgb565(&stdout.interface, allocator, pixels, screen_width, screen_height);
    } else {
        const big = try allocator.alloc(u16, screen_width * scale * screen_height * scale);
        for (0..screen_height * scale) |y| {
            for (0..screen_width * scale) |x| {
                big[y * screen_width * scale + x] =
                    pixels[(y / scale) * screen_width + (x / scale)];
            }
        }
        try png.writeRgb565(&stdout.interface, allocator, big, screen_width * scale, screen_height * scale);
    }
    try stdout.interface.flush();
    stderrPrint("wrote screen PNG ({d}x{d})\n", .{ screen_width * scale, screen_height * scale });
}

/// Draw a screen that shows a string (such as one UR part) as a QR code.
fn commandScreenQr(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const screen_width: usize = 240;
    const screen_height: usize = 240;

    const input = try readAllStdin(allocator);
    const text = std.mem.trim(u8, input, " \t\r\n");
    if (text.len == 0) {
        stderrPrint("pass the text to show as a QR code on stdin\n", .{});
        return error.Usage;
    }

    const ec_text = option(args, "--ec") orelse "m";
    const ec: zhww.ui_qr.EcLevel = switch (ec_text[0]) {
        'l', 'L' => .l,
        'm', 'M' => .m,
        'q', 'Q' => .q,
        else => .h,
    };

    var matrix = try zhww.ui_qr.encode(allocator, text, ec);

    const pixels = try allocator.alloc(u16, screen_width * screen_height);
    var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, screen_width, screen_height);

    const caption = try std.fmt.allocPrint(
        allocator,
        "{d} chars  v{d}  EC {s}",
        .{ text.len, matrix.version, ec_text },
    );
    const lines = [_]zhww.ui_screen.Line{
        .{ .label = "SCAN", .value = caption },
    };
    const screen = zhww.ui_screen.Screen{
        .title = "SHOW TO PHONE",
        .lines = &lines,
        .qr = .{ .width = matrix.size, .height = matrix.size, .modules = matrix.modules },
        .footer_left = "BACK",
        .footer_right = "NEXT",
    };
    screen.render(&fb);

    const scale_text = option(args, "--scale") orelse "1";
    const scale = try std.fmt.parseInt(usize, scale_text, 10);
    if (scale <= 1) {
        try png.writeRgb565(&stdout.interface, allocator, pixels, screen_width, screen_height);
    } else {
        const big = try allocator.alloc(u16, screen_width * scale * screen_height * scale);
        for (0..screen_height * scale) |y| {
            for (0..screen_width * scale) |x| {
                big[y * screen_width * scale + x] = pixels[(y / scale) * screen_width + (x / scale)];
            }
        }
        try png.writeRgb565(&stdout.interface, allocator, big, screen_width * scale, screen_height * scale);
    }
    try stdout.interface.flush();
    stderrPrint(
        "wrote QR (v{d}, {d}x{d} modules)\n",
        .{ matrix.version, matrix.size, matrix.size },
    );
    matrix.deinit(allocator);
}

// ---------------------------------------------------------------- show

/// Show the contents of a PSBT in human-readable form.
///
/// Lets you check what you are about to sign, even without the device screen.
/// It does not sign (display only).
fn commandShow(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const network = try networkOf(args);

    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("pass a PSBT (base64) on stdin\n", .{});
        return error.Usage;
    }

    const decoder = std.base64.standard.Decoder;
    const raw = try allocator.alloc(u8, try decoder.calcSizeForSlice(trimmed));
    try decoder.decode(raw, trimmed);

    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);
    const tx = psbt.unsigned_tx;

    // --- Inputs ---
    var total_input: u64 = 0;
    var unknown_value = false;
    try stdout.interface.print("inputs:\n", .{});
    for (tx.inputs, 0..) |_, i| {
        const info = try inputInfo(allocator, psbt, i);
        if (info) |utxo| {
            total_input += utxo.value;
            try stdout.interface.print("  {d}: {d} sats", .{ i, utxo.value });
            var buffer: [90]u8 = undefined;
            if (try zhww.btc_address.fromScriptPubKey(&buffer, utxo.script_pubkey, network)) |address| {
                try stdout.interface.print("  {s}", .{address});
            } else {
                try stdout.interface.print("  (unsupported script)", .{});
            }
        } else {
            unknown_value = true;
            try stdout.interface.print("  {d}: amount unknown (no UTXO info)", .{i});
        }
        if (psbt.inputs[i].partial_sigs.len > 0) {
            try stdout.interface.print("  [signed]", .{});
        }
        try stdout.interface.print("\n", .{});
    }

    // --- Outputs ---
    const change = try changeOutputs(allocator, psbt, args);
    var total_output: u64 = 0;
    try stdout.interface.print("outputs:\n", .{});
    for (tx.outputs, 0..) |output, i| {
        total_output += output.value;
        try stdout.interface.print("  {d}: {d} sats", .{ i, output.value });
        var buffer: [90]u8 = undefined;
        if (try zhww.btc_address.fromScriptPubKey(&buffer, output.script_pubkey, network)) |address| {
            try stdout.interface.print("  {s}", .{address});
        } else {
            try stdout.interface.print("  (unsupported script)", .{});
        }
        var is_change = false;
        for (change) |index| {
            if (index == i) is_change = true;
        }
        try stdout.interface.print("  {s}\n", .{if (is_change) "change" else "payment"});
    }
    try stdout.interface.print("output total: {d} sats\n", .{total_output});

    // --- Fee and warnings ---
    if (unknown_value) {
        try stdout.interface.print("fee: cannot compute (input amount unknown)\n", .{});
        stderrPrint("warning: cannot verify the fee because an input amount is unknown\n", .{});
    } else if (total_input >= total_output) {
        const fee = total_input - total_output;
        try stdout.interface.print(
            "fee: {d} sats ({d}.{d:0>2}%)\n",
            .{ fee, fee * 100 / total_input, (fee * 10000 / total_input) % 100 },
        );
        if (fee * 100 > total_input) {
            stderrPrint("warning: fee is more than 1% of the total input\n", .{});
        }
    } else {
        stderrPrint("warning: the output total exceeds the input total\n", .{});
    }

    if (change.len == 0 and psbt.outputs.len > 1) {
        stderrPrint("note: could not identify change (pass --mnemonic to detect it)\n", .{});
    }
    stderrPrint("this is display only; nothing was signed\n", .{});
}

/// Resolve UTXO info (amount and scriptPubKey) for an input. Null if unknown.
fn inputInfo(
    allocator: std.mem.Allocator,
    psbt: zhww.btc_psbt.Psbt,
    index: usize,
) !?zhww.btc_transaction.TxOut {
    if (psbt.inputs[index].witness_utxo) |utxo| return utxo;
    if (psbt.inputs[index].non_witness_utxo) |prev_tx| {
        const prevout = psbt.unsigned_tx.inputs[index].prevout;
        const txid = try prev_tx.txid(allocator);
        if (!std.mem.eql(u8, &txid, &prevout.txid)) return null;
        for (prev_tx.outputs, 0..) |output, vout| {
            if (vout == prevout.vout) return output;
        }
    }
    return null;
}

/// Detect the change output when a mnemonic is given.
fn changeOutputs(
    allocator: std.mem.Allocator,
    psbt: zhww.btc_psbt.Psbt,
    args: []const []const u8,
) ![]const usize {
    const mnemonic = option(args, "--mnemonic") orelse return &.{};
    const passphrase = option(args, "--passphrase") orelse "";
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const result = try zhww.btc_sign.sign(allocator, psbt, keys);
    return result.change_outputs;
}

fn toHex(bytes: []const u8, out: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 15];
    }
    return out[0 .. bytes.len * 2];
}

// ---------------------------------------------------------------- UR (QR transfer)

/// Convert a PSBT (base64) to UR and print one part per line.
///
/// Lets you inspect the generated UR strings without a screen or camera.
fn commandUr(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const fragment_text = option(args, "--fragment") orelse "40";
    const max_fragment = std.fmt.parseInt(usize, fragment_text, 10) catch {
        stderrPrint("invalid value for --fragment: {s}\n", .{fragment_text});
        return error.InvalidArgument;
    };
    const ur_type = option(args, "--type") orelse zhww.ur.type_crypto_psbt;

    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("pass a PSBT (base64) on stdin\n", .{});
        return error.Usage;
    }

    const decoder = std.base64.standard.Decoder;
    const raw_len = decoder.calcSizeForSlice(trimmed) catch {
        stderrPrint("cannot decode the base64 PSBT\n", .{});
        return error.InvalidArgument;
    };
    const raw = try allocator.alloc(u8, raw_len);
    try decoder.decode(raw, trimmed);

    // BC-UR `crypto-psbt` / `bytes` travel as a CBOR byte string.
    // Putting raw bytes in directly makes standards-compliant decoders reject it.
    const cbor_buffer = try allocator.alloc(u8, zhww.cbor.bytesLength(raw.len));
    const message = try zhww.cbor.writeBytes(cbor_buffer, raw);

    const scratch = try allocator.alloc(u8, zhww.ur.maxPartCborLength(max_fragment));
    var encoder = try zhww.ur.Encoder.init(
        ur_type,
        message,
        max_fragment,
        zhww.ur.default_min_fragment_len,
        scratch,
    );

    var output_buffer: [1024]u8 = undefined;
    var part_count: usize = 0;
    while (try encoder.next(&output_buffer, .lower)) |part| {
        try stdout.interface.print("{s}\n", .{part});
        part_count += 1;
    }
    stderrPrint("{s}: {d} parts ({d} bytes)\n", .{ ur_type, part_count, raw.len });
}

/// Read UR parts (one per line) and convert them back to a PSBT (base64).
fn commandUrDecode(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    _ = args;
    const input = try readAllStdin(allocator);

    var lines = std.mem.tokenizeAny(u8, input, "\r\n");
    const first = lines.next() orelse {
        stderrPrint("pass the UR string on stdin\n", .{});
        return error.Usage;
    };

    var message: []const u8 = undefined;
    const uri = try zhww.ur.parse(first);

    if (uri.seq == null) {
        // Single part
        const buffer = try allocator.alloc(u8, 64 * 1024);
        message = try zhww.ur.decodeSingle(buffer, first, null);
    } else {
        // Multipart: the first part gives the size, then collect the rest
        var probe_buffer: [4096]u8 = undefined;
        const probe = try zhww.ur.decodePartUr(&probe_buffer, first);

        const seq_len = probe.part.seq_len;
        const message_len = probe.part.message_len;
        const fragment_len = probe.part.data.len;

        const bits = try allocator.alloc(u8, (seq_len + 7) / 8);
        const buffer = try allocator.alloc(u8, message_len);
        const part_buffer = try allocator.alloc(u8, zhww.ur.maxPartCborLength(fragment_len));

        var decoder = zhww.ur.Decoder.init(bits, buffer, part_buffer);
        _ = try decoder.receive(first);
        while (lines.next()) |line| {
            const status = try decoder.receive(line);
            if (status == .complete) break;
        }

        stderrPrint("received {d}/{d} parts\n", .{
            decoder.receivedFragmentCount(),
            decoder.expectedFragmentCount(),
        });
        message = decoder.result() orelse {
            stderrPrint("not all parts were received\n", .{});
            return error.InvalidArgument;
        };
    }

    const encoder = std.base64.standard.Encoder;
    // Extract the payload (a PSBT, etc.) from the CBOR byte string
    var reader = zhww.cbor.Reader.init(message);
    const payload = reader.readBytes() catch {
        stderrPrint("cannot parse the UR payload as CBOR\n", .{});
        return error.InvalidArgument;
    };
    const encoded = try allocator.alloc(u8, encoder.calcSize(payload.len));
    _ = encoder.encode(encoded, payload);
    try stdout.interface.print("{s}\n", .{encoded});
}
