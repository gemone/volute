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

    while (!editor.should_quit) {
        try @import("vx/view.zig").render(&editor);

        const key = editor.terminal.readKey() catch |err| {
            if (err == error.WouldBlock or err == error.SystemResources) continue;
            return err;
        };

        if (key) |k| {
            try editor.handleKey(k);
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
