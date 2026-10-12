//! Ethereum トランザクションの署名（EIP-155 legacy と EIP-1559 type 2）。
//!
//! **署名対象ハッシュ**
//! - legacy: `keccak256(RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]))`
//! - 1559  : `keccak256(0x02 || RLP([chainId, nonce, maxPriorityFeePerGas, maxFeePerGas,
//!                                  gasLimit, to, value, data, accessList]))`
//!
//! **署名済みトランザクション**
//! - legacy: `RLP([nonce, gasPrice, gasLimit, to, value, data, v, r, s])`、`v = chainId * 2 + 35 + yParity`
//! - 1559  : `0x02 || RLP([... , yParity, r, s])`
//!
//! **設計方針**
//! - **メモリ確保をしない**。鍵を扱う経路で `OutOfMemory` を起こさないため、出力先は
//!   呼び出し側が用意する（足りなければ `error.BufferTooSmall`）。
//! - リストの長さはヘッダに書く必要があるため、まず「同じフィールド書き込み」を
//!   `MeasureSink` で走らせて長さを測る。長さの手計算によるハッシュ不一致を
//!   構造的に防ぐ（フィールド順の定義は 1 箇所だけ）。
//! - 署名演算は監査済み libsecp256k1 のみを使い、**署名したら必ず検証する**。
//! - pre-EIP-155（`v = 27/28`）は対応しない。リプレイ攻撃を許すため、意図的に
//!   非対応としている。
//!
//! 参考: https://eips.ethereum.org/EIPS/eip-155
//!       https://eips.ethereum.org/EIPS/eip-1559
//!       https://eips.ethereum.org/EIPS/eip-2718
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../../core/errors.zig").Error;
const hashes = @import("../../core/crypto/hashes.zig");
const secp256k1 = @import("../../core/crypto/secp256k1.zig");
const rlp = @import("rlp.zig");

/// EIP-2718 の type 2（EIP-1559）を表す先頭バイト。
pub const transaction_type_eip1559: u8 = 0x02;

/// EIP-155（legacy）トランザクションのフィールド。
pub const LegacyTx = struct {
    nonce: u256,
    gas_price: u256,
    gas_limit: u256,
    /// 送信先。null はコントラクト作成（空文字列として符号化する）。
    to: ?[20]u8,
    value: u256,
    data: []const u8,
    /// EIP-155 のチェーン ID。`v = chain_id * 2 + 35 + yParity` になる。
    chain_id: u256,
};

/// EIP-2930 のアクセスリスト項目（EIP-1559 でも使う）。
pub const AccessListItem = struct {
    address: [20]u8,
    storage_keys: []const [32]u8,
};

/// EIP-1559（type 2）トランザクションのフィールド。
pub const Eip1559Tx = struct {
    chain_id: u256,
    nonce: u256,
    max_priority_fee_per_gas: u256,
    max_fee_per_gas: u256,
    gas_limit: u256,
    /// 送信先。null はコントラクト作成。
    to: ?[20]u8,
    value: u256,
    data: []const u8,
    access_list: []const AccessListItem = &.{},
};

// ---------------------------------------------------------------- RLP 出力先
//
// 「長さを測る」「ハッシュに入れる」「バッファに書く」の 3 通りを、同じフィールド順の
// コードで使い回すための小さなインタフェース（`uint` / `bytes` / `listHeader`）。

/// 符号化後の長さだけを数える。
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

/// Keccak-256 に流し込む。
const HashSink = struct {
    hasher: *hashes.Keccak256,

    fn uint(self: HashSink, value: u256) Error!void {
        var buf: [33]u8 = undefined;
        self.hasher.update(try rlp.encodeUint(&buf, value));
    }

    fn bytes(self: HashSink, data: []const u8) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        const header = try rlp.encodeBytesHeader(&header_buf, data);
        // ヘッダが空（1 バイトかつ < 0x80）の場合は本体だけを書く
        if (header.len != 0) self.hasher.update(header);
        self.hasher.update(data);
    }

    fn listHeader(self: HashSink, payload_len: usize) Error!void {
        var header_buf: [rlp.max_header_len]u8 = undefined;
        self.hasher.update(try rlp.encodeListHeader(&header_buf, payload_len));
    }
};

/// 出力バッファに書く。
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

/// 長さの加算。あふれる場合は「バッファに収まらない」として拒否する。
fn addLen(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.BufferTooSmall;
}

// ---------------------------------------------------------------- フィールド
//
// フィールド順の定義はここだけに置く（長さ測定・ハッシュ・直列化で共用）。

/// `to` フィールド。コントラクト作成時は空文字列。
fn writeTo(sink: anytype, to: ?[20]u8) Error!void {
    if (to) |address| {
        var bytes = address;
        try sink.bytes(&bytes);
    } else {
        try sink.bytes(&.{});
    }
}

/// legacy の共通部分（nonce, gasPrice, gasLimit, to, value, data）。
fn writeLegacyFields(tx: LegacyTx, sink: anytype) Error!void {
    try sink.uint(tx.nonce);
    try sink.uint(tx.gas_price);
    try sink.uint(tx.gas_limit);
    try writeTo(sink, tx.to);
    try sink.uint(tx.value);
    try sink.bytes(tx.data);
}

/// EIP-155 の署名対象（chainId, 0, 0 を末尾に足した 9 要素）。
fn writeLegacySigningFields(tx: LegacyTx, sink: anytype) Error!void {
    try writeLegacyFields(tx, sink);
    try sink.uint(tx.chain_id);
    try sink.uint(0);
    try sink.uint(0);
}

/// EIP-155 の署名済み（v, r, s を末尾に足した 9 要素）。
fn writeLegacySignedFields(value: LegacySignedFields, sink: anytype) Error!void {
    try writeLegacyFields(value.tx, sink);
    try sink.uint(value.v);
    try sink.uint(value.r);
    try sink.uint(value.s);
}

/// `writeLegacySignedFields` の入力。
const LegacySignedFields = struct { tx: LegacyTx, v: u256, r: u256, s: u256 };

/// アクセスリストの各項目の中身（アドレスとストレージキーのリスト）。
fn writeAccessListItem(item: AccessListItem, sink: anytype) Error!void {
    var address = item.address;
    try sink.bytes(&address);

    // ストレージキーのリスト（[32 バイト, ...]）
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

/// アクセスリスト全体（項目のリスト）。
fn writeAccessList(access_list: []const AccessListItem, sink: anytype) Error!void {
    // 1) 長さを測る: 各項目は「項目リストのヘッダ + 中身」
    var measure = MeasureSink{};
    for (access_list) |item| {
        var item_measure = MeasureSink{};
        try writeAccessListItem(item, &item_measure);
        try measure.listHeader(item_measure.written);
        try writeAccessListItem(item, &measure);
    }

    // 2) 測った長さでヘッダを書き、中身を書く
    try sink.listHeader(measure.written);
    for (access_list) |item| {
        var item_measure = MeasureSink{};
        try writeAccessListItem(item, &item_measure);
        try sink.listHeader(item_measure.written);
        try writeAccessListItem(item, sink);
    }
}

/// EIP-1559 の共通部分
/// （chainId, nonce, maxPriorityFeePerGas, maxFeePerGas, gasLimit, to, value, data, accessList）。
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

/// EIP-1559 の署名済み（yParity, r, s を末尾に足した 12 要素）。
fn writeEip1559SignedFields(value: Eip1559SignedFields, sink: anytype) Error!void {
    try writeEip1559Fields(value.tx, sink);
    try sink.uint(value.y_parity);
    try sink.uint(value.r);
    try sink.uint(value.s);
}

/// `writeEip1559SignedFields` の入力。
const Eip1559SignedFields = struct { tx: Eip1559Tx, y_parity: u1, r: u256, s: u256 };

/// フィールド群を 1 つの RLP リストにして `out` に書く。
///
/// まず `MeasureSink` で長さを測り、その長さでリストヘッダを書いてから本体を書く。
/// 最後に測った長さと書いた長さが一致することを確認する（内部矛盾の検出）。
fn encodeListWith(comptime writeFields: anytype, value: anytype, out: []u8) Error![]u8 {
    var measure = MeasureSink{};
    try writeFields(value, &measure);

    const header = try rlp.encodeListHeader(out, measure.written);
    var sink = SliceSink{ .out = out[header.len..] };
    try writeFields(value, &sink);
    if (sink.pos != measure.written) return error.InvalidEncoding;

    return out[0 .. header.len + sink.pos];
}

/// EIP-2718 の型付きトランザクション（`0x02 || RLP(...)`）を `out` に書く。
fn encodeTypedListWith(comptime writeFields: anytype, value: anytype, out: []u8) Error![]u8 {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = transaction_type_eip1559;
    const body = try encodeListWith(writeFields, value, out[1..]);
    return out[0 .. 1 + body.len];
}

// ---------------------------------------------------------------- 署名対象

/// EIP-155 の署名対象（9 要素の RLP）を `out` に書く。
pub fn legacySigningPayload(out: []u8, tx: LegacyTx) Error![]u8 {
    return encodeListWith(writeLegacySigningFields, tx, out);
}

/// EIP-155 の署名対象ハッシュ。
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

/// EIP-1559 の署名対象（`0x02 || RLP(...)`）を `out` に書く。
pub fn eip1559SigningPayload(out: []u8, tx: Eip1559Tx) Error![]u8 {
    return encodeTypedListWith(writeEip1559Fields, tx, out);
}

/// EIP-1559 の署名対象ハッシュ。
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

// ---------------------------------------------------------------- 署名

/// EIP-155 の `v`。`v = chain_id * 2 + 35 + yParity`。
pub fn legacyV(chain_id: u256, y_parity: u1) Error!u256 {
    // v が u256 をあふれるチェーン ID は実在しないが、計算前に拒否する
    // （35 と yParity の最大値 1 を足しても収まる上限）。
    const max_chain_id = (std.math.maxInt(u256) - 36) / 2;
    if (chain_id > max_chain_id) return error.InvalidEncoding;
    return chain_id * 2 + 35 + y_parity;
}

/// ECDSA 署名の成分。
pub const Signature = struct {
    /// `r`（32 バイトのビッグエンディアン）。
    r: u256,
    /// `s`（32 バイトのビッグエンディアン、EIP-2 により low-s）。
    s: u256,
    /// `y` 座標の偶奇。legacy の `v` と EIP-1559 の `yParity` に使う。
    y_parity: u1,
};

// libsecp256k1 の recoverable 署名。
//
// **注意**: `secp256k1_ecdsa_signature` の `data[64]` は内部表現であり、r || s の
// ビッグエンディアンではない（ヘッダにも「不透明な型」と明記されている）。
// 実際、この環境の libsecp256k1 0.8.0 では各スカラーがリトルエンディアンで入る。
// r || s と recovery id は `core.crypto.secp256k1.signRecoverable` で取得する
// （libsecp256k1 への extern 宣言は core に集約してある）。

/// ハッシュに署名し、`r` / `s` / `y_parity` を返す。**必ず検証してから返す。**
fn signHash(hash: [32]u8, priv: [32]u8) Error!Signature {
    if (!secp256k1.isValidPrivateKey(priv)) return error.InvalidKey;

    const result = try secp256k1.signRecoverable(hash, priv);
    const signature = Signature{
        .r = std.mem.readInt(u256, result.compact[0..32], .big),
        .s = std.mem.readInt(u256, result.compact[32..64], .big),
        .y_parity = @intCast(result.recovery_id),
    };

    // EIP-2: トランザクションの s は low-s でなければならない
    if (signature.s > secp256k1.curve_order / 2) return error.SignatureInvalid;

    // 署名は必ず検証する（実装ミスの検出）
    const parsed = try secp256k1.parseCompact(result.compact);
    if (!try secp256k1.verify(&parsed, hash, try secp256k1.pubKeyCompressed(priv))) {
        return error.SignatureInvalid;
    }
    return signature;
}

/// EIP-155（legacy）トランザクションに署名し、署名済み raw tx を `out` に書く。
pub fn signLegacy(out: []u8, tx: LegacyTx, priv: [32]u8) Error![]u8 {
    const signature = try signHash(try legacySigningHash(tx), priv);
    return encodeLegacySigned(out, tx, try legacyV(tx.chain_id, signature.y_parity), signature.r, signature.s);
}

/// EIP-1559（type 2）トランザクションに署名し、署名済み raw tx を `out` に書く。
pub fn signEip1559(out: []u8, tx: Eip1559Tx, priv: [32]u8) Error![]u8 {
    const signature = try signHash(try eip1559SigningHash(tx), priv);
    return encodeEip1559Signed(out, tx, signature.y_parity, signature.r, signature.s);
}

/// 外部で署名した成分から EIP-155 の署名済み raw tx を組み立てる
/// （ハードウェア署名器の連携と、公式テストベクタとの突合に使う）。
pub fn encodeLegacySigned(out: []u8, tx: LegacyTx, v: u256, r: u256, s: u256) Error![]u8 {
    return encodeListWith(writeLegacySignedFields, LegacySignedFields{ .tx = tx, .v = v, .r = r, .s = s }, out);
}

/// 外部で署名した成分から EIP-1559 の署名済み raw tx を組み立てる。
pub fn encodeEip1559Signed(out: []u8, tx: Eip1559Tx, y_parity: u1, r: u256, s: u256) Error![]u8 {
    return encodeTypedListWith(
        writeEip1559SignedFields,
        Eip1559SignedFields{ .tx = tx, .y_parity = y_parity, .r = r, .s = s },
        out,
    );
}

// ---------------------------------------------------------------- テスト

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

test "EIP-155 の公式例（署名対象・署名ハッシュ・署名済み tx がバイト一致）" {
    // https://eips.ethereum.org/EIPS/eip-155 の Example。
    // nonce=9, gasPrice=20 gwei, gasLimit=21000, to=0x3535...35, value=1 ether, chainId=1。
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

    // 署名対象（9 要素。chain_id と 0, 0 が付く）
    try expectHex("ec098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a764000080018080", try legacySigningPayload(&payload_buf, tx));
    // 署名ハッシュ
    try expectHex("daf5a779ae972f972197303d7b574746c7ef83eadac0f2791ad23db92e4c8e53", &(try legacySigningHash(tx)));
    // 署名済み tx（v = 37 = chainId * 2 + 35 + 1）
    try expectHex("f86c098504a817c800825208943535353535353535353535353535353535353535880de0b6b3a76400008025a028ef61340bd939bc2195fe537567866003e1a15d3c71ff63e1590620aa636276a067cbe9d8997f761aecb703304b3800ccf555c9f3dc64214b297fb1966a3b6d83", try signLegacy(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
    // 公式例の v は 37（yParity = 0）。yParity = 1 なら 38 になる。
    try testing.expectEqual(@as(u256, 37), try legacyV(1, 0));
    try testing.expectEqual(@as(u256, 38), try legacyV(1, 1));
}

test "legacy のコントラクト作成（to が空）が独立実装とバイト一致" {
    // 期待値は eth_account 0.13.7（Account.sign_transaction）で算出。
    // to が null のときは空文字列（0x80）として符号化する。
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

test "EIP-1559 の署名が独立実装（eth_account）とバイト一致" {
    // 期待値は eth_account 0.13.7（TypedTransaction.encode/hash と Account.sign_transaction）。
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

test "EIP-1559 のアクセスリストとコントラクト作成が独立実装とバイト一致" {
    // 期待値は eth_account 0.13.7。アクセスリストの構造（アドレス + ストレージキーの入れ子）も
    // ここで検証する。
    const tx = Eip1559Tx{
        .chain_id = 137,
        .nonce = 0,
        .max_priority_fee_per_gas = 2000000000,
        .max_fee_per_gas = 50000000000,
        .gas_limit = 60000,
        .to = null,
        .value = 0,
        .data = "`\x80`@R",
        .access_list = &[_]AccessListItem{ .{ .address = hexBytes(20, "3535353535353535353535353535353535353535"), .storage_keys = &[_][32]u8{ hexBytes(32, "0000000000000000000000000000000000000000000000000000000000000001"), hexBytes(32, "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff") } } },
    };
    var payload_buf: [256]u8 = undefined;
    var out: [256]u8 = undefined;

    try expectHex("02f8768189808477359400850ba43b740082ea608080856080604052f85bf859943535353535353535353535353535353535353535f842a00000000000000000000000000000000000000000000000000000000000000001a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", try eip1559SigningPayload(&payload_buf, tx));
    try expectHex("00a955dcd675bf9f1161e28756916ac110faaf546bfa0f9e78f2d3ef9db64747", &(try eip1559SigningHash(tx)));
    try expectHex("02f8b98189808477359400850ba43b740082ea608080856080604052f85bf859943535353535353535353535353535353535353535f842a00000000000000000000000000000000000000000000000000000000000000001a0ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff80a00930a6e3686fda2930fd48cacf757207598558136159552078e903a6768e263fa05f6dc3ed5307c88ee976370fd9a13035e604daa7815d47d8932ca9fbecb41343", try signEip1559(&out, tx, hexBytes(32, "4646464646464646464646464646464646464646464646464646464646464646")));
}

test "EIP-1559 の公式テストベクタ（ethereum/tests ttEIP1559 maxFeePerGas32BytesValue）" {
    // TransactionTests/ttEIP1559/maxFeePerGas32BytesValue.json の txbytes とバイト一致すること。
    // maxFeePerGas が 32 バイト（0xa0 + 32 バイト）。署名は filler が固定値（r/s は全ファイル共通のダミー）なので、
    // 署名済み tx は署名成分から組み立てて比較する。署名対象と署名ハッシュは
    // 独立実装（eth_account の TypedTransaction.encode/hash）と一致を確認済み。
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

test "EIP-1559 の公式テストベクタ（ethereum/tests ttEIP1559 maxPriorityFeePerGass32BytesValue）" {
    // TransactionTests/ttEIP1559/maxPriorityFeePerGass32BytesValue.json の txbytes とバイト一致すること。
    // maxPriorityFeePerGas が 32 バイト。署名は filler が固定値（r/s は全ファイル共通のダミー）なので、
    // 署名済み tx は署名成分から組み立てて比較する。署名対象と署名ハッシュは
    // 独立実装（eth_account の TypedTransaction.encode/hash）と一致を確認済み。
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

test "EIP-1559 の公式テストベクタ（ethereum/tests ttEIP1559 GasLimitPriceProductOverflow）" {
    // TransactionTests/ttEIP1559/GasLimitPriceProductOverflow.json の txbytes とバイト一致すること。
    // maxFeePerGas が 31 バイト（0x9f + 31 バイト）。署名は filler が固定値（r/s は全ファイル共通のダミー）なので、
    // 署名済み tx は署名成分から組み立てて比較する。署名対象と署名ハッシュは
    // 独立実装（eth_account の TypedTransaction.encode/hash）と一致を確認済み。
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

test "v の計算（EIP-155）" {
    try testing.expectEqual(@as(u256, 35), try legacyV(0, 0));
    try testing.expectEqual(@as(u256, 37), try legacyV(1, 0));
    try testing.expectEqual(@as(u256, 38), try legacyV(1, 1));
    try testing.expectEqual(@as(u256, 46), try legacyV(5, 1));

    // v が u256 をあふれるチェーン ID は拒否する
    const max_chain_id = (std.math.maxInt(u256) - 36) / 2;
    _ = try legacyV(max_chain_id, 1); // 上限（yParity = 1 でも収まる）
    try testing.expectError(error.InvalidEncoding, legacyV(max_chain_id + 1, 0));
}

test "r / s は先頭ゼロを付けずに正準 RLP で符号化する" {
    // 公式ベクタではなく符号化の確認用（r = 0x80 は 0x8180、s = 1 は 0x01）。
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
    // 末尾 4 バイトは yParity=1, r=0x80, s=1
    try expectHex("01818001", raw[raw.len - 4 ..]);
}

test "署名済み tx は正準な RLP である" {
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
    // decodeList は正準性まで検査する（非正準な出力なら失敗する）
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

test "不正な鍵と小さすぎる出力バッファを拒否する" {
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
