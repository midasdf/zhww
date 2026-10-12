// zhww enclosure (OpenSCAD, parametric)
//
// Layout: an RP2350-PiZero (65 × 30mm) plus a Waveshare 1.3inch LCD HAT, in a two-part
//         case split top and bottom. No battery (externally powered over USB).
//
// **Coordinate convention**: x is the board's long edge (0 = left end, 65 = right end),
// y is the short edge (0 = front = the USB-side edge, 30 = rear = the 40-pin header side),
// z is height (0 = the board's underside).
//
// ## Where the dimensions come from (important)
//
// Most of them are **values read off the official dimension drawings and product
// photos**; nothing has been measured with calipers yet.
// Once you measure, update the values marked `MEASURED`.
//
//   - Board outline 65.00 × 30.00mm, mounting holes Φ3.00, 40-pin header 2.54mm pitch
//     — the Waveshare RP2350-PiZero dimension drawing (the Dimensions image on the wiki)
//     https://www.waveshare.com/wiki/RP2350-PiZero
//   - Connector positions (three on the front long edge, microSD on the left short edge,
//     BAT 2-pin on the right short edge)
//     — the same dimension drawing. **Values read off the drawing**, so confirm by measuring
//   - HAT 65 × 30.2mm, display area 23.4 × 23.4mm
//     — the Waveshare 1.3inch LCD HAT wiki (Dimension / Specification)
//   - Layout on the HAT (a vertical column of KEY buttons at the left edge, the LCD in the
//     center, the joystick at the right edge)
//     — read off product photos. **Confirm by measuring**
//
// ## License
//
// CC-BY-SA-4.0 (the repository's LICENSE-ENCLOSURE)

// ---------------------------------------------------------------- board

board_w = 65.0;         // long edge (from the official drawing)
board_d = 30.0;         // short edge (from the official drawing)
board_t = 1.6;          // board thickness (a typical value)
corner_r = 3.0;         // board corner radius (from the drawing)

// Mounting holes (assumed to be in the same positions as the Pi Zero.
// MEASURED: confirm with calipers)
hole_d = 3.0;           // Φ3.00 (from the official drawing)
hole_inset = 3.5;       // edge to hole center (the Pi Zero standard. MEASURED)

// 40-pin header (along the rear long edge)
header_h = 8.5;         // height with the female socket mated (MEASURED)
header_pitch = 2.54;    // from the official drawing

// ---------------------------------------------------------------- connectors (front long edge)

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

// BAT connector on the right short edge (leave an opening in case an optional
// LiPo mod is used)
bat_w = 8.0;
bat_h = 4.0;
bat_y0 = 11.0;

// ---------------------------------------------------------------- HAT (sits on top)

hat_w = 65.0;           // HAT width (wiki: 65 × 30.2mm)
hat_d = 30.2;           // HAT depth
hat_t = 1.6;
// Display window (slightly left of the HAT center. MEASURED)
display_size = 23.4;    // display area (from the wiki)
display_x = 13.0;       // from the HAT's left edge
display_y = 3.3;        // from the HAT's front edge

// 3 buttons in a vertical column at the left edge (KEY1–3.
// MEASURED: read off photos)
button_d = 5.2;
button_x = 5.0;
button_y = [7.0, 15.0, 23.0];

// Joystick at the right edge (MEASURED: read off photos)
joystick_d = 8.0;
joystick_x = 55.0;
joystick_y = 15.0;

// ---------------------------------------------------------------- case

wall = 2.0;             // wall thickness
clearance = 0.4;        // clearance between the board and the case
floor_t = 2.0;          // base plate
inner_w = board_w + clearance * 2;
inner_d = board_d + clearance * 2;
inner_h = board_t + header_h + hat_t + 2.0;
screw_d = 2.2;          // M2.5 pilot hole

$fn = 48;

// ---------------------------------------------------------------- parts

module rounded_box(w, d, h, r = 2) {
    hull() {
        for (x = [r, w - r], y = [r, d - r])
            translate([x, y, 0]) cylinder(r = r, h = h);
    }
}

// Bosses aligned with the mounting holes at the board's four corners
// (the lid is screwed onto them)
module bosses() {
    for (p = [[hole_inset, hole_inset],
              [board_w - hole_inset, hole_inset],
              [hole_inset, board_d - hole_inset],
              [board_w - hole_inset, board_d - hole_inset]]) {
        translate([wall + clearance + p[0], wall + clearance + p[1], floor_t]) {
            difference() {
                cylinder(d = 6, h = inner_h - 1);
                translate([0, 0, -1]) cylinder(d = screw_d, h = inner_h + 2);
            }
        }
    }
}

// Bottom (the tray)
module tray() {
    difference() {
        union() {
            rounded_box(inner_w + wall * 2, inner_d + wall * 2, inner_h + floor_t, corner_r);
            // Inner lip that mates with the lid
            translate([wall + 0.6, wall + 0.6, inner_h + floor_t - 1.5])
                rounded_box(inner_w - 1.2, inner_d - 1.2, 1.5, corner_r / 2);
        }

        // Hollow out the inside
        translate([wall, wall, floor_t])
            rounded_box(inner_w, inner_d, inner_h + 2, corner_r / 2);

        // Front long edge: mini HDMI / USB-C ×2
        translate([wall + clearance + hdmi_x, -1, floor_t + 2.5])
            cube([hdmi_w, wall + 2, hdmi_h]);
        translate([wall + clearance + usb_c1_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);
        translate([wall + clearance + usb_c2_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);

        // Left short edge: microSD
        translate([-1, wall + clearance + sd_y0, floor_t + 1.5])
            cube([wall + 2, sd_len, sd_h]);

        // Right short edge: BAT (for an optional LiPo)
        translate([inner_w + wall - 1, wall + clearance + bat_y0, floor_t + 1.5])
            cube([wall + 2, bat_w, bat_h]);
    }

    bosses();
}

// Lid
module lid() {
    difference() {
        union() {
            translate([0, 0, inner_h + floor_t])
                rounded_box(inner_w + wall * 2, inner_d + wall * 2, wall, corner_r);
            translate([wall - 0.2, wall - 0.2, inner_h + floor_t - 1.5])
                rounded_box(inner_w + 0.4, inner_d + 0.4, 1.5, corner_r / 2);
        }

        // Display window
        translate([wall + clearance + display_x, wall + clearance + display_y,
                   inner_h + floor_t - 1])
            cube([display_size, display_size, wall + 3]);

        // 3 buttons (a vertical column at the left edge)
        for (y = button_y)
            translate([wall + clearance + button_x, wall + clearance + y,
                       inner_h + floor_t - 1])
                cylinder(d = button_d, h = wall + 3);

        // Joystick
        translate([wall + clearance + joystick_x, wall + clearance + joystick_y,
                   inner_h + floor_t - 1])
            cylinder(d = joystick_d, h = wall + 3);

        // Screw holes (aligned with the bosses)
        for (p = [[hole_inset, hole_inset],
                  [board_w - hole_inset, hole_inset],
                  [hole_inset, board_d - hole_inset],
                  [board_w - hole_inset, board_d - hole_inset]])
            translate([wall + clearance + p[0], wall + clearance + p[1],
                       inner_h + floor_t - 1])
                cylinder(d = screw_d, h = wall + 3);
    }
}

// ---------------------------------------------------------------- internals (cross-section check)

// Place the board, the 40-pin header, the HAT and the microSD card at their **actual
// heights**. The cross-section shows the height relationships, to check the report that
// "the cut-outs and the buttons look like they interfere".
module internals() {
    // Board (65 × 30 × 1.6)
    color("SteelBlue")
        translate([wall + clearance, wall + clearance, floor_t])
            cube([board_w, board_d, board_t]);
    // 40-pin header (the rear long edge; stands on the board)
    color("Green")
        translate([wall + clearance + corner_r, wall + clearance + board_d - 2.5,
                   floor_t + board_t])
            cube([board_w - corner_r * 2, 2.5, header_h]);
    // HAT (65 × 30.2 × 1.6; sits on the header)
    color("Orange")
        translate([wall + clearance, wall + clearance, floor_t + board_t + header_h])
            cube([hat_w, hat_d, hat_t]);
    // microSD card (inserted from the left; barely clear of the board's top face)
    color("Silver")
        translate([-1, wall + clearance + sd_y0 + 2, floor_t + board_t + 0.2])
            cube([12, 11, 0.8]);
}

// ---------------------------------------------------------------- layout check (2D)

// A plan view that draws the board and the HAT on **separate panels** (overlaying them
// would mislead because of the height difference).
// For comparing against the official dimension drawing and spotting position errors.
module layout_check() {
    // --- left panel: the board (lower layer) ---
    color("SteelBlue") difference() {
        offset(r = corner_r) offset(delta = -corner_r) square([board_w, board_d]);
        for (p = [[hole_inset, hole_inset],
                  [board_w - hole_inset, hole_inset],
                  [hole_inset, board_d - hole_inset],
                  [board_w - hole_inset, board_d - hole_inset]])
            translate([p[0], p[1]]) circle(d = hole_d);
    }
    // Connectors on the front long edge (HDMI / USB-C ×2) and the 40-pin header
    color("Gray") translate([hdmi_x, -4]) square([hdmi_w, 4]);
    color("Gray") translate([usb_c1_x, -4]) square([usb_c_w, 4]);
    color("Gray") translate([usb_c2_x, -4]) square([usb_c_w, 4]);
    color("Green") translate([corner_r, board_d]) square([board_w - corner_r * 2, 2.5]);
    // microSD on the left short edge, BAT on the right short edge
    color("DimGray") translate([-4, sd_y0]) square([4, sd_len]);
    color("DimGray") translate([board_w, bat_y0]) square([4, bat_w]);

    // --- right panel: the HAT (upper layer; shifted in x to sit beside it) ---
    translate([board_w + 25, 0]) {
        color("SteelBlue") offset(r = corner_r) offset(delta = -corner_r) square([hat_w, hat_d]);
        color("Orange") translate([display_x, display_y]) square([display_size, display_size]);
        color("Crimson") {
            for (y = button_y) translate([button_x, y]) circle(d = button_d);
            translate([joystick_x, joystick_y]) circle(d = joystick_d);
        }
        for (p = [[hole_inset, hole_inset],
                  [board_w - hole_inset, hole_inset],
                  [hole_inset, board_d - hole_inset],
                  [board_w - hole_inset, board_d - hole_inset]])
            translate([p[0], p[1]]) circle(d = hole_d);
    }
}

// ---------------------------------------------------------------- output

part = "all";   // "tray" / "lid" / "all" / "check" / "section" (switch with -D)

if (part == "all") {
    tray();
    translate([0, inner_d + wall * 2 + 10, 0]) lid();
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
            cube([inner_w + wall * 2 + 10, wall + clearance + board_d / 2, inner_h + floor_t + wall + 10]);
    }
}
