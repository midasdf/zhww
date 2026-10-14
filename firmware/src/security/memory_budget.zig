//! Provisional RP2350 SRAM inventory, NOT a linked-image or worst-case stack proof.
//! Size-of terms are target ABI measurements; stack/HAL terms are UNVALIDATED reserves.
//! One framebuffer, one ingress buffer, one workflow, one reusable workspace.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT
const std = @import("std");
const Workflow = @import("../apps/btc/approved_sign.zig").Workflow;
const Review = @import("../apps/btc/review.zig").Review;
const secp256k1 = @import("../core/crypto/secp256k1.zig");
const ContextOwner = secp256k1.ContextOwner(secp256k1.context_capacity);
const Workspace = @import("workspace.zig").Workspace;
const Rng = @import("rng.zig").Rng;

pub const sram_bytes = 520 * 1024;
pub const workspace_bytes = 128 * 1024;
pub const ingress_bytes = 64 * 1024;
pub const framebuffer_bytes = 240 * 135 * @sizeOf(u16);
pub const stack_reserve_bytes = 64 * 1024;
pub const fault_stack_reserve_bytes = 8 * 1024;
pub const nonsecure_stack_reserve_bytes = 8 * 1024;
pub const hal_reserve_bytes = 32 * 1024;

/// Fixed ELF-readable schema; all values are bytes except ABI width/schema.
/// Review is included in Workflow; its size is INFORMATIONAL, not counted twice.
/// Context capacity currently matches secp256k1's shared preallocated allocation.
pub const Layout = extern struct {
    schema: u32,
    pointer_bits: u32,
    sram: u32,
    workflow: u32,
    review_in_workflow: u32,
    workspace_control: u32,
    rng_control: u32,
    context_owner: u32,
    workspace: u32,
    ingress: u32,
    framebuffer: u32,
    stack_reserve: u32,
    fault_stack_reserve: u32,
    nonsecure_stack_reserve: u32,
    hal_reserve: u32,
    planned_total: u32,
    unallocated_margin: u32,
};

const planned_total = @sizeOf(Workflow) + @sizeOf(Workspace) + @sizeOf(Rng) +
    @sizeOf(ContextOwner) + workspace_bytes + ingress_bytes + framebuffer_bytes +
    stack_reserve_bytes + fault_stack_reserve_bytes + nonsecure_stack_reserve_bytes + hal_reserve_bytes;

pub const layout: Layout = .{
    .schema = 2,
    .pointer_bits = @bitSizeOf(usize),
    .sram = sram_bytes,
    .workflow = @sizeOf(Workflow),
    .review_in_workflow = @sizeOf(Review),
    .workspace_control = @sizeOf(Workspace),
    .rng_control = @sizeOf(Rng),
    .context_owner = @sizeOf(ContextOwner),
    .workspace = workspace_bytes,
    .ingress = ingress_bytes,
    .framebuffer = framebuffer_bytes,
    .stack_reserve = stack_reserve_bytes,
    .fault_stack_reserve = fault_stack_reserve_bytes,
    .nonsecure_stack_reserve = nonsecure_stack_reserve_bytes,
    .hal_reserve = hal_reserve_bytes,
    .planned_total = planned_total,
    .unallocated_margin = sram_bytes - planned_total,
};

comptime {
    if (planned_total > sram_bytes) @compileError("Provisional RP2350 SRAM reservations exceed 520 KiB");
}

test "provisional inventory avoids counting embedded review twice" {
    try std.testing.expect(layout.workflow > layout.review_in_workflow);
    try std.testing.expectEqual(@as(u32, sram_bytes), layout.planned_total + layout.unallocated_margin);
    try std.testing.expectEqual(@as(u32, workspace_bytes), layout.workspace);
}
