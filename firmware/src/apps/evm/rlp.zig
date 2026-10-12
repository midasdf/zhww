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
                return try self.openList(length);
            },
            // ロングリスト: 0xF7 + 長さのバイト数（1〜8）
            0xF8...0xFF => {
                const length = try self.readLongLength(prefix - 0xF7);
                return try self.openList(length);
            },
            // 0x00〜0x7F は上で処理済み
            else => unreachable,
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
    // 先頭のリストが入力全体を覆っていることを確認する（末尾の余分なデータを拒否）
    if (@intFromPtr(payload.ptr) + payload.len != @intFromPtr(data.ptr) + data.len) {
        return error.InvalidEncoding;
    }
    // 中身をすべて読み、構造が正準であることを確認する
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
/// イテレータは深さ優先でトークンを返すため、その順に書き出すだけでよい
/// （リストは「ヘッダ → 中身 → 終端」の順に現れる）。非正準な入力を渡すと、
/// 組み直した結果が元のバイト列と異なる。したがって「デコード → 再エンコード」
/// が一致することは、受理した入力が正準形であり、かつイテレータが正しい境界を
/// 返したことの確認になる。
fn reencode(out: []u8, it: *Iterator) Error![]u8 {
    var pos: usize = 0;
    while (try it.next()) |item| {
        pos += switch (item) {
            .bytes => |bytes| (try encodeBytes(out[pos..], bytes)).len,
            .list => |payload| (try encodeListHeader(out[pos..], payload.len)).len,
            .list_end => 0,
        };
    }
    return out[0..pos];
}

/// 公式テストベクタ（RLPTests/rlptest.json）。`in` を `input`、`out` を `encoded` に
/// そのまま写している（16 進文字列は 0x を除いた部分）。
///
/// - `bigint`（2^256）は u256 に収まらないため、整数ではなく**その値のビッグエンディアン
///   表現（33 バイト）**をバイト列として持つ（RLP の整数表現は先頭ゼロを除いた
///   ビッグエンディアンなので、公式の `out` と同じ比較ができる）
const vectors = [_]struct {
    name: []const u8,
    input: Value,
    encoded: []const u8,
}{
    .{
        .name = "emptystring",
        .input = .{ .bytes = "" },
        .encoded = "80",
    },
    .{
        .name = "bytestring00",
        .input = .{ .bytes = "\x00" },
        .encoded = "00",
    },
    .{
        .name = "bytestring01",
        .input = .{ .bytes = "\x01" },
        .encoded = "01",
    },
    .{
        .name = "bytestring7F",
        .input = .{ .bytes = "\x7f" },
        .encoded = "7f",
    },
    .{
        .name = "shortstring",
        .input = .{ .bytes = "dog" },
        .encoded = "83646f67",
    },
    .{
        .name = "shortstring2",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipisicing eli" },
        .encoded = "b74c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c69",
    },
    .{
        .name = "longstring",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipisicing elit" },
        .encoded = "b8384c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e7365637465747572206164697069736963696e6720656c6974",
    },
    .{
        .name = "longstring2",
        .input = .{ .bytes = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Curabitur mauris magna, suscipit sed vehicula non, iaculis faucibus tortor. Proin suscipit ultricies malesuada. Duis tortor elit, dictum quis tristique eu, ultrices at risus. Morbi a est imperdiet mi ullamcorper aliquet suscipit nec lorem. Aenean quis leo mollis, vulputate elit varius, consequat enim. Nulla ultrices turpis justo, et posuere urna consectetur nec. Proin non convallis metus. Donec tempor ipsum in mauris congue sollicitudin. Vestibulum ante ipsum primis in faucibus orci luctus et ultrices posuere cubilia Curae; Suspendisse convallis sem vel massa faucibus, eget lacinia lacus tempor. Nulla quis ultricies purus. Proin auctor rhoncus nibh condimentum mollis. Aliquam consequat enim at metus luctus, a eleifend purus egestas. Curabitur at nibh metus. Nam bibendum, neque at auctor tristique, lorem libero aliquet arcu, non interdum tellus lectus sit amet eros. Cras rhoncus, metus ac ornare cursus, dolor justo ultrices metus, at ullamcorper volutpat" },
        .encoded = "b904004c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742e20437572616269747572206d6175726973206d61676e612c20737573636970697420736564207665686963756c61206e6f6e2c20696163756c697320666175636962757320746f72746f722e2050726f696e20737573636970697420756c74726963696573206d616c6573756164612e204475697320746f72746f7220656c69742c2064696374756d2071756973207472697374697175652065752c20756c7472696365732061742072697375732e204d6f72626920612065737420696d70657264696574206d6920756c6c616d636f7270657220616c6971756574207375736369706974206e6563206c6f72656d2e2041656e65616e2071756973206c656f206d6f6c6c69732c2076756c70757461746520656c6974207661726975732c20636f6e73657175617420656e696d2e204e756c6c6120756c74726963657320747572706973206a7573746f2c20657420706f73756572652075726e6120636f6e7365637465747572206e65632e2050726f696e206e6f6e20636f6e76616c6c6973206d657475732e20446f6e65632074656d706f7220697073756d20696e206d617572697320636f6e67756520736f6c6c696369747564696e2e20566573746962756c756d20616e746520697073756d207072696d697320696e206661756369627573206f726369206c756374757320657420756c74726963657320706f737565726520637562696c69612043757261653b2053757370656e646973736520636f6e76616c6c69732073656d2076656c206d617373612066617563696275732c2065676574206c6163696e6961206c616375732074656d706f722e204e756c6c61207175697320756c747269636965732070757275732e2050726f696e20617563746f722072686f6e637573206e69626820636f6e64696d656e74756d206d6f6c6c69732e20416c697175616d20636f6e73657175617420656e696d206174206d65747573206c75637475732c206120656c656966656e6420707572757320656765737461732e20437572616269747572206174206e696268206d657475732e204e616d20626962656e64756d2c206e6571756520617420617563746f72207472697374697175652c206c6f72656d206c696265726f20616c697175657420617263752c206e6f6e20696e74657264756d2074656c6c7573206c65637475732073697420616d65742065726f732e20437261732072686f6e6375732c206d65747573206163206f726e617265206375727375732c20646f6c6f72206a7573746f20756c747269636573206d657475732c20617420756c6c616d636f7270657220766f6c7574706174",
    },
    .{
        .name = "zero",
        .input = .{ .uint = 0 },
        .encoded = "80",
    },
    .{
        .name = "smallint",
        .input = .{ .uint = 1 },
        .encoded = "01",
    },
    .{
        .name = "smallint2",
        .input = .{ .uint = 16 },
        .encoded = "10",
    },
    .{
        .name = "smallint3",
        .input = .{ .uint = 79 },
        .encoded = "4f",
    },
    .{
        .name = "smallint4",
        .input = .{ .uint = 127 },
        .encoded = "7f",
    },
    .{
        .name = "mediumint1",
        .input = .{ .uint = 128 },
        .encoded = "8180",
    },
    .{
        .name = "mediumint2",
        .input = .{ .uint = 1000 },
        .encoded = "8203e8",
    },
    .{
        .name = "mediumint3",
        .input = .{ .uint = 100000 },
        .encoded = "830186a0",
    },
    // in = 83729609699884896815286331701780722（15 バイト）
    .{
        .name = "mediumint4",
        .input = .{ .uint = 0x102030405060708090a0b0c0d0e0f2 },
        .encoded = "8f102030405060708090a0b0c0d0e0f2",
    },
    // in = 105315505618206987246253880190783558935785933862974822347068935681（29 バイト）
    .{
        .name = "mediumint5",
        .input = .{ .uint = 0x100020003000400050006000700080009000a000b000c000d000e01 },
        .encoded = "9c0100020003000400050006000700080009000a000b000c000d000e01",
    },
    .{
        .name = "emptylist",
        .input = .{ .list = &.{  } },
        .encoded = "c0",
    },
    .{
        .name = "stringlist",
        .input = .{ .list = &.{ .{ .bytes = "dog" }, .{ .bytes = "god" }, .{ .bytes = "cat" } } },
        .encoded = "cc83646f6783676f6483636174",
    },
    .{
        .name = "multilist",
        .input = .{ .list = &.{ .{ .bytes = "zw" }, .{ .list = &.{ .{ .uint = 4 } } }, .{ .uint = 1 } } },
        .encoded = "c6827a77c10401",
    },
    .{
        .name = "shortListMax1",
        .input = .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" }, .{ .bytes = "asdf" }, .{ .bytes = "qwer" } } },
        .encoded = "f784617364668471776572847a78637684617364668471776572847a78637684617364668471776572847a78637684617364668471776572",
    },
    .{
        .name = "longList1",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } } } },
        .encoded = "f840cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376",
    },
    .{
        .name = "longList2",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } }, .{ .list = &.{ .{ .bytes = "asdf" }, .{ .bytes = "qwer" }, .{ .bytes = "zxcv" } } } } },
        .encoded = "f90200cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376cf84617364668471776572847a786376",
    },
    .{
        .name = "listsoflists",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{  } } } }, .{ .list = &.{  } } } },
        .encoded = "c4c2c0c0c0",
    },
    .{
        .name = "listsoflists2",
        .input = .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{ .{ .list = &.{  } } } }, .{ .list = &.{ .{ .list = &.{  } }, .{ .list = &.{ .{ .list = &.{  } } } } } } } },
        .encoded = "c7c0c1c0c3c0c1c0",
    },
    .{
        .name = "dictTest1",
        .input = .{ .list = &.{ .{ .list = &.{ .{ .bytes = "key1" }, .{ .bytes = "val1" } } }, .{ .list = &.{ .{ .bytes = "key2" }, .{ .bytes = "val2" } } }, .{ .list = &.{ .{ .bytes = "key3" }, .{ .bytes = "val3" } } }, .{ .list = &.{ .{ .bytes = "key4" }, .{ .bytes = "val4" } } } } },
        .encoded = "ecca846b6579318476616c31ca846b6579328476616c32ca846b6579338476616c33ca846b6579348476616c34",
    },
    // 公式ベクタの `bigint`: in = 2^256、out = 0xa1 0100...00（33 バイトの整数）
    .{
        .name = "bigint",
        .input = .{ .bytes = "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" },
        .encoded = "a1010000000000000000000000000000000000000000000000000000000000000000",
    },
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
        try testing.expectEqualSlices(u8, encoded, reencoded);

        // 5) 最後まで読み切れること（余分なデータや閉じていないリストがないこと）
        var walk = Iterator.open(encoded);
        while ((try walk.next()) != null) {}
        try walk.finish();
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
    var expected: [64]u8 = undefined;
    var hex_buf: [256]u8 = undefined;

    try expectHex("80", try encodeUint(&buf, 0));
    try expectHex("7f", try encodeUint(&buf, 0x7f));
    try expectHex("8180", try encodeUint(&buf, 0x80));
    try expectHex("820400", try encodeUint(&buf, 0x400));
    try expectHex(
        "a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
        try encodeUint(&buf, std.math.maxInt(u256)),
    );

    // 1 バイトの 0x80 には長さヘッダが付く（0x80 単体は空文字列）
    try expectHex("8180", try encodeBytes(&buf, &[_]u8{0x80}));
    try expectHex("80", try encodeBytes(&buf, &.{}));

    // 55 バイトはショート形式（0xB7 = 0x80 + 55）
    var data: [56]u8 = undefined;
    @memset(&data, 0xaa);
    expected[0] = 0xb7;
    @memset(expected[1..56], 0xaa);
    try expectHex(toHex(&hex_buf, expected[0..56]), try encodeBytes(&buf, data[0..55]));

    // 56 バイトはロング形式（0xB8 + 長さ 1 バイト 0x38 = 56）
    expected[0] = 0xb8;
    expected[1] = 56;
    @memset(expected[2..58], 0xaa);
    try expectHex(toHex(&hex_buf, expected[0..58]), try encodeBytes(&buf, &data));
}
