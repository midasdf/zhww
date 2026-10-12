//! Bitcoin Core との相互運用テスト（最も強い検証）。
//!
//! ベクタ: tests/vectors/core_psbt.json
//!
//! 手順（実際に regtest で実行した内容をそのまま固定している）:
//!   1. Bitcoin Core（v31.1.0）の `createpsbt` + `utxoupdatepsbt` で PSBT を作る
//!   2. 本実装で署名して署名済み PSBT を書き出す
//!   3. Core の `finalizepsbt` が `complete: true` を返し、
//!      その出力 hex が本実装の最終トランザクションと**バイト単位で一致**する
//!   4. Core の `testmempoolaccept` が `allowed: true` を返す
//!
//! **他のテストとの違い**: BIP143 のベクタは「仕様どうりに実装できているか」を見るが、
//! このテストは「**実際の Bitcoin Core が我々の署名を有効と判断するか**」を見る。
//! 実装・エンコード・鍵探索・最終化のすべてが噛み合っていなければ通らない。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/core_psbt.json");

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    const buffer = try allocator.alloc(u8, size);
    try decoder.decode(buffer, encoded);
    return buffer;
}

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "Bitcoin Core が生成した PSBT に署名し、Core の署名済みトランザクションと一致する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const psbt_b64 = root.get("unsigned_psbt_base64").?.string;
    const mnemonic = root.get("mnemonic").?.string;
    const expected_tx = root.get("expected_final_tx").?.string;
    const expected_fee: u64 = @intCast(root.get("fee_sats").?.integer);

    // --- Core が作った PSBT を解析する ---
    const psbt_bytes = try decodeBase64(allocator, psbt_b64);
    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, psbt_bytes);
    try testing.expectEqual(@as(usize, 1), psbt.inputs.len);
    try testing.expectEqual(@as(usize, 1), psbt.outputs.len);
    try testing.expect(psbt.inputs[0].witness_utxo != null);

    // --- 署名（鍵は script の一致で見つかる。PSBT に派生情報は無い）---
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, "");
    const outcome = try zhww.btc_sign.signPsbtBytes(allocator, psbt_bytes, keys);

    try testing.expectEqual(@as(usize, 1), outcome.result.partial_sigs.len);
    try testing.expectEqual(@as(usize, 0), outcome.result.unsigned_inputs.len);
    try testing.expectEqual(@as(?u64, expected_fee), outcome.result.fee);

    // --- 最終トランザクションが Core の出力と一致する ---
    const expected_bytes = try hexAlloc(allocator, expected_tx);
    try testing.expectEqualSlices(u8, expected_bytes, outcome.result.final_tx.?);

    // --- 署名を独立に検証する（P2WPKH の BIP143 sighash を再計算）---
    const pub_key = outcome.result.partial_sigs[0].pubkey;
    const utxo = psbt.inputs[0].witness_utxo.?;
    var h160: [20]u8 = undefined;
    zhww.hashes.hash160(&h160, &pub_key);
    try testing.expectEqualSlices(u8, utxo.script_pubkey[2..22], &h160);

    const script_code = zhww.btc_sighash.p2wpkhScriptCode(h160);
    const message = try zhww.btc_sighash.segwitV0Sighash(
        allocator,
        psbt.unsigned_tx,
        0,
        &script_code,
        utxo.value,
        zhww.btc_sighash.SIGHASH_ALL,
    );
    const signature = outcome.result.partial_sigs[0].signature;
    try testing.expectEqual(@as(u8, 0x01), signature[signature.len - 1]);
    const parsed_signature = try zhww.secp256k1.parseDer(signature[0 .. signature.len - 1]);
    try testing.expect(try zhww.secp256k1.verify(&parsed_signature, message, pub_key));

    // --- 署名済み PSBT は Core に渡せる形（再解析できる）---
    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, outcome.signed_psbt);
    try testing.expectEqual(@as(usize, 1), reparsed.inputs[0].partial_sigs.len);
    try testing.expectEqualSlices(
        u8,
        &pub_key,
        reparsed.inputs[0].partial_sigs[0].pubkey,
    );
}
