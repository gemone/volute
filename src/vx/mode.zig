pub const Mode = enum {
    normal,
    insert,
    select_,

    pub fn toString(self: Mode) []const u8 {
        return switch (self) {
            .normal => "NORMAL",
            .insert => "INSERT",
            .select_ => "SELECT",
        };
    }
};
