//! QR コードのデコーダ（カメラ入力を想定）。
//!
//! 入力は「1 バイト 1 画素のグレースケール画像」だけ。カメラ固有の処理
//! （露出・ホワイトバランス・RGB 変換）は呼び出し側の責任とし、このモジュールは
//! 画像バッファから文字列を取り出すことだけを行う。
//!
//! 処理の流れ:
//!   1. 二値化 — 8×8 ブロックの局所平均を使う適応的二値化（ZXing の HybridBinarizer と
//!      同じ考え方）。小さい画像では大津の手法（全体閾値）へ落とす。復号に失敗したら
//!      もう一方の二値化・許容を広げた検出・白黒反転でも順に試す。
//!   2. 位置検出パターン（3 つの角）を 1:1:3:1:1 のラン走査で探し、直交方向の
//!      クロスチェックで中心をサブピクセルまで詰める。
//!   3. 3 点の並び（左上・右上・左下）を外積で確定し、タイミングパターンの明暗遷移を
//!      数えてバージョン（= 一辺のモジュール数）を決める。遷移数は距離に依存しないので
//!      遠近があっても寸法を誤りにくい。
//!   4. 右下のアラインメントパターンを探し、4 点から射影変換（ホモグラフィ）を解く。
//!      見つからない場合は平行四辺形（アフィン）で代用する。
//!   5. 各モジュール中心を 5 点サンプリング（多数決）して行列化する。
//!   6. format 情報（15 ビット、ハミング距離で誤り訂正）から EC レベルとマスクを得て、
//!      マスクを外しながらジグザグにデータコードワードを読み出す。
//!   7. ブロックごとに Reed-Solomon で誤り訂正し、モード指示子を解釈して文字列にする。
//!
//! 対応する範囲: バージョン 1〜40、EC レベル L/M/Q/H、数字・英数字・バイトモード。
//! ECI・漢字モード・構造的連接（structured append）・FNC1 は `Error.UnsupportedMode`。
//!
//! メモリ: 二値画像とモジュール行列は 1 ビット 1 画素で持つ。`Image` の画素バッファは
//! 呼び出し側が所有し、このモジュールは書き換えない。作業用の確保は `decode` の
//! allocator から行い、すべて関数内で解放する。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const trace = true;
const qr = @import("qr.zig");
const CoreError = @import("../core/errors.zig").Error;

/// デコード時のエラー。コア共通の `Error` に QR 固有のものを加える。
pub const Error = CoreError || error{
    /// 画像から位置検出パターン（3 つの角）を見つけられなかった
    SymbolNotFound,
    /// シンボルは見つかったが、誤り訂正の能力を超える誤りがあった
    TooManyErrors,
    /// シンボルは見つかったが構造が規格に合わない（データモジュール不足など）
    InvalidSymbol,
    /// 規格上未対応の機能（ECI・漢字モード・構造的連接・FNC1）
    UnsupportedMode,
};

/// 対応する最小バージョン。
pub const min_version: u8 = 1;
/// 対応する最大バージョン。
pub const max_version: u8 = 40;
/// バージョン 1 の一辺のモジュール数。
pub const min_size: usize = 17 + 4 * @as(usize, min_version);
/// バージョン 40 の一辺のモジュール数。
pub const max_size: usize = 17 + 4 * @as(usize, max_version);

/// 受け付ける画像の最大辺。これを超える画像は対象外（掛け算のオーバーフロー防止も兼ねる）。
pub const max_image_dim: usize = 4096;

/// グレースケール画像。1 バイト 1 画素（0 = 黒、255 = 白）、行優先。
pub const Image = struct {
    width: usize,
    height: usize,
    /// `width * height` バイト以上が必要（行優先）。
    pixels: []const u8,

    /// (x, y) の画素。範囲外は白（255）として扱う。
    pub fn pixel(self: *const Image, x: usize, y: usize) u8 {
        if (x >= self.width or y >= self.height) return 255;
        return self.pixels[y * self.width + x];
    }
};

/// 復号結果の付帯情報。
pub const Info = struct {
    /// 復号したテキスト。`decodeTo` に渡した `out` の先頭部分を指す。
    text: []const u8,
    /// シンボルのバージョン（1〜40）。
    version: u8,
    /// 誤り訂正レベル。
    ec: qr.EcLevel,
    /// 使われていたマスク番号（0〜7）。
    mask: u3,
};

// ---------------------------------------------------------------- 公開 API

/// 画像を復号して文字列を返す。
///
/// 戻り値は `allocator` が確保したメモリなので、呼び出し側が同じ allocator で
/// `allocator.free(result)` すること。バイトモードの内容はそのまま返す
/// （UTF-8 の解釈は呼び出し側に任せる）。
pub fn decode(allocator: std.mem.Allocator, image: Image) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var sink = Sink{ .allocator = allocator, .list = &out };
    var info: Info = undefined;
    try decodeInternal(allocator, &image, &sink, &info);
    return try out.toOwnedSlice(allocator);
}

/// `out` に書き込んで復号する。
///
/// 足りなければ `Error.BufferTooSmall`。戻り値は `out` の先頭部分を指す。
pub fn decodeInto(allocator: std.mem.Allocator, image: Image, out: []u8) Error![]const u8 {
    return (try decodeTo(allocator, image, out)).text;
}

/// `out` に書き込み、バージョン・EC レベル・マスクも返す。
pub fn decodeTo(allocator: std.mem.Allocator, image: Image, out: []u8) Error!Info {
    var sink = Sink{ .allocator = allocator, .fixed = out };
    var info: Info = .{ .text = out[0..0], .version = 0, .ec = .l, .mask = 0 };
    try decodeInternal(allocator, &image, &sink, &info);
    return info;
}

// ---------------------------------------------------------------- 出力先

/// 復号結果の書き込み先。可変長（ArrayList）と固定長を同じ経路で扱う。
const Sink = struct {
    allocator: std.mem.Allocator,
    list: ?*std.ArrayList(u8) = null,
    fixed: ?[]u8 = null,
    len: usize = 0,

    fn writeByte(self: *Sink, b: u8) Error!void {
        if (self.list) |l| {
            try l.append(self.allocator, b);
        } else if (self.fixed) |f| {
            if (self.len >= f.len) return Error.BufferTooSmall;
            f[self.len] = b;
        } else return Error.BufferTooSmall;
        self.len += 1;
    }

    /// 直前の試行の書き込みを捨てる（候補ごとにやり直すため）。
    fn reset(self: *Sink) void {
        if (self.list) |l| l.clearRetainingCapacity();
        self.len = 0;
    }

    fn text(self: *const Sink) []const u8 {
        if (self.list) |l| return l.items;
        if (self.fixed) |f| return f[0..self.len];
        return &.{};
    }
};

// ---------------------------------------------------------------- ビット行列

/// 1 ビット 1 画素の二値行列。二値画像とモジュール行列の両方に使う。
const BitMatrix = struct {
    width: usize,
    height: usize,
    words: []u64,

    fn init(allocator: std.mem.Allocator, width: usize, height: usize) Error!BitMatrix {
        const n = (width * height + 63) / 64;
        const words = try allocator.alloc(u64, n);
        @memset(words, 0);
        return .{ .width = width, .height = height, .words = words };
    }

    fn deinit(self: *const BitMatrix, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
    }

    fn get(self: *const BitMatrix, x: usize, y: usize) bool {
        if (x >= self.width or y >= self.height) return false;
        const i = y * self.width + x;
        return (self.words[i >> 6] >> @intCast(i & 63)) & 1 != 0;
    }

    fn set(self: *BitMatrix, x: usize, y: usize) void {
        if (x >= self.width or y >= self.height) return;
        const i = y * self.width + x;
        self.words[i >> 6] |= @as(u64, 1) << @intCast(i & 63);
    }

    /// 全ビットを反転する（白黒反転した画像への最後の抵抗）。
    fn invert(self: *BitMatrix) void {
        for (self.words) |*w| w.* = ~w.*;
    }
};

// ---------------------------------------------------------------- 二値化

/// 二値化の方針。
const BinarizePlan = struct {
    /// 8×8 ブロックの局所平均を使う（照明むらに強い）。false なら大津の全体閾値。
    adaptive: bool,
    /// 白黒反転した画像とみなして反転する。
    invert: bool = false,
};

/// ZXing と同じ「平坦とみなす明暗差」。
const min_dynamic_range: u32 = 24;

fn clampUsize(value: usize, low: usize, high: usize) usize {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

/// 二値化する。`bin` は画像と同じ寸法で確保済みであること。
fn binarize(bin: *BitMatrix, image: *const Image, plan: BinarizePlan, black_points: []u8) void {
    const sub_w = (image.width + 7) / 8;
    const sub_h = (image.height + 7) / 8;
    if (plan.adaptive and sub_w >= 5 and sub_h >= 5 and black_points.len >= sub_w * sub_h) {
        adaptiveBinarize(bin, image, black_points);
    } else {
        globalBinarize(bin, image);
    }
    if (plan.invert) bin.invert();
}

/// 大津の手法で全体閾値を決めて二値化する（小さい画像・照明が一様な画像向け）。
fn globalBinarize(bin: *BitMatrix, image: *const Image) void {
    var histogram: [256]u32 = @splat(0);
    const n = image.width * image.height;
    for (image.pixels[0..n]) |p| histogram[p] += 1;

    var total: u32 = 0;
    var sum_all: f64 = 0;
    for (0..256) |i| {
        total += histogram[i];
        sum_all += @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(histogram[i]));
    }
    if (total == 0) return;

    var best_threshold: u8 = 0;
    var best_variance: f64 = -1.0;
    var sum_back: f64 = 0;
    var weight_back: u32 = 0;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        weight_back += histogram[i];
        if (weight_back == 0) continue;
        const weight_fore = total - weight_back;
        if (weight_fore == 0) break;
        sum_back += @as(f64, @floatFromInt(i)) * @as(f64, @floatFromInt(histogram[i]));
        const mean_back = sum_back / @as(f64, @floatFromInt(weight_back));
        const mean_fore = (sum_all - sum_back) / @as(f64, @floatFromInt(weight_fore));
        const diff = mean_back - mean_fore;
        const variance = @as(f64, @floatFromInt(weight_back)) *
            @as(f64, @floatFromInt(weight_fore)) * diff * diff;
        if (variance > best_variance) {
            best_variance = variance;
            best_threshold = @intCast(i);
        }
    }

    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        const row = image.pixels[y * image.width ..][0..image.width];
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            if (row[x] <= best_threshold) bin.set(x, y);
        }
    }
}

/// 8×8 ブロックごとの局所平均で二値化する（ZXing の HybridBinarizer 相当）。
///
/// 各ブロックの平均（平坦なブロックは近傍の値で補う）を求め、その 5×5 近傍の平均を
/// 閾値にする。照明の勾配や軽い影があっても局所的に白黒を分けられる。
fn adaptiveBinarize(bin: *BitMatrix, image: *const Image, black_points: []u8) void {
    const w = image.width;
    const h = image.height;
    const sub_w = (w + 7) / 8;
    const sub_h = (h + 7) / 8;
    @memset(black_points[0 .. sub_w * sub_h], 0);

    var by: usize = 0;
    while (by < sub_h) : (by += 1) {
        var bx: usize = 0;
        while (bx < sub_w) : (bx += 1) {
            const x0 = bx * 8;
            const y0 = by * 8;
            const x1 = @min(x0 + 8, w);
            const y1 = @min(y0 + 8, h);
            var sum: u32 = 0;
            var min: u8 = 255;
            var max: u8 = 0;
            var count: u32 = 0;
            var y: usize = y0;
            while (y < y1) : (y += 1) {
                var x: usize = x0;
                while (x < x1) : (x += 1) {
                    const p = image.pixels[y * w + x];
                    sum += p;
                    if (p < min) min = p;
                    if (p > max) max = p;
                    count += 1;
                }
            }
            var average: u8 = if (count == 0) 255 else @intCast(sum / count);
            if (@as(u32, max) - @as(u32, min) <= min_dynamic_range) {
                // 平坦なブロック（一様な白地・黒地）は近傍の閾値を借りる。
                average = min / 2;
                if (by > 0 and bx > 0) {
                    const neighbor = (@as(u32, black_points[(by - 1) * sub_w + bx]) +
                        2 * @as(u32, black_points[by * sub_w + bx - 1]) +
                        @as(u32, black_points[(by - 1) * sub_w + bx - 1])) / 4;
                    if (min < neighbor) average = @intCast(neighbor);
                }
            }
            black_points[by * sub_w + bx] = average;
        }
    }

    by = 0;
    while (by < sub_h) : (by += 1) {
        var bx: usize = 0;
        while (bx < sub_w) : (bx += 1) {
            const left = clampUsize(bx, 2, sub_w - 3);
            const top = clampUsize(by, 2, sub_h - 3);
            var sum: u32 = 0;
            var z: usize = 0;
            while (z < 5) : (z += 1) {
                var xx: usize = 0;
                while (xx < 5) : (xx += 1) {
                    sum += black_points[(top + z - 2) * sub_w + (left + xx - 2)];
                }
            }
            const threshold: u8 = @intCast(sum / 25);

            const x0 = bx * 8;
            const y0 = by * 8;
            const x1 = @min(x0 + 8, w);
            const y1 = @min(y0 + 8, h);
            var y: usize = y0;
            while (y < y1) : (y += 1) {
                var x: usize = x0;
                while (x < x1) : (x += 1) {
                    if (image.pixels[y * w + x] <= threshold) bin.set(x, y);
                }
            }
        }
    }
}

// ---------------------------------------------------------------- 幾何

const Point = struct { x: f64, y: f64 };

fn distance(a: Point, b: Point) f64 {
    const dx = a.x - b.x;
    const dy = a.y - b.y;
    return @sqrt(dx * dx + dy * dy);
}

fn cross(a: Point, b: Point, origin: Point) f64 {
    return (a.x - origin.x) * (b.y - origin.y) - (a.y - origin.y) * (b.x - origin.x);
}

/// 射影変換（モジュール座標 → 画素座標）。h[6], h[7] が 0 ならアフィン。
const Homography = struct {
    h: [8]f64,

    fn map(self: *const Homography, u: f64, v: f64) Point {
        const denom = self.h[6] * u + self.h[7] * v + 1.0;
        const d = if (@abs(denom) < 1e-12) 1e-12 else denom;
        return .{
            .x = (self.h[0] * u + self.h[1] * v + self.h[2]) / d,
            .y = (self.h[3] * u + self.h[4] * v + self.h[5]) / d,
        };
    }
};

/// 4 点対応から射影変換を解く。退化している場合は null。
fn solveHomography(src: [4]Point, dst: [4]Point) ?Homography {
    var m: [8][9]f64 = undefined;
    for (0..4) |k| {
        const u = src[k].x;
        const v = src[k].y;
        const x = dst[k].x;
        const y = dst[k].y;
        m[2 * k] = .{ u, v, 1.0, 0.0, 0.0, 0.0, -u * x, -v * x, x };
        m[2 * k + 1] = .{ 0.0, 0.0, 0.0, u, v, 1.0, -u * y, -v * y, y };
    }
    for (0..8) |col| {
        var pivot = col;
        var best = @abs(m[col][col]);
        var r = col + 1;
        while (r < 8) : (r += 1) {
            const a = @abs(m[r][col]);
            if (a > best) {
                best = a;
                pivot = r;
            }
        }
        if (best < 1e-9) return null;
        if (pivot != col) std.mem.swap([9]f64, &m[pivot], &m[col]);
        const d = m[col][col];
        var c = col;
        while (c < 9) : (c += 1) m[col][c] /= d;
        for (0..8) |row| {
            if (row == col) continue;
            const factor = m[row][col];
            if (factor == 0.0) continue;
            c = col;
            while (c < 9) : (c += 1) m[row][c] -= factor * m[col][c];
        }
    }
    var h: [8]f64 = undefined;
    for (0..8) |i| h[i] = m[i][8];
    return .{ .h = h };
}

// ---------------------------------------------------------------- ラン走査

/// 走査で見つかった候補（位置検出パターン・アラインメントパターンの中心）。
const Candidate = struct {
    x: f64,
    y: f64,
    module: f64,
    count: usize = 1,
};

/// 5 連ラン（暗・明・暗・明・暗）の相対幅。位置検出は 1:1:3:1:1、アラインは 1:1:1:1:1。
const finder_ratio = [5]f64{ 1, 1, 3, 1, 1 };
/// 位置検出パターンの候補リストの上限（溢れたら弱いものから捨てる）。
const max_finder_candidates: usize = 512;
const align_ratio = [5]f64{ 1, 1, 1, 1, 1 };

const RatioResult = struct { center: usize, module: f64 };

/// 5 連ランの中心（走査軸方向、先頭からの距離）とモジュール長。比が合わなければ null。
fn ratioCenter(counts: [5]usize, expected: [5]f64, tolerance: f64) ?RatioResult {
    var total: usize = 0;
    for (counts) |c| total += c;
    if (total < 7) return null;
    const expected_total = expected[0] + expected[1] + expected[2] + expected[3] + expected[4];
    const module = @as(f64, @floatFromInt(total)) / expected_total;
    if (module < 1.0) return null;
    for (0..5) |i| {
        const want = expected[i] * module;
        const allowed = expected[i] * tolerance * module + 1.0;
        const got = @as(f64, @floatFromInt(counts[i]));
        if (@abs(got - want) > allowed) return null;
    }
    return .{ .center = counts[0] + counts[1] + counts[2] / 2, .module = module };
}

/// アラインメントパターン用のラン判定。
///
/// 中心の 1 モジュール（暗）とその周りの明の輪は、隣のデータモジュールと融合しない
/// ので厳密に見る。一方、外側の暗い枠は隣のデータと繋がって長くなりうるため、
/// 「1 モジュール以上」だけを要求する（ZXing の AlignmentPatternFinder と同じ考え方）。
fn alignRatio(counts: [5]usize, tolerance: f64) ?f64 {
    const inner = counts[1] + counts[2] + counts[3];
    if (inner < 3) return null;
    const module = @as(f64, @floatFromInt(inner)) / 3.0;
    if (module < 1.0) return null;
    const allowed = tolerance * module + 1.0;
    for (1..4) |i| {
        const got: f64 = @floatFromInt(counts[i]);
        if (@abs(got - module) > allowed) return null;
    }
    if (@as(f64, @floatFromInt(counts[0])) < 0.4 * module) return null;
    if (@as(f64, @floatFromInt(counts[4])) < 0.4 * module) return null;
    return module;
}

/// ラン走査の作業領域（1 行分のラン開始位置）。
const RunScanner = struct {
    starts: []usize,

    fn init(allocator: std.mem.Allocator, max_len: usize) Error!RunScanner {
        return .{ .starts = try allocator.alloc(usize, max_len + 2) };
    }

    fn deinit(self: *const RunScanner, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
    }
};

/// 走査軸 `major` の 1 行（列）分のラン開始位置を作り、ラン数を返す。
fn buildRuns(self: *const RunScanner, bin: *const BitMatrix, vertical: bool, major: usize, lo: usize, hi: usize) usize {
    var n: usize = 0;
    self.starts[0] = lo;
    var p = lo + 1;
    while (p < hi) : (p += 1) {
        const prev = if (vertical) bin.get(major, p - 1) else bin.get(p - 1, major);
        const cur = if (vertical) bin.get(major, p) else bin.get(p, major);
        if (cur != prev) {
            n += 1;
            self.starts[n] = p;
        }
    }
    n += 1;
    self.starts[n] = hi;
    return n;
}

/// 走査軸に沿って (major, minor) の画素を読む。
fn runPixel(bin: *const BitMatrix, vertical: bool, major: isize, minor: isize) bool {
    if (major < 0 or minor < 0) return false;
    const ma: usize = @intCast(major);
    const mi: usize = @intCast(minor);
    if (vertical) {
        if (mi >= bin.width or ma >= bin.height) return false;
        return bin.get(mi, ma);
    }
    if (ma >= bin.width or mi >= bin.height) return false;
    return bin.get(ma, mi);
}

/// 中心画素から走査軸の両側へ 5 連ランを測り、比が合えば中心を返す。
///
/// 中心が暗でない場合や、比が合わない場合は null。`total_hint` を渡すと、
/// 直交方向の全長が大きく違う候補を弾く（位置検出パターンの縦横比の確認）。
const ScanKind = enum { finder, alignment };

fn crossCheck(
    bin: *const BitMatrix,
    cx: f64,
    cy: f64,
    horizontal: bool,
    kind: ScanKind,
    expected: [5]f64,
    tolerance: f64,
    total_hint: ?f64,
) ?Candidate {
    if (cx < 0.0 or cy < 0.0) return null;
    const cxi: isize = @intFromFloat(@floor(cx));
    const cyi: isize = @intFromFloat(@floor(cy));
    const c_major = if (horizontal) cxi else cyi;
    const c_minor = if (horizontal) cyi else cxi;
    if (!runPixel(bin, !horizontal, c_major, c_minor)) return null;

    var counts: [5]usize = @splat(0);
    counts[2] = 1;
    var center_neg: usize = 0;
    const limit: usize = 128;

    // 負方向: 暗（中央ラン）→ 明 → 暗。
    {
        var k: isize = 1;
        while (k < @as(isize, @intCast(limit))) : (k += 1) {
            if (!runPixel(bin, !horizontal, c_major - k, c_minor)) break;
            counts[2] += 1;
            center_neg += 1;
        }
        var kk: isize = 1 + @as(isize, @intCast(center_neg));
        while (kk < @as(isize, @intCast(limit))) : (kk += 1) {
            if (runPixel(bin, !horizontal, c_major - kk, c_minor)) break;
            counts[1] += 1;
        }
        var k2: isize = 1 + @as(isize, @intCast(center_neg + counts[1]));
        while (k2 < @as(isize, @intCast(limit))) : (k2 += 1) {
            if (!runPixel(bin, !horizontal, c_major - k2, c_minor)) break;
            counts[0] += 1;
        }
    }
    // 正方向: 中央ラン → 明 → 暗。
    {
        var k: isize = 1;
        while (k < @as(isize, @intCast(limit))) : (k += 1) {
            if (!runPixel(bin, !horizontal, c_major + k, c_minor)) break;
            counts[2] += 1;
        }
        const center_pos = counts[2] - 1 - center_neg;
        var kk: isize = 1 + @as(isize, @intCast(center_pos));
        while (kk < @as(isize, @intCast(limit))) : (kk += 1) {
            if (runPixel(bin, !horizontal, c_major + kk, c_minor)) break;
            counts[3] += 1;
        }
        var k2: isize = 1 + @as(isize, @intCast(center_pos + counts[3]));
        while (k2 < @as(isize, @intCast(limit))) : (k2 += 1) {
            if (!runPixel(bin, !horizontal, c_major + k2, c_minor)) break;
            counts[4] += 1;
        }
    }

    const module = switch (kind) {
        .finder => (ratioCenter(counts, expected, tolerance) orelse return null).module,
        .alignment => alignRatio(counts, tolerance) orelse return null,
    };
    const total: f64 = @floatFromInt(counts[0] + counts[1] + counts[2] + counts[3] + counts[4]);
    if (total_hint) |hint| {
        if (@abs(total - hint) > 0.5 * hint + 1.0) return null;
    }
    // 中心ランの画素範囲は [c_major - center_neg, c_major + center_pos] なので、
    // 連続座標での中心は +0.5 した値になる（画素 i は [i, i+1) を占める）。
    const center_pos = counts[2] - 1 - center_neg;
    const t = (@as(f64, @floatFromInt(center_pos)) - @as(f64, @floatFromInt(center_neg))) / 2.0;
    const major_f = @as(f64, @floatFromInt(c_major)) + t + 0.5;
    const minor_f = @as(f64, @floatFromInt(c_minor)) + 0.5;
    return .{
        .x = if (horizontal) major_f else minor_f,
        .y = if (horizontal) minor_f else major_f,
        .module = module,
    };
}

/// 位置検出パターンの外側（中心から 4 モジュール）が明るいか確かめる。
///
/// 本物の位置検出パターンは分離帯（明）と静穏域に囲まれているので、中心から
/// ±4 モジュールの 4 点は必ず明になる。走査で測ったモジュール長は画像軸に沿った
/// 長さなので、シンボルが回転していてもこの 4 点は分離帯の上に落ちる。
fn hasLightRing(bin: *const BitMatrix, cx: f64, cy: f64, module: f64) bool {
    const d = 4.0 * module;
    const points = [4]Point{
        .{ .x = cx + d, .y = cy },
        .{ .x = cx - d, .y = cy },
        .{ .x = cx, .y = cy + d },
        .{ .x = cx, .y = cy - d },
    };
    var light: usize = 0;
    for (points) |p| {
        if (!samplePixel(bin, p)) light += 1;
    }
    return light >= 3;
}

/// すでに複数行で確認できている候補のモジュール長。
///
/// データ領域に偶然現れる 1:1:3:1:1 は本物よりずっと小さい（1〜3 画素）ことが多いので、
/// 基準から外れたものを捨てると候補リストが溢れない。位置検出パターンは 3 つとも
/// 同じモジュール長なので、回転していてもこの判定は使える。
fn referenceModule(items: []const Candidate) ?f64 {
    var best_count: usize = 2; // count >= 3 のものだけを基準にする
    var best: ?f64 = null;
    for (items) |c| {
        if (c.count > best_count) {
            best_count = c.count;
            best = c.module;
        }
    }
    return best;
}

/// 既存候補に近ければまとめ、そうでなければ追加する。
fn mergeCandidate(list: *std.ArrayList(Candidate), allocator: std.mem.Allocator, c: Candidate) Error!void {
    for (list.items) |*p| {
        const near = @abs(p.x - c.x) <= p.module * 1.0 and @abs(p.y - c.y) <= p.module * 1.0;
        // モジュール長が大きく違うものは統合しない（データ領域の 1 画素パターンが
        // 本物の位置検出パターンに吸着して、寸法推定を壊すのを防ぐ）。
        const similar = @abs(p.module - c.module) <= 0.35 * @max(p.module, c.module) + 0.3;
        if (near and similar) {
            const n = @as(f64, @floatFromInt(p.count));
            p.x = (p.x * n + c.x) / (n + 1.0);
            p.y = (p.y * n + c.y) / (n + 1.0);
            p.module = (p.module * n + c.module) / (n + 1.0);
            p.count += 1;
            return;
        }
    }
    // 上限に達したら、いちばん弱い（確認回数の少ない）候補を追い出す。
    if (list.items.len >= max_finder_candidates) {
        var weakest: usize = 0;
        for (list.items, 0..) |p, i| {
            if (p.count < list.items[weakest].count) weakest = i;
        }
        if (list.items[weakest].count >= c.count) return;
        list.items[weakest] = c;
        return;
    }
    try list.append(allocator, c);
}

/// 5 連ランを走査して中心候補を集める。
///
/// `vertical` が true なら列方向に走査する（回転したシンボルや、行走査で拾えない
/// 場合の保険）。`minor` は走査しない側の座標。
fn scanRuns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    scanner: *const RunScanner,
    vertical: bool,
    lo: usize,
    hi: usize,
    expected: [5]f64,
    tolerance: f64,
    relaxed_ring: bool,
    out: *std.ArrayList(Candidate),
) Error!void {
    const major_len = if (vertical) bin.height else bin.width;
    const minor_len = if (vertical) bin.width else bin.height;
    if (lo >= hi or hi > major_len) return;

    var minor: usize = 0;
    while (minor < minor_len) : (minor += 1) {
        const nruns = buildRuns(scanner, bin, vertical, minor, lo, hi);
        if (nruns < 5) continue;
        var i: usize = 0;
        while (i + 5 <= nruns) : (i += 1) {
            const first_dark = if (vertical)
                bin.get(minor, scanner.starts[i])
            else
                bin.get(scanner.starts[i], minor);
            if (!first_dark) continue;
            var counts: [5]usize = undefined;
            for (0..5) |k| counts[k] = scanner.starts[i + k + 1] - scanner.starts[i + k];
            _ = ratioCenter(counts, expected, tolerance) orelse continue;
            const major_center = (@as(f64, @floatFromInt(scanner.starts[i + 2])) +
                @as(f64, @floatFromInt(scanner.starts[i + 3]))) / 2.0;
            const minor_center = @as(f64, @floatFromInt(minor)) + 0.5;
            const cx = if (vertical) minor_center else major_center;
            const cy = if (vertical) major_center else minor_center;
            const total_px: f64 = @floatFromInt(counts[0] + counts[1] + counts[2] + counts[3] + counts[4]);
            // 直交方向のクロスチェック → 走査方向で中心を詰める。
            const first = crossCheck(bin, cx, cy, vertical, .finder, expected, tolerance, total_px) orelse continue;
            const second = crossCheck(bin, first.x, first.y, !vertical, .finder, expected, tolerance, total_px) orelse continue;
            const measured = (first.module + second.module) / 2.0;
            // 分離帯に囲まれていないものは位置検出パターンではない。
            if (!relaxed_ring and !hasLightRing(bin, second.x, second.y, measured)) continue;
            // すでに複数行で確認できた候補があるなら、モジュール長が大きく違うものを
            // 落とす（データ領域に偶然現れる小さな 1:1:3:1:1 をふるい落とす）。
            if (referenceModule(out.items)) |reference| {
                if (measured < 0.5 * reference or measured > 2.0 * reference) continue;
            }
            try mergeCandidate(out, allocator, .{
                .x = second.x,
                .y = second.y,
                .module = measured,
            });
        }
    }
}

// ---------------------------------------------------------------- 位置検出

/// 位置検出パターンを探す（確認回数の多い順、呼び出し側が free する）。
///
/// `relaxed` が false のときは分離帯の判定を入れて厳しく絞る。true のときは
/// 判定を外し、許容も広げて、行と列の両方を走査する（汚れた画像・欠けた画像向け）。
fn findFinderPatterns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    relaxed: bool,
) Error![]Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    errdefer out.deinit(allocator);
    const scanner = try RunScanner.init(allocator, @max(bin.width, bin.height));
    defer scanner.deinit(allocator);

    const tolerance: f64 = if (relaxed) 0.75 else 0.5;
    try scanRuns(allocator, bin, &scanner, false, 0, bin.width, finder_ratio, tolerance, relaxed, &out);
    if (relaxed or out.items.len < 3) {
        try scanRuns(allocator, bin, &scanner, true, 0, bin.height, finder_ratio, tolerance, relaxed, &out);
    }
    // 確認回数の多い順（単純な挿入ソート。候補は多くても数百）。
    const items = out.items;
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and items[j - 1].count < key.count) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }
    if (trace) {
        std.debug.print("[cand] relaxed={} total={d}\n", .{ relaxed, items.len });
        for (items, 0..) |c, ci| {
            if (ci < 8) {
                std.debug.print("[cand] {d}: ({d:.2},{d:.2}) module={d:.3} count={d}\n", .{ ci, c.x, c.y, c.module, c.count });
            }
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// 3 点の組み合わせを選ぶ。直角・辺の比・モジュール長の整合で採点する。
fn selectPatterns(pats: []const Candidate, relaxed: bool) ?[3]usize {
    if (pats.len < 3) return null;
    if (pats.len == 3) return .{ 0, 1, 2 };
    const n = @min(pats.len, 24);
    var best: ?[3]usize = null;
    var best_score: f64 = -1.0e18;
    var a: usize = 0;
    while (a < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            var c = b + 1;
            while (c < n) : (c += 1) {
                if (scoreTriple(pats[a], pats[b], pats[c], relaxed)) |s| {
                    if (s > best_score) {
                        best_score = s;
                        best = .{ a, b, c };
                    }
                }
            }
        }
    }
    return best;
}

fn scoreTriple(p: Candidate, q: Candidate, r: Candidate, relaxed: bool) ?f64 {
    const mods = [3]f64{ p.module, q.module, r.module };
    const m_min = @min(mods[0], @min(mods[1], mods[2]));
    const m_max = @max(mods[0], @max(mods[1], mods[2]));
    if (m_min < 1.0) return null;
    // 3 つの位置検出パターンのモジュール長は（多少の遠近を除けば）揃っているはず。
    const module_ratio_limit: f64 = if (relaxed) 1.8 else 1.35;
    if (m_max > m_min * module_ratio_limit) return null;

    const pts = [3]Point{ .{ .x = p.x, .y = p.y }, .{ .x = q.x, .y = q.y }, .{ .x = r.x, .y = r.y } };
    const d01 = distance(pts[0], pts[1]);
    const d12 = distance(pts[1], pts[2]);
    const d02 = distance(pts[0], pts[2]);
    var vertex: usize = 0;
    var hyp_a: usize = 0;
    var hyp_b: usize = 0;
    if (d01 >= d12 and d01 >= d02) {
        vertex = 2;
        hyp_a = 0;
        hyp_b = 1;
    } else if (d12 >= d01 and d12 >= d02) {
        vertex = 0;
        hyp_a = 1;
        hyp_b = 2;
    } else {
        vertex = 1;
        hyp_a = 0;
        hyp_b = 2;
    }
    const v = pts[vertex];
    const e1 = Point{ .x = pts[hyp_a].x - v.x, .y = pts[hyp_a].y - v.y };
    const e2 = Point{ .x = pts[hyp_b].x - v.x, .y = pts[hyp_b].y - v.y };
    const l1 = @sqrt(e1.x * e1.x + e1.y * e1.y);
    const l2 = @sqrt(e2.x * e2.x + e2.y * e2.y);
    if (l1 < 1.0 or l2 < 1.0) return null;
    // 直角の頂点なので 2 辺のなす角は 90 度に近いはず。
    const cos = (e1.x * e2.x + e1.y * e2.y) / (l1 * l2);
    const cos_limit: f64 = if (relaxed) 0.6 else 0.35;
    if (@abs(cos) > cos_limit) return null;
    const leg_ratio = @max(l1, l2) / @min(l1, l2);
    const leg_limit: f64 = if (relaxed) 3.0 else 2.2;
    if (leg_ratio > leg_limit) return null;
    // 2 辺は「辺の長さ / モジュール長」がほぼ同じで、規格上の寸法（17 + 4v）に近いはず。
    const module = (p.module + q.module + r.module) / 3.0;
    const dim_h = @max(l1, l2) / module + 7.0;
    const dim_v = @min(l1, l2) / module + 7.0;
    const dim_avg = (dim_h + dim_v) / 2.0;
    const dim_tol: f64 = if (relaxed) 8.0 else 4.0;
    if (@abs(dim_h - dim_v) > dim_tol) return null;
    const nearest = nearestDimension(dim_avg) orelse return null;
    const dim_dev = @abs(dim_avg - @as(f64, @floatFromInt(nearest)));
    if (dim_dev > dim_tol) return null;

    const counts: f64 = @floatFromInt(p.count + q.count + r.count);
    const spread = (m_max - m_min) / m_min;
    return counts - spread * 12.0 - dim_dev * 2.0 - @abs(cos) * 3.0;
}

/// 3 点を左上・右上・左下に並べる。画像座標（y 下向き）で右手系になるようにする。
fn orderPatterns(a: Candidate, b: Candidate, c: Candidate) [3]Candidate {
    const pts = [3]Candidate{ a, b, c };
    const d01 = distance(.{ .x = pts[0].x, .y = pts[0].y }, .{ .x = pts[1].x, .y = pts[1].y });
    const d12 = distance(.{ .x = pts[1].x, .y = pts[1].y }, .{ .x = pts[2].x, .y = pts[2].y });
    const d02 = distance(.{ .x = pts[0].x, .y = pts[0].y }, .{ .x = pts[2].x, .y = pts[2].y });
    var tl: usize = 0;
    var p: usize = 0;
    var q: usize = 0;
    if (d01 >= d12 and d01 >= d02) {
        tl = 2;
        p = 0;
        q = 1;
    } else if (d12 >= d01 and d12 >= d02) {
        tl = 0;
        p = 1;
        q = 2;
    } else {
        tl = 1;
        p = 0;
        q = 2;
    }
    const origin = Point{ .x = pts[tl].x, .y = pts[tl].y };
    const pa = Point{ .x = pts[p].x, .y = pts[p].y };
    const qa = Point{ .x = pts[q].x, .y = pts[q].y };
    if (cross(pa, qa, origin) >= 0.0) {
        return .{ pts[tl], pts[p], pts[q] };
    }
    return .{ pts[tl], pts[q], pts[p] };
}

// ---------------------------------------------------------------- 寸法の推定

/// 中心から方向 (dx, dy)（単位ベクトル）へ「暗・明・暗」の並びを測り、その長さを返す。
///
/// 位置検出パターンの中心から外へ向かうと、中心の暗ラン（1.5 モジュール）、明の輪
/// （1 モジュール）、外側の暗い枠（1 モジュール）で 3.5 モジュールになる。ZXing の
/// `sizeOfBlackWhiteBlackRun` と同じ考え方。端に達したら null。
fn walkBlackWhiteBlack(bin: *const BitMatrix, cx: f64, cy: f64, dx: f64, dy: f64, max_len: f64) ?f64 {
    var t: f64 = 0.25;
    var state: u8 = 0; // 0 = 中心の暗 / 1 = 明の輪 / 2 = 外側の暗
    while (t <= max_len) : (t += 0.25) {
        const x = cx + dx * t;
        const y = cy + dy * t;
        if (x < 0.0 or y < 0.0) return null;
        const xi: usize = @intFromFloat(@floor(x));
        const yi: usize = @intFromFloat(@floor(y));
        if (xi >= bin.width or yi >= bin.height) return null;
        const dark = bin.get(xi, yi);
        switch (state) {
            0 => if (!dark) {
                state = 1;
            },
            1 => if (dark) {
                state = 2;
            },
            else => if (!dark) return t,
        }
    }
    return null;
}

/// 位置検出パターンの中心から指定方向の両側の暗ラン（7 モジュール分）からモジュール長を
/// 求める。方向は画像軸ではなく「相手の位置検出パターンへ向かう向き」なので、回転して
/// いても正しい値になる。
fn measureModuleAlong(bin: *const BitMatrix, c: Candidate, dx: f64, dy: f64, fallback: f64, max_len: f64) f64 {
    const plus = walkBlackWhiteBlack(bin, c.x, c.y, dx, dy, max_len) orelse return fallback;
    const minus = walkBlackWhiteBlack(bin, c.x, c.y, -dx, -dy, max_len) orelse return fallback;
    const total = plus + minus;
    if (total < 3.0) return fallback;
    return total / 7.0;
}

/// 走査線に沿って明暗の遷移を数える。境界のばたつきは「一定距離同じ色が続いたら遷移と
/// みなす」ことで抑える。
fn countTransitions(bin: *const BitMatrix, from: Point, to: Point, hold_px: f64) ?usize {
    const dist = distance(from, to);
    if (dist < 8.0) return null;
    const steps: usize = @intFromFloat(@ceil(dist / 0.5));
    if (steps < 8) return null;
    const hold_steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(hold_px / 0.5))));

    const Sampler = struct {
        fn at(b: *const BitMatrix, a: Point, c: Point, i: usize, n: usize) bool {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
            const x = a.x + (c.x - a.x) * t;
            const y = a.y + (c.y - a.y) * t;
            const xi = clampUsize(@intFromFloat(@floor(x)), 0, b.width - 1);
            const yi = clampUsize(@intFromFloat(@floor(y)), 0, b.height - 1);
            return b.get(xi, yi);
        }
    };

    var transitions: usize = 0;
    var current = Sampler.at(bin, from, to, 0, steps);
    var candidate_color = current;
    var hold: usize = 0;
    var i: usize = 1;
    while (i <= steps) : (i += 1) {
        const c = Sampler.at(bin, from, to, i, steps);
        if (c == current) {
            hold = 0;
            continue;
        }
        if (c == candidate_color) {
            hold += 1;
        } else {
            candidate_color = c;
            hold = 1;
        }
        if (hold >= hold_steps) {
            current = c;
            hold = 0;
            transitions += 1;
        }
    }
    return transitions;
}

/// タイミングパターンの遷移数から一辺のモジュール数を推定する。
///
/// 左上の中心から右上（または左下）の中心まで、タイミングパターンの行（列）を通る
/// 直線を歩き、明暗の切り替わりを数える。タイミングパターンは 1 モジュールごとに
/// 反転するので、遷移数 = 寸法 - 13 になる（両端の位置検出パターンと分離帯で 4 回）。
/// 遷移の「数」は距離に依存しないため、遠近や回転があっても寸法を誤りにくい。
fn timingDimension(bin: *const BitMatrix, tl: Point, other: Point, offset: Point, module: f64) ?usize {
    const hold = @max(1.0, module * 0.35);
    var counts: [3]usize = undefined;
    var n: usize = 0;
    var k: usize = 0;
    while (k < 3) : (k += 1) {
        const scale = 0.9 + 0.1 * @as(f64, @floatFromInt(k));
        const from = Point{ .x = tl.x + offset.x * scale, .y = tl.y + offset.y * scale };
        const to = Point{ .x = other.x + offset.x * scale, .y = other.y + offset.y * scale };
        const t = countTransitions(bin, from, to, hold) orelse continue;
        counts[n] = t + 13;
        n += 1;
    }
    if (n == 0) return null;
    var best = counts[0];
    var best_hits: usize = 0;
    for (counts[0..n]) |candidate| {
        var hits: usize = 0;
        for (counts[0..n]) |other_count| {
            const diff = if (candidate > other_count) candidate - other_count else other_count - candidate;
            if (diff <= 2) hits += 1;
        }
        if (hits > best_hits) {
            best_hits = hits;
            best = candidate;
        }
    }
    return best;
}

/// 生の推定値に最も近い「規格上の寸法」（17 + 4v）を返す。
fn nearestDimension(raw: f64) ?usize {
    if (raw < 19.0 or raw > 179.0) return null;
    const rounded: isize = @intFromFloat(@round(raw));
    var v = @divTrunc(rounded - 17 + 2, 4);
    v = std.math.clamp(v, 1, 40);
    return 17 + 4 * @as(usize, @intCast(v));
}

/// 寸法候補のリスト（重複なし、優先順）。
const DimensionCandidates = struct {
    dims: [4]usize = @splat(0),
    len: usize = 0,

    fn push(self: *DimensionCandidates, dim: usize) void {
        if (dim < min_size or dim > max_size) return;
        if ((dim - 17) % 4 != 0) return;
        for (self.dims[0..self.len]) |d| {
            if (d == dim) return;
        }
        if (self.len >= self.dims.len) return;
        self.dims[self.len] = dim;
        self.len += 1;
    }
};

// ---------------------------------------------------------------- アラインメント

/// 射影変換の逆写像（画素 → モジュール座標）。ニュートン法で解く。
fn inverseMap(affine: *const Homography, px: f64, py: f64) ?Point {
    var u = px;
    var v = py;
    var iter: usize = 0;
    while (iter < 24) : (iter += 1) {
        const p = affine.map(u, v);
        const ex = p.x - px;
        const ey = p.y - py;
        if (@abs(ex) < 0.02 and @abs(ey) < 0.02) return .{ .x = u, .y = v };
        const eps = 0.25;
        const a = affine.map(u + eps, v);
        const b = affine.map(u, v + eps);
        const j00 = (a.x - p.x) / eps;
        const j10 = (a.y - p.y) / eps;
        const j01 = (b.x - p.x) / eps;
        const j11 = (b.y - p.y) / eps;
        const det = j00 * j11 - j01 * j10;
        if (@abs(det) < 1e-9) return null;
        u -= (j11 * ex - j01 * ey) / det;
        v -= (-j10 * ex + j00 * ey) / det;
    }
    return null;
}

/// 画素位置の色。範囲外は明（false）。
fn samplePixel(bin: *const BitMatrix, p: Point) bool {
    if (p.x < 0.0 or p.y < 0.0) return false;
    const xi: usize = @intFromFloat(@floor(p.x));
    const yi: usize = @intFromFloat(@floor(p.y));
    return bin.get(xi, yi);
}

/// 候補位置が 5×5 のアラインメントパターン（中心が暗・その周りが明・外側が暗）らしいかを
/// 0〜1 で採点する。
fn scoreAlignment(bin: *const BitMatrix, affine: *const Homography, px: f64, py: f64) f64 {
    const base = inverseMap(affine, px, py) orelse return 0.0;
    var score: f64 = 0.0;
    var total: f64 = 0.0;
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const ring: u32 = @max(@abs(dx), @abs(dy));
            const want_dark = ring != 1;
            const weight: f64 = if (ring == 0) 4.0 else if (ring == 1) 2.0 else 1.0;
            const at = affine.map(
                base.x + @as(f64, @floatFromInt(dx)),
                base.y + @as(f64, @floatFromInt(dy)),
            );
            total += weight;
            if (samplePixel(bin, at) == want_dark) score += weight;
        }
    }
    return if (total == 0.0) 0.0 else score / total;
}

/// モジュール座標の 1 ステップ分の画素ベクトル（射影変換の偏微分から）。
fn moduleStepX(affine: *const Homography, u: f64, v: f64) Point {
    const eps = 0.5;
    const a = affine.map(u - eps, v);
    const b = affine.map(u + eps, v);
    const step = Point{ .x = (b.x - a.x) / (2 * eps), .y = (b.y - a.y) / (2 * eps) };
    if (@abs(step.x) + @abs(step.y) < 1e-9) return .{ .x = 1.0, .y = 0.0 };
    return step;
}

fn moduleStepY(affine: *const Homography, u: f64, v: f64) Point {
    const eps = 0.5;
    const a = affine.map(u, v - eps);
    const b = affine.map(u, v + eps);
    const step = Point{ .x = (b.x - a.x) / (2 * eps), .y = (b.y - a.y) / (2 * eps) };
    if (@abs(step.x) + @abs(step.y) < 1e-9) return .{ .x = 0.0, .y = 1.0 };
    return step;
}

/// 矩形領域内をラン走査してアラインメントパターンの候補を集める。
fn scanRunsInRect(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    scanner: *const RunScanner,
    vertical: bool,
    lo: usize,
    hi: usize,
    minor_lo: usize,
    minor_hi: usize,
    module_px: f64,
    out: *std.ArrayList(Candidate),
) Error!void {
    if (hi <= lo or minor_hi <= minor_lo) return;
    var minor = minor_lo;
    while (minor < minor_hi) : (minor += 1) {
        const nruns = buildRuns(scanner, bin, vertical, minor, lo, hi);
        if (nruns < 5) continue;
        var i: usize = 0;
        while (i + 5 <= nruns) : (i += 1) {
            const first_dark = if (vertical)
                bin.get(minor, scanner.starts[i])
            else
                bin.get(scanner.starts[i], minor);
            if (!first_dark) continue;
            var counts: [5]usize = undefined;
            for (0..5) |k| counts[k] = scanner.starts[i + k + 1] - scanner.starts[i + k];
            const module_est = alignRatio(counts, 0.7) orelse continue;
            // モジュール長が想定から離れすぎた候補は落とす（データ領域の偶然を減らす）。
            if (module_est < module_px * 0.4 or module_est > module_px * 2.5) continue;
            // 中心は中央のラン（= 中心の暗モジュール）の中央。
            const major_center = (@as(f64, @floatFromInt(scanner.starts[i + 2])) +
                @as(f64, @floatFromInt(scanner.starts[i + 3]))) / 2.0;
            const minor_center = @as(f64, @floatFromInt(minor)) + 0.5;
            const cx = if (vertical) minor_center else major_center;
            const cy = if (vertical) major_center else minor_center;
            const first = crossCheck(bin, cx, cy, vertical, .alignment, align_ratio, 0.7, null) orelse continue;
            const second = crossCheck(bin, first.x, first.y, !vertical, .alignment, align_ratio, 0.7, null) orelse continue;
            if (out.items.len >= 512) return;
            try out.append(allocator, .{
                .x = second.x,
                .y = second.y,
                .module = (first.module + second.module) / 2.0,
            });
        }
    }
}

/// 右下のアラインメントパターン（5×5）を探す。見つかれば中心の画素座標。
fn findAlignmentPattern(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    affine: *const Homography,
    expected: Point,
    module_px: f64,
    search_modules: f64,
) Error!?Point {
    const radius = @max(4.0, search_modules) * module_px;
    const x0f = @max(0.0, expected.x - radius);
    const y0f = @max(0.0, expected.y - radius);
    const x1f = @min(@as(f64, @floatFromInt(bin.width)), expected.x + radius);
    const y1f = @min(@as(f64, @floatFromInt(bin.height)), expected.y + radius);
    if (x1f - x0f < 3.0 or y1f - y0f < 3.0) return null;
    const lo_x: usize = @intFromFloat(x0f);
    const hi_x: usize = @intFromFloat(@ceil(x1f));
    const lo_y: usize = @intFromFloat(y0f);
    const hi_y: usize = @intFromFloat(@ceil(y1f));

    var candidates: std.ArrayList(Candidate) = .empty;
    defer candidates.deinit(allocator);
    const scanner = try RunScanner.init(allocator, @max(bin.width, bin.height));
    defer scanner.deinit(allocator);

    try scanRunsInRect(allocator, bin, &scanner, false, lo_x, hi_x, lo_y, hi_y, module_px, &candidates);
    try scanRunsInRect(allocator, bin, &scanner, true, lo_y, hi_y, lo_x, hi_x, module_px, &candidates);
    if (candidates.items.len == 0) return null;

    var best: ?Point = null;
    var best_score: f64 = 0.0;
    for (candidates.items) |c| {
        const score = scoreAlignment(bin, affine, c.x, c.y);
        const weighted = score - distance(.{ .x = c.x, .y = c.y }, expected) / @max(module_px, 1.0) * 0.05;
        if (score >= 0.72 and weighted > best_score) {
            best_score = weighted;
            best = .{ .x = c.x, .y = c.y };
        }
    }
    const coarse = best orelse return null;

    // 0.1 モジュール刻みで中心を詰める（テンプレートの当たりが最も良い位置へ）。
    var refined = coarse;
    var best_raw = scoreAlignment(bin, affine, refined.x, refined.y);
    const step_x = moduleStepX(affine, coarse.x, coarse.y);
    const step_y = moduleStepY(affine, coarse.x, coarse.y);
    var du: f64 = -0.4;
    while (du <= 0.41) : (du += 0.1) {
        var dv: f64 = -0.4;
        while (dv <= 0.41) : (dv += 0.1) {
            const x = coarse.x + du * step_x.x + dv * step_y.x;
            const y = coarse.y + du * step_x.y + dv * step_y.y;
            const s = scoreAlignment(bin, affine, x, y);
            if (s > best_raw) {
                best_raw = s;
                refined = .{ .x = x, .y = y };
            }
        }
    }
    return refined;
}

// ---------------------------------------------------------------- 格子の抽出

/// 射影変換に従って各モジュールの中心を 5 点サンプリング（多数決）する。
fn sampleGrid(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    transform: *const Homography,
    dim: usize,
) Error!BitMatrix {
    var grid = try BitMatrix.init(allocator, dim, dim);
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            const u = @as(f64, @floatFromInt(x)) + 0.5;
            const v = @as(f64, @floatFromInt(y)) + 0.5;
            var dark: usize = 0;
            if (samplePixel(bin, transform.map(u, v))) dark += 1;
            if (samplePixel(bin, transform.map(u - 0.3, v))) dark += 1;
            if (samplePixel(bin, transform.map(u + 0.3, v))) dark += 1;
            if (samplePixel(bin, transform.map(u, v - 0.3))) dark += 1;
            if (samplePixel(bin, transform.map(u, v + 0.3))) dark += 1;
            if (dark >= 3) grid.set(x, y);
        }
    }
    return grid;
}

/// 転置した格子を作る（鏡像・裏返しの画像への保険）。
fn transposeGrid(allocator: std.mem.Allocator, grid: *const BitMatrix) Error!BitMatrix {
    const dim = grid.width;
    var out = try BitMatrix.init(allocator, dim, dim);
    var y: usize = 0;
    while (y < dim) : (y += 1) {
        var x: usize = 0;
        while (x < dim) : (x += 1) {
            if (grid.get(y, x)) out.set(x, y);
        }
    }
    return out;
}

// ---------------------------------------------------------------- 機能モジュール

/// アラインメントパターンの中心位置（規格 Annex E）。`pos[0..len]` を使う。
const AlignmentPositions = struct {
    pos: [7]usize = @splat(0),
    len: usize = 0,
};

/// バージョンごとのアラインメントパターン中心（qrcodegen と同じ導出）。
fn alignmentPositions(version: u8) AlignmentPositions {
    const size = 17 + 4 * @as(usize, version);
    const num: usize = version / 7 + 2;
    const step: usize = if (version == 32)
        26
    else
        (@as(usize, version) * 4 + num * 2 + 1) / (num * 2 - 2) * 2;
    var out = AlignmentPositions{ .len = num };
    out.pos[0] = 6;
    // 最後の位置が「一辺 - 7」で、そこから step ずつ左へ戻る。
    var i: usize = 1;
    while (i < num) : (i += 1) {
        out.pos[i] = size - 7 - (num - 1 - i) * step;
    }
    return out;
}

fn markRect(func: *BitMatrix, x0: usize, y0: usize, w: usize, h: usize) void {
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            func.set(x0 + x, y0 + y);
        }
    }
}

/// 機能モジュール（データを含まないモジュール）の地図を作る。座標は (x = 列, y = 行)。
fn buildFunctionMap(func: *BitMatrix, dim: usize, version: u8) void {
    // 位置検出パターン + 分離帯 + format 情報（9×9 の角 3 つ）。
    markRect(func, 0, 0, 9, 9);
    markRect(func, dim - 8, 0, 8, 9);
    markRect(func, 0, dim - 8, 9, 8);
    // タイミングパターン。
    var i: usize = 8;
    while (i < dim - 8) : (i += 1) {
        func.set(i, 6);
        func.set(6, i);
    }
    // アラインメントパターン（位置検出パターンと重なる 3 つは置かれない）。
    if (version >= 2) {
        const ap = alignmentPositions(version);
        for (0..ap.len) |a| {
            for (0..ap.len) |b| {
                const skip = (a == 0 and b == 0) or (a == 0 and b == ap.len - 1) or
                    (a == ap.len - 1 and b == 0);
                if (skip) continue;
                markRect(func, ap.pos[a] - 2, ap.pos[b] - 2, 5, 5);
            }
        }
    }
    // version 情報（バージョン 7 以上）。
    if (version >= 7) {
        for (0..18) |k| {
            const a = dim - 11 + k % 3;
            const c = k / 3;
            func.set(a, c);
            func.set(c, a);
        }
    }
}

// ---------------------------------------------------------------- format / version

const FormatResult = struct {
    ec: qr.EcLevel,
    mask: u3,
    distance: u3,
};

/// (x, y) のモジュールを 0/1 で返す（x = 列、y = 行）。
fn bitAt(grid: *const BitMatrix, x: usize, y: usize) u32 {
    return @intFromBool(grid.get(x, y));
}

/// 規格 Table C.1 の有効な format 情報 32 通り。添字は (EC ビット << 3) | マスク。
const format_codes: [32]u15 = blk: {
    var table: [32]u15 = undefined;
    for (0..32) |k| {
        const data: u32 = @intCast(k);
        var rem: u32 = data;
        for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        table[k] = @intCast(((data << 10) | rem) ^ 0x5412);
    }
    break :blk table;
};

/// 規格 Table D.1 の有効な version 情報（バージョン 7〜40）。添字はバージョン。
const version_codes: [41]u18 = blk: {
    var table: [41]u18 = @splat(0);
    for (7..41) |v| {
        const data: u32 = @intCast(v);
        var rem: u32 = data;
        for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        table[v] = @intCast((data << 12) | rem);
    }
    break :blk table;
};

fn ecFromFormatBits(bits: u2) qr.EcLevel {
    return switch (bits) {
        0b01 => .l,
        0b00 => .m,
        0b11 => .q,
        else => .h,
    };
}

/// format 情報を 2 か所から読み、ハミング距離が最小の有効な組み合わせを返す。
fn readFormat(grid: *const BitMatrix, dim: usize) ?FormatResult {
    var copy1: u32 = 0;
    var i: usize = 0;
    while (i < 6) : (i += 1) copy1 |= bitAt(grid, 8, i) << @intCast(i);
    copy1 |= bitAt(grid, 8, 7) << 6;
    copy1 |= bitAt(grid, 8, 8) << 7;
    copy1 |= bitAt(grid, 7, 8) << 8;
    i = 9;
    while (i < 15) : (i += 1) copy1 |= bitAt(grid, 14 - i, 8) << @intCast(i);

    var copy2: u32 = 0;
    i = 0;
    while (i < 8) : (i += 1) copy2 |= bitAt(grid, dim - 1 - i, 8) << @intCast(i);
    i = 8;
    while (i < 15) : (i += 1) copy2 |= bitAt(grid, 8, dim - 15 + i) << @intCast(i);

    var best: ?FormatResult = null;
    var best_distance: u32 = 4;
    for (format_codes, 0..) |code, k| {
        const c: u32 = code;
        const d1: u32 = @popCount(c ^ copy1);
        const d2: u32 = @popCount(c ^ copy2);
        const d = @min(d1, d2);
        if (d < best_distance) {
            best_distance = d;
            best = .{
                .ec = ecFromFormatBits(@intCast(k >> 3)),
                .mask = @intCast(k & 7),
                .distance = @intCast(d),
            };
        }
    }
    return best;
}

const VersionResult = struct { version: u8, distance: u3 };

/// version 情報（18 ビット、2 か所）を読み、ハミング距離が最小の有効な値を返す。
fn readVersionInfo(grid: *const BitMatrix, dim: usize) ?VersionResult {
    var copy1: u32 = 0;
    var copy2: u32 = 0;
    for (0..18) |i| {
        const a = dim - 11 + i % 3;
        const c = i / 3;
        copy1 |= bitAt(grid, a, c) << @intCast(i);
        copy2 |= bitAt(grid, c, a) << @intCast(i);
    }
    var best: ?VersionResult = null;
    var best_distance: u32 = 4;
    for (7..41) |v| {
        const code: u32 = version_codes[v];
        const d1: u32 = @popCount(code ^ copy1);
        const d2: u32 = @popCount(code ^ copy2);
        const d = @min(d1, d2);
        if (d < best_distance) {
            best_distance = d;
            best = .{ .version = @intCast(v), .distance = @intCast(d) };
        }
    }
    return best;
}

// ---------------------------------------------------------------- データ読み出し

/// マスクパターン（規格 Table 10）。true なら反転する。x = 列、y = 行。
fn maskBit(mask: u3, x: usize, y: usize) bool {
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

/// ジグザグ（右下から 2 列ずつ、上下交互）に読み出してマスクを外す。
fn readCodewords(
    grid: *const BitMatrix,
    func: *const BitMatrix,
    dim: usize,
    mask: u3,
    out: []u8,
) Error!void {
    const total_bits = out.len * 8;
    var bit: usize = 0;
    var right: usize = dim - 1;
    while (true) {
        if (right == 6) right = 5; // タイミング列を飛ばす
        var vert: usize = 0;
        while (vert < dim) : (vert += 1) {
            var j: usize = 0;
            while (j < 2) : (j += 1) {
                const x = right - j;
                const upward = ((right + 1) & 2) == 0;
                const y = if (upward) dim - 1 - vert else vert;
                if (func.get(x, y)) continue;
                if (bit < total_bits) {
                    const dark = grid.get(x, y) != maskBit(mask, x, y);
                    if (dark) out[bit >> 3] |= @as(u8, 1) << @intCast(7 - (bit & 7));
                    bit += 1;
                }
            }
        }
        if (right < 2) break;
        right -= 2;
    }
    if (bit != total_bits) return Error.InvalidSymbol;
}

// ---------------------------------------------------------------- 容量テーブル

/// ブロックあたりの誤り訂正コードワード数（規格 Table 9）。添字は [EC][version]。
/// qr.zig と同じ値（テストで qr.zig の公開 API と突き合わせる）。
const ecc_codewords_per_block = [4][41]u8{
    .{ 0, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ 0, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ 0, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

/// 誤り訂正ブロック数（規格 Table 9）。添字は [EC][version]。
const num_ec_blocks = [4][41]u8{
    .{ 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ 0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ 0, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ 0, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// QR の 1 ブロックの最大長（データ + ECC）は 186（バージョン 40-L）なので 255 で足りる。
const max_block_len = 255;
const max_ec_codewords = 30;
const max_errors = max_ec_codewords / 2;
const max_blocks = 81;

// ---------------------------------------------------------------- GF(2^8) と RS

/// GF(2^8)（原始多項式 0x11D、生成多項式の根は α^0 から）。
const gf_exp: [512]u8 = blk: {
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

const gf_log: [256]u8 = blk: {
    var table: [256]u8 = @splat(0);
    for (0..255) |i| table[gf_exp[i]] = @intCast(i);
    break :blk table;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + @as(usize, gf_log[b])];
}

fn gfInv(a: u8) u8 {
    return gf_exp[255 - @as(usize, gf_log[a])];
}

fn gfPow(a: u8, e: usize) u8 {
    if (a == 0) return 0;
    return gf_exp[(@as(usize, gf_log[a]) * e) % 255];
}

/// Reed-Solomon 訂正の作業領域（すべてスタック上、確保なし）。
const RsScratch = struct {
    syndromes: [max_ec_codewords]u8 = @splat(0),
    locator: [max_errors + 1]u8 = @splat(0),
    matrix: [max_errors * (max_errors + 1)]u8 = @splat(0),
    positions: [max_errors]usize = @splat(0),
    roots: [max_errors]u8 = @splat(0),
    magnitudes: [max_errors]u8 = @splat(0),
    work: [max_block_len]u8 = @splat(0),
};

/// GF(256) の連立一次方程式を掃き出し法で解く。`a` は rows × (cols+1) の行優先。
/// 解が一意でなければ false。
fn solveLinear(a: []u8, rows: usize, cols: usize, x: []u8) bool {
    const stride = cols + 1;
    var prow: usize = 0;
    var col: usize = 0;
    while (col < cols and prow < rows) : (col += 1) {
        var sel: ?usize = null;
        var r = prow;
        while (r < rows) : (r += 1) {
            if (a[r * stride + col] != 0) {
                sel = r;
                break;
            }
        }
        const p = sel orelse continue;
        if (p != prow) {
            var c: usize = col;
            while (c < stride) : (c += 1) {
                const tmp = a[p * stride + c];
                a[p * stride + c] = a[prow * stride + c];
                a[prow * stride + c] = tmp;
            }
        }
        const inv = gfInv(a[prow * stride + col]);
        var c: usize = col;
        while (c < stride) : (c += 1) a[prow * stride + c] = gfMul(a[prow * stride + c], inv);
        for (0..rows) |rr| {
            if (rr == prow) continue;
            const factor = a[rr * stride + col];
            if (factor == 0) continue;
            c = col;
            while (c < stride) : (c += 1) {
                a[rr * stride + c] ^= gfMul(factor, a[prow * stride + c]);
            }
        }
        prow += 1;
    }
    if (prow != cols) return false;
    for (0..cols) |i| x[i] = a[i * stride + cols];
    return true;
}

/// 仮定した誤り数 `nu` で訂正を試す。成功したら誤り数を、だめなら null を返す。
fn tryCorrectCount(cw: []u8, nsym: usize, nu: usize, scratch: *RsScratch) ?usize {
    const n = cw.len;
    const stride = nu + 1;
    // 誤り位置多項式 Λ の係数（Λ_1..Λ_ν）を PGZ の連立方程式から求める。
    for (0..nu) |i| {
        for (0..nu) |j| scratch.matrix[i * stride + j] = scratch.syndromes[i + nu - 1 - j];
        scratch.matrix[i * stride + nu] = scratch.syndromes[i + nu];
    }
    if (!solveLinear(scratch.matrix[0 .. nu * stride], nu, nu, scratch.locator[1 .. nu + 1])) return null;
    scratch.locator[0] = 1;

    // Chien 探索: Λ(α^-p) = 0 となる p を探す。誤り位置は指数 p（X = α^p）。
    var found: usize = 0;
    var p: usize = 0;
    while (p < n) : (p += 1) {
        const x = gf_exp[(255 - (p % 255)) % 255];
        var acc: u8 = 0;
        var k = nu + 1;
        while (k > 0) {
            k -= 1;
            acc = gfMul(acc, x) ^ scratch.locator[k];
        }
        if (acc == 0) {
            if (found >= nu) return null;
            scratch.positions[found] = n - 1 - p;
            scratch.roots[found] = gf_exp[p % 255];
            found += 1;
        }
    }
    if (found != nu) return null;

    // 誤りの大きさ: Σ_k e_k X_k^i = S_i (i = 0..ν-1) を解く。
    for (0..nu) |i| {
        for (0..nu) |k| scratch.matrix[i * stride + k] = gfPow(scratch.roots[k], i);
        scratch.matrix[i * stride + nu] = scratch.syndromes[i];
    }
    if (!solveLinear(scratch.matrix[0 .. nu * stride], nu, nu, scratch.magnitudes[0..nu])) return null;

    @memcpy(scratch.work[0..n], cw);
    for (0..nu) |k| scratch.work[scratch.positions[k]] ^= scratch.magnitudes[k];
    // 検算: 訂正後のシンドロームがすべて 0 でなければ、この仮定は誤り。
    for (0..nsym) |i| {
        var s: u8 = 0;
        const x = gf_exp[i];
        for (scratch.work[0..n]) |c| s = gfMul(s, x) ^ c;
        if (s != 0) return null;
    }
    @memcpy(cw, scratch.work[0..n]);
    return nu;
}

/// 1 ブロック（データ + ECC）をその場で誤り訂正する。訂正した個数を返す。
fn rsCorrect(cw: []u8, nsym: usize, scratch: *RsScratch) Error!usize {
    const n = cw.len;
    if (n > max_block_len or nsym == 0 or nsym >= n) return Error.InvalidSymbol;
    var nonzero = false;
    for (0..nsym) |i| {
        var s: u8 = 0;
        const x = gf_exp[i];
        for (cw) |c| s = gfMul(s, x) ^ c;
        scratch.syndromes[i] = s;
        if (s != 0) nonzero = true;
    }
    if (!nonzero) return 0;

    const t = nsym / 2;
    var nu: usize = 1;
    while (nu <= t) : (nu += 1) {
        if (tryCorrectCount(cw, nsym, nu, scratch)) |count| return count;
    }
    return Error.TooManyErrors;
}

/// インターリーブを解いてブロックごとに訂正し、データコードワードを連結する。
fn correctAndExtract(
    allocator: std.mem.Allocator,
    raw: []const u8,
    ec: qr.EcLevel,
    version: u8,
    data_out: []u8,
) Error!void {
    const ei = ec.index();
    const nblocks: usize = num_ec_blocks[ei][version];
    const ecc_per: usize = ecc_codewords_per_block[ei][version];
    if (nblocks == 0 or ecc_per == 0 or nblocks > max_blocks) return Error.InvalidSymbol;
    const total_data = qr.dataCodewords(ec, version);
    if (data_out.len != total_data) return Error.InvalidSymbol;
    if (raw.len < total_data + nblocks * ecc_per) return Error.InvalidSymbol;

    const short_len = total_data / nblocks;
    const num_long = total_data % nblocks;
    const max_dlen = short_len + @intFromBool(num_long > 0);
    // 規格 7.6: データ長が 1 多いブロックは**最後**に置かれる（qr.zig / ZXing / segno と同じ）。
    const first_long = nblocks - num_long;

    // 作業領域は「ブロックごとに [データ | ECC] が連続」するように置く。
    var region: [max_blocks]usize = @splat(0);
    var data_start: [max_blocks]usize = @splat(0);
    var acc: usize = 0;
    var dacc: usize = 0;
    for (0..nblocks) |b| {
        const dlen = short_len + @intFromBool(b >= first_long);
        region[b] = acc;
        data_start[b] = dacc;
        acc += dlen + ecc_per;
        dacc += dlen;
    }

    const work = try allocator.alloc(u8, raw.len);
    defer allocator.free(work);

    // データ部のインターリーブを解く。
    var pos: usize = 0;
    var k: usize = 0;
    while (k < max_dlen) : (k += 1) {
        for (0..nblocks) |b| {
            const dlen = short_len + @intFromBool(b >= first_long);
            if (k < dlen) {
                work[region[b] + k] = raw[pos];
                pos += 1;
            }
        }
    }
    // ECC 部のインターリーブを解く。
    for (0..ecc_per) |j| {
        for (0..nblocks) |b| {
            const dlen = short_len + @intFromBool(b >= first_long);
            work[region[b] + dlen + j] = raw[pos];
            pos += 1;
        }
    }

    var scratch: RsScratch = .{};
    for (0..nblocks) |b| {
        const dlen = short_len + @intFromBool(b >= first_long);
        const block = work[region[b] .. region[b] + dlen + ecc_per];
        const corrected = try rsCorrect(block, ecc_per, &scratch);
        if (trace) {
            std.debug.print("[rs] block {d}/{d} dlen={d} ecc={d} corrected={d} first={x:0>2},{x:0>2},{x:0>2},{x:0>2}\n", .{ b, nblocks, dlen, ecc_per, corrected, block[0], block[1], block[2], block[3] });
        }
        @memcpy(data_out[data_start[b] .. data_start[b] + dlen], work[region[b] .. region[b] + dlen]);
    }
}

// ---------------------------------------------------------------- ビット列の解釈

const BitReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: *const BitReader) usize {
        return self.data.len * 8 - self.pos;
    }

    fn read(self: *BitReader, count: usize) Error!u32 {
        if (count > 32) return Error.InvalidSymbol;
        if (self.pos + count > self.data.len * 8) return Error.Truncated;
        var v: u32 = 0;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const bit = (self.data[self.pos >> 3] >> @intCast(7 - (self.pos & 7))) & 1;
            v = (v << 1) | bit;
            self.pos += 1;
        }
        return v;
    }
};

/// 英数字モードの文字集合（規格 Table 5）。
const alphanumeric_charset = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:";

fn parseNumeric(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.numeric.charCountBits(version));
    var left = count;
    while (left >= 3) : (left -= 3) {
        const v = try reader.read(10);
        if (v > 999) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v / 100));
        try sink.writeByte(@intCast('0' + (v / 10) % 10));
        try sink.writeByte(@intCast('0' + v % 10));
    }
    if (left == 2) {
        const v = try reader.read(7);
        if (v > 99) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v / 10));
        try sink.writeByte(@intCast('0' + v % 10));
    } else if (left == 1) {
        const v = try reader.read(4);
        if (v > 9) return Error.InvalidSymbol;
        try sink.writeByte(@intCast('0' + v));
    }
}

fn parseAlphanumeric(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.alphanumeric.charCountBits(version));
    var left = count;
    while (left >= 2) : (left -= 2) {
        const v = try reader.read(11);
        if (v >= 45 * 45) return Error.InvalidSymbol;
        try sink.writeByte(alphanumeric_charset[v / 45]);
        try sink.writeByte(alphanumeric_charset[v % 45]);
    }
    if (left == 1) {
        const v = try reader.read(6);
        if (v >= 45) return Error.InvalidSymbol;
        try sink.writeByte(alphanumeric_charset[v]);
    }
}

fn parseByte(reader: *BitReader, version: u8, sink: *Sink) Error!void {
    const count = try reader.read(qr.Mode.byte.charCountBits(version));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const b = try reader.read(8);
        try sink.writeByte(@intCast(b));
    }
}

/// モード指示子を順に解釈してテキストを書き出す。
fn parseBitStream(data: []const u8, version: u8, sink: *Sink) Error!void {
    var reader = BitReader{ .data = data };
    while (reader.remaining() >= 4) {
        const mode = try reader.read(4);
        switch (mode) {
            0b0000 => return, // ターミネータ
            0b0001 => try parseNumeric(&reader, version, sink),
            0b0010 => try parseAlphanumeric(&reader, version, sink),
            0b0100 => try parseByte(&reader, version, sink),
            // 構造的連接・FNC1・ECI・漢字（JIS / GB2312）は未対応。
            0b0011, 0b0101, 0b0111, 0b1000, 0b1001, 0b1101 => return Error.UnsupportedMode,
            else => return Error.InvalidSymbol,
        }
    }
}

// ---------------------------------------------------------------- 1 シンボルの復号

/// 格子の 3 隅に位置検出パターン（7×7）が正しく現れているか。
///
/// QR ではない画像（文章の画面など）を「QR らしいが見つからない」と誤って報告しない
/// ための確認と、明らかに違う格子を早めに捨てるための足切りを兼ねる。
fn gridLooksLikeQr(grid: *const BitMatrix, dim: usize) bool {
    const origins = [3][2]usize{ .{ 0, 0 }, .{ dim - 7, 0 }, .{ 0, dim - 7 } };
    var mismatch: usize = 0;
    for (origins) |o| {
        var y: usize = 0;
        while (y < 7) : (y += 1) {
            var x: usize = 0;
            while (x < 7) : (x += 1) {
                // 中心 (3,3) からのチェビシェフ距離: 0-1 が暗、2 が明、3 が暗。
                const dx = if (x > 3) x - 3 else 3 - x;
                const dy = if (y > 3) y - 3 else 3 - y;
                const cheb = @max(dx, dy);
                const want = cheb != 2;
                if (grid.get(o[0] + x, o[1] + y) != want) mismatch += 1;
            }
        }
    }
    return mismatch <= 12;
}

/// 格子（モジュール行列）からテキストを取り出す。失敗したら false（別候補を試す）。
fn decodeGrid(
    allocator: std.mem.Allocator,
    grid: *const BitMatrix,
    dim: usize,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!bool {
    if (dim < min_size or dim > max_size or (dim - 17) % 4 != 0) return false;
    if (!gridLooksLikeQr(grid, dim)) return false;
    confirmed.* = true;
    const version: u8 = @intCast((dim - 17) / 4);
    const fmt = readFormat(grid, dim) orelse {
        if (trace) std.debug.print("[grid] dim={d} format NG\n", .{dim});
        return false;
    };
    if (trace) std.debug.print("[grid] dim={d} v={d} ec={s} mask={d} dist={d}\n", .{ dim, (dim - 17) / 4, fmt.ec.name(), fmt.mask, fmt.distance });

    // バージョン 7 以上は version 情報でも照合する（食い違えば格子が疑わしい）。
    if (version >= 7) {
        if (readVersionInfo(grid, dim)) |v| {
            if (v.distance <= 1 and v.version != version) return false;
        }
    }

    if (trace and dim <= 45) {
        var yy: usize = 0;
        while (yy < dim) : (yy += 1) {
            var buf: [200]u8 = @splat('.');
            var xx: usize = 0;
            while (xx < dim) : (xx += 1) {
                if (grid.get(xx, yy)) buf[xx] = '#';
            }
            std.debug.print("GRID {s}\n", .{buf[0..dim]});
        }
    }
    var func = try BitMatrix.init(allocator, dim, dim);
    defer func.deinit(allocator);
    buildFunctionMap(&func, dim, version);

    const raw_len = qr.rawCodewords(version);
    const data_len = qr.dataCodewords(fmt.ec, version);
    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    @memset(raw, 0);
    try readCodewords(grid, &func, dim, fmt.mask, raw);

    const data = try allocator.alloc(u8, data_len);
    defer allocator.free(data);
    correctAndExtract(allocator, raw, fmt.ec, version, data) catch |e| switch (e) {
        Error.TooManyErrors => {
            if (trace) std.debug.print("[grid] dim={d} RS NG\n", .{dim});
            return false;
        },
        else => return e,
    };

    parseBitStream(data, version, sink) catch |e| switch (e) {
        Error.UnsupportedMode, Error.BufferTooSmall, Error.OutOfMemory => return e,
        else => return false,
    };
    info.* = .{
        .text = sink.text(),
        .version = version,
        .ec = fmt.ec,
        .mask = fmt.mask,
    };
    return true;
}

/// 1 回の試行の結果。
const AttemptResult = enum {
    /// 位置検出パターンの組が見つからなかった
    not_found,
    /// 見つかったが復号できなかった
    corrupt,
    /// 復号できた
    ok,
};

/// 3 点組とその採点（スコア降順に並べる）。
const TripleScore = struct {
    score: f64,
    idx: [3]usize,
};

/// すべての 3 点組を採点してスコアの降順に並べる（上位だけを使う）。
fn collectTriples(
    allocator: std.mem.Allocator,
    pats: []const Candidate,
    relaxed: bool,
    out: *std.ArrayList(TripleScore),
) Error!void {
    if (pats.len < 3) return;
    const n = @min(pats.len, 24);
    var a: usize = 0;
    while (a < n) : (a += 1) {
        var b = a + 1;
        while (b < n) : (b += 1) {
            var c = b + 1;
            while (c < n) : (c += 1) {
                const score = scoreTriple(pats[a], pats[b], pats[c], relaxed) orelse continue;
                try out.append(allocator, .{ .score = score, .idx = .{ a, b, c } });
            }
        }
    }
    std.sort.pdq(TripleScore, out.items, {}, struct {
        fn lessThan(_: void, x: TripleScore, y: TripleScore) bool {
            return x.score > y.score;
        }
    }.lessThan);
}

/// 見つけた位置検出パターンから 1 シンボルの復号を試す。
fn tryPatterns(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    pats: []const Candidate,
    relaxed: bool,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!AttemptResult {
    var triples: std.ArrayList(TripleScore) = .empty;
    defer triples.deinit(allocator);
    try collectTriples(allocator, pats, relaxed, &triples);
    if (triples.items.len == 0) return .not_found;

    const limit = @min(triples.items.len, 6);
    var sampled = false;
    // 1 周目はタイミングパターンと整合する組だけ、2 周目で残りを試す。
    var phase: usize = 0;
    while (phase < 2) : (phase += 1) {
        const want_consistent = phase == 0;
        for (triples.items[0..limit]) |ts| {
            const ordered = orderPatterns(pats[ts.idx[0]], pats[ts.idx[1]], pats[ts.idx[2]]);
            const tl = ordered[0];
            const tr = ordered[1];
            const bl = ordered[2];

            const tl_pt = Point{ .x = tl.x, .y = tl.y };
            const tr_pt = Point{ .x = tr.x, .y = tr.y };
            const bl_pt = Point{ .x = bl.x, .y = bl.y };
            const dist_h = distance(tl_pt, tr_pt);
            const dist_v = distance(tl_pt, bl_pt);
            if (dist_h < 10.0 or dist_v < 10.0) continue;

            // 方向ごとのモジュール長（回転していても正しい値になる測り方）。
            const ux = (tr.x - tl.x) / dist_h;
            const uy = (tr.y - tl.y) / dist_h;
            const vx = (bl.x - tl.x) / dist_v;
            const vy = (bl.y - tl.y) / dist_v;
            const run_module = (tl.module + tr.module + bl.module) / 3.0;
            // 位置検出パターンの暗ランは 7 モジュール分。相手との距離から上限を見積もる
            // （いちばん短い辺でも 14 モジュールなので 0.35 倍あれば足りる）。
            const walk_limit = @max(8.0, 0.35 * @min(dist_h, dist_v));
            const m_h_tl = measureModuleAlong(bin, tl, ux, uy, run_module, walk_limit);
            const m_h_tr = measureModuleAlong(bin, tr, ux, uy, run_module, walk_limit);
            const m_v_tl = measureModuleAlong(bin, tl, vx, vy, run_module, walk_limit);
            const m_v_bl = measureModuleAlong(bin, bl, vx, vy, run_module, walk_limit);
            const m_h = (m_h_tl + m_h_tr) / 2.0;
            const m_v = (m_v_tl + m_v_bl) / 2.0;
            if (m_h < 1.0 or m_v < 1.0) continue;

            // モジュール座標系の基底（1 モジュール分の画素ベクトル）。
            const dm_h = dist_h / m_h;
            const dm_v = dist_v / m_v;
            if (dm_h < 10.0 or dm_v < 10.0) continue;
            const ex = Point{ .x = (tr.x - tl.x) / dm_h, .y = (tr.y - tl.y) / dm_h };
            const ey = Point{ .x = (bl.x - tl.x) / dm_v, .y = (bl.y - tl.y) / dm_v };

            // タイミングパターンの遷移数から寸法を測る（距離に依存しないので遠近に強い）。
            const dim_timing_h = timingDimension(
                bin,
                tl_pt,
                tr_pt,
                .{ .x = ey.x * 3.0, .y = ey.y * 3.0 * (m_h_tr / @max(m_h_tl, 0.5)) },
                m_h,
            );
            const dim_timing_v = timingDimension(
                bin,
                tl_pt,
                bl_pt,
                .{ .x = ex.x * 3.0 * (m_v_bl / @max(m_v_tl, 0.5)), .y = ex.y * 3.0 },
                m_v,
            );
            const dim_geo_raw = (dm_h + dm_v) / 2.0 + 7.0;

            var timing_raw: ?f64 = null;
            if (dim_timing_h != null and dim_timing_v != null) {
                const ta: f64 = @floatFromInt(dim_timing_h.?);
                const tb: f64 = @floatFromInt(dim_timing_v.?);
                if (@abs(ta - tb) <= 4.0) timing_raw = (ta + tb) / 2.0;
            } else if (dim_timing_h) |t| {
                timing_raw = @floatFromInt(t);
            } else if (dim_timing_v) |t| {
                timing_raw = @floatFromInt(t);
            }
            const consistent = if (timing_raw) |t| @abs(t - dim_geo_raw) <= 5.0 else false;
            if (consistent != want_consistent) continue;
            if (trace) {
                std.debug.print("[att] phase={d} score={d:.1} tl=({d:.1},{d:.1}) tr=({d:.1},{d:.1}) bl=({d:.1},{d:.1}) mh={d:.3} mv={d:.3} dim_t=({?},{?}) geo={d:.1}\n", .{ phase, ts.score, tl.x, tl.y, tr.x, tr.y, bl.x, bl.y, m_h, m_v, dim_timing_h, dim_timing_v, dim_geo_raw });
            }

            // 寸法の候補（優先順）。タイミング → 幾何 → ±1 段。
            var dims: DimensionCandidates = .{};
            if (timing_raw) |t| {
                if (nearestDimension(t)) |d| dims.push(d);
            }
            if (nearestDimension(dim_geo_raw)) |d| dims.push(d);
            if (dims.len > 0) {
                const first = dims.dims[0];
                if (first >= 25) {
                    dims.push(first - 4);
                    dims.push(first + 4);
                }
            }
            if (dims.len == 0) continue;

            for (dims.dims[0..dims.len]) |dim| {
                const df: f64 = @floatFromInt(dim);
                // 4 点目は右下（アラインメント中心、無ければ平行四辺形の頂点）。
                const br = Point{ .x = tr.x + bl.x - tl.x, .y = tr.y + bl.y - tl.y };
                var transform = solveHomography(
                    .{ .{ .x = 3.5, .y = 3.5 }, .{ .x = df - 3.5, .y = 3.5 }, .{ .x = 3.5, .y = df - 3.5 }, .{ .x = df - 3.5, .y = df - 3.5 } },
                    .{ tl_pt, tr_pt, bl_pt, br },
                ) orelse continue;

                const module_px = (m_h + m_v) / 2.0;
                if (dim >= 25) {
                    const expected = transform.map(df - 6.5, df - 6.5);
                    const search_modules = @max(4.0, df / 8.0);
                    if (try findAlignmentPattern(allocator, bin, &transform, expected, module_px, search_modules)) |center| {
                        if (trace) {
                            std.debug.print("[att] dim={d} align=({d:.2},{d:.2}) expected=({d:.1},{d:.1})\n", .{ dim, center.x, center.y, expected.x, expected.y });
                        }
                        if (solveHomography(
                            .{ .{ .x = 3.5, .y = 3.5 }, .{ .x = df - 3.5, .y = 3.5 }, .{ .x = 3.5, .y = df - 3.5 }, .{ .x = df - 6.5, .y = df - 6.5 } },
                            .{ tl_pt, tr_pt, bl_pt, center },
                        )) |t2| {
                            transform = t2;
                        }
                    }
                }

                var grid = try sampleGrid(allocator, bin, &transform, dim);
                defer grid.deinit(allocator);
                sampled = true;

                sink.reset();
                if (try decodeGrid(allocator, &grid, dim, sink, info, confirmed)) return .ok;

                // 鏡像（裏返し）で撮られた場合の保険として転置でも試す。
                var flipped = try transposeGrid(allocator, &grid);
                defer flipped.deinit(allocator);
                sink.reset();
                if (try decodeGrid(allocator, &flipped, dim, sink, info, confirmed)) return .ok;
            }
        }
    }
    return if (sampled) .corrupt else .not_found;
}

/// 二値画像 1 枚から 1 シンボルを取り出す。
///
/// まず厳しく（分離帯の判定つきで）探し、だめなら緩く探し直す。
fn attemptDecode(
    allocator: std.mem.Allocator,
    bin: *const BitMatrix,
    sink: *Sink,
    info: *Info,
    confirmed: *bool,
) Error!AttemptResult {
    var detected = false;
    var relaxed = false;
    while (true) {
        const pats = try findFinderPatterns(allocator, bin, relaxed);
        defer allocator.free(pats);
        const result = try tryPatterns(allocator, bin, pats, relaxed, sink, info, confirmed);
        if (result == .ok) return .ok;
        if (result == .corrupt) detected = true;
        if (relaxed) break;
        relaxed = true;
    }
    return if (detected) .corrupt else .not_found;
}

/// 二値化の条件を変えながら復号を試す。
fn decodeInternal(
    allocator: std.mem.Allocator,
    image: *const Image,
    sink: *Sink,
    info: *Info,
) Error!void {
    if (image.width == 0 or image.height == 0) return Error.SymbolNotFound;
    if (image.width > max_image_dim or image.height > max_image_dim) return Error.SymbolNotFound;
    const need = image.width * image.height;
    if (image.pixels.len < need) return Error.Truncated;

    var bin = try BitMatrix.init(allocator, image.width, image.height);
    defer bin.deinit(allocator);
    const sub_w = (image.width + 7) / 8;
    const sub_h = (image.height + 7) / 8;
    const black_points = try allocator.alloc(u8, sub_w * sub_h);
    defer allocator.free(black_points);

    const plans = [_]BinarizePlan{
        .{ .adaptive = true },
        .{ .adaptive = true, .invert = true },
        .{ .adaptive = false },
        .{ .adaptive = false, .invert = true },
    };
    // 「QR らしい格子が取れた」印。取れていないのに失敗した場合は
    // 「シンボルが見つからない」として報告する。
    var confirmed = false;
    var detected = false;
    for (plans) |plan| {
        binarize(&bin, image, plan, black_points);
        if (trace and image.width > 300) {
            var yy: usize = image.height - 26;
            while (yy < image.height) : (yy += 1) {
                var buf: [64]u8 = @splat('.');
                var xx: usize = 0;
                while (xx < 40) : (xx += 1) {
                    if (bin.get(xx, yy)) buf[xx] = '#';
                }
                std.debug.print("BIN {s}\n", .{buf[0..40]});
            }
        }
        sink.reset();
        const result = try attemptDecode(allocator, &bin, sink, info, &confirmed);
        switch (result) {
            .ok => return,
            .corrupt => detected = true,
            .not_found => {},
        }
    }
    if (detected and confirmed) return Error.TooManyErrors;
    return Error.SymbolNotFound;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

/// テストで使う画像（画素バッファは allocator 所有）。
const RenderedImage = struct {
    pixels: []u8,
    image: Image,

    fn deinit(self: *const RenderedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }
};

/// 行列をグレースケール画像に描く（テスト用）。
fn renderMatrix(
    allocator: std.mem.Allocator,
    m: *const qr.Matrix,
    scale: usize,
    quiet: usize,
    dark: u8,
    light: u8,
) Error!RenderedImage {
    const total = (m.size + 2 * quiet) * scale;
    const pixels = try allocator.alloc(u8, total * total);
    @memset(pixels, light);
    var y: usize = 0;
    while (y < m.size) : (y += 1) {
        var x: usize = 0;
        while (x < m.size) : (x += 1) {
            if (!m.get(x, y)) continue;
            var py: usize = 0;
            while (py < scale) : (py += 1) {
                var px: usize = 0;
                while (px < scale) : (px += 1) {
                    const gx = (quiet + x) * scale + px;
                    const gy = (quiet + y) * scale + py;
                    pixels[gy * total + gx] = dark;
                }
            }
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = total, .height = total, .pixels = pixels } };
}

/// 画像を 90 度単位で回す（テスト用）。
fn rotateQuarter(allocator: std.mem.Allocator, image: *const Image, quarters: usize) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    const q = quarters % 4;
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            // 出力は (h, w) または (w, h)。
            const src = image.pixels[y * w + x];
            switch (q) {
                0 => pixels[y * w + x] = src,
                1 => pixels[x * h + (h - 1 - y)] = src, // 90 度時計回り
                2 => pixels[(h - 1 - y) * w + (w - 1 - x)] = src,
                else => pixels[(w - 1 - x) * h + y] = src,
            }
        }
    }
    const out_w = if (q % 2 == 0) w else h;
    const out_h = if (q % 2 == 0) h else w;
    return .{ .pixels = pixels, .image = .{ .width = out_w, .height = out_h, .pixels = pixels } };
}

/// テスト用の簡単なぼかし（3×3 の平均を 1 回）。
fn boxBlur(allocator: std.mem.Allocator, image: *const Image) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            var sum: u32 = 0;
            var count: u32 = 0;
            var dy: isize = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: isize = -1;
                while (dx <= 1) : (dx += 1) {
                    const sx = @as(isize, @intCast(x)) + dx;
                    const sy = @as(isize, @intCast(y)) + dy;
                    if (sx < 0 or sy < 0 or sx >= @as(isize, @intCast(w)) or sy >= @as(isize, @intCast(h))) continue;
                    sum += image.pixels[@as(usize, @intCast(sy)) * w + @as(usize, @intCast(sx))];
                    count += 1;
                }
            }
            pixels[y * w + x] = @intCast(sum / count);
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// 局所的な明暗（照明むら）を掛ける（テスト用）。
fn shade(allocator: std.mem.Allocator, image: *const Image, strength: f64) Error!RenderedImage {
    const w = image.width;
    const h = image.height;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            const fx = 1.0 - strength * (@as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(w - 1)));
            const fy = 1.0 - strength * (@as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(h - 1)));
            const v = @as(f64, @floatFromInt(image.pixels[y * w + x])) * fx * fy;
            pixels[y * w + x] = @intFromFloat(std.math.clamp(v, 0.0, 255.0));
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// 画像を 2 倍に拡大する（テスト用、最近傍）。
fn upscale(allocator: std.mem.Allocator, image: *const Image, factor: usize) Error!RenderedImage {
    const w = image.width * factor;
    const h = image.height * factor;
    const pixels = try allocator.alloc(u8, w * h);
    var y: usize = 0;
    while (y < h) : (y += 1) {
        var x: usize = 0;
        while (x < w) : (x += 1) {
            pixels[y * w + x] = image.pixels[(y / factor) * image.width + (x / factor)];
        }
    }
    return .{ .pixels = pixels, .image = .{ .width = w, .height = h, .pixels = pixels } };
}

/// 復号して期待値と比べる（テスト用の共通処理）。
fn expectDecode(
    allocator: std.mem.Allocator,
    image: *const Image,
    expected: []const u8,
) !void {
    const text = try decode(allocator, image.*);
    defer allocator.free(text);
    try testing.expectEqualStrings(expected, text);
}

test "自己整合: EC レベルとモードの組み合わせ" {
    const allocator = testing.allocator;
    const cases = [_]struct { text: []const u8, ec: qr.EcLevel }{
        .{ .text = "0123456789012345678901234567890", .ec = .l },
        .{ .text = "HELLO WORLD $%*+-./: 1234", .ec = .m },
        .{ .text = "Hello, QR decoder! zig 0.17", .ec = .q },
        .{ .text = "日本語のテスト/QRデコーダ", .ec = .h },
        .{ .text = "12345", .ec = .h },
        .{ .text = "A", .ec = .l },
    };
    for (cases) |c| {
        const m = try qr.encode(allocator, c.text, c.ec);
        defer m.deinit(allocator);
        const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
        defer rendered.deinit(allocator);
        try expectDecode(allocator, &rendered.image, c.text);
    }
}

test "自己整合: 8 種類のマスクすべて" {
    const allocator = testing.allocator;
    const text = "MASK TEST 0123456789";
    var mask: u3 = 0;
    while (true) : (mask += 1) {
        const m = try qr.encodeWithMask(allocator, text, .m, mask);
        defer m.deinit(allocator);
        const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
        defer rendered.deinit(allocator);
        const info = try decodeTo(allocator, rendered.image, try allocator.alloc(u8, 64));
        defer allocator.free(info.text.ptr[0..64]);
        try testing.expectEqualStrings(text, info.text);
        try testing.expectEqual(mask, info.mask);
        try testing.expectEqual(qr.EcLevel.m, info.ec);
        if (mask == 7) break;
    }
}

test "自己整合: バージョン 1〜40" {
    const allocator = testing.allocator;
    const text = "ABCDEF123456";
    var version: u8 = 1;
    while (version <= 40) : (version += 1) {
        const m = try qr.encodeVersion(allocator, text, .l, version);
        defer m.deinit(allocator);
        const scale: usize = if (version <= 10) 3 else 2;
        const rendered = try renderMatrix(allocator, &m, scale, 4, 0, 255);
        defer rendered.deinit(allocator);
        const info_out = try allocator.alloc(u8, 64);
        defer allocator.free(info_out);
        const info = try decodeTo(allocator, rendered.image, info_out);
        try testing.expectEqualStrings(text, info.text);
        try testing.expectEqual(version, info.version);
    }
}

test "劣化: 90/180/270 度回転" {
    const allocator = testing.allocator;
    const text = "ROTATE ME 12345";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);
    var quarters: usize = 1;
    while (quarters < 4) : (quarters += 1) {
        const rotated = try rotateQuarter(allocator, &rendered.image, quarters);
        defer rotated.deinit(allocator);
        try expectDecode(allocator, &rotated.image, text);
    }
}

test "劣化: 拡大縮小" {
    const allocator = testing.allocator;
    const text = "SCALE 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const small = try renderMatrix(allocator, &m, 1, 4, 10, 240);
    defer small.deinit(allocator);
    try expectDecode(allocator, &small.image, text);

    const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
    defer rendered.deinit(allocator);
    const big = try upscale(allocator, &rendered.image, 3);
    defer big.deinit(allocator);
    try expectDecode(allocator, &big.image, text);
}

test "劣化: クワイエットゾーンなし" {
    const allocator = testing.allocator;
    const text = "NO QUIET ZONE";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 0, 0, 255);
    defer rendered.deinit(allocator);
    try expectDecode(allocator, &rendered.image, text);
}

test "劣化: 明暗のむらとぼかし" {
    const allocator = testing.allocator;
    const text = "ILLUMINATION 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);

    const shaded = try shade(allocator, &rendered.image, 0.7);
    defer shaded.deinit(allocator);
    try expectDecode(allocator, &shaded.image, text);

    const blurred = try boxBlur(allocator, &rendered.image);
    defer blurred.deinit(allocator);
    try expectDecode(allocator, &blurred.image, text);
}

test "劣化: 一部を塗りつぶしても EC の範囲内なら復号できる" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .h);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 6, 4, 0, 255);
    defer rendered.deinit(allocator);

    // シンボル中央のやや右下（位置検出パターンを避ける）を黒く塗る。
    var pixels = rendered.pixels;
    const side = rendered.image.width;
    const quiet_px = 4 * 6;
    const x0 = quiet_px + (m.size * 6 * 45) / 100;
    const x1 = quiet_px + (m.size * 6 * 75) / 100;
    const y0 = quiet_px + (m.size * 6 * 25) / 100;
    const y1 = quiet_px + (m.size * 6 * 45) / 100;
    var y = y0;
    while (y < y1) : (y += 1) {
        @memset(pixels[y * side + x0 .. y * side + x1], 0);
    }
    try expectDecode(allocator, &rendered.image, text);
}

test "劣化: ノイズ" {
    const allocator = testing.allocator;
    const text = "NOISE 0123456789";
    const m = try qr.encode(allocator, text, .m);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 4, 4, 0, 255);
    defer rendered.deinit(allocator);

    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    const noisy = try allocator.alloc(u8, rendered.pixels.len);
    defer allocator.free(noisy);
    for (rendered.pixels, 0..) |p, i| {
        const delta: i32 = @intCast(random.uintLessThan(u8, 61));
        const v = @as(i32, p) + delta - 30;
        noisy[i] = @intCast(std.math.clamp(v, 0, 255));
    }
    const image = Image{ .width = rendered.image.width, .height = rendered.image.height, .pixels = noisy };
    try expectDecode(allocator, &image, text);
}

test "壊れた入力では落ちない（エラーを返す）" {
    const allocator = testing.allocator;
    const empty = Image{ .width = 0, .height = 0, .pixels = &.{} };
    try testing.expectError(Error.SymbolNotFound, decode(allocator, empty));

    const short = Image{ .width = 4, .height = 4, .pixels = &[_]u8{ 0, 0 } };
    try testing.expectError(Error.Truncated, decode(allocator, short));

    const white = try allocator.alloc(u8, 64 * 64);
    defer allocator.free(white);
    @memset(white, 255);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 64, .pixels = white }));

    const black = try allocator.alloc(u8, 64 * 64);
    defer allocator.free(black);
    @memset(black, 0);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 64, .pixels = black }));

    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const noise = try allocator.alloc(u8, 128 * 96);
    defer allocator.free(noise);
    for (noise) |*p| p.* = random.int(u8);
    // でたらめな画像は「見つからない」か「見つかったが読めない」のどちらか。落ちてはならない。
    const noise_image = Image{ .width = 128, .height = 96, .pixels = noise };
    if (decode(allocator, noise_image)) |text| {
        allocator.free(text);
    } else |e| {
        try testing.expect(e == Error.SymbolNotFound or e == Error.TooManyErrors);
    }

    // 極端に細い画像。
    const thin = try allocator.alloc(u8, 1 * 64);
    defer allocator.free(thin);
    @memset(thin, 0);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 1, .height = 64, .pixels = thin }));

    const thin2 = try allocator.alloc(u8, 64 * 1);
    defer allocator.free(thin2);
    @memset(thin2, 255);
    try testing.expectError(Error.SymbolNotFound, decode(allocator, .{ .width = 64, .height = 1, .pixels = thin2 }));
}

test "decodeInto: ちょうどの大きさと不足" {
    const allocator = testing.allocator;
    const text = "Hello, QR decoder! zig 0.17";
    const m = try qr.encode(allocator, text, .q);
    defer m.deinit(allocator);
    const rendered = try renderMatrix(allocator, &m, 3, 4, 0, 255);
    defer rendered.deinit(allocator);

    var buf: [64]u8 = undefined;
    const exact = try decodeInto(allocator, rendered.image, buf[0..text.len]);
    try testing.expectEqualStrings(text, exact);

    var small: [4]u8 = undefined;
    try testing.expectError(Error.BufferTooSmall, decodeInto(allocator, rendered.image, &small));
}

test "Reed-Solomon: 能力内の誤りを訂正し、超えると失敗する" {
    const allocator = testing.allocator;
    _ = allocator;
    // テスト専用の RS 符号化（生成多項式による剰余）。本実装の復号と独立に用意する。
    const data = [_]u8{ 0x10, 0x20, 0x0C, 0x56, 0x61, 0x80, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11, 0xEC, 0x11 };
    inline for (.{ 7, 10, 13, 17, 22, 30 }) |ecc_len| {
        var codeword: [16 + 30]u8 = @splat(0);
        @memcpy(codeword[0..data.len], &data);
        testRsEncode(&data, ecc_len, codeword[data.len .. data.len + ecc_len]);
        const total = data.len + ecc_len;

        // 符号語のシンドロームが 0（= 妥当な符号語）であること。
        var scratch: RsScratch = .{};
        var all_zero = true;
        for (0..ecc_len) |i| {
            var s: u8 = 0;
            const x = gf_exp[i];
            for (codeword[0..total]) |c| s = gfMul(s, x) ^ c;
            if (s != 0) all_zero = false;
        }
        try testing.expect(all_zero);

        // 能力内（t = ecc/2 個）の誤りを訂正できる。
        var prng = std.Random.DefaultPrng.init(0x1234 + ecc_len);
        const random = prng.random();
        var trial: usize = 0;
        while (trial < 8) : (trial += 1) {
            var damaged: [16 + 30]u8 = @splat(0);
            @memcpy(damaged[0..total], codeword[0..total]);
            try testing.expectEqual(ecc_len / 2, corruptDistinct(&damaged, total, ecc_len / 2, random));
            const corrected = try rsCorrect(damaged[0..total], ecc_len, &scratch);
            try testing.expect(corrected <= ecc_len / 2 + 1);
            try testing.expectEqualSlices(u8, codeword[0..total], damaged[0..total]);
        }

        // 能力を超える誤り（t + 2 個）は、遅くとも誤り訂正で失敗するか別の符号語になる。
        var damaged: [16 + 30]u8 = @splat(0);
        @memcpy(damaged[0..total], codeword[0..total]);
        _ = corruptDistinct(&damaged, total, ecc_len / 2 + 2, random);
        const outcome = rsCorrect(damaged[0..total], ecc_len, &scratch);
        if (outcome) |_| {
            // 別の符号語に化けた場合は、元と一致しないことを確認する。
            try testing.expect(!std.mem.eql(u8, codeword[0..total], damaged[0..total]));
        } else |e| {
            try testing.expectEqual(Error.TooManyErrors, e);
        }
    }
}

/// テスト専用: 異なる位置に `count` 個の誤りを入れて、実際に入れた個数を返す。
fn corruptDistinct(codeword: *[16 + 30]u8, total: usize, count: usize, random: std.Random) usize {
    var used: [16 + 30]bool = @splat(false);
    var placed: usize = 0;
    var attempts: usize = 0;
    while (placed < count and attempts < 200) : (attempts += 1) {
        const at = random.uintLessThan(usize, total);
        if (used[at]) continue;
        used[at] = true;
        const delta = random.int(u8) | 1;
        codeword[at] ^= delta;
        if (codeword[at] != 0 or delta != 0) placed += 1;
    }
    return placed;
}

/// テスト専用: データコードワード列に対する RS の ECC を計算する。
fn testRsEncode(data: []const u8, ecc_len: usize, out: []u8) void {
    // 生成多項式 g(x) = Π (x - α^i) を昇順係数で持つ。
    var gen: [31]u8 = @splat(0);
    gen[0] = 1;
    var degree: usize = 0;
    for (0..ecc_len) |i| {
        const root = gf_exp[i];
        var k = degree + 1;
        while (k > 0) : (k -= 1) {
            gen[k] = gfMul(gen[k], root) ^ gen[k - 1];
        }
        gen[0] = gfMul(gen[0], root);
        degree += 1;
    }
    // LFSR による剰余（データは最高次が先頭）。
    var rem: [30]u8 = @splat(0);
    for (data) |d| {
        const factor = d ^ rem[ecc_len - 1];
        var k = ecc_len - 1;
        while (k > 0) : (k -= 1) {
            rem[k] = rem[k - 1] ^ gfMul(factor, gen[k]);
        }
        rem[0] = gfMul(factor, gen[0]);
    }
    for (0..ecc_len) |k| out[k] = rem[ecc_len - 1 - k];
}

test "容量テーブルが qr.zig の公開 API と一致する" {
    for (0..4) |i| {
        const ec: qr.EcLevel = switch (i) {
            0 => .l,
            1 => .m,
            2 => .q,
            else => .h,
        };
        var version: u8 = 1;
        while (version <= 40) : (version += 1) {
            const raw = qr.rawCodewords(version);
            const data = qr.dataCodewords(ec, version);
            const ecc_total = @as(usize, ecc_codewords_per_block[i][version]) * num_ec_blocks[i][version];
            try testing.expectEqual(raw, data + ecc_total);
            // データコードワードはブロックに 1 個差で分配できる（規格 Table 9 の前提）。
            const blocks: usize = num_ec_blocks[i][version];
            try testing.expect(blocks >= 1);
            if (data / blocks < 1) return error.TestUnexpectedResult;
        }
    }
}

test "アラインメントパターン位置が規格の表と一致する" {
    // ISO/IEC 18004 Annex E の代表値。
    const expected_7 = [_]usize{ 6, 22, 38 };
    const ap7 = alignmentPositions(7);
    try testing.expectEqual(expected_7.len, ap7.len);
    for (expected_7, 0..) |v, i| try testing.expectEqual(v, ap7.pos[i]);

    const expected_32 = [_]usize{ 6, 34, 60, 86, 112, 138 };
    const ap32 = alignmentPositions(32);
    try testing.expectEqual(expected_32.len, ap32.len);
    for (expected_32, 0..) |v, i| try testing.expectEqual(v, ap32.pos[i]);

    const expected_40 = [_]usize{ 6, 30, 58, 86, 114, 142, 170 };
    const ap40 = alignmentPositions(40);
    try testing.expectEqual(expected_40.len, ap40.len);
    for (expected_40, 0..) |v, i| try testing.expectEqual(v, ap40.pos[i]);

    // 最後の位置は必ず「一辺 - 7」。
    var version: u8 = 2;
    while (version <= 40) : (version += 1) {
        const ap = alignmentPositions(version);
        try testing.expectEqual(17 + 4 * @as(usize, version) - 7, ap.pos[ap.len - 1]);
    }
}

test "format 情報の復号: 全 32 通り" {
    const allocator = testing.allocator;
    // 行列を作って format 情報だけを読み取る（データ部は無関係）。
    const text = "FORMAT";
    for (0..32) |k| {
        const ec: qr.EcLevel = ecFromFormatBits(@intCast(k >> 3));
        const mask: u3 = @intCast(k & 7);
        const m = try qr.encodeWithMask(allocator, text, ec, mask);
        defer m.deinit(allocator);
        var grid = try BitMatrix.init(allocator, m.size, m.size);
        defer grid.deinit(allocator);
        var y: usize = 0;
        while (y < m.size) : (y += 1) {
            var x: usize = 0;
            while (x < m.size) : (x += 1) {
                if (m.get(x, y)) grid.set(x, y);
            }
        }
        const fmt = readFormat(&grid, m.size) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(ec, fmt.ec);
        try testing.expectEqual(mask, fmt.mask);
        try testing.expectEqual(@as(u3, 0), fmt.distance);
    }
}

test "version 情報の復号: バージョン 7〜40" {
    const allocator = testing.allocator;
    var version: u8 = 7;
    while (version <= 40) : (version += 1) {
        const m = try qr.encodeVersion(allocator, "V", .l, version);
        defer m.deinit(allocator);
        var grid = try BitMatrix.init(allocator, m.size, m.size);
        defer grid.deinit(allocator);
        var y: usize = 0;
        while (y < m.size) : (y += 1) {
            var x: usize = 0;
            while (x < m.size) : (x += 1) {
                if (m.get(x, y)) grid.set(x, y);
            }
        }
        const v = readVersionInfo(&grid, m.size) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(version, v.version);
        try testing.expectEqual(@as(u3, 0), v.distance);
    }
}
