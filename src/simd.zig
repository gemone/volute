//! SIMD utilities for bulk ASCII byte scanning.
//!
//! Processes bytes in 16-byte (128-bit) chunks — compatible with SSE2/NEON and
//! any platform Zig targets.  Falls back to scalar for tail bytes automatically.
//!
//! Used by encoding.zig and codec/table_codec.zig to skip ASCII runs in O(N/16)
//! rather than O(N) iterations before reaching high-byte sequences.

const std = @import("std");

/// Number of bytes processed per SIMD iteration (128-bit lane).
const VEC_LEN: usize = 16;
const V = @Vector(VEC_LEN, u8);

/// Threshold for "is ASCII": bytes in [0x00, 0x7F] are ASCII.
const THRESHOLD: V = @splat(0x7F);

/// Returns the index of the first byte with bit 7 set (value > 0x7F).
/// Returns `bytes.len` if all bytes are ASCII.
///
/// Processes 16 bytes per loop iteration using SIMD comparisons, then
/// falls back to scalar for the tail.
pub fn findFirstNonAscii(bytes: []const u8) usize {
    var i: usize = 0;
    while (i + VEC_LEN <= bytes.len) {
        const chunk: V = bytes[i..][0..VEC_LEN].*;
        const gt: @Vector(VEC_LEN, bool) = chunk > THRESHOLD;
        if (@reduce(.Or, gt)) {
            // Locate the exact position within this chunk.
            inline for (0..VEC_LEN) |j| {
                if (gt[j]) return i + j;
            }
        }
        i += VEC_LEN;
    }
    // Scalar tail for the remaining < VEC_LEN bytes.
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] > 0x7F) return i;
    }
    return bytes.len;
}

/// Returns `true` if every byte in `bytes` is in the ASCII range [0x00, 0x7F].
pub inline fn allAscii(bytes: []const u8) bool {
    return findFirstNonAscii(bytes) == bytes.len;
}

/// Returns the count of bytes with value > 0x7F.
///
/// Used by `decodeLatin1` to pre-calculate the output buffer size in one SIMD
/// pass rather than a byte-by-byte loop.
pub fn countNonAscii(bytes: []const u8) usize {
    const ones: V = @splat(@as(u8, 1));
    const zeros: V = @splat(@as(u8, 0));
    var count: usize = 0;
    var i: usize = 0;
    while (i + VEC_LEN <= bytes.len) : (i += VEC_LEN) {
        const chunk: V = bytes[i..][0..VEC_LEN].*;
        const gt: @Vector(VEC_LEN, bool) = chunk > THRESHOLD;
        const selected: V = @select(u8, gt, ones, zeros);
        count += @reduce(.Add, selected);
    }
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] > 0x7F) count += 1;
    }
    return count;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "findFirstNonAscii: empty slice" {
    try std.testing.expectEqual(@as(usize, 0), findFirstNonAscii(""));
}

test "findFirstNonAscii: all ASCII (< 16 bytes)" {
    const s = "Hello";
    try std.testing.expectEqual(s.len, findFirstNonAscii(s));
}

test "findFirstNonAscii: all ASCII (exactly 16 bytes)" {
    const s = "0123456789ABCDEF";
    try std.testing.expectEqual(s.len, findFirstNonAscii(s));
}

test "findFirstNonAscii: all ASCII (17 bytes, crosses boundary)" {
    const s = "0123456789ABCDEFG";
    try std.testing.expectEqual(s.len, findFirstNonAscii(s));
}

test "findFirstNonAscii: non-ASCII at position 0" {
    const s = "\x80Hello";
    try std.testing.expectEqual(@as(usize, 0), findFirstNonAscii(s));
}

test "findFirstNonAscii: non-ASCII in the middle (< 16 bytes)" {
    const s = "Hello\xC2\xA9world";
    try std.testing.expectEqual(@as(usize, 5), findFirstNonAscii(s));
}

test "findFirstNonAscii: non-ASCII at byte 15 (end of first chunk)" {
    const s = "0123456789ABCDE\xFF";
    try std.testing.expectEqual(@as(usize, 15), findFirstNonAscii(s));
}

test "findFirstNonAscii: non-ASCII in second chunk" {
    const s = "0123456789ABCDEF\x80";
    try std.testing.expectEqual(@as(usize, 16), findFirstNonAscii(s));
}

test "findFirstNonAscii: non-ASCII at end of 32-byte buffer" {
    const s = "0123456789ABCDEF0123456789ABCDE\xFF";
    try std.testing.expectEqual(@as(usize, 31), findFirstNonAscii(s));
}

test "allAscii: pure ASCII" {
    try std.testing.expect(allAscii("Hello, World!"));
    try std.testing.expect(allAscii(""));
}

test "allAscii: contains high byte" {
    try std.testing.expect(!allAscii("caf\xE9"));
}

test "countNonAscii: empty" {
    try std.testing.expectEqual(@as(usize, 0), countNonAscii(""));
}

test "countNonAscii: all ASCII" {
    try std.testing.expectEqual(@as(usize, 0), countNonAscii("Hello"));
}

test "countNonAscii: mixed" {
    // \xC2\xA9 = UTF-8 for © (two non-ASCII bytes)
    const s = "caf\xC2\xA9";
    try std.testing.expectEqual(@as(usize, 2), countNonAscii(s));
}

test "countNonAscii: across 16-byte boundary" {
    // 16 ASCII bytes + 2 non-ASCII
    const s = "0123456789ABCDEF\x80\x81";
    try std.testing.expectEqual(@as(usize, 2), countNonAscii(s));
}

test "countNonAscii: all non-ASCII (16 bytes)" {
    const s = "\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8A\x8B\x8C\x8D\x8E\x8F";
    try std.testing.expectEqual(@as(usize, 16), countNonAscii(s));
}
