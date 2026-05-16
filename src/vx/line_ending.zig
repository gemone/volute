const std = @import("std");

/// Line-ending style detected in or requested for a file.
pub const LineEnding = enum {
    lf,    // Unix: \n
    crlf,  // Windows: \r\n
    cr,    // Classic Mac: \r
    mixed, // Multiple styles present

    pub fn displayName(self: LineEnding) []const u8 {
        return switch (self) {
            .lf => "LF",
            .crlf => "CRLF",
            .cr => "CR",
            .mixed => "mixed",
        };
    }
};

/// Detect the dominant line-ending style in a byte slice.
/// If multiple styles are present the majority wins; ties favour LF.
pub fn detect(bytes: []const u8) LineEnding {
    var lf_count: usize = 0;
    var crlf_count: usize = 0;
    var cr_count: usize = 0;

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r') {
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                crlf_count += 1;
                i += 1; // skip the \n
            } else {
                cr_count += 1;
            }
        } else if (bytes[i] == '\n') {
            lf_count += 1;
        }
    }

    const total = lf_count + crlf_count + cr_count;
    if (total == 0) return .lf;

    if (crlf_count > 0 and lf_count == 0 and cr_count == 0) return .crlf;
    if (cr_count > 0 and lf_count == 0 and crlf_count == 0) return .cr;
    if (lf_count > 0 and crlf_count == 0 and cr_count == 0) return .lf;

    // Mixed: return whichever is dominant; ties → lf
    const max = @max(lf_count, @max(crlf_count, cr_count));
    if (max == lf_count) return .lf;
    if (max == crlf_count) return .crlf;
    if (max == cr_count) return .cr;
    return .lf;
}

/// Normalize bytes to LF-only line endings.
/// Replaces all \r\n and lone \r sequences with \n.
/// Returns a new allocation if any \r bytes are present;
/// otherwise returns null to signal the input can be used as-is.
pub fn normalize(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    // Fast path: no CR bytes at all.
    if (std.mem.indexOfScalar(u8, bytes, '\r') == null) return null;

    var out = try std.ArrayList(u8).initCapacity(allocator, bytes.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r') {
            // \r\n → \n
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') {
                i += 1;
            }
            // lone \r → \n
            try out.append(allocator, '\n');
        } else {
            try out.append(allocator, bytes[i]);
        }
    }

    return try out.toOwnedSlice(allocator);
}

/// Convert LF-only bytes to the requested line-ending style.
/// Returns a new allocation; caller owns the result.
pub fn denormalize(allocator: std.mem.Allocator, bytes: []const u8, to: LineEnding) ![]u8 {
    switch (to) {
        .lf, .mixed => return allocator.dupe(u8, bytes),
        .cr => {
            const out = try allocator.dupe(u8, bytes);
            for (out) |*b| {
                if (b.* == '\n') b.* = '\r';
            }
            return out;
        },
        .crlf => {
            // Count newlines to pre-size
            const nl_count = std.mem.count(u8, bytes, "\n");
            var out = try std.ArrayList(u8).initCapacity(allocator, bytes.len + nl_count);
            errdefer out.deinit(allocator);
            for (bytes) |b| {
                if (b == '\n') {
                    try out.append(allocator, '\r');
                }
                try out.append(allocator, b);
            }
            return try out.toOwnedSlice(allocator);
        },
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "detect: LF only" {
    try std.testing.expectEqual(LineEnding.lf, detect("hello\nworld\n"));
}

test "detect: CRLF only" {
    try std.testing.expectEqual(LineEnding.crlf, detect("hello\r\nworld\r\n"));
}

test "detect: CR only" {
    try std.testing.expectEqual(LineEnding.cr, detect("hello\rworld\r"));
}

test "detect: empty" {
    try std.testing.expectEqual(LineEnding.lf, detect(""));
}

test "detect: no newlines" {
    try std.testing.expectEqual(LineEnding.lf, detect("hello world"));
}

test "detect: mixed CRLF+LF returns dominant" {
    // 3 CRLF, 1 LF → CRLF
    const result = detect("a\r\nb\r\nc\r\nd\n");
    try std.testing.expectEqual(LineEnding.crlf, result);
}

test "normalize: LF passthrough returns null" {
    const result = try normalize(std.testing.allocator, "hello\nworld\n");
    try std.testing.expect(result == null);
}

test "normalize: CRLF converted to LF" {
    const result = try normalize(std.testing.allocator, "hello\r\nworld\r\n");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("hello\nworld\n", result.?);
}

test "normalize: lone CR converted to LF" {
    const result = try normalize(std.testing.allocator, "hello\rworld\r");
    try std.testing.expect(result != null);
    defer std.testing.allocator.free(result.?);
    try std.testing.expectEqualStrings("hello\nworld\n", result.?);
}

test "denormalize: LF passthrough" {
    const result = try denormalize(std.testing.allocator, "hello\nworld\n", .lf);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld\n", result);
}

test "denormalize: LF to CRLF" {
    const result = try denormalize(std.testing.allocator, "hello\nworld\n", .crlf);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\r\nworld\r\n", result);
}

test "denormalize: LF to CR" {
    const result = try denormalize(std.testing.allocator, "hello\nworld\n", .cr);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello\rworld\r", result);
}

test "normalize then denormalize round-trip: CRLF" {
    const original = "line1\r\nline2\r\nline3\r\n";
    const normalized = try normalize(std.testing.allocator, original);
    try std.testing.expect(normalized != null);
    defer std.testing.allocator.free(normalized.?);

    const restored = try denormalize(std.testing.allocator, normalized.?, .crlf);
    defer std.testing.allocator.free(restored);
    try std.testing.expectEqualStrings(original, restored);
}
