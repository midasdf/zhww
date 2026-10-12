//! Taproot（BIP341 / BIP86）の鍵パス署名。
//!
//! 参考: https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki
//!       https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki
//!
//! **実装範囲**: 鍵パス（key path）のみ。スクリプトパス（Tapscript）は実装しない
//! （誤実装のリスクが高いため。[docs/01-requirements.md] でスコープ外としている）。
//!
//! **注意点**
//! - Taproot の署名対象ハッシュは **単一の SHA256**（`tagged_hash("TapSighash", ...)`）。
//!   Legacy / BIP143 の二重 SHA256 とは異なる
//! - 署名に使う鍵は `taproot_tweak_private_key` で tweak 済みにすること（BIP341）
//! - `SIGHASH_DEFAULT` の署名は 64 バイトで、末尾に sighash タイプを付けない
//!   （BIP143 の 65 バイトとは異なる）

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const transaction = @import("transaction.zig");

/// BIP341 の sighash タイプ。`SIGHASH_DEFAULT` は 0 で、署名にタイプを付けない。
pub const SIGHASH_DEFAULT: u8 = 0x00;
pub const SIGHASH_ALL: u8 = 0x01;

/// P2TR の scriptPubKey（`5120{x-only 出力鍵}`）。
pub fn scriptPubKey(output_key: [32]u8) [34]u8 {
    var script: [34]u8 = undefined;
    script[0] = 0x51; // OP_1
    script[1] = 0x20; // push 32
    @memcpy(script[2..34], &output_key);
    return script;
}

/// scriptPubKey が P2TR なら x-only 出力鍵を取り出す。
pub fn outputKeyFromScript(script: []const u8) ?[32]u8 {
    if (script.len != 34) return null;
    if (script[0] != 0x51 or script[1] != 0x20) return null;
    return script[2..34].*;
}

/// BIP341 の署名対象ハッシュ（鍵パス、annex なし）。
///
/// `prevouts` は入力と同じ順・同じ数の UTXO 情報（金額と scriptPubKey）が必要。
/// `SIGHASH_DEFAULT`（および `ALL`）ではすべての入力の情報を使う。
pub fn sighashKeyPath(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    prevouts: []const transaction.TxOut,
    sighash_type: u8,
) Error![32]u8 {
    if (sighash_type != SIGHASH_DEFAULT and sighash_type != SIGHASH_ALL) {
        return error.UnsupportedSighash; // NONE / SINGLE は非対応
    }
    if (input_index >= tx.inputs.len) return error.InvalidEncoding;
    if (prevouts.len != tx.inputs.len) return error.InvalidEncoding;

    var sha_prevouts: [32]u8 = undefined;
    var sha_amounts: [32]u8 = undefined;
    var sha_scriptpubkeys: [32]u8 = undefined;
    var sha_sequences: [32]u8 = undefined;
    var sha_outputs: [32]u8 = undefined;

    // sha_prevouts / sha_amounts / sha_scriptpubkeys / sha_sequences
    {
        var prevout_bytes = std.ArrayList(u8).empty;
        defer prevout_bytes.deinit(allocator);
        var amount_bytes = std.ArrayList(u8).empty;
        defer amount_bytes.deinit(allocator);
        var script_bytes = std.ArrayList(u8).empty;
        defer script_bytes.deinit(allocator);
        var sequence_bytes = std.ArrayList(u8).empty;
        defer sequence_bytes.deinit(allocator);

        for (tx.inputs, 0..) |input, i| {
            try prevout_bytes.appendSlice(allocator, &input.prevout.txid);
            var vout: [4]u8 = undefined;
            std.mem.writeInt(u32, &vout, input.prevout.vout, .little);
            try prevout_bytes.appendSlice(allocator, &vout);

            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, prevouts[i].value, .little);
            try amount_bytes.appendSlice(allocator, &value);

            try transaction.writeVarBytes(&script_bytes, allocator, prevouts[i].script_pubkey);

            var sequence: [4]u8 = undefined;
            std.mem.writeInt(u32, &sequence, input.sequence, .little);
            try sequence_bytes.appendSlice(allocator, &sequence);
        }

        hashes.Sha256.hash(prevout_bytes.items, &sha_prevouts, .{});
        hashes.Sha256.hash(amount_bytes.items, &sha_amounts, .{});
        hashes.Sha256.hash(script_bytes.items, &sha_scriptpubkeys, .{});
        hashes.Sha256.hash(sequence_bytes.items, &sha_sequences, .{});
    }

    // sha_outputs
    {
        var output_bytes = std.ArrayList(u8).empty;
        defer output_bytes.deinit(allocator);
        for (tx.outputs) |output| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, output.value, .little);
            try output_bytes.appendSlice(allocator, &value);
            try transaction.writeVarBytes(&output_bytes, allocator, output.script_pubkey);
        }
        hashes.Sha256.hash(output_bytes.items, &sha_outputs, .{});
    }

    // 署名対象の組み立て
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var version: [4]u8 = undefined;
    std.mem.writeInt(i32, &version, tx.version, .little);
    var lock_time: [4]u8 = undefined;
    std.mem.writeInt(u32, &lock_time, tx.lock_time, .little);
    var index: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, @intCast(input_index), .little);

    try buffer.append(allocator, 0x00); // sighash epoch
    try buffer.append(allocator, sighash_type);
    try buffer.appendSlice(allocator, &version);
    try buffer.appendSlice(allocator, &lock_time);
    try buffer.appendSlice(allocator, &sha_prevouts);
    try buffer.appendSlice(allocator, &sha_amounts);
    try buffer.appendSlice(allocator, &sha_scriptpubkeys);
    try buffer.appendSlice(allocator, &sha_sequences);
    try buffer.appendSlice(allocator, &sha_outputs);
    try buffer.append(allocator, 0x00); // spend_type（鍵パス・annex なし）
    try buffer.appendSlice(allocator, &index);

    var digest: [32]u8 = undefined;
    hashes.taggedHash(&digest, "TapSighash", buffer.items);
    return digest;
}

/// 鍵パスの署名（64 バイト。`SIGHASH_DEFAULT`）。
///
/// `priv` は内部鍵の秘密鍵（tweak 前）。内部で BIP341 の tweak を適用する。
pub fn signKeyPath(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    prevouts: []const transaction.TxOut,
    priv: [32]u8,
) Error![64]u8 {
    const message = try sighashKeyPath(
        allocator,
        tx,
        input_index,
        prevouts,
        SIGHASH_DEFAULT,
    );
    const tweaked = try secp256k1.taprootTweakPrivateKey(priv);
    return secp256k1.schnorrSign(message, tweaked);
}

/// 鍵パス署名の witness（64 バイトの署名 1 つだけ）。
pub fn witnessFrom(signature: [64]u8) [1][]const u8 {
    return .{&signature};
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "P2TR の scriptPubKey と出力鍵の取り出し" {
    const output_key: [32]u8 = @splat(0xAB);
    const script = scriptPubKey(output_key);
    try testing.expectEqual(@as(u8, 0x51), script[0]);
    try testing.expectEqual(@as(u8, 0x20), script[1]);
    try testing.expectEqualSlices(u8, &output_key, &outputKeyFromScript(&script).?);
    try testing.expect(outputKeyFromScript(&[_]u8{ 0x00, 0x14 }) == null);
}

test "鍵パス署名は BIP340 の検証を通り、決定論的である" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 適当な 1 入力 1 出力のトランザクション
    var prev_txid: [32]u8 = undefined;
    for (&prev_txid, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    var destination: [22]u8 = @splat(0x11);
    destination[0] = 0x00;
    destination[1] = 0x14;
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 90_000, .script_pubkey = &destination };
    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };

    // 内部鍵から P2TR の出力鍵を作り、その UTXO を用意する
    var priv: [32]u8 = @splat(0);
    priv[31] = 0x42;
    const internal = try secp256k1.schnorrPublicKey(priv);
    const output_key = try secp256k1.taprootOutputKey(internal);
    const prevouts = try allocator.alloc(transaction.TxOut, 1);
    prevouts[0] = .{ .value = 100_000, .script_pubkey = &scriptPubKey(output_key) };

    const signature = try signKeyPath(allocator, tx, 0, prevouts, priv);

    // 署名は output_key に対して検証が通る
    const message = try sighashKeyPath(allocator, tx, 0, prevouts, SIGHASH_DEFAULT);
    try testing.expect(try secp256k1.schnorrVerify(signature, message, output_key));

    // 決定論的（同じ入力からは同じ署名）
    const again = try signKeyPath(allocator, tx, 0, prevouts, priv);
    try testing.expectEqualSlices(u8, &signature, &again);

    // 改竄した署名は通らない
    var broken = signature;
    broken[0] ^= 0x01;
    try testing.expect(!try secp256k1.schnorrVerify(broken, message, output_key));

    // witness は署名 1 つ（65 バイトの sighash タイプ付きではない）
    const witness = witnessFrom(signature);
    try testing.expectEqual(@as(usize, 1), witness.len);
    try testing.expectEqual(@as(usize, 64), witness[0].len);
}

test "SIGHASH_DEFAULT 以外は非対応（NONE / SINGLE を拒否する）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prev_txid: [32]u8 = @splat(0);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0,
        .witness = &.{},
    };
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 1, .script_pubkey = &[_]u8{0x6a} };
    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const prevouts = try allocator.alloc(transaction.TxOut, 1);
    prevouts[0] = .{ .value = 2, .script_pubkey = &[_]u8{0x6a} };

    try testing.expectError(
        error.UnsupportedSighash,
        sighashKeyPath(allocator, tx, 0, prevouts, 0x02), // SIGHASH_NONE
    );
    try testing.expectError(
        error.UnsupportedSighash,
        sighashKeyPath(allocator, tx, 0, prevouts, 0x03), // SIGHASH_SINGLE
    );
    // 入力数と UTXO 数が合わない場合も拒否する
    try testing.expectError(
        error.InvalidEncoding,
        sighashKeyPath(allocator, tx, 0, &.{}, SIGHASH_DEFAULT),
    );
}
