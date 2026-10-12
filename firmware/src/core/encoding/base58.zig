//! Base58 / Base58Check（Bitcoin のアドレスと拡張鍵の直列化）。
//!
//! 動的メモリを使わない。出力は呼び出し側が用意したバッファに書き込む。
//!
//! 参考: https://en.bitcoin.it/wiki/Base58Check_encoding

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("../crypto/hashes.zig");

pub const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

/// Base58 エンコードで必要になる最大長（入力長 n に対し ceil(n * 138 / 100) + 1）。
pub fn encodedLenMax(input_len: usize) usize {
    return input_len * 138 / 100 + 1;
}

/// Base58Check デコードで扱える最大ペイロード長。
pub const max_payload_len = 128;

const DigitBuf = [max_payload_len * 138 / 100 + 2]u8;

fn indexOf(ch: u8) ?u8 {
    for (alphabet, 0..) |c, i| {
        if (c == ch) return @intCast(i);
    }
    return null;
}

/// `data` を Base58 文字列にして `out` へ書き、書き込んだスライスを返す。
pub fn encode(out: []u8, data: []const u8) Error![]u8 {
    if (data.len > max_payload_len) return error.BufferTooSmall;
    if (out.len < encodedLenMax(data.len)) return error.BufferTooSmall;

    var digits: DigitBuf = undefined;
    var digits_len: usize = 0;

    // 先頭の 0x00 は '1' として保存されるので、ここでは数値変換から除外する
    var zeros: usize = 0;
    while (zeros < data.len and data[zeros] == 0) : (zeros += 1) {}

    for (data[zeros..]) |byte| {
        var carry: u32 = byte;
        var i: usize = 0;
        while (i < digits_len) : (i += 1) {
            carry += @as(u32, digits[i]) << 8;
            digits[i] = @intCast(carry % 58);
            carry /= 58;
        }
        while (carry > 0) {
            digits[digits_len] = @intCast(carry % 58);
            digits_len += 1;
            carry /= 58;
        }
    }

    var pos: usize = 0;
    for (0..zeros) |_| {
        out[pos] = '1';
        pos += 1;
    }
    var i: usize = digits_len;
    while (i > 0) {
        i -= 1;
        out[pos] = alphabet[digits[i]];
        pos += 1;
    }
    return out[0..pos];
}

/// Base58 文字列をバイト列に戻し、書き込んだスライスを返す。
pub fn decode(out: []u8, text: []const u8) Error![]u8 {
    var bin: [max_payload_len + 1]u8 = undefined;
    var bin_len: usize = 0;

    var zeros: usize = 0;
    while (zeros < text.len and text[zeros] == '1') : (zeros += 1) {}

    for (text[zeros..]) |ch| {
        const value = indexOf(ch) orelse return error.InvalidEncoding;
        var carry: u32 = value;
        var i: usize = 0;
        while (i < bin_len) : (i += 1) {
            carry += @as(u32, bin[i]) * 58;
            bin[i] = @intCast(carry & 0xFF);
            carry >>= 8;
        }
        while (carry > 0) {
            if (bin_len >= bin.len) return error.InvalidEncoding;
            bin[bin_len] = @intCast(carry & 0xFF);
            bin_len += 1;
            carry >>= 8;
        }
    }

    var pos: usize = 0;
    if (out.len < zeros + bin_len) return error.BufferTooSmall;
    for (0..zeros) |_| {
        out[pos] = 0;
        pos += 1;
    }
    var i: usize = bin_len;
    while (i > 0) {
        i -= 1;
        out[pos] = bin[i];
        pos += 1;
    }
    return out[0..pos];
}

/// 4 バイトのチェックサムを付けて Base58Check エンコードする。
pub fn checkEncode(out: []u8, payload: []const u8) Error![]u8 {
    if (payload.len + 4 > max_payload_len) return error.BufferTooSmall;
    var buf: [max_payload_len]u8 = undefined;
    @memcpy(buf[0..payload.len], payload);
    var checksum: [32]u8 = undefined;
    hashes.sha256d(&checksum, payload);
    @memcpy(buf[payload.len..][0..4], checksum[0..4]);
    return encode(out, buf[0 .. payload.len + 4]);
}

/// Base58Check を検証してペイロード（チェックサムを除いた部分）を返す。
pub fn checkDecode(out: []u8, text: []const u8) Error![]u8 {
    var raw: [max_payload_len + 1]u8 = undefined;
    const decoded = try decode(&raw, text);
    if (decoded.len < 5) return error.InvalidEncoding;
    const payload = decoded[0 .. decoded.len - 4];
    const checksum = decoded[decoded.len - 4 ..];
    var expected: [32]u8 = undefined;
    hashes.sha256d(&expected, payload);
    if (!std.mem.eql(u8, expected[0..4], checksum)) return error.ChecksumMismatch;
    if (out.len < payload.len) return error.BufferTooSmall;
    @memcpy(out[0..payload.len], payload);
    return out[0..payload.len];
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "先頭の 0x00 が '1' として保存される" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("11111", try encode(&buf, &[_]u8{ 0, 0, 0, 0, 0 }));
    try testing.expectEqualStrings("112", try encode(&buf, &[_]u8{ 0, 0, 1 }));

    var out: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0, 0 }, try decode(&out, "11111"));
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 1 }, try decode(&out, "112"));
}

test "ラウンドトリップ（既知の Bitcoin アドレス）" {
    const addr = "2Mww8dCYPUpKHofjgcXcBCEGmniw9CoaiD2";
    var payload: [64]u8 = undefined;
    const decoded = try checkDecode(&payload, addr);
    // testnet P2SH のプレフィクスは 0xc4
    try testing.expectEqual(@as(u8, 0xC4), decoded[0]);
    try testing.expectEqual(@as(usize, 21), decoded.len);

    var reencoded: [128]u8 = undefined;
    try testing.expectEqualStrings(addr, try checkEncode(&reencoded, decoded));
}

test "不正な文字を拒否する" {
    var out: [64]u8 = undefined;
    for ([_][]const u8{ "0", "O", "I", "l", "abc def" }) |bad| {
        try testing.expectError(error.InvalidEncoding, decode(&out, bad));
    }
}

test "チェックサム破損を検出する" {
    var payload: [21]u8 = @splat(0x11);
    payload[0] = 0x00;
    var encoded: [64]u8 = undefined;
    const text = try checkEncode(&encoded, &payload);

    var out: [64]u8 = undefined;
    try testing.expectEqualSlices(u8, &payload, try checkDecode(&out, text));

    // 最後の 1 文字を変える
    var corrupted: [64]u8 = undefined;
    @memcpy(corrupted[0..text.len], text);
    corrupted[text.len - 1] = if (corrupted[text.len - 1] == '1') '2' else '1';
    try testing.expectError(error.ChecksumMismatch, checkDecode(&out, corrupted[0..text.len]));
}

test "短すぎる入力を拒否する" {
    var out: [64]u8 = undefined;
    try testing.expectError(error.InvalidEncoding, checkDecode(&out, "1111"));
}
