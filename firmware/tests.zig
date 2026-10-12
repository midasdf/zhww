//! テストのルート。
//!
//! コアのユニットテスト（src/ 内の `test` ブロック）と、公式テストベクタによる
//! 統合テスト（tests/）の両方を 1 つのモジュールにまとめて実行する。
//!
//! ベクタは第三者（Bitcoin BIPs リポジトリ等）の生データをそのまま埋め込む。
//! **自前の期待値は使わない。**

test {
    _ = @import("src/root.zig");
    _ = @import("tests/bip39_vectors_test.zig");
    _ = @import("tests/bip32_vectors_test.zig");
    _ = @import("tests/address_vectors_test.zig");
    _ = @import("tests/bip143_test.zig");
    _ = @import("tests/bip174_test.zig");
    _ = @import("tests/sign_test.zig");
    _ = @import("tests/core_interop_test.zig");
    _ = @import("tests/multisig_test.zig");
}
