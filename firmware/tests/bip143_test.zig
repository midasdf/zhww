//! BIP143 の公式テストベクタ（Native P2WPKH）による、署名の**バイト単位**検証。
//!
//! ベクタ: tests/vectors/bip143.json
//! 出典: https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki
//!
//! このベクタは未署名トランザクション・期待 sighash・期待 DER 署名・署名済み
//! トランザクションの全てを含むため、以下を同時に検証できる。
//!
//!   1. トランザクションの解析と直列化
//!   2. Legacy sighash（input 0 は P2PK）
//!   3. BIP143 sighash（input 1 は P2WPKH）
//!   4. ECDSA 署名（RFC6979 の決定論的 nonce・low-s・DER 符号化）
//!   5. 最終的な署名済みトランザクションの再現
//!
//! **RFC6979 は決定論的**なので、同じ鍵と同じメッセージからは同じ署名が得られる。
//! したがって「署名が公式ベクタと完全一致する」ことが、実装全体の正しさの強い証拠になる。

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip143.json");

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn hexTo(out: []u8, hex: []const u8) ![]u8 {
    return std.fmt.hexToBytes(out, hex);
}

test "BIP143: BIP143 sighash と DER 署名が公式ベクタと一致する（input 1: P2WPKH）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const unsigned_tx = try hexAlloc(allocator, root.get("unsigned_tx").?.string);
    const tx = try zhww.btc_transaction.Transaction.parse(allocator, unsigned_tx);

    // ベクタの期待値
    var expected_sighash: [32]u8 = undefined;
    _ = try hexTo(&expected_sighash, root.get("sighash_input1").?.string);

    // input 1 の情報
    const input1 = root.get("input1").?.object;
    var priv: [32]u8 = undefined;
    _ = try hexTo(&priv, input1.get("private_key").?.string);
    const amount: u64 = @intCast(input1.get("value_sats").?.integer);

    // scriptPubKey は `0014{hash160(pubkey)}` なので、scriptCode を公開鍵から組み立てられる
    var expected_pubkey: [33]u8 = undefined;
    _ = try hexTo(&expected_pubkey, input1.get("public_key").?.string);
    var pubkey_hash: [20]u8 = undefined;
    zhww.hashes.hash160(&pubkey_hash, &expected_pubkey);

    // 導出した公開鍵がベクタと一致すること（scriptPubKey の中身と整合）
    const derived_pubkey = try zhww.secp256k1.pubKeyCompressed(priv);
    try testing.expectEqualSlices(u8, &expected_pubkey, &derived_pubkey);

    const script_code = zhww.btc_sighash.p2wpkhScriptCode(pubkey_hash);
    const script_pubkey = zhww.btc_sighash.p2wpkhScriptPubKey(pubkey_hash);
    var expected_script_pubkey: [22]u8 = undefined;
    _ = try hexTo(&expected_script_pubkey, "00141d0f172a0ecb48aee1be1f2687d2963ae33f71a1");
    try testing.expectEqualSlices(u8, &expected_script_pubkey, &script_pubkey);

    // 1) sighash が一致する
    const sighash = try zhww.btc_sighash.segwitV0Sighash(
        allocator,
        tx,
        1,
        &script_code,
        amount,
        zhww.btc_sighash.SIGHASH_ALL,
    );
    try testing.expectEqualSlices(u8, &expected_sighash, &sighash);

    // 2) DER 署名 + sighash タイプが一致する
    const signature = try zhww.secp256k1.sign(sighash, priv);
    var der_buf: [72]u8 = undefined;
    const der = try zhww.secp256k1.serializeDer(&der_buf, &signature);

    var expected_signature: [128]u8 = undefined;
    const expected = try hexTo(&expected_signature, root.get("signature_input1").?.string);
    try testing.expectEqual(@as(usize, expected.len), der.len + 1);
    try testing.expectEqualSlices(u8, expected[0..der.len], der);
    try testing.expectEqual(@as(u8, 0x01), expected[der.len]);

    // 3) 作った署名が検証を通る
    try testing.expect(try zhww.secp256k1.verify(&signature, sighash, derived_pubkey));
}

test "BIP143: 署名済みトランザクションを完全に再現する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const unsigned_tx = try hexAlloc(allocator, root.get("unsigned_tx").?.string);
    const tx = try zhww.btc_transaction.Transaction.parse(allocator, unsigned_tx);

    const input0 = root.get("input0").?.object;
    const input1 = root.get("input1").?.object;

    var priv0: [32]u8 = undefined;
    _ = try hexTo(&priv0, input0.get("private_key").?.string);
    var priv1: [32]u8 = undefined;
    _ = try hexTo(&priv1, input1.get("private_key").?.string);

    // --- input 0: P2PK（legacy sighash）---
    var script_code0: [35]u8 = undefined;
    _ = try hexTo(&script_code0, input0.get("prevout_script_pubkey").?.string);
    const sighash0 = try zhww.btc_sighash.legacySighash(
        allocator,
        tx,
        0,
        &script_code0,
        zhww.btc_sighash.SIGHASH_ALL,
    );
    const signature0 = try zhww.secp256k1.sign(sighash0, priv0);
    try testing.expect(try zhww.secp256k1.verify(&signature0, sighash0, try zhww.secp256k1.pubKeyCompressed(priv0)));

    var der0_buf: [72]u8 = undefined;
    const der0 = try zhww.secp256k1.serializeDer(&der0_buf, &signature0);

    // scriptSig は「署名を push する」形になる: <push 72> || DER || 0x01
    // （P2PK はスクリプト内に公開鍵が埋まっているため、署名だけを push する）
    const signature_blob = try allocator.alloc(u8, der0.len + 1);
    @memcpy(signature_blob[0..der0.len], der0);
    signature_blob[der0.len] = 0x01;

    const script_sig0 = try allocator.alloc(u8, signature_blob.len + 1);
    script_sig0[0] = @intCast(signature_blob.len); // 0x48 = 72 バイトを push
    @memcpy(script_sig0[1..], signature_blob);

    // --- input 1: P2WPKH（BIP143 sighash）---
    var pubkey1: [33]u8 = undefined;
    _ = try hexTo(&pubkey1, input1.get("public_key").?.string);
    var pubkey_hash1: [20]u8 = undefined;
    zhww.hashes.hash160(&pubkey_hash1, &pubkey1);
    const script_code1 = zhww.btc_sighash.p2wpkhScriptCode(pubkey_hash1);
    const sighash1 = try zhww.btc_sighash.segwitV0Sighash(
        allocator,
        tx,
        1,
        &script_code1,
        @intCast(input1.get("value_sats").?.integer),
        zhww.btc_sighash.SIGHASH_ALL,
    );
    const signature1 = try zhww.secp256k1.sign(sighash1, priv1);
    var der1_buf: [72]u8 = undefined;
    const der1 = try zhww.secp256k1.serializeDer(&der1_buf, &signature1);

    const witness_signature = try allocator.alloc(u8, der1.len + 1);
    @memcpy(witness_signature[0..der1.len], der1);
    witness_signature[der1.len] = 0x01;

    // --- 署名を埋めて直列化する ---
    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, tx.inputs.len);
    @memcpy(inputs, tx.inputs);
    inputs[0].script_sig = script_sig0;
    const witness0: []const []const u8 = &.{};
    inputs[0].witness = witness0;
    const witness1 = try allocator.alloc([]const u8, 2);
    witness1[0] = witness_signature;
    witness1[1] = &pubkey1;
    inputs[1].witness = witness1;

    const signed = zhww.btc_transaction.Transaction{
        .version = tx.version,
        .inputs = inputs,
        .outputs = tx.outputs,
        .lock_time = tx.lock_time,
        .has_witness = true,
    };

    const serialized = try signed.serialize(allocator, true);
    const expected_signed = try hexAlloc(allocator, root.get("signed_tx").?.string);
    try testing.expectEqualSlices(u8, expected_signed, serialized);
}
