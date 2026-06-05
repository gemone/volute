/// src/languages/config.zig — canonical language/grammar struct definitions.
///
/// Defines LanguageDef, GrammarDef, Config, and the compile-time `config` constant.
///
/// `languages.zon` is injected by build.zig as the anonymous import "languages.zon",
/// so `@import("default_config_languages")` resolves cleanly inside this module regardless of
/// where the module is used.
///
/// Consumers (vx, tools):
///   @import("languages").config.languages  — []const LanguageDef at compile time
///   @import("languages").config.grammars   — []const GrammarDef  at compile time
///
/// Runtime user override (vx only):
///   loadUserConfigOverride(io, allocator) — checks VOLUTE_CONFIG_PATH/languages.zon

/// Per-language file-detection metadata entry.
pub const LanguageDef = struct {
    /// Language name (e.g. "python", "zig").
    name: []const u8,
    /// Grammar to use for syntax highlighting (usually equals name).
    grammar: []const u8,
    /// File extensions with leading dot (e.g. ".py").
    file_types: []const []const u8,
    /// Vim modeline ft= value (e.g. "python").
    modeline: []const u8,
    /// Interpreter names on a shebang line (e.g. "python3").
    shebangs: []const []const u8,
    /// Basename/glob patterns for extension-less or special filenames.
    glob_patterns: []const []const u8,
};

/// Per-grammar tree-sitter source entry.
pub const GrammarDef = struct {
    /// Grammar name (e.g. "python").
    name: []const u8,
    /// Package URL: "git+https://host/repo#commit"
    url: []const u8,
    /// Zig package hash as computed by `zig fetch` (empty string if not yet registered).
    hash: []const u8,
};

/// Container for all language and grammar configuration.
pub const Config = struct {
    languages: []const LanguageDef,
    grammars: []const GrammarDef,
};

/// Compile-time configuration loaded from languages.zon (injected by build.zig).
pub const config: Config = @import("default_config_languages");

/// Grammar management operations (clone, build, remove, filename helpers).
pub const grammar_ops = @import("grammar_ops.zig");

/// Runtime directory resolution (findGrammarsDir).
pub const runtime = @import("grammar_ops.zig");

// ── Runtime loading (vx user config override) ─────────────────────────────────

const std = @import("std");

/// Parse a languages.zon file at `path` into a heap-allocated Config.
/// Caller must free with `freeConfig`.
pub fn loadFromPathAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Config {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(raw);
    const source = try allocator.dupeZ(u8, raw);
    defer allocator.free(source);
    return std.zon.parse.fromSliceAlloc(Config, allocator, source, null, .{});
}

/// Free a Config returned by `loadFromPathAlloc`.
pub fn freeConfig(allocator: std.mem.Allocator, cfg: Config) void {
    std.zon.parse.free(allocator, cfg);
}

/// Check `VOLUTE_CONFIG_PATH` environment variable.  If set and
/// `$VOLUTE_CONFIG_PATH/languages.zon` exists, load and return it.
/// Returns `null` when the env var is absent or the file is not found.
/// On success the caller owns the returned Config and must `freeConfig` it.
pub fn loadUserConfigOverride(io: std.Io, allocator: std.mem.Allocator) !?Config {
    const dir_c = std.c.getenv("VOLUTE_CONFIG_PATH") orelse return null;
    const dir = std.mem.span(dir_c);
    const path = try std.fs.path.join(allocator, &.{ dir, "languages.zon" });
    defer allocator.free(path);
    return loadFromPathAlloc(io, allocator, path) catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => null,
        else => err,
    };
}

/// Serialize `cfg` as ZON and write it to `path`.
/// Before overwriting, backs up the existing file to `backup_subpath` (relative to cwd)
/// if provided; defaults to `zig-cache/languages.zon.bak`.
pub fn saveConfigToFileIo(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    cfg: Config,
    backup_subpath: ?[]const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const bak = backup_subpath orelse "zig-cache/languages.zon.bak";

    if (cwd.readFileAlloc(io, path, allocator, .limited(1024 * 1024))) |existing| {
        defer allocator.free(existing);
        cwd.writeFile(io, .{ .sub_path = bak, .data = existing }) catch {};
    } else |_| {}

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try std.zon.stringify.serialize(cfg, .{}, &aw.writer);

    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = aw.writer.buffer[0..aw.writer.end],
    });
}
