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

// ── Unicode character width utilities ────────────────────────────────────────────

const CodepointRange = struct {
    start: u21,
    end: u21,
};

fn inRanges(codepoint: u21, ranges: []const CodepointRange) bool {
    for (ranges) |range| {
        if (codepoint >= range.start and codepoint <= range.end) return true;
    }
    return false;
}

/// Display width of a codepoint in terminal cells (0, 1, or 2).
pub fn codepointCellWidth(codepoint: u21) usize {
    if (codepoint == 0) return 0;
    if (codepoint < 0x20 or (codepoint >= 0x7F and codepoint < 0xA0)) return 1;
    if (isZeroWidthCodepoint(codepoint)) return 0;
    if (isWideCodepoint(codepoint)) return 2;
    return 1;
}

/// Line number column width: at least 3 digits.
pub fn lineWidth(line_count: usize) usize {
    return @max(3, std.fmt.count("{d}", .{line_count}));
}

/// Display cell count up to a column position in a line.
pub fn displayCellsToColumn(line: []const u8, col: usize) usize {
    const target = boundary(line).alignColumn(col, true);
    var used_cells: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const start = iter.i - slice.len;
        if (start >= target) break;
        used_cells += codepointCellWidth(std.unicode.utf8Decode(slice) catch std.unicode.replacement_character);
    }
    return used_cells;
}

/// Display cell count up to a column position, reading the line from a buffer.
pub fn displayCellsToColumnFromBuf(buf: anytype, row: usize, col: usize) usize {
    const line = buf.getLine(row) orelse return 0;
    return displayCellsToColumn(line, col);
}

fn isZeroWidthCodepoint(codepoint: u21) bool {
    return inRanges(codepoint, &.{
        .{ .start = 0x0300, .end = 0x036F },
        .{ .start = 0x0483, .end = 0x0489 },
        .{ .start = 0x0591, .end = 0x05BD },
        .{ .start = 0x05BF, .end = 0x05BF },
        .{ .start = 0x05C1, .end = 0x05C2 },
        .{ .start = 0x05C4, .end = 0x05C5 },
        .{ .start = 0x05C7, .end = 0x05C7 },
        .{ .start = 0x0610, .end = 0x061A },
        .{ .start = 0x064B, .end = 0x065F },
        .{ .start = 0x0670, .end = 0x0670 },
        .{ .start = 0x06D6, .end = 0x06DD },
        .{ .start = 0x06DF, .end = 0x06E4 },
        .{ .start = 0x06E7, .end = 0x06E8 },
        .{ .start = 0x06EA, .end = 0x06ED },
        .{ .start = 0x0711, .end = 0x0711 },
        .{ .start = 0x0730, .end = 0x074A },
        .{ .start = 0x07A6, .end = 0x07B0 },
        .{ .start = 0x07EB, .end = 0x07F3 },
        .{ .start = 0x0816, .end = 0x0819 },
        .{ .start = 0x081B, .end = 0x0823 },
        .{ .start = 0x0825, .end = 0x0827 },
        .{ .start = 0x0829, .end = 0x082D },
        .{ .start = 0x0859, .end = 0x085B },
        .{ .start = 0x08D3, .end = 0x0902 },
        .{ .start = 0x093A, .end = 0x093A },
        .{ .start = 0x093C, .end = 0x093C },
        .{ .start = 0x0941, .end = 0x0948 },
        .{ .start = 0x094D, .end = 0x094D },
        .{ .start = 0x0951, .end = 0x0957 },
        .{ .start = 0x0962, .end = 0x0963 },
        .{ .start = 0x0981, .end = 0x0981 },
        .{ .start = 0x09BC, .end = 0x09BC },
        .{ .start = 0x09C1, .end = 0x09C4 },
        .{ .start = 0x09CD, .end = 0x09CD },
        .{ .start = 0x09E2, .end = 0x09E3 },
        .{ .start = 0x0A01, .end = 0x0A02 },
        .{ .start = 0x0A3C, .end = 0x0A3C },
        .{ .start = 0x0A41, .end = 0x0A42 },
        .{ .start = 0x0A47, .end = 0x0A48 },
        .{ .start = 0x0A4B, .end = 0x0A4D },
        .{ .start = 0x0A51, .end = 0x0A51 },
        .{ .start = 0x0A70, .end = 0x0A71 },
        .{ .start = 0x0A75, .end = 0x0A75 },
        .{ .start = 0x0A81, .end = 0x0A82 },
        .{ .start = 0x0ABC, .end = 0x0ABC },
        .{ .start = 0x0AC1, .end = 0x0AC5 },
        .{ .start = 0x0AC7, .end = 0x0AC8 },
        .{ .start = 0x0ACD, .end = 0x0ACD },
        .{ .start = 0x0AE2, .end = 0x0AE3 },
        .{ .start = 0x0B01, .end = 0x0B01 },
        .{ .start = 0x0B3C, .end = 0x0B3C },
        .{ .start = 0x0B3F, .end = 0x0B3F },
        .{ .start = 0x0B41, .end = 0x0B44 },
        .{ .start = 0x0B4D, .end = 0x0B4D },
        .{ .start = 0x0B56, .end = 0x0B56 },
        .{ .start = 0x0B62, .end = 0x0B63 },
        .{ .start = 0x0B82, .end = 0x0B82 },
        .{ .start = 0x0BC0, .end = 0x0BC0 },
        .{ .start = 0x0BCD, .end = 0x0BCD },
        .{ .start = 0x0C00, .end = 0x0C00 },
        .{ .start = 0x0C3E, .end = 0x0C40 },
        .{ .start = 0x0C46, .end = 0x0C48 },
        .{ .start = 0x0C4A, .end = 0x0C4D },
        .{ .start = 0x0C55, .end = 0x0C56 },
        .{ .start = 0x0C62, .end = 0x0C63 },
        .{ .start = 0x0C81, .end = 0x0C81 },
        .{ .start = 0x0CBC, .end = 0x0CBC },
        .{ .start = 0x0CBF, .end = 0x0CBF },
        .{ .start = 0x0CC6, .end = 0x0CC6 },
        .{ .start = 0x0CCC, .end = 0x0CCD },
        .{ .start = 0x0CE2, .end = 0x0CE3 },
        .{ .start = 0x0D00, .end = 0x0D01 },
        .{ .start = 0x0D3B, .end = 0x0D3C },
        .{ .start = 0x0D41, .end = 0x0D44 },
        .{ .start = 0x0D4D, .end = 0x0D4D },
        .{ .start = 0x0D62, .end = 0x0D63 },
        .{ .start = 0x0DCA, .end = 0x0DCA },
        .{ .start = 0x0DD2, .end = 0x0DD4 },
        .{ .start = 0x0DD6, .end = 0x0DD6 },
        .{ .start = 0x0E31, .end = 0x0E31 },
        .{ .start = 0x0E34, .end = 0x0E3A },
        .{ .start = 0x0E47, .end = 0x0E4E },
        .{ .start = 0x0EB1, .end = 0x0EB1 },
        .{ .start = 0x0EB4, .end = 0x0EBC },
        .{ .start = 0x0EC8, .end = 0x0ECD },
        .{ .start = 0x0F18, .end = 0x0F19 },
        .{ .start = 0x0F35, .end = 0x0F35 },
        .{ .start = 0x0F37, .end = 0x0F37 },
        .{ .start = 0x0F39, .end = 0x0F39 },
        .{ .start = 0x0F71, .end = 0x0F7E },
        .{ .start = 0x0F80, .end = 0x0F84 },
        .{ .start = 0x0F86, .end = 0x0F87 },
        .{ .start = 0x0F8D, .end = 0x0F97 },
        .{ .start = 0x0F99, .end = 0x0FBC },
        .{ .start = 0x0FC6, .end = 0x0FC6 },
        .{ .start = 0x102D, .end = 0x1030 },
        .{ .start = 0x1032, .end = 0x1037 },
        .{ .start = 0x1039, .end = 0x103A },
        .{ .start = 0x103D, .end = 0x103E },
        .{ .start = 0x1058, .end = 0x1059 },
        .{ .start = 0x105E, .end = 0x1060 },
        .{ .start = 0x1071, .end = 0x1074 },
        .{ .start = 0x1082, .end = 0x1082 },
        .{ .start = 0x1085, .end = 0x1086 },
        .{ .start = 0x108D, .end = 0x108D },
        .{ .start = 0x109D, .end = 0x109D },
        .{ .start = 0x135D, .end = 0x135F },
        .{ .start = 0x1712, .end = 0x1714 },
        .{ .start = 0x1732, .end = 0x1734 },
        .{ .start = 0x1752, .end = 0x1753 },
        .{ .start = 0x1772, .end = 0x1773 },
        .{ .start = 0x17B4, .end = 0x17B5 },
        .{ .start = 0x17B7, .end = 0x17BD },
        .{ .start = 0x17C6, .end = 0x17C6 },
        .{ .start = 0x17C9, .end = 0x17D3 },
        .{ .start = 0x17DD, .end = 0x17DD },
        .{ .start = 0x180B, .end = 0x180D },
        .{ .start = 0x1885, .end = 0x1886 },
        .{ .start = 0x18A9, .end = 0x18A9 },
        .{ .start = 0x1920, .end = 0x1922 },
        .{ .start = 0x1927, .end = 0x1928 },
        .{ .start = 0x1932, .end = 0x1932 },
        .{ .start = 0x1939, .end = 0x193B },
        .{ .start = 0x1A17, .end = 0x1A18 },
        .{ .start = 0x1A1B, .end = 0x1A1B },
        .{ .start = 0x1A56, .end = 0x1A56 },
        .{ .start = 0x1A58, .end = 0x1A5E },
        .{ .start = 0x1A60, .end = 0x1A60 },
        .{ .start = 0x1A62, .end = 0x1A62 },
        .{ .start = 0x1A65, .end = 0x1A6C },
        .{ .start = 0x1A73, .end = 0x1A7C },
        .{ .start = 0x1A7F, .end = 0x1A7F },
        .{ .start = 0x1AB0, .end = 0x1ACE },
        .{ .start = 0x1B00, .end = 0x1B03 },
        .{ .start = 0x1B34, .end = 0x1B34 },
        .{ .start = 0x1B36, .end = 0x1B3A },
        .{ .start = 0x1B3C, .end = 0x1B3C },
        .{ .start = 0x1B42, .end = 0x1B42 },
        .{ .start = 0x1B6B, .end = 0x1B73 },
        .{ .start = 0x1B80, .end = 0x1B81 },
        .{ .start = 0x1BA2, .end = 0x1BA5 },
        .{ .start = 0x1BA8, .end = 0x1BA9 },
        .{ .start = 0x1BAB, .end = 0x1BAD },
        .{ .start = 0x1BE6, .end = 0x1BE6 },
        .{ .start = 0x1BE8, .end = 0x1BE9 },
        .{ .start = 0x1BED, .end = 0x1BED },
        .{ .start = 0x1BEF, .end = 0x1BF1 },
        .{ .start = 0x1C2C, .end = 0x1C33 },
        .{ .start = 0x1C36, .end = 0x1C37 },
        .{ .start = 0x1CD0, .end = 0x1CD2 },
        .{ .start = 0x1CD4, .end = 0x1CE0 },
        .{ .start = 0x1CE2, .end = 0x1CE8 },
        .{ .start = 0x1CED, .end = 0x1CED },
        .{ .start = 0x1CF4, .end = 0x1CF4 },
        .{ .start = 0x1CF8, .end = 0x1CF9 },
        .{ .start = 0x1DC0, .end = 0x1DFF },
        .{ .start = 0x200B, .end = 0x200F },
        .{ .start = 0x202A, .end = 0x202E },
        .{ .start = 0x2060, .end = 0x2064 },
        .{ .start = 0x2066, .end = 0x206F },
        .{ .start = 0x20D0, .end = 0x20F0 },
        .{ .start = 0x2CEF, .end = 0x2CF1 },
        .{ .start = 0x2D7F, .end = 0x2D7F },
        .{ .start = 0x2DE0, .end = 0x2DFF },
        .{ .start = 0x302A, .end = 0x302F },
        .{ .start = 0x3099, .end = 0x309A },
        .{ .start = 0xA66F, .end = 0xA672 },
        .{ .start = 0xA674, .end = 0xA67D },
        .{ .start = 0xA69E, .end = 0xA69F },
        .{ .start = 0xA6F0, .end = 0xA6F1 },
        .{ .start = 0xA802, .end = 0xA802 },
        .{ .start = 0xA806, .end = 0xA806 },
        .{ .start = 0xA80B, .end = 0xA80B },
        .{ .start = 0xA825, .end = 0xA826 },
        .{ .start = 0xA8C4, .end = 0xA8C5 },
        .{ .start = 0xA8E0, .end = 0xA8F1 },
        .{ .start = 0xA926, .end = 0xA92D },
        .{ .start = 0xA947, .end = 0xA951 },
        .{ .start = 0xA980, .end = 0xA982 },
        .{ .start = 0xA9B3, .end = 0xA9B3 },
        .{ .start = 0xA9B6, .end = 0xA9B9 },
        .{ .start = 0xA9BC, .end = 0xA9BC },
        .{ .start = 0xA9E5, .end = 0xA9E5 },
        .{ .start = 0xAA29, .end = 0xAA2E },
        .{ .start = 0xAA31, .end = 0xAA32 },
        .{ .start = 0xAA35, .end = 0xAA36 },
        .{ .start = 0xAA43, .end = 0xAA43 },
        .{ .start = 0xAA4C, .end = 0xAA4C },
        .{ .start = 0xAA7C, .end = 0xAA7C },
        .{ .start = 0xAAB0, .end = 0xAAB0 },
        .{ .start = 0xAAB2, .end = 0xAAB4 },
        .{ .start = 0xAAB7, .end = 0xAAB8 },
        .{ .start = 0xAABE, .end = 0xAABF },
        .{ .start = 0xAAC1, .end = 0xAAC1 },
        .{ .start = 0xAAEC, .end = 0xAAED },
        .{ .start = 0xAAF6, .end = 0xAAF6 },
        .{ .start = 0xABE5, .end = 0xABE5 },
        .{ .start = 0xABE8, .end = 0xABE8 },
        .{ .start = 0xABED, .end = 0xABED },
        .{ .start = 0xFB1E, .end = 0xFB1E },
        .{ .start = 0xFE00, .end = 0xFE0F },
        .{ .start = 0xFE20, .end = 0xFE2F },
        .{ .start = 0x101FD, .end = 0x101FD },
        .{ .start = 0x102E0, .end = 0x102E0 },
        .{ .start = 0x10376, .end = 0x1037A },
        .{ .start = 0x10A01, .end = 0x10A03 },
        .{ .start = 0x10A05, .end = 0x10A06 },
        .{ .start = 0x10A0C, .end = 0x10A0F },
        .{ .start = 0x10A38, .end = 0x10A3A },
        .{ .start = 0x10A3F, .end = 0x10A3F },
        .{ .start = 0x10AE5, .end = 0x10AE6 },
        .{ .start = 0x11001, .end = 0x11001 },
        .{ .start = 0x11038, .end = 0x11046 },
        .{ .start = 0x1107F, .end = 0x11081 },
        .{ .start = 0x110B3, .end = 0x110B6 },
        .{ .start = 0x110B9, .end = 0x110BA },
        .{ .start = 0x11100, .end = 0x11102 },
        .{ .start = 0x11127, .end = 0x1112B },
        .{ .start = 0x1112D, .end = 0x11134 },
        .{ .start = 0x11173, .end = 0x11173 },
        .{ .start = 0x11180, .end = 0x11181 },
        .{ .start = 0x111B6, .end = 0x111BE },
        .{ .start = 0x111C9, .end = 0x111CC },
        .{ .start = 0x1122F, .end = 0x11231 },
        .{ .start = 0x11234, .end = 0x11234 },
        .{ .start = 0x11236, .end = 0x11237 },
        .{ .start = 0x1123E, .end = 0x1123E },
        .{ .start = 0x112DF, .end = 0x112DF },
        .{ .start = 0x112E3, .end = 0x112EA },
        .{ .start = 0x11300, .end = 0x11301 },
        .{ .start = 0x1133B, .end = 0x1133C },
        .{ .start = 0x11340, .end = 0x11340 },
        .{ .start = 0x11366, .end = 0x1136C },
        .{ .start = 0x11370, .end = 0x11374 },
        .{ .start = 0x11438, .end = 0x1143F },
        .{ .start = 0x11442, .end = 0x11444 },
        .{ .start = 0x11446, .end = 0x11446 },
        .{ .start = 0x1145E, .end = 0x1145E },
        .{ .start = 0x114B3, .end = 0x114B8 },
        .{ .start = 0x114BA, .end = 0x114BA },
        .{ .start = 0x114BF, .end = 0x114C0 },
        .{ .start = 0x114C2, .end = 0x114C3 },
        .{ .start = 0x115B2, .end = 0x115B5 },
        .{ .start = 0x115BC, .end = 0x115BD },
        .{ .start = 0x115BF, .end = 0x115C0 },
        .{ .start = 0x115DC, .end = 0x115DD },
        .{ .start = 0x11633, .end = 0x1163A },
        .{ .start = 0x1163D, .end = 0x1163D },
        .{ .start = 0x1163F, .end = 0x11640 },
        .{ .start = 0x116AB, .end = 0x116AB },
        .{ .start = 0x116AD, .end = 0x116AD },
        .{ .start = 0x116B0, .end = 0x116B5 },
        .{ .start = 0x116B7, .end = 0x116B7 },
        .{ .start = 0x1171D, .end = 0x1171F },
        .{ .start = 0x11722, .end = 0x11725 },
        .{ .start = 0x11727, .end = 0x1172B },
        .{ .start = 0x1182F, .end = 0x11837 },
        .{ .start = 0x11839, .end = 0x1183A },
        .{ .start = 0x1193B, .end = 0x1193C },
        .{ .start = 0x1193E, .end = 0x1193E },
        .{ .start = 0x11943, .end = 0x11943 },
        .{ .start = 0x119D4, .end = 0x119D7 },
        .{ .start = 0x119DA, .end = 0x119DB },
        .{ .start = 0x119E0, .end = 0x119E0 },
        .{ .start = 0x11A01, .end = 0x11A0A },
        .{ .start = 0x11A33, .end = 0x11A38 },
        .{ .start = 0x11A3B, .end = 0x11A3E },
        .{ .start = 0x11A47, .end = 0x11A47 },
        .{ .start = 0x11A51, .end = 0x11A56 },
        .{ .start = 0x11A59, .end = 0x11A5B },
        .{ .start = 0x11A8A, .end = 0x11A96 },
        .{ .start = 0x11A98, .end = 0x11A99 },
        .{ .start = 0x11C30, .end = 0x11C36 },
        .{ .start = 0x11C38, .end = 0x11C3D },
        .{ .start = 0x11C3F, .end = 0x11C3F },
        .{ .start = 0x11C92, .end = 0x11CA7 },
        .{ .start = 0x11CAA, .end = 0x11CB0 },
        .{ .start = 0x11CB2, .end = 0x11CB3 },
        .{ .start = 0x11CB5, .end = 0x11CB6 },
        .{ .start = 0x11D31, .end = 0x11D36 },
        .{ .start = 0x11D3A, .end = 0x11D3A },
        .{ .start = 0x11D3C, .end = 0x11D3D },
        .{ .start = 0x11D3F, .end = 0x11D45 },
        .{ .start = 0x11D47, .end = 0x11D47 },
        .{ .start = 0x11D90, .end = 0x11D91 },
        .{ .start = 0x11D95, .end = 0x11D95 },
        .{ .start = 0x11D97, .end = 0x11D97 },
        .{ .start = 0x11EF3, .end = 0x11EF4 },
        .{ .start = 0x16AF0, .end = 0x16AF4 },
        .{ .start = 0x16B30, .end = 0x16B36 },
        .{ .start = 0x16F4F, .end = 0x16F4F },
        .{ .start = 0x16F8F, .end = 0x16F92 },
        .{ .start = 0x16FE4, .end = 0x16FE4 },
        .{ .start = 0x1BC9D, .end = 0x1BC9E },
        .{ .start = 0x1D167, .end = 0x1D169 },
        .{ .start = 0x1D17B, .end = 0x1D182 },
        .{ .start = 0x1D185, .end = 0x1D18B },
        .{ .start = 0x1D1AA, .end = 0x1D1AD },
        .{ .start = 0x1D242, .end = 0x1D244 },
        .{ .start = 0x1DA00, .end = 0x1DA36 },
        .{ .start = 0x1DA3B, .end = 0x1DA6C },
        .{ .start = 0x1DA75, .end = 0x1DA75 },
        .{ .start = 0x1DA84, .end = 0x1DA84 },
        .{ .start = 0x1DA9B, .end = 0x1DA9F },
        .{ .start = 0x1DAA1, .end = 0x1DAAF },
        .{ .start = 0x1E000, .end = 0x1E006 },
        .{ .start = 0x1E008, .end = 0x1E018 },
        .{ .start = 0x1E01B, .end = 0x1E021 },
        .{ .start = 0x1E023, .end = 0x1E024 },
        .{ .start = 0x1E026, .end = 0x1E02A },
        .{ .start = 0x1E130, .end = 0x1E136 },
        .{ .start = 0x1E2AE, .end = 0x1E2AE },
        .{ .start = 0x1E2EC, .end = 0x1E2EF },
        .{ .start = 0x1E8D0, .end = 0x1E8D6 },
        .{ .start = 0x1E944, .end = 0x1E94A },
        .{ .start = 0xE0100, .end = 0xE01EF },
    });
}

fn isWideCodepoint(codepoint: u21) bool {
    return inRanges(codepoint, &.{
        .{ .start = 0x1100, .end = 0x115F },
        .{ .start = 0x231A, .end = 0x231B },
        .{ .start = 0x2329, .end = 0x232A },
        .{ .start = 0x23E9, .end = 0x23EC },
        .{ .start = 0x23F0, .end = 0x23F0 },
        .{ .start = 0x23F3, .end = 0x23F3 },
        .{ .start = 0x25FD, .end = 0x25FE },
        .{ .start = 0x2614, .end = 0x2615 },
        .{ .start = 0x2648, .end = 0x2653 },
        .{ .start = 0x267F, .end = 0x267F },
        .{ .start = 0x2693, .end = 0x2693 },
        .{ .start = 0x26A1, .end = 0x26A1 },
        .{ .start = 0x26AA, .end = 0x26AB },
        .{ .start = 0x26BD, .end = 0x26BE },
        .{ .start = 0x26C4, .end = 0x26C5 },
        .{ .start = 0x26CE, .end = 0x26CE },
        .{ .start = 0x26D4, .end = 0x26D4 },
        .{ .start = 0x26EA, .end = 0x26EA },
        .{ .start = 0x26F2, .end = 0x26F3 },
        .{ .start = 0x26F5, .end = 0x26F5 },
        .{ .start = 0x26FA, .end = 0x26FA },
        .{ .start = 0x26FD, .end = 0x26FD },
        .{ .start = 0x2705, .end = 0x2705 },
        .{ .start = 0x270A, .end = 0x270B },
        .{ .start = 0x2728, .end = 0x2728 },
        .{ .start = 0x274C, .end = 0x274C },
        .{ .start = 0x274E, .end = 0x274E },
        .{ .start = 0x2753, .end = 0x2755 },
        .{ .start = 0x2757, .end = 0x2757 },
        .{ .start = 0x2795, .end = 0x2797 },
        .{ .start = 0x27B0, .end = 0x27B0 },
        .{ .start = 0x27BF, .end = 0x27BF },
        .{ .start = 0x2B1B, .end = 0x2B1C },
        .{ .start = 0x2B50, .end = 0x2B50 },
        .{ .start = 0x2B55, .end = 0x2B55 },
        .{ .start = 0x2E80, .end = 0x303E },
        .{ .start = 0x3040, .end = 0xA4CF },
        .{ .start = 0xAC00, .end = 0xD7A3 },
        .{ .start = 0xF900, .end = 0xFAFF },
        .{ .start = 0xFE10, .end = 0xFE19 },
        .{ .start = 0xFE30, .end = 0xFE6F },
        .{ .start = 0xFF01, .end = 0xFF60 },
        .{ .start = 0xFFE0, .end = 0xFFE6 },
        .{ .start = 0x16FE0, .end = 0x16FE4 },
        .{ .start = 0x17000, .end = 0x187F7 },
        .{ .start = 0x18800, .end = 0x18CD5 },
        .{ .start = 0x1B000, .end = 0x1B122 },
        .{ .start = 0x1B132, .end = 0x1B132 },
        .{ .start = 0x1B150, .end = 0x1B152 },
        .{ .start = 0x1F004, .end = 0x1F004 },
        .{ .start = 0x1F0CF, .end = 0x1F0CF },
        .{ .start = 0x1F18E, .end = 0x1F18E },
        .{ .start = 0x1F191, .end = 0x1F19A },
        .{ .start = 0x1F200, .end = 0x1F202 },
        .{ .start = 0x1F210, .end = 0x1F23B },
        .{ .start = 0x1F240, .end = 0x1F248 },
        .{ .start = 0x1F250, .end = 0x1F251 },
        .{ .start = 0x1F300, .end = 0x1F64F },
        .{ .start = 0x1F680, .end = 0x1F6FF },
        .{ .start = 0x1F700, .end = 0x1F77F },
        .{ .start = 0x1F780, .end = 0x1F7FF },
        .{ .start = 0x1F800, .end = 0x1F8FF },
        .{ .start = 0x1F900, .end = 0x1F9FF },
        .{ .start = 0x1FA00, .end = 0x1FAFF },
        .{ .start = 0x20000, .end = 0x2FFFD },
        .{ .start = 0x30000, .end = 0x3FFFD },
    });
}
