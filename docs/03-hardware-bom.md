# 03. Hardware BOM and Assembly

- **Target**: the standard build (parts decided by the owner, 2026-10-14)
- **Last updated**: 2026-10-14
- **Policy**: no soldering; off-the-shelf parts only; USB power; a clear printed case

---

## 1. BOM (the standard build)

| # | Part | Spec / model number | Approx. cost | Example source |
|---|---|---|---|---|
| 1 | Board | **Waveshare RP2350-PiZero** — RP2350B, 520 KB SRAM, 16 MB flash, **no wireless**, 40-pin header pre-installed, USB-C, 65 × 30 mm | ~¥2,000 | [Switch Science 10733](https://www.switch-science.com/products/10733) |
| 2 | Display | **Adafruit Mini PiTFT 135×240** (#4393) — 1.14" ST7789, **two tactile buttons**, a **STEMMA QT / Qwiic** port, 38.6 × 24.5 mm, plugs onto header pins 1–24 | ~¥2,500 | [Switch Science 7422](https://www.switch-science.com/products/7422) |
| 3 | Camera | **ArduCam UC-805** = Arducam **B0315** "HM01B0 Monochrome QVGA Camera Module for Raspberry Pi Pico" — Himax HM01B0, 320 × 320 monochrome, 60° fixed-focus lens, 1×8 right-angle header | ¥2,589 (Amazon.co.jp, 2026-10-14, low stock) / US$15.99 (UCTRONICS) | [Amazon.co.jp B093KBQB1C](https://www.amazon.co.jp/dp/B093KBQB1C), [UCTRONICS](https://www.uctronics.com/arducam-hm01b0-qvga-spi-camera-module-for-raspberry-pi-pico.html) |
| 4 | Camera power / I²C cable | **Adafruit STEMMA QT to female sockets, 150 mm** (#4397) | price unconfirmed | Adafruit and its distributors |
| 5 | Camera signal wires | **4 × female–female jumper wires, 10 cm**, plus ~4 cm of Φ2 mm heat-shrink (or polyimide tape) | ~¥300 | Any electronics shop |
| 6 | Enclosure | 3D printed in a **clear** material ([hardware/enclosure](../hardware/enclosure/README.md)), 7 × M2 × 16 flat-head screws | ¥0–2,000 | Self-printed or a print service |
| 7 | Power | **Not onboard.** A USB-C cable (power-only recommended) and a power source you already own | ¥0–3,000 | — |

**Estimated total: about ¥8,000–11,000** (about USD 55–75), plus the cable in #4 and printing if
outsourced. Nine parts before the case and the consumables (NFR-03: ten or fewer).

Check, when you buy the camera, that **its header is fitted**: the current stock ships with a 1×8
right-angle header on the odd row; some older listings show bare holes ("pin headers not included"),
which would need soldering.

## 2. Why these parts

### 2.1 Board: RP2350-PiZero

- **No radio on the board**, so there is nothing to disable and nothing to trust about it being off
- The **RP2350** has the security features the firmware design is built on (signed boot, TrustZone,
  OTP, glitch detectors; [11-rp2350-security.md](11-rp2350-security.md)), and Zig targets its
  Cortex-M33 directly
- **Pi Zero size, 40-pin header pre-installed**, flashed by copying a UF2 file — no soldering, no
  programmer
- The port plan, the flash layout and the power policy are in [08-rp2350-pizero.md](08-rp2350-pizero.md)

### 2.2 Display: Adafruit Mini PiTFT #4393

- It covers only **header pins 1–24**, so pins 25–40 stay free for the camera
- Two **tactile buttons** on the module (enough for "next / confirm"), and a **STEMMA QT port** that
  carries 3.3 V, ground and I²C to the camera without a wire to the header
- The firmware's screen layout is drawn for its 240 × 135 panel (`zhww screen` previews it); the
  square 240 × 240 version (#4484) is hard to get in Japan

### 2.3 Camera: ArduCam UC-805 (HM01B0)

- **Native grayscale**, 320 × 320 (used as 320 × 240): a frame is 76.8 KB, which fits the RP2350's
  SRAM with room to spare, and needs no colour conversion before the QR decoder
- **The decoder is ours** ([src/ui/qr_decode.zig](../firmware/src/ui/qr_decode.zig)), verified
  against two independent encoders and down to one pixel per module. The owner rejected modules
  that decode QR internally (2026-10-13): the input decides what gets signed, so it must not pass
  through a third-party decoder
- **Field of view** 60° diagonal: at 100 mm it sees about 78 × 59 mm, about 0.25 mm per pixel
  (estimated from the lens's 1.47 mm focal length and the 3.6 µm pixels), so a phone's 3 cm QR code
  is about 120 pixels across. Fixed focus; the near limit is estimated at 5–11 cm — **measure it**
- **3.3 V in**, its own 2.8 V regulator and 24 MHz oscillator, I²C at 0x24. Its video bus runs in
  one-bit mode on four GPIOs (§3)
- The camera **looks out of the back** of the case (SeedSigner style): you hold the device, aim it at
  the phone's screen and watch the progress on the display

### 2.4 How data gets in and out

| Direction | Channel |
|---|---|
| Host → device | **The device's camera reads a UR QR code** (animated if needed) on the phone's or PC's screen |
| Device → host | **The device shows a UR QR code** (BC-UR, animated parts) for the host's camera |

Nothing else connects to the host: no SD card, no data over USB. The owner ruled out exchanging data
on SD cards (2026-10-13): a card is shared physical media that passes through the untrusted host.
**Do not propose it again.** The FAT32 code was removed from the tree (2026-10-14).

### 2.5 Power: external, over USB (decided 2026-10-12)

No battery in the device. A hardware wallet is used a few times a year; a cell kept inside it
degrades, swells or leaks while it waits, and "plug it in to use it" has no state to forget.

- **Unplugging is the normal way to switch off**, so signing must be atomic: either it completes
  or no valid signature exists
- Use a **power-only** USB cable, or a power bank, so no data lines connect the device to a computer
  ([05-threat-model.md](05-threat-model.md) §4-8)
- The board's LiPo connector is not used; it stays inside the case

### 2.6 Enclosure

Our own parametric design, generated from Zig and built in SolidCraft:
[hardware/enclosure/README.md](../hardware/enclosure/README.md). 97.2 × 38.6 × 19.7 mm, two shells,
seven screws from underneath: one in each corner, one in the middle of the rear edge, two through the board.

- **Clear, not sealed** (owner decision, 2026-10-14). Every user builds and opens their own device,
  so a tamper-evident seal would prove nothing; a clear case lets you compare the inside with your
  assembly photo before each use
- **Thin**: the camera sits beside the board, not under it, and the four signal wires' header-side
  ends are unhoused and insulated, so the height is the display's (owner decision, 2026-10-14)

## 3. Wiring (no soldering)

**The RP2350-PiZero's header is not numbered like a Raspberry Pi's on every pin.** These pins differ
(Waveshare wiki and schematic):

| Header pin | 7 | 8 | 10 | 19 | 21 | 23 | 29 | 32 |
|---|---|---|---|---|---|---|---|---|
| RP2350-PiZero | GPIO14 | GPIO4 | GPIO5 | GPIO11 (SPI1 TX) | GPIO12 (SPI1 RX) | GPIO10 (SPI1 SCK) | GPIO15 | GPIO9 |
| Raspberry Pi | GPIO4 | GPIO14 | GPIO15 | GPIO10 | GPIO9 | GPIO11 | GPIO5 | GPIO12 |

Pins 2 and 4 are USB VBUS (5 V), pins 1 and 17 are 3.3 V.

**The Mini PiTFT** (plugged onto pins 1–24), in RP2350-PiZero GPIO numbers:

| Function | Header pin | GPIO |
|---|---|---|
| Display SPI MOSI / SCK | 19 / 23 | **GPIO11 / GPIO10 (SPI1)** |
| Display CS | 24 | GPIO8 (driven as a plain GPIO) |
| Display DC | 22 | GPIO25 |
| Backlight | 15 | GPIO22 (on by default through a pull-up; the backlight runs from 5 V) |
| Buttons | 16 / 18 | GPIO23 / GPIO24 (pulled up to 3.3 V) |
| STEMMA QT port | 3 / 5 (+ 3.3 V, GND) | SDA GPIO2 / SCL GPIO3 (I²C1). **No pull-ups on the module or the board** |

**The camera** (UC-805 header, odd row): power, I²C and ground from the Mini PiTFT's STEMMA QT port
through the #4397 cable; the four video signals to header pins on jumper wires.

| UC-805 pin | Signal | Goes to |
|---|---|---|
| 1 | VCC | STEMMA QT red (3.3 V) |
| 3 | SCL | STEMMA QT yellow → GPIO3 |
| 5 | SDA | STEMMA QT blue → GPIO2 |
| 7 | VSYNC | header pin **36** → GPIO16 |
| 9 | HREF | header pin **29** → GPIO15 |
| 11 | PCLK | header pin **33** → GPIO13 |
| 13 | D0 | header pin **32** → GPIO9 |
| 15 | GND | STEMMA QT black |

The four header pins are chequered across the two rows so the bare terminals (§4) never stand side by
side. Free header GPIOs left after this: pins 26 (GPIO7, partly under the display), 27 (GPIO0),
28 (GPIO1), 31 (GPIO6), 35 (GPIO19), 37 (GPIO26), 38 (GPIO20) and 40 (GPIO21).

**For the camera driver** (not written yet):

- The camera's I/O is **2.8 V**; the RP2350 reads it correctly at 3.3 V (V_IH 2.0 V). Its I²C pull-ups
  are on the camera (4.7 kΩ to 2.8 V), and are the only ones on the bus
- **Never drive XCLK**: the camera's own 24 MHz oscillator clocks it. In one-bit mode PCLK is 24 MHz,
  about 6 RP2350 cycles per bit at 150 MHz
- Capture in **one-bit mode** with PIO. Arm's
  [hm01b0-library-for-pico](https://github.com/ArmDeveloperEcosystem/hm01b0-library-for-pico) waits on
  absolute GPIO numbers, so only the data pin has to be chosen with PIO in mind; on the RP2350 the
  input pads must be initialised before use (input enable on, isolation off). Nothing is incorporated
  from it

## 4. Assembly (solder-free; about 30 minutes)

The full steps, with the case, are in
[hardware/enclosure/README.md](../hardware/enclosure/README.md#assembly). In short:

1. Plug the Mini PiTFT onto header pins 1–24, and the #4397 cable into its STEMMA QT socket underneath
2. **Unhouse one end of each of the four jumper wires** (lift the housing's latch with a pin and slide
   the terminal out), insulate the terminal with heat-shrink or polyimide tape, and push it onto
   header pins 29, 32, 33 and 36. This is the one hand step: a standard 14 mm housing would stand 6 mm
   above the display and make the case 25 mm thick
3. Plug the other ends and the #4397's sockets onto the camera's header (§3)
4. Lay the board and the camera (lens down) in the printed base, photograph the inside, close the
   top and drive in seven M2 × 16 screws from underneath
5. Copy the firmware's UF2 file to the board (hold BOOT while plugging in USB)

## 5. Verification (after assembly, before use)

| Item | Method |
|---|---|
| Firmware authenticity | Build the UF2 yourself, or check the release's hash and signature before copying it |
| Screen and buttons | Both buttons respond; the screen shows the whole layout |
| Camera | A test UR QR code shown on a phone is read at 10–20 cm |
| The inside | Matches your assembly photo: no extra parts, no extra wires (the case is clear for this) |
| No data path | Powered from a power-only cable or a power bank |

## 6. Maintenance and operation

- **Firmware updates**: a UF2 file over USB with BOOT held. Check its signature first; open the case
  if BOOT is not reachable through it
- **Switching off** is unplugging (§2.5). Nothing is kept: the seed exists only in RAM while powered
- **Disposal / transfer**: the design leaves nothing from which the seed can be recovered

## 7. Superseded options (history)

Kept so the reasons are not lost; the full research is in the git history before 2026-10-14.

| Option | Status | Why |
|---|---|---|
| Raspberry Pi Zero 2 WH (Linux, the v0.1 build) | Superseded by the RP2350-PiZero | It has a radio, which can only be disabled in software. [07-zero2w-setup.md](07-zero2w-setup.md) is kept for host-side work |
| Pi Zero 1.3 / Luckfox Pico / other Linux boards | Not adopted | Hard to obtain, or a header to fit, or a port of the Linux build |
| Waveshare 1.3" LCD HAT (240 × 240) | Replaced by the Mini PiTFT | It covers all 40 header pins, leaving nothing for an input device |
| Light receiver (LM393 module, then an Adafruit OPT4048 under a raised board) | Replaced by the camera; its code was removed (2026-10-14) | Cheapest, but tens of seconds per PSBT, a link layer only this project uses, and a 33.5 mm case |
| SD-card exchange | **Ruled out** (owner decision, 2026-10-13) | Shared media through the untrusted host |
| M5Stack QR Code Scanner Unit (decodes on the module) | Rejected (owner decision, 2026-10-13) | A third-party decoder on the input path |
| Arducam Mega 3 MP / 5 MP SPI, Arducam 5 MP Mini, OV2640 | Superseded by the UC-805 | Colour sensors with frames far larger than SRAM (windowing needed), at two to three times the price |
| RP2350 board with a built-in 2" touch screen and camera (Switch Science 10387) | Not adopted | A new UI and a new case for a capacitive touch screen; the chosen stack keeps physical buttons |
| Tamper-evident sealing of the case | Dropped (owner decision, 2026-10-14) | Users build and open their own devices; a clear case is recommended instead |

## 8. Additional requirements when selling (reference)

This BOM assumes **personal use**. Distributing or selling the device requires the following in addition.

- If an AC adapter is included: PSE
- For Europe and North America: CE / FCC (a camera and a microcontroller with no radio still need EMC conformity)
- Export control of cryptographic functions (even with public source code, US EAR can impose notification requirements)
