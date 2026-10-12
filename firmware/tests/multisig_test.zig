//! Bitcoin Core との相互運用テスト（2-of-3 マルチシグ P2WSH）。
//!
//! ベクタ: tests/vectors/core_multisig.json
//!
//! 手順（実際に regtest で実行した内容をそのまま固定している）:
//!   1. Core の `createmultisig` で 2-of-3 のアドレスを作り、送金して UTXO を作る
//!   2. Core の `createpsbt` でトランザクションを作る
//!   3. 本実装で 2 つの鍵で署名し（witnessScript の公開鍵順）、署名済み PSBT を書き出す
//!   4. Core の `finalizepsbt` が `complete: true` を返し、その出力 hex が
//!      本実装の最終トランザクションと**バイト単位で一致**する
//!   5. Core の `testmempoolaccept` が `allowed: true` を返す
//!
//! マルチシグは「1 台が壊れても・盗まれても資産を失わない」ための構成であり、
//! 本プロジェクトの推奨運用の中核である（[docs/05-threat-model.md]）。
//! P2WSH の署名は **witnessScript に現れる公開鍵と同じ順**に並べる必要があり、
//! ここを取り違えると Core が受理しない。

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/core_multisig.json");

fn hexToFixed(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "Bitcoin Core が受理する 2-of-3 マルチシグ署名を作れる" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const witness_script = try hexAlloc(allocator, root.get("witness_script").?.string);
    const utxo_script = try hexAlloc(allocator, root.get("witness_utxo_script").?.string);
    const destination = try hexAlloc(allocator, root.get("destination_script").?.string);
    const input_amount: u64 = @intCast(root.get("input_amount_sats").?.integer);
    const fee: u64 = @intCast(root.get("fee_sats").?.integer);
    const required: usize = @intCast(root.get("required").?.integer);

    // --- witnessScript が Core のものと一致し、解析できること ---
    const parsed_script = try zhww.btc_multisig.parseWitnessScript(witness_script);
    try testing.expectEqual(required, parsed_script.required);

    // scriptPubKey が Core の witness_utxo と一致すること
    const script_pubkey = zhww.btc_multisig.scriptPubKey(witness_script);
    try testing.expectEqualSlices(u8, utxo_script, &script_pubkey);

    // --- 未署名トランザクションを組み立てる ---
    const display_txid = try hexAlloc(allocator, root.get("prevout_txid").?.string);
    var wire_txid: [32]u8 = undefined;
    for (0..32) |i| wire_txid[i] = display_txid[31 - i]; // 表示順 → 直列化順

    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = wire_txid, .vout = @intCast(root.get("prevout_vout").?.integer) },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFD,
        .witness = &.{},
    };
    const outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 1);
    outputs[0] = .{ .value = input_amount - fee, .script_pubkey = destination };
    const tx = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };

    // --- 2 つの鍵で署名する ---
    const keys_json = root.get("keys").?.array.items;
    var signers: [3]zhww.btc_multisig.Signer = undefined;
    for (keys_json, 0..) |entry, i| {
        signers[i] = .{
            .public_key = hexToFixed(33, entry.object.get("pub").?.string),
            .private_key = hexToFixed(32, entry.object.get("priv").?.string),
        };
    }

    const signatures = try zhww.btc_multisig.signP2wsh(
        allocator,
        tx,
        0,
        witness_script,
        input_amount,
        signers[0..2], // 3 つのうち 2 つ（2-of-3）
    );
    try testing.expectEqual(required, signatures.len);

    // --- 最終トランザクションを組み立て、Core の出力と比較する ---
    const witness = try zhww.btc_multisig.buildWitness(allocator, signatures, witness_script);
    try testing.expectEqual(@as(usize, required + 2), witness.len);
    try testing.expectEqual(@as(usize, 0), witness[0].len); // 先頭は空要素

    const final_inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    final_inputs[0] = inputs[0];
    final_inputs[0].witness = witness;
    const final_tx = zhww.btc_transaction.Transaction{
        .version = tx.version,
        .inputs = final_inputs,
        .outputs = tx.outputs,
        .lock_time = tx.lock_time,
        .has_witness = true,
    };
    const final_bytes = try final_tx.serialize(allocator, true);

    const expected = try hexAlloc(allocator, root.get("expected_final_tx").?.string);
    try testing.expectEqualSlices(u8, expected, final_bytes);

    // --- 各署名を独立に再計算した sighash で検証する ---
    const message = try zhww.btc_multisig.sighashForP2wsh(
        allocator,
        tx,
        0,
        witness_script,
        input_amount,
    );
    for (signatures, 0..) |signature, i| {
        try testing.expectEqual(@as(u8, 0x01), signature[signature.len - 1]);
        const parsed_signature = try zhww.secp256k1.parseDer(signature[0 .. signature.len - 1]);
        try testing.expect(try zhww.secp256k1.verify(
            &parsed_signature,
            message,
            parsed_script.slice()[i],
        ));
    }
}

test "マルチシグ: 署名が足りなければ拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;
    const witness_script = try hexAlloc(allocator, root.get("witness_script").?.string);

    // witnessScript に含まれない鍵しか無い場合は署名できない
    const stranger = zhww.btc_multisig.Signer{
        .private_key = hexToFixed(32, "0000000000000000000000000000000000000000000000000000000000000001"),
        .public_key = try zhww.secp256k1.pubKeyCompressed(
            hexToFixed(32, "0000000000000000000000000000000000000000000000000000000000000001"),
        ),
    };

    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = @splat(0), .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    const outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 1);
    outputs[0] = .{ .value = 1000, .script_pubkey = &[_]u8{ 0x6a } };
    const tx = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };

    try testing.expectError(
        error.NoMatchingKey,
        zhww.btc_multisig.signP2wsh(allocator, tx, 0, witness_script, 1000, &[_]zhww.btc_multisig.Signer{stranger}),
    );
    try testing.expectError(
        error.NoMatchingKey,
        zhww.btc_multisig.signP2wsh(allocator, tx, 0, witness_script, 1000, &[_]zhww.btc_multisig.Signer{}),
    );
}
