// zhww enclosure (OpenSCAD, parametric)
//
// Hardware: Waveshare RP2350-PiZero (65 × 30 mm) + **Adafruit Mini PiTFT 135x240
//           (product 4393)** on the 40-pin header + a commodity **LM393 light-sensor
//           module** behind a short opaque light-guide tube. USB power only (no battery).
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
//   - LM393 module ~20 × 15 mm, light guide ~Φ5 mm × 8–15 mm — from the project brief,
//     not measured .......................................................... [E]
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

// ---------------------------------------------------------------- light sensor (LM393)

light_window_d = 5.4;   // [E] optical opening in the floor (the brief asks Φ5–6)
light_guide_id = 5.0;   // [E] light guide tube: ~5 mm inner diameter (from the brief)
light_guide_od = 6.0;   // [E] tube outer diameter — the case only has to fit this
light_guide_len = 10.0; // [E] tube length, 8–15 mm in the brief
sleeve_od = 9.0;        // [E] printed sleeve around the tube
sleeve_bore = light_guide_od + 0.4;
sensor_mod_x = 15.0;    // [E] LM393 module ~20 × 15 mm (from the brief, not measured);
sensor_mod_y = 20.0;    //     drop it in with the 20 mm side front-to-back so it lands on
                        //     both rails
sensor_mod_t = 1.6;     // [E] module PCB thickness
rails_gap = 13.0;       // [E] clear width between the two module support rails
rail_t = 2.5;           // [E] rail thickness

// ---------------------------------------------------------------- case

wall = 2.0;             // wall thickness
clearance = 0.4;        // clearance between the board and the case
floor_t = 3.0;          // base plate; also the thread depth for the three board screws
                        // (a 2 mm floor would be too thin: the lid sits 16.5 mm above it)
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

// Sensor bay: the interior is extended past the board's right edge so the light guide has
// a floor to look through and the LM393 module has somewhere to live.
bay_len = 16.0;         // [E] interior extension beyond the board's right edge
bay_x0 = board_w + clearance;
bay_x1 = bay_x0 + bay_len;
light_cx = (bay_x0 + bay_x1) / 2;   // light window, x (board coordinates)
light_cy = board_d / 2;             // light window, y

inner_w = board_w + clearance * 2 + bay_len;
inner_d = board_d + clearance * 2;
outer_w = inner_w + wall * 2;
outer_d = inner_d + wall * 2;

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

sensor_deck_z = floor_t + light_guide_len + 1.0;          // = 13.0 LM393 PCB underside
// The tube reaches from the floor's top face up to just under the module, so the
// photodiode ends up inside the tube/sleeve — that is what keeps room light out.

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
// Prints the numbers the display window and the button holes were placed with, and fails
// the render if the two ever touch. Run with -D 'part="check"'.

echo(str("zhww-case: display window x ", win_x0, "..", win_x1,
         "  y ", win_y0, "..", win_y1, "  (", win_w, " x ", win_h, " mm)"));
echo(str("zhww-case: button holes Φ", tft_btn_hole_d, " at ",
         btn_xy[0], " and ", btn_xy[1], "  (x ", btn_x0, "..", btn_x1, ")"));
echo(str("zhww-case: window-to-button gap = ", win_button_gap, " mm",
         win_button_gap > 1.0 ? "  PASS" : "  FAIL (needs > 1.0 mm)"));
assert(win_button_gap > 1.0, "display window intersects the button cut-outs");
assert(win_x0 > tft_x0 && win_x1 < tft_x1 && win_y0 > tft_y0 && win_y1 < tft_y1,
       "display window falls outside the Mini PiTFT board");
assert(btn_x0 > tft_x0, "button hole falls outside the Mini PiTFT board");
assert(light_cx - sleeve_od / 2 > bay_x0 && light_cx + sleeve_od / 2 < bay_x1,
       "light guide sleeve does not fit in the sensor bay");
assert(sensor_mod_x + 1.0 <= bay_len && sensor_mod_y >= rails_gap + 2.0,
       "LM393 module does not fit the sensor bay / the rails");

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
// bite into the 2 mm floor (blind pilot, so nothing shows on the underside). The sensor
// bay has no board over it, so its two screws get proper bosses.
module screw_anchors() {
    for (p = screw_board)
        translate([wall + clearance + p[0], wall + clearance + p[1], 0])
            translate([0, 0, floor_t - floor_pilot_depth])
                cylinder(d = screw_pilot, h = floor_pilot_depth + 1);
    for (p = screw_bay)
        translate([wall + clearance + p[0], wall + clearance + p[1], 0])
            difference() {
                cylinder(d = boss_d, h = deck_z);
                translate([0, 0, deck_z - screw_pilot_depth])
                    cylinder(d = screw_pilot, h = screw_pilot_depth + 1);
            }
}

// The two rails the LM393 module rests on (sensor side down, photodiode over the sleeve).
module sensor_rails() {
    for (y = [light_cy - rails_gap / 2 - rail_t, light_cy + rails_gap / 2])
        translate([wall + clearance + bay_x0 + 1, wall + clearance + y, floor_t])
            cube([bay_len - 2, rail_t, sensor_deck_z - floor_t]);
}

// Printed sleeve around the user's light guide tube: a Ø6.4 bore from the floor up to the
// LM393 board, closed at the bottom by the Φ5.4 optical opening in the floor.
module light_sleeve() {
    translate([wall + clearance + light_cx, wall + clearance + light_cy, floor_t])
        difference() {
            cylinder(d = sleeve_od, h = sensor_deck_z - floor_t);
            translate([0, 0, -1]) cylinder(d = sleeve_bore, h = sensor_deck_z);
        }
}

// ---------------------------------------------------------------- parts

module tray() {
    difference() {
        union() {
            rounded_box(outer_w, outer_d, deck_z, corner_r);
            screw_anchors();
            sensor_rails();
            light_sleeve();
        }

        // Hollow out the inside
        translate([wall, wall, floor_t])
            rounded_box(inner_w, inner_d, deck_z, corner_r / 2);

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
    // LM393 module resting on the rails, sensor side down
    color("Purple")
        translate([wall + clearance + light_cx - sensor_mod_x / 2,
                   wall + clearance + light_cy - sensor_mod_y / 2, sensor_deck_z])
            cube([sensor_mod_x, sensor_mod_y, sensor_mod_t]);
    // Light guide tube (the user's part) inside the printed sleeve
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

    // --- right panel: the Mini PiTFT (upper layer; drawn beside the board) ---
    // Everything in this panel is in the module's **own** coordinates: (0,0) is the
    // module board's left/rear corner, exactly as in Adafruit's top-down photo.
    translate([board_w + 25, 0]) {
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

    // --- sensor bay, to the right of the board (shown in board coordinates) ---
    color("DarkSlateGray") flat(0.2) translate([bay_x0, -0.4]) square([bay_len, board_d + 0.8]);
    color("DarkOrange") flat(0.3) translate([light_cx, light_cy]) circle(d = sleeve_od);
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
