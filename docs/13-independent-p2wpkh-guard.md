# 13. Independent native-P2WPKH signing-plan guard

**Experimental host prototype, not a hardware security boundary or independent audit.**
The approved BTC workflow now has two independently implemented **wire parsing/message
construction** paths for its narrow native-P2WPKH/SIGHASH_ALL subset. This does not establish
project-wide I-3, I-2 key isolation, actual TrustZone configuration or fault-injection resistance.

## 1. Why another parser/calculator

Checking a PSBT byte hash or rebuilding presentation with the same parser does not catch a shared
parser/sighash mistake. If the application both displays and signs a transaction that accidentally
omits an output, both operations can agree with one another while disagreeing with the wire input.

`firmware/src/security/p2wpkh_guard.zig` is deliberately independent of the application layer:

- Its own bounds-checked reader, canonical CompactSize decoder and PSBT map scanner.
- Its own unsigned transaction scan, duplicate-outpoint check and amount aggregation.
- Streaming double-SHA256 over **original canonical wire outpoints, sequences and outputs**.
- Literal native-P2WPKH BIP143 scriptCode construction from the wire UTXO program, not a
  public-key-derived application helper.
- No dynamic allocation, private keys, library context, transaction serialization or retained raw
  slices in the returned plan.
- No imports of the primary PSBT/transaction/cursor/script/sighash/encoding implementations.
  Only `std` is imported. A Python CI dependency tripwire guards this import rule; it is not formal
  verification and does not prove independent behavior by itself.

Both paths still share standard SHA256, the same compiler, processor and trusted execution
context. The second implementation can contain its own bugs. This is software diversity, **not**
independent cryptographic implementations or resistance to an instruction skip/memory corruption.

## 2. Scope and conservative refusal

| Item | Independent guard policy |
|---|---|
| Input file | PSBTv0, at most 64 KiB, exactly the declared input/output maps, no trailing bytes |
| Inputs | 1–31, unsigned empty scriptSig, no duplicate outpoints |
| Funding | Exact native-P2WPKH `witness_utxo` CTxOut; amounts known and bounded |
| Excluded input data | `non_witness_utxo` (even redundant), finalized scriptSig/witness, other input types |
| Sighash | Absent/default ALL or explicit `0x00000001`; no NONE/SINGLE/ANYONECANPAY |
| Outputs | 1–62; every canonical value/script is included in hashOutputs |
| Map fields | At most 128 per map, canonical key/value lengths and no duplicate full keys |
| Input key metadata | If supplied, at most eight compressed BIP84 candidates, exact five-level path; no arbitrary-depth/legacy/EVM paths |
| Amounts | Values and totals bounded by 21 million BTC; outputs cannot exceed inputs |

The approved workflow also applies its primary display policy: standard address outputs and
at most 64 explicit review pages. The independent guard's output hashing does not itself render
addresses or prove a destination is supported by the display.

Irrelevant metadata/unknown fields are length-bounded, duplicate-checked and skipped, not fully
interpreted. Input derivation key/path shape has the stricter bound above; point validity and
xpub/partial-signature metadata remain primary-parser responsibilities. This is **not a second
complete BIP174 validator**. Unknown fields are
still preserved by the primary signed-PSBT serializer. A request the development CLI can sign
may be refused by the narrower approved workflow; refusal must not silently fall back to the CLI.

Host-supplied witness UTXO amounts are **not authenticated against the blockchain**. Agreeing
on their bytes/amounts does not establish that they describe real unspent outputs. Existing review
warnings remain. No independent previous-transaction/txid handling is claimed for this subset.

## 3. Approved workflow dataflow

1. Copy incoming bytes into bounded owned storage before parsing.
2. Build the primary review. Independently parse the frozen wire request and compute every
   BIP143 message plus counts/totals/fee. Refuse disagreement in numeric review fields.
3. Commit the ordered message plan/counts/totals with a domain-separated digest, alongside
   the existing exact request/page commitments. Store no caller-provided expected hashes.
4. Traverse every physical-page receipt and require the fresh release/hold/release approval
   sequence (events are still synthetic in host tests; a trusted HAL is required on the target).
5. Consume approval. Rebuild the primary presentation and independent plan from **owned
   bytes only**; compare both commitments and numeric fields before requesting entropy.
6. Acquire fresh context-blinding entropy and a randomized C-context lease; derive the owned
   master key. Primary `signPsbtWithPlan` reparses the same owned PSBT.
7. **Before any signature or input-key discovery, compute and compare every primary input
   message with the independent plan.** Refuse mismatched count, unsupported/finalized input,
   unknown amount or any mismatched message. A mismatch in a later input cannot be deferred
   until after earlier signatures are generated.
8. For each matched key, compute the actual key-derived message and compare it again directly
   before `secp256k1.sign`. Verify every resulting ECDSA signature.
9. Explicit key metadata mismatch never triggers broad fallback. Without metadata, search only
   BIP84 account 0, coin 0/1, branch 0/1, indices 0–20. Do not run change-discovery scans or infer
   hidden change. Require a signature for every input and the reviewed fee. Return output only after success;
   consume/wipe the session on every exit and destroy/erase the owned signing context.

The approved adapter uses `signPsbtWithPlan`, not the unchecked compatibility API. The plan
argument is a **trusted internal borrow**, not a transport/Non-secure signing API. Future NS calls
must supply only bounded requests, never hashes, seed material, page receipts or GPIO events.
Existing `sign`, `signPsbtBytes` and `signPsbtWithKeys` remain development interfaces; they do
not establish this guard. Zig visibility alone does not stop bypasses within the same process.

The guard independently validates counts and numeric totals. It does **not** independently
validate the displayed address strings, font/rendering, physical SPI transfer, every human-readable
warning or chain selection. Network choice is a Secure-selected review commitment, not a field
that can be authenticated from a PSBT. Display completeness and physical isolation still matter.

## 4. Tests and reproduction

```bash
cd firmware
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test -Doptimize=ReleaseFast --summary all
zig build test -Doptimize=ReleaseSmall --summary all
zig build pico --summary all
zig build memory --summary all
cd ..
python3 -m unittest discover -s tools/tests -v
```

`firmware/tests/p2wpkh_guard_test.zig` covers:

- Official BIP143 native-P2WPKH input-1 sighash exactly matches the published hash. Its
  low-level unsigned-transaction calculator can hash this input even though another input in
  that official vector is legacy; `Plan.fromPsbt` still requires every approved input to be P2WPKH.
- Pinned Core PSBT message agreement with the primary path and exact numeric totals.
- Refusal of every truncated prefix, trailing data, duplicate fields, noncanonical and maximum-
  sized CompactSize lengths, oversized files and excessive input/map-field counts.
- Refusal of alternate sighash, finalized stacks, missing/unsupported UTXOs and redundant
  non-witness data; the exact 128-field boundary is also checked.
- Wrong expected message/count is rejected before input-key discovery. A two-input test with
  valid first hash and corrupted second hash proves all-input preflight precedes the first key lookup.
- Bounded BIP84 metadata/candidate-count and discovery-cap checks; explicit fingerprint
  mismatch refuses without fallback, and guarded results never infer change.
- Deterministic 512-case transaction-byte mutation differential check: currently 468 are accepted
  by the guard and every accepted case matches primary messages. Other mutations are refused,
  not signed. This is a regression corpus, not an exhaustive parser/sighash proof.

The approved-workflow tests additionally corrupt the stored plan commitment after approval:
`SigningPlanMismatch` is returned, no entropy is requested and the owned seed/input/plan digest
are wiped. Existing pinned final-transaction, single-use approval, RNG and workspace-failure tests
continue to run against the now-guarded real signer.

Guard state/temporary maps use stack, not workspace allocation. The [offline target link/frame
harness](14-target-link-and-fault-prototype.md) now measures individual frames (guard 6,032 bytes)
and real partial-image storage, but **does not establish a transitive stack bound**. The host fixed-workspace peaks remain 2,244 bytes for the small Core
request and 99,722 bytes for the padded 64 KiB request. See [12](12-rp2350-memory-budget.md).

## 5. Still required before release

- Separate Secure/NS images, constrained NS gateway, Secure memory/display/button ownership,
  DMA attribution and runtime-validated target stacks. Offline linking/fatal-stack compilation
  now exists but is not a bootable or attributed wallet image.
- Independent review of both implementations and adversarial target tests. Protect guard/plan
  state and rejection logic against fault injection using the actual RP2350 facilities, rather than
  assuming two software comparisons cannot both be bypassed.
- Independent representation/display checks, actual physical review/approval and complete key/
  C-stack/register/spill lifecycle analysis.
- Equivalent guarded paths for other BTC inputs/Taproot/multisig and EVM, without broadening
  this guard implicitly or treating development APIs as a production fallback.
- Actual linked memory budget, target TRNG/HAL, signed update/recovery/rollback and safe
  provisioning tests. Development interfaces remain reflashable; no OTP is programmed here.
