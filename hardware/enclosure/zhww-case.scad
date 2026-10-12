// zhww の筐体（OpenSCAD・パラメトリック）
//
// 構成: Raspberry Pi Zero 形状の RP2350-PiZero（65 × 30mm）＋ Waveshare 1.3inch LCD HAT を
//       上下 2 分割のケースに収める。電池は積まない（USB 外部給電）。
//
// **注意（重要）**: 穴の位置の一部は**まだ実測していない**。
// 実機が届いたら `// --- 実測して埋める ---` の印があるパラメータを測って更新すること。
// この環境に OpenSCAD が無いため、**このファイルはまだレンダリングしていない**。
//
// 参考にした公開情報:
//   - RP2350-PiZero の寸法: 65 × 30mm（Waveshare wiki / CNX Software の紹介記事）
//   - 1.3inch LCD HAT の寸法: 65 × 30.2mm、表示領域 23.4 × 23.4mm（Waveshare wiki）
//   - 筐体の作り方は SeedSigner のコミュニティ製ケースを参考にした（下記 README に出典）
//
// ライセンス: CC-BY-SA-4.0（リポジトリの LICENSE-ENCLOSURE を参照）

// ---------------------------------------------------------------- パラメータ

// 基板と HAT
board_w = 65.0;         // 基板の幅（40pin ヘッダ側が上）
board_d = 30.0;         // 基板の奥行き
hat_w = 65.0;           // HAT の幅
hat_d = 30.2;           // HAT の奥行き
board_t = 1.6;          // 基板の厚み
hat_t = 1.6;            // HAT の基板厚
header_h = 8.5;         // 40pin ヘッダ＋ソケットの高さ（実測して調整）

// ケース
wall = 2.0;             // 肉厚
clearance = 0.4;        // 各部の遊び
floor_t = 2.0;          // 底板の厚み
inner_w = board_w + clearance * 2;
inner_d = board_d + clearance * 2;
inner_h = board_t + header_h + hat_t + 2.0;  // 基板＋ヘッダ＋HAT＋余裕

// 表示窓（HAT 上の LCD の位置に合わせる）
// --- 実測して埋める ---
display_size = 23.4;    // 表示領域（公開情報より）
display_x = 3.0;        // HAT 左端から LCD 左端まで（未実測・仮）
display_y = 3.0;        // HAT 手前端から LCD 手前端まで（未実測・仮）

// 操作部（HAT 上のジョイスティックと 3 ボタン）
// --- 実測して埋める（位置は仮。SeedSigner のケースはボタンキャップ方式なので同じ考え方）---
joystick_d = 8.0;       // ジョイスティックの穴の直径
joystick_x = 46.0;      // HAT 左端から（LCD の右側に置く想定。実測して確定）
joystick_y = 8.0;       // HAT 手前端から
button_d = 5.2;         // タクトスイッチの穴
button1_x = 40.0;  button1_y = 24.0;
button2_x = 48.0;  button2_y = 24.0;
button3_x = 56.0;  button3_y = 24.0;

// ポート（RP2350-PiZero: USB-C ×2、mini HDMI、microSD、BOOT / RUN）
// --- 実測して埋める（Pi Zero とは位置が違うため、SeedSigner のケースの穴はそのまま使えない）---
usb_c_w = 9.5;          // USB-C コネクタの幅
usb_c_h = 4.0;          // 高さ
usb_c1_y = 6.0;         // 手前端からの位置
usb_c2_y = 18.0;
hdmi_w = 12.0;          // mini HDMI
hdmi_h = 3.5;
hdmi_y = 4.0;
sd_w = 12.5;            // microSD スロット
sd_h = 2.5;
sd_y = 8.0;

$fn = 48;

// ---------------------------------------------------------------- 本体（下側）

module tray() {
    difference() {
        // 外殻
        rounded_box(inner_w + wall * 2, inner_d + wall * 2, inner_h + floor_t);

        // 内側をくり抜く
        translate([wall, wall, floor_t])
            rounded_box(inner_w, inner_d, inner_h + 1);

        // ポートの穴（右側面に開ける。向きは実機で確認する）
        // USB-C ×2
        translate([inner_w + wall * 2 - wall - 1, wall + usb_c1_y, floor_t + 3])
            cube([wall + 2, usb_c_w, usb_c_h]);
        translate([inner_w + wall * 2 - wall - 1, wall + usb_c2_y, floor_t + 3])
            cube([wall + 2, usb_c_w, usb_c_h]);
        // mini HDMI
        translate([inner_w + wall * 2 - wall - 1, wall + hdmi_y, floor_t + 3])
            cube([wall + 2, hdmi_w, hdmi_h]);
        // microSD（左側面）
        translate([-1, wall + sd_y, floor_t + 2])
            cube([wall + 2, sd_w, sd_h]);
    }

    // HAT を押さえる支柱（基板の四隅。高さは実測して調整する）
    posts();
}

// ---------------------------------------------------------------- 上蓋

module lid() {
    difference() {
        union() {
            translate([0, 0, inner_h + floor_t])
                rounded_box(inner_w + wall * 2, inner_d + wall * 2, wall);
            // 噛み合わせ（内側に少し入る）
            translate([wall - 0.2, wall - 0.2, inner_h + floor_t - 1.5])
                rounded_box(inner_w + 0.4, inner_d + 0.4, 1.5);
        }

        // 表示窓
        translate([wall + display_x, wall + display_y, inner_h + floor_t - 1])
            cube([display_size, display_size, wall + 3]);

        // 操作部の穴
        translate([wall + joystick_x, wall + joystick_y, inner_h + floor_t - 1])
            cylinder(d = joystick_d, h = wall + 3);
        for (p = [[button1_x, button1_y], [button2_x, button2_y], [button3_x, button3_y]])
            translate([wall + p[0], wall + p[1], inner_h + floor_t - 1])
                cylinder(d = button_d, h = wall + 3);
    }
}

// HAT を押さえる 4 本の支柱（HAT 上面から上蓋まで）
module posts() {
    for (p = [[4, 4], [inner_w - 4, 4], [4, inner_d - 4], [inner_w - 4, inner_d - 4]])
        translate([wall + p[0], wall + p[1], inner_h + floor_t - 2])
            cylinder(d = 4, h = 2);
}

// ---------------------------------------------------------------- 部品

module rounded_box(w, d, h, r = 2) {
    hull() {
        for (x = [r, w - r], y = [r, d - r])
            translate([x, y, 0]) cylinder(r = r, h = h);
    }
}

// 表示する部品を切り替える（コマンドラインで -D 'part="lid"' でもよい）
part = "all";   // "tray" / "lid" / "all"

if (part == "all") {
    tray();
    translate([0, inner_d + wall * 2 + 10, 0]) lid();
} else if (part == "tray") {
    tray();
} else if (part == "lid") {
    lid();
}
