//! RLP（Recursive Length Prefix）のエンコードとデコード。
//!
//! Ethereum のトランザクション・ブロック・状態トライで使われる直列化形式。
//!
//! **設計方針**
//! - **正準性（canonical）に厳格**。RLP は同じ値に対して複数の表現が存在しうる
//!   （1 バイト（< 0x80）を長さ付きで書く、長さを最短バイト数で書かない、など）。
//!   署名対象ハッシュは 1 バイト違えば別のハッシュになるため、非正準な表現は
//!   すべて error.InvalidEncoding で拒否する。
//! - 秘密情報を扱わないため、メモリ確保は行わない（出力先は呼び出し側が用意する）。
//!
//! 参考: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
//!       https://github.com/ethereum/tests/blob/develop/RLPTests/rlptest.json
//!       https://ethereum.github.io/yellowpaper/paper.pdf （付録 B）

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;

/// デコード時に許す最大ネスト深さ。
///
/// 正規のトランザクションは 3 段程度しかネストしない。深い入力をそのまま
/// 再帰処理するとスタックを食い潰すため、上限を設けて拒否する。
pub const max_depth = 16;

/// RLP の長さヘッダの最大バイト数（種別 1 バイト + 長さ 8 バイト）。
/// 長さヘッダだけを書く一時バッファの大きさとして使える。
pub const max_header_len = 9;

// ---------------------------------------------------------------- エンコード

/// 値を表すのに必要な最小バイト数（0 のときは 0）。
fn byteLen(value: usize) usize {
    if (value == 0) return 0;
    return (@bitSizeOf(usize) - @clz(value) + 7) / 8;
}

/// 長さヘッダを `out` に書く。`offset` はバイト列（0x80）かリスト（0xC0）の種別。
///
/// 55 以下は 1 バイト（`offset + len`）、それ以上は `offset + 55 + 長さのバイト数` の
/// 後ろに長さをビッグエンディアンで書く。長さは常に最短バイト数で書く。
fn encodeLenHeader(out: []u8, payload_len: usize, offset: u8) Error![]u8 {
    if (payload_len < 56) {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = offset + @as(u8, @intCast(payload_len));
        return out[0..1];
    }
    const length_bytes = byteLen(payload_len);
    if (out.len < 1 + length_bytes) return error.BufferTooSmall;

    var length_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &length_buf, @intCast(payload_len), .big);
    out[0] = offset + 55 + @as(u8, @intCast(length_bytes));
    @memcpy(out[1..][0..length_bytes], length_buf[8 - length_bytes ..]);
    return out[0 .. 1 + length_bytes];
}

/// バイト列の RLP ヘッダ（本体を含まない）を `out` に書く。
///
/// 返り値が空スライスの場合は「1 バイトかつ < 0x80 はそのまま符号化する」ケースで、
/// **本体をそのまま出力すればよい**。ハッシュ計算のように本体をコピーせずに
/// ストリーミングしたい場合に使う。
pub fn encodeBytesHeader(out: []u8, data: []const u8) Error![]u8 {
    if (data.len == 1 and data[0] < 0x80) return out[0..0];
    return encodeLenHeader(out, data.len, 0x80);
}

/// バイト列をエンコードする。
///
/// 1 バイトかつ 0x00〜0x7F の場合はそのバイト自身が符号化になる（`0x80` を付けない）。
/// 空文字列は `0x80`。
pub fn encodeBytes(out: []u8, data: []const u8) Error![]u8 {
    const header = try encodeBytesHeader(out, data);
    if (header.len == 0) {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = data[0];
        return out[0..1];
    }
    if (out.len < header.len + data.len) return error.BufferTooSmall;
    @memcpy(out[header.len..][0..data.len], data);
    return out[0 .. header.len + data.len];
}

/// 整数をエンコードする（Ethereum の「整数は先頭ゼロを付けないビッグエンディアン」規則）。
///
/// 0 は空文字列 `0x80`、1 バイトに収まる値は長さヘッダを付けない。
pub fn encodeUint(out: []u8, value: u256) Error![]u8 {
    if (value == 0) return encodeBytes(out, &.{});
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &buf, value, .big);
    const leading_zero_bytes: usize = @clz(value) / 8;
    return encodeBytes(out, buf[leading_zero_bytes..]);
}

/// リストのヘッダを書く（本体は呼び出し側が `payload_len` バイト書く）。
pub fn encodeListHeader(out: []u8, payload_len: usize) Error![]u8 {
    return encodeLenHeader(out, payload_len, 0xC0);
}

// ---------------------------------------------------------------- デコード

/// デコードしたトークン。
pub const Item = union(enum) {
    /// バイト列（整数・アドレス・データなど）。
    bytes: []const u8,
    /// リストの開始。`payload` はリストの中身全体（ヘッダを含まない）。
    list: []const u8,
    /// リストの終端。
    list_end,
};

/// トークン列を先頭から順に返すイテレータ。
///
/// リストは `.list` → 中身 → `.list_end` の順に現れる。入力全体を読み終えると
/// `null` を返す。読み終えたら必ず `finish()` を呼び、余分なデータや閉じていない
/// リストがないことを確認する。
pub const Iterator = struct {
    data: []const u8,
    pos: usize = 0,
    depth: usize = 0,
    /// 現在開いている各リストの終端位置。
    ends: [max_depth]usize = @splat(0),

    pub fn open(data: []const u8) Iterator {
        return .{ .data = data };
    }

    /// 現在の入れ子（最も内側のリスト、無ければ入力全体）の終端。
    fn currentEnd(self: *const Iterator) usize {
        if (self.depth == 0) return self.data.len;
        return self.ends[self.depth - 1];
    }

    /// `start` から `len` バイトを読む範囲を検査して終端を返す。
    fn checkedEnd(self: *const Iterator, start: usize, len: usize) Error!usize {
        if (start > self.data.len or len > self.data.len - start) return error.Truncated;
        const end = start + len;
        // 親リストの終端を越える要素は構造として不正
        if (end > self.currentEnd()) return error.InvalidEncoding;
        return end;
    }

    /// ロング形式の長さ（0xB8〜0xBF / 0xF8〜0xFF）を読む。
    fn readLongLength(self: *const Iterator, length_bytes: usize) Error!usize {
        const start = self.pos + 1;
        if (start + length_bytes > self.data.len) return error.Truncated;
        // 最短バイト数で書かれていない長さ（先頭バイトが 0）は非正準
        if (self.data[start] == 0) return error.InvalidEncoding;

        var value: u64 = 0;
        for (self.data[start .. start + length_bytes]) |byte| {
            value = (value << 8) | byte;
        }
        if (value < 56) return error.InvalidEncoding;
        if (value > std.math.maxInt(usize)) return error.InvalidEncoding;
        return @intCast(value);
    }

    pub fn next(self: *Iterator) Error!?Item {
        // 開いているリストの終端に到達したら list_end を返す
        if (self.depth > 0 and self.pos == self.ends[self.depth - 1]) {
            self.depth -= 1;
            return .list_end;
        }
        if (self.pos >= self.data.len) return null;

        const prefix = self.data[self.pos];
        // 単一バイト（0x00〜0x7F）はそれ自身が符号化
        if (prefix < 0x80) {
            const item = self.data[self.pos .. self.pos + 1];
            self.pos += 1;
            return .{ .bytes = item };
        }

        switch (prefix) {
            // ショート文字列: 0x80 + 長さ（0〜55）
            0x80...0xB7 => {
                const length = prefix - 0x80;
                const start = self.pos + 1;
                const end = try self.checkedEnd(start, length);
                // 1 バイト（< 0x80）は長さ付きで書いてはならない（非正準）
                if (length == 1 and self.data[start] < 0x80) return error.InvalidEncoding;
                self.pos = end;
                return .{ .bytes = self.data[start..end] };
            },
            // ロング文字列: 0xB7 + 長さのバイト数（1〜8）
            0xB8...0xBF => {
                const length = try self.readLongLength(prefix - 0xB7);
                const start = self.pos + 1 + (prefix - 0xB7);
                const end = try self.checkedEnd(start, length);
                self.pos = end;
                return .{ .bytes = self.data[start..end] };
            },
            // ショートリスト: 0xC0 + ペイロード長（0〜55）
            0xC0...0xF7 => {
                const length = prefix - 0xC0;
                return self.openList(length);
            },
            // ロングリスト: 0xF7 + 長さのバイト数（1〜8）
            0xF8...0xFF => {
                const length = try self.readLongLength(prefix - 0xF7);
                return self.openList(length);
            },
        }
    }

    fn openList(self: *Iterator, payload_len: usize) Error!Item {
        if (self.depth >= max_depth) return error.InvalidEncoding;
        const length_bytes: usize = if (payload_len < 56)
            0
        else
            byteLen(payload_len);
        const start = self.pos + 1 + length_bytes;
        const end = try self.checkedEnd(start, payload_len);
        self.ends[self.depth] = end;
        self.depth += 1;
        self.pos = start;
        return .{ .list = self.data[start..end] };
    }

    /// 入力全体を矛盾なく読み切ったことを確認する。
    pub fn finish(self: *const Iterator) Error!void {
        if (self.depth != 0) return error.Truncated;
        if (self.pos != self.data.len) return error.InvalidEncoding;
    }
};

/// 単一のバイト列（整数・アドレス・データ）としてデコードする。
pub fn decodeBytes(data: []const u8) Error![]const u8 {
    var it = Iterator.open(data);
    const first = (try it.next()) orelse return error.Truncated;
    const payload = switch (first) {
        .bytes => |bytes| bytes,
        else => return error.InvalidEncoding,
    };
    if ((try it.next()) != null) return error.InvalidEncoding;
    try it.finish();
    return payload;
}

/// 単一のリストとしてデコードし、ペイロードを返す。
pub fn decodeList(data: []const u8) Error![]const u8 {
    var it = Iterator.open(data);
    const first = (try it.next()) orelse return error.Truncated;
    const payload = switch (first) {
        .list => |bytes| bytes,
        else => return error.InvalidEncoding,
    };
    // 残りをすべて読み、構造が正準であることを確認する
    while ((try it.next()) != null) {}
    try it.finish();
    return payload;
}

/// RLP のペイロード（長さヘッダを除いたバイト列）を整数として読む。
///
/// 先頭にゼロバイトがある表現は非正準なので拒否する（`0x00` の 1 バイトも拒否）。
/// 空文字列は 0 の正準形として受理する。
pub fn decodeUintPayload(payload: []const u8) Error!u256 {
    if (payload.len == 0) return 0;
    if (payload.len > 32) return error.InvalidEncoding;
    if (payload[0] == 0) return error.InvalidEncoding;

    var buf: [32]u8 = @splat(0);
    @memcpy(buf[32 - payload.len ..], payload);
    return std.mem.readInt(u256, &buf, .big);
}

/// 単一の整数としてデコードする。
pub fn decodeUint(data: []const u8) Error!u256 {
    return decodeUintPayload(try decodeBytes(data));
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// テストの失敗時に差分を読めるよう 16 進文字列に直す。
fn toHex(buf: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        buf[i * 2] = digits[byte >> 4];
        buf[i * 2 + 1] = digits[byte & 0x0F];
    }
    return buf[0 .. bytes.len * 2];
}

fn expectHex(expected: []const u8, actual: []const u8) !void {
    var buf: [8192]u8 = undefined;
    try testing.expectEqualStrings(expected, toHex(&buf, actual));
}

/// 公式テストベクタの入力をそのまま書けるようにするための値。
const Value = union(enum) {
    bytes: []const u8,
    uint: u256,
    list: []const Value,
};

fn encodeValue(out: []u8, value: Value) Error![]u8 {
    switch (value) {
        .bytes => |bytes| return encodeBytes(out, bytes),
        .uint => |number| return encodeUint(out, number),
        .list => |items| {
            var payload_buf: [4096]u8 = undefined;
            var payload_len: usize = 0;
            for (items) |item| {
                payload_len += (try encodeValue(payload_buf[payload_len..], item)).len;
            }
            const header = try encodeListHeader(out, payload_len);
            if (out.len < header.len + payload_len) return error.BufferTooSmall;
            @memcpy(out[header.len..][0..payload_len], payload_buf[0..payload_len]);
            return out[0 .. header.len + payload_len];
        },
    }
}

/// デコードしたトークン列を正準 RLP に組み直す。
///
/// 非正準な入力を渡すと、組み直した結果が元のバイト列と異なる。したがって
/// 「デコード → 再エンコード」が一致することは、受理した入力が正準形であり、
/// かつイテレータが正しい境界を返したことの確認になる。
fn reencode(out: []u8, it: *Iterator) Error![]u8 {
    var pos: usize = 0;
    while (try it.next()) |item| {
        switch (item) {
            .bytes => |bytes| pos += (try encodeBytes(out[pos..], bytes)).len,
            .list => |payload| {
                var sub = Iterator.open(payload);
                var body_buf: [4096]u8 = undefined;
                const body = try reencode(&body_buf, &sub);
                const header = try encodeListHeader(out[pos..], body.len);
                pos += header.len;
                if (out.len < pos + body.len) return error.BufferTooSmall;
                @memcpy(out[pos..][0..body.len], body);
                pos += body.len;
            },
            .list_end => return out[0..pos],
        }
    }
    return out[0..pos];
}

/// 公式テストベクタ（RLPTests/rlptest.json）。`in` を `input`、`out` を `encoded` に
/// そのまま写している（16 進文字列は 0x を除いた部分）。
///
/// - `bigint`（2^256）は u256 に収まらないため整数ではなくバイト列として持つ
const vectors = [_]struct {
    name: []const u8,
    input: Value,
    encoded: []const u8,
}{
    // @@VECTORS@@
};

test "公式ベクタ: エンコード" {
    var buf: [4096]u8 = undefined;
    for (vectors) |vector| {
        const encoded = encodeValue(&buf, vector.input) catch |err| {
            std.debug.print("ベクタ {s}: エンコードに失敗 ({s})\n", .{ vector.name, @errorName(err) });
            return err;
        };
        expectHex(vector.encoded, encoded) catch |err| {
            std.debug.print("ベクタ {s}: 公式の `out` と一致しない\n", .{vector.name});
            return err;
        };
    }
}

test "公式ベクタ: デコード（正準形の往復）" {
    var encoded_buf: [4096]u8 = undefined;
    var decoded_buf: [4096]u8 = undefined;
    var payload_buf: [4096]u8 = undefined;

    for (vectors) |vector| {
        const encoded = try encodeValue(&encoded_buf, vector.input);

        // 1) バイト列ベクタは decodeBytes で入力そのものが戻る
        // 2) 整数ベクタは decodeUint が元の値になる
        // 3) リストベクタは decodeList がヘッダを除いた長さを返す
        switch (vector.input) {
            .bytes => |bytes| {
                const decoded = decodeBytes(encoded) catch |err| {
                    std.debug.print("ベクタ {s}: decodeBytes 失敗 ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                try testing.expectEqualSlices(u8, bytes, decoded);
            },
            .uint => |number| {
                const decoded = decodeUint(encoded) catch |err| {
                    std.debug.print("ベクタ {s}: decodeUint 失敗 ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                try testing.expectEqual(number, decoded);
            },
            .list => |items| {
                const payload = decodeList(encoded) catch |err| {
                    std.debug.print("ベクタ {s}: decodeList 失敗 ({s})\n", .{ vector.name, @errorName(err) });
                    return err;
                };
                var payload_len: usize = 0;
                for (items) |item| {
                    payload_len += (try encodeValue(payload_buf[payload_len..], item)).len;
                }
                try testing.expectEqual(payload_len, payload.len);
            },
        }

        // 4) トークン列を読み切って組み直すと元のバイト列に戻る
        var it = Iterator.open(encoded);
        const reencoded = reencode(&decoded_buf, &it) catch |err| {
            std.debug.print("ベクタ {s}: 再エンコード失敗 ({s})\n", .{ vector.name, @errorName(err) });
            return err;
        };
        try it.finish();
        try testing.expectEqualSlices(u8, encoded, reencoded);
    }
}

test "非正準な表現を拒否する" {
    // 1 バイト（< 0x80）を長さ付きで書いている
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x81, 0x7f }));
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x81, 0x00 }));

    // 55 バイト以下をロング形式（0xB8）で書いている
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0xb8, 0x01, 0x80 }));
    var short_long: [2 + 55]u8 = undefined;
    short_long[0] = 0xb8;
    short_long[1] = 55;
    @memset(short_long[2..], 0x41);
    try testing.expectError(error.InvalidEncoding, decodeBytes(&short_long));

    // 長さが最短バイト数で書かれていない（先頭バイトが 0）
    var padded: [3 + 56]u8 = undefined;
    padded[0] = 0xb9;
    padded[1] = 0x00;
    padded[2] = 56;
    @memset(padded[3..], 0x41);
    try testing.expectError(error.InvalidEncoding, decodeBytes(&padded));

    // リストでも同じ規則
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xf8, 0x01, 0x80 }));
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xf9, 0x00, 0x38, 0xc0 }));

    // 整数として非正準（先頭ゼロバイト、33 バイト）
    try testing.expectError(error.InvalidEncoding, decodeUint(&[_]u8{0x00}));
    try testing.expectError(error.InvalidEncoding, decodeUint(&[_]u8{ 0x82, 0x00, 0x01 }));
    var too_large: [34]u8 = undefined;
    too_large[0] = 0xa1;
    @memset(too_large[1..], 0x01);
    try testing.expectError(error.InvalidEncoding, decodeUint(&too_large));
}

test "途中で終わっている入力を拒否する" {
    // 3 バイトと宣言して 2 バイトしかない
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{ 0x83, 0x61, 0x62 }));
    // 長さのバイト数が足りない
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{ 0xb9, 0x01 }));
    // リストのペイロードが足りない
    try testing.expectError(error.Truncated, decodeList(&[_]u8{ 0xc2, 0x80 }));
    try testing.expectError(error.Truncated, decodeList(&[_]u8{ 0xf8, 0x40, 0xc0 }));
    // 空入力
    try testing.expectError(error.Truncated, decodeBytes(&[_]u8{}));
    try testing.expectError(error.Truncated, decodeList(&[_]u8{}));
}

test "リストの境界を越える入力を拒否する" {
    // 親リスト（ペイロード 1 バイト）の中に、親より長い子リストを置いている
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xc1, 0xc2, 0x80, 0x80 }));

    // 正しい入れ子（親の終端と子の終端が一致）は受理する: [ [ [ "" ] ] ]
    var it = Iterator.open(&[_]u8{ 0xc3, 0xc2, 0xc1, 0x80 });
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.bytes, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(Item.list_end, std.meta.activeTag((try it.next()).?));
    try testing.expectEqual(@as(?Item, null), try it.next());
    try it.finish();
}

test "ネストが深すぎる入力を拒否する" {
    // 各レベルが「残り全部」をペイロードに持つリスト（深さ = 配列長 - 1）
    var ok: [max_depth + 1]u8 = undefined;
    for (0..ok.len - 1) |i| ok[i] = 0xc0 + @as(u8, @intCast(ok.len - 1 - i));
    ok[ok.len - 1] = 0x80;
    _ = try decodeList(&ok);

    var too_deep: [max_depth + 2]u8 = undefined;
    for (0..too_deep.len - 1) |i| too_deep[i] = 0xc0 + @as(u8, @intCast(too_deep.len - 1 - i));
    too_deep[too_deep.len - 1] = 0x80;
    try testing.expectError(error.InvalidEncoding, decodeList(&too_deep));
}

test "余分なデータを拒否する" {
    try testing.expectError(error.InvalidEncoding, decodeBytes(&[_]u8{ 0x80, 0x80 }));
    try testing.expectError(error.InvalidEncoding, decodeList(&[_]u8{ 0xc0, 0x80 }));
}

test "整数の境界（0、1 バイト、55/56 バイト境界）" {
    var buf: [64]u8 = undefined;

    try expectHex("80", try encodeUint(&buf, 0));
    try expectHex("7f", try encodeUint(&buf, 0x7f));
    try expectHex("8180", try encodeUint(&buf, 0x80));
    try expectHex("820400", try encodeUint(&buf, 0x400));
    try expectHex("a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", try encodeUint(&buf, std.math.maxInt(u256)));

    // 1 バイトの 0x80 は長さヘッダが付く（0x80 単体は空文字列）
    try expectHex("8180", try encodeBytes(&buf, &[_]u8{0x80}));
    try expectHex("80", try encodeBytes(&buf, &.{}));

    // 55 バイトはショート形式、56 バイトはロング形式
    var data: [56]u8 = undefined;
    @memset(&data, 0xaa);
    try expectHex("b7" ++ ("aa" ** 55), try encodeBytes(&buf, data[0..55]));
    var long_out: [64]u8 = undefined;
    try expectHex("b838" ++ ("aa" ** 56), try encodeBytes(&long_out, &data));
}
