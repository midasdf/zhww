//! **Byte-for-byte** verification of signatures against BIP143's official test vectors (Native P2WPKH).
//!
//! Vector: tests/vectors/bip143.json
//! Source: https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki
//!
//! This vector contains the unsigned transaction, the expected sighash, the expected DER
//! signature and the signed transaction, so it verifies all of the following at once.
//!
//!   1. Transaction parsing and serialization
//!   2. Legacy sighash (input 0 is P2PK)
//!   3. BIP143 sighash (input 1 is P2WPKH)
//!   4. ECDSA signing (RFC6979 deterministic nonce, low-s, DER encoding)
//!   5. Reproduction of the final signed transaction
//!
//! **RFC6979 is deterministic**, so the same key and the same message always give the same signature.
//! Hence an exact match with the official vector is strong evidence that the implementation is correct.
// SPDX-License-Identifier: GPL-3.0-or-later

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

test "BIP143: BIP143 sighash and DER signature match the official vector (input 1: P2WPKH)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const unsigned_tx = try hexAlloc(allocator, root.get("unsigned_tx").?.string);
    const tx = try zhww.btc_transaction.Transaction.parse(allocator, unsigned_tx);

    // Expected values from the vector
    var expected_sighash: [32]u8 = undefined;
    _ = try hexTo(&expected_sighash, root.get("sighash_input1").?.string);

    // Information for input 1
    const input1 = root.get("input1").?.object;
    var priv: [32]u8 = undefined;
    _ = try hexTo(&priv, input1.get("private_key").?.string);
    const amount: u64 = @intCast(input1.get("value_sats").?.integer);

    // scriptPubKey is `0014{hash160(pubkey)}`, so scriptCode can be built from the public key
    var expected_pubkey: [33]u8 = undefined;
    _ = try hexTo(&expected_pubkey, input1.get("public_key").?.string);
    var pubkey_hash: [20]u8 = undefined;
    zhww.hashes.hash160(&pubkey_hash, &expected_pubkey);

    // The derived public key must match the vector (consistent with the scriptPubKey contents)
    const derived_pubkey = try zhww.secp256k1.pubKeyCompressed(priv);
    try testing.expectEqualSlices(u8, &expected_pubkey, &derived_pubkey);

    const script_code = zhww.btc_sighash.p2wpkhScriptCode(pubkey_hash);
    const script_pubkey = zhww.btc_sighash.p2wpkhScriptPubKey(pubkey_hash);
    var expected_script_pubkey: [22]u8 = undefined;
    _ = try hexTo(&expected_script_pubkey, "00141d0f172a0ecb48aee1be1f2687d2963ae33f71a1");
    try testing.expectEqualSlices(u8, &expected_script_pubkey, &script_pubkey);

    // 1) the sighash matches
    const sighash = try zhww.btc_sighash.segwitV0Sighash(
        allocator,
        tx,
        1,
        &script_code,
        amount,
        zhww.btc_sighash.SIGHASH_ALL,
    );
    try testing.expectEqualSlices(u8, &expected_sighash, &sighash);

    // 2) the DER signature + sighash type match
    const signature = try zhww.secp256k1.sign(sighash, priv);
    var der_buf: [72]u8 = undefined;
    const der = try zhww.secp256k1.serializeDer(&der_buf, &signature);

    var expected_signature: [128]u8 = undefined;
    const expected = try hexTo(&expected_signature, root.get("signature_input1").?.string);
    try testing.expectEqual(@as(usize, expected.len), der.len + 1);
    try testing.expectEqualSlices(u8, expected[0..der.len], der);
    try testing.expectEqual(@as(u8, 0x01), expected[der.len]);

    // 3) the signature we built verifies
    try testing.expect(try zhww.secp256k1.verify(&signature, sighash, derived_pubkey));
}

test "BIP143: fully reproduces the signed transaction" {
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

    // --- input 0: P2PK (legacy sighash) ---
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

    // scriptSig takes the form "push the signature": <push 72> || DER || 0x01
    // (P2PK embeds the public key in the script, so only the signature is pushed)
    const signature_blob = try allocator.alloc(u8, der0.len + 1);
    @memcpy(signature_blob[0..der0.len], der0);
    signature_blob[der0.len] = 0x01;

    const script_sig0 = try allocator.alloc(u8, signature_blob.len + 1);
    script_sig0[0] = @intCast(signature_blob.len); // 0x48 = push 72 bytes
    @memcpy(script_sig0[1..], signature_blob);

    // --- input 1: P2WPKH (BIP143 sighash) ---
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

    // --- fill in the signatures and serialize ---
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

test "BIP143: signing via a PSBT also matches the official vector's signature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const unsigned_tx = try hexAlloc(allocator, root.get("unsigned_tx").?.string);
    const input0 = root.get("input0").?.object;
    const input1 = root.get("input1").?.object;

    var priv0: [32]u8 = undefined;
    _ = try hexTo(&priv0, input0.get("private_key").?.string);
    var pub0: [33]u8 = undefined;
    _ = try hexTo(&pub0, input0.get("prevout_script_pubkey").?.string[2..68]);
    var priv1: [32]u8 = undefined;
    _ = try hexTo(&priv1, input1.get("private_key").?.string);
    var pub1: [33]u8 = undefined;
    _ = try hexTo(&pub1, input1.get("public_key").?.string);

    // --- build the PSBT (give a witness_utxo only to input 1) ---
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &zhww.btc_psbt.magic);
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, 0x00); // PSBT_GLOBAL_UNSIGNED_TX
    try zhww.btc_transaction.writeVarInt(&bytes, allocator, unsigned_tx.len);
    try bytes.appendSlice(allocator, unsigned_tx);
    try bytes.append(allocator, 0); // end of global map

    try bytes.append(allocator, 0); // input 0 map (empty)

    var utxo = std.ArrayList(u8).empty;
    defer utxo.deinit(allocator);
    var value_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &value_le, @intCast(input1.get("value_sats").?.integer), .little);
    try utxo.appendSlice(allocator, &value_le);
    var script1: [22]u8 = undefined;
    _ = try hexTo(&script1, "00141d0f172a0ecb48aee1be1f2687d2963ae33f71a1");
    try zhww.btc_transaction.writeVarBytes(&utxo, allocator, &script1);
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, 0x01); // PSBT_IN_WITNESS_UTXO
    try zhww.btc_transaction.writeVarInt(&bytes, allocator, utxo.items.len);
    try bytes.appendSlice(allocator, utxo.items);
    try bytes.append(allocator, 0); // end of input 1 map

    try bytes.append(allocator, 0); // output 0 map (empty)
    try bytes.append(allocator, 0); // output 1 map (empty)

    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, bytes.items);

    // --- sign with raw keys ---
    const raw_keys = [_]zhww.btc_sign.KeySource.RawKey{
        .{ .private_key = priv0, .public_key = pub0 },
        .{ .private_key = priv1, .public_key = pub1 },
    };
    const keys = zhww.btc_sign.KeySource.fromRawKeys(&raw_keys);
    const result = try zhww.btc_sign.sign(allocator, psbt, keys);

    // Only input 1 can be signed (input 0 has no UTXO information, so it is not signed)
    try testing.expectEqual(@as(usize, 1), result.partial_sigs.len);
    try testing.expectEqual(@as(usize, 1), result.partial_sigs[0].index);
    try testing.expectEqualSlices(u8, &pub1, &result.partial_sigs[0].pubkey);

    // The signature **matches the official vector byte for byte**
    var expected_signature: [128]u8 = undefined;
    const expected = try hexTo(&expected_signature, root.get("signature_input1").?.string);
    try testing.expectEqualSlices(u8, expected, result.partial_sigs[0].signature);

    // Correctly reports the inputs that could not be signed
    try testing.expectEqual(@as(usize, 1), result.unsigned_inputs.len);
    try testing.expectEqual(@as(usize, 0), result.unsigned_inputs[0]);
    try testing.expect(result.final_tx == null);

    // If even one input amount is unknown, no fee is computed
    try testing.expect(result.fee == null);
    try testing.expectEqual(@as(u64, 335_790_000), result.total_output);

    // --- write out the signed PSBT and confirm the signatures survive a re-read ---
    // The public key points into result.partial_sigs (do not pass the address of a loop variable)
    const sigs = try allocator.alloc([]const zhww.btc_psbt.PartialSig, psbt.inputs.len);
    for (sigs) |*slot| slot.* = &.{};
    for (result.partial_sigs, 0..) |partial, i| {
        const one = try allocator.alloc(zhww.btc_psbt.PartialSig, 1);
        one[0] = .{
            .pubkey = &result.partial_sigs[i].pubkey,
            .signature = partial.signature,
        };
        sigs[partial.index] = one;
    }
    const signed_psbt = try zhww.btc_psbt.Psbt.serialize(allocator, psbt, sigs);
    try testing.expect(signed_psbt.len > bytes.items.len);

    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, signed_psbt);
    try testing.expectEqual(@as(usize, 1), reparsed.inputs[1].partial_sigs.len);
    try testing.expectEqualSlices(u8, &pub1, reparsed.inputs[1].partial_sigs[0].pubkey);
    try testing.expectEqualSlices(u8, expected, reparsed.inputs[1].partial_sigs[0].signature);
    // Inputs that were not signed get no partial sig
    try testing.expectEqual(@as(usize, 0), reparsed.inputs[0].partial_sigs.len);
}
