/// notcurses C bindings and Key mapping for vx.
///
/// This module wraps the notcurses C API so the rest of vx stays in Zig.
/// All notcurses symbols are exposed via `c.*`.  Key helpers are
/// `ncinputToEvent` (preferred) and `ncinputToKey` (legacy).
const std = @import("std");
const Key = @import("../vx/key.zig").Key;
const BaseKey = @import("../vx/key.zig").BaseKey;

pub const c = @import("notcurses_c");

// ─── PRETERUNICODE offset (same value as in nckeys.h) ──────────────────────
const PRETERUNICODEBASE: u32 = 1115000;

inline fn nckey(offset: u32) u32 {
    return PRETERUNICODEBASE + offset;
}

// ─── Event types ──────────────────────────────────────────────────────────
/// A mouse event from notcurses.
pub const MouseEvent = struct {
    kind: enum { button1, button2, button3, scroll_up, scroll_down, motion },
    row: i32,
    col: i32,
};

/// All event types the terminal can produce.
pub const Event = union(enum) {
    key: Key,
    resize: struct { rows: usize, cols: usize },
    mouse: MouseEvent,
};

// ─── ncinput → Event ──────────────────────────────────────────────────────
/// Convert a notcurses `ncinput` to an `Event`.  Returns null for:
/// - key-release events (vx acts on press/repeat only)
/// - unrecognised synthesised keys
///
/// `nc_ptr` is required for NCKEY_RESIZE to call `notcurses_refresh`.
pub fn ncinputToEvent(nc_ptr: *c.notcurses, ni: c.ncinput) ?Event {
    // Ignore release events.
    if (ni.evtype == c.NCTYPE_RELEASE) return null;

    const id = ni.id;

    // ── Resize ────────────────────────────────────────────────────────────
    if (id == nckey(1)) { // NCKEY_RESIZE
        var rows: c_uint = 0;
        var cols: c_uint = 0;
        _ = c.notcurses_refresh(nc_ptr, &rows, &cols);
        return .{ .resize = .{ .rows = @intCast(rows), .cols = @intCast(cols) } };
    }

    // ── Mouse events ──────────────────────────────────────────────────────
    if (id >= nckey(200) and id <= nckey(211)) {
        const kind: @TypeOf(@as(MouseEvent, undefined).kind) = switch (id) {
            nckey(200) => .motion,
            nckey(201) => .button1,
            nckey(202) => .button2,
            nckey(203) => .button3,
            nckey(204) => .scroll_up, // NCKEY_BUTTON4 / NCKEY_SCROLL_UP
            nckey(205) => .scroll_down, // NCKEY_BUTTON5 / NCKEY_SCROLL_DOWN
            else => .button1,
        };
        return .{ .mouse = .{ .kind = kind, .row = ni.y, .col = ni.x } };
    }

    // ── Key events ────────────────────────────────────────────────────────
    if (ncinputToKey(ni)) |k| return .{ .key = k };
    return null;
}

// ─── ncinput → Key (legacy) ───────────────────────────────────────────────
/// Convert a notcurses `ncinput` event to vx's `Key`.  Returns null for
/// release events, mouse events and unrecognised synthesised keys.
pub fn ncinputToKey(ni: c.ncinput) ?Key {
    // Ignore release events; vx acts on press/repeat only.
    if (ni.evtype == c.NCTYPE_RELEASE) return null;

    const id = ni.id;

    // Build modifiers.
    var mod = Key.Modifier{};
    if (ni.modifiers & c.NCKEY_MOD_SHIFT != 0) mod.shift = true;
    if (ni.modifiers & c.NCKEY_MOD_CTRL != 0) mod.ctrl = true;
    if (ni.modifiers & c.NCKEY_MOD_ALT != 0) mod.alt = true;

    // ── Special / function keys ────────────────────────────────────────────
    if (id >= PRETERUNICODEBASE) {
        const base: ?BaseKey = switch (id) {
            nckey(1) => null, // NCKEY_RESIZE — vx handles via updateSize
            nckey(2) => .up,
            nckey(3) => .right,
            nckey(4) => .down,
            nckey(5) => .left,
            nckey(6) => .insert,
            nckey(7) => .delete,
            nckey(8) => .backspace,
            nckey(9) => .page_down,
            nckey(10) => .page_up,
            nckey(11) => .home,
            nckey(12) => .end,
            nckey(121) => .enter, // NCKEY_ENTER / NCKEY_RETURN
            nckey(21) => .f1,
            nckey(22) => .f2,
            nckey(23) => .f3,
            nckey(24) => .f4,
            nckey(25) => .f5,
            nckey(26) => .f6,
            nckey(27) => .f7,
            nckey(28) => .f8,
            nckey(29) => .f9,
            nckey(30) => .f10,
            nckey(31) => .f11,
            nckey(32) => .f12,
            else => null,
        };
        if (base) |b| {
            if (b == .tab and mod.shift) {
                return Key{ .base = .backtab, .mod = .{ .ctrl = mod.ctrl, .alt = mod.alt } };
            }
            return Key{ .base = b, .mod = mod };
        }
        return null;
    }

    // ── ASCII / Unicode ────────────────────────────────────────────────────
    // Ctrl+letter: notcurses delivers the raw codepoint (e.g. ctrl+c = 3).
    // Handle the common terminal control codes that vx cares about.
    if (id < 32) {
        // Ctrl+i shares the raw codepoint with Tab; preserve the ctrl modifier
        // when the terminal provides it (e.g. kitty/notcurses with modifiers).
        if (id == 0x09 and mod.ctrl) {
            return Key{ .base = .lower_i, .mod = mod };
        }

        // Semantic special keys take priority.
        const base: ?BaseKey = switch (id) {
            0x00 => .null,
            0x08 => .backspace, // ctrl+h = backspace in traditional terminals
            0x09 => .tab,
            0x0d => .enter,
            0x1b => .escape,
            else => null,
        };
        if (base) |b| {
            if (b == .tab and mod.shift) {
                return Key{ .base = .backtab, .mod = .{ .ctrl = mod.ctrl, .alt = mod.alt } };
            }
            return Key{ .base = b, .mod = mod };
        }
        // Ctrl+letter: codepoints 1-26 → ctrl+a..ctrl+z (non-kitty terminals
        // embed the ctrl modifier in the codepoint instead of ni.modifiers).
        if (id >= 1 and id <= 26) {
            const letter: u8 = @intCast('a' + id - 1);
            return Key{ .base = @enumFromInt(letter), .mod = .{ .ctrl = true, .shift = mod.shift, .alt = mod.alt } };
        }
        // Codepoints 28-31 (ctrl+\, ctrl+], ctrl+^, ctrl+_) — not mapped.
        return null;
    }

    // Printable ASCII (32–126) + DEL (127=backspace): map directly to BaseKey.
    // When Ctrl is held, normalise uppercase letters to lowercase — terminals
    // and multiplexers are inconsistent: some deliver Ctrl+W as id=23 (raw
    // control codepoint), others as id=87 ('W') with ctrl modifier.
    if (id >= 32 and id <= 127) {
        if (id == 127) return Key{ .base = .backspace, .mod = mod };
        if (mod.ctrl and id >= 'A' and id <= 'Z') {
            return Key{ .base = @enumFromInt(id + 32), .mod = .{ .ctrl = true, .shift = mod.shift, .alt = mod.alt } };
        }
        return Key{ .base = @enumFromInt(id), .mod = mod };
    }

    // Unicode codepoints >= 128: store raw UTF-8 bytes and preserve modifiers.
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(id), &buf) catch return null;
    var key = Key.initUtf8(buf[0..len]);
    key.mod = mod;
    return key;
}

fn makeInput(id: u32, modifiers: u32) c.ncinput {
    return .{
        .id = id,
        .evtype = c.NCTYPE_PRESS,
        .modifiers = modifiers,
    };
}

test "ncinputToKey maps shifted ASCII, ctrl-i, alt, and unicode modifiers" {
    const shifted = [_]struct {
        id: u32,
        base: BaseKey,
    }{
        .{ .id = 'A', .base = .upper_a },
        .{ .id = 'H', .base = .upper_h },
        .{ .id = 'Z', .base = .upper_z },
        .{ .id = '!', .base = .exclam },
        .{ .id = '@', .base = .at },
        .{ .id = '#', .base = .hash },
        .{ .id = '$', .base = .dollar },
        .{ .id = '%', .base = .percent },
        .{ .id = '^', .base = .caret },
        .{ .id = '&', .base = .ampersand },
        .{ .id = '*', .base = .asterisk },
        .{ .id = '(', .base = .left_paren },
        .{ .id = ')', .base = .right_paren },
        .{ .id = '_', .base = .underscore },
        .{ .id = '+', .base = .plus },
        .{ .id = '{', .base = .left_brace },
        .{ .id = '}', .base = .right_brace },
        .{ .id = '|', .base = .pipe },
        .{ .id = ':', .base = .colon },
        .{ .id = '"', .base = .double_quote },
        .{ .id = '<', .base = .less },
        .{ .id = '>', .base = .greater },
        .{ .id = '?', .base = .question },
    };

    for (shifted) |case_| {
        const key = ncinputToKey(makeInput(case_.id, c.NCKEY_MOD_SHIFT)) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(case_.base, key.base);
        try std.testing.expect(key.mod.shift);
        try std.testing.expect(!key.mod.ctrl);
        try std.testing.expect(!key.mod.alt);
    }

    const ctrl_i = ncinputToKey(makeInput(0x09, c.NCKEY_MOD_CTRL)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(ctrl_i.eql(Key.initCtrl(.lower_i)));

    const backtab = ncinputToKey(makeInput(0x09, c.NCKEY_MOD_SHIFT)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(BaseKey.backtab, backtab.base);
    try std.testing.expect(!backtab.mod.shift);

    const alt_x = ncinputToKey(makeInput('x', c.NCKEY_MOD_ALT)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(alt_x.eql(Key.initAlt(.lower_x)));

    const unicode = ncinputToKey(makeInput(0x4F60, c.NCKEY_MOD_ALT)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, "你", unicode.getBytes());
    try std.testing.expect(unicode.mod.alt);
}

// ─── Color helpers ────────────────────────────────────────────────────────
/// Set the foreground RGB on an ncplane (helper used by view.zig).
pub inline fn setFgRgb(plane: *c.ncplane, r: u8, g: u8, b: u8) void {
    _ = c.ncplane_set_fg_rgb8(plane, r, g, b);
}

pub inline fn setFgDefault(plane: *c.ncplane) void {
    c.ncplane_set_fg_default(plane);
}

pub inline fn setBgDefault(plane: *c.ncplane) void {
    c.ncplane_set_bg_default(plane);
}

pub inline fn setStyles(plane: *c.ncplane, styles: u32) void {
    c.ncplane_set_styles(plane, styles);
}

pub inline fn putStrYx(plane: *c.ncplane, y: c_int, x: c_int, s: [*:0]const u8) c_int {
    return c.ncplane_putstr_yx(plane, y, x, s);
}

pub inline fn putNStr(plane: *c.ncplane, n: usize, s: [*:0]const u8) c_int {
    return c.ncplane_putnstr(plane, n, s);
}
