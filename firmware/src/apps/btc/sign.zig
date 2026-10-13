//! Signing and finalization from a PSBT (single-signature Bitcoin).
//!
//! Division of responsibilities (invariants in [docs/02-architecture.md]):
//! - Key discovery, choosing what to sign, signing and finalization all happen here
//! - `apps` holds no key material. The caller passes keys in as a `KeySource`, and
//!   this layer returns only the result "this key signed it"
//!
//! **Safety policy**
//! - Always verify with `secp256k1.verify` before returning a signature (never return a broken one)
//! - If an input amount is unknown, do not compute a fee (`amounts_complete = false`).
//!   In that case the display layer must not ask for approval
//! - Do not sign a non-witness input that only has `witness_utxo` (BIP174 rule)
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const bip32 = @import("../../core/derive/bip32.zig");
const bip39 = @import("../../core/seed/bip39.zig");
const bech32 = @import("../../core/encoding/bech32.zig");
const transaction = @import("transaction.zig");
const sighash = @import("sighash.zig");
const psbt_mod = @import("psbt.zig");

pub const SIGHASH_ALL: u32 = 0x01;
/// Bitcoin Core's consensus money range (21 million BTC, in satoshis).
pub const max_money: u64 = 21_000_000 * 100_000_000;

/// Kind of scriptPubKey.
pub const ScriptKind = enum {
    p2pkh,
    p2sh,
    p2wpkh,
    p2wsh,
    p2tr,
    p2pk,
    unknown,

    pub fn isWitness(self: ScriptKind) bool {
        return switch (self) {
            .p2wpkh, .p2wsh, .p2tr => true,
            else => false,
        };
    }
};

/// Determine the kind from the scriptPubKey.
pub fn detectScriptKind(script: []const u8) ScriptKind {
    if (script.len == 25 and script[0] == 0x76 and script[1] == 0xa9 and
        script[2] == 0x14 and script[23] == 0x88 and script[24] == 0xac) return .p2pkh;
    if (script.len == 23 and script[0] == 0xa9 and script[1] == 0x14 and script[22] == 0x87) {
        return .p2sh;
    }
    if (script.len == 22 and script[0] == 0x00 and script[1] == 0x14) return .p2wpkh;
    if (script.len == 34 and script[0] == 0x00 and script[1] == 0x20) return .p2wsh;
    if (script.len == 34 and script[0] == 0x51 and script[1] == 0x20) return .p2tr;
    if (script.len == 35 and script[0] == 0x21 and script[34] == 0xac) return .p2pk;
    return .unknown;
}

/// The set of keys used for signing.
///
/// - Passing `master` derives keys via BIP32 (normal use)
/// - `raw_keys` are individually imported keys (for tests and recovery)
pub const KeySource = struct {
    master: ?bip32.ExtendedKey = null,
    master_fingerprint: [4]u8 = @splat(0),
    raw_keys: []const RawKey = &.{},
    /// Highest index walked during key discovery (for receive and change alike).
    max_index: u32 = 20,

    pub const RawKey = struct {
        private_key: [32]u8,
        public_key: [33]u8,
    };

    /// Build a key set from a seed (BIP32 master key).
    pub fn fromSeed(seed: []const u8) Error!KeySource {
        var master = try bip32.ExtendedKey.fromSeed(seed, .xprv);
        defer master.wipe();
        return .{
            .master = master,
            .master_fingerprint = try master.fingerprint(),
        };
    }

    /// Use only the individual keys.
    pub fn fromRawKeys(keys: []const RawKey) KeySource {
        return .{ .raw_keys = keys };
    }

    /// Erase this owned copy, not caller-owned raw_keys storage. Never use after wipe.
    pub fn wipe(self: *KeySource) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }

    pub fn derive(self: *const KeySource, path: []const u32) Error!bip32.ExtendedKey {
        var node = self.master orelse return error.NoMatchingKey;
        defer node.wipe();
        for (path) |index| {
            var child = try node.child(index);
            defer child.wipe();
            node.wipe();
            node = child;
        }
        return node;
    }
};

/// An input that was signed.
pub const PartialSignature = struct {
    index: usize,
    pubkey: [33]u8,
    /// DER signature + sighash type (in the form that goes straight into scriptSig / witness).
    signature: []const u8,
};

/// The result of signing.
pub const SignResult = struct {
    partial_sigs: []const PartialSignature,
    /// The final transaction (already serialized) when every input could be signed.
    final_tx: ?[]const u8,
    /// Total input amount (null if even one of them is unknown).
    total_input: ?u64,
    total_output: u64,
    /// The fee (only when every input amount is known).
    fee: ?u64,
    /// Index of the output judged to be change.
    change_outputs: []const usize,
    /// Indices of the inputs that could not be signed.
    unsigned_inputs: []const usize,
};

/// Sign a PSBT.
pub fn sign(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: KeySource,
) Error!SignResult {
    var owned_keys = keys;
    defer owned_keys.wipe();
    return signOwned(allocator, psbt, &owned_keys, null);
}

fn signOwned(allocator: std.mem.Allocator, psbt: psbt_mod.Psbt, keys: *const KeySource, expected: ?[]const [32]u8) Error!SignResult {
    const tx = psbt.unsigned_tx;
    var partial_sigs = std.ArrayList(PartialSignature).empty;
    errdefer partial_sigs.deinit(allocator);
    var unsigned = std.ArrayList(usize).empty;
    errdefer unsigned.deinit(allocator);

    // Resolve each input's scriptPubKey and amount
    const resolved = try allocator.alloc(?ResolvedUtxo, tx.inputs.len);
    for (resolved, 0..) |*entry, i| {
        entry.* = try resolveUtxo(allocator, psbt, i);
    }

    // Check EVERY primary message before any signature is created. The approved
    // native-P2WPKH path supplies independent wire-parser hashes, never host hashes.
    if (expected) |messages| {
        if (messages.len != tx.inputs.len) return error.SigningPlanMismatch;
        for (resolved, 0..) |entry, i| {
            const utxo = entry orelse return error.SigningPlanMismatch;
            if (detectScriptKind(utxo.script_pubkey) != .p2wpkh) return error.SigningPlanMismatch;
            const input = psbt.inputs[i];
            if (input.final_script_sig != null or input.final_script_witness != null or
                (input.sighash_type != null and input.sighash_type.? != SIGHASH_ALL))
                return error.SigningPlanMismatch;
            const code = sighash.p2wpkhScriptCode(utxo.script_pubkey[2..22].*);
            const primary = try sighash.segwitV0Sighash(allocator, tx, i, &code, utxo.amount, SIGHASH_ALL);
            if (!std.crypto.timing_safe.eql([32]u8, primary, messages[i]))
                return error.SigningPlanMismatch;
        }
    }

    // Sign each input
    const signatures = try allocator.alloc(?[]const u8, tx.inputs.len);
    const signer_pubkeys = try allocator.alloc(?[33]u8, tx.inputs.len);
    for (signatures) |*slot| slot.* = null;
    for (signer_pubkeys) |*slot| slot.* = null;

    for (tx.inputs, 0..) |_, index| {
        const input = psbt.inputs[index];
        // A finalized input must not be modified by adding a new partial signature. Supporting
        // mixed finalized/unfinalized PSBTs requires preserving and validating the final stack.
        if (input.final_script_sig != null or input.final_script_witness != null) {
            return error.InvalidPsbt;
        }
        // This signer deliberately supports only SIGHASH_ALL. Ignoring a PSBT's requested
        // sighash would produce a signature different from what the host asked the user to review.
        if (input.sighash_type) |requested| {
            if (requested != SIGHASH_ALL) return error.UnsupportedSighash;
        }

        const utxo = resolved[index] orelse {
            try unsigned.append(allocator, index);
            continue;
        };
        const kind = detectScriptKind(utxo.script_pubkey);

        // Find the key
        var found = try findKeyForInput(allocator, psbt, keys, index, utxo, kind) orelse {
            if (expected != null) return error.NoMatchingKey;
            try unsigned.append(allocator, index);
            continue;
        };
        defer std.crypto.secureZero(u8, std.mem.asBytes(&found));

        // Compute the signature hash
        const message = try sighashForInput(
            allocator,
            psbt,
            index,
            utxo,
            kind,
            found.public_key,
        );

        // Check the actual key-derived message too, immediately at the C signing boundary.
        if (expected) |messages| {
            if (!std.crypto.timing_safe.eql([32]u8, message, messages[index]))
                return error.SigningPlanMismatch;
        }
        const signature = try secp256k1.sign(message, found.private_key);
        // A signature is only accepted after it verifies
        if (!(try secp256k1.verify(&signature, message, found.public_key))) {
            return error.SignatureInvalid;
        }

        var der_buf: [72]u8 = undefined;
        const der = try secp256k1.serializeDer(&der_buf, &signature);
        const blob = try allocator.alloc(u8, der.len + 1);
        @memcpy(blob[0..der.len], der);
        blob[der.len] = @intCast(SIGHASH_ALL);

        signatures[index] = blob;
        signer_pubkeys[index] = found.public_key;
        try partial_sigs.append(allocator, .{
            .index = index,
            .pubkey = found.public_key,
            .signature = blob,
        });
    }

    // Total input amount and fee
    var total_input: u64 = 0;
    var amounts_complete = true;
    for (resolved) |entry| {
        if (entry) |utxo| {
            if (utxo.amount > max_money) return error.InvalidPsbt;
            total_input = std.math.add(u64, total_input, utxo.amount) catch return error.InvalidPsbt;
            if (total_input > max_money) return error.InvalidPsbt;
        } else {
            amounts_complete = false;
        }
    }
    var total_output: u64 = 0;
    for (tx.outputs) |output| {
        if (output.value > max_money) return error.InvalidPsbt;
        total_output = std.math.add(u64, total_output, output.value) catch return error.InvalidPsbt;
        if (total_output > max_money) return error.InvalidPsbt;
    }
    const fee: ?u64 = if (amounts_complete) blk: {
        if (total_input < total_output) return error.InvalidPsbt;
        break :blk total_input - total_output;
    } else null;

    // Change detection
    const change_outputs = try findChangeOutputsOwned(allocator, psbt, keys);

    // Finalization (only when every input could be signed)
    var final_tx: ?[]const u8 = null;
    if (unsigned.items.len == 0) {
        final_tx = try finalize(allocator, psbt, signatures, signer_pubkeys, resolved);
    }

    return .{
        .partial_sigs = try partial_sigs.toOwnedSlice(allocator),
        .final_tx = final_tx,
        .total_input = if (amounts_complete) total_input else null,
        .total_output = total_output,
        .fee = fee,
        .change_outputs = change_outputs,
        .unsigned_inputs = try unsigned.toOwnedSlice(allocator),
    };
}

const ResolvedUtxo = struct {
    script_pubkey: []const u8,
    amount: u64,
    /// The redeemScript in the P2SH-P2WPKH case.
    redeem_script: ?[]const u8 = null,
};

fn resolveUtxo(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
) Error!?ResolvedUtxo {
    if (index >= psbt.inputs.len or index >= psbt.unsigned_tx.inputs.len) return error.InvalidPsbt;
    const input = psbt.inputs[index];
    const previous = try resolveNonWitnessUtxo(allocator, psbt, index);

    // For a witness input, use witness_utxo. A nested P2SH witness is accepted only when
    // redeemScript itself hashes to the P2SH program; its shape alone is not enough.
    if (input.witness_utxo) |utxo| {
        if (utxo.value > max_money) return error.InvalidPsbt;
        const kind = detectScriptKind(utxo.script_pubkey);
        const is_witness_input = kind.isWitness() or
            (kind == .p2sh and nestedP2wpkhMatches(utxo.script_pubkey, input.redeem_script));
        if (is_witness_input) {
            // When both forms are supplied, they must describe the same previous output. This
            // prevents the display path and signing path from choosing different amounts/scripts.
            if (previous) |trusted| {
                if (trusted.value != utxo.value or
                    !std.mem.eql(u8, trusted.script_pubkey, utxo.script_pubkey))
                {
                    return error.InvalidPsbt;
                }
            }
            return .{
                .script_pubkey = utxo.script_pubkey,
                .amount = utxo.value,
                .redeem_script = input.redeem_script,
            };
        }
    }

    // A non-witness input that only has witness_utxo is not signed (BIP174 rule).
    if (previous) |utxo| {
        if (utxo.value > max_money) return error.InvalidPsbt;
        return .{
            .script_pubkey = utxo.script_pubkey,
            .amount = utxo.value,
            .redeem_script = input.redeem_script,
        };
    }
    return null;
}

fn resolveNonWitnessUtxo(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
) Error!?transaction.TxOut {
    const prev_tx = psbt.inputs[index].non_witness_utxo orelse return null;
    const prevout = psbt.unsigned_tx.inputs[index].prevout;
    const txid = try prev_tx.txid(allocator);
    if (!std.mem.eql(u8, &txid, &prevout.txid)) return error.InvalidPsbt;
    if (prevout.vout >= prev_tx.outputs.len) return error.InvalidPsbt;
    return prev_tx.outputs[@intCast(prevout.vout)];
}

fn nestedP2wpkhMatches(script_pubkey: []const u8, redeem_script: ?[]const u8) bool {
    const redeem = redeem_script orelse return false;
    if (detectScriptKind(redeem) != .p2wpkh or detectScriptKind(script_pubkey) != .p2sh) return false;
    var redeem_hash: [20]u8 = undefined;
    hashes.hash160(&redeem_hash, redeem);
    return std.mem.eql(u8, script_pubkey[2..22], &redeem_hash);
}

/// Resolve exactly the UTXO the signer will use, for a pre-signing display.
///
/// Keeping this in the signing module prevents a UI from preferring an untrusted
/// `witness_utxo` for a legacy input while the signer correctly uses `non_witness_utxo`.
pub fn utxoForDisplay(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
) Error!?transaction.TxOut {
    const resolved = try resolveUtxo(allocator, psbt, index) orelse return null;
    return .{ .value = resolved.amount, .script_pubkey = resolved.script_pubkey };
}

fn findKeyForInput(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: *const KeySource,
    index: usize,
    utxo: ResolvedUtxo,
    kind: ScriptKind,
) Error!?KeySource.RawKey {
    // 1) Use the PSBT's BIP32 derivation information (those whose fingerprint matches)
    for (psbt.inputs[index].bip32_derivations) |derivation| {
        if (!std.mem.eql(u8, &derivation.fingerprint, &keys.master_fingerprint)) continue;
        var node = try keys.derive(derivation.path);
        defer node.wipe();
        if (node.keyIsPrivate()) {
            const pub_key = try node.publicKey();
            if (!std.mem.eql(u8, derivation.pubkey, &pub_key)) continue;
            if (matchesKey(utxo, kind, pub_key)) {
                return .{ .private_key = node.key.priv, .public_key = pub_key };
            }
        }
    }

    // 2) Individually supplied keys
    for (keys.raw_keys) |*raw| {
        if (matchesKey(utxo, kind, raw.public_key)) return raw.*;
    }

    // 3) Walk the standard derivation paths
    if (keys.master != null) {
        const purposes = [_]u32{ 84, 49, 44 };
        for (purposes) |purpose| {
            for ([_]u32{ 0, 1 }) |change| {
                var i: u32 = 0;
                while (i <= keys.max_index) : (i += 1) {
                    const path = [_]u32{
                        purpose | bip32.hardened,
                        0 | bip32.hardened,
                        0 | bip32.hardened,
                        change,
                        i,
                    };
                    var node = keys.derive(&path) catch continue;
                    defer node.wipe();
                    if (!node.keyIsPrivate()) continue;
                    const pub_key = try node.publicKey();
                    if (matchesKey(utxo, kind, pub_key)) {
                        return .{ .private_key = node.key.priv, .public_key = pub_key };
                    }
                }
            }
        }
    }
    _ = allocator;
    return null;
}

/// Whether the public key is plausible as the key for this UTXO.
fn matchesKey(utxo: ResolvedUtxo, kind: ScriptKind, pub_key: [33]u8) bool {
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);
    switch (kind) {
        .p2wpkh => return utxo.script_pubkey.len == 22 and
            std.mem.eql(u8, utxo.script_pubkey[2..22], &h160),
        .p2pkh => return utxo.script_pubkey.len == 25 and
            std.mem.eql(u8, utxo.script_pubkey[3..23], &h160),
        .p2sh => {
            // P2SH-P2WPKH: redeemScript = 0014{h160}
            var redeem: [22]u8 = undefined;
            redeem[0] = 0x00;
            redeem[1] = 0x14;
            @memcpy(redeem[2..22], &h160);
            var redeem_hash: [20]u8 = undefined;
            hashes.hash160(&redeem_hash, &redeem);
            return utxo.script_pubkey.len == 23 and
                std.mem.eql(u8, utxo.script_pubkey[2..22], &redeem_hash);
        },
        .p2pk => return utxo.script_pubkey.len == 35 and
            std.mem.eql(u8, utxo.script_pubkey[1..34], &pub_key),
        else => return false,
    }
}

fn sighashForInput(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    index: usize,
    utxo: ResolvedUtxo,
    kind: ScriptKind,
    pub_key: [33]u8,
) Error![32]u8 {
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);

    switch (kind) {
        .p2wpkh => {
            const script_code = sighash.p2wpkhScriptCode(h160);
            return sighash.segwitV0Sighash(
                allocator,
                psbt.unsigned_tx,
                index,
                &script_code,
                utxo.amount,
                SIGHASH_ALL,
            );
        },
        .p2sh => {
            // Handle as P2SH-P2WPKH (the redeemScript match was already checked)
            const script_code = sighash.p2wpkhScriptCode(h160);
            return sighash.segwitV0Sighash(
                allocator,
                psbt.unsigned_tx,
                index,
                &script_code,
                utxo.amount,
                SIGHASH_ALL,
            );
        },
        .p2pkh => return sighash.legacySighash(
            allocator,
            psbt.unsigned_tx,
            index,
            utxo.script_pubkey,
            SIGHASH_ALL,
        ),
        .p2pk => return sighash.legacySighash(
            allocator,
            psbt.unsigned_tx,
            index,
            utxo.script_pubkey,
            SIGHASH_ALL,
        ),
        else => return error.UnsupportedSighash,
    }
}

/// Decide whether an output belongs to one of our **change** keys, and return its index.
///
/// Only the change chains of BIP84/49/44 (`.../1/i`) are considered.
/// **A payment to a receive address (`.../0/i`) is not treated as change** (to avoid misjudging it).
pub fn findChangeOutputs(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    keys: KeySource,
) Error![]const usize {
    var owned_keys = keys;
    defer owned_keys.wipe();
    return findChangeOutputsOwned(allocator, psbt, &owned_keys);
}

fn findChangeOutputsOwned(allocator: std.mem.Allocator, psbt: psbt_mod.Psbt, keys: *const KeySource) Error![]const usize {
    var result = std.ArrayList(usize).empty;
    errdefer result.deinit(allocator);
    if (keys.master == null) return result.toOwnedSlice(allocator);

    for (psbt.unsigned_tx.outputs, 0..) |output, index| {
        const kind = detectScriptKind(output.script_pubkey);
        if (kind == .unknown) continue;
        if (try outputMatchesChangeKey(keys, output.script_pubkey, kind)) {
            try result.append(allocator, index);
        }
    }
    return result.toOwnedSlice(allocator);
}

fn outputMatchesChangeKey(keys: *const KeySource, script: []const u8, kind: ScriptKind) Error!bool {
    const purposes = [_]u32{ 84, 49, 44 };
    for (purposes) |purpose| {
        var i: u32 = 0;
        while (i <= keys.max_index) : (i += 1) {
            const path = [_]u32{
                purpose | bip32.hardened,
                0 | bip32.hardened,
                0 | bip32.hardened,
                1, // change
                i,
            };
            var node = keys.derive(&path) catch continue;
            defer node.wipe();
            const pub_key = try node.publicKey();
            if (matchesKey(.{ .script_pubkey = script, .amount = 0 }, kind, pub_key)) {
                return true;
            }
        }
    }
    return false;
}

/// Fill in the signatures and assemble the final transaction.
fn finalize(
    allocator: std.mem.Allocator,
    psbt: psbt_mod.Psbt,
    signatures: []const ?[]const u8,
    pubkeys: []const ?[33]u8,
    resolved: []const ?ResolvedUtxo,
) Error![]const u8 {
    const tx = psbt.unsigned_tx;
    const inputs = try allocator.alloc(transaction.TxIn, tx.inputs.len);
    @memcpy(inputs, tx.inputs);

    for (inputs, 0..) |*input, index| {
        const signature = signatures[index] orelse return error.NoMatchingKey;
        const pub_key = pubkeys[index] orelse return error.NoMatchingKey;
        const utxo = resolved[index] orelse return error.InvalidPsbt;
        const kind = detectScriptKind(utxo.script_pubkey);

        // Copy the public key into stable storage before putting it in the witness.
        // Passing the address of a local variable becomes an invalid reference once the loop exits.
        const pub_key_copy = try allocator.dupe(u8, &pub_key);

        switch (kind) {
            .p2wpkh => {
                const witness = try allocator.alloc([]const u8, 2);
                witness[0] = signature;
                witness[1] = pub_key_copy;
                input.script_sig = &.{};
                input.witness = witness;
            },
            .p2sh => {
                // scriptSig = push(redeemScript), witness = [sig, pubkey]
                var redeem: [22]u8 = undefined;
                redeem[0] = 0x00;
                redeem[1] = 0x14;
                var h160: [20]u8 = undefined;
                hashes.hash160(&h160, &pub_key);
                @memcpy(redeem[2..22], &h160);
                input.script_sig = try pushData(allocator, &redeem);
                const witness = try allocator.alloc([]const u8, 2);
                witness[0] = signature;
                witness[1] = pub_key_copy;
                input.witness = witness;
            },
            .p2pkh => {
                const sig_push = try pushData(allocator, signature);
                const pub_push = try pushData(allocator, &pub_key);
                const script_sig = try allocator.alloc(u8, sig_push.len + pub_push.len);
                @memcpy(script_sig[0..sig_push.len], sig_push);
                @memcpy(script_sig[sig_push.len..], pub_push);
                input.script_sig = script_sig;
                input.witness = &.{};
            },
            .p2pk => {
                input.script_sig = try pushData(allocator, signature);
                input.witness = &.{};
            },
            else => return error.UnsupportedSighash,
        }
    }

    const final = transaction.Transaction{
        .version = tx.version,
        .inputs = inputs,
        .outputs = tx.outputs,
        .lock_time = tx.lock_time,
        .has_witness = true,
    };
    return final.serialize(allocator, true);
}

/// The "push data" construct in Bitcoin Script.
fn pushData(allocator: std.mem.Allocator, data: []const u8) Error![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (data.len < 0x4C) {
        try out.append(allocator, @intCast(data.len));
    } else if (data.len <= 0xFF) {
        try out.append(allocator, 0x4C);
        try out.append(allocator, @intCast(data.len));
    } else if (data.len <= 0xFFFF) {
        try out.append(allocator, 0x4D);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(data.len), .little);
        try out.appendSlice(allocator, &buf);
    } else {
        return error.BufferTooSmall;
    }
    try out.appendSlice(allocator, data);
    return out.toOwnedSlice(allocator);
}

/// The whole set of results, including the signed PSBT.
pub const SignedPsbt = struct {
    /// Signature details (fee, change, inputs that could not be signed, and so on).
    result: SignResult,
    /// The signed PSBT returned to the host (the original fields are preserved).
    signed_psbt: []const u8,
};

/// Take PSBT bytes, sign them, and return the signed PSBT.
///
/// Air-gapped operation is fundamentally "take bytes, return bytes", so the input and
/// output are completed here (QR / SD / USB all use the same function).
pub fn signPsbtBytes(
    allocator: std.mem.Allocator,
    psbt_bytes: []const u8,
    keys: KeySource,
) Error!SignedPsbt {
    var owned_keys = keys;
    defer owned_keys.wipe();
    return signPsbtWithKeys(allocator, psbt_bytes, &owned_keys);
}

/// Pointer-borrowing development entry point. Caller owns/erases master/raw-key
/// storage; no key pointer is retained. Approved signing must use signPsbtWithPlan.
pub fn signPsbtWithKeys(
    allocator: std.mem.Allocator,
    psbt_bytes: []const u8,
    keys: *const KeySource,
) Error!SignedPsbt {
    return signPsbtChecked(allocator, psbt_bytes, keys, null);
}

/// Trusted approved-path entry point. `messages` must come from the independent
/// guard over owned request bytes, NEVER from transport/NS/caller-supplied hashes.
/// Legacy development APIs intentionally do not enforce this plan.
pub fn signPsbtWithPlan(
    allocator: std.mem.Allocator,
    psbt_bytes: []const u8,
    keys: *const KeySource,
    messages: []const [32]u8,
) Error!SignedPsbt {
    return signPsbtChecked(allocator, psbt_bytes, keys, messages);
}

fn signPsbtChecked(allocator: std.mem.Allocator, psbt_bytes: []const u8, keys: *const KeySource, expected: ?[]const [32]u8) Error!SignedPsbt {
    const psbt = try psbt_mod.Psbt.parse(allocator, psbt_bytes);
    const result = try signOwned(allocator, psbt, keys, expected);

    // Collect the additional signatures for each input.
    // The public key points into `result.partial_sigs` (stable storage), so
    // never pass the address of a loop-local variable.
    const sigs = try allocator.alloc([]const psbt_mod.PartialSig, psbt.inputs.len);
    for (sigs) |*slot| slot.* = &.{};
    for (result.partial_sigs, 0..) |partial, i| {
        const one = try allocator.alloc(psbt_mod.PartialSig, 1);
        one[0] = .{
            .pubkey = &result.partial_sigs[i].pubkey,
            .signature = partial.signature,
        };
        sigs[partial.index] = one;
    }

    return .{
        .result = result,
        .signed_psbt = try psbt_mod.Psbt.serialize(allocator, psbt, sigs),
    };
}

/// Build a key set from a seed (BIP32 master key).
pub fn keysFromMnemonic(mnemonic: []const u8, passphrase: []const u8) Error!KeySource {
    // PBKDF2 accepts arbitrary text by design, but a wallet entry point must reject a typo
    // instead of silently deriving an unrelated wallet from a bad word or checksum.
    var entropy: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &entropy);
    _ = try bip39.mnemonicToEntropy(&entropy, mnemonic);

    var seed: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try bip39.mnemonicToSeed(&seed, mnemonic, passphrase);
    return KeySource.fromSeed(&seed);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "owned key source wipe erases master backing bytes without modifying caller key" {
    var keys = try KeySource.fromSeed(&@as([64]u8, @splat(0x42)));
    var derived = try keys.derive(&.{ 84 | bip32.hardened, 0 | bip32.hardened, 0 | bip32.hardened, 0, 0 });
    defer derived.wipe();
    const public_before = try derived.publicKey();
    keys.wipe();
    try testing.expectEqualSlices(u8, &@as([@sizeOf(KeySource)]u8, @splat(0)), std.mem.asBytes(&keys));
    try testing.expectEqualSlices(u8, &public_before, &(try derived.publicKey()));
}

test "scriptPubKey kind detection" {
    var p2pkh: [25]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2pkh, "76a914000102030405060708090a0b0c0d0e0f1011121388ac");
    try testing.expectEqual(ScriptKind.p2pkh, detectScriptKind(&p2pkh));

    var p2wpkh: [22]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2wpkh, "0014000102030405060708090a0b0c0d0e0f10111213");
    try testing.expectEqual(ScriptKind.p2wpkh, detectScriptKind(&p2wpkh));

    var p2sh: [23]u8 = undefined;
    _ = try std.fmt.hexToBytes(&p2sh, "a914000102030405060708090a0b0c0d0e0f1011121387");
    try testing.expectEqual(ScriptKind.p2sh, detectScriptKind(&p2sh));

    var p2tr: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &p2tr,
        "5120000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
    );
    try testing.expectEqual(ScriptKind.p2tr, detectScriptKind(&p2tr));

    var p2pk: [35]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &p2pk,
        "21025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357ac",
    );
    try testing.expectEqual(ScriptKind.p2pk, detectScriptKind(&p2pk));

    try testing.expectEqual(ScriptKind.unknown, detectScriptKind(&[_]u8{0x6a}));
    try testing.expectEqual(ScriptKind.unknown, detectScriptKind(&[_]u8{}));
}

test "pushData representation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const short = try pushData(allocator, &[_]u8{ 0xAA, 0xBB });
    try testing.expectEqualSlices(u8, &[_]u8{ 0x02, 0xAA, 0xBB }, short);

    var big: [80]u8 = @splat(0x11);
    const long = try pushData(allocator, &big);
    try testing.expectEqual(@as(u8, 0x4C), long[0]);
    try testing.expectEqual(@as(u8, 80), long[1]);
    try testing.expectEqual(@as(usize, 82), long.len);
}

test "wallet key entry rejects an invalid mnemonic checksum" {
    try testing.expectError(
        error.ChecksumMismatch,
        keysFromMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon", ""),
    );
}

test "builds a key set from a mnemonic (matches the BIP84 test vector address)" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    const keys = try keysFromMnemonic(mnemonic, "");

    var program: [40]u8 = undefined;
    const decoded = try bech32.decodeSegwit(
        "bc",
        &program,
        "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu",
    );

    const node = try keys.derive(&[_]u32{
        84 | bip32.hardened, 0 | bip32.hardened, 0 | bip32.hardened, 0, 0,
    });
    const pub_key = try node.publicKey();
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);
    try testing.expectEqualSlices(u8, decoded.program, &h160);
}

test "derives BIP84 keys from a seed and matches the known witness program" {
    const mnemonic = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about";
    var seed: [64]u8 = undefined;
    try bip39.mnemonicToSeed(&seed, mnemonic, "");
    const keys = try KeySource.fromSeed(&seed);

    // Confirm that the HASH160 of the m/84'/0'/0'/0/0 public key matches the witness
    // program of the BIP84 test vector address.
    // The address string comes from the official vector and the decoder is our own
    // implementation, validated against the BIP173 vectors, so this cross-checks the derivation -> address path.
    const node = try keys.derive(&[_]u32{
        84 | bip32.hardened, 0 | bip32.hardened, 0 | bip32.hardened, 0, 0,
    });
    const pub_key = try node.publicKey();
    var h160: [20]u8 = undefined;
    hashes.hash160(&h160, &pub_key);

    var program: [40]u8 = undefined;
    const decoded = try bech32.decodeSegwit(
        "bc",
        &program,
        "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", // BIP84 test vector
    );
    try testing.expectEqual(@as(u8, 0), decoded.witness_version);
    try testing.expectEqualSlices(u8, decoded.program, &h160);

    // The master key fingerprint is obtained reproducibly
    const master = try bip32.ExtendedKey.fromSeed(&seed, .xprv);
    try testing.expectEqualSlices(
        u8,
        &(try master.fingerprint()),
        &keys.master_fingerprint,
    );
}
