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
| 4 | LiPo 電池（2pin コネクタ） | 充電回路は本体側 | ¥1,000〜 |
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

## 6. 変えずに済むもの

- `core/` と `apps/`（BIP39/BIP32・アドレス・PSBT・署名・EVM・ERC-7730・UR）は**そのまま**
- 公式テストベクタによる 203 件のテストはホストで実行を継続し、回帰を防ぐ
- 開発用 CLI もそのまま（ホストでの検証・ベクタ生成に使う）

## 7. 未解決の判断: QR の扱い

| 案 | 長所 | 短所 |
|---|---|---|
| **A. microSD で受け渡し、QR は表示のみ**（推奨） | 追加部品ゼロ。カメラ不要。確実 | スマホから直接読めない（PC 経由が必要） |
| B. SPI カメラを追加して QR を読む | スマホと直接やり取りできる | 部品追加、PIO での取り込み、QR デコードの実装（マイコンでは重い） |
| C. 両方（まず A、余力で B） | 現実的 | 実装量は増える |

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
