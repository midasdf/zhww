# 03. Hardware BOM and Assembly

- **Target version**: v0.1
- **Last updated**: 2026-10-13
- **Policy**: No soldering. Just seat off-the-shelf parts.

---

## 1. BOM (standard configuration)

| # | Part | Spec / model number | Approx. cost | Example source |
|---|---|---|---|---|
| 1 | SBC | **Waveshare RP2350-PiZero** - available domestically at [Switch Science 10733](https://www.switch-science.com/products/10733) (previously listed as Waveshare direct / Amazon) |
| 1b | SBC (v0.1 Linux build) | **Raspberry Pi Zero 2 WH (header pre-installed)** | ¥3,500–4,400 | スイッチサイエンス (Switch Science), 千石電商 (Sengoku Denshi), Amazon |
| 2 | Display | **Adafruit Mini PiTFT 135×240** (product 4393, 1.14", ST7789, **two tactile buttons on the board**, **Qwiic/STEMMA QT port**, 38.6×24.5 mm, pre-assembled) | ~¥2,500 | **Switch Science (domestic)**: https://www.switch-science.com/products/7422 |
| 3 | Light receiver (**the input path**) | **LM393 light-sensor module with a photodiode/phototransistor and both an analog and a digital output** (the common 4-pin "LM393 light sensor" boards) | ¥300–600 | Akizuki Denshi, aitendo, Amazon.co.jp, Yahoo Shopping |
| — | Camera (**not bought** — the light receiver was chosen, see §2.6) | OV5647 5MP (**the version with the 22-pin FPC for Pi Zero**; Aokin / AuviPal, etc.) | ¥1,000–1,800 | Amazon |
| 4 | microSD | 8–32GB (A1 or better; compatibility varies) | ¥800 | Consumer electronics retailer |
| 5 | Power | **Not onboard (external power)**. USB power cable + a power source you already own (PC / mobile battery pack / dry-cell box) | ¥0–3,000 | — |
| 6 | GPIO hammer header | 2×20 (pushes pins into place without soldering) | ¥800 | 秋月電子 (Akizuki Denshi), Amazon |
| 7 | Enclosure | 3D printed (**our own OpenSCAD**; see [hardware/enclosure](../hardware/enclosure/README.md). The SeedSigner case is a dimensional reference) | ¥0–1,500 | Self-made or a print service |
| 8 | microSD writer | USB card reader (on the PC side) | ¥800 | — |

**Estimated total: ¥8,000–13,000 (about USD 55–90); add roughly ¥3,000 if the enclosure is outsourced**

## 2. Selection rationale and caveats

### 2.1 Which SBC to choose (as of 2026-10)

**Conclusion: the standard configuration is the Raspberry Pi Zero 2 WH (header pre-installed).**

The first candidate was originally the wireless-free Pi Zero 1.3, but two obstacles appeared from the standpoint of actually building the device.

1. **The Pi Zero 1.3 is rarely in stock** (the model without wireless ships in small volumes and is hard to obtain reliably in Japan)
2. **The 40-pin pin header has to be attached** (a hammer header avoids soldering, but doubts remain about how reliable the press-fit is)

The Pi Zero 2 WH is a model whose **header is installed at the factory**, which solves both problems at once. It is available from authorized domestic distributors and mass-market retailers, and the Waveshare LCD HAT plugs straight in. The camera also connects with the 22-pin cable shared by the Zero family, so **neither soldering nor wiring is required** (the SeedSigner enclosure STL also assumes this configuration).

The price is that **the wireless chip physically exists**. In operation it is disabled in three ways — (a) remove the wireless drivers from the OS image, (b) disable it in the device tree, (c) verify with rfkill (procedure in [07-zero2w-setup.md](07-zero2w-setup.md)) — and the fact that it **exists as hardware** is stated explicitly as a residual risk in the threat model ([05-threat-model.md](05-threat-model.md)).

Only if you want to eliminate wireless physically as well should you consider the following, in order.

1. When a **Pi Zero 1.3** (no wireless) can be obtained
2. **Pi Zero 2 W + hammer header** (press-fit. No soldering, but the reliability is your own responsibility)
3. If you still want to avoid wireless, the alternatives below (at the cost of more porting work)

| | Pi Zero 2 WH (recommended) | Pi Zero 1.3 | Pi Zero 2 W |
|---|---|---|---|
| Header | **Pre-installed** | You install it | You install it |
| Wireless | Yes (procedure to disable it) | **None** | Yes (procedure to disable it) |
| Availability | Good (domestic distributors, retailers) | **Poor** | Good |
| Boot time | Short | Up to about 60 seconds | Short |
| Price | ¥3,500–4,400 | ¥2,500–3,500 | ¥3,000–3,800 |

### 2.2 Alternative candidates (options if the Zero 1.3 cannot be obtained)

With "no soldering" as an absolute requirement, the table below compares small boards that run Linux.
Note that **at present, the only boards on which this project's firmware (Zig + libsecp256k1 + Linux `std.Io`) runs as-is are the Raspberry Pi Zero family**.

| Candidate | Soldering | Wireless | Camera | Availability | Fit for this firmware |
|---|---|---|---|---|---|
| **Pi Zero 2 WH** | Not needed | Yes (can be disabled) | Pi camera (22-pin) | Good | **Runs as-is** |
| Pi Zero 2 W + hammer header | Not needed (press-fit) | Yes (can be disabled) | Same as above | Good | Runs as-is |
| Pi Zero 1.3 | Needed (can be avoided with press-fit) | None | Same as above | Poor | Runs as-is |
| Compatible boards such as the Banana Pi M2 Zero | Depends on SKU | Depends on model | Connector may be incompatible | Mostly personal imports | **Needs verification** (Linux images are unofficial / community-built) |
| **RP2350-PiZero + 1.3" LCD HAT** (main v0.2 target) | **Not needed** (40-pin header pre-installed) | **None** (the RP2350 has no wireless) | None (exchange via microSD) | Good (Switch Science, etc.) | **Port required** (core compilation already measured) → [08-rp2350-pizero.md](08-rp2350-pizero.md) |
| Pico 2 H + Pico-LCD-1.3 | **Not needed** ("H" models ship with the header installed) | **None** (the Pico 2 has no wireless) | SPI camera required (weakness described below) | Good (domestic distributors) | **Port required** (though core compilation has already been measured) |
| Luckfox Pico (RV1106) | Some SKUs ship without a header | None | Dedicated module (some SKUs include one) | Available in Akihabara and elsewhere | **Port required** (different SoC; LCD wiring also needed) |
| All-in-one units (Krux-family hardware such as M5Stack) | Not needed | Depends on model | Some models have one built in | Good | **Will not run** (not Linux, so the firmware would have to be a separate implementation) |

**About the enclosure**: the SeedSigner case has **the same screen and board dimensions**, but **the port cut-outs do not line up**
(on the RP2350-PiZero: mini HDMI + 2× USB-C on the front long edge, microSD on the left short edge, BAT on the right short edge, Φ3.00 mounting holes in the four corners, BOOT/RUN buttons, and no camera is fitted).
We therefore provide our own parametric OpenSCAD, and **have verified the external shape and structure by rendering**
(only the hole positions remain to be fixed by measuring the real hardware; [hardware/enclosure](../hardware/enclosure/README.md)).

![Enclosure preview](images/case-preview.png)

**All-in-one units (devices with the screen, buttons and camera built in from the start) are the strongest option from the standpoint of "widespread adoption"**, but
because they do not run Linux, this repository's Zig firmware will not run on them as-is
(current Zig has no official support for the ESP32-S3 and similar parts). Adopting one would mean
redesigning the firmware as a **separate line**; the existing implementation (PSBT, signing, UR transport)
could be reused as a library, but the HAL, display and camera would all have to be rewritten.
This decision is recorded in [06-roadmap.md](06-roadmap.md) as an open question for v0.2.

Sources (checked as of 2026-10):
- Domestic availability of the Raspberry Pi Zero 2 WH: [スイッチサイエンス (Switch Science)](https://www.switch-science.com/products/9812), [千石電商 (Sengoku Denshi)](https://www.sengoku.co.jp/mod/sgk_cart/detail.php?code=EEHD-6JRZ), [Amazon.co.jp](https://www.amazon.co.jp/dp/B0DB2JBD9C) ("header already soldered on")
- Example of an unofficial Linux image for the Banana Pi BPI-ZERO: [bananapi-zero-ubuntu-base-minimal (community-built)](https://github.com/avafinger/bananapi-zero-ubuntu-base-minimal)
- Domestic stock of the Luckfox Pico and an example of a "no header" SKU: [エルミタージュ秋葉原 (Hermitage Akihabara)](https://www.gdm.or.jp/crew/2024/0729/548831), [千石電商 (Sengoku Denshi; Luckfox Pico Ultra)](https://www.sengoku.co.jp/mod/sgk_cart/detail.php?code=EEHD-6ERY)

### 2.3 Findings for the Pico family (RP2040 / RP2350)

**Attractive points**: the Pico family best satisfies the conditions for "widespread adoption".

- **No soldering** — the Pico H / **Pico 2 H** come in versions with the header pre-installed ([スイッチサイエンス (Switch Science)](https://www.switch-science.com/products/10257))
- **A wireless-free model is standard** — the Pico 2 (non-W) has no Wi-Fi/BT. The residual risk that the Zero 2 WH carries — "the wireless chip exists" — disappears
- **Instant boot, low power consumption** — it is not Linux, so it boots in an instant. Battery life is good too
- **Inexpensive** — Pico 2 H (around ¥1,000) + [Waveshare Pico-LCD-1.3](https://www.waveshare.com/pico-lcd-1.3.htm) ($7.99, 240×240, SPI, with joystick/buttons)
- **Officially supported by Zig** — current Zig can target both Cortex-M0+ (RP2040) and Cortex-M33 (RP2350) (the ESP32-S3's Xtensa is not supported)

**Constraints**:

- **It is not Linux** — the HAL (LCD, buttons, SD, randomness) has to be rewritten. The logic (BIP39/32, PSBT, signing, EVM, UR) can be used as-is
- **The camera is the biggest weakness** — the RP2040/RP2350 has no CSI. There are examples of reading an SPI camera (ArduCAM, etc.) through PIO, but **QR decoding is heavy for a microcontroller**. The two realistic workarounds are (a) display-only QR, and (b) exchanging PSBTs over microSD

**Measured facts** (2026-10-12, run against this repository's code; reproduction steps below):

| What was checked | Result |
|---|---|
| Compilation of the core (BIP39/32, address generation, PSBT parsing, signing path, EVM parsing, UR) | **Succeeds for both the RP2040 (Cortex-M0+) and the RP2350 (Cortex-M33)** (about 64KB each, `-OReleaseSmall`) |
| Undefined symbols | Only `secp256k1_*` and compiler-rt (`__aeabi_*`). Zig supplies the latter |
| **Building libsecp256k1 0.6.0** | **Succeeds for both targets** (`zig cc`, using a minimal libc shim. A real port would use picolibc/newlib and remove the stdio dependency with `-DNDEBUG`) |
| Signing speed | **Not verified**. On an M0+ at 133MHz a single signature may take hundreds of ms; measurement is required |

```bash
# Check that the core compiles (from the repository root)
cd firmware
zig build pico     # checks both RP2040 and RP2350 together
# To do them individually:
zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m0plus -OReleaseSmall
zig build-obj pico_smoke.zig -target thumb-freestanding -mcpu=cortex_m33 -OReleaseSmall

# Check that libsecp256k1 builds (with minimal picolibc-equivalent headers in place)
zig cc -target thumb-freestanding -mcpu=cortex_m0plus -O2 -DHAVE_CONFIG_H -Icompat -I. -Isrc -c src/secp256k1.c
```

**Conclusion**: **v0.1 is completed on the Zero 2 WH (the current implementation runs as-is), and the main v0.2 candidate is the RP2350-PiZero** (§2.2, [08-rp2350-pizero.md](08-rp2350-pizero.md)).
Moving to an RP2350 board makes "rewriting the HAL + deciding how to handle camera/QR + measuring signing speed" the core of the work.

### 2.4 Display choice

| Option | Size | Pros | Cons |
|---|---|---|---|
| ~~A: Waveshare 1.3" LCD HAT~~ (rejected, see below) | 1.3" / 240×240 | Plugs directly into the Zero's 40-pin header. SeedSigner's track record and enclosure STL can be used as-is | Displaying EVM calldata requires paging. **It covers the whole board (65×30 mm), so every free GPIO is hidden** — no sensor or camera can be added (see [09-light-audio-input.md](09-light-audio-input.md) §7) |
| B: 2.4–3.5" SPI panel (ILI9341 / ST7789) | 2.4–3.5" | Addresses and amounts are easier to take in at a glance | Not a HAT form factor, so jumper wiring is needed and the enclosure STL must be custom |
| **C: Adafruit Mini PiTFT 135×240 (#4393) — CHOSEN** | 1.14" / **240×135** | Covers only 38.6×24.5 mm of the 65×30 mm board, so the rest of the 40-pin header stays reachable. Uses SPI plus a few control pins (~8-9), and brings **two tactile buttons** and a **Qwiic/STEMMA QT (I2C) port** for sensors. Pre-assembled, $9.95, ~15 FPS (fine for animated QR). Same ST7789 controller as before | **The resolution is 240×135, not 240×240**, so the screen layout has to be redesigned for half the height |
| D: same 1.3" 240×240 panel as a module + separate buttons | 1.3" / 240×240 | **The same panel and the same ST7789 driver**, so the screen design and the firmware's display layer are unchanged. A module with a 0.1" header is wired with jumpers (no soldering) and **leaves the rest of the 40-pin header reachable**, which is what a camera or light sensor needs. Cheaper than the HAT | The joystick is gone, so the UI simplifies to about three buttons; the enclosure must be redrawn around the module |
| E: connectorised display (Grove / STEMMA QT) | 0.96–1.14" | One cable, no soldering at all | Small (128×64 or 135×240) and I²C refresh rate is a question mark for animated QR output |
| F: 1.3" HAT + confirmation on the host side | — | Minimal implementation | Requires trusting the host, which violates principle 2 (not recommended) |

**C is the choice**: it is the only option that keeps enough of the 40-pin header reachable for a camera or a
light sensor while still being a single pre-assembled board that plugs in. Jumpers do the wiring, so no
soldering is needed. Option B (a bigger panel) remains the answer if the 135 px height proves too cramped
in use, and option D is the fallback if a square 240×240 screen becomes essential.

**Note on the chosen display (#4393)**:

The square 240×240 version of the same family (Adafruit 4484) would have needed no screen-layout
change at all, but it is hard to obtain in Japan, so **the 240×135 #4393 was chosen instead**. That
means the screen layout must be reworked for a 135 px tall panel (13 text lines at the 8x8 font,
against 26 before); the safety requirement that every error screen states in red that *no signature
was made* applies unchanged at the smaller size. The exact GPIOs the module uses for SPI, the two
buttons and the backlight have to be confirmed against Adafruit's guide when ordering.

**Note on option C form factors**: if a camera or a light sensor is wanted later, C is the cheapest way to make room for
it. The concrete parts seen while looking into this: the [Waveshare Pico LCD 1.3](https://www.waveshare.net/shop/Pico-LCD-1.3.htm)
module (240×240, SPI, the same panel as the HAT) and connectorised buttons such as
[Grove – Button](https://www.taiwaniot.com.tw/product/grove-button-%e6%8c%89%e9%88%95%e6%8e%a7%e5%88%b6%e5%99%a8%e6%94%af%e6%8f%b4arduino%e8%88%87%e6%a8%b9%e8%8e%93%e6%b4%be/) with
[Grove/STEMMA-to-jumper cables](https://media.distrelec.com/Web/Downloads/_t/ds/114992154_eng_tds.pdf).
Exact pinouts and stock have to be confirmed against the vendor's wiki when ordering; nothing here has
been bought or measured yet.


### 2.5 Build recipes

The standard build is **optical in both directions**: the host shows a flickering pattern that the
device's light receiver reads, and the device answers with a BC-UR QR code on its own screen. **No SD
card is involved at all** (§2.9), so nothing shared with a general-purpose computer ever touches the
device.

| | Standard build (this is the one) | SD-card variant (optional, not standard) |
|---|---|---|
| Display | **Adafruit Mini PiTFT #4393**, plugged onto the 40-pin header — **available domestically at [Switch Science](https://www.switch-science.com/products/7422)** | same |
| Input | **LM393 light-sensor module** (¥300-600): three wires to the free header pins (VCC, GND, AO) | microSD card |
| Output | QR code on the device screen (BC-UR, standard, readable by any UR-capable wallet) | file on the card |
| Assembly | plug the display on, connect three wires: **~3 minutes** | plug the display on, insert a card |
| Soldering | none | none |
| Parts | board $9.99 + display ~¥2,500 + sensor ¥300-600 | + a card and a card reader |
| Security shape | **air-gapped, optical both ways**; the host never touches the device | the card passes through the host, which is the untrusted party |

The SD-card variant remains implemented and verified in CI (`mtools` + `fsck.fat` in the handoff test),
because it is the cheapest path for a PC-only user and it exercises the filesystem layer. It is simply
not what the standard build uses.

**Grove** is the extension ecosystem: the display leaves most of the header free, so a Grove module
plugs in through one Grove-to-jumper cable. Seeed's Grove Shield for Pi Pico (domestic at
[Switch Science](https://www.switch-science.com/collections/seeed/products/7109)) breaks out
2x I2C, 2x UART, 3x digital, 3x analog and 1x SPI as Grove sockets, but its female headers mean it
**cannot be stacked with the display**, so it is an alternative to the small display rather than an
addition.

**Unconfirmed**: prices are approximate, and the light receiver's pin assignment is to be confirmed
against Adafruit's pin list for the display.

### 2.6 Camera (deferred — the light receiver was chosen instead)

The camera was the alternative **input** path. It is **not** being bought: it costs about $25 against
¥300–600 for the light receiver, and the light path reuses the same payload (UR strings) and the same
assembler. The research is kept here in case a camera becomes attractive later.

The camera would be the **input** path (reading a UR QR displayed by the host). On the RP2350 there is **no CSI**,
so the camera must be an **SPI module wired to the 40-pin header** — which the chosen small display makes
possible again (it covers only a third of the board; see [09-light-audio-input.md](09-light-audio-input.md) §9
for why the camera was preferred over a light sensor).

#### 2.6.1 Best candidate: a module that decodes the QR internally (found 2026-10-13)

A shop survey found modules that do the **capture *and* the decoding on board** and hand the MCU a short
string, which removes the entire image-processing objection to a camera.

| | |
|---|---|
| Product / shop | **M5Stack QR Code Scanner Unit (U173)** — [Switch Science product 9508](https://www.switch-science.com/products/9508) |
| Price / stock | **¥3,498, in stock** (Switch Science, checked 2026-10-13) |
| Interface | **I²C (address 0x21) or UART**, selected by an on-board toggle switch; Grove / HY2.0-4P (2.0 mm) connector |
| **What the MCU receives** | **The decoded QR text as a string** — no image crosses the wire. Vendor API: `get_qrcode_data()` returns the scanned data as a string, `get_qrcode_data_status()` reports ready/not-ready, `set_trigger_mode(0 = auto, 1 = manual)` ([UIFlow API docs](https://uiflow-micropython.readthedocs.io/en/2.4.1/units/qrcode.html)) |
| Sensor | 640 × 480 CMOS capture engine plus an STM32F030F4P6 bus MCU (the sensor part number is not given) |
| QR capability | **Vendor-documented**: PDF417, QR Code and Data Matrix, plus 8 one-dimensional codes; ≥5 mil, print contrast ≥20 %, scan angle ±55° |
| Solder-free | **Yes** — comes with a 20 cm HY2.0-4P cable; add the [Grove→Dupont conversion cable (M5Stack A096, ¥847)](https://www.switch-science.com/products/8305) to reach the Pico 2 H's factory-fitted header pins. No soldering |
| Size | 65.8 × 18.4 × 15.8 mm, 14 g — a hand-held scanner body with its own trigger button and buzzer |
| **Unverified** | Supply voltage range (Grove units normally run from 5 V, available as VBUS on the 40-pin header); its working distance; and whether it reads a **phone screen** as reliably as printed codes (the datasheet quotes printed-code specs only). Nothing has been bought or measured |

**Alternatives from the same survey** (prices as of 2026-10-13): the
[M5Stack QR Code Scanner Module 13.2 (M145, ¥3,784, in stock)](https://www.switch-science.com/products/10693)
also decodes internally over UART but is a Core2-shaped module with a 9–24 V DC jack; the
[M5Stack UnitV2 M12 (¥18,051)](https://www.switch-science.com/products/7536) decodes QR and emits JSON over
UART but is **out of stock**; [HuskyLens (¥10,824)](https://www.switch-science.com/products/6248) and
[HuskyLens 2 (¥19,547)](https://www.switch-science.com/products/10885) document face / object / line / colour /
AprilTag (and OCR, pose) recognition but **not QR**; the
[Grove Vision AI Module V2 (¥3,205, camera not included)](https://www.switch-science.com/products/9476) returns
model output (class + bounding box), not decoded text, and no QR model is documented for it; and the SPI cameras
([Arducam 5 MP Mini SPI ¥7,920](https://www.switch-science.com/products/11225),
[Arducam Mega 5 MP ¥6,490](https://www.switch-science.com/products/8943)) hand over **raw images**, leaving the
decoding to the RP2350 — the expensive path this candidate avoids.

| Candidate | Interface | Resolution | Notes |
|---|---|---|---|
| **Arducam 5MP Mini SPI camera module** — verified to exist at a domestic shop: [Switch Science product 11225](https://www.switch-science.com/products/11225). The manufacturer lists it for "Arduino UNO, Raspberry Pi Pico and other MCU", so it is SPI and Pico-documented, which is what this board needs. **Price and stock confirmed 2026-10-13: ¥7,920, in stock**; whether the header comes soldered is still unconfirmed | SPI | 5 MP sensor (OV5642), used at QVGA | It ships with jumper wires but returns **raw images** — no on-board decoding (see §2.6.1) |
| ArduCAM Mini 2MP Plus (OV2640) — earlier candidate, **no domestic listing confirmed** | SPI (plus a few control pins) | 2 MP sensor, used at QVGA (320×240) | A finished module with a pin header, documented for use with the Pico/RP2040, ~$25. QVGA RGB565 is 153 KB, which fits the 520 KB SRAM; the frame is converted to grayscale before decoding. Listed by a Japan-facing shop ([RobotShop JP](https://jp.robotshop.com/products/arducam-mini-camera-module-w-2mp-plus-ov2640-arduino)) |
| **Himax HM01B0 (monochrome)** — alternative | SPI | 320×320, **native grayscale** | Electrically the nicest fit: no colour conversion, low power, small frames. The bare sensor is a flex-connector part; a breakout is sold by [SparkFun](https://www.sparkfun.com/himax-cmos-imaging-camera-hm01b0-monochrome.html). Availability and whether the breakout has a solder-free header are unconfirmed |
| Raspberry Pi camera module (CSI) | CSI | — | **Not possible on the RP2350**: the board has no CSI connector. This applies to the v0.1 Pi Zero build only |

**Why the resolution is not a problem**: the decoder in `src/ui/qr_decode.zig` was verified down to
**1 pixel per module**, and a whole ~200-byte PSBT in a version-13 QR is 69 modules across. A QVGA camera
therefore reads a full PSBT in **one frame** (~4.6 px per module), which is much faster than the output
direction, where the device's 240×135 screen has to send 17 animated parts.

**Pin budget**: SPI1 (SCK/MISO/MOSI), one chip-select, plus power and ground — about five pins. The display
and its two buttons use roughly nine, so the 28 GPIOs are not a constraint.

**Unconfirmed**: exact pin assignments, whether each module ships with a header soldered (the no-soldering
rule), and Japanese stock. Nothing here has been bought or measured.

### 2.7 GPIO header

**The Pi Zero 2 WH comes with the header pre-installed, so this step itself is unnecessary** (just plug it in).
Only when using a Pi Zero 2 W / 1.3 does one of the following become necessary.

- **Hammer header** (press-in): no soldering. If the press-fit worries you, check continuity with a multimeter
- **Soldering**: reliable, but requires tools and skill (not recommended by this project)


### 2.8 Power options (dry cells / LiPo / USB)

**Adopted (decided 2026-10-12): no battery in the device; power is supplied externally over USB.**

| | **External power (adopted)** | Dry cells (carried in the device) | LiPo (board connector) |
|---|---|---|---|
| Device size | **Smallest** | Large (about 70×65×20mm with 4× AA cells) | Small (a thin cell fits behind the board) |
| Long-term storage (years to a decade) | **Best** (no battery, so nothing degrades) | Good (20 years with lithium AA cells) | **Poor** (degrades and swells in 2–3 years) |
| Charging / replacement | **Not needed** | Replacement only | Charging required |
| Leakage / fire | **None** | Beware of leakage (almost none with lithium) | Risk of fire and swelling |
| Usable on the spot | Needs a power source (PC / mobile battery pack / dry-cell box) | **Anywhere** | If charged |
| Remaining-charge indicator | **Not needed** (the problem itself disappears) | Cannot be measured (needs a voltage-divider resistor) | Can be measured |
| Part count / cost | **Smallest** | Medium | Medium |

**Why external power suits this use case**: a hardware wallet is used **only a few times a year**.
Carrying a battery in the device for that reason means it degrades, swells and leaks while sitting unused.
"Plug it in only when you use it" gives **higher long-term storage reliability**.

**Caveats**:

1. **Cutting power becomes "the normal way to switch off"** — the atomicity of signing (either it goes through
   to the end or nothing remains) becomes even more important. This is guaranteed by the microSD `OUT.TMP` → `OUT.PSBT`
   rename scheme (section 7b of [08](08-rp2350-pizero.md)) and by a design in which no valid signature remains
   even if power is lost before the signing result is written out
2. **USB power should be supplied without the data lines connected** — use a power-only cable, or a mobile
   battery pack / dry-cell box (which have no data lines). This preserves the air gap (section 4-8 of [05](05-threat-model.md))
3. It cannot be used where there is no power source (during a disaster, for example) → **carrying a dry-cell box solves this** (do not build it into the device)
4. The board's LiPo connector is **not used** (it is left available as an optional modification for people who want a smaller device)

## 2.9 SD-card exchange: not proposed any more (owner decision, 2026-10-13)

**Do not propose an SD-card exchange for this project again.** The owner ruled it out: a card is shared
physical media that passes through the untrusted host and then into the signing device. The code stays
in the tree because it is implemented and CI-verified, but it must not be suggested as the standard
build nor as an option. The exchange is **optical**: light in, QR out.

The rest of this section records the original reasoning, kept for context.


An SD card is shared physical media: it is written by the **host**, which this project treats as
untrusted, and then inserted into the signing device. That makes it the one component that carries
data — and potentially an exploit for the filesystem layer — from the untrusted side into the trusted
one. The firmware does defend itself (the FAT32 parser is fuzzed, the PSBT is validated and displayed
before anything is signed, and nothing is signed unless the screen shows it), but the cheapest defence
is to not have the interface at all.

So the standard build exchanges **optically in both directions**:

| Direction | Channel | Standard? |
|---|---|---|
| Host to device | **Light** (the host's screen flickers; the device's light receiver reads it) | Link layer is this project's own; the payload is a standard BC-UR string |
| Device to host | **QR code on the device screen** (BC-UR, animated parts) | Yes - BCR-2020-005, readable by any UR-capable wallet |

The consequence is honesty about cost: receiving a PSBT over light takes **tens of seconds** instead of
an instant, and the light link is not a standard anyone else has reviewed. In exchange, the device has
**no shared storage, no removable media and no cable data path** - only a light sensor and a screen.


### 2.10 Exactly what to buy for the light receiver (and the cable)

Search terms: **"LM393 光センサモジュール"** (Akizuki Denshi, aitendo, Amazon.co.jp, Yahoo
Shopping), or **"LM393 photosensitive diode module digital analog output"**. Category pages worth
starting from: [aitendo sensors](https://www.aitendo.com/product-list/211?num=50&img=200&sort=rank&page=2),
[Akizuki photodiodes](https://akizukidenshi.com/catalog/c/cphotodio_dL_spd_p2/). A 3-pack of "photosensitive
diode, digital/analog output" boards is typically **¥300-600 for three**, i.e. one spare set.

**What it must be** (all four matter):

| Must have | Why |
|---|---|
| A **photodiode or phototransistor** as the sensing element | Fast enough for a screen flickering at 30-120 Hz |
| **Both `AO` (analog) and `DO` (digital)** outputs, on a 4-pin board | `AO` goes to an ADC pin so the firmware thresholds in software; `DO` is the fallback |
| `3.3-5 V` supply (most of these boards take either) | The board runs at 3.3 V |
| A **soldered pin header** (or a screw terminal) | The no-soldering rule |

**What to avoid**: boards whose description says **"フォトレジスタ" / "光敏電阻" / "CdS" / "LDR"**. Those
respond in 10-100 ms - too slow at this data rate - and CdS cells are being phased out anyway. On the
board itself the difference is visible: a photodiode is a small **clear or black lens** can, a
photoresistor is a **bare serpentine squiggle** on a ceramic or plastic base.

**The cable**: the sensor's header is male and the board's 40-pin header is male, so the connection is
**female-to-female (F-F) jumper wires, 4 of them** (or a 4-way F-F ribbon of the same length).
Choose **10-20 cm**: the display sits on the header, so the wires have to come around it. Nothing else
is needed - no Grove or Qwiic adapter, because these boards have plain 0.1" pins. The **light guide is
printed as part of the case** (a collar and floor window that carry the light guide down through the underside (the 16 mm side bay has not existed since v0.4)), so there is
nothing extra to buy for it.

**Wiring** (3 wires are enough to start; `DO` is optional):

| Sensor pin | Board pin | Note |
|---|---|---|
| `VCC` | `3V3` | not 5 V |
| `GND` | `GND` | — |
| `AO` | **an ADC pin** (`GPIO26` or `GPIO27`) | the firmware samples this; the pin has to be confirmed against Adafruit's pin list for the display |
| `DO` | any free GPIO | optional hardware-threshold path |

**Qwiic works - with an I2C ADC.** An earlier note here said a Qwiic light sensor was impossible; that
was wrong, and the mistake was mine: it conflated the *sensor's integration time* with the *bus*. A
BH1750 lux sensor really is unusable (one measurement takes 16-180 ms, ~50x too slow, and the time
varies), but I2C itself is not the limit. Put an **I2C ADC** on the Qwiic port and the analog light
level arrives as a normal sample stream.

| Part | Status |
|---|---|
| **[Qwiic - ADS1015 12-bit ADC, 4 channel (Switch Science 5722)](https://www.switch-science.com/products/5722)** | **Verified to exist domestically.** 12-bit, and the ADS1015 converts at up to **3300 samples/s** in continuous mode - enough for 100 samples per symbol at 30 symbols/s with a 10% margin. (The 16-bit ADS1115 does only 860 samples/s, so pick the 1015.) Price and stock unconfirmed |
| **[Qwiic-Qwiic cable 50 mm (Switch Science 6896)](https://www.switch-science.com/products/6896)** | Verified product page. One cable from the display's Qwiic port to the ADC |
| A photodiode/phototransistor module with an analog output (LM393-type board) | **Still to be verified domestically.** Its `AO` goes to the ADC's A0 through three short wires; both boards live together in the sensor bay, so no wire runs to the 40-pin header at all |

**One Qwiic lux sensor is fast enough to skip the ADC entirely (checked 2026-10-13).** Of ten Switch
Science product pages surveyed, the
**[Qwiic - OPT4048 三刺激値カラーセンサモジュール (Switch Science 9281)](https://www.switch-science.com/products/9281)**
is the only plug-and-play Qwiic **ambient-light** sensor whose conversion time is short enough to sample a
screen flicker: **600 µs per channel, one of 12 selectable conversion times from 600 µs to 800 ms** (stated on
the product page; Adafruit's CircuitPython OPT4048 driver lists the same 12 values from datasheet page 29).
**¥2,739, in stock** on the store's own variant data. One Qwiic cable into the display's STEMMA QT port would
then be the whole light receiver — no ADC, no photodiode wiring.

Caveats, **all unverified** and to be measured on the bench before this displaces the ADS1015 path:

- the auto full-scale range (7 ranges, 2.2-144 klux) changes gain between conversions, so the range must be
  **pinned manually** for amplitude sampling; the driver exposes `Range.AUTO` plus the seven fixed ranges
- 600 µs is the shortest and therefore the least sensitive setting; signal-to-noise from a screen at close
  range, through the IR-cut/CIE filters, on the wideband channel is untested
- it is a colour sensor that also reports lux, not a plain photodiode: sample the **wideband (clear) channel**
- the display's STEMMA QT port must land on the I2C pins the firmware uses

Every other Qwiic ambient-light sensor on that list is **25 ms or slower** (fastest settings: VEML6030 and
VEML7700 25 ms, LTR-381RGB-01 25 ms, MAX44009 6.25 ms but manual-mode only / 100 ms in auto mode, VCNL4200 and
VCNL4030 50 ms, LTR-329 50 ms, VCNL4020 100 ms), which is the same order as the BH1750 already rejected above.

Why the timing is comfortable rather than marginal:

| Quantity | Value |
|---|---|
| ADC sample period | 0.3 ms at 3300 samples/s |
| Symbol period | 33 ms at 30 symbols/s |
| Jitter the receiver tolerates | about +-10% of a symbol = **+-3.3 ms** |
| I2C read jitter | tens of microseconds to a millisecond |

The receiver's own header already says a 12-bit ADC must be shifted down to 8 bits, so the ADS1015
feeds `light_rx` **unchanged** - the 371 tests still describe it exactly.

What this buys: **no wire to the 40-pin header at all**, so the question of how many pins the display's
socket covers stops mattering, and the sensor's power comes from the Qwiic port rather than a stolen
3V3 pin. The light path stays the first candidate.

Check the silkscreen for the pin order before connecting: the 4-pin boards come in both
`VCC GND DO AO` and mirror-image orders. Nothing here has been bought or measured in this session, and
no specific product page could be verified - the specification above is what matters.


**Cheaper listing of the same part (2026-10-13)**: [Adafruit OPT4048 module, Switch Science 10457](https://www.switch-science.com/products/10457),
**¥2,090, in stock** - the same OPT4048 chip as 9281 (¥2,739), so the 600 us conversion time, the four
X/Y/Z/W channels (the fourth is the wideband one to sample), the 0x44 I2C address and the two
STEMMA QT/Qwiic connectors are identical. Buy this one; the ¥650 difference buys nothing.

Two consequences to act on, both now decided (see §2.11):

- this board is **25.4 x 17.78 mm**, and the sensor goes **under the main board, looking down through the
  floor** - so the v0.3/v0.4 side bay is removed rather than enlarged, and the case grows in thickness
  instead of length;
- the sensor's aperture is **at the centre of the board** (12.70, 8.89 mm), not near an edge: Adafruit's
  published Eagle board file puts the OPT4048 package U1 exactly there and their top-down photo agrees.
  That number is still tagged as an estimate in the .scad, because the emitting spot inside the package
  is not published.

Useful extras this board brings: it has breakout pads for I2C, the address pin and an interrupt output
(so it can also be wired with jumpers if a Qwiic cable is ever impractical), and it carries a level
shifter so it works from both 3.3 V and 5 V rails.


### 2.11 The light sensor faces the bottom of the case (owner decision, 2026-10-13)

The sensor is mounted so it looks **down through the underside of the case**, not out of an end face.

Why this is better, not just different:

| | Sensor on the bottom | Sensor on an end face |
|---|---|---|
| To send | **Lay the device on the phone's screen.** It self-aligns, it is hands-free, and the phone itself **shields the sensor from room light** - which is the single biggest cause of dropped frames | You have to aim the edge at the screen by hand and hold it steady |
| Ambient light | Blocked by the phone | Room light leaks in from every side |
| The device's own screen | Faces up and **stays readable while the device sits on the phone** - useful, because the input screen shows progress | Must be tilted away to aim, so it is unreadable |
| Getting it wrong | Misalignment is obvious and stable | Misalignment is invisible and drifts |

Consequences for the case:

- The main board is raised on **taller standoffs** so the 25.4 x 17.78 mm sensor board fits **underneath** it;
  the aperture and the light guide pass **down through the floor**.
- The **16 mm side bay from v0.3 is removed**, so the footprint returns to the board's 65 x 30 mm and the
  case grows in thickness instead of length - better for holding against a phone.
- The Qwiic cable runs from the display, around the board edge, to the sensor underneath; 50 mm is enough.

The firmware is unaffected: the sensor is on I2C, so only its physical position changes. The light guide
still matters (it keeps the phone's own light from spilling in sideways), but the phone now does most of
the shielding.


### 2.12 A single board that replaces the whole stack (found 2026-10-13)

[Switch Science 10387](https://www.switch-science.com/products/10387), **Y4,059, in stock**: an
RP2350 **module with the screen and the camera already on it**.

| It has | Why it matters here |
|---|---|
| **RP2350A**, 520 KB SRAM, **16 MB flash** | The same chip family the firmware already targets |
| **2 inch 240 x 320 IPS, ST7789T3 over SPI** | Same controller as the display we already drive |
| **Capacitive touch, CST816D over I2C** | No buttons at all - but the UI design has to change |
| **OV5640 5 MP camera included**, 24-pin 0.5 mm FPC | **The camera input path becomes possible for free**, and its decoder is already written and verified (124/124 against independent encoders) |
| **microSD (SPI)**, 6-axis IMU, LiPo charge circuit | Not needed for the standard build, but they cost nothing |
| **2 x 12-bit ADC and 22 usable GPIO on installed headers** | The ADC pins are free here, so a light sensor can be added as well as the camera |
| **USB-C with drag-and-drop UF2 flashing** | No programmer needed |

Cost comparison for the current plan: board Y1,991 + display Y2,500 + OPT4048 Y2,090 + Qwiic cable
Y550 = **Y7,131** - this single board is **cheaper and does more**, including the camera.

What it costs us instead:

- **A new enclosure** - but a simpler one: one board plus a screen window, no HAT, no standoffs, no
  Qwiic routing.
- **A different screen shape** (240 x 320 portrait). The layout is already driven by a framebuffer size
  argument, so this is a new variant rather than a rewrite.
- **HAL work**: display pin mapping, touch input, and a camera driver. The signing core, the UI layer
  and the transport stack are unaffected.

So this is a genuine decision point: the assembly story gets *better* (one board, camera included, no
HAT covering anything), at the cost of the enclosure and HAL rework. Nothing has been bought; the
specifications above are from the product page.

## 3. Assembly procedure (solder-free; target 45 minutes; for the Pi Zero 2 WH)

1. **Fit the LCD HAT** — plug it into the 40-pin header (1 minute)
2. **Connect the camera** — lift the lock bar on the CSI connector, insert the FPC taking care with the contact-side orientation, and lock it (5 minutes)
3. **Write the OS image** — write the release image to the microSD card and verify the hash (15 minutes)
   (with the RP2350 configuration you just copy a UF2)
4. **Assemble the enclosure** — print the STL and secure the board (15 minutes)
5. **Check that it boots** — apply power and confirm that the logo and menu appear (5 minutes)
6. **Self-test** — check the screen, joystick, 3 buttons, camera and (optionally) QR reading

(If you use a Pi Zero 2 W / 1.3, add "press-fitting the hammer header (10 minutes)" at the start)

**Important**: always supply power through USB micro-B. Reversing the GPIO 5V pin and GND will damage the board.

## 4. Verification (after assembly, before use)

| Item | Method |
|---|---|
| Image authenticity | Verify the distributed hash and PGP signature on the PC before writing to the SD card |
| Screen / input | Check that every button and the joystick respond |
| Camera | Check that a test QR code (SeedQR) can be read |
| Absence of wireless | Confirm that no wireless interface exists in the OS (`ip link`, `rfkill`) |
| Air gap | Confirm that the signing flow completes even after removing the SD card following boot |

## 5. Maintenance and operation

- **Firmware updates**: via the SD card. Run the signature-verification sequence before updating.
- **Running from a battery pack is recommended**: because cutting power means wiping memory, running from a mobile battery pack naturally establishes the habit of "switch off when you are done".
- **Disposal / transfer**: the design leaves nothing from which the seed can be recovered, but do not reuse a used enclosure or SD card.

## 6. Additional requirements when selling (reference)

This BOM assumes **personal use**. Distributing or selling the device requires the following in addition.

- A configuration with wireless: giteki certification (technical conformity certification)
- If an AC adapter is included: PSE
- For Europe and North America: CE / FCC
- Export control of cryptographic functions (even with public source code, US EAR can impose notification requirements)
