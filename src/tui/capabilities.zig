const std = @import("std");

pub const ColorDepth = enum { mono, ansi16, ansi256, truecolor };
pub const TerminalFamily = enum {
    unknown,
    xterm,
    iTerm2,
    wezterm,
    kitty,
    alacritty,
    tmux,
    screen,
    vscode,
    windows_terminal,
    linux_console,
};
pub const Confidence = enum { low, medium, high };

pub const Capabilities = struct {
    terminal_family: TerminalFamily = .unknown,
    confidence: Confidence = .low,
    color_depth: ColorDepth = .ansi16,
    has_alt_screen: bool = true,
    has_cursor_shape: bool = false,
    has_bracketed_paste: bool = false,
    has_sgr_mouse: bool = false,
    has_focus_events: bool = false,
    has_kitty_kbd_protocol: bool = false,
    supports_underline_styles: bool = true,
    supports_italic: bool = false,
    supports_rgb_bg: bool = false,
    supports_rgb_fg: bool = false,
};

const DetectInput = struct {
    term: []const u8 = "",
    colorterm: []const u8 = "",
    term_program: []const u8 = "",
    has_tmux: bool = false,
    has_screen: bool = false,
    has_kitty: bool = false,
    has_wt: bool = false,
    has_vscode: bool = false,
    stdin_is_tty: bool = true,
    stdout_is_tty: bool = true,

    override_color_depth: ?ColorDepth = null,
    override_disable_italic: bool = false,
    override_disable_underline: bool = false,
    override_disable_mouse: bool = false,
    override_disable_cursor_shape: bool = false,
    override_force_focus_events: bool = false,
};

fn env(name: [*:0]const u8) ?[]const u8 {
    const raw = std.c.getenv(name) orelse return null;
    return std.mem.span(raw);
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn parseBoolEnv(name: [*:0]const u8) bool {
    const v = env(name) orelse return false;
    return std.mem.eql(u8, v, "1") or std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "yes") or std.ascii.eqlIgnoreCase(v, "on");
}

fn parseColorDepthEnv() ?ColorDepth {
    const v = env("VX_TUI_COLOR_DEPTH") orelse return null;
    if (std.ascii.eqlIgnoreCase(v, "mono")) return .mono;
    if (std.ascii.eqlIgnoreCase(v, "ansi16")) return .ansi16;
    if (std.ascii.eqlIgnoreCase(v, "ansi256")) return .ansi256;
    if (std.ascii.eqlIgnoreCase(v, "truecolor")) return .truecolor;
    return null;
}

fn detectFromInput(input: DetectInput) Capabilities {
    var caps: Capabilities = .{};

    if (input.has_tmux) {
        caps.terminal_family = .tmux;
        caps.confidence = .high;
    } else if (input.has_screen) {
        caps.terminal_family = .screen;
        caps.confidence = .high;
    } else if (input.has_kitty or containsCaseInsensitive(input.term_program, "kitty")) {
        caps.terminal_family = .kitty;
        caps.confidence = .high;
    } else if (containsCaseInsensitive(input.term_program, "wezterm")) {
        caps.terminal_family = .wezterm;
        caps.confidence = .high;
    } else if (containsCaseInsensitive(input.term_program, "iterm")) {
        caps.terminal_family = .iTerm2;
        caps.confidence = .high;
    } else if (input.has_wt) {
        caps.terminal_family = .windows_terminal;
        caps.confidence = .high;
    } else if (input.has_vscode) {
        caps.terminal_family = .vscode;
        caps.confidence = .medium;
    } else if (containsCaseInsensitive(input.term, "alacritty")) {
        caps.terminal_family = .alacritty;
        caps.confidence = .high;
    } else if (containsCaseInsensitive(input.term, "xterm")) {
        caps.terminal_family = .xterm;
        caps.confidence = .medium;
    } else if (containsCaseInsensitive(input.term, "linux")) {
        caps.terminal_family = .linux_console;
        caps.confidence = .medium;
    }

    if (containsCaseInsensitive(input.colorterm, "truecolor") or containsCaseInsensitive(input.colorterm, "24bit")) {
        caps.color_depth = .truecolor;
    } else if (containsCaseInsensitive(input.term, "256color")) {
        caps.color_depth = .ansi256;
    } else if (containsCaseInsensitive(input.term, "color")) {
        caps.color_depth = .ansi16;
    } else {
        caps.color_depth = .mono;
    }

    caps.has_kitty_kbd_protocol = caps.terminal_family == .kitty;
    caps.has_focus_events = switch (caps.terminal_family) {
        .kitty, .wezterm, .iTerm2, .windows_terminal => true,
        else => false,
    };

    if (caps.terminal_family == .linux_console) {
        caps.supports_italic = false;
        caps.has_cursor_shape = false;
    }

    // Enable richer protocols only for known-compatible families.
    switch (caps.terminal_family) {
        .kitty, .wezterm, .iTerm2, .alacritty, .xterm, .windows_terminal => {
            caps.has_cursor_shape = true;
            caps.has_sgr_mouse = true;
            caps.supports_italic = true;
            caps.has_bracketed_paste = true;
        },
        .vscode => {
            // VSCode integrated terminal is the most variable host.
            // Prefer stable defaults; users can opt in via env overrides.
            caps.has_alt_screen = false;
            caps.has_cursor_shape = true;
            caps.has_sgr_mouse = false;
            caps.supports_italic = true;
            caps.has_bracketed_paste = false;
            caps.has_focus_events = false;
        },
        .tmux, .screen => {
            // Multiplexers: keep cursor-shape conservative, but mouse/paste are generally safe.
            caps.has_sgr_mouse = true;
            caps.has_bracketed_paste = true;
        },
        else => {},
    }

    // Dynamic probe merge: runtime tty signals.
    if (!input.stdout_is_tty) {
        caps.color_depth = .mono;
        caps.has_alt_screen = false;
        caps.has_cursor_shape = false;
        caps.has_sgr_mouse = false;
        caps.has_focus_events = false;
        caps.confidence = .low;
    }
    if (!input.stdin_is_tty) {
        caps.has_sgr_mouse = false;
        caps.has_focus_events = false;
        if (caps.confidence == .high) caps.confidence = .medium;
    }
    if (std.ascii.eqlIgnoreCase(input.term, "dumb")) {
        caps.color_depth = .mono;
        caps.has_alt_screen = false;
        caps.has_cursor_shape = false;
        caps.supports_italic = false;
        caps.supports_underline_styles = false;
        caps.has_sgr_mouse = false;
        caps.has_focus_events = false;
        caps.confidence = .low;
    }

    // Conservative downgrade for multiplexers.
    if (caps.terminal_family == .tmux or caps.terminal_family == .screen) {
        if (caps.color_depth == .truecolor and !(containsCaseInsensitive(input.colorterm, "truecolor") or containsCaseInsensitive(input.colorterm, "24bit"))) {
            caps.color_depth = .ansi256;
        }
        caps.has_kitty_kbd_protocol = false;
        caps.confidence = .medium;
    }

    if (input.override_color_depth) |d| caps.color_depth = d;
    if (input.override_disable_italic) caps.supports_italic = false;
    if (input.override_disable_underline) caps.supports_underline_styles = false;
    if (input.override_disable_mouse) caps.has_sgr_mouse = false;
    if (input.override_disable_cursor_shape) caps.has_cursor_shape = false;
    if (input.override_force_focus_events) caps.has_focus_events = true;

    caps.supports_rgb_fg = caps.color_depth == .truecolor;
    caps.supports_rgb_bg = caps.color_depth == .truecolor;
    return caps;
}

pub fn detectWithRuntime(stdin_is_tty: bool, stdout_is_tty: bool) Capabilities {
    const term_program = env("TERM_PROGRAM") orelse "";
    return detectFromInput(.{
        .term = env("TERM") orelse "",
        .colorterm = env("COLORTERM") orelse "",
        .term_program = term_program,
        .has_tmux = env("TMUX") != null,
        .has_screen = env("STY") != null,
        .has_kitty = env("KITTY_WINDOW_ID") != null,
        .has_wt = env("WT_SESSION") != null,
        .has_vscode = env("VSCODE_GIT_IPC_HANDLE") != null or containsCaseInsensitive(term_program, "vscode"),
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
        .override_color_depth = parseColorDepthEnv(),
        .override_disable_italic = parseBoolEnv("VX_TUI_NO_ITALIC"),
        .override_disable_underline = parseBoolEnv("VX_TUI_NO_UNDERLINE"),
        .override_disable_mouse = parseBoolEnv("VX_TUI_DISABLE_MOUSE"),
        .override_disable_cursor_shape = parseBoolEnv("VX_TUI_DISABLE_CURSOR_SHAPE"),
        .override_force_focus_events = parseBoolEnv("VX_TUI_FORCE_FOCUS_EVENTS"),
    });
}

pub fn detect() Capabilities {
    // Fallback for call sites without runtime tty context.
    return detectWithRuntime(true, true);
}

test "phase1 profile: kitty truecolor" {
    const caps = detectFromInput(.{
        .term = "xterm-kitty",
        .colorterm = "truecolor",
        .term_program = "kitty",
        .has_kitty = true,
    });
    try std.testing.expectEqual(TerminalFamily.kitty, caps.terminal_family);
    try std.testing.expectEqual(ColorDepth.truecolor, caps.color_depth);
    try std.testing.expect(caps.has_kitty_kbd_protocol);
    try std.testing.expect(caps.supports_rgb_fg);
}

test "phase1 profile: wezterm under tmux stays conservative" {
    const caps = detectFromInput(.{
        .term = "tmux-256color",
        .colorterm = "",
        .term_program = "WezTerm",
        .has_tmux = true,
    });
    try std.testing.expectEqual(TerminalFamily.tmux, caps.terminal_family);
    try std.testing.expectEqual(ColorDepth.ansi256, caps.color_depth);
    try std.testing.expectEqual(Confidence.medium, caps.confidence);
    try std.testing.expect(!caps.has_kitty_kbd_protocol);
}

test "phase1 profile: kitty under tmux keeps tmux family" {
    const caps = detectFromInput(.{
        .term = "tmux-256color",
        .term_program = "kitty",
        .colorterm = "truecolor",
        .has_tmux = true,
        .has_kitty = true,
    });
    try std.testing.expectEqual(TerminalFamily.tmux, caps.terminal_family);
    try std.testing.expectEqual(Confidence.medium, caps.confidence);
    try std.testing.expect(!caps.has_kitty_kbd_protocol);
}

test "phase1 profile: iTerm2 under tmux keeps tmux family" {
    const caps = detectFromInput(.{
        .term = "tmux-256color",
        .term_program = "iTerm.app",
        .has_tmux = true,
    });
    try std.testing.expectEqual(TerminalFamily.tmux, caps.terminal_family);
    try std.testing.expectEqual(Confidence.medium, caps.confidence);
}

test "phase1 profile: windows terminal" {
    const caps = detectFromInput(.{
        .term = "xterm-256color",
        .has_wt = true,
    });
    try std.testing.expectEqual(TerminalFamily.windows_terminal, caps.terminal_family);
    try std.testing.expect(caps.has_focus_events);
}

test "runtime probe: non-tty output disables interactive features" {
    const caps = detectFromInput(.{
        .term = "xterm-256color",
        .stdout_is_tty = false,
    });
    try std.testing.expectEqual(ColorDepth.mono, caps.color_depth);
    try std.testing.expect(!caps.has_alt_screen);
    try std.testing.expect(!caps.has_cursor_shape);
    try std.testing.expect(!caps.has_sgr_mouse);
}

test "env overrides win over detection" {
    const caps = detectFromInput(.{
        .term = "xterm-kitty",
        .colorterm = "truecolor",
        .override_color_depth = .ansi16,
        .override_disable_italic = true,
        .override_disable_cursor_shape = true,
    });
    try std.testing.expectEqual(ColorDepth.ansi16, caps.color_depth);
    try std.testing.expect(!caps.supports_italic);
    try std.testing.expect(!caps.has_cursor_shape);
}

test "phase2 profile: alacritty detection" {
    const caps = detectFromInput(.{
        .term = "alacritty",
    });
    try std.testing.expectEqual(TerminalFamily.alacritty, caps.terminal_family);
    try std.testing.expectEqual(Confidence.high, caps.confidence);
}

test "phase2 profile: xterm 256color detection" {
    const caps = detectFromInput(.{
        .term = "xterm-256color",
    });
    try std.testing.expectEqual(TerminalFamily.xterm, caps.terminal_family);
    try std.testing.expectEqual(ColorDepth.ansi256, caps.color_depth);
}

test "phase2 profile: vscode terminal detection" {
    const caps = detectFromInput(.{
        .term = "xterm-256color",
        .term_program = "vscode",
        .has_vscode = true,
    });
    try std.testing.expectEqual(TerminalFamily.vscode, caps.terminal_family);
    try std.testing.expectEqual(Confidence.medium, caps.confidence);
    try std.testing.expect(!caps.has_alt_screen);
    try std.testing.expect(!caps.has_sgr_mouse);
    try std.testing.expect(!caps.has_bracketed_paste);
    try std.testing.expect(!caps.has_focus_events);
}

test "phase2 profile: linux console conservative fallback" {
    const caps = detectFromInput(.{
        .term = "linux",
    });
    try std.testing.expectEqual(TerminalFamily.linux_console, caps.terminal_family);
    try std.testing.expect(!caps.supports_italic);
    try std.testing.expect(!caps.has_cursor_shape);
}

test "phase2 profile: screen conservative fallback" {
    const caps = detectFromInput(.{
        .term = "screen-256color",
        .has_screen = true,
        .colorterm = "",
    });
    try std.testing.expectEqual(TerminalFamily.screen, caps.terminal_family);
    try std.testing.expectEqual(Confidence.medium, caps.confidence);
    try std.testing.expect(!caps.has_kitty_kbd_protocol);
}

test "unknown terminal defaults to conservative protocol set" {
    const caps = detectFromInput(.{
        .term = "weird-term",
        .colorterm = "",
    });
    try std.testing.expectEqual(TerminalFamily.unknown, caps.terminal_family);
    try std.testing.expect(!caps.has_sgr_mouse);
    try std.testing.expect(!caps.has_cursor_shape);
    try std.testing.expect(!caps.supports_italic);
}
