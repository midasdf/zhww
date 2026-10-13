//! Approved workflow checks against the pinned Bitcoin Core vector, with synthetic
//! trusted display/GPIO events. This does not test a real LCD, GPIO or TrustZone.
// SPDX-License-Identifier: GPL-3.0-or-later
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

fn wiped(w: *Workflow) !void {
    try testing.expect(!w.session.ready);
    try testing.expectEqualSlices(u8, &@as([64]u8, @splat(0)), &w.session.secret.memory);
    for (w.session.gate.request) |b| try testing.expectEqual(@as(u8, 0), b);
    try testing.expectEqual(@as(usize, 0), w.review.count);
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
    const outcome = try w.sign(a, f.raw, 1102);
    try testing.expectEqualSlices(u8, f.expected_tx, outcome.result.final_tx.?);
    try wiped(&w);
    try testing.expectError(error.InvalidState, w.sign(a, f.raw, 1103));
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
        try testing.expectError(error.InvalidState, w.sign(a, f.raw, 1102));
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
                try testing.expectError(error.RequestMismatch, w.sign(a, changed, 1102));
            },
            1 => {
                w.network = .mainnet;
                try testing.expectError(error.ReviewMismatch, w.sign(a, f.raw, 1102));
            },
            2 => {
                w.abort();
                try testing.expectError(error.InvalidState, w.sign(a, f.raw, 1102));
            },
            else => try testing.expectError(error.Timeout, w.poll(120000)),
        }
        try wiped(&w);
    }
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
    try testing.expectError(error.NoMatchingKey, w.sign(a, f.raw, 1102));
    try wiped(&w);
}
