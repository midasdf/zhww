// zhww enclosure (OpenSCAD, parametric)
//
// Hardware: Waveshare RP2350-PiZero (65 × 30 mm) + **Adafruit Mini PiTFT 135x240
//           (product 4393)** on the 40-pin header + an **Adafruit OPT4048 breakout**
//           (25.4 × 17.78 mm) **underneath the raised main board**, behind a short opaque
//           light-guide tube that looks **down through the case's floor**. USB power only.
//
// **v0.5 — the light sensor looks down through the underside of the case.** The 30 × 22 mm
// side bay of v0.3/v0.4 is gone: the footprint is back to the board's 65 × 30 mm plus walls
// (plus a 2.4 mm cable channel at the front), and the case grew in *thickness* instead. To
// send, you lay the device on the phone's screen — it self-aligns, it is hands-free, and the
// phone itself shields the sensor from room light while the display keeps facing the user.
//
// The case is two parts: a tray (floor, four board standoffs, four sensor posts, the
// light-guide collar, and the front cable channel) and a lid (display window, two button
// holes, three screws).
//
// **Coordinate convention** (unchanged from v0.2, except that the board no longer rests on
// the floor):
//   x = the board's long edge (0 = left = the microSD end, 65 = right)
//   y = the board's short edge (0 = front = the USB-C edge, 30 = rear = the 40-pin header edge)
//   z = height (0 = the case's outside bottom)
//   The case's own origin is the tray's outer corner. The board sits at
//   (board_x0, board_y0, board_z) = (wall + clearance, wall + clearance + cable_channel,
//   floor_t + standoff_h): raised on four standoffs so the sensor module fits underneath it,
//   and set back from the front wall so the Qwiic cable has a channel to drop through.
//
// ## Where the numbers come from (important)
//
// **Nothing has been measured with calipers yet.** Every parameter carries a tag:
//
//   [D] published dimension — an official drawing, a vendor page, or the vendor's own PCB file
//   [P] read off a product photo — a scale estimate from pixels, not a measurement
//   [E] engineering estimate / placeholder chosen by us
//   MEASURED: confirm this on the real hardware with calipers, then update the value
//
// Sources are listed in README.md ("Sources"). The load-bearing ones:
//   - Board outline 65.00 × 30.00, Φ3.00 mounting holes, 40-pin header at 2.54 mm pitch
//     — the Waveshare RP2350-PiZero dimension drawing ................... [D]
//   - Mini PiTFT module board 38.6 × 24.5 mm, "2x12 connector" (pins 1–24), two tactile
//     buttons on GPIO23/24, Qwiic/STEMMA QT on the module's underside
//     — the Adafruit product page and the Mini PiTFT pinouts guide ............ [D]
//   - Everything about *where* things sit on the Mini PiTFT (socket offset, display
//     centre, button centres) — measured in pixels on Adafruit's top-down product photo,
//     scaled by the socket's 2.54 mm pitch .................................. [P]
//   - Display active area 24.4 × 13.7 mm — derived from a 1.14" 240×135 panel
//     (0.1016 mm dot pitch). Adafruit does not publish the active area .......... [E]
//   - OPT4048 breakout board 25.4 × 17.78 mm, 2.54 mm corner radius, four Φ2.5 plated
//     mounting holes at (2.54, 2.54) / (22.86, 2.54) / (2.54, 15.24) / (22.86, 15.24), the
//     OPT4048 package U1 at (12.70, 8.89), one STEMMA QT connector on each short edge
//     (CONN1 at x 3.175, CONN2 at x 22.225, both at y 8.89, mouths facing outwards)
//     — Adafruit's published PCB files (adafruit/Adafruit-OPT4048-XYZ-Color-Sensor-PCB,
//     the Eagle .brd) ....................................................... [D]
//   - **Where the light-sensitive area sits on that board** — the *package* is at
//     (12.70, 8.89) (the .brd says so and Adafruit's photo agrees), but the position of the
//     sensing spot inside the 2.2 × 1.2 mm package is not published in a form we could
//     verify. `opt_ap_from_left` / `opt_ap_from_front` are therefore ESTIMATES (±1–2 mm)
//     and are the first thing to measure on the real board .......................... [E]
//   - The Mini PiTFT's Qwiic connector (CONN1, mirrored to the module's underside in the
//     same Eagle .brd, adafruit/Adafruit-Mini-PiTFT-240x135-TFT-PCB): shell from x 6.525 to
//     12.625 of the module's 38.1 mm, its mouth 0.5 mm in from the module's front edge,
//     facing the front edge — v0.5's cable route depends on this ................... [D]
//   - Light guide ~Φ5 mm bore × 8–15 mm — from the project brief, not measured ....... [E]
//
// ## License
//
// CC-BY-SA-4.0 (the repository's LICENSE-ENCLOSURE)

// ---------------------------------------------------------------- board (RP2350-PiZero)

board_w = 65.0;         // [D] long edge (official drawing)
board_d = 30.0;         // [D] short edge (official drawing)
board_t = 1.6;          // [E] board thickness
corner_r = 3.0;         // [D] board corner radius
hole_d = 3.0;           // [D] Φ3.00 mounting holes
hole_inset = 3.5;       // [P] edge to hole centre (Pi Zero standard)  MEASURED

// 40-pin header along the rear long edge
header_pitch = 2.54;    // [D]
header_cols = 20;       // [D]
header_x0 = 8.37;       // [P] x of column 0 (pin 1, microSD end); header assumed centred
                        //     on the board  MEASURED
header_y_rear = 27.0;   // [P] y of the row nearer the rear edge  MEASURED
header_y_front = header_y_rear - header_pitch;
header_h = 8.5;         // [E] board top face -> add-on board underside, socket mated
                        //     (this sets the lid height)  MEASURED

// ---------------------------------------------------------------- connectors, front long edge
// Values read off the official drawing (MEASURED: confirm by measuring)
usb_c_w = 9.0;          // USB-C cut-out
usb_c_h = 3.6;
usb_c1_x = 33.0;        // left edge of the PIO-USB one
usb_c2_x = 47.0;        // left edge of the USB one
hdmi_w = 11.0;          // mini HDMI (leftmost)
hdmi_h = 3.0;
hdmi_x = 8.0;

// microSD slot on the left short edge (the card is inserted from the left)
sd_h = 3.0;             // slot height
sd_y0 = 6.0;            // front edge of the slot
sd_len = 14.0;          // slot length (along y)

// BAT connector on the right short edge. It is **not cut out**: power is USB only, so the
// connector sits inside the case. The numbers are kept so a future LiPo version knows where
// it is (and where a new opening would have to go).
bat_w = 8.0;            // [P]
bat_h = 4.0;
bat_y0 = 11.0;

// ---------------------------------------------------------------- Mini PiTFT #4393

tft_w = 38.6;           // [D] module board (Adafruit: 38.6 × 24.5 × 7.6 mm overall)
tft_d = 24.5;           // [D]
tft_t = 1.6;            // [E] module PCB thickness (the 7.6 mm includes the socket below)
tft_cols = 12;          // [D] 2×12 socket -> the first 12 header columns (pins 1–24)
tft_sock_cx = header_x0 + (tft_cols - 1) * header_pitch / 2;   // = 22.34
tft_sock_cy = (header_y_rear + header_y_front) / 2;            // = 25.73
tft_left_off = -22.2;   // [P] module PCB left edge  - socket centre
tft_rear_off = 4.25;    // [P] module PCB rear edge - socket centre
// With the values above the module's left edge lands at x ≈ 0.2 and its rear edge at
// y ≈ 30.0: flush with the board, exactly as in Adafruit's "mounted on a Pi Zero" photo.

// Display: 1.14" 240×135 → active area ≈ 24.4 × 13.7 mm (240 × 0.1016 by 135 × 0.1016) [E]
tft_lcd_w = 24.4;
tft_lcd_h = 13.7;
tft_lcd_dx = -1.63;     // [P] active-area centre - socket centre (x)
tft_lcd_dy = 10.80;     // [P] active-area centre - socket centre (y, toward the front)
tft_glass_t = 1.6;      // [E] display glass/panel above the PCB
tft_btn_h = 2.0;        // [E] tactile-button actuator above the PCB

// The two tactile buttons sit on the module's board, in a vertical pair at its left edge
// (silkscreened "23" and "24"), so they need press-through holes of their own.
tft_btn_d = 3.0;        // [P] actuator diameter
tft_btn_dx = -19.3;     // [P] button centre - socket centre (x)
tft_btn_dy = [6.15, 14.90];  // [P] the two button centres (y, toward the front)

tft_btn_hole_d = 4.6;   // [E] press-through hole (bigger than the 3.0 mm actuator)
window_margin = 1.0;    // [E] lid window = active area + this on every side

// ---------------------------------------------------------------- light sensor (Adafruit OPT4048)

// The breakout is 25.4 × 17.78 mm (1.00 × 0.70 in) with a 2.54 mm corner radius and four
// Φ2.5 plated mounting holes 2.54 mm in from every edge — Adafruit's published PCB files.
opt_w = 25.4;            // [D] board, the 25.4 mm edge runs along the case's x
opt_d = 17.78;           // [D] board, the 17.78 mm edge runs along the case's y
opt_t = 1.6;             // [E] PCB thickness
opt_hole_inset = 2.54;   // [D] mounting-hole centre, from either edge
opt_hole_pitch_x = 20.32;    // [D] mounting-hole spacing along x (25.4 - 2 × 2.54)
opt_hole_pitch_y = 12.70;    // [D] mounting-hole spacing along y (17.78 - 2 × 2.54)
opt_hole_d = 2.5;        // [D] Φ2.5 plated mounting holes

// --- THE APERTURE IS AN ESTIMATE, NOT A MEASUREMENT -------------------------------------
// Adafruit's PCB files put the sensor *package* at (12.70, 8.89) — the centre of the
// 25.4 × 17.78 board — and their top-down photo agrees, so both defaults below are that
// centre. The light-sensitive spot *inside* the 2.2 × 1.2 mm package is not published in a
// form we could verify, so the real aperture can be 1–2 mm away from these numbers.
// **Measure it with calipers** — centre of the clear window, from the module's left edge and
// its front edge — and change these two values: the collar, the floor window and the layout
// drawing all follow them. Nothing here has been measured.
opt_ap_from_left = 12.70;    // [E] *** ESTIMATE *** aperture centre, from the module's left edge
opt_ap_from_front = 8.89;    // [E] *** ESTIMATE *** aperture centre, from the module's front edge
opt_pkg_h = 1.0;         // [E] how far the sensor package hangs below the module's PCB

// Mounting orientation: the module goes in **sensor side down** (package and window facing
// the floor), its 25.4 mm edge along the case's x, and its 6-pin-header edge (VIN/SCL/INT)
// towards the case's REAR wall. Turning the board over mirrors its own y axis, so the
// "front edge" in the parameter names above is the module's y = 17.78 edge — the "OPT4048
// XYZ Color" silk edge in Adafruit's photo. Four printed posts enter the board's own Φ2.5
// mounting holes, which fixes its position (and therefore the aperture's).

post_d = 3.6;            // [E] post shoulder, inside the Φ4.0 plated pad ring (the nearest
                         //     part on the module's underside is the LED, 2.2 mm from a hole)
post_spigot_d = 2.2;     // [E] spigot that enters the Φ2.5 hole (0.3 mm of play)
post_spigot_h = 1.2;     // [E] spigot length (the PCB is opt_t thick)

// The light guide (the user's part) and the printed collar around it. The collar is exactly
// as tall as the guide and no taller: on this board the pull-up pack (2.9 mm from the
// aperture), the bypass caps (1.7 / 2.4 / 4.1 mm) and the regulator (2.4 mm) all sit inside
// the collar's 4.5 mm radius, so nothing may rise as far as the module's underside there.
light_window_d = 5.4;    // [E] optical opening in the floor (the brief asks Φ5–6)
light_guide_id = 5.0;    // [E] the tube's bore (from the brief)
light_guide_od = 6.0;    // [E] the tube's outer diameter — set this to your real tube
light_guide_len = 10.0;  // [E] the tube's length, 8–15 mm in the brief. **This sets the case's
                         //     height 1:1** — the module deck, the standoffs and the lid all
                         //     follow it (see the check output's stack-up)
sleeve_od = 9.0;         // [E] the printed collar's outer diameter
sleeve_bore = light_guide_od + 0.4;
guide_to_pcb = 1.8;      // [E] the guide's top → the module's PCB underside: it has to clear
                         //     the tallest part on the module's underside near the aperture
                         //     (the SOT23-5 regulator, ≈1.45 mm) with a little room to spare

// ---------------------------------------------------------------- the Qwiic cable's two ends
// One STEMMA QT (JST SH 4-pin) cable, one end into the display's socket *above* the board and
// one end into the sensor's socket *below* it. Both shells are the same part; the numbers are
// read off the two published Eagle .brd files (see the header note).
qt_body_w = 4.25;        // [D] shell, across the cable's axis
qt_body_l = 6.10;        // [D] shell, along the cable's axis (including the solder tabs)
qt_h = 3.00;             // [E] shell height above/below its PCB (the mated plug is about this)
qt_plug = 3.40;          // [E] how far the mated plug sticks out of the shell's mouth

// The display's socket (Mini PiTFT .brd, CONN1, mirrored onto the module's underside): its
// mouth faces the module's FRONT edge, 0.5 mm in from it — so the cable leaves the display
// heading for the case's front wall, which is what makes the short route below possible.
tft_qt_x = 6.50;         // [D] shell's left face, from the module's left edge
tft_qt_w = 6.10;         // [D] shell width along the module's x (= the cable's axis)
tft_qt_y = 0.50;         // [D] shell's mouth, from the module's front edge
tft_qt_d = 4.25;         // [D] shell depth along the module's y

// The sensor's two sockets (OPT4048 .brd, CONN1 on the left and CONN2 on the right, both with
// their mouths facing outwards — the cable takes the left one, the one that faces the case's
// left wall and therefore the channel). In the module's own frame, before it is turned over:
opt_qt_x = 1.09;         // [D] left shell's outer face (its mouth), from the module's left edge
opt_qt_y0 = 5.79;        // [D] left shell's near edge, from the module's front edge
opt_qt_y1 = 11.89;       // [D] left shell's far edge
// The module is turned over in the case, so its own y is mirrored: these two are the shell's
// edges as they end up in the case's frame.
opt_qt_yA = opt_d - opt_qt_y1;   // = 5.89
opt_qt_yB = opt_d - opt_qt_y0;   // = 11.99

// ---------------------------------------------------------------- case

wall = 2.0;             // wall thickness
clearance = 0.4;        // clearance between the board and the case
floor_t = 3.0;          // [E] base plate (no longer a thread depth: the screws bite into the
                        //     standoffs now, not into the floor)

// --- the raised board (v0.5) -------------------------------------------------------------
// The board stands on four printed standoffs so the sensor module fits underneath it. The
// value below is the *minimum* that clears the module with `module_gap` of air to spare:
//   floor_t + light_guide_len + guide_to_pcb + opt_t + module_gap - floor_t
//   = 3.0 + 10.0 + 1.8 + 1.6 + 0.6 - 3.0 = 14.0
standoff_h = 14.0;      // [E] printed standoff height, above the floor's top face
standoff_d = 6.0;       // [E] standoff shoulder, inside the Φ4.0 pad ring around the board's
                        //     Φ3.00 mounting holes (the lid screws pass through those holes)
module_gap = 0.6;       // [E] air between the module's top face and the board's underside
screw_len = 25.0;       // M2.5 × 25 for all three screws (see README: 18 mm no longer
                        //     reaches — the board is 17 mm up)
screw_pilot_depth = 11.0;   // blind pilot in each standoff (leaves 3 mm of solid plastic)

// --- the front cable channel (v0.5) ------------------------------------------------------
// The display's socket is on the module's underside and points at the case's front wall, but
// getting from there to the sensor *under* the board means passing the board's edge — and the
// board sits only `clearance` from the wall, so at 0.4 mm there is no route at all. The
// interior is therefore `cable_channel` deeper than the board needs: that leaves a
// (cable_channel + clearance) = 2.8 mm slot along the front wall, interrupted only where the
// HDMI and USB-C cut-outs tunnel across it to reach the board's edge. The cable drops through
// the slot at `cable_drop_x` — left of the HDMI cut-out, which starts at board_x0 + hdmi_x.
cable_channel = 2.4;    // [E] extra interior depth in front of the board
cable_drop_x = 7.5;     // [E] case x where the cable drops through the channel
cable_w = 2.6;          // [E] Qwiic ribbon width (the shell itself is 4.25 wide)
cable_budget = 50.0;    // [E] the Qwiic-Qwiic cable in the BOM (Switch Science 6896)

// --- lid and screws
screw_clear = 2.8;      // M2.5 clearance hole (lid)
screw_pilot = 2.05;     // M2.5 self-tapping pilot (standoffs)
lid_gap = 0.8;          // air above the tallest thing on the module stack
lid_lip = 1.2;          // how far the lid overhangs the tray's outer face
skirt_h = 1.2;          // how far the lid's skirt hangs down outside the tray
skirt_gap = 0.2;        // skirt-to-tray clearance

// ---------------------------------------------------------------- derived layout

// The board's corner in the case (the tray's outer corner is the case's origin)
board_x0 = wall + clearance;                     // = 2.4
board_y0 = wall + clearance + cable_channel;     // = 4.8
board_z = floor_t + standoff_h;                  // = 17.0, the board's underside

inner_w = board_w + clearance * 2;                       // = 65.8
inner_d = board_d + clearance * 2 + cable_channel;       // = 33.2
outer_w = inner_w + wall * 2;                            // = 69.8
outer_d = inner_d + wall * 2;                            // = 37.2

// The sensor module sits **centred on the board**, which puts the (estimated) aperture at
// x = 32.5, y = 15.0 in board coordinates — i.e. under the middle of the raised board and,
// once the case's 4.8 mm front channel is added, within 0.1 mm of the centre of the case's
// footprint. That is where you want it when the device is laid on a phone.
sensor_cx = board_w / 2;
sensor_cy = board_d / 2;
sensor_x0 = sensor_cx - opt_w / 2;
sensor_y0 = sensor_cy - opt_d / 2;
sensor_holes = [[sensor_x0 + opt_hole_inset, sensor_y0 + opt_hole_inset],
                [sensor_x0 + opt_hole_inset + opt_hole_pitch_x, sensor_y0 + opt_hole_inset],
                [sensor_x0 + opt_hole_inset, sensor_y0 + opt_hole_inset + opt_hole_pitch_y],
                [sensor_x0 + opt_hole_inset + opt_hole_pitch_x,
                 sensor_y0 + opt_hole_inset + opt_hole_pitch_y]];

light_cx = sensor_x0 + opt_ap_from_left;     // the ***ESTIMATED*** aperture (see above)
light_cy = sensor_y0 + opt_ap_from_front;

// ---------------------------------------------------------------- screw positions
// Nothing may stand inside the board's footprint above the floor except the four standoffs the
// board itself drops onto: each one sits under one of the board's own Φ3.00 mounting holes, and
// the lid screws pass through those holes into a blind pilot in the standoff. The board's
// rear-left corner gets a standoff but **no screw** — the Mini PiTFT's board is over it, so a
// screw could not be inserted (it still has to carry that corner).
screw_board = [[hole_inset, hole_inset],
               [board_w - hole_inset, hole_inset],
               [board_w - hole_inset, board_d - hole_inset]];
standoffs = concat(screw_board, [[hole_inset, board_d - hole_inset]]);

// ---------------------------------------------------------------- derived heights

opt_deck_z = floor_t + light_guide_len + guide_to_pcb;    // = 14.8 module PCB underside
opt_top_z = opt_deck_z + opt_t;                           // = 16.4 module PCB top face
collar_top = floor_t + light_guide_len;                   // = 13.0 top of the printed collar
// The guide's top is guide_to_pcb below the module's PCB, i.e. guide_to_pcb - opt_pkg_h
// (0.8 mm) below the estimated window plane: the sensor package hangs into that gap, and the
// collar around the guide stops at the guide's top (see the note with the sensor parameters).

board_top_z = board_z + board_t;                          // = 18.6 board top face
tft_pcb_z = board_top_z + header_h;                       // = 27.1 module PCB underside
tft_pcb_top = tft_pcb_z + tft_t;                          // = 28.7 module PCB top
deck_z = tft_pcb_top + max(tft_glass_t, tft_btn_h) + lid_gap;   // = 31.5 lid underside
inner_h = deck_z - floor_t;                               // = 28.5 interior height

// ---------------------------------------------------------------- derived layout (board coords)

tft_x0 = tft_sock_cx + tft_left_off;
tft_x1 = tft_x0 + tft_w;
tft_y1 = tft_sock_cy + tft_rear_off;
tft_y0 = tft_y1 - tft_d;

lcd_x = tft_sock_cx + tft_lcd_dx;         // active-area centre
lcd_y = tft_sock_cy - tft_lcd_dy;
win_w = tft_lcd_w + window_margin * 2;    // lid window
win_h = tft_lcd_h + window_margin * 2;
win_x0 = lcd_x - win_w / 2;
win_x1 = lcd_x + win_w / 2;
win_y0 = lcd_y - win_h / 2;
win_y1 = lcd_y + win_h / 2;

btn_xy = [for (dy = tft_btn_dy) [tft_sock_cx + tft_btn_dx, tft_sock_cy - dy]];
btn_x1 = btn_xy[0][0] + tft_btn_hole_d / 2;      // rightmost extent of a button hole
btn_x0 = btn_xy[0][0] - tft_btn_hole_d / 2;
win_button_gap = win_x0 - btn_x1;                // material between window and buttons

// ---------------------------------------------------------------- the Qwiic cable's route
// Four waypoints, in case coordinates: out of the display's plug, across to the channel, down
// the channel to the sensor's level, then to the sensor's plug. The channel's mid-depth is
// wall + (clearance + cable_channel)/2.
qt_chan_y = wall + (clearance + cable_channel) / 2;       // = 3.4
qt_z_disp = tft_pcb_z - qt_h / 2;                         // = 25.6 plug centre, above the board
qt_z_sens = opt_deck_z - qt_h / 2;                        // = 13.3 plug centre, below it
cable_pts = [
    [board_x0 + tft_x0 + tft_qt_x + tft_qt_w / 2,         // out of the display's socket
     board_y0 + tft_y0 + tft_qt_y - qt_plug, qt_z_disp],
    [cable_drop_x, qt_chan_y, qt_z_disp],                 // into the channel
    [cable_drop_x, qt_chan_y, qt_z_sens],                 // down past the board's edge
    [board_x0 + sensor_x0 + opt_qt_x - qt_plug,           // into the sensor's socket
     board_y0 + sensor_y0 + (opt_qt_yA + opt_qt_yB) / 2, qt_z_sens]];
cable_segs = [for (i = [0 : len(cable_pts) - 2]) norm(cable_pts[i + 1] - cable_pts[i])];
cable_len = cable_segs[0] + cable_segs[1] + cable_segs[2];

$fn = 48;

// ---------------------------------------------------------------- self-check
// Prints the stack-up, the collision checks, the window/button/aperture numbers and the Qwiic
// cable's route, and fails the render if any of them stop fitting. -D 'part="check"' also
// draws the layout plan (see the bottom of this file).

echo(str("zhww-case: display window x ", win_x0, "..", win_x1,
         "  y ", win_y0, "..", win_y1, "  (", win_w, " x ", win_h, " mm)"));
echo(str("zhww-case: button holes Φ", tft_btn_hole_d, " at ",
         btn_xy[0], " and ", btn_xy[1], "  (x ", btn_x0, "..", btn_x1, ")"));
echo(str("zhww-case: window-to-button gap = ", win_button_gap, " mm",
         win_button_gap > 1.0 ? "  PASS" : "  FAIL (needs > 1.0 mm)"));

echo(str("zhww-case: stack-up [mm above the case's outside bottom]"));
echo(str("zhww-case:   floor 0..", floor_t,
         " | board standoffs ", floor_t, "..", board_z, " (", standoff_h, " printed)"));
echo(str("zhww-case:   board ", board_z, "..", board_top_z,
         " | header ", board_top_z, "..", tft_pcb_z,
         " | Mini PiTFT ", tft_pcb_z, "..", tft_pcb_top,
         " | glass/buttons to ", tft_pcb_top + max(tft_glass_t, tft_btn_h),
         " | lid underside ", deck_z, " | case top ", deck_z + wall));
echo(str("zhww-case:   sensor: light guide ", floor_t, "..", collar_top,
         " (collar stops there too) | module PCB ", opt_deck_z, "..", opt_top_z,
         " | its Qwiic shell hangs ", opt_deck_z - qt_h, "..", opt_deck_z,
         " | board underside ", board_z));
echo(str("zhww-case:   case ", outer_w, " x ", outer_d, " x ", deck_z + wall,
         " mm outside (board ", board_w, " x ", board_d,
         " + ", clearance, " clearance + ", wall, " walls + ", cable_channel,
         " front channel)"));

echo(str("zhww-case: check board vs sensor module: ", board_z, " - ", opt_top_z, " = ",
         board_z - opt_top_z, " mm", board_z > opt_top_z ? "  PASS" : "  FAIL"));
echo(str("zhww-case: check board vs light-guide collar: ", board_z, " - ", collar_top, " = ",
         board_z - collar_top, " mm", board_z > collar_top ? "  PASS" : "  FAIL"));
echo(str("zhww-case: check board vs sensor-post spigots: ", board_z, " - ",
         opt_deck_z + post_spigot_h, " = ", board_z - (opt_deck_z + post_spigot_h), " mm",
         board_z > opt_deck_z + post_spigot_h ? "  PASS" : "  FAIL"));
echo(str("zhww-case: check Qwiic plug under the module: ", opt_deck_z - qt_h, " - ", floor_t,
         " = ", opt_deck_z - qt_h - floor_t, " mm of cable room above the floor",
         opt_deck_z - qt_h - floor_t > 2.0 ? "  PASS" : "  FAIL"));

echo(str("zhww-case: sensor module ", opt_w, " x ", opt_d, " mm under the board at board x ",
         sensor_x0, "..", sensor_x0 + opt_w, "  y ", sensor_y0, "..", sensor_y0 + opt_d,
         "  (board is 0..", board_w, " x 0..", board_d,
         "; ", sensor_x0, " mm and ", board_d - (sensor_y0 + opt_d), " mm to its edges)"));
echo(str("zhww-case: aperture *** ESTIMATE, NOT MEASURED *** ",
         opt_ap_from_left, " mm from the module's left edge + ", opt_ap_from_front,
         " mm from its front edge → case x ", board_x0 + light_cx, " y ", board_y0 + light_cy,
         " of ", outer_w, " x ", outer_d,
         "  (from the other two edges: ", opt_w - opt_ap_from_left, " + ",
         opt_d - opt_ap_from_front, " mm)"));
echo(str("zhww-case: light guide's mouth is ", guide_to_pcb - opt_pkg_h,
         " mm below the estimated sensor window plane  (guide_to_pcb ", guide_to_pcb,
         " - opt_pkg_h ", opt_pkg_h, ")"));

echo(str("zhww-case: Qwiic cable: channel ", clearance + cable_channel, " mm wide at case x ",
         cable_drop_x, ", route ", cable_len, " mm (display plug → channel → sensor plug) of a ",
         cable_budget, " mm cable → ", cable_budget - cable_len, " mm spare",
         cable_len < cable_budget - 5.0 ? "  PASS" : "  FAIL"));

assert(win_button_gap > 1.0, "display window intersects the button cut-outs");
assert(win_x0 > tft_x0 && win_x1 < tft_x1 && win_y0 > tft_y0 && win_y1 < tft_y1,
       "display window falls outside the Mini PiTFT board");
assert(btn_x0 > tft_x0, "button hole falls outside the Mini PiTFT board");
assert(opt_hole_inset * 2 + opt_hole_pitch_x - opt_w < 0.001 &&
       opt_hole_inset * 2 + opt_hole_pitch_y - opt_d < 0.001,
       "the mounting holes do not match the module's board outline");
assert(opt_ap_from_left > 0 && opt_ap_from_left < opt_w &&
       opt_ap_from_front > 0 && opt_ap_from_front < opt_d,
       "the estimated aperture falls off the module's board");
assert(light_window_d < sleeve_bore, "the floor's light window is wider than the collar's bore");

// The raised board must not collide with the sensor stack underneath it (v0.5's point), and the
// module has to be fully under the board, clear of the board's standoffs.
assert(board_z > opt_top_z, "the raised board collides with the OPT4048 module underneath it");
assert(board_z > collar_top, "the raised board collides with the light-guide collar");
assert(board_z > opt_deck_z + post_spigot_h, "the sensor posts reach the raised board");
assert(opt_deck_z - qt_h > floor_t + 2.0,
       "no room under the sensor module for the Qwiic plug and its cable");
assert(sensor_x0 > 0 && sensor_x0 + opt_w < board_w &&
       sensor_y0 > 0 && sensor_y0 + opt_d < board_d,
       "the sensor module is not fully under the raised board");
assert(light_cx - sleeve_od / 2 > 0 && light_cx + sleeve_od / 2 < board_w &&
       light_cy - sleeve_od / 2 > 0 && light_cy + sleeve_od / 2 < board_d,
       "the light-guide collar falls outside the raised board (check the aperture estimate)");
assert(min([for (p = sensor_holes) (p[0] - light_cx) * (p[0] - light_cx)
                                + (p[1] - light_cy) * (p[1] - light_cy)])
       > pow(sleeve_od / 2 + post_d / 2, 2),
       "the light-guide collar reaches one of the module posts");
assert(min([for (h = sensor_holes) min([for (s = standoffs)
           (h[0] - s[0]) * (h[0] - s[0]) + (h[1] - s[1]) * (h[1] - s[1])])])
       > pow(post_d / 2 + standoff_d / 2, 2),
       "a sensor post reaches a board standoff");
assert(min([for (s = standoffs) (s[0] - light_cx) * (s[0] - light_cx)
                              + (s[1] - light_cy) * (s[1] - light_cy)])
       > pow(standoff_d / 2 + sleeve_od / 2, 2),
       "the light-guide collar reaches a board standoff");

// ... and the Qwiic cable has to have somewhere to go. The drop point must sit inside the
// channel and clear of both the wall and the HDMI cut-out (the three front cut-outs are the
// only places the channel is interrupted).
assert(cable_drop_x - cable_w / 2 > wall + 0.2 &&
       cable_drop_x + cable_w / 2 < board_x0 + hdmi_x - 0.2,
       "the Qwiic cable's drop point is not clear in the front channel");
assert(cable_len < cable_budget - 5.0,
       "the Qwiic cable's route is longer than the 50 mm cable leaves room for");

// ---------------------------------------------------------------- helpers

module rounded_box(w, d, h, r = 2) {
    hull() {
        for (x = [r, w - r], y = [r, d - r])
            translate([x, y, 0]) cylinder(r = r, h = h);
    }
}

// A cylinder from p to q — used for the Qwiic cable's drawn route.
module seg(p, q, d) {
    v = q - p;
    translate(p) rotate([0, atan2(sqrt(v[0] * v[0] + v[1] * v[1]), v[2]), atan2(v[1], v[0])])
        cylinder(d = d, h = norm(v));
}

// The four standoffs the raised board rests on, each under one of the board's own Φ3.00
// mounting holes. They are printed *after* the shell is hollowed out (v0.4's fix: cutting the
// cavity last took the standoffs, the posts and the collar with it).
module board_standoffs() {
    for (p = standoffs)
        translate([board_x0 + p[0], board_y0 + p[1], floor_t])
            cylinder(d = standoff_d, h = standoff_h);
}

// The four posts the OPT4048 module rests on: a shoulder under each plated pad ring and a
// spigot that enters the board's own Φ2.5 mounting hole. Using the module's own holes to
// locate it is what keeps the aperture over the collar — and the spigots stop 1.0 mm short of
// the raised board above them.
module sensor_posts() {
    for (p = sensor_holes) {
        translate([board_x0 + p[0], board_y0 + p[1], floor_t])
            cylinder(d = post_d, h = opt_deck_z - floor_t);
        translate([board_x0 + p[0], board_y0 + p[1], opt_deck_z])
            cylinder(d = post_spigot_d, h = post_spigot_h);
    }
}

// Three blind screw pilots, one in each of the three standoffs that carries a lid screw.
module screw_pilots() {
    for (p = screw_board)
        translate([board_x0 + p[0], board_y0 + p[1], board_z - screw_pilot_depth])
            cylinder(d = screw_pilot, h = screw_pilot_depth + 1);
}

// Printed collar around the user's light guide tube: a bore from the floor up to the top of
// the guide, closed at the bottom by the Φ5.4 optical opening in the floor. It stops at the
// guide's top rather than at the module because the module's underside parts sit within
// 4.5 mm of the aperture — see the note with the sensor parameters.
module light_sleeve() {
    translate([board_x0 + light_cx, board_y0 + light_cy, floor_t])
        difference() {
            cylinder(d = sleeve_od, h = light_guide_len);
            translate([0, 0, -1]) cylinder(d = sleeve_bore, h = light_guide_len + 2);
        }
}

// The Qwiic cable's route, as four round segments (a drawing aid, not a printed part): out of
// the display's socket, across to the channel, down past the board's edge, and into the
// sensor's socket. `part="section"` draws it whole so the route stays readable.
module qwiic_cable() {
    color("White")
        for (i = [0 : len(cable_pts) - 2])
            seg(cable_pts[i], cable_pts[i + 1], cable_w);
}

// ---------------------------------------------------------------- parts

module tray() {
    difference() {
        union() {
            // The shell is hollowed out **first**, and the features that stand inside the
            // cavity are added afterwards. Cutting the cavity at the end (as v0.3 did) takes
            // the collar, the posts and the standoffs with it: they are all inside the
            // cavity's own volume, so nothing of them survives.
            difference() {
                rounded_box(outer_w, outer_d, deck_z, corner_r);
                translate([wall, wall, floor_t])
                    rounded_box(inner_w, inner_d, deck_z, corner_r / 2);
            }
            board_standoffs();
            sensor_posts();
            light_sleeve();
        }

        // Front long edge: mini HDMI / USB-C x2. Each cut-out tunnels across the 2.8 mm cable
        // channel to reach the connector on the board's front edge, 0.6 mm past it.
        translate([board_x0 + hdmi_x, -1, board_z + 2.5])
            cube([hdmi_w, board_y0 + 1.6, hdmi_h]);
        translate([board_x0 + usb_c1_x, -1, board_z + 2.5])
            cube([usb_c_w, board_y0 + 1.6, usb_c_h]);
        translate([board_x0 + usb_c2_x, -1, board_z + 2.5])
            cube([usb_c_w, board_y0 + 1.6, usb_c_h]);

        // Left short edge: microSD
        translate([-1, board_y0 + sd_y0, board_z + 1.5])
            cube([wall + 2, sd_len, sd_h]);

        // Floor: the light window the sensor looks down through
        translate([board_x0 + light_cx, board_y0 + light_cy, -1])
            cylinder(d = light_window_d, h = floor_t + 2);

        // The three blind screw pilots
        screw_pilots();
    }
}

module lid() {
    difference() {
        union() {
            // Top plate, overhanging the tray by lid_lip all round (corner radius grows
            // with the overhang so the lid stays concentric with the tray)
            translate([-lid_lip, -lid_lip, deck_z])
                rounded_box(outer_w + lid_lip * 2, outer_d + lid_lip * 2, wall,
                            corner_r + lid_lip);
            // Skirt that drops over the tray's outside (locates the lid, blocks light)
            translate([-lid_lip, -lid_lip, deck_z - skirt_h])
                difference() {
                    rounded_box(outer_w + lid_lip * 2, outer_d + lid_lip * 2, skirt_h,
                                corner_r + lid_lip);
                    translate([lid_lip + skirt_gap, lid_lip + skirt_gap, -1])
                        rounded_box(outer_w - skirt_gap * 2, outer_d - skirt_gap * 2,
                                    skirt_h + 2, corner_r);
                }
            // No pad holds the sensor module any more: it now sits *under* the board, and the
            // 0.6 mm gap between its top face and the board's underside keeps it on its posts
            // (v0.4's lid pad had nothing left to press on).
        }

        // Display window (the module's board is 38.6 × 24.5; the window must stay smaller
        // than that because the two buttons are on the same face — see README)
        translate([board_x0 + win_x0, board_y0 + win_y0, deck_z - 1])
            cube([win_w, win_h, wall + 3]);

        // The module's two tactile buttons (a vertical pair at its left edge)
        for (p = btn_xy)
            translate([board_x0 + p[0], board_y0 + p[1], deck_z - 1])
                cylinder(d = tft_btn_hole_d, h = wall + 3);

        // Screw holes: three, straight down the board's own mounting holes into the standoffs
        for (p = screw_board)
            translate([board_x0 + p[0], board_y0 + p[1], deck_z - skirt_h - 1])
                cylinder(d = screw_clear, h = wall + skirt_h + 3);
    }
}

// ---------------------------------------------------------------- internals (cross-section check)

// The board, the header, the Mini PiTFT and the light sensor at their **actual heights**, so
// the cross-section shows the height relationships rather than a flat projection.
module internals() {
    // Board (65 × 30 × 1.6), raised on its standoffs
    color("SteelBlue")
        translate([board_x0, board_y0, board_z])
            cube([board_w, board_d, board_t]);
    // 40-pin header (rear long edge): 2 rows × 20 columns, 2.54 mm pitch
    color("Green")
        translate([board_x0 + header_x0 - header_pitch / 2,
                   board_y0 + header_y_front - header_pitch / 2,
                   board_top_z])
            cube([(header_cols - 1) * header_pitch + header_pitch,
                  header_pitch * 2, header_h]);
    // Mini PiTFT: 2×12 socket under the board, board, display glass, two buttons
    color("DimGray")
        translate([board_x0 + tft_sock_cx - (tft_cols - 1) * header_pitch / 2 - 1.27,
                   board_y0 + tft_sock_cy - 1.27,
                   tft_pcb_z - 5.0])
            cube([(tft_cols - 1) * header_pitch + 2.54, 2.54, 5.0]);
    color("Orange")
        translate([board_x0 + tft_x0, board_y0 + tft_y0, tft_pcb_z])
            cube([tft_w, tft_d, tft_t]);
    color("Black")
        translate([board_x0 + lcd_x - tft_lcd_w / 2,
                   board_y0 + lcd_y - tft_lcd_h / 2, tft_pcb_top])
            cube([tft_lcd_w, tft_lcd_h, tft_glass_t]);
    color("Crimson")
        for (p = btn_xy)
            translate([board_x0 + p[0], board_y0 + p[1], tft_pcb_top])
                cylinder(d = tft_btn_d, h = tft_btn_h);
    // The display's STEMMA QT socket on the module's underside (mouth toward the front edge)
    color("White")
        translate([board_x0 + tft_x0 + tft_qt_x,
                   board_y0 + tft_y0 + tft_qt_y, tft_pcb_z - qt_h])
            cube([tft_qt_w, tft_qt_d, qt_h]);
    // Adafruit OPT4048 breakout on its posts, sensor side down, **under** the board
    color("Purple")
        translate([board_x0 + sensor_x0, board_y0 + sensor_y0, opt_deck_z])
            cube([opt_w, opt_d, opt_t]);
    // its package, hanging below the board at the (estimated) aperture
    color("Black")
        translate([board_x0 + light_cx - 1.1, board_y0 + light_cy - 0.6,
                   opt_deck_z - opt_pkg_h])
            cube([2.2, 1.2, opt_pkg_h]);
    // its two STEMMA QT sockets (the left one takes the cable)
    color("White") {
        translate([board_x0 + sensor_x0 + opt_qt_x,
                   board_y0 + sensor_y0 + opt_qt_yA, opt_deck_z - qt_h])
            cube([qt_body_w, opt_qt_yB - opt_qt_yA, qt_h]);
        translate([board_x0 + sensor_x0 + opt_w - opt_qt_x - qt_body_w,
                   board_y0 + sensor_y0 + opt_qt_yA, opt_deck_z - qt_h])
            cube([qt_body_w, opt_qt_yB - opt_qt_yA, qt_h]);
    }
    // Light guide tube (the user's part) inside the printed collar
    color("Gold")
        translate([board_x0 + light_cx, board_y0 + light_cy, floor_t])
            difference() {
                cylinder(d = light_guide_od, h = light_guide_len);
                translate([0, 0, -1]) cylinder(d = light_guide_id, h = light_guide_len + 2);
            };
    // microSD card (inserted from the left; passes under the Mini PiTFT)
    color("Silver")
        translate([-1, board_y0 + sd_y0 + 2, board_top_z + 0.2])
            cube([12, 11, 0.8]);
}

// ---------------------------------------------------------------- layout check (2D plan)

// Plan view. Left panel: the raised board with the sensor module underneath it — that is the
// drawing to lay the real OPT4048 on, because it shows where the collar and the floor window
// land relative to the module's own mounting holes. Right panel: the Mini PiTFT in its own
// coordinates, with the lid's window and button holes drawn on top of it and the Qwiic socket
// marked, so the display's end of the cable can be checked too.
//
// The drawing is extruded a fraction of a millimetre (each layer at its own height) so
// that `--render` treats it as a 3D object: that keeps the colours *and* prints a
// "Status:" line, neither of which happens when OpenSCAD CGAL-renders a flat 2D model.
module flat(h) { linear_extrude(height = h) children(); }

module layout_check() {
    // --- left panel: the board, and everything that lives under it (board coordinates) ---
    // the front cable channel (light blue), with the drop point (red)
    color("LightBlue") flat(0.15)
        translate([-clearance, -(clearance + cable_channel)])
            square([board_w + clearance * 2, clearance + cable_channel]);
    color("Red") flat(0.2)
        translate([cable_drop_x - board_x0, -(clearance + cable_channel) / 2])
            circle(d = 1.2);
    // the board (blue) with its four Φ3.00 mounting holes
    color("SteelBlue") flat(0.25) difference() {
        offset(r = corner_r) offset(delta = -corner_r) square([board_w, board_d]);
        for (p = standoffs) translate([p[0], p[1]]) circle(d = hole_d);
    }
    // connectors on the front long edge (HDMI / USB-C ×2) and the 40-pin header
    color("Gray") flat(0.3) {
        translate([hdmi_x, -4]) square([hdmi_w, 4]);
        translate([usb_c1_x, -4]) square([usb_c_w, 4]);
        translate([usb_c2_x, -4]) square([usb_c_w, 4]);
    }
    color("Green") flat(0.3)
        translate([header_x0 - header_pitch / 2, header_y_front - header_pitch / 2])
            square([(header_cols - 1) * header_pitch + header_pitch, header_pitch * 2]);
    // microSD on the left short edge (the BAT connector is not cut out)
    color("DimGray") flat(0.3) translate([-4, sd_y0]) square([4, sd_len]);
    // the four board standoffs, drawn as rings so the board's own Φ3.00 holes stay visible
    color("DimGray") flat(0.35)
        for (p = standoffs) translate([p[0], p[1]])
            difference() {
                circle(d = standoff_d);
                circle(d = hole_d);
            }
    // the OPT4048 module **under** the board: its board, its four mounting holes, its sockets
    color("Purple") flat(0.4) translate([sensor_x0, sensor_y0]) square([opt_w, opt_d]);
    color("White") flat(0.45)
        for (p = sensor_holes) translate([p[0], p[1]]) circle(d = opt_hole_d);
    color("Gainsboro") flat(0.5) {
        translate([sensor_x0 + opt_qt_x, sensor_y0 + opt_qt_yA])
            square([qt_body_w, opt_qt_yB - opt_qt_yA]);
        translate([sensor_x0 + opt_w - opt_qt_x - qt_body_w, sensor_y0 + opt_qt_yA])
            square([qt_body_w, opt_qt_yB - opt_qt_yA]);
    }
    // the collar (orange ring) and the floor window (gold dot), both from the estimated aperture
    color("DarkOrange") flat(0.55) translate([light_cx, light_cy]) circle(d = sleeve_od);
    color("Gold") flat(0.6) translate([light_cx, light_cy]) circle(d = light_window_d);

    // --- right panel: the Mini PiTFT (in the model's board coordinates minus the module's
    //     own corner, i.e. (0,0) is the module's front-left corner, +y toward its rear edge) ---
    translate([board_w + 14, 0]) {
        color("SteelBlue") flat(0.2) square([tft_w, tft_d]);
        // its 2x12 socket (pins 1–24), along the module's rear edge
        color("Green") flat(0.3)
            translate([tft_sock_cx - (tft_cols - 1) * header_pitch / 2 - header_pitch / 2
                       - tft_x0,
                       tft_sock_cy - header_pitch / 2 - tft_y0])
                square([(tft_cols - 1) * header_pitch + header_pitch, header_pitch]);
        // the lid window (yellow) with the display's active area (orange) inside it
        color("Yellow") flat(0.4)
            translate([win_x0 - tft_x0, win_y0 - tft_y0]) square([win_w, win_h]);
        color("DarkOrange") flat(0.5)
            translate([lcd_x - tft_lcd_w / 2 - tft_x0, lcd_y - tft_lcd_h / 2 - tft_y0])
                square([tft_lcd_w, tft_lcd_h]);
        // the two button holes
        color("Crimson") flat(0.6)
            for (p = btn_xy)
                translate([p[0] - tft_x0, p[1] - tft_y0]) circle(d = tft_btn_hole_d);
        // the STEMMA QT / Qwiic socket on the module's underside (grey), with the direction
        // its cable leaves in (red) — straight at the case's front wall
        color("Gainsboro") flat(0.65)
            translate([tft_qt_x, tft_qt_y]) square([tft_qt_w, tft_qt_d]);
        color("Red") flat(0.7) translate([tft_qt_x + tft_qt_w / 2 - 1.0, -6]) square([2.0, 6]);
    }
}

// ---------------------------------------------------------------- output

part = "all";   // "tray" / "lid" / "all" / "check" / "section" (switch with -D)

if (part == "all") {
    tray();
    translate([0, outer_d + lid_lip * 2 + 10, 0]) lid();
} else if (part == "tray") {
    tray();
} else if (part == "lid") {
    lid();
} else if (part == "check") {
    layout_check();
} else if (part == "section") {
    // Cut away the front half — the plane passes through the aperture, so the light window,
    // the collar and the sensor package all show up in the section face.
    difference() {
        union() {
            tray();
            internals();
            lid();
        }
        translate([-5, -5, -5])
            cube([outer_w + 10, board_y0 + light_cy, deck_z + wall + 10]);
    }
    // Drawn *after* the cut, on purpose: the cable's route is the one thing in here that
    // crosses the cut plane, and a section that deletes it would not answer the question.
    qwiic_cable();
}
