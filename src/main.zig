const std = @import("std");
const Editor = @import("vx/editor.zig").Editor;
const terminal = @import("vx/terminal.zig");
const enc_mod = @import("codecs/encoding.zig");
const validation = @import("codecs/validation.zig");
const Dir = std.Io.Dir;

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
    /// Positional file arguments.
    files: []const []const u8 = &.{},

    /// True when batch (non-interactive) mode is requested.
    fn isBatch(self: CliArgs) bool {
        return self.output != null or self.in_place;
    }
};

/// Parse argv into a CliArgs.  Returns an error and prints usage on bad input.
fn parseArgs(
    allocator: std.mem.Allocator,
    args_iter: *std.process.Args.Iterator,
) !CliArgs {
    var src_enc: ?[]const u8 = null;
    var dst_enc: []const u8 = "utf-8";
    var output: ?[]const u8 = null;
    var in_place = false;
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
                std.debug.print("vx: {s} requires an encoding name\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--to")) {
            dst_enc = args_iter.next() orelse {
                std.debug.print("vx: {s} requires an encoding name\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            output = args_iter.next() orelse {
                std.debug.print("vx: {s} requires a file path\n", .{arg});
                return error.InvalidArgs;
            };
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--in-place")) {
            in_place = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            printUsage();
            return error.HelpRequested;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            std.debug.print("vx: unknown flag: {s}\n", .{arg});
            return error.InvalidArgs;
        } else {
            try files.append(allocator, arg);
        }
    }

    if (in_place and output != null) {
        std.debug.print("vx: -i/--in-place and -o/--output are mutually exclusive\n", .{});
        return error.InvalidArgs;
    }
    if (in_place and files.items.len == 0) {
        std.debug.print("vx: -i/--in-place requires at least one input file\n", .{});
        return error.InvalidArgs;
    }

    return CliArgs{
        .src_enc = src_enc,
        .dst_enc = dst_enc,
        .output = output,
        .in_place = in_place,
        .files = try allocator.dupe([]const u8, files.items),
    };
}

fn printUsage() void {
    std.debug.print(
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
    , .{});
}

// ── Batch transcoding ──────────────────────────────────────────────────────────

/// Read an entire file (or stdin when path is "-") into a new allocation.
fn readAll(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        // Read stdin via posix since we have no stat to know the size up front.
        var buf: std.ArrayList(u8) = .empty;
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const n = try std.posix.read(std.posix.STDIN_FILENO, &read_buf);
            if (n == 0) break;
            try buf.appendSlice(allocator, read_buf[0..n]);
        }
        return buf.toOwnedSlice(allocator);
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
        std.debug.print("{s}", .{error_msg});
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
            std.debug.print("vx: unknown source encoding: {s}\n", .{name});
            return error.UnknownEncoding;
        };
        break :blk e;
    } else null;

    const dst_enc = enc_mod.Encoding.fromName(args.dst_enc) orelse {
        std.debug.print("vx: unknown target encoding: {s}\n", .{args.dst_enc});
        return error.UnknownEncoding;
    };

    if (args.in_place) {
        // -i: transcode each input file back to itself.
        for (args.files) |path| {
            transcodeOne(allocator, io, path, path, src_forced, dst_enc) catch |err| {
                std.debug.print("vx: {s}: {s}\n", .{ path, @errorName(err) });
                return err;
            };
        }
    } else {
        // -o: exactly one input file (or stdin "-"), one output.
        const input = if (args.files.len > 0) args.files[0] else "-";
        if (args.files.len > 1) {
            std.debug.print("vx: -o accepts only one input file\n", .{});
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

    const args = parseArgs(allocator, &args_iter) catch |err| switch (err) {
        error.HelpRequested => return,
        else => std.process.exit(1),
    };
    defer allocator.free(args.files);

    // ── Batch (non-interactive) mode ──────────────────────────────────────────
    if (args.isBatch()) {
        runBatch(allocator, io, args) catch |err| {
            std.debug.print("vx: transcode failed: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        return;
    }

    // ── TUI mode ──────────────────────────────────────────────────────────────
    var editor = try Editor.init(allocator, io);
    defer editor.deinit();

    applyCursorStyleEnv(&editor);

    // Resolve optional forced source encoding for TUI opens.
    const forced_enc: ?enc_mod.Encoding = if (args.src_enc) |name| blk: {
        const e = enc_mod.Encoding.fromName(name) orelse {
            std.debug.print("vx: unknown encoding: {s}\n", .{name});
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
            std.debug.print("vx: error opening {s}: {any}\n", .{ path, err });
        };
    }

    if (editor.buffers.items.len == 0) {
        const buf = try @import("vx/buffer.zig").Buffer.init(allocator);
        try editor.buffers.append(allocator, buf);
    }

    try @import("vx/view.zig").render(&editor);
    while (!editor.should_quit) {
        const key = editor.terminal.readKey() catch |err| {
            if (err == error.WouldBlock or err == error.SystemResources) continue;
            return err;
        };

        if (key) |k| {
            try drainQueuedInput(&editor, k);
            if (!editor.should_quit) {
                try @import("vx/view.zig").render(&editor);
            }
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
            text_burst.clearRetainingCapacity();
            try appendBurstInsertBytes(editor.allocator, &text_burst, key);

            while (true) {
                const next = try readKeyNonBlocking(&editor.terminal);
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
        pending = try readKeyNonBlocking(&editor.terminal);
    }
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
    return tty.readKey() catch |err| switch (err) {
        error.WouldBlock, error.SystemResources => null,
        else => return err,
    };
}

test "main: burst batching ignores modified shortcut keys" {
    const Key = @import("vx/key.zig").Key;

    const utf8_bytes = [_]u8{ 0xE5, 0xA5, 0xBD };

    try std.testing.expect(isBurstInsertKey(Key.init(.lower_a)));
    try std.testing.expect(isBurstInsertKey(Key.initUtf8(&utf8_bytes)));
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
