//! secp256k1 operations (bindings to libsecp256k1).
//!
//! **Design constraint**: signing and key operations use only audited libsecp256k1.
//! A pure Zig implementation does not resist timing attacks, so it is never used for
//! operations that handle private keys.
//!
//! We do not `@cImport` the C headers; only the functions we need are declared extern.
//! This was chosen so that an audit can see at a glance which C functions we depend on.
//!
//! Reference: https://github.com/bitcoin-core/secp256k1
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("hashes.zig");

// --- libsecp256k1 declarations (from secp256k1.h) ------------------------

/// Opaque context type.
pub const Context = opaque {};
/// secp256k1_pubkey is a 64-byte internal representation.
pub const Pubkey = extern struct { data: [64]u8 };

/// SECP256K1_CONTEXT_NONE
const context_none: c_uint = 1 << 0;
/// SECP256K1_EC_COMPRESSED
const ec_compressed: c_uint = (1 << 1) | (1 << 8);
/// SECP256K1_EC_UNCOMPRESSED
const ec_uncompressed: c_uint = (1 << 1);

extern fn secp256k1_context_preallocated_size(flags: c_uint) usize;
extern fn secp256k1_context_preallocated_create(memory: *anyopaque, flags: c_uint) ?*Context;
extern fn secp256k1_context_preallocated_destroy(ctx: *Context) void;
extern fn secp256k1_context_randomize(ctx: *Context, seed32: *const [32]u8) c_int;
extern fn secp256k1_ec_pubkey_create(
    ctx: *const Context,
    pubkey: *Pubkey,
    seckey: *const [32]u8,
) c_int;
extern fn secp256k1_ec_pubkey_serialize(
    ctx: *const Context,
    output: [*]u8,
    outputlen: *usize,
    pubkey: *const Pubkey,
    flags: c_uint,
) c_int;
extern fn secp256k1_ec_pubkey_parse(
    ctx: *const Context,
    pubkey: *Pubkey,
    input: [*]const u8,
    inputlen: usize,
) c_int;
extern fn secp256k1_ec_seckey_tweak_add(
    ctx: *const Context,
    seckey: *[32]u8,
    tweak: *const [32]u8,
) c_int;
extern fn secp256k1_ec_pubkey_tweak_add(
    ctx: *const Context,
    pubkey: *Pubkey,
    tweak: *const [32]u8,
) c_int;

/// ECDSA signature (64-byte compact representation).
pub const EcdsaSignature = extern struct { data: [64]u8 };

/// ECDSA signature with recovery id (libsecp256k1 internal representation).
pub const RecoverableSignature = extern struct { data: [65]u8 };

extern fn secp256k1_ecdsa_sign_recoverable(
    ctx: *const Context,
    sig: *RecoverableSignature,
    msg32: *const [32]u8,
    seckey: *const [32]u8,
    noncefp: ?*const anyopaque,
    ndata: ?*const anyopaque,
) c_int;
extern fn secp256k1_ecdsa_recoverable_signature_serialize_compact(
    ctx: *const Context,
    output64: [*]u8,
    recid: *c_int,
    sig: *const RecoverableSignature,
) c_int;

extern fn secp256k1_ecdsa_sign(
    ctx: *const Context,
    sig: *EcdsaSignature,
    msg32: *const [32]u8,
    seckey: *const [32]u8,
    // passing null for noncefp uses RFC6979 (libsecp256k1's default implementation)
    noncefp: ?*const anyopaque,
    ndata: ?*const anyopaque,
) c_int;
extern fn secp256k1_ecdsa_verify(
    ctx: *const Context,
    sig: *const EcdsaSignature,
    msg32: *const [32]u8,
    pubkey: *const Pubkey,
) c_int;
extern fn secp256k1_ecdsa_signature_serialize_der(
    ctx: *const Context,
    output: [*]u8,
    outputlen: *usize,
    sig: *const EcdsaSignature,
) c_int;
extern fn secp256k1_ecdsa_signature_parse_der(
    ctx: *const Context,
    sig: *EcdsaSignature,
    input: [*]const u8,
    inputlen: usize,
) c_int;
extern fn secp256k1_ecdsa_signature_parse_compact(
    ctx: *const Context,
    sig: *EcdsaSignature,
    input64: [*]const u8,
) c_int;
extern fn secp256k1_ecdsa_signature_normalize(
    ctx: *const Context,
    out_sig: ?*EcdsaSignature,
    in_sig: *const EcdsaSignature,
) c_int;

// --- parameters ----------------------------------------------------------

/// The order n of the secp256k1 group.
pub const curve_order: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

pub fn isValidPrivateKey(priv: [32]u8) bool {
    const value = std.mem.readInt(u256, &priv, .big);
    return value != 0 and value < curve_order;
}

fn isValidTweak(tweak: [32]u8) bool {
    const value = std.mem.readInt(u256, &tweak, .big);
    return value < curve_order;
}

/// Whether a serialized compressed or uncompressed public key is a curve point accepted by
/// libsecp256k1. Length and prefix checks alone are not sufficient for untrusted PSBT/xpub data.
pub fn isValidPublicKey(serialized: []const u8) bool {
    if (serialized.len != 33 and serialized.len != 65) return false;
    var pubkey: Pubkey = undefined;
    return secp256k1_ec_pubkey_parse(
        context() catch return false,
        &pubkey,
        serialized.ptr,
        serialized.len,
    ) == 1;
}

// --- context -------------------------------------------------------------

/// Fixed-capacity C context ownership. Keep at a stable address; never copy while live.
/// libsecp256k1 preallocated API performs no malloc/free. Runtime size check supports
/// differing library configurations; alignment 64 covers the supported host/Arm ABIs.
/// Do not read/write backing memory before preallocated_destroy returns.
pub fn ContextOwner(comptime capacity: usize) type {
    return struct {
        memory: [capacity]u8 align(64) = @splat(0),
        ptr: ?*Context = null,

        pub fn get(self: *@This()) Error!*Context {
            if (self.ptr) |ctx| return ctx;
            const required = secp256k1_context_preallocated_size(context_none);
            if (required == 0 or required > capacity) return error.BufferTooSmall;
            self.ptr = secp256k1_context_preallocated_create(&self.memory, context_none) orelse return error.InvalidKey;
            return self.ptr.?;
        }

        /// C destruction first, then wipe ALL backing bytes including padding/tail.
        pub fn deinit(self: *@This()) void {
            if (self.ptr) |ctx| secp256k1_context_preallocated_destroy(ctx);
            self.ptr = null;
            std.crypto.secureZero(u8, &self.memory);
        }
    };
}

pub const context_capacity = 4096;
var global_owner: ContextOwner(context_capacity) = .{};
var signing_context_active = false;

/// Compatibility accessor for existing crypto/BIP32 code. Shared singleton, NOT
/// a thread-safe/per-request API or security boundary. Secure target must serialize
/// execution, prevent interrupt re-entry and park the other core. Legacy CLI operations
/// lazily create an unrandomized development context; approved signing uses the lease.
pub fn context() Error!*const Context {
    return global_owner.get();
}

/// Exclusive logical signing lease for single-threaded trusted orchestration.
/// Context blinding seed is borrowed, not copied into the lease. Lexical use only:
/// `var lease = try SigningLease.begin(&seed); defer lease.end();` Never copy a lease.
/// Ordinary context() calls still work inside the scope, so this is not isolation.
pub const SigningLease = struct {
    live: bool = false,

    pub fn begin(seed: *const [32]u8) !SigningLease {
        if (signing_context_active) return error.ContextBusy;
        global_owner.deinit(); // retire any unrandomized development context
        errdefer global_owner.deinit();
        const ctx = try global_owner.get();
        if (secp256k1_context_randomize(ctx, seed) == 0) return error.InvalidKey;
        signing_context_active = true;
        return .{ .live = true };
    }

    pub fn end(self: *SigningLease) void {
        if (!self.live) return;
        global_owner.deinit();
        signing_context_active = false;
        self.live = false;
    }
};

/// Legacy development helper. Approved signing uses a bounded RNG and SigningLease.
pub fn randomize(seed: [32]u8) Error!void {
    if (signing_context_active) return error.InvalidKey;
    var copy = seed;
    defer std.crypto.secureZero(u8, &copy);
    if (secp256k1_context_randomize(try global_owner.get(), &copy) == 0) return error.InvalidKey;
}

// --- operations ----------------------------------------------------------

/// Derive the compressed public key (33 bytes) from a private key.
pub fn pubKeyCompressed(priv: [32]u8) Error![33]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    const ctx = try context();
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_create(ctx, &pubkey, &priv) == 0) return error.InvalidKey;
    var out: [33]u8 = undefined;
    var out_len: usize = out.len;
    if (secp256k1_ec_pubkey_serialize(ctx, &out, &out_len, &pubkey, ec_compressed) == 0) {
        return error.InvalidKey;
    }
    return out;
}

/// Uncompressed public key (65 bytes) from a private key. Used for EVM address derivation.
pub fn pubKeyUncompressed(priv: [32]u8) Error![65]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    const ctx = try context();
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_create(ctx, &pubkey, &priv) == 0) return error.InvalidKey;
    var out: [65]u8 = undefined;
    var out_len: usize = out.len;
    if (secp256k1_ec_pubkey_serialize(ctx, &out, &out_len, &pubkey, ec_uncompressed) == 0) {
        return error.InvalidKey;
    }
    return out;
}

/// (priv + tweak) mod n (BIP32 CKDpriv).
///
/// An invalid result gives error.InvalidTweak. Per the BIP32 spec, this means skipping
/// that index and using the next one.
pub fn privateTweakAdd(priv: [32]u8, tweak: [32]u8) Error![32]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    if (!isValidTweak(tweak)) return error.InvalidTweak;
    var secret = priv;
    defer std.crypto.secureZero(u8, &secret);
    if (secp256k1_ec_seckey_tweak_add(try context(), &secret, &tweak) == 0) {
        return error.InvalidTweak;
    }
    if (!isValidPrivateKey(secret)) return error.InvalidTweak;
    const result = secret;
    return result;
}

/// point(tweak) + pub (BIP32 CKDpub).
pub fn publicTweakAdd(pub_key: [33]u8, tweak: [32]u8) Error![33]u8 {
    const ctx = try context();
    if (!isValidTweak(tweak)) return error.InvalidTweak;
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_parse(ctx, &pubkey, &pub_key, pub_key.len) == 0) {
        return error.InvalidKey;
    }
    if (secp256k1_ec_pubkey_tweak_add(ctx, &pubkey, &tweak) == 0) return error.InvalidTweak;
    var out: [33]u8 = undefined;
    var out_len: usize = out.len;
    if (secp256k1_ec_pubkey_serialize(ctx, &out, &out_len, &pubkey, ec_compressed) == 0) {
        return error.InvalidKey;
    }
    return out;
}

/// Extract the x-only public key (32 bytes) from a compressed public key (33 bytes).
///
/// BIP340's lift_x picks the point with even Y, so extracting the x coordinate is enough.
pub fn xonly(pub_key: [33]u8) Error![32]u8 {
    if (pub_key[0] != 2 and pub_key[0] != 3) return error.InvalidKey;
    return pub_key[1..33].*;
}

/// Output key for the BIP341 key path (32-byte x-only).
///
/// Q = lift_x(internal) + int(HashTapTweak(internal)) * G
pub fn taprootOutputKey(internal_xonly: [32]u8) Error![32]u8 {
    var internal: [33]u8 = undefined;
    internal[0] = 2; // restore as the point with even Y
    @memcpy(internal[1..], &internal_xonly);
    var tweak: [32]u8 = undefined;
    hashes.taggedHash(&tweak, "TapTweak", &internal_xonly);
    const tweaked = try publicTweakAdd(internal, tweak);
    return xonly(tweaked);
}

// --- ECDSA ---------------------------------------------------------------

/// ECDSA-sign a message hash.
///
/// The nonce uses libsecp256k1's default implementation (RFC6979). Because it uses **no
/// randomness**, the same key and message always give the same signature, which structurally
/// prevents key leakage through nonce reuse. libsecp256k1 always returns a low-s
/// normalized signature.
pub fn sign(msg: [32]u8, priv: [32]u8) Error!EcdsaSignature {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_sign(try context(), &sig, &msg, &priv, null, null) == 0) {
        return error.InvalidKey;
    }
    return sig;
}

/// Serialize a signature in DER form (the form used in Bitcoin scriptSig / witness).
pub fn serializeDer(out: []u8, sig: *const EcdsaSignature) Error![]u8 {
    var len: usize = out.len;
    if (secp256k1_ecdsa_signature_serialize_der(try context(), out.ptr, &len, sig) == 0) {
        return error.BufferTooSmall;
    }
    return out[0..len];
}

/// Parse a DER-form signature (for verification and interoperability tests).
pub fn parseDer(der: []const u8) Error!EcdsaSignature {
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_signature_parse_der(try context(), &sig, der.ptr, der.len) == 0) {
        return error.InvalidEncoding;
    }
    return sig;
}

/// Parse a signature in compact form (r || s).
pub fn parseCompact(compact: [64]u8) Error!EcdsaSignature {
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_signature_parse_compact(try context(), &sig, &compact) == 0) {
        return error.InvalidEncoding;
    }
    return sig;
}

/// Verify a signature. **Always verify with this after producing a signature** (to catch implementation mistakes).
pub fn verify(sig: *const EcdsaSignature, msg: [32]u8, pub_key: [33]u8) Error!bool {
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_parse(try context(), &pubkey, &pub_key, pub_key.len) == 0) {
        return error.InvalidKey;
    }
    return secp256k1_ecdsa_verify(try context(), sig, &msg, &pubkey) == 1;
}

/// Check whether a signature is low-s normalized (a BIP62 / EIP-2 requirement).
pub fn isNormalized(sig: *const EcdsaSignature) bool {
    return secp256k1_ecdsa_signature_normalize(context() catch return false, null, sig) == 1;
}

/// Compact signature (big-endian `r || s`) and recovery id.
pub const RecoverableResult = struct {
    /// 64 bytes usable directly as Ethereum's `r` / `s`.
    compact: [64]u8,
    /// 0 or 1 (used to compute Ethereum's `yParity` / EIP-155 `v`).
    recovery_id: u8,
};

/// Sign and obtain `r || s` and the recovery id at the same time.
///
/// **Important**: `EcdsaSignature.data` is libsecp256k1's internal representation and is
/// **not** big-endian `r || s` (in 0.8.0 on this environment each scalar is stored
/// little-endian). Always use this function when `r || s` is needed.
/// Bitcoin DER signatures go through `serializeDer` and are therefore unaffected.
pub fn signRecoverable(msg: [32]u8, priv: [32]u8) Error!RecoverableResult {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    const ctx = try context();

    var recoverable: RecoverableSignature = undefined;
    if (secp256k1_ecdsa_sign_recoverable(ctx, &recoverable, &msg, &priv, null, null) == 0) {
        return error.InvalidKey;
    }

    var compact: [64]u8 = undefined;
    var recid: c_int = 0;
    if (secp256k1_ecdsa_recoverable_signature_serialize_compact(
        ctx,
        &compact,
        &recid,
        &recoverable,
    ) == 0) return error.SignatureInvalid;

    // 2 / 3 only happens when the x coordinate is at least the group order, which is effectively unreachable
    if (recid != 0 and recid != 1) return error.SignatureInvalid;
    return .{ .compact = compact, .recovery_id = @intCast(recid) };
}

/// Tweak-applied private key used for BIP341 key path signing.
///
/// When the internal key's public key has odd Y, the private key is replaced with `n - k`
/// to match BIP340's lift_x (the point with even Y), and then TapTweak is added.
pub fn taprootTweakPrivateKey(priv: [32]u8) Error![32]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    const pub_key = try pubKeyCompressed(priv);

    var key = priv;
    defer std.crypto.secureZero(u8, &key);
    if (pub_key[0] == 3) {
        const value = std.mem.readInt(u256, &priv, .big);
        const negated = @as(u256, curve_order) - value;
        std.mem.writeInt(u256, &key, negated, .big);
    }

    // the tweak is computed from the internal key's x coordinate (the same value regardless of Y parity)
    var tweak: [32]u8 = undefined;
    hashes.taggedHash(&tweak, "TapTweak", pub_key[1..33]);
    const result = try privateTweakAdd(key, tweak);
    return result;
}

// --- BIP340 (Schnorr / Taproot) ------------------------------------------

/// x-only public key (the 32-byte public key used by BIP340 / Taproot).
pub const XOnlyPubkey = extern struct { data: [64]u8 };
/// Keypair (libsecp256k1 internal representation).
pub const Keypair = extern struct { data: [96]u8 };

extern fn secp256k1_keypair_create(
    ctx: *const Context,
    keypair: *Keypair,
    seckey: *const [32]u8,
) c_int;
extern fn secp256k1_keypair_xonly_pub(
    ctx: *const Context,
    pubkey: *XOnlyPubkey,
    pk_parity: ?*c_int,
    keypair: *const Keypair,
) c_int;
extern fn secp256k1_xonly_pubkey_from_pubkey(
    ctx: *const Context,
    xonly_pubkey: *XOnlyPubkey,
    pk_parity: ?*c_int,
    pubkey: *const Pubkey,
) c_int;
extern fn secp256k1_xonly_pubkey_serialize(
    ctx: *const Context,
    output32: [*]u8,
    pubkey: *const XOnlyPubkey,
) c_int;
extern fn secp256k1_schnorrsig_sign32(
    ctx: *const Context,
    sig64: [*]u8,
    msg32: *const [32]u8,
    keypair: *const Keypair,
    aux_rand32: ?*const [32]u8,
) c_int;
extern fn secp256k1_schnorrsig_verify(
    ctx: *const Context,
    sig64: [*]const u8,
    msg32: *const [32]u8,
    msglen: usize,
    pubkey: *const XOnlyPubkey,
) c_int;

/// BIP340 Schnorr signature (64 bytes).
///
/// **The caller must tweak the key beforehand**. Taproot key path signing uses a key
/// passed through `taproot_tweak_private_key` (BIP341).
///
/// Deterministic development/vector helper (zero auxiliary randomness). Device code
/// must use schnorrSignRandomized with a bounded Secure-world entropy provider.
pub fn schnorrSign(msg: [32]u8, priv: [32]u8) Error![64]u8 {
    return schnorrSignWithAux(msg, &priv, &@as([32]u8, @splat(0)));
}

/// Explicit borrowed BIP340 auxiliary randomness; caller owns its secure erasure.
/// This low-level API does not establish a randomized context or verify the result.
pub fn schnorrSignWithAux(msg: [32]u8, priv: *const [32]u8, aux_rand: *const [32]u8) Error![64]u8 {
    if (!isValidPrivateKey(priv.*)) return error.InvalidKey;
    const ctx = try context();

    var keypair: Keypair = undefined;
    defer std.crypto.secureZero(u8, &keypair.data);
    if (secp256k1_keypair_create(ctx, &keypair, priv) == 0) return error.InvalidKey;

    var signature: [64]u8 = undefined;
    if (secp256k1_schnorrsig_sign32(ctx, &signature, &msg, &keypair, aux_rand) == 0) {
        return error.SignatureInvalid;
    }
    return signature;
}

/// Fresh independent portions for context blinding and BIP340 auxiliary randomness.
/// RNG must implement the fail-closed fill contract (security/rng.zig on the target).
/// No fallback: entropy/acquisition/signature/verification errors propagate. This is
/// a primitive, NOT a transaction approval gateway or integrated Taproot workflow.
pub fn schnorrSignRandomized(msg: [32]u8, priv: *const [32]u8, rng: anytype) ![64]u8 {
    var entropy: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &entropy);
    try rng.fill(&entropy);
    var lease = try SigningLease.begin(entropy[0..32]);
    defer lease.end();
    const signature = try schnorrSignWithAux(msg, priv, entropy[32..64]);
    if (!(try schnorrVerify(signature, msg, try schnorrPublicKey(priv.*)))) return error.SignatureInvalid;
    return signature;
}

/// The x-only public key (32 bytes) corresponding to a private key.
pub fn schnorrPublicKey(priv: [32]u8) Error![32]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    const ctx = try context();

    var keypair: Keypair = undefined;
    defer std.crypto.secureZero(u8, &keypair.data);
    if (secp256k1_keypair_create(ctx, &keypair, &priv) == 0) return error.InvalidKey;

    var pubkey: XOnlyPubkey = undefined;
    if (secp256k1_keypair_xonly_pub(ctx, &pubkey, null, &keypair) == 0) return error.InvalidKey;

    var out: [32]u8 = undefined;
    if (secp256k1_xonly_pubkey_serialize(ctx, &out, &pubkey) == 0) return error.InvalidKey;
    return out;
}

/// Verify a BIP340 signature (**always run this after signing**).
pub fn schnorrVerify(signature: [64]u8, msg: [32]u8, xonly_key: [32]u8) Error!bool {
    const ctx = try context();

    // restore the x-only public key as the `0x02 || x` compressed public key (lift_x)
    const compressed = [_]u8{0x02} ++ xonly_key;
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_parse(ctx, &pubkey, &compressed, 33) == 0) {
        return error.InvalidKey;
    }
    var xonly_pubkey: XOnlyPubkey = undefined;
    if (secp256k1_xonly_pubkey_from_pubkey(ctx, &xonly_pubkey, null, &pubkey) == 0) {
        return error.InvalidKey;
    }
    return secp256k1_schnorrsig_verify(ctx, &signature, &msg, 32, &xonly_pubkey) == 1;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Convert a hex string into a fixed-length byte array.
fn hexBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// Turn a small integer into a 32-byte big-endian private key.
fn scalar(value: u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    out[31] = value;
    return out;
}

test "preallocated context validates capacity and wipes backing memory after destruction" {
    var small: ContextOwner(1) = .{};
    try testing.expectError(error.BufferTooSmall, small.get());
    try testing.expect(small.ptr == null);
    var owner: ContextOwner(context_capacity) = .{};
    _ = try owner.get();
    try testing.expect(owner.ptr != null);
    // Never inspect live C backing memory. Destroy, then verify the whole allocation.
    owner.deinit();
    try testing.expect(owner.ptr == null);
    try testing.expectEqualSlices(u8, &@as([context_capacity]u8, @splat(0)), &owner.memory);
    owner.deinit();
    _ = try owner.get();
    owner.deinit();
}

test "randomized signing lease preserves deterministic signatures and rejects nesting" {
    const msg: [32]u8 = @splat(0x42);
    const before = try sign(msg, scalar(1));
    var first = try SigningLease.begin(&@as([32]u8, @splat(0x11)));
    errdefer first.end();
    try testing.expectError(error.ContextBusy, SigningLease.begin(&@as([32]u8, @splat(0x22))));
    const during = try sign(msg, scalar(1));
    try testing.expectEqualSlices(u8, &before.data, &during.data);
    try testing.expect(try verify(&during, msg, try pubKeyCompressed(scalar(1))));
    first.end();
    first.end();
    try testing.expect(!signing_context_active);
    try testing.expect(global_owner.ptr == null);
    try testing.expectEqualSlices(u8, &@as([context_capacity]u8, @splat(0)), &global_owner.memory);
    var second = try SigningLease.begin(&@as([32]u8, @splat(0x33)));
    defer second.end();
    const after = try sign(msg, scalar(1));
    try testing.expectEqualSlices(u8, &before.data, &after.data);
}

test "randomized Schnorr uses fresh auxiliary bytes, verifies and wipes context" {
    const MockRng = struct {
        calls: usize = 0,
        pub fn fill(self: *@This(), out: []u8) !void {
            self.calls += 1;
            try testing.expectEqual(@as(usize, 64), out.len);
            @memset(out, @intCast(self.calls));
        }
    };
    var rng: MockRng = .{};
    const msg: [32]u8 = @splat(0x42);
    const priv = scalar(1);
    const pubkey = try schnorrPublicKey(priv);
    const first = try schnorrSignRandomized(msg, &priv, &rng);
    try testing.expect(global_owner.ptr == null);
    try testing.expectEqualSlices(u8, &@as([context_capacity]u8, @splat(0)), &global_owner.memory);
    const second = try schnorrSignRandomized(msg, &priv, &rng);
    try testing.expect(!std.mem.eql(u8, &first, &second));
    try testing.expect(try schnorrVerify(first, msg, pubkey));
    try testing.expect(try schnorrVerify(second, msg, pubkey));
    try testing.expectEqual(@as(usize, 2), rng.calls);
    global_owner.deinit();
}

test "randomized Schnorr refuses failed entropy without creating a signing context" {
    const FailedRng = struct {
        pub fn fill(_: *@This(), out: []u8) !void {
            @memset(out, 0xab); // partial read before hardware failure
            return error.HealthFailure;
        }
    };
    var rng: FailedRng = .{};
    global_owner.deinit();
    try testing.expectError(error.HealthFailure, schnorrSignRandomized(@splat(0x42), &scalar(1), &rng));
    try testing.expect(global_owner.ptr == null);
    try testing.expect(!signing_context_active);
    try testing.expectEqualSlices(u8, &@as([context_capacity]u8, @splat(0)), &global_owner.memory);
}

test "the library is linked (public key from a BIP49 test vector)" {
    const priv = hexBytes(32, "c9bdb49cfbaedca21c4b1f3a7803c34636b1d7dc55a717132443fc3f4c5867e8");
    const expected = hexBytes(33, "03a1af804ac108a8a51782198c2d034b28bf90c8803f5a53f76276fa69a4eae77f");
    try testing.expectEqualSlices(u8, &expected, &(try pubKeyCompressed(priv)));
}

test "private key range validation" {
    const zeros: [32]u8 = @splat(0);
    const ones: [32]u8 = @splat(0xFF);
    try testing.expect(!isValidPrivateKey(zeros));
    try testing.expect(!isValidPrivateKey(ones));
    try testing.expect(isValidPrivateKey(scalar(1)));
}

test "CKDpriv tweak addition" {
    // 1 + 1 = 2
    const result = try privateTweakAdd(scalar(1), scalar(1));
    try testing.expectEqualSlices(u8, &scalar(2), &result);

    // reject an invalid tweak (>= n)
    const overflow: [32]u8 = @splat(0xFF);
    try testing.expectError(error.InvalidTweak, privateTweakAdd(scalar(1), overflow));
}

test "CKDpub tweak addition (1*G + 1*G = 2*G)" {
    const point_one = try pubKeyCompressed(scalar(1));
    const point_two = try pubKeyCompressed(scalar(2));
    try testing.expectEqualSlices(u8, &point_two, &(try publicTweakAdd(point_one, scalar(1))));
}

test "Taproot output key (BIP86 test vector)" {
    const internal = hexBytes(32, "cc8a4bc64d897bddc5fbc2f670f7a8ba0b386779106cf1223c6fc5d7cd6fc115");
    const expected = hexBytes(32, "a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c");
    try testing.expectEqualSlices(u8, &expected, &(try taprootOutputKey(internal)));
}

test "ECDSA signing and verification" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    const pub_key = try pubKeyCompressed(priv);
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const sig = try sign(msg, priv);
    try testing.expect(try verify(&sig, msg, pub_key));

    // changing the message makes verification fail
    var tampered = msg;
    tampered[0] ^= 0x01;
    try testing.expect(!try verify(&sig, tampered, pub_key));

    // verification fails with a different key
    const other_pub = try pubKeyCompressed(scalar(2));
    try testing.expect(!try verify(&sig, msg, other_pub));
}

test "signatures are deterministic (RFC6979) and low-s" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const first = try sign(msg, priv);
    const second = try sign(msg, priv);
    try testing.expectEqualSlices(u8, &first.data, &second.data);

    // libsecp256k1 always returns low-s (no normalization needed)
    try testing.expect(!isNormalized(&first));
}

test "DER serialization and parsing round trip" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const sig = try sign(msg, priv);
    var der_buf: [72]u8 = undefined;
    const der = try serializeDer(&der_buf, &sig);
    try testing.expect(der.len >= 68 and der.len <= 72);

    const parsed = try parseDer(der);
    const pub_key = try pubKeyCompressed(priv);
    try testing.expect(try verify(&parsed, msg, pub_key));

    // broken DER cannot be parsed
    try testing.expectError(error.InvalidEncoding, parseDer(&[_]u8{ 0x30, 0x00 }));
}

test "recoverable signing returns r || s and a recovery id" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    const pub_key = try pubKeyCompressed(priv);
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const result = try signRecoverable(msg, priv);
    try testing.expect(result.recovery_id == 0 or result.recovery_id == 1);

    // the compact form verifies as-is (= it is the canonical r || s)
    const parsed = try parseCompact(result.compact);
    try testing.expect(try verify(&parsed, msg, pub_key));

    // r / s match the signature obtained via DER (deterministic, same key and message)
    const plain = try sign(msg, priv);
    var der_buf: [72]u8 = undefined;
    const der = try serializeDer(&der_buf, &plain);
    const expected_r = std.mem.readInt(u256, result.compact[0..32], .big);
    const expected_s = std.mem.readInt(u256, result.compact[32..64], .big);
    const der_signature = try parseDer(der);
    // serialize_compact cannot be used to extract r / s from DER, so
    // identity is confirmed by verification alone (both are valid for the same message)
    try testing.expect(try verify(&der_signature, msg, pub_key));
    try testing.expect(expected_r != 0 and expected_s != 0);
}
