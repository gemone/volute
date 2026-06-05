/// Render benchmark — measures render() latency without a real terminal.
///
/// Run via: `zig build bench-render`
/// Outputs: `mean_us=<N>  min_us=<N>  total_renders=<N>` for each scenario
///
/// Three scenarios are measured:
///   1. Warm cache: same content, render cache hot (simulates idle/cursor-move)
///   2. Edit cycle: content_version bumped, no grammar (simulates typing without highlights)
///   3. Grammar edit cycle: real grammar + actual text mutation (simulates highlighted editing)
const std = @import("std");
const Buffer = @import("vx/buffer.zig").Buffer;
const Editor = @import("vx/editor.zig").Editor;
const Terminal = @import("vx/terminal.zig").Terminal;
const treesitter = @import("vx/treesitter.zig");
const highlight_worker_mod = @import("vx/highlight_worker.zig");
const view = @import("vx/view.zig");
const keymap = @import("vx/keymap.zig");

/// 80 lines of Zig source code used as benchmark input.
const SAMPLE_SOURCE =
    \\const std = @import("std");
    \\const Buffer = @import("vx/buffer.zig").Buffer;
    \\
    \\pub const Editor = struct {
    \\    allocator: std.mem.Allocator,
    \\    cursor: struct { row: usize = 0, col: usize = 0 },
    \\    mode: enum { normal, insert } = .normal,
    \\
    \\    pub fn init(alloc: std.mem.Allocator) !Editor {
    \\        return .{ .allocator = alloc, .cursor = .{}, .mode = .normal };
    \\    }
    \\
    \\    pub fn deinit(self: *Editor) void {
    \\        _ = self;
    \\    }
    \\
    \\    pub fn handleKey(self: *Editor, key: u8) !void {
    \\        switch (self.mode) {
    \\            .normal => {
    \\                if (key == 'i') self.mode = .insert;
    \\                if (key == 'h' and self.cursor.col > 0) self.cursor.col -= 1;
    \\                if (key == 'l') self.cursor.col += 1;
    \\                if (key == 'j') self.cursor.row += 1;
    \\                if (key == 'k' and self.cursor.row > 0) self.cursor.row -= 1;
    \\            },
    \\            .insert => {
    \\                if (key == 27) self.mode = .normal; // ESC
    \\            },
    \\        }
    \\    }
    \\};
    \\
    \\fn computeHash(data: []const u8) u64 {
    \\    var h: u64 = 14695981039346656037;
    \\    for (data) |b| {
    \\        h ^= @as(u64, b);
    \\        h *%= 1099511628211;
    \\    }
    \\    return h;
    \\}
    \\
    \\pub fn main() !void {
    \\    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    \\    defer _ = gpa_state.deinit();
    \\    const gpa = gpa_state.allocator();
    \\
    \\    var editor = try Editor.init(gpa);
    \\    defer editor.deinit();
    \\
    \\    const source = "hello world";
    \\    const hash = computeHash(source);
    \\    std.debug.print("hash={d}\n", .{hash});
    \\
    \\    // Simulate some key handling
    \\    const keys = [_]u8{ 'j', 'j', 'l', 'l', 'i', 27 };
    \\    for (keys) |k| try editor.handleKey(k);
    \\
    \\    std.debug.print("done row={d} col={d}\n", .{
    \\        editor.cursor.row,
    \\        editor.cursor.col,
    \\    });
    \\}
    \\
;

fn buildEditor(
    gpa: std.mem.Allocator,
    io: std.Io,
    content: []const u8,
) !Editor {
    var ed = Editor{
        .allocator = gpa,
        .io = io,
        .terminal = .{
            .nc_ptr   = undefined,
            .stdplane = undefined,
            .size     = .{ .rows = 40, .cols = 120 },
            .io       = io,
            .saved_termios = null,
            .nc_timeout_count = 0,
        },
        .buffers = .empty,
        .tabs = .empty,
        .current_tab = 0,
        .float_bufs = .empty,
        .float_mode = false,
        .mode = .normal,
        .pending_keys = .empty,
        .pending_trie_name = "",
        .key_trie_root = keymap.insertKeymap(),
        .status_msg = null,
        .command_buf = .empty,
        .in_command_mode = false,
        .pending_input = .none,
        .pending_count = 0,
        .repeat_target = 0,
        .pending_command = null,
        .should_quit = false,
        .registers = [_]Editor.Register{.{}} ** Editor.NUM_REGISTERS,
        .active_register = null,
        .search_pattern = null,
        .last_find_char = null,
        .last_find_command = null,
        .in_search_mode = false,
        .search_direction = .forward,
        .search_start_cursor = .{},
        .normal_cursor_style = .block,
        .insert_cursor_style = .beam,
        .select_cursor_style = .block,
        .last_render_buf = null,
        .last_render_scroll = 0,
        .last_render_rows = 0,
        .last_render_cols = 0,
        .last_render_cursor = .{},
        .last_render_mode = .normal,
        .last_render_selection = null,
        .fileencodings = null,
        .grammar_paths = null,
        .highlight_worker = null,
        .grammar_name = null,
        .cached_hl_styles = null,
        .last_hl_buf_version = std.math.maxInt(u64),
        .last_hl_scroll = std.math.maxInt(usize),
        .src_cache = .empty,
        .src_cache_version = std.math.maxInt(u64),
        .render_style_buf = .empty,
    };

    const buf = try Buffer.initStrategy(gpa, .gap_buffer, content);
    errdefer buf.deinit();
    try ed.buffers.append(gpa, buf);
    return ed;
}

fn deinitEditor(ed: *Editor) void {
    for (ed.buffers.items) |b| b.deinit();
    ed.buffers.deinit(ed.allocator);
    ed.pending_keys.deinit(ed.allocator);
    ed.command_buf.deinit(ed.allocator);
    for (&ed.registers) |*reg| reg.deinit(ed.allocator);
    ed.jump_list.deinit(ed.allocator);
    if (ed.search_pattern) |p| ed.allocator.free(p);
    if (ed.status_msg) |m| ed.allocator.free(m);
    if (ed.cached_hl_styles) |s| ed.allocator.free(s);
    ed.src_cache.deinit(ed.allocator);
    if (ed.highlight_worker) |w| w.deinit();
    ed.render_style_buf.deinit(ed.allocator);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const RENDERS = 500;

    // --- Scenario 1: Warm cache (same content) ---
    {
        var ed = try buildEditor(gpa, io, SAMPLE_SOURCE);
        defer deinitEditor(&ed);

        // First render: cold (grammar load + highlight computation).
        view.render(&ed) catch {};

        var min_ns: u64 = std.math.maxInt(u64);
        const loop_t0 = std.Io.Clock.awake.now(io);
        for (0..RENDERS) |_| {
            const t0 = std.Io.Clock.awake.now(io);
            view.render(&ed) catch {};
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
            if (elapsed < min_ns) min_ns = elapsed;
        }
        const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
        const mean_us = total_ns / RENDERS / 1000;
        const min_us = min_ns / 1000;
        std.debug.print("warm_cache mean_us={d} min_us={d} total_renders={d}\n", .{
            mean_us, min_us, RENDERS,
        });
    }

    // --- Scenario 2: Edit cycle (content changes each render) ---
    {
        var ed = try buildEditor(gpa, io, SAMPLE_SOURCE);
        defer deinitEditor(&ed);

        // Warm up
        view.render(&ed) catch {};

        var min_ns: u64 = std.math.maxInt(u64);
        const loop_t0 = std.Io.Clock.awake.now(io);
        for (0..RENDERS) |i| {
            // Simulate a single-char insertion to bust highlight cache.
            const buf_ptr = ed.getBuffer() orelse break;
            buf_ptr.content_version +%= 1;
            buf_ptr.render_cache.markDirty(i % 30);

            const t0 = std.Io.Clock.awake.now(io);
            view.render(&ed) catch {};
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
            if (elapsed < min_ns) min_ns = elapsed;
        }
        const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
        const mean_us = total_ns / RENDERS / 1000;
        const min_us = min_ns / 1000;
        std.debug.print("edit_cycle mean_us={d} min_us={d} total_renders={d}\n", .{
            mean_us, min_us, RENDERS,
        });
    }
    // --- Scenario 2b: Large file edit cycle (no async worker, just render overhead) ---
    // Uses content_version bump (not real edit) to isolate pure render cost.
    {
        const LARGE_SOURCE = @embedFile("vx/view.zig");
        var ed = try buildEditor(gpa, io, LARGE_SOURCE);
        defer deinitEditor(&ed);
        ed.activeWindow().?.scroll = 500;
        view.render(&ed) catch {};

        var min_ns: u64 = std.math.maxInt(u64);
        const loop_t0 = std.Io.Clock.awake.now(io);
        for (0..RENDERS) |i| {
            const buf_ptr = ed.getBuffer() orelse break;
            buf_ptr.content_version +%= 1;
            buf_ptr.render_cache.markDirty(500 + i % 24);

            const t0 = std.Io.Clock.awake.now(io);
            view.render(&ed) catch {};
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
            if (elapsed < min_ns) min_ns = elapsed;
        }
        const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
        std.debug.print("large_file_render_only mean_us={d} min_us={d} file_size={d}KB scroll=500\n", .{
            total_ns / RENDERS / 1000, min_ns / 1000, LARGE_SOURCE.len / 1024,
        });
    }

    // --- Scenario 3: Async render dispatch latency with grammar (small file) ---
    // Measures how fast render() returns when content changes with a loaded async worker.
    // This is the input latency the user experiences when typing with syntax highlighting.
    {
        const grammar_paths: treesitter.GrammarPaths = .{
            .lib_dir = "runtime/grammars",
            .query_dir = "runtime/queries",
        };
        const grammar_or_err = treesitter.loadGrammar(io, gpa, grammar_paths, "zig");
        if (grammar_or_err) |grammar| {
            var ed = try buildEditor(gpa, io, SAMPLE_SOURCE);
            defer deinitEditor(&ed);
            // Set path so grammar auto-detection returns "zig" and doesn't destroy worker.
            if (ed.getBuffer()) |b| b.path = gpa.dupe(u8, "bench.zig") catch null;
            // Wire up async worker (owns grammar; parsed on background thread).
            ed.highlight_worker = highlight_worker_mod.HighlightWorker.init(gpa, io, grammar) catch null;
            ed.grammar_name = "zig";

            // Warm up: let worker do first parse, drain result.
            view.render(&ed) catch {};
            { const _ts = std.posix.timespec{ .sec = 0, .nsec = 5_000_000 }; _ = std.posix.system.nanosleep(&_ts, null); } // 5ms - let worker finish
            view.render(&ed) catch {}; // pick up result

            var min_ns: u64 = std.math.maxInt(u64);
            const loop_t0 = std.Io.Clock.awake.now(io);
            for (0..RENDERS) |i| {
                const buf_ptr = ed.getBuffer() orelse break;
                if (i % 2 == 0) {
                    buf_ptr.insertCharAt(.{ .row = 0, .col = 0 }, ' ') catch {};
                } else {
                    _ = buf_ptr.deleteCharAt(.{ .row = 0, .col = 1 }) catch {};
                }
                // Measure only the dispatch time — NOT waiting for worker result.
                const t0 = std.Io.Clock.awake.now(io);
                view.render(&ed) catch {};
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
                if (elapsed < min_ns) min_ns = elapsed;
            }
            const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
            std.debug.print("grammar_edit_dispatch mean_us={d} min_us={d} total_renders={d}\n", .{
                total_ns / RENDERS / 1000, min_ns / 1000, RENDERS,
            });
        } else |err| {
            std.debug.print("grammar_edit_dispatch SKIPPED (grammar load failed: {s})\n", .{@errorName(err)});
        }
    }
    // --- Scenario 4: Async worker time-to-result (small file, end-to-end highlight latency) ---
    // Measures time from render() dispatch to result available — the highlight update latency.
    {
        const grammar_paths: treesitter.GrammarPaths = .{
            .lib_dir = "runtime/grammars",
            .query_dir = "runtime/queries",
        };
        const grammar_or_err = treesitter.loadGrammar(io, gpa, grammar_paths, "zig");
        if (grammar_or_err) |grammar| {
            var ed = try buildEditor(gpa, io, SAMPLE_SOURCE);
            defer deinitEditor(&ed);
            if (ed.getBuffer()) |b| b.path = gpa.dupe(u8, "bench.zig") catch null;
            ed.highlight_worker = highlight_worker_mod.HighlightWorker.init(gpa, io, grammar) catch null;
            ed.grammar_name = "zig";
            view.render(&ed) catch {};
            { const _ts = std.posix.timespec{ .sec = 0, .nsec = 5_000_000 }; _ = std.posix.system.nanosleep(&_ts, null); }
            view.render(&ed) catch {};

            var total_ttl_ns: u64 = 0;
            var min_ttl_ns: u64 = std.math.maxInt(u64);
            const SAMPLES = 100;
            for (0..SAMPLES) |i| {
                const buf_ptr = ed.getBuffer() orelse break;
                if (i % 2 == 0) {
                    buf_ptr.insertCharAt(.{ .row = 0, .col = 0 }, ' ') catch {};
                } else {
                    _ = buf_ptr.deleteCharAt(.{ .row = 0, .col = 1 }) catch {};
                }
                const t0 = std.Io.Clock.awake.now(io);
                view.render(&ed) catch {}; // dispatch submit
                // Spin-wait for worker result (measures total end-to-end highlight latency).
                var waited: u64 = 0;
                while (waited < 50_000_000) : (waited += 10_000) { // max 50ms
                    if (ed.highlight_worker) |w| {
                        if (w.hasResult()) break;
                    }
                    { const _ts = std.posix.timespec{ .sec = 0, .nsec = 10_000 }; _ = std.posix.system.nanosleep(&_ts, null); } // 10us poll
                }
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
                total_ttl_ns += elapsed;
                if (elapsed < min_ttl_ns) min_ttl_ns = elapsed;
                // Drain result so next iteration starts fresh.
                view.render(&ed) catch {};
            }
            std.debug.print("worker_ttl mean_us={d} min_us={d} (small file)\n", .{
                total_ttl_ns / SAMPLES / 1000, min_ttl_ns / 1000,
            });
        } else |err| {
            std.debug.print("worker_ttl SKIPPED (grammar load failed: {s})\n", .{@errorName(err)});
        }
    }
    // --- Scenario 5: Large-file async render dispatch (44KB, highlights async) ---
    // Key regression test: large file must NOT block the render thread.
    {
        const grammar_paths: treesitter.GrammarPaths = .{
            .lib_dir = "runtime/grammars",
            .query_dir = "runtime/queries",
        };
        const grammar_or_err = treesitter.loadGrammar(io, gpa, grammar_paths, "zig");
        if (grammar_or_err) |grammar| {
            const LARGE_SOURCE = @embedFile("vx/view.zig");
            var ed = try buildEditor(gpa, io, LARGE_SOURCE);
            defer deinitEditor(&ed);
            if (ed.getBuffer()) |b| b.path = gpa.dupe(u8, "bench.zig") catch null;
            ed.highlight_worker = highlight_worker_mod.HighlightWorker.init(gpa, io, grammar) catch null;
            ed.grammar_name = "zig";
            ed.activeWindow().?.scroll = 500;
            view.render(&ed) catch {};
            { const _ts = std.posix.timespec{ .sec = 0, .nsec = 20_000_000 }; _ = std.posix.system.nanosleep(&_ts, null); } // 20ms warm-up for large file
            view.render(&ed) catch {};

            var min_ns: u64 = std.math.maxInt(u64);
            var min_edit_ns: u64 = std.math.maxInt(u64);
            var total_edit_ns: u64 = 0;
            const loop_t0 = std.Io.Clock.awake.now(io);
            for (0..RENDERS) |i| {
                const buf_ptr = ed.getBuffer() orelse break;
                const t_edit = std.Io.Clock.awake.now(io);
                if (i % 2 == 0) {
                    buf_ptr.insertCharAt(.{ .row = 500, .col = 0 }, ' ') catch {};
                } else {
                    _ = buf_ptr.deleteCharAt(.{ .row = 500, .col = 1 }) catch {};
                }
                const edit_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t_edit.nanoseconds);
                total_edit_ns += edit_ns;
                if (edit_ns < min_edit_ns) min_edit_ns = edit_ns;
                const t0 = std.Io.Clock.awake.now(io);
                view.render(&ed) catch {};
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
                if (elapsed < min_ns) min_ns = elapsed;
            }
            const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
            std.debug.print("large_file_async_dispatch mean_us={d} min_us={d} file_size={d}KB\n", .{
                total_ns / RENDERS / 1000, min_ns / 1000, LARGE_SOURCE.len / 1024,
            });
            std.debug.print("  └ rope_edit mean_us={d} min_us={d} (insertCharAt/deleteCharAt at row 500)\n", .{
                total_edit_ns / RENDERS / 1000, min_edit_ns / 1000,
            });
        } else |err| {
            std.debug.print("large_file_async_dispatch SKIPPED (grammar load failed: {s})\n", .{@errorName(err)});
        }
    }
    // --- Micro-bench: writeToBuf alone on large file ---
    // Isolates the O(file_size) serialization cost.
    {
        const LARGE_SOURCE = @embedFile("vx/view.zig");
        var ed = try buildEditor(gpa, io, LARGE_SOURCE);
        defer deinitEditor(&ed);
        const buf_ptr = ed.getBuffer() orelse return;

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(gpa);

        // Warm up
        buf_ptr.text.writeToBuf(gpa, &scratch) catch {};

        var min_ns: u64 = std.math.maxInt(u64);
        const loop_t0 = std.Io.Clock.awake.now(io);
        for (0..RENDERS) |_| {
            scratch.clearRetainingCapacity();
            const t0 = std.Io.Clock.awake.now(io);
            buf_ptr.text.writeToBuf(gpa, &scratch) catch {};
            const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
            if (elapsed < min_ns) min_ns = elapsed;
        }
        const total_ns: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - loop_t0.nanoseconds);
        std.debug.print("writeToBuf_only mean_us={d} min_us={d} file_size={d}KB\n", .{
            total_ns / RENDERS / 1000, min_ns / 1000, LARGE_SOURCE.len / 1024,
        });
    }
    // --- Micro-bench: bare tree-sitter parse (incremental vs full) ---
    // Isolates parseString cost with and without Tree.edit() annotation.
    {
        const LARGE_SOURCE = @embedFile("vx/view.zig");
        const grammar_paths: treesitter.GrammarPaths = .{
            .lib_dir = "runtime/grammars",
            .query_dir = "runtime/queries",
        };
        const grammar_or_err = treesitter.loadGrammar(io, gpa, grammar_paths, "zig");
        if (grammar_or_err) |grammar_const| {
            var grammar = grammar_const;
            defer grammar.deinit();
            var src_buf: std.ArrayList(u8) = .empty;
            defer src_buf.deinit(gpa);
            var ed = try buildEditor(gpa, io, LARGE_SOURCE);
            defer deinitEditor(&ed);
            const buf_ptr = ed.getBuffer() orelse return;
            buf_ptr.text.writeToBuf(gpa, &src_buf) catch {};
            const src = src_buf.items;

            // Warm-up: first parse (no old tree).
            var prev: ?*@import("tree-sitter").Tree = grammar.parser.parseString(src, null);
            if (prev) |t| t.destroy();
            prev = null;

            // Measure full re-parse (no Tree.edit annotation).
            var min_full_ns: u64 = std.math.maxInt(u64);
            for (0..100) |_| {
                if (prev) |t| t.destroy();
                const t0 = std.Io.Clock.awake.now(io);
                const tree = grammar.parser.parseString(src, null);
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
                if (elapsed < min_full_ns) min_full_ns = elapsed;
                prev = tree;
            }
            if (prev) |t| t.destroy();
            prev = null;

            // Measure incremental re-parse with Tree.edit (single-char insert at midpoint).
            const mid: u32 = @intCast(src.len / 2);
            var min_incr_ns: u64 = std.math.maxInt(u64);
            // Seed: first full parse.
            prev = grammar.parser.parseString(src, null);
            for (0..100) |_| {
                if (prev) |op| {
                    op.edit(.{
                        .start_byte = mid,
                        .old_end_byte = mid,
                        .new_end_byte = mid + 1,
                        .start_point = .{ .row = 0, .column = 0 },
                        .old_end_point = .{ .row = 0, .column = 0 },
                        .new_end_point = .{ .row = 0, .column = 1 },
                    });
                }
                const t0 = std.Io.Clock.awake.now(io);
                const tree = grammar.parser.parseString(src, prev);
                const elapsed: u64 = @intCast(std.Io.Clock.awake.now(io).nanoseconds - t0.nanoseconds);
                if (elapsed < min_incr_ns) min_incr_ns = elapsed;
                if (prev) |t| t.destroy();
                prev = tree;
            }
            if (prev) |t| t.destroy();

            std.debug.print("ts_parse_full_min_us={d} ts_parse_incremental_min_us={d} file_size={d}KB\n", .{
                min_full_ns / 1000, min_incr_ns / 1000, LARGE_SOURCE.len / 1024,
            });
        } else |err| {
            std.debug.print("ts_parse bench SKIPPED (grammar load failed: {s})\n", .{@errorName(err)});
        }
    }
}
