//! Validation of PSBT parsing against BIP174's official test vectors.
//!
//! Vectors: tests/vectors/bip174.json (20 invalid / 27 valid)
//! Source: https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki
//!
//! - **Every invalid PSBT must be rejected** (none may be accepted)
//! - **Every valid PSBT must be accepted** (we must not be overly strict either)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip174.json");

fn decodeBase64(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    const buffer = try allocator.alloc(u8, size);
    try decoder.decode(buffer, encoded);
    return buffer;
}

test "BIP174: rejects all 20 invalid PSBTs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const invalid = parsed.value.object.get("invalid").?.array.items;
    try testing.expectEqual(@as(usize, 20), invalid.len);

    for (invalid) |entry| {
        const fields = entry.object;
        const case_name = fields.get("case").?.string;
        const raw = try decodeBase64(allocator, fields.get("base64").?.string);

        const result = zhww.btc_psbt.Psbt.parse(allocator, raw);
        _ = result catch continue;

        // We accepted it = test failure
        std.debug.print("accepted an invalid PSBT: {s}\n", .{case_name});
        return error.TestUnexpectedResult;
    }
}

test "BIP174: accepts all 27 valid PSBTs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const valid = parsed.value.object.get("valid").?.array.items;
    try testing.expectEqual(@as(usize, 27), valid.len);

    for (valid) |entry| {
        const fields = entry.object;
        const case_name = fields.get("case").?.string;
        const raw = try decodeBase64(allocator, fields.get("base64").?.string);

        _ = zhww.btc_psbt.Psbt.parse(allocator, raw) catch |err| {
            std.debug.print("rejected a valid PSBT: {s} ({s})\n", .{
                case_name,
                @errorName(err),
            });
            return error.TestUnexpectedResult;
        };
    }
}

test "BIP174: parsing and writing back reproduces the original bytes (unknown fields are preserved)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const valid = parsed.value.object.get("valid").?.array.items;

    for (valid) |entry| {
        const fields = entry.object;
        const case_name = fields.get("case").?.string;
        const raw = try decodeBase64(allocator, fields.get("base64").?.string);

        const psbt = zhww.btc_psbt.Psbt.parse(allocator, raw) catch continue;

        // Write back without adding any signature
        const sigs = try allocator.alloc([]const zhww.btc_psbt.PartialSig, psbt.inputs.len);
        for (sigs) |*slot| slot.* = &.{};
        const reserialized = try zhww.btc_psbt.Psbt.serialize(allocator, psbt, sigs);

        if (!std.mem.eql(u8, raw, reserialized)) {
            std.debug.print("write-back does not match: {s}\n", .{case_name});
            return error.TestUnexpectedResult;
        }
    }
}
