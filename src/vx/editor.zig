const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Key = @import("key.zig").Key;
const Mode = @import("mode.zig").Mode;
const Position = @import("position.zig").Position;
const Selection = @import("selection.zig").Selection;
const Terminal = @import("terminal.zig").Terminal;
const CursorStyle = @import("terminal.zig").CursorStyle;
const MouseEvent = @import("terminal.zig").MouseEvent;
const keymap = @import("keymap.zig");
const Command = keymap.Command;
const encoding_mod = @import("../codecs/encoding.zig");
const line_ending_mod = @import("line_ending.zig");
const grammar_mod = @import("grammar.zig");
const syntax = @import("syntax.zig");
const highlight_worker_mod = @import("highlight_worker.zig");
const utf8 = @import("utf8.zig");
const window_mod = @import("window.zig");
const Window = window_mod.Window;
const Tab = window_mod.Tab;
const FloatBuf = window_mod.FloatBuf;
const Rect = window_mod.Rect;
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

    /// A single register storing text and whether it was linewise.
    pub const Register = struct {
        text: ?[]const u8 = null,
        linewise: bool = false,

        pub fn deinit(self: *Register, allocator: std.mem.Allocator) void {
            if (self.text) |t| allocator.free(t);
            self.text = null;
            self.linewise = false;
        }

        pub fn set(self: *Register, allocator: std.mem.Allocator, new_text: []const u8, new_linewise: bool) !void {
            self.deinit(allocator);
            self.text = try allocator.dupe(u8, new_text);
            self.linewise = new_linewise;
        }
    };

    /// Register names: 'a'-'z', '"', '/', ':', '_', '+', '*'
    /// Use a 128-entry array indexed by ASCII for O(1) access.
    pub const NUM_REGISTERS = 128;

    /// Unified pending-input state. Replaces scattered bool flags.
    pub const PendingInput = enum {
        none,
        /// Waiting for a character argument (f/t/F/T, r, m-s/m-r, @)
        char_pending,
        /// Accumulating digits for a numeric prompt (:goto_line)
        numeric_prompt,
        /// Waiting for a register name (")
        register,
        /// Accumulating a repeat count (1-9 prefix)
        repeat_count,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    terminal: Terminal,
    buffers: std.ArrayList(*Buffer),
    tabs: std.ArrayList(Tab),
    current_tab: usize,
    float_bufs: std.ArrayList(FloatBuf),
    float_mode: bool,
    mode: Mode,
    pending_keys: std.ArrayList(Key),
    pending_trie_name: []const u8,
    // Which-key state
    which_key_visible: bool = false,
    which_key_prefix: []const u8 = "",
    key_trie_root: keymap.KeyTrie,
    status_msg: ?[]const u8,
    command_buf: std.ArrayList(u8),
    in_command_mode: bool,
    /// Unified pending-input state: replaces in_char_pending, in_numeric_prompt, in_register_pending
    pending_input: PendingInput = .none,
    /// Accumulated digits for repeat count (e.g., "5j" → count=5)
    pending_count: usize = 0,
    /// Target count for the current command (set by handleNormalKeyWithCount)
    repeat_target: usize = 0,
    /// Command awaiting char/numeric input (used by .char_pending and .numeric_prompt)
    pending_command: ?Command = null,
    should_quit: bool,
    /// Named registers (a-z, ", /, :, _, +, *)
    registers: [NUM_REGISTERS]Register = [_]Register{.{}} ** NUM_REGISTERS,
    /// Which register is active for the next yank/paste (set by " prefix). null = default (")
    active_register: ?u8 = null,
    search_pattern: ?[]const u8,
    last_find_char: ?u8,
    last_find_command: ?Command,
    in_search_mode: bool,
    search_direction: SearchDirection,
    search_start_cursor: Position,
    /// Jump list for Ctrl-o / Ctrl-i navigation
    jump_list: std.ArrayList(Position) = .empty,
    jump_index: usize = 0,
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
    /// Name of the grammar currently loaded (e.g. "python"). Points into static config;
    /// not owned by the editor.
    grammar_name: ?[]const u8,
    /// Background highlight worker. Non-null when a grammar is loaded.
    highlight_worker: ?*highlight_worker_mod.HighlightWorker,
    /// Cached highlight styles from last completed highlight (may be stale).
    cached_hl_styles: ?[]syntax.TokenStyle,
    /// Buffer content_version when cached_hl_styles was computed.
    last_hl_buf_version: u64,
    /// Scroll position when cached_hl_styles was computed.
    last_hl_scroll: usize,
    /// Persistent serialized source cache; avoids writeToBuf on scroll-only changes.
    src_cache: std.ArrayList(u8),
    /// content_version for which src_cache was last filled.
    src_cache_version: u64,
    /// Reusable per-line style buffer for render(): avoids per-frame alloc churn.
    render_style_buf: std.ArrayList(syntax.TokenStyle),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        var terminal = try Terminal.init(io);
        errdefer terminal.deinit();

        var tabs: std.ArrayList(Tab) = .empty;
        errdefer {
            for (tabs.items) |*tab| tab.deinit();
            tabs.deinit(allocator);
        }

        var first_tab = Tab.init(allocator);
        errdefer first_tab.deinit();
        try first_tab.windows.append(allocator, .{ .buf_index = 0, .rect = .{} });
        try tabs.append(allocator, first_tab);

        return .{
            .allocator = allocator,
            .io = io,
            .terminal = terminal,
            .buffers = .empty,
            .tabs = tabs,
            .current_tab = 0,
            .float_bufs = .empty,
            .float_mode = false,
            .mode = .normal,
            .pending_keys = .empty,
            .pending_trie_name = "",
            .which_key_visible = false,
            .which_key_prefix = "",
            .key_trie_root = keymap.normalKeymap(),

            .status_msg = null,
            .command_buf = .empty,
            .in_command_mode = false,
            .should_quit = false,
            .registers = [_]Register{.{}} ** NUM_REGISTERS,
            .active_register = null,
            .search_pattern = null,
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
            .grammar_name = null,
            .highlight_worker = null,
            .cached_hl_styles = null,
            .last_hl_buf_version = std.math.maxInt(u64),
            .last_hl_scroll = std.math.maxInt(usize),
            .src_cache = .empty,
            .src_cache_version = std.math.maxInt(u64),
            .render_style_buf = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.tabs.items) |*tab| tab.deinit();
        self.tabs.deinit(self.allocator);
        self.float_bufs.deinit(self.allocator);
        for (self.buffers.items) |buf| buf.deinit();
        self.buffers.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.jump_list.deinit(self.allocator);
        self.command_buf.deinit(self.allocator);
        for (&self.registers) |*reg| reg.deinit(self.allocator);
        if (self.search_pattern) |p| self.allocator.free(p);
        if (self.status_msg) |m| self.allocator.free(m);
        if (self.fileencodings) |fe| self.allocator.free(fe);
        if (self.highlight_worker) |w| w.deinit();
        if (self.cached_hl_styles) |s| self.allocator.free(s);
        self.src_cache.deinit(self.allocator);
        if (self.grammar_paths) |gp| {
            self.allocator.free(gp.lib_dir);
            self.allocator.free(gp.query_dir);
        }
        self.render_style_buf.deinit(self.allocator);
        self.terminal.deinit();
    }

    /// Reset the active window to point at the last buffer in the list.
    /// Visible content rows (total rows minus statusline and command line)
    fn visibleRows(self: *const Self) usize {
        return self.terminal.size.rows -| 2;
    }

    /// Clear selection and return to normal mode
    fn clearSelectionAndMode(self: *Self) void {
        const win = self.activeWindow() orelse return;
        win.selection = null;
        win.selection_linewise = false;
        self.setMode(.normal);
    }

    fn resetActiveWindowToLastBuffer(self: *Self) void {
        const win = self.activeWindow().?;
        win.buf_index = self.buffers.items.len - 1;
        win.resetView();
        win.selection = null;
        win.selection_linewise = false;
    }

    /// Reset all windows pointing at a given buffer index.
    fn resetWindowsForBuffer(self: *Self, buf_idx: usize) void {
        for (self.tabs.items) |*tab| {
            for (tab.windows.items) |*w| {
                if (w.buf_index == buf_idx) w.resetView();
            }
        }
    }

    /// Register a newly created buffer and point the active window at it.
    fn registerBuffer(self: *Self, buf: *Buffer) !void {
        errdefer buf.deinit();
        try self.buffers.append(self.allocator, buf);
        errdefer _ = self.buffers.pop();
        self.resetActiveWindowToLastBuffer();
    }

    pub fn openFile(self: *Self, path: []const u8) !void {
        const buf = try Buffer.openFileWithOptions(self.allocator, self.io, path, self.fileencodings);
        try self.registerBuffer(buf);
    }

    /// Open a file with a forced encoding (skips auto-detection).
    /// Used when `-e <enc>` is passed on the command line in TUI mode.
    pub fn openFileForced(self: *Self, path: []const u8, enc: encoding_mod.Encoding) !void {
        const forced_list = [_]encoding_mod.Encoding{enc};
        const buf = try Buffer.openFileWithOptions(self.allocator, self.io, path, &forced_list);
        try self.registerBuffer(buf);
    }

    fn openNewBuffer(self: *Self) !void {
        const buf = try Buffer.init(self.allocator);
        try self.registerBuffer(buf);
    }

    /// Open a new float buffer with given title. Returns the float buf index.
    /// The float window is centered on screen and sized to ~60% of terminal.
    pub fn openFloatBuf(self: *Self, title: []const u8) !usize {
        const buf = try Buffer.init(self.allocator);
        errdefer buf.deinit();
        try self.buffers.append(self.allocator, buf);
        errdefer _ = self.buffers.pop();

        const buf_idx = self.buffers.items.len - 1;
        const rows = self.terminal.size.rows;
        const cols = self.terminal.size.cols;
        const float_rows = @min(rows, @max(rows * 3 / 5, @as(usize, 6)));
        const float_cols = @min(cols, @max(cols * 3 / 5, @as(usize, 40)));
        const top = (rows -| float_rows) / 2;
        const left = (cols -| float_cols) / 2;

        for (self.float_bufs.items) |*f| f.focused = false;
        const fb = FloatBuf{
            .buf_index = buf_idx,
            .title = title,
            .rect = Rect{ .top = top, .left = left, .rows = float_rows, .cols = float_cols },
            .focused = true,
        };
        try self.float_bufs.append(self.allocator, fb);
        self.float_mode = true;
        return self.float_bufs.items.len - 1;
    }

    /// Close the topmost (last) float buffer.
    pub fn closeTopFloat(self: *Self) void {
        if (self.float_bufs.items.len == 0) {
            self.float_mode = false;
            return;
        }

        _ = self.float_bufs.pop();
        for (self.float_bufs.items) |*f| f.focused = false;
        if (self.float_bufs.items.len > 0) {
            self.float_bufs.items[self.float_bufs.items.len - 1].focused = true;
            self.float_mode = true;
        } else {
            self.float_mode = false;
        }
    }

    /// Open a cheatsheet float buffer populated from the keymap trie.
    pub fn openCheatsheetFloat(self: *Self) !void {
        // Close existing cheatsheet float if one already exists
        var i: usize = self.float_bufs.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.float_bufs.items[i].title, "Cheatsheet")) {
                _ = self.float_bufs.swapRemove(i);
                break;
            }
        }

        // De-focus all remaining floats
        for (self.float_bufs.items) |*f| f.focused = false;

        // Create buffer with nearly-full-screen dimensions
        const buf = try Buffer.init(self.allocator);
        errdefer buf.deinit();
        try self.buffers.append(self.allocator, buf);
        errdefer _ = self.buffers.pop();

        const buf_idx = self.buffers.items.len - 1;
        const rows = self.terminal.size.rows;
        const cols = self.terminal.size.cols;
        const float_rows = rows -| 3;
        const float_cols = cols -| 4;

        const fb = FloatBuf{
            .buf_index = buf_idx,
            .title = "Cheatsheet",
            .rect = Rect{ .top = 1, .left = 2, .rows = float_rows, .cols = float_cols },
            .focused = true,
        };
        try self.float_bufs.append(self.allocator, fb);
        self.float_mode = true;

        // Build cheatsheet content
        const buf_ptr = self.buffers.items[buf_idx];
        try buildCheatsheetSections(self.allocator, buf_ptr);
    }

    /// Build cheatsheet content in single-column stacked layout.
    fn buildCheatsheetSections(gpa: std.mem.Allocator, buf: *Buffer) !void {
        const root = keymap.normalKeymap();
        const normal_node = switch (root) {
            .node => |n| n,
            else => return,
        };

        const max_lines: usize = 32;
        const Cat = enum(u8) { movement, insert, editing, find, case_, sel, search, indent, jump, other };
        const cat_titles = [_][]const u8{ "Movement", "Insert Modes", "Editing", "Find / Replace", "Case", "Selection", "Search", "Indent / Format", "Page / Jump", "Other" };

        var sections: [12]struct {
            title: []const u8,
            lines: [max_lines][]const u8,
            count: usize,
        } = undefined;
        var sec_count: usize = 0;

        // Init category sections (0-9)
        for (cat_titles, 0..) |title, i| {
            sections[i].title = title;
            sections[i].count = 0;
            sec_count += 1;
        }

        // Collect prefix nodes
        var prefix_titles: [6][]const u8 = undefined;
        var prefix_lines: [6][max_lines][]const u8 = undefined;
        var prefix_counts: [6]usize = [_]usize{0} ** 6;
        var prefix_count: usize = 0;

        for (normal_node.bindings) |binding| {
            switch (binding.trie) {
                .leaf => |cmd| {
                    if (binding.desc.len == 0) continue;
                    const cat: ?Cat = switch (cmd) {
                        .move_char_left, .move_char_right, .move_visual_line_up, .move_visual_line_down, .move_line_up, .move_line_down, .move_next_word_start, .move_prev_word_start, .move_next_word_end, .move_next_long_word_start, .move_prev_long_word_start, .move_next_long_word_end, .goto_line_start, .goto_line_end => .movement,
                        .insert_mode, .insert_at_line_start, .insert_at_line_end, .append_mode, .open_below_with_indent, .open_above_with_indent => .insert,
                        .delete_current_line, .delete_selection, .delete_selection_noyank, .change_current_line, .change_selection_noyank, .yank_current_line, .paste_after, .paste_before, .undo, .redo => .editing,
                        .find_till_char, .find_next_char, .till_prev_char, .find_prev_char, .repeat_last_motion, .replace, .replace_with_yanked => .find,
                        .switch_case, .switch_to_lowercase, .switch_to_uppercase => .case_,
                        .select_mode, .extend_line_below, .extend_to_line_bounds, .select_all, .collapse_selection, .flip_selections, .copy_selection_on_next_line, .copy_selection_on_prev_line, .match_brackets, .join_selections => .sel,
                        .search, .rsearch, .search_next, .search_prev => .search,
                        .indent, .unindent, .format_selections => .indent,
                        .page_up, .page_down, .page_cursor_half_up, .page_cursor_half_down, .jump_back, .jump_forward, .save => .jump,
                        else => .other,
                    };
                    const si = @intFromEnum(cat.?);
                    if (sections[si].count >= max_lines) continue;
                    var kbuf: [16]u8 = undefined;
                    const kl = binding.key.format(&kbuf);
                    sections[si].lines[sections[si].count] = try std.fmt.allocPrint(gpa, "  {s:8}  {s}", .{ kl, binding.desc });
                    sections[si].count += 1;
                },
                .node => |child| {
                    if (child.name.len == 0 or prefix_count >= prefix_titles.len) continue;
                    var pbuf: [16]u8 = undefined;
                    const pl = binding.key.format(&pbuf);
                    prefix_titles[prefix_count] = try std.fmt.allocPrint(gpa, "{s} ({s})", .{ child.name, pl });
                    for (child.bindings) |sub| {
                        if (sub.desc.len == 0 or prefix_counts[prefix_count] >= max_lines) continue;
                        var sbuf: [16]u8 = undefined;
                        const sl = sub.key.format(&sbuf);
                        prefix_lines[prefix_count][prefix_counts[prefix_count]] = try std.fmt.allocPrint(gpa, "  {s:3}  {s}", .{ sl, sub.desc });
                        prefix_counts[prefix_count] += 1;
                    }
                    prefix_count += 1;
                },
            }
        }

        // Write sections to buffer — single column, stacked vertically
        // Free each string immediately after writing to avoid leak on error
        var row: usize = 0;
        for (&sections) |*sec| {
            if (sec.count == 0) continue;
            if (row > 0) {
                try buf.insertLine(row, "");
                row += 1;
            }
            const header = try std.fmt.allocPrint(gpa, "═══ {s} ═══", .{sec.title});
            defer gpa.free(header);
            try buf.insertLine(row, header);
            row += 1;
            for (sec.lines[0..sec.count]) |line| {
                try buf.insertLine(row, line);
                gpa.free(line);
                row += 1;
            }
            sec.count = 0; // Mark as freed
        }
        for (0..prefix_count) |pi| {
            if (prefix_counts[pi] == 0) continue;
            if (row > 0) {
                try buf.insertLine(row, "");
                row += 1;
            }
            const header = try std.fmt.allocPrint(gpa, "═══ {s} ═══", .{prefix_titles[pi]});
            defer gpa.free(header);
            try buf.insertLine(row, header);
            row += 1;
            for (prefix_lines[pi][0..prefix_counts[pi]]) |line| {
                try buf.insertLine(row, line);
                gpa.free(line);
                row += 1;
            }
            gpa.free(prefix_titles[pi]);
            prefix_counts[pi] = 0; // Mark as freed
        }
    }
    pub fn focusedFloat(self: *Self) ?*FloatBuf {
        var i = self.float_bufs.items.len;
        while (i > 0) {
            i -= 1;
            if (self.float_bufs.items[i].focused) return &self.float_bufs.items[i];
        }
        return null;
    }

    pub fn activeTab(self: *Self) ?*Tab {
        if (self.current_tab < self.tabs.items.len) return &self.tabs.items[self.current_tab];
        return null;
    }

    fn activeTabConst(self: *const Self) ?*const Tab {
        if (self.current_tab < self.tabs.items.len) return &self.tabs.items[self.current_tab];
        return null;
    }

    pub fn activeWindow(self: *Self) ?*Window {
        return if (self.activeTab()) |tab| tab.activeWindow() else null;
    }

    fn activeWindowConst(self: *const Self) ?*const Window {
        return if (self.activeTabConst()) |tab| if (tab.active_window < tab.windows.items.len) &tab.windows.items[tab.active_window] else null else null;
    }

    pub fn getBuffer(self: Self) ?*Buffer {
        if (self.current_tab >= self.tabs.items.len) return null;
        const tab = self.tabs.items[self.current_tab];
        if (tab.active_window >= tab.windows.items.len) return null;
        const win = tab.windows.items[tab.active_window];
        if (win.buf_index < self.buffers.items.len) return self.buffers.items[win.buf_index];
        return null;
    }

    pub fn handleMouseEvent(self: *Self, ev: MouseEvent) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        switch (ev.kind) {
            .scroll_up => {
                win.scroll = win.scroll -| 3;
                if (win.cursor.row > win.scroll + self.visibleRows() -| 1)
                    win.cursor.row = win.scroll + self.visibleRows() -| 1;
                win.cursor.row = @max(win.cursor.row, win.scroll);
            },
            .scroll_down => {
                const max_scroll = buf.lineCount() -| 1;
                win.scroll = @min(win.scroll + 3, max_scroll);
                if (win.cursor.row < win.scroll)
                    win.cursor.row = win.scroll;
            },
            else => {},
        }
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

        switch (self.pending_input) {
            .numeric_prompt => {
                try self.handleNumericPromptKey(key);
                return;
            },
            .char_pending => {
                try self.handleCharPending(key);
                return;
            },
            .register => {
                try self.handleRegisterKey(key);
                return;
            },
            .repeat_count => {
                try self.handleRepeatCountKey(key);
                return;
            },
            .none => {},
        }

        self.clearStatus();

        if (self.float_mode and self.focusedFloat() != null) {
            try self.handleFloatKey(key);
            return;
        }

        switch (self.mode) {
            .insert => try self.handleInsertKey(key),
            .normal, .select_ => try self.handleNormalKey(key),
        }
    }

    fn changeSelection(self: *Self, yank: bool) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        try self.deleteSelection(yank);
        self.setMode(.insert);
        win.cursor = buf.clampPosInsert(win.cursor);
        self.adjustScroll();
    }

    /// Delete the character before the cursor (backspace behavior).
    fn deleteBackward(self: *Self) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        if (win.cursor.col > 0) {
            const prev_col = buf.prevColumn(win.cursor.row, win.cursor.col);
            _ = try buf.deleteCharAt(win.cursor);
            win.cursor.col = prev_col;
        } else if (win.cursor.row > 0) {
            const prev_len = buf.lineLen(win.cursor.row - 1);
            _ = try buf.deleteCharAt(win.cursor);
            win.cursor.row -= 1;
            win.cursor.col = prev_len;
        }
        self.adjustScroll();
    }

    pub fn insertTextBytes(self: *Self, bytes: []const u8) !void {
        const win = self.activeWindow().?;
        if (bytes.len == 0) return;
        const buf = self.getBuffer() orelse return;
        const insert_pos = buf.clampPosInsert(win.cursor);
        try buf.insertBytesAt(insert_pos, bytes);
        win.cursor = advancePositionByBytes(insert_pos, bytes);
        self.adjustScroll();
    }

    fn handleInsertKey(self: *Self, key: Key) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;

        if (key.eql(Key.init(.escape)) or key.eql(Key.initCtrl(.lower_c))) {
            self.setMode(.normal);
            if (win.cursor.col > 0) win.cursor.col = buf.prevColumn(win.cursor.row, win.cursor.col);
            win.cursor = buf.clampPos(win.cursor);
            self.adjustScroll();
            return;
        }

        // ctrl+h = backspace (delete char left)
        if (key.eql(Key.initCtrl(.lower_h))) {
            try self.deleteBackward();
            return;
        }
        // ctrl+a = go to line start, ctrl+e = go to line end
        if (key.eql(Key.initCtrl(.lower_a))) {
            try self.executeCommand(.goto_line_start);
            return;
        }
        if (key.eql(Key.initCtrl(.lower_e))) {
            try self.executeCommand(.goto_line_end);
            return;
        }

        if (key.mod.ctrl or key.mod.alt) {
            const result = keymap.lookup(&self.key_trie_root, &.{key});
            if (result.command) |cmd| {
                switch (cmd) {
                    .no_op => {},
                    else => try self.executeCommand(cmd),
                }
            }
            return;
        }

        // Handle UTF-8 multi-byte sequences
        const utf8_bytes = key.getBytes();
        if (utf8_bytes.len > 0) {
            const insert_pos = buf.clampPosInsert(win.cursor);
            try buf.insertBytesAt(insert_pos, utf8_bytes);
            win.cursor = advancePositionByBytes(insert_pos, utf8_bytes);
            self.adjustScroll();
            return;
        }

        const ch = key.char();
        if (ch) |c| {
            const insert_pos = buf.clampPosInsert(win.cursor);
            try buf.insertCharAt(insert_pos, c);
            win.cursor.col += 1;
            self.adjustScroll();
            return;
        }

        switch (key.base) {
            .enter => {
                const insert_pos = buf.clampPosInsert(win.cursor);
                const indent = buf.getAutoIndent(insert_pos.row);

                // Insert newline followed by indent in one sequence
                try buf.insertNewlineAt(insert_pos);

                // Move cursor to new line and insert indent there
                win.cursor.row += 1;
                win.cursor.col = 0;

                // Insert indent at the beginning of the new line
                for (indent) |c| {
                    try buf.insertCharAt(win.cursor, c);
                    win.cursor.col += 1;
                }

                win.cursor = buf.clampPosInsert(win.cursor);
                self.adjustScroll();
            },
            .backspace => {
                try self.deleteBackward();
            },
            .tab => {
                if (key.mod.shift) {
                    try self.executeCommand(.unindent);
                    return;
                }
                try self.insertTextBytes("    ");
            },
            .backtab => {
                try self.executeCommand(.unindent);
            },
            else => {
                // Route navigation keys (arrows, home, end, page_up/down) through
                // the insert keymap so they move the cursor properly.
                const result = keymap.lookup(&self.key_trie_root, &.{key});
                if (result.command) |cmd| {
                    switch (cmd) {
                        .no_op => {},
                        else => try self.executeCommand(cmd),
                    }
                }
            },
        }
    }

    fn clearWhichKey(self: *Self) void {
        self.which_key_visible = false;
        self.which_key_prefix = "";
    }

    fn prefixWhichKeyLabel(key: Key) ?[]const u8 {
        if (key.mod.alt) return null;
        if (key.mod.ctrl) {
            return switch (key.base) {
                .lower_w => "C-w",
                else => null,
            };
        }
        return switch (key.base) {
            .lower_g => "g",
            .space => "space",
            .lower_z => "z",
            .lower_m => "m",
            .double_quote => "\"",
            else => null,
        };
    }

    fn updateWhichKeyForPending(self: *Self) void {
        if (self.pending_keys.items.len == 1) {
            if (prefixWhichKeyLabel(self.pending_keys.items[0])) |prefix| {
                self.which_key_visible = true;
                self.which_key_prefix = prefix;
                return;
            }
        }
        self.clearWhichKey();
    }

    fn handleFloatKey(self: *Self, key: Key) !void {
        const fb = self.focusedFloat() orelse {
            self.float_mode = false;
            return;
        };
        const buf = if (fb.buf_index < self.buffers.items.len) self.buffers.items[fb.buf_index] else return;
        const inner_rows = fb.rect.rows -| 2;

        switch (key.base) {
            .escape, .lower_q => {
                self.closeTopFloat();
                return;
            },
            .lower_j, .down => {
                const max_row = buf.lineCount() -| 1;
                if (fb.cursor.row < max_row) {
                    fb.cursor.row += 1;
                    fb.cursor = buf.clampPosInsert(fb.cursor);
                    if (inner_rows > 0 and fb.cursor.row >= fb.scroll + inner_rows) {
                        fb.scroll = @min(fb.scroll + 1, buf.lineCount() -| inner_rows);
                    }
                }
            },
            .lower_k, .up => {
                if (fb.cursor.row > 0) {
                    fb.cursor.row -= 1;
                    fb.cursor = buf.clampPosInsert(fb.cursor);
                    if (fb.cursor.row < fb.scroll) fb.scroll = fb.cursor.row;
                }
            },
            .lower_g => {
                fb.scroll = 0;
                fb.cursor = .{};
            },
            .upper_g => {
                fb.cursor.row = buf.lineCount() -| 1;
                fb.cursor = buf.clampPosInsert(fb.cursor);
                fb.scroll = if (inner_rows > 0) buf.lineCount() -| inner_rows else 0;
            },
            else => {},
        }
    }

    fn handleNormalKey(self: *Self, key: Key) !void {
        const win = self.activeWindow().?;

        // Digits 1-9 begin count accumulation
        if (self.pending_input == .none) {
            const ch = key.char();
            if (ch) |c| {
                if (c >= '1' and c <= '9') {
                    self.pending_input = .repeat_count;
                    self.pending_count = c - '0';
                    self.setStatus("count: {d}", .{self.pending_count});
                    return;
                }
            }
        }

        if (key.eql(Key.init(.double_quote))) {
            self.pending_input = .register;
            self.which_key_visible = true;
            self.which_key_prefix = "\"";
            self.setStatusText("select register...");
            return;
        }

        if (key.eql(Key.init(.escape))) {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
            self.clearWhichKey();
            self.setMode(.normal);
            win.selection = null;
            win.selection_linewise = false;
            return;
        }

        try self.pending_keys.append(self.allocator, key);
        const result = keymap.lookup(&self.key_trie_root, self.pending_keys.items);

        if (result.command) |cmd| {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
            self.clearWhichKey();
            try self.executeCommand(cmd);
        } else if (!result.pending) {
            self.pending_keys.clearRetainingCapacity();
            self.pending_trie_name = "";
            self.clearWhichKey();
        } else {
            self.pending_trie_name = result.trie_name;
            self.updateWhichKeyForPending();
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
                self.pending_input = .none;
                self.pending_command = null;
                self.command_buf.clearRetainingCapacity();
            },
            .enter => {
                try self.applyNumericPrompt();
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                } else {
                    self.pending_input = .none;
                    self.pending_command = null;
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
        const cmd = self.pending_command orelse {
            self.pending_input = .none;
            return;
        };

        if (key.eql(Key.init(.escape))) {
            self.pending_input = .none;
            self.pending_command = null;
            return;
        }

        self.pending_input = .none;
        self.pending_command = null;

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
                var ascii_buf: [4]u8 = undefined;
                const target = keyInputBytes(key, &ascii_buf);
                if (target.len == 0) return;
                try self.replaceSelectionWithBytes(target);
            },
            else => {},
        }
    }

    fn handleRegisterKey(self: *Self, key: Key) !void {
        self.pending_input = .none;
        self.clearWhichKey();
        if (key.eql(Key.init(.escape))) return;
        const ch = key.char() orelse {
            self.setStatusText("Invalid register");
            return;
        };
        self.active_register = ch;
        self.setStatus("register '{c}'", .{ch});
    }

    fn handleRepeatCountKey(self: *Self, key: Key) !void {
        if (key.eql(Key.init(.escape))) {
            self.pending_input = .none;
            self.pending_count = 0;
            self.clearStatus();
            return;
        }
        const ch = key.char();
        if (ch == null or (ch.? < '0' or ch.? > '9')) {
            self.pending_input = .none;
            defer self.pending_count = 0;
            defer self.clearStatus();
            try self.handleNormalKeyWithCount(key, self.pending_count);
            return;
        }
        self.pending_count = self.pending_count * 10 + (ch.? - '0');
        self.setStatus("count: {d}", .{self.pending_count});
    }

    fn handleNormalKeyWithCount(self: *Self, key: Key, count: usize) !void {
        self.repeat_target = count;
        defer self.repeat_target = 0;
        try self.handleNormalKey(key);
    }

    fn executeFindChar(self: *Self, cmd: Command, target: u8) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;

        switch (cmd) {
            .find_next_char => {
                win.cursor = findNextChar(buf, win.cursor, target) orelse win.cursor;
            },
            .find_till_char => {
                const found = findNextChar(buf, win.cursor, target) orelse return;
                win.cursor = prevCharPosition(buf, found) orelse win.cursor;
            },
            .find_prev_char => {
                win.cursor = findPrevChar(buf, win.cursor, target) orelse win.cursor;
            },
            .till_prev_char => {
                const found = findPrevChar(buf, win.cursor, target) orelse return;
                win.cursor = nextCharPosition(buf, found) orelse win.cursor;
            },
            else => {},
        }
    }

    fn handleSearchKey(self: *Self, key: Key) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse {
            self.in_search_mode = false;
            return;
        };

        switch (key.base) {
            .escape => {
                self.in_search_mode = false;
                self.command_buf.clearRetainingCapacity();
                win.cursor = self.search_start_cursor;
            },
            .enter => {
                self.in_search_mode = false;
                if (self.command_buf.items.len > 0) {
                    try self.pushJumpPosition(self.search_start_cursor);
                    if (self.search_pattern) |p| self.allocator.free(p);
                    self.search_pattern = try self.allocator.dupe(u8, self.command_buf.items);
                    try self.writeRegister('/', self.search_pattern.?, false);
                    if (searchBuffer(buf, self.search_pattern.?, self.search_start_cursor, self.search_direction, true)) |pos| {
                        const end_pos = advancePositionByBytes(pos, self.search_pattern.?);
                        const end_cursor = prevCharPositionFromEnd(buf, pos, end_pos);
                        self.setMode(.select_);
                        win.selection_linewise = false;
                        win.selection = .{ .anchor = pos, .cursor = end_cursor };
                        win.cursor = end_cursor;
                    }
                }
                self.command_buf.clearRetainingCapacity();
            },
            .backspace => {
                if (self.command_buf.items.len > 0) {
                    _ = self.command_buf.pop();
                    if (self.command_buf.items.len > 0) {
                        self.searchJump(buf, self.command_buf.items);
                    } else {
                        win.cursor = self.search_start_cursor;
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
        const win = self.activeWindow().?;
        if (pattern.len == 0) return;
        const start = if (self.in_search_mode) self.search_start_cursor else win.cursor;
        if (searchBuffer(buf, pattern, start, self.search_direction, true)) |pos| {
            win.cursor = pos;
        }
    }

    fn executeCommandString(self: *Self, cmd: []const u8) !void {
        try self.writeRegister(':', cmd, false);

        const win = self.activeWindow().?;
        const trimmed = std.mem.trim(u8, cmd, " ");
        const split_at = std.mem.indexOfScalar(u8, trimmed, ' ');
        const name = if (split_at) |idx| trimmed[0..idx] else trimmed;
        const arg = if (split_at) |idx| std.mem.trim(u8, trimmed[idx + 1 ..], " ") else "";

        if (std.mem.eql(u8, trimmed, "w") or std.mem.eql(u8, trimmed, "write")) {
            try self.executeCommand(.save);
        } else if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "quit")) {
            try self.executeCommand(.quit);
        } else if (std.mem.eql(u8, trimmed, "q!") or std.mem.eql(u8, trimmed, "quit!")) {
            try self.executeCommand(.force_quit);
        } else if (std.mem.eql(u8, trimmed, "wq") or std.mem.eql(u8, trimmed, "x")) {
            try self.executeCommand(.save);
            try self.executeCommand(.quit);
        } else if (std.mem.eql(u8, trimmed, "qa") or std.mem.eql(u8, trimmed, "qall")) {
            var dirty_count: usize = 0;
            for (self.buffers.items) |b| {
                if (b.dirty) dirty_count += 1;
            }
            if (dirty_count > 0) {
                self.setStatus("{d} unsaved buffer(s)! Use :qa! to force quit", .{dirty_count});
            } else {
                self.should_quit = true;
            }
        } else if (std.mem.eql(u8, trimmed, "qa!") or std.mem.eql(u8, trimmed, "qall!")) {
            self.should_quit = true;
        } else if (std.mem.eql(u8, trimmed, "wa") or std.mem.eql(u8, trimmed, "wall")) {
            var saved: usize = 0;
            for (self.buffers.items) |b| {
                if (b.dirty and b.path != null) {
                    b.save(self.io) catch |err| {
                        self.setStatus("Error saving {s}: {}", .{ b.path.?, err });
                        return;
                    };
                    saved += 1;
                }
            }
            if (saved > 0) {
                self.setStatus("Saved {d} file(s)", .{saved});
            } else {
                self.setStatusText("No files to save");
            }
        } else if (std.mem.eql(u8, trimmed, "rl") or std.mem.eql(u8, trimmed, "reload")) {
            const buf = self.getBuffer() orelse {
                self.setStatusText("No buffer");
                return;
            };
            if (buf.path == null) {
                self.setStatusText("No file associated with this buffer");
                return;
            }
            buf.revertWithEncoding(self.io, buf.file_encoding) catch |err| {
                self.setStatus("Reload failed: {}", .{err});
                return;
            };
            const buf_idx = win.buf_index;
            self.resetWindowsForBuffer(buf_idx);
            self.setStatus("Reloaded: {s}", .{buf.path.?});
        } else if (std.mem.eql(u8, trimmed, "rla") or std.mem.eql(u8, trimmed, "reload-all")) {
            var reloaded: usize = 0;
            for (self.buffers.items, 0..) |buf, buf_idx| {
                if (buf.path == null) continue;
                buf.revertWithEncoding(self.io, buf.file_encoding) catch continue;
                reloaded += 1;
                self.resetWindowsForBuffer(buf_idx);
            }
            self.setStatus("Reloaded {d} file(s)", .{reloaded});
        } else if (std.mem.eql(u8, name, "o") or std.mem.eql(u8, name, "open")) {
            if (arg.len > 0) {
                try self.openFile(arg);
                self.setStatus("Opened: {s}", .{arg});
            }
        } else if (std.mem.eql(u8, name, "e") or std.mem.eql(u8, name, "edit")) {
            // :e ++enc=<name> [path]  — reload current file (or open path) with explicit encoding
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
                        win.buf_index = self.buffers.items.len - 1;
                        win.resetView();
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
                        win.resetView();
                        self.setStatus("Reloaded as {s}", .{enc.displayName()});
                    }
                } else {
                    self.setStatus("Unknown encoding: {s}", .{enc_name});
                }
            } else if (arg.len > 0) {
                try self.openFile(arg);
                self.setStatus("Opened: {s}", .{arg});
            }
        } else if (std.mem.eql(u8, name, "n") or std.mem.eql(u8, name, "new")) {
            try self.openNewBuffer();
        } else if (std.mem.eql(u8, name, "float")) {
            _ = try self.openFloatBuf("Float");
        } else if (std.mem.eql(u8, name, "floatclose") or std.mem.eql(u8, name, "fclose")) {
            self.closeTopFloat();
        } else if (std.mem.eql(u8, name, "split") or std.mem.eql(u8, name, "sp")) {
            try self.executeCommand(.hsplit);
            if (arg.len > 0) {
                try self.openFile(arg);
                self.setStatus("Opened: {s}", .{arg});
            }
        } else if (std.mem.eql(u8, name, "vsplit") or std.mem.eql(u8, name, "vs")) {
            try self.executeCommand(.vsplit);
            if (arg.len > 0) {
                try self.openFile(arg);
                self.setStatus("Opened: {s}", .{arg});
            }
        } else if (std.mem.eql(u8, name, "only")) {
            try self.executeCommand(.window_only);
        } else if (std.mem.eql(u8, name, "close")) {
            try self.executeCommand(.wclose);
        } else if (std.mem.eql(u8, name, "tabnew")) {
            try self.executeCommand(.tab_new);
        } else if (std.mem.eql(u8, name, "tabclose") or std.mem.eql(u8, name, "tabc")) {
            try self.executeCommand(.tab_close);
        } else if (std.mem.eql(u8, name, "tabnext") or std.mem.eql(u8, name, "tabn") or std.mem.eql(u8, name, "gt")) {
            try self.executeCommand(.tab_next);
        } else if (std.mem.eql(u8, name, "tabprev") or std.mem.eql(u8, name, "tabp") or std.mem.eql(u8, name, "gT")) {
            try self.executeCommand(.tab_prev);
        } else if (std.mem.eql(u8, name, "bn") or std.mem.eql(u8, name, "bnext")) {
            try self.executeCommand(.buffer_next);
        } else if (std.mem.eql(u8, name, "bp") or std.mem.eql(u8, name, "bprev")) {
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
                    if (std.mem.eql(u8, value, "unix")) .lf else if (std.mem.eql(u8, value, "dos")) .crlf else if (std.mem.eql(u8, value, "mac")) .cr else null;
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
        self.pending_input = .numeric_prompt;
        self.pending_command = cmd;
        self.command_buf.clearRetainingCapacity();
    }

    fn applyNumericPrompt(self: *Self) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const cmd = self.pending_command orelse return;
        defer {
            self.pending_input = .none;
            self.pending_command = null;
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
                try self.pushJumpPosition(win.cursor);
                win.cursor.row = @min(one_based, buf.lineCount() -| 1);
                win.cursor = buf.clampPos(win.cursor);
            },
            .goto_column => {
                try self.pushJumpPosition(win.cursor);
                win.cursor.col = one_based;
                win.cursor = if (self.mode == .insert) buf.clampPosInsert(win.cursor) else buf.clampPos(win.cursor);
            },
            else => {},
        }
    }

    fn selectedLineRange(self: *const Self) struct { start: usize, end: usize } {
        const win = self.activeWindowConst().?;
        if (win.selection) |sel| {
            const start = sel.start().row;
            const end = sel.end().row;
            return .{ .start = start, .end = end };
        }
        return .{ .start = win.cursor.row, .end = win.cursor.row };
    }

    /// Get the register name for the current operation (active or default '"')
    fn currentRegisterName(self: *const Self) u8 {
        return self.active_register orelse '"';
    }

    /// Get a pointer to the current register
    fn currentRegister(self: *Self) *Register {
        return &self.registers[self.currentRegisterName()];
    }

    /// Read text from a register. Handles read-only special registers.
    fn readRegister(self: *Self, name: u8) ?[]const u8 {
        return switch (name) {
            // Read-only registers
            '%' => blk: {
                const buf = self.getBuffer() orelse break :blk null;
                break :blk buf.path;
            },
            '.' => blk: {
                const buf = self.getBuffer() orelse break :blk null;
                const win = self.activeWindow() orelse break :blk null;
                if (win.selection == null) break :blk null;
                const range = self.selectedTextRange(buf);
                // Store in the register so it owns the memory (freed on next write or deinit)
                self.registers['.'].deinit(self.allocator);
                self.registers['.'].text = buf.copyRange(range.start, range.end) catch null;
                self.registers['.'].linewise = false;
                break :blk self.registers['.'].text;
            },
            '_' => null, // black hole — always empty on read
            // Normal registers
            else => self.registers[name].text,
        };
    }

    /// Write text to a register. Handles write-only special registers.
    fn writeRegister(self: *Self, name: u8, text: []const u8, linewise: bool) !void {
        if (name == '_') return; // black hole — discard
        if (name == '%' or name == '.' or name == '#') return; // read-only — ignore writes
        try self.registers[name].set(self.allocator, text, linewise);
    }

    fn setYankText(self: *Self, text: []const u8, linewise: bool) !void {
        const name = self.currentRegisterName();
        try self.writeRegister(name, text, linewise);
        self.active_register = null;
    }

    fn selectionIsLinewise(self: *const Self) bool {
        const win = self.activeWindowConst().?;
        return win.selection != null and win.selection_linewise;
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
        const win = self.activeWindow().?;
        if (win.selection == null) return;

        if (force_linewise or self.selectionIsLinewise()) {
            const rows = self.selectedLineRange();
            try buf.deleteLines(rows.start, rows.end + 1);
            try insertTextAsLines(buf, rows.start, bytes);
            win.cursor = .{ .row = rows.start, .col = 0 };
        } else {
            const range = self.selectedTextRange(buf);
            try buf.replaceTextRange(range.start, range.end, bytes);
            win.cursor = advancePositionByBytes(range.start, bytes);
        }

        win.selection = null;
        win.selection_linewise = false;
        self.setMode(.normal);
        win.cursor = buf.clampPos(win.cursor);
        self.adjustScroll();
    }

    fn pasteYank(self: *Self, after: bool) !void {
        defer self.active_register = null;

        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const name = self.currentRegisterName();
        const text = self.readRegister(name) orelse return;
        const linewise = self.registers[name].linewise;

        try buf.pushUndo(win.cursor);

        if (win.selection != null) {
            try self.replaceSelectionBytes(buf, text, linewise);
            self.adjustScroll();
            return;
        }

        if (linewise) {
            const insert_row = if (after) win.cursor.row + 1 else win.cursor.row;
            try insertTextAsLines(buf, insert_row, text);
            win.cursor = .{ .row = insert_row, .col = 0 };
            win.cursor = buf.clampPos(win.cursor);
            self.adjustScroll();
            return;
        }

        const insert_pos = self.pasteCharwiseInsertPosition(buf, after);
        try buf.insertBytesAt(insert_pos, text);
        win.cursor = buf.clampPos(advancePositionByBytes(insert_pos, text));
        self.adjustScroll();
    }

    fn pasteCharwiseInsertPosition(self: *const Self, buf: *Buffer, after: bool) Position {
        const win = self.activeWindowConst().?;
        const cursor = buf.clampPos(win.cursor);
        if (!after) return buf.clampPosInsert(cursor);

        const line = buf.getLine(cursor.row) orelse "";
        if (line.len == 0 or cursor.col >= line.len) {
            return .{ .row = cursor.row, .col = line.len };
        }
        return .{ .row = cursor.row, .col = buf.nextColumn(cursor.row, cursor.col) };
    }

    fn replaceSelectionWithBytes(self: *Self, target: []const u8) !void {
        const win = self.activeWindow().?;
        if (target.len == 0 or (target.len == 1 and target[0] == '\n')) return;
        const buf = self.getBuffer() orelse return;
        if (win.selection == null) {
            try buf.pushUndo(win.cursor);
            const line = buf.getLine(win.cursor.row) orelse return;
            if (win.cursor.col < line.len) {
                try buf.replaceBytesAt(win.cursor.row, win.cursor.col, target);
                self.adjustScroll();
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

        try buf.pushUndo(win.cursor);
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
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        if (win.selection == null) {
            try buf.pushUndo(win.cursor);
            const line = buf.getLine(win.cursor.row) orelse return;
            if (win.cursor.col >= line.len) return;
            try buf.replaceCharAt(win.cursor.row, win.cursor.col, applyCaseShift(line[win.cursor.col], transform));
            return;
        }

        const source = try self.copySelectionText(buf);
        defer self.allocator.free(source);

        for (source) |*ch| {
            ch.* = applyCaseShift(ch.*, transform);
        }

        try buf.pushUndo(win.cursor);
        try self.replaceSelectionBytes(buf, source, self.selectionIsLinewise());
    }

    fn linewiseSelectionForRows(self: *Self, start_row: usize, end_row: usize, buf: *Buffer) void {
        const win = self.activeWindow().?;
        self.setMode(.select_);
        win.selection_linewise = true;
        win.selection = .{
            .anchor = .{ .row = start_row, .col = 0 },
            .cursor = .{ .row = end_row, .col = buf.lineLen(end_row) },
        };
        win.cursor = win.selection.?.cursor;
    }

    fn selectedTextRange(self: *const Self, buf: *Buffer) struct { start: Position, end: Position } {
        const win = self.activeWindowConst().?;
        if (win.selection) |sel| {
            const start = sel.start();
            var end = sel.end();
            const line_len = buf.lineLen(end.row);
            if (!sel.isCollapsed() and end.col < line_len) {
                end.col += 1;
            }
            return .{ .start = start, .end = buf.clampPosInsert(end) };
        }

        const line = buf.getLine(win.cursor.row) orelse "";
        if (line.len == 0) {
            return .{ .start = win.cursor, .end = win.cursor };
        }

        var pivot = win.cursor.col;
        if (pivot >= line.len and pivot > 0) pivot -= 1;
        if (pivot < line.len and isWordChar(line[pivot])) {
            var start_col = pivot;
            var end_col = pivot + 1;
            while (start_col > 0 and isWordChar(line[start_col - 1])) : (start_col -= 1) {}
            while (end_col < line.len and isWordChar(line[end_col])) : (end_col += 1) {}
            return .{
                .start = .{ .row = win.cursor.row, .col = start_col },
                .end = .{ .row = win.cursor.row, .col = end_col },
            };
        }

        if (win.cursor.col < line.len) {
            return .{
                .start = win.cursor,
                .end = .{ .row = win.cursor.row, .col = win.cursor.col + 1 },
            };
        }

        return .{
            .start = .{ .row = win.cursor.row, .col = win.cursor.col -| 1 },
            .end = win.cursor,
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
        const win = self.activeWindow().?;
        const end_cursor = prevCharPositionFromEnd(buf, match.start, match.end);
        self.setMode(.select_);
        win.selection_linewise = false;
        win.selection = .{
            .anchor = match.start,
            .cursor = end_cursor,
        };
        win.cursor = end_cursor;
    }

    fn applySurroundAdd(self: *Self, target: u8) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const pair = surroundPairFor(target) orelse {
            self.setStatus("Unsupported surround: {c}", .{target});
            return;
        };
        const range = self.selectedTextRange(buf);
        try buf.pushUndo(win.cursor);
        try buf.insertCharAt(buf.clampPosInsert(range.end), pair.close);
        try buf.insertCharAt(buf.clampPosInsert(range.start), pair.open);
        win.cursor = buf.clampPos(.{ .row = range.start.row, .col = range.start.col + 1 });
        self.adjustScroll();
    }

    fn applySurroundReplace(self: *Self, target: u8) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const pair = surroundPairFor(target) orelse {
            self.setStatus("Unsupported surround: {c}", .{target});
            return;
        };
        const match = self.findSurroundMatch(buf) orelse {
            self.setStatusText("No surrounding delimiters found");
            return;
        };
        try buf.pushUndo(win.cursor);
        try buf.replaceCharAt(match.open_pos.row, match.open_pos.col, pair.open);
        try buf.replaceCharAt(match.close_pos.row, match.close_pos.col, pair.close);
    }

    fn applySurroundDelete(self: *Self) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const match = self.findSurroundMatch(buf) orelse {
            self.setStatusText("No surrounding delimiters found");
            return;
        };
        try buf.pushUndo(win.cursor);
        _ = try buf.deleteCharAt(.{ .row = match.close_pos.row, .col = match.close_pos.col + 1 });
        _ = try buf.deleteCharAt(.{ .row = match.open_pos.row, .col = match.open_pos.col + 1 });
        win.cursor = buf.clampPos(match.open_pos);
        self.adjustScroll();
    }

    fn findSurroundMatch(self: *const Self, buf: *Buffer) ?SurroundMatch {
        const win = self.activeWindowConst().?;
        if (win.selection) |sel| {
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

        if (findBracketMatchAtOrBefore(buf, win.cursor)) |match| return match;

        const line = buf.getLine(win.cursor.row) orelse return null;
        if (win.cursor.col > 0 and win.cursor.col < line.len) {
            const left_pos = Position{ .row = win.cursor.row, .col = win.cursor.col - 1 };
            const right_pos = Position{ .row = win.cursor.row, .col = win.cursor.col };
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

    fn deleteCurrentLine(self: *Self, yank: bool) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const line = buf.getLine(win.cursor.row) orelse "";
        if (yank) try self.setYankText(line, true);

        try buf.pushUndo(win.cursor);
        try buf.deleteLine(win.cursor.row);
        win.selection = null;
        win.selection_linewise = false;
        self.setMode(.normal);
        win.cursor = .{ .row = @min(win.cursor.row, buf.lineCount() -| 1), .col = 0 };
        win.cursor = buf.clampPos(win.cursor);
        self.adjustScroll();
    }

    fn deleteSelection(self: *Self, yank: bool) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;

        if (win.selection) |_| {
            if (yank) {
                const text = try self.copySelectionText(buf);
                defer self.allocator.free(text);
                try self.setYankText(text, self.selectionIsLinewise());
            }

            try buf.pushUndo(win.cursor);
            if (self.selectionIsLinewise()) {
                const rows = self.selectedLineRange();
                try buf.deleteLines(rows.start, rows.end + 1);
                win.cursor = .{ .row = @min(rows.start, buf.lineCount() -| 1), .col = 0 };
            } else {
                const range = self.selectedTextRange(buf);
                try buf.replaceTextRange(range.start, range.end, "");
                win.cursor = range.start;
            }
            win.selection = null;
            win.selection_linewise = false;
            self.setMode(.normal);
            win.cursor = buf.clampPos(win.cursor);
            self.adjustScroll();
            return;
        }

        try buf.pushUndo(win.cursor);
        const line = buf.getLine(win.cursor.row) orelse return;
        if (line.len > 0) {
            const ch = buf.charSliceAt(win.cursor) orelse return;
            if (yank) {
                try self.setYankText(ch, false);
            }
            _ = try buf.deleteCharAt(.{ .row = win.cursor.row, .col = win.cursor.col + 1 });
            win.cursor = buf.clampPos(win.cursor);
        } else if (buf.lineCount() > 1) {
            if (yank) {
                try self.setYankText("\n", true);
            }
            try buf.deleteLine(win.cursor.row);
            win.cursor = buf.clampPos(win.cursor);
        }
        self.adjustScroll();
    }

    fn executeCommand(self: *Self, cmd: Command) !void {
        const win = self.activeWindow().?;
        const buf = self.getBuffer() orelse return;
        const count = @max(self.repeat_target, 1);

        switch (cmd) {
            .move_char_left => {
                for (0..count) |_| {
                    if (win.cursor.col > 0) win.cursor.col = buf.prevColumn(win.cursor.row, win.cursor.col);
                }
            },
            .move_char_right => {
                for (0..count) |_| {
                    const line_len = buf.lineLen(win.cursor.row);
                    if (win.cursor.col < line_len) win.cursor.col = buf.nextColumn(win.cursor.row, win.cursor.col);
                    if (self.mode == .normal and win.cursor.col >= line_len) win.cursor.col = normalLineEndCol(buf, win.cursor.row);
                }
            },
            .move_visual_line_down, .move_line_down => {
                win.cursor.row = @min(win.cursor.row + count, buf.lineCount() -| 1);
                win.cursor = buf.clampPos(win.cursor);
            },
            .move_visual_line_up, .move_line_up => {
                win.cursor.row = win.cursor.row -| count;
                win.cursor = buf.clampPos(win.cursor);
            },
            .move_next_word_start => {
                for (0..count) |_| {
                    const line = buf.getLine(win.cursor.row) orelse "";
                    var col = win.cursor.col;
                    while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                    while (col < line.len and isWordChar(line[col])) : (col += 1) {}
                    while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                    if (col >= line.len and win.cursor.row < buf.lineCount() -| 1) {
                        win.cursor.row += 1;
                        win.cursor.col = 0;
                        const next = buf.getLine(win.cursor.row) orelse "";
                        while (win.cursor.col < next.len and next[win.cursor.col] == ' ') : (win.cursor.col += 1) {}
                    } else {
                        // Helix selection model: cursor at end of selection (char before word start)
                        win.cursor.col = if (col >= line.len) normalLineEndCol(buf, win.cursor.row) else if (col > 0) col - 1 else 0;
                    }
                }
            },
            .move_prev_word_start => {
                for (0..count) |_| {
                    const line = buf.getLine(win.cursor.row) orelse "";
                    if (win.cursor.col == 0) {
                        if (win.cursor.row > 0) {
                            win.cursor.row -= 1;
                            win.cursor.col = normalLineEndCol(buf, win.cursor.row);
                        }
                    } else {
                        var col = win.cursor.col;
                        while (col > 0 and !isWordChar(line[col - 1])) : (col -= 1) {}
                        while (col > 0 and isWordChar(line[col - 1])) : (col -= 1) {}
                        win.cursor.col = col;
                    }
                }
            },
            .move_next_word_end => {
                const line = buf.getLine(win.cursor.row) orelse "";
                var col = win.cursor.col + 1;
                while (col < line.len and !isWordChar(line[col])) : (col += 1) {}
                while (col < line.len and isWordChar(line[col])) : (col += 1) {}
                win.cursor.col = if (col == 0) 0 else if (col >= line.len) normalLineEndCol(buf, win.cursor.row) else buf.prevColumn(win.cursor.row, col);
            },
            .move_next_long_word_start => {
                // WORD motion: skip to next whitespace-delimited word start
                for (0..count) |_| {
                    const line = buf.getLine(win.cursor.row) orelse "";
                    var col = win.cursor.col;
                    while (col < line.len and line[col] != ' ') : (col += 1) {} // skip current WORD
                    while (col < line.len and line[col] == ' ') : (col += 1) {} // skip spaces
                    if (col >= line.len and win.cursor.row < buf.lineCount() -| 1) {
                        win.cursor.row += 1;
                        win.cursor.col = 0;
                        const next = buf.getLine(win.cursor.row) orelse "";
                        while (win.cursor.col < next.len and next[win.cursor.col] == ' ') : (win.cursor.col += 1) {}
                    } else {
                        win.cursor.col = if (col >= line.len) normalLineEndCol(buf, win.cursor.row) else if (col > 0) col - 1 else 0;
                    }
                }
            },
            .move_prev_long_word_start => {
                // WORD motion: skip to previous whitespace-delimited word start
                for (0..count) |_| {
                    const line = buf.getLine(win.cursor.row) orelse "";
                    if (win.cursor.col == 0) {
                        if (win.cursor.row > 0) {
                            win.cursor.row -= 1;
                            win.cursor.col = normalLineEndCol(buf, win.cursor.row);
                        }
                    } else {
                        var col = win.cursor.col;
                        while (col > 0 and line[col - 1] == ' ') : (col -= 1) {} // skip spaces
                        while (col > 0 and line[col - 1] != ' ') : (col -= 1) {} // skip WORD
                        win.cursor.col = col;
                    }
                }
            },
            .move_next_long_word_end => {
                // WORD motion: skip to next whitespace-delimited word end
                for (0..count) |_| {
                    const line = buf.getLine(win.cursor.row) orelse "";
                    var col = win.cursor.col + 1;
                    while (col < line.len and line[col] == ' ') : (col += 1) {} // skip spaces
                    while (col < line.len and line[col] != ' ') : (col += 1) {} // skip WORD
                    win.cursor.col = if (col == 0) 0 else if (col >= line.len) normalLineEndCol(buf, win.cursor.row) else buf.prevColumn(win.cursor.row, col);
                }
            },
            .goto_line_start => win.cursor.col = 0,
            .goto_line_end => {
                win.cursor.col = normalLineEndCol(buf, win.cursor.row);
            },
            .goto_first_nonwhitespace => {
                const line = buf.getLine(win.cursor.row) orelse "";
                var col: usize = 0;
                while (col < line.len and (line[col] == ' ' or line[col] == '\t')) : (col += 1) {}
                win.cursor.col = if (col < line.len) col else if (line.len > 0) line.len - 1 else @as(usize, 0);
            },
            .goto_file_start => {
                win.resetView();
            },
            .goto_last_line => {
                win.cursor.row = buf.lineCount() -| 1;
                win.cursor = buf.clampPos(win.cursor);
            },
            .goto_line => self.beginNumericPrompt(.goto_line),
            .goto_column => self.beginNumericPrompt(.goto_column),
            .goto_window_top => {
                win.cursor.row = win.scroll;
                win.cursor = buf.clampPos(win.cursor);
            },
            .goto_window_center => {
                win.cursor.row = win.scroll + (self.visibleRows()) / 2;
                win.cursor = buf.clampPos(win.cursor);
            },
            .goto_window_bottom => {
                win.cursor.row = win.scroll + (self.visibleRows() -| 1);
                win.cursor = buf.clampPos(win.cursor);
            },

            .insert_mode => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                win.cursor = buf.clampPosInsert(win.cursor);
            },
            .insert_at_line_start => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                win.cursor.col = 0;
            },
            .insert_at_line_end => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                win.cursor.col = buf.lineLen(win.cursor.row);
            },
            .append_mode => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                if (buf.lineLen(win.cursor.row) > 0) win.cursor.col = buf.nextColumn(win.cursor.row, win.cursor.col);
                win.cursor = buf.clampPosInsert(win.cursor);
            },
            .open_below_with_indent => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                const indent = buf.getAutoIndent(win.cursor.row);
                try buf.insertLine(win.cursor.row + 1, indent);
                win.cursor.row += 1;
                win.cursor.col = indent.len;
                win.cursor = buf.clampPosInsert(win.cursor);
            },
            .open_above_with_indent => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                const indent = buf.getAutoIndent(win.cursor.row);
                try buf.insertLine(win.cursor.row, indent);
                win.cursor.col = indent.len;
                win.cursor = buf.clampPosInsert(win.cursor);
            },
            .open_below => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                try buf.insertLine(win.cursor.row + 1, "");
                win.cursor.row += 1;
                win.cursor.col = 0;
            },
            .open_above => {
                try buf.pushUndo(win.cursor);
                self.setMode(.insert);
                try buf.insertLine(win.cursor.row, "");
                win.cursor.col = 0;
            },
            .normal_mode => {
                self.setMode(.normal);
                win.selection = null;
                win.selection_linewise = false;
                win.cursor = buf.clampPos(win.cursor);
                if (win.cursor.col >= buf.lineLen(win.cursor.row)) win.cursor.col = normalLineEndCol(buf, win.cursor.row);
            },
            .select_mode => {
                self.setMode(.select_);
                win.selection_linewise = false;
                win.selection = Selection.init(win.cursor);
            },

            .delete_selection => try self.deleteSelection(true),
            .delete_selection_noyank => try self.deleteSelection(false),
            .delete_current_line => try self.deleteCurrentLine(true),
            .delete_current_line_noyank => try self.deleteCurrentLine(false),
            .change_selection => try self.changeSelection(true),
            .change_selection_noyank => try self.changeSelection(false),
            .change_current_line, .change_current_line_noyank => {
                try self.deleteCurrentLine(cmd == .change_current_line);
                self.setMode(.insert);
                win.cursor = buf.clampPosInsert(win.cursor);
            },
            .yank_current_line => {
                const line = buf.getLine(win.cursor.row) orelse "";
                try self.setYankText(line, true);
            },
            .yank => {
                if (win.selection != null) {
                    const text = try self.copySelectionText(buf);
                    defer self.allocator.free(text);
                    try self.setYankText(text, self.selectionIsLinewise());
                    win.selection = null;
                    win.selection_linewise = false;
                    self.setMode(.normal);
                } else {
                    const line = buf.getLine(win.cursor.row) orelse return;
                    if (line.len > 0 and win.cursor.col < line.len) {
                        const ch = buf.charSliceAt(win.cursor) orelse return;
                        try self.setYankText(ch, false);
                    } else {
                        try self.setYankText(line, false);
                    }
                }
            },
            .paste_after => try self.pasteYank(true),
            .paste_before => try self.pasteYank(false),
            .undo => {
                if (try buf.undo(win.cursor)) |pos| {
                    win.cursor = pos;
                }
            },
            .redo => {
                if (try buf.redo(win.cursor)) |pos| {
                    win.cursor = pos;
                }
            },
            .jump_back => {
                if (self.jump_index > 0) {
                    // Save current position if at end of list
                    if (self.jump_index >= self.jump_list.items.len) {
                        try self.jump_list.append(self.allocator, win.cursor);
                    } else {
                        self.jump_list.items[self.jump_index] = win.cursor;
                    }
                    self.jump_index -= 1;
                    win.cursor = self.jump_list.items[self.jump_index];
                    win.cursor = buf.clampPos(win.cursor);
                    self.adjustScroll();
                }
            },
            .jump_forward => {
                if (self.jump_index < self.jump_list.items.len) {
                    self.jump_list.items[self.jump_index] = win.cursor;
                    self.jump_index += 1;
                    if (self.jump_index < self.jump_list.items.len) {
                        win.cursor = self.jump_list.items[self.jump_index];
                    }
                    win.cursor = buf.clampPos(win.cursor);
                    self.adjustScroll();
                }
            },
            .earlier => self.setStatusText("Earlier history is not available in this editor yet"),
            .later => self.setStatusText("Later history is not available in this editor yet"),
            .find_till_char, .find_next_char, .till_prev_char, .find_prev_char => {
                self.pending_input = .char_pending;
                self.pending_command = cmd;
            },
            .repeat_last_motion => {
                if (self.last_find_char) |target| {
                    if (self.last_find_command) |find_cmd| {
                        try self.executeFindChar(find_cmd, target);
                    }
                }
            },
            .replace => {
                self.pending_input = .char_pending;
                self.pending_command = .replace;
            },
            .replace_with_yanked => {
                defer self.active_register = null;
                const name = self.currentRegisterName();
                const text = self.readRegister(name) orelse "";
                const linewise = self.registers[name].linewise;
                if (text.len > 0) {
                    try buf.pushUndo(win.cursor);
                    if (win.selection != null) {
                        try self.replaceSelectionBytes(buf, text, linewise);
                    } else {
                        const range = self.selectedTextRange(buf);
                        try buf.replaceTextRange(range.start, range.end, text);
                        win.cursor = buf.clampPos(advancePositionByBytes(range.start, text));
                    }
                }
            },
            .switch_case => try self.transformSelectionCase(.toggle),
            .switch_to_lowercase => try self.transformSelectionCase(.lower),
            .switch_to_uppercase => try self.transformSelectionCase(.upper),
            .extend_line_below => {
                if (win.selection != null) {
                    const rows = self.selectedLineRange();
                    self.linewiseSelectionForRows(rows.start, @min(rows.end + 1, buf.lineCount() -| 1), buf);
                } else {
                    self.linewiseSelectionForRows(win.cursor.row, win.cursor.row, buf);
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
                win.selection = null;
                win.selection_linewise = false;
                self.setMode(.normal);
            },
            .flip_selections => {
                if (win.selection) |sel| {
                    win.cursor = sel.anchor;
                    win.selection = Selection{ .anchor = sel.cursor, .cursor = sel.anchor };
                }
            },
            .copy_selection_on_next_line => {
                try buf.pushUndo(win.cursor);
                const line = buf.getLine(win.cursor.row) orelse return;
                try buf.insertLine(win.cursor.row + 1, line);
                win.cursor.row += 1;
            },
            .copy_selection_on_prev_line => {
                try buf.pushUndo(win.cursor);
                const line = buf.getLine(win.cursor.row) orelse return;
                try buf.insertLine(win.cursor.row, line);
            },
            .keep_primary_selection => self.setStatusText("Primary selection filtering needs multi-selection support"),
            .remove_primary_selection => self.setStatusText("Primary selection removal needs multi-selection support"),
            .search, .rsearch => {
                self.in_search_mode = true;
                self.search_direction = if (cmd == .search) .forward else .backward;
                self.search_start_cursor = win.cursor;
                self.command_buf.clearRetainingCapacity();
            },
            .search_next, .search_prev => {
                if (self.search_pattern) |pattern| {
                    if (pattern.len > 0) {
                        const direction: SearchDirection = if (cmd == .search_next)
                            self.search_direction
                        else if (self.search_direction == .forward) .backward else .forward;
                        const start = advanceSearchPosition(buf, win.cursor, direction) orelse win.cursor;
                        if (searchMatch(buf, pattern, start, direction, false)) |match| {
                            self.selectSearchMatch(buf, match);
                        }
                    }
                }
            },
            .match_brackets => {
                if (findBracketMatchAtOrBefore(buf, win.cursor)) |match| {
                    if (match.open_pos.eql(win.cursor)) {
                        win.cursor = match.close_pos;
                    } else if (match.close_pos.eql(win.cursor)) {
                        win.cursor = match.open_pos;
                    } else if (match.open_pos.lessThan(win.cursor)) {
                        win.cursor = match.close_pos;
                    } else {
                        win.cursor = match.open_pos;
                    }
                } else {
                    self.setStatusText("No matching bracket found");
                }
            },
            .surround_add, .surround_replace => {
                self.pending_input = .char_pending;
                self.pending_command = cmd;
            },
            .surround_delete => try self.applySurroundDelete(),
            .indent => {
                try buf.pushUndo(win.cursor);
                try buf.replaceLinePrefix(win.cursor.row, "    ", 0);
                win.cursor.col += 4;
            },
            .unindent => {
                try buf.pushUndo(win.cursor);
                const line = buf.getLine(win.cursor.row) orelse return;
                var remove: usize = 0;
                while (remove < 4 and remove < line.len and line[remove] == ' ') : (remove += 1) {}
                if (remove > 0) {
                    try buf.setLine(win.cursor.row, line[remove..]);
                    win.cursor.col = win.cursor.col -| remove;
                }
            },
            .format_selections => {
                const rows = self.selectedLineRange();
                var changed = false;
                try buf.pushUndo(win.cursor);
                var row = rows.start;
                while (row <= rows.end) : (row += 1) {
                    const line = buf.getLine(row) orelse continue;
                    var end = line.len;
                    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
                    if (end != line.len) {
                        try buf.setLine(row, line[0..end]);
                        changed = true;
                        if (win.cursor.row == row and win.cursor.col > end) {
                            win.cursor.col = end;
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
                try buf.pushUndo(win.cursor);
                if (win.cursor.row < buf.lineCount() -| 1) {
                    try buf.joinLines(win.cursor.row);
                }
            },
            .page_up => {
                const page_size = self.visibleRows();
                win.scroll = win.scroll -| page_size;
                win.cursor.row = win.scroll;
                win.cursor = buf.clampPos(win.cursor);
            },
            .page_down => {
                const page_size = self.visibleRows();
                win.scroll += page_size;
                win.cursor.row = @min(win.scroll + page_size -| 1, buf.lineCount() -| 1);
                win.cursor = buf.clampPos(win.cursor);
            },
            .page_cursor_half_up => {
                const visible_rows = self.visibleRows();
                const half = visible_rows / 2;
                win.cursor.row = win.cursor.row -| half;
                win.scroll = win.scroll -| half;
                win.cursor = buf.clampPos(win.cursor);
            },
            .page_cursor_half_down => {
                const visible_rows = self.visibleRows();
                const half = visible_rows / 2;
                win.cursor.row = @min(win.cursor.row + half, buf.lineCount() -| 1);
                win.scroll = @min(win.scroll + half, buf.lineCount() -| visible_rows);
                win.cursor = buf.clampPos(win.cursor);
            },
            .scroll_cursor_center => {
                const visible_rows = self.visibleRows();
                win.scroll = @min(win.cursor.row -| (visible_rows / 2), buf.lineCount() -| visible_rows);
            },
            .scroll_cursor_top => {
                const visible_rows = self.visibleRows();
                win.scroll = @min(win.cursor.row, buf.lineCount() -| visible_rows);
            },
            .scroll_cursor_bottom => {
                const visible_rows = self.visibleRows();
                win.scroll = @min(win.cursor.row -| (visible_rows -| 1), buf.lineCount() -| visible_rows);
            },
            .rotate_view => {
                const tab = self.activeTab() orelse return;
                if (tab.windows.items.len > 1) {
                    tab.active_window = (tab.active_window + 1) % tab.windows.items.len;
                }
                self.adjustScroll();
                return;
            },
            .hsplit, .vsplit => {
                const tab = self.activeTab() orelse return;
                const active = tab.activeWindow() orelse return;
                const dir: window_mod.SplitDir = if (cmd == .hsplit) .horizontal else .vertical;

                // Resize the active window immediately to make room for the new pane.
                // The new pane gets the remaining space after the divider.
                var new_rect: window_mod.Rect = undefined;
                switch (dir) {
                    .vertical => {
                        const old_cols = active.rect.cols;
                        const half_cols = old_cols / 2;
                        active.rect.cols = half_cols;
                        new_rect = .{
                            .top = active.rect.top,
                            .left = active.rect.left + half_cols + 1,
                            .rows = active.rect.rows,
                            .cols = old_cols -| half_cols -| 1,
                        };
                    },
                    .horizontal => {
                        const old_rows = active.rect.rows;
                        const half_rows = old_rows / 2;
                        active.rect.rows = half_rows;
                        new_rect = .{
                            .top = active.rect.top + half_rows + 1,
                            .left = active.rect.left,
                            .rows = old_rows -| half_rows -| 1,
                            .cols = active.rect.cols,
                        };
                    },
                }

                const new_win = Window{
                    .buf_index = active.buf_index,
                    .cursor = active.cursor,
                    .scroll = active.scroll,
                    .scroll_col = active.scroll_col,
                    .selection = active.selection,
                    .selection_linewise = active.selection_linewise,
                    .split_dir = dir,
                    .rect = new_rect,
                };
                try tab.windows.append(self.allocator, new_win);
                tab.active_window = tab.windows.items.len - 1;
                self.adjustScroll();
                return;
            },
            .wclose => {
                const tab = self.activeTab() orelse return;
                if (tab.windows.items.len <= 1) {
                    self.should_quit = true;
                } else {
                    _ = tab.windows.orderedRemove(tab.active_window);
                    if (tab.active_window >= tab.windows.items.len and tab.active_window > 0) {
                        tab.active_window -= 1;
                    }
                }
                self.adjustScroll();
                return;
            },
            .focus_window_left, .focus_window_up => {
                const tab = self.activeTab() orelse return;
                if (tab.active_window > 0) tab.active_window -= 1;
                self.adjustScroll();
                return;
            },
            .focus_window_right, .focus_window_down => {
                const tab = self.activeTab() orelse return;
                if (tab.active_window + 1 < tab.windows.items.len) tab.active_window += 1;
                self.adjustScroll();
                return;
            },
            .window_only => {
                const tab = self.activeTab() orelse return;
                const kept = tab.windows.items[tab.active_window];
                tab.windows.clearRetainingCapacity();
                try tab.windows.append(self.allocator, kept);
                tab.active_window = 0;
                self.adjustScroll();
                return;
            },
            .tab_new => {
                var new_tab = Tab.init(self.allocator);
                errdefer new_tab.deinit();
                const new_buf = try Buffer.init(self.allocator);
                try self.buffers.append(self.allocator, new_buf);
                const buf_idx = self.buffers.items.len - 1;
                try new_tab.windows.append(self.allocator, .{ .buf_index = buf_idx });
                try self.tabs.append(self.allocator, new_tab);
                self.current_tab = self.tabs.items.len - 1;
                self.adjustScroll();
                return;
            },
            .tab_close => {
                if (self.tabs.items.len <= 1) {
                    self.should_quit = true;
                } else {
                    self.tabs.items[self.current_tab].deinit();
                    _ = self.tabs.orderedRemove(self.current_tab);
                    if (self.current_tab >= self.tabs.items.len and self.current_tab > 0) {
                        self.current_tab -= 1;
                    }
                }
                self.adjustScroll();
                return;
            },
            .tab_next => {
                if (self.tabs.items.len > 1) {
                    self.current_tab = (self.current_tab + 1) % self.tabs.items.len;
                }
                self.adjustScroll();
                return;
            },
            .tab_prev => {
                if (self.tabs.items.len > 1) {
                    self.current_tab = if (self.current_tab > 0) self.current_tab - 1 else self.tabs.items.len - 1;
                }
                self.adjustScroll();
                return;
            },
            .float_open => {
                _ = try self.openFloatBuf("Float");
                return;
            },
            .float_close => {
                self.closeTopFloat();
                return;
            },
            .which_key_cheatsheet => {
                self.openCheatsheetFloat() catch |err| {
                    self.setStatus("Error opening cheatsheet: {any}", .{err});
                    return;
                };
                return;
            },
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
            .buffer_next, .buffer_prev => {
                if (self.buffers.items.len > 1) {
                    win.buf_index = if (cmd == .buffer_next)
                        (win.buf_index + 1) % self.buffers.items.len
                    else if (win.buf_index > 0) win.buf_index - 1 else self.buffers.items.len - 1;
                    win.resetView();
                }
            },
            .no_op => {},
        }

        if (self.mode == .select_) {
            if (win.selection) |sel| {
                win.selection = .{ .anchor = sel.anchor, .cursor = win.cursor };
            }
        }

        self.adjustScroll();
    }

    const MAX_JUMP_LIST = 100;

    fn pushJumpPosition(self: *Self, pos: Position) !void {
        if (self.jump_list.items.len > 0 and self.jump_index > 0) {
            const last = self.jump_list.items[self.jump_index - 1];
            if (last.row == pos.row and last.col == pos.col) return;
        }
        if (self.jump_index < self.jump_list.items.len) {
            self.jump_list.items.len = self.jump_index;
        }
        if (self.jump_list.items.len >= MAX_JUMP_LIST) {
            _ = self.jump_list.orderedRemove(0);
            self.jump_index -|= 1;
        }
        try self.jump_list.append(self.allocator, pos);
        self.jump_index = self.jump_list.items.len;
    }

    fn adjustScroll(self: *Self) void {
        const win = self.activeWindow().?;
        const visible_rows = self.visibleRows();
        if (win.cursor.row < win.scroll) {
            win.scroll = win.cursor.row;
        } else if (visible_rows > 0 and win.cursor.row >= win.scroll + visible_rows) {
            win.scroll = win.cursor.row - visible_rows + 1;
        }

        const buf = self.getBuffer() orelse {
            win.scroll_col = 0;
            return;
        };
        const text_start = utf8.lineWidth(buf.lineCount()) + 3;
        const visible_cols = self.terminal.size.cols -| text_start;
        const cursor_display_col = utf8.displayCellsToColumnFromBuf(buf, win.cursor.row, win.cursor.col);
        if (cursor_display_col < win.scroll_col) {
            win.scroll_col = cursor_display_col;
        } else if (visible_cols == 0 or cursor_display_col >= win.scroll_col + visible_cols) {
            win.scroll_col = cursor_display_col -| (visible_cols -| 1);
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
        ')' => .{ .open = '(', .close = ')' },
        ']' => .{ .open = '[', .close = ']' },
        '}' => .{ .open = '{', .close = '}' },
        '>' => .{ .open = '<', .close = '>' },
        '\'', '"', '`' => .{ .open = ch, .close = ch },
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

fn keyInputBytes(key: Key, ascii_buf: *[4]u8) []const u8 {
    const utf8_bytes = key.getBytes();
    if (utf8_bytes.len > 0) {
        @memcpy(ascii_buf[0..utf8_bytes.len], utf8_bytes);
        return ascii_buf[0..utf8_bytes.len];
    }
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
            const seq_len = utf8.boundary(bytes).sequenceLen(i);
            pos.col += seq_len;
            i += seq_len;
        }
    }
    return pos;
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
        .io = std.Io.Threaded.global_single_threaded.io(),
        .terminal = .{
            .nc_ptr = undefined,
            .stdplane = undefined,
            .size = .{ .rows = 24, .cols = 80 },
            .io = std.Io.Threaded.global_single_threaded.io(),
            .saved_termios = null,
            .nc_timeout_count = 0,
        },
        .buffers = .empty,
        .tabs = .empty,
        .current_tab = 0,
        .float_bufs = .empty,
        .float_mode = false,
        .mode = .insert,
        .pending_keys = .empty,
        .pending_trie_name = "",
        .which_key_visible = false,
        .which_key_prefix = "",
        .key_trie_root = keymap.normalKeymap(),
        .status_msg = null,
        .command_buf = .empty,
        .in_command_mode = false,
        .should_quit = false,
        .registers = [_]Editor.Register{.{}} ** Editor.NUM_REGISTERS,
        .active_register = null,
        .search_pattern = null,
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
        .grammar_name = null,
        .highlight_worker = null,
        .cached_hl_styles = null,
        .last_hl_buf_version = std.math.maxInt(u64),
        .last_hl_scroll = std.math.maxInt(usize),
        .src_cache = .empty,
        .src_cache_version = std.math.maxInt(u64),
        .render_style_buf = .empty,
    };
    const buf = try Buffer.initStrategy(allocator, .gap_buffer, initial);
    errdefer buf.deinit();
    try editor.buffers.append(allocator, buf);

    var first_tab = Tab.init(allocator);
    errdefer first_tab.deinit();
    try first_tab.windows.append(allocator, .{ .buf_index = 0, .rect = .{} });
    try editor.tabs.append(allocator, first_tab);
    return editor;
}

fn deinitTestEditor(editor: *Editor) void {
    for (editor.tabs.items) |*tab| tab.deinit();
    editor.tabs.deinit(editor.allocator);
    editor.float_bufs.deinit(editor.allocator);
    for (editor.buffers.items) |buf| buf.deinit();
    editor.buffers.deinit(editor.allocator);
    editor.pending_keys.deinit(editor.allocator);
    editor.jump_list.deinit(editor.allocator);
    editor.command_buf.deinit(editor.allocator);
    for (&editor.registers) |*reg| reg.deinit(editor.allocator);
    if (editor.search_pattern) |p| editor.allocator.free(p);
    if (editor.status_msg) |m| editor.allocator.free(m);
    if (editor.cached_hl_styles) |s| editor.allocator.free(s);
    editor.src_cache.deinit(editor.allocator);
    editor.render_style_buf.deinit(editor.allocator);
}

fn expectEditorBufferText(editor: *Editor, expected: []const u8) !void {
    const buf = editor.getBuffer() orelse return error.TestUnexpectedResult;
    var actual: std.ArrayList(u8) = .empty;
    defer actual.deinit(editor.allocator);
    try buf.text.writeToBuf(editor.allocator, &actual);
    try std.testing.expectEqualStrings(expected, actual.items);
}

fn expectYankText(editor: *Editor, expected: []const u8) !void {
    const actual = editor.registers['"'].text orelse return error.TestUnexpectedResult;
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
    try std.testing.expectEqual(Position{ .row = 0, .col = expected.len }, editor.activeWindow().?.cursor);
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
    try std.testing.expectEqual(Position{ .row = 0, .col = omega.len }, editor.activeWindow().?.cursor);
}

test "handleInsertKey ignores modified printable keys" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    try editor.handleInsertKey(Key.initCtrl(.lower_a));
    try editor.handleInsertKey(Key.initAlt(.lower_x));
    try editor.handleInsertKey(Key.init(.lower_b));

    try expectEditorBufferText(&editor, "b");
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);
}

test "handleInsertKey tab inserts four spaces and escape restores normal cursor state" {
    var editor = try initTestEditor("abc\ndef");
    defer deinitTestEditor(&editor);

    editor.activeWindow().?.cursor = .{ .row = 1, .col = 3 };
    try editor.handleInsertKey(Key.init(.tab));
    try expectEditorBufferText(&editor, "abc\ndef    ");
    try std.testing.expectEqual(Position{ .row = 1, .col = 7 }, editor.activeWindow().?.cursor);

    editor.activeWindow().?.scroll = 2;
    try editor.handleInsertKey(Key.init(.escape));
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expectEqual(@as(usize, 6), editor.activeWindow().?.cursor.col);
    try std.testing.expectEqual(@as(usize, 1), editor.activeWindow().?.scroll);
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
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 0 };

    try editor.executeCommand(.paste_after);

    try expectEditorBufferText(&editor, "aXb");
}

test "charwise paste_before inserts before the current grapheme" {
    var editor = try initTestEditor("ab");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("X", false);
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.paste_before);

    try expectEditorBufferText(&editor, "aXb");
}

test "charwise paste_before keeps UTF-8 and multiline inserts aligned" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("界\nZ", false);
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.paste_before);

    try expectEditorBufferText(&editor, "A界\nZ你B");
    try std.testing.expectEqual(Position{ .row = 1, .col = 1 }, editor.activeWindow().?.cursor);
}

test "delete_selection_noyank deletes without replacing yank register" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.activeWindow().?.cursor.col = 1;
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

    editor.activeWindow().?.cursor.col = 1;
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
    editor.activeWindow().?.cursor.col = 1;

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
    editor.activeWindow().?.cursor.col = 1;

    try editor.executeCommand(.change_selection_noyank);
    try editor.handleInsertKey(Key.init(.lower_x));
    try expectEditorBufferText(&editor, "axc");

    try editor.executeCommand(.undo);

    try expectEditorBufferText(&editor, "abc");
}

test "normal mode linewise yank and paste use the current line" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.handleKey(Key.init(.lower_y));

    try std.testing.expect(editor.registers['"'].linewise);
    try expectYankText(&editor, "alpha");
    try std.testing.expectEqual(Mode.normal, editor.mode);

    editor.activeWindow().?.cursor = .{ .row = 1, .col = 2 };
    try editor.handleKey(Key.init(.lower_p));

    try expectEditorBufferText(&editor, "alpha\nbeta\nalpha\ngamma");
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, editor.activeWindow().?.cursor);
}

test "normal mode d deletes single character under cursor" {
    var editor = try initTestEditor("line one\nline two\nline three");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 1, .col = 3 };

    try editor.handleKey(Key.init(.lower_d));

    // d deletes the character under cursor (not the whole line)
    try expectEditorBufferText(&editor, "line one\nlin two\nline three");
    try std.testing.expect(!editor.registers['"'].linewise);
    try expectYankText(&editor, "e");

    try editor.handleKey(Key.init(.lower_u));
    try expectEditorBufferText(&editor, "line one\nline two\nline three");
}

test "select mode linewise yank and paste keep full lines" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.handleKey(Key.init(.lower_x));
    try editor.handleKey(Key.init(.lower_y));

    try std.testing.expect(editor.registers['"'].linewise);
    try expectYankText(&editor, "alpha");
    try std.testing.expectEqual(Mode.normal, editor.mode);

    editor.activeWindow().?.cursor = .{ .row = 1, .col = 2 };
    try editor.handleKey(Key.init(.lower_p));

    try expectEditorBufferText(&editor, "alpha\nbeta\nalpha\ngamma");
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, editor.activeWindow().?.cursor);
}

test "select mode paste replaces active selection" {
    var editor = try initTestEditor("alpha beta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    try editor.setYankText("XYZ", false);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 0 };
    try editor.handleKey(Key.init(.lower_v));
    try editor.handleKey(Key.init(.lower_l));
    try editor.handleKey(Key.init(.lower_l));
    try editor.handleKey(Key.init(.lower_p));

    try expectEditorBufferText(&editor, "XYZha beta");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.activeWindow().?.selection == null);
}

test "select mode replace fills the active selection" {
    var editor = try initTestEditor("ab你");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.activeWindow().?.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = "ab你".len },
    };
    editor.activeWindow().?.cursor = editor.activeWindow().?.selection.?.cursor;

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
    editor.activeWindow().?.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.activeWindow().?.cursor = editor.activeWindow().?.selection.?.cursor;

    try editor.handleKey(Key.init(.backtick));

    try expectEditorBufferText(&editor, "abc");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.activeWindow().?.selection == null);
}

test "Alt-` uppercases a normal-mode selection from the keymap" {
    var editor = try initTestEditor("abC");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.activeWindow().?.cursor = editor.activeWindow().?.selection.?.cursor;

    try editor.handleKey(Key.initAlt(.backtick));

    try expectEditorBufferText(&editor, "ABC");
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.activeWindow().?.selection == null);
}

test "v enters select mode and exits back to normal" {
    var editor = try initTestEditor("alpha\nbeta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 2 };

    try editor.handleKey(Key.init(.lower_v));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expect(editor.activeWindow().?.selection != null);
    try std.testing.expectEqual(Position{ .row = 0, .col = 2 }, editor.activeWindow().?.selection.?.anchor);

    try editor.handleKey(Key.init(.lower_v));
    try std.testing.expectEqual(Mode.normal, editor.mode);
    try std.testing.expect(editor.activeWindow().?.selection == null);
}

test "x selects current line and extends downward in select mode" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 2 };

    try editor.handleKey(Key.init(.lower_x));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.activeWindow().?.selection.?.cursor);

    try editor.handleKey(Key.init(.lower_x));
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.activeWindow().?.selection.?.cursor);
}

test "X expands selection to full current line bounds" {
    var editor = try initTestEditor("alpha\nbeta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 1, .col = 2 };

    try editor.handleKey(Key.init(.upper_x));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.activeWindow().?.selection.?.cursor);
}

test "% selects the entire buffer linewise" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 1, .col = 1 };

    try editor.handleKey(Key.init(.percent));
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 2, .col = 5 }, editor.activeWindow().?.selection.?.cursor);
}

test "Alt-d triggers no-yank deletion from keymap" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.yank);
    try expectYankText(&editor, "a");

    editor.activeWindow().?.cursor.col = 1;
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

    editor.activeWindow().?.cursor.col = 1;
    try editor.handleKey(Key.initAlt(.lower_c));

    try expectEditorBufferText(&editor, "ac");
    try expectYankText(&editor, "a");
    try std.testing.expectEqual(Mode.insert, editor.mode);
}

test "Ctrl aliases route through the keymap" {
    var editor = try initTestEditor("alpha\nbeta\ngamma\ndelta");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.terminal.size.rows = 4;
    editor.activeWindow().?.cursor = .{ .row = 1, .col = 1 };

    try editor.handleKey(Key.initCtrl(.lower_u));
    try std.testing.expectEqual(@as(usize, 0), editor.activeWindow().?.cursor.row);

    try editor.handleKey(Key.initCtrl(.lower_d));
    try std.testing.expectEqual(@as(usize, 1), editor.activeWindow().?.cursor.row);

    try editor.handleKey(Key.initCtrl(.lower_f));
    try std.testing.expectEqual(@as(usize, 3), editor.activeWindow().?.cursor.row);

    try editor.handleKey(Key.initCtrl(.lower_b));
    try std.testing.expect(editor.activeWindow().?.cursor.row < 3);

    const row_before_undo = editor.activeWindow().?.cursor.row;
    try editor.handleKey(Key.initCtrl(.lower_z));
    try std.testing.expectEqual(row_before_undo, editor.activeWindow().?.cursor.row);

    try editor.handleKey(Key.initCtrl(.lower_o));
    // jump_back should work (no error message)

    try editor.handleKey(Key.initCtrl(.lower_i));
    // jump_forward should work (no error message)
}

test "Ctrl-s saves and Ctrl-c clears pending normal-mode keys" {
    var threaded: std.Io.Threaded = .init_single_threaded;
    var editor = try initTestEditor("alpha");
    defer deinitTestEditor(&editor);

    editor.io = threaded.io();
    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.handleKey(Key.init(.space));
    try std.testing.expectEqualStrings("Space", editor.pending_trie_name);
    try std.testing.expectEqual(@as(usize, 1), editor.pending_keys.items.len);

    try editor.handleKey(Key.initCtrl(.lower_c));
    try std.testing.expectEqualStrings("", editor.pending_trie_name);
    try std.testing.expectEqual(@as(usize, 0), editor.pending_keys.items.len);
    try std.testing.expectEqual(Mode.normal, editor.mode);

    const path = ".zig-cache/editor_ctrl_s_test.txt";
    defer std.Io.Dir.cwd().deleteFile(editor.io, path) catch {};
    editor.getBuffer().?.path = try editor.allocator.dupe(u8, path);
    try editor.handleKey(Key.initCtrl(.lower_s));
    try std.testing.expect(std.mem.startsWith(u8, editor.status_msg orelse "", "Saved: .zig-cache/editor_ctrl_s_test.txt"));
}

test "Alt-. repeats the last find motion from the keymap" {
    var editor = try initTestEditor("banana");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 0 };

    try editor.handleKey(Key.init(.lower_f));
    try editor.handleKey(Key.init(.lower_a));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);

    try editor.handleKey(Key.initAlt(.dot));
    try std.testing.expectEqual(Position{ .row = 0, .col = 3 }, editor.activeWindow().?.cursor);
}

test "select mode search-next binding selects the active match" {
    var editor = try initTestEditor("alpha beta alpha");
    defer deinitTestEditor(&editor);

    editor.mode = .select_;
    editor.key_trie_root = keymap.selectKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 0 };
    editor.activeWindow().?.selection = Selection.init(editor.activeWindow().?.cursor);
    editor.search_pattern = try editor.allocator.dupe(u8, "alpha");
    editor.search_direction = .forward;

    try editor.handleKey(Key.init(.lower_n));

    try std.testing.expectEqual(Position{ .row = 0, .col = 15 }, editor.activeWindow().?.cursor);
    try std.testing.expect(editor.activeWindow().?.selection != null);
    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 15 }, editor.activeWindow().?.selection.?.cursor);
}

test "normal mode cursor movement stays on Chinese UTF-8 boundaries" {
    var editor = try initTestEditor("A你B好");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_right);
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);

    try editor.executeCommand(.move_char_left);
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.activeWindow().?.cursor);
}

test "handleInsertKey keeps Chinese inserts stable between adjacent ASCII bytes" {
    var editor = try initTestEditor("AB");
    defer deinitTestEditor(&editor);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.handleInsertKey(Key.initUtf8("你"));
    try editor.handleInsertKey(Key.init(.exclam));

    try expectEditorBufferText(&editor, "A你!B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 5 }, editor.activeWindow().?.cursor);
}

test "handleInsertKey advances UTF-8 inserts from the aligned cursor position" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 2 };

    try editor.handleInsertKey(Key.initUtf8("好"));

    try expectEditorBufferText(&editor, "A好你B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.activeWindow().?.cursor);
}

test "append_mode inserts Chinese text after the full UTF-8 sequence" {
    var editor = try initTestEditor("A你B");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.append_mode);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 4 }, editor.activeWindow().?.cursor);

    try editor.handleInsertKey(Key.initUtf8("好"));

    try expectEditorBufferText(&editor, "A你好B");
    try std.testing.expectEqual(Position{ .row = 0, .col = 7 }, editor.activeWindow().?.cursor);
}

test "insertTextBytes inserts a burst and advances cursor once" {
    var editor = try initTestEditor("hello");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_at_line_end);
    try editor.insertTextBytes(" world");

    try expectEditorBufferText(&editor, "hello world");
    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.activeWindow().?.cursor);
}

test "insertTextBytes keeps UTF-8 bursts intact" {
    var editor = try initTestEditor("");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_mode);
    try editor.insertTextBytes("A你B");

    try expectEditorBufferText(&editor, "A你B");
    try std.testing.expectEqual(Position{ .row = 0, .col = "A你B".len }, editor.activeWindow().?.cursor);
}

test "insertTextBytes advances across UTF-8 text and newlines" {
    var editor = try initTestEditor("A");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.insert_at_line_end);
    try editor.insertTextBytes("你\n好");

    try expectEditorBufferText(&editor, "A你\n好");
    try std.testing.expectEqual(Position{ .row = 1, .col = "好".len }, editor.activeWindow().?.cursor);
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
    try std.testing.expectEqual(Position{ .row = 1, .col = 4 }, editor.activeWindow().?.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
}

test "open_below inserts a fresh line directly below the cursor" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 2 };

    try editor.executeCommand(.open_below);

    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.activeWindow().?.cursor);
    try std.testing.expectEqual(Mode.insert, editor.mode);
    try expectEditorBufferText(&editor, "alpha\n\nbeta\ngamma");
}

test "repeated open_below preserves the original next line content" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    editor.mode = .normal;
    editor.key_trie_root = keymap.normalKeymap();
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.open_below);
    try editor.handleInsertKey(Key.init(.lower_x));
    try editor.executeCommand(.normal_mode);
    try editor.executeCommand(.open_below);
    try editor.handleInsertKey(Key.init(.lower_y));

    try std.testing.expectEqual(Position{ .row = 2, .col = 1 }, editor.activeWindow().?.cursor);
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
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 0 };

    try editor.executeCommand(.search_next);
    try std.testing.expectEqual(Mode.select_, editor.mode);
    try std.testing.expectEqual(Position{ .row = 0, .col = 6 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 9 }, editor.activeWindow().?.selection.?.cursor);

    const next_range = editor.selectedTextRange(editor.getBuffer().?);
    const next_text = try editor.getBuffer().?.copyRange(next_range.start, next_range.end);
    defer editor.allocator.free(next_text);
    try std.testing.expectEqualStrings("beta", next_text);

    try editor.executeCommand(.search_prev);
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 1, .col = 3 }, editor.activeWindow().?.selection.?.cursor);

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
    editor.activeWindow().?.selection = Selection{
        .anchor = .{ .row = 0, .col = 0 },
        .cursor = .{ .row = 0, .col = 3 },
    };
    editor.activeWindow().?.cursor = editor.activeWindow().?.selection.?.cursor;
    editor.search_pattern = try editor.allocator.dupe(u8, "beta");
    editor.search_direction = .forward;

    try editor.executeCommand(.search_next);

    try std.testing.expectEqual(Position{ .row = 0, .col = 11 }, editor.activeWindow().?.selection.?.anchor);
    try std.testing.expectEqual(Position{ .row = 0, .col = 14 }, editor.activeWindow().?.selection.?.cursor);
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
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 6 };
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
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };

    try editor.executeCommand(.find_next_char);
    try editor.handleKey(Key.init(.lower_e));
    try std.testing.expectEqual(Position{ .row = 2, .col = 0 }, editor.activeWindow().?.cursor);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };
    try editor.executeCommand(.find_till_char);
    try editor.handleKey(Key.init(.lower_e));
    try std.testing.expectEqual(Position{ .row = 1, .col = 1 }, editor.activeWindow().?.cursor);

    editor.activeWindow().?.cursor = .{ .row = 2, .col = 0 };
    try editor.executeCommand(.find_prev_char);
    try editor.handleKey(Key.init(.lower_b));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);

    editor.activeWindow().?.cursor = .{ .row = 2, .col = 0 };
    try editor.executeCommand(.till_prev_char);
    try editor.handleKey(Key.init(.lower_b));
    try std.testing.expectEqual(Position{ .row = 1, .col = 0 }, editor.activeWindow().?.cursor);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 1 };
    try editor.executeCommand(.till_prev_char);
    try editor.handleKey(Key.init(.lower_a));
    try std.testing.expectEqual(Position{ .row = 0, .col = 1 }, editor.activeWindow().?.cursor);
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

test "which-key becomes visible for normal-mode prefixes" {
    var editor = try initTestEditor("one\ntwo\n");
    defer deinitTestEditor(&editor);

    editor.setMode(.normal);

    try editor.handleKey(Key.init(.lower_g));
    try std.testing.expect(editor.which_key_visible);
    try std.testing.expectEqualStrings("g", editor.which_key_prefix);

    try editor.handleKey(Key.init(.lower_g));
    try std.testing.expect(!editor.which_key_visible);
    try std.testing.expectEqualStrings("", editor.which_key_prefix);
}

test "which-key clears after invalid pending key" {
    var editor = try initTestEditor("one\ntwo\n");
    defer deinitTestEditor(&editor);

    editor.setMode(.normal);

    try editor.handleKey(Key.init(.space));
    try std.testing.expect(editor.which_key_visible);
    try std.testing.expectEqualStrings("space", editor.which_key_prefix);

    try editor.handleKey(Key.init(.lower_x));
    try std.testing.expect(!editor.which_key_visible);
    try std.testing.expectEqualStrings("", editor.which_key_prefix);
}

test "which-key becomes visible for ctrl-w window prefix" {
    var editor = try initTestEditor("one\ntwo\n");
    defer deinitTestEditor(&editor);

    editor.setMode(.normal);

    try editor.handleKey(Key.initCtrl(.lower_w));
    try std.testing.expect(editor.which_key_visible);
    try std.testing.expectEqualStrings("C-w", editor.which_key_prefix);

    try editor.handleKey(Key.init(.lower_s));
    try std.testing.expect(!editor.which_key_visible);
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().?.windows.items.len);
    try std.testing.expect(editor.activeTab().?.windows.items[1].split_dir != null);
    try std.testing.expectEqual(window_mod.SplitDir.horizontal, editor.activeTab().?.windows.items[1].split_dir.?);
}

test "float buffers open focus and close in stack order" {
    var editor = try initTestEditor("alpha\nbeta\ngamma");
    defer deinitTestEditor(&editor);

    const first = try editor.openFloatBuf("One");
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expect(editor.float_mode);
    try std.testing.expectEqual(@as(usize, 1), editor.float_bufs.items.len);
    try std.testing.expectEqualStrings("One", editor.focusedFloat().?.title);

    const second = try editor.openFloatBuf("Two");
    try std.testing.expectEqual(@as(usize, 1), second);
    try std.testing.expectEqual(@as(usize, 2), editor.float_bufs.items.len);
    try std.testing.expectEqualStrings("Two", editor.focusedFloat().?.title);
    try std.testing.expect(!editor.float_bufs.items[0].focused);

    editor.closeTopFloat();
    try std.testing.expectEqual(@as(usize, 1), editor.float_bufs.items.len);
    try std.testing.expect(editor.float_mode);
    try std.testing.expectEqualStrings("One", editor.focusedFloat().?.title);

    editor.closeTopFloat();
    try std.testing.expectEqual(@as(usize, 0), editor.float_bufs.items.len);
    try std.testing.expect(!editor.float_mode);
    try std.testing.expect(editor.focusedFloat() == null);
}

test "float mode routes j k g G q to focused float" {
    var editor = try initTestEditor("seed");
    defer deinitTestEditor(&editor);

    const float_index = try editor.openFloatBuf("Float");
    const fb = &editor.float_bufs.items[float_index];
    const buf = editor.buffers.items[fb.buf_index];
    try buf.setLine(0, "one");
    try buf.insertLine(1, "two");
    try buf.insertLine(2, "three");
    try buf.insertLine(3, "four");
    try buf.insertLine(4, "five");

    try editor.handleKey(Key.init(.lower_j));
    try std.testing.expectEqual(@as(usize, 1), fb.cursor.row);

    try editor.handleKey(Key.init(.upper_g));
    try std.testing.expectEqual(buf.lineCount() -| 1, fb.cursor.row);

    try editor.handleKey(Key.init(.lower_g));
    try std.testing.expectEqual(@as(usize, 0), fb.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), fb.scroll);

    try editor.handleKey(Key.init(.lower_k));
    try std.testing.expectEqual(@as(usize, 0), fb.cursor.row);

    try editor.handleKey(Key.init(.lower_q));
    try std.testing.expectEqual(@as(usize, 0), editor.float_bufs.items.len);
    try std.testing.expect(!editor.float_mode);
}

test "executeCommandString float opens and escape closes the top float" {
    var editor = try initTestEditor("alpha");
    defer deinitTestEditor(&editor);

    try editor.executeCommandString("float");
    try std.testing.expectEqual(@as(usize, 1), editor.float_bufs.items.len);
    try std.testing.expect(editor.float_mode);
    try std.testing.expectEqualStrings("Float", editor.focusedFloat().?.title);

    try editor.handleKey(Key.init(.escape));
    try std.testing.expectEqual(@as(usize, 0), editor.float_bufs.items.len);
    try std.testing.expect(!editor.float_mode);
}

test "window commands split focus cycle and close views" {
    var editor = try initTestEditor("one\ntwo\n");
    defer deinitTestEditor(&editor);

    try editor.executeCommand(.hsplit);
    try editor.executeCommand(.vsplit);
    try std.testing.expectEqual(@as(usize, 3), editor.activeTab().?.windows.items.len);
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().?.active_window);

    try editor.executeCommand(.focus_window_left);
    try std.testing.expectEqual(@as(usize, 1), editor.activeTab().?.active_window);

    try editor.executeCommand(.rotate_view);
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().?.active_window);

    try editor.executeCommand(.window_only);
    try std.testing.expectEqual(@as(usize, 1), editor.activeTab().?.windows.items.len);
    try std.testing.expectEqual(@as(usize, 0), editor.activeTab().?.active_window);

    try editor.executeCommand(.hsplit);
    try editor.executeCommand(.wclose);
    try std.testing.expectEqual(@as(usize, 1), editor.activeTab().?.windows.items.len);
}

test "tab commands and command aliases manage tabs" {
    var editor = try initTestEditor("one\ntwo\n");
    defer deinitTestEditor(&editor);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.Io.Threaded.global_single_threaded.io(), .{ .sub_path = "vb.txt", .data = "One\nTwo\nThree\n" });
    const split_path = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/vb.txt", .{tmp.sub_path});
    defer std.testing.allocator.free(split_path);

    try editor.executeCommandString("tabnew");
    try std.testing.expectEqual(@as(usize, 2), editor.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), editor.current_tab);
    try std.testing.expectEqual(@as(usize, 2), editor.buffers.items.len);

    try editor.executeCommandString("gT");
    try std.testing.expectEqual(@as(usize, 0), editor.current_tab);

    try editor.executeCommandString("gt");
    try std.testing.expectEqual(@as(usize, 1), editor.current_tab);

    try editor.executeCommandString("split");
    try std.testing.expectEqual(@as(usize, 2), editor.activeTab().?.windows.items.len);

    var vs_cmd = std.ArrayList(u8).empty;
    defer vs_cmd.deinit(std.testing.allocator);
    try vs_cmd.appendSlice(std.testing.allocator, "vsplit ");
    try vs_cmd.appendSlice(std.testing.allocator, split_path);
    try editor.executeCommandString(vs_cmd.items);
    try std.testing.expectEqual(@as(usize, 3), editor.activeTab().?.windows.items.len);
    try std.testing.expect(std.mem.eql(u8, editor.getBuffer().?.path.?, split_path));

    try editor.executeCommandString("only");
    try std.testing.expectEqual(@as(usize, 1), editor.activeTab().?.windows.items.len);

    try editor.executeCommandString("tabclose");
    try std.testing.expectEqual(@as(usize, 1), editor.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), editor.current_tab);
}

test "shift-tab unindents the current line in insert mode" {
    var editor = try initTestEditor("    alpha");
    defer deinitTestEditor(&editor);

    editor.activeWindow().?.cursor = .{ .row = 0, .col = 4 };

    try editor.handleInsertKey(Key.init(.backtab));

    try expectEditorBufferText(&editor, "alpha");
    try std.testing.expectEqual(Position{ .row = 0, .col = 0 }, editor.activeWindow().?.cursor);
}

test "ctrl-d and ctrl-u move half a page and adjust scroll" {
    var editor = try initTestEditor("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25\n26\n27\n28\n29\n30\n31\n32\n33\n34\n35\n36\n37\n38\n39");
    defer deinitTestEditor(&editor);

    editor.setMode(.normal);
    editor.activeWindow().?.cursor = .{ .row = 5, .col = 0 };
    editor.activeWindow().?.scroll = 0;

    try editor.handleKey(Key.initCtrl(.lower_d));
    try std.testing.expectEqual(@as(usize, 16), editor.activeWindow().?.cursor.row);
    try std.testing.expectEqual(@as(usize, 11), editor.activeWindow().?.scroll);

    try editor.handleKey(Key.initCtrl(.lower_u));
    try std.testing.expectEqual(@as(usize, 5), editor.activeWindow().?.cursor.row);
    try std.testing.expectEqual(@as(usize, 0), editor.activeWindow().?.scroll);
}

test "adjustScroll keeps insert cursor within the horizontal viewport" {
    var editor = try initTestEditor("0123456789");
    defer deinitTestEditor(&editor);

    editor.mode = .insert;
    editor.terminal.size.cols = 10;
    editor.activeWindow().?.cursor = .{ .row = 0, .col = 10 };

    editor.adjustScroll();

    try std.testing.expectEqual(@as(usize, 7), editor.activeWindow().?.scroll_col);
    try std.testing.expectEqual(@as(usize, 4), utf8.lineWidth(1000));
}

test "zz zt and zb reposition the viewport around the cursor" {
    var editor = try initTestEditor("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n21\n22\n23\n24\n25\n26\n27\n28\n29\n30\n31\n32\n33\n34\n35\n36\n37\n38\n39");
    defer deinitTestEditor(&editor);

    editor.setMode(.normal);
    editor.activeWindow().?.cursor = .{ .row = 30, .col = 0 };

    try editor.handleKey(Key.init(.lower_z));
    try editor.handleKey(Key.init(.lower_z));
    try std.testing.expectEqual(@as(usize, 18), editor.activeWindow().?.scroll);

    try editor.handleKey(Key.init(.lower_z));
    try editor.handleKey(Key.init(.lower_t));
    try std.testing.expectEqual(@as(usize, 18), editor.activeWindow().?.scroll);

    try editor.handleKey(Key.init(.lower_z));
    try editor.handleKey(Key.init(.lower_b));
    try std.testing.expectEqual(@as(usize, 9), editor.activeWindow().?.scroll);
}
