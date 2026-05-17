const std = @import("std");

pub const TokenStyle = enum {
    normal,
    keyword,
    type_name,
    string,
    comment,
    number,
    builtin,
};
