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

    // Stub codec .zig for codecs excluded by -Dcodecs.
    const stub_wf = b.addWriteFiles();
    const sbcs_stub_content =
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
    const dbcs_stub_content =
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
    ;

    // Selected codecs produce a tracked file from convert; excluded get stubs
    // (each needs a unique file — Zig disallows two modules sharing a source).

    const codec_zigs = b.allocator.alloc(std.Build.LazyPath, codecs.len) catch @panic("OOM");

    for (codecs, codec_zigs) |codec, *codec_zig| {
        if (!cvt.codecSelected(codec, codecs_opt)) {
            const stub = if (codec.max_seq == 2) dbcs_stub_content else sbcs_stub_content;
            codec_zig.* = stub_wf.add(
                b.fmt("{s}_stub.zig", .{codec.name}),
                stub,
            );
        } else {
            const name = b.fmt("{s}_codec.zig", .{codec.name});
            convert_run.addArg(codec.name);
            codec_zig.* = convert_run.addOutputFileArg(name);
        }
    }

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addCodecImports(b, root_mod, codecs, codec_zigs);

    const exe = b.addExecutable(.{ .name = "vx", .root_module = root_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the editor").dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────────────────────

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addCodecImports(b, test_mod, codecs, codec_zigs);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    // ── Benchmark ─────────────────────────────────────────────────────────────

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench_encoding.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    addCodecImports(b, bench_mod, codecs, codec_zigs);

    const bench_exe = b.addExecutable(.{ .name = "bench_encoding", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench_exe);
    b.step("bench", "Run encoding throughput benchmark").dependOn(&run_bench.step);
}
