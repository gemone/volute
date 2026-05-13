const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Key = @import("key.zig").Key;
const Mode = @import("mode.zig").Mode;
const Position = @import("position.zig").Position;
const Selection = @import("selection.zig").Selection;
const Terminal = @import("terminal.zig").Terminal;
const CursorStyle = @import("terminal.zig").CursorStyle;
const keymap = @import("keymap.zig");
const Command = keymap.Command;
const SearchDirection = enum { forward, backward };
const SurroundPair = struct {
    open: u8,
    close: u8,
};

const SurroundMatch = struct {
    open_pos: Position,
    close_pos: Position,
    pair: SurroundPair,
};

pub const Editor = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    io: std.Io,
    terminal: Terminal,
    buffers: std.ArrayList(*Buffer),
    current_buf: usize,
    mode: Mode,
    cursor: Position,
    selection: ?Selection,
    scroll: usize,
    pending_keys: std.ArrayList(Key),
    pending_trie_name: []const u8,
    key_trie_root: keymap.KeyTrie,
    status_msg: ?[]const u8,
    command_buf: std.ArrayList(u8),
    in_command_mode: bool,
    in_numeric_prompt: bool,
    pending_numeric_command: ?Command,
    should_quit: bool,
    yank_text: ?[]const u8,
    search_pattern: ?[]const u8,
    in_char_pending: bool,
    pending_char_command: ?Command,
    last_find_char: ?u8,
    last_find_command: ?Command,
    in_search_mode: bool,
    search_direction: SearchDirection,
    search_start_cursor: Position,
    normal_cursor_style: CursorStyle,
    insert_cursor_style: CursorStyle,
    select_cursor_style: CursorStyle,
    last_render_buf: ?*Buffer,
    last_render_scroll: usize,
    last_render_rows: usize,
    last_render_cols: usize,
    last_render_cursor: Position,
    last_render_mode: Mode,
    last_render_selection: ?Selection,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        var terminal = try Terminal.init(io);
        errdefer terminal.deinit();

        return .{
            .allocator = allocator,
            .io = io,
            .terminal = terminal,
            .buffers = .empty,
            .current_buf = 0,
            .mode = .normal,
            .cursor = .{},
            .selection = null,
            .scroll = 0,
            .pending_keys = .empty,
            .pending_trie_name = "",
            .key_trie_root = keymap.normalKeymap(),
            .status_msg = null,
            .command_buf = .empty,
            .in_command_mode = false,
            .in_numeric_prompt = false,
            .pending_numeric_command = null,
            .should_quit = false,
            .yank_text = null,
            .search_pattern = null,
            .in_char_pending = false,
            .pending_char_command = null,
            .last_find_char = null,
            .last_find_command = null,
            .in_search_mode = false,
            .search_direction = .forward,
            .search_start_cursor = .{},
            .normal_cursor_style = .block,
            .insert_cursor_style = .beam,
            .select_cursor_style = .block,
            .last_render_buf = null,
            .last_render_scroll = 0,
            .last_render_rows = 0,
            .last_render_cols = 0,
            .last_render_cursor = .{},
            .last_render_mode = .normal,
            .last_render_selection = null,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buf| buf.deinit();
        self.buffers.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.command_buf.deinit(self.allocator);
        if (self.yank_text) |t| self.allocator.free(t);
        if (self.search_pattern) |p| self.allocator.free(p);
        if (self.status_msg) |m| self.allocator.free(m);
        self.terminal.deinit();
    }

    pub fn openFile(self: *Self, path: []const u8) !void {
        const buf = try Buffer.openFile(self.allocator, self.io, path);
        try self.buffers.append(self.allocator, buf);
        self.current_buf = self.buffers.items.len - 1;
        self.cursor = .{};
        self.scroll = 0;
    }

    fn openNewBuffer(self: *Self) !void {
        const buf = try Buffer.init(self.allocator);
        try self.buffers.append(self.allocator, buf);
        self.current_buf = self.buffers.items.len - 1;
        self.cursor = .{};
        self.scroll = 0;
    }

    pub fn getBuffer(self: Self) ?*Buffer {
        if (self.current_buf < self.buffers.items.len) return self.buffers.items[self.current_buf];
        return null;
    }

    pub fn handleKey(self: *Self, key: Key) !void {
        if (self.in_command_mode) {
            try self.handleCommandKey(key);
            return;
        }

        if (self.in_search_mode) {
            try self.handleSearchKey(key);
            return;
        }

        if (self.in_numeric_prompt) {
            try self.handleNumericPromptKey(key);
            return;
        }

        if (self.in_char_pending) {
            try self.handleCharPending(key);
            return;
        }

        self.clearStatus();

        switch (self.mode) {
            .insert => try self.handleInsertKey(key),
            .normal, .select_ => try self.handleNormalKey(key),
        }
    }

    pub fn insertTextBytes(self: *Self, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const buf = self.getBuffer() orelse return;
        const insert_pos = buf.clampPosInsert(self.cursor);
        try buf.insertBytesAt(insert_pos, bytes);
        self.cursor = advancePositionByBytes(insert_pos, bytes);
    }

    fn handleInsertKey(self: *Self, key: Key) !void {
        const buf = self.getBuffer() orelse return;

        if (key.eql(Key.init(.escape)) or key.eql(Key.initCtrl(.lower_c))) {
            self.setMode(.normal);
            if (self.cursor.col > 0) self.cursor.col = buf.prevColumn(self.cursor.row, self.cursor.col);
            self.cursor = buf.clampPos(self.cursor);
            return;
        }

        if (key.mod.ctrl or key.mod.alt) return;

        // Handle UTF-8 multi-byte sequences
        const utf8_bytes = key.getBytes();
        if (utf8_bytes.len > 0) {
            const insert_pos = buf.clampPosInsert(self.cursor);
            try buf.insertBytesAt(insert_pos, utf8_bytes);
            self.cursor.col += utf8_bytes.len;
            return;
        }

        const ch = key.char();
        if (ch) |c| {
            const insert_pos = buf.clampPosInsert(self.cursor);
            try buf.insertCharAt(insert_pos, c);
            self.cursor.col += 1;
            return;
        }

        switch (key.base) {
            .enter => {
                const insert_pos = buf.clampPosInsert(self.cursor);
                const indent = buf.getAutoIndent(insert_pos.row);

                // Insert newline followed by indent in one sequence
                try buf.insertNewlineAt(insert_pos);

                // Move cursor to new line and insert indent there
                self.cursor.row += 1;
                self.cursor.col = 0;

                // Insert indent at the beginning of the new line
                for (indent) |c| {
                    try buf.insertCharAt(self.cursor, c);
                    self.cursor.col += 1;
                }

                self.cursor = buf.clampPosInsert(self.cursor);
            },
            .backspace => {
                if (self.cursor.col > 0) {
                    const prev_col = buf.prevColumn(self.cursor.row, self.cursor.col);
                    _ = try buf.deleteCharAt(self.cursor);
                    self.cursor.col = prev_col;
                } else if (self.cursor.row > 0) {
                    const prev_len = buf.lineLen(self.cursor.row - 1);
                    _ = try buf.deleteCharAt(self.cursor);
                    self.cursor.row -= 1;
                    self.cursor.col = prev_len;
                }
            },
            .tab => {
                const insert_pos = buf.clampPosInsert(self.cursor);
                try buf.insertCharAt(insert_pos, ' ');
                self.cursor.col += 1;
                try buf.insertCharAt(buf.clampPosInsert(self.cursor), ' ');
                self.cursor.col += 1;
                try buf.insertCharAt(buf.clampPosInsert(self.cursor), ' ');
                self.cursor.col += 1;
                try buf.insertCharAt(buf.clampPosInsert(self.cursor), ' ');
                self.cursor.col += 1;
            },
            else => {
                try self.executeCommand(.no_op);
            },
        }
    }

    fn handleNormalKey(self: *Self, key: Key) !void {
        if (key.eql(Key.init(.escape))) {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
            self.setMode(.normal);
            self.selection = null;
            return;
        }

        try self.pending_keys.append(self.allocator, key);
        const result = keymap.lookup(&self.key_trie_root, self.pending_keys.items);

        if (result.command) |cmd| {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
            try self.executeCommand(cmd);
        } else if (!result.pending) {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
        } else {
            self.pending_trie_name = result.trie_name;
        }
    }

    fn handleCommandKey(self: *Self, key: Key) !void {
        switch (key.base) {
            .escape => {
                self.in_command_mode = false;
                self.command_buf.clearRetainingCapacity();
            },
            .enter => {
                self.in_command_mode = false;
                try self.executeCommandString(self.command_buf.items);
                self.command_buf.clearRetainingCapacity();
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                } else {
                    self.in_command_mode = false;
                }
            },
            else => {
                const ch = key.char();
                if (ch) |c| {
                    try self.command_buf.append(self.allocator, c);
                }
            },
        }
    }

    fn handleNumericPromptKey(self: *Self, key: Key) !void {
        switch (key.base) {
            .escape => {
                self.in_numeric_prompt = false;
                self.pending_numeric_command = null;
                self.command_buf.clearRetainingCapacity();
            },
            .enter => {
                try self.applyNumericPrompt();
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                } else {
                    self.in_numeric_prompt = false;
                    self.pending_numeric_command = null;
                }
            },
            else => {
                const ch = key.char() orelse return;
                if (ch < '0' or ch > '9') return;
                try self.command_buf.append(self.allocator, ch);
            },
        }
    }

    fn handleCharPending(self: *Self, key: Key) !void {
        const cmd = self.pending_char_command orelse {
            self.in_char_pending = false;
            return;
        };

        if (key.eql(Key.init(.escape))) {
            self.in_char_pending = false;
            self.pending_char_command = null;
            return;
        }

        const ch = key.char();
        if (ch == null) {
            self.in_char_pending = false;
            self.pending_char_command = null;
            return;
        }
        const target = ch.?;
        self.in_char_pending = false;
        self.pending_char_command = null;

        switch (cmd) {
            .find_next_char, .find_till_char, .find_prev_char, .till_prev_char => {
                self.last_find_char = target;
                self.last_find_command = cmd;
                try self.executeFindChar(cmd, target);
            },
            .surround_add => try self.applySurroundAdd(target),
            .surround_replace => try self.applySurroundReplace(target),
            .replace => {
                const buf = self.getBuffer() orelse return;
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                if (self.cursor.col < line.len) {
                    try buf.replaceCharAt(self.cursor.row, self.cursor.col, target);
                }
            },
            else => {},
        }
    }

    fn executeFindChar(self: *Self, cmd: Command, target: u8) !void {
        const buf = self.getBuffer() orelse return;
        const line = buf.getLine(self.cursor.row) orelse return;

        switch (cmd) {
            .find_next_char => {
                var col = self.cursor.col + 1;
                while (col < line.len) : (col += 1) {
                    if (line[col] == target) {
                        self.cursor.col = col;
                        return;
                    }
                }
            },
            .find_till_char => {
                var col = self.cursor.col + 1;
                while (col < line.len) : (col += 1) {
                    if (line[col] == target) {
                        self.cursor.col = col -| 1;
                        return;
                    }
                }
            },
            .find_prev_char => {
                if (self.cursor.col == 0) return;
                var col: usize = self.cursor.col - 1;
                while (true) : (col -= 1) {
                    if (line[col] == target) {
                        self.cursor.col = col;
                        return;
                    }
                    if (col == 0) break;
                }
            },
            .till_prev_char => {
                if (self.cursor.col <= 1) return;
                var col: usize = self.cursor.col - 1;
                while (true) : (col -= 1) {
                    if (line[col] == target) {
                        if (col + 1 < line.len) self.cursor.col = col + 1;
                        return;
                    }
                    if (col == 0) break;
                }
            },
            else => {},
        }
    }

    fn handleSearchKey(self: *Self, key: Key) !void {
        const buf = self.getBuffer() orelse {
            self.in_search_mode = false;
            return;
        };

        switch (key.base) {
            .escape => {
                self.in_search_mode = false;
                self.command_buf.clearRetainingCapacity();
                self.cursor = self.search_start_cursor;
            },
            .enter => {
                self.in_search_mode = false;
                if (self.command_buf.items.len > 0) {
                    if (self.search_pattern) |p| self.allocator.free(p);
                    self.search_pattern = try self.allocator.dupe(u8, self.command_buf.items);
                }
                self.command_buf.clearRetainingCapacity();
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                    if (self.command_buf.items.len > 0) {
                        self.searchJump(buf, self.command_buf.items);
                    } else {
                        self.cursor = self.search_start_cursor;
                    }
                } else {
                    self.in_search_mode = false;
                }
            },
            else => {
                const ch = key.char();
                if (ch) |c| {
                    try self.command_buf.append(self.allocator, c);
                    self.searchJump(buf, self.command_buf.items);
                }
            },
        }
    }

    fn searchJump(self: *Self, buf: *Buffer, pattern: []const u8) void {
        if (pattern.len == 0) return;
        const start = if (self.in_search_mode) self.search_start_cursor else self.cursor;
        if (searchBuffer(buf, pattern, start, self.search_direction, true)) |pos| {
            self.cursor = pos;
        }
    }

    fn executeCommandString(self: *Self, cmd: []const u8) !void {
        if (std.mem.eql(u8, cmd, "w") or std.mem.eql(u8, cmd, "write")) {
            try self.executeCommand(.save);
        } else if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
            try self.executeCommand(.quit);
        } else if (std.mem.eql(u8, cmd, "q!") or std.mem.eql(u8, cmd, "quit!")) {
            try self.executeCommand(.force_quit);
        } else if (std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x")) {
            try self.executeCommand(.save);
            try self.executeCommand(.quit);
        } else if (std.mem.startsWith(u8, cmd, "o ") or std.mem.startsWith(u8, cmd, "open ")) {
            const path_start: usize = if (cmd.len > 1 and cmd[1] == ' ') 2 else 5;
            if (cmd.len > path_start) {
                const path = std.mem.trim(u8, cmd[path_start..], " ");
                try self.openFile(path);
                self.setStatus("Opened: {s}", .{path});
            }
        } else if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "new")) {
            try self.openNewBuffer();
        } else if (std.mem.eql(u8, cmd, "bn") or std.mem.eql(u8, cmd, "bnext")) {
            try self.executeCommand(.buffer_next);
        } else if (std.mem.eql(u8, cmd, "bp") or std.mem.eql(u8, cmd, "bprev")) {
            try self.executeCommand(.buffer_prev);
        } else {
            self.setStatus("Unknown command: {s}", .{cmd});
        }
    }

    fn clearStatus(self: *Self) void {
        if (self.status_msg) |msg| self.allocator.free(msg);
        self.status_msg = null;
    }

    fn setStatus(self: *Self, comptime fmt: []const u8, args: anytype) void {
        self.clearStatus();
        self.status_msg = std.fmt.allocPrint(self.allocator, fmt, args) catch null;
    }

    fn setStatusText(self: *Self, text: []const u8) void {
        self.clearStatus();
        self.status_msg = self.allocator.dupe(u8, text) catch null;
    }

    fn setMode(self: *Self, mode: Mode) void {
        self.mode = mode;
        self.key_trie_root = switch (mode) {
            .normal => keymap.normalKeymap(),
            .insert => keymap.insertKeymap(),
            .select_ => keymap.selectKeymap(),
        };
    }

    pub fn cursorStyleForMode(self: *const Self, mode: Mode) CursorStyle {
        return switch (mode) {
            .normal => self.normal_cursor_style,
            .insert => self.insert_cursor_style,
            .select_ => self.select_cursor_style,
        };
    }

    fn beginNumericPrompt(self: *Self, cmd: Command) void {
        self.in_numeric_prompt = true;
        self.pending_numeric_command = cmd;
        self.command_buf.clearRetainingCapacity();
    }

    fn applyNumericPrompt(self: *Self) !void {
        const buf = self.getBuffer() orelse return;
        const cmd = self.pending_numeric_command orelse return;
        defer {
            self.in_numeric_prompt = false;
            self.pending_numeric_command = null;
            self.command_buf.clearRetainingCapacity();
        }

        if (self.command_buf.items.len == 0) return;

        const value = std.fmt.parseUnsigned(usize, self.command_buf.items, 10) catch {
            self.setStatusText("Expected a numeric target");
            return;
        };
        const one_based = if (value > 0) value - 1 else 0;

        switch (cmd) {
            .goto_line => {
                self.cursor.row = @min(one_based, buf.lineCount() -| 1);
                self.cursor = buf.clampPos(self.cursor);
            },
            .goto_column => {
                self.cursor.col = one_based;
                self.cursor = if (self.mode == .insert) buf.clampPosInsert(self.cursor) else buf.clampPos(self.cursor);
            },
            else => {},
        }
    }

    fn selectedLineRange(self: *const Self) struct { start: usize, end: usize } {
        if (self.selection) |sel| {
            const start = sel.start().row;
            const end = sel.end().row;
            return .{ .start = start, .end = end };
        }
        return .{ .start = self.cursor.row, .end = self.cursor.row };
    }

    fn selectedTextRange(self: *const Self, buf: *Buffer) struct { start: Position, end: Position } {
        if (self.selection) |sel| {
            const start = sel.start();
            var end = sel.end();
            const line_len = buf.lineLen(end.row);
            if (!sel.isCollapsed() and end.col < line_len) {
                end.col += 1;
            }
            return .{ .start = start, .end = buf.clampPosInsert(end) };
        }

        const line = buf.getLine(self.cursor.row) orelse "";
        if (line.len == 0) {
            return .{ .start = self.cursor, .end = self.cursor };
        }

        var pivot = self.cursor.col;
        if (pivot >= line.len and pivot > 0) pivot -= 1;
        if (pivot < line.len and isWordChar(line[pivot])) {
            var start_col = pivot;
            var end_col = pivot + 1;
            while (start_col > 0 and isWordChar(line[start_col - 1])) : (start_col -= 1) {}
            while (end_col < line.len and isWordChar(line[end_col])) : (end_col += 1) {}
            return .{
                .start = .{ .row = self.cursor.row, .col = start_col },
                .end = .{ .row = self.cursor.row, .col = end_col },
            };
        }

        if (self.cursor.col < line.len) {
            return .{
                .start = self.cursor,
                .end = .{ .row = self.cursor.row, .col = self.cursor.col + 1 },
            };
        }

        return .{
            .start = .{ .row = self.cursor.row, .col = self.cursor.col -| 1 },
            .end = self.cursor,
        };
    }

    fn applySurroundAdd(self: *Self, target: u8) !void {
        const buf = self.getBuffer() orelse return;
        const pair = surroundPairFor(target) orelse {
            self.setStatus("Unsupported surround: {c}", .{target});
            return;
        };
        const range = self.selectedTextRange(buf);
        try buf.pushUndo(self.cursor);
        try buf.insertCharAt(buf.clampPosInsert(range.end), pair.close);
        try buf.insertCharAt(buf.clampPosInsert(range.start), pair.open);
        self.cursor = buf.clampPos(.{ .row = range.start.row, .col = range.start.col + 1 });
    }

    fn applySurroundReplace(self: *Self, target: u8) !void {
        const buf = self.getBuffer() orelse return;
        const pair = surroundPairFor(target) orelse {
            self.setStatus("Unsupported surround: {c}", .{target});
            return;
        };
        const match = self.findSurroundMatch(buf) orelse {
            self.setStatusText("No surrounding delimiters found");
            return;
        };
        try buf.pushUndo(self.cursor);
        try buf.replaceCharAt(match.open_pos.row, match.open_pos.col, pair.open);
        try buf.replaceCharAt(match.close_pos.row, match.close_pos.col, pair.close);
    }

    fn applySurroundDelete(self: *Self) !void {
        const buf = self.getBuffer() orelse return;
        const match = self.findSurroundMatch(buf) orelse {
            self.setStatusText("No surrounding delimiters found");
            return;
        };
        try buf.pushUndo(self.cursor);
        _ = try buf.deleteCharAt(.{ .row = match.close_pos.row, .col = match.close_pos.col + 1 });
        _ = try buf.deleteCharAt(.{ .row = match.open_pos.row, .col = match.open_pos.col + 1 });
        self.cursor = buf.clampPos(match.open_pos);
    }

    fn findSurroundMatch(self: *const Self, buf: *Buffer) ?SurroundMatch {
        if (self.selection) |sel| {
            if (!sel.isCollapsed()) {
                const start = sel.start();
                const end = self.selectedTextRange(buf).end;
                if (start.col > 0) {
                    const open_pos = Position{ .row = start.row, .col = start.col - 1 };
                    const close_pos = end;
                    if (charAt(buf, open_pos)) |open_ch| {
                        if (charAt(buf, close_pos)) |close_ch| {
                            if (surroundPairFor(open_ch)) |pair| {
                                if (pair.close == close_ch) {
                                    return .{ .open_pos = open_pos, .close_pos = close_pos, .pair = pair };
                                }
                            }
                        }
                    }
                }
            }
        }

        if (findBracketMatchAtOrBefore(buf, self.cursor)) |match| return match;

        const line = buf.getLine(self.cursor.row) orelse return null;
        if (self.cursor.col > 0 and self.cursor.col < line.len) {
            const left_pos = Position{ .row = self.cursor.row, .col = self.cursor.col - 1 };
            const right_pos = Position{ .row = self.cursor.row, .col = self.cursor.col };
            if (charAt(buf, left_pos)) |open_ch| {
                if (charAt(buf, right_pos)) |close_ch| {
                    if (surroundPairFor(open_ch)) |pair| {
                        if (pair.close == close_ch) {
                            return .{ .open_pos = left_pos, .close_pos = right_pos, .pair = pair };
                        }
                    }
                }
            }
        }

        return null;
    }

    fn deleteSelection(self: *Self, yank: bool) !void {
        const buf = self.getBuffer() orelse return;

        try buf.pushUndo(self.cursor);
        const line = buf.getLine(self.cursor.row) orelse return;
        if (line.len > 0) {
            const ch = buf.charSliceAt(self.cursor) orelse return;
            if (yank) {
                if (self.yank_text) |t| self.allocator.free(t);
                self.yank_text = try self.allocator.dupe(u8, ch);
            }
            _ = try buf.deleteCharAt(.{ .row = self.cursor.row, .col = self.cursor.col + 1 });
            self.cursor = buf.clampPos(self.cursor);
        } else if (buf.lineCount() > 1) {
            if (yank) {
                if (self.yank_text) |t| self.allocator.free(t);
                self.yank_text = try self.allocator.dupe(u8, "\n");
            }
            try buf.deleteLine(self.cursor.row);
            self.cursor = buf.clampPos(self.cursor);
        }
    }

    fn executeCommand(self: *Self, cmd: Command) !void {
        const buf = self.getBuffer() orelse return;

        switch (cmd) {
            .move_char_left => {
                if (self.cursor.col > 0) self.cursor.col = buf.prevColumn(self.cursor.row, self.cursor.col);
            },
            .move_char_right => {
                const line_len = buf.lineLen(self.cursor.row);
                if (self.cursor.col < line_len) self.cursor.col = buf.nextColumn(self.cursor.row, self.cursor.col);
                if (self.mode == .normal and self.cursor.col >= line_len) self.cursor.col = normalLineEndCol(buf, self.cursor.row);
            },
            .move_visual_line_down, .move_line_down => {
                if (self.cursor.row < buf.lineCount() -| 1) {
                    self.cursor.row += 1;
                    self.cursor = buf.clampPos(self.cursor);
                }
            },
            .move_visual_line_up, .move_line_up => {
                if (self.cursor.row > 0) {
                    self.cursor.row -= 1;
                    self.cursor = buf.clampPos(self.cursor);
                }
            },
            .move_next_word_start => {
                const line = buf.getLine(self.cursor.row) orelse "";
                var col = self.cursor.col;
                while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                while (col < line.len and isWordChar(line[col])) : (col += 1) {}
                while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                if (col >= line.len and self.cursor.row < buf.lineCount() -| 1) {
                    self.cursor.row += 1;
                    self.cursor.col = 0;
                    const next = buf.getLine(self.cursor.row) orelse "";
                    while (self.cursor.col < next.len and next[self.cursor.col] == ' ') : (self.cursor.col += 1) {}
                } else {
                    self.cursor.col = if (col >= line.len) normalLineEndCol(buf, self.cursor.row) else col;
                }
            },
            .move_prev_word_start => {
                const line = buf.getLine(self.cursor.row) orelse "";
                if (self.cursor.col == 0) {
                    if (self.cursor.row > 0) {
                        self.cursor.row -= 1;
                        self.cursor.col = normalLineEndCol(buf, self.cursor.row);
                    }
                } else {
                    var col = self.cursor.col;
                    while (col > 0 and !isWordChar(line[col - 1])) : (col -= 1) {}
                    while (col > 0 and isWordChar(line[col - 1])) : (col -= 1) {}
                    self.cursor.col = col;
                }
            },
            .move_next_word_end => {
                const line = buf.getLine(self.cursor.row) orelse "";
                var col = self.cursor.col + 1;
                while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                while (col < line.len and isWordChar(line[col])) : (col += 1) {}
                self.cursor.col = if (col == 0) 0 else if (col >= line.len) normalLineEndCol(buf, self.cursor.row) else buf.prevColumn(self.cursor.row, col);
            },
            .move_next_long_word_start, .move_prev_long_word_start, .move_next_long_word_end => {
                try self.executeCommand(switch (cmd) {
                    .move_next_long_word_start => .move_next_word_start,
                    .move_prev_long_word_start => .move_prev_word_start,
                    .move_next_long_word_end => .move_next_word_end,
                    else => .no_op,
                });
            },
            .goto_line_start => self.cursor.col = 0,
            .goto_line_end => {
                self.cursor.col = normalLineEndCol(buf, self.cursor.row);
            },
            .goto_first_nonwhitespace => {
                const line = buf.getLine(self.cursor.row) orelse "";
                var col: usize = 0;
                while (col < line.len and (line[col] == ' ' or line[col] == '\t')) : (col += 1) {}
                self.cursor.col = if (col < line.len) col else if (line.len > 0) line.len - 1 else @as(usize, 0);
            },
            .goto_file_start => {
                self.cursor = .{};
                self.scroll = 0;
            },
            .goto_last_line => {
                self.cursor.row = buf.lineCount() -| 1;
                self.cursor = buf.clampPos(self.cursor);
            },
            .goto_line => self.beginNumericPrompt(.goto_line),
            .goto_column => self.beginNumericPrompt(.goto_column),
            .goto_window_top => {
                self.cursor.row = self.scroll;
                self.cursor = buf.clampPos(self.cursor);
            },
            .goto_window_center => {
                self.cursor.row = self.scroll + (self.terminal.size.rows - 2) / 2;
                self.cursor = buf.clampPos(self.cursor);
            },
            .goto_window_bottom => {
                self.cursor.row = self.scroll + self.terminal.size.rows - 3;
                self.cursor = buf.clampPos(self.cursor);
            },

            .insert_mode => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                self.cursor = buf.clampPosInsert(self.cursor);
            },
            .insert_at_line_start => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                self.cursor.col = 0;
            },
            .insert_at_line_end => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                self.cursor.col = buf.lineLen(self.cursor.row);
            },
            .append_mode => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                if (buf.lineLen(self.cursor.row) > 0) self.cursor.col = buf.nextColumn(self.cursor.row, self.cursor.col);
                self.cursor = buf.clampPosInsert(self.cursor);
            },
            .open_below_with_indent => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                const indent = buf.getAutoIndent(self.cursor.row);
                try buf.insertLine(self.cursor.row + 1, indent);
                self.cursor.row += 1;
                self.cursor.col = indent.len;
                self.cursor = buf.clampPosInsert(self.cursor);
            },
            .open_above_with_indent => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                const indent = buf.getAutoIndent(self.cursor.row);
                try buf.insertLine(self.cursor.row, indent);
                self.cursor.col = indent.len;
                self.cursor = buf.clampPosInsert(self.cursor);
            },
            .open_below => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                try buf.insertLine(self.cursor.row + 1, "");
                self.cursor.row += 1;
                self.cursor.col = 0;
            },
            .open_above => {
                try buf.pushUndo(self.cursor);
                self.setMode(.insert);
                try buf.insertLine(self.cursor.row, "");
                self.cursor.col = 0;
            },
            .normal_mode => {
                self.setMode(.normal);
                self.selection = null;
                self.cursor = buf.clampPos(self.cursor);
                if (self.cursor.col >= buf.lineLen(self.cursor.row)) self.cursor.col = normalLineEndCol(buf, self.cursor.row);
            },
            .select_mode => {
                self.setMode(.select_);
                self.selection = Selection.init(self.cursor);
            },

            .delete_selection => try self.deleteSelection(true),
            .delete_selection_noyank => try self.deleteSelection(false),
            .change_selection => {
                try buf.pushUndo(self.cursor);
                try self.executeCommand(.delete_selection);
                try self.executeCommand(.insert_mode);
            },
            .change_selection_noyank => {
                try buf.pushUndo(self.cursor);
                try self.executeCommand(.delete_selection_noyank);
                try self.executeCommand(.insert_mode);
            },
            .yank => {
                const line = buf.getLine(self.cursor.row) orelse return;
                if (self.yank_text) |t| self.allocator.free(t);
                if (line.len > 0 and self.cursor.col < line.len) {
                    const ch = buf.charSliceAt(self.cursor) orelse return;
                    self.yank_text = try self.allocator.dupe(u8, ch);
                } else {
                    self.yank_text = try self.allocator.dupe(u8, line);
                }
            },
            .paste_after => {
                try buf.pushUndo(self.cursor);
                if (self.yank_text) |text| {
                    const insert_pos = buf.clampPosInsert(self.cursor);
                    try buf.insertBytesAt(insert_pos, text);
                    self.cursor = advancePositionByBytes(insert_pos, text);
                }
            },
            .paste_before => {
                try buf.pushUndo(self.cursor);
                if (self.yank_text != null) {
                    if (self.cursor.col > 0) self.cursor.col = buf.prevColumn(self.cursor.row, self.cursor.col);
                    try self.executeCommand(.paste_after);
                    if (self.cursor.col > 0) self.cursor.col = buf.prevColumn(self.cursor.row, self.cursor.col);
                }
            },
            .undo => {
                if (try buf.undo(self.cursor)) |pos| {
                    self.cursor = pos;
                }
            },
            .redo => {
                if (try buf.redo(self.cursor)) |pos| {
                    self.cursor = pos;
                }
            },
            .earlier => self.setStatusText("Earlier history is not available in this editor yet"),
            .later => self.setStatusText("Later history is not available in this editor yet"),
            .find_till_char, .find_next_char, .till_prev_char, .find_prev_char => {
                self.in_char_pending = true;
                self.pending_char_command = cmd;
            },
            .repeat_last_motion => {
                if (self.last_find_char) |target| {
                    if (self.last_find_command) |find_cmd| {
                        try self.executeFindChar(find_cmd, target);
                    }
                }
            },
            .replace => {
                self.in_char_pending = true;
                self.pending_char_command = .replace;
            },
            .replace_with_yanked => {
                try buf.pushUndo(self.cursor);
                if (self.yank_text) |text| {
                    const replacement = leadingUtf8Char(text);
                    if (replacement.len > 0 and replacement[0] != '\n') {
                        try buf.replaceBytesAt(self.cursor.row, self.cursor.col, replacement);
                    }
                }
            },
            .switch_case => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                if (self.cursor.col < line.len) {
                    const ch = line[self.cursor.col];
                    const new_ch = if (ch >= 'a' and ch <= 'z') ch - 32 else if (ch >= 'A' and ch <= 'Z') ch + 32 else ch;
                    try buf.replaceCharAt(self.cursor.row, self.cursor.col, new_ch);
                }
            },
            .switch_to_lowercase => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                if (self.cursor.col < line.len) {
                    const ch = line[self.cursor.col];
                    if (ch >= 'A' and ch <= 'Z') try buf.replaceCharAt(self.cursor.row, self.cursor.col, ch + 32);
                }
            },
            .switch_to_uppercase => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                if (self.cursor.col < line.len) {
                    const ch = line[self.cursor.col];
                    if (ch >= 'a' and ch <= 'z') try buf.replaceCharAt(self.cursor.row, self.cursor.col, ch - 32);
                }
            },
            .extend_line_below => {
                self.selection = Selection{
                    .anchor = self.cursor,
                    .cursor = .{ .row = @min(self.cursor.row + 1, buf.lineCount() -| 1), .col = self.cursor.col },
                };
                self.cursor = self.selection.?.cursor;
            },
            .extend_to_line_bounds => {
                const rows = self.selectedLineRange();
                self.selection = .{
                    .anchor = .{ .row = rows.start, .col = 0 },
                    .cursor = .{ .row = rows.end, .col = buf.lineLen(rows.end) },
                };
                self.cursor = self.selection.?.cursor;
            },
            .select_all => {
                const last_row = buf.lineCount() -| 1;
                self.selection = Selection{ .anchor = .{}, .cursor = .{ .row = last_row, .col = buf.lineLen(last_row) } };
                self.cursor = self.selection.?.cursor;
            },
            .collapse_selection => self.selection = null,
            .flip_selections => {
                if (self.selection) |sel| {
                    self.cursor = sel.anchor;
                    self.selection = Selection{ .anchor = sel.cursor, .cursor = sel.anchor };
                }
            },
            .copy_selection_on_next_line => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                try buf.insertLine(self.cursor.row + 1, line);
                self.cursor.row += 1;
            },
            .copy_selection_on_prev_line => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                try buf.insertLine(self.cursor.row, line);
            },
            .keep_primary_selection => self.setStatusText("Primary selection filtering needs multi-selection support"),
            .remove_primary_selection => self.setStatusText("Primary selection removal needs multi-selection support"),
            .search => {
                self.in_search_mode = true;
                self.search_direction = .forward;
                self.search_start_cursor = self.cursor;
                self.command_buf.clearRetainingCapacity();
            },
            .rsearch => {
                self.in_search_mode = true;
                self.search_direction = .backward;
                self.search_start_cursor = self.cursor;
                self.command_buf.clearRetainingCapacity();
            },
            .search_next => {
                if (self.search_pattern) |pattern| {
                    if (pattern.len > 0) {
                        const start = advanceSearchPosition(buf, self.cursor, self.search_direction) orelse self.cursor;
                        if (searchBuffer(buf, pattern, start, self.search_direction, false)) |pos| {
                            self.cursor = pos;
                        }
                    }
                }
            },
            .search_prev => {
                if (self.search_pattern) |pattern| {
                    if (pattern.len > 0) {
                        const direction: SearchDirection = if (self.search_direction == .forward) .backward else .forward;
                        const start = advanceSearchPosition(buf, self.cursor, direction) orelse self.cursor;
                        if (searchBuffer(buf, pattern, start, direction, false)) |pos| {
                            self.cursor = pos;
                        }
                    }
                }
            },
            .match_brackets => {
                if (findBracketMatchAtOrBefore(buf, self.cursor)) |match| {
                    if (match.open_pos.eql(self.cursor)) {
                        self.cursor = match.close_pos;
                    } else if (match.close_pos.eql(self.cursor)) {
                        self.cursor = match.open_pos;
                    } else if (match.open_pos.lessThan(self.cursor)) {
                        self.cursor = match.close_pos;
                    } else {
                        self.cursor = match.open_pos;
                    }
                } else {
                    self.setStatusText("No matching bracket found");
                }
            },
            .surround_add, .surround_replace => {
                self.in_char_pending = true;
                self.pending_char_command = cmd;
            },
            .surround_delete => try self.applySurroundDelete(),
            .indent => {
                try buf.pushUndo(self.cursor);
                try buf.replaceLinePrefix(self.cursor.row, "    ", 0);
                self.cursor.col += 4;
            },
            .unindent => {
                try buf.pushUndo(self.cursor);
                const line = buf.getLine(self.cursor.row) orelse return;
                var remove: usize = 0;
                while (remove < 4 and remove < line.len and line[remove] == ' ') : (remove += 1) {}
                if (remove > 0) {
                    try buf.setLine(self.cursor.row, line[remove..]);
                    self.cursor.col = self.cursor.col -| remove;
                }
            },
            .format_selections => {
                const rows = self.selectedLineRange();
                var changed = false;
                try buf.pushUndo(self.cursor);
                var row = rows.start;
                while (row <= rows.end) : (row += 1) {
                    const line = buf.getLine(row) orelse continue;
                    var end = line.len;
                    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
                    if (end != line.len) {
                        try buf.setLine(row, line[0..end]);
                        changed = true;
                        if (self.cursor.row == row and self.cursor.col > end) {
                            self.cursor.col = end;
                        }
                    }
                }
                if (changed) {
                    self.setStatus("Formatted {d} line{s}", .{ rows.end - rows.start + 1, if (rows.end == rows.start) "" else "s" });
                } else {
                    self.setStatusText("Nothing to format");
                }
            },
            .join_selections => {
                try buf.pushUndo(self.cursor);
                if (self.cursor.row < buf.lineCount() -| 1) {
                    try buf.joinLines(self.cursor.row, self.allocator);
                }
            },
            .page_up => {
                const page_size = self.terminal.size.rows - 2;
                self.scroll = self.scroll -| page_size;
                self.cursor.row = self.scroll;
                self.cursor = buf.clampPos(self.cursor);
            },
            .page_down => {
                const page_size = self.terminal.size.rows - 2;
                self.scroll += page_size;
                self.cursor.row = @min(self.scroll + page_size - 1, buf.lineCount() -| 1);
                self.cursor = buf.clampPos(self.cursor);
            },
            .page_cursor_half_up => {
                const half = (self.terminal.size.rows - 2) / 2;
                self.cursor.row = if (self.cursor.row >= half) self.cursor.row - half else 0;
                self.cursor = buf.clampPos(self.cursor);
            },
            .page_cursor_half_down => {
                const half = (self.terminal.size.rows - 2) / 2;
                self.cursor.row = @min(self.cursor.row + half, buf.lineCount() -| 1);
                self.cursor = buf.clampPos(self.cursor);
            },
            .rotate_view => self.setStatusText("Only one view is available in the current editor architecture"),
            .hsplit, .vsplit => self.setStatusText("Split views are not available in the current editor architecture"),
            .wclose => self.setStatusText("There is only one view to close"),
            .command_mode => {
                self.in_command_mode = true;
                self.command_buf.clearRetainingCapacity();
            },
            .save => {
                buf.save(self.io) catch |err| {
                    self.setStatus("Error saving: {any}", .{err});
                    return;
                };
                self.setStatus("Saved: {s}", .{buf.path orelse "[unnamed]"});
            },
            .quit => {
                const b = self.getBuffer() orelse {
                    self.should_quit = true;
                    return;
                };
                if (b.dirty) {
                    self.setStatusText("Unsaved changes! Use :q! to force quit");
                    return;
                }
                self.should_quit = true;
            },
            .force_quit => self.should_quit = true,
            .open_file => {
                self.in_command_mode = true;
                try self.command_buf.appendSlice(self.allocator, "o ");
            },
            .new_file => try self.openNewBuffer(),
            .buffer_next => {
                if (self.buffers.items.len > 1) {
                    self.current_buf = (self.current_buf + 1) % self.buffers.items.len;
                    self.cursor = .{};
                    self.scroll = 0;
                }
            },
            .buffer_prev => {
                if (self.buffers.items.len > 1) {
                    self.current_buf = if (self.current_buf > 0) self.current_buf - 1 else self.buffers.items.len - 1;
                    self.cursor = .{};
                    self.scroll = 0;
                }
            },
            .no_op => {},
        }

        if (self.mode == .select_) {
            if (self.selection) |sel| {
                self.selection = .{ .anchor = sel.anchor, .cursor = self.cursor };
            }
        }

        self.adjustScroll();
    }

    fn adjustScroll(self: *Self) void {
        const visible_rows = self.terminal.size.rows - 2;
        if (self.cursor.row < self.scroll) {
            self.scroll = self.cursor.row;
        } else if (self.cursor.row >= self.scroll + visible_rows) {
            self.scroll = self.cursor.row - visible_rows + 1;
        }
    }
};

fn searchBuffer(buf: *Buffer, pattern: []const u8, start: Position, direction: SearchDirection, skip_current: bool) ?Position {
    return switch (direction) {
        .forward => searchForward(buf, pattern, start, skip_current),
        .backward => searchBackward(buf, pattern, start, skip_current),
    };
}

fn searchForward(buf: *Buffer, pattern: []const u8, start: Position, skip_current: bool) ?Position {
    if (buf.lineCount() == 0 or pattern.len == 0) return null;

    var row = start.row;
    while (row < buf.lineCount()) : (row += 1) {
        const line = buf.getLine(row) orelse continue;
        const col = if (row == start.row)
            @min(start.col + @intFromBool(skip_current), line.len)
        else
            0;
        if (col <= line.len) {
            if (std.mem.indexOf(u8, line[col..], pattern)) |idx| {
                return .{ .row = row, .col = col + idx };
            }
        }
    }

    row = 0;
    while (row <= @min(start.row, buf.lineCount() -| 1)) : (row += 1) {
        const line = buf.getLine(row) orelse continue;
        const limit = if (row == start.row)
            @min(start.col + @intFromBool(skip_current), line.len)
        else
            line.len;
        if (std.mem.indexOf(u8, line[0..limit], pattern)) |idx| {
            return .{ .row = row, .col = idx };
        }
    }

    return null;
}

fn searchBackward(buf: *Buffer, pattern: []const u8, start: Position, skip_current: bool) ?Position {
    if (buf.lineCount() == 0 or pattern.len == 0) return null;

    var row = @min(start.row, buf.lineCount() -| 1);
    while (true) {
        const line = buf.getLine(row) orelse "";
        const limit = if (row == start.row)
            @min(start.col + @intFromBool(!skip_current), line.len)
        else
            line.len;
        if (lastIndexOfPattern(line[0..limit], pattern)) |idx| {
            return .{ .row = row, .col = idx };
        }
        if (row == 0) break;
        row -= 1;
    }

    row = buf.lineCount() -| 1;
    while (row > start.row) : (row -= 1) {
        const line = buf.getLine(row) orelse continue;
        if (lastIndexOfPattern(line, pattern)) |idx| {
            return .{ .row = row, .col = idx };
        }
    }

    return null;
}

fn lastIndexOfPattern(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var idx = haystack.len - needle.len;
    while (true) {
        if (std.mem.eql(u8, haystack[idx .. idx + needle.len], needle)) return idx;
        if (idx == 0) break;
        idx -= 1;
    }
    return null;
}

fn advanceSearchPosition(buf: *Buffer, pos: Position, direction: SearchDirection) ?Position {
    const line = buf.getLine(pos.row) orelse return null;
    return switch (direction) {
        .forward => {
            if (pos.col < line.len) return .{ .row = pos.row, .col = buf.nextColumn(pos.row, pos.col) };
            if (pos.row + 1 < buf.lineCount()) return .{ .row = pos.row + 1, .col = 0 };
            return .{ .row = 0, .col = 0 };
        },
        .backward => {
            if (pos.col > 0) return .{ .row = pos.row, .col = buf.prevColumn(pos.row, pos.col) };
            if (pos.row > 0) {
                const prev_row = pos.row - 1;
                return .{ .row = prev_row, .col = buf.lineLen(prev_row) };
            }
            const last_row = buf.lineCount() -| 1;
            return .{ .row = last_row, .col = buf.lineLen(last_row) };
        },
    };
}

fn surroundPairFor(ch: u8) ?SurroundPair {
    return switch (ch) {
        '(' => .{ .open = '(', .close = ')' },
        '[' => .{ .open = '[', .close = ']' },
        '{' => .{ .open = '{', .close = '}' },
        '<' => .{ .open = '<', .close = '>' },
        ')', ']', '}', '>' => {
            const pair = surroundPairFor(matchingOpenBracket(ch) orelse return null) orelse return null;
            return pair;
        },
        '\'', '"', '`' => .{ .open = ch, .close = ch },
        else => null,
    };
}

fn matchingOpenBracket(ch: u8) ?u8 {
    return switch (ch) {
        ')' => '(',
        ']' => '[',
        '}' => '{',
        '>' => '<',
        else => null,
    };
}

fn charAt(buf: *Buffer, pos: Position) ?u8 {
    const line = buf.getLine(pos.row) orelse return null;
    if (pos.col >= line.len) return null;
    return line[pos.col];
}

fn findBracketMatchAtOrBefore(buf: *Buffer, cursor: Position) ?SurroundMatch {
    if (findBracketMatchAt(buf, cursor)) |match| return match;
    if (cursor.col > 0) {
        return findBracketMatchAt(buf, .{ .row = cursor.row, .col = cursor.col - 1 });
    }
    return null;
}

fn findBracketMatchAt(buf: *Buffer, pos: Position) ?SurroundMatch {
    const ch = charAt(buf, pos) orelse return null;
    if (surroundPairFor(ch)) |pair| {
        if (ch == pair.open) {
            const close_pos = findMatchingDelimiter(buf, pos, pair, .forward) orelse return null;
            return .{ .open_pos = pos, .close_pos = close_pos, .pair = pair };
        }
        if (ch == pair.close) {
            const open_pos = findMatchingDelimiter(buf, pos, pair, .backward) orelse return null;
            return .{ .open_pos = open_pos, .close_pos = pos, .pair = pair };
        }
    }
    return null;
}

fn findMatchingDelimiter(buf: *Buffer, pos: Position, pair: SurroundPair, direction: SearchDirection) ?Position {
    if (pair.open == pair.close) {
        return findMatchingQuote(buf, pos, pair.open, direction);
    }

    var depth: usize = 0;
    switch (direction) {
        .forward => {
            var row = pos.row;
            while (row < buf.lineCount()) : (row += 1) {
                const line = buf.getLine(row) orelse continue;
                var col = if (row == pos.row) pos.col + 1 else 0;
                while (col < line.len) : (col += 1) {
                    if (line[col] == pair.open) {
                        depth += 1;
                    } else if (line[col] == pair.close) {
                        if (depth == 0) return .{ .row = row, .col = col };
                        depth -= 1;
                    }
                }
            }
        },
        .backward => {
            var row = pos.row;
            while (true) {
                const line = buf.getLine(row) orelse "";
                var limit = if (row == pos.row) pos.col else line.len;
                while (limit > 0) {
                    limit -= 1;
                    if (line[limit] == pair.close) {
                        depth += 1;
                    } else if (line[limit] == pair.open) {
                        if (depth == 0) return .{ .row = row, .col = limit };
                        depth -= 1;
                    }
                }
                if (row == 0) break;
                row -= 1;
            }
        },
    }
    return null;
}

fn findMatchingQuote(buf: *Buffer, pos: Position, quote: u8, direction: SearchDirection) ?Position {
    switch (direction) {
        .forward => {
            var row = pos.row;
            while (row < buf.lineCount()) : (row += 1) {
                const line = buf.getLine(row) orelse continue;
                var col = if (row == pos.row) pos.col + 1 else 0;
                while (col < line.len) : (col += 1) {
                    if (line[col] == quote and (col == 0 or line[col - 1] != '\\')) {
                        return .{ .row = row, .col = col };
                    }
                }
            }
        },
        .backward => {
            var row = pos.row;
            while (true) {
                const line = buf.getLine(row) orelse "";
                var limit = if (row == pos.row) pos.col else line.len;
                while (limit > 0) {
                    limit -= 1;
                    if (line[limit] == quote and (limit == 0 or line[limit - 1] != '\\')) {
                        return .{ .row = row, .col = limit };
                    }
                }
                if (row == 0) break;
                row -= 1;
            }
        },
    }
    return null;
}

pub fn selectionContainsChar(sel: Selection, row: usize, col: usize, line_len: usize) bool {
    const start = sel.start();
    const end = sel.end();

    if (row < start.row or row > end.row) return false;
    if (start.row == end.row) {
        const end_col = if (end.col >= line_len) end.col else end.col + @intFromBool(!sel.isCollapsed());
        return col >= start.col and col < end_col;
    }
    if (row == start.row) return col >= start.col;
    if (row == end.row) {
        const end_col = if (end.col >= line_len) end.col else end.col + @intFromBool(!sel.isCollapsed());
        return col < end_col;
    }
    return true;
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

fn normalLineEndCol(buf: *Buffer, row: usize) usize {
    const len = buf.lineLen(row);
    if (len == 0) return 0;
    return buf.prevColumn(row, len);
}

fn advancePositionByBytes(start: Position, bytes: []const u8) Position {
    var pos = start;
    for (bytes) |byte| {
        if (byte == '\n') {
            pos.row += 1;
            pos.col = 0;
        } else {
            pos.col += 1;
        }
    }
    return pos;
}

fn leadingUtf8Char(bytes: []const u8) []const u8 {
    if (bytes.len == 0) return bytes;

    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return bytes[0..1];
    if (len > bytes.len) return bytes[0..1];

    var idx: usize = 1;
    while (idx < len) : (idx += 1) {
        if ((bytes[idx] & 0xC0) != 0x80) return bytes[0..1];
    }

    return bytes[0..len];
}

fn initTestEditor(initial: []const u8) !Editor {
    const allocator = std.testing.allocator;
    var editor = Editor{
        .allocator = allocator,
        .io = undefined,
        .terminal = .{
            .io = undefined,
            .original_termios = undefined,
            .out = undefined,
            .in = undefined,
            .size = .{ .rows = 24, .cols = 80 },
            .pending_input = undefined,
            .pending_len = 0,
        },
        .buffers = .empty,
        .current_buf = 0,
        .mode = .insert,
        .cursor = .{},
        .selection = null,
        .scroll = 0,
        .pending_keys = .empty,
        .pending_trie_name = "",
        .key_trie_root = keymap.insertKeymap(),
        .status_msg = null,
        .command_buf = .empty,
        .in_command_mode = false,
        .in_numeric_prompt = false,
        .pending_numeric_command = null,
        .should_quit = false,
        .yank_text = null,
        .search_pattern = null,
        .in_char_pending = false,
        .pending_char_command = null,
        .last_find_char = null,
        .last_find_command = null,
        .in_search_mode = false,
        .search_direction = .forward,
        .search_start_cursor = .{},
        .normal_cursor_style = .block,
        .insert_cursor_style = .beam,
        .select_cursor_style = .block,
        .last_render_buf = null,
        .last_render_scroll = 0,
        .last_render_rows = 0,
        .last_render_cols = 0,
        .last_render_cursor = .{},
        .last_render_mode = .insert,
        .last_render_selection = null,
    };
    const buf = try Buffer.initStrategy(allocator, .gap_buffer, initial);
    errdefer buf.deinit();
    try editor.buffers.append(allocator, buf);
    return editor;
}

fn deinitTestEditor(editor: *Editor) void {
    for (editor.buffers.items) |buf| buf.deinit();
    editor.buffers.deinit(editor.allocator);
    editor.pending_keys.deinit(editor.allocator);
    editor.command_buf.deinit(editor.allocator);
    if (editor.yank_text) |t| editor.allocator.free(t);
    if (editor.search_pattern) |p| editor.allocator.free(p);
    if (editor.status_msg) |m| editor.allocator.free(m);
}

fn expectEditorBufferText(editor: *Editor, expected: []const u8) !void {
    const buf = editor.getBuffer() orelse return error.TestUnexpectedResult;
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(editor.allocator);
    try buf.text.writeToBuf(editor.allocator, &actual);
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn expectYankText(editor: *Editor, expected: []const u8) !void {
    const actual = editor.yank_text orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(expected, actual);
}

test "handleInsertKey keeps UTF-8 sequences intact across mixed inserts" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    const omega = [_]u8{ 0xCE, 0xA9 };
    const smile = [_]u8{ 0xF0, 0x9F, 0x98, 0x80 };
    const expected = [_]u8{ 0xCE, 0xA9, '!', 0xF0, 0x9F, 0x98, 0x80 };

    try editor.handleInsertKey(Key.initUtf8(&omega));
    try editor.handleInsertKey(Key.init(.exclam));
    try editor.handleInsertKey(Key.initUtf8(&smile));

    const line = editor.getBuffer().?.getLine(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &expected, line);
    try std.testing.expectEqual(Position{ .row = 0, .col = expected.len }, editor.cursor);
}

test "handleInsertKey backspace removes an entire UTF-8 sequence" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    const omega = [_]u8{ 0xCE, 0xA9 };
    const smile = [_]u8{ 0xF0, 0x9F, 0x98, 0x80 };

    try editor.handleInsertKey(Key.initUtf8(&omega));
    try editor.handleInsertKey(Key.initUtf8(&smile));
    try editor.handleInsertKey(Key.init(.backspace));

    const line = editor.getBuffer().?.getLine(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &omega, line);
    try std.testing.expectEqual(Position{ .row = 0, .col = omega.len }, editor.cursor);
}

test "handleInsertKey ignores modified printable keys" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    try editor.handleInsertKey(Key.initCtrl(.lower_a));
    try editor.handleInsertKey(Key.initAlt(.lower_x));
    try editor.handleInsertKey(Key.init(.lower_b));

    try expectEditorBufferText(&editor, "b");
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);
}

test "normal mode yank and paste keep UTF-8 bytes intact" {
    const omega = [_]u8{ 0xCE, 0xA9 };
    const expected = [_]u8{ 0xCE, 0xA9, 0xCE, 0xA9, '!' };

    var editor = try initTestEditor(&[_]u8{ omega[0], omega[1], '!' });
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try editor.executeCommand(.paste_after);

    const line = editor.getBuffer().?.getLine(0) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualSlices(u8, &expected, line);
}

test "delete_selection_noyank deletes without replacing yank register" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.cursor.col = 1;
    try editor.executeCommand(.delete_selection_noyank);

    try expectEditorBufferText(&editor, "ac");
    try expectYankText(&editor, "a");
    try std.testing.expectEqual(Mode.normal, editor.mode);
}

test "change_selection_noyank enters insert mode without replacing yank register" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.cursor.col = 1;
    try editor.executeCommand(.change_selection_noyank);

    try expectEditorBufferText(&editor, "ac");
    try expectYankText(&editor, "a");
    try std.testing.expectEqual(Mode.insert, editor.mode);
}

test "Alt-d triggers no-yank deletion from keymap" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.cursor.col = 1;
    try editor.handleKey(Key.initAlt(.lower_d));

    try expectEditorBufferText(&editor, "ac");
    try expectYankText(&editor, "a");
    try std.testing.expectEqual(Mode.normal, editor.mode);
}

test "Alt-c triggers no-yank change and enters insert mode" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.cursor.col = 1;
    try editor.handleKey(Key.initAlt(.lower_c));

    try expectEditorBufferText(&editor, "ac");
    try expectYankText(&editor, "a");
    try std.testing.expectEqual(Mode.insert, editor.mode);
}

test "normal mode cursor movement stays on Chinese UTF-8 boundaries" {
    var editor = try initTestEditor("A你B好");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.cursor);
}

test "handleInsertKey keeps Chinese inserts stable between adjacent ASCII bytes" {
    var editor = try initTestEditor("AB");
    defer deinitTestEditor(&editor);

    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.handleInsertKey(Key.initUtf8("你"));
    try editor.handleInsertKey(Key.init(.exclam));

    try expectEditorBufferText(&editor, "A你!B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.cursor);
}

test "append_mode inserts Chinese text after the full UTF-8 sequence" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.append_mode);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.cursor);

    try editor.handleInsertKey(Key.initUtf8("好"));

    try expectEditorBufferText(&editor, "A你好B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 7 }, editor.cursor);
}

test "insertTextBytes inserts a burst and advances cursor once" {
    var editor = try initTestEditor("hello");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_at_line_end);
    try editor.insertTextBytes(" world");

    try expectEditorBufferText(&editor, "hello world");
    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.cursor);
}

test "insertTextBytes keeps UTF-8 bursts intact" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_mode);
    try editor.insertTextBytes("A你B");

    try expectEditorBufferText(&editor, "A你B");
    try std.testing.expectEqual(Position{ .row = 0, .col = "A你B".len }, editor.cursor);
}

test "open_below_with_indent inserts a fresh line directly below the cursor" {
    var editor = try initTestEditor("    alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.open_below_with_indent);

    const buf = editor.getBuffer().?;
    try std.testing.expectEqualStrings("    alpha", buf.getLine(0).?);
    try std.testing.expectEqualStrings("    ", buf.getLine(1).?);
    try std.testing.expectEqualStrings("beta", buf.getLine(2).?);
    try std.testing.expectEqualStrings("gamma", buf.getLine(3).?);
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
}

test "open_below inserts a fresh line directly below the cursor" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 2 };

    try editor.executeCommand(.open_below);

    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try expectEditorBufferText(&editor, "alpha\n\nbeta\ngamma");
}

test "repeated open_below preserves the original next line content" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.open_below);
    try editor.handleInsertKey(Key.init(.lower_x));
    try editor.executeCommand(.normal_mode);
    try editor.executeCommand(.open_below);
    try editor.handleInsertKey(Key.init(.lower_y));

    try std.testing.expectEqual(Position{ .row = 2, .col = 1 }, editor.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try expectEditorBufferText(&editor, "alpha\nx\ny\nbeta\ngamma");
}

test "searchBuffer searches backward across lines" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta alpha\ngamma");
    defer buf.deinit();

    const pos = searchBuffer(buf, "alpha", .{ .row = 2, .col = 0 }, .backward, true) orelse unreachable;
    try std.testing.expectEqual(Position{ .row = 1, .col = 5 }, pos);
}

test "findBracketMatchAtOrBefore finds nested bracket pair" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "([x])");
    defer buf.deinit();

    const match = findBracketMatchAtOrBefore(buf, .{ .row = 0, .col = 1 }) orelse unreachable;
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, match.open_pos);
    try std.testing.expectEqual(Position{ .row = 0, .col = 3 }, match.close_pos);
}

test "selectionContainsChar handles full-line end columns" {
    const sel = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 1, .col = 4 },
    };

    try std.testing.expect(selectionContainsChar(sel, 0, 0, 3));
    try std.testing.expect(selectionContainsChar(sel, 1, 3, 4));
    try std.testing.expect(!selectionContainsChar(sel, 1, 4, 4));
}
