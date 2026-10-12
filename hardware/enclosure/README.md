# hardware/enclosure/ — 筐体

- **対象**: RP2350-PiZero（65 × 30mm）＋ Waveshare 1.3inch LCD HAT
- **形式**: [OpenSCAD](https://openscad.org/)（テキスト。差分管理と再生成ができる）
- **ライセンス**: **CC-BY-SA-4.0**（リポジトリの [LICENSE-ENCLOSURE](../../LICENSE-ENCLOSURE)）

## なぜ SeedSigner の STL をそのまま使わないのか

**寸法は合うが、ポートの穴が合わない。**

| | SeedSigner（Raspberry Pi Zero） | 本プロジェクト（RP2350-PiZero） |
|---|---|---|
| 基板寸法 | 65 × 30mm | **同じ**（65 × 30mm） |
| 画面 | Waveshare 1.3inch LCD HAT | **同じ HAT**（65 × 30.2mm） |
| 電源端子 | micro-USB | **USB Type-C**（位置も形も違う） |
| データ端子 | micro-USB | **USB Type-C**（PIO-USB） |
| 映像 | mini HDMI | mini HDMI（**位置は要確認**） |
| 記録媒体 | microSD（基板裏の縁） | microSD（**位置は要確認**） |
| ボタン | なし | **BOOT / RUN ボタンあり** |
| カメラ | Pi カメラ（QR 読み取り） | **積まない**（カメラ穴は不要） |

そのため、既存の STL を流用すると**穴の位置が合わない**。改造して配布する場合は、
配布元のライセンス条件を引き継ぐ必要もある（配布元によって MIT / CC / 不明とばらついている。
例: [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) は MIT で
Inventor（.ipt）の編集可能ソース付き）。

**そこで、SeedSigner のケースは「作り方の参考」にとどめ、自前のパラメトリックな OpenSCAD を用意した。**

- ライセンスを自分たちで決められる（CC-BY-SA-4.0）
- **寸法がパラメータ**なので、部品を変えたら再生成できる
- テキストなので差分管理・レビューができる（本リポジトリの他の部分と同じ流儀）

## 使い方

```bash
# OpenSCAD を入れる（macOS: brew install --cask openscad / Linux: apt install openscad）
openscad -o zhww-case.stl hardware/enclosure/zhww-case.scad          # STL を書き出す
openscad -o tray.stl -D 'part="tray"' hardware/enclosure/zhww-case.scad
openscad -o lid.stl  -D 'part="lid"'  hardware/enclosure/zhww-case.scad
```

## 実機が届いたら実測して埋めること

`zhww-case.scad` の中で **`// --- 実測して埋める ---`** の印を付けたパラメータは、
**公開情報から分からないため仮の値**になっている。実機で測って更新する。

| パラメータ | 何を測るか |
|---|---|
| `display_x` / `display_y` | HAT の基板端から LCD 表示領域までの距離 |
| `joystick_x` / `joystick_y` / `joystick_d` | ジョイスティックの中心位置と軸の直径 |
| `button1..3_x/y` / `button_d` | 3 ボタンの中心位置と直径 |
| `usb_c1_y` / `usb_c2_y` / `usb_c_w/h` | USB-C コネクタの位置・寸法 |
| `hdmi_y` / `hdmi_w/h` | mini HDMI の位置・寸法 |
| `sd_y` / `sd_w/h` | microSD スロットの位置・寸法 |
| `header_h` | 40pin ヘッダ＋ソケットを挿したときの高さ |

**注意**: この環境に OpenSCAD が無いため、**この .scad はまだレンダリングしていない**。
構文と寸法は実機で確認すること。

## 出典（参考にした公開情報）

- RP2350-PiZero の寸法 65 × 30mm: [Waveshare wiki](https://www.waveshare.com/wiki/RP2350-PiZero) / [CNX Software](https://www.cnx-software.com/2025/07/08/rp2350-pizero-rp2350-board-with-raspberry-pi-zero-form-factor-mini-hdmi-16mb-flash/)
- 1.3inch LCD HAT の寸法 65 × 30.2mm・表示領域 23.4 × 23.4mm: [Waveshare wiki](https://www.waveshare.com/wiki/1.3inch_LCD_HAT)
- 筐体の作り方の参考（SeedSigner のコミュニティ製ケース）: [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase)（MIT）ほか
