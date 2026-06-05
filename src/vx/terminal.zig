// Backward-compat shim — actual implementation in src/nc/terminal.zig
const nc_terminal = @import("../nc/terminal.zig");
pub const Color         = nc_terminal.Color;
pub const STYLE_NONE    = nc_terminal.STYLE_NONE;
pub const STYLE_BOLD    = nc_terminal.STYLE_BOLD;
pub const STYLE_ITALIC  = nc_terminal.STYLE_ITALIC;
pub const STYLE_UNDERLINE = nc_terminal.STYLE_UNDERLINE;
pub const MouseEvent    = nc_terminal.MouseEvent;
pub const Event         = nc_terminal.Event;
pub const Terminal      = nc_terminal.Terminal;
pub const CursorStyle   = nc_terminal.CursorStyle;
pub const parseCursorStyle = nc_terminal.parseCursorStyle;
