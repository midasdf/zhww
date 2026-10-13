const std = @import("std");

/// Build definition for the zhww firmware.
///
/// Dependencies:
///   - libsecp256k1 (resolved through pkg-config or the standard library search path)
///     macOS:  brew install secp256k1
///     Debian: apt install libsecp256k1-dev
///
/// Usage:
///   zig build test     tests (including the official test vectors)
///   zig build          build the development CLI into zig-out/bin/zhww
///   zig build run -- addr --mnemonic "..." --path "m/84'/0'/0'/0/0"
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library (chain-independent + apps)
    const lib = b.addModule("zhww", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSecp256k1(lib);

    const pico_step = b.step("pico", "Check that the core compiles for the Pico family (RP2040 / RP2350)");

    // Compile target ABI sizes into an ELF constant and inspect it without execution.
    // Stack/HAL entries are provisional reserves, not a linked-image fit guarantee.
    const memory_cmd = b.addSystemCommand(&.{"python3"});
    memory_cmd.addFileArg(b.path("../tools/check_memory_layout.py"));
    memory_cmd.addArgs(&.{ "--zig", b.graph.zig_exe });
    const memory_step = b.step("memory", "Check the provisional Cortex-M33 SRAM inventory (requires Python 3)");
    memory_step.dependOn(&memory_cmd.step);

    // Development CLI (a way to check things before building the on-device screen UI)
    const cli_module = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_module.addImport("zhww", lib);
    linkSecp256k1(cli_module);

    const exe = b.addExecutable(.{
        .name = "zhww",
        .root_module = cli_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    // Note: Zig 0.17 has no way to pass arguments through the build (the old b.args),
    // so to use arguments, run the built artifact directly:
    //   ./zig-out/bin/zhww address --mnemonic "..." --path "m/84'/0'/0'/0/0"
    const run_step = b.step("run", "Run the development CLI (pass arguments directly to the built artifact)");
    run_step.dependOn(&run_cmd.step);

    // Check that the core compiles for the Pico family (bare metal)
    //
    // A step to see whether the code can be ported to RP2040 / RP2350 without assuming Linux.
    // It is not run (we only check that an object file can be produced).
    inline for (.{
        .{ "pico_rp2040", &std.Target.arm.cpu.cortex_m0plus },
        .{ "pico_rp2350", &std.Target.arm.cpu.cortex_m33 },
    }) |config| {
        const pico_target = b.resolveTargetQuery(.{
            .cpu_arch = .thumb,
            .os_tag = .freestanding,
            .cpu_model = .{ .explicit = config[1] },
        });

        // We do not link the host libsecp256k1 (building it for the target is part of the porting work).
        // Here we only check whether the Zig core compiles for this target.
        const pico_core = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = pico_target,
            .optimize = .ReleaseSmall,
        });
        const pico_module = b.createModule(.{
            .root_source_file = b.path("pico_smoke.zig"),
            .target = pico_target,
            .optimize = .ReleaseSmall,
        });
        pico_module.addImport("zhww", pico_core);

        const pico_object = b.addObject(.{ .name = config[0], .root_module = pico_module });
        pico_step.dependOn(&pico_object.step);
    }

    // Tests (tests.zig bundles both the core and the official test vectors)
    const test_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSecp256k1(test_module);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run the tests");
    test_step.dependOn(&run_unit_tests.step);
}

/// Link libsecp256k1. If pkg-config is available, include/lib paths are resolved automatically.
fn linkSecp256k1(m: *std.Build.Module) void {
    m.linkSystemLibrary("secp256k1", .{});
    // C runtime (required by libsecp256k1)
    m.linkSystemLibrary("c", .{});
}
