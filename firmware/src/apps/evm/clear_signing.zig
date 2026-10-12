//! ERC-7730 の記述子（clear signing の表示定義）の解析と、人間可読な表示項目の生成。
//!
//! 参考: https://eips.ethereum.org/EIPS/eip-7730
//!       https://github.com/ethereum/clear-signing-erc7730-registry
//!
//! **設計方針（推測で表示しない）**
//! - 記述子は `context.contract.deployments` の **chainId と address が両方一致**したときだけ使う。
//!   デプロイ情報を持たない記述子（`ercs/` の汎用テンプレートなど）は、セレクタが一致しても
//!   **使わない**（任意のコントラクトに汎用の意味づけを与えないため）。
//! - 一致しない呼び出しは内容を推測せず、「未知のコントラクト」として警告し、
//!   calldata の Keccak-256 ハッシュだけを提示する。
//! - 値が不明なとき・表示形式が未対応のときは、**生の値に理由を添えて** `warning = true` に
//!   する（例: `1000 (トークン情報が不明)`）。値を捏造しない。
//! - 危険な操作（無制限の `approve`、`setApprovalForAll`、`permit`）の警告は記述子に依存せず
//!   calldata から直接判定する（記述子が無くても警告できる）。警告項目は一覧の先頭に置く。
//!
//! **未対応（その旨を警告する）**
//! - `includes` による他の記述子の取り込み（レジストリ利用側での解決が必要）
//! - tuple（構造体）のフィールド、`calldata`（入れ子の呼び出し）、`nftName`、`unit`、
//!   `interoperableAddressName` の表示形式
//! - `interpolatedIntent`、`path` の `[]`・添字・スライス以外の記法、`params` の配列添字対応、
//!   `encryption`、`visible` の複合ルール、`$.` パス内の配列添字
//! - `render` が受け取るコンテナは `to` と `chainId` のみ（`from` / `value` を使う記述子は
//!   「不明」として警告する。完全なコンテナが必要なら `renderTransaction` を使う）
//! - 名前解決（ENS など）は行わない。`addressName` は仕様どおり ERC-55 表記にフォールバックする
//!
//! テストではレジストリの実記述子（stETH / Ekubo Ve33 / ERC-20 汎用テンプレート）を
//! そのまま埋め込んで検証する。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const abi = @import("abi.zig");
const evm_address = @import("address.zig");

/// 表示項目。`label` は項目名、`value` は整形済みの値。
pub const DisplayItem = struct {
    label: []const u8,
    value: []const u8,
    /// 不明・危険・未対応など、利用者に注意を促す項目。
    warning: bool,
};

/// トークンの表示に使うメタデータ（コントラクトから取得したもの、または既知の一覧）。
pub const TokenMetadata = struct {
    address: [20]u8,
    ticker: []const u8,
    decimals: u8,
};

/// 記述子が対象とするコントラクトのデプロイ先。
pub const Deployment = struct {
    chain_id: u64,
    address: [20]u8,
};

/// トランザクションのコンテナ（ERC-7730 の `@.` が指す値）。
pub const Container = struct {
    chain_id: u64,
    to: [20]u8,
    /// 送信元（`@.from`）。不明なら null。
    from: ?[20]u8 = null,
    /// ネイティブ通貨の値（`@.value`）。不明なら null。
    value: ?u256 = null,
};

/// 記述子のフィールド（表示項目の定義）。
///
/// `$ref`（`display.definitions` への参照）は解析時に解決し、ローカルの指定で上書きする。
pub const Field = struct {
    /// デコード済みの引数を指すパス。
    path: ?[]const u8,
    /// 記述子内の定数を指すパス、またはリテラル。
    value: ?[]const u8,
    label: ?[]const u8,
    format: ?[]const u8,
    params: ?std.json.Value,
    /// `visible` の生の値（文字列、または複合ルールのオブジェクト）。
    visible: ?std.json.Value,

    fn labelText(self: Field) []const u8 {
        return self.label orelse self.path orelse self.value orelse "項目";
    }
};

/// 1 つの関数（`display.formats` の 1 エントリ）。
pub const Format = struct {
    /// `display.formats` のキー（例 `transfer(address _recipient, uint256 _amount)`）。
    key: []const u8,
    /// 型のみの正準シグネチャ（例 `transfer(address,uint256)`）。
    signature: []const u8,
    selector: [4]u8,
    intent: []const u8,
    fields: []const Field,
    /// 引数の型。tuple を含む場合は null（デコード不可）。
    types: ?[]const abi.AbiType,
    /// トップレベルの引数名。名前が無い引数は空文字列。
    names: []const []const u8,
};

/// ERC-7730 記述子。
pub const Descriptor = struct {
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    /// JSON 文字列を解析する。数値は文字列として保持する（`uint256` を正確に扱うため）。
    pub fn parse(allocator: std.mem.Allocator, json: []const u8) Error!Descriptor {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            json,
            .{ .parse_numbers = false },
        ) catch return error.InvalidEncoding;
        if (parsed.value != .object) return error.InvalidEncoding;
        return .{ .parsed = parsed, .allocator = allocator };
    }

    pub fn deinit(self: *Descriptor) void {
        self.parsed.deinit();
    }

    /// `context.$id`（記述子の識別子）。
    pub fn contextId(self: Descriptor) ?[]const u8 {
        const context = self.parsed.value.object.get("context") orelse return null;
        if (context != .object) return null;
        return stringOf(context.object.get("$id"));
    }

    /// `metadata.owner`。
    pub fn owner(self: Descriptor) ?[]const u8 {
        return self.metadataString("owner");
    }

    /// `metadata.contractName`。
    pub fn contractName(self: Descriptor) ?[]const u8 {
        return self.metadataString("contractName");
    }

    /// `metadata.info.url`。
    pub fn infoUrl(self: Descriptor) ?[]const u8 {
        const metadata_object = self.metadata() orelse return null;
        const info = metadata_object.get("info") orelse return null;
        if (info != .object) return null;
        return stringOf(info.object.get("url"));
    }

    /// `context.contract.deployments`。無い場合は空。
    pub fn deployments(self: Descriptor) Error![]Deployment {
        const context = self.parsed.value.object.get("context") orelse return &.{};
        if (context != .object) return error.InvalidEncoding;
        const contract = context.object.get("contract") orelse return &.{};
        if (contract != .object) return error.InvalidEncoding;
        const list = contract.object.get("deployments") orelse return &.{};
        if (list != .array) return error.InvalidEncoding;

        const out = try self.allocator.alloc(Deployment, list.array.items.len);
        for (list.array.items, 0..) |item, i| {
            if (item != .object) return error.InvalidEncoding;
            const chain_id = jsonU64(item.object.get("chainId") orelse return error.InvalidEncoding) orelse
                return error.InvalidEncoding;
            const address = parseAddress(stringOf(item.object.get("address")) orelse
                return error.InvalidEncoding) orelse return error.InvalidEncoding;
            out[i] = .{ .chain_id = chain_id, .address = address };
        }
        return out;
    }

    /// `metadata.token`（記述子自身が持つ ERC-20 メタデータ）。
    pub fn ownToken(self: Descriptor) ?TokenInfo {
        const metadata_object = self.metadata() orelse return null;
        const token = metadata_object.get("token") orelse return null;
        if (token != .object) return null;
        const ticker = stringOf(token.object.get("ticker")) orelse return null;
        const decimals = jsonU64(token.object.get("decimals") orelse return null) orelse return null;
        if (decimals > 36) return null;
        return .{ .ticker = ticker, .decimals = @intCast(decimals) };
    }

    fn metadata(self: Descriptor) ?std.json.ObjectMap {
        const metadata_value = self.parsed.value.object.get("metadata") orelse return null;
        if (metadata_value != .object) return null;
        return metadata_value.object;
    }

    fn metadataString(self: Descriptor, key: []const u8) ?[]const u8 {
        const metadata_object = self.metadata() orelse return null;
        return stringOf(metadata_object.get(key));
    }

    /// `display.formats` のオブジェクト。無い場合（`includes` のみの記述子など）は null。
    fn formatsObject(self: Descriptor) ?std.json.ObjectMap {
        const display = self.parsed.value.object.get("display") orelse return null;
        if (display != .object) return null;
        const formats = display.object.get("formats") orelse return null;
        if (formats != .object) return null;
        return formats.object;
    }

    /// `$.` で始まる内部パスを解決する（オブジェクトのキーのみ。配列添字は未対応）。
    fn resolveInternalPath(self: Descriptor, path: []const u8) ?std.json.Value {
        var rest = path;
        if (std.mem.startsWith(u8, rest, "$.")) {
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "#.")) {
            rest = rest[2..];
        } else if (std.mem.eql(u8, rest, "$")) {
            return self.parsed.value;
        } else {
            return null;
        }
        var current = self.parsed.value;
        var tokens = std.mem.splitScalar(u8, rest, '.');
        while (tokens.next()) |token| {
            if (token.len == 0) return null;
            if (current != .object) return null;
            current = current.object.get(token) orelse return null;
        }
        return current;
    }
};

/// 記述子内のトークン情報。
pub const TokenInfo = struct {
    ticker: []const u8,
    decimals: u8,
};

// ---------------------------------------------------------------- 記述子の照合

/// 照合の結果。重複定義（不正な記述子）を「見つからない」と区別するために使う。
const Lookup = union(enum) {
    none,
    /// 同じセレクタの定義が複数ある（仕様上は不正な記述子）。
    duplicate,
    found: Format,
};

/// `chainId` とコントラクトアドレスの両方が一致し、かつセレクタが一致する表示定義を返す。
///
/// - デプロイ情報が無い記述子は対象外（`null`）。
/// - 同じセレクタの定義が複数ある記述子は不正として `null`。
///
/// 記述子のキーの解析結果は `descriptor` のアロケータに確保される。
pub fn findFormat(
    descriptor: Descriptor,
    chain_id: u64,
    to: [20]u8,
    selector: [4]u8,
) ?Format {
    return switch (lookupFormat(descriptor, chain_id, to, selector)) {
        .found => |format| format,
        else => null,
    };
}

fn lookupFormat(descriptor: Descriptor, chain_id: u64, to: [20]u8, selector: [4]u8) Lookup {
    // デプロイ情報が一致しない（または記述子が壊れている）場合は使わない。
    if (!(deploymentMatches(descriptor, chain_id, to) catch false)) return .none;

    const formats = descriptor.formatsObject() orelse return .none;
    var found: ?Format = null;
    var iterator = formats.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (value != .object) continue;

        const fragment = abi.parseFragment(descriptor.allocator, key) catch continue;
        const computed = abi.computeSelector(fragment.signature);
        if (!std.mem.eql(u8, &computed, &selector)) continue;
        // 同じセレクタの定義が複数ある記述子は不正（仕様: MUST treat as invalid）。
        if (found != null) return .duplicate;
        found = parseFormat(descriptor, key, value, fragment) catch continue;
    }
    if (found) |format| return .{ .found = format };
    return .none;
}

/// 記述子のデプロイ先に `chain_id` / `to` の組があるか。
///
/// **デプロイ情報が無い記述子は一致しない**（汎用テンプレートを任意のコントラクトに
/// 適用しないため）。
fn deploymentMatches(descriptor: Descriptor, chain_id: u64, to: [20]u8) Error!bool {
    const list = try descriptor.deployments();
    for (list) |deployment| {
        if (deployment.chain_id == chain_id and std.mem.eql(u8, &deployment.address, &to)) return true;
    }
    return false;
}

fn parseFormat(
    descriptor: Descriptor,
    key: []const u8,
    value: std.json.Value,
    fragment: abi.Fragment,
) Error!Format {
    const allocator = descriptor.allocator;
    const raw_intent = value.object.get("intent") orelse return error.InvalidEncoding;
    const intent = if (stringOf(raw_intent)) |text|
        text
    else
        // `intent` は「人間可読な文字列」または「ラベルと値の組」のどちらでもよい。
        try flattenIntent(allocator, raw_intent);

    return .{
        .key = key,
        .signature = fragment.signature,
        .selector = abi.computeSelector(fragment.signature),
        .intent = intent,
        .fields = try fieldsOf(descriptor, value),
        .types = fragment.types,
        .names = fragment.names,
    };
}

/// `intent` がオブジェクトの場合は「ラベル: 値」を並べた文字列にする（画面表示用）。
fn flattenIntent(allocator: std.mem.Allocator, intent: std.json.Value) Error![]const u8 {
    if (intent != .object) return error.InvalidEncoding;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var first = true;
    var iterator = intent.object.iterator();
    while (iterator.next()) |entry| {
        const text = stringOf(entry.value_ptr.*) orelse return error.InvalidEncoding;
        if (!first) try out.appendSlice(allocator, " / ");
        try out.appendSlice(allocator, entry.key_ptr.*);
        if (text.len != 0) {
            try out.appendSlice(allocator, ": ");
            try out.appendSlice(allocator, text);
        }
        first = false;
    }
    return out.toOwnedSlice(allocator);
}

/// `display.formats.<key>.fields` を解析する。`$ref` はここで解決する。
fn fieldsOf(descriptor: Descriptor, format: std.json.Value) Error![]Field {
    const fields = format.object.get("fields") orelse return &.{};
    if (fields != .array) return error.InvalidEncoding;

    const allocator = descriptor.allocator;
    const out = try allocator.alloc(Field, fields.array.items.len);
    for (fields.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidEncoding;

        // `$ref`（`$.display.definitions.X`）の定義。ローカルの指定が優先される。
        var definition: ?std.json.ObjectMap = null;
        if (item.object.get("$ref")) |reference| {
            if (reference != .string) return error.InvalidEncoding;
            const target = descriptor.resolveInternalPath(reference.string) orelse return error.InvalidEncoding;
            if (target != .object) return error.InvalidEncoding;
            definition = target.object;
        }

        out[i] = .{
            .path = pickString(item.object, definition, "path"),
            .value = pickString(item.object, definition, "value"),
            .label = pickString(item.object, definition, "label"),
            .format = pickString(item.object, definition, "format"),
            .params = pickValue(item.object, definition, "params"),
            .visible = pickValue(item.object, definition, "visible"),
        };
    }
    return out;
}

fn pickString(local: std.json.ObjectMap, definition: ?std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (local.get(key)) |value| return stringOf(value);
    if (definition) |def| return stringOf(def.get(key));
    return null;
}

fn pickValue(local: std.json.ObjectMap, definition: ?std.json.ObjectMap, key: []const u8) ?std.json.Value {
    if (local.get(key)) |value| return value;
    if (definition) |def| return def.get(key);
    return null;
}

// ---------------------------------------------------------------- 表示

/// 表示項目を生成する。
///
/// `token_metadata` は既知のトークン（コントラクトから取得した値など）。空でもよい。
/// `allocator` は `descriptor` と同じ `ArenaAllocator` を渡すのが素直（戻り値と内部の
/// スライスはすべてそこから確保される）。
pub fn render(
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    chain_id: u64,
    to: [20]u8,
    calldata: []const u8,
    token_metadata: []const TokenMetadata,
) Error![]DisplayItem {
    return renderTransaction(
        allocator,
        descriptor,
        .{ .chain_id = chain_id, .to = to },
        calldata,
        token_metadata,
    );
}

/// コンテナの情報を明示して表示項目を生成する（`from` / `value` を使う記述子向け）。
pub fn renderTransaction(
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    container: Container,
    calldata: []const u8,
    token_metadata: []const TokenMetadata,
) Error![]DisplayItem {
    var items = std.ArrayList(DisplayItem).empty;
    errdefer items.deinit(allocator);

    const selector = abi.selector(calldata) orelse {
        try items.append(allocator, .{
            .label = "calldata",
            .value = "関数呼び出しとして短すぎる（4 バイト未満）",
            .warning = true,
        });
        return items.toOwnedSlice(allocator);
    };

    // 記述子に依存しない危険操作の警告を先頭に置く。
    try appendRiskWarnings(allocator, &items, selector, calldata);

    switch (lookupFormat(descriptor, container.chain_id, container.to, selector)) {
        .none => {
            try items.append(allocator, .{
                .label = "宛先",
                .value = try checksumAddress(allocator, container.to),
                .warning = false,
            });
            try items.append(allocator, .{
                .label = "警告",
                .value = "未知のコントラクト（一致する ERC-7730 記述子が無い）。内容を表示できない",
                .warning = true,
            });
            try appendCalldataSummary(allocator, &items, calldata, selector);
        },
        .duplicate => {
            try items.append(allocator, .{
                .label = "警告",
                .value = "記述子が不正（同じセレクタの定義が重複）。内容を表示できない",
                .warning = true,
            });
            try appendCalldataSummary(allocator, &items, calldata, selector);
        },
        .found => |format| {
            try items.append(allocator, .{
                .label = "操作",
                .value = format.intent,
                .warning = false,
            });
            try renderFormat(allocator, descriptor, container, format, calldata, token_metadata, &items);
        },
    }

    return items.toOwnedSlice(allocator);
}

fn renderFormat(
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    container: Container,
    format: Format,
    calldata: []const u8,
    token_metadata: []const TokenMetadata,
    items: *std.ArrayList(DisplayItem),
) Error!void {
    const types = format.types orelse {
        try items.append(allocator, .{
            .label = "警告",
            .value = "記述子の引数に tuple（構造体）などの未対応の型があるため、引数を表示できない",
            .warning = true,
        });
        try appendCalldataSummary(allocator, items, calldata, format.selector);
        return;
    };

    const values = try allocator.alloc(abi.Value, types.len);
    abi.decodeParameters(allocator, types, calldata[abi.selector_len..], values) catch {
        try items.append(allocator, .{
            .label = "警告",
            .value = "calldata が ABI の正準形ではないため、引数を表示できない",
            .warning = true,
        });
        try appendCalldataSummary(allocator, items, calldata, format.selector);
        return;
    };

    const context = RenderContext{
        .allocator = allocator,
        .descriptor = descriptor,
        .container = container,
        .values = values,
        .names = format.names,
        .tokens = token_metadata,
    };

    for (format.fields) |field| {
        if (field.path == null and field.value == null) continue;

        const resolved = if (field.value) |constant|
            try resolveConstant(&context, constant)
        else
            try resolveFieldPath(&context, field.path.?);

        const visibility = checkVisibility(field);
        if (!visibility.show) {
            if (visibility.note) |note| {
                try items.append(allocator, .{
                    .label = field.labelText(),
                    .value = try withNote(allocator, "（非表示）", note),
                    .warning = true,
                });
            }
            continue;
        }

        switch (resolved) {
            .missing => |reason| {
                try items.append(allocator, .{
                    .label = field.labelText(),
                    .value = try std.fmt.allocPrint(allocator, "不明: {s}", .{reason}),
                    .warning = true,
                });
            },
            .value => |value| {
                const rendered = try formatField(&context, field, value);
                try items.append(allocator, .{
                    .label = field.labelText(),
                    .value = rendered.value,
                    .warning = rendered.warning,
                });
            },
            .text => |text| {
                const rendered = try formatField(&context, field, .{ .string = text });
                try items.append(allocator, .{
                    .label = field.labelText(),
                    .value = rendered.value,
                    .warning = rendered.warning,
                });
            },
        }
    }
}

/// セレクタと calldata のハッシュ（推測できないときの最後の拠り所）。
fn appendCalldataSummary(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    calldata: []const u8,
    selector: [4]u8,
) Error!void {
    var selector_hex: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&selector_hex, "{x}", .{&selector}) catch return error.BufferTooSmall;
    try items.append(allocator, .{
        .label = "関数セレクタ",
        .value = try std.fmt.allocPrint(allocator, "0x{s}", .{selector_hex}),
        .warning = true,
    });

    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(calldata, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try items.append(allocator, .{
        .label = "calldata ハッシュ",
        .value = try std.fmt.allocPrint(allocator, "0x{s}", .{&hex}),
        .warning = true,
    });
}

// ---------------------------------------------------------------- 危険操作の警告

/// 記述子に依存せず calldata から危険な操作を判定し、警告項目を追加する。
fn appendRiskWarnings(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    selector: [4]u8,
    calldata: []const u8,
) Error!void {
    const known = abi.knownFunction(selector) orelse return;

    // 引数のデコード（正準形でなければ警告できないので何もしない）。
    const values = try allocator.alloc(abi.Value, known.types.len);
    abi.decodeParameters(allocator, known.types, calldata[abi.selector_len..], values) catch return;

    if (std.mem.eql(u8, known.signature, "approve(address,uint256)")) {
        const spender = values[0].address;
        const amount = values[1].uint;
        if (amount == std.math.maxInt(u256)) {
            try items.append(allocator, .{
                .label = "警告",
                .value = try std.fmt.allocPrint(
                    allocator,
                    "無制限の承認（2^256-1）。{s} が残高をすべて移動できる",
                    .{try checksumAddress(allocator, spender)},
                ),
                .warning = true,
            });
        }
    } else if (std.mem.eql(u8, known.signature, "setApprovalForAll(address,bool)")) {
        const operator = values[0].address;
        const approved = values[1].boolean;
        try items.append(allocator, .{
            .label = "警告",
            .value = if (approved)
                try std.fmt.allocPrint(
                    allocator,
                    "すべてのトークンの操作権限を {s} に付与する",
                    .{try checksumAddress(allocator, operator)},
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "すべてのトークンの操作権限を {s} から剥奪する",
                    .{try checksumAddress(allocator, operator)},
                ),
            .warning = true,
        });
    } else if (std.mem.eql(u8, known.signature, "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)")) {
        const owner = values[0].address;
        const spender = values[1].address;
        try items.append(allocator, .{
            .label = "警告",
            .value = try std.fmt.allocPrint(
                allocator,
                "EIP-2612 permit: {s} が {s} の残高を（期限まで）移動できるようになる",
                .{ try checksumAddress(allocator, spender), try checksumAddress(allocator, owner) },
            ),
            .warning = true,
        });
    }
}

// ---------------------------------------------------------------- パスの解決

const RenderContext = struct {
    allocator: std.mem.Allocator,
    descriptor: Descriptor,
    container: Container,
    values: []const abi.Value,
    names: []const []const u8,
    tokens: []const TokenMetadata,

    fn lookupToken(self: *const RenderContext, address: [20]u8) ?TokenInfo {
        for (self.tokens) |token| {
            if (std.mem.eql(u8, &token.address, &address)) {
                return .{ .ticker = token.ticker, .decimals = token.decimals };
            }
        }
        // 記述子自身が `metadata.token` を持つ場合は、対象コントラクトのメタデータを使う。
        if (std.mem.eql(u8, &address, &self.container.to)) {
            if (self.descriptor.ownToken()) |own| return own;
        }
        return null;
    }
};

/// パスの解決結果。
const Resolved = union(enum) {
    /// calldata からデコードした値。
    value: abi.Value,
    /// 記述子内の定数（文字列・数値）。
    text: []const u8,
    /// 解決できない。文字列は理由（画面に「不明: 〜」として出す）。
    missing: []const u8,
};

/// フィールドのパスを解決する。
///
/// 対応する記法: `name` / `name[3]` / `name[-1]` / `name[0:20]` / `name.[]`、
/// `@.to` `@.from` `@.value` `@.chainId`、`$.metadata.constants.X`（オブジェクトのキーのみ）。
fn resolveFieldPath(context: *const RenderContext, path: []const u8) Error!Resolved {
    if (std.mem.startsWith(u8, path, "@.")) return resolveContainer(context, path[2..]);
    if (std.mem.startsWith(u8, path, "$")) return resolveConstant(context, path);

    var rest = path;
    if (std.mem.startsWith(u8, rest, "#.")) rest = rest[2..];

    // 先頭の引数名。
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    if (end == 0) return .{ .missing = "パスの記法が未対応" };
    const name = rest[0..end];

    var position: ?usize = null;
    for (context.names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) {
            position = i;
            break;
        }
    }
    const index = position orelse
        return .{ .missing = "記述子の引数名と一致しない（引数名の無い定義か未対応の型）" };

    var value = context.values[index];
    rest = rest[end..];
    while (rest.len != 0) {
        if (rest[0] != '[') return .{ .missing = "パスの記法が未対応" };
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return .{ .missing = "パスの記法が未対応" };
        const next = applySelector(value, rest[1..close]);
        value = switch (next) {
            .value => |resolved| resolved,
            else => return next,
        };
        rest = rest[close + 1 ..];
    }
    return .{ .value = value };
}

/// `[i]` / `[-i]` / `[a:b]` / `[]` を適用する。
///
/// 解決できない場合は「不明」を返す（記述子の書き間違いで画面全体を空にしないため）。
fn applySelector(value: abi.Value, selector_text: []const u8) Resolved {
    if (selector_text.len == 0) return .{ .value = value }; // `.[]` は配列全体

    if (std.mem.indexOfScalar(u8, selector_text, ':')) |colon| {
        const elements = switch (value) {
            .bytes => |bytes| bytes,
            .string => |bytes| bytes,
            else => return .{ .missing = "スライスは bytes / string のみ対応" },
        };
        const start = sliceIndex(elements.len, selector_text[0..colon], 0) orelse
            return .{ .missing = "スライスの開始位置が不正" };
        const end = sliceIndex(elements.len, selector_text[colon + 1 ..], elements.len) orelse
            return .{ .missing = "スライスの終了位置が不正" };
        if (start > end) return .{ .missing = "スライスの範囲が逆転している" };
        return .{ .value = .{ .bytes = elements[start..end] } };
    }

    const elements = switch (value) {
        .array => |items| items,
        .fixed_array => |items| items,
        else => return .{ .missing = "添字は配列のみ対応" },
    };
    const at = elementIndex(elements.len, selector_text) orelse
        return .{ .missing = "配列の添字が範囲外（記述子か calldata が不正）" };
    return .{ .value = elements[at] };
}

/// スライスの境界。`len` 自体を許す（終端は排他）。
fn sliceIndex(len: usize, text: []const u8, fallback: usize) ?usize {
    if (text.len == 0) return fallback;
    const raw = parseIndex(digitsOf(text)) orelse return null;
    if (text[0] == '-') {
        if (raw > len) return null;
        return len - raw;
    }
    if (raw > len) return null;
    return raw;
}

/// 配列の添字。`[-1]` は末尾からの位置。
fn elementIndex(len: usize, text: []const u8) ?usize {
    if (text.len == 0) return null;
    const raw = parseIndex(digitsOf(text)) orelse return null;
    if (text[0] == '-') {
        if (raw == 0 or raw > len) return null;
        return len - raw;
    }
    if (raw >= len) return null;
    return raw;
}

fn digitsOf(text: []const u8) []const u8 {
    return if (text.len != 0 and text[0] == '-') text[1..] else text;
}

fn parseIndex(digits: []const u8) ?usize {
    if (digits.len == 0) return null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}

/// `@.` のコンテナ値を解決する。
fn resolveContainer(context: *const RenderContext, name: []const u8) Error!Resolved {
    if (std.mem.eql(u8, name, "to")) return .{ .value = .{ .address = context.container.to } };
    if (std.mem.eql(u8, name, "chainId")) return .{ .value = .{ .uint = context.container.chain_id } };
    if (std.mem.eql(u8, name, "from")) {
        const from = context.container.from orelse
            return .{ .missing = "送信元（from）が取得できない" };
        return .{ .value = .{ .address = from } };
    }
    if (std.mem.eql(u8, name, "value")) {
        const value = context.container.value orelse
            return .{ .missing = "送信額（value）が取得できない" };
        return .{ .value = .{ .uint = value } };
    }
    return .{ .missing = "コンテナの未対応の値" };
}

/// `$` で始まる記述子内の定数を解決する。
fn resolveConstant(context: *const RenderContext, path: []const u8) Error!Resolved {
    // `$` で始まらなければリテラル（`value` は定数の直値でもよい）。
    if (!std.mem.startsWith(u8, path, "$")) return .{ .text = path };

    const target = context.descriptor.resolveInternalPath(path) orelse
        return .{ .missing = "記述子内の定数が見つからない" };
    switch (target) {
        .string => |text| return .{ .text = text },
        .number_string => |text| return .{ .text = text },
        .integer => |number| return .{ .text = try std.fmt.allocPrint(context.allocator, "{d}", .{number}) },
        .bool => |flag| return .{ .text = if (flag) "true" else "false" },
        else => return .{ .missing = "記述子内の定数の型が未対応（配列・オブジェクトなど）" },
    }
}

// ---------------------------------------------------------------- 表示条件

const Visibility = struct { show: bool, note: ?[]const u8 = null };

fn checkVisibility(field: Field) Visibility {
    const raw = field.visible orelse return .{ .show = true };
    if (raw != .string) {
        // `ifNotIn` / `mustMatch` などの複合ルールは未対応。安全側で非表示にする。
        return .{ .show = false, .note = "visible の複合ルールが未対応のため、この項目は表示しない" };
    }
    const rule = raw.string;
    if (std.mem.eql(u8, rule, "always")) return .{ .show = true };
    if (std.mem.eql(u8, rule, "never")) return .{ .show = false };
    if (std.mem.eql(u8, rule, "optional")) return .{ .show = true }; // 仕様上は表示してよい（MAY）
    return .{ .show = false, .note = "visible の値が未知のため、この項目は表示しない" };
}

// ---------------------------------------------------------------- 表示形式

const Rendered = struct {
    value: []const u8,
    warning: bool,
};

/// フィールドの値を表示形式に従って整形する。
fn formatField(context: *const RenderContext, field: Field, value: abi.Value) Error!Rendered {
    const allocator = context.allocator;

    // 配列は要素ごとに同じ書式で整形して連結する（`params` の添字対応は未対応）。
    if (value == .array or value == .fixed_array) {
        const elements = switch (value) {
            .array => |items| items,
            .fixed_array => |items| items,
            else => unreachable,
        };
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var warning = false;
        for (elements, 0..) |element, i| {
            if (i != 0) try out.appendSlice(allocator, ", ");
            if (paramText(field, "separator")) |separator| {
                try out.appendSlice(allocator, try separatorWithIndex(allocator, separator, i));
            }
            const rendered = try formatField(context, field, element);
            if (rendered.warning) warning = true;
            try out.appendSlice(allocator, rendered.value);
        }
        return .{ .value = try out.toOwnedSlice(allocator), .warning = warning };
    }

    const identifier = field.format orelse {
        // 表示形式の指定が無い場合は、生の値にその旨を添える（意味づけを推測しない）。
        return .{
            .value = try withNote(allocator, try rawText(allocator, value), "表示形式が未指定"),
            .warning = true,
        };
    };

    if (std.mem.eql(u8, identifier, "raw")) {
        if (value == .string and !std.unicode.utf8ValidateSlice(value.string)) {
            return .{
                .value = try withNote(allocator, try rawText(allocator, value), "UTF-8 として不正"),
                .warning = true,
            };
        }
        return .{ .value = try rawText(allocator, value), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "amount")) {
        const integer = uintOf(value) orelse return unsupportedValue(allocator, value, "整数ではない");
        if (try thresholdMessage(field, integer, "All")) |message| return message;
        const ticker = nativeTicker(context.container.chain_id) orelse {
            return .{
                .value = try withNote(allocator, try decimal(allocator, integer), "ネイティブ通貨が不明"),
                .warning = true,
            };
        };
        return .{
            .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{
                try formatUnits(allocator, integer, 18),
                ticker,
            }),
            .warning = false,
        };
    }

    if (std.mem.eql(u8, identifier, "tokenAmount")) {
        const integer = uintOf(value) orelse return unsupportedValue(allocator, value, "整数ではない");

        // `tokenPath` / `token`（定数）からトークンのアドレスを決める。
        var token: ?[20]u8 = null;
        if (paramText(field, "tokenPath")) |path| {
            switch (try resolveFieldPath(context, path)) {
                .value => |resolved| token = addressOf(resolved),
                .text => |text| token = parseAddress(text),
                .missing => {},
            }
        } else if (paramText(field, "token")) |text| {
            if (std.mem.startsWith(u8, text, "$") or std.mem.startsWith(u8, text, "@")) {
                switch (try resolveFieldPath(context, text)) {
                    .value => |resolved| token = addressOf(resolved),
                    .text => |resolved_text| token = parseAddress(resolved_text),
                    .missing => {},
                }
            } else {
                token = parseAddress(text);
            }
        }

        if (token) |address| {
            // ネイティブ通貨として扱う指定（`nativeCurrencyAddress`）。
            if (isNativeCurrency(field, address)) {
                const ticker = nativeTicker(context.container.chain_id) orelse {
                    return .{
                        .value = try withNote(allocator, try decimal(allocator, integer), "ネイティブ通貨が不明"),
                        .warning = true,
                    };
                };
                return .{
                    .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{
                        try formatUnits(allocator, integer, 18),
                        ticker,
                    }),
                    .warning = false,
                };
            }
            if (context.lookupToken(address)) |metadata| {
                if (metadata.decimals > 36) {
                    return .{
                        .value = try withNote(allocator, try decimal(allocator, integer), "トークンの decimals が不正"),
                        .warning = true,
                    };
                }
                if (try thresholdMessage(field, integer, "Unlimited")) |message| {
                    return .{
                        .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{ message.value, metadata.ticker }),
                        .warning = message.warning,
                    };
                }
                return .{
                    .value = try std.fmt.allocPrint(allocator, "{s} {s}", .{
                        try formatUnits(allocator, integer, metadata.decimals),
                        metadata.ticker,
                    }),
                    .warning = false,
                };
            }
        }

        return .{
            .value = try withNote(allocator, try decimal(allocator, integer), "トークン情報が不明"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "addressName")) {
        const address = addressOf(value) orelse return unsupportedValue(allocator, value, "アドレスではない");
        // 名前解決（ENS など）は端末内では行わないため、仕様どおり ERC-55 表記にする。
        if (addressListContains(field, "senderAddress", address)) {
            const from = context.container.from orelse {
                return .{
                    .value = try withNote(allocator, try checksumAddress(allocator, address), "送信元（from）が不明"),
                    .warning = true,
                };
            };
            return .{ .value = try checksumAddress(allocator, from), .warning = false };
        }
        return .{ .value = try checksumAddress(allocator, address), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "date")) {
        const seconds = uintOf(value) orelse return unsupportedValue(allocator, value, "整数ではない");
        const encoding = paramText(field, "encoding") orelse "timestamp";
        if (!std.mem.eql(u8, encoding, "timestamp")) {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "date の encoding が未対応"),
                .warning = true,
            };
        }
        if (seconds > std.math.maxInt(i64)) {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "日付の範囲外"),
                .warning = true,
            };
        }
        const text = formatDate(allocator, @intCast(seconds)) catch {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "日付の範囲外"),
                .warning = true,
            };
        };
        return .{ .value = text, .warning = false };
    }

    if (std.mem.eql(u8, identifier, "duration")) {
        const seconds = uintOf(value) orelse return unsupportedValue(allocator, value, "整数ではない");
        return .{ .value = try formatDuration(allocator, seconds), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "enum")) {
        const reference = paramText(field, "$ref") orelse
            return unsupportedValue(allocator, value, "enum の $ref が無い");
        const table = context.descriptor.resolveInternalPath(reference) orelse
            return unsupportedValue(allocator, value, "enum の定義が見つからない");
        if (table != .object) return unsupportedValue(allocator, value, "enum の定義が不正");
        if (try enumText(allocator, table.object, value)) |text| {
            return .{ .value = text, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try rawText(allocator, value), "enum の定義に無い値"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "chainId")) {
        const id = uintOf(value) orelse return unsupportedValue(allocator, value, "整数ではない");
        if (id <= std.math.maxInt(u64)) {
            if (chainName(@intCast(id))) |name| return .{ .value = name, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try decimal(allocator, id), "チェーン名が不明"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "tokenTicker")) {
        const address = addressOf(value) orelse return unsupportedValue(allocator, value, "アドレスではない");
        if (context.lookupToken(address)) |metadata| {
            return .{ .value = metadata.ticker, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try checksumAddress(allocator, address), "トークン情報が不明"),
            .warning = true,
        };
    }

    // `calldata`（入れ子の呼び出し）・`nftName`・`unit`・`interoperableAddressName` など。
    return .{
        .value = try withNote(allocator, try rawText(allocator, value), try std.fmt.allocPrint(
            allocator,
            "表示形式 \"{s}\" は未対応",
            .{identifier},
        )),
        .warning = true,
    };
}

/// 整数でない値に表示形式を適用しようとしたときの応答（生の値＋理由）。
fn unsupportedValue(allocator: std.mem.Allocator, value: abi.Value, reason: []const u8) Error!Rendered {
    return .{
        .value = try withNote(allocator, try rawText(allocator, value), reason),
        .warning = true,
    };
}

/// しきい値以上ならメッセージを返す（`threshold` / `message`）。
fn thresholdMessage(field: Field, value: u256, default_message: []const u8) Error!?Rendered {
    const threshold_text = paramText(field, "threshold") orelse return null;
    const threshold = parseU256(threshold_text) orelse return null;
    if (value < threshold) return null;
    const message = paramText(field, "message") orelse default_message;
    return .{ .value = message, .warning = false };
}

/// `metadata.enums.X` の対応表から表示文字列を引く。
fn enumText(
    allocator: std.mem.Allocator,
    table: std.json.ObjectMap,
    value: abi.Value,
) Error!?[]const u8 {
    var buffer: [80]u8 = undefined;
    var candidates: [2][]const u8 = undefined;
    var count: usize = 0;

    switch (value) {
        .boolean => |flag| {
            candidates[0] = if (flag) "true" else "false";
            candidates[1] = if (flag) "True" else "False";
            count = 2;
        },
        .uint => |number| {
            candidates[0] = std.fmt.bufPrint(&buffer, "{d}", .{number}) catch return error.BufferTooSmall;
            candidates[1] = try std.fmt.allocPrint(allocator, "0x{x}", .{number});
            count = 2;
        },
        else => return null,
    }

    for (candidates[0..count]) |candidate| {
        if (table.get(candidate)) |mapped| {
            if (stringOf(mapped)) |text| return text;
        }
    }
    return null;
}

// ---------------------------------------------------------------- 値の文字列化

/// 生の値を文字列にする（`uint` は十進、アドレスは ERC-55 表記、バイト列は 16 進）。
fn rawText(allocator: std.mem.Allocator, value: abi.Value) Error![]const u8 {
    return switch (value) {
        .uint => |number| try decimal(allocator, number),
        .int => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .address => |address| try checksumAddress(allocator, address),
        .boolean => |flag| if (flag) "true" else "false",
        .bytes => |bytes| try hexWithPrefix(allocator, bytes),
        .string => |text| text,
        .array, .fixed_array => |items| try std.fmt.allocPrint(allocator, "{d} 件の配列", .{items.len}),
    };
}

fn decimal(allocator: std.mem.Allocator, value: u256) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn hexWithPrefix(allocator: std.mem.Allocator, bytes: []const u8) Error![]const u8 {
    const digits = "0123456789abcdef";
    const out = try allocator.alloc(u8, 2 + bytes.len * 2);
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |byte, i| {
        out[2 + i * 2] = digits[byte >> 4];
        out[2 + i * 2 + 1] = digits[byte & 0x0F];
    }
    return out;
}

fn checksumAddress(allocator: std.mem.Allocator, address: [20]u8) Error![]const u8 {
    var buffer: [evm_address.checksummed_len]u8 = undefined;
    const text = try evm_address.checksum(&buffer, address);
    return allocator.dupe(u8, text);
}

fn withNote(allocator: std.mem.Allocator, text: []const u8, note: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ text, note });
}

/// 整数を `decimals` 桁の小数として表す（末尾の 0 は落とす）。
fn formatUnits(allocator: std.mem.Allocator, value: u256, decimals: u8) Error![]const u8 {
    if (decimals == 0) return decimal(allocator, value);
    if (decimals > 36) return error.InvalidEncoding;

    var scale: u256 = 1;
    var i: u8 = 0;
    while (i < decimals) : (i += 1) scale *= 10;

    const whole = value / scale;
    const fraction = value % scale;
    if (fraction == 0) return decimal(allocator, whole);

    var buffer: [40]u8 = undefined;
    const fraction_text = std.fmt.bufPrint(&buffer, "{d}", .{fraction}) catch return error.BufferTooSmall;
    const width: usize = decimals;
    if (fraction_text.len > width) return error.InvalidEncoding;

    var padded: [40]u8 = undefined;
    const zeros = width - fraction_text.len;
    for (0..zeros) |z| padded[z] = '0';
    @memcpy(padded[zeros..width], fraction_text);
    var end = width;
    while (end > 0 and padded[end - 1] == '0') end -= 1;
    return std.fmt.allocPrint(allocator, "{d}.{s}", .{ whole, padded[0..end] });
}

/// UNIX 時刻（秒）を RFC 3339 風の UTC 表記（`2024-02-29T07:27:12Z`）にする。
///
/// アルゴリズムは civil_from_days（Howard Hinnant）。うるう年もこの式で扱える。
fn formatDate(allocator: std.mem.Allocator, seconds: i64) Error![]const u8 {
    const days = @divFloor(seconds, 86_400);
    const remainder = seconds - days * 86_400;
    const hours = @divFloor(remainder, 3_600);
    const minutes = @divFloor(remainder - hours * 3_600, 60);
    const secs = remainder - hours * 3_600 - minutes * 60;

    const z = days + 719_468;
    const era = @divFloor(z, 146_097);
    const doe = z - era * 146_097; // [0, 146096]
    const yoe = @divFloor(doe - @divFloor(doe, 1_460) + @divFloor(doe, 36_524) - @divFloor(doe, 146_096), 365);
    var year = yoe + era * 400;
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = mp + (if (mp < 10) @as(i64, 3) else -9);
    if (month <= 2) year += 1;

    if (year < 0 or year > 9999) return error.InvalidEncoding;
    // 符号付きのまま整形すると "+2024" になるため、非負を確認してから符号なしにする。
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(year)),
        @as(u32, @intCast(month)),
        @as(u32, @intCast(day)),
        @as(u32, @intCast(hours)),
        @as(u32, @intCast(minutes)),
        @as(u32, @intCast(secs)),
    });
}

/// 秒数を `HH:MM:SS` にする（24 時間を超える時間もそのまま時として表す）。
fn formatDuration(allocator: std.mem.Allocator, seconds: u256) Error![]const u8 {
    const hours = seconds / 3_600;
    const minutes = (seconds % 3_600) / 60;
    const secs = seconds % 60;
    return std.fmt.allocPrint(allocator, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, minutes, secs });
}

fn separatorWithIndex(allocator: std.mem.Allocator, separator: []const u8, index: usize) Error![]const u8 {
    const placeholder = "{index}";
    if (std.mem.indexOf(u8, separator, placeholder)) |position| {
        return std.fmt.allocPrint(allocator, "{s}{d}{s}", .{
            separator[0..position],
            index,
            separator[position + placeholder.len ..],
        });
    }
    return separator;
}

// ---------------------------------------------------------------- パラメータ

fn paramValue(field: Field, name: []const u8) ?std.json.Value {
    const params = field.params orelse return null;
    if (params != .object) return null;
    return params.object.get(name);
}

fn paramText(field: Field, name: []const u8) ?[]const u8 {
    return stringOf(paramValue(field, name));
}

/// `nativeCurrencyAddress`（文字列または配列）にアドレスが含まれるか。
fn isNativeCurrency(field: Field, address: [20]u8) bool {
    return addressListContains(field, "nativeCurrencyAddress", address);
}

fn addressListContains(field: Field, name: []const u8, address: [20]u8) bool {
    const params = paramValue(field, name) orelse return false;
    switch (params) {
        .string => |text| {
            const candidate = parseAddress(text) orelse return false;
            return std.mem.eql(u8, &candidate, &address);
        },
        .array => |items| {
            for (items.items) |item| {
                const text = stringOf(item) orelse continue;
                const candidate = parseAddress(text) orelse continue;
                if (std.mem.eql(u8, &candidate, &address)) return true;
            }
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------- チェーン表
//
// 端末内に持てるのはごく一部のチェーンだけである。表に無いチェーンは推測せず
// 「不明」として警告する。

fn nativeTicker(chain_id: u64) ?[]const u8 {
    return switch (chain_id) {
        1, 10, 8453, 42161, 11155111, 17000, 31337 => "ETH",
        56 => "BNB",
        100 => "xDAI",
        137 => "POL",
        43114 => "AVAX",
        else => null,
    };
}

fn chainName(chain_id: u64) ?[]const u8 {
    return switch (chain_id) {
        1 => "Ethereum Mainnet",
        10 => "OP Mainnet",
        56 => "BNB Smart Chain",
        100 => "Gnosis",
        137 => "Polygon",
        8453 => "Base",
        42161 => "Arbitrum One",
        43114 => "Avalanche C-Chain",
        11155111 => "Sepolia",
        17000 => "Holesky",
        else => null,
    };
}

// ---------------------------------------------------------------- 小物

fn stringOf(value: ?std.json.Value) ?[]const u8 {
    const item = value orelse return null;
    if (item != .string) return null;
    return item.string;
}

fn jsonU64(value: std.json.Value) ?u64 {
    const text = switch (value) {
        .string => |string| string,
        .number_string => |number| number,
        .integer => |number| return if (number >= 0 and number <= std.math.maxInt(u64)) @intCast(number) else null,
        else => return null,
    };
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// `0x` 付き 40 桁の 16 進表記をアドレスにする。
fn parseAddress(text: []const u8) ?[20]u8 {
    if (text.len != 42) return null;
    if (!std.mem.startsWith(u8, text, "0x") and !std.mem.startsWith(u8, text, "0X")) return null;
    var address: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&address, text[2..]) catch return null;
    return address;
}

/// 十進または `0x` 付き十六進の文字列を `u256` にする。
fn parseU256(text: []const u8) ?u256 {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X")) {
        return std.fmt.parseInt(u256, text[2..], 16) catch null;
    }
    return std.fmt.parseInt(u256, text, 10) catch null;
}

fn uintOf(value: abi.Value) ?u256 {
    return switch (value) {
        .uint => |number| number,
        else => null,
    };
}

/// 値をアドレスとして解釈する。
///
/// `bytes` の先頭 20 バイトも受け付ける（仕様の `path` スライス
/// `params.path.[0:20]` をアドレスとして扱うため）。
fn addressOf(value: abi.Value) ?[20]u8 {
    return switch (value) {
        .address => |address| address,
        .bytes => |bytes| if (bytes.len == 20) bytes[0..20].* else null,
        else => null,
    };
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn hexToBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// 32 バイト語にする（テスト用の calldata 構築）。
fn word(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, .big);
    return out;
}

/// セレクタ＋引数の語から calldata を組み立てる（テスト用）。
fn buildCalldata(
    allocator: std.mem.Allocator,
    signature: []const u8,
    arguments: []const [32]u8,
) Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    const selector = abi.computeSelector(signature);
    try out.appendSlice(allocator, &selector);
    for (arguments) |argument| try out.appendSlice(allocator, &argument);
    return out.toOwnedSlice(allocator);
}

/// Lido stETH の記述子。レジストリの実ファイルをそのまま埋め込む。
///
/// 出典: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/registry/lido/calldata-stETH.json
///       （ERC-7730 v2 スキーマ。context.contract.deployments が chainId 1 の stETH を指す）
const steth_descriptor =
    \\{
    \\  "$schema": "../../specs/erc7730-v2.schema.json",
    \\  "context": { "$id": "stETH", "contract": { "deployments": [{ "chainId": 1, "address": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84" }] } },
    \\  "metadata": {
    \\    "owner": "Lido DAO",
    \\    "info": { "url": "https://lido.fi" },
    \\    "constants": { "stETHaddress": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84" },
    \\    "contractName": "stETH"
    \\  },
    \\  "display": {
    \\    "formats": {
    \\      "approve(address _spender, uint256 _amount)": {
    \\        "intent": "Approve stETH",
    \\        "interpolatedIntent": "Allow to spend {_amount}",
    \\        "fields": [
    \\          {
    \\            "label": "Spender",
    \\            "format": "addressName",
    \\            "params": { "types": ["contract"], "sources": ["local"] },
    \\            "path": "#._spender",
    \\            "visible": "always"
    \\          },
    \\          {
    \\            "label": "Amount",
    \\            "format": "tokenAmount",
    \\            "path": "#._amount",
    \\            "params": {
    \\              "token": "$.metadata.constants.stETHaddress",
    \\              "threshold": "0x8000000000000000000000000000000000000000000000000000000000000000",
    \\              "message": "Unlimited"
    \\            },
    \\            "visible": "always"
    \\          }
    \\        ]
    \\      },
    \\      "submit(address _referral)": {
    \\        "intent": "Stake ETH",
    \\        "interpolatedIntent": "Stake {@.value}",
    \\        "fields": [
    \\          { "label": "Amount", "format": "amount", "path": "@.value" },
    \\          { "label": "Referral", "path": "#._referral", "visible": "never" }
    \\        ]
    \\      },
    \\      "transfer(address _recipient, uint256 _amount)": {
    \\        "intent": "Transfer stETH",
    \\        "interpolatedIntent": "Send {_amount} to {_recipient}",
    \\        "fields": [
    \\          {
    \\            "label": "Recipient",
    \\            "format": "addressName",
    \\            "params": { "types": ["eoa", "wallet"], "sources": ["local", "ens"] },
    \\            "path": "#._recipient",
    \\            "visible": "always"
    \\          },
    \\          {
    \\            "label": "Amount",
    \\            "format": "tokenAmount",
    \\            "path": "#._amount",
    \\            "params": { "token": "$.metadata.constants.stETHaddress" },
    \\            "visible": "always"
    \\          }
    \\        ]
    \\      }
    \\    }
    \\  }
    \\}
;

/// Ekubo Ve33 の記述子。レジストリの実ファイルをそのまま埋め込む。
///
/// 出典: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/registry/ekubo/calldata-Ve33Periphery.json
///       （`date` / `calldata` / `@.from` を含む例）
const ekubo_descriptor =
    \\{
    \\  "$schema": "../../specs/erc7730-v2.schema.json",
    \\  "context": {
    \\    "contract": {
    \\      "deployments": [
    \\        { "chainId": 4663, "address": "0x1D834b70c33FAceBdB05af3C9C78da396f5d0E26" },
    \\        { "chainId": 46630, "address": "0x1D834b70c33FAceBdB05af3C9C78da396f5d0E26" }
    \\      ]
    \\    }
    \\  },
    \\  "metadata": {
    \\    "owner": "Ekubo Protocol",
    \\    "contractName": "Ekubo Ve33 Emissions Periphery",
    \\    "info": { "url": "https://ekubo.org" },
    \\    "constants": { "rewardToken": "0x570C5aa79c798E7A418412cC8399ae5bcCe570C5" }
    \\  },
    \\  "display": {
    \\    "formats": {
    \\      "scheduleEmissions(uint64 startTime, uint64 endTime, uint160 rewardRate)": {
    \\        "intent": "Schedule Ve33 emissions",
    \\        "interpolatedIntent": "Schedule STONX emissions",
    \\        "fields": [
    \\          { "path": "startTime", "label": "Start time", "format": "date", "params": { "encoding": "timestamp" }, "visible": "always" },
    \\          { "path": "endTime", "label": "End time", "format": "date", "params": { "encoding": "timestamp" }, "visible": "always" },
    \\          { "path": "rewardRate", "label": "Reward rate (Q32)", "format": "raw", "visible": "always" }
    \\        ]
    \\      },
    \\      "multicall(bytes[] data)": {
    \\        "intent": "Batch Ve33 emission actions",
    \\        "interpolatedIntent": "Ve33 emission batch",
    \\        "fields": [{ "path": "data.[]", "label": "Action", "format": "calldata", "params": { "calleePath": "@.to" }, "visible": "always" }]
    \\      },
    \\      "refundNativeToken()": {
    \\        "intent": "Refund unused native token",
    \\        "interpolatedIntent": "Refund native token",
    \\        "fields": [
    \\          {
    \\            "path": "@.from",
    \\            "label": "Recipient",
    \\            "format": "addressName",
    \\            "params": { "types": ["wallet", "eoa"] },
    \\            "visible": "always"
    \\          }
    \\        ]
    \\      }
    \\    }
    \\  }
    \\}
;

/// ERC-20 の汎用テンプレート（`ercs/` 配下）。**デプロイ情報を持たない**。
///
/// 出典: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/ercs/calldata-erc20-tokens.json
const erc20_template_descriptor =
    \\{
    \\  "$schema": "../specs/erc7730-v2.schema.json",
    \\  "context": { "contract": {} },
    \\  "display": {
    \\    "formats": {
    \\      "transfer(address _to, uint256 _value)": {
    \\        "intent": "Send",
    \\        "fields": [
    \\          { "path": "_value", "label": "Amount", "format": "tokenAmount", "params": { "tokenPath": "@.to" }, "visible": "always" },
    \\          {
    \\            "path": "_to",
    \\            "label": "To",
    \\            "format": "addressName",
    \\            "params": { "types": ["eoa"], "sources": ["local", "ens"] },
    \\            "visible": "always"
    \\          }
    \\        ]
    \\      },
    \\      "approve(address _spender, uint256 _value)": {
    \\        "intent": "Approve",
    \\        "fields": [
    \\          {
    \\            "path": "_spender",
    \\            "label": "Spender",
    \\            "format": "addressName",
    \\            "params": { "types": ["eoa", "contract"] },
    \\            "visible": "always"
    \\          },
    \\          {
    \\            "path": "_value",
    \\            "label": "Amount",
    \\            "format": "tokenAmount",
    \\            "params": { "tokenPath": "@.to", "threshold": "0x8000000000000000000000000000000000000000000000000000000000000000" },
    \\            "visible": "always"
    \\          }
    \\        ]
    \\      }
    \\    }
    \\  }
    \\}
;

const steth_address = hexToBytes(20, "ae7ab96520de3a18e5e111b5eaab095312d7fe84");
const zero_address = hexToBytes(20, "0000000000000000000000000000000000000000");
const recipient_address = hexToBytes(20, "5aaeb6053f3e94c9b9a09f33669435e7ef1beaed");

/// アドレスを 32 バイト語にする。
fn addressWord(address: [20]u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    @memcpy(out[12..32], &address);
    return out;
}

test "stETH の記述子を解析する（実レジストリのファイル）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    try testing.expectEqualStrings("stETH", descriptor.contextId().?);
    try testing.expectEqualStrings("Lido DAO", descriptor.owner().?);
    try testing.expectEqualStrings("stETH", descriptor.contractName().?);
    try testing.expectEqualStrings("https://lido.fi", descriptor.infoUrl().?);

    const deployments = try descriptor.deployments();
    try testing.expectEqual(@as(usize, 1), deployments.len);
    try testing.expectEqual(@as(u64, 1), deployments[0].chain_id);
    try testing.expectEqualSlices(u8, &steth_address, &deployments[0].address);

    descriptor.deinit();
}

test "findFormat は chainId とアドレスの両方が一致するときだけ返す" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);
    const transfer_selector = hexToBytes(4, "a9059cbb");

    const format = findFormat(descriptor, 1, steth_address, transfer_selector).?;
    try testing.expectEqualStrings("transfer(address,uint256)", format.signature);
    try testing.expectEqualStrings("transfer(address _recipient, uint256 _amount)", format.key);
    try testing.expectEqualStrings("Transfer stETH", format.intent);
    try testing.expectEqual(@as(usize, 2), format.fields.len);
    try testing.expectEqualStrings("_recipient", format.names[0]);
    try testing.expectEqualStrings("_amount", format.names[1]);
    try testing.expect(format.types != null);

    // チェーンが違う → 使わない
    try testing.expect(findFormat(descriptor, 10, steth_address, transfer_selector) == null);
    // アドレスが違う → 使わない
    try testing.expect(findFormat(descriptor, 1, zero_address, transfer_selector) == null);
    // セレクタが違う → 使わない
    try testing.expect(findFormat(descriptor, 1, steth_address, hexToBytes(4, "deadbeef")) == null);

    descriptor.deinit();
}

test "stETH transfer を実データで表示する（ERC-55 表記とトークン量）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // transfer(0x5aAe…eAed, 1.5e18) — アドレスは EIP-55 の公式テスト用例。
    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1_500_000_000_000_000_000),
    });

    const tokens = [_]TokenMetadata{
        .{ .address = steth_address, .ticker = "stETH", .decimals = 18 },
    };
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &tokens);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("操作", items[0].label);
    try testing.expectEqualStrings("Transfer stETH", items[0].value);
    try testing.expect(!items[0].warning);
    try testing.expectEqualStrings("Recipient", items[1].label);
    try testing.expectEqualStrings("0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed", items[1].value);
    try testing.expect(!items[1].warning);
    try testing.expectEqualStrings("Amount", items[2].label);
    try testing.expectEqualStrings("1.5 stETH", items[2].value);
    try testing.expect(!items[2].warning);

    descriptor.deinit();
}

test "トークン情報が無い場合は生の値に警告を付ける" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);
    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
    });

    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("1000 (トークン情報が不明)", items[2].value);
    try testing.expect(items[2].warning);

    descriptor.deinit();
}

test "無制限の approve は警告付きで表示する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);
    const calldata = try buildCalldata(allocator, "approve(address,uint256)", &.{
        addressWord(hexToBytes(20, "1111111111111111111111111111111111111111")),
        word(std.math.maxInt(u256)),
    });

    const tokens = [_]TokenMetadata{
        .{ .address = steth_address, .ticker = "stETH", .decimals = 18 },
    };
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &tokens);

    // 警告が先頭に来る（記述子に依存しない危険判定）。
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("警告", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "無制限の承認") != null);
    try testing.expect(items[0].warning);
    try testing.expectEqualStrings("操作", items[1].label);
    try testing.expectEqualStrings("Approve stETH", items[1].value);
    try testing.expectEqualStrings("Spender", items[2].label);
    try testing.expectEqualStrings("0x1111111111111111111111111111111111111111", items[2].value);
    // `threshold` 以上なのでメッセージ（既定 "Unlimited"）＋ティッカー
    try testing.expectEqualStrings("Amount", items[3].label);
    try testing.expectEqualStrings("Unlimited stETH", items[3].value);
    try testing.expect(!items[3].warning);

    descriptor.deinit();
}

test "取得できないコンテナ値（@.value）は不明として警告する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);
    const calldata = try buildCalldata(allocator, "submit(address)", &.{
        addressWord(zero_address),
    });

    // `render` は value を持たない。
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Stake ETH", items[0].value);
    try testing.expectEqualStrings("Amount", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "不明") != null);
    try testing.expect(items[1].warning);
    // `visible: "never"` の Referral は表示しない。
    for (items) |item| {
        try testing.expect(!std.mem.eql(u8, item.label, "Referral"));
    }

    // value を渡せばネイティブ通貨として表示する。
    const container = Container{ .chain_id = 1, .to = steth_address, .value = 500_000_000_000_000_000 };
    const with_value = try renderTransaction(allocator, descriptor, container, calldata, &.{});
    try testing.expectEqualStrings("0.5 ETH", with_value[1].value);
    try testing.expect(!with_value[1].warning);

    descriptor.deinit();
}

test "記述子に無い呼び出しは未知のコントラクトとして警告しハッシュを返す" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // stETH だが記述子に無い関数（セレクタ deadbeef）。
    const calldata = try buildCalldata(allocator, "unknownFunction()", &.{
        word(1),
    });
    var patched = try allocator.dupe(u8, calldata);
    @memcpy(patched[0..4], &hexToBytes(4, "deadbeef"));

    const items = try render(allocator, descriptor, 1, steth_address, patched, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("宛先", items[0].label);
    try testing.expectEqualStrings("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", items[0].value);
    try testing.expectEqualStrings("警告", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "未知のコントラクト") != null);
    try testing.expect(items[1].warning);
    try testing.expectEqualStrings("関数セレクタ", items[2].label);
    try testing.expectEqualStrings("0xdeadbeef", items[2].value);
    try testing.expectEqualStrings("calldata ハッシュ", items[3].label);

    // ハッシュは Keccak-256(calldata) である。
    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(patched, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "0x{s}", .{&expected}),
        items[3].value,
    );

    descriptor.deinit();
}

test "デプロイ情報を持たない汎用記述子は使わない（安全側）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, erc20_template_descriptor);
    // ERC-20 の `transfer(address,uint256)` が定義されているが context.contract は空。
    try testing.expect(findFormat(descriptor, 1, steth_address, hexToBytes(4, "a9059cbb")) == null);

    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
    });
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqualStrings("宛先", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "無い") != null);
    try testing.expect(items[1].warning);
    try testing.expectEqualStrings("calldata ハッシュ", items[3].label);

    descriptor.deinit();
}

test "同じセレクタの定義が重複する記述子は不正として扱う" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "context": { "contract": { "deployments": [{ "chainId": 1, "address": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84" }] } },
        \\  "display": { "formats": {
        \\    "transfer(address a, uint256 b)": { "intent": "A" },
        \\    "transfer(address to, uint256 value)": { "intent": "B" }
        \\  } }
        \\}
    ;
    var descriptor = try Descriptor.parse(allocator, json);
    try testing.expect(findFormat(descriptor, 1, steth_address, hexToBytes(4, "a9059cbb")) == null);

    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
    });
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqualStrings("警告", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "重複") != null);

    descriptor.deinit();
}

test "Ekubo: 日付・raw を実データで表示する（実レジストリのファイル）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, ekubo_descriptor);
    const ve33 = hexToBytes(20, "1d834b70c33facebdb05af3c9c78da396f5d0e26");

    // scheduleEmissions(1709191632, 0, 2^160-1)
    const calldata = try buildCalldata(allocator, "scheduleEmissions(uint64,uint64,uint160)", &.{
        word(1_709_191_632),
        word(0),
        word((@as(u256, 1) << 160) - 1),
    });

    const items = try render(allocator, descriptor, 4663, ve33, calldata, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Schedule Ve33 emissions", items[0].value);
    try testing.expectEqualStrings("Start time", items[1].label);
    try testing.expectEqualStrings("2024-02-29T07:27:12Z", items[1].value);
    try testing.expect(!items[1].warning);
    try testing.expectEqualStrings("End time", items[2].label);
    try testing.expectEqualStrings("1970-01-01T00:00:00Z", items[2].value);
    try testing.expectEqualStrings("Reward rate (Q32)", items[3].label);
    try testing.expectEqualStrings("1461501637330902918203684832716283019655932542975", items[3].value);
    try testing.expect(!items[3].warning);

    // 2 つ目のデプロイ先（chainId 46630）でも一致する。
    try testing.expect(findFormat(descriptor, 46630, ve33, abi.computeSelector("refundNativeToken()")) != null);
    // 別チェーンでは使わない。
    try testing.expect(findFormat(descriptor, 1, ve33, abi.computeSelector("refundNativeToken()")) == null);

    descriptor.deinit();
}

test "Ekubo: 未対応の表示形式と取得できないコンテナ値は警告する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, ekubo_descriptor);
    const ve33 = hexToBytes(20, "1d834b70c33facebdb05af3c9c78da396f5d0e26");
    const refund_selector = abi.computeSelector("refundNativeToken()");

    // refundNativeToken() — `@.from` は `render` では取得できない。
    const items = try render(allocator, descriptor, 4663, ve33, &refund_selector, &.{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Refund unused native token", items[0].value);
    try testing.expectEqualStrings("Recipient", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "不明") != null);
    try testing.expect(items[1].warning);

    // from を渡せば送信元のアドレス（ERC-55 表記）になる。
    const container = Container{ .chain_id = 4663, .to = ve33, .from = steth_address };
    const with_from = try renderTransaction(allocator, descriptor, container, &refund_selector, &.{});
    try testing.expectEqualStrings("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", with_from[1].value);
    try testing.expect(!with_from[1].warning);

    // multicall(bytes[]) — `calldata` 形式は未対応（生の値を警告付きで出す）。
    const multicall_selector = abi.computeSelector("multicall(bytes[])");
    var multicall = std.ArrayList(u8).empty;
    try multicall.appendSlice(allocator, &multicall_selector);
    try multicall.appendSlice(allocator, &word(0x20)); // 配列データへのオフセット
    try multicall.appendSlice(allocator, &word(1)); // 要素数 1
    try multicall.appendSlice(allocator, &word(0x20)); // 要素 0 へのオフセット
    try multicall.appendSlice(allocator, &word(4)); // 要素（bytes）の長さ 4
    try multicall.appendSlice(allocator, &hexToBytes(32, "deadbeef00000000000000000000000000000000000000000000000000000000"));

    const multicall_items = try render(allocator, descriptor, 4663, ve33, multicall.items, &.{});
    try testing.expectEqual(@as(usize, 2), multicall_items.len);
    try testing.expectEqualStrings("Action", multicall_items[1].label);
    try testing.expect(std.mem.indexOf(u8, multicall_items[1].value, "未対応") != null);
    try testing.expect(multicall_items[1].warning);

    descriptor.deinit();
}

test "setApprovalForAll と permit は記述子が無くても警告する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 記述子を持たない（未知のコントラクト）ケースでも警告できることを確認する。
    var descriptor = try Descriptor.parse(allocator, "{\"context\":{\"contract\":{}}}");

    const set_approval = try buildCalldata(allocator, "setApprovalForAll(address,bool)", &.{
        addressWord(hexToBytes(20, "2222222222222222222222222222222222222222")),
        word(1),
    });
    const items = try render(allocator, descriptor, 1, steth_address, set_approval, &.{});
    try testing.expectEqualStrings("警告", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "すべてのトークンの操作権限") != null);
    try testing.expect(items[0].warning);

    // permit(...) — 7 引数（セレクタ + 224 バイト）。
    var permit = std.ArrayList(u8).empty;
    try permit.appendSlice(allocator, &hexToBytes(4, "d505accf"));
    for (0..7) |_| try permit.appendSlice(allocator, &word(0));
    const permit_items = try render(allocator, descriptor, 1, steth_address, permit.items, &.{});
    try testing.expectEqualStrings("警告", permit_items[0].label);
    try testing.expect(std.mem.indexOf(u8, permit_items[0].value, "permit") != null);
    try testing.expect(permit_items[0].warning);

    // 無制限でない approve には警告を出さない。
    const approve = try buildCalldata(allocator, "approve(address,uint256)", &.{
        addressWord(zero_address),
        word(1000),
    });
    const approve_items = try render(allocator, descriptor, 1, steth_address, approve, &.{});
    try testing.expectEqualStrings("宛先", approve_items[0].label);

    descriptor.deinit();
}

test "非正準な calldata は値を捏造せず拒否する" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // transfer の calldata に余分な語を足したもの（正準形ではない）。
    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
        word(0),
    });

    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Transfer stETH", items[0].value);
    try testing.expectEqualStrings("警告", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "正準形ではない") != null);
    try testing.expect(items[1].warning);

    descriptor.deinit();
}

test "tuple を含む記述子はセレクタ照合だけ行い引数は表示しない" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json =
        \\{
        \\  "context": { "contract": { "deployments": [{ "chainId": 1, "address": "0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84" }] } },
        \\  "display": { "formats": {
        \\    "submit((address token, uint256 amount) order, bytes32 salt)": {
        \\      "intent": "Submit order",
        \\      "fields": [{ "path": "order.amount", "label": "Amount", "format": "raw" }]
        \\    }
        \\  } }
        \\}
    ;
    var descriptor = try Descriptor.parse(allocator, json);

    const selector = abi.computeSelector("submit((address,uint256),bytes32)");
    const format = findFormat(descriptor, 1, steth_address, selector).?;
    try testing.expectEqualStrings("submit((address,uint256),bytes32)", format.signature);
    try testing.expect(format.types == null);

    const calldata = try buildCalldata(allocator, "submit((address,uint256),bytes32)", &.{
        addressWord(recipient_address),
        word(1000),
        word(0),
    });
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Submit order", items[0].value);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "未対応の型") != null);
    try testing.expect(items[1].warning);

    descriptor.deinit();
}

test "パスのスライス（bytes[0:20]）をアドレスとして扱う（自前の最小記述子）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 実レジストリのファイルではない（パスのスライスだけを確認するための最小記述子）。
    // 仕様では `tokenPath: "params.path.[0:20]"` のように使われる。
    const json =
        \\{
        \\  "context": { "contract": { "deployments": [{ "chainId": 1, "address": "0x0000000000000000000000000000000000000002" }] } },
        \\  "display": { "formats": {
        \\    "f(bytes packed)": {
        \\      "intent": "Slice test",
        \\      "fields": [
        \\        { "path": "packed[0:20]", "label": "Token", "format": "tokenTicker" },
        \\        { "path": "packed[0:4]", "label": "Prefix", "format": "raw" },
        \\        { "path": "packed[0:99]", "label": "Out of range", "format": "raw" }
        \\      ]
        \\    }
        \\  } }
        \\}
    ;
    var descriptor = try Descriptor.parse(allocator, json);
    const target = hexToBytes(20, "0000000000000000000000000000000000000002");

    const calldata = try buildCalldata(allocator, "f(bytes)", &.{
        word(0x20),
        word(20),
        hexToBytes(32, "ae7ab96520de3a18e5e111b5eaab095312d7fe84000000000000000000000000"),
    });

    const tokens = [_]TokenMetadata{
        .{ .address = steth_address, .ticker = "stETH", .decimals = 18 },
    };
    const items = try render(allocator, descriptor, 1, target, calldata, &tokens);
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Token", items[1].label);
    try testing.expectEqualStrings("stETH", items[1].value);
    try testing.expect(!items[1].warning);
    try testing.expectEqualStrings("Prefix", items[2].label);
    try testing.expectEqualStrings("0xae7ab965", items[2].value);
    // 範囲外のスライスは推測せず「不明」として警告する（画面全体は失敗させない）。
    try testing.expectEqualStrings("Out of range", items[3].label);
    try testing.expect(std.mem.indexOf(u8, items[3].value, "不明") != null);
    try testing.expect(items[3].warning);

    descriptor.deinit();
}

test "date・duration・enum・chainId の表示形式（自前の最小記述子）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // 実レジストリのファイルではない（個々の表示形式だけを確認するための最小記述子）。
    const json =
        \\{
        \\  "context": { "contract": { "deployments": [{ "chainId": 1, "address": "0x0000000000000000000000000000000000000001" }] } },
        \\  "metadata": { "enums": { "mode": { "1": "stable", "2": "variable" } } },
        \\  "display": { "formats": {
        \\    "f(uint256 mode, uint256 chain, uint256 seconds, uint256 when)": {
        \\      "intent": "Test",
        \\      "fields": [
        \\        { "path": "mode", "label": "Mode", "format": "enum", "params": { "$ref": "$.metadata.enums.mode" } },
        \\        { "path": "chain", "label": "Chain", "format": "chainId" },
        \\        { "path": "seconds", "label": "Duration", "format": "duration" },
        \\        { "path": "when", "label": "When", "format": "date", "params": { "encoding": "timestamp" } }
        \\      ]
        \\    }
        \\  } }
        \\}
    ;
    var descriptor = try Descriptor.parse(allocator, json);
    const target = hexToBytes(20, "0000000000000000000000000000000000000001");

    const calldata = try buildCalldata(allocator, "f(uint256,uint256,uint256,uint256)", &.{
        word(2),
        word(1),
        word(8250),
        word(1_709_191_632),
    });

    const items = try render(allocator, descriptor, 1, target, calldata, &.{});
    try testing.expectEqual(@as(usize, 5), items.len);
    try testing.expectEqualStrings("Test", items[0].value);
    try testing.expectEqualStrings("Mode", items[1].label);
    try testing.expectEqualStrings("variable", items[1].value);
    try testing.expectEqualStrings("Ethereum Mainnet", items[2].value);
    try testing.expectEqualStrings("Duration", items[3].label);
    try testing.expectEqualStrings("02:17:30", items[3].value);
    try testing.expectEqualStrings("2024-02-29T07:27:12Z", items[4].value);

    descriptor.deinit();
}
