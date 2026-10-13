//! Approved BTC workflow prototype, not a TrustZone gateway or physical device loop.
//! Existing direct CLI APIs remain development-only and intentionally separate.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const review_mod = @import("review.zig");
const signing = @import("sign.zig");
const address = @import("address.zig");
const boot = @import("../../security/boot_policy.zig");
const session_mod = @import("../../security/signing_session.zig");
const rng_mod = @import("../../security/rng.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");

pub const Workflow = struct {
    session: session_mod.SigningSession(review_mod.max_request_bytes, review_mod.max_pages) = .{},
    review: review_mod.Review = .{},
    review_digest: [32]u8 = @splat(0),
    network: address.Network = .mainnet,

    /// Secure caller must choose the network (PSBT does not authenticate a network),
    /// collect evidence, and erase input seed/KDF copies. Objects must not be copied.
    /// Freeze BEFORE parsing; no transport slices survive begin().
    pub fn begin(self: *Workflow, allocator: std.mem.Allocator, evidence: boot.Evidence, seed: *const [64]u8, raw: []const u8, network: address.Network, now: u64) !void {
        errdefer self.abort();
        if (self.session.ready or self.session.gate.state == .fault) return error.InvalidState;
        try boot.validate(evidence);
        if (raw.len == 0 or raw.len > review_mod.max_request_bytes) return error.InvalidRequest;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const frozen = try arena.allocator().dupe(u8, raw);
        try self.review.build(arena.allocator(), frozen, network);
        self.review_digest = self.review.digest();
        self.network = network;
        var pages: [review_mod.max_pages][]const u8 = undefined;
        for (self.review.pages[0..self.review.count], 0..) |*page, i| pages[i] = page.bytes();
        try self.session.begin(evidence, seed, frozen, pages[0..self.review.count], now);
    }

    /// Receipt must follow successful physical framebuffer transfer, not just generation.
    pub fn displayed(self: *Workflow, index: usize, text: []const u8, now: u64) !void {
        errdefer self.abort();
        try self.session.displayed(index, text, now);
    }

    pub fn button(self: *Workflow, down: bool, now: u64) !void {
        errdefer self.abort();
        try self.session.button(down, now);
    }

    pub fn poll(self: *Workflow, now: u64) !void {
        errdefer self.abort();
        try self.session.poll(now);
    }

    /// Return output only after full signing/verification succeeds. Caller owns result
    /// allocations; use a dedicated arena and discard it on failure. Approval is spent
    /// on EVERY attempt and the seed/input backing memory is wiped on EVERY exit.
    /// Fresh context blinding entropy is mandatory and requested only inside the
    /// approved callback. There is no deterministic/default RNG for this workflow.
    pub fn sign(self: *Workflow, allocator: std.mem.Allocator, raw: []const u8, now: u64, rng: *rng_mod.Rng) !signing.SignedPsbt {
        defer self.abort();
        var adapter: Adapter = .{
            .allocator = allocator,
            .network = self.network,
            .expected_digest = self.review_digest,
            .rng = rng,
        };
        try self.session.sign(raw, now, &adapter);
        return adapter.output orelse error.NoMatchingKey;
    }

    pub fn abort(self: *Workflow) void {
        self.session.abort();
        self.review = .{};
        std.crypto.secureZero(u8, &self.review_digest);
    }
};

const Adapter = struct {
    allocator: std.mem.Allocator,
    network: address.Network,
    expected_digest: [32]u8,
    rng: *rng_mod.Rng,
    output: ?signing.SignedPsbt = null,

    pub fn sign(self: *Adapter, frozen: []const u8, seed: []const u8) !void {
        // Reparse ONLY owned input and compare the complete presentation before signing.
        // Same parser, NOT I-3 independent computation. Never infer chain security from this.
        var review: review_mod.Review = .{};
        try review.build(self.allocator, frozen, self.network);
        if (!std.crypto.timing_safe.eql([32]u8, review.digest(), self.expected_digest))
            return error.ReviewMismatch;
        var blinding_seed: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &blinding_seed);
        try self.rng.fill(&blinding_seed);
        var lease = try secp256k1.SigningLease.begin(&blinding_seed);
        defer lease.end();
        var keys = try signing.KeySource.fromSeed(seed);
        defer keys.wipe();
        const outcome = try signing.signPsbtWithKeys(self.allocator, frozen, &keys);
        if (outcome.result.unsigned_inputs.len != 0 or
            outcome.result.partial_sigs.len != review.input_count) return error.NoMatchingKey;
        if (outcome.result.fee == null or outcome.result.fee.? != review.fee)
            return error.ReviewMismatch;
        self.output = outcome;
        // Existing signer verifies each ECDSA signature. Lease destroys and wipes C
        // context backing memory. By-value parameters/compiler spills still need audit.
    }
};
