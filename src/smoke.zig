//! End-to-end smoke check for the project.labelle writer + Compiler launcher
//! invocation. Creates a temp project via ProjectManager, then runs
//! Compiler.launcherGenerate against it and reports pass/fail.

const std = @import("std");
const project = @import("project.zig");
const compiler = @import("compiler.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Honor $TMPDIR (set on macOS by default, and respected on most Unix
    // shells); fall back to /tmp. Windows isn't a target for this smoke
    // runner but anyone can `set TMPDIR=...` before invoking if needed.
    const tmp_base = std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const dir_name = try std.fmt.allocPrint(allocator, "labelle_gui_smoke_{x}", .{prng.random().int(u64)});
    defer allocator.free(dir_name);
    const tmp = try std.fs.path.join(allocator, &.{
        std.mem.trimRight(u8, tmp_base, "/\\"),
        dir_name,
    });
    defer allocator.free(tmp);
    try std.fs.cwd().makePath(tmp);
    defer std.fs.cwd().deleteTree(tmp) catch {};

    var pm = project.ProjectManager.init(allocator);
    defer pm.deinit();
    try pm.newProject("smoke_via_gui");
    try pm.saveProject(tmp);

    std.log.info("wrote project at {s}", .{tmp});

    var comp = compiler.Compiler.init(allocator);
    defer comp.deinit();

    var result = comp.launcherGenerate(pm.current_project.?) catch |err| {
        std.log.err("launcherGenerate raised: {s}", .{@errorName(err)});
        if (err == error.LauncherNotFound) {
            std.log.err("  `labelle` not on PATH. Install via https://labelle.games or add ~/.labelle/bin to PATH.", .{});
        }
        std.process.exit(1);
    };
    defer result.deinit(allocator);

    if (result.errors.len > 0) std.log.info("stderr:\n{s}", .{result.errors});
    if (result.output.len > 0) std.log.info("stdout:\n{s}", .{result.output});

    if (!result.success) {
        std.log.err("launcher exited with non-zero status", .{});
        std.process.exit(1);
    }

    // Verify the .labelle/<target>/ tree exists.
    const expected = try std.fs.path.join(allocator, &.{ tmp, ".labelle", "raylib_desktop" });
    defer allocator.free(expected);
    var dir = std.fs.cwd().openDir(expected, .{}) catch |err| {
        std.log.err("expected target dir not found: {s} ({s})", .{ expected, @errorName(err) });
        std.process.exit(1);
    };
    dir.close();

    std.log.info("generate OK — verifying full build...", .{});

    // Now exercise the spawn-and-poll path that main.zig uses.
    try comp.build(pm.current_project.?);
    var build_result = while (true) {
        if (comp.pollBuild()) |r| break r;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    };
    defer build_result.deinit(allocator);

    if (build_result.errors.len > 0) std.log.info("build stderr:\n{s}", .{build_result.errors});
    if (build_result.output.len > 0) std.log.info("build stdout:\n{s}", .{build_result.output});

    if (!build_result.success) {
        std.log.err("`labelle build` failed", .{});
        std.process.exit(1);
    }

    std.log.info("SMOKE OK — generate + build via launcher succeeded", .{});
}
