//! Parsing of ERC-7730 descriptors (display definitions for clear signing) and generation of human-readable display items.
//!
//! References: https://eips.ethereum.org/EIPS/eip-7730
//!       https://github.com/ethereum/clear-signing-erc7730-registry
//!
//! **Design policy (never display a guess)**
//! - A descriptor is used only when **both the chainId and the address** in `context.contract.deployments` match.
//!   A descriptor without deployment information (such as the generic templates under `ercs/`) is
//!   **not used** even if the selector matches (so that no generic meaning is attached to an arbitrary contract).
//! - A call that does not match is not guessed at: it is warned about as an "unknown contract" and
//!   only the Keccak-256 hash of the calldata is presented.
//! - When a value is unknown or a display format is unsupported, the **raw value is annotated with a reason** and
//!   `warning = true` is set (e.g. `1000 (unknown token info)`). Values are never fabricated.
//! - Warnings for dangerous operations (unlimited `approve`, `setApprovalForAll`, `permit`) do not depend on
//!   the descriptor; they are determined directly from the calldata (so they work without a descriptor). Warning items go at the top of the list.
//!
//! **Unsupported (warned about as such)**
//! - Pulling in other descriptors via `includes` (requires resolution on the registry consumer side)
//! - The display formats for tuple (struct) fields, `calldata` (nested calls), `nftName`, `unit` and
//!   `interoperableAddressName`
//! - `interpolatedIntent`; notations for `path` other than `[]`, subscripts and slices; array subscript support for `params`;
//!   `encryption`; compound rules for `visible`; array subscripts inside `$.` paths
//! - The container `render` receives has only `to` and `chainId` (descriptors that use `from` / `value`
//!   are warned about as "unknown". Use `renderTransaction` when a complete container is needed)
//! - No name resolution (ENS etc.) is performed. `addressName` falls back to ERC-55 notation as the spec requires
//!
//! The tests embed real registry descriptors (stETH / Ekubo Ve33 / ERC-20 generic template)
//! verbatim and verify against them.
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const abi = @import("abi.zig");
const evm_address = @import("address.zig");

/// A display item. `label` is the item name, `value` is the formatted value.
pub const DisplayItem = struct {
    label: []const u8,
    value: []const u8,
    /// An item that draws the user's attention: unknown, dangerous, unsupported, and so on.
    warning: bool,
};

/// Metadata used to display a token (obtained from the contract, or from a known list).
pub const TokenMetadata = struct {
    address: [20]u8,
    ticker: []const u8,
    decimals: u8,
};

/// A deployment target of the contract the descriptor applies to.
pub const Deployment = struct {
    chain_id: u64,
    address: [20]u8,
};

/// The transaction container (the value ERC-7730's `@.` refers to).
pub const Container = struct {
    chain_id: u64,
    to: [20]u8,
    /// Sender (`@.from`). null if unknown.
    from: ?[20]u8 = null,
    /// Native currency value (`@.value`). null if unknown.
    value: ?u256 = null,
};

/// A descriptor field (the definition of a display item).
///
/// `$ref` (a reference to `display.definitions`) is resolved at parse time and overridden by a local entry.
pub const Field = struct {
    /// Path pointing at a decoded argument.
    path: ?[]const u8,
    /// Path pointing at a constant inside the descriptor, or a literal.
    value: ?[]const u8,
    label: ?[]const u8,
    format: ?[]const u8,
    params: ?std.json.Value,
    /// The raw value of `visible` (a string, or a compound rule object).
    visible: ?std.json.Value,

    fn labelText(self: Field) []const u8 {
        return self.label orelse self.path orelse self.value orelse "Item";
    }
};

/// One function (one entry of `display.formats`).
pub const Format = struct {
    /// The key of `display.formats` (e.g. `transfer(address _recipient, uint256 _amount)`).
    key: []const u8,
    /// Types-only canonical signature (e.g. `transfer(address,uint256)`).
    signature: []const u8,
    selector: [4]u8,
    intent: []const u8,
    fields: []const Field,
    /// Argument types. null if a tuple is included (not decodable).
    types: ?[]const abi.AbiType,
    /// Top-level argument names. An argument without a name is the empty string.
    names: []const []const u8,
};

/// An ERC-7730 descriptor.
pub const Descriptor = struct {
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    /// Parse a JSON string. Numbers are kept as strings (to handle `uint256` exactly).
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

    /// `context.$id` (the descriptor identifier).
    pub fn contextId(self: Descriptor) ?[]const u8 {
        const context = self.parsed.value.object.get("context") orelse return null;
        if (context != .object) return null;
        return stringOf(context.object.get("$id"));
    }

    /// `metadata.owner`.
    pub fn owner(self: Descriptor) ?[]const u8 {
        return self.metadataString("owner");
    }

    /// `metadata.contractName`.
    pub fn contractName(self: Descriptor) ?[]const u8 {
        return self.metadataString("contractName");
    }

    /// `metadata.info.url`.
    pub fn infoUrl(self: Descriptor) ?[]const u8 {
        const metadata_object = self.metadata() orelse return null;
        const info = metadata_object.get("info") orelse return null;
        if (info != .object) return null;
        return stringOf(info.object.get("url"));
    }

    /// `context.contract.deployments`. Empty if absent.
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

    /// `metadata.token` (ERC-20 metadata carried by the descriptor itself).
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

    /// The `display.formats` object. null if absent (e.g. a descriptor with only `includes`).
    fn formatsObject(self: Descriptor) ?std.json.ObjectMap {
        const display = self.parsed.value.object.get("display") orelse return null;
        if (display != .object) return null;
        const formats = display.object.get("formats") orelse return null;
        if (formats != .object) return null;
        return formats.object;
    }

    /// Resolve an internal path starting with `$.` (object keys only; array subscripts unsupported).
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

/// Token information inside a descriptor.
pub const TokenInfo = struct {
    ticker: []const u8,
    decimals: u8,
};

// ---------------------------------------------------------------- descriptor lookup

/// The lookup result. Used to distinguish duplicate definitions (an invalid descriptor) from "not found".
const Lookup = union(enum) {
    none,
    /// Multiple definitions share the same selector (an invalid descriptor per the spec).
    duplicate,
    found: Format,
};

/// Return the display definition whose `chainId` and contract address both match and whose selector matches.
///
/// - Descriptors without deployment information are not eligible (`null`).
/// - A descriptor with multiple definitions for the same selector is treated as invalid and gives `null`.
///
/// Key parse results are allocated on `descriptor`'s allocator.
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
    // If the deployment information does not match (or the descriptor is broken), do not use it.
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
        // A descriptor with multiple definitions for the same selector is invalid (spec: MUST treat as invalid).
        if (found != null) return .duplicate;
        found = parseFormat(descriptor, key, value, fragment) catch continue;
    }
    if (found) |format| return .{ .found = format };
    return .none;
}

/// Whether the descriptor's deployment targets contain the `chain_id` / `to` pair.
///
/// **A descriptor without deployment information never matches** (so that generic templates are
/// not applied to arbitrary contracts).
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
        // `intent` may be either a "human-readable string" or a "set of label and value pairs".
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

/// When `intent` is an object, join the "label: value" pairs into a string (for on-screen display).
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

/// Parse `display.formats.<key>.fields`. `$ref` is resolved here.
fn fieldsOf(descriptor: Descriptor, format: std.json.Value) Error![]Field {
    const fields = format.object.get("fields") orelse return &.{};
    if (fields != .array) return error.InvalidEncoding;

    const allocator = descriptor.allocator;
    const out = try allocator.alloc(Field, fields.array.items.len);
    for (fields.array.items, 0..) |item, i| {
        if (item != .object) return error.InvalidEncoding;

        // The definition of `$ref` (`$.display.definitions.X`). A local entry takes precedence.
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

// ---------------------------------------------------------------- display

/// Generate display items.
///
/// `token_metadata` is known tokens (values obtained from contracts, etc.). It may be empty.
/// It is natural to pass the same `ArenaAllocator` as for `descriptor` to `allocator` (the return value and
/// all internal slices are allocated from it).
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

/// Generate display items with explicit container information (for descriptors that use `from` / `value`).
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
            .value = "not a function call (< 4 bytes)",
            .warning = true,
        });
        return items.toOwnedSlice(allocator);
    };

    // Put warnings for dangerous operations that do not depend on the descriptor first.
    try appendRiskWarnings(allocator, &items, selector, calldata);

    switch (lookupFormat(descriptor, container.chain_id, container.to, selector)) {
        .none => {
            try items.append(allocator, .{
                .label = "To",
                .value = try checksumAddress(allocator, container.to),
                .warning = false,
            });
            try items.append(allocator, .{
                .label = "WARNING",
                .value = "unknown contract (no matching descriptor): contents not shown",
                .warning = true,
            });
            try appendCalldataSummary(allocator, &items, calldata, selector);
        },
        .duplicate => {
            try items.append(allocator, .{
                .label = "WARNING",
                .value = "invalid descriptor (duplicate selector definition): contents not shown",
                .warning = true,
            });
            try appendCalldataSummary(allocator, &items, calldata, selector);
        },
        .found => |format| {
            try items.append(allocator, .{
                .label = "Action",
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
            .label = "WARNING",
            .value = "unsupported argument type (tuple/struct): cannot show arguments",
            .warning = true,
        });
        try appendCalldataSummary(allocator, items, calldata, format.selector);
        return;
    };

    const values = try allocator.alloc(abi.Value, types.len);
    abi.decodeParameters(allocator, types, calldata[abi.selector_len..], values) catch {
        try items.append(allocator, .{
            .label = "WARNING",
            .value = "calldata is not the canonical ABI form: cannot show arguments",
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
                    .value = try withNote(allocator, "hidden", note),
                    .warning = true,
                });
            }
            continue;
        }

        switch (resolved) {
            .missing => |reason| {
                try items.append(allocator, .{
                    .label = field.labelText(),
                    .value = try std.fmt.allocPrint(allocator, "unknown: {s}", .{reason}),
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

/// The selector and the calldata hash (the last resort when nothing can be inferred).
fn appendCalldataSummary(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    calldata: []const u8,
    selector: [4]u8,
) Error!void {
    var selector_hex: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&selector_hex, "{x}", .{&selector}) catch return error.BufferTooSmall;
    try items.append(allocator, .{
        .label = "Function selector",
        .value = try std.fmt.allocPrint(allocator, "0x{s}", .{selector_hex}),
        .warning = true,
    });

    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(calldata, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try items.append(allocator, .{
        .label = "calldata hash",
        .value = try std.fmt.allocPrint(allocator, "0x{s}", .{&hex}),
        .warning = true,
    });
}

// ---------------------------------------------------------------- dangerous operation warnings

/// Determine dangerous operations from the calldata without depending on the descriptor, and add warning items.
fn appendRiskWarnings(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(DisplayItem),
    selector: [4]u8,
    calldata: []const u8,
) Error!void {
    const known = abi.knownFunction(selector) orelse return;

    // Decode the arguments (nothing can be warned about unless the calldata is canonical).
    const values = try allocator.alloc(abi.Value, known.types.len);
    abi.decodeParameters(allocator, known.types, calldata[abi.selector_len..], values) catch return;

    if (std.mem.eql(u8, known.signature, "approve(address,uint256)")) {
        const spender = values[0].address;
        const amount = values[1].uint;
        if (amount == std.math.maxInt(u256)) {
            try items.append(allocator, .{
                .label = "WARNING",
                .value = try std.fmt.allocPrint(
                    allocator,
                    "Unlimited approval (2^256-1): {s} can move the whole balance",
                    .{try checksumAddress(allocator, spender)},
                ),
                .warning = true,
            });
        }
    } else if (std.mem.eql(u8, known.signature, "setApprovalForAll(address,bool)")) {
        const operator = values[0].address;
        const approved = values[1].boolean;
        try items.append(allocator, .{
            .label = "WARNING",
            .value = if (approved)
                try std.fmt.allocPrint(
                    allocator,
                    "Grants {s} operator rights over all tokens",
                    .{try checksumAddress(allocator, operator)},
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Revokes {s} operator rights over all tokens",
                    .{try checksumAddress(allocator, operator)},
                ),
            .warning = true,
        });
    } else if (std.mem.eql(u8, known.signature, "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)")) {
        const owner = values[0].address;
        const spender = values[1].address;
        try items.append(allocator, .{
            .label = "WARNING",
            .value = try std.fmt.allocPrint(
                allocator,
                "EIP-2612 permit: {s} can move the balance of {s} until expiry",
                .{ try checksumAddress(allocator, spender), try checksumAddress(allocator, owner) },
            ),
            .warning = true,
        });
    }
}

// ---------------------------------------------------------------- path resolution

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
        // If the descriptor itself has `metadata.token`, use the metadata of the target contract.
        if (std.mem.eql(u8, &address, &self.container.to)) {
            if (self.descriptor.ownToken()) |own| return own;
        }
        return null;
    }
};

/// The result of resolving a path.
const Resolved = union(enum) {
    /// A value decoded from the calldata.
    value: abi.Value,
    /// A constant inside the descriptor (string or number).
    text: []const u8,
    /// Could not be resolved. The string is the reason (displayed on screen as "unknown: ...").
    missing: []const u8,
};

/// Resolve a field path.
///
/// Supported notations: `name` / `name[3]` / `name[-1]` / `name[0:20]` / `name.[]`,
/// `@.to` `@.from` `@.value` `@.chainId`, `$.metadata.constants.X` (object keys only).
fn resolveFieldPath(context: *const RenderContext, path: []const u8) Error!Resolved {
    if (std.mem.startsWith(u8, path, "@.")) return resolveContainer(context, path[2..]);
    if (std.mem.startsWith(u8, path, "$")) return resolveConstant(context, path);

    var rest = path;
    if (std.mem.startsWith(u8, rest, "#.")) rest = rest[2..];

    // The leading argument name.
    var end: usize = 0;
    while (end < rest.len and (std.ascii.isAlphanumeric(rest[end]) or rest[end] == '_')) end += 1;
    if (end == 0) return .{ .missing = "unsupported path notation" };
    const name = rest[0..end];

    var position: ?usize = null;
    for (context.names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) {
            position = i;
            break;
        }
    }
    const index = position orelse
        return .{ .missing = "argument name not in descriptor (unnamed or unsupported type)" };

    var value = context.values[index];
    rest = rest[end..];
    while (rest.len != 0) {
        if (rest[0] != '[') return .{ .missing = "unsupported path notation" };
        const close = std.mem.indexOfScalar(u8, rest, ']') orelse return .{ .missing = "unsupported path notation" };
        const next = applySelector(value, rest[1..close]);
        value = switch (next) {
            .value => |resolved| resolved,
            else => return next,
        };
        rest = rest[close + 1 ..];
    }
    return .{ .value = value };
}

/// Apply `[i]` / `[-i]` / `[a:b]` / `[]`.
///
/// Returns "unknown" when it cannot be resolved (so that a typo in a descriptor does not blank the whole screen).
fn applySelector(value: abi.Value, selector_text: []const u8) Resolved {
    if (selector_text.len == 0) return .{ .value = value }; // `.[]` is the whole array

    if (std.mem.indexOfScalar(u8, selector_text, ':')) |colon| {
        const elements = switch (value) {
            .bytes => |bytes| bytes,
            .string => |bytes| bytes,
            else => return .{ .missing = "slices support bytes / string only" },
        };
        const start = sliceIndex(elements.len, selector_text[0..colon], 0) orelse
            return .{ .missing = "invalid slice start" };
        const end = sliceIndex(elements.len, selector_text[colon + 1 ..], elements.len) orelse
            return .{ .missing = "invalid slice end" };
        if (start > end) return .{ .missing = "slice range is reversed" };
        return .{ .value = .{ .bytes = elements[start..end] } };
    }

    const elements = switch (value) {
        .array => |items| items,
        .fixed_array => |items| items,
        else => return .{ .missing = "subscripts support arrays only" },
    };
    const at = elementIndex(elements.len, selector_text) orelse
        return .{ .missing = "array subscript out of range (invalid descriptor or calldata)" };
    return .{ .value = elements[at] };
}

/// Slice bounds. `len` itself is allowed (the end is exclusive).
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

/// Array subscript. `[-1]` means a position from the end.
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

/// Resolve an `@.` container value.
fn resolveContainer(context: *const RenderContext, name: []const u8) Error!Resolved {
    if (std.mem.eql(u8, name, "to")) return .{ .value = .{ .address = context.container.to } };
    if (std.mem.eql(u8, name, "chainId")) return .{ .value = .{ .uint = context.container.chain_id } };
    if (std.mem.eql(u8, name, "from")) {
        const from = context.container.from orelse
            return .{ .missing = "sender (from) not available" };
        return .{ .value = .{ .address = from } };
    }
    if (std.mem.eql(u8, name, "value")) {
        const value = context.container.value orelse
            return .{ .missing = "amount (value) not available" };
        return .{ .value = .{ .uint = value } };
    }
    return .{ .missing = "unsupported container field" };
}

/// Resolve a constant inside the descriptor starting with `$`.
fn resolveConstant(context: *const RenderContext, path: []const u8) Error!Resolved {
    // If it does not start with `$`, it is a literal (`value` may also be a direct constant).
    if (!std.mem.startsWith(u8, path, "$")) return .{ .text = path };

    const target = context.descriptor.resolveInternalPath(path) orelse
        return .{ .missing = "constant not found in descriptor" };
    switch (target) {
        .string => |text| return .{ .text = text },
        .number_string => |text| return .{ .text = text },
        .integer => |number| return .{ .text = try std.fmt.allocPrint(context.allocator, "{d}", .{number}) },
        .bool => |flag| return .{ .text = if (flag) "true" else "false" },
        else => return .{ .missing = "unsupported constant type (array, object, etc.)" },
    }
}

// ---------------------------------------------------------------- visibility

const Visibility = struct { show: bool, note: ?[]const u8 = null };

fn checkVisibility(field: Field) Visibility {
    const raw = field.visible orelse return .{ .show = true };
    if (raw != .string) {
        // Compound rules such as `ifNotIn` / `mustMatch` are unsupported. Hide the field on the safe side.
        return .{ .show = false, .note = "unsupported visible rule" };
    }
    const rule = raw.string;
    if (std.mem.eql(u8, rule, "always")) return .{ .show = true };
    if (std.mem.eql(u8, rule, "never")) return .{ .show = false };
    if (std.mem.eql(u8, rule, "optional")) return .{ .show = true }; // the spec allows displaying it (MAY)
    return .{ .show = false, .note = "unknown visible value" };
}

// ---------------------------------------------------------------- display formats

const Rendered = struct {
    value: []const u8,
    warning: bool,
};

/// Format a field value according to its display format.
fn formatField(context: *const RenderContext, field: Field, value: abi.Value) Error!Rendered {
    const allocator = context.allocator;

    // Arrays are formatted element by element with the same format and joined (`params` array subscript support is unsupported).
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
        // With no display format specified, annotate the raw value with that fact (do not guess a meaning).
        return .{
            .value = try withNote(allocator, try rawText(allocator, value), "no display format specified"),
            .warning = true,
        };
    };

    if (std.mem.eql(u8, identifier, "raw")) {
        if (value == .string and !std.unicode.utf8ValidateSlice(value.string)) {
            return .{
                .value = try withNote(allocator, try rawText(allocator, value), "invalid UTF-8"),
                .warning = true,
            };
        }
        return .{ .value = try rawText(allocator, value), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "amount")) {
        const integer = uintOf(value) orelse return unsupportedValue(allocator, value, "not an integer");
        if (try thresholdMessage(field, integer, "All")) |message| return message;
        const ticker = nativeTicker(context.container.chain_id) orelse {
            return .{
                .value = try withNote(allocator, try decimal(allocator, integer), "native currency unknown"),
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
        const integer = uintOf(value) orelse return unsupportedValue(allocator, value, "not an integer");

        // Determine the token address from `tokenPath` / `token` (a constant).
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
            // Specification to treat it as the native currency (`nativeCurrencyAddress`).
            if (isNativeCurrency(field, address)) {
                const ticker = nativeTicker(context.container.chain_id) orelse {
                    return .{
                        .value = try withNote(allocator, try decimal(allocator, integer), "native currency unknown"),
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
                        .value = try withNote(allocator, try decimal(allocator, integer), "invalid token decimals"),
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
            .value = try withNote(allocator, try decimal(allocator, integer), "unknown token info"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "addressName")) {
        const address = addressOf(value) orelse return unsupportedValue(allocator, value, "not an address");
        // Name resolution (ENS etc.) is not performed on the device, so use ERC-55 notation as the spec requires.
        if (addressListContains(field, "senderAddress", address)) {
            const from = context.container.from orelse {
                return .{
                    .value = try withNote(allocator, try checksumAddress(allocator, address), "sender (from) unknown"),
                    .warning = true,
                };
            };
            return .{ .value = try checksumAddress(allocator, from), .warning = false };
        }
        return .{ .value = try checksumAddress(allocator, address), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "date")) {
        const seconds = uintOf(value) orelse return unsupportedValue(allocator, value, "not an integer");
        const encoding = paramText(field, "encoding") orelse "timestamp";
        if (!std.mem.eql(u8, encoding, "timestamp")) {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "unsupported date encoding"),
                .warning = true,
            };
        }
        if (seconds > std.math.maxInt(i64)) {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "date out of range"),
                .warning = true,
            };
        }
        const text = formatDate(allocator, @intCast(seconds)) catch {
            return .{
                .value = try withNote(allocator, try decimal(allocator, seconds), "date out of range"),
                .warning = true,
            };
        };
        return .{ .value = text, .warning = false };
    }

    if (std.mem.eql(u8, identifier, "duration")) {
        const seconds = uintOf(value) orelse return unsupportedValue(allocator, value, "not an integer");
        return .{ .value = try formatDuration(allocator, seconds), .warning = false };
    }

    if (std.mem.eql(u8, identifier, "enum")) {
        const reference = paramText(field, "$ref") orelse
            return unsupportedValue(allocator, value, "enum has no $ref");
        const table = context.descriptor.resolveInternalPath(reference) orelse
            return unsupportedValue(allocator, value, "enum definition not found");
        if (table != .object) return unsupportedValue(allocator, value, "invalid enum definition");
        if (try enumText(allocator, table.object, value)) |text| {
            return .{ .value = text, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try rawText(allocator, value), "value not in enum definition"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "chainId")) {
        const id = uintOf(value) orelse return unsupportedValue(allocator, value, "not an integer");
        if (id <= std.math.maxInt(u64)) {
            if (chainName(@intCast(id))) |name| return .{ .value = name, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try decimal(allocator, id), "unknown chain name"),
            .warning = true,
        };
    }

    if (std.mem.eql(u8, identifier, "tokenTicker")) {
        const address = addressOf(value) orelse return unsupportedValue(allocator, value, "not an address");
        if (context.lookupToken(address)) |metadata| {
            return .{ .value = metadata.ticker, .warning = false };
        }
        return .{
            .value = try withNote(allocator, try checksumAddress(allocator, address), "unknown token info"),
            .warning = true,
        };
    }

    // `calldata` (nested calls), `nftName`, `unit`, `interoperableAddressName`, and so on.
    return .{
        .value = try withNote(allocator, try rawText(allocator, value), try std.fmt.allocPrint(
            allocator,
            "unsupported display format \"{s}\"",
            .{identifier},
        )),
        .warning = true,
    };
}

/// The response when a display format is applied to a non-integer value (raw value + reason).
fn unsupportedValue(allocator: std.mem.Allocator, value: abi.Value, reason: []const u8) Error!Rendered {
    return .{
        .value = try withNote(allocator, try rawText(allocator, value), reason),
        .warning = true,
    };
}

/// Return a message when the value is at or above the threshold (`threshold` / `message`).
fn thresholdMessage(field: Field, value: u256, default_message: []const u8) Error!?Rendered {
    const threshold_text = paramText(field, "threshold") orelse return null;
    const threshold = parseU256(threshold_text) orelse return null;
    if (value < threshold) return null;
    const message = paramText(field, "message") orelse default_message;
    return .{ .value = message, .warning = false };
}

/// Look up the display string in the `metadata.enums.X` mapping table.
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

// ---------------------------------------------------------------- value to string

/// Turn a raw value into a string (`uint` in decimal, addresses in ERC-55 notation, byte sequences in hex).
fn rawText(allocator: std.mem.Allocator, value: abi.Value) Error![]const u8 {
    return switch (value) {
        .uint => |number| try decimal(allocator, number),
        .int => |number| try std.fmt.allocPrint(allocator, "{d}", .{number}),
        .address => |address| try checksumAddress(allocator, address),
        .boolean => |flag| if (flag) "true" else "false",
        .bytes => |bytes| try hexWithPrefix(allocator, bytes),
        .string => |text| text,
        .array, .fixed_array => |items| try std.fmt.allocPrint(allocator, "array of {d} items", .{items.len}),
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

/// Render an integer as a decimal with `decimals` digits (trailing zeros are dropped).
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

/// Render a UNIX time (seconds) as an RFC 3339-style UTC string (`2024-02-29T07:27:12Z`).
///
/// The algorithm is civil_from_days (Howard Hinnant). Leap years are handled by this formula too.
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
    // Formatting it while signed would produce "+2024", so check that it is non-negative before making it unsigned.
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        @as(u32, @intCast(year)),
        @as(u32, @intCast(month)),
        @as(u32, @intCast(day)),
        @as(u32, @intCast(hours)),
        @as(u32, @intCast(minutes)),
        @as(u32, @intCast(secs)),
    });
}

/// Render seconds as `HH:MM:SS` (durations beyond 24 hours are still shown as hours).
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

// ---------------------------------------------------------------- parameters

fn paramValue(field: Field, name: []const u8) ?std.json.Value {
    const params = field.params orelse return null;
    if (params != .object) return null;
    return params.object.get(name);
}

fn paramText(field: Field, name: []const u8) ?[]const u8 {
    return stringOf(paramValue(field, name));
}

/// Whether `nativeCurrencyAddress` (a string or an array) contains the address.
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

// ---------------------------------------------------------------- chain table
//
// Only a small subset of chains can be kept on the device. A chain not in the table is not guessed at;
// it is warned about as "unknown".

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

// ---------------------------------------------------------------- helpers

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

/// Turn a 0x-prefixed 40-digit hex string into an address.
fn parseAddress(text: []const u8) ?[20]u8 {
    if (text.len != 42) return null;
    if (!std.mem.startsWith(u8, text, "0x") and !std.mem.startsWith(u8, text, "0X")) return null;
    var address: [20]u8 = undefined;
    _ = std.fmt.hexToBytes(&address, text[2..]) catch return null;
    return address;
}

/// Turn a decimal or 0x-prefixed hex string into a `u256`.
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

/// Interpret a value as an address.
///
/// The first 20 bytes of `bytes` are also accepted (so that the spec's `path` slice
/// `params.path.[0:20]` is treated as an address).
fn addressOf(value: abi.Value) ?[20]u8 {
    return switch (value) {
        .address => |address| address,
        .bytes => |bytes| if (bytes.len == 20) bytes[0..20].* else null,
        else => null,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn hexToBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// Turn a value into a 32-byte word (test calldata construction).
fn word(value: u256) [32]u8 {
    var out: [32]u8 = undefined;
    std.mem.writeInt(u256, &out, value, .big);
    return out;
}

/// Build calldata from a selector plus argument words (for tests).
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

/// The Lido stETH descriptor. The real registry file is embedded verbatim.
///
/// Source: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/registry/lido/calldata-stETH.json
///       (ERC-7730 v2 schema. context.contract.deployments points at stETH on chainId 1)
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

/// The Ekubo Ve33 descriptor. The real registry file is embedded verbatim.
///
/// Source: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/registry/ekubo/calldata-Ve33Periphery.json
///       (an example containing `date` / `calldata` / `@.from`)
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

/// The ERC-20 generic template (under `ercs/`). **It carries no deployment information**.
///
/// Source: https://github.com/ethereum/clear-signing-erc7730-registry/blob/master/ercs/calldata-erc20-tokens.json
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

/// Turn an address into a 32-byte word.
fn addressWord(address: [20]u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    @memcpy(out[12..32], &address);
    return out;
}

test "parses the stETH descriptor (a real registry file)" {
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

test "findFormat returns a format only when both chainId and address match" {
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

    // different chain → not used
    try testing.expect(findFormat(descriptor, 10, steth_address, transfer_selector) == null);
    // different address → not used
    try testing.expect(findFormat(descriptor, 1, zero_address, transfer_selector) == null);
    // different selector → not used
    try testing.expect(findFormat(descriptor, 1, steth_address, hexToBytes(4, "deadbeef")) == null);

    descriptor.deinit();
}

test "displays an stETH transfer from real data (ERC-55 notation and token amount)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // transfer(0x5aAe…eAed, 1.5e18) — the address is the official EIP-55 test case.
    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1_500_000_000_000_000_000),
    });

    const tokens = [_]TokenMetadata{
        .{ .address = steth_address, .ticker = "stETH", .decimals = 18 },
    };
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &tokens);

    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("Action", items[0].label);
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

test "annotates the raw value with a warning when token information is missing" {
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
    try testing.expectEqualStrings("1000 (unknown token info)", items[2].value);
    try testing.expect(items[2].warning);

    descriptor.deinit();
}

test "displays an unlimited approve with a warning" {
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

    // The warning comes first (danger detection independent of the descriptor).
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("WARNING", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "Unlimited approval") != null);
    try testing.expect(items[0].warning);
    try testing.expectEqualStrings("Action", items[1].label);
    try testing.expectEqualStrings("Approve stETH", items[1].value);
    try testing.expectEqualStrings("Spender", items[2].label);
    try testing.expectEqualStrings("0x1111111111111111111111111111111111111111", items[2].value);
    // At or above `threshold`, so the message (default "Unlimited") + ticker
    try testing.expectEqualStrings("Amount", items[3].label);
    try testing.expectEqualStrings("Unlimited stETH", items[3].value);
    try testing.expect(!items[3].warning);

    descriptor.deinit();
}

test "warns about an unavailable container value (@.value) as unknown" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);
    const calldata = try buildCalldata(allocator, "submit(address)", &.{
        addressWord(zero_address),
    });

    // `render` has no value.
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Stake ETH", items[0].value);
    try testing.expectEqualStrings("Amount", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "unknown") != null);
    try testing.expect(items[1].warning);
    // Referral with `visible: "never"` is not displayed.
    for (items) |item| {
        try testing.expect(!std.mem.eql(u8, item.label, "Referral"));
    }

    // Passing value displays it as the native currency.
    const container = Container{ .chain_id = 1, .to = steth_address, .value = 500_000_000_000_000_000 };
    const with_value = try renderTransaction(allocator, descriptor, container, calldata, &.{});
    try testing.expectEqualStrings("0.5 ETH", with_value[1].value);
    try testing.expect(!with_value[1].warning);

    descriptor.deinit();
}

test "warns about a call missing from the descriptor as an unknown contract and returns the hash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // An stETH function missing from the descriptor (selector deadbeef).
    const calldata = try buildCalldata(allocator, "unknownFunction()", &.{
        word(1),
    });
    var patched = try allocator.dupe(u8, calldata);
    @memcpy(patched[0..4], &hexToBytes(4, "deadbeef"));

    const items = try render(allocator, descriptor, 1, steth_address, patched, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("To", items[0].label);
    try testing.expectEqualStrings("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", items[0].value);
    try testing.expectEqualStrings("WARNING", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "unknown contract") != null);
    try testing.expect(items[1].warning);
    try testing.expectEqualStrings("Function selector", items[2].label);
    try testing.expectEqualStrings("0xdeadbeef", items[2].value);
    try testing.expectEqualStrings("calldata hash", items[3].label);

    // The hash is Keccak-256(calldata).
    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(patched, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(allocator, "0x{s}", .{&expected}),
        items[3].value,
    );

    descriptor.deinit();
}

test "does not use a generic descriptor without deployment information (safe side)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, erc20_template_descriptor);
    // ERC-20 `transfer(address,uint256)` is defined, but context.contract is empty.
    try testing.expect(findFormat(descriptor, 1, steth_address, hexToBytes(4, "a9059cbb")) == null);

    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
    });
    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqualStrings("To", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "no matching") != null);
    try testing.expect(items[1].warning);
    try testing.expectEqualStrings("calldata hash", items[3].label);

    descriptor.deinit();
}

test "treats a descriptor with duplicate definitions for the same selector as invalid" {
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
    try testing.expectEqualStrings("WARNING", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "duplicate selector definition") != null);

    descriptor.deinit();
}

test "Ekubo: displays dates and raw values from real data (a real registry file)" {
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

    // It also matches the second deployment target (chainId 46630).
    try testing.expect(findFormat(descriptor, 46630, ve33, abi.computeSelector("refundNativeToken()")) != null);
    // Not used on another chain.
    try testing.expect(findFormat(descriptor, 1, ve33, abi.computeSelector("refundNativeToken()")) == null);

    descriptor.deinit();
}

test "Ekubo: warns about unsupported display formats and unavailable container values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, ekubo_descriptor);
    const ve33 = hexToBytes(20, "1d834b70c33facebdb05af3c9c78da396f5d0e26");
    const refund_selector = abi.computeSelector("refundNativeToken()");

    // refundNativeToken() — `@.from` cannot be obtained by `render`.
    const items = try render(allocator, descriptor, 4663, ve33, &refund_selector, &.{});
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Refund unused native token", items[0].value);
    try testing.expectEqualStrings("Recipient", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "unknown") != null);
    try testing.expect(items[1].warning);

    // Passing from yields the sender address (ERC-55 notation).
    const container = Container{ .chain_id = 4663, .to = ve33, .from = steth_address };
    const with_from = try renderTransaction(allocator, descriptor, container, &refund_selector, &.{});
    try testing.expectEqualStrings("0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84", with_from[1].value);
    try testing.expect(!with_from[1].warning);

    // multicall(bytes[]) — the `calldata` format is unsupported (the raw value is shown with a warning).
    const multicall_selector = abi.computeSelector("multicall(bytes[])");
    var multicall = std.ArrayList(u8).empty;
    try multicall.appendSlice(allocator, &multicall_selector);
    try multicall.appendSlice(allocator, &word(0x20)); // offset to the array data
    try multicall.appendSlice(allocator, &word(1)); // 1 element
    try multicall.appendSlice(allocator, &word(0x20)); // offset to element 0
    try multicall.appendSlice(allocator, &word(4)); // length of the element (bytes): 4
    try multicall.appendSlice(allocator, &hexToBytes(32, "deadbeef00000000000000000000000000000000000000000000000000000000"));

    const multicall_items = try render(allocator, descriptor, 4663, ve33, multicall.items, &.{});
    try testing.expectEqual(@as(usize, 2), multicall_items.len);
    try testing.expectEqualStrings("Action", multicall_items[1].label);
    try testing.expect(std.mem.indexOf(u8, multicall_items[1].value, "unsupported") != null);
    try testing.expect(multicall_items[1].warning);

    descriptor.deinit();
}

test "setApprovalForAll and permit warn even without a descriptor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Confirm that a warning is still produced in the no-descriptor (unknown contract) case.
    var descriptor = try Descriptor.parse(allocator, "{\"context\":{\"contract\":{}}}");

    const set_approval = try buildCalldata(allocator, "setApprovalForAll(address,bool)", &.{
        addressWord(hexToBytes(20, "2222222222222222222222222222222222222222")),
        word(1),
    });
    const items = try render(allocator, descriptor, 1, steth_address, set_approval, &.{});
    try testing.expectEqualStrings("WARNING", items[0].label);
    try testing.expect(std.mem.indexOf(u8, items[0].value, "operator rights over all tokens") != null);
    try testing.expect(items[0].warning);

    // permit(...) — 7 arguments (selector + 224 bytes).
    var permit = std.ArrayList(u8).empty;
    try permit.appendSlice(allocator, &hexToBytes(4, "d505accf"));
    for (0..7) |_| try permit.appendSlice(allocator, &word(0));
    const permit_items = try render(allocator, descriptor, 1, steth_address, permit.items, &.{});
    try testing.expectEqualStrings("WARNING", permit_items[0].label);
    try testing.expect(std.mem.indexOf(u8, permit_items[0].value, "permit") != null);
    try testing.expect(permit_items[0].warning);

    // No warning for a non-unlimited approve.
    const approve = try buildCalldata(allocator, "approve(address,uint256)", &.{
        addressWord(zero_address),
        word(1000),
    });
    const approve_items = try render(allocator, descriptor, 1, steth_address, approve, &.{});
    try testing.expectEqualStrings("To", approve_items[0].label);

    descriptor.deinit();
}

test "rejects non-canonical calldata without fabricating values" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descriptor = try Descriptor.parse(allocator, steth_descriptor);

    // transfer calldata with an extra word appended (not the canonical form).
    const calldata = try buildCalldata(allocator, "transfer(address,uint256)", &.{
        addressWord(recipient_address),
        word(1000),
        word(0),
    });

    const items = try render(allocator, descriptor, 1, steth_address, calldata, &.{});
    try testing.expectEqual(@as(usize, 4), items.len);
    try testing.expectEqualStrings("Transfer stETH", items[0].value);
    try testing.expectEqualStrings("WARNING", items[1].label);
    try testing.expect(std.mem.indexOf(u8, items[1].value, "not the canonical ABI form") != null);
    try testing.expect(items[1].warning);

    descriptor.deinit();
}

test "a descriptor containing a tuple only matches selectors and does not display arguments" {
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
    try testing.expect(std.mem.indexOf(u8, items[1].value, "unsupported argument type") != null);
    try testing.expect(items[1].warning);

    descriptor.deinit();
}

test "treats a path slice (bytes[0:20]) as an address (a minimal hand-written descriptor)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Not a real registry file (a minimal descriptor to check path slicing only).
    // The spec uses it as `tokenPath: "params.path.[0:20]"`.
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
    // An out-of-range slice is not guessed at but warned about as "unknown" (the whole screen is not failed).
    try testing.expectEqualStrings("Out of range", items[3].label);
    try testing.expect(std.mem.indexOf(u8, items[3].value, "unknown") != null);
    try testing.expect(items[3].warning);

    descriptor.deinit();
}

test "display formats date, duration, enum and chainId (a minimal hand-written descriptor)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Not a real registry file (a minimal descriptor to check individual display formats only).
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
