# firmware/tests/ — テストと公式テストベクタ

- **最終更新**: 2026-10-12

```bash
cd firmware && zig build test
```

実装のユニットテスト（`src/` 内の `test` ブロック）と、公式テストベクタによる統合テスト
（本ディレクトリ）を `firmware/tests.zig` がまとめて実行する。

**現在: 71 件すべて成功。**

## ディレクトリ構成

```
firmware/tests/
├── README.md                 ← 本ファイル
├── vectors/
│   ├── bip39.json            BIP39 公式ベクタ 24 件（entropy / mnemonic / seed / xprv）
│   ├── bip32.json            BIP32 テストベクタ 1 の派生チェーン（seed / path / xprv / xpub）
│   ├── bip49.json            BIP49 P2SH-P2WPKH（testnet・uprv/upub・WIF・アドレス）
│   ├── bip84.json            BIP84 P2WPKH（mainnet・zprv/zpub・WIF・公開鍵・アドレス）
│   ├── bip86.json            BIP86 P2TR（内部鍵・出力鍵・アドレス）
│   ├── bip143.json           BIP143 Native P2WPKH（未署名 tx / sighash / DER 署名 / 署名済み tx）
│   └── bip174.json           BIP174 PSBT（不正 20 件 / 妥当 27 件・Base64）
├── bip39_vectors_test.zig
├── bip32_vectors_test.zig
├── address_vectors_test.zig
├── bip143_test.zig
└── bip174_test.zig
```

## ベクタの出典（自前の期待値は使わない）

| ファイル | 出典 |
|---|---|
| `bip39.json` | https://github.com/trezor/python-mnemonic （公式ベクタ） |
| `bip32.json` | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki |
| `bip49.json` | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki |
| `bip84.json` | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki |
| `bip86.json` | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki |
| `bip143.json` | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki |
| `bip174.json` | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki |

> **注意**: `bip39.json` の seed はパスフレーズ **"TREZOR"** で導出された値である
> （空のパスフレーズでは一致しない）。

## 最も強いテスト: 署名のバイト単位一致

`bip143_test.zig` は BIP143 の Native P2WPKH ベクタを使い、以下を **同時に** 検証する。

1. トランザクションの解析と直列化
2. Legacy sighash（input 0 は P2PK）
3. BIP143 sighash（input 1 は P2WPKH）
4. ECDSA 署名（RFC6979 の決定論的 nonce・low-s・DER 符号化）
5. 署名済みトランザクションの再現（**バイト単位で完全一致**）

RFC6979 は決定論的なので、同じ鍵と同じメッセージからは必ず同じ署名になる。
したがって「署名が一致する」ことは実装全体の正しさの強い証拠になる。

## テストが実際に検出したバグ（記録）

LLM が生成したコードに対して、テストが実際に誤りを検出した記録。

| # | 検出したバグ | 内容 |
|---|---|---|
| 1 | **エントロピーのバイト順の逆転** | BIP39 の entropy 抽出が逆順になっていた。`7f7f7f...` のような同一バイトが並ぶ公式ベクタでは露見しなかった |
| 2 | **誤階層からの派生** | 非マスター鍵に `m/0'/1` を与えると 1 階層余分に潜っていた。API 側で「絶対パスはマスター鍵のみ」と制約して修正 |
| 3 | **scriptCode が 1 バイト短い** | P2WPKH の scriptCode を `19 76 a9 14 … 88`（25 バイト）と誤って実装し、`88` が `ac` に上書きされていた。BIP143 の sighash 不一致として検出 |
| 4 | **P2PK の scriptSig に push opcode が無い** | テスト側の組み立てミス。P2PK の scriptSig は「署名を push する」必要があり、`<push 72> || DER || 0x01` が正しい。署名済みトランザクションの 1 バイト不一致として検出 |

**教訓**:
- 「公式ベクタが通った」だけでは不十分。同じ値が並ぶベクタは順序のバグを隠す。
- 部分的な一致（署名だけ、sighash だけ）ではなく、**最終成果物をバイト単位で比較する** テストが最も強い。
- テストが落ちたときは「実装が悪い」と決めつけず、**テスト側の前提も疑う**（#4 はテスト側の誤りだった）。

## 必須テスト（今後の追加分）

| 分類 | 内容 | 合格条件 |
|---|---|---|
| PSBT 署名 | witness_utxo / non_witness_utxo からの署名 | Bitcoin Core で署名検証が通る |
| お釣り判定 | 出力が自分の鍵に属するかの判定 | 誤判定ケースで正しく拒否する |
| EVM 署名 | Legacy / EIP-1559 | viem / ethers.js の署名と**バイト単位一致** |
| EIP-712 | `domainSeparator` / `hashStruct` | 既知サンプルとの一致。未知 `verifyingContract` で警告 |
| clear signing | ERC-7730 記述子の適用 | 期待表示のスナップショット一致。chainId 不一致は拒否 |
| 異常系 | 長大な配列・深いネスト・未知セレクタ・欠落 UTXO | すべて署名拒否し、理由を画面表示 |
| 秘密の残存 | 電源断後の SD / フラッシュ | mnemonic / seed / xprv のバイト列が存在しない |
| 再現性 | イメージビルド | 2 環境で同一ハッシュ |

## 表示の回帰テスト

セキュリティ上重要なのは「正しくデコードできること」より「**警告すべきものを警告し続けること**」。
承認画面のスナップショットを固定し、以下のケースで赤警告が消えていないことを検証する。

- 無制限 `approve`（`2^256-1`）
- `setApprovalForAll`
- `permit`（EIP-2612）
- 未知コントラクト・未知セレクタ
- `to` が空（コントラクト作成）
- 過大な手数料（BTC）
- `decimals` 不明のトークン
