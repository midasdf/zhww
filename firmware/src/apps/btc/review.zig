//! Bounded, key-free, conservative PSBT review for the first approved BTC workflow.
//! Initial policy: P2WPKH inputs, known amounts, SIGHASH_ALL, standard address outputs.
//! Every output is shown as a payment (no unproven change suppression).
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const psbt_mod = @import("psbt.zig");
const sign = @import("sign.zig");
const address = @import("address.zig");
const ui = @import("../../ui/screen.zig");
const framebuffer = @import("../../ui/framebuffer.zig");

pub const max_request_bytes = 64 * 1024;
pub const max_pages = 64;
pub const max_lines = 6;
pub const columns = 26;
pub const page_bytes = max_lines * (columns + 1);

pub const Page = struct {
    text: [page_bytes]u8 = @splat(0),
    len: usize = 0,
    line_count: usize = 0,

    fn line(self: *Page, text: []const u8) !void {
        if (text.len == 0 or text.len > columns or self.line_count >= max_lines)
            return error.Undisplayable;
        for (text) |ch| if (ch < 32 or ch > 126) return error.Undisplayable;
        @memcpy(self.text[self.len..][0..text.len], text);
        self.len += text.len;
        self.text[self.len] = '\n';
        self.len += 1;
        self.line_count += 1;
    }

    fn format(self: *Page, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [columns]u8 = undefined;
        try self.line(try std.fmt.bufPrint(&buffer, fmt, args));
    }

    fn chunks(self: *Page, text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            const end = @min(text.len, offset + columns);
            try self.line(text[offset..end]);
            offset = end;
        }
    }

    pub fn bytes(self: *const Page) []const u8 {
        return self.text[0..self.len];
    }

    /// Fixed short lines: no elision or hidden pagination on the supported screens.
    /// HAL must render and successfully transfer this framebuffer before acknowledging.
    pub fn render(self: *const Page, fb: *framebuffer.Framebuffer) !void {
        if (fb.width != 240 or (fb.height != 240 and fb.height != 135))
            return error.Undisplayable;
        var lines: [max_lines]ui.Line = undefined;
        var count: usize = 0;
        var split = std.mem.splitScalar(u8, self.bytes(), '\n');
        while (split.next()) |text| {
            if (text.len == 0) continue;
            if (count >= lines.len) return error.Undisplayable;
            lines[count] = .{ .value = text };
            count += 1;
        }
        const screen: ui.Screen = .{
            .title = "BTC REVIEW",
            .lines = lines[0..count],
            .footer_left = "CANCEL",
            .footer_right = "NEXT",
        };
        if (screen.pageCount(fb) != 1) return error.Undisplayable;
        screen.render(fb);
    }
};

pub const Review = struct {
    pages: [max_pages]Page = @splat(.{}),
    count: usize = 0,
    input_count: usize = 0,
    output_count: usize = 0,
    total_input: u64 = 0,
    total_output: u64 = 0,
    fee: u64 = 0,

    fn add(self: *Review) !*Page {
        if (self.count >= self.pages.len) return error.TooManyPages;
        const index = self.count;
        self.count += 1;
        return &self.pages[index];
    }

    pub fn page(self: *const Review, index: usize) !*const Page {
        if (index >= self.count) return error.InvalidPage;
        return &self.pages[index];
    }

    /// Owns all presentation bytes; retains no parsed request or allocator slices.
    /// Scratch allocations are released on every exit. The caller freezes input first.
    pub fn build(self: *Review, allocator: std.mem.Allocator, raw: []const u8, network: address.Network) !void {
        self.* = .{};
        errdefer self.* = .{};
        if (raw.len == 0 or raw.len > max_request_bytes) return error.InvalidRequest;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const scratch = arena.allocator();
        const parsed = try psbt_mod.Psbt.parse(scratch, raw);
        const tx = parsed.unsigned_tx;
        if (tx.inputs.len == 0 or tx.outputs.len == 0) return error.InvalidRequest;
        self.input_count = tx.inputs.len;
        self.output_count = tx.outputs.len;
        // 1 summary, 2 pages per input, 1 per output, 1 totals page.
        if (tx.inputs.len > (max_pages - 2) / 2 or
            tx.outputs.len > max_pages - 2 - 2 * tx.inputs.len) return error.TooManyPages;

        const summary = try self.add();
        try summary.format("Network: {s}", .{@tagName(network)});
        try summary.format("Version: {d}", .{tx.version});
        try summary.format("Locktime: {d}", .{tx.lock_time});
        try summary.format("Inputs: {d}", .{tx.inputs.len});
        try summary.format("Outputs: {d}", .{tx.outputs.len});
        try summary.line("Sighash: ALL");

        var total_input: u64 = 0;
        for (tx.inputs, 0..) |input, i| {
            const metadata = parsed.inputs[i];
            if (metadata.final_script_sig != null or metadata.final_script_witness != null)
                return error.InvalidRequest;
            if (metadata.sighash_type) |kind| if (kind != sign.SIGHASH_ALL)
                return error.UnsupportedSighash;
            const utxo = try sign.utxoForDisplay(scratch, parsed, i) orelse return error.UnknownAmount;
            if (sign.detectScriptKind(utxo.script_pubkey) != .p2wpkh) return error.UnsupportedInput;
            total_input = try addMoney(total_input, utxo.value);
            // User-facing txid is byte-reversed. Show every byte, never abbreviate.
            var txid: [64]u8 = undefined;
            const hex = "0123456789abcdef";
            for (0..32) |j| {
                const b = input.prevout.txid[31 - j];
                txid[j * 2] = hex[b >> 4];
                txid[j * 2 + 1] = hex[b & 15];
            }
            const identity = try self.add();
            try identity.format("Input {d}/{d} txid:", .{ i + 1, tx.inputs.len });
            try identity.chunks(&txid);
            try identity.format("Prevout: {d}", .{input.prevout.vout});
            try identity.format("Sequence: {d}", .{input.sequence});
            const value = try self.add();
            try value.format("Input {d}/{d}", .{ i + 1, tx.inputs.len });
            try value.format("Sats: {d}", .{utxo.value});
            try value.line("Type: P2WPKH");
            try value.line("UTXO supplied by host");
        }

        var total_output: u64 = 0;
        for (tx.outputs, 0..) |output, i| {
            total_output = try addMoney(total_output, output.value);
            var buffer: [90]u8 = undefined;
            const destination = try address.fromScriptPubKey(&buffer, output.script_pubkey, network) orelse return error.UnsupportedOutput;
            const payment = try self.add();
            try payment.format("Output {d}/{d}: payment", .{ i + 1, tx.outputs.len });
            try payment.chunks(destination);
            try payment.format("Sats: {d}", .{output.value});
        }
        if (total_output > total_input) return error.InvalidRequest;
        self.total_input = total_input;
        self.total_output = total_output;
        self.fee = total_input - total_output;
        const totals = try self.add();
        try totals.format("In: {d} sats", .{total_input});
        try totals.format("Out: {d} sats", .{total_output});
        try totals.format("Fee: {d} sats", .{self.fee});
        try totals.line("ALL outputs shown");
        try totals.line("Change NOT hidden");
        try totals.line("Host amounts unverified");
    }

    /// Commits page order/content including network, amounts and policy notices.
    /// Not an independent sighash calculation and not a signature authorization token.
    pub fn digest(self: *const Review) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("zhww-btc-review-v1");
        var length: [8]u8 = undefined;
        std.mem.writeInt(u64, &length, @intCast(self.count), .little);
        h.update(&length);
        for (self.pages[0..self.count]) |*p| {
            std.mem.writeInt(u64, &length, @intCast(p.len), .little);
            h.update(&length);
            h.update(p.bytes());
        }
        var out: [32]u8 = undefined;
        h.final(&out);
        return out;
    }
};

fn addMoney(total: u64, value: u64) !u64 {
    if (value > sign.max_money) return error.InvalidRequest;
    const result = std.math.add(u64, total, value) catch return error.InvalidRequest;
    if (result > sign.max_money) return error.InvalidRequest;
    return result;
}
