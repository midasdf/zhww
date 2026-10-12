//! Bytewords（BCR-2020-012）: バイナリデータを 4 文字の英単語列に符号化する。
//!
//! **設計方針**
//! - 語彙は仕様どおりの 256 語。各語は 4 文字で、先頭+末尾・先頭 3 文字・末尾 3 文字の
//!   いずれでも一意に区別できる（テストで検証している）。
//! - チェックサムは本体の CRC-32 を **ビッグエンディアン（ネットワーク順）4 バイト**として
//!   末尾に付ける。検証せずに本体を返す API は用意しない。
//! - 大文字小文字は区別しない（QR コードでは大文字、URI・画面表示では小文字を使う）。
//! - 秘密情報を扱わないため、メモリ確保は行わない（出力先は呼び出し側が用意する）。
//! - 壊れた入力（語彙にない語・奇数長・チェックサム不一致・長さ不足）はすべて error で拒否する。
//!
//! 参考: https://github.com/BlockchainCommons/Research/blob/master/papers/bcr-2020-012-bytewords.md
//!
//! テストベクタの出典（いずれも第三者による公開ベクタをそのまま使用）:
//!   - BCR-2020-012 §Example/Test Vector（16 バイトの seed）と §Brutal Encoding
//!   - bc-ur（C++ リファレンス実装）test/test.cpp の
//!     test_crc32 / test_bytewords_1 / test_bytewords_2
//!     https://github.com/BlockchainCommons/bc-ur/blob/master/test/test.cpp
//!   - bc-ur-rust src/ur.rs の test_ur（"ur:test/lsadaoaxjygonesw"）
//!     https://github.com/BlockchainCommons/bc-ur-rust/blob/master/src/ur.rs
//!   - BCR-2024-001（MUR）§CRC-32 Checksum のテストベクタ
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// 符号化スタイル。
pub const Style = enum {
    /// 単語を空白で区切る（人が読む・金属に刻む用途）。
    standard,
    /// 単語をハイフンで区切る（URI に埋め込める）。
    uri,
    /// 各語の先頭と末尾の 2 文字だけを連結する（QR コード用。16 進数と同じ長さ）。
    minimal,
};

/// 語彙の数（1 バイト = 1 語）。
pub const alphabet_size = 256;
/// 語の文字数（全語 4 文字）。
pub const word_len = 4;
/// 最小表現の文字数（先頭 + 末尾）。
pub const minimal_len = 2;
/// チェックサムのバイト数（CRC-32）。
pub const checksum_len = 4;

/// BCR-2020-012 の語彙（アルファベット順、全 256 語）。
/// 行頭のコメントは仕様書と同じ「その行の先頭バイト値」を表す。
pub const words: [alphabet_size][]const u8 = .{
    "able", "acid", "also", "apex", "aqua", "arch", "atom", "aunt", // 0x00
    "away", "axis", "back", "bald", "barn", "belt", "beta", "bias", // 0x08
    "blue", "body", "brag", "brew", "bulb", "buzz", "calm", "cash", // 0x10
    "cats", "chef", "city", "claw", "code", "cola", "cook", "cost", // 0x18
    "crux", "curl", "cusp", "cyan", "dark", "data", "days", "deli", // 0x20
    "dice", "diet", "door", "down", "draw", "drop", "drum", "dull", // 0x28
    "duty", "each", "easy", "echo", "edge", "epic", "even", "exam", // 0x30
    "exit", "eyes", "fact", "fair", "fern", "figs", "film", "fish", // 0x38
    "fizz", "flap", "flew", "flux", "foxy", "free", "frog", "fuel", // 0x40
    "fund", "gala", "game", "gear", "gems", "gift", "girl", "glow", // 0x48
    "good", "gray", "grim", "guru", "gush", "gyro", "half", "hang", // 0x50
    "hard", "hawk", "heat", "help", "high", "hill", "holy", "hope", // 0x58
    "horn", "huts", "iced", "idea", "idle", "inch", "inky", "into", // 0x60
    "iris", "iron", "item", "jade", "jazz", "join", "jolt", "jowl", // 0x68
    "judo", "jugs", "jump", "junk", "jury", "keep", "keno", "kept", // 0x70
    "keys", "kick", "kiln", "king", "kite", "kiwi", "knob", "lamb", // 0x78
    "lava", "lazy", "leaf", "legs", "liar", "limp", "lion", "list", // 0x80
    "logo", "loud", "love", "luau", "luck", "lung", "main", "many", // 0x88
    "math", "maze", "memo", "menu", "meow", "mild", "mint", "miss", // 0x90
    "monk", "nail", "navy", "need", "news", "next", "noon", "note", // 0x98
    "numb", "obey", "oboe", "omit", "onyx", "open", "oval", "owls", // 0xa0
    "paid", "part", "peck", "play", "plus", "poem", "pool", "pose", // 0xa8
    "puff", "puma", "purr", "quad", "quiz", "race", "ramp", "real", // 0xb0
    "redo", "rich", "road", "rock", "roof", "ruby", "ruin", "runs", // 0xb8
    "rust", "safe", "saga", "scar", "sets", "silk", "skew", "slot", // 0xc0
    "soap", "solo", "song", "stub", "surf", "swan", "taco", "task", // 0xc8
    "taxi", "tent", "tied", "time", "tiny", "toil", "tomb", "toys", // 0xd0
    "trip", "tuna", "twin", "ugly", "undo", "unit", "urge", "user", // 0xd8
    "vast", "very", "veto", "vial", "vibe", "view", "visa", "void", // 0xe0
    "vows", "wall", "wand", "warm", "wasp", "wave", "waxy", "webs", // 0xe8
    "what", "when", "whiz", "wolf", "work", "yank", "yawn", "yell", // 0xf0
    "yoga", "yurt", "zaps", "zero", "zest", "zinc", "zone", "zoom", // 0xf8
};

/// バイト値に対応する 4 文字の語。
pub fn wordFor(byte: u8) []const u8 {
    return words[byte];
}

/// バイト値に対応する最小表現（語の先頭 1 文字 + 末尾 1 文字）。
pub fn minimalFor(byte: u8) [minimal_len]u8 {
    const word = words[byte];
    return .{ word[0], word[word_len - 1] };
}

/// CRC-32 の増分計算（初期値は 0xFFFFFFFF を渡し、最後に反転すること）。
fn crc32Update(state: u32, data: []const u8) u32 {
    var crc = state;
    for (data) |byte| {
        crc ^= byte;
        for (0..8) |_| {
            if ((crc & 1) != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc >>= 1;
            }
        }
    }
    return crc;
}

/// CRC-32（IEEE 802.3 / zlib）。
///
/// 反射多項式 0xEDB88320、初期値 0xFFFFFFFF、最後に全ビット反転する。
/// BCR-2020-012 は「MSDN: 32-Bit CRC Algorithm」を参照している。
///
/// 既知の値（bc-ur test/test.cpp の test_crc32 と BCR-2024-001）:
///   "Wolf" → 0x598c84dc、"Hello, world!" → 0xebe6c6e6
pub fn crc32(data: []const u8) u32 {
    return ~crc32Update(0xFFFFFFFF, data);
}

/// CRC-32 をビッグエンディアン（ネットワーク順）4 バイトにする。
fn checksumBytes(checksum: u32) [checksum_len]u8 {
    var out: [checksum_len]u8 = undefined;
    std.mem.writeInt(u32, &out, checksum, .big);
    return out;
}

/// `data_len` バイトを符号化した本体（チェックサムを除く）の文字列長。
fn bodyLength(data_len: usize, style: Style) usize {
    const len: usize = switch (style) {
        .minimal => data_len * minimal_len,
        .standard, .uri => if (data_len == 0) 0 else data_len * word_len + (data_len - 1),
    };
    return len;
}

/// `data_len` バイトをチェックサム付きで符号化した文字列長。
///
/// 出力バッファの大きさを決めるのに使う。
pub fn encodedLength(data_len: usize, style: Style) usize {
    return bodyLength(data_len + checksum_len, style);
}

/// 語（または最小表現）を 1 つ書き出す。`pos` は書き込み位置。
/// 呼び出し側が `encodedLength` でバッファ長を確認していることを前提とする。
fn appendWord(out: []u8, pos: *usize, byte: u8, style: Style, first: bool) void {
    switch (style) {
        .minimal => {
            const minimal = minimalFor(byte);
            out[pos.*] = minimal[0];
            out[pos.* + 1] = minimal[1];
            pos.* += minimal_len;
        },
        .standard, .uri => {
            if (!first) {
                out[pos.*] = if (style == .standard) ' ' else '-';
                pos.* += 1;
            }
            @memcpy(out[pos.*..][0..word_len], wordFor(byte));
            pos.* += word_len;
        },
    }
}

/// チェックサムを付けずに符号化する。
///
/// 語彙の対応表を確かめるとき以外は `encodeWithChecksum` を使うこと。
pub fn encode(out: []u8, data: []const u8, style: Style) Error![]u8 {
    if (out.len < bodyLength(data.len, style)) return error.BufferTooSmall;

    var pos: usize = 0;
    for (data, 0..) |byte, i| appendWord(out, &pos, byte, style, i == 0);
    return out[0..pos];
}

/// 本体の CRC-32（4 バイト、ビッグエンディアン）を末尾に付けて符号化する。
///
/// BCR-2020-012 の Bytewords 本体はこちら。UR の `<message>` 部分もこれで作る。
pub fn encodeWithChecksum(out: []u8, data: []const u8, style: Style) Error![]u8 {
    return encodeWithChecksumParts(out, &.{data}, style);
}

/// 複数のバイト列を連結したものとして符号化する（間にコピーを作らない）。
///
/// CBOR のヘッダと本体を別々に持っている場合（`ur.zig` の `encodeSingleByteString`）に使う。
pub fn encodeWithChecksumParts(out: []u8, parts: []const []const u8, style: Style) Error![]u8 {
    var total: usize = 0;
    for (parts) |part| total += part.len;
    if (out.len < encodedLength(total, style)) return error.BufferTooSmall;

    var pos: usize = 0;
    var index: usize = 0;
    for (parts) |part| {
        for (part) |byte| {
            appendWord(out, &pos, byte, style, index == 0);
            index += 1;
        }
    }

    var crc: u32 = 0xFFFFFFFF;
    for (parts) |part| crc = crc32Update(crc, part);
    const checksum = checksumBytes(~crc);
    for (checksum, 0..) |byte, i| appendWord(out, &pos, byte, style, (total + i) == 0);
    return out[0..pos];
}

/// デコードの作業状態。
///
/// 末尾 4 バイトはチェックサムなので、`out` に書くのは「チェックサムでは
/// ないと確定したバイト」だけにする（本体用バッファに 4 バイトの余裕を要求しない）。
const DecoderState = struct {
    out: []u8,
    body_len: usize = 0,
    total: usize = 0,
    tail: [checksum_len]u8 = undefined,

    fn push(self: *DecoderState, byte: u8) Error!void {
        if (self.total >= checksum_len) {
            if (self.body_len >= self.out.len) return error.BufferTooSmall;
            self.out[self.body_len] = self.tail[0];
            self.body_len += 1;
            self.tail[0] = self.tail[1];
            self.tail[1] = self.tail[2];
            self.tail[2] = self.tail[3];
            self.tail[3] = byte;
        } else {
            self.tail[self.total] = byte;
        }
        self.total += 1;
    }

    fn finish(self: *DecoderState) Error![]u8 {
        // チェックサム 4 バイト + 本体 1 バイト以上を要求する。
        if (self.total < checksum_len + 1) return error.Truncated;
        var expected: [checksum_len]u8 = undefined;
        std.mem.writeInt(u32, &expected, crc32(self.out[0..self.body_len]), .big);
        if (!std.mem.eql(u8, &expected, &self.tail)) return error.ChecksumMismatch;
        return self.out[0..self.body_len];
    }
};

fn sameLetters(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

/// 4 文字の語をバイト値に変換する。語彙になければ error.InvalidEncoding。
fn lookupWord(token: []const u8) Error!u8 {
    if (token.len != word_len) return error.InvalidEncoding;
    for (words, 0..) |word, i| {
        if (sameLetters(word, token)) return @intCast(i);
    }
    return error.InvalidEncoding;
}

/// 2 文字の最小表現（先頭 + 末尾）をバイト値に変換する。
fn lookupMinimal(token: []const u8) Error!u8 {
    if (token.len != minimal_len) return error.InvalidEncoding;
    const first = std.ascii.toLower(token[0]);
    const last = std.ascii.toLower(token[minimal_len - 1]);
    for (words, 0..) |word, i| {
        if (word[0] == first and word[word_len - 1] == last) return @intCast(i);
    }
    return error.InvalidEncoding;
}

/// 3 文字（先頭 3 文字 or 末尾 3 文字）をバイト値に変換する。
///
/// 先頭 3 文字の集合と末尾 3 文字の集合は重なりうる（例: "ice" は iced の先頭 3 文字
/// でも dice の末尾 3 文字でもある）。**迷ったら推測せず** error.InvalidEncoding を返す。
fn lookupTriple(token: []const u8) Error!u8 {
    if (token.len != 3) return error.InvalidEncoding;
    var found: ?u8 = null;
    for (words, 0..) |word, i| {
        if (sameLetters(word[0..3], token) or sameLetters(word[1..4], token)) {
            const byte: u8 = @intCast(i);
            if (found) |previous| {
                if (previous != byte) return error.InvalidEncoding;
            } else {
                found = byte;
            }
        }
    }
    return found orelse error.InvalidEncoding;
}

/// チェックサムを検証し、取り除いた本体を `out` に書き出して返す。
///
/// - standard / uri: 区切り（空白 / ハイフン）で語に分ける。連続する区切りは無視する。
/// - minimal: 2 文字ずつに分ける（奇数長は error.InvalidEncoding）。
/// - 語彙にない語・長さ不足・チェックサム不一致はすべて error で拒否する。
pub fn decode(out: []u8, text: []const u8, style: Style) Error![]u8 {
    var state = DecoderState{ .out = out };

    switch (style) {
        .minimal => {
            if (text.len % minimal_len != 0) return error.InvalidEncoding;
            var i: usize = 0;
            while (i < text.len) : (i += minimal_len) {
                try state.push(try lookupMinimal(text[i..][0..minimal_len]));
            }
        },
        .standard, .uri => {
            const separator: u8 = if (style == .standard) ' ' else '-';
            var tokens = std.mem.tokenizeScalar(u8, text, separator);
            while (tokens.next()) |token| {
                try state.push(try lookupWord(token));
            }
        },
    }
    return state.finish();
}

/// 人が書き写した語や OCR した語をバイト値に正規化する。
///
/// 語彙の条件（BCR-2020-012 §Word selection criteria）により、語は
/// 語そのもの（4 文字）と先頭+末尾（2 文字）で一意に特定できる。
/// 3 文字（先頭 3 文字 / 末尾 3 文字）も受け付けるが、両者が衝突する場合は
/// 推測せず error.InvalidEncoding を返す。
pub fn canonicalize(token: []const u8) Error!u8 {
    return switch (token.len) {
        minimal_len => lookupMinimal(token),
        3 => lookupTriple(token),
        word_len => lookupWord(token),
        else => error.InvalidEncoding,
    };
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// BCR-2020-012 §Example/Test Vector: 16 バイトの seed をタグ付き CBOR にした本体（27 バイト）。
const spec_body_hex = "d99d6ca20150c7098580125e2ab0981253468b2dbc5202c11947da";

fn decodeHex(buf: []u8, hex: []const u8) []u8 {
    std.debug.assert(hex.len % 2 == 0);
    for (0..hex.len / 2) |i| {
        buf[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch unreachable;
    }
    return buf[0 .. hex.len / 2];
}

test "語彙は BCR-2020-012 の条件を満たす" {
    try testing.expectEqual(@as(usize, 256), words.len);

    // すべて 4 文字の英小文字で、アルファベット順に並んでいる。
    for (words, 0..) |word, i| {
        try testing.expectEqual(@as(usize, word_len), word.len);
        for (word) |c| try testing.expect(c >= 'a' and c <= 'z');
        if (i > 0) try testing.expect(std.mem.order(u8, words[i - 1], word) == .lt);
    }

    // 先頭+末尾・先頭 3 文字・末尾 3 文字がすべて一意。
    for (words, 0..) |a, i| {
        for (words[i + 1 ..]) |b| {
            try testing.expect(!(a[0] == b[0] and a[3] == b[3]));
            try testing.expect(!std.mem.eql(u8, a[0..3], b[0..3]));
            try testing.expect(!std.mem.eql(u8, a[1..4], b[1..4]));
        }
    }
}

test "CRC-32 の既知の値と一致する" {
    // bc-ur test/test.cpp test_crc32
    try testing.expectEqual(@as(u32, 0xebe6c6e6), crc32("Hello, world!"));
    // BCR-2024-001 §CRC-32 Checksum（Swift リファレンス実装のテストベクタ）
    try testing.expectEqual(@as(u32, 0x598c84dc), crc32("Wolf"));

    // BCR-2020-012 §Example/Test Vector の本体とチェックサム
    var buf: [64]u8 = undefined;
    try testing.expectEqual(@as(u32, 0xc904f40b), crc32(decodeHex(&buf, spec_body_hex)));

    // BCR-2020-012 §Brutal Encoding のペイロードとチェックサム
    try testing.expectEqual(
        @as(u32, 0xfeac0dea),
        crc32(decodeHex(&buf, "c7098580125e2ab0981253468b2dbc52")),
    );

    // bc-ur-rust test_ur の CBOR [1, 2, 3]（"ur:test/lsadaoaxjygonesw" の末尾 4 バイト）
    try testing.expectEqual(@as(u32, 0x74559fc6), crc32(decodeHex(&buf, "83010203")));
}

test "BCR-2020-012 の例と一致する（standard / uri / minimal）" {
    var body_buf: [64]u8 = undefined;
    const body = decodeHex(&body_buf, spec_body_hex);

    const expected_standard =
        "tuna next jazz oboe acid good slot axis limp lava brag holy door puff monk brag " ++
        "guru frog luau drop roof grim also safe chef fuel twin solo aqua work bald";
    const expected_uri =
        "tuna-next-jazz-oboe-acid-good-slot-axis-limp-lava-brag-holy-door-puff-monk-brag-" ++
        "guru-frog-luau-drop-roof-grim-also-safe-chef-fuel-twin-solo-aqua-work-bald";
    const expected_minimal =
        "tantjzoeadgdstaslplabghydrpfmkbggufgludprfgmaosecffltnsoaawkbd";

    var out: [256]u8 = undefined;
    try testing.expectEqualStrings(expected_standard, try encodeWithChecksum(&out, body, .standard));
    try testing.expectEqualStrings(expected_uri, try encodeWithChecksum(&out, body, .uri));
    try testing.expectEqualStrings(expected_minimal, try encodeWithChecksum(&out, body, .minimal));

    // ラウンドトリップ（本体 27 バイト、チェックサムは取り除かれる）
    var decoded: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 27), (try decode(&decoded, expected_standard, .standard)).len);
    try testing.expectEqualStrings(body, try decode(&decoded, expected_standard, .standard));
    try testing.expectEqualStrings(body, try decode(&decoded, expected_uri, .uri));
    try testing.expectEqualStrings(body, try decode(&decoded, expected_minimal, .minimal));
}

test "BCR-2020-012 の brutal 例と一致する" {
    var body_buf: [64]u8 = undefined;
    const payload = decodeHex(&body_buf, "c7098580125e2ab0981253468b2dbc52");

    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "slot axis limp lava brag holy door puff monk brag guru frog luau drop roof grim " ++
            "zone plus belt wand",
        try encodeWithChecksum(&out, payload, .standard),
    );
    try testing.expectEqualStrings(
        "staslplabghydrpfmkbggufgludprfgmzepsbtwd",
        try encodeWithChecksum(&out, payload, .minimal),
    );

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(payload, try decode(&decoded, "staslplabghydrpfmkbggufgludprfgmzepsbtwd", .minimal));
}

test "bc-ur の Bytewords テストベクタ 1" {
    // bc-ur test/test.cpp test_bytewords_1
    const input = [_]u8{ 0, 1, 2, 128, 255 };

    var out: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "able acid also lava zoom jade need echo taxi",
        try encodeWithChecksum(&out, &input, .standard),
    );
    try testing.expectEqualStrings(
        "able-acid-also-lava-zoom-jade-need-echo-taxi",
        try encodeWithChecksum(&out, &input, .uri),
    );
    try testing.expectEqualStrings(
        "aeadaolazmjendeoti",
        try encodeWithChecksum(&out, &input, .minimal),
    );

    var decoded: [8]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, "able acid also lava zoom jade need echo taxi", .standard));
    try testing.expectEqualStrings(&input, try decode(&decoded, "able-acid-also-lava-zoom-jade-need-echo-taxi", .uri));
    try testing.expectEqualStrings(&input, try decode(&decoded, "aeadaolazmjendeoti", .minimal));

    // チェックサムだけが違う入力（zoom taxi → zero wolf）。
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "able acid also lava zero jade need echo wolf", .standard),
    );
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "able-acid-also-lava-zero-jade-need-echo-wolf", .uri),
    );
    try testing.expectError(
        error.ChecksumMismatch,
        decode(&decoded, "aeadaolazojendeowf", .minimal),
    );

    // 語が 1 つしかない入力は本体が空になるので拒否する。
    try testing.expectError(error.Truncated, decode(&decoded, "wolf", .standard));
    try testing.expectError(error.Truncated, decode(&decoded, "", .standard));
    try testing.expectError(error.Truncated, decode(&decoded, "", .minimal));
}

test "bc-ur の Bytewords テストベクタ 2（100 バイト）" {
    // bc-ur test/test.cpp test_bytewords_2
    const input = [100]u8{
        0xf5, 0xd7, 0x14, 0xc6, 0xf1, 0xeb, 0x45, 0x3b, 0xd1, 0xcd, 0xa5, 0x12, 0x96, 0x9e, 0x74, 0x87,
        0xe5, 0xd4, 0x13, 0x9f, 0x11, 0x25, 0xef, 0xf0, 0xfd, 0x0b, 0x6d, 0xbf, 0x25, 0xf2, 0x26, 0x78,
        0xdf, 0x29, 0x9c, 0xbd, 0xf2, 0xfe, 0x93, 0xcc, 0x42, 0xa3, 0xd8, 0xaf, 0xbf, 0x48, 0xa9, 0x36,
        0x20, 0x3c, 0x90, 0xe6, 0xd2, 0x89, 0xb8, 0xc5, 0x21, 0x71, 0x58, 0x0e, 0x9d, 0x1f, 0xb1, 0x2e,
        0x01, 0x73, 0xcd, 0x45, 0xe1, 0x96, 0x41, 0xeb, 0x3a, 0x90, 0x41, 0xf0, 0x85, 0x45, 0x71, 0xf7,
        0x3f, 0x35, 0xf2, 0xa5, 0xa0, 0x90, 0x1a, 0x0d, 0x4f, 0xed, 0x85, 0x47, 0x52, 0x45, 0xfe, 0xa5,
        0x8a, 0x29, 0x55, 0x18,
    };

    const expected_standard =
        "yank toys bulb skew when warm free fair tent swan open brag mint noon jury list view tiny " ++
        "brew note body data webs what zinc bald join runs data whiz days keys user diet news ruby " ++
        "whiz zone menu surf flew omit trip pose runs fund part even crux fern math visa tied loud " ++
        "redo silk curl jugs hard beta next cost puma drum acid junk swan free very mint flap warm " ++
        "fact math flap what limp free jugs yell fish epic whiz open numb math city belt glow wave " ++
        "limp fuel grim free zone open love diet gyro cats fizz holy city puff";
    const expected_minimal =
        "yktsbbswwnwmfefrttsnonbgmtnnjyltvwtybwnebydawswtzcbdjnrsdawzdsksurdtnsrywzzemusf" ++
        "fwottppersfdptencxfnmhvatdldroskcljshdbantctpadmadjksnfevymtfpwmftmhfpwtlpfejsyl" ++
        "fhecwzonnbmhcybtgwwelpflgmfezeonledtgocsfzhycypf";

    var out: [1024]u8 = undefined;
    try testing.expectEqualStrings(expected_standard, try encodeWithChecksum(&out, &input, .standard));
    try testing.expectEqualStrings(expected_minimal, try encodeWithChecksum(&out, &input, .minimal));

    var decoded: [128]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, expected_standard, .standard));
    try testing.expectEqualStrings(&input, try decode(&decoded, expected_minimal, .minimal));
}

test "bc-ur-rust の UR テストベクタ（minimal）" {
    // bc-ur-rust src/ur.rs test_ur: CBOR [1, 2, 3] の minimal Bytewords。
    var decoded: [8]u8 = undefined;
    const body = try decode(&decoded, "lsadaoaxjygonesw", .minimal);
    var expected: [4]u8 = undefined;
    try testing.expectEqualStrings(decodeHex(&expected, "83010203"), body);

    var out: [64]u8 = undefined;
    const input = [_]u8{ 0x83, 0x01, 0x02, 0x03 };
    try testing.expectEqualStrings("lsadaoaxjygonesw", try encodeWithChecksum(&out, &input, .minimal));
}

test "全バイト値のラウンドトリップ" {
    var input: [256]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast(i);

    var encoded: [2048]u8 = undefined;
    var decoded: [256]u8 = undefined;

    for ([_]Style{ .standard, .uri, .minimal }) |style| {
        const text = try encodeWithChecksum(&encoded, &input, style);
        try testing.expectEqual(encodedLength(input.len, style), text.len);
        try testing.expectEqualStrings(&input, try decode(&decoded, text, style));
    }

    // 1 バイトずつ（チェックサムがあるので本体 1 バイトでも成立する）。
    for (0..256) |i| {
        const one = [_]u8{@intCast(i)};
        const text = try encodeWithChecksum(&encoded, &one, .minimal);
        try testing.expectEqual(@as(usize, 10), text.len);
        try testing.expectEqualStrings(&one, try decode(&decoded, text, .minimal));
    }
}

test "大文字の入力を受理する（QR コード用）" {
    var input: [32]u8 = undefined;
    for (&input, 0..) |*b, i| b.* = @intCast((i * 7 + 3) % 256);

    var encoded: [256]u8 = undefined;
    const text = try encodeWithChecksum(&encoded, &input, .minimal);

    var upper: [256]u8 = undefined;
    for (text, 0..) |c, i| upper[i] = std.ascii.toUpper(c);
    const upper_text = upper[0..text.len];

    var decoded: [64]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&decoded, upper_text, .minimal));

    // standard / uri でも大文字を受け付ける。
    const standard = try encodeWithChecksum(&encoded, &input, .standard);
    var upper_standard: [256]u8 = undefined;
    for (standard, 0..) |c, i| upper_standard[i] = std.ascii.toUpper(c);
    try testing.expectEqualStrings(
        &input,
        try decode(&decoded, upper_standard[0..standard.len], .standard),
    );
}

test "壊れた入力を拒否する" {
    var out: [128]u8 = undefined;

    // 語彙にない語・語の長さが違う（standard / uri）
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo xxxx", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo taxi extra", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "ableacid also lava zoom jade need echo taxi", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able-acid-also-lava-zoom-jade-need-echo-tax", .uri));
    // 区切り文字の取り違え（uri を standard として読む / その逆）
    try testing.expectError(error.InvalidEncoding, decode(&out, "able-acid-also-lava-zoom-jade-need-echo-taxi", .standard));
    try testing.expectError(error.InvalidEncoding, decode(&out, "able acid also lava zoom jade need echo taxi", .uri));

    // minimal: 語彙にない 2 文字・奇数長
    try testing.expectError(error.InvalidEncoding, decode(&out, "aeadaolazmjendeotx", .minimal));
    try testing.expectError(error.InvalidEncoding, decode(&out, "aeadaolazmjendeoti0", .minimal));

    // 長さ不足（チェックサム 4 バイトにも満たない）
    try testing.expectError(error.Truncated, decode(&out, "aeadao", .minimal));
    try testing.expectError(error.Truncated, decode(&out, "able acid also", .standard));

    // チェックサム不一致（本体ではなく末尾 4 バイトが違う）
    try testing.expectError(error.ChecksumMismatch, decode(&out, "aeadaolazmjendeotl", .minimal));
}

test "本体を書き出すバッファが足りない場合は BufferTooSmall" {
    const input = [_]u8{ 0, 1, 2, 128, 255 };
    var encoded: [128]u8 = undefined;
    const text = try encodeWithChecksum(&encoded, &input, .minimal);

    // 符号化: 出力が 1 バイト足りない
    try testing.expectError(error.BufferTooSmall, encodeWithChecksum(encoded[0 .. encodedLength(input.len, .minimal) - 1], &input, .minimal));
    try testing.expectError(error.BufferTooSmall, encode(encoded[0 .. input.len * minimal_len - 1], &input, .minimal));

    // デコード: 本体 5 バイトを入れる場所がない
    var small: [4]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, decode(&small, text, .minimal));
    var exact: [5]u8 = undefined;
    try testing.expectEqualStrings(&input, try decode(&exact, text, .minimal));
}

test "canonicalize は 2 / 3 / 4 文字を受け付ける" {
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ae")); // able の先頭+末尾
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("abl")); // able の先頭 3 文字
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ble")); // able の末尾 3 文字
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("able"));
    try testing.expectEqual(@as(u8, 0x00), try canonicalize("ABLE"));

    for (words, 0..) |word, i| {
        // 語そのものと先頭+末尾は常に一意。
        try testing.expectEqual(@as(u8, @intCast(i)), try canonicalize(word));
        try testing.expectEqual(@as(u8, @intCast(i)), try canonicalize(&minimalFor(@intCast(i))));

        // 3 文字は「正しい語を返す」か「曖昧として拒否する」のどちらかでなければならない。
        for ([_][]const u8{ word[0..3], word[1..4] }) |triple| {
            if (canonicalize(triple)) |byte| {
                try testing.expectEqual(@as(u8, @intCast(i)), byte);
            } else |err| {
                try testing.expectEqual(Error.InvalidEncoding, err);
            }
        }
    }

    // 実際に曖昧になる例: "ice" は iced の先頭 3 文字であり dice の末尾 3 文字でもある。
    try testing.expectError(error.InvalidEncoding, canonicalize("ice"));
    try testing.expectError(error.InvalidEncoding, canonicalize("axi")); // axis / taxi

    try testing.expectError(error.InvalidEncoding, canonicalize(""));
    try testing.expectError(error.InvalidEncoding, canonicalize("a"));
    try testing.expectError(error.InvalidEncoding, canonicalize("aaaaa"));
    try testing.expectError(error.InvalidEncoding, canonicalize("zz"));
}
