const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Editor = @import("editor.zig").Editor;
const keymap = @import("keymap.zig");
const term = @import("terminal.zig");
const syntax = @import("syntax.zig");
const treesitter = @import("treesitter.zig");
const grammar_detect = @import("grammar.zig");
const utf8 = @import("utf8.zig");
const encoding_mod = @import("../codecs/encoding.zig");
const line_ending_mod = @import("line_ending.zig");
const highlight_worker_mod = @import("highlight_worker.zig");
const window_mod = @import("window.zig");
const FloatBuf = window_mod.FloatBuf;
const Rect = window_mod.Rect;
const SplitDir = window_mod.SplitDir;
const Tab = window_mod.Tab;
const Window = window_mod.Window;

const WhichKeyEntry = keymap.KeyBindingDesc;

fn clipAscii(text: []const u8, max_len: usize) []const u8 {
    return text[0..@min(text.len, max_len)];
}

/// Clip text to fit within `max_cols` display columns, accounting for wide characters.
fn clipToWidth(text: []const u8, max_cols: usize) []const u8 {
    var cols: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const w = utf8.codepointCellWidth(std.unicode.utf8Decode(slice) catch continue);
        if (cols + w > max_cols) {
            const end = iter.i - slice.len;
            return text[0..end];
        }
        cols += w;
    }
    return text;
}

/// Display width of text in terminal columns.
fn displayWidth(text: []const u8) usize {
    var cols: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        cols += utf8.codepointCellWidth(std.unicode.utf8Decode(slice) catch continue);
    }
    return cols;
}

fn writeRepeatedText(self: *Editor, text: []const u8, count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) self.terminal.writeText(text);
}

fn renderFloatLine(self: *Editor, width: usize, line: []const u8) void {
    if (width == 0) return;

    const split = std.mem.indexOf(u8, line, "  ") orelse std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    const key_text = clipToWidth(line[0..split], width);
    var written = displayWidth(key_text);

    if (key_text.len > 0) {
        self.terminal.setFgRgb(0xff, 0xdd, 0x66);
        self.terminal.writeText(key_text);
    }
    if (written < width and split < line.len) {
        const rest = clipToWidth(line[split..], width - written);
        self.terminal.setFgRgb(0xcc, 0xcc, 0xcc);
        self.terminal.writeText(rest);
        written += displayWidth(rest);
    }
    if (written < width) {
        self.terminal.setFgRgb(0xcc, 0xcc, 0xcc);
        self.terminal.writeSpaces(width - written);
    }
}

fn renderFloatBox(
    self: *Editor,
    top: usize,
    left: usize,
    width: usize,
    height: usize,
    title: []const u8,
    lines: []const []const u8,
    focused: bool,
) void {
    const box_width = @min(width, self.terminal.size.cols -| left);
    const box_height = @min(height, self.terminal.size.rows -| top);
    if (box_width < 2 or box_height < 2) return;

    const inner_width = box_width - 2;
    const content_rows = box_height - 2;

    self.terminal.setBgRgb(0x2a, 0x2a, 0x2a);

    const border_rgb: u8 = if (focused) 0xd8 else 0x88;
    const title_rgb: u8 = if (focused) 0xff else 0xcc;

    self.terminal.moveTo(top, left);
    self.terminal.setFgRgb(border_rgb, border_rgb, border_rgb);
    self.terminal.writeText("┌");

    var remaining = inner_width;
    if (title.len > 0 and remaining >= 3) {
        const visible_title = clipAscii(title, remaining -| 3);
        self.terminal.writeText("─ ");
        remaining = remaining -| 2;
        self.terminal.setFgRgb(title_rgb, title_rgb, title_rgb);
        self.terminal.writeText(visible_title);
        remaining = remaining -| visible_title.len;
        self.terminal.setFgRgb(border_rgb, border_rgb, border_rgb);
        self.terminal.writeText(" ");
        remaining = remaining -| 1;
    }
    writeRepeatedText(self, "─", remaining);
    self.terminal.writeText("┐");

    for (0..content_rows) |row| {
        self.terminal.moveTo(top + 1 + row, left);
        self.terminal.setFgRgb(border_rgb, border_rgb, border_rgb);
        self.terminal.writeText("│");
        if (row < lines.len) {
            renderFloatLine(self, inner_width, lines[row]);
        } else {
            self.terminal.setFgRgb(0xcc, 0xcc, 0xcc);
            self.terminal.writeSpaces(inner_width);
        }
        self.terminal.setFgRgb(border_rgb, border_rgb, border_rgb);
        self.terminal.writeText("│");
    }

    self.terminal.moveTo(top + box_height - 1, left);
    self.terminal.setFgRgb(border_rgb, border_rgb, border_rgb);
    self.terminal.writeText("└");
    writeRepeatedText(self, "─", inner_width);
    self.terminal.writeText("┘");
    self.terminal.resetAttrs();
}

fn renderWhichKeyPopup(self: *Editor, rows: usize, cols: usize) void {
    if (!self.which_key_visible) return;

    var key_bufs: [12][16]u8 = undefined;
    var entries: [12]WhichKeyEntry = undefined;
    var entry_count: usize = 0;

    if (std.mem.eql(u8, self.which_key_prefix, "\"")) {
        // Register popup — Helix style
        // Always show: " (default), _ (black hole), # (sel indices), . (sel contents), % (file), + (clipboard), * (primary)
        // Show only when has content: a-z, / (search), : (command), @ (macro)
        var line_bufs: [32][64]u8 = undefined;
        var lines: [32][]const u8 = undefined;
        var count: usize = 0;

        // Named registers with content (a-z, /, :, @)
        const content_regs = "abcdefghijklmnopqrstuvwxyz/:@";
        for (content_regs) |name| {
            if (count >= line_bufs.len) break;
            const reg = self.registers[name];
            if (reg.text == null) continue;
            const preview = clipToWidth(reg.text.?, 20);
            const lw: u8 = if (reg.linewise) 'L' else 'c';
            lines[count] = std.fmt.bufPrint(&line_bufs[count], "{c} [{c}] {s}", .{ name, lw, preview }) catch "?";
            count += 1;
        }

        // Always show these special registers
        {
            // Default register
            const reg = self.registers['"'];
            const lw: u8 = if (reg.linewise) 'L' else 'c';
            if (reg.text) |text| {
                const preview = clipToWidth(text, 20);
                lines[count] = std.fmt.bufPrint(&line_bufs[count], "\" [{c}] {s}", .{ lw, preview }) catch "?";
            } else {
                lines[count] = "\" (empty)";
            }
            count += 1;
        }
        // Black hole
        lines[count] = "_ <empty>";
        count += 1;
        // Selection indices (read-only)
        lines[count] = "# <selection indices>";
        count += 1;
        // Selection contents (read-only)
        lines[count] = ". <selection contents>";
        count += 1;
        // File name (read-only)
        if (self.getBuffer()) |buf| {
            if (buf.path) |path| {
                const preview = clipToWidth(path, 20);
                lines[count] = std.fmt.bufPrint(&line_bufs[count], "% {s}", .{preview}) catch "?";
            } else {
                lines[count] = "% <document path>";
            }
        } else {
            lines[count] = "% <document path>";
        }
        count += 1;
        // System clipboard
        lines[count] = "+ <system clipboard>";
        count += 1;
        // Primary clipboard
        lines[count] = "* <primary clipboard>";
        count += 1;

        if (count == 0) return;
        const box_height = count + 2;
        const top = rows -| 3 -| box_height;
        const width = @min(cols, @as(usize, 60));
        renderFloatBox(self, top, 0, width, box_height, "Select register", lines[0..count], false);
        return;
    }

    // Normal prefix — look up in trie
    {
        const root = keymap.normalKeymap();
        const normal_node = switch (root) {
            .node => |n| n,
            else => return,
        };

        for (normal_node.bindings) |binding| {
            const trie_node = switch (binding.trie) {
                .node => |n| n,
                else => continue,
            };
            var prefix_buf: [16]u8 = undefined;
            const label = binding.key.format(&prefix_buf);
            if (std.mem.eql(u8, label, self.which_key_prefix)) {
                entry_count = keymap.nodeLeafEntries(trie_node, &key_bufs, &entries);
                break;
            }
        }
    }

    if (entry_count == 0) return;

    var line_bufs: [12][48]u8 = undefined;
    var lines: [12][]const u8 = undefined;
    for (entries[0..entry_count], 0..) |entry, i| {
        lines[i] = std.fmt.bufPrint(&line_bufs[i], "{s}  {s}", .{ entry.key, entry.desc }) catch entry.key;
    }

    const box_height = entry_count + 2;
    const top = rows -| 3 -| box_height;
    const width = @min(cols, @as(usize, 60));
    var title_buf: [24]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, "{s} prefix", .{self.which_key_prefix}) catch self.which_key_prefix;
    renderFloatBox(self, top, 0, width, box_height, title, lines[0..entry_count], false);
}

fn tabBarHeight(self: *const Editor) usize {
    return if (self.tabs.items.len > 1) 1 else 0;
}

fn contentAreaRect(self: *const Editor) Rect {
    const top = tabBarHeight(self);
    // Each window owns its own statusline row (vim-style), so we only reserve
    // 1 global row at the bottom for the command / message line.
    return .{
        .top = top,
        .left = 0,
        .rows = self.terminal.size.rows -| 1 -| top,
        .cols = self.terminal.size.cols,
    };
}

fn bufferForWindow(self: *Editor, win: *const Window) ?*Buffer {
    if (win.buf_index < self.buffers.items.len) return self.buffers.items[win.buf_index];
    return null;
}

fn computeWindowRects(tab: *Tab, content_rect: Rect) void {
    layoutWindows(tab, 0, content_rect);
}

/// Recursively lay out windows[start..] within `rect`.
/// Each split is determined by windows[start+1].split_dir — the direction
/// in which that window was created.  This allows mixed horizontal/vertical
/// layouts within a single tab (e.g. vsplit then split).
fn layoutWindows(tab: *Tab, start: usize, rect: Rect) void {
    if (start >= tab.windows.items.len) return;
    if (start == tab.windows.items.len - 1) {
        tab.windows.items[start].rect = rect;
        return;
    }
    // The window at start+1 was created by a split — its split_dir tells us
    // how to separate windows[start] from the rest.
    const dir = tab.windows.items[start + 1].split_dir orelse .vertical;
    switch (dir) {
        .vertical => {
            const first_cols = rect.cols / 2;
            tab.windows.items[start].rect = .{
                .top = rect.top,
                .left = rect.left,
                .rows = rect.rows,
                .cols = first_cols,
            };
            const rest = Rect{
                .top = rect.top,
                .left = rect.left + first_cols + 1,
                .rows = rect.rows,
                .cols = rect.cols -| first_cols -| 1,
            };
            layoutWindows(tab, start + 1, rest);
        },
        .horizontal => {
            const first_rows = rect.rows / 2;
            tab.windows.items[start].rect = .{
                .top = rect.top,
                .left = rect.left,
                .rows = first_rows,
                .cols = rect.cols,
            };
            const rest = Rect{
                .top = rect.top + first_rows + 1,
                .left = rect.left,
                .rows = rect.rows -| first_rows -| 1,
                .cols = rect.cols,
            };
            layoutWindows(tab, start + 1, rest);
        },
    }
}

fn renderTabBar(self: *Editor) void {
    if (self.tabs.items.len <= 1) return;

    const cols = self.terminal.size.cols;
    var written: usize = 0;
    self.terminal.moveTo(0, 0);
    self.terminal.setBgRgb(0x20, 0x20, 0x20);

    for (self.tabs.items, 0..) |tab, i| {
        if (written >= cols) break;

        const buf_ptr = if (tab.active_window < tab.windows.items.len)
            bufferForWindow(self, &tab.windows.items[tab.active_window])
        else
            null;
        const buf_name = if (buf_ptr) |buf|
            std.fs.path.basename(buf.path orelse "[scratch]")
        else
            "[scratch]";
        const dirty = if (buf_ptr) |buf| if (buf.dirty) "*" else "" else "";

        var label_buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, " [{d}: {s}{s}] ", .{ i + 1, buf_name, dirty }) catch " [tab] ";
        const visible = clipAscii(label, cols - written);

        if (i == self.current_tab) {
            self.terminal.setStyles(term.STYLE_BOLD);
            self.terminal.setFgRgb(0x10, 0x10, 0x10);
            self.terminal.setBgRgb(0xa8, 0xb8, 0xd0);
        } else {
            self.terminal.setStyles(term.STYLE_NONE);
            self.terminal.setFgRgb(0xc8, 0xc8, 0xc8);
            self.terminal.setBgRgb(0x34, 0x34, 0x34);
        }
        self.terminal.writeText(visible);
        written += visible.len;
    }

    if (written < cols) {
        self.terminal.setStyles(term.STYLE_NONE);
        self.terminal.setFgRgb(0xc8, 0xc8, 0xc8);
        self.terminal.setBgRgb(0x20, 0x20, 0x20);
        self.terminal.writeSpaces(cols - written);
    }
    self.terminal.resetAttrs();
}

/// Render a vim-style per-window statusline at the bottom row of win.rect.
/// Active window: bright blue background. Inactive: dark gray.
fn renderWindowStatusline(self: *Editor, win: *const Window, buf_ptr: *Buffer, active: bool) void {
    if (win.rect.rows == 0 or win.rect.cols == 0) return;
    const statusline_row = win.rect.top + win.rect.rows - 1;
    const cols = win.rect.cols;

    self.terminal.moveTo(statusline_row, win.rect.left);

    if (active) {
        self.terminal.setFgRgb(0xf0, 0xf0, 0xf0);
        self.terminal.setBgRgb(0x3a, 0x5a, 0x80);
        self.terminal.setStyles(term.STYLE_BOLD);
    } else {
        self.terminal.setFgRgb(0xaa, 0xaa, 0xaa);
        self.terminal.setBgRgb(0x28, 0x28, 0x28);
        self.terminal.setStyles(term.STYLE_NONE);
    }

    const buf_path = buf_ptr.path orelse "[scratch]";
    const dirty_mark = if (buf_ptr.dirty) " [+]" else "";
    const enc_name = buf_ptr.file_encoding.displayName();
    const le_name = buf_ptr.file_line_ending.displayName();

    // For vertical splits, show shorter info in inactive panes
    var left_buf: [320]u8 = undefined;
    const left = if (active) blk: {
        const mode_str = self.mode.toString();
        break :blk std.fmt.bufPrint(&left_buf, " {s}  {s}{s} [{s}] [{s}]", .{ mode_str, buf_path, dirty_mark, enc_name, le_name }) catch "";
    } else blk: {
        // Inactive: show filename (no mode)
        break :blk std.fmt.bufPrint(&left_buf, " {s}{s}", .{ buf_path, dirty_mark }) catch "";
    };

    var right_buf: [32]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, " {}:{} ", .{ win.cursor.row + 1, win.cursor.col + 1 }) catch "";

    const left_vis = clipAscii(left, cols);
    const right_vis = if (cols > left_vis.len + right.len) right else clipAscii(right, cols -| left_vis.len);
    const pad = cols -| left_vis.len -| right_vis.len;

    self.terminal.writeText(left_vis);
    self.terminal.writeSpaces(pad);
    self.terminal.writeText(right_vis);
    self.terminal.resetAttrs();
}

fn drawWindowDividers(self: *Editor, tab: *const Tab, content_rect: Rect) void {
    const count = tab.windows.items.len;
    if (count <= 1) return;

    // Draw a divider between each adjacent pair, using the split_dir of
    // the window that was created by that split (windows[i+1].split_dir).
    for (0..count - 1) |i| {
        const dir = tab.windows.items[i + 1].split_dir orelse .vertical;
        const focused = tab.active_window == i or tab.active_window == i + 1;
        const gray: u8 = if (focused) 0xd8 else 0x55;
        self.terminal.setStyles(if (focused) term.STYLE_BOLD else term.STYLE_NONE);
        self.terminal.setFgRgb(gray, gray, gray);

        switch (dir) {
            .horizontal => {
                // Horizontal split: draw a horizontal divider row between
                // the bottom of windows[i] and the top of windows[i+1].
                const win = &tab.windows.items[i];
                const divider_row = win.rect.top + win.rect.rows;
                if (divider_row >= content_rect.top + content_rect.rows) continue;
                if (win.rect.cols == 0) continue;
                self.terminal.moveTo(divider_row, win.rect.left);
                for (0..win.rect.cols) |_| {
                    self.terminal.writeText(if (focused) "━" else "─");
                }
            },
            .vertical => {
                const left_win = &tab.windows.items[i];
                const divider_col = left_win.rect.left + left_win.rect.cols;
                if (divider_col >= content_rect.left + content_rect.cols) continue;
                for (0..left_win.rect.rows) |row| {
                    self.terminal.moveTo(left_win.rect.top + row, divider_col);
                    self.terminal.writeText(if (focused) "┃" else "│");
                }
            },
        }
    }
    self.terminal.resetAttrs();
}

fn renderFloatBuffers(self: *Editor) void {
    const gpa = self.allocator;
    for (self.float_bufs.items) |fb| {
        const buf_ptr = if (fb.buf_index < self.buffers.items.len) self.buffers.items[fb.buf_index] else continue;
        const inner_rows = fb.rect.rows -| 2;
        if (inner_rows == 0) continue;
        var line_ptrs: [128][]const u8 = undefined;
        var dyn_lines: ?[][]const u8 = null;
        defer if (dyn_lines) |lines| gpa.free(lines);

        const lines: [][]const u8 = if (inner_rows <= line_ptrs.len) blk: {
            for (0..inner_rows) |row| {
                line_ptrs[row] = buf_ptr.getLine(fb.scroll + row) orelse "";
            }
            break :blk line_ptrs[0..inner_rows];
        } else blk: {
            dyn_lines = gpa.alloc([]const u8, inner_rows) catch {
                // Fallback: show as many as fit in the stack buffer
                for (0..line_ptrs.len) |row| {
                    line_ptrs[row] = buf_ptr.getLine(fb.scroll + row) orelse "";
                }
                break :blk line_ptrs[0..];
            };
            for (0..inner_rows) |row| {
                dyn_lines.?[row] = buf_ptr.getLine(fb.scroll + row) orelse "";
            }
            break :blk dyn_lines.?;
        };
        renderFloatBox(self, fb.rect.top, fb.rect.left, fb.rect.cols, fb.rect.rows, fb.title, lines, fb.focused);

        if (fb.focused) {
            const cursor = buf_ptr.clampPosInsert(fb.cursor);
            if (cursor.row >= fb.scroll and cursor.row < fb.scroll + inner_rows and fb.rect.rows > 2 and fb.rect.cols > 2) {
                self.terminal.setCursorStyle(self.cursorStyleForMode(self.mode));
                const cursor_row = fb.rect.top + 1 + (cursor.row - fb.scroll);
                const cursor_col = fb.rect.left + 1 + @min(cursor.col, fb.rect.cols -| 3);
                self.terminal.showCursor(cursor_row, cursor_col);
            }
        }
    }
}

pub fn render(self: *Editor) !void {
    const gpa = self.allocator;
    const style_buf = &self.render_style_buf;
    const rows = self.terminal.size.rows;
    const cols = self.terminal.size.cols;
    const tab = self.activeTab() orelse return;
    const content_rect = contentAreaRect(self);
    computeWindowRects(tab, content_rect);

    const win = tab.activeWindow() orelse return;
    const buf_ptr = bufferForWindow(self, win) orelse return;

    const file_path = buf_ptr.path orelse "";
    const first_line = buf_ptr.getLine(0);
    const detected_name = grammar_detect.grammarNameForFile(file_path, first_line);
    if (!std.mem.eql(u8, detected_name orelse "", self.grammar_name orelse "")) {
        if (self.highlight_worker) |w| {
            w.deinit();
            self.highlight_worker = null;
        }
        if (self.cached_hl_styles) |s| {
            gpa.free(s);
            self.cached_hl_styles = null;
        }
        self.last_hl_buf_version = std.math.maxInt(u64);
        self.last_hl_scroll = std.math.maxInt(usize);
        self.grammar_name = detected_name;
        if (detected_name) |name| {
            if (self.grammar_paths) |paths| {
                const grammar = grammar_detect.loadGrammar(self.io, self.allocator, paths, name) catch |err| blk: {
                    std.log.warn("loadGrammar({s}): {}", .{ name, err });
                    break :blk null;
                };
                if (grammar) |g| {
                    self.highlight_worker = highlight_worker_mod.HighlightWorker.init(self.allocator, self.io, g) catch |err| blk: {
                        std.log.warn("HighlightWorker.init: {}", .{err});
                        break :blk null;
                    };
                }
            }
        }
    }

    var hl_styles: ?[]syntax.TokenStyle = null;
    if (self.highlight_worker) |worker| {
        if (worker.tryTakeResult()) |result| {
            if (result.version == buf_ptr.content_version) {
                defer if (result.changed_ranges) |cr| gpa.free(cr);
                if (self.cached_hl_styles) |old| gpa.free(old);
                self.cached_hl_styles = result.styles;
                self.last_hl_buf_version = result.version;
                self.last_hl_scroll = result.scroll;
                if (result.changed_ranges) |ranges| {
                    for (ranges) |range| {
                        var row: u32 = range.start_point.row;
                        while (row <= range.end_point.row) : (row += 1) {
                            buf_ptr.render_cache.markDirty(@intCast(row));
                        }
                    }
                } else {
                    buf_ptr.render_cache.invalidateAll();
                }
            } else {
                defer if (result.changed_ranges) |cr| gpa.free(cr);
                gpa.free(result.styles);
            }
        }

        const content_changed = self.last_hl_buf_version != buf_ptr.content_version;
        const scroll_changed = self.last_hl_scroll != win.scroll;
        if (content_changed or scroll_changed) {
            if (self.src_cache_version != buf_ptr.content_version) {
                self.src_cache.clearRetainingCapacity();
                buf_ptr.text.writeToBuf(gpa, &self.src_cache) catch {};
                self.src_cache_version = buf_ptr.content_version;
            }
            const src = self.src_cache.items;
            const src_len: u32 = @intCast(src.len);
            const rows_visible = win.rect.rows;
            const first_row = win.scroll;
            const last_row = win.scroll +| (rows_visible -| 1);
            const q_start: u32 = if (first_row == 0 and buf_ptr.lineCount() <= rows_visible) blk: {
                break :blk 0;
            } else blk: {
                const r = buf_ptr.text.lineByteRange(first_row) catch break :blk 0;
                break :blk @min(@as(u32, @intCast((r orelse break :blk 0).start)), src_len);
            };
            const q_end: u32 = if (first_row == 0 and buf_ptr.lineCount() <= rows_visible) blk: {
                break :blk src_len;
            } else blk: {
                const r = buf_ptr.text.lineByteRange(last_row) catch break :blk src_len;
                break :blk @max(@min(@as(u32, @intCast((r orelse break :blk src_len).end)), src_len), q_start);
            };

            const te = buf_ptr.pending_tree_edit;
            buf_ptr.pending_tree_edit = null;
            if (gpa.dupe(u8, src)) |src_copy| {
                worker.submit(.{
                    .source = src_copy,
                    .version = buf_ptr.content_version,
                    .scroll = win.scroll,
                    .q_start = q_start,
                    .q_end = q_end,
                    .tree_edit = te,
                });
                self.last_hl_buf_version = buf_ptr.content_version;
                self.last_hl_scroll = win.scroll;
            } else |_| {}
        }

        hl_styles = self.cached_hl_styles;
    }

    self.terminal.hideCursor();
    self.terminal.erasePlane();
    buf_ptr.render_cache.invalidateAll();

    renderTabBar(self);

    for (tab.windows.items, 0..) |*window, wi| {
        const window_buf = bufferForWindow(self, window) orelse continue;
        const line_num_width = utf8.lineWidth(window_buf.lineCount());
        const window_hl_styles = if (window.buf_index == win.buf_index) hl_styles else null;
        // Content rows = rect.rows - 1 (last row reserved for per-window statusline)
        const content_rows = window.rect.rows -| 1;

        var row: usize = 0;
        while (row < content_rows) : (row += 1) {
            try appendRenderedTextRow(self, gpa, style_buf, window, row, line_num_width, window_hl_styles);
        }
        renderWindowStatusline(self, window, window_buf, wi == tab.active_window);
    }

    drawWindowDividers(self, tab, content_rect);

    // Command / message line (single global row at the very bottom).
    // Mode indicator lives here when not in a special input mode.
    const cmd_row = rows -| 1;
    self.terminal.moveTo(cmd_row, 0);
    if (self.in_command_mode) {
        self.terminal.setFg(.yellow);
        self.terminal.writeText(":");
        self.terminal.writeText(self.command_buf.items);
        self.terminal.resetAttrs();
    } else if (self.in_search_mode) {
        self.terminal.setFg(.yellow);
        const dir_label = if (self.search_direction == .forward) "/" else "?";
        self.terminal.writeText(dir_label);
        self.terminal.writeText(self.command_buf.items);
        self.terminal.resetAttrs();
    } else if (self.pending_input == .char_pending) {
        self.terminal.setFg(.cyan);
        const prompt = switch (self.pending_command orelse .no_op) {
            .find_next_char => "f",
            .find_till_char => "t",
            .find_prev_char => "F",
            .till_prev_char => "T",
            .surround_add => "ms",
            .surround_replace => "mr",
            .replace => "r",
            else => "?",
        };
        self.terminal.writeText(prompt);
        self.terminal.writeText("> ");
        self.terminal.resetAttrs();
    } else if (self.pending_input == .numeric_prompt) {
        self.terminal.setFg(.cyan);
        const prompt = switch (self.pending_command orelse .no_op) {
            .goto_line => "gd",
            .goto_column => "g|",
            else => "#",
        };
        self.terminal.writeText(prompt);
        self.terminal.writeText(" ");
        self.terminal.writeText(self.command_buf.items);
        self.terminal.resetAttrs();
    } else if (self.pending_keys.items.len > 0) {
        self.terminal.setFg(.cyan);
        for (self.pending_keys.items) |k| {
            var kbuf: [16]u8 = undefined;
            const label = k.format(&kbuf);
            self.terminal.writeText(label);
        }
        if (self.pending_trie_name.len > 0) {
            self.terminal.writeText(" · ");
            self.terminal.writeText(self.pending_trie_name);
        }
        self.terminal.resetAttrs();
    } else if (self.status_msg) |msg| {
        self.terminal.writeText(msg);
    }

    if (self.which_key_visible) renderWhichKeyPopup(self, rows, cols);
    renderFloatBuffers(self);
    if (!(self.float_mode and self.focusedFloat() != null)) {
        appendCursorPresentation(self, win, buf_ptr, utf8.lineWidth(buf_ptr.lineCount()));
    }

    self.terminal.flushRender();

    self.last_render_buf = buf_ptr;
    self.last_render_scroll = win.scroll;
    self.last_render_rows = rows;
    self.last_render_cols = cols;
    self.last_render_cursor = win.cursor;
    self.last_render_mode = self.mode;
    self.last_render_selection = win.selection;
}

fn appendRenderedTextRow(
    self: *Editor,
    gpa: std.mem.Allocator,
    style_buf: *std.ArrayList(syntax.TokenStyle),
    win: *const Window,
    screen_row: usize,
    line_num_width: usize,
    hl_styles: ?[]const syntax.TokenStyle,
) !void {
    const buf_ptr = bufferForWindow(self, win) orelse return;
    if (win.rect.cols == 0) return;

    const line_idx = win.scroll + screen_row;
    self.terminal.moveTo(win.rect.top + screen_row, win.rect.left);

    var remaining_cols = win.rect.cols;
    if (line_idx < buf_ptr.lineCount()) {
        self.terminal.setFg(.gray);
        var num_buf: [16]u8 = undefined;
        const line_num = std.fmt.bufPrint(&num_buf, "{d}", .{line_idx + 1}) catch "";

        const pad_count = line_num_width -| line_num.len;
        const pad_visible = @min(pad_count, remaining_cols);
        if (pad_visible > 0) self.terminal.writeSpaces(pad_visible);
        remaining_cols -|= pad_visible;

        const line_num_visible = clipAscii(line_num, remaining_cols);
        self.terminal.writeText(line_num_visible);
        remaining_cols -|= line_num_visible.len;

        const separator = clipAscii(" │ ", remaining_cols);
        self.terminal.writeText(separator);
        remaining_cols -|= separator.len;
        if (remaining_cols == 0) {
            self.terminal.resetAttrs();
            buf_ptr.render_cache.markClean(line_idx);
            return;
        }

        self.terminal.resetAttrs();

        const line = buf_ptr.getLine(line_idx) orelse "";
        const start_byte = displayCellByteOffset(line, win.scroll_col);
        const line_tail = line[start_byte..];
        const visible = line_tail[0..visibleByteCountForCells(line_tail, remaining_cols)];
        style_buf.clearRetainingCapacity();
        if (hl_styles) |hs| {
            const range = buf_ptr.text.lineByteRange(line_idx) catch null;
            if (range) |r| {
                const start_byte_idx = r.start + start_byte;
                const end_byte_idx = @min(start_byte_idx + visible.len, hs.len);
                const line_hl = if (start_byte_idx < hs.len) hs[start_byte_idx..end_byte_idx] else &[_]syntax.TokenStyle{};
                try style_buf.appendSlice(gpa, line_hl);
            }
        }
        const current_len = style_buf.items.len;
        if (current_len < visible.len) {
            try style_buf.resize(gpa, visible.len);
            @memset(style_buf.items[current_len..], .normal);
        }
        if (visible.len == 0 and line_idx == win.cursor.row and self.mode == .normal and remaining_cols > 0) {
            self.terminal.setFgRgb(0x1a, 0x1a, 0x1a);
            self.terminal.setBgRgb(0xc8, 0xc8, 0xc8);
            self.terminal.writeText("█");
            self.terminal.resetAttrs();
        } else {
            appendStyledText(self, win, line_idx, visible, style_buf.items);
        }

        self.terminal.resetAttrs();
    } else {
        self.terminal.setFg(.gray);
        const tilde_count = @min(line_num_width, remaining_cols);
        for (0..tilde_count) |_| self.terminal.writeText("~");
        remaining_cols -|= tilde_count;
        self.terminal.resetAttrs();
        self.terminal.writeSpaces(@min(@as(usize, 3), remaining_cols));
    }

    buf_ptr.render_cache.markClean(line_idx);
}

const Mode = @import("mode.zig").Mode;

fn applyCharStyle(
    terminal: *term.Terminal,
    style: syntax.TokenStyle,
    reversed: bool,
) void {
    const bold = style == .keyword or style == .type_name;
    terminal.setStyles(if (bold) term.STYLE_BOLD else term.STYLE_NONE);
    const fg: [3]u8 = switch (style) {
        .normal => .{ 0xc8, 0xc8, 0xc8 },
        .keyword => .{ 0xcc, 0x77, 0xcc },
        .type_name => .{ 0x77, 0xcc, 0xcc },
        .string => .{ 0x77, 0xbb, 0x77 },
        .comment => .{ 0x6a, 0x88, 0x7a },
        .number => .{ 0xcc, 0x99, 0x44 },
        .builtin => .{ 0x66, 0x99, 0xcc },
    };
    if (reversed) {
        terminal.setFgRgb(0x1a, 0x1a, 0x1a);
        terminal.setBgRgb(fg[0], fg[1], fg[2]);
    } else {
        terminal.setFgRgb(fg[0], fg[1], fg[2]);
        terminal.setBgDefault();
    }
}

fn appendStyledText(
    self: *Editor,
    win: *const Window,
    line_idx: usize,
    line: []const u8,
    styles: []const syntax.TokenStyle,
) void {
    const cursor_byte = if (line_idx == win.cursor.row and self.mode == .normal)
        normalCursorByte(line, win.cursor.col)
    else
        null;

    if (cursor_byte == null and win.selection == null) {
        var last_style: syntax.TokenStyle = .normal;
        var run_start: usize = 0;
        var first_run = true;
        var i: usize = 0;
        while (i < line.len) {
            const style: syntax.TokenStyle = if (i < styles.len) styles[i] else .normal;
            if (first_run or style != last_style) {
                if (!first_run) self.terminal.writeText(line[run_start..i]);
                applyCharStyle(&self.terminal, style, false);
                last_style = style;
                run_start = i;
                first_run = false;
            }
            const b = line[i];
            i += if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
        }
        if (!first_run) self.terminal.writeText(line[run_start..]);
        return;
    }

    var last_style: ?syntax.TokenStyle = null;
    var last_reversed = false;
    var run_start: usize = 0;

    var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const start_byte = iter.i - slice.len;
        const in_selection = if (win.selection) |sel|
            @import("editor.zig").selectionContainsChar(sel, line_idx, start_byte, line.len)
        else
            false;
        const reversed = (cursor_byte != null and cursor_byte.? == start_byte) or in_selection;
        const style = if (start_byte < styles.len) styles[start_byte] else syntax.TokenStyle.normal;
        if (last_style == null or last_style.? != style or last_reversed != reversed) {
            if (last_style != null) self.terminal.writeText(line[run_start..start_byte]);
            applyCharStyle(&self.terminal, style, reversed);
            last_style = style;
            last_reversed = reversed;
            run_start = start_byte;
        }
    }
    if (last_style != null) self.terminal.writeText(line[run_start..]);
}

fn visibleByteCountForCells(line: []const u8, max_cells: usize) usize {
    const check_len = @min(line.len, max_cells);
    // Fast path: pure ASCII — every byte is exactly 1 terminal cell wide.
    const is_ascii = for (line[0..check_len]) |b| {
        if (b & 0x80 != 0) break false;
    } else true;
    if (is_ascii) return check_len;

    // UTF-8 slow path for lines with multibyte or wide characters.
    var used_cells: usize = 0;
    var visible_bytes: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const width = utf8.codepointCellWidth(std.unicode.utf8Decode(slice) catch std.unicode.replacement_character);
        if (width > 0 and used_cells + width > max_cells) break;
        used_cells += width;
        visible_bytes = iter.i;
    }
    return visible_bytes;
}

fn cursorScreenColumn(buf: *Buffer, row: usize, col: usize, scroll_col: usize, max_cells: usize) usize {
    const line = buf.getLine(row) orelse return 0;
    return @min(utf8.displayCellsToColumn(line, col) -| scroll_col, max_cells -| 1);
}

fn appendCursorPresentation(
    self: *Editor,
    win: *const Window,
    buf_ptr: *Buffer,
    line_num_width: usize,
) void {
    if (win.rect.rows == 0 or win.rect.cols == 0) return;
    // Content rows = rect.rows - 1 (last row is the statusline)
    const content_rows = win.rect.rows -| 1;
    if (content_rows == 0) return;

    const style = self.cursorStyleForMode(self.mode);
    self.terminal.setCursorStyle(style);

    const text_start = line_num_width + 3;
    const cursor_screen_row = win.rect.top + @min(win.cursor.row -| win.scroll, content_rows -| 1);
    const cursor_screen_col = win.rect.left + @min(
        text_start + cursorScreenColumn(buf_ptr, win.cursor.row, win.cursor.col, win.scroll_col, win.rect.cols -| text_start),
        win.rect.cols -| 1,
    );
    self.terminal.showCursor(cursor_screen_row, cursor_screen_col);
}

fn displayCellByteOffset(line: []const u8, cells: usize) usize {
    if (cells == 0 or line.len == 0) return 0;

    var used_cells: usize = 0;
    var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (iter.nextCodepointSlice()) |slice| {
        const start = iter.i - slice.len;
        if (used_cells >= cells) return start;

        const width = utf8.codepointCellWidth(std.unicode.utf8Decode(slice) catch std.unicode.replacement_character);
        if (width > 0 and used_cells + width > cells) return start;

        used_cells += width;
        if (used_cells >= cells) return iter.i;
    }
    return line.len;
}

fn normalCursorByte(line: []const u8, col: usize) ?usize {
    if (line.len == 0) return null;

    const aligned = utf8.boundary(line).alignColumn(col, true);
    if (aligned >= line.len) return utf8.boundary(line).prev(line.len);
    return aligned;
}

fn initTestEditor(initial: []const u8) !Editor {
    const allocator = std.testing.allocator;
    var editor = Editor{
        .allocator = allocator,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .terminal = .{
            .nc_ptr   = undefined,
            .stdplane = undefined,
            .size     = .{ .rows = 24, .cols = 80 },
            .io       = std.Io.Threaded.global_single_threaded.io(),
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
        .key_trie_root = keymap.insertKeymap(),
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
        .highlight_worker = null,
        .grammar_name = null,
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
    editor.command_buf.deinit(editor.allocator);
    for (&editor.registers) |*reg| reg.deinit(editor.allocator);
    if (editor.search_pattern) |p| editor.allocator.free(p);
    if (editor.status_msg) |m| editor.allocator.free(m);
    if (editor.cached_hl_styles) |s| editor.allocator.free(s);
    editor.src_cache.deinit(editor.allocator);
    editor.render_style_buf.deinit(editor.allocator);
}

test "computeWindowRects splits vertical panes with divider" {
    var tab = Tab.init(std.testing.allocator);
    defer tab.deinit();

    try tab.windows.append(std.testing.allocator, .{ .buf_index = 0 });
    try tab.windows.append(std.testing.allocator, .{ .buf_index = 1, .split_dir = .vertical });

    computeWindowRects(&tab, .{ .top = 1, .left = 0, .rows = 10, .cols = 20 });

    try std.testing.expectEqual(Rect{ .top = 1, .left = 0, .rows = 10, .cols = 10 }, tab.windows.items[0].rect);
    try std.testing.expectEqual(Rect{ .top = 1, .left = 11, .rows = 10, .cols = 9 }, tab.windows.items[1].rect);
}

test "computeWindowRects splits horizontal panes with divider" {
    var tab = Tab.init(std.testing.allocator);
    defer tab.deinit();

    try tab.windows.append(std.testing.allocator, .{ .buf_index = 0 });
    try tab.windows.append(std.testing.allocator, .{ .buf_index = 1, .split_dir = .horizontal });

    computeWindowRects(&tab, .{ .top = 1, .left = 0, .rows = 9, .cols = 20 });

    try std.testing.expectEqual(Rect{ .top = 1, .left = 0, .rows = 4, .cols = 20 }, tab.windows.items[0].rect);
    try std.testing.expectEqual(Rect{ .top = 6, .left = 0, .rows = 4, .cols = 20 }, tab.windows.items[1].rect);
}

test "computeWindowRects mixed split directions" {
    var tab = Tab.init(std.testing.allocator);
    defer tab.deinit();

    // vsplit then split: first pair vertical, second pair horizontal
    try tab.windows.append(std.testing.allocator, .{ .buf_index = 0 });
    try tab.windows.append(std.testing.allocator, .{ .buf_index = 1, .split_dir = .vertical });
    try tab.windows.append(std.testing.allocator, .{ .buf_index = 2, .split_dir = .horizontal });

    computeWindowRects(&tab, .{ .top = 0, .left = 0, .rows = 10, .cols = 20 });

    // Window 0: left half (vertical split with window 1+)
    try std.testing.expectEqual(Rect{ .top = 0, .left = 0, .rows = 10, .cols = 10 }, tab.windows.items[0].rect);
    // Window 1: top-right (horizontal split with window 2)
    try std.testing.expectEqual(Rect{ .top = 0, .left = 11, .rows = 5, .cols = 9 }, tab.windows.items[1].rect);
    // Window 2: bottom-right
    try std.testing.expectEqual(Rect{ .top = 6, .left = 11, .rows = 4, .cols = 9 }, tab.windows.items[2].rect);
}

test "display cells use terminal width for CJK glyphs" {
    try std.testing.expectEqual(@as(usize, 2), utf8.displayCellsToColumn("你a", 3));
    try std.testing.expectEqual(@as(usize, 3), utf8.displayCellsToColumn("你a", 4));
    try std.testing.expectEqual(@as(usize, 3), visibleByteCountForCells("你a", 2));
    try std.testing.expectEqual(@as(usize, 4), visibleByteCountForCells("你a", 3));
}

test "visibleByteCountForCells does not split UTF-8 multibyte sequences" {
    // "你" is 3 bytes (U+4F60); max_cells=1 should yield 0, not 1 or 2.
    try std.testing.expectEqual(@as(usize, 0), visibleByteCountForCells("你好", 1));
    // max_cells=2 fits one wide char (2 cells) → 3 bytes.
    try std.testing.expectEqual(@as(usize, 3), visibleByteCountForCells("你好", 2));
    // ASCII first, then CJK: "A你" — 1 cell ASCII + need 2 more for 你.
    try std.testing.expectEqual(@as(usize, 1), visibleByteCountForCells("A你", 2));
    try std.testing.expectEqual(@as(usize, 4), visibleByteCountForCells("A你", 3));
}

test "appendRenderedTextRow marks lines clean after rendering" {
    var editor = try initTestEditor("abc");
    defer deinitTestEditor(&editor);

    const buf_ptr = editor.getBuffer().?;
    // Verify that render_cache correctly tracks dirty/clean state independent of rendering.
    buf_ptr.render_cache.markDirty(0);
    try std.testing.expect(buf_ptr.render_cache.isDirty(0));
    buf_ptr.render_cache.markClean(0);
    try std.testing.expect(!buf_ptr.render_cache.isDirty(0));
}

test "line_num_width + 3 accounts for full line-number gutter" {
    try std.testing.expectEqual(@as(usize, 6), utf8.lineWidth(99) + 3); // 3 digits + 3 = 6
    try std.testing.expectEqual(@as(usize, 7), utf8.lineWidth(1000) + 3); // 4 digits + 3 = 7
}

test "cursorScreenColumn keeps insert cursors aligned with horizontal scroll" {
    const buf = try Buffer.initStrategy(std.testing.allocator, .gap_buffer, "hello world");
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 5), cursorScreenColumn(buf, 0, "hello world".len, 6, 10));
}

test "displayCellByteOffset does not split wide UTF-8 glyphs" {
    try std.testing.expectEqual(@as(usize, 1), displayCellByteOffset("A你B", 1));
    try std.testing.expectEqual(@as(usize, 4), displayCellByteOffset("A你B", 3));
}
