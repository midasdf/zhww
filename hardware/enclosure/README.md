# hardware/enclosure/ — enclosure

- **Target**: RP2350-PiZero (65 × 30 mm) + **Adafruit Mini PiTFT 135×240 (#4393)** + an
  **LM393 light-sensor module** behind a short light-guide tube
- **Format**: [OpenSCAD](https://openscad.org/) (text; can be version-controlled and regenerated)
- **License**: **CC-BY-SA-4.0** (the repository's [LICENSE-ENCLOSURE](../../LICENSE-ENCLOSURE))

## What changed in v0.3 (and why)

| | v0.2 (old) | **v0.3 (this one)** |
|---|---|---|
| Display | Waveshare 1.3inch LCD HAT (65 × 30.2 mm, 240×240) | **Adafruit Mini PiTFT #4393** (38.6 × 24.5 mm board, 1.14", 240×135, 2×12 socket) |
| Input on the display | joystick + 3 buttons on the HAT | **two tactile buttons on the module's own board** (GPIO23/24), one column at its left edge |
| Light input | none | **LM393 module in a new sensor bay**, looking down a light-guide tube at the phone screen |
| Case outline | 69.8 × 34.8 × 17.7 mm | **85.8 × 34.8 × 19.5 mm** (the same 69.8 mm board section + a 16 mm sensor bay) |
| Lid | 4 screw bosses, display window + joystick + 3 button holes | 5 screws, display window + 2 button holes |

The Mini PiTFT covers only the left half of the 40-pin header, so the rest of the header
stays reachable — that is where the light sensor's three wires go (see
[docs/09-light-audio-input.md](../../docs/09-light-audio-input.md)).

## Why we do not use the SeedSigner STL as-is

**The board dimensions fit, but nothing else does.**

| | SeedSigner (Raspberry Pi Zero) | This project (RP2350-PiZero) |
|---|---|---|
| Board dimensions | 65 × 30 mm | **The same** (65 × 30 mm) |
| Display | Waveshare 1.3inch LCD HAT | **A different display**, and it is a module, not a HAT |
| Power and data connectors | micro-USB ×2 (left short edge and front long edge) | **mini HDMI + USB-C ×2 on the front long edge** (from the left: HDMI / PIO-USB / USB) |
| Storage medium | microSD (towards the front long edge) | **The left short edge** (the card is inserted from the left) |
| Battery | None | A 2-pin BAT connector on the right short edge, **inside the case now** (USB power only) |
| Mounting holes | Around Φ2.75 (varies by model) | **Φ3.00 ×4** at the four corners (Pi Zero placement) |
| Light input | Camera (QR reading) | **No camera** — an LM393 module behind a light guide |

So reusing an existing STL means **the hole positions do not line up**. If you modify one and
redistribute it, you also have to carry over the license terms of the source (they vary: MIT / CC /
unknown. For example, [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) is MIT
and includes editable Inventor (.ipt) sources).

**So the SeedSigner case is kept only as "a reference for how to build one", and we provide our own parametric OpenSCAD instead.**

- We can decide the license ourselves (CC-BY-SA-4.0)
- **The dimensions are parameters**, so the model can be regenerated when parts change
- It is text, so it can be version-controlled and reviewed (the same style as the rest of this repository)

## Where the numbers come from (read this before printing)

**Nothing in this file has been measured with calipers yet.** Every dimension in
`zhww-case.scad` carries one of four tags:

| Tag | Meaning |
|---|---|
| `[D]` | **Published dimension** — an official drawing or the vendor's product page |
| `[P]` | **Read off a product photo** — measured in pixels and scaled by a known pitch. Good to roughly ±0.5–1 mm |
| `[E]` | **Our estimate / placeholder** — no published value exists |
| `MEASURED` | A value that **must be confirmed with calipers** before the print can be trusted |

The load-bearing values:

- Board outline 65.00 × 30.00 mm, Φ3.00 mounting holes, 40-pin header at 2.54 mm pitch — the
  Waveshare RP2350-PiZero drawing `[D]`
- Mini PiTFT board 38.6 × 24.5 mm, "2×12 connector", buttons on GPIO23/24, Qwiic/STEMMA QT on the
  module's underside — the Adafruit product page and the Mini PiTFT pinouts guide `[D]`
- **Where things sit on the Mini PiTFT** (socket offset, display centre, the two button centres) —
  measured in pixels on Adafruit's top-down product photo, scaled by the socket's 2.54 mm pitch `[P]`
- Display active area 24.4 × 13.7 mm — derived from a 1.14" 240×135 panel at a 0.1016 mm dot pitch.
  **Adafruit does not publish the active area**, so this is an estimate `[E]`
- The 40-pin header's position on the board (`header_x0`, `header_y_rear`) — assumed centred /
  Pi-Zero-like `[P]`
- LM393 module "about 20 × 15 mm", light guide "~Φ5 mm inner, 8–15 mm long" — from the project brief,
  never measured `[E]`

## The display window is *not* 38.6 × 24.5 mm (and why)

The Mini PiTFT's **board** is 38.6 × 24.5 mm. The lid's window is **26.4 × 15.7 mm**, because the
module's two tactile buttons are on that same 38.6 × 24.5 mm face, in a vertical pair at its left
edge. A window the size of the whole board would swallow both buttons and leave nothing to press.

So the numbers are used like this:

- **38.6 × 24.5 mm** — the module's board outline. The case *fits* it (the cavity, the lid height and
  the screw positions are built around it), and the module's left and rear edges end up flush with
  the Pi's board edges, as in Adafruit's own "mounted on a Pi Zero" photo.
- **26.4 × 15.7 mm** — the actual window in the lid: the display's active area (24.4 × 13.7 mm) plus
  a 1.0 mm margin on every side (`window_margin`). It keeps a **2.17 mm** wall to the button holes.

`part="check"` prints those rectangles and asserts they never intersect:

```
ECHO: "zhww-case: display window x 7.51..33.91  y 7.08..22.78  (26.4 x 15.7 mm)"
ECHO: "zhww-case: button holes Φ4.6 at [3.04, 19.58] and [3.04, 10.83]  (x 0.74..5.34)"
ECHO: "zhww-case: window-to-button gap = 2.17 mm  PASS"
```

If the real module turns out to differ, the parameters to change are `tft_lcd_dx`, `tft_lcd_dy`
(where the display sits), `tft_btn_dx`, `tft_btn_dy` (where the buttons sit) and `window_margin`.

## The light sensor bay

The light input is the part that decides whether the optical link works at all, so the case gives it
a dedicated bay on the right-hand end (16 mm of interior, no Pi board underneath):

- a **Φ5.4 mm light window** straight through the tray's floor (`light_window_d`);
- a printed **sleeve** around it (Φ9 outer, Φ6.4 bore) rising from the floor to just under the
  sensor module;
- the user's **opaque light-guide tube** (Φ5 inner, 8–15 mm in the brief; `light_guide_len = 10`)
  drops into the sleeve and lands on the floor, which closes the ring around it;
- two **rails** at the same height carry the LM393 module, sensor side down, so its photodiode ends
  up inside the tube and its trimmer hangs in the bay below.

The result: put the phone flat on the table and lay the case on the screen — the display still faces
the user, and only light that comes up the tunnel reaches the photodiode. Room light has to travel
down a 10 mm × Φ5 mm tube to get in.

Set `light_guide_od` to the real tube's outer diameter before printing (the bore is
`light_guide_od + 0.4`); the sleeve is a plain cylinder, so it is an easy edit. If your tube is
longer than 10 mm, raise `light_guide_len` — `sensor_deck_z` follows it, but the module then gets
closer to the lid (there is 1.9 mm of air at 10 mm).

## Rendered results (verified)

![Isometric view of the enclosure](../../docs/images/case-iso-v2.png)

*Left is the tray (front connector cut-outs, the light window in the floor at the right-hand end),
right is the lid (display window, two button holes, five screw holes).*

**Orthographic projection from directly above** (lid layout, and the tray with its light window):

![Top of the lid](../../docs/images/case-top-v2.png)

**Front projection of both parts** (the three connector openings on the front long edge; tilted 12°
so the openings read instead of vanishing edge-on):

![Front](../../docs/images/case-front-v2.png)

**Cross-section (isometric, front half cut away)** — board, header, Mini PiTFT (with its two
buttons and the display glass poking into the lid's window), the LM393 module on its rails and the
light-guide tube in its sleeve:

![Cross-section](../../docs/images/case-section.png)

**What we verified** (OpenSCAD 2026.10.11, `--render`, every image prints `Status: NoError`):

| Mode | Status | Genus | Vertices | Facets |
|---|---|---|---|---|
| `part="tray"` | `NoError` | 5 | 336 | 688 |
| `part="lid"` | `NoError` | 8 | 941 | 1910 |
| `part="all"` | `NoError` | 12 | 1277 | 2598 |
| `part="section"` | `NoError` | 2 | 1074 | 2152 |
| `part="check"` | `NoError` | 2 | 967 | 1938 |

Reading the STLs back out (edges shared by exactly two triangles, Euler characteristic per shell):
tray **genus 5** (HDMI + 2× USB-C + microSD + light window), lid **genus 8** (window + 2 buttons +
5 screws), `all` = 2 shells, genus 13 = 5 + 8, **0 non-manifold edges** in every case.

The outer sizes come out at **85.8 × 34.8 × 17.5 mm** for the tray, **88.2 × 37.2 × 3.2 mm** for the
lid (2.0 mm plate plus a 1.2 mm skirt that drops over the tray, which overhangs by 1.2 mm on each
side) and **19.5 mm** tall once assembled.

## Heights (the module stack)

The lid is derived from the stack below it, so changing `header_h` moves the lid with it.

| Layer | Height (z, case bottom = 0) |
|---|---|
| Case floor | 0–3.0 mm |
| Board (65 × 30 × 1.6) | 3.0–4.6 mm |
| microSD card | 4.8–5.6 mm (directly above the board) |
| 40-pin header (mated) | 4.6–13.1 mm |
| Mini PiTFT board | 13.1–14.7 mm |
| Display glass / button tops | 14.7–16.7 mm |
| Lid underside | **17.5 mm** |
| Lid (display window, button holes) | 17.5–19.5 mm |

At the other end of the case the same stack is: LM393 board underside at **14.0 mm**, its top at
15.6 mm — 1.9 mm below the lid.

## Layout check drawing (for comparing against the real module)

The **left panel is the board (lower layer)**, the **right panel is the Mini PiTFT in its own
coordinates**, and the sensor bay is drawn to scale between them (overlaying them would make them
look like they interfere because of the height difference).

![Layout check drawing](../../docs/images/layout-check.png)

How to read it: blue = the board, green = the 40-pin header and the module's 2×12 socket,
grey = the connectors (HDMI and two USB-C on the front long edge, microSD on the left short edge),
dark = the sensor bay, orange ring = the light-guide sleeve, gold dot = the light window,
yellow = the lid's display window, orange rectangle = the display's active area,
red = the two button holes.

## Usage

```bash
# Install OpenSCAD
#   macOS: install the .dmg from the official distribution (https://openscad.org/downloads.html)
#          (the Homebrew cask does not pass Gatekeeper checks)
#   Linux: apt install openscad
openscad -o zhww-case.stl hardware/enclosure/zhww-case.scad          # export the STL
openscad -o tray.stl -D 'part="tray"' hardware/enclosure/zhww-case.scad
openscad -o lid.stl  -D 'part="lid"'  hardware/enclosure/zhww-case.scad

# self-check: prints the display-window / button-hole rectangles and asserts they are apart
openscad -o check.png --render -D 'part="check"' hardware/enclosure/zhww-case.scad
```

The images above were regenerated with (macOS path shown; `--autocenter --viewall` does the framing):

```bash
OSCAD=/Applications/OpenSCAD.app/Contents/MacOS/OpenSCAD
D=hardware/enclosure/zhww-case.scad
C="--render --imgsize=1400,800 --projection=o --colorscheme=Tomorrow --autocenter --viewall"

$OSCAD -o docs/images/case-iso-v2.png     $C --camera=0,0,0,55,0,25,180 -D 'part="all"'     $D
$OSCAD -o docs/images/case-top-v2.png     $C --camera=0,0,0,0,0,0,180   -D 'part="all"'     $D
$OSCAD -o docs/images/case-front-v2.png   $C --camera=0,0,0,78,0,0,180  -D 'part="all"'     $D
$OSCAD -o docs/images/case-section.png    $C --camera=0,0,0,55,0,25,180 -D 'part="section"' $D
$OSCAD -o docs/images/layout-check.png    $C --camera=0,0,0,0,0,0,180   -D 'part="check"'   $D
cp docs/images/case-iso-v2.png docs/images/case-preview.png   # the name docs/03-hardware-bom.md uses
```

`docs/images/case-section-front.png` is **not referenced by anything any more** and still shows the
old LCD-HAT version; it is a candidate for deletion.

**Fasteners**: five M2.5 × 18 mm self-tapping screws. Three pass through the board's own Φ3.00
mounting holes and bite into the 3 mm floor (blind pilots, so nothing shows on the underside); two go
into the sensor-bay bosses. Nothing stands inside the board's footprint, otherwise the board could
not be dropped into the tray — that is why the board's rear-left corner has no screw (the Mini PiTFT
is over it).

## Deliberately not in this version

- **No Qwiic/STEMMA QT opening.** The connector is on the Mini PiTFT's *underside* and faces down
  into the case, so there is no sensible place for a cut-out. A cable can still be routed inside,
  towards the sensor bay and the free header pins; otherwise use the module with the lid off.
- **No BAT opening any more.** Power is USB only, and the sensor bay now occupies that end of the
  case, so the 2-pin BAT connector sits inside (the numbers are still in the .scad for a future
  LiPo version, which would need a new opening).
- **No screw at the board's rear-left corner** — the Mini PiTFT's board is over it, and a boss there
  would make the case impossible to assemble (see below). Five screws hold the lid.
- `docs/images/case-section-front.png` is stale and unreferenced (see above).

## Parameters to measure and fill in once the hardware is in hand

The parameters tagged **`MEASURED`** in `zhww-case.scad` are **placeholders or photo readings,
not measurements**:

| Parameter | What to measure |
|---|---|
| `header_x0` / `header_y_rear` | Where the 40-pin header actually sits on the board. **The display window's position depends on this** |
| `hole_inset` / `hole_d` | Mounting hole position and diameter (Φ3.00 is confirmed in the drawing; the 3.5 mm inset is assumed) |
| `header_h` | Height from the board's top face to the Mini PiTFT's PCB with the socket mated. **Every case height follows this one** |
| `tft_left_off` / `tft_rear_off` | Where the module's board sits relative to its 2×12 socket (currently read off Adafruit's photo) |
| `tft_lcd_dx` / `tft_lcd_dy` | Where the display's active area sits on the module (`[P]`; ±1 mm would show as an off-centre window) |
| `tft_lcd_w` / `tft_lcd_h` | The active area (`[E]`, derived from the diagonal — measure the lit rectangle) |
| `tft_btn_dx` / `tft_btn_dy` / `tft_btn_d` | The two buttons' centres and actuator diameter, and the module's PCB thickness (`tft_t`, `tft_glass_t`, `tft_btn_h`) |
| `usb_c1_x` / `usb_c2_x` / `usb_c_w/h`, `hdmi_x` / `hdmi_w/h` | Connector positions and sizes on the front long edge (read off the drawing) |
| `sd_y0` / `sd_len` / `sd_h` | microSD slot position, length and height (left short edge) |
| `light_window_d`, `light_guide_od`, `light_guide_len` | Your actual light-guide tube, and the LM393 board's real size (`sensor_mod_x` / `sensor_mod_y`) and photodiode position |
| `clearance`, `wall`, `skirt_gap` | Print tolerances on your machine |

**Note**: the shape and the structure have been verified by rendering (manifold, no interference in
the model), but **every position above is still an estimate**. Print the `part="check"` drawing at
1:1 on paper, lay the real module on it, and correct the numbers before committing to a long print.

## Sources (public information we referenced)

- RP2350-PiZero dimension drawing (65.00 × 30.00 mm, Φ3.00 mounting holes, 2.54 mm pitch, connector
  placement): the Dimensions image on the [Waveshare wiki](https://www.waveshare.com/wiki/RP2350-PiZero) /
  [CNX Software](https://www.cnx-software.com/2025/07/08/rp2350-pizero-rp2350-board-with-raspberry-pi-zero-form-factor-mini-hdmi-16mb-flash/)
- Mini PiTFT 135×240 (#4393) board dimensions 38.6 × 24.5 × 7.6 mm, two tactile buttons,
  Qwiic/STEMMA QT: [Adafruit product page](https://www.adafruit.com/product/4393) and the
  [Mini PiTFT pinouts guide](https://learn.adafruit.com/adafruit-mini-pitft-135x240-color-tft-add-on-for-raspberry-pi/pinouts)
  ("both versions have the same 2×12 connector", GPIO23/24 for the buttons). Button, socket and
  display positions were measured on the product's overhead photo.
- LM393 light-sensor module (photodiode + comparator, AO/DO) and the light-guide idea:
  [docs/09-light-audio-input.md](../../docs/09-light-audio-input.md)
- Reference for how to build the enclosure (community-made SeedSigner cases): [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) (MIT) and others
