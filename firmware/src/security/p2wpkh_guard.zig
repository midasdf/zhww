//! Independent, allocation-free PSBTv0/P2WPKH/SIGHASH_ALL guard.
//! Deliberately imports NO application parser, cursor, serializer, script or sighash
//! helper. Only std SHA-256/memory primitives are shared. This is a second software
//! calculation, not a TrustZone boundary, independent crypto implementation or fault proof.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Error = error{ GuardInvalid, GuardTruncated, GuardUnsupported, GuardLimit };
pub const max_inputs = 31;
pub const max_outputs = 62;
pub const max_fields_per_map = 128;
pub const max_derivations_per_input = 8;
const max_bytes = 64 * 1024;
const max_money: u64 = 21_000_000 * 100_000_000;

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.offset) return error.GuardTruncated;
        const start = self.offset;
        self.offset += count;
        return self.bytes[start..self.offset];
    }

    fn integer(self: *Reader, comptime T: type) Error!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
    }

    fn compact(self: *Reader) Error!usize {
        const first = try self.integer(u8);
        const value: u64 = switch (first) {
            0xfd => blk: {
                const n = try self.integer(u16);
                if (n < 0xfd) return error.GuardInvalid;
                break :blk n;
            },
            0xfe => blk: {
                const n = try self.integer(u32);
                if (n <= 0xffff) return error.GuardInvalid;
                break :blk n;
            },
            0xff => blk: {
                const n = try self.integer(u64);
                if (n <= 0xffffffff) return error.GuardInvalid;
                break :blk n;
            },
            else => first,
        };
        if (value > std.math.maxInt(usize)) return error.GuardLimit;
        return @intCast(value);
    }

    fn finished(self: *const Reader) Error!void {
        if (self.offset != self.bytes.len) return error.GuardInvalid;
    }
};

const Field = struct { key: []const u8, value: []const u8 };
const Map = struct {
    reader: *Reader,
    keys: [max_fields_per_map][]const u8 = undefined,
    count: usize = 0,
    ended: bool = false,

    fn next(self: *Map) Error!?Field {
        if (self.ended) return null;
        const key_len = try self.reader.compact();
        if (key_len == 0) {
            self.ended = true;
            return null;
        }
        if (self.count == self.keys.len) return error.GuardLimit;
        const key = try self.reader.take(key_len);
        for (self.keys[0..self.count]) |previous|
            if (std.mem.eql(u8, key, previous)) return error.GuardInvalid;
        self.keys[self.count] = key;
        self.count += 1;
        const value_len = try self.reader.compact();
        return .{ .key = key, .value = try self.reader.take(value_len) };
    }
};

const Tx = struct {
    version: []const u8,
    locktime: []const u8,
    outpoints: [max_inputs][]const u8 = undefined,
    sequences: [max_inputs][]const u8 = undefined,
    inputs: usize,
    outputs: usize,
    output_sum: u64 = 0,
    hash_prevouts: [32]u8,
    hash_sequences: [32]u8,
    hash_outputs: [32]u8,

    fn parse(raw: []const u8) Error!Tx {
        var r: Reader = .{ .bytes = raw };
        const version = try r.take(4);
        const input_count = try r.compact();
        if (input_count == 0) return error.GuardUnsupported; // no marker/flag witness serialization
        if (input_count > max_inputs) return error.GuardLimit;
        var prevouts = Sha256.init(.{});
        var sequences = Sha256.init(.{});
        var tx: Tx = .{
            .version = version,
            .locktime = undefined,
            .inputs = input_count,
            .outputs = 0,
            .hash_prevouts = undefined,
            .hash_sequences = undefined,
            .hash_outputs = undefined,
        };
        for (0..input_count) |i| {
            const outpoint = try r.take(36);
            for (tx.outpoints[0..i]) |previous|
                if (std.mem.eql(u8, outpoint, previous)) return error.GuardInvalid;
            tx.outpoints[i] = outpoint;
            prevouts.update(outpoint);
            if (try r.compact() != 0) return error.GuardInvalid; // unsigned scriptSig must be empty
            tx.sequences[i] = try r.take(4);
            sequences.update(tx.sequences[i]);
        }
        const output_count = try r.compact();
        if (output_count == 0) return error.GuardInvalid;
        if (output_count > max_outputs) return error.GuardLimit;
        tx.outputs = output_count;
        var outputs = Sha256.init(.{});
        for (0..output_count) |_| {
            const start = r.offset;
            tx.output_sum = try money(tx.output_sum, try r.integer(u64));
            const script_len = try r.compact();
            _ = try r.take(script_len);
            // Hash original canonical value/length/script bytes, not reserialized structs.
            outputs.update(raw[start..r.offset]);
        }
        tx.locktime = try r.take(4);
        try r.finished();
        tx.hash_prevouts = finishDouble(&prevouts);
        tx.hash_sequences = finishDouble(&sequences);
        tx.hash_outputs = finishDouble(&outputs);
        return tx;
    }

    fn message(self: *const Tx, index: usize, amount: u64, program: *const [20]u8) Error![32]u8 {
        if (index >= self.inputs or amount > max_money) return error.GuardInvalid;
        var h = Sha256.init(.{});
        h.update(self.version);
        h.update(&self.hash_prevouts);
        h.update(&self.hash_sequences);
        h.update(self.outpoints[index]);
        // Independent literal BIP143 scriptCode with its CompactSize length.
        h.update(&.{ 0x19, 0x76, 0xa9, 0x14 });
        h.update(program);
        h.update(&.{ 0x88, 0xac });
        var value: [8]u8 = undefined;
        std.mem.writeInt(u64, &value, amount, .little);
        h.update(&value);
        h.update(self.sequences[index]);
        h.update(&self.hash_outputs);
        h.update(self.locktime);
        h.update(&.{ 1, 0, 0, 0 }); // SIGHASH_ALL, no ANYONECANPAY
        return finishDouble(&h);
    }
};

/// Low-level independent calculator for official BIP143 vectors. Not authorization.
/// Does not require other inputs to have P2WPKH UTXOs; Plan.fromPsbt does.
pub fn hashUnsignedTransaction(raw: []const u8, index: usize, amount: u64, program: *const [20]u8) Error![32]u8 {
    if (raw.len > max_bytes) return error.GuardLimit;
    const tx = try Tx.parse(raw);
    return tx.message(index, amount, program);
}

pub const Plan = struct {
    hashes: [max_inputs][32]u8 = undefined,
    count: usize,
    output_count: usize,
    total_input: u64,
    total_output: u64,
    fee: u64,

    /// Independently read the frozen wire PSBT. Returned plan owns hashes/numbers,
    /// retains no input slices, performs no allocation and never handles private keys.
    /// Narrow policy: witness_utxo-only native P2WPKH; no finalized/non-witness inputs.
    pub fn fromPsbt(raw: []const u8) Error!Plan {
        if (raw.len > max_bytes) return error.GuardLimit;
        var r: Reader = .{ .bytes = raw };
        if (!std.mem.eql(u8, try r.take(5), &.{ 0x70, 0x73, 0x62, 0x74, 0xff }))
            return error.GuardInvalid;
        var globals: Map = .{ .reader = &r };
        var unsigned: ?[]const u8 = null;
        while (try globals.next()) |field| {
            switch (field.key[0]) {
                0 => {
                    if (field.key.len != 1 or unsigned != null) return error.GuardInvalid;
                    unsigned = field.value;
                },
                0xfb => if (field.key.len != 1 or field.value.len != 4 or
                    std.mem.readInt(u32, field.value[0..4], .little) != 0) return error.GuardUnsupported,
                else => {}, // irrelevant fields are still bounded/canonical/duplicate-checked
            }
        }
        const tx = try Tx.parse(unsigned orelse return error.GuardInvalid);
        var plan: Plan = .{
            .count = tx.inputs,
            .output_count = tx.outputs,
            .total_input = 0,
            .total_output = tx.output_sum,
            .fee = 0,
        };
        for (0..tx.inputs) |i| {
            var map: Map = .{ .reader = &r };
            var witness: ?[]const u8 = null;
            var derivations: usize = 0;
            while (try map.next()) |field| {
                switch (field.key[0]) {
                    0, 7, 8 => return error.GuardUnsupported, // non_witness_utxo / final stacks
                    1 => {
                        if (field.key.len != 1 or witness != null) return error.GuardInvalid;
                        // Exact CTxOut: amount(8), script length(1), 0014 + program(20).
                        if (field.value.len != 31 or !std.mem.eql(u8, field.value[8..11], &.{ 22, 0, 20 }))
                            return error.GuardUnsupported;
                        witness = field.value;
                    },
                    3 => if (field.key.len != 1 or field.value.len != 4 or
                        std.mem.readInt(u32, field.value[0..4], .little) != 1) return error.GuardUnsupported,
                    6 => {
                        derivations += 1;
                        if (derivations > max_derivations_per_input) return error.GuardLimit;
                        // If supplied, metadata must describe bounded fixed-depth BIP84 paths.
                        if (field.key.len != 34 or (field.key[1] != 2 and field.key[1] != 3) or
                            field.value.len != 24) return error.GuardUnsupported;
                        const path = field.value[4..24]; // fingerprint followed by FIVE indices
                        const purpose = std.mem.readInt(u32, path[0..4], .little);
                        const coin = std.mem.readInt(u32, path[4..8], .little);
                        const account = std.mem.readInt(u32, path[8..12], .little);
                        const branch = std.mem.readInt(u32, path[12..16], .little);
                        const index = std.mem.readInt(u32, path[16..20], .little);
                        if (purpose != 0x80000054 or (coin != 0x80000000 and coin != 0x80000001) or
                            account & 0x80000000 == 0 or branch > 1 or index & 0x80000000 != 0)
                            return error.GuardUnsupported;
                    },
                    else => {},
                }
            }
            const utxo = witness orelse return error.GuardUnsupported;
            const amount = std.mem.readInt(u64, utxo[0..8], .little);
            plan.total_input = try money(plan.total_input, amount);
            plan.hashes[i] = try tx.message(i, amount, utxo[11..31]);
        }
        for (0..tx.outputs) |_| {
            var map: Map = .{ .reader = &r };
            while (try map.next()) |_| {}
        }
        try r.finished();
        if (plan.total_output > plan.total_input) return error.GuardInvalid;
        plan.fee = plan.total_input - plan.total_output;
        return plan;
    }

    pub fn digest(self: *const Plan) [32]u8 {
        var h = Sha256.init(.{});
        h.update("zhww-independent-p2wpkh-plan-v1");
        for ([_]u64{ @intCast(self.count), @intCast(self.output_count), self.total_input, self.total_output }) |number| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, number, .little);
            h.update(&bytes);
        }
        for (self.hashes[0..self.count]) |*hash| h.update(hash);
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }
};

fn money(total: u64, value: u64) Error!u64 {
    if (value > max_money) return error.GuardInvalid;
    const sum = std.math.add(u64, total, value) catch return error.GuardInvalid;
    if (sum > max_money) return error.GuardInvalid;
    return sum;
}

fn finishDouble(h: *Sha256) [32]u8 {
    var first: [32]u8 = undefined;
    h.final(&first);
    var out: [32]u8 = undefined;
    Sha256.hash(&first, &out, .{});
    return out;
}
