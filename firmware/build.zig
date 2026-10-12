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

    // 開発用 CLI
    //
    // TODO: Zig 0.17 では標準出力が `std.Io` 経由に変わったため、
    //       CLI（src/cli/main.zig）は Io の初期化方法を確定させてから追加する。
    //       検証は `zig build test` の公式テストベクタで行う。

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
