const std = @import("std");
const Io = std.Io;
const Dir = std.Io.Dir;
const Position = @import("position.zig").Position;
const TextStore = @import("text/storage.zig").TextStore;
const createTextStore = @import("text/factory.zig").create;
const Strategy = @import("text/factory.zig").Strategy;
const utf8 = @import("utf8.zig");

pub const Buffer = struct {
    const Self = @This();
    const ADAPTIVE_TREE_OPEN_THRESHOLD: usize = 1 * 1024 * 1024;
    const ADAPTIVE_TREE_GROW_THRESHOLD: usize = 1 * 1024 * 1024;
    const ADAPTIVE_GAP_SHRINK_THRESHOLD: usize = 256 * 1024;
    const ADAPTIVE_LARGE_EDIT_THRESHOLD: usize = 64 * 1024;
    const ADAPTIVE_EDIT_LOCALITY_WINDOW: usize = 8 * 1024;
    const ADAPTIVE_DISPERSED_STREAK: usize = 6;
    const ADAPTIVE_LOCALIZED_STREAK: usize = 4;

    allocator: std.mem.Allocator,
    text: TextStore,
    backend_strategy: Strategy,
    path: ?[]const u8,
    dirty: bool,

    history: std.ArrayList(Edit),
    history_idx: usize,

    // Reusable buffer for getLine() output.
    // Returned slices are valid until the next getLine() call.
    line_buf: std.ArrayList(u8),

    last_edit_offset: ?usize,
    localized_edit_streak: usize,
    dispersed_edit_streak: usize,

    // Rendering cache: tracks which lines have been modified since last render
    render_cache: RenderCache,

    // Track if buffer has mutated since last undo operation
    mutated_since_undo: bool,

    const RenderCache = struct {
        /// Tracks line modification state for incremental rendering
        dirty_lines: std.ArrayList(bool),

        /// Mark all lines as dirty (full redraw needed)
        pub fn invalidateAll(self: *RenderCache) void {
            @memset(self.dirty_lines.items, true);
        }

        /// Mark specific line as dirty
        pub fn markDirty(self: *RenderCache, line: usize) void {
            if (line < self.dirty_lines.items.len) {
                self.dirty_lines.items[line] = true;
            }
        }

        pub fn markDirtyFrom(self: *RenderCache, line: usize) void {
            if (line >= self.dirty_lines.items.len) return;
            @memset(self.dirty_lines.items[line..], true);
        }

        /// Mark specific line as clean (already rendered)
        pub fn markClean(self: *RenderCache, line: usize) void {
            if (line < self.dirty_lines.items.len) {
                self.dirty_lines.items[line] = false;
            }
        }

        /// Check if line needs rendering
        pub fn isDirty(self: *const RenderCache, line: usize) bool {
            return if (line < self.dirty_lines.items.len)
                self.dirty_lines.items[line]
            else
                true;
        }

        /// Resize cache to match line count
        pub fn resize(self: *RenderCache, allocator: std.mem.Allocator, new_size: usize) !void {
            const old_len = self.dirty_lines.items.len;
            try self.dirty_lines.resize(allocator, new_size);
            // Mark new lines as dirty
            if (new_size > old_len) {
                @memset(self.dirty_lines.items[old_len..], true);
            }
        }
    };

    pub const Edit = struct {
        // Delta-based storage instead of full snapshots
        kind: enum { insert, delete },
        offset: usize,
        content: []const u8,
        cursor: Position,
        strategy: Strategy,
    };

    /// Initialize a new Buffer with auto-selected backend.
    pub fn init(allocator: std.mem.Allocator) !*Self {
        return initStrategy(allocator, .auto, null);
    }

    /// Initialize a new Buffer with explicit backend strategy.
    pub fn initStrategy(allocator: std.mem.Allocator, strategy: Strategy, data: ?[]const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        const resolved_strategy = resolveStrategy(strategy, if (data) |d| d.len else 0);
        const initial_lines = if (data) |d|
            std.mem.count(u8, d, "\n") + 1
        else
            1;

        self.* = .{
            .allocator = allocator,
            .text = try createTextStore(allocator, resolved_strategy, data),
            .backend_strategy = resolved_strategy,
            .path = null,
            .dirty = false,
            .history = .empty,
            .history_idx = 0,
            .line_buf = .empty,
            .last_edit_offset = null,
            .localized_edit_streak = 0,
            .dispersed_edit_streak = 0,
            .render_cache = .{
                .dirty_lines = try std.ArrayList(bool).initCapacity(allocator, initial_lines),
            },
            .mutated_since_undo = false,
        };
        // Initialize render cache with all lines marked dirty
        try self.render_cache.dirty_lines.resize(allocator, initial_lines);
        @memset(self.render_cache.dirty_lines.items, true);

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.text.deinit(self.allocator);
        self.clearHistory();
        self.history.deinit(self.allocator);
        if (self.path) |p| self.allocator.free(p);
        self.line_buf.deinit(self.allocator);
        self.render_cache.dirty_lines.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearHistory(self: *Self) void {
        for (self.history.items) |*edit| {
            self.allocator.free(edit.content);
        }
        self.history.clearRetainingCapacity();
        self.history_idx = 0;
    }

    pub fn pushUndo(self: *Self, cursor: Position) !void {
        // Discard any redo entries beyond current index
        while (self.history.items.len > self.history_idx) {
            const edit = self.history.pop() orelse break;
            self.allocator.free(edit.content);
        }

        // Store a full owned snapshot of the current text.
        const cloned_data = try borrowAllTextStore(&self.text, self.allocator);
        errdefer self.allocator.free(cloned_data);

        try self.history.append(self.allocator, .{
            .kind = .insert,
            .offset = 0,
            .content = cloned_data,
            .cursor = cursor,
            .strategy = self.backend_strategy,
        });
        self.history_idx = self.history.items.len;
        self.mutated_since_undo = false;
    }

    pub fn undo(self: *Self, cursor: Position) !?Position {
        if (self.history_idx == 0) return null;
        if (self.history_idx == self.history.items.len) {
            // Save current state before undoing
            const latest = self.history.items[self.history_idx - 1].content;
            const current_data = try borrowAllTextStore(&self.text, self.allocator);
            if (std.mem.eql(u8, current_data, latest)) {
                self.allocator.free(current_data);
            } else {
                errdefer self.allocator.free(current_data);
                try self.history.append(self.allocator, .{
                    .kind = .insert,
                    .offset = 0,
                    .content = current_data,
                    .cursor = cursor,
                    .strategy = self.backend_strategy,
                });
                self.history_idx = self.history.items.len;
            }
        }
        self.history_idx -= 1;
        const pos = try self.restoreSnapshot();
        self.mutated_since_undo = false;
        return pos;
    }

    pub fn redo(self: *Self) !?Position {
        if (self.history_idx >= self.history.items.len) return null;
        self.history_idx += 1;
        const pos = try self.restoreSnapshot();
        self.mutated_since_undo = false;
        return pos;
    }

    /// Borrow all text content from a TextStore as a byte array.
    /// Caller owns the returned memory and must free it with allocator.free().
    fn borrowAllTextStore(store: *const TextStore, allocator: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(allocator, @intCast(store.len()));
        errdefer buf.deinit(allocator);
        try store.writeToBuf(allocator, &buf);
        return buf.toOwnedSlice(allocator);
    }

    fn restoreSnapshot(self: *Self) !?Position {
        if (self.history_idx == 0) return null;
        const edit = &self.history.items[self.history_idx - 1];

        // Restore by replacing entire content
        self.text.deinit(self.allocator);
        self.text = try createTextStore(self.allocator, edit.strategy, edit.content);
        self.backend_strategy = edit.strategy;
        self.resetAdaptiveTracking();

        // Update render cache
        if (self.text.lineCount() != self.render_cache.dirty_lines.items.len) {
            self.render_cache.resize(self.allocator, self.text.lineCount()) catch return null;
        }
        self.render_cache.invalidateAll();
        self.dirty = true;

        return edit.cursor;
    }

    pub fn openFile(allocator: std.mem.Allocator, io: Io, path: []const u8) !*Self {
        const cwd = Dir.cwd();
        var file = cwd.openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                const scratch = try Self.initStrategy(allocator, .gap_buffer, null);
                errdefer scratch.deinit();
                scratch.path = try allocator.dupe(u8, path);
                return scratch;
            },
            else => return err,
        };
        defer file.close(io);

        const stat = try file.stat(io);
        const strategy = resolveStrategy(.auto, @intCast(stat.size));
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        const data = try reader.interface.readAlloc(allocator, @intCast(stat.size));
        defer allocator.free(data);

        const self = try Self.initStrategy(allocator, strategy, data);
        errdefer self.deinit();

        self.path = try allocator.dupe(u8, path);
        self.dirty = false;
        return self;
    }

    pub fn save(self: *Self, io: Io) !void {
        if (self.path == null) return error.NoPath;
        const path = self.path.?;
        const cwd = Dir.cwd();
        const existing_permissions = cwd.statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        var atomic = try cwd.createFileAtomic(io, path, .{
            .permissions = if (existing_permissions) |stat| stat.permissions else .default_file,
            .replace = true,
        });
        defer atomic.deinit(io);

        var write_buf: [4096]u8 = undefined;
        var writer = atomic.file.writerStreaming(io, &write_buf);
        try self.text.writeTo(&writer.interface);
        try writer.interface.flush();
        try atomic.file.sync(io);
        try atomic.replace(io);

        self.dirty = false;
    }

    pub fn lineCount(self: *Self) usize {
        return self.text.lineCount();
    }

    pub fn backend(self: *const Self) Strategy {
        return self.backend_strategy;
    }

    pub fn getLine(self: *Self, row: usize) ?[]const u8 {
        return self.text.getLine(row, &self.line_buf) catch return null;
    }

    pub fn lineLen(self: *Self, row: usize) usize {
        return if (self.getLine(row)) |l| l.len else 0;
    }

    pub fn prevColumn(self: *Self, row: usize, col: usize) usize {
        const line = self.getLine(row) orelse return 0;
        return utf8PrevBoundary(line, col);
    }

    pub fn nextColumn(self: *Self, row: usize, col: usize) usize {
        const line = self.getLine(row) orelse return 0;
        return utf8NextBoundary(line, col);
    }

    pub fn charSliceAt(self: *Self, pos: Position) ?[]const u8 {
        const line = self.getLine(pos.row) orelse return null;
        if (line.len == 0 or pos.col >= line.len) return null;

        const start = utf8FloorBoundary(line, pos.col);
        const end = utf8NextBoundary(line, start);
        if (end <= start) return null;
        return line[start..end];
    }

    pub fn insertCharAt(self: *Self, pos: Position, ch: u8) !void {
        const offset = (try self.text.posToOffset(pos.row, pos.col)) orelse return;
        try self.text.insert(offset, &[_]u8{ch});
        try self.finishMutation(offset, 1);
    }

    pub fn insertBytesAt(self: *Self, pos: Position, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const offset = (try self.text.posToOffset(pos.row, pos.col)) orelse return;
        try self.text.insert(offset, bytes);
        try self.finishMutation(offset, bytes.len);
    }

    pub fn deleteCharAt(self: *Self, pos: Position) !?u8 {
        if (pos.row == 0 and pos.col == 0) return null;
        const line = self.getLine(pos.row) orelse return null;

        if (pos.col == 0) {
            // Join with previous line: delete the newline at end of (row-1)
            const prev_line = self.getLine(pos.row - 1) orelse return null;
            const newline_off = (try self.text.posToOffset(pos.row - 1, prev_line.len)) orelse return null;
            try self.text.delete(newline_off, 1);
            try self.finishMutation(newline_off, 1);
            self.render_cache.markDirtyFrom(pos.row - 1);
            return '\n';
        }

        if (pos.col > line.len) return null;

        const delete_start = utf8PrevBoundary(line, pos.col);
        const delete_end = utf8NextBoundary(line, delete_start);
        if (delete_end <= delete_start) return null;

        const ch = line[delete_start];
        const offset = (try self.text.posToOffset(pos.row, delete_start)) orelse return null;
        try self.text.delete(offset, delete_end - delete_start);
        try self.finishMutation(offset, delete_end - delete_start);
        return ch;
    }

    pub fn insertNewlineAt(self: *Self, pos: Position) !void {
        const offset = (try self.text.posToOffset(pos.row, pos.col)) orelse return;
        try self.text.insert(offset, "\n");
        try self.finishMutation(offset, 1);
        self.render_cache.markDirtyFrom(pos.row);
    }

    pub fn deleteLines(self: *Self, start: usize, end: usize) !void {
        if (end <= start) return;
        const start_range = (try self.text.lineByteRange(start)) orelse return;
        const last_line = end - 1;
        const end_range = (try self.text.lineByteRange(last_line)) orelse return;
        // Include the newline at end of last_line
        const end_off = if (last_line + 1 < self.text.lineCount())
            end_range.end
        else
            self.text.len();
        try self.text.delete(start_range.start, end_off - start_range.start);
        if (self.text.len() == 0) {
            try self.text.insert(0, "");
        }
        try self.finishMutation(start_range.start, end_off - start_range.start);
        self.render_cache.markDirtyFrom(start);
    }

    pub fn insertLine(self: *Self, row: usize, text: []const u8) !void {
        const line_count = self.text.lineCount();
        if (row > line_count) return;

        if (row == line_count) {
            const offset = self.text.len();
            if (row > 0) {
                try self.text.insert(offset, "\n");
                try self.text.insert(offset + 1, text);
                try self.finishMutation(offset, text.len + 1);
                self.render_cache.markDirtyFrom(row);
            } else {
                try self.text.insert(offset, text);
                try self.finishMutation(offset, text.len);
                self.render_cache.markDirtyFrom(row);
            }
            return;
        }

        const offset = (try self.text.posToOffset(row, 0)) orelse return;
        try self.text.insert(offset, text);
        try self.text.insert(offset + text.len, "\n");
        try self.finishMutation(offset, text.len + 1);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn setLine(self: *Self, row: usize, text: []const u8) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        const line_len = if (row + 1 < self.text.lineCount())
            range.end - range.start - 1 // exclude the trailing newline
        else
            self.text.len() - range.start;
        try self.text.delete(range.start, line_len);
        try self.text.insert(range.start, text);
        try self.finishMutation(range.start, line_len + text.len);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn replaceCharAt(self: *Self, row: usize, col: usize, ch: u8) !void {
        try self.replaceBytesAt(row, col, &[_]u8{ch});
    }

    pub fn replaceBytesAt(self: *Self, row: usize, col: usize, bytes: []const u8) !void {
        const line = self.getLine(row) orelse return;
        if (line.len == 0 or col >= line.len) return;

        const start = utf8FloorBoundary(line, col);
        const end = utf8NextBoundary(line, start);
        if (end <= start) return;

        const offset = (try self.text.posToOffset(row, start)) orelse return;
        try self.text.delete(offset, end - start);
        try self.text.insert(offset, bytes);
        try self.finishMutation(offset, (end - start) + bytes.len);
    }

    pub fn replaceLinePrefix(self: *Self, row: usize, prefix: []const u8, rest_start: usize) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        if (rest_start > 0) {
            try self.text.delete(range.start, rest_start);
        }
        try self.text.insert(range.start, prefix);
        try self.finishMutation(range.start, rest_start + prefix.len);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn deleteLine(self: *Self, row: usize) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        const end_off = if (row + 1 < self.text.lineCount())
            range.end
        else
            self.text.len();
        try self.text.delete(range.start, end_off - range.start);
        if (self.text.len() == 0) {
            try self.text.insert(0, "");
        }
        try self.finishMutation(range.start, end_off - range.start);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn joinLines(self: *Self, row: usize, allocator: std.mem.Allocator) !void {
        _ = allocator;
        const line1 = self.getLine(row) orelse return;
        const line2 = self.getLine(row + 1) orelse return;
        const trimmed = std.mem.trimStart(u8, line2, " \t");

        // Delete the newline at end of line1
        const newline_off = (try self.text.posToOffset(row, line1.len)) orelse return;
        try self.text.delete(newline_off, 1);

        // Delete leading whitespace from line2 (now right after the former newline)
        const ws_count = line2.len - trimmed.len;
        if (ws_count > 0) {
            try self.text.delete(newline_off, ws_count);
        }

        // Insert a single space between the joined lines
        try self.text.insert(newline_off, " ");
        try self.finishMutation(newline_off, ws_count + 1);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn getAutoIndent(self: *Self, row: usize) []const u8 {
        const line = self.getLine(row) orelse return "";
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        return line[0..i];
    }

    pub fn clampPos(self: *Self, pos: Position) Position {
        const rows = self.text.lineCount();
        const row = @min(pos.row, if (rows > 0) rows - 1 else 0);
        const line = self.getLine(row) orelse "";
        const col = alignColumn(line, pos.col, false);
        return .{ .row = row, .col = col };
    }

    pub fn clampPosInsert(self: *Self, pos: Position) Position {
        const rows = self.text.lineCount();
        const row = @min(pos.row, if (rows > 0) rows - 1 else 0);
        const line = self.getLine(row) orelse "";
        const col = alignColumn(line, pos.col, true);
        return .{ .row = row, .col = col };
    }

    fn resolveStrategy(requested: Strategy, size_hint: usize) Strategy {
        return switch (requested) {
            .gap_buffer, .tree_rope => requested,
            .auto => if (size_hint >= ADAPTIVE_TREE_OPEN_THRESHOLD) .tree_rope else .gap_buffer,
        };
    }

    fn resetAdaptiveTracking(self: *Self) void {
        self.last_edit_offset = null;
        self.localized_edit_streak = 0;
        self.dispersed_edit_streak = 0;
    }

    fn recordEdit(self: *Self, offset: usize) void {
        if (self.last_edit_offset) |last| {
            const distance = if (offset > last) offset - last else last - offset;
            if (distance <= ADAPTIVE_EDIT_LOCALITY_WINDOW) {
                self.localized_edit_streak += 1;
                self.dispersed_edit_streak = 0;
            } else {
                self.dispersed_edit_streak += 1;
                self.localized_edit_streak = 0;
            }
        } else {
            self.localized_edit_streak = 1;
            self.dispersed_edit_streak = 0;
        }
        self.last_edit_offset = offset;
    }

    fn finishMutation(self: *Self, offset: usize, magnitude: usize) !void {
        // Any real mutation after undo/redo invalidates future redo states.
        while (self.history.items.len > self.history_idx) {
            const edit = self.history.pop() orelse break;
            self.allocator.free(edit.content);
        }

        self.recordEdit(offset);
        try self.adaptBackend(offset, magnitude);
        self.dirty = true;
        self.mutated_since_undo = true;

        // Mark affected lines as dirty for incremental rendering
        const pos = self.text.offsetToPos(offset) catch return;
        self.render_cache.markDirty(pos.row);
        // Also mark next line as dirty if edit spans multiple lines
        if (magnitude > 0) {
            const end_pos = self.text.offsetToPos(offset + magnitude) catch return;
            if (end_pos.row > pos.row) {
                self.render_cache.markDirty(end_pos.row);
            }
        }
    }

    fn adaptBackend(self: *Self, offset: usize, magnitude: usize) !void {
        _ = offset;
        const len = self.text.len();
        const target = switch (self.backend_strategy) {
            .gap_buffer => if (len >= ADAPTIVE_TREE_GROW_THRESHOLD and
                (magnitude >= ADAPTIVE_LARGE_EDIT_THRESHOLD or self.dispersed_edit_streak >= ADAPTIVE_DISPERSED_STREAK))
                Strategy.tree_rope
            else
                Strategy.gap_buffer,
            .tree_rope => if (len <= ADAPTIVE_GAP_SHRINK_THRESHOLD and
                (magnitude >= ADAPTIVE_LARGE_EDIT_THRESHOLD or self.localized_edit_streak >= ADAPTIVE_LOCALIZED_STREAK))
                Strategy.gap_buffer
            else
                Strategy.tree_rope,
            .auto => unreachable,
        };
        try self.ensureBackendStrategy(target);
    }

    fn ensureBackendStrategy(self: *Self, target: Strategy) !void {
        if (target == self.backend_strategy) return;

        var migrated = try createTextStore(self.allocator, target, null);
        errdefer migrated.deinit(self.allocator);

        var chunk: [64 * 1024]u8 = undefined;
        var offset: usize = 0;
        while (offset < self.text.len()) {
            const read_len = try self.text.readChunk(offset, &chunk);
            if (read_len == 0) break;
            try migrated.insert(offset, chunk[0..read_len]);
            offset += read_len;
        }
        _ = migrated.lineCount();

        const previous = self.text;
        self.text = migrated;
        self.backend_strategy = target;
        previous.deinit(self.allocator);
        self.resetAdaptiveTracking();
    }
};

fn utf8FloorBoundary(line: []const u8, col: usize) usize {
    return utf8.boundary(line).floor(col);
}

fn utf8PrevBoundary(line: []const u8, col: usize) usize {
    return utf8.boundary(line).prev(col);
}

fn utf8NextBoundary(line: []const u8, col: usize) usize {
    return utf8.boundary(line).next(col);
}

fn alignColumn(line: []const u8, col: usize, allow_eol: bool) usize {
    return utf8.boundary(line).alignColumn(col, allow_eol);
}

test "Buffer: init with auto strategy" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.text.len());
    try std.testing.expectEqual(@as(usize, 1), buf.text.lineCount());
    try std.testing.expectEqual(Strategy.gap_buffer, buf.backend());
}

test "Buffer: init with GapBuffer strategy" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 5), buf.text.len());
    try std.testing.expectEqual(@as(usize, 1), buf.text.lineCount());
}

test "Buffer: empty buffer insertion" {
    const allocator = std.testing.allocator;

    // Create empty buffer (mimics scratch buffer)
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(usize, 0), buf.text.len());
    try std.testing.expectEqual(@as(usize, 1), buf.text.lineCount());

    // Try to insert a character at position 0,0
    const pos = Position{ .row = 0, .col = 0 };
    try buf.insertCharAt(pos, 'h');

    // Verify it worked
    try std.testing.expectEqual(@as(usize, 1), buf.text.len());

    const line = buf.getLine(0) orelse {
        std.debug.print("ERROR: getLine(0) returned null!\n", .{});
        return error.TestFailed;
    };

    if (line.len != 1 or line[0] != 'h') {
        std.debug.print("ERROR: Expected 'h', got '{any}'\n", .{line});
        return error.TestFailed;
    }
}

test "Buffer: clamp positions snap to UTF-8 boundaries" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "你a");
    defer buf.deinit();

    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, buf.clampPos(.{ .row = 0, .col = 1 }));
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, buf.clampPosInsert(.{ .row = 0, .col = 1 }));
    try std.testing.expectEqual(Position{ .row = 0, .col = 3 }, buf.clampPos(.{ .row = 0, .col = 4 }));
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, buf.clampPosInsert(.{ .row = 0, .col = 4 }));
}

test "Buffer: large input without corruption" {
    const allocator = std.testing.allocator;

    // Create empty buffer
    var buf = try Buffer.init(allocator);
    defer buf.deinit();

    // Insert many characters (simulates rapid typing)
    var pos = Position{ .row = 0, .col = 0 };
    const test_text = "The quick brown fox jumps over the lazy dog. ";

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        for (test_text) |c| {
            try buf.insertCharAt(pos, c);
            pos.col += 1;
        }
    }

    // Verify no corruption: total length should be correct
    const expected_len = test_text.len * 50;
    try std.testing.expectEqual(expected_len, buf.text.len());

    // Verify content is readable
    const line = buf.getLine(0) orelse {
        std.debug.print("ERROR: getLine(0) returned null after large insert!\n", .{});
        return error.TestFailed;
    };

    // Line should be long but not corrupted
    try std.testing.expectEqual(expected_len, line.len);

    // Verify content starts with expected text
    for (test_text, 0..) |c, j| {
        if (j >= line.len) break;
        try std.testing.expectEqual(c, line[j]);
    }
}

test "Buffer: init with TreeRope strategy" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .tree_rope, "world");
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 5), buf.text.len());
    try std.testing.expectEqual(@as(usize, 1), buf.text.lineCount());
    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());
}

test "Buffer: auto strategy prefers TreeRope for large initial data" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, Buffer.ADAPTIVE_TREE_OPEN_THRESHOLD + 128);
    defer allocator.free(data);
    @memset(data, 'x');

    var buf = try Buffer.initStrategy(allocator, .auto, data);
    defer buf.deinit();

    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());
    try std.testing.expectEqual(data.len, buf.text.len());
}

test "Buffer: adaptive migration preserves undo and redo snapshots" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "seed");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });

    const large_text = try allocator.alloc(u8, Buffer.ADAPTIVE_TREE_GROW_THRESHOLD + 128);
    defer allocator.free(large_text);
    @memset(large_text, 'z');

    try buf.text.insert(buf.text.len(), large_text);
    try buf.finishMutation(4, large_text.len);
    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());

    try buf.pushUndo(.{ .row = 0, .col = buf.text.len() });

    const undo_pos = (try buf.undo(.{ .row = 0, .col = 4 + large_text.len })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, undo_pos);
    try std.testing.expectEqual(Strategy.gap_buffer, buf.backend());
    try std.testing.expectEqualStrings("seed", buf.getLine(0).?);

    const redo_pos = (try buf.redo()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 + large_text.len }, redo_pos);
    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());
    try std.testing.expectEqual(@as(usize, 4 + large_text.len), buf.text.len());
}

test "Buffer: large tree-rope undo remains available above old snapshot limit" {
    const allocator = std.testing.allocator;
    const size = 9 * 1024 * 1024;
    const data = try allocator.alloc(u8, size);
    defer allocator.free(data);
    @memset(data, 'a');

    var buf = try Buffer.initStrategy(allocator, .auto, data);
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'b');
    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());
    try std.testing.expectEqual(@as(usize, size + 1), buf.text.len());

    const undo_pos = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, undo_pos);
    try std.testing.expectEqual(data.len, buf.text.len());
    try std.testing.expectEqual(@as(u8, 'a'), buf.getLine(0).?[0]);
}

test "Buffer: open and save large file keeps adaptive backend" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const large_text = try allocator.alloc(u8, Buffer.ADAPTIVE_TREE_OPEN_THRESHOLD + 64);
    defer allocator.free(large_text);
    @memset(large_text, 'a');

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "large.txt" });
    defer allocator.free(path);

    {
        const cwd = Dir.cwd();
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(io, &write_buf);
        try writer.interface.writeAll(large_text);
        try writer.interface.flush();
    }

    var buf = try Buffer.openFile(allocator, io, path);
    defer buf.deinit();

    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());
    try std.testing.expectEqual(large_text.len, buf.text.len());

    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'b');
    try buf.save(io);

    const cwd = Dir.cwd();
    var read_file = try cwd.openFile(io, path, .{});
    defer read_file.close(io);
    const stat = try read_file.stat(io);
    var read_buf: [4096]u8 = undefined;
    var reader = read_file.reader(io, &read_buf);
    const written = try reader.interface.readAlloc(allocator, @intCast(stat.size));
    defer allocator.free(written);
    try std.testing.expectEqual(@as(usize, large_text.len + 1), written.len);
    try std.testing.expectEqual(@as(u8, 'b'), written[0]);
}

test "Buffer: save does not use legacy predictable temp path" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "legacy-temp.txt" });
    defer allocator.free(path);
    const legacy_tmp_path = try std.fmt.allocPrint(allocator, "{s}.volute-save.tmp", .{path});
    defer allocator.free(legacy_tmp_path);

    const cwd = Dir.cwd();
    {
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);
        var write_buf: [64]u8 = undefined;
        var writer = file.writerStreaming(io, &write_buf);
        try writer.interface.writeAll("old");
        try writer.interface.flush();
    }
    {
        var file = try cwd.createFile(io, legacy_tmp_path, .{ .truncate = true });
        defer file.close(io);
        var write_buf: [64]u8 = undefined;
        var writer = file.writerStreaming(io, &write_buf);
        try writer.interface.writeAll("sentinel");
        try writer.interface.flush();
    }

    var buf = try Buffer.openFile(allocator, io, path);
    defer buf.deinit();
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'N');
    try buf.save(io);

    var legacy_file = try cwd.openFile(io, legacy_tmp_path, .{});
    defer legacy_file.close(io);
    const legacy_stat = try legacy_file.stat(io);
    var legacy_read_buf: [64]u8 = undefined;
    var legacy_reader = legacy_file.reader(io, &legacy_read_buf);
    const legacy_contents = try legacy_reader.interface.readAlloc(allocator, @intCast(legacy_stat.size));
    defer allocator.free(legacy_contents);
    try std.testing.expectEqualStrings("sentinel", legacy_contents);
}

fn insertByteOwned(allocator: std.mem.Allocator, src: []u8, idx: usize, byte: u8) ![]u8 {
    const clamped = @min(idx, src.len);
    const out = try allocator.alloc(u8, src.len + 1);
    if (clamped > 0) @memcpy(out[0..clamped], src[0..clamped]);
    out[clamped] = byte;
    if (clamped < src.len) @memcpy(out[clamped + 1 ..], src[clamped..]);
    return out;
}

fn expectSingleLineBytes(buf: *Buffer, expected: []const u8) !void {
    const line = buf.getLine(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected.len, line.len);
    try std.testing.expectEqualSlices(u8, expected, line);
}

fn expectBufferText(buf: *Buffer, expected: []const u8) !void {
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(buf.allocator);
    try buf.text.writeToBuf(buf.allocator, &actual);
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn runRepeatedHeadMiddleTailInsertionScenario(strategy: Strategy) !void {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, strategy, "");
    defer buf.deinit();

    var expected = try allocator.alloc(u8, 0);
    defer allocator.free(expected);

    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const head: u8 = @as(u8, @intCast('A' + @as(i32, @intCast(i % 26))));
        const middle: u8 = @as(u8, @intCast('0' + @as(i32, @intCast(i % 10))));
        const tail: u8 = @as(u8, @intCast('a' + @as(i32, @intCast(i % 26))));

        try buf.insertCharAt(.{ .row = 0, .col = 0 }, head);
        var next = try insertByteOwned(allocator, expected, 0, head);
        allocator.free(expected);
        expected = next;

        const mid_col = expected.len / 2;
        try buf.insertCharAt(.{ .row = 0, .col = mid_col }, middle);
        next = try insertByteOwned(allocator, expected, mid_col, middle);
        allocator.free(expected);
        expected = next;

        const tail_col = expected.len;
        try buf.insertCharAt(.{ .row = 0, .col = tail_col }, tail);
        next = try insertByteOwned(allocator, expected, tail_col, tail);
        allocator.free(expected);
        expected = next;
    }

    const line = buf.getLine(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected.len, buf.text.len());
    try std.testing.expectEqualStrings(expected, line);
}

test "Buffer: repeated head/middle/tail insertions are stable (GapBuffer)" {
    try runRepeatedHeadMiddleTailInsertionScenario(.gap_buffer);
}

test "Buffer: repeated head/middle/tail insertions are stable (TreeRope)" {
    try runRepeatedHeadMiddleTailInsertionScenario(.tree_rope);
}

fn runUtf8InsertAndPersistScenario(strategy: Strategy) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "utf8-roundtrip.txt" });
    defer allocator.free(path);

    var buf = try Buffer.initStrategy(allocator, strategy, "");
    defer buf.deinit();
    buf.path = try allocator.dupe(u8, path);

    const omega = [_]u8{ 0xCE, 0xA9 };
    const smile = [_]u8{ 0xF0, 0x9F, 0x98, 0x80 };
    const expected = [_]u8{ 0xCE, 0xA9, '!', 0xF0, 0x9F, 0x98, 0x80 };

    try buf.insertBytesAt(.{ .row = 0, .col = 0 }, &omega);
    try buf.insertCharAt(.{ .row = 0, .col = omega.len }, '!');
    try buf.insertBytesAt(.{ .row = 0, .col = omega.len + 1 }, &smile);

    try expectSingleLineBytes(buf, &expected);
    try std.testing.expectEqual(@as(?usize, expected.len), try buf.text.posToOffset(0, expected.len));
    try std.testing.expectEqual(Position{ .row = 0, .col = expected.len }, try buf.text.offsetToPos(expected.len));

    try buf.save(io);

    var reopened = try Buffer.openFile(allocator, io, path);
    defer reopened.deinit();
    try expectSingleLineBytes(reopened, &expected);
}

test "Buffer: UTF-8 byte insertions persist after save and reopen (GapBuffer)" {
    try runUtf8InsertAndPersistScenario(.gap_buffer);
}

test "Buffer: UTF-8 byte insertions persist after save and reopen (TreeRope)" {
    try runUtf8InsertAndPersistScenario(.tree_rope);
}

test "Buffer: insertLine inserts at the target row and appends at EOF" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "one\ntwo\nthree");
    defer buf.deinit();

    try buf.insertLine(1, "mid");
    try std.testing.expectEqualStrings("one", buf.getLine(0).?);
    try std.testing.expectEqualStrings("mid", buf.getLine(1).?);
    try std.testing.expectEqualStrings("two", buf.getLine(2).?);
    try std.testing.expectEqualStrings("three", buf.getLine(3).?);

    try buf.insertLine(0, "head");
    try std.testing.expectEqualStrings("head", buf.getLine(0).?);
    try std.testing.expectEqualStrings("one", buf.getLine(1).?);

    try buf.insertLine(buf.lineCount(), "tail");
    try std.testing.expectEqualStrings("tail", buf.getLine(buf.lineCount() - 1).?);
}

test "Buffer: insertLine preserves following content when opening below in middle" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta\ngamma");
    defer buf.deinit();

    try buf.insertLine(1, "");

    try expectBufferText(buf, "alpha\n\nbeta\ngamma");
}

test "Buffer: newline insertion invalidates following rendered lines" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta\ngamma");
    defer buf.deinit();

    buf.render_cache.invalidateAll();
    buf.render_cache.markClean(0);
    buf.render_cache.markClean(1);
    buf.render_cache.markClean(2);

    try buf.insertNewlineAt(.{ .row = 0, .col = 5 });

    try std.testing.expect(buf.render_cache.isDirty(0));
    try std.testing.expect(buf.render_cache.isDirty(1));
    try std.testing.expect(buf.render_cache.isDirty(2));
}

test "Buffer: deleteCharAt removes an entire UTF-8 sequence from an interior byte position" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, null);
    defer buf.deinit();

    const omega = [_]u8{ 0xCE, 0xA9 };
    try buf.insertBytesAt(.{ .row = 0, .col = 0 }, &omega);
    _ = try buf.deleteCharAt(.{ .row = 0, .col = 1 });

    try expectSingleLineBytes(buf, "");
}

test "Buffer: deleteLine propagates mutation errors" {
    const allocator = std.testing.allocator;
    const first_line_len = Buffer.ADAPTIVE_LARGE_EDIT_THRESHOLD + 16;
    const second_line_len = Buffer.ADAPTIVE_TREE_GROW_THRESHOLD + 32;
    const total_len = first_line_len + 1 + second_line_len;
    const data = try allocator.alloc(u8, total_len);
    defer allocator.free(data);
    @memset(data, 'a');
    data[first_line_len] = '\n';

    var failing_state = std.testing.FailingAllocator.init(allocator, .{});
    var buf = try Buffer.initStrategy(failing_state.allocator(), .gap_buffer, data);
    defer buf.deinit();

    failing_state.fail_index = failing_state.alloc_index;
    try std.testing.expectError(error.OutOfMemory, buf.deleteLine(0));
}

test "Buffer: replaceBytesAt swaps a full UTF-8 sequence" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, null);
    defer buf.deinit();

    const omega = [_]u8{ 0xCE, 0xA9 };
    const han = [_]u8{ 0xE6, 0xB1, 0x89 };
    try buf.insertBytesAt(.{ .row = 0, .col = 0 }, &omega);
    try buf.replaceBytesAt(0, 0, &han);

    try expectSingleLineBytes(buf, &han);
}

test "Buffer: mixed ASCII and Chinese text preserves UTF-8 cursor boundaries" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "A你B好");
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 1), buf.nextColumn(0, 0));
    try std.testing.expectEqual(@as(usize, 4), buf.nextColumn(0, 1));
    try std.testing.expectEqual(@as(usize, 4), buf.nextColumn(0, 2));
    try std.testing.expectEqual(@as(usize, 4), buf.nextColumn(0, 3));
    try std.testing.expectEqual(@as(usize, 5), buf.nextColumn(0, 4));
    try std.testing.expectEqual(@as(usize, 8), buf.nextColumn(0, 5));

    try std.testing.expectEqual(@as(usize, 0), buf.prevColumn(0, 1));
    try std.testing.expectEqual(@as(usize, 1), buf.prevColumn(0, 2));
    try std.testing.expectEqual(@as(usize, 1), buf.prevColumn(0, 3));
    try std.testing.expectEqual(@as(usize, 1), buf.prevColumn(0, 4));
    try std.testing.expectEqual(@as(usize, 4), buf.prevColumn(0, 5));
    try std.testing.expectEqual(@as(usize, 5), buf.prevColumn(0, 8));
}

test "Buffer: charSliceAt returns a full Chinese sequence from an interior byte position" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "A你B");
    defer buf.deinit();

    try std.testing.expectEqualStrings("你", buf.charSliceAt(.{ .row = 0, .col = 2 }).?);
    try std.testing.expectEqualStrings("B", buf.charSliceAt(.{ .row = 0, .col = 4 }).?);
}

test "Buffer: daily workflow persists after save and reopen" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "daily-workflow.txt" });
    defer allocator.free(path);

    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta");
    defer buf.deinit();
    buf.path = try allocator.dupe(u8, path);

    try buf.insertCharAt(.{ .row = 0, .col = 5 }, '!');
    try buf.insertNewlineAt(.{ .row = 1, .col = 4 });
    try buf.insertCharAt(.{ .row = 2, .col = 0 }, 'B');
    try buf.joinLines(1, allocator);
    try buf.insertCharAt(.{ .row = 1, .col = 0 }, '*');
    try buf.save(io);

    const expected = "alpha!\n*beta B";

    var reopened = try Buffer.openFile(allocator, io, path);
    defer reopened.deinit();
    const line0 = reopened.getLine(0) orelse return error.TestUnexpectedResult;
    const line0_copy = try allocator.dupe(u8, line0);
    defer allocator.free(line0_copy);
    const line1 = reopened.getLine(1) orelse return error.TestUnexpectedResult;
    var merged = try std.ArrayList(u8).initCapacity(allocator, line0.len + line1.len + 1);
    defer merged.deinit(allocator);
    try merged.appendSlice(allocator, line0_copy);
    try merged.append(allocator, '\n');
    try merged.appendSlice(allocator, line1);
    try std.testing.expectEqualStrings(expected, merged.items);
}

test "Buffer: insertLine save and reopen preserves original next line" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "insert-line-roundtrip.txt" });
    defer allocator.free(path);

    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta\ngamma");
    defer buf.deinit();
    buf.path = try allocator.dupe(u8, path);

    try buf.insertLine(1, "");
    try buf.insertCharAt(.{ .row = 1, .col = 0 }, '*');
    try buf.save(io);

    var reopened = try Buffer.openFile(allocator, io, path);
    defer reopened.deinit();
    try expectBufferText(reopened, "alpha\n*\nbeta\ngamma");
}

test "Buffer: large repeated inserts persist after save and reopen" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(allocator, &.{ ".zig-cache/tmp", &tmp.sub_path, "large-repeated.txt" });
    defer allocator.free(path);

    const base = try allocator.alloc(u8, 2 * 1024 * 1024);
    defer allocator.free(base);
    @memset(base, 'x');

    var file_buf = try Buffer.initStrategy(allocator, .auto, base);
    defer file_buf.deinit();
    file_buf.path = try allocator.dupe(u8, path);

    var expected = try allocator.dupe(u8, base);
    defer allocator.free(expected);

    var i: usize = 0;
    while (i < 32) : (i += 1) {
        try file_buf.insertCharAt(.{ .row = 0, .col = 0 }, 'H');
        var next = try insertByteOwned(allocator, expected, 0, 'H');
        allocator.free(expected);
        expected = next;

        const mid = expected.len / 2;
        try file_buf.insertCharAt(.{ .row = 0, .col = mid }, 'M');
        next = try insertByteOwned(allocator, expected, mid, 'M');
        allocator.free(expected);
        expected = next;

        const tail = expected.len;
        try file_buf.insertCharAt(.{ .row = 0, .col = tail }, 'T');
        next = try insertByteOwned(allocator, expected, tail, 'T');
        allocator.free(expected);
        expected = next;
    }

    try file_buf.save(io);

    var reopened = try Buffer.openFile(allocator, io, path);
    defer reopened.deinit();
    var actual = try std.ArrayList(u8).initCapacity(allocator, expected.len + 16);
    defer actual.deinit(allocator);
    try reopened.text.writeToBuf(allocator, &actual);
    try std.testing.expectEqual(expected.len, actual.items.len);
    try std.testing.expectEqualStrings(expected, actual.items);
}

test "Buffer: single-edit undo then redo restores content" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);

    _ = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", buf.getLine(0).?);

    _ = (try buf.redo()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);
}

test "Buffer: gap undo after multiple edits restores each snapshot" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Y');
    try std.testing.expectEqualStrings("XYhello", buf.getLine(0).?);

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);

    _ = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", buf.getLine(0).?);
}

test "Buffer: rope undo then redo restores snapshots" {
    const allocator = std.testing.allocator;
    const initial = try allocator.alloc(u8, Buffer.ADAPTIVE_TREE_OPEN_THRESHOLD + 128);
    defer allocator.free(initial);
    @memset(initial, 'r');

    var buf = try Buffer.initStrategy(allocator, .tree_rope, initial);
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'Z');
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Q');

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try std.testing.expect(buf.getLine(0).?.len > 0);
    try std.testing.expectEqual(@as(u8, 'Z'), buf.getLine(0).?[0]);

    _ = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 'r'), buf.getLine(0).?[0]);

    _ = (try buf.redo()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 'Z'), buf.getLine(0).?[0]);
}

test "Buffer: edit after undo branches history and clears redo" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Y');
    try std.testing.expectEqualStrings("XYhello", buf.getLine(0).?);

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);

    // Branch history from the undone state.
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Z');
    try std.testing.expectEqualStrings("XZhello", buf.getLine(0).?);

    // Redo of the old branch must be gone.
    try std.testing.expect((try buf.redo()) == null);

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);
}

test "Buffer: undo captures current cursor for redo snapshot" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');

    const undo_pos = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, undo_pos);
    const redo_pos = (try buf.redo()) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, redo_pos);
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);
}
