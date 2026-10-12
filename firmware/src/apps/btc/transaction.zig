//! Bitcoin トランザクションの解析・直列化。
//!
//! 参考: https://en.bitcoin.it/wiki/Transaction
//!       BIP144（SegWit の witness 直列化）
//!
//! **設計方針**: トランザクションは可変長（入力数・出力数・スクリプト長）なので、
//! 解析には呼び出し側が用意したアロケータ（セッション単位のアリーナを想定）を使う。
//! **秘密情報はこの領域に置かない**（seed・鍵は固定長バッファのみで扱う）。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const Cursor = @import("cursor.zig").Cursor;

pub const OutPoint = struct {
    /// 直前のトランザクション ID（**直列化されたままのバイト順**）。
    /// 表示用の txid は逆順になることに注意。
    txid: [32]u8,
    vout: u32,
};

pub const TxIn = struct {
    prevout: OutPoint,
    script_sig: []const u8,
    sequence: u32,
    /// SegWit の witness スタック（非 SegWit では空）。
    witness: []const []const u8,
};

pub const TxOut = struct {
    value: u64,
    script_pubkey: []const u8,
};

pub const Transaction = struct {
    version: i32,
    inputs: []TxIn,
    outputs: []TxOut,
    lock_time: u32,
    /// witness 付きで直列化されていたかどうか。
    has_witness: bool,

    /// ネットワーク直列化形式を解析する（witness 付き・無しの両方に対応）。
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) Error!Transaction {
        var cursor = Cursor{ .data = bytes };
        const version = try cursor.readI32();

        var input_count = try cursor.readVarInt();
        var has_witness = false;
        // BIP144 の判定。入力数 0 のとき、次のバイトが 0x01 なら
        // 「marker(0x00) + flag(0x01)」の witness 形式、それ以外は
        // 「入力 0 の通常トランザクション」として出力数を続けて読む。
        //
        // この曖昧さは Bitcoin の直列化自体に由来する（Bitcoin Core も同じ規則で
        // 判定している）。BIP174 のテストベクタには「入力 0・出力 2」の
        // トランザクションが妥当な例として含まれている。
        if (input_count == 0) {
            if (try cursor.peekU8() == 0x01) {
                _ = try cursor.readU8();
                has_witness = true;
                input_count = try cursor.readVarInt();
            }
        }
        if (input_count > 4096) return error.InvalidEncoding;

        const inputs = try allocator.alloc(TxIn, @intCast(input_count));
        for (inputs) |*input| {
            var prev_txid: [32]u8 = undefined;
            @memcpy(&prev_txid, try cursor.readBytes(32));
            const vout = try cursor.readU32();
            const script_sig = try cursor.readVarBytes();
            const sequence = try cursor.readU32();
            input.* = .{
                .prevout = .{ .txid = prev_txid, .vout = vout },
                .script_sig = script_sig,
                .sequence = sequence,
                .witness = &.{},
            };
        }

        const output_count = try cursor.readVarInt();
        if (output_count > 4096) return error.InvalidEncoding;
        const outputs = try allocator.alloc(TxOut, @intCast(output_count));
        for (outputs) |*output| {
            const value = try cursor.readU64();
            const script_pubkey = try cursor.readVarBytes();
            output.* = .{ .value = value, .script_pubkey = script_pubkey };
        }

        if (has_witness) {
            for (inputs) |*input| {
                const item_count = try cursor.readVarInt();
                if (item_count > 1024) return error.InvalidEncoding;
                const items = try allocator.alloc([]const u8, @intCast(item_count));
                for (items) |*item| {
                    item.* = try cursor.readVarBytes();
                }
                input.witness = items;
            }
        }

        const lock_time = try cursor.readU32();
        if (cursor.remaining() != 0) return error.InvalidEncoding;

        return .{
            .version = version,
            .inputs = inputs,
            .outputs = outputs,
            .lock_time = lock_time,
            .has_witness = has_witness,
        };
    }

    /// ネットワーク直列化形式に戻す。`include_witness` が false の場合は
    /// BIP174 の PSBT_GLOBAL_UNSIGNED_TX が要求する「witness 無し」形式になる。
    pub fn serialize(
        self: Transaction,
        allocator: std.mem.Allocator,
        include_witness: bool,
    ) Error![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        try writeI32(&out, allocator, self.version);

        const with_witness = include_witness and self.has_witness;
        if (with_witness) {
            try out.append(allocator, 0x00); // marker
            try out.append(allocator, 0x01); // flag
        }
        try writeVarInt(&out, allocator, self.inputs.len);

        for (self.inputs) |input| {
            try out.appendSlice(allocator, &input.prevout.txid);
            try writeU32(&out, allocator, input.prevout.vout);
            try writeVarBytes(&out, allocator, input.script_sig);
            try writeU32(&out, allocator, input.sequence);
        }

        try writeVarInt(&out, allocator, self.outputs.len);
        for (self.outputs) |output| {
            try writeU64(&out, allocator, output.value);
            try writeVarBytes(&out, allocator, output.script_pubkey);
        }

        if (with_witness) {
            for (self.inputs) |input| {
                try writeVarInt(&out, allocator, input.witness.len);
                for (input.witness) |item| {
                    try writeVarBytes(&out, allocator, item);
                }
            }
        }

        try writeU32(&out, allocator, self.lock_time);
        return out.toOwnedSlice(allocator);
    }

    /// txid（内部バイト順。表示する場合は逆順にすること）。
    pub fn txid(self: Transaction, allocator: std.mem.Allocator) Error![32]u8 {
        const raw = try self.serialize(allocator, false);
        defer allocator.free(raw);
        var hash: [32]u8 = undefined;
        hashes.sha256d(&hash, raw);
        return hash;
    }

    /// 合計出力額（sats）。
    pub fn totalOutput(self: Transaction) u64 {
        var total: u64 = 0;
        for (self.outputs) |output| total += output.value;
        return total;
    }
};

fn writeU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeI32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) Error!void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(i32, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

fn writeU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) Error!void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    try out.appendSlice(allocator, &buf);
}

pub fn writeVarInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) Error!void {
    if (value < 0xFD) {
        try out.append(allocator, @intCast(value));
    } else if (value <= 0xFFFF) {
        try out.append(allocator, 0xFD);
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, @intCast(value), .little);
        try out.appendSlice(allocator, &buf);
    } else if (value <= 0xFFFFFFFF) {
        try out.append(allocator, 0xFE);
        try writeU32(out, allocator, @intCast(value));
    } else {
        try out.append(allocator, 0xFF);
        try writeU64(out, allocator, @intCast(value));
    }
}

pub fn writeVarBytes(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    bytes: []const u8,
) Error!void {
    try writeVarInt(out, allocator, bytes.len);
    try out.appendSlice(allocator, bytes);
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

const bip143_unsigned_tx = "0100000002fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f0000000000eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac11000000";

fn hexAlloc(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, hex.len / 2);
    _ = try std.fmt.hexToBytes(out, hex);
    return out;
}

test "BIP143 の未署名トランザクションを解析して同一バイト列に戻せる" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const raw = try hexAlloc(allocator, bip143_unsigned_tx);
    const tx = try Transaction.parse(allocator, raw);

    try testing.expectEqual(@as(i32, 1), tx.version);
    try testing.expectEqual(@as(usize, 2), tx.inputs.len);
    try testing.expectEqual(@as(usize, 2), tx.outputs.len);
    try testing.expectEqual(@as(u32, 0x11), tx.lock_time);
    try testing.expect(!tx.has_witness);

    // input 0 の outpoint（直列化順）
    const expected_txid = try std.fmt.hexToBytes(
        try allocator.alloc(u8, 32),
        "fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f",
    );
    try testing.expectEqualSlices(u8, expected_txid, &tx.inputs[0].prevout.txid);
    try testing.expectEqual(@as(u32, 0), tx.inputs[0].prevout.vout);
    try testing.expectEqual(@as(u32, 0xffffffee), tx.inputs[0].sequence);
    try testing.expectEqual(@as(u64, 0x06b22c20), tx.outputs[0].value);
    try testing.expectEqual(@as(u64, 0x0d519390), tx.outputs[1].value);

    // 往復して同一バイト列になる
    const reserialized = try tx.serialize(allocator, false);
    try testing.expectEqualSlices(u8, raw, reserialized);
}

test "SegWit 形式（witness 付き）の解析と直列化" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // BIP143 の署名済みトランザクション（witness 付き）
    const signed = try hexAlloc(
        allocator,
        "01000000000102fff7f7881a8099afa6940d42d1e7f6362bec38171ea3edf433541db4e4ad969f00000000494830450221008b9d1dc26ba6a9cb62127b02742fa9d754cd3bebf337f7a55d114c8e5cdd30be022040529b194ba3f9281a99f2b1c0a19c0489bc22ede944ccf4ecbab4cc618ef3ed01eeffffffef51e1b804cc89d182d279655c3aa89e815b1b309fe287d9b2b55d57b90ec68a0100000000ffffffff02202cb206000000001976a9148280b37df378db99f66f85c95a783a76ac7a6d5988ac9093510d000000001976a9143bde42dbee7e4dbe6a21b2d50ce2f0167faa815988ac000247304402203609e17b84f6a7d30c80bfa610b5b4542f32a8a0d5447a12fb1366d7f01cc44a0220573a954c4518331561406f90300e8f3358f51928d43c212a8caed02de67eebee0121025476c2e83188368da1ff3e292e7acafcdb3566bb0ad253f62fc70f07aeee635711000000",
    );
    const tx = try Transaction.parse(allocator, signed);
    try testing.expect(tx.has_witness);
    // input 0 は P2PK（witness 無し）、input 1 は P2WPKH（署名 + 公開鍵）
    try testing.expectEqual(@as(usize, 0), tx.inputs[0].witness.len);
    try testing.expectEqual(@as(usize, 2), tx.inputs[1].witness.len);
    try testing.expectEqual(@as(usize, 71), tx.inputs[1].witness[0].len);
    try testing.expectEqual(@as(usize, 33), tx.inputs[1].witness[1].len);

    const reserialized = try tx.serialize(allocator, true);
    try testing.expectEqualSlices(u8, signed, reserialized);

    // witness を除いた直列化: marker/flag が無く、scriptSig はそのまま保持される
    const without_witness = try tx.serialize(allocator, false);
    try testing.expectEqual(@as(u8, 0x02), without_witness[4]); // 先頭が input count（marker 無し）
    try testing.expect(without_witness.len < signed.len);
}

test "合計出力額" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const tx = try Transaction.parse(allocator, try hexAlloc(allocator, bip143_unsigned_tx));
    // 0x06b22c20 (1.1234 BTC) + 0x0d519390 (2.2345 BTC)
    try testing.expectEqual(@as(u64, 335_790_000), tx.totalOutput());
}
