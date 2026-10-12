//! zhww 開発用 CLI。
//!
//! 実機（Raspberry Pi）に画面 UI を用意する前でも、ターミナルから
//! アドレス生成・PSBT 署名・ダイス検証ができるようにするための道具。
//!
//! **出力の方針**: 結果は標準出力、診断（手数料・警告など）は標準エラー。
//! これにより `zhww sign < psbt.txt > signed.txt` のように繋げられる。
//!
//! Zig 0.17 では標準出力が `std.Io` 経由になり、プロセスの引数は
//! `pub fn main(init: std.process.Init.Minimal)` で受け取る。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("zhww");

const usage =
    \\使い方: zhww <コマンド> [オプション]
    \\
    \\コマンド:
    \\  address    アドレスを表示する
    \\  sign       PSBT（base64）に署名する。標準入力から読む
    \\  mnemonic   ダイスの出目から mnemonic を作る（記録の検証用）
    \\  version    バージョンを表示する
    \\
    \\address のオプション:
    \\  --mnemonic "<12/24 語>"    鍵の元にする mnemonic（必須）
    \\  --passphrase "<文字列>"    パスフレーズ（任意）
    \\  --path "m/84'/0'/0'/0/0"   派生パス（既定: m/84'/0'/0'/0/0）
    \\  --network mainnet|testnet|signet|regtest （既定: mainnet）
    \\  --kind p2wpkh|p2pkh|p2sh-p2wpkh|p2tr （既定: p2wpkh）
    \\
    \\sign のオプション:
    \\  --mnemonic "..."           署名に使う mnemonic（必須）
    \\  --passphrase "..."         パスフレーズ（任意）
    \\
    \\mnemonic のオプション:
    \\  --dice "123456..."         ダイスの出目（1〜6）
    \\  --words 12|24              語数（既定: 24）
    \\  --camera <hex>             カメラ等の追加エントロピー（任意）
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

    run(init, &stdout) catch |err| {
        switch (err) {
            error.Usage => {
                stderrPrint("{s}", .{usage});
            },
            else => {
                stderrPrint("エラー: {s}\n", .{@errorName(err)});
            },
        }
        stdout.interface.flush() catch {};
        std.process.exit(1);
    };
    // 出力はバッファリングされるため、必ず吐き出す
    stdout.interface.flush() catch {};
}

fn stderrPrint(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

fn run(init: std.process.Init.Minimal, stdout: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.ArrayList([]const u8).empty;
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next(); // argv[0] は読み飛ばす
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
    if (std.mem.eql(u8, command, "mnemonic")) {
        try commandMnemonic(allocator, args.items[1..], stdout);
        return;
    }
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help")) {
        return error.Usage;
    }
    return error.Usage;
}

// ---------------------------------------------------------------- 引数

fn option(args: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], name)) return args[i + 1];
    }
    return null;
}

fn requiredOption(args: []const []const u8, name: []const u8) ![]const u8 {
    return option(args, name) orelse {
        stderrPrint("{s} が必要です\n", .{name});
        return error.Usage;
    };
}

fn networkOf(args: []const []const u8) !zhww.btc_address.Network {
    const name = option(args, "--network") orelse return .mainnet;
    if (std.mem.eql(u8, name, "mainnet")) return .mainnet;
    if (std.mem.eql(u8, name, "testnet")) return .testnet;
    if (std.mem.eql(u8, name, "signet")) return .signet;
    if (std.mem.eql(u8, name, "regtest")) return .regtest;
    stderrPrint("--network の値が不正です: {s}\n", .{name});
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
        stderrPrint("--kind の値が不正です: {s}\n", .{kind});
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

    // 標準入力から base64 の PSBT を読む
    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("PSBT（base64）を標準入力から渡してください\n", .{});
        return error.Usage;
    }

    const decoder = std.base64.standard.Decoder;
    const raw_len = decoder.calcSizeForSlice(trimmed) catch {
        stderrPrint("PSBT の base64 を解釈できません\n", .{});
        return error.InvalidArgument;
    };
    const raw = try allocator.alloc(u8, raw_len);
    try decoder.decode(raw, trimmed);

    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, passphrase);
    const outcome = try zhww.btc_sign.signPsbtBytes(allocator, raw, keys);

    // 診断は標準エラーへ
    stderrPrint(
        "署名した入力: {d} / 署名できなかった入力: {d}\n",
        .{ outcome.result.partial_sigs.len, outcome.result.unsigned_inputs.len },
    );
    if (outcome.result.total_input) |total| stderrPrint("入力合計: {d} sats\n", .{total});
    if (outcome.result.fee) |fee| {
        stderrPrint("手数料: {d} sats\n", .{fee});
    } else {
        stderrPrint("手数料: 不明（入力額が揃っていないため計算しない）\n", .{});
    }
    if (outcome.result.change_outputs.len > 0) {
        stderrPrint("お釣り: 出力 {d} 番\n", .{outcome.result.change_outputs[0]});
    }
    for (outcome.result.unsigned_inputs) |index| {
        stderrPrint("警告: 入力 {d} は署名できませんでした\n", .{index});
    }

    // 結果は標準出力へ
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
        stderrPrint("--words の値が不正です: {s}\n", .{words_text});
        return error.InvalidArgument;
    };

    var dice: zhww.entropy.Dice = .{};
    dice.rollString(dice_text) catch {
        stderrPrint("--dice には 1〜6 の数字だけを並べてください\n", .{});
        return error.InvalidArgument;
    };

    var camera_bytes: ?[]u8 = null;
    if (option(args, "--camera")) |camera_hex| {
        const cleaned = if (std.mem.startsWith(u8, camera_hex, "0x")) camera_hex[2..] else camera_hex;
        if (cleaned.len % 2 != 0) {
            stderrPrint("--camera は 16 進数で指定してください\n", .{});
            return error.InvalidArgument;
        }
        const bytes = try allocator.alloc(u8, cleaned.len / 2);
        _ = std.fmt.hexToBytes(bytes, cleaned) catch {
            stderrPrint("--camera は 16 進数で指定してください\n", .{});
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

    // 記録の検証用に、出目の個数と必要な個数も出す（診断は標準エラー）
    const needed = if (word_count == 12)
        zhww.entropy.rolls_for_12_words
    else
        zhww.entropy.rolls_for_24_words;
    if (dice.len < needed) {
        stderrPrint("警告: {d} 語には {d} 回の出目が必要です（{d} 回しかありません）\n", .{
            word_count,
            needed,
            dice.len,
        });
    }

    try stdout.interface.print("{s}\n", .{text});
}

fn toHex(bytes: []const u8, out: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 15];
    }
    return out[0 .. bytes.len * 2];
}
