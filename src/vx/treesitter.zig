const std = @import("std");
const ts = @import("tree-sitter");
const gops = @import("languages").grammar_ops;

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

/// A loaded tree-sitter language with all available SCM queries.
/// Owns the dynamic library handle — must call `deinit` to release.
pub const GrammarHandle = struct {
    lib: std.DynLib,
    language: *const ts.Language,
    queries: Queries,

    pub fn deinit(self: *GrammarHandle) void {
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

    var lib = try std.DynLib.open(lib_path);
    errdefer lib.close();

    const sym_name = try std.fmt.allocPrint(allocator, "tree_sitter_{s}", .{name});
    defer allocator.free(sym_name);
    const sym_name_z = try allocator.dupeZ(u8, sym_name);
    defer allocator.free(sym_name_z);

    const LangFn = *const fn () callconv(.c) *const ts.Language;
    const lang_fn = lib.lookup(LangFn, sym_name_z) orelse return error.SymbolNotFound;
    const language = lang_fn();

    const queries = Queries{
        .highlights  = loadQuery(io, allocator, paths.query_dir, name, "highlights.scm",  language),
        .injections  = loadQuery(io, allocator, paths.query_dir, name, "injections.scm",  language),
        .locals      = loadQuery(io, allocator, paths.query_dir, name, "locals.scm",      language),
        .indents     = loadQuery(io, allocator, paths.query_dir, name, "indents.scm",     language),
        .textobjects = loadQuery(io, allocator, paths.query_dir, name, "textobjects.scm", language),
        .tags        = loadQuery(io, allocator, paths.query_dir, name, "tags.scm",        language),
    };

    return .{ .lib = lib, .language = language, .queries = queries };
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
                if (std.mem.eql(u8, text, val)) { found = true; break; }
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
pub fn highlight(allocator: std.mem.Allocator, grammar: *const GrammarHandle, source: []const u8) ![]TokenStyle {
    const styles = try allocator.alloc(TokenStyle, source.len);
    @memset(styles, .normal);

    const query = grammar.query orelse return styles;

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(grammar.language);

    const tree = parser.parseString(source, null) orelse return styles;
    defer tree.destroy();

    const root = tree.rootNode();
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, root);

    while (cursor.nextMatch()) |match| {
        if (!satisfiesPredicates(query, match, source)) continue;

        for (match.captures) |cap| {
            const cap_name = query.captureNameForId(cap.index) orelse continue;
            const new_style = captureToStyle(cap_name);
            if (new_style == .normal) continue;

            const start: usize = @intCast(cap.node.startByte());
            const end: usize = @intCast(cap.node.endByte());
            const clamped_end = @min(end, source.len);
            if (start >= clamped_end) continue;

            const new_prio = stylePriority(new_style);
            for (styles[start..clamped_end]) |*s| {
                if (stylePriority(s.*) < new_prio) s.* = new_style;
            }
        }
    }

    return styles;
}

