//! Interoperability test against Bitcoin Core (2-of-3 P2WSH multisig).
//!
//! Vector: tests/vectors/core_multisig.json
//!
//! Procedure (frozen exactly as it was run on regtest):
//!   1. Create a 2-of-3 address with Core's `createmultisig`, send funds to it and get a UTXO
//!   2. Build a transaction with Core's `createpsbt`
//!   3. Sign it with two keys in this implementation (in witnessScript public key order) and write out the signed PSBT
//!   4. Core's `finalizepsbt` returns `complete: true`, and its output hex
//!      **matches byte for byte** this implementation's final transaction
//!   5. Core's `testmempoolaccept` returns `allowed: true`
//!
//! Multisig is a setup where one device breaking or being stolen does not lose the funds,
//! and it is the core of this project's recommended operation ([docs/05-threat-model.md]).
//! P2WSH signatures must be ordered **in the same order as the public keys appearing in
//! the witnessScript**; get this wrong and Core will not accept them.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

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

test "produces a 2-of-3 multisig signature Bitcoin Core accepts" {
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

    // --- the witnessScript matches Core's and can be parsed ---
    const parsed_script = try zhww.btc_multisig.parseWitnessScript(witness_script);
    try testing.expectEqual(required, parsed_script.required);

    // The scriptPubKey must match Core's witness_utxo
    const script_pubkey = zhww.btc_multisig.scriptPubKey(witness_script);
    try testing.expectEqualSlices(u8, utxo_script, &script_pubkey);

    // --- assemble the unsigned transaction ---
    const display_txid = try hexAlloc(allocator, root.get("prevout_txid").?.string);
    var wire_txid: [32]u8 = undefined;
    for (0..32) |i| wire_txid[i] = display_txid[31 - i]; // display order -> serialization order

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

    // --- sign with two of the keys ---
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
        signers[0..2], // 2 of the 3 (2-of-3)
    );
    try testing.expectEqual(required, signatures.len);

    // Supplying all three private keys to a 2-of-3 signer must still emit exactly two
    // signatures; a third witness item would make the final transaction non-standard.
    const all_signatures = try zhww.btc_multisig.signP2wsh(
        allocator,
        tx,
        0,
        witness_script,
        input_amount,
        &signers,
    );
    try testing.expectEqual(required, all_signatures.len);

    // --- assemble the final transaction and compare it against Core's output ---
    const witness = try zhww.btc_multisig.buildWitness(allocator, signatures, witness_script);
    try testing.expectEqual(@as(usize, required + 2), witness.len);
    try testing.expectEqual(@as(usize, 0), witness[0].len); // the first element is empty

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

    // --- verify each signature against an independently recomputed sighash ---
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

test "multisig: rejects when there are not enough signatures" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;
    const witness_script = try hexAlloc(allocator, root.get("witness_script").?.string);

    // With only keys that are not in the witnessScript, signing is impossible
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
    outputs[0] = .{ .value = 1000, .script_pubkey = &[_]u8{0x6a} };
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
