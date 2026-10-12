//! トランザクションの署名対象ハッシュ（sighash）。
//!
//! - Legacy（P2PKH / P2PK）: scriptSig を差し替えた tx の二重 SHA-256
//! - SegWit v0（P2WPKH / P2WSH）: BIP143 の preimage
//!
//! **対応する sighash タイプは SIGHASH_ALL と ANYONECANPAY 付きのみ。**
//! NONE / SINGLE は「署名した覚えのない出力への送金」を許すため、誤用防止の観点から
//! 明示的に非対応（error.UnsupportedSighash）としている。
//!
//! 参考: https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const transaction = @import("transaction.zig");

pub const SIGHASH_ALL: u32 = 0x01;
pub const SIGHASH_NONE: u32 = 0x02;
pub const SIGHASH_SINGLE: u32 = 0x03;
pub const SIGHASH_ANYONECANPAY: u32 = 0x80;

fn isSupported(sighash_type: u32) bool {
    const base = sighash_type & 0x1F;
    return base == SIGHASH_ALL;
}

fn hasAnyoneCanPay(sighash_type: u32) bool {
    return (sighash_type & SIGHASH_ANYONECANPAY) != 0;
}

/// P2WPKH の scriptCode（**25 バイト**）。
///
/// `76a914{20}88ac`（OP_DUP / OP_HASH160 / push20 / OP_EQUALVERIFY / OP_CHECKSIG）。
/// BIP143 の preimage では scriptCode を「CTxOut 内のスクリプトと同様に」直列化するため、
/// 呼び出し側が `writeVarBytes` で長さ（`0x19`）を付ける。したがって preimage 上では
/// `1976a914{20}88ac` の 26 バイトとして現れる。
pub fn p2wpkhScriptCode(pubkey_hash: [20]u8) [25]u8 {
    var script: [25]u8 = undefined;
    script[0] = 0x76; // OP_DUP
    script[1] = 0xa9; // OP_HASH160
    script[2] = 0x14; // push 20 bytes
    @memcpy(script[3..23], &pubkey_hash);
    script[23] = 0x88; // OP_EQUALVERIFY
    script[24] = 0xac; // OP_CHECKSIG
    return script;
}

/// P2WPKH の scriptPubKey（`0014{20}`）。
pub fn p2wpkhScriptPubKey(pubkey_hash: [20]u8) [22]u8 {
    var script: [22]u8 = undefined;
    script[0] = 0x00;
    script[1] = 0x14;
    @memcpy(script[2..22], &pubkey_hash);
    return script;
}

/// BIP143 の hashPrevouts（全入力の outpoint の二重 SHA-256）。
pub fn hashPrevouts(allocator: std.mem.Allocator, tx: transaction.Transaction) Error![32]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    for (tx.inputs) |input| {
        try buffer.appendSlice(allocator, &input.prevout.txid);
        var vout: [4]u8 = undefined;
        std.mem.writeInt(u32, &vout, input.prevout.vout, .little);
        try buffer.appendSlice(allocator, &vout);
    }
    var hash: [32]u8 = undefined;
    hashes.sha256d(&hash, buffer.items);
    return hash;
}

/// BIP143 の hashSequence（全入力の sequence の二重 SHA-256）。
pub fn hashSequence(allocator: std.mem.Allocator, tx: transaction.Transaction) Error![32]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    for (tx.inputs) |input| {
        var sequence: [4]u8 = undefined;
        std.mem.writeInt(u32, &sequence, input.sequence, .little);
        try buffer.appendSlice(allocator, &sequence);
    }
    var hash: [32]u8 = undefined;
    hashes.sha256d(&hash, buffer.items);
    return hash;
}

/// BIP143 の hashOutputs（全出力の二重 SHA-256）。
pub fn hashOutputs(allocator: std.mem.Allocator, tx: transaction.Transaction) Error![32]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);
    for (tx.outputs) |output| {
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, output.value, .little);
        try buffer.appendSlice(allocator, &value);
        try transaction.writeVarBytes(&buffer, allocator, output.script_pubkey);
    }
    var hash: [32]u8 = undefined;
    hashes.sha256d(&hash, buffer.items);
    return hash;
}

/// Legacy の署名対象ハッシュ。`script_code` は前出力の scriptPubKey。
pub fn legacySighash(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    script_code: []const u8,
    sighash_type: u32,
) Error![32]u8 {
    if (!isSupported(sighash_type)) return error.UnsupportedSighash;
    if (input_index >= tx.inputs.len) return error.InvalidEncoding;

    // scriptSig を空にし、対象入力だけ script_code を入れた tx を作る
    var modified = tx;
    const inputs = try allocator.alloc(transaction.TxIn, tx.inputs.len);
    for (tx.inputs, 0..) |input, i| {
        var copy = input;
        copy.script_sig = if (i == input_index) script_code else &.{};
        copy.witness = &.{};
        inputs[i] = copy;
    }
    modified.inputs = inputs;
    modified.has_witness = false;

    const raw = try modified.serialize(allocator, false);
    defer allocator.free(raw);

    var preimage = try allocator.alloc(u8, raw.len + 4);
    defer allocator.free(preimage);
    @memcpy(preimage[0..raw.len], raw);
    std.mem.writeInt(u32, preimage[raw.len..][0..4], sighash_type, .little);

    var hash: [32]u8 = undefined;
    hashes.sha256d(&hash, preimage);
    return hash;
}

/// SegWit v0（BIP143）の署名対象ハッシュ。
pub fn segwitV0Sighash(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    script_code: []const u8,
    amount: u64,
    sighash_type: u32,
) Error![32]u8 {
    if (!isSupported(sighash_type)) return error.UnsupportedSighash;
    if (input_index >= tx.inputs.len) return error.InvalidEncoding;

    const anyone_can_pay = hasAnyoneCanPay(sighash_type);

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    // hashPrevouts（ANYONECANPAY の場合はゼロ）
    var hash_prevouts: [32]u8 = @splat(0);
    if (!anyone_can_pay) hash_prevouts = try hashPrevouts(allocator, tx);

    // hashSequence（ANYONECANPAY の場合はゼロ）
    var hash_sequence: [32]u8 = @splat(0);
    if (!anyone_can_pay) hash_sequence = try hashSequence(allocator, tx);

    // hashOutputs（SIGHASH_ALL のみ対応なので常に全出力）
    const hash_outputs = try hashOutputs(allocator, tx);

    const input = tx.inputs[input_index];
    var version: [4]u8 = undefined;
    std.mem.writeInt(i32, &version, tx.version, .little);
    var sequence: [4]u8 = undefined;
    std.mem.writeInt(u32, &sequence, input.sequence, .little);
    var amount_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &amount_bytes, amount, .little);
    var lock_time: [4]u8 = undefined;
    std.mem.writeInt(u32, &lock_time, tx.lock_time, .little);
    var sighash_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &sighash_bytes, sighash_type, .little);

    try buffer.appendSlice(allocator, &version);
    try buffer.appendSlice(allocator, &hash_prevouts);
    try buffer.appendSlice(allocator, &hash_sequence);
    try buffer.appendSlice(allocator, &input.prevout.txid);
    var vout: [4]u8 = undefined;
    std.mem.writeInt(u32, &vout, input.prevout.vout, .little);
    try buffer.appendSlice(allocator, &vout);
    try transaction.writeVarBytes(&buffer, allocator, script_code);
    try buffer.appendSlice(allocator, &amount_bytes);
    try buffer.appendSlice(allocator, &sequence);
    try buffer.appendSlice(allocator, &hash_outputs);
    try buffer.appendSlice(allocator, &lock_time);
    try buffer.appendSlice(allocator, &sighash_bytes);

    var hash: [32]u8 = undefined;
    hashes.sha256d(&hash, buffer.items);
    return hash;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "sighash タイプの対応範囲" {
    try testing.expect(isSupported(SIGHASH_ALL));
    try testing.expect(isSupported(SIGHASH_ALL | SIGHASH_ANYONECANPAY));
    try testing.expect(!isSupported(SIGHASH_NONE));
    try testing.expect(!isSupported(SIGHASH_SINGLE));
    try testing.expect(hasAnyoneCanPay(SIGHASH_ALL | SIGHASH_ANYONECANPAY));
    try testing.expect(!hasAnyoneCanPay(SIGHASH_ALL));
}

test "P2WPKH の scriptCode と scriptPubKey" {
    var hash: [20]u8 = undefined;
    for (&hash, 0..) |*byte, i| byte.* = @intCast(i);

    // scriptCode は `76a914{20}88ac` の 25 バイト（preimage 側で長さ 0x19 が付く）。
    // 全バイトを比較する（末尾の 0x88 0xac を書き漏らすバグを検出するため）。
    const script_code = p2wpkhScriptCode(hash);
    var expected: [25]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    try testing.expectEqualSlices(u8, &expected, &script_code);

    // scriptPubKey は 0014{20}
    const script_pubkey = p2wpkhScriptPubKey(hash);
    var expected_pubkey: [22]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected_pubkey, "0014000102030405060708090a0b0c0d0e0f10111213");
    try testing.expectEqualSlices(u8, &expected_pubkey, &script_pubkey);
}
