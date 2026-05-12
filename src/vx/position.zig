pub const Position = struct {
    row: usize = 0,
    col: usize = 0,

    pub fn init(row: usize, col: usize) @This() {
        return .{ .row = row, .col = col };
    }

    pub fn eql(a: @This(), b: @This()) bool {
        return a.row == b.row and a.col == b.col;
    }

    pub fn lessThan(a: @This(), b: @This()) bool {
        if (a.row != b.row) return a.row < b.row;
        return a.col < b.col;
    }
};
