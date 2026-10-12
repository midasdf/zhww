//! Bech32 / Bech32m（BIP173 / BIP350）。
//!
//! **重要な設計制約**: P2WPKH（witness v0）は Bech32、P2TR（witness v1）は Bech32m を使う。
//! チェックサム方式の取り違えは資金喪失に直結するため、定数を型で分離し、
//! テストで「v0 を Bech32m として受理しない」ことを検証する。
//!
//! 参考: https://github.com/bitcoin/bips/blob/master/bip-0173.mediawiki
//!       https://github.com/bitcoin/bips/blob/master/bip-0350.mediawiki
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../errors.zig").Error;

const charset = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

const bech32_const: u32 = 1;
const bech32m_const: u32 = 0x2BC830A3;

pub const Spec = enum { bech32, bech32m };

/// Bech32 文字列の最大長（BIP173）。
pub const max_length = 90;
/// HRP の最大長。
pub const max_hrp_len = 83;

fn polymod(values: []const u8) u32 {
    const generator = [5]u32{ 0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3 };
    var chk: u32 = 1;
    for (values) |value| {
        const top = chk >> 25;
        chk = ((chk & 0x1FFFFFF) << 5) ^ value;
        for (0..5) |i| {
            if (((top >> @intCast(i)) & 1) != 0) chk ^= generator[i];
        }
    }
    return chk;
}

fn hrpExpand(hrp: []const u8) [2 * max_hrp_len + 1]u8 {
    var out: [2 * max_hrp_len + 1]u8 = undefined;
    for (hrp, 0..) |c, i| out[i] = c >> 5;
    out[hrp.len] = 0;
    for (hrp, 0..) |c, i| out[hrp.len + 1 + i] = c & 31;
    return out;
}

fn createChecksum(hrp: []const u8, data: []const u8, spec: Spec) [6]u8 {
    const const_value: u32 = if (spec == .bech32m) bech32m_const else bech32_const;
    var values: [2 * max_hrp_len + 1 + max_length + 6]u8 = undefined;
    var len: usize = 0;

    const expanded = hrpExpand(hrp);
    const expanded_len = 2 * hrp.len + 1;
    @memcpy(values[0..expanded_len], expanded[0..expanded_len]);
    len += expanded_len;
    @memcpy(values[len..][0..data.len], data);
    len += data.len;
    for (0..6) |_| {
        values[len] = 0;
        len += 1;
    }

    const polymod_value = polymod(values[0..len]) ^ const_value;
    var out: [6]u8 = undefined;
    for (0..6) |i| {
        out[i] = @intCast((polymod_value >> @intCast(5 * (5 - i))) & 31);
    }
    return out;
}

fn verifyChecksum(hrp: []const u8, data: []const u8, spec: Spec) bool {
    const const_value: u32 = if (spec == .bech32m) bech32m_const else bech32_const;
    var values: [2 * max_hrp_len + 1 + max_length]u8 = undefined;
    if (2 * hrp.len + 1 + data.len > values.len) return false;
    const expanded = hrpExpand(hrp);
    const expanded_len = 2 * hrp.len + 1;
    @memcpy(values[0..expanded_len], expanded[0..expanded_len]);
    @memcpy(values[expanded_len..][0..data.len], data);
    return polymod(values[0 .. expanded_len + data.len]) == const_value;
}

/// hrp と 5bit データ列から Bech32 / Bech32m 文字列を作る。
pub fn encode(out: []u8, hrp: []const u8, data: []const u8, spec: Spec) Error![]u8 {
    if (hrp.len == 0 or hrp.len > max_hrp_len) return error.InvalidEncoding;
    const checksum = createChecksum(hrp, data, spec);
    if (out.len < hrp.len + 1 + data.len + 6) return error.BufferTooSmall;

    var pos: usize = 0;
    @memcpy(out[pos..][0..hrp.len], hrp);
    pos += hrp.len;
    out[pos] = '1';
    pos += 1;
    for (data) |d| {
        out[pos] = charset[d];
        pos += 1;
    }
    for (checksum) |d| {
        out[pos] = charset[d];
        pos += 1;
    }
    return out[0..pos];
}

pub const Decoded = struct {
    hrp: []const u8,
    data: []const u8,
    spec: Spec,
};

/// Bech32 / Bech32m 文字列を検証して分解する。`expect` を指定すると方式も検査する。
pub fn decode(
    hrp_buf: []u8,
    data_buf: []u8,
    text: []const u8,
    expect: ?Spec,
) Error!Decoded {
    if (text.len == 0 or text.len > max_length) return error.InvalidEncoding;

    var has_lower = false;
    var has_upper = false;
    for (text) |c| {
        if (c < 33 or c > 126) return error.InvalidEncoding;
        if (c >= 'a' and c <= 'z') has_lower = true;
        if (c >= 'A' and c <= 'Z') has_upper = true;
    }
    if (has_lower and has_upper) return error.InvalidEncoding;

    var lower: [max_length]u8 = undefined;
    for (text, 0..) |c, i| lower[i] = std.ascii.toLower(c);
    const lowered = lower[0..text.len];

    const sep = std.mem.lastIndexOfScalar(u8, lowered, '1') orelse return error.InvalidEncoding;
    if (sep == 0 or sep + 7 > lowered.len) return error.InvalidEncoding;

    const hrp = lowered[0..sep];
    const data_part = lowered[sep + 1 ..];
    if (hrp.len > max_hrp_len) return error.InvalidEncoding;
    if (hrp_buf.len < hrp.len or data_buf.len < data_part.len) return error.BufferTooSmall;

    @memcpy(hrp_buf[0..hrp.len], hrp);

    var data: [max_length]u8 = undefined;
    for (data_part, 0..) |c, i| {
        const value = std.mem.indexOfScalar(u8, charset, c) orelse return error.InvalidEncoding;
        data[i] = @intCast(value);
    }
    const data_values = data[0..data_part.len];

    for ([_]Spec{ .bech32, .bech32m }) |candidate| {
        if (verifyChecksum(hrp, data_values, candidate)) {
            if (expect) |wanted| {
                if (wanted != candidate) return error.InvalidEncoding;
            }
            @memcpy(data_buf[0 .. data_part.len - 6], data_values[0 .. data_part.len - 6]);
            return .{
                .hrp = hrp_buf[0..hrp.len],
                .data = data_buf[0 .. data_part.len - 6],
                .spec = candidate,
            };
        }
    }
    return error.ChecksumMismatch;
}

/// ビット幅を変換する。`pad = false` のとき端数のビットが不正なら error を返す。
pub fn convertBits(
    out: []u8,
    data: []const u8,
    from_bits: u4,
    to_bits: u4,
    pad: bool,
) Error![]u8 {
    var acc: u32 = 0;
    var bits: u4 = 0;
    const maxv: u32 = (@as(u32, 1) << to_bits) - 1;
    const max_acc: u32 = (@as(u32, 1) << (from_bits + to_bits - 1)) - 1;
    var pos: usize = 0;

    for (data) |value| {
        if ((@as(u16, value) >> from_bits) != 0) return error.InvalidEncoding;
        acc = ((acc << from_bits) | value) & max_acc;
        bits += from_bits;
        while (bits >= to_bits) {
            bits -= to_bits;
            if (pos >= out.len) return error.BufferTooSmall;
            out[pos] = @intCast((acc >> bits) & maxv);
            pos += 1;
        }
    }
    if (pad) {
        if (bits != 0) {
            if (pos >= out.len) return error.BufferTooSmall;
            out[pos] = @intCast((acc << (to_bits - bits)) & maxv);
            pos += 1;
        }
    } else if (bits >= from_bits or ((acc << (to_bits - bits)) & maxv) != 0) {
        return error.InvalidEncoding;
    }
    return out[0..pos];
}

/// SegWit アドレス（witness program）を生成する。v0 は Bech32、v1 以降は Bech32m。
pub fn encodeSegwit(out: []u8, hrp: []const u8, witness_version: u8, program: []const u8) Error![]u8 {
    if (witness_version > 16) return error.InvalidEncoding;
    if (program.len < 2 or program.len > 40) return error.InvalidEncoding;
    if (witness_version == 0 and program.len != 20 and program.len != 32) {
        return error.InvalidEncoding;
    }
    var data: [1 + 65]u8 = undefined;
    data[0] = witness_version;
    const converted = try convertBits(data[1..], program, 8, 5, true);
    const spec: Spec = if (witness_version == 0) .bech32 else .bech32m;
    return encode(out, hrp, data[0 .. 1 + converted.len], spec);
}

pub const SegwitDecoded = struct {
    witness_version: u8,
    program: []const u8,
};

/// SegWit アドレスを検証して分解する。v0 に Bech32m、v1 以降に Bech32 を使っていたら error。
pub fn decodeSegwit(
    hrp: []const u8,
    program_buf: []u8,
    address: []const u8,
) Error!SegwitDecoded {
    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    const decoded = try decode(&hrp_buf, &data_buf, address, null);

    if (!std.mem.eql(u8, decoded.hrp, hrp)) return error.InvalidEncoding;
    if (decoded.data.len < 1) return error.InvalidEncoding;

    const witness_version = decoded.data[0];
    const program = try convertBits(program_buf, decoded.data[1..], 5, 8, false);
    if (program.len < 2 or program.len > 40) return error.InvalidEncoding;
    if (witness_version > 16) return error.InvalidEncoding;
    if (witness_version == 0 and program.len != 20 and program.len != 32) {
        return error.InvalidEncoding;
    }
    const expected: Spec = if (witness_version == 0) .bech32 else .bech32m;
    if (decoded.spec != expected) return error.InvalidEncoding;
    return .{ .witness_version = witness_version, .program = program };
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

const p2wpkh_address = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
const p2tr_address = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr";

test "BIP173 の妥当なテストベクタ" {
    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    for ([_][]const u8{
        "A12UEL5L",
        "a12uel5l",
        "abcdef1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw",
    }) |address| {
        const decoded = try decode(&hrp_buf, &data_buf, address, null);
        try testing.expectEqual(Spec.bech32, decoded.spec);
    }
}

test "BIP173 の不正なテストベクタ" {
    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    for ([_][]const u8{ "", "pzry9x0s0muk", "1pzry9x0s0muk", "A1G7SGD8", "li1dgmt3" }) |address| {
        // エラーの種類は問わない（書式違反かチェックサム不一致のいずれか）。
        // 重要なのは「受理しないこと」。
        const result = decode(&hrp_buf, &data_buf, address, null);
        _ = result catch continue;
        return error.TestUnexpectedResult;
    }
}

test "大文字小文字の混在を拒否する" {
    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    try testing.expectError(
        error.InvalidEncoding,
        decode(&hrp_buf, &data_buf, "A12uEL5L", null),
    );
}

test "P2WPKH は Bech32（v0）" {
    var program: [40]u8 = undefined;
    const decoded = try decodeSegwit("bc", &program, p2wpkh_address);
    try testing.expectEqual(@as(u8, 0), decoded.witness_version);
    try testing.expectEqual(@as(usize, 20), decoded.program.len);

    var out: [max_length]u8 = undefined;
    try testing.expectEqualStrings(p2wpkh_address, try encodeSegwit(&out, "bc", 0, decoded.program));

    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    const raw = try decode(&hrp_buf, &data_buf, p2wpkh_address, null);
    try testing.expectEqual(Spec.bech32, raw.spec);
}

test "P2TR は Bech32m（v1）" {
    var program: [40]u8 = undefined;
    const decoded = try decodeSegwit("bc", &program, p2tr_address);
    try testing.expectEqual(@as(u8, 1), decoded.witness_version);
    try testing.expectEqual(@as(usize, 32), decoded.program.len);

    var out: [max_length]u8 = undefined;
    try testing.expectEqualStrings(p2tr_address, try encodeSegwit(&out, "bc", 1, decoded.program));

    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    const raw = try decode(&hrp_buf, &data_buf, p2tr_address, null);
    try testing.expectEqual(Spec.bech32m, raw.spec);
}

test "v0 アドレスを Bech32m として受理しない" {
    var hrp_buf: [max_hrp_len]u8 = undefined;
    var data_buf: [max_length]u8 = undefined;
    try testing.expectError(
        error.InvalidEncoding,
        decode(&hrp_buf, &data_buf, p2wpkh_address, .bech32m),
    );
    try testing.expectError(
        error.InvalidEncoding,
        decode(&hrp_buf, &data_buf, p2tr_address, .bech32),
    );
}

test "異なる hrp を拒否する" {
    var program: [40]u8 = undefined;
    try testing.expectError(
        error.InvalidEncoding,
        decodeSegwit("tb", &program, p2wpkh_address),
    );
}

test "witness version と program 長の検証" {
    var out: [max_length]u8 = undefined;
    const program_20: [20]u8 = @splat(0);
    const program_21: [21]u8 = @splat(0);
    try testing.expectError(error.InvalidEncoding, encodeSegwit(&out, "bc", 17, &program_20));
    try testing.expectError(error.InvalidEncoding, encodeSegwit(&out, "bc", 0, &program_21));
}
