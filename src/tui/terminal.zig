const std = @import("std");
const posix = std.posix;
const c = std.c;
const Key = @import("../vx/key.zig").Key;
const BaseKey = @import("../vx/key.zig").BaseKey;
const capabilities = @import("capabilities.zig");

pub const Color = enum { default, red, green, yellow, blue, magenta, cyan, white, gray };

pub const STYLE_NONE: u32 = 0;
pub const STYLE_BOLD: u32 = 1 << 0;
pub const STYLE_ITALIC: u32 = 1 << 1;
pub const STYLE_UNDERLINE: u32 = 1 << 2;

const MouseKind = enum { button1, button2, button3, scroll_up, scroll_down, motion };

pub const MouseEvent = struct {
    kind: MouseKind,
    row: i32,
    col: i32,
};

const Resize = struct { rows: usize, cols: usize };

pub const Event = union(enum) {
    key: Key,
    resize: Resize,
    mouse: MouseEvent,
};

pub fn hasInteractiveTty() bool {
    return c.isatty(posix.STDIN_FILENO) == 1 and c.isatty(posix.STDOUT_FILENO) == 1;
}

const Size = struct { rows: usize, cols: usize };

pub const Terminal = struct {
    const Self = @This();

    // Kept for compatibility with existing tests/bench initializers.
    nc_ptr: ?*anyopaque,
    stdplane: ?*anyopaque,
    size: Size,
    io: std.Io,
    saved_termios: ?posix.termios,
    nc_timeout_count: u8,

    headless: bool = true,
    stdin_is_tty: bool = false,
    stdout_is_tty: bool = false,
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    caps: capabilities.Capabilities = .{},
    out_buf: [16384]u8 = undefined,
    out_len: usize = 0,

    pub fn init(io: std.Io) !Self {
        const stdin_is_tty = c.isatty(posix.STDIN_FILENO) == 1;
        const stdout_is_tty = c.isatty(posix.STDOUT_FILENO) == 1;
        const saved_termios = if (stdin_is_tty) posix.tcgetattr(posix.STDIN_FILENO) catch null else null;

        if (saved_termios) |saved| {
            var raw = saved;
            makeRawMode(&raw);
            posix.tcsetattr(posix.STDIN_FILENO, .NOW, raw) catch {};
        }

        var self: Self = .{
            .nc_ptr = null,
            .stdplane = null,
            .size = readTerminalSize(stdout_is_tty),
            .io = io,
            .saved_termios = saved_termios,
            .nc_timeout_count = 0,
            .headless = false,
            .stdin_is_tty = stdin_is_tty,
            .stdout_is_tty = stdout_is_tty,
            .caps = capabilities.detectWithRuntime(stdin_is_tty, stdout_is_tty),
        };

        if (self.stdout_is_tty) {
            if (self.caps.has_alt_screen) {
                self.emit("\x1b[?1049h");
                self.emit("\x1b[?25l");
            }
            if (self.stdin_is_tty and self.caps.has_sgr_mouse) self.emit("\x1b[?1000h\x1b[?1006h");
            if (self.stdin_is_tty and self.caps.has_focus_events) self.emit("\x1b[?1004h");
            if (self.stdin_is_tty and self.caps.has_bracketed_paste) self.emit("\x1b[?2004h");
        }
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (!self.headless and self.stdout_is_tty) {
            self.emit("\x1b[0m");
            if (self.stdin_is_tty and self.caps.has_bracketed_paste) self.emit("\x1b[?2004l");
            if (self.stdin_is_tty and self.caps.has_focus_events) self.emit("\x1b[?1004l");
            if (self.stdin_is_tty and self.caps.has_sgr_mouse) self.emit("\x1b[?1000l\x1b[?1006l");
            if (self.caps.has_alt_screen) self.emit("\x1b[?25h");
            if (self.caps.has_alt_screen) self.emit("\x1b[?1049l");
        }
        self.flush();
        if (self.saved_termios) |termios_state| {
            posix.tcsetattr(posix.STDIN_FILENO, .NOW, termios_state) catch {};
        }
    }

    pub fn readEvent(self: *Self) !?Event {
        if (self.headless or !self.stdin_is_tty) return null;

        const first = try self.readByteWithTimeout(5);
        if (first == null) {
            if (self.nc_timeout_count < 255) self.nc_timeout_count += 1;
            if (self.detectResize()) |sz| return .{ .resize = sz };
            return null;
        }
        self.nc_timeout_count = 0;
        return try self.decodeInput(first.?);
    }

    pub fn readEventNonBlocking(self: *Self) !?Event {
        if (self.headless or !self.stdin_is_tty) return null;
        const first = try self.readByteWithTimeout(0) orelse return null;
        return try self.decodeInput(first);
    }

    pub fn readKey(self: *Self) !?Key {
        const ev = try self.readEvent() orelse return null;
        return if (ev == .key) ev.key else null;
    }

    pub fn readKeyNonBlocking(self: *Self) !?Key {
        const ev = try self.readEventNonBlocking() orelse return null;
        return if (ev == .key) ev.key else null;
    }

    pub fn refreshAfterResize(self: *Self) void {
        _ = self.updateSize() catch {};
    }

    pub fn updateSize(self: *Self) !void {
        self.size = readTerminalSize(self.stdout_is_tty);
    }

    pub fn moveTo(self: *Self, row: usize, col: usize) void {
        self.cursor_row = row;
        self.cursor_col = col;
        if (self.headless) return;
        self.emitFmt("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    pub fn writeText(self: *Self, text: []const u8) void {
        if (self.headless or text.len == 0) return;
        self.emitBytes(text);
    }

    pub fn writeSpaces(self: *Self, count: usize) void {
        if (self.headless or count == 0) return;
        var tmp: [256]u8 = [_]u8{' '} ** 256;
        var left = count;
        while (left > 0) {
            const chunk = @min(left, tmp.len);
            self.emitBytes(tmp[0..chunk]);
            left -= chunk;
        }
    }

    pub fn setFg(self: *Self, color: Color) void {
        if (colorToRgb(color)) |rgb|
            self.setFgRgb(rgb[0], rgb[1], rgb[2])
        else
            self.setFgDefault();
    }

    pub fn setFgRgb(self: *Self, r: u8, g: u8, b: u8) void {
        if (self.headless) return;
        if (self.caps.supports_rgb_fg) {
            self.emitFmt("\x1b[38;2;{d};{d};{d}m", .{ r, g, b });
            return;
        }
        if (self.caps.color_depth == .ansi256) {
            self.emitFmt("\x1b[38;5;{d}m", .{rgbToAnsi256(r, g, b)});
            return;
        }
        self.emit("\x1b[39m");
    }

    pub fn setBgRgb(self: *Self, r: u8, g: u8, b: u8) void {
        if (self.headless) return;
        if (self.caps.supports_rgb_bg) {
            self.emitFmt("\x1b[48;2;{d};{d};{d}m", .{ r, g, b });
            return;
        }
        if (self.caps.color_depth == .ansi256) {
            self.emitFmt("\x1b[48;5;{d}m", .{rgbToAnsi256(r, g, b)});
            return;
        }
        self.emit("\x1b[49m");
    }

    pub fn setFgDefault(self: *Self) void {
        if (self.headless) return;
        self.emit("\x1b[39m");
    }

    pub fn setBgDefault(self: *Self) void {
        if (self.headless) return;
        self.emit("\x1b[49m");
    }

    pub fn setStyles(self: *Self, bits: u32) void {
        if (self.headless) return;
        if (bits == STYLE_NONE) {
            self.emit("\x1b[22;23;24m");
            return;
        }
        if (bits & STYLE_BOLD != 0) self.emit("\x1b[1m");
        if (bits & STYLE_ITALIC != 0 and self.caps.supports_italic) self.emit("\x1b[3m");
        if (bits & STYLE_UNDERLINE != 0 and self.caps.supports_underline_styles) self.emit("\x1b[4m");
    }

    pub fn resetAttrs(self: *Self) void {
        if (self.headless) return;
        self.emit("\x1b[0m");
    }

    pub fn hideCursor(self: *Self) void {
        if (self.headless) return;
        if (!self.caps.has_alt_screen) return;
        self.emit("\x1b[?25l");
    }

    pub fn showCursor(self: *Self, row: usize, col: usize) void {
        self.moveTo(row, col);
        if (self.headless) return;
        if (!self.caps.has_alt_screen) return;
        self.emit("\x1b[?25h");
    }

    pub fn erasePlane(self: *Self) void {
        if (self.headless) return;
        if (self.caps.has_alt_screen) {
            self.emit("\x1b[2J\x1b[H");
        } else {
            // On primary screen buffers (e.g. conservative VSCode mode), avoid full-screen
            // clear to reduce visible flicker while still removing stale tail content.
            self.emit("\x1b[H\x1b[0J");
        }
    }

    pub fn flushRender(self: *Self) void {
        if (self.headless) return;
        self.flush();
    }

    pub fn setCursorStyle(self: *Self, style: CursorStyle) void {
        if (self.headless or !self.caps.has_cursor_shape) return;
        const seq: []const u8 = switch (style) {
            .block => "\x1b[2 q",
            .underline => "\x1b[4 q",
            .beam => "\x1b[6 q",
        };
        self.emit(seq);
    }

    fn decodeInput(self: *Self, first: u8) !?Event {
        if (first == 0x1b) {
            const next = try self.readByteWithTimeout(20) orelse {
                return .{ .key = Key.init(.escape) };
            };
            return try self.decodeEscape(next);
        }
        if (first >= 0x80) {
            return .{ .key = try self.decodeUtf8Key(first) };
        }
        if (mapByteToKey(first)) |k| return .{ .key = k };
        return null;
    }

    fn decodeEscape(self: *Self, next: u8) !?Event {
        if (next == '[') {
            var seq: [16]u8 = undefined;
            var len: usize = 0;
            while (len < seq.len) {
                const b = try self.readByteWithTimeout(10) orelse break;
                seq[len] = b;
                len += 1;
                if ((b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z') or b == '~' or b == 'm' or b == 'M') break;
            }
            return parseCsi(seq[0..len]);
        }
        if (next == 'O') {
            const b = try self.readByteWithTimeout(10) orelse return .{ .key = Key.init(.escape) };
            const base: ?BaseKey = switch (b) {
                'P' => .f1,
                'Q' => .f2,
                'R' => .f3,
                'S' => .f4,
                'A' => .up,
                'B' => .down,
                'C' => .right,
                'D' => .left,
                'H' => .home,
                'F' => .end,
                else => null,
            };
            if (base) |k| return .{ .key = Key.init(k) };
            return null;
        }

        if (mapByteToKey(next)) |k| {
            var alt_key = k;
            alt_key.mod.alt = true;
            return .{ .key = alt_key };
        }
        return .{ .key = Key.init(.escape) };
    }

    fn readByteWithTimeout(self: *Self, timeout_ms: i32) !?u8 {
        _ = self;
        var fds = [_]posix.pollfd{.{
            .fd = posix.STDIN_FILENO,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try posix.poll(&fds, timeout_ms);
        if (ready == 0) return null;

        var b: [1]u8 = undefined;
        const n = posix.read(posix.STDIN_FILENO, &b) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return null;
        return b[0];
    }

    fn decodeUtf8Key(self: *Self, first: u8) !Key {
        var buf: [4]u8 = .{ 0, 0, 0, 0 };
        buf[0] = first;
        const len: usize = if ((first & 0xE0) == 0xC0)
            2
        else if ((first & 0xF0) == 0xE0)
            3
        else if ((first & 0xF8) == 0xF0)
            4
        else
            1;

        var i: usize = 1;
        while (i < len) : (i += 1) {
            const b = try self.readByteWithTimeout(1) orelse break;
            if ((b & 0xC0) != 0x80) break;
            buf[i] = b;
        }
        return Key.initUtf8(buf[0..i]);
    }

    fn detectResize(self: *Self) ?Resize {
        const new_size = readTerminalSize(self.stdout_is_tty);
        if (new_size.rows == self.size.rows and new_size.cols == self.size.cols) return null;
        self.size = new_size;
        return .{ .rows = new_size.rows, .cols = new_size.cols };
    }

    fn emit(self: *Self, data: []const u8) void {
        self.emitBytes(data);
    }

    fn emitFmt(self: *Self, comptime fmt: []const u8, args: anytype) void {
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.emit(text);
    }

    fn emitBytes(self: *Self, data: []const u8) void {
        if (data.len == 0) return;

        if (data.len >= self.out_buf.len) {
            self.flush();
            self.writeDirect(data);
            return;
        }

        if (self.out_len + data.len > self.out_buf.len) {
            self.flush();
        }
        @memcpy(self.out_buf[self.out_len .. self.out_len + data.len], data);
        self.out_len += data.len;
    }

    fn flush(self: *Self) void {
        if (self.out_len == 0) return;
        self.writeDirect(self.out_buf[0..self.out_len]);
        self.out_len = 0;
    }

    fn writeDirect(self: *Self, data: []const u8) void {
        _ = self;
        var off: usize = 0;
        while (off < data.len) {
            const n = c.write(posix.STDOUT_FILENO, data.ptr + off, data.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (n == 0) return;
            const err = posix.errno(-1);
            if (err == .INTR) continue;
            if (err == .AGAIN) continue;
            return;
        }
    }
};

fn readTerminalSize(stdout_is_tty: bool) Size {
    if (!stdout_is_tty) return .{ .rows = 24, .cols = 80 };
    var ws: c.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    if (@hasDecl(c, "T")) {
        const rc = c.ioctl(posix.STDOUT_FILENO, @as(c_int, @intCast(c.T.IOCGWINSZ)), &ws);
        if (rc == 0 and ws.row > 0 and ws.col > 0) {
            return .{ .rows = ws.row, .cols = ws.col };
        }
    }
    return .{ .rows = 24, .cols = 80 };
}

fn makeRawMode(term: *posix.termios) void {
    if (@hasField(@TypeOf(term.iflag), "BRKINT")) term.iflag.BRKINT = false;
    if (@hasField(@TypeOf(term.iflag), "ICRNL")) term.iflag.ICRNL = false;
    if (@hasField(@TypeOf(term.iflag), "INPCK")) term.iflag.INPCK = false;
    if (@hasField(@TypeOf(term.iflag), "ISTRIP")) term.iflag.ISTRIP = false;
    if (@hasField(@TypeOf(term.iflag), "IXON")) term.iflag.IXON = false;
    if (@hasField(@TypeOf(term.oflag), "OPOST")) term.oflag.OPOST = false;
    if (@hasField(@TypeOf(term.cflag), "CSIZE")) term.cflag.CSIZE = .CS8;
    if (@hasField(@TypeOf(term.cflag), "PARENB")) term.cflag.PARENB = false;
    if (@hasField(@TypeOf(term.lflag), "ECHO")) term.lflag.ECHO = false;
    if (@hasField(@TypeOf(term.lflag), "ICANON")) term.lflag.ICANON = false;
    if (@hasField(@TypeOf(term.lflag), "IEXTEN")) term.lflag.IEXTEN = false;
    if (@hasField(@TypeOf(term.lflag), "ISIG")) term.lflag.ISIG = false;
    term.cc[@intFromEnum(posix.V.MIN)] = 0;
    term.cc[@intFromEnum(posix.V.TIME)] = 0;
}

fn parseCsi(seq: []const u8) ?Event {
    if (seq.len == 0) return null;
    const final = seq[seq.len - 1];

    if (final == 'A') return .{ .key = Key.init(.up) };
    if (final == 'B') return .{ .key = Key.init(.down) };
    if (final == 'C') return .{ .key = Key.init(.right) };
    if (final == 'D') return .{ .key = Key.init(.left) };
    if (final == 'H') return .{ .key = Key.init(.home) };
    if (final == 'F') return .{ .key = Key.init(.end) };
    if (final == 'Z') return .{ .key = Key.init(.backtab) };

    if ((final == 'm' or final == 'M') and seq.len >= 2 and seq[0] == '<') {
        return parseSgrMouse(seq, final == 'M');
    }

    if (final == '~') {
        const n = parseLeadingNumber(seq[0 .. seq.len - 1]) orelse return null;
        const base: ?BaseKey = switch (n) {
            1, 7 => .home,
            2 => .insert,
            3 => .delete,
            4, 8 => .end,
            5 => .page_up,
            6 => .page_down,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => null,
        };
        if (base) |k| return .{ .key = Key.init(k) };
    }
    return null;
}

fn parseLeadingNumber(s: []const u8) ?u16 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var n: u16 = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        n = n * 10 + (s[i] - '0');
    }
    if (i == 0) return null;
    return n;
}

fn parseSgrMouse(seq: []const u8, pressed: bool) ?Event {
    // <b;x;yM / <b;x;ym
    var parts: [3]u16 = .{ 0, 0, 0 };
    var part_idx: usize = 0;
    var i: usize = 1; // skip '<'
    while (i < seq.len - 1 and part_idx < parts.len) {
        var val: u16 = 0;
        var has_digit = false;
        while (i < seq.len - 1 and seq[i] >= '0' and seq[i] <= '9') : (i += 1) {
            has_digit = true;
            val = val * 10 + (seq[i] - '0');
        }
        if (!has_digit) return null;
        parts[part_idx] = val;
        part_idx += 1;
        if (i < seq.len - 1 and seq[i] == ';') i += 1 else break;
    }
    if (part_idx != 3) return null;

    const b = parts[0];
    const x = @as(i32, @intCast(parts[1])) - 1;
    const y = @as(i32, @intCast(parts[2])) - 1;
    const kind: MouseKind = switch (b & 0x43) {
        0 => if (pressed) .button1 else .motion,
        1 => if (pressed) .button2 else .motion,
        2 => if (pressed) .button3 else .motion,
        64 => .scroll_up,
        65 => .scroll_down,
        else => .motion,
    };
    return .{ .mouse = .{ .kind = kind, .row = y, .col = x } };
}

fn mapByteToKey(first: u8) ?Key {
    if (first == 0x7f) return Key.init(.backspace);
    if (first == 0x0d or first == 0x0a) return Key.init(.enter);
    if (first == 0x09) return Key.init(.tab);
    if (first == 0x1b) return Key.init(.escape);
    if (first == 0x00) return Key.init(.null);

    if (first < 32) {
        if (first >= 1 and first <= 26) {
            const letter: u8 = @intCast('a' + first - 1);
            return Key{ .base = @enumFromInt(letter), .mod = .{ .ctrl = true } };
        }
        return null;
    }
    if (first < 128) {
        return Key.init(@enumFromInt(first));
    }

    return null;
}

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

fn rgbToAnsi256(r: u8, g: u8, b: u8) u8 {
    const rr: u8 = @intCast((@as(u16, r) * 5) / 255);
    const gg: u8 = @intCast((@as(u16, g) * 5) / 255);
    const bb: u8 = @intCast((@as(u16, b) * 5) / 255);
    return @as(u8, 16) + rr * 36 + gg * 6 + bb;
}

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
}

test "parseCsi maps arrow and paging keys" {
    const up = parseCsi("A").?;
    try std.testing.expectEqual(Key.init(.up), up.key);

    const right = parseCsi("C").?;
    try std.testing.expectEqual(Key.init(.right), right.key);

    const pg_up = parseCsi("5~").?;
    try std.testing.expectEqual(Key.init(.page_up), pg_up.key);

    const f12 = parseCsi("24~").?;
    try std.testing.expectEqual(Key.init(.f12), f12.key);
}

test "parseCsi maps backtab and mouse events" {
    const backtab = parseCsi("Z").?;
    try std.testing.expectEqual(Key.init(.backtab), backtab.key);

    const mouse_up = parseCsi("<64;10;4M").?;
    try std.testing.expect(mouse_up == .mouse);
    try std.testing.expectEqual(@as(i32, 9), mouse_up.mouse.col);
    try std.testing.expectEqual(@as(i32, 3), mouse_up.mouse.row);
    try std.testing.expectEqual(MouseKind.scroll_up, mouse_up.mouse.kind);
}

test "mapByteToKey handles control and ascii keys" {
    const ctrl_a = mapByteToKey(1).?;
    try std.testing.expect(ctrl_a.mod.ctrl);
    try std.testing.expectEqual(BaseKey.lower_a, ctrl_a.base);

    const tab = mapByteToKey(9).?;
    try std.testing.expectEqual(Key.init(.tab), tab);

    const ascii = mapByteToKey('x').?;
    try std.testing.expectEqual(Key.init(.lower_x), ascii);
}
