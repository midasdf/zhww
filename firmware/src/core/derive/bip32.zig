//! BIP32 階層的決定性ウォレット（secp256k1）。
//!
//! 参考: https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki
//!
//! **実装上の要点**
//! - CKDpriv / CKDpub で無効な tweak が出た場合は、BIP32 の仕様どおり次の index へ進む
//! - 拡張鍵のバージョンバイトは SLIP-132 に従い、BIP44/49/84 で異なる接頭辞を出力できる
//! - 秘密鍵を持たない経路では `neuter()` を使い、拡張秘密鍵を保持しない

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("../crypto/hashes.zig");
const secp256k1 = @import("../crypto/secp256k1.zig");
const base58 = @import("../encoding/base58.zig");

const HmacSha512 = std.crypto.auth.hmac.sha2.HmacSha512;

/// hardened 派生を表すビット。
pub const hardened: u32 = 0x80000000;

/// 拡張鍵のバージョンバイト（SLIP-132 を含む）。
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

    /// 対応する公開鍵版のバージョン。
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

    /// 対応する秘密鍵版のバージョン。
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
            const candidate: Version = @enumFromInt(field_value);
            if (candidate.bytes() == value) return candidate;
        }
        return null;
    }
};

/// 鍵素材。秘密鍵か公開鍵のどちらか一方のみを持つ。
pub const Key = union(enum) {
    priv: [32]u8,
    pub_key: [33]u8,
};

/// 派生パス。最大 16 レベルまで（BIP32 の実用上の上限）。
pub const Path = struct {
    indices: [16]u32 = @splat(0),
    len: usize = 0,
    /// 先頭が "m" の絶対パスかどうか。絶対パスはマスター鍵（depth 0）でのみ使える。
    absolute: bool = false,
};

/// 'm/84'/0'/0'/0/0' 形式のパスを解析する。
///
/// **安全性のための規則**: 先頭の "m" はマスター鍵からの絶対パスを意味する。
/// "m" を省略した場合は現在のノードからの相対パスとして扱う。
/// この区別を曖昧にすると、意図と異なる鍵を導出して資金を失う事故につながる。
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

/// BIP32 拡張鍵。
pub const ExtendedKey = struct {
    version: Version,
    depth: u8,
    parent_fingerprint: [4]u8,
    index: u32,
    chain_code: [32]u8,
    key: Key,

    /// 圧縮公開鍵（33 バイト）。秘密鍵しか無い場合は導出する。
    pub fn publicKey(self: ExtendedKey) Error![33]u8 {
        return switch (self.key) {
            .pub_key => |k| k,
            .priv => |p| try secp256k1.pubKeyCompressed(p),
        };
    }

    /// HASH160(公開鍵)。BIP32 の識別子。
    pub fn identifier(self: ExtendedKey) Error![20]u8 {
        var id: [20]u8 = undefined;
        const pub_key = try self.publicKey();
        hashes.hash160(&id, &pub_key);
        return id;
    }

    /// 親の fingerprint として使う 4 バイト。
    pub fn fingerprint(self: ExtendedKey) Error![4]u8 {
        const id = try self.identifier();
        return id[0..4].*;
    }

    /// 公開鍵版へ変換する（秘密鍵を持たない）。
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

    /// バージョンバイトだけを差し替える（例: xprv を zprv にする）。
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

    /// BIP32 マスター鍵を生成する。
    pub fn fromSeed(seed: []const u8, version: Version) Error!ExtendedKey {
        if (seed.len < 16 or seed.len > 64) return error.InvalidKey;
        var digest: [64]u8 = undefined;
        HmacSha512.create(&digest, seed, "Bitcoin seed");

        var master: [32]u8 = undefined;
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

    /// CKDpriv: 秘密鍵から子鍵を導出する。
    pub fn ckdPriv(self: ExtendedKey, index: u32) Error!ExtendedKey {
        const parent = switch (self.key) {
            .priv => |p| p,
            .pub_key => return error.InvalidKey,
        };

        var data: [37]u8 = undefined;
        if (index >= hardened) {
            data[0] = 0;
            @memcpy(data[1..33], &parent);
        } else {
            const pub_key = try self.publicKey();
            @memcpy(data[0..33], &pub_key);
        }
        std.mem.writeInt(u32, data[33..37], index, .big);

        var digest: [64]u8 = undefined;
        HmacSha512.create(&digest, &data, &self.chain_code);

        var tweak: [32]u8 = undefined;
        @memcpy(&tweak, digest[0..32]);
        var child_chain: [32]u8 = undefined;
        @memcpy(&child_chain, digest[32..64]);

        return .{
            .version = self.version,
            .depth = self.depth +% 1,
            .parent_fingerprint = try self.fingerprint(),
            .index = index,
            .chain_code = child_chain,
            .key = .{ .priv = try secp256k1.privateTweakAdd(parent, tweak) },
        };
    }

    /// CKDpub: 公開鍵から子公開鍵を導出する（hardened は不可）。
    pub fn ckdPub(self: ExtendedKey, index: u32) Error!ExtendedKey {
        if (index >= hardened) return error.InvalidPath;

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
            .depth = self.depth +% 1,
            .parent_fingerprint = try self.fingerprint(),
            .index = index,
            .chain_code = child_chain,
            .key = .{ .pub_key = try secp256k1.publicTweakAdd(parent, tweak) },
        };
    }

    /// 子鍵を導出する。無効な tweak が出た場合は次の index を試す（BIP32 の仕様）。
    pub fn child(self: ExtendedKey, index: u32) Error!ExtendedKey {
        var attempt = index;
        while (true) {
            const result = if (self.keyIsPrivate()) self.ckdPriv(attempt) else self.ckdPub(attempt);
            if (result) |node| {
                return node;
            } else |err| {
                if (err != error.InvalidTweak) return err;
                if (attempt == std.math.maxInt(u32)) return error.InvalidTweak;
                attempt += 1;
            }
        }
    }

    /// パスを辿って子鍵を返す。
    ///
    /// 絶対パス（"m/..."）はマスター鍵でのみ受け付ける。相対パス（"0/1"）は
    /// 現在のノードからの派生として扱う。誤った階層から派生する事故を防ぐため、
    /// 非マスター鍵に絶対パスを与えると error.InvalidPath になる。
    pub fn derivePath(self: ExtendedKey, path: []const u8) Error!ExtendedKey {
        const parsed = try parsePath(path);
        if (parsed.absolute and self.depth != 0) return error.InvalidPath;
        var node = self;
        for (parsed.indices[0..parsed.len]) |index| {
            node = try node.child(index);
        }
        return node;
    }

    /// Base58Check 形式の拡張鍵文字列（xprv / zpub など）を返す。
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

    /// 拡張鍵文字列を解析する。
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
            var priv_key: [32]u8 = undefined;
            @memcpy(&priv_key, key_data[1..33]);
            if (!secp256k1.isValidPrivateKey(priv_key)) return error.InvalidKey;
            break :blk .{ .priv = priv_key };
        } else blk: {
            var pub_key: [33]u8 = undefined;
            @memcpy(&pub_key, key_data);
            break :blk .{ .pub_key = pub_key };
        };

        return .{
            .version = version,
            .depth = decoded[4],
            .parent_fingerprint = decoded[5..9].*,
            .index = std.mem.readInt(u32, decoded[9..13], .big),
            .chain_code = chain_code,
            .key = key,
        };
    }
};

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "パス解析" {
    const path = try parsePath("m/84'/0'/0'/0/0");
    try testing.expectEqual(@as(usize, 5), path.len);
    try testing.expectEqual(@as(u32, 84 | hardened), path.indices[0]);
    try testing.expectEqual(@as(u32, 0), path.indices[3]);
    try testing.expect(path.absolute);

    // h / H 表記と相対パス
    const alt = try parsePath("84h/0H/0'");
    try testing.expectEqual(@as(usize, 3), alt.len);
    try testing.expectEqual(@as(u32, 84 | hardened), alt.indices[0]);
    try testing.expectEqual(@as(u32, 0 | hardened), alt.indices[1]);
    try testing.expect(!alt.absolute);

    const master = try parsePath("m");
    try testing.expectEqual(@as(usize, 0), master.len);
    try testing.expect(master.absolute);
}

test "不正なパスを拒否する" {
    try testing.expectError(error.InvalidPath, parsePath(""));
    try testing.expectError(error.InvalidPath, parsePath("/0"));
    try testing.expectError(error.InvalidPath, parsePath("m/x"));
    try testing.expectError(error.InvalidPath, parsePath("m/2147483648"));
    try testing.expectError(error.InvalidPath, parsePath("m/0''"));
}

test "マスター鍵と直列化（BIP32 テストベクタ 1）" {
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

test "公開鍵からの派生と秘密鍵からの派生が一致する" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const account = try master.derivePath("m/0'");
    const parent_pub = try account.neuter();

    // m/0'/1 を秘密鍵側と公開鍵側の両方から導出して一致することを確認する
    const node_from_private = try account.derivePath("1"); // 相対パス = m/0'/1
    const node_from_public = try parent_pub.derivePath("1");

    var buf_a: [128]u8 = undefined;
    var buf_b: [128]u8 = undefined;
    try testing.expectEqualStrings(
        try (try node_from_private.neuter()).serialize(&buf_a),
        try node_from_public.serialize(&buf_b),
    );

    // 公開鍵から hardened は派生できない
    try testing.expectError(
        error.InvalidPath,
        parent_pub.derivePath("0'"),
    );
}

test "非マスター鍵に絶対パスを与えると拒否する（誤階層からの派生防止）" {
    const seed = [_]u8{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    };
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const account = try master.derivePath("m/0'");

    // 絶対パスは depth 0 のみ
    try testing.expectError(error.InvalidPath, account.derivePath("m/1"));
    // 相対パスは可
    _ = try account.derivePath("1");
}

test "拡張鍵の解析（ラウンドトリップ）" {
    const text = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs";
    const parsed = try ExtendedKey.parse(text);
    try testing.expectEqual(Version.zpub, parsed.version);
    try testing.expectEqual(false, parsed.keyIsPrivate());
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(text, try parsed.serialize(&buf));

    // 不明なバージョンバイトを拒否する
    try testing.expectError(error.InvalidEncoding, ExtendedKey.parse("not-base58!"));
}

test "バージョン差し替え" {
    const seed: [32]u8 = @splat(0x01);
    const master = try ExtendedKey.fromSeed(&seed, .xprv);
    const zprv = try master.withVersion(.zprv);
    var buf: [128]u8 = undefined;
    try testing.expect(std.mem.startsWith(u8, try zprv.serialize(&buf), "zprv"));

    // 秘密鍵版に公開鍵を入れ替えることはできない
    try testing.expectError(error.InvalidKey, (try master.neuter()).withVersion(.zprv));
}
