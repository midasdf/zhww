# hardware/enclosure/ — enclosure

- **Target**: RP2350-PiZero (65 × 30 mm) + **Adafruit Mini PiTFT 135×240 (#4393)** + an
  **Adafruit OPT4048 breakout (25.4 × 17.78 mm)** behind a short light-guide tube
- **Format**: [OpenSCAD](https://openscad.org/) (text; can be version-controlled and regenerated)
- **License**: **CC-BY-SA-4.0** (the repository's [LICENSE-ENCLOSURE](../../LICENSE-ENCLOSURE))

## What changed in v0.4 (and why)

| | v0.3 | **v0.4 (this one)** |
|---|---|---|
| Light sensor | LM393-type module, ~20 × 15 mm, resting on two rails | **Adafruit OPT4048 breakout, 25.4 × 17.78 mm**, resting on **four posts that enter the board's own Φ2.5 mounting holes** |
| Sensor bay | 16 mm extension of the interior | **30 × 22 mm internal pocket** (the 25.4 × 17.78 board + 4.6 mm in x and 4.22 mm in y), formed by two new internal walls |
| Light guide | printed sleeve ran from the floor up to the module's underside | printed collar is **exactly as tall as the guide** — the OPT4048 has parts within 4.5 mm of the aperture (pull-up pack 2.9 mm out, bypass caps 1.7 / 2.4 / 4.1 mm, regulator 2.4 mm; all from Adafruit's board file), so nothing may rise to the module there |
| Where the light enters | the photodiode was assumed to be over the sleeve | the aperture is an **explicit parameter marked as an estimate** (`opt_ap_from_left` / `opt_ap_from_front`); the collar, the floor window and the layout drawing all follow it |
| Case outline | 85.8 × 34.8 × 19.5 mm | **99.8 × 34.8 × 19.5 mm** (the same board section + a 30 mm bay) |
| Tray internals | — | **bug fix**: v0.3 cut the cavity *after* unioning the light-guide sleeve, the module rails, the bay screw bosses and the three floor pilots, so the cut removed all of them again. The printed tray had a bare bay, no collar and no screw pilots. The shell is now hollowed out first and those features are added afterwards |

The case is 14 mm longer than v0.3 because the module's 25.4 mm edge runs along the case's long
axis — the orientation the 30 × 22 mm bay is sized for. Turning the module 90° gives a 22 × 26.4 mm
pocket and a case about 8 mm shorter (91.8 mm), at the cost of a much deeper pocket with thinner bay
walls; the two aperture numbers would have to be re-read against the module's other edges. Nothing
else in the model depends on the choice.

## What changed in v0.3 (history: v0.2 → v0.3)

| | v0.2 (old) | v0.3 |
|---|---|---|
| Display | Waveshare 1.3inch LCD HAT (65 × 30.2 mm, 240×240) | **Adafruit Mini PiTFT #4393** (38.6 × 24.5 mm board, 1.14", 240×135, 2×12 socket) |
| Input on the display | joystick + 3 buttons on the HAT | **two tactile buttons on the module's own board** (GPIO23/24), one column at its left edge |
| Light input | none | **LM393 module in a new sensor bay**, looking down a light-guide tube at the phone screen |
| Case outline | 69.8 × 34.8 × 17.7 mm | **85.8 × 34.8 × 19.5 mm** (the same 69.8 mm board section + a 16 mm sensor bay) |
| Lid | 4 screw bosses, display window + joystick + 3 button holes | 5 screws, display window + 2 button holes |

The Mini PiTFT covers only the left half of the 40-pin header, so the rest of the header stays
reachable (that is where the LM393 module's three wires went in v0.3). The OPT4048 module in v0.4
needs no wires to the header at all: it hangs on the display's Qwiic/STEMMA QT port, with the cable
inside the case (see [docs/09-light-audio-input.md](../../docs/09-light-audio-input.md)).

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
| Light input | Camera (QR reading) | **No camera** — an OPT4048 module behind a light guide |

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
- OPT4048 breakout board 25.4 × 17.78 mm, 2.54 mm corner radius, four Φ2.5 plated mounting holes
  2.54 mm in from every edge, one STEMMA QT connector on each short edge, and the OPT4048 package
  **in the middle of the board** — Adafruit's published PCB source files (the Eagle `.brd`) `[D]`
- **Where the light-sensitive area sits inside that package** — not published in a form we could
  verify, so `opt_ap_from_left` / `opt_ap_from_front` are **estimates** `[E]`, and the first thing to
  measure (see below)
- The parts around the aperture on the module's underside (which is why the collar cannot rise to
  the board) — read off the same `.brd`: pull-up pack 2.9 mm from the aperture, bypass caps 1.7 / 2.4 /
  4.1 mm, regulator 2.4 mm `[D]`, their *heights* `[E]`
- Light guide "~Φ5 mm bore, 8–15 mm long" — from the project brief, never measured `[E]`

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

`part="check"` prints those rectangles — and now the sensor bay and the aperture estimate with them —
and asserts that none of them stop fitting:

```
ECHO: "zhww-case: display window x 7.51..33.91  y 7.08..22.78  (26.4 x 15.7 mm)"
ECHO: "zhww-case: button holes Φ4.6 at [3.04, 19.58] and [3.04, 10.83]  (x 0.74..5.34)"
ECHO: "zhww-case: window-to-button gap = 2.17 mm  PASS"
ECHO: "zhww-case: OPT4048 sensor bay 30 x 22 mm internal (x × y); module 25.4 x 17.78 mm → gap 4.6 mm in x (2.3 per side) and 4.22 mm in y (2.11 per side)"
ECHO: "zhww-case: aperture *** ESTIMATE, NOT MEASURED *** 12.7 mm from the module's left edge + 8.89 mm from its front edge → case x 80.4 y 15  (from the other two edges: 12.7 + 8.89 mm)"
ECHO: "zhww-case: light guide top is 0.8 mm below the estimated sensor window plane  (guide_to_pcb 1.8 - opt_pkg_h 1)"
```

The assertions behind them: window-to-button gap > 1.0 mm, the window and both button holes inside
the Mini PiTFT's board, the module inside the bay with > 1.0 mm to spare on each axis, the module's
mounting holes consistent with its outline, the aperture on the board, the collar inside the bay and
clear of the posts, the module clear of the lid, and the floor window narrower than the collar's bore.
Move a parameter past any of those limits and the render fails instead of producing an unusable STL.

If the real module turns out to differ, the parameters to change are `tft_lcd_dx`, `tft_lcd_dy`
(where the display sits), `tft_btn_dx`, `tft_btn_dy` (where the buttons sit) and `window_margin`.

## The light sensor bay

The light input decides whether the optical link works at all, so the case gives it a dedicated bay
on the right-hand end (no Pi board underneath):

- a **30 × 22 mm internal pocket** (`bay_len` × `bay_depth`) for the 25.4 × 17.78 mm OPT4048 board;
  the case's interior is 30.8 mm deep because of the Pi board, so two internal walls (`bay_wall_t`,
  4.4 mm) narrow the extension to the pocket;
- **clearance**: 4.6 mm in x (2.30 mm on each side) and 4.22 mm in y (2.11 mm on each side). The board
  is *centred* in the pocket, so those are real gaps, not an interference fit;
- **four posts** (`post_d` 3.6 mm shoulders with Φ2.2 mm spigots) that enter the board's own Φ2.5
  mounting holes. A pocket 2.11 mm wider than the board on each side would let a hand-placed module
  slide that far off the light guide, which is 2 mm of slop on a Φ5 mm light path — so the board's
  own holes are what locate it. The shoulder sits under the Φ4.0 plated pad ring, and the spigot
  passes 1.2 mm into the 1.6 mm hole;
- a **Φ5.4 mm light window** straight through the floor (`light_window_d`);
- a printed **collar** around it (Φ9 outer, Φ6.4 bore) rising from the floor;
- the user's **opaque light guide** (Φ5 bore, Φ6 outer, 10 mm in the model) drops into the collar and
  lands on the floor, which closes the ring around it;
- a **pad on the lid's underside** presses the module down on its posts.

**The aperture is an estimate.** The collar, the floor window and the layout drawing are all placed
from `opt_ap_from_left` / `opt_ap_from_front` — the sensing area's distance from the module's left
edge and its front edge. Both default to the board's centre (12.70, 8.89), because Adafruit's
published PCB files put the OPT4048 *package* in the middle of the board and their top-down photo
agrees. The position of the light-sensitive spot *inside* that 2.2 × 1.2 mm package is not published
in a form we could verify, so **treat both numbers as ±1–2 mm placeholders**. This is the one thing
to measure with calipers: centre of the clear window, from the module's left long edge and from its
front short edge. Change the two numbers, re-render, and the collar and the window follow.

Mounting orientation (so the two numbers mean something): the module goes in **sensor side down**,
its 25.4 mm edge along the case's x, its 6-pin-header edge (VIN/SCL/INT) towards the case's **rear**
wall. Turning the board over mirrors its own y axis, so the "front edge" in the parameter names is
the module's y = 17.78 edge — the silk "OPT4048 XYZ Color" edge in Adafruit's photo. The two STEMMA
QT connectors end up on the module's left and right edges: use the **inner** one (facing the Pi
board), because the outer one has only 2.3 mm to the bay wall. **Leave the 6-pin header unsoldered**:
with the board 14.8 mm up, 2.5 mm pins under its header edge would land on the collar.

The collar stops at the top of the light guide rather than at the module because the OPT4048 breakout
has parts on the same side as the sensor, close to the aperture: the nearest bypass cap 1.7 mm out,
the regulator 2.4 mm, a second cap 2.4 mm, the pull-up pack 2.9 mm, a third cap 4.1 mm (all from the
published board file — the collar's radius is 4.5 mm). The module's PCB therefore sits `guide_to_pcb`
(1.8 mm) above the guide's top, which clears the tallest of them (a SOT23-5, ~1.45 mm `[E]`) and
leaves the guide's mouth `guide_to_pcb - opt_pkg_h` (**0.8 mm**) below the estimated window plane.

The result: put the phone flat on the table and lay the case on the screen — the display still faces
the user, and only light that comes up the tunnel reaches the sensor. Room light has to travel down a
10 mm × Φ5 mm tube to get in. The lid's underside is 1.1 mm above the module's top face, and the lid's
pad fills exactly that gap.

Set `light_guide_od` to the real tube's outer diameter before printing (the bore is
`light_guide_od + 0.4`); if your tube is longer than 10 mm, raise `light_guide_len` — the collar, the
module and the lid pad all follow it. Watch the two assertions that guard that move (the module must
stay clear of the lid, and the tube's top stays 1.8 mm below the module's PCB, so a much longer tube
squeezes the module against the lid).

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
buttons and the display glass poking into the lid's window), the OPT4048 module on its four posts
with the light-guide tube inside the printed collar:

![Cross-section](../../docs/images/case-section.png)

**What we verified** (OpenSCAD 2026.10.11, `--render`, every image prints `Status: NoError`):

| Mode | Status | Genus | Vertices | Facets |
|---|---|---|---|---|
| `part="tray"` | `NoError` | 5 | 1852 | 3720 |
| `part="lid"` | `NoError` | 8 | 1038 | 2104 |
| `part="all"` | `NoError` | 12 | 2890 | 5824 |
| `part="section"` | `NoError` | 5 | 1899 | 3814 |
| `part="check"` | `NoError` | 2 | 1357 | 2718 |

`Genus` is OpenSCAD's own line, which is computed as `1 - χ/2` and therefore ignores the number of
shells — for the multi-shell modes it is not the sum of the parts' genera.

Reading the STLs back out (edges shared by exactly two triangles, Euler characteristic per shell):
tray **1 shell, genus 5** (HDMI + 2× USB-C + microSD + light window), lid **1 shell, genus 8**
(window + 2 buttons + 5 screws), `all` **2 shells, genus 13 = 5 + 8**, `section` 3 shells,
`check` 3 shells (one per drawing panel; the board panel carries the Pi's four mounting holes) — and
**0 non-manifold edges, 0 open edges and 0 inconsistently-oriented edges in every one of the five**.

The outer sizes come out at **99.8 × 34.8 × 17.5 mm** for the tray, **102.2 × 37.2 × 3.2 mm** for the
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
| Lid (display window, button holes, module pad) | 17.5–19.5 mm |

At the other end of the case the same stack is: light guide 3.0–13.0 mm inside the collar (which is
exactly as tall as the guide), the estimated sensor window plane at **13.8 mm**, the OPT4048 board
**14.8–16.4 mm** on its four posts, and the lid's pad filling the 1.1 mm between the module's top face
and the lid.

## Layout check drawing (for comparing against the real modules)

Three panels, side by side and all to scale: the **Pi board** (left), the **sensor bay** (middle, in
board coordinates), and the **Mini PiTFT in its own coordinates** (right — overlaying it on the board
would make them look like they interfere because of the height difference).

![Layout check drawing](../../docs/images/layout-check.png)

How to read it: blue = the board and the Mini PiTFT's board, green = the 40-pin header and the
module's 2×12 socket, grey = the connectors (HDMI and two USB-C on the front long edge, microSD on the
left short edge), dark = the 30 × 22 mm bay pocket, purple = the OPT4048 board, white dots = its four
Φ2.5 mounting holes (where the printed posts go), orange ring = the light-guide collar, gold dot =
the floor's light window (**both placed from the estimated aperture**), yellow = the lid's display
window, orange rectangle = the display's active area, red = the two button holes.

Print it at 1:1 on paper and lay the real boards on it: the bay panel is the one that tells you whether
`opt_ap_from_left` / `opt_ap_from_front` (and the module's four hole positions) are right — correct
that one first.

## Usage

```bash
# Install OpenSCAD
#   macOS: install the .dmg from the official distribution (https://openscad.org/downloads.html)
#          (the Homebrew cask does not pass Gatekeeper checks)
#   Linux: apt install openscad
openscad -o zhww-case.stl hardware/enclosure/zhww-case.scad          # export the STL
openscad -o tray.stl -D 'part="tray"' hardware/enclosure/zhww-case.scad
openscad -o lid.stl  -D 'part="lid"'  hardware/enclosure/zhww-case.scad

# self-check: prints the display window, button holes, bay and aperture numbers, and
# asserts that the window, the buttons, the bay and the light path still do not collide
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

(The commands are written from the repository root; from anywhere else, prefix the two paths with the
path to the checkout.)

**Fasteners**: five M2.5 × 18 mm self-tapping screws. Three pass through the board's own Φ3.00
mounting holes and bite into the 3 mm floor (blind pilots, so nothing shows on the underside); two go
into the sensor-bay bosses. Nothing stands inside the board's footprint, otherwise the board could
not be dropped into the tray — that is why the board's rear-left corner has no screw (the Mini PiTFT
is over it).

## Deliberately not in this version

- **No Qwiic/STEMMA QT opening.** The display's connector is on the Mini PiTFT's *underside*, facing
  down into the case, and the sensor's are inside the bay, so there is no sensible place for a
  cut-out. A 50 mm Qwiic cable is meant to run inside, from the display's port to the sensor module's
  inner connector (the one facing the Pi board — the outer one has only 2.3 mm to the bay wall).
  Nobody has run that cable yet; check the length and the bend radius when the hardware is in hand.
- **No header pins on the OPT4048 module.** The board goes in sensor side down, so a soldered 6-pin
  header would hang below its rear edge and land on the light-guide collar. Use the Qwiic cable (the
  whole point of choosing this module), or trim the pins.
- **No BAT opening any more.** Power is USB only, and the sensor bay now occupies that end of the
  case, so the 2-pin BAT connector sits inside (the numbers are still in the .scad for a future
  LiPo version, which would need a new opening).
- **No screw at the board's rear-left corner** — the Mini PiTFT's board is over it, and a boss there
  would make the case impossible to assemble (see below). Five screws hold the lid.

## Parameters to measure and fill in once the hardware is in hand

The parameters tagged **`MEASURED`** in `zhww-case.scad` (plus everything tagged `[E]`, and the
aperture in particular) are **placeholders or readings off photos and published board files, not
measurements**:

| Parameter | What to measure |
|---|---|
| **`opt_ap_from_left` / `opt_ap_from_front`** | **The sensor's aperture** — the centre of the clear window, from the module's left long edge and its front short edge. Currently the board's centre (12.70, 8.89) *because Adafruit's board file puts the package there*, not because anyone measured the spot inside the package. **This moves the collar and the floor window — measure it first** |
| `opt_pkg_h` / `guide_to_pcb` | How far the sensor package hangs below the module's PCB, and the gap from the light guide's top to that PCB. Together they set how far the guide's mouth sits below the window plane (0.8 mm now) |
| `post_spigot_d` / `post_d` | The module's Φ2.5 holes and the Φ4.0 pad rings (the `.brd` says 2.54 mm in from each edge; confirm on the board and file the spigots to fit) |
| `light_guide_od` / `light_guide_id` / `light_guide_len` | Your actual light-guide tube; the collar's bore is `light_guide_od + 0.4` and its height follows the guide |
| `header_x0` / `header_y_rear` | Where the 40-pin header actually sits on the board. **The display window's position depends on this** |
| `hole_inset` / `hole_d` | Mounting hole position and diameter (Φ3.00 is confirmed in the drawing; the 3.5 mm inset is assumed) |
| `header_h` | Height from the board's top face to the Mini PiTFT's PCB with the socket mated. **Every case height follows this one** |
| `tft_left_off` / `tft_rear_off` | Where the module's board sits relative to its 2×12 socket (currently read off Adafruit's photo) |
| `tft_lcd_dx` / `tft_lcd_dy` | Where the display's active area sits on the module (`[P]`; ±1 mm would show as an off-centre window) |
| `tft_lcd_w` / `tft_lcd_h` | The active area (`[E]`, derived from the diagonal — measure the lit rectangle) |
| `tft_btn_dx` / `tft_btn_dy` / `tft_btn_d` | The two buttons' centres and actuator diameter, and the module's PCB thickness (`tft_t`, `tft_glass_t`, `tft_btn_h`) |
| `usb_c1_x` / `usb_c2_x` / `usb_c_w/h`, `hdmi_x` / `hdmi_w/h` | Connector positions and sizes on the front long edge (read off the drawing) |
| `sd_y0` / `sd_len` / `sd_h` | microSD slot position, length and height (left short edge) |
| `clearance`, `wall`, `skirt_gap` | Print tolerances on your machine |

**Note**: the shape and the structure have been verified by rendering (manifold, no interference in
the model), but **nothing here has been caliper-measured**, and the aperture is an outright estimate.
Print the `part="check"` drawing at 1:1 on paper, lay the real boards on it, and correct the numbers
before committing to a long print.

## Sources (public information we referenced)

- RP2350-PiZero dimension drawing (65.00 × 30.00 mm, Φ3.00 mounting holes, 2.54 mm pitch, connector
  placement): the Dimensions image on the [Waveshare wiki](https://www.waveshare.com/wiki/RP2350-PiZero) /
  [CNX Software](https://www.cnx-software.com/2025/07/08/rp2350-pizero-rp2350-board-with-raspberry-pi-zero-form-factor-mini-hdmi-16mb-flash/)
- Mini PiTFT 135×240 (#4393) board dimensions 38.6 × 24.5 × 7.6 mm, two tactile buttons,
  Qwiic/STEMMA QT: [Adafruit product page](https://www.adafruit.com/product/4393) and the
  [Mini PiTFT pinouts guide](https://learn.adafruit.com/adafruit-mini-pitft-135x240-color-tft-add-on-for-raspberry-pi/pinouts)
  ("both versions have the same 2×12 connector", GPIO23/24 for the buttons). Button, socket and
  display positions were measured on the product's overhead photo.
- **OPT4048 breakout**: board outline 25.4 × 17.78 mm, the 2.54 mm corner radius, the four Φ2.5
  mounting holes 2.54 mm in from every edge, the OPT4048 package in the middle of the board, one
  STEMMA QT connector on each short edge, and the positions of the parts around the aperture — all
  from Adafruit's published PCB source files,
  [adafruit/Adafruit-OPT4048-XYZ-Color-Sensor-PCB](https://github.com/adafruit/Adafruit-OPT4048-XYZ-Color-Sensor-PCB)
  (the Eagle `.brd`). The [product page](https://www.adafruit.com/product/6335),
  [pinouts guide](https://learn.adafruit.com/adafruit-opt4048-xyz-color-sensor/pinouts) and the
  [Switch Science listings](https://www.switch-science.com/products/10457) cover the rest (0x44,
  ADDR jumper, level shifter, Qwiic ×2). **What none of them state is where the light-sensitive area
  sits inside the package** — that is the estimate in this model.
- OPT4048 as the light receiver (600 µs conversion, the wideband channel, why it beats a lux sensor)
  and the light-guide idea: [docs/09-light-audio-input.md](../../docs/09-light-audio-input.md) and
  [docs/03-hardware-bom.md](../../docs/03-hardware-bom.md)
- Reference for how to build the enclosure (community-made SeedSigner cases): [cyphergurke/seedsigner-thincase](https://github.com/cyphergurke/seedsigner-thincase) (MIT) and others
