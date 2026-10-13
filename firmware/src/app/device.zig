//! The layer that decides which screen the device shows right now.
//!
//! It depends on neither the hardware nor the chain (it only assembles the material for the screen).
//! Both the firmware main loop and the host-side check (the CLI walkthrough) use the
//! **same functions**.
//!
//! Policy (the project principle "do not sign anything that cannot be displayed"):
//! - Errors are **always shown on screen** (never stop silently)
//! - Show what is being signed (file name, destination, amount, fee) before signing
//! - Say "unknown" for what is unknown (never fill it in by guessing)
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");
const ui_screen = @import("../ui/screen.zig");

/// The situation the device should show the user.
pub const Problem = enum {
    /// No card is inserted
    waiting_card,
    /// The card was read but is not FAT32 (FAT16 / exFAT, etc.)
    not_fat32,
    /// The card cannot be read (poor contact, unformatted, etc.)
    card_unreadable,
    /// There is no IN.PSBT
    no_input,
    /// The file is too large (limit 64KB)
    file_too_large,
    /// It cannot be interpreted as a PSBT
    invalid_psbt,
    /// There is no key that can sign
    no_matching_key,
    /// An unsupported signature scheme (SIGHASH_NONE / SINGLE, etc.)
    unsupported_sighash,
    /// An unexpected failure other than signing
    failure,
};

/// The content to show on screen (strings are static; no allocator is used).
pub const Notice = struct {
    title: []const u8,
    /// Body (one item per line).
    lines: []const []const u8,
    /// Warnings (shown in red).
    warnings: []const []const u8 = &.{},
    footer_left: []const u8 = "",
    footer_right: []const u8 = "",
    /// Whether this screen prompts an action (waiting / confirmation).
    actionable: bool = false,
};

/// Returns the screen content for a situation.
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

/// Maps a FAT32 mount failure to a screen situation.
pub fn problemForMountError(err: anyerror) Problem {
    return switch (err) {
        error.UnsupportedFatType, error.NotFat32 => .not_fat32,
        error.DeviceFailure, error.Truncated, error.OutOfRange => .card_unreadable,
        else => .card_unreadable,
    };
}

/// Maps a signing failure to a screen situation.
pub fn problemForSignError(err: anyerror) Problem {
    return switch (err) {
        error.InvalidPsbt, error.Truncated, error.InvalidEncoding, error.ChecksumMismatch => .invalid_psbt,
        error.NoMatchingKey, error.InvalidKey => .no_matching_key,
        error.UnsupportedSighash => .unsupported_sighash,
        error.BufferTooSmall, error.OutOfMemory => .file_too_large,
        else => .failure,
    };
}

/// Decides the situation from the file size (shown on screen when the limit is exceeded).
pub fn problemForFileSize(size: usize, limit: usize) ?Problem {
    if (size > limit) return .file_too_large;
    return null;
}

/// Converts the screen content into a `ui_screen.Screen`.
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

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "every situation has screen content (the title is not empty)" {
    const problems = [_]Problem{
        .waiting_card,   .not_fat32,  .card_unreadable, .no_input,
        .file_too_large, .invalid_psbt, .no_matching_key, .unsupported_sighash,
        .failure,
    };
    for (problems) |problem| {
        const notice = noticeFor(problem);
        try testing.expect(notice.title.len > 0);
        // Anything other than waiting must always report that no signing was performed
        // (do not mislead the user).
        if (problem != .waiting_card) {
            try testing.expect(notice.warnings.len > 0);
            try testing.expect(notice.lines.len > 0);
        }
    }
}

test "error mapping (FAT32 and signing)" {
    try testing.expectEqual(Problem.not_fat32, problemForMountError(error.UnsupportedFatType));
    try testing.expectEqual(Problem.not_fat32, problemForMountError(error.NotFat32));
    try testing.expectEqual(Problem.card_unreadable, problemForMountError(error.DeviceFailure));

    try testing.expectEqual(Problem.invalid_psbt, problemForSignError(error.InvalidPsbt));
    try testing.expectEqual(Problem.no_matching_key, problemForSignError(error.NoMatchingKey));
    try testing.expectEqual(Problem.unsupported_sighash, problemForSignError(error.UnsupportedSighash));
    try testing.expectEqual(Problem.failure, problemForSignError(error.SomethingElse));
}

test "size limit (64KB)" {
    try testing.expectEqual(@as(?Problem, null), problemForFileSize(64 * 1024, 64 * 1024));
    try testing.expectEqual(Problem.file_too_large, problemForFileSize(64 * 1024 + 1, 64 * 1024));
    try testing.expectEqual(@as(?Problem, null), problemForFileSize(100, 64 * 1024));
}

test "conversion to a screen (lines and warnings are filled in)" {
    var lines: [8]ui_screen.Line = undefined;
    var warnings: [4][]const u8 = undefined;
    const screen = screenFor(noticeFor(.invalid_psbt), &lines, &warnings);
    try testing.expectEqualStrings("INVALID PSBT", screen.title);
    try testing.expect(screen.lines.len >= 3);
    try testing.expectEqual(@as(usize, 1), screen.warnings.len);
    try testing.expectEqualStrings("BACK", screen.footer_left);
}

test "a small screen buffer does not crash (content is truncated)" {
    var lines: [1]ui_screen.Line = undefined;
    var warnings: [0][]const u8 = undefined;
    const screen = screenFor(noticeFor(.no_input), &lines, &warnings);
    try testing.expectEqual(@as(usize, 1), screen.lines.len);
    try testing.expectEqual(@as(usize, 0), screen.warnings.len);
}
