const std = @import("std");

/// Shared UTF-8 boundary checking utilities.
/// Consolidates duplicate UTF-8 handling code from buffer.zig, view.zig, and text backends.
pub const Boundary = struct {
    line: []const u8,

    /// Check if byte is a UTF-8 continuation byte (10xxxxxx).
    pub fn isContinuationByte(byte: u8) bool {
        return (byte & 0xC0) == 0x80;
    }

    /// Find the nearest UTF-8 boundary at or before col (clamps to valid positions).
    /// For interior byte positions within a multi-byte sequence, returns the start of that sequence.
    pub fn floor(self: Boundary, col: usize) usize {
        if (self.line.len == 0) return 0;
        var idx = @min(col, self.line.len - 1);
        while (idx > 0 and isContinuationByte(self.line[idx])) : (idx -= 1) {}
        return idx;
    }

    /// Move to previous UTF-8 boundary (safe to call at position 0).
    pub fn prev(self: Boundary, col: usize) usize {
        const clamped = @min(col, self.line.len);
        if (clamped == 0) return 0;

        var idx = clamped - 1;
        while (idx > 0 and isContinuationByte(self.line[idx])) : (idx -= 1) {}
        return idx;
    }

    /// Get length of UTF-8 sequence starting at position.
    pub fn sequenceLen(self: Boundary, start: usize) usize {
        if (start >= self.line.len) return 0;

        const expected = std.unicode.utf8ByteSequenceLength(self.line[start]) catch return 1;
        if (start + expected > self.line.len) return 1;

        var idx: usize = 1;
        while (idx < expected) : (idx += 1) {
            if (!isContinuationByte(self.line[start + idx])) return 1;
        }

        return expected;
    }

    /// Move to next UTF-8 boundary (safe to call at end of line).
    pub fn next(self: Boundary, col: usize) usize {
        const clamped = @min(col, self.line.len);
        if (clamped >= self.line.len) return self.line.len;

        const start = self.floor(clamped);
        const next_boundary = start + self.sequenceLen(start);
        return @min(next_boundary, self.line.len);
    }

    /// Align column to valid UTF-8 boundary for cursor operations.
    /// allow_eol: if true, allows positioning at end-of-line (after last character)
    pub fn alignColumn(self: Boundary, col: usize, allow_eol: bool) usize {
        if (self.line.len == 0) return 0;

        const clamped = @min(col, self.line.len);
        if (allow_eol and clamped == self.line.len) return self.line.len;
        if (clamped >= self.line.len) return self.prev(self.line.len);
        return self.floor(clamped);
    }
};

/// Convenience function to create a Boundary from a byte slice.
pub fn boundary(line: []const u8) Boundary {
    return .{ .line = line };
}
