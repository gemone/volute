const std = @import("std");
const Position = @import("position.zig").Position;
const Selection = @import("selection.zig").Selection;

pub const Rect = struct {
    top: usize = 0,
    left: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
};

pub const SplitDir = enum { horizontal, vertical };

pub const Window = struct {
    buf_index: usize = 0,
    cursor: Position = .{},
    scroll: usize = 0,
    scroll_col: usize = 0,
    selection: ?Selection = null,
    selection_linewise: bool = false,
    rect: Rect = .{},
    split_dir: ?SplitDir = null,

    pub fn resetView(self: *Window) void {
        self.cursor = .{};
        self.scroll = 0;
        self.scroll_col = 0;
    }
};

pub const Tab = struct {
    allocator: std.mem.Allocator,
    windows: std.ArrayList(Window) = .empty,
    active_window: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Tab {
        return .{ .allocator = allocator, .windows = .empty };
    }

    pub fn deinit(self: *Tab) void {
        self.windows.deinit(self.allocator);
    }

    pub fn activeWindow(self: *Tab) ?*Window {
        if (self.active_window < self.windows.items.len)
            return &self.windows.items[self.active_window];
        return null;
    }
};

pub const FloatBuf = struct {
    buf_index: usize,
    title: []const u8,
    rect: Rect,
    cursor: Position = .{},
    scroll: usize = 0,
    focused: bool = false,
};
