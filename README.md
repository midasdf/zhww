# zhww — Open Source Hardware Wallet (BTC + EVM)

> ## ⚠️ 実験的プロジェクト・開発中 — 実資金で使わないでください
>
> - **Status: 実験的／開発中（experimental, work in progress）。** 仕様・API・ファイル構成は予告なく変わります。
> - **第三者によるセキュリティ監査を受けていません。** ハードウェアウォレットとして動作するには未実装部分があります（**署名機能はまだありません**）。
> - **実資金を預けないでください。** 資産を失う可能性があります。
> - **開発に LLM（大規模言語モデル）をヘビーに使用しています。** 設計・コード・テスト・文書の大部分は LLM が生成し、人間がレビューしています。生成コードには誤りが含まれ得ます。
>
> 詳細は必ず **[DISCLAIMER.md](DISCLAIMER.md)** を読んでください。

**できるだけ簡単に組み立てられる、完全オープンソースのマルチチェーン・ハードウェアウォレット（を目指して開発中のもの）。**

- **初期スコープ**: Bitcoin + EVM (Ethereum / ERC-20 / 主要L2)
- **ハードウェア**: SeedSigner 互換の既成部品（**半田付け不要**、既製品を載せるだけ）
- **想定コスト**: 1台あたり ¥8,000〜12,000 程度
- **現状**: BIP39 / BIP32 / Base58 / Bech32・Bech32m / BTC アドレス生成まで実装。公式テストベクタ 51 件が成功

---

## このプロジェクトが解こうとしている問題

既存のオープンソース・ハードウェアウォレットは二極化している。

| 分類 | 例 | 問題 |
|---|---|---|
| 完全オープンだが Bitcoin 専用 | SeedSigner, Krux, Specter DIY | マルチチェーンで使えない |
| マルチチェーンだがハード/ファームが非公開 | Ledger 等 | 「完全オープンソース」にならない |
| マルチチェーンでファームはオープン | Trezor, BitBox02, Keystone | ハード設計が非公開、または自作できない |

本プロジェクトは **「既成部品で誰でも組める」×「マルチチェーン」×「完全オープンソース」** の交点を狙う。ハードは実績のある SeedSigner の部品構成を流用し、ソフトウェアを BTC + EVM 対応で自作する。

---

## 設計の3原則

1. **鍵はチェーンを知らない** — 鍵管理・乱数・署名プリミティブを `core` に閉じ込め、チェーン固有ロジックは `apps` に追い出す。新チェーン追加＝アプリ追加であり、コアの再監査を不要にする。
2. **画面に出たものだけを署名する（clear signing）** — チェーンごとのトランザクション解析と人間可読表示を必須とし、blind signing を許さない。BTC は PSBT、EVM は [ERC-7730](https://eips.ethereum.org/EIPS/eip-7730) 記述子を使う。
3. **秘密は電源と共に消える（stateless）** — seed は RAM 上にのみ存在し、フラッシュに永続化しない。電源を切れば消える。SD カードは起動後に抜く。

---

## なぜセキュアエレメント（SE）を積まないのか

「完全オープンソース」と「SE でチェーン署名」は現状の部品では両立しない。

| SE | 曲線 | 結論 |
|---|---|---|
| ATECC608A/B | NIST P-256 のみ | **secp256k1 の署名ができない**（BTC/ETH 用途では鍵保管・証明用） |
| OPTIGA Trust M V3 | NIST/Brainpool 系 | [Trezor Safe 3/5 が採用するが、SE 内に seed は入らず署名は MCU 側](https://trezor.io/learn/security-privacy/how-trezor-keeps-you-safe/secure-elements-in-trezor-safe-devices) |
| Java Card 系 | secp256k1 対応品あり | 画面を持たない設計になり UX が大きく劣化する |
| TROPIC01 | 監査可能 SE | [Trezor Safe 7 が採用](https://trezor.io/learn/security-privacy/how-trezor-keeps-you-safe/secure-elements-in-trezor-safe-devices)。現状個人入手はほぼ不可 |

したがって本プロジェクトは **SE なし・ステートレス** を採用し、物理攻撃に対する残存リスクを [docs/05-threat-model.md](docs/05-threat-model.md) に明記する。物理攻撃耐性は「マルチシグ」「パスフレーズ」「少額運用」「使用後は電源断」で補う。

---

## リポジトリ構成

```
zhww/
├── README.md                  ← 本ファイル
├── DISCLAIMER.md              ← 免責・開発体制・LLM 利用の開示（必読）
├── SECURITY.md                ← 脆弱性の報告方法
├── LICENSE                    ← GPL-3.0（ファームウェア）
├── LICENSE-HARDWARE           ← CERN-OHL-S-2.0（ハードウェア設計）
├── LICENSE-POLICY.md          ← ライセンス方針
├── THIRD-PARTY-NOTICES.md     ← 第三者ソフトウェア・テストベクタの出典
├── docs/
│   ├── 01-requirements.md     ← 要求仕様・スコープ・受け入れ基準
│   ├── 02-architecture.md     ← アーキテクチャ・鍵導出・署名フロー
│   ├── 03-hardware-bom.md     ← BOM・調達・組立・筐体
│   ├── 04-chain-support.md    ← BTC/EVM 実装マトリクス・仕様
│   ├── 05-threat-model.md     ← 脅威モデル・残存リスク
│   ├── 06-roadmap.md          ← マイルストーンと Done 定義
│   └── 07-zero2w-setup.md     ← 手元の Raspberry Pi Zero 2 W を使う手順（無線の無効化）
├── firmware/                  ← Zig 実装（BTC 署名一式 + 公式テストベクタ）
│   ├── build.zig
│   ├── tests.zig
│   ├── src/                   ← core（チェーン非依存）と apps（BTC / EVM）
│   └── tests/                 ← 公式テストベクタと統合テスト
└── hardware/                  ← KiCad 等（v0.1 は既成部品のため現状は方針のみ）
```

## 現在の進捗

| 項目 | 状態 |
|---|---|
| 設計ドキュメント | 作成済み（要求仕様・アーキテクチャ・BOM・チェーン対応・脅威モデル・ロードマップ・実機手順） |
| ファームウェア（Zig + libsecp256k1） | BIP39（ダイス entropy 含む）/ BIP32 / Base58 / Bech32・Bech32m / RIPEMD-160 / ECDSA（RFC6979）/ BTC アドレス生成 / トランザクション解析 / Legacy・BIP143 sighash / PSBT の解析・検証・書き出し / **PSBT からの署名と最終化（P2WPKH・P2PKH・P2SH-P2WPKH・P2PK）** / 手数料とお釣り判定 |
| テスト | **88 件すべて成功**（BIP39 24 件・BIP32・BIP49/84/86・**BIP143 の署名がバイト単位で一致**・BIP174 の PSBT 不正 20 件/妥当 27 件・3 種類の入力を持つ PSBT の署名と最終化） |
| 実機 | Raspberry Pi Zero 2 W のセットアップ手順を [docs/07](docs/07-zero2w-setup.md) に記載 |
| 次の作業 | EVM 署名、画面 UI、QR 送受信、開発用 CLI |

```bash
cd firmware && zig build test
```

---

## 読み始める順番

1. [要求仕様](docs/01-requirements.md) — 何を作り、何を作らないか
2. [ハードウェア BOM](docs/03-hardware-bom.md) — 何を買えばよいか
3. [実機セットアップ（Zero 2 W）](docs/07-zero2w-setup.md) — 手元の実機を使う手順と無線の無効化
4. [アーキテクチャ](docs/02-architecture.md) — どう組み立てるか
5. [チェーン対応表](docs/04-chain-support.md) — BTC/EVM で実装すべき仕様
6. [脅威モデル](docs/05-threat-model.md) — 何を守れて、何を守れないか
7. [ロードマップ](docs/06-roadmap.md) — どの順番で進めるか

---

## ライセンス

- ファームウェア: **GPL-3.0-or-later**（[LICENSE](LICENSE)）
- ハードウェア設計: **CERN-OHL-S-2.0**
- 筐体: **CC-BY-SA-4.0**
- ドキュメント: **CC-BY-4.0**

詳細は [LICENSE-POLICY.md](LICENSE-POLICY.md)。

---

## 開発体制と AI（LLM）利用について

**このプロジェクトは、LLM をヘビーに使って開発しています。**

| 役割 | 担当 |
|---|---|
| 設計方針の決定、要件の指示、受け入れ判断 | 人間 |
| 設計書・コード・テスト・ドキュメントの生成 | LLM（コーディングエージェント） |
| 検証（テスト実行・公式ベクタとの突合） | 自動テスト ＋ 人間の確認 |

具体的には、Zig による実装（`firmware/src/`）、テスト（`firmware/tests/`）、`docs/` の設計文書の
大部分は LLM が生成したものです。人間がレビューしていますが、**生成されたコードには誤りが
含まれ得ます**。実際に、テストによって LLM 生成コードのバグが 2 件検出されています
（BIP39 のバイト順の逆転、非マスター鍵からの誤階層派生）。

したがって本プロジェクトでは、**「テストが通った」ことを「安全」とは扱いません**。
未検証の領域は未検証のまま明示します。指摘・修正の Pull Request を歓迎します。

---

## 免責

本プロジェクトは**実験的な研究開発プロジェクト**であり、第三者監査を受けていない。
**実資金を預けないこと。** 設計・実装・運用のいずれの段階でも資産を失う可能性がある。
まずテストネット（Bitcoin Signet / Ethereum Sepolia）で全フローを検証すること。

全文は **[DISCLAIMER.md](DISCLAIMER.md)** を参照。
