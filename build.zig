const std = @import("std");
const cvt = @import("tools/convert.zig");

fn addCodecImports(
    b: *std.Build,
    mod: *std.Build.Module,
    codecs: []const cvt.Codec,
    codec_zigs: []const std.Build.LazyPath,
) void {
    for (codecs, codec_zigs) |codec, codec_zig| {
        mod.addAnonymousImport(
            b.fmt("{s}_codec", .{codec.name}),
            .{ .root_source_file = codec_zig },
        );
    }
}

fn linkNotcursesSystemLibs(mod: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("ntdll", .{});
        mod.linkSystemLibrary("user32", .{});
    } else if (target.result.os.tag == .macos) {
        mod.linkSystemLibrary("ncurses", .{});
        mod.linkSystemLibrary("unistring", .{});
        mod.linkSystemLibrary("z", .{});
    } else {
        mod.linkSystemLibrary("tinfo", .{});
        mod.linkSystemLibrary("unistring", .{});
        mod.linkSystemLibrary("z", .{});
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const codecs = cvt.loadCodecs(b.allocator);

    const fetch_tables = b.option(
        bool,
        "fetch",
        "Download codec mapping tables from unicode.org (default: true; use -Dfetch=false for offline builds)",
    ) orelse true;

    const codecs_opt = b.option(
        []const u8,
        "codecs",
        "Codec preset: 'all' (default), 'common', or comma-separated names e.g. 'gbk,cp1252'",
    ) orelse "all";

    // ── Codec conversion tool ─────────────────────────────────────────────────────
    const convert_exe = b.addExecutable(.{
        .name = "convert",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/convert.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        }),
    });

    const convert_run = b.addRunArtifact(convert_exe);
    convert_run.setCwd(b.path("."));
    convert_run.addArgs(&.{ "--codecs", codecs_opt });
    if (!fetch_tables) convert_run.addArg("--no-fetch");
    convert_run.addArg("--");

    const gen_codecs_step = b.step("gen-codecs", "Regenerate encoding tables from Unicode source files");
    gen_codecs_step.dependOn(&convert_run.step);

    // ── Tree-sitter grammar configuration ───────────────────────────────────────────

    // tree-sitter dependency for the main executable
    const ts_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const ts_module = ts_dep.module("tree_sitter");

    // Separate tree-sitter dependency for the grammar CLI tool (host, ReleaseFast)
    const ts_dep_host = b.dependency("tree_sitter", .{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const ts_module_host = ts_dep_host.module("tree_sitter");

    // ── Languages config module (injected into vx and tool executables) ──────────
    const languages_mod = b.createModule(.{
        .root_source_file = b.path("src/languages/config.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    // Inject languages.zon so @import("default_config_languages") inside config.zig resolves.
    languages_mod.addAnonymousImport("default_config_languages", .{ .root_source_file = b.path("languages.zon") });

    // ── Grammar management CLI step ───────────────────────────────────────────────
    const tree_sitters_exe = b.addExecutable(.{
        .name = "tree-sitters",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/languages/grammar.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    tree_sitters_exe.root_module.addImport("tree-sitter", ts_module_host);
    tree_sitters_exe.root_module.addImport("languages", languages_mod);

    const tree_sitters_run = b.addRunArtifact(tree_sitters_exe);
    tree_sitters_run.setCwd(b.path("."));
    if (b.args) |args| tree_sitters_run.addArgs(args);

    const grammar_step = b.step("grammar", "Manage tree-sitter grammars (fetch/update/build/rm/list/test)");
    grammar_step.dependOn(&tree_sitters_run.step);

    // ── Auto fetch+build all grammars step ────────────────────────────────────────
    const grammars_fetch_run = b.addRunArtifact(tree_sitters_exe);
    grammars_fetch_run.setCwd(b.path("."));
    grammars_fetch_run.addArg("fetch");

    const grammars_build_run = b.addRunArtifact(tree_sitters_exe);
    grammars_build_run.setCwd(b.path("."));
    grammars_build_run.addArg("build");
    grammars_build_run.step.dependOn(&grammars_fetch_run.step);

    const grammars_step = b.step("grammars", "Fetch and build all tree-sitter grammar .so files");
    grammars_step.dependOn(&grammars_build_run.step);

    // ── Language management CLI step ───────────────────────────────────────────────
    const languages_exe = b.addExecutable(.{
        .name = "languages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/languages/language.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    languages_exe.root_module.addImport("languages", languages_mod);

    const languages_run = b.addRunArtifact(languages_exe);
    languages_run.setCwd(b.path("."));
    if (b.args) |args| languages_run.addArgs(args);

    const language_step = b.step("language", "Manage language detection mappings (add/remove/list/update)");
    language_step.dependOn(&languages_run.step);

    // ── Codec .zig file generation ─────────────────────────────────────────────────

    const codec_zigs = b.allocator.alloc(std.Build.LazyPath, codecs.len) catch @panic("OOM");

    for (codecs, codec_zigs) |codec, *codec_zig| {
        if (!cvt.codecSelected(codec, codecs_opt)) {
            // Stub generation for excluded codecs
            const stub_content = if (codec.max_seq == 2)
                \\// Stub codec — excluded from this build preset (-Dcodecs=...)
                \\// Non-ASCII bytes decode to U+FFFD; encoding emits '?'.
                \\const std = @import("std");
                \\pub const is_stub = true;
                \\pub const fwd_table: [65536]u16 = [_]u16{0xFFFF} ** 65536;
                \\pub const rev_table: [65536]u16 = [_]u16{0xFFFF} ** 65536;
                \\pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
                \\    var out = try allocator.alloc(u8, bytes.len * 3);
                \\    errdefer allocator.free(out);
                \\    var j: usize = 0;
                \\    for (bytes) |b| {
                \\        if (b < 0x80) { out[j] = b; j += 1; }
                \\        else { out[j] = 0xEF; out[j+1] = 0xBF; out[j+2] = 0xBD; j += 3; }
                \\    }
                \\    return allocator.realloc(out, j);
                \\}
                \\pub fn encode(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
                \\    var out = try allocator.alloc(u8, utf8_bytes.len);
                \\    errdefer allocator.free(out);
                \\    var j: usize = 0;
                \\    var i: usize = 0;
                \\    while (i < utf8_bytes.len) {
                \\        const b = utf8_bytes[i];
                \\        if (b < 0x80) { out[j] = b; j += 1; i += 1; }
                \\        else {
                \\            out[j] = '?'; j += 1;
                \\            const seq_len: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                \\            i += if (i + seq_len <= utf8_bytes.len) seq_len else 1;
                \\        }
                \\    }
                \\    return allocator.realloc(out, j);
                \\}
                \\
            else
                \\// Stub codec — excluded from this build preset (-Dcodecs=...)
                \\// Non-ASCII bytes decode to U+FFFD; encoding emits '?'.
                \\const std = @import("std");
                \\pub const fwd: []const u8 = &.{};
                \\pub const rev: []const u8 = &.{};
                \\pub const fwd_table: [128]u32 = [_]u32{0} ** 128;
                \\pub const rev_base: u16 = 0x0080;
                \\pub const rev_table: [1]u8 = .{0xFF};
                \\pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
                \\    var out = try allocator.alloc(u8, bytes.len * 3);
                \\    errdefer allocator.free(out);
                \\    var j: usize = 0;
                \\    for (bytes) |b| {
                \\        if (b < 0x80) { out[j] = b; j += 1; }
                \\        else { out[j] = 0xEF; out[j+1] = 0xBF; out[j+2] = 0xBD; j += 3; }
                \\    }
                \\    return allocator.realloc(out, j);
                \\}
                \\pub fn encode(allocator: std.mem.Allocator, utf8_bytes: []const u8) ![]u8 {
                \\    var out = try allocator.alloc(u8, utf8_bytes.len);
                \\    errdefer allocator.free(out);
                \\    var j: usize = 0;
                \\    var i: usize = 0;
                \\    while (i < utf8_bytes.len) {
                \\        const b = utf8_bytes[i];
                \\        if (b < 0x80) { out[j] = b; j += 1; i += 1; }
                \\        else {
                \\            out[j] = '?'; j += 1;
                \\            const seq_len: usize = if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
                \\            i += if (i + seq_len <= utf8_bytes.len) seq_len else 1;
                \\        }
                \\    }
                \\    return allocator.realloc(out, j);
                \\}
                \\
            ;

            const stub_wf = b.addWriteFiles();
            codec_zig.* = stub_wf.add(
                b.fmt("{s}_stub.zig", .{codec.name}),
                stub_content,
            );
        } else {
            const name = b.fmt("{s}_codec.zig", .{codec.name});
            convert_run.addArg(codec.name);
            codec_zig.* = convert_run.addOutputFileArg(name);
        }
    }

    // ── PCRE2 dependency (cross-platform, no system library needed) ──────────────

    const pcre2_dep = b.dependency("pcre2", .{ .target = target, .optimize = optimize });
    const pcre2_lib = pcre2_dep.artifact("pcre2-8");

    const pcre2_mod = b.createModule(.{
        .root_source_file = b.path("src/pcre2/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pcre2_mod.linkLibrary(pcre2_lib);

    // ── notcurses (compiled from source, no system install needed) ────────────────

    const nc_dep = b.dependency("notcurses", .{});

    // Hand-craft the two CMake-generated headers (no multimedia, no GPM, no deflate).
    const nc_gen = b.addWriteFiles();
    _ = nc_gen.add("builddef.h",
        \\// Generated for zig build (no multimedia, no GPM, no deflate)
        \\#pragma once
        \\#define NOTCURSES_SHARE "/usr/share/notcurses"
    );
    _ = nc_gen.add("version.h",
        \\// Generated for zig build
        \\#pragma once
        \\#ifndef NOTCURSES_VERSION_HEADER
        \\#define NOTCURSES_VERSION_HEADER
        \\#define NOTCURSES_VERNUM_MAJOR 3
        \\#define NOTCURSES_VERNUM_MINOR 0
        \\#define NOTCURSES_VERNUM_PATCH 17
        \\#define NOTCURSES_VERNUM_TWEAK 0
        \\#define NOTCURSES_VERSION_MAJOR "3"
        \\#define NOTCURSES_VERSION_MINOR "0"
        \\#define NOTCURSES_VERSION_PATCH "17"
        \\#define NOTCURSES_VERSION_TWEAK "0"
        \\#define NOTCURSES_VERSION_COMPARABLE(major, minor, patch) \
        \\  (((major) << 16u) + ((minor) << 8u) + (patch))
        \\#define NOTCURSES_VERNUM_ORDERED NOTCURSES_VERSION_COMPARABLE( \
        \\  NOTCURSES_VERNUM_MAJOR, NOTCURSES_VERNUM_MINOR, NOTCURSES_VERNUM_PATCH)
        \\#endif
    );

    const nc_cflags = &[_][]const u8{
        "-std=gnu11",           // sixel.c uses typeof() GNU extension
        "-D_GNU_SOURCE",        "-D_DEFAULT_SOURCE",
        "-Wno-unused-function", "-Wno-deprecated-declarations",
    };

    const nc_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    nc_mod.addCSourceFiles(.{
        .root = nc_dep.path("src/lib"),
        .files = &.{
            "automaton.c", "banner.c",   "blit.c",     "debug.c",
            "direct.c",    "egcpool.c",  "fade.c",     "fd.c",
            "fill.c",      "gpm.c",      "in.c",       "kitty.c",
            "layout.c",    "linux.c",    "menu.c",     "metric.c",
            "mice.c",      "notcurses.c","plot.c",     "progbar.c",
            "reader.c",    "reel.c",     "render.c",   "selector.c",
            "sixel.c",     "sprite.c",   "stats.c",    "tabbed.c",
            "termdesc.c",  "tree.c",     "unixsig.c",  "util.c",
            "visual.c",    "windows.c",
        },
        .flags = nc_cflags,
    });
    nc_mod.addCSourceFiles(.{
        .root = nc_dep.path("src/compat"),
        .files = &.{"compat.c"},
        .flags = nc_cflags,
    });
    nc_mod.addIncludePath(nc_dep.path("include"));
    nc_mod.addIncludePath(nc_dep.path("src"));
    nc_mod.addIncludePath(nc_dep.path("src/lib"));
    nc_mod.addIncludePath(nc_gen.getDirectory());
    // Platform-specific compile settings for notcurses sources.
    if (target.result.os.tag == .windows) {
        nc_mod.addCMacro("NOMINMAX", "1");
        nc_mod.addCMacro("WIN32_LEAN_AND_MEAN", "1");
    }

    const notcurses_lib = b.addLibrary(.{
        .name = "notcurses",
        .linkage = .static,
        .root_module = nc_mod,
    });

    // Translate notcurses C headers to Zig (Zig 0.16 @cImport replacement).
    const nc_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/vx/notcurses.h"),
        .target = target,
        .optimize = optimize,
    });
    nc_translate.addIncludePath(nc_dep.path("include"));
    nc_translate.addIncludePath(nc_gen.getDirectory());
    nc_translate.defineCMacro("_GNU_SOURCE", null);
    const nc_c_mod = nc_translate.createModule();

    // ── Main executable ────────────────────────────────────────────────────────────

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addCodecImports(b, root_mod, codecs, codec_zigs);
    root_mod.addImport("tree-sitter", ts_module);
    root_mod.addImport("languages", languages_mod);
    root_mod.addImport("pcre2", pcre2_mod);
    root_mod.linkLibrary(notcurses_lib);
    linkNotcursesSystemLibs(root_mod, target);
    root_mod.addIncludePath(nc_dep.path("include"));
    root_mod.addImport("notcurses_c", nc_c_mod);

    const exe = b.addExecutable(.{ .name = "vx", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the editor").dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────────────

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addCodecImports(b, test_mod, codecs, codec_zigs);
    test_mod.addImport("tree-sitter", ts_module);
    test_mod.addImport("languages", languages_mod);
    test_mod.addImport("pcre2", pcre2_mod);
    test_mod.linkLibrary(notcurses_lib);
    linkNotcursesSystemLibs(test_mod, target);
    test_mod.addIncludePath(nc_dep.path("include"));
    test_mod.addImport("notcurses_c", nc_c_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    // ── Highlight benchmark ───────────────────────────────────────────────────────────

    // Bench needs all modules at ReleaseFast to avoid ubsan symbol mismatches.
    const bench_ts_dep = b.dependency("tree_sitter", .{ .target = target, .optimize = .ReleaseFast });
    const bench_ts_mod = bench_ts_dep.module("tree_sitter");

    const bench_pcre2_dep = b.dependency("pcre2", .{ .target = target, .optimize = .ReleaseFast });
    const bench_pcre2_lib = bench_pcre2_dep.artifact("pcre2-8");
    const bench_pcre2_mod = b.createModule(.{
        .root_source_file = b.path("src/pcre2/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_pcre2_mod.linkLibrary(bench_pcre2_lib);

    const bench_languages_mod = b.createModule(.{
        .root_source_file = b.path("src/languages/config.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_languages_mod.addAnonymousImport("default_config_languages", .{
        .root_source_file = b.path("languages.zon"),
    });

    const treesitter_mod = b.createModule(.{
        .root_source_file = b.path("src/vx/treesitter.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    treesitter_mod.addImport("tree-sitter", bench_ts_mod);
    treesitter_mod.addImport("pcre2", bench_pcre2_mod);
    treesitter_mod.addImport("languages", bench_languages_mod);

    const bench_hl_mod = b.createModule(.{
        .root_source_file = b.path("bench/highlight_bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_hl_mod.addImport("treesitter", treesitter_mod);

    const bench_hl_exe = b.addExecutable(.{ .name = "bench_highlight", .root_module = bench_hl_mod });
    const run_bench_hl = b.addRunArtifact(bench_hl_exe);
    run_bench_hl.setCwd(b.path("."));
    b.step("bench-highlight", "Run parse+highlight benchmark (requires runtime/grammars/)").dependOn(&run_bench_hl.step);

    // ── Render benchmark ──────────────────────────────────────────────────────────

    const bench_render_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_render_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    bench_render_mod.addImport("tree-sitter", bench_ts_mod);
    bench_render_mod.addImport("pcre2", bench_pcre2_mod);
    bench_render_mod.addImport("languages", bench_languages_mod);
    bench_render_mod.linkLibrary(notcurses_lib);
    linkNotcursesSystemLibs(bench_render_mod, target);
    bench_render_mod.addIncludePath(nc_dep.path("include"));
    bench_render_mod.addImport("notcurses_c", nc_c_mod);
    addCodecImports(b, bench_render_mod, codecs, codec_zigs);

    const bench_render_exe = b.addExecutable(.{ .name = "bench_render", .root_module = bench_render_mod });
    const run_bench_render = b.addRunArtifact(bench_render_exe);
    run_bench_render.setCwd(b.path("."));
    b.step("bench-render", "Run render latency benchmark (outputs mean_us/min_us)").dependOn(&run_bench_render.step);
}
