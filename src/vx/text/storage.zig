const std = @import("std");
const Position = @import("../position.zig").Position;

/// Byte range for a line (includes trailing newline).
pub const LineRange = struct {
    start: usize,
    end: usize,
};

/// Vtable-based TextStore interface.
///
/// Unified abstraction over GapBuffer, TreeRope, and future backends
/// (mmap, encrypted, remote, etc.). Inspired by the SumTree pattern
/// from Zed (B+ tree with composable summaries) and ropey from Helix.
///
/// Design notes (Zed sumtree reference):
///   - Zed's SumTree<T> is a B+ tree where each node stores a typed
///     Summary that can be summed across children. A cursor traverses
///     along any registered Dimension (byte offset, line/col, UTF-16).
///   - This TextStore interface exposes the common text operations.
///     The B+ tree details are internal to each backend.
///   - For tree-sitter: readChunk() provides byte-range access at
///     any offset, matching the TSInput.read callback signature.
///
/// Concurrency model (all backends):
///   All mutations (insert, delete) MUST happen on a single thread (the "owner"
///   thread"). Mutations are NOT thread-safe and must be externally synchronized.
///
///   Read-only operations (charAt, getLine, offsetToPos, etc.) are safe on the
///   owning thread without synchronization. For concurrent read access from
///   other threads, use clone() to obtain a frozen snapshot.
///
///   Clone for concurrent access:
///     ```zig
///     // Main thread: editor owns and modifies buffer
///     try buffer.insert(offset, "text");
///
///     // Background thread: read-only access via clone
///     var snapshot = try buffer.text.clone(background_allocator);
///     const line = snapshot.getLine(row, &buf);  // Safe, no synchronization needed
///     snapshot.deinit(background_allocator);
///     ```
///
///   Async I/O pattern (background save without blocking editor):
///     ```zig
///     // Main thread: create snapshot for save operation
///     var snapshot = try buffer.text.clone(io_allocator);
///     // Spawn background task to save to disk
///     try io_thread.spawnTask(struct {
///         store: TextStore,
///         fn saveToDisk(self: @This()) !void {
///             var file = try std.fs.cwd().createFile("document.txt", .{});
///             defer file.close();
///             var writer = file.writer();
///             try self.store.writeTo(&writer);
///             self.store.deinit(io_allocator);
///         }
///     }{ .store = snapshot });
///     // Main thread continues editing immediately
///     try buffer.insert(new_offset, "more text");
///     ```
///
///   The clone() method creates a completely independent copy with its own
///   heap allocations. The clone is safe for concurrent read-only access from
///   any thread without any synchronization. Mutations to the original buffer
///   do not affect the clone and vice versa.
///
/// Value type. Use .provider() on concrete backends to obtain.
/// The concrete backend is heap-allocated behind the opaque ptr.
///
/// ## Extensibility
///
/// The TextStore interface is designed for extension via the vtable pattern.
/// Custom backends can be added by implementing the VTable methods:
///
/// Adding a custom backend:
///   ```zig
///   const MyBackend = struct {
///       allocator: std.mem.Allocator,
///       // ... internal state
///
///       pub fn init(allocator: std.mem.Allocator) !MyBackend {
///           // ... initialization
///       }
///
///       pub fn provider(self: *MyBackend) TextStore {
///           return .{ .ptr = self, .vtable = &comptime TextStore.makeVTable(MyBackend) };
///       }
///
///       // Implement all 15 VTable methods...
///       pub fn deinit(self: *MyBackend, allocator: std.mem.Allocator) void { }
///       pub fn insert(self: *MyBackend, byte_offset: usize, text: []const u8) !void { }
///       // ... (delete, len, charAt, lineCount, lineByteRange, getLine, posToOffset,
///       //       offsetToPos, writeTo, writeToBuf, clone, readChunk)
///   };
///   ```
///
/// ## Integration Patterns
///
/// LSP (Language Server Protocol) integration:
///   Use readChunk() to stream buffer content to LSP servers:
///   ```zig
///   const TSInput = struct {
///       store: TextStore,
///       read_fn: fn (*TSInput, usize, []u8) callconv(.C) usize,
///
///       fn read(self: *TSInput, byte_offset: usize, buf: []u8) usize {
///           return self.store.readChunk(byte_offset, buf) catch return 0;
///       }
///   };
///
///   // Pass to tree-sitter parser
///   const ts_input = TSInput{ .store = buffer.text };
///   const parser = try ts.Parser.create();
///   try parser.parseString(&ts_input, tree);
///   ```
///
/// Tree-sitter incremental parsing:
///   Use clone() for snapshots during parsing to avoid blocking edits:
///   ```zig
///   // Background: parse with tree-sitter
///   var snapshot = try buffer.text.clone(parse_allocator);
///   const tree = try ts_parser.parse(&.{.store = snapshot}, null);
///   snapshot.deinit(parse_allocator);
///
///   // Main thread: continue editing without blocking
///   try buffer.insert(offset, "more code");
///   ```
///
/// Hook system (mutation interception):
///   Wrap a TextStore to intercept mutations:
///   ```zig
///   const HookedTextStore = struct {
///       inner: TextStore,
///       on_insert: fn ([]const u8) void,
///
///       pub fn insert(self: *HookedTextStore, offset: usize, text: []const u8) !void {
///           self.on_insert(text);  // Run hook
///           try self.inner.insert(offset, text);  // Delegate to wrapped store
///       }
///
///       // Delegate other methods to inner...
///       pub fn len(self: *HookedTextStore) usize { return self.inner.len(); }
///   };
///   ```
pub const TextStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    fn replaceWithChunks(self: TextStore, other: *const TextStore) !void {
        if (self.ptr == other.ptr and self.vtable == other.vtable) return;

        const current_len = self.len();
        if (current_len > 0) {
            try self.delete(0, current_len);
        }

        var chunk: [64 * 1024]u8 = undefined;
        var offset: usize = 0;
        while (true) {
            const read_len = try other.readChunk(offset, &chunk);
            if (read_len == 0) break;
            try self.insert(offset, chunk[0..read_len]);
            offset += read_len;
        }
    }

    pub const VTable = struct {
        deinit: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) void,
        insert: *const fn (ctx: *anyopaque, byte_offset: usize, text: []const u8) anyerror!void,
        delete: *const fn (ctx: *anyopaque, byte_offset: usize, length: usize) anyerror!void,
        len: *const fn (ctx: *anyopaque) usize,
        charAt: *const fn (ctx: *anyopaque, byte_offset: usize) ?u8,
        lineCount: *const fn (ctx: *anyopaque) usize,
        lineByteRange: *const fn (ctx: *anyopaque, line: usize) anyerror!?LineRange,
        getLine: *const fn (ctx: *anyopaque, line: usize, buf: *std.ArrayList(u8)) anyerror!?[]const u8,
        posToOffset: *const fn (ctx: *anyopaque, row: usize, col: usize) anyerror!?usize,
        offsetToPos: *const fn (ctx: *anyopaque, offset: usize) anyerror!Position,
        writeTo: *const fn (ctx: *anyopaque, w: *std.Io.Writer) anyerror!void,
        writeToBuf: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) anyerror!void,
        clone: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!TextStore,
        readChunk: *const fn (ctx: *anyopaque, byte_offset: usize, buf: []u8) anyerror!usize,
        replaceFrom: *const fn (ctx: *anyopaque, other: *const TextStore) anyerror!void,
    };

    pub fn makeVTable(comptime T: type) VTable {
        return .{
            .deinit = struct {
                fn f(ctx: *anyopaque, allocator: std.mem.Allocator) void {
                    const ptr = @as(*T, @ptrCast(@alignCast(ctx)));
                    // Call the specialized destroy method if it exists
                    // (checks heap_allocated internally and destroys the struct if true)
                    if (comptime @hasDecl(T, "destroy")) {
                        ptr.destroy(allocator);
                    } else {
                        ptr.deinit(allocator);
                        allocator.destroy(ptr);
                    }
                }
            }.f,
            .insert = struct {
                fn f(ctx: *anyopaque, byte_offset: usize, text: []const u8) anyerror!void {
                    return @as(*T, @ptrCast(@alignCast(ctx))).insert(byte_offset, text);
                }
            }.f,
            .delete = struct {
                fn f(ctx: *anyopaque, byte_offset: usize, length: usize) anyerror!void {
                    return @as(*T, @ptrCast(@alignCast(ctx))).delete(byte_offset, length);
                }
            }.f,
            .len = struct {
                fn f(ctx: *anyopaque) usize {
                    return @as(*T, @ptrCast(@alignCast(ctx))).len();
                }
            }.f,
            .charAt = struct {
                fn f(ctx: *anyopaque, byte_offset: usize) ?u8 {
                    return @as(*T, @ptrCast(@alignCast(ctx))).charAt(byte_offset);
                }
            }.f,
            .lineCount = struct {
                fn f(ctx: *anyopaque) usize {
                    return @as(*T, @ptrCast(@alignCast(ctx))).lineCount();
                }
            }.f,
            .lineByteRange = struct {
                fn f(ctx: *anyopaque, line: usize) anyerror!?LineRange {
                    return @as(*T, @ptrCast(@alignCast(ctx))).lineByteRange(line);
                }
            }.f,
            .getLine = struct {
                fn f(ctx: *anyopaque, line: usize, buf: *std.ArrayList(u8)) anyerror!?[]const u8 {
                    return @as(*T, @ptrCast(@alignCast(ctx))).getLine(line, buf);
                }
            }.f,
            .posToOffset = struct {
                fn f(ctx: *anyopaque, row: usize, col: usize) anyerror!?usize {
                    return @as(*T, @ptrCast(@alignCast(ctx))).posToOffset(row, col);
                }
            }.f,
            .offsetToPos = struct {
                fn f(ctx: *anyopaque, offset: usize) anyerror!Position {
                    return @as(*T, @ptrCast(@alignCast(ctx))).offsetToPos(offset);
                }
            }.f,
            .writeTo = struct {
                fn f(ctx: *anyopaque, w: *std.Io.Writer) anyerror!void {
                    return @as(*T, @ptrCast(@alignCast(ctx))).writeTo(w);
                }
            }.f,
            .writeToBuf = struct {
                fn f(ctx: *anyopaque, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) anyerror!void {
                    return @as(*T, @ptrCast(@alignCast(ctx))).writeToBuf(gpa, buf);
                }
            }.f,
            .clone = struct {
                fn f(ctx: *anyopaque, gpa: std.mem.Allocator) anyerror!TextStore {
                    return @as(*T, @ptrCast(@alignCast(ctx))).clone(gpa);
                }
            }.f,
            .readChunk = struct {
                fn f(ctx: *anyopaque, byte_offset: usize, buf: []u8) anyerror!usize {
                    return @as(*T, @ptrCast(@alignCast(ctx))).readChunk(byte_offset, buf);
                }
            }.f,
            .replaceFrom = struct {
                fn f(ctx: *anyopaque, other: *const TextStore) anyerror!void {
                    const self_store = TextStore{
                        .ptr = ctx,
                        .vtable = &comptime TextStore.makeVTable(T),
                    };
                    const self_ptr = @as(*T, @ptrCast(@alignCast(ctx)));
                    if (other.vtable == self_store.vtable) {
                        const other_ptr = @as(*T, @ptrCast(@alignCast(other.ptr)));
                        return self_ptr.replaceFrom(other_ptr);
                    }
                    return self_store.replaceWithChunks(other);
                }
            }.f,
        };
    }

    pub fn deinit(self: TextStore, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
    pub fn insert(self: TextStore, byte_offset: usize, text: []const u8) !void {
        return self.vtable.insert(self.ptr, byte_offset, text);
    }
    pub fn delete(self: TextStore, byte_offset: usize, length: usize) !void {
        return self.vtable.delete(self.ptr, byte_offset, length);
    }
    pub fn len(self: TextStore) usize {
        return self.vtable.len(self.ptr);
    }
    pub fn charAt(self: TextStore, byte_offset: usize) ?u8 {
        return self.vtable.charAt(self.ptr, byte_offset);
    }
    pub fn lineCount(self: TextStore) usize {
        return self.vtable.lineCount(self.ptr);
    }
    pub fn lineByteRange(self: TextStore, line: usize) !?LineRange {
        return self.vtable.lineByteRange(self.ptr, line);
    }
    pub fn getLine(self: TextStore, line: usize, buf: *std.ArrayList(u8)) !?[]const u8 {
        return self.vtable.getLine(self.ptr, line, buf);
    }
    pub fn posToOffset(self: TextStore, row: usize, col: usize) !?usize {
        return self.vtable.posToOffset(self.ptr, row, col);
    }
    pub fn offsetToPos(self: TextStore, offset: usize) !Position {
        return self.vtable.offsetToPos(self.ptr, offset);
    }
    pub fn writeTo(self: TextStore, w: *std.Io.Writer) !void {
        return self.vtable.writeTo(self.ptr, w);
    }
    pub fn writeToBuf(self: TextStore, gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        return self.vtable.writeToBuf(self.ptr, gpa, buf);
    }
    /// Create a deep copy of the text store.
    ///
    /// Thread safety: The returned TextStore is safe for concurrent read-only
    /// access on any thread. Multiple threads can call charAt, getLine, offsetToPos,
    /// writeTo, etc. on the cloned TextStore without synchronization.
    ///
    /// Usage pattern for async operations:
    ///   ```zig
    ///   // Main thread: create snapshot before async operation
    ///   var snapshot = try buffer.text.clone(allocator);
    ///   // Pass snapshot to background thread for save-to-disk
    ///   try background_thread.spawnSave(snapshot);
    ///   // Main thread continues editing original buffer
    ///   ```
    ///
    /// The clone allocates new memory for all text data and caches.
    /// Call deinit() on the clone when done to free the copy.
    pub fn clone(self: TextStore, gpa: std.mem.Allocator) !TextStore {
        return self.vtable.clone(self.ptr, gpa);
    }
    pub fn readChunk(self: TextStore, byte_offset: usize, buf: []u8) !usize {
        return self.vtable.readChunk(self.ptr, byte_offset, buf);
    }
    pub fn replaceFrom(self: TextStore, other: *const TextStore) !void {
        return self.vtable.replaceFrom(self.ptr, other);
    }
};
