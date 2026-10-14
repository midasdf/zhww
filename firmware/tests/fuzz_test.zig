//! Robustness tests against corrupt input (a kind of mutation testing / fuzzing).
//!
//! **Why this matters**: the PSBTs the device scans from the camera are
//! **untrusted data coming from outside**. If a parser crashes or hangs, the worst case
//! is that it stops in the middle of signing ([docs/05-threat-model.md] 4-6, "implementation bugs").
//!
//! Here we corrupt valid data little by little and feed in a large number of mutants,
//! checking that it **either parses successfully or returns an error** (no crash, no hang).
//!
//! The RNG uses a fixed seed (so a failure can be reproduced). Under Debug / ReleaseSafe
//! safety checks are enabled, so out-of-bounds accesses and integer overflows are caught here too.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const Fuzz = struct {
    prng: std.Random.DefaultPrng,

    fn init(seed: u64) Fuzz {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    /// **Caution**: `std.Random` holds a pointer to the random number generator.
    /// Storing it in a struct and returning that struct copies the pointee (itself) and
    /// **dangles**. It is therefore created on every use.
    fn random(self: *Fuzz) std.Random {
        return self.prng.random();
    }

    /// Corrupt the data a little (1 to 8 places).
    fn mutate(self: *Fuzz, data: []u8) void {
        const changes = 1 + self.random().uintLessThan(usize, 8);
        for (0..changes) |_| {
            if (data.len == 0) return;
            switch (self.random().uintLessThan(u8, 5)) {
                0 => data[self.random().uintLessThan(usize, data.len)] ^= @as(u8, 1) << @intCast(self.random().uintLessThan(u4, 8)),
                1 => data[self.random().uintLessThan(usize, data.len)] = self.random().int(u8),
                2 => {
                    // Truncate
                    const at = self.random().uintLessThan(usize, data.len);
                    data[at] = 0;
                },
                3 => {
                    // Corrupt the edge
                    if (self.random().boolean()) {
                        data[0] = self.random().int(u8);
                    } else {
                        data[data.len - 1] = self.random().int(u8);
                    }
                },
                else => {
                    // Swap 2 bytes
                    const a = self.random().uintLessThan(usize, data.len);
                    const b = self.random().uintLessThan(usize, data.len);
                    const tmp = data[a];
                    data[a] = data[b];
                    data[b] = tmp;
                },
            }
        }
    }
};

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const out = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(out, encoded);
    return out;
}

test "PSBT: does not crash on corrupt input (2000 mutants)" {
    const vectors = @embedFile("vectors/core_psbt.json");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed_json = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const base64 = parsed_json.value.object.get("unsigned_psbt_base64").?.string;
    const valid = try decodeBase64(allocator, base64);

    var fuzz = Fuzz.init(0x5EED_1234);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..2000) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, valid);
        fuzz.mutate(mutated);

        const result = zhww.btc_psbt.Psbt.parse(a, mutated);
        if (result) |psbt| {
            ok += 1;
            // Whatever parsed must be writable and readable again (round trip)
            const sigs = try a.alloc([]const zhww.btc_psbt.PartialSig, psbt.inputs.len);
            for (sigs) |*s| s.* = &.{};
            const serialized = try zhww.btc_psbt.Psbt.serialize(a, psbt, sigs);
            const reparsed = try zhww.btc_psbt.Psbt.parse(a, serialized);
            try testing.expectEqual(psbt.inputs.len, reparsed.inputs.len);
            try testing.expectEqual(psbt.outputs.len, reparsed.outputs.len);
            try testing.expectEqual(psbt.unsigned_tx.inputs.len, reparsed.unsigned_tx.inputs.len);
            try testing.expectEqual(psbt.unsigned_tx.outputs.len, reparsed.unsigned_tx.outputs.len);
        } else |_| {
            failed += 1;
        }

        // No pathological allocations (under 1MB per case)
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    // Most mutants should fail to parse (= the checks are working)
    try testing.expect(failed > ok);
    try testing.expect(ok + failed == 2000);
    std.debug.print("\n  PSBT: parsed {d} / failed {d}\n", .{ ok, failed });
}

test "transaction: does not crash on corrupt input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build an arbitrary transaction, then corrupt it
    const inputs = try allocator.alloc(zhww.btc_transaction.TxIn, 2);
    inputs[0] = .{ .prevout = .{ .txid = @splat(0x11), .vout = 0 }, .script_sig = &.{}, .sequence = 0xFFFFFFFF, .witness = &.{} };
    inputs[1] = .{ .prevout = .{ .txid = @splat(0x22), .vout = 1 }, .script_sig = &.{}, .sequence = 0, .witness = &.{} };
    const outputs = try allocator.alloc(zhww.btc_transaction.TxOut, 1);
    outputs[0] = .{ .value = 1000, .script_pubkey = &[_]u8{ 0x00, 0x14 } };
    const tx = zhww.btc_transaction.Transaction{
        .version = 2,
        .inputs = inputs,
        .outputs = outputs,
        .lock_time = 0,
        .has_witness = false,
    };
    const bytes = try tx.serialize(allocator, false);

    var fuzz = Fuzz.init(0xABCD_5678);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..1000) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, bytes);
        fuzz.mutate(mutated);

        if (zhww.btc_transaction.Transaction.parse(a, mutated)) |parsed_tx| {
            ok += 1;
            // Round-trips to the same shape
            const again = try parsed_tx.serialize(a, parsed_tx.has_witness);
            const reparsed = try zhww.btc_transaction.Transaction.parse(a, again);
            try testing.expectEqual(parsed_tx.inputs.len, reparsed.inputs.len);
            try testing.expectEqual(parsed_tx.outputs.len, reparsed.outputs.len);
            try testing.expectEqual(parsed_tx.version, reparsed.version);
        } else |_| {
            failed += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    try testing.expect(ok + failed == 1000);
    std.debug.print("  Transaction: parsed {d} / failed {d}\n", .{ ok, failed });
}

test "UR / Bytewords: rejects corrupt strings" {
    var fuzz = Fuzz.init(0x0BAD_F00D);
    const alphabet = "ur:bytes/1-2/lpadacslbcyfmemqdoshdcxjojkidjyzmadaegmaoaeaeaeadswmuoygamogscfkodwknsrmdvwkttlfsfnluwysewzlubg-ZZ00";

    for (0..500) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const length = 1 + fuzz.random().uintLessThan(usize, 60);
        const text = try a.alloc(u8, length);
        for (text) |*c| c.* = alphabet[fuzz.random().uintLessThan(usize, alphabet.len)];

        // Parsing may succeed or fail, but it must not crash
        if (zhww.ur.parse(text)) |uri| {
            try testing.expect(uri.ur_type.len <= zhww.ur.max_type_len);
        } else |_| {}

        // Also exercise the path that reads them as parts
        var part_buffer: [4096]u8 = undefined;
        if (zhww.ur.decodePartUr(&part_buffer, text)) |decoded| {
            try testing.expect(decoded.part.data.len <= part_buffer.len);
        } else |_| {}

        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }
}

test "EVM: rejects corrupt raw transactions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw_hex = "02f86f0107843b9aca008506fc23ac0082520894353535353535353535353535353535353535353584075bcd1580c080a08b29bfd611a0f695677f38218b2a6d02218f906adedbb1f171aa49b261794de2a02e5c9604faa6d3f48c89f8568aa04ea6cef7e058d0464ef4447989524c1bd4cf";
    const valid = try allocator.alloc(u8, raw_hex.len / 2);
    _ = try std.fmt.hexToBytes(valid, raw_hex);

    var fuzz = Fuzz.init(0x1234_5678);
    var ok: usize = 0;
    var failed: usize = 0;

    for (0..500) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        const mutated = try a.dupe(u8, valid);
        fuzz.mutate(mutated);

        if (zhww.evm_transaction.decode(a, mutated)) |decoded| {
            ok += 1;
            // Even for corrupt input, the values returned must stay consistent
            if (decoded.to) |to| try testing.expectEqual(@as(usize, 20), to.len);
            try testing.expect(decoded.data.len <= mutated.len);
        } else |_| {
            failed += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    try testing.expect(ok + failed == 500);
    std.debug.print("  EVM: parsed {d} / failed {d}\n", .{ ok, failed });
}

test "BIP39: rejects garbage mnemonics" {
    const words = [_][]const u8{ "abandon", "about", "zoo", "notaword", "", "A", "日本語" };
    var fuzz = Fuzz.init(0x9999_1111);
    var accepted: usize = 0;
    var rejected: usize = 0;

    for (0..300) |_| {
        var iteration = std.heap.ArenaAllocator.init(testing.allocator);
        defer iteration.deinit();
        const a = iteration.allocator();

        var list = std.ArrayList(u8).empty;
        const count = 1 + fuzz.random().uintLessThan(usize, 30);
        for (0..count) |i| {
            if (i > 0) try list.append(a, ' ');
            try list.appendSlice(a, words[fuzz.random().uintLessThan(usize, words.len)]);
        }

        var seed: [64]u8 = undefined;
        if (zhww.bip39.mnemonicToSeed(&seed, list.items, "")) |_| {
            accepted += 1;
        } else |_| {
            rejected += 1;
        }
        try testing.expect(iteration.queryCapacity() < 1024 * 1024);
    }

    std.debug.print("  BIP39: accepted {d} / rejected {d}\n", .{ accepted, rejected });
    try testing.expect(rejected > accepted);
}
