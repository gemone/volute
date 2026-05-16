const std = @import("std");
const simd = @import("../simd.zig");
const dbcs = @import("dbcs.zig");
const sbcs = @import("sbcs.zig");
const utf16 = @import("utf16.zig");
const validation = @import("validation.zig");

/// File encoding enumeration (mirrors Vim's fileencoding list).
pub const Encoding = enum {
    utf8,     // UTF-8 without BOM (default)
    utf8bom,  // UTF-8 with BOM (EF BB BF)
    utf16le,  // UTF-16 Little-Endian (FF FE BOM)
    utf16be,  // UTF-16 Big-Endian (FE FF BOM)
    gbk,      // GBK / CP936 (Simplified Chinese; superset of GB2312)
    gb18030,  // GB18030 (superset of GBK with 4-byte sequences)
    big5,     // Big5 / CP950 (Traditional Chinese)
    shiftjis, // Shift_JIS / CP932 (Japanese)
    eucjp,    // EUC-JP (Japanese)
    euckr,    // EUC-KR / CP949 (Korean)
    latin1,   // ISO-8859-1 / Latin-1 (same byte→codepoint mapping)
    cp1250,   // Windows-1250 (Central European)
    cp1251,   // Windows-1251 (Cyrillic)
    cp1252,   // Windows-1252 (Western European)
    koi8r,    // KOI8-R (Russian)
    cp874,    // Windows-874 (Thai)
    cp1253,   // Windows-1253 (Greek)
    cp1254,   // Windows-1254 (Turkish)
    cp1255,   // Windows-1255 (Hebrew)
    cp1256,   // Windows-1256 (Arabic)
    cp1257,   // Windows-1257 (Baltic)
    cp1258,   // Windows-1258 (Vietnamese)
    koi8u,    // KOI8-U (Ukrainian)
    cp437,    // CP437 (DOS US ASCII Extended)
    cp850,    // CP850 (DOS Multilingual Latin-1)
    iso8859_2,  // ISO-8859-2 (Latin-2, Central European)
    iso8859_3,  // ISO-8859-3 (Latin-3, South European)
    iso8859_4,  // ISO-8859-4 (Latin-4, North European)
    iso8859_5,  // ISO-8859-5 (Latin/Cyrillic)
    iso8859_6,  // ISO-8859-6 (Latin/Arabic)
    iso8859_7,  // ISO-8859-7 (Latin/Greek)
    iso8859_8,  // ISO-8859-8 (Latin/Hebrew)
    iso8859_9,  // ISO-8859-9 (Latin-5, Turkish)
    iso8859_10, // ISO-8859-10 (Latin-6, Nordic)
    iso8859_11, // ISO-8859-11 (Thai / TIS-620)
    iso8859_13, // ISO-8859-13 (Latin-7, Baltic Rim)
    iso8859_14, // ISO-8859-14 (Latin-8, Celtic)
    iso8859_15, // ISO-8859-15 (Latin-9, Western European with €)
    iso8859_16, // ISO-8859-16 (Latin-10, South-Eastern European)
    ascii,    // 7-bit ASCII
    unknown,  // Could not detect

    /// Human-readable name shown in the status bar.
    pub fn displayName(self: Encoding) []const u8 {
        return switch (self) {
            .utf8 => "UTF-8",
            .utf8bom => "UTF-8 BOM",
            .utf16le => "UTF-16 LE",
            .utf16be => "UTF-16 BE",
            .gbk => "GBK",
            .gb18030 => "GB18030",
            .big5 => "Big5",
            .shiftjis => "Shift-JIS",
            .eucjp => "EUC-JP",
            .euckr => "EUC-KR",
            .latin1 => "Latin-1",
            .cp1250 => "CP1250",
            .cp1251 => "CP1251",
            .cp1252 => "CP1252",
            .koi8r => "KOI8-R",
            .cp874    => "CP874",
            .cp1253   => "CP1253",
            .cp1254   => "CP1254",
            .cp1255   => "CP1255",
            .cp1256   => "CP1256",
            .cp1257   => "CP1257",
            .cp1258   => "CP1258",
            .koi8u    => "KOI8-U",
            .cp437    => "CP437",
            .cp850    => "CP850",
            .iso8859_2  => "ISO-8859-2",
            .iso8859_3  => "ISO-8859-3",
            .iso8859_4  => "ISO-8859-4",
            .iso8859_5  => "ISO-8859-5",
            .iso8859_6  => "ISO-8859-6",
            .iso8859_7  => "ISO-8859-7",
            .iso8859_8  => "ISO-8859-8",
            .iso8859_9  => "ISO-8859-9",
            .iso8859_10 => "ISO-8859-10",
            .iso8859_11 => "ISO-8859-11",
            .iso8859_13 => "ISO-8859-13",
            .iso8859_14 => "ISO-8859-14",
            .iso8859_15 => "ISO-8859-15",
            .iso8859_16 => "ISO-8859-16",
            .ascii    => "ASCII",
            .unknown => "unknown",
        };
    }

    /// Parse an encoding name (as used in :set fenc=<name>).
    pub fn fromName(name: []const u8) ?Encoding {
        const table = [_]struct { name: []const u8, enc: Encoding }{
            .{ .name = "utf-8", .enc = .utf8 },
            .{ .name = "utf8", .enc = .utf8 },
            .{ .name = "utf-8-bom", .enc = .utf8bom },
            .{ .name = "ucs-bom", .enc = .utf8bom },
            .{ .name = "utf-16le", .enc = .utf16le },
            .{ .name = "utf-16be", .enc = .utf16be },
            .{ .name = "gbk", .enc = .gbk },
            .{ .name = "gb2312", .enc = .gbk },
            .{ .name = "gb18030", .enc = .gb18030 },
            .{ .name = "cp936", .enc = .gbk },
            .{ .name = "big5", .enc = .big5 },
            .{ .name = "cp950", .enc = .big5 },
            .{ .name = "shift-jis", .enc = .shiftjis },
            .{ .name = "shift_jis", .enc = .shiftjis },
            .{ .name = "sjis", .enc = .shiftjis },
            .{ .name = "cp932", .enc = .shiftjis },
            .{ .name = "euc-jp", .enc = .eucjp },
            .{ .name = "euc-kr", .enc = .euckr },
            .{ .name = "cp949", .enc = .euckr },
            .{ .name = "latin1", .enc = .latin1 },
            .{ .name = "latin-1", .enc = .latin1 },
            .{ .name = "iso-8859-1", .enc = .latin1 },
            .{ .name = "iso8859-1", .enc = .latin1 },
            .{ .name = "cp1250", .enc = .cp1250 },
            .{ .name = "windows-1250", .enc = .cp1250 },
            .{ .name = "cp1251", .enc = .cp1251 },
            .{ .name = "windows-1251", .enc = .cp1251 },
            .{ .name = "cp1252", .enc = .cp1252 },
            .{ .name = "windows-1252", .enc = .cp1252 },
            .{ .name = "koi8-r",      .enc = .koi8r },
            .{ .name = "koi8r",       .enc = .koi8r },
            .{ .name = "cp874",       .enc = .cp874 },
            .{ .name = "windows-874", .enc = .cp874 },
            .{ .name = "tis-620",     .enc = .cp874 },
            .{ .name = "cp1253",      .enc = .cp1253 },
            .{ .name = "windows-1253",.enc = .cp1253 },
            .{ .name = "cp1254",      .enc = .cp1254 },
            .{ .name = "windows-1254",.enc = .cp1254 },
            .{ .name = "cp1255",      .enc = .cp1255 },
            .{ .name = "windows-1255",.enc = .cp1255 },
            .{ .name = "cp1256",      .enc = .cp1256 },
            .{ .name = "windows-1256",.enc = .cp1256 },
            .{ .name = "cp1257",      .enc = .cp1257 },
            .{ .name = "windows-1257",.enc = .cp1257 },
            .{ .name = "cp1258",      .enc = .cp1258 },
            .{ .name = "windows-1258",.enc = .cp1258 },
            .{ .name = "koi8-u",      .enc = .koi8u },
            .{ .name = "koi8u",       .enc = .koi8u },
            .{ .name = "cp437",       .enc = .cp437 },
            .{ .name = "cp850",       .enc = .cp850 },
            .{ .name = "iso-8859-2",  .enc = .iso8859_2 },
            .{ .name = "iso8859-2",   .enc = .iso8859_2 },
            .{ .name = "iso-8859-3",  .enc = .iso8859_3 },
            .{ .name = "iso8859-3",   .enc = .iso8859_3 },
            .{ .name = "iso-8859-4",  .enc = .iso8859_4 },
            .{ .name = "iso8859-4",   .enc = .iso8859_4 },
            .{ .name = "iso-8859-5",  .enc = .iso8859_5 },
            .{ .name = "iso8859-5",   .enc = .iso8859_5 },
            .{ .name = "iso-8859-6",  .enc = .iso8859_6 },
            .{ .name = "iso8859-6",   .enc = .iso8859_6 },
            .{ .name = "iso-8859-7",  .enc = .iso8859_7 },
            .{ .name = "iso8859-7",   .enc = .iso8859_7 },
            .{ .name = "iso-8859-8",  .enc = .iso8859_8 },
            .{ .name = "iso8859-8",   .enc = .iso8859_8 },
            .{ .name = "iso-8859-9",  .enc = .iso8859_9 },
            .{ .name = "iso8859-9",   .enc = .iso8859_9 },
            .{ .name = "iso-8859-10", .enc = .iso8859_10 },
            .{ .name = "iso8859-10",  .enc = .iso8859_10 },
            .{ .name = "iso-8859-11", .enc = .iso8859_11 },
            .{ .name = "iso8859-11",  .enc = .iso8859_11 },
            .{ .name = "tis620",      .enc = .iso8859_11 },
            .{ .name = "iso-8859-13", .enc = .iso8859_13 },
            .{ .name = "iso8859-13",  .enc = .iso8859_13 },
            .{ .name = "iso-8859-14", .enc = .iso8859_14 },
            .{ .name = "iso8859-14",  .enc = .iso8859_14 },
            .{ .name = "iso-8859-15", .enc = .iso8859_15 },
            .{ .name = "iso8859-15",  .enc = .iso8859_15 },
            .{ .name = "latin9",      .enc = .iso8859_15 },
            .{ .name = "iso-8859-16", .enc = .iso8859_16 },
            .{ .name = "iso8859-16",  .enc = .iso8859_16 },
            .{ .name = "ascii",       .enc = .ascii },
            .{ .name = "us-ascii", .enc = .ascii },
        };

        var lower_buf: [32]u8 = undefined;
        if (name.len > lower_buf.len) return null;
        const lower = std.ascii.lowerString(&lower_buf, name);

        for (table) |entry| {
            if (std.mem.eql(u8, lower, entry.name)) return entry.enc;
        }
        return null;
    }
};

// ── BOM constants ─────────────────────────────────────────────────────────────

const BOM_UTF8 = [3]u8{ 0xEF, 0xBB, 0xBF };
const BOM_UTF16_LE = [2]u8{ 0xFF, 0xFE };
const BOM_UTF16_BE = [2]u8{ 0xFE, 0xFF };

// ── Detection ─────────────────────────────────────────────────────────────────

/// Detect the encoding of a byte slice.
///
/// Detection order (mirrors Emacs + Vim conventions):
///   1. BOM check (UTF-8 BOM, UTF-16 LE, UTF-16 BE)     — unambiguous
///   2. Magic coding comment (Emacs/Python/Vim modeline) — explicit user hint
///   3. Sequential probe via `default_fileencodings`     — Vim-style fencs
///
/// To use a custom probe order (e.g. from `:set fencs=`), call
/// `detectWithList()` directly.
pub fn detect(bytes: []const u8) Encoding {
    if (bytes.len == 0) return .utf8;

    // 1. BOM detection — most unambiguous signal
    if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, &BOM_UTF8)) return .utf8bom;
    if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_LE)) return .utf16le;
    if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_BE)) return .utf16be;

    // 2. Magic coding comment (Emacs `-*- coding: X -*-`, Python `# coding: X`,
    //    Vim modeline `vim: set fileencoding=X:`)
    if (detectMagicComment(bytes)) |enc| return enc;

    // 3. Sequential probe with default list (skipping BOM variants already handled)
    return detectFromList(bytes, default_fileencodings[3..]);
}

/// Variant of `detect()` that uses a caller-supplied probe list.
///
/// BOM and magic comment checks still run first; `candidates` is consulted
/// only when those checks yield no result.  This is the path taken when the
/// user has configured `:set fencs=<list>`.
pub fn detectWithList(bytes: []const u8, candidates: []const Encoding) Encoding {
    if (bytes.len == 0) return .utf8;

    if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, &BOM_UTF8)) return .utf8bom;
    if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_LE)) return .utf16le;
    if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_BE)) return .utf16be;

    if (detectMagicComment(bytes)) |enc| return enc;

    return detectFromList(bytes, candidates);
}

/// Scan the first ~512 bytes and last ~256 bytes of a file for an explicit
/// coding hint in a comment or modeline.
///
/// Recognised patterns (case-insensitive keyword, any-case value):
///   Emacs:  `-*- coding: UTF-8 -*-`
///   Python: `# coding: utf-8`  or  `# coding=utf-8`
///   Python: `# -*- coding: utf-8 -*-`
///   Vim:    `vim: set fileencoding=gbk:`   `vim: set fenc=gbk:`
///   XML:    `<?xml ... encoding="utf-8"?>` (keyword "encoding")
///
/// Returns null when no recognised hint is found.
pub fn detectMagicComment(bytes: []const u8) ?Encoding {
    const head_len = @min(512, bytes.len);
    const head = bytes[0..head_len];
    if (scanRegionForCodingHint(head)) |enc| return enc;

    // Also scan last ~256 bytes for Vim modelines typically placed at EOF.
    if (bytes.len > head_len) {
        const tail_start = bytes.len - @min(256, bytes.len - head_len);
        const tail = bytes[tail_start..];
        if (scanRegionForCodingHint(tail)) |enc| return enc;
    }
    return null;
}

/// Scan a byte region for "keyword[whitespace][:=][whitespace]name" patterns.
/// Keywords checked: fileencoding, fenc, coding, encoding, charset.
fn scanRegionForCodingHint(region: []const u8) ?Encoding {
    // Keywords ordered longest-first to avoid prefix collisions.
    const keywords = [_][]const u8{
        "fileencoding", // Vim modeline full form
        "encoding",     // XML/HTML <?xml encoding="..."?>
        "charset",      // HTML <meta charset="...">
        "coding",       // Emacs / Python
        "fenc",         // Vim modeline short form
    };

    var i: usize = 0;
    while (i < region.len) : (i += 1) {
        for (keywords) |kw| {
            if (i + kw.len > region.len) continue;
            if (!std.ascii.eqlIgnoreCase(region[i .. i + kw.len], kw)) continue;

            var j = i + kw.len;
            // Optional whitespace
            while (j < region.len and (region[j] == ' ' or region[j] == '\t')) j += 1;
            if (j >= region.len) continue;
            // Separator must be ':' or '='
            if (region[j] != ':' and region[j] != '=') continue;
            j += 1;
            // Optional whitespace + optional quotes
            while (j < region.len and (region[j] == ' ' or region[j] == '\t')) j += 1;
            if (j < region.len and (region[j] == '"' or region[j] == '\'')) j += 1;

            // Collect the encoding name
            const name_start = j;
            while (j < region.len) {
                const c = region[j];
                // Stop at common delimiters found in modelines / comments / XML
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                    c == '*' or c == ';' or c == ':' or c == '"' or
                    c == '\'' or c == '>' or c == '#') break;
                j += 1;
            }
            if (j == name_start) continue;

            // Lowercase into a stack buffer before lookup
            var lower_buf: [64]u8 = undefined;
            const name = region[name_start..j];
            if (name.len > lower_buf.len) continue;
            for (name, 0..) |c, idx| lower_buf[idx] = std.ascii.toLower(c);

            if (Encoding.fromName(lower_buf[0..name.len])) |enc| return enc;
        }
    }
    return null;
}

const Utf8Class = enum { ascii, utf8, invalid };

/// Single-pass UTF-8 validation and ASCII classification.
/// Scans the input once, identifying whether it is:
///   .ascii   — every byte ≤ 0x7F
///   .utf8    — valid multi-byte UTF-8 with at least one byte > 0x7F
///   .invalid — not valid UTF-8
fn classifyUtf8(bytes: []const u8) Utf8Class {
    // SIMD fast path: bulk check for all-ASCII content (most common case).
    if (simd.allAscii(bytes)) return .ascii;

    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk; after this i points at a non-ASCII byte or end.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b0 = bytes[i];
        const seq_len = std.unicode.utf8ByteSequenceLength(b0) catch return .invalid;
        if (i + seq_len > bytes.len) return .invalid;
        _ = std.unicode.utf8Decode(bytes[i .. i + seq_len]) catch return .invalid;
        i += seq_len;
    }
    // We know there is at least one non-ASCII byte (allAscii returned false above).
    return .utf8;
}

/// Heuristic GBK detection (kept for internal use by probe()).
///
/// A byte sequence "looks like" GBK when the high-byte pairs (lead 0x81–0xFE,
/// trail 0x40–0xFE excluding 0x7F) dominate the non-ASCII content.
fn looksLikeGbk(bytes: []const u8) bool {
    var valid_gbk: usize = 0;
    var invalid: usize = 0;
    var i: usize = 0;

    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        // Potential GBK lead byte
        if (b >= 0x81 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if ((t >= 0x40 and t <= 0x7E) or (t >= 0x80 and t <= 0xFE)) {
                valid_gbk += 1;
                i += 2;
                continue;
            }
        }
        invalid += 1;
        i += 1;
    }

    if (valid_gbk == 0) return false;
    // Require ≥80% of non-ASCII sequences to be valid GBK pairs
    return invalid * 4 <= valid_gbk;
}

// ── Sequential probe system (Vim-style fileencodings) ────────────────────────

/// Confidence level returned by `probe()`.
///
/// Used by `detectFromList()` to pick the first sufficiently confident match.
pub const ProbeResult = enum {
    /// Unambiguous match: BOM present, or all bytes perfectly valid for encoding.
    definite,
    /// High-confidence heuristic: ≥85 % of non-ASCII content forms valid sequences.
    likely,
    /// Syntactically possible but unconfirmable: SBCS encodings that accept any byte.
    possible,
    /// Bytes contain sequences incompatible with this encoding.
    invalid,
};

/// Test whether `bytes` can plausibly be decoded with `enc`.
///
/// For DBCS encodings the result is based on what fraction of multi-byte pairs
/// are syntactically valid for the encoding.  For SBCS encodings (Latin-1,
/// CP12xx, KOI8-R, etc.) every byte is a valid codepoint, so the result is
/// always `.possible`.
pub fn probe(bytes: []const u8, enc: Encoding) ProbeResult {
    if (bytes.len == 0) return .definite;
    return switch (enc) {
        // ── BOM-based (unambiguous) ───────────────────────────────────────────
        .utf8bom => blk: {
            if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, &BOM_UTF8))
                break :blk if (classifyUtf8(bytes[3..]) != .invalid) .definite else .invalid;
            break :blk .invalid;
        },
        .utf16le => if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_LE)) .definite else .invalid,
        .utf16be => if (bytes.len >= 2 and std.mem.startsWith(u8, bytes, &BOM_UTF16_BE)) .definite else .invalid,

        // ── Strict encodings ─────────────────────────────────────────────────
        .ascii => if (classifyUtf8(bytes) == .ascii) .definite else .invalid,
        .utf8 => switch (classifyUtf8(bytes)) {
            .ascii, .utf8 => .definite,
            .invalid => .invalid,
        },

        // ── DBCS heuristics ──────────────────────────────────────────────────
        .gbk, .gb18030 => probeGbk(bytes),
        .big5          => probeBig5(bytes),
        .shiftjis      => probeShiftJis(bytes),
        .eucjp         => probeEucJp(bytes),
        .euckr         => probeEucKr(bytes),

        // ── SBCS: every byte maps to a codepoint — always possible ───────────
        .latin1, .cp1250, .cp1251, .cp1252, .koi8r,
        .cp874, .cp1253, .cp1254, .cp1255, .cp1256, .cp1257, .cp1258,
        .koi8u, .cp437, .cp850,
        .iso8859_2, .iso8859_3, .iso8859_4, .iso8859_5, .iso8859_6,
        .iso8859_7, .iso8859_8, .iso8859_9, .iso8859_10, .iso8859_11,
        .iso8859_13, .iso8859_14, .iso8859_15, .iso8859_16 => .possible,

        .unknown => .invalid,
    };
}

/// Convert a (valid, invalid) pair for DBCS content to a ProbeResult.
fn scoreDbcs(valid: usize, invalid: usize) ProbeResult {
    if (valid == 0 and invalid == 0) return .possible; // no non-ASCII bytes at all
    if (invalid == 0) return .likely;
    const pct = valid * 100 / (valid + invalid);
    if (pct >= 85) return .likely;
    if (pct >= 50) return .possible;
    return .invalid;
}

fn probeGbk(bytes: []const u8) ProbeResult {
    var valid: usize = 0;
    var invalid: usize = 0;
    // GBK-exclusive sequences: lead 0x81–0xA0 (below EUC-JP/KR minimum 0xA1),
    // or trail 0x40–0x9F (below EUC-JP/KR minimum 0xA1, excluding 0x7F).
    // Their presence distinguishes GBK from the overlapping 0xA1–0xFE EUC range.
    var has_exclusive: bool = false;
    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        if (b >= 0x81 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if ((t >= 0x40 and t <= 0x7E) or (t >= 0x80 and t <= 0xFE)) {
                if (b < 0xA1 or (t < 0xA1 and t != 0x7F)) has_exclusive = true;
                valid += 1; i += 2; continue;
            }
        }
        invalid += 1; i += 1;
    }
    const base = scoreDbcs(valid, invalid);
    // Without GBK-exclusive bytes the data is in the overlap zone shared with
    // EUC-JP and EUC-KR.  Cap at .possible so uniquely-identifiable probes win.
    if (!has_exclusive and base == .likely) return .possible;
    return base;
}

fn probeBig5(bytes: []const u8) ProbeResult {
    var valid: usize = 0;
    var invalid: usize = 0;
    // Big5-exclusive vs EUC-JP: trail bytes 0x40–0x7E are valid Big5 but
    // NOT valid EUC-JP G1 (which requires trail 0xA1–0xFE).  Without such
    // bytes the data is in the overlap zone shared with GBK and EUC-JP.
    var has_exclusive: bool = false;
    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        // Big5 lead: 0x81–0xFE; trail: 0x40–0x7E or 0xA1–0xFE
        if (b >= 0x81 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if ((t >= 0x40 and t <= 0x7E) or (t >= 0xA1 and t <= 0xFE)) {
                if (t >= 0x40 and t <= 0x7E) has_exclusive = true;
                valid += 1; i += 2; continue;
            }
        }
        invalid += 1; i += 1;
    }
    const base = scoreDbcs(valid, invalid);
    // Pure 0xA1–0xFE trail pairs are ambiguous with GBK and EUC-JP; cap at .possible.
    if (!has_exclusive and base == .likely) return .possible;
    return base;
}

fn probeShiftJis(bytes: []const u8) ProbeResult {
    var valid: usize = 0;
    var invalid: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        // Half-width katakana: 0xA1–0xDF (single byte in Shift-JIS)
        if (b >= 0xA1 and b <= 0xDF) { i += 1; continue; }
        // Lead byte: 0x81–0x9F or 0xE0–0xFC; trail: 0x40–0x7E or 0x80–0xFC
        if (((b >= 0x81 and b <= 0x9F) or (b >= 0xE0 and b <= 0xFC)) and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if ((t >= 0x40 and t <= 0x7E) or (t >= 0x80 and t <= 0xFC)) {
                valid += 1; i += 2; continue;
            }
        }
        invalid += 1; i += 1;
    }
    return scoreDbcs(valid, invalid);
}

fn probeEucJp(bytes: []const u8) ProbeResult {
    var valid: usize = 0;
    var invalid: usize = 0;
    // SS2 (0x8E) and SS3 (0x8F) are unique to EUC-JP; their presence lets us
    // confidently distinguish EUC-JP from EUC-KR and the GBK 0xA1–0xFE overlap.
    var has_ss: bool = false;
    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        // SS2 (0x8E) + half-width katakana 0xA1–0xDF
        if (b == 0x8E and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if (t >= 0xA1 and t <= 0xDF) { valid += 1; has_ss = true; i += 2; continue; }
        }
        // SS3 (0x8F) + two bytes 0xA1–0xFE (JIS X 0212)
        if (b == 0x8F and i + 2 < bytes.len) {
            const t1 = bytes[i + 1];
            const t2 = bytes[i + 2];
            if (t1 >= 0xA1 and t1 <= 0xFE and t2 >= 0xA1 and t2 <= 0xFE) {
                valid += 1; has_ss = true; i += 3; continue;
            }
        }
        // G1: 0xA1–0xFE + 0xA1–0xFE (JIS X 0208)
        if (b >= 0xA1 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if (t >= 0xA1 and t <= 0xFE) { valid += 1; i += 2; continue; }
        }
        invalid += 1; i += 1;
    }
    const base = scoreDbcs(valid, invalid);
    // Pure G1 (0xA1–0xFE) pairs are identical to EUC-KR and to the upper GBK
    // range.  Without SS2/SS3 we cannot confirm Japanese, so cap at .possible.
    if (!has_ss and base == .likely) return .possible;
    return base;
}

fn probeEucKr(bytes: []const u8) ProbeResult {
    var valid: usize = 0;
    var invalid: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        // Skip ASCII run in bulk.
        i += simd.findFirstNonAscii(bytes[i..]);
        if (i >= bytes.len) break;
        const b = bytes[i];
        // EUC-KR: lead 0xA1–0xFE, trail 0xA1–0xFE
        if (b >= 0xA1 and b <= 0xFE and i + 1 < bytes.len) {
            const t = bytes[i + 1];
            if (t >= 0xA1 and t <= 0xFE) { valid += 1; i += 2; continue; }
        }
        invalid += 1; i += 1;
    }
    // EUC-KR has no unique byte ranges vs EUC-JP G1 (both use 0xA1–0xFE lead+trail).
    // Always cap at .possible so ambiguous content falls through to list ordering.
    const base = scoreDbcs(valid, invalid);
    if (base == .likely) return .possible;
    return base;
}

/// Default ordered encoding probe list.
///
/// Mirrors Vim's `ucs-bom,utf-8,cp936,latin1` default but expanded for all
/// supported East-Asian encodings.  Users can override this per-session with
/// `:set fencs=<list>`.
///
/// Ordering rationale:
///   - BOM variants first (unambiguous, no false positives)
///   - UTF-8 next (strict validator, fails fast on non-UTF-8 bytes)
///   - ShiftJIS: distinct lead-byte ranges 0x81–0x9F and 0xE0–0xFC separate
///     it from EUC-style encodings
///   - GBK before EUC-JP/EUC-KR: GBK has exclusive byte ranges (lead < 0xA1
///     or trail < 0xA1) that uniquely identify it; also the most-used CJK
///     encoding globally (~1.4B users)
///   - Big5 after GBK: narrower trail range (no 0x80–0xA0) helps distinguish
///   - EUC-JP: fires on SS2/SS3 sequences unique to Japanese; for pure G1
///     pairs the probe now returns .possible (ambiguous with EUC-KR/GBK)
///   - EUC-KR: pure 0xA1–0xFE overlap with EUC-JP G1; needs .possible tier
///   - SBCS encodings last (always accept any byte → must be a fallback)
pub const default_fileencodings: []const Encoding = &.{
    .utf8bom,  // UTF-8 with BOM (EF BB BF)
    .utf16le,  // UTF-16 LE with BOM (FF FE)
    .utf16be,  // UTF-16 BE with BOM (FE FF)
    .ascii,    // Pure 7-bit ASCII (strict)
    .utf8,     // UTF-8 without BOM (strict validator)
    .gbk,      // GBK/GB2312: exclusive lead < 0xA1 or trail < 0xA1 → .likely
    .gb18030,  // GB18030: superset of GBK, same heuristics
    .big5,     // Big5: trail 0x40–0x7E (exclusive vs EUC-JP) → .likely; else .possible
    .eucjp,    // EUC-JP: .likely only when SS2/SS3 present; G1-only → .possible
    .shiftjis, // Shift-JIS: exclusive lead ranges 0x81–0x9F / 0xE0–0xFC
    .euckr,    // EUC-KR: .possible for 0xA1–0xFE pairs (overlaps EUC-JP G1)
    .latin1,   // ISO-8859-1: accepts any byte (last-resort fallback)
};

/// Try each encoding in `candidates` in order.
///
/// Returns the first encoding whose `probe()` result is `.definite` or `.likely`.
/// If none qualifies, returns the first `.possible` encoding found, or the last
/// entry in the list when everything returns `.invalid`.
pub fn detectFromList(bytes: []const u8, candidates: []const Encoding) Encoding {
    if (bytes.len == 0) return .utf8;
    if (candidates.len == 0) return .latin1;

    var first_possible: ?Encoding = null;
    for (candidates) |enc| {
        switch (probe(bytes, enc)) {
            .definite, .likely => return enc,
            .possible => if (first_possible == null) { first_possible = enc; },
            .invalid => {},
        }
    }
    return first_possible orelse candidates[candidates.len - 1];
}

// ── Codec: decode to UTF-8 ────────────────────────────────────────────────────

/// Decode bytes in the given encoding to a UTF-8 string.
/// Always returns a newly allocated slice; caller owns it.
pub fn toUtf8(allocator: std.mem.Allocator, bytes: []const u8, enc: Encoding) ![]u8 {
    return switch (enc) {
        .utf8, .ascii, .unknown => allocator.dupe(u8, bytes),
        .utf8bom => blk: {
            // Strip the 3-byte BOM
            const start: usize = if (bytes.len >= 3 and std.mem.startsWith(u8, bytes, &BOM_UTF8)) 3 else 0;
            break :blk allocator.dupe(u8, bytes[start..]);
        },
        .utf16le  => utf16.decode(allocator, bytes, .little),
        .utf16be  => utf16.decode(allocator, bytes, .big),
        .gbk      => dbcs.decodeGbk(allocator, bytes),
        .gb18030  => dbcs.decodeGb18030(allocator, bytes),
        .big5     => dbcs.decodeBig5(allocator, bytes),
        .shiftjis => dbcs.decodeShiftJis(allocator, bytes),
        .euckr    => dbcs.decodeEucKr(allocator, bytes),
        .eucjp    => dbcs.decodeEucJp(allocator, bytes),
        .cp1250   => sbcs.decodeCp1250(allocator, bytes),
        .cp1251   => sbcs.decodeCp1251(allocator, bytes),
        .cp1252   => sbcs.decodeCp1252(allocator, bytes),
        .koi8r    => sbcs.decodeKoi8r(allocator, bytes),
        .cp874    => sbcs.decodeCp874(allocator, bytes),
        .cp1253   => sbcs.decodeCp1253(allocator, bytes),
        .cp1254   => sbcs.decodeCp1254(allocator, bytes),
        .cp1255   => sbcs.decodeCp1255(allocator, bytes),
        .cp1256   => sbcs.decodeCp1256(allocator, bytes),
        .cp1257   => sbcs.decodeCp1257(allocator, bytes),
        .cp1258   => sbcs.decodeCp1258(allocator, bytes),
        .koi8u    => sbcs.decodeKoi8u(allocator, bytes),
        .cp437    => sbcs.decodeCp437(allocator, bytes),
        .cp850    => sbcs.decodeCp850(allocator, bytes),
        .iso8859_2  => sbcs.decodeIso8859_2(allocator, bytes),
        .iso8859_3  => sbcs.decodeIso8859_3(allocator, bytes),
        .iso8859_4  => sbcs.decodeIso8859_4(allocator, bytes),
        .iso8859_5  => sbcs.decodeIso8859_5(allocator, bytes),
        .iso8859_6  => sbcs.decodeIso8859_6(allocator, bytes),
        .iso8859_7  => sbcs.decodeIso8859_7(allocator, bytes),
        .iso8859_8  => sbcs.decodeIso8859_8(allocator, bytes),
        .iso8859_9  => sbcs.decodeIso8859_9(allocator, bytes),
        .iso8859_10 => sbcs.decodeIso8859_10(allocator, bytes),
        .iso8859_11 => sbcs.decodeIso8859_11(allocator, bytes),
        .iso8859_13 => sbcs.decodeIso8859_13(allocator, bytes),
        .iso8859_14 => sbcs.decodeIso8859_14(allocator, bytes),
        .iso8859_15 => sbcs.decodeIso8859_15(allocator, bytes),
        .iso8859_16 => sbcs.decodeIso8859_16(allocator, bytes),
        .latin1   => sbcs.decodeLatin1(allocator, bytes),
    };
}

/// Encode a UTF-8 string to the given encoding.
/// Always returns a newly allocated slice; caller owns it.
pub fn fromUtf8(allocator: std.mem.Allocator, utf8_bytes: []const u8, enc: Encoding) ![]u8 {
    return switch (enc) {
        .utf8, .ascii, .unknown => allocator.dupe(u8, utf8_bytes),
        .utf8bom => blk: {
            var out = try allocator.alloc(u8, 3 + utf8_bytes.len);
            @memcpy(out[0..3], &BOM_UTF8);
            @memcpy(out[3..], utf8_bytes);
            break :blk out;
        },
        .utf16le  => utf16.encode(allocator, utf8_bytes, .little),
        .utf16be  => utf16.encode(allocator, utf8_bytes, .big),
        .gbk      => dbcs.encodeGbk(allocator, utf8_bytes),
        .gb18030  => dbcs.encodeGb18030(allocator, utf8_bytes),
        .big5     => dbcs.encodeBig5(allocator, utf8_bytes),
        .shiftjis => dbcs.encodeShiftJis(allocator, utf8_bytes),
        .euckr    => dbcs.encodeEucKr(allocator, utf8_bytes),
        .eucjp    => dbcs.encodeEucJp(allocator, utf8_bytes),
        .cp1250   => sbcs.encodeCp1250(allocator, utf8_bytes),
        .cp1251   => sbcs.encodeCp1251(allocator, utf8_bytes),
        .cp1252   => sbcs.encodeCp1252(allocator, utf8_bytes),
        .koi8r    => sbcs.encodeKoi8r(allocator, utf8_bytes),
        .cp874    => sbcs.encodeCp874(allocator, utf8_bytes),
        .cp1253   => sbcs.encodeCp1253(allocator, utf8_bytes),
        .cp1254   => sbcs.encodeCp1254(allocator, utf8_bytes),
        .cp1255   => sbcs.encodeCp1255(allocator, utf8_bytes),
        .cp1256   => sbcs.encodeCp1256(allocator, utf8_bytes),
        .cp1257   => sbcs.encodeCp1257(allocator, utf8_bytes),
        .cp1258   => sbcs.encodeCp1258(allocator, utf8_bytes),
        .koi8u    => sbcs.encodeKoi8u(allocator, utf8_bytes),
        .cp437    => sbcs.encodeCp437(allocator, utf8_bytes),
        .cp850    => sbcs.encodeCp850(allocator, utf8_bytes),
        .iso8859_2  => sbcs.encodeIso8859_2(allocator, utf8_bytes),
        .iso8859_3  => sbcs.encodeIso8859_3(allocator, utf8_bytes),
        .iso8859_4  => sbcs.encodeIso8859_4(allocator, utf8_bytes),
        .iso8859_5  => sbcs.encodeIso8859_5(allocator, utf8_bytes),
        .iso8859_6  => sbcs.encodeIso8859_6(allocator, utf8_bytes),
        .iso8859_7  => sbcs.encodeIso8859_7(allocator, utf8_bytes),
        .iso8859_8  => sbcs.encodeIso8859_8(allocator, utf8_bytes),
        .iso8859_9  => sbcs.encodeIso8859_9(allocator, utf8_bytes),
        .iso8859_10 => sbcs.encodeIso8859_10(allocator, utf8_bytes),
        .iso8859_11 => sbcs.encodeIso8859_11(allocator, utf8_bytes),
        .iso8859_13 => sbcs.encodeIso8859_13(allocator, utf8_bytes),
        .iso8859_14 => sbcs.encodeIso8859_14(allocator, utf8_bytes),
        .iso8859_15 => sbcs.encodeIso8859_15(allocator, utf8_bytes),
        .iso8859_16 => sbcs.encodeIso8859_16(allocator, utf8_bytes),
        .latin1   => sbcs.encodeLatin1(allocator, utf8_bytes),
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// Codec modules imported for test stub-skip guards.
const cp1250_codec = @import("cp1250_codec");
const cp1251_codec = @import("cp1251_codec");
const cp1252_codec = @import("cp1252_codec");
const koi8r_codec  = @import("koi8r_codec");
const eucjp_codec  = @import("eucjp_codec");
const big5_codec   = @import("big5_codec");
const gbk_codec    = @import("gbk_codec");

test "detect: pure ASCII is ascii" {
    try std.testing.expectEqual(Encoding.ascii, detect("hello world\n"));
}

test "detectMagicComment: Emacs first-line style" {
    const input = "-*- coding: gbk -*-\nsome content\n";
    try std.testing.expectEqual(Encoding.gbk, detectMagicComment(input).?);
}

test "detectMagicComment: Python hash comment" {
    const input = "# coding: utf-8\nprint('hello')\n";
    try std.testing.expectEqual(Encoding.utf8, detectMagicComment(input).?);
}

test "detectMagicComment: Python coding= assignment" {
    const input = "# coding=shift-jis\n";
    try std.testing.expectEqual(Encoding.shiftjis, detectMagicComment(input).?);
}

test "detectMagicComment: Vim modeline fileencoding" {
    const input = "some text\n# vim: set fileencoding=euc-jp:\n";
    try std.testing.expectEqual(Encoding.eucjp, detectMagicComment(input).?);
}

test "detectMagicComment: Vim modeline short fenc" {
    const input = "# vim: set fenc=cp1251:\n";
    try std.testing.expectEqual(Encoding.cp1251, detectMagicComment(input).?);
}

test "detectMagicComment: XML encoding attribute" {
    const input = "<?xml version=\"1.0\" encoding=\"windows-1252\"?>\n<root/>\n";
    try std.testing.expectEqual(Encoding.cp1252, detectMagicComment(input).?);
}

test "detectMagicComment: uppercase encoding name" {
    const input = "# coding: GBK\n";
    try std.testing.expectEqual(Encoding.gbk, detectMagicComment(input).?);
}

test "detectMagicComment: no hint returns null" {
    try std.testing.expect(detectMagicComment("hello world\n") == null);
}

test "detect: magic comment overrides heuristic" {
    // GBK bytes, but file has an explicit UTF-8 coding comment → honour the comment.
    // In practice this file would be corrupted, but the user's explicit hint wins.
    const input = "# coding: gbk\n\xC4\xE3\xBA\xC3";
    try std.testing.expectEqual(Encoding.gbk, detect(input));
}

test "detect: UTF-8 BOM" {
    try std.testing.expectEqual(Encoding.utf8bom, detect("\xEF\xBB\xBFhello"));
}

test "detect: UTF-16 LE BOM" {
    try std.testing.expectEqual(Encoding.utf16le, detect("\xFF\xFEh\x00i\x00"));
}

test "detect: UTF-16 BE BOM" {
    try std.testing.expectEqual(Encoding.utf16be, detect("\xFE\xFF\x00h\x00i"));
}

test "detect: valid UTF-8 multi-byte" {
    try std.testing.expectEqual(Encoding.utf8, detect("hello \xE4\xB8\x96\xE7\x95\x8C")); // "hello 世界"
}

test "detect: GBK bytes" {
    // 0xA0 is a valid GBK lead (0x81-0xFE) but NOT a valid ShiftJIS lead (0x81-0x9F / 0xE0-0xFC)
    // and NOT a valid EUC-JP G1 lead (0xA1-0xFE), so these bytes are unambiguously GBK
    try std.testing.expectEqual(Encoding.gbk, detect("\xA0\x41\xA0\x42\xA0\x43\xA0\x44"));
}

test "Encoding.fromName" {
    // Core + CJK
    try std.testing.expectEqual(Encoding.utf8,    Encoding.fromName("utf-8").?);
    try std.testing.expectEqual(Encoding.utf8,    Encoding.fromName("UTF8").?);
    try std.testing.expectEqual(Encoding.gbk,     Encoding.fromName("GBK").?);
    try std.testing.expectEqual(Encoding.gbk,     Encoding.fromName("gb2312").?);
    try std.testing.expectEqual(Encoding.gbk,     Encoding.fromName("cp936").?);
    try std.testing.expectEqual(Encoding.latin1,  Encoding.fromName("iso-8859-1").?);
    try std.testing.expectEqual(Encoding.big5,    Encoding.fromName("cp950").?);
    try std.testing.expectEqual(Encoding.shiftjis,Encoding.fromName("shift-jis").?);
    try std.testing.expectEqual(Encoding.shiftjis,Encoding.fromName("cp932").?);
    try std.testing.expectEqual(Encoding.eucjp,   Encoding.fromName("euc-jp").?);
    try std.testing.expectEqual(Encoding.euckr,   Encoding.fromName("euc-kr").?);
    try std.testing.expectEqual(Encoding.euckr,   Encoding.fromName("cp949").?);
    // Windows code pages
    try std.testing.expectEqual(Encoding.cp1250,  Encoding.fromName("windows-1250").?);
    try std.testing.expectEqual(Encoding.cp1251,  Encoding.fromName("cp1251").?);
    try std.testing.expectEqual(Encoding.cp1252,  Encoding.fromName("windows-1252").?);
    try std.testing.expectEqual(Encoding.koi8r,   Encoding.fromName("koi8-r").?);
    try std.testing.expectEqual(Encoding.koi8r,   Encoding.fromName("koi8r").?);
    try std.testing.expectEqual(Encoding.cp874,   Encoding.fromName("tis-620").?);
    try std.testing.expectEqual(Encoding.cp1253,  Encoding.fromName("windows-1253").?);
    try std.testing.expectEqual(Encoding.cp1254,  Encoding.fromName("windows-1254").?);
    try std.testing.expectEqual(Encoding.cp1255,  Encoding.fromName("windows-1255").?);
    try std.testing.expectEqual(Encoding.cp1256,  Encoding.fromName("windows-1256").?);
    try std.testing.expectEqual(Encoding.cp1257,  Encoding.fromName("windows-1257").?);
    try std.testing.expectEqual(Encoding.cp1258,  Encoding.fromName("windows-1258").?);
    try std.testing.expectEqual(Encoding.koi8u,   Encoding.fromName("koi8-u").?);
    // ISO-8859 series
    try std.testing.expectEqual(Encoding.iso8859_2,  Encoding.fromName("iso-8859-2").?);
    try std.testing.expectEqual(Encoding.iso8859_15, Encoding.fromName("latin9").?);
    try std.testing.expectEqual(Encoding.iso8859_16, Encoding.fromName("iso8859-16").?);
    // Misc
    try std.testing.expectEqual(Encoding.ascii, Encoding.fromName("us-ascii").?);
    try std.testing.expect(Encoding.fromName("nonexistent") == null);
}

test "toUtf8: UTF-8 passthrough" {
    const input = "hello \xE4\xB8\x96\xE7\x95\x8C";
    const result = try toUtf8(std.testing.allocator, input, .utf8);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(input, result);
}

test "toUtf8: strip UTF-8 BOM" {
    const result = try toUtf8(std.testing.allocator, "\xEF\xBB\xBFhello", .utf8bom);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("hello", result);
}

test "toUtf8 / fromUtf8: Latin-1 round-trip" {
    // Latin-1 bytes for "café"
    const latin1_bytes = "caf\xE9";
    const utf8_result = try toUtf8(std.testing.allocator, latin1_bytes, .latin1);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("caf\xC3\xA9", utf8_result); // é in UTF-8

    const back = try fromUtf8(std.testing.allocator, utf8_result, .latin1);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(latin1_bytes, back);
}

test "toUtf8 / fromUtf8: GBK round-trip for '你好'" {
    // GBK encoding of 你(C4E3) 好(BAC3)
    const gbk_bytes = "\xC4\xE3\xBA\xC3";
    const utf8_result = try toUtf8(std.testing.allocator, gbk_bytes, .gbk);
    defer std.testing.allocator.free(utf8_result);
    // UTF-8 for 你好
    try std.testing.expectEqualStrings("\xE4\xBD\xA0\xE5\xA5\xBD", utf8_result);

    const back = try fromUtf8(std.testing.allocator, utf8_result, .gbk);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(gbk_bytes, back);
}

test "toUtf8 / fromUtf8: UTF-16 LE round-trip" {
    // UTF-16 LE encoding of "Hi" with BOM
    const utf16le_bytes = "\xFF\xFEH\x00i\x00";
    const utf8_result = try toUtf8(std.testing.allocator, utf16le_bytes, .utf16le);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("Hi", utf8_result);

    const back = try fromUtf8(std.testing.allocator, utf8_result, .utf16le);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(utf16le_bytes, back);
}

test "toUtf8 / fromUtf8: CP1252 round-trip for euro sign" {
    if (cp1252_codec.rev_table.len == 1) return error.SkipZigTest; // stub: codec not in build preset
    // CP1252 byte 0x80 → U+20AC EURO SIGN (€)
    const cp1252_bytes = "\x80";
    const utf8_result = try toUtf8(std.testing.allocator, cp1252_bytes, .cp1252);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xE2\x82\xAC", utf8_result); // UTF-8 for €

    const back = try fromUtf8(std.testing.allocator, utf8_result, .cp1252);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(cp1252_bytes, back);
}

test "toUtf8 / fromUtf8: CP1251 round-trip for Cyrillic 'А'" {
    if (cp1251_codec.rev_table.len == 1) return error.SkipZigTest; // stub: codec not in build preset
    // CP1251 byte 0xC0 → U+0410 Cyrillic Capital Letter A (А)
    const cp1251_bytes = "\xC0";
    const utf8_result = try toUtf8(std.testing.allocator, cp1251_bytes, .cp1251);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xD0\x90", utf8_result); // UTF-8 for А

    const back = try fromUtf8(std.testing.allocator, utf8_result, .cp1251);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(cp1251_bytes, back);
}

test "toUtf8 / fromUtf8: KOI8-R round-trip for Cyrillic 'а'" {
    if (koi8r_codec.rev_table.len == 1) return error.SkipZigTest; // stub: codec not in build preset
    // KOI8-R byte 0xC1 → U+0430 Cyrillic Small Letter A (а)
    const koi8r_bytes = "\xC1";
    const utf8_result = try toUtf8(std.testing.allocator, koi8r_bytes, .koi8r);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xD0\xB0", utf8_result); // UTF-8 for а

    const back = try fromUtf8(std.testing.allocator, utf8_result, .koi8r);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(koi8r_bytes, back);
}

test "toUtf8 / fromUtf8: CP1250 round-trip for 'Ą'" {
    if (cp1250_codec.rev_table.len == 1) return error.SkipZigTest; // stub: codec not in build preset
    // CP1250 byte 0xA5 → U+0104 Latin Capital Letter A with Ogonek (Ą)
    const cp1250_bytes = "\xA5";
    const utf8_result = try toUtf8(std.testing.allocator, cp1250_bytes, .cp1250);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xC4\x84", utf8_result); // UTF-8 for Ą

    const back = try fromUtf8(std.testing.allocator, utf8_result, .cp1250);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(cp1250_bytes, back);
}

test "toUtf8 / fromUtf8: EUC-JP round-trip for hiragana 'あ'" {
    if (eucjp_codec.is_stub) return error.SkipZigTest; // stub: codec not in build preset
    // EUC-JP 0xA4A2 → U+3042 HIRAGANA LETTER A (あ)
    const eucjp_bytes = "\xA4\xA2";
    const utf8_result = try toUtf8(std.testing.allocator, eucjp_bytes, .eucjp);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xE3\x81\x82", utf8_result); // UTF-8 for あ

    const back = try fromUtf8(std.testing.allocator, utf8_result, .eucjp);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(eucjp_bytes, back);
}

test "toUtf8 / fromUtf8: EUC-JP SS2 half-kana round-trip" {
    if (eucjp_codec.is_stub) return error.SkipZigTest; // stub: codec not in build preset
    // EUC-JP SS2: 0x8EA6 → U+FF66 HALFWIDTH KATAKANA LETTER WO (ｦ)
    const eucjp_bytes = "\x8E\xA6";
    const utf8_result = try toUtf8(std.testing.allocator, eucjp_bytes, .eucjp);
    defer std.testing.allocator.free(utf8_result);
    try std.testing.expectEqualStrings("\xEF\xBD\xA6", utf8_result); // UTF-8 for ｦ

    const back = try fromUtf8(std.testing.allocator, utf8_result, .eucjp);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings(eucjp_bytes, back);
}

// ── Probe / detectFromList tests ──────────────────────────────────────────────

test "probe: UTF-8 BOM is definite" {
    try std.testing.expectEqual(ProbeResult.definite, probe("\xEF\xBB\xBFhello", .utf8bom));
}

test "probe: UTF-8 is definite for valid UTF-8" {
    try std.testing.expectEqual(ProbeResult.definite, probe("hello \xE4\xB8\x96", .utf8));
}

test "probe: UTF-8 is invalid for raw GBK bytes" {
    try std.testing.expectEqual(ProbeResult.invalid, probe("\xC4\xE3\xBA\xC3", .utf8));
}

test "probe: GBK is likely when exclusive low-range bytes present" {
    // 0x82 0x40: lead 0x82 < 0xA1 → GBK-exclusive, must be .likely
    try std.testing.expectEqual(ProbeResult.likely, probe("\x82\x40\x83\x41", .gbk));
}

test "probe: GBK is possible for ambiguous upper-range bytes" {
    // "你好" (C4 E3 BA C3): leads 0xBx/0xCx and trails 0xAx–0xFx are shared
    // with EUC-JP G1 range → ambiguous, so only .possible
    try std.testing.expectEqual(ProbeResult.possible, probe("\xC4\xE3\xBA\xC3", .gbk));
}

test "probe: Latin-1 is always possible" {
    try std.testing.expectEqual(ProbeResult.possible, probe("\xC4\xE3\xBA\xC3", .latin1));
    try std.testing.expectEqual(ProbeResult.possible, probe("hello", .latin1));
}

test "probe: ASCII is definite for 7-bit content" {
    try std.testing.expectEqual(ProbeResult.definite, probe("hello world\n", .ascii));
}

test "probe: ASCII is invalid for high bytes" {
    try std.testing.expectEqual(ProbeResult.invalid, probe("\xC4\xE3", .ascii));
}

test "probe: EUC-JP is possible for pure G1 pairs (ambiguous with EUC-KR/GBK)" {
    // "あ" in EUC-JP is A4 A2 — valid in EUC-KR too; no SS2/SS3 → only .possible
    try std.testing.expectEqual(ProbeResult.possible, probe("\xA4\xA2", .eucjp));
}

test "probe: Shift-JIS is likely for valid ShiftJIS pairs" {
    // "あ" in Shift-JIS is 82 A0
    try std.testing.expectEqual(ProbeResult.likely, probe("\x82\xA0", .shiftjis));
}

test "detectFromList: picks utf8 for UTF-8 content" {
    const list: []const Encoding = &.{ .utf8, .gbk, .latin1 };
    try std.testing.expectEqual(Encoding.utf8, detectFromList("hello \xE4\xB8\x96\xE7\x95\x8C", list));
}

test "detectFromList: picks gbk for GBK bytes" {
    const list: []const Encoding = &.{ .utf8, .gbk, .latin1 };
    try std.testing.expectEqual(Encoding.gbk, detectFromList("\xC4\xE3\xBA\xC3", list));
}

test "detectFromList: falls back to latin1 when only sbcs available" {
    const list: []const Encoding = &.{ .utf8, .latin1 };
    // Invalid UTF-8; latin1 is the SBCS fallback
    try std.testing.expectEqual(Encoding.latin1, detectFromList("\xC4\xE3\xBA\xC3", list));
}

test "detect: sequential probe detects GBK" {
    // 0xA0 is a valid GBK lead but invalid for ShiftJIS and EUC-JP, making this unambiguously GBK
    try std.testing.expectEqual(Encoding.gbk, detect("\xA0\x41\xA0\x42\xA0\x43\xA0\x44"));
}

test "detect: sequential probe prefers GBK over EUC-JP for ambiguous CJK bytes" {
    // Pure G1 pairs (0xA1–0xFE lead + 0xA1–0xFE trail) are ambiguous between
    // GBK, EUC-JP, EUC-KR, and Big5 (all accept these byte ranges).
    // With exclusive-range probes, all return .possible for such content.
    // GBK is first in default_fileencodings → wins the .possible tier.
    try std.testing.expectEqual(Encoding.gbk, detect("\xA4\xA2\xA4\xA4\xA4\xA6"));
}

test "probe: EUC-JP is likely when SS2/SS3 are present" {
    // When tested directly, SS2 (0x8E) + katakana bytes are recognized as .likely
    // EUC-JP.  Note: detect() reports GBK for the same bytes because GBK's
    // lead-<0xA1 exclusive rule also fires on 0x8E — that ambiguity requires
    // language statistics or an explicit :e ++enc=eucjp override.
    try std.testing.expectEqual(ProbeResult.likely, probe("\x8E\xB1\x8E\xB2", .eucjp));
}

// ── Correctness validation tests (iconv + Python codecs verified) ─────────────

test "correctness: CP1251 full high-byte round-trip (iconv+python verified)" {
    // All 127 defined CP1251 bytes 0x80-0xFF (byte 0x98 is undefined, excluded).
    // Reference values generated from Python codecs and cross-checked with iconv.
    if (cp1251_codec.rev_table.len == 1) return error.SkipZigTest;
    const cases = [_]struct { byte: u8, utf8: []const u8 }{
        .{ .byte = 0x80, .utf8 = "\xD0\x82" }, .{ .byte = 0x81, .utf8 = "\xD0\x83" },
        .{ .byte = 0x82, .utf8 = "\xE2\x80\x9A" }, .{ .byte = 0x83, .utf8 = "\xD1\x93" },
        .{ .byte = 0x84, .utf8 = "\xE2\x80\x9E" }, .{ .byte = 0x85, .utf8 = "\xE2\x80\xA6" },
        .{ .byte = 0x86, .utf8 = "\xE2\x80\xA0" }, .{ .byte = 0x87, .utf8 = "\xE2\x80\xA1" },
        .{ .byte = 0x88, .utf8 = "\xE2\x82\xAC" }, .{ .byte = 0x89, .utf8 = "\xE2\x80\xB0" },
        .{ .byte = 0x8A, .utf8 = "\xD0\x89" }, .{ .byte = 0x8B, .utf8 = "\xE2\x80\xB9" },
        .{ .byte = 0x8C, .utf8 = "\xD0\x8A" }, .{ .byte = 0x8D, .utf8 = "\xD0\x8C" },
        .{ .byte = 0x8E, .utf8 = "\xD0\x8B" }, .{ .byte = 0x8F, .utf8 = "\xD0\x8F" },
        .{ .byte = 0x90, .utf8 = "\xD1\x92" }, .{ .byte = 0x91, .utf8 = "\xE2\x80\x98" },
        .{ .byte = 0x92, .utf8 = "\xE2\x80\x99" }, .{ .byte = 0x93, .utf8 = "\xE2\x80\x9C" },
        .{ .byte = 0x94, .utf8 = "\xE2\x80\x9D" }, .{ .byte = 0x95, .utf8 = "\xE2\x80\xA2" },
        .{ .byte = 0x96, .utf8 = "\xE2\x80\x93" }, .{ .byte = 0x97, .utf8 = "\xE2\x80\x94" },
        // 0x98 is undefined in CP1251 — skip
        .{ .byte = 0x99, .utf8 = "\xE2\x84\xA2" }, .{ .byte = 0x9A, .utf8 = "\xD1\x99" },
        .{ .byte = 0x9B, .utf8 = "\xE2\x80\xBA" }, .{ .byte = 0x9C, .utf8 = "\xD1\x9A" },
        .{ .byte = 0x9D, .utf8 = "\xD1\x9C" }, .{ .byte = 0x9E, .utf8 = "\xD1\x9B" },
        .{ .byte = 0x9F, .utf8 = "\xD1\x9F" }, .{ .byte = 0xA0, .utf8 = "\xC2\xA0" },
        .{ .byte = 0xA1, .utf8 = "\xD0\x8E" }, .{ .byte = 0xA2, .utf8 = "\xD1\x9E" },
        .{ .byte = 0xA3, .utf8 = "\xD0\x88" }, .{ .byte = 0xA4, .utf8 = "\xC2\xA4" },
        .{ .byte = 0xA5, .utf8 = "\xD2\x90" }, .{ .byte = 0xA6, .utf8 = "\xC2\xA6" },
        .{ .byte = 0xA7, .utf8 = "\xC2\xA7" }, .{ .byte = 0xA8, .utf8 = "\xD0\x81" },
        .{ .byte = 0xA9, .utf8 = "\xC2\xA9" }, .{ .byte = 0xAA, .utf8 = "\xD0\x84" },
        .{ .byte = 0xAB, .utf8 = "\xC2\xAB" }, .{ .byte = 0xAC, .utf8 = "\xC2\xAC" },
        .{ .byte = 0xAD, .utf8 = "\xC2\xAD" }, .{ .byte = 0xAE, .utf8 = "\xC2\xAE" },
        .{ .byte = 0xAF, .utf8 = "\xD0\x87" }, .{ .byte = 0xB0, .utf8 = "\xC2\xB0" },
        .{ .byte = 0xB1, .utf8 = "\xC2\xB1" }, .{ .byte = 0xB2, .utf8 = "\xD0\x86" },
        .{ .byte = 0xB3, .utf8 = "\xD1\x96" }, .{ .byte = 0xB4, .utf8 = "\xD2\x91" },
        .{ .byte = 0xB5, .utf8 = "\xC2\xB5" }, .{ .byte = 0xB6, .utf8 = "\xC2\xB6" },
        .{ .byte = 0xB7, .utf8 = "\xC2\xB7" }, .{ .byte = 0xB8, .utf8 = "\xD1\x91" },
        .{ .byte = 0xB9, .utf8 = "\xE2\x84\x96" }, .{ .byte = 0xBA, .utf8 = "\xD1\x94" },
        .{ .byte = 0xBB, .utf8 = "\xC2\xBB" }, .{ .byte = 0xBC, .utf8 = "\xD1\x98" },
        .{ .byte = 0xBD, .utf8 = "\xD0\x85" }, .{ .byte = 0xBE, .utf8 = "\xD1\x95" },
        .{ .byte = 0xBF, .utf8 = "\xD1\x97" }, .{ .byte = 0xC0, .utf8 = "\xD0\x90" },
        .{ .byte = 0xC1, .utf8 = "\xD0\x91" }, .{ .byte = 0xC2, .utf8 = "\xD0\x92" },
        .{ .byte = 0xC3, .utf8 = "\xD0\x93" }, .{ .byte = 0xC4, .utf8 = "\xD0\x94" },
        .{ .byte = 0xC5, .utf8 = "\xD0\x95" }, .{ .byte = 0xC6, .utf8 = "\xD0\x96" },
        .{ .byte = 0xC7, .utf8 = "\xD0\x97" }, .{ .byte = 0xC8, .utf8 = "\xD0\x98" },
        .{ .byte = 0xC9, .utf8 = "\xD0\x99" }, .{ .byte = 0xCA, .utf8 = "\xD0\x9A" },
        .{ .byte = 0xCB, .utf8 = "\xD0\x9B" }, .{ .byte = 0xCC, .utf8 = "\xD0\x9C" },
        .{ .byte = 0xCD, .utf8 = "\xD0\x9D" }, .{ .byte = 0xCE, .utf8 = "\xD0\x9E" },
        .{ .byte = 0xCF, .utf8 = "\xD0\x9F" }, .{ .byte = 0xD0, .utf8 = "\xD0\xA0" },
        .{ .byte = 0xD1, .utf8 = "\xD0\xA1" }, .{ .byte = 0xD2, .utf8 = "\xD0\xA2" },
        .{ .byte = 0xD3, .utf8 = "\xD0\xA3" }, .{ .byte = 0xD4, .utf8 = "\xD0\xA4" },
        .{ .byte = 0xD5, .utf8 = "\xD0\xA5" }, .{ .byte = 0xD6, .utf8 = "\xD0\xA6" },
        .{ .byte = 0xD7, .utf8 = "\xD0\xA7" }, .{ .byte = 0xD8, .utf8 = "\xD0\xA8" },
        .{ .byte = 0xD9, .utf8 = "\xD0\xA9" }, .{ .byte = 0xDA, .utf8 = "\xD0\xAA" },
        .{ .byte = 0xDB, .utf8 = "\xD0\xAB" }, .{ .byte = 0xDC, .utf8 = "\xD0\xAC" },
        .{ .byte = 0xDD, .utf8 = "\xD0\xAD" }, .{ .byte = 0xDE, .utf8 = "\xD0\xAE" },
        .{ .byte = 0xDF, .utf8 = "\xD0\xAF" }, .{ .byte = 0xE0, .utf8 = "\xD0\xB0" },
        .{ .byte = 0xE1, .utf8 = "\xD0\xB1" }, .{ .byte = 0xE2, .utf8 = "\xD0\xB2" },
        .{ .byte = 0xE3, .utf8 = "\xD0\xB3" }, .{ .byte = 0xE4, .utf8 = "\xD0\xB4" },
        .{ .byte = 0xE5, .utf8 = "\xD0\xB5" }, .{ .byte = 0xE6, .utf8 = "\xD0\xB6" },
        .{ .byte = 0xE7, .utf8 = "\xD0\xB7" }, .{ .byte = 0xE8, .utf8 = "\xD0\xB8" },
        .{ .byte = 0xE9, .utf8 = "\xD0\xB9" }, .{ .byte = 0xEA, .utf8 = "\xD0\xBA" },
        .{ .byte = 0xEB, .utf8 = "\xD0\xBB" }, .{ .byte = 0xEC, .utf8 = "\xD0\xBC" },
        .{ .byte = 0xED, .utf8 = "\xD0\xBD" }, .{ .byte = 0xEE, .utf8 = "\xD0\xBE" },
        .{ .byte = 0xEF, .utf8 = "\xD0\xBF" }, .{ .byte = 0xF0, .utf8 = "\xD1\x80" },
        .{ .byte = 0xF1, .utf8 = "\xD1\x81" }, .{ .byte = 0xF2, .utf8 = "\xD1\x82" },
        .{ .byte = 0xF3, .utf8 = "\xD1\x83" }, .{ .byte = 0xF4, .utf8 = "\xD1\x84" },
        .{ .byte = 0xF5, .utf8 = "\xD1\x85" }, .{ .byte = 0xF6, .utf8 = "\xD1\x86" },
        .{ .byte = 0xF7, .utf8 = "\xD1\x87" }, .{ .byte = 0xF8, .utf8 = "\xD1\x88" },
        .{ .byte = 0xF9, .utf8 = "\xD1\x89" }, .{ .byte = 0xFA, .utf8 = "\xD1\x8A" },
        .{ .byte = 0xFB, .utf8 = "\xD1\x8B" }, .{ .byte = 0xFC, .utf8 = "\xD1\x8C" },
        .{ .byte = 0xFD, .utf8 = "\xD1\x8D" }, .{ .byte = 0xFE, .utf8 = "\xD1\x8E" },
        .{ .byte = 0xFF, .utf8 = "\xD1\x8F" },
    };
    for (cases) |c| {
        const decoded = try toUtf8(std.testing.allocator, &[_]u8{c.byte}, .cp1251);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(c.utf8, decoded);
        const back = try fromUtf8(std.testing.allocator, c.utf8, .cp1251);
        defer std.testing.allocator.free(back);
        try std.testing.expectEqual(c.byte, back[0]);
    }
}

test "correctness: Big5/cp950 seven patch points (iconv+python verified)" {
    // The cp950 patches override 7 code points where Microsoft's CP950 differs
    // from the base Big5 standard. Values verified with iconv -f CP950 and
    // Python's cp950 codec.
    if (big5_codec.is_stub) return error.SkipZigTest;
    const cases = [_]struct { lead: u8, trail: u8, utf8: []const u8 }{
        // 0xA15A → U+2574 BOX DRAWINGS LIGHT LEFT
        .{ .lead = 0xA1, .trail = 0x5A, .utf8 = "\xE2\x95\xB4" },
        // 0xA1C3 → U+FFE3 FULLWIDTH MACRON
        .{ .lead = 0xA1, .trail = 0xC3, .utf8 = "\xEF\xBF\xA3" },
        // 0xA1C5 → U+02CD MODIFIER LETTER LOW MACRON
        .{ .lead = 0xA1, .trail = 0xC5, .utf8 = "\xCB\x8D" },
        // 0xA1FE → U+FF0F FULLWIDTH SOLIDUS
        .{ .lead = 0xA1, .trail = 0xFE, .utf8 = "\xEF\xBC\x8F" },
        // 0xA240 → U+FF3C FULLWIDTH REVERSE SOLIDUS
        .{ .lead = 0xA2, .trail = 0x40, .utf8 = "\xEF\xBC\xBC" },
        // 0xA2CC → U+5341 HANGZHOU NUMERAL TEN (non-invertible: Big5 has canonical encoding)
        .{ .lead = 0xA2, .trail = 0xCC, .utf8 = "\xE5\x8D\x81" },
        // 0xA2CE → U+5345 HANGZHOU NUMERAL THIRTY (non-invertible)
        .{ .lead = 0xA2, .trail = 0xCE, .utf8 = "\xE5\x8D\x85" },
    };
    for (cases) |c| {
        const decoded = try toUtf8(std.testing.allocator, &[_]u8{ c.lead, c.trail }, .big5);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(c.utf8, decoded);
    }
}

test "correctness: GBK comprehensive CJK decode+encode (iconv verified)" {
    // Selected CJK characters verified with `iconv -f GBK -t UTF-8`.
    if (gbk_codec.is_stub) return error.SkipZigTest;
    const cases = [_]struct { gbk: [2]u8, utf8: []const u8 }{
        .{ .gbk = .{ 0xC4, 0xE3 }, .utf8 = "\xE4\xBD\xA0" }, // 你
        .{ .gbk = .{ 0xBA, 0xC3 }, .utf8 = "\xE5\xA5\xBD" }, // 好
        .{ .gbk = .{ 0xCE, 0xD2 }, .utf8 = "\xE6\x88\x91" }, // 我
        .{ .gbk = .{ 0xCA, 0xC7 }, .utf8 = "\xE6\x98\xAF" }, // 是
        .{ .gbk = .{ 0xD6, 0xD0 }, .utf8 = "\xE4\xB8\xAD" }, // 中
        .{ .gbk = .{ 0xB9, 0xFA }, .utf8 = "\xE5\x9B\xBD" }, // 国
        .{ .gbk = .{ 0xC8, 0xCB }, .utf8 = "\xE4\xBA\xBA" }, // 人
        .{ .gbk = .{ 0xD5, 0xE2 }, .utf8 = "\xE8\xBF\x99" }, // 这
    };
    for (cases) |c| {
        const decoded = try toUtf8(std.testing.allocator, &c.gbk, .gbk);
        defer std.testing.allocator.free(decoded);
        try std.testing.expectEqualStrings(c.utf8, decoded);
        const back = try fromUtf8(std.testing.allocator, c.utf8, .gbk);
        defer std.testing.allocator.free(back);
        try std.testing.expectEqualSlices(u8, &c.gbk, back);
    }
}
