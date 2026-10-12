# 08. RP2350-PiZero への移植計画

- **対象**: Waveshare RP2350-PiZero
- **最終更新**: 2026-10-12
- **位置づけ**: v0.2 の本命。ハードウェアを必要としない準備は [pico_smoke.zig](../firmware/pico_smoke.zig) と `zig build pico` で済ませてある

---

## 1. なぜこのボードか

Pi Zero 1.3 の在庫難とピンヘッダの半田付けを避けつつ、「無線なし」「半田付けなし」を両立できる。

**RP2350-PiZero の仕様**（出典: [Waveshare wiki](https://www.waveshare.com/wiki/RP2350-PiZero)、[CNX Software の紹介記事](https://www.cnx-software.com/2025/07/08/rp2350-pizero-rp2350-board-with-raspberry-pi-zero-form-factor-mini-hdmi-16mb-flash/)）:

| 項目 | 内容 |
|---|---|
| MCU | RP2350B（Cortex-M33 ×2 または RISC-V Hazard3 ×2、最大 150MHz、520KB SRAM） |
| フラッシュ | 16MB（PSRAM 用パッドあり） |
| 記録 | **microSD（TF）スロット** |
| GPIO | **40pin（Raspberry Pi 互換）**。28 GPIO、SPI ×2、I2C ×2、UART ×2、PWM ×16、PIO ×12 |
| 電源 | USB Type-C（給電・書き込み）＋ **LiPo 充電コネクタ** |
| その他 | USB Type-C（PIO-USB）、DVI 出力、BOOT/RUN ボタン、65×30mm（Pi Zero と同寸） |
| 価格 | $9.99（Waveshare 直販）。国内は[スイッチサイエンス](https://www.switch-science.com/products/10733)等 |
| 書き込み | UF2 をドラッグ&ドロップ（BOOT ボタン） |

**本プロジェクトとの相性**:

- **無線チップが無い** — エアギャップをソフトではなくハードウェアで達成できる（Zero 2 WH の残存リスクが消える）
- **Pi Zero と同寸・40pin 互換** — 既存の [Waveshare 1.3inch LCD HAT](https://www.waveshare.com/wiki/1.3inch_LCD_HAT)（BOM の標準ディスプレイ）を**そのまま差せる**。筐体はポート位置が異なるため新規 STL が必要
- **microSD を標準搭載** — カメラ無しでも PSBT を受け渡せる
- **LiPo 給電＋充電回路** — 携帯できる
- **UF2 書き込み** — 利用者の導入が「ファイルをコピーするだけ」で済む
- **Zig が公式対応**（Cortex-M33）— ESP32-S3 の Xtensa と違い、現行の Zig で書ける

## 2. 実測で確認できていること

| 確かめたこと | 結果 | 再現方法 |
|---|---|---|
| コア（BIP39/32・アドレス・PSBT・署名経路・EVM・UR）のコンパイル | **成功**（RP2040 / RP2350 の両方、各約 64KB） | `zig build pico` |
| libsecp256k1 0.6.0 のビルド | **成功**（`zig cc` + 最小 libc シム。実移植では picolibc を使い `-DNDEBUG` で stdio 依存を消す） | [03-hardware-bom.md](03-hardware-bom.md) の 2.3 節 |
| 署名速度 | **未検証**（実機が必要） | — |
| HAL（画面・SD・入力・乱数） | **未着手** | — |

## 3. ハード構成（案）

| # | 部品 | 備考 | 概算 |
|---|---|---|---|
| 1 | RP2350-PiZero | 本体。40pin 実装済み | $9.99（約 ¥1,600） |
| 2 | Waveshare 1.3inch LCD HAT（SKU 14972） | ST7789VW 240×240、ジョイスティック＋3 ボタン | $13.99 |
| 3 | microSD（8〜32GB） | 本体スロットに挿す | ¥800 |
| 4 | **乾電池式モバイルバッテリー（単3×4、USB 出力）**（**採用**） | 例: エレコム DE-KD06BK。USB-C 給電で使う（[03-hardware-bom.md](03-hardware-bom.md) の 2.7 節） | ¥2,000〜3,000 |
| 4b | 電池（リチウム単3 L91 等） | 長期保管向け。日常はアルカリでも可 | ¥500〜1,500 |
| 5 | 筐体 | 3D プリント。**ポート位置が Pi Zero と違うため新規 STL** | ¥0〜1,500 |
| 6 | USB-C ケーブル | 書き込み・給電 | ¥500 |

**合計目安: ¥6,000〜9,000**（カメラを付けない場合）

## 4. ピン配置（LCD HAT の公式表）

Waveshare の HAT は BCM 番号で次のピンを使う。40pin が Pi 互換である以上、同じ物理ピンに載る。

| 用途 | BCM | 用途 | BCM |
|---|---|---|---|
| KEY1 | 21 | Joystick UP | 6 |
| KEY2 | 20 | Joystick DOWN | 19 |
| KEY3 | 16 | Joystick LEFT | 5 |
| SCLK (SPI0) | 11 | Joystick RIGHT | 26 |
| MOSI (SPI0) | 10 | Joystick PRESS | 13 |
| CS (CE0) | 8 | DC | 25 |
| RST | 27 | BL（バックライト） | 24 |

**移植時に必ず確認すること**:

1. 「BCM 番号 = RP2350 の GPIO 番号」として扱えるか（基板の回路図・ピン配置図で確認する）
2. **microSD がどの GPIO に繋がっているか** — 基板の回路図は Waveshare が公開している（[RP2350-PiZero Schematic](https://files.waveshare.com/wiki/RP2350-PiZero/RP2350-PiZero.pdf)）。40pin とは独立の可能性が高い
3. DVI は使わない（無効のまま）

## 4b. 電源ポリシー（乾電池で確定）

乾電池を電源にすると、**「いつでも電源が落ちる」**前提で設計する必要がある。

| 項目 | 方針 |
|---|---|
| 電源スイッチ | 電池ボックスのスイッチを使う（本体に追加部品を付けない） |
| 待機 | RP2350 のスリープ（DORMANT 等）を使い、画面を消して待つ。**ボタン押下で復帰** |
| 残量表示 | **行わない**（5V レールを測るには分圧抵抗の追加＝半田付けが必要）。電池ボックス側の表示に頼る |
| 電源断 | **署名は「最後まで通すか、何も残さないか」のどちらか**にする。署名結果を書き出す前に電源が落ちても、中途半端な署名が有効にならないこと |
| 起動時の確認 | 起動直後に「前回の署名が完了していたか」を確認できるようにする（署名結果は電源断で消える設計なので、消えていれば何もなかったことになる） |
| 消費電流 | **実測が必要**。RP2350 は 150MHz で数十 mA、LCD バックライトも数十 mA。署名は数分なので実用上は問題ないが、連続動作時間は測ってから記載する |

**なぜ「何も残さない」で安全か**: 秘密（seed）はメモリ上にしか置かず、署名結果は書き出しが
完了したときだけ有効になる。電源断で消えるのは「まだ書き出していない中間状態」だけである。
この性質は [05-threat-model.md](05-threat-model.md) の stateless 設計と同じ考え方。

## 5. 移植するもの（HAL）

| 層 | 内容 | 難易度 |
|---|---|---|
| display | ST7789VW を SPI0 で駆動（240×240、RGB565）、バックライト制御、オフセット補正 | 低（既存の C 実装が多数） |
| input | ジョイスティック 5 方向＋KEY1〜3（GPIO 入力、プルアップ） | 低 |
| storage | microSD（FAT32）の読み書き。PSBT ファイルの入出力 | 中（FatFs 相当が必要） |
| entropy | RP2350 内蔵 TRNG | 低 |
| 署名 | libsecp256k1 をターゲット向けにビルドしてリンク | 中（ビルドは実測済み） |
| 起動 | BOOTSEL → UF2、ベクタテーブル、リンカスクリプト | 中 |
| UI | 画面（アドレス・金額・手数料・警告の表示、QR 描画） | 中〜高 |

### 実装済みの UI 層（ハードウェア非依存・2026-10-12）

実機が無くても UI を固められるよう、**画面の組み立ては PC 上で完結する形**にしてある。

| ファイル | 内容 | テスト |
|---|---|---|
| [src/ui/font.zig](../firmware/src/ui/font.zig) | 8×8 ビットマップフォント（パブリックドメイン、出典を明記） | 字形の検証 |
| [src/ui/framebuffer.zig](../firmware/src/ui/framebuffer.zig) | RGB565 の描画（点・矩形・文字・ドット列）。範囲外はクリップ | ピクセル単位で検証 |
| [src/ui/screen.zig](../firmware/src/ui/screen.zig) | 240×240 の画面レイアウト（タイトル・ラベル/値・警告・QR・フッター） | 領域ごとの描画を検証 |
| [src/ui/qr.zig](../firmware/src/ui/qr.zig) | QR エンコーダ（ISO/IEC 18004。表示専用、デコーダは含まない） | 独立実装（qrcodegen）と**全モジュール行列が一致** |
| [src/cli/png.zig](../firmware/src/cli/png.zig) | PNG 出力（無圧縮 zlib。外部ライブラリ不要） | 構造と CRC / Adler-32 を検証 |

**PC で画面を見る方法**（実機は不要）:

```bash
cd firmware && zig build
./zig-out/bin/zhww screen --demo --scale 2 > demo.png
cat psbt.txt | ./zig-out/bin/zhww screen --network regtest --scale 2 > confirm.png

# UR の 1 パートを QR として表示する（実機の「スマホに見せる」画面）
cat psbt.txt | ./zig-out/bin/zhww ur --fragment 40 | head -1 \
  | ./zig-out/bin/zhww screen --qr --scale 2 > qr.png
```

![UR の 1 パートを QR にした画面](images/screen-qr-ur.png)

*Bitcoin Core の PSBT を BC-UR のパートに変換し、その 1 つを QR にした画面（v7・45×45 モジュール・EC M）。
この PNG を独立した読み取り実装（OpenCV の QRCodeDetector）で復号すると、元の UR 文字列と
**完全に一致**することを確認済み。*

**QR エンコーダの検証**（重要）:
- 独立実装 **qrcodegen 1.8.0** と、同一入力・同一 EC・同一マスクで**全モジュール行列が一致**（強制マスクで 16/16、全 40 バージョン × 4 EC の網羅比較は実装時に 320/320）
- 自動マスク選択は **ISO/IEC 18004 Annex I.2 の作業例**（`"01234567"`・EC M → マスク 2）を再現する
- 生成した QR を **OpenCV で復号**して内容が一致することまで確認
- **注意**: オラクルとして使った segno 1.6.6 にはバイトモードのパディングのバグがある
  （[heuer/segno#123](https://github.com/heuer/segno/issues/123)、未修正）。本実装は規格どおりで、
  qrcodegen とは一致し segno とは一致しない。詳細は [../firmware/tests/README.md](../firmware/tests/README.md) の #10

実際に Bitcoin Core が作った PSBT から「送金先・金額・手数料」の確認画面が描けることを確認済み。

![Core の PSBT から描いた確認画面（240×240 を 2 倍で出力）](images/screen-confirm-psbt.png)

*Core の PSBT（送金先 bcrt1qf593…、99990000 sats、手数料 10000 sats。手数料は Core の
`decodepsbt` と一致）から描いた確認画面。*

![デモ画面](images/screen-confirm-demo.png)

*デモ画面。QR の位置には現在デモ用の市松模様が入っている（QR エンコーダ実装後に差し替える）。*

## 6. 変えずに済むもの

- `core/` と `apps/`（BIP39/BIP32・アドレス・PSBT・署名・EVM・ERC-7730・UR）は**そのまま**
- 公式テストベクタによる 203 件のテストはホストで実行を継続し、回帰を防ぐ
- 開発用 CLI もそのまま（ホストでの検証・ベクタ生成に使う）

## 7. 未解決の判断: QR の扱い

**採用: C（まず A を作り、余力で B を足す）** — 2026-10-12 決定

| 案 | 長所 | 短所 | 判定 |
|---|---|---|---|
| **A. microSD で受け渡し、QR は表示のみ** | 追加部品ゼロ。カメラ不要。確実 | スマホから直接読めない（PC 経由が必要） | **先に実装する** |
| B. SPI カメラを追加して QR を読む | スマホと直接やり取りできる | 部品追加、PIO での取り込み、QR デコードの実装（マイコンでは重い） | A の後、余力で |
| C. 両方（まず A、余力で B） | 現実的 | 実装量は増える | **採用** |

A を先に作る理由: 署名結果を QR で**表示**できれば、受け渡しは microSD でも成立する。
カメラは「入力の手間を減らす」部品であり、無くても署名フローは完結する。

### 画面に出す文字について

240×240 の画面に日本語を出すにはフォントを同梱する必要があり、容量と実装が増える。
当面は**画面上は英語（ASCII）**とし、日本語はドキュメントと CLI 側で扱う。
日本語フォント（必要な字形だけを絞ったビットマップ）は、UI が固まってから検討する。

## 8. 検証計画

1. **ホスト**: 既存の 203 テストを維持（回帰検出）
2. **ターゲット**: 同じベクタの一部を実機で実行するセルフテスト画面（起動時に「BIP39/BIP32/PSBT のベクタが通ったか」を表示）
3. **署名速度**: 実機で 1 署名あたりの時間を測る（実用判断の材料）
4. **実機**: signet で送金し、Core / エクスプローラで確認

## 9. 作業順序

| # | 作業 | 完了条件 |
|---|---|---|
| 1 | ボード入手 → UF2 で L チカ | 画面なしで動くことを確認 |
| 2 | ST7789 表示 | 文字と図形が出る |
| 3 | 入力（ジョイスティック・ボタン） | 押下が取れる |
| 4 | microSD 読み書き | PSBT ファイルを読める |
| 5 | libsecp256k1 リンク＋署名速度測定 | 実用範囲か判断できる |
| 6 | 画面 UI（署名前の確認表示） | 「表示できないものには署名しない」を満たす |
| 7 | signet で送金 | 実際に使える |

## 10. Pi Zero（Linux）案との関係

Linux 案（[03-hardware-bom.md](03-hardware-bom.md) の Pi Zero 2 WH）は**捨てない**。
理由は 2 つある。

- 移植が難航したときの退避先になる（現行ファームウェアがそのまま動く）
- ホストでのテスト・ベクタ生成・CLI として今後も使う（`core/` は共通）

つまり **「Linux で検証し、実機は RP2350 で動かす」** という二本立てが最終形になる。
