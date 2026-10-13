//! Compile-only target ABI layout probe. No hardware, no seed, no signing events.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const budget = @import("src/security/memory_budget.zig");
export const zhww_memory_layout: budget.Layout = budget.layout;
