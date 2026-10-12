//! UR で必要な範囲の CBOR（RFC 8949）と、その決定性プロファイル dCBOR。
//!
//! **対応する範囲**
//! - エンコード: 符号なし整数・バイト文字列・テキスト文字列・配列・タグ付き型。
//!   整数と長さは常に最短表現で書く（dCBOR / RFC 8949 §4.1 の決定性）。
//! - デコード: 上記に加えて、マップ・負数・単純値/浮動小数点を **読み飛ばす** ことができる
//!   （`skipItem` / `isWellFormed`）。UR のメッセージ（PSBT など）の中身を解釈しないまま
//!   「dCBOR として壊れていないか」を検査するために使う。
//! - 不定長（indefinite length, 追加情報 31）は未対応。UR のメッセージは dCBOR であり、
//!   dCBOR は不定長を禁止しているため、現れることはない。
//!
//! **設計方針**
//! - 決定性に厳格: `Reader.strict`（既定 true）のとき、最短表現でない整数・長さは
//!   error.InvalidEncoding で拒否する。同じ値に複数の表現があると、UR の型や
//!   チェックサムの検証をすり抜ける余地が生まれるため。
//! - 深いネストでスタックを食い潰さないよう、`skipItem` は深さの上限（`max_depth`）で拒否する。
//! - 秘密情報を扱わないため、メモリ確保は行わない（出力先は呼び出し側が用意する）。
//!
//! 参考: https://www.rfc-editor.org/rfc/rfc8949.html
//!       https://datatracker.ietf.org/doc/draft-mcnally-deterministic-cbor/
//! テストベクタの出典: RFC 8949 §Appendix A（診断記法と十六進の対応表）と、
//! BCR-2020-012 / BCR-2024-001 の CBOR 例。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// ヘッダ（型 + 引数）の最大バイト数。ヘッダだけを書く一時バッファの大きさに使える。
pub const max_header_len = 9;

/// ネストの深さの上限。これを超える入力は error.InvalidEncoding で拒否する。
pub const max_depth = 32;

/// 主要型（RFC 8949 §3.1 の major type）。
pub const MajorType = enum(u3) {
    unsigned_int = 0,
    negative_int = 1,
    byte_string = 2,
    text_string = 3,
    array = 4,
    map = 5,
    tag = 6,
    simple = 7,
};

/// `value` を最短表現で書くのに必要なヘッダのバイト数。
pub fn headLength(value: u64) usize {
    if (value < 24) return 1;
    if (value <= 0xff) return 2;
    if (value <= 0xffff) return 3;
    if (value <= 0xffff_ffff) return 5;
    return 9;
}

/// バイト文字列として符号化したときの長さ（ヘッダ + 本体）。
pub fn bytesLength(data_len: usize) usize {
    return headLength(data_len) + data_len;
}

/// n バイトで表現された値が取りうる最小値（決定性の検査に使う）。
fn minimalValueForWidth(width: usize) u64 {
    return switch (width) {
        1 => 24,
        2 => 0x100,
        4 => 0x1_0000,
        8 => 0x1_0000_0000,
        else => unreachable,
    };
}

fn writeBigEndian(out: []u8, value: u64, width: usize) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .big);
    @memcpy(out[0..width], buf[8 - width ..]);
}

// ---------------------------------------------------------------- エンコード

/// ヘッダ（型 + 最短表現の引数）を書く。
///
/// タグ付き型は `writeTag` のあとに続けて中身を書く（CBOR ではタグは「次の 1 項目」に
/// かかるため、中身の長さをヘッダに含めない）。
pub fn writeHead(out: []u8, major: MajorType, value: u64) Error![]u8 {
    const width = headLength(value);
    if (out.len < width) return error.BufferTooSmall;

    const prefix: u8 = @as(u8, @intFromEnum(major)) << 5;
    switch (width) {
        1 => out[0] = prefix | @as(u8, @intCast(value)),
        2 => {
            out[0] = prefix | 24;
            writeBigEndian(out[1..], value, 1);
        },
        3 => {
            out[0] = prefix | 25;
            writeBigEndian(out[1..], value, 2);
        },
        5 => {
            out[0] = prefix | 26;
            writeBigEndian(out[1..], value, 4);
        },
        9 => {
            out[0] = prefix | 27;
            writeBigEndian(out[1..], value, 8);
        },
        else => unreachable,
    }
    return out[0..width];
}

/// 符号なし整数（主要型 0）。
pub fn writeUint(out: []u8, value: u64) Error![]u8 {
    return writeHead(out, .unsigned_int, value);
}

/// タグ（主要型 6）。`6.40300` なら `writeTag(out, 40300)` のあとに中身を書く。
pub fn writeTag(out: []u8, tag: u64) Error![]u8 {
    return writeHead(out, .tag, tag);
}

/// 配列のヘッダ（主要型 4）。中身は呼び出し側が `length` 個書く。
pub fn writeArrayHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .array, length);
}

/// バイト文字列のヘッダ（主要型 2）。中身は呼び出し側が書く。
pub fn writeBytesHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .byte_string, length);
}

/// テキスト文字列のヘッダ（主要型 3）。
pub fn writeTextHeader(out: []u8, length: usize) Error![]u8 {
    return writeHead(out, .text_string, length);
}

/// バイト文字列（主要型 2）。
pub fn writeBytes(out: []u8, data: []const u8) Error![]u8 {
    const header = try writeBytesHeader(out, data.len);
    if (out.len < header.len + data.len) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..data.len], data);
    return out[0 .. header.len + data.len];
}

/// テキスト文字列（主要型 3）。UTF-8 の妥当性は検査しない。
pub fn writeText(out: []u8, text: []const u8) Error![]u8 {
    const header = try writeTextHeader(out, text.len);
    if (out.len < header.len + text.len) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..text.len], text);
    return out[0 .. header.len + text.len];
}

// ---------------------------------------------------------------- デコード

/// 読み取ったヘッダ。
pub const Head = struct {
    major: MajorType,
    /// 引数の値（整数値・長さ・タグ番号）。
    value: u64,
    /// ヘッダのバイト数。
    len: usize,
};

/// 先頭から順に読む CBOR デコーダ。
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    /// true なら最短表現でない整数・長さを拒否する（dCBOR の決定性）。
    strict: bool = true,

    pub fn init(data: []const u8) Reader {
        return .{ .data = data };
    }

    /// 入力全体を読み終えているか。
    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.data.len;
    }

    /// 入力全体を読み終えたことを確認する（余分なデータを許さない）。
    pub fn finish(self: *const Reader) Error!void {
        if (self.pos != self.data.len) return error.InvalidEncoding;
    }

    /// 次のヘッダを読む。
    ///
    /// 追加情報 31（不定長）と 28〜30（予約）は error.InvalidEncoding。
    pub fn readHead(self: *Reader) Error!Head {
        if (self.pos >= self.data.len) return error.Truncated;

        const first = self.data[self.pos];
        const major: MajorType = @enumFromInt(@as(u3, @intCast(first >> 5)));
        const additional: u8 = first & 0x1f;

        var width: usize = 0;
        var value: u64 = additional;
        var len: usize = 1;

        switch (additional) {
            0...23 => {},
            24, 25, 26, 27 => {
                width = switch (additional) {
                    24 => 1,
                    25 => 2,
                    26 => 4,
                    else => 8,
                };
                if (self.data.len - self.pos < 1 + width) return error.Truncated;
                value = 0;
                for (self.data[self.pos + 1 ..][0..width]) |byte| value = (value << 8) | byte;
                len = 1 + width;
                // dCBOR: もっと短く書ける値は拒否する。
                // 主要型 7（単純値・浮動小数点）の引数は長さではないので除外する。
                if (self.strict and major != .simple and value < minimalValueForWidth(width)) {
                    return error.InvalidEncoding;
                }
            },
            else => return error.InvalidEncoding,
        }

        self.pos += len;
        return .{ .major = major, .value = value, .len = len };
    }

    /// 符号なし整数（主要型 0）を読む。
    pub fn readUint(self: *Reader) Error!u64 {
        const head = try self.readHead();
        if (head.major != .unsigned_int) return error.InvalidEncoding;
        return head.value;
    }

    /// タグ（主要型 6）を読む。中身は続けて読む。
    pub fn readTag(self: *Reader) Error!u64 {
        const head = try self.readHead();
        if (head.major != .tag) return error.InvalidEncoding;
        return head.value;
    }

    /// 配列のヘッダ（主要型 4）を読み、要素数を返す。
    pub fn readArrayHeader(self: *Reader) Error!usize {
        const head = try self.readHead();
        if (head.major != .array) return error.InvalidEncoding;
        if (head.value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(head.value);
    }

    /// マップのヘッダ（主要型 5）を読み、組の数を返す。
    pub fn readMapHeader(self: *Reader) Error!usize {
        const head = try self.readHead();
        if (head.major != .map) return error.InvalidEncoding;
        if (head.value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(head.value);
    }

    fn readString(self: *Reader, major: MajorType) Error![]const u8 {
        const head = try self.readHead();
        if (head.major != major) return error.InvalidEncoding;
        if (head.value > self.data.len - self.pos) return error.Truncated;
        const length: usize = @intCast(head.value);
        const body = self.data[self.pos..][0..length];
        self.pos += length;
        return body;
    }

    /// バイト文字列（主要型 2）を読む。返るスライスは入力の一部を指す。
    pub fn readBytes(self: *Reader) Error![]const u8 {
        return self.readString(.byte_string);
    }

    /// テキスト文字列（主要型 3）を読む。返るスライスは入力の一部を指す。
    pub fn readText(self: *Reader) Error![]const u8 {
        return self.readString(.text_string);
    }

    fn skipItemDepth(self: *Reader, depth: usize) Error!void {
        if (depth > max_depth) return error.InvalidEncoding;

        const head = try self.readHead();
        switch (head.major) {
            .unsigned_int, .negative_int, .simple => {},
            .byte_string, .text_string => {
                if (head.value > self.data.len - self.pos) return error.Truncated;
                self.pos += @intCast(head.value);
            },
            .array => {
                var i: u64 = 0;
                while (i < head.value) : (i += 1) try self.skipItemDepth(depth + 1);
            },
            .map => {
                var i: u64 = 0;
                while (i < head.value) : (i += 1) {
                    try self.skipItemDepth(depth + 1); // キー
                    try self.skipItemDepth(depth + 1); // 値
                }
            },
            .tag => try self.skipItemDepth(depth + 1),
        }
    }

    /// 次の 1 項目を読み飛ばす（中身は解釈しない）。
    pub fn skipItem(self: *Reader) Error!void {
        return self.skipItemDepth(0);
    }
};

/// 入力全体が「ちょうど 1 つの CBOR 項目」として壊れていないかを検査する。
///
/// `strict` が true なら dCBOR の最短表現も要求する。
pub fn isWellFormed(data: []const u8, strict: bool) bool {
    var reader = Reader{ .data = data, .strict = strict };
    reader.skipItem() catch return false;
    return reader.pos == data.len;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn asHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

fn expectEncoded(expected_hex: []const u8, actual: []const u8) !void {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(asHex(&buf, expected_hex), actual);
}

test "RFC 8949 Appendix A の整数表現と一致する" {
    // 診断記法 → 十六進（RFC 8949 §Appendix A）
    const vectors = [_]struct { value: u64, hex: []const u8 }{
        .{ .value = 0, .hex = "00" },
        .{ .value = 10, .hex = "0a" },
        .{ .value = 23, .hex = "17" },
        .{ .value = 24, .hex = "1818" },
        .{ .value = 25, .hex = "1819" },
        .{ .value = 100, .hex = "1864" },
        .{ .value = 255, .hex = "18ff" },
        .{ .value = 256, .hex = "190100" },
        .{ .value = 1000, .hex = "1903e8" },
        .{ .value = 65535, .hex = "19ffff" },
        .{ .value = 65536, .hex = "1a00010000" },
        .{ .value = 1000000, .hex = "1a000f4240" },
        .{ .value = 4294967295, .hex = "1affffffff" },
        .{ .value = 4294967296, .hex = "1b0000000100000000" },
        .{ .value = 1000000000000, .hex = "1b000000e8d4a51000" },
        .{ .value = 18446744073709551615, .hex = "1bffffffffffffffff" },
    };

    for (vectors) |vector| {
        var out: [16]u8 = undefined;
        const encoded = try writeUint(&out, vector.value);
        try expectEncoded(vector.hex, encoded);

        // ラウンドトリップ
        var reader = Reader.init(encoded);
        try testing.expectEqual(vector.value, try reader.readUint());
        try reader.finish();
    }
}

test "RFC 8949 Appendix A の配列・バイト文字列・テキスト・タグと一致する" {
    var out: [64]u8 = undefined;

    // h'' / h'01020304'
    try expectEncoded("40", try writeBytes(&out, ""));
    var four: [4]u8 = undefined;
    try expectEncoded("4401020304", try writeBytes(&out, asHex(&four, "01020304")));

    // "" / "a" / "IETF"
    try expectEncoded("60", try writeText(&out, ""));
    try expectEncoded("6161", try writeText(&out, "a"));
    try expectEncoded("6449455446", try writeText(&out, "IETF"));

    // [] / [1, 2, 3] / [1, [2, 3], [4, 5]] / {}
    try expectEncoded("80", try writeArrayHeader(&out, 0));
    var pos: usize = 0;
    pos += (try writeArrayHeader(out[pos..], 3)).len;
    for ([_]u64{ 1, 2, 3 }) |value| pos += (try writeUint(out[pos..], value)).len;
    try expectEncoded("83010203", out[0..pos]);

    pos = 0;
    pos += (try writeArrayHeader(out[pos..], 3)).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeArrayHeader(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 3)).len;
    pos += (try writeArrayHeader(out[pos..], 2)).len;
    pos += (try writeUint(out[pos..], 4)).len;
    pos += (try writeUint(out[pos..], 5)).len;
    try expectEncoded("8301820203820405", out[0..pos]);

    try expectEncoded("a0", try writeHead(&out, .map, 0));

    // タグ: 0("2013-03-21T20:04:00Z") と 40300（BCR-2020-012 の seed）
    try expectEncoded("c0", try writeTag(&out, 0));
    try expectEncoded("d99d6c", try writeTag(&out, 40300));

    pos = 0;
    pos += (try writeTag(out[pos..], 40300)).len;
    pos += (try writeHead(out[pos..], .map, 1)).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeBytes(out[pos..], asHex(&four, "deadbeef"))).len;
    try expectEncoded("d99d6ca10144deadbeef", out[0..pos]);
}

test "BCR-2024-001 のパート CBOR を読み取れる" {
    // FountainEncoder::Part(seqNum: 1, seqLen: 9, messageLen: 256, checksum: 0x0167aa07,
    // data: 29 バイト) の CBOR（BCR-2024-001 §5 の testEncoderCBOR より）。
    var buf: [128]u8 = undefined;
    const part = asHex(
        &buf,
        "8501091901001a0167aa07581d916ec65cf77cadf55cd7f9cda1a1030026ddd42e905b77adc36e4f2d3c",
    );

    var reader = Reader.init(part);
    try testing.expectEqual(@as(usize, 5), try reader.readArrayHeader());
    try testing.expectEqual(@as(u64, 1), try reader.readUint());
    try testing.expectEqual(@as(u64, 9), try reader.readUint());
    try testing.expectEqual(@as(u64, 256), try reader.readUint());
    try testing.expectEqual(@as(u64, 0x0167aa07), try reader.readUint());
    const data = try reader.readBytes();
    try testing.expectEqual(@as(usize, 29), data.len);
    try testing.expectEqual(@as(u8, 0x91), data[0]);
    try testing.expectEqual(@as(u8, 0x3c), data[28]);
    try reader.finish();

    // 全体としても壊れていない。
    try testing.expect(isWellFormed(part, true));
}

test "タグ付き型を読み取れる（BCR-2020-012 の seed）" {
    var buf: [64]u8 = undefined;
    const seed = asHex(&buf, "d99d6ca20150c7098580125e2ab0981253468b2dbc5202c11947da");

    var reader = Reader.init(seed);
    try testing.expectEqual(@as(u64, 40300), try reader.readTag());
    try testing.expectEqual(@as(usize, 2), try reader.readMapHeader());
    try testing.expectEqual(@as(u64, 1), try reader.readUint());
    try testing.expectEqual(@as(usize, 16), (try reader.readBytes()).len);
    try testing.expectEqual(@as(u64, 2), try reader.readUint());
    try testing.expectEqual(@as(u64, 1), try reader.readTag());
    try testing.expectEqual(@as(u64, 18394), try reader.readUint());
    try reader.finish();
}

test "マップ・負数・単純値・浮動小数点を読み飛ばせる" {
    // {"a": 1, "b": [-1, null, true, 1.5]}
    var out: [64]u8 = undefined;
    var pos: usize = 0;
    pos += (try writeHead(out[pos..], .map, 2)).len;
    pos += (try writeText(out[pos..], "a")).len;
    pos += (try writeUint(out[pos..], 1)).len;
    pos += (try writeText(out[pos..], "b")).len;
    pos += (try writeArrayHeader(out[pos..], 4)).len;
    pos += (try writeHead(out[pos..], .negative_int, 0)).len; // -1
    pos += (try writeHead(out[pos..], .simple, 22)).len; // null
    pos += (try writeHead(out[pos..], .simple, 21)).len; // true
    out[pos] = 0xf9;
    out[pos + 1] = 0x3e;
    out[pos + 2] = 0x00; // 1.5（float16）
    pos += 3;
    const document = out[0..pos];

    // RFC 8949 の表現どおり（-1 は 0x20、null は 0xf6、true は 0xf5、1.5 は 0xf93e00）。
    try expectEncoded("a261610161628420f6f5f93e00", document);

    try testing.expect(isWellFormed(document, true));
    var reader = Reader.init(document);
    try reader.skipItem();
    try reader.finish();

    // 浮動小数点（主要型 7）は最短表現の検査対象外。
    var float_buf: [16]u8 = undefined;
    const float32 = asHex(&float_buf, "fa00000000"); // 0.0 を float32 で書いたもの
    var float_reader = Reader.init(float32);
    try testing.expectEqual(@as(u64, 0), (try float_reader.readHead()).value);
    try float_reader.finish();
}

test "非最短表現を拒否する（dCBOR の決定性）" {
    var buf_a: [16]u8 = undefined;
    var buf_b: [16]u8 = undefined;
    var buf_c: [16]u8 = undefined;

    // 0 を 2 バイトで書いたもの（正しくは 0x00）
    const non_minimal_zero = asHex(&buf_a, "1800");
    var reader = Reader.init(non_minimal_zero);
    try testing.expectError(error.InvalidEncoding, reader.readHead());
    try testing.expect(!isWellFormed(non_minimal_zero, true));
    // 緩めれば読める（相互運用のために strict = false も選べる）。
    try testing.expect(isWellFormed(non_minimal_zero, false));

    // 255 を 4 バイトで書いたもの（正しくは 0x18ff）
    reader = Reader.init(asHex(&buf_b, "1a000000ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());

    // 長さ 2 のバイト文字列を 2 バイトの長さで書いたもの（正しくは 0x42）
    reader = Reader.init(asHex(&buf_c, "58020203"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
}

test "不定長と予約値を拒否する" {
    var buf: [16]u8 = undefined;

    // 不定長のバイト文字列（0x5f ... 0xff）と不定長の配列（0x9f ... 0xff）
    var reader = Reader.init(asHex(&buf, "5f420102ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
    reader = Reader.init(asHex(&buf, "9f0102ff"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());

    // 追加情報 28（予約）
    reader = Reader.init(asHex(&buf, "1c"));
    try testing.expectError(error.InvalidEncoding, reader.readHead());
}

test "切り詰め・型違い・余分なデータを拒否する" {
    var buf: [16]u8 = undefined;

    // ヘッダだけあって本体がない
    var reader = Reader.init(asHex(&buf, "44"));
    try testing.expectError(error.Truncated, reader.readBytes());
    var reader2 = Reader.init(asHex(&buf, "58"));
    try testing.expectError(error.Truncated, reader2.readHead());
    var reader3 = Reader.init(asHex(&buf, ""));
    try testing.expectError(error.Truncated, reader3.readHead());
    try testing.expect(!isWellFormed(asHex(&buf, "1901"), true));

    // 型違い
    var reader4 = Reader.init(asHex(&buf, "6161"));
    try testing.expectError(error.InvalidEncoding, reader4.readUint());
    var reader5 = Reader.init(asHex(&buf, "4401020304"));
    try testing.expectError(error.InvalidEncoding, reader5.readArrayHeader());
    var reader6 = Reader.init(asHex(&buf, "00"));
    try testing.expectError(error.InvalidEncoding, reader6.readTag());

    // 余分なデータ
    try testing.expect(!isWellFormed(asHex(&buf, "0000"), true));
    var reader7 = Reader.init(asHex(&buf, "0000"));
    try testing.expectEqual(@as(u64, 0), try reader7.readUint());
    try testing.expectError(error.InvalidEncoding, reader7.finish());
}

test "ネストが深すぎる入力を拒否する" {
    // 0x81（要素 1 の配列）を 64 段重ねたあとに 0x00
    var deep: [65]u8 = @splat(0x81);
    deep[64] = 0x00;
    try testing.expect(!isWellFormed(&deep, true));

    // max_depth 以内なら通る
    var shallow: [max_depth + 1]u8 = @splat(0x81);
    shallow[max_depth] = 0x00;
    try testing.expect(isWellFormed(&shallow, true));
}

test "出力バッファが足りない場合は BufferTooSmall" {
    var short: [2]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, writeUint(&short, 65536));
    try testing.expectError(error.BufferTooSmall, writeHead(&short, .tag, 40300));
    try testing.expectError(error.BufferTooSmall, writeBytes(short[0..1], &.{ 1, 2 }));
    try testing.expectError(error.BufferTooSmall, writeText(short[0..1], "abc"));
}
