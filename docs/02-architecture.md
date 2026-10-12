# 02. Architecture

- **Target version**: v0.1
- **Last updated**: 2026-10-12

---

## 1. Overall structure

```
                 ┌────────────────────────────────────────────────────────────────┐
                 │  Host (untrusted)                                              │
                 │  Sparrow / Electrum / MetaMask / any dApp                      │
                 └───────┬──────────────────────────┬─────────────────────────────┘
                         │ PSBT / tx JSON           │ signed data
                         │ (QR or SD)               │
┌────────────────────────▼──────────────────────────▼──────────────────────────────┐
│ zhww device (air-gapped)                                                         │
│                                                                                  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │ UI layer   screen (240x240) / joystick / 3 buttons / camera                │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │ apps/  chain-specific logic (isolated from the core)                       │  │
│  │   btc/   PSBT parsing, BIP32 paths, addresses, fees, change detection      │  │
│  │   evm/   RLP/EIP-1559, EIP-191/712, ERC-20, ERC-7730 display               │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │ core/  chain-agnostic (final authority over keys and display)              │  │
│  │   seed      BIP39 / passphrase / dice and camera entropy                   │  │
│  │   derive    BIP32 (secp256k1)                                              │  │
│  │   sign      libsecp256k1 / RFC6979 deterministic nonce                     │  │
│  │   verify    independent recomputation of displayed hash (dual computation) │  │
│  │   render    clear signing descriptor → screen items                        │  │
│  │   wipe      erasure of session secrets                                     │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │ fs/  (microSD / FAT32)                                                     │  │
│  │ transport/  QR (BC-UR, animated) / USB-CDC (optional) / SD                 │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────────────────────────────┐  │
│  │ OS: Raspberry Pi OS Lite / read-only rootfs / tmpfs only                   │  │
│  └────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────┘
```

> Note: the `OS` row describes the v0.1 Linux build. The main v0.2 target, the RP2350-PiZero, is a microcontroller board that does not run Linux ([08-rp2350-pizero.md](08-rp2350-pizero.md)); there the firmware runs directly on the MCU, with no OS layer. The firmware has not yet run on any hardware.

## 2. Layer responsibilities and prohibited actions

| Layer | Responsibility | Prohibited |
|---|---|---|
| `transport/` | Raw byte input/output, QR splitting and reassembly, SD reads and writes | Interpreting payloads (interpretation happens in apps and above) |
| `apps/` | Chain-specific parsing, generating display items, computing the hash to be signed | Direct access to the seed and extended private keys |
| `core/` | Key derivation, signing, final confirmation of what is displayed, erasure of secrets | Chain-specific interpretation (handles only the hash received from `apps/`) |

**Invariant I-1**: `core` does not know "which chain" it is dealing with.
**Invariant I-2**: `apps` holds no key material. Signing is limited to calling the `core` API with "this path, these 32 bytes".
**Invariant I-3**: The hash to be signed is computed **independently** by `apps` and `core`, and signing does not proceed unless the two match (the dual-computation principle). This prevents a bug on the `apps` side from turning into a "mismatch between what is displayed and what is actually signed".

## 3. Key management

### 3.1 Generation

```
entropy = HKDF( dice_entropy || camera_entropy || soc_trng )
mnemonic = BIP39( entropy, word_count )
seed64   = PBKDF2-HMAC-SHA512( mnemonic, "mnemonic" || passphrase, 2048 )
```

- Dice are a mandatory input (12 words: 50 rolls, 24 words: 99 rolls). Camera-image entropy and the SoC TRNG are **additional** contributions, not replacements.
- The BIP39 checksum is verified immediately after generation, and both an on-screen display and SeedQR output are provided.
- For random-number quality, a simple health test (repeated-pattern detection, bit distribution) runs at boot, and generation is aborted if it fails.

### 3.2 Derivation (scope supported in v0.1)

| Purpose | Path |
|---|---|
| Bitcoin P2PKH (BIP44) | `m/44'/0'/0'/0/i` |
| Bitcoin P2SH-P2WPKH (BIP49) | `m/49'/0'/0'/0/i` |
| Bitcoin P2WPKH (BIP84) | `m/84'/0'/0'/0/i` |
| Bitcoin P2TR (BIP86) | `m/86'/0'/0'/0/i` |
| Bitcoin multisig (P2WSH) | `m/48'/0'/0'/2'` |
| EVM (common to all EVM chains) | `m/44'/60'/0'/0/i` |

EVM gives priority to interoperability and defaults to `60'`. Some chains have their own SLIP-44 numbers, such as Polygon (966) and Optimism (614), but the major wallets use 60 in common. This can be switched in settings, but the default is 60.

### 3.3 Protection policy

- The seed is expanded only in RAM and is **zeroed on exit**.
- Nothing is persisted except settings (display unit, chainId, etc.). No secrets are written to persistent storage.
- The SD card is unmounted after boot completes, or remounted read-only.

## 4. Signing flow

```
Host                  transport      apps                   core               screen
  │                       │            │                      │                   │
  │ PSBT / tx JSON        │            │                      │                   │
  ├──────────────────────►│ raw bytes  │                      │                   │
  │                       ├───────────►│ parse                │                   │
  │                       │            │ display items + hash │                   │
  │                       │            ├─────────────────────►│ hash recomputation│
  │                       │            │                      │ match check       │
  │                       │            │                      ├──────────────────►│
  │                       │            │                      │                   │ destination, amount
  │                       │            │                      │◄──────────────────┤ fee, chainId
  │                       │            │                      │ user approval     │
  │                       │            │                      │ expand seed → derive → sign
  │                       │◄───────────┴──────────────────────┤                   │
  │ signed PSBT / tx      │◄──────────────────────────────────┘                   │
  │◄──────────────────────┤                                                       │
  │                       │                                     memory wipe       │
```

### 4.1 Mandatory requirements for the approval UI

1. The destination address must be **displayed in full** (paging is allowed; truncation with an ellipsis in the middle is forbidden)
2. Amounts are displayed in human units (BTC / ETH / token amount), not in the smallest unit. For tokens, decimals are taken from the descriptor
3. Fees are shown as an absolute amount and, where possible, as an estimated rate
4. EVM must always display the chainId (the same address exists on multiple chains)
5. Unknown contracts and unknown function selectors get a red warning and an explicit extra approval
6. Before approval, display the "hash to be signed" (so that it can be compared against the host)

## 5. Communication specifications

| Path | Format | Use |
|---|---|---|
| QR (BC-UR) | `ur:crypto-psbt`, `ur:bytes`, animated | BTC signing requests/responses, EVM transactions |
| QR (SeedQR) | standard / Compact SeedQR | Loading the seed |
| SD card | PSBT file, JSON | Large transactions, firmware updates |
| USB-CDC (optional) | Raw bytes | Development and debugging. Disabled by default, and disabled in release builds |

Enabling USB breaks the air gap, so **USB data communication is disabled in release builds**, which are treated as power-only.

## 6. Dependency policy

The implementation language is **Zig** ([firmware/README.md](../firmware/README.md)).

| Use | Policy |
|---|---|
| Elliptic curve | **libsecp256k1** only. A pure home-grown implementation does not resist timing attacks, so it is not used for operations that handle private keys |
| SHA-256 / SHA-512 / HMAC / PBKDF2 | Zig standard library (`std.crypto`) |
| RIPEMD-160 | **Implemented in-house**, because some environments can depend on neither the Zig standard library nor OpenSSL (verified against the official vectors) |
| Keccak-256 | Zig standard library (`std.crypto.hash.sha3.Keccak256`). Do not confuse it with SHA3-256 |
| RLP | Implemented in-house. Exact agreement with the official test vectors is mandatory |
| QR | Port the BC-UR reference implementation: done (Bytewords / CBOR / single- and multi-part). On-device QR input/output is not implemented yet — the UI is a host-side preview |

**Memory policy**: the core uses no dynamic memory (fixed-size buffers and slices). This structurally rules out
allocation failure, leaks and fragmentation, and makes embedded behaviour predictable.

## 7. Error handling

- Parse failures, checksum mismatches and descriptor chainId mismatches **all reject signing**, and the reason is displayed on screen.
- If the two independent computations of the hash to be signed do not match, the session is destroyed immediately and a restart is prompted (possible tampering or a bug).
- On an unexpected exception, the seed is wiped and the device returns to the equivalent of a power-off state.

## 8. Testing policy

| Target | Method |
|---|---|
| BIP39/32/84/86 | Match the test vectors given in the specifications |
| PSBT | Sign PSBTs generated by Bitcoin Core and verify them with Core (the current implementation's single-signature, 2-of-3 multisig and Taproot signatures are accepted by Core) |
| EIP-155 / 1559 | Test vectors from the EIPs, and byte-for-byte agreement with signatures from viem / ethers.js |
| EIP-712 | Compare domainSeparator / hashStruct against known typed-data samples |
| ERC-7730 display | Snapshot tests of the display items given descriptor samples |
| Seed residue | After power loss, dump the SD card and flash and confirm that no mnemonic, seed or extended private key byte sequences are present |
