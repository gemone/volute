const std = @import("std");
const simd = @import("../simd.zig");

const gbk_codec      = @import("gbk_codec");
const big5_codec     = @import("big5_codec");
const shiftjis_codec = @import("shiftjis_codec");
const euckr_codec    = @import("euckr_codec");
const eucjp_codec    = @import("eucjp_codec");

// ── GB18030 4-byte sequence support ──────────────────────────────────────────
//
// GB18030 extends GBK with 4-byte sequences that cover the entire Unicode BMP
// (characters not already in GBK) plus all supplementary planes.
//
// 4-byte sequence format:
//   b1 ∈ [0x81..0xFE],  b2 ∈ [0x30..0x39],
//   b3 ∈ [0x81..0xFE],  b4 ∈ [0x30..0x39]
//
// Linear index: (b1-0x81)*12600 + (b2-0x30)*1260 + (b3-0x81)*10 + (b4-0x30)
//   linear ∈ [0..39419]        → BMP character (binary search in gb18030_bmp_ranges)
//   linear ∈ [189000..1237575]  → Supplementary: cp = 0x10000 + linear - 189000

const Gb18030Range = struct { linear: u32, cp: u21, len: u32 };

/// Sorted mapping table: linear index → Unicode BMP codepoint ranges.
/// Each entry covers [linear, linear+len) → [cp, cp+len).
const gb18030_bmp_ranges = [_]Gb18030Range{
    .{ .linear = 0, .cp = 0x0080, .len = 36 },
    .{ .linear = 36, .cp = 0x00A5, .len = 2 },
    .{ .linear = 38, .cp = 0x00A9, .len = 7 },
    .{ .linear = 45, .cp = 0x00B2, .len = 5 },
    .{ .linear = 50, .cp = 0x00B8, .len = 31 },
    .{ .linear = 81, .cp = 0x00D8, .len = 8 },
    .{ .linear = 89, .cp = 0x00E2, .len = 6 },
    .{ .linear = 95, .cp = 0x00EB, .len = 1 },
    .{ .linear = 96, .cp = 0x00EE, .len = 4 },
    .{ .linear = 100, .cp = 0x00F4, .len = 3 },
    .{ .linear = 103, .cp = 0x00F8, .len = 1 },
    .{ .linear = 104, .cp = 0x00FB, .len = 1 },
    .{ .linear = 105, .cp = 0x00FD, .len = 4 },
    .{ .linear = 109, .cp = 0x0102, .len = 17 },
    .{ .linear = 126, .cp = 0x0114, .len = 7 },
    .{ .linear = 133, .cp = 0x011C, .len = 15 },
    .{ .linear = 148, .cp = 0x012C, .len = 24 },
    .{ .linear = 172, .cp = 0x0145, .len = 3 },
    .{ .linear = 175, .cp = 0x0149, .len = 4 },
    .{ .linear = 179, .cp = 0x014E, .len = 29 },
    .{ .linear = 208, .cp = 0x016C, .len = 98 },
    .{ .linear = 306, .cp = 0x01CF, .len = 1 },
    .{ .linear = 307, .cp = 0x01D1, .len = 1 },
    .{ .linear = 308, .cp = 0x01D3, .len = 1 },
    .{ .linear = 309, .cp = 0x01D5, .len = 1 },
    .{ .linear = 310, .cp = 0x01D7, .len = 1 },
    .{ .linear = 311, .cp = 0x01D9, .len = 1 },
    .{ .linear = 312, .cp = 0x01DB, .len = 1 },
    .{ .linear = 313, .cp = 0x01DD, .len = 28 },
    .{ .linear = 341, .cp = 0x01FA, .len = 87 },
    .{ .linear = 428, .cp = 0x0252, .len = 15 },
    .{ .linear = 443, .cp = 0x0262, .len = 101 },
    .{ .linear = 544, .cp = 0x02C8, .len = 1 },
    .{ .linear = 545, .cp = 0x02CC, .len = 13 },
    .{ .linear = 558, .cp = 0x02DA, .len = 183 },
    .{ .linear = 741, .cp = 0x03A2, .len = 1 },
    .{ .linear = 742, .cp = 0x03AA, .len = 7 },
    .{ .linear = 749, .cp = 0x03C2, .len = 1 },
    .{ .linear = 750, .cp = 0x03CA, .len = 55 },
    .{ .linear = 805, .cp = 0x0402, .len = 14 },
    .{ .linear = 819, .cp = 0x0450, .len = 1 },
    .{ .linear = 820, .cp = 0x0452, .len = 7102 },
    .{ .linear = 7922, .cp = 0x2011, .len = 2 },
    .{ .linear = 7924, .cp = 0x2017, .len = 1 },
    .{ .linear = 7925, .cp = 0x201A, .len = 2 },
    .{ .linear = 7927, .cp = 0x201E, .len = 7 },
    .{ .linear = 7934, .cp = 0x2027, .len = 9 },
    .{ .linear = 7943, .cp = 0x2031, .len = 1 },
    .{ .linear = 7944, .cp = 0x2034, .len = 1 },
    .{ .linear = 7945, .cp = 0x2036, .len = 5 },
    .{ .linear = 7950, .cp = 0x203C, .len = 112 },
    .{ .linear = 8062, .cp = 0x20AD, .len = 86 },
    .{ .linear = 8148, .cp = 0x2104, .len = 1 },
    .{ .linear = 8149, .cp = 0x2106, .len = 3 },
    .{ .linear = 8152, .cp = 0x210A, .len = 12 },
    .{ .linear = 8164, .cp = 0x2117, .len = 10 },
    .{ .linear = 8174, .cp = 0x2122, .len = 62 },
    .{ .linear = 8236, .cp = 0x216C, .len = 4 },
    .{ .linear = 8240, .cp = 0x217A, .len = 22 },
    .{ .linear = 8262, .cp = 0x2194, .len = 2 },
    .{ .linear = 8264, .cp = 0x219A, .len = 110 },
    .{ .linear = 8374, .cp = 0x2209, .len = 6 },
    .{ .linear = 8380, .cp = 0x2210, .len = 1 },
    .{ .linear = 8381, .cp = 0x2212, .len = 3 },
    .{ .linear = 8384, .cp = 0x2216, .len = 4 },
    .{ .linear = 8388, .cp = 0x221B, .len = 2 },
    .{ .linear = 8390, .cp = 0x2221, .len = 2 },
    .{ .linear = 8392, .cp = 0x2224, .len = 1 },
    .{ .linear = 8393, .cp = 0x2226, .len = 1 },
    .{ .linear = 8394, .cp = 0x222C, .len = 2 },
    .{ .linear = 8396, .cp = 0x222F, .len = 5 },
    .{ .linear = 8401, .cp = 0x2238, .len = 5 },
    .{ .linear = 8406, .cp = 0x223E, .len = 10 },
    .{ .linear = 8416, .cp = 0x2249, .len = 3 },
    .{ .linear = 8419, .cp = 0x224D, .len = 5 },
    .{ .linear = 8424, .cp = 0x2253, .len = 13 },
    .{ .linear = 8437, .cp = 0x2262, .len = 2 },
    .{ .linear = 8439, .cp = 0x2268, .len = 6 },
    .{ .linear = 8445, .cp = 0x2270, .len = 37 },
    .{ .linear = 8482, .cp = 0x2296, .len = 3 },
    .{ .linear = 8485, .cp = 0x229A, .len = 11 },
    .{ .linear = 8496, .cp = 0x22A6, .len = 25 },
    .{ .linear = 8521, .cp = 0x22C0, .len = 82 },
    .{ .linear = 8603, .cp = 0x2313, .len = 333 },
    .{ .linear = 8936, .cp = 0x246A, .len = 10 },
    .{ .linear = 8946, .cp = 0x249C, .len = 100 },
    .{ .linear = 9046, .cp = 0x254C, .len = 4 },
    .{ .linear = 9050, .cp = 0x2574, .len = 13 },
    .{ .linear = 9063, .cp = 0x2590, .len = 3 },
    .{ .linear = 9066, .cp = 0x2596, .len = 10 },
    .{ .linear = 9076, .cp = 0x25A2, .len = 16 },
    .{ .linear = 9092, .cp = 0x25B4, .len = 8 },
    .{ .linear = 9100, .cp = 0x25BE, .len = 8 },
    .{ .linear = 9108, .cp = 0x25C8, .len = 3 },
    .{ .linear = 9111, .cp = 0x25CC, .len = 2 },
    .{ .linear = 9113, .cp = 0x25D0, .len = 18 },
    .{ .linear = 9131, .cp = 0x25E6, .len = 31 },
    .{ .linear = 9162, .cp = 0x2607, .len = 2 },
    .{ .linear = 9164, .cp = 0x260A, .len = 54 },
    .{ .linear = 9218, .cp = 0x2641, .len = 1 },
    .{ .linear = 9219, .cp = 0x2643, .len = 2110 },
    .{ .linear = 11329, .cp = 0x2E82, .len = 2 },
    .{ .linear = 11331, .cp = 0x2E85, .len = 3 },
    .{ .linear = 11334, .cp = 0x2E89, .len = 2 },
    .{ .linear = 11336, .cp = 0x2E8D, .len = 10 },
    .{ .linear = 11346, .cp = 0x2E98, .len = 15 },
    .{ .linear = 11361, .cp = 0x2EA8, .len = 2 },
    .{ .linear = 11363, .cp = 0x2EAB, .len = 3 },
    .{ .linear = 11366, .cp = 0x2EAF, .len = 4 },
    .{ .linear = 11370, .cp = 0x2EB4, .len = 2 },
    .{ .linear = 11372, .cp = 0x2EB8, .len = 3 },
    .{ .linear = 11375, .cp = 0x2EBC, .len = 14 },
    .{ .linear = 11389, .cp = 0x2ECB, .len = 293 },
    .{ .linear = 11682, .cp = 0x2FFC, .len = 4 },
    .{ .linear = 11686, .cp = 0x3004, .len = 1 },
    .{ .linear = 11687, .cp = 0x3018, .len = 5 },
    .{ .linear = 11692, .cp = 0x301F, .len = 2 },
    .{ .linear = 11694, .cp = 0x302A, .len = 20 },
    .{ .linear = 11714, .cp = 0x303F, .len = 2 },
    .{ .linear = 11716, .cp = 0x3094, .len = 7 },
    .{ .linear = 11723, .cp = 0x309F, .len = 2 },
    .{ .linear = 11725, .cp = 0x30F7, .len = 5 },
    .{ .linear = 11730, .cp = 0x30FF, .len = 6 },
    .{ .linear = 11736, .cp = 0x312A, .len = 246 },
    .{ .linear = 11982, .cp = 0x322A, .len = 7 },
    .{ .linear = 11989, .cp = 0x3232, .len = 113 },
    .{ .linear = 12102, .cp = 0x32A4, .len = 234 },
    .{ .linear = 12336, .cp = 0x3390, .len = 12 },
    .{ .linear = 12348, .cp = 0x339F, .len = 2 },
    .{ .linear = 12350, .cp = 0x33A2, .len = 34 },
    .{ .linear = 12384, .cp = 0x33C5, .len = 9 },
    .{ .linear = 12393, .cp = 0x33CF, .len = 2 },
    .{ .linear = 12395, .cp = 0x33D3, .len = 2 },
    .{ .linear = 12397, .cp = 0x33D6, .len = 113 },
    .{ .linear = 12510, .cp = 0x3448, .len = 43 },
    .{ .linear = 12553, .cp = 0x3474, .len = 298 },
    .{ .linear = 12851, .cp = 0x359F, .len = 111 },
    .{ .linear = 12962, .cp = 0x360F, .len = 11 },
    .{ .linear = 12973, .cp = 0x361B, .len = 765 },
    .{ .linear = 13738, .cp = 0x3919, .len = 85 },
    .{ .linear = 13823, .cp = 0x396F, .len = 96 },
    .{ .linear = 13919, .cp = 0x39D1, .len = 14 },
    .{ .linear = 13933, .cp = 0x39E0, .len = 147 },
    .{ .linear = 14080, .cp = 0x3A74, .len = 218 },
    .{ .linear = 14298, .cp = 0x3B4F, .len = 287 },
    .{ .linear = 14585, .cp = 0x3C6F, .len = 113 },
    .{ .linear = 14698, .cp = 0x3CE1, .len = 885 },
    .{ .linear = 15583, .cp = 0x4057, .len = 264 },
    .{ .linear = 15847, .cp = 0x4160, .len = 471 },
    .{ .linear = 16318, .cp = 0x4338, .len = 116 },
    .{ .linear = 16434, .cp = 0x43AD, .len = 4 },
    .{ .linear = 16438, .cp = 0x43B2, .len = 43 },
    .{ .linear = 16481, .cp = 0x43DE, .len = 248 },
    .{ .linear = 16729, .cp = 0x44D7, .len = 373 },
    .{ .linear = 17102, .cp = 0x464D, .len = 20 },
    .{ .linear = 17122, .cp = 0x4662, .len = 193 },
    .{ .linear = 17315, .cp = 0x4724, .len = 5 },
    .{ .linear = 17320, .cp = 0x472A, .len = 82 },
    .{ .linear = 17402, .cp = 0x477D, .len = 16 },
    .{ .linear = 17418, .cp = 0x478E, .len = 441 },
    .{ .linear = 17859, .cp = 0x4948, .len = 50 },
    .{ .linear = 17909, .cp = 0x497B, .len = 2 },
    .{ .linear = 17911, .cp = 0x497E, .len = 4 },
    .{ .linear = 17915, .cp = 0x4984, .len = 1 },
    .{ .linear = 17916, .cp = 0x4987, .len = 20 },
    .{ .linear = 17936, .cp = 0x499C, .len = 3 },
    .{ .linear = 17939, .cp = 0x49A0, .len = 22 },
    .{ .linear = 17961, .cp = 0x49B8, .len = 703 },
    .{ .linear = 18664, .cp = 0x4C78, .len = 39 },
    .{ .linear = 18703, .cp = 0x4CA4, .len = 111 },
    .{ .linear = 18814, .cp = 0x4D1A, .len = 148 },
    .{ .linear = 18962, .cp = 0x4DAF, .len = 81 },
    .{ .linear = 19043, .cp = 0x9FA6, .len = 14426 },
    .{ .linear = 33469, .cp = 0xE76C, .len = 1 },
    .{ .linear = 33470, .cp = 0xE7C8, .len = 1 },
    .{ .linear = 33471, .cp = 0xE7E7, .len = 13 },
    .{ .linear = 33484, .cp = 0xE815, .len = 1 },
    .{ .linear = 33485, .cp = 0xE819, .len = 5 },
    .{ .linear = 33490, .cp = 0xE81F, .len = 7 },
    .{ .linear = 33497, .cp = 0xE827, .len = 4 },
    .{ .linear = 33501, .cp = 0xE82D, .len = 4 },
    .{ .linear = 33505, .cp = 0xE833, .len = 8 },
    .{ .linear = 33513, .cp = 0xE83C, .len = 7 },
    .{ .linear = 33520, .cp = 0xE844, .len = 16 },
    .{ .linear = 33536, .cp = 0xE856, .len = 14 },
    .{ .linear = 33550, .cp = 0xE865, .len = 4295 },
    .{ .linear = 37845, .cp = 0xF92D, .len = 76 },
    .{ .linear = 37921, .cp = 0xF97A, .len = 27 },
    .{ .linear = 37948, .cp = 0xF996, .len = 81 },
    .{ .linear = 38029, .cp = 0xF9E8, .len = 9 },
    .{ .linear = 38038, .cp = 0xF9F2, .len = 26 },
    .{ .linear = 38064, .cp = 0xFA10, .len = 1 },
    .{ .linear = 38065, .cp = 0xFA12, .len = 1 },
    .{ .linear = 38066, .cp = 0xFA15, .len = 3 },
    .{ .linear = 38069, .cp = 0xFA19, .len = 6 },
    .{ .linear = 38075, .cp = 0xFA22, .len = 1 },
    .{ .linear = 38076, .cp = 0xFA25, .len = 2 },
    .{ .linear = 38078, .cp = 0xFA2A, .len = 1030 },
    .{ .linear = 39108, .cp = 0xFE32, .len = 1 },
    .{ .linear = 39109, .cp = 0xFE45, .len = 4 },
    .{ .linear = 39113, .cp = 0xFE53, .len = 1 },
    .{ .linear = 39114, .cp = 0xFE58, .len = 1 },
    .{ .linear = 39115, .cp = 0xFE67, .len = 1 },
    .{ .linear = 39116, .cp = 0xFE6C, .len = 149 },
    .{ .linear = 39265, .cp = 0xFF5F, .len = 129 },
    .{ .linear = 39394, .cp = 0xFFE6, .len = 26 },
};

/// GB18030 BMP reverse table: same ranges sorted by codepoint for reverse lookups.
/// Each entry covers Unicode [cp, cp+len) → linear [linear, linear+len).
const gb18030_rev_ranges = blk: {
    // Sort by .cp field using a comptime insertion sort.
    var sorted = gb18030_bmp_ranges;
    @setEvalBranchQuota(500_000);
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        const key = sorted[i];
        var j: usize = i;
        while (j > 0 and sorted[j - 1].cp > key.cp) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = key;
    }
    break :blk sorted;
};

/// Decode a GB18030 4-byte linear index to a Unicode codepoint.
/// linear ∈ [0..39419]       → BMP codepoint via range table
/// linear ∈ [189000..1237575] → supplementary plane: U+10000 + (linear - 189000)
fn gb18030LinearToUnicode(linear: u32) ?u21 {
    if (linear >= 189000) {
        const sup = linear - 189000;
        if (sup >= 0x110000 - 0x10000) return null;
        return @intCast(0x10000 + sup);
    }
    if (linear >= 39420) return null; // gap 39420..188999 is invalid
    // Binary search in the BMP ranges (sorted by .linear).
    const ranges = gb18030_bmp_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (linear < r.linear) {
            hi = mid;
        } else if (linear >= r.linear + r.len) {
            lo = mid + 1;
        } else {
            return r.cp + @as(u21, @intCast(linear - r.linear));
        }
    }
    return null; // gap — not a valid GB18030 4-byte codepoint
}

/// Encode a Unicode codepoint to a GB18030 4-byte linear index.
/// Returns null if the codepoint is covered by the 2-byte GBK table instead.
fn gb18030UnicodeToLinear(cp: u21) ?u32 {
    // Supplementary planes → always 4-byte GB18030
    if (cp >= 0x10000) {
        if (cp >= 0x110000) return null;
        return (cp - 0x10000) + 189000;
    }
    // BMP: binary search in reverse range table (sorted by .cp).
    const ranges = gb18030_rev_ranges;
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (@as(u32, cp) < @as(u32, r.cp)) {
            hi = mid;
        } else if (@as(u32, cp) >= @as(u32, r.cp) + r.len) {
            lo = mid + 1;
        } else {
            return r.linear + (cp - r.cp);
        }
    }
    return null; // Not a 4-byte GB18030 codepoint (either in GBK 2-byte or unmapped)
}

/// Convert a GB18030 4-byte linear index to the 4 native bytes.
fn gb18030LinearTo4Bytes(linear: u32) [4]u8 {
    const b4: u8 = @intCast(linear % 10 + 0x30);
    const r1 = linear / 10;
    const b3: u8 = @intCast(r1 % 126 + 0x81);
    const r2 = r1 / 126;
    const b2: u8 = @intCast(r2 % 10 + 0x30);
    const b1: u8 = @intCast(r2 / 10 + 0x81);
    return .{ b1, b2, b3, b4 };
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn decodeGbk(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return gbk_codec.decode(allocator, bytes);
}

pub fn encodeGbk(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return gbk_codec.encode(allocator, utf8_bytes);
}

/// Decode GB18030 bytes to UTF-8.
/// Handles 4-byte sequences as well as the full GBK 2-byte table.
pub fn decodeGb18030(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // Fast path: all-ASCII
    if (simd.allAscii(bytes)) return allocator.dupe(u8, bytes);

    // Pre-allocate: worst case is 4 input bytes → 4 UTF-8 bytes (U+10FFFF = 4 bytes)
    var buf = try allocator.alloc(u8, bytes.len + bytes.len / 2 + 4);
    errdefer allocator.free(buf);

    const REPLACEMENT: [3]u8 = .{ 0xEF, 0xBF, 0xBD }; // U+FFFD in UTF-8

    var i: usize = 0;
    var j: usize = 0;
    while (i < bytes.len) {
        const b1 = bytes[i];

        // ASCII passthrough (0x00–0x7F) with SIMD bulk copy and GBK fuse lookahead
        if (b1 < 0x80) {
            // Fuse: ASCII byte immediately followed by a GBK pair → 3-byte UTF-8
            if (i + 3 <= bytes.len) {
                const nb1 = bytes[i + 1];
                if (nb1 >= 0x81 and nb1 <= 0xFE) {
                    const nb2 = bytes[i + 2];
                    if (nb2 >= 0x40 and nb2 <= 0xFE and nb2 != 0x7F) {
                        const key: u16 = (@as(u16, nb1) << 8) | @as(u16, nb2);
                        const cp16 = gbk_codec.fwd_table[key];
                        if (cp16 >= 0x800 and cp16 != 0xFFFF) {
                            if (j + 4 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 4);
                            buf[j]   = b1;
                            buf[j+1] = @intCast(0xE0 | (cp16 >> 12));
                            buf[j+2] = @intCast(0x80 | ((cp16 >> 6) & 0x3F));
                            buf[j+3] = @intCast(0x80 | (cp16 & 0x3F));
                            j += 4; i += 3;
                            continue;
                        }
                    }
                }
            }
            const run = simd.findFirstNonAscii(bytes[i..]);
            const n = if (run > 0) run else 1;
            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
            @memcpy(buf[j..][0..n], bytes[i..][0..n]);
            j += n; i += n;
            continue;
        }

        // Lead byte for multi-byte sequences: 0x81–0xFE
        if (b1 >= 0x81 and b1 <= 0xFE and i + 1 < bytes.len) {
            const b2 = bytes[i + 1];

            // GB18030 4-byte: b2 ∈ [0x30..0x39] signals the 4-byte form
            if (b2 >= 0x30 and b2 <= 0x39 and i + 3 < bytes.len) {
                const b3 = bytes[i + 2];
                const b4 = bytes[i + 3];
                if (b3 >= 0x81 and b3 <= 0xFE and b4 >= 0x30 and b4 <= 0x39) {
                    const linear: u32 = @as(u32, b1 - 0x81) * 12600 +
                        @as(u32, b2 - 0x30) * 1260 +
                        @as(u32, b3 - 0x81) * 10 +
                        @as(u32, b4 - 0x30);
                    const cp = gb18030LinearToUnicode(linear) orelse {
                        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
                        buf[j..][0..3].* = REPLACEMENT;
                        j += 3; i += 4;
                        continue;
                    };
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
                        buf[j..][0..3].* = REPLACEMENT;
                        j += 3; i += 4;
                        continue;
                    };
                    if (j + utf8_len > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 4);
                    @memcpy(buf[j..][0..utf8_len], utf8_buf[0..utf8_len]);
                    j += utf8_len; i += 4;
                    continue;
                }
            }

            // GBK 2-byte: b2 ∈ [0x40..0xFE] (excluding 0x7F)
            if (b2 >= 0x40 and b2 <= 0xFE and b2 != 0x7F) {
                const key: u16 = (@as(u16, b1) << 8) | @as(u16, b2);
                const cp16 = gbk_codec.fwd_table[key];
                if (cp16 != 0xFFFF) {
                    if (cp16 >= 0x800) {
                        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
                        buf[j]   = @intCast(0xE0 | (cp16 >> 12));
                        buf[j+1] = @intCast(0x80 | ((cp16 >> 6) & 0x3F));
                        buf[j+2] = @intCast(0x80 | (cp16 & 0x3F));
                        j += 3; i += 2;
                    } else {
                        if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 2);
                        buf[j]   = @intCast(0xC0 | (cp16 >> 6));
                        buf[j+1] = @intCast(0x80 | (cp16 & 0x3F));
                        j += 2; i += 2;
                    }
                    continue;
                }
            }
        }

        // Anything else → U+FFFD and consume 1 byte
        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
        buf[j..][0..3].* = REPLACEMENT;
        j += 3; i += 1;
    }

    return allocator.realloc(buf, j);
}

/// Encode UTF-8 to GB18030.
/// GBK 2-byte sequences are used for all GBK-covered characters.
/// GB18030 4-byte sequences are used for supplementary and BMP-extension characters.
pub fn encodeGb18030(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    // Fast path: all-ASCII
    if (simd.allAscii(utf8_bytes)) return allocator.dupe(u8, utf8_bytes);

    // Pre-allocate: most CJK chars → 2 bytes; worst case 4 bytes per char
    var buf = try allocator.alloc(u8, utf8_bytes.len + utf8_bytes.len / 2 + 4);
    errdefer allocator.free(buf);

    var i: usize = 0;
    var j: usize = 0;
    while (i < utf8_bytes.len) {
        const byte = utf8_bytes[i];

        // ASCII passthrough with SIMD bulk copy and fused GBK encode lookahead
        if (byte < 0x80) {
            // Fuse: ASCII followed by a 3-byte UTF-8 CJK → GBK 2-byte in one step
            if (i + 4 <= utf8_bytes.len) {
                const b1 = utf8_bytes[i + 1];
                if (b1 >= 0xE0 and b1 <= 0xEF) {
                    const b2 = utf8_bytes[i + 2];
                    const b3 = utf8_bytes[i + 3];
                    const cp16: u16 = @intCast(
                        (@as(u21, b1 & 0x0F) << 12) |
                        (@as(u21, b2 & 0x3F) << 6) |
                        @as(u21, b3 & 0x3F)
                    );
                    const nat = gbk_codec.rev_table[cp16];
                    if (nat != 0xFFFF) {
                        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
                        buf[j]   = byte;
                        buf[j+1] = @intCast(nat >> 8);
                        buf[j+2] = @intCast(nat & 0xFF);
                        j += 3; i += 4;
                        continue;
                    }
                }
            }
            const run = simd.findFirstNonAscii(utf8_bytes[i..]);
            const n = if (run > 0) run else 1;
            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
            @memcpy(buf[j..][0..n], utf8_bytes[i..][0..n]);
            j += n; i += n;
            continue;
        }

        // Decode UTF-8 codepoint
        const cp_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 1);
            buf[j] = '?'; j += 1; i += 1;
            continue;
        };
        if (i + cp_len > utf8_bytes.len) {
            if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 1);
            buf[j] = '?'; j += 1; i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(utf8_bytes[i .. i + cp_len]) catch {
            if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 1);
            buf[j] = '?'; j += 1; i += 1;
            continue;
        };
        i += cp_len;

        // Try GBK 2-byte encoding first (covers most CJK)
        if (cp <= 0xFFFF) {
            const nat = gbk_codec.rev_table[@intCast(cp)];
            if (nat != 0xFFFF) {
                if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 2);
                buf[j]   = @intCast(nat >> 8);
                buf[j+1] = @intCast(nat & 0xFF);
                j += 2;
                continue;
            }
        }

        // Try GB18030 4-byte encoding (supplementary + BMP extensions)
        if (gb18030UnicodeToLinear(cp)) |linear| {
            const seq = gb18030LinearTo4Bytes(linear);
            if (j + 4 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 4);
            buf[j..][0..4].* = seq;
            j += 4;
            continue;
        }

        // Unmapped → '?'
        if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 1);
        buf[j] = '?'; j += 1;
    }

    return allocator.realloc(buf, j);
}

// ── cp950 compatibility patches ───────────────────────────────────────────────
//
// Windows cp950 (Traditional Chinese) differs from the standard BIG5.TXT in 7
// codepoints.  Applying these patches when reading/writing Big5 files ensures
// round-trip compatibility with Windows applications.
//
// Source: CPython Modules/cjkcodecs/README and genmap_tchinese.py
//
//   BIG5    Unicode  Note
//   0xA15A  U+2574   BOX DRAWINGS LIGHT LEFT
//   0xA1C3  U+FFE3   FULLWIDTH MACRON
//   0xA1C5  U+02CD   MODIFIER LETTER LOW MACRON
//   0xA1FE  U+FF0F   FULLWIDTH SOLIDUS
//   0xA240  U+FF3C   FULLWIDTH REVERSE SOLIDUS
//   0xA2CC  U+5341   HANGZHOU NUMERAL TEN  (duplicate → encode non-roundtrip)
//   0xA2CE  U+5345   HANGZHOU NUMERAL THIRTY (duplicate → encode non-roundtrip)

const Cp950Patch = struct { big5: u16, cp: u21 };

/// cp950 decode overrides: Big5 native key → Unicode codepoint.
const cp950_decode_patches = [_]Cp950Patch{
    .{ .big5 = 0xA15A, .cp = 0x2574 },
    .{ .big5 = 0xA1C3, .cp = 0xFFE3 },
    .{ .big5 = 0xA1C5, .cp = 0x02CD },
    .{ .big5 = 0xA1FE, .cp = 0xFF0F },
    .{ .big5 = 0xA240, .cp = 0xFF3C },
    .{ .big5 = 0xA2CC, .cp = 0x5341 },
    .{ .big5 = 0xA2CE, .cp = 0x5345 },
};

/// cp950 encode overrides: Unicode codepoint → Big5 byte pair.
/// Only the 5 non-duplicate codepoints are listed (U+5341/U+5345 already have
/// canonical Big5 encodings, so we do not override them in the encode direction).
const cp950_encode_patches = [_]Cp950Patch{
    .{ .big5 = 0xA15A, .cp = 0x2574 },
    .{ .big5 = 0xA1C3, .cp = 0xFFE3 },
    .{ .big5 = 0xA1C5, .cp = 0x02CD },
    .{ .big5 = 0xA1FE, .cp = 0xFF0F },
    .{ .big5 = 0xA240, .cp = 0xFF3C },
};

/// Comptime-patched cp950 forward table: Big5 native key → Unicode u16.
/// The 7 cp950 decode patches are pre-applied so no runtime patch scan is needed.
const cp950_fwd_table: [65536]u16 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [65536]u16 = big5_codec.fwd_table;
    for (cp950_decode_patches) |patch| {
        table[patch.big5] = @intCast(patch.cp);
    }
    break :blk table;
};

/// Comptime-patched cp950 reverse table: Unicode u16 → Big5 native key.
/// The 5 cp950 encode patches are pre-applied.
const cp950_rev_table: [65536]u16 = blk: {
    @setEvalBranchQuota(200_000);
    var table: [65536]u16 = big5_codec.rev_table;
    for (cp950_encode_patches) |patch| {
        table[@intCast(patch.cp)] = patch.big5;
    }
    break :blk table;
};

pub fn decodeBig5(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const capacity = bytes.len + bytes.len / 2 + 4;
    var buf = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buf);
    var j: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b < 0x80) {
            // Fuse: ASCII byte + Big5 DBCS pair → 1 ASCII + 3-byte UTF-8 in one step.
            // Use cp950_fwd_table (patches pre-applied) for O(1) lookup — no runtime scan.
            if (i + 3 <= bytes.len) {
                const native_key: u16 = (@as(u16, bytes[i + 1]) << 8) | @as(u16, bytes[i + 2]);
                const cp16 = cp950_fwd_table[native_key];
                if (cp16 >= 0x800 and cp16 != 0xFFFF) {
                    if (j + 4 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
                    buf[j]     = b;
                    buf[j + 1] = @intCast(0xE0 | (cp16 >> 12));
                    buf[j + 2] = @intCast(0x80 | ((cp16 >> 6) & 0x3F));
                    buf[j + 3] = @intCast(0x80 | (cp16 & 0x3F));
                    j += 4;
                    i += 3;
                    continue;
                }
            }
            // Fallback: copy ASCII run in bulk.
            const run = simd.findFirstNonAscii(bytes[i..]);
            const n = if (run > 0) run else 1;
            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
            @memcpy(buf[j .. j + n], bytes[i .. i + n]);
            j += n;
            i += n;
            continue;
        }
        // Big5 lead byte: 0x81..0xFE; trail: 0x40..0x7E or 0xA1..0xFE
        if (b >= 0x81 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if ((t >= 0x40 and t <= 0x7E) or (t >= 0xA1 and t <= 0xFE)) {
                const native_key: u16 = (@as(u16, b) << 8) | @as(u16, t);
                const cp16 = cp950_fwd_table[native_key];
                const mapped = if (cp16 == 0xFFFF) @as(u16, 0xFFFD) else cp16;
                // Inline UTF-8 write: all Big5/cp950 codepoints are BMP (≤ U+FFFF).
                if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
                if (mapped >= 0x800) {
                    buf[j]     = @intCast(0xE0 | (mapped >> 12));
                    buf[j + 1] = @intCast(0x80 | ((mapped >> 6) & 0x3F));
                    buf[j + 2] = @intCast(0x80 | (mapped & 0x3F));
                    j += 3;
                } else if (mapped >= 0x80) {
                    buf[j]     = @intCast(0xC0 | (mapped >> 6));
                    buf[j + 1] = @intCast(0x80 | (mapped & 0x3F));
                    j += 2;
                } else {
                    buf[j] = @intCast(mapped);
                    j += 1;
                }
                i += 2;
                continue;
            }
        }
        // Unmapped / lone lead byte → U+FFFD
        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        buf[j] = 0xEF; buf[j + 1] = 0xBF; buf[j + 2] = 0xBD;
        j += 3;
        i += 1;
    }
    return allocator.realloc(buf, j);
}

pub fn encodeBig5(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    var buf = try allocator.alloc(u8, utf8_bytes.len);
    errdefer allocator.free(buf);
    var j: usize = 0;
    var i: usize = 0;
    while (i < utf8_bytes.len) {
        const b0 = utf8_bytes[i];
        if (b0 < 0x80) {
            // Fuse: ASCII byte + 3-byte CJK UTF-8 → ASCII + 2-byte Big5 in one step.
            // Use cp950_rev_table (patches pre-applied) for O(1) lookup.
            if (i + 4 <= utf8_bytes.len) {
                const b1 = utf8_bytes[i + 1];
                if (b1 >= 0xE0 and b1 <= 0xEF) {
                    const b2 = utf8_bytes[i + 2];
                    const b3 = utf8_bytes[i + 3];
                    const cp: u21 = (@as(u21, b1 & 0x0F) << 12) | (@as(u21, b2 & 0x3F) << 6) | @as(u21, b3 & 0x3F);
                    if (cp <= 0xFFFF) {
                        const nk = cp950_rev_table[@intCast(cp)];
                        if (nk != 0xFFFF) {
                            if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
                            buf[j]     = b0;
                            buf[j + 1] = @intCast(nk >> 8);
                            buf[j + 2] = @intCast(nk & 0xFF);
                            j += 3;
                            i += 4;
                            continue;
                        }
                    }
                }
            }
            const run = simd.findFirstNonAscii(utf8_bytes[i..]);
            const n = if (run > 0) run else 1;
            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
            @memcpy(buf[j .. j + n], utf8_bytes[i .. i + n]);
            j += n;
            i += n;
            continue;
        }
        // Inline UTF-8 decode: fast path for 3-byte CJK sequences (0xE0-0xEF).
        if (b0 >= 0xE0 and b0 <= 0xEF and i + 3 <= utf8_bytes.len) {
            const b1 = utf8_bytes[i + 1];
            const b2 = utf8_bytes[i + 2];
            const cp: u21 = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F);
            if (cp <= 0xFFFF) {
                const nk = cp950_rev_table[@intCast(cp)];
                if (nk != 0xFFFF) {
                    if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 2);
                    buf[j]     = @intCast(nk >> 8);
                    buf[j + 1] = @intCast(nk & 0xFF);
                    j += 2;
                    i += 3;
                    continue;
                }
            }
            if (j + 1 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
            buf[j] = '?'; j += 1;
            i += 3;
            continue;
        }
        // 2-byte UTF-8 sequences (0xC0-0xDF).
        if (b0 >= 0xC0 and b0 <= 0xDF and i + 2 <= utf8_bytes.len) {
            const b1 = utf8_bytes[i + 1];
            const cp: u21 = (@as(u21, b0 & 0x1F) << 6) | @as(u21, b1 & 0x3F);
            if (cp <= 0xFFFF) {
                const nk = cp950_rev_table[@intCast(cp)];
                if (nk != 0xFFFF) {
                    if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 2);
                    buf[j]     = @intCast(nk >> 8);
                    buf[j + 1] = @intCast(nk & 0xFF);
                    j += 2;
                    i += 2;
                    continue;
                }
            }
            if (j + 1 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
            buf[j] = '?'; j += 1;
            i += 2;
            continue;
        }
        // Invalid or 4-byte sequences → '?'
        if (j + 1 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        buf[j] = '?'; j += 1;
        const seq_len: usize = if (b0 >= 0xF0) 4 else if (b0 >= 0xE0) 3 else if (b0 >= 0xC0) 2 else 1;
        i += seq_len;
    }
    return allocator.realloc(buf, j);
}

pub fn decodeShiftJis(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return shiftjis_codec.decode(allocator, bytes);
}

pub fn encodeShiftJis(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return shiftjis_codec.encode(allocator, utf8_bytes);
}

pub fn decodeEucKr(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return euckr_codec.decode(allocator, bytes);
}

pub fn encodeEucKr(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return euckr_codec.encode(allocator, utf8_bytes);
}

pub fn decodeEucJp(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    return eucjp_codec.decode(allocator, bytes);
}

pub fn encodeEucJp(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
    return eucjp_codec.encode(allocator, utf8_bytes);
}

test "GB18030 4-byte round-trip" {
    // U+20000 (𠀀) encoded in GB18030 4-byte
    const alloc = std.testing.allocator;
    const utf8_input = "\xF0\xA0\x80\x80"; // U+20000 in UTF-8
    const encoded = try encodeGb18030(alloc, utf8_input);
    defer alloc.free(encoded);
    const decoded = try decodeGb18030(alloc, encoded);
    defer alloc.free(decoded);
    try std.testing.expectEqualSlices(u8, utf8_input, decoded);
}

test "GBK 2-byte basic" {
    // GBK 0xC4E3 = U+4F60 (你)
    try std.testing.expect(gbk_codec.fwd_table[0xC4E3] == 0x4F60);
}
