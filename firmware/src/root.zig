//! zhww ファームウェアの公開 API。
//!
//! 層の分離（docs/02-architecture.md）:
//!   core/  チェーン非依存。鍵・乱数・署名・表示の最終責任者
//!   apps/  チェーン固有。鍵素材を保持しない
//!
//! 不変条件:
//!   I-1 core はチェーンを知らない
//!   I-2 apps は鍵素材を保持しない
//!   I-3 署名対象ハッシュは apps と core が独立に計算する（二重計算の原則）

pub const errors = @import("core/errors.zig");
pub const base58 = @import("core/encoding/base58.zig");
pub const bech32 = @import("core/encoding/bech32.zig");
pub const hashes = @import("core/crypto/hashes.zig");
pub const secp256k1 = @import("core/crypto/secp256k1.zig");
pub const bip39 = @import("core/seed/bip39.zig");
pub const bip32 = @import("core/derive/bip32.zig");
pub const btc_address = @import("apps/btc/address.zig");

test {
    _ = base58;
    _ = bech32;
    _ = hashes;
    _ = secp256k1;
    _ = bip39;
    _ = bip32;
    _ = btc_address;
}
