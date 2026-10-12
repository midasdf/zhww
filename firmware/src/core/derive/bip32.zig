//! BIP32 hierarchical deterministic wallet (secp256k1).
//!
//! Reference: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
//!
//! **Implementation notes**
//! - When CKDpriv / CKDpub hits an invalid tweak, it moves on to the next index as the BIP32 spec says
//! - Extended key version bytes follow SLIP-132, so BIP44/49/84 can emit different prefixes
//! - Paths that must not hold a private key use `neuter()` and keep no extended private key
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("../crypto/hashes.zig");
const secp256k1 = @import("../crypto/secp256k1.zig");
const base58 = @import("../encoding/base58.zig");

const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

/// Bit that marks hardened derivation.
pub const hardened: u32 = 0x80000000;

/// Extended key version bytes (including SLIP-132).
pub const Version = enum {
    xprv,
    xpub,
    yprv,
    ypub,
    zprv,
    zpub,
    tprv,
    tpub,
    uprv,
    upub,
    vprv,
    vpub,

    pub fn bytes(self: Version) u32 {
        return switch (self) {
            .xprv => 0x0488ADE4,
            .xpub => 0x0488B21E,
            .yprv => 0x049D7878,
            .ypub => 0x049D7CB2,
            .zprv => 0x04B2430C,
            .zpub => 0x04B24746,
            .tprv => 0x04358394,
            .tpub => 0x043587CF,
            .uprv => 0x044A4E28,
            .upub => 0x044A5262,
            .vprv => 0x045F18BC,
            .vpub => 0x045F1CF6,
        };
    }

    pub fn isPrivate(self: Version) bool {
        return switch (self) {
            .xprv, .yprv, .zprv, .tprv, .uprv, .vprv => true,
            .xpub, .ypub, .zpub, .tpub, .upub, .vpub => false,
        };
    }

    pub fn name(self: Version) []const u8 {
        return @tagName(self);
    }

    /// The matching public-key version.
    pub fn publicVersion(self: Version) Version {
        return switch (self) {
            .xprv, .xpub => .xpub,
            .yprv, .ypub => .ypub,
            .zprv, .zpub => .zpub,
            .tprv, .tpub => .tpub,
            .uprv, .upub => .upub,
            .vprv, .vpub => .vpub,
        };
    }

    /// The matching private-key version.
    pub fn privateVersion(self: Version) Version {
        return switch (self) {
            .xprv, .xpub => .xprv,
            .yprv, .ypub => .yprv,
            .zprv, .zpub => .zprv,
            .tprv, .tpub => .tprv,
            .uprv, .upub => .uprv,
            .vprv, .vpub => .vprv,
        };
    }

    pub fn fromBytes(value: u32) ?Version {
        const info = @typeInfo(Version).@"enum";
        inline for (info.field_names, info.field_values) |_, field_value| {
            const candidate: Version = @fromBackingInt(@intCast(field_value));
            if (candidate.bytes() == value) return candidate;
        }
        return null;
    }
};

/// Key material. Holds either a private key or a public key, never both.
pub const Key = union(enum) {
    priv: [32]u8,
    pub_key: [33]u8,
};

/// Derivation path. Up to 16 levels (the practical BIP32 limit).
pub const Path = struct {
    indices: [16]u32 = @splat(0),
    len: usize = 0,
    /// Whether the path is absolute, starting with "m". Absolute paths only work on the master key (depth 0).
    absolute: bool = false,
};

/// Parse a path in the 'm/84'/0'/0'/0/0' format.
///
/// **Safety rule**: a leading "m" means an absolute path from the master key.
/// Omitting "m" treats the path as relative to the current node.
/// Blurring this distinction leads to deriving keys other than intended and losing funds.
pub fn parsePath(path: []const u8) Error!Path {
    var result: Path = .{};
    if (path.len == 0) return error.InvalidPath;

    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, path, " \t"), '/');
    const first = parts.first();
    if (std.mem.eql(u8, first, "m") or std.mem.eql(u8, first, "M")) {
        result.absolute = true;
    } else if (first.len == 0) {
        return error.InvalidPath;
    } else {
        try appendLevel(&result, first);
    }

    while (parts.next()) |part| {
        try appendLevel(&result, part);
    }
    return result;
}

fn appendLevel(result: *Path, raw: []const u8) Error!void {
    var token = std.mem.trim(u8, raw, " \t");
    var is_hardened = false;
    if (token.len > 0) {
        const last = token[token.len - 1];
        if (last == '\'' or last == 'h' or last == 'H') {
            is_hardened = true;
            token = token[0 .. token.len - 1];
        }
    }
    if (token.len == 0) return error.InvalidPath;
    const value = std.fmt.parseInt(u32, token, 10) catch return error.InvalidPath;
    if (value >= hardened) return error.InvalidPath;
    if (result.len >= result.indices.len) return error.InvalidPath;
    result.indices[result.len] = if (is_hardened) value | hardened else value;
    result.len += 1;
}

/// BIP32 extended key.
pub const ExtendedKey = struct {
    version: Version,
    depth: u8,
    parent_fingerprint: [4]u8,
    index: u32,
    chain_code: [32]u8,
    key: Key,

    /// Compressed public key (33 bytes). Derived when only a private key is present.
    pub fn publicKey(self: ExtendedKey) Error![33]u8 {
        return switch (self.key) {
            .pub_key => |k| k,
            .priv => |p| try secp256k1.pubKeyCompressed(p),
        };
    }

    /// HASH160(public key). The BIP32 identifier.
    pub fn identifier(self: ExtendedKey) Error![20]u8 {
        var id: [20]u8 = undefined;
        const pub_key = try self.publicKey();
        hashes.hash160(&id, &pub_key);
        return id;
    }

    /// The 4 bytes used as the parent fingerprint.
    pub fn fingerprint(self: ExtendedKey) Error![4]u8 {
        const id = try self.identifier();
        return id[0..4].*;
    }

    /// Convert to the public-key version (holds no private key).
    pub fn neuter(self: ExtendedKey) Error!ExtendedKey {
        return switch (self.key) {
            .pub_key => self,
            .priv => |p| .{
                .version = self.version.publicVersion(),
                .depth = self.depth,
                .parent_fingerprint = self.parent_fingerprint,
                .index = self.index,
                .chain_code = self.chain_code,
                .key = .{ .pub_key = try secp256k1.pubKeyCompressed(p) },
            },
        };
    }

    /// Replace only the version bytes (for example, turn an xprv into a zprv).
    pub fn withVersion(self: ExtendedKey, version: Version) Error!ExtendedKey {
        if (version.isPrivate() != self.keyIsPrivate()) return error.InvalidKey;
        return .{
            .version = version,
            .depth = self.depth,
            .parent_fingerprint = self.parent_fingerprint,
            .index = self.index,
            .chain_code = self.chain_code,
            .key = self.key,
        };
    }

    pub fn keyIsPrivate(self: ExtendedKey) bool {
        return switch (self.key) {
            .priv => true,
            .pub_key => false,
        };
    }

    /// Generate the BIP32 master key.
    pub fn fromSeed(seed: []const u8, version: Version) Error!ExtendedKey {
        if (seed.len < 16 or seed.len > 64) return error.InvalidKey;
        var digest: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        HmacSha512.create(&digest, seed, "Bitcoin seed");

        var master: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &master);
        @memcpy(&master, digest[0..32]);
        if (!secp256k1.isValidPrivateKey(master)) return error.InvalidKey;

        var chain_code: [32]u8 = undefined;
        @memcpy(&chain_code, digest[32..64]);

        return .{
            .version = version,
            .depth = 0,
            .parent_fingerprint = @splat(0),
            .index = 0,
            .chain_code = chain_code,
            .key = .{ .priv = master },
        };
    }

    /// CKDpriv: derive a child key from a private key.
    pub fn ckdPriv(self: ExtendedKey, index: u32) Error!ExtendedKey {
        if (self.depth == std.math.maxInt(u8)) return error.InvalidPath;
        var parent = switch (self.key) {
            .priv => |p| p,
            .pub_key => return error.InvalidKey,
        };
        defer std.crypto.secureZero(u8, &parent);

        var data: [37]u8 = undefined;
        defer std.crypto.secureZero(u8, &data);
        if (index >= hardened) {
            data[0] = 0;
            @memcpy(data[1..33], &parent);
        } else {
            const pub_key = try self.publicKey();
            @memcpy(data[0..33], &pub_key);
        }
        std.mem.writeInt(u32, data[33..37], index, .big);

        var digest: [64]u8 = undefined;
        defer std.crypto.secureZero(u8, &digest);
        HmacSha512.create(&digest, &data, &self.chain_code);

        var tweak: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &tweak);
        @memcpy(&tweak, digest[0..32]);
        var child_chain: [32]u8 = undefined;
        @memcpy(&child_chain, digest[32..64]);

        return .{
            .version = self.version,
            .depth = self.depth + 1,
            .parent_fingerprint = try self.fingerprint(),
            .index = index,
            .chain_code = child_chain,
            .key = .{ .priv = try secp256k1.privateTweakAdd(parent, tweak) },
        };
    }

    /// CKDpub: derive a child public key from a public key (hardened is not possible).
    pub fn ckdPub(self: ExtendedKey, index: u32) Error!ExtendedKey {
        if (index >= hardened or self.depth == std.math.maxInt(u8)) return error.InvalidPath;

        const parent = try self.publicKey();
        var data: [37]u8 = undefined;
        @memcpy(data[0..33], &parent);
        std.mem.writeInt(u32, data[33..37], index, .big);

        var digest: [64]u8 = undefined;
        HmacSha512.create(&digest, &data, &self.chain_code);

        var tweak: [32]u8 = undefined;
        @memcpy(&tweak, digest[0..32]);
        var child_chain: [32]u8 = undefined;
        @memcpy(&child_chain, digest[32..64]);

        return .{
            .version = self.version,
            .depth = self.depth + 1,
            .parent_fingerprint = try self.fingerprint(),
            .index = index,
            .chain_code = child_chain,
            .key = .{ .pub_key = try secp256k1.publicTweakAdd(parent, tweak) },
        };
    }

    /// Derive a child key. On an invalid tweak, try the next index (per the BIP32 spec).
    pub fn child(self: ExtendedKey, index: u32) Error!ExtendedKey {
        var attempt = index;
        while (true) {
            const result = if (self.keyIsPrivate()) self.ckdPriv(attempt) else self.ckdPub(attempt);
            if (result) |node| {
                return node;
            } else |err| {
                if (err != error.InvalidTweak) return err;
                // Do not silently turn a requested normal child into a hardened child when
                // the last normal index happens to be invalid.
                if (attempt == std.math.maxInt(u32) or
                    (index < hardened and attempt == hardened - 1)) return error.InvalidTweak;
                attempt += 1;
            }
        }
    }

    /// Walk a path and return the child key.
    ///
    /// Absolute paths ("m/...") are accepted only on the master key. Relative paths ("0/1")
    /// are treated as derivation from the current node. To prevent deriving from the wrong
    /// level by accident, giving an absolute path to a non-master key yields error.InvalidPath.
    pub fn derivePath(self: ExtendedKey, path: []const u8) Error!ExtendedKey {
        const parsed = try parsePath(path);
        if (parsed.absolute and self.depth != 0) return error.InvalidPath;
        var node = self;
        for (parsed.indices[0..parsed.len]) |index| {
            node = try node.child(index);
        }
        return node;
    }

    /// Return the extended key string in Base58Check form (xprv / zpub etc.).
    pub fn serialize(self: ExtendedKey, out: []u8) Error![]u8 {
        var payload: [78]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], self.version.bytes(), .big);
        payload[4] = self.depth;
        @memcpy(payload[5..9], &self.parent_fingerprint);
        std.mem.writeInt(u32, payload[9..13], self.index, .big);
        @memcpy(payload[13..45], &self.chain_code);
        switch (self.key) {
            .priv => |p| {
                payload[45] = 0;
                @memcpy(payload[46..78], &p);
            },
            .pub_key => |k| @memcpy(payload[45..78], &k),
        }
        return base58.checkEncode(out, &payload);
    }

    /// Parse an extended key string.
    pub fn parse(text: []const u8) Error!ExtendedKey {
        var payload: [128]u8 = undefined;
        const decoded = try base58.checkDecode(&payload, text);
        if (decoded.len != 78) return error.InvalidEncoding;

        const version_bytes = std.mem.readInt(u32, decoded[0..4], .big);
        const version = Version.fromBytes(version_bytes) orelse return error.InvalidEncoding;

        var chain_code: [32]u8 = undefined;
        @memcpy(&chain_code, decoded[13..45]);

        const key_data = decoded[45..78];
        const key: Key = if (key_data[0] == 0) blk: {
            if (!version.isPrivate()) return error.InvalidEncoding;
            var priv_key: [32]u8 = undefined;
            @memcpy(&priv_key, key_data[1..33]);
            if (!secp256k1.isValidPrivateKey(priv_key)) return error.InvalidKey;
            break :blk .{ .priv = priv_key };
        } else blk: {
            if (version.isPrivate() or !secp256k1.isValidPublicKey(key_data)) {
                return error.InvalidEncoding;
            }
            var pub_key: [33]u8 = undefined;
            @memcpy(&pub_key, key_data);
            break :blk .{ .pub_key = pub_key };
        };

        const depth = decoded[4];
        const parent_fingerprint = decoded[5..9].*;
        const index = std.mem.readInt(u32, decoded[9..13], .big);
        const zero_fingerprint: [4]u8 = @splat(0);
        if (depth == 0 and (!std.mem.eql(u8, &parent_fingerprint, &zero_fingerprint) or index != 0)) {
            return error.InvalidEncoding;
        }

        return .{
            .version = version,
            .depth = depth,
            .parent_fingerprint = parent_fingerprint,
            .index = index,
            .chain_code = chain_code,
            .key = key,
        };
    }
};

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "path parsing" {
    const path = try parsePath("m/84'/0'/0'/0/0");
    try testing.expectEqual(@as(usize, 5), path.len);
    try testing.expectEqual(@as(u32, 84 | hardened), path.indices[0]);
    try testing.expectEqual(@as(u32, 0), path.indices[3]);
    try testing.expect(path.absolute);

    // h / H notation and relative paths
    const alt = try parsePath("84h/0H/0'");
    try testing.expectEqual(@as(usize, 3), alt.len);
    try testing.expectEqual(@as(u32, 84 | hardened), alt.indices[0]);
    try testing.expectEqual(@as(u32, 0 | hardened), alt.indices[1]);
    try testing.expect(!alt.absolute);

    const master = try parsePath("m");
    try testing.expectEqual(@as(usize, 0), master.len);
    try testing.expect(master.absolute);
}

test "rejects invalid paths" {
    try testing.expectError(error.InvalidPath, parsePath(""));
    try testing.expectError(error.InvalidPath, parsePath("/0"));
    try testing.expectError(error.InvalidPath, parsePath("m/x"));
    try testing.expectError(error.InvalidPath, parsePath("m/2147483648"));
    try testing.expectError(error.InvalidPath, parsePath("m/0''"));
}

test "master key and serialization (BIP32 test vector 1)" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi",
        try master.serialize(&buf),
    );
    try testing.expectEqualStrings(
        "xpub661MyMwAqRbcFtXgS5sYJABqqG9YLmC4Q1Rdap9gSE8NqtwybGhePY2gZ29ESFjqJoCu1Rupje8YtGqsefD265TMg7usUDFdp6W1EGMcet8",
        try (try master.neuter()).serialize(&buf),
    );
}

test "public and private derivation agree" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const account = try master.derivePath("m/0'");
    const parent_pub = try account.neuter();

    // derive m/0'/1 from both the private and the public side and check that they agree
    const node_from_private = try account.derivePath("1"); // relative path = m/0'/1
    const node_from_public = try parent_pub.derivePath("1");

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    try testing.expectEqualStrings(
        try (try node_from_private.neuter()).serialize(&buf_a),
        try node_from_public.serialize(&buf_b),
    );

    // hardened cannot be derived from a public key
    try testing.expectError(
        error.InvalidPath,
        parent_pub.derivePath("0'"),
    );
}

test "rejects an absolute path on a non-master key (prevents deriving from the wrong level)" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const account = try master.derivePath("m/0'");

    // absolute paths only at depth 0
    try testing.expectError(error.InvalidPath, account.derivePath("m/1"));
    // relative paths are fine
    _ = try account.derivePath("1");
}

test "extended key parsing (round trip)" {
    const text = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs";
    const parsed = try ExtendedKey.parse(text);
    try testing.expectEqual(Version.zpub, parsed.version);
    try testing.expectEqual(false, parsed.keyIsPrivate());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(text, try parsed.serialize(&buf));

    // reject unknown version bytes
    try testing.expectError(error.InvalidEncoding, ExtendedKey.parse("not-base58!"));
}

test "derivation rejects depth overflow" {
    const seed: [32]u8 = @splat(0x01);
    var master = try ExtendedKey.fromSeed(&seed, .xprv);
    master.depth = std.math.maxInt(u8);
    try testing.expectError(error.InvalidPath, master.ckdPriv(0));
    try testing.expectError(error.InvalidPath, (try master.neuter()).ckdPub(0));
}

test "extended key parsing rejects a version/key-kind mismatch" {
    const seed: [32]u8 = @splat(0x01);
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    var encoded: [128]u8 = undefined;
    const text = try master.serialize(&encoded);

    var payload: [78]u8 = undefined;
    const decoded = try base58.checkDecode(&payload, text);
    std.mem.writeInt(u32, decoded[0..4], Version.xpub.bytes(), .big);
    var mismatched: [128]u8 = undefined;
    const bad = try base58.checkEncode(&mismatched, decoded);
    try testing.expectError(error.InvalidEncoding, ExtendedKey.parse(bad));
}

test "version replacement" {
    const seed: [32]u8 = @splat(0x01);
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const zprv = try master.withVersion(.zprv);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, try zprv.serialize(&buf), "zprv"));

    // a public key cannot be swapped into a private-key version
    try testing.expectError(error.InvalidKey, (try master.neuter()).withVersion(.zprv));
}
