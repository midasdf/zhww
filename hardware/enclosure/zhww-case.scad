// zhww の筐体（OpenSCAD・パラメトリック）
//
// 構成: RP2350-PiZero（65 × 30mm）＋ Waveshare 1.3inch LCD HAT を上下 2 分割で収める。
//       電池は積まない（USB 外部給電）。
//
// **座標の約束**: x は基板の長辺（0 = 左端、65 = 右端）、y は短辺（0 = 手前＝USB 側の辺、
// 30 = 奥＝40pin ヘッダ側）、z は高さ（0 = 基板の下面）。
//
// ## 寸法の出所（重要）
//
// 大半は**公式の寸法図と製品写真から読み取った値**で、ノギスでの実測はまだ。
// 実測したら `MEASURED` の印がある値を更新すること。
//
//   - 基板外形 65.00 × 30.00mm、取付穴 Φ3.00、40pin ヘッダ 2.54mm ピッチ
//     … Waveshare RP2350-PiZero の寸法図（wiki の Dimensions 画像）
//     https://www.waveshare.com/wiki/RP2350-PiZero
//   - コネクタの位置（手前の長辺に 3 つ、左の短辺に microSD、右の短辺に BAT 2pin）
//     … 同じ寸法図。**図からの読み取り値**なので実測で確認する
//   - HAT 65 × 30.2mm、表示領域 23.4 × 23.4mm
//     … Waveshare 1.3inch LCD HAT の wiki（Dimension / Specification）
//   - HAT 上の配置（左端に KEY が縦一列、中央に LCD、右端にジョイスティック）
//     … 製品写真からの読み取り。**実測で確認する**
//
// ## ライセンス
//
// CC-BY-SA-4.0（リポジトリの LICENSE-ENCLOSURE）

// ---------------------------------------------------------------- 基板

board_w = 65.0;         // 長辺（公式図より）
board_d = 30.0;         // 短辺（公式図より）
board_t = 1.6;          // 基板の厚み（一般的な値）
corner_r = 3.0;         // 基板の角の丸み（図から）

// 取付穴（Pi Zero と同じ配置と仮定。MEASURED: ノギスで確認する）
hole_d = 3.0;           // Φ3.00（公式図より）
hole_inset = 3.5;       // 端から穴中心まで（Pi Zero の標準。MEASURED）

// 40pin ヘッダ（奥の長辺に沿って）
header_h = 8.5;         // メスソケットを挿したときの高さ（MEASURED）
header_pitch = 2.54;    // 公式図より

// ---------------------------------------------------------------- コネクタ（手前の長辺）

// 公式図からの読み取り値（MEASURED: 実測で確認）
usb_c_w = 9.0;          // USB-C の穴
usb_c_h = 3.6;
usb_c1_x = 33.0;        // PIO-USB 側の左端
usb_c2_x = 47.0;        // USB 側の左端
hdmi_w = 11.0;          // mini HDMI（一番左）
hdmi_h = 3.0;
hdmi_x = 8.0;

// 左の短辺の microSD スロット（カードは左から挿す）
sd_h = 3.0;             // スロットの高さ
sd_y0 = 6.0;            // スロットの前端
sd_len = 14.0;          // スロットの長さ（y 方向）

// 右の短辺の BAT コネクタ（任意改造で LiPo を使う場合に備えて開口しておく）
bat_w = 8.0;
bat_h = 4.0;
bat_y0 = 11.0;

// ---------------------------------------------------------------- HAT（上に載る）

hat_t = 1.6;
// 表示窓（HAT の中央やや左。MEASURED）
display_size = 23.4;    // 表示領域（wiki より）
display_x = 13.0;       // HAT 左端から
display_y = 3.3;        // HAT 前端から

// 左端に縦一列の 3 ボタン（KEY1〜3。MEASURED: 写真からの読み取り）
button_d = 5.2;
button_x = 5.0;
button_y = [7.0, 15.0, 23.0];

// 右端のジョイスティック（MEASURED: 写真からの読み取り）
joystick_d = 8.0;
joystick_x = 55.0;
joystick_y = 15.0;

// ---------------------------------------------------------------- ケース

wall = 2.0;             // 肉厚
clearance = 0.4;        // 基板とケースの遊び
floor_t = 2.0;          // 底板
inner_w = board_w + clearance * 2;
inner_d = board_d + clearance * 2;
inner_h = board_t + header_h + hat_t + 2.0;
screw_d = 2.2;          // M2.5 の下穴

$fn = 48;

// ---------------------------------------------------------------- 部品

module rounded_box(w, d, h, r = 2) {
    hull() {
        for (x = [r, w - r], y = [r, d - r])
            translate([x, y, 0]) cylinder(r = r, h = h);
    }
}

// 基板の四隅の取付穴に合わせたボス（上蓋をネジ止めする）
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

// 下側（トレイ）
module tray() {
    difference() {
        union() {
            rounded_box(inner_w + wall * 2, inner_d + wall * 2, inner_h + floor_t, corner_r);
            // 上蓋と噛み合う内側のリップ
            translate([wall + 0.6, wall + 0.6, inner_h + floor_t - 1.5])
                rounded_box(inner_w - 1.2, inner_d - 1.2, 1.5, corner_r / 2);
        }

        // 内側をくり抜く
        translate([wall, wall, floor_t])
            rounded_box(inner_w, inner_d, inner_h + 2, corner_r / 2);

        // 手前の長辺: mini HDMI / USB-C ×2
        translate([wall + clearance + hdmi_x, -1, floor_t + 2.5])
            cube([hdmi_w, wall + 2, hdmi_h]);
        translate([wall + clearance + usb_c1_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);
        translate([wall + clearance + usb_c2_x, -1, floor_t + 2.5])
            cube([usb_c_w, wall + 2, usb_c_h]);

        // 左の短辺: microSD
        translate([-1, wall + clearance + sd_y0, floor_t + 1.5])
            cube([wall + 2, sd_len, sd_h]);

        // 右の短辺: BAT（任意の LiPo 用）
        translate([inner_w + wall - 1, wall + clearance + bat_y0, floor_t + 1.5])
            cube([wall + 2, bat_w, bat_h]);
    }

    bosses();
}

// 上蓋
module lid() {
    difference() {
        union() {
            translate([0, 0, inner_h + floor_t])
                rounded_box(inner_w + wall * 2, inner_d + wall * 2, wall, corner_r);
            translate([wall - 0.2, wall - 0.2, inner_h + floor_t - 1.5])
                rounded_box(inner_w + 0.4, inner_d + 0.4, 1.5, corner_r / 2);
        }

        // 表示窓
        translate([wall + clearance + display_x, wall + clearance + display_y,
                   inner_h + floor_t - 1])
            cube([display_size, display_size, wall + 3]);

        // 3 ボタン（左端に縦一列）
        for (y = button_y)
            translate([wall + clearance + button_x, wall + clearance + y,
                       inner_h + floor_t - 1])
                cylinder(d = button_d, h = wall + 3);

        // ジョイスティック
        translate([wall + clearance + joystick_x, wall + clearance + joystick_y,
                   inner_h + floor_t - 1])
            cylinder(d = joystick_d, h = wall + 3);

        // ネジ穴（ボスに合わせる）
        for (p = [[hole_inset, hole_inset],
                  [board_w - hole_inset, hole_inset],
                  [hole_inset, board_d - hole_inset],
                  [board_w - hole_inset, board_d - hole_inset]])
            translate([wall + clearance + p[0], wall + clearance + p[1],
                       inner_h + floor_t - 1])
                cylinder(d = screw_d, h = wall + 3);
    }
}

// ---------------------------------------------------------------- 出力

part = "all";   // "tray" / "lid" / "all"（-D 'part="lid"' で切り替え）

if (part == "all") {
    tray();
    translate([0, inner_d + wall * 2 + 10, 0]) lid();
} else if (part == "tray") {
    tray();
} else if (part == "lid") {
    lid();
}
