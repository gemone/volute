pub const BaseKey = enum(u16) {
    // Printable ASCII
    space = ' ',
    exclam = '!',
    double_quote = '"',
    hash = '#',
    dollar = '$',
    percent = '%',
    ampersand = '&',
    single_quote = '\'',
    left_paren = '(',
    right_paren = ')',
    asterisk = '*',
    plus = '+',
    comma = ',',
    minus = '-',
    dot = '.',
    slash = '/',
    digit_0 = '0',
    digit_1 = '1',
    digit_2 = '2',
    digit_3 = '3',
    digit_4 = '4',
    digit_5 = '5',
    digit_6 = '6',
    digit_7 = '7',
    digit_8 = '8',
    digit_9 = '9',
    colon = ':',
    semicolon = ';',
    less = '<',
    equal = '=',
    greater = '>',
    question = '?',
    at = '@',
    upper_a = 'A',
    upper_b = 'B',
    upper_c = 'C',
    upper_d = 'D',
    upper_e = 'E',
    upper_f = 'F',
    upper_g = 'G',
    upper_h = 'H',
    upper_i = 'I',
    upper_j = 'J',
    upper_k = 'K',
    upper_l = 'L',
    upper_m = 'M',
    upper_n = 'N',
    upper_o = 'O',
    upper_p = 'P',
    upper_q = 'Q',
    upper_r = 'R',
    upper_s = 'S',
    upper_t = 'T',
    upper_u = 'U',
    upper_v = 'V',
    upper_w = 'W',
    upper_x = 'X',
    upper_y = 'Y',
    upper_z = 'Z',
    left_bracket = '[',
    backslash = '\\',
    right_bracket = ']',
    caret = '^',
    underscore = '_',
    backtick = '`',
    lower_a = 'a',
    lower_b = 'b',
    lower_c = 'c',
    lower_d = 'd',
    lower_e = 'e',
    lower_f = 'f',
    lower_g = 'g',
    lower_h = 'h',
    lower_i = 'i',
    lower_j = 'j',
    lower_k = 'k',
    lower_l = 'l',
    lower_m = 'm',
    lower_n = 'n',
    lower_o = 'o',
    lower_p = 'p',
    lower_q = 'q',
    lower_r = 'r',
    lower_s = 's',
    lower_t = 't',
    lower_u = 'u',
    lower_v = 'v',
    lower_w = 'w',
    lower_x = 'x',
    lower_y = 'y',
    lower_z = 'z',
    left_brace = '{',
    pipe = '|',
    right_brace = '}',
    tilde = '~',

    // Special keys
    enter = 13,
    tab = 9,
    backtab,
    backspace = 127,
    escape = 256,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Non-printable
    null,
};

pub const Key = struct {
    pub const Modifier = packed struct {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
    };

    mod: Modifier = .{},
    base: BaseKey = .null,
    utf8_bytes: [4]u8 = .{ 0, 0, 0, 0 },
    utf8_len: u8 = 0,

    pub fn init(base: BaseKey) @This() {
        return .{ .base = base };
    }

    pub fn initCtrl(base: BaseKey) @This() {
        return .{ .base = base, .mod = .{ .ctrl = true } };
    }

    pub fn initAlt(base: BaseKey) @This() {
        return .{ .base = base, .mod = .{ .alt = true } };
    }

    pub fn initUtf8(bytes: []const u8) @This() {
        var key: @This() = .{};
        if (bytes.len > 0 and bytes.len <= 4) {
            @memcpy(key.utf8_bytes[0..bytes.len], bytes);
            key.utf8_len = @intCast(bytes.len);
        }
        return key;
    }

    pub fn format(self: @This(), buf: *[16]u8) []const u8 {
        var i: usize = 0;
        if (self.mod.ctrl) {
            buf[i] = 'C';
            i += 1;
            buf[i] = '-';
            i += 1;
        }
        if (self.mod.alt) {
            buf[i] = 'A';
            i += 1;
            buf[i] = '-';
            i += 1;
        }
        const label = switch (self.base) {
            .space => "space",
            .enter => "ret",
            .tab => "tab",
            .backtab => "S-tab",
            .backspace => "backspace",
            .escape => "esc",
            .up => "up",
            .down => "down",
            .left => "left",
            .right => "right",
            .home => "home",
            .end => "end",
            .page_up => "pageup",
            .page_down => "pagedown",
            .delete => "del",
            .insert => "ins",
            .f1 => "F1",
            .f2 => "F2",
            .f3 => "F3",
            .f4 => "F4",
            .f5 => "F5",
            .f6 => "F6",
            .f7 => "F7",
            .f8 => "F8",
            .f9 => "F9",
            .f10 => "F10",
            .f11 => "F11",
            .f12 => "F12",
            .null => "null",
            else => &[1]u8{@intCast(@intFromEnum(self.base))},
        };
        const len = if (@typeInfo(@TypeOf(label)) == .pointer) label.len else 1;
        @memcpy(buf[i..][0..len], label);
        i += len;
        return buf[0..i];
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return a.mod.ctrl == b.mod.ctrl and a.mod.alt == b.mod.alt and a.base == b.base;
    }

    pub fn char(self: @This()) ?u8 {
        const v = @intFromEnum(self.base);
        if (v >= 32 and v < 127) return @intCast(v);
        return null;
    }

    pub fn getBytes(self: *const @This()) []const u8 {
        if (self.utf8_len > 0) {
            return self.utf8_bytes[0..self.utf8_len];
        }
        return &[0]u8{};
    }
};
