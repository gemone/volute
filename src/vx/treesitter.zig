const std = @import("std");
const builtin = @import("builtin");
const ts = @import("tree-sitter");
const gops = @import("languages").grammar_ops;
const buffer_mod = @import("buffer.zig");

const UnsupportedDynLib = struct {
    pub fn open(_: []const u8) error{UnsupportedPlatform}!UnsupportedDynLib {
        return error.UnsupportedPlatform;
    }

    pub fn close(_: *UnsupportedDynLib) void {}

    pub fn lookup(_: *UnsupportedDynLib, comptime T: type, _: [:0]const u8) ?T {
        return null;
    }
};

const DynLib = if (builtin.target.os.tag == .windows and builtin.target.abi == .gnu)
    UnsupportedDynLib
else
    std.DynLib;

/// All tree-sitter query files for a single language.
/// Each field is null when the corresponding .scm file is absent.
pub const Queries = struct {
    /// Syntax highlight rules.
    highlights: ?*ts.Query = null,
    /// Embedded-language injection rules (e.g. JS inside HTML).
    injections: ?*ts.Query = null,
    /// Local-scope / definition / reference rules.
    locals: ?*ts.Query = null,
    /// Auto-indentation rules.
    indents: ?*ts.Query = null,
    /// Text-object (structural motion) rules.
    textobjects: ?*ts.Query = null,
    /// Symbol-tag rules for navigation.
    tags: ?*ts.Query = null,

    pub fn deinit(self: *Queries) void {
        inline for (std.meta.fields(Queries)) |f| {
            if (@field(self, f.name)) |q| q.destroy();
        }
    }
};

/// Per-capture metadata pre-computed at grammar load time.
const CaptureMeta = struct {
    style: TokenStyle,
    prio: u8, // priority << 4 (packed high nibble form)
};

/// A loaded tree-sitter language with all available SCM queries.
/// Owns the dynamic library handle — must call `deinit` to release.
pub const GrammarHandle = struct {
    lib: DynLib,
    language: *const ts.Language,
    queries: Queries,
    /// Reusable parser — created once per grammar load, reused across highlight() calls.
    parser: *ts.Parser,
    /// Pre-computed style+priority for each capture index in the highlights query.
    /// Indexed by capture id.  Empty if no highlights query loaded.
    capture_meta: []CaptureMeta,
    /// Source-level highlight cache: last seen source hash + styles.
    /// On cache hit, highlight() skips parsing entirely.
    cache_hash: u64,
    cache_styles: []TokenStyle,
    /// Previously parsed tree for incremental re-parsing on source changes.
    prev_tree: ?*ts.Tree,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *GrammarHandle) void {
        if (self.prev_tree) |t| t.destroy();
        self.allocator.free(self.cache_styles);
        self.allocator.free(self.capture_meta);
        self.parser.destroy();
        self.queries.deinit();
        self.language.destroy();
        self.lib.close();
    }
};

/// Configuration for grammar loading paths.
pub const GrammarPaths = struct {
    lib_dir: []const u8,
    query_dir: []const u8,
};

/// Try to load one .scm file as a compiled Query.  Returns null on any error
/// (file missing, parse failure) so callers never need to handle partial state.
fn loadQuery(
    io: std.Io,
    allocator: std.mem.Allocator,
    query_dir: []const u8,
    lang_name: []const u8,
    filename: []const u8,
    language: *const ts.Language,
) ?*ts.Query {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ query_dir, lang_name, filename }) catch return null;
    defer allocator.free(path);

    const scm = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(scm);

    var err_offset: u32 = 0;
    return ts.Query.create(language, scm, &err_offset) catch null;
}

/// Load a grammar from a compiled shared library plus all available SCM queries.
/// The library must export `tree_sitter_<name>()` returning `*const ts.Language`.
pub fn loadGrammar(io: std.Io, allocator: std.mem.Allocator, paths: GrammarPaths, name: []const u8) !GrammarHandle {
    const lib_filename = try gops.grammarLibFilename(allocator, name);
    defer allocator.free(lib_filename);
    const lib_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.lib_dir, lib_filename });
    defer allocator.free(lib_path);

    var lib = try DynLib.open(lib_path);
    errdefer lib.close();

    const sym_name = try std.fmt.allocPrint(allocator, "tree_sitter_{s}", .{name});
    defer allocator.free(sym_name);
    const sym_name_z = try allocator.dupeZ(u8, sym_name);
    defer allocator.free(sym_name_z);

    const LangFn = *const fn () callconv(.c) *const ts.Language;
    const lang_fn = lib.lookup(LangFn, sym_name_z) orelse return error.SymbolNotFound;
    const language = lang_fn();

    const queries = Queries{
        .highlights = loadQuery(io, allocator, paths.query_dir, name, "highlights.scm", language),
        .injections = loadQuery(io, allocator, paths.query_dir, name, "injections.scm", language),
        .locals = loadQuery(io, allocator, paths.query_dir, name, "locals.scm", language),
        .indents = loadQuery(io, allocator, paths.query_dir, name, "indents.scm", language),
        .textobjects = loadQuery(io, allocator, paths.query_dir, name, "textobjects.scm", language),
        .tags = loadQuery(io, allocator, paths.query_dir, name, "tags.scm", language),
    };

    const parser = ts.Parser.create();
    errdefer parser.destroy();
    try parser.setLanguage(language);

    // Pre-compute style+priority for every capture in the highlights query.
    const capture_meta = blk: {
        const hl = queries.highlights orelse break :blk try allocator.alloc(CaptureMeta, 0);
        const count = hl.captureCount();
        const meta = try allocator.alloc(CaptureMeta, count);
        for (0..count) |i| {
            const cap_name = hl.captureNameForId(@intCast(i)) orelse {
                meta[i] = .{ .style = .normal, .prio = 0 };
                continue;
            };
            const style = captureToStyle(cap_name);
            meta[i] = .{ .style = style, .prio = stylePriority(style) << 4 };
        }
        break :blk meta;
    };
    errdefer allocator.free(capture_meta);

    return .{ .lib = lib, .language = language, .queries = queries, .parser = parser, .capture_meta = capture_meta, .cache_hash = 0, .cache_styles = &.{}, .prev_tree = null, .allocator = allocator };
}

/// Highlight tokens produced by tree-sitter for one line of source.
pub const TokenStyle = @import("syntax.zig").TokenStyle;

/// Map a tree-sitter capture name to a `TokenStyle` using hierarchical
/// prefix matching (same cascade logic as helix themes).
/// Tries longest prefix first, then progressively trims the last ".segment"
/// until a match is found.
fn captureToStyle(capture_name: []const u8) TokenStyle {
    // Each entry: prefix → style.  Order matters for ambiguous top-level names.
    // We walk from most-specific to least-specific via prefix shortening below.
    const rules = std.StaticStringMap(TokenStyle).initComptime(.{
        // comments
        .{ "comment", .comment },
        // keywords (all sub-families inherit)
        .{ "keyword", .keyword },
        // types
        .{ "type", .type_name },
        .{ "constructor", .type_name },
        .{ "namespace", .type_name },
        .{ "module", .type_name },
        .{ "label", .type_name },
        .{ "tag", .type_name },
        // strings
        .{ "string", .string },
        // numbers — constant.numeric.* → number; constant.builtin.* → keyword (true/false/null)
        .{ "number", .number },
        .{ "constant.numeric", .number },
        .{ "constant.character", .string },
        .{ "constant.builtin", .keyword },
        .{ "constant", .number },
        // functions / builtins
        .{ "function.builtin", .builtin },
        .{ "function.macro", .builtin },
        .{ "function", .type_name },
        // variables
        .{ "variable.builtin", .builtin },
        .{ "variable.parameter", .normal },
        .{ "variable", .normal },
        // operators (treat as keyword-weight)
        .{ "operator", .keyword },
        // attributes / annotations
        .{ "attribute", .builtin },
        .{ "property", .normal },
        // markup headings/bold → keyword; italic/raw/strings handled above
        .{ "markup.heading", .keyword },
        .{ "markup.bold", .keyword },
        .{ "markup.italic", .comment },
        .{ "markup.raw", .string },
        .{ "markup.link", .builtin },
        .{ "markup", .normal },
        // embedded code blocks
        .{ "embedded", .normal },
    });

    // Try the full name, then progressively trim the last ".segment".
    var name = capture_name;
    while (true) {
        if (rules.get(name)) |style| return style;
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break;
        name = name[0..dot];
    }
    return .normal;
}

/// Priority of a TokenStyle for highlight conflict resolution.
/// Higher = more prominent; existing style is kept if >= new style's priority.
fn stylePriority(style: TokenStyle) u8 {
    return switch (style) {
        .normal => 0,
        .builtin => 3,
        .comment => 2,
        .number => 2,
        .string => 2,
        .type_name => 3,
        .keyword => 4,
    };
}

/// Get the source text of a specific capture by its capture index within a match.
fn getCaptureText(match: ts.Query.Match, capture_idx: u32, source: []const u8) ?[]const u8 {
    for (match.captures) |cap| {
        if (cap.index == capture_idx) {
            const s: usize = @intCast(cap.node.startByte());
            const e: usize = @intCast(cap.node.endByte());
            if (s <= e and e <= source.len) return source[s..e];
            return null;
        }
    }
    return null;
}

const pcre2 = @import("pcre2");

/// Test if `text` matches the PCRE2 regex `pattern`.
/// Returns false when the pattern fails to compile (invalid patterns fail predicates).
fn regexMatch(pattern: []const u8, text: []const u8) bool {
    const re = pcre2.Regex.compile(pattern) catch return false;
    defer re.deinit();
    return re.match(text);
}

/// Skip to the next predicate in the array when current one is malformed.
fn skipToNextPredicate(preds: []const ts.Query.PredicateStep, i: *usize) void {
    while (i.* < preds.len and preds[i.*].type != .done) i.* += 1;
    if (i.* < preds.len) i.* += 1;
}

/// Check whether all predicates for the match's pattern pass.
/// Returns true when there are no predicates, or when all pass.
/// Unknown predicates are treated as passing (permissive).
fn satisfiesPredicates(query: *const ts.Query, match: ts.Query.Match, source: []const u8) bool {
    const preds = query.predicatesForPattern(match.pattern_index);
    if (preds.len == 0) return true;

    var i: usize = 0;
    while (i < preds.len) {
        if (preds[i].type != .string) {
            skipToNextPredicate(preds, &i);
            continue;
        }
        const pred_name = query.stringValueForId(preds[i].value_id) orelse {
            skipToNextPredicate(preds, &i);
            continue;
        };
        i += 1;

        const args_start = i;
        while (i < preds.len and preds[i].type != .done) i += 1;
        const args = preds[args_start..i];
        if (i < preds.len) i += 1;

        const negate = std.mem.startsWith(u8, pred_name, "not-");
        const base = if (negate) pred_name[4..] else pred_name;

        if (std.mem.eql(u8, base, "any-of?") or std.mem.eql(u8, base, "is?")) {
            if (args.len < 2 or args[0].type != .capture) continue;
            const text = getCaptureText(match, args[0].value_id, source) orelse continue;
            var found = false;
            for (args[1..]) |arg| {
                if (arg.type != .string) continue;
                const val = query.stringValueForId(arg.value_id) orelse continue;
                if (std.mem.eql(u8, text, val)) {
                    found = true;
                    break;
                }
            }
            if (found == negate) return false;
        } else if (std.mem.eql(u8, base, "match?")) {
            if (args.len < 2 or args[0].type != .capture or args[1].type != .string) continue;
            const text = getCaptureText(match, args[0].value_id, source) orelse continue;
            const pat = query.stringValueForId(args[1].value_id) orelse continue;
            const matched = regexMatch(pat, text);
            if (matched == negate) return false;
        } else if (std.mem.eql(u8, base, "eq?")) {
            if (args.len < 2) continue;
            const t0 = if (args[0].type == .capture)
                getCaptureText(match, args[0].value_id, source) orelse continue
            else
                query.stringValueForId(args[0].value_id) orelse continue;
            const t1 = if (args[1].type == .capture)
                getCaptureText(match, args[1].value_id, source) orelse continue
            else
                query.stringValueForId(args[1].value_id) orelse continue;
            const equal = std.mem.eql(u8, t0, t1);
            if (equal == negate) return false;
        }
        // Unknown predicates: treat as passing.
    }
    return true;
}

/// Highlight a complete source buffer using tree-sitter.
/// Returns a slice of `TokenStyle` parallel to `source` bytes.
/// Caller owns the returned slice.
/// Result of a versioned highlight computation.
/// `changed_ranges` is null on the first parse (no old tree to diff against),
/// meaning the caller should assume all lines are dirty.
pub const HighlightResult = struct {
    styles: []TokenStyle,
    /// Null → first parse; caller should use invalidateAll().
    /// Non-null → sorted list of parse-tree ranges that changed; caller marks only those rows dirty.
    changed_ranges: ?[]ts.Range,
};

pub fn highlight(allocator: std.mem.Allocator, grammar: *GrammarHandle, source: []const u8) ![]TokenStyle {
    // Cache hit: same source content → return a copy of cached styles.
    const h = std.hash.Wyhash.hash(0, source);
    const result = try highlightWithKey(allocator, grammar, source, h, true, null, 0, @intCast(source.len));
    if (result.changed_ranges) |r| allocator.free(r);
    return result.styles;
}

/// Like highlight() but uses a pre-computed cache key (e.g. content_version) to skip hashing.
/// Returns a HighlightResult with an optional changed_ranges slice so the caller can perform
/// targeted render-cache invalidation instead of a full-screen redraw.
/// `tree_edit` is an optional edit annotation: when provided, it is applied to the old
/// parse tree via `Tree.edit()` before incremental re-parsing, enabling O(edit_region)
/// re-scans instead of O(file_size). Pass `null` to fall back to a full re-scan.
/// `query_start_byte` and `query_end_byte` restrict the query scan to the visible viewport.
/// The caller owns both `styles` and `changed_ranges` (free each independently).
pub fn highlightVersioned(
    allocator: std.mem.Allocator,
    grammar: *GrammarHandle,
    source: []const u8,
    version: u64,
    tree_edit: ?buffer_mod.TreeEditHint,
    query_start_byte: u32,
    query_end_byte: u32,
) !HighlightResult {
    return highlightWithKey(allocator, grammar, source, version, false, tree_edit, query_start_byte, query_end_byte);
}

fn highlightWithKey(allocator: std.mem.Allocator, grammar: *GrammarHandle, source: []const u8, cache_key: u64, update_internal_cache: bool, tree_edit: ?buffer_mod.TreeEditHint, query_start_byte: u32, query_end_byte: u32) !HighlightResult {
    if (update_internal_cache and cache_key == grammar.cache_hash and grammar.cache_styles.len == source.len) {
        const copy = try allocator.alloc(TokenStyle, source.len);
        @memcpy(copy, grammar.cache_styles);
        return .{ .styles = copy, .changed_ranges = null };
    }

    const styles = try allocator.alloc(TokenStyle, source.len);
    @memset(styles, .normal);

    const query = grammar.queries.highlights orelse {
        if (update_internal_cache) {
            grammar.cache_hash = cache_key;
            grammar.allocator.free(grammar.cache_styles);
            grammar.cache_styles = try grammar.allocator.dupe(TokenStyle, styles);
        }
        return .{ .styles = styles, .changed_ranges = null };
    };

    // Save old tree for change-range diffing before the new parse replaces it.
    const old_prev = grammar.prev_tree;

    // Apply the edit annotation to the old tree so tree-sitter can re-parse
    // incrementally in O(edit_region) instead of O(file_size).
    if (old_prev) |op| {
        if (tree_edit) |te| {
            op.edit(.{
                .start_byte = te.start_byte,
                .old_end_byte = te.old_end_byte,
                .new_end_byte = te.new_end_byte,
                .start_point = .{ .row = te.start_row, .column = te.start_col },
                .old_end_point = .{ .row = te.old_end_row, .column = te.old_end_col },
                .new_end_point = .{ .row = te.new_end_row, .column = te.new_end_col },
            });
        }
    }

    const tree = grammar.parser.parseString(source, old_prev) orelse {
        if (update_internal_cache) {
            grammar.cache_hash = cache_key;
            grammar.allocator.free(grammar.cache_styles);
            grammar.cache_styles = try grammar.allocator.dupe(TokenStyle, styles);
        }
        return .{ .styles = styles, .changed_ranges = null };
    };
    defer tree.destroy();

    // Compute which parse-tree ranges actually changed before we overwrite prev_tree.
    const changed_ranges: ?[]ts.Range = blk: {
        const op = old_prev orelse break :blk null;
        break :blk op.getChangedRanges(allocator, tree) catch null;
    };

    // Store new tree for incremental re-parsing on next source change; destroy old.
    if (old_prev) |op| op.destroy();
    grammar.prev_tree = tree.dupe();

    const root = tree.rootNode();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    // Restrict query scan to the requested byte range (viewport) so we skip
    // nodes that are off-screen. This scales the query cost with viewport size
    // rather than file size — a major win for large files.
    cursor.setByteRange(query_start_byte, query_end_byte) catch {};
    cursor.exec(query, root);

    // Packed byte: high nibble = priority (0-15), low nibble = reserved.
    // Avoids a separate priorities allocation and improves cache locality.
    const prio_map = try allocator.alloc(u8, source.len);
    defer allocator.free(prio_map);
    @memset(prio_map, 0);

    while (cursor.nextMatch()) |match| {
        if (!satisfiesPredicates(query, match, source)) continue;

        for (match.captures) |cap| {
            if (cap.index >= grammar.capture_meta.len) continue;
            const meta = grammar.capture_meta[cap.index];
            if (meta.prio == 0) continue;

            const start: usize = @intCast(cap.node.startByte());
            const end: usize = @intCast(cap.node.endByte());
            const clamped_end = @min(end, source.len);
            if (start >= clamped_end) continue;

            for (styles[start..clamped_end], prio_map[start..clamped_end]) |*s, *pk| {
                if (pk.* < meta.prio) {
                    s.* = meta.style;
                    pk.* = meta.prio;
                }
            }
        }
    }

    // Update internal cache only when requested (not needed when caller has its own cache).
    if (update_internal_cache) {
        grammar.cache_hash = cache_key;
        grammar.allocator.free(grammar.cache_styles);
        grammar.cache_styles = try grammar.allocator.dupe(TokenStyle, styles);
    }

    return .{ .styles = styles, .changed_ranges = changed_ranges };
}

/// Re-run the viewport-scoped query on the existing parsed tree, without reparsing.
/// Use this for scroll-only cache busts when source content has not changed.
/// The returned slice is byte-parallel to `source`; caller owns it.
pub fn highlightQueryOnly(
    allocator: std.mem.Allocator,
    grammar: *GrammarHandle,
    source: []const u8,
    query_start_byte: u32,
    query_end_byte: u32,
) ![]TokenStyle {
    const query = grammar.queries.highlights orelse return error.NoQuery;
    const tree = grammar.prev_tree orelse return error.NoTree;

    const styles = try allocator.alloc(TokenStyle, source.len);
    @memset(styles, .normal);

    const root = tree.rootNode();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.setByteRange(query_start_byte, query_end_byte) catch {};
    cursor.exec(query, root);

    const prio_map = try allocator.alloc(u8, source.len);
    defer allocator.free(prio_map);
    @memset(prio_map, 0);

    while (cursor.nextMatch()) |match| {
        if (!satisfiesPredicates(query, match, source)) continue;
        for (match.captures) |cap| {
            if (cap.index >= grammar.capture_meta.len) continue;
            const meta = grammar.capture_meta[cap.index];
            if (meta.prio == 0) continue;
            const start: usize = @intCast(cap.node.startByte());
            const end: usize = @intCast(cap.node.endByte());
            const clamped_end = @min(end, source.len);
            if (start >= clamped_end) continue;
            for (styles[start..clamped_end], prio_map[start..clamped_end]) |*s, *pk| {
                if (pk.* < meta.prio) {
                    s.* = meta.style;
                    pk.* = meta.prio;
                }
            }
        }
    }
    return styles;
}
test "highlight: keyword and string styles in Zig source" {
    // Requires runtime/grammars/libtree-sitter-zig.so to exist (built by `zig build grammar -- build zig`).
    // Skip gracefully when grammar files are absent.
    const alloc = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const paths: GrammarPaths = .{ .lib_dir = "runtime/grammars", .query_dir = "runtime/queries" };
    var grammar = loadGrammar(io, alloc, paths, "zig") catch |err| {
        std.log.warn("skipping treesitter highlight test: loadGrammar failed: {}", .{err});
        return;
    };
    defer grammar.deinit();

    const source = "const x: u32 = 42;\n";
    const result = try highlightVersioned(alloc, &grammar, source, 0, null, 0, @intCast(source.len));
    defer alloc.free(result.styles);
    defer if (result.changed_ranges) |r| alloc.free(r);

    // Expect styles array is parallel to source bytes.
    try std.testing.expectEqual(source.len, result.styles.len);

    // "const" starts at byte 0 and is 5 bytes. Expect keyword highlight.
    for (result.styles[0..5]) |s| {
        try std.testing.expectEqual(TokenStyle.keyword, s);
    }

    // "42" starts at byte 15 and is 2 bytes. Expect number highlight.
    for (result.styles[15..17]) |s| {
        try std.testing.expectEqual(TokenStyle.number, s);
    }
}
