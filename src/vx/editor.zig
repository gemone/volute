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
const encoding_mod = @import("../codecs/encoding.zig");
const line_ending_mod = @import("line_ending.zig");
const grammar_mod = @import("grammar.zig");
const SearchDirection = enum { forward, backward };
const SearchMatch = struct {
    start: Position,
    end: Position,
};
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
    selection_linewise: bool,
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
    yank_linewise: bool,
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
    /// Ordered encoding probe list used when opening files.
    /// Mirrors Vim's `fileencodings` option.  null = use encoding.default_fileencodings.
    /// Owned by the editor (heap-allocated); replaced by `:set fencs=<list>`.
    fileencodings: ?[]const encoding_mod.Encoding,
    /// Tree-sitter grammar paths (lib_dir + query_dir). Strings are owned by the editor.
    grammar_paths: ?grammar_mod.GrammarPaths,
    /// Currently loaded grammar handle. Null if no grammar was loaded or loading failed.
    grammar_handle: ?grammar_mod.GrammarHandle,
    /// Name of the grammar currently loaded (e.g. "python"). Points into static config;
    /// not owned by the editor.
    grammar_name: ?[]const u8,

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
            .selection_linewise = false,
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
            .yank_linewise = false,
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
            .fileencodings = null,
            .grammar_paths = null,
            .grammar_handle = null,
            .grammar_name = null,
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
        if (self.fileencodings) |fe| self.allocator.free(fe);
        if (self.grammar_handle) |*gh| gh.deinit();
        if (self.grammar_paths) |gp| {
            self.allocator.free(gp.lib_dir);
            self.allocator.free(gp.query_dir);
        }
        self.terminal.deinit();
    }

    pub fn openFile(self: *Self, path: []const u8) !void {
        const buf = try Buffer.openFileWithOptions(self.allocator, self.io, path, self.fileencodings);
        try self.buffers.append(self.allocator, buf);
        self.current_buf = self.buffers.items.len - 1;
        self.cursor = .{};
        self.scroll = 0;
    }

    /// Open a file with a forced encoding (skips auto-detection).
    /// Used when `-e <enc>` is passed on the command line in TUI mode.
    pub fn openFileForced(self: *Self, path: []const u8, enc: encoding_mod.Encoding) !void {
        const forced_list = [_]encoding_mod.Encoding{enc};
        const buf = try Buffer.openFileWithOptions(self.allocator, self.io, path, &forced_list);
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

    fn changeSelection(self: *Self, yank: bool) !void {
        const buf = self.getBuffer() orelse return;
        try self.deleteSelection(yank);
        self.setMode(.insert);
        self.cursor = buf.clampPosInsert(self.cursor);
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
            self.cursor = advancePositionByBytes(insert_pos, utf8_bytes);
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
            self.selection_linewise = false;
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

        self.in_char_pending = false;
        self.pending_char_command = null;

        switch (cmd) {
            .find_next_char, .find_till_char, .find_prev_char, .till_prev_char => {
                const target = key.char() orelse return;
                self.last_find_char = target;
                self.last_find_command = cmd;
                try self.executeFindChar(cmd, target);
            },
            .surround_add => try self.applySurroundAdd(key.char() orelse return),
            .surround_replace => try self.applySurroundReplace(key.char() orelse return),
            .replace => {
                var ascii_buf: [1]u8 = undefined;
                const target = keyInputBytes(key, &ascii_buf);
                if (target.len == 0) return;
                try self.replaceSelectionWithBytes(target);
            },
            else => {},
        }
    }

    fn executeFindChar(self: *Self, cmd: Command, target: u8) !void {
        const buf = self.getBuffer() orelse return;

        switch (cmd) {
            .find_next_char => {
                self.cursor = findNextChar(buf, self.cursor, target) orelse self.cursor;
            },
            .find_till_char => {
                const found = findNextChar(buf, self.cursor, target) orelse return;
                self.cursor = prevCharPosition(buf, found) orelse self.cursor;
            },
            .find_prev_char => {
                self.cursor = findPrevChar(buf, self.cursor, target) orelse self.cursor;
            },
            .till_prev_char => {
                const found = findPrevChar(buf, self.cursor, target) orelse return;
                self.cursor = nextCharPosition(buf, found) orelse self.cursor;
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
        } else if (std.mem.startsWith(u8, cmd, "e ") or std.mem.startsWith(u8, cmd, "edit ")) {
            // :e ++enc=<name> [path]  — reload current file (or open path) with explicit encoding
            const arg = std.mem.trim(u8, cmd[if (cmd[1] == ' ') 2 else 5 ..], " ");
            if (std.mem.startsWith(u8, arg, "++enc=")) {
                const rest = arg[6..];
                const space = std.mem.indexOfScalar(u8, rest, ' ');
                const enc_name = if (space) |s| rest[0..s] else rest;
                const path_arg = if (space) |s| std.mem.trim(u8, rest[s + 1 ..], " ") else "";
                if (encoding_mod.Encoding.fromName(enc_name)) |enc| {
                    if (path_arg.len > 0) {
                        // Open a new file, forcing decode with the specified encoding.
                        // Pass a single-element list so auto-detection is bypassed entirely.
                        const forced: []const encoding_mod.Encoding = &.{enc};
                        const buf = try Buffer.openFileWithOptions(self.allocator, self.io, path_arg, forced);
                        try self.buffers.append(self.allocator, buf);
                        self.current_buf = self.buffers.items.len - 1;
                        self.cursor = .{};
                        self.scroll = 0;
                        self.setStatus("Opened {s} as {s}", .{ path_arg, enc.displayName() });
                    } else {
                        // Revert current buffer with specified encoding
                        const buf = self.getBuffer() orelse {
                            self.setStatusText("No buffer");
                            return;
                        };
                        buf.revertWithEncoding(self.io, enc) catch |err| {
                            self.setStatus("Revert failed: {}", .{err});
                            return;
                        };
                        self.cursor = .{};
                        self.scroll = 0;
                        self.setStatus("Reloaded as {s}", .{enc.displayName()});
                    }
                } else {
                    self.setStatus("Unknown encoding: {s}", .{enc_name});
                }
            } else if (arg.len > 0) {
                try self.openFile(arg);
                self.setStatus("Opened: {s}", .{arg});
            }
        } else if (std.mem.eql(u8, cmd, "n") or std.mem.eql(u8, cmd, "new")) {
            try self.openNewBuffer();
        } else if (std.mem.eql(u8, cmd, "bn") or std.mem.eql(u8, cmd, "bnext")) {
            try self.executeCommand(.buffer_next);
        } else if (std.mem.eql(u8, cmd, "bp") or std.mem.eql(u8, cmd, "bprev")) {
            try self.executeCommand(.buffer_prev);
        } else if (std.mem.startsWith(u8, cmd, "set ")) {
            self.executeSetCommand(cmd[4..]);
        } else {
            self.setStatus("Unknown command: {s}", .{cmd});
        }
    }

    /// Handle `:set <option>[=<value>]` or `:set <option>?` sub-commands.
    fn executeSetCommand(self: *Self, arg: []const u8) void {
        const buf = self.getBuffer() orelse {
            self.setStatusText("No buffer");
            return;
        };
        const trimmed = std.mem.trim(u8, arg, " ");

        // Query commands: :set fenc?  :set ff?  :set fencs?
        if (std.mem.eql(u8, trimmed, "fenc?") or std.mem.eql(u8, trimmed, "fileencoding?")) {
            self.setStatus("fileencoding={s}", .{buf.file_encoding.displayName()});
            return;
        }
        if (std.mem.eql(u8, trimmed, "ff?") or std.mem.eql(u8, trimmed, "fileformat?")) {
            self.setStatus("fileformat={s}", .{buf.file_line_ending.displayName()});
            return;
        }
        if (std.mem.eql(u8, trimmed, "fencs?") or std.mem.eql(u8, trimmed, "fileencodings?")) {
            const list = self.fileencodings orelse encoding_mod.default_fileencodings;
            var out = std.ArrayList(u8).empty;
            defer out.deinit(self.allocator);
            out.appendSlice(self.allocator, "fencs=") catch {};
            for (list, 0..) |enc, i| {
                if (i > 0) out.append(self.allocator, ',') catch {};
                out.appendSlice(self.allocator, enc.displayName()) catch {};
            }
            self.setStatusText(out.items);
            return;
        }
        if (std.mem.eql(u8, trimmed, "bomb")) {
            buf.has_bom = true;
            buf.dirty = true;
            self.setStatusText("BOM enabled");
            return;
        }
        if (std.mem.eql(u8, trimmed, "nobomb")) {
            buf.has_bom = false;
            buf.dirty = true;
            self.setStatusText("BOM disabled");
            return;
        }

        // Assignment commands: :set fenc=utf-8  :set ff=unix
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_idx| {
            const key = trimmed[0..eq_idx];
            const value = trimmed[eq_idx + 1 ..];
            if (std.mem.eql(u8, key, "fenc") or std.mem.eql(u8, key, "fileencoding")) {
                if (encoding_mod.Encoding.fromName(value)) |enc| {
                    buf.file_encoding = enc;
                    buf.has_bom = (enc == .utf8bom);
                    buf.dirty = true;
                    self.setStatus("fileencoding={s}", .{enc.displayName()});
                } else {
                    self.setStatus("Unknown encoding: {s}", .{value});
                }
                return;
            }
            if (std.mem.eql(u8, key, "fencs") or std.mem.eql(u8, key, "fileencodings")) {
                // Parse comma-separated encoding list e.g. "utf-8,gbk,latin1"
                var list = std.ArrayListUnmanaged(encoding_mod.Encoding).empty;
                defer list.deinit(self.allocator);
                var it = std.mem.splitScalar(u8, value, ',');
                var bad: ?[]const u8 = null;
                while (it.next()) |token| {
                    const name = std.mem.trim(u8, token, " ");
                    if (name.len == 0) continue;
                    if (encoding_mod.Encoding.fromName(name)) |enc| {
                        list.append(self.allocator, enc) catch {};
                    } else {
                        bad = name;
                        break;
                    }
                }
                if (bad) |name| {
                    self.setStatus("Unknown encoding in fencs: {s}", .{name});
                } else if (list.items.len == 0) {
                    // Empty list → reset to default
                    if (self.fileencodings) |fe| self.allocator.free(fe);
                    self.fileencodings = null;
                    self.setStatusText("fencs reset to default");
                } else {
                    if (self.fileencodings) |fe| self.allocator.free(fe);
                    self.fileencodings = list.toOwnedSlice(self.allocator) catch null;
                    self.setStatus("fencs={s}", .{value});
                }
                return;
            }
            if (std.mem.eql(u8, key, "ff") or std.mem.eql(u8, key, "fileformat")) {
                const le: ?line_ending_mod.LineEnding =
                    if (std.mem.eql(u8, value, "unix")) .lf
                    else if (std.mem.eql(u8, value, "dos")) .crlf
                    else if (std.mem.eql(u8, value, "mac")) .cr
                    else null;
                if (le) |l| {
                    buf.file_line_ending = l;
                    buf.dirty = true;
                    self.setStatus("fileformat={s}", .{value});
                } else {
                    self.setStatus("Unknown fileformat: {s} (use unix/dos/mac)", .{value});
                }
                return;
            }
        }

        self.setStatus("Unknown option: {s}", .{trimmed});
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

    fn clearYankText(self: *Self) void {
        if (self.yank_text) |text| self.allocator.free(text);
        self.yank_text = null;
        self.yank_linewise = false;
    }

    fn setYankText(self: *Self, text: []const u8, linewise: bool) !void {
        self.clearYankText();
        self.yank_text = try self.allocator.dupe(u8, text);
        self.yank_linewise = linewise;
    }

    fn selectionIsLinewise(self: *const Self) bool {
        return self.selection != null and self.selection_linewise;
    }

    fn copySelectedLines(self: *Self, buf: *Buffer) ![]u8 {
        const rows = self.selectedLineRange();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);

        var row = rows.start;
        while (row <= rows.end) : (row += 1) {
            const line = buf.getLine(row) orelse "";
            try out.appendSlice(self.allocator, line);
            if (row < rows.end) try out.append(self.allocator, '\n');
        }
        return try out.toOwnedSlice(self.allocator);
    }

    fn copySelectionText(self: *Self, buf: *Buffer) ![]u8 {
        if (self.selectionIsLinewise()) {
            return try self.copySelectedLines(buf);
        }
        const range = self.selectedTextRange(buf);
        return try buf.copyRange(range.start, range.end);
    }

    fn replaceSelectionBytes(self: *Self, buf: *Buffer, bytes: []const u8, force_linewise: bool) !void {
        if (self.selection == null) return;

        if (force_linewise or self.selectionIsLinewise()) {
            const rows = self.selectedLineRange();
            try buf.deleteLines(rows.start, rows.end + 1);
            try insertTextAsLines(buf, rows.start, bytes);
            self.cursor = .{ .row = rows.start, .col = 0 };
        } else {
            const range = self.selectedTextRange(buf);
            try buf.replaceTextRange(range.start, range.end, bytes);
            self.cursor = advancePositionByBytes(range.start, bytes);
        }

        self.selection = null;
        self.selection_linewise = false;
        self.setMode(.normal);
        self.cursor = buf.clampPos(self.cursor);
    }

    fn pasteYank(self: *Self, after: bool) !void {
        const buf = self.getBuffer() orelse return;
        const text = self.yank_text orelse return;

        try buf.pushUndo(self.cursor);

        if (self.selection != null) {
            try self.replaceSelectionBytes(buf, text, self.yank_linewise);
            return;
        }

        if (self.yank_linewise) {
            const insert_row = if (after) self.cursor.row + 1 else self.cursor.row;
            try insertTextAsLines(buf, insert_row, text);
            self.cursor = .{ .row = insert_row, .col = 0 };
            self.cursor = buf.clampPos(self.cursor);
            return;
        }

        const insert_pos = self.pasteCharwiseInsertPosition(buf, after);
        try buf.insertBytesAt(insert_pos, text);
        self.cursor = buf.clampPos(advancePositionByBytes(insert_pos, text));
    }

    fn pasteCharwiseInsertPosition(self: *const Self, buf: *Buffer, after: bool) Position {
        const cursor = buf.clampPos(self.cursor);
        if (!after) return buf.clampPosInsert(cursor);

        const line = buf.getLine(cursor.row) orelse "";
        if (line.len == 0 or cursor.col >= line.len) {
            return .{ .row = cursor.row, .col = line.len };
        }
        return .{ .row = cursor.row, .col = buf.nextColumn(cursor.row, cursor.col) };
    }

    fn replaceSelectionWithBytes(self: *Self, target: []const u8) !void {
        if (target.len == 0 or (target.len == 1 and target[0] == '\n')) return;
        const buf = self.getBuffer() orelse return;
        if (self.selection == null) {
            try buf.pushUndo(self.cursor);
            const line = buf.getLine(self.cursor.row) orelse return;
            if (self.cursor.col < line.len) {
                try buf.replaceBytesAt(self.cursor.row, self.cursor.col, target);
            }
            return;
        }

        const source = try self.copySelectionText(buf);
        defer self.allocator.free(source);

        var replaced: std.ArrayList(u8) = .empty;
        defer replaced.deinit(self.allocator);
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            const byte = source[i];
            if (byte == '\n') {
                try replaced.append(self.allocator, '\n');
            } else if ((byte & 0b1100_0000) != 0b1000_0000) {
                try replaced.appendSlice(self.allocator, target);
            }
        }

        try buf.pushUndo(self.cursor);
        try self.replaceSelectionBytes(buf, replaced.items, self.selectionIsLinewise());
    }

    const CaseTransform = enum { toggle, lower, upper };

    fn applyCaseShift(ch: u8, transform: CaseTransform) u8 {
        return switch (transform) {
            .toggle => if (ch >= 'a' and ch <= 'z') ch - 32 else if (ch >= 'A' and ch <= 'Z') ch + 32 else ch,
            .lower => if (ch >= 'A' and ch <= 'Z') ch + 32 else ch,
            .upper => if (ch >= 'a' and ch <= 'z') ch - 32 else ch,
        };
    }

    fn transformSelectionCase(self: *Self, transform: CaseTransform) !void {
        const buf = self.getBuffer() orelse return;
        if (self.selection == null) {
            try buf.pushUndo(self.cursor);
            const line = buf.getLine(self.cursor.row) orelse return;
            if (self.cursor.col >= line.len) return;
            try buf.replaceCharAt(self.cursor.row, self.cursor.col, applyCaseShift(line[self.cursor.col], transform));
            return;
        }

        const source = try self.copySelectionText(buf);
        defer self.allocator.free(source);

        for (source) |*ch| {
            ch.* = applyCaseShift(ch.*, transform);
        }

        try buf.pushUndo(self.cursor);
        try self.replaceSelectionBytes(buf, source, self.selectionIsLinewise());
    }

    fn linewiseSelectionForRows(self: *Self, start_row: usize, end_row: usize, buf: *Buffer) void {
        self.setMode(.select_);
        self.selection_linewise = true;
        self.selection = .{
            .anchor = .{ .row = start_row, .col = 0 },
            .cursor = .{ .row = end_row, .col = buf.lineLen(end_row) },
        };
        self.cursor = self.selection.?.cursor;
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

    fn searchMatch(buf: *Buffer, pattern: []const u8, start: Position, direction: SearchDirection, skip_current: bool) ?SearchMatch {
        const match_start = searchBuffer(buf, pattern, start, direction, skip_current) orelse return null;
        return .{
            .start = match_start,
            .end = advancePositionByBytes(match_start, pattern),
        };
    }

    fn selectSearchMatch(self: *Self, buf: *Buffer, match: SearchMatch) void {
        const end_cursor = prevCharPositionFromEnd(buf, match.start, match.end);
        self.setMode(.select_);
        self.selection_linewise = false;
        self.selection = .{
            .anchor = match.start,
            .cursor = end_cursor,
        };
        self.cursor = end_cursor;
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

        if (self.selection) |_| {
            if (yank) {
                const text = try self.copySelectionText(buf);
                defer self.allocator.free(text);
                try self.setYankText(text, self.selectionIsLinewise());
            }

            try buf.pushUndo(self.cursor);
            if (self.selectionIsLinewise()) {
                const rows = self.selectedLineRange();
                try buf.deleteLines(rows.start, rows.end + 1);
                self.cursor = .{ .row = @min(rows.start, buf.lineCount() -| 1), .col = 0 };
            } else {
                const range = self.selectedTextRange(buf);
                try buf.replaceTextRange(range.start, range.end, "");
                self.cursor = range.start;
            }
            self.selection = null;
            self.selection_linewise = false;
            self.setMode(.normal);
            self.cursor = buf.clampPos(self.cursor);
            return;
        }

        try buf.pushUndo(self.cursor);
        const line = buf.getLine(self.cursor.row) orelse return;
        if (line.len > 0) {
            const ch = buf.charSliceAt(self.cursor) orelse return;
            if (yank) {
                try self.setYankText(ch, false);
            }
            _ = try buf.deleteCharAt(.{ .row = self.cursor.row, .col = self.cursor.col + 1 });
            self.cursor = buf.clampPos(self.cursor);
        } else if (buf.lineCount() > 1) {
            if (yank) {
                try self.setYankText("\n", true);
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
                self.selection_linewise = false;
                self.cursor = buf.clampPos(self.cursor);
                if (self.cursor.col >= buf.lineLen(self.cursor.row)) self.cursor.col = normalLineEndCol(buf, self.cursor.row);
            },
            .select_mode => {
                self.setMode(.select_);
                self.selection_linewise = false;
                self.selection = Selection.init(self.cursor);
            },

            .delete_selection => try self.deleteSelection(true),
            .delete_selection_noyank => try self.deleteSelection(false),
            .change_selection => try self.changeSelection(true),
            .change_selection_noyank => try self.changeSelection(false),
            .yank => {
                if (self.selection != null) {
                    const text = try self.copySelectionText(buf);
                    defer self.allocator.free(text);
                    try self.setYankText(text, self.selectionIsLinewise());
                    self.selection = null;
                    self.selection_linewise = false;
                    self.setMode(.normal);
                } else {
                    const line = buf.getLine(self.cursor.row) orelse return;
                    if (line.len > 0 and self.cursor.col < line.len) {
                        const ch = buf.charSliceAt(self.cursor) orelse return;
                        try self.setYankText(ch, false);
                    } else {
                        try self.setYankText(line, false);
                    }
                }
            },
            .paste_after => try self.pasteYank(true),
            .paste_before => try self.pasteYank(false),
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
                if (self.yank_text) |text| {
                    try buf.pushUndo(self.cursor);
                    if (self.selection != null) {
                        try self.replaceSelectionBytes(buf, text, self.yank_linewise);
                    } else {
                        const range = self.selectedTextRange(buf);
                        try buf.replaceTextRange(range.start, range.end, text);
                        self.cursor = buf.clampPos(advancePositionByBytes(range.start, text));
                    }
                }
            },
            .switch_case => try self.transformSelectionCase(.toggle),
            .switch_to_lowercase => try self.transformSelectionCase(.lower),
            .switch_to_uppercase => try self.transformSelectionCase(.upper),
            .extend_line_below => {
                if (self.selection != null) {
                    const rows = self.selectedLineRange();
                    self.linewiseSelectionForRows(rows.start, @min(rows.end + 1, buf.lineCount() -| 1), buf);
                } else {
                    self.linewiseSelectionForRows(self.cursor.row, self.cursor.row, buf);
                }
            },
            .extend_to_line_bounds => {
                const rows = self.selectedLineRange();
                self.linewiseSelectionForRows(rows.start, rows.end, buf);
            },
            .select_all => {
                const last_row = buf.lineCount() -| 1;
                self.linewiseSelectionForRows(0, last_row, buf);
            },
            .collapse_selection => {
                self.selection = null;
                self.selection_linewise = false;
                self.setMode(.normal);
            },
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
                        if (searchMatch(buf, pattern, start, self.search_direction, false)) |match| {
                            self.selectSearchMatch(buf, match);
                        }
                    }
                }
            },
            .search_prev => {
                if (self.search_pattern) |pattern| {
                    if (pattern.len > 0) {
                        const direction: SearchDirection = if (self.search_direction == .forward) .backward else .forward;
                        const start = advanceSearchPosition(buf, self.cursor, direction) orelse self.cursor;
                        if (searchMatch(buf, pattern, start, direction, false)) |match| {
                            self.selectSearchMatch(buf, match);
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

fn insertTextAsLines(buf: *Buffer, start_row: usize, text: []const u8) !void {
    if (text.len == 0) return;
    var row = start_row;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try buf.insertLine(row, line);
        row += 1;
    }
}

fn keyInputBytes(key: Key, ascii_buf: *[1]u8) []const u8 {
    const utf8_bytes = key.getBytes();
    if (utf8_bytes.len > 0) return utf8_bytes;
    if (key.char()) |ch| {
        ascii_buf[0] = ch;
        return ascii_buf[0..1];
    }
    return &[0]u8{};
}

fn advancePositionByBytes(start: Position, bytes: []const u8) Position {
    var pos = start;
    var i: usize = 0;
    while (i < bytes.len) {
        const byte = bytes[i];
        if (byte == '\n') {
            pos.row += 1;
            pos.col = 0;
            i += 1;
        } else {
            const seq_len = utf8SequenceLen(bytes, i);
            pos.col += seq_len;
            i += seq_len;
        }
    }
    return pos;
}

fn utf8SequenceLen(bytes: []const u8, start: usize) usize {
    if (start >= bytes.len) return 0;

    const byte = bytes[start];
    if ((byte & 0b1100_0000) == 0b1000_0000) return 1;

    const expected = std.unicode.utf8ByteSequenceLength(byte) catch return 1;
    if (start + expected > bytes.len) return 1;

    var i: usize = 1;
    while (i < expected) : (i += 1) {
        if ((bytes[start + i] & 0b1100_0000) != 0b1000_0000) return 1;
    }

    return expected;
}

fn prevCharPosition(buf: *Buffer, pos: Position) ?Position {
    var row = pos.row;
    var col = pos.col;
    if (row >= buf.lineCount()) return null;

    if (col > 0) return .{ .row = row, .col = buf.prevColumn(row, col) };

    while (row > 0) {
        row -= 1;
        col = buf.lineLen(row);
        if (col > 0) return .{ .row = row, .col = buf.prevColumn(row, col) };
    }

    return null;
}

fn nextCharPosition(buf: *Buffer, pos: Position) ?Position {
    if (pos.row >= buf.lineCount()) return null;

    const line = buf.getLine(pos.row) orelse return null;
    const next_col = buf.nextColumn(pos.row, pos.col);
    if (next_col < line.len) return .{ .row = pos.row, .col = next_col };

    var row = pos.row + 1;
    while (row < buf.lineCount()) : (row += 1) {
        if (buf.lineLen(row) > 0) return .{ .row = row, .col = 0 };
    }

    return null;
}

fn prevCharPositionFromEnd(buf: *Buffer, start: Position, end: Position) Position {
    return prevCharPosition(buf, end) orelse start;
}

fn findNextChar(buf: *Buffer, start: Position, target: u8) ?Position {
    var pos = nextCharPosition(buf, start) orelse return null;
    while (true) {
        if (charAt(buf, pos) == target) return pos;
        pos = nextCharPosition(buf, pos) orelse return null;
    }
}

fn findPrevChar(buf: *Buffer, start: Position, target: u8) ?Position {
    var pos = prevCharPosition(buf, start) orelse return null;
    while (true) {
        if (charAt(buf, pos) == target) return pos;
        pos = prevCharPosition(buf, pos) orelse return null;
    }
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
        .selection_linewise = false,
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
        .yank_linewise = false,
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
        .fileencodings = null,
        .grammar_paths = null,
        .grammar_handle = null,
        .grammar_name = null,
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

test "charwise paste_after inserts after the current grapheme" {
    var editor = try initTestEditor("ab");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("X", false);
    editor.cursor = .{ .row = 0, .col = 0 };

    try editor.executeCommand(.paste_after);

    try expectEditorBufferText(&editor, "aXb");
}

test "charwise paste_before inserts before the current grapheme" {
    var editor = try initTestEditor("ab");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("X", false);
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.paste_before);

    try expectEditorBufferText(&editor, "aXb");
}

test "charwise paste_before keeps UTF-8 and multiline inserts aligned" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("界\nZ", false);
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.paste_before);

    try expectEditorBufferText(&editor, "A界\nZ你B");
    try std.testing.expectEqual(Position{ .row = 1, .col = 1 }, editor.cursor);
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

test "change_selection undo restores both delete and inserted replacement" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor.col = 1;

    try editor.executeCommand(.change_selection);
    try editor.handleInsertKey(Key.init(.lower_x));
    try expectEditorBufferText(&editor, "axc");

    try editor.executeCommand(.undo);

    try expectEditorBufferText(&editor, "abc");
}

test "change_selection_noyank undo restores both delete and inserted replacement" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor.col = 1;

    try editor.executeCommand(.change_selection_noyank);
    try editor.handleInsertKey(Key.init(.lower_x));
    try expectEditorBufferText(&editor, "axc");

    try editor.executeCommand(.undo);

    try expectEditorBufferText(&editor, "abc");
}

test "select mode linewise yank and paste keep full lines" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.handleKey(Key.init(.lower_x));
    try editor.handleKey(Key.init(.lower_y));

    try std.testing.expect(editor.yank_linewise);
    try expectYankText(&editor, "alpha");
    try std.testing.expectEqual(Mode.normal, editor.mode);

    editor.cursor = .{ .row = 1, .col = 2 };
    try editor.handleKey(Key.init(.lower_p));

    try expectEditorBufferText(&editor, "alpha\nbeta\nalpha\ngamma");
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, editor.cursor);
}

test "select mode paste replaces active selection" {
    var editor = try initTestEditor("alpha beta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("XYZ", false);

    editor.cursor = .{ .row = 0, .col = 0 };
    try editor.handleKey(Key.init(.lower_v));
    try editor.handleKey(Key.init(.lower_l));
    try editor.handleKey(Key.init(.lower_l));
    try editor.handleKey(Key.init(.lower_p));

    try expectEditorBufferText(&editor, "XYZha beta");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.selection == null);
}

test "select mode replace fills the active selection" {
    var editor = try initTestEditor("ab你");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = "ab你".len },
    };
    editor.cursor = editor.selection.?.cursor;

    try editor.handleKey(Key.init(.lower_r));
    try editor.handleKey(Key.init(.lower_x));

    try expectEditorBufferText(&editor, "xxx");
    try std.testing.expectEqual(Mode.normal, editor.mode);
}

test "select mode lowercase transforms the whole selection" {
    var editor = try initTestEditor("AbC");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.cursor = editor.selection.?.cursor;

    try editor.handleKey(Key.init(.backtick));

    try expectEditorBufferText(&editor, "abc");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.selection == null);
}

test "Alt-` uppercases a normal-mode selection from the keymap" {
    var editor = try initTestEditor("abC");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.cursor = editor.selection.?.cursor;

    try editor.handleKey(Key.initAlt(.backtick));

    try expectEditorBufferText(&editor, "ABC");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.selection == null);
}

test "v enters select mode and exits back to normal" {
    var editor = try initTestEditor("alpha\nbeta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 2 };

    try editor.handleKey(Key.init(.lower_v));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expect(editor.selection != null);
    try std.testing.expectEqual(Position{ .row = 0, .col = 2 }, editor.selection.?.anchor);

    try editor.handleKey(Key.init(.lower_v));
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.selection == null);
}

test "x selects current line and extends downward in select mode" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 2 };

    try editor.handleKey(Key.init(.lower_x));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.selection.?.cursor);

    try editor.handleKey(Key.init(.lower_x));
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.selection.?.cursor);
}

test "X expands selection to full current line bounds" {
    var editor = try initTestEditor("alpha\nbeta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 1, .col = 2 };

    try editor.handleKey(Key.init(.upper_x));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.selection.?.cursor);
}

test "% selects the entire buffer linewise" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 1, .col = 1 };

    try editor.handleKey(Key.init(.percent));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 2, .col = 5 }, editor.selection.?.cursor);
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

test "Alt-. repeats the last find motion from the keymap" {
    var editor = try initTestEditor("banana");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 0 };

    try editor.handleKey(Key.init(.lower_f));
    try editor.handleKey(Key.init(.lower_a));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);

    try editor.handleKey(Key.initAlt(.dot));
    try std.testing.expectEqual(Position{ .row = 0, .col = 3 }, editor.cursor);
}

test "select mode search-next binding selects the active match" {
    var editor = try initTestEditor("alpha beta alpha");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.cursor = .{ .row = 0, .col = 0 };
    editor.selection = Selection.init(editor.cursor);
    editor.search_pattern = try editor.allocator.dupe(u8, "alpha");
    editor.search_direction = .forward;

    try editor.handleKey(Key.init(.lower_n));

    try std.testing.expectEqual(Position{ .row = 0, .col = 15 }, editor.cursor);
    try std.testing.expect(editor.selection != null);
    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 15 }, editor.selection.?.cursor);
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

test "handleInsertKey advances UTF-8 inserts from the aligned cursor position" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.cursor = .{ .row = 0, .col = 2 };

    try editor.handleInsertKey(Key.initUtf8("好"));

    try expectEditorBufferText(&editor, "A好你B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.cursor);
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

test "insertTextBytes advances across UTF-8 text and newlines" {
    var editor = try initTestEditor("A");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_at_line_end);
    try editor.insertTextBytes("你\n好");

    try expectEditorBufferText(&editor, "A你\n好");
    try std.testing.expectEqual(Position{ .row = 1, .col = "好".len }, editor.cursor);
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

test "search_next and search_prev select the full match" {
    var editor = try initTestEditor("alpha beta\nbeta gamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.search_pattern = try editor.allocator.dupe(u8, "beta");
    editor.search_direction = .forward;
    editor.cursor = .{ .row = 0, .col = 0 };

    try editor.executeCommand(.search_next);
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 6 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 9 }, editor.selection.?.cursor);

    const next_range = editor.selectedTextRange(editor.getBuffer().?);
    const next_text = try editor.getBuffer().?.copyRange(next_range.start, next_range.end);
    defer editor.allocator.free(next_text);
    try std.testing.expectEqualStrings("beta", next_text);

    try editor.executeCommand(.search_prev);
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 3 }, editor.selection.?.cursor);

    const prev_range = editor.selectedTextRange(editor.getBuffer().?);
    const prev_text = try editor.getBuffer().?.copyRange(prev_range.start, prev_range.end);
    defer editor.allocator.free(prev_text);
    try std.testing.expectEqualStrings("beta", prev_text);
}

test "search_next in select mode replaces the active selection with the match" {
    var editor = try initTestEditor("zero alpha beta");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.cursor = editor.selection.?.cursor;
    editor.search_pattern = try editor.allocator.dupe(u8, "beta");
    editor.search_direction = .forward;

    try editor.executeCommand(.search_next);

    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 14 }, editor.selection.?.cursor);
}

test "searchBuffer searches backward across lines" {
    const allocator = std.testing.allocator;
    var buf = try Buffer.initStrategy(allocator, .gap_buffer, "alpha\nbeta alpha\ngamma");
    defer buf.deinit();

    const pos = searchBuffer(buf, "alpha", .{ .row = 2, .col = 0 }, .backward, true) orelse unreachable;
    try std.testing.expectEqual(Position{ .row = 1, .col = 5 }, pos);
}

test "replace_with_yanked uses the full yanked text for the implicit selection" {
    var editor = try initTestEditor("hello world");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 6 };
    try editor.setYankText("planet", false);

    try editor.executeCommand(.replace_with_yanked);

    try expectEditorBufferText(&editor, "hello planet");
}

test "pending replace accepts UTF-8 input" {
    var editor = try initTestEditor("ab");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.handleKey(Key.init(.lower_r));
    try editor.handleKey(Key.initUtf8("你"));

    try expectEditorBufferText(&editor, "你b");
}

test "find and till motions search across lines" {
    var editor = try initTestEditor("ab\ncd\nef");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.find_next_char);
    try editor.handleKey(Key.init(.lower_e));
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, editor.cursor);

    editor.cursor = .{ .row = 0, .col = 1 };
    try editor.executeCommand(.find_till_char);
    try editor.handleKey(Key.init(.lower_e));
    try std.testing.expectEqual(Position{ .row = 1, .col = 1 }, editor.cursor);

    editor.cursor = .{ .row = 2, .col = 0 };
    try editor.executeCommand(.find_prev_char);
    try editor.handleKey(Key.init(.lower_b));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);

    editor.cursor = .{ .row = 2, .col = 0 };
    try editor.executeCommand(.till_prev_char);
    try editor.handleKey(Key.init(.lower_b));
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.cursor);

    editor.cursor = .{ .row = 0, .col = 1 };
    try editor.executeCommand(.till_prev_char);
    try editor.handleKey(Key.init(.lower_a));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.cursor);
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
