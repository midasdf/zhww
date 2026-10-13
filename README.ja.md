# zhww — オープンソース・ハードウェアウォレット（BTC + EVM）

[English](README.md) | **日本語**

> ## ⚠️ 実験的プロジェクト・開発中 — 実資金で使わないでください
>
> - **Status: 実験的／開発中（experimental, work in progress）。** 仕様・API・ファイル構成は予告なく変わります。
> - **第三者によるセキュリティ監査を受けていません。** [2026-10-13 の内部コードレビュー](docs/10-security-audit-2026-10-13.md)は実施しましたが、実機のメインループと物理承認フローは未実装です。カメラと QR のコードも実機へ接続しておらず、対象ボードでは動作確認していません。
> - **実資金を預けないでください。** 資産を失う可能性があります。
> - **開発に LLM（大規模言語モデル）をヘビーに使用しています。** 設計・コード・テスト・文書の大部分は LLM が生成し、人間がレビューしています。生成コードには誤りが含まれ得ます。
>
> 詳細は必ず **[DISCLAIMER.md](DISCLAIMER.md)** を読んでください。

**できるだけ簡単に組み立てられる、完全オープンソースのマルチチェーン・ハードウェアウォレット（を目指して開発中のもの）。**

- **初期スコープ**: Bitcoin + EVM (Ethereum / ERC-20 / 主要L2)
- **ハードウェア**: SeedSigner 互換の既成部品（**半田付け不要**、既製品を載せるだけ）
- **想定コスト**: 1台あたり ¥8,000〜12,000 程度
- **現状**: PC 上では、承認付き native P2WPKH 署名と独立した BIP143 検証経路まで実装済み（テスト **449 件**）。物理承認、実機 HAL／TrustZone、端から端までのデバイスファームウェアは未実装で、対象ボードでは未実行

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
├── LICENSE                    ← MIT（ファームウェアとツール）
├── LICENSES/                  ← 使っているライセンスの全文（MIT、CERN-OHL-S-2.0、CC-BY-4.0、BSD-2-Clause）
├── REUSE.toml                 ← SPDX ヘッダを書けないファイルのライセンス
├── LICENSE-POLICY.md          ← ライセンス方針
├── TRADEMARKS.md              ← 「zhww」という名前の使い方
├── THIRD-PARTY-NOTICES.md     ← 第三者ソフトウェア・テストベクタの出典
├── docs/
│   ├── 01-requirements.md     ← 要求仕様・スコープ・受け入れ基準
│   ├── 02-architecture.md     ← アーキテクチャ・鍵導出・署名フロー
│   ├── 03-hardware-bom.md     ← BOM・調達・組立・筐体
│   ├── 04-chain-support.md    ← BTC/EVM 実装マトリクス・仕様
│   ├── 05-threat-model.md     ← 脅威モデル・残存リスク
│   ├── 06-roadmap.md          ← マイルストーンと Done 定義
│   ├── 07-zero2w-setup.md     ← Raspberry Pi Zero 2 W/WH の初期設定（無線の無効化）
│   ├── 08-rp2350-pizero.md    ← RP2350-PiZero への移植計画（v0.2 の本命）
│   └── 10-security-audit-2026-10-13.md ← 内部コードレビューと未解決事項
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
| 設計ドキュメント | 要求仕様・アーキテクチャ・BOM・チェーン対応・脅威モデル・ロードマップ・実機手順の草案あり。セキュリティ、メモリ、独立検証の設計とリリース条件は検証・更新中。 |
| ファームウェア（Zig + libsecp256k1） | **Bitcoin**: BIP39、BIP32、アドレス生成、トランザクションと PSBT の解析、Legacy・BIP143 の署名と最終化、手数料とお釣りの判定、BC-UR、画面描画、QR エンコード・デコード、FAT32。**Taproot と 2-of-3 P2WSH は単独モジュールと相互運用テストのみで、`signPsbtBytes` には未統合。** **EVM**: RLP、EIP-55、EIP-155・EIP-1559、EIP-191、EIP-712、ABI、ERC-7730 の各モジュール。実機の承認フローには未統合。 |
| セキュリティ基盤 | PC 上の承認付き native P2WPKH／SIGHASH_ALL フロー、所有する秘密情報と暗号コンテキストの消去、乱数・固定メモリの異常系、別パーサーによる BIP143 ハッシュ照合を実装。物理承認と実機の隔離は未実装。[設計](docs/11-rp2350-security.md)・[メモリ予算](docs/12-rp2350-memory-budget.md)・[独立検証の範囲](docs/13-independent-p2wpkh-guard.md)を参照。 |
| テスト | **449 件すべて成功**（通常のホストライブラリと、対象用32bit整数演算のC構成、それぞれ4つの最適化モード）。既存の署名・相互運用ベクタに加え、承認・消去・乱数／メモリ不足・独立検証・入力改変を検査。実機での動作や安全性の証明ではない。現在の詳細は[firmware](firmware/README.md)、過去の内部レビューは[報告書](docs/10-security-audit-2026-10-13.md)を参照。 |
| CI | Linux ホストでの回帰テスト、Pico 向けコンパイル、Cortex-M33 の暫定メモリ予算、検査ツールと依存関係のチェックを実行。microSD イメージの受け渡しも mtools／fsck.fat で検査する。RP2350 実機での実行ではない。 |
| 実機 | Linux 構成（**Pi Zero 2 WH**）は組立 [docs/03](docs/03-hardware-bom.md)・初期設定 [docs/07](docs/07-zero2w-setup.md)。**v0.2 の本命は無線なしの [RP2350-PiZero](docs/08-rp2350-pizero.md)**（Pi Zero 同寸・40pin 互換・microSD・**電池を積まない外部給電**・UF2） |
| ターゲット向け試作 | 固定バージョンのC暗号ライブラリで Secure／Non-secure 領域を実際にリンクし、関数単体のスタック使用量を取得。別スタックに切り替えて既知の領域を消去する異常終了経路もコンパイル・命令検査済み。ただし起動可能なファームウェア、実機の隔離、NS用ゲートウェイではない（[範囲と限界](docs/14-target-link-and-fault-prototype.md)）。 |
| 次の作業 | 実際の起動／SDK／CMSEとアクセス制限、呼出し先と割り込みを含むスタック上限、物理画面・ボタン・TRNG・SD の HAL。その後に P2TR／P2WSH／EVM の承認・検証フローと実機テストを進める。 |

```bash
cd firmware && zig build test      # 449 件
zig build pico                     # コンパイル確認。実機では未実行
zig build memory                   # 暫定の型サイズ・予約量。実機に収まることの証明ではない
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
8. [内部コードレビュー](docs/10-security-audit-2026-10-13.md) — 修正済みの問題と未解決のリリース阻害事項

---

## ライセンス

- ファームウェアとツール: **MIT**（[LICENSE](LICENSE)）
- ハードウェア設計（筐体を含む）: **CERN-OHL-S-2.0**（[LICENSES/CERN-OHL-S-2.0.txt](LICENSES/CERN-OHL-S-2.0.txt)）
- ドキュメント: **CC-BY-4.0**（[LICENSES/CC-BY-4.0.txt](LICENSES/CC-BY-4.0.txt)）
- 「zhww」という名前: 派生版は歓迎するが、別の名前で出してほしい（[TRADEMARKS.md](TRADEMARKS.md)）

すべてのファイルに SPDX ヘッダか [REUSE.toml](REUSE.toml) でライセンスを明記し、CI で検査している
（`git ls-files -z | zig run tools/license_check.zig`）。2026-10-14 まではファームウェアが
GPL-3.0-or-later、筐体が CC-BY-SA-4.0 だった。
第三者ソフトウェアとテストデータの出典は [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)、
方針の詳細は [LICENSE-POLICY.md](LICENSE-POLICY.md) を参照。

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
含まれ得ます**。テストとレビューでは、メモリ寿命、画面表示と署名内容の不一致、入力解析、
算術処理、ファイルシステム境界に関する不具合が複数見つかっています。2026-10-13 の
修正内容と未解決のリリース阻害事項は[レビュー報告](docs/10-security-audit-2026-10-13.md)にまとめました。
過去には、**参照実装（オラクル）側が間違っていた例**も 1 件ありました。

したがって本プロジェクトでは、**「テストが通った」ことを「安全」とは扱いません**。
未検証の領域は未検証のまま明示します。指摘・修正の Pull Request を歓迎します。

---

## 免責

本プロジェクトは**実験的な研究開発プロジェクト**であり、第三者監査を受けていない。
**実資金を預けないこと。** 設計・実装・運用のいずれの段階でも資産を失う可能性がある。
まずテストネット（Bitcoin Signet / Ethereum Sepolia）で全フローを検証すること。

全文は **[DISCLAIMER.md](DISCLAIMER.md)** を参照。
