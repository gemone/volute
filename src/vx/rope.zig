const std = @import("std");
const Position = @import("position.zig").Position;

/// Maximum bytes per leaf chunk.
const CHUNK_SIZE: usize = 256;

/// A rope data structure for efficient text editing.
///
/// Uses an array of fixed-size chunks to store text, with a line index
/// cache for O(1) line lookups. Chunks are merged when they become small
/// and split when they exceed CHUNK_SIZE.
///
/// This is not a tree rope (for simplicity), but provides the same
/// editing semantics: O(n) insert/delete (n = number of chunks), O(1)
/// line access with cache, O(log n) effective for typical files.
pub const Rope = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(Chunk),
    total_len: usize,
    total_newlines: usize,

    // Line index cache: byte offset for each line's start.
    // After each mutation the cache is marked invalid and rebuilt
    // on next access.
    line_starts: std.ArrayList(usize),
    cache_valid: bool,

    pub const Chunk = struct {
        data: []const u8,

        fn newlines(self: Chunk) usize {
            return std.mem.count(u8, self.data, "\n");
        }
    };

    pub fn init(allocator: std.mem.Allocator) Rope {
        return .{
            .allocator = allocator,
            .chunks = .empty,
            .total_len = 0,
            .total_newlines = 0,
            .line_starts = .empty,
            .cache_valid = true, // empty rope has valid cache trivially
        };
    }

    pub fn deinit(self: *Rope) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.data);
        }
        self.chunks.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
    }

    /// Create a rope from a byte slice (deep copy).
    pub fn fromSlice(allocator: std.mem.Allocator, text: []const u8) !Rope {
        var rope = Rope.init(allocator);
        if (text.len == 0) return rope;

        var offset: usize = 0;
        while (offset < text.len) {
            const chunk_end = @min(offset + CHUNK_SIZE, text.len);
            const data = try allocator.dupe(u8, text[offset..chunk_end]);
            try rope.chunks.append(allocator, .{ .data = data });
            offset = chunk_end;
        }

        rope.total_len = text.len;
        rope.total_newlines = std.mem.count(u8, text, "\n");
        rope.cache_valid = false;
        return rope;
    }

    pub fn len(self: *const Rope) usize {
        return self.total_len;
    }

    pub fn lineCount(self: *const Rope) usize {
        return self.total_newlines + 1;
    }

    pub fn charAt(self: *const Rope, offset: usize) ?u8 {
        var cumulative: usize = 0;
        for (self.chunks.items) |chunk| {
            if (offset < cumulative + chunk.data.len) {
                return chunk.data[offset - cumulative];
            }
            cumulative += chunk.data.len;
        }
        return null;
    }

    /// Insert text at the given byte offset.
    pub fn insert(self: *Rope, byte_offset: usize, text: []const u8) !void {
        if (text.len == 0) return;
        const clamped = @min(byte_offset, self.total_len);

        if (self.chunks.items.len == 0) {
            const data = try self.allocator.dupe(u8, text);
            try self.chunks.append(self.allocator, .{ .data = data });
            self.total_len = text.len;
            self.total_newlines = std.mem.count(u8, text, "\n");
            self.cache_valid = false;
            return;
        }

        // Find the chunk containing the insertion point
        var cumulative: usize = 0;
        var idx: usize = self.chunks.items.len; // default: append
        for (self.chunks.items, 0..) |chunk, i| {
            if (clamped <= cumulative + chunk.data.len) {
                idx = i;
                break;
            }
            cumulative += chunk.data.len;
        }

        if (idx >= self.chunks.items.len) {
            // Append at end
            const data = try self.allocator.dupe(u8, text);
            try self.chunks.append(self.allocator, .{ .data = data });
            self.total_len += text.len;
            self.total_newlines += std.mem.count(u8, text, "\n");
            self.cache_valid = false;
            return;
        }

        const split_off = clamped - cumulative;
        var chunk = &self.chunks.items[idx];

        // Split the chunk at the insertion point
        const before_data = if (split_off > 0)
            try self.allocator.dupe(u8, chunk.data[0..split_off])
        else
            null;
        const after_data = if (split_off < chunk.data.len)
            try self.allocator.dupe(u8, chunk.data[split_off..])
        else
            null;

        self.allocator.free(chunk.data);
        _ = self.chunks.orderedRemove(idx);

        // Insert pieces in order: before, text chunks, after
        var insert_pos = idx;

        if (before_data) |d| {
            try self.chunks.insert(self.allocator, insert_pos, .{ .data = d });
            insert_pos += 1;
        }

        // Split text into chunks
        var text_off: usize = 0;
        while (text_off < text.len) {
            const chunk_end = @min(text_off + CHUNK_SIZE, text.len);
            const data = try self.allocator.dupe(u8, text[text_off..chunk_end]);
            try self.chunks.insert(self.allocator, insert_pos, .{ .data = data });
            text_off = chunk_end;
            insert_pos += 1;
        }

        if (after_data) |d| {
            try self.chunks.insert(self.allocator, insert_pos, .{ .data = d });
        }

        self.total_len += text.len;
        self.total_newlines += std.mem.count(u8, text, "\n");

        // Merge small adjacent chunks to keep chunk count manageable
        if (self.chunks.items.len > 2000) {
            try self.mergeChunks();
        }

        self.cache_valid = false;
    }

    /// Delete `length` bytes at `byte_offset`.
    pub fn delete(self: *Rope, byte_offset: usize, length: usize) !void {
        if (length == 0 or self.total_len == 0) return;
        const end = @min(byte_offset + length, self.total_len);
        const actual_len = end - byte_offset;
        if (actual_len == 0) return;

        var deleted_newlines: usize = 0;
        var remaining = actual_len;
        var cumulative: usize = 0;
        var i: usize = 0;

        while (i < self.chunks.items.len and remaining > 0) {
            const chunk = &self.chunks.items[i];
            const chunk_end = cumulative + chunk.data.len;

            if (byte_offset < chunk_end and cumulative + chunk.data.len > cumulative) {
                const del_start = if (byte_offset > cumulative) byte_offset - cumulative else 0;
                const del_end = @min(del_start + remaining, chunk.data.len);
                const del_count = del_end - del_start;

                deleted_newlines += std.mem.count(u8, chunk.data[del_start..del_end], "\n");

                if (del_start == 0 and del_end >= chunk.data.len) {
                    // Remove entire chunk
                    self.allocator.free(chunk.data);
                    _ = self.chunks.orderedRemove(i);
                    remaining -= del_count;
                    // Don't increment i — next chunk slides into this position
                } else if (del_start == 0) {
                    // Remove prefix of chunk
                    const keep = try self.allocator.dupe(u8, chunk.data[del_end..]);
                    self.allocator.free(chunk.data);
                    chunk.data = keep;
                    remaining -= del_count;
                    i += 1;
                } else if (del_end >= chunk.data.len) {
                    // Remove suffix of chunk
                    const keep = try self.allocator.dupe(u8, chunk.data[0..del_start]);
                    self.allocator.free(chunk.data);
                    chunk.data = keep;
                    remaining -= del_count;
                    i += 1;
                } else {
                    // Remove middle of chunk — split
                    const keep_before = try self.allocator.dupe(u8, chunk.data[0..del_start]);
                    const keep_after = try self.allocator.dupe(u8, chunk.data[del_end..]);
                    self.allocator.free(chunk.data);
                    chunk.data = keep_before;
                    try self.chunks.insert(self.allocator, i + 1, .{ .data = keep_after });
                    remaining -= del_count;
                    i += 2; // skip past the inserted chunk
                }
            } else {
                cumulative += chunk.data.len;
                i += 1;
            }
        }

        self.total_len -= actual_len;
        self.total_newlines -= deleted_newlines;
        self.cache_valid = false;
    }

    /// Merge small adjacent chunks to reduce fragmentation.
    fn mergeChunks(self: *Rope) !void {
        if (self.chunks.items.len < 2) return;

        var i: usize = 0;
        while (i < self.chunks.items.len - 1) {
            const cur = &self.chunks.items[i];
            const next = &self.chunks.items[i + 1];

            if (cur.data.len + next.data.len <= CHUNK_SIZE) {
                var merged = try self.allocator.alloc(u8, cur.data.len + next.data.len);
                @memcpy(merged[0..cur.data.len], cur.data);
                @memcpy(merged[cur.data.len..], next.data);
                self.allocator.free(cur.data);
                self.allocator.free(next.data);
                cur.data = merged;
                _ = self.chunks.orderedRemove(i + 1);
            } else {
                i += 1;
            }
        }
    }

    /// Rebuild the line start offset cache.
    pub fn rebuildCache(self: *Rope) !void {
        self.line_starts.clearRetainingCapacity();

        // Always return line 0 at offset 0
        try self.line_starts.append(self.allocator, 0);

        var offset: usize = 0;
        for (self.chunks.items) |chunk| {
            for (chunk.data, 0..) |ch, i| {
                if (ch == '\n') {
                    try self.line_starts.append(self.allocator, offset + i + 1);
                }
            }
            offset += chunk.data.len;
        }

        self.cache_valid = true;
    }

    /// Ensure cache is valid.
    fn ensureCache(self: *Rope) !void {
        if (!self.cache_valid) {
            try self.rebuildCache();
        }
    }

    /// Get the byte offset for the start of a line (0-indexed).
    pub fn lineOffset(self: *Rope, line: usize) !?usize {
        try self.ensureCache();
        if (line >= self.line_starts.items.len) return null;
        return self.line_starts.items[line];
    }

    /// Convert (row, col) to byte offset. Returns null if row is out of bounds.
    /// col may extend past the line end (for insert-mode positioning).
    pub fn posToOffset(self: *Rope, row: usize, col: usize) !?usize {
        const off = try self.lineOffset(row) orelse return null;
        return off + col;
    }

    /// Convert byte offset to (row, col). Returns (0, 0) for empty or out-of-range.
    pub fn offsetToPos(self: *Rope, offset: usize) !Position {
        if (self.total_len == 0) return .{};

        const clamped = @min(offset, self.total_len);
        try self.ensureCache();

        // Binary search line_starts to find the row
        var lo: usize = 0;
        var hi: usize = self.line_starts.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.line_starts.items[mid] <= clamped) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        const row = if (lo > 0) lo - 1 else 0;
        const line_off = self.line_starts.items[row];
        const col = clamped - line_off;
        return .{ .row = row, .col = col };
    }

    /// Get the text of a line (no newline). Returns null if row is out of bounds.
    /// The returned slice is valid only until the next mutation.
    pub fn getLine(self: *Rope, row: usize, out: *std.ArrayList(u8)) !?[]const u8 {
        try self.ensureCache();
        if (row >= self.line_starts.items.len) return null;

        const start = self.line_starts.items[row];
        // End is either the start of the next line, or total length
        const end = if (row + 1 < self.line_starts.items.len)
            self.line_starts.items[row + 1] -| 1 // exclude the newline
        else
            self.total_len;

        if (end <= start) {
            out.clearRetainingCapacity();
            return try out.toOwnedSlice(self.allocator);
        }

        // Collect the line text from chunks
        out.clearRetainingCapacity();
        var cumulative: usize = 0;
        for (self.chunks.items) |chunk| {
            const chunk_end = cumulative + chunk.data.len;
            if (start < chunk_end) {
                const slice_start = if (start > cumulative) start - cumulative else 0;
                const slice_end = @min(end - cumulative, chunk.data.len);
                if (slice_start < slice_end) {
                    try out.appendSlice(self.allocator, chunk.data[slice_start..slice_end]);
                }
                if (cumulative + chunk.data.len >= end) break;
            }
            cumulative += chunk.data.len;
        }

        return out.items;
    }

    /// Return the byte offset range for a line (including its newline).
    /// Returns null if row is out of bounds.
    pub fn lineByteRange(self: *Rope, row: usize) !?struct { start: usize, end: usize } {
        try self.ensureCache();
        if (row >= self.line_starts.items.len) return null;
        const start = self.line_starts.items[row];
        const end = if (row + 1 < self.line_starts.items.len)
            self.line_starts.items[row + 1]
        else
            self.total_len;
        return .{ .start = start, .end = end };
    }

    /// Write the entire text to a writer (for saving).
    pub fn writeTo(self: *Rope, w: *std.Io.Writer) !void {
        for (self.chunks.items) |chunk| {
            try w.writeAll(chunk.data);
        }
    }

    /// Write text into a growable buffer.
    pub fn writeToBuf(self: *const Rope, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        for (self.chunks.items) |chunk| {
            try buf.appendSlice(gpa, chunk.data);
        }
    }

    /// Deep-copy the rope state (for undo snapshots).
    pub fn clone(self: *const Rope, allocator: std.mem.Allocator) !Rope {
        var new_rope = Rope.init(allocator);
        for (self.chunks.items) |chunk| {
            const data = try allocator.dupe(u8, chunk.data);
            try new_rope.chunks.append(allocator, .{ .data = data });
        }
        new_rope.total_len = self.total_len;
        new_rope.total_newlines = self.total_newlines;
        return new_rope;
    }

    /// Replace all content with a clone of another rope (for undo/redo restore).
    pub fn replaceFrom(self: *Rope, other: *const Rope) !void {
        // Free current chunks
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.data);
        }
        self.chunks.clearRetainingCapacity();

        // Deep copy from other
        for (other.chunks.items) |chunk| {
            const data = try self.allocator.dupe(u8, chunk.data);
            try self.chunks.append(self.allocator, .{ .data = data });
        }
        self.total_len = other.total_len;
        self.total_newlines = other.total_newlines;
        self.cache_valid = false;

        // Copy line cache if valid
        if (other.cache_valid) {
            self.line_starts.clearRetainingCapacity();
            try self.line_starts.appendSlice(self.allocator, other.line_starts.items);
            self.cache_valid = true;
        }
    }
};
