//! Test root.
//!
//! Bundles both the core unit tests (`test` blocks under src/) and the integration tests
//! based on official test vectors (tests/) into a single module and runs them together.
//!
//! Vectors are embedded verbatim as raw data from third parties (Bitcoin BIPs repository etc.).
//! **We never use home-grown expected values.**

test {
    _ = @import("src/root.zig");
    _ = @import("tests/bip39_vectors_test.zig");
    _ = @import("tests/bip32_vectors_test.zig");
    _ = @import("tests/address_vectors_test.zig");
    _ = @import("tests/bip143_test.zig");
    _ = @import("tests/bip174_test.zig");
    _ = @import("tests/sign_test.zig");
    _ = @import("tests/approved_btc_test.zig");
    _ = @import("tests/p2wpkh_guard_test.zig");
    _ = @import("tests/core_interop_test.zig");
    _ = @import("tests/multisig_test.zig");
    _ = @import("tests/taproot_test.zig");
    _ = @import("tests/fuzz_test.zig");
}
