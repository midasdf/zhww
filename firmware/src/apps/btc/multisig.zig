//! P2WSH マルチシグ（BIP67 の sortedmulti）の構築と署名。
//!
//! 参考: BIP67（鍵の辞書順ソート）, BIP141（P2WSH）, BIP143（署名対象ハッシュ）
//!
//! **設計方針**
//! - マルチシグは「1 台が壊れても・盗まれても資産を失わない」ための構成であり、
//!   本プロジェクトの推奨運用（[docs/05-threat-model.md]）の中核である
//! - witnessScript は `OP_m <pubkey>… OP_n OP_CHECKMULTISIG`。署名は
//!   **スクリプトに現れる公開鍵の順**に並べなければならない（OP_CHECKMULTISIG の仕様）
//! - 署名したら必ず `secp256k1.verify` で検証してから返す

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const transaction = @import("transaction.zig");
const sighash = @import("sighash.zig");

pub const SIGHASH_ALL: u32 = 0x01;

/// 署名に使える鍵。
pub const Signer = struct {
    private_key: [32]u8,
    public_key: [33]u8,
};

/// 公開鍵を BIP67（辞書順）に並べ替える。
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

/// `OP_m <pubkey>… OP_n OP_CHECKMULTISIG` を組み立てる。
///
/// `pubkeys` は BIP67 でソート済みであること（`sortPubKeys` を使う）。
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

/// witnessScript から P2WSH の scriptPubKey（`0020{sha256}`）を作る。
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

    /// **注意**: `self` は値渡しにしてはならない。
    /// 値渡しの構造体の内部を指すスライスを返すと、戻り値が呼び出し元で
    /// 不正な参照になる（実際にこのバグをテストが検出した）。
    pub fn slice(self: *const ParsedScript) []const [33]u8 {
        return self.pubkeys[0..self.count];
    }
};

/// witnessScript を解析する（`OP_m <pubkey>… OP_n OP_CHECKMULTISIG` のみ対応）。
pub fn parseWitnessScript(script: []const u8) Error!ParsedScript {
    if (script.len < 3) return error.InvalidEncoding;
    if (script[script.len - 1] != 0xae) return error.InvalidEncoding; // OP_CHECKMULTISIG

    const required_op = script[0];
    if (required_op < 0x51 or required_op > 0x60) return error.InvalidEncoding;
    const required: usize = required_op - 0x50;

    var result: ParsedScript = .{ .required = required, .pubkeys = undefined, .count = 0 };
    var pos: usize = 1;
    // 末尾の 2 バイト（OP_n と OP_CHECKMULTISIG）は公開鍵ではない
    while (script.len - pos > 2) {
        const push = script[pos];
        if (push != 33) return error.InvalidEncoding;
        if (pos + 34 > script.len - 1) return error.InvalidEncoding;
        if (result.count >= 15) return error.InvalidEncoding;
        @memcpy(&result.pubkeys[result.count], script[pos + 1 .. pos + 34]);
        result.count += 1;
        pos += 34;
    }

    // 最後の 1 バイト（OP_n）を確認する
    const total_op = script[script.len - 2];
    if (total_op < 0x51 or total_op > 0x60) return error.InvalidEncoding;
    if (total_op - 0x50 != result.count) return error.InvalidEncoding;
    if (required > result.count) return error.InvalidEncoding;
    return result;
}

/// P2WSH 入力の署名対象ハッシュ（BIP143。scriptCode は witnessScript そのもの）。
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

/// P2WSH 入力に署名し、**witnessScript に現れる順**の署名（DER + sighash タイプ）を返す。
///
/// `signers` に含まれる鍵のうち、witnessScript に現れる公開鍵に対応するものだけを使う。
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

    // OP_CHECKMULTISIG は公開鍵と同じ順に署名を要求する
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
    }

    if (signatures.items.len < parsed.required) return error.NoMatchingKey;
    return signatures.toOwnedSlice(allocator);
}

/// 署名から witness スタックを組み立てる。
///
/// `[空要素, 署名…, witnessScript]`（先頭の空要素は OP_CHECKMULTISIG の仕様）。
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

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn hexToFixed(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "2-of-3 の witnessScript が Bitcoin Core の createmultisig と一致する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // regtest で Bitcoin Core の createmultisig が出した値（実際に実行して取得）。
    //
    // **注意**: Core の createmultisig は `multi()`（与えた順序を保持）を使う。
    // BIP67 の `sortedmulti()`（鍵を辞書順に並べる）とは別物であり、
    // 同じ鍵でも順序が違えばアドレスも変わる。ここでは Core が出した順序のまま
    // 突き合わせ、ソートそのものは別のテストで検証する。
    const k1 = hexToFixed(33, "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0");
    const k2 = hexToFixed(33, "033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f");
    const k3 = hexToFixed(33, "03bca5f67b028685140f87c46956647cd1d6042d83f8a0d5621c9c84d6148fe8d0");

    const script = try witnessScript(allocator, 2, &[_][33]u8{ k1, k2, k3 });

    const expected_hex = "522103dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e021033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f2103bca5f67b028685140f87c46956647cd1d6042d83f8a0d5621c9c84d6148fe8d053ae";
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try testing.expectEqualSlices(u8, &expected, script);

    // scriptPubKey も Core の witness_utxo と一致する
    const spk = scriptPubKey(script);
    var expected_spk: [34]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &expected_spk,
        "0020238359dc6fe67694593c6335d53470ec4312ce48bfb4c022a8de82c08ec1554f",
    );
    try testing.expectEqualSlices(u8, &expected_spk, &spk);

    // BIP67 でソートすると（順序が変わるので）別のスクリプトになることも確認する
    const sorted = try sortPubKeys(allocator, &[_][33]u8{ k1, k2, k3 });
    const sorted_script = try witnessScript(allocator, 2, sorted);
    try testing.expect(!std.mem.eql(u8, script, sorted_script));
    try testing.expect(std.mem.lessThan(u8, &sorted[0], &sorted[1]));
}

test "witnessScript の解析（往復）" {
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

    // 壊れたスクリプトを拒否する
    try testing.expectError(error.InvalidEncoding, parseWitnessScript(&[_]u8{ 0x52, 0x21 }));
    var broken = try allocator.dupe(u8, script);
    broken[broken.len - 1] = 0xad; // OP_CHECKMULTISIG でない
    try testing.expectError(error.InvalidEncoding, parseWitnessScript(broken));
}

test "BIP67 のソートは辞書順" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const a = hexToFixed(33, "03dc1953c2756c7c58d4f48ca1bbba767f414fd236bf4d662b67721ac626c514e0");
    const b = hexToFixed(33, "033416774e7264295034cd3db47e74113f74903a0d795ab54515cf1c454d4bf74f");
    const sorted = try sortPubKeys(allocator, &[_][33]u8{ a, b });
    try testing.expect(std.mem.lessThan(u8, &sorted[0], &sorted[1]));
}

test "buildWitness の形（先頭が空要素）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const signature = [_]u8{ 0xDE, 0xAD };
    const script = [_]u8{ 0x52 };
    const witness = try buildWitness(allocator, &[_][]const u8{&signature}, &script);
    try testing.expectEqual(@as(usize, 3), witness.len);
    try testing.expectEqual(@as(usize, 0), witness[0].len);
    try testing.expectEqualSlices(u8, &signature, witness[1]);
    try testing.expectEqualSlices(u8, &script, witness[2]);
}
