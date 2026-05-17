//! PCRE2 8-bit Zig wrapper.
//!
//! Usage:
//!   const re = try pcre2.Regex.compile(pattern);
//!   defer re.deinit();
//!   if (re.match(text)) { ... }

const std = @import("std");

// ── raw extern declarations (8-bit API, symbol names have _8 suffix) ─────────

const Code = opaque {};
const MatchData = opaque {};

extern fn pcre2_compile_8(
    pattern: [*]const u8,
    length: usize,
    options: u32,
    errorcode: *c_int,
    erroroffset: *usize,
    ccontext: ?*anyopaque,
) ?*Code;

extern fn pcre2_match_data_create_from_pattern_8(
    code: *const Code,
    gcontext: ?*anyopaque,
) ?*MatchData;

extern fn pcre2_match_8(
    code: *const Code,
    subject: [*]const u8,
    length: usize,
    startoffset: usize,
    options: u32,
    match_data: *MatchData,
    mcontext: ?*anyopaque,
) c_int;

extern fn pcre2_match_data_free_8(match_data: *MatchData) void;
extern fn pcre2_code_free_8(code: *Code) void;

// ── public API ───────────────────────────────────────────────────────────────

pub const Error = error{CompileError};

/// A compiled PCRE2 regular expression. Call `deinit` when done.
pub const Regex = struct {
    code: *Code,

    /// Compile `pattern`. Returns `error.CompileError` on invalid syntax.
    pub fn compile(pattern: []const u8) Error!Regex {
        var errcode: c_int = 0;
        var erroffset: usize = 0;
        const code = pcre2_compile_8(
            pattern.ptr,
            pattern.len,
            0,
            &errcode,
            &erroffset,
            null,
        ) orelse return error.CompileError;
        return .{ .code = code };
    }

    /// Returns true if `text` contains a match for this pattern.
    pub fn match(self: Regex, text: []const u8) bool {
        const md = pcre2_match_data_create_from_pattern_8(self.code, null) orelse return false;
        defer pcre2_match_data_free_8(md);
        return pcre2_match_8(self.code, text.ptr, text.len, 0, 0, md, null) >= 0;
    }

    pub fn deinit(self: Regex) void {
        pcre2_code_free_8(self.code);
    }
};

// ── tests ────────────────────────────────────────────────────────────────────

test "compile and match" {
    const re = try Regex.compile("hello");
    defer re.deinit();
    try std.testing.expect(re.match("say hello world"));
    try std.testing.expect(!re.match("goodbye"));
}

test "compile error" {
    try std.testing.expectError(error.CompileError, Regex.compile("[invalid"));
}

test "case sensitive by default" {
    const re = try Regex.compile("Hello");
    defer re.deinit();
    try std.testing.expect(!re.match("hello"));
}
