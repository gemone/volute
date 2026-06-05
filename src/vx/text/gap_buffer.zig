const std = @import("std");
const Position = @import("../position.zig").Position;
const TextStore = @import("storage.zig").TextStore;
const LineRange = @import("storage.zig").LineRange;
const LineCache = @import("line_cache.zig").LineCache;

/// Initial gap size for new buffers.
const INITIAL_GAP: usize = 256;

/// Minimum gap to maintain after operations.
const MIN_GAP: usize = 64;

/// Grow factor for gap buffer reallocation.
const GROW_FACTOR: f64 = 1.5;

/// Gap buffer text storage backend.
///
/// A contiguous buffer with a movable gap. Insert/delete at the gap
/// position are O(1). Moving the gap is O(distance moved).
///
/// Per the gap-buffer-vs-rope showdown analysis, gap buffers win on:
///   - Search (7x+ faster than ropes — the gap gives ~flat memory)
///   - Memory overhead (~0% overhead, virtually unchanged after edits)
///   - Localized editing (cursor-based patterns common in modal editors)
///
/// Ropes only beat gap buffers when edits are very far apart (>4K bytes)
/// or when tail latency must be bounded regardless of file size.
///
/// For the editor use case (Helix-like modal editing), most edits are
/// at or near the cursor, making GapBuffer the optimal default backend.
pub const GapBuffer = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    buf: []u8,
    gap_start: usize,
    gap_end: usize,
    total_newlines: usize,

    // Unified line cache management
    line_cache: LineCache(Self),
    heap_allocated: bool = false, // Track if this struct was heap-allocated (via factory)

    pub fn init(allocator: std.mem.Allocator) !Self {
        const buf = try allocator.alloc(u8, INITIAL_GAP);
        return .{
            .allocator = allocator,
            .buf = buf,
            .gap_start = 0,
            .gap_end = INITIAL_GAP,
            .total_newlines = 0,
            .line_cache = try LineCache(Self).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.allocator.free(self.buf);
        self.line_cache.deinit(allocator);
    }

    /// Destroy the GapBuffer struct and all its allocations.
    /// Only call this if heap_allocated is true (set by factory).
    /// For stack-allocated GapBuffers, just call deinit().
    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        if (self.heap_allocated) {
            allocator.destroy(self);
        }
    }

    /// Load content from a byte slice. Replaces any existing content.
    pub fn fromSlice(self: *Self, data: []const u8) !void {
        const needed = data.len + MIN_GAP;
        if (needed > self.buf.len) {
            self.allocator.free(self.buf);
            self.buf = try self.allocator.alloc(u8, needed);
        }
        @memcpy(self.buf[0..data.len], data);
        self.gap_start = data.len;
        self.gap_end = self.buf.len;
        self.total_newlines = std.mem.count(u8, data, "\n");
        self.line_cache.invalidate();
    }

    pub fn len(self: *const Self) usize {
        return self.buf.len - (self.gap_end - self.gap_start);
    }

    /// Move the gap so it is positioned at `byte_offset`.
    /// Gap movement is O(distance) — the trade-off for O(1) local edits.
    fn moveGap(self: *Self, byte_offset: usize) void {
        const clamped = @min(byte_offset, self.len());
        const old_gap_start = self.gap_start;
        const old_gap_end = self.gap_end;

        // Early return if already at the target position
        if (clamped == old_gap_start) return;

        if (clamped < old_gap_start) {
            // Move gap left: shift [clamped..old_gap_start] to after the gap
            const count = old_gap_start - clamped;
            if (count > 0) {
                const src = self.buf[clamped..old_gap_start];
                const dst = self.buf[old_gap_end - count .. old_gap_end];
                std.mem.copyBackwards(u8, dst, src);
            }
            self.gap_start = clamped;
            self.gap_end = old_gap_end - count;
        } else {
            // Move gap right: shift [old_gap_end..old_gap_end+count] into the gap
            const count = clamped - old_gap_start;
            if (count > 0) {
                const src = self.buf[old_gap_end .. old_gap_end + count];
                const dst = self.buf[old_gap_start .. old_gap_start + count];
                std.mem.copyForwards(u8, dst, src);
            }
            self.gap_start = clamped;
            self.gap_end = old_gap_end + count;
        }
    }

    /// Get byte at offset, accounting for the gap.
    /// Returns null if offset is beyond content length.
    fn byteAt(self: *Self, offset: usize) ?u8 {
        if (offset >= self.len()) return null;
        return if (offset < self.gap_start)
            self.buf[offset]
        else
            self.buf[offset + (self.gap_end - self.gap_start)];
    }

    /// Ensure the gap has at least `needed` free bytes.
    fn ensureGap(self: *Self, needed: usize) !void {
        const gap_size = self.gap_end - self.gap_start;
        if (gap_size >= needed) return;

        const content_len = self.len();
        const new_capacity = @max(
            @as(usize, @intFromFloat(@as(f64, @floatFromInt(self.buf.len)) * GROW_FACTOR)),
            content_len + needed + MIN_GAP,
        );
        const new_buf = try self.allocator.alloc(u8, new_capacity);
        const pre_len = self.gap_start;
        const post_len = self.buf.len - self.gap_end;

        // Copy pre-gap data to the beginning
        if (pre_len > 0) @memcpy(new_buf[0..pre_len], self.buf[0..pre_len]);

        // Keep the post-gap data at the end of the allocation so the grown
        // gap stays contiguous, matching the classic Emacs layout.
        const gap_end_new = new_capacity - post_len;
        if (post_len > 0) {
            @memcpy(new_buf[gap_end_new..][0..post_len], self.buf[self.gap_end..]);
        }

        self.allocator.free(self.buf);
        self.buf = new_buf;
        self.gap_start = pre_len;
        self.gap_end = gap_end_new;
    }

    pub fn insert(self: *Self, byte_offset: usize, text: []const u8) !void {
        if (text.len == 0) return;
        try self.ensureGap(text.len);
        self.moveGap(byte_offset);
        @memcpy(self.buf[self.gap_start .. self.gap_start + text.len], text);
        self.gap_start += text.len;

        const newline_count = std.mem.count(u8, text, "\n");
        self.total_newlines += newline_count;

        if (newline_count == 0 and self.line_cache.valid) {
            // No new lines: shift all line starts after the insertion point forward.
            self.line_cache.shiftForwardFrom(byte_offset, text.len);
        } else {
            self.line_cache.invalidate();
        }
    }

    pub fn delete(self: *Self, byte_offset: usize, length: usize) !void {
        if (length == 0 or self.len() == 0) return;
        const clamped_len = @min(length, self.len() -| byte_offset);
        if (clamped_len == 0) return;

        const end = byte_offset + clamped_len;
        // Position gap at end of delete range, then expand backward
        self.moveGap(end);

        // Count newlines in deleted range and only invalidate cache if we deleted newlines
        const deleted_newlines = std.mem.count(u8, self.buf[byte_offset..self.gap_start], "\n");
        self.total_newlines -= deleted_newlines;

        // Expand gap backward to cover the deleted bytes
        self.gap_start = byte_offset;

        if (deleted_newlines == 0 and self.line_cache.valid) {
            // No lines removed: shift all line starts after the deletion point backward.
            self.line_cache.shiftBackwardFrom(byte_offset, clamped_len);
        } else {
            self.line_cache.invalidate();
        }
    }

    pub fn charAt(self: *const Self, byte_offset: usize) ?u8 {
        if (byte_offset >= self.len()) return null;
        if (byte_offset < self.gap_start) {
            return self.buf[byte_offset];
        } else {
            return self.buf[byte_offset + (self.gap_end - self.gap_start)];
        }
    }

    pub fn lineCount(self: *const Self) usize {
        return self.total_newlines + 1;
    }

    fn rebuildCache(self: *Self) !void {
        // Fast path: scan the two contiguous gap-buffer slices directly using
        // SIMD-capable indexOfScalarPos instead of the per-byte callback.
        const pre = self.buf[0..self.gap_start];
        const post = self.buf[self.gap_end..];
        self.line_cache.starts.clearRetainingCapacity();
        try self.line_cache.starts.append(self.allocator, 0);

        var search: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pre, search, '\n')) |pos| {
            try self.line_cache.starts.append(self.allocator, pos + 1);
            search = pos + 1;
        }
        const base: usize = self.gap_start;
        search = 0;
        while (std.mem.indexOfScalarPos(u8, post, search, '\n')) |pos| {
            try self.line_cache.starts.append(self.allocator, base + pos + 1);
            search = pos + 1;
        }
        self.line_cache.valid = true;
    }

    fn ensureCache(self: *Self) !void {
        if (!self.line_cache.valid) try self.rebuildCache();
    }

    pub fn lineByteRange(self: *Self, line: usize) !?LineRange {
        try self.ensureCache();
        if (self.line_cache.getLineRange(line, self.len())) |range| {
            return .{ .start = range.start, .end = range.end };
        }
        return null;
    }

    pub fn getLine(self: *Self, line: usize, buf: *std.ArrayList(u8)) !?[]const u8 {
        try self.ensureCache();
        if (self.line_cache.getLineRange(line, self.len())) |range| {
            const start = range.start;
            const end = if (line + 1 < self.line_cache.lineCount())
                range.end -| 1
            else
                self.len();

            if (end <= start) {
                buf.clearRetainingCapacity();
                return buf.items;
            }

            buf.clearRetainingCapacity();
            const total = self.len();
            if (end > total) return buf.items;
            // Split the logical [start, end) range across the gap boundary.
            // Case 1: entire range is before the gap.
            // Case 2: entire range is in the post-gap region.
            // Case 3: range straddles the gap — two appendSlice calls.
            if (end <= self.gap_start) {
                // Entirely in pre-gap region.
                try buf.appendSlice(self.allocator, self.buf[start..end]);
            } else if (start >= self.gap_start) {
                // Entirely in post-gap region (physical offset adjusted).
                const gap_size = self.gap_end - self.gap_start;
                try buf.appendSlice(self.allocator, self.buf[start + gap_size .. end + gap_size]);
            } else {
                // Straddles the gap: pre-gap portion then post-gap portion.
                try buf.appendSlice(self.allocator, self.buf[start..self.gap_start]);
                const gap_size = self.gap_end - self.gap_start;
                try buf.appendSlice(self.allocator, self.buf[self.gap_end .. end + gap_size]);
            }
            return buf.items;
        }
        return null;
    }

    pub fn posToOffset(self: *Self, row: usize, col: usize) !?usize {
        try self.ensureCache();
        if (row >= self.line_cache.starts.items.len) return null;
        const max_col = try self.lineLengthNoNewline(row);
        if (col > max_col) return null;
        return self.line_cache.starts.items[row] + col;
    }

    pub fn offsetToPos(self: *Self, offset: usize) !Position {
        if (self.len() == 0) return .{};
        const clamped = @min(offset, self.len());
        try self.ensureCache();

        var lo: usize = 0;
        var hi: usize = self.line_cache.starts.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_cache.starts.items[mid] <= clamped) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const row = if (lo > 0) lo - 1 else 0;
        return .{ .row = row, .col = clamped - self.line_cache.starts.items[row] };
    }

    pub fn writeTo(self: *Self, w: *std.Io.Writer) !void {
        const pre_len = self.gap_start;
        if (pre_len > 0) try w.writeAll(self.buf[0..pre_len]);
        const post_start = self.gap_end;
        const post_len = self.buf.len - post_start;
        if (post_len > 0) try w.writeAll(self.buf[post_start..]);
    }

    pub fn writeToBuf(self: *const Self, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        const pre_len = self.gap_start;
        if (pre_len > 0) try buf.appendSlice(gpa, self.buf[0..pre_len]);
        const post_start = self.gap_end;
        const post_len = self.buf.len - post_start;
        if (post_len > 0) try buf.appendSlice(gpa, self.buf[post_start..]);
    }

    pub fn clone(self: *Self, gpa: std.mem.Allocator) !TextStore {
        const new_buf = try gpa.create(Self);
        new_buf.* = try Self.init(gpa);
        new_buf.heap_allocated = true; // Mark as heap-allocated so vtable can destroy it
        errdefer {
            new_buf.deinit(gpa);
            gpa.destroy(new_buf);
        }

        const data = try self.borrowAll(gpa);
        defer gpa.free(data);
        try new_buf.fromSlice(data);
        return new_buf.provider();
    }

    /// GapBuffer-specific clone (returns *GapBuffer directly).
    pub fn cloneBuffer(self: *Self, gpa: std.mem.Allocator) !*Self {
        const new_buf = try gpa.create(Self);
        new_buf.* = try Self.init(gpa);
        errdefer gpa.destroy(new_buf);

        const data = try self.borrowAll(gpa);
        defer gpa.free(data);
        try new_buf.fromSlice(data);
        return new_buf;
    }

    /// Return all content as a single allocation (borrowed, caller must free).
    pub fn borrowAll(self: *const Self, gpa: std.mem.Allocator) ![]u8 {
        const total = self.len();
        var result = try gpa.alloc(u8, total);
        const pre_len = self.gap_start;
        if (pre_len > 0) @memcpy(result[0..pre_len], self.buf[0..pre_len]);
        const post_start = self.gap_end;
        const post_len = self.buf.len - post_start;
        if (post_len > 0) @memcpy(result[pre_len..], self.buf[post_start..]);
        return result;
    }

    pub fn replaceFrom(self: *Self, other: *const Self) !void {
        const data = try other.borrowAll(self.allocator);
        defer self.allocator.free(data);
        try self.fromSlice(data);
    }

    pub fn readChunk(self: *const Self, byte_offset: usize, buf: []u8) !usize {
        const total = self.len();
        if (byte_offset >= total) return 0;
        const available = total - byte_offset;
        const to_read = @min(buf.len, available);

        var i: usize = 0;
        while (i < to_read) : (i += 1) {
            const src = byte_offset + i;
            buf[i] = if (src < self.gap_start)
                self.buf[src]
            else
                self.buf[src + (self.gap_end - self.gap_start)];
        }
        return to_read;
    }

    pub fn provider(self: *Self) TextStore {
        const vtbl = comptime TextStore.makeVTable(Self);
        return .{ .ptr = self, .vtable = &vtbl };
    }

    fn lineLengthNoNewline(self: *Self, row: usize) !usize {
        const range = (try self.lineByteRange(row)) orelse return 0;
        const raw_len = range.end - range.start;
        if (raw_len == 0) return 0;
        if (self.charAt(range.end - 1) == '\n') return raw_len - 1;
        return raw_len;
    }
};

fn expectGapBufferSingleLineState(gb: *GapBuffer, expected: []const u8) !void {
    try std.testing.expectEqual(expected.len, gb.len());
    try std.testing.expectEqual(@as(usize, 1), gb.lineCount());
    try std.testing.expectEqual(@as(?u8, null), gb.charAt(expected.len));

    var write_buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, expected.len + 8);
    defer write_buf.deinit(std.testing.allocator);
    try gb.writeToBuf(std.testing.allocator, &write_buf);
    try std.testing.expectEqualStrings(expected, write_buf.items);

    var line_buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, expected.len + 8);
    defer line_buf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, (try gb.getLine(0, &line_buf)).?);

    const mid = expected.len / 2;
    try std.testing.expectEqual(@as(?usize, 0), try gb.posToOffset(0, 0));
    try std.testing.expectEqual(@as(?usize, mid), try gb.posToOffset(0, mid));
    try std.testing.expectEqual(@as(?usize, expected.len), try gb.posToOffset(0, expected.len));

    const origin = try gb.offsetToPos(0);
    try std.testing.expectEqual(@as(usize, 0), origin.row);
    try std.testing.expectEqual(@as(usize, 0), origin.col);

    const mid_pos = try gb.offsetToPos(mid);
    try std.testing.expectEqual(@as(usize, 0), mid_pos.row);
    try std.testing.expectEqual(mid, mid_pos.col);

    const end_pos = try gb.offsetToPos(expected.len);
    try std.testing.expectEqual(@as(usize, 0), end_pos.row);
    try std.testing.expectEqual(expected.len, end_pos.col);

    if (expected.len > 0) {
        try std.testing.expectEqual(expected[0], gb.charAt(0).?);
        try std.testing.expectEqual(expected[mid], gb.charAt(mid).?);
        try std.testing.expectEqual(expected[expected.len - 1], gb.charAt(expected.len - 1).?);
    }
}

test "GapBuffer: insert and read round-trip" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("hello world");
    try std.testing.expectEqual(@as(usize, 11), gb.len());
    try std.testing.expectEqual(@as(u8, 'h'), gb.charAt(0).?);
    try std.testing.expectEqual(@as(u8, 'w'), gb.charAt(6).?);
    try std.testing.expectEqual(@as(u8, 'd'), gb.charAt(10).?);
}

test "GapBuffer: insert at beginning" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("world");
    try gb.insert(0, "hello ");
    try expectGapBufferSingleLineState(&gb, "hello world");
}

test "GapBuffer: insert at end" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("hello");
    try gb.insert(5, " world");
    try expectGapBufferSingleLineState(&gb, "hello world");
}

test "GapBuffer: insert in middle" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("he world");
    try gb.insert(2, "llo");
    try expectGapBufferSingleLineState(&gb, "hello world");
}

test "GapBuffer: repeated insertions at head" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("tail");
    try gb.insert(0, "-");
    try gb.insert(0, "mid");
    try gb.insert(0, "head-");

    try expectGapBufferSingleLineState(&gb, "head-mid-tail");
}

test "GapBuffer: repeated insertions in middle" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("AH");
    try gb.insert(1, "D");
    try gb.insert(1, "BC");
    try gb.insert(4, "EFG");

    try expectGapBufferSingleLineState(&gb, "ABCDEFGH");
}

test "GapBuffer: repeated insertions at tail" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("head");
    try gb.insert(gb.len(), "-");
    try gb.insert(gb.len(), "mid");
    try gb.insert(gb.len(), "-tail");

    try expectGapBufferSingleLineState(&gb, "head-mid-tail");
}

test "GapBuffer: moveGap preserves content across overlapping moves" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("abcdefghijklmnopqrstuvwxyz");
    const original = try gb.borrowAll(std.testing.allocator);
    defer std.testing.allocator.free(original);

    gb.moveGap(0);
    gb.moveGap(10);
    gb.moveGap(3);
    gb.moveGap(gb.len());
    gb.moveGap(1);

    const current = try gb.borrowAll(std.testing.allocator);
    defer std.testing.allocator.free(current);
    try std.testing.expectEqualStrings(original, current);
}

test "GapBuffer: mixed repeated insertion sequence" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("core");
    try gb.insert(0, "start-");
    try gb.insert(gb.len(), "-end");
    try gb.insert(6, "mid-");
    try gb.insert(0, "[");
    try gb.insert(gb.len(), "]");

    try expectGapBufferSingleLineState(&gb, "[start-mid-core-end]");
}

test "GapBuffer: delete from middle" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("hello world");
    try gb.delete(5, 1);
    try std.testing.expectEqual(@as(usize, 10), gb.len());
    try std.testing.expectEqual(@as(u8, 'w'), gb.charAt(5).?);
}

test "GapBuffer: delete from beginning" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("hello world");
    try gb.delete(0, 6);
    try std.testing.expectEqual(@as(usize, 5), gb.len());
    try std.testing.expectEqual(@as(u8, 'w'), gb.charAt(0).?);
}

test "GapBuffer: line count" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("line1\nline2\nline3\n");
    try std.testing.expectEqual(@as(usize, 4), gb.lineCount());
}

test "GapBuffer: getLine" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("abc\ndef\nghi");
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);

    const line0 = (try gb.getLine(0, &buf)).?;
    try std.testing.expectEqualStrings("abc", line0);
    const line1 = (try gb.getLine(1, &buf)).?;
    try std.testing.expectEqualStrings("def", line1);
    const line2 = (try gb.getLine(2, &buf)).?;
    try std.testing.expectEqualStrings("ghi", line2);
}

test "GapBuffer: non-newline edits keep cache valid with updated offsets" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("abc\ndef");
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);

    _ = try gb.getLine(1, &buf);
    try std.testing.expect(gb.line_cache.isValid());

    // Non-newline insert: cache stays valid, line starts are updated incrementally.
    try gb.insert(0, "X");
    try std.testing.expect(gb.line_cache.isValid());
    try std.testing.expectEqual(@as(?usize, 5), try gb.posToOffset(1, 0));

    _ = try gb.getLine(1, &buf);
    try std.testing.expect(gb.line_cache.isValid());

    // Non-newline delete: cache stays valid, line starts are updated incrementally.
    try gb.delete(0, 1);
    try std.testing.expect(gb.line_cache.isValid());
    try std.testing.expectEqual(@as(?usize, 4), try gb.posToOffset(1, 0));
}

test "GapBuffer: posToOffset and offsetToPos" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    try gb.fromSlice("hello\nworld\n");
    const off = (try gb.posToOffset(1, 2)).?;
    try std.testing.expectEqual(@as(usize, 8), off);

    const pos = try gb.offsetToPos(8);
    try std.testing.expectEqual(@as(usize, 1), pos.row);
    try std.testing.expectEqual(@as(usize, 2), pos.col);
}

test "GapBuffer: clone preserves content" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("clone test");

    var cloned = try gb.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 10), cloned.len());
}

test "GapBuffer: readChunk" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("hello world");

    var buf: [5]u8 = undefined;
    const n = try gb.readChunk(0, &buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "GapBuffer: writeToBuf" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("hello world");

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    try gb.writeToBuf(std.testing.allocator, &buf);

    try std.testing.expectEqualStrings("hello world", buf.items);
}

test "GapBuffer: writeTo filesystem round-trip" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const parent = ".zig-cache/tmp";
    const path = try std.fs.path.join(allocator, &.{ parent, &tmp.sub_path, "test_gb.txt" });
    defer allocator.free(path);

    var gb = try GapBuffer.init(allocator);
    defer gb.deinit(allocator);
    try gb.fromSlice("hello gap buffer");

    const cwd = std.Io.Dir.cwd();
    {
        var file = try cwd.createFile(io, path, .{});
        defer file.close(io);

        var write_buf: [4096]u8 = undefined;
        var writer = file.writerStreaming(io, &write_buf);
        try gb.writeTo(&writer.interface);
        try writer.flush();
        try file.sync(io); // Ensure data is written to disk
    }
    // File is closed now, safe to open for reading

    // Read back and verify
    var read_file = try cwd.openFile(io, path, .{});
    defer read_file.close(io);

    // Get file size and read exactly that many bytes
    const stat = try read_file.stat(io);
    const file_size = stat.size;
    var read_buf: [64]u8 = undefined;
    var reader = read_file.reader(io, &read_buf);
    const content = try reader.interface.readAlloc(allocator, file_size);
    defer allocator.free(content);

    try std.testing.expectEqualStrings("hello gap buffer", content);
}

test "GapBuffer: replaceFrom restores content" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("original content");

    var other = try GapBuffer.init(std.testing.allocator);
    defer other.deinit(std.testing.allocator);
    try other.fromSlice("replacement content");

    try gb.replaceFrom(&other);
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    const line = (try gb.getLine(0, &buf)).?;
    try std.testing.expectEqualStrings("replacement content", line);
}

test "GapBuffer: fromSlice empty string" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("");
    try std.testing.expectEqual(@as(usize, 0), gb.len());
    try std.testing.expectEqual(@as(usize, 1), gb.lineCount());
}

test "GapBuffer: insert empty does nothing" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("test");
    try gb.insert(2, "");
    try std.testing.expectEqual(@as(usize, 4), gb.len());
}

test "GapBuffer: delete zero does nothing" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("test");
    try gb.delete(0, 0);
    try std.testing.expectEqual(@as(usize, 4), gb.len());
}

test "GapBuffer: offsetToPos returns origin for empty" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    const pos = try gb.offsetToPos(0);
    try std.testing.expectEqual(@as(usize, 0), pos.row);
    try std.testing.expectEqual(@as(usize, 0), pos.col);
}

test "GapBuffer: growth preserves slack gap" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);

    const text = "abcdefghijklmnopqrstuvwxyz" ** 32;
    try gb.insert(0, text);

    try std.testing.expect(gb.gap_end > gb.gap_start);
    try std.testing.expect((gb.gap_end - gb.gap_start) >= MIN_GAP);
}

test "GapBuffer: posToOffset rejects column past line end" {
    var gb = try GapBuffer.init(std.testing.allocator);
    defer gb.deinit(std.testing.allocator);
    try gb.fromSlice("abc\ndef");

    try std.testing.expectEqual(@as(?usize, null), try gb.posToOffset(0, 4));
    try std.testing.expectEqual(@as(?usize, null), try gb.posToOffset(1, 4));
}
