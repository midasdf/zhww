//! Independent guard tests: official BIP143, pinned Core, primary-path differential
//! mutation checks, malformed/bounded wire input and signing-boundary fault injection.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const zhww = @import("../src/root.zig");
const guard = zhww.p2wpkh_guard;
const testing = std.testing;

fn hex(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, text.len / 2);
    _ = try std.fmt.hexToBytes(out, text);
    return out;
}

fn core(allocator: std.mem.Allocator) ![]u8 {
    const json = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("vectors/core_psbt.json"), .{});
    const text = json.value.object.get("unsigned_psbt_base64").?.string;
    const decoder = std.base64.standard.Decoder;
    const out = try allocator.alloc(u8, try decoder.calcSizeForSlice(text));
    try decoder.decode(out, text);
    return out;
}

fn comparePrimary(allocator: std.mem.Allocator, raw: []const u8, plan: *const guard.Plan) !void {
    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);
    try testing.expectEqual(psbt.inputs.len, plan.count);
    try testing.expectEqual(psbt.outputs.len, plan.output_count);
    for (0..plan.count) |i| {
        const utxo = (try zhww.btc_sign.utxoForDisplay(allocator, psbt, i)).?;
        const code = zhww.btc_sighash.p2wpkhScriptCode(utxo.script_pubkey[2..22].*);
        const primary = try zhww.btc_sighash.segwitV0Sighash(allocator, psbt.unsigned_tx, i, &code, utxo.value, 1);
        try testing.expectEqualSlices(u8, &primary, &plan.hashes[i]);
    }
}

fn extra(allocator: std.mem.Allocator, raw: []const u8, fields: []const zhww.btc_psbt.Psbt.Field) ![]u8 {
    const psbt = try zhww.btc_psbt.Psbt.parse(allocator, raw);
    return zhww.btc_psbt.Psbt.serializeWith(allocator, psbt, &.{fields});
}

// Test-only PSBT wrapping. Primary serializer is allowed in tests, never in guard implementation.
fn wrapTransaction(allocator: std.mem.Allocator, original: []const u8, tx: []const u8) ![]u8 {
    var psbt = try zhww.btc_psbt.Psbt.parse(allocator, original);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(allocator, &.{ 1, 0 });
    try zhww.btc_transaction.writeVarBytes(&global, allocator, tx);
    psbt.global_raw = try global.toOwnedSlice(allocator);
    return zhww.btc_psbt.Psbt.serializeWith(allocator, psbt, &.{&.{}});
}

fn explicitMetadata(a: std.mem.Allocator, original: []const u8, fields: []const zhww.btc_psbt.Psbt.Field) ![]u8 {
    var psbt = try zhww.btc_psbt.Psbt.parse(a, original);
    const utxo = psbt.inputs[0].witness_utxo.?;
    var value: [31]u8 = undefined;
    std.mem.writeInt(u64, value[0..8], utxo.value, .little);
    value[8] = 22;
    @memcpy(value[9..31], utxo.script_pubkey);
    var map = std.ArrayList(u8).empty;
    try map.appendSlice(a, &.{ 1, 1 });
    try zhww.btc_transaction.writeVarBytes(&map, a, &value);
    for (fields) |field| {
        try zhww.btc_transaction.writeVarBytes(&map, a, field.key);
        try zhww.btc_transaction.writeVarBytes(&map, a, field.value);
    }
    psbt.input_raw = &.{map.items};
    return zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{&.{}});
}

fn derivation(a: std.mem.Allocator, raw: []const u8) !zhww.btc_psbt.Psbt.Field {
    _ = raw; // Core fixture intentionally contains no BIP32 metadata.
    const json = try std.json.parseFromSlice(std.json.Value, a, @embedFile("vectors/core_psbt.json"), .{});
    var seed: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try zhww.bip39.mnemonicToSeed(&seed, json.value.object.get("mnemonic").?.string, "");
    var keys = try zhww.btc_sign.KeySource.fromSeed(&seed);
    defer keys.wipe();
    const path = [_]u32{ 0x80000054, 0x80000000, 0x80000000, 0, 0 };
    var node = try keys.derive(&path);
    defer node.wipe();
    const public = try node.publicKey();
    const key = try std.mem.concat(a, u8, &.{ &.{6}, &public });
    const value = try a.alloc(u8, 24);
    @memcpy(value[0..4], &keys.master_fingerprint);
    for (path, 0..) |index, i| std.mem.writeInt(u32, value[4 + i * 4 ..][0..4], index, .little);
    return .{ .key = key, .value = value };
}

test "guard bounds supplied BIP84 paths and refuses long or non-wallet paths" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    const d = try derivation(a, raw);
    _ = try guard.Plan.fromPsbt(try explicitMetadata(a, raw, &.{d}));
    _ = try guard.Plan.fromPsbt(try explicitMetadata(a, raw, &.{})); // bounded metadata-free BIP84 discovery
    const cases = [_]struct { index: usize, value: u32 }{
        .{ .index = 0, .value = 0x8000002c }, // BIP44
        .{ .index = 1, .value = 0x8000003c }, // EVM coin type
        .{ .index = 2, .value = 0 }, // non-hardened account
        .{ .index = 3, .value = 2 }, // unknown branch
        .{ .index = 4, .value = 0x80000000 }, // hardened address index
    };
    for (cases) |case| {
        const value = try a.dupe(u8, d.value);
        std.mem.writeInt(u32, value[4 + case.index * 4 ..][0..4], case.value, .little);
        try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(try explicitMetadata(a, raw, &.{.{ .key = d.key, .value = value }})));
    }
    const long = try a.alloc(u8, 4 + 1024 * 4);
    @memset(long, 0);
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(try explicitMetadata(a, raw, &.{.{ .key = d.key, .value = long }})));
}

test "guard caps explicit derivation candidates at eight" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    const d = try derivation(a, raw);
    var fields: [guard.max_derivations_per_input + 1]zhww.btc_psbt.Psbt.Field = undefined;
    for (&fields, 0..) |*field, i| {
        var private: [32]u8 = @splat(0);
        defer std.crypto.secureZero(u8, &private);
        private[31] = @intCast(i + 1);
        const public = try zhww.secp256k1.pubKeyCompressed(private);
        field.* = .{ .key = try std.mem.concat(a, u8, &.{ &.{6}, &public }), .value = d.value };
    }
    _ = try guard.Plan.fromPsbt(try explicitMetadata(a, raw, fields[0..guard.max_derivations_per_input]));
    try testing.expectError(error.GuardLimit, guard.Plan.fromPsbt(try explicitMetadata(a, raw, &fields)));
}

test "guarded signer caps metadata-free scan, refuses explicit mismatch fallback and never infers change" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    const json = try std.json.parseFromSlice(std.json.Value, a, @embedFile("vectors/core_psbt.json"), .{});
    var seed: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &seed);
    try zhww.bip39.mnemonicToSeed(&seed, json.value.object.get("mnemonic").?.string, "");
    var keys = try zhww.btc_sign.KeySource.fromSeed(&seed);
    defer keys.wipe();
    const plan = try guard.Plan.fromPsbt(raw);
    keys.max_index = zhww.btc_sign.approved_max_scan_index + 1;
    try testing.expectError(error.InvalidPath, zhww.btc_sign.signPsbtWithPlan(a, raw, &keys, plan.hashes[0..plan.count]));
    keys.max_index = zhww.btc_sign.approved_max_scan_index;
    const signed = try zhww.btc_sign.signPsbtWithPlan(a, raw, &keys, plan.hashes[0..plan.count]);
    try testing.expectEqual(@as(usize, 0), signed.result.change_outputs.len);
    const d = try derivation(a, raw);
    const value = try a.dupe(u8, d.value);
    value[0] ^= 1; // wrong fingerprint, but correct script/key exists on fallback path
    const changed = try explicitMetadata(a, raw, &.{.{ .key = d.key, .value = value }});
    const changed_plan = try guard.Plan.fromPsbt(changed);
    try testing.expectError(error.NoMatchingKey, zhww.btc_sign.signPsbtWithPlan(a, changed, &keys, changed_plan.hashes[0..changed_plan.count]));
    const development = try zhww.btc_sign.signPsbtWithKeys(a, changed, &keys);
    try testing.expectEqual(@as(usize, 1), development.result.partial_sigs.len); // compatibility still scans
}

test "independent wire calculator matches the official native P2WPKH BIP143 hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const json = try std.json.parseFromSlice(std.json.Value, a, @embedFile("vectors/bip143.json"), .{});
    const root = json.value.object;
    const tx = try hex(a, root.get("unsigned_tx").?.string);
    const expected = try hex(a, root.get("sighash_input1").?.string);
    var program: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&program, "1d0f172a0ecb48aee1be1f2687d2963ae33f71a1");
    const amount: u64 = @intCast(root.get("input1").?.object.get("value_sats").?.integer);
    const independent = try guard.hashUnsignedTransaction(tx, 1, amount, &program);
    try testing.expectEqualSlices(u8, expected, &independent);
    try testing.expectError(error.GuardInvalid, guard.hashUnsignedTransaction(tx, 2, amount, &program));
}

test "independent Core plan agrees with primary messages and exact totals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    const plan = try guard.Plan.fromPsbt(raw);
    try comparePrimary(a, raw, &plan);
    try testing.expectEqual(@as(u64, 100000000), plan.total_input);
    try testing.expectEqual(@as(u64, 99990000), plan.total_output);
    try testing.expectEqual(@as(u64, 10000), plan.fee);
    try testing.expectEqual(@as(usize, 1), plan.count);
}

test "guard refuses every truncation and trailing bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    for (0..raw.len) |length| {
        if (guard.Plan.fromPsbt(raw[0..length])) |_| return error.TestUnexpectedResult else |_| {}
    }
    const trailing = try std.mem.concat(a, u8, &.{ raw, &.{0} });
    try testing.expectError(error.GuardInvalid, guard.Plan.fromPsbt(trailing));
}

test "guard rejects duplicate fields, noncanonical lengths and oversized requests" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    // Preserve the whole PSBT but replace first key length 1 with noncanonical fd0100.
    const noncanonical = try std.mem.concat(a, u8, &.{ raw[0..5], &.{ 0xfd, 1, 0 }, raw[6..] });
    try testing.expectError(error.GuardInvalid, guard.Plan.fromPsbt(noncanonical));
    var psbt = try zhww.btc_psbt.Psbt.parse(a, raw);
    psbt.input_raw = &.{try std.mem.concat(a, u8, &.{ psbt.input_raw[0], psbt.input_raw[0] })};
    const duplicate = try zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{&.{}});
    try testing.expectError(error.GuardInvalid, guard.Plan.fromPsbt(duplicate));
    const oversized = try a.alloc(u8, 64 * 1024 + 1);
    try testing.expectError(error.GuardLimit, guard.Plan.fromPsbt(oversized));
}

test "guard refuses unsupported UTXOs, finalized inputs and alternate sighash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    const non_all = try extra(a, raw, &.{.{ .key = &.{3}, .value = &.{ 0x81, 0, 0, 0 } }});
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(non_all));
    const finalized = try extra(a, raw, &.{.{ .key = &.{7}, .value = &.{} }});
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(finalized));
    // Even a redundant non_witness_utxo is outside the narrow independent policy.
    const previous = try extra(a, raw, &.{.{ .key = &.{0}, .value = &.{} }});
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(previous));
    var missing = try zhww.btc_psbt.Psbt.parse(a, raw);
    missing.input_raw = &.{&.{}};
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(try zhww.btc_psbt.Psbt.serializeWith(a, missing, &.{&.{}})));
    var invalid: [31]u8 = @splat(0);
    invalid[8] = 22;
    invalid[9] = 0x51; // witness v1 is not P2WPKH
    invalid[10] = 20;
    const wrong = try extra(a, raw, &.{.{ .key = &.{1}, .value = &invalid }});
    try testing.expectError(error.GuardUnsupported, guard.Plan.fromPsbt(wrong));
}

test "guard caps irrelevant map fields independently of the primary parser" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    var psbt = try zhww.btc_psbt.Psbt.parse(a, raw);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(a, psbt.global_raw);
    for (0..guard.max_fields_per_map) |i| {
        try global.appendSlice(a, &.{ 2, 0xfa, @intCast(i), 0 });
    }
    psbt.global_raw = try global.toOwnedSlice(a);
    const crowded = try zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{&.{}});
    _ = try zhww.btc_psbt.Psbt.parse(a, crowded);
    try testing.expectError(error.GuardLimit, guard.Plan.fromPsbt(crowded));
    psbt.global_raw = psbt.global_raw[0 .. psbt.global_raw.len - 4];
    const at_limit = try zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{&.{}});
    _ = try guard.Plan.fromPsbt(at_limit); // unsigned-tx + 127 unknown keys = 128 fields
}

test "hostile CompactSize lengths and excessive input counts fail without overflow" {
    const huge = [_]u8{ 0x70, 0x73, 0x62, 0x74, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const expected = if (@bitSizeOf(usize) == 32) error.GuardLimit else error.GuardTruncated;
    try testing.expectError(expected, guard.Plan.fromPsbt(&huge));
    const noncanonical = [_]u8{ 0x70, 0x73, 0x62, 0x74, 0xff, 0xfe, 1, 0, 0, 0 };
    try testing.expectError(error.GuardInvalid, guard.Plan.fromPsbt(&noncanonical));
    try testing.expectError(error.GuardLimit, guard.hashUnsignedTransaction(&.{ 2, 0, 0, 0, 32 }, 0, 1, &@as([20]u8, @splat(0))));
}

test "primary signer rejects wrong plan length or message before key discovery" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    var plan = try guard.Plan.fromPsbt(raw);
    const no_keys: zhww.btc_sign.KeySource = .{};
    try testing.expectError(error.SigningPlanMismatch, zhww.btc_sign.signPsbtWithPlan(a, raw, &no_keys, &.{}));
    plan.hashes[0][0] ^= 1;
    try testing.expectError(error.SigningPlanMismatch, zhww.btc_sign.signPsbtWithPlan(a, raw, &no_keys, plan.hashes[0..plan.count]));
    plan.hashes[0][0] ^= 1;
    try testing.expectError(error.NoMatchingKey, zhww.btc_sign.signPsbtWithPlan(a, raw, &no_keys, plan.hashes[0..plan.count]));
}

test "every input plan is checked before discovering the first signing key" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = try core(a);
    var psbt = try zhww.btc_psbt.Psbt.parse(a, raw);
    const original_input = psbt.inputs[0];
    const original_raw = psbt.input_raw[0];
    const inputs = try a.alloc(zhww.btc_transaction.TxIn, 2);
    inputs[0] = psbt.unsigned_tx.inputs[0];
    inputs[1] = inputs[0];
    inputs[1].prevout.vout += 1;
    psbt.unsigned_tx.inputs = inputs;
    psbt.inputs = try a.alloc(zhww.btc_psbt.Input, 2);
    @memset(psbt.inputs, original_input);
    psbt.input_raw = &.{ original_raw, original_raw };
    const tx = try psbt.unsigned_tx.serialize(a, false);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(a, &.{ 1, 0 });
    try zhww.btc_transaction.writeVarBytes(&global, a, tx);
    psbt.global_raw = try global.toOwnedSlice(a);
    const two_inputs = try zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{ &.{}, &.{} });
    var plan = try guard.Plan.fromPsbt(two_inputs);
    try comparePrimary(a, two_inputs, &plan);
    plan.hashes[1][0] ^= 1; // first hash valid, SECOND hash wrong
    const no_keys: zhww.btc_sign.KeySource = .{};
    // NoMatchingKey would mean the implementation started processing input 0 too early.
    try testing.expectError(error.SigningPlanMismatch, zhww.btc_sign.signPsbtWithPlan(a, two_inputs, &no_keys, plan.hashes[0..plan.count]));
}

test "independent and primary hashes agree for accepted transaction byte mutations" {
    var setup = std.heap.ArenaAllocator.init(testing.allocator);
    defer setup.deinit();
    const a = setup.allocator();
    const raw = try core(a);
    const parsed = try zhww.btc_psbt.Psbt.parse(a, raw);
    const tx = try parsed.unsigned_tx.serialize(a, false);
    var random = std.Random.DefaultPrng.init(0x2350143);
    var accepted: usize = 0;
    for (0..512) |_| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const mutated = try scratch.dupe(u8, tx);
        const index = random.random().uintLessThan(usize, mutated.len);
        mutated[index] ^= random.random().int(u8) | 1;
        const request = try wrapTransaction(scratch, raw, mutated);
        const plan = guard.Plan.fromPsbt(request) catch continue;
        try comparePrimary(scratch, request, &plan);
        accepted += 1;
    }
    try testing.expect(accepted > 100);
    std.debug.print("\nIndependent P2WPKH guard: {d}/512 transaction mutations accepted and matched primary hashes\n", .{accepted});
}
