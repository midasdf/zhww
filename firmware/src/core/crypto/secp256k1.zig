//! secp256k1 演算（libsecp256k1 へのバインディング）。
//!
//! **設計制約**: 署名・鍵演算は監査済みの libsecp256k1 のみを使う。
//! 純粋な Zig 実装はタイミング攻撃に耐えないため、秘密鍵を扱う演算には使わない。
//!
//! C ヘッダを `@cImport` せず、必要な関数だけを extern 宣言する。
//! 監査時に「どの C 関数に依存しているか」が一目で分かることを優先した。
//!
//! 参考: https://github.com/bitcoin-core/secp256k1

const std = @import("std");
const Error = @import("../errors.zig").Error;
const hashes = @import("hashes.zig");

// --- libsecp256k1 の宣言（secp256k1.h より） ------------------------------

/// 不透明なコンテキスト型。
pub const Context = opaque {};
/// secp256k1_pubkey は 64 バイトの内部表現。
pub const Pubkey = extern struct { data: [64]u8 };

/// SECP256K1_CONTEXT_NONE
const context_none: c_uint = 1 << 0;
/// SECP256K1_EC_COMPRESSED
const ec_compressed: c_uint = (1 << 1) | (1 << 8);
/// SECP256K1_EC_UNCOMPRESSED
const ec_uncompressed: c_uint = (1 << 1);

extern fn secp256k1_context_create(flags: c_uint) ?*Context;
extern fn secp256k1_context_destroy(ctx: ?*Context) void;
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

/// ECDSA 署名（64 バイトのコンパクト表現）。
pub const EcdsaSignature = extern struct { data: [64]u8 };

extern fn secp256k1_ecdsa_sign(
    ctx: *const Context,
    sig: *EcdsaSignature,
    msg32: *const [32]u8,
    seckey: *const [32]u8,
    // noncefp に null を渡すと RFC6979（libsecp256k1 の既定実装）が使われる
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

// --- パラメータ -----------------------------------------------------------

/// secp256k1 の群位数 n。
pub const curve_order: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

pub fn isValidPrivateKey(priv: [32]u8) bool {
    const value = std.mem.readInt(u256, &priv, .big);
    return value != 0 and value < curve_order;
}

fn isValidTweak(tweak: [32]u8) bool {
    const value = std.mem.readInt(u256, &tweak, .big);
    return value < curve_order;
}

// --- コンテキスト ---------------------------------------------------------

var global_context: ?*Context = null;

/// プロセス内で共有するコンテキストを返す。
///
/// 単一スレッドで使う前提（デバイス側はシングルスレッド）。マルチスレッドで
/// 使う場合は呼び出し側で排他すること。
pub fn context() Error!*const Context {
    if (global_context) |ctx| return ctx;
    const created = secp256k1_context_create(context_none) orelse return error.InvalidKey;
    global_context = created;
    return created;
}

/// サイドチャネル対策のブラインディング。デバイス起動時に TRNG の出力で呼ぶ。
pub fn randomize(seed: [32]u8) Error!void {
    if (secp256k1_context_randomize(try context(), &seed) == 0) return error.InvalidKey;
}

// --- 演算 -----------------------------------------------------------------

/// 秘密鍵から圧縮公開鍵（33 バイト）を導出する。
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

/// 秘密鍵から非圧縮公開鍵（65 バイト）。EVM アドレスの導出で使う。
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

/// (priv + tweak) mod n（BIP32 の CKDpriv）。
///
/// 無効な結果になった場合は error.InvalidTweak。BIP32 の仕様では、この場合は
/// その index をスキップして次の index を使う。
pub fn privateTweakAdd(priv: [32]u8, tweak: [32]u8) Error![32]u8 {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    if (!isValidTweak(tweak)) return error.InvalidTweak;
    var secret = priv;
    if (secp256k1_ec_seckey_tweak_add(try context(), &secret, &tweak) == 0) {
        return error.InvalidTweak;
    }
    if (!isValidPrivateKey(secret)) return error.InvalidTweak;
    return secret;
}

/// point(tweak) + pub（BIP32 の CKDpub）。
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

/// 圧縮公開鍵（33 バイト）から x-only 公開鍵（32 バイト）を取り出す。
///
/// BIP340 の lift_x は偶数 Y の点を選ぶため、x 座標を取り出すだけでよい。
pub fn xonly(pub_key: [33]u8) Error![32]u8 {
    if (pub_key[0] != 2 and pub_key[0] != 3) return error.InvalidKey;
    return pub_key[1..33].*;
}

/// BIP341 の鍵パス用の出力鍵（32 バイト x-only）。
///
/// Q = lift_x(internal) + int(HashTapTweak(internal)) * G
pub fn taprootOutputKey(internal_xonly: [32]u8) Error![32]u8 {
    var internal: [33]u8 = undefined;
    internal[0] = 2; // 偶数 Y の点として復元する
    @memcpy(internal[1..], &internal_xonly);
    var tweak: [32]u8 = undefined;
    hashes.taggedHash(&tweak, "TapTweak", &internal_xonly);
    const tweaked = try publicTweakAdd(internal, tweak);
    return xonly(tweaked);
}

// --- ECDSA ---------------------------------------------------------------

/// メッセージハッシュに ECDSA 署名する。
///
/// nonce は libsecp256k1 の既定実装（RFC6979）を使う。**乱数を使わない**ため、
/// 同じ鍵と同じメッセージからは常に同じ署名が得られる（nonce 再利用による鍵漏洩を
/// 構造的に防ぐ）。libsecp256k1 は常に low-s 正規化された署名を返す。
pub fn sign(msg: [32]u8, priv: [32]u8) Error!EcdsaSignature {
    if (!isValidPrivateKey(priv)) return error.InvalidKey;
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_sign(try context(), &sig, &msg, &priv, null, null) == 0) {
        return error.InvalidKey;
    }
    return sig;
}

/// 署名を DER 形式に直列化する（Bitcoin の scriptSig / witness で使う形式）。
pub fn serializeDer(out: []u8, sig: *const EcdsaSignature) Error![]u8 {
    var len: usize = out.len;
    if (secp256k1_ecdsa_signature_serialize_der(try context(), out.ptr, &len, sig) == 0) {
        return error.BufferTooSmall;
    }
    return out[0..len];
}

/// DER 形式の署名を解析する（検証・相互運用のテスト用）。
pub fn parseDer(der: []const u8) Error!EcdsaSignature {
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_signature_parse_der(try context(), &sig, der.ptr, der.len) == 0) {
        return error.InvalidEncoding;
    }
    return sig;
}

/// コンパクト形式（r || s）の署名を解析する。
pub fn parseCompact(compact: [64]u8) Error!EcdsaSignature {
    var sig: EcdsaSignature = undefined;
    if (secp256k1_ecdsa_signature_parse_compact(try context(), &sig, &compact) == 0) {
        return error.InvalidEncoding;
    }
    return sig;
}

/// 署名を検証する。**署名を作ったら必ずこれで検証する**（実装ミスの検出）。
pub fn verify(sig: *const EcdsaSignature, msg: [32]u8, pub_key: [33]u8) Error!bool {
    var pubkey: Pubkey = undefined;
    if (secp256k1_ec_pubkey_parse(try context(), &pubkey, &pub_key, pub_key.len) == 0) {
        return error.InvalidKey;
    }
    return secp256k1_ecdsa_verify(try context(), sig, &msg, &pubkey) == 1;
}

/// 署名が low-s 正規化されているかを確認する（BIP62 / EIP-2 の要件）。
pub fn isNormalized(sig: *const EcdsaSignature) bool {
    return secp256k1_ecdsa_signature_normalize(context() catch return false, null, sig) == 1;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// 16 進文字列を固定長のバイト列に変換する。
fn hexBytes(comptime n: usize, hex: []const u8) [n]u8 {
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch unreachable;
    return out;
}

/// 小さな整数を 32 バイトのビッグエンディアン秘密鍵にする。
fn scalar(value: u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    out[31] = value;
    return out;
}

test "ライブラリがリンクされている（BIP49 テストベクタの公開鍵）" {
    const priv = hexBytes(32, "c9bdb49cfbaedca21c4b1f3a7803c34636b1d7dc55a717132443fc3f4c5867e8");
    const expected = hexBytes(33, "03a1af804ac108a8a51782198c2d034b28bf90c8803f5a53f76276fa69a4eae77f");
    try testing.expectEqualSlices(u8, &expected, &(try pubKeyCompressed(priv)));
}

test "秘密鍵の範囲検証" {
    const zeros: [32]u8 = @splat(0);
    const ones: [32]u8 = @splat(0xFF);
    try testing.expect(!isValidPrivateKey(zeros));
    try testing.expect(!isValidPrivateKey(ones));
    try testing.expect(isValidPrivateKey(scalar(1)));
}

test "CKDpriv の tweak 加算" {
    // 1 + 1 = 2
    const result = try privateTweakAdd(scalar(1), scalar(1));
    try testing.expectEqualSlices(u8, &scalar(2), &result);

    // 無効な tweak（n 以上）を拒否する
    const overflow: [32]u8 = @splat(0xFF);
    try testing.expectError(error.InvalidTweak, privateTweakAdd(scalar(1), overflow));
}

test "CKDpub の tweak 加算（1*G + 1*G = 2*G）" {
    const point_one = try pubKeyCompressed(scalar(1));
    const point_two = try pubKeyCompressed(scalar(2));
    try testing.expectEqualSlices(u8, &point_two, &(try publicTweakAdd(point_one, scalar(1))));
}

test "Taproot 出力鍵（BIP86 テストベクタ）" {
    const internal = hexBytes(32, "cc8a4bc64d897bddc5fbc2f670f7a8ba0b386779106cf1223c6fc5d7cd6fc115");
    const expected = hexBytes(32, "a60869f0dbcf1dc659c9cecbaf8050135ea9e8cdc487053f1dc6880949dc684c");
    try testing.expectEqualSlices(u8, &expected, &(try taprootOutputKey(internal)));
}

test "ECDSA 署名と検証" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    const pub_key = try pubKeyCompressed(priv);
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const sig = try sign(msg, priv);
    try testing.expect(try verify(&sig, msg, pub_key));

    // メッセージを変えると検証に失敗する
    var tampered = msg;
    tampered[0] ^= 0x01;
    try testing.expect(!try verify(&sig, tampered, pub_key));

    // 別の鍵では検証に失敗する
    const other_pub = try pubKeyCompressed(scalar(2));
    try testing.expect(!try verify(&sig, msg, other_pub));
}

test "署名は決定論的（RFC6979）で low-s である" {
    const priv = hexBytes(32, "619c335025c7f4012e556c2a58b2506e30b8511b53ade95ea316fd8c3286feb9");
    var msg: [32]u8 = undefined;
    for (&msg, 0..) |*byte, i| byte.* = @intCast(i);

    const first = try sign(msg, priv);
    const second = try sign(msg, priv);
    try testing.expectEqualSlices(u8, &first.data, &second.data);

    // libsecp256k1 は常に low-s を返す（正規化が不要）
    try testing.expect(!isNormalized(&first));
}

test "DER 直列化と解析のラウンドトリップ" {
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

    // 壊れた DER は解析できない
    try testing.expectError(error.InvalidEncoding, parseDer(&[_]u8{ 0x30, 0x00 }));
}
