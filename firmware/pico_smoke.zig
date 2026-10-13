//! For checking that the core compiles on RP2040 / RP2350 (bare metal).
//!
//! A smoke test to confirm the code can be ported to the Pico family without assuming Linux.
//! **It is not run by the test runner** (it is not part of `zig build test`).
//! Confirm that it compiles with a target specified, as follows:
//!
//! ```bash
//! # Check everything at once (a build.zig step)
//! zig build pico
//!
//! # Check individually
//! zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m0plus -OReleaseSmall
//! zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall
//! ```
//!
//! The only undefined symbols left are libsecp256k1 (`secp256k1_*`) and compiler-rt (`__aeabi_*`).
//! The former must be built separately for the target; the latter is supplied by Zig.
const std = @import("std");
const zhww = @import("src/root.zig");

/// Compile the security orchestration on both MCUs. Synthetic events and a hash-only
/// callback: this is NOT an actual hardware approval or signature implementation.
export fn zhww_smoke_security(evidence: *const zhww.boot_policy.Evidence, seed: *const [64]u8) usize {
    var session: zhww.signing_session.SigningSession(128, 4) = .{};
    defer session.abort();
    session.begin(evidence.*, seed, "request", &.{"review page"}, 0) catch return 0;
    session.displayed(0, "review page", 1) catch return 0;
    session.button(false, 2) catch return 0;
    session.button(true, 3) catch return 0;
    session.poll(1002) catch return 0;
    session.button(false, 1003) catch return 0;
    var sink: SecuritySmokeSink = .{};
    session.sign("request", 1004, &sink) catch return 0;
    return sink.digest[0];
}

const SecuritySmokeSink = struct {
    digest: [32]u8 = undefined,
    pub fn sign(self: *@This(), request: []const u8, seed: []const u8) !void {
        _ = seed;
        std.crypto.hash.sha2.Sha256.hash(request, &self.digest, .{});
    }
};

/// Compile the real approved BTC path with synthetic trusted events, never a
/// production main loop. External scratch budget must be measured on real hardware.
export fn zhww_smoke_approved_btc(
    evidence: *const zhww.boot_policy.Evidence,
    seed: *const [64]u8,
    raw_ptr: [*]const u8,
    raw_len: usize,
    scratch_ptr: [*]u8,
    scratch_len: usize,
) usize {
    var fba = std.heap.FixedBufferAllocator.init(scratch_ptr[0..scratch_len]);
    const allocator = fba.allocator();
    const raw = raw_ptr[0..raw_len];
    var workflow: zhww.btc_approved_sign.Workflow = .{};
    defer workflow.abort();
    workflow.begin(allocator, evidence.*, seed, raw, .regtest, 0) catch return 0;
    for (0..workflow.review.count) |i| {
        const page = workflow.review.page(i) catch return 0;
        workflow.displayed(i, page.bytes(), @intCast(i + 1)) catch return 0;
    }
    workflow.button(false, 100) catch return 0;
    workflow.button(true, 101) catch return 0;
    workflow.button(false, 1101) catch return 0;
    const output = workflow.sign(allocator, raw, 1102) catch return 0;
    return output.signed_psbt.len;
}

/// Reference address generation (BIP84) through PSBT signing so that real code gets generated.
export fn zhww_smoke(
    mnemonic_ptr: [*]const u8,
    mnemonic_len: usize,
    psbt_ptr: [*]const u8,
    psbt_len: usize,
    scratch_ptr: [*]u8,
    scratch_len: usize,
    out_address: *[90]u8,
) usize {
    var fba = std.heap.FixedBufferAllocator.init(scratch_ptr[0..scratch_len]);
    const allocator = fba.allocator();

    const keys = zhww.btc_sign.keysFromMnemonic(mnemonic_ptr[0..mnemonic_len], "") catch return 0;
    const node = keys.derive(&[_]u32{
        84 | zhww.bip32.hardened, 0 | zhww.bip32.hardened, 0 | zhww.bip32.hardened, 0, 0,
    }) catch return 0;
    const pub_key = node.publicKey() catch return 0;
    const address = zhww.btc_address.p2wpkh(out_address, pub_key, .mainnet) catch return 0;

    const parsed = zhww.btc_psbt.Psbt.parse(allocator, psbt_ptr[0..psbt_len]) catch return 0;
    const result = zhww.btc_sign.sign(allocator, parsed, keys) catch return 0;
    return address.len + result.partial_sigs.len;
}

/// Also reference the UI layer (screen and LCD driver).
export fn zhww_smoke_ui(pixels_ptr: [*]u16, count: usize, out: [*]u8, out_len: usize) usize {
    var fb = @import("src/ui/framebuffer.zig").Framebuffer.init(pixels_ptr[0..count], 240, 240) catch return 0;
    const modules: [9]u8 = .{ 1, 0, 1, 0, 1, 0, 1, 0, 1 };
    const screen = @import("src/ui/screen.zig").Screen{
        .title = "CONFIRM",
        .lines = &.{.{ .label = "To", .value = "bc1qexample" }},
        .qr = .{ .width = 3, .height = 3, .modules = &modules },
        .footer_left = "OK",
        .footer_right = "CANCEL",
    };
    screen.render(&fb);
    const device = @import("src/app/device.zig");
    const notice = device.noticeFor(.invalid_psbt);
    if (notice.title.len == 0) return 0;

    const indicator = @import("src/ui/indicator.zig");
    if (indicator.backlightOn(.idle)) return 0;
    if (!indicator.patternFor(.busy).isOnAt(0)) return 0;

    const lcd = @import("src/ui/st7789.zig");
    var driver = lcd.Driver(@import("src/ui/st7789.zig").MockTransport){ .transport = .{} };
    driver.setWindow(0, 0, 239, 239) catch return 0;
    _ = out;
    _ = out_len;
    return fb.getPixel(0, 0);
}

/// Also reference EVM and UR (to include them in the compilation).
export fn zhww_smoke_evm(
    data_ptr: [*]const u8,
    data_len: usize,
    out_ptr: [*]u8,
    out_len: usize,
) usize {
    const data = data_ptr[0..data_len];
    const out = out_ptr[0..out_len];
    // Bare metal uses a fixed buffer (page_allocator is unavailable)
    var fba = std.heap.FixedBufferAllocator.init(out);
    const decoded = zhww.evm_transaction.decode(fba.allocator(), data) catch return 0;
    var encoder = zhww.ur.Encoder.init(
        zhww.ur.type_crypto_psbt,
        decoded.data,
        40,
        zhww.ur.default_min_fragment_len,
        out[0 .. out.len / 2],
    ) catch return 0;
    var buffer: [512]u8 = undefined;
    const part = encoder.next(&buffer, .lower) catch return 0;
    return if (part) |p| p.len else 0;
}
