//! Interoperability test against Bitcoin Core (the strongest verification).
//!
//! Vector: tests/vectors/core_psbt.json
//!
//! Procedure (frozen exactly as it was run on regtest):
//!   1. Build a PSBT with Bitcoin Core (v31.1.0) `createpsbt` + `utxoupdatepsbt`
//!   2. Sign it with this implementation and write out the signed PSBT
//!   3. Core's `finalizepsbt` returns `complete: true`, and its output hex
//!      **matches byte for byte** this implementation's final transaction
//!   4. Core's `testmempoolaccept` returns `allowed: true`
//!
//! **How this differs from the other tests**: the BIP143 vectors check whether the
//! implementation follows the spec, while this test checks **whether real Bitcoin Core
//! considers our signature valid**. It only passes when implementation, encoding, key discovery and finalization all mesh.
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

test "signs a PSBT created by Bitcoin Core and matches Core's signed transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    const psbt_b64 = root.get("unsigned_psbt_base64").?.string;
    const mnemonic = root.get("mnemonic").?.string;
    const expected_tx = root.get("expected_final_tx").?.string;
    const expected_fee: u64 = @intCast(root.get("fee_sats").?.integer);

    // --- parse the PSBT Core created ---
    const psbt_bytes = try decodeBase64(allocator, psbt_b64);
    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, psbt_bytes);
    try testing.expectEqual(@as(usize, 1), psbt.inputs.len);
    try testing.expectEqual(@as(usize, 1), psbt.outputs.len);
    try testing.expect(psbt.inputs[0].witness_utxo != null);

    // --- signing (the key is found by matching the script; the PSBT has no derivation info) ---
    const keys = try zhww.btc_sign.keysFromMnemonic(mnemonic, "");
    const outcome = try zhww.btc_sign.signPsbtBytes(allocator, psbt_bytes, keys);

    try testing.expectEqual(@as(usize, 1), outcome.result.partial_sigs.len);
    try testing.expectEqual(@as(usize, 0), outcome.result.unsigned_inputs.len);
    try testing.expectEqual(@as(?u64, expected_fee), outcome.result.fee);

    // --- the final transaction matches Core's output ---
    const expected_bytes = try hexAlloc(allocator, expected_tx);
    try testing.expectEqualSlices(u8, expected_bytes, outcome.result.final_tx.?);

    // --- verify the signature independently (recompute the P2WPKH BIP143 sighash) ---
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

    // --- the signed PSBT is in a form Core accepts (it can be parsed again) ---
    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, outcome.signed_psbt);
    try testing.expectEqual(@as(usize, 1), reparsed.inputs[0].partial_sigs.len);
    try testing.expectEqualSlices(
        u8,
        &pub_key,
        reparsed.inputs[0].partial_sigs[0].pubkey,
    );
}
