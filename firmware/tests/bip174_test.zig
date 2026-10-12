//! BIP174 の公式テストベクタによる PSBT 解析の検証。
//!
//! ベクタ: tests/vectors/bip174.json（不正 20 件 / 妥当 27 件）
//! 出典: https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki
//!
//! - **不正な PSBT はすべて拒否されること**（受理してはならない）
//! - **妥当な PSBT はすべて受理されること**（過剰に厳しくてもならない）

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

test "BIP174: 不正な PSBT 20 件をすべて拒否する" {
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

        // 受理してしまった = テスト失敗
        std.debug.print("不正な PSBT を受理してしまった: {s}\n", .{case_name});
        return error.TestUnexpectedResult;
    }
}

test "BIP174: 妥当な PSBT 27 件をすべて受理する" {
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
            std.debug.print("妥当な PSBT を拒否してしまった: {s} ({s})\n", .{
                case_name,
                @errorName(err),
            });
            return error.TestUnexpectedResult;
        };
    }
}

test "BIP174: 解析して書き戻すと元のバイト列と一致する（未知フィールドを保持する）" {
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

        // 追加署名なしで書き戻す
        const sigs = try allocator.alloc([]const zhww.btc_psbt.PartialSig, psbt.inputs.len);
        for (sigs) |*slot| slot.* = &.{};
        const reserialized = try zhww.btc_psbt.Psbt.serialize(allocator, psbt, sigs);

        if (!std.mem.eql(u8, raw, reserialized)) {
            std.debug.print("書き戻しが一致しない: {s}\n", .{case_name});
            return error.TestUnexpectedResult;
        }
    }
}
