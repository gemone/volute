const std = @import("std");
const TextStore = @import("storage.zig").TextStore;
const GapBuffer = @import("gap_buffer.zig").GapBuffer;
const TreeRope = @import("tree_rope.zig").TreeRope;

/// Backend selection strategy.
pub const Strategy = enum {
    /// GapBuffer: best for localized editing, search, memory efficiency.
    /// Default for files < 128 MB.
    gap_buffer,
    /// TreeRope: B+ tree with O(log n) operations.
    /// Used for large files (> 128 MB) where gap movement cost is significant.
    tree_rope,
    /// Auto-select based on file size and characteristics.
    auto,
};

/// Threshold above which TreeRope is preferred over GapBuffer.
const LARGE_FILE_THRESHOLD: usize = 128 * 1024 * 1024;

/// Create a TextStore with the given strategy and optional initial data.
pub fn create(allocator: std.mem.Allocator, strategy: Strategy, data: ?[]const u8) !TextStore {
    const backend: TextStore = switch (strategy) {
        .gap_buffer => {
            const gb = try allocator.create(GapBuffer);
            gb.* = try GapBuffer.init(allocator);
            gb.heap_allocated = true;
            if (data) |d| try gb.fromSlice(d);
            return gb.provider();
        },
        .tree_rope => {
            const rope = try allocator.create(TreeRope);
            rope.* = try TreeRope.init(allocator);
            rope.heap_allocated = true;
            if (data) |d| try rope.fromSlice(d);
            return rope.provider();
        },
        .auto => {
            const size = if (data) |d| d.len else 0;
            if (size > LARGE_FILE_THRESHOLD) {
                const rope = try allocator.create(TreeRope);
                rope.* = try TreeRope.init(allocator);
                rope.heap_allocated = true;
                if (data) |d| try rope.fromSlice(d);
                return rope.provider();
            } else {
                const gb = try allocator.create(GapBuffer);
                gb.* = try GapBuffer.init(allocator);
                gb.heap_allocated = true;
                if (data) |d| try gb.fromSlice(d);
                return gb.provider();
            }
        },
    };
    return backend;
}

/// Create a TextStore for a file of known size.
/// Uses auto strategy with size-based selection.
pub fn forFile(allocator: std.mem.Allocator, file_size: usize, data: ?[]const u8) !TextStore {
    const strategy: Strategy = if (file_size > LARGE_FILE_THRESHOLD) .tree_rope else .gap_buffer;
    return create(allocator, strategy, data);
}

test "factory: creates GapBuffer for small data" {
    const allocator = std.testing.allocator;
    const data = "hello world";
    var store = try create(allocator, .auto, data);
    defer store.deinit(allocator);

    try std.testing.expectEqual(data.len, store.len());
    try std.testing.expectEqual(@as(usize, 1), store.lineCount());
}

test "factory: can create TreeRope explicitly" {
    const allocator = std.testing.allocator;
    const data = "hello\nworld\n";
    var store = try create(allocator, .tree_rope, data);
    defer store.deinit(allocator);

    try std.testing.expectEqual(data.len, store.len());
    try std.testing.expectEqual(@as(usize, 3), store.lineCount());
}

test "factory: empty data creates empty store" {
    const allocator = std.testing.allocator;
    var store = try create(allocator, .auto, null);
    defer store.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), store.len());
    try std.testing.expectEqual(@as(usize, 1), store.lineCount());
}

test "factory: TreeRope getLine after create" {
    const allocator = std.testing.allocator;
    var store = try create(allocator, .tree_rope, "hello");
    defer store.deinit(allocator);
    
    var buf = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer buf.deinit(allocator);
    
    const line = (try store.getLine(0, &buf)).?;
    try std.testing.expectEqualStrings("hello", line);
}

test "factory: TextStore replaceFrom works across backends" {
    const allocator = std.testing.allocator;

    var gap_store = try create(allocator, .gap_buffer, "gap");
    defer gap_store.deinit(allocator);
    var rope_store = try create(allocator, .tree_rope, "tree\nrope");
    defer rope_store.deinit(allocator);

    try gap_store.replaceFrom(&rope_store);
    var buf = try std.ArrayList(u8).initCapacity(allocator, 16);
    defer buf.deinit(allocator);
    try std.testing.expectEqualStrings("tree", (try gap_store.getLine(0, &buf)).?);
    try std.testing.expectEqualStrings("rope", (try gap_store.getLine(1, &buf)).?);

    try rope_store.replaceFrom(&gap_store);
    buf.clearRetainingCapacity();
    try rope_store.writeToBuf(allocator, &buf);
    try std.testing.expectEqualStrings("tree\nrope", buf.items);
}
