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

    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/labelle_gui_smoke_{x}", .{prng.random().int(u64)});
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
