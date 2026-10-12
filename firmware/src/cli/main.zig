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
    \\  evm-show   署名済み/未署名の EVM トランザクションを表示する（raw hex）
    \\  evm-sign   EVM のトランザクション（JSON）に署名する
    \\  screen     実機の画面（240×240）を PNG で出力する（PC での確認用）
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
    \\evm-show のオプション:
    \\  入力は raw トランザクションの 16 進数（0x の有無は問わない）
    \\
    \\evm-sign のオプション:
    \\  --mnemonic "..."        署名に使う mnemonic（必須。EVM は 44h/60h/0h/0/0 を使う）
    \\  --passphrase "..."      パスフレーズ（任意）
    \\  入力（JSON）: chainId / nonce / to / value / gasLimit / gasPrice、
    \\                 または maxFeePerGas と maxPriorityFeePerGas（EIP-1559）
    \\
    \\screen のオプション:
    \\  --demo                    サンプルの確認画面を出す（入力不要）
    \\  --qr                      標準入力の文字列を QR として表示する（UR の 1 パートなど）
    \\  --network mainnet|testnet|signet|regtest （アドレス表示用。既定: mainnet）
    \\  --mnemonic "..."          渡すとお釣りを判定する（任意）
    \\  --scale <n>               1 ドットを n 倍で出力する（既定: 1）
    \\  入力に PSBT（base64）を渡すと、その確認画面を描く
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
    if (std.mem.eql(u8, command, "evm-show")) {
        try commandEvmShow(allocator, args.items[1..], stdout);
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

// ---------------------------------------------------------------- EVM

/// EVM のトランザクション（JSON）に署名して raw tx を出力する。
///
/// 対応: EIP-155（legacy）と EIP-1559（type 2）。`maxFeePerGas` があれば EIP-1559 とみなす。
/// 鍵は `m/44'/60'/0'/0/0`（EVM の標準的な派生パス）。
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
        stderrPrint("トランザクションの JSON を標準入力から渡してください\n", .{});
        return error.Usage;
    }

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        trimmed,
        .{ .parse_numbers = false },
    ) catch {
        stderrPrint("JSON を解釈できません\n", .{});
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

    // 鍵（EVM は m/44'/60'/0'/0/0）
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
        stderrPrint("種別: EIP-1559（type 2）\n", .{});
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
        stderrPrint("種別: legacy（EIP-155）\n", .{});
    }

    // 送信元アドレスも表示する（確認用）
    const address_buffer = try allocator.alloc(u8, 42);
    const signer = try zhww.evm_address.fromPublicKey(
        address_buffer,
        try zhww.secp256k1.pubKeyUncompressed(priv),
    );
    stderrPrint("送信元: {s}\n", .{signer});

    const hex = try allocator.alloc(u8, signed.len * 2);
    try stdout.interface.print("{s}\n", .{toHex(signed, hex)});
}

fn jsonU256(root: std.json.ObjectMap, name: []const u8) !u256 {
    const value = root.get(name) orelse {
        stderrPrint("{s} がありません\n", .{name});
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

// ---------------------------------------------------------------- EVM 表示

/// EVM のトランザクション（raw hex）を人間可読で表示する。署名は行わない。
fn commandEvmShow(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
) !void {
    _ = args;
    const input = try readAllStdin(allocator);
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        stderrPrint("raw トランザクション（16 進数）を標準入力から渡してください\n", .{});
        return error.Usage;
    }
    const hex_text = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    if (hex_text.len % 2 != 0) {
        stderrPrint("16 進数として解釈できません\n", .{});
        return error.InvalidArgument;
    }
    const raw = try allocator.alloc(u8, hex_text.len / 2);
    _ = std.fmt.hexToBytes(raw, hex_text) catch {
        stderrPrint("16 進数として解釈できません\n", .{});
        return error.InvalidArgument;
    };

    const decoded = try zhww.evm_transaction.decode(allocator, raw);

    const kind_name = switch (decoded.kind) {
        .legacy => "legacy（EIP-155）",
        .eip2930 => "EIP-2930（type 1）",
        .eip1559 => "EIP-1559（type 2）",
    };
    try stdout.interface.print("種別: {s}\n", .{kind_name});
    if (decoded.chain_id) |chain_id| {
        try stdout.interface.print("チェーン ID: {d}\n", .{chain_id});
    }
    if (decoded.nonce) |nonce| try stdout.interface.print("nonce: {d}\n", .{nonce});

    if (decoded.to) |to| {
        var buffer: [42]u8 = undefined;
        const address = try zhww.evm_address.checksum(&buffer, to);
        try stdout.interface.print("送金先: {s}\n", .{address});
    } else {
        try stdout.interface.print("送金先: なし（コントラクト作成）\n", .{});
        stderrPrint("警告: コントラクト作成のトランザクションです\n", .{});
    }

    if (decoded.value) |value| {
        try stdout.interface.print("金額: {d} wei", .{value});
        if (value > 0) {
            try stdout.interface.print(" ({d}.{d:0>18} ETH)", .{
                value / 1_000_000_000_000_000_000,
                value % 1_000_000_000_000_000_000,
            });
        }
        try stdout.interface.print("\n", .{});
    }
    if (decoded.gas_limit) |gas_limit| {
        try stdout.interface.print("gas 上限: {d}\n", .{gas_limit});
    }
    if (decoded.gas_price) |gas_price| {
        try stdout.interface.print("gas 価格: {d} wei/gas\n", .{gas_price});
        if (decoded.gas_limit) |gas_limit| {
            try stdout.interface.print("最大手数料: {d} wei\n", .{gas_price * gas_limit});
        }
    }
    if (decoded.max_fee_per_gas) |max_fee| {
        try stdout.interface.print("手数料上限: {d} wei/gas\n", .{max_fee});
        if (decoded.max_priority_fee_per_gas) |tip| {
            try stdout.interface.print("優先手数料: {d} wei/gas\n", .{tip});
        }
        if (decoded.gas_limit) |gas_limit| {
            try stdout.interface.print("最大手数料: {d} wei\n", .{max_fee * gas_limit});
        }
    }

    // data（calldata）
    if (decoded.data.len == 0) {
        try stdout.interface.print("data: なし（送金）\n", .{});
    } else if (zhww.evm_abi.selector(decoded.data)) |selector| {
        var selector_hex: [8]u8 = undefined;
        try stdout.interface.print("data: {d} バイト  セレクタ: 0x{s}\n", .{
            decoded.data.len,
            toHex(&selector, &selector_hex),
        });
        if (zhww.evm_abi.knownFunction(selector)) |known| {
            try stdout.interface.print("  関数: {s}\n", .{known.signature});
        } else {
            try stdout.interface.print("  関数: 不明\n", .{});
            stderrPrint("警告: 知らない関数です。内容を確認できないまま署名しないでください\n", .{});
        }
        try warnDangerousCalldata(selector);
    } else {
        try stdout.interface.print("data: {d} バイト（セレクタなし）\n", .{decoded.data.len});
    }

    try stdout.interface.print("署名: {s}\n", .{if (decoded.signed) "あり" else "なし"});
    stderrPrint("これは表示のみで、署名は行っていません\n", .{});
}

/// 危険な操作（無制限 approve・全権委譲・permit）を警告する。
fn warnDangerousCalldata(selector: [4]u8) !void {
    // approve(address,uint256) / increaseAllowance / setApprovalForAll / permit
    const approve = [_]u8{ 0x09, 0x5e, 0xa7, 0xb3 };
    const set_approval_for_all = [_]u8{ 0xa2, 0x2c, 0xb4, 0x65 };
    const permit = [_]u8{ 0xd5, 0x05, 0xac, 0xcf };
    if (std.mem.eql(u8, &selector, &approve)) {
        stderrPrint("注意: approve です。金額を確認してください（無制限の許可は危険）\n", .{});
    }
    if (std.mem.eql(u8, &selector, &set_approval_for_all)) {
        stderrPrint("警告: setApprovalForAll です。全トークンの操作権を委ねます\n", .{});
    }
    if (std.mem.eql(u8, &selector, &permit)) {
        stderrPrint("注意: permit（オフチェーン署名の代行）です\n", .{});
    }
}

// ---------------------------------------------------------------- screen

const png = @import("png.zig");

/// 実機の画面（240×240）を組み立てて PNG で出力する。
///
/// 実機が無くても UI を確認できるようにするためのコマンド。
/// `--demo` ならサンプル、PSBT を渡せばその確認画面を描く。
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

    const qr_mode = option(args, "--qr") != null;
    const demo = option(args, "--demo") != null;
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
            stderrPrint("PSBT（base64）を渡すか、--demo を指定してください\n", .{});
            return error.Usage;
        }
        const decoder = std.base64.standard.Decoder;
        const raw = try allocator.alloc(u8, try decoder.calcSizeForSlice(trimmed));
        try decoder.decode(raw, trimmed);
        const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);

        // 送金先（お釣り以外の最初の出力）を探す
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
            stderrPrint("送金先の出力が見つかりません\n", .{});
            return error.InvalidArgument;
        }

        lines_buf[0] = .{ .label = "To", .value = to_address };
        lines_buf[1] = .{ .label = "Amount", .value = try std.fmt.allocPrint(allocator, "{d} sats", .{amount}) , .kind = .strong };

        // 手数料
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

    // QR（デモでは市松模様。実際の UR は QR エンコーダ実装後に差し込む）
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

    // 拡大して PNG で出す（既定は等倍）
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
    stderrPrint("画面を PNG で出力しました（{d}×{d}）\n", .{ screen_width * scale, screen_height * scale });
}

/// 文字列（UR の 1 パートなど）を QR として表示する画面を描く。
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
        stderrPrint("QR にする文字列を標準入力から渡してください\n", .{});
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
        "QR を出力しました（v{d}・{d}×{d}モジュール）\n",
        .{ matrix.version, matrix.size, matrix.size },
    );
    matrix.deinit(allocator);
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
