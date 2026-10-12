# 第三者ソフトウェア・データの表示

- **最終更新**: 2026-10-12

本プロジェクト（zhww）が利用している第三者製のソフトウェアとデータの一覧です。
ライセンスの全文は各プロジェクトの配布物を参照してください。

---

## 1. 実行時依存（ファームウェア）

| 名称 | 用途 | ライセンス | 出典 |
|---|---|---|---|
| **libsecp256k1** | 楕円曲線演算（唯一の暗号プリミティブ） | MIT | https://github.com/bitcoin-core/secp256k1 |
| Zig 標準ライブラリ | SHA-256 / SHA-512 / HMAC / PBKDF2 / Keccak など | MIT | https://ziglang.org/ |

> RIPEMD-160 は Zig 標準ライブラリに存在しないため、**本プロジェクトが自前で実装**しています
> （`firmware/src/core/crypto/ripemd160.zig`）。実装は公式テストベクタで検証済みです。

## 2. 開発・テストで利用しているもの

| 名称 | 用途 | ライセンス |
|---|---|---|
| Zig コンパイラ | ビルド（0.17 以降） | MIT |
| **eth-account 0.13.7**（外部オラクル） | EVM 署名・EIP-712 の**期待値のクロスチェック**。リポジトリ外（`/tmp`）で実行し、依存には含めない | MIT |
| **Bitcoin Core v31.1.0**（外部オラクル・相互運用） | regtest で実際の PSBT を作り、`finalizepsbt` と `testmempoolaccept` で本実装の署名を検証する。**相互運用テストのベクタは Core の出力をそのまま固定**（`tests/vectors/core_psbt.json`） | MIT |
| **ethers.js 6.17.0**（外部オラクル） | EVM の calldata 生成（ABI エンコード）とセレクタのクロスチェック。リポジトリ外で実行し、依存には含めない | MIT |
| **ERC-7730 記述子レジストリ** | clear signing のテストデータ（Lido stETH / Ekubo / ERC-20 の記述子をそのまま埋め込み） | レジストリのライセンスに従う（出典: https://github.com/ethereum/clear-signing-erc7730-registry ） |

> オラクルは「実装とは独立した第三者の実装で期待値を計算し、バイト単位で一致するか確認する」
> ために使っています。**リポジトリの依存には含めません**（テストは埋め込んだ固定値で実行されます）。

## 3. テストデータ（公式テストベクタ）

テストは**第三者の公式ベクタ**を用いています。自前の期待値は使いません。
各ファイルの出典は以下のとおりです（`firmware/tests/vectors/`）。

| ファイル | 内容 | 出典 | ライセンス |
|---|---|---|---|
| `bip39.json` | BIP39 公式ベクタ 24 件 | https://github.com/trezor/python-mnemonic | MIT |
| `bip32.json` | BIP32 テストベクタ 1 | https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki | BIPs は CC0-1.0 |
| `bip49.json` | BIP49 P2SH-P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0049.mediawiki | 同上 |
| `bip84.json` | BIP84 P2WPKH | https://github.com/bitcoin/bips/blob/master/bip-0084.mediawiki | 同上 |
| `bip86.json` | BIP86 P2TR | https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki | 同上 |
| `bip143.json` | BIP143 Native P2WPKH（署名・署名済み tx） | https://github.com/bitcoin/bips/blob/master/bip-0143.mediawiki | 同上 |
| `bip174.json` | BIP174 PSBT（不正 20 件 / 妥当 27 件） | https://github.com/bitcoin/bips/blob/master/bip-0174.mediawiki | 同上 |

> BIP39 の英語単語リスト（`firmware/src/core/seed/english.txt`）も
> https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt から取得しています（CC0-1.0）。

## 4. 参考にした仕様・実装（コードの取り込みは無し）

以下は仕様の参照や設計の参考として挙げているもので、**コードを取り込んではいません**。

| 名称 | 参照している内容 | 備考 |
|---|---|---|
| [SeedSigner](https://github.com/SeedSigner/seedsigner) | 部品構成、ダイス entropy、エアギャップ運用 | ハードウェア構成の参考 |
| [Krux](https://github.com/selfcustody/krux) | 画面設計、エントロピー実測の考え方 | MIT |
| [Specter DIY](https://github.com/cryptoadvance/specter-diy) | セキュリティモデルの書き方 | ドキュメントの参考 |
| Trezor ファームウェア | マルチチェーンのアプリ分離構造（考え方のみ） | **コードを取り込んだ場合、本プロジェクトのファームは GPLv3 となり "Trezor" の名称は使えない** |
| [Ethereum Improvement Proposals](https://eips.ethereum.org/) | EIP-155 / EIP-1559 / EIP-191 / EIP-55 / ERC-7730 | 仕様の参照 |
| [BC-UR](https://github.com/BlockchainCommons/bc-ur) | QR 転送方式（未実装） | 導入時はライセンス表示を追加する |

## 5. ライセンス上の注意

- 本プロジェクトのファームウェアは **GPL-3.0-or-later** です（[LICENSE](LICENSE)）
- ハードウェア設計は **CERN-OHL-S-2.0**（[LICENSE-HARDWARE](LICENSE-HARDWARE)）
- ドキュメントは **CC-BY-4.0**、筐体は **CC-BY-SA-4.0**（[LICENSE-POLICY.md](LICENSE-POLICY.md)）
- 第三者のコードを取り込む場合は、**互換性のあるライセンスのみ**とし、この一覧を更新すること
