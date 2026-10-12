//! FAT32 mount and read/write (the minimum needed to exchange PSBTs over microSD).
//!
//! **Supported scope**
//! - Mount: find a FAT32 partition in the first 4 MBR entries.
//!   A superfloppy with no partition table is accepted too.
//! - BPB: 512-byte sectors only. Cluster size is 1 to 128 sectors (a power of two).
//! - File listing (including subdirectories), reading (following the FAT chain;
//!   fragmentation is fine), writing (create and overwrite), deleting, renaming
//! - Reading and writing long file names (LFN / VFAT), including UTF-8 ↔ UTF-16 conversion.
//!   `IN.PSBT` has a 4-character extension, so it does not fit 8.3 and **always becomes an LFN**.
//! - Paths are absolute and separated by `/`. Case is folded within ASCII only
//!   (the FAT convention. Non-ASCII LFN characters are compared byte by byte).
//!
//! **Unsupported scope** (deliberately not implemented)
//! - FAT12 / FAT16 / exFAT (`error.UnsupportedFatType`)
//! - Sector sizes other than 512 (`error.InvalidEncoding`)
//! - Creating subdirectories (writing into existing directories is allowed)
//! - Setting date and time (fixed at 1980-01-01, time 0)
//! - Defragmentation (free clusters are simply searched in order)
//! - chkdsk-style validation (the two FAT copies are not compared, nor FSInfo checked)
//! - Moving to another directory (rename works within the same directory only)
//! - Paths containing `..`, drive letters, `\` separators, relative paths
//! - Write atomicity (a power loss can leave an empty file or unattached clusters)
//! - On a volume with mirroring disabled (`BPB_ExtFlags` bit 7), only the active
//!   FAT copy is read and written (writing both would corrupt it)
//!
//! **Memory**
//! - At mount time, only one cluster (sector size x sectors per cluster) is allocated
//!   from the allocator. No buffer holds a whole file.
//! - Directory traversal uses a caller-provided `Iterator` (about 1.1KB).
//! - Write-side scratch space is at most about 4KB (`Iterator` + `Entry` + name buffer).
// SPDX-License-Identifier: GPL-3.0-or-later

const std = @import("std");
const block_device = @import("block_device.zig");
const BlockDevice = block_device.BlockDevice;
const sector_size = block_device.sector_size;

/// Maximum LFN length (UTF-16 code units). 255 per the FAT specification.
pub const max_name_utf16 = 255;
/// Maximum length needed to represent an LFN name in UTF-8 (at most 3 bytes per code unit).
pub const max_name_utf8 = max_name_utf16 * 3;

const entry_size = 32;
const entries_per_sector = sector_size / entry_size;
/// Number of UTF-16 code units that fit in one LFN entry.
const lfn_chars = 13;
/// Upper bound on the number of LFN entries needed to hold 255 code units.
const max_lfn_entries = (max_name_utf16 + lfn_chars - 1) / lfn_chars;

const attr_read_only: u8 = 0x01;
const attr_hidden: u8 = 0x02;
const attr_system: u8 = 0x04;
const attr_volume_id: u8 = 0x08;
const attr_directory: u8 = 0x10;
const attr_archive: u8 = 0x20;
/// Attribute of an LFN entry (READ_ONLY|HIDDEN|SYSTEM|VOLUME_ID).
const attr_lfn: u8 = attr_read_only | attr_hidden | attr_system | attr_volume_id;

/// First byte of a deleted entry.
const entry_free: u8 = 0xE5;
/// First byte marking the end of a directory.
const entry_end: u8 = 0x00;

/// Mask used for FAT values (the top 4 bits are reserved).
const fat_mask: u32 = 0x0FFFFFFF;
/// Bad cluster.
const fat_bad: u32 = 0x0FFFFFF7;
/// End of chain (values at or above this are EOC).
const fat_eoc_min: u32 = 0x0FFFFFF8;
/// Free cluster.
const fat_free: u32 = 0;

/// Value meaning "unknown" in FSInfo.
const value_unknown: u32 = 0xFFFFFFFF;
/// FSInfo signature.
const fsinfo_lead_signature: u32 = 0x41615252;
const fsinfo_struct_signature: u32 = 0x61417272;
const fsinfo_trail_signature: u32 = 0xAA550000;

/// Date written into entries (1980-01-01). The time is not set (0).
const default_date: u16 = (1 << 5) | 1;

/// FAT32 errors. `InvalidEncoding` / `BufferTooSmall` / `Truncated` /
/// `OutOfMemory` use the same values as `core/errors.zig` (for display purposes).
pub const Error = block_device.Error || error{
    /// Malformed BPB, name, or UTF-8/UTF-16
    InvalidEncoding,
    /// Not an absolute path, contains "..", an empty name, etc.
    InvalidPath,
    /// The name exceeds the FAT limit (255 UTF-16 code units)
    NameTooLong,
    /// The output buffer is too small
    BufferTooSmall,
    /// The device is smaller than the file system
    Truncated,
    /// Memory allocation failed
    OutOfMemory,
    /// Not FAT32
    NotFat32,
    /// FAT12 / FAT16 / exFAT (when it is known not to be FAT32)
    UnsupportedFatType,
    /// Broken structure: a FAT chain loop, out of range, a free cluster in a chain, etc.
    CorruptChain,
    /// No entry at the given path
    NotFound,
    /// Not a file (a directory or volume label)
    NotAFile,
    /// The operation is invalid for a directory
    IsDirectory,
    /// Tried to descend into something that is not a directory
    NotADirectory,
    /// No free cluster
    NoFreeCluster,
    /// No free entry, or no free 8.3 alias even after trying 999999 of them
    NameCollision,
    /// The name is already in use (e.g. as a rename destination)
    AlreadyExists,
};

// ---------------------------------------------------------------------------
// BPB (BIOS Parameter Block)
// ---------------------------------------------------------------------------

/// The FAT32 BPB and the layout derived from it.
pub const Bpb = struct {
    /// First sector of the volume (0 for a superfloppy).
    partition_sector: u32,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sectors: u16,
    fat_count: u8,
    sectors_per_fat: u32,
    root_cluster: u32,
    /// Total number of sectors in the partition.
    total_sectors: u32,
    fs_info_sector: u16,
    backup_boot_sector: u16,
    /// First sector of the first FAT (absolute LBA).
    fat_sector: u32,
    /// First sector of the data area (absolute LBA).
    data_sector: u32,
    /// Number of clusters in the data area. Cluster numbers run from 2 to `cluster_count + 1`.
    cluster_count: u32,
    /// FAT copy in use (non-zero only when mirroring is disabled).
    active_fat: u8,
    /// Whether the FAT is mirrored (whether both copies may be updated).
    mirrored: bool,
    volume_label: [11]u8,

    pub fn clusterSize(self: *const Bpb) usize {
        return @as(usize, self.sectors_per_cluster) * sector_size;
    }

    /// Highest valid cluster number.
    pub fn maxCluster(self: *const Bpb) u32 {
        return self.cluster_count + 1;
    }

    /// Compute the first sector (absolute LBA) of a cluster number. The caller validates the range.
    pub fn clusterToSector(self: *const Bpb, cluster: u32) u32 {
        std.debug.assert(cluster >= 2 and cluster <= self.maxCluster());
        const offset = @as(u64, cluster - 2) * @as(u64, self.sectors_per_cluster);
        return @intCast(@as(u64, self.data_sector) + offset);
    }

    /// Sector holding the entry for `cluster` in the given FAT copy.
    pub fn fatSectorOf(self: *const Bpb, cluster: u32, copy: u8) u32 {
        const byte_offset = @as(u64, cluster) * 4;
        const sector_offset = byte_offset / sector_size;
        return @intCast(@as(u64, self.fat_sector) + @as(u64, copy) * @as(u64, self.sectors_per_fat) + sector_offset);
    }

    /// Entry position within the sector (in bytes).
    pub fn fatOffsetOf(cluster: u32) usize {
        return (@as(usize, cluster) * 4) % sector_size;
    }
};

/// Interpret the boot sector as a BPB. FAT12/16/exFAT are rejected with dedicated errors.
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

    // FAT12 / FAT16 have a fixed-size root directory (root_entries != 0) and the
    // FAT length in the 16-bit field. exFAT was already rejected by OEM name.
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

    // Whether the FAT can hold every cluster number (1 sector = 128 entries).
    const fat_entries = @as(u64, fat_32) * (sector_size / 4);
    if (fat_entries < @as(u64, cluster_count) + 2) return error.InvalidEncoding;

    const root_cluster = std.mem.readInt(u32, sector[44..48], .little);
    if (root_cluster < 2 or root_cluster > cluster_count + 1) return error.InvalidEncoding;

    if (@as(u64, partition_sector) + @as(u64, total_sectors) > device_sectors) return error.Truncated;

    // When mirroring is disabled, use only the active FAT copy.
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
// Directory entries
// ---------------------------------------------------------------------------

/// One directory entry. `name` is the LFN when there is one, otherwise the 8.3
/// name converted to UTF-8. Take the name slice with `nameSlice()`.
pub const Entry = struct {
    name: [max_name_utf8]u8 = @splat(0),
    name_len: u16 = 0,
    /// Raw 11-byte short name (a leading 0x05 is already corrected to 0xE5).
    short_name: [11]u8 = @splat(' '),
    /// NT case flags of the short name (bit3: base is lowercase, bit4: extension is lowercase).
    case_flags: u8 = 0,
    attr: u8 = 0,
    /// Whether a validated LFN was attached.
    has_lfn: bool = false,
    /// Number of validated consecutive LFN entries immediately before the short-name entry.
    lfn_count: u8 = 0,
    first_cluster: u32 = 0,
    size: u32 = 0,
    /// Linear entry number within the directory (used by delete and rename).
    index: u32 = 0,
    /// Sector holding the short-name entry (absolute LBA).
    sector: u32 = 0,
    /// Offset within that sector (a multiple of 32).
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

    /// "." or ".." (the caller decides whether to list them).
    pub fn isDot(self: *const Entry) bool {
        if (self.short_name[0] != '.') return false;
        const dots: usize = if (self.short_name[1] == '.') 2 else 1;
        for (self.short_name[dots..]) |c| {
            if (c != ' ') return false;
        }
        return true;
    }

    /// 8.3 name for display (with NT case flags applied). `buffer` must be at least 12 bytes.
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

/// State for one cluster used by a listing traversal.
const ClusterCursor = struct {
    fs: *Fat32,
    cluster: u32,
    sector_in_cluster: u16 = 0,
    steps: u32 = 0,

    fn init(fs: *Fat32, cluster: u32) ClusterCursor {
        return .{ .fs = fs, .cluster = cluster };
    }

    /// Successor of this cluster, or null at the end of the chain. A loop is `CorruptChain`.
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
// File names (8.3 and LFN)
// ---------------------------------------------------------------------------

/// Result of preparing a name for writing.
const NameInfo = struct {
    units: [max_name_utf16]u16 = @splat(0),
    unit_count: u16 = 0,
    short_name: [11]u8 = @splat(' '),
    /// Number of LFN entries to write before the short name (0 means 8.3 only).
    lfn_count: u8 = 0,
};

/// LFN checksum (computed from the 11-byte short name).
fn shortNameChecksum(short: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (short) |c| sum = (sum >> 1) +% ((sum & 1) << 7) +% c;
    return sum;
}

/// Offset of the `index`-th (0 to 12) code unit within an LFN entry.
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

/// Whether a name can be used as 8.3 as is (uppercase only, within 8+3, allowed characters only).
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

/// Names Windows treats specially (not allowed in 8.3).
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

/// Build the 11-byte 8.3 form ("NAME    EXT"). Pass only names where `isPlainShortName` is true.
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

/// Map characters unusable in 8.3 to '_' (lowercase becomes uppercase).
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

/// Convert UTF-8 to UTF-16. A malformed sequence is `InvalidEncoding`.
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

/// Convert UTF-16 to UTF-8. Unpaired surrogates become U+FFFD
/// (so a name written by a PC does not fail the whole listing).
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

/// Compare case-insensitively within the ASCII range.
fn asciiCaseEqual(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toUpper(x) != std.ascii.toUpper(y)) return false;
    }
    return true;
}

/// Whether `name` refers to this entry (matching either the LFN name or the 8.3 name is enough).
fn nameMatches(entry: *const Entry, name: []const u8) bool {
    if (asciiCaseEqual(entry.nameSlice(), name)) return true;
    var buffer: [12]u8 = @splat(0);
    return asciiCaseEqual(entry.shortDisplay(&buffer), name);
}

/// Validate a name to be written.
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
// The FAT32 volume itself
// ---------------------------------------------------------------------------

const FatCache = struct {
    valid: bool = false,
    dirty: bool = false,
    /// Sector within the active FAT copy (absolute LBA).
    sector: u32 = 0,
    data: [sector_size]u8 = @splat(0),
};

const FsInfo = struct {
    /// Whether an FSInfo with a valid signature was found. Without it, free_count is not updated.
    valid: bool = false,
    sector: u32 = 0,
    /// FSInfo in the backup boot sector (only when the signature is valid).
    backup_sector: ?u32 = null,
    next_free: u32 = value_unknown,
    free_count: u32 = value_unknown,
};

/// Result used when extending a directory by one cluster during a write.
const DataChain = struct {
    first_cluster: u32,
    cluster_count: u32,
};

/// A mounted FAT32 volume.
///
/// Not thread-safe (one volume is used by one operation at a time).
/// Reads are not reentrant either, because they share the scratch buffer.
pub const Fat32 = struct {
    device: BlockDevice,
    allocator: std.mem.Allocator,
    bpb: Bpb,
    /// Scratch buffer for one cluster.
    cluster_buf: []u8,
    fat_cache: FatCache = .{},
    fs_info: FsInfo = .{},

    /// Mount FAT32 from a block device.
    /// Call `deinit` on success.
    pub fn mount(device: BlockDevice, allocator: std.mem.Allocator) Error!Fat32 {
        var boot: [sector_size]u8 = @splat(0);
        try device.readSector(0, &boot);
        const device_sectors = device.sectorCount();

        // 1. Superfloppy (no partition table, the BPB is at the start)
        if (parseBpb(&boot, 0, device_sectors)) |bpb| {
            return finishMount(device, allocator, bpb);
        } else |super_error| {
            // 2. Find a FAT32 partition in the first 4 MBR entries
            if (parseMbr(&boot, device, device_sectors)) |bpb| {
                return finishMount(device, allocator, bpb);
            } else |mbr_error| {
                if (super_error == error.UnsupportedFatType) return error.UnsupportedFatType;
                if (mbr_error == error.UnsupportedFatType) return error.UnsupportedFatType;
                // If the start looks like a FAT boot sector, return that reason instead
                // (so a corrupt BPB is not misreported as "not FAT32")
                if (mbr_error == error.NotFat32 and looksLikeFatBootSector(&boot)) return super_error;
                return mbr_error;
            }
        }
    }

    pub fn deinit(self: *Fat32) void {
        self.allocator.free(self.cluster_buf);
        self.cluster_buf = self.cluster_buf[0..0];
    }

    /// First cluster of the root directory.
    pub fn rootCluster(self: *const Fat32) u32 {
        return self.bpb.root_cluster;
    }

    pub fn clusterSize(self: *const Fat32) usize {
        return self.bpb.clusterSize();
    }

    /// Return the entry for a path. `/` is the root directory itself.
    pub fn stat(self: *Fat32, path: []const u8) Error!Entry {
        var entry: Entry = .{};
        if (!try self.findPath(path, &entry)) return error.NotFound;
        return entry;
    }

    /// Whether a path exists. Returns false only when missing; other errors pass through.
    pub fn exists(self: *Fat32, path: []const u8) Error!bool {
        var entry: Entry = .{};
        return self.findPath(path, &entry);
    }

    /// Build an iterator over a directory.
    pub fn openDir(self: *Fat32, path: []const u8) Error!Iterator {
        var entry: Entry = .{};
        if (!try self.findPath(path, &entry)) return error.NotFound;
        if (!entry.isDirectory()) return error.NotADirectory;
        return self.iterate(entry.first_cluster);
    }

    /// Read a file. `out` must be at least `size` bytes long (otherwise `BufferTooSmall`).
    pub fn readFile(self: *Fat32, path: []const u8, out: []u8) Error![]u8 {
        const entry = try self.stat(path);
        return self.readEntry(&entry, out);
    }

    /// Read a file into a newly allocated buffer. A file larger than `max_bytes` gives
    /// `BufferTooSmall` (this is where the 64KB PSBT limit is enforced).
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

    /// Write a file (overwriting an existing one). The parent directory must exist.
    ///
    /// Overwriting frees the old clusters before writing the new data, so a power loss
    /// can leave an empty file behind (it is not atomic).
    pub fn writeFile(self: *Fat32, path: []const u8, data: []const u8) Error!void {
        const parts = try splitPath(path);
        try validateName(parts.name);
        if (data.len > 0xFFFFFFFF) return error.BufferTooSmall; // The FAT size field is 32 bits
        const parent = try self.stat(parts.parent);
        if (!parent.isDirectory()) return error.NotADirectory;

        // Find an existing entry (so making an 8.3 alias does not collide with itself)
        var existing: Entry = .{};
        const found = try self.findEntryInDir(parent.first_cluster, parts.name, &existing);
        if (found) {
            if (existing.isDirectory()) return error.IsDirectory;
            if (existing.isVolumeLabel()) return error.NotAFile;
        }

        var info: NameInfo = .{};
        try self.prepareName(parent.first_cluster, parts.name, if (found) existing.index else null, &info);

        if (found and existing.index < existing.lfn_count) return error.CorruptChain;

        // Overwrite: clear the entry first, then free the old clusters
        if (found and existing.lfn_count == info.lfn_count) {
            try self.clearEntryData(&existing);
        }
        if (found) {
            _ = try self.freeChain(existing.first_cluster);
        }

        // Reserve slots for the name (reuse them when the slot count is unchanged)
        var slot_index: u32 = 0;
        if (found and existing.lfn_count == info.lfn_count) {
            slot_index = existing.index - existing.lfn_count;
        } else {
            if (found) {
                try self.markDeleted(parent.first_cluster, existing.index - existing.lfn_count, existing.index);
            }
            slot_index = try self.allocateSlots(parent.first_cluster, @as(u32, info.lfn_count) + 1);
        }

        // Write the data before the entry (so a half-written file never looks complete)
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

    /// Delete a file (freeing its clusters too).
    pub fn deleteFile(self: *Fat32, path: []const u8) Error!void {
        const parts = try splitPath(path);
        const parent = try self.stat(parts.parent);
        if (!parent.isDirectory()) return error.NotADirectory;

        var entry: Entry = .{};
        if (!try self.findEntryInDir(parent.first_cluster, parts.name, &entry)) return error.NotFound;
        if (entry.isDirectory()) return error.IsDirectory;
        if (entry.isVolumeLabel()) return error.NotAFile;
        if (entry.index < entry.lfn_count) return error.CorruptChain;

        // Delete the entry first (leaking clusters on power loss is safer than double-linking)
        try self.markDeleted(parent.first_cluster, entry.index - entry.lfn_count, entry.index);
        _ = try self.freeChain(entry.first_cluster);
    }

    /// Rename within the same directory. The data (clusters) is not moved.
    ///
    /// Only the name is rewritten. For names that do not fit 8.3 (`OUT.PSBT` qualifies,
    /// because its extension is 4 characters) the LFN entries are rebuilt.
    /// **When the destination name already exists this is `error.AlreadyExists`** (no overwrite).
    /// Call `deleteFile` first if you want to overwrite.
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
            // Same slot count: rewrite only the name in place
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

        // The slot count changes: reserve the new location first, then delete the old name.
        // (A power loss midway leaves "nothing". The clusters are not moved.)
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

    // -- Internal: mount ---------------------------------------------------

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

    /// Verify the FSInfo signature and trust free_count / next_free only when usable.
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

    /// Write the cluster count and the next search position to FSInfo (no-op without an FSInfo).
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

    // -- Internal: scratch buffers -----------------------------------------

    /// Scratch area for one sector (uses the head of the one-cluster buffer).
    fn sectorBuf(self: *Fat32) *[sector_size]u8 {
        return self.cluster_buf[0..sector_size];
    }

    // -- Internal: FAT -----------------------------------------------------

    fn loadFatSector(self: *Fat32, lba: u32) Error!void {
        if (self.fat_cache.valid and self.fat_cache.sector == lba) return;
        try self.flushFat();
        try self.device.readSector(lba, &self.fat_cache.data);
        self.fat_cache.sector = lba;
        self.fat_cache.valid = true;
    }

    /// Write back buffered FAT sectors (to both copies when mirrored).
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

    /// Find a free cluster starting at `from` (wrapping to the beginning after the end).
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

    /// Read one cluster (`out` must hold one cluster).
    fn readCluster(self: *Fat32, cluster: u32, out: []u8) Error!void {
        try self.device.readSectors(self.bpb.clusterToSector(cluster), out[0..self.clusterSize()]);
    }

    /// Write one cluster (`data` must hold one cluster).
    fn writeCluster(self: *Fat32, cluster: u32, data: []const u8) Error!void {
        try self.device.writeSectors(self.bpb.clusterToSector(cluster), data[0..self.clusterSize()]);
    }

    fn zeroCluster(self: *Fat32, cluster: u32) Error!void {
        @memset(self.cluster_buf, 0);
        try self.writeCluster(cluster, self.cluster_buf);
    }

    // -- Internal: chains --------------------------------------------------

    /// Walk a FAT chain one cluster at a time. The FAT entry of a returned cluster may
    /// be rewritten (its successor was read in advance). Loops are caught by the cluster cap.
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

    /// Free a chain (set its FAT entries to 0). Returns the number of clusters freed.
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

    // -- Internal: paths ---------------------------------------------------

    const PathParts = struct {
        /// Parent directory path (includes `/`).
        parent: []const u8,
        /// Last component (the file name).
        name: []const u8,
    };

    /// Split an absolute path into parent and name. The name is never empty.
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

    /// Walk a path component by component. False when it is not found.
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

    /// Find one entry by name in directory `dir_cluster`.
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

    // -- Internal: name preparation ----------------------------------------

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

    /// Build an 8.3 alias for a long name (the "LONGFI~1.BIN" form).
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

    /// Whether an 8.3 alias is already in use (the entry at `ignore_index` is not counted).
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

    // -- Internal: reading ------------------------------------------------

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
            if (next >= fat_eoc_min) return error.CorruptChain; // Chain shorter than the size
            if (next > self.bpb.maxCluster()) return error.CorruptChain;
            steps += 1;
            if (steps > self.bpb.cluster_count) return error.CorruptChain; // A loop
            cluster = next;
        }

        // After reading `size` bytes, check that the chain really ends.
        // If it does not (it is longer than the size, or loops), walk it with a limit to check.
        // A chain that is merely longer than the size does not affect the bytes read, so it
        // is allowed, but a chain that comes back around becomes `CorruptChain` here.
        const tail = try self.fatGet(cluster);
        if (tail != fat_bad and tail != fat_free and tail != 1 and tail < fat_eoc_min) {
            var walker = ChainWalker.init(self, cluster);
            while (try walker.next()) |_| {}
        }
        return out[0..size];
    }

    // -- Internal: writing ------------------------------------------------

    /// Write data into clusters and link the FAT. Returns the first cluster allocated.
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
                // Free what was allocated on failure (cleanup does not hide the real error)
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

    /// Clear the data fields (first cluster and size) of an existing entry.
    fn clearEntryData(self: *Fat32, entry: *const Entry) Error!void {
        const buffer = self.sectorBuf();
        try self.device.readSector(entry.sector, buffer);
        const offset = entry.offset;
        std.mem.writeInt(u16, buffer[offset + 20 ..][0..2], 0, .little);
        std.mem.writeInt(u16, buffer[offset + 26 ..][0..2], 0, .little);
        std.mem.writeInt(u32, buffer[offset + 28 ..][0..4], 0, .little);
        try self.device.writeSector(entry.sector, buffer);
    }

    /// Reserve `count` consecutive free entries and return the linear number of the first one.
    /// If there are not enough, append clusters to the directory to extend it.
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

        // Not enough even at the end of the chain: append clusters (zero-filled = free)
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

    /// Mark the entries in the given linear-number range as deleted (0xE5).
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

    /// Write a group of entries (LFN + short name) starting at `start_index`.
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

/// Assemble the LFN entries (in disk order) and the short-name entry.
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
    if (short[0] == 0xE5) short[0] = 0x05; // So it is not mistaken for a deleted entry
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

/// Whether the first sector looks like a FAT boot sector (used to pick the error when
/// the BPB is corrupt. The jump instruction is checked too, so an MBR is not mistaken for one).
fn looksLikeFatBootSector(sector: *const [sector_size]u8) bool {
    if (sector[510] != 0x55 or sector[511] != 0xAA) return false;
    if (sector[0] != 0xEB and sector[0] != 0xE9) return false;
    const bytes_per_sector = std.mem.readInt(u16, sector[11..13], .little);
    return bytes_per_sector >= sector_size and bytes_per_sector % sector_size == 0;
}

/// Find a FAT32 partition in the first 4 MBR entries.
fn parseMbr(mbr: *const [sector_size]u8, device: BlockDevice, device_sectors: u64) Error!Bpb {
    if (mbr[510] != 0x55 or mbr[511] != 0xAA) return error.NotFat32;

    var boot: [sector_size]u8 = @splat(0);
    var saw_fat32_type = false;
    var saw_other_fat = false;
    var last_error: Error = error.NotFat32;

    // First pass: prefer partitions whose type is FAT32 (0x0B / 0x0C)
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

    // Second pass: accept any type if the BPB can be read (for real cards with odd type bytes)
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
// Directory iterator
// ---------------------------------------------------------------------------

/// Iterator returning directory entries one at a time. Provided by the caller (about 1.1KB).
///
/// Usage:
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
    cluster: u32 = 0,
    sector_in_cluster: u16 = 0,
    sector_lba: u32 = 0,
    sector: [sector_size]u8 = @splat(0),
    sector_loaded: bool = false,
    entry_index: u16 = 0,
    /// Linear entry number within the directory (the next position to read).
    index: u32 = 0,
    done: bool = false,
    steps: u32 = 0,
    lfn_units: [max_name_utf16]u16 = @splat(0),
    /// Bitmask of the ordinals seen (bits 1 to 20).
    lfn_seen: u32 = 0,
    lfn_total: u8 = 0,
    lfn_count: u8 = 0,
    lfn_checksum: u8 = 0,
    lfn_valid: bool = false,
    lfn_last_index: u32 = 0,

    /// Write the next entry to `out`. False at the end of the directory.
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

    /// Take in one LFN entry. If anything is inconsistent, drop `lfn_valid` and
    /// use only the short name (so the whole listing does not fail).
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
            if (index != self.lfn_last_index + 1) self.lfn_valid = false; // Gaps are not accepted
            if (raw[13] != self.lfn_checksum) self.lfn_valid = false;
            if (ordinal == 0 or ordinal > self.lfn_total) {
                self.lfn_valid = false;
            } else if (@as(i32, ordinal) != @as(i32, self.lfn_total) - @as(i32, self.lfn_count)) {
                self.lfn_valid = false; // Whether they arrive from the top down (N, N-1, ..., 1)
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
            // A volume label uses all 11 bytes as is (no 8.3 splitting)
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
// Tests
// ---------------------------------------------------------------------------

test "core/errors.zig and the shared error values match" {
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

/// Synthetic FAT32 image for tests.
///
/// Reproduces the minimum of the structure mkfs.fat creates (BPB, FSInfo, 2 FATs, root
/// directory). By the specification FAT32 needs at least 33MB, so a real image cannot be
/// embedded in a test. Instead a small volume that is "consistent as FAT32" is built here
/// and the implementation's reads and writes are exercised in memory.
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
        /// Total number of sectors in the partition.
        total_sectors: u32 = 1024,
        sectors_per_cluster: u8 = 1,
        fat_count: u8 = 2,
        /// When non-zero, write an MBR and place the partition at that position.
        partition_sector: u32 = 0,
        /// Volume label to place in the root directory (an 11-byte short name).
        volume_label: ?[]const u8 = null,
        /// Whether to place an FSInfo (whether to write the signature).
        fs_info: bool = true,
        /// Whether to disable FAT mirroring (ExtFlags bit 7).
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

        // Converge on the smallest length that can hold its own FAT
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

        // The first 2 reserved entries and the root directory cluster
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

    /// Write to both FAT copies (independent of the implementation).
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
        std.mem.writeInt(u16, boot[17..19], 0, .little); // 0 for FAT32
        std.mem.writeInt(u16, boot[19..21], 0, .little);
        boot[21] = 0xF8;
        std.mem.writeInt(u16, boot[22..24], 0, .little); // 0 for FAT32
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

    /// Write entries into free directory slots (appending clusters when there are not enough).
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

    /// Write data and link clusters. Returns the first cluster.
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

    /// Write a file with an LFN (an independent implementation on the test side).
    fn addLfnFile(self: *TestImage, dir_cluster: u32, name: []const u8, data: []const u8) !void {
        const first = try self.allocChain(data);

        var units: [max_name_utf16]u16 = @splat(0);
        var unit_count: usize = 0;
        for (name) |c| {
            if (c >= 0x80) return error.TestUnexpectedResult;
            units[unit_count] = c;
            unit_count += 1;
        }

        // The short name is 6 base characters + "~1" + a 3-character extension
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

    /// Create a subdirectory (including "." and "..").
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

    /// Free a chain (used by tests to create fragmentation).
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

    /// Compare the second FAT against the first (to confirm they match after a write).
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

/// Test helper: compare read contents as a string.
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

test "mount: reads the superfloppy BPB and FSInfo" {
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

test "mount: finds FAT32 in the first 4 MBR entries" {
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

test "mount: a sector size other than 512 is InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    std.mem.writeInt(u16, image.sector(0)[11..13], 1024, .little);

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: an invalid sectors-per-cluster value is InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    image.sector(0)[13] = 3; // Not a power of two

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: FAT12 / FAT16 is UnsupportedFatType" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // Turn the BPB into a FAT16 one (root entry count != 0, FAT length in the 16-bit field)
    std.mem.writeInt(u16, image.sector(0)[17..19], 512, .little);
    std.mem.writeInt(u16, image.sector(0)[22..24], 40, .little);
    std.mem.writeInt(u32, image.sector(0)[36..40], 0, .little);

    try std.testing.expectError(error.UnsupportedFatType, Fat32.mount(image.device(), allocator));
}

test "mount: exFAT is UnsupportedFatType" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    @memcpy(image.sector(0)[3..11], "EXFAT   ");

    try std.testing.expectError(error.UnsupportedFatType, Fat32.mount(image.device(), allocator));
}

test "mount: a volume larger than the device is Truncated" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // Make the device 4KB shorter (the BPB is left as is)
    const full = image.dev.storage;
    image.dev.storage = full[0 .. full.len - 4096];
    try std.testing.expectError(error.Truncated, Fat32.mount(image.device(), allocator));
    image.dev.storage = full; // Restore it so deinit can free it
}

test "mount: a root cluster out of range is InvalidEncoding" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    std.mem.writeInt(u32, image.sector(0)[44..48], image.cluster_count + 100, .little);

    try std.testing.expectError(error.InvalidEncoding, Fat32.mount(image.device(), allocator));
}

test "mount: neither a partition table nor a BPB is NotFat32" {
    const allocator = std.testing.allocator;
    var memory = try block_device.MemoryDevice.create(allocator, 64 * sector_size);
    defer memory.deinit(allocator);

    try std.testing.expectError(error.NotFat32, Fat32.mount(memory.device(), allocator));
}

test "list: enumerates root short names, LFNs, and the volume label" {
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

test "list: a subdirectory (including . and ..) and the NT lowercase flag" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    const sub = try image.addDirectory(image.root_cluster, &short_zhww);
    try image.addFile(sub, &short_out_tmp, "signed psbt");

    // A short name with NT case flags (the form Windows puts on a lowercase 8.3 name)
    var lower: [11]u8 = @splat(' ');
    @memcpy(lower[0..6], "lowerc");
    @memcpy(lower[8..11], "txt");
    var slot: [entry_size]u8 = @splat(0);
    @memcpy(slot[0..11], &lower);
    slot[11] = attr_archive;
    slot[12] = 0x18; // Both base and extension are lowercase
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

    // Contents of the subdirectory ("." and ".." are returned too)
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

test "read: reads a short-name file byte for byte" {
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

    // It can be opened in lowercase too (the FAT convention)
    const again = try volume.readFile("/big.bin", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, again);
}

test "read: reads an LFN file by LFN name and by 8.3 name" {
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

test "read: a 4-character extension (IN.PSBT) is read as an LFN" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    // A 4-character extension does not fit 8.3, so it always becomes an LFN
    try image.addLfnFile(image.root_cluster, "IN.PSBT", "psbt payload");

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/IN.PSBT", &buffer);
    try std.testing.expectEqualStrings("psbt payload", data);
}

test "read: reads inside a subdirectory" {
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

test "read: reads a fragmented file spanning several clusters" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    // First place two 4-cluster files, then free the first to create a hole.
    // Writing a 5-cluster file afterwards splits it into the hole (4) plus later clusters.
    try image.addFile(image.root_cluster, &short_readme, "A");
    var hole_payload: [4 * 512]u8 = undefined;
    fillPattern(&hole_payload, 11);
    try image.addFile(image.root_cluster, &short_big, &hole_payload); // Clusters 4 to 7
    var filler_payload: [4 * 512]u8 = undefined;
    fillPattern(&filler_payload, 22);
    var filler_short: [11]u8 = @splat(' ');
    @memcpy(filler_short[0..5], "FILLR");
    try image.addFile(image.root_cluster, &filler_short, &filler_payload); // Clusters 8 to 11
    image.freeChain(4); // Free the hole (clusters 4 to 7)

    var fragmented: [5 * 512]u8 = undefined;
    fillPattern(&fragmented, 33);
    var target_short: [11]u8 = @splat(' ');
    @memcpy(target_short[0..4], "FRAG");
    @memcpy(target_short[8..11], "BIN");
    try image.addFile(image.root_cluster, &target_short, &fragmented); // 4 to 7 + 12

    var chain_buffer: [16]u32 = @splat(0);
    const chain = image.chainOf(4, &chain_buffer);
    try std.testing.expectEqual(@as(usize, 5), chain.len);
    var jump = false;
    for (chain[1..], chain[0 .. chain.len - 1]) |current, previous| {
        if (current != previous + 1) jump = true;
    }
    try std.testing.expect(jump); // Really fragmented

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [5 * 512]u8 = @splat(0);
    const data = try volume.readFile("/FRAG.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &fragmented, data);
}

test "read: a volume with a 4-sector cluster" {
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

test "read: an insufficient output buffer is BufferTooSmall" {
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

test "read: rejects a missing path, a directory, a relative path, and .." {
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

    // "/" and "/ZHWW/" point at the same directory
    const root_entry = try volume.stat("/");
    const sub_entry = try volume.stat("/ZHWW/");
    try std.testing.expectEqual(sub, sub_entry.first_cluster);
    try std.testing.expect(root_entry.isDirectory());

    try std.testing.expect(try volume.exists("/ZHWW"));
    try std.testing.expect(!try volume.exists("/ZHWW/NOPE.TXT"));
}

test "read: a looping FAT chain is CorruptChain (no infinite loop)" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    // Create a file the size of 5 clusters and make the chain loop after 3
    var payload: [5 * 512]u8 = @splat(0x5A);
    try image.addFile(image.root_cluster, &short_big, &payload);
    var chain_buffer: [8]u32 = @splat(0);
    const chain = image.chainOf(3, &chain_buffer);
    try std.testing.expectEqual(@as(usize, 5), chain.len);
    image.setFat(chain[chain.len - 1], chain[0]); // Link the tail back to the head to loop

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [5 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));

    // Listing (the directory is fine) and delete are unaffected... delete does detect the loop
    _ = try volume.stat("/BIG.BIN");
    try std.testing.expectError(error.CorruptChain, volume.deleteFile("/BIG.BIN"));
}

test "read: a self-looping chain is CorruptChain too" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [4 * 512]u8 = @splat(0x33);
    try image.addFile(image.root_cluster, &short_big, &payload);
    image.setFat(3, 3); // Points at itself

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [4 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
}

test "read: a chain pointing out of range or at a free cluster is CorruptChain" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [3 * 512]u8 = @splat(0x44);
    try image.addFile(image.root_cluster, &short_big, &payload);

    // (1) Points out of range
    image.setFat(3, image.cluster_count + 10);
    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    var buffer: [3 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
    volume.deinit();

    // (2) Points at a free cluster
    image.setFat(3, 0);
    var volume2 = try Fat32.mount(image.device(), allocator);
    defer volume2.deinit();
    try std.testing.expectError(error.CorruptChain, volume2.readFile("/BIG.BIN", &buffer));
}

test "read: a chain shorter than the size is CorruptChain" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 96 });
    defer image.deinit(allocator);
    var payload: [3 * 512]u8 = @splat(0x55);
    try image.addFile(image.root_cluster, &short_big, &payload);
    image.setFat(3, fat_eoc_min); // Terminate after one cluster

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var buffer: [3 * 512]u8 = @splat(0);
    try std.testing.expectError(error.CorruptChain, volume.readFile("/BIG.BIN", &buffer));
}

test "write: writes a new short-name file and updates both FATs and FSInfo" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const free_before = image.freeClusters();
    var payload: [1300]u8 = undefined;
    fillPattern(&payload, 99);
    try volume.writeFile("/NEW.BIN", &payload);

    // The two FAT copies match
    try std.testing.expect(image.fatCopiesMatch());

    // 3 clusters were used (1300 bytes / 512)
    try std.testing.expectEqual(free_before - 3, image.freeClusters());
    try std.testing.expectEqual(free_before - 3, volume.fs_info.free_count);

    // FSInfo's free_count is written to disk too
    const fsinfo = image.sector(1);
    try std.testing.expectEqual(free_before - 3, std.mem.readInt(u32, fsinfo[488..492], .little));
    const backup = image.sector(1 + 6);
    try std.testing.expectEqual(free_before - 3, std.mem.readInt(u32, backup[488..492], .little));

    // Readable after writing back
    var buffer: [1300]u8 = @splat(0);
    const data = try volume.readFile("/NEW.BIN", &buffer);
    try std.testing.expectEqualSlices(u8, &payload, data);

    const entry = try volume.stat("/NEW.BIN");
    try std.testing.expectEqual(@as(u32, 1300), entry.size);
    try std.testing.expect(!entry.has_lfn);
    try std.testing.expectEqual(attr_archive, entry.attr);
}

test "write: writes a long name as an LFN with the right order and checksum" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    const name = "LongFileName-PSBT.bin";
    try volume.writeFile("/LongFileName-PSBT.bin", "signed psbt bytes");

    // Confirmed by reading it back through the implementation itself
    var buffer: [64]u8 = @splat(0);
    const data = try volume.readFile("/LongFileName-PSBT.bin", &buffer);
    try std.testing.expectEqualStrings("signed psbt bytes", data);

    // Verify the on-disk LFN independently (order, 0x40, checksum, padding).
    // "LongFileName-PSBT.bin" is 21 code units -> 2 LFN entries + 1 short-name entry.
    // Disk order: second half (ordinal 2, with 0x40), first half (ordinal 1), short name.
    const target = image.sector(image.clusterSector(image.root_cluster));
    const lfn_second = target[0..entry_size];
    const lfn_first = target[entry_size..][0..entry_size];
    const short_entry = target[2 * entry_size ..][0..entry_size];
    try std.testing.expectEqual(@as(u8, attr_lfn), lfn_second[11]);
    try std.testing.expectEqual(@as(u8, attr_lfn), lfn_first[11]);
    try std.testing.expectEqual(@as(u8, 0x42), lfn_second[0]); // Last of a 2-entry set (with 0x40)
    try std.testing.expectEqual(@as(u8, 0x01), lfn_first[0]);
    try std.testing.expectEqual(@as(u8, 0), lfn_second[12]); // The type field of an LFN entry is 0

    var short_name: [11]u8 = short_entry[0..11].*;
    if (short_name[0] == 0x05) short_name[0] = 0xE5;
    try std.testing.expectEqualSlices(u8, "LONGFI~1BIN", &short_name); // Raw 11 bytes (no dot)
    try std.testing.expectEqual(shortNameChecksum(&short_name), lfn_second[13]);
    try std.testing.expectEqual(shortNameChecksum(&short_name), lfn_first[13]);
    try std.testing.expectEqual(@as(u32, 17), std.mem.readInt(u32, short_entry[28..32], .little));

    // Reassemble the UTF-16 and check that it matches the name
    var units: [max_name_utf16]u16 = @splat(0);
    for (0..lfn_chars) |position| {
        units[position] = std.mem.readInt(u16, lfn_first[lfnCharOffset(position)..][0..2], .little);
        units[lfn_chars + position] = std.mem.readInt(u16, lfn_second[lfnCharOffset(position)..][0..2], .little);
    }
    var decoded: [max_name_utf8]u8 = @splat(0);
    const decoded_len = try utf16ToUtf8(&decoded, units[0..21]);
    try std.testing.expectEqualStrings(name, decoded[0..decoded_len]);
    try std.testing.expectEqual(@as(u16, 0x0000), units[21]); // Terminator
    try std.testing.expectEqual(@as(u16, 0xFFFF), units[22]); // Padding after that

    // Readable through the 8.3 alias as well
    const by_short = try volume.readFile("/LONGFI~1.BIN", &buffer);
    try std.testing.expectEqualStrings("signed psbt bytes", by_short);

    // It also shows up in the listing under the long name
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var found = false;
    while (try iterator.next(&entry)) {
        if (std.mem.eql(u8, entry.nameSlice(), name)) found = true;
    }
    try std.testing.expect(found);
}

test "write: a 4-character extension (OUT.PSBT) is written as an LFN" {
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

test "write: a UTF-8 name (Japanese) is written as an LFN" {
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

test "write: overwriting an existing file leaks no clusters" {
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

    // Make it larger
    var large: [2400]u8 = undefined;
    fillPattern(&large, 2);
    try volume.writeFile("/OUT.TMP", &large);
    try std.testing.expectEqual(free_before - 5, image.freeClusters());
    var buffer: [2400]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &large, try volume.readFile("/OUT.TMP", &buffer));

    // Make it smaller
    try volume.writeFile("/out.tmp", &small); // A different case is the same file
    try std.testing.expectEqual(free_before - 1, image.freeClusters());
    try std.testing.expectEqualSlices(u8, &small, try volume.readFile("/OUT.TMP", &buffer));

    // Only one entry
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

test "write: an empty file can be written and read" {
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

    // Put contents in by overwriting
    try volume.writeFile("/EMPTY.TXT", "now it has bytes");
    try std.testing.expectEqualStrings("now it has bytes", try volume.readFile("/EMPTY.TXT", &buffer));

    // Empty it again
    try volume.writeFile("/EMPTY.TXT", "");
    try std.testing.expectEqual(@as(u32, 0), (try volume.stat("/EMPTY.TXT")).first_cluster);
}

test "write: can write into a subdirectory" {
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

test "write: a full directory grows by appending a cluster" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 128 });
    defer image.deinit(allocator);

    // Fill the root directory (16 slots) completely
    var count: u32 = 0;
    while (count < entries_per_sector) : (count += 1) {
        var short: [11]u8 = @splat(' ');
        short[0] = 'A' + @as(u8, @intCast(count / 10)); // A0 to A9, B0 to B5
        short[1] = '0' + @as(u8, @intCast(count % 10));
        @memcpy(short[8..11], "TXT");
        try image.addFile(image.root_cluster, &short, &[_]u8{0x77});
    }
    try std.testing.expect(image.getFat(image.root_cluster) >= fat_eoc_min); // Still one cluster

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    // The name becomes an LFN, so 2 slots are needed -> it has to grow
    var payload: [600]u8 = undefined;
    fillPattern(&payload, 8);
    try volume.writeFile("/Extended-Name.bin", &payload);

    try std.testing.expect(image.getFat(image.root_cluster) < fat_eoc_min); // It grew (not the end)
    try std.testing.expect(image.fatCopiesMatch());

    var buffer: [600]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/Extended-Name.bin", &buffer));
    try std.testing.expectEqualStrings("A0.TXT", (try volume.stat("/A0.TXT")).nameSlice());
    try std.testing.expectEqualStrings("B5.TXT", (try volume.stat("/B5.TXT")).nameSlice());

    // 17 entries in the listing (16 + 1)
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var seen: usize = 0;
    while (try iterator.next(&entry)) seen += 1;
    try std.testing.expectEqual(@as(usize, 17), seen);
}

test "write: no free cluster gives NoFreeCluster" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 64 });
    defer image.deinit(allocator);

    // Fill every free cluster with a single file
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
    // A failure leaves no allocated clusters behind
    try std.testing.expectEqual(@as(u32, 0), image.freeClusters());
}

test "delete: the entry and its clusters disappear" {
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

test "delete: a file with an LFN loses its LFN entries too" {
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

    // The first 2 slots of the directory (LFN + short name) are now deleted
    const target = image.sector(image.clusterSector(image.root_cluster));
    try std.testing.expectEqual(@as(u8, entry_free), target[0]);
    try std.testing.expectEqual(@as(u8, entry_free), target[entry_size]);

    // Writing another file does not corrupt anything
    try volume.writeFile("/AFTER.BIN", "after");
    try expectFileContent(&volume, "/AFTER.BIN", "after");

    // No leftovers show up in the listing
    var item: Entry = .{};
    var iterator = try volume.openDir("/");
    while (try iterator.next(&item)) {
        try std.testing.expect(!std.mem.eql(u8, item.nameSlice(), "IN.PSBT"));
    }
}

test "delete: a directory is IsDirectory" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);
    _ = try image.addDirectory(image.root_cluster, &short_zhww);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    try std.testing.expectError(error.IsDirectory, volume.deleteFile("/ZHWW"));
}

test "rename: OUT.TMP → OUT.PSBT (which needs an LFN) keeps the data" {
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

    // OUT.TMP is 8.3 but OUT.PSBT has a 4-character extension -> the path that rebuilds the LFN
    try volume.rename("/OUT.TMP", "/OUT.PSBT");

    try std.testing.expect(!try volume.exists("/OUT.TMP"));
    const after = try volume.stat("/OUT.PSBT");
    try std.testing.expectEqualStrings("OUT.PSBT", after.nameSlice());
    try std.testing.expect(after.has_lfn);
    try std.testing.expectEqual(before.size, after.size);
    try std.testing.expectEqual(before.first_cluster, after.first_cluster); // The data is not moved
    try std.testing.expectEqual(free_before, image.freeClusters());

    var buffer: [2400]u8 = @splat(0);
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/OUT.PSBT", &buffer));
    try std.testing.expectEqualSlices(u8, &payload, try volume.readFile("/OUT~1.PSB", &buffer));
}

test "rename: between 8.3 names only the name is rewritten in place" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{});
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    try volume.writeFile("/OUT.TMP", "payload");
    const before = try volume.stat("/OUT.TMP");
    const raw_before = image.sector(before.sector)[before.offset + 11]; // The attribute byte

    try volume.rename("/OUT.TMP", "/OUT.LOG");

    const after = try volume.stat("/OUT.LOG");
    try std.testing.expectEqual(before.index, after.index); // The same slot
    try std.testing.expectEqual(before.sector, after.sector);
    try std.testing.expectEqual(before.offset, after.offset);
    try std.testing.expectEqual(before.first_cluster, after.first_cluster);
    try std.testing.expectEqual(raw_before, image.sector(after.sector)[after.offset + 11]);
    try expectFileContent(&volume, "/OUT.LOG", "payload");

    // Check in the raw bytes that only the name changed (the other fields are the same)
    const raw_after = image.sector(after.sector);
    try std.testing.expectEqualStrings("OUT     LOG", raw_after[after.offset..][0..11]);
}

test "rename: from a long name to 8.3 and from 8.3 to a long name" {
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

    // Only one entry in the listing
    var entry: Entry = .{};
    var iterator = try volume.openDir("/");
    var count: usize = 0;
    while (try iterator.next(&entry)) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "rename: an existing destination is AlreadyExists, another directory is InvalidPath" {
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

    // A name pointing at the same entry (a case-only change) is rewritten in place
    try volume.rename("/OUT.PSBT", "/out.psbt");
    try std.testing.expectEqualStrings("out.psbt", (try volume.stat("/out.psbt")).nameSlice());
    try expectFileContent(&volume, "/out.psbt", "b");
}

test "write: name validation (too long, unusable characters, empty)" {
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

test "write: a name of exactly 255 code units can be written" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .total_sectors = 256 });
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();

    var name: [1 + 251 + 4]u8 = @splat('b');
    name[0] = '/';
    @memcpy(name[252..256], ".bin"); // 251 + 4 = 255 code units
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

test "write: a volume with mirroring disabled updates only the active FAT" {
    const allocator = std.testing.allocator;
    var image = try TestImage.init(allocator, .{ .mirroring_disabled = true });
    defer image.deinit(allocator);

    var volume = try Fat32.mount(image.device(), allocator);
    defer volume.deinit();
    try std.testing.expect(!volume.bpb.mirrored);
    try std.testing.expectEqual(@as(u8, 0), volume.bpb.active_fat);

    try volume.writeFile("/OUT.TMP", "mirroring off");
    try expectFileContent(&volume, "/OUT.TMP", "mirroring off");

    // The second copy is untouched (still 0)
    const second = image.firstFatSector() + image.sectors_per_fat;
    const offset = image.fatOffset(3).offset;
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, image.sector(second)[offset..][0..4], .little) & fat_mask);
}

test "write: a name with characters unusable in 8.3 falls back to an alias" {
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

    // The second one becomes ~2
    try volume.writeFile("/out2.psbt", "second");
    const second = try volume.stat("/out2.psbt");
    var second_buffer: [12]u8 = @splat(0);
    try std.testing.expectEqualStrings("OUT2~1.PSB", second.shortDisplay(&second_buffer));

    // A reserved name (CON) becomes an LFN instead of 8.3
    try volume.writeFile("/CON", "reserved");
    const reserved = try volume.stat("/CON");
    try std.testing.expect(reserved.has_lfn);
    try std.testing.expectEqualStrings("CON", reserved.nameSlice());
}

test "write: post-write invariants (the two FATs match and FSInfo is consistent)" {
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

    // The FAT chains are intact too (walking every in-use cluster finds no loop)
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
