//! 状態表示（LED と画面バックライト）の方針。
//!
//! **なぜ「方針」をコードにするのか**: 実機の LED が GPIO で制御できるかは
//! 基板の回路図待ちで未確定（RP2350-PiZero には「Power LED」があるが、電源レールに
//! 直結されている可能性が高い）。一方で「どの状態でどう光らせるか」はハードに依存しない
//! ので、先に決めてテストできる形にしておけば、実機が来たら GPIO を繋ぐだけで済む。
//!
//! **乾電池駆動なので消費電力が重要**: 待機中は「たまに一瞬光る」程度に抑え、
//! 平均の点灯率を数 % 以下にする（点滅の平均電流を計算できるよう、パターンは
//! 点灯/消灯と時間の列で表す）。

const std = @import("std");
const Error = @import("../core/errors.zig").Error;

/// 端末の状態。
pub const State = enum {
    /// 待機（画面オフ・たまに心拍のように光る）
    idle,
    /// 処理中（署名の計算など）
    busy,
    /// 利用者の確認待ち（画面に内容を出している）
    confirm,
    /// エラー（画面に理由を出している）。`error` は Zig の予約語なので failure とする
    failure,
    /// 電池が少ない見込み（推定。実測ではない）
    battery_low,
};

/// 点滅パターンの 1 段階。
pub const Step = struct {
    on: bool,
    ms: u32,
};

/// 1 周期のパターン。
pub const Pattern = struct {
    steps: []const Step,

    /// 周期の長さ（ミリ秒）。
    pub fn periodMs(self: Pattern) u32 {
        var total: u32 = 0;
        for (self.steps) |step| total += step.ms;
        return total;
    }

    /// 点灯している時間の合計（ミリ秒）。
    pub fn onMs(self: Pattern) u32 {
        var total: u32 = 0;
        for (self.steps) |step| {
            if (step.on) total += step.ms;
        }
        return total;
    }

    /// 平均の点灯率（%）。乾電池の持ちを評価するために使う。
    pub fn dutyPercent(self: Pattern) u32 {
        const period = self.periodMs();
        if (period == 0) return 0;
        return self.onMs() * 100 / period;
    }

    /// `elapsed_ms` の時点で点灯しているか。
    pub fn isOnAt(self: Pattern, elapsed_ms: u64) bool {
        const period = self.periodMs();
        if (period == 0) return false;
        var position: u32 = @intCast(elapsed_ms % period);
        for (self.steps) |step| {
            if (position < step.ms) return step.on;
            position -= step.ms;
        }
        return false;
    }
};

// 待機: 3 秒ごとに 20ms だけ光る（心拍）。平均点灯率 0.7% 未満。
const idle_steps = [_]Step{
    .{ .on = true, .ms = 20 },
    .{ .on = false, .ms = 2980 },
};

// 処理中: 点灯したまま（利用者が見ている）。
const busy_steps = [_]Step{
    .{ .on = true, .ms = 1000 },
    .{ .on = false, .ms = 0 },
};

// 確認待ち: ゆっくり点滅（画面を見てもらう合図）。
const confirm_steps = [_]Step{
    .{ .on = true, .ms = 400 },
    .{ .on = false, .ms = 600 },
};

// エラー: 速く点滅。
const error_steps = [_]Step{
    .{ .on = true, .ms = 100 },
    .{ .on = false, .ms = 100 },
};

// 電池少: 2 回点滅して長く消える（待機の心拍と区別できる）。
const battery_low_steps = [_]Step{
    .{ .on = true, .ms = 60 },
    .{ .on = false, .ms = 140 },
    .{ .on = true, .ms = 60 },
    .{ .on = false, .ms = 3740 },
};

/// 状態に対応する点滅パターン。
pub fn patternFor(state: State) Pattern {
    return switch (state) {
        .idle => .{ .steps = &idle_steps },
        .busy => .{ .steps = &busy_steps },
        .confirm => .{ .steps = &confirm_steps },
        .failure => .{ .steps = &error_steps },
        .battery_low => .{ .steps = &battery_low_steps },
    };
}

/// 画面のバックライトを点けるか。
///
/// **待機中は消す**（バックライトが一番電気を食うため）。
pub fn backlightOn(state: State) bool {
    return state != .idle;
}

/// 状態を日本語で表す（画面に出す用。文字は ASCII 前提の画面では英字を使う）。
pub fn label(state: State) []const u8 {
    return switch (state) {
        .idle => "STAND BY",
        .busy => "WORKING",
        .confirm => "CONFIRM",
        .failure => "ERROR",
        .battery_low => "BATTERY LOW",
    };
}

/// 状態を切り替えたときに「何か光らせる必要があるか」を返す。
///
/// 状態が変わった直後だけ光らせると、待機中の平均消費をさらに下げられる。
pub fn shouldPulseOnChange(previous: State, next: State) bool {
    if (previous == next) return false;
    return next == .battery_low or next == .failure;
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "待機は点灯率が非常に低い（乾電池の持ちを優先する）" {
    const pattern = patternFor(.idle);
    try testing.expect(pattern.dutyPercent() <= 1);
    try testing.expect(pattern.isOnAt(0));
    try testing.expect(!pattern.isOnAt(20));
    try testing.expect(!pattern.isOnAt(1500));
    // 3 秒後にはもう一度光る
    try testing.expect(pattern.isOnAt(3000));
}

test "処理中と確認待ちは消えない／ゆっくり点滅する" {
    const busy = patternFor(.busy);
    try testing.expectEqual(@as(u32, 100), busy.dutyPercent());
    try testing.expect(busy.isOnAt(0));
    try testing.expect(busy.isOnAt(999));

    const confirm = patternFor(.confirm);
    try testing.expect(confirm.isOnAt(0));
    try testing.expect(!confirm.isOnAt(400));
    try testing.expect(confirm.isOnAt(1000));
    try testing.expectEqual(@as(u32, 40), confirm.dutyPercent());
}

test "エラーは速く点滅し、電池少は待機と区別できる" {
    const error_pattern = patternFor(.failure);
    try testing.expect(error_pattern.isOnAt(0));
    try testing.expect(!error_pattern.isOnAt(100));
    try testing.expect(error_pattern.isOnAt(200));

    const low = patternFor(.battery_low);
    // 2 回光ってから長く消える
    try testing.expect(low.isOnAt(0));
    try testing.expect(!low.isOnAt(60));
    try testing.expect(low.isOnAt(200));
    try testing.expect(!low.isOnAt(260));
    try testing.expect(!low.isOnAt(2000));
    try testing.expect(low.isOnAt(4000));
    // 待機（0.7%）よりは目立つが、点灯しっぱなしではない
    try testing.expect(low.dutyPercent() < 10);
}

test "バックライトは待機中だけ消す" {
    try testing.expect(!backlightOn(.idle));
    try testing.expect(backlightOn(.busy));
    try testing.expect(backlightOn(.confirm));
    try testing.expect(backlightOn(.failure));
    try testing.expect(backlightOn(.battery_low));
}

test "状態が変わったときだけ合図する" {
    try testing.expect(!shouldPulseOnChange(.idle, .idle));
    try testing.expect(!shouldPulseOnChange(.idle, .confirm));
    try testing.expect(shouldPulseOnChange(.confirm, .failure));
    try testing.expect(shouldPulseOnChange(.confirm, .battery_low));
}

test "周期が 0 のパターンでも落ちない" {
    const empty = Pattern{ .steps = &.{} };
    try testing.expectEqual(@as(u32, 0), empty.periodMs());
    try testing.expectEqual(@as(u32, 0), empty.dutyPercent());
    try testing.expect(!empty.isOnAt(1234));
}
