# 07. Raspberry Pi Zero 2 W setup (using the hardware you already have)

- **Last updated**: 2026-10-12
- **Target hardware**: Raspberry Pi Zero 2 WH (header pre-installed; the standard configuration). The procedure is the same for the Zero 2 W
- **Purpose**: procedure for using the Raspberry Pi Zero 2 W you already have as a **development machine** while at the same time **disabling wireless**, to get as close as possible to air-gapped operation

---

## 0. Conclusion (the short version)

| Question | Answer |
|---|---|
| Can I use the Zero 2 W I already have? | **Yes. But kill the wireless** |
| Is the Zero 2 W acceptable as the final configuration? | It is possible, but the wireless chip physically exists, so **it must be documented as a residual risk**. The wireless-free Zero 1.3 is preferable for the final configuration |
| Why is it acceptable to proceed with the Zero 2 W? | The development speed is dramatically better (boot and builds are fast). The firmware is the same binary on both (same BCM2710A1 family, same instruction set) |
| Where do I start? | (1) Flash the OS → (2) disable wireless → (3) confirm that wireless is gone → (4) enable the screen and camera |

**Principle**: operate in three stages — "do not install wireless drivers", "disable wireless", and "confirm at boot that there is no wireless".
Even when disabled, the chip still exists on the board, so this must be recorded in the residual risks of `docs/05-threat-model.md`.

---

## 1. Creating the OS image

1. Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/) to write **Raspberry Pi OS Lite (64-bit, Bookworm or later)** to a microSD card
2. In Imager's advanced settings, **do not configure Wi-Fi** (enable SSH only when you need it)
3. After writing, edit `/boot/firmware/config.txt` to disable wireless

```
# ---- Disabling wireless ----
dtoverlay=disable-wifi
dtoverlay=disable-bt

# ---- Screen (Waveshare 1.3inch LCD HAT: ST7789 240x240, SPI) ----
dtparam=spi=on

# ---- Camera (Bookworm and later use the libcamera stack) ----
camera_auto_detect=1
```

4. After boot, stop the services too (Bookworm)

```bash
sudo systemctl disable --now wpa_supplicant bluetooth hciuart 2>/dev/null || true
sudo systemctl mask wpa_supplicant bluetooth hciuart 2>/dev/null || true
sudo rfkill block all 2>/dev/null || true
```

---

## 2. Confirming that wireless is gone (mandatory)

**Always verify on the real device** so that "I thought I had disabled it" cannot happen.

```bash
# 1) No wireless interface exists
ip link show | grep -E "wlan|wlp" && echo "NG: wireless still present" || echo "OK: no wireless interface"

# 2) rfkill reports it as blocked
rfkill list

# 3) The wireless driver is not loaded
lsmod | grep -E "brcmfmac|bluetooth" && echo "NG: driver is loaded" || echo "OK: no driver"

# 4) The Bluetooth service is not running
systemctl is-active bluetooth 2>/dev/null || echo "OK: bluetooth stopped"
```

**To go further (optional, irreversible)**: physically cut away the antenna pattern around the wireless module on the board.
However, this risks damaging the board, so it is recommended to operate with the four checks above and to state explicitly, as a residual risk, the fact that "the wireless chip is physically present".

---

## 3. Development workflow

### 3.1 On the Mac (tests and implementation)

```bash
cd firmware
zig build test          # all tests, including the official test vectors
```

Zig can **cross-compile**, so aarch64 binaries can also be produced on the Mac.
However, libsecp256k1 needs a library built for the target, so in practice it is one of the following two.

| Method | Pros | Cons |
|---|---|---|
| **Native build on the Pi** (recommended) | Dependencies are simple to resolve (`apt install libsecp256k1-dev`) | Builds take a long time even on the Zero 2 W |
| Cross-compile from the Mac | Fast | An aarch64 libsecp256k1 must be built separately and passed to `linkSystemLibrary` |

### 3.2 On the Pi

```bash
# Zig (aarch64-linux) — unpack the tarball from the official site and add it to PATH
curl -fsSLO https://ziglang.org/download/0.17.0/zig-linux-aarch64-0.17.0.tar.xz
tar -xf zig-linux-aarch64-0.17.0.tar.xz
export PATH="$PWD/zig-linux-aarch64-0.17.0:$PATH"

# libsecp256k1 (Debian/Ubuntu family)
sudo apt update && sudo apt install -y libsecp256k1-dev pkg-config build-essential

# Build and test
cd firmware && zig build test
```

> If `pkg-config` cannot be found, set `PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig`.

---

## 4. Checking the screen and camera

| Item | How to check |
|---|---|
| SPI enabled | A device exists under `ls /dev/spidev*` |
| LCD display | Draw a test pattern and confirm that it appears at 240×240 |
| Joystick / 3 buttons | Confirm that GPIO inputs change (the Waveshare LCD HAT is connected to GPIO) |
| Camera | `libcamera-still -o test.jpg` can take a picture |
| QR reading with the camera | A SeedQR (`docs/04-chain-support.md` §2.3) can be read |

> The device tree overlay for the LCD HAT's ST7789 is **not yet prepared**. It is included in M0 of
> `docs/06-roadmap.md` as a v0.1 implementation task (the overlay implementation in SeedSigner OS is a useful reference).

---

## 5. Operational checklist (before using the device)

- [ ] There is no wireless interface in `ip link`
- [ ] There is no `brcmfmac` / `bluetooth` in `lsmod`
- [ ] Remove the microSD card after boot (the signing flow must complete without an SD card)
- [ ] Power off when finished (to erase the seed from RAM)
- [ ] Try a full send on a test network (Signet / Sepolia) once
- [ ] Start with small amounts of real funds. Make multisig the default configuration
