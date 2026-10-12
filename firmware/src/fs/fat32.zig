//! FAT32 のマウントと読み書き（microSD で PSBT を受け渡すための最小限）。
//!
//! **対応する範囲**
//! - マウント: MBR の先頭 4 エントリから FAT32 パーティションを探す。
//!   パーティションテーブルの無いスーパーフロッピーも受け付ける。
//! - BPB: セクタ長 512 のみ。クラスタ長は 1〜128 セクタ（2 の冪）。
//! - ファイル一覧（サブディレクトリを含む）、読み出し（FAT チェーンを辿る。
//!   断片化していてもよい）、書き込み（新規・上書き）、削除、リネーム
//! - 長いファイル名（LFN / VFAT）の読み書き。UTF-8 ↔ UTF-16 の変換を含む。
//!   `IN.PSBT` は拡張子が 4 文字なので 8.3 に収まらず、**必ず LFN になる**。
//! - パスは `/` 区切りの絶対パス。大文字小文字は ASCII の範囲で畳み込む
//!   （FAT の慣習。LFN の非 ASCII はバイト単位で比較する）。
//!
//! **対応しない範囲**（意図的に実装していない）
//! - FAT12 / FAT16 / exFAT（`error.UnsupportedFatType`）
//! - セクタ長 512 以外（`error.InvalidEncoding`）
//! - サブディレクトリの作成（既存ディレクトリへの書き込みは可）
//! - 日付・時刻の設定（1980-01-01 固定、時刻は 0）
//! - 断片化の最適化（空きクラスタを順に探すだけ）
//! - chkdsk 相当の検証（FAT 2 枚の一致や FSInfo の正しさは検査しない）
//! - 別ディレクトリへの移動（リネームは同じディレクトリ内のみ）
//! - `..` を含むパス、ドライブ文字、`\` 区切り、相対パス
//! - 書き込みの原子性（電源断では空のファイルや未接続クラスタが残りうる）
//! - ミラーリング無効（`BPB_ExtFlags` の bit7）のボリュームでは、有効な
//!   FAT コピーだけを読み書きする（両方に書くと壊すため）
//!
//! **メモリ**
//! - マウント時に 1 クラスタ分（セクタ長 × クラスタあたりセクタ数）だけ
//!   アロケータから確保する。ファイル全体を載せるバッファは持たない。
//! - ディレクトリ走査は呼び出し側が用意した `Iterator`（約 1.1KB）で行う。
//! - 書き込み系の一時領域は最大 4KB 程度（`Iterator` + `Entry` + 名前バッファ）。
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const block_device = @import("block_device.zig");
const BlockDevice = block_device.BlockDevice;
const sector_size = block_device.sector_size;

/// LFN の上限（UTF-16 コード単位）。FAT の仕様で 255。
pub const max_name_utf16 = 255;
/// LFN 名を UTF-8 で表すのに必要な最大長（1 コード単位あたり最大 3 バイト）。
pub const max_name_utf8 = max_name_utf16 * 3;

const entry_size = 32;
const entries_per_sector = sector_size / entry_size;
/// LFN 1 エントリに入る UTF-16 コード単位の数。
const lfn_chars = 13;
/// 255 コード単位を格納するのに必要な LFN エントリ数の上限。
const max_lfn_entries = (max_name_utf16 + lfn_chars - 1) / lfn_chars;

const attr_read_only: u8 = 0x01;
const attr_hidden: u8 = 0x02;
const attr_system: u8 = 0x04;
const attr_volume_id: u8 = 0x08;
const attr_directory: u8 = 0x10;
const attr_archive: u8 = 0x20;
/// LFN エントリの属性（READ_ONLY|HIDDEN|SYSTEM|VOLUME_ID）。
const attr_lfn: u8 = attr_read_only | attr_hidden | attr_system | attr_volume_id;

/// 削除済みエントリの先頭バイト。
const entry_free: u8 = 0xE5;
/// ディレクトリの終端を表す先頭バイト。
const entry_end: u8 = 0x00;

/// FAT の値として使うマスク（上位 4 ビットは予約）。
const fat_mask: u32 = 0x0FFFFFFF;
/// 不良クラスタ。
const fat_bad: u32 = 0x0FFFFFF7;
/// チェーンの終端（これ以上は EOC）。
const fat_eoc_min: u32 = 0x0FFFFFF8;
/// 空きクラスタ。
const fat_free: u32 = 0;

/// FSInfo で「不明」を表す値。
const value_unknown: u32 = 0xFFFFFFFF;
/// FSInfo の署名。
const fsinfo_lead_signature: u32 = 0x41615252;
const fsinfo_struct_signature: u32 = 0x61417272;
const fsinfo_trail_signature: u32 = 0xAA550000;

/// 書き込むエントリの日付（1980-01-01）。時刻は設定しない（0）。
const default_date: u16 = (1 << 5) | 1;

/// FAT32 のエラー。`InvalidEncoding` / `BufferTooSmall` / `Truncated` /
/// `OutOfMemory` は `core/errors.zig` と同じ値を使う（画面表示の都合）。
pub const Error = block_device.Error || error{
    /// BPB・名前・UTF-8/UTF-16 の書式が不正
    InvalidEncoding,
    /// 絶対パスでない、".." を含む、名前が空など
    InvalidPath,
    /// 名前が FAT の上限（UTF-16 で 255 コード単位）を超えた
    NameTooLong,
    /// 出力バッファが足りない
    BufferTooSmall,
    /// デバイスがファイルシステムより小さい
    Truncated,
    /// メモリ確保に失敗した
    OutOfMemory,
    /// FAT32 ではない
    NotFat32,
    /// FAT12 / FAT16 / exFAT（FAT32 でないと分かっている場合）
    UnsupportedFatType,
    /// FAT チェーンの循環・範囲外・フリークラスタなど、構造が壊れている
    CorruptChain,
    /// 指定パスのエントリが無い
    NotFound,
    /// ファイルではない（ディレクトリ・ボリュームラベル）
    NotAFile,
    /// ディレクトリに対する操作が不正
    IsDirectory,
    /// ディレクトリではないものの中を辿ろうとした
    NotADirectory,
    /// 空きクラスタが無い
    NoFreeCluster,
    /// 空きエントリが無い、または 8.3 の別名を 999999 通り試しても空きが無い
    NameCollision,
    /// 名前が既に使われている（リネーム先など）
    AlreadyExists,
};

// ---------------------------------------------------------------------------
// BPB（BIOS Parameter Block）
// ---------------------------------------------------------------------------

/// FAT32 の BPB と、そこから導かれる配置。
pub const Bpb = struct {
    /// ボリュームの先頭セクタ（スーパーフロッピーは 0）。
    partition_sector: u32,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    sectors_per_fat: u32,
    root_cluster: u32,
    /// パーティション内の総セクタ数。
    total_sectors: u32,
    fs_info_sector: u16,
    backup_boot_sector: u16,
    /// 1 つ目の FAT の先頭セクタ（絶対 LBA）。
    fat_sector: u32,
    /// データ領域の先頭セクタ（絶対 LBA）。
    data_sector: u32,
    /// データ領域のクラスタ数。クラスタ番号は 2 〜 `cluster_count + 1`。
    cluster_count: u32,
    /// 使用する FAT コピー（ミラーリング無効のときだけ 0 以外）。
    active_fat: u8,
    /// FAT がミラーリングされているか（両方のコピーを更新してよいか）。
    mirrored: bool,
    volume_label: [11]u8,

    pub fn clusterSize(self: *const Bpb) usize {
        return @as(usize, self.sectors_per_cluster) * sector_size;
    }

    /// 有効なクラスタ番号の上限。
    pub fn maxCluster(self: *const Bpb) u32 {
        return self.cluster_count + 1;
    }

    /// クラスタ番号から先頭セクタ（絶対 LBA）を求める。範囲は呼び出し側で検証する。
    pub fn clusterToSector(self: *const Bpb, cluster: u32) u32 {
        std.debug.assert(cluster >= 2 and cluster <= self.maxCluster());
        const offset = @as(u64, cluster - 2) * @as(u64, self.sectors_per_cluster);
        return @intCast(@as(u64, self.data_sector) + offset);
    }

    /// 指定した FAT コピーの中での `cluster` のエントリがあるセクタ。
    pub fn fatSectorOf(self: *const Bpb, cluster: u32, copy: u8) u32 {
        const byte_offset = @as(u64, cluster) * 4;
        const sector_offset = byte_offset / sector_size;
        return @intCast(@as(u64, self.fat_sector) + @as(u64, copy) * @as(u64, self.sectors_per_fat) + sector_offset);
    }

    /// セクタ内のエントリ位置（バイト）。
    pub fn fatOffsetOf(cluster: u32) usize {
        return (@as(usize, cluster) * 4) % sector_size;
    }
};

/// 起動セクタを BPB として解釈する。FAT12/16/exFAT は専用のエラーで弾く。
fn parseBpb(sector: *const [sector_size]u8, partition_sector: u32, device_sectors: u64) Error!Bpb {
    if (sector[510] != 0x55 or sector[511] != 0xAA) return error.InvalidEncoding;
    if (std.mem.eql(u8, sector[3..11], "EXFAT   ")) return error.UnsupportedFatType;

    const bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little);
    if (bytes_per_sector != sector_size) return error.InvalidEncoding;

    const sectors_per_cluster = sector[13];
    if (sectors_per_cluster == 0 or sectors_per_cluster > 128) return error.InvalidEncoding;
    if (sectors_per_cluster & (sectors_per_cluster - 1) != 0) return error.InvalidEncoding;

    const reserved_sectors = std.mem.readInt(u16, sector[14..16], .little);
    if (reserved_sectors == 0) return error.InvalidEncoding;

    const fat_count = sector[16];
    if (fat_count == 0 or fat_count > 4) return error.InvalidEncoding;

    const root_entries = std.mem.readInt(u16, sector[17..19], .little);
    const total_16 = std.mem.readInt(u16, sector[19..21], .little);
    const fat_16 = std.mem.readInt(u16, sector[22..24], .little);
    const total_32 = std.mem.readInt(u32, sector[32..36], .little);
    const fat_32 = std.mem.readInt(u32, sector[36..40], .little);

    // FAT12 / FAT16 はルートディレクトリが固定長（root_entries != 0）で、
    // FAT 長が 16 ビット側に入る。exFAT は OEM 名で弾いてある。
    if (fat_32 == 0 or root_entries != 0) {
        if (fat_16 != 0 or root_entries != 0) return error.UnsupportedFatType;
        return error.InvalidEncoding;
    }

    const total_sectors: u32 = if (total_16 != 0) total_16 else total_32;
    if (total_sectors == 0) return error.InvalidEncoding;

    const overhead = @as(u64, reserved_sectors) + @as(u64, fat_32) * @as(u64, fat_count);
    if (overhead >= @as(u64, total_sectors)) return error.InvalidEncoding;
    const data_sectors: u32 = @intCast(@as(u64, total_sectors) - overhead);
    const cluster_count = data_sectors / @as(u32, sectors_per_cluster);
    if (cluster_count == 0) return error.InvalidEncoding;

    // FAT が全クラスタ番号を保持できるか（1 セクタ = 128 エントリ）。
    const fat_entries = @as(u64, fat_32) * (sector_size / 4);
    if (fat_entries < @as(u64, cluster_count) + 2) return error.InvalidEncoding;

    const root_cluster = std.mem.readInt(u32, sector[44..48], .little);
    if (root_cluster < 2 or root_cluster > cluster_count + 1) return error.InvalidEncoding;

    if (@as(u64, partition_sector) + @as(u64, total_sectors) > device_sectors) return error.Truncated;

    // ミラーリング無効なら有効な FAT コピーだけを使う。
    const ext_flags = std.mem.readInt(u16, sector[40..42], .little);
    const mirrored = (ext_flags & 0x0080) == 0;
    const active_fat: u8 = @intCast(ext_flags & 0x000F);
    if (active_fat >= fat_count) return error.InvalidEncoding;

    const fs_info_sector = std.mem.readInt(u16, sector[48..50], .little);
    const backup_boot_sector = std.mem.readInt(u16, sector[50..52], .little);
    const fat_sector: u32 = partition_sector + @as(u32, reserved_sectors);

    return .{
        .partition_sector = partition_sector,
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sectors = reserved_sectors,
        .fat_count = fat_count,
        .sectors_per_fat = fat_32,
        .root_cluster = root_cluster,
        .total_sectors = total_sectors,
        .fs_info_sector = fs_info_sector,
        .backup_boot_sector = backup_boot_sector,
        .fat_sector = fat_sector,
        .data_sector = fat_sector + @as(u32, fat_count) * fat_32,
        .cluster_count = cluster_count,
        .active_fat = active_fat,
        .mirrored = mirrored,
        .volume_label = sector[71..82].*,
    };
}

// ---------------------------------------------------------------------------
// ディレクトリエントリ
// ---------------------------------------------------------------------------

/// ディレクトリエントリ 1 件。`name` は LFN があればそれ、無ければ 8.3 を
/// UTF-8 にしたもの。名前のスライスは `nameSlice()` で取る。
pub const Entry = struct {
    name: [max_name_utf8]u8 = @splat(0),
    name_len: u16 = 0,
    /// 生の 11 バイト短名（先頭 0x05 は 0xE5 に補正済み）。
    short_name: [11]u8 = @splat(' '),
    /// 短名の NT ケースフラグ（bit3: 基底が小文字、bit4: 拡張子が小文字）。
    case_flags: u8 = 0,
    attr: u8 = 0,
    /// 検証済みの LFN が付いていたか。
    has_lfn: bool = false,
    /// 短名エントリの直前にある、検証済みの連続 LFN エントリ数。
    lfn_count: u8 = 0,
    first_cluster: u32 = 0,
    size: u32 = 0,
    /// ディレクトリ内の線形エントリ番号（削除・リネームで使う）。
    index: u32 = 0,
    /// 短名エントリのあるセクタ（絶対 LBA）。
    sector: u32 = 0,
    /// そのセクタ内のオフセット（32 の倍数）。
    offset: u16 = 0,

    pub fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isDirectory(self: *const Entry) bool {
        return self.attr & attr_directory != 0;
    }

    pub fn isVolumeLabel(self: *const Entry) bool {
        return self.attr & attr_volume_id != 0 and self.attr & attr_directory == 0;
    }

    /// "." または ".."（一覧に出すかどうかは呼び出し側が決める）。
    pub fn isDot(self: *const Entry) bool {
        if (self.short_name[0] != '.') return false;
        const dots: usize = if (self.short_name[1] == '.') 2 else 1;
        for (self.short_name[dots..]) |c| {
            if (c != ' ') return false;
        }
        return true;
    }

    /// 8.3 名（NT ケースフラグを反映した表示用）。`buffer` は 12 バイト以上。
    pub fn shortDisplay(self: *const Entry, buffer: *[12]u8) []const u8 {
        var base_len: usize = 8;
        while (base_len > 0 and self.short_name[base_len - 1] == ' ') base_len -= 1;
        var ext_len: usize = 3;
        while (ext_len > 0 and self.short_name[8 + ext_len - 1] == ' ') ext_len -= 1;

        const base_lower = (self.case_flags & 0x08) != 0;
        const ext_lower = (self.case_flags & 0x10) != 0;
        var len: usize = 0;
        for (self.short_name[0..base_len]) |c| {
            buffer[len] = if (base_lower) std.ascii.toLower(c) else c;
            len += 1;
        }
        if (ext_len > 0) {
            buffer[len] = '.';
            len += 1;
            for (self.short_name[8 .. 8 + ext_len]) |c| {
                buffer[len] = if (ext_lower) std.ascii.toLower(c) else c;
                len += 1;
            }
        }
        return buffer[0..len];
    }
};

/// 一覧の走査で使う 1 クラスタ分の状態をまとめたもの。
const ClusterCursor = struct {
    fs: *Fat32,
    cluster: u32,
    sector_in_cluster: u16 = 0,
    steps: u32 = 0,

    fn init(fs: *Fat32, cluster: u32) ClusterCursor {
        return .{ .fs = fs, .cluster = cluster };
    }

    /// このクラスタの次を返す。チェーンが終端なら null。循環は `CorruptChain`。
    fn advance(self: *ClusterCursor) Error!?u32 {
        self.steps += 1;
        if (self.steps > self.fs.bpb.cluster_count) return error.CorruptChain;
        const successor = try self.fs.fatGet(self.cluster);
        if (successor == fat_bad or successor == fat_free or successor == 1) return error.CorruptChain;
        if (successor >= fat_eoc_min) return null;
        if (successor > self.fs.bpb.maxCluster()) return error.CorruptChain;
        self.cluster = successor;
        self.sector_in_cluster = 0;
        return successor;
    }
};

// ---------------------------------------------------------------------------
// ファイル名（8.3 と LFN）
// ---------------------------------------------------------------------------

/// 書き込む名前の準備結果。
const NameInfo = struct {
    units: [max_name_utf16]u16 = @splat(0),
    unit_count: u16 = 0,
    short_name: [11]u8 = @splat(' '),
    /// 短名の直前に書く LFN エントリ数（0 なら 8.3 のみ）。
    lfn_count: u8 = 0,
};

/// LFN のチェックサム（11 バイト短名から）。
fn shortNameChecksum(short: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| sum = (sum >> 1) +% ((sum & 1) << 7) +% c;
    return sum;
}

/// LFN エントリ内で `index` 番目（0〜12）のコード単位が入るオフセット。
fn lfnCharOffset(index: usize) usize {
    if (index < 5) return 1 + index * 2;
    if (index < 11) return 14 + (index - 5) * 2;
    return 28 + (index - 11) * 2;
}

fn isShortChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', '0'...'9' => true,
        '$', '%', '\'', '-', '_', '@', '~', '!', '(', ')', '^', '#', '&', '{', '}', '`' => true,
        else => false,
    };
}

/// 8.3 としてそのまま使える名前か（大文字のみ・8+3 以内・使える文字のみ）。
fn isPlainShortName(name: []const u8) bool {
    if (name.len == 0 or name.len > 12) return false;
    if (name[0] == '.') return false;
    if (name[name.len - 1] == '.') return false;
    var base_len: usize = 0;
    var ext_len: usize = 0;
    var seen_dot = false;
    for (name) |c| {
        if (c == '.') {
            if (seen_dot) return false;
            seen_dot = true;
            continue;
        }
        if (!isShortChar(c)) return false;
        if (seen_dot) ext_len += 1 else base_len += 1;
    }
    if (base_len == 0 or base_len > 8 or ext_len > 3) return false;
    return !isReservedDeviceName(name);
}

/// Windows が特別扱いする名前（8.3 では使わせない）。
fn isReservedDeviceName(name: []const u8) bool {
    var buffer: [8]u8 = @splat(0);
    var len: usize = 0;
    for (name) |c| {
        if (c == '.') break;
        if (len == buffer.len) return false;
        buffer[len] = c;
        len += 1;
    }
    const base = buffer[0..len];
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (std.mem.eql(u8, base, reserved)) return true;
    }
    if (base.len == 4 and (base[3] >= '1' and base[3] <= '9')) {
        if (std.mem.eql(u8, base[0..3], "COM") or std.mem.eql(u8, base[0..3], "LPT")) return true;
    }
    return false;
}

/// 8.3 の 11 バイト（"NAME    EXT"）を作る。`isPlainShortName` が真の名前だけを渡す。
fn plainShortFromName(name: []const u8) [11]u8 {
    var out: [11]u8 = @splat(' ');
    var base_index: usize = 0;
    var ext_index: usize = 8;
    var in_ext = false;
    for (name) |c| {
        if (c == '.') {
            in_ext = true;
            continue;
        }
        if (in_ext) {
            out[ext_index] = c;
            ext_index += 1;
        } else {
            out[base_index] = c;
            base_index += 1;
        }
    }
    return out;
}

/// 8.3 に使えない文字を '_' に寄せる（小文字は大文字にする）。
fn shortCharOr(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    if (isShortChar(c)) return c;
    return '_';
}

fn decimalDigits(value: u32) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (n /= 10) digits += 1;
    return digits;
}

fn formatDecimal(value: u32, out: *[6]u8) usize {
    var buffer: [10]u8 = @splat(0);
    var len: usize = 0;
    var n = value;
    while (n > 0) : (n /= 10) {
        buffer[len] = '0' + @as(u8, @intCast(n % 10));
        len += 1;
    }
    for (0..len) |i| out[i] = buffer[len - 1 - i];
    return len;
}

/// UTF-8 を UTF-16 に変換する。不正な並びは `InvalidEncoding`。
fn utf8ToUtf16(out: []u16, text: []const u8) Error!usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const first = text[i];
        var code_point: u21 = 0;
        var width: usize = 0;
        if (first < 0x80) {
            code_point = first;
            width = 1;
        } else if (first & 0xE0 == 0xC0) {
            code_point = first & 0x1F;
            width = 2;
        } else if (first & 0xF0 == 0xE0) {
            code_point = first & 0x0F;
            width = 3;
        } else if (first & 0xF8 == 0xF0) {
            code_point = first & 0x07;
            width = 4;
        } else return error.InvalidEncoding;

        if (i + width > text.len) return error.InvalidEncoding;
        for (1..width) |k| {
            const c = text[i + k];
            if (c & 0xC0 != 0x80) return error.InvalidEncoding;
            code_point = (code_point << 6) | (c & 0x3F);
        }
        const shortest: u21 = switch (width) {
            1 => 0,
            2 => 0x80,
            3 => 0x800,
            else => 0x10000,
        };
        if (code_point < shortest) return error.InvalidEncoding;
        if (code_point >= 0xD800 and code_point <= 0xDFFF) return error.InvalidEncoding;
        if (code_point > 0x10FFFF) return error.InvalidEncoding;
        i += width;

        if (code_point >= 0x10000) {
            if (len + 2 > out.len) return error.NameTooLong;
            const v = code_point - 0x10000;
            out[len] = @intCast(0xD800 + (v >> 10));
            out[len + 1] = @intCast(0xDC00 + (v & 0x3FF));
            len += 2;
        } else {
            if (len + 1 > out.len) return error.NameTooLong;
            out[len] = @intCast(code_point);
            len += 1;
        }
    }
    return len;
}

/// UTF-16 を UTF-8 に変換する。対になっていないサロゲートは U+FFFD にする
/// （PC が付けた名前で一覧全体を失敗させないため）。
fn utf16ToUtf8(out: []u8, units: []const u16) Error!usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < units.len) {
        const unit = units[i];
        i += 1;
        var code_point: u21 = 0;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i < units.len and units[i] >= 0xDC00 and units[i] <= 0xDFFF) {
                code_point = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, units[i]) - 0xDC00);
                i += 1;
            } else {
                code_point = 0xFFFD;
            }
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) {
            code_point = 0xFFFD;
        } else {
            code_point = unit;
        }
        len += try encodeUtf8(out[len..], code_point);
    }
    return len;
}

fn encodeUtf8(out: []u8, code_point: u21) Error!usize {
    if (code_point < 0x80) {
        if (out.len < 1) return error.BufferTooSmall;
        out[0] = @intCast(code_point);
        return 1;
    }
    if (code_point < 0x800) {
        if (out.len < 2) return error.BufferTooSmall;
        out[0] = @intCast(0xC0 | (code_point >> 6));
        out[1] = @intCast(0x80 | (code_point & 0x3F));
        return 2;
    }
    if (code_point < 0x10000) {
        if (out.len < 3) return error.BufferTooSmall;
        out[0] = @intCast(0xE0 | (code_point >> 12));
        out[1] = @intCast(0x80 | ((code_point >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (code_point & 0x3F));
        return 3;
    }
    if (out.len < 4) return error.BufferTooSmall;
    out[0] = @intCast(0xF0 | (code_point >> 18));
    out[1] = @intCast(0x80 | ((code_point >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((code_point >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (code_point & 0x3F));
    return 4;
}

/// ASCII の範囲で大文字小文字を畳み込んで比較する。
fn asciiCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// `name` がこのエントリを指すか（LFN 名か 8.3 名のどちらかと一致すればよい）。
fn nameMatches(entry: *const Entry, name: []const u8) bool {
    if (asciiCaseEqual(entry.nameSlice(), name)) return true;
    var buffer: [12]u8 = @splat(0);
    return asciiCaseEqual(entry.shortDisplay(&buffer), name);
}

/// 書き込む名前を検証する。
fn validateName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidPath;
    if (name.len > max_name_utf8) return error.NameTooLong;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return error.InvalidEncoding;
    for (name) |c| {
        if (c < 0x20) return error.InvalidEncoding;
        switch (c) {
            '"', '*', '/', ':', '<', '>', '?', '\\', '|' => return error.InvalidEncoding,
            else => {},
        }
    }
    var units: [max_name_utf16]u16 = @splat(0);
    const count = try utf8ToUtf16(&units, name);
    if (count == 0) return error.InvalidPath;
}

// ---------------------------------------------------------------------------
// FAT32 本体
// ---------------------------------------------------------------------------

const FatCache = struct {
    valid: bool = false,
    dirty: bool = false,
    /// 有効な FAT コピーの中でのセクタ（絶対 LBA）。
    sector: u32 = 0,
    data: [sector_size]u8 = @splat(0),
};

const FsInfo = struct {
    /// 署名が正しい FSInfo があったか。無ければ free_count の更新はしない。
    valid: bool = false,
    sector: u32 = 0,
    /// 予備ブートセクタ側の FSInfo（署名が正しいときだけ）。
    backup_sector: ?u32 = null,
    next_free: u32 = value_unknown,
    free_count: u32 = value_unknown,
};

/// 書き込み時にディレクトリを 1 つ伸ばすときに使う結果。
const DataChain = struct {
    first_cluster: u32,
    cluster_count: u32,
};

/// マウント済みの FAT32 ボリューム。
///
/// スレッド安全ではない（1 つのボリュームは同時に 1 つの操作から使う）。
/// 読み出しも作業バッファを共有するため再入不可。
pub const Fat32 = struct {
    device: BlockDevice,
    allocator: std.mem.Allocator,
    bpb: Bpb,
    /// 1 クラスタ分の作業バッファ。
    cluster_buf: []u8,
    fat_cache: FatCache = .{},
    fs_info: FsInfo = .{},

    /// ブロックデバイスから FAT32 をマウントする。
    /// 成功したら `deinit` を呼ぶこと。
    pub fn mount(device: BlockDevice, allocator: std.mem.Allocator) Error!Fat32 {
        var boot: [sector_size]u8 = @splat(0);
        try device.readSector(0, &boot);
        const device_sectors = device.sectorCount();

        // 1. スーパーフロッピー（パーティションテーブル無しで BPB が先頭）
        if (parseBpb(&boot, 0, device_sectors)) |bpb| {
            return finishMount(device, allocator, bpb);
        } else |super_error| {
            // 2. MBR の先頭 4 エントリから FAT32 パーティションを探す
            if (parseMbr(&boot, device, device_sectors)) |bpb| {
                return finishMount(device, allocator, bpb);
            } else |mbr_error| {
                if (super_error == error.UnsupportedFatType) return error.UnsupportedFatType;
                if (mbr_error == error.UnsupportedFatType) return error.UnsupportedFatType;
                // 先頭が FAT の起動セクタの形をしているなら、そちらの理由を返す
                // （壊れた BPB を「FAT32 ではない」と誤って報告しないため）
                if (mbr_error == error.NotFat32 and looksLikeFatBootSector(&boot)) return super_error;
                return mbr_error;
            }
        }
    }

    pub fn deinit(self: *Fat32) void {
        self.allocator.free(self.cluster_buf);
        self.cluster_buf = self.cluster_buf[0..0];
    }

    /// ルートディレクトリの先頭クラスタ。
    pub fn rootCluster(self: *const Fat32) u32 {
        return self.bpb.root_cluster;
    }

    pub fn clusterSize(self: *const Fat32) usize {
        return self.bpb.clusterSize();
    }

    /// パスのエントリを返す。`/` はルートディレクトリ自身。
    pub fn stat(self: *Fat32, path: []const u8) Error!Entry {
        var entry: Entry = .{};
        if (!try self.findPath(path, &entry)) return error.NotFound;
        return entry;
    }

    /// パスが存在するか。無い場合だけ false を返し、他のエラーはそのまま返す。
    pub fn exists(self: *Fat32, path: []const u8) Error!bool {
        var entry: Entry = .{};
        return self.findPath(path, &entry);
    }

    /// ディレクトリを走査する反復子を作る。
    pub fn openDir(self: *Fat32, path: []const u8) Error!Iterator {
        var entry: Entry = .{};
        if (!try self.findPath(path, &entry)) return error.NotFound;
        if (!entry.isDirectory()) return error.NotADirectory;
        return self.iterate(entry.first_cluster);
    }

    /// ファイルを読む。`out` は `size` 以上必要（足りなければ `BufferTooSmall`）。
    pub fn readFile(self: *Fat32, path: []const u8, out: []u8) Error![]u8 {
        const entry = try self.stat(path);
        return self.readEntry(&entry, out);
    }

    /// ファイルを読んで新しいバッファを返す。`max_bytes` を超えるファイルは
    /// `BufferTooSmall`（PSBT の 64KB 上限をここで効かせる）。
    pub fn readFileAlloc(
        self: *Fat32,
        allocator: std.mem.Allocator,
        path: []const u8,
        max_bytes: usize,
    ) Error![]u8 {
        const entry = try self.stat(path);
        if (entry.isDirectory()) return error.IsDirectory;
        if (entry.isVolumeLabel()) return error.NotAFile;
        const size: usize = entry.size;
        if (size > max_bytes) return error.BufferTooSmall;
        const buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);
        return self.readEntry(&entry, buffer);
    }

    /// ファイルを書く（既存なら上書き）。親ディレクトリは存在すること。
    ///
    /// 上書きは「先に古いクラスタを解放してから書く」ため、電源断では
    /// 空のファイルが残りうる（原子的ではない）。
    pub fn writeFile(self: *Fat32, path: []const u8, data: []const u8) Error!void {
        const parts = try splitPath(path);
        try validateName(parts.name);
        const parent = try self.stat(parts.parent);
        if (!parent.isDirectory()) return error.NotADirectory;

        // 既存エントリを探す（8.3 の別名を作るときに自分自身と衝突させない）
        var existing: Entry = .{};
        const found = try self.findEntryInDir(parent.first_cluster, parts.name, &existing);
        if (found) {
            if (existing.isDirectory()) return error.IsDirectory;
            if (existing.isVolumeLabel()) return error.NotAFile;
        }

        var info: NameInfo = .{};
        try self.prepareName(parent.first_cluster, parts.name, if (found) existing.index else null, &info);

        if (found and existing.index < existing.lfn_count) return error.CorruptChain;

        // 上書き: 先にエントリを空にしてから古いクラスタを解放する
        if (found and existing.lfn_count == info.lfn_count) {
            try self.clearEntryData(&existing);
        }
        if (found) {
            _ = try self.freeChain(existing.first_cluster);
        }

        // 名前のスロットを確保する（同じスロット数なら作り直し）
        var slot_index: u32 = 0;
        if (found and existing.lfn_count == info.lfn_count) {
            slot_index = existing.index - existing.lfn_count;
        } else {
            if (found) {
                try self.markDeleted(parent.first_cluster, existing.index - existing.lfn_count, existing.index);
            }
            slot_index = try self.allocateSlots(parent.first_cluster, @as(u32, info.lfn_count) + 1);
        }

        // データを書いてからエントリを書く（途中のファイルが完成品に見えないように）
        const chain = try self.writeData(data);
        try self.writeEntryGroup(
            parent.first_cluster,
            slot_index,
            &info,
            attr_archive,
            chain.first_cluster,
            @intCast(data.len),
        );
    }

    /// ファイルを削除する（クラスタも解放する）。
    pub fn deleteFile(self: *Fat32, path: []const u8) Error!void {
        const parts = try splitPath(path);
        const parent = try self.stat(parts.parent);
        if (!parent.isDirectory()) return error.NotADirectory;

        var entry: Entry = .{};
        if (!try self.findEntryInDir(parent.first_cluster, parts.name, &entry)) return error.NotFound;
        if (entry.isDirectory()) return error.IsDirectory;
        if (entry.isVolumeLabel()) return error.NotAFile;
        if (entry.index < entry.lfn_count) return error.CorruptChain;

        // 先にエントリを消す（電源断でクラスタが漏れる方が、二重に繋がるより安全）
        try self.markDeleted(parent.first_cluster, entry.index - entry.lfn_count, entry.index);
        _ = try self.freeChain(entry.first_cluster);
    }

    /// 同じディレクトリ内で名前を変える。データ（クラスタ）は動かさない。
    ///
    /// 名前だけを書き換える。8.3 に収まらない名前（`OUT.PSBT` は拡張子が
    /// 4 文字なので該当する）では LFN エントリを作り直す。
    /// **移動先の名前が既にある場合は `error.AlreadyExists`**（上書きしない）。
    /// 上書きしたい場合は先に `deleteFile` を呼ぶこと。
    pub fn rename(self: *Fat32, from: []const u8, to: []const u8) Error!void {
        const from_parts = try splitPath(from);
        const to_parts = try splitPath(to);
        try validateName(to_parts.name);
        if (!std.mem.eql(u8, from_parts.parent, to_parts.parent)) return error.InvalidPath;

        const parent = try self.stat(from_parts.parent);
        if (!parent.isDirectory()) return error.NotADirectory;

        var entry: Entry = .{};
        if (!try self.findEntryInDir(parent.first_cluster, from_parts.name, &entry)) return error.NotFound;
        if (entry.isVolumeLabel()) return error.NotAFile;
        if (entry.index < entry.lfn_count) return error.CorruptChain;

        var destination: Entry = .{};
        if (try self.findEntryInDir(parent.first_cluster, to_parts.name, &destination)) {
            if (destination.index != entry.index) return error.AlreadyExists;
        }

        var info: NameInfo = .{};
        try self.prepareName(parent.first_cluster, to_parts.name, entry.index, &info);

        const attr = entry.attr & (attr_read_only | attr_hidden | attr_system | attr_directory | attr_archive);
        const group_start = entry.index - entry.lfn_count;
        if (entry.lfn_count == info.lfn_count) {
            // 同じスロット数: その場で名前だけ書き換える
            try self.writeEntryGroup(
                parent.first_cluster,
                group_start,
                &info,
                attr,
                entry.first_cluster,
                entry.size,
            );
            return;
        }

        // スロット数が変わる: 先に新しい場所を確保してから、古い名前を消す。
        // （途中で電源が切れたら「何も無い」状態にする。クラスタは動かさない）
        const slot_index = try self.allocateSlots(parent.first_cluster, @as(u32, info.lfn_count) + 1);
        try self.markDeleted(parent.first_cluster, group_start, entry.index);
        try self.writeEntryGroup(
            parent.first_cluster,
            slot_index,
            &info,
            attr,
            entry.first_cluster,
            entry.size,
        );
    }

    // -- 内部: マウント ----------------------------------------------------

    fn finishMount(device: BlockDevice, allocator: std.mem.Allocator, bpb: Bpb) Error!Fat32 {
        const buffer = try allocator.alloc(u8, bpb.clusterSize());
        errdefer allocator.free(buffer);
        @memset(buffer, 0);
        var volume = Fat32{
            .device = device,
            .allocator = allocator,
            .bpb = bpb,
            .cluster_buf = buffer,
        };
        try volume.loadFsInfo();
        return volume;
    }

    /// FSInfo の署名を確かめて、使えるときだけ free_count / next_free を信用する。
    fn loadFsInfo(self: *Fat32) Error!void {
        const relative = self.bpb.fs_info_sector;
        if (relative == 0 or relative >= self.bpb.reserved_sectors) return;

        const lba = self.bpb.partition_sector + @as(u32, relative);
        var buffer: [sector_size]u8 = @splat(0);
        try self.device.readSector(lba, &buffer);
        if (!fsInfoLooksValid(&buffer)) return;

        self.fs_info.valid = true;
        self.fs_info.sector = lba;
        self.fs_info.free_count = std.mem.readInt(u32, buffer[488..492], .little);
        self.fs_info.next_free = std.mem.readInt(u32, buffer[492..496], .little);

        const backup = self.bpb.backup_boot_sector;
        const backup_end = @as(u32, backup) + relative;
        if (backup != 0 and backup_end < self.bpb.reserved_sectors) {
            const backup_lba = self.bpb.partition_sector + backup_end;
            try self.device.readSector(backup_lba, &buffer);
            if (fsInfoLooksValid(&buffer)) self.fs_info.backup_sector = backup_lba;
        }
    }

    /// クラスタ数と次に探し始める位置を FSInfo に書く（FSInfo が無ければ何もしない）。
    fn updateFsInfo(self: *Fat32, allocated: u32, freed: u32, next_free: ?u32) Error!void {
        if (!self.fs_info.valid) return;

        const buffer = self.sectorBuf();
        try self.device.readSector(self.fs_info.sector, buffer);
        if (next_free) |hint| {
            if (hint >= 2 and hint <= self.bpb.maxCluster()) {
                std.mem.writeInt(u32, buffer[492..496], hint, .little);
                self.fs_info.next_free = hint;
            }
        }
        if (self.fs_info.free_count != value_unknown) {
            var count: i64 = self.fs_info.free_count;
            count -= allocated;
            count += freed;
            if (count < 0) count = 0;
            if (count >= value_unknown) count = value_unknown - 1;
            self.fs_info.free_count = @intCast(count);
            std.mem.writeInt(u32, buffer[488..492], self.fs_info.free_count, .little);
        }
        try self.device.writeSector(self.fs_info.sector, buffer);
        if (self.fs_info.backup_sector) |backup| try self.device.writeSector(backup, buffer);
    }

    // -- 内部: 作業バッファ -------------------------------------------------

    /// セクタ 1 枚分の作業領域（1 クラスタのバッファの先頭を使う）。
    fn sectorBuf(self: *Fat32) *[sector_size]u8 {
        return self.cluster_buf[0..sector_size];
    }

    // -- 内部: FAT ---------------------------------------------------------

    fn loadFatSector(self: *Fat32, lba: u32) Error!void {
        if (self.fat_cache.valid and self.fat_cache.sector == lba) return;
        try self.flushFat();
        try self.device.readSector(lba, &self.fat_cache.data);
        self.fat_cache.sector = lba;
        self.fat_cache.valid = true;
    }

    /// 書き溜めた FAT セクタを（ミラーリングされていれば両方のコピーに）書く。
    fn flushFat(self: *Fat32) Error!void {
        if (!self.fat_cache.valid or !self.fat_cache.dirty) return;
        if (self.bpb.mirrored) {
            for (0..self.bpb.fat_count) |copy| {
                const lba = self.fat_cache.sector + @as(u32, @intCast(copy)) * self.bpb.sectors_per_fat;
                try self.device.writeSector(lba, &self.fat_cache.data);
            }
        } else {
            try self.device.writeSector(self.fat_cache.sector, &self.fat_cache.data);
        }
        self.fat_cache.dirty = false;
    }

    fn fatGet(self: *Fat32, cluster: u32) Error!u32 {
        if (cluster < 2 or cluster > self.bpb.maxCluster()) return error.CorruptChain;
        try self.loadFatSector(self.bpb.fatSectorOf(cluster, self.bpb.active_fat));
        const offset = Bpb.fatOffsetOf(cluster);
        const raw = std.mem.readInt(u32, self.fat_cache.data[offset..][0..4], .little);
        return raw & fat_mask;
    }

    fn fatSet(self: *Fat32, cluster: u32, value: u32) Error!void {
        if (cluster < 2 or cluster > self.bpb.maxCluster()) return error.CorruptChain;
        try self.loadFatSector(self.bpb.fatSectorOf(cluster, self.bpb.active_fat));
        const offset = Bpb.fatOffsetOf(cluster);
        const old = std.mem.readInt(u32, self.fat_cache.data[offset..][0..4], .little);
        std.mem.writeInt(u32, self.fat_cache.data[offset..][0..4], (old & 0xF0000000) | (value & fat_mask), .little);
        self.fat_cache.dirty = true;
    }

    /// 空きクラスタを `from` から探す（末尾まで見たら先頭へ戻る）。
    fn findFreeCluster(self: *Fat32, from: u32) Error!u32 {
        const max = self.bpb.maxCluster();
        var cluster: u32 = if (from >= 2 and from <= max) from else 2;
        var remaining = self.bpb.cluster_count;
        while (remaining > 0) : (remaining -= 1) {
            if (try self.fatGet(cluster) == fat_free) return cluster;
            cluster += 1;
            if (cluster > max) cluster = 2;
        }
        return error.NoFreeCluster;
    }

    fn freeSearchHint(self: *Fat32) u32 {
        const hint = self.fs_info.next_free;
        if (self.fs_info.valid and hint >= 2 and hint <= self.bpb.maxCluster()) return hint;
        return 2;
    }

    /// クラスタを 1 つ読む（`out` は 1 クラスタ分）。
    fn readCluster(self: *Fat32, cluster: u32, out: []u8) Error!void {
        try self.device.readSectors(self.bpb.clusterToSector(cluster), out[0..self.clusterSize()]);
    }

    /// クラスタを 1 つ書く（`data` は 1 クラスタ分）。
    fn writeCluster(self: *Fat32, cluster: u32, data: []const u8) Error!void {
        try self.device.writeSectors(self.bpb.clusterToSector(cluster), data[0..self.clusterSize()]);
    }

    fn zeroCluster(self: *Fat32, cluster: u32) Error!void {
        @memset(self.cluster_buf, 0);
        try self.writeCluster(cluster, self.cluster_buf);
    }

    // -- 内部: チェーン -----------------------------------------------------

    /// FAT チェーンを 1 クラスタずつ辿る。返したクラスタの FAT は書き換えてよい
    /// （次を先に読んである）。循環はクラスタ数の上限で検出する。
    const ChainWalker = struct {
        fs: *Fat32,
        cluster: u32,
        successor: ?u32 = null,
        started: bool = false,
        ended: bool = false,
        steps: u32 = 0,

        fn init(fs: *Fat32, first_cluster: u32) ChainWalker {
            return .{ .fs = fs, .cluster = first_cluster };
        }

        fn next(self: *ChainWalker) Error!?u32 {
            if (self.ended) return null;
            if (!self.started) {
                self.started = true;
                if (self.cluster < 2 or self.cluster > self.fs.bpb.maxCluster()) return error.CorruptChain;
            } else {
                const next_cluster = self.successor orelse {
                    self.ended = true;
                    return null;
                };
                self.cluster = next_cluster;
            }
            self.successor = try self.successorOf(self.cluster);
            return self.cluster;
        }

        fn successorOf(self: *ChainWalker, cluster: u32) Error!?u32 {
            self.steps += 1;
            if (self.steps > self.fs.bpb.cluster_count) return error.CorruptChain;
            const successor = try self.fs.fatGet(cluster);
            if (successor == fat_bad or successor == fat_free or successor == 1) return error.CorruptChain;
            if (successor >= fat_eoc_min) return null;
            if (successor > self.fs.bpb.maxCluster()) return error.CorruptChain;
            return successor;
        }
    };

    /// チェーンを解放する（FAT を 0 にする）。解放したクラスタ数を返す。
    fn freeChain(self: *Fat32, first_cluster: u32) Error!u32 {
        if (first_cluster < 2) return 0;
        var freed: u32 = 0;
        var walker = ChainWalker.init(self, first_cluster);
        while (try walker.next()) |cluster| {
            try self.fatSet(cluster, fat_free);
            freed += 1;
        }
        try self.flushFat();
        if (freed > 0) try self.updateFsInfo(0, freed, first_cluster);
        return freed;
    }

    // -- 内部: パス ---------------------------------------------------------

    const PathParts = struct {
        /// 親ディレクトリのパス（`/` を含む）。
        parent: []const u8,
        /// 最後の要素（ファイル名）。
        name: []const u8,
    };

    /// 絶対パスを親と名前へ分ける。名前は空にならない。
    fn splitPath(path: []const u8) Error!PathParts {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        var end = path.len;
        while (end > 1 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return error.InvalidPath;
        const name = trimmed[slash + 1 ..];
        if (name.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidPath;
        const parent = if (slash == 0) trimmed[0..1] else trimmed[0..slash];
        return .{ .parent = parent, .name = name };
    }

    /// パスを 1 要素ずつ辿る。見つからなければ false。
    fn findPath(self: *Fat32, path: []const u8, out: *Entry) Error!bool {
        if (path.len == 0 or path[0] != '/') return error.InvalidPath;
        out.* = .{};
        out.name[0] = '/';
        out.name_len = 1;
        out.attr = attr_directory;
        out.first_cluster = self.bpb.root_cluster;

        var components = std.mem.splitScalar(u8, path[1..], '/');
        while (components.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
            if (!out.isDirectory()) return error.NotADirectory;
            var entry: Entry = .{};
            if (!try self.findEntryInDir(out.first_cluster, component, &entry)) return false;
            out.* = entry;
        }
        return true;
    }

    /// ディレクトリ `dir_cluster` から名前で 1 件探す。
    fn findEntryInDir(self: *Fat32, dir_cluster: u32, name: []const u8, out: *Entry) Error!bool {
        var iterator = try self.iterate(dir_cluster);
        while (try iterator.next(out)) {
            if (out.isDot()) continue;
            if (nameMatches(out, name)) return true;
        }
        return false;
    }

    fn iterate(self: *Fat32, dir_cluster: u32) Error!Iterator {
        if (dir_cluster < 2 or dir_cluster > self.bpb.maxCluster()) return error.CorruptChain;
        return .{ .fs = self, .cluster = dir_cluster };
    }

    // -- 内部: 名前の準備 ---------------------------------------------------

    fn prepareName(self: *Fat32, dir_cluster: u32, name: []const u8, ignore_index: ?u32, info: *NameInfo) Error!void {
        info.* = .{};
        const count = try utf8ToUtf16(&info.units, name);
        if (count == 0) return error.InvalidPath;
        info.unit_count = @intCast(count);
        if (isPlainShortName(name)) {
            info.short_name = plainShortFromName(name);
            info.lfn_count = 0;
        } else {
            info.short_name = try self.makeShortAlias(dir_cluster, name, ignore_index);
            info.lfn_count = @intCast((count + lfn_chars - 1) / lfn_chars);
        }
    }

    /// 長い名前に対する 8.3 の別名（"LONGFI~1.BIN" 形式）を作る。
    fn makeShortAlias(self: *Fat32, dir_cluster: u32, name: []const u8, ignore_index: ?u32) Error![11]u8 {
        var base: [8]u8 = @splat('_');
        var base_len: usize = 0;
        var ext: [3]u8 = @splat(' ');
        var ext_len: usize = 0;

        var dot: ?usize = null;
        for (name, 0..) |c, i| {
            if (c == '.' and i != 0) dot = i;
        }
        const base_end = dot orelse name.len;
        for (name[0..base_end]) |c| {
            if (base_len == base.len) break;
            base[base_len] = shortCharOr(c);
            base_len += 1;
        }
        if (dot) |index| {
            for (name[index + 1 ..]) |c| {
                if (ext_len == ext.len) break;
                ext[ext_len] = shortCharOr(c);
                ext_len += 1;
            }
        }
        if (base_len == 0) {
            base[0] = '_';
            base_len = 1;
        }

        var sequence: u32 = 1;
        while (sequence <= 999999) : (sequence += 1) {
            var candidate: [11]u8 = @splat(' ');
            const digits = decimalDigits(sequence);
            const keep = if (digits + 1 >= 8) 1 else 8 - digits - 1;
            const head = @min(base_len, keep);
            @memcpy(candidate[0..head], base[0..head]);
            candidate[head] = '~';
            var text: [6]u8 = @splat(0);
            const text_len = formatDecimal(sequence, &text);
            @memcpy(candidate[head + 1 ..][0..text_len], text[0..text_len]);
            @memcpy(candidate[8..][0..ext_len], ext[0..ext_len]);
            if (!try self.shortNameExists(dir_cluster, &candidate, ignore_index)) return candidate;
        }
        return error.NameCollision;
    }

    /// 8.3 の別名が既に使われているか（`ignore_index` のエントリは数えない）。
    fn shortNameExists(self: *Fat32, dir_cluster: u32, short: *const [11]u8, ignore_index: ?u32) Error!bool {
        var index: u32 = 0;
        var cursor = ClusterCursor.init(self, dir_cluster);
        while (true) {
            var sector_index: u16 = 0;
            while (sector_index < self.bpb.sectors_per_cluster) : (sector_index += 1) {
                try self.device.readSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, self.sectorBuf());
                for (0..entries_per_sector) |slot| {
                    const raw = self.sectorBuf()[slot * entry_size ..][0..entry_size];
                    const entry_index = index + @as(u32, @intCast(slot));
                    if (raw[0] == entry_end) return false;
                    if (raw[0] == entry_free or raw[11] == attr_lfn) continue;
                    if (ignore_index) |skip| {
                        if (entry_index == skip) continue;
                    }
                    if (std.mem.eql(u8, raw[0..11], short)) return true;
                }
                index += entries_per_sector;
            }
            _ = (try cursor.advance()) orelse return false;
        }
    }

    // -- 内部: 読み出し -----------------------------------------------------

    fn readEntry(self: *Fat32, entry: *const Entry, out: []u8) Error![]u8 {
        if (entry.isDirectory()) return error.IsDirectory;
        if (entry.isVolumeLabel()) return error.NotAFile;

        const size: usize = entry.size;
        if (out.len < size) return error.BufferTooSmall;
        if (size == 0) return out[0..0];
        if (entry.first_cluster < 2 or entry.first_cluster > self.bpb.maxCluster()) return error.CorruptChain;

        const cluster_size = self.clusterSize();
        var cluster = entry.first_cluster;
        var remaining = size;
        var written: usize = 0;
        var steps: u32 = 0;
        while (true) {
            const chunk = @min(remaining, cluster_size);
            try self.readCluster(cluster, self.cluster_buf);
            @memcpy(out[written..][0..chunk], self.cluster_buf[0..chunk]);
            written += chunk;
            remaining -= chunk;
            if (remaining == 0) break;

            const next = try self.fatGet(cluster);
            if (next == fat_bad or next == fat_free or next == 1) return error.CorruptChain;
            if (next >= fat_eoc_min) return error.CorruptChain; // サイズよりチェーンが短い
            if (next > self.bpb.maxCluster()) return error.CorruptChain;
            steps += 1;
            if (steps > self.bpb.cluster_count) return error.CorruptChain; // 循環
            cluster = next;
        }

        // サイズ分を読んだあと、チェーンが本当に終わっているかを確かめる。
        // 終端でなければ（サイズより長いか、循環している）上限付きで辿って検査する。
        // サイズより長いだけのチェーンは読めた内容に影響しないため許すが、
        // 一周して戻ってくるチェーンはここで `CorruptChain` になる。
        const tail = try self.fatGet(cluster);
        if (tail != fat_bad and tail != fat_free and tail != 1 and tail < fat_eoc_min) {
            var walker = ChainWalker.init(self, cluster);
            while (try walker.next()) |_| {}
        }
        return out[0..size];
    }

    // -- 内部: 書き込み -----------------------------------------------------

    /// データをクラスタに書き、FAT を連結する。確保した先頭クラスタを返す。
    fn writeData(self: *Fat32, data: []const u8) Error!DataChain {
        if (data.len == 0) return .{ .first_cluster = 0, .cluster_count = 0 };

        const cluster_size = self.clusterSize();
        var hint = self.freeSearchHint();
        var first: u32 = 0;
        var previous: u32 = 0;
        var count: u32 = 0;
        var offset: usize = 0;

        {
            errdefer {
                // 失敗したら確保済みを解放する（後始末の失敗は元のエラーを隠さない）
                if (first >= 2) _ = self.freeChain(first) catch 0;
                self.flushFat() catch {};
            }
            while (offset < data.len) {
                const cluster = try self.findFreeCluster(hint);
                hint = cluster + 1;
                try self.fatSet(cluster, fat_eoc_min);
                if (previous != 0) try self.fatSet(previous, cluster);

                const chunk = @min(cluster_size, data.len - offset);
                @memset(self.cluster_buf, 0);
                @memcpy(self.cluster_buf[0..chunk], data[offset..][0..chunk]);
                try self.writeCluster(cluster, self.cluster_buf);

                if (first == 0) first = cluster;
                previous = cluster;
                count += 1;
                offset += chunk;
            }
        }

        try self.flushFat();
        try self.updateFsInfo(count, 0, hint);
        return .{ .first_cluster = first, .cluster_count = count };
    }

    /// 既存エントリのデータ欄（先頭クラスタとサイズ）を空にする。
    fn clearEntryData(self: *Fat32, entry: *const Entry) Error!void {
        const buffer = self.sectorBuf();
        try self.device.readSector(entry.sector, buffer);
        const offset = entry.offset;
        std.mem.writeInt(u16, buffer[offset + 20 ..][0..2], 0, .little);
        std.mem.writeInt(u16, buffer[offset + 26 ..][0..2], 0, .little);
        std.mem.writeInt(u32, buffer[offset + 28 ..][0..4], 0, .little);
        try self.device.writeSector(entry.sector, buffer);
    }

    /// 空きエントリを `count` 個連続で確保し、その先頭の線形番号を返す。
    /// 足りなければディレクトリのクラスタを足して伸ばす。
    fn allocateSlots(self: *Fat32, dir_cluster: u32, count: u32) Error!u32 {
        var index: u32 = 0;
        var run_start: u32 = 0;
        var run_length: u32 = 0;
        var past_end = false;
        var cursor = ClusterCursor.init(self, dir_cluster);

        while (true) {
            var sector_index: u16 = 0;
            while (sector_index < self.bpb.sectors_per_cluster) : (sector_index += 1) {
                try self.device.readSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, self.sectorBuf());
                for (0..entries_per_sector) |slot| {
                    var free = past_end;
                    if (!past_end) {
                        const first_byte = self.sectorBuf()[slot * entry_size];
                        if (first_byte == entry_end) {
                            past_end = true;
                            free = true;
                        } else if (first_byte == entry_free) {
                            free = true;
                        }
                    }
                    if (free) {
                        if (run_length == 0) run_start = index;
                        run_length += 1;
                        if (run_length >= count) return run_start;
                    } else {
                        run_length = 0;
                        run_start = 0;
                    }
                    index += 1;
                }
            }

            const next = try cursor.advance();
            if (next == null) break;
        }

        // チェーンの終端までで足りない: クラスタを足す（足した分は 0 埋め＝空き）
        if (run_length == 0) run_start = index;
        const per_cluster: u32 = @intCast(self.clusterSize() / entry_size);
        const missing = count - run_length;
        const needed = (missing + per_cluster - 1) / per_cluster;

        var hint = self.freeSearchHint();
        var previous = cursor.cluster;
        var appended: u32 = 0;
        while (appended < needed) : (appended += 1) {
            const cluster = try self.findFreeCluster(hint);
            hint = cluster + 1;
            try self.fatSet(cluster, fat_eoc_min);
            try self.fatSet(previous, cluster);
            try self.zeroCluster(cluster);
            previous = cluster;
        }
        try self.flushFat();
        try self.updateFsInfo(appended, 0, hint);
        return run_start;
    }

    /// 指定した線形番号の範囲のエントリを削除済み（0xE5）にする。
    fn markDeleted(self: *Fat32, dir_cluster: u32, first_index: u32, last_index: u32) Error!void {
        var index: u32 = 0;
        var cursor = ClusterCursor.init(self, dir_cluster);
        while (true) {
            var sector_index: u16 = 0;
            while (sector_index < self.bpb.sectors_per_cluster) : (sector_index += 1) {
                if (index + entries_per_sector <= first_index) {
                    index += entries_per_sector;
                    continue;
                }
                if (index > last_index) return;
                const buffer = self.sectorBuf();
                try self.device.readSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, buffer);
                var changed = false;
                for (0..entries_per_sector) |slot| {
                    const entry_index = index + @as(u32, @intCast(slot));
                    if (entry_index < first_index or entry_index > last_index) continue;
                    buffer[slot * entry_size] = entry_free;
                    changed = true;
                }
                if (changed) try self.device.writeSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, buffer);
                index += entries_per_sector;
                if (index > last_index) return;
            }
            if (index > last_index) return;
            _ = (try cursor.advance()) orelse return;
        }
    }

    /// エントリの並び（LFN + 短名）を `start_index` から書く。
    fn writeEntryGroup(
        self: *Fat32,
        dir_cluster: u32,
        start_index: u32,
        info: *const NameInfo,
        attr: u8,
        first_cluster: u32,
        size: u32,
    ) Error!void {
        var slots: [max_lfn_entries + 1][entry_size]u8 = undefined;
        const count = buildEntryGroup(info, attr, first_cluster, size, &slots);
        try self.writeSlots(dir_cluster, start_index, slots[0..count]);
    }

    fn writeSlots(self: *Fat32, dir_cluster: u32, start_index: u32, entries: []const [entry_size]u8) Error!void {
        var index: u32 = 0;
        var written: usize = 0;
        var cursor = ClusterCursor.init(self, dir_cluster);
        while (true) {
            var sector_index: u16 = 0;
            while (sector_index < self.bpb.sectors_per_cluster) : (sector_index += 1) {
                if (index + entries_per_sector <= start_index) {
                    index += entries_per_sector;
                    continue;
                }
                if (written == entries.len) return;
                const buffer = self.sectorBuf();
                try self.device.readSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, buffer);
                var changed = false;
                for (0..entries_per_sector) |slot| {
                    const entry_index = index + @as(u32, @intCast(slot));
                    if (entry_index < start_index) continue;
                    const position = entry_index - start_index;
                    if (position >= entries.len) break;
                    @memcpy(buffer[slot * entry_size ..][0..entry_size], &entries[position]);
                    written += 1;
                    changed = true;
                }
                if (changed) try self.device.writeSector(self.bpb.clusterToSector(cursor.cluster) + sector_index, buffer);
                index += entries_per_sector;
                if (written == entries.len) return;
            }
            if (written == entries.len) return;
            _ = (try cursor.advance()) orelse return error.CorruptChain;
        }
    }
};

fn fsInfoLooksValid(buffer: *const [sector_size]u8) bool {
    return std.mem.readInt(u32, buffer[0..4], .little) == fsinfo_lead_signature and
        std.mem.readInt(u32, buffer[484..488], .little) == fsinfo_struct_signature and
        std.mem.readInt(u32, buffer[508..512], .little) == fsinfo_trail_signature;
}

/// LFN エントリ（ディスク順）と短名エントリを組み立てる。
fn buildEntryGroup(
    info: *const NameInfo,
    attr: u8,
    first_cluster: u32,
    size: u32,
    slots: *[max_lfn_entries + 1][entry_size]u8,
) usize {
    const checksum = shortNameChecksum(&info.short_name);
    var count: usize = 0;

    if (info.lfn_count > 0) {
        var ordinal: u8 = info.lfn_count;
        while (ordinal >= 1) : (ordinal -= 1) {
            const entry = &slots[count];
            @memset(entry, 0);
            entry[0] = ordinal;
            if (ordinal == info.lfn_count) entry[0] |= 0x40;
            entry[11] = attr_lfn;
            entry[12] = 0;
            entry[13] = checksum;
            for (0..lfn_chars) |position| {
                const unit_index = (@as(usize, ordinal) - 1) * lfn_chars + position;
                if (unit_index >= max_name_utf16) continue;
                const value: u16 = if (unit_index < info.unit_count)
                    info.units[unit_index]
                else if (unit_index == info.unit_count)
                    0x0000
                else
                    0xFFFF;
                std.mem.writeInt(u16, entry[lfnCharOffset(position)..][0..2], value, .little);
            }
            count += 1;
        }
    }

    const short = &slots[count];
    @memset(short, 0);
    @memcpy(short[0..11], &info.short_name);
    if (short[0] == 0xE5) short[0] = 0x05; // 削除済みと紛れないようにする
    short[11] = attr;
    short[12] = 0;
    std.mem.writeInt(u16, short[16..18], default_date, .little);
    std.mem.writeInt(u16, short[18..20], default_date, .little);
    std.mem.writeInt(u16, short[20..22], @truncate(first_cluster >> 16), .little);
    std.mem.writeInt(u16, short[24..26], default_date, .little);
    std.mem.writeInt(u16, short[26..28], @truncate(first_cluster & 0xFFFF), .little);
    std.mem.writeInt(u32, short[28..32], size, .little);
    count += 1;
    return count;
}

/// 先頭セクタが FAT の起動セクタの形をしているか（BPB が壊れている場合の
/// エラーの選び分けに使う。MBR と誤認しないようジャンプ命令も見る）。
fn looksLikeFatBootSector(sector: *const [sector_size]u8) bool {
    if (sector[510] != 0x55 or sector[511] != 0xAA) return false;
    if (sector[0] != 0xEB and sector[0] != 0xE9) return false;
    const bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little);
    return bytes_per_sector >= sector_size and bytes_per_sector % sector_size == 0;
}

/// MBR の先頭 4 エントリから FAT32 パーティションを探す。
fn parseMbr(mbr: *const [sector_size]u8, device: BlockDevice, device_sectors: u64) Error!Bpb {
    if (mbr[510] != 0x55 or mbr[511] != 0xAA) return error.NotFat32;

    var boot: [sector_size]u8 = @splat(0);
    var saw_fat32_type = false;
    var saw_other_fat = false;
    var last_error: Error = error.NotFat32;

    // 1 回目: パーティション型が FAT32（0x0B / 0x0C）のものを優先する
    for (0..4) |index| {
        const base = 446 + index * 16;
        const part_type = mbr[base + 4];
        const lba = std.mem.readInt(u32, mbr[base + 8 ..][0..4], .little);
        const sectors = std.mem.readInt(u32, mbr[base + 12 ..][0..4], .little);
        if (lba == 0 or sectors == 0) continue;
        if (part_type == 0x0B or part_type == 0x0C) {
            saw_fat32_type = true;
        } else {
            if (part_type == 0x01 or part_type == 0x04 or part_type == 0x06 or part_type == 0x0E) saw_other_fat = true;
            continue;
        }
        if (@as(u64, lba) + sectors > device_sectors) {
            last_error = error.Truncated;
            continue;
        }
        try device.readSector(lba, &boot);
        if (parseBpb(&boot, lba, device_sectors)) |bpb| {
            return bpb;
        } else |err| {
            last_error = err;
        }
    }

    // 2 回目: 型が FAT でなくても BPB が読めれば受け付ける（変な型の実機対策）
    for (0..4) |index| {
        const base = 446 + index * 16;
        const part_type = mbr[base + 4];
        const lba = std.mem.readInt(u32, mbr[base + 8 ..][0..4], .little);
        const sectors = std.mem.readInt(u32, mbr[base + 12 ..][0..4], .little);
        if (lba == 0 or sectors == 0) continue;
        if (part_type == 0x0B or part_type == 0x0C) continue;
        if (@as(u64, lba) + sectors > device_sectors) continue;
        try device.readSector(lba, &boot);
        if (parseBpb(&boot, lba, device_sectors)) |bpb| {
            return bpb;
        } else |_| {}
    }

    if (saw_fat32_type) return last_error;
    if (saw_other_fat) return error.UnsupportedFatType;
    return error.NotFat32;
}

// ---------------------------------------------------------------------------
// ディレクトリの反復子
// ---------------------------------------------------------------------------

/// ディレクトリを 1 件ずつ返す反復子。呼び出し側が用意する（約 1.1KB）。
///
/// 使い方:
/// ```
/// var entry: fs.Entry = .{};
/// var it = try volume.openDir("/");
/// while (try it.next(&entry)) {
///     if (entry.isVolumeLabel()) continue;
///     // entry.nameSlice() / entry.size / entry.isDirectory() ...
/// }
/// ```
pub const Iterator = struct {
    fs: *Fat32,
    /// 走査対象のディレクトリの先頭クラスタ。
    first_cluster: u32 = 0,
    cluster: u32 = 0,
    sector_in_cluster: u16 = 0,
    sector_lba: u32 = 0,
    sector: [sector_size]u8 = @splat(0),
    sector_loaded: bool = false,
    entry_index: u16 = 0,
    /// ディレクトリ内の線形エントリ番号（次に読む位置）。
    index: u32 = 0,
    done: bool = false,
    steps: u32 = 0,
    lfn_units: [max_name_utf16]u16 = @splat(0),
    /// 見た序数のビットマスク（1〜20 ビット目）。
    lfn_seen: u32 = 0,
    lfn_total: u8 = 0,
    lfn_count: u8 = 0,
    lfn_checksum: u8 = 0,
    lfn_valid: bool = false,
    lfn_last_index: u32 = 0,

    /// 次のエントリを `out` に書く。ディレクトリの終端なら false。
    pub fn next(self: *Iterator, out: *Entry) Error!bool {
        while (true) {
            if (self.done) return false;
            if (!self.sector_loaded) {
                if (!try self.loadSector()) return false;
            }

            const offset: u16 = self.entry_index * entry_size;
            const current_index = self.index;
            self.index += 1;
            self.entry_index += 1;
            if (self.entry_index == entries_per_sector) {
                self.entry_index = 0;
                self.sector_loaded = false;
            }

            const raw = self.sector[offset..][0..entry_size];
            const first_byte = raw[0];
            if (first_byte == entry_end) {
                self.done = true;
                return false;
            }
            if (first_byte == entry_free) {
                self.resetLfn();
                continue;
            }
            if (raw[11] == attr_lfn) {
                self.accumulateLfn(raw, current_index);
                continue;
            }

            try self.buildEntry(out, raw, current_index, offset);
            self.resetLfn();
            return true;
        }
    }

    fn loadSector(self: *Iterator) Error!bool {
        while (true) {
            if (self.sector_in_cluster < self.fs.bpb.sectors_per_cluster) {
                const lba = self.fs.bpb.clusterToSector(self.cluster) + self.sector_in_cluster;
                try self.fs.device.readSector(lba, &self.sector);
                self.sector_lba = lba;
                self.sector_in_cluster += 1;
                self.entry_index = 0;
                self.sector_loaded = true;
                return true;
            }
            self.steps += 1;
            if (self.steps > self.fs.bpb.cluster_count) return error.CorruptChain;
            const successor = try self.fs.fatGet(self.cluster);
            if (successor == fat_bad or successor == fat_free or successor == 1) return error.CorruptChain;
            if (successor >= fat_eoc_min) {
                self.done = true;
                return false;
            }
            if (successor > self.fs.bpb.maxCluster()) return error.CorruptChain;
            self.cluster = successor;
            self.sector_in_cluster = 0;
        }
    }

    fn resetLfn(self: *Iterator) void {
        self.lfn_seen = 0;
        self.lfn_total = 0;
        self.lfn_count = 0;
        self.lfn_checksum = 0;
        self.lfn_valid = false;
    }

    /// LFN エントリを 1 つ取り込む。少しでも辻褄が合わなければ `lfn_valid` を落とし、
    /// 短名だけを使う（一覧全体を失敗させない）。
    fn accumulateLfn(self: *Iterator, raw: *const [entry_size]u8, index: u32) void {
        const ordinal: u8 = raw[0] & 0x1F;
        const is_last = (raw[0] & 0x40) != 0;

        if (self.lfn_count == 0) {
            self.lfn_valid = true;
            self.lfn_seen = 0;
            self.lfn_total = ordinal;
            self.lfn_checksum = raw[13];
            if (!is_last or ordinal == 0 or ordinal > max_lfn_entries) self.lfn_valid = false;
        } else {
            if (is_last) self.lfn_valid = false;
            if (index != self.lfn_last_index + 1) self.lfn_valid = false; // 飛び飛びは認めない
            if (raw[13] != self.lfn_checksum) self.lfn_valid = false;
            if (ordinal == 0 or ordinal > self.lfn_total) {
                self.lfn_valid = false;
            } else if (@as(i32, ordinal) != @as(i32, self.lfn_total) - @as(i32, self.lfn_count)) {
                self.lfn_valid = false; // 下から順（N, N-1, ..., 1）に来ているか
            }
        }

        if (ordinal == 0 or ordinal > max_lfn_entries) {
            self.lfn_count += 1;
            self.lfn_last_index = index;
            return;
        }
        if (self.lfn_seen & (@as(u32, 1) << @intCast(ordinal)) != 0) self.lfn_valid = false;
        self.lfn_seen |= @as(u32, 1) << @intCast(ordinal);

        for (0..lfn_chars) |position| {
            const unit_index = (@as(usize, ordinal) - 1) * lfn_chars + position;
            if (unit_index >= max_name_utf16) continue;
            self.lfn_units[unit_index] = std.mem.readInt(u16, raw[lfnCharOffset(position)..][0..2], .little);
        }
        self.lfn_count += 1;
        self.lfn_last_index = index;
    }

    fn buildEntry(self: *Iterator, out: *Entry, raw: *const [entry_size]u8, index: u32, offset: u16) Error!void {
        out.* = .{};
        var short: [11]u8 = raw[0..11].*;
        if (short[0] == 0x05) short[0] = 0xE5;
        out.short_name = short;
        out.case_flags = raw[12];
        out.attr = raw[11];
        out.first_cluster = (@as(u32, std.mem.readInt(u16, raw[20..22], .little)) << 16) |
            @as(u32, std.mem.readInt(u16, raw[26..28], .little));
        out.size = std.mem.readInt(u32, raw[28..32], .little);
        out.index = index;
        out.sector = self.sector_lba;
        out.offset = offset;

        if (out.isVolumeLabel()) {
            // ボリュームラベルは 11 バイトをそのまま使う（8.3 の分割はしない）
            var length: usize = 11;
            while (length > 0 and short[length - 1] == ' ') length -= 1;
            @memcpy(out.name[0..length], short[0..length]);
            out.name_len = @intCast(length);
            out.has_lfn = false;
            out.lfn_count = 0;
            return;
        }

        const group_complete = self.lfn_valid and self.lfn_count > 0 and
            self.lfn_count == self.lfn_total and self.lfn_checksum == shortNameChecksum(&short);
        if (group_complete) {
            const total_units = @as(usize, self.lfn_total) * lfn_chars;
            var name_len: usize = @min(total_units, max_name_utf16);
            for (self.lfn_units[0..name_len], 0..) |unit, position| {
                if (unit == 0) {
                    name_len = position;
                    break;
                }
            }
            out.name_len = @intCast(try utf16ToUtf8(&out.name, self.lfn_units[0..name_len]));
            out.has_lfn = true;
            out.lfn_count = self.lfn_count;
        } else {
            var buffer: [12]u8 = @splat(0);
            const display = out.shortDisplay(&buffer);
            @memcpy(out.name[0..display.len], display);
            out.name_len = @intCast(display.len);
            out.has_lfn = false;
            out.lfn_count = 0;
        }
    }
};

// ---------------------------------------------------------------------------
// テスト
// ---------------------------------------------------------------------------

test "core/errors.zig と共通のエラー値は同じ" {
    const CoreError = @import("../core/errors.zig").Error;

    const encoding: anyerror = error.InvalidEncoding;
    const encoding_core: CoreError = error.InvalidEncoding;
    const encoding_mine: Error = error.InvalidEncoding;
    try std.testing.expect(encoding == @as(anyerror, encoding_core));
    try std.testing.expect(encoding == @as(anyerror, encoding_mine));

    const too_small_core: CoreError = error.BufferTooSmall;
    const too_small_mine: Error = error.BufferTooSmall;
    try std.testing.expect(@as(anyerror, too_small_core) == @as(anyerror, too_small_mine));

    const truncated_core: CoreError = error.Truncated;
    const truncated_mine: Error = error.Truncated;
    try std.testing.expect(@as(anyerror, truncated_core) == @as(anyerror, truncated_mine));

    const out_of_memory_core: CoreError = error.OutOfMemory;
    const out_of_memory_mine: Error = error.OutOfMemory;
    try std.testing.expect(@as(anyerror, out_of_memory_core) == @as(anyerror, out_of_memory_mine));
}

/// テスト用の合成 FAT32 イメージ。
///
/// mkfs.fat が作る構造（BPB・FSInfo・FAT 2 枚・ルートディレクトリ）を最小限だけ
/// 再現する。FAT32 は規格上 33MB 以上必要なので、実イメージはテストに埋め込めない。
/// ここでは「FAT32 として筋の通った」小さなボリュームを作り、実装の読み書きを
/// インメモリで検証する。
const TestImage = struct {
    dev: block_device.MemoryDevice,
    partition_sector: u32 = 0,
    total_sectors: u32 = 0,
    reserved_sectors: u16 = 8,
    fat_count: u8 = 2,
    sectors_per_fat: u32 = 1,
    sectors_per_cluster: u8 = 1,
    root_cluster: u32 = 2,
    fs_info_sector: u16 = 1,
    backup_boot_sector: u16 = 6,
    cluster_count: u32 = 0,
    free_count: u32 = 0,
    next_free: u32 = 3,

    const Options = struct {
        /// パーティション内の総セクタ数。
        total_sectors: u32 = 1024,
        sectors_per_cluster: u8 = 1,
        fat_count: u8 = 2,
        /// 0 以外なら MBR を書いて、その位置からパーティションを置く。
        partition_sector: u32 = 0,
        /// ルートディレクトリに置くボリュームラベル（11 バイト短名）。
        volume_label: ?[]const u8 = null,
        /// FSInfo を置くか（署名を書くか）。
        fs_info: bool = true,
        /// FAT のミラーリングを無効にするか（ExtFlags の bit7）。
        mirroring_disabled: bool = false,
    };

    fn init(allocator: std.mem.Allocator, options: Options) !TestImage {
        var image: TestImage = .{
            .dev = undefined,
            .partition_sector = options.partition_sector,
            .total_sectors = options.total_sectors,
            .fat_count = options.fat_count,
            .sectors_per_cluster = options.sectors_per_cluster,
            .fs_info_sector = if (options.fs_info) 1 else 0,
        };

        // 自分の FAT を保持できる最小の長さに収束させる
        var fat_sectors: u32 = 1;
        for (0..8) |_| {
            const data_sectors = image.total_sectors - image.reserved_sectors -
                @as(u32, image.fat_count) * fat_sectors;
            const clusters = data_sectors / image.sectors_per_cluster;
            const needed = (clusters + 2 + (sector_size / 4) - 1) / (sector_size / 4);
            if (needed <= fat_sectors) break;
            fat_sectors = needed;
        }
        image.sectors_per_fat = fat_sectors;
        const data_sectors = image.total_sectors - image.reserved_sectors -
            @as(u32, image.fat_count) * fat_sectors;
        image.cluster_count = data_sectors / image.sectors_per_cluster;

        const byte_len = @as(usize, image.partition_sector + image.total_sectors) * sector_size;
        image.dev = try block_device.MemoryDevice.create(allocator, byte_len);
        errdefer image.dev.deinit(allocator);

        if (image.partition_sector != 0) image.writeMbr();
        image.writeBootSector(options.mirroring_disabled);

        // 予約領域の先頭 2 エントリと、ルートディレクトリのクラスタ
        image.setFat(0, 0x0FFFFFF8);
        image.setFat(1, 0x0FFFFFFF);
        image.setFat(image.root_cluster, fat_eoc_min);
        image.writeCluster(image.root_cluster, &.{});
        image.free_count = image.cluster_count - 1;

        if (options.volume_label) |label| {
            var raw: [entry_size]u8 = @splat(0);
            @memcpy(raw[0..11], label[0..11]);
            raw[11] = attr_volume_id;
            try image.addEntries(image.root_cluster, &.{raw});
        }
        image.writeFsInfo();
        return image;
    }

    fn deinit(self: *TestImage, allocator: std.mem.Allocator) void {
        self.dev.deinit(allocator);
    }

    fn device(self: *TestImage) BlockDevice {
        return self.dev.device();
    }

    fn sector(self: *TestImage, lba: u32) *[sector_size]u8 {
        const start = @as(usize, lba) * sector_size;
        return self.dev.storage[start..][0..sector_size];
    }

    fn firstFatSector(self: *const TestImage) u32 {
        return self.partition_sector + self.reserved_sectors;
    }

    fn clusterSector(self: *const TestImage, cluster: u32) u32 {
        const data_first = self.firstFatSector() + @as(u32, self.fat_count) * self.sectors_per_fat;
        return data_first + (cluster - 2) * self.sectors_per_cluster;
    }

    fn fatOffset(self: *const TestImage, cluster: u32) struct { sector: u32, offset: usize } {
        const byte_offset = @as(usize, cluster) * 4;
        return .{
            .sector = self.firstFatSector() + @as(u32, @intCast(byte_offset / sector_size)),
            .offset = byte_offset % sector_size,
        };
    }

    fn getFat(self: *TestImage, cluster: u32) u32 {
        const location = self.fatOffset(cluster);
        return std.mem.readInt(u32, self.sector(location.sector)[location.offset..][0..4], .little) & fat_mask;
    }

    /// 両方の FAT コピーへ書く（実装とは独立）。
    fn setFat(self: *TestImage, cluster: u32, value: u32) void {
        const location = self.fatOffset(cluster);
        for (0..self.fat_count) |copy| {
            const lba = location.sector + @as(u32, @intCast(copy)) * self.sectors_per_fat;
            std.mem.writeInt(u32, self.sector(lba)[location.offset..][0..4], value & fat_mask, .little);
        }
    }

    fn allocCluster(self: *TestImage) !u32 {
        var cluster: u32 = 2;
        while (cluster <= self.cluster_count + 1) : (cluster += 1) {
            if (self.getFat(cluster) == fat_free) {
                self.setFat(cluster, fat_eoc_min);
                self.free_count -= 1;
                self.next_free = cluster + 1;
                self.writeFsInfo();
                return cluster;
            }
        }
        return error.NoFreeCluster;
    }

    fn writeCluster(self: *TestImage, cluster: u32, data: []const u8) void {
        var index: u16 = 0;
        while (index < self.sectors_per_cluster) : (index += 1) {
            const target = self.sector(self.clusterSector(cluster) + index);
            @memset(target, 0);
            const start = @as(usize, index) * sector_size;
            if (start >= data.len) continue;
            const room = @min(sector_size, data.len - start);
            @memcpy(target[0..room], data[start..][0..room]);
        }
    }

    fn writeMbr(self: *TestImage) void {
        const mbr = self.sector(0);
        @memset(mbr, 0);
        const base = 446;
        mbr[base] = 0x80;
        mbr[base + 4] = 0x0C; // FAT32 LBA
        std.mem.writeInt(u32, mbr[base + 8 ..][0..4], self.partition_sector, .little);
        std.mem.writeInt(u32, mbr[base + 12 ..][0..4], self.total_sectors, .little);
        mbr[510] = 0x55;
        mbr[511] = 0xAA;
    }

    fn writeBootSector(self: *TestImage, mirroring_disabled: bool) void {
        const boot = self.sector(self.partition_sector);
        @memset(boot, 0);
        boot[0] = 0xEB;
        boot[1] = 0x58;
        boot[2] = 0x90;
        @memcpy(boot[3..11], "MSWIN4.1");
        std.mem.writeInt(u16, boot[11..13], sector_size, .little);
        boot[13] = self.sectors_per_cluster;
        std.mem.writeInt(u16, boot[14..16], self.reserved_sectors, .little);
        boot[16] = self.fat_count;
        std.mem.writeInt(u16, boot[17..19], 0, .little); // FAT32 は 0
        std.mem.writeInt(u16, boot[19..21], 0, .little);
        boot[21] = 0xF8;
        std.mem.writeInt(u16, boot[22..24], 0, .little); // FAT32 は 0
        std.mem.writeInt(u32, boot[28..32], self.partition_sector, .little);
        std.mem.writeInt(u32, boot[32..36], self.total_sectors, .little);
        std.mem.writeInt(u32, boot[36..40], self.sectors_per_fat, .little);
        std.mem.writeInt(u16, boot[40..42], if (mirroring_disabled) 0x0080 else 0x0000, .little);
        std.mem.writeInt(u16, boot[42..44], 0, .little);
        std.mem.writeInt(u32, boot[44..48], self.root_cluster, .little);
        std.mem.writeInt(u16, boot[48..50], self.fs_info_sector, .little);
        std.mem.writeInt(u16, boot[50..52], self.backup_boot_sector, .little);
        boot[66] = 0x29;
        std.mem.writeInt(u32, boot[67..71], 0x12345678, .little);
        @memcpy(boot[71..82], "ZHWW TEST  ");
        @memcpy(boot[82..90], "FAT32   ");
        boot[510] = 0x55;
        boot[511] = 0xAA;

        if (self.backup_boot_sector != 0) {
            const backup = self.sector(self.partition_sector + self.backup_boot_sector);
            @memcpy(backup, boot);
        }
    }

    fn writeFsInfo(self: *TestImage) void {
        if (self.fs_info_sector == 0) return;
        const info = self.sector(self.partition_sector + self.fs_info_sector);
        @memset(info, 0);
        std.mem.writeInt(u32, info[0..4], fsinfo_lead_signature, .little);
        std.mem.writeInt(u32, info[484..488], fsinfo_struct_signature, .little);
        std.mem.writeInt(u32, info[488..492], self.free_count, .little);
        std.mem.writeInt(u32, info[492..496], self.next_free, .little);
        std.mem.writeInt(u32, info[508..512], fsinfo_trail_signature, .little);
        if (self.backup_boot_sector != 0) {
            const backup = self.sector(self.partition_sector + self.backup_boot_sector + @as(u32, self.fs_info_sector));
            @memcpy(backup, info);
        }
    }

    /// ディレクトリの空きスロットにエントリを書く（足りなければクラスタを足す）。
    fn addEntries(self: *TestImage, dir_cluster: u32, entries: []const [entry_size]u8) !void {
        var written: usize = 0;
        var cluster = dir_cluster;
        while (true) {
            var sector_index: u16 = 0;
            while (sector_index < self.sectors_per_cluster) : (sector_index += 1) {
                const target = self.sector(self.clusterSector(cluster) + sector_index);
                for (0..entries_per_sector) |slot| {
                    if (written == entries.len) break;
                    const first_byte = target[slot * entry_size];
                    if (first_byte != entry_end and first_byte != entry_free) continue;
                    @memcpy(target[slot * entry_size ..][0..entry_size], &entries[written]);
                    written += 1;
                }
            }
            if (written == entries.len) return;
            const next = self.getFat(cluster);
            if (next >= fat_eoc_min) {
                const added = try self.allocCluster();
                self.setFat(cluster, added);
                self.writeCluster(added, &.{});
                cluster = added;
            } else {
                cluster = next;
            }
        }
    }

    /// データを書いてクラスタを連結する。先頭クラスタを返す。
    fn allocChain(self: *TestImage, data: []const u8) !u32 {
        const cluster_size = @as(usize, self.sectors_per_cluster) * sector_size;
        if (data.len == 0) return 0;
        var first: u32 = 0;
        var previous: u32 = 0;
        var offset: usize = 0;
        while (offset < data.len) {
            const cluster = try self.allocCluster();
            if (previous != 0) self.setFat(previous, cluster);
            const chunk = @min(cluster_size, data.len - offset);
            self.writeCluster(cluster, data[offset..][0..chunk]);
            if (first == 0) first = cluster;
            previous = cluster;
            offset += chunk;
        }
        return first;
    }

    fn addFile(self: *TestImage, dir_cluster: u32, short: *const [11]u8, data: []const u8) !void {
        const first = try self.allocChain(data);
        var raw: [entry_size]u8 = @splat(0);
        @memcpy(raw[0..11], short);
        raw[11] = attr_archive;
        std.mem.writeInt(u16, raw[16..18], default_date, .little);
        std.mem.writeInt(u16, raw[18..20], default_date, .little);
        std.mem.writeInt(u16, raw[20..22], @truncate(first >> 16), .little);
        std.mem.writeInt(u16, raw[24..26], default_date, .little);
        std.mem.writeInt(u16, raw[26..28], @truncate(first & 0xFFFF), .little);
        std.mem.writeInt(u32, raw[28..32], @intCast(data.len), .little);
        try self.addEntries(dir_cluster, &.{raw});
    }

    /// LFN 付きのファイルを書く（テスト側の独立した実装）。
    fn addLfnFile(self: *TestImage, dir_cluster: u32, name: []const u8, data: []const u8) !void {
        const first = try self.allocChain(data);

        var units: [max_name_utf16]u16 = @splat(0);
        var unit_count: usize = 0;
        for (name) |c| {
            if (c >= 0x80) return error.TestUnexpectedResult;
            units[unit_count] = c;
            unit_count += 1;
        }

        // 短名は基底 6 文字 + "~1" + 拡張子 3 文字
        var short: [11]u8 = @splat(' ');
        var base_len: usize = 0;
        var ext_len: usize = 0;
        var in_ext = false;
        for (name) |c| {
            if (c == '.') {
                in_ext = true;
                continue;
            }
            if (in_ext) {
                if (ext_len < 3) {
                    short[8 + ext_len] = shortCharOr(c);
                    ext_len += 1;
                }
            } else if (base_len < 6) {
                short[base_len] = shortCharOr(c);
                base_len += 1;
            }
        }
        if (base_len == 0) {
            short[0] = '_';
            base_len = 1;
        }
        short[base_len] = '~';
        short[base_len + 1] = '1';

        const checksum = shortNameChecksum(&short);
        const lfn_count = (unit_count + lfn_chars - 1) / lfn_chars;
        var slots: [max_lfn_entries + 1][entry_size]u8 = @splat(@splat(0));

        var ordinal: usize = lfn_count;
        var index: usize = 0;
        while (ordinal >= 1) : (ordinal -= 1) {
            const entry = &slots[index];
            entry[0] = @intCast(ordinal);
            if (ordinal == lfn_count) entry[0] |= 0x40;
            entry[11] = attr_lfn;
            entry[13] = checksum;
            for (0..lfn_chars) |position| {
                const unit_index = (ordinal - 1) * lfn_chars + position;
                const value: u16 = if (unit_index < unit_count)
                    units[unit_index]
                else if (unit_index == unit_count)
                    0
                else
                    0xFFFF;
                std.mem.writeInt(u16, entry[lfnCharOffset(position)..][0..2], value, .little);
            }
            index += 1;
        }

        const short_entry = &slots[index];
        @memcpy(short_entry[0..11], &short);
        short_entry[11] = attr_archive;
        std.mem.writeInt(u16, short_entry[16..18], default_date, .little);
        std.mem.writeInt(u16, short_entry[18..20], default_date, .little);
        std.mem.writeInt(u16, short_entry[20..22], @truncate(first >> 16), .little);
        std.mem.writeInt(u16, short_entry[24..26], default_date, .little);
        std.mem.writeInt(u16, short_entry[26..28], @truncate(first & 0xFFFF), .little);
        std.mem.writeInt(u32, short_entry[28..32], @intCast(data.len), .little);

        try self.addEntries(dir_cluster, slots[0 .. index + 1]);
    }

    /// サブディレクトリを作る（"." と ".." を含む）。
    fn addDirectory(self: *TestImage, parent_cluster: u32, short: *const [11]u8) !u32 {
        const cluster = try self.allocCluster();
        self.writeCluster(cluster, &.{});

        var dot: [entry_size]u8 = @splat(0);
        @memcpy(dot[0..11], ".          ");
        dot[11] = attr_directory;
        std.mem.writeInt(u16, dot[26..28], @truncate(cluster), .little);
        var dotdot: [entry_size]u8 = @splat(0);
        @memcpy(dotdot[0..11], "..         ");
        dotdot[11] = attr_directory;
        const parent_pointer: u32 = if (parent_cluster == self.root_cluster) 0 else parent_cluster;
        std.mem.writeInt(u16, dotdot[26..28], @truncate(parent_pointer), .little);

        const target = self.sector(self.clusterSector(cluster));
        @memcpy(target[0..entry_size], &dot);
        @memcpy(target[entry_size..][0..entry_size], &dotdot);

        var raw: [entry_size]u8 = @splat(0);
        @memcpy(raw[0..11], short);
        raw[11] = attr_directory;
        std.mem.writeInt(u16, raw[18..20], default_date, .little);
        std.mem.writeInt(u16, raw[24..26], default_date, .little);
        std.mem.writeInt(u16, raw[26..28], @truncate(cluster), .little);
        try self.addEntries(parent_cluster, &.{raw});
        return cluster;
    }

    /// チェーンを解放する（テスト側で断片化を作るため）。
    fn freeChain(self: *TestImage, first_cluster: u32) void {
        var cluster = first_cluster;
        while (cluster >= 2 and cluster <= self.cluster_count + 1) {
            const next = self.getFat(cluster);
            self.setFat(cluster, fat_free);
            self.free_count += 1;
            if (next >= fat_eoc_min or next < 2) break;
            cluster = next;
        }
        self.writeFsInfo();
    }

    fn chainOf(self: *TestImage, first_cluster: u32, out: []u32) []u32 {
        var cluster = first_cluster;
        var len: usize = 0;
        while (cluster >= 2 and cluster <= self.cluster_count + 1 and len < out.len) {
            out[len] = cluster;
            len += 1;
            const next = self.getFat(cluster);
            if (next >= fat_eoc_min or next < 2) break;
            cluster = next;
        }
        return out[0..len];
    }

    fn freeClusters(self: *TestImage) u32 {
        var count: u32 = 0;
        var cluster: u32 = 2;
        while (cluster <= self.cluster_count + 1) : (cluster += 1) {
            if (self.getFat(cluster) == fat_free) count += 1;
        }
        return count;
    }

    /// FAT 1 枚目の先頭から 2 枚目と比べる（書き込み後に一致することを確かめる）。
    fn fatCopiesMatch(self: *TestImage) bool {
        const first = self.firstFatSector();
        const second = first + self.sectors_per_fat;
        var index: u32 = 0;
        while (index < self.sectors_per_fat) : (index += 1) {
            if (!std.mem.eql(u8, self.sector(first + index), self.sector(second + index))) return false;
        }
        return true;
    }
};

const short_in_psbt = [11]u8{ 'I', 'N', ' ', ' ', ' ', ' ', ' ', ' ', 'P', 'S', 'B' };
const short_out_tmp = [11]u8{ 'O', 'U', 'T', ' ', ' ', ' ', ' ', ' ', 'T', 'M', 'P' };
const short_zhww = [11]u8{ 'Z', 'H', 'W', 'W', ' ', ' ', ' ', ' ', ' ', ' ', ' ' };
const short_readme = [11]u8{ 'R', 'E', 'A', 'D', 'M', 'E', ' ', ' ', 'T', 'X', 'T' };
const short_deep = [11]u8{ 'D', 'E', 'E', 'P', ' ', ' ', ' ', ' ', ' ', ' ', ' ' };
const short_file = [11]u8{ 'F', 'I', 'L', 'E', ' ', ' ', ' ', ' ', 'T', 'X', 'T' };
const short_big = [11]u8{ 'B', 'I', 'G', ' ', ' ', ' ', ' ', ' ', 'B', 'I', 'N' };

/// テスト用: 読み出した内容を文字列として比べる。
fn expectFileContent(volume: *Fat32, path: []const u8, expected: []const u8) !void {
    var buffer: [4096]u8 = @splat(0);
    if (expected.len > buffer.len) return error.TestUnexpectedResult;
    const data = try volume.readFile(path, &buffer);
    try std.testing.expectEqualStrings(expected, data);
}

fn fillPattern(out: []u8, seed: u32) void {
    var state = seed;
    for (out) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 16);
    }
}

test "mount: スーパーフロッピーの BPB と FSInfo を読む" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try std.testing.expectEqual(@as(u32, 0), volume.bpb.partition_sector);
    try std.testing.expectEqual(@as(u16, 512), volume.bpb.bytes_per_sector);
    try std.testing.expectEqual(@as(u8, 1), volume.bpb.sectors_per_cluster);
    try std.testing.expectEqual(@as(u8, 2), volume.bpb.fat_count);
    try std.testing.expectEqual(@as(u16, 8), volume.bpb.reserved_sectors);
    try std.testing.expectEqual(@as(u32, 2), volume.bpb.root_cluster);
    try std.testing.expectEqual(@as(u32, 1024), volume.bpb.total_sectors);
    try std.testing.expectEqual(@as(u16, 1), volume.bpb.fs_info_sector);
    try std.testing.expectEqual(image.cluster_count, volume.bpb.cluster_count);
    try std.testing.expectEqual(@as(usize, 512), volume.clusterSize());
    try std.testing.expect(volume.bpb.mirrored);
    try std.testing.expect(volume.fs_info.valid);
    try std.testing.expectEqual(image.free_count, volume.fs_info.free_count);
}

test "mount: MBR の先頭 4 エントリから FAT32 を探す" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .partition_sector = 2048 });
    defer image.deinit(allocator);
    try image.addFile(image.root_cluster, &short_readme, "hello mbr");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try std.testing.expectEqual(@as(u32, 2048), volume.bpb.partition_sector);
    try std.testing.expectEqual(@as(u32, 1024), volume.bpb.total_sectors);
    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/README.TXT", &buffer);
    try std.testing.expectEqualStrings("hello mbr", data);
}

test "mount: セクタ長が 512 以外は InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    std.mem.writeInt(u16, image.sector(0)[11..13], 1024, .little);

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: クラスタあたりセクタ数が不正なら InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    image.sector(0)[13] = 3; // 2 の冪でない

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: FAT12 / FAT16 は UnsupportedFatType" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // FAT16 の BPB に作り変える（ルートエントリ数 != 0、FAT 長は 16 ビット側）
    std.mem.writeInt(u16, image.sector(0)[17..19], 512, .little);
    std.mem.writeInt(u16, image.sector(0)[22..24], 40, .little);
    std.mem.writeInt(u32, image.sector(0)[36..40], 0, .little);

    try std.testing.expectError(error.UnsupportedFatType, Fat32.mount(image.device(), allocator));
}

test "mount: exFAT は UnsupportedFatType" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    @memcpy(image.sector(0)[3..11], "EXFAT   ");

    try std.testing.expectError(error.UnsupportedFatType, Fat32.mount(image.device(), allocator));
}

test "mount: デバイスより大きいボリュームは Truncated" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // デバイスを 4KB 短くする（BPB は元のまま）
    const full = image.dev.storage;
    image.dev.storage = full[0 .. full.len - 4096];
    try std.testing.expectError(error.Truncated, Fat32.mount(image.device(), allocator));
    image.dev.storage = full; // deinit で解放できるように元へ戻す
}

test "mount: ルートクラスタが範囲外なら InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    std.mem.writeInt(u32, image.sector(0)[44..48], image.cluster_count + 100, .little);

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: パーティションテーブルも BPB も無ければ NotFat32" {
    const allocator = std.testing.allocator;
    var memory = try block_device.MemoryDevice.create(allocator, 64 * sector_size);
    defer memory.deinit(allocator);

    try std.testing.expectError(error.NotFat32, Fat32.mount(memory.device(), allocator));
}

test "list: ルートの短名・LFN・ボリュームラベルを列挙する" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .volume_label = "ZHWW TEST  " });
    defer image.deinit(allocator);
    try image.addFile(image.root_cluster, &short_readme, "readme bytes");
    try image.addLfnFile(image.root_cluster, "LongFileName-PSBT.bin", "long name bytes");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var saw_label = false;
    var saw_readme = false;
    var saw_long = false;
    while (try iterator.next(&entry)) {
        if (entry.isVolumeLabel()) {
            saw_label = true;
            try std.testing.expectEqualStrings("ZHWW TEST", entry.nameSlice());
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.nameSlice(), "README.TXT")) {
            saw_readme = true;
            try std.testing.expectEqual(@as(u32, 12), entry.size);
            try std.testing.expect(!entry.isDirectory());
            continue;
        }
        if (std.mem.eql(u8, entry.nameSlice(), "LongFileName-PSBT.bin")) {
            saw_long = true;
            try std.testing.expect(entry.has_lfn);
            try std.testing.expectEqual(@as(u8, 2), entry.lfn_count);
            try std.testing.expectEqual(@as(u32, 15), entry.size);
            var short_buffer: [12]u8 = @splat(0);
            try std.testing.expectEqualStrings("LONGFI~1.BIN", entry.shortDisplay(&short_buffer));
        }
    }
    try std.testing.expect(saw_label);
    try std.testing.expect(saw_readme);
    try std.testing.expect(saw_long);
}

test "list: サブディレクトリ（. と .. を含む）と NT 小文字フラグ" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    const sub = try image.addDirectory(image.root_cluster, &short_zhww);
    try image.addFile(sub, &short_out_tmp, "signed psbt");

    // NT ケースフラグ付きの短名（Windows が小文字 8.3 に付ける形）
    var lower: [11]u8 = @splat(' ');
    @memcpy(lower[0..6], "lowerc");
    @memcpy(lower[8..11], "txt");
    var slot: [entry_size]u8 = @splat(0);
    @memcpy(slot[0..11], &lower);
    slot[11] = attr_archive;
    slot[12] = 0x18; // 基底も拡張子も小文字
    std.mem.writeInt(u16, slot[18..20], default_date, .little);
    std.mem.writeInt(u16, slot[24..26], default_date, .little);
    std.mem.writeInt(u32, slot[28..32], 3, .little);
    try image.addEntries(image.root_cluster, &.{slot});

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var entry: Entry = .{};
    var root = try volume.openDir("/");
    var saw_dir = false;
    var saw_lower = false;
    while (try root.next(&entry)) {
        if (std.ascii.eqlIgnoreCase(entry.nameSlice(), "zhww")) {
            saw_dir = true;
            try std.testing.expect(entry.isDirectory());
            try std.testing.expectEqual(sub, entry.first_cluster);
        }
        if (std.mem.eql(u8, entry.nameSlice(), "lowerc.txt")) saw_lower = true;
    }
    try std.testing.expect(saw_dir);
    try std.testing.expect(saw_lower);

    // サブディレクトリの中身（"." と ".." も返る）
    var inner = try volume.openDir("/ZHWW");
    var saw_dot = false;
    var saw_dotdot = false;
    var saw_file = false;
    while (try inner.next(&entry)) {
        if (entry.isDot()) {
            if (entry.short_name[1] == '.') saw_dotdot = true else saw_dot = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(entry.nameSlice(), "out.tmp")) {
            saw_file = true;
            try std.testing.expectEqual(@as(u32, 11), entry.size);
        }
    }
    try std.testing.expect(saw_dot);
    try std.testing.expect(saw_dotdot);
    try std.testing.expect(saw_file);
}

test "read: 短名のファイルをバイト単位で読む" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    var payload: [700]u8 = undefined;
    fillPattern(&payload, 7);
    try image.addFile(image.root_cluster, &short_big, &payload);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [700]u8 = @splat(0);
    const data = try volume.readFile("/BIG.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, data);

    // 小文字でも引ける（FAT の慣習）
    const again = try volume.readFile("/big.bin", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, again);
}

test "read: LFN のファイルを LFN 名でも 8.3 名でも読める" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    try image.addLfnFile(image.root_cluster, "LongFileName-PSBT.bin", "long name payload");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [64]u8 = @splat(0);
    const by_long = try volume.readFile("/LongFileName-PSBT.bin", &buffer);
    try std.testing.expectEqualStrings("long name payload", by_long);
    const by_short = try volume.readFile("/LONGFI~1.BIN", &buffer);
    try std.testing.expectEqualStrings("long name payload", by_short);
    const by_case = try volume.readFile("/longfilename-psbt.BIN", &buffer);
    try std.testing.expectEqualStrings("long name payload", by_case);

    const entry = try volume.stat("/LongFileName-PSBT.bin");
    try std.testing.expect(entry.has_lfn);
    try std.testing.expectEqualStrings("LongFileName-PSBT.bin", entry.nameSlice());
}

test "read: 4 文字の拡張子（IN.PSBT）は LFN として読む" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // 4 文字の拡張子は 8.3 に収まらないので、必ず LFN になる
    try image.addLfnFile(image.root_cluster, "IN.PSBT", "psbt payload");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/IN.PSBT", &buffer);
    try std.testing.expectEqualStrings("psbt payload", data);
}

test "read: サブディレクトリの中を読む" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    const sub = try image.addDirectory(image.root_cluster, &short_zhww);
    const deep = try image.addDirectory(sub, &short_deep);
    try image.addFile(deep, &short_out_tmp, "nested payload");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/ZHWW/DEEP/OUT.TMP", &buffer);
    try std.testing.expectEqualStrings("nested payload", data);

    const root_entry = try volume.stat("/");
    try std.testing.expect(root_entry.isDirectory());
    try std.testing.expectEqual(image.root_cluster, root_entry.first_cluster);
}

test "read: 断片化した複数クラスタのファイルを読む" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    // 先に 4 クラスタのファイルを 2 つ置き、1 つ目を解放して穴を作る。
    // そのあと 5 クラスタのファイルを書くと、穴（4 個）＋後方のクラスタに分かれる。
    try image.addFile(image.root_cluster, &short_readme, "A");
    var hole_payload: [4 * 512]u8 = undefined;
    fillPattern(&hole_payload, 11);
    try image.addFile(image.root_cluster, &short_big, &hole_payload); // クラスタ 4〜7
    var filler_payload: [4 * 512]u8 = undefined;
    fillPattern(&filler_payload, 22);
    var filler_short: [11]u8 = @splat(' ');
    @memcpy(filler_short[0..5], "FILLR");
    try image.addFile(image.root_cluster, &filler_short, &filler_payload); // クラスタ 8〜11
    image.freeChain(4); // 穴（クラスタ 4〜7）を空ける

    var fragmented: [5 * 512]u8 = undefined;
    fillPattern(&fragmented, 33);
    var target_short: [11]u8 = @splat(' ');
    @memcpy(target_short[0..4], "FRAG");
    @memcpy(target_short[8..11], "BIN");
    try image.addFile(image.root_cluster, &target_short, &fragmented); // 4〜7 + 12

    var chain_buffer: [16]u32 = @splat(0);
    const chain = image.chainOf(4, &chain_buffer);
    try std.testing.expectEqual(@as(usize, 5), chain.len);
    var jump = false;
    for (chain[1..], chain[0 .. chain.len - 1]) |current, previous| {
        if (current != previous + 1) jump = true;
    }
    try std.testing.expect(jump); // 本当に断片化している

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [5 * 512]u8 = @splat(0);
    const data = try volume.readFile("/FRAG.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &fragmented, data);
}

test "read: クラスタ長が 4 セクタのボリューム" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 2048, .sectors_per_cluster = 4 });
    defer image.deinit(allocator);
    var payload: [3 * 2048 + 17]u8 = undefined;
    fillPattern(&payload, 44);
    try image.addFile(image.root_cluster, &short_big, &payload);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    try std.testing.expectEqual(@as(usize, 2048), volume.clusterSize());

    var buffer: [3 * 2048 + 17]u8 = @splat(0);
    const data = try volume.readFile("/BIG.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, data);
}

test "read: 出力バッファが足りなければ BufferTooSmall" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    var payload: [600]u8 = @splat(0x11);
    try image.addFile(image.root_cluster, &short_big, &payload);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var small: [256]u8 = @splat(0);
    try std.testing.expectError(error.BufferTooSmall, volume.readFile("/BIG.BIN", &small));
    try std.testing.expectError(error.BufferTooSmall, volume.readFileAlloc(allocator, "/BIG.BIN", 128));

    const exact = try volume.readFileAlloc(allocator, "/BIG.BIN", 600);
    defer allocator.free(exact);
    try std.testing.expectEqual(@as(usize, 600), exact.len);
}

test "read: 無いパス・ディレクトリ・相対パス・.. を弾く" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    const sub = try image.addDirectory(image.root_cluster, &short_zhww);
    try image.addFile(image.root_cluster, &short_file, "plain file");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [64]u8 = @splat(0);
    try std.testing.expectError(error.NotFound, volume.readFile("/NOPE.TXT", &buffer));
    try std.testing.expectError(error.NotFound, volume.readFile("/ZHWW/NOPE.TXT", &buffer));
    try std.testing.expectError(error.IsDirectory, volume.readFile("/ZHWW", &buffer));
    try std.testing.expectError(error.InvalidPath, volume.readFile("ZHWW/OUT.TMP", &buffer));
    try std.testing.expectError(error.InvalidPath, volume.readFile("/ZHWW/../OUT.TMP", &buffer));
    try std.testing.expectError(error.NotADirectory, volume.readFile("/FILE.TXT/x", &buffer));
    try std.testing.expectError(error.NotADirectory, volume.openDir("/FILE.TXT"));

    // "/" と "/ZHWW/" は同じディレクトリを指す
    const root_entry = try volume.stat("/");
    const sub_entry = try volume.stat("/ZHWW/");
    try std.testing.expectEqual(sub, sub_entry.first_cluster);
    try std.testing.expect(root_entry.isDirectory());

    try std.testing.expect(try volume.exists("/ZHWW"));
    try std.testing.expect(!try volume.exists("/ZHWW/NOPE.TXT"));
}

test "read: 循環した FAT チェーンは CorruptChain（無限ループしない）" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    // 5 クラスタ分のサイズを持つファイルを作り、チェーンを 3 個で循環させる
    var payload: [5 * 512]u8 = @splat(0x5A);
    try image.addFile(image.root_cluster, &short_big, &payload);
    var chain_buffer: [8]u32 = @splat(0);
    const chain = image.chainOf(3, &chain_buffer);
    try std.testing.expectEqual(@as(usize, 5), chain.len);
    image.setFat(chain[chain.len - 1], chain[0]); // 末尾を先頭へ繋いで循環

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [5 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));

    // 一覧（ディレクトリ自体は正常）と削除は影響を受けない…削除は循環を検出する
    _ = try volume.stat("/BIG.BIN");
    try std.testing.expectError(error.CorruptChain, volume.deleteFile("/BIG.BIN"));
}

test "read: 自己ループしたチェーンも CorruptChain" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [4 * 512]u8 = @splat(0x33);
    try image.addFile(image.root_cluster, &short_big, &payload);
    image.setFat(3, 3); // 自分自身を指す

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [4 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
}

test "read: 範囲外・フリークラスタを指すチェーンは CorruptChain" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [3 * 512]u8 = @splat(0x44);
    try image.addFile(image.root_cluster, &short_big, &payload);

    // (1) 範囲外を指す
    image.setFat(3, image.cluster_count + 10);
    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    var buffer: [3 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
    volume.deinit();

    // (2) フリークラスタを指す
    image.setFat(3, 0);
    var volume2 = try Fat32.mount(image.device(), allocator);
    defer volume2.deinit();
    try std.testing.expectError(error.CorruptChain, volume2.readFile("/BIG.BIN", &buffer));
}

test "read: サイズよりチェーンが短ければ CorruptChain" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [3 * 512]u8 = @splat(0x55);
    try image.addFile(image.root_cluster, &short_big, &payload);
    image.setFat(3, fat_eoc_min); // 1 クラスタで終端にする

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [3 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
}

test "write: 新しい短名ファイルを書き、FAT 2 枚と FSInfo を更新する" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const free_before = image.freeClusters();
    var payload: [1300]u8 = undefined;
    fillPattern(&payload, 99);
    try volume.writeFile("/NEW.BIN", &payload);

    // FAT の 2 枚が一致する
    try std.testing.expect(image.fatCopiesMatch());

    // クラスタが 3 個使われた（1300 バイト / 512）
    try std.testing.expectEqual(free_before - 3, image.freeClusters());
    try std.testing.expectEqual(free_before - 3, volume.fs_info.free_count);

    // FSInfo の free_count がディスクにも書かれている
    const fsinfo = image.sector(1);
    try std.testing.expectEqual(free_before - 3, std.mem.readInt(u32, fsinfo[488..492], .little));
    const backup = image.sector(1 + 6);
    try std.testing.expectEqual(free_before - 3, std.mem.readInt(u32, backup[488..492], .little));

    // 書き戻して読める
    var buffer: [1300]u8 = @splat(0);
    const data = try volume.readFile("/NEW.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, data);

    const entry = try volume.stat("/NEW.BIN");
    try std.testing.expectEqual(@as(u32, 1300), entry.size);
    try std.testing.expect(!entry.has_lfn);
    try std.testing.expectEqual(attr_archive, entry.attr);
}

test "write: 長い名前は LFN として書き、並びとチェックサムが正しい" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const name = "LongFileName-PSBT.bin";
    try volume.writeFile("/LongFileName-PSBT.bin", "signed psbt bytes");

    // 自分自身の読み出しで確認
    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/LongFileName-PSBT.bin", &buffer);
    try std.testing.expectEqualStrings("signed psbt bytes", data);

    // ディスク上の LFN を独立に検証する（並び順・0x40・チェックサム・パディング）。
    // "LongFileName-PSBT.bin" は 21 コード単位 → LFN 2 個 + 短名 1 個。ディスク順は
    // 「名前の後半（ordinal 2、0x40 付き）」「前半（ordinal 1）」「短名」。
    const target = image.sector(image.clusterSector(image.root_cluster));
    const lfn_second = target[0..entry_size];
    const lfn_first = target[entry_size..][0..entry_size];
    const short_entry = target[2 * entry_size ..][0..entry_size];
    try std.testing.expectEqual(@as(u8, attr_lfn), lfn_second[11]);
    try std.testing.expectEqual(@as(u8, attr_lfn), lfn_first[11]);
    try std.testing.expectEqual(@as(u8, 0x42), lfn_second[0]); // 2 個組の最後（0x40 付き）
    try std.testing.expectEqual(@as(u8, 0x01), lfn_first[0]);
    try std.testing.expectEqual(@as(u8, 0), lfn_second[12]); // LFN エントリの type は 0

    var short_name: [11]u8 = short_entry[0..11].*;
    if (short_name[0] == 0x05) short_name[0] = 0xE5;
    try std.testing.expectEqualSlices(u8, "LONGFI~1BIN", &short_name); // 生の 11 バイト（点は入らない）
    try std.testing.expectEqual(shortNameChecksum(&short_name), lfn_second[13]);
    try std.testing.expectEqual(shortNameChecksum(&short_name), lfn_first[13]);
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, short_entry[28..32], .little));

    // UTF-16 を組み立て直して名前と一致することを確かめる
    var units: [max_name_utf16]u16 = @splat(0);
    for (0..lfn_chars) |position| {
        units[position] = std.mem.readInt(u16, lfn_first[lfnCharOffset(position)..][0..2], .little);
        units[lfn_chars + position] = std.mem.readInt(u16, lfn_second[lfnCharOffset(position)..][0..2], .little);
    }
    var decoded: [max_name_utf8]u8 = @splat(0);
    const decoded_len = try utf16ToUtf8(&decoded, units[0..21]);
    try std.testing.expectEqualStrings(name, decoded[0..decoded_len]);
    try std.testing.expectEqual(@as(u16, 0x0000), units[21]); // 終端
    try std.testing.expectEqual(@as(u16, 0xFFFF), units[22]); // そのあとは埋め草

    // 8.3 の別名からも読める
    const by_short = try volume.readFile("/LONGFI~1.BIN", &buffer);
    try std.testing.expectEqualStrings("signed psbt bytes", by_short);

    // 一覧にも長い名前で出る
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var found = false;
    while (try iterator.next(&entry)) {
        if (std.mem.eql(u8, entry.nameSlice(), name)) found = true;
    }
    try std.testing.expect(found);
}

test "write: 4 文字の拡張子（OUT.PSBT）を LFN として書ける" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/OUT.PSBT", "signed");
    var buffer: [32]u8 = @splat(0);
    const data = try volume.readFile("/OUT.PSBT", &buffer);
    try std.testing.expectEqualStrings("signed", data);

    const entry = try volume.stat("/OUT.PSBT");
    try std.testing.expect(entry.has_lfn);
    try std.testing.expectEqualStrings("OUT.PSBT", entry.nameSlice());
    var short_buffer: [12]u8 = @splat(0);
    try std.testing.expectEqualStrings("OUT~1.PSB", entry.shortDisplay(&short_buffer));
}

test "write: UTF-8 の名前（日本語）を LFN として書ける" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const name = "日本語-PSBT.bin";
    try volume.writeFile("/日本語-PSBT.bin", "japanese name");

    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/日本語-PSBT.bin", &buffer);
    try std.testing.expectEqualStrings("japanese name", data);

    const entry = try volume.stat("/日本語-PSBT.bin");
    try std.testing.expectEqualStrings(name, entry.nameSlice());
    try std.testing.expect(entry.has_lfn);
}

test "write: 既存ファイルの上書きでクラスタが漏れない" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const free_before = image.freeClusters();
    var small: [200]u8 = undefined;
    fillPattern(&small, 1);
    try volume.writeFile("/OUT.TMP", &small);
    try std.testing.expectEqual(free_before - 1, image.freeClusters());

    // 大きくする
    var large: [2400]u8 = undefined;
    fillPattern(&large, 2);
    try volume.writeFile("/OUT.TMP", &large);
    try std.testing.expectEqual(free_before - 5, image.freeClusters());
    var buffer: [2400]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &large, try volume.readFile("/OUT.TMP", &buffer));

    // 小さくする
    try volume.writeFile("/out.tmp", &small); // 大文字小文字違いも同じファイル
    try std.testing.expectEqual(free_before - 1, image.freeClusters());
    try std.testing.expectEqualSlices(u8, &small, try volume.readFile("/OUT.TMP", &buffer));

    // エントリは 1 つだけ
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var count: usize = 0;
    while (try iterator.next(&entry)) {
        if (entry.isVolumeLabel()) continue;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(image.fatCopiesMatch());
}

test "write: 空のファイルを書いて読める" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/EMPTY.TXT", "");
    const entry = try volume.stat("/EMPTY.TXT");
    try std.testing.expectEqual(@as(u32, 0), entry.size);
    try std.testing.expectEqual(@as(u32, 0), entry.first_cluster);

    var buffer: [32]u8 = @splat(0);
    const data = try volume.readFile("/EMPTY.TXT", &buffer);
    try std.testing.expectEqual(@as(usize, 0), data.len);

    // 上書きで中身を入れる
    try volume.writeFile("/EMPTY.TXT", "now it has bytes");
    try std.testing.expectEqualStrings("now it has bytes", try volume.readFile("/EMPTY.TXT", &buffer));

    // また空にする
    try volume.writeFile("/EMPTY.TXT", "");
    try std.testing.expectEqual(@as(u32, 0), (try volume.stat("/EMPTY.TXT")).first_cluster);
}

test "write: サブディレクトリの中へ書ける" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    _ = try image.addDirectory(image.root_cluster, &short_zhww);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var payload: [900]u8 = undefined;
    fillPattern(&payload, 5);
    try volume.writeFile("/zhww/out.tmp", &payload);

    var buffer: [900]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/ZHWW/OUT.TMP", &buffer));
    try std.testing.expect(try volume.exists("/ZHWW/OUT.TMP"));
    try std.testing.expect(!try volume.exists("/ZHWW/OUT.PSBT"));
    try std.testing.expectError(error.NotFound, volume.writeFile("/NOPE/OUT.TMP", "x"));
}

test "write: ディレクトリが満杯ならクラスタを足して伸ばす" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 128 });
    defer image.deinit(allocator);

    // ルートディレクトリ（16 スロット）を全部埋める
    var count: u32 = 0;
    while (count < entries_per_sector) : (count += 1) {
        var short: [11]u8 = @splat(' ');
        short[0] = 'A' + @as(u8, @intCast(count / 10)); // A0〜A9, B0〜B5
        short[1] = '0' + @as(u8, @intCast(count % 10));
        @memcpy(short[8..11], "TXT");
        try image.addFile(image.root_cluster, &short, &[_]u8{0x77});
    }
    try std.testing.expect(image.getFat(image.root_cluster) >= fat_eoc_min); // まだ 1 クラスタ

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    // 名前が LFN になるので 2 スロット必要 → 伸ばさざるを得ない
    var payload: [600]u8 = undefined;
    fillPattern(&payload, 8);
    try volume.writeFile("/Extended-Name.bin", &payload);

    try std.testing.expect(image.getFat(image.root_cluster) < fat_eoc_min); // 伸びた（終端ではない）
    try std.testing.expect(image.fatCopiesMatch());

    var buffer: [600]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/Extended-Name.bin", &buffer));
    try std.testing.expectEqualStrings("A0.TXT", (try volume.stat("/A0.TXT")).nameSlice());
    try std.testing.expectEqualStrings("B5.TXT", (try volume.stat("/B5.TXT")).nameSlice());

    // 一覧で 17 件（16 + 1）
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var seen: usize = 0;
    while (try iterator.next(&entry)) seen += 1;
    try std.testing.expectEqual(@as(usize, 17), seen);
}

test "write: 空きクラスタが無ければ NoFreeCluster" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 64 });
    defer image.deinit(allocator);

    // 空きクラスタを全部 1 つのファイルで埋める
    const free = image.freeClusters();
    const payload = try allocator.alloc(u8, free * 512);
    defer allocator.free(payload);
    fillPattern(payload, 3);
    try image.addFile(image.root_cluster, &short_big, payload);
    try std.testing.expectEqual(@as(u32, 0), image.freeClusters());

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var payload_after: [1024]u8 = @splat(0x01);
    try std.testing.expectError(error.NoFreeCluster, volume.writeFile("/NOPE.BIN", &payload_after));
    // 失敗しても確保済みクラスタを残さない
    try std.testing.expectEqual(@as(u32, 0), image.freeClusters());
}

test "delete: エントリとクラスタが消える" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const free_before = image.freeClusters();
    var payload: [1200]u8 = undefined;
    fillPattern(&payload, 6);
    try volume.writeFile("/OUT.TMP", &payload);
    try std.testing.expectEqual(free_before - 3, image.freeClusters());

    try volume.deleteFile("/OUT.TMP");
    try std.testing.expectEqual(free_before, image.freeClusters());
    try std.testing.expectEqual(free_before, volume.fs_info.free_count);
    try std.testing.expect(!try volume.exists("/OUT.TMP"));
    try std.testing.expectError(error.NotFound, volume.deleteFile("/OUT.TMP"));
}

test "delete: LFN 付きのファイルは LFN エントリも消える" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/IN.PSBT", "psbt data");
    try volume.writeFile("/KEEP.TXT", "keep me");
    const entry = try volume.stat("/IN.PSBT");
    try std.testing.expect(entry.lfn_count > 0);

    try volume.deleteFile("/IN.PSBT");
    try std.testing.expect(!try volume.exists("/IN.PSBT"));
    try expectFileContent(&volume, "/KEEP.TXT", "keep me");

    // ディレクトリの先頭 2 スロット（LFN + 短名）が削除済みになっている
    const target = image.sector(image.clusterSector(image.root_cluster));
    try std.testing.expectEqual(@as(u8, entry_free), target[0]);
    try std.testing.expectEqual(@as(u8, entry_free), target[entry_size]);

    // 別のファイルを書いても壊れない
    try volume.writeFile("/AFTER.BIN", "after");
    try expectFileContent(&volume, "/AFTER.BIN", "after");

    // 一覧に残骸が出ない
    var item: Entry = .{};
    var iterator = try volume.openDir("/");
    while (try iterator.next(&item)) {
        try std.testing.expect(!std.mem.eql(u8, item.nameSlice(), "IN.PSBT"));
    }
}

test "delete: ディレクトリは IsDirectory" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    _ = try image.addDirectory(image.root_cluster, &short_zhww);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    try std.testing.expectError(error.IsDirectory, volume.deleteFile("/ZHWW"));
}

test "rename: OUT.TMP → OUT.PSBT（LFN が必要）でもデータが保たれる" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var payload: [2400]u8 = undefined;
    fillPattern(&payload, 21);
    try volume.writeFile("/OUT.TMP", &payload);
    const before = try volume.stat("/OUT.TMP");
    const free_before = image.freeClusters();

    // OUT.TMP は 8.3 だが OUT.PSBT は拡張子が 4 文字 → LFN を作り直す経路
    try volume.rename("/OUT.TMP", "/OUT.PSBT");

    try std.testing.expect(!try volume.exists("/OUT.TMP"));
    const after = try volume.stat("/OUT.PSBT");
    try std.testing.expectEqualStrings("OUT.PSBT", after.nameSlice());
    try std.testing.expect(after.has_lfn);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.first_cluster, after.first_cluster); // データは動かさない
    try std.testing.expectEqual(free_before, image.freeClusters());

    var buffer: [2400]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/OUT.PSBT", &buffer));
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/OUT~1.PSB", &buffer));
}

test "rename: 8.3 どうしはその場で名前だけ書き換える" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/OUT.TMP", "payload");
    const before = try volume.stat("/OUT.TMP");
    const raw_before = image.sector(before.sector)[before.offset + 11]; // 属性バイト

    try volume.rename("/OUT.TMP", "/OUT.LOG");

    const after = try volume.stat("/OUT.LOG");
    try std.testing.expectEqual(before.index, after.index); // 同じスロット
    try std.testing.expectEqual(before.sector, after.sector);
    try std.testing.expectEqual(before.offset, after.offset);
    try std.testing.expectEqual(before.first_cluster, after.first_cluster);
    try std.testing.expectEqual(raw_before, image.sector(after.sector)[after.offset + 11]);
    try expectFileContent(&volume, "/OUT.LOG", "payload");

    // データのバイトも名前だけが変わったことを確かめる（他のフィールドは同じ）
    const raw_after = image.sector(after.sector);
    try std.testing.expectEqualStrings("OUT     LOG", raw_after[after.offset..][0..11]);
}

test "rename: 長い名前から 8.3 へ、8.3 から長い名前へ" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/LongOriginalName.bin", "content here");
    try volume.rename("/LongOriginalName.bin", "/SHORT.BIN");
    try std.testing.expect(!try volume.exists("/LongOriginalName.bin"));
    try expectFileContent(&volume, "/SHORT.BIN", "content here");

    try volume.rename("/SHORT.BIN", "/Another-Long-Name.bin");
    try expectFileContent(&volume, "/Another-Long-Name.bin", "content here");
    try std.testing.expect(!try volume.exists("/SHORT.BIN"));
    try std.testing.expect(image.fatCopiesMatch());

    // 一覧に 1 件だけ
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var count: usize = 0;
    while (try iterator.next(&entry)) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "rename: 移動先が既にあれば AlreadyExists、別ディレクトリへは InvalidPath" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    _ = try image.addDirectory(image.root_cluster, &short_zhww);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/OUT.TMP", "a");
    try volume.writeFile("/OUT.PSBT", "b");
    try std.testing.expectError(error.AlreadyExists, volume.rename("/OUT.TMP", "/OUT.PSBT"));
    try expectFileContent(&volume, "/OUT.TMP", "a");
    try expectFileContent(&volume, "/OUT.PSBT", "b");

    try std.testing.expectError(error.InvalidPath, volume.rename("/OUT.TMP", "/ZHWW/OUT.PSBT"));
    try std.testing.expectError(error.NotFound, volume.rename("/NOPE.TMP", "/OUT.LOG"));
    try std.testing.expectError(error.NotFound, volume.rename("/OUT.LOG", "/OUT.LOG"));

    // 同じエントリを指す名前（大文字小文字だけの変更）はその場で書き換わる
    try volume.rename("/OUT.PSBT", "/out.psbt");
    try std.testing.expectEqualStrings("out.psbt", (try volume.stat("/out.psbt")).nameSlice());
    try expectFileContent(&volume, "/out.psbt", "b");
}

test "write: 名前の検証（長すぎる・使えない文字・空）" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var long_name: [300]u8 = @splat('a');
    long_name[0] = '/';
    try std.testing.expectError(error.NameTooLong, volume.writeFile(&long_name, "x"));

    try std.testing.expectError(error.InvalidEncoding, volume.writeFile("/BAD:NAME.TXT", "x"));
    try std.testing.expectError(error.InvalidEncoding, volume.writeFile("/BAD*NAME.TXT", "x"));
    try std.testing.expectError(error.InvalidPath, volume.writeFile("/", "x"));
    try std.testing.expectError(error.InvalidPath, volume.writeFile("/.", "x"));
    try std.testing.expectError(error.InvalidPath, volume.writeFile("/..", "x"));
    try std.testing.expectError(error.InvalidPath, volume.writeFile("REL.TXT", "x"));
}

test "write: 255 コード単位ちょうどの名前を書ける" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 256 });
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var name: [1 + 251 + 4]u8 = @splat('b');
    name[0] = '/';
    @memcpy(name[252..256], ".bin"); // 251 + 4 = 255 コード単位
    try volume.writeFile(&name, "max name");
    var buffer: [32]u8 = @splat(0);
    try std.testing.expectEqualStrings("max name", try volume.readFile(&name, &buffer));

    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var found = false;
    while (try iterator.next(&entry)) {
        if (std.mem.eql(u8, entry.nameSlice(), name[1..])) {
            found = true;
            try std.testing.expectEqual(@as(u16, 255), entry.name_len);
            try std.testing.expectEqual(@as(u8, 20), entry.lfn_count);
        }
    }
    try std.testing.expect(found);
}

test "write: ミラーリング無効のボリュームでは有効な FAT だけを更新する" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .mirroring_disabled = true });
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    try std.testing.expect(!volume.bpb.mirrored);
    try std.testing.expectEqual(@as(u8, 0), volume.bpb.active_fat);

    try volume.writeFile("/OUT.TMP", "mirroring off");
    try expectFileContent(&volume, "/OUT.TMP", "mirroring off");

    // 2 枚目は触られていない（0 のまま）
    const second = image.firstFatSector() + image.sectors_per_fat;
    const offset = image.fatOffset(3).offset;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, image.sector(second)[offset..][0..4], .little) & fat_mask);
}

test "write: 8.3 で使えない文字を含む名前は別名に寄せる" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/out.psbt", "lowercase name");
    const entry = try volume.stat("/out.psbt");
    try std.testing.expectEqualStrings("out.psbt", entry.nameSlice());
    var short_buffer: [12]u8 = @splat(0);
    try std.testing.expectEqualStrings("OUT~1.PSB", entry.shortDisplay(&short_buffer));

    // 2 つ目は ~2 になる
    try volume.writeFile("/out2.psbt", "second");
    const second = try volume.stat("/out2.psbt");
    var second_buffer: [12]u8 = @splat(0);
    try std.testing.expectEqualStrings("OUT2~1.PSB", second.shortDisplay(&second_buffer));

    // 予約名（CON）は 8.3 にせず LFN にする
    try volume.writeFile("/CON", "reserved");
    const reserved = try volume.stat("/CON");
    try std.testing.expect(reserved.has_lfn);
    try std.testing.expectEqualStrings("CON", reserved.nameSlice());
}

test "write: 書き込み後の不変条件（FAT 2 枚の一致と FSInfo の整合）" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 512 });
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var payload: [3333]u8 = undefined;
    fillPattern(&payload, 77);
    try volume.writeFile("/A-LONG-NAME-1.bin", &payload);
    try volume.writeFile("/B.BIN", payload[0..100]);
    try volume.writeFile("/A-LONG-NAME-1.bin", payload[0..1500]);
    try volume.deleteFile("/B.BIN");
    try volume.rename("/A-LONG-NAME-1.bin", "/C.TMP");
    try volume.rename("/C.TMP", "/D.PSBT");

    try std.testing.expect(image.fatCopiesMatch());
    try std.testing.expectEqual(image.freeClusters(), volume.fs_info.free_count);
    const on_disk_free = std.mem.readInt(
        u32,
        image.sector(image.partition_sector + image.fs_info_sector)[488..492],
        .little,
    );
    try std.testing.expectEqual(image.freeClusters(), on_disk_free);

    var buffer: [3333]u8 = @splat(0);
    const data = try volume.readFile("/D.PSBT", &buffer);
    try std.testing.expectEqualSlices(u8, payload[0..1500], data);

    // FAT のチェーンも壊れていない（使用中の全クラスタから辿って循環が無いこと）
    var cluster: u32 = 2;
    while (cluster <= image.cluster_count + 1) : (cluster += 1) {
        if (image.getFat(cluster) == fat_free) continue;
        var walker = Fat32.ChainWalker.init(&volume, cluster);
        var steps: u32 = 0;
        while (try walker.next()) |_| {
            steps += 1;
            try std.testing.expect(steps <= image.cluster_count);
        }
    }
}
