//! EVM の ABI（Application Binary Interface）デコードと関数セレクタ。
//!
//! 参考: https://docs.soliditylang.org/en/latest/abi-spec.html
//!
//! **設計方針（clear signing の前提）**
//! - 画面に出す値は、**仕様どおりに正準（canonical）なエンコード**からのみ取り出す。
//!   余分なデータ、範囲外・順序違いのオフセット、長さのあふれ、ゼロでないパディングは
//!   すべて拒否する（`error.InvalidEncoding` / `error.Truncated`）。曖昧な入力は表示しない。
//! - 動的な値は「ヘッド（オフセット語）＋テール（実データ）」が**隙間なくこの順に**
//!   並んでいることを要求する。Solidity が出力する形だけを受け付ける。
//! - 配列のオフセットは、その集約値の**要素ヘッド列の先頭**からの相対位置である
//!   （動的配列では長さ語の直後、固定長配列では配列自身の先頭）。Solidity 仕様書の
//!   例（`g(uint256[][],string[])`）で検算している。
//! - `string` は UTF-8 の検証をしない（バイト列のまま返す）。表示側で検証する。
//! - **tuple（構造体）型はデコードしない**。型の解析だけは行い、セレクタの計算には
//!   含める（記述子の一致判定には必要）。デコードが必要になった時点で別途対応する。
//! - 確保するメモリは動的な配列・可変長バイト列のときだけ。呼び出し側の `allocator`
//!   （通常は `ArenaAllocator`）から確保し、呼び出し側が解放する。
//!
//! テストの一部は Solidity 仕様書の公式例をそのまま埋め込んでいる（自前の期待値は
//! 使わない）。セレクタは Keccak-256 の計算結果と既知の定数を突き合わせる。

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");

/// 語長。ABI のヘッドは 32 バイト単位。
pub const word_size = 32;

/// セレクタの長さ（`keccak256(signature)` の先頭 4 バイト）。
pub const selector_len = 4;

/// ABI の型。
///
/// `fixed_array` と `array` の要素型は再帰するため、アロケータ上に確保した
/// `AbiType` へのポインタで表す（`parseTypeList` / `parseFragment` が構築する）。
pub const AbiType = union(enum) {
    /// 符号なし整数。ビット幅（8..256、8 の倍数）。
    uint: u16,
    /// 符号付き整数。ビット幅（8..256、8 の倍数）。
    int: u16,
    address,
    bool,
    /// `bytes<M>`（1..32）。静的型。
    bytes_fixed: u16,
    /// 動的 `bytes`。
    bytes,
    /// 動的 `string`。
    string,
    /// 固定長配列 `T[k]`。
    fixed_array: Array,
    /// 動的配列 `T[]`。
    array: Array,

    pub const Array = struct {
        element: *const AbiType,
        /// `null` は動的長（`T[]`）、数値は固定長（`T[k]`）。
        len: ?usize = null,
    };
};

/// デコード結果。
///
/// `bytes` / `string` / `bytes_fixed` は**入力バッファを指すスライス**である
/// （コピーしない）。入力より長生きさせてはならない。
pub const Value = union(enum) {
    uint: u256,
    int: i256,
    address: [20]u8,
    boolean: bool,
    /// `bytes<M>` と動的 `bytes` の両方。
    bytes: []const u8,
    string: []const u8,
    fixed_array: []Value,
    array: []Value,
};

// ---------------------------------------------------------------- セレクタ

/// calldata の先頭 4 バイト（関数セレクタ）。4 バイト未満は null。
pub fn selector(calldata: []const u8) ?[selector_len]u8 {
    if (calldata.len < selector_len) return null;
    return calldata[0..selector_len].*;
}

/// 型のみの正準シグネチャ（`transfer(address,uint256)`）からセレクタを計算する。
pub fn computeSelector(signature: []const u8) [selector_len]u8 {
    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(signature, &digest, .{});
    return digest[0..selector_len].*;
}

/// 既知の関数（セレクタと引数型）。
pub const Known = struct {
    /// 型のみの正準シグネチャ。
    signature: []const u8,
    /// 引数の型。
    types: []const AbiType,
};

const uint256_type: AbiType = .{ .uint = 256 };
const uint8_type: AbiType = .{ .uint = 8 };
const address_type: AbiType = .address;
const bool_type: AbiType = .bool;
const bytes32_type: AbiType = .{ .bytes_fixed = 32 };

const known_functions = [_]Known{
    // ERC-20
    .{ .signature = "transfer(address,uint256)", .types = &[_]AbiType{ address_type, uint256_type } },
    .{ .signature = "approve(address,uint256)", .types = &[_]AbiType{ address_type, uint256_type } },
    .{ .signature = "transferFrom(address,address,uint256)", .types = &[_]AbiType{ address_type, address_type, uint256_type } },
    // ERC-721 / ERC-1155
    .{ .signature = "setApprovalForAll(address,bool)", .types = &[_]AbiType{ address_type, bool_type } },
    // ERC-2612（EIP-2612 permit）
    .{
        .signature = "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
        .types = &[_]AbiType{ address_type, address_type, uint256_type, uint256_type, uint8_type, bytes32_type, bytes32_type },
    },
};

/// 既知の関数セレクタなら、そのシグネチャと引数型を返す。
///
/// 未知のセレクタに対しては null（**推測しない**）。
pub fn knownFunction(sel: [selector_len]u8) ?Known {
    for (known_functions) |function| {
        const computed = computeSelector(function.signature);
        if (std.mem.eql(u8, &computed, &sel)) return function;
    }
    return null;
}

/// 既知の関数の一覧（テストと UI 用）。
pub fn knownFunctions() []const Known {
    return &known_functions;
}

// ---------------------------------------------------------------- デコード

/// 引数をデコードする。
///
/// `out.len` は `types.len` 以上でなければならない（足りなければ `error.BufferTooSmall`）。
/// `out[0..types.len]` に書き込む。配列の要素は `allocator` から確保する。
///
/// 拒否する条件:
/// - `data` の長さが 32 の倍数でない / ヘッド領域に足りない（`error.InvalidEncoding` / `error.Truncated`）
/// - 動的型のオフセットが正準の位置でない（順序違い・重複・範囲外）
/// - 動的配列・`bytes`・`string` の長さがあふれている、データが足りない
/// - デコード後に**余分なデータ**が残る
/// - 正準でない値（`bool` が 0/1 以外、`uint<M>` の上位ビット、`address` の上位 12 バイト、
///   `bytes<M>` や `bytes` のパディングが非ゼロ、`int<M>` の符号拡張が不一致）
pub fn decodeParameters(
    allocator: std.mem.Allocator,
    types: []const AbiType,
    data: []const u8,
    out: []Value,
) Error!void {
    if (out.len < types.len) return error.BufferTooSmall;

    var head_len: usize = 0;
    for (types) |t| head_len = try addChecked(head_len, try headWords(t));

    if (data.len % word_size != 0) return error.InvalidEncoding;
    if (data.len < head_len) return error.Truncated;

    var head_at: usize = 0;
    var tail: usize = head_len;
    for (types, 0..) |t, i| {
        if (isDynamic(t)) {
            // 動的型のヘッドはオフセット語 1 つ。テールは隙間なく並んでいるはず。
            const offset = try toLength(try readWord(data, head_at));
            if (offset != tail) return error.InvalidEncoding;
            const consumed = try decodeDynamic(t, data[offset..], &out[i], allocator);
            tail = try addChecked(tail, consumed);
            head_at += word_size;
        } else {
            try decodeStatic(t, data[head_at..], &out[i], allocator);
            head_at += try headWords(t);
        }
    }

    // 余分なデータを許さない。
    if (tail != data.len) return error.InvalidEncoding;
}

/// 動的型か（親のヘッドではオフセット語 1 つになる型か）。
pub fn isDynamic(t: AbiType) bool {
    return switch (t) {
        .bytes, .string, .array => true,
        .fixed_array => |a| isDynamic(a.element.*),
        else => false,
    };
}

/// 親のヘッド領域でこの型が占めるバイト数。
///
/// 動的型はオフセット語 1 つ。静的型は符号化そのものの長さ（固定長配列は要素の和）。
fn headWords(t: AbiType) Error!usize {
    if (isDynamic(t)) return word_size;
    return switch (t) {
        .fixed_array => |a| try mulChecked(a.len orelse return error.InvalidEncoding, try headWords(a.element.*)),
        else => word_size,
    };
}

/// 静的な値を `data` の先頭からデコードする（`data` は値の先頭を指す）。
fn decodeStatic(t: AbiType, data: []const u8, out: *Value, allocator: std.mem.Allocator) Error!void {
    switch (t) {
        .uint => |bits| {
            const word = try readWord(data, 0);
            if (bits < 256) {
                // `uint<M>` の上位 (256-M) ビットはゼロでなければならない。
                if (word >> @intCast(bits) != 0) return error.InvalidEncoding;
            }
            out.* = .{ .uint = word };
        },
        .int => |bits| {
            const word = try readWord(data, 0);
            if (bits >= 256) {
                out.* = .{ .int = @bitCast(word) };
                return;
            }
            const shift: u8 = @intCast(bits);
            const sign = (word >> @intCast(bits - 1)) & 1;
            const upper = word >> shift; // 上位 (256-M) ビット
            // 符号拡張が一貫していること（M-1 ビット目が 1 なら上位はすべて 1）。
            const expected: u256 = if (sign == 1) @as(u256, std.math.maxInt(u256)) >> shift else 0;
            if (upper != expected) return error.InvalidEncoding;
            const low = word & maskBits(bits);
            out.* = .{ .int = if (sign == 1)
                @as(i256, @intCast(low)) - (@as(i256, 1) << shift)
            else
                @as(i256, @intCast(low)) };
        },
        .address => {
            const word = try readWord(data, 0);
            // 上位 12 バイトはゼロでなければならない。
            if (word >> 160 != 0) return error.InvalidEncoding;
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, word, .big);
            out.* = .{ .address = bytes[12..32].* };
        },
        .bool => {
            const word = try readWord(data, 0);
            if (word > 1) return error.InvalidEncoding;
            out.* = .{ .boolean = word == 1 };
        },
        .bytes_fixed => |m| {
            const word = try readWord(data, 0);
            if (m < 32) {
                // 右側のパディングはゼロでなければならない。
                if (word & maskBytes(@intCast(32 - m)) != 0) return error.InvalidEncoding;
            }
            // `bytes<M>` は語の左詰めなので先頭 M バイトが値（入力のスライスを返す）。
            out.* = .{ .bytes = data[0..m] };
        },
        .fixed_array => |a| {
            const element = a.element.*;
            const element_head = try headWords(element);
            const count = a.len orelse return error.InvalidEncoding;
            const values = try allocator.alloc(Value, count);
            for (values, 0..) |*slot, i| {
                try decodeStatic(element, data[i * element_head ..], slot, allocator);
            }
            out.* = .{ .fixed_array = values };
        },
        .bytes, .string, .array => unreachable, // 動的型は decodeDynamic が扱う
    }
}

/// 動的な値を、その値自身の符号化（`region` の先頭）からデコードし、
/// 消費したバイト数を返す。
fn decodeDynamic(
    t: AbiType,
    region: []const u8,
    out: *Value,
    allocator: std.mem.Allocator,
) Error!usize {
    switch (t) {
        .bytes, .string => {
            const len = try toLength(try readWord(region, 0));
            const padded = try paddedLength(len);
            if (word_size + padded > region.len) return error.Truncated;
            const contents = region[word_size .. word_size + len];
            // パディングはゼロでなければならない。
            if (!allZero(region[word_size + len .. word_size + padded])) return error.InvalidEncoding;
            out.* = if (t == .string) .{ .string = contents } else .{ .bytes = contents };
            return word_size + padded;
        },
        .array, .fixed_array => {
            const a = switch (t) {
                .array => |x| x,
                .fixed_array => |x| x,
                else => unreachable,
            };
            const element = a.element.*;

            // 動的配列は長さ語の直後、固定長配列は配列自身の先頭が「要素ヘッド列」。
            var count: usize = 0;
            var base: usize = 0;
            if (t == .array) {
                count = try toLength(try readWord(region, 0));
                base = word_size;
            } else {
                count = a.len orelse return error.InvalidEncoding;
            }

            const element_head = if (isDynamic(element)) word_size else try headWords(element);
            const head_end = try addChecked(base, try mulChecked(count, element_head));
            if (head_end > region.len) return error.Truncated;

            const values = try allocator.alloc(Value, count);
            var tail = head_end;
            for (values, 0..) |*slot, i| {
                const at = base + i * element_head;
                if (isDynamic(element)) {
                    // オフセットは要素ヘッド列の先頭（= base）からの相対位置。
                    const offset = try toLength(try readWord(region, at));
                    if (offset != tail - base) return error.InvalidEncoding;
                    tail = try addChecked(tail, try decodeDynamic(element, region[base + offset ..], slot, allocator));
                    if (tail > region.len) return error.Truncated;
                } else {
                    try decodeStatic(element, region[at..], slot, allocator);
                }
            }

            out.* = if (t == .array) .{ .array = values } else .{ .fixed_array = values };
            // `tail` は region の先頭からの消費バイト数（動的配列では長さ語を含む）。
            return tail;
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- 型の解析

/// ヒューマンリーダブルな ABI フラグメントの解析結果。
pub const Fragment = struct {
    /// 関数名（例 `transfer`）。
    name: []const u8,
    /// 型のみの正準シグネチャ（例 `transfer(address,uint256)`）。セレクタの計算対象。
    signature: []const u8,
    /// 引数の型。**tuple（構造体）を含む場合は null**（セレクタの計算だけが可能）。
    types: ?[]const AbiType,
    /// トップレベルの引数名。名前が無い引数は空文字列。
    names: []const []const u8,
};

/// `transfer(address _to, uint256 _value)` のようなフラグメントを解析する。
///
/// ERC-7730 の `display.formats` のキーはこの形（型名＋引数名）をしている。
/// 型のみの正準形（`transfer(address,uint256)`）に正規化して返すので、
/// 空白の入れ方や `uint` / `int` の別名（`uint256` / `int256` に正規化）に依存しない。
/// tuple は `(address,uint256)` と `tuple(address,uint256)` の両方を受け付ける。
pub fn parseFragment(allocator: std.mem.Allocator, text: []const u8) Error!Fragment {
    var parser = Parser{ .allocator = allocator, .text = text };
    parser.skipSpace();

    const name = try parser.parseName();
    parser.skipSpace();
    try parser.expect('(');

    var nodes = std.ArrayList(*const TypeNode).empty;
    defer nodes.deinit(allocator);
    var names = std.ArrayList([]const u8).empty;
    defer names.deinit(allocator);

    parser.skipSpace();
    if (parser.peek() == ')') {
        parser.pos += 1;
    } else {
        while (true) {
            const node = try parser.parseType();
            parser.skipSpace();
            // 引数名は省略可能（正準形では省略される）。
            const parameter_name = if (parser.peekIsIdentStart()) try parser.parseName() else "";
            try nodes.append(allocator, node);
            try names.append(allocator, parameter_name);
            parser.skipSpace();
            const c = parser.peek() orelse return error.InvalidEncoding;
            if (c == ',') {
                parser.pos += 1;
                parser.skipSpace();
                continue;
            }
            if (c == ')') {
                parser.pos += 1;
                break;
            }
            return error.InvalidEncoding;
        }
    }
    parser.skipSpace();
    if (parser.pos != text.len) return error.InvalidEncoding;

    // 型のみの正準シグネチャを組み立てる。
    var signature = std.ArrayList(u8).empty;
    defer signature.deinit(allocator);
    try signature.appendSlice(allocator, name);
    try signature.append(allocator, '(');
    for (nodes.items, 0..) |node, i| {
        if (i != 0) try signature.append(allocator, ',');
        try printType(allocator, node, &signature);
    }
    try signature.append(allocator, ')');

    // デコード可能な型に変換する（tuple を含むなら null）。
    const slots = try allocator.alloc(AbiType, nodes.items.len);
    var decodable = true;
    for (nodes.items, 0..) |node, i| {
        const converted = try toAbiType(allocator, node);
        if (converted == null) {
            decodable = false;
            break;
        }
        slots[i] = converted.?;
    }

    return .{
        .name = name,
        .signature = try signature.toOwnedSlice(allocator),
        .types = if (decodable) slots else null,
        .names = try names.toOwnedSlice(allocator),
    };
}

/// カンマ区切りの型リスト（`address,uint256`）を解析する。tuple は受け付けない。
pub fn parseTypeList(allocator: std.mem.Allocator, text: []const u8) Error![]AbiType {
    var parser = Parser{ .allocator = allocator, .text = text };
    var list = std.ArrayList(AbiType).empty;
    defer list.deinit(allocator);

    parser.skipSpace();
    while (true) {
        const node = try parser.parseType();
        const converted = try toAbiType(allocator, node) orelse return error.InvalidEncoding;
        try list.append(allocator, converted);
        parser.skipSpace();
        const c = parser.peek() orelse break;
        if (c != ',') return error.InvalidEncoding;
        parser.pos += 1;
        parser.skipSpace();
    }
    return list.toOwnedSlice(allocator);
}

/// 型の構文木。`AbiType` に落とせない（tuple を含む）場合があるため別に持つ。
const TypeNode = union(enum) {
    uint: u16,
    int: u16,
    address,
    bool,
    bytes_fixed: u16,
    bytes,
    string,
    array: struct {
        element: *const TypeNode,
        len: ?usize,
    },
    tuple: []const *const TypeNode,
};

const Parser = struct {
    allocator: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    fn peek(self: Parser) ?u8 {
        if (self.pos >= self.text.len) return null;
        return self.text[self.pos];
    }

    fn peekIsIdentStart(self: Parser) bool {
        const c = self.peek() orelse return false;
        return isIdentStart(c);
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.text.len and isSpace(self.text[self.pos])) self.pos += 1;
    }

    fn expect(self: *Parser, c: u8) Error!void {
        if (self.peek() != c) return error.InvalidEncoding;
        self.pos += 1;
    }

    fn parseName(self: *Parser) Error![]const u8 {
        if (!self.peekIsIdentStart()) return error.InvalidEncoding;
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.text.len and isIdentChar(self.text[self.pos])) self.pos += 1;
        return self.text[start..self.pos];
    }

    /// 型 1 つ（配列の接尾辞を含む）を解析する。
    fn parseType(self: *Parser) Error!*const TypeNode {
        self.skipSpace();
        var node = try self.parseBaseType();
        // 配列の接尾辞（`[]` / `[N]`）は繰り返し付きうる（`T[][2]` など）。
        while (true) {
            self.skipSpace();
            if (self.peek() != '[') break;
            self.pos += 1;
            var len: ?usize = null;
            if (self.peek() != ']') {
                const digits = try self.parseDigits();
                len = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidEncoding;
            }
            try self.expect(']');
            const wrapper = try self.allocator.create(TypeNode);
            wrapper.* = .{ .array = .{ .element = node, .len = len } };
            node = wrapper;
        }
        return node;
    }

    fn parseBaseType(self: *Parser) Error!*const TypeNode {
        if (self.peek() == '(') {
            self.pos += 1;
            return self.parseTupleBody();
        }
        const name = try self.parseName();
        const node = try self.allocator.create(TypeNode);

        if (std.mem.eql(u8, name, "address")) {
            node.* = .address;
            return node;
        }
        if (std.mem.eql(u8, name, "bool")) {
            node.* = .bool;
            return node;
        }
        if (std.mem.eql(u8, name, "string")) {
            node.* = .string;
            return node;
        }
        if (std.mem.eql(u8, name, "bytes")) {
            node.* = .bytes;
            return node;
        }
        if (std.mem.eql(u8, name, "tuple")) {
            try self.expect('(');
            return self.parseTupleBody();
        }
        if (std.mem.startsWith(u8, name, "bytes")) {
            const m = try parseByteSized(name["bytes".len..]);
            node.* = .{ .bytes_fixed = m };
            return node;
        }
        if (std.mem.startsWith(u8, name, "uint")) {
            node.* = .{ .uint = try parseSized(name["uint".len..], 8, 256) };
            return node;
        }
        if (std.mem.startsWith(u8, name, "int")) {
            node.* = .{ .int = try parseSized(name["int".len..], 8, 256) };
            return node;
        }
        return error.InvalidEncoding;
    }

    /// `(` の直後から tuple の中身を解析する（`(` は消費済み）。
    fn parseTupleBody(self: *Parser) Error!*const TypeNode {
        var elements = std.ArrayList(*const TypeNode).empty;
        defer elements.deinit(self.allocator);

        self.skipSpace();
        if (self.peek() == ')') {
            self.pos += 1;
        } else {
            while (true) {
                const element = try self.parseType();
                self.skipSpace();
                // tuple の中の引数名は表示に使わないので読み飛ばす。
                if (self.peekIsIdentStart()) _ = try self.parseName();
                try elements.append(self.allocator, element);
                self.skipSpace();
                const c = self.peek() orelse return error.InvalidEncoding;
                if (c == ',') {
                    self.pos += 1;
                    continue;
                }
                if (c == ')') {
                    self.pos += 1;
                    break;
                }
                return error.InvalidEncoding;
            }
        }
        const node = try self.allocator.create(TypeNode);
        node.* = .{ .tuple = try elements.toOwnedSlice(self.allocator) };
        return node;
    }

    fn parseDigits(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) self.pos += 1;
        if (self.pos == start) return error.InvalidEncoding;
        return self.text[start..self.pos];
    }
};

/// `uint<M>` / `int<M>` の `<M>`（ビット幅）を検証する。空文字列は 256。
fn parseSized(digits: []const u8, min: u16, max: u16) Error!u16 {
    if (digits.len == 0) return max; // `uint` → 256
    const value = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidEncoding;
    if (value < min or value > max) return error.InvalidEncoding;
    if (value % 8 != 0) return error.InvalidEncoding; // ビット幅は 8 の倍数
    return value;
}

/// `bytes<M>` の `<M>`（バイト幅）を検証する。
fn parseByteSized(digits: []const u8) Error!u16 {
    const value = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidEncoding;
    if (value < 1 or value > 32) return error.InvalidEncoding;
    return value;
}

/// 正準形（型のみ・空白なし）を出力する。
fn printType(allocator: std.mem.Allocator, node: *const TypeNode, out: *std.ArrayList(u8)) Error!void {
    switch (node.*) {
        .uint => |bits| try appendSized(allocator, out, "uint", bits),
        .int => |bits| try appendSized(allocator, out, "int", bits),
        .address => try out.appendSlice(allocator, "address"),
        .bool => try out.appendSlice(allocator, "bool"),
        .bytes => try out.appendSlice(allocator, "bytes"),
        .bytes_fixed => |m| try appendSized(allocator, out, "bytes", m),
        .string => try out.appendSlice(allocator, "string"),
        .array => |a| {
            try printType(allocator, a.element, out);
            if (a.len) |len| {
                var buffer: [24]u8 = undefined;
                const text = std.fmt.bufPrint(&buffer, "[{d}]", .{len}) catch return error.BufferTooSmall;
                try out.appendSlice(allocator, text);
            } else {
                try out.appendSlice(allocator, "[]");
            }
        },
        .tuple => |elements| {
            try out.append(allocator, '(');
            for (elements, 0..) |element, i| {
                if (i != 0) try out.append(allocator, ',');
                try printType(allocator, element, out);
            }
            try out.append(allocator, ')');
        },
    }
}

/// `uint256` のように接頭辞＋ビット幅／バイト幅を出力する。
fn appendSized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8, value: u16) Error!void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}{d}", .{ prefix, value }) catch return error.BufferTooSmall;
    try out.appendSlice(allocator, text);
}

/// 構文木をデコード用の型に変換する。tuple を含む場合は null。
fn toAbiType(allocator: std.mem.Allocator, node: *const TypeNode) Error!?AbiType {
    return switch (node.*) {
        .uint => |bits| AbiType{ .uint = bits },
        .int => |bits| AbiType{ .int = bits },
        .address => AbiType.address,
        .bool => AbiType.bool,
        .bytes => AbiType.bytes,
        .string => AbiType.string,
        .bytes_fixed => |m| AbiType{ .bytes_fixed = m },
        .tuple => null,
        .array => |a| blk: {
            const element = try toAbiType(allocator, a.element) orelse break :blk null;
            const pointer = try allocator.create(AbiType);
            pointer.* = element;
            const array: AbiType.Array = .{ .element = pointer, .len = a.len };
            break :blk if (a.len == null) AbiType{ .array = array } else AbiType{ .fixed_array = array };
        },
    };
}

// ---------------------------------------------------------------- 小物

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn addChecked(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.InvalidEncoding;
}

fn mulChecked(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.InvalidEncoding;
}

/// 32 バイト語をビッグエンディアンで読む。
fn readWord(data: []const u8, at: usize) Error!u256 {
    if (at > data.len or data.len - at < word_size) return error.Truncated;
    return std.mem.readInt(u256, data[at..][0..word_size], .big);
}

/// 長さの語を `usize` に落とす。範囲外は「長さのあふれ」として拒否する。
fn toLength(word: u256) Error!usize {
    if (word > std.math.maxInt(usize)) return error.InvalidEncoding;
    return @intCast(word);
}

/// `bytes` / `string` のパディング込みの長さ。あふれたら拒否する。
fn paddedLength(len: usize) Error!usize {
    const words = try addChecked(len, word_size - 1);
    return mulChecked(words / word_size, word_size);
}

/// 下位 `bits` ビットが 1 のマスク。
fn maskBits(bits: u16) u256 {
    if (bits >= 256) return std.math.maxInt(u256);
    return (@as(u256, 1) << @intCast(bits)) - 1;
}

/// 下位 `bytes` バイトが 1 のマスク（最大 32 バイト）。
fn maskBytes(bytes: u8) u256 {
    return maskBits(@as(u16, bytes) * 8);
}

fn allZero(data: []const u8) bool {
    for (data) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// 16 進文字列をバイト列にする（テスト用）。
fn hexToBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "関数セレクタは Keccak-256 の先頭 4 バイトである" {
    // 期待値は EVM の仕様・実装で広く使われている既知の定数。
    // ここでは Keccak-256 の計算結果と一致することを確認する（自前の定数を信用しない）。
    const vectors = [_]struct { signature: []const u8, selector: [4]u8 }{
        .{ .signature = "transfer(address,uint256)", .selector = hexToBytes(4, "a9059cbb") },
        .{ .signature = "approve(address,uint256)", .selector = hexToBytes(4, "095ea7b3") },
        .{ .signature = "transferFrom(address,address,uint256)", .selector = hexToBytes(4, "23b872dd") },
        .{ .signature = "setApprovalForAll(address,bool)", .selector = hexToBytes(4, "a22cb465") },
        .{
            .signature = "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
            .selector = hexToBytes(4, "d505accf"),
        },
    };

    for (vectors) |vector| {
        const computed = computeSelector(vector.signature);
        try testing.expectEqualSlices(u8, &vector.selector, &computed);
    }
}

test "既知の関数セレクタからシグネチャと引数型を引ける" {
    const transfer = knownFunction(hexToBytes(4, "a9059cbb")).?;
    try testing.expectEqualStrings("transfer(address,uint256)", transfer.signature);
    try testing.expectEqual(@as(usize, 2), transfer.types.len);
    try testing.expectEqual(@as(u16, 256), transfer.types[1].uint);

    const permit = knownFunction(hexToBytes(4, "d505accf")).?;
    try testing.expectEqual(@as(usize, 7), permit.types.len);
    try testing.expectEqual(@as(u16, 8), permit.types[4].uint);
    try testing.expectEqual(@as(u16, 32), permit.types[5].bytes_fixed);

    // 未知のセレクタは推測しない。
    try testing.expect(knownFunction(hexToBytes(4, "deadbeef")) == null);
    try testing.expect(knownFunction(hexToBytes(4, "00000000")) == null);
}

test "calldata の先頭 4 バイトをセレクタとして取り出す" {
    const calldata = hexToBytes(68, "a9059cbb0000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed00000000000000000000000000000000000000000000000000000000000003e8");
    try testing.expectEqualSlices(u8, &hexToBytes(4, "a9059cbb"), &selector(&calldata).?);
    try testing.expect(selector(&[_]u8{ 1, 2, 3 }) == null);
    try testing.expect(selector(&[_]u8{}) == null);
}

test "ERC-20 transfer の calldata をデコードする" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 実在する calldata の形（セレクタ + 4 バイト未満の端数なし）。
    const calldata = hexToBytes(68, "a9059cbb" ++
        "0000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed" ++
        "00000000000000000000000000000000000000000000000000000000000003e8");

    const types = try parseTypeList(allocator, "address,uint256");
    var values: [2]Value = undefined;
    try decodeParameters(allocator, types, calldata[4..], &values);

    try testing.expectEqualSlices(
        u8,
        &hexToBytes(20, "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed"),
        &values[0].address,
    );
    try testing.expectEqual(@as(u256, 1000), values[1].uint);
}

test "Solidity 仕様書の g(uint256[][],string[]) の例をデコードする" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // https://docs.soliditylang.org/en/latest/abi-spec.html の例をそのまま埋め込む。
    // g([[1, 2], [3]], ["one", "two", "three"])
    const blob = hexToBytes(640,
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000140" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "00000000000000000000000000000000000000000000000000000000000000a0" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "0000000000000000000000000000000000000000000000000000000000000060" ++
        "00000000000000000000000000000000000000000000000000000000000000a0" ++
        "00000000000000000000000000000000000000000000000000000000000000e0" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "6f6e650000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "74776f0000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000005" ++
        "7468726565000000000000000000000000000000000000000000000000000000");

    const types = try parseTypeList(allocator, "uint256[][],string[]");
    var values: [2]Value = undefined;
    try decodeParameters(allocator, types, &blob, &values);

    const outer = values[0].array;
    try testing.expectEqual(@as(usize, 2), outer.len);
    try testing.expectEqual(@as(usize, 2), outer[0].array.len);
    try testing.expectEqual(@as(u256, 1), outer[0].array[0].uint);
    try testing.expectEqual(@as(u256, 2), outer[0].array[1].uint);
    try testing.expectEqual(@as(usize, 1), outer[1].array.len);
    try testing.expectEqual(@as(u256, 3), outer[1].array[0].uint);

    const strings = values[1].array;
    try testing.expectEqual(@as(usize, 3), strings.len);
    try testing.expectEqualStrings("one", strings[0].string);
    try testing.expectEqualStrings("two", strings[1].string);
    try testing.expectEqualStrings("three", strings[2].string);
}

test "固定長配列・bytes・bool・int・bytes32 をデコードする" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // bytes4 は左詰め、bool は 1、int8 は -1（符号拡張）、bytes32 は全ビット。
    // ヘッドは 4 語 + 動的配列のオフセット語。テール（`bytes3[]` の長さ語）が末尾に続く。
    const data = hexToBytes(32 * 6,
        "deadbeef00000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff" ++
        "00000000000000000000000000000000000000000000000000000000000000a0" ++
        "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20" ++
        "0000000000000000000000000000000000000000000000000000000000000000");

    const types = try parseTypeList(allocator, "bytes4,bool,int8,bytes3[],bytes32");
    var values: [5]Value = undefined;
    try decodeParameters(allocator, types, &data, &values);

    try testing.expectEqualSlices(u8, &hexToBytes(4, "deadbeef"), values[0].bytes);
    try testing.expect(values[1].boolean);
    try testing.expectEqual(@as(i256, -1), values[2].int);
    // 動的配列 `bytes3[]` の長さは 0（ヘッドにオフセット、テールに長さ語）。
    try testing.expectEqual(@as(usize, 0), values[3].array.len);
    const full = hexToBytes(32, "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");
    try testing.expectEqualSlices(u8, &full, values[4].bytes);
}

test "静的型のオフセットの無い並び（値のみ）をデコードする" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `uint8[2]` は語 2 つぶんを 1 つのヘッドとして使う。
    const data = hexToBytes(32 * 4,
        "0000000000000000000000000000000000000000000000000000000000000007" ++
        "0000000000000000000000000000000000000000000000000000000000000008" ++
        "0000000000000000000000000000000000000000000000000000000000000009" ++
        "000000000000000000000000000000000000000000000000000000000000000a");

    const types = try parseTypeList(allocator, "uint8[2],uint8[2]");
    var values: [2]Value = undefined;
    try decodeParameters(allocator, types, &data, &values);
    try testing.expectEqual(@as(u256, 7), values[0].fixed_array[0].uint);
    try testing.expectEqual(@as(u256, 8), values[0].fixed_array[1].uint);
    try testing.expectEqual(@as(u256, 9), values[1].fixed_array[0].uint);
    try testing.expectEqual(@as(u256, 10), values[1].fixed_array[1].uint);
}

test "固定長配列（動的要素）は配列自身の先頭を基準にオフセットを持つ" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // string[2] = ["a", "b"] を要素に持つ 1 引数（`f(string[2])`）。
    // 固定長配列のオフセットは「配列自身の先頭」からの相対位置になる。
    const data = hexToBytes(32 * 7,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000080" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "6100000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "6200000000000000000000000000000000000000000000000000000000000000");

    const types = try parseTypeList(allocator, "string[2]");
    var values: [1]Value = undefined;
    try decodeParameters(allocator, types, &data, &values);

    try testing.expectEqual(@as(usize, 2), values[0].fixed_array.len);
    try testing.expectEqualStrings("a", values[0].fixed_array[0].string);
    try testing.expectEqualStrings("b", values[0].fixed_array[1].string);
}

test "独立実装（ethers 6.17.0）が生成した calldata をデコードする" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 期待値は ethers 6.17.0 の AbiCoder.encode が出力したもの（自前の期待値ではない）。
    // h(bytes,uint8[2],string,bytes4,int256,bool) = (0xdeadbeef, [7,8], "hello", 0x01020304, -12345, false)
    const h_data = hexToBytes(352,
        "00000000000000000000000000000000000000000000000000000000000000e0" ++
        "0000000000000000000000000000000000000000000000000000000000000007" ++
        "0000000000000000000000000000000000000000000000000000000000000008" ++
        "0000000000000000000000000000000000000000000000000000000000000120" ++
        "0102030400000000000000000000000000000000000000000000000000000000" ++
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffcfc7" ++
        "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000004" ++
        "deadbeef00000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000005" ++
        "68656c6c6f000000000000000000000000000000000000000000000000000000");
    const h_types = try parseTypeList(allocator, "bytes,uint8[2],string,bytes4,int256,bool");
    var h_values: [6]Value = undefined;
    try decodeParameters(allocator, h_types, &h_data, &h_values);

    try testing.expectEqualSlices(u8, &hexToBytes(4, "deadbeef"), h_values[0].bytes);
    try testing.expectEqual(@as(usize, 2), h_values[1].fixed_array.len);
    try testing.expectEqual(@as(u256, 7), h_values[1].fixed_array[0].uint);
    try testing.expectEqual(@as(u256, 8), h_values[1].fixed_array[1].uint);
    try testing.expectEqualStrings("hello", h_values[2].string);
    try testing.expectEqualSlices(u8, &hexToBytes(4, "01020304"), h_values[3].bytes);
    try testing.expectEqual(@as(i256, -12345), h_values[4].int);
    try testing.expect(!h_values[5].boolean);

    // k(bytes32[],uint16[2][]) = ([0xaa…aa, 0xbb…bb], [[1,2],[3,4]])
    const k_data = hexToBytes(320,
        "0000000000000000000000000000000000000000000000000000000000000040" ++
        "00000000000000000000000000000000000000000000000000000000000000a0" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002" ++
        "0000000000000000000000000000000000000000000000000000000000000003" ++
        "0000000000000000000000000000000000000000000000000000000000000004");
    const k_types = try parseTypeList(allocator, "bytes32[],uint16[2][]");
    var k_values: [2]Value = undefined;
    try decodeParameters(allocator, k_types, &k_data, &k_values);

    try testing.expectEqual(@as(usize, 2), k_values[0].array.len);
    const aa: [32]u8 = @splat(0xaa);
    try testing.expectEqualSlices(u8, &aa, k_values[0].array[0].bytes);
    const bb: [32]u8 = @splat(0xbb);
    try testing.expectEqualSlices(u8, &bb, k_values[0].array[1].bytes);
    try testing.expectEqual(@as(usize, 2), k_values[1].array.len);
    try testing.expectEqual(@as(u256, 1), k_values[1].array[0].fixed_array[0].uint);
    try testing.expectEqual(@as(u256, 2), k_values[1].array[0].fixed_array[1].uint);
    try testing.expectEqual(@as(u256, 3), k_values[1].array[1].fixed_array[0].uint);
    try testing.expectEqual(@as(u256, 4), k_values[1].array[1].fixed_array[1].uint);

    // セレクタも独立実装と一致する。
    try testing.expectEqualSlices(u8, &hexToBytes(4, "397db75c"), &computeSelector("h(bytes,uint8[2],string,bytes4,int256,bool)"));
    try testing.expectEqualSlices(u8, &hexToBytes(4, "37e133c7"), &computeSelector("k(bytes32[],uint16[2][])"));
}

test "非正準なエンコードを拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const uint256 = try parseTypeList(allocator, "uint256");
    const two_uint256 = try parseTypeList(allocator, "uint256,uint256");
    const address_arg = try parseTypeList(allocator, "address");
    const bytes_arg = try parseTypeList(allocator, "bytes");
    const bool_arg = try parseTypeList(allocator, "bool");
    const uint8_arg = try parseTypeList(allocator, "uint8");
    const bytes4_arg = try parseTypeList(allocator, "bytes4");
    const array_arg = try parseTypeList(allocator, "uint256[]");

    var value: [1]Value = undefined;
    var two_values: [2]Value = undefined;

    // 32 の倍数でない
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint256, &hexToBytes(31,
        "00000000000000000000000000000000000000000000000000000000000000"), &value));
    // 途中で終わっている（32 の倍数だがヘッドに足りない）
    try testing.expectError(error.Truncated, decodeParameters(allocator, two_uint256, &hexToBytes(32,
        "0000000000000000000000000000000000000000000000000000000000000001"), &two_values));
    // 余分なデータ
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint256, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000000002"), &value));
    // 出力バッファが足りない
    var empty: [0]Value = undefined;
    try testing.expectError(error.BufferTooSmall, decodeParameters(allocator, uint256, &[_]u8{}, &empty));

    // uint8 の上位ビットが非ゼロ（正準でない）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint8_arg, &hexToBytes(32,
        "0000000000000000000000000000000000000000000000000000000000000101"), &value));
    // address の上位 12 バイトが非ゼロ
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, address_arg, &hexToBytes(32,
        "0000000000000000000000010000000000000000000000000000000000000001"), &value));
    // bool が 2
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bool_arg, &hexToBytes(32,
        "0000000000000000000000000000000000000000000000000000000000000002"), &value));
    // bytes4 のパディングが非ゼロ
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes4_arg, &hexToBytes(32,
        "deadbeef000000000000000000000000000000000000000000000000000000ff"), &value));

    // 動的型: オフセットが範囲外
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000040" ++
            "0000000000000000000000000000000000000000000000000000000000000000"), &value));
    // 動的型: オフセットが正準の位置でない（先頭を指している）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000000" ++
            "0000000000000000000000000000000000000000000000000000000000000000"), &value));

    // bytes: 長さがあふれている（`usize` にも収まらない）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), &value));
    // bytes: 実際の長さより短い（切り詰め）
    try testing.expectError(error.Truncated, decodeParameters(allocator, bytes_arg, &hexToBytes(96,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "0000000000000000000000000000000000000000000000000000000000000021" ++
            "0000000000000000000000000000000000000000000000000000000000000000"), &value));
    // bytes: 長さは足りているがパディングが非ゼロ（値 1 バイト + 非ゼロの詰め物）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(96,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "00ff000000000000000000000000000000000000000000000000000000000000"), &value));

    // 動的配列: 要素数が多すぎる（データが足りない）
    try testing.expectError(error.Truncated, decodeParameters(allocator, array_arg, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "0000000000000000000000000000000000000000000000000000000000000040"), &value));
    // 動的配列: 要素数があふれている（`usize` にも収まらない）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, array_arg, &hexToBytes(64,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), &value));
    // 動的配列: 要素のオフセットが正準の位置でない（`uint256[]` なので要素は静的だが、
    // 要素数 1 で余分な語が残るため末尾で拒否される）
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, array_arg, &hexToBytes(128,
        "0000000000000000000000000000000000000000000000000000000000000020" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000000002"), &value));

    // 動的配列（動的要素）: 要素オフセットがテールの先頭を指していない
    const nested = try parseTypeList(allocator, "bytes[],bytes[]");
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, nested, &hexToBytes(160,
        "0000000000000000000000000000000000000000000000000000000000000040" ++
            "00000000000000000000000000000000000000000000000000000000000000c0" ++
            "0000000000000000000000000000000000000000000000000000000000000001" ++
            "0000000000000000000000000000000000000000000000000000000000000020" ++
            "0000000000000000000000000000000000000000000000000000000000000000"), &two_values));
}

test "ヒューマンリーダブルな ABI フラグメントを正準形に変換する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 空白の入れ方（カンマの後ろの空白）に依存しない。
    const transfer = try parseFragment(allocator, "transfer(address _to, uint256 _value)");
    try testing.expectEqualStrings("transfer", transfer.name);
    try testing.expectEqualStrings("transfer(address,uint256)", transfer.signature);
    try testing.expectEqual(@as(usize, 2), transfer.names.len);
    try testing.expectEqualStrings("_to", transfer.names[0]);
    try testing.expectEqualStrings("_value", transfer.names[1]);
    try testing.expectEqualSlices(u8, &hexToBytes(4, "a9059cbb"), &computeSelector(transfer.signature));

    // 引数名が無い正準形、別名 `uint` → `uint256`、配列。
    const canonical = try parseFragment(allocator, "airdrop(address[],uint)");
    try testing.expectEqualStrings("airdrop(address[],uint256)", canonical.signature);
    try testing.expectEqual(@as(usize, 2), canonical.types.?.len);
    try testing.expect(isDynamic(canonical.types.?[0]));
    try testing.expectEqual(@as(usize, 256), canonical.types.?[1].uint);

    // 固定長配列・入れ子の配列。
    const nested = try parseFragment(allocator, "f(uint16[3][],bytes32)");
    try testing.expectEqualStrings("f(uint16[3][],bytes32)", nested.signature);
    try testing.expectEqual(@as(usize, 3), nested.types.?[0].array.element.fixed_array.len);

    // tuple はセレクタの計算だけ行い、デコード用の型は作らない。
    const tuple = try parseFragment(
        allocator,
        "submitOrder((address token,uint256 amount) order,bytes32 salt)",
    );
    try testing.expectEqualStrings("submitOrder((address,uint256),bytes32)", tuple.signature);
    try testing.expect(tuple.types == null);
    try testing.expectEqualStrings("order", tuple.names[0]);
    try testing.expectEqualStrings("salt", tuple.names[1]);
}

test "壊れたフラグメントを拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bad = [_][]const u8{
        "transfer(address,uint256", // 閉じ括弧が無い
        "transfer(address,)", // 空の引数
        "transfer(uint7)", // 8 の倍数でない
        "transfer(uint264)", // 256 を超える
        "transfer(bytes33)", // 32 を超える
        "transfer(function)", // 未対応の型
        "transfer(uint256)extra", // 余分な文字
        "transfer(address[)", // 配列の書式が不正
        "transfer", // 引数リストが無い
        "transfer(address))", // 閉じ括弧が余分
    };
    for (bad) |text| {
        try testing.expectError(error.InvalidEncoding, parseFragment(allocator, text));
    }
}
