// zhww enclosure (OpenSCAD, parametric)
//
// Hardware: Waveshare RP2350-PiZero (65 × 30 mm) + **Adafruit Mini PiTFT 135x240
//           (product 4393)** on the 40-pin header + an **Adafruit OPT4048 breakout**
//           (25.4 × 17.78 mm) behind a short opaque light-guide tube. USB power only.
//
// The case is two parts: a tray (floor, sensor bay, light-guide sleeve) and a lid (display
// window, two button holes). The light window is in the tray's floor, so the device can be
// laid on a phone screen with the display still facing the user.
//
// **Coordinate convention** (unchanged from v0.2):
//   x = the board's long edge (0 = left = the microSD end, 65 = right)
//   y = the board's short edge (0 = front = the USB-C edge, 30 = rear = the 40-pin header edge)
//   z = height (0 = the board's underside)
//   The case's own origin is the tray's outer corner, so the board sits at
//   (wall + clearance, wall + clearance, floor_t) in case coordinates.
//
// ## Where the numbers come from (important)
//
// **Nothing has been measured with calipers yet.** Every parameter carries a tag:
//
//   [D] published dimension — an official drawing or the vendor's product page
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
//     mounting holes 2.54 mm in from every edge, the OPT4048 package in the middle of the
//     board, one STEMMA QT connector on each short edge — Adafruit's published PCB files
//     (adafruit/Adafruit-OPT4048-XYZ-Color-Sensor-PCB, the Eagle .brd) ................ [D]
//   - **Where the light-sensitive area sits on that board** — the *package* is in the
//     middle (the .brd says so and Adafruit's photo agrees), but the position of the
//     sensing spot inside the 2.2 × 1.2 mm package is not published in a form we could
//     verify. `opt_ap_from_left` / `opt_ap_from_front` are therefore ESTIMATES (±1–2 mm)
//     and are the first thing to measure on the real board .......................... [E]
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

// BAT connector on the right short edge. It is **no longer cut out**: the sensor bay now
// occupies that end of the case, so the connector sits inside the case. Power is USB only.
// The numbers are kept so a future LiPo version knows where it is.
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
// Adafruit's PCB files put the sensor *package* in the middle of the board, and their
// top-down photo agrees, so both defaults below are the board's centre (12.70, 8.89 of
// 25.4 × 17.78). The light-sensitive spot *inside* that 2.2 × 1.2 mm package is not
// published in a form we could verify, so the real aperture can be 1–2 mm away from these
// numbers. **Measure it with calipers** — centre of the clear window, from the module's left
// edge and its front edge — and change these two values: the collar, the floor window and
// the layout drawing all follow them. Nothing here has been measured.
opt_ap_from_left = 12.70;    // [E] *** ESTIMATE *** aperture centre, from the module's left edge
opt_ap_from_front = 8.89;    // [E] *** ESTIMATE *** aperture centre, from the module's front edge
opt_pkg_h = 1.0;         // [E] how far the sensor package hangs below the module's PCB

// The module goes in **sensor side down** (the package and its window face the floor), its
// 25.4 mm edge along the case's x, and its 6-pin-header edge (VIN/SCL/INT) towards the
// case's REAR wall: turning the board over mirrors its own y axis, so "front edge" above is
// the module's y = 17.78 edge — the "OPT4048 XYZ Color" silk edge in Adafruit's photo.
// Four printed posts enter the board's own mounting holes, which fixes its position (and
// therefore the aperture's) instead of leaving it to the eye.

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
light_guide_len = 10.0;  // [E] the tube's length, 8–15 mm in the brief
sleeve_od = 9.0;         // [E] the printed collar's outer diameter
sleeve_bore = light_guide_od + 0.4;
guide_to_pcb = 1.8;      // [E] the guide's top → the module's PCB underside: it has to clear
                         //     the tallest part on the module's underside near the aperture
                         //     (the SOT23-5 regulator, ≈1.45 mm) with a little room to spare

// ---------------------------------------------------------------- case

wall = 2.0;             // wall thickness
clearance = 0.4;        // clearance between the board and the case
floor_t = 3.0;          // base plate; also the thread depth for the three board screws
                        // (a 2 mm floor would be too thin: the lid sits 14.5 mm above it)
screw_clear = 2.8;      // M2.5 clearance hole (lid)
screw_pilot = 2.05;     // M2.5 self-tapping pilot (tray)
screw_len = 18.0;       // M2.5 x 18 for all five screws (see README)
screw_pilot_depth = 16.5;   // blind pilot in the sensor-bay bosses
floor_pilot_depth = 2.5;    // blind pilot in the floor under the board's holes
boss_d = 6.0;           // screw boss in the sensor bay
lid_gap = 0.8;          // air above the tallest thing on the module stack
lid_lip = 1.2;          // how far the lid overhangs the tray's outer face
skirt_h = 1.2;          // how far the lid's skirt hangs down outside the tray
skirt_gap = 0.2;        // skirt-to-tray clearance
screw_inset_bay = 3.5;  // bay screw bosses, from the bay's end wall
screw_bay_y = 2.2;      // bay screw bosses, from the front/rear walls

// Sensor bay: the interior is extended past the board's right edge so the OPT4048 module has
// somewhere to live, and two internal walls narrow that extension to a defined pocket — the
// case's interior is 30.8 mm deep because of the Pi board, and the module only needs 22.
bay_len = 30.0;         // [E] bay pocket, x: 25.4 (module) + 4.6 → 2.30 mm each side
bay_depth = 22.0;       // [E] bay pocket, y: 17.78 (module) + 4.22 → 2.11 mm each side
bay_x0 = board_w + clearance;
bay_x1 = bay_x0 + bay_len;

inner_w = board_w + clearance * 2 + bay_len;
inner_d = board_d + clearance * 2;
outer_w = inner_w + wall * 2;
outer_d = inner_d + wall * 2;

bay_y0 = board_d / 2 - bay_depth / 2;        // = 4.0, on the board's centreline
bay_wall_t = (inner_d - bay_depth) / 2;      // = 4.4: solid wall at the bay's front and rear

// The module sits in the middle of the pocket; its four mounting holes (and the posts that
// go into them) are derived from the board's own hole pattern.
sensor_cx = (bay_x0 + bay_x1) / 2;
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
// Nothing may stand inside the board's footprint above the floor: the board has to drop
// straight down into the tray. So the three lid screws at the board's corners pass
// **through the board's own Φ3.00 mounting holes** and thread into the 2 mm floor, and
// only the sensor bay (which has no board over it) carries real bosses.
screw_board = [[hole_inset, hole_inset],
               [board_w - hole_inset, hole_inset],
               [board_w - hole_inset, board_d - hole_inset]];
screw_bay = [[bay_x1 - screw_inset_bay, screw_bay_y],
             [bay_x1 - screw_inset_bay, board_d - screw_bay_y]];
screw_xy = concat(screw_board, screw_bay);


// ---------------------------------------------------------------- derived heights

tft_pcb_z = floor_t + board_t + header_h;                 // = 12.1 module PCB underside
tft_pcb_top = tft_pcb_z + tft_t;                          // = 13.7 module PCB top
deck_z = tft_pcb_top + max(tft_glass_t, tft_btn_h) + lid_gap;   // = 16.5 lid underside
inner_h = deck_z - floor_t;                               // interior height above the floor

sensor_deck_z = floor_t + light_guide_len + guide_to_pcb;  // = 14.8 module PCB underside
// The guide's top is guide_to_pcb below the module's PCB, i.e. guide_to_pcb - opt_pkg_h
// (0.8 mm) below the estimated window plane: the sensor package hangs into that gap, and the
// collar around the guide stops at the guide's top (see the note with the sensor parameters).

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

$fn = 48;

// ---------------------------------------------------------------- self-check
// Prints the numbers the display window, the button holes, the sensor bay and the aperture
// were placed with, and fails the render if any of them stop fitting. Run with -D 'part="check"'.

echo(str("zhww-case: display window x ", win_x0, "..", win_x1,
         "  y ", win_y0, "..", win_y1, "  (", win_w, " x ", win_h, " mm)"));
echo(str("zhww-case: button holes Φ", tft_btn_hole_d, " at ",
         btn_xy[0], " and ", btn_xy[1], "  (x ", btn_x0, "..", btn_x1, ")"));
echo(str("zhww-case: window-to-button gap = ", win_button_gap, " mm",
         win_button_gap > 1.0 ? "  PASS" : "  FAIL (needs > 1.0 mm)"));
echo(str("zhww-case: OPT4048 sensor bay ", bay_len, " x ", bay_depth,
         " mm internal (x × y); module ", opt_w, " x ", opt_d, " mm → gap ",
         bay_len - opt_w, " mm in x (", (bay_len - opt_w) / 2, " per side) and ",
         bay_depth - opt_d, " mm in y (", (bay_depth - opt_d) / 2, " per side)"));
echo(str("zhww-case: aperture *** ESTIMATE, NOT MEASURED *** ",
         opt_ap_from_left, " mm from the module's left edge + ", opt_ap_from_front,
         " mm from its front edge → case x ", light_cx, " y ", light_cy,
         "  (from the other two edges: ", opt_w - opt_ap_from_left, " + ",
         opt_d - opt_ap_from_front, " mm)"));
echo(str("zhww-case: light guide top is ", guide_to_pcb - opt_pkg_h,
         " mm below the estimated sensor window plane  (guide_to_pcb ", guide_to_pcb,
         " - opt_pkg_h ", opt_pkg_h, ")"));

assert(win_button_gap > 1.0, "display window intersects the button cut-outs");
assert(win_x0 > tft_x0 && win_x1 < tft_x1 && win_y0 > tft_y0 && win_y1 < tft_y1,
       "display window falls outside the Mini PiTFT board");
assert(btn_x0 > tft_x0, "button hole falls outside the Mini PiTFT board");
assert(bay_len - opt_w > 1.0 && bay_depth - opt_d > 1.0,
       "the OPT4048 module does not fit the sensor bay");
assert(opt_hole_inset * 2 + opt_hole_pitch_x - opt_w < 0.001 &&
       opt_hole_inset * 2 + opt_hole_pitch_y - opt_d < 0.001,
       "the mounting holes do not match the module's board outline");
assert(opt_ap_from_left > 0 && opt_ap_from_left < opt_w &&
       opt_ap_from_front > 0 && opt_ap_from_front < opt_d,
       "the estimated aperture falls off the module's board");
assert(light_cx - sleeve_od / 2 > bay_x0 && light_cx + sleeve_od / 2 < bay_x1 &&
       light_cy - sleeve_od / 2 > bay_y0 && light_cy + sleeve_od / 2 < bay_y0 + bay_depth,
       "the light-guide collar does not fit the sensor bay (check the aperture estimate)");
assert(min([for (p = sensor_holes) (p[0] - light_cx) * (p[0] - light_cx)
                                + (p[1] - light_cy) * (p[1] - light_cy)])
       > pow(sleeve_od / 2 + post_d / 2, 2),
       "the light-guide collar reaches one of the module posts");
assert(sensor_deck_z + opt_t + 0.2 < deck_z,
       "the sensor module reaches the lid: shorten the light guide");
assert(light_window_d < sleeve_bore, "the floor's light window is wider than the collar's bore");

// ---------------------------------------------------------------- helpers

module rounded_box(w, d, h, r = 2) {
    hull() {
        for (x = [r, w - r], y = [r, d - r])
            translate([x, y, 0]) cylinder(r = r, h = h);
    }
}

// Screw anchors. The three board screws have **no** boss: anything standing inside the
// board's footprint would stop the board from dropping into the tray, and the Mini PiTFT
// covers the rear-left corner anyway. They pass through the board's own Φ3.00 holes and
// bite into the 3 mm floor (blind pilot, so nothing shows on the underside). The sensor
// bay has no board over it, so its two screws get proper bosses — which stand inside the
// cavity and are therefore added *after* the tray has been hollowed out, not before.
module bay_bosses() {
    for (p = screw_bay)
        translate([wall + clearance + p[0], wall + clearance + p[1], 0])
            cylinder(d = boss_d, h = deck_z);
}

// The five blind screw pilots, subtracted last: three in the floor (under the board's own
// mounting holes) and two in the bay bosses. Without them the screws would have to bite into
// solid plastic.
module screw_pilots() {
    for (p = screw_board)
        translate([wall + clearance + p[0], wall + clearance + p[1],
                   floor_t - floor_pilot_depth])
            cylinder(d = screw_pilot, h = floor_pilot_depth + 1);
    for (p = screw_bay)
        translate([wall + clearance + p[0], wall + clearance + p[1],
                   deck_z - screw_pilot_depth])
            cylinder(d = screw_pilot, h = screw_pilot_depth + 1);
}

// The four posts the OPT4048 module rests on: a shoulder under each plated pad ring and a
// spigot that enters the board's own Φ2.5 mounting hole. Using the board's holes to locate
// it is what keeps the aperture over the collar — the pocket is 2.11 mm wider than the board
// on each side, so a module placed by eye could slide that far off the light guide.
module sensor_posts() {
    for (p = sensor_holes) {
        translate([wall + clearance + p[0], wall + clearance + p[1], floor_t])
            cylinder(d = post_d, h = sensor_deck_z - floor_t);
        translate([wall + clearance + p[0], wall + clearance + p[1], sensor_deck_z])
            cylinder(d = post_spigot_d, h = post_spigot_h);
    }
}

// The two walls that narrow the bay's extension to the module's pocket (the case interior is
// 30.8 mm deep because of the Pi board; the module needs 22).
module bay_walls() {
    for (y = [bay_y0 - bay_wall_t, bay_y0 + bay_depth])
        translate([wall + clearance + bay_x0, wall + clearance + y, floor_t])
            cube([bay_len, bay_wall_t, deck_z - floor_t]);
}

// Printed collar around the user's light guide tube: a bore from the floor up to the top of
// the guide, closed at the bottom by the Φ5.4 optical opening in the floor. It stops at the
// guide's top rather than at the module because the module's underside parts sit within
// 4.5 mm of the aperture — see the note with the sensor parameters.
module light_sleeve() {
    translate([wall + clearance + light_cx, wall + clearance + light_cy, floor_t])
        difference() {
            cylinder(d = sleeve_od, h = light_guide_len);
            translate([0, 0, -1]) cylinder(d = sleeve_bore, h = light_guide_len + 2);
        }
}

// Pad on the lid's underside that holds the sensor module down on its four posts (the posts
// locate the board, they cannot retain it). Its height is whatever the stack leaves, so it
// follows the light guide's length and the module's thickness.
module module_hold_down() {
    translate([wall + clearance + sensor_cx, wall + clearance + sensor_cy,
               sensor_deck_z + opt_t])
        cylinder(d = 8.0, h = max(0.2, deck_z - (sensor_deck_z + opt_t)));
}

// ---------------------------------------------------------------- parts

module tray() {
    difference() {
        union() {
            // The shell is hollowed out **first**, and the features that stand inside the
            // cavity are added afterwards. Cutting the cavity at the end (as v0.3 did) takes
            // the collar, the posts, the bay walls and the bay screw bosses with it: they
            // are all inside the cavity's own volume, so nothing of them survives.
            difference() {
                rounded_box(outer_w, outer_d, deck_z, corner_r);
                translate([wall, wall, floor_t])
                    rounded_box(inner_w, inner_d, deck_z, corner_r / 2);
            }
            bay_bosses();
            bay_walls();
            sensor_posts();
            light_sleeve();
        }

        // Front long edge: mini HDMI / USB-C x2
        translate([wall + clearance + hdmi_x, -1, floor_t + 2.5])
            cube([hdmi_w, wall + 2, hdmi_h]);
        translate([wall + clearance + usb_c1_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);
        translate([wall + clearance + usb_c2_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);

        // Left short edge: microSD
        translate([-1, wall + clearance + sd_y0, floor_t + 1.5])
            cube([wall + 2, sd_len, sd_h]);

        // Floor: the light window the sensor looks through
        translate([wall + clearance + light_cx, wall + clearance + light_cy, -1])
            cylinder(d = light_window_d, h = floor_t + 2);

        // The five blind screw pilots
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
            // Pad that keeps the sensor module on its posts
            module_hold_down();
        }

        // Display window (the module's board is 38.6 × 24.5; the window must stay smaller
        // than that because the two buttons are on the same face — see README)
        translate([wall + clearance + win_x0, wall + clearance + win_y0, deck_z - 1])
            cube([win_w, win_h, wall + 3]);

        // The module's two tactile buttons (a vertical pair at its left edge)
        for (p = btn_xy)
            translate([wall + clearance + p[0], wall + clearance + p[1], deck_z - 1])
                cylinder(d = tft_btn_hole_d, h = wall + 3);

        // Screw holes
        for (p = screw_xy)
            translate([wall + clearance + p[0], wall + clearance + p[1], deck_z - skirt_h - 1])
                cylinder(d = screw_clear, h = wall + skirt_h + 3);
    }
}

// ---------------------------------------------------------------- internals (cross-section check)

// The board, the header, the Mini PiTFT and the light sensor at their **actual heights**,
// so the cross-section shows the height relationships rather than a flat projection.
module internals() {
    // Board (65 × 30 × 1.6)
    color("SteelBlue")
        translate([wall + clearance, wall + clearance, floor_t])
            cube([board_w, board_d, board_t]);
    // 40-pin header (rear long edge): 2 rows × 20 columns, 2.54 mm pitch
    color("Green")
        translate([wall + clearance + header_x0 - header_pitch / 2,
                   wall + clearance + header_y_front - header_pitch / 2,
                   floor_t + board_t])
            cube([(header_cols - 1) * header_pitch + header_pitch,
                  header_pitch * 2, header_h]);
    // Mini PiTFT: 2×12 socket under the board, board, display glass, two buttons
    color("DimGray")
        translate([wall + clearance + tft_sock_cx - (tft_cols - 1) * header_pitch / 2 - 1.27,
                   wall + clearance + tft_sock_cy - 1.27,
                   tft_pcb_z - 5.0])
            cube([(tft_cols - 1) * header_pitch + 2.54, 2.54, 5.0]);
    color("Orange")
        translate([wall + clearance + tft_x0, wall + clearance + tft_y0, tft_pcb_z])
            cube([tft_w, tft_d, tft_t]);
    color("Black")
        translate([wall + clearance + lcd_x - tft_lcd_w / 2,
                   wall + clearance + lcd_y - tft_lcd_h / 2, tft_pcb_top])
            cube([tft_lcd_w, tft_lcd_h, tft_glass_t]);
    color("Crimson")
        for (p = btn_xy)
            translate([wall + clearance + p[0], wall + clearance + p[1], tft_pcb_top])
                cylinder(d = tft_btn_d, h = tft_btn_h);
    // Adafruit OPT4048 breakout on its posts, sensor side down (its window faces the floor)
    color("Purple")
        translate([wall + clearance + sensor_x0, wall + clearance + sensor_y0, sensor_deck_z])
            cube([opt_w, opt_d, opt_t]);
    // its package, hanging below the board at the (estimated) aperture
    color("Black")
        translate([wall + clearance + light_cx - 1.1, wall + clearance + light_cy - 0.6,
                   sensor_deck_z - opt_pkg_h])
            cube([2.2, 1.2, opt_pkg_h]);
    // the STEMMA QT connector on each short edge (the inner one takes the cable)
    color("White")
        for (x = [0.58, 19.92])
            translate([wall + clearance + sensor_x0 + x, wall + clearance + sensor_y0 + 5.19,
                       sensor_deck_z - 3.0])
                cube([4.9, 7.4, 3.0]);
    // Light guide tube (the user's part) inside the printed collar
    color("Gold")
        translate([wall + clearance + light_cx, wall + clearance + light_cy, floor_t])
            difference() {
                cylinder(d = light_guide_od, h = light_guide_len);
                translate([0, 0, -1]) cylinder(d = light_guide_id, h = light_guide_len + 2);
            };
    // microSD card (inserted from the left; passes under the Mini PiTFT)
    color("Silver")
        translate([-1, wall + clearance + sd_y0 + 2, floor_t + board_t + 0.2])
            cube([12, 11, 0.8]);
}

// ---------------------------------------------------------------- layout check (2D plan)

// Plan view. Left panel: the board and its connectors. Right panel: the Mini PiTFT's
// board as it sits on the header, with the lid window and the button holes drawn on top of
// it — this is the drawing to compare against the real module and Adafruit's photo.
//
// The drawing is extruded a fraction of a millimetre (each layer at its own height) so
// that `--render` treats it as a 3D object: that keeps the colours *and* prints a
// "Status:" line, neither of which happens when OpenSCAD CGAL-renders a flat 2D model.
module flat(h) { linear_extrude(height = h) children(); }

module layout_check() {
    // --- left panel: the board (lower layer) ---
    color("SteelBlue") flat(0.2) difference() {
        offset(r = corner_r) offset(delta = -corner_r) square([board_w, board_d]);
        for (p = concat(screw_board, [[hole_inset, board_d - hole_inset]]))
            translate([p[0], p[1]]) circle(d = hole_d);
    }
    // Connectors on the front long edge (HDMI / USB-C x2) and the 40-pin header
    color("Gray") flat(0.3) {
        translate([hdmi_x, -4]) square([hdmi_w, 4]);
        translate([usb_c1_x, -4]) square([usb_c_w, 4]);
        translate([usb_c2_x, -4]) square([usb_c_w, 4]);
    }
    color("Green") flat(0.3)
        translate([header_x0 - header_pitch / 2, header_y_front - header_pitch / 2])
            square([(header_cols - 1) * header_pitch + header_pitch, header_pitch * 2]);
    // microSD on the left short edge (the BAT connector is no longer cut out)
    color("DimGray") flat(0.3) translate([-4, sd_y0]) square([4, sd_len]);

    // --- right panel: the Mini PiTFT (upper layer; drawn beside the bay, not on top of it) ---
    // Everything in this panel is in the module's **own** coordinates: (0,0) is the
    // module board's left/rear corner, exactly as in Adafruit's top-down photo.
    translate([bay_x1 + 5, 0]) {
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
    }

    // --- sensor bay, to the right of the board (shown in board coordinates): the pocket, the
    //     OPT4048 board, the four mounting holes the posts go into, and the *estimated*
    //     aperture (orange = collar, gold = floor window) ---
    color("DarkSlateGray") flat(0.2) translate([bay_x0, bay_y0]) square([bay_len, bay_depth]);
    color("Purple") flat(0.25) translate([sensor_x0, sensor_y0]) square([opt_w, opt_d]);
    color("White") flat(0.3)
        for (p = sensor_holes) translate([p[0], p[1]]) circle(d = opt_hole_d);
    color("DarkOrange") flat(0.35) translate([light_cx, light_cy]) circle(d = sleeve_od);
    color("Gold") flat(0.4) translate([light_cx, light_cy]) circle(d = light_window_d);
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
    // Cut away the front half so the internal height relationships are visible
    difference() {
        union() {
            tray();
            internals();
            lid();
        }
        translate([-5, -5, -5])
            cube([outer_w + 10, wall + clearance + board_d / 2, deck_z + wall + 10]);
    }
}
