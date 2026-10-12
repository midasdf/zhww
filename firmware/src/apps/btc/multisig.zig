//! Construction and signing of P2WSH multisig (BIP67 sortedmulti).
//!
//! Reference: BIP67 (lexicographic key sorting), BIP141 (P2WSH), BIP143 (signature hash)
//!
//! **Design policy**
//! - Multisig is what keeps funds safe when one device breaks or is stolen, and it is
//!   the core of this project's recommended operation ([docs/05-threat-model.md])
//! - The witnessScript is `OP_m <pubkey>... OP_n OP_CHECKMULTISIG`. Signatures must be
//!   ordered **as the public keys appear in the script** (an OP_CHECKMULTISIG rule)
//! - Every signature is verified with `secp256k1.verify` before being returned

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const transaction = @import("transaction.zig");
const sighash = @import("sighash.zig");

pub const SIGHASH_ALL: u32 = 0x01;

/// A key usable for signing.
pub const Signer = struct {
    private_key: [32]u8,
    public_key: [33]u8,
};

/// Sort public keys per BIP67 (lexicographic order).
pub fn sortPubKeys(allocator: std.mem.Allocator, pubkeys: []const [33]u8) Error![][33]u8 {
    const out = try allocator.alloc([33]u8, pubkeys.len);
    @memcpy(out, pubkeys);
    std.mem.sort([33]u8, out, {}, struct {
        fn lessThan(_: void, a: [33]u8, b: [33]u8) bool {
            return std.mem.lessThan(u8, &a, &b);
        }
    }.lessThan);
    return out;
}

/// Build `OP_m <pubkey>... OP_n OP_CHECKMULTISIG`.
///
/// `pubkeys` must already be sorted per BIP67 (use `sortPubKeys`).
pub fn witnessScript(
    allocator: std.mem.Allocator,
    required: usize,
    pubkeys: []const [33]u8,
) Error![]u8 {
    if (required < 1 or required > pubkeys.len or pubkeys.len > 15) {
        return error.InvalidEncoding;
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, 0x50 + @as(u8, @intCast(required))); // OP_m
    for (pubkeys) |pub_key| {
        try out.append(allocator, 33);
        try out.appendSlice(allocator, &pub_key);
    }
    try out.append(allocator, 0x50 + @as(u8, @intCast(pubkeys.len))); // OP_n
    try out.append(allocator, 0xae); // OP_CHECKMULTISIG
    return out.toOwnedSlice(allocator);
}

/// Build the P2WSH scriptPubKey (`0020{sha256}`) from a witnessScript.
pub fn scriptPubKey(witness_script_bytes: []const u8) [34]u8 {
    var hash: [32]u8 = undefined;
    hashes.Sha256.hash(witness_script_bytes, &hash, .{});
    var script: [34]u8 = undefined;
    script[0] = 0x00;
    script[1] = 0x20;
    @memcpy(script[2..34], &hash);
    return script;
}

pub const ParsedScript = struct {
    required: usize,
    pubkeys: [15][33]u8,
    count: usize,

    /// **Caution**: `self` must not be passed by value.
    /// Returning a slice that points inside a by-value struct leaves the caller with
    /// an invalid reference (a test actually caught this bug).
    pub fn slice(self: *const ParsedScript) []const [33]u8 {
        return self.pubkeys[0..self.count];
    }
};

/// Parse a witnessScript (only `OP_m <pubkey>... OP_n OP_CHECKMULTISIG` is supported).
pub fn parseWitnessScript(script: []const u8) Error!ParsedScript {
    if (script.len < 3) return error.InvalidEncoding;
    if (script[script.len - 1] != 0xae) return error.InvalidEncoding; // OP_CHECKMULTISIG

    const required_op = script[0];
    if (required_op < 0x51 or required_op > 0x60) return error.InvalidEncoding;
    const required: usize = required_op - 0x50;

    var result: ParsedScript = .{ .required = required, .pubkeys = undefined, .count = 0 };
    var pos: usize = 1;
    // The last 2 bytes (OP_n and OP_CHECKMULTISIG) are not public keys
    while (script.len - pos > 2) {
        const push = script[pos];
        if (push != 33) return error.InvalidEncoding;
        if (pos + 34 > script.len - 1) return error.InvalidEncoding;
        if (result.count >= 15) return error.InvalidEncoding;
        @memcpy(&result.pubkeys[result.count], script[pos + 1 .. pos + 34]);
        if (!secp256k1.isValidPublicKey(&result.pubkeys[result.count])) return error.InvalidEncoding;
        result.count += 1;
        pos += 34;
    }

    // Check the last byte (OP_n)
    const total_op = script[script.len - 2];
    if (total_op < 0x51 or total_op > 0x60) return error.InvalidEncoding;
    if (total_op - 0x50 != result.count) return error.InvalidEncoding;
    if (required > result.count) return error.InvalidEncoding;
    return result;
}

/// Signature hash for a P2WSH input (BIP143; the scriptCode is the witnessScript itself).
pub fn sighashForP2wsh(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    witness_script_bytes: []const u8,
    amount: u64,
) Error![32]u8 {
    return sighash.segwitV0Sighash(
        allocator,
        tx,
        input_index,
        witness_script_bytes,
        amount,
        SIGHASH_ALL,
    );
}

/// Sign a P2WSH input and return the signatures (DER + sighash type) **in the order they appear in the witnessScript**.
///
/// Of the keys in `signers`, only those matching a public key that appears in the witnessScript are used.
pub fn signP2wsh(
    allocator: std.mem.Allocator,
    tx: transaction.Transaction,
    input_index: usize,
    witness_script_bytes: []const u8,
    amount: u64,
    signers: []const Signer,
) Error![]const []const u8 {
    const parsed = try parseWitnessScript(witness_script_bytes);
    const message = try sighashForP2wsh(
        allocator,
        tx,
        input_index,
        witness_script_bytes,
        amount,
    );

    var signatures = std.ArrayList([]const u8).empty;
    errdefer signatures.deinit(allocator);

    // OP_CHECKMULTISIG requires signatures in the same order as the public keys
    for (parsed.slice()) |pub_key| {
        for (signers) |signer| {
            if (!std.mem.eql(u8, &signer.public_key, &pub_key)) continue;

            const signature = try secp256k1.sign(message, signer.private_key);
            if (!(try secp256k1.verify(&signature, message, pub_key))) {
                return error.SignatureInvalid;
            }
            var der_buf: [72]u8 = undefined;
            const der = try secp256k1.serializeDer(&der_buf, &signature);
            const blob = try allocator.alloc(u8, der.len + 1);
            @memcpy(blob[0..der.len], der);
            blob[der.len] = @intCast(SIGHASH_ALL);
            try signatures.append(allocator, blob);
            break;
        }
        // CHECKMULTISIG consumes exactly `required` signatures. Supplying signatures for every
        // available key in a 2-of-3 script leaves an extra stack item and fails clean-stack rules.
        if (signatures.items.len == parsed.required) break;
    }

    if (signatures.items.len < parsed.required) return error.NoMatchingKey;
    return signatures.toOwnedSlice(allocator);
}

/// Build the witness stack from the signatures.
///
/// `[empty element, signature..., witnessScript]` (the leading empty element is required by OP_CHECKMULTISIG).
pub fn buildWitness(
    allocator: std.mem.Allocator,
    signatures: []const []const u8,
    witness_script_bytes: []const u8,
) Error![]const []const u8 {
    const witness = try allocator.alloc([]const u8, signatures.len + 2);
    witness[0] = &.{};
    for (signatures, 0..) |signature, i| witness[i + 1] = signature;
    witness[signatures.len + 1] = witness_script_bytes;
    return witness;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn hexToFixed(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "2-of-3 witnessScript matches Bitcoin Core's createmultisig" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The value Bitcoin Core's createmultisig produced on regtest (obtained by running it).
    //
    // **Caution**: Core's createmultisig uses `multi()` (which preserves the given order).
    // That is a different thing from BIP67's `sortedmulti()` (which sorts keys
    // lexicographically), and the same keys in a different order give a different address.
    // Here we compare against the order Core produced, and verify sorting itself in a separate test.
    const k1 = hexToFixed(33, "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0");
    const k2 = hexToFixed(33, "033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f");
    const k3 = hexToFixed(33, "03bca5f67b028685140f87c46956647cd1d6042d83f8a0d5621c9c84d6148fe8d0");

    const script = try witnessScript(allocator, 2, &[_][33]u8{ k1, k2, k3 });

    const expected_hex = "522103dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e021033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f2103bca5f67b028685140f87c46956647cd1d6042d83f8a0d5621c9c84d6148fe8d053ae";
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try testing.expectEqualSlices(u8, &expected, script);

    // The scriptPubKey also matches Core's witness_utxo
    const spk = scriptPubKey(script);
    var expected_spk: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_spk,
        "0020238359dc6fe67694593c6335d53470ec4312ce48bfb4c022a8de82c08ec1554f",
    );
    try testing.expectEqualSlices(u8, &expected_spk, &spk);

    // Also confirm that sorting per BIP67 gives a different script (because the order changes)
    const sorted = try sortPubKeys(allocator, &[_][33]u8{ k1, k2, k3 });
    const sorted_script = try witnessScript(allocator, 2, sorted);
    try testing.expect(!std.mem.eql(u8, script, sorted_script));
    try testing.expect(std.mem.lessThan(u8, &sorted[0], &sorted[1]));
}

test "witnessScript parsing (round trip)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const k1 = hexToFixed(33, "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0");
    const k2 = hexToFixed(33, "033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f");
    const k3 = hexToFixed(33, "03bca5f67b028685140f87c46956647cd1d6042d83f8a0d5621c9c84d6148fe8d0");

    const sorted = try sortPubKeys(allocator, &[_][33]u8{ k3, k1, k2 });
    const script = try witnessScript(allocator, 2, sorted);

    const parsed = try parseWitnessScript(script);
    try testing.expectEqual(@as(usize, 2), parsed.required);
    try testing.expectEqual(@as(usize, 3), parsed.count);
    for (parsed.slice()) |pub_key| {
        var found = false;
        for ([_][33]u8{ k1, k2, k3 }) |candidate| {
            if (std.mem.eql(u8, &candidate, &pub_key)) found = true;
        }
        try testing.expect(found);
    }

    // Reject a broken script
    try testing.expectError(error.InvalidEncoding, parseWitnessScript(&[_]u8{ 0x52, 0x21 }));
    var broken = try allocator.dupe(u8, script);
    broken[broken.len - 1] = 0xad; // not OP_CHECKMULTISIG
    try testing.expectError(error.InvalidEncoding, parseWitnessScript(broken));
}

test "BIP67 sorting is lexicographic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const a = hexToFixed(33, "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0");
    const b = hexToFixed(33, "033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f");
    const sorted = try sortPubKeys(allocator, &[_][33]u8{ a, b });
    try testing.expect(std.mem.lessThan(u8, &sorted[0], &sorted[1]));
}

test "buildWitness shape (leading empty element)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const signature = [_]u8{ 0xDE, 0xAD };
    const script = [_]u8{0x52};
    const witness = try buildWitness(allocator, &[_][]const u8{&signature}, &script);
    try testing.expectEqual(@as(usize, 3), witness.len);
    try testing.expectEqual(@as(usize, 0), witness[0].len);
    try testing.expectEqualSlices(u8, &signature, witness[1]);
    try testing.expectEqualSlices(u8, &script, witness[2]);
}
