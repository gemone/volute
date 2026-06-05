const std = @import("std");
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
    delete_current_line,
    delete_current_line_noyank,
    change_selection,
    change_selection_noyank,
    change_current_line,
    change_current_line_noyank,
    yank,
    yank_current_line,
    paste_after,
    paste_before,
    undo,
    redo,
    jump_back,
    jump_forward,
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
    scroll_cursor_center,
    scroll_cursor_top,
    scroll_cursor_bottom,

    // Window
    rotate_view,
    hsplit,
    vsplit,
    wclose,
    focus_window_left,
    focus_window_right,
    focus_window_up,
    focus_window_down,
    window_only,
    tab_new,
    tab_close,
    tab_next,
    tab_prev,
    float_open,
    float_close,
    which_key_cheatsheet,

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
        desc: []const u8 = "",
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
        .{ .key = k(.lower_g), .trie = .{ .leaf = .goto_file_start }, .desc = "file start" },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .goto_last_line }, .desc = "last line" },
        .{ .key = k(.lower_h), .trie = .{ .leaf = .goto_line_start }, .desc = "line start" },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .goto_line_end }, .desc = "line end" },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .goto_first_nonwhitespace }, .desc = "first non-ws" },
        .{ .key = k(.pipe), .trie = .{ .leaf = .goto_column }, .desc = "goto column" },
        .{ .key = k(.lower_t), .trie = .{ .leaf = .tab_next }, .desc = "tab next" },
        .{ .key = k(.upper_t), .trie = .{ .leaf = .tab_prev }, .desc = "tab prev" },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .goto_window_center }, .desc = "win center" },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .goto_window_bottom }, .desc = "win bottom" },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_line_up }, .desc = "line up" },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_line_down }, .desc = "line down" },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .goto_line }, .desc = "goto line#" },
    },
};

const match_node: KeyTrie.KeyTrieNode = .{
    .name = "Match",
    .bindings = &.{
        .{ .key = k(.lower_m), .trie = .{ .leaf = .match_brackets }, .desc = "match brackets" },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .surround_add }, .desc = "surround add" },
        .{ .key = k(.lower_r), .trie = .{ .leaf = .surround_replace }, .desc = "surround replace" },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .surround_delete }, .desc = "surround delete" },
    },
};

const ctrl_w_node: KeyTrie.KeyTrieNode = .{
    .name = "Window",
    .bindings = &.{
        .{ .key = kc(.lower_w), .trie = .{ .leaf = .rotate_view }, .desc = "next win" },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .rotate_view }, .desc = "next win" },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .hsplit }, .desc = "hsplit" },
        .{ .key = k(.lower_v), .trie = .{ .leaf = .vsplit }, .desc = "vsplit" },
        .{ .key = k(.lower_h), .trie = .{ .leaf = .focus_window_left }, .desc = "focus left" },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .focus_window_down }, .desc = "focus down" },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .focus_window_up }, .desc = "focus up" },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .focus_window_right }, .desc = "focus right" },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .wclose }, .desc = "close win" },
        .{ .key = k(.lower_o), .trie = .{ .leaf = .window_only }, .desc = "only win" },
        .{ .key = k(.lower_q), .trie = .{ .leaf = .wclose }, .desc = "close win" },
    },
};

const scroll_node: KeyTrie.KeyTrieNode = .{
    .name = "Scroll",
    .bindings = &.{
        .{ .key = k(.lower_z), .trie = .{ .leaf = .scroll_cursor_center }, .desc = "center" },
        .{ .key = k(.lower_t), .trie = .{ .leaf = .scroll_cursor_top }, .desc = "top" },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .scroll_cursor_bottom }, .desc = "bottom" },
    },
};

const space_node: KeyTrie.KeyTrieNode = .{
    .name = "Space",
    .bindings = &.{
        .{ .key = k(.lower_f), .trie = .{ .leaf = .open_file }, .desc = "open file" },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .save }, .desc = "save" },
        .{ .key = k(.lower_q), .trie = .{ .leaf = .quit }, .desc = "quit" },
        .{ .key = k(.lower_s), .trie = .{ .leaf = .hsplit }, .desc = "hsplit" },
        .{ .key = k(.lower_v), .trie = .{ .leaf = .vsplit }, .desc = "vsplit" },
        .{ .key = k(.lower_n), .trie = .{ .leaf = .buffer_next }, .desc = "next buf" },
        .{ .key = k(.lower_p), .trie = .{ .leaf = .buffer_prev }, .desc = "prev buf" },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .float_open }, .desc = "float buf" },
        .{ .key = k(.question), .trie = .{ .leaf = .which_key_cheatsheet }, .desc = "cheatsheet" },
    },
};

const normal_node: KeyTrie.KeyTrieNode = .{
    .name = "Normal mode",
    .bindings = &.{
        // Movement
        .{ .key = k(.lower_h), .trie = .{ .leaf = .move_char_left }, .desc = "move left" },
        .{ .key = k(.left), .trie = .{ .leaf = .move_char_left }, .desc = "move left" },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_visual_line_down }, .desc = "move down" },
        .{ .key = k(.down), .trie = .{ .leaf = .move_visual_line_down }, .desc = "move down" },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_visual_line_up }, .desc = "move up" },
        .{ .key = k(.up), .trie = .{ .leaf = .move_visual_line_up }, .desc = "move up" },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .move_char_right }, .desc = "move right" },
        .{ .key = k(.right), .trie = .{ .leaf = .move_char_right }, .desc = "move right" },

        .{ .key = k(.lower_w), .trie = .{ .leaf = .move_next_word_start }, .desc = "next word" },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .move_prev_word_start }, .desc = "prev word" },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .move_next_word_end }, .desc = "word end" },
        .{ .key = k(.upper_w), .trie = .{ .leaf = .move_next_long_word_start }, .desc = "next WORD" },
        .{ .key = k(.upper_b), .trie = .{ .leaf = .move_prev_long_word_start }, .desc = "prev WORD" },
        .{ .key = k(.upper_e), .trie = .{ .leaf = .move_next_long_word_end }, .desc = "WORD end" },

        .{ .key = k(.home), .trie = .{ .leaf = .goto_line_start }, .desc = "line start" },
        .{ .key = k(.end), .trie = .{ .leaf = .goto_line_end }, .desc = "line end" },

        // Insert modes
        .{ .key = k(.lower_i), .trie = .{ .leaf = .insert_mode }, .desc = "insert" },
        .{ .key = k(.upper_i), .trie = .{ .leaf = .insert_at_line_start }, .desc = "insert line start" },
        .{ .key = k(.lower_a), .trie = .{ .leaf = .append_mode }, .desc = "append" },
        .{ .key = k(.upper_a), .trie = .{ .leaf = .insert_at_line_end }, .desc = "append line end" },
        .{ .key = k(.lower_o), .trie = .{ .leaf = .open_below_with_indent }, .desc = "open below" },
        .{ .key = k(.upper_o), .trie = .{ .leaf = .open_above_with_indent }, .desc = "open above" },

        // Editing
        .{ .key = k(.lower_d), .trie = .{ .leaf = .delete_selection }, .desc = "delete" },
        .{ .key = k(.delete), .trie = .{ .leaf = .delete_selection }, .desc = "delete" },
        .{ .key = ka(.lower_d), .trie = .{ .leaf = .delete_selection_noyank }, .desc = "delete no yank" },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .change_current_line }, .desc = "change line" },
        .{ .key = ka(.lower_c), .trie = .{ .leaf = .change_selection_noyank }, .desc = "change no yank" },
        .{ .key = k(.lower_y), .trie = .{ .leaf = .yank_current_line }, .desc = "yank line" },
        .{ .key = k(.lower_p), .trie = .{ .leaf = .paste_after }, .desc = "paste after" },
        .{ .key = k(.upper_p), .trie = .{ .leaf = .paste_before }, .desc = "paste before" },
        .{ .key = k(.lower_u), .trie = .{ .leaf = .undo }, .desc = "undo" },
        .{ .key = k(.upper_u), .trie = .{ .leaf = .redo }, .desc = "redo" },

        // Find char
        .{ .key = k(.lower_t), .trie = .{ .leaf = .find_till_char }, .desc = "till char" },
        .{ .key = k(.lower_f), .trie = .{ .leaf = .find_next_char }, .desc = "find char" },
        .{ .key = k(.upper_t), .trie = .{ .leaf = .till_prev_char }, .desc = "till prev" },
        .{ .key = k(.upper_f), .trie = .{ .leaf = .find_prev_char }, .desc = "find prev" },
        .{ .key = ka(.dot), .trie = .{ .leaf = .repeat_last_motion }, .desc = "repeat last motion" },
        .{ .key = k(.lower_r), .trie = .{ .leaf = .replace }, .desc = "replace char" },
        .{ .key = k(.upper_r), .trie = .{ .leaf = .replace_with_yanked }, .desc = "replace yanked" },

        // Case
        .{ .key = k(.tilde), .trie = .{ .leaf = .switch_case }, .desc = "switch case" },
        .{ .key = k(.backtick), .trie = .{ .leaf = .switch_to_lowercase }, .desc = "to lowercase" },
        .{ .key = ka(.backtick), .trie = .{ .leaf = .switch_to_uppercase }, .desc = "to uppercase" },

        // Selection
        .{ .key = k(.lower_v), .trie = .{ .leaf = .select_mode }, .desc = "visual mode" },
        .{ .key = k(.lower_x), .trie = .{ .leaf = .extend_line_below }, .desc = "extend line" },
        .{ .key = k(.upper_x), .trie = .{ .leaf = .extend_to_line_bounds }, .desc = "extend to bounds" },
        .{ .key = k(.percent), .trie = .{ .leaf = .select_all }, .desc = "select all" },
        .{ .key = k(.semicolon), .trie = .{ .leaf = .collapse_selection }, .desc = "collapse sel" },
        .{ .key = ka(.semicolon), .trie = .{ .leaf = .flip_selections }, .desc = "flip sels" },
        .{ .key = k(.upper_c), .trie = .{ .leaf = .copy_selection_on_next_line }, .desc = "copy sel down" },
        .{ .key = ka(.upper_c), .trie = .{ .leaf = .copy_selection_on_prev_line }, .desc = "copy sel up" },

        // Search
        .{ .key = k(.slash), .trie = .{ .leaf = .search }, .desc = "search" },
        .{ .key = k(.question), .trie = .{ .leaf = .rsearch }, .desc = "search reverse" },
        .{ .key = k(.lower_n), .trie = .{ .leaf = .search_next }, .desc = "search next" },
        .{ .key = k(.upper_n), .trie = .{ .leaf = .search_prev }, .desc = "search prev" },

        // Indent
        .{ .key = k(.greater), .trie = .{ .leaf = .indent }, .desc = "indent" },
        .{ .key = k(.less), .trie = .{ .leaf = .unindent }, .desc = "unindent" },
        .{ .key = k(.equal), .trie = .{ .leaf = .format_selections }, .desc = "format" },

        // Join
        .{ .key = k(.upper_j), .trie = .{ .leaf = .join_selections }, .desc = "join" },

        // Match
        .{ .key = k(.upper_m), .trie = .{ .leaf = .match_brackets }, .desc = "match brackets" },

        // Goto prefix
        .{ .key = k(.lower_g), .trie = .{ .node = &goto_node }, .desc = "goto..." },

        // G (shift-g) = goto last line
        .{ .key = k(.upper_g), .trie = .{ .leaf = .goto_last_line }, .desc = "last line" },

        // Scroll prefix
        .{ .key = k(.lower_z), .trie = .{ .node = &scroll_node }, .desc = "scroll..." },

        // Match prefix
        .{ .key = k(.lower_m), .trie = .{ .node = &match_node }, .desc = "match..." },

        // Window prefix
        .{ .key = kc(.lower_w), .trie = .{ .node = &ctrl_w_node }, .desc = "window..." },

        // Page navigation
        .{ .key = kc(.lower_b), .trie = .{ .leaf = .page_up }, .desc = "page up" },
        .{ .key = k(.page_up), .trie = .{ .leaf = .page_up }, .desc = "page up" },
        .{ .key = kc(.lower_f), .trie = .{ .leaf = .page_down }, .desc = "page down" },
        .{ .key = k(.page_down), .trie = .{ .leaf = .page_down }, .desc = "page down" },
        .{ .key = kc(.lower_u), .trie = .{ .leaf = .page_cursor_half_up }, .desc = "half page up" },
        .{ .key = kc(.lower_d), .trie = .{ .leaf = .page_cursor_half_down }, .desc = "half page down" },
        .{ .key = kc(.lower_o), .trie = .{ .leaf = .jump_back }, .desc = "jump back" },
        .{ .key = kc(.lower_i), .trie = .{ .leaf = .jump_forward }, .desc = "jump forward" },
        .{ .key = kc(.lower_s), .trie = .{ .leaf = .save }, .desc = "save" },
        .{ .key = kc(.lower_z), .trie = .{ .leaf = .undo }, .desc = "undo" },

        // Command mode
        .{ .key = k(.colon), .trie = .{ .leaf = .command_mode }, .desc = "command" },

        // Escape
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode }, .desc = "" },

        // Space prefix (leader)
        .{ .key = k(.space), .trie = .{ .node = &space_node }, .desc = "leader..." },
    },
};

const insert_node: KeyTrie.KeyTrieNode = .{
    .name = "Insert mode",
    .bindings = &.{
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode }, .desc = "" },
        .{ .key = kc(.lower_c), .trie = .{ .leaf = .normal_mode }, .desc = "" },
        .{ .key = k(.backspace), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = k(.enter), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = k(.tab), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = k(.backtab), .trie = .{ .leaf = .unindent }, .desc = "unindent" },
        .{ .key = kc(.lower_n), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = kc(.lower_p), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = kc(.lower_r), .trie = .{ .leaf = .no_op }, .desc = "" },
        .{ .key = kc(.lower_b), .trie = .{ .leaf = .page_up }, .desc = "page up" },
        .{ .key = kc(.lower_f), .trie = .{ .leaf = .page_down }, .desc = "page down" },
        .{ .key = kc(.lower_u), .trie = .{ .leaf = .page_cursor_half_up }, .desc = "half page up" },
        .{ .key = kc(.lower_d), .trie = .{ .leaf = .page_cursor_half_down }, .desc = "half page down" },
        .{ .key = kc(.lower_o), .trie = .{ .leaf = .jump_back }, .desc = "jump back" },
        .{ .key = kc(.lower_i), .trie = .{ .leaf = .jump_forward }, .desc = "jump forward" },
        .{ .key = kc(.lower_s), .trie = .{ .leaf = .save }, .desc = "save" },
        .{ .key = kc(.lower_z), .trie = .{ .leaf = .undo }, .desc = "undo" },
        .{ .key = k(.left), .trie = .{ .leaf = .move_char_left }, .desc = "" },
        .{ .key = k(.right), .trie = .{ .leaf = .move_char_right }, .desc = "" },
        .{ .key = k(.up), .trie = .{ .leaf = .move_visual_line_up }, .desc = "" },
        .{ .key = k(.down), .trie = .{ .leaf = .move_visual_line_down }, .desc = "" },
        .{ .key = k(.home), .trie = .{ .leaf = .goto_line_start }, .desc = "" },
        .{ .key = k(.end), .trie = .{ .leaf = .goto_line_end }, .desc = "" },
    },
};

const select_node: KeyTrie.KeyTrieNode = .{
    .name = "Select mode",
    .bindings = &.{
        .{ .key = k(.escape), .trie = .{ .leaf = .normal_mode }, .desc = "" },
        .{ .key = k(.lower_v), .trie = .{ .leaf = .normal_mode }, .desc = "" },
        .{ .key = k(.lower_h), .trie = .{ .leaf = .move_char_left }, .desc = "move left" },
        .{ .key = k(.left), .trie = .{ .leaf = .move_char_left }, .desc = "move left" },
        .{ .key = k(.lower_j), .trie = .{ .leaf = .move_visual_line_down }, .desc = "move down" },
        .{ .key = k(.down), .trie = .{ .leaf = .move_visual_line_down }, .desc = "move down" },
        .{ .key = k(.lower_k), .trie = .{ .leaf = .move_visual_line_up }, .desc = "move up" },
        .{ .key = k(.up), .trie = .{ .leaf = .move_visual_line_up }, .desc = "move up" },
        .{ .key = k(.lower_l), .trie = .{ .leaf = .move_char_right }, .desc = "move right" },
        .{ .key = k(.right), .trie = .{ .leaf = .move_char_right }, .desc = "move right" },
        .{ .key = k(.lower_w), .trie = .{ .leaf = .move_next_word_start }, .desc = "next word" },
        .{ .key = k(.lower_b), .trie = .{ .leaf = .move_prev_word_start }, .desc = "prev word" },
        .{ .key = k(.lower_e), .trie = .{ .leaf = .move_next_word_end }, .desc = "word end" },
        .{ .key = k(.upper_w), .trie = .{ .leaf = .move_next_long_word_start }, .desc = "next WORD" },
        .{ .key = k(.upper_b), .trie = .{ .leaf = .move_prev_long_word_start }, .desc = "prev WORD" },
        .{ .key = k(.upper_e), .trie = .{ .leaf = .move_next_long_word_end }, .desc = "WORD end" },
        .{ .key = k(.home), .trie = .{ .leaf = .goto_line_start }, .desc = "line start" },
        .{ .key = k(.end), .trie = .{ .leaf = .goto_line_end }, .desc = "line end" },
        .{ .key = k(.lower_x), .trie = .{ .leaf = .extend_line_below }, .desc = "extend line" },
        .{ .key = k(.upper_x), .trie = .{ .leaf = .extend_to_line_bounds }, .desc = "extend bounds" },
        .{ .key = k(.percent), .trie = .{ .leaf = .select_all }, .desc = "select all" },
        .{ .key = k(.lower_d), .trie = .{ .leaf = .delete_selection }, .desc = "delete" },
        .{ .key = ka(.lower_d), .trie = .{ .leaf = .delete_selection_noyank }, .desc = "delete no yank" },
        .{ .key = k(.lower_c), .trie = .{ .leaf = .change_selection }, .desc = "change" },
        .{ .key = ka(.lower_c), .trie = .{ .leaf = .change_selection_noyank }, .desc = "change no yank" },
        .{ .key = k(.lower_y), .trie = .{ .leaf = .yank }, .desc = "yank" },
        .{ .key = k(.lower_p), .trie = .{ .leaf = .paste_after }, .desc = "paste after" },
        .{ .key = k(.upper_p), .trie = .{ .leaf = .paste_before }, .desc = "paste before" },
        .{ .key = k(.lower_t), .trie = .{ .leaf = .find_till_char }, .desc = "till char" },
        .{ .key = k(.lower_f), .trie = .{ .leaf = .find_next_char }, .desc = "find char" },
        .{ .key = k(.upper_t), .trie = .{ .leaf = .till_prev_char }, .desc = "till prev" },
        .{ .key = k(.upper_f), .trie = .{ .leaf = .find_prev_char }, .desc = "find prev" },
        .{ .key = ka(.dot), .trie = .{ .leaf = .repeat_last_motion }, .desc = "repeat motion" },
        .{ .key = k(.lower_r), .trie = .{ .leaf = .replace }, .desc = "replace char" },
        .{ .key = k(.upper_r), .trie = .{ .leaf = .replace_with_yanked }, .desc = "replace yanked" },
        .{ .key = k(.tilde), .trie = .{ .leaf = .switch_case }, .desc = "switch case" },
        .{ .key = k(.backtick), .trie = .{ .leaf = .switch_to_lowercase }, .desc = "lowercase" },
        .{ .key = ka(.backtick), .trie = .{ .leaf = .switch_to_uppercase }, .desc = "uppercase" },
        .{ .key = k(.semicolon), .trie = .{ .leaf = .collapse_selection }, .desc = "collapse sel" },
        .{ .key = ka(.semicolon), .trie = .{ .leaf = .flip_selections }, .desc = "flip sels" },
        .{ .key = k(.upper_c), .trie = .{ .leaf = .copy_selection_on_next_line }, .desc = "copy down" },
        .{ .key = ka(.upper_c), .trie = .{ .leaf = .copy_selection_on_prev_line }, .desc = "copy up" },
        .{ .key = k(.slash), .trie = .{ .leaf = .search }, .desc = "search" },
        .{ .key = k(.question), .trie = .{ .leaf = .rsearch }, .desc = "search rev" },
        .{ .key = k(.lower_n), .trie = .{ .leaf = .search_next }, .desc = "search next" },
        .{ .key = k(.upper_n), .trie = .{ .leaf = .search_prev }, .desc = "search prev" },
        .{ .key = k(.greater), .trie = .{ .leaf = .indent }, .desc = "indent" },
        .{ .key = k(.less), .trie = .{ .leaf = .unindent }, .desc = "unindent" },
        .{ .key = k(.equal), .trie = .{ .leaf = .format_selections }, .desc = "format" },
        .{ .key = k(.upper_j), .trie = .{ .leaf = .join_selections }, .desc = "join" },
        .{ .key = kc(.lower_b), .trie = .{ .leaf = .page_up }, .desc = "page up" },
        .{ .key = k(.page_up), .trie = .{ .leaf = .page_up }, .desc = "page up" },
        .{ .key = kc(.lower_f), .trie = .{ .leaf = .page_down }, .desc = "page down" },
        .{ .key = k(.page_down), .trie = .{ .leaf = .page_down }, .desc = "page down" },
        .{ .key = kc(.lower_u), .trie = .{ .leaf = .page_cursor_half_up }, .desc = "half up" },
        .{ .key = kc(.lower_d), .trie = .{ .leaf = .page_cursor_half_down }, .desc = "half down" },
        .{ .key = kc(.lower_o), .trie = .{ .leaf = .jump_back }, .desc = "jump back" },
        .{ .key = kc(.lower_i), .trie = .{ .leaf = .jump_forward }, .desc = "jump forward" },
        .{ .key = kc(.lower_s), .trie = .{ .leaf = .save }, .desc = "save" },
        .{ .key = kc(.lower_z), .trie = .{ .leaf = .undo }, .desc = "undo" },
        .{ .key = k(.colon), .trie = .{ .leaf = .command_mode }, .desc = "command" },
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
    return trieLookup(root, keys);
}

fn trieLookup(root: *const KeyTrie, keys: []const Key) LookupResult {
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

/// Runtime keymap registry — wraps static compile-time trie defaults for each mode
/// and supports runtime `addBinding` for future config-driven customization.
pub const KeyBindingDesc = struct {
    key: []const u8,
    desc: []const u8,
};

/// Extract key_label + desc pairs from the leaf bindings of a trie node.
/// Key labels are formatted into `key_bufs`; entries are written into `entries`.
/// Returns the number of entries written.
/// Used by which-key popup and cheatsheet.
pub fn nodeLeafEntries(node: *const KeyTrie.KeyTrieNode, key_bufs: [][16]u8, entries: []KeyBindingDesc) usize {
    var count: usize = 0;
    for (node.bindings) |binding| {
        if (count >= entries.len or count >= key_bufs.len) break;
        if (binding.desc.len == 0) continue;
        if (binding.trie == .node) continue; // skip sub-nodes
        entries[count] = .{
            .key = binding.key.format(&key_bufs[count]),
            .desc = binding.desc,
        };
        count += 1;
    }
    return count;
}
