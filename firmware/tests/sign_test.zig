//! Integration tests for signing and finalization.
//!
//! Paths that have no external test vector (P2PKH and P2SH-P2WPKH finalization, key discovery,
//! fee computation, change detection) are verified with **self-consistently assembled PSBTs**.
//!
//! Verification approach:
//!   1. Create a funding transaction, then a spending transaction that references its txid
//!      (this also exercises non_witness_utxo txid matching)
//!   2. Assemble a PSBT with 3 kinds of input (P2WPKH / P2PKH / P2SH-P2WPKH)
//!   3. Sign and finalize it
//!   4. **Verify each input's signature against a sighash recomputed independently on the
//!      test side** (without using any internal value of the implementation)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const HARDENED = zhww.bip32.hardened;
const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";

fn p2wpkhScript(out: *[22]u8, pub_key: [33]u8) void {
    var h160: [20]u8 = undefined;
    zhww.hashes.hash160(&h160, &pub_key);
    out[0] = 0x00;
    out[1] = 0x14;
    @memcpy(out[2..22], &h160);
}

fn p2pkhScript(out: *[25]u8, pub_key: [33]u8) void {
    var h160: [20]u8 = undefined;
    zhww.hashes.hash160(&h160, &pub_key);
    out[0] = 0x76;
    out[1] = 0xa9;
    out[2] = 0x14;
    @memcpy(out[3..23], &h160);
    out[23] = 0x88;
    out[24] = 0xac;
}

fn p2shP2wpkhScript(out: *[23]u8, redeem: *[22]u8, pub_key: [33]u8) void {
    var h160: [20]u8 = undefined;
    zhww.hashes.hash160(&h160, &pub_key);
    redeem[0] = 0x00;
    redeem[1] = 0x14;
    @memcpy(redeem[2..22], &h160);
    var redeem_hash: [20]u8 = undefined;
    zhww.hashes.hash160(&redeem_hash, redeem);
    out[0] = 0xa9;
    out[1] = 0x14;
    @memcpy(out[2..22], &redeem_hash);
    out[22] = 0x87;
}

test "signs and finalizes 3 kinds of input (P2WPKH / P2PKH / P2SH-P2WPKH)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // --- keys ---
    var seed: [64]u8 = undefined;
    try zhww.bip39.mnemonicToSeed(&seed, mnemonic, "");
    const keys = try zhww.btc_sign.KeySource.fromSeed(&seed);

    const receive84 = try keys.derive(&[_]u32{ 84 | HARDENED, 0 | HARDENED, 0 | HARDENED, 0, 0 });
    const pub84 = try receive84.publicKey();
    var spk84: [22]u8 = undefined;
    p2wpkhScript(&spk84, pub84);

    const receive44 = try keys.derive(&[_]u32{ 44 | HARDENED, 0 | HARDENED, 0 | HARDENED, 0, 0 });
    const pub44 = try receive44.publicKey();
    var spk44: [25]u8 = undefined;
    p2pkhScript(&spk44, pub44);

    const receive49 = try keys.derive(&[_]u32{ 49 | HARDENED, 0 | HARDENED, 0 | HARDENED, 0, 0 });
    const pub49 = try receive49.publicKey();
    var spk49: [23]u8 = undefined;
    var redeem49: [22]u8 = undefined;
    p2shP2wpkhScript(&spk49, &redeem49, pub49);

    // Receive address (must not be misjudged as change)
    const receive84_1 = try keys.derive(&[_]u32{ 84 | HARDENED, 0 | HARDENED, 0 | HARDENED, 0, 1 });
    const pub84_1 = try receive84_1.publicKey();
    var spk84_1: [22]u8 = undefined;
    p2wpkhScript(&spk84_1, pub84_1);

    // For change (the BIP84 change chain)
    const change84 = try keys.derive(&[_]u32{ 84 | HARDENED, 0 | HARDENED, 0 | HARDENED, 1, 0 });
    const pub_change = try change84.publicKey();
    var spk_change: [22]u8 = undefined;
    p2wpkhScript(&spk_change, pub_change);

    // --- funding transaction (with 3 outputs) ---
    var funding_prev_txid: [32]u8 = undefined;
    for (&funding_prev_txid, 0..) |*byte, i| byte.* = @intCast(i + 1);

    const funding_inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    funding_inputs[0] = .{
        .prevout = .{ .txid = funding_prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    const funding_outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 3);
    funding_outputs[0] = .{ .value = 50_000_000, .script_pubkey = &spk84 };
    funding_outputs[1] = .{ .value = 30_000_000, .script_pubkey = &spk44 };
    funding_outputs[2] = .{ .value = 20_000_000, .script_pubkey = &spk49 };

    const funding = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = funding_inputs,
        .outputs = funding_outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const funding_txid = try funding.txid(allocator);
    const funding_bytes = try funding.serialize(allocator, false);

    // --- spending transaction (3 inputs / 2 outputs) ---
    const spend_inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 3);
    for (spend_inputs, 0..) |*input, i| {
        input.* = .{
            .prevout = .{ .txid = funding_txid, .vout = @intCast(i) },
            .script_sig = &.{},
            .sequence = 0xFFFFFFFD,
            .witness = &.{},
        };
    }
    const spend_outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 2);
    spend_outputs[0] = .{ .value = 99_400_000, .script_pubkey = &spk84_1 }; // to the receive address
    spend_outputs[1] = .{ .value = 550_000, .script_pubkey = &spk_change }; // change

    const spend = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = spend_inputs,
        .outputs = spend_outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const spend_bytes = try spend.serialize(allocator, false);

    // --- build the PSBT ---
    var psbt_bytes = std.ArrayList(u8).empty;
    defer psbt_bytes.deinit(allocator);
    try psbt_bytes.appendSlice(allocator, &zhww.btc_psbt.magic);

    // Global: unsigned tx
    try psbt_bytes.append(allocator, 1);
    try psbt_bytes.append(allocator, 0x00);
    try zhww.btc_transaction.writeVarInt(&psbt_bytes, allocator, spend_bytes.len);
    try psbt_bytes.appendSlice(allocator, spend_bytes);
    try psbt_bytes.append(allocator, 0);

    // Input 0: P2WPKH -> witness_utxo
    try appendWitnessUtxo(allocator, &psbt_bytes, 50_000_000, &spk84);
    try psbt_bytes.append(allocator, 0); // end of input map

    // Input 1: P2PKH -> non_witness_utxo (the whole funding tx)
    try psbt_bytes.append(allocator, 1);
    try psbt_bytes.append(allocator, 0x00); // PSBT_IN_NON_WITNESS_UTXO
    try zhww.btc_transaction.writeVarInt(&psbt_bytes, allocator, funding_bytes.len);
    try psbt_bytes.appendSlice(allocator, funding_bytes);
    try psbt_bytes.append(allocator, 0); // end of input map

    // Input 2: P2SH-P2WPKH -> witness_utxo + redeemScript
    try appendWitnessUtxo(allocator, &psbt_bytes, 20_000_000, &spk49);
    try psbt_bytes.append(allocator, 1);
    try psbt_bytes.append(allocator, 0x04); // PSBT_IN_REDEEM_SCRIPT
    try zhww.btc_transaction.writeVarInt(&psbt_bytes, allocator, redeem49.len);
    try psbt_bytes.appendSlice(allocator, &redeem49);
    try psbt_bytes.append(allocator, 0); // end of input map

    // Two output maps (empty)
    try psbt_bytes.append(allocator, 0);
    try psbt_bytes.append(allocator, 0);

    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, psbt_bytes.items);
    try testing.expectEqual(@as(usize, 3), psbt.inputs.len);

    // --- signing ---
    const result = try zhww.btc_sign.sign(allocator, psbt, keys);

    try testing.expectEqual(@as(usize, 3), result.partial_sigs.len);
    try testing.expectEqual(@as(usize, 0), result.unsigned_inputs.len);

    // fee = 100,000,000 - 99,400,000 - 550,000
    try testing.expectEqual(@as(?u64, 50_000), result.fee);
    try testing.expectEqual(@as(?u64, 100_000_000), result.total_input);
    try testing.expectEqual(@as(u64, 99_950_000), result.total_output);

    // Only output 1 is change (output 0, to the receive address, is not included)
    try testing.expectEqual(@as(usize, 1), result.change_outputs.len);
    try testing.expectEqual(@as(usize, 1), result.change_outputs[0]);

    // --- verify each signature against a sighash **independently** recomputed on the test side ---
    for (result.partial_sigs) |partial| {
        const index = partial.index;
        const amount: u64 = switch (index) {
            0 => 50_000_000,
            1 => 30_000_000,
            2 => 20_000_000,
            else => unreachable,
        };
        const message = switch (index) {
            0 => blk: {
                const script_code = zhww.btc_sighash.p2wpkhScriptCode(blk2: {
                    var h: [20]u8 = undefined;
                    zhww.hashes.hash160(&h, &pub84);
                    break :blk2 h;
                });
                break :blk try zhww.btc_sighash.segwitV0Sighash(
                    allocator,
                    spend,
                    0,
                    &script_code,
                    amount,
                    zhww.btc_sighash.SIGHASH_ALL,
                );
            },
            1 => try zhww.btc_sighash.legacySighash(
                allocator,
                spend,
                1,
                &spk44,
                zhww.btc_sighash.SIGHASH_ALL,
            ),
            2 => blk: {
                const script_code = zhww.btc_sighash.p2wpkhScriptCode(blk2: {
                    var h: [20]u8 = undefined;
                    zhww.hashes.hash160(&h, &pub49);
                    break :blk2 h;
                });
                break :blk try zhww.btc_sighash.segwitV0Sighash(
                    allocator,
                    spend,
                    2,
                    &script_code,
                    amount,
                    zhww.btc_sighash.SIGHASH_ALL,
                );
            },
            else => unreachable,
        };

        // Parse and verify the DER signature (excluding the trailing sighash type)
        const der = partial.signature[0 .. partial.signature.len - 1];
        try testing.expectEqual(@as(u8, 0x01), partial.signature[partial.signature.len - 1]);
        const signature = try zhww.secp256k1.parseDer(der);
        try testing.expect(try zhww.secp256k1.verify(&signature, message, partial.pubkey));
    }

    // --- finalization ---
    const final_bytes = result.final_tx.?;
    const final_tx = try zhww.btc_transaction.Transaction.parse(allocator, final_bytes);
    try testing.expectEqual(@as(usize, 3), final_tx.inputs.len);

    // Input 0 (P2WPKH): scriptSig is empty, witness is [signature, public key]
    try testing.expectEqual(@as(usize, 0), final_tx.inputs[0].script_sig.len);
    try testing.expectEqual(@as(usize, 2), final_tx.inputs[0].witness.len);
    try testing.expectEqualSlices(u8, &pub84, final_tx.inputs[0].witness[1]);

    // Input 1 (P2PKH): scriptSig is [push signature][push public key], no witness
    try testing.expectEqual(@as(usize, 0), final_tx.inputs[1].witness.len);
    try testing.expectEqual(@as(usize, 1 + 72 + 1 + 33), final_tx.inputs[1].script_sig.len);
    try testing.expectEqual(@as(u8, 72), final_tx.inputs[1].script_sig[0]);
    try testing.expectEqual(@as(u8, 33), final_tx.inputs[1].script_sig[73]);
    try testing.expectEqualSlices(u8, &pub44, final_tx.inputs[1].script_sig[74..107]);

    // Input 2 (P2SH-P2WPKH): scriptSig pushes the redeemScript, witness is [signature, public key]
    try testing.expectEqual(@as(usize, 23), final_tx.inputs[2].script_sig.len);
    try testing.expectEqual(@as(u8, 22), final_tx.inputs[2].script_sig[0]);
    try testing.expectEqualSlices(u8, &redeem49, final_tx.inputs[2].script_sig[1..23]);
    try testing.expectEqual(@as(usize, 2), final_tx.inputs[2].witness.len);
    try testing.expectEqualSlices(u8, &pub49, final_tx.inputs[2].witness[1]);

    // Serialization round-trips identically
    const reserialized = try final_tx.serialize(allocator, true);
    try testing.expectEqualSlices(u8, final_bytes, reserialized);

    // --- the workflow function (bytes -> signed PSBT) must give the same result ---
    const workflow = try zhww.btc_sign.signPsbtBytes(allocator, psbt_bytes.items, keys);
    try testing.expectEqual(@as(usize, 3), workflow.result.partial_sigs.len);
    try testing.expectEqual(@as(?u64, 50_000), workflow.result.fee);
    try testing.expectEqual(@as(?u64, 100_000_000), workflow.result.total_input);
    try testing.expectEqualSlices(u8, final_bytes, workflow.result.final_tx.?);
    try testing.expect(workflow.signed_psbt.len > psbt_bytes.items.len);

    // Reading the signed PSBT back shows partial sigs on all 3 inputs
    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, workflow.signed_psbt);
    for (reparsed.inputs) |input| {
        try testing.expectEqual(@as(usize, 1), input.partial_sigs.len);
    }
    // The signatures read back match the original signatures
    try testing.expectEqualSlices(
        u8,
        reparsed.inputs[0].partial_sigs[0].signature,
        workflow.result.partial_sigs[0].signature,
    );

    // The requested sighash is part of the signing request and must not be ignored.
    var modified = psbt;
    const modified_inputs = try allocator.dupe(zhww.btc_psbt.Input, psbt.inputs);
    modified.inputs = modified_inputs;
    modified.inputs[0].sighash_type = zhww.btc_sighash.SIGHASH_NONE;
    try testing.expectError(error.UnsupportedSighash, zhww.btc_sign.sign(allocator, modified, keys));

    // A finalized input must not receive another partial signature.
    modified.inputs[0].sighash_type = null;
    modified.inputs[0].final_script_witness = &.{};
    try testing.expectError(error.InvalidPsbt, zhww.btc_sign.sign(allocator, modified, keys));

    // For the legacy input, an attacker-supplied witness_utxo must not override the previous
    // transaction used by the signer/display to determine the amount and script.
    modified.inputs[0].final_script_witness = null;
    modified.inputs[1].witness_utxo = .{ .value = 1, .script_pubkey = &spk84 };
    try testing.expectError(error.InvalidPsbt, zhww.btc_sign.sign(allocator, modified, keys));
    try testing.expectError(error.InvalidPsbt, zhww.btc_sign.utxoForDisplay(allocator, modified, 1));
}

fn appendWitnessUtxo(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    value: u64,
    script_pubkey: []const u8,
) !void {
    var utxo = std.ArrayList(u8).empty;
    defer utxo.deinit(allocator);
    var value_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &value_le, value, .little);
    try utxo.appendSlice(allocator, &value_le);
    try zhww.btc_transaction.writeVarBytes(&utxo, allocator, script_pubkey);

    try out.append(allocator, 1); // keylen
    try out.append(allocator, 0x01); // PSBT_IN_WITNESS_UTXO
    try zhww.btc_transaction.writeVarInt(out, allocator, utxo.items.len);
    try out.appendSlice(allocator, utxo.items);
}
