# firmware/ — firmware (Zig)

> **⚠️ Experimental, in development. Do not use with real funds.**
> This code has not had a third-party audit. Screen/QR components exist on the host, but the
> target HAL, physical approval state machine, and end-to-end device main loop are not implemented,
> so this is not a hardware wallet firmware yet. Development makes **heavy use of LLMs**, and
> generated code can contain mistakes. See the [2026-10-13 internal review](../docs/10-security-audit-2026-10-13.md)
> and [../DISCLAIMER.md](../DISCLAIMER.md).

## Current status (v0.1 in development)

| Item | State |
|---|---|
| Language | **Zig** (0.17 and later) |
| Elliptic curve | **libsecp256k1** (links the C library) |
| Implemented (crypto, encoding) | Base58 / Bech32 / Bech32m / RIPEMD-160 / SHA-256 / HMAC-SHA512 / PBKDF2 / HKDF-SHA256 / Keccak-256 / ECDSA signing and verification (RFC6979, low-s, DER, recoverable) |
| Implemented (Bitcoin) | BIP39 (including dice/camera input combination) / BIP32 / address generation / transaction and PSBT parsing / legacy and BIP143 signing and finalization (P2WPKH / P2PKH / P2SH-P2WPKH / P2PK) / fee and change analysis / byte-array workflow (`signPsbtBytes`). Taproot key-path and 2-of-3 P2WSH signing are separate modules with interoperability tests, **not integrations in `signPsbtBytes`**. |
| Implemented (CLI) | `address` / `sign` / `show` (confirmation display before signing) / `screen` (preview of the device screen) / `walkthrough` (screen flow) / `card` (FAT32 image operations) / `mnemonic` (dice verification) / `ur` / `ur-decode` / `evm-sign` / `evm-show` |
| Implemented (transport) | **BC-UR** (Bytewords standard/uri/minimal, CRC-32, single-part and multi-part encode/decode, reconstruction from out-of-order parts with duplicates) |
| Implemented (EVM) | RLP encoding and decoding / EIP-55 checksummed addresses / **EIP-155 (legacy) and EIP-1559 (type 2) signing** (both are signed and then verified) / EIP-191 `personal_sign` / **EIP-712 typed data** (dependency sorting for encodeType, arrays, nesting, domain inference) / **ABI decoding** (canonical form only) / **ERC-7730 clear signing** (descriptor parsing, function matching, generation of human-readable display items, warnings for dangerous patterns) |
| Tests | **All 391 tests pass** after the 2026-10-13 review in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall. They cover official/independent BTC and EVM vectors, standalone multisig/Taproot interoperability, transport, QR, FAT32, and mutation/fuzz cases. See the [review report](../docs/10-security-audit-2026-10-13.md) for limits. |
| Not implemented | Target HAL and device main loop; physical display/approval/sign gate; session-wide secret erasure; P2TR/P2WSH integration in the normal PSBT workflow; EVM clear-signing integration; real-hardware Signet/Sepolia flow; MUR fountain recovery. |

```bash
zig build test     # 391 tests, including the official test vectors
```

## Dependencies

| Dependency | Purpose | How to get it |
|---|---|---|
| **libsecp256k1** | Key derivation and signing (the only cryptography library) | macOS: `brew install secp256k1` / Debian: `apt install libsecp256k1-dev` |
| Zig standard library | SHA-256 / SHA-512 / HMAC / PBKDF2 / Keccak | — |

> RIPEMD-160 is not in the Zig standard library and may not be available on the
> target either (Raspberry Pi OS + OpenSSL 3), so it is **implemented here**
> (`src/core/crypto/ripemd160.zig`). Verified against official test vectors.

## Module layout

```
firmware/
├── build.zig
├── tests.zig                  test root (core + official vectors)
├── src/
│   ├── root.zig               public API
│   ├── core/                  chain-agnostic. Final authority on keys and display
│   │   ├── errors.zig         error types (a parse failure must always lead to refusing to sign)
│   │   ├── encoding/
│   │   │   ├── base58.zig     Base58 / Base58Check
│   │   │   └── bech32.zig     Bech32 / Bech32m (prevents mixing up v0 and v1)
│   │   ├── crypto/
│   │   │   ├── ripemd160.zig  RIPEMD-160 (own implementation, streaming)
│   │   │   ├── hashes.zig     sha256d / hash160 / taggedHash
│   │   │   └── secp256k1.zig  minimal binding to libsecp256k1
│   │   ├── seed/
│   │   │   ├── bip39.zig      BIP39 (the word list is embedded in the binary)
│   │   │   └── entropy.zig    combines dice, camera and TRNG entropy (HKDF-SHA256)
│   │   └── derive/bip32.zig   BIP32 (CKDpriv / CKDpub / extended key serialization)
│   ├── apps/btc/              Bitcoin
│   │   ├── address.zig        address generation (P2PKH / P2SH-P2WPKH / P2WPKH / P2TR)
│   │   ├── cursor.zig         cursor for network serialization
│   │   ├── transaction.zig    transaction parsing and serialization
│   │   ├── sighash.zig        legacy / BIP143 sighash
│   │   ├── psbt.zig           PSBT parse, validate and serialize (BIP174)
│   │   ├── sign.zig           key search, signing, finalization, fees, change detection
│   │   ├── multisig.zig       building and signing 2-of-3 multisig (P2WSH)
│   │   └── taproot.zig        Taproot (BIP341) key-path signing
│   ├── transport/             air-gapped transport layer
│   │   ├── bytewords.zig      Bytewords (standard / uri / minimal)
│   │   ├── cbor.zig           CBOR needed for UR
│   │   └── ur.zig             BC-UR (single-part and multi-part)
│   └── apps/evm/              EVM
│       ├── rlp.zig            RLP encoding and decoding
│       ├── address.zig        EIP-55 checksummed addresses
│       ├── transaction.zig    EIP-155 / EIP-1559 signing
│       ├── eip191.zig         personal_sign
│       ├── eip712.zig         typed data
│       ├── abi.zig            ABI decoding (parsing calldata)
│       └── clear_signing.zig  human-readable display via ERC-7730 descriptors
└── tests/                     integration tests based on official test vectors
```

## Target invariants (not yet enforced end to end)

The current host-side implementation does not yet satisfy I-2 or I-3. Application modules receive
private keys, and there is no independent second signing-hash computation. See the
[2026-10-13 review](../docs/10-security-audit-2026-10-13.md).

| ID | Target property |
|---|---|
| I-1 | `core` knows nothing about chains |
| I-2 | `apps` does not hold key material (it requests a signature only as "these 32 bytes with this path") |
| I-3 | The sighash is computed independently by `apps` and `core`, and if they do not match, nothing is signed |
| I-4 | Secrets are never written to flash, SD or swap |
| I-5 | USB data communication is disabled in release builds |

## Design decisions and their rationale

| Decision | Rationale |
|---|---|
| **No dynamic memory** (the core uses fixed-size buffers and slices) | Structurally eliminates fragmentation, allocation failure and freeing mistakes. Behaviour on embedded targets becomes predictable |
| **Use libsecp256k1 as the only cryptographic primitive** | A pure Zig implementation would not resist timing attacks, so it is not used for operations involving private keys |
| **Declare only the needed functions as extern instead of `@cImport`-ing the C headers** | At audit time it is obvious at a glance which C functions we depend on |
| **Implement RIPEMD-160 here** | Some environments can depend on neither the standard library nor OpenSSL (verified against official vectors) |
| **Embed the BIP39 word list in the binary** (`@embedFile`) | Removes the runtime filesystem dependency. It also reduces the tampering surface |
| **`derivePath` accepts an absolute path (`m/...`) only on a master key** | Passing "m/0'/1" to a non-master key descends one level too many. The tests actually detected this bug in this implementation, so the API forbids it |
| **Explicitly reject non-ASCII passphrases** | NFKD normalization is not implemented. Failing with an error is safer than silently producing a different seed |

## Portability to the Pico family (RP2040 / RP2350)

Whether the core can be put on the Pico family, which does not assume Linux, is checked by compiling on every run
(see section 2.3 of [docs/03-hardware-bom.md](../docs/03-hardware-bom.md) for details and the conclusions).

```bash
zig build pico     # check both RP2040 (Cortex-M0+) and RP2350 (Cortex-M33)
```

The referenced smoke paths (BIP39/32, address generation, PSBT parsing/signing, screen rendering,
EVM decoding and UR) compile for both targets. libsecp256k1 has also been compiled separately for
both targets. This is a compile check, not execution. The HAL (LCD, buttons, camera, SD, RNG) and
the device approval loop are not implemented.

## Development CLI

The CLI exercises host-side components. Signing commands sign immediately and do not implement the
future device's physical approval gate; use them only for test vectors and development.

```bash
zig build                      # produces zig-out/bin/zhww
cd firmware

# Address (result to stdout, diagnostics to stderr)
./zig-out/bin/zhww address --mnemonic "abandon abandon … about"
./zig-out/bin/zhww address --mnemonic "…" --path "m/86'/0'/0'/0/0" --kind p2tr
./zig-out/bin/zhww address --mnemonic "…" --network signet --kind p2wpkh

# Sign a PSBT (reads base64 from stdin)
cat psbt.txt | ./zig-out/bin/zhww sign --mnemonic "…"
#   → SIGNED_PSBT=<base64> and FINAL_TX=<hex> to stdout
#   → number of signatures, fee, change and warnings to stderr

# Recompute the mnemonic from a dice record (for verifying the record)
./zig-out/bin/zhww mnemonic --dice "123456123456…" --words 12
./zig-out/bin/zhww mnemonic --dice "…" --words 24 --camera aabbccdd

# Sign an EVM transaction (JSON from stdin)
echo '{"chainId":1,"nonce":7,"gasLimit":21000,"maxFeePerGas":30000000000,
       "maxPriorityFeePerGas":1000000000,"to":"0x…","value":123456789,"data":"0x"}' \
  | ./zig-out/bin/zhww evm-sign --mnemonic "…"
#   → signed raw tx to stdout (sender address and type to stderr)

# Display an EVM transaction (raw hex; does not sign)
./zig-out/bin/zhww evm-show < raw_tx.hex
#   → shows the type, chain ID, destination (EIP-55), amount, fee and the calldata
#     function name, and warns about unknown functions or dangerous operations (approve, etc.)

# Check "what am I about to sign" before signing (instead of the screen)
cat psbt.txt | ./zig-out/bin/zhww show --network regtest --mnemonic "…"
#   → shows the inputs (amount, address), outputs (payment/change) and the fee

# Turn a PSBT into UR (for QR transport) and print one part per line
cat psbt.txt | ./zig-out/bin/zhww ur --fragment 40
#   → printed like ur:crypto-psbt/1-4/… (each frame of the animated QR)

# Output the device screen flow (waiting for card → confirmation → result QR) as PNGs
./zig-out/bin/zhww walkthrough --image card.img --mnemonic "…" --out-dir .

# Check the device screen (240×240) as a PNG (lets you polish the UI without hardware)
./zig-out/bin/zhww screen --demo --scale 2 > demo.png
cat psbt.txt | ./zig-out/bin/zhww screen --qr --scale 2 > qr.png   # show UR as QR

# Read UR parts back into a PSBT
./zig-out/bin/zhww ur-decode < parts.txt
```

**Output policy**: results go to stdout, diagnostics (fees, warnings) to stderr.
That makes it composable as-is, e.g. `zhww sign < psbt.txt > signed.txt`.

## Implementations we reference

| Project | What we reference |
|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | Dice entropy, SeedQR, air-gapped operation, [reproducible build procedure](https://github.com/SeedSigner/seedsigner-os/blob/main/docs/building.md) |
| [Krux](https://github.com/selfcustody/krux) | Screen design, entropy measurement, code structure |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | Secure bootloader, [how to write a security model](https://github.com/cryptoadvance/specter-diy/blob/master/docs/security-model.md) |
| [libsecp256k1](https://github.com/bitcoin-core/secp256k1) | The sole provider of cryptographic primitives |

## License

**GPL-3.0-or-later** ([../LICENSE-POLICY.md](../LICENSE-POLICY.md))
