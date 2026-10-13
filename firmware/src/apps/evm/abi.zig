//! EVM ABI (Application Binary Interface) decoding and function selectors.
//!
//! Reference: https://docs.soliditylang.org/en/latest/abi-spec.html
//!
//! **Design policy (premises for clear signing)**
//! - Values shown on screen are taken only from **canonical encodings that follow the spec**.
//!   Extra data, out-of-range or out-of-order offsets, overflowing lengths and non-zero
//!   padding are all rejected (`error.InvalidEncoding` / `error.Truncated`). Ambiguous input is never displayed.
//! - A dynamic value requires its "head (offset word) + tail (actual data)" to be laid out
//!   **contiguously and in that order**. Only the shape Solidity emits is accepted.
//! - An array offset is relative to the **start of that aggregate's element head sequence**
//!   (right after the length word for a dynamic array, the start of the array itself for a fixed-size array).
//!   It is cross-checked against the example in the Solidity spec (`g(uint256[][],string[])`).
//! - `string` is not UTF-8 validated (returned as a byte sequence). The display side validates it.
//! - **tuple (struct) types are not decoded**. Their types are still parsed and included in
//!   selector computation (needed to match descriptors). Decoding will be added when required.
//! - Memory is allocated only for dynamic arrays and variable-length byte sequences. It comes from the
//!   caller's `allocator` (usually an `ArenaAllocator`) and the caller frees it.
//!
//! Some tests embed the official examples from the Solidity spec verbatim (no hand-written
//! expected values are used). Selectors are checked against Keccak-256 results and known constants.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");

/// Word size. ABI heads are in 32-byte units.
pub const word_size = 32;

/// Selector length (the first 4 bytes of `keccak256(signature)`).
pub const selector_len = 4;

/// An ABI type.
///
/// The element types of `fixed_array` and `array` recurse, so they are represented by a
/// pointer to an `AbiType` allocated on the allocator (built by `parseTypeList` / `parseFragment`).
pub const AbiType = union(enum) {
    /// Unsigned integer. Bit width (8..256, a multiple of 8).
    uint: u16,
    /// Signed integer. Bit width (8..256, a multiple of 8).
    int: u16,
    address,
    bool,
    /// `bytes<M>` (1..32). Static type.
    bytes_fixed: u16,
    /// Dynamic `bytes`.
    bytes,
    /// Dynamic `string`.
    string,
    /// Fixed-size array `T[k]`.
    fixed_array: Array,
    /// Dynamic array `T[]`.
    array: Array,

    pub const Array = struct {
        element: *const AbiType,
        /// `null` means dynamic length (`T[]`); a number means fixed length (`T[k]`).
        len: ?usize = null,
    };
};

/// A decode result.
///
/// `bytes` / `string` / `bytes_fixed` are **slices pointing into the input buffer**
/// (they are not copied). They must not outlive the input.
pub const Value = union(enum) {
    uint: u256,
    int: i256,
    address: [20]u8,
    boolean: bool,
    /// Both `bytes<M>` and dynamic `bytes`.
    bytes: []const u8,
    string: []const u8,
    fixed_array: []Value,
    array: []Value,
};

// ---------------------------------------------------------------- selectors

/// The first 4 bytes of calldata (the function selector). null if shorter than 4 bytes.
pub fn selector(calldata: []const u8) ?[selector_len]u8 {
    if (calldata.len < selector_len) return null;
    return calldata[0..selector_len].*;
}

/// Compute the selector from a types-only canonical signature (`transfer(address,uint256)`).
pub fn computeSelector(signature: []const u8) [selector_len]u8 {
    var digest: [32]u8 = undefined;
    hashes.Keccak256.hash(signature, &digest, .{});
    return digest[0..selector_len].*;
}

/// A known function (selector and argument types).
pub const Known = struct {
    /// Types-only canonical signature.
    signature: []const u8,
    /// Argument types.
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
    // ERC-2612 (EIP-2612 permit)
    .{
        .signature = "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
        .types = &[_]AbiType{ address_type, address_type, uint256_type, uint256_type, uint8_type, bytes32_type, bytes32_type },
    },
};

/// If the selector is a known function, return its signature and argument types.
///
/// null for unknown selectors (**never guess**).
pub fn knownFunction(sel: [selector_len]u8) ?Known {
    for (known_functions) |function| {
        const computed = computeSelector(function.signature);
        if (std.mem.eql(u8, &computed, &sel)) return function;
    }
    return null;
}

/// The list of known functions (for tests and the UI).
pub fn knownFunctions() []const Known {
    return &known_functions;
}

// ---------------------------------------------------------------- decoding

/// Decode the arguments.
///
/// `out.len` must be at least `types.len` (otherwise `error.BufferTooSmall`).
/// Writes to `out[0..types.len]`. Array elements are allocated from `allocator`.
///
/// Rejected conditions:
/// - `data` length is not a multiple of 32 / too short for the head area (`error.InvalidEncoding` / `error.Truncated`)
/// - a dynamic type's offset is not at the canonical position (out of order, duplicated, out of range)
/// - a dynamic array, `bytes` or `string` length overflows, or there is not enough data
/// - **extra data** remains after decoding
/// - non-canonical values (`bool` other than 0/1, upper bits of `uint<M>`, upper 12 bytes of `address`,
///   non-zero padding of `bytes<M>` or `bytes`, inconsistent sign extension of `int<M>`)
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
            // A dynamic type's head is a single offset word. Tails are expected to be laid out contiguously.
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

    // Extra data is not allowed.
    if (tail != data.len) return error.InvalidEncoding;
}

/// Whether the type is dynamic (i.e. becomes a single offset word in the parent's head).
pub fn isDynamic(t: AbiType) bool {
    return switch (t) {
        .bytes, .string, .array => true,
        .fixed_array => |a| isDynamic(a.element.*),
        else => false,
    };
}

/// Number of bytes this type occupies in the parent's head area.
///
/// A dynamic type is one offset word. A static type is the length of its own encoding (a fixed-size array is the sum of its elements).
fn headWords(t: AbiType) Error!usize {
    if (isDynamic(t)) return word_size;
    return switch (t) {
        .fixed_array => |a| try mulChecked(a.len orelse return error.InvalidEncoding, try headWords(a.element.*)),
        else => word_size,
    };
}

/// Decode a static value from the start of `data` (`data` points at the start of the value).
fn decodeStatic(t: AbiType, data: []const u8, out: *Value, allocator: std.mem.Allocator) Error!void {
    switch (t) {
        .uint => |bits| {
            const word = try readWord(data, 0);
            if (bits < 256) {
                // The upper (256-M) bits of `uint<M>` must be zero.
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
            const upper = word >> shift; // upper (256-M) bits
            // Sign extension must be consistent (if bit M-1 is 1, all upper bits are 1).
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
            // The upper 12 bytes must be zero.
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
                // The padding on the right must be zero.
                if (word & maskBytes(@intCast(32 - m)) != 0) return error.InvalidEncoding;
            }
            // `bytes<M>` is left-aligned in the word, so the first M bytes are the value (returns a slice of the input).
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
        .bytes, .string, .array => unreachable, // dynamic types are handled by decodeDynamic
    }
}

/// Decode a dynamic value from its own encoding (the start of `region`) and
/// return the number of bytes consumed.
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
            const end = try addChecked(word_size, padded);
            const content_end = try addChecked(word_size, len);
            if (end > region.len) return error.Truncated;
            const contents = region[word_size..content_end];
            // Padding must be zero.
            if (!allZero(region[content_end..end])) return error.InvalidEncoding;
            out.* = if (t == .string) .{ .string = contents } else .{ .bytes = contents };
            return end;
        },
        .array, .fixed_array => {
            const a = switch (t) {
                .array => |x| x,
                .fixed_array => |x| x,
                else => unreachable,
            };
            const element = a.element.*;

            // For a dynamic array the element head sequence starts right after the length word; for a fixed-size array it is the start of the array itself.
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
                    // The offset is relative to the start of the element head sequence (= base).
                    const offset = try toLength(try readWord(region, at));
                    if (offset != tail - base) return error.InvalidEncoding;
                    tail = try addChecked(tail, try decodeDynamic(element, region[base + offset ..], slot, allocator));
                    if (tail > region.len) return error.Truncated;
                } else {
                    try decodeStatic(element, region[at..], slot, allocator);
                }
            }

            out.* = if (t == .array) .{ .array = values } else .{ .fixed_array = values };
            // `tail` is the number of bytes consumed from the start of region (including the length word for a dynamic array).
            return tail;
        },
        else => unreachable,
    }
}

// ---------------------------------------------------------------- type parsing

/// The result of parsing a human-readable ABI fragment.
pub const Fragment = struct {
    /// Function name (e.g. `transfer`).
    name: []const u8,
    /// Types-only canonical signature (e.g. `transfer(address,uint256)`). The target of selector computation.
    signature: []const u8,
    /// Argument types. **null when a tuple (struct) is included** (only selector computation is possible).
    types: ?[]const AbiType,
    /// Top-level argument names. An argument without a name is the empty string.
    names: []const []const u8,
};

/// Parse a fragment such as `transfer(address _to, uint256 _value)`.
///
/// ERC-7730 `display.formats` keys have this shape (type name + argument name).
/// It normalizes to the types-only canonical form (`transfer(address,uint256)`), so it
/// does not depend on whitespace or on the `uint` / `int` aliases (normalized to `uint256` / `int256`).
/// Tuples are accepted both as `(address,uint256)` and as `tuple(address,uint256)`.
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
            // Argument names are optional (omitted in the canonical form).
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

    // Build the types-only canonical signature.
    var signature = std.ArrayList(u8).empty;
    defer signature.deinit(allocator);
    try signature.appendSlice(allocator, name);
    try signature.append(allocator, '(');
    for (nodes.items, 0..) |node, i| {
        if (i != 0) try signature.append(allocator, ',');
        try printType(allocator, node, &signature);
    }
    try signature.append(allocator, ')');

    // Convert to decodable types (null if a tuple is included).
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

/// Parse a comma-separated type list (`address,uint256`). Tuples are not accepted.
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

/// Type syntax tree. Kept separately because it cannot always be lowered to `AbiType` (it may contain tuples).
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

    /// Parse a single type (including array suffixes).
    fn parseType(self: *Parser) Error!*const TypeNode {
        self.skipSpace();
        var node = try self.parseBaseType();
        // Array suffixes (`[]` / `[N]`) can be repeated (e.g. `T[][2]`).
        while (true) {
            self.skipSpace();
            if (self.peek() != '[') break;
            self.pos += 1;
            var len: ?usize = null;
            if (self.peek() != ']') {
                const digits = try self.parseDigits();
                const parsed = std.fmt.parseInt(usize, digits, 10) catch return error.InvalidEncoding;
                if (parsed == 0) return error.InvalidEncoding;
                len = parsed;
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

    /// Parse the body of a tuple right after `(` (`(` has already been consumed).
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
                // Argument names inside a tuple are not used for display, so they are skipped.
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

/// Validate `<M>` (bit width) of `uint<M>` / `int<M>`. An empty string means 256.
fn parseSized(digits: []const u8, min: u16, max: u16) Error!u16 {
    if (digits.len == 0) return max; // `uint` → 256
    const value = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidEncoding;
    if (value < min or value > max) return error.InvalidEncoding;
    if (value % 8 != 0) return error.InvalidEncoding; // the bit width must be a multiple of 8
    return value;
}

/// Validate `<M>` (byte width) of `bytes<M>`.
fn parseByteSized(digits: []const u8) Error!u16 {
    const value = std.fmt.parseInt(u16, digits, 10) catch return error.InvalidEncoding;
    if (value < 1 or value > 32) return error.InvalidEncoding;
    return value;
}

/// Print the canonical form (types only, no whitespace).
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

/// Print a prefix plus bit width / byte width, as in `uint256`.
fn appendSized(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prefix: []const u8, value: u16) Error!void {
    var buffer: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{s}{d}", .{ prefix, value }) catch return error.BufferTooSmall;
    try out.appendSlice(allocator, text);
}

/// Convert the syntax tree to decodable types. null if a tuple is included.
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

// ---------------------------------------------------------------- helpers

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

/// Read a 32-byte word as big-endian.
fn readWord(data: []const u8, at: usize) Error!u256 {
    if (at > data.len or data.len - at < word_size) return error.Truncated;
    return std.mem.readInt(u256, data[at..][0..word_size], .big);
}

/// Narrow a length word to `usize`. Out of range is rejected as an "overflowing length".
fn toLength(word: u256) Error!usize {
    if (word > std.math.maxInt(usize)) return error.InvalidEncoding;
    return @intCast(word);
}

/// The padded length of `bytes` / `string`. Rejected if it overflows.
fn paddedLength(len: usize) Error!usize {
    const words = try addChecked(len, word_size - 1);
    return mulChecked(words / word_size, word_size);
}

/// Mask with the low `bits` bits set.
fn maskBits(bits: u16) u256 {
    if (bits >= 256) return std.math.maxInt(u256);
    return (@as(u256, 1) << @intCast(bits)) - 1;
}

/// Mask with the low `bytes` bytes set (up to 32 bytes).
fn maskBytes(bytes: u8) u256 {
    return maskBits(@as(u16, bytes) * 8);
}

fn allZero(data: []const u8) bool {
    for (data) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Turn a hex string into bytes (for tests).
fn hexToBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

test "the function selector is the first 4 bytes of Keccak-256" {
    // The expected values are known constants widely used by EVM specs and implementations.
    // Here we check that they match the Keccak-256 computation (we do not trust our own constants).
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

test "a known function selector yields its signature and argument types" {
    const transfer = knownFunction(hexToBytes(4, "a9059cbb")).?;
    try testing.expectEqualStrings("transfer(address,uint256)", transfer.signature);
    try testing.expectEqual(@as(usize, 2), transfer.types.len);
    try testing.expectEqual(@as(u16, 256), transfer.types[1].uint);

    const permit = knownFunction(hexToBytes(4, "d505accf")).?;
    try testing.expectEqual(@as(usize, 7), permit.types.len);
    try testing.expectEqual(@as(u16, 8), permit.types[4].uint);
    try testing.expectEqual(@as(u16, 32), permit.types[5].bytes_fixed);

    // Unknown selectors are not guessed.
    try testing.expect(knownFunction(hexToBytes(4, "deadbeef")) == null);
    try testing.expect(knownFunction(hexToBytes(4, "00000000")) == null);
}

test "the first 4 bytes of calldata are taken as the selector" {
    const calldata = hexToBytes(68, "a9059cbb0000000000000000000000005aaeb6053f3e94c9b9a09f33669435e7ef1beaed00000000000000000000000000000000000000000000000000000000000003e8");
    try testing.expectEqualSlices(u8, &hexToBytes(4, "a9059cbb"), &selector(&calldata).?);
    try testing.expect(selector(&[_]u8{ 1, 2, 3 }) == null);
    try testing.expect(selector(&[_]u8{}) == null);
}

test "decodes ERC-20 transfer calldata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A realistic calldata shape (selector + no remainder shorter than 4 bytes).
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

test "decodes the g(uint256[][],string[]) example from the Solidity spec" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Embed the example from https://docs.soliditylang.org/en/latest/abi-spec.html verbatim.
    // g([[1, 2], [3]], ["one", "two", "three"])
    const blob = hexToBytes(640, "0000000000000000000000000000000000000000000000000000000000000040" ++
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

test "decodes fixed-size arrays, bytes, bool, int and bytes32" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // bytes4 is left-aligned, bool is 1, int8 is -1 (sign-extended), bytes32 is all bits.
    // The head is 4 words plus the dynamic array's offset word. The tail (the length word of `bytes3[]`) follows at the end.
    const data = hexToBytes(32 * 6, "deadbeef00000000000000000000000000000000000000000000000000000000" ++
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
    // The dynamic array `bytes3[]` has length 0 (an offset in the head, a length word in the tail).
    try testing.expectEqual(@as(usize, 0), values[3].array.len);
    const full = hexToBytes(32, "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20");
    try testing.expectEqualSlices(u8, &full, values[4].bytes);
}

test "decodes a sequence of static types without offsets (values only)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `uint8[2]` uses two words as one head.
    const data = hexToBytes(32 * 4, "0000000000000000000000000000000000000000000000000000000000000007" ++
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

test "a fixed-size array (with dynamic elements) has offsets relative to the start of the array itself" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // One argument whose element is string[2] = ["a", "b"] (`f(string[2])`).
    // The offset of a fixed-size array is relative to "the start of the array itself".
    const data = hexToBytes(32 * 7, "0000000000000000000000000000000000000000000000000000000000000020" ++
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

test "decodes calldata generated by an independent implementation (ethers 6.17.0)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The expected values come from ethers 6.17.0's AbiCoder.encode (not hand-written expected values).
    // h(bytes,uint8[2],string,bytes4,int256,bool) = (0xdeadbeef, [7,8], "hello", 0x01020304, -12345, false)
    const h_data = hexToBytes(352, "00000000000000000000000000000000000000000000000000000000000000e0" ++
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
    const k_data = hexToBytes(320, "0000000000000000000000000000000000000000000000000000000000000040" ++
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

    // The selector also matches the independent implementation.
    try testing.expectEqualSlices(u8, &hexToBytes(4, "397db75c"), &computeSelector("h(bytes,uint8[2],string,bytes4,int256,bool)"));
    try testing.expectEqualSlices(u8, &hexToBytes(4, "37e133c7"), &computeSelector("k(bytes32[],uint16[2][])"));
}

test "rejects non-canonical encodings" {
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

    // not a multiple of 32
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint256, &hexToBytes(31, "00000000000000000000000000000000000000000000000000000000000000"), &value));
    // truncated (a multiple of 32, but too short for the head)
    try testing.expectError(error.Truncated, decodeParameters(allocator, two_uint256, &hexToBytes(32, "0000000000000000000000000000000000000000000000000000000000000001"), &two_values));
    // extra data
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint256, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002"), &value));
    // output buffer too small
    var empty: [0]Value = undefined;
    try testing.expectError(error.BufferTooSmall, decodeParameters(allocator, uint256, &[_]u8{}, &empty));

    // upper bits of uint8 are non-zero (not canonical)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, uint8_arg, &hexToBytes(32, "0000000000000000000000000000000000000000000000000000000000000101"), &value));
    // upper 12 bytes of address are non-zero
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, address_arg, &hexToBytes(32, "0000000000000000000000010000000000000000000000000000000000000001"), &value));
    // bool is 2
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bool_arg, &hexToBytes(32, "0000000000000000000000000000000000000000000000000000000000000002"), &value));
    // padding of bytes4 is non-zero
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes4_arg, &hexToBytes(32, "deadbeef000000000000000000000000000000000000000000000000000000ff"), &value));

    // dynamic type: offset out of range
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000040" ++
        "0000000000000000000000000000000000000000000000000000000000000000"), &value));
    // dynamic type: offset is not at the canonical position (it points at the start)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000000" ++
        "0000000000000000000000000000000000000000000000000000000000000000"), &value));

    // bytes: the length overflows (it does not fit in `usize`)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), &value));
    // bytes: shorter than the actual length (truncated)
    try testing.expectError(error.Truncated, decodeParameters(allocator, bytes_arg, &hexToBytes(96, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000021" ++
        "0000000000000000000000000000000000000000000000000000000000000000"), &value));
    // bytes: the length is sufficient but the padding is non-zero (1 byte of value + non-zero filler)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, bytes_arg, &hexToBytes(96, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "00ff000000000000000000000000000000000000000000000000000000000000"), &value));

    // dynamic array: too many elements (not enough data)
    try testing.expectError(error.Truncated, decodeParameters(allocator, array_arg, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000040"), &value));
    // dynamic array: the element count overflows (it does not fit in `usize`)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, array_arg, &hexToBytes(64, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"), &value));
    // dynamic array: the element offset is not at the canonical position (`uint256[]` has static elements,
    // so with a single element an extra word remains and it is rejected at the end)
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, array_arg, &hexToBytes(128, "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000002"), &value));

    // dynamic array (dynamic elements): the element offset does not point at the start of the tail
    const nested = try parseTypeList(allocator, "bytes[],bytes[]");
    try testing.expectError(error.InvalidEncoding, decodeParameters(allocator, nested, &hexToBytes(160, "0000000000000000000000000000000000000000000000000000000000000040" ++
        "00000000000000000000000000000000000000000000000000000000000000c0" ++
        "0000000000000000000000000000000000000000000000000000000000000001" ++
        "0000000000000000000000000000000000000000000000000000000000000020" ++
        "0000000000000000000000000000000000000000000000000000000000000000"), &two_values));
}

test "converts a human-readable ABI fragment to the canonical form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Independent of whitespace placement (spaces after commas).
    const transfer = try parseFragment(allocator, "transfer(address _to, uint256 _value)");
    try testing.expectEqualStrings("transfer", transfer.name);
    try testing.expectEqualStrings("transfer(address,uint256)", transfer.signature);
    try testing.expectEqual(@as(usize, 2), transfer.names.len);
    try testing.expectEqualStrings("_to", transfer.names[0]);
    try testing.expectEqualStrings("_value", transfer.names[1]);
    try testing.expectEqualSlices(u8, &hexToBytes(4, "a9059cbb"), &computeSelector(transfer.signature));

    // A canonical form without argument names, the `uint` → `uint256` alias, and arrays.
    const canonical = try parseFragment(allocator, "airdrop(address[],uint)");
    try testing.expectEqualStrings("airdrop(address[],uint256)", canonical.signature);
    try testing.expectEqual(@as(usize, 2), canonical.types.?.len);
    try testing.expect(isDynamic(canonical.types.?[0]));
    try testing.expectEqual(@as(usize, 256), canonical.types.?[1].uint);

    // Fixed-size arrays and nested arrays.
    const nested = try parseFragment(allocator, "f(uint16[3][],bytes32)");
    try testing.expectEqualStrings("f(uint16[3][],bytes32)", nested.signature);
    try testing.expectEqual(@as(usize, 3), nested.types.?[0].array.element.fixed_array.len);

    // For tuples only the selector is computed; no decodable type is created.
    const tuple = try parseFragment(
        allocator,
        "submitOrder((address token,uint256 amount) order,bytes32 salt)",
    );
    try testing.expectEqualStrings("submitOrder((address,uint256),bytes32)", tuple.signature);
    try testing.expect(tuple.types == null);
    try testing.expectEqualStrings("order", tuple.names[0]);
    try testing.expectEqualStrings("salt", tuple.names[1]);
}

test "rejects malformed fragments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bad = [_][]const u8{
        "transfer(address,uint256", // missing closing parenthesis
        "transfer(address,)", // empty argument
        "transfer(uint7)", // not a multiple of 8
        "transfer(uint264)", // greater than 256
        "transfer(bytes33)", // greater than 32
        "transfer(function)", // unsupported type
        "transfer(uint256)extra", // extra characters
        "transfer(address[)", // malformed array notation
        "transfer", // no argument list
        "transfer(address))", // extra closing parenthesis
    };
    for (bad) |text| {
        try testing.expectError(error.InvalidEncoding, parseFragment(allocator, text));
    }
}
