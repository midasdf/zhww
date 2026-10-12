# セキュリティポリシー

---

## Summary (English)

This project is experimental and is not audited. Security reports are genuinely welcome — even
for a hobby project, a wallet bug matters.

- **How to report**: open a [GitHub security advisory](https://github.com/midasdf/zhww/security/advisories/new)
  (private) or an issue if the matter is not sensitive.
- **Please include**: what you found, how to reproduce it, and which commit you tested.
- **Response**: best effort. This is a volunteer, experimental project with no guaranteed SLA.
- **Most interesting classes**: signature or sighash mistakes, PSBT/FAT32 parsing that leads to
  signing the wrong thing, key material leaking into flash or logs, anything that makes the device
  display something different from what it signs.

The full policy below is in Japanese. Corrections and translations are welcome.

---

- **最終更新**: 2026-10-12
- **対象**: 本リポジトリのすべての成果物（ファームウェア・ドキュメント・ハードウェア構成）

---

## 1. このプロジェクトの位置づけ

**zhww は実験的な研究開発プロジェクトであり、第三者によるセキュリティ監査を受けていません。**
現時点でハードウェアウォレットとして完成しておらず、**実資金での使用を想定していません**。

詳細は [DISCLAIMER.md](DISCLAIMER.md) を参照してください。

## 2. 脆弱性の報告方法

セキュリティ上の問題を見つけた場合は、**公開 Issue ではなく**、以下のいずれかで非公開に連絡してください。

1. **GitHub Security Advisories**（推奨）
   - リポジトリの「Security」タブ →「Report a vulnerability」から報告する
   - 非公開で議論でき、修正後の開示も同じ場所で行える

2. それが使えない場合は、リポジトリの Issue で「非公開で連絡したい」旨を書き、
   連絡手段を相談してください（**脆弱性の内容そのものは公開 Issue に書かないこと**）

### 報告に含めてほしいこと

- 影響を受けるファイル・関数・コミット
- 再現手順（可能ならテストコードや入力データ）
- 想定される影響（鍵の漏洩、署名内容のすり替え、資金の喪失など）
- すでに公開しているかどうか

### 対応のめやす（ベストエフォート）

| 段階 | めやす |
|---|---|
| 受領の返信 | できるだけ早く（数日以内を目標） |
| 初期評価 | 2 週間以内 |
| 修正 | 内容と開発状況による |

**このプロジェクトはボランティアベースであり、対応を保証するものではありません。**
それでも、知らせていただけることが利用者の保護につながります。

## 3. 特に重要と考える脆弱性の種類

以下は優先的に扱います。

| 分類 | 例 |
|---|---|
| 鍵の漏洩 | seed・秘密鍵・パスフレーズがメモリやストレージに残る、外部に送出される |
| 署名内容のすり替え | 画面表示と実際の署名対象が食い違う（[docs/02-architecture.md](docs/02-architecture.md) の不変条件 I-3 の破れ） |
| 署名の偽造・検証漏れ | 生成した署名が検証を通らない、他者の署名を受理する |
| 手数料・送金先の偽装 | 表示されない出力への送金、手数料の水増し |
| PSBT の検証漏れ | 不正な PSBT を受理する（重複キー、キー長、マップ数の不一致など） |
| 乱数の欠陥 | 予測可能な seed が生成される |

## 4. 対象外

- 本プロジェクトが利用している外部ライブラリ（[libsecp256k1](https://github.com/bitcoin-core/secp256k1) 等）自体の脆弱性
  → それぞれのプロジェクトへ報告してください
- 設計上の既知の制約（[docs/05-threat-model.md](docs/05-threat-model.md) の「守れないもの」に列挙済み）
  → 例: 物理アクセス下での seed 保護、Raspberry Pi にセキュアブートが無いこと
- 「監査を受けていないこと」「LLM をヘビーに使っていること」自体
  → これらは [DISCLAIMER.md](DISCLAIMER.md) で開示済みです

## 5. 開示の方針

- 修正が用意できるまで、詳細の公開は控えていただけると助かります
- 修正後は、報告者の希望に応じて GitHub Security Advisories で公開します
- クレジットを希望する場合はお知らせください

## 6. 謝辞

セキュリティ上の指摘は、たとえ小さなものでもプロジェクトの価値を高めます。
報告いただいた方には、この場を借りて感謝します。
