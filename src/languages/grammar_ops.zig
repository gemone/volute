/// src/languages/grammar_ops.zig — shared grammar management operations.
///
/// Used by both `src/main.zig` (vx --grammar) and `tools/languages/grammar.zig`
/// (zig build grammar --).
///
/// Key operations:
///   grammarLibFilename  — platform-specific .so/.dll filename for a grammar
///   cloneAndHash        — git clone a grammar source tree and pin to commit
///   buildGrammarSo      — compile parser.c -> shared library
///   removeGrammarFiles  — delete runtime .so and source directory
///   findGrammarsDir     — locate the runtime grammars directory

const std = @import("std");
const builtin = @import("builtin");
const lcfg = @import("config.zig");

/// Result of a clone+hash operation.
pub const CloneResult = struct {
    /// Pinned URL: original URL + "#<commit>" (caller owns).
    pinned_url: []u8,
    /// Hex commit hash (caller owns).
    hash: []u8,
};

/// Return the platform-specific shared-library filename for `name`.
/// E.g. on Linux: "libtree-sitter-zig.so", on Windows: "tree-sitter-zig.dll",
/// on macOS: "libtree-sitter-zig.dylib".
/// Caller must free the returned slice.
pub fn grammarLibFilename(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return switch (builtin.os.tag) {
        .windows => std.fmt.allocPrint(allocator, "tree-sitter-{s}.dll", .{name}),
        .macos, .ios => std.fmt.allocPrint(allocator, "libtree-sitter-{s}.dylib", .{name}),
        else => std.fmt.allocPrint(allocator, "libtree-sitter-{s}.so", .{name}),
    };
}

/// Clone `git_url` into `src_dir` (creating it if needed), resolve HEAD commit,
/// and return a `CloneResult` with a pinned URL and commit hash.
/// `url_prefix` is prepended to the pinned_url (e.g. "git+").
/// Caller must free `result.pinned_url` and `result.hash`.
pub fn cloneAndHash(
    io: std.Io,
    allocator: std.mem.Allocator,
    git_url: []const u8,
    src_dir: []const u8,
    url_prefix: []const u8,
) !CloneResult {
    // Ensure the parent directory exists.
    {
        const mkdir = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "mkdir", "-p", src_dir },
        });
        defer {
            allocator.free(mkdir.stdout);
            allocator.free(mkdir.stderr);
        }
        if (mkdir.term != .exited or mkdir.term.exited != 0) {
            std.debug.print("mkdir -p {s} failed: {s}\n", .{ src_dir, mkdir.stderr });
            return error.MkdirFailed;
        }
    }

    // Clone the repository (shallow).
    {
        const clone = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "git", "clone", "--depth", "1", git_url, src_dir },
        });
        defer {
            allocator.free(clone.stdout);
            allocator.free(clone.stderr);
        }
        if (clone.term != .exited or clone.term.exited != 0) {
            std.debug.print("git clone failed:\n{s}\n", .{clone.stderr});
            return error.CloneFailed;
        }
    }

    // Resolve HEAD to get the pinned commit.
    const rev = try std.process.run(allocator, io, .{
        .argv = &[_][]const u8{ "git", "rev-parse", "HEAD" },
        .cwd = .{ .path = src_dir },
    });
    defer {
        allocator.free(rev.stdout);
        allocator.free(rev.stderr);
    }
    if (rev.term != .exited or rev.term.exited != 0) {
        std.debug.print("git rev-parse failed:\n{s}\n", .{rev.stderr});
        return error.RevParseFailed;
    }
    const commit = std.mem.trim(u8, rev.stdout, &std.ascii.whitespace);
    const hash = try allocator.dupe(u8, commit);
    const pinned_url = try std.fmt.allocPrint(allocator, "{s}{s}#{s}", .{ url_prefix, git_url, commit });

    return CloneResult{ .pinned_url = pinned_url, .hash = hash };
}

/// Compile the grammar at `<runtime_dir>/src/<grammar.name>/src/parser.c` into
/// a shared library at `<runtime_dir>/libtree-sitter-<grammar.name>.<ext>`.
pub fn buildGrammarSo(
    io: std.Io,
    allocator: std.mem.Allocator,
    grammar: lcfg.GrammarDef,
    runtime_dir: []const u8,
) !void {
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ runtime_dir, grammar.name });
    defer allocator.free(src_dir);

    const parser_c = try std.fmt.allocPrint(allocator, "{s}/src/parser.c", .{src_dir});
    defer allocator.free(parser_c);

    // Verify parser.c exists.
    {
        const f = std.Io.Dir.cwd().openFile(io, parser_c, .{}) catch {
            std.debug.print("  {s}: parser.c not found\n", .{grammar.name});
            return error.ParserNotFound;
        };
        f.close(io);
    }

    const lib_filename = try grammarLibFilename(allocator, grammar.name);
    defer allocator.free(lib_filename);

    const output_lib = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime_dir, lib_filename });
    defer allocator.free(output_lib);

    var cc_args = std.ArrayList([]const u8).empty;
    defer cc_args.deinit(allocator);
    try cc_args.appendSlice(allocator, &[_][]const u8{
        "zig", "cc",
        "-shared",
        "-fPIC",
        "-std=c11",
        "-I", try std.fmt.allocPrint(allocator, "{s}/src", .{src_dir}),
        "-o", output_lib,
        parser_c,
    });

    // Include scanner.c if present (optional external scanner).
    const scanner_c = try std.fmt.allocPrint(allocator, "{s}/src/scanner.c", .{src_dir});
    if (std.Io.Dir.cwd().openFile(io, scanner_c, .{})) |f| {
        f.close(io);
        try cc_args.append(allocator, scanner_c);
    } else |_| {}

    const result = try std.process.run(allocator, io, .{ .argv = cc_args.items });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("zig cc failed:\n{s}\n", .{result.stderr});
        return error.CompileFailed;
    }
}

/// Delete the runtime .so and the source directory for `name`.
/// Errors (e.g. file not found) are silently ignored.
pub fn removeGrammarFiles(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    runtime_dir: []const u8,
) void {
    const lib_filename = grammarLibFilename(allocator, name) catch return;
    defer allocator.free(lib_filename);
    const lib_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ runtime_dir, lib_filename }) catch return;
    defer allocator.free(lib_path);
    std.Io.Dir.cwd().deleteFile(io, lib_path) catch {};

    const src_path = std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ runtime_dir, name }) catch return;
    defer allocator.free(src_path);
    std.Io.Dir.cwd().deleteTree(io, src_path) catch {};
}

// ── Runtime directory resolution ──────────────────────────────────────────────

/// Locate the runtime grammars directory.
///
/// Resolution order:
///   1. `VOLUTE_RUNTIME_DIR` environment variable (if set).
///   2. Compile-time default "runtime/grammars" (relative to cwd).
///
/// Caller must free the returned slice.
pub fn findGrammarsDir(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    _ = io;

    // 1. Environment override.
    if (std.c.getenv("VOLUTE_RUNTIME_DIR")) |dir_c| {
        return allocator.dupe(u8, std.mem.span(dir_c));
    }

    // 2. Fallback: compile-time relative default.
    return allocator.dupe(u8, "runtime/grammars");
}
