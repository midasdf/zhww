# 04. Per-chain implementation specification (BTC / EVM)

- **Target version**: v0.1
- **Last updated**: 2026-10-12

---

## 1. Support matrix

**Status**: ✅ implemented / 🔄 in progress / ⬜ not started / ❌ out of scope

| Feature | BTC | EVM | Priority |
|---|---|---|---|
| Single-sig P2WPKH (BIP84) | ✅ Implemented | — | Required |
| Single-sig P2PKH / P2SH-P2WPKH | ✅ Implemented | — | Medium |
| Single-sig P2PK | ✅ Implemented (signing and finalization) | — | — |
| Multisig P2WSH (no P2SH) | ✅ Implemented (2-of-3; BIP67 sorting also supported) | — | High |
| Taproot key-path (BIP86) | ✅ Implemented (address generation and key-path signing; script path is out of scope) | — | Medium |
| Taproot script-path | ❌ Out of scope | — | — |
| PSBT (BIP174) parse / validate / serialize | ✅ Implemented | — | Required |
| Legacy / EIP-1559 transactions | — | ✅ Implemented | Required |
| ERC-20 transfer / approve | — | ✅ Implemented (with warnings for dangerous patterns) | Required |
| EIP-191 personal_sign | — | ✅ Implemented | Required |
| EIP-712 typed data v4 | — | ✅ Implemented | Required |
| ERC-7730 clear signing | — | ✅ Implemented (descriptor application and warnings) | High |
| QR transport (BC-UR) | ✅ Implemented (Bytewords / CBOR / single- and multi-part) | ✅ Same as BTC | Required |
| ed25519-family chains | ❌ v0.2 or later | ❌ | — |

---

## 2. Bitcoin

### 2.1 Address generation

| Type | Path | Encoding | Notes |
|---|---|---|---|
| P2PKH | `m/44'/0'/0'/0/i` | Base58Check | `1...` |
| P2SH-P2WPKH | `m/49'/0'/0'/0/i` | Base58Check | `3...` |
| P2WPKH | `m/84'/0'/0'/0/i` | Bech32 | `bc1q...` |
| P2TR | `m/86'/0'/0'/0/i` | Bech32m | `bc1p...` |
| P2WSH (multisig) | `m/48'/0'/0'/2'` | Bech32 | `bc1q...` (32 bytes) |

- **Confusing Bech32 with Bech32m is fatal**. P2WPKH uses Bech32 (checksum constant 1), P2TR uses Bech32m (0x2bc830a3). Keep the constants separate in the implementation and verify both with test vectors.
- The HRP and version byte differ per network (mainnet / testnet / signet / regtest). **Verification on testnet is mandatory**.

### 2.2 PSBT (BIP174)

**Acceptance validation**

1. Parse `PSBT_GLOBAL_UNSIGNED_TX` or the PSBTv2 fields
2. Confirm that every input has either `witness_utxo` or `non_witness_utxo`
   - **Refuse to sign a PSBT that contains an input with neither.** If the input amount is unknown, the fee cannot be displayed and a fee attack cannot be detected
3. Confirm that each input's `PSBT_IN_BIP32_DERIVATION` (or master fingerprint) matches a key derived from this device's seed
4. Classify the outputs as "payment" or "change"
   - Change detection actually derives `m/84'/0'/0'/1/i` and checks for a script match (it does not rely on heuristics)

**Signing**

- SegWit: implement the BIP143 sighash. `SIGHASH_ALL` is the basis; `ANYONECANPAY` is unsupported (or triggers a strong warning)
- Legacy: the legacy sighash (scriptCode is the scriptPubKey of the previous output)
- Taproot: only `SIGHASH_DEFAULT` key-path. **Script path is not implemented** (high risk of misimplementation)

**Items that must always be displayed before signing**

| Item | Requirement |
|---|---|
| Destination address | List every output. Show in full; no truncation |
| Amount | Show in both BTC and sats |
| Type | Mark clearly as payment / change. Only outputs identified as change by key match count |
| Fee | Absolute amount (sats) + fee rate (sat/vB). Computed from the input and output script lengths |
| Number of inputs / outputs | For checking that the list is consistent |
| Hash to be signed | The value recomputed independently by `core` (the double-computation principle) |

**Conditions that trigger a warning**

- The fee exceeds 10% of the total input amount, or exceeds 100,000 sats
- The same PSBT contains multiple outputs to the same address
- Only `non_witness_utxo` was supplied (warning from the standpoint of excessive size and parsing load)
- There are more than 2 outputs and one of them is not change (prevents missing a destination)

### 2.3 QR / files

- **BC-UR**: `ur:crypto-psbt` (single), `ur:bytes`. Large payloads are sent and received as animated QR (split into frames)
- **SeedQR**: standard (12 words: 25×25 / 24 words: 29×29), Compact SeedQR (12 words: 21×21 / 24 words: 25×25)
- **SD card**: read and write `.psbt` files. As a rule, unmount after boot

### 2.4 Test vectors

| Target | Source |
|---|---|
| BIP39 checksum, mnemonic→seed | Official vectors from the BIP39 specification |
| BIP32 derivation, xpub | Official BIP32 vectors |
| BIP84 zpub / addresses | Official BIP84 vectors |
| PSBT signing | Created and verified with Bitcoin Core (regtest / signet); Core accepts the single-sig, 2-of-3 multisig and Taproot signatures |
| Change detection | Cross-checked against PSBTs created with Core |

---

## 3. EVM

### 3.1 Transaction types

| Type | Leading byte | Purpose | v0.1 |
|---|---|---|---|
| Legacy | None | Old style. Uses `gasPrice` | ✅ |
| EIP-2930 (type 1) | `0x01` | Legacy with an access list | ⚪ Optional |
| EIP-1559 (type 2) | `0x02` | Current standard | ✅ |
| EIP-4844 (type 3) | `0x03` | Blob transactions | ❌ |
| EIP-7702 (type 4) | `0x04` | Account delegation | ❌ Future |

**Hash to be signed**

```
legacy  : keccak256( RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]) )
type 1/2: keccak256( type_byte || RLP([...fields..., excluding the signature fields]) )
```

For typed transactions, **the leading type byte must always be included**. Drop it and the signature will not verify.

**Signature values**

- `yParity` is `0/1` for typed transactions; for legacy EIP-155, `v = chainId * 2 + 35 + yParity`
- `s` must be **low-s normalized** (`s <= n/2`)
- Nonces use deterministic generation (RFC6979), yielding `r || s || yParity`

### 3.2 RLP implementation notes

RLP is a breeding ground for implementation bugs. Always test the following.

- A single byte `0x00–0x7f` is encoded as-is (no prefix)
- Leading zero bytes are stripped (`0x00` is the empty string, `0x0042` is `0x42`)
- Prefix switching between short and long strings (the 55-byte boundary)
- Empty lists, empty strings (`to` empty = contract creation)
- Exact agreement with the official test vectors

### 3.3 Display requirements

| Item | Requirement |
|---|---|
| chainId | **Always display**. The same address exists on multiple chains |
| Destination | Show `0x` + 40 hex characters **in full** (no truncation) |
| Amount | ETH has 18 decimals. Also show the raw value in wei |
| Gas | `maxFeePerGas` / `maxPriorityFeePerGas`, and the maximum cost `gasLimit × maxFeePerGas` |
| `to` is empty | Red warning as "contract creation" + additional approval |
| `data` is empty | Display as a "plain transfer" |
| Unknown contract | Warning + display of the Keccak-256 hash of the raw calldata |

Compute the **EIP-55 checksum** and display mixed-case text so the user can check it visually.

### 3.4 ERC-20 and dangerous patterns

| Selector | Function | Display | Warning |
|---|---|---|---|
| `0xa9059cbb` | `transfer(address,uint256)` | Destination, token amount | — |
| `0x095ea7b3` | `approve(address,uint256)` | Spender, approved amount | `2^256-1` triggers a red warning as "unlimited approval" |
| `0x23b872dd` | `transferFrom(...)` | From, to, amount | — |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | Approval for all tokens | Always a red warning |
| `0xd505accf` | `permit` (EIP-2612) | Spender, amount, deadline | Treat a **signature as equivalent to an approve** |
| `0x39509351` etc. | `increaseAllowance` | Increase in allowance | Warning if the current value is unknown |

**Displaying token amounts**: when `decimals` and `symbol` are unknown, **do not guess**. If `decimals` is unknown, show the raw integer value plus a "unit unknown" warning. Obtain metadata from ERC-7730 descriptors or from a signed token list, and display its source on the screen.

### 3.5 EIP-191 / EIP-712

- **EIP-191 (personal_sign)**: Keccak-256 over `"\x19Ethereum Signed Message:\n" + len(message) + message`. Display the message body in full (page through long messages). Always display a notice that **even if the message says it is "only asking for a signature", its content is not guaranteed**.
- **EIP-712 (typed data v4)**:
  - Recompute `domainSeparator` and display `verifyingContract`, `chainId`, `name` and `version`
  - Compute `hashStruct` recursively (structs, dynamic types, arrays, `bytes`) and display it under human-readable field names
  - **A red warning if `verifyingContract` is unknown**. This is the main battleground for phishing
  - Impose limits on array length and nesting depth, and refuse to sign when they are exceeded (prevents DoS and display spoofing)

### 3.6 Clear signing with ERC-7730

[ERC-7730](https://eips.ethereum.org/EIPS/eip-7730) is a metadata standard that maps contract functions and messages onto human-readable fields. The descriptor registry was [transferred to the Ethereum Foundation in May 2026](https://developers.ledger.com/docs/clear-signing/overview), and [clearsigning.org](https://clearsigning.org) and [ethereum/clear-signing-erc7730-registry](https://github.com/ethereum/clear-signing-erc7730-registry) are now the canonical sources.

**Implementation policy**

1. Ship the descriptors (JSON) **bundled in the signed release**. Do not fetch them from the network at runtime (for air-gap and tamper prevention)
2. Verify that the descriptor's `chainId` matches the transaction's `chainId`. Reject a mismatch
3. Apply a descriptor only when the `to` address and the function selector match its entry
4. If there is no match, **fall back to raw display (with a warning)** and never guess
5. Display the descriptor's hash and version on the screen so they can be checked externally

### 3.7 Initial chainId support

| chainId | Network |
|---|---|
| 1 | Ethereum Mainnet |
| 10 | OP Mainnet |
| 137 | Polygon PoS |
| 324 | zkSync Era |
| 8453 | Base |
| 42161 | Arbitrum One |
| 59144 | Linea |
| 534352 | Scroll |
| 11155111 | Sepolia (for testing; mandatory) |

### 3.8 Test vectors

| Target | Method |
|---|---|
| RLP | Exact agreement with the official test vectors |
| EIP-155 / 1559 signing | The examples given in the EIPs, plus byte-for-byte agreement with signatures from viem / ethers.js |
| ERC-20 decoding | Decode and verify using calldata extracted from real transactions (Sepolia) |
| EIP-712 | Cross-check `domainSeparator` / `hashStruct` against known samples |
| ERC-7730 display | Snapshot tests of sample descriptors |
| Error cases | Over-long arrays, deep nesting, chainId mismatch, unknown selector |

---

## 4. Implementation order (dependencies)

```
M1  BTC BIP84 single-sig (address generation → PSBT signing → QR response)
        │
        ├─► M1.5 BTC fees, change detection, warnings
        │
        ▼
M2  EVM Legacy/EIP-1559 (RLP → signing → chainId display)
        │
        ├─► M2.5 ERC-20 transfer/approve + dangerous-pattern warnings
        │
        └─► M2.6 EIP-191 / EIP-712
                     │
                     ▼
              M3  ERC-7730 clear signing (can run in parallel with BTC multisig and Taproot)
```

**Why BTC is implemented first**: the idea of matching what is displayed with what is signed (clear signing) can be established first on PSBT, whose specification is mature. EVM is implemented by reusing that structure.
