/// src/vx/language.zig — language detection registry
///
/// Detects the language of a file from its metadata, using data from the
/// `languages` module (src/languages/config.zig) which is injected at build time.
///
/// Detection priority (highest to lowest):
///   1. Vim modeline  — `# vim: ft=X` or `/* vim: set ft=X */`
///   2. Shebang line  — `#!/usr/bin/env python3`
///   3. File extension — `.py`, `.zig`, `.c`, etc.

const std = @import("std");
const lang = @import("languages");

/// Active language list — defaults to compile-time config, can be overridden at
/// startup via setLanguages() when the user has a VOLUTE_CONFIG_PATH override.
var g_languages: []const lang.LanguageDef = lang.config.languages;

/// Override the language list used for detection.  Call once at startup when
/// VOLUTE_CONFIG_PATH provides a custom languages.zon.
/// LIFETIME: `languages` must remain valid for the entire program lifetime
/// (or until setLanguages is called again). The slice is NOT copied.
pub fn setLanguages(languages: []const lang.LanguageDef) void {
    g_languages = languages;
}

/// Information about a detected language.
pub const LangInfo = struct {
    /// Grammar name as defined in languages.zon (e.g. "python", "zig").
    name: []const u8,
    /// Index into `lang.config.languages` for direct access.
    index: usize,
};

/// Detect the language of a file.
///
/// - `path`       — file path (may be null); extension is extracted from the last component
/// - `first_line` — first line of the file content (may be null); used for modeline/shebang
///
/// Returns `null` if no grammar matches (plain text).
pub fn detectLanguage(path: ?[]const u8, first_line: ?[]const u8) ?LangInfo {
    // 1. Vim modeline in first line
    if (first_line) |line| {
        if (detectModeline(line)) |ft| {
            if (findByModeline(ft)) |info| return info;
        }
        // 2. Shebang
        if (std.mem.startsWith(u8, line, "#!")) {
            if (findByShebang(line)) |info| return info;
        }
    }
    // 3. File extension
    if (path) |p| {
        const ext = std.fs.path.extension(p);
        if (ext.len > 0) {
            if (findByExtension(ext)) |info| return info;
        }
    }
    return null;
}

// ── Internal helpers ───────────────────────────────────────────────────────────

/// Parse a vim modeline from a line and return the `ft` value if found.
/// Handles two common forms:
///   `# vim: ft=python` / `# vim: set ft=python :`
///   `/* vim: set ft=c : */`
fn detectModeline(line: []const u8) ?[]const u8 {
    // Search for "vim:" or "vim: set"
    const vim_marker = "vim:";
    var pos = std.mem.indexOf(u8, line, vim_marker) orelse return null;
    pos += vim_marker.len;

    // Skip optional whitespace and "set "
    const rest = std.mem.trimStart(u8, line[pos..], " \t");
    const after_set = if (std.mem.startsWith(u8, rest, "set "))
        rest["set ".len..]
    else
        rest;

    // Find "ft=" or "filetype="
    const ft_key_short = "ft=";
    const ft_key_long = "filetype=";

    const val_start: usize = if (std.mem.indexOf(u8, after_set, ft_key_long)) |i|
        i + ft_key_long.len
    else if (std.mem.indexOf(u8, after_set, ft_key_short)) |i|
        i + ft_key_short.len
    else
        return null;

    const val = after_set[val_start..];
    // Value ends at space, colon, or end-of-string
    const val_end = for (val, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == ':') break i;
    } else val.len;

    return if (val_end > 0) val[0..val_end] else null;
}

/// Extract the interpreter from a shebang line.
/// `#!/usr/bin/env python3` → `"python3"`
/// `#!/usr/bin/python`      → `"python"`
fn shebangeInterpreter(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "#!")) return null;
    const rest = std.mem.trimStart(u8, line[2..], " \t");
    // If starts with "/usr/bin/env", the next token is the interpreter
    const path_start = if (std.mem.startsWith(u8, rest, "/usr/bin/env")) blk: {
        const after_env = std.mem.trimStart(u8, rest["/usr/bin/env".len..], " \t");
        break :blk after_env;
    } else rest;
    // Take last path component
    const last = std.fs.path.basename(path_start);
    // Strip trailing version numbers for matching: "python3" → try "python3" first
    const end = for (last, 0..) |c, i| {
        if (c == ' ' or c == '\t' or c == '\n') break i;
    } else last.len;
    return if (end > 0) last[0..end] else null;
}

fn findByModeline(ft: []const u8) ?LangInfo {
    for (g_languages, 0..) |l, i| {
        if (std.mem.eql(u8, l.modeline, ft)) {
            return .{ .name = l.name, .index = i };
        }
    }
    return null;
}

fn findByShebang(line: []const u8) ?LangInfo {
    const interp = shebangeInterpreter(line) orelse return null;
    for (g_languages, 0..) |l, i| {
        for (l.shebangs) |s| {
            if (std.mem.eql(u8, s, interp)) {
                return .{ .name = l.name, .index = i };
            }
        }
    }
    return null;
}

fn findByExtension(ext: []const u8) ?LangInfo {
    for (g_languages, 0..) |l, i| {
        for (l.file_types) |ft| {
            if (std.mem.eql(u8, ft, ext)) {
                return .{ .name = l.name, .index = i };
            }
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────────────

test "detectModeline: ft=python" {
    const ft = detectModeline("# vim: ft=python");
    try std.testing.expectEqualStrings("python", ft orelse return error.Missing);
}

test "detectModeline: set ft=zig :" {
    const ft = detectModeline("// vim: set ft=zig :");
    try std.testing.expectEqualStrings("zig", ft orelse return error.Missing);
}

test "detectModeline: none" {
    const ft = detectModeline("just a normal comment");
    try std.testing.expectEqual(null, ft);
}

test "shebangeInterpreter: env python3" {
    const i = shebangeInterpreter("#!/usr/bin/env python3");
    try std.testing.expectEqualStrings("python3", i orelse return error.Missing);
}

test "shebangeInterpreter: direct path" {
    const i = shebangeInterpreter("#!/usr/bin/python");
    try std.testing.expectEqualStrings("python", i orelse return error.Missing);
}

test "detectLanguage: extension .zig" {
    const info = detectLanguage("src/main.zig", null) orelse return error.Missing;
    try std.testing.expectEqualStrings("zig", info.name);
}

test "detectLanguage: extension .py" {
    const info = detectLanguage("script.py", null) orelse return error.Missing;
    try std.testing.expectEqualStrings("python", info.name);
}

test "detectLanguage: extension .c" {
    const info = detectLanguage("main.c", null) orelse return error.Missing;
    try std.testing.expectEqualStrings("c", info.name);
}

test "detectLanguage: shebang python3" {
    const info = detectLanguage(null, "#!/usr/bin/env python3") orelse return error.Missing;
    try std.testing.expectEqualStrings("python", info.name);
}

test "detectLanguage: modeline overrides extension" {
    // .c extension but modeline says python
    const info = detectLanguage("foo.c", "# vim: ft=python") orelse return error.Missing;
    try std.testing.expectEqualStrings("python", info.name);
}

test "detectLanguage: unknown returns null" {
    const info = detectLanguage("README.md", null);
    try std.testing.expectEqual(null, info);
}
