//! UR（Uniform Resource）: バイナリデータを `ur:<type>/<bytewords>` の形で
//! QR コードや URI に載せて運ぶ符号化。
//!
//! **対応する範囲**
//! - 単一パート: `ur:<type>/<bytewords>`（BCR-2020-005 §UR Encoding）。
//! - マルチパート: `ur:<type>/<seqNum>-<seqLen>/<bytewords>`。
//!   `bytewords` はパートの CBOR `[seqNum, seqLen, messageLen, checksum, data]` を符号化したもの。
//! - **逐次パート（seqNum = 1..seqLen）のみ対応**。ファウンテン符号の冗長パート
//!   （seqNum > seqLen、複数のフラグメントを XOR で混ぜたもの）は **生成しない**。
//!   デコーダは冗長パートを構造としては受理するが、復元には使わない
//!   （`Status.fountain_unsupported` を返す）。BCR-2024-001 の MUR 完全対応は未実装。
//! - 型名（`bytes` / `crypto-psbt` など）は文字列として扱うだけで、中身は解釈しない。
//!
//! **設計方針**
//! - パート番号は仕様どおり **1 始まり**。フラグメントの 0 始まり添字は `seqNum - 1`。
//! - デコーダは順不同・重複ありの入力を受け付け、`seqLen` 個そろったときだけ CRC-32 を
//!   検証して完成とする。そろわないうちは `Status.need_more` を返し、**完成扱いしない**。
//! - 最初に受理したパートが「メッセージ長・分割数・チェックサム・フラグメント長」を決める。
//!   以降のパートがこれらと食い違う場合（別のメッセージのパートを混ぜた場合など）は
//!   error.InvalidEncoding で拒否する（リファレンス実装は黙って捨てるが、こちらは厳格に拒否する）。
//! - UR は大文字小文字を区別しない。QR コード（英数字モード）向けに大文字で出力できる。
//! - メッセージ全体は dCBOR でなければならないため、完成時に CBOR としての構造検査も行う。
//! - 秘密情報を扱わないため、メモリ確保は行わない（作業領域は呼び出し側が用意する）。
//!
//! 参考: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-005-ur.md
//!       https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2024-001-multipart-ur.md
//! テストベクタの出典:
//!   - BCR-2020-005 §UR CBOR Tags の seed の例（ur:seed/oyad...）
//!   - bc-ur（C++ リファレンス実装）test/test.cpp の test_single_part_ur / test_ur_encoder
//!     https://github.com/BlockchainCommons/bc-ur/blob/master/test/test.cpp
//!   - bc-ur-rust src/ur.rs の test_ur（ur:test/lsadaoaxjygonesw）
//!     https://github.com/BlockchainCommons/bc-ur-rust/blob/master/src/ur.rs
//!   - BCR-2024-001 §5 の findNominalFragmentLength のテストベクタ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../core/errors.zig").Error;
const bytewords = @import("bytewords.zig");
const cbor = @import("cbor.zig");

/// UR の型名の最大長（実用上は `crypto-psbt` 程度）。
pub const max_type_len = 32;
/// `bytes` 型（仕様では試験・検証用とされている）。
pub const type_bytes = "bytes";
/// `crypto-psbt` 型（PSBT を運ぶ）。
pub const type_crypto_psbt = "crypto-psbt";
/// URI スキーム。
pub const scheme = "ur:";
/// フラグメント長の下限の既定値（bc-ur / URKit の既定値に合わせる）。
pub const default_min_fragment_len = 10;

/// 出力文字列の大文字小文字。UR は case agnostic で、QR コードの英数字モードでは
/// 大文字の方が効率がよい。
pub const TextCase = enum { lower, upper };

/// seq（パート番号と分割数）。
pub const Seq = struct {
    /// パート番号。**1 始まり**。seqLen を超える値はファウンテン符号の冗長パート。
    num: u32,
    /// メッセージの分割数。
    len: u32,
};

/// 分解した UR 文字列。
pub const Uri = struct {
    /// 型名（入力の大文字小文字のまま。入力の一部を指す）。
    ur_type: []const u8,
    /// マルチパートの seq。単一パートなら null。
    seq: ?Seq = null,
    /// `<message>` または `<fragment>` の bytewords 部分（入力の一部を指す）。
    body: []const u8,
};

/// パート（マルチパート UR の中身）。
pub const Part = struct {
    seq_num: u32,
    seq_len: u32,
    /// メッセージ全体のバイト数（パディングを含まない）。
    message_len: usize,
    /// メッセージ全体の CRC-32。
    checksum: u32,
    /// フラグメント（末尾のパートは 0 でパディングされている）。
    data: []const u8,
};

// ---------------------------------------------------------------- 型名

/// 型名として妥当か（英字・数字・ハイフンのみ、1〜max_type_len 文字）。
pub fn isValidType(ur_type: []const u8) bool {
    if (ur_type.len == 0 or ur_type.len > max_type_len) return false;
    for (ur_type) |c| {
        const lower = std.ascii.toLower(c);
        if (lower >= 'a' and lower <= 'z') continue;
        if (c >= '0' and c <= '9') continue;
        if (c == '-') continue;
        return false;
    }
    return true;
}

/// 型名を大文字小文字を無視して比較する。
pub fn typeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn upperCase(text: []u8) void {
    for (text) |*c| c.* = std.ascii.toUpper(c.*);
}

fn digitsLen(value: u32) usize {
    var len: usize = 1;
    var rest = value / 10;
    while (rest != 0) : (rest /= 10) len += 1;
    return len;
}

/// 10 進数を書く。戻り値は書いたバイト数。領域は `digitsLen` 以上あること。
fn writeDigits(out: []u8, value: u32) usize {
    var buf: [10]u8 = undefined;
    var index: usize = buf.len;
    var rest = value;
    while (true) {
        index -= 1;
        buf[index] = '0' + @as(u8, @intCast(rest % 10));
        rest /= 10;
        if (rest == 0) break;
    }
    const len = buf.len - index;
    @memcpy(out[0..len], buf[index..]);
    return len;
}

fn parseDigits(text: []const u8) Error!u32 {
    if (text.len == 0 or text.len > 10) return error.InvalidEncoding;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.InvalidEncoding;
        const digit: u32 = c - '0';
        if (value > (std.math.maxInt(u32) - digit) / 10) return error.InvalidEncoding;
        value = value * 10 + digit;
    }
    return value;
}

// ---------------------------------------------------------------- 単一パート

/// 単一パート UR `ur:<type>/<bytewords(message)>` を組み立てる。
///
/// `message` はタグ無しの CBOR（PSBT なら CBOR のバイト文字列、`bytes` 型なら任意のバイト列を
/// CBOR のバイト文字列にしたもの）。bytewords には CRC-32 が付く。
pub fn encodeSingle(out: []u8, ur_type: []const u8, message: []const u8, case: TextCase) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;
    // CBOR は最低 1 バイト。空のメッセージは UR として復号できないので拒否する。
    if (message.len == 0) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1;
    if (out.len < prefix_len + bytewords.encodedLength(message.len, .minimal)) {
        return error.BufferTooSmall;
    }

    @memcpy(out[0..scheme.len], scheme);
    @memcpy(out[scheme.len..][0..ur_type.len], ur_type);
    out[scheme.len + ur_type.len] = '/';

    const body = try bytewords.encodeWithChecksum(out[prefix_len..], message, .minimal);
    const total = prefix_len + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// 生のバイト列を CBOR のバイト文字列に包んで単一パート UR にする。
///
/// `ur:bytes` や `ur:crypto-psbt` のように「中身は 1 つのバイト文字列」という型で使う。
/// ペイロードを一時バッファにコピーしない（CBOR ヘッダと本体をまとめて符号化する）。
pub fn encodeSingleByteString(
    out: []u8,
    ur_type: []const u8,
    payload: []const u8,
    case: TextCase,
) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1;
    const message_len = cbor.bytesLength(payload.len);
    if (out.len < prefix_len + bytewords.encodedLength(message_len, .minimal)) {
        return error.BufferTooSmall;
    }

    var header: [cbor.max_header_len]u8 = undefined;
    const header_bytes = try cbor.writeBytesHeader(&header, payload.len);

    @memcpy(out[0..scheme.len], scheme);
    @memcpy(out[scheme.len..][0..ur_type.len], ur_type);
    out[scheme.len + ur_type.len] = '/';

    const body = try bytewords.encodeWithChecksumParts(out[prefix_len..], &.{ header_bytes, payload }, .minimal);
    const total = prefix_len + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// UR 文字列を型名・seq・bytewords 部分に分解する（大文字小文字はそのまま返す）。
///
/// 返るスライスは `text` の一部を指す。
pub fn parse(text: []const u8) Error!Uri {
    if (text.len < scheme.len + 3) return error.InvalidEncoding;
    if (!typeEql(text[0..scheme.len], scheme)) return error.InvalidEncoding;

    const rest = text[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidEncoding;

    const ur_type = rest[0..slash];
    if (!isValidType(ur_type)) return error.InvalidEncoding;

    const tail = rest[slash + 1 ..];
    if (tail.len == 0) return error.InvalidEncoding;

    if (std.mem.indexOfScalar(u8, tail, '/')) |sep| {
        const seq_text = tail[0..sep];
        const body = tail[sep + 1 ..];
        if (body.len == 0) return error.InvalidEncoding;
        if (std.mem.indexOfScalar(u8, body, '/') != null) return error.InvalidEncoding;

        const dash = std.mem.indexOfScalar(u8, seq_text, '-') orelse return error.InvalidEncoding;
        const num = try parseDigits(seq_text[0..dash]);
        const len = try parseDigits(seq_text[dash + 1 ..]);
        if (num == 0 or len == 0) return error.InvalidEncoding;
        return .{ .ur_type = ur_type, .seq = .{ .num = num, .len = len }, .body = body };
    }

    return .{ .ur_type = ur_type, .body = tail };
}

/// 単一パート UR を復号する。`expected_type` を指定すると型名も検査する。
///
/// デコードしたメッセージが dCBOR として壊れていないことも検査する。
pub fn decodeSingle(out: []u8, text: []const u8, expected_type: ?[]const u8) Error![]u8 {
    const uri = try parse(text);
    if (uri.seq != null) return error.InvalidEncoding;
    if (expected_type) |wanted| {
        if (!typeEql(wanted, uri.ur_type)) return error.InvalidEncoding;
    }

    const message = try bytewords.decode(out, uri.body, .minimal);
    if (!cbor.isWellFormed(message, true)) return error.InvalidEncoding;
    return message;
}

// ---------------------------------------------------------------- パート

/// パートの CBOR `[seqNum, seqLen, messageLen, checksum, data]` の長さ。
///
/// 作業領域（`Encoder.init` の `scratch`）の大きさを決めるのに使う。
pub fn partCborLength(seq_num: u32, seq_len: u32, message_len: usize, checksum: u32, data_len: usize) usize {
    return 1 + cbor.headLength(seq_num) + cbor.headLength(seq_len) + cbor.headLength(message_len) +
        cbor.headLength(checksum) + cbor.headLength(data_len) + data_len;
}

/// フラグメント長 `fragment_len` のパート CBOR が取りうる最大長。
///
/// 作業領域（`Encoder.init` の `scratch` / `Decoder.init` の `part_buf`）は
/// これ以上を用意すればよい。
pub fn maxPartCborLength(fragment_len: usize) usize {
    return partCborLength(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
        std.math.maxInt(usize),
        std.math.maxInt(u32),
        fragment_len,
    );
}

/// パートの CBOR（配列 5 要素）を書き出す。
pub fn encodePart(out: []u8, part: Part) Error![]u8 {
    if (part.seq_num == 0 or part.seq_len == 0 or part.message_len == 0) return error.InvalidEncoding;

    var pos: usize = 0;
    pos += (try cbor.writeArrayHeader(out[pos..], 5)).len;
    pos += (try cbor.writeUint(out[pos..], part.seq_num)).len;
    pos += (try cbor.writeUint(out[pos..], part.seq_len)).len;
    pos += (try cbor.writeUint(out[pos..], part.message_len)).len;
    pos += (try cbor.writeUint(out[pos..], part.checksum)).len;
    pos += (try cbor.writeBytes(out[pos..], part.data)).len;
    return out[0..pos];
}

/// パートの CBOR を読み取る。返る `data` は入力の一部を指す。
pub fn decodePart(bytes: []const u8) Error!Part {
    var reader = cbor.Reader.init(bytes);
    if (try reader.readArrayHeader() != 5) return error.InvalidEncoding;

    const seq_num = try reader.readUint();
    const seq_len = try reader.readUint();
    const message_len = try reader.readUint();
    const checksum = try reader.readUint();
    const data = try reader.readBytes();
    try reader.finish();

    if (seq_num == 0 or seq_num > std.math.maxInt(u32)) return error.InvalidEncoding;
    if (seq_len == 0 or seq_len > std.math.maxInt(u32)) return error.InvalidEncoding;
    if (message_len == 0 or message_len > std.math.maxInt(usize)) return error.InvalidEncoding;
    if (checksum > std.math.maxInt(u32)) return error.InvalidEncoding;

    return .{
        .seq_num = @intCast(seq_num),
        .seq_len = @intCast(seq_len),
        .message_len = @intCast(message_len),
        .checksum = @intCast(checksum),
        .data = data,
    };
}

/// 符号化済みのパート CBOR を `ur:<type>/<seqNum>-<seqLen>/<bytewords>` にする。
pub fn encodePartUr(
    out: []u8,
    ur_type: []const u8,
    seq_num: u32,
    seq_len: u32,
    part_cbor: []const u8,
    case: TextCase,
) Error![]u8 {
    if (!isValidType(ur_type)) return error.InvalidEncoding;
    if (seq_num == 0 or seq_len == 0) return error.InvalidEncoding;

    const prefix_len = scheme.len + ur_type.len + 1 + digitsLen(seq_num) + 1 + digitsLen(seq_len) + 1;
    if (out.len < prefix_len + bytewords.encodedLength(part_cbor.len, .minimal)) return error.BufferTooSmall;

    var pos: usize = 0;
    @memcpy(out[pos..][0..scheme.len], scheme);
    pos += scheme.len;
    @memcpy(out[pos..][0..ur_type.len], ur_type);
    pos += ur_type.len;
    out[pos] = '/';
    pos += 1;
    pos += writeDigits(out[pos..], seq_num);
    out[pos] = '-';
    pos += 1;
    pos += writeDigits(out[pos..], seq_len);
    out[pos] = '/';
    pos += 1;

    const body = try bytewords.encodeWithChecksum(out[pos..], part_cbor, .minimal);
    const total = pos + body.len;
    if (case == .upper) upperCase(out[0..total]);
    return out[0..total];
}

/// マルチパート UR 文字列からパートを取り出す。
pub const DecodedPart = struct {
    ur_type: []const u8,
    seq: Seq,
    part: Part,
};

/// UR 文字列（マルチパート）をパートに復号する。
///
/// パスの `seq` と CBOR の `seqNum` / `seqLen` が食い違う場合は error.InvalidEncoding。
/// 返る `part.data` は `part_buf` の一部を指す。
pub fn decodePartUr(part_buf: []u8, text: []const u8) Error!DecodedPart {
    const uri = try parse(text);
    const seq = uri.seq orelse return error.InvalidEncoding;

    const part_bytes = try bytewords.decode(part_buf, uri.body, .minimal);
    const part = try decodePart(part_bytes);
    if (part.seq_num != seq.num or part.seq_len != seq.len) return error.InvalidEncoding;

    return .{ .ur_type = uri.ur_type, .seq = seq, .part = part };
}

// ---------------------------------------------------------------- 分割

/// メッセージ長とフラグメント長の上限・下限から、実際のフラグメント長を決める
/// （BCR-2024-001 §5 の findNominalFragmentLength）。
///
/// フラグメント長は「メッセージが `max_fragment_len` 以下になる最小の分割数」で決まる。
pub fn findFragmentLength(message_len: usize, min_fragment_len: usize, max_fragment_len: usize) Error!usize {
    if (message_len == 0) return error.InvalidEncoding;
    if (min_fragment_len == 0 or max_fragment_len < min_fragment_len) return error.InvalidEncoding;

    const max_fragment_count = message_len / min_fragment_len;
    var fragment_len = message_len;
    var count: usize = 1;
    while (count <= max_fragment_count) : (count += 1) {
        fragment_len = (message_len + count - 1) / count;
        if (fragment_len <= max_fragment_len) break;
    }
    return fragment_len;
}

/// 逐次パートを生成する（`seqNum` = 1, 2, …, `seqLen`）。
///
/// ファウンテン符号の冗長パートは生成しない。全て送り終えたら、受信側が取りこぼした
/// パートに備えて 1 から順に送り直す（本実装では固定レート方式のみ）。
pub const Encoder = struct {
    /// 型名（呼び出し側が生かしておくこと）。
    ur_type: []const u8,
    /// タグ無し CBOR のメッセージ（呼び出し側が生かしておくこと）。
    message: []const u8,
    /// 1 フラグメントのバイト数。
    fragment_len: usize,
    /// フラグメント数（= 逐次パート数）。
    seq_len: u32,
    /// メッセージ全体の CRC-32。
    checksum: u32,
    /// 次に返すパート番号（1 始まり）。`seq_len` を超えたら完了。
    next_seq_num: u32,
    /// パート CBOR を組み立てる作業領域（呼び出し側が用意し、`Encoder` より長生きさせる）。
    scratch: []u8,

    /// `message` はタグ無しの CBOR。`max_fragment_len` は 1 パートに載せたい最大バイト数
    /// （QR コードの容量から決める）。`min_fragment_len` は分割を細かくしすぎないための下限
    /// （bc-ur / URKit の既定値は `default_min_fragment_len`）。
    pub fn init(
        ur_type: []const u8,
        message: []const u8,
        max_fragment_len: usize,
        min_fragment_len: usize,
        scratch: []u8,
    ) Error!Encoder {
        if (!isValidType(ur_type)) return error.InvalidEncoding;

        const fragment_len = try findFragmentLength(message.len, min_fragment_len, max_fragment_len);
        const seq_len = (message.len + fragment_len - 1) / fragment_len;
        if (seq_len > std.math.maxInt(u32)) return error.InvalidEncoding;

        if (scratch.len < maxPartCborLength(fragment_len)) return error.BufferTooSmall;

        return .{
            .ur_type = ur_type,
            .message = message,
            .fragment_len = fragment_len,
            .seq_len = @intCast(seq_len),
            .checksum = bytewords.crc32(message),
            .next_seq_num = 1,
            .scratch = scratch,
        };
    }

    /// 全ての逐次パートを返し終えたか。
    pub fn isComplete(self: *const Encoder) bool {
        return self.next_seq_num > self.seq_len;
    }

    /// 1 から順に送り直す（ファウンテン符号の代わりの固定レート方式）。
    pub fn restart(self: *Encoder) void {
        self.next_seq_num = 1;
    }

    /// 次のパートを UR 文字列にする。全て返し終えていれば null。
    ///
    /// メッセージが 1 フラグメントに収まる場合は、仕様が単一パート形式を REQUIRED と
    /// しているため `ur:<type>/<message>` を 1 回だけ返す。
    pub fn next(self: *Encoder, out: []u8, case: TextCase) Error!?[]u8 {
        if (self.isComplete()) return null;

        if (self.seq_len == 1) {
            const single = try encodeSingle(out, self.ur_type, self.message, case);
            self.next_seq_num = 2;
            return single;
        }

        const seq_num = self.next_seq_num;
        const start = (seq_num - 1) * self.fragment_len;
        const take = @min(self.fragment_len, self.message.len - start);

        var pos: usize = 0;
        pos += (try cbor.writeArrayHeader(self.scratch[pos..], 5)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], seq_num)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.seq_len)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.message.len)).len;
        pos += (try cbor.writeUint(self.scratch[pos..], self.checksum)).len;
        pos += (try cbor.writeBytesHeader(self.scratch[pos..], self.fragment_len)).len;
        @memcpy(self.scratch[pos..][0..take], self.message[start..][0..take]);
        @memset(self.scratch[pos + take ..][0 .. self.fragment_len - take], 0);
        pos += self.fragment_len;

        const encoded = try encodePartUr(out, self.ur_type, seq_num, self.seq_len, self.scratch[0..pos], case);
        self.next_seq_num += 1;
        return encoded;
    }

    /// 最大のパートを出力するのに必要な `out` の大きさ。
    pub fn maxPartLength(ur_type_len: usize, fragment_len: usize) usize {
        const part_len = maxPartCborLength(fragment_len);
        return scheme.len + ur_type_len + 1 + 10 + 1 + 10 + 1 + bytewords.encodedLength(part_len, .minimal);
    }
};

// ---------------------------------------------------------------- デコーダ

/// `Decoder.receive` の結果。
pub const Status = enum {
    /// 取り込んだが、まだ全パートはそろっていない（メッセージは未完成）。
    need_more,
    /// 取り込んだ結果、メッセージが完成した（`Decoder.result` が有効）。
    complete,
    /// 既に持っているパート（重複）。状態は変わらない。
    duplicate,
    /// ファウンテン符号の冗長パート（seqNum > seqLen）。本実装では復元に使えないので無視した。
    fountain_unsupported,
};

/// マルチパート（および単一パート）UR を溜めてメッセージを再構成する。
///
/// パートは順不同・重複ありで渡してよい。`seqLen` 個そろったときだけ CRC-32 を検証し、
/// 一致しなければ error.ChecksumMismatch（完成扱いにしない）。
pub const Decoder = struct {
    /// 受信済みフラグメントのビットマップ（`ceil(seqLen / 8)` バイト以上）。
    bits: []u8,
    /// 再構成したメッセージの置き場（想定する最大メッセージ長以上）。
    message: []u8,
    /// パート CBOR を復号する作業領域（`maxPartCborLength(fragment_len)` バイト以上）。
    part_buf: []u8,

    type_buf: [max_type_len]u8 = undefined,
    type_len: usize = 0,
    seq_len: u32 = 0,
    message_len: usize = 0,
    fragment_len: usize = 0,
    checksum: u32 = 0,
    received_count: usize = 0,
    fountain_parts: usize = 0,
    single_part: bool = false,
    complete: bool = false,

    pub fn init(bits: []u8, message: []u8, part_buf: []u8) Decoder {
        return .{ .bits = bits, .message = message, .part_buf = part_buf };
    }

    /// 状態を捨てて最初からやり直せるようにする。
    pub fn reset(self: *Decoder) void {
        self.type_len = 0;
        self.seq_len = 0;
        self.message_len = 0;
        self.fragment_len = 0;
        self.checksum = 0;
        self.received_count = 0;
        self.fountain_parts = 0;
        self.single_part = false;
        self.complete = false;
        if (self.bits.len > 0) @memset(self.bits, 0);
    }

    /// 最初に受理したパートの型名（未受信なら空スライス）。
    pub fn urType(self: *const Decoder) []const u8 {
        return self.type_buf[0..self.type_len];
    }

    /// 完成していればメッセージを返す。
    pub fn result(self: *const Decoder) ?[]const u8 {
        if (!self.complete) return null;
        return self.message[0..self.message_len];
    }

    /// 必要なパート数（未受信なら 0）。
    pub fn expectedFragmentCount(self: *const Decoder) usize {
        return self.seq_len;
    }

    /// 受信済みのパート数。
    pub fn receivedFragmentCount(self: *const Decoder) usize {
        return self.received_count;
    }

    /// 無視したファウンテンパートの数。
    pub fn fountainPartCount(self: *const Decoder) usize {
        return self.fountain_parts;
    }

    fn isReceived(self: *const Decoder, index: usize) bool {
        return (self.bits[index / 8] >> @intCast(index % 8)) & 1 != 0;
    }

    fn setReceived(self: *Decoder, index: usize) void {
        self.bits[index / 8] |= @as(u8, 1) << @intCast(index % 8);
    }

    /// 1 つの UR 文字列を取り込む。
    ///
    /// 完成後は取り込まず `Status.duplicate` を返す。壊れた入力、および最初のパートと
    /// 食い違うメタデータ（別メッセージのパートなど）は error で拒否する。
    /// **エラーを返したときは、まだ受理していないパートの状態（ビットマップ・受信数）を
    /// 変えない**ので、呼び出し側がエラーを無視して読み進めても壊れない。ただし最初に
    /// 分解できた型名は記録される（別の型のストリームを混ぜないため）。最初からやり直すには
    /// `reset` を呼ぶ。
    pub fn receive(self: *Decoder, text: []const u8) Error!Status {
        const uri = try parse(text);

        // 型名は最初のパートで決まり、以降は一致を要求する。
        if (self.type_len == 0) {
            @memcpy(self.type_buf[0..uri.ur_type.len], uri.ur_type);
            self.type_len = uri.ur_type.len;
        } else if (!typeEql(self.type_buf[0..self.type_len], uri.ur_type)) {
            return error.InvalidEncoding;
        }

        if (self.complete) return .duplicate;

        if (uri.seq == null) return self.receiveSingle(uri.body);

        const decoded = try decodePartUr(self.part_buf, text);
        const part = decoded.part;

        if (self.seq_len == 0) {
            // 最初のパートがメッセージ全体のメタデータを決める。
            const seq_len: usize = part.seq_len;
            if ((part.message_len + seq_len - 1) / seq_len != part.data.len) return error.InvalidEncoding;
            if ((part.message_len + part.data.len - 1) / part.data.len != seq_len) return error.InvalidEncoding;
            if (self.bits.len < (seq_len + 7) / 8) return error.BufferTooSmall;
            if (self.message.len < part.message_len) return error.BufferTooSmall;

            self.seq_len = part.seq_len;
            self.message_len = part.message_len;
            self.fragment_len = part.data.len;
            self.checksum = part.checksum;
            @memset(self.bits[0 .. (seq_len + 7) / 8], 0);
        } else if (part.seq_len != self.seq_len or
            part.message_len != self.message_len or
            part.checksum != self.checksum or
            part.data.len != self.fragment_len)
        {
            return error.InvalidEncoding;
        }

        if (part.seq_num > self.seq_len) {
            // ファウンテン符号の冗長パート。復元には使わない。
            self.fountain_parts += 1;
            return .fountain_unsupported;
        }

        const index: usize = part.seq_num - 1;
        if (self.isReceived(index)) return .duplicate;

        // 末尾のパートはパディングを含むので、メッセージ長を超える分は捨てる
        // （CRC-32 はパディングを除いたメッセージ全体に対して計算されている）。
        const offset = index * self.fragment_len;
        const take = @min(part.data.len, self.message_len - offset);
        @memcpy(self.message[offset..][0..take], part.data[0..take]);
        self.setReceived(index);
        self.received_count += 1;

        if (self.received_count < self.seq_len) return .need_more;

        const assembled = self.message[0..self.message_len];
        if (bytewords.crc32(assembled) != self.checksum) return error.ChecksumMismatch;
        if (!cbor.isWellFormed(assembled, true)) return error.InvalidEncoding;

        self.complete = true;
        return .complete;
    }

    /// 単一パート UR を取り込む。
    fn receiveSingle(self: *Decoder, body: []const u8) Error!Status {
        if (self.seq_len != 0 and !self.single_part) {
            // マルチパートの途中に単一パートが来るのはおかしい。
            return error.InvalidEncoding;
        }

        const message = try bytewords.decode(self.part_buf, body, .minimal);
        if (!cbor.isWellFormed(message, true)) return error.InvalidEncoding;
        if (self.message.len < message.len) return error.BufferTooSmall;

        @memcpy(self.message[0..message.len], message);
        self.seq_len = 1;
        self.message_len = message.len;
        self.fragment_len = message.len;
        self.checksum = bytewords.crc32(message);
        self.single_part = true;
        self.complete = true;
        return .complete;
    }
};

// ---------------------------------------------------------------- テスト

const testing = std.testing;

fn asHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

/// BCR-2024-001 §5 のテストベクタのメッセージ（256 バイト、seed "Wolf"）。
const message_256 = [256]u8{
    0x91, 0x6e, 0xc6, 0x5c, 0xf7, 0x7c, 0xad, 0xf5, 0x5c, 0xd7, 0xf9, 0xcd, 0xa1, 0xa1, 0x03, 0x00,
    0x26, 0xdd, 0xd4, 0x2e, 0x90, 0x5b, 0x77, 0xad, 0xc3, 0x6e, 0x4f, 0x2d, 0x3c, 0xcb, 0xa4, 0x4f,
    0x7f, 0x04, 0xf2, 0xde, 0x44, 0xf4, 0x2d, 0x84, 0xc3, 0x74, 0xa0, 0xe1, 0x49, 0x13, 0x6f, 0x25,
    0xb0, 0x18, 0x52, 0x54, 0x59, 0x61, 0xd5, 0x5f, 0x7f, 0x7a, 0x8c, 0xde, 0x6d, 0x0e, 0x2e, 0xc4,
    0x3f, 0x3b, 0x2d, 0xcb, 0x64, 0x4a, 0x22, 0x09, 0xe8, 0xc9, 0xe3, 0x4a, 0xf5, 0xc4, 0x74, 0x79,
    0x84, 0xa5, 0xe8, 0x73, 0xc9, 0xcf, 0x5f, 0x96, 0x5e, 0x25, 0xee, 0x29, 0x03, 0x9f, 0xdf, 0x8c,
    0xa7, 0x4f, 0x1c, 0x76, 0x9f, 0xc0, 0x7e, 0xb7, 0xeb, 0xae, 0xc4, 0x6e, 0x06, 0x95, 0xae, 0xa6,
    0xcb, 0xd6, 0x0b, 0x3e, 0xc4, 0xbb, 0xff, 0x1b, 0x9f, 0xfe, 0x8a, 0x9e, 0x72, 0x40, 0x12, 0x93,
    0x77, 0xb9, 0xd3, 0x71, 0x1e, 0xd3, 0x8d, 0x41, 0x2f, 0xbb, 0x44, 0x42, 0x25, 0x6f, 0x1e, 0x6f,
    0x59, 0x5e, 0x0f, 0xc5, 0x7f, 0xed, 0x45, 0x1f, 0xb0, 0xa0, 0x10, 0x1f, 0xb7, 0x6b, 0x1f, 0xb1,
    0xe1, 0xb8, 0x8c, 0xfd, 0xfd, 0xaa, 0x94, 0x62, 0x94, 0xa4, 0x7d, 0xe8, 0xff, 0xf1, 0x73, 0xf0,
    0x21, 0xc0, 0xe6, 0xf6, 0x5b, 0x05, 0xc0, 0xa4, 0x94, 0xe5, 0x07, 0x91, 0x27, 0x0a, 0x00, 0x50,
    0xa7, 0x3a, 0xe6, 0x9b, 0x67, 0x25, 0x50, 0x5a, 0x2e, 0xc8, 0xa5, 0x79, 0x14, 0x57, 0xc9, 0x87,
    0x6d, 0xd3, 0x4a, 0xad, 0xd1, 0x92, 0xa5, 0x3a, 0xa0, 0xdc, 0x66, 0xb5, 0x56, 0xc0, 0xc2, 0x15,
    0xc7, 0xce, 0xb8, 0x24, 0x8b, 0x71, 0x7c, 0x22, 0x95, 0x1e, 0x65, 0x30, 0x5b, 0x56, 0xa3, 0x70,
    0x6e, 0x3e, 0x86, 0xeb, 0x01, 0xc8, 0x03, 0xbb, 0xf9, 0x15, 0xd8, 0x0e, 0xdc, 0xd6, 0x4d, 0x4d,
};

/// bc-ur test_ur_encoder が期待する 9 個の逐次パート（`ur:bytes`, max_fragment_len = 30）。
const expected_parts = [9][]const u8{
    "ur:bytes/1-9/lpadascfadaxcywenbpljkhdcahkadaemejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtdkgslpgh",
    "ur:bytes/2-9/lpaoascfadaxcywenbpljkhdcagwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsgmghhkhstlrdcxaefz",
    "ur:bytes/3-9/lpaxascfadaxcywenbpljkhdcahelbknlkuejnbadmssfhfrdpsbiegecpasvssovlgeykssjykklronvsjksopdzmol",
    "ur:bytes/4-9/lpaaascfadaxcywenbpljkhdcasotkhemthydawydtaxneurlkosgwcekonertkbrlwmplssjtammdplolsbrdzcrtas",
    "ur:bytes/5-9/lpahascfadaxcywenbpljkhdcatbbdfmssrkzmcwnezelennjpfzbgmuktrhtejscktelgfpdlrkfyfwdajldejokbwf",
    "ur:bytes/6-9/lpamascfadaxcywenbpljkhdcackjlhkhybssklbwefectpfnbbectrljectpavyrolkzczcpkmwidmwoxkilghdsowp",
    "ur:bytes/7-9/lpatascfadaxcywenbpljkhdcavszmwnjkwtclrtvaynhpahrtoxmwvwatmedibkaegdosftvandiodagdhthtrlnnhy",
    "ur:bytes/8-9/lpayascfadaxcywenbpljkhdcadmsponkkbbhgsoltjntegepmttmoonftnbuoiyrehfrtsabzsttorodklubbuyaetk",
    "ur:bytes/9-9/lpasascfadaxcywenbpljkhdcajskecpmdckihdyhphfotjojtfmlnwmadspaxrkytbztpbauotbgtgtaeaevtgavtny",
};

/// UR のメッセージ = CBOR のバイト文字列 `59 0100` + 256 バイト（合計 259 バイト）。
fn makeUrMessage(buf: *[259]u8) []u8 {
    buf[0] = 0x59;
    buf[1] = 0x01;
    buf[2] = 0x00;
    @memcpy(buf[3..], &message_256);
    return buf;
}

test "BCR-2020-005 の単一パートの例と一致する" {
    // ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox
    // （タグ無し CBOR a10150c7098580125e2ab0981253468b2dbc52 の Bytewords）
    var message_buf: [32]u8 = undefined;
    const message = asHex(&message_buf, "a10150c7098580125e2ab0981253468b2dbc52");

    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox",
        try encodeSingle(&out, "seed", message, .lower),
    );

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(
        message,
        try decodeSingle(&decoded, "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "seed"),
    );

    // 型名が違えば拒否する。
    try testing.expectError(
        error.InvalidEncoding,
        decodeSingle(&decoded, "ur:seed/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "bytes"),
    );
    // マルチパート形式は decodeSingle では拒否する。
    try testing.expectError(
        error.InvalidEncoding,
        decodeSingle(&decoded, "ur:seed/1-9/oyadgdstaslplabghydrpfmkbggufgludprfgmamdpwmox", "seed"),
    );
}

test "bc-ur-rust の UR テストベクタと一致する" {
    // bc-ur-rust src/ur.rs test_ur: CBOR [1, 2, 3]。
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("ur:test/lsadaoaxjygonesw", try encodeSingle(&out, "test", &message, .lower));
    // QR コード向けの大文字表現（bc-ur-rust test_ur の "UR:TEST/LSADAOAXJYGONESW"）。
    try testing.expectEqualStrings("UR:TEST/LSADAOAXJYGONESW", try encodeSingle(&out, "test", &message, .upper));

    // 大文字の UR も復号できる（case agnostic）。
    var decoded: [8]u8 = undefined;
    try testing.expectEqualStrings(&message, try decodeSingle(&decoded, "UR:TEST/LSADAOAXJYGONESW", "test"));
    try testing.expectEqualStrings(&message, try decodeSingle(&decoded, "ur:test/lsadaoaxjygonesw", null));
}

test "bc-ur の単一パート UR テストベクタと一致する" {
    // bc-ur test/test.cpp test_single_part_ur: 50 バイトの CBOR バイト文字列。
    var payload_buf: [64]u8 = undefined;
    const payload = asHex(
        &payload_buf,
        "916ec65cf77cadf55cd7f9cda1a1030026ddd42e905b77adc36e4f2d3ccba44f7f04f2de44f42d84c374a0e1" ++
            "49136f25b018",
    );

    var out: [256]u8 = undefined;
    const text = try encodeSingleByteString(&out, type_bytes, payload, .lower);
    try testing.expectEqualStrings(
        "ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch",
        text,
    );

    var decoded: [64]u8 = undefined;
    const message = try decodeSingle(&decoded, text, type_bytes);
    // ur:bytes のメッセージは CBOR のバイト文字列なので、中身のペイロードを取り出す。
    var reader = cbor.Reader.init(message);
    try testing.expectEqualStrings(payload, try reader.readBytes());
    try reader.finish();
}

test "findNominalFragmentLength のテストベクタと一致する" {
    // BCR-2024-001 §5 testFindFragmentLength
    try testing.expectEqual(@as(usize, 1764), try findFragmentLength(12345, 1005, 1955));
    try testing.expectEqual(@as(usize, 12345), try findFragmentLength(12345, 1005, 30000));
    // 259 バイトのメッセージを最大 30 バイトずつ → 29 バイト × 9 個（上のテストベクタと同じ）
    try testing.expectEqual(@as(usize, 29), try findFragmentLength(259, default_min_fragment_len, 30));

    try testing.expectError(error.InvalidEncoding, findFragmentLength(0, 10, 30));
    try testing.expectError(error.InvalidEncoding, findFragmentLength(100, 0, 30));
    try testing.expectError(error.InvalidEncoding, findFragmentLength(100, 30, 10));
}

test "bc-ur のマルチパート UR テストベクタと一致する（逐次パート）" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 9), encoder.seq_len);
    try testing.expectEqual(@as(usize, 29), encoder.fragment_len);

    var out: [256]u8 = undefined;
    for (expected_parts) |expected| {
        const part = (try encoder.next(&out, .lower)) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(expected, part);
    }
    try testing.expect(encoder.isComplete());
    try testing.expectEqual(@as(?[]u8, null), try encoder.next(&out, .lower));

    // 送り直しも同じ列を返す。
    encoder.restart();
    try testing.expectEqualStrings(expected_parts[0], (try encoder.next(&out, .lower)).?);
}

test "マルチパートを順不同・重複ありで再構成できる" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var parts: [9][]u8 = undefined;
    var part_bufs: [9][256]u8 = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(part_bufs[i][0..part.len], part);
        slot.* = part_bufs[i][0..part.len];
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // 順不同 + 重複あり（3, 1, 3, 9, 5, ...）で渡す。
    const order = [_]usize{ 2, 0, 2, 8, 4, 1, 6, 3, 7, 5 };
    for (order, 0..) |index, step| {
        const status = try decoder.receive(parts[index]);
        if (step < order.len - 1) {
            // 途中では「まだ足りない」か「重複」でしかない。
            try testing.expect(status == .need_more or status == .duplicate);
            try testing.expect(decoder.result() == null);
        } else {
            try testing.expectEqual(Status.complete, status);
        }
    }

    try testing.expectEqual(@as(usize, 9), decoder.receivedFragmentCount());
    try testing.expectEqual(@as(usize, 0), decoder.fountainPartCount());
    try testing.expectEqualStrings(ur_message, decoder.result().?);
}

test "パートが欠けているうちは完成扱いしない" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // 1, 2, 4, 5 だけ渡す（3, 6..9 が欠けている）。
    for ([_]usize{ 0, 1, 3, 4 }) |index| {
        try testing.expectEqual(Status.need_more, try decoder.receive(parts[index][0..lengths[index]]));
        try testing.expect(decoder.result() == null);
        try testing.expect(!decoder.complete);
    }
    try testing.expectEqual(@as(usize, 4), decoder.receivedFragmentCount());
    try testing.expectEqual(@as(usize, 9), decoder.expectedFragmentCount());

    // 残りを渡すと完成する。
    for ([_]usize{ 2, 5, 6, 7, 8 }) |index| {
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expectEqualStrings(ur_message, decoder.result().?);
    // 完成後のパートは取り込まない。
    try testing.expectEqual(Status.duplicate, try decoder.receive(parts[0][0..lengths[0]]));
}

test "2 桁の seq でも往復でき、パディングが切り落とされる" {
    // CBOR のバイト文字列（59 012c + 300 バイト = 303 バイト）を 11 個に分ける。
    var message: [303]u8 = undefined;
    message[0] = 0x59;
    message[1] = 0x01;
    message[2] = 0x2c;
    for (message[3..], 0..) |*byte, i| byte.* = @intCast((i * 31 + 7) % 256);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, &message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 11), encoder.seq_len);
    try testing.expectEqual(@as(usize, 28), encoder.fragment_len);

    var parts: [11][256]u8 = undefined;
    var lengths: [11]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }
    try testing.expect(std.mem.startsWith(u8, parts[0][0..lengths[0]], "ur:bytes/1-11/"));
    try testing.expect(std.mem.startsWith(u8, parts[10][0..lengths[10]], "ur:bytes/11-11/"));

    var bits: [8]u8 = undefined;
    var assembled_buf: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &assembled_buf, &part_buf);

    // 逆順（11, 10, …, 1）に渡す。
    var index: usize = parts.len;
    while (index > 0) {
        index -= 1;
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expectEqualStrings(&message, decoder.result().?);
}

test "端数が出ない分割でも往復できる（パディングなし）" {
    // CBOR のバイト文字列（58 1a + 26 バイト = 28 バイト）を 14 バイトずつ 2 個に分ける。
    var message: [28]u8 = undefined;
    message[0] = 0x58;
    message[1] = 0x1a;
    for (message[2..], 0..) |*byte, i| byte.* = @intCast((i * 17 + 3) % 256);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, &message, 14, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 2), encoder.seq_len);
    try testing.expectEqual(@as(usize, 14), encoder.fragment_len);

    var out: [256]u8 = undefined;
    const part1 = (try encoder.next(&out, .lower)).?;
    var part1_copy: [256]u8 = undefined;
    @memcpy(part1_copy[0..part1.len], part1);
    const part2 = (try encoder.next(&out, .lower)).?;
    var part2_copy: [256]u8 = undefined;
    @memcpy(part2_copy[0..part2.len], part2);

    var bits: [8]u8 = undefined;
    var assembled: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &assembled, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(part2_copy[0..part2.len]));
    try testing.expectEqual(Status.complete, try decoder.receive(part1_copy[0..part1.len]));
    try testing.expectEqualStrings(&message, decoder.result().?);
}

test "壊れたパートを拒否し、誤って完成扱いしない" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    var out: [256]u8 = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    // (1) bytewords のチェックサムを壊したパート
    var broken = parts[0];
    broken[lengths[0] - 1] = if (broken[lengths[0] - 1] == 'a') 'b' else 'a';
    try testing.expectError(error.ChecksumMismatch, decoder.receive(broken[0..lengths[0]]));

    // (2) 中身のデータだけを書き換えたパート（bytewords のチェックサムは付け直す）
    var part_cbor: [128]u8 = undefined;
    const tampered = try decodePartUr(&part_buf, parts[3][0..lengths[3]]);
    var data: [32]u8 = undefined;
    @memcpy(data[0..tampered.part.data.len], tampered.part.data);
    data[0] ^= 0xff;
    const tampered_part = Part{
        .seq_num = tampered.part.seq_num,
        .seq_len = tampered.part.seq_len,
        .message_len = tampered.part.message_len,
        .checksum = tampered.part.checksum,
        .data = data[0..tampered.part.data.len],
    };
    const tampered_cbor = try encodePart(&part_cbor, tampered_part);
    var tampered_ur: [256]u8 = undefined;
    const tampered_text = try encodePartUr(
        &tampered_ur,
        type_bytes,
        tampered_part.seq_num,
        tampered_part.seq_len,
        tampered_cbor,
        .lower,
    );

    // 残りのパートをすべて渡し、最後に壊れた 4 番目を渡す。
    for ([_]usize{ 0, 1, 2, 4, 5, 6, 7, 8 }) |index| {
        _ = try decoder.receive(parts[index][0..lengths[index]]);
    }
    try testing.expect(decoder.result() == null);
    try testing.expectError(error.ChecksumMismatch, decoder.receive(tampered_text));
    // チェックサムが合わないので完成にはならない。
    try testing.expect(decoder.result() == null);
    try testing.expect(!decoder.complete);
}

test "別のメッセージのパートや不正な入力を拒否する" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    var parts: [9][256]u8 = undefined;
    var lengths: [9]usize = undefined;
    for (&parts, 0..) |*slot, i| {
        const part = (try encoder.next(&out, .lower)).?;
        @memcpy(slot[0..part.len], part);
        lengths[i] = part.len;
    }

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(parts[0][0..lengths[0]]));

    // 別の型名
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:crypto-psbt/2-9/lpaoascfadaxcywenbpljkhdcagw"));
    // 別のメッセージ（チェックサムが違う）
    var other_message: [259]u8 = undefined;
    _ = makeUrMessage(&other_message);
    other_message[3] ^= 0xff;
    var other_scratch: [128]u8 = undefined;
    var other_encoder = try Encoder.init(type_bytes, &other_message, 30, default_min_fragment_len, &other_scratch);
    var other_out: [256]u8 = undefined;
    _ = (try other_encoder.next(&other_out, .lower)).?;
    const other_part2 = (try other_encoder.next(&other_out, .lower)).?;
    try testing.expectError(error.InvalidEncoding, decoder.receive(other_part2));

    // 壊れた書式
    try testing.expectError(error.InvalidEncoding, decoder.receive(""));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("http://example.com/1-9/abcd"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/0-9/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1/1-9/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1-9/"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/x-y/lpao"));
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bytes/1-9/oooo")); // 語彙にない
    try testing.expectError(error.InvalidEncoding, decoder.receive("ur:bad_type!/1-9/lpao"));

    // 状態は変わっていない（1 パートだけ受信済み）。
    try testing.expectEqual(@as(usize, 1), decoder.receivedFragmentCount());
    try testing.expect(decoder.result() == null);
}

test "ファウンテン符号の冗長パートは受理するが復元には使わない" {
    var ur_message_buf: [259]u8 = undefined;
    const ur_message = makeUrMessage(&ur_message_buf);

    var scratch: [128]u8 = undefined;
    var encoder = try Encoder.init(type_bytes, ur_message, 30, default_min_fragment_len, &scratch);

    var out: [256]u8 = undefined;
    const part1 = (try encoder.next(&out, .lower)).?;
    var part1_copy: [256]u8 = undefined;
    @memcpy(part1_copy[0..part1.len], part1);

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.need_more, try decoder.receive(part1_copy[0..part1.len]));

    // 冗長パート（seqNum = 10 > seqLen = 9）を手で組み立てる。
    const decoded = try decodePartUr(&part_buf, part1_copy[0..part1.len]);
    const fountain_part = Part{
        .seq_num = decoded.part.seq_len + 1,
        .seq_len = decoded.part.seq_len,
        .message_len = decoded.part.message_len,
        .checksum = decoded.part.checksum,
        .data = decoded.part.data,
    };
    var cbor_buf: [128]u8 = undefined;
    const fountain_cbor = try encodePart(&cbor_buf, fountain_part);
    var ur_buf: [256]u8 = undefined;
    const fountain_ur = try encodePartUr(
        &ur_buf,
        type_bytes,
        fountain_part.seq_num,
        fountain_part.seq_len,
        fountain_cbor,
        .lower,
    );

    try testing.expectEqual(Status.fountain_unsupported, try decoder.receive(fountain_ur));
    try testing.expectEqual(@as(usize, 1), decoder.fountainPartCount());
    try testing.expectEqual(@as(usize, 1), decoder.receivedFragmentCount());
    try testing.expect(decoder.result() == null);
}

test "単一パート UR も Decoder で受け取れる" {
    const payload = "00112233445566778899aabbccddeeff";

    var out: [256]u8 = undefined;
    const text = try encodeSingleByteString(&out, type_crypto_psbt, payload, .lower);

    var bits: [8]u8 = undefined;
    var message: [512]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &message, &part_buf);

    try testing.expectEqual(Status.complete, try decoder.receive(text));
    try testing.expectEqualStrings(type_crypto_psbt, decoder.urType());

    // 中身は CBOR のバイト文字列。
    var reader = cbor.Reader.init(decoder.result().?);
    const decoded_payload = try reader.readBytes();
    try reader.finish();
    try testing.expectEqualStrings(payload, decoded_payload);
}

test "小さなメッセージは単一パート形式で出力する" {
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    var scratch: [64]u8 = undefined;
    var encoder = try Encoder.init("test", &message, 30, default_min_fragment_len, &scratch);
    try testing.expectEqual(@as(u32, 1), encoder.seq_len);

    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("ur:test/lsadaoaxjygonesw", (try encoder.next(&out, .lower)).?);
    try testing.expect(encoder.isComplete());
    try testing.expectEqual(@as(?[]u8, null), try encoder.next(&out, .lower));
}

test "出力バッファが足りない場合は BufferTooSmall" {
    var small: [8]u8 = undefined;
    const message = [_]u8{ 0x83, 0x01, 0x02, 0x03 };

    try testing.expectError(error.BufferTooSmall, encodeSingle(&small, "test", &message, .lower));
    try testing.expectError(error.BufferTooSmall, encodeSingleByteString(&small, type_bytes, "hello", .lower));

    // 作業領域が足りない Encoder は作れない。
    var tiny_scratch: [8]u8 = undefined;
    try testing.expectError(
        error.BufferTooSmall,
        Encoder.init(type_bytes, &message_256, 30, default_min_fragment_len, &tiny_scratch),
    );

    // メッセージの置き場が足りない Decoder。
    var tiny_message: [4]u8 = undefined;
    var bits: [8]u8 = undefined;
    var part_buf: [128]u8 = undefined;
    var decoder = Decoder.init(&bits, &tiny_message, &part_buf);
    try testing.expectError(
        error.BufferTooSmall,
        decoder.receive("ur:bytes/hdeymejtswhhylkepmykhhtsytsnoyoyaxaedsuttydmmhhpktpmsrjtgwdpfnsboxgwlbaawzuefywkdplrsrjynbvygabwjldapfcsdwkbrkch"),
    );
}

test "型名と seq の書式" {
    try testing.expect(isValidType("bytes"));
    try testing.expect(isValidType("crypto-psbt"));
    try testing.expect(isValidType("crypto-account"));
    try testing.expect(isValidType("BYTES"));
    try testing.expect(!isValidType(""));
    try testing.expect(!isValidType("bad_type"));
    try testing.expect(!isValidType("bad type"));
    try testing.expect(!isValidType("crypto/psbt"));
    try testing.expect(!isValidType("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")); // 33 文字

    // 1 始まりの seq を読み取れる。
    const uri = try parse("ur:bytes/1-9/lpaoascf");
    try testing.expectEqual(@as(u32, 1), uri.seq.?.num);
    try testing.expectEqual(@as(u32, 9), uri.seq.?.len);
    try testing.expectEqualStrings("bytes", uri.ur_type);
    try testing.expectEqualStrings("lpaoascf", uri.body);

    const single = try parse("ur:seed/oyadgd");
    try testing.expect(single.seq == null);
    try testing.expectEqualStrings("seed", single.ur_type);
    // 大文字の UR も分解できる。
    const upper = try parse("UR:BYTES/10-9/LPAOASCF");
    try testing.expectEqual(@as(u32, 10), upper.seq.?.num);
    try testing.expectEqual(@as(u32, 9), upper.seq.?.len);
}
