const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Key = @import("../vx/key.zig").Key;
const nc = @import("bindings.zig");
const c = nc.c;

// ── Colour names (kept for view.zig compatibility) ───────────────────────────
pub const Color = enum { default, red, green, yellow, blue, magenta, cyan, white, gray };

// ── Notcurses style-bit constants ─────────────────────────────────────────────
pub const STYLE_NONE = @as(c_uint, c.NCSTYLE_NONE);
pub const STYLE_BOLD = @as(c_uint, c.NCSTYLE_BOLD);
pub const STYLE_ITALIC = @as(c_uint, c.NCSTYLE_ITALIC);
pub const STYLE_UNDERLINE = @as(c_uint, c.NCSTYLE_UNDERLINE);

// ── Event types (defined in bindings.zig to avoid circular imports) ────────────────
pub const MouseEvent = nc.MouseEvent;
pub const Event = nc.Event;

// ── Terminal ──────────────────────────────────────────────────────────────────
pub const Terminal = struct {
    const Self = @This();

    nc_ptr: *c.notcurses,
    stdplane: *c.ncplane,
    size: struct { rows: usize, cols: usize },
    io: std.Io,
    saved_termios: ?posix.termios,
    /// Consecutive timeouts from notcurses_get; above threshold we start
    /// polling raw stdin as well (SSH fallback).
    nc_timeout_count: u8,

    pub fn init(io: std.Io) !Self {
        // Save termios BEFORE notcurses touches the terminal so we can
        // restore it on deinit.  notcurses_core_init sets its own raw mode;
        // we must NOT apply our own raw mode on top of it.
        const saved_termios = if (builtin.target.os.tag == .windows)
            null
        else
            posix.tcgetattr(posix.STDIN_FILENO) catch null;

        var opts: c.notcurses_options = std.mem.zeroes(c.notcurses_options);
        opts.flags = c.NCOPTION_SUPPRESS_BANNERS;
        opts.loglevel = c.NCLOGLEVEL_SILENT;
        const nc_ptr = c.notcurses_core_init(&opts, null) orelse
            return error.NotcursesInitFailed;
        errdefer _ = c.notcurses_stop(nc_ptr);

        const stdplane = c.notcurses_stdplane(nc_ptr) orelse {
            return error.NoStdplane;
        };
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.notcurses_term_dim_yx(nc_ptr, &rows, &cols);
        // Enable mouse button events (includes scroll wheel BUTTON4/5).
        _ = c.notcurses_mice_enable(nc_ptr, c.NCMICE_BUTTON_EVENT);
        return .{
            .nc_ptr = nc_ptr,
            .stdplane = stdplane,
            .size = .{ .rows = @intCast(rows), .cols = @intCast(cols) },
            .io = io,
            .saved_termios = saved_termios,
            .nc_timeout_count = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = c.notcurses_stop(self.nc_ptr);
        if (builtin.target.os.tag != .windows) {
            if (self.saved_termios) |termios_state| {
                posix.tcsetattr(posix.STDIN_FILENO, .NOW, termios_state) catch {};
            }
        }
    }

    /// Blocking read.  Uses notcurses as the primary input source (handles
    /// escape sequences, mouse, resize).
    pub fn readEvent(self: *Self) !?Event {
        var ni: c.ncinput = undefined;
        var ts: c.timespec = .{ .tv_sec = 0, .tv_nsec = 5_000_000 }; // 5 ms
        const id = c.notcurses_get(self.nc_ptr, &ts, &ni);
        if (id > 0 and id != std.math.maxInt(c_uint)) {
            self.nc_timeout_count = 0;
            ni.id = id;
            return nc.ncinputToEvent(self.nc_ptr, ni);
        }
        if (id == std.math.maxInt(c_uint)) return error.ReadFailed;

        // notcurses timed out (id == 0).
        if (self.nc_timeout_count < 255) {
            self.nc_timeout_count += 1;
        }
        return null;
    }

    /// Non-blocking read.  Returns null immediately when no input is queued.
    pub fn readEventNonBlocking(self: *Self) !?Event {
        var ni: c.ncinput = undefined;
        const id = c.notcurses_get_nblock(self.nc_ptr, &ni);
        if (id > 0 and id != std.math.maxInt(c_uint)) {
            self.nc_timeout_count = 0;
            ni.id = id;
            return nc.ncinputToEvent(self.nc_ptr, ni);
        }
        if (id == std.math.maxInt(c_uint)) return error.ReadFailed;
        return null;
    }

    /// Convenience wrapper: extract a Key from the next event (legacy call sites).
    pub fn readKey(self: *Self) !?Key {
        const ev = try self.readEvent() orelse return null;
        return if (ev == .key) ev.key else null;
    }

    /// Convenience wrapper: non-blocking key read (legacy call sites).
    pub fn readKeyNonBlocking(self: *Self) !?Key {
        const ev = try self.readEventNonBlocking() orelse return null;
        return if (ev == .key) ev.key else null;
    }

    /// Refresh terminal after resize.  Updates self.size with the new dimensions.
    pub fn refreshAfterResize(self: *Self) void {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        _ = c.notcurses_refresh(self.nc_ptr, &rows, &cols);
        self.size.rows = @intCast(rows);
        self.size.cols = @intCast(cols);
    }

    pub fn updateSize(self: *Self) !void {
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        c.notcurses_term_dim_yx(self.nc_ptr, &rows, &cols);
        self.size.rows = @intCast(rows);
        self.size.cols = @intCast(cols);
    }

    // ── Plane drawing ─────────────────────────────────────────────────────────

    pub fn moveTo(self: *Self, row: usize, col: usize) void {
        _ = c.ncplane_cursor_move_yx(self.stdplane, @intCast(row), @intCast(col));
    }

    /// Write UTF-8 text at the current plane cursor (Zig slice, no null-terminator needed).
    ///
    /// notcurses's utf8_egc_len() reads PAST the n-byte boundary to determine
    /// grapheme cluster extent, so we must pass a null-terminated copy.  Lines
    /// are at most a few thousand bytes wide, so a 4096-byte stack buffer covers
    /// every real case without heap allocation.
    pub fn writeText(self: *Self, text: []const u8) void {
        if (text.len == 0) return;
        var buf: [4096]u8 = undefined;
        const len = text.len;
        if (len < buf.len) {
            @memcpy(buf[0..len], text);
            buf[len] = 0;
            _ = c.ncplane_putnstr(self.stdplane, len, &buf);
        } else {
            // Oversized segment: write in null-terminated chunks of up to 4095 bytes.
            // Walk back from the nominal split point to avoid breaking multi-byte UTF-8
            // sequences: continuation bytes (10xxxxxx) are never valid sequence starts.
            var off: usize = 0;
            while (off < len) {
                var chunk = @min(len - off, buf.len - 1);
                // If there is more text after this chunk, ensure we don't split a
                // multi-byte UTF-8 sequence at the boundary.
                if (off + chunk < len) {
                    // Walk backward past any continuation bytes (0x80..0xBF).
                    while (chunk > 0 and (text[off + chunk] & 0xC0) == 0x80) {
                        chunk -= 1;
                    }
                    // Also skip the leading byte of the multi-byte sequence so the
                    // next chunk starts cleanly on a sequence boundary.
                    if (chunk > 0 and (text[off + chunk] & 0x80) != 0) {
                        chunk -= 1;
                    }
                    // Degenerate guard: if chunk shrank to zero (e.g. 4-byte sequence
                    // straddles the very start of the buffer), force at least 1 byte to
                    // make progress and accept the corruption rather than looping forever.
                    if (chunk == 0) chunk = 1;
                }
                @memcpy(buf[0..chunk], text[off..][0..chunk]);
                buf[chunk] = 0;
                _ = c.ncplane_putnstr(self.stdplane, chunk, &buf);
                off += chunk;
            }
        }
    }

    /// Write `count` ASCII space characters.
    pub fn writeSpaces(self: *Self, count: usize) void {
        // Space is ASCII; the null-terminator after the chunk ensures
        // utf8_egc_len does not read stale bytes at the chunk boundary.
        var tmp: [257]u8 = [_]u8{' '} ** 256 ++ [_]u8{0};
        var left = count;
        while (left > 0) {
            const chunk = @min(left, 256);
            _ = c.ncplane_putnstr(self.stdplane, chunk, &tmp);
            left -= chunk;
        }
    }

    /// Set foreground colour from the named `Color` palette.
    pub fn setFg(self: *Self, color: Color) void {
        if (colorToRgb(color)) |r|
            _ = c.ncplane_set_fg_rgb8(self.stdplane, r[0], r[1], r[2])
        else
            c.ncplane_set_fg_default(self.stdplane);
    }

    pub fn setFgRgb(self: *Self, r: u8, g: u8, b: u8) void {
        _ = c.ncplane_set_fg_rgb8(self.stdplane, r, g, b);
    }

    pub fn setBgRgb(self: *Self, r: u8, g: u8, b: u8) void {
        _ = c.ncplane_set_bg_rgb8(self.stdplane, r, g, b);
    }

    pub fn setFgDefault(self: *Self) void {
        c.ncplane_set_fg_default(self.stdplane);
    }

    pub fn setBgDefault(self: *Self) void {
        c.ncplane_set_bg_default(self.stdplane);
    }

    pub fn setStyles(self: *Self, bits: c_uint) void {
        c.ncplane_set_styles(self.stdplane, bits);
    }

    /// Reset fg → default, bg → default, clear all style bits.
    pub fn resetAttrs(self: *Self) void {
        c.ncplane_set_fg_default(self.stdplane);
        c.ncplane_set_bg_default(self.stdplane);
        c.ncplane_set_styles(self.stdplane, c.NCSTYLE_NONE);
    }

    pub fn hideCursor(self: *Self) void {
        _ = c.notcurses_cursor_disable(self.nc_ptr);
    }

    /// Position and show the hardware cursor at (row, col).
    pub fn showCursor(self: *Self, row: usize, col: usize) void {
        _ = c.notcurses_cursor_enable(self.nc_ptr, @intCast(row), @intCast(col));
    }

    /// Erase all cells in the standard plane (call before a full-frame redraw).
    pub fn erasePlane(self: *Self) void {
        c.ncplane_erase(self.stdplane);
    }

    /// Diff the plane against the previous frame and flush changes to the terminal.
    pub fn flushRender(self: *Self) void {
        _ = c.notcurses_render(self.nc_ptr);
    }

    /// Emit a cursor-shape escape sequence via std.Io.
    /// notcurses does not manage cursor shape, so we bypass it here.
    pub fn setCursorStyle(self: *Self, style: CursorStyle) void {
        const seq: []const u8 = switch (style) {
            .block => "\x1b[2 q",
            .underline => "\x1b[4 q",
            .beam => "\x1b[6 q",
        };
        var buf: [8]u8 = undefined;
        var w = std.Io.File.stdout().writerStreaming(self.io, &buf);
        w.interface.writeAll(seq) catch {};
        w.interface.flush() catch {};
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn colorToRgb(color: Color) ?[3]u8 {
    return switch (color) {
        .default => null,
        .red => .{ 0xcc, 0x44, 0x44 },
        .green => .{ 0x44, 0xaa, 0x44 },
        .yellow => .{ 0xcc, 0xaa, 0x44 },
        .blue => .{ 0x44, 0x88, 0xcc },
        .magenta => .{ 0xbb, 0x55, 0xcc },
        .cyan => .{ 0x44, 0xcc, 0xcc },
        .white => .{ 0xcc, 0xcc, 0xcc },
        .gray => .{ 0x88, 0x88, 0x88 },
    };
}

// ── Cursor style ──────────────────────────────────────────────────────────────

pub const CursorStyle = enum { block, underline, beam };

pub fn parseCursorStyle(name: []const u8) ?CursorStyle {
    if (std.ascii.eqlIgnoreCase(name, "block")) return .block;
    if (std.ascii.eqlIgnoreCase(name, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(name, "beam")) return .beam;
    return null;
}

test "parseCursorStyle accepts supported values only" {
    try std.testing.expectEqual(CursorStyle.block, parseCursorStyle("block").?);
    try std.testing.expectEqual(CursorStyle.underline, parseCursorStyle("underline").?);
    try std.testing.expectEqual(CursorStyle.beam, parseCursorStyle("beam").?);
    try std.testing.expect(parseCursorStyle("slash") == null);
    try std.testing.expect(parseCursorStyle("bar") == null);
    try std.testing.expect(parseCursorStyle("weird") == null);
}
