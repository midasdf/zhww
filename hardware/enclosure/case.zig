//! zhww enclosure: the parametric source. Running it writes the SolidCraft scripts next to it.
//!
//!     cd hardware/enclosure
//!     zig run case.zig -- write    # (re)generate zhww-case.json and zhww-case-check.json
//!     zig run case.zig -- check    # CI: the committed scripts match this file, and every check passes
//!     zig test case.zig            # the same checks, as tests
//!
//! Hardware: Waveshare RP2350-PiZero (65 × 30 mm), the Adafruit Mini PiTFT 135×240 (#4393) on the
//! left 24 pins of its 40-pin header, and an ArduCam UC-805 (Arducam B0315, Himax HM01B0) camera
//! **looking out through the floor**, beside the board at the right-hand end. USB power only.
//!
//! The case is two shells split at one horizontal parting line, so their outer faces, corner radii
//! and the parting groove run continuously round the part: a **base** (floor, board standoffs,
//! camera posts, the lens opening, the power USB-C opening) and a **top** (display window, two
//! button caps, bosses). Four countersunk M2 screws come in from
//! underneath, one in each corner, all the same distance from both edges they are near; the
//! front-right one passes through the camera board's own hole. Bosses in the top press the board
//! and the camera's other hole down without screws, and nothing shows on the face you look at.
//!
//! The lens is placed by the golden ratio: it divides the space between the two right-hand screws
//! 1 : φ, which is what sets the case's depth.
//!
//! Why the camera sits beside the board rather than under it: under the board it would add about
//! 6 mm to the height; beside it, the case stays as thin as the display stack (about 20 mm) and
//! grows about 23 mm in length instead. Why the height is the display stack and not the wiring:
//! the four camera signals reach the 40-pin header on jumper wires whose header-side ends have
//! their plastic housings removed and are insulated with heat-shrink (see the README) — a standard
//! 14 mm housing would stand about 6 mm above the display.
//!
//! **Coordinates** (the same convention as the earlier OpenSCAD model): x = the board's long edge
//! (0 = the microSD end), y = its short edge (0 = the USB-C edge, the front), z = up (0 = the
//! case's outside bottom). "Board" coordinates are measured from the board's front-left corner;
//! the case's origin is its own outer front-left-bottom corner.
//!
//! **Where the numbers come from.** Nothing has been measured with calipers yet. Every value that
//! describes a bought part carries a tag:
//!
//!   [D] published: an official drawing, a datasheet, a vendor page or the vendor's PCB files
//!   [P] read off a product photo (good to about ±0.5–1 mm)
//!   [E] our estimate or a design choice
//!   MEASURED: confirm on the real part before a long print
//!
//! The checks at the bottom of this file are the point of it: they compute every clearance the
//! design depends on and refuse to write a script when one of them stops holding.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: CERN-OHL-S-2.0

const std = @import("std");
const sc = @import("solidcraft.zig");
const Vec3 = sc.Vec3;
const XY = [2]f64;

// ---------------------------------------------------------------- the board (RP2350-PiZero)

const board_w: f64 = 65.0; // [D] long edge (Waveshare dimension drawing)
const board_d: f64 = 30.0; // [D] short edge
const board_t: f64 = 1.6; // [E] PCB thickness
const board_r: f64 = 3.0; // [D] corner radius
const hole_d: f64 = 3.0; // [D] Φ3.00 mounting holes
const hole_inset: f64 = 3.5; // [P] edge to hole centre (Pi Zero layout)  MEASURED
/// What hangs below the board: the 40-pin header's solder tails and any bottom-side parts.
const under_board: f64 = 2.0; // [E]  MEASURED

// 40-pin header along the rear edge. Odd pins are on the inner row, even pins on the outer row;
// pin 1 is at the microSD end. (On this board several pins carry different GPIO numbers from a
// Raspberry Pi's: docs/03-hardware-bom.md has the table.)
const header_pitch: f64 = 2.54; // [D]
const header_x0: f64 = 8.37; // [P] x of column 0  MEASURED
const header_y_rear: f64 = 27.0; // [P] y of the outer row  MEASURED
const header_body_h: f64 = 2.5; // [E] the header's plastic strip above the board
const header_h: f64 = 8.5; // [E] board top → Mini PiTFT underside, socket mated  MEASURED (sets the height)

// Front-edge connectors. Only the power USB-C (the rightmost, "USB") gets an opening; the mini
// HDMI and the PIO-USB stay closed behind the wall (an air-gapped signer has no use for them),
// with a shallow relief inside the wall in case they stand out past the board edge.
const usb_cx: f64 = 51.5; // [P] centre of the power USB-C, from the board's left edge  MEASURED
const usb_body_w: f64 = 8.94; // [D] USB-C receptacle shell (USB-IF)
const usb_body_h: f64 = 3.26; // [D]
const usb_protrusion: f64 = 0.5; // [E] how far the receptacles stand out past the board edge  MEASURED
const hdmi_x0: f64 = 8.0; // [P] mini HDMI, left edge … right edge  MEASURED
const hdmi_x1: f64 = 19.0; // [P]
const piousb_x0: f64 = 33.0; // [P] PIO-USB (USB-C), left edge … right edge  MEASURED
const piousb_x1: f64 = 42.0; // [P]
const front_relief: f64 = 0.7; // [E] relief depth into the closed front wall

// The 2-pin BAT connector on the right short edge stays inside (USB power only). The camera's
// jumper housings pass over it.
const bat_x0: f64 = 59.0; // [E]  MEASURED
const bat_y0: f64 = 11.0; // [P]
const bat_y1: f64 = 19.0; // [P]
const bat_h: f64 = 4.0; // [P] above the board  MEASURED

// The microSD slot on the left short edge stays closed: the project does not exchange data on
// cards (owner decision, docs/03-hardware-bom.md).

// ---------------------------------------------------------------- Mini PiTFT #4393

const tft_w: f64 = 38.6; // [D] module board (the .brd outline is 38.1 × 24.4; the larger is kept)
const tft_d: f64 = 24.5; // [D]
const tft_t: f64 = 1.6; // [E]
const tft_cols = 12; // [D] its 2×12 socket takes header columns 0–11 (pins 1–24)
const tft_sock_cx = header_x0 + (tft_cols - 1) * header_pitch / 2.0;
const tft_sock_cy = header_y_rear - header_pitch / 2.0;
const tft_left_off: f64 = -22.2; // [P] module left edge − socket centre
const tft_rear_off: f64 = 4.25; // [P] module rear edge − socket centre (the .brd says ~0.75 more)
const tft_lcd_w: f64 = 24.4; // [E] active area (240 × 0.1016 mm)
const tft_lcd_h: f64 = 13.7; // [E] (135 × 0.1016 mm)
const tft_lcd_dx: f64 = -1.63; // [P] active-area centre − socket centre (x)
const tft_lcd_dy: f64 = 10.80; // [P] socket centre − active-area centre (y, toward the front)
const tft_glass_t: f64 = 1.6; // [E] panel above the module PCB
const tft_btn_h: f64 = 2.0; // [E] tactile-button actuator above the module PCB
const tft_btn_d: f64 = 3.0; // [P] actuator diameter
const tft_btn_dx: f64 = -19.3; // [P] button centre − socket centre (x)
const tft_btn_dy = [2]f64{ 6.15, 14.90 }; // [P] socket centre − button centres (y)
const tft_qt_x0: f64 = 6.5; // [D] its STEMMA QT socket (underside), from the module's left edge
const tft_qt_w: f64 = 6.1; // [D]
const tft_qt_d: f64 = 4.25; // [D]
const tft_qt_h: f64 = 3.0; // [E]

// ---------------------------------------------------------------- the camera (ArduCam UC-805)

// A carrier board with the HM01B0 module stuck to its component side, mounted component side
// DOWN so the lens looks out through the floor; the 1×8 right-angle header (odd row only) is on
// the back and points its pins back toward the main board.
const cam_w: f64 = 24.9; // [P] the header edge (along y here)  MEASURED
const cam_d: f64 = 22.8; // [P] header edge → hole edge (along x here)  MEASURED
const cam_t: f64 = 1.6; // [E]
const cam_hole_d: f64 = 3.0; // [E] two holes on the edge opposite the header  MEASURED
const cam_hole_inset: f64 = 2.2; // [E] from the hole edge and from each side  MEASURED
const cam_lens_from_far: f64 = 5.3; // [P] lens axis → the hole edge; centred across  MEASURED
const cam_parts_h: f64 = 1.45; // [E] tallest component-side part other than the camera (SOT-23-5)
const lens_barrel_d: f64 = 4.0; // [D] Arducam-HM01B0 drawing
const lens_h: f64 = 2.98; // [D] lens tip below the component surface (+ glue: MEASURED)
const lens_collar_d: f64 = 5.0; // [D]
const lens_collar_h: f64 = 2.35; // [D]
const lens_body: f64 = 6.0; // [D] 6 × 6 mm body
const lens_body_h: f64 = 1.95; // [D]
const lens_aperture: f64 = 1.1; // [D]
const lens_half_fov_deg: f64 = 30.0; // [D] 60° diagonal
const cam_header_h: f64 = 2.5; // [E] right-angle header's plastic body on the back
const cam_pin_out: f64 = 7.0; // [E] pins past the board edge  MEASURED
const housing: f64 = 2.54; // [E] a standard 0.1" female housing, square
const housing_len: f64 = 14.0; // [E]
const housing_on_pin: f64 = 6.0; // [E] how much of the pin a housing swallows
const cam_pins = 8; // [D] VCC SCL SDA VSYNC HREF PCLK D0 GND, odd row of the 2×8 footprint
const cam_gap: f64 = 0.5; // [E] main board edge → camera board edge
/// Camera centre line, in board y. Its front hole is the front-right corner screw, so the camera
/// sits where that hole lands `corner_inset` from the front edge; the checks confirm that this
/// keeps its housings in front of the 40-pin header and its board inside the front wall.
const cam_cy = corner_inset - board_y0 + (cam_w / 2 - cam_hole_inset);

// The four camera signals land on the 40-pin header (RP2350-PiZero GPIO numbers): HREF on pin 29
// (GPIO15), D0 on pin 32 (GPIO9), PCLK on pin 33 (GPIO13), VSYNC on pin 36 (GPIO16). They are
// chequered across the two rows, so no two bare terminals stand side by side at 2.54 mm. Power,
// I²C and ground come from the Mini PiTFT's STEMMA QT port instead.
const signal_pins = [_]u8{ 29, 32, 33, 36 };
const terminal: f64 = 2.8; // [E] a bare female crimp terminal in heat-shrink, round
const terminal_h: f64 = 8.5; // [E] its height above the header's plastic  MEASURED
const wire_bend: f64 = 1.2; // [E] the wire turning flat above it

// ---------------------------------------------------------------- case

const wall: f64 = 1.8; // [E] side walls (uniform, for a clear print)
const floor_t: f64 = 1.8; // [E]
const top_t: f64 = 1.6; // [E] top plate
const clearance: f64 = 0.4; // [E] board edge → inner wall (front)
const cam_clearance: f64 = 0.5; // [E] camera board → right inner wall
const corner_r: f64 = 5.0; // [E] outer corner radius in plan
const inner_r: f64 = 1.0; // [E] inner corner radius (keeps square module corners clear)
const top_edge_r: f64 = 1.5; // [E] round-over along the top
const bottom_edge_r: f64 = 0.8; // [E] round-over along the bottom
const parting_groove: f64 = 0.4; // [E] chamfer on both sides of the parting line: a V reveal
const lid_gap: f64 = 0.5; // [E] air above the tallest thing under the top plate
const lip_t: f64 = 0.8; // [E] locating lip on the base: the inner part of the wall, standing up
/// As tall as it can be while its top stays below the Mini PiTFT's board: it locks the shells
/// against each other in torsion (it was 1.2 mm).
const lip_h = @min(2.5, tft_pcb_z - parting_z - 0.1);
const lip_gap: f64 = 0.15; // [E] lip → top-shell clearance

const standoff_d: f64 = 5.5; // [E] inside the Φ6 keep-out round the board's holes
const pin_d: f64 = 2.5; // [E] locating pin into a Φ3.00 hole
const pin_h: f64 = 1.2; // [E]
const cam_post_d: f64 = 4.6; // [E] under the camera board's holes
const cam_rest_d: f64 = 2.4; // [E] under the header-edge corners
const cam_rest_from_edge: f64 = 1.5; // [E]
const cam_rest_from_side: f64 = 1.25; // [E]
const clamp_t: f64 = 1.2; // [E] rib from the top plate onto the camera header's plastic
const clamp_gap: f64 = 0.2; // [E]

// Screws: four M2 × 16 flat heads from underneath, one in each corner, into blind pilots in the
// top shell. All four stand `corner_inset` in from both edges they are near. That inset is set by
// the front-right one, which is the camera board's own front hole: its distance from the camera's
// edge, plus the camera's clearance to the wall, plus the wall. The other three stand in columns
// of their own (a post in the base, a boss in the top), clear of the walls: a boss merged into the
// wall would hit the base's wall and lip below the parting line. The board and the camera's rear
// hole are held by bosses that press on them without a screw.
const screw_clear_d: f64 = 2.4; // [E] M2 clearance
const screw_head_d: f64 = 4.0; // [D] ISO 10642 M2 head (3.8)
const screw_pilot_d: f64 = 1.6; // [E] M2 into printed plastic
const screw_len: f64 = 16.0; // [E] M2 × 16
const boss_d: f64 = 5.0; // [E]
/// The front-left boss runs beside the Mini PiTFT's front edge, so it is flattened on that side.
const boss_flat_keepout: f64 = 0.3; // [E] air between that flat and the module's front edge
const corner_inset = cam_hole_inset + cam_clearance + wall;
const column_d: f64 = 3.6; // [E] a corner column round a Φ1.6 pilot: 1.0 mm of wall
const column_gap_board: f64 = 0.3; // [E] the left columns → the board's left edge (and the Mini PiTFT's)
const column_gap_wall = corner_inset - wall - column_d / 2; // the left columns → the left inner wall
/// The rear-middle column stands behind the board's rear edge, on the rear row, at the case's
/// centre; it is slimmer so it clears that edge.
const rear_column_d: f64 = 3.2; // [E] round a Φ1.6 pilot: 0.8 mm of wall
/// Under every column's boss, the base has a wider post that stops just below the board, so it has
/// a thick wall round the screw's clearance hole; only the slimmer boss above passes the board's
/// edge.
const column_post_d: f64 = 4.6; // [E] round the Φ2.4 clearance hole: 1.1 mm of wall
const column_seat = board_z - 0.2; // the post's top, where the boss above meets it

/// The golden ratio sets the case's depth: the lens divides it 1 : φ from the front edge (the lens's
/// own distance from the front edge is fixed by the camera board and the corner inset). The rear
/// clearance is whatever that leaves; the checks confirm the Mini PiTFT fits and the rear-middle
/// column clears the board.
const phi = (1.0 + @sqrt(5.0)) / 2.0;
const golden_minor = 1.0 - 1.0 / phi; // 0.382: the smaller part of a golden division
const lens_from_front = corner_inset + (cam_w / 2 - cam_hole_inset);

// Display window and buttons
const window_margin: f64 = 1.0; // [E] window = active area + this on every side
const window_r: f64 = 1.0; // [E]
const window_chamfer: f64 = 0.6; // [E]
const cap_d: f64 = 4.0; // [E] button cap
const cap_hole_d: f64 = 4.4; // [E]
const cap_flange_d: f64 = 6.2; // [E] captive flange, sits in a counterbore in the top plate
const cap_flange_t: f64 = 0.7; // [E]
const cap_counterbore: f64 = 0.8; // [E]
const cap_proud: f64 = 0.4; // [E] how far the caps stand above the top
const cap_rest_gap: f64 = 0.15; // [E] cap → actuator when released

// Power USB-C opening: a stadium through the wall and a shallow pocket for the plug's overmould
const usb_open_w: f64 = 9.6; // [E]
const usb_open_h: f64 = 4.0; // [E]
const usb_pocket_w: f64 = 12.6; // [E] fits most overmoulded plugs  MEASURED with your cable
const usb_pocket_h: f64 = 7.0; // [E]
const usb_wall_left: f64 = 0.6; // [E] wall left at the bottom of the pocket

// Lens opening in the floor (countersunk from below)
const lens_hole_d: f64 = 6.4; // [E]
const lens_cs_d: f64 = 8.0; // [E] 90° countersink at the bottom face

// ---------------------------------------------------------------- derived layout

const clearance_left = column_gap_wall + column_d + column_gap_board; // board edge → left inner wall
const board_x0 = wall + clearance_left;
const board_y0 = wall + clearance;
const board_z = floor_t + under_board; // board underside
const board_top = board_z + board_t;
const header_top = board_top + header_body_h;

const tft_x0 = tft_sock_cx + tft_left_off;
const tft_x1 = tft_x0 + tft_w;
const tft_y1 = tft_sock_cy + tft_rear_off;
const tft_y0 = tft_y1 - tft_d;
const tft_pcb_z = board_top + header_h;
const tft_pcb_top = tft_pcb_z + tft_t;
const tft_tallest = tft_pcb_top + @max(tft_glass_t, tft_btn_h);
const btn_top = tft_pcb_top + tft_btn_h;

// The camera board, in board coordinates (it lies beyond the board's right edge)
const cam_x0 = board_w + cam_gap; // the header edge
const cam_x1 = cam_x0 + cam_d; // the hole edge
const cam_y0 = cam_cy - cam_w / 2;
const cam_y1 = cam_cy + cam_w / 2;
/// The housings on its pins lie on its back; their underside is the board's back surface.
const cam_top = board_top + bat_h + 0.3; // camera board back (up) surface
const cam_bottom = cam_top - cam_t; // component surface (down)
const lens_x = cam_x1 - cam_lens_from_far;
const lens_tip = cam_bottom - lens_h;
const housing_x1 = cam_x0 - (cam_pin_out - housing_on_pin);
const housing_x0 = housing_x1 - housing_len;
const housing_half = cam_pins * header_pitch / 2;
const cam_holes = [2]XY{
    .{ cam_x1 - cam_hole_inset, cam_y0 + cam_hole_inset },
    .{ cam_x1 - cam_hole_inset, cam_y1 - cam_hole_inset },
};

const top_inner = @max(tft_tallest, header_top + terminal_h + wire_bend) + lid_gap;
const outer_h = top_inner + top_t;
const outer_w = board_x0 + cam_x1 + cam_clearance + wall;
const outer_d = lens_from_front / golden_minor;
const clearance_rear = outer_d - wall - board_y0 - board_d; // board's rear edge → rear inner wall

const lcd_x = tft_sock_cx + tft_lcd_dx;
const lcd_y = tft_sock_cy - tft_lcd_dy;
const win_w = tft_lcd_w + 2 * window_margin;
const win_h = tft_lcd_h + 2 * window_margin;
const win_x0 = lcd_x - win_w / 2;
const win_y0 = lcd_y - win_h / 2;
const buttons = [2]XY{
    .{ tft_sock_cx + tft_btn_dx, tft_sock_cy - tft_btn_dy[0] },
    .{ tft_sock_cx + tft_btn_dx, tft_sock_cy - tft_btn_dy[1] },
};

const usb_cz = board_top + usb_body_h / 2;
/// The parting line sits above the USB-C pocket, so the opening is one closed shape in the base.
const parting_z = usb_cz + usb_pocket_h / 2 + 1.2;

// Board mounting holes, in board coordinates
const hole_fl = XY{ hole_inset, hole_inset };
const hole_fr = XY{ board_w - hole_inset, hole_inset };
const hole_rr = XY{ board_w - hole_inset, board_d - hole_inset };
const hole_rl = XY{ hole_inset, board_d - hole_inset };

/// A boss hanging from the top plate. With `screw`, a screw comes up from underneath into it;
/// without, it only presses the part below it down.
const Boss = struct {
    at: XY, // board coordinates
    seat: f64, // z of the face the boss presses on (the board's top, or the camera's back)
    under: f64, // z of that part's underside, where the clearance hole from below ends
    screw: bool,
    flat: bool = false, // flattened toward the Mini PiTFT
    d: f64 = boss_d,
    post: bool = false, // a column: the base has a post of its own (Φ`column_post_d`) under the boss
    corner: bool = false, // one of the four corner screws, all `corner_inset` from their edges
};
// The corner screws, in board coordinates
const column_left = -(column_gap_board + column_d / 2);
const column_right = cam_holes[0][0];
const row_front = cam_holes[0][1];
const row_rear = outer_d - corner_inset - board_y0;
const column_middle = outer_w / 2 - board_x0;
const bosses = [_]Boss{
    .{ .at = .{ column_left, row_front }, .seat = column_seat, .under = column_seat, .screw = true, .d = column_d, .post = true, .corner = true },
    .{ .at = .{ column_left, row_rear }, .seat = column_seat, .under = column_seat, .screw = true, .d = column_d, .post = true, .corner = true },
    .{ .at = cam_holes[0], .seat = cam_top, .under = cam_bottom, .screw = true, .corner = true },
    .{ .at = .{ column_right, row_rear }, .seat = column_seat, .under = column_seat, .screw = true, .d = column_d, .post = true, .corner = true },
    // the middle of the rear row, behind the board
    .{ .at = .{ column_middle, row_rear }, .seat = column_seat, .under = column_seat, .screw = true, .d = rear_column_d, .post = true },
    // two more through the board's own holes: they clamp base, board and top together
    .{ .at = hole_fl, .seat = board_top, .under = board_z, .screw = true, .flat = true },
    .{ .at = hole_rr, .seat = board_top, .under = board_z, .screw = true },
    .{ .at = cam_holes[1], .seat = cam_top, .under = cam_bottom, .screw = false },
};

fn caseX(bx: f64) f64 {
    return board_x0 + bx;
}
fn caseY(by: f64) f64 {
    return board_y0 + by;
}

/// A 40-pin header pin's centre, in board coordinates.
fn pinXY(pin: u8) XY {
    const col: f64 = @floatFromInt((pin - 1) / 2);
    const y = if (pin % 2 == 1) header_y_rear - header_pitch else header_y_rear;
    return .{ header_x0 + col * header_pitch, y };
}

/// Radius of the lens's field of view at height `z` (below the lens tip).
fn fovRadius(z: f64) f64 {
    return lens_aperture / 2 + (lens_tip - z) * @tan(lens_half_fov_deg * std.math.pi / 180.0);
}

fn pilotDepth(seat: f64) f64 {
    return screw_len - seat + 1.0;
}

// ---------------------------------------------------------------- geometry

/// A box with its four vertical edges rounded (`r` 0: square), created as a new body.
fn roundedBox(s: *sc.Script, name: []const u8, corner: Vec3, size: Vec3, r: f64) !void {
    try s.box(name, corner, size, .new);
    if (r <= 0) return;
    const x0 = corner[0];
    const y0 = corner[1];
    const x1 = corner[0] + size[0];
    const y1 = corner[1] + size[1];
    const zm = corner[2] + size[2] / 2;
    try s.fillet(name, &.{ .{ x0, y0, zm }, .{ x1, y0, zm }, .{ x1, y1, zm }, .{ x0, y1, zm } }, r);
}

/// A stadium (a slot with round ends) along y, as a new body.
fn stadiumY(s: *sc.Script, name: []const u8, cx: f64, cz: f64, w: f64, h: f64, y0: f64, y1: f64) !void {
    try s.box(name, .{ cx - w / 2, y0, cz - h / 2 }, .{ w, y1 - y0, h }, .new);
    const ym = (y0 + y1) / 2;
    const r = h / 2 - 0.02;
    try s.fillet(name, &.{
        .{ cx - w / 2, ym, cz - h / 2 }, .{ cx + w / 2, ym, cz - h / 2 },
        .{ cx - w / 2, ym, cz + h / 2 }, .{ cx + w / 2, ym, cz + h / 2 },
    }, r);
}

fn cutWith(s: *sc.Script, target: []const u8, tool: []const u8) !void {
    try s.combine(target, &.{tool}, .cut);
}

fn joinWith(s: *sc.Script, target: []const u8, tool: []const u8) !void {
    try s.combine(target, &.{tool}, .join);
}

/// A countersunk clearance hole for an M2 flat head, from the bottom face up to `depth`.
fn screwHole(s: *sc.Script, body: []const u8, x: f64, y: f64, depth: f64) !void {
    try s.cmd("solid.hole", "\"body\": \"{s}\", \"position\": {f}, \"direction\": [0, 0, 1], \"diameter\": {f}, \"depth\": {f}, \"type\": \"countersink\", \"cs_diameter\": {f}, \"cs_angle\": \"90 deg\"", .{
        body, sc.p3(x, y, 0), sc.n(screw_clear_d), sc.n(depth), sc.n(screw_head_d + 0.3),
    });
}

const up: Vec3 = .{ 0, 0, 1 };

fn writeBase(s: *sc.Script) !void {
    // Outer shell, from the floor to the parting line. The locating lip (the inner part of the
    // wall carried up past the parting line) is added as a solid block and hollowed out together
    // with the cavity, so no two faces coincide.
    try roundedBox(s, "Base", .{ 0, 0, 0 }, .{ outer_w, outer_d, parting_z }, corner_r);
    try roundedBox(s, "Lip", .{ wall - lip_t, wall - lip_t, parting_z - 1 }, .{ outer_w - 2 * (wall - lip_t), outer_d - 2 * (wall - lip_t), lip_h + 1 }, corner_r - (wall - lip_t)); // concentric with the outside
    try joinWith(s, "Base", "Lip");
    try s.fillet("Base", &.{.{ outer_w / 2, 0, 0 }}, bottom_edge_r);
    try roundedBox(s, "BaseCavity", .{ wall, wall, floor_t }, .{ outer_w - 2 * wall, outer_d - 2 * wall, parting_z + lip_h }, inner_r);
    try cutWith(s, "Base", "BaseCavity");

    // Board standoffs: the front-left and rear-right ones are drilled for screws, the front-right
    // and rear-left ones (under the camera housings and under the display) carry locating pins
    for ([_]XY{ hole_fl, hole_fr, hole_rr, hole_rl }) |h| {
        try s.cylinder("Standoff", .{ caseX(h[0]), caseY(h[1]), floor_t - 0.01 }, standoff_d, under_board + 0.01, up, .new);
        try joinWith(s, "Base", "Standoff");
    }
    for ([_]XY{ hole_fr, hole_rl }) |h| {
        try s.cylinder("Pin", .{ caseX(h[0]), caseY(h[1]), board_z - 0.01 }, pin_d, pin_h + 0.01, up, .new);
        try joinWith(s, "Base", "Pin");
    }

    // The posts under the three corner columns
    for (bosses) |b| {
        if (!b.post) continue;
        try s.cylinder("ColumnPost", .{ caseX(b.at[0]), caseY(b.at[1]), floor_t - 0.01 }, column_post_d, b.seat - floor_t + 0.01, up, .new);
        try joinWith(s, "Base", "ColumnPost");
    }

    // Camera: two posts under its holes (the front one drilled for its screw, the rear one with a
    // locating pin) and two rests under the corners of its header edge
    for (cam_holes) |h| {
        try s.cylinder("CamPost", .{ caseX(h[0]), caseY(h[1]), floor_t - 0.01 }, cam_post_d, cam_bottom - floor_t + 0.01, up, .new);
        try joinWith(s, "Base", "CamPost");
    }
    try s.cylinder("Pin", .{ caseX(cam_holes[1][0]), caseY(cam_holes[1][1]), cam_bottom - 0.01 }, pin_d, pin_h + 0.01, up, .new);
    try joinWith(s, "Base", "Pin");
    for ([_]f64{ cam_y0 + cam_rest_from_side, cam_y1 - cam_rest_from_side }) |y| {
        try s.cylinder("CamRest", .{ caseX(cam_x0 + cam_rest_from_edge), caseY(y), floor_t - 0.01 }, cam_rest_d, cam_bottom - floor_t + 0.01, up, .new);
        try joinWith(s, "Base", "CamRest");
    }

    // Screw holes from underneath, countersunk
    for (bosses) |b| {
        if (b.screw) try screwHole(s, "Base", caseX(b.at[0]), caseY(b.at[1]), b.under + 0.5);
    }

    // The lens looks out through the floor
    try s.cmd("solid.hole", "\"body\": \"Base\", \"position\": {f}, \"direction\": [0, 0, 1], \"diameter\": {f}, \"depth\": {f}, \"type\": \"countersink\", \"cs_diameter\": {f}, \"cs_angle\": \"90 deg\"", .{
        sc.p3(caseX(lens_x), caseY(cam_cy), 0), sc.n(lens_hole_d), sc.n(floor_t + 0.5), sc.n(lens_cs_d),
    });

    // Power USB-C: the opening, and a pocket that lets an overmoulded plug seat fully
    try stadiumY(s, "UsbOpening", caseX(usb_cx), usb_cz, usb_open_w, usb_open_h, -1, wall + 1);
    try cutWith(s, "Base", "UsbOpening");
    try stadiumY(s, "UsbPocket", caseX(usb_cx), usb_cz, usb_pocket_w, usb_pocket_h, -1, wall - usb_wall_left);
    try cutWith(s, "Base", "UsbPocket");
    // Reliefs inside the closed front wall for the mini HDMI and the PIO-USB receptacles
    for ([_]XY{ .{ hdmi_x0, hdmi_x1 }, .{ piousb_x0, piousb_x1 } }) |r| {
        try s.box("FrontRelief", .{ caseX(r[0] - 0.5), wall - front_relief, board_top - 0.3 }, .{ r[1] - r[0] + 1, front_relief + 0.5, usb_body_h + 0.9 }, .new);
        try cutWith(s, "Base", "FrontRelief");
    }

    try s.chamfer("Base", &.{.{ outer_w / 2, 0, parting_z }}, parting_groove);
}

fn writeTop(s: *sc.Script) !void {
    try roundedBox(s, "Top", .{ 0, 0, parting_z }, .{ outer_w, outer_d, outer_h - parting_z }, corner_r);
    try s.fillet("Top", &.{.{ outer_w / 2, 0, outer_h }}, top_edge_r);
    try roundedBox(s, "TopCavity", .{ wall, wall, parting_z - 1 }, .{ outer_w - 2 * wall, outer_d - 2 * wall, top_inner - parting_z + 1 }, inner_r);
    try cutWith(s, "Top", "TopCavity");
    // Relief for the base's lip
    const relief = wall - lip_t - lip_gap;
    try roundedBox(s, "LipRelief", .{ relief, relief, parting_z - 1 }, .{ outer_w - 2 * relief, outer_d - 2 * relief, lip_h + lip_gap + 1 }, corner_r - relief); // concentric: an even skin round the corners
    try cutWith(s, "Top", "LipRelief");

    // Bosses, from the underside of the top plate down onto the board, the camera or a corner
    // post; the four with a screw get a blind pilot
    for (bosses) |b| {
        const x = caseX(b.at[0]);
        const y = caseY(b.at[1]);
        try s.cylinder("Boss", .{ x, y, b.seat }, b.d, top_inner - b.seat + 0.01, up, .new);
        if (b.flat) {
            try s.box("BossFlat", .{ x - b.d, caseY(tft_y0 - boss_flat_keepout), b.seat - 1 }, .{ 2 * b.d, b.d, top_inner - b.seat + 2 }, .new);
            try cutWith(s, "Boss", "BossFlat");
        }
        try joinWith(s, "Top", "Boss");
        if (!b.screw) continue;
        try s.cylinder("Pilot", .{ x, y, b.seat - 0.01 }, screw_pilot_d, pilotDepth(b.seat), up, .new);
        try cutWith(s, "Top", "Pilot");
    }

    // A rib that holds the camera's header edge down by its plastic body
    const clamp_z = cam_top + cam_header_h + clamp_gap;
    try s.box("CamClamp", .{ caseX(cam_x0 + 0.3), caseY(cam_cy - housing_half + 0.6), clamp_z }, .{ clamp_t, 2 * housing_half - 1.2, top_inner - clamp_z + 0.01 }, .new);
    try joinWith(s, "Top", "CamClamp");

    // Display window, rounded in plan and chamfered on the outside
    try roundedBox(s, "Window", .{ caseX(win_x0), caseY(win_y0), top_inner - 1 }, .{ win_w, win_h, top_t + 2 }, window_r);
    try cutWith(s, "Top", "Window");
    try s.chamfer("Top", &.{.{ caseX(lcd_x), caseY(win_y0), outer_h }}, window_chamfer);

    // Button-cap holes, with a counterbore underneath for the caps' flanges
    for (buttons) |b| {
        try s.cylinder("CapHole", .{ caseX(b[0]), caseY(b[1]), top_inner - 1 }, cap_hole_d, top_t + 2, up, .new);
        try cutWith(s, "Top", "CapHole");
        try s.cylinder("CapCounterbore", .{ caseX(b[0]), caseY(b[1]), top_inner - 1 }, cap_flange_d + 0.4, cap_counterbore + 1, up, .new);
        try cutWith(s, "Top", "CapCounterbore");
    }

    try s.chamfer("Top", &.{.{ outer_w / 2, 0, parting_z }}, parting_groove);
}

fn writeCaps(s: *sc.Script) !void {
    const names = [2][]const u8{ "CapUpper", "CapLower" };
    for (buttons, names) |b, name| {
        const x = caseX(b[0]);
        const y = caseY(b[1]);
        const z0 = btn_top + cap_rest_gap;
        try s.cylinder(name, .{ x, y, z0 }, cap_d, outer_h + cap_proud - z0, up, .new);
        try s.cylinder("CapFlange", .{ x, y, top_inner + cap_counterbore - cap_flange_t }, cap_flange_d, cap_flange_t, up, .new);
        try joinWith(s, name, "CapFlange");
        try s.fillet(name, &.{.{ x + cap_d / 2, y, outer_h + cap_proud }}, 0.6);
    }
}

// ---------------------------------------------------------------- the parts we do not print

/// The bought parts at their modelled positions, for the interference check and the pictures.
fn writeElectronics(s: *sc.Script) !void {
    try roundedBox(s, "Board", .{ caseX(0), caseY(0), board_z }, .{ board_w, board_d, board_t }, board_r);
    for ([_]XY{ hole_fl, hole_fr, hole_rr, hole_rl }) |h| {
        try s.cylinder("BoardHole", .{ caseX(h[0]), caseY(h[1]), board_z - 1 }, hole_d, board_t + 2, up, .new);
        try cutWith(s, "Board", "BoardHole");
    }
    // the 40-pin header: its plastic, and the pins of columns 12–19 that the display leaves bare
    try s.box("Header", .{ caseX(header_x0 - header_pitch / 2), caseY(header_y_rear - 1.5 * header_pitch), board_top }, .{ 20 * header_pitch, 2 * header_pitch, header_body_h }, .new);
    try s.box("HeaderPins", .{ caseX(header_x0 + 11.5 * header_pitch), caseY(header_y_rear - 1.5 * header_pitch), header_top }, .{ 8 * header_pitch, 2 * header_pitch, header_h - header_body_h }, .new);
    // the Mini PiTFT: its socket on the header, its board, the display and the two buttons
    try s.box("PiTFTSocket", .{ caseX(header_x0 - header_pitch / 2), caseY(header_y_rear - 1.5 * header_pitch), header_top }, .{ 12 * header_pitch, 2 * header_pitch, header_h - header_body_h }, .new);
    try s.box("PiTFT", .{ caseX(tft_x0), caseY(tft_y0), tft_pcb_z }, .{ tft_w, tft_d, tft_t }, .new);
    try s.box("Display", .{ caseX(lcd_x - tft_lcd_w / 2 - 1), caseY(lcd_y - tft_lcd_h / 2 - 1), tft_pcb_top }, .{ tft_lcd_w + 2, tft_lcd_h + 2, tft_glass_t }, .new);
    for (buttons, [2][]const u8{ "ButtonUpper", "ButtonLower" }) |b, name| {
        try s.cylinder(name, .{ caseX(b[0]), caseY(b[1]), tft_pcb_top }, tft_btn_d, tft_btn_h, up, .new);
    }
    try s.box("PiTFTQwiic", .{ caseX(tft_x0 + tft_qt_x0), caseY(tft_y0 + 0.5), tft_pcb_z - tft_qt_h }, .{ tft_qt_w, tft_qt_d, tft_qt_h }, .new);
    // front-edge receptacles and the BAT connector
    try stadiumY(s, "UsbPower", caseX(usb_cx), usb_cz, usb_body_w, usb_body_h, caseY(-usb_protrusion), caseY(7.3 - usb_protrusion));
    try s.box("PioUsb", .{ caseX(piousb_x0), caseY(-usb_protrusion), board_top }, .{ piousb_x1 - piousb_x0, 7.3, usb_body_h }, .new);
    try s.box("Hdmi", .{ caseX(hdmi_x0), caseY(-usb_protrusion), board_top }, .{ hdmi_x1 - hdmi_x0, 7.5, 3.2 }, .new);
    try s.box("Bat", .{ caseX(bat_x0), caseY(bat_y0), board_top }, .{ board_w - bat_x0, bat_y1 - bat_y0, bat_h }, .new);
    // the four signal wires' bare terminals on the header, with room for the wire to turn
    for (signal_pins) |p| {
        const at = pinXY(p);
        try s.cylinder("Terminal", .{ caseX(at[0]), caseY(at[1]), header_top }, terminal, terminal_h + wire_bend, up, .new);
        try s.appearance(&.{"Terminal"}, "#c03030", 1);
        try s.cmd("body.rename", "\"body\": \"Terminal\", \"name\": \"Terminal{d}\"", .{p});
    }
    // the camera: its board, the HM01B0 module hanging below it, its header and the housings
    try s.box("Camera", .{ caseX(cam_x0), caseY(cam_y0), cam_bottom }, .{ cam_d, cam_w, cam_t }, .new);
    for (cam_holes) |h| {
        try s.cylinder("CamHole", .{ caseX(h[0]), caseY(h[1]), cam_bottom - 1 }, cam_hole_d, cam_t + 2, up, .new);
        try cutWith(s, "Camera", "CamHole");
    }
    const lx = caseX(lens_x);
    const ly = caseY(cam_cy);
    try s.box("LensBody", .{ lx - lens_body / 2, ly - lens_body / 2, cam_bottom - lens_body_h }, .{ lens_body, lens_body, lens_body_h }, .new);
    try s.cylinder("LensCollar", .{ lx, ly, cam_bottom - lens_collar_h }, lens_collar_d, lens_collar_h - lens_body_h, up, .new);
    try joinWith(s, "LensBody", "LensCollar");
    try s.cylinder("LensBarrel", .{ lx, ly, lens_tip }, lens_barrel_d, lens_h - lens_collar_h, up, .new);
    try joinWith(s, "LensBody", "LensBarrel");
    try s.box("CamParts", .{ caseX(cam_x0 + 6), ly - 4, cam_bottom - cam_parts_h }, .{ 4, 3, cam_parts_h }, .new);
    try s.box("CamHeader", .{ caseX(cam_x0), caseY(cam_cy - housing_half), cam_top }, .{ cam_header_h, 2 * housing_half, cam_header_h }, .new);
    try s.box("Housings", .{ caseX(housing_x0), caseY(cam_cy - housing_half), cam_top }, .{ housing_len, 2 * housing_half, housing }, .new);
}

pub const part_bodies = [_][]const u8{ "Base", "Top", "CapUpper", "CapLower" };
pub const electronics_bodies = [_][]const u8{
    "Board",       "Header",     "HeaderPins", "PiTFTSocket", "PiTFT",    "Display",  "ButtonUpper",
    "ButtonLower", "PiTFTQwiic", "UsbPower",   "PioUsb",      "Hdmi",     "Bat",      "Terminal29",
    "Terminal32",  "Terminal33", "Terminal36", "Camera",      "LensBody", "CamParts", "CamHeader",
    "Housings",
};

const provenance = "hardware/enclosure/case.zig (zig run case.zig -- write); edit that file, not this one";

pub fn writeDesign(w: *std.Io.Writer) !void {
    var s = try sc.Script.begin(w, provenance);
    try writeBase(&s);
    try writeTop(&s);
    try writeCaps(&s);
    try s.appearance(&part_bodies, "#d6ecff", 0.35);
    try s.end();
}

/// The design, then the files a builder needs: the STEP of the assembled case and one STL per
/// part to print, the top turned over so its outside face lies on the bed. The paths are
/// relative to where `solidcraft-cli run` is started (hardware/enclosure).
pub fn writeExport(w: *std.Io.Writer) !void {
    var s = try sc.Script.begin(w, provenance);
    try writeBase(&s);
    try writeTop(&s);
    try writeCaps(&s);
    try s.exportFile("zhww-case.step", &part_bodies);
    try s.exportFile("zhww-case-base.stl", &.{"Base"});
    try s.rotate(&.{"Top"}, .{ 1, 0, 0 }, 180);
    try s.move(&.{"Top"}, .{ 0, outer_d, outer_h });
    try s.exportFile("zhww-case-top.stl", &.{"Top"});
    try s.move(&.{"CapUpper"}, .{ 0, 0, -(btn_top + cap_rest_gap) });
    try s.exportFile("zhww-case-cap.stl", &.{"CapUpper"});
    try s.end();
}

/// Two scripts for the pictures in the README (not committed): the case opened up over the
/// parts, and a cut through the lens.
pub fn writeExploded(w: *std.Io.Writer) !void {
    var s = try sc.Script.begin(w, provenance);
    try writeAssembly(&s);
    try s.move(&.{ "Top", "CapUpper", "CapLower" }, .{ 0, 0, 22 });
    try s.end();
}

pub fn writeSection(w: *std.Io.Writer) !void {
    var s = try sc.Script.begin(w, provenance);
    try writeAssembly(&s);
    try s.cmd("inspect.section", "\"plane\": \"XZ\", \"at\": \"{f} mm\", \"flip\": true", .{sc.n(caseY(cam_cy))});
    try s.end();
}

fn writeAssembly(s: *sc.Script) !void {
    try writeBase(s);
    try writeTop(s);
    try writeCaps(s);
    try s.appearance(&part_bodies, "#d6ecff", 0.35);
    try writeElectronics(s);
    try s.appearance(&.{ "Board", "Header", "Camera" }, "#2f6f4f", 1);
    try s.appearance(&.{ "PiTFT", "PiTFTSocket", "ButtonUpper", "ButtonLower", "UsbPower", "PioUsb", "Hdmi", "Bat", "CamHeader", "Housings", "PiTFTQwiic" }, "#303030", 1);
    try s.appearance(&.{ "Display", "LensBody", "CamParts" }, "#101820", 1);
    try s.appearance(&.{"HeaderPins"}, "#c8a040", 1);
}

/// The design with the bought parts in place, and SolidCraft's own interference check over all of
/// them (`zig run case.zig -- verify` reads its result).
pub fn writeCheck(w: *std.Io.Writer) !void {
    var s = try sc.Script.begin(w, provenance);
    try writeAssembly(&s);
    try s.interference(&(part_bodies ++ electronics_bodies));
    try s.end();
}

// ---------------------------------------------------------------- checks

const Check = struct {
    name: []const u8,
    value: f64,
    limit: f64,
    /// true: value must be at least `limit`; false: at most.
    at_least: bool = true,

    fn ok(self: Check) bool {
        return if (self.at_least) self.value >= self.limit - 1e-9 else self.value <= self.limit + 1e-9;
    }
};

fn minPilotMargin() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses) |b| {
        if (b.screw) m = @min(m, top_inner - (b.seat + pilotDepth(b.seat)));
    }
    return m;
}

fn minThread() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses) |b| {
        if (b.screw) m = @min(m, pilotDepth(b.seat) - 1.0);
    }
    return m;
}

/// How far the four corner screws stray from `corner_inset` (from the nearer short end and the
/// nearer long side, measured on the outside of the case).
fn cornerInsetError() f64 {
    var m: f64 = 0;
    for (bosses) |b| {
        if (!b.corner) continue;
        const x = caseX(b.at[0]);
        const y = caseY(b.at[1]);
        m = @max(m, @abs(@min(x, outer_w - x) - corner_inset));
        m = @max(m, @abs(@min(y, outer_d - y) - corner_inset));
    }
    return m;
}

/// Every column against the inner walls; the left-hand ones against the board's left edge and the
/// button caps; the rear-middle one against the board's rear edge, the Mini PiTFT (with its
/// possible overhang) and the bare terminals; the rear-right one against the camera board.
/// The columns' posts in the base: against the inner walls, the board's standoffs and the camera's
/// posts and rests (they stand below the board, so the board itself is not in the way).
fn postClearance() f64 {
    var m: f64 = std.math.inf(f64);
    const r = column_post_d / 2;
    for (bosses) |b| {
        if (!b.post) continue;
        m = @min(m, (b.at[0] - r) + clearance_left);
        m = @min(m, (cam_x1 + cam_clearance) - (b.at[0] + r));
        m = @min(m, (b.at[1] - r) + clearance);
        m = @min(m, (board_d + clearance_rear) - (b.at[1] + r));
        for ([_]XY{ hole_fl, hole_fr, hole_rr, hole_rl }) |h| m = @min(m, std.math.hypot(h[0] - b.at[0], h[1] - b.at[1]) - standoff_d / 2 - r);
        for (cam_holes) |h| m = @min(m, std.math.hypot(h[0] - b.at[0], h[1] - b.at[1]) - cam_post_d / 2 - r);
    }
    return m;
}

fn columnClearance() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses) |b| {
        if (!b.post) continue;
        const r = b.d / 2;
        // inner walls, in board coordinates
        m = @min(m, (b.at[0] - r) + clearance_left);
        m = @min(m, (cam_x1 + cam_clearance) - (b.at[0] + r));
        m = @min(m, (b.at[1] - r) + clearance);
        m = @min(m, (board_d + clearance_rear) - (b.at[1] + r));
        if (b.at[0] < 0) {
            m = @min(m, -(b.at[0] + r)); // the board's left edge (and the Mini PiTFT's, which is further in)
            for (buttons) |c| m = @min(m, std.math.hypot(c[0] - b.at[0], c[1] - b.at[1]) - (cap_flange_d + 0.4) / 2 - r);
        } else if (b.at[0] < board_w) {
            m = @min(m, (b.at[1] - r) - board_d); // the board's rear edge
            m = @min(m, @max((b.at[0] - r) - tft_x1, (b.at[1] - r) - (tft_y1 + 0.75)));
            for (signal_pins) |p| {
                const at = pinXY(p);
                m = @min(m, std.math.hypot(at[0] - b.at[0], at[1] - b.at[1]) - terminal / 2 - r);
            }
        } else {
            m = @min(m, (b.at[1] - r) - cam_y1);
        }
    }
    return m;
}

/// Every countersunk head stays clear of the outer faces it is near.
fn countersinkToOutside() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses) |b| {
        if (!b.screw) continue;
        const x = caseX(b.at[0]);
        const y = caseY(b.at[1]);
        const r = (screw_head_d + 0.3) / 2;
        m = @min(m, @min(x, outer_w - x) - r);
        m = @min(m, @min(y, outer_d - y) - r);
    }
    return m;
}

fn screwHeadsApart() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses, 0..) |a, i| {
        if (!a.screw) continue;
        for (bosses[i + 1 ..]) |b| {
            if (!b.screw) continue;
            m = @min(m, std.math.hypot(a.at[0] - b.at[0], a.at[1] - b.at[1]) - (screw_head_d + 0.3));
        }
    }
    return m;
}

fn lensToScrewHeads() f64 {
    var m: f64 = std.math.inf(f64);
    for (bosses) |b| {
        if (!b.screw) continue;
        m = @min(m, std.math.hypot(b.at[0] - lens_x, b.at[1] - cam_cy) - lens_cs_d / 2 - (screw_head_d + 0.3) / 2);
    }
    return m;
}

/// Where the lens divides the case's depth, from the front edge (0.382 is golden).
const lens_division = caseY(cam_cy) / outer_d;

fn terminalsToHousings() f64 {
    // the terminals stand behind the housings' rear edge, or beside their end
    var m: f64 = std.math.inf(f64);
    const housing_rear = cam_cy + housing_half;
    for (signal_pins) |p| {
        const at = pinXY(p);
        const dy = (at[1] - terminal / 2) - housing_rear;
        const dx = housing_x0 - (at[0] + terminal / 2);
        m = @min(m, @max(dy, dx));
    }
    return m;
}

fn terminalsApart() f64 {
    var m: f64 = std.math.inf(f64);
    for (signal_pins, 0..) |a, i| {
        for (signal_pins[i + 1 ..]) |b| {
            const pa = pinXY(a);
            const pb = pinXY(b);
            m = @min(m, std.math.hypot(pa[0] - pb[0], pa[1] - pb[1]) - terminal);
        }
    }
    return m;
}

const checks = blk: {
    @setEvalBranchQuota(100_000);
    break :blk [_]Check{
        // display, buttons
        .{ .name = "display window inside the Mini PiTFT board (left)", .value = win_x0 - tft_x0, .limit = 0.5 },
        .{ .name = "display window inside the Mini PiTFT board (right)", .value = tft_x1 - (win_x0 + win_w), .limit = 0.5 },
        .{ .name = "display window inside the Mini PiTFT board (front/rear)", .value = @min(win_y0 - tft_y0, tft_y1 - (win_y0 + win_h)), .limit = 0.5 },
        .{ .name = "button-cap counterbore to the display window", .value = win_x0 - (buttons[0][0] + (cap_flange_d + 0.4) / 2), .limit = 0.6 },
        .{ .name = "button-cap counterbore to the inner wall", .value = caseX(buttons[0][0] - (cap_flange_d + 0.4) / 2) - wall, .limit = 0.0 },
        .{ .name = "button caps clear of each other", .value = @abs(buttons[0][1] - buttons[1][1]) - (cap_flange_d + 0.4), .limit = 0.8 },
        .{ .name = "top plate above the display and the buttons", .value = top_inner - tft_tallest, .limit = 0.2 },
        .{ .name = "Mini PiTFT clear of the rear wall (with the .brd's 0.75 mm overhang)", .value = (board_d + clearance_rear) - (tft_y1 + 0.75), .limit = 0.2 },
        .{ .name = "front-left boss flat: material left beside the pilot", .value = (tft_y0 - boss_flat_keepout) - hole_fl[1] - screw_pilot_d / 2, .limit = 0.6 },
        // power USB-C
        .{ .name = "USB-C pocket below the parting groove", .value = parting_z - parting_groove - (usb_cz + usb_pocket_h / 2), .limit = 0.6 },
        .{ .name = "USB-C receptacle fits the opening if it stands out into it", .value = @min(usb_open_w - usb_body_w, usb_open_h - usb_body_h), .limit = 0.4 },
        .{ .name = "USB-C plug: overmould seat to the receptacle mouth", .value = clearance - usb_protrusion + usb_wall_left, .limit = 1.0, .at_least = false },
        .{ .name = "closed receptacles clear of the front wall (relief)", .value = clearance + front_relief - usb_protrusion, .limit = 0.2 },
        // camera
        .{ .name = "camera board beyond the main board", .value = cam_x0 - board_w, .limit = 0.3 },
        .{ .name = "camera board inside the front wall", .value = cam_y0 + clearance, .limit = 0.3 },
        .{ .name = "camera board inside the rear wall", .value = (board_d + clearance_rear) - cam_y1, .limit = 0.3 },
        .{ .name = "camera housings above the BAT connector", .value = cam_top - (board_top + bat_h), .limit = 0.2 },
        .{ .name = "camera housings in front of the 40-pin header", .value = (header_y_rear - 1.5 * header_pitch) - (cam_cy + housing_half), .limit = 0.2 },
        .{ .name = "camera housings below the top plate", .value = top_inner - (cam_top + housing), .limit = 2.0 },
        .{ .name = "camera parts above the floor", .value = @min(lens_tip, cam_bottom - cam_parts_h) - floor_t, .limit = 1.0 },
        .{ .name = "lens view through the floor: at the floor's top", .value = lens_hole_d / 2 - fovRadius(floor_t), .limit = 0.0 },
        .{ .name = "lens view through the floor: at the countersink's edge", .value = lens_hole_d / 2 - fovRadius((lens_cs_d - lens_hole_d) / 2), .limit = 0.0 },
        .{ .name = "lens view through the floor: at the bottom face", .value = lens_cs_d / 2 - fovRadius(0), .limit = 0.0 },
        .{ .name = "camera post clear of the lens module", .value = std.math.hypot(cam_holes[0][0] - lens_x, cam_holes[0][1] - cam_cy) - cam_post_d / 2 - lens_body * std.math.sqrt2 / 2, .limit = 0.5 },
        .{ .name = "camera clamp rib clear of the screw bosses", .value = (cam_holes[0][0] - boss_d / 2) - (cam_x0 + 0.3 + clamp_t), .limit = 1.0 },
        // wiring
        .{ .name = "bare terminals and their wires below the top plate", .value = top_inner - (header_top + terminal_h + wire_bend), .limit = 0.2 },
        .{ .name = "bare terminals clear of the camera housings", .value = terminalsToHousings(), .limit = 0.2 },
        .{ .name = "bare terminals clear of each other", .value = terminalsApart(), .limit = 0.5 },
        .{ .name = "bare terminals right of the Mini PiTFT", .value = pinXY(signal_pins[0])[0] - terminal / 2 - tft_x1, .limit = 0.3 },
        .{ .name = "rear-right boss clear of the camera housings", .value = (hole_rr[1] - boss_d / 2) - (cam_cy + housing_half), .limit = 0.3 },
        // screws and the bottom face
        .{ .name = "the four corner screws all stand the corner inset from both edges", .value = cornerInsetError(), .limit = 0.01, .at_least = false },
        .{ .name = "columns clear of the walls, the board, the Mini PiTFT, the terminals, the caps and the camera", .value = columnClearance(), .limit = 0.2 },
        .{ .name = "column posts: wall round the screw's clearance hole", .value = (column_post_d - screw_clear_d) / 2, .limit = 0.8 },
        .{ .name = "column posts stop below the board", .value = board_z - column_seat, .limit = 0.2 },
        .{ .name = "column posts clear of the walls, the board's standoffs and the camera's posts", .value = postClearance(), .limit = 0.2 },
        .{ .name = "countersunk heads clear of the outer faces", .value = countersinkToOutside(), .limit = 1.5 },
        .{ .name = "lens divides the depth in the golden ratio, from the front edge (0.382 is golden)", .value = @abs(lens_division - golden_minor), .limit = 0.001, .at_least = false },
        .{ .name = "rear-middle screw centred between the rear corner screws", .value = @abs((column_middle - column_left) - (column_right - column_middle)), .limit = 0.01, .at_least = false },
        .{ .name = "lens opening clear of the screw heads", .value = lensToScrewHeads(), .limit = 1.0 },
        .{ .name = "countersunk heads clear of each other", .value = screwHeadsApart(), .limit = 1.0 },
        .{ .name = "screw thread engaged in every boss", .value = minThread(), .limit = 4.0 },
        .{ .name = "every pilot ends below the top plate", .value = minPilotMargin(), .limit = 0.5 },
    };
};

fn report(w: *std.Io.Writer) !bool {
    try w.print("zhww-case: outside {f} x {f} x {f} mm (parting line at z {f}: base {f}, top {f})\n", .{
        sc.n(outer_w), sc.n(outer_d), sc.n(outer_h), sc.n(parting_z), sc.n(parting_z), sc.n(outer_h - parting_z),
    });
    try w.print("zhww-case: stack-up: floor 0..{f} | board {f}..{f} | header to {f} | Mini PiTFT {f}..{f} | glass/buttons to {f} | terminals+wires to {f} | top plate {f}..{f}\n", .{
        sc.n(floor_t), sc.n(board_z), sc.n(board_top), sc.n(header_top), sc.n(tft_pcb_z), sc.n(tft_pcb_top), sc.n(tft_tallest), sc.n(header_top + terminal_h + wire_bend), sc.n(top_inner), sc.n(outer_h),
    });
    try w.print("zhww-case: camera: board {f}..{f} (component side down), lens tip {f}, housings {f}..{f}; lens at case x {f} y {f}\n", .{
        sc.n(cam_bottom), sc.n(cam_top), sc.n(lens_tip), sc.n(cam_top), sc.n(cam_top + housing), sc.n(caseX(lens_x)), sc.n(caseY(cam_cy)),
    });
    var all = true;
    for (checks) |c| {
        const pass = c.ok();
        all = all and pass;
        try w.print("zhww-case: check {s}: {f} mm ({s} {f})  {s}\n", .{
            c.name, sc.n(c.value), if (c.at_least) ">=" else "<=", sc.n(c.limit), if (pass) "PASS" else "FAIL",
        });
    }
    return all;
}

// ---------------------------------------------------------------- main

/// Overlaps the model has on purpose: each bare terminal is drawn as the envelope it occupies, and
/// that envelope contains its header pin.
fn expectedOverlap(a: []const u8, b: []const u8) bool {
    const pins = "HeaderPins";
    return (std.mem.eql(u8, a, pins) and std.mem.startsWith(u8, b, "Terminal")) or
        (std.mem.eql(u8, b, pins) and std.mem.startsWith(u8, a, "Terminal"));
}

/// Faces that only touch (a boss pressing on the board) show up as slivers of this size or less.
const contact_mm3 = 0.01;

/// Reads `solidcraft-cli run zhww-case-check.json --results` and passes only if SolidCraft found
/// no overlap between any two bodies, apart from contacts and the overlaps above.
fn verifyInterference(arena: std.mem.Allocator, text: []const u8, out: *std.Io.Writer) !bool {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const results = parsed.array.items;
    var found: ?std.json.ObjectMap = null;
    for (results) |r| {
        if (r != .object) continue;
        if (r.object.get("interferences") != null) found = r.object;
    }
    const result = found orelse {
        try out.print("zhww-case: no inspect.interference result in the file\n", .{});
        return false;
    };
    var ok = true;
    const unchecked = result.get("unchecked").?.array.items;
    if (unchecked.len != 0) {
        try out.print("zhww-case: {d} body pair(s) could not be checked\n", .{unchecked.len});
        ok = false;
    }
    var allowed: usize = 0;
    for (result.get("interferences").?.array.items) |item| {
        const a = item.object.get("a").?.string;
        const b = item.object.get("b").?.string;
        const volume: f64 = switch (item.object.get("volume_mm3").?) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => return error.InvalidResults,
        };
        if (volume <= contact_mm3 or expectedOverlap(a, b)) {
            allowed += 1;
            continue;
        }
        try out.print("zhww-case: INTERFERENCE {s} x {s}: {f} mm³\n", .{ a, b, sc.n(volume) });
        ok = false;
    }
    const checked = result.get("checked").?.integer;
    try out.print("zhww-case: interference: {d} bodies checked, {d} expected contacts/overlaps, {s}\n", .{ checked, allowed, if (ok) "PASS" else "FAIL" });
    return ok;
}

const outputs = [_]struct { path: []const u8, write: *const fn (*std.Io.Writer) anyerror!void }{
    .{ .path = "zhww-case.json", .write = writeDesign },
    .{ .path = "zhww-case-check.json", .write = writeCheck },
    .{ .path = "zhww-case-export.json", .write = writeExport },
};

const views = [_]struct { path: []const u8, write: *const fn (*std.Io.Writer) anyerror!void }{
    .{ .path = "view-exploded.json", .write = writeExploded },
    .{ .path = "view-section.json", .write = writeSection },
};

pub fn main(init: std.process.Init.Minimal) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);

    const ok = run(init, io, &stdout.interface) catch |err| blk: {
        std.debug.print("case: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    stdout.interface.flush() catch {};
    if (!ok) std.process.exit(1);
}

fn run(init: std.process.Init.Minimal, io: std.Io, out: *std.Io.Writer) !bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.Args.Iterator.init(init.args);
    _ = args.next();
    const mode = args.next() orelse "check";
    if (std.mem.eql(u8, mode, "verify")) {
        const path = args.next() orelse {
            std.debug.print("usage: zig run case.zig -- verify <results.json from solidcraft-cli run zhww-case-check.json --results>\n", .{});
            return false;
        };
        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024 * 1024));
        return verifyInterference(arena, text, out);
    }
    if (std.mem.eql(u8, mode, "views")) {
        const dir = args.next() orelse "build";
        try std.Io.Dir.cwd().createDirPath(io, dir);
        for (views) |v| {
            var generated: std.Io.Writer.Allocating = .init(arena);
            try v.write(&generated.writer);
            const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, v.path });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = generated.written() });
            try out.print("zhww-case: wrote {s}\n", .{path});
        }
        return true;
    }
    const write = std.mem.eql(u8, mode, "write");
    if (!write and !std.mem.eql(u8, mode, "check")) {
        std.debug.print("usage: zig run case.zig -- write|check|views [dir]|verify <results.json>   (from hardware/enclosure)\n", .{});
        return false;
    }

    if (!try report(out)) {
        try out.print("zhww-case: a check failed; nothing written\n", .{});
        return false;
    }

    var all = true;
    for (outputs) |o| {
        var generated: std.Io.Writer.Allocating = .init(arena);
        try o.write(&generated.writer);
        const text = generated.written();
        if (write) {
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = o.path, .data = text });
            try out.print("zhww-case: wrote {s} ({d} bytes)\n", .{ o.path, text.len });
            continue;
        }
        const committed = std.Io.Dir.cwd().readFileAlloc(io, o.path, arena, .limited(16 * 1024 * 1024)) catch |err| {
            try out.print("zhww-case: cannot read {s}: {s} (run from hardware/enclosure)\n", .{ o.path, @errorName(err) });
            all = false;
            continue;
        };
        if (std.mem.eql(u8, committed, text)) {
            try out.print("zhww-case: {s} is up to date\n", .{o.path});
        } else {
            try out.print("zhww-case: {s} differs from case.zig: run `zig run case.zig -- write`\n", .{o.path});
            all = false;
        }
    }
    return all;
}

test "every check passes" {
    for (checks) |c| {
        if (!c.ok()) {
            std.debug.print("FAIL: {s}: {d}\n", .{ c.name, c.value });
            return error.CheckFailed;
        }
    }
}

test "header pins map to the two rows" {
    try std.testing.expectEqual(XY{ header_x0, header_y_rear - header_pitch }, pinXY(1));
    try std.testing.expectEqual(XY{ header_x0, header_y_rear }, pinXY(2));
    try std.testing.expectApproxEqAbs(header_x0 + 17 * header_pitch, pinXY(36)[0], 1e-9);
    try std.testing.expectEqual(header_y_rear, pinXY(36)[1]);
}

test "the scripts are valid JSON with every part in them" {
    for (outputs) |o| {
        var generated: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer generated.deinit();
        try o.write(&generated.writer);
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, generated.written(), .{});
        defer parsed.deinit();
        const commands = parsed.value.object.get("commands").?.array.items;
        try std.testing.expect(commands.len > 40);
    }
}
