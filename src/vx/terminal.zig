const std = @import("std");
const Key = @import("key.zig").Key;
const File = std.Io.File;

pub const Color = enum { default, red, green, yellow, blue, magenta, cyan, white, gray };

pub const TerminalState = struct {
    current_fg: ?Color = null,
    current_bg: ?Color = null,
    current_bold: bool = false,
    current_reverse: bool = false,

    pub fn reset(self: *TerminalState) void {
        self.current_fg = null;
        self.current_bg = null;
        self.current_bold = false;
        self.current_reverse = false;
    }

    pub fn needsFgChange(self: *const TerminalState, new_color: Color) bool {
        return self.current_fg != new_color;
    }

    pub fn needsBgChange(self: *const TerminalState, new_color: Color) bool {
        return self.current_bg != new_color;
    }

    pub fn needsBoldChange(self: *const TerminalState, new_bold: bool) bool {
        return self.current_bold != new_bold;
    }

    pub fn needsReverseChange(self: *const TerminalState, new_reverse: bool) bool {
        return self.current_reverse != new_reverse;
    }
};

pub const Terminal = struct {
    const Self = @This();

    io: std.Io,
    original_termios: std.posix.termios,
    out: File,
    in: File,
    size: struct { rows: usize, cols: usize },
    pending_input: [16]u8,
    pending_len: usize,

    pub fn init(io: std.Io) !Self {
        const out = File.stdout();
        const in = File.stdin();
        const original = try std.posix.tcgetattr(in.handle);
        var raw = original;

        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;

        try std.posix.tcsetattr(in.handle, .FLUSH, raw);
        try out.writeStreamingAll(io, "\x1b[?1049h\x1b[?25l");

        const winsize = try getWinsize(out.handle);

        return .{
            .io = io,
            .original_termios = original,
            .out = out,
            .in = in,
            .size = .{ .rows = winsize.row, .cols = winsize.col },
            .pending_input = undefined,
            .pending_len = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.out.writeStreamingAll(self.io, "\x1b[2 q\x1b[?25h\x1b[?1049l") catch {};
        std.posix.tcsetattr(self.in.handle, .FLUSH, self.original_termios) catch {};
    }

    pub fn writeAll(self: Self, bytes: []const u8) !void {
        try self.out.writeStreamingAll(self.io, bytes);
    }

    pub fn updateSize(self: *Self) !void {
        const ws = try getWinsize(self.out.handle);
        self.size.rows = ws.row;
        self.size.cols = ws.col;
    }

    pub fn readKey(self: *Self) !?Key {
        if (self.pending_len == 0) {
            const n = try std.posix.read(self.in.handle, &self.pending_input);
            if (n == 0) return null;
            self.pending_len = n;
        }

        const consumed = parseEscapeLen(self.pending_input[0..self.pending_len]);
        if (consumed == 0) {
            // Bare ESC or incomplete sequence — try reading more
            const extra = try std.posix.read(self.in.handle, self.pending_input[self.pending_len..]);
            if (extra == 0) {
                // Timeout: treat bare ESC as escape key
                if (self.pending_len >= 1 and self.pending_input[0] == 27) {
                    self.pending_len = 0;
                    return Key{ .base = .escape };
                }
                self.pending_len = 0;
                return null;
            }
            self.pending_len += extra;
            const consumed2 = parseEscapeLen(self.pending_input[0..self.pending_len]);
            if (consumed2 == 0) {
                self.pending_len = 0;
                return null;
            }
            const key = parseEscape(self.pending_input[0..self.pending_len]);
            self.shiftPending(consumed2);
            return key;
        }

        const key = parseEscape(self.pending_input[0..self.pending_len]);
        self.shiftPending(consumed);
        return key;
    }

    fn shiftPending(self: *Self, consumed: usize) void {
        const remaining = self.pending_len - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.pending_input[0..remaining], self.pending_input[consumed..self.pending_len]);
        }
        self.pending_len = remaining;
    }

    fn getWinsize(fd: std.posix.fd_t) !struct { row: usize, col: usize } {
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (rc == -1) return error.IoctlFailed;
        return .{ .row = ws.row, .col = ws.col };
    }
};

fn parseEscapeLen(buf: []const u8) usize {
    if (buf.len == 0) return 0;
    const b = buf[0];

    // UTF-8 multi-byte sequences
    if ((b & 0xE0) == 0xC0) {
        // 2-byte UTF-8: 110xxxxx 10xxxxxx
        if (buf.len < 2) return 0;
        return 2;
    }
    if ((b & 0xF0) == 0xE0) {
        // 3-byte UTF-8: 1110xxxx 10xxxxxx 10xxxxxx
        if (buf.len < 3) return 0;
        return 3;
    }
    if ((b & 0xF8) == 0xF0) {
        // 4-byte UTF-8: 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx
        if (buf.len < 4) return 0;
        return 4;
    }

    // Single-byte keys
    if (b == 13 or b == 9 or b == 127 or (b >= 1 and b <= 26) or (b >= 32 and b < 127)) return 1;
    if (b != 27) return 1; // Unknown byte, consume it

    // ESC sequences
    if (buf.len < 2) return 0; // Bare ESC, need more data (or it's just ESC)
    if (buf[1] != '[') {
        // Alt+char or bare ESC
        if (buf[1] >= 'a' and buf[1] <= 'z') return 2;
        if (buf[1] >= 'A' and buf[1] <= 'Z') return 2;
        return 1; // Treat as bare ESC
    }

    // CSI sequences: ESC [
    if (buf.len < 3) return 0;

    // CSI + letter: 3 bytes (ESC [ A/B/C/D/H/F)
    if ((buf[2] >= 'A' and buf[2] <= 'Z') or (buf[2] >= 'a' and buf[2] <= 'z')) return 3;

    // CSI + digit: need more bytes
    if (buf[2] >= '0' and buf[2] <= '9') {
        if (buf.len < 4) return 0;
        if (buf[3] == '~') return 4; // ESC [ 5 ~
        if (buf.len < 5) return 0;
        if (buf[4] == '~') return 5; // ESC [ 1 1 ~
        if (buf.len < 6) return 0;
        if (buf[2] == '1' and buf[3] == ';') return 6; // ESC [ 1 ; 5 A
    }

    return 3; // Unknown CSI, consume minimum
}

fn parseEscape(buf: []const u8) ?Key {
    if (buf.len == 0) return null;

    const b = buf[0];

    // UTF-8 multi-byte sequences
    if ((b & 0xE0) == 0xC0 and buf.len >= 2) {
        return Key.initUtf8(buf[0..2]);
    }
    if ((b & 0xF0) == 0xE0 and buf.len >= 3) {
        return Key.initUtf8(buf[0..3]);
    }
    if ((b & 0xF8) == 0xF0 and buf.len >= 4) {
        return Key.initUtf8(buf[0..4]);
    }

    if (b == 13) return Key{ .base = .enter };
    if (b == 9) return Key{ .base = .tab };
    if (b == 127) return Key{ .base = .backspace };
    if (b == 27) {
        if (buf.len < 2) return Key{ .base = .escape };
        if (buf[1] == '[' and buf.len >= 3) {
            if (buf.len == 3) {
                return switch (buf[2]) {
                    'A' => Key{ .base = .up },
                    'B' => Key{ .base = .down },
                    'C' => Key{ .base = .right },
                    'D' => Key{ .base = .left },
                    'H' => Key{ .base = .home },
                    'F' => Key{ .base = .end },
                    else => Key{ .base = .escape },
                };
            }
            if (buf.len == 4 and buf[3] == '~') {
                return switch (buf[2]) {
                    '1', '7' => Key{ .base = .home },
                    '3' => Key{ .base = .delete },
                    '4', '8' => Key{ .base = .end },
                    '5' => Key{ .base = .page_up },
                    '6' => Key{ .base = .page_down },
                    else => Key{ .base = .escape },
                };
            }
            if (buf.len == 5 and buf[4] == '~') {
                const fnum: usize = switch (buf[2]) {
                    '1' => switch (buf[3]) {
                        '1' => 1,
                        '2' => 2,
                        '3' => 3,
                        '4' => 4,
                        else => return Key{ .base = .escape },
                    },
                    '2' => switch (buf[3]) {
                        '0' => 9,
                        '1' => 10,
                        '3' => 11,
                        '4' => 12,
                        else => return Key{ .base = .escape },
                    },
                    else => return Key{ .base = .escape },
                };
                return Key{ .base = switch (fnum) {
                    1 => .f1,
                    2 => .f2,
                    3 => .f3,
                    4 => .f4,
                    9 => .f9,
                    10 => .f10,
                    11 => .f11,
                    12 => .f12,
                    else => return Key{ .base = .escape },
                } };
            }
            if (buf.len >= 6 and buf[2] == '1' and buf[3] == ';') {
                const mod_val: u8 = buf[4] - '0';
                const dir: u8 = buf[5];
                const mod_alt: bool = mod_val >= 3;
                const mod_ctrl: bool = mod_val == 5 or mod_val == 7 or mod_val == 9;
                const base: @import("key.zig").BaseKey = switch (dir) {
                    'A' => .up,
                    'B' => .down,
                    'C' => .right,
                    'D' => .left,
                    'H' => .home,
                    'F' => .end,
                    else => return Key{ .base = .escape },
                };
                return Key{ .base = base, .mod = .{ .ctrl = mod_ctrl, .alt = mod_alt } };
            }
        }
        if (buf.len >= 2) {
            const c = buf[1];
            if (c >= 'a' and c <= 'z') return Key{ .base = @enumFromInt(c), .mod = .{ .alt = true } };
            if (c >= 'A' and c <= 'Z') return Key{ .base = @enumFromInt(c), .mod = .{ .alt = true } };
        }
        return Key{ .base = .escape };
    }
    if (b >= 1 and b <= 26) return Key{ .base = @enumFromInt(b + 96), .mod = .{ .ctrl = true } };
    if (b >= 32 and b < 127) return Key{ .base = @enumFromInt(b) };
    return null;
}

// Rendering helpers — all take (allocator, buf, ...) following Zig 0.16 convention
pub fn moveTo(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), row: usize, col: usize) !void {
    try buf.print(gpa, "\x1b[{};{}H", .{ row + 1, col + 1 });
}

pub fn clearScreen(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(gpa, "\x1b[2J\x1b[H");
}

pub fn setFg(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), color: enum { default, red, green, yellow, blue, magenta, cyan, white, gray }) !void {
    const code: []const u8 = switch (color) {
        .default => "\x1b[39m",
        .red => "\x1b[31m",
        .green => "\x1b[32m",
        .yellow => "\x1b[33m",
        .blue => "\x1b[34m",
        .magenta => "\x1b[35m",
        .cyan => "\x1b[36m",
        .white => "\x1b[37m",
        .gray => "\x1b[90m",
    };
    try buf.appendSlice(gpa, code);
}

pub fn setBg(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), color: enum { default, red, green, blue, magenta, cyan, white, gray }) !void {
    const code: []const u8 = switch (color) {
        .default => "\x1b[49m",
        .red => "\x1b[41m",
        .green => "\x1b[42m",
        .blue => "\x1b[44m",
        .magenta => "\x1b[45m",
        .cyan => "\x1b[46m",
        .white => "\x1b[47m",
        .gray => "\x1b[100m",
    };
    try buf.appendSlice(gpa, code);
}

pub fn setBold(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), on: bool) !void {
    try buf.appendSlice(gpa, if (on) "\x1b[1m" else "\x1b[22m");
}

pub fn setReverse(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), on: bool) !void {
    try buf.appendSlice(gpa, if (on) "\x1b[7m" else "\x1b[27m");
}

pub fn resetAttrs(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(gpa, "\x1b[0m");
}

pub fn hideCursor(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(gpa, "\x1b[?25l");
}

pub fn showCursor(gpa: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
    try buf.appendSlice(gpa, "\x1b[?25h");
}

pub const CursorStyle = enum {
    block,
    underline,
    beam,
};

pub fn parseCursorStyle(name: []const u8) ?CursorStyle {
    if (std.ascii.eqlIgnoreCase(name, "block")) return .block;
    if (std.ascii.eqlIgnoreCase(name, "underline")) return .underline;
    if (std.ascii.eqlIgnoreCase(name, "beam")) return .beam;
    return null;
}

pub fn setCursorStyle(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), style: CursorStyle) !void {
    const seq = switch (style) {
        .block => "\x1b[2 q",
        .underline => "\x1b[4 q",
        .beam => "\x1b[6 q",
    };
    try buf.appendSlice(gpa, seq);
}

test "parseCursorStyle accepts supported values only" {
    try std.testing.expectEqual(CursorStyle.block, parseCursorStyle("block").?);
    try std.testing.expectEqual(CursorStyle.underline, parseCursorStyle("underline").?);
    try std.testing.expectEqual(CursorStyle.beam, parseCursorStyle("beam").?);
    try std.testing.expect(parseCursorStyle("slash") == null);
    try std.testing.expect(parseCursorStyle("bar") == null);
    try std.testing.expect(parseCursorStyle("weird") == null);
}
