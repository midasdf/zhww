//! Compile-only target ABI layout probe. No hardware, no seed, no signing events.
// SPDX-License-Identifier: GPL-3.0-or-later
const budget = @import("src/security/memory_budget.zig");
export const zhww_memory_layout: budget.Layout = budget.layout;
