const std = @import("std");
const Position = @import("../position.zig").Position;
const TextStore = @import("storage.zig").TextStore;
const LineRange = @import("storage.zig").LineRange;
const LineCache = @import("line_cache.zig").LineCache;

/// Maximum bytes per leaf chunk.
const CHUNK_SIZE: usize = 4096;

/// Branching factor for internal nodes.
const BRANCHING: usize = 16;

/// B+ tree rope with per-node text summaries.
///
/// Concurrency model (critical — must be understood by all backends):
///   All mutations (insert, delete) happen on the editor's main thread.
///   Read-only operations (len, charAt, getLine, offsetToPos, etc.)
///   are safe on any thread AFTER obtaining a snapshot via clone().
///
///   For async I/O (save-to-disk via std.Io on a background thread):
///   the Buffer calls clone() to get a snapshot TextStore, then passes
///   it to the writeTo() method which streams through *std.Io.Writer.
///   The writer itself carries the std.Io threading context.
///
///   This TreeRope implements incremental B+ tree mutations for O(log n)
///   insert/delete EDIT operations, while keeping the line cache as
///   a lazy-rebuilt performance optimization for O(1) position queries.
///
/// Reference (Zed sumtree):
///   Zed's SumTree<T> is a B+ tree where each node stores a typed
///   Summary that sums across children. A Cursor traverses along
///   registered Dimensions (byte offset, line/col, UTF-16) in O(log n).
///   This specialized text-only version tracks len + newlines + last_line_len.
pub const TreeRope = struct {
    const Self = @This();
    const NodeList = std.ArrayList(*Node);

    allocator: std.mem.Allocator,
    root: ?*Node,
    leaf_cache: std.ArrayList([]u8),
    leaf_cache_valid: bool,
    line_cache: LineCache(Self),
    heap_allocated: bool = false,

    const TextSummary = struct {
        len: usize,
        newlines: usize,
        last_line_len: usize,
    };

    const Node = struct {
        summary: TextSummary,
        tag: Tag,
        const Tag = union(enum) {
            leaf: Leaf,
            internal: Internal,
        };
        const Leaf = struct { data: []u8 };
        const Internal = struct {
            children: []*Node,
            child_summaries: []TextSummary,
        };
    };

    pub fn init(allocator: std.mem.Allocator) !Self {
        return .{
            .allocator = allocator,
            .root = null,
            .leaf_cache = try .initCapacity(allocator, 0),
            .leaf_cache_valid = false,
            .line_cache = try LineCache(Self).init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.root) |r| freeNode(r, self.allocator);
        self.leaf_cache.deinit(self.allocator);
        self.line_cache.deinit(self.allocator);
    }

    /// Destroy the TreeRope struct and all its allocations.
    /// Only call this if heap_allocated is true (set by factory).
    /// For stack-allocated TreeRopes, just call deinit().
    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        if (self.heap_allocated) {
            allocator.destroy(self);
        }
    }

    fn invalidateCaches(self: *Self) void {
        self.leaf_cache.clearRetainingCapacity();
        self.leaf_cache_valid = false;
        self.line_cache.invalidate();
    }

    fn freeNode(node: *Node, allocator: std.mem.Allocator) void {
        switch (node.tag) {
            .leaf => |l| allocator.free(l.data),
            .internal => |i| {
                for (i.children) |child| freeNode(child, allocator);
                allocator.free(i.children);
                allocator.free(i.child_summaries);
            },
        }
        allocator.destroy(node);
    }

    fn freeInternalShell(node: *Node, allocator: std.mem.Allocator) void {
        const internal = switch (node.tag) {
            .internal => |i| i,
            else => unreachable,
        };
        allocator.free(internal.children);
        allocator.free(internal.child_summaries);
        allocator.destroy(node);
    }

    fn summaryFromData(data: []const u8) TextSummary {
        return .{
            .len = data.len,
            .newlines = std.mem.count(u8, data, "\n"),
            .last_line_len = if (data.len == 0)
                0
            else if (std.mem.lastIndexOfScalar(u8, data, '\n')) |last_nl|
                data.len - last_nl - 1
            else
                data.len,
        };
    }

    fn appendSummary(prefix: TextSummary, suffix: TextSummary) TextSummary {
        if (prefix.len == 0) return suffix;
        if (suffix.len == 0) return prefix;
        return .{
            .len = prefix.len + suffix.len,
            .newlines = prefix.newlines + suffix.newlines,
            .last_line_len = if (suffix.newlines > 0)
                suffix.last_line_len
            else
                prefix.last_line_len + suffix.len,
        };
    }

    fn balancedGroupCount(total: usize, max_items_per_group: usize) usize {
        return (total + max_items_per_group - 1) / max_items_per_group;
    }

    fn balancedGroupSize(total: usize, group_count: usize, index: usize) usize {
        const base = total / group_count;
        const extra = total % group_count;
        return base + @as(usize, if (index < extra) 1 else 0);
    }

    fn allocLeafOwned(allocator: std.mem.Allocator, data: []u8) !*Node {
        const node = try allocator.create(Node);
        node.* = .{ .summary = summaryFromData(data), .tag = .{ .leaf = .{ .data = data } } };
        return node;
    }

    fn allocLeaf(allocator: std.mem.Allocator, data: []const u8) !*Node {
        const owned = try allocator.dupe(u8, data);
        errdefer allocator.free(owned);
        return allocLeafOwned(allocator, owned);
    }

    fn allocInternal(allocator: std.mem.Allocator, children_flat: []*Node) !*Node {
        const node = try allocator.create(Node);
        errdefer allocator.destroy(node);

        const children = try allocator.dupe(*Node, children_flat);
        errdefer allocator.free(children);

        const child_summaries = try allocator.alloc(TextSummary, children_flat.len);
        errdefer allocator.free(child_summaries);

        var sum = TextSummary{ .len = 0, .newlines = 0, .last_line_len = 0 };
        for (children_flat, 0..) |child, idx| {
            const summary = child.summary;
            child_summaries[idx] = summary;
            sum.len += summary.len;
            sum.newlines += summary.newlines;
            if (idx == children_flat.len - 1) sum.last_line_len = summary.last_line_len;
        }

        node.* = .{
            .summary = sum,
            .tag = .{
                .internal = .{
                    .children = children,
                    .child_summaries = child_summaries,
                },
            },
        };
        return node;
    }

    fn buildLeafNodes(self: *Self, data: []const u8) !NodeList {
        const leaf_count = if (data.len == 0) 0 else balancedGroupCount(data.len, CHUNK_SIZE);
        var leaves = try NodeList.initCapacity(self.allocator, leaf_count);
        errdefer {
            for (leaves.items) |leaf| freeNode(leaf, self.allocator);
            leaves.deinit(self.allocator);
        }

        if (data.len == 0) {
            return leaves;
        }

        const group_count = balancedGroupCount(data.len, CHUNK_SIZE);
        var start: usize = 0;
        for (0..group_count) |idx| {
            const size = balancedGroupSize(data.len, group_count, idx);
            const end = start + size;
            try leaves.append(self.allocator, try allocLeaf(self.allocator, data[start..end]));
            start = end;
        }
        return leaves;
    }

    fn buildInternalLayer(self: *Self, children: []*Node) !NodeList {
        if (children.len == 0) return try NodeList.initCapacity(self.allocator, 0);
        if (children.len == 1) {
            var single = try NodeList.initCapacity(self.allocator, 1);
            try single.append(self.allocator, children[0]);
            return single;
        }

        const group_count = balancedGroupCount(children.len, BRANCHING);
        var parents = try NodeList.initCapacity(self.allocator, group_count);
        errdefer {
            for (parents.items) |parent| freeInternalShell(parent, self.allocator);
            parents.deinit(self.allocator);
        }

        var start: usize = 0;
        for (0..group_count) |idx| {
            const size = balancedGroupSize(children.len, group_count, idx);
            const end = start + size;
            try parents.append(self.allocator, try allocInternal(self.allocator, children[start..end]));
            start = end;
        }
        return parents;
    }

    // ── Tree construction ──────────────────────────────────

    /// Load content from a byte slice (replaces all content).
    pub fn fromSlice(self: *Self, data: []const u8) !void {
        if (self.root) |r| {
            freeNode(r, self.allocator);
            self.root = null;
        }
        self.invalidateCaches();
        if (data.len == 0) return;

        var leaves = try self.buildLeafNodes(data);
        defer leaves.deinit(self.allocator);
        errdefer {
            for (leaves.items) |leaf| freeNode(leaf, self.allocator);
        }

        self.root = try buildBalanced(self.allocator, leaves.items);
    }

    fn buildBalanced(allocator: std.mem.Allocator, leaves: []*Node) !?*Node {
        if (leaves.len == 0) return null;
        if (leaves.len == 1) return leaves[0];

        var level = try std.ArrayList(*Node).initCapacity(allocator, leaves.len);
        defer level.deinit(allocator);
        try level.appendSlice(allocator, leaves);

        var next = try std.ArrayList(*Node).initCapacity(allocator, balancedGroupCount(leaves.len, BRANCHING));
        defer next.deinit(allocator);

        while (level.items.len > 1) {
            next.clearRetainingCapacity();
            const group_count = balancedGroupCount(level.items.len, BRANCHING);
            var start: usize = 0;
            for (0..group_count) |idx| {
                const size = balancedGroupSize(level.items.len, group_count, idx);
                const end = start + size;
                try next.append(allocator, try allocInternal(allocator, level.items[start..end]));
                start = end;
            }
            std.mem.swap(std.ArrayList(*Node), &level, &next);
        }

        return level.items[0];
    }

    // ── Core editing ───────────────────────────────────────

    pub fn len(self: *const Self) usize {
        return if (self.root) |r| r.summary.len else 0;
    }

    pub fn lineCount(self: *const Self) usize {
        return if (self.root) |r| r.summary.newlines + 1 else 1;
    }

    pub fn charAt(self: *Self, byte_offset: usize) ?u8 {
        var buf: [1]u8 = undefined;
        return if ((self.readChunk(byte_offset, &buf) catch 0) > 0) buf[0] else null;
    }

    fn findChildIndex(child_summaries: []const TextSummary, byte_offset: usize) struct { index: usize, offset: usize } {
        var cumulative: usize = 0;
        for (child_summaries, 0..) |summary, idx| {
            const child_end = cumulative + summary.len;
            if (byte_offset < child_end or idx == child_summaries.len - 1) {
                return .{ .index = idx, .offset = byte_offset - cumulative };
            }
            cumulative = child_end;
        }
        unreachable;
    }

    fn insertLeaf(self: *Self, leaf: *Node, byte_offset: usize, text: []const u8) !NodeList {
        const current = switch (leaf.tag) {
            .leaf => |l| l.data,
            else => unreachable,
        };
        const clamped = @min(byte_offset, current.len);

        const combined = try self.allocator.alloc(u8, current.len + text.len);
        defer self.allocator.free(combined);

        @memcpy(combined[0..clamped], current[0..clamped]);
        @memcpy(combined[clamped .. clamped + text.len], text);
        @memcpy(combined[clamped + text.len ..], current[clamped..]);

        var replacements = try self.buildLeafNodes(combined);
        errdefer {
            for (replacements.items) |node| freeNode(node, self.allocator);
            replacements.deinit(self.allocator);
        }

        freeNode(leaf, self.allocator);
        return replacements;
    }

    fn insertNode(self: *Self, node: *Node, byte_offset: usize, text: []const u8) !NodeList {
        return switch (node.tag) {
            .leaf => try self.insertLeaf(node, byte_offset, text),
            .internal => |internal| blk: {
                const target = findChildIndex(internal.child_summaries, byte_offset);
                var child_replacements = try self.insertNode(internal.children[target.index], target.offset, text);
                defer child_replacements.deinit(self.allocator);

                var merged = try NodeList.initCapacity(
                    self.allocator,
                    internal.children.len - 1 + child_replacements.items.len,
                );
                defer merged.deinit(self.allocator);

                try merged.appendSlice(self.allocator, internal.children[0..target.index]);
                try merged.appendSlice(self.allocator, child_replacements.items);
                try merged.appendSlice(self.allocator, internal.children[target.index + 1 ..]);

                freeInternalShell(node, self.allocator);
                errdefer {
                    for (merged.items) |child| freeNode(child, self.allocator);
                }

                break :blk try self.buildInternalLayer(merged.items);
            },
        };
    }

    fn deleteLeaf(self: *Self, leaf: *Node, byte_offset: usize, length: usize) !NodeList {
        const current = switch (leaf.tag) {
            .leaf => |l| l.data,
            else => unreachable,
        };
        const start = @min(byte_offset, current.len);
        const clamped = @min(length, current.len - start);

        if (clamped == 0) {
            var unchanged = try NodeList.initCapacity(self.allocator, 1);
            try unchanged.append(self.allocator, leaf);
            return unchanged;
        }

        const new_len = current.len - clamped;
        if (new_len == 0) {
            freeNode(leaf, self.allocator);
            return try NodeList.initCapacity(self.allocator, 0);
        }

        const new_data = try self.allocator.alloc(u8, new_len);
        defer self.allocator.free(new_data);

        if (start > 0) @memcpy(new_data[0..start], current[0..start]);
        @memcpy(new_data[start..], current[start + clamped ..]);

        var replacements = try self.buildLeafNodes(new_data);
        errdefer {
            for (replacements.items) |node| freeNode(node, self.allocator);
            replacements.deinit(self.allocator);
        }

        freeNode(leaf, self.allocator);
        return replacements;
    }

    fn tryMergeSiblings(self: *Self, left: *Node, right: *Node) !?*Node {
        switch (left.tag) {
            .leaf => |left_leaf| switch (right.tag) {
                .leaf => |right_leaf| {
                    const merged_len = left_leaf.data.len + right_leaf.data.len;
                    if (merged_len > CHUNK_SIZE) return null;

                    const merged = try self.allocator.alloc(u8, merged_len);
                    @memcpy(merged[0..left_leaf.data.len], left_leaf.data);
                    @memcpy(merged[left_leaf.data.len..], right_leaf.data);
                    const node = try allocLeafOwned(self.allocator, merged);
                    freeNode(left, self.allocator);
                    freeNode(right, self.allocator);
                    return node;
                },
                else => return null,
            },
            .internal => |left_internal| switch (right.tag) {
                .internal => |right_internal| {
                    const merged_len = left_internal.children.len + right_internal.children.len;
                    if (merged_len > BRANCHING) return null;

                    var children = try NodeList.initCapacity(self.allocator, merged_len);
                    defer children.deinit(self.allocator);
                    try children.appendSlice(self.allocator, left_internal.children);
                    try children.appendSlice(self.allocator, right_internal.children);

                    const node = try allocInternal(self.allocator, children.items);
                    freeInternalShell(left, self.allocator);
                    freeInternalShell(right, self.allocator);
                    return node;
                },
                else => return null,
            },
        }
    }

    fn compactChildren(self: *Self, children: []*Node) !NodeList {
        var compacted = try NodeList.initCapacity(self.allocator, children.len);
        errdefer {
            for (compacted.items) |child| freeNode(child, self.allocator);
            compacted.deinit(self.allocator);
        }

        for (children) |child| {
            if (compacted.items.len == 0) {
                try compacted.append(self.allocator, child);
                continue;
            }

            const previous = compacted.items[compacted.items.len - 1];
            if (try self.tryMergeSiblings(previous, child)) |merged| {
                _ = compacted.pop();
                try compacted.append(self.allocator, merged);
            } else {
                try compacted.append(self.allocator, child);
            }
        }

        return compacted;
    }

    fn deleteNode(self: *Self, node: *Node, byte_offset: usize, length: usize) !NodeList {
        return switch (node.tag) {
            .leaf => try self.deleteLeaf(node, byte_offset, length),
            .internal => |internal| blk: {
                const delete_start = byte_offset;
                const delete_end = byte_offset + length;

                var rewritten = try NodeList.initCapacity(self.allocator, internal.children.len);
                defer rewritten.deinit(self.allocator);

                var cumulative: usize = 0;
                for (internal.children, internal.child_summaries) |child, summary| {
                    const child_start = cumulative;
                    const child_end = child_start + summary.len;
                    cumulative = child_end;

                    if (delete_end <= child_start or delete_start >= child_end) {
                        try rewritten.append(self.allocator, child);
                        continue;
                    }

                    const overlap_start = @max(delete_start, child_start) - child_start;
                    const overlap_end = @min(delete_end, child_end) - child_start;
                    var child_replacements = try self.deleteNode(child, overlap_start, overlap_end - overlap_start);
                    defer child_replacements.deinit(self.allocator);
                    try rewritten.appendSlice(self.allocator, child_replacements.items);
                }

                freeInternalShell(node, self.allocator);
                errdefer {
                    for (rewritten.items) |child| freeNode(child, self.allocator);
                }

                var compacted = try self.compactChildren(rewritten.items);
                defer compacted.deinit(self.allocator);
                errdefer {
                    for (compacted.items) |child| freeNode(child, self.allocator);
                }

                if (compacted.items.len == 0) {
                    break :blk try NodeList.initCapacity(self.allocator, 0);
                }
                if (compacted.items.len == 1) {
                    var single = try NodeList.initCapacity(self.allocator, 1);
                    try single.append(self.allocator, compacted.items[0]);
                    break :blk single;
                }
                break :blk try self.buildInternalLayer(compacted.items);
            },
        };
    }

    /// Insert text at byte_offset using localized subtree rewrites.
    pub fn insert(self: *Self, byte_offset: usize, text: []const u8) !void {
        if (text.len == 0) return;

        var replacements = if (self.root) |root|
            try self.insertNode(root, @min(byte_offset, self.len()), text)
        else
            try self.buildLeafNodes(text);
        defer replacements.deinit(self.allocator);
        errdefer {
            for (replacements.items) |node| freeNode(node, self.allocator);
        }

        self.root = try buildBalanced(self.allocator, replacements.items);
        self.invalidateCaches();
    }

    /// Delete `length` bytes at `byte_offset` using localized subtree rewrites.
    pub fn delete(self: *Self, byte_offset: usize, length: usize) !void {
        if (length == 0 or self.root == null) return;

        const total = self.len();
        const clamped = @min(length, total -| byte_offset);
        if (clamped == 0) return;

        var replacements = try self.deleteNode(self.root.?, byte_offset, clamped);
        defer replacements.deinit(self.allocator);
        errdefer {
            for (replacements.items) |node| freeNode(node, self.allocator);
        }

        self.root = try buildBalanced(self.allocator, replacements.items);
        self.invalidateCaches();
    }

    // ── Leaf cache (for readChunk) ─────────────────────────

    fn ensureLeafCache(self: *Self) !void {
        if (self.leaf_cache_valid) return;
        self.leaf_cache.clearRetainingCapacity();
        if (self.root) |root| try collectLeaves(root, &self.leaf_cache, self.allocator);
        self.leaf_cache_valid = true;
    }

    fn collectLeaves(node: *Node, out: *std.ArrayList([]u8), allocator: std.mem.Allocator) !void {
        switch (node.tag) {
            .leaf => |l| try out.append(allocator, l.data),
            .internal => |i| {
                for (i.children) |child| try collectLeaves(child, out, allocator);
            },
        }
    }

    // ── Line cache ─────────────────────────────────────────

    /// Get byte at offset for line cache rebuilding.
    fn byteAt(self: *Self, offset: usize) ?u8 {
        var buf: [1]u8 = undefined;
        return if ((self.readChunk(offset, &buf) catch 0) > 0) buf[0] else null;
    }

    fn rebuildLineCache(self: *Self) !void {
        try self.line_cache.rebuild(self, self.allocator, byteAt, self.len());
    }

    fn ensureLineCache(self: *Self) !void {
        try self.line_cache.ensure(self, self.allocator, byteAt, self.len());
    }

    fn offsetAfterNthNewline(node: *Node, newline_index: usize) usize {
        std.debug.assert(newline_index < node.summary.newlines);
        switch (node.tag) {
            .leaf => |leaf| {
                var remaining = newline_index;
                var search_from: usize = 0;
                while (true) {
                    const relative = std.mem.indexOfScalarPos(u8, leaf.data, search_from, '\n').?;
                    if (remaining == 0) return relative;
                    remaining -= 1;
                    search_from = relative + 1;
                }
            },
            .internal => |internal| {
                var cumulative: usize = 0;
                var remaining = newline_index;
                for (internal.children, internal.child_summaries) |child, summary| {
                    if (remaining < summary.newlines) {
                        return cumulative + offsetAfterNthNewline(child, remaining);
                    }
                    remaining -= summary.newlines;
                    cumulative += summary.len;
                }
                unreachable;
            },
        }
    }

    fn lineStartOffset(self: *const Self, line: usize) ?usize {
        if (line == 0) return 0;
        const root = self.root orelse return null;
        if (line > root.summary.newlines) return null;
        return offsetAfterNthNewline(root, line - 1) + 1;
    }

    fn prefixSummary(node: *Node, byte_count: usize) TextSummary {
        if (byte_count == 0) return .{ .len = 0, .newlines = 0, .last_line_len = 0 };
        if (byte_count >= node.summary.len) return node.summary;

        switch (node.tag) {
            .leaf => |leaf| return summaryFromData(leaf.data[0..byte_count]),
            .internal => |internal| {
                var prefix = TextSummary{ .len = 0, .newlines = 0, .last_line_len = 0 };
                var remaining = byte_count;
                for (internal.children, internal.child_summaries) |child, summary| {
                    if (remaining == 0) break;
                    if (remaining >= summary.len) {
                        prefix = appendSummary(prefix, summary);
                        remaining -= summary.len;
                        continue;
                    }
                    prefix = appendSummary(prefix, prefixSummary(child, remaining));
                    break;
                }
                return prefix;
            },
        }
    }

    pub fn lineByteRange(self: *Self, line: usize) !?LineRange {
        const start = self.lineStartOffset(line) orelse return null;
        const end = if (line + 1 < self.lineCount())
            self.lineStartOffset(line + 1).?
        else
            self.len();
        return .{ .start = start, .end = end };
    }

    pub fn getLine(self: *Self, line: usize, buf: *std.ArrayList(u8)) !?[]const u8 {
        const start = self.lineStartOffset(line) orelse return null;
        const end = if (line + 1 < self.lineCount())
            self.lineStartOffset(line + 1).?
        else
            self.len();

        buf.clearRetainingCapacity();
        if (start >= end or self.root == null) return buf.items;
        try appendNodeRange(self.root.?, start, end, self.allocator, buf);
        if (buf.items.len > 0 and buf.items[buf.items.len - 1] == '\n') {
            buf.items.len -= 1;
        }
        return buf.items;
    }

    fn appendNodeRange(node: *Node, start: usize, end: usize, allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        if (start >= end) return;
        switch (node.tag) {
            .leaf => |leaf| try buf.appendSlice(allocator, leaf.data[start..end]),
            .internal => |internal| {
                var cumulative: usize = 0;
                for (internal.children, internal.child_summaries) |child, summary| {
                    const child_start = cumulative;
                    const child_end = child_start + summary.len;
                    cumulative = child_end;

                    if (end <= child_start) break;
                    if (start >= child_end) continue;

                    const local_start = start -| child_start;
                    const local_end = @min(end, child_end) - child_start;
                    try appendNodeRange(child, local_start, local_end, allocator, buf);
                }
            },
        }
    }

    fn copyNodeRange(node: *Node, start: usize, end: usize, out: []u8, copied: *usize) void {
        if (start >= end or copied.* >= out.len) return;
        switch (node.tag) {
            .leaf => |leaf| {
                const slice = leaf.data[start..end];
                @memcpy(out[copied.*..][0..slice.len], slice);
                copied.* += slice.len;
            },
            .internal => |internal| {
                var cumulative: usize = 0;
                for (internal.children, internal.child_summaries) |child, summary| {
                    const child_start = cumulative;
                    const child_end = child_start + summary.len;
                    cumulative = child_end;

                    if (end <= child_start or copied.* >= out.len) break;
                    if (start >= child_end) continue;

                    const local_start = start -| child_start;
                    const local_end = @min(end, child_end) - child_start;
                    copyNodeRange(child, local_start, local_end, out, copied);
                }
            },
        }
    }

    pub fn posToOffset(self: *Self, row: usize, col: usize) !?usize {
        const start = self.lineStartOffset(row) orelse return null;
        const max_col = try self.lineLengthNoNewline(row);
        if (col > max_col) return null;
        return start + col;
    }

    pub fn offsetToPos(self: *Self, offset: usize) !Position {
        if (self.len() == 0) return .{};
        const clamped = @min(offset, self.len());
        const root = self.root orelse return .{};
        const prefix = prefixSummary(root, clamped);
        return .{ .row = prefix.newlines, .col = prefix.last_line_len };
    }

    // ── Serialization ──────────────────────────────────────

    pub fn writeTo(self: *Self, w: *std.Io.Writer) !void {
        if (self.root) |root| try writeNode(root, w);
    }

    pub fn writeToBuf(self: *const Self, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        if (self.root) |root| try appendNodeAll(root, gpa, buf);
    }

    fn writeNode(node: *Node, w: *std.Io.Writer) !void {
        switch (node.tag) {
            .leaf => |leaf| try w.writeAll(leaf.data),
            .internal => |internal| for (internal.children) |child| try writeNode(child, w),
        }
    }

    fn appendNodeAll(node: *Node, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        switch (node.tag) {
            .leaf => |leaf| try buf.appendSlice(gpa, leaf.data),
            .internal => |internal| for (internal.children) |child| try appendNodeAll(child, gpa, buf),
        }
    }

    fn borrowAll(self: *Self, gpa: std.mem.Allocator) ![]u8 {
        var buf = try std.ArrayList(u8).initCapacity(gpa, 16);
        defer buf.deinit(gpa);
        try self.writeToBuf(gpa, &buf);
        return try buf.toOwnedSlice(gpa);
    }

    // ── Snapshot & restore ─────────────────────────────────

    pub fn clone(self: *Self, gpa: std.mem.Allocator) !TextStore {
        const new_rope = try gpa.create(Self);
        new_rope.* = try Self.init(gpa);
        new_rope.heap_allocated = true;
        errdefer {
            new_rope.deinit(gpa);
            gpa.destroy(new_rope);
        }
        if (self.root) |root| new_rope.root = try cloneNode(root, gpa);
        new_rope.line_cache.invalidate();
        new_rope.leaf_cache_valid = false;
        return new_rope.provider();
    }

    fn cloneNode(node: *const Node, allocator: std.mem.Allocator) !*Node {
        var new = try allocator.create(Node);
        new.* = .{ .summary = node.summary, .tag = undefined };
        switch (node.tag) {
            .leaf => |l| new.tag = .{ .leaf = .{ .data = try allocator.dupe(u8, l.data) } },
            .internal => |i| {
                var children = try allocator.alloc(*Node, i.children.len);
                for (i.children, 0..) |child, idx| children[idx] = try cloneNode(child, allocator);
                new.tag = .{ .internal = .{
                    .children = children,
                    .child_summaries = try allocator.dupe(TextSummary, i.child_summaries),
                } };
            },
        }
        return new;
    }

    pub fn replaceFrom(self: *Self, other: *const Self) !void {
        if (self.root) |r| {
            freeNode(r, self.allocator);
            self.root = null;
        }
        if (other.root) |root| self.root = try cloneNode(root, self.allocator);
        self.invalidateCaches();
    }

    // ── Tree-sitter integration ────────────────────────────

    /// Read up to `buf.len` bytes starting at `byte_offset`.
    /// Returns number of bytes actually read (0 at EOF).
    /// Uses the leaf cache for O(n_leaves) traversal, which is
    /// fine for tree-sitter's typical chunk size (~4K-64K).
    pub fn readChunk(self: *Self, byte_offset: usize, buf: []u8) !usize {
        if (self.root == null or buf.len == 0) return 0;
        const total = self.len();
        if (byte_offset >= total) return 0;

        const to_read = @min(buf.len, total - byte_offset);
        var copied: usize = 0;
        copyNodeRange(self.root.?, byte_offset, byte_offset + to_read, buf[0..to_read], &copied);
        return copied;
    }

    // ── TextStore vtable ───────────────────────────────────

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

fn expectRopeContent(rope: *TreeRope, expected: []const u8) !void {
    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, expected.len + 16);
    defer buf.deinit(std.testing.allocator);
    try rope.writeToBuf(std.testing.allocator, &buf);
    try std.testing.expectEqualStrings(expected, buf.items);
}

fn expectTreeRopeSingleLineState(rope: *TreeRope, expected: []const u8) !void {
    try std.testing.expectEqual(expected.len, rope.len());
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(?u8, null), rope.charAt(expected.len));
    try expectRopeContent(rope, expected);

    var line_buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, expected.len + 8);
    defer line_buf.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(expected, (try rope.getLine(0, &line_buf)).?);

    const mid = expected.len / 2;
    try std.testing.expectEqual(@as(?usize, 0), try rope.posToOffset(0, 0));
    try std.testing.expectEqual(@as(?usize, mid), try rope.posToOffset(0, mid));
    try std.testing.expectEqual(@as(?usize, expected.len), try rope.posToOffset(0, expected.len));

    const origin = try rope.offsetToPos(0);
    try std.testing.expectEqual(@as(usize, 0), origin.row);
    try std.testing.expectEqual(@as(usize, 0), origin.col);

    const mid_pos = try rope.offsetToPos(mid);
    try std.testing.expectEqual(@as(usize, 0), mid_pos.row);
    try std.testing.expectEqual(mid, mid_pos.col);

    const end_pos = try rope.offsetToPos(expected.len);
    try std.testing.expectEqual(@as(usize, 0), end_pos.row);
    try std.testing.expectEqual(expected.len, end_pos.col);

    if (expected.len > 0) {
        try std.testing.expectEqual(expected[0], rope.charAt(0).?);
        try std.testing.expectEqual(expected[mid], rope.charAt(mid).?);
        try std.testing.expectEqual(expected[expected.len - 1], rope.charAt(expected.len - 1).?);
    }
}

test "TreeRope: fromSlice and basic reads" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello world");

    try std.testing.expectEqual(@as(usize, 11), rope.len());
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(u8, 'h'), rope.charAt(0).?);
    try std.testing.expectEqual(@as(u8, 'd'), rope.charAt(10).?);
}

test "TreeRope: insert and read back" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("he world");
    try rope.insert(2, "llo");
    try expectTreeRopeSingleLineState(&rope, "hello world");
}

test "TreeRope: insert at end" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("hello");
    try rope.insert(5, " world");
    try expectTreeRopeSingleLineState(&rope, "hello world");
}

test "TreeRope: insert at beginning" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("world");
    try rope.insert(0, "hello ");
    try expectTreeRopeSingleLineState(&rope, "hello world");
}

test "TreeRope: repeated insertions at head" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("tail");
    try rope.insert(0, "-");
    try rope.insert(0, "mid");
    try rope.insert(0, "head-");

    try expectTreeRopeSingleLineState(&rope, "head-mid-tail");
}

test "TreeRope: repeated insertions in middle" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("AH");
    try rope.insert(1, "D");
    try rope.insert(1, "BC");
    try rope.insert(4, "EFG");

    try expectTreeRopeSingleLineState(&rope, "ABCDEFGH");
}

test "TreeRope: repeated insertions at tail" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("head");
    try rope.insert(rope.len(), "-");
    try rope.insert(rope.len(), "mid");
    try rope.insert(rope.len(), "-tail");

    try expectTreeRopeSingleLineState(&rope, "head-mid-tail");
}

test "TreeRope: mixed repeated insertion sequence" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("core");
    try rope.insert(0, "start-");
    try rope.insert(rope.len(), "-end");
    try rope.insert(6, "mid-");
    try rope.insert(0, "[");
    try rope.insert(rope.len(), "]");

    try expectTreeRopeSingleLineState(&rope, "[start-mid-core-end]");
}

test "TreeRope: delete from middle" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try rope.fromSlice("hello world");
    try rope.delete(5, 1);
    try std.testing.expectEqual(@as(usize, 10), rope.len());
    try std.testing.expectEqual(@as(u8, 'w'), rope.charAt(5).?);
}

test "TreeRope: localized insert keeps untouched leaves" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, CHUNK_SIZE * 3);
    defer allocator.free(data);
    @memset(data[0..CHUNK_SIZE], 'a');
    @memset(data[CHUNK_SIZE .. CHUNK_SIZE * 2], 'b');
    @memset(data[CHUNK_SIZE * 2 ..], 'c');
    try rope.fromSlice(data);
    try rope.ensureLeafCache();

    const first_ptr = rope.leaf_cache.items[0].ptr;
    const last_ptr = rope.leaf_cache.items[2].ptr;

    try rope.insert(CHUNK_SIZE + 10, "XYZ");
    try rope.ensureLeafCache();

    try std.testing.expectEqual(first_ptr, rope.leaf_cache.items[0].ptr);
    try std.testing.expectEqual(last_ptr, rope.leaf_cache.items[rope.leaf_cache.items.len - 1].ptr);

    var expected = try std.ArrayList(u8).initCapacity(allocator, data.len + 3);
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, data[0 .. CHUNK_SIZE + 10]);
    try expected.appendSlice(std.testing.allocator, "XYZ");
    try expected.appendSlice(allocator, data[CHUNK_SIZE + 10 ..]);
    try expectRopeContent(&rope, expected.items);
}

test "TreeRope: localized delete keeps untouched leaves" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    const allocator = std.testing.allocator;
    const data = try allocator.alloc(u8, CHUNK_SIZE * 3);
    defer allocator.free(data);
    @memset(data[0..CHUNK_SIZE], 'a');
    @memset(data[CHUNK_SIZE .. CHUNK_SIZE * 2], 'b');
    @memset(data[CHUNK_SIZE * 2 ..], 'c');
    try rope.fromSlice(data);
    try rope.ensureLeafCache();

    const first_ptr = rope.leaf_cache.items[0].ptr;
    const last_ptr = rope.leaf_cache.items[2].ptr;

    try rope.delete(CHUNK_SIZE + 8, 12);
    try rope.ensureLeafCache();

    try std.testing.expectEqual(first_ptr, rope.leaf_cache.items[0].ptr);
    try std.testing.expectEqual(last_ptr, rope.leaf_cache.items[rope.leaf_cache.items.len - 1].ptr);

    var expected = try std.ArrayList(u8).initCapacity(allocator, data.len);
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, data[0 .. CHUNK_SIZE + 8]);
    try expected.appendSlice(allocator, data[CHUNK_SIZE + 20 ..]);
    try expectRopeContent(&rope, expected.items);
}

test "TreeRope: summary queries work while caches stay invalid after edits" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("alpha\nbeta\ngamma");

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);

    try rope.ensureLeafCache();
    try rope.rebuildLineCache();
    try std.testing.expect(rope.line_cache.isValid());
    try std.testing.expect(rope.leaf_cache_valid);

    try rope.insert(5, "\nmid");
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);
    try std.testing.expectEqual(@as(usize, 4), rope.lineCount());
    try std.testing.expectEqualStrings("mid", (try rope.getLine(1, &buf)).?);
    try std.testing.expectEqual(@as(?usize, 10), try rope.posToOffset(2, 0));
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, try rope.offsetToPos(10));
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);

    try rope.delete(5, 4);
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);
    try std.testing.expectEqual(@as(usize, 3), rope.lineCount());
    try std.testing.expectEqualStrings("beta", (try rope.getLine(1, &buf)).?);
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);
}

test "TreeRope: fromSlice empty clears caches" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello\nworld");

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    _ = try rope.getLine(0, &buf);
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);

    try rope.fromSlice("");
    try std.testing.expectEqual(@as(usize, 0), rope.len());
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expect(!rope.line_cache.isValid());
    try std.testing.expect(!rope.leaf_cache_valid);
    try rope.ensureLeafCache();
    try std.testing.expectEqual(@as(usize, 0), rope.leaf_cache.items.len);
}

test "TreeRope: line operations" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("abc\ndef\nghi");

    try std.testing.expectEqual(@as(usize, 3), rope.lineCount());

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    const line0 = (try rope.getLine(0, &buf)).?;
    try std.testing.expectEqualStrings("abc", line0);
    const line1 = (try rope.getLine(1, &buf)).?;
    try std.testing.expectEqualStrings("def", line1);
}

test "TreeRope: position conversion" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello\nworld\n");

    const off = (try rope.posToOffset(1, 2)).?;
    try std.testing.expectEqual(@as(usize, 8), off);

    const pos = try rope.offsetToPos(8);
    try std.testing.expectEqual(@as(usize, 1), pos.row);
    try std.testing.expectEqual(@as(usize, 2), pos.col);
}

test "TreeRope: clone preserves content" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("clone test data");

    var cloned = try rope.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 15), cloned.len());
}

test "TreeRope: readChunk" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello world");

    var buf: [5]u8 = undefined;
    const n = try rope.readChunk(0, &buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
}

test "TreeRope: readChunk partial" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello world");

    var buf: [64]u8 = undefined;
    const n = try rope.readChunk(3, &buf);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualStrings("lo world", buf[0..n]);
}

test "TreeRope: readChunk crosses leaf boundary" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    const data = ("a" ** (CHUNK_SIZE - 2)) ++ "bcdef";
    try rope.fromSlice(data);

    var buf: [8]u8 = undefined;
    const n = try rope.readChunk(CHUNK_SIZE - 4, &buf);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqualStrings("aabcdef", buf[0..n]);
}

test "TreeRope: writeToBuf" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("hello tree rope");

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    try rope.writeToBuf(std.testing.allocator, &buf);

    try std.testing.expectEqualStrings("hello tree rope", buf.items);
}

test "TreeRope: empty rope" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), rope.len());
    try std.testing.expectEqual(@as(usize, 1), rope.lineCount());
    try std.testing.expectEqual(@as(?u8, null), rope.charAt(0));
}

test "TreeRope: multi-line content" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);

    var data = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer data.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try data.appendSlice(std.testing.allocator, "line ");
        try data.appendSlice(std.testing.allocator, "A");
        try data.appendSlice(std.testing.allocator, "\n");
    }
    try rope.fromSlice(data.items);

    try std.testing.expectEqual(@as(usize, 501), rope.lineCount());
    try std.testing.expect(data.items.len > 0);
}

test "TreeRope: clone creates independent copy" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("original");

    var cloned = try rope.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    const cloned_len = cloned.len();
    try std.testing.expectEqual(@as(usize, 8), cloned_len);

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    const result = (try cloned.getLine(0, &buf)).?;
    try std.testing.expectEqualStrings("original", result);
}

test "TreeRope: replaceFrom restores content" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("original");

    var other = try TreeRope.init(std.testing.allocator);
    defer other.deinit(std.testing.allocator);
    try other.fromSlice("replacement");

    try rope.replaceFrom(&other);
    try std.testing.expectEqual(@as(usize, 0), rope.leaf_cache.items.len);

    var buf = try std.ArrayList(u8).initCapacity(std.testing.allocator, 16);
    defer buf.deinit(std.testing.allocator);
    try rope.writeToBuf(std.testing.allocator, &buf);
    try std.testing.expectEqualStrings("replacement", buf.items);
}

test "TreeRope: posToOffset rejects column past line end" {
    var rope = try TreeRope.init(std.testing.allocator);
    defer rope.deinit(std.testing.allocator);
    try rope.fromSlice("abc\ndef");

    try std.testing.expectEqual(@as(?usize, null), try rope.posToOffset(0, 4));
    try std.testing.expectEqual(@as(?usize, null), try rope.posToOffset(1, 4));
}
