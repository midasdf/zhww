# 07. Raspberry Pi Zero 2 W のセットアップ（手元の実機を使う）

- **最終更新**: 2026-10-12
- **対象ハード**: Raspberry Pi Zero 2 WH（ヘッダ実装済み。標準構成）。手順は Zero 2 W でも同じ
- **対象**: 手元にある Raspberry Pi Zero 2 W を **開発機** として使い、同時に **無線を無効化** して
  エアギャップ運用に近づけるための手順

---

## 0. 結論（先に要点）

| 質問 | 答え |
|---|---|
| 手元の Zero 2 W をそのまま使えるか | **使える。ただし無線を潰すこと** |
| 最終構成も Zero 2 W でよいか | 可能だが、無線チップが物理的に存在するため**残存リスクとして文書化が必要**。最終構成は無線なしの Zero 1.3 が望ましい |
| なぜ Zero 2 W でも進めてよいか | 開発速度が圧倒的に違う（起動とビルドが速い）。ファームウェアは両者で同一バイナリ（同じ BCM2710A1 系、命令セットは同一） |
| 何から始めるか | ① OS を焼く → ② 無線を無効化 → ③ 無線が消えたことを確認 → ④ 画面とカメラを有効化 |

**原則**: 「無線ドライバを入れない」「無線を無効化する」「無線が無いことを起動時に確認する」の 3 段で運用する。
無効化していてもチップは基板上に存在するため、`docs/05-threat-model.md` の残存リスクに記載すること。

---

## 1. OS イメージの作成

1. [Raspberry Pi Imager](https://www.raspberrypi.com/software/) で **Raspberry Pi OS Lite (64-bit, Bookworm 以降)**
   を microSD に書き込む
2. Imager の詳細設定では **Wi-Fi を設定しない**（SSH も必要なときだけ有効にする）
3. 書き込み後、`/boot/firmware/config.txt` を編集して無線を無効化する

```
# ---- 無線の無効化 ----
dtoverlay=disable-wifi
dtoverlay=disable-bt

# ---- 画面（Waveshare 1.3inch LCD HAT: ST7789 240x240, SPI）----
dtparam=spi=on

# ---- カメラ（Bookworm 以降は libcamera スタック）----
camera_auto_detect=1
```

4. 起動後、サービスも止める（Bookworm）

```bash
sudo systemctl disable --now wpa_supplicant bluetooth hciuart 2>/dev/null || true
sudo systemctl mask wpa_supplicant bluetooth hciuart 2>/dev/null || true
sudo rfkill block all 2>/dev/null || true
```

---

## 2. 無線が消えたことの確認（必須）

**「設定したつもり」を防ぐため、必ず実機で確認する。**

```bash
# 1) 無線インタフェースが存在しないこと
ip link show | grep -E "wlan|wlp" && echo "NG: 無線が残っている" || echo "OK: 無線インタフェースなし"

# 2) rfkill で blocked になっていること
rfkill list

# 3) 無線ドライバが読み込まれていないこと
lsmod | grep -E "brcmfmac|bluetooth" && echo "NG: ドライバがロードされている" || echo "OK: ドライバなし"

# 4) Bluetooth サービスが動いていないこと
systemctl is-active bluetooth 2>/dev/null || echo "OK: bluetooth 停止"
```

**さらに徹底する場合（任意・非可逆）**: 基板上の無線モジュール周辺のアンテナパターンを物理的に切除する。
ただし基板を破損するリスクがあるため、まずは上記 4 点の確認で運用し、
「物理的に無線チップが載っている」事実を残存リスクとして明記する方を推奨する。

---

## 3. 開発の流れ

### 3.1 Mac 側（テストと実装）

```bash
cd firmware
zig build test          # 公式テストベクタを含む全テスト
```

Zig は **クロスコンパイル** が可能なので、aarch64 用のバイナリも Mac 上で作れる。
ただし libsecp256k1 はターゲット用のライブラリが必要なため、現実的には次のどちらか。

| 方法 | 長所 | 短所 |
|---|---|---|
| **Pi 上でネイティブビルド**（推奨） | 依存の解決が単純（`apt install libsecp256k1-dev`） | Zero 2 W でもビルドに時間がかかる |
| Mac からクロスコンパイル | 速い | aarch64 用 libsecp256k1 を別途ビルドして `linkSystemLibrary` に渡す必要がある |

### 3.2 Pi 側

```bash
# Zig（aarch64-linux）— 公式サイトの tarball を展開して PATH を通す
curl -fsSLO https://ziglang.org/download/0.17.0/zig-linux-aarch64-0.17.0.tar.xz
tar -xf zig-linux-aarch64-0.17.0.tar.xz
export PATH="$PWD/zig-linux-aarch64-0.17.0:$PATH"

# libsecp256k1（Debian/Ubuntu 系）
sudo apt update && sudo apt install -y libsecp256k1-dev pkg-config build-essential

# ビルドとテスト
cd firmware && zig build test
```

> `pkg-config` が見つからない場合は `PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig` を設定する。

---

## 4. 画面とカメラの確認

| 項目 | 確認方法 |
|---|---|
| SPI 有効化 | `ls /dev/spidev*` にデバイスがあること |
| LCD 表示 | テストパターンを描画し、240×240 で表示されること |
| ジョイスティック / 3 ボタン | GPIO 入力の変化を確認（Waveshare LCD HAT は GPIO に接続） |
| カメラ | `libcamera-still -o test.jpg` で撮影できること |
| カメラで QR 読取 | SeedQR（`docs/04-chain-support.md` §2.3）を読み取れること |

> LCD HAT の ST7789 用 device tree overlay は **未整備**。v0.1 の実装課題として
> `docs/06-roadmap.md` の M0 に含める（SeedSigner OS の overlay 実装が参考になる）。

---

## 5. 運用チェックリスト（実機を使う前に）

- [ ] `ip link` に無線インタフェースが無い
- [ ] `lsmod` に `brcmfmac` / `bluetooth` が無い
- [ ] microSD は起動後に抜く（署名フローが SD なしで完結すること）
- [ ] 使い終わったら電源を切る（RAM 上の seed を消す）
- [ ] テストネット（Signet / Sepolia）で一度フルに送金を試す
- [ ] 実資金は少額から。マルチシグ構成を基本にする
