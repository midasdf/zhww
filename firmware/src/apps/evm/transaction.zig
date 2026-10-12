//! Ethereum transaction signing (EIP-155 legacy and EIP-1559 type 2).
//!
//! **Signing hash**
//! - legacy: `keccak256(RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))`
//! - 1559  : `keccak256(0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
//!                                  gasLimit, to, value, data, accessList]))`
//!
//! **Signed transaction**
//! - legacy: `RLP([nonce, gasPrice, gasLimit, to, value, data, v, r, s])`, `v = chainId * 2 + 35 + yParity`
//! - 1559  : `0x02 || RLP([... , yParity, r, s])`
//!
//! **Design policy**
//! - **No memory allocation.** So that the key-handling path cannot raise `OutOfMemory`,
//!   the caller provides the output buffer (too small a buffer gives `error.BufferTooSmall`).
//! - Because a list length must be written into the header, the same field-writing code is
//!   first run through `MeasureSink` to measure the length. This structurally prevents hash
//!   mismatches from hand-computed lengths (the field order is defined in exactly one place).
//! - Signing uses only audited libsecp256k1, and **every signature is verified before it is returned**.
//! - pre-EIP-155 (`v = 27/28`) is not supported. It is deliberately unsupported because it
//!   would allow replay attacks.
//!
//! References: https://eips.ethereum.org/EIPS/eip-155
//!             https://eips.ethereum.org/EIPS/eip-1559
//!             https://eips.ethereum.org/EIPS/eip-2718
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const rlp = @import("rlp.zig");

/// Leading byte that marks EIP-2718 type 2 (EIP-1559).
pub const transaction_type_eip1559: u8 = 0x02;

/// Fields of an EIP-155 (legacy) transaction.
pub const LegacyTx = struct {
    nonce: u256,
    gas_price: u256,
    gas_limit: u256,
    /// Destination. null means contract creation (encoded as the empty string).
    to: ?[20]u8,
    value: u256,
    data: []const u8,
    /// EIP-155 chain ID. It yields `v = chain_id * 2 + 35 + yParity`.
    chain_id: u256,
};

/// An EIP-2930 access list item (also used by EIP-1559).
pub const AccessListItem = struct {
    address: [20]u8,
    storage_keys: []const [32]u8,
};

/// Fields of an EIP-1559 (type 2) transaction.
pub const Eip1559Tx = struct {
    chain_id: u256,
    nonce: u256,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u256,
    /// Destination. null means contract creation.
    to: ?[20]u8,
    value: u256,
    data: []const u8,
    access_list: []const AccessListItem = &.{},
};

// ---------------------------------------------------------------- RLP sinks
//
// A small interface (`uint` / `bytes` / `listHeader`) that lets the same field-order code
// serve the three modes: measure the length, feed the hash, and write to a buffer.

/// Counts only the encoded length.
const MeasureSink = struct {
    written: usize = 0,

    fn uint(self: *MeasureSink, value: u256) Error!void {
        var buf: [33]u8 = undefined;
        self.written = try addLen(self.written, (try rlp.encodeUint(&buf, value)).len);
    }

    fn bytes(self: *MeasureSink, data: []const u8) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        const header = try rlp.encodeBytesHeader(&header_buf, data);
        self.written = try addLen(self.written, header.len + data.len);
    }

    fn listHeader(self: *MeasureSink, payload_len: usize) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        self.written = try addLen(self.written, (try rlp.encodeListHeader(&header_buf, payload_len)).len);
    }
};

/// Feeds Keccak-256.
const HashSink = struct {
    hasher: *hashes.Keccak256,

    fn uint(self: HashSink, value: u256) Error!void {
        var buf: [33]u8 = undefined;
        self.hasher.update(try rlp.encodeUint(&buf, value));
    }

    fn bytes(self: HashSink, data: []const u8) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        const header = try rlp.encodeBytesHeader(&header_buf, data);
        // When the header is empty (a single byte < 0x80), write only the body
        if (header.len != 0) self.hasher.update(header);
        self.hasher.update(data);
    }

    fn listHeader(self: HashSink, payload_len: usize) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        self.hasher.update(try rlp.encodeListHeader(&header_buf, payload_len));
    }
};

/// Writes to the output buffer.
const SliceSink = struct {
    out: []u8,
    pos: usize = 0,

    fn uint(self: *SliceSink, value: u256) Error!void {
        self.pos += (try rlp.encodeUint(self.out[self.pos..], value)).len;
    }

    fn bytes(self: *SliceSink, data: []const u8) Error!void {
        self.pos += (try rlp.encodeBytes(self.out[self.pos..], data)).len;
    }

    fn listHeader(self: *SliceSink, payload_len: usize) Error!void {
        self.pos += (try rlp.encodeListHeader(self.out[self.pos..], payload_len)).len;
    }
};

/// Adds lengths. Overflow is rejected as "does not fit in the buffer".
fn addLen(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.BufferTooSmall;
}

// ---------------------------------------------------------------- fields
//
// The field order is defined here and nowhere else (shared by measuring, hashing, serialization).

/// The `to` field. The empty string for contract creation.
fn writeTo(sink: anytype, to: ?[20]u8) Error!void {
    if (to) |address| {
        var bytes = address;
        try sink.bytes(&bytes);
    } else {
        try sink.bytes(&.{});
    }
}

/// The common legacy part (nonce, gasPrice, gasLimit, to, value, data).
fn writeLegacyFields(tx: LegacyTx, sink: anytype) Error!void {
    try sink.uint(tx.nonce);
    try sink.uint(tx.gas_price);
    try sink.uint(tx.gas_limit);
    try writeTo(sink, tx.to);
    try sink.uint(tx.value);
    try sink.bytes(tx.data);
}

/// EIP-155 signing payload (9 elements, with chainId, 0, 0 appended).
fn writeLegacySigningFields(tx: LegacyTx, sink: anytype) Error!void {
    try writeLegacyFields(tx, sink);
    try sink.uint(tx.chain_id);
    try sink.uint(0);
    try sink.uint(0);
}

/// EIP-155 signed form (9 elements, with v, r, s appended).
fn writeLegacySignedFields(value: LegacySignedFields, sink: anytype) Error!void {
    try writeLegacyFields(value.tx, sink);
    try sink.uint(value.v);
    try sink.uint(value.r);
    try sink.uint(value.s);
}

/// Input to `writeLegacySignedFields`.
const LegacySignedFields = struct { tx: LegacyTx, v: u256, r: u256, s: u256 };

/// Body of one access list item (an address and a list of storage keys).
fn writeAccessListItem(item: AccessListItem, sink: anytype) Error!void {
    var address = item.address;
    try sink.bytes(&address);

    // The storage key list ([32 bytes, ...])
    var keys_measure = MeasureSink{};
    for (item.storage_keys) |key| {
        var bytes = key;
        try keys_measure.bytes(&bytes);
    }
    try sink.listHeader(keys_measure.written);
    for (item.storage_keys) |key| {
        var bytes = key;
        try sink.bytes(&bytes);
    }
}

/// The whole access list (a list of items).
fn writeAccessList(access_list: []const AccessListItem, sink: anytype) Error!void {
    // 1) Measure: each item is "item list header + body"
    var measure = MeasureSink{};
    for (access_list) |item| {
        var item_measure = MeasureSink{};
        try writeAccessListItem(item, &item_measure);
        try measure.listHeader(item_measure.written);
        try writeAccessListItem(item, &measure);
    }

    // 2) Write the header with the measured length, then write the body
    try sink.listHeader(measure.written);
    for (access_list) |item| {
        var item_measure = MeasureSink{};
        try writeAccessListItem(item, &item_measure);
        try sink.listHeader(item_measure.written);
        try writeAccessListItem(item, sink);
    }
}

/// The common EIP-1559 part
/// (chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList).
fn writeEip1559Fields(tx: Eip1559Tx, sink: anytype) Error!void {
    try sink.uint(tx.chain_id);
    try sink.uint(tx.nonce);
    try sink.uint(tx.max_priority_fee_per_gas);
    try sink.uint(tx.max_fee_per_gas);
    try sink.uint(tx.gas_limit);
    try writeTo(sink, tx.to);
    try sink.uint(tx.value);
    try sink.bytes(tx.data);
    try writeAccessList(tx.access_list, sink);
}

/// EIP-1559 signed form (12 elements, with yParity, r, s appended).
fn writeEip1559SignedFields(value: Eip1559SignedFields, sink: anytype) Error!void {
    try writeEip1559Fields(value.tx, sink);
    try sink.uint(value.y_parity);
    try sink.uint(value.r);
    try sink.uint(value.s);
}

/// Input to `writeEip1559SignedFields`.
const Eip1559SignedFields = struct { tx: Eip1559Tx, y_parity: u1, r: u256, s: u256 };

/// Writes a group of fields to `out` as a single RLP list.
///
/// First it measures the length with `MeasureSink`, writes the list header with that length,
/// then writes the body. Finally it checks measured against written length (internal check).
fn encodeListWith(comptime writeFields: anytype, value: anytype, out: []u8) Error![]u8 {
    var measure = MeasureSink{};
    try writeFields(value, &measure);

    const header = try rlp.encodeListHeader(out, measure.written);
    var sink = SliceSink{ .out = out[header.len..] };
    try writeFields(value, &sink);
    if (sink.pos != measure.written) return error.InvalidEncoding;

    return out[0 .. header.len + sink.pos];
}

/// Writes an EIP-2718 typed transaction (`0x02 || RLP(...)`) to `out`.
fn encodeTypedListWith(comptime writeFields: anytype, value: anytype, out: []u8) Error![]u8 {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = transaction_type_eip1559;
    const body = try encodeListWith(writeFields, value, out[1..]);
    return out[0 .. 1 + body.len];
}

// ---------------------------------------------------------------- signing payload

/// Writes the EIP-155 signing payload (a 9-element RLP list) to `out`.
pub fn legacySigningPayload(out: []u8, tx: LegacyTx) Error![]u8 {
    return encodeListWith(writeLegacySigningFields, tx, out);
}

/// EIP-155 signing payload hash.
pub fn legacySigningHash(tx: LegacyTx) Error![32]u8 {
    var measure = MeasureSink{};
    try writeLegacySigningFields(tx, &measure);

    var hasher = hashes.Keccak256.init(.{});
    var header_buf: [rlp.max_header_len]u8 = undefined;
    hasher.update(try rlp.encodeListHeader(&header_buf, measure.written));
    try writeLegacySigningFields(tx, HashSink{ .hasher = &hasher });

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

/// Writes the EIP-1559 signing payload (`0x02 || RLP(...)`) to `out`.
pub fn eip1559SigningPayload(out: []u8, tx: Eip1559Tx) Error![]u8 {
    return encodeTypedListWith(writeEip1559Fields, tx, out);
}

/// EIP-1559 signing payload hash.
pub fn eip1559SigningHash(tx: Eip1559Tx) Error![32]u8 {
    var measure = MeasureSink{};
    try writeEip1559Fields(tx, &measure);

    var hasher = hashes.Keccak256.init(.{});
    hasher.update(&[_]u8{transaction_type_eip1559});
    var header_buf: [rlp.max_header_len]u8 = undefined;
    hasher.update(try rlp.encodeListHeader(&header_buf, measure.written));
    try writeEip1559Fields(tx, HashSink{ .hasher = &hasher });

    var hash: [32]u8 = undefined;
    hasher.final(&hash);
    return hash;
}

// ---------------------------------------------------------------- signing

/// EIP-155 `v`. `v = chain_id * 2 + 35 + yParity`.
pub fn legacyV(chain_id: u256, y_parity: u1) Error!u256 {
    // No chain ID makes v overflow u256, but it is rejected before the computation
    // (the bound that still fits after adding 35 and the maximum yParity of 1).
    const max_chain_id = (std.math.maxInt(u256) - 36) / 2;
    if (chain_id > max_chain_id) return error.InvalidEncoding;
    return chain_id * 2 + 35 + y_parity;
}

/// Components of an ECDSA signature.
pub const Signature = struct {
    /// `r` (32 bytes, big-endian).
    r: u256,
    /// `s` (32 bytes, big-endian; low-s as required by EIP-2).
    s: u256,
    /// Parity of the `y` coordinate. Used for legacy `v` and EIP-1559 `yParity`.
    y_parity: u1,
};

// libsecp256k1 recoverable signatures.
//
// **Note**: `data[64]` of `secp256k1_ecdsa_signature` is an internal representation, not
// big-endian r || s (the header explicitly calls it an "opaque type" too).
// Indeed, in libsecp256k1 0.8.0 on this environment each scalar is stored little-endian.
// r || s and the recovery id are obtained from `core.crypto.secp256k1.signRecoverable`
// (the extern declarations for libsecp256k1 are consolidated in core).

/// Signs a hash and returns `r` / `s` / `y_parity`. **The signature is verified before returning.**
fn signHash(hash: [32]u8, priv: [32]u8) Error!Signature {
    if (!secp256k1.isValidPrivateKey(priv)) return error.InvalidKey;

    const result = try secp256k1.signRecoverable(hash, priv);
    const signature = Signature{
        .r = std.mem.readInt(u256, result.compact[0..32], .big),
        .s = std.mem.readInt(u256, result.compact[32..64], .big),
        .y_parity = @intCast(result.recovery_id),
    };

    // EIP-2: a transaction's s must be low-s
    if (signature.s > secp256k1.curve_order / 2) return error.SignatureInvalid;

    // Always verify the signature (to catch implementation mistakes)
    const parsed = try secp256k1.parseCompact(result.compact);
    if (!try secp256k1.verify(&parsed, hash, try secp256k1.pubKeyCompressed(priv))) {
        return error.SignatureInvalid;
    }
    return signature;
}

/// Signs an EIP-155 (legacy) transaction and writes the signed raw tx to `out`.
pub fn signLegacy(out: []u8, tx: LegacyTx, priv: [32]u8) Error![]u8 {
    const signature = try signHash(try legacySigningHash(tx), priv);
    return encodeLegacySigned(out, tx, try legacyV(tx.chain_id, signature.y_parity), signature.r, signature.s);
}

/// Signs an EIP-1559 (type 2) transaction and writes the signed raw tx to `out`.
pub fn signEip1559(out: []u8, tx: Eip1559Tx, priv: [32]u8) Error![]u8 {
    if (tx.max_priority_fee_per_gas > tx.max_fee_per_gas) return error.InvalidEncoding;
    const signature = try signHash(try eip1559SigningHash(tx), priv);
    return encodeEip1559Signed(out, tx, signature.y_parity, signature.r, signature.s);
}

/// Assembles an EIP-155 signed raw tx from externally produced signature components
/// (used for hardware signer integration and for checking against official test vectors).
pub fn encodeLegacySigned(out: []u8, tx: LegacyTx, v: u256, r: u256, s: u256) Error![]u8 {
    return encodeListWith(writeLegacySignedFields, LegacySignedFields{ .tx = tx, .v = v, .r = r, .s = s }, out);
}

/// Assembles an EIP-1559 signed raw tx from externally produced signature components.
pub fn encodeEip1559Signed(out: []u8, tx: Eip1559Tx, y_parity: u1, r: u256, s: u256) Error![]u8 {
    return encodeTypedListWith(
        writeEip1559SignedFields,
        Eip1559SignedFields{ .tx = tx, .y_parity = y_parity, .r = r, .s = s },
        out,
    );
}

// ---------------------------------------------------------------- display decoding

/// Transaction kind.
pub const Kind = enum { legacy, eip2930, eip1559 };

/// A transaction decoded for display.
///
/// Both signed and unsigned transactions can be decoded (unsigned gives `signed = false`).
/// Fields without a value are null (broken input is not filled in by guessing).
pub const Decoded = struct {
    kind: Kind,
    chain_id: ?u256 = null,
    nonce: ?u256 = null,
    to: ?[20]u8 = null,
    value: ?u256 = null,
    data: []const u8 = &.{},
    gas_limit: ?u256 = null,
    gas_price: ?u256 = null,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    signed: bool = false,
};

/// Decodes a raw transaction (signed or unsigned).
pub fn decode(allocator: std.mem.Allocator, raw: []const u8) Error!Decoded {
    if (raw.len == 0) return error.Truncated;
    return switch (raw[0]) {
        transaction_type_eip1559 => try decodeTyped(allocator, .eip1559, raw[1..]),
        0x01 => try decodeTyped(allocator, .eip2930, raw[1..]),
        else => try decodeLegacy(allocator, raw),
    };
}

const TopLevelItem = union(enum) {
    bytes: []const u8,
    list: []const u8,
};

/// Collect the items directly under a list while retaining nested lists as one typed item.
/// Silently dropping access-list items shifts every later field and can make a decoder display
/// a transaction different from the one represented by the RLP.
fn topLevelItems(allocator: std.mem.Allocator, payload: []const u8) Error![]const TopLevelItem {
    var items = std.ArrayList(TopLevelItem).empty;
    errdefer items.deinit(allocator);

    var iterator = rlp.Iterator.open(payload);
    var depth: usize = 0;
    while (try iterator.next()) |item| {
        switch (item) {
            .bytes => |bytes| {
                if (depth == 0) try items.append(allocator, .{ .bytes = bytes });
            },
            .list => |list_payload| {
                if (depth == 0) try items.append(allocator, .{ .list = list_payload });
                depth += 1;
            },
            .list_end => {
                if (depth == 0) return error.InvalidEncoding;
                depth -= 1;
            },
        }
    }
    if (depth != 0) return error.InvalidEncoding;
    try iterator.finish();
    return items.toOwnedSlice(allocator);
}

fn bytesOf(item: TopLevelItem) Error![]const u8 {
    return switch (item) {
        .bytes => |bytes| bytes,
        .list => error.InvalidEncoding,
    };
}

fn listOf(item: TopLevelItem) Error![]const u8 {
    return switch (item) {
        .list => |payload| payload,
        .bytes => error.InvalidEncoding,
    };
}

fn validateSignature(r_payload: []const u8, s_payload: []const u8) Error!void {
    const r = try rlp.decodeUintPayload(r_payload);
    const s = try rlp.decodeUintPayload(s_payload);
    if (r == 0 or r >= secp256k1.curve_order or s == 0 or s > secp256k1.curve_order / 2) {
        return error.InvalidEncoding;
    }
}

fn validateAccessList(allocator: std.mem.Allocator, item: TopLevelItem) Error!void {
    const entries = try topLevelItems(allocator, try listOf(item));
    for (entries) |entry| {
        const fields = try topLevelItems(allocator, try listOf(entry));
        if (fields.len != 2) return error.InvalidEncoding;
        if ((try bytesOf(fields[0])).len != 20) return error.InvalidEncoding;
        const keys = try topLevelItems(allocator, try listOf(fields[1]));
        for (keys) |key| {
            if ((try bytesOf(key)).len != 32) return error.InvalidEncoding;
        }
    }
}

/// A 20-byte address. Empty means contract creation (null).
fn payloadToAddress(payload: []const u8) Error!?[20]u8 {
    if (payload.len == 0) return null;
    if (payload.len != 20) return error.InvalidEncoding;
    return payload[0..20].*;
}

fn decodeLegacy(allocator: std.mem.Allocator, raw: []const u8) Error!Decoded {
    const payload = try rlp.decodeList(raw);
    const items = try topLevelItems(allocator, payload);
    if (items.len != 6 and items.len != 9) return error.InvalidEncoding;

    var decoded = Decoded{ .kind = .legacy };
    decoded.nonce = try rlp.decodeUintPayload(try bytesOf(items[0]));
    decoded.gas_price = try rlp.decodeUintPayload(try bytesOf(items[1]));
    decoded.gas_limit = try rlp.decodeUintPayload(try bytesOf(items[2]));
    decoded.to = try payloadToAddress(try bytesOf(items[3]));
    decoded.value = try rlp.decodeUintPayload(try bytesOf(items[4]));
    decoded.data = try bytesOf(items[5]);

    // A signed EIP-155 transaction continues with v, r, s. Pre-EIP-155 27/28 signatures
    // are deliberately rejected because this project does not sign or endorse replayable txs.
    if (items.len == 9) {
        const v = try rlp.decodeUintPayload(try bytesOf(items[6]));
        if (v < 35) return error.InvalidEncoding;
        try validateSignature(try bytesOf(items[7]), try bytesOf(items[8]));
        decoded.signed = true;
        decoded.chain_id = (v - 35) / 2;
    }
    return decoded;
}

fn decodeTyped(
    allocator: std.mem.Allocator,
    kind: Kind,
    payload_with_list: []const u8,
) Error!Decoded {
    const payload = try rlp.decodeList(payload_with_list);
    const items = try topLevelItems(allocator, payload);

    var decoded = Decoded{ .kind = kind };
    switch (kind) {
        .eip1559 => {
            if (items.len != 9 and items.len != 12) return error.InvalidEncoding;
            decoded.chain_id = try rlp.decodeUintPayload(try bytesOf(items[0]));
            decoded.nonce = try rlp.decodeUintPayload(try bytesOf(items[1]));
            decoded.max_priority_fee_per_gas = try rlp.decodeUintPayload(try bytesOf(items[2]));
            decoded.max_fee_per_gas = try rlp.decodeUintPayload(try bytesOf(items[3]));
            if (decoded.max_priority_fee_per_gas.? > decoded.max_fee_per_gas.?) return error.InvalidEncoding;
            decoded.gas_limit = try rlp.decodeUintPayload(try bytesOf(items[4]));
            decoded.to = try payloadToAddress(try bytesOf(items[5]));
            decoded.value = try rlp.decodeUintPayload(try bytesOf(items[6]));
            decoded.data = try bytesOf(items[7]);
            try validateAccessList(allocator, items[8]);
            if (items.len == 12) {
                const parity = try rlp.decodeUintPayload(try bytesOf(items[9]));
                if (parity > 1) return error.InvalidEncoding;
                try validateSignature(try bytesOf(items[10]), try bytesOf(items[11]));
                decoded.signed = true;
            }
        },
        .eip2930 => {
            if (items.len != 8 and items.len != 11) return error.InvalidEncoding;
            decoded.chain_id = try rlp.decodeUintPayload(try bytesOf(items[0]));
            decoded.nonce = try rlp.decodeUintPayload(try bytesOf(items[1]));
            decoded.gas_price = try rlp.decodeUintPayload(try bytesOf(items[2]));
            decoded.gas_limit = try rlp.decodeUintPayload(try bytesOf(items[3]));
            decoded.to = try payloadToAddress(try bytesOf(items[4]));
            decoded.value = try rlp.decodeUintPayload(try bytesOf(items[5]));
            decoded.data = try bytesOf(items[6]);
            try validateAccessList(allocator, items[7]);
            if (items.len == 11) {
                const parity = try rlp.decodeUintPayload(try bytesOf(items[8]));
                if (parity > 1) return error.InvalidEncoding;
                try validateSignature(try bytesOf(items[9]), try bytesOf(items[10]));
                decoded.signed = true;
            }
        },
        .legacy => unreachable,
    }
    return decoded;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn hexBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

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

test "EIP-155 official example (signing payload, signing hash, and signed tx match byte for byte)" {
    // The Example from https://eips.ethereum.org/EIPS/eip-155.
    // nonce=9, gasPrice=20 gwei, gasLimit=21000, to=0x3535...35, value=1 ether, chainId=1.
    const tx = LegacyTx{
        .nonce = 9,
        .gas_price = 20000000000,
        .gas_limit = 21000,
        .to = hexBytes(20, "3535353535353535353535353535353535353535"),
        .value = 1000000000000000000,
        .data = "",
        .chain_id = 1,
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    // Signing payload (9 elements; chain_id and 0, 0 are appended)
    try expectHex("ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080", try legacySigningPayload(&payload_buf, tx));
    // Signing hash
    try expectHex("daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53", &(try legacySigningHash(tx)));
    // Signed tx (v = 37 = chainId * 2 + 35 + 1)
    try expectHex("f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83", try signLegacy(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
    // The official example has v = 37 (yParity = 0). With yParity = 1 it becomes 38.
    try testing.expectEqual(@as(u256, 37), try legacyV(1, 0));
    try testing.expectEqual(@as(u256, 38), try legacyV(1, 1));
}

test "legacy contract creation (empty to) matches an independent implementation byte for byte" {
    // The expected values were computed with eth_account 0.13.7 (Account.sign_transaction).
    // When to is null it is encoded as the empty string (0x80).
    const tx = LegacyTx{
        .nonce = 0,
        .gas_price = 1000000000,
        .gas_limit = 53000,
        .to = null,
        .value = 0,
        .data = "`\x80`@R4\x80\x15`\x0fW`\x00\x80\xfd[P",
        .chain_id = 1,
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("e080843b9aca0082cf088080916080604052348015600f57600080fd5b50018080", try legacySigningPayload(&payload_buf, tx));
    try expectHex("a0494f0cdc02714532aed42f42b5bcb1ef7ae172393ccf60a843360538259ff4", &(try legacySigningHash(tx)));
    try expectHex("f86080843b9aca0082cf088080916080604052348015600f57600080fd5b5026a0cb1999858ff0f80c2b15403e13eb52ea1800956f33ecbf872bc80a32d81f35c1a02211da84cd48c02ad1a35eea03bb84442dc0c9869820e9670e13320ad1d6b8bf", try signLegacy(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
}

test "EIP-1559 signing matches an independent implementation (eth_account) byte for byte" {
    // The expected values come from eth_account 0.13.7 (TypedTransaction.encode/hash and Account.sign_transaction).
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 7,
        .max_priority_fee_per_gas = 1000000000,
        .max_fee_per_gas = 30000000000,
        .gas_limit = 21000,
        .to = hexBytes(20, "3535353535353535353535353535353535353535"),
        .value = 1000000000000000000,
        .data = "",
        .access_list = &.{},
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f00107843b9aca008506fc23ac00825208943535353535353535353535353535353535353535880de0b6b3a764000080c0", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("8b4b6a59aa0a174673c6df4af1c2b09fd1239c0bc6c2e514a88380c7744699dc", &(try eip1559SigningHash(tx)));
    try expectHex("02f8730107843b9aca008506fc23ac00825208943535353535353535353535353535353535353535880de0b6b3a764000080c080a0505cdd8549b8122d419cc4ac67a0ed1e68e4255f1720efeefeb77add34487110a040008058ace1a5cf56b23649773433ddeaa338dcb18f9143857a01004e492850", try signEip1559(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
}

test "EIP-1559 access list and contract creation match an independent implementation byte for byte" {
    // The expected values come from eth_account 0.13.7. The access list structure (an address
    // with a nested list of storage keys) is checked here as well.
    const tx = Eip1559Tx{
        .chain_id = 137,
        .nonce = 0,
        .max_priority_fee_per_gas = 2000000000,
        .max_fee_per_gas = 50000000000,
        .gas_limit = 60000,
        .to = null,
        .value = 0,
        .data = "`\x80`@R",
        .access_list = &[_]AccessListItem{.{ .address = hexBytes(20, "3535353535353535353535353535353535353535"), .storage_keys = &[_][32]u8{ hexBytes(32, "0000000000000000000000000000000000000000000000000000000000000001"), hexBytes(32, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") } }},
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f8768189808477359400850ba43b740082ea608080856080604052f85bf859943535353535353535353535353535353535353535f842a00000000000000000000000000000000000000000000000000000000000000001a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("00a955dcd675bf9f1161e28756916ac110faaf546bfa0f9e78f2d3ef9db64747", &(try eip1559SigningHash(tx)));
    try expectHex("02f8b98189808477359400850ba43b740082ea608080856080604052f85bf859943535353535353535353535353535353535353535f842a00000000000000000000000000000000000000000000000000000000000000001a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff80a00930a6e3686fda2930fd48cacf757207598558136159552078e903a6768e263fa05f6dc3ed5307c88ee976370fd9a13035e604daa7815d47d8932ca9fbecb41343", try signEip1559(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
}

test "EIP-1559 official test vector (ethereum/tests ttEIP1559 maxFeePerGas32BytesValue)" {
    // Must match the txbytes of TransactionTests/ttEIP1559/maxFeePerGas32BytesValue.json byte for byte.
    // maxFeePerGas is 32 bytes (0xa0 + 32 bytes). The filler uses fixed signature values (r/s are
    // the same dummy across all files), so the signed tx is assembled from the signature
    // components for comparison. The signing payload and hash were verified to match an
    // independent implementation (eth_account's TypedTransaction.encode/hash).
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 2000000000,
        .max_fee_per_gas = 115792089237316195423570985008687907853269984665640564039457584007913129639935,
        .gas_limit = 21000,
        .to = hexBytes(20, "095e7baea6a6c7c4c2dfeb977efac326af552d87"),
        .value = 0,
        .data = "",
        .access_list = &.{},
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f84301808477359400a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff82520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c0", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("b8a565bf16bebb93dca8971e2b20abfa1864c1ed2fc20abe5549d2fd4258c6ae", &(try eip1559SigningHash(tx)));
    try expectHex("02f88601808477359400a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff82520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c080a05cbd172231fc0735e0fb994dd5b1a4939170a260b36f0427a8a80866b063b948a07c230f7f578dd61785c93361b9871c0706ebfa6d06e3f4491dc9558c5202ed36", try encodeEip1559Signed(&out, tx, 0, 41946875826971765900365732300593142460367773151448914018868876086522398619976, 56148739830921221639620957524060463709107052619168622154235151530996971793718));
}

test "EIP-1559 official test vector (ethereum/tests ttEIP1559 maxPriorityFeePerGass32BytesValue)" {
    // Must match the txbytes of TransactionTests/ttEIP1559/maxPriorityFeePerGass32BytesValue.json byte for byte.
    // maxPriorityFeePerGas is 32 bytes. The filler uses fixed signature values (r/s are the same
    // dummy across all files), so the signed tx is assembled from the signature components for
    // comparison. The signing payload and hash were verified to match an independent
    // implementation (eth_account's TypedTransaction.encode/hash).
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 115792089237316195423570985008687907853269984665640564039457584007913129639935,
        .max_fee_per_gas = 3000000000,
        .gas_limit = 21000,
        .to = hexBytes(20, "095e7baea6a6c7c4c2dfeb977efac326af552d87"),
        .value = 0,
        .data = "",
        .access_list = &.{},
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f8430180a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84b2d05e0082520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c0", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("7e811af5a83300ae86736ea93d7346b17796e35d0a98b2984d687d5da8b09eee", &(try eip1559SigningHash(tx)));
    try expectHex("02f8860180a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff84b2d05e0082520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c080a05cbd172231fc0735e0fb994dd5b1a4939170a260b36f0427a8a80866b063b948a07c230f7f578dd61785c93361b9871c0706ebfa6d06e3f4491dc9558c5202ed36", try encodeEip1559Signed(&out, tx, 0, 41946875826971765900365732300593142460367773151448914018868876086522398619976, 56148739830921221639620957524060463709107052619168622154235151530996971793718));
}

test "EIP-1559 official test vector (ethereum/tests ttEIP1559 GasLimitPriceProductOverflow)" {
    // Must match the txbytes of TransactionTests/ttEIP1559/GasLimitPriceProductOverflow.json byte for byte.
    // maxFeePerGas is 31 bytes (0x9f + 31 bytes). The filler uses fixed signature values (r/s are
    // the same dummy across all files), so the signed tx is assembled from the signature
    // components for comparison. The signing payload and hash were verified to match an
    // independent implementation (eth_account's TypedTransaction.encode/hash).
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 2000000000,
        .max_fee_per_gas = 7067388259113537318333190002971674063309935587502475832486424805170479103,
        .gas_limit = 21000,
        .to = hexBytes(20, "095e7baea6a6c7c4c2dfeb977efac326af552d87"),
        .value = 0,
        .data = "",
        .access_list = &.{},
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f842018084773594009f03ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff82520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c0", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("6d697a0b4ae7d338c7faede3bbcb84c97d93f3253f1dc7fa12195b4bd4258759", &(try eip1559SigningHash(tx)));
    try expectHex("02f885018084773594009f03ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff82520894095e7baea6a6c7c4c2dfeb977efac326af552d878080c080a05cbd172231fc0735e0fb994dd5b1a4939170a260b36f0427a8a80866b063b948a07c230f7f578dd61785c93361b9871c0706ebfa6d06e3f4491dc9558c5202ed36", try encodeEip1559Signed(&out, tx, 0, 41946875826971765900365732300593142460367773151448914018868876086522398619976, 56148739830921221639620957524060463709107052619168622154235151530996971793718));
}

test "v computation (EIP-155)" {
    try testing.expectEqual(@as(u256, 35), try legacyV(0, 0));
    try testing.expectEqual(@as(u256, 37), try legacyV(1, 0));
    try testing.expectEqual(@as(u256, 38), try legacyV(1, 1));
    try testing.expectEqual(@as(u256, 46), try legacyV(5, 1));

    // Reject a chain ID that would make v overflow u256
    const max_chain_id = (std.math.maxInt(u256) - 36) / 2;
    _ = try legacyV(max_chain_id, 1); // the bound (still fits with yParity = 1)
    try testing.expectError(error.InvalidEncoding, legacyV(max_chain_id + 1, 0));
}

test "r / s are encoded as canonical RLP with no leading zeros" {
    // Not an official vector, only an encoding check (r = 0x80 gives 0x8180, s = 1 gives 0x01).
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 0,
        .max_fee_per_gas = 0,
        .gas_limit = 0,
        .to = null,
        .value = 0,
        .data = "",
    };
    var out: [64]u8 = undefined;
    const raw = try encodeEip1559Signed(&out, tx, 1, 0x80, 1);
    // The last 4 bytes are yParity=1, r=0x80, s=1
    try expectHex("01818001", raw[raw.len - 4 ..]);
}

test "a signed tx is canonical RLP" {
    const tx = LegacyTx{
        .nonce = 1,
        .gas_price = 2,
        .gas_limit = 21000,
        .to = hexBytes(20, "3535353535353535353535353535353535353535"),
        .value = 3,
        .data = "abc",
        .chain_id = 1,
    };
    var out: [128]u8 = undefined;
    const raw = try signLegacy(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646"));
    // decodeList also checks canonical form (a non-canonical output fails here)
    _ = try rlp.decodeList(raw);

    const tx2 = Eip1559Tx{
        .chain_id = 1,
        .nonce = 1,
        .max_priority_fee_per_gas = 2,
        .max_fee_per_gas = 3,
        .gas_limit = 21000,
        .to = null,
        .value = 4,
        .data = "abc",
    };
    const raw2 = try signEip1559(&out, tx2, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646"));
    try testing.expectEqual(@as(u8, transaction_type_eip1559), raw2[0]);
    _ = try rlp.decodeList(raw2[1..]);
}

test "rejects an invalid key and an output buffer that is too small" {
    const tx = LegacyTx{
        .nonce = 0,
        .gas_price = 1,
        .gas_limit = 21000,
        .to = null,
        .value = 0,
        .data = "",
        .chain_id = 1,
    };
    var out: [128]u8 = undefined;

    const zero_key: [32]u8 = @splat(0);
    try testing.expectError(error.InvalidKey, signLegacy(&out, tx, zero_key));

    const order: [32]u8 = @splat(0xFF);
    try testing.expectError(error.InvalidKey, signLegacy(&out, tx, order));

    const priv = hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646");
    var small: [32]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, signLegacy(&small, tx, priv));

    var small_payload: [1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, legacySigningPayload(&small_payload, tx));
}

test "decodes a signed legacy transaction (the EIP-155 official example)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The EIP-155 example (9, 20 gwei, 21000, 0x3535…, 1 ether, chainId 1)
    const raw_hex =
        "f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a0" ++
        "28ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83";
    const raw = try allocator.alloc(u8, raw_hex.len / 2);
    _ = try std.fmt.hexToBytes(raw, raw_hex);

    const decoded = try decode(allocator, raw);
    try testing.expectEqual(Kind.legacy, decoded.kind);
    try testing.expect(decoded.signed);
    try testing.expectEqual(@as(u256, 1), decoded.chain_id.?);
    try testing.expectEqual(@as(u256, 9), decoded.nonce.?);
    try testing.expectEqual(@as(u256, 20_000_000_000), decoded.gas_price.?);
    try testing.expectEqual(@as(u256, 21_000), decoded.gas_limit.?);
    try testing.expectEqual(@as(u256, 1_000_000_000_000_000_000), decoded.value.?);
    try testing.expectEqual(@as(usize, 0), decoded.data.len);
    const to = decoded.to.?;
    try testing.expectEqual(@as(u8, 0x35), to[0]);
    try testing.expectEqual(@as(u8, 0x35), to[19]);
}

test "decodes an unsigned EIP-1559 transaction without dropping its access list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 7,
        .max_priority_fee_per_gas = 1,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = hexBytes(20, "3535353535353535353535353535353535353535"),
        .value = 3,
        .data = "abc",
        .access_list = &[_]AccessListItem{.{
            .address = hexBytes(20, "1111111111111111111111111111111111111111"),
            .storage_keys = &[_][32]u8{hexBytes(32, "2222222222222222222222222222222222222222222222222222222222222222")},
        }},
    };
    var raw: [512]u8 = undefined;
    const decoded = try decode(allocator, try eip1559SigningPayload(&raw, tx));
    try testing.expectEqual(Kind.eip1559, decoded.kind);
    try testing.expect(!decoded.signed);
    try testing.expectEqual(@as(u256, 1), decoded.chain_id.?);
    try testing.expectEqual(@as(u256, 3), decoded.value.?);
    try testing.expectEqualStrings("abc", decoded.data);
}

test "EIP-1559 signing rejects a priority fee above the max fee" {
    const tx = Eip1559Tx{
        .chain_id = 1,
        .nonce = 0,
        .max_priority_fee_per_gas = 3,
        .max_fee_per_gas = 2,
        .gas_limit = 21_000,
        .to = null,
        .value = 0,
        .data = "",
    };
    var out: [256]u8 = undefined;
    try testing.expectError(
        error.InvalidEncoding,
        signEip1559(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")),
    );
}

test "decodes a signed EIP-1559 transaction (eth-account output)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw_hex = "02f86f0107843b9aca008506fc23ac0082520894353535353535353535353535353535353535353584075bcd1580c080a08b29bfd611a0f695677f38218b2a6d02218f906adedbb1f171aa49b261794de2a02e5c9604faa6d3f48c89f8568aa04ea6cef7e058d0464ef4447989524c1bd4cf";
    const raw = try allocator.alloc(u8, raw_hex.len / 2);
    _ = try std.fmt.hexToBytes(raw, raw_hex);

    const decoded = try decode(allocator, raw);
    try testing.expectEqual(Kind.eip1559, decoded.kind);
    try testing.expect(decoded.signed);
    try testing.expectEqual(@as(u256, 1), decoded.chain_id.?);
    try testing.expectEqual(@as(u256, 7), decoded.nonce.?);
    try testing.expectEqual(@as(u256, 1_000_000_000), decoded.max_priority_fee_per_gas.?);
    try testing.expectEqual(@as(u256, 30_000_000_000), decoded.max_fee_per_gas.?);
    try testing.expectEqual(@as(u256, 21_000), decoded.gas_limit.?);
    try testing.expectEqual(@as(u256, 123_456_789), decoded.value.?);
    try testing.expectEqual(@as(?u256, null), decoded.gas_price);
}

test "decodes unsigned transactions and transactions with calldata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // ERC-20 transfer calldata (selector a9059cbb)
    const raw_hex = "02f8b001018459682f008509502f900082ea6094a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4880b844a9059cbb000000000000000000000000353535353535353535353535353535353535353a0000000000000000000000000000000000000000000000000000000005f5e100c080a0f81c6287143005ecacc19b19ed1f8929c0d1ac1304d1e4c365c97c9f0410b003a019c85ccdf57b11bb85a28151b1847ce6777524240ef8ec55441b3cda63643de9";
    const raw = try allocator.alloc(u8, raw_hex.len / 2);
    _ = try std.fmt.hexToBytes(raw, raw_hex);

    const decoded = try decode(allocator, raw);
    try testing.expectEqual(@as(usize, 68), decoded.data.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xa9, 0x05, 0x9c, 0xbb }, decoded.data[0..4]);

    // Reject broken input
    try testing.expectError(error.Truncated, decode(allocator, &.{}));
    try testing.expectError(error.InvalidEncoding, decode(allocator, &[_]u8{0xc0}));
}
