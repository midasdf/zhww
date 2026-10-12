//! QR コード（ISO/IEC 18004）エンコーダ。表示専用で、**デコーダは含まない**。
//!
//! 用途は 240×240 LCD に UR 文字列・アドレス・署名結果を QR として表示すること。
//! 署名フローから渡される数百バイトの UR 文字列を扱えるよう、バージョン 1〜40 に対応する。
//!
//! **実装範囲**
//! - モード: 数字 / 英数字 / バイト（1 シンボル = 1 セグメント。混在セグメント最適化はしない）
//! - 誤り訂正: L / M / Q / H（自動昇格 "boost error" はしない。指定どおりに作る）
//! - バージョン: 1〜40。入力長と EC レベルから最小を自動選択（指定も可能）
//! - マスク: 8 種類すべてを試し、規格 Table 11 の 4 ペナルティ（N1〜N4）の合計が
//!   最小のものを選ぶ（同点は小さい番号）
//! - 出力: モジュール行列（1 モジュール 1 バイト、0=明 1=暗）と RGB565 描画ヘルパ
//!
//! **マスク評価の規約（実装上の最大の分岐点）**
//! 規格 6.8 は「マスキングは format/version 情報を除いた符号化領域に適用する」と定めるが、
//! **4 つのペナルティで評価する行列に format/version 情報を含めるか**は明文で定めていない。
//! 本実装は既定（`MaskEval.final_symbol`）で「候補マスクの format 情報を書き込んだ
//! 最終形のシンボル」を評価する。この規約は規格 Annex I.2 の作業例
//! （"01234567" をバージョン 1-M で符号化 → 選択されるマスクは 010 = 2）を再現する。
//! 検証では 20 通りの解釈（format 情報を書く/書かない × N3 の 5 通り × N4 の 2 通り）を
//! 総当たりし、Annex I.2 のマスク 2 を再現するのはこの組み合わせだけであった。
//! もう一方の `MaskEval.encoding_region_only`（format/version 情報を空のまま評価）は
//! segno 1.6.6 と python-qrcode 8.2 がとる規約で、第三者実装との突き合わせに使う。
//! どちらの規約でも生成されるシンボルは規格に適合し、復号できる（マスク番号は
//! format 情報に記録されるため）。
//!
//! **第三者実装との既知の差異（重要）**
//! - segno 1.6.6 には「ターミネータの直後がちょうどコードワード境界に来るとき、規格が
//!   要求しない 8 ビットの 0 を追加してしまう」バグがある（heuer/segno#123、2023-05 報告、
//!   本実装の時点で未修正）。この結果 segno は 0xEC のパッドコードワード 1 個を 0x00 に
//!   置き換え、以降のパッドコードワードが 1 バイト分ずれる。バイトモードではほぼ常に
//!   この条件に当たるため、segno と本実装の行列はパディング領域で一致しない。
//!   本実装は規格 7.4.9 / 7.4.10 のとおり、境界に来た場合はパディングビットを追加しない。
//!   （0xEC の位置が変わるだけで復号はできるが、規格の要求ではない。）
//! - 自動マスク選択は N3 の解釈が実装ごとに違う。本実装は規格 Table 11 の文言どおり
//!   「1011101 の前後いずれかに 4 モジュールの明領域」を数え、シンボル外（クワイエット
//!   ゾーン）は明として扱う（segno と同じ）。Nayuki qrcodegen は 1:1:3:1:1 の比率を
//!   n 倍に拡張した解釈、zxing / python-qrcode はシンボル外を明としない。
//! - N4（暗モジュール比率）は `k = |暗% - 50%| / 5%` の整数除算。規格 Table 11 の
//!   ちょうど 5% 倍数の境界の扱いは実装ごとに揺れるが、本実装は segno と一致する
//!   （qrcodegen の `ceil(...) - 1` とは境界でのみ差が出る）。
//!
//! **メモリ**
//! 行列（バージョン 40 で 177×177 = 31 KB）と一時バッファ（データコードワード 2956 B、
//! 最終メッセージ 3706 B、機能モジュールフラグ 4 KB）をアロケータから取る。
//! 秘密情報は扱わない（QR に載せる文字列は呼び出し側の責任で選ぶ）。
//!
//! **テストの期待値の出典**
//! 埋め込んだ期待値はすべて第三者実装または規格そのものから取得している（各テストの
//! コメントに明記）。自作の期待値は使っていない。検証に使った実装:
//!   - ISO/IEC 18004:2006(E) の本文・Annex（Table C.1 / Table D.1 / Annex I.2 の作業例）
//!   - Nayuki qrcodegen 1.8.0（Python 版）
//!   - python-qrcode 8.2
//!   - segno 1.6.6（上記パディングバグのみ規格どおりに修正して実行）
//!
//! **突き合わせ検証の結果（開発時に実施。テストベクタの生成にも使った）**
//! - 強制マスク時の全モジュール行列: 全 40 バージョン × 4 EC レベル × マスク {0,7} の
//!   320 ケースで qrcodegen と完全一致（SHA-256 で比較）。代表 56 ケース
//!   （短い英数字・数字・境界長・日本語 UTF-8・UR 風 700 文字・ランダム 1000 バイトなど
//!   × 4 EC）では qrcodegen / python-qrcode / segno（パディング修正）の 3 実装すべてと
//!   完全一致。
//! - バージョン自動選択: 上記 124 ケース（31 入力 × 4 EC）で 3 実装と完全一致。
//!   容量を超える 7 ケースも 3 実装と同じくエラーになることを確認。
//! - 自動マスク選択: `MaskEval.encoding_region_only`（segno と同じ規約）は segno と
//!   117/117 一致。既定の `MaskEval.final_symbol` は規格 Annex I.2 の作業例
//!   （"01234567" 1-M → マスク 2）を再現する唯一の規約だが、format 情報を評価に
//!   含めない segno / python-qrcode とはマスクが食い違うことがある（マスクが違っても
//!   生成物は規格適合で、復号結果は同じ）。
//!
//! 参考: ISO/IEC 18004:2015/2006, https://www.qrcode.com/en/about/standards.html
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const CoreError = @import("../core/errors.zig").Error;

/// エンコード時のエラー。コア共通の `Error` に QR 固有のものを加える。
pub const Error = CoreError || error{
    /// 誤り訂正レベルとバージョンの容量を超える（バージョン 40 でも収まらない）
    DataTooLong,
    /// バージョン指定が範囲外（1〜40）
    InvalidVersion,
    /// 指定したモードで表せない文字が入力に含まれる
    /// （数字モードに数字以外、英数字モードに規格 Table 5 以外の文字）
    InvalidCharacter,
};

/// 対応する最小バージョン。
pub const min_version: u8 = 1;
/// 対応する最大バージョン。
pub const max_version: u8 = 40;
/// バージョン 1 のシンボル一辺のモジュール数。
pub const min_size: usize = 17 + 4 * min_version;
/// バージョン 40 のシンボル一辺のモジュール数。
pub const max_size: usize = 17 + 4 * max_version;
/// マスクパターンの数（規格 Table 10）。
pub const mask_count: usize = 8;
/// 規格 8.1 が要求する最小クワイエットゾーン（モジュール数）。
pub const min_quiet_zone: u8 = 4;

/// 誤り訂正レベル（規格 Table 12）。値は format 情報の 2 ビットそのもの。
pub const EcLevel = enum(u2) {
    /// 約 7% 復元
    l = 0b01,
    /// 約 15% 復元
    m = 0b00,
    /// 約 25% 復元
    q = 0b11,
    /// 約 30% 復元
    h = 0b10,

    /// 容量テーブルの添字（L=0, M=1, Q=2, H=3）。
    pub fn index(self: EcLevel) usize {
        return switch (self) {
            .l => 0,
            .m => 1,
            .q => 2,
            .h => 3,
        };
    }

    /// format 情報に入れる 2 ビット（規格 Table 12）。
    pub fn formatBits(self: EcLevel) u3 {
        return @backingInt(self);
    }

    /// 1 文字の指定（'l' / 'm' / 'q' / 'h'、大文字も可）。
    pub fn fromChar(c: u8) ?EcLevel {
        return switch (c) {
            'l', 'L' => .l,
            'm', 'M' => .m,
            'q', 'Q' => .q,
            'h', 'H' => .h,
            else => null,
        };
    }

    /// 画面表示などに使う名前。
    pub fn name(self: EcLevel) []const u8 {
        return switch (self) {
            .l => "L",
            .m => "M",
            .q => "Q",
            .h => "H",
        };
    }
};

/// データモード（規格 Table 2 のモード指示子）。
pub const Mode = enum {
    numeric,
    alphanumeric,
    byte,

    /// モード指示子（4 ビット、規格 Table 2）。
    pub fn indicator(self: Mode) u4 {
        return switch (self) {
            .numeric => 0b0001,
            .alphanumeric => 0b0010,
            .byte => 0b0100,
        };
    }

    /// 文字数指示子のビット数（規格 Table 3）。
    pub fn charCountBits(self: Mode, version: u8) usize {
        return switch (self) {
            .numeric => if (version <= 9) 10 else if (version <= 26) 12 else 14,
            .alphanumeric => if (version <= 9) 9 else if (version <= 26) 11 else 13,
            .byte => if (version <= 9) 8 else 16,
        };
    }

    /// 画面表示などに使う名前。
    pub fn name(self: Mode) []const u8 {
        return switch (self) {
            .numeric => "numeric",
            .alphanumeric => "alphanumeric",
            .byte => "byte",
        };
    }

    /// このモードで `text` を表せるか（バイトモードは常に真）。
    pub fn canEncode(self: Mode, text: []const u8) bool {
        return switch (self) {
            .numeric => isNumeric(text),
            .alphanumeric => isAlphanumeric(text),
            .byte => true,
        };
    }
};

/// 自動マスク選択で、ペナルティ評価の対象にする行列の種類。
pub const MaskEval = enum {
    /// 候補マスクの format 情報（および dark モジュール・version 情報）を書き込んだ
    /// 「最終形のシンボル」を評価する。既定であり、規格 Annex I.2 の作業例を再現する。
    final_symbol,
    /// format/version 情報の領域を空（明）のまま評価する。segno 1.6.6 / python-qrcode 8.2
    /// と同じ規約。Annex I.2 の作業例は再現しない。第三者実装との突き合わせ用。
    encoding_region_only,
};

/// エンコードのオプション。
pub const Options = struct {
    /// null なら入力長と EC レベルから最小バージョンを選ぶ。
    version: ?u8 = null,
    /// null なら 8 種類のマスクを評価して自動選択する。
    mask: ?u3 = null,
    /// null なら入力から自動判定する（数字 → 英数字 → バイトの順に狭いモードを選ぶ）。
    mode: ?Mode = null,
    /// 自動マスク選択の評価規約。
    mask_eval: MaskEval = .final_symbol,
};

/// エンコード結果のモジュール行列。
///
/// `modules` は 1 モジュール 1 バイト（行優先、0 = 明 / 1 = 暗）で、UI 層の
/// `screen.Bitmap`（`modules: []const u8`、0 以外は黒）へそのまま渡せる。
pub const Matrix = struct {
    /// バージョン（1〜40）。
    version: u8,
    /// 一辺のモジュール数（17 + 4 × version）。
    size: usize,
    /// 誤り訂正レベル。
    ec: EcLevel,
    /// 実際に使ったマスク番号（0〜7）。
    mask: u3,
    /// 実際に使ったデータモード。
    mode: Mode,
    /// モジュール（1 バイト 1 モジュール、行優先、0 = 明 / 1 = 暗）。
    modules: []u8,

    /// 幅（= 高さ。QR は正方形）。
    pub fn width(self: *const Matrix) usize {
        return self.size;
    }

    /// 高さ（= 幅）。
    pub fn height(self: *const Matrix) usize {
        return self.size;
    }

    /// (x, y) のモジュール。範囲外は明（false）として扱う。
    pub fn get(self: *const Matrix, x: usize, y: usize) bool {
        if (x >= self.size or y >= self.size) return false;
        return self.modules[y * self.size + x] != 0;
    }

    /// 暗モジュールの総数。
    pub fn darkCount(self: *const Matrix) usize {
        var count: usize = 0;
        for (self.modules) |m| {
            if (m != 0) count += 1;
        }
        return count;
    }

    /// 行列が確保したメモリを解放する。以後 `self` は使えない。
    pub fn deinit(self: *const Matrix, allocator: std.mem.Allocator) void {
        allocator.free(self.modules);
    }
};

// ---------------------------------------------------------------- 公開 API

/// 最小バージョン・自動マスクで行列を作る（もっとも一般的な入口）。
pub fn encode(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{});
}

/// マスクを固定して行列を作る（検証・比較用）。
pub fn encodeWithMask(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, mask: u3) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{ .mask = mask });
}

/// バージョンを固定して行列を作る（収まらなければ `DataTooLong`）。
pub fn encodeVersion(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, version: u8) Error!Matrix {
    return encodeOptions(allocator, text, ec, .{ .version = version });
}

/// オプションを指定して行列を作る。
pub fn encodeOptions(allocator: std.mem.Allocator, text: []const u8, ec: EcLevel, opts: Options) Error!Matrix {
    const mode = opts.mode orelse detectMode(text);
    // モードを明示指定された場合は、そのモードで表せない文字を拒否する
    // （黙って壊れたシンボルを作らない。表示専用でも誤った QR を出すより落とす）。
    if (!mode.canEncode(text)) return Error.InvalidCharacter;
    const version = opts.version orelse try selectVersion(mode, text.len, ec);
    if (version < min_version or version > max_version) return Error.InvalidVersion;

    const count_bits = mode.charCountBits(version);
    if (text.len >= (@as(usize, 1) << @intCast(count_bits))) return Error.DataTooLong;
    const capacity_bits = dataCodewords(ec, version) * 8;
    if (4 + count_bits + dataBitLength(mode, text.len) > capacity_bits) return Error.DataTooLong;

    const size = versionSize(version);
    const data_len = dataCodewords(ec, version);
    const raw_len = rawCodewords(version);

    // データコードワード
    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    @memset(data, 0);
    var bit_len: usize = 0;
    writeData(data, &bit_len, mode, text, version);
    writePadding(data, &bit_len, capacity_bits);

    // 誤り訂正を付けてインターリーブした最終メッセージ
    const message = try allocator.alloc(u8, raw_len);
    defer allocator.free(message);
    try buildMessage(allocator, data, message, ec, version);

    // 行列本体と機能モジュールフラグ（フラグは 1 モジュール 1 ビットで持つ）
    const modules = try allocator.alloc(u8, size * size);
    errdefer allocator.free(modules);
    const func = try allocator.alloc(u8, (size * size + 7) / 8);
    defer allocator.free(func);
    @memset(func, 0);
    @memset(modules, 0);

    var builder = Builder{ .size = size, .modules = modules, .func = func };
    buildMatrix(&builder, message, ec, version, opts);

    return Matrix{
        .version = version,
        .size = size,
        .ec = ec,
        .mask = builder.mask,
        .mode = mode,
        .modules = modules,
    };
}

/// 入力から最適な単一モードを選ぶ。
///
/// 数字だけなら数字モード、規格 Table 5 の英数字 45 文字だけなら英数字モード、
/// それ以外（UTF-8 の日本語など）はバイトモード。モード混在の最適化はしない。
pub fn detectMode(text: []const u8) Mode {
    if (isNumeric(text)) return .numeric;
    if (isAlphanumeric(text)) return .alphanumeric;
    return .byte;
}

// ---------------------------------------------------------------- RGB565 描画

/// RGB565 描画のオプション。
pub const DrawOptions = struct {
    /// 暗モジュールの色（既定は黒）。
    dark: u16 = 0x0000,
    /// 明モジュールと余白の色（既定は白）。
    light: u16 = 0xFFFF,
    /// 1 モジュールあたりのピクセル数（拡大倍率）。0 は描画しない。
    scale: u8 = 1,
    /// 余白（クワイエットゾーン、モジュール数）。規格は 4 以上を要求する。
    quiet_zone: u8 = min_quiet_zone,
    /// 描画開始位置（左上のピクセル座標）。負の値も許し、はみ出しはクリップする。
    origin_x: i32 = 0,
    origin_y: i32 = 0,
};

/// 余白を含めた描画サイズ（一辺のピクセル数）。
pub fn pixelSize(m: *const Matrix, opts: DrawOptions) usize {
    if (opts.scale == 0) return 0;
    return (m.size + 2 * @as(usize, opts.quiet_zone)) * @as(usize, opts.scale);
}

/// 余白を含めた全体がフレームバッファに収まるか。負の原点（クリップ前提）は false。
pub fn fitsIn(m: *const Matrix, fb_width: usize, fb_height: usize, opts: DrawOptions) bool {
    if (opts.scale == 0) return false;
    if (opts.origin_x < 0 or opts.origin_y < 0) return false;
    const px = pixelSize(m, opts);
    const x: usize = @intCast(opts.origin_x);
    const y: usize = @intCast(opts.origin_y);
    if (x >= fb_width or y >= fb_height) return false;
    return px <= fb_width - x and px <= fb_height - y;
}

/// RGB565 のフレームバッファ（行優先、1 ピクセル 1 個の u16）へ行列を描く。
///
/// - 余白（`opts.quiet_zone`）と拡大倍率（`opts.scale`）を指定できる。
/// - 描画するのは「余白 + シンボル」の正方形領域だけ。その外側のピクセルには触らない。
/// - フレームバッファの外へはみ出す部分はクリップする（負の原点も可）。
/// - `buffer.len` が `fb_width * fb_height` より小さい場合は、入る行だけ描く。
pub fn drawRgb565(
    m: *const Matrix,
    buffer: []u16,
    fb_width: usize,
    fb_height: usize,
    opts: DrawOptions,
) void {
    if (fb_width == 0 or fb_height == 0 or opts.scale == 0) return;
    const rows = @min(fb_height, buffer.len / fb_width);
    if (rows == 0) return;

    const total = m.size + 2 * @as(usize, opts.quiet_zone);
    const scale: i64 = opts.scale;

    var my: usize = 0;
    while (my < total) : (my += 1) {
        const py0 = clipStart(@as(i64, opts.origin_y) + @as(i64, @intCast(my)) * scale, rows);
        const py1 = clipEnd(@as(i64, opts.origin_y) + (@as(i64, @intCast(my)) + 1) * scale, rows);
        if (py1 <= py0) continue;

        var mx: usize = 0;
        while (mx < total) : (mx += 1) {
            const px0 = clipStart(@as(i64, opts.origin_x) + @as(i64, @intCast(mx)) * scale, fb_width);
            const px1 = clipEnd(@as(i64, opts.origin_x) + (@as(i64, @intCast(mx)) + 1) * scale, fb_width);
            if (px1 <= px0) continue;

            const dark = if (mx >= opts.quiet_zone and my >= opts.quiet_zone)
                m.get(mx - opts.quiet_zone, my - opts.quiet_zone)
            else
                false;
            const color = if (dark) opts.dark else opts.light;

            var py = py0;
            while (py < py1) : (py += 1) {
                @memset(buffer[py * fb_width + px0 .. py * fb_width + px1], color);
            }
        }
    }
}

/// 0 未満を 0 に、`limit` を超えるものを `limit` に丸める（クリップ開始位置）。
fn clipStart(value: i64, limit: usize) usize {
    if (value <= 0) return 0;
    const v: usize = @intCast(value);
    return @min(v, limit);
}

/// 0 未満を 0 に、`limit` を超えるものを `limit` に丸める（クリップ終了位置）。
fn clipEnd(value: i64, limit: usize) usize {
    if (value <= 0) return 0;
    const v: usize = @intCast(value);
    return @min(v, limit);
}

// ---------------------------------------------------------------- 容量テーブル

/// ブロックあたりの誤り訂正コードワード数（規格 Table 9）。添字は [EC][version]。
/// version 0 は未使用（0）。値は segno 1.6.6 の `consts.ECC` と qrcodegen 1.8.0 の
/// `_ECC_CODEWORDS_PER_BLOCK` が完全に一致することを確認済み。
const ecc_codewords_per_block = [4][max_version + 1]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// 誤り訂正ブロック数（規格 Table 9）。添字は [EC][version]。
const num_ec_blocks = [4][max_version + 1]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// バージョンからシンボル一辺のモジュール数を求める。
pub fn versionSize(version: u8) usize {
    return 17 + 4 * @as(usize, version);
}

/// データと誤り訂正に使えるモジュール数（剰余ビットを含む）。
///
/// 規格の配置規則から導かれる式（Nayuki qrcodegen の `getNumRawDataModules` と同じ）。
fn numRawDataModules(version: u8) usize {
    const v: usize = version;
    var result: usize = (16 * v + 128) * v + 64;
    if (version >= 2) {
        const num_align: usize = v / 7 + 2;
        result -= (25 * num_align - 10) * num_align - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

/// 総コードワード数（データ + 誤り訂正）。
pub fn rawCodewords(version: u8) usize {
    return numRawDataModules(version) / 8;
}

/// データコードワード数（誤り訂正を除く）。
pub fn dataCodewords(ec: EcLevel, version: u8) usize {
    const i = ec.index();
    return rawCodewords(version) - @as(usize, ecc_codewords_per_block[i][version]) * num_ec_blocks[i][version];
}

/// ビット数を格納するのに必要なデータコードワード数を超えない、最大のデータビット数。
pub fn capacityBits(ec: EcLevel, version: u8) usize {
    return dataCodewords(ec, version) * 8;
}

/// 指定モードで `len` 文字を格納するのに必要なデータビット数（モード・文字数指示子を含む）。
pub fn requiredBits(mode: Mode, len: usize, version: u8) usize {
    return 4 + mode.charCountBits(version) + dataBitLength(mode, len);
}

/// 入力長と EC レベルから最小バージョンを選ぶ。
fn selectVersion(mode: Mode, len: usize, ec: EcLevel) Error!u8 {
    var version: u8 = min_version;
    while (version <= max_version) : (version += 1) {
        const count_bits = mode.charCountBits(version);
        // 文字数指示子に収まらない場合は、より広い指示子のバージョンまで飛ばす。
        if (len >= (@as(usize, 1) << @intCast(count_bits))) continue;
        if (requiredBits(mode, len, version) <= capacityBits(ec, version)) return version;
    }
    return Error.DataTooLong;
}

/// モードごとのデータビット数（モード指示子と文字数指示子を除く）。
fn dataBitLength(mode: Mode, len: usize) usize {
    return switch (mode) {
        .numeric => 10 * (len / 3) + switch (len % 3) {
            0 => @as(usize, 0),
            1 => @as(usize, 4),
            else => @as(usize, 7),
        },
        .alphanumeric => 11 * (len / 2) + 6 * (len % 2),
        .byte => 8 * len,
    };
}

// ---------------------------------------------------------------- モード判定

/// すべて ASCII 数字か（空列は true）。
fn isNumeric(text: []const u8) bool {
    for (text) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// すべて規格 Table 5 の英数字 45 文字か（空列は true）。
fn isAlphanumeric(text: []const u8) bool {
    for (text) |c| {
        if (alphanumericValue(c) == null) return false;
    }
    return true;
}

/// 英数字モードの値（規格 Table 5）。0〜44。
fn alphanumericValue(c: u8) ?u6 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'Z' => @intCast(c - 'A' + 10),
        ' ' => 36,
        '$' => 37,
        '%' => 38,
        '*' => 39,
        '+' => 40,
        '-' => 41,
        '.' => 42,
        '/' => 43,
        ':' => 44,
        else => null,
    };
}

// ---------------------------------------------------------------- ビット列

/// ビット列を書き込む。`buf` は 0 で初期化されていること。
fn appendBits(buf: []u8, bit_len: *usize, value: u32, count: usize) void {
    var i: usize = count;
    while (i > 0) {
        i -= 1;
        const bit = (value >> @intCast(i)) & 1;
        if (bit != 0) {
            buf[bit_len.* >> 3] |= @as(u8, 1) << @intCast(7 - (bit_len.* & 7));
        }
        bit_len.* += 1;
    }
}

/// モード指示子・文字数指示子・データ本体を書く。
fn writeData(buf: []u8, bit_len: *usize, mode: Mode, text: []const u8, version: u8) void {
    appendBits(buf, bit_len, mode.indicator(), 4);
    appendBits(buf, bit_len, @intCast(text.len), mode.charCountBits(version));

    switch (mode) {
        .numeric => {
            var i: usize = 0;
            while (i + 3 <= text.len) : (i += 3) {
                const v: u32 = @as(u32, text[i] - '0') * 100 +
                    @as(u32, text[i + 1] - '0') * 10 +
                    @as(u32, text[i + 2] - '0');
                appendBits(buf, bit_len, v, 10);
            }
            const rest = text.len - i;
            if (rest == 1) {
                appendBits(buf, bit_len, @as(u32, text[i] - '0'), 4);
            } else if (rest == 2) {
                appendBits(buf, bit_len, @as(u32, text[i] - '0') * 10 + @as(u32, text[i + 1] - '0'), 7);
            }
        },
        .alphanumeric => {
            var i: usize = 0;
            while (i + 2 <= text.len) : (i += 2) {
                const a = alphanumericValue(text[i]).?;
                const b = alphanumericValue(text[i + 1]).?;
                appendBits(buf, bit_len, @as(u32, a) * 45 + @as(u32, b), 11);
            }
            if (i < text.len) {
                appendBits(buf, bit_len, alphanumericValue(text[i]).?, 6);
            }
        },
        .byte => {
            for (text) |c| appendBits(buf, bit_len, c, 8);
        },
    }
}

/// ターミネータ・境界までの 0 詰め・パッドコードワード（規格 7.4.9 / 7.4.10）。
fn writePadding(buf: []u8, bit_len: *usize, capacity: usize) void {
    // ターミネータ（最大 4 ビット。残り容量が 4 未満ならそこで打ち切る）。
    const terminator = @min(@as(usize, 4), capacity - bit_len.*);
    appendBits(buf, bit_len, 0, terminator);

    // コードワード境界まで 0 で埋める。**既に境界なら何もしない**（規格 7.4.10）。
    // ここで 8 ビット追加してしまうのが segno 1.6.6 のバグ（heuer/segno#123）。
    if (bit_len.* % 8 != 0) {
        appendBits(buf, bit_len, 0, 8 - (bit_len.* % 8));
    }

    // 残りはパッドコードワード 11101100 / 00010001 を交互に。
    var pad: u8 = 0xEC;
    while (bit_len.* + 8 <= capacity) {
        appendBits(buf, bit_len, pad, 8);
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }
}

// ---------------------------------------------------------------- 誤り訂正

/// GF(2^8)（原始多項式 0x11D）の演算。QR の誤り訂正はこの体のうえで行う。
const Gf = struct {
    const exp: [512]u8 = blk: {
        var table: [512]u8 = undefined;
        var x: u16 = 1;
        var i: usize = 0;
        while (i < 255) : (i += 1) {
            table[i] = @intCast(x);
            x <<= 1;
            if (x & 0x100 != 0) x ^= 0x11D;
        }
        i = 255;
        while (i < 512) : (i += 1) table[i] = table[i - 255];
        break :blk table;
    };

    const log: [256]u8 = blk: {
        var table: [256]u8 = @splat(0);
        for (0..255) |i| table[exp[i]] = @intCast(i);
        break :blk table;
    };

    fn multiply(a: u8, b: u8) u8 {
        if (a == 0 or b == 0) return 0;
        return exp[@as(usize, log[a]) + @as(usize, log[b])];
    }
};

/// 次数 `degree` の生成多項式 (x - α^0)(x - α^1)... の係数（先頭の 1 を除く）。
fn rsDivisor(degree: usize, out: []u8) void {
    std.debug.assert(out.len == degree);
    @memset(out, 0);
    out[degree - 1] = 1;
    var root: u8 = 1;
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = 0;
        while (j < degree) : (j += 1) {
            out[j] = Gf.multiply(out[j], root);
            if (j + 1 < degree) out[j] ^= out[j + 1];
        }
        root = Gf.multiply(root, 0x02);
    }
}

/// データ `data` を生成多項式で割った剰余（= 誤り訂正コードワード）を `out` に書く。
fn rsRemainder(data: []const u8, divisor: []const u8, out: []u8) void {
    std.debug.assert(out.len == divisor.len);
    @memset(out, 0);
    for (data) |b| {
        const factor = b ^ out[0];
        var i: usize = 0;
        while (i + 1 < out.len) : (i += 1) out[i] = out[i + 1];
        out[out.len - 1] = 0;
        i = 0;
        while (i < out.len) : (i += 1) out[i] ^= Gf.multiply(divisor[i], factor);
    }
}

/// データコードワードをブロックに分け、誤り訂正を付け、規格 7.6 の順にインターリーブする。
fn buildMessage(
    allocator: std.mem.Allocator,
    data: []const u8,
    message: []u8,
    ec: EcLevel,
    version: u8,
) Error!void {
    const i = ec.index();
    const blocks: usize = num_ec_blocks[i][version];
    const ecc_len: usize = ecc_codewords_per_block[i][version];
    const raw_len = message.len;
    const short_len = raw_len / blocks; // 短いブロックの「データ + EC」長
    const num_short = blocks - raw_len % blocks;

    const ecc_all = try allocator.alloc(u8, blocks * ecc_len);
    defer allocator.free(ecc_all);

    var divisor_buf: [30]u8 = undefined;
    const divisor = divisor_buf[0..ecc_len];
    rsDivisor(ecc_len, divisor);

    // ブロックごとのデータ長は、長いブロックが short_len - ecc_len + 1。
    var offset: usize = 0;
    var b: usize = 0;
    while (b < blocks) : (b += 1) {
        const data_len = short_len - ecc_len + @as(usize, if (b < num_short) 0 else 1);
        rsRemainder(data[offset .. offset + data_len], divisor, ecc_all[b * ecc_len ..][0..ecc_len]);
        offset += data_len;
    }

    // データコードワードのインターリーブ（短いブロックは最後の 1 バイトを飛ばす）。
    var out: usize = 0;
    var k: usize = 0;
    const max_data_len = short_len - ecc_len + 1;
    while (k < max_data_len) : (k += 1) {
        offset = 0;
        b = 0;
        while (b < blocks) : (b += 1) {
            const data_len = short_len - ecc_len + @as(usize, if (b < num_short) 0 else 1);
            if (k < data_len) {
                message[out] = data[offset + k];
                out += 1;
            }
            offset += data_len;
        }
    }

    // 誤り訂正コードワードのインターリーブ。
    k = 0;
    while (k < ecc_len) : (k += 1) {
        b = 0;
        while (b < blocks) : (b += 1) {
            message[out] = ecc_all[b * ecc_len + k];
            out += 1;
        }
    }
    std.debug.assert(out == raw_len);
}

// ---------------------------------------------------------------- ビット操作

fn getBit(buf: []const u8, index: usize) bool {
    return (buf[index >> 3] >> @intCast(7 - (index & 7))) & 1 != 0;
}

fn setBit(buf: []u8, index: usize, dark: bool) void {
    const mask: u8 = @as(u8, 1) << @intCast(7 - (index & 7));
    if (dark) {
        buf[index >> 3] |= mask;
    } else {
        buf[index >> 3] &= ~mask;
    }
}

// ---------------------------------------------------------------- 行列の組み立て

/// 行列の組み立て中に使う作業構造体。`modules` は 1 モジュール 1 バイト、
/// `func` は機能モジュール（マスク対象外）を 1 モジュール 1 ビットで持つ。
const Builder = struct {
    size: usize,
    modules: []u8,
    func: []u8,
    mask: u3 = 0,

    fn isFunc(self: *const Builder, x: usize, y: usize) bool {
        return getBit(self.func, y * self.size + x);
    }

    fn setFunc(self: *const Builder, x: usize, y: usize, dark: bool) void {
        setBit(self.func, y * self.size + x, true);
        self.modules[y * self.size + x] = @intFromBool(dark);
    }

    fn setData(self: *const Builder, x: usize, y: usize, dark: bool) void {
        self.modules[y * self.size + x] = @intFromBool(dark);
    }

    /// モジュールの明暗を反転する（マスク用）。
    /// `modules` は 1 モジュール 1 バイトなので、ビット演算ではなく値そのものを入れ替える。
    fn toggleModule(self: *const Builder, x: usize, y: usize) void {
        const i = y * self.size + x;
        self.modules[i] = if (self.modules[i] != 0) 0 else 1;
    }
};

/// 行列を組み立て、マスクを選んで適用し、format/version 情報を書き込む。
fn buildMatrix(b: *Builder, message: []const u8, ec: EcLevel, version: u8, opts: Options) void {
    drawFinderPatterns(b);
    drawTimingPatterns(b);
    drawAlignmentPatterns(b, version);
    reserveFormatInfo(b);
    if (version >= 7) reserveVersionInfo(b);
    placeData(b, message);

    // 最終形のシンボルを評価する規約では、version 情報（マスク非依存）を先に書く。
    if (version >= 7 and opts.mask_eval == .final_symbol) drawVersionInfo(b, version);

    b.mask = chooseMask(b, ec, opts);
    applyMask(b, b.mask);
    if (version >= 7) drawVersionInfo(b, version);
    drawFormatInfo(b, ec, b.mask);
}

/// 8 種類のマスクを試し、ペナルティが最小のものを返す（この時点では適用しない）。
fn chooseMask(b: *Builder, ec: EcLevel, opts: Options) u3 {
    if (opts.mask) |forced| return forced;

    var best: u3 = 0;
    var best_score: u32 = std.math.maxInt(u32);
    var candidate: u3 = 0;
    while (true) : (candidate += 1) {
        applyMask(b, candidate);
        if (opts.mask_eval == .final_symbol) drawFormatInfo(b, ec, candidate);
        const score = penaltyScore(b.size, b.modules);
        if (score < best_score) {
            best_score = score;
            best = candidate;
        }
        applyMask(b, candidate); // XOR なのでもう一度適用すると元に戻る
        if (candidate == mask_count - 1) break;
    }
    return best;
}

/// 規格 Table 10 のマスク条件（x = 列 = j、y = 行 = i）。真ならモジュールを反転する。
fn maskCondition(mask: u3, x: usize, y: usize) bool {
    return switch (mask) {
        0 => (x + y) % 2 == 0,
        1 => y % 2 == 0,
        2 => x % 3 == 0,
        3 => (x + y) % 3 == 0,
        4 => (y / 2 + x / 3) % 2 == 0,
        5 => (x * y) % 2 + (x * y) % 3 == 0,
        6 => ((x * y) % 2 + (x * y) % 3) % 2 == 0,
        7 => ((x + y) % 2 + (x * y) % 3) % 2 == 0,
    };
}

/// 符号化領域（機能モジュール以外）にマスクを XOR する。2 回呼ぶと元に戻る。
fn applyMask(b: *Builder, mask: u3) void {
    var y: usize = 0;
    while (y < b.size) : (y += 1) {
        var x: usize = 0;
        while (x < b.size) : (x += 1) {
            if (b.isFunc(x, y)) continue;
            if (maskCondition(mask, x, y)) b.toggleModule(x, y);
        }
    }
}

/// 3 隅の位置検出パターン（セパレータ含む 8×8 領域）。
fn drawFinderPatterns(b: *Builder) void {
    const size = b.size;
    const corners = [3][2]usize{
        .{ 0, 0 },
        .{ size - 7, 0 },
        .{ 0, size - 7 },
    };
    for (corners) |corner| {
        const cx = corner[0];
        const cy = corner[1];
        var dy: isize = -1;
        while (dy <= 7) : (dy += 1) {
            var dx: isize = -1;
            while (dx <= 7) : (dx += 1) {
                const x = @as(isize, @intCast(cx)) + dx;
                const y = @as(isize, @intCast(cy)) + dy;
                if (x < 0 or y < 0 or x >= @as(isize, @intCast(size)) or y >= @as(isize, @intCast(size))) continue;
                const inner = dx >= 0 and dx <= 6 and dy >= 0 and dy <= 6;
                const dark = inner and (dx == 0 or dx == 6 or dy == 0 or dy == 6 or
                    (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4));
                b.setFunc(@intCast(x), @intCast(y), dark);
            }
        }
    }
}

/// タイミングパターン（6 行目と 6 列目、偶数番目が暗）。
fn drawTimingPatterns(b: *Builder) void {
    var i: usize = 0;
    while (i < b.size) : (i += 1) {
        if (!b.isFunc(i, 6)) b.setFunc(i, 6, i % 2 == 0);
        if (!b.isFunc(6, i)) b.setFunc(6, i, i % 2 == 0);
    }
}

/// 位置合わせパターン（規格 Annex E の位置。バージョン 1 には無い）。
fn drawAlignmentPatterns(b: *Builder, version: u8) void {
    if (version == 1) return;
    var positions: [7]usize = undefined;
    const count = alignmentPositions(version, &positions);
    const size = b.size;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        var j: usize = 0;
        while (j < count) : (j += 1) {
            const cx = positions[j];
            const cy = positions[i];
            // 位置検出パターンと重なる 3 箇所には置かない。
            const near_finder = (cx == 6 and cy == 6) or
                (cx == 6 and cy == size - 7) or
                (cx == size - 7 and cy == 6);
            if (near_finder) continue;

            var dy: isize = -2;
            while (dy <= 2) : (dy += 1) {
                var dx: isize = -2;
                while (dx <= 2) : (dx += 1) {
                    const x = @as(isize, @intCast(cx)) + dx;
                    const y = @as(isize, @intCast(cy)) + dy;
                    const dark = dx == -2 or dx == 2 or dy == -2 or dy == 2 or (dx == 0 and dy == 0);
                    b.setFunc(@intCast(x), @intCast(y), dark);
                }
            }
        }
    }
}

/// 位置合わせパターンの中心座標（規格 Annex E）。昇順で `out` に書き、個数を返す。
fn alignmentPositions(version: u8, out: *[7]usize) usize {
    if (version == 1) return 0;
    const v: usize = version;
    const size = versionSize(version);
    const num_align: usize = v / 7 + 2;
    const step: usize = if (version == 32)
        26
    else
        (v * 4 + num_align * 2 + 1) / (num_align * 2 - 2) * 2;

    // 6 と、size-7 から step ずつ減らした値。最後に昇順へ直す。
    var buffer: [7]usize = undefined;
    buffer[0] = 6;
    var pos = size - 7;
    var n: usize = num_align;
    while (n > 1) {
        n -= 1;
        buffer[n] = pos;
        if (n > 1) pos -= step;
    }
    for (0..num_align) |i| out[i] = buffer[i];
    return num_align;
}

/// format 情報の領域を機能モジュールとして予約する（値は明。あとで書き込む）。
fn reserveFormatInfo(b: *Builder) void {
    const size = b.size;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        if (i != 6) b.setFunc(8, i, false);
        if (i != 6) b.setFunc(i, 8, false);
    }
    i = 0;
    while (i < 8) : (i += 1) b.setFunc(size - 1 - i, 8, false);
    i = 0;
    while (i < 7) : (i += 1) b.setFunc(8, size - 1 - i, false);
    b.setFunc(8, size - 8, false); // dark モジュール（あとで必ず暗にする）
}

/// version 情報の領域（バージョン 7 以上）を機能モジュールとして予約する。
fn reserveVersionInfo(b: *Builder) void {
    const size = b.size;
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const a = size - 11 + i % 3;
        const c = i / 3;
        b.setFunc(a, c, false);
        b.setFunc(c, a, false);
    }
}

/// データコードワードを規格 7.7 の順（右下から 2 列ずつ蛇行）に配置する。
fn placeData(b: *Builder, message: []const u8) void {
    const size = b.size;
    const total_bits = message.len * 8;
    var bit: usize = 0;

    var right: usize = size - 1;
    while (true) {
        if (right == 6) right = 5; // タイミング列を飛ばす
        var vert: usize = 0;
        while (vert < size) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x = right - j;
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) size - 1 - vert else vert;
                if (b.isFunc(x, y)) continue;
                var dark = false;
                if (bit < total_bits) dark = getBit(message, bit);
                b.setData(x, y, dark);
                bit += 1;
            }
        }
        if (right < 2) break;
        right -= 2;
    }
}

/// format 情報（15 ビット、規格 7.9）と dark モジュールを書き込む。
fn drawFormatInfo(b: *Builder, ec: EcLevel, mask: u3) void {
    const size = b.size;
    const bits = formatBits(ec, mask);

    var i: usize = 0;
    while (i < 6) : (i += 1) b.setFunc(8, i, getBit15(bits, i));
    b.setFunc(8, 7, getBit15(bits, 6));
    b.setFunc(8, 8, getBit15(bits, 7));
    b.setFunc(7, 8, getBit15(bits, 8));
    i = 9;
    while (i < 15) : (i += 1) b.setFunc(14 - i, 8, getBit15(bits, i));

    i = 0;
    while (i < 8) : (i += 1) b.setFunc(size - 1 - i, 8, getBit15(bits, i));
    i = 8;
    while (i < 15) : (i += 1) b.setFunc(8, size - 15 + i, getBit15(bits, i));

    // 規格 6.9.1: (4V+9, 8) のモジュールは常に暗。
    b.setFunc(8, size - 8, true);
}

/// version 情報（18 ビット、規格 7.10）。バージョン 7 未満では何もしない。
fn drawVersionInfo(b: *Builder, version: u8) void {
    if (version < 7) return;
    const size = b.size;
    const bits = versionBits(version);
    var i: usize = 0;
    while (i < 18) : (i += 1) {
        const a = size - 11 + i % 3;
        const c = i / 3;
        b.setFunc(a, c, getBit18(bits, i));
        b.setFunc(c, a, getBit18(bits, i));
    }
}

/// format 情報のビット列（5 データビット + 10 BCH ビット、0x5412 で XOR）。
fn formatBits(ec: EcLevel, mask: u3) u15 {
    const data: u32 = (@as(u32, ec.formatBits()) << 3) | @as(u32, mask);
    var rem: u32 = data;
    for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    return @intCast(((data << 10) | rem) ^ 0x5412);
}

/// version 情報のビット列（6 データビット + 12 Golay ビット）。
fn versionBits(version: u8) u18 {
    const data: u32 = version;
    var rem: u32 = data;
    for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    return @intCast((data << 12) | rem);
}

fn getBit15(bits: u15, index: usize) bool {
    return (bits >> @intCast(index)) & 1 != 0;
}

fn getBit18(bits: u18, index: usize) bool {
    return (bits >> @intCast(index)) & 1 != 0;
}

// ---------------------------------------------------------------- ペナルティ

/// 規格 Table 11 の 4 つのペナルティの合計。
fn penaltyScore(size: usize, modules: []const u8) u32 {
    return penaltyRuns(size, modules) + penaltyBlocks(size, modules) +
        penaltyFinderLike(size, modules) + penaltyBalance(size, modules);
}

/// N1: 同色が 5 モジュール以上連続する行・列（5 で 3 点、1 個増えるごとに +1）。
fn penaltyRuns(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;

    var y: usize = 0;
    while (y < size) : (y += 1) {
        var run: usize = 1;
        var x: usize = 1;
        while (x < size) : (x += 1) {
            if (modules[y * size + x] == modules[y * size + x - 1]) {
                run += 1;
            } else {
                if (run >= 5) score += @intCast(run - 2);
                run = 1;
            }
        }
        if (run >= 5) score += @intCast(run - 2);
    }

    var x: usize = 0;
    while (x < size) : (x += 1) {
        var run: usize = 1;
        var yy: usize = 1;
        while (yy < size) : (yy += 1) {
            if (modules[yy * size + x] == modules[(yy - 1) * size + x]) {
                run += 1;
            } else {
                if (run >= 5) score += @intCast(run - 2);
                run = 1;
            }
        }
        if (run >= 5) score += @intCast(run - 2);
    }

    return score;
}

/// N2: 同色 2×2 のブロック（1 箇所 3 点。重なりも数える）。
fn penaltyBlocks(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;
    var y: usize = 0;
    while (y + 1 < size) : (y += 1) {
        var x: usize = 0;
        while (x + 1 < size) : (x += 1) {
            const c = modules[y * size + x];
            if (c == modules[y * size + x + 1] and
                c == modules[(y + 1) * size + x] and
                c == modules[(y + 1) * size + x + 1])
            {
                score += 3;
            }
        }
    }
    return score;
}

/// N3: 1:1:3:1:1（1011101）の前後いずれかに 4 モジュールの明領域（1 箇所 40 点）。
/// シンボル外はクワイエットゾーンなので明として扱う。
///
/// 走査は segno 1.6.6 と同じ「数えたら 7 進む / 条件を満たさなければ 4 進む」。
/// 1011101 は 4 モジュール以上ずらすと重なって現れうる（例: 1011101 1101 の 0 と 4）が、
/// 同じ 1:1:3:1:1 の領域を二重に数えないため、数えた出現の先へ読み進める。
fn penaltyFinderLike(size: usize, modules: []const u8) u32 {
    var score: u32 = 0;
    var line: usize = 0;
    while (line < size) : (line += 1) {
        score += penaltyFinderLikeLine(size, modules, line, true);
        score += penaltyFinderLikeLine(size, modules, line, false);
    }
    return score;
}

fn moduleAt(size: usize, modules: []const u8, line: usize, index: usize, comptime row: bool) bool {
    const v = if (row) modules[line * size + index] else modules[index * size + line];
    return v != 0;
}

fn penaltyFinderLikeLine(size: usize, modules: []const u8, line: usize, comptime row: bool) u32 {
    if (size < 7) return 0;
    const pattern = [7]bool{ true, false, true, true, true, false, true };
    var score: u32 = 0;

    var i: usize = 0;
    while (i + 7 <= size) {
        var matches = true;
        for (pattern, 0..) |want, k| {
            if (moduleAt(size, modules, line, i + k, row) != want) {
                matches = false;
                break;
            }
        }
        if (!matches) {
            i += 1;
            continue;
        }

        if (lightBefore(size, modules, line, i, row) or lightAfter(size, modules, line, i + 7, row)) {
            score += 40;
            i += 7;
        } else {
            i += 4;
        }
    }
    return score;
}

/// `index` の直前 4 モジュール（存在する範囲だけ）がすべて明か。
fn lightBefore(size: usize, modules: []const u8, line: usize, index: usize, comptime row: bool) bool {
    const start = if (index >= 4) index - 4 else 0;
    var j = start;
    while (j < index) : (j += 1) {
        if (moduleAt(size, modules, line, j, row)) return false;
    }
    return true;
}

/// `from` から 4 モジュール（存在する範囲だけ）がすべて明か。
fn lightAfter(size: usize, modules: []const u8, line: usize, from: usize, comptime row: bool) bool {
    const end = @min(from + 4, size);
    var j = from;
    while (j < end) : (j += 1) {
        if (moduleAt(size, modules, line, j, row)) return false;
    }
    return true;
}

/// N4: 暗モジュール比率の 50% からのずれ（5% ごとに 10 点）。
/// `k = |暗% - 50%| / 5%` の整数除算（切り捨て）。
fn penaltyBalance(size: usize, modules: []const u8) u32 {
    const total = size * size;
    var dark: usize = 0;
    for (modules) |m| {
        if (m != 0) dark += 1;
    }
    const scaled_dark = dark * 100;
    const scaled_half = total * 50;
    const diff = if (scaled_dark > scaled_half) scaled_dark - scaled_half else scaled_half - scaled_dark;
    const k = diff / (5 * total);
    return @intCast(k * 10);
}

// ---------------------------------------------------------------- テスト
//
// 期待値の出典は各テストに明記する。すべて第三者（規格そのもの、または独立実装）から
// 取得した値で、本実装の出力をそのまま期待値にはしていない。

const testing = std.testing;

test "検出モード: 数字・英数字・バイトを入力から選ぶ" {
    try testing.expectEqual(Mode.numeric, detectMode("0123456789"));
    try testing.expectEqual(Mode.alphanumeric, detectMode("HELLO WORLD $%*+-./:"));
    try testing.expectEqual(Mode.alphanumeric, detectMode("UR:BYTES/ABCDEFG"));
    // UTF-8 の日本語はバイトモード
    try testing.expectEqual(Mode.byte, detectMode("日本語"));
    try testing.expectEqual(Mode.byte, detectMode("hello"));
    // 空入力は数字モード（最小）
    try testing.expectEqual(Mode.numeric, detectMode(""));
}

test "英数字モードの値は規格 Table 5 の 45 文字" {
    try testing.expectEqual(@as(?u6, 0), alphanumericValue('0'));
    try testing.expectEqual(@as(?u6, 9), alphanumericValue('9'));
    try testing.expectEqual(@as(?u6, 10), alphanumericValue('A'));
    try testing.expectEqual(@as(?u6, 35), alphanumericValue('Z'));
    try testing.expectEqual(@as(?u6, 36), alphanumericValue(' '));
    try testing.expectEqual(@as(?u6, 44), alphanumericValue(':'));
    try testing.expectEqual(@as(?u6, null), alphanumericValue('a'));
    try testing.expectEqual(@as(?u6, null), alphanumericValue('_'));
}

test "文字数指示子のビット数は規格 Table 3" {
    try testing.expectEqual(@as(usize, 10), Mode.numeric.charCountBits(1));
    try testing.expectEqual(@as(usize, 12), Mode.numeric.charCountBits(10));
    try testing.expectEqual(@as(usize, 14), Mode.numeric.charCountBits(27));
    try testing.expectEqual(@as(usize, 9), Mode.alphanumeric.charCountBits(9));
    try testing.expectEqual(@as(usize, 11), Mode.alphanumeric.charCountBits(26));
    try testing.expectEqual(@as(usize, 13), Mode.alphanumeric.charCountBits(27));
    try testing.expectEqual(@as(usize, 8), Mode.byte.charCountBits(9));
    try testing.expectEqual(@as(usize, 16), Mode.byte.charCountBits(10));
    try testing.expectEqual(@as(usize, 16), Mode.byte.charCountBits(40));
}

test "総コードワード数とデータコードワード数" {
    // 規格 Table 1 / Table 9 の値（第三者: segno 1.6.6 の consts.ECC と
    // qrcodegen 1.8.0 の _ECC_CODEWORDS_PER_BLOCK / _NUM_ERROR_CORRECTION_BLOCKS が
    // 全 40 バージョン × 4 レベルで一致することを確認済み）
    try testing.expectEqual(@as(usize, 26), rawCodewords(1));
    try testing.expectEqual(@as(usize, 44), rawCodewords(2));
    try testing.expectEqual(@as(usize, 3706), rawCodewords(40));

    try testing.expectEqual(@as(usize, 19), dataCodewords(.l, 1));
    try testing.expectEqual(@as(usize, 16), dataCodewords(.m, 1));
    try testing.expectEqual(@as(usize, 13), dataCodewords(.q, 1));
    try testing.expectEqual(@as(usize, 9), dataCodewords(.h, 1));
    try testing.expectEqual(@as(usize, 2956), dataCodewords(.l, 40));
    try testing.expectEqual(@as(usize, 2334), dataCodewords(.m, 40));
    try testing.expectEqual(@as(usize, 1666), dataCodewords(.q, 40));
    try testing.expectEqual(@as(usize, 1276), dataCodewords(.h, 40));
}

test "バージョン自動選択の境界（規格 Table 7 の容量）" {
    // 第三者: segno 1.6.6 / qrcodegen 1.8.0 / python-qrcode 8.2 が一致する境界。
    // バージョン 1 のバイトモード容量は L=17, M=14, Q=11, H=7 バイト。
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 17, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 18, .l));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 14, .m));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 15, .m));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 11, .q));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 12, .q));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.byte, 7, .h));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.byte, 8, .h));
    // 英数字モードのバージョン 1 容量は L=25, M=20, Q=16, H=10 文字。
    try testing.expectEqual(@as(u8, 1), try selectVersion(.alphanumeric, 25, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.alphanumeric, 26, .l));
    try testing.expectEqual(@as(u8, 1), try selectVersion(.alphanumeric, 20, .m));
    // 数字モードのバージョン 1 容量は L=41, M=34, Q=27, H=17 桁。
    try testing.expectEqual(@as(u8, 1), try selectVersion(.numeric, 41, .l));
    try testing.expectEqual(@as(u8, 2), try selectVersion(.numeric, 42, .l));
    // バージョン 40-L のバイトモード容量は 2953 バイト。
    try testing.expectEqual(@as(u8, 40), try selectVersion(.byte, 2953, .l));
    try testing.expectError(Error.DataTooLong, selectVersion(.byte, 2954, .l));
}

test "Reed-Solomon: 規格 Annex I.2 の誤り訂正コードワード" {
    // ISO/IEC 18004:2006(E) Annex I.2（"01234567" をバージョン 1-M で符号化）。
    // データコードワード 16 個（パッドコードワード含む）と、生成される EC 10 個。
    const data = [16]u8{
        0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11,
        0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
    };
    const expected = [10]u8{
        0xA5, 0x24, 0xD4, 0xC1, 0xED, 0x36, 0xC7, 0x87, 0x2C, 0x55,
    };
    var divisor: [10]u8 = undefined;
    var out: [10]u8 = undefined;
    rsDivisor(10, &divisor);
    rsRemainder(&data, &divisor, &out);
    try testing.expectEqualSlices(u8, &expected, &out);
}

test "データ符号化: 規格 Annex I.2 のデータコードワード列" {
    // ISO/IEC 18004:2006(E) Annex I.2: "01234567" をバージョン 1-M で符号化すると
    // 16 個のデータコードワード（6 個 + パッド 10 個）になる。
    // 8 ビットへの区切りで「必要なときだけ」パディングビットを足すことも、この例が根拠。
    var buf: [16]u8 = @splat(0);
    var bit_len: usize = 0;
    writeData(&buf, &bit_len, .numeric, "01234567", 1);
    writePadding(&buf, &bit_len, 16 * 8);
    const expected = [16]u8{
        0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11,
        0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11,
    };
    try testing.expectEqualSlices(u8, &expected, &buf);
}

test "format 情報: 規格 Table C.1 の 32 通り" {
    // ISO/IEC 18004:2006(E) Table C.1「Valid format information bit sequences」の
    // 「Sequence after masking (QR Code symbols)」列（16 進）。
    // 添字は 5 データビットの値（上位 2 ビットが EC レベル、下位 3 ビットがマスク）。
    const table = [32]u16{
        0x5412, 0x5125, 0x5E7C, 0x5B4B, 0x45F9, 0x40CE, 0x4F97, 0x4AA0,
        0x77C4, 0x72F3, 0x7DAA, 0x789D, 0x662F, 0x6318, 0x6C41, 0x6976,
        0x1689, 0x13BE, 0x1CE7, 0x19D0, 0x0762, 0x0255, 0x0D0C, 0x083B,
        0x355F, 0x3068, 0x3F31, 0x3A06, 0x24B4, 0x2183, 0x2EDA, 0x2BED,
    };
    const levels = [4]EcLevel{ .m, .l, .h, .q }; // データビット上位 2 ビットの順（00, 01, 10, 11）
    for (levels, 0..) |ec, ec_bits| {
        var mask: u3 = 0;
        while (true) : (mask += 1) {
            const data = ec_bits * 8 + @as(usize, mask);
            try testing.expectEqual(table[data], formatBits(ec, mask));
            if (mask == 7) break;
        }
    }
}

test "version 情報: 規格 Table D.1 の全 34 バージョン" {
    // ISO/IEC 18004:2006(E) Table D.1「Version information bit stream for each version」。
    const table = [41]u32{
        0,       0,       0,       0,       0,       0,       0,
        0x07C94, 0x085BC, 0x09A99, 0x0A4D3, 0x0BBF6, 0x0C762, 0x0D847,
        0x0E60D, 0x0F928, 0x10B78, 0x1145D, 0x12A17, 0x13532, 0x149A6,
        0x15683, 0x168C9, 0x177EC, 0x18EC4, 0x191E1, 0x1AFAB, 0x1B08E,
        0x1CC1A, 0x1D33F, 0x1ED75, 0x1F250, 0x209D5, 0x216F0, 0x228BA,
        0x2379F, 0x24B0B, 0x2542E, 0x26A64, 0x27541, 0x28C69,
    };
    var version: u8 = 7;
    while (version <= 40) : (version += 1) {
        try testing.expectEqual(table[version], versionBits(version));
    }
}

test "エラー: 容量超過とバージョン範囲外" {
    const allocator = testing.allocator;
    // 0x80 は英数字でも数字でもないのでバイトモード。バージョン 40-L の 2953 バイトを超える。
    var too_long: [2954]u8 = @splat(0x80);
    try testing.expectError(Error.DataTooLong, encode(allocator, &too_long, .l));
    try testing.expectError(Error.InvalidVersion, encodeVersion(allocator, "A", .m, 0));
    try testing.expectError(Error.InvalidVersion, encodeVersion(allocator, "A", .m, 41));
    // 指定バージョンに収まらない場合
    try testing.expectError(Error.DataTooLong, encodeVersion(allocator, "0123456789ABCDEF", .h, 1));
    // モードを明示指定した場合、そのモードで表せない文字は拒否する
    // （英数字モードに小文字、数字モードに数字以外）
    try testing.expectError(Error.InvalidCharacter, encodeOptions(allocator, "ur:bytes/abc", .m, .{ .mode = .alphanumeric }));
    try testing.expectError(Error.InvalidCharacter, encodeOptions(allocator, "12a", .m, .{ .mode = .numeric }));
    // 同じ入力でもバイトモードなら通る
    var as_bytes = try encodeOptions(allocator, "ur:bytes/abc", .m, .{ .mode = .byte });
    defer as_bytes.deinit(allocator);
    try testing.expectEqual(as_bytes.size * as_bytes.size, as_bytes.modules.len);

    // バイトモードを明示した場合も同じ境界（2953 は入り、2954 は入らない）
    var max_byte: [2953]u8 = @splat(0x80);
    var m = try encodeOptions(allocator, &max_byte, .l, .{ .mode = .byte });
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 40), m.version);
}

test "描画: 余白・拡大倍率・クリップ" {
    const allocator = testing.allocator;
    var m = try encodeOptions(allocator, "HELLO", .m, .{ .version = 1, .mask = 0 });
    defer m.deinit(allocator);

    // 21 モジュール + 余白 4 × 2 = 29 モジュール。倍率 1 なら 29×29 ピクセル。
    try testing.expectEqual(@as(usize, 29), pixelSize(&m, .{ .scale = 1, .quiet_zone = 4 }));
    try testing.expectEqual(@as(usize, 58), pixelSize(&m, .{ .scale = 2, .quiet_zone = 4 }));
    try testing.expect(fitsIn(&m, 240, 240, .{ .scale = 2, .quiet_zone = 4 }));
    try testing.expect(!fitsIn(&m, 240, 240, .{ .scale = 2, .quiet_zone = 4, .origin_x = 200 }));

    // 29×29 の枠にちょうど収める。余白は明、位置検出パターンの角は暗、セパレータは明。
    var buffer: [31 * 31]u16 = @splat(0x1234);
    drawRgb565(&m, &buffer, 31, 31, .{ .scale = 1, .quiet_zone = 4, .dark = 0x0000, .light = 0xFFFF });
    try testing.expectEqual(@as(u16, 0xFFFF), buffer[0]);
    try testing.expectEqual(@as(u16, 0x0000), buffer[4 * 31 + 4]);
    try testing.expectEqual(@as(u16, 0xFFFF), buffer[(4 + 7) * 31 + (4 + 7)]);
    // 29 モジュールぶんを描いたので、30 列目・30 行目（枠の外）は触らない。
    try testing.expectEqual(@as(u16, 0x1234), buffer[30]);
    try testing.expectEqual(@as(u16, 0x1234), buffer[30 * 31 + 0]);
    // 原点をずらすと、その位置から描く。
    var offset: [31 * 31]u16 = @splat(0x1234);
    drawRgb565(&m, &offset, 31, 31, .{ .scale = 1, .quiet_zone = 4, .origin_x = 2, .origin_y = 1 });
    try testing.expectEqual(@as(u16, 0x1234), offset[0]);
    try testing.expectEqual(@as(u16, 0xFFFF), offset[1 * 31 + 2]);

    // 負の原点でもクリップして描ける（例外を出さない）。
    var small: [4]u16 = @splat(0x1234);
    drawRgb565(&m, &small, 2, 2, .{ .scale = 4, .quiet_zone = 0, .origin_x = -8, .origin_y = -8 });
    try testing.expectEqual(@as(u16, 0x0000), small[0]);

    // buffer がフレームバッファより小さい場合は入る行だけ描く。
    var tiny: [3]u16 = @splat(0x1234);
    drawRgb565(&m, &tiny, 3, 3, .{ .scale = 1, .quiet_zone = 4 });
    try testing.expectEqual(@as(u16, 0xFFFF), tiny[0]);
}

/// hello_world_m: alphanumeric / EC M / version 1 / mask 0
const expect_hello_world_m = [_][]const u8{
    "#######...#.#.#######",
    "#.....#.###...#.....#",
    "#.###.#...#.#.#.###.#",
    "#.###.#...#.#.#.###.#",
    "#.###.#.#.###.#.###.#",
    "#.....#..###..#.....#",
    "#######.#.#.#.#######",
    ".....................",
    "#.#.#.#..#..#...#..#.",
    ".####...#..#....#...#",
    "...#######.#..#.##...",
    "####.#.##..###.#.###.",
    ".#..####.#.#..###.#.#",
    "........#.#...#...#.#",
    "#######.....#..#.##..",
    "#.....#..##...##.#...",
    "#.###.#.##..#.#######",
    "#.###.#...##.#.#...#.",
    "#.###.#.####.###.#..#",
    "#.....#....###...#.##",
    "#######.##.#.###....#",
};

/// iso_01234567_m_mask2: numeric / EC M / version 1 / mask 2
const expect_iso_01234567_m_mask2 = [_][]const u8{
    "#######..#.##.#######",
    "#.....#..####.#.....#",
    "#.###.#.#.....#.###.#",
    "#.###.#.##....#.###.#",
    "#.###.#.#.###.#.###.#",
    "#.....#.#...#.#.....#",
    "#######.#.#.#.#######",
    "........#..##........",
    "#.#####..#..#.#####..",
    "...#.#.##.#.#..#.##..",
    "..#...##.#.#.#..#####",
    "....#....#.....####..",
    "...######..#.#..#....",
    "........#.#####..##..",
    "#######..##.#.##.....",
    "#.....#.#.#####...#.#",
    "#.###.#.#...#..#.##..",
    "#.###.#.##..#..#.....",
    "#.###.#.#.##.#..#.#..",
    "#.....#........##.##.",
    "#######.####.#..#.#..",
};

/// jp_utf8_q_mask5: byte / EC Q / version 3 / mask 5
const expect_jp_utf8_q_mask5 = [_][]const u8{
    "#######.#.##...#.#.##.#######",
    "#.....#.###.#.###.#.#.#.....#",
    "#.###.#..######.##....#.###.#",
    "#.###.#..##.#.#.###.#.#.###.#",
    "#.###.#...#.#..#.##...#.###.#",
    "#.....#..#..#..###.##.#.....#",
    "#######.#.#.#.#.#.#.#.#######",
    ".........##..##..###.........",
    ".#....#####..##.#....#.....##",
    "..#.....#..#..#..##...##...##",
    "..#..##.#....#...#.#..#..#.##",
    "#.#.##.####..#.#.####..#.##.#",
    "#.#####......#......#..#.#..#",
    "...###.#..##.####.###.#..#.##",
    "##.#..#...##.#..#.##.#..#####",
    ".###...##.#..#.....#.###.....",
    "#...###.#.#.###...####..#.##.",
    "##.###...######.#....#..#...#",
    "####.##.....##..#.##.#.##....",
    "#..#.#.....#.#####........##.",
    "#.##.##.#.#.#.#...#.#####....",
    "........####...#.####...###.#",
    "#######.####..#..#..#.#.##.##",
    "#.....#........####.#...#####",
    "#.###.#..#.#.#.#.#..######.##",
    "#.###.#..#....#...#.#.###..#.",
    "#.###.#....##.#####.###..###.",
    "#.....#.####....##..##......#",
    "#######..###.###..#######....",
};

/// ur300_l_mask0: alphanumeric / EC L / version 9 / mask 0
const expect_ur300_l_mask0 = [_][]const u8{
    "#######..##.###.#.###.###.#.#####.###.##..#...#######",
    "#.....#...##.......#.......####.##.#.#.#.###..#.....#",
    "#.###.#.#.##..#.#.#.###..###.#.######.##...#..#.###.#",
    "#.###.#....###...######..#.###...#.....#..#.#.#.###.#",
    "#.###.#......####.##.#.######...#...##....#...#.###.#",
    "#.....#.......#..#.....##...##...#...###.##...#.....#",
    "#######.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#.#######",
    "........##.#######.#.#.##...##...####.##.#..#........",
    "###.########.#..#.#.....#####.#....###..##.####...#..",
    "##.###.##..#.#..##....#...#.##..#......#.##.##.##.#..",
    "#.#...##.##.#.#..###...#.#.##...######.#.#.#..#.####.",
    "##.##..##.#..#..#####.#####...#.##..#####.#.####.#...",
    ".####.##.#..#.####..#..##.##..#...#...#.#####...#####",
    "#.#.#...####.#.##.....###.###..##..#.###...#.#.##..##",
    "..#...###.##..#..#..#......#...####...##...#.##...#..",
    "#.####..#..#...#####.##..#.#####.###.#..#####.##.##..",
    "..#####.####..####.#.....#...###....#####.....#..##..",
    "#..#...##.###..#.#...##..##.....##....#.#.##.##....#.",
    ".#.#.###.###..#####.#..#######..#####.####.####..#...",
    ".###...#.###...#.###.#....#.###.#.....#....###.#..#.#",
    "###...#..##.#...#.##.....#..#.#####.#...#..#..#.#.##.",
    "#.#.##.#..#.###.#...#...####.......####..#...#.....#.",
    "####.#####...#.#..#..#..##.####.###....#.####.#..#..#",
    "###.##..##...###...###...#.##.......#.##.#..##..###..",
    "#########.##.#..#.#..#.#########.#..#.#.#.#.########.",
    "##..#...######..#....##.#...##....####..#####...#..#.",
    "#.###.#.###.##.....###.##.#.##..#########.###.#.##...",
    "###.#...#..###..######.##...#######..#.#.####...#.#.#",
    "###.#####...###.##..#..###########..#..#.########.##.",
    "..###....###...###..###.##.#.###.#.#.####..#.##.#...#",
    "#.#..#####.##.#.##..#.#....#.#..#.....###...#..#.....",
    "######.#####.....####.##.####..######...#.#.#.#.##.##",
    ".#.#.##.##..#.####..###..#....##..####.#.##...#.#.#.#",
    "...#.#.####.#..#.#.####.#..##..###.###...#.####.###..",
    "#..#..##.....#.##.#.##..####..#.....###.####..#.#...#",
    ".#.#.#.#.#.###.#..#..###....####..###.####.###.###.##",
    "#.##..#.##.#..##.#.....###.##.###.#.#.###.#.##.######",
    "#.#..#...##.####.#....####..###.#....#....##.........",
    "#...#.#..##.##..#.#......#.........##..##.###..#.#.#.",
    ".##.##...#.######..#..##..##.####........#..###...#..",
    "##..#.##.#.###..#.##.####.....###.#......#.##...#.#..",
    "######..#....#..#.....##.#.#.#.#..#.#.##.####..####..",
    "##.#######...#......#.###.###..#...##.####.#.#####.#.",
    ".##....#..#.....#..#.....##..##.####..#.###.#....#.##",
    "...#..##...#.#.#####..#.#######.#...#.#.###.######...",
    "........#.#.##.#..##.####...##.#.###......###...####.",
    "#######.#.#.#..###.#.####.#.###..##.#......##.#.#..##",
    "#.....#.#.##.##.######.##...##....#.#####...#...#.#.#",
    "#.###.#.##.....###..###.######...#.##...##..#####.#..",
    "#.###.#..####..#.#.#..##.####..#..##.#..##.###..#.#..",
    "#.###.#.#..##..##.###.##.#....###.#.#..#.######...#..",
    "#.....#.#...#.##..##.###..####.##.#..#.###....##..###",
    "#######.#####.#######..##..###.##.##..#.#...#.#####.#",
};

/// 埋め込み行列と一致するか確かめる（'#' が暗、'.' が明）。
fn expectMatrix(m: *const Matrix, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, m.size);
    for (expected, 0..) |row, y| {
        try testing.expectEqual(m.size, row.len);
        for (row, 0..) |c, x| {
            try testing.expectEqual(c == '#', m.get(x, y));
        }
    }
}

/// 2 つの行列が完全に同じか確かめる。
fn expectSameMatrix(a: *const Matrix, b: *const Matrix) !void {
    try testing.expectEqual(a.size, b.size);
    try testing.expectEqualSlices(u8, a.modules, b.modules);
}

/// 埋め込みベクタで使う UR 風の文字列（大文字の bytewords を QR に出す想定）。
const ur_long_vector = "UR:BYTES/71HFE86Y5R215DEW1ZCYQESH0ARLH9DL65O6MMG2TY7O5ZINC42EI5E6OHTNANMDH4AYFATOHZEK3E2KPH4DKDVPT9G8FZYGRPNE8WV5379AR4OOTXGZ07YHL7IRAT0GWBW6JWC9NAYX0KV17NJF3F55V4Y88UZAGXRDYCJPNSXS7FE4L1ZEE043E42L4WFHVDY8UFUQC66RMRQT363PL6FCCYS8RBHTF4SZ63Y05FAQVUDP3AO0OGTIRZV9CID3Y3K33UWXA3W5B44FP7F25QXKGDKFGP8JTK40T64YDWG8";

test "行列: HELLO WORLD（英数字 / EC M / 自動マスク）" {
    // 出典: Nayuki qrcodegen 1.8.0、python-qrcode 8.2、segno 1.6.6（パディングのみ
    // 規格どおりに修正）の 3 実装が、いずれも version 1・マスク 0 を自動選択し、
    // 同一の行列を出力することを確認している。
    const allocator = testing.allocator;
    var m = try encode(allocator, "HELLO WORLD", .m);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), m.version);
    try testing.expectEqual(@as(u3, 0), m.mask);
    try testing.expectEqual(Mode.alphanumeric, m.mode);
    try testing.expectEqual(@as(usize, 21), m.size);
    try expectMatrix(&m, &expect_hello_world_m);
}

test "行列: 01234567（数字 / EC M / 規格 Annex I.2 の作業例）" {
    // ISO/IEC 18004:2006(E) Annex I.2 は "01234567" をバージョン 1-M で符号化し、
    // Step 4 で「選択されるデータマスクは 010（= 2）」と明記している。format 情報も
    // Step 5 で 101111001111100（= 0x5E7C。Table C.1 のデータビット 00010）と明記。
    // 期待する行列は、qrcodegen 1.8.0 / python-qrcode 8.2 / segno 1.6.6（パディング修正）が
    // マスク 2 指定で一致して出力するもので、規格の作業例と同一のシンボル。
    const allocator = testing.allocator;

    var m = try encode(allocator, "01234567", .m);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 1), m.version);
    try testing.expectEqual(@as(u3, 2), m.mask);
    try testing.expectEqual(Mode.numeric, m.mode);
    try expectMatrix(&m, &expect_iso_01234567_m_mask2);

    // 参考: format/version 情報を空のまま評価する規約（`encoding_region_only`、
    // segno 1.6.6 と同じ）ではマスク 3 が選ばれる。どちらの規約でも生成される
    // シンボルは規格に適合し、復号できる（マスク番号は format 情報に入る）。
    var compat = try encodeOptions(allocator, "01234567", .m, .{ .mask_eval = .encoding_region_only });
    defer compat.deinit(allocator);
    try testing.expectEqual(@as(u3, 3), compat.mask);
    var forced = try encodeWithMask(allocator, "01234567", .m, 3);
    defer forced.deinit(allocator);
    try expectSameMatrix(&compat, &forced);
}

test "行列: 日本語 UTF-8（バイト / EC Q / マスク 5 指定）" {
    // 出典: qrcodegen 1.8.0 / python-qrcode 8.2 / segno 1.6.6（パディング修正）が
    // マスク 5 指定で一致して出力する行列。バイトモード・version 3
    // （位置合わせパターンを含む大きさ）。
    const allocator = testing.allocator;
    var m = try encodeWithMask(allocator, "日本語のテスト", .q, 5);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 3), m.version);
    try testing.expectEqual(Mode.byte, m.mode);
    try testing.expectEqual(@as(u3, 5), m.mask);
    try expectMatrix(&m, &expect_jp_utf8_q_mask5);
}

test "行列: 長い UR 風文字列（英数字 / EC L / マスク 0 指定）" {
    // 出典: 上と同じ 3 実装がマスク 0 指定で一致して出力する行列。
    // version 9（version 情報ブロックと位置合わせパターンを含む）。
    // zhww は QR 表示用に bytewords を大文字で出すため、英数字モードが選ばれる。
    const allocator = testing.allocator;
    var m = try encodeWithMask(allocator, ur_long_vector, .l, 0);
    defer m.deinit(allocator);
    try testing.expectEqual(@as(u8, 9), m.version);
    try testing.expectEqual(Mode.alphanumeric, m.mode);
    try testing.expectEqual(@as(usize, 309), ur_long_vector.len);
    try expectMatrix(&m, &expect_ur300_l_mask0);
}
