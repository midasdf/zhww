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
    \\  show       PSBT の中身を人間可読で表示する（画面の代わり）
    \\  sign       PSBT（base64）に署名する。標準入力から読む
    \\  mnemonic   ダイスの出目から mnemonic を作る（記録の検証用）
    \\  ur         PSBT（base64）を UR（QR 転送用）に変換する
    \\  ur-decode  UR のパートを読み取って PSBT（base64）に戻す
    \\  version    バージョンを表示する
    \\
    \\address のオプション:
    \\  --mnemonic "<12/24 語>"    鍵の元にする mnemonic（必須）
    \\  --passphrase "<文字列>"    パスフレーズ（任意）
    \\  --path "m/84'/0'/0'/0/0"   派生パス（既定: m/84'/0'/0'/0/0）
    \\  --network mainnet|testnet|signet|regtest （既定: mainnet）
    \\  --kind p2wpkh|p2pkh|p2sh-p2wpkh|p2tr （既定: p2wpkh）
    \\
    \\show のオプション:
    \\  --network mainnet|testnet|signet|regtest （アドレス表示用。既定: mainnet）
    \\  --mnemonic "..."         渡すとお釣りを判定する（任意）
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
    \\ur / ur-decode のオプション:
    \\  --fragment <n>             QR 1 枚あたりの最大バイト数（既定: 40）
    \\  --type <型名>              UR の型（既定: crypto-psbt）
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

// ---------------------------------------------------------------- show（表示）

/// PSBT の中身を人間可読で表示する。
///
/// 実機の画面が無くても「何に署名しようとしているか」を確認できるようにする。
/// 署名は行わない（表示だけ）。
fn commandShow(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const network = try networkOf(args);

    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("PSBT（base64）を標準入力から渡してください\n", .{});
        return error.Usage;
    }

    const decoder = std.base64.standard.Decoder;
    const raw = try allocator.alloc(u8, try decoder.calcSizeForSlice(trimmed));
    try decoder.decode(raw, trimmed);

    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);
    const tx = psbt.unsigned_tx;

    // --- 入力 ---
    var total_input: u64 = 0;
    var unknown_value = false;
    try stdout.interface.print("入力:\n", .{});
    for (tx.inputs, 0..) |_, i| {
        const info = try inputInfo(allocator, psbt, i);
        if (info) |utxo| {
            total_input += utxo.value;
            try stdout.interface.print("  {d}: {d} sats", .{ i, utxo.value });
            var buffer: [90]u8 = undefined;
            if (try zhww.btc_address.fromScriptPubKey(&buffer, utxo.script_pubkey, network)) |address| {
                try stdout.interface.print("  {s}", .{address});
            } else {
                try stdout.interface.print("  (未対応の script)", .{});
            }
        } else {
            unknown_value = true;
            try stdout.interface.print("  {d}: 金額不明（UTXO 情報がありません）", .{i});
        }
        if (psbt.inputs[i].partial_sigs.len > 0) {
            try stdout.interface.print("  [署名あり]", .{});
        }
        try stdout.interface.print("\n", .{});
    }

    // --- 出力 ---
    const change = try changeOutputs(allocator, psbt, args);
    var total_output: u64 = 0;
    try stdout.interface.print("出力:\n", .{});
    for (tx.outputs, 0..) |output, i| {
        total_output += output.value;
        try stdout.interface.print("  {d}: {d} sats", .{ i, output.value });
        var buffer: [90]u8 = undefined;
        if (try zhww.btc_address.fromScriptPubKey(&buffer, output.script_pubkey, network)) |address| {
            try stdout.interface.print("  {s}", .{address});
        } else {
            try stdout.interface.print("  (未対応の script)", .{});
        }
        var is_change = false;
        for (change) |index| {
            if (index == i) is_change = true;
        }
        try stdout.interface.print("  {s}\n", .{if (is_change) "お釣り" else "送金"});
    }
    try stdout.interface.print("出力合計: {d} sats\n", .{total_output});

    // --- 手数料と警告 ---
    if (unknown_value) {
        try stdout.interface.print("手数料: 計算できません（入力額が不明）\n", .{});
        stderrPrint("警告: 入力額が分からないため手数料を確認できません\n", .{});
    } else if (total_input >= total_output) {
        const fee = total_input - total_output;
        try stdout.interface.print(
            "手数料: {d} sats ({d}.{d:0>2}%)\n",
            .{ fee, fee * 100 / total_input, (fee * 10000 / total_input) % 100 },
        );
        if (fee * 100 > total_input) {
            stderrPrint("警告: 手数料が入力合計の 1% を超えています\n", .{});
        }
    } else {
        stderrPrint("警告: 出力合計が入力合計を超えています\n", .{});
    }

    if (change.len == 0 and psbt.outputs.len > 1) {
        stderrPrint("注意: お釣りを判定できませんでした（--mnemonic を渡すと判定します）\n", .{});
    }
    stderrPrint("これは表示のみで、署名は行っていません\n", .{});
}

/// 入力の UTXO 情報（金額と scriptPubKey）を解決する。分からなければ null。
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

/// mnemonic が渡されていればお釣りを判定する。
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

// ---------------------------------------------------------------- UR（QR 転送）

/// PSBT（base64）を UR に変換し、1 行 1 パートで出力する。
///
/// 画面とカメラが無くても、生成される UR 文字列を目で確認できる。
fn commandUr(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    const fragment_text = option(args, "--fragment") orelse "40";
    const max_fragment = std.fmt.parseInt(usize, fragment_text, 10) catch {
        stderrPrint("--fragment の値が不正です: {s}\n", .{fragment_text});
        return error.InvalidArgument;
    };
    const ur_type = option(args, "--type") orelse zhww.ur.type_crypto_psbt;

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

    // BC-UR の `crypto-psbt` / `bytes` は CBOR のバイト文字列として運ぶ。
    // 生のバイト列をそのまま入れると、規格に沿った復号器が拒否する。
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
    stderrPrint("{s}: {d} パート（{d} バイト）\n", .{ ur_type, part_count, raw.len });
}

/// UR のパート（1 行 1 つ）を読み取って PSBT（base64）に戻す。
fn commandUrDecode(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    _ = args;
    const input = try readAllStdin(allocator);

    var lines = std.mem.tokenizeAny(u8, input, "\r\n");
    const first = lines.next() orelse {
        stderrPrint("UR の文字列を標準入力から渡してください\n", .{});
        return error.Usage;
    };

    var message: []const u8 = undefined;
    const uri = try zhww.ur.parse(first);

    if (uri.seq == null) {
        // 単一パート
        const buffer = try allocator.alloc(u8, 64 * 1024);
        message = try zhww.ur.decodeSingle(buffer, first, null);
    } else {
        // マルチパート: 最初のパートから大きさを決めてから溜める
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

        stderrPrint("{d}/{d} パート受信\n", .{
            decoder.receivedFragmentCount(),
            decoder.expectedFragmentCount(),
        });
        message = decoder.result() orelse {
            stderrPrint("パートが揃っていません\n", .{});
            return error.InvalidArgument;
        };
    }

    const encoder = std.base64.standard.Encoder;
    // CBOR のバイト文字列から中身（PSBT など）を取り出す
    var reader = zhww.cbor.Reader.init(message);
    const payload = reader.readBytes() catch {
        stderrPrint("UR の中身を CBOR として解釈できません\n", .{});
        return error.InvalidArgument;
    };
    const encoded = try allocator.alloc(u8, encoder.calcSize(payload.len));
    _ = encoder.encode(encoded, payload);
    try stdout.interface.print("{s}\n", .{encoded});
}
