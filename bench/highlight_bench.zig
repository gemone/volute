/// bench/highlight_bench.zig — Benchmark: parse + highlight a ~100-line Zig file.
///
/// Usage: zig build bench-highlight
/// Prints: iterations, total_ns, ns/op to stdout.
/// Grammars must be built first: zig build grammars (or use runtime/grammars/).

const std = @import("std");
const treesitter = @import("treesitter");

/// ~100 lines of representative Zig code used as benchmark source.
const BENCH_SOURCE =
    \\const std = @import("std");
    \\
    \\pub const TokenStyle = enum {
    \\    normal,
    \\    keyword,
    \\    type_name,
    \\    string,
    \\    comment,
    \\    number,
    \\    builtin,
    \\};
    \\
    \\pub fn captureToStyle(capture_name: []const u8) TokenStyle {
    \\    const rules = std.StaticStringMap(TokenStyle).initComptime(.{
    \\        .{ "comment", .comment },
    \\        .{ "keyword", .keyword },
    \\        .{ "type", .type_name },
    \\        .{ "string", .string },
    \\        .{ "number", .number },
    \\        .{ "function", .type_name },
    \\        .{ "variable", .normal },
    \\        .{ "operator", .keyword },
    \\    });
    \\    var name = capture_name;
    \\    while (true) {
    \\        if (rules.get(name)) |style| return style;
    \\        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse break;
    \\        name = name[0..dot];
    \\    }
    \\    return .normal;
    \\}
    \\
    \\pub fn stylePriority(style: TokenStyle) u8 {
    \\    return switch (style) {
    \\        .normal => 0,
    \\        .builtin => 3,
    \\        .comment => 2,
    \\        .number => 2,
    \\        .string => 2,
    \\        .type_name => 3,
    \\        .keyword => 4,
    \\    };
    \\}
    \\
    \\pub fn highlight(
    \\    allocator: std.mem.Allocator,
    \\    grammar: *const GrammarHandle,
    \\    source: []const u8,
    \\) ![]TokenStyle {
    \\    const styles = try allocator.alloc(TokenStyle, source.len);
    \\    @memset(styles, .normal);
    \\    const query = grammar.queries.highlights orelse return styles;
    \\    const parser = ts.Parser.create();
    \\    defer parser.destroy();
    \\    try parser.setLanguage(grammar.language);
    \\    const tree = parser.parseString(source, null) orelse return styles;
    \\    defer tree.destroy();
    \\    const root = tree.rootNode();
    \\    const cursor = ts.QueryCursor.create();
    \\    defer cursor.destroy();
    \\    cursor.exec(query, root);
    \\    while (cursor.nextMatch()) |match| {
    \\        for (match.captures) |cap| {
    \\            const cap_name = query.captureNameForId(cap.index) orelse continue;
    \\            const new_style = captureToStyle(cap_name);
    \\            if (new_style == .normal) continue;
    \\            const start: usize = @intCast(cap.node.startByte());
    \\            const end: usize = @intCast(cap.node.endByte());
    \\            const clamped_end = @min(end, source.len);
    \\            if (start >= clamped_end) continue;
    \\            const new_prio = stylePriority(new_style);
    \\            for (styles[start..clamped_end]) |*s| {
    \\                if (stylePriority(s.*) < new_prio) s.* = new_style;
    \\            }
    \\        }
    \\    }
    \\    return styles;
    \\}
    \\
    \\test "style priority ordering" {
    \\    try std.testing.expect(stylePriority(.keyword) > stylePriority(.normal));
    \\    try std.testing.expect(stylePriority(.type_name) > stylePriority(.comment));
    \\}
;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = init.io;

    // Determine grammar/query paths relative to CWD (project root).
    const grammars_dir = "runtime/grammars";
    const queries_dir = "runtime/queries";

    const paths = treesitter.GrammarPaths{
        .lib_dir = grammars_dir,
        .query_dir = queries_dir,
    };

    var grammar = treesitter.loadGrammar(io, allocator, paths, "zig") catch |err| {
        const stderr = std.Io.File.stderr();
        var buf: [256]u8 = undefined;
        var bw = stderr.writerStreaming(io, &buf);
        try bw.interface.print(
            "bench: failed to load zig grammar: {s}\n  (ensure runtime/grammars/ exists)\n",
            .{@errorName(err)},
        );
        try bw.flush();
        std.process.exit(1);
    };
    defer grammar.deinit();

    const N: usize = 2000;

    // Warm-up pass (1 iteration, not timed).
    {
        const styles = try treesitter.highlight(allocator, &grammar, BENCH_SOURCE);
        allocator.free(styles);
    }

    const t0 = std.Io.Clock.awake.now(io);
    for (0..N) |_| {
        const styles = try treesitter.highlight(allocator, &grammar, BENCH_SOURCE);
        allocator.free(styles);
    }
    const t1 = std.Io.Clock.awake.now(io);
    const elapsed: u64 = @intCast(t1.nanoseconds - t0.nanoseconds);

    const ns_per_op = elapsed / N;
    const stdout = std.Io.File.stdout();
    var buf: [256]u8 = undefined;
    var bw = stdout.writerStreaming(io, &buf);
    try bw.interface.print(
        "highlight_bench: N={d}  total={d}ms  ns/op={d}\n",
        .{ N, elapsed / 1_000_000, ns_per_op },
    );
    try bw.flush();
}
