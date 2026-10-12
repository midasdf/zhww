const std = @import("std");

/// zhww ファームウェアのビルド定義。
///
/// 依存:
///   - libsecp256k1（pkg-config か標準のライブラリ検索パスから解決）
///     macOS:  brew install secp256k1
///     Debian: apt install libsecp256k1-dev
///
/// 使い方:
///   zig build test     テスト（公式テストベクタを含む）
///   zig build          開発用 CLI を zig-out/bin/zhww に生成
///   zig build run -- addr --mnemonic "..." --path "m/84'/0'/0'/0/0"
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // コアライブラリ（チェーン非依存 + アプリ）
    const lib = b.addModule("zhww", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    linkSecp256k1(lib);

    // 開発用 CLI（実機に画面 UI を作る前の確認手段）
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
    // 注意: Zig 0.17 ではビルド経由で引数を渡す仕組み（旧 b.args）が無いため、
    // 引数付きで使う場合は生成物を直接実行する:
    //   ./zig-out/bin/zhww address --mnemonic "..." --path "m/84'/0'/0'/0/0"
    const run_step = b.step("run", "開発用 CLI を実行する（引数は生成物に直接渡すこと）");
    run_step.dependOn(&run_cmd.step);

    // テスト（tests.zig がコアと公式テストベクタの両方をまとめる）
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
    const test_step = b.step("test", "テストを実行する");
    test_step.dependOn(&run_unit_tests.step);
}

/// libsecp256k1 をリンクする。pkg-config が使えれば include/lib を自動解決する。
fn linkSecp256k1(m: *std.Build.Module) void {
    m.linkSystemLibrary("secp256k1", .{});
    // C ランタイム（libsecp256k1 が要求する）
    m.linkSystemLibrary("c", .{});
}
