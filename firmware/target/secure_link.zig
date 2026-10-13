//! Offline link harness ONLY. Not a boot image, NS gateway or hardware main loop.
//! Entry halts. No synthetic approval/entropy/evidence and no real seed are embedded.
// SPDX-License-Identifier: GPL-3.0-or-later
const std = @import("std");
const zhww = @import("zhww");
const budget = zhww.memory_budget;
pub const panic = std.debug.FullPanic(panicStop);
const FatalABI = struct {
    extern fn zhww_target_fatal_enter() noreturn; // call naked entry via its external C ABI
};
fn panicStop(_: []const u8, _: ?usize) noreturn {
    FatalABI.zhww_target_fatal_enter();
}
// Compile-checked ARMv8-M fatal entry, NOT an installed exception/vector handler.
// Assumes privileged Secure execution and a parked secondary core. No FP use here.
comptime {
    @export(&fatalEntry, .{ .name = "zhww_target_fatal_enter" });
}
noinline fn fatalEntry() callconv(.naked) noreturn {
    asm volatile (
        \\cpsid i
        \\movw r0, :lower16:__fault_stack_top
        \\movt r0, :upper16:__fault_stack_top
        \\msr msp, r0
        \\mrs r1, control
        \\bic r1, r1, #2
        \\msr control, r1
        \\isb
        \\movs r0, #0
        \\mov r1, r0
        \\mov r2, r0
        \\mov r3, r0
        \\mov r4, r0
        \\mov r5, r0
        \\mov r6, r0
        \\mov r7, r0
        \\mov r8, r0
        \\mov r9, r0
        \\mov r10, r0
        \\mov r11, r0
        \\mov r12, r0
        \\mov lr, r0
        \\msr APSR_nzcvq, r0
        \\b.w zhww_target_fatal_wipe
    );
}
extern var __stack_bottom: [budget.stack_reserve_bytes]u8;
export fn zhww_target_fatal_wipe() noreturn {
    // No C destructor with a possibly corrupted context. Never resume C.
    zhww.secp256k1.poisonContextAndAbandon();
    // Fixed known spans, not lengths/pointers from potentially damaged allocator state.
    std.crypto.secureZero(u8, std.mem.asBytes(&zhww_secure_workflow));
    std.crypto.secureZero(u8, &zhww_secure_workspace);
    std.crypto.secureZero(u8, std.mem.asBytes(&workspace));
    std.crypto.secureZero(u16, &zhww_secure_framebuffer);
    // Now executing on a separate stack: old designated signing stack can be wiped.
    std.crypto.secureZero(u8, &__stack_bottom);
    // Not all possible stacks/registers: exception frames, FPU, DMA and other core pending.
    halt();
}
fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
export fn zhww_link_only_halt() noreturn {
    halt();
}
export fn secp256k1_default_illegal_callback_fn(_: [*:0]const u8, _: ?*anyopaque) void {
    FatalABI.zhww_target_fatal_enter();
}
export fn secp256k1_default_error_callback_fn(_: [*:0]const u8, _: ?*anyopaque) void {
    FatalABI.zhww_target_fatal_enter();
}

// Retained dedicated storage, NEVER large automatic objects in a real event loop.
var zhww_secure_workflow: zhww.btc_approved_sign.Workflow linksection(".secure_workflow") = .{};
export var zhww_secure_workspace: [budget.workspace_bytes]u8 linksection(".secure_workspace") = undefined;
export var zhww_secure_framebuffer: [budget.framebuffer_bytes / 2]u16 linksection(".secure_framebuffer") = undefined;
var workspace = zhww.workspace.Workspace.init(&zhww_secure_workspace);

// Internal reachability exports, NOT CMSE entry points. Do not expose to NS.
export fn zhww_link_only_prepare(evidence: *const zhww.boot_policy.Evidence, seed: *const [64]u8, raw: [*]const u8, len: usize) u32 {
    // Validate the untrusted ABI length before constructing a slice from a raw pointer.
    if (len == 0 or len > zhww.btc_review.max_request_bytes) return 1;
    zhww_secure_workflow.begin(workspace.allocator(), evidence.*, seed, raw[0..len], .regtest, 0) catch {
        // begin() invalidates the workflow; reclaim and erase parser allocations too.
        workspace.reset();
        return 1;
    };
    return 0;
}
export fn zhww_link_only_render(index: usize) u32 {
    var fb = zhww.ui_framebuffer.Framebuffer.init(&zhww_secure_framebuffer, 240, 240) catch {
        zhww_secure_workflow.abort();
        workspace.reset();
        return 1;
    };
    const page = zhww_secure_workflow.review.page(index) catch {
        zhww_secure_workflow.abort();
        workspace.reset();
        return 1;
    };
    page.render(&fb) catch {
        // A renderer/transfer failure must never leave an approvable session alive.
        zhww_secure_workflow.abort();
        workspace.reset();
        return 1;
    };
    return 0; // NO physical receipt; rendering alone never approves
}
export fn zhww_link_only_sign(raw: [*]const u8, len: usize, now: u64, rng: *zhww.rng.Rng) u32 {
    defer {
        zhww_secure_workflow.abort();
        workspace.reset();
    }
    // Reject at the ABI boundary, before raw[0..len] can describe arbitrary memory.
    if (len == 0 or len > zhww.btc_review.max_request_bytes) return 1;
    _ = zhww_secure_workflow.sign(workspace.allocator(), raw[0..len], now, rng) catch return 1;
    return 0;
}
