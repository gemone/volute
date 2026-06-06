const std = @import("std");
const Editor = @import("vx/editor.zig").Editor;
const terminal = @import("vx/terminal.zig");
const enc_mod = @import("codecs/encoding.zig");
const validation = @import("codecs/validation.zig");
const Dir = std.Io.Dir;
const lcfg = @import("languages");
const grammar_detect = @import("vx/grammar.zig");

fn stderrPrint(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [256]u8 = undefined;
    var w = std.Io.File.stderr().writerStreaming(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

// ── CLI argument types ─────────────────────────────────────────────────────────

/// Parsed command-line arguments.
const CliArgs = struct {
    /// Source encoding name (-e <enc>).  Null = auto-detect.
    src_enc: ?[]const u8 = null,
    /// Destination encoding name (--to <enc>).  Defaults to utf-8.
    dst_enc: []const u8 = "utf-8",
    /// Output path (-o <file>).  Use "-" for stdout.  Null = TUI mode.
    output: ?[]const u8 = null,
    /// In-place mode (-i).  Rewrites each input file with transcoded content.
    in_place: bool = false,
    /// Grammar arguments (--grammar <cmd> [args...]).  Null = no grammar command.
    /// When present, grammar_args[0] is the subcommand and remaining elements are its args.
    grammar_args: ?[]const []const u8 = null,
    /// Positional file arguments.
    files: []const []const u8 = &.{},

    /// True when batch (non-interactive) mode is requested.
    fn isBatch(self: CliArgs) bool {
        return self.output != null or self.in_place or self.grammar_args != null;
    }
};

/// Parse argv into a CliArgs.  Returns an error and prints usage on bad input.
fn parseArgs(
    allocator: std.mem.Allocator,
    io: std.Io,
    args_iter: *std.process.Args.Iterator,
) !CliArgs {
    var src_enc: ?[]const u8 = null;
    var dst_enc: []const u8 = "utf-8";
    var output: ?[]const u8 = null;
    var in_place = false;
    var grammar_args: ?[]const []const u8 = null;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);
    var end_of_opts = false; // true after "--"

    while (args_iter.next()) |arg| {
        if (end_of_opts) {
            // Everything after "--" is a positional argument.
            try files.append(allocator, arg);
            continue;
        }

        if (std.mem.eql(u8, arg, "--")) {
            end_of_opts = true;
        } else if (std.mem.eql(u8, arg, "-e") or std.mem.eql(u8, arg, "--encoding")) {
            src_enc = args_iter.next() orelse {
                try stderrPrint(io, "vx: {s} requires an encoding name\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--to")) {
            dst_enc = args_iter.next() orelse {
                try stderrPrint(io, "vx: {s} requires an encoding name\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output = args_iter.next() orelse {
                try stderrPrint(io, "vx: {s} requires a file path\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--in-place")) {
            in_place = true;
        } else if (std.mem.eql(u8, arg, "--grammar")) {
            // Capture the subcommand and all remaining tokens as grammar_args.
            var gargs: std.ArrayList([]const u8) = .empty;
            while (args_iter.next()) |garg| {
                try gargs.append(allocator, garg);
            }
            if (gargs.items.len == 0) {
                try stderrPrint(io, "vx: --grammar requires a command (fetch, update, build, rm, list, test)\n", .{});
                gargs.deinit(allocator);
                return error.InvalidArgs;
            }
            grammar_args = try gargs.toOwnedSlice(allocator);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage(io);
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try stderrPrint(io, "vx: unknown flag: {s}\n", .{arg});
            return error.InvalidArgs;
        } else {
            try files.append(allocator, arg);
        }
    }

    if (in_place and output != null) {
        try stderrPrint(io, "vx: -i/--in-place and -o/--output are mutually exclusive\n", .{});
        return error.InvalidArgs;
    }
    if (in_place and files.items.len == 0) {
        try stderrPrint(io, "vx: -i/--in-place requires at least one input file\n", .{});
        return error.InvalidArgs;
    }

    return CliArgs{
        .src_enc = src_enc,
        .dst_enc = dst_enc,
        .output = output,
        .in_place = in_place,
        .grammar_args = grammar_args,
        .files = try allocator.dupe([]const u8, files.items),
    };
}

fn printUsage(io: std.Io) void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;
    out.writeAll(
        \\Usage: vx [options] [--] [file...]
        \\
        \\TUI mode (default when no -o/--output or -i/--in-place):
        \\  vx [file...]                    Open files in the editor
        \\  vx -e <enc> [file...]           Force input encoding when opening
        \\
        \\Batch transcode mode (-o or -i triggers non-interactive):
        \\  vx -e <enc> -o <out> <in>       Decode <in> from <enc>, write UTF-8 to <out>
        \\  vx -e <enc> -t <enc2> -o <out> <in>
        \\                                  Transcode <in> from <enc> to <enc2>
        \\  vx -i [-e <enc>] [-t <enc2>] <file...>
        \\                                  Transcode files in-place
        \\  Use - as file path for stdin/stdout.
        \\  Use -- to end option parsing (e.g. vx -- -myfile.txt).
        \\
        \\Options (short / long):
        \\  -e / --encoding <enc>   Source encoding (default: auto-detect)
        \\  -t / --to <enc>         Target encoding (default: utf-8)
        \\  -o / --output <file>    Output file ("-" = stdout)
        \\  -i / --in-place         Transcode files in-place
        \\  -h / --help             Show this help
        \\
        \\Encoding names: utf-8, gbk, gb18030, big5, shift-jis, euc-jp, euc-kr,
        \\                latin-1, cp1250..cp1258, koi8-r, utf-16le, utf-16be, utf-8bom
        \\
    ) catch {};
    stdout_w.interface.flush() catch {};
}

// ── Batch transcoding ──────────────────────────────────────────────────────────

/// Read an entire file (or stdin when path is "-") into a new allocation.
fn readAll(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var read_buf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &read_buf);
        return reader.interface.allocRemaining(allocator, .unlimited);
    }
    const cwd = Dir.cwd();
    var file = try cwd.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    return reader.interface.readAlloc(allocator, @intCast(stat.size));
}

/// Write bytes to a file (or stdout when path is "-") atomically.
fn writeAll(io: std.Io, path: []const u8, bytes: []const u8) !void {
    if (std.mem.eql(u8, path, "-")) {
        const stdout = std.Io.File.stdout();
        var write_buf: [4096]u8 = undefined;
        var writer = stdout.writerStreaming(io, &write_buf);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
        return;
    }
    const cwd = Dir.cwd();
    var atomic = try cwd.createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    var write_buf: [4096]u8 = undefined;
    var writer = atomic.file.writerStreaming(io, &write_buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

/// Transcode one file: read → decode to UTF-8 → re-encode → write.
fn transcodeOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    input_path: []const u8,
    output_path: []const u8,
    src_enc_forced: ?enc_mod.Encoding,
    dst_enc: enc_mod.Encoding,
) !void {
    const raw = try readAll(allocator, io, input_path);
    defer allocator.free(raw);

    // Resolve source encoding: forced by -e, or auto-detected.
    const src_enc = src_enc_forced orelse enc_mod.detect(raw);

    // Decode to UTF-8 (fast path for UTF-8/ASCII: reuse the raw buffer).
    const utf8 = switch (src_enc) {
        .utf8, .ascii => raw,
        else => try enc_mod.toUtf8(allocator, raw, src_enc),
    };
    defer if (utf8.ptr != raw.ptr) allocator.free(utf8);

    // Validate that UTF-8 content can be safely encoded in target encoding
    // This prevents silent data loss during batch transcoding
    const validation_result = try validation.validateUtf8ToEncoding(utf8, dst_enc);
    if (validation_result.is_lossy) {
        const error_msg = try validation.formatValidationError(validation_result, input_path, dst_enc);
        // Note: error_msg is allocated by page_allocator internally, don't free it with our allocator
        try stderrPrint(io, "{s}", .{error_msg});
        return error.EncodingLossDetected;
    }

    // Re-encode to target encoding (fast path for UTF-8 output).
    const out_bytes = switch (dst_enc) {
        .utf8, .ascii => utf8,
        else => try enc_mod.fromUtf8(allocator, utf8, dst_enc),
    };
    defer if (out_bytes.ptr != utf8.ptr) allocator.free(out_bytes);

    try writeAll(io, output_path, out_bytes);
}

/// Entry point for batch (-o / -i) mode.
fn runBatch(allocator: std.mem.Allocator, io: std.Io, args: CliArgs) !void {
    // Resolve and validate encoding names.
    const src_forced: ?enc_mod.Encoding = if (args.src_enc) |name| blk: {
        const e = enc_mod.Encoding.fromName(name) orelse {
            try stderrPrint(io, "vx: unknown source encoding: {s}\n", .{name});
            return error.UnknownEncoding;
        };
        break :blk e;
    } else null;

    const dst_enc = enc_mod.Encoding.fromName(args.dst_enc) orelse {
        try stderrPrint(io, "vx: unknown target encoding: {s}\n", .{args.dst_enc});
        return error.UnknownEncoding;
    };

    if (args.in_place) {
        // -i: transcode each input file back to itself.
        for (args.files) |path| {
            transcodeOne(allocator, io, path, path, src_forced, dst_enc) catch |err| {
                try stderrPrint(io, "vx: {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
        }
    } else {
        // -o: exactly one input file (or stdin "-"), one output.
        const input = if (args.files.len > 0) args.files[0] else "-";
        if (args.files.len > 1) {
            try stderrPrint(io, "vx: -o accepts only one input file\n", .{});
            return error.InvalidArgs;
        }
        try transcodeOne(allocator, io, input, args.output.?, src_forced, dst_enc);
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next(); // skip argv[0]

    const args = parseArgs(allocator, io, &args_iter) catch |err| switch (err) {
        error.HelpRequested => return,
        else => std.process.exit(1),
    };
    defer allocator.free(args.files);
    defer if (args.grammar_args) |ga| allocator.free(ga);

    // ── User language config override (VOLUTE_CONFIG_PATH/languages.zon) ─────────
    const user_lang_cfg: ?lcfg.Config = try lcfg.loadUserConfigOverride(io, allocator);
    defer if (user_lang_cfg) |cfg| lcfg.freeConfig(allocator, cfg);
    if (user_lang_cfg) |cfg| {
        grammar_detect.setLanguages(cfg.languages);
    }

    // ── Grammar commands ──────────────────────────────────────────────────────
    if (args.grammar_args) |gargs| {
        try runGrammarCommand(io, allocator, gargs);
        return;
    }

    // ── Batch (non-interactive) mode ──────────────────────────────────────────
    if (args.isBatch()) {
        runBatch(allocator, io, args) catch |err| {
            stderrPrint(io, "vx: transcode failed: {s}\n", .{@errorName(err)}) catch {};
            std.process.exit(1);
        };
        return;
    }

    // ── TUI mode ──────────────────────────────────────────────────────────────
    if (!terminal.hasInteractiveTty()) {
        stderrPrint(
            io,
            "vx: interactive TUI requires a real terminal (stdin/stdout must be TTY)\n",
            .{},
        ) catch {};
        std.process.exit(1);
    }

    var editor = try Editor.init(allocator, io);
    defer editor.deinit();

    // Resolve runtime grammar paths and load into editor.
    {
        const grammars_dir = lcfg.runtime.findGrammarsDir(io, allocator) catch null;
        if (grammars_dir) |gd| {
            const parent = std.fs.path.dirname(gd) orelse gd;
            const queries_dir = std.fmt.allocPrint(allocator, "{s}/queries", .{parent}) catch null;
            if (queries_dir) |qd| {
                editor.grammar_paths = .{ .lib_dir = gd, .query_dir = qd };
            } else {
                allocator.free(gd);
            }
        }
    }

    applyCursorStyleEnv(&editor);

    // Resolve optional forced source encoding for TUI opens.
    const forced_enc: ?enc_mod.Encoding = if (args.src_enc) |name| blk: {
        const e = enc_mod.Encoding.fromName(name) orelse {
            stderrPrint(io, "vx: unknown encoding: {s}\n", .{name}) catch {};
            std.process.exit(1);
        };
        break :blk e;
    } else null;

    for (args.files) |path| {
        const open_err = if (forced_enc) |enc|
            editor.openFileForced(path, enc)
        else
            editor.openFile(path);
        open_err catch |err| {
            stderrPrint(io, "vx: error opening {s}: {any}\n", .{ path, err }) catch {};
        };
    }

    if (editor.buffers.items.len == 0) {
        const buf = try @import("vx/buffer.zig").Buffer.init(allocator);
        try editor.buffers.append(allocator, buf);
    }

    try @import("vx/view.zig").render(&editor);
    while (!editor.should_quit) {
        const ev = editor.terminal.readEvent() catch |err| {
            if (err == error.WouldBlock or err == error.SystemResources) continue;
            return err;
        };

        switch (ev orelse {
            // Timeout: check if highlight worker has a new result.
            if (editor.highlight_worker) |w| {
                if (w.hasResult()) try @import("vx/view.zig").render(&editor);
            }
            continue;
        }) {
            .key => |k| {
                try drainQueuedInput(&editor, k);
                if (!editor.should_quit) try @import("vx/view.zig").render(&editor);
            },
            .resize => |sz| {
                editor.terminal.size = .{ .rows = sz.rows, .cols = sz.cols };
                try @import("vx/view.zig").render(&editor);
            },
            .mouse => |m| {
                try editor.handleMouseEvent(m);
                if (!editor.should_quit) try @import("vx/view.zig").render(&editor);
            },
        }
    }
}

fn applyCursorStyleEnv(editor: *Editor) void {
    editor.normal_cursor_style = readCursorStyleEnv("VX_CURSOR_NORMAL") orelse editor.normal_cursor_style;
    editor.insert_cursor_style = readCursorStyleEnv("VX_CURSOR_INSERT") orelse editor.insert_cursor_style;
    editor.select_cursor_style = readCursorStyleEnv("VX_CURSOR_SELECT") orelse editor.select_cursor_style;
}

fn readCursorStyleEnv(name: [*:0]const u8) ?terminal.CursorStyle {
    const value = std.c.getenv(name) orelse return null;
    const slice = std.mem.span(value);
    return terminal.parseCursorStyle(slice);
}

fn drainQueuedInput(editor: *Editor, first_key: @import("vx/key.zig").Key) !void {
    const Key = @import("vx/key.zig").Key;

    var pending: ?Key = first_key;
    var text_burst: std.ArrayList(u8) = .empty;
    defer text_burst.deinit(editor.allocator);

    while (pending) |key| {
        pending = null;
        if (editor.mode == .insert and isBurstInsertKey(key)) {
            // Batch consecutive printable characters into one insert to minimise
            // allocations and intermediate renders while typing quickly.
            text_burst.clearRetainingCapacity();
            try appendBurstInsertBytes(editor.allocator, &text_burst, key);

            while (true) {
                const next = try editor.terminal.readKeyNonBlocking();
                if (next == null) break;
                if (editor.mode != .insert or !isBurstInsertKey(next.?)) {
                    pending = next.?;
                    break;
                }
                try appendBurstInsertBytes(editor.allocator, &text_burst, next.?);
            }

            if (text_burst.items.len > 0) {
                try editor.insertTextBytes(text_burst.items);
            }
            continue;
        }

        try editor.handleKey(key);
        // Only drain already-buffered keys (0 ms poll). Movement/edit keys each
        // get their own render so the cursor visibly advances on every repeat.
        pending = try editor.terminal.readKeyNonBlocking();
    }
}

// ── Grammar command handling ───────────────────────────────────────────────────

const lcfg_pkg = @import("languages");
const gops = lcfg_pkg.grammar_ops;
const vx_runtime = lcfg_pkg.runtime;

/// Config write path for vx grammar commands: $VOLUTE_CONFIG_PATH/languages.zon.
/// Returns null if VOLUTE_CONFIG_PATH is not set (write operations will fail gracefully).
fn grammarConfigWritePath(allocator: std.mem.Allocator) !?[]u8 {
    const cp = std.c.getenv("VOLUTE_CONFIG_PATH") orelse return null;
    const dir = std.mem.span(cp);
    return @as(?[]u8, try std.fs.path.join(allocator, &.{ dir, "languages.zon" }));
}

/// Dispatch `vx --grammar <cmd> [args...]` to the appropriate grammar operation.
/// `gargs[0]` is the subcommand; `gargs[1..]` are its arguments.
fn runGrammarCommand(io: std.Io, allocator: std.mem.Allocator, gargs: []const []const u8) !void {
    const cmd = gargs[0];
    const cmd_args = gargs[1..];

    const runtime_dir = vx_runtime.findGrammarsDir(io, allocator) catch |err| {
        try stderrPrint(io, "vx --grammar: could not determine runtime dir: {s}\n", .{@errorName(err)});
        return err;
    };
    defer allocator.free(runtime_dir);

    if (std.mem.eql(u8, cmd, "list")) {
        return grammarList(io, allocator, runtime_dir);
    } else if (std.mem.eql(u8, cmd, "fetch")) {
        return grammarFetch(io, allocator, cmd_args, runtime_dir);
    } else if (std.mem.eql(u8, cmd, "update")) {
        return grammarUpdate(io, allocator, cmd_args, runtime_dir);
    } else if (std.mem.eql(u8, cmd, "build")) {
        return grammarBuild(io, allocator, cmd_args, runtime_dir);
    } else if (std.mem.eql(u8, cmd, "rm")) {
        return grammarRm(io, allocator, cmd_args, runtime_dir);
    } else if (std.mem.eql(u8, cmd, "test")) {
        try stderrPrint(io, "vx --grammar test: not yet implemented \xe2\x80\x94 use 'zig build grammar -- test'\n", .{});
        return error.CommandNotImplemented;
    } else {
        try stderrPrint(io, "vx --grammar: unknown command '{s}'\nAvailable: fetch, update, build, rm, list\n", .{cmd});
        return error.UnknownGrammarCommand;
    }
}

fn grammarList(io: std.Io, allocator: std.mem.Allocator, runtime_dir: []const u8) !void {
    const cfg = lcfg.config;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    try out.print("{d} grammar(s):\n", .{cfg.grammars.len});
    try out.print("  runtime grammars dir: {s}\n\n", .{runtime_dir});
    for (cfg.grammars) |g| {
        const lib_filename = try gops.grammarLibFilename(allocator, g.name);
        defer allocator.free(lib_filename);
        const lib_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime_dir, lib_filename });
        defer allocator.free(lib_path);
        const built = if (std.Io.Dir.cwd().access(io, lib_path, .{})) |_| true else |_| false;
        try out.print("  {s}\n    url:  {s}\n    hash: {s}\n    lib:  {s}  [{s}]\n\n", .{
            g.name,
            g.url,
            if (g.hash.len > 0) g.hash else "(none)",
            lib_path,
            if (built) "built" else "not built",
        });
    }
    try out.flush();
}

fn grammarFetch(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, runtime_dir: []const u8) !void {
    if (args.len > 0 and std.mem.startsWith(u8, args[0], "--save=")) {
        // --save=<name> <url> mode: fetch + save to user config
        const name = args[0]["--save=".len..];
        if (args.len < 2) {
            try stderrPrint(io, "vx --grammar fetch --save={s}: missing <url>\n", .{name});
            return error.MissingArgument;
        }
        const raw_url = args[1];
        const git_url = if (std.mem.startsWith(u8, raw_url, "git+")) raw_url["git+".len..] else raw_url;
        const url_prefix = if (std.mem.startsWith(u8, raw_url, "git+")) "git+" else "";

        const src_dir = try std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ runtime_dir, name });
        defer allocator.free(src_dir);

        var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const out = &stdout_w.interface;

        try out.print("Fetching grammar '{s}'...\n", .{name});
        const result = try gops.cloneAndHash(io, allocator, git_url, src_dir, url_prefix);
        defer allocator.free(result.pinned_url);
        defer allocator.free(result.hash);
        try out.print("  url:  {s}\n  hash: {s}\n", .{ result.pinned_url, result.hash });

        // Determine write path
        const config_path = try grammarConfigWritePath(allocator) orelse {
            try stderrPrint(io, "vx --grammar fetch --save: set VOLUTE_CONFIG_PATH to enable config writes\n", .{});
            return error.NoConfigPath;
        };
        defer allocator.free(config_path);

        // Load current config (user override if present, else compile-time)
        const maybe_user_cfg = try lcfg.loadUserConfigOverride(io, allocator);
        defer if (maybe_user_cfg) |uc| lcfg.freeConfig(allocator, uc);
        const cfg_base = if (maybe_user_cfg) |uc| uc else lcfg.config;

        var new_grammars = std.ArrayList(lcfg.GrammarDef).empty;
        defer new_grammars.deinit(allocator);
        var replaced = false;
        for (cfg_base.grammars) |g| {
            if (std.mem.eql(u8, g.name, name)) {
                try new_grammars.append(allocator, .{ .name = name, .url = result.pinned_url, .hash = result.hash });
                replaced = true;
            } else {
                try new_grammars.append(allocator, g);
            }
        }
        if (!replaced) {
            try new_grammars.append(allocator, .{ .name = name, .url = result.pinned_url, .hash = result.hash });
        }
        const new_cfg = lcfg.Config{ .languages = cfg_base.languages, .grammars = new_grammars.items };

        // Ensure config dir exists
        if (std.fs.path.dirname(config_path)) |dir| {
            const mkdir = try std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", dir } });
            allocator.free(mkdir.stdout);
            allocator.free(mkdir.stderr);
        }
        try lcfg.saveConfigToFileIo(io, allocator, config_path, new_cfg, null);
        try out.print("{s} grammar '{s}' in {s}\n", .{ if (replaced) "Updated" else "Added", name, config_path });
        try out.flush();
    } else {
        // name-only mode: fetch registered grammars and verify hash
        const maybe_ucfg = try lcfg.loadUserConfigOverride(io, allocator);
        defer if (maybe_ucfg) |uc| lcfg.freeConfig(allocator, uc);
        const cfg = if (maybe_ucfg) |uc| uc else lcfg.config;

        var stdout_buf: [4096]u8 = undefined;
        var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const out = &stdout_w.interface;

        var ok: usize = 0;
        var failed: usize = 0;
        for (cfg.grammars) |g| {
            if (args.len > 0 and !containsStr(args, g.name)) continue;
            try out.print("Fetching '{s}'...\n", .{g.name});
            try out.flush();
            fetchAndVerifyGrammar(io, allocator, g, runtime_dir) catch |err| {
                try out.print("  FAIL {s}: {s}\n", .{ g.name, @errorName(err) });
                failed += 1;
                continue;
            };
            try out.print("  OK {s}\n", .{g.name});
            ok += 1;
        }
        try out.print("\nFetched: {d}, Failed: {d}\n", .{ ok, failed });
        try out.flush();
        if (failed > 0) return error.SomeFetchesFailed;
    }
}

fn fetchAndVerifyGrammar(
    io: std.Io,
    allocator: std.mem.Allocator,
    g: lcfg.GrammarDef,
    runtime_dir: []const u8,
) !void {
    const base_url = if (std.mem.lastIndexOfScalar(u8, g.url, '#')) |i| g.url[0..i] else g.url;
    const git_url = if (std.mem.startsWith(u8, base_url, "git+")) base_url["git+".len..] else base_url;
    const url_prefix = if (std.mem.startsWith(u8, base_url, "git+")) "git+" else "";

    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ runtime_dir, g.name });
    defer allocator.free(src_dir);

    const result = try gops.cloneAndHash(io, allocator, git_url, src_dir, url_prefix);
    defer allocator.free(result.pinned_url);
    defer allocator.free(result.hash);

    if (g.hash.len > 0 and !std.mem.eql(u8, result.hash, g.hash)) {
        try stderrPrint(io, "  HASH MISMATCH for '{s}':\n    expected: {s}\n    got:      {s}\n", .{ g.name, g.hash, result.hash });
        return error.HashMismatch;
    }
}

fn grammarUpdate(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, runtime_dir: []const u8) !void {
    const config_path = try grammarConfigWritePath(allocator) orelse {
        try stderrPrint(io, "vx --grammar update: set VOLUTE_CONFIG_PATH to enable config writes\n", .{});
        return error.NoConfigPath;
    };
    defer allocator.free(config_path);

    const maybe_ucfg = try lcfg.loadUserConfigOverride(io, allocator);
    defer if (maybe_ucfg) |uc| lcfg.freeConfig(allocator, uc);
    const cfg = if (maybe_ucfg) |uc| uc else lcfg.config;

    var new_grammars = std.ArrayList(lcfg.GrammarDef).empty;
    defer new_grammars.deinit(allocator);
    var updated: usize = 0;
    var failed: usize = 0;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    for (cfg.grammars) |g| {
        const should_update = args.len == 0 or containsStr(args, g.name);
        if (!should_update) { try new_grammars.append(allocator, g); continue; }

        try out.print("Updating '{s}'...\n", .{g.name});
        try out.flush();
        const base_url = if (std.mem.lastIndexOfScalar(u8, g.url, '#')) |i| g.url[0..i] else g.url;
        const git_url = if (std.mem.startsWith(u8, base_url, "git+")) base_url["git+".len..] else base_url;
        const url_prefix = if (std.mem.startsWith(u8, base_url, "git+")) "git+" else "";
        const src_dir = try std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ runtime_dir, g.name });
        defer allocator.free(src_dir);

        const result = gops.cloneAndHash(io, allocator, git_url, src_dir, url_prefix) catch |err| {
            try out.print("  FAIL {s}: {s}\n", .{ g.name, @errorName(err) });
            failed += 1;
            try new_grammars.append(allocator, g);
            continue;
        };
        defer allocator.free(result.pinned_url);
        defer allocator.free(result.hash);

        try new_grammars.append(allocator, .{
            .name = g.name,
            .url = try allocator.dupe(u8, result.pinned_url),
            .hash = try allocator.dupe(u8, result.hash),
        });
        try out.print("  OK {s}  hash: {s}\n", .{ g.name, result.hash });
        updated += 1;
    }

    const new_cfg = lcfg.Config{ .languages = cfg.languages, .grammars = new_grammars.items };
    if (updated > 0) {
        if (std.fs.path.dirname(config_path)) |dir| {
            const mkdir = try std.process.run(allocator, io, .{ .argv = &[_][]const u8{ "mkdir", "-p", dir } });
            allocator.free(mkdir.stdout); allocator.free(mkdir.stderr);
        }
        try lcfg.saveConfigToFileIo(io, allocator, config_path, new_cfg, null);
        try out.print("languages.zon updated at {s}\n", .{config_path});
    }
    try out.print("\nUpdated: {d}, Failed: {d}\n", .{ updated, failed });
    try out.flush();
    if (failed > 0) return error.SomeUpdatesFailed;
}

fn grammarBuild(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, runtime_dir: []const u8) !void {
    const cfg = lcfg.config;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const out = &stdout_w.interface;

    var built: usize = 0;
    var failed: usize = 0;
    for (cfg.grammars) |grammar| {
        if (args.len > 0 and !containsStr(args, grammar.name)) continue;
        gops.buildGrammarSo(io, allocator, grammar, runtime_dir) catch |err| {
            try out.print("  FAIL {s}: {s}\n", .{ grammar.name, @errorName(err) });
            failed += 1;
            continue;
        };
        try out.print("  OK {s}\n", .{grammar.name});
        built += 1;
    }
    try out.print("\nBuilt: {d}, Failed: {d}\n", .{ built, failed });
    try out.flush();
    if (failed > 0) return error.SomeBuildsFailed;
}

fn grammarRm(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8, runtime_dir: []const u8) !void {
    if (args.len == 0) {
        try stderrPrint(io, "vx --grammar rm: missing <name>\n", .{});
        return error.MissingArgument;
    }
    const name = args[0];

    const config_path = try grammarConfigWritePath(allocator) orelse {
        try stderrPrint(io, "vx --grammar rm: set VOLUTE_CONFIG_PATH to enable config writes\n", .{});
        return error.NoConfigPath;
    };
    defer allocator.free(config_path);

    const maybe_rm_cfg = try lcfg.loadUserConfigOverride(io, allocator);
    defer if (maybe_rm_cfg) |uc| lcfg.freeConfig(allocator, uc);
    const rm_cfg = if (maybe_rm_cfg) |uc| uc else lcfg.config;

    var found = false;
    var new_grammars = std.ArrayList(lcfg.GrammarDef).empty;
    defer new_grammars.deinit(allocator);
    for (rm_cfg.grammars) |g| {
        if (std.mem.eql(u8, g.name, name)) { found = true; } else { try new_grammars.append(allocator, g); }
    }
    var new_languages = std.ArrayList(lcfg.LanguageDef).empty;
    defer new_languages.deinit(allocator);
    for (rm_cfg.languages) |l| {
        if (!std.mem.eql(u8, l.name, name)) try new_languages.append(allocator, l);
    }

    if (!found) {
        try stderrPrint(io, "vx --grammar rm: '{s}' not found in config\n", .{name});
        return error.GrammarNotFound;
    }

    const new_cfg = lcfg.Config{ .languages = new_languages.items, .grammars = new_grammars.items };
    try lcfg.saveConfigToFileIo(io, allocator, config_path, new_cfg, null);

    gops.removeGrammarFiles(io, allocator, name, runtime_dir);

    var stdout_buf: [256]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    try stdout_w.interface.print("Removed grammar '{s}'.\n", .{name});
    try stdout_w.interface.flush();
}

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}


fn isBurstInsertKey(key: @import("vx/key.zig").Key) bool {
    if (key.mod.ctrl or key.mod.alt) return false;
    return key.getBytes().len > 0 or key.char() != null;
}

fn appendBurstInsertBytes(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: @import("vx/key.zig").Key) !void {
    const bytes = key.getBytes();
    if (bytes.len > 0) {
        try buf.appendSlice(allocator, bytes);
        return;
    }
    if (key.char()) |ch| {
        try buf.append(allocator, ch);
    }
}

fn readKeyNonBlocking(tty: *@import("vx/terminal.zig").Terminal) !?@import("vx/key.zig").Key {
    return tty.readKeyNonBlocking();
}

test "main: burst batching ignores modified shortcut keys" {
    const Key = @import("vx/key.zig").Key;

    const utf8_bytes = [_]u8{ 0xE5, 0xA5, 0xBD };

    try std.testing.expect(isBurstInsertKey(Key.init(.lower_a)));

    try std.testing.expect(isBurstInsertKey(Key.initUtf8(&utf8_bytes)));
    var unicode_alt_key = Key.initUtf8(&utf8_bytes);
    unicode_alt_key.mod.alt = true;
    try std.testing.expect(!isBurstInsertKey(unicode_alt_key));

    try std.testing.expect(!isBurstInsertKey(Key.initCtrl(.lower_a)));
    try std.testing.expect(!isBurstInsertKey(Key.initAlt(.lower_x)));
}

test {
    _ = @import("vx/buffer.zig");
    _ = @import("vx/editor.zig");
    _ = @import("vx/key.zig");
    _ = @import("vx/mode.zig");
    _ = @import("vx/position.zig");
    _ = @import("vx/selection.zig");
    _ = @import("vx/keymap.zig");
    _ = @import("vx/rope.zig");
    _ = @import("vx/syntax.zig");
    _ = @import("vx/view.zig");
    _ = @import("vx/text/storage.zig");
    _ = @import("vx/text/gap_buffer.zig");
    _ = @import("vx/text/tree_rope.zig");
    _ = @import("vx/text/factory.zig");
    _ = @import("codecs/encoding.zig");
    _ = @import("vx/line_ending.zig");
    _ = @import("simd.zig");
}
