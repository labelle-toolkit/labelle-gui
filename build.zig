const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    const zopengl = b.dependency("zopengl", .{});

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
    });

    const nfd = b.dependency("nfd", .{
        .target = target,
        .optimize = optimize,
    });

    const zspec = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "labelle-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    exe.root_module.addImport("zopengl", zopengl.module("root"));

    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    exe.root_module.addImport("nfd", nfd.module("nfd"));

    // Windows-specific: embed DPI awareness manifest
    if (target.result.os.tag == .windows) {
        exe.win32_manifest = b.path("assets/labelle-gui.manifest");
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);

    // Tests with zspec
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zspec", .module = zspec.module("zspec") },
            },
        }),
        .test_runner = .{ .path = zspec.path("src/runner.zig"), .mode = .simple },
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);

    // UI test runner ------------------------------------------------------
    //
    // A separate exe linking a second zgui instance built with the bundled
    // Dear ImGui Test Engine (`with_te = true`). It opens a hidden GLFW
    // window, drives the imgui frame loop, and runs registered TE tests to
    // completion. Not part of the default install — only `zig build gui-test`
    // builds and runs it, so the production exe stays free of TE overhead.
    const zgui_te = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
        .with_te = true,
    });

    const gui_tests_exe = b.addExecutable(.{
        .name = "gui-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gui_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    gui_tests_exe.root_module.addImport("zglfw", zglfw.module("root"));
    gui_tests_exe.linkLibrary(zglfw.artifact("glfw"));
    gui_tests_exe.root_module.addImport("zopengl", zopengl.module("root"));
    gui_tests_exe.root_module.addImport("zgui", zgui_te.module("root"));
    gui_tests_exe.linkLibrary(zgui_te.artifact("imgui"));

    const run_gui_tests = b.addRunArtifact(gui_tests_exe);
    const gui_test_step = b.step("gui-test", "Run the UI test runner");
    gui_test_step.dependOn(&run_gui_tests.step);

    // End-to-end smoke check ----------------------------------------------
    //
    // Drives the gui's project writer + Compiler.launcherGenerate against
    // the real `labelle` launcher to confirm the chain works on this
    // machine. Not part of `zig build test` because it requires `labelle`
    // on PATH and a populated package cache (or at least network).
    const smoke_exe = b.addExecutable(.{
        .name = "gui-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_smoke = b.addRunArtifact(smoke_exe);
    const smoke_step = b.step("smoke", "End-to-end smoke check against `labelle` launcher");
    smoke_step.dependOn(&run_smoke.step);
}
