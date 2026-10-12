//! BIP32 公式テストベクタ（テストベクタ 1 の派生チェーン）。
//!
//! ベクタ: tests/vectors/bip32.json
//! 出典: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const vectors = @embedFile("vectors/bip32.json");

test "BIP32 テストベクタ 1 の派生チェーン" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    const root = parsed.value.object;

    var seed_buf: [64]u8 = undefined;
    const seed = try std.fmt.hexToBytes(&seed_buf, root.get("seed").?.string);

    const chains = root.get("chains").?.array.items;
    try testing.expect(chains.len >= 6);

    const master = try zhww.bip32.ExtendedKey.fromSeed(seed, .xprv);

    for (chains) |entry| {
        const fields = entry.object;
        const path = fields.get("path").?.string;
        const expected_xprv = fields.get("xprv").?.string;
        const expected_xpub = fields.get("xpub").?.string;

        const node = try master.derivePath(path);
        var buf: [128]u8 = undefined;
        try testing.expectEqualStrings(expected_xprv, try node.serialize(&buf));

        const public_node = try node.neuter();
        try testing.expectEqualStrings(expected_xpub, try public_node.serialize(&buf));
    }
}

test "公開鍵のみの派生が秘密鍵の派生と一致する（non-hardened 部分）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vectors, .{});
    var seed_buf: [64]u8 = undefined;
    const seed = try std.fmt.hexToBytes(&seed_buf, parsed.value.object.get("seed").?.string);

    const master = try zhww.bip32.ExtendedKey.fromSeed(seed, .xprv);
    const account = try master.derivePath("m/0'");
    const account_pub = try account.neuter();

    // m/0'/1 を秘密鍵側と公開鍵側の両方から導出して一致することを確認する
    // （非マスター鍵には相対パスを使う）
    const from_private = try account.derivePath("1");
    const from_public = try account_pub.derivePath("1");

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    try testing.expectEqualStrings(
        try (try from_private.neuter()).serialize(&buf_a),
        try from_public.serialize(&buf_b),
    );

    // 公開鍵のみのノードからは hardened 派生ができない
    try testing.expectError(error.InvalidPath, account_pub.derivePath("0'"));
    // 秘密鍵側では可能（公開鍵には hardened の情報が無いことの確認）
    _ = try account.derivePath("0'");
}
