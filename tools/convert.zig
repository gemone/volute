//! convert: Unified codec conversion tool.
//!
//! Reads codecs.json (embedded in the binary via @embedFile), fetches or loads
//! Unicode.org mapping tables (TXT), and generates Zig source files containing
//! sorted binary tables for use with src/vx/codec/table_codec.zig.
//!
//! Usage:
//!   convert [options] -- <codec_name> <output_file> ...
//!
//! Options:
//!   --codecs <preset>  Which codecs to include: "all" (default), "common",
//!                      or comma-separated names (e.g. "gbk,cp1252")
//!   --no-fetch         Skip HTTP downloads, use local src files only
//!
//! The remaining positional args are <codec_name> <output_path> pairs — one per
//! selected codec.  The tool verifies that each <codec_name> matches the expected
//! selection order from codecs.json.

const std = @import("std");

// ── Data model ──────────────────────────────────────────────────────────────────

pub const Codec = struct {
    name: []const u8,
    url: []const u8,
    src: []const u8,
    max_seq: u8,
    common: bool = false,
    no_fetch: bool = false,
    comment: []const u8 = "",
};

/// Parse codecs.json at build-config time.
/// The returned slice lives in the given allocator's arena (caller should not
/// deinit — the data is needed for the build graph lifetime).
pub fn loadCodecs(allocator: std.mem.Allocator) []const Codec {
    const json_text = @embedFile("codecs.json");
    const parsed = std.json.parseFromSlice(
        []Codec,
        allocator,
        json_text,
        .{ .ignore_unknown_fields = true },
    ) catch |err| std.debug.panic("Failed to parse tools/codecs.json: {}", .{err});
    return parsed.value;
}

/// Return true if a codec should be included given the -Dcodecs option value.
pub fn codecSelected(codec: Codec, opt: []const u8) bool {
    if (std.mem.eql(u8, opt, "all")) return true;
    if (std.mem.eql(u8, opt, "common")) return codec.common;
    var it = std.mem.splitScalar(u8, opt, ',');
    while (it.next()) |token| {
        if (std.mem.eql(u8, std.mem.trim(u8, token, " \t"), codec.name)) return true;
    }
    return false;
}

const Pair = struct { native: u16, unicode: u16 };

// ── Main ────────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var codecs_opt: []const u8 = "all";
    var no_fetch = false;

    var iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer iter.deinit();
    _ = iter.skip(); // argv[0]
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--codecs")) {
            codecs_opt = iter.next() orelse {
                std.debug.print("convert: error: --codecs requires a value\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--no-fetch")) {
            no_fetch = true;
        } else if (std.mem.eql(u8, arg, "--")) {
            break;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            std.debug.print("convert: error: unknown option '{s}'\n", .{arg});
            std.process.exit(1);
        } else {
            std.debug.print("convert: error: unexpected argument '{s}' (use -- before positional args)\n", .{arg});
            std.process.exit(1);
        }
    }

    const OutputPair = struct { name: []const u8, path: []const u8 };
    var out_pairs: std.ArrayList(OutputPair) = .empty;
    defer out_pairs.deinit(allocator);
    while (iter.next()) |name| {
        const path = iter.next() orelse {
            std.debug.print("convert: error: missing output path for codec '{s}'\n", .{name});
            std.process.exit(1);
        };
        try out_pairs.append(allocator, .{ .name = name, .path = path });
    }

    const codecs = loadCodecs(allocator);

    var pair_idx: usize = 0;
    for (codecs) |codec| {
        if (!codecSelected(codec, codecs_opt)) continue;

        if (pair_idx >= out_pairs.items.len) {
            std.debug.print("convert: error: missing output for codec '{s}'\n", .{codec.name});
            std.process.exit(1);
        }
        if (!std.mem.eql(u8, out_pairs.items[pair_idx].name, codec.name)) {
            std.debug.print(
                "convert: error: expected codec '{s}', got '{s}'\n",
                .{ codec.name, out_pairs.items[pair_idx].name },
            );
            std.process.exit(1);
        }
        const out_path = out_pairs.items[pair_idx].path;
        pair_idx += 1;

        const src_data = getTxtData(io, allocator, codec, no_fetch) catch |err| {
            std.debug.print("convert: error: failed to load source for '{s}': {}\n", .{ codec.name, err });
            std.process.exit(1);
        };

        var pairs: std.ArrayList(Pair) = .empty;

        var lines = std.mem.splitScalar(u8, src_data, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trimEnd(u8, raw_line, "\r \t");
            if (line.len == 0 or line[0] == '#') continue;
            if (!std.mem.startsWith(u8, line, "0x") and !std.mem.startsWith(u8, line, "0X")) continue;

            var cols = std.mem.tokenizeAny(u8, line, " \t");
            const native_str = cols.next() orelse continue;
            const unicode_str = cols.next() orelse continue;

            const native = std.fmt.parseInt(u32, native_str[2..], 16) catch continue;
            const unicode = std.fmt.parseInt(u32, unicode_str[2..], 16) catch continue;

            if (native > 0xFFFF or unicode > 0xFFFF) continue;
            if (native < 0x80) continue; // ASCII — passed through

            try pairs.append(allocator, .{ .native = @intCast(native), .unicode = @intCast(unicode) });
        }

        if (pairs.items.len == 0) {
            std.debug.print("convert: error: no mappings found for '{s}'\n", .{codec.name});
            std.process.exit(1);
        }

        var out: std.ArrayList(u8) = .empty;

        if (codec.max_seq == 1) {
            // SBCS: generate complete .zig with SIMD decode/encode
            try emitSbcsZig(allocator, &out, codec.name, pairs.items);
        } else {
            // DBCS: emit flat fwd_table[65536]u16 + rev_table[65536]u16 + decode/encode
            try emitDbcsZig(allocator, &out, codec.name, pairs.items);
        }

        const out_file = std.Io.Dir.cwd().createFile(io, out_path, .{}) catch |err| {
            std.debug.print("convert: error: cannot write '{s}': {}\n", .{ out_path, err });
            std.process.exit(1);
        };
        defer out_file.close(io);
        try out_file.writePositionalAll(io, out.items, 0);

        std.debug.print("convert: {s} -> {s}  ({d} pairs)\n", .{ codec.name, out_path, pairs.items.len });
    }

    if (pair_idx != out_pairs.items.len) {
        std.debug.print("convert: warning: {d} unused output path(s)\n", .{out_pairs.items.len - pair_idx});
    }
}

// ── Helpers ──────────────────────────────────────────────────────────────────────

fn getTxtData(io: std.Io, allocator: std.mem.Allocator, codec: Codec, no_fetch: bool) ![]const u8 {
    if (!no_fetch and !codec.no_fetch) {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        defer client.deinit();

        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = codec.url },
            .response_writer = &aw.writer,
        }) catch |err| {
            // Download failed — fall back to local file
            std.debug.print("convert: warning: fetch failed for '{s}' ({}), using local src\n", .{ codec.name, err });
            return readLocalSrc(io, allocator, codec.src);
        };

        if (result.status != .ok) {
            std.debug.print("convert: warning: HTTP {d} for '{s}', using local src\n", .{ @intFromEnum(result.status), codec.name });
            return readLocalSrc(io, allocator, codec.src);
        }

        return allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    }
    return readLocalSrc(io, allocator, codec.src);
}

fn readLocalSrc(io: std.Io, allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, src, allocator, .limited(8 * 1024 * 1024));
}

fn lessNative(_: void, a: Pair, b: Pair) bool {
    return a.native < b.native;
}

fn lessUnicode(_: void, a: Pair, b: Pair) bool {
    return a.unicode < b.unicode;
}

const TableOrder = enum { native_first, unicode_first };

fn appendPairArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    pairs: []const Pair,
    order: TableOrder,
) !void {
    try out.print(allocator, "\n/// {s}\npub const {s}: []const u8 = &[_]u8{{\n", .{ @tagName(order), name });

    const per_line = 8;
    for (pairs, 0..) |p, i| {
        if (i % per_line == 0) try out.appendSlice(allocator, "   ");
        const key: u16 = switch (order) { .native_first => p.native, .unicode_first => p.unicode };
        const val: u16 = switch (order) { .native_first => p.unicode, .unicode_first => p.native };
        try out.print(allocator, " 0x{x:0>2},0x{x:0>2},0x{x:0>2},0x{x:0>2},", .{
            @as(u8, @intCast(key & 0xFF)),
            @as(u8, @intCast(key >> 8)),
            @as(u8, @intCast(val & 0xFF)),
            @as(u8, @intCast(val >> 8)),
        });
        if (i % per_line == per_line - 1) try out.append(allocator, '\n');
    }
    if (pairs.len % per_line != 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, "};\n");
}

// ── DBCS code generation ──────────────────────────────────────────────────────

fn emitDbcsZig(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    pairs: []const Pair,
) !void {
    var fwd = [_]u16{0xFFFF} ** 65536;
    var rev = [_]u16{0xFFFF} ** 65536;
    for (pairs) |pair| {
        if (pair.unicode != 0xFFFF and pair.unicode < 0x8000) {
            fwd[pair.native] = pair.unicode;
            if (pair.unicode < 0x8000) rev[pair.unicode] = pair.native;
        } else if (pair.unicode != 0xFFFF) {
            fwd[pair.native] = pair.unicode;
            rev[pair.unicode] = pair.native;
        }
    }

    try out.appendSlice(allocator, "// Auto-generated by tools/convert.zig — DO NOT EDIT\n");
    try out.print(allocator, "// Source: {s}  ({d} non-ASCII mappings)\n", .{ name, pairs.len });
    try out.appendSlice(allocator, "// Regenerate: zig build gen-codecs\n\nconst std = @import(\"std\");\n\npub const is_stub = false;\n\n");

    // fwd_table
    try out.appendSlice(allocator,
        \\/// Forward table: fwd_table[native_key] = unicode_cp (0xFFFF = unmapped)
        \\/// native_key = (lead_byte << 8) | trail_byte
        \\pub const fwd_table: [65536]u16 = .{
        \\
    );
    for (0..2048) |row| {
        try out.appendSlice(allocator, "   ");
        for (0..32) |col| {
            const idx = row * 32 + col;
            try out.print(allocator, " 0x{X:0>4},", .{fwd[idx]});
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "};\n\n");

    // rev_table
    try out.appendSlice(allocator,
        \\/// Reverse table: rev_table[unicode_cp] = native_key (0xFFFF = unmapped)
        \\pub const rev_table: [65536]u16 = .{
        \\
    );
    for (0..2048) |row| {
        try out.appendSlice(allocator, "   ");
        for (0..32) |col| {
            const idx = row * 32 + col;
            try out.print(allocator, " 0x{X:0>4},", .{rev[idx]});
        }
        try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "};\n\n");

    // findFirstNonAscii
    try out.appendSlice(allocator,
        \\inline fn findFirstNonAscii(bytes: []const u8) usize {
        \\    var i: usize = 0;
        \\    while (i + 16 <= bytes.len) {
        \\        const chunk: @Vector(16, u8) = bytes[i..][0..16].*;
        \\        if (@reduce(.Or, chunk & @as(@Vector(16, u8), @splat(0x80))) != 0) return i;
        \\        i += 16;
        \\    }
        \\    while (i < bytes.len and bytes[i] < 0x80) i += 1;
        \\    return i;
        \\}
        \\
        \\
    );

    // decode function
    try out.appendSlice(allocator,
        \\pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        \\    const cap = bytes.len + bytes.len / 2 + 4;
        \\    var buf = try allocator.alloc(u8, cap);
        \\    errdefer allocator.free(buf);
        \\    var i: usize = 0;
        \\    var j: usize = 0;
        \\    while (i < bytes.len) {
        \\        if (bytes[i] < 0x80) {
        \\            // Fuse: ASCII byte immediately followed by a DBCS pair → 3-byte UTF-8 (U+0800..U+FFFF)
        \\            // Handles the common corpus pattern 'A' + lead + trail in one loop iteration.
        \\            if (i + 3 <= bytes.len) {
        \\                const b1 = bytes[i + 1];
        \\                if (b1 >= 0x81) {
        \\                    const native_key: u16 = (@as(u16, b1) << 8) | @as(u16, bytes[i + 2]);
        \\                    const cp16 = fwd_table[native_key];
        \\                    if (cp16 >= 0x800 and cp16 != 0xFFFF) {
        \\                        if (j + 4 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 4);
        \\                        buf[j]   = bytes[i];
        \\                        buf[j+1] = @intCast(0xE0 | (cp16 >> 12));
        \\                        buf[j+2] = @intCast(0x80 | ((cp16 >> 6) & 0x3F));
        \\                        buf[j+3] = @intCast(0x80 | (cp16 & 0x3F));
        \\                        j += 4; i += 3; continue;
        \\                    }
        \\                }
        \\            }
        \\            const run = findFirstNonAscii(bytes[i..]);
        \\            const n = if (run > 0) run else 1;
        \\            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
        \\            @memcpy(buf[j..][0..n], bytes[i..][0..n]);
        \\            j += n; i += n; continue;
        \\        }
        \\        if (i + 1 >= bytes.len) {
        \\            if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\            buf[j] = 0xEF; buf[j+1] = 0xBF; buf[j+2] = 0xBD; j += 3; i += 1; continue;
        \\        }
        \\        const native_key: u16 = (@as(u16, bytes[i]) << 8) | @as(u16, bytes[i + 1]);
        \\        const cp16 = fwd_table[native_key];
        \\        if (cp16 == 0xFFFF) {
        \\            if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\            buf[j] = 0xEF; buf[j+1] = 0xBF; buf[j+2] = 0xBD; j += 3;
        \\        } else if (cp16 >= 0x800) {
        \\            if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\            buf[j]   = @intCast(0xE0 | (cp16 >> 12));
        \\            buf[j+1] = @intCast(0x80 | ((cp16 >> 6) & 0x3F));
        \\            buf[j+2] = @intCast(0x80 | (cp16 & 0x3F));
        \\            j += 3;
        \\        } else if (cp16 < 0x80) {
        \\            if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\            buf[j] = @intCast(cp16); j += 1;
        \\        } else {
        \\            if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\            buf[j]   = @intCast(0xC0 | (cp16 >> 6));
        \\            buf[j+1] = @intCast(0x80 | (cp16 & 0x3F));
        \\            j += 2;
        \\        }
        \\        i += 2;
        \\    }
        \\    return allocator.realloc(buf, j);
        \\}
        \\
        \\
    );

    // encode function
    try out.appendSlice(allocator,
        \\pub fn encode(allocator: std.mem.Allocator, utf8: []const u8) ![]u8 {
        \\    var buf = try allocator.alloc(u8, utf8.len);
        \\    errdefer allocator.free(buf);
        \\    var i: usize = 0;
        \\    var j: usize = 0;
        \\    while (i < utf8.len) {
        \\        if (utf8[i] < 0x80) {
        \\            // Fuse: ASCII byte immediately followed by a 3-byte UTF-8 codepoint with rev_table entry.
        \\            // Handles the common corpus pattern ASCII + CJK in one loop iteration.
        \\            if (i + 4 <= utf8.len) {
        \\                const b1 = utf8[i + 1];
        \\                if (b1 >= 0xE0 and b1 <= 0xEF) {
        \\                    const b2 = utf8[i + 2];
        \\                    const b3 = utf8[i + 3];
        \\                    const cp16: u16 = @intCast(
        \\                        (@as(u21, b1 & 0x0F) << 12) |
        \\                        (@as(u21, b2 & 0x3F) << 6) |
        \\                        @as(u21, b3 & 0x3F)
        \\                    );
        \\                    const nat = rev_table[cp16];
        \\                    if (nat != 0xFFFF) {
        \\                        if (j + 3 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 3);
        \\                        buf[j]   = utf8[i];
        \\                        buf[j+1] = @intCast(nat >> 8);
        \\                        buf[j+2] = @intCast(nat & 0xFF);
        \\                        j += 3; i += 4; continue;
        \\                    }
        \\                }
        \\            }
        \\            const run = findFirstNonAscii(utf8[i..]);
        \\            const n = if (run > 0) run else 1;
        \\            if (j + n > buf.len) buf = try allocator.realloc(buf, buf.len + n + buf.len / 4);
        \\            @memcpy(buf[j..][0..n], utf8[i..][0..n]);
        \\            j += n; i += n; continue;
        \\        }
        \\        const b = utf8[i];
        \\        const seq_len: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        \\        if (i + seq_len > utf8.len) { buf[j] = '?'; j += 1; i += 1; continue; }
        \\        const cp21: u21 = switch (seq_len) {
        \\            2 => @as(u21, b & 0x1F) << 6 | @as(u21, utf8[i+1] & 0x3F),
        \\            3 => @as(u21, b & 0x0F) << 12 | @as(u21, utf8[i+1] & 0x3F) << 6 | @as(u21, utf8[i+2] & 0x3F),
        \\            else => 0x110000,
        \\        };
        \\        if (cp21 < 65536) {
        \\            const nat16 = rev_table[@intCast(cp21)];
        \\            if (nat16 != 0xFFFF) {
        \\                if (j + 2 > buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4 + 2);
        \\                buf[j]   = @intCast(nat16 >> 8);
        \\                buf[j+1] = @intCast(nat16 & 0xFF);
        \\                j += 2; i += seq_len; continue;
        \\            }
        \\        }
        \\        if (j >= buf.len) buf = try allocator.realloc(buf, buf.len + buf.len / 4);
        \\        buf[j] = '?'; j += 1; i += seq_len;
        \\    }
        \\    return allocator.realloc(buf, j);
        \\}
        \\
    );
}

// ── SBCS code generation ──────────────────────────────────────────────────────

const SegType = enum { linear_2byte, linear_3byte_same };

const DecodeSeg = struct {
    native_start: u8,
    run_len: u8,
    unicode_base: u16,
    seg_type: SegType,
};

const EncodeAlgBlock = struct {
    lead: u8,
    mid: u8, // 0 for 2-byte sequences
    cont_lo: u8,
    run_len: u8,
    nat_lo: u8,
    is_3byte: bool,
};

/// Pack a Unicode codepoint (≥ 0x80) into the fwd_table format:
///   (utf8_len << 24) | (byte2 << 16) | (byte1 << 8) | byte0
fn packUtf8(cp: u16) u32 {
    if (cp < 0x800) {
        const lead: u32 = 0xC0 | (cp >> 6);
        const cont: u32 = 0x80 | (cp & 0x3F);
        return (2 << 24) | (cont << 8) | lead;
    } else {
        const lead: u32 = 0xE0 | (cp >> 12);
        const mid: u32 = 0x80 | ((cp >> 6) & 0x3F);
        const cont: u32 = 0x80 | (cp & 0x3F);
        return (3 << 24) | (cont << 16) | (mid << 8) | lead;
    }
}

/// Find SIMD-eligible linear decode segments in an SBCS forward map.
fn analyzeDecodeSegs(allocator: std.mem.Allocator, fwd_map: [128]u16) ![]DecodeSeg {
    var segs: std.ArrayList(DecodeSeg) = .empty;
    var i: usize = 0;
    while (i < 128) {
        if (fwd_map[i] == 0xFFFF) { i += 1; continue; }
        const run_start = i;
        var run_len: usize = 1;
        while (run_start + run_len < 128) {
            const next = run_start + run_len;
            if (fwd_map[next] == 0xFFFF) break;
            if (@as(u32, fwd_map[next]) != @as(u32, fwd_map[run_start]) + run_len) break;
            run_len += 1;
        }
        try classifyAndAddSegs(
            allocator, &segs,
            @intCast(0x80 + run_start),
            fwd_map[run_start],
            run_len,
        );
        i = run_start + run_len;
    }
    return segs.toOwnedSlice(allocator);
}

fn classifyAndAddSegs(
    allocator: std.mem.Allocator,
    segs: *std.ArrayList(DecodeSeg),
    native_start: u8,
    unicode_base: u16,
    run_len: usize,
) !void {
    const ub32: u32 = unicode_base;
    const ue32: u32 = ub32 + @as(u32, @intCast(run_len)) - 1;

    if (ub32 >= 0x80 and ue32 <= 0x7FF) {
        // Entirely 2-byte UTF-8 range
        if (run_len >= 16) {
            try segs.append(allocator, .{
                .native_start = native_start,
                .run_len = @intCast(run_len),
                .unicode_base = unicode_base,
                .seg_type = .linear_2byte,
            });
        }
        return;
    }

    if (ub32 >= 0x800) {
        // Entirely 3-byte UTF-8; split at 64-cp (mid-byte) boundaries
        var sub: usize = 0;
        while (sub < run_len) {
            const cp_s: u32 = ub32 + @as(u32, @intCast(sub));
            const page: u32 = cp_s >> 6;
            var sub_len: usize = 1;
            while (sub + sub_len < run_len) {
                if (((ub32 + @as(u32, @intCast(sub + sub_len))) >> 6) != page) break;
                sub_len += 1;
            }
            if (sub_len >= 8) {
                try segs.append(allocator, .{
                    .native_start = @intCast(@as(usize, native_start) + sub),
                    .run_len = @intCast(sub_len),
                    .unicode_base = @intCast(cp_s),
                    .seg_type = .linear_3byte_same,
                });
            }
            sub += sub_len;
        }
        return;
    }

    // Straddles 0x7FF/0x800 boundary
    const split: usize = 0x800 - @as(usize, unicode_base);
    if (split >= 16) {
        try classifyAndAddSegs(allocator, segs, native_start, unicode_base, split);
    }
    if (run_len > split and run_len - split >= 8) {
        try classifyAndAddSegs(
            allocator, segs,
            @intCast(@as(usize, native_start) + split),
            0x800, run_len - split,
        );
    }
}

fn segDescending(_: void, a: DecodeSeg, b: DecodeSeg) bool {
    return a.native_start > b.native_start;
}

/// Find SIMD-eligible encode blocks in an SBCS forward map.
fn analyzeEncodeBlocks(allocator: std.mem.Allocator, fwd_map: [128]u16) ![]EncodeAlgBlock {
    const Mapping = struct { native: u8, lead: u8, mid: u8, cont: u8, is_3byte: bool };
    var mappings: std.ArrayList(Mapping) = .empty;
    for (0..128) |idx| {
        const cp = fwd_map[idx];
        if (cp == 0xFFFF or cp < 0x80) continue;
        const native: u8 = @intCast(0x80 + idx);
        if (cp < 0x800) {
            try mappings.append(allocator, .{
                .native = native,
                .lead = @intCast(0xC0 | (cp >> 6)),
                .mid = 0,
                .cont = @intCast(0x80 | (cp & 0x3F)),
                .is_3byte = false,
            });
        } else {
            try mappings.append(allocator, .{
                .native = native,
                .lead = @intCast(0xE0 | (cp >> 12)),
                .mid = @intCast(0x80 | ((cp >> 6) & 0x3F)),
                .cont = @intCast(0x80 | (cp & 0x3F)),
                .is_3byte = true,
            });
        }
    }
    std.sort.pdq(Mapping, mappings.items, {}, struct {
        fn lt(_: void, a: Mapping, b: Mapping) bool {
            if (a.lead != b.lead) return a.lead < b.lead;
            if (a.mid != b.mid) return a.mid < b.mid;
            return a.cont < b.cont;
        }
    }.lt);
    var blocks: std.ArrayList(EncodeAlgBlock) = .empty;
    var i: usize = 0;
    while (i < mappings.items.len) {
        const m0 = mappings.items[i];
        var j: usize = i + 1;
        while (j < mappings.items.len) {
            const mj = mappings.items[j];
            const mp = mappings.items[j - 1];
            if (mj.lead != m0.lead or mj.mid != m0.mid) break;
            if (mj.cont != mp.cont + 1) break;
            if (mj.native != mp.native + 1) break;
            j += 1;
        }
        const rlen = j - i;
        if (rlen >= 8) {
            try blocks.append(allocator, .{
                .lead = m0.lead,
                .mid = m0.mid,
                .cont_lo = m0.cont,
                .run_len = @intCast(rlen),
                .nat_lo = m0.native,
                .is_3byte = m0.is_3byte,
            });
        }
        i = j;
    }
    return blocks.toOwnedSlice(allocator);
}

/// Emit the complete .zig source file for an SBCS codec.
fn emitSbcsZig(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    codec_name: []const u8,
    pairs: []const Pair,
) !void {
    // Build fwd_map: fwd_map[b - 0x80] = unicode codepoint (0xFFFF = unmapped)
    var fwd_map: [128]u16 = [_]u16{0xFFFF} ** 128;
    for (pairs) |p| {
        if (p.native >= 0x80) fwd_map[p.native - 0x80] = p.unicode;
    }

    // Build packed fwd_table
    var fwd_table: [128]u32 = [_]u32{0} ** 128;
    for (0..128) |idx| {
        const cp = fwd_map[idx];
        if (cp != 0xFFFF) fwd_table[idx] = packUtf8(cp);
    }

    // Build rev_table
    var rev_base: u32 = 0xFFFF;
    var rev_max: u32 = 0;
    for (0..128) |idx| {
        const cp: u32 = fwd_map[idx];
        if (cp != 0xFFFF) {
            if (cp < rev_base) rev_base = cp;
            if (cp > rev_max) rev_max = cp;
        }
    }
    const rev_len: usize = if (rev_base <= rev_max) rev_max - rev_base + 1 else 0;
    const rev_table = try allocator.alloc(u8, rev_len);
    @memset(rev_table, 0xFF);
    for (0..128) |idx| {
        const cp: u32 = fwd_map[idx];
        if (cp != 0xFFFF and cp >= rev_base and cp <= rev_max) {
            rev_table[cp - rev_base] = @intCast(0x80 + idx);
        }
    }

    // Analyze decode segments and encode blocks
    const segs = try analyzeDecodeSegs(allocator, fwd_map);
    std.sort.pdq(DecodeSeg, segs, {}, segDescending);
    const blocks = try analyzeEncodeBlocks(allocator, fwd_map);

    // ── Header ──────────────────────────────────────────────────────────────
    try out.appendSlice(allocator, "// Auto-generated by tools/convert.zig — DO NOT EDIT\n");
    try out.print(allocator, "// Codec: {s}  ({d} non-ASCII mappings)\n", .{ codec_name, pairs.len });
    try out.appendSlice(allocator, "// Regenerate: zig build gen-codecs\n\n");
    try out.appendSlice(allocator, "const std = @import(\"std\");\n\n");

    // ── fwd_table ────────────────────────────────────────────────────────────
    try out.appendSlice(allocator,
        \\// Forward table: fwd_table[b - 0x80] = packed UTF-8 for native byte b.
        \\// Encoding: (utf8_len<<24)|(byte2<<16)|(byte1<<8)|byte0  (0 = unmapped)
        \\pub const fwd_table: [128]u32 = .{
        \\
    );
    for (0..128) |idx| {
        if (idx % 8 == 0) {
            try out.print(allocator, "    // 0x{x:0>2}..0x{x:0>2}\n    ", .{ 0x80 + idx, 0x80 + idx + 7 });
        }
        try out.print(allocator, " 0x{x:0>8},", .{fwd_table[idx]});
        if (idx % 8 == 7) try out.append(allocator, '\n');
    }
    try out.appendSlice(allocator, "};\n\n");

    // ── rev_table ─────────────────────────────────────────────────────────────
    try out.appendSlice(allocator,
        \\// Reverse table: rev_table[cp - rev_base] = native byte (0xFF = unmapped)
        \\
    );
    try out.print(allocator, "pub const rev_base: u16 = {d};\n", .{rev_base});
    try out.print(allocator, "pub const rev_table: [{d}]u8 = .{{\n", .{rev_len});
    for (0..rev_len) |idx| {
        if (idx % 16 == 0) try out.appendSlice(allocator, "   ");
        try out.print(allocator, " 0x{x:0>2},", .{rev_table[idx]});
        if (idx % 16 == 15) try out.append(allocator, '\n');
    }
    if (rev_len > 0 and rev_len % 16 != 0) try out.append(allocator, '\n');
    try out.appendSlice(allocator, "};\n\n");

    // ── findFirstNonAscii (inlined) ───────────────────────────────────────────
    try out.appendSlice(allocator,
        \\inline fn findFirstNonAscii(buf: []const u8) usize {
        \\    var i: usize = 0;
        \\    while (i + 16 <= buf.len) {
        \\        const chunk: @Vector(16, u8) = buf[i..][0..16].*;
        \\        const gt: @Vector(16, bool) = chunk > @as(@Vector(16, u8), @splat(0x7F));
        \\        if (@reduce(.Or, gt)) {
        \\            inline for (0..16) |k| {
        \\                if (gt[k]) return i + k;
        \\            }
        \\        }
        \\        i += 16;
        \\    }
        \\    while (i < buf.len) : (i += 1) {
        \\        if (buf[i] > 0x7F) return i;
        \\    }
        \\    return buf.len;
        \\}
        \\
        \\
    );

    // ── decode function ───────────────────────────────────────────────────────
    try out.appendSlice(allocator,
        \\pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        \\    var out = try allocator.alloc(u8, bytes.len * 3 + 2);
        \\    errdefer allocator.free(out);
        \\    var i: usize = 0;
        \\    var j: usize = 0;
        \\
    );
    if (segs.len > 0) {
        try out.appendSlice(allocator,
            \\    outer: while (i < bytes.len) {
            \\
        );
    } else {
        try out.appendSlice(allocator,
            \\    while (i < bytes.len) {
            \\
        );
    }
    try out.appendSlice(allocator,
        \\        const n_ascii = findFirstNonAscii(bytes[i..]);
        \\        if (n_ascii > 0) {
        \\            @memcpy(out[j..][0..n_ascii], bytes[i..][0..n_ascii]);
        \\            i += n_ascii;
        \\            j += n_ascii;
        \\            continue;
        \\        }
        \\        var b = bytes[i];
        \\
    );
    for (segs) |seg| {
        try emitDecodeSegHandler(allocator, out, seg);
    }
    // Emit fwd_table fallback as an inner batch loop.
    // Processes consecutive non-SIMD non-ASCII bytes without returning to outer loop,
    // avoiding repeated findFirstNonAscii + segment-check overhead.
    try out.appendSlice(allocator,
        \\        // fwd_table fallback — inner batch loop for consecutive non-SIMD bytes
        \\        while (true) {
        \\            const raw_entry = fwd_table[b - 0x80];
        \\            const entry: u32 = if (raw_entry != 0) raw_entry else 0x03BDBFEF;
        \\            const utf_len: usize = entry >> 24;
        \\            out[j]     = @truncate(entry);
        \\            out[j + 1] = @truncate(entry >> 8);
        \\            out[j + 2] = @truncate(entry >> 16);
        \\            j += utf_len;
        \\            i += 1;
        \\            if (i >= bytes.len) break;
        \\            b = bytes[i];
        \\            if (b < 0x80) break;
        \\
    );
    // Break out of the inner loop only when b falls inside an actual SIMD segment
    // range (so the outer loop can try an 8-wide SIMD batch).  Bytes between or
    // above segments stay in the inner fwd_table loop, avoiding per-byte
    // findFirstNonAscii + seg-check overhead for non-linear encodings like KOI8-R.
    if (segs.len > 0) {
        // Build condition: (b >= start0 and b <= end0) or (b >= start1 and b <= end1) ...
        try out.appendSlice(allocator, "            if (");
        for (segs, 0..) |seg, si| {
            if (si > 0) try out.appendSlice(allocator, " or\n                ");
            try out.print(allocator, "(b >= 0x{X:0>2} and b <= 0x{X:0>2})", .{
                seg.native_start,
                seg.native_start + seg.run_len - 1,
            });
        }
        try out.appendSlice(allocator, ") break; // re-enter outer for SIMD\n");
    }
    try out.appendSlice(allocator,
        \\        }
        \\    }
        \\    if (j == out.len) return out;
        \\    return allocator.realloc(out, j);
        \\}
        \\
        \\
    );

    // ── encode function ───────────────────────────────────────────────────────
    try out.appendSlice(allocator,
        \\pub fn encode(allocator: std.mem.Allocator, utf8: []const u8) ![]u8 {
        \\    var buf = try allocator.alloc(u8, utf8.len);
        \\    errdefer allocator.free(buf);
        \\    var i: usize = 0;
        \\    var j: usize = 0;
        \\
    );
    if (blocks.len > 0) {
        try out.appendSlice(allocator,
            \\    outer: while (i < utf8.len) {
            \\
        );
    } else {
        try out.appendSlice(allocator,
            \\    while (i < utf8.len) {
            \\
        );
    }
    try out.appendSlice(allocator,
        \\        const n_ascii = findFirstNonAscii(utf8[i..]);
        \\        if (n_ascii > 0) {
        \\            @memcpy(buf[j..][0..n_ascii], utf8[i..][0..n_ascii]);
        \\            i += n_ascii;
        \\            j += n_ascii;
        \\            continue;
        \\        }
        \\        const b = utf8[i];
        \\
    );
    for (blocks) |block| {
        try emitEncodeBlockHandler(allocator, out, block);
    }
    // Encode fallback: UTF-8 decode + rev_table lookup
    try out.appendSlice(allocator,
        \\        // fallback: UTF-8 decode + rev_table lookup
        \\        var seq_len: usize = 1;
        \\        var cp: u32 = b;
        \\        if (b >= 0xF0 and i + 4 <= utf8.len) {
        \\            cp = (@as(u32, b & 0x07) << 18) | (@as(u32, utf8[i+1] & 0x3F) << 12) | (@as(u32, utf8[i+2] & 0x3F) << 6) | (@as(u32, utf8[i+3] & 0x3F));
        \\            seq_len = 4;
        \\        } else if (b >= 0xE0 and i + 3 <= utf8.len) {
        \\            cp = (@as(u32, b & 0x0F) << 12) | (@as(u32, utf8[i+1] & 0x3F) << 6) | (@as(u32, utf8[i+2] & 0x3F));
        \\            seq_len = 3;
        \\        } else if (b >= 0xC0 and i + 2 <= utf8.len) {
        \\            cp = (@as(u32, b & 0x1F) << 6) | (@as(u32, utf8[i+1] & 0x3F));
        \\            seq_len = 2;
        \\        }
        \\
    );
    try out.print(allocator,
        "        buf[j] = if (cp >= {d} and cp < {d})\n" ++
        "            rev_table[cp - {d}]\n" ++
        "        else '?';\n",
        .{ rev_base, rev_base + rev_len, rev_base },
    );
    try out.appendSlice(allocator,
        \\        j += 1;
        \\        i += seq_len;
        \\    }
        \\    return allocator.realloc(buf, j);
        \\}
        \\
    );
}

fn emitDecodeSegHandler(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    seg: DecodeSeg,
) !void {
    const end_byte: u8 = seg.native_start +% seg.run_len -% 1;
    const no_upper = end_byte == 0xFF;

    if (no_upper) {
        try out.print(allocator, "        if (b >= 0x{x:0>2}) {{\n", .{seg.native_start});
    } else {
        try out.print(allocator, "        if (b >= 0x{x:0>2} and b <= 0x{x:0>2}) {{\n", .{ seg.native_start, end_byte });
    }

    switch (seg.seg_type) {
        .linear_2byte => {
            const delta: u8 = @intCast(seg.unicode_base & 0x3F);
            const threshold: u8 = @intCast(64 - @as(u32, delta));
            const lead0: u8 = @intCast(0xC0 | (seg.unicode_base >> 6));
            const last_cp: u32 = @as(u32, seg.unicode_base) + seg.run_len - 1;
            const lead1: u8 = @intCast(0xC0 | (last_cp >> 6));
            const crosses = lead0 != lead1;

            // SIMD 16-wide path
            try out.print(allocator,
                "            if (i + 16 <= bytes.len) {{\n" ++
                "                const chunk: @Vector(16, u8) = bytes[i..][0..16].*;\n" ++
                "                const k: @Vector(16, u8) = chunk -% @as(@Vector(16, u8), @splat(0x{x:0>2}));\n" ++
                "                if (@reduce(.And, k < @as(@Vector(16, u8), @splat(@as(u8, {d}))))) {{\n",
                .{ seg.native_start, seg.run_len },
            );
            if (crosses) {
                try out.print(allocator,
                    "                    const cont = (k +% @as(@Vector(16, u8), @splat(@as(u8, {d})))) & @as(@Vector(16, u8), @splat(@as(u8, 0x3F))) | @as(@Vector(16, u8), @splat(@as(u8, 0x80)));\n" ++
                    "                    const leads = @select(u8, k >= @as(@Vector(16, u8), @splat(@as(u8, {d}))), @as(@Vector(16, u8), @splat(@as(u8, 0x{x:0>2}))), @as(@Vector(16, u8), @splat(@as(u8, 0x{x:0>2}))));\n",
                    .{ delta, threshold, lead1, lead0 },
                );
            } else {
                try out.print(allocator,
                    "                    const cont = (k +% @as(@Vector(16, u8), @splat(@as(u8, {d})))) & @as(@Vector(16, u8), @splat(@as(u8, 0x3F))) | @as(@Vector(16, u8), @splat(@as(u8, 0x80)));\n" ++
                    "                    const leads: @Vector(16, u8) = @splat(0x{x:0>2});\n",
                    .{ delta, lead0 },
                );
            }
            try out.appendSlice(allocator,
                \\                    var buf2: [32]u8 = undefined;
                \\                    inline for (0..16) |n| { buf2[n * 2] = leads[n]; buf2[n * 2 + 1] = cont[n]; }
                \\                    @memcpy(out[j..][0..32], &buf2);
                \\                    i += 16; j += 32;
                \\                    continue :outer;
                \\                }
                \\            }
                \\            // scalar 2-byte
                \\
            );
            if (crosses) {
                try out.print(allocator,
                    "            const k2: u8 = b -% 0x{x:0>2};\n" ++
                    "            const lead: u8 = if (k2 >= {d}) 0x{x:0>2} else 0x{x:0>2};\n" ++
                    "            const cont2: u8 = ((k2 +% @as(u8, {d})) & 0x3F) | 0x80;\n" ++
                    "            out[j] = lead; out[j + 1] = cont2;\n",
                    .{ seg.native_start, threshold, lead1, lead0, delta },
                );
            } else {
                try out.print(allocator,
                    "            const k2: u8 = b -% 0x{x:0>2};\n" ++
                    "            out[j] = 0x{x:0>2}; out[j + 1] = ((k2 +% @as(u8, {d})) & 0x3F) | 0x80;\n",
                    .{ seg.native_start, lead0, delta },
                );
            }
            try out.appendSlice(allocator,
                \\            i += 1; j += 2;
                \\            continue :outer;
                \\        }
                \\
            );
        },

        .linear_3byte_same => {
            const utf8_lead: u8 = @intCast(0xE0 | (seg.unicode_base >> 12));
            const utf8_mid: u8 = @intCast(0x80 | ((seg.unicode_base >> 6) & 0x3F));
            const utf8_base_cont: u8 = @intCast(0x80 | (seg.unicode_base & 0x3F));

            // SIMD 8-wide path
            try out.print(allocator,
                "            if (i + 8 <= bytes.len) {{\n" ++
                "                const chunk8: @Vector(8, u8) = bytes[i..][0..8].*;\n" ++
                "                const k8: @Vector(8, u8) = chunk8 -% @as(@Vector(8, u8), @splat(0x{x:0>2}));\n" ++
                "                if (@reduce(.And, k8 < @as(@Vector(8, u8), @splat(@as(u8, {d}))))) {{\n" ++
                "                    const cont8 = k8 +% @as(@Vector(8, u8), @splat(@as(u8, 0x{x:0>2})));\n" ++
                "                    var buf3: [24]u8 = undefined;\n" ++
                "                    inline for (0..8) |n| {{ buf3[n*3] = 0x{x:0>2}; buf3[n*3+1] = 0x{x:0>2}; buf3[n*3+2] = cont8[n]; }}\n" ++
                "                    @memcpy(out[j..][0..24], &buf3);\n" ++
                "                    i += 8; j += 24;\n" ++
                "                    continue :outer;\n" ++
                "                }}\n" ++
                "            }}\n" ++
                "            // scalar 3-byte\n" ++
                "            out[j] = 0x{x:0>2}; out[j+1] = 0x{x:0>2}; out[j+2] = (b -% 0x{x:0>2}) +% 0x{x:0>2};\n" ++
                "            i += 1; j += 3;\n" ++
                "            continue :outer;\n" ++
                "        }}\n\n",
                .{ seg.native_start, seg.run_len, utf8_base_cont, utf8_lead, utf8_mid, utf8_lead, utf8_mid, seg.native_start, utf8_base_cont },
            );
        },
    }
}

fn emitEncodeBlockHandler(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: EncodeAlgBlock,
) !void {
    const cont_hi: u8 = block.cont_lo +% block.run_len -% 1;

    if (!block.is_3byte) {
        // 2-byte block: SIMD 8×2 bytes (16 bytes input → 8 bytes output)
        try out.print(allocator,
            "        if (b == 0x{x:0>2}) {{\n" ++
            "            if (i + 16 <= utf8.len) {{\n" ++
            "                const chunk16: @Vector(16, u8) = utf8[i..][0..16].*;\n" ++
            "                const evens = @shuffle(u8, chunk16, undefined, @Vector(8, i32){{ 0, 2, 4, 6, 8, 10, 12, 14 }});\n" ++
            "                const odds  = @shuffle(u8, chunk16, undefined, @Vector(8, i32){{ 1, 3, 5, 7, 9, 11, 13, 15 }});\n" ++
            "                if (@reduce(.And, evens == @as(@Vector(8, u8), @splat(0x{x:0>2}))) and\n" ++
            "                    @reduce(.And, odds >= @as(@Vector(8, u8), @splat(0x{x:0>2}))) and\n" ++
            "                    @reduce(.And, odds <= @as(@Vector(8, u8), @splat(0x{x:0>2}))))\n" ++
            "                {{\n" ++
            "                    const natives = odds -% @as(@Vector(8, u8), @splat(0x{x:0>2})) +% @as(@Vector(8, u8), @splat(0x{x:0>2}));\n" ++
            "                    const nat_arr: [8]u8 = @as([8]u8, natives);\n" ++
            "                    @memcpy(buf[j..][0..8], &nat_arr);\n" ++
            "                    i += 16; j += 8;\n" ++
            "                    continue :outer;\n" ++
            "                }}\n" ++
            "            }}\n" ++
            "            if (i + 2 <= utf8.len) {{\n" ++
            "                const c = utf8[i + 1];\n" ++
            "                if (c >= 0x{x:0>2} and c <= 0x{x:0>2}) {{\n" ++
            "                    buf[j] = c -% 0x{x:0>2} +% 0x{x:0>2};\n" ++
            "                    i += 2; j += 1;\n" ++
            "                    continue :outer;\n" ++
            "                }}\n" ++
            "            }}\n" ++
            "        }}\n",
            .{ block.lead, block.lead, block.cont_lo, cont_hi, block.cont_lo, block.nat_lo, block.cont_lo, cont_hi, block.cont_lo, block.nat_lo },
        );
    } else {
        // 3-byte block: SIMD 8×3 bytes (24 bytes input → 8 bytes output)
        try out.print(allocator,
            "        if (b == 0x{x:0>2}) {{\n" ++
            "            if (i + 24 <= utf8.len) {{\n" ++
            "                var leads_a: [8]u8 = undefined;\n" ++
            "                var mids_a:  [8]u8 = undefined;\n" ++
            "                var conts_a: [8]u8 = undefined;\n" ++
            "                inline for (0..8) |k| {{\n" ++
            "                    leads_a[k] = utf8[i + k * 3];\n" ++
            "                    mids_a[k]  = utf8[i + k * 3 + 1];\n" ++
            "                    conts_a[k] = utf8[i + k * 3 + 2];\n" ++
            "                }}\n" ++
            "                const leads8: @Vector(8, u8) = leads_a;\n" ++
            "                const mids8:  @Vector(8, u8) = mids_a;\n" ++
            "                const conts8: @Vector(8, u8) = conts_a;\n" ++
            "                if (@reduce(.And, leads8 == @as(@Vector(8, u8), @splat(0x{x:0>2}))) and\n" ++
            "                    @reduce(.And, mids8 == @as(@Vector(8, u8), @splat(0x{x:0>2}))) and\n" ++
            "                    @reduce(.And, conts8 >= @as(@Vector(8, u8), @splat(0x{x:0>2}))) and\n" ++
            "                    @reduce(.And, conts8 <= @as(@Vector(8, u8), @splat(0x{x:0>2}))))\n" ++
            "                {{\n" ++
            "                    const natives8 = conts8 -% @as(@Vector(8, u8), @splat(0x{x:0>2})) +% @as(@Vector(8, u8), @splat(0x{x:0>2}));\n" ++
            "                    const nat_arr8: [8]u8 = @as([8]u8, natives8);\n" ++
            "                    @memcpy(buf[j..][0..8], &nat_arr8);\n" ++
            "                    i += 24; j += 8;\n" ++
            "                    continue :outer;\n" ++
            "                }}\n" ++
            "            }}\n" ++
            "            if (i + 3 <= utf8.len) {{\n" ++
            "                const m = utf8[i + 1];\n" ++
            "                const c = utf8[i + 2];\n" ++
            "                if (m == 0x{x:0>2} and c >= 0x{x:0>2} and c <= 0x{x:0>2}) {{\n" ++
            "                    buf[j] = c -% 0x{x:0>2} +% 0x{x:0>2};\n" ++
            "                    i += 3; j += 1;\n" ++
            "                    continue :outer;\n" ++
            "                }}\n" ++
            "            }}\n" ++
            "        }}\n",
            .{ block.lead, block.lead, block.mid, block.cont_lo, cont_hi, block.cont_lo, block.nat_lo, block.mid, block.cont_lo, cont_hi, block.cont_lo, block.nat_lo },
        );
    }
}
