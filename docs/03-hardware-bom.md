# 03. Hardware BOM and Assembly

- **Target version**: v0.1
- **Last updated**: 2026-10-12
- **Policy**: No soldering. Just seat off-the-shelf parts.

---

## 1. BOM (standard configuration)

| # | Part | Spec / model number | Approx. cost | Example source |
|---|---|---|---|---|
| 1 | SBC | **Raspberry Pi Zero 2 WH (header pre-installed)** | ¥3,500–4,400 | スイッチサイエンス (Switch Science), 千石電商 (Sengoku Denshi), Amazon |
| 2 | Display | **Adafruit Mini PiTFT 135×240** (product 4393, 1.14", ST7789, **two tactile buttons on the board**, **Qwiic/STEMMA QT port**, 38.6×24.5 mm, pre-assembled) | $9.95 | Adafruit (US) |
| 3 | Light receiver (**the input path**) | **LM393 light-sensor module with a photodiode/phototransistor and both an analog and a digital output** (the common 4-pin "LM393 light sensor" boards) | ¥300–600 | Akizuki Denshi, aitendo, Amazon.co.jp, Yahoo Shopping |
| — | Camera (**not bought** — the light receiver was chosen, see §2.5) | OV5647 5MP (**the version with the 22-pin FPC for Pi Zero**; Aokin / AuviPal, etc.) | ¥1,000–1,800 | Amazon |
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


### 2.5 Build recipes (pick one; "easy to assemble" comes first)

The project's first promise is that a person can put this together in minutes without soldering.
Three recipes keep that promise, in order of how little they add. They differ only in the display and
in how extensions are attached; the firmware supports all of them (the screen layout handles both
240x240 and 240x135).

| | R1: minimal (default) | R2: extensible | R3: all plug-in (Grove) |
|---|---|---|---|
| Display | **Waveshare 1.3" LCD HAT** (plugs straight on) | Adafruit Mini PiTFT #4393 | **M5Stack Unit LCD** (135x240, Grove cable) |
| Header | fully covered, **no extensions possible** | mostly free, **extensions possible** | all pins broken out as **female headers** |
| Extension route | — | **Grove module + a Grove-to-jumper cable** onto the free pins | **Grove sockets on the shield** (plug in, nothing else) |
| Assembly | plug the HAT on, insert the card: **~2 minutes** | plug the display on, one cable per sensor: **~3 minutes** | plug the shield on, two Grove cables: **~2 minutes** |
| Soldering / loose jumpers | none / none | none / one cable per module | **none / none** |
| Parts cost | $9.99 + $13.99 (~Y3,500) | ~Y3,500 + ~Y2,000 + modules | ~Y1,500 + ~Y3,500 + ~Y800 (~Y5,800) |
| Where to buy | Waveshare, Amazon | Adafruit (import) + Grove from domestic shops | **all from domestic shops** |
| Screen | 240x240 (native) | 240x135 | 240x135 (I2C) |
| Known catch | extensions are impossible later | the display has to be imported | I2C is slower for full-screen updates (fine for partial ones; unmeasured), and the shield's female headers mean **it cannot be stacked with a HAT** |

**R1 is the default.** It is the one that needs no decisions, no imports beyond the board itself, and
it is the only recipe whose exchange path (microSD) is already implemented and verified in CI.

**R2 is the middle ground** and is the one to choose if a sensor (a light receiver, extra buttons, a
rotary encoder) is wanted later: the Grove ecosystem supplies the module with keyed connectors, and
one Grove-to-jumper cable is all the wiring needed. Adafruit's STEMMA QT is the equivalent ecosystem
and Grove-to-STEMMA adapter cables exist.

**R3 is the "never touch a jumper wire" build.** Seeed's
[Grove Shield for Pi Pico](https://www.seeedstudio.com/Grove-Shield-for-Pi-Pico-v1-0-p-4846.html)
(available domestically at [Switch Science](https://www.switch-science.com/collections/seeed/products/7109))
breaks out 2x I2C, 2x UART, 3x digital, 3x analog and 1x SPI as Grove sockets, so a Grove display and
Grove buttons connect with cables only. It costs more and the display is I2C, which is the trade.

**For a phone as the host**, the simplest answer in every recipe is a **USB-C SD card reader** (Y800-
1,500): it reuses the microSD path that already works, and needs no sensor, no web page and no new
firmware. A light receiver or camera is an optional extra, documented in
[09-light-audio-input.md](09-light-audio-input.md), not part of the default build.

**Unconfirmed**: prices are approximate, the M5Stack Unit LCD's real I2C update rate has not been
measured, and whether the Grove shield's female headers can coexist with the chosen display has to be
checked on the real boards.

### 2.6 Camera (deferred — the light receiver was chosen instead)

The camera was the alternative **input** path. It is **not** being bought: it costs about $25 against
¥300–600 for the light receiver, and the light path reuses the same payload (UR strings) and the same
assembler. The research is kept here in case a camera becomes attractive later.

The camera would be the **input** path (reading a UR QR displayed by the host). On the RP2350 there is **no CSI**,
so the camera must be an **SPI module wired to the 40-pin header** — which the chosen small display makes
possible again (it covers only a third of the board; see [09-light-audio-input.md](09-light-audio-input.md) §9
for why the camera was preferred over a light sensor).

| Candidate | Interface | Resolution | Notes |
|---|---|---|---|
| **ArduCAM Mini 2MP Plus (OV2640)** — first choice | SPI (plus a few control pins) | 2 MP sensor, used at QVGA (320×240) | A finished module with a pin header, documented for use with the Pico/RP2040, ~$25. QVGA RGB565 is 153 KB, which fits the 520 KB SRAM; the frame is converted to grayscale before decoding. Listed by a Japan-facing shop ([RobotShop JP](https://jp.robotshop.com/products/arducam-mini-camera-module-w-2mp-plus-ov2640-arduino)) |
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
