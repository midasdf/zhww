# firmware/tests/ — テストと公式テストベクタ

- **最終更新**: 2026-10-12

```bash
cd firmware && zig build test
```

実装のユニットテスト（`src/` 内の `test` ブロック）と、公式テストベクタによる統合テスト
（本ディレクトリ）を `firmware/tests.zig` がまとめて実行する。

**現在: 51 件すべて成功。**

## ディレクトリ構成

```
firmware/tests/
├── README.md                 ← 本ファイル
├── vectors/
│   ├── bip39.json            BIP39 公式ベクタ 24 件（entropy / mnemonic / seed / xprv）
│   ├── bip32.json            BIP32 テストベクタ 1 の派生チェーン（seed / path / xprv / xpub）
│   ├── bip49.json            BIP49 P2SH-P2WPKH（testnet・uprv/upub・WIF・アドレス）
│   ├── bip84.json            BIP84 P2WPKH（mainnet・zprv/zpub・WIF・公開鍵・アドレス）
│   └── bip86.json            BIP86 P2TR（内部鍵・出力鍵・アドレス）
├── bip39_vectors_test.zig
├── bip32_vectors_test.zig
└── address_vectors_test.zig
```

## ベクタの出典（自前の期待値は使わない）

| ファイル | 出典 |
|---|---|
| `bip39.json` | https://github.com/trezor/python-mnemonic （公式ベクタ） |
| `bip32.json` | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki |
| `bip49.json` | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki |
| `bip84.json` | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki |
| `bip86.json` | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki |

> **注意**: `bip39.json` の seed はパスフレーズ **"TREZOR"** で導出された値である
> （空のパスフレーズでは一致しない）。

## テストが実際に検出したバグ（記録）

| 事象 | 内容 |
|---|---|
| バイト順の逆転 | BIP39 の entropy 抽出が逆順になっていた。`7f7f...` のような同一バイト列のベクタでは露見せず、非対称なエントロピーで往復させるテストを追加して検出した |
| 誤階層からの派生 | 非マスター鍵に `m/0'/1` を与えると 1 階層余分に潜る問題をテストが検出。API 側で「絶対パスはマスター鍵のみ」と制約して修正した |

**教訓**: 「公式ベクタが通った」だけでは不十分。同じ値が並ぶベクタは順序のバグを隠す。
境界条件（非対称な入力、階層、ブロック境界）を明示的にテストする。

## 必須テスト（今後の追加分）

| 分類 | 内容 | 合格条件 |
|---|---|---|
| PSBT | 解析・署名・お釣り判定 | Bitcoin Core で署名検証が通る。誤判定ケースで正しく拒否する |
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
