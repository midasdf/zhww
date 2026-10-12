//! Taproot (BIP341 / BIP86) key path signing.
//!
//! Reference: https://github.com/bitcoin/bips/blob/master/bip-0341.mediawiki
//!       https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki
//!
//! **Scope**: key path only. The script path (Tapscript) is not implemented
//! (the risk of getting it wrong is high; [docs/01-requirements.md] puts it out of scope).
//!
//! **Points to watch**
//! - The Taproot signature hash is a **single SHA256** (`tagged_hash("TapSighash", ...)`).
//!   It differs from the double SHA256 of Legacy / BIP143
//! - The key used for signing must already be tweaked with `taproot_tweak_private_key` (BIP341)
//! - A `SIGHASH_DEFAULT` signature is 64 bytes and carries no sighash type at the end
//!   (unlike BIP143's 65 bytes)

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const transaction = @import("transaction.zig");

/// BIP341 sighash type. `SIGHASH_DEFAULT` is 0 and adds no type to the signature.
pub const SIGHASH_DEFAULT: u8 = 0x00;
pub const SIGHASH_ALL: u8 = 0x01;

/// P2TR scriptPubKey (`5120{x-only output key}`).
pub fn scriptPubKey(output_key: [32]u8) [34]u8 {
    var script: [34]u8 = undefined;
    script[0] = 0x51; // OP_1
    script[1] = 0x20; // push 32
    @memcpy(script[2..34], &output_key);
    return script;
}

/// Extract the x-only output key when the scriptPubKey is P2TR.
pub fn outputKeyFromScript(script: []const u8) ?[32]u8 {
    if (script.len != 34) return null;
    if (script[0] != 0x51 or script[1] != 0x20) return null;
    return script[2..34].*;
}

/// BIP341 signature hash (key path, no annex).
///
/// `prevouts` must supply UTXO information (value and scriptPubKey) in the same order and
/// the same number as the inputs. `SIGHASH_DEFAULT` (and `ALL`) use every input's information.
pub fn sighashKeyPath(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    prevouts: []const transaction.TxOut,
    sighash_type: u8,
) Error![32]u8 {
    if (sighash_type != SIGHASH_DEFAULT and sighash_type != SIGHASH_ALL) {
        return error.UnsupportedSighash; // NONE / SINGLE are not supported
    }
    if (input_index >= tx.inputs.len) return error.InvalidEncoding;
    if (prevouts.len != tx.inputs.len) return error.InvalidEncoding;

    var sha_prevouts: [32]u8 = undefined;
    var sha_amounts: [32]u8 = undefined;
    var sha_scriptpubkeys: [32]u8 = undefined;
    var sha_sequences: [32]u8 = undefined;
    var sha_outputs: [32]u8 = undefined;

    // sha_prevouts / sha_amounts / sha_scriptpubkeys / sha_sequences
    {
        var prevout_bytes = std.ArrayList(u8).empty;
        defer prevout_bytes.deinit(allocator);
        var amount_bytes = std.ArrayList(u8).empty;
        defer amount_bytes.deinit(allocator);
        var script_bytes = std.ArrayList(u8).empty;
        defer script_bytes.deinit(allocator);
        var sequence_bytes = std.ArrayList(u8).empty;
        defer sequence_bytes.deinit(allocator);

        for (tx.inputs, 0..) |input, i| {
            try prevout_bytes.appendSlice(allocator, &input.prevout.txid);
            var vout: [4]u8 = undefined;
            std.mem.writeInt(u32, &vout, input.prevout.vout, .little);
            try prevout_bytes.appendSlice(allocator, &vout);

            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, prevouts[i].value, .little);
            try amount_bytes.appendSlice(allocator, &value);

            try transaction.writeVarBytes(&script_bytes, allocator, prevouts[i].script_pubkey);

            var sequence: [4]u8 = undefined;
            std.mem.writeInt(u32, &sequence, input.sequence, .little);
            try sequence_bytes.appendSlice(allocator, &sequence);
        }

        hashes.Sha256.hash(prevout_bytes.items, &sha_prevouts, .{});
        hashes.Sha256.hash(amount_bytes.items, &sha_amounts, .{});
        hashes.Sha256.hash(script_bytes.items, &sha_scriptpubkeys, .{});
        hashes.Sha256.hash(sequence_bytes.items, &sha_sequences, .{});
    }

    // sha_outputs
    {
        var output_bytes = std.ArrayList(u8).empty;
        defer output_bytes.deinit(allocator);
        for (tx.outputs) |output| {
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, output.value, .little);
            try output_bytes.appendSlice(allocator, &value);
            try transaction.writeVarBytes(&output_bytes, allocator, output.script_pubkey);
        }
        hashes.Sha256.hash(output_bytes.items, &sha_outputs, .{});
    }

    // Assemble the signature target
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    var version: [4]u8 = undefined;
    std.mem.writeInt(i32, &version, tx.version, .little);
    var lock_time: [4]u8 = undefined;
    std.mem.writeInt(u32, &lock_time, tx.lock_time, .little);
    var index: [4]u8 = undefined;
    std.mem.writeInt(u32, &index, @intCast(input_index), .little);

    try buffer.append(allocator, 0x00); // sighash epoch
    try buffer.append(allocator, sighash_type);
    try buffer.appendSlice(allocator, &version);
    try buffer.appendSlice(allocator, &lock_time);
    try buffer.appendSlice(allocator, &sha_prevouts);
    try buffer.appendSlice(allocator, &sha_amounts);
    try buffer.appendSlice(allocator, &sha_scriptpubkeys);
    try buffer.appendSlice(allocator, &sha_sequences);
    try buffer.appendSlice(allocator, &sha_outputs);
    try buffer.append(allocator, 0x00); // spend_type (key path, no annex)
    try buffer.appendSlice(allocator, &index);

    var digest: [32]u8 = undefined;
    hashes.taggedHash(&digest, "TapSighash", buffer.items);
    return digest;
}

/// Key path signature (64 bytes, `SIGHASH_DEFAULT`).
///
/// `priv` is the internal key's private key (before tweaking). The BIP341 tweak is applied internally.
pub fn signKeyPath(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    prevouts: []const transaction.TxOut,
    priv: [32]u8,
) Error![64]u8 {
    const message = try sighashKeyPath(
        allocator,
        tx,
        input_index,
        prevouts,
        SIGHASH_DEFAULT,
    );
    const internal_key = try secp256k1.schnorrPublicKey(priv);
    const expected_output_key = try secp256k1.taprootOutputKey(internal_key);
    const actual_output_key = outputKeyFromScript(prevouts[input_index].script_pubkey) orelse
        return error.InvalidEncoding;
    if (!std.mem.eql(u8, &expected_output_key, &actual_output_key)) return error.NoMatchingKey;

    var tweaked = try secp256k1.taprootTweakPrivateKey(priv);
    defer std.crypto.secureZero(u8, &tweaked);
    const signature = try secp256k1.schnorrSign(message, tweaked);
    if (!try secp256k1.schnorrVerify(signature, message, expected_output_key)) {
        return error.SignatureInvalid;
    }
    return signature;
}

/// Witness for a key path signature (a single 64-byte signature).
///
/// The caller owns `signature` and must keep it alive while the returned witness is used.
/// Taking a pointer avoids returning a slice into a by-value parameter's dead stack storage.
pub fn witnessFrom(signature: *const [64]u8) [1][]const u8 {
    return .{signature};
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "P2TR scriptPubKey and output key extraction" {
    const output_key: [32]u8 = @splat(0xAB);
    const script = scriptPubKey(output_key);
    try testing.expectEqual(@as(u8, 0x51), script[0]);
    try testing.expectEqual(@as(u8, 0x20), script[1]);
    try testing.expectEqualSlices(u8, &output_key, &outputKeyFromScript(&script).?);
    try testing.expect(outputKeyFromScript(&[_]u8{ 0x00, 0x14 }) == null);
}

test "key path signature passes BIP340 verification and is deterministic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // An arbitrary 1-input 1-output transaction
    var prev_txid: [32]u8 = undefined;
    for (&prev_txid, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    var destination: [22]u8 = @splat(0x11);
    destination[0] = 0x00;
    destination[1] = 0x14;
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 90_000, .script_pubkey = &destination };
    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };

    // Derive the P2TR output key from the internal key and prepare its UTXO
    var priv: [32]u8 = @splat(0);
    priv[31] = 0x42;
    const internal = try secp256k1.schnorrPublicKey(priv);
    const output_key = try secp256k1.taprootOutputKey(internal);
    const prevouts = try allocator.alloc(transaction.TxOut, 1);
    prevouts[0] = .{ .value = 100_000, .script_pubkey = &scriptPubKey(output_key) };

    const signature = try signKeyPath(allocator, tx, 0, prevouts, priv);

    // The signature verifies against output_key
    const message = try sighashKeyPath(allocator, tx, 0, prevouts, SIGHASH_DEFAULT);
    try testing.expect(try secp256k1.schnorrVerify(signature, message, output_key));

    // Deterministic (the same input yields the same signature)
    const again = try signKeyPath(allocator, tx, 0, prevouts, priv);
    try testing.expectEqualSlices(u8, &signature, &again);

    // A key that does not own the UTXO is refused before returning a useless signature.
    var wrong_priv = priv;
    wrong_priv[31] +%= 1;
    try testing.expectError(error.NoMatchingKey, signKeyPath(allocator, tx, 0, prevouts, wrong_priv));

    // A tampered signature does not verify
    var broken = signature;
    broken[0] ^= 0x01;
    try testing.expect(!try secp256k1.schnorrVerify(broken, message, output_key));

    // The witness is a single signature (not 65 bytes with a sighash type)
    const witness = witnessFrom(&signature);
    try testing.expectEqual(@as(usize, 1), witness.len);
    try testing.expectEqual(@as(usize, 64), witness[0].len);
}

test "anything but SIGHASH_DEFAULT is unsupported (NONE / SINGLE are rejected)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const prev_txid: [32]u8 = @splat(0);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0,
        .witness = &.{},
    };
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 1, .script_pubkey = &[_]u8{0x6a} };
    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const prevouts = try allocator.alloc(transaction.TxOut, 1);
    prevouts[0] = .{ .value = 2, .script_pubkey = &[_]u8{0x6a} };

    try testing.expectError(
        error.UnsupportedSighash,
        sighashKeyPath(allocator, tx, 0, prevouts, 0x02), // SIGHASH_NONE
    );
    try testing.expectError(
        error.UnsupportedSighash,
        sighashKeyPath(allocator, tx, 0, prevouts, 0x03), // SIGHASH_SINGLE
    );
    // Also reject a mismatch between the number of inputs and the number of UTXOs
    try testing.expectError(
        error.InvalidEncoding,
        sighashKeyPath(allocator, tx, 0, &.{}, SIGHASH_DEFAULT),
    );
}
