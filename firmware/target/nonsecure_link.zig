//! Offline NS region link harness. Not executable wallet firmware.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
export var zhww_nonsecure_ingress: [64 * 1024]u8 linksection(".nonsecure_ingress") = undefined;
export fn zhww_link_only_halt() noreturn {
    while (true) asm volatile ("wfi");
}
