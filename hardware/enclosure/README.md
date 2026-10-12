# hardware/enclosure/ — enclosure

- **Target**: RP2350-PiZero (65 × 30mm) + Waveshare 1.3inch LCD HAT
- **Format**: [OpenSCAD](https://openscad.org/) (text; can be version-controlled and regenerated)
- **License**: **CC-BY-SA-4.0** (the repository's [LICENSE-ENCLOSURE](../../LICENSE-ENCLOSURE))

## Why we do not use the SeedSigner STL as-is

**The dimensions fit, but the port cut-outs do not.**

| | SeedSigner (Raspberry Pi Zero) | This project (RP2350-PiZero) |
|---|---|---|
| Board dimensions | 65 × 30mm | **The same** (65 × 30mm) |
| Display | Waveshare 1.3inch LCD HAT | **The same HAT** (65 × 30.2mm) |
| Power and data connectors | micro-USB ×2 (on the left short edge and the front long edge) | **mini HDMI + USB-C ×2 on the front long edge** (from the left: HDMI / PIO-USB / USB) |
| Storage medium | microSD (towards the front long edge) | **The left short edge** (the card is inserted from the left) |
| Battery | None | **A 2-pin BAT connector on the right short edge** (not used, but leave an opening for it) |
| Mounting holes | Around Φ2.75 (varies by model) | **Φ3.00 ×4** (at the four corners; the same placement as the Pi Zero) |
| Buttons | None | **BOOT / RUN buttons present** (on the board. Either make them pressable through the case, or use it with the lid off) |
| Camera | Pi camera (QR reading) | **Not fitted** (no camera hole needed) |

**The actual layout of the HAT (Waveshare 1.3inch LCD HAT)** (from product photos):

| Part | Position |
|---|---|
| 3 buttons (KEY1–3) | **A single vertical column along the left short edge** |
| LCD | Slightly left of centre (display area 23.4 × 23.4mm) |
| Joystick | **Towards the right short edge, centred** |
| Mounting holes | The four corners (the same positions as the board) |

So reusing an existing STL means **the hole positions do not line up**. If you modify one and
redistribute it, you also have to carry over the license terms of the source (they vary: MIT / CC /
unknown. For example, [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) is MIT
and includes editable Inventor (.ipt) sources).

**So the SeedSigner case is kept only as "a reference for how to build one", and we provide our own parametric OpenSCAD instead.**

- We can decide the license ourselves (CC-BY-SA-4.0)
- **The dimensions are parameters**, so the model can be regenerated when parts change
- It is text, so it can be version-controlled and reviewed (the same style as the rest of this repository)

## Rendered results (verified)

![Isometric view of the enclosure](../../docs/images/case-iso-v2.png)

**Orthographic projection from directly above** (for checking the lid layout):

![Top of the lid](../../docs/images/case-top-v2.png)

**Orthographic front projection** (the front connector cut-outs):

![Front](../../docs/images/case-front-v2.png)

*Left is the bottom (the tray: posts at the four corners holding the HAT down, a USB-C cut-out on the right side), right is the lid
(display window, joystick, 3 buttons). Rendered on 2026-10-12 with OpenSCAD 2026.10.11.*

**What we verified**:

| Item | Result |
|---|---|
| Syntax and rendering | `Status: NoError` (a valid manifold) |
| Bottom (tray) | Outer 69.8 × 34.8 × 15.7mm = board 65×30 + wall 2×2 + clearance 0.4×2 ✅ |
| Lid | Outer 69.8 × 34.8 × 3.5mm ✅ |
| **Connector orientation** | The first version put USB-C on the right side, but **the official dimension drawing puts it on the front long edge**, so it was corrected everywhere ✅ |
| **HAT layout** | The first version put the buttons in a horizontal row, but **the real unit has a vertical column at the left edge**, so it was corrected ✅ |
| Interference | The overlap between the display window and the button holes was detected in the first version and has already been fixed ✅ |
| Mounting | Added bosses aligned with the board's Φ3.00 holes (M2.5 pilot holes) ✅ |

**The only thing not yet measured is the hole positions**; the outer shape and structure are settled.

### Heights (the buttons and the microSD do not interfere)

After a comment that "the cut-outs and the buttons look like they interfere", we checked the cross-section.
A 2D overlay is a **projection**, so things at different heights also appear to overlap. The actual heights are as follows.

| Layer | Height (z, case bottom = 0) |
|---|---|
| Case base plate | 0–2.0mm |
| Board (65 × 30 × 1.6) | 2.0–3.6mm |
| **microSD card** | 3.6–4.4mm (directly above the board) |
| 40-pin header | 3.6–12.1mm |
| **HAT** | 12.1–13.7mm |
| Lid (**button holes**) | 13.7–15.7mm |

**The button holes are more than 10mm above the microSD card**, so they do not interfere.
The card passes between the board and the HAT (an 8.5mm gap) and is inserted and removed through the opening in the left face of the case (14 × 3mm).

![Cross-section (isometric view with the front half cut away)](../../docs/images/case-section.png)

### Layout check drawing (for comparing against the official dimension drawing)

The **left panel is the board (lower layer)** and the **right panel is the HAT (upper layer)**, drawn separately
(overlaying them would make them look like they interfere because of the height difference).

![Layout check drawing](../../docs/images/layout-check.png)

```bash
openscad -o layout-check.png --imgsize=1300,700 --projection=o --camera=0,0,0,0,0,0,300 \
  --autocenter --viewall -D 'part="check"' hardware/enclosure/zhww-case.scad
```

How to read it: blue = the board (65×30, rounded corners, Φ3.00 holes at the four corners), green = the 40-pin header (the rear long edge),
grey = the connectors (HDMI and USB-C ×2 on the front long edge, microSD on the left short edge, BAT on the right short edge),
orange = the HAT's LCD, red = the HAT's 3 buttons (a vertical column at the left edge) and the joystick (right).

## Usage

```bash
# Install OpenSCAD
#   macOS: install the .dmg from the official distribution (https://openscad.org/downloads.html)
#          Note: the Homebrew cask does not pass Gatekeeper checks and was disabled on 2026-09-01
#   Linux: apt install openscad
openscad -o zhww-case.stl hardware/enclosure/zhww-case.scad          # export the STL
openscad -o tray.stl -D 'part="tray"' hardware/enclosure/zhww-case.scad
openscad -o lid.stl  -D 'part="lid"'  hardware/enclosure/zhww-case.scad

# preview image (the same one used in this README)
openscad -o case.png --imgsize=1000,750 --autocenter --viewall --projection=o \
  --colorscheme=Tomorrow hardware/enclosure/zhww-case.scad
```

## Parameters to measure and fill in once the hardware arrives

The parameters marked **`MEASURED`** in `zhww-case.scad` are
**placeholder values, because public information does not give them**. Measure them on the real hardware and update them.

| Parameter | What to measure |
|---|---|
| `display_x` / `display_y` | Distance from the HAT board edge to the LCD display area (currently read off photos) |
| `joystick_x` / `joystick_y` / `joystick_d` | Joystick centre position and shaft diameter (currently placed provisionally to the right of the LCD) |
| `button1..3_x/y` / `button_d` | Centre positions and diameter of the 3 buttons |
| `usb_c1_x` / `usb_c2_x` / `usb_c_w/h` | Left/right positions and dimensions of the two USB-C connectors (front long edge) |
| `hdmi_x` / `hdmi_w/h` | Position and dimensions of the mini HDMI (towards the left of the front long edge) |
| `sd_y0` / `sd_len` / `sd_h` | Position, length and height of the microSD slot (left short edge) |
| `bat_y0` / `bat_w/h` | Position of the BAT connector (right short edge; for an optional LiPo mod) |
| `hole_inset` / `hole_d` | Mounting hole position (distance from the edge) and diameter (**Φ3.00 is confirmed in the official drawing**) |
| `header_h` | Height with the 40-pin header and socket mated |

**Note**: the outer shape and structure have been verified by rendering, but **the hole positions will be settled after measuring**.
The current values are what public information gives plus reasonable placeholders; update them to match the real hardware.

## Sources (public information we referenced)

- RP2350-PiZero dimension drawing (65.00 × 30.00mm, Φ3.00 mounting holes, 2.54mm pitch, connector placement):
  the Dimensions image on the [Waveshare wiki](https://www.waveshare.com/wiki/RP2350-PiZero) /
  [CNX Software](https://www.cnx-software.com/2025/07/08/rp2350-pizero-rp2350-board-with-raspberry-pi-zero-form-factor-mini-hdmi-16mb-flash/)
- 1.3inch LCD HAT dimensions 65 × 30.2mm, display area 23.4 × 23.4mm: [Waveshare wiki](https://www.waveshare.com/wiki/1.3inch_LCD_HAT)
- Reference for how to build the enclosure (community-made SeedSigner cases): [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) (MIT) and others
