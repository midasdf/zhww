//! Public API of the zhww firmware.
//!
//! Layer separation (docs/02-architecture.md):
//!   core/  chain-agnostic: the final authority over keys, randomness, signing and display.
//!   apps/  chain-specific: never holds key material.
//!
//! Invariants:
//!   I-1 core knows nothing about any chain
//!   I-2 apps never hold key material
//!   I-3 the sighash is computed independently by apps and by core (dual-computation principle)
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
pub const btc_taproot = @import("apps/btc/taproot.zig");
pub const bytewords = @import("transport/bytewords.zig");
pub const cbor = @import("transport/cbor.zig");
pub const light = @import("transport/light.zig");
pub const light_rx = @import("transport/light_rx.zig");
pub const opt4048 = @import("transport/opt4048.zig");
pub const ur = @import("transport/ur.zig");
pub const ur_receive = @import("transport/ur_receive.zig");
pub const ui_font = @import("ui/font.zig");
pub const ui_framebuffer = @import("ui/framebuffer.zig");
pub const ui_screen = @import("ui/screen.zig");
pub const ui_st7789 = @import("ui/st7789.zig");
pub const ui_qr = @import("ui/qr.zig");
pub const ui_qr_decode = @import("ui/qr_decode.zig");
pub const block_device = @import("fs/block_device.zig");
pub const app_device = @import("app/device.zig");
pub const fs_fat32 = @import("fs/fat32.zig");
pub const ui_indicator = @import("ui/indicator.zig");
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
    _ = btc_taproot;
    _ = bytewords;
    _ = cbor;
    _ = light;
    _ = light_rx;
    _ = opt4048;
    _ = ur;
    _ = ur_receive;
    _ = ui_font;
    _ = ui_framebuffer;
    _ = ui_screen;
    _ = ui_st7789;
    _ = ui_qr;
    _ = ui_qr_decode;
    _ = block_device;
    _ = app_device;
    _ = fs_fat32;
    _ = ui_indicator;
    _ = evm_rlp;
    _ = evm_address;
    _ = evm_transaction;
    _ = evm_eip191;
    _ = evm_eip712;
    _ = evm_abi;
    _ = evm_clear_signing;
}
