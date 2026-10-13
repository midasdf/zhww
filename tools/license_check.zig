//! Licence check for the whole repository: a Zig subset of `reuse lint` (REUSE 3.3).
//!
//! Every file passed in must state a copyright holder and a licence, either in the file itself
//! (SPDX tags, normally a two-line header near the top) or through an annotation in `REUSE.toml`
//! (for Markdown, images, JSON, word lists and CAD exports, which cannot carry a header). Every
//! licence that is named must have its text in `LICENSES/<id>.txt`, and every text there must be
//! used by at least one file.
//!
//! Usage, from the repository root (the file list comes from git, so untracked junk such as
//! `.DS_Store` or `zig-out/` is never checked):
//!
//!     git ls-files -z | zig run tools/license_check.zig
//!     zig test tools/license_check.zig
//!
//! The rules follow REUSE where it has one, so the official tool should agree:
//!   - `LICENSE` at the root and everything in `LICENSES/` are the licence texts themselves, not
//!     covered files.
//!   - A file with an in-file tag must carry **both** tags; it then takes precedence over
//!     `REUSE.toml` (`precedence = "closest"`, the default). `"override"` and `"aggregate"` are
//!     understood too.
//!   - In `REUSE.toml` paths, `*` matches within one directory and `**` matches across
//!     directories. When several annotations match a file, the **last** one wins.
//!   - Only the subset of TOML that `REUSE.toml` needs is parsed: `version`, `[[annotations]]`,
//!     strings, integers and (multi-line) arrays of strings, and `#` comments.
// SPDX-FileCopyrightText: 2026 midasdf and the zhww contributors
// SPDX-License-Identifier: MIT

const std = @import("std");

// Spelled in two pieces so that this file's own header is the only tag it contains.
const tag_license = "SPDX-" ++ "License-Identifier:";
const tag_copyright = "SPDX-" ++ "FileCopyrightText:";

const max_file_len = 64 * 1024 * 1024;

const Precedence = enum { closest, aggregate, override };

const Annotation = struct {
    paths: []const []const u8,
    precedence: Precedence = .closest,
    copyrights: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
    line: usize,
};

const Info = struct {
    copyrights: []const []const u8 = &.{},
    licenses: []const []const u8 = &.{},
};

pub fn main(init: std.process.Init.Minimal) void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &stdout_buffer);

    const ok = run(io, &stdout.interface) catch |err| blk: {
        std.debug.print("license-check: {s}\n", .{@errorName(err)});
        break :blk false;
    };
    stdout.interface.flush() catch {};
    if (!ok) std.process.exit(1);
}

fn run(io: std.Io, out: *std.Io.Writer) !bool {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(io, &stdin_buffer);
    const list = try stdin.interface.allocRemaining(arena, .limited(16 * 1024 * 1024));

    const toml_text = std.Io.Dir.cwd().readFileAlloc(io, "REUSE.toml", arena, .limited(1024 * 1024)) catch |err| {
        std.debug.print("license-check: cannot read REUSE.toml: {s}\n", .{@errorName(err)});
        return err;
    };
    var toml_error: ParseError = .{};
    const annotations = parseReuseToml(arena, toml_text, &toml_error) catch |err| {
        std.debug.print("license-check: REUSE.toml:{d}: {s}\n", .{ toml_error.line, toml_error.message });
        return err;
    };

    var failures: usize = 0;
    var checked: usize = 0;
    var used: std.ArrayList(Count) = .empty;
    var texts: std.ArrayList([]const u8) = .empty;

    var paths = std.mem.tokenizeAny(u8, list, "\x00\n");
    while (paths.next()) |path| {
        if (licenceTextId(path)) |id| {
            if (id.len == 0) {
                std.debug.print("{s}: not named <SPDX id>.txt\n", .{path});
                failures += 1;
            } else try texts.append(arena, id);
            continue;
        }
        if (std.mem.eql(u8, path, "LICENSE")) continue;

        const content = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_file_len)) catch |err| switch (err) {
            // Deleted in the working tree but still in git's index: nothing to check.
            error.FileNotFound => continue,
            else => {
                std.debug.print("{s}: cannot read: {s}\n", .{ path, @errorName(err) });
                failures += 1;
                continue;
            },
        };
        checked += 1;

        const in_file = try scanTags(arena, content);
        const info = resolve(arena, path, in_file, annotations) catch |err| {
            std.debug.print("{s}: {s}\n", .{ path, problem(err) });
            failures += 1;
            continue;
        };
        for (info.licenses) |expression| {
            var ids = licenseIds(expression);
            while (ids.next()) |id| try countLicense(arena, &used, id);
        }
    }

    for (used.items) |entry| {
        if (!contains(texts.items, entry.id)) {
            std.debug.print("LICENSES/{s}.txt: missing (used by {d} file(s))\n", .{ entry.id, entry.files });
            failures += 1;
        }
    }
    for (texts.items) |id| {
        if (findCount(used.items, id) == null) {
            std.debug.print("LICENSES/{s}.txt: not used by any file\n", .{id});
            failures += 1;
        }
    }

    try out.print("license-check: {d} files checked\n", .{checked});
    for (used.items) |entry| try out.print("  {s}: {d}\n", .{ entry.id, entry.files });
    if (failures == 0) {
        try out.print("license-check: PASS\n", .{});
        return true;
    }
    try out.print("license-check: FAIL ({d} problem(s), listed on stderr)\n", .{failures});
    return false;
}

const Count = struct { id: []const u8, files: usize };

fn countLicense(arena: std.mem.Allocator, used: *std.ArrayList(Count), id: []const u8) !void {
    if (findCount(used.items, id)) |index| {
        used.items[index].files += 1;
        return;
    }
    try used.append(arena, .{ .id = id, .files = 1 });
}

fn findCount(items: []const Count, id: []const u8) ?usize {
    for (items, 0..) |entry, index| if (std.mem.eql(u8, entry.id, id)) return index;
    return null;
}

fn contains(items: []const []const u8, value: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

/// `LICENSES/<id>.txt` → `<id>`; "" for a file in `LICENSES/` with another name; null elsewhere.
fn licenceTextId(path: []const u8) ?[]const u8 {
    const prefix = "LICENSES/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const name = path[prefix.len..];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return "";
    if (!std.mem.endsWith(u8, name, ".txt") or name.len == ".txt".len) return "";
    return name[0 .. name.len - ".txt".len];
}

const ResolveError = error{ IncompleteHeader, NoCopyright, NoLicense, OutOfMemory };

fn problem(err: ResolveError) []const u8 {
    return switch (err) {
        error.IncompleteHeader => "an in-file SPDX header needs both the copyright and the licence tag",
        error.NoCopyright => "no copyright (add an SPDX header or a REUSE.toml annotation)",
        error.NoLicense => "no licence (add an SPDX header or a REUSE.toml annotation)",
        error.OutOfMemory => "out of memory",
    };
}

/// The copyright and licence that apply to `path`, from its own tags and the last matching
/// annotation, following the annotation's precedence.
fn resolve(
    arena: std.mem.Allocator,
    path: []const u8,
    in_file: Info,
    annotations: []const Annotation,
) ResolveError!Info {
    const has_copyright = in_file.copyrights.len != 0;
    const has_license = in_file.licenses.len != 0;
    if (has_copyright != has_license) return error.IncompleteHeader;

    var match: ?Annotation = null;
    for (annotations) |annotation| {
        for (annotation.paths) |pattern| {
            if (globMatch(pattern, path)) {
                match = annotation;
                break;
            }
        }
    }

    const info: Info = if (match) |annotation| switch (annotation.precedence) {
        .closest => if (has_license) in_file else .{
            .copyrights = annotation.copyrights,
            .licenses = annotation.licenses,
        },
        .override => .{ .copyrights = annotation.copyrights, .licenses = annotation.licenses },
        .aggregate => .{
            .copyrights = try std.mem.concat(arena, []const u8, &.{ in_file.copyrights, annotation.copyrights }),
            .licenses = try std.mem.concat(arena, []const u8, &.{ in_file.licenses, annotation.licenses }),
        },
    } else in_file;

    if (info.copyrights.len == 0) return error.NoCopyright;
    if (info.licenses.len == 0) return error.NoLicense;
    return info;
}

/// Collects every copyright and licence tag in `content`. A tag runs to the end of its line;
/// a trailing comment closer (`*/`, `-->`) is not part of the value.
fn scanTags(arena: std.mem.Allocator, content: []const u8) !Info {
    var copyrights: std.ArrayList([]const u8) = .empty;
    var licenses: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (tagValue(line, tag_license)) |value| try licenses.append(arena, value);
        if (tagValue(line, tag_copyright)) |value| try copyrights.append(arena, value);
    }
    return .{ .copyrights = copyrights.items, .licenses = licenses.items };
}

fn tagValue(line: []const u8, tag: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, line, tag) orelse return null;
    var value = std.mem.trim(u8, line[at + tag.len ..], " \t\r");
    for ([_][]const u8{ "*/", "-->" }) |closer| {
        if (std.mem.endsWith(u8, value, closer)) {
            value = std.mem.trimEnd(u8, value[0 .. value.len - closer.len], " \t");
        }
    }
    return if (value.len == 0) null else value;
}

/// Iterates over the licence identifiers of an SPDX expression (`MIT`, `MIT OR Apache-2.0`,
/// `(A AND B) WITH Exception`): the operators and the exception after `WITH` are skipped.
const LicenseIds = struct {
    tokens: std.mem.TokenIterator(u8, .any),

    fn next(self: *LicenseIds) ?[]const u8 {
        while (self.tokens.next()) |token| {
            if (std.mem.eql(u8, token, "AND") or std.mem.eql(u8, token, "OR")) continue;
            if (std.mem.eql(u8, token, "WITH")) {
                _ = self.tokens.next();
                continue;
            }
            return token;
        }
        return null;
    }
};

fn licenseIds(expression: []const u8) LicenseIds {
    return .{ .tokens = std.mem.tokenizeAny(u8, expression, " \t()") };
}

/// REUSE.toml path globs: `**` matches anything (`/` included), `*` anything but `/`, and `\`
/// escapes the next character. Everything else matches itself.
fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    switch (pattern[0]) {
        '*' => {
            const across = pattern.len > 1 and pattern[1] == '*';
            const rest = pattern[if (across) 2 else 1..];
            var end: usize = 0;
            while (true) : (end += 1) {
                if (globMatch(rest, path[end..])) return true;
                if (end == path.len) return false;
                if (!across and path[end] == '/') return false;
            }
        },
        '\\' => {
            if (pattern.len < 2 or path.len == 0 or path[0] != pattern[1]) return false;
            return globMatch(pattern[2..], path[1..]);
        },
        else => {
            if (path.len == 0 or path[0] != pattern[0]) return false;
            return globMatch(pattern[1..], path[1..]);
        },
    }
}

// ---------------------------------------------------------------- REUSE.toml (TOML subset)

const ParseError = struct {
    line: usize = 0,
    message: []const u8 = "",
};

const Parser = struct {
    text: []const u8,
    pos: usize = 0,
    line: usize = 1,
    arena: std.mem.Allocator,
    err: *ParseError,

    fn fail(self: *Parser, message: []const u8) error{InvalidToml} {
        self.err.* = .{ .line = self.line, .message = message };
        return error.InvalidToml;
    }

    /// Skips spaces, tabs and comments; newlines too when `newlines` is set.
    fn skip(self: *Parser, newlines: bool) void {
        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '#') {
                while (self.pos < self.text.len and self.text[self.pos] != '\n') self.pos += 1;
            } else if (c == '\n' and newlines) {
                self.pos += 1;
                self.line += 1;
            } else break;
        }
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn startsWith(self: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.text[self.pos..], s);
    }

    fn endOfLine(self: *Parser) !void {
        self.skip(false);
        const c = self.peek() orelse return;
        if (c != '\n') return self.fail("expected the end of the line");
        self.pos += 1;
        self.line += 1;
    }

    fn key(self: *Parser) ![]const u8 {
        if (self.peek() == '"') return self.string();
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') self.pos += 1 else break;
        }
        if (self.pos == start) return self.fail("expected a key");
        return self.text[start..self.pos];
    }

    fn string(self: *Parser) ![]const u8 {
        if (self.peek() != '"') return self.fail("expected a string");
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.peek()) |c| {
            self.pos += 1;
            switch (c) {
                '"' => return out.items,
                '\n' => return self.fail("unterminated string"),
                '\\' => {
                    const e = self.peek() orelse return self.fail("unterminated string");
                    self.pos += 1;
                    try out.append(self.arena, switch (e) {
                        '"' => '"',
                        '\\' => '\\',
                        'n' => '\n',
                        't' => '\t',
                        else => return self.fail("unsupported escape in a string"),
                    });
                },
                else => try out.append(self.arena, c),
            }
        }
        return self.fail("unterminated string");
    }

    /// A string or an array of strings, returned as a list either way.
    fn strings(self: *Parser) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        if (self.peek() != '[') {
            try out.append(self.arena, try self.string());
            return out.items;
        }
        self.pos += 1;
        while (true) {
            self.skip(true);
            if (self.peek() == ']') {
                self.pos += 1;
                return out.items;
            }
            try out.append(self.arena, try self.string());
            self.skip(true);
            if (self.peek() == ',') {
                self.pos += 1;
            } else if (self.peek() != ']') return self.fail("expected ',' or ']' in an array");
        }
    }

    fn integer(self: *Parser) !i64 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (std.ascii.isDigit(c)) self.pos += 1 else break;
        }
        return std.fmt.parseInt(i64, self.text[start..self.pos], 10) catch self.fail("expected an integer");
    }
};

fn parseReuseToml(arena: std.mem.Allocator, text: []const u8, err: *ParseError) ![]const Annotation {
    var p: Parser = .{ .text = text, .arena = arena, .err = err };
    var annotations: std.ArrayList(Annotation) = .empty;
    var current: ?*Annotation = null;
    var version: ?i64 = null;

    while (true) {
        p.skip(true);
        if (p.peek() == null) break;

        if (p.startsWith("[[")) {
            p.pos += 2;
            p.skip(false);
            const name = try p.key();
            p.skip(false);
            if (!p.startsWith("]]")) return p.fail("expected ']]'");
            p.pos += 2;
            if (!std.mem.eql(u8, name, "annotations")) return p.fail("only [[annotations]] tables are supported");
            try annotations.append(arena, .{ .paths = &.{}, .line = p.line });
            current = &annotations.items[annotations.items.len - 1];
            try p.endOfLine();
            continue;
        }
        if (p.peek() == '[') return p.fail("only [[annotations]] tables are supported");

        const name = try p.key();
        p.skip(false);
        if (p.peek() != '=') return p.fail("expected '='");
        p.pos += 1;
        p.skip(false);

        if (current) |a| {
            if (std.mem.eql(u8, name, "path")) {
                a.paths = try p.strings();
            } else if (std.mem.eql(u8, name, "precedence")) {
                const value = try p.string();
                a.precedence = std.meta.stringToEnum(Precedence, value) orelse
                    return p.fail("precedence must be closest, aggregate or override");
            } else if (std.mem.eql(u8, name, "SPDX-FileCopyrightText")) {
                a.copyrights = try p.strings();
            } else if (std.mem.eql(u8, name, "SPDX-License-Identifier")) {
                a.licenses = try p.strings();
            } else return p.fail("unknown key in [[annotations]]");
        } else if (std.mem.eql(u8, name, "version")) {
            version = try p.integer();
        } else return p.fail("unknown top-level key");
        try p.endOfLine();
    }

    if (version != 1) return p.fail("REUSE.toml must say version = 1");
    for (annotations.items) |a| {
        if (a.paths.len == 0) {
            err.* = .{ .line = a.line, .message = "an annotation without a path" };
            return error.InvalidToml;
        }
    }
    return annotations.items;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "globs: * stays in one directory, ** crosses them, \\ escapes" {
    try testing.expect(globMatch("*.md", "README.md"));
    try testing.expect(!globMatch("*.md", "docs/README.md"));
    try testing.expect(globMatch("**/*.md", "docs/README.md"));
    try testing.expect(globMatch("**/*.md", "hardware/enclosure/README.md"));
    try testing.expect(!globMatch("**/*.md", "README.md"));
    try testing.expect(globMatch("hardware/**", "hardware/enclosure/case.step"));
    try testing.expect(!globMatch("hardware/**", "hardwareX/a"));
    try testing.expect(globMatch("firmware/tests/vectors/core_*.json", "firmware/tests/vectors/core_psbt.json"));
    try testing.expect(!globMatch("firmware/tests/vectors/core_*.json", "firmware/tests/vectors/bip32.json"));
    try testing.expect(globMatch("a\\*b", "a*b"));
    try testing.expect(!globMatch("a\\*b", "axb"));
}

test "tags: values run to the end of the line, comment closers are dropped" {
    const content = "/* " ++ tag_copyright ++ " 2026 A */\n" ++
        "<!-- " ++ tag_license ++ " MIT -->\n" ++
        "// " ++ tag_license ++ "\n"; // an empty tag is not a licence
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const info = try scanTags(arena_state.allocator(), content);
    try testing.expectEqual(@as(usize, 1), info.copyrights.len);
    try testing.expectEqualStrings("2026 A", info.copyrights[0]);
    try testing.expectEqual(@as(usize, 1), info.licenses.len);
    try testing.expectEqualStrings("MIT", info.licenses[0]);
}

test "licence ids: operators and exceptions are skipped" {
    var ids = licenseIds("(MIT OR Apache-2.0) AND GPL-2.0-only WITH Classpath-exception-2.0");
    try testing.expectEqualStrings("MIT", ids.next().?);
    try testing.expectEqualStrings("Apache-2.0", ids.next().?);
    try testing.expectEqualStrings("GPL-2.0-only", ids.next().?);
    try testing.expect(ids.next() == null);
}

test "REUSE.toml: annotations, multi-line arrays, comments; the last match wins" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\# comment
        \\version = 1
        \\
        \\[[annotations]]
        \\path = "hardware/**"
        \\SPDX-FileCopyrightText = "2026 A"
        \\SPDX-License-Identifier = "CERN-OHL-S-2.0"
        \\
        \\[[annotations]]  # trailing comment
        \\path = [
        \\  "*.md",
        \\  "**/*.md", # a comment inside the array
        \\]
        \\SPDX-FileCopyrightText = ["2026 A", "2025 B"]
        \\SPDX-License-Identifier = "CC-BY-4.0"
        \\precedence = "override"
    ;
    var err: ParseError = .{};
    const annotations = try parseReuseToml(arena, text, &err);
    try testing.expectEqual(@as(usize, 2), annotations.len);
    try testing.expectEqual(@as(usize, 2), annotations[1].paths.len);
    try testing.expectEqual(Precedence.override, annotations[1].precedence);

    const none: Info = .{};
    const design = try resolve(arena, "hardware/enclosure/case.json", none, annotations);
    try testing.expectEqualStrings("CERN-OHL-S-2.0", design.licenses[0]);
    const readme = try resolve(arena, "hardware/README.md", none, annotations);
    try testing.expectEqualStrings("CC-BY-4.0", readme.licenses[0]);
    try testing.expectEqual(@as(usize, 2), readme.copyrights.len);
    try testing.expectError(error.NoCopyright, resolve(arena, "firmware/build.zig", none, annotations));
}

test "resolve: a complete header wins under closest; half a header is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const annotations = [_]Annotation{.{
        .paths = &.{"**"},
        .copyrights = &.{"2026 A"},
        .licenses = &.{"CC-BY-4.0"},
        .line = 1,
    }};
    const header: Info = .{ .copyrights = &.{"2026 B"}, .licenses = &.{"MIT"} };
    const got = try resolve(arena, "x/y.zig", header, &annotations);
    try testing.expectEqualStrings("MIT", got.licenses[0]);
    const half: Info = .{ .licenses = &.{"MIT"} };
    try testing.expectError(error.IncompleteHeader, resolve(arena, "x/y.zig", half, &annotations));
}

test "REUSE.toml: errors carry the line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var err: ParseError = .{};
    try testing.expectError(error.InvalidToml, parseReuseToml(arena_state.allocator(), "version = 1\n[table]\n", &err));
    try testing.expectEqual(@as(usize, 2), err.line);
    try testing.expectError(error.InvalidToml, parseReuseToml(arena_state.allocator(), "[[annotations]]\npath = \"a\"\n", &err));
}

test "LICENSES/ entries map to their SPDX id" {
    try testing.expectEqualStrings("MIT", licenceTextId("LICENSES/MIT.txt").?);
    try testing.expectEqualStrings("", licenceTextId("LICENSES/MIT").?);
    try testing.expectEqualStrings("", licenceTextId("LICENSES/sub/MIT.txt").?);
    try testing.expect(licenceTextId("LICENSE") == null);
}
