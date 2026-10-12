//! EIP-712 型付きデータ（typed data）のハッシュ計算と署名。
//!
//! 参考: https://eips.ethereum.org/EIPS/eip-712
//!
//! **実装上の要点**
//! - `encodeType` は「主型の定義 + 参照される構造体型を名前順に並べたもの」。参照関係は
//!   推移的に集める（順序を間違えるとハッシュが変わるため、テストで固定する）
//! - 数値は JSON の数値表記に依存しないよう、`parse_numbers = false` で文字列として読み、
//!   十進文字列（および `0x` 付き十六進）として解釈する。uint256 の範囲外はエラーにする
//! - ドメインの型（`EIP712Domain`）が `types` に無い場合は、標準の並び
//!   （name / version / chainId / verifyingContract / salt）で推論する
//!
//! テストは独立実装（eth-account 0.13.7）で計算した値との一致を確認している。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

const Keccak256 = hashes.Keccak256;

/// 型のフィールド定義。
pub const Field = struct {
    name: []const u8,
    type_name: []const u8,
};

/// 署名結果。
pub const SignedTypedData = struct {
    signing_hash: [32]u8,
    /// `r || s`（ビッグエンディアン）。
    compact: [64]u8,
    /// 0 または 1（Ethereum の `yParity`）。
    recovery_id: u8,

    pub fn r(self: SignedTypedData) u256 {
        return std.mem.readInt(u256, self.compact[0..32], .big);
    }

    pub fn s(self: SignedTypedData) u256 {
        return std.mem.readInt(u256, self.compact[32..64], .big);
    }
};

/// 型付きデータ（JSON）。
pub const TypedData = struct {
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    /// JSON 文字列を解析する。数値は文字列として保持する（uint256 を正確に扱うため）。
    pub fn parse(allocator: std.mem.Allocator, json: []const u8) Error!TypedData {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json,
            .{ .parse_numbers = false },
        ) catch return error.InvalidEncoding;
        if (parsed.value != .object) return error.InvalidEncoding;
        return .{ .parsed = parsed, .allocator = allocator };
    }

    pub fn deinit(self: *TypedData) void {
        self.parsed.deinit();
    }

    fn typesMap(self: TypedData) Error!std.json.ObjectMap {
        const types = self.parsed.value.object.get("types") orelse return error.InvalidEncoding;
        if (types != .object) return error.InvalidEncoding;
        return types.object;
    }

    fn primaryType(self: TypedData) Error![]const u8 {
        const value = self.parsed.value.object.get("primaryType") orelse return error.InvalidEncoding;
        if (value != .string) return error.InvalidEncoding;
        return value.string;
    }

    // ------------------------------------------------------------ 型の定義

    /// 型のフィールド一覧。`EIP712Domain` が types に無い場合はドメインから推論する。
    pub fn fieldsOf(self: TypedData, type_name: []const u8) Error![]Field {
        const types = try self.typesMap();
        if (types.get(type_name)) |entry| {
            if (entry != .array) return error.InvalidEncoding;
            const out = try self.allocator.alloc(Field, entry.array.items.len);
            for (entry.array.items, 0..) |item, i| {
                if (item != .object) return error.InvalidEncoding;
                const name_value = item.object.get("name") orelse return error.InvalidEncoding;
                const type_value = item.object.get("type") orelse return error.InvalidEncoding;
                if (name_value != .string or type_value != .string) return error.InvalidEncoding;
                out[i] = .{ .name = name_value.string, .type_name = type_value.string };
            }
            return out;
        }
        if (std.mem.eql(u8, type_name, "EIP712Domain")) return self.inferDomainFields();
        return error.InvalidEncoding;
    }

    /// ドメインの型が与えられていない場合に、標準の並びでフィールドを推論する。
    fn inferDomainFields(self: TypedData) Error![]Field {
        const domain = self.parsed.value.object.get("domain") orelse return error.InvalidEncoding;
        if (domain != .object) return error.InvalidEncoding;

        const candidates = [_]Field{
            .{ .name = "name", .type_name = "string" },
            .{ .name = "version", .type_name = "string" },
            .{ .name = "chainId", .type_name = "uint256" },
            .{ .name = "verifyingContract", .type_name = "address" },
            .{ .name = "salt", .type_name = "bytes32" },
        };

        var count: usize = 0;
        for (candidates) |candidate| {
            if (domain.object.get(candidate.name) != null) count += 1;
        }
        if (count == 0) return error.InvalidEncoding;

        const out = try self.allocator.alloc(Field, count);
        var i: usize = 0;
        for (candidates) |candidate| {
            if (domain.object.get(candidate.name) != null) {
                out[i] = candidate;
                i += 1;
            }
        }
        return out;
    }

    /// 構造体型かどうか（原子型・配列の基底型ではない）。
    fn isStructType(self: TypedData, name: []const u8) bool {
        const types = self.typesMap() catch return false;
        return types.get(name) != null;
    }

    /// 配列の基底型を取り出す（`Person[]` → `Person`、`uint256[2]` → `uint256`）。
    pub fn baseType(name: []const u8) []const u8 {
        if (!std.mem.endsWith(u8, name, "]")) return name;
        const bracket = std.mem.lastIndexOfScalar(u8, name, '[') orelse return name;
        return name[0..bracket];
    }

    /// `encodeType`（主型 + 参照型を名前順に連結した文字列）。
    pub fn encodeType(self: TypedData, type_name: []const u8) Error![]u8 {
        var dependencies = std.ArrayList([]const u8).empty;
        defer dependencies.deinit(self.allocator);
        try self.collectDependencies(type_name, &dependencies);

        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        try self.appendTypeDefinition(&out, type_name);

        std.mem.sort([]const u8, dependencies.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (dependencies.items) |dependency| {
            try self.appendTypeDefinition(&out, dependency);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn collectDependencies(
        self: TypedData,
        type_name: []const u8,
        out: *std.ArrayList([]const u8),
    ) Error!void {
        const fields = try self.fieldsOf(type_name);
        for (fields) |field| {
            const base = baseType(field.type_name);
            if (!self.isStructType(base)) continue;
            if (std.mem.eql(u8, base, type_name)) continue;

            var seen = false;
            for (out.items) |existing| {
                if (std.mem.eql(u8, existing, base)) seen = true;
            }
            if (seen) continue;

            try out.append(self.allocator, base);
            try self.collectDependencies(base, out);
        }
    }

    fn appendTypeDefinition(
        self: TypedData,
        out: *std.ArrayList(u8),
        type_name: []const u8,
    ) Error!void {
        const fields = try self.fieldsOf(type_name);
        try out.appendSlice(self.allocator, type_name);
        try out.append(self.allocator, '(');
        for (fields, 0..) |field, i| {
            if (i != 0) try out.append(self.allocator, ',');
            try out.appendSlice(self.allocator, field.type_name);
            try out.append(self.allocator, ' ');
            try out.appendSlice(self.allocator, field.name);
        }
        try out.append(self.allocator, ')');
    }

    /// `typeHash = keccak256(encodeType(typeOf(s)))`
    pub fn typeHash(self: TypedData, type_name: []const u8) Error![32]u8 {
        const encoded = try self.encodeType(type_name);
        var digest: [32]u8 = undefined;
        Keccak256.hash(encoded, &digest, .{});
        return digest;
    }

    // ------------------------------------------------------------ エンコード

    /// `hashStruct(s) = keccak256(typeHash ‖ encodeData(s))`
    pub fn structHash(
        self: TypedData,
        type_name: []const u8,
        value: std.json.Value,
        out: *[32]u8,
    ) Error!void {
        const type_hash = try self.typeHash(type_name);

        var encoded = std.ArrayList(u8).empty;
        defer encoded.deinit(self.allocator);
        try self.encodeData(type_name, value, &encoded);

        const buffer = try self.allocator.alloc(u8, 32 + encoded.items.len);
        @memcpy(buffer[0..32], &type_hash);
        @memcpy(buffer[32..], encoded.items);
        Keccak256.hash(buffer, out, .{});
    }

    fn encodeData(
        self: TypedData,
        type_name: []const u8,
        value: std.json.Value,
        out: *std.ArrayList(u8),
    ) Error!void {
        if (value != .object) return error.InvalidEncoding;
        const fields = try self.fieldsOf(type_name);
        for (fields) |field| {
            const field_value = value.object.get(field.name) orelse return error.InvalidEncoding;
            try self.encodeField(field.type_name, field_value, out);
        }
    }

    fn encodeField(
        self: TypedData,
        type_name: []const u8,
        value: std.json.Value,
        out: *std.ArrayList(u8),
    ) Error!void {
        // 配列（固定長・動的のどちらも「要素を並べたものを keccak256 する」）
        //
        // EIP-712 §Definition of encodeData:
        //   "The array values are encoded as the keccak256 hash of the concatenated
        //    encodeData of their contents (i.e. the encoding of SomeType[5] is identical
        //    to that of a struct containing five members of type SomeType)."
        // 固定長でもハッシュする点に注意（ABI エンコードとは異なる）。
        if (std.mem.endsWith(u8, type_name, "]")) {
            const bracket = std.mem.lastIndexOfScalar(u8, type_name, '[') orelse {
                return error.InvalidEncoding;
            };
            const base = type_name[0..bracket];
            const suffix = type_name[bracket + 1 .. type_name.len - 1];
            if (value != .array) return error.InvalidEncoding;

            if (suffix.len != 0) {
                const expected = std.fmt.parseInt(usize, suffix, 10) catch {
                    return error.InvalidEncoding;
                };
                if (value.array.items.len != expected) return error.InvalidEncoding;
            }

            var buffer = std.ArrayList(u8).empty;
            defer buffer.deinit(self.allocator);
            for (value.array.items) |item| {
                try self.encodeField(base, item, &buffer);
            }
            var digest: [32]u8 = undefined;
            Keccak256.hash(buffer.items, &digest, .{});
            try out.appendSlice(self.allocator, &digest);
            return;
        }

        // 構造体（再帰）
        if (self.isStructType(type_name)) {
            var digest: [32]u8 = undefined;
            try self.structHash(type_name, value, &digest);
            try out.appendSlice(self.allocator, &digest);
            return;
        }

        // 原子型
        var word: [32]u8 = @splat(0);
        if (std.mem.eql(u8, type_name, "string")) {
            if (value != .string) return error.InvalidEncoding;
            Keccak256.hash(value.string, &word, .{});
        } else if (std.mem.eql(u8, type_name, "bytes")) {
            const raw = try self.decodeHex(value);
            Keccak256.hash(raw, &word, .{});
        } else if (std.mem.startsWith(u8, type_name, "bytes")) {
            const size = std.fmt.parseInt(usize, type_name[5..], 10) catch {
                return error.InvalidEncoding;
            };
            if (size == 0 or size > 32) return error.InvalidEncoding;
            const raw = try self.decodeHex(value);
            if (raw.len != size) return error.InvalidEncoding;
            @memcpy(word[0..size], raw); // bytesN は左寄せ（右をゼロ埋め）
        } else if (std.mem.eql(u8, type_name, "address")) {
            const raw = try self.decodeHex(value);
            if (raw.len != 20) return error.InvalidEncoding;
            @memcpy(word[12..32], raw); // 左をゼロ埋め
        } else if (std.mem.eql(u8, type_name, "bool")) {
            if (value != .bool) return error.InvalidEncoding;
            word[31] = if (value.bool) 1 else 0;
        } else if (std.mem.startsWith(u8, type_name, "uint")) {
            std.mem.writeInt(u256, &word, try self.toU256(value), .big);
        } else if (std.mem.startsWith(u8, type_name, "int")) {
            const text = try self.numberText(value);
            if (text.len > 0 and text[0] == '-') {
                // 負数は 2 の補数
                const magnitude = std.fmt.parseInt(u256, text[1..], 10) catch {
                    return error.InvalidEncoding;
                };
                std.mem.writeInt(u256, &word, 0 -% magnitude, .big);
            } else {
                std.mem.writeInt(u256, &word, try self.toU256(value), .big);
            }
        } else {
            return error.InvalidEncoding;
        }
        try out.appendSlice(self.allocator, &word);
    }

    fn numberText(self: TypedData, value: std.json.Value) Error![]const u8 {
        return switch (value) {
            .number_string => |text| text,
            .string => |text| text,
            .integer => |number| try std.fmt.allocPrint(self.allocator, "{d}", .{number}),
            else => error.InvalidEncoding,
        };
    }

    fn toU256(self: TypedData, value: std.json.Value) Error!u256 {
        const text = try self.numberText(value);
        if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
            const hex = text[2..];
            if (hex.len == 0 or hex.len > 64 or hex.len % 2 != 0) return error.InvalidEncoding;
            var bytes: [32]u8 = @splat(0);
            const target = bytes[32 - hex.len / 2 ..];
            _ = std.fmt.hexToBytes(target, hex) catch return error.InvalidEncoding;
            return std.mem.readInt(u256, &bytes, .big);
        }
        return std.fmt.parseInt(u256, text, 10) catch return error.InvalidEncoding;
    }

    fn decodeHex(self: TypedData, value: std.json.Value) Error![]u8 {
        if (value != .string) return error.InvalidEncoding;
        var text = value.string;
        if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
            text = text[2..];
        }
        if (text.len % 2 != 0) return error.InvalidEncoding;
        const out = try self.allocator.alloc(u8, text.len / 2);
        _ = std.fmt.hexToBytes(out, text) catch return error.InvalidEncoding;
        return out;
    }

    // ------------------------------------------------------------ ハッシュ

    /// `domainSeparator = hashStruct(eip712Domain)`
    pub fn domainSeparator(self: TypedData, out: *[32]u8) Error!void {
        const domain = self.parsed.value.object.get("domain") orelse return error.InvalidEncoding;
        try self.structHash("EIP712Domain", domain, out);
    }

    /// 署名対象: `keccak256("\x19\x01" ‖ domainSeparator ‖ hashStruct(message))`
    pub fn signingHash(self: TypedData, out: *[32]u8) Error!void {
        var separator: [32]u8 = undefined;
        try self.domainSeparator(&separator);

        const message = self.parsed.value.object.get("message") orelse {
            return error.InvalidEncoding;
        };
        var body: [32]u8 = undefined;
        try self.structHash(try self.primaryType(), message, &body);

        var buffer: [66]u8 = undefined;
        buffer[0] = 0x19;
        buffer[1] = 0x01;
        @memcpy(buffer[2..34], &separator);
        @memcpy(buffer[34..66], &body);
        Keccak256.hash(&buffer, out, .{});
    }

    /// 型付きデータに署名する（署名したら必ず検証する）。
    pub fn signTypedData(self: TypedData, priv: [32]u8) Error!SignedTypedData {
        var hash: [32]u8 = undefined;
        try self.signingHash(&hash);

        const result = try secp256k1.signRecoverable(hash, priv);
        const parsed = try secp256k1.parseCompact(result.compact);
        if (!try secp256k1.verify(&parsed, hash, try secp256k1.pubKeyCompressed(priv))) {
            return error.SignatureInvalid;
        }
        return .{
            .signing_hash = hash,
            .compact = result.compact,
            .recovery_id = result.recovery_id,
        };
    }
};

// ---------------------------------------------------------------- テスト
//
// 期待値は独立実装（eth-account 0.13.7）で計算した。仕様書の Mail の例については
// EIP-712 の仕様に掲載されている既知の値（f2cee375… / c52c0ee5… / be609aee…）と一致する。

const testing = std.testing;

fn hexToFixed(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

const mail_example =
    \\{
    \\  "types": {
    \\    "EIP712Domain": [
    \\      {"name":"name","type":"string"},{"name":"version","type":"string"},
    \\      {"name":"chainId","type":"uint256"},{"name":"verifyingContract","type":"address"}],
    \\    "Person": [{"name":"name","type":"string"},{"name":"wallet","type":"address"}],
    \\    "Mail": [{"name":"from","type":"Person"},{"name":"to","type":"Person"},{"name":"contents","type":"string"}]
    \\  },
    \\  "primaryType": "Mail",
    \\  "domain": {"name":"Ether Mail","version":"1","chainId":1,
    \\             "verifyingContract":"0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"},
    \\  "message": {
    \\    "from": {"name":"Cow","wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
    \\    "to": {"name":"Bob","wallet":"0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
    \\    "contents": "Hello, Bob!"
    \\  }
    \\}
;

test "EIP-712 仕様書の Mail の例（ドメイン分離・構造体ハッシュ・署名対象）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = try TypedData.parse(allocator, mail_example);

    // encodeType は「主型 + 参照型を名前順」
    const encoded = try data.encodeType("Mail");
    try testing.expectEqualStrings(
        "Mail(Person from,Person to,string contents)Person(string name,address wallet)",
        encoded,
    );

    var separator: [32]u8 = undefined;
    try data.domainSeparator(&separator);
    const expected_separator = hexToFixed(
        32,
        "f2cee375fa42b42143804025fc449deafd50cc031ca257e0b194a650a912090f",
    );
    try testing.expectEqualSlices(u8, &expected_separator, &separator);

    const message = data.parsed.value.object.get("message").?;
    var body: [32]u8 = undefined;
    try data.structHash("Mail", message, &body);
    const expected_body = hexToFixed(
        32,
        "c52c0ee5d84264471806290a3f2c4cecfc5490626bf912d01f240d7a274b371e",
    );
    try testing.expectEqualSlices(u8, &expected_body, &body);

    var signing: [32]u8 = undefined;
    try data.signingHash(&signing);
    const expected_signing = hexToFixed(
        32,
        "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2",
    );
    try testing.expectEqualSlices(u8, &expected_signing, &signing);
    data.deinit();
}

test "EIP-712 動的配列・bytes・bytes32・string" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "types": {
        \\    "EIP712Domain": [{"name":"name","type":"string"},{"name":"chainId","type":"uint256"}],
        \\    "Batch": [
        \\      {"name":"amounts","type":"uint256[]"},
        \\      {"name":"recipients","type":"address[]"},
        \\      {"name":"memo","type":"bytes"},
        \\      {"name":"ref","type":"bytes32"},
        \\      {"name":"note","type":"string"}]
        \\  },
        \\  "primaryType": "Batch",
        \\  "domain": {"name":"zhww test","chainId":1},
        \\  "message": {
        \\    "amounts": [1, 2, 3],
        \\    "recipients": ["0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826",
        \\                   "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"],
        \\    "memo": "0xdeadbeef",
        \\    "ref": "0x1111111111111111111111111111111111111111111111111111111111111111",
        \\    "note": "hello"
        \\  }
        \\}
    ;

    var data = try TypedData.parse(allocator, json);
    var signing: [32]u8 = undefined;
    try data.signingHash(&signing);
    const expected = hexToFixed(
        32,
        "80a058bbc32e172259fbcc75925525a2dd82172b12446b0f137560c36240f2a2",
    );
    try testing.expectEqualSlices(u8, &expected, &signing);
    data.deinit();
}

test "EIP-712 入れ子の構造体・固定長配列・bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "types": {
        \\    "EIP712Domain": [{"name":"verifyingContract","type":"address"}],
        \\    "Order": [
        \\      {"name":"maker","type":"Person"},
        \\      {"name":"prices","type":"uint256[2]"},
        \\      {"name":"active","type":"bool"},
        \\      {"name":"salt","type":"uint256"}],
        \\    "Person": [{"name":"wallet","type":"address"}]
        \\  },
        \\  "primaryType": "Order",
        \\  "domain": {"verifyingContract":"0x0000000000000000000000000000000000000001"},
        \\  "message": {
        \\    "maker": {"wallet":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
        \\    "prices": ["1000000000000000000", "2500000000"],
        \\    "active": true,
        \\    "salt": 42
        \\  }
        \\}
    ;

    var data = try TypedData.parse(allocator, json);
    var signing: [32]u8 = undefined;
    try data.signingHash(&signing);
    const expected = hexToFixed(
        32,
        "7c3747bb80ec1c0caf702665766bd45d8ff37b6b95e9a7ff05744bfce3eaa067",
    );
    try testing.expectEqualSlices(u8, &expected, &signing);
    data.deinit();
}

test "EIP-712 依存する型が複数ある場合は名前順に連結する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "types": {
        \\    "EIP712Domain": [{"name":"name","type":"string"}],
        \\    "Top": [{"name":"z","type":"Zeta"},{"name":"a","type":"Alpha"}],
        \\    "Zeta": [{"name":"value","type":"uint256"}],
        \\    "Alpha": [{"name":"label","type":"string"}]
        \\  },
        \\  "primaryType": "Top",
        \\  "domain": {"name":"sort test"},
        \\  "message": {"z": {"value": 7}, "a": {"label": "x"}}
        \\}
    ;

    var data = try TypedData.parse(allocator, json);
    try testing.expectEqualStrings(
        "Top(Zeta z,Alpha a)Alpha(string label)Zeta(uint256 value)",
        try data.encodeType("Top"),
    );

    var signing: [32]u8 = undefined;
    try data.signingHash(&signing);
    const expected = hexToFixed(
        32,
        "823711c338ddea1384a4d54b0b0e18a0e57927ced811579fd866d9b1c1a04047",
    );
    try testing.expectEqualSlices(u8, &expected, &signing);
    data.deinit();
}

test "EIP-712 ドメインの型が無い場合は標準の並びで推論する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "types": {
        \\    "Simple": [{"name":"value","type":"uint256"},{"name":"who","type":"address"}]
        \\  },
        \\  "primaryType": "Simple",
        \\  "domain": {"name":"zhww","version":"1","chainId":1,
        \\             "verifyingContract":"0x0000000000000000000000000000000000000001"},
        \\  "message": {"value": 12345, "who":"0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"}
        \\}
    ;

    var data = try TypedData.parse(allocator, json);

    var separator: [32]u8 = undefined;
    try data.domainSeparator(&separator);
    const expected_separator = hexToFixed(
        32,
        "fd69ecb482009f071034fc861a964316b16d7765680d3e59a4b22e26d65b1bcd",
    );
    try testing.expectEqualSlices(u8, &expected_separator, &separator);

    var signing: [32]u8 = undefined;
    try data.signingHash(&signing);
    const expected = hexToFixed(
        32,
        "4c68f3c8a7aeaa20e1d920cadd8cdb26decf82c73f36c8a688019697bf14f529",
    );
    try testing.expectEqualSlices(u8, &expected, &signing);
    data.deinit();
}

test "EIP-712 の署名が独立実装（eth-account）と一致する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var data = try TypedData.parse(allocator, mail_example);

    const priv = hexToFixed(32, "4646464646464646464646464646464646464646464646464646464646464646");
    const signed = try data.signTypedData(priv);

    // eth-account が同じ鍵・同じハッシュに対して生成した署名と一致する
    const expected_compact = hexToFixed(
        64,
        "5318aee9942b84885761bb20e768372b76e7ee454fc4d39b59ce07338d15a06c" ++
            "5e585a2f4882ec3228a9303244798b47a9102e4be72f48159d890c73e4511d79",
    );
    try testing.expectEqualSlices(u8, &expected_compact, &signed.compact);
    try testing.expectEqual(@as(u8, 0), signed.recovery_id); // v = 27 → recovery id 0
    data.deinit();
}

test "EIP-712 異常系を拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 不正な JSON
    try testing.expectError(error.InvalidEncoding, TypedData.parse(allocator, "not json"));

    // primaryType が types に無い
    const missing_type =
        \\{"types":{"A":[{"name":"x","type":"uint256"}]},"primaryType":"B",
        \\ "domain":{"name":"x"},"message":{"x":1}}
    ;
    var data = try TypedData.parse(allocator, missing_type);
    var out: [32]u8 = undefined;
    try testing.expectError(error.InvalidEncoding, data.signingHash(&out));
    data.deinit();

    // 構造体のフィールドが欠けている
    const missing_field =
        \\{"types":{"A":[{"name":"x","type":"uint256"},{"name":"y","type":"uint256"}]},
        \\ "primaryType":"A","domain":{"name":"x"},"message":{"x":1}}
    ;
    var data2 = try TypedData.parse(allocator, missing_field);
    try testing.expectError(error.InvalidEncoding, data2.signingHash(&out));
    data2.deinit();

    // uint256 の範囲を超える値
    const too_large =
        \\{"types":{"A":[{"name":"x","type":"uint256"}]},
        \\ "primaryType":"A","domain":{"name":"x"},
        \\ "message":{"x":115792089237316195423570985008687907853269984665640564039457584007913129639936}}
    ;
    var data3 = try TypedData.parse(allocator, too_large);
    try testing.expectError(error.InvalidEncoding, data3.signingHash(&out));
    data3.deinit();

    // bytes32 の長さが違う
    const wrong_bytes =
        \\{"types":{"A":[{"name":"x","type":"bytes32"}]},
        \\ "primaryType":"A","domain":{"name":"x"},"message":{"x":"0x1234"}}
    ;
    var data4 = try TypedData.parse(allocator, wrong_bytes);
    try testing.expectError(error.InvalidEncoding, data4.signingHash(&out));
    data4.deinit();
}
