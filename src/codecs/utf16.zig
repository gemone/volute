const std = @import("std");

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian) ![]u8 {
    // Strip BOM if present.
    var start: usize = 0;
    if (bytes.len >= 2) {
        const b0 = bytes[0];
        const b1 = bytes[1];
        if ((endian == .little and b0 == 0xFF and b1 == 0xFE) or
            (endian == .big and b0 == 0xFE and b1 == 0xFF))
        {
            start = 2;
        }
    }
    const payload = bytes[start..];
    if (payload.len % 2 != 0) return error.InvalidEncoding;

    // Pre-alloc worst-case + 4 bytes padding for "write 4, advance 3" store trick.
    const cap = payload.len / 2 * 3 + 4;
    var buf = try allocator.alloc(u8, cap);
    errdefer allocator.free(buf);
    var j: usize = 0;

    var i: usize = 0;
    // ── SIMD-ish batch: process 8 LE code units (16 bytes) → 24 bytes UTF-8 ──
    // Only taken when all 8 are BMP non-surrogate >= 0x0800 (3-byte UTF-8).
    // Covers the common CJK / high-Latin batch case.
    if (endian == .little) {
        while (i + 16 <= payload.len) {
            // Bitcast 16 bytes → 8 LE u16 values in one instruction.
            const raw: @Vector(8, u16) = @bitCast(payload[i..][0..16].*);
            // SIMD range checks: all >= 0x800 and none in surrogate range [0xD800,0xDFFF].
            const above: @Vector(8, u16) = @splat(0x800);
            const slo:   @Vector(8, u16) = @splat(0xD800);
            const shi:   @Vector(8, u16) = @splat(0xDFFF);
            const lo_ok   = @reduce(.And, raw >= above);
            const no_surr = @reduce(.And, (raw < slo) | (raw > shi));
            if (!lo_ok or !no_surr) break;
            // Emit 8 × 3-byte UTF-8 sequences = 24 bytes.
            inline for (0..8) |k| {
                const cu = raw[k];
                const val: u32 = @as(u32, 0xE0 | (cu >> 12)) |
                    (@as(u32, 0x80 | ((cu >> 6) & 0x3F)) << 8) |
                    (@as(u32, 0x80 | (cu & 0x3F)) << 16);
                std.mem.writeInt(u32, buf[j + k * 3..][0..4], val, .little);
            }
            i += 16;
            j += 24;
        }
    }

    // ── Scalar fallback: handles ASCII, 2-byte, surrogates, BE, and tail ──
    while (i + 2 <= payload.len) {
        const b0 = payload[i];
        const b1 = payload[i + 1];
        const cu: u16 = if (endian == .little)
            @as(u16, b0) | (@as(u16, b1) << 8)
        else
            (@as(u16, b0) << 8) | @as(u16, b1);
        i += 2;

        if (cu < 0xD800 or cu > 0xDFFF) {
            if (cu < 0x80) {
                buf[j] = @intCast(cu);
                j += 1;
            } else if (cu < 0x800) {
                buf[j]     = @intCast(0xC0 | (cu >> 6));
                buf[j + 1] = @intCast(0x80 | (cu & 0x3F));
                j += 2;
            } else {
                buf[j]     = @intCast(0xE0 | (cu >> 12));
                buf[j + 1] = @intCast(0x80 | ((cu >> 6) & 0x3F));
                buf[j + 2] = @intCast(0x80 | (cu & 0x3F));
                j += 3;
            }
        } else if (cu <= 0xDBFF) {
            // High surrogate — need a following low surrogate.
            if (i + 2 > payload.len) {
                buf[j] = 0xEF; buf[j + 1] = 0xBF; buf[j + 2] = 0xBD;
                j += 3;
                break;
            }
            const b2 = payload[i];
            const b3 = payload[i + 1];
            const cu2: u16 = if (endian == .little)
                @as(u16, b2) | (@as(u16, b3) << 8)
            else
                (@as(u16, b2) << 8) | @as(u16, b3);
            if (cu2 < 0xDC00 or cu2 > 0xDFFF) {
                buf[j] = 0xEF; buf[j + 1] = 0xBF; buf[j + 2] = 0xBD;
                j += 3;
                continue;
            }
            i += 2;
            const cp: u21 = 0x10000 +
                (@as(u21, cu - 0xD800) << 10) + @as(u21, cu2 - 0xDC00);
            // Supplementary plane: need 4 bytes; buf was sized for 3 max, so check.
            if (j + 4 > buf.len) {
                buf = try allocator.realloc(buf, buf.len + 64);
            }
            buf[j]     = @intCast(0xF0 | (cp >> 18));
            buf[j + 1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
            buf[j + 2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
            buf[j + 3] = @intCast(0x80 | (cp & 0x3F));
            j += 4;
        } else {
            // Lone low surrogate → U+FFFD.
            buf[j] = 0xEF; buf[j + 1] = 0xBF; buf[j + 2] = 0xBD;
            j += 3;
        }
    }
    return allocator.realloc(buf, j);
}

pub fn encode(allocator: std.mem.Allocator, utf8_bytes: []const u8, endian: std.builtin.Endian) ![]u8 {
    // Pre-alloc: BOM (2) + worst-case 2 bytes per UTF-8 byte.
    // realloc to exact size at end.
    const cap = 2 + utf8_bytes.len * 2;
    var buf = try allocator.alloc(u8, cap);
    errdefer allocator.free(buf);

    // Write BOM.
    if (endian == .little) {
        buf[0] = 0xFF; buf[1] = 0xFE;
    } else {
        buf[0] = 0xFE; buf[1] = 0xFF;
    }
    var j: usize = 2;

    var i: usize = 0;
    while (i < utf8_bytes.len) {
        // SIMD-ish batch: process 8 × 3-byte UTF-8 → 8 × 2-byte UTF-16 LE.
        // Only for LE, when all 8 leads are 0xE0-0xEF (3-byte, BMP range).
        if (endian == .little) {
            while (i + 24 <= utf8_bytes.len) {
                const leads: @Vector(8, u8) = .{
                    utf8_bytes[i + 0],  utf8_bytes[i + 3],  utf8_bytes[i + 6],  utf8_bytes[i + 9],
                    utf8_bytes[i + 12], utf8_bytes[i + 15], utf8_bytes[i + 18], utf8_bytes[i + 21],
                };
                const ok = @reduce(.And, leads >= @as(@Vector(8, u8), @splat(0xE0))) and
                           @reduce(.And, leads <= @as(@Vector(8, u8), @splat(0xEF)));
                if (!ok) break;
                inline for (0..8) |k| {
                    const b0 = utf8_bytes[i + k * 3];
                    const b1 = utf8_bytes[i + k * 3 + 1];
                    const b2 = utf8_bytes[i + k * 3 + 2];
                    const cu: u16 = @intCast((@as(u21, b0 & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | @as(u21, b2 & 0x3F));
                    buf[j + k * 2]     = @intCast(cu & 0xFF);
                    buf[j + k * 2 + 1] = @intCast(cu >> 8);
                }
                i += 24;
                j += 16;
            }
        }
        if (i >= utf8_bytes.len) break;
        const b = utf8_bytes[i];
        const cp: u21 = blk: {
            if (b < 0x80) {
                i += 1;
                break :blk @as(u21, b);
            }
            if (b < 0xC0 or b > 0xF7) {
                i += 1;
                break :blk @as(u21, 0xFFFD);
            }
            const seq_len: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
            if (i + seq_len > utf8_bytes.len) {
                i = utf8_bytes.len;
                break :blk @as(u21, 0xFFFD);
            }
            const c: u21 = switch (seq_len) {
                2 => @as(u21, b & 0x1F) << 6 | @as(u21, utf8_bytes[i + 1] & 0x3F),
                3 => @as(u21, b & 0x0F) << 12 | @as(u21, utf8_bytes[i + 1] & 0x3F) << 6 | @as(u21, utf8_bytes[i + 2] & 0x3F),
                else => @as(u21, b & 0x07) << 18 | @as(u21, utf8_bytes[i + 1] & 0x3F) << 12 | @as(u21, utf8_bytes[i + 2] & 0x3F) << 6 | @as(u21, utf8_bytes[i + 3] & 0x3F),
            };
            i += seq_len;
            break :blk c;
        };

        if (cp < 0x10000) {
            const cu: u16 = @intCast(cp);
            if (endian == .little) {
                buf[j]     = @intCast(cu & 0xFF);
                buf[j + 1] = @intCast(cu >> 8);
            } else {
                buf[j]     = @intCast(cu >> 8);
                buf[j + 1] = @intCast(cu & 0xFF);
            }
            j += 2;
        } else {
            // Surrogate pair for U+10000+.
            const adjusted = cp - 0x10000;
            const high: u16 = @intCast(0xD800 + (adjusted >> 10));
            const low: u16  = @intCast(0xDC00 + (adjusted & 0x3FF));
            if (endian == .little) {
                buf[j]     = @intCast(high & 0xFF);
                buf[j + 1] = @intCast(high >> 8);
                buf[j + 2] = @intCast(low & 0xFF);
                buf[j + 3] = @intCast(low >> 8);
            } else {
                buf[j]     = @intCast(high >> 8);
                buf[j + 1] = @intCast(high & 0xFF);
                buf[j + 2] = @intCast(low >> 8);
                buf[j + 3] = @intCast(low & 0xFF);
            }
            j += 4;
        }
    }
    return allocator.realloc(buf, j);
}
