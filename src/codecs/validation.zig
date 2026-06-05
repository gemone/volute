//! Encoding validation utilities - check if file content can be safely represented in target encoding

const std = @import("std");
const encoding = @import("encoding.zig");

/// Validation result for encoding conversion
pub const ValidationResult = struct {
    /// Whether the conversion is lossy
    is_lossy: bool,
    /// Number of characters that would be lost
    lost_char_count: usize,
    /// Suggested alternative encoding if available
    suggestion: ?[]const u8,
};

/// Check if UTF-8 content can be safely encoded in target encoding
pub fn validateUtf8ToEncoding(utf8_bytes: []const u8, target_enc: encoding.Encoding) !ValidationResult {
    const allocator = std.heap.page_allocator;

    // Try to encode and decode back
    const encoded = try encoding.fromUtf8(allocator, utf8_bytes, target_enc);
    defer allocator.free(encoded);

    const decoded = try encoding.toUtf8(allocator, encoded, target_enc);
    defer allocator.free(decoded);

    // Compare original with round-trip result
    if (std.mem.eql(u8, utf8_bytes, decoded)) {
        // Perfect round-trip - no data loss
        return .{
            .is_lossy = false,
            .lost_char_count = 0,
            .suggestion = null,
        };
    }

    // Data loss detected - count characters that differ
    var lost_count: usize = 0;
    var i: usize = 0;
    var j: usize = 0;

    while (i < utf8_bytes.len and j < decoded.len) {
        // Get UTF-8 sequence lengths
        const len1 = utf8ByteLen(utf8_bytes[i]);
        const len2 = utf8ByteLen(decoded[j]);

        // Compare sequences
        if (len1 != len2 or !std.mem.eql(u8, utf8_bytes[i..i+len1], decoded[j..j+len2])) {
            lost_count += 1;
        }

        i += len1;
        j += len2;
    }

    // Count any remaining characters
    while (i < utf8_bytes.len) {
        lost_count += 1;
        i += utf8ByteLen(utf8_bytes[i]);
    }

    // Suggest UTF-8 if data would be lost
    const suggestion: ?[]const u8 = if (target_enc != .utf8) "UTF-8" else null;

    return .{
        .is_lossy = true,
        .lost_char_count = lost_count,
        .suggestion = suggestion,
    };
}

/// Get UTF-8 sequence length from first byte
fn utf8ByteLen(first_byte: u8) usize {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    return 4;
}

/// Format a validation error message for users
pub fn formatValidationError(result: ValidationResult, file_path: []const u8, target_enc: encoding.Encoding) ![]u8 {
    const allocator = std.heap.page_allocator;

    var msg = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer msg.deinit(allocator);

    const enc_name = target_enc.displayName();

    try msg.appendSlice(allocator, "⚠️  Cannot safely open '");
    try msg.appendSlice(allocator, file_path);
    try msg.appendSlice(allocator, "' as ");
    try msg.appendSlice(allocator, enc_name);
    try msg.appendSlice(allocator, "\n\n");

    if (result.is_lossy) {
        try msg.appendSlice(allocator, "This file contains characters that cannot be represented in ");
        try msg.appendSlice(allocator, enc_name);
        try msg.appendSlice(allocator, " encoding:\n\n");

        if (result.lost_char_count > 0) {
            try msg.print(allocator, "  • {d} characters would be lost or corrupted\n", .{result.lost_char_count});
        }

        if (result.suggestion) |sugg| {
            try msg.appendSlice(allocator, "\n💡 Suggestion: Try opening this file as ");
            try msg.appendSlice(allocator, sugg);
            try msg.appendSlice(allocator, " instead.\n");
        }
    }

    return msg.toOwnedSlice(allocator);
}

test "validateUtf8ToEncoding: safe content" {
    const safe_content = "Hello, World!";
    const result = try validateUtf8ToEncoding(safe_content, .utf8);
    try std.testing.expect(!result.is_lossy);
    try std.testing.expectEqual(@as(usize, 0), result.lost_char_count);
}

test "validateUtf8ToEncoding: lossy CP1251" {
    // Mixed Cyrillic + Chinese would be lossy in CP1251
    const lossy_content = "Привет! 世界!";
    const result = try validateUtf8ToEncoding(lossy_content, .cp1251);
    try std.testing.expect(result.is_lossy);
    try std.testing.expect(result.lost_char_count > 0);
    try std.testing.expect(result.suggestion != null);
}

test "validateUtf8ToEncoding: lossy CP1250" {
    // Latin-1 extended + Chinese would be lossy in CP1250
    const lossy_content = "ÀÁÂÃ 世界!";
    const result = try validateUtf8ToEncoding(lossy_content, .cp1250);
    try std.testing.expect(result.is_lossy);
    try std.testing.expect(result.lost_char_count > 0);
}
