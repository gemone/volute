const Key = @import("key.zig").Key;
const BaseKey = @import("key.zig").BaseKey;
const Mode = @import("mode.zig").Mode;

pub const Command = enum {
    // Movement
    move_char_left,
    move_char_right,
    move_visual_line_up,
    move_visual_line_down,
    move_line_up,
    move_line_down,
    move_next_word_start,
    move_prev_word_start,
    move_next_word_end,
    move_next_long_word_start,
    move_prev_long_word_start,
    move_next_long_word_end,
    goto_line_start,
    goto_line_end,
    goto_first_nonwhitespace,
    goto_file_start,
    goto_last_line,
    goto_line,
    goto_column,
    goto_window_top,
    goto_window_center,
    goto_window_bottom,

    // Insert modes
    insert_mode,
    insert_at_line_start,
    insert_at_line_end,
    append_mode,
    open_below,
    open_above,
    open_below_with_indent,
    open_above_with_indent,
    normal_mode,

    // Editing
    delete_selection,
    delete_selection_noyank,
    change_selection,
    change_selection_noyank,
    yank,
    paste_after,
    paste_before,
    undo,
    redo,
    earlier,
    later,

    // Selection
    select_mode,
    extend_line_below,
    select_all,
    collapse_selection,
    flip_selections,
    copy_selection_on_next_line,
    copy_selection_on_prev_line,
    keep_primary_selection,
    remove_primary_selection,

    // Search
    search,
    rsearch,
    search_next,
    search_prev,

    // Find char
    find_till_char,
    find_next_char,
    till_prev_char,
    find_prev_char,
    repeat_last_motion,

    // Replace
    replace,
    replace_with_yanked,
    switch_case,
    switch_to_lowercase,
    switch_to_uppercase,

    // Indent
    indent,
    unindent,
    format_selections,

    // Join/split
    join_selections,

    // Line operations
    extend_to_line_bounds,

    // Surround
    match_brackets,
    surround_add,
    surround_replace,
    surround_delete,

    // View
    page_up,
    page_down,
    page_cursor_half_up,
    page_cursor_half_down,

    // Window
    rotate_view,
    hsplit,
    vsplit,
    wclose,

    // Command mode
    command_mode,

    // File
    save,
    quit,
    force_quit,
    open_file,
    new_file,
    buffer_next,
    buffer_prev,

    // Misc
    no_op,
};

pub const KeyTrie = union(enum) {
    leaf: Command,
    node: *const KeyTrieNode,

    pub const KeyTrieNode = struct {
        name: []const u8,
        bindings: []const Binding,
    };

    pub const Binding = struct {
        key: Key,
        trie: KeyTrie,
    };
};

pub const LookupResult = struct {
    command: ?Command = null,
    pending: bool = false,
    trie_name: []const u8 = "",
};

fn k(base: BaseKey) Key {
    return .{ .base = base };
}

fn kc(base: BaseKey) Key {
    return .{ .base = base, .mod = .{ .ctrl = true } };
}

fn ka(base: BaseKey) Key {
    return .{ .base = base, .mod = .{ .alt = true } };
}

// --- Normal mode trie nodes (module-level const for static storage) ---

const goto_node: KeyTrie.KeyTrieNode = .{
    .name = "Goto",
    .bindings = &.{
        .{ .key = k(.lower_g), .trie = .{ .leaf = .goto_file_start } },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .goto_last_line } },
        .{ .key = k(.lower_h), .trie = .{ .leaf = .goto_line_start } },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .goto_line_end } },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .goto_first_nonwhitespace } },
        .{ .key = k(.pipe), .trie = .{ .leaf = .goto_column } },
        .{ .key = k(.lower_t), .trie = .{ .leaf = .goto_window_top } },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .goto_window_center } },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .goto_window_bottom } },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_line_up } },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_line_down } },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .goto_line } },
    },
};

const match_node: KeyTrie.KeyTrieNode = .{
    .name = "Match",
    .bindings = &.{
        .{ .key = k(.lower_m), .trie = .{ .leaf = .match_brackets } },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .surround_add } },
        .{ .key = k(.lower_r), .trie = .{ .leaf = .surround_replace } },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .surround_delete } },
    },
};

const window_node: KeyTrie.KeyTrieNode = .{
    .name = "Window",
    .bindings = &.{
        .{ .key = kc(.lower_w), .trie = .{ .leaf = .rotate_view } },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .rotate_view } },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .hsplit } },
        .{ .key = k(.lower_v), .trie = .{ .leaf = .vsplit } },
        .{ .key = k(.lower_q), .trie = .{ .leaf = .wclose } },
    },
};

const space_node: KeyTrie.KeyTrieNode = .{
    .name = "Space",
    .bindings = &.{
        .{ .key = k(.lower_f), .trie = .{ .leaf = .open_file } },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .save } },
        .{ .key = k(.lower_q), .trie = .{ .leaf = .quit } },
        .{ .key = k(.lower_n), .trie = .{ .leaf = .buffer_next } },
        .{ .key = k(.lower_p), .trie = .{ .leaf = .buffer_prev } },
    },
};

const normal_node: KeyTrie.KeyTrieNode = .{
    .name = "Normal mode",
    .bindings = &.{
        // Movement
        .{ .key = k(.lower_h), .trie = .{ .leaf = .move_char_left } },
        .{ .key = k(.left), .trie = .{ .leaf = .move_char_left } },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_visual_line_down } },
        .{ .key = k(.down), .trie = .{ .leaf = .move_visual_line_down } },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_visual_line_up } },
        .{ .key = k(.up), .trie = .{ .leaf = .move_visual_line_up } },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .move_char_right } },
        .{ .key = k(.right), .trie = .{ .leaf = .move_char_right } },

        .{ .key = k(.lower_w), .trie = .{ .leaf = .move_next_word_start } },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .move_prev_word_start } },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .move_next_word_end } },
        .{ .key = k(.upper_w), .trie = .{ .leaf = .move_next_long_word_start } },
        .{ .key = k(.upper_b), .trie = .{ .leaf = .move_prev_long_word_start } },
        .{ .key = k(.upper_e), .trie = .{ .leaf = .move_next_long_word_end } },

        .{ .key = k(.home), .trie = .{ .leaf = .goto_line_start } },
        .{ .key = k(.end), .trie = .{ .leaf = .goto_line_end } },

        // Insert modes
        .{ .key = k(.lower_i), .trie = .{ .leaf = .insert_mode } },
        .{ .key = k(.upper_i), .trie = .{ .leaf = .insert_at_line_start } },
        .{ .key = k(.lower_a), .trie = .{ .leaf = .append_mode } },
        .{ .key = k(.upper_a), .trie = .{ .leaf = .insert_at_line_end } },
        .{ .key = k(.lower_o), .trie = .{ .leaf = .open_below_with_indent } },
        .{ .key = k(.upper_o), .trie = .{ .leaf = .open_above_with_indent } },

        // Editing
        .{ .key = k(.lower_d), .trie = .{ .leaf = .delete_selection } },
        .{ .key = ka(.lower_d), .trie = .{ .leaf = .delete_selection_noyank } },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .change_selection } },
        .{ .key = ka(.lower_c), .trie = .{ .leaf = .change_selection_noyank } },
        .{ .key = k(.lower_y), .trie = .{ .leaf = .yank } },
        .{ .key = k(.lower_p), .trie = .{ .leaf = .paste_after } },
        .{ .key = k(.upper_p), .trie = .{ .leaf = .paste_before } },
        .{ .key = k(.lower_u), .trie = .{ .leaf = .undo } },
        .{ .key = k(.upper_u), .trie = .{ .leaf = .redo } },

        // Find char
        .{ .key = k(.lower_t), .trie = .{ .leaf = .find_till_char } },
        .{ .key = k(.lower_f), .trie = .{ .leaf = .find_next_char } },
        .{ .key = k(.upper_t), .trie = .{ .leaf = .till_prev_char } },
        .{ .key = k(.upper_f), .trie = .{ .leaf = .find_prev_char } },
        .{ .key = k(.lower_r), .trie = .{ .leaf = .replace } },
        .{ .key = k(.upper_r), .trie = .{ .leaf = .replace_with_yanked } },

        // Case
        .{ .key = k(.tilde), .trie = .{ .leaf = .switch_case } },
        .{ .key = k(.backtick), .trie = .{ .leaf = .switch_to_lowercase } },

        // Selection
        .{ .key = k(.lower_v), .trie = .{ .leaf = .select_mode } },
        .{ .key = k(.lower_x), .trie = .{ .leaf = .extend_line_below } },
        .{ .key = k(.upper_x), .trie = .{ .leaf = .extend_to_line_bounds } },
        .{ .key = k(.percent), .trie = .{ .leaf = .select_all } },
        .{ .key = k(.semicolon), .trie = .{ .leaf = .collapse_selection } },
        .{ .key = k(.upper_c), .trie = .{ .leaf = .copy_selection_on_next_line } },

        // Search
        .{ .key = k(.slash), .trie = .{ .leaf = .search } },
        .{ .key = k(.question), .trie = .{ .leaf = .rsearch } },
        .{ .key = k(.lower_n), .trie = .{ .leaf = .search_next } },
        .{ .key = k(.upper_n), .trie = .{ .leaf = .search_prev } },

        // Indent
        .{ .key = k(.greater), .trie = .{ .leaf = .indent } },
        .{ .key = k(.less), .trie = .{ .leaf = .unindent } },
        .{ .key = k(.equal), .trie = .{ .leaf = .format_selections } },

        // Join
        .{ .key = k(.upper_j), .trie = .{ .leaf = .join_selections } },

        // Match
        .{ .key = k(.upper_m), .trie = .{ .leaf = .match_brackets } },

        // Goto prefix
        .{ .key = k(.lower_g), .trie = .{ .node = &goto_node } },

        // G (shift-g) = goto last line
        .{ .key = k(.upper_g), .trie = .{ .leaf = .goto_last_line } },

        // Match prefix
        .{ .key = k(.lower_m), .trie = .{ .node = &match_node } },

        // Window prefix
        .{ .key = kc(.lower_w), .trie = .{ .node = &window_node } },

        // Page navigation
        .{ .key = kc(.lower_b), .trie = .{ .leaf = .page_up } },
        .{ .key = k(.page_up), .trie = .{ .leaf = .page_up } },
        .{ .key = kc(.lower_f), .trie = .{ .leaf = .page_down } },
        .{ .key = k(.page_down), .trie = .{ .leaf = .page_down } },
        .{ .key = kc(.lower_u), .trie = .{ .leaf = .page_cursor_half_up } },
        .{ .key = kc(.lower_d), .trie = .{ .leaf = .page_cursor_half_down } },

        // Command mode
        .{ .key = k(.colon), .trie = .{ .leaf = .command_mode } },

        // Escape
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode } },

        // Space prefix (leader)
        .{ .key = k(.space), .trie = .{ .node = &space_node } },
    },
};

const insert_node: KeyTrie.KeyTrieNode = .{
    .name = "Insert mode",
    .bindings = &.{
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode } },
        .{ .key = kc(.lower_c), .trie = .{ .leaf = .normal_mode } },
        .{ .key = k(.backspace), .trie = .{ .leaf = .no_op } },
        .{ .key = k(.enter), .trie = .{ .leaf = .no_op } },
        .{ .key = k(.tab), .trie = .{ .leaf = .no_op } },
        .{ .key = k(.left), .trie = .{ .leaf = .move_char_left } },
        .{ .key = k(.right), .trie = .{ .leaf = .move_char_right } },
        .{ .key = k(.up), .trie = .{ .leaf = .move_visual_line_up } },
        .{ .key = k(.down), .trie = .{ .leaf = .move_visual_line_down } },
        .{ .key = k(.home), .trie = .{ .leaf = .goto_line_start } },
        .{ .key = k(.end), .trie = .{ .leaf = .goto_line_end } },
    },
};

const select_node: KeyTrie.KeyTrieNode = .{
    .name = "Select mode",
    .bindings = &.{
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode } },
        .{ .key = k(.lower_h), .trie = .{ .leaf = .move_char_left } },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_visual_line_down } },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_visual_line_up } },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .move_char_right } },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .move_next_word_start } },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .move_prev_word_start } },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .move_next_word_end } },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .delete_selection } },
        .{ .key = ka(.lower_d), .trie = .{ .leaf = .delete_selection_noyank } },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .change_selection } },
        .{ .key = ka(.lower_c), .trie = .{ .leaf = .change_selection_noyank } },
        .{ .key = k(.lower_y), .trie = .{ .leaf = .yank } },
        .{ .key = k(.colon), .trie = .{ .leaf = .command_mode } },
    },
};

pub fn normalKeymap() KeyTrie {
    return .{ .node = &normal_node };
}

pub fn insertKeymap() KeyTrie {
    return .{ .node = &insert_node };
}

pub fn selectKeymap() KeyTrie {
    return .{ .node = &select_node };
}

pub fn lookup(root: *const KeyTrie, keys: []const Key) LookupResult {
    if (keys.len == 0) return .{};

    var current = root;
    for (keys, 0..) |key, depth| {
        switch (current.*) {
            .leaf => {
                if (depth < keys.len - 1) return .{};
                return .{ .command = current.leaf };
            },
            .node => {
                var found = false;
                for (current.node.bindings, 0..) |binding, i| {
                    if (binding.key.eql(key)) {
                        current = &current.node.bindings[i].trie;
                        found = true;
                        break;
                    }
                }
                if (!found) return .{};
            },
        }
    }

    switch (current.*) {
        .leaf => |cmd| return .{ .command = cmd },
        .node => |node| return .{ .pending = true, .trie_name = node.name },
    }
}
