//! Approved workflow checks against the pinned Bitcoin Core vector, with synthetic
//! trusted display/GPIO events. This does not test a real LCD, GPIO or TrustZone.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;
const review_mod = zhww.btc_review;
const Workflow = zhww.btc_approved_sign.Workflow;
const Fixture = struct { raw: []u8, seed: [64]u8, expected_tx: []u8 };

fn fixture(allocator: std.mem.Allocator) !Fixture {
    const json = try std.json.parseFromSlice(std.json.Value, allocator, @embedFile("vectors/core_psbt.json"), .{});
    const root = json.value.object;
    const encoded = root.get("unsigned_psbt_base64").?.string;
    const decoder = std.base64.standard.Decoder;
    const raw = try allocator.alloc(u8, try decoder.calcSizeForSlice(encoded));
    try decoder.decode(raw, encoded);
    var seed: [64]u8 = undefined;
    try zhww.bip39.mnemonicToSeed(&seed, root.get("mnemonic").?.string, "");
    const hex = root.get("expected_final_tx").?.string;
    const expected = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(expected, hex);
    return .{ .raw = raw, .seed = seed, .expected_tx = expected };
}

fn evidence() zhww.boot_policy.Evidence {
    var e: zhww.boot_policy.Evidence = .{ .stepping = .a4 };
    inline for (comptime std.meta.fieldNames(zhww.boot_policy.Evidence)) |name| {
        if (@TypeOf(@field(e, name)) == bool) @field(e, name) = true;
    }
    return e;
}

fn approve(w: *Workflow) !void {
    for (0..w.review.count) |i|
        try w.displayed(i, (try w.review.page(i)).bytes(), @intCast(i + 1));
    try w.button(false, 100);
    try w.button(true, 101);
    try w.button(false, 1101);
}

fn twoInputs(a: std.mem.Allocator, raw: []const u8, foreign_second: bool) ![]u8 {
    var psbt = try zhww.btc_psbt.Psbt.parse(a, raw);
    const original = psbt.inputs[0];
    const original_map = psbt.input_raw[0];
    const inputs = try a.alloc(zhww.btc_transaction.TxIn, 2);
    inputs[0] = psbt.unsigned_tx.inputs[0];
    inputs[1] = inputs[0];
    inputs[1].prevout.vout += 1; // different outpoint; synthetic UTXO data, not a chain proof
    psbt.unsigned_tx.inputs = inputs;
    psbt.inputs = try a.alloc(zhww.btc_psbt.Input, 2);
    @memset(psbt.inputs, original);
    var second_map: []const u8 = original_map;
    if (foreign_second) {
        var value: [31]u8 = @splat(0xff);
        std.mem.writeInt(u64, value[0..8], original.witness_utxo.?.value, .little);
        value[8] = 22;
        value[9] = 0;
        value[10] = 20;
        var map = std.ArrayList(u8).empty;
        try map.appendSlice(a, &.{ 1, 1 });
        try zhww.btc_transaction.writeVarBytes(&map, a, &value);
        second_map = map.items;
    }
    psbt.input_raw = &.{ original_map, second_map };
    const tx = try psbt.unsigned_tx.serialize(a, false);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(a, &.{ 1, 0 });
    try zhww.btc_transaction.writeVarBytes(&global, a, tx);
    psbt.global_raw = global.items;
    return zhww.btc_psbt.Psbt.serializeWith(a, psbt, &.{ &.{}, &.{} });
}

const MockEntropy = struct {
    const Mode = enum { ready, unhealthy, stalled, unavailable };
    calls: usize = 0,
    mode: Mode = .ready,
    fn read(raw: *anyopaque) error{Unavailable}!zhww.rng.Word {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.calls += 1;
        return switch (self.mode) {
            .ready => .{ .ready = @intCast(self.calls) }, // test-only, NOT secure entropy
            .unhealthy => if (self.calls == 2) .health_failure else .{ .ready = 1 },
            .stalled => .not_ready,
            .unavailable => error.Unavailable,
        };
    }
    fn rng(self: *@This()) zhww.rng.Rng {
        return .{ .source = .{ .context = self, .read_word = read } };
    }
};

fn signTest(w: *Workflow, allocator: std.mem.Allocator, raw: []const u8, now: u64) !zhww.btc_sign.SignedPsbt {
    var mock: MockEntropy = .{};
    var rng = mock.rng();
    return w.sign(allocator, raw, now, &rng);
}

fn wiped(w: *Workflow) !void {
    try testing.expect(!w.session.ready);
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &w.session.secret.memory);
    for (w.session.gate.request) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(usize, 0), w.review.count);
    try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &w.plan_digest);
}

// Re-encode only the known global unsigned transaction for mutation tests.
fn replaceTransaction(allocator: std.mem.Allocator, parsed: *zhww.btc_psbt.Psbt) ![]u8 {
    const tx_bytes = try parsed.unsigned_tx.serialize(allocator, false);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(allocator, &.{ 1, 0 });
    try zhww.btc_transaction.writeVarBytes(&global, allocator, tx_bytes);
    parsed.global_raw = try global.toOwnedSlice(allocator);
    const outputs = try allocator.alloc(zhww.btc_psbt.Output, parsed.unsigned_tx.outputs.len);
    @memset(outputs, .{});
    parsed.outputs = outputs;
    const output_raw = try allocator.alloc([]const u8, outputs.len);
    @memset(output_raw, &.{});
    parsed.output_raw = output_raw;
    const extra = try allocator.alloc([]const zhww.btc_psbt.Psbt.Field, parsed.inputs.len);
    @memset(extra, &.{});
    return zhww.btc_psbt.Psbt.serializeWith(allocator, parsed.*, extra);
}

test "approved BTC workflow produces the pinned Core final transaction and wipes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try testing.expectEqual(@as(u64, 10000), w.review.fee);
    try testing.expectEqual(@as(usize, 5), w.review.count);
    try approve(&w);
    const outcome = try signTest(&w, a, f.raw, 1102);
    try testing.expectEqualSlices(u8, f.expected_tx, outcome.result.final_tx.?);
    try wiped(&w);
    try testing.expectError(error.InvalidState, signTest(&w, a, f.raw, 1103));
}

test "approved BTC signs using only the fixed workspace and resets without accumulation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var memory: [zhww.memory_budget.workspace_bytes]u8 align(64) = undefined;
    var workspace = zhww.workspace.Workspace.init(&memory);
    defer workspace.reset();
    var expected_peak: ?usize = null;
    for (0..3) |_| {
        var w: Workflow = .{};
        const fixed = workspace.allocator();
        try w.begin(fixed, evidence(), &f.seed, f.raw, .regtest, 0);
        const prepare_peak = workspace.peak;
        try approve(&w);
        const outcome = try signTest(&w, fixed, f.raw, 1102);
        try testing.expectEqualSlices(u8, f.expected_tx, outcome.result.final_tx.?);
        try testing.expectEqual(@as(usize, 0), workspace.failures);
        if (expected_peak) |peak| try testing.expectEqual(peak, workspace.peak) else {
            expected_peak = workspace.peak;
            std.debug.print("\nApproved BTC fixed workspace (host ABI): prepare peak {d}, combined peak {d}, capacity {d} bytes\n", .{ prepare_peak, workspace.peak, memory.len });
        }
        try wiped(&w);
        // Output borrows expire here, never inspect outcome after reset.
        workspace.reset();
        for (memory) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "largest padded request fits the fixed workspace for the pinned transaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var parsed = try zhww.btc_psbt.Psbt.parse(a, f.raw);
    const padding = try a.alloc(u8, review_mod.max_request_bytes - f.raw.len - 5);
    @memset(padding, 0xab);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(a, parsed.global_raw);
    try global.appendSlice(a, &.{ 1, 0xfa }); // unknown global key, preserved verbatim
    try zhww.btc_transaction.writeVarBytes(&global, a, padding);
    parsed.global_raw = try global.toOwnedSlice(a);
    const padded = try zhww.btc_psbt.Psbt.serializeWith(a, parsed, &.{&.{}});
    try testing.expectEqual(@as(usize, review_mod.max_request_bytes), padded.len);
    var memory: [zhww.memory_budget.workspace_bytes]u8 align(64) = undefined;
    var workspace = zhww.workspace.Workspace.init(&memory);
    defer workspace.reset();
    var w: Workflow = .{};
    try w.begin(workspace.allocator(), evidence(), &f.seed, padded, .regtest, 0);
    const prepare_peak = workspace.peak;
    try approve(&w);
    const outcome = try signTest(&w, workspace.allocator(), padded, 1102);
    try testing.expectEqualSlices(u8, f.expected_tx, outcome.result.final_tx.?);
    try testing.expectEqual(@as(usize, 0), workspace.failures);
    try testing.expect(std.mem.indexOf(u8, outcome.signed_psbt, padding) != null);
    std.debug.print("Approved BTC padded 64 KiB (host ABI): prepare peak {d}, combined peak {d} bytes\n", .{ prepare_peak, workspace.peak });
    try wiped(&w);
}

test "two-input 64 KiB request signs completely inside the fixed workspace" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    const raw = try twoInputs(a, f.raw, false);
    var parsed = try zhww.btc_psbt.Psbt.parse(a, raw);
    const padding = try a.alloc(u8, review_mod.max_request_bytes - raw.len - 5);
    @memset(padding, 0xab);
    var global = std.ArrayList(u8).empty;
    try global.appendSlice(a, parsed.global_raw);
    try global.appendSlice(a, &.{ 1, 0xfa });
    try zhww.btc_transaction.writeVarBytes(&global, a, padding);
    parsed.global_raw = global.items;
    const padded = try zhww.btc_psbt.Psbt.serializeWith(a, parsed, &.{ &.{}, &.{} });
    try testing.expectEqual(@as(usize, review_mod.max_request_bytes), padded.len);
    var memory: [zhww.memory_budget.workspace_bytes]u8 align(64) = undefined;
    var workspace = zhww.workspace.Workspace.init(&memory);
    defer workspace.reset();
    var w: Workflow = .{};
    try w.begin(workspace.allocator(), evidence(), &f.seed, padded, .regtest, 0);
    try approve(&w);
    const signed = try signTest(&w, workspace.allocator(), padded, 1102);
    try testing.expectEqual(@as(usize, 2), signed.result.partial_sigs.len);
    try testing.expectEqual(@as(usize, 0), signed.result.unsigned_inputs.len);
    try testing.expectEqual(@as(usize, 0), signed.result.change_outputs.len);
    const final = try zhww.btc_transaction.Transaction.parse(a, signed.result.final_tx.?);
    try testing.expectEqual(@as(usize, 2), final.inputs.len);
    for (final.inputs) |input| try testing.expectEqual(@as(usize, 2), input.witness.len);
    try testing.expect(std.mem.indexOf(u8, signed.signed_psbt, padding) != null);
    try testing.expectEqual(@as(usize, 0), workspace.failures);
    std.debug.print("Approved two-input padded 64 KiB (host ABI): peak {d} bytes\n", .{workspace.peak});
    try wiped(&w);
}

test "foreign second input cannot publish an earlier partial signature and releases context" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    const raw = try twoInputs(a, f.raw, true);
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, raw, .regtest, 0);
    try approve(&w);
    try testing.expectError(error.NoMatchingKey, signTest(&w, a, raw, 1102));
    try wiped(&w);
    // No output is returned even if input 0 was signed internally. Lease was retired.
    var next = try zhww.secp256k1.SigningLease.begin(&@as([32]u8, @splat(0x44)));
    defer next.end();
}

test "workspace exhaustion during prepare and post-approval revalidation wipes the session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var tiny: [1]u8 = undefined;
    var workspace = zhww.workspace.Workspace.init(&tiny);
    var w: Workflow = .{};
    try testing.expectError(error.OutOfMemory, w.begin(workspace.allocator(), evidence(), &f.seed, f.raw, .regtest, 0));
    try wiped(&w);
    workspace.reset();
    var memory: [zhww.memory_budget.workspace_bytes]u8 align(64) = undefined;
    workspace = zhww.workspace.Workspace.init(&memory);
    defer workspace.reset();
    w = .{};
    try w.begin(workspace.allocator(), evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    _ = try workspace.allocator().alloc(u8, memory.len - workspace.fba.end_index);
    var mock: MockEntropy = .{};
    var rng = mock.rng();
    try testing.expectError(error.OutOfMemory, w.sign(workspace.allocator(), f.raw, 1102, &rng));
    try testing.expectEqual(@as(usize, 0), mock.calls);
    try testing.expect(workspace.failures > 0);
    try wiped(&w);
}

test "allocation failure after entropy acquisition releases the signing context and seed" {
    const ExhaustOnEntropy = struct {
        workspace: *zhww.workspace.Workspace,
        calls: usize = 0,
        fn read(raw: *anyopaque) error{Unavailable}!zhww.rng.Word {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            if (self.calls == 8) {
                const available = self.workspace.fba.buffer.len - self.workspace.fba.end_index;
                _ = self.workspace.allocator().alloc(u8, available) catch return error.Unavailable;
            }
            return .{ .ready = @intCast(self.calls) }; // test-only fault injection
        }
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var memory: [zhww.memory_budget.workspace_bytes]u8 align(64) = undefined;
    var workspace = zhww.workspace.Workspace.init(&memory);
    defer workspace.reset();
    var w: Workflow = .{};
    try w.begin(workspace.allocator(), evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    var mock: ExhaustOnEntropy = .{ .workspace = &workspace };
    var rng: zhww.rng.Rng = .{ .source = .{ .context = &mock, .read_word = ExhaustOnEntropy.read } };
    try testing.expectError(error.OutOfMemory, w.sign(workspace.allocator(), f.raw, 1102, &rng));
    try testing.expectEqual(@as(usize, 8), mock.calls);
    try wiped(&w);
    var lease = try zhww.secp256k1.SigningLease.begin(&@as([32]u8, @splat(0x77)));
    lease.end();
}

test "no signature before all pages and physical event sequence" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    for (0..3) |scenario| {
        var w: Workflow = .{};
        try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
        if (scenario == 1) try w.displayed(0, (try w.review.page(0)).bytes(), 1);
        if (scenario == 2) {
            for (0..w.review.count) |i|
                try w.displayed(i, (try w.review.page(i)).bytes(), @intCast(i + 1));
            try w.button(true, 100); // held without a release after review
            try w.button(false, 1101);
        }
        try testing.expectError(error.InvalidState, signTest(&w, a, f.raw, 1102));
        try wiped(&w);
    }
}

test "input mutation, network change, media removal and timeout prevent signing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    for (0..4) |scenario| {
        var w: Workflow = .{};
        try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
        try approve(&w);
        switch (scenario) {
            0 => {
                const changed = try a.dupe(u8, f.raw);
                changed[changed.len - 1] ^= 1;
                try testing.expectError(error.RequestMismatch, signTest(&w, a, changed, 1102));
            },
            1 => {
                w.network = .mainnet;
                try testing.expectError(error.ReviewMismatch, signTest(&w, a, f.raw, 1102));
            },
            2 => {
                w.abort();
                try testing.expectError(error.InvalidState, signTest(&w, a, f.raw, 1102));
            },
            else => try testing.expectError(error.Timeout, w.poll(120000)),
        }
        try wiped(&w);
    }
}

test "approved BTC entropy failures consume approval and wipe without output" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    for ([_]MockEntropy.Mode{ .unhealthy, .stalled, .unavailable }) |mode| {
        var w: Workflow = .{};
        try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
        try approve(&w);
        var mock: MockEntropy = .{ .mode = mode };
        var rng = mock.rng();
        switch (mode) {
            .unhealthy => try testing.expectError(error.HealthFailure, w.sign(a, f.raw, 1102, &rng)),
            .stalled => try testing.expectError(error.Timeout, w.sign(a, f.raw, 1102, &rng)),
            .unavailable => try testing.expectError(error.Unavailable, w.sign(a, f.raw, 1102, &rng)),
            else => unreachable,
        }
        try testing.expect(rng.failed);
        try wiped(&w);
        const calls = mock.calls;
        try testing.expectError(error.InvalidState, w.sign(a, f.raw, 1103, &rng));
        try testing.expectEqual(calls, mock.calls);
    }
}

test "independent plan commitment mismatch refuses signing before entropy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    w.plan_digest[0] ^= 1; // trusted-state corruption simulation, not a public setter
    var mock: MockEntropy = .{};
    var rng = mock.rng();
    try testing.expectError(error.SigningPlanMismatch, w.sign(a, f.raw, 1102, &rng));
    try testing.expectEqual(@as(usize, 0), mock.calls);
    try wiped(&w);
}

test "entropy is not requested before valid approval or after request mutation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var mock: MockEntropy = .{};
    var rng = mock.rng();
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try testing.expectError(error.InvalidState, w.sign(a, f.raw, 1102, &rng));
    try testing.expectEqual(@as(usize, 0), mock.calls);
    w = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    const changed = try a.dupe(u8, f.raw);
    changed[changed.len - 1] ^= 1;
    try testing.expectError(error.RequestMismatch, w.sign(a, changed, 1102, &rng));
    try testing.expectEqual(@as(usize, 0), mock.calls);
    try wiped(&w);
}

test "nested context acquisition refuses approved signing without closing outer lease" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    var lease = try zhww.secp256k1.SigningLease.begin(&@as([32]u8, @splat(0x77)));
    defer lease.end();
    try testing.expectError(error.ContextBusy, signTest(&w, a, f.raw, 1102));
    try wiped(&w);
    try testing.expectError(error.ContextBusy, zhww.secp256k1.SigningLease.begin(&@as([32]u8, @splat(0x88))));
}

test "review renders every complete page on both supported displays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var review: review_mod.Review = .{};
    try review.build(a, f.raw, .regtest);
    try testing.expect(std.mem.indexOf(u8, (try review.page(0)).bytes(), "regtest") != null);
    try testing.expect(std.mem.indexOf(u8, (try review.page(3)).bytes(), "bcrt1") != null);
    for ([_]usize{ 135, 240 }) |height| {
        const pixels = try a.alloc(u16, 240 * height);
        var fb = try zhww.ui_framebuffer.Framebuffer.init(pixels, 240, height);
        for (review.pages[0..review.count]) |*page| try page.render(&fb);
    }
}

test "multiple outputs are all shown and unknown output scripts are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    var parsed = try zhww.btc_psbt.Psbt.parse(a, f.raw);
    const original = parsed.unsigned_tx.outputs[0];
    const outputs = try a.alloc(zhww.btc_transaction.TxOut, 3);
    for (outputs) |*output| output.* = .{ .value = original.value / 3, .script_pubkey = original.script_pubkey };
    outputs[2].value += original.value % 3;
    parsed.unsigned_tx.outputs = outputs;
    var review: review_mod.Review = .{};
    try review.build(a, try replaceTransaction(a, &parsed), .regtest);
    try testing.expectEqual(@as(usize, 7), review.count);
    for (3..6) |i| try testing.expect(std.mem.indexOf(u8, (try review.page(i)).bytes(), "payment") != null);
    outputs[1].script_pubkey = &.{0x6a}; // refuse undisplayable OP_RETURN, don't silently skip
    try testing.expectError(error.UnsupportedOutput, review.build(a, try replaceTransaction(a, &parsed), .regtest));
    try testing.expectEqual(@as(usize, 0), review.count);
}

test "unknown input amount, unsupported sighash and input type fail before seed ownership" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    const parsed = try zhww.btc_psbt.Psbt.parse(a, f.raw);
    // A missing witness UTXO: empty input map; still syntactically valid PSBT.
    var missing = parsed;
    missing.input_raw = &.{&.{}};
    const missing_raw = try zhww.btc_psbt.Psbt.serializeWith(a, missing, &.{&.{}});
    var w: Workflow = .{};
    try testing.expectError(error.UnknownAmount, w.begin(a, evidence(), &f.seed, missing_raw, .regtest, 0));
    try wiped(&w);
    const non_all = try zhww.btc_psbt.Psbt.serializeWith(a, parsed, &.{&.{.{ .key = &.{3}, .value = &.{ 2, 0, 0, 0 } }}});
    w = .{};
    try testing.expectError(error.UnsupportedSighash, w.begin(a, evidence(), &f.seed, non_all, .regtest, 0));
    try wiped(&w);
    // P2WSH witness UTXO, unsupported by this initial approved workflow.
    var utxo: [43]u8 = @splat(0);
    std.mem.writeInt(u64, utxo[0..8], 100000000, .little);
    utxo[8] = 34;
    utxo[9] = 0;
    utxo[10] = 32;
    const wsh = try zhww.btc_psbt.Psbt.serializeWith(a, parsed, &.{&.{.{ .key = &.{1}, .value = &utxo }}});
    w = .{};
    try testing.expectError(error.UnsupportedInput, w.begin(a, evidence(), &f.seed, wsh, .regtest, 0));
    try wiped(&w);
}

test "wrong wallet cannot publish a partially signed or unsigned result" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = try fixture(a);
    defer std.crypto.secureZero(u8, &f.seed);
    f.seed[0] ^= 1;
    var w: Workflow = .{};
    try w.begin(a, evidence(), &f.seed, f.raw, .regtest, 0);
    try approve(&w);
    try testing.expectError(error.NoMatchingKey, signTest(&w, a, f.raw, 1102));
    try wiped(&w);
}
