const std = @import("std");

pub const Language = enum {
    plain,
    zig,
};

pub const TokenStyle = enum {
    normal,
    keyword,
    type_name,
    string,
    comment,
    number,
    builtin,
};

const zig_keywords = std.StaticStringMap(void).initComptime(.{
    .{ "addrspace", {} },
    .{ "align", {} },
    .{ "allowzero", {} },
    .{ "and", {} },
    .{ "anyframe", {} },
    .{ "anytype", {} },
    .{ "asm", {} },
    .{ "async", {} },
    .{ "await", {} },
    .{ "break", {} },
    .{ "callconv", {} },
    .{ "catch", {} },
    .{ "comptime", {} },
    .{ "const", {} },
    .{ "continue", {} },
    .{ "defer", {} },
    .{ "else", {} },
    .{ "enum", {} },
    .{ "errdefer", {} },
    .{ "error", {} },
    .{ "export", {} },
    .{ "extern", {} },
    .{ "false", {} },
    .{ "fn", {} },
    .{ "for", {} },
    .{ "if", {} },
    .{ "inline", {} },
    .{ "linksection", {} },
    .{ "noalias", {} },
    .{ "noinline", {} },
    .{ "nosuspend", {} },
    .{ "opaque", {} },
    .{ "or", {} },
    .{ "orelse", {} },
    .{ "packed", {} },
    .{ "pub", {} },
    .{ "resume", {} },
    .{ "return", {} },
    .{ "struct", {} },
    .{ "suspend", {} },
    .{ "switch", {} },
    .{ "test", {} },
    .{ "threadlocal", {} },
    .{ "true", {} },
    .{ "try", {} },
    .{ "union", {} },
    .{ "unreachable", {} },
    .{ "usingnamespace", {} },
    .{ "var", {} },
    .{ "volatile", {} },
    .{ "while", {} },
});

const zig_types = std.StaticStringMap(void).initComptime(.{
    .{ "anyopaque", {} },
    .{ "bool", {} },
    .{ "f16", {} },
    .{ "f32", {} },
    .{ "f64", {} },
    .{ "f80", {} },
    .{ "f128", {} },
    .{ "isize", {} },
    .{ "noreturn", {} },
    .{ "type", {} },
    .{ "u8", {} },
    .{ "u16", {} },
    .{ "u32", {} },
    .{ "u64", {} },
    .{ "u128", {} },
    .{ "usize", {} },
    .{ "i8", {} },
    .{ "i16", {} },
    .{ "i32", {} },
    .{ "i64", {} },
    .{ "i128", {} },
});

pub fn detectLanguage(path: ?[]const u8) Language {
    const ext = std.fs.path.extension(path orelse "");
    if (std.mem.eql(u8, ext, ".zig") or std.mem.eql(u8, ext, ".zon")) return .zig;
    return .plain;
}

pub fn highlightLine(
    allocator: std.mem.Allocator,
    language: Language,
    line: []const u8,
    styles: *std.ArrayList(TokenStyle),
) !void {
    styles.clearRetainingCapacity();
    try styles.resize(allocator, line.len);
    @memset(styles.items, .normal);

    switch (language) {
        .plain => {},
        .zig => try highlightZig(line, styles.items),
    }
}

fn highlightZig(line: []const u8, styles: []TokenStyle) !void {
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];
        if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') {
            @memset(styles[i..], .comment);
            return;
        }
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            var j = i + 1;
            var escaped = false;
            while (j < line.len) : (j += 1) {
                if (escaped) {
                    escaped = false;
                    continue;
                }
                if (line[j] == '\\') {
                    escaped = true;
                    continue;
                }
                if (line[j] == quote) {
                    j += 1;
                    break;
                }
            }
            @memset(styles[i..@min(j, line.len)], .string);
            i = @min(j, line.len);
            continue;
        }
        if (ch == '@') {
            var j = i + 1;
            while (j < line.len and isIdentContinue(line[j])) : (j += 1) {}
            @memset(styles[i..j], .builtin);
            i = j;
            continue;
        }
        if (std.ascii.isDigit(ch)) {
            var j = i + 1;
            while (j < line.len and isNumberContinue(line[j])) : (j += 1) {}
            @memset(styles[i..j], .number);
            i = j;
            continue;
        }
        if (isIdentStart(ch)) {
            var j = i + 1;
            while (j < line.len and isIdentContinue(line[j])) : (j += 1) {}
            const ident = line[i..j];
            const style: TokenStyle = if (zig_keywords.has(ident))
                .keyword
            else if (zig_types.has(ident) or std.ascii.isUpper(ident[0]))
                .type_name
            else
                .normal;
            @memset(styles[i..j], style);
            i = j;
            continue;
        }
        i += 1;
    }
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdentContinue(ch: u8) bool {
    return isIdentStart(ch) or std.ascii.isDigit(ch);
}

fn isNumberContinue(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

test "syntax: detects zig language" {
    try std.testing.expectEqual(Language.zig, detectLanguage("src/main.zig"));
    try std.testing.expectEqual(Language.plain, detectLanguage("README.txt"));
}

test "syntax: highlights zig comment and keyword" {
    var styles = std.ArrayList(TokenStyle).empty;
    defer styles.deinit(std.testing.allocator);

    try highlightLine(std.testing.allocator, .zig, "pub const x = 42; // hi", &styles);

    try std.testing.expectEqual(TokenStyle.keyword, styles.items[0]);
    try std.testing.expectEqual(TokenStyle.keyword, styles.items[4]);
    try std.testing.expectEqual(TokenStyle.number, styles.items[14]);
    try std.testing.expectEqual(TokenStyle.comment, styles.items[18]);
}
