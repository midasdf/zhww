//! アドレス生成の公式テストベクタ（BIP49 / BIP84 / BIP86）。
//!
//! ベクタ: tests/vectors/bip49.json, bip84.json, bip86.json
//! 出典: https://github.com/bitcoin/bips （bip-0049 / bip-0084 / bip-0086 .mediawiki）

const std = @import("std");
const zhww = @import("../src/root.zig");
const testing = std.testing;

const bip49_vectors = @embedFile("vectors/bip49.json");
const bip84_vectors = @embedFile("vectors/bip84.json");
const bip86_vectors = @embedFile("vectors/bip86.json");

fn hexTo(out: []u8, hex: []const u8) ![]u8 {
    return std.fmt.hexToBytes(out, hex);
}

test "BIP84: P2WPKH（mainnet / zprv・zpub・WIF・アドレス）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bip84_vectors, .{});
    const root = parsed.value.object;
    const mnemonic = root.get("mnemonic").?.string;

    var seed: [64]u8 = undefined;
    try zhww.bip39.mnemonicToSeed(&seed, mnemonic, "");

    // ルート鍵（xprv → zprv にバージョン差し替え、zpub は neuter で得る）
    const master = try zhww.bip32.ExtendedKey.fromSeed(&seed, .xprv);
    const root_zprv = try master.withVersion(.zprv);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(root.get("root_zprv").?.string, try root_zprv.serialize(&buf));
    try testing.expectEqualStrings(
        root.get("root_zpub").?.string,
        try (try root_zprv.neuter()).serialize(&buf),
    );

    // アカウント鍵
    const account_info = root.get("account").?.object;
    const account = try root_zprv.derivePath(account_info.get("path").?.string);
    try testing.expectEqualStrings(account_info.get("zprv").?.string, try account.serialize(&buf));
    try testing.expectEqualStrings(
        account_info.get("zpub").?.string,
        try (try account.neuter()).serialize(&buf),
    );

    // アドレス（WIF・公開鍵・アドレス）
    for (root.get("addresses").?.array.items) |entry| {
        const fields = entry.object;
        const node = try root_zprv.derivePath(fields.get("path").?.string);

        const priv = node.key.priv;
        var wif_buf: [64]u8 = undefined;
        try testing.expectEqualStrings(
            fields.get("wif").?.string,
            try zhww.btc_address.wif(&wif_buf, priv, .mainnet, true),
        );

        const pub_key = try node.publicKey();
        var pub_hex: [66]u8 = undefined;
        const encoded = std.fmt.bytesToHex(pub_key, .lower);
        @memcpy(pub_hex[0..encoded.len], &encoded);
        try testing.expectEqualStrings(fields.get("pubkey").?.string, &pub_hex);

        var addr_buf: [90]u8 = undefined;
        try testing.expectEqualStrings(
            fields.get("address").?.string,
            try zhww.btc_address.p2wpkh(&addr_buf, pub_key, .mainnet),
        );
    }
}

test "BIP49: P2SH-P2WPKH（testnet / uprv・upub・アドレス）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bip49_vectors, .{});
    const root = parsed.value.object;
    const mnemonic = root.get("mnemonic").?.string;

    var seed: [64]u8 = undefined;
    try zhww.bip39.mnemonicToSeed(&seed, mnemonic, "");

    const master = try zhww.bip32.ExtendedKey.fromSeed(&seed, .tprv);
    const root_uprv = try master.withVersion(.uprv);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(root.get("root_uprv").?.string, try root_uprv.serialize(&buf));

    const account_info = root.get("account").?.object;
    const account = try root_uprv.derivePath(account_info.get("path").?.string);
    try testing.expectEqualStrings(account_info.get("uprv").?.string, try account.serialize(&buf));
    try testing.expectEqualStrings(
        account_info.get("upub").?.string,
        try (try account.neuter()).serialize(&buf),
    );

    for (root.get("addresses").?.array.items) |entry| {
        const fields = entry.object;
        const node = try root_uprv.derivePath(fields.get("path").?.string);
        const priv = node.key.priv;

        var priv_hex: [64]u8 = undefined;
        const encoded = std.fmt.bytesToHex(priv, .lower);
        @memcpy(priv_hex[0..encoded.len], &encoded);
        try testing.expectEqualStrings(fields.get("privkey_hex").?.string, &priv_hex);

        var wif_buf: [64]u8 = undefined;
        try testing.expectEqualStrings(
            fields.get("wif").?.string,
            try zhww.btc_address.wif(&wif_buf, priv, .testnet, true),
        );

        var addr_buf: [90]u8 = undefined;
        try testing.expectEqualStrings(
            fields.get("address").?.string,
            try zhww.btc_address.p2shP2wpkh(&addr_buf, try node.publicKey(), .testnet),
        );
    }
}

test "BIP86: P2TR（mainnet / 内部鍵・出力鍵・アドレス）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bip86_vectors, .{});
    const root = parsed.value.object;
    const entry = root.get("address").?.object;

    var seed: [64]u8 = undefined;
    try zhww.bip39.mnemonicToSeed(&seed, root.get("mnemonic").?.string, "");

    const master = try zhww.bip32.ExtendedKey.fromSeed(&seed, .xprv);
    const node = try master.derivePath(entry.get("path").?.string);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(entry.get("xprv").?.string, try node.serialize(&buf));
    try testing.expectEqualStrings(
        entry.get("xpub").?.string,
        try (try node.neuter()).serialize(&buf),
    );

    const pub_key = try node.publicKey();
    const internal = try zhww.secp256k1.xonly(pub_key);

    var internal_hex: [64]u8 = undefined;
    const encoded = std.fmt.bytesToHex(internal, .lower);
    @memcpy(internal_hex[0..encoded.len], &encoded);
    try testing.expectEqualStrings(entry.get("internal_key").?.string, &internal_hex);

    const output_key = try zhww.secp256k1.taprootOutputKey(internal);
    var output_hex: [64]u8 = undefined;
    const output_encoded = std.fmt.bytesToHex(output_key, .lower);
    @memcpy(output_hex[0..output_encoded.len], &output_encoded);
    try testing.expectEqualStrings(entry.get("output_key").?.string, &output_hex);

    var addr_buf: [90]u8 = undefined;
    try testing.expectEqualStrings(
        entry.get("address").?.string,
        try zhww.btc_address.p2tr(&addr_buf, internal, .mainnet),
    );
}

test "アドレスのラウンドトリップ（Bech32 / Bech32m の取り違え検出）" {
    const p2wpkh = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
    const p2tr = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr";

    var program: [40]u8 = undefined;
    const v0 = try zhww.bech32.decodeSegwit("bc", &program, p2wpkh);
    try testing.expectEqual(@as(u8, 0), v0.witness_version);
    const v1 = try zhww.bech32.decodeSegwit("bc", &program, p2tr);
    try testing.expectEqual(@as(u8, 1), v1.witness_version);

    // v0 アドレスを Bech32m として受理しない
    var hrp_buf: [83]u8 = undefined;
    var data_buf: [90]u8 = undefined;
    try testing.expectError(
        error.InvalidEncoding,
        zhww.bech32.decode(&hrp_buf, &data_buf, p2wpkh, .bech32m),
    );
    try testing.expectError(
        error.InvalidEncoding,
        zhww.bech32.decode(&hrp_buf, &data_buf, p2tr, .bech32),
    );
}
