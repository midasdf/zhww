//! PSBT（BIP174）の解析と検証。
//!
//! 参考: https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki
//!
//! **実装範囲**: PSBTv0（`PSBT_GLOBAL_UNSIGNED_TX` を持つ形式）。
//! PSBTv2（入力・出力を個別のマップで持つ形式）は未対応で、unsigned tx が無い場合は
//! `error.InvalidPsbt` とする。
//!
//! **検証方針**: BIP174 の「解析時に拒否すべき」条件だけを実装する。
//! - マジック `psbt\xff`
//! - 同じマップ内でのキーの重複
//! - 型ごとのキー長（例: partial sig の公開鍵は 33 か 65 バイト）
//! - unsigned tx は witness 無しの直列化で、scriptSig が全て空であること
//! - 入力マップ・出力マップの数がトランザクションと一致すること
//!
//! スクリプトの一致確認（redeemScript が scriptPubKey と一致するか等）は
//! **署名者の責務**であり、解析時には検証しない（BIP174 のテストベクタでも
//! 「一致しないが妥当な PSBT」が valid として扱われている）。

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const Cursor = @import("cursor.zig").Cursor;
const transaction = @import("transaction.zig");

/// PSBT のマジックバイト。
pub const magic = [5]u8{ 0x70, 0x73, 0x62, 0x74, 0xff };

// グローバルの型
const GLOBAL_UNSIGNED_TX: u8 = 0x00;
const GLOBAL_XPUB: u8 = 0x01;
const GLOBAL_VERSION: u8 = 0xFB;

// 入力の型
const IN_NON_WITNESS_UTXO: u8 = 0x00;
const IN_WITNESS_UTXO: u8 = 0x01;
const IN_PARTIAL_SIG: u8 = 0x02;
const IN_SIGHASH_TYPE: u8 = 0x03;
const IN_REDEEM_SCRIPT: u8 = 0x04;
const IN_WITNESS_SCRIPT: u8 = 0x05;
const IN_BIP32_DERIVATION: u8 = 0x06;
const IN_FINAL_SCRIPTSIG: u8 = 0x07;
const IN_FINAL_SCRIPTWITNESS: u8 = 0x08;

// 出力の型
const OUT_REDEEM_SCRIPT: u8 = 0x00;
const OUT_WITNESS_SCRIPT: u8 = 0x01;
const OUT_BIP32_DERIVATION: u8 = 0x02;

pub const PartialSig = struct {
    pubkey: []const u8,
    signature: []const u8,
};

pub const Bip32Derivation = struct {
    pubkey: []const u8,
    fingerprint: [4]u8,
    /// hardened ビット付きの派生パス。
    path: []const u32,
};

pub const Input = struct {
    witness_utxo: ?transaction.TxOut = null,
    non_witness_utxo: ?transaction.Transaction = null,
    partial_sigs: []const PartialSig = &.{},
    sighash_type: ?u32 = null,
    redeem_script: ?[]const u8 = null,
    witness_script: ?[]const u8 = null,
    bip32_derivations: []const Bip32Derivation = &.{},
    final_script_sig: ?[]const u8 = null,
    final_script_witness: ?[]const []const u8 = null,

    /// 署名に使える UTXO 情報（witness_utxo を優先）。
    pub fn utxo(self: Input) ?transaction.TxOut {
        if (self.witness_utxo) |witness| return witness;
        // non_witness_utxo から該当する出力を取り出すには prevout が必要なため、
        // ここでは witness_utxo のみ返す。呼び出し側（署名者）が prevout を使って解決する。
        return null;
    }
};

pub const Output = struct {
    redeem_script: ?[]const u8 = null,
    witness_script: ?[]const u8 = null,
    bip32_derivations: []const Bip32Derivation = &.{},
};

pub const Psbt = struct {
    unsigned_tx: transaction.Transaction,
    inputs: []Input,
    outputs: []Output,
    /// PSBT_GLOBAL_VERSION（未設定なら 0 = PSBTv0）。
    version: u32 = 0,
    /// 各マップの生バイト列（終端の 0x00 を含まない）。
    /// 未知のフィールドをそのまま保持して書き戻すために使う。
    global_raw: []const u8 = &.{},
    input_raw: []const []const u8 = &.{},
    output_raw: []const []const u8 = &.{},

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Psbt {
        var cursor = Cursor{ .data = bytes };
        const header = try cursor.readBytes(magic.len);
        if (!std.mem.eql(u8, header, &magic)) return error.InvalidPsbt;

        // --- グローバルマップ ---
        const global_start = cursor.pos;
        var unsigned_tx: ?transaction.Transaction = null;
        var version: u32 = 0;

        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(allocator);

        while (true) {
            const key_len = try cursor.readVarInt();
            if (key_len == 0) break; // マップ終端
            const key = try cursor.readBytes(@intCast(key_len));
            try checkDuplicate(keys.items, key);
            try keys.append(allocator, key);

            const value_len = try cursor.readVarInt();
            const value = try cursor.readBytes(@intCast(value_len));

            switch (key[0]) {
                GLOBAL_UNSIGNED_TX => {
                    if (key.len != 1) return error.InvalidPsbt;
                    if (unsigned_tx != null) return error.InvalidPsbt;
                    // Transaction.parse は「余分なバイトが無いこと」まで検証する
                    const tx = try parseUnsignedTx(allocator, value);
                    if (tx.has_witness) return error.InvalidPsbt; // witness 直列化は不可
                    for (tx.inputs) |input| {
                        if (input.script_sig.len != 0) return error.InvalidPsbt;
                    }
                    unsigned_tx = tx;
                },
                GLOBAL_XPUB => {
                    // キーは 1 + 78 バイト（拡張公開鍵）。内容は署名には使わない
                    if (key.len != 1 + 78) return error.InvalidPsbt;
                },
                GLOBAL_VERSION => {
                    if (key.len != 1) return error.InvalidPsbt;
                    if (value.len != 4) return error.InvalidPsbt;
                    version = std.mem.readInt(u32, value[0..4], .little);
                },
                else => {
                    // 未知の型は無視する（BIP174 の拡張性の規定）
                },
            }
        }

        // PSBTv0 では unsigned tx が必須
        const tx = unsigned_tx orelse return error.InvalidPsbt;
        // 終端の 0x00 を除いたマップ本体
        const global_raw = bytes[global_start .. cursor.pos - 1];

        // --- 入力マップ（トランザクションの入力数と一致すること） ---
        const inputs = try allocator.alloc(Input, tx.inputs.len);
        const input_raw = try allocator.alloc([]const u8, tx.inputs.len);
        for (inputs) |*input| input.* = .{};
        for (inputs, 0..) |*input, i| {
            input_raw[i] = try parseInputMap(allocator, &cursor, input);
        }

        // --- 出力マップ ---
        const outputs = try allocator.alloc(Output, tx.outputs.len);
        const output_raw = try allocator.alloc([]const u8, tx.outputs.len);
        for (outputs) |*output| output.* = .{};
        for (outputs, 0..) |*output, i| {
            output_raw[i] = try parseOutputMap(allocator, &cursor, output);
        }

        // 余分なデータがあってはならない
        if (cursor.remaining() != 0) return error.InvalidPsbt;
        // 0xfb がある場合は version 0 以外（PSBTv2 等）として扱う
        if (version != 0) return error.InvalidPsbt;

        return .{
            .unsigned_tx = tx,
            .inputs = inputs,
            .outputs = outputs,
            .version = version,
            .global_raw = global_raw,
            .input_raw = input_raw,
            .output_raw = output_raw,
        };
    }

    /// 署名済み（または部分署名済み）PSBT を書き出す。
    ///
    /// 元のバイト列をそのまま使い、**未知のフィールドも保持する**。
    /// `sigs_by_input` は入力ごとの追加署名（公開鍵と DER 署名 + sighash タイプ）。
    /// 同じ公開鍵の partial sig が元のマップに既にある場合は置き換える。
    pub fn serialize(
        allocator: std.mem.Allocator,
        psbt: Psbt,
        sigs_by_input: []const []const PartialSig,
    ) Error![]u8 {
        if (sigs_by_input.len != psbt.inputs.len) return error.InvalidPsbt;
        if (psbt.input_raw.len != psbt.inputs.len) return error.InvalidPsbt;
        if (psbt.output_raw.len != psbt.outputs.len) return error.InvalidPsbt;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, &magic);
        try out.appendSlice(allocator, psbt.global_raw);
        try out.append(allocator, 0); // グローバルマップ終端

        for (psbt.input_raw, 0..) |raw, index| {
            try appendFilteredMap(allocator, &out, raw, sigs_by_input[index]);
            for (sigs_by_input[index]) |sig| {
                if (sig.pubkey.len != 33 and sig.pubkey.len != 65) return error.InvalidPsbt;
                try out.append(allocator, @intCast(1 + sig.pubkey.len));
                try out.append(allocator, IN_PARTIAL_SIG);
                try out.appendSlice(allocator, sig.pubkey);
                try transaction.writeVarInt(&out, allocator, sig.signature.len);
                try out.appendSlice(allocator, sig.signature);
            }
            try out.append(allocator, 0); // 入力マップ終端
        }

        for (psbt.output_raw) |raw| {
            try out.appendSlice(allocator, raw);
            try out.append(allocator, 0); // 出力マップ終端
        }

        return out.toOwnedSlice(allocator);
    }
};

/// 生のマップをコピーする。ただし `new_sigs` に含まれる公開鍵の partial sig は
/// 取り除く（重複キーを作らないため）。
fn appendFilteredMap(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
    new_sigs: []const PartialSig,
) Error!void {
    var cursor = Cursor{ .data = raw };
    while (cursor.remaining() > 0) {
        const field_start = cursor.pos;
        const key_len = try cursor.readVarInt();
        const key = try cursor.readBytes(@intCast(key_len));
        const value_len = try cursor.readVarInt();
        _ = try cursor.readBytes(@intCast(value_len));

        var skip = false;
        if (key.len >= 1 and key[0] == IN_PARTIAL_SIG) {
            for (new_sigs) |sig| {
                if (std.mem.eql(u8, key[1..], sig.pubkey)) skip = true;
            }
        }
        if (!skip) try out.appendSlice(allocator, raw[field_start..cursor.pos]);
    }
}

fn parseUnsignedTx(
    allocator: std.mem.Allocator,
    value: []const u8,
) Error!transaction.Transaction {
    return transaction.Transaction.parse(allocator, value) catch |err| switch (err) {
        error.Truncated, error.InvalidEncoding => error.InvalidPsbt,
        else => err,
    };
}

fn checkDuplicate(existing: []const []const u8, key: []const u8) Error!void {
    for (existing) |previous| {
        if (std.mem.eql(u8, previous, key)) return error.InvalidPsbt;
    }
}

fn parseInputMap(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    input: *Input,
) Error![]const u8 {
    const start = cursor.pos;
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var partial_sigs = std.ArrayList(PartialSig).empty;
    var derivations = std.ArrayList(Bip32Derivation).empty;

    while (true) {
        const key_len = try cursor.readVarInt();
        if (key_len == 0) break;
        const key = try cursor.readBytes(@intCast(key_len));
        try checkDuplicate(keys.items, key);
        try keys.append(allocator, key);

        const value_len = try cursor.readVarInt();
        const value = try cursor.readBytes(@intCast(value_len));

        switch (key[0]) {
            IN_NON_WITNESS_UTXO => {
                if (key.len != 1) return error.InvalidPsbt;
                input.non_witness_utxo = try parseUnsignedTx(allocator, value);
            },
            IN_WITNESS_UTXO => {
                if (key.len != 1) return error.InvalidPsbt;
                var utxo_cursor = Cursor{ .data = value };
                const out = try parseTxOut(&utxo_cursor);
                if (utxo_cursor.remaining() != 0) return error.InvalidPsbt;
                input.witness_utxo = out;
            },
            IN_PARTIAL_SIG => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try partial_sigs.append(allocator, .{
                    .pubkey = key[1..],
                    .signature = value,
                });
            },
            IN_SIGHASH_TYPE => {
                if (key.len != 1) return error.InvalidPsbt;
                if (value.len != 4) return error.InvalidPsbt;
                input.sighash_type = std.mem.readInt(u32, value[0..4], .little);
            },
            IN_REDEEM_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                input.redeem_script = value;
            },
            IN_WITNESS_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                input.witness_script = value;
            },
            IN_BIP32_DERIVATION => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try derivations.append(
                    allocator,
                    try parseDerivation(allocator, key[1..], value),
                );
            },
            IN_FINAL_SCRIPTSIG => {
                if (key.len != 1) return error.InvalidPsbt;
                input.final_script_sig = value;
            },
            IN_FINAL_SCRIPTWITNESS => {
                if (key.len != 1) return error.InvalidPsbt;
                var witness_cursor = Cursor{ .data = value };
                const items = try parseWitness(allocator, &witness_cursor);
                if (witness_cursor.remaining() != 0) return error.InvalidPsbt;
                input.final_script_witness = items;
            },
            else => {
                // 未知の型（または本実装が未対応の型）は無視する
            },
        }
    }

    input.partial_sigs = try partial_sigs.toOwnedSlice(allocator);
    input.bip32_derivations = try derivations.toOwnedSlice(allocator);
    // 終端の 0x00 を除いたマップ本体
    return cursor.data[start .. cursor.pos - 1];
}

fn parseOutputMap(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    output: *Output,
) Error![]const u8 {
    const start = cursor.pos;
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var derivations = std.ArrayList(Bip32Derivation).empty;

    while (true) {
        const key_len = try cursor.readVarInt();
        if (key_len == 0) break;
        const key = try cursor.readBytes(@intCast(key_len));
        try checkDuplicate(keys.items, key);
        try keys.append(allocator, key);

        const value_len = try cursor.readVarInt();
        const value = try cursor.readBytes(@intCast(value_len));

        switch (key[0]) {
            OUT_REDEEM_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                output.redeem_script = value;
            },
            OUT_WITNESS_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                output.witness_script = value;
            },
            OUT_BIP32_DERIVATION => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try derivations.append(
                    allocator,
                    try parseDerivation(allocator, key[1..], value),
                );
            },
            else => {},
        }
    }

    output.bip32_derivations = try derivations.toOwnedSlice(allocator);
    // 終端の 0x00 を除いたマップ本体
    return cursor.data[start .. cursor.pos - 1];
}

fn parseTxOut(cursor: *Cursor) Error!transaction.TxOut {
    const value = try cursor.readU64();
    const script_pubkey = try cursor.readVarBytes();
    return .{ .value = value, .script_pubkey = script_pubkey };
}

fn parseWitness(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
) Error![]const []const u8 {
    const count = try cursor.readVarInt();
    if (count > 1024) return error.InvalidPsbt;
    const items = try allocator.alloc([]const u8, @intCast(count));
    for (items) |*item| {
        item.* = try cursor.readVarBytes();
    }
    return items;
}

/// BIP32 派生情報（4 バイトの fingerprint + 4 バイト単位のインデックス列）。
fn parseDerivation(
    allocator: std.mem.Allocator,
    pubkey: []const u8,
    value: []const u8,
) Error!Bip32Derivation {
    if (value.len < 8 or (value.len - 4) % 4 != 0) return error.InvalidPsbt;
    const count = (value.len - 4) / 4;
    const path = try allocator.alloc(u32, count);
    for (path, 0..) |*index, i| {
        index.* = std.mem.readInt(u32, value[4 + i * 4 ..][0..4], .little);
    }
    return .{
        .pubkey = pubkey,
        .fingerprint = value[0..4].*,
        .path = path,
    };
}

/// 公開鍵が有効な形（圧縮 33 / 非圧縮 65 バイト）かどうか。
pub fn isValidPubKeyFormat(pubkey: []const u8) bool {
    if (pubkey.len == 33) return pubkey[0] == 2 or pubkey[0] == 3;
    if (pubkey.len == 65) return pubkey[0] == 4;
    return false;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

const sample_psbt_hex = "70736274ff0100550200000001279a2323a5dfb51fc45f220fa58b0fc13e1e3342792a85d7e36cd6333b5cbc390000000000ffffffff01a05aea0b000000001976a914ffe9c0061097cc3b636f2cb0460fa4fc427d2b4588ac0000000000010120955eea0b0000000017a9146345200f68d189e1adc0df1c4d16ea8f14c0dbeb8700000000";

test "マジックバイトが違えば拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ネットワーク形式のトランザクション（PSBT ではない）
    const raw = try allocator.alloc(u8, 8);
    _ = try std.fmt.hexToBytes(raw, "0200000001000000");
    try testing.expectError(error.InvalidPsbt, Psbt.parse(allocator, raw));
}

test "最小構成の PSBT を組み立てて解析する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 1 入力 1 出力の未署名トランザクション
    var prev_txid: [32]u8 = undefined;
    for (&prev_txid, 0..) |*byte, i| byte.* = @intCast(i);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    var hash20: [20]u8 = undefined;
    for (&hash20, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const script_pubkey = [_]u8{ 0x00, 0x14 } ++ hash20;
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 50_000, .script_pubkey = &script_pubkey };

    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const raw_tx = try tx.serialize(allocator, false);

    // PSBT を組み立てる
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &magic);

    // グローバル: unsigned tx
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, GLOBAL_UNSIGNED_TX);
    try transaction.writeVarInt(&bytes, allocator, raw_tx.len);
    try bytes.appendSlice(allocator, raw_tx);
    try bytes.append(allocator, 0); // グローバルマップ終端

    // 入力マップ: witness utxo
    var utxo_bytes = std.ArrayList(u8).empty;
    defer utxo_bytes.deinit(allocator);
    var value_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &value_le, 100_000, .little);
    try utxo_bytes.appendSlice(allocator, &value_le);
    try transaction.writeVarBytes(&utxo_bytes, allocator, &script_pubkey);
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, IN_WITNESS_UTXO);
    try transaction.writeVarInt(&bytes, allocator, utxo_bytes.items.len);
    try bytes.appendSlice(allocator, utxo_bytes.items);
    try bytes.append(allocator, 0); // 入力マップ終端

    // 出力マップ（空）
    try bytes.append(allocator, 0);

    const psbt = try Psbt.parse(allocator, bytes.items);
    try testing.expectEqual(@as(usize, 1), psbt.inputs.len);
    try testing.expectEqual(@as(usize, 1), psbt.outputs.len);
    try testing.expectEqual(@as(u64, 100_000), psbt.inputs[0].witness_utxo.?.value);
    try testing.expectEqualSlices(u8, &script_pubkey, psbt.inputs[0].witness_utxo.?.script_pubkey);
    try testing.expectEqual(@as(i32, 2), psbt.unsigned_tx.version);
}

test "キー長の検証（partial sig の公開鍵は 33 / 65 バイト）" {
    var compressed: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &compressed,
        "025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357",
    );
    try testing.expect(isValidPubKeyFormat(&compressed));
    try testing.expect(!isValidPubKeyFormat(&[_]u8{ 0x02, 0x01 }));
    try testing.expect(!isValidPubKeyFormat(&[_]u8{0x01}));
}

test "重複キーを拒否する" {
    // グローバルマップに同じキーを 2 回書いた PSBT
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &magic);
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, GLOBAL_UNSIGNED_TX, 0x01, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, GLOBAL_UNSIGNED_TX, 0x01, 0x00 });

    try testing.expectError(error.InvalidPsbt, Psbt.parse(testing.allocator, bytes.items));
}

test "カーソルが尽きたら拒否する" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &magic);
    // キー長 10 と言いつつ 2 バイトしかない
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x0A, 0x00, 0x00 });
    try testing.expectError(error.Truncated, Psbt.parse(testing.allocator, bytes.items));
}
