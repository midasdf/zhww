//! 端末が「今どの画面を出すか」を決める層。
//!
//! ハードウェアにもチェーンにも依存しない（画面の材料だけを組み立てる）。
//! 実機の main ループも、PC 上の確認（CLI の walkthrough）も、**同じ関数**を使う。
//!
//! 方針（プロジェクトの原則「表示できないものには署名しない」）:
//! - エラーは**必ず画面に出す**（黙って止まらない）
//! - 何に署名するのか（ファイル名・送金先・金額・手数料）を署名前に出す
//! - 分からないことは「分からない」と出す（推測で埋めない）

const std = @import("std");
const ui_screen = @import("../ui/screen.zig");

/// 端末が利用者に見せるべき状況。
pub const Problem = enum {
    /// カードが挿さっていない
    waiting_card,
    /// カードは読めたが FAT32 ではない（FAT16 / exFAT など）
    not_fat32,
    /// カードを読めない（接触不良・未フォーマットなど）
    card_unreadable,
    /// IN.PSBT が無い
    no_input,
    /// ファイルが大きすぎる（上限 64KB）
    file_too_large,
    /// PSBT として解釈できない
    invalid_psbt,
    /// 署名できる鍵が無い
    no_matching_key,
    /// 対応していない署名方式（SIGHASH_NONE / SINGLE など）
    unsupported_sighash,
    /// 署名以外の想定外の失敗
    failure,
};

/// 画面に出す内容（文字列は静的。アロケータを使わない）。
pub const Notice = struct {
    title: []const u8,
    /// 本文（1 行 1 項目）。
    lines: []const []const u8,
    /// 警告（赤で出る）。
    warnings: []const []const u8 = &.{},
    footer_left: []const u8 = "",
    footer_right: []const u8 = "",
    /// 操作を促す画面か（待機・確認）どうか。
    actionable: bool = false,
};

/// 状況に対応する画面の内容を返す。
pub fn noticeFor(problem: Problem) Notice {
    return switch (problem) {
        .waiting_card => .{
            .title = "ZHWW",
            .lines = &.{
                "INSERT CARD",
                "Put a FAT32 microSD card",
                "with IN.PSBT on it.",
            },
            .footer_right = "POWER ON",
            .actionable = true,
        },
        .not_fat32 => .{
            .title = "NOT FAT32",
            .lines = &.{
                "This card is not FAT32.",
                "Format it as FAT32 (not exFAT).",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .card_unreadable => .{
            .title = "NO CARD",
            .lines = &.{
                "The card could not be read.",
                "Check that it is inserted fully.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .no_input => .{
            .title = "NO IN.PSBT",
            .lines = &.{
                "IN.PSBT was not found on the card.",
                "Write the PSBT to the card first.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .file_too_large => .{
            .title = "FILE TOO LARGE",
            .lines = &.{
                "IN.PSBT is larger than 64KB.",
                "Split the transaction or use a",
                "smaller PSBT.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .invalid_psbt => .{
            .title = "INVALID PSBT",
            .lines = &.{
                "The file is not a valid PSBT.",
                "Check that the file is complete",
                "and not truncated.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .no_matching_key => .{
            .title = "NO KEY",
            .lines = &.{
                "This wallet has no key for",
                "any of the inputs.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .unsupported_sighash => .{
            .title = "NOT SUPPORTED",
            .lines = &.{
                "This transaction uses a signature",
                "type this wallet does not support",
                "(only SIGHASH_ALL is supported).",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
        .failure => .{
            .title = "FAILED",
            .lines = &.{
                "Something went wrong.",
                "No signature was made.",
            },
            .warnings = &.{"No signing was performed."},
            .footer_left = "BACK",
        },
    };
}

/// FAT32 のマウント失敗を画面の状況に対応づける。
pub fn problemForMountError(err: anyerror) Problem {
    return switch (err) {
        error.UnsupportedFatType, error.NotFat32 => .not_fat32,
        error.DeviceFailure, error.Truncated, error.OutOfRange => .card_unreadable,
        else => .card_unreadable,
    };
}

/// 署名の失敗を画面の状況に対応づける。
pub fn problemForSignError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidPsbt, error.Truncated, error.InvalidEncoding, error.ChecksumMismatch => .invalid_psbt,
        error.NoMatchingKey, error.InvalidKey => .no_matching_key,
        error.UnsupportedSighash => .unsupported_sighash,
        error.BufferTooSmall, error.OutOfMemory => .file_too_large,
        else => .failure,
    };
}

/// ファイルの大きさから状況を決める（上限を超えていれば画面に出す）。
pub fn problemForFileSize(size: usize, limit: usize) ?Problem {
    if (size > limit) return .file_too_large;
    return null;
}

/// 画面の内容を `ui_screen.Screen` に変換する。
pub fn screenFor(notice: Notice, lines_buffer: []ui_screen.Line, warnings_buffer: [][]const u8) ui_screen.Screen {
    var count: usize = 0;
    for (notice.lines) |line| {
        if (count >= lines_buffer.len) break;
        lines_buffer[count] = .{ .label = "", .value = line };
        count += 1;
    }
    var warning_count: usize = 0;
    for (notice.warnings) |warning| {
        if (warning_count >= warnings_buffer.len) break;
        warnings_buffer[warning_count] = warning;
        warning_count += 1;
    }
    return .{
        .title = notice.title,
        .lines = lines_buffer[0..count],
        .warnings = warnings_buffer[0..warning_count],
        .footer_left = notice.footer_left,
        .footer_right = notice.footer_right,
    };
}

// ---------------------------------------------------------------- テスト

const testing = std.testing;

test "すべての状況に画面の内容がある（タイトルが空でない）" {
    const problems = [_]Problem{
        .waiting_card,   .not_fat32,  .card_unreadable, .no_input,
        .file_too_large, .invalid_psbt, .no_matching_key, .unsupported_sighash,
        .failure,
    };
    for (problems) |problem| {
        const notice = noticeFor(problem);
        try testing.expect(notice.title.len > 0);
        // 待機以外は「署名していない」ことを必ず伝える（誤解させない）
        if (problem != .waiting_card) {
            try testing.expect(notice.warnings.len > 0);
            try testing.expect(notice.lines.len > 0);
        }
    }
}

test "エラーの対応づけ（FAT32 と署名）" {
    try testing.expectEqual(Problem.not_fat32, problemForMountError(error.UnsupportedFatType));
    try testing.expectEqual(Problem.not_fat32, problemForMountError(error.NotFat32));
    try testing.expectEqual(Problem.card_unreadable, problemForMountError(error.DeviceFailure));

    try testing.expectEqual(Problem.invalid_psbt, problemForSignError(error.InvalidPsbt));
    try testing.expectEqual(Problem.no_matching_key, problemForSignError(error.NoMatchingKey));
    try testing.expectEqual(Problem.unsupported_sighash, problemForSignError(error.UnsupportedSighash));
    try testing.expectEqual(Problem.failure, problemForSignError(error.SomethingElse));
}

test "大きさの上限（64KB）" {
    try testing.expectEqual(@as(?Problem, null), problemForFileSize(64 * 1024, 64 * 1024));
    try testing.expectEqual(Problem.file_too_large, problemForFileSize(64 * 1024 + 1, 64 * 1024));
    try testing.expectEqual(@as(?Problem, null), problemForFileSize(100, 64 * 1024));
}

test "画面への変換（行と警告が入る）" {
    var lines: [8]ui_screen.Line = undefined;
    var warnings: [4][]const u8 = undefined;
    const screen = screenFor(noticeFor(.invalid_psbt), &lines, &warnings);
    try testing.expectEqualStrings("INVALID PSBT", screen.title);
    try testing.expect(screen.lines.len >= 3);
    try testing.expectEqual(@as(usize, 1), screen.warnings.len);
    try testing.expectEqualStrings("BACK", screen.footer_left);
}

test "画面が小さいバッファでも落ちない（切り詰められる）" {
    var lines: [1]ui_screen.Line = undefined;
    var warnings: [0][]const u8 = undefined;
    const screen = screenFor(noticeFor(.no_input), &lines, &warnings);
    try testing.expectEqual(@as(usize, 1), screen.lines.len);
    try testing.expectEqual(@as(usize, 0), screen.warnings.len);
}
