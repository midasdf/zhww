//! Bitcoin Core との相互運用テスト（Taproot 鍵パス署名）。
//!
//! ベクタ: tests/vectors/core_taproot.json
//!
//! 手順（実際に regtest で実行した内容をそのまま固定している）:
//!   1. Core から BIP86 の P2TR アドレス（`bcrt1p…`）へ送金して UTXO を作る
//!   2. Core の `createpsbt` + `utxoupdatepsbt` でトランザクションを作る
//!   3. 本実装で BIP341 の鍵パス署名を行い、署名済み PSBT を書き出す
//!   4. Core の `finalizepsbt` が `complete: true` を返し、その出力 hex が
//!      本実装の最終トランザクションと**バイト単位で一致**する
//!   5. Core の `testmempoolaccept` が `allowed: true` を返す
//!
//! **BIP143（SegWit v0）との違い**: 署名対象ハッシュは単一の SHA256 を使う
//! `tagged_hash("TapSighash", …)` であり、署名は 64 バイトの Schnorr 署名
//! （末尾に sighash タイプを付けない）。鍵は BIP341 の tweak を適用したものを使う。

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/core_taproot.json");

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const buffer = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(buffer, encoded);
    return buffer;
}

test "Bitcoin Core が受理する Taproot 鍵パス署名を作れる" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const psbt_bytes = try decodeBase64(allocator, root.get("unsigned_psbt_base64").?.string);
    const mnemonic = root.get("mnemonic").?.string;
    const expected_tx = try hexAlloc(allocator, root.get("expected_final_tx").?.string);

    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, psbt_bytes);
    try testing.expectEqual(@as(usize, 1), psbt.inputs.len);

    // --- UTXO は P2TR で、金額が分かっていること ---
    const utxo = psbt.inputs[0].witness_utxo.?;
    try testing.expectEqual(@as(u64, @intCast(root.get("input_amount_sats").?.integer)), utxo.value);
    const output_key = zhww.btc_taproot.outputKeyFromScript(utxo.script_pubkey) orelse {
        return error.InvalidEncoding;
    };

    // --- 鍵の探索: 内部鍵から出力鍵を作り、UTXO と一致するものを探す ---
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, "");
    var private_key: ?[32]u8 = null;
    var index: u32 = 0;
    while (index <= 20) : (index += 1) {
        const node = try keys.derive(&[_]u32{
            86 | zhww.bip32.hardened,
            0 | zhww.bip32.hardened,
            0 | zhww.bip32.hardened,
            0,
            index,
        });
        const internal = try zhww.secp256k1.xonly(try node.publicKey());
        const derived_output = try zhww.secp256k1.taprootOutputKey(internal);
        if (std.mem.eql(u8, &derived_output, &output_key)) {
            private_key = node.key.priv;
            break;
        }
    }
    const priv = private_key orelse return error.NoMatchingKey;

    // --- BIP341 の署名対象ハッシュと署名 ---
    const prevouts = try allocator.alloc(zhww.btc_transaction.TxOut, 1);
    prevouts[0] = utxo;

    const message = try zhww.btc_taproot.sighashKeyPath(
        allocator,
        psbt.unsigned_tx,
        0,
        prevouts,
        zhww.btc_taproot.SIGHASH_DEFAULT,
    );
    const signature = try zhww.btc_taproot.signKeyPath(
        allocator,
        psbt.unsigned_tx,
        0,
        prevouts,
        priv,
    );
    try testing.expect(try zhww.secp256k1.schnorrVerify(signature, message, output_key));

    // --- 最終トランザクションが Core の出力と一致する ---
    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    inputs[0] = psbt.unsigned_tx.inputs[0];
    const witness = try allocator.alloc([]const u8, 1);
    witness[0] = &signature; // 鍵パスは 64 バイトの署名 1 つ
    inputs[0].witness = witness;

    const final_tx = zhww.btc_transaction.Transaction{
        .version = psbt.unsigned_tx.version,
        .inputs = inputs,
        .outputs = psbt.unsigned_tx.outputs,
        .lock_time = psbt.unsigned_tx.lock_time,
        .has_witness = true,
    };
    const final_bytes = try final_tx.serialize(allocator, true);
    try testing.expectEqualSlices(u8, expected_tx, final_bytes);

    // --- 署名済み PSBT（PSBT_IN_TAP_KEY_SIG = 0x13）を書き出し、読み直せること ---
    const fields = try allocator.alloc([]const zhww.btc_psbt.Psbt.Field, psbt.inputs.len);
    const one = try allocator.alloc(zhww.btc_psbt.Psbt.Field, 1);
    one[0] = .{ .key = &[_]u8{zhww.btc_psbt.IN_TAP_KEY_SIG}, .value = &signature };
    fields[0] = one;

    const signed_psbt = try zhww.btc_psbt.Psbt.serializeWith(allocator, psbt, fields);
    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, signed_psbt);
    try testing.expect(signed_psbt.len > psbt_bytes.len);
    try testing.expectEqual(@as(usize, 1), reparsed.inputs.len);

    // 追加フィールドが元のマップを壊していないこと（witness_utxo が残っている）
    try testing.expect(reparsed.inputs[0].witness_utxo != null);
    try testing.expectEqualSlices(
        u8,
        utxo.script_pubkey,
        reparsed.inputs[0].witness_utxo.?.script_pubkey,
    );
}
