//! Offline NS region link harness. Not executable wallet firmware.
// SPDX-License-Identifier: GPL-3.0-or-later
export var zhww_nonsecure_ingress: [64 * 1024]u8 linksection(".nonsecure_ingress") = undefined;
export fn zhww_link_only_halt() noreturn {
    while (true) asm volatile ("wfi");
}
