//! PSBT からの署名と最終化（Bitcoin 単一署名）。
//!
//! 役割分担（[docs/02-architecture.md] の不変条件）:
//! - 鍵の探索・署名対象の決定・署名・最終化をここで行う
//! - `apps` は鍵素材を保持しない。鍵は `KeySource` として呼び出し側が渡し、
//!   この層は「この鍵で署名した」という結果だけを返す
//!
//! **安全性の方針**
//! - 署名したら必ず `secp256k1.verify` で検証してから返す（壊れた署名を返さない）
//! - 入力額が分からない場合は手数料を計算しない（`amounts_complete = false`）。
//!   表示層はこの場合に承認を求めてはならない
//! - 非 witness 入力に対して `witness_utxo` しか無い場合は署名しない（BIP174 の規定）

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const bip32 = @import("../../core/derive/bip32.zig");
const bip39 = @import("../../core/seed/bip39.zig");
const bech32 = @import("../../core/encoding/bech32.zig");
const transaction = @import("transaction.zig");
const sighash = @import("sighash.zig");
const psbt_mod = @import("psbt.zig");

pub const SIGHASH_ALL: u32 = 0x01;

/// scriptPubKey の種類。
pub const ScriptKind = enum {
    p2pkh,
    p2sh,
    p2wpkh,
    p2wsh,
    p2tr,
    p2pk,
    unknown,

    pub fn isWitness(self: ScriptKind) bool {
        return switch (self) {
            .p2wpkh, .p2wsh, .p2tr => true,
            else => false,
        };
    }
};

/// scriptPubKey から種類を判定する。
pub fn detectScriptKind(script: []const u8) ScriptKind {
    if (script.len == 25 and script[0] == 0x76 and script[1] == 0xa9 and
        script[2] == 0x14 and script[23] == 0x88 and script[24] == 0xac) return .p2pkh;
    if (script.len == 23 and script[0] == 0xa9 and script[1] == 0x14 and script[22] == 0x87) {
        return .p2sh;
    }
    if (script.len == 22 and script[0] == 0x00 and script[1] == 0x14) return .p2wpkh;
    if (script.len == 34 and script[0] == 0x00 and script[1] == 0x20) return .p2wsh;
    if (script.len == 34 and script[0] == 0x51 and script[1] == 0x20) return .p2tr;
    if (script.len == 35 and script[0] == 0x21 and script[34] == 0xac) return .p2pk;
    return .unknown;
}

/// 署名に使う鍵の集合。
///
/// - `master` を渡すと BIP32 で派生する（通常の利用）
/// - `raw_keys` は個別にインポートした鍵（テストや復旧用）
pub const KeySource = struct {
    master: ?bip32.ExtendedKey = null,
    master_fingerprint: [4]u8 = @splat(0),
    raw_keys: []const RawKey = &.{},
    /// 鍵探索で辿る最大 index（受取・お釣りそれぞれ）。
    max_index: u32 = 20,

    pub const RawKey = struct {
        private_key: [32]u8,
        public_key: [33]u8,
    };

    /// seed から鍵集合を作る（BIP32 マスター鍵）。
    pub fn fromSeed(seed: []const u8) Error!KeySource {
        const master = try bip32.ExtendedKey.fromSeed(seed, .xprv);
        return .{
            .master = master,
            .master_fingerprint = try master.fingerprint(),
        };
    }

    /// 個別の鍵だけを使う。
    pub fn fromRawKeys(keys: []const RawKey) KeySource {
        return .{ .raw_keys = keys };
    }

    pub fn derive(self: KeySource, path: []const u32) Error!bip32.ExtendedKey {
        const master = self.master orelse return error.NoMatchingKey;
        var node = master;
        for (path) |index| node = try node.child(index);
        return node;
    }
};

/// 署名できた入力。
pub const PartialSignature = struct {
    index: usize,
    pubkey: [33]u8,
    /// DER 署名 + sighash タイプ（scriptSig / witness にそのまま入れられる形）。
    signature: []const u8,
};

/// 署名の結果。
pub const SignResult = struct {
    partial_sigs: []const PartialSignature,
    /// すべての入力に署名できた場合の最終トランザクション（直列化済み）。
    final_tx: ?[]const u8,
    /// 入力額の合計（1 つでも不明なら null）。
    total_input: ?u64,
    total_output: u64,
    /// 手数料（入力額がすべて判明している場合のみ）。
    fee: ?u64,
    /// お釣りと判定した出力の index。
    change_outputs: []const usize,
    /// 署名できなかった入力の index。
    unsigned_inputs: []const usize,
};

/// PSBT に署名する。
pub fn sign(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: KeySource,
) Error!SignResult {
    const tx = psbt.unsigned_tx;
    var partial_sigs = std.ArrayList(PartialSignature).empty;
    errdefer partial_sigs.deinit(allocator);
    var unsigned = std.ArrayList(usize).empty;
    errdefer unsigned.deinit(allocator);

    // 入力の scriptPubKey と金額を解決する
    const resolved = try allocator.alloc(?ResolvedUtxo, tx.inputs.len);
    for (resolved, 0..) |*entry, i| {
        entry.* = try resolveUtxo(allocator, psbt, i);
    }

    // 各入力に署名する
    const signatures = try allocator.alloc(?[]const u8, tx.inputs.len);
    const signer_keys = try allocator.alloc(?KeySource.RawKey, tx.inputs.len);
    for (signatures) |*slot| slot.* = null;
    for (signer_keys) |*slot| slot.* = null;

    for (tx.inputs, 0..) |_, index| {
        const utxo = resolved[index] orelse {
            try unsigned.append(allocator, index);
            continue;
        };
        const kind = detectScriptKind(utxo.script_pubkey);

        // 鍵を探す
        const found = try findKeyForInput(allocator, psbt, keys, index, utxo, kind) orelse {
            try unsigned.append(allocator, index);
            continue;
        };

        // 署名対象のハッシュを求める
        const message = try sighashForInput(
            allocator,
            psbt,
            index,
            utxo,
            kind,
            found.public_key,
        );

        const signature = try secp256k1.sign(message, found.private_key);
        // 署名は必ず検証してから採用する
        if (!(try secp256k1.verify(&signature, message, found.public_key))) {
            return error.SignatureInvalid;
        }

        var der_buf: [72]u8 = undefined;
        const der = try secp256k1.serializeDer(&der_buf, &signature);
        const blob = try allocator.alloc(u8, der.len + 1);
        @memcpy(blob[0..der.len], der);
        blob[der.len] = @intCast(SIGHASH_ALL);

        signatures[index] = blob;
        signer_keys[index] = found;
        try partial_sigs.append(allocator, .{
            .index = index,
            .pubkey = found.public_key,
            .signature = blob,
        });
    }

    // 入力額の合計と手数料
    var total_input: u64 = 0;
    var amounts_complete = true;
    for (resolved) |entry| {
        if (entry) |utxo| {
            total_input += utxo.amount;
        } else {
            amounts_complete = false;
        }
    }
    const total_output = tx.totalOutput();
    const fee: ?u64 = if (amounts_complete) blk: {
        if (total_input < total_output) return error.InvalidPsbt;
        break :blk total_input - total_output;
    } else null;

    // お釣り判定
    const change_outputs = try findChangeOutputs(allocator, psbt, keys);

    // 最終化（すべて署名できた場合のみ）
    var final_tx: ?[]const u8 = null;
    if (unsigned.items.len == 0) {
        final_tx = try finalize(allocator, psbt, signatures, signer_keys, resolved);
    }

    return .{
        .partial_sigs = try partial_sigs.toOwnedSlice(allocator),
        .final_tx = final_tx,
        .total_input = if (amounts_complete) total_input else null,
        .total_output = total_output,
        .fee = fee,
        .change_outputs = change_outputs,
        .unsigned_inputs = try unsigned.toOwnedSlice(allocator),
    };
}

const ResolvedUtxo = struct {
    script_pubkey: []const u8,
    amount: u64,
    /// P2SH-P2WPKH の場合の redeemScript。
    redeem_script: ?[]const u8 = null,
};

fn resolveUtxo(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
) Error!?ResolvedUtxo {
    const input = psbt.inputs[index];
    const prevout = psbt.unsigned_tx.inputs[index].prevout;

    // witness 入力なら witness_utxo を使う。
    // P2SH でも redeemScript が P2WPKH なら witness 入力（P2SH-P2WPKH）である。
    if (input.witness_utxo) |utxo| {
        const kind = detectScriptKind(utxo.script_pubkey);
        const is_witness_input = kind.isWitness() or (kind == .p2sh and
            input.redeem_script != null and
            detectScriptKind(input.redeem_script.?) == .p2wpkh);
        if (is_witness_input) {
            return .{
                .script_pubkey = utxo.script_pubkey,
                .amount = utxo.value,
                .redeem_script = input.redeem_script,
            };
        }
    }

    // non-witness utxo から該当する出力を探す。
    // **witness_utxo しか無い非 witness 入力は署名しない**（BIP174 の規定）。
    if (input.non_witness_utxo) |prev_tx| {
        // txid の一致を確認する（差し替え攻撃の防止）
        const txid = try prev_tx.txid(allocator);
        if (!std.mem.eql(u8, &txid, &prevout.txid)) return error.InvalidPsbt;

        for (prev_tx.outputs, 0..) |out, vout| {
            if (vout != prevout.vout) continue;
            return .{
                .script_pubkey = out.script_pubkey,
                .amount = out.value,
                .redeem_script = input.redeem_script,
            };
        }
        return error.InvalidPsbt;
    }

    return null;
}

fn findKeyForInput(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: KeySource,
    index: usize,
    utxo: ResolvedUtxo,
    kind: ScriptKind,
) Error!?KeySource.RawKey {
    // 1) PSBT の BIP32 派生情報を使う（fingerprint が一致するもの）
    for (psbt.inputs[index].bip32_derivations) |derivation| {
        if (!std.mem.eql(u8, &derivation.fingerprint, &keys.master_fingerprint)) continue;
        const node = try keys.derive(derivation.path);
        if (node.keyIsPrivate()) {
            const pub_key = try node.publicKey();
            if (matchesKey(utxo, kind, pub_key)) {
                return .{ .private_key = node.key.priv, .public_key = pub_key };
            }
        }
    }

    // 2) 個別に渡された鍵
    for (keys.raw_keys) |raw| {
        if (matchesKey(utxo, kind, raw.public_key)) return raw;
    }

    // 3) 標準的な派生パスを走査する
    if (keys.master != null) {
        const purposes = [_]u32{ 84, 49, 44 };
        for (purposes) |purpose| {
            for ([_]u32{ 0, 1 }) |change| {
                var i: u32 = 0;
                while (i <= keys.max_index) : (i += 1) {
                    const path = [_]u32{
                        purpose | bip32.hardened,
                        0 | bip32.hardened,
                        0 | bip32.hardened,
                        change,
                        i,
                    };
                    const node = keys.derive(&path) catch continue;
                    if (!node.keyIsPrivate()) continue;
                    const pub_key = try node.publicKey();
                    if (matchesKey(utxo, kind, pub_key)) {
                        return .{ .private_key = node.key.priv, .public_key = pub_key };
                    }
                }
            }
        }
    }
    _ = allocator;
    return null;
}

/// 公開鍵がこの UTXO の鍵として妥当かどうか。
fn matchesKey(utxo: ResolvedUtxo, kind: ScriptKind, pub_key: [33]u8) bool {
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);
    switch (kind) {
        .p2wpkh => return utxo.script_pubkey.len == 22 and
            std.mem.eql(u8, utxo.script_pubkey[2..22], &h160),
        .p2pkh => return utxo.script_pubkey.len == 25 and
            std.mem.eql(u8, utxo.script_pubkey[3..23], &h160),
        .p2sh => {
            // P2SH-P2WPKH: redeemScript = 0014{h160}
            var redeem: [22]u8 = undefined;
            redeem[0] = 0x00;
            redeem[1] = 0x14;
            @memcpy(redeem[2..22], &h160);
            var redeem_hash: [20]u8 = undefined;
            hashes.hash160(&redeem_hash, &redeem);
            return utxo.script_pubkey.len == 23 and
                std.mem.eql(u8, utxo.script_pubkey[2..22], &redeem_hash);
        },
        .p2pk => return utxo.script_pubkey.len == 35 and
            std.mem.eql(u8, utxo.script_pubkey[1..34], &pub_key),
        else => return false,
    }
}

fn sighashForInput(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
    utxo: ResolvedUtxo,
    kind: ScriptKind,
    pub_key: [33]u8,
) Error![32]u8 {
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);

    switch (kind) {
        .p2wpkh => {
            const script_code = sighash.p2wpkhScriptCode(h160);
            return sighash.segwitV0Sighash(
                allocator,
                psbt.unsigned_tx,
                index,
                &script_code,
                utxo.amount,
                SIGHASH_ALL,
            );
        },
        .p2sh => {
            // P2SH-P2WPKH として扱う（redeemScript が一致することを確認済み）
            const script_code = sighash.p2wpkhScriptCode(h160);
            return sighash.segwitV0Sighash(
                allocator,
                psbt.unsigned_tx,
                index,
                &script_code,
                utxo.amount,
                SIGHASH_ALL,
            );
        },
        .p2pkh => return sighash.legacySighash(
            allocator,
            psbt.unsigned_tx,
            index,
            utxo.script_pubkey,
            SIGHASH_ALL,
        ),
        .p2pk => return sighash.legacySighash(
            allocator,
            psbt.unsigned_tx,
            index,
            utxo.script_pubkey,
            SIGHASH_ALL,
        ),
        else => return error.UnsupportedSighash,
    }
}

/// 出力が自分の**お釣り用**の鍵に属するかを判定し、該当する index を返す。
///
/// 判定は BIP84/49/44 の change 鎖（`.../1/i`）のみを対象にする。
/// **受取アドレス（`.../0/i`）への送金はお釣りとして扱わない**（誤判定を避けるため）。
fn findChangeOutputs(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: KeySource,
) Error![]const usize {
    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(allocator);
    if (keys.master == null) return result.toOwnedSlice(allocator);

    for (psbt.unsigned_tx.outputs, 0..) |output, index| {
        const kind = detectScriptKind(output.script_pubkey);
        if (kind == .unknown) continue;
        if (try outputMatchesChangeKey(keys, output.script_pubkey, kind)) {
            try result.append(allocator, index);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn outputMatchesChangeKey(keys: KeySource, script: []const u8, kind: ScriptKind) Error!bool {
    const purposes = [_]u32{ 84, 49, 44 };
    for (purposes) |purpose| {
        var i: u32 = 0;
        while (i <= keys.max_index) : (i += 1) {
            const path = [_]u32{
                purpose | bip32.hardened,
                0 | bip32.hardened,
                0 | bip32.hardened,
                1, // change
                i,
            };
            const node = keys.derive(&path) catch continue;
            const pub_key = try node.publicKey();
            if (matchesKey(.{ .script_pubkey = script, .amount = 0 }, kind, pub_key)) {
                return true;
            }
        }
    }
    return false;
}

/// 署名を埋めて最終トランザクションを組み立てる。
fn finalize(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    signatures: []const ?[]const u8,
    keys: []const ?KeySource.RawKey,
    resolved: []const ?ResolvedUtxo,
) Error![]const u8 {
    const tx = psbt.unsigned_tx;
    const inputs = try allocator.alloc(transaction.TxIn, tx.inputs.len);
    @memcpy(inputs, tx.inputs);

    for (inputs, 0..) |*input, index| {
        const signature = signatures[index] orelse return error.NoMatchingKey;
        const key = keys[index] orelse return error.NoMatchingKey;
        const utxo = resolved[index] orelse return error.InvalidPsbt;
        const kind = detectScriptKind(utxo.script_pubkey);

        // 公開鍵は安定した領域にコピーしてから witness に入れる。
        // ローカル変数のアドレスを渡すと、ループを抜けた時点で不正な参照になる。
        const pub_key_copy = try allocator.dupe(u8, &key.public_key);

        switch (kind) {
            .p2wpkh => {
                const witness = try allocator.alloc([]const u8, 2);
                witness[0] = signature;
                witness[1] = pub_key_copy;
                input.script_sig = &.{};
                input.witness = witness;
            },
            .p2sh => {
                // scriptSig = push(redeemScript), witness = [sig, pubkey]
                var redeem: [22]u8 = undefined;
                redeem[0] = 0x00;
                redeem[1] = 0x14;
                var h160: [20]u8 = undefined;
                hashes.hash160(&h160, &key.public_key);
                @memcpy(redeem[2..22], &h160);
                input.script_sig = try pushData(allocator, &redeem);
                const witness = try allocator.alloc([]const u8, 2);
                witness[0] = signature;
                witness[1] = pub_key_copy;
                input.witness = witness;
            },
            .p2pkh => {
                const sig_push = try pushData(allocator, signature);
                const pub_push = try pushData(allocator, &key.public_key);
                const script_sig = try allocator.alloc(u8, sig_push.len + pub_push.len);
                @memcpy(script_sig[0..sig_push.len], sig_push);
                @memcpy(script_sig[sig_push.len..], pub_push);
                input.script_sig = script_sig;
                input.witness = &.{};
            },
            .p2pk => {
                input.script_sig = try pushData(allocator, signature);
                input.witness = &.{};
            },
            else => return error.UnsupportedSighash,
        }
    }

    const final = transaction.Transaction{
        .version = tx.version,
        .inputs = inputs,
        .outputs = tx.outputs,
        .lock_time = tx.lock_time,
        .has_witness = true,
    };
    return final.serialize(allocator, true);
}

/// Bitcoin のスクリプトにおける「データを push する」表現。
fn pushData(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (data.len < 0x4C) {
        try out.append(allocator, @intCast(data.len));
    } else if (data.len <= 0xFF) {
        try out.append(allocator, 0x4C);
        try out.append(allocator, @intCast(data.len));
    } else if (data.len <= 0xFFFF) {
        try out.append(allocator, 0x4D);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(data.len), .little);
        try out.appendSlice(allocator, &buf);
    } else {
        return error.BufferTooSmall;
    }
    try out.appendSlice(allocator, data);
    return out.toOwnedSlice(allocator);
}

/// 署名済み PSBT を含む一連の結果。
pub const SignedPsbt = struct {
    /// 署名の詳細（手数料・お釣り・署名できなかった入力など）。
    result: SignResult,
    /// ホストに返す署名済み PSBT（元のフィールドを保持する）。
    signed_psbt: []const u8,
};

/// PSBT のバイト列を受け取り、署名して署名済み PSBT を返す。
///
/// エアギャップ運用では「バイト列を受けてバイト列を返す」形が基本になるため、
/// 入出力をここで完結させる（QR / SD / USB のどの経路でも同じ関数を使う）。
pub fn signPsbtBytes(
    allocator: std.mem.Allocator,
    psbt_bytes: []const u8,
    keys: KeySource,
) Error!SignedPsbt {
    const psbt = try psbt_mod.Psbt.parse(allocator, psbt_bytes);
    const result = try sign(allocator, psbt, keys);

    // 入力ごとの追加署名をまとめる。
    // 公開鍵は `result.partial_sigs` の要素を指す（安定した領域）ので、
    // ループのローカル変数のアドレスを渡してはならない。
    const sigs = try allocator.alloc([]const psbt_mod.PartialSig, psbt.inputs.len);
    for (sigs) |*slot| slot.* = &.{};
    for (result.partial_sigs, 0..) |partial, i| {
        const one = try allocator.alloc(psbt_mod.PartialSig, 1);
        one[0] = .{
            .pubkey = &result.partial_sigs[i].pubkey,
            .signature = partial.signature,
        };
        sigs[partial.index] = one;
    }

    return .{
        .result = result,
        .signed_psbt = try psbt_mod.Psbt.serialize(allocator, psbt, sigs),
    };
}

/// seed から鍵集合を作る（BIP32 マスター鍵）。
pub fn keysFromMnemonic(mnemonic: []const u8, passphrase: []const u8) Error!KeySource {
    var seed: [64]u8 = undefined;
    defer @memset(&seed, 0); // 使い終わった seed は即座に消す
    try bip39.mnemonicToSeed(&seed, mnemonic, passphrase);
    return KeySource.fromSeed(&seed);
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "scriptPubKey の種類判定" {
    var p2pkh: [25]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2pkh, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    try testing.expectEqual(ScriptKind.p2pkh, detectScriptKind(&p2pkh));

    var p2wpkh: [22]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2wpkh, "0014000102030405060708090a0b0c0d0e0f10111213");
    try testing.expectEqual(ScriptKind.p2wpkh, detectScriptKind(&p2wpkh));

    var p2sh: [23]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2sh, "a914000102030405060708090a0b0c0d0e0f1011121387");
    try testing.expectEqual(ScriptKind.p2sh, detectScriptKind(&p2sh));

    var p2tr: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &p2tr,
        "5120000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    );
    try testing.expectEqual(ScriptKind.p2tr, detectScriptKind(&p2tr));

    var p2pk: [35]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &p2pk,
        "21025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357ac",
    );
    try testing.expectEqual(ScriptKind.p2pk, detectScriptKind(&p2pk));

    try testing.expectEqual(ScriptKind.unknown, detectScriptKind(&[_]u8{0x6a}));
    try testing.expectEqual(ScriptKind.unknown, detectScriptKind(&[_]u8{}));
}

test "pushData の表現" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const short = try pushData(allocator, &[_]u8{ 0xAA, 0xBB });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0xAA, 0xBB }, short);

    var big: [80]u8 = @splat(0x11);
    const long = try pushData(allocator, &big);
    try testing.expectEqual(@as(u8, 0x4C), long[0]);
    try testing.expectEqual(@as(u8, 80), long[1]);
    try testing.expectEqual(@as(usize, 82), long.len);
}

test "mnemonic から鍵集合を作れる（BIP84 テストベクタのアドレスと一致）" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const keys = try keysFromMnemonic(mnemonic, "");

    var program: [40]u8 = undefined;
    const decoded = try bech32.decodeSegwit(
        "bc",
        &program,
        "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
    );

    const node = try keys.derive(&[_]u32{
        84 | bip32.hardened, 0 | bip32.hardened, 0 | bip32.hardened, 0, 0,
    });
    const pub_key = try node.publicKey();
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);
    try testing.expectEqualSlices(u8, decoded.program, &h160);
}

test "seed から BIP84 の鍵を導出し、既知の witness program と一致する" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var seed: [64]u8 = undefined;
    try bip39.mnemonicToSeed(&seed, mnemonic, "");
    const keys = try KeySource.fromSeed(&seed);

    // m/84'/0'/0'/0/0 の公開鍵の HASH160 が、BIP84 テストベクタのアドレスの
    // witness program と一致することを確認する。
    // アドレス文字列は公式ベクタ、デコードは BIP173 ベクタで検証済みの自前実装なので、
    // 導出 → アドレス の経路に対する相互検証になる。
    const node = try keys.derive(&[_]u32{
        84 | bip32.hardened, 0 | bip32.hardened, 0 | bip32.hardened, 0, 0,
    });
    const pub_key = try node.publicKey();
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);

    var program: [40]u8 = undefined;
    const decoded = try bech32.decodeSegwit(
        "bc",
        &program,
        "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", // BIP84 テストベクタ
    );
    try testing.expectEqual(@as(u8, 0), decoded.witness_version);
    try testing.expectEqualSlices(u8, decoded.program, &h160);

    // マスター鍵の fingerprint が再現性をもって得られること
    const master = try bip32.ExtendedKey.fromSeed(&seed, .xprv);
    try testing.expectEqualSlices(
        u8,
        &(try master.fingerprint()),
        &keys.master_fingerprint,
    );
}
