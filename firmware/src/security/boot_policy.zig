//! Semantic requirements, NOT register definitions or proof of hardware configuration.
//! Only a future Secure-world HAL may collect Evidence. Never accept it from NS code.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");

pub const Stepping = enum { unknown, a2, a3, a4 };
pub const Evidence = struct {
    stepping: Stepping = .unknown,
    arm_only: bool = false,
    signed_boot: bool = false,
    boot_key_matches: bool = false,
    unused_boot_keys_revoked: bool = false,
    debug_disabled: bool = false,
    otp_permissions_locked: bool = false,
    glitch_detection_enabled: bool = false,
    boot_interfaces_disabled: bool = false,
    watchdog_pc_sp_disabled: bool = false,
    usb_data_disabled: bool = false,
    secure_memory_isolated: bool = false,
    secure_peripherals_isolated: bool = false,
    dma_isolated: bool = false,
    secondary_core_parked: bool = false,
    trng_healthy: bool = false,
    self_tests_passed: bool = false,
};

pub const Failure = error{
    UnsupportedSilicon,
    Architecture,
    UnsignedBoot,
    BootKey,
    Debug,
    OtpPermissions,
    GlitchDetection,
    BootInterfaces,
    WatchdogReboot,
    UsbData,
    MemoryIsolation,
    PeripheralIsolation,
    DmaIsolation,
    SecondaryCore,
    Entropy,
    SelfTest,
};

/// Production has no override. Dev tools remain separate and must not claim production status.
/// Encrypted boot is deliberately not required: it hides public code, not wallet secrets,
/// and SRAM size / XIP substitution risks require a separately validated image layout.
pub fn validate(e: Evidence) Failure!void {
    if (e.stepping != .a4) return error.UnsupportedSilicon;
    if (!e.arm_only) return error.Architecture;
    if (!e.signed_boot) return error.UnsignedBoot;
    if (!e.boot_key_matches or !e.unused_boot_keys_revoked) return error.BootKey;
    if (!e.debug_disabled) return error.Debug;
    if (!e.otp_permissions_locked) return error.OtpPermissions;
    if (!e.glitch_detection_enabled) return error.GlitchDetection;
    if (!e.boot_interfaces_disabled) return error.BootInterfaces;
    if (!e.watchdog_pc_sp_disabled) return error.WatchdogReboot;
    if (!e.usb_data_disabled) return error.UsbData;
    if (!e.secure_memory_isolated) return error.MemoryIsolation;
    if (!e.secure_peripherals_isolated) return error.PeripheralIsolation;
    if (!e.dma_isolated) return error.DmaIsolation;
    if (!e.secondary_core_parked) return error.SecondaryCore;
    if (!e.trng_healthy) return error.Entropy;
    if (!e.self_tests_passed) return error.SelfTest;
}

// Test fixture only: deliberately not exported as a production configuration.
fn good() Evidence {
    var e: Evidence = .{ .stepping = .a4 };
    inline for (comptime std.meta.fieldNames(Evidence)) |name| {
        if (@TypeOf(@field(e, name)) == bool) @field(e, name) = true;
    }
    return e;
}

test "boot evidence defaults fail closed and only reviewed silicon is accepted" {
    try std.testing.expectError(error.UnsupportedSilicon, validate(.{}));
    try validate(good());
    for ([_]Stepping{ .unknown, .a2, .a3 }) |stepping| {
        var e = good();
        e.stepping = stepping;
        try std.testing.expectError(error.UnsupportedSilicon, validate(e));
    }
}

test "every production requirement is mandatory" {
    inline for (comptime std.meta.fieldNames(Evidence)) |name| {
        if (@TypeOf(@field(@as(Evidence, .{}), name)) == bool) {
            var e = good();
            @field(e, name) = false;
            if (validate(e)) |_| return error.TestUnexpectedResult else |_| {}
        }
    }
}
