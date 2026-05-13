const std = @import("std");
const Editor = @import("vx/editor.zig").Editor;
const terminal = @import("vx/terminal.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var editor = try Editor.init(allocator, io);
    defer editor.deinit();

    applyCursorStyleEnv(&editor);

    var args_iter = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_iter.next();
    while (args_iter.next()) |path| {
        editor.openFile(path) catch |err| {
            std.debug.print("Error opening {s}: {any}\n", .{ path, err });
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
}
