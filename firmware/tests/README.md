# firmware/tests/ — tests and official test vectors

- **Last updated**: 2026-10-12

```bash
cd firmware && zig build test
```

`firmware/tests.zig` runs both the implementation's unit tests (the `test` blocks under `src/`) and
the integration tests based on official test vectors (this directory).

**Currently: all 322 tests pass.** (Verified to pass in all four modes — Debug / ReleaseSafe /
ReleaseFast / ReleaseSmall. GitHub Actions also checks this on Linux on every run.)

## The strongest verification: Bitcoin Core accepts our signatures

`core_interop_test.zig` verifies that **this implementation interoperates with a real Bitcoin Core (v31.1.0)**.

1. Sign, with this implementation, a PSBT created by Core's `createpsbt` + `utxoupdatepsbt`
2. Core's `finalizepsbt` returns `complete: true`, and its output hex **matches this
   implementation's final transaction byte for byte**
3. Core's `testmempoolaccept` returns `allowed: true`

Other tests look at "is this implemented as the specification says"; this test looks at
"**does Core consider our signature valid**". It cannot pass unless the implementation, the
encoding, the key search and the finalization all mesh. The PSBT used for verification and the
expected values are pinned in `tests/vectors/core_psbt.json` (see the explanation in that file for
the reproduction steps).

## Verified against a local EVM node (anvil)

For EVM the equivalent of the Bitcoin Core check is to make a **real node accept the signed
transactions**. This was done against `anvil` (Foundry's local EVM node, v1.8.5), which uses the
standard test mnemonic `test test test test test test test test test test test junk` at
`m/44'/60'/0'/0/` — exactly the derivation path this firmware uses.

```bash
anvil --port 8545 --chain-id 31337          # 10 funded accounts, base fee 1 gwei
cd firmware && zig build
SIGNED=$(printf '%s' '{"chainId":31337,"nonce":0,"gasPrice":2000000000,"gasLimit":21000,
  "to":"0x70997970C51812dc3A010C7d01b50e0d17dc79C8","value":1000000000000000000,"data":"0x"}' \
  | ./zig-out/bin/zhww evm-sign --mnemonic "test test test test test test test test test test test junk")
curl -s -X POST -H 'Content-Type: application/json' \
  --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_sendRawTransaction\",\"params\":[\"$SIGNED\"]}" \
  http://127.0.0.1:8545
```

| Check | Result |
|---|---|
| Our derived address vs anvil's account 0 | identical (`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`) |
| Legacy (EIP-155) transaction | accepted, mined, receipt `status: 0x1`, `type: 0x0`, gasUsed 21000 |
| EIP-1559 (type 2) transaction | accepted, mined, receipt `status: 0x1`, `type: 0x2`, gasUsed 21000 |
| Transaction carrying ERC-20 calldata | accepted, mined, receipt `status: 0x1`, gasUsed 22490 (calldata cost) |
| Receipt `from` / `to` | our account 0 / the intended recipient, as signed |
| Tampered signature (one nibble changed) | **rejected** by the node — the recovered sender is an unfunded address, so it cannot spend account 0's funds |
| Control: the same transaction with the correct signature | accepted |

Independently of the node, `eth-account` recovers the expected sender from all three signed
transactions (3/3).

This is a local, throwaway chain: it proves that the signature, the RLP encoding and the transaction
type are accepted by a real EVM implementation. It says nothing about fees or congestion on a public
network, and nothing has ever been broadcast to a public chain.

## The result must not change when the optimization mode changes

Integer-overflow and undefined-behaviour checks are enabled in Debug and ReleaseSafe and disabled in
ReleaseFast and ReleaseSmall. We check that **the result does not change with the mode**.

On macOS the flags come from pkg-config (`brew install secp256k1` already done).

```bash
cd firmware
for mode in Debug ReleaseSafe ReleaseFast ReleaseSmall; do
  echo "== $mode =="
  zig test tests.zig -O$mode $(pkg-config --cflags --libs libsecp256k1) -lc | tail -1
done
```

## Directory layout

```
firmware/tests/
├── README.md                 ← this file
├── vectors/
│   ├── bip39.json            24 official BIP39 vectors (entropy / mnemonic / seed / xprv)
│   ├── bip32.json            BIP32 test vector 1 derivation chain (seed / path / xprv / xpub)
│   ├── bip49.json            BIP49 P2SH-P2WPKH (testnet, uprv/upub, WIF, address)
│   ├── bip84.json            BIP84 P2WPKH (mainnet, zprv/zpub, WIF, public key, address)
│   ├── bip86.json            BIP86 P2TR (internal key, output key, address)
│   ├── bip143.json           BIP143 native P2WPKH (unsigned tx / sighash / DER signature / signed tx)
│   ├── bip174.json           BIP174 PSBT (20 invalid / 27 valid, Base64)
│   ├── core_psbt.json        a PSBT created by Bitcoin Core, and Core's finalization result (single-sig)
│   ├── core_multisig.json    2-of-3 multisig (a UTXO created by Core, and Core's finalization result)
│   └── core_taproot.json     Taproot key-path signing (a P2TR UTXO created by Core, and Core's finalization result)
├── bip39_vectors_test.zig
├── bip32_vectors_test.zig
├── address_vectors_test.zig
├── bip143_test.zig
├── bip174_test.zig
├── fuzz_test.zig             robustness against corrupted input (mutation tests)
├── sign_test.zig             integration tests for signing and finalization (paths with no external vectors)
│                             * the screen UI (font / framebuffer / screen) and PNG output tests
│                               live inside each module and are run through root.zig
├── core_interop_test.zig     interoperability with Bitcoin Core (Core accepts the signature)
├── multisig_test.zig         2-of-3 multisig (Core accepts the signature)
└── taproot_test.zig          Taproot key-path signing (Core accepts the signature)

EVM tests live inside the implementation files (`test` blocks in `src/apps/evm/*.zig`) and
verify the official RLP vectors, the official EIP-155 example, EIP-55 and EIP-191.
```

## Vector sources (no expected values of our own)

| File | Source |
|---|---|
| `bip39.json` | https://github.com/trezor/python-mnemonic (official vectors) |
| `bip32.json` | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki |
| `bip49.json` | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki |
| `bip84.json` | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki |
| `bip86.json` | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki |
| `bip143.json` | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki |
| `bip174.json` | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki |
| `core_psbt.json` | Bitcoin Core v31.1.0 (actually created on regtest; the output of `createpsbt` + `utxoupdatepsbt`) |
| `core_multisig.json` | Bitcoin Core v31.1.0 (regtest; a transaction created with `createpsbt` after sending to a `createmultisig` address) |
| `core_taproot.json` | Bitcoin Core v31.1.0 (regtest; a transaction created with `createpsbt` after sending to a BIP86 P2TR address) |

> **Note**: the seeds in `bip39.json` are derived with the passphrase **"TREZOR"**
> (they do not match with an empty passphrase).

## The strongest test: signatures match byte for byte

`bip143_test.zig` uses the BIP143 native P2WPKH vectors and verifies the following **all at once**.

1. Transaction parsing and serialization
2. Legacy sighash (input 0 is P2PK)
3. BIP143 sighash (input 1 is P2WPKH)
4. ECDSA signing (RFC6979 deterministic nonce, low-s, DER encoding)
5. Reproducing the signed transaction (**exact byte-for-byte match**)

RFC6979 is deterministic, so the same key and the same message always produce the same signature.
A matching signature is therefore strong evidence that the whole implementation is correct.

## Bugs the tests actually detected (record)

A record of errors the tests actually detected in LLM-generated code.

| # | Bug detected | Description |
|---|---|---|
| 1 | **Entropy byte order reversed** | BIP39 entropy extraction was reversed. It did not show up in the official vectors where the same byte repeats, such as `7f7f7f...` |
| 2 | **Derivation from the wrong depth** | Passing `m/0'/1` to a non-master key descended one level too many. Fixed by constraining the API so that "absolute paths are only accepted on a master key" |
| 3 | **scriptCode one byte short** | The P2WPKH scriptCode was implemented wrongly as `19 76 a9 14 … 88` (25 bytes), and `88` was overwritten by `ac`. Detected as a BIP143 sighash mismatch |
| 4 | **No push opcode in the P2PK scriptSig** | A mistake on the test side. A P2PK scriptSig has to "push the signature", so `<push 72> || DER || 0x01` is correct. Detected as a one-byte mismatch in the signed transaction |
| 5 | **P2SH-P2WPKH not treated as a witness input** | A P2SH input with a `witness_utxo` was judged to be a "non-witness input", so it demanded a `non_witness_utxo` and could not be signed. Fixed so that an input is treated as a witness input when its redeemScript is P2WPKH |
| 6 | **Dangling pointer** | Finalization kept `witness[1] = &key.public_key` (the address of a loop-local variable). Detected because the signature was correct while only the public key became a different value. This is a **memory-safety bug**, the kind that would first be noticed in production if there were no integration tests |
| 7 | **`EcdsaSignature.data` is not `r‖s`** | It is libsecp256k1's internal representation (little-endian in this environment), not the big-endian `r‖s`. Noticed while implementing the EVM side; added `signRecoverable` to `core` and consolidated the extern declarations |
| 8 | **Fixed-size arrays were not hashed** | In EIP-712, **fixed-size arrays are hashed the same way as dynamic arrays**, as `keccak256(concatenation of the elements)` (`SomeType[5]` is the same as a struct with 5 members). Fixed after checking the relevant sentence in the specification. Identified by splitting it into sub-cases and comparing against the oracle |
| 9 | **Returning a slice into a by-value struct** | `slice(self: ParsedScript)` returned a slice into the by-value copy (inside the function frame), which became an invalid reference at the call site. This is a **memory-safety bug of the same class as #6**, detected because the second and later parse results became undefined values. Fixed by changing it to take `*const` |
| 10 | **A padding bug on the oracle side (segno 1.6.6)** (not a bug in this implementation) | In QR byte mode, when the position right after the terminator falls on a codeword boundary, it added padding the standard does not require and replaced the pad codeword `0xEC` with `0x00`. When cross-checked against an independent implementation (qrcodegen 1.8.0), **this implementation matches and only segno disagrees**. Reported upstream as the unfixed issue [heuer/segno#123](https://github.com/heuer/segno/issues/123). A concrete example that **an oracle is not always right** |
| 11 | **A pointer to the RNG was stored in a struct and returned** (a bug on the test side) | `std.Random` holds a pointer to the RNG. `Fuzz.init` **returned by value** a struct holding "the RNG plus its `Random`", so the pointee (a local inside the function) died and the caller had a **dangling** reference. Detected by the mutation tests as a TRAP. **The same class as #6 / #9** (holding a reference to a temporary value), for the third time. Changed so that the `Random` is created each time it is used |

**About oracles**: cross-checking against an independent implementation is powerful, but as in #10 the **reference side can be wrong**. Compare against several implementations (qrcodegen / python-qrcode / segno), not just one, and also check against the standard's accompanying material (the example in ISO/IEC 18004 Annex I.2).

**About memory safety**: #6 and #9 are both bugs that "hold a reference to a temporary value".
Zig passes by value by default, so be rigorous about two rules: **a function that returns a slice pointing inside a struct must take `*const`**, and **never put the address of a loop-local variable into a longer-lived structure**.

**Lessons**:
- "The official vectors passed" is not enough on its own. Vectors with repeated identical values hide ordering bugs.
- The strongest tests compare the **final artifact byte for byte**, not partial matches (only the signature, only the sighash).
- When a test fails, do not assume "the implementation is wrong"; **question the test's assumptions too** (#4 was an error on the test side).
- For paths with no external vectors (P2PKH/P2SH finalization, fees, change detection), verify by **constructing self-consistent data**. #5 and #6 were in fact found this way.

## Required tests (to be added)

| Category | Content | Pass condition |
|---|---|---|
| PSBT signing | Signing from witness_utxo / non_witness_utxo | Signature verification passes in Bitcoin Core |
| Change detection | Deciding whether an output belongs to our own key | Correctly rejects the misjudgement cases |
| EVM signing | Legacy / EIP-1559 | **Byte-for-byte match** with viem / ethers.js signatures |
| EIP-712 | `domainSeparator` / `hashStruct` | Matches known samples. Warns on an unknown `verifyingContract` |
| Clear signing | Applying ERC-7730 descriptors | Snapshot match for the expected display. A mismatched chainId is rejected |
| Error cases | Huge arrays, deep nesting, unknown selectors, missing UTXOs | All refuse to sign and show the reason on screen |
| Secrets left behind | SD / flash after power loss | No byte sequence of the mnemonic / seed / xprv is present |
| Reproducibility | Image builds | The same hash in two environments |

## Display regression tests

What matters for security is not "being able to decode correctly" but "**continuing to warn about what should be warned about**".
The approval screens are pinned as snapshots, and we verify that the red warning has not disappeared in the following cases.

- Unlimited `approve` (`2^256-1`)
- `setApprovalForAll`
- `permit` (EIP-2612)
- Unknown contract / unknown selector
- Empty `to` (contract creation)
- Excessive fee (BTC)
- Token with unknown `decimals`
