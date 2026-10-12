//! PSBT (BIP174) parsing and validation.
//!
//! Reference: https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki
//!
//! **Scope**: PSBTv0 (the form carrying `PSBT_GLOBAL_UNSIGNED_TX`).
//! PSBTv2 (which keeps inputs and outputs in separate maps) is not supported, and a
//! PSBT without an unsigned tx is rejected with `error.InvalidPsbt`.
//!
//! **Validation policy**: implement only the conditions that BIP174 requires us to
//! reject at parse time.
//! - the magic `psbt\xff`
//! - duplicate keys within the same map
//! - per-type key lengths (e.g. a partial sig public key is 33 or 65 bytes)
//! - the unsigned tx must be serialized without witness, with every scriptSig empty
//! - the number of input and output maps must match the transaction
//!
//! Checking that scripts agree (whether redeemScript matches scriptPubKey, etc.) is
//! the **signer's responsibility** and is not validated at parse time (BIP174's own
//! test vectors treat a "valid PSBT whose scripts do not match" as valid).
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const Cursor = @import("cursor.zig").Cursor;
const transaction = @import("transaction.zig");

/// PSBT magic bytes.
pub const magic = [5]u8{ 0x70, 0x73, 0x62, 0x74, 0xff };

// Global types
const GLOBAL_UNSIGNED_TX: u8 = 0x00;
const GLOBAL_XPUB: u8 = 0x01;
const GLOBAL_VERSION: u8 = 0xFB;

// Input types
const IN_NON_WITNESS_UTXO: u8 = 0x00;
const IN_WITNESS_UTXO: u8 = 0x01;
const IN_PARTIAL_SIG: u8 = 0x02;
const IN_SIGHASH_TYPE: u8 = 0x03;
const IN_REDEEM_SCRIPT: u8 = 0x04;
const IN_WITNESS_SCRIPT: u8 = 0x05;
const IN_BIP32_DERIVATION: u8 = 0x06;
const IN_FINAL_SCRIPTSIG: u8 = 0x07;
const IN_FINAL_SCRIPTWITNESS: u8 = 0x08;
/// PSBT_IN_TAP_KEY_SIG (Taproot key path signature, 64 bytes)
pub const IN_TAP_KEY_SIG: u8 = 0x13;

// Output types
const OUT_REDEEM_SCRIPT: u8 = 0x00;
const OUT_WITNESS_SCRIPT: u8 = 0x01;
const OUT_BIP32_DERIVATION: u8 = 0x02;

pub const PartialSig = struct {
    pubkey: []const u8,
    signature: []const u8,
};

pub const Bip32Derivation = struct {
    pubkey: []const u8,
    fingerprint: [4]u8,
    /// Derivation path with the hardened bits set.
    path: []const u32,
};

pub const Input = struct {
    witness_utxo: ?transaction.TxOut = null,
    non_witness_utxo: ?transaction.Transaction = null,
    partial_sigs: []const PartialSig = &.{},
    sighash_type: ?u32 = null,
    redeem_script: ?[]const u8 = null,
    witness_script: ?[]const u8 = null,
    bip32_derivations: []const Bip32Derivation = &.{},
    final_script_sig: ?[]const u8 = null,
    final_script_witness: ?[]const []const u8 = null,

    /// UTXO information usable for signing (witness_utxo takes precedence).
    pub fn utxo(self: Input) ?transaction.TxOut {
        if (self.witness_utxo) |witness| return witness;
        // Pulling the matching output out of non_witness_utxo needs the prevout, so
        // only witness_utxo is returned here; the caller (the signer) resolves it
        // using the prevout.
        return null;
    }
};

pub const Output = struct {
    redeem_script: ?[]const u8 = null,
    witness_script: ?[]const u8 = null,
    bip32_derivations: []const Bip32Derivation = &.{},
};

pub const Psbt = struct {
    unsigned_tx: transaction.Transaction,
    inputs: []Input,
    outputs: []Output,
    /// PSBT_GLOBAL_VERSION (0 = PSBTv0 when unset).
    version: u32 = 0,
    /// Raw bytes of each map (not including the terminating 0x00).
    /// Used to keep unknown fields verbatim and write them back out.
    global_raw: []const u8 = &.{},
    input_raw: []const []const u8 = &.{},
    output_raw: []const []const u8 = &.{},

    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Psbt {
        var cursor = Cursor{ .data = bytes };
        const header = try cursor.readBytes(magic.len);
        if (!std.mem.eql(u8, header, &magic)) return error.InvalidPsbt;

        // --- global map ---
        const global_start = cursor.pos;
        var unsigned_tx: ?transaction.Transaction = null;
        var version: u32 = 0;

        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(allocator);

        while (true) {
            const key_len = try cursor.readVarInt();
            if (key_len == 0) break; // end of map
            const key = try cursor.readBytes(@intCast(key_len));
            try checkDuplicate(keys.items, key);
            try keys.append(allocator, key);

            const value_len = try cursor.readVarInt();
            const value = try cursor.readBytes(@intCast(value_len));

            switch (key[0]) {
                GLOBAL_UNSIGNED_TX => {
                    if (key.len != 1) return error.InvalidPsbt;
                    if (unsigned_tx != null) return error.InvalidPsbt;
                    // Transaction.parse also verifies that there are no leftover bytes
                    const tx = try parseUnsignedTx(allocator, value);
                    if (tx.has_witness) return error.InvalidPsbt; // no witness serialization
                    for (tx.inputs) |input| {
                        if (input.script_sig.len != 0) return error.InvalidPsbt;
                    }
                    unsigned_tx = tx;
                },
                GLOBAL_XPUB => {
                    // The key is 1 + 78 bytes (an extended public key). Its contents are not used for signing
                    if (key.len != 1 + 78) return error.InvalidPsbt;
                },
                GLOBAL_VERSION => {
                    if (key.len != 1) return error.InvalidPsbt;
                    if (value.len != 4) return error.InvalidPsbt;
                    version = std.mem.readInt(u32, value[0..4], .little);
                },
                else => {
                    // Unknown types are ignored (BIP174's extensibility rule)
                },
            }
        }

        // PSBTv0 requires an unsigned tx
        const tx = unsigned_tx orelse return error.InvalidPsbt;
        // Map body, excluding the terminating 0x00
        const global_raw = bytes[global_start .. cursor.pos - 1];

        // --- input maps (must match the transaction's input count) ---
        const inputs = try allocator.alloc(Input, tx.inputs.len);
        const input_raw = try allocator.alloc([]const u8, tx.inputs.len);
        for (inputs) |*input| input.* = .{};
        for (inputs, 0..) |*input, i| {
            input_raw[i] = try parseInputMap(allocator, &cursor, input);
        }

        // --- output maps ---
        const outputs = try allocator.alloc(Output, tx.outputs.len);
        const output_raw = try allocator.alloc([]const u8, tx.outputs.len);
        for (outputs) |*output| output.* = .{};
        for (outputs, 0..) |*output, i| {
            output_raw[i] = try parseOutputMap(allocator, &cursor, output);
        }

        // There must be no leftover data
        if (cursor.remaining() != 0) return error.InvalidPsbt;
        // If 0xfb is present, treat the PSBT as a version other than 0 (PSBTv2 etc.)
        if (version != 0) return error.InvalidPsbt;

        return .{
            .unsigned_tx = tx,
            .inputs = inputs,
            .outputs = outputs,
            .version = version,
            .global_raw = global_raw,
            .input_raw = input_raw,
            .output_raw = output_raw,
        };
    }

    /// Field to add to an input map (key is the full key, including the type byte).
    pub const Field = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Write out a PSBT with arbitrary fields added.
    ///
    /// The original bytes are reused as-is, so **unknown fields are preserved**.
    /// `extra` holds the additional fields per input (e.g. partial sigs, Taproot signatures).
    /// A key already present in the original map is replaced (no duplicate keys are created).
    pub fn serializeWith(
        allocator: std.mem.Allocator,
        psbt: Psbt,
        extra: []const []const Field,
    ) Error![]u8 {
        if (extra.len != psbt.inputs.len) return error.InvalidPsbt;
        if (psbt.input_raw.len != psbt.inputs.len) return error.InvalidPsbt;
        if (psbt.output_raw.len != psbt.outputs.len) return error.InvalidPsbt;

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, &magic);
        try out.appendSlice(allocator, psbt.global_raw);
        try out.append(allocator, 0); // end of global map

        for (psbt.input_raw, 0..) |raw, index| {
            try appendFilteredMap(allocator, &out, raw, extra[index]);
            for (extra[index]) |field| {
                if (field.key.len == 0) return error.InvalidPsbt;
                try transaction.writeVarInt(&out, allocator, field.key.len);
                try out.appendSlice(allocator, field.key);
                try transaction.writeVarInt(&out, allocator, field.value.len);
                try out.appendSlice(allocator, field.value);
            }
            try out.append(allocator, 0); // end of input map
        }

        for (psbt.output_raw) |raw| {
            try out.appendSlice(allocator, raw);
            try out.append(allocator, 0); // end of output map
        }

        return out.toOwnedSlice(allocator);
    }

    /// Write out a signed (or partially signed) PSBT.
    ///
    /// The original bytes are reused as-is, so **unknown fields are preserved**.
    /// `sigs_by_input` holds the additional signatures per input (public key and DER
    /// signature + sighash type).
    /// A partial sig already present in the original map for the same public key is replaced.
    pub fn serialize(
        allocator: std.mem.Allocator,
        psbt: Psbt,
        sigs_by_input: []const []const PartialSig,
    ) Error![]u8 {
        if (sigs_by_input.len != psbt.inputs.len) return error.InvalidPsbt;

        const fields = try allocator.alloc([]const Field, psbt.inputs.len);
        for (sigs_by_input, 0..) |sigs, i| {
            const list = try allocator.alloc(Field, sigs.len);
            for (sigs, 0..) |sig, j| {
                if (sig.pubkey.len != 33 and sig.pubkey.len != 65) return error.InvalidPsbt;
                const key = try allocator.alloc(u8, 1 + sig.pubkey.len);
                key[0] = IN_PARTIAL_SIG;
                @memcpy(key[1..], sig.pubkey);
                list[j] = .{ .key = key, .value = sig.signature };
            }
            fields[i] = list;
        }
        return serializeWith(allocator, psbt, fields);
    }
};

/// Copy a raw map, dropping any field whose key also appears in `extra`
/// (so that no duplicate keys are created).
fn appendFilteredMap(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
    extra: []const Psbt.Field,
) Error!void {
    var cursor = Cursor{ .data = raw };
    while (cursor.remaining() > 0) {
        const field_start = cursor.pos;
        const key_len = try cursor.readVarInt();
        const key = try cursor.readBytes(@intCast(key_len));
        const value_len = try cursor.readVarInt();
        _ = try cursor.readBytes(@intCast(value_len));

        var skip = false;
        for (extra) |field| {
            if (std.mem.eql(u8, field.key, key)) skip = true;
        }
        if (!skip) try out.appendSlice(allocator, raw[field_start..cursor.pos]);
    }
}

fn parseUnsignedTx(
    allocator: std.mem.Allocator,
    value: []const u8,
) Error!transaction.Transaction {
    return transaction.Transaction.parse(allocator, value) catch |err| switch (err) {
        error.Truncated, error.InvalidEncoding => error.InvalidPsbt,
        else => err,
    };
}

fn checkDuplicate(existing: []const []const u8, key: []const u8) Error!void {
    for (existing) |previous| {
        if (std.mem.eql(u8, previous, key)) return error.InvalidPsbt;
    }
}

fn parseInputMap(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    input: *Input,
) Error![]const u8 {
    const start = cursor.pos;
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var partial_sigs = std.ArrayList(PartialSig).empty;
    var derivations = std.ArrayList(Bip32Derivation).empty;

    while (true) {
        const key_len = try cursor.readVarInt();
        if (key_len == 0) break;
        const key = try cursor.readBytes(@intCast(key_len));
        try checkDuplicate(keys.items, key);
        try keys.append(allocator, key);

        const value_len = try cursor.readVarInt();
        const value = try cursor.readBytes(@intCast(value_len));

        switch (key[0]) {
            IN_NON_WITNESS_UTXO => {
                if (key.len != 1) return error.InvalidPsbt;
                input.non_witness_utxo = try parseUnsignedTx(allocator, value);
            },
            IN_WITNESS_UTXO => {
                if (key.len != 1) return error.InvalidPsbt;
                var utxo_cursor = Cursor{ .data = value };
                const out = try parseTxOut(&utxo_cursor);
                if (utxo_cursor.remaining() != 0) return error.InvalidPsbt;
                input.witness_utxo = out;
            },
            IN_PARTIAL_SIG => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try partial_sigs.append(allocator, .{
                    .pubkey = key[1..],
                    .signature = value,
                });
            },
            IN_SIGHASH_TYPE => {
                if (key.len != 1) return error.InvalidPsbt;
                if (value.len != 4) return error.InvalidPsbt;
                input.sighash_type = std.mem.readInt(u32, value[0..4], .little);
            },
            IN_REDEEM_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                input.redeem_script = value;
            },
            IN_WITNESS_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                input.witness_script = value;
            },
            IN_BIP32_DERIVATION => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try derivations.append(
                    allocator,
                    try parseDerivation(allocator, key[1..], value),
                );
            },
            IN_FINAL_SCRIPTSIG => {
                if (key.len != 1) return error.InvalidPsbt;
                input.final_script_sig = value;
            },
            IN_FINAL_SCRIPTWITNESS => {
                if (key.len != 1) return error.InvalidPsbt;
                var witness_cursor = Cursor{ .data = value };
                const items = try parseWitness(allocator, &witness_cursor);
                if (witness_cursor.remaining() != 0) return error.InvalidPsbt;
                input.final_script_witness = items;
            },
            else => {
                // Unknown types (or types this implementation does not support) are ignored
            },
        }
    }

    input.partial_sigs = try partial_sigs.toOwnedSlice(allocator);
    input.bip32_derivations = try derivations.toOwnedSlice(allocator);
    // Map body, excluding the terminating 0x00
    return cursor.data[start .. cursor.pos - 1];
}

fn parseOutputMap(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    output: *Output,
) Error![]const u8 {
    const start = cursor.pos;
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var derivations = std.ArrayList(Bip32Derivation).empty;

    while (true) {
        const key_len = try cursor.readVarInt();
        if (key_len == 0) break;
        const key = try cursor.readBytes(@intCast(key_len));
        try checkDuplicate(keys.items, key);
        try keys.append(allocator, key);

        const value_len = try cursor.readVarInt();
        const value = try cursor.readBytes(@intCast(value_len));

        switch (key[0]) {
            OUT_REDEEM_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                output.redeem_script = value;
            },
            OUT_WITNESS_SCRIPT => {
                if (key.len != 1) return error.InvalidPsbt;
                output.witness_script = value;
            },
            OUT_BIP32_DERIVATION => {
                if (key.len != 1 + 33 and key.len != 1 + 65) return error.InvalidPsbt;
                try derivations.append(
                    allocator,
                    try parseDerivation(allocator, key[1..], value),
                );
            },
            else => {},
        }
    }

    output.bip32_derivations = try derivations.toOwnedSlice(allocator);
    // Map body, excluding the terminating 0x00
    return cursor.data[start .. cursor.pos - 1];
}

fn parseTxOut(cursor: *Cursor) Error!transaction.TxOut {
    const value = try cursor.readU64();
    const script_pubkey = try cursor.readVarBytes();
    return .{ .value = value, .script_pubkey = script_pubkey };
}

fn parseWitness(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
) Error![]const []const u8 {
    const count = try cursor.readVarInt();
    if (count > 1024) return error.InvalidPsbt;
    const items = try allocator.alloc([]const u8, @intCast(count));
    for (items) |*item| {
        item.* = try cursor.readVarBytes();
    }
    return items;
}

/// BIP32 derivation information (4-byte fingerprint + a sequence of 4-byte indices).
fn parseDerivation(
    allocator: std.mem.Allocator,
    pubkey: []const u8,
    value: []const u8,
) Error!Bip32Derivation {
    if (value.len < 8 or (value.len - 4) % 4 != 0) return error.InvalidPsbt;
    const count = (value.len - 4) / 4;
    const path = try allocator.alloc(u32, count);
    for (path, 0..) |*index, i| {
        index.* = std.mem.readInt(u32, value[4 + i * 4 ..][0..4], .little);
    }
    return .{
        .pubkey = pubkey,
        .fingerprint = value[0..4].*,
        .path = path,
    };
}

/// Whether the public key has a valid form (compressed 33 / uncompressed 65 bytes).
pub fn isValidPubKeyFormat(pubkey: []const u8) bool {
    if (pubkey.len == 33) return pubkey[0] == 2 or pubkey[0] == 3;
    if (pubkey.len == 65) return pubkey[0] == 4;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const sample_psbt_hex = "70736274ff0100550200000001279a2323a5dfb51fc45f220fa58b0fc13e1e3342792a85d7e36cd6333b5cbc390000000000ffffffff01a05aea0b000000001976a914ffe9c0061097cc3b636f2cb0460fa4fc427d2b4588ac0000000000010120955eea0b0000000017a9146345200f68d189e1adc0df1c4d16ea8f14c0dbeb8700000000";

test "rejects a mismatched magic byte" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A network-format transaction (not a PSBT)
    const raw = try allocator.alloc(u8, 8);
    _ = try std.fmt.hexToBytes(raw, "0200000001000000");
    try testing.expectError(error.InvalidPsbt, Psbt.parse(allocator, raw));
}

test "builds and parses a minimal PSBT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // An unsigned transaction with 1 input and 1 output
    var prev_txid: [32]u8 = undefined;
    for (&prev_txid, 0..) |*byte, i| byte.* = @intCast(i);
    const inputs = try allocator.alloc(transaction.TxIn, 1);
    inputs[0] = .{
        .prevout = .{ .txid = prev_txid, .vout = 0 },
        .script_sig = &.{},
        .sequence = 0xFFFFFFFF,
        .witness = &.{},
    };
    var hash20: [20]u8 = undefined;
    for (&hash20, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const script_pubkey = [_]u8{ 0x00, 0x14 } ++ hash20;
    const outputs = try allocator.alloc(transaction.TxOut, 1);
    outputs[0] = .{ .value = 50_000, .script_pubkey = &script_pubkey };

    const tx = transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const raw_tx = try tx.serialize(allocator, false);

    // Build the PSBT
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    try bytes.appendSlice(allocator, &magic);

    // Global: unsigned tx
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, GLOBAL_UNSIGNED_TX);
    try transaction.writeVarInt(&bytes, allocator, raw_tx.len);
    try bytes.appendSlice(allocator, raw_tx);
    try bytes.append(allocator, 0); // end of global map

    // Input map: witness utxo
    var utxo_bytes = std.ArrayList(u8).empty;
    defer utxo_bytes.deinit(allocator);
    var value_le: [8]u8 = undefined;
    std.mem.writeInt(u64, &value_le, 100_000, .little);
    try utxo_bytes.appendSlice(allocator, &value_le);
    try transaction.writeVarBytes(&utxo_bytes, allocator, &script_pubkey);
    try bytes.append(allocator, 1); // keylen
    try bytes.append(allocator, IN_WITNESS_UTXO);
    try transaction.writeVarInt(&bytes, allocator, utxo_bytes.items.len);
    try bytes.appendSlice(allocator, utxo_bytes.items);
    try bytes.append(allocator, 0); // end of input map

    // Output map (empty)
    try bytes.append(allocator, 0);

    const psbt = try Psbt.parse(allocator, bytes.items);
    try testing.expectEqual(@as(usize, 1), psbt.inputs.len);
    try testing.expectEqual(@as(usize, 1), psbt.outputs.len);
    try testing.expectEqual(@as(u64, 100_000), psbt.inputs[0].witness_utxo.?.value);
    try testing.expectEqualSlices(u8, &script_pubkey, psbt.inputs[0].witness_utxo.?.script_pubkey);
    try testing.expectEqual(@as(i32, 2), psbt.unsigned_tx.version);
}

test "key length validation (partial sig public keys are 33 / 65 bytes)" {
    var compressed: [33]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &compressed,
        "025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee6357",
    );
    try testing.expect(isValidPubKeyFormat(&compressed));
    try testing.expect(!isValidPubKeyFormat(&[_]u8{ 0x02, 0x01 }));
    try testing.expect(!isValidPubKeyFormat(&[_]u8{0x01}));
}

test "rejects duplicate keys" {
    // A PSBT that writes the same key twice into the global map
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &magic);
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, GLOBAL_UNSIGNED_TX, 0x01, 0x00 });
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x01, GLOBAL_UNSIGNED_TX, 0x01, 0x00 });

    try testing.expectError(error.InvalidPsbt, Psbt.parse(testing.allocator, bytes.items));
}

test "rejects an exhausted cursor" {
    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &magic);
    // Claims a key length of 10 while only 2 bytes are present
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x0A, 0x00, 0x00 });
    try testing.expectError(error.Truncated, Psbt.parse(testing.allocator, bytes.items));
}
