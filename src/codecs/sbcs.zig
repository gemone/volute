const std = @import("std");
const simd = @import("../simd.zig");

const cp1250_codec = @import("cp1250_codec");
const cp1251_codec = @import("cp1251_codec");
const cp1252_codec = @import("cp1252_codec");
const koi8r_codec  = @import("koi8r_codec");
const cp874_codec  = @import("cp874_codec");
const cp1253_codec = @import("cp1253_codec");
const cp1254_codec = @import("cp1254_codec");
const cp1255_codec = @import("cp1255_codec");
const cp1256_codec = @import("cp1256_codec");
const cp1257_codec = @import("cp1257_codec");
const cp1258_codec = @import("cp1258_codec");
const koi8u_codec  = @import("koi8u_codec");
const cp437_codec  = @import("cp437_codec");
const cp850_codec  = @import("cp850_codec");
const iso8859_2_codec  = @import("iso8859_2_codec");
const iso8859_3_codec  = @import("iso8859_3_codec");
const iso8859_4_codec  = @import("iso8859_4_codec");
const iso8859_5_codec  = @import("iso8859_5_codec");
const iso8859_6_codec  = @import("iso8859_6_codec");
const iso8859_7_codec  = @import("iso8859_7_codec");
const iso8859_8_codec  = @import("iso8859_8_codec");
const iso8859_9_codec  = @import("iso8859_9_codec");
const iso8859_10_codec = @import("iso8859_10_codec");
const iso8859_11_codec = @import("iso8859_11_codec");
const iso8859_13_codec = @import("iso8859_13_codec");
const iso8859_14_codec = @import("iso8859_14_codec");
const iso8859_15_codec = @import("iso8859_15_codec");
const iso8859_16_codec = @import("iso8859_16_codec");

// ── Latin-1 ───────────────────────────────────────────────────────────────────

pub fn decodeLatin1(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // Single-pass with exact 2× pre-alloc.
    // For pure non-ASCII corpus: j == out.len → realloc is a no-op.
    // For mixed/ASCII-heavy: realloc shrinks in-place (GPA O(1) resize).
    var out = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(out);
    var i: usize = 0;
    var j: usize = 0;
    while (i < bytes.len) {
        const run = simd.findFirstNonAscii(bytes[i..]);
        if (run > 0) {
            @memcpy(out[j .. j + run], bytes[i .. i + run]);
            i += run;
            j += run;
            continue;
        }
        while (i + 16 <= bytes.len) {
            const chunk: @Vector(16, u8) = bytes[i..][0..16].*;
            if (!@reduce(.And, chunk >= @as(@Vector(16, u8), @splat(0x80)))) break;
            const upper = @as(@Vector(16, u8), @splat(0xC0)) | (chunk >> @as(@Vector(16, u8), @splat(6)));
            const lower = @as(@Vector(16, u8), @splat(0x80)) | (chunk & @as(@Vector(16, u8), @splat(0x3F)));
            inline for (0..16) |k| {
                out[j + 2 * k]     = upper[k];
                out[j + 2 * k + 1] = lower[k];
            }
            i += 16;
            j += 32;
        }
        while (i < bytes.len and bytes[i] >= 0x80) {
            const b = bytes[i];
            out[j]     = 0xC0 | (b >> 6);
            out[j + 1] = 0x80 | (b & 0x3F);
            i += 1;
            j += 2;
        }
    }
    if (j == out.len) return out;
    return allocator.realloc(out, j);
}

pub fn encodeLatin1(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    // Output is always ≤ input (each UTF-8 char ≥ 1 byte → 1 Latin-1 byte).
    var buf = try allocator.alloc(u8, utf8_bytes.len);
    errdefer allocator.free(buf);
    var j: usize = 0;

    var i: usize = 0;
    while (i < utf8_bytes.len) {
        // SIMD bulk-copy ASCII run (bytes 0x00-0x7F pass through 1:1).
        const run = simd.findFirstNonAscii(utf8_bytes[i..]);
        if (run > 0) {
            @memcpy(buf[j .. j + run], utf8_bytes[i .. i + run]);
            j += run;
            i += run;
            continue;
        }
        const b = utf8_bytes[i];
        // Only 2-byte (0xC2/0xC3) and 3-byte seqs can map to Latin-1 (U+0080-U+00FF).
        if (b < 0xC0 or b > 0xEF) {
            buf[j] = '?';
            j += 1;
            i += 1;
            continue;
        }
        const seq_len: usize = if (b < 0xE0) 2 else 3;
        if (i + seq_len > utf8_bytes.len) {
            buf[j] = '?';
            j += 1;
            break;
        }
        // SIMD batch path: process 8 × 2-byte sequences (0xC2/0xC3 + continuation)
        // into 8 Latin-1 output bytes in one shot.
        if (seq_len == 2 and i + 16 <= utf8_bytes.len) {
            // Check: all 8 pairs are 0xC2/0xC3 followed by 0x80-0xBF.
            var all_latin1 = true;
            var cps: [8]u8 = undefined;
            inline for (0..8) |k| {
                const b0 = utf8_bytes[i + k * 2];
                const b1 = utf8_bytes[i + k * 2 + 1];
                if ((b0 != 0xC2 and b0 != 0xC3) or (b1 < 0x80 or b1 > 0xBF)) {
                    all_latin1 = false;
                    break;
                }
                cps[k] = @intCast((@as(u21, b0 & 0x1F) << 6) | @as(u21, b1 & 0x3F));
            }
            if (all_latin1) {
                @memcpy(buf[j .. j + 8], &cps);
                j += 8;
                i += 16;
                continue;
            }
        }
        // Inline UTF-8 decode for 2/3-byte sequences.
        const cp: u21 = if (seq_len == 2)
            @as(u21, b & 0x1F) << 6 | @as(u21, utf8_bytes[i + 1] & 0x3F)
        else
            @as(u21, b & 0x0F) << 12 | @as(u21, utf8_bytes[i + 1] & 0x3F) << 6 | @as(u21, utf8_bytes[i + 2] & 0x3F);
        buf[j] = if (cp <= 0xFF) @as(u8, @intCast(cp)) else '?';
        j += 1;
        i += seq_len;
    }

    return allocator.realloc(buf, j);
}

// ── CP12xx / KOI8-R wrappers ──────────────────────────────────────────────────

pub fn decodeCp1250(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1250_codec.decode(allocator, bytes);
}

pub fn encodeCp1250(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1250_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1251(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1251_codec.decode(allocator, bytes);
}

pub fn encodeCp1251(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1251_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1252(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1252_codec.decode(allocator, bytes);
}

pub fn encodeCp1252(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1252_codec.encode(allocator, utf8_bytes);
}

pub fn decodeKoi8r(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return koi8r_codec.decode(allocator, bytes);
}

pub fn encodeKoi8r(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return koi8r_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp874(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp874_codec.decode(allocator, bytes);
}

pub fn encodeCp874(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp874_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1253(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1253_codec.decode(allocator, bytes);
}

pub fn encodeCp1253(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1253_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1254(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1254_codec.decode(allocator, bytes);
}

pub fn encodeCp1254(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1254_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1255(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1255_codec.decode(allocator, bytes);
}

pub fn encodeCp1255(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1255_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1256(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1256_codec.decode(allocator, bytes);
}

pub fn encodeCp1256(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1256_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1257(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1257_codec.decode(allocator, bytes);
}

pub fn encodeCp1257(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1257_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp1258(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp1258_codec.decode(allocator, bytes);
}

pub fn encodeCp1258(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp1258_codec.encode(allocator, utf8_bytes);
}

pub fn decodeKoi8u(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return koi8u_codec.decode(allocator, bytes);
}

pub fn encodeKoi8u(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return koi8u_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp437(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp437_codec.decode(allocator, bytes);
}

pub fn encodeCp437(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp437_codec.encode(allocator, utf8_bytes);
}

pub fn decodeCp850(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return cp850_codec.decode(allocator, bytes);
}

pub fn encodeCp850(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return cp850_codec.encode(allocator, utf8_bytes);
}

pub fn decodeIso8859_2(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_2_codec.decode(allocator, bytes); }
pub fn encodeIso8859_2(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_2_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_3(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_3_codec.decode(allocator, bytes); }
pub fn encodeIso8859_3(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_3_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_4(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_4_codec.decode(allocator, bytes); }
pub fn encodeIso8859_4(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_4_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_5(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_5_codec.decode(allocator, bytes); }
pub fn encodeIso8859_5(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_5_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_6(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_6_codec.decode(allocator, bytes); }
pub fn encodeIso8859_6(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_6_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_7(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_7_codec.decode(allocator, bytes); }
pub fn encodeIso8859_7(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_7_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_8_codec.decode(allocator, bytes); }
pub fn encodeIso8859_8(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_8_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_9(allocator: std.mem.Allocator, bytes: []const u8) ![]u8  { return iso8859_9_codec.decode(allocator, bytes); }
pub fn encodeIso8859_9(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_9_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_10(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_10_codec.decode(allocator, bytes); }
pub fn encodeIso8859_10(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_10_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_11(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_11_codec.decode(allocator, bytes); }
pub fn encodeIso8859_11(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_11_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_13(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_13_codec.decode(allocator, bytes); }
pub fn encodeIso8859_13(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_13_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_14(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_14_codec.decode(allocator, bytes); }
pub fn encodeIso8859_14(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_14_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_15(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_15_codec.decode(allocator, bytes); }
pub fn encodeIso8859_15(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_15_codec.encode(allocator, utf8_bytes); }
pub fn decodeIso8859_16(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 { return iso8859_16_codec.decode(allocator, bytes); }
pub fn encodeIso8859_16(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 { return iso8859_16_codec.encode(allocator, utf8_bytes); }
