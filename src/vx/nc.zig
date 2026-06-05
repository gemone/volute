// Backward-compat shim — actual implementation in src/nc/bindings.zig
const nc_bindings = @import("../nc/bindings.zig");
pub const c              = nc_bindings.c;
pub const MouseEvent     = nc_bindings.MouseEvent;
pub const Event          = nc_bindings.Event;
pub const ncinputToEvent = nc_bindings.ncinputToEvent;
pub const ncinputToKey   = nc_bindings.ncinputToKey;
pub const setFgRgb       = nc_bindings.setFgRgb;
pub const setFgDefault   = nc_bindings.setFgDefault;
pub const setBgDefault   = nc_bindings.setBgDefault;
pub const setStyles      = nc_bindings.setStyles;
pub const putStrYx       = nc_bindings.putStrYx;
pub const putNStr        = nc_bindings.putNStr;
