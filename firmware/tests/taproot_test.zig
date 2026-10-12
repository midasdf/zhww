//! Interoperability test against Bitcoin Core (Taproot key path signing).
//!
//! Vector: tests/vectors/core_taproot.json
//!
//! Procedure (frozen exactly as it was run on regtest):
//!   1. Send from Core to a BIP86 P2TR address (`bcrt1p...`) to create a UTXO
//!   2. Build a transaction with Core's `createpsbt` + `utxoupdatepsbt`
//!   3. Sign the BIP341 key path with this implementation and write out the signed PSBT
//!   4. Core's `finalizepsbt` returns `complete: true`, and its output hex
//!      **matches byte for byte** this implementation's final transaction
//!   5. Core's `testmempoolaccept` returns `allowed: true`
//!
//! **Difference from BIP143 (SegWit v0)**: the signature hash uses a single SHA256,
//! `tagged_hash("TapSighash", ...)`, and the signature is a 64-byte Schnorr signature
//! (with no sighash type appended). The key used is one with the BIP341 tweak applied.

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

test "produces a Taproot key path signature Bitcoin Core accepts" {
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

    // --- the UTXO is P2TR and its amount is known ---
    const utxo = psbt.inputs[0].witness_utxo.?;
    try testing.expectEqual(@as(u64, @intCast(root.get("input_amount_sats").?.integer)), utxo.value);
    const output_key = zhww.btc_taproot.outputKeyFromScript(utxo.script_pubkey) orelse {
        return error.InvalidEncoding;
    };

    // --- key discovery: derive the output key from the internal key and find the one matching the UTXO ---
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

    // --- BIP341 signature hash and signature ---
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

    // --- the final transaction matches Core's output ---
    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 1);
    inputs[0] = psbt.unsigned_tx.inputs[0];
    const witness = try allocator.alloc([]const u8, 1);
    witness[0] = &signature; // the key path is a single 64-byte signature
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

    // --- write out the signed PSBT (PSBT_IN_TAP_KEY_SIG = 0x13) and confirm it can be read back ---
    const fields = try allocator.alloc([]const zhww.btc_psbt.Psbt.Field, psbt.inputs.len);
    const one = try allocator.alloc(zhww.btc_psbt.Psbt.Field, 1);
    one[0] = .{ .key = &[_]u8{zhww.btc_psbt.IN_TAP_KEY_SIG}, .value = &signature };
    fields[0] = one;

    const signed_psbt = try zhww.btc_psbt.Psbt.serializeWith(allocator, psbt, fields);
    const reparsed = try zhww.btc_psbt.Psbt.parse(allocator, signed_psbt);
    try testing.expect(signed_psbt.len > psbt_bytes.len);
    try testing.expectEqual(@as(usize, 1), reparsed.inputs.len);

    // The added field must not break the original map (witness_utxo is still present)
    try testing.expect(reparsed.inputs[0].witness_utxo != null);
    try testing.expectEqualSlices(
        u8,
        utxo.script_pubkey,
        reparsed.inputs[0].witness_utxo.?.script_pubkey,
    );
}
