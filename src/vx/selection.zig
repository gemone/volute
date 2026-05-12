const Position = @import("position.zig").Position;

pub const Selection = struct {
    anchor: Position,
    cursor: Position,

    pub fn init(pos: Position) @This() {
        return .{ .anchor = pos, .cursor = pos };
    }

    pub fn isCollapsed(self: @This()) bool {
        return self.anchor.eql(self.cursor);
    }

    pub fn start(self: @This()) Position {
        if (self.cursor.lessThan(self.anchor)) return self.cursor;
        return self.anchor;
    }

    pub fn end(self: @This()) Position {
        if (self.anchor.lessThan(self.cursor)) return self.cursor;
        return self.anchor;
    }
};
