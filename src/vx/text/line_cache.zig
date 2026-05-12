const std = @import("std");

/// Unified line cache management for text storage backends.
/// Provides consistent invalidation and rebuilding logic across GapBuffer and TreeRope.
pub fn LineCache(comptime StorageT: type) type {
    return struct {
        const Self = @This();

        /// Line start positions (byte offsets).
        /// starts[i] = byte offset where line i begins.
        starts: std.ArrayList(usize),

        /// Cache validity flag. Set to false on mutation, rebuilt on demand.
        valid: bool,

        /// Initialize a new line cache.
        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{
                .starts = try std.ArrayList(usize).initCapacity(allocator, 16),
                .valid = false,
            };
        }

        /// Free cache resources.
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.starts.deinit(allocator);
        }

        /// Mark cache as invalid (must be rebuilt before next use).
        pub fn invalidate(self: *Self) void {
            self.valid = false;
        }

        /// Check if cache is currently valid.
        pub fn isValid(self: *const Self) bool {
            return self.valid;
        }

        /// Rebuild cache from text storage.
        /// Caller provides a callback function that returns the byte at a given offset.
        pub fn rebuild(
            self: *Self,
            storage: *StorageT,
            allocator: std.mem.Allocator,
            comptime getByteFn: fn (*StorageT, usize) ?u8,
            length: usize,
        ) !void {
            self.starts.clearRetainingCapacity();
            try self.starts.append(allocator, 0);

            var offset: usize = 0;
            while (offset < length) {
                if (getByteFn(storage, offset)) |ch| {
                    if (ch == '\n') {
                        try self.starts.append(allocator, offset + 1);
                    }
                }
                offset += 1;
            }

            self.valid = true;
        }

        /// Get line count from cache (cache must be valid).
        pub fn lineCount(self: *const Self) usize {
            std.debug.assert(self.valid);
            return self.starts.items.len;
        }

        /// Get byte range for a line (cache must be valid).
        /// Returns null if line index is out of bounds.
        pub fn getLineRange(self: *const Self, line: usize, total_len: usize) ?struct { start: usize, end: usize } {
            if (!self.valid or line >= self.starts.items.len) return null;

            const start = self.starts.items[line];
            const end = if (line + 1 < self.starts.items.len)
                self.starts.items[line + 1]
            else
                total_len;

            return .{ .start = start, .end = end };
        }

        /// Ensure cache is valid, rebuilding if necessary.
        pub fn ensure(
            self: *Self,
            storage: *StorageT,
            allocator: std.mem.Allocator,
            comptime getByteFn: fn (*StorageT, usize) ?u8,
            length: usize,
        ) !void {
            if (!self.valid) {
                try self.rebuild(storage, allocator, getByteFn, length);
            }
        }
    };
}
