# 04. チェーン別実装仕様（BTC / EVM）

- **対象バージョン**: v0.1
- **最終更新**: 2026-10-12

---

## 1. 対応マトリクス

**状態**: ✅ 実装済み / 🔄 実装中 / ⬜ 未着手 / ❌ スコープ外

| 機能 | BTC | EVM | 優先度 |
|---|---|---|---|
| 単一署名 P2WPKH (BIP84) | ✅ 実装済み | — | 必須 |
| 単一署名 P2PKH / P2SH-P2WPKH | ✅ 実装済み | — | 中 |
| 単一署名 P2PK | ✅ 実装済み（署名と最終化） | — | — |
| マルチシグ P2WSH (P2SH なし) | ✅ 実装済み（2-of-3 / BIP67 のソートにも対応） | — | 高 |
| Taproot key-path (BIP86) | ✅ 実装済み（アドレス生成と鍵パス署名。スクリプトパスはスコープ外） | — | 中 |
| Taproot script-path | ❌ スコープ外 | — | — |
| PSBT（BIP174）の解析・検証・書き出し | ✅ 実装済み | — | 必須 |
| Legacy / EIP-1559 トランザクション | — | ✅ 実装済み | 必須 |
| ERC-20 transfer / approve | — | ✅ 実装済み（危険パターンの警告つき） | 必須 |
| EIP-191 personal_sign | — | ✅ 実装済み | 必須 |
| EIP-712 typed data v4 | — | ✅ 実装済み | 必須 |
| ERC-7730 clear signing | — | ✅ 実装済み（記述子の適用と警告） | 高 |
| QR 転送（BC-UR） | ✅ 実装済み（Bytewords / CBOR / 単一・マルチパート） | ✅ 同左 | 必須 |
| ed25519 系チェーン | ❌ v0.2 以降 | ❌ | — |

---

## 2. Bitcoin

### 2.1 アドレス生成

| 種別 | パス | エンコード | 備考 |
|---|---|---|---|
| P2PKH | `m/44'/0'/0'/0/i` | Base58Check | `1...` |
| P2SH-P2WPKH | `m/49'/0'/0'/0/i` | Base58Check | `3...` |
| P2WPKH | `m/84'/0'/0'/0/i` | Bech32 | `bc1q...` |
| P2TR | `m/86'/0'/0'/0/i` | Bech32m | `bc1p...` |
| P2WSH (multisig) | `m/48'/0'/0'/2'` | Bech32 | `bc1q...`（32 バイト） |

- **Bech32 と Bech32m の取り違えは致命的**。P2WPKH は Bech32（checksum 定数 1）、P2TR は Bech32m（0x2bc830a3）。実装時に定数を分離し、テストベクタで両方を検証する。
- ネットワーク（mainnet / testnet / signet / regtest）ごとに HRP とバージョンバイトが異なる。**テストネットでの検証を必須**とする。

### 2.2 PSBT（BIP174）

**受け入れ検証**

1. `PSBT_GLOBAL_UNSIGNED_TX` または PSBTv2 のフィールドを解析
2. 各入力に `witness_utxo` または `non_witness_utxo` が存在することを確認
   - **どちらも無い入力を含む PSBT は署名拒否する。** 入力額が不明なままでは手数料を表示できず、手数料詐取（fee attack）を検出できない
3. 各入力の `PSBT_IN_BIP32_DERIVATION`（または master fingerprint）が、本デバイスの seed から導出した鍵と一致することを確認
4. 出力を「送金」と「お釣り」に分類
   - お釣り判定は `m/84'/0'/0'/1/i` を実際に導出してスクリプト一致を確認する（ヒューリスティックに頼らない）

**署名**

- SegWit: BIP143 の sighash を実装。`SIGHASH_ALL` を基本とし、`ANYONECANPAY` は非対応（または強警告）
- Legacy: 従来の sighash（scriptCode は前出力の scriptPubKey）
- Taproot: `SIGHASH_DEFAULT` の key-path のみ。**script-path は実装しない**（誤実装のリスクが高い）

**署名前に必ず表示する項目**

| 項目 | 要件 |
|---|---|
| 送金先アドレス | 全出力を一覧。全文表示、中略禁止 |
| 金額 | BTC / sats の両建て表示 |
| 種別 | 送金 / お釣り を明示。お釣りは鍵一致で判定したもののみ |
| 手数料 | 絶対額（sats）＋ 手数料率（sat/vB）。入出力スクリプト長から算出 |
| 入力数 / 出力数 | 一覧の整合性確認用 |
| 署名対象ハッシュ | `core` が独立再計算した値（二重計算の原則） |

**警告を出す条件**

- 手数料が入力合計の 10% を超える、または 100,000 sats を超える
- 同一 PSBT 内に同一アドレスへの複数出力がある
- `non_witness_utxo` のみで与件された（サイズ過大・解析負荷の観点で警告）
- 出力数が 2 を超え、うち 1 つがお釣りでない（送金先の見落とし防止）

### 2.3 QR / ファイル

- **BC-UR**: `ur:crypto-psbt`（単一）、`ur:bytes`。大容量は animated QR（フレーム分割）で送受信
- **SeedQR**: 標準（12語: 25×25 / 24語: 29×29）、Compact SeedQR（12語: 21×21 / 24語: 25×25）
- **SD カード**: `.psbt` ファイルの読み書き。起動後は原則アンマウント

### 2.4 テストベクタ

| 対象 | 出典 |
|---|---|
| BIP39 チェックサム・mnemonic→seed | BIP39 仕様の公式ベクタ |
| BIP32 派生・xpub | BIP32 公式ベクタ |
| BIP84 zpub / アドレス | BIP84 公式ベクタ |
| PSBT 署名 | Bitcoin Core（regtest / signet）で作成・検証 |
| お釣り判定 | Core で作成した PSBT と突合 |

---

## 3. EVM

### 3.1 トランザクション種別

| 型 | 先頭バイト | 用途 | v0.1 |
|---|---|---|---|
| Legacy | なし | 旧式。`gasPrice` を使用 | ✅ |
| EIP-2930 (type 1) | `0x01` | access list 付き legacy | ⚪ 任意 |
| EIP-1559 (type 2) | `0x02` | 現行標準 | ✅ |
| EIP-4844 (type 3) | `0x03` | blob トランザクション | ❌ |
| EIP-7702 (type 4) | `0x04` | アカウント委任 | ❌ 将来 |

**署名対象ハッシュ**

```
legacy  : keccak256( RLP([nonce, gasPrice, gasLimit, to, value, data, chainId, 0, 0]) )
type 1/2: keccak256( type_byte || RLP([...フィールド..., 前の署名フィールドを除く]) )
```

型付きトランザクションでは **先頭の型バイトを必ず含める**。ここを落とすと署名が検証に通らない。

**署名値**

- `yParity` は型付きでは `0/1`、legacy の EIP-155 では `v = chainId * 2 + 35 + yParity`
- `s` は **low-s 正規化**（`s <= n/2`）必須
- nonce は `r || s || yParity` の決定論的 nonce（RFC6979）を用いる

### 3.2 RLP 実装上の注意

RLP は実装バグの温床。以下を必ずテストする。

- 単一バイト `0x00〜0x7f` はそのまま（プレフィクスなし）
- 先頭ゼロバイトの除去（`0x00` は空文字列、`0x0042` は `0x42`）
- 短い文字列 / 長い文字列（55 バイト境界）のプレフィクス切り替え
- 空リスト、空文字列（`to` が空 = コントラクト作成）
- 公式テストベクタとの完全一致

### 3.3 表示要件

| 項目 | 要件 |
|---|---|
| chainId | **必ず表示**。同じアドレスが複数チェーンに存在するため |
| 送金先 | `0x` + 40 hex を**全文表示**（中略禁止） |
| 金額 | ETH は 18 decimals。wei の生値も併記 |
| ガス | `maxFeePerGas` / `maxPriorityFeePerGas` と、`gasLimit × maxFeePerGas` の最大費用 |
| `to` が空 | 「コントラクト作成」として赤警告＋追加承認 |
| `data` が空 | 「単純送金」として表示 |
| 未知のコントラクト | 警告＋ raw calldata の Keccak-256 ハッシュ表示 |

**EIP-55 チェックサム**を計算して大文字小文字を混在表示し、ユーザーが目視で照合できるようにする。

### 3.4 ERC-20 と危険パターン

| セレクタ | 関数 | 表示 | 警告 |
|---|---|---|---|
| `0xa9059cbb` | `transfer(address,uint256)` | 送金先・トークン量 | — |
| `0x095ea7b3` | `approve(address,uint256)` | 承認先・承認量 | `2^256-1` は「無制限承認」として赤警告 |
| `0x23b872dd` | `transferFrom(...)` | 送金元・送金先・量 | — |
| `0xa22cb465` | `setApprovalForAll(address,bool)` | 全トークン承認 | 常に赤警告 |
| `0xd505accf` | `permit`（EIP-2612） | 承認先・量・期限 | **署名＝approve と同等**として扱う |
| `0x39509351` 等 | `increaseAllowance` | 承認量の増加 | 現行値が不明なら警告 |

**トークン量の表示**: `decimals` と `symbol` が不明な場合、**推測してはならない**。`decimals` 不明時は生の整数値＋「単位不明」警告を表示する。メタデータは ERC-7730 記述子、または署名済みトークンリストから取得し、その出所を画面に表示する。

### 3.5 EIP-191 / EIP-712

- **EIP-191（personal_sign）**: `"\x19Ethereum Signed Message:\n" + len(message) + message` に Keccak-256。メッセージ本文を全文表示する（長文はページ送り）。**メッセージに「署名を求めているだけ」と書かれていても内容は保証されない**旨を常時表示する。
- **EIP-712（typed data v4）**:
  - `domainSeparator` を再計算し、`verifyingContract`・`chainId`・`name`・`version` を表示
  - `hashStruct` を再帰的に計算（構造体・動的型・配列・`bytes`）し、人間可読なフィールド名で表示
  - **`verifyingContract` が未知なら赤警告**。フィッシングの主戦場はここ
  - 配列長や入れ子の深さに上限を設け、超過時は署名拒否（DoS・表示偽装の防止）

### 3.6 ERC-7730 による clear signing

[ERC-7730](https://eips.ethereum.org/EIPS/eip-7730) は、コントラクト関数やメッセージを人間可読フィールドに写像するメタデータ標準。記述子レジストリは [2026 年 5 月に Ethereum Foundation へ移管](https://developers.ledger.com/docs/clear-signing/overview)され、現在は [clearsigning.org](https://clearsigning.org) と [ethereum/clear-signing-erc7730-registry](https://github.com/ethereum/clear-signing-erc7730-registry) が正典。

**実装方針**

1. 記述子（JSON）は**署名済みリリースに同梱**する。実行時にネットワークから取得しない（エアギャップかつ改ざん防止のため）
2. 記述子の `chainId` とトランザクションの `chainId` が一致することを検証。不一致は拒否
3. `to` アドレスと関数セレクタが記述子のエントリと一致する場合のみ適用
4. 一致しない場合は**素の表示（警告付き）にフォールバック**し、絶対に推測表示しない
5. 記述子のハッシュとバージョンを画面に表示し、外部で照合可能にする

### 3.7 chainId の初期対応

| chainId | ネットワーク |
|---|---|
| 1 | Ethereum Mainnet |
| 10 | OP Mainnet |
| 137 | Polygon PoS |
| 324 | zkSync Era |
| 8453 | Base |
| 42161 | Arbitrum One |
| 59144 | Linea |
| 534352 | Scroll |
| 11155111 | Sepolia（テスト用・必須） |

### 3.8 テストベクタ

| 対象 | 方法 |
|---|---|
| RLP | 公式テストベクタ完全一致 |
| EIP-155 / 1559 署名 | EIP 記載例、および viem / ethers.js の署名とバイト一致 |
| ERC-20 デコード | 実トランザクション（Sepolia）から抽出した calldata でデコード検証 |
| EIP-712 | 既知サンプルで `domainSeparator` / `hashStruct` を突合 |
| ERC-7730 表示 | 記述子サンプルのスナップショットテスト |
| 異常系 | 長すぎる配列、深いネスト、chainId 不一致、未知セレクタ |

---

## 4. 実装順序（依存関係）

```
M1  BTC BIP84 単一署名（アドレス生成 → PSBT 署名 → QR 応答）
        │
        ├─► M1.5 BTC 手数料・お釣り判定・警告
        │
        ▼
M2  EVM Legacy/EIP-1559（RLP → 署名 → chainId 表示）
        │
        ├─► M2.5 ERC-20 transfer/approve + 危険パターン警告
        │
        └─► M2.6 EIP-191 / EIP-712
                     │
                     ▼
              M3  ERC-7730 clear signing（BTC マルチシグ・Taproot と並行可）
```

**BTC を先に実装する理由**: 署名対象と表示内容の一致（clear signing）の考え方を、仕様が枯れている PSBT で先に確立できる。EVM はこの構造を流用して実装する。
