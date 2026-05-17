const std = @import("std");
const ts_module = @import("treesitter.zig");

/// Grammar and language metadata from languages.zon (baked in at build time).
const lang = @import("languages");

/// Active language list — defaults to compile-time config, overridable at startup.
var g_languages: []const lang.LanguageDef = lang.config.languages;

/// Override the language list used for grammar name detection.
/// LIFETIME: `languages` must remain valid for the entire program lifetime
/// (or until setLanguages is called again). The slice is NOT copied.
pub fn setLanguages(languages: []const lang.LanguageDef) void {
    g_languages = languages;
}

pub const GrammarHandle = ts_module.GrammarHandle;
pub const GrammarPaths = ts_module.GrammarPaths;
pub const loadGrammar = ts_module.loadGrammar;

/// Return the grammar name for the given file path and (optionally) the first
/// line of the file content.  Detection order:
///   1. Vim modeline in first_line:  "# vim: ft=python"
///   2. Shebang in first_line:       "#!/usr/bin/env python3"
///   3. File extension:              ".py" → "python"
///   4. Glob/basename pattern:       ".bashrc" → "bash"
/// Returns the grammar name (not the language name) or null when nothing matches.
pub fn grammarNameForFile(file_path: []const u8, first_line: ?[]const u8) ?[]const u8 {
    if (first_line) |line| {
        if (detectModeline(line)) |name| return name;
        if (detectShebang(line)) |name| return name;
    }

    const ext = std.fs.path.extension(file_path);
    if (ext.len > 0) {
        for (g_languages) |l| {
            for (l.file_types) |ft| {
                if (std.mem.eql(u8, ft, ext)) return l.grammar;
            }
        }
    }

    // Fall back to glob/basename pattern detection.
    if (detectByGlob(file_path)) |name| return name;

    return null;
}

/// Match the file's basename against each language's `glob_patterns`.
/// Supported forms:
///   "Dockerfile"   — exact basename match
///   "*.conf"       — basename ends with ".conf"
///   "CMake*"       — basename starts with "CMake"
fn detectByGlob(file_path: []const u8) ?[]const u8 {
    const basename = std.fs.path.basename(file_path);
    if (basename.len == 0) return null;

    for (g_languages) |l| {
        for (l.glob_patterns) |pat| {
            if (matchGlobPattern(pat, basename)) return l.grammar;
        }
    }
    return null;
}

fn matchGlobPattern(pattern: []const u8, basename: []const u8) bool {
    if (pattern.len == 0) return false;
    if (pattern[0] == '*') {
        // "*.ext" — suffix match
        return std.mem.endsWith(u8, basename, pattern[1..]);
    }
    if (pattern[pattern.len - 1] == '*') {
        // "prefix*" — prefix match
        return std.mem.startsWith(u8, basename, pattern[0 .. pattern.len - 1]);
    }
    // exact match
    return std.mem.eql(u8, basename, pattern);
}


fn detectModeline(line: []const u8) ?[]const u8 {
    // Accept:  vim: ft=X   vi: set ft=X   vim: set filetype=X:
    const patterns = [_][]const u8{ " ft=", "\tft=", " filetype=", "\tfiletype=" };
    for (patterns) |pat| {
        if (std.mem.indexOf(u8, line, pat)) |idx| {
            const after = line[idx + pat.len ..];
            const end = for (after, 0..) |c, i| {
                if (c == ' ' or c == ':' or c == '\t' or c == '\n' or c == '\r') break i;
            } else after.len;
            const name = after[0..end];
            for (g_languages) |l| {
                if (std.mem.eql(u8, l.modeline, name)) return l.grammar;
            }
        }
    }
    return null;
}

/// Return the grammar name matching the interpreter on a shebang line, or null.
fn detectShebang(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "#!")) return null;
    const rest = std.mem.trimStart(u8, line[2..], " \t");

    // "#!/usr/bin/env python3" → basename after "env "
    // "#!/usr/bin/python3"     → basename of path
    const interp: []const u8 = blk: {
        const env_prefix = "env ";
        if (std.mem.indexOf(u8, rest, env_prefix)) |i| {
            const after_env = std.mem.trimStart(u8, rest[i + env_prefix.len ..], " \t");
            const end = for (after_env, 0..) |c, j| {
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break j;
            } else after_env.len;
            break :blk after_env[0..end];
        }
        const trimmed = std.mem.trimEnd(u8, rest, " \t\n\r");
        if (std.mem.lastIndexOfScalar(u8, trimmed, '/')) |i| break :blk trimmed[i + 1 ..];
        break :blk trimmed;
    };

    for (g_languages) |l| {
        for (l.shebangs) |shebang| {
            if (std.mem.eql(u8, shebang, interp)) return l.grammar;
        }
    }
    return null;
}

