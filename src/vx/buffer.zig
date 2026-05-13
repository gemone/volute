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
    const MAX_HISTORY_DEPTH: usize = 50;
    const MAX_HISTORY_BYTES: usize = 1 * 1024 * 1024;
    allocator: std.mem.Allocator,
    text: TextStore,
    backend_strategy: Strategy,
    path: ?[]const u8,
    dirty: bool,

    history_root: *HistoryNode,
    history_current: *HistoryNode,
    pending_history: ?PendingHistory,

    // Reusable buffer for getLine() output.
    // Returned slices are valid until the next getLine() call.
    line_buf: std.ArrayList(u8),

    last_edit_offset: ?usize,
    localized_edit_streak: usize,
    dispersed_edit_streak: usize,

    // Rendering cache: tracks which lines have been modified since last render
    render_cache: RenderCache,

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

    const Delta = struct {
        offset: usize,
        deleted: []u8,
        inserted: []u8,
    };

    const HistoryNode = struct {
        parent: ?*HistoryNode,
        children: std.ArrayList(*HistoryNode),
        preferred_child: ?*HistoryNode,
        deltas: std.ArrayList(Delta),
        cursor_before: Position,
        cursor_after: Position,
        before_strategy: Strategy,
        after_strategy: Strategy,
        depth: usize,
    };

    const PendingHistory = struct {
        parent: *HistoryNode,
        deltas: std.ArrayList(Delta),
        cursor_before: Position,
        before_strategy: Strategy,
    };

    const MutationState = struct {
        strategy: Strategy,
        dirty: bool,
        last_edit_offset: ?usize,
        localized_edit_streak: usize,
        dispersed_edit_streak: usize,
        render_cache_len: usize,
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
            .history_root = undefined,
            .history_current = undefined,
            .pending_history = null,
            .line_buf = .empty,
            .last_edit_offset = null,
            .localized_edit_streak = 0,
            .dispersed_edit_streak = 0,
            .render_cache = .{
                .dirty_lines = try std.ArrayList(bool).initCapacity(allocator, initial_lines),
            },
        };
        // Initialize render cache with all lines marked dirty
        try self.render_cache.dirty_lines.resize(allocator, initial_lines);
        @memset(self.render_cache.dirty_lines.items, true);

        self.history_root = try self.createHistoryRoot(resolved_strategy);
        self.history_current = self.history_root;

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.text.deinit(self.allocator);
        self.clearHistory();
        if (self.path) |p| self.allocator.free(p);
        self.line_buf.deinit(self.allocator);
        self.render_cache.dirty_lines.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn clearHistory(self: *Self) void {
        if (self.pending_history) |*pending| {
            self.deinitDeltaList(&pending.deltas);
            self.pending_history = null;
        }
        self.destroyHistoryNode(self.history_root);
    }

    fn createHistoryRoot(self: *Self, strategy: Strategy) !*HistoryNode {
        const node = try self.allocator.create(HistoryNode);
        node.* = .{
            .parent = null,
            .children = .empty,
            .preferred_child = null,
            .deltas = .empty,
            .cursor_before = .{},
            .cursor_after = .{},
            .before_strategy = strategy,
            .after_strategy = strategy,
            .depth = 0,
        };
        return node;
    }

    fn destroyHistoryNode(self: *Self, node: *HistoryNode) void {
        for (node.children.items) |child| {
            self.destroyHistoryNode(child);
        }
        node.children.deinit(self.allocator);
        self.deinitDeltaList(&node.deltas);
        self.allocator.destroy(node);
    }

    fn deinitDeltaList(self: *Self, deltas: *std.ArrayList(Delta)) void {
        for (deltas.items) |delta| {
            self.allocator.free(delta.deleted);
            self.allocator.free(delta.inserted);
        }
        deltas.deinit(self.allocator);
    }

    pub fn pushUndo(self: *Self, cursor: Position) !void {
        try self.finalizePendingHistory(cursor);
        self.pending_history = .{
            .parent = self.history_current,
            .deltas = .empty,
            .cursor_before = cursor,
            .before_strategy = self.backend_strategy,
        };
    }

    pub fn undo(self: *Self, cursor: Position) !?Position {
        try self.finalizePendingHistory(cursor);
        if (self.history_current == self.history_root) return null;

        const node = self.history_current;
        const parent = node.parent orelse return null;
        parent.preferred_child = node;
        try self.applyHistoryNodeReverse(node);
        self.history_current = parent;
        return node.cursor_before;
    }

    pub fn redo(self: *Self, cursor: Position) !?Position {
        try self.finalizePendingHistory(cursor);
        const child = self.historyCurrentRedoChild() orelse return null;
        try self.applyHistoryNodeForward(child);
        self.history_current = child;
        return child.cursor_after;
    }

    fn historyCurrentRedoChild(self: *Self) ?*HistoryNode {
        if (self.history_current.preferred_child) |preferred| return preferred;
        if (self.history_current.children.items.len == 0) return null;
        return self.history_current.children.items[self.history_current.children.items.len - 1];
    }

    fn finalizePendingHistory(self: *Self, cursor_after: Position) !void {
        var pending = self.pending_history orelse return;
        defer self.pending_history = null;

        if (pending.deltas.items.len == 0) {
            pending.deltas.deinit(self.allocator);
            return;
        }

        const node = try self.allocator.create(HistoryNode);
        node.* = .{
            .parent = pending.parent,
            .children = .empty,
            .preferred_child = null,
            .deltas = pending.deltas,
            .cursor_before = pending.cursor_before,
            .cursor_after = cursor_after,
            .before_strategy = pending.before_strategy,
            .after_strategy = self.backend_strategy,
            .depth = pending.parent.depth + 1,
        };
        errdefer {
            self.deinitDeltaList(&node.deltas);
            self.allocator.destroy(node);
        }

        try pending.parent.children.append(self.allocator, node);
        pending.parent.preferred_child = node;
        self.history_current = node;
        try self.enforceHistoryDepth();
    }

    fn enforceHistoryDepth(self: *Self) !void {
        try self.enforceHistoryDepthCap();
        try self.enforceHistoryByteBudget();
    }

    fn enforceHistoryDepthCap(self: *Self) !void {
        if (self.history_current.depth <= MAX_HISTORY_DEPTH) return;
        const frontier = self.historyFrontierForRetentionDepth(MAX_HISTORY_DEPTH) orelse return;
        try self.rebaseHistoryRoot(frontier);
    }

    fn enforceHistoryByteBudget(self: *Self) !void {
        if (self.history_current == self.history_root) return;
        if (self.historyRetainedBytes() <= MAX_HISTORY_BYTES) return;

        var selected = self.history_current;
        var node = self.history_current;
        while (node.parent) |parent| {
            if (self.historySubtreeBytes(parent) > MAX_HISTORY_BYTES) break;
            selected = parent;
            node = parent;
        }

        if (selected != self.history_root) {
            try self.rebaseHistoryRoot(selected);
        }
    }

    fn historyFrontierForRetentionDepth(self: *Self, retain_depth: usize) ?*HistoryNode {
        if (self.history_current.depth <= retain_depth) return null;

        const frontier_depth = self.history_current.depth - retain_depth + 1;
        var node = self.history_current;
        while (node.depth > frontier_depth) {
            node = node.parent orelse return null;
        }
        return node;
    }

    fn rebaseHistoryRoot(self: *Self, frontier: *HistoryNode) !void {
        const old_root = self.history_root;
        if (frontier == old_root) return;

        const old_parent = frontier.parent orelse return;
        const frontier_idx = self.historyChildIndex(old_parent, frontier) orelse return;

        const new_root = try self.createHistoryRoot(frontier.before_strategy);
        errdefer self.destroyHistoryNode(new_root);
        try new_root.children.append(self.allocator, frontier);

        _ = old_parent.children.orderedRemove(frontier_idx);
        if (old_parent.preferred_child == frontier) old_parent.preferred_child = null;

        frontier.parent = new_root;
        new_root.preferred_child = frontier;

        self.recomputeHistoryDepths(new_root, 0);
        self.history_root = new_root;
        self.destroyHistoryNode(old_root);
    }

    fn historyChildIndex(self: *Self, parent: *const HistoryNode, child: *const HistoryNode) ?usize {
        _ = self;
        for (parent.children.items, 0..) |candidate, idx| {
            if (candidate == child) return idx;
        }
        return null;
    }

    fn recomputeHistoryDepths(self: *Self, node: *HistoryNode, depth: usize) void {
        node.depth = depth;
        for (node.children.items) |child| {
            self.recomputeHistoryDepths(child, depth + 1);
        }
    }

    fn historyRetainedBytes(self: *Self) usize {
        return self.historySubtreeBytes(self.history_root);
    }

    fn historySubtreeBytes(self: *Self, node: *const HistoryNode) usize {
        var total = historyNodeOwnBytes(node);
        for (node.children.items) |child| {
            total += self.historySubtreeBytes(child);
        }
        return total;
    }

    fn historyNodeOwnBytes(node: *const HistoryNode) usize {
        var total: usize = 0;
        for (node.deltas.items) |delta| {
            total += delta.deleted.len + delta.inserted.len;
        }
        return total;
    }

    fn applyHistoryNodeForward(self: *Self, node: *const HistoryNode) !void {
        for (node.deltas.items) |delta| {
            try self.applyRecordedDelta(delta.offset, delta.deleted, delta.inserted);
        }
        try self.ensureBackendStrategy(node.after_strategy);
        try self.afterHistoryReplay();
    }

    fn applyHistoryNodeReverse(self: *Self, node: *const HistoryNode) !void {
        var idx = node.deltas.items.len;
        while (idx > 0) {
            idx -= 1;
            const delta = node.deltas.items[idx];
            try self.applyRecordedDelta(delta.offset, delta.inserted, delta.deleted);
        }
        try self.ensureBackendStrategy(node.before_strategy);
        try self.afterHistoryReplay();
    }

    fn applyRecordedDelta(self: *Self, offset: usize, deleted: []const u8, insert_bytes: []const u8) !void {
        if (deleted.len > 0) {
            try self.text.delete(offset, deleted.len);
            errdefer self.text.insert(offset, deleted) catch {};
        }
        if (insert_bytes.len > 0) {
            try self.text.insert(offset, insert_bytes);
        }
    }

    fn afterHistoryReplay(self: *Self) !void {
        self.resetAdaptiveTracking();
        self.dirty = true;
        if (self.text.lineCount() != self.render_cache.dirty_lines.items.len) {
            try self.render_cache.resize(self.allocator, self.text.lineCount());
        }
        self.render_cache.invalidateAll();
    }

    fn recordDelta(self: *Self, offset: usize, deleted: []u8, inserted: []u8) !void {
        if (self.pending_history == null) {
            self.allocator.free(deleted);
            self.allocator.free(inserted);
            return;
        }

        var pending = &self.pending_history.?;
        if (pending.deltas.items.len > 0) {
            var last = &pending.deltas.items[pending.deltas.items.len - 1];
            if (last.deleted.len == 0 and deleted.len == 0 and offset == last.offset + last.inserted.len) {
                last.inserted = try self.allocator.realloc(last.inserted, last.inserted.len + inserted.len);
                @memcpy(last.inserted[last.inserted.len - inserted.len ..], inserted);
                self.allocator.free(inserted);
                self.allocator.free(deleted);
                return;
            }
            if (last.inserted.len == 0 and inserted.len == 0 and offset + deleted.len == last.offset) {
                const merged = try self.allocator.alloc(u8, deleted.len + last.deleted.len);
                @memcpy(merged[0..deleted.len], deleted);
                @memcpy(merged[deleted.len..], last.deleted);
                self.allocator.free(last.deleted);
                last.deleted = merged;
                last.offset = offset;
                self.allocator.free(inserted);
                self.allocator.free(deleted);
                return;
            }
        }
        // replaceRange() still owns deleted/inserted cleanup on append failure; ownership
        // transfers to history only after this append succeeds.
        try pending.deltas.append(self.allocator, .{
            .offset = offset,
            .deleted = deleted,
            .inserted = inserted,
        });
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
        try self.replaceRange(offset, 0, &[_]u8{ch});
    }

    pub fn insertBytesAt(self: *Self, pos: Position, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const offset = (try self.text.posToOffset(pos.row, pos.col)) orelse return;
        try self.replaceRange(offset, 0, bytes);
    }

    pub fn deleteCharAt(self: *Self, pos: Position) !?u8 {
        if (pos.row == 0 and pos.col == 0) return null;
        const line = self.getLine(pos.row) orelse return null;

        if (pos.col == 0) {
            // Join with previous line: delete the newline at end of (row-1)
            const prev_line = self.getLine(pos.row - 1) orelse return null;
            const newline_off = (try self.text.posToOffset(pos.row - 1, prev_line.len)) orelse return null;
            try self.replaceRange(newline_off, 1, "");
            self.render_cache.markDirtyFrom(pos.row - 1);
            return '\n';
        }

        if (pos.col > line.len) return null;

        const delete_start = utf8PrevBoundary(line, pos.col);
        const delete_end = utf8NextBoundary(line, delete_start);
        if (delete_end <= delete_start) return null;

        const ch = line[delete_start];
        const offset = (try self.text.posToOffset(pos.row, delete_start)) orelse return null;
        try self.replaceRange(offset, delete_end - delete_start, "");
        return ch;
    }

    pub fn insertNewlineAt(self: *Self, pos: Position) !void {
        const offset = (try self.text.posToOffset(pos.row, pos.col)) orelse return;
        try self.replaceRange(offset, 0, "\n");
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
        try self.replaceRange(start_range.start, end_off - start_range.start, "");
        self.render_cache.markDirtyFrom(start);
    }

    pub fn insertLine(self: *Self, row: usize, text: []const u8) !void {
        const line_count = self.text.lineCount();
        if (row > line_count) return;

        if (row == line_count) {
            const offset = self.text.len();
            if (row > 0) {
                var combined: std.ArrayList(u8) = .empty;
                defer combined.deinit(self.allocator);
                try combined.append(self.allocator, '\n');
                try combined.appendSlice(self.allocator, text);
                try self.replaceRange(offset, 0, combined.items);
                self.render_cache.markDirtyFrom(row);
            } else {
                try self.replaceRange(offset, 0, text);
                self.render_cache.markDirtyFrom(row);
            }
            return;
        }

        const offset = (try self.text.posToOffset(row, 0)) orelse return;
        var combined: std.ArrayList(u8) = .empty;
        defer combined.deinit(self.allocator);
        try combined.appendSlice(self.allocator, text);
        try combined.append(self.allocator, '\n');
        try self.replaceRange(offset, 0, combined.items);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn setLine(self: *Self, row: usize, text: []const u8) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        const line_len = if (row + 1 < self.text.lineCount())
            range.end - range.start - 1 // exclude the trailing newline
        else
            self.text.len() - range.start;
        try self.replaceRange(range.start, line_len, text);
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
        try self.replaceRange(offset, end - start, bytes);
    }

    pub fn replaceLinePrefix(self: *Self, row: usize, prefix: []const u8, rest_start: usize) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        try self.replaceRange(range.start, rest_start, prefix);
        self.render_cache.markDirtyFrom(row);
    }

    pub fn deleteLine(self: *Self, row: usize) !void {
        const range = (try self.text.lineByteRange(row)) orelse return;
        const end_off = if (row + 1 < self.text.lineCount())
            range.end
        else
            self.text.len();
        try self.replaceRange(range.start, end_off - range.start, "");
        self.render_cache.markDirtyFrom(row);
    }

    pub fn joinLines(self: *Self, row: usize, allocator: std.mem.Allocator) !void {
        _ = allocator;
        const line1 = self.getLine(row) orelse return;
        const line2 = self.getLine(row + 1) orelse return;
        const trimmed = std.mem.trimStart(u8, line2, " \t");

        // Delete the newline at end of line1
        const newline_off = (try self.text.posToOffset(row, line1.len)) orelse return;
        const ws_count = line2.len - trimmed.len;
        try self.replaceRange(newline_off, ws_count + 1, " ");
        self.render_cache.markDirtyFrom(row);
    }

    fn replaceRange(self: *Self, offset: usize, delete_len: usize, insert_bytes: []const u8) !void {
        const state = MutationState{
            .strategy = self.backend_strategy,
            .dirty = self.dirty,
            .last_edit_offset = self.last_edit_offset,
            .localized_edit_streak = self.localized_edit_streak,
            .dispersed_edit_streak = self.dispersed_edit_streak,
            .render_cache_len = self.render_cache.dirty_lines.items.len,
        };
        const deleted = try self.copyTextRange(offset, delete_len);
        errdefer self.allocator.free(deleted);
        const inserted = try self.allocator.dupe(u8, insert_bytes);
        errdefer self.allocator.free(inserted);

        try self.applyRecordedDelta(offset, deleted, insert_bytes);
        self.finishMutation(offset, deleted, inserted) catch |err| {
            try self.rollbackReplaceRange(offset, deleted, inserted, state);
            return err;
        };
    }

    fn copyTextRange(self: *Self, offset: usize, len: usize) ![]u8 {
        const clamped = @min(len, self.text.len() -| offset);
        const out = try self.allocator.alloc(u8, clamped);
        var copied: usize = 0;
        while (copied < clamped) {
            const read_len = try self.text.readChunk(offset + copied, out[copied..]);
            if (read_len == 0) break;
            copied += read_len;
        }
        return out[0..copied];
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

    fn finishMutation(self: *Self, offset: usize, deleted: []u8, inserted: []u8) !void {
        const magnitude = deleted.len + inserted.len;
        const spans_lines = std.mem.indexOfScalar(u8, deleted, '\n') != null or std.mem.indexOfScalar(u8, inserted, '\n') != null;
        self.recordEdit(offset);
        try self.adaptBackend(offset, magnitude);
        self.dirty = true;
        if (spans_lines) {
            if (self.text.lineCount() != self.render_cache.dirty_lines.items.len) {
                try self.render_cache.resize(self.allocator, self.text.lineCount());
            }
        }

        const pos = try self.text.offsetToPos(offset);
        if (spans_lines) {
            self.render_cache.markDirtyFrom(pos.row);
        } else {
            self.render_cache.markDirty(pos.row);
        }
        try self.recordDelta(offset, deleted, inserted);
    }

    fn rollbackReplaceRange(self: *Self, offset: usize, deleted: []const u8, inserted: []const u8, state: MutationState) !void {
        try self.applyRecordedDelta(offset, inserted, deleted);
        try self.ensureBackendStrategy(state.strategy);
        if (self.render_cache.dirty_lines.items.len != state.render_cache_len) {
            try self.render_cache.resize(self.allocator, state.render_cache_len);
        }
        self.dirty = state.dirty;
        self.last_edit_offset = state.last_edit_offset;
        self.localized_edit_streak = state.localized_edit_streak;
        self.dispersed_edit_streak = state.dispersed_edit_streak;
        self.render_cache.invalidateAll();
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

    try buf.replaceRange(4, 0, large_text);
    try std.testing.expectEqual(Strategy.tree_rope, buf.backend());

    try buf.pushUndo(.{ .row = 0, .col = buf.text.len() });

    const undo_pos = (try buf.undo(.{ .row = 0, .col = 4 + large_text.len })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, undo_pos);
    try std.testing.expectEqual(Strategy.gap_buffer, buf.backend());
    try std.testing.expectEqualStrings("seed", buf.getLine(0).?);

    const redo_pos = (try buf.redo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;
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

test "Buffer: replaceRange rolls back text when mutation bookkeeping fails" {
    const allocator = std.testing.allocator;
    var saw_oom = false;

    for (0..16) |fail_step| {
        var failing_state = std.testing.FailingAllocator.init(allocator, .{});
        var buf = try Buffer.initStrategy(failing_state.allocator(), .gap_buffer, "ab");
        defer buf.deinit();

        try buf.pushUndo(.{ .row = 0, .col = 1 });
        failing_state.fail_index = failing_state.alloc_index + fail_step;

        if (buf.insertNewlineAt(.{ .row = 0, .col = 1 })) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_oom = true;
                failing_state.fail_index = std.math.maxInt(usize);
                try expectBufferText(buf, "ab");
            },
            else => return err,
        }
    }

    try std.testing.expect(saw_oom);
}

test "Buffer: finalizePendingHistory cleans up node if child append fails" {
    const allocator = std.testing.allocator;

    var failing_state = std.testing.FailingAllocator.init(allocator, .{});
    var buf = try Buffer.initStrategy(failing_state.allocator(), .gap_buffer, "a");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'b');

    failing_state.fail_index = failing_state.alloc_index + 1;
    try std.testing.expectError(error.OutOfMemory, buf.finalizePendingHistory(.{ .row = 0, .col = 2 }));

    failing_state.fail_index = std.math.maxInt(usize);
    try expectBufferText(buf, "ab");
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

    _ = (try buf.redo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;
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

    _ = (try buf.redo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;
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
    try std.testing.expect((try buf.redo(.{ .row = 0, .col = 0 })) == null);

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);
}

test "Buffer: branching undo keeps alternate redo branches in history tree" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Y');

    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;
    try buf.pushUndo(.{ .row = 0, .col = 1 });
    try buf.insertCharAt(.{ .row = 0, .col = 1 }, 'Z');
    _ = (try buf.undo(.{ .row = 0, .col = 2 })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 2), buf.history_current.children.items.len);
    try std.testing.expect(buf.history_current.preferred_child != null);
}

test "Buffer: undo captures current cursor for redo snapshot" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "hello");
    defer buf.deinit();

    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'X');

    const undo_pos = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, undo_pos);
    const redo_pos = (try buf.redo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, redo_pos);
    try std.testing.expectEqualStrings("Xhello", buf.getLine(0).?);
}

test "Buffer: history depth cap retains only the most recent undo chain" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "initial");
    defer buf.deinit();

    const total_edits = Buffer.MAX_HISTORY_DEPTH + 25;
    for (0..total_edits) |i| {
        try buf.pushUndo(.{ .row = 0, .col = 0 });
        try buf.insertCharAt(.{ .row = 0, .col = 0 }, @as(u8, @intCast(65 + (i % 26))));
    }

    try buf.finalizePendingHistory(.{ .row = 0, .col = 0 });

    try std.testing.expectEqual(Buffer.MAX_HISTORY_DEPTH, buf.history_current.depth);
    try std.testing.expectEqual(@as(usize, 1), buf.history_root.children.items.len);

    var undo_count: usize = 0;
    while (try buf.undo(.{ .row = 0, .col = 0 })) |_| {
        undo_count += 1;
    }
    try std.testing.expectEqual(Buffer.MAX_HISTORY_DEPTH, undo_count);

    var redo_count: usize = 0;
    while (try buf.redo(.{ .row = 0, .col = 0 })) |_| {
        redo_count += 1;
    }
    try std.testing.expectEqual(Buffer.MAX_HISTORY_DEPTH, redo_count);
}

test "Buffer: history pruning preserves alternate branches within retained depth" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "seed");
    defer buf.deinit();

    const total_edits = Buffer.MAX_HISTORY_DEPTH + 8;
    for (0..total_edits) |i| {
        try buf.pushUndo(.{ .row = 0, .col = 0 });
        try buf.insertCharAt(.{ .row = 0, .col = 0 }, @as(u8, @intCast(65 + (i % 26))));
    }
    try buf.finalizePendingHistory(.{ .row = 0, .col = 0 });

    _ = (try buf.undo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;
    _ = (try buf.undo(.{ .row = 0, .col = 0 })) orelse return error.TestUnexpectedResult;

    const branch_point = buf.history_current;
    try buf.pushUndo(.{ .row = 0, .col = 0 });
    try buf.insertCharAt(.{ .row = 0, .col = 0 }, 'Z');
    try buf.finalizePendingHistory(.{ .row = 0, .col = 1 });

    _ = (try buf.undo(.{ .row = 0, .col = 1 })) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(branch_point, buf.history_current);
    try std.testing.expectEqual(@as(usize, 2), branch_point.children.items.len);
    try std.testing.expect(branch_point.preferred_child != null);
    try std.testing.expect(branch_point.depth < Buffer.MAX_HISTORY_DEPTH);
}

test "Buffer: history byte budget prunes oversized retained deltas" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "");
    defer buf.deinit();

    const payload_len = Buffer.MAX_HISTORY_BYTES / 4 + 128;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    @memset(payload, 'p');

    for (0..6) |_| {
        try buf.pushUndo(.{ .row = 0, .col = 0 });
        try buf.insertBytesAt(.{ .row = 0, .col = 0 }, payload);
    }
    try buf.finalizePendingHistory(.{ .row = 0, .col = buf.lineLen(0) });

    try std.testing.expect(buf.historyRetainedBytes() <= Buffer.MAX_HISTORY_BYTES);
    try std.testing.expectEqual(@as(usize, 3), buf.history_current.depth);

    var undo_count: usize = 0;
    while (try buf.undo(.{ .row = 0, .col = 0 })) |_| {
        undo_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), undo_count);
}

test "Buffer: superlarge tree-rope history stays within byte budget" {
    const allocator = std.testing.allocator;

    const base_len = 4 * 1024 * 1024;
    const base = try allocator.alloc(u8, base_len);
    defer allocator.free(base);
    @memset(base, 'a');

    var buf = try Buffer.initStrategy(allocator, .tree_rope, base);
    defer buf.deinit();

    const payload_len = 256 * 1024;
    const payload = try allocator.alloc(u8, payload_len);
    defer allocator.free(payload);
    @memset(payload, 'b');

    for (0..10) |_| {
        try buf.pushUndo(.{ .row = 0, .col = 0 });
        try buf.insertBytesAt(.{ .row = 0, .col = 0 }, payload);
    }
    try buf.finalizePendingHistory(.{ .row = 0, .col = buf.lineLen(0) });

    try std.testing.expect(buf.historyRetainedBytes() <= Buffer.MAX_HISTORY_BYTES);
    try std.testing.expect(buf.history_current.depth <= 4);
    try std.testing.expect(buf.lineLen(0) >= base_len + (10 * payload_len));
}
