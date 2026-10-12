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
// SPDX-License-Identifier: GPL-3.0-or-later

pub const errors = @import("core/errors.zig");
pub const base58 = @import("core/encoding/base58.zig");
pub const bech32 = @import("core/encoding/bech32.zig");
pub const hashes = @import("core/crypto/hashes.zig");
pub const secp256k1 = @import("core/crypto/secp256k1.zig");
pub const bip39 = @import("core/seed/bip39.zig");
pub const entropy = @import("core/seed/entropy.zig");
pub const bip32 = @import("core/derive/bip32.zig");
pub const btc_address = @import("apps/btc/address.zig");
pub const btc_cursor = @import("apps/btc/cursor.zig");
pub const btc_transaction = @import("apps/btc/transaction.zig");
pub const btc_sighash = @import("apps/btc/sighash.zig");
pub const btc_psbt = @import("apps/btc/psbt.zig");
pub const btc_sign = @import("apps/btc/sign.zig");
pub const btc_multisig = @import("apps/btc/multisig.zig");
pub const bytewords = @import("transport/bytewords.zig");
pub const cbor = @import("transport/cbor.zig");
pub const ur = @import("transport/ur.zig");
pub const evm_rlp = @import("apps/evm/rlp.zig");
pub const evm_address = @import("apps/evm/address.zig");
pub const evm_transaction = @import("apps/evm/transaction.zig");
pub const evm_eip191 = @import("apps/evm/eip191.zig");
pub const evm_eip712 = @import("apps/evm/eip712.zig");
pub const evm_abi = @import("apps/evm/abi.zig");
pub const evm_clear_signing = @import("apps/evm/clear_signing.zig");

test {
    _ = base58;
    _ = bech32;
    _ = hashes;
    _ = secp256k1;
    _ = bip39;
    _ = entropy;
    _ = bip32;
    _ = btc_address;
    _ = btc_cursor;
    _ = btc_transaction;
    _ = btc_sighash;
    _ = btc_psbt;
    _ = btc_sign;
    _ = btc_multisig;
    _ = bytewords;
    _ = cbor;
    _ = ur;
    _ = evm_rlp;
    _ = evm_address;
    _ = evm_transaction;
    _ = evm_eip191;
    _ = evm_eip712;
    _ = evm_abi;
    _ = evm_clear_signing;
}
