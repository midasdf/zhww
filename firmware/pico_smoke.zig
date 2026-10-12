//! RP2040 / RP2350（ベアメタル）でコアがコンパイルできるかの確認用。
//!
//! Linux を前提にしない Pico 系へ移植できるかを確かめるためのスモークテスト。
//! **テストランナーでは実行しない**（`zig build test` の対象ではない）。
//! 次のように、ターゲットを指定してコンパイルが通ることを確認する:
//!
//! ```bash
//! # まとめて確認する場合（build.zig のステップ）
//! zig build pico
//!
//! # 個別に確認する場合
//! zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m0plus -OReleaseSmall
//! zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall
//! ```
//!
//! 未定義シンボルは libsecp256k1（`secp256k1_*`）と compiler-rt（`__aeabi_*`）だけになる。
//! 前者はターゲット向けに別途ビルドが必要、後者は Zig が供給する。
const std = @import("std");
const zhww = @import("src/root.zig");

/// アドレス生成（BIP84）と PSBT 署名までを参照させて、実際にコード生成させる。
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

/// EVM と UR も参照させる（コンパイル対象に含める）。
export fn zhww_smoke_evm(
    data_ptr: [*]const u8,
    data_len: usize,
    out_ptr: [*]u8,
    out_len: usize,
) usize {
    const data = data_ptr[0..data_len];
    const out = out_ptr[0..out_len];
    // ベアメタルでは固定バッファを使う（page_allocator は使えない）
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
