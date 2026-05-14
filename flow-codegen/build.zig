const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zspec_dep = b.dependency("zspec", .{ .target = target, .optimize = optimize });

    const flow_codegen_module = b.addModule("flow_codegen", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── Tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run flow_codegen tests");

    // Lightweight smoke compilation of the public surface. Picks up
    // any `test {}` blocks added directly to `src/` files in the
    // future; today these files have no in-place tests (the real
    // suite lives in `test/root_test.zig`).
    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(src_tests).step);

    // BDD-style tests, mirroring labelle-gfx/spatial_grid.
    const root_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/root_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flow_codegen", .module = flow_codegen_module },
                .{ .name = "zspec", .module = zspec_dep.module("zspec") },
            },
        }),
        .test_runner = .{ .path = zspec_dep.path("src/runner.zig"), .mode = .simple },
    });
    test_step.dependOn(&b.addRunArtifact(root_tests).step);
}
