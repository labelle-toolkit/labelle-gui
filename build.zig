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
        // Pulls in thedmd/imgui-node-editor (vendored at
        // libs/node_editor) and compiles it into the same `imgui`
        // artifact zgui already produces. Exposed via
        // `zgui.node_editor.*` (see libs/zgui/src/node_editor.zig).
        // Linked against the same ImGui instance so the editor's
        // canvas draws into the gui's existing context — no second
        // ImGuiContext needed (issue #45, Flows spike).
        .with_node_editor = true,
    });

    const nfd = b.dependency("nfd", .{
        .target = target,
        .optimize = optimize,
    });

    const zstbi = b.dependency("zstbi", .{
        .target = target,
        .optimize = optimize,
    });

    const zspec = b.dependency("zspec", .{
        .target = target,
        .optimize = optimize,
    });

    // Pure-Zig `.flow.zon` parser + codegen, promoted into an in-tree
    // sub-package so labelle-assembler can depend on it without
    // pulling in the gui's imgui/zgui stack (issue #94).
    const flow_codegen = b.dependency("flow_codegen", .{
        .target = target,
        .optimize = optimize,
    });
    const flow_codegen_module = flow_codegen.module("flow_codegen");

    // labelle-engine — for the PIE viewport (#107). We pull the
    // engine in solely for `preview_mode.preview_shm.Consumer`
    // (cross-process pixel ring reader) and the protocol types.
    // The engine's own deps (labelle-core etc.) come along for the
    // ride but the editor only links the preview surface.
    const engine = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    });
    const engine_module = engine.module("engine");

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
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));

    exe.root_module.addImport("zopengl", zopengl.module("root"));

    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.root_module.linkLibrary(zgui.artifact("imgui"));

    exe.root_module.addImport("nfd", nfd.module("nfd"));

    exe.root_module.addImport("zstbi", zstbi.module("root"));

    exe.root_module.addImport("flow_codegen", flow_codegen_module);

    exe.root_module.addImport("engine", engine_module);

    // macOS-only: link the frameworks `src/iosurface.zig` calls into
    // (`IOSurfaceLookup`, `CFRelease`, `CGLTexImageIOSurface2D`).
    // The bindings are no-ops on other platforms (every public API
    // returns `error.PlatformUnsupported`), so the links stay
    // mac-gated. See labelle-gui#108.
    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("IOSurface", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("OpenGL", .{});
    }

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
                // atlas.zig pulls in zopengl + zstbi at module scope
                // (for the GL upload path); the test target only
                // exercises the pure-parse function but still needs
                // both modules to resolve at compile time.
                .{ .name = "zopengl", .module = zopengl.module("root") },
                .{ .name = "zstbi", .module = zstbi.module("root") },
                .{ .name = "flow_codegen", .module = flow_codegen_module },
                .{ .name = "engine", .module = engine_module },
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
        // Mirror the production `zgui` config so `App` compiles
        // against the same module shape — the Flow module references
        // `zgui.node_editor.*` and the test runner imports App.
        .with_node_editor = true,
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
    gui_tests_exe.root_module.linkLibrary(zglfw.artifact("glfw"));
    gui_tests_exe.root_module.addImport("zopengl", zopengl.module("root"));
    gui_tests_exe.root_module.addImport("zgui", zgui_te.module("root"));
    gui_tests_exe.root_module.linkLibrary(zgui_te.artifact("imgui"));
    gui_tests_exe.root_module.addImport("zstbi", zstbi.module("root"));
    gui_tests_exe.root_module.addImport("flow_codegen", flow_codegen_module);
    // App.renderFrame transitively imports nfd via the file-dialog
    // code path; without this addImport the test binary fails to
    // compile as soon as the previously-dead `Callbacks.gui`/`run`
    // bodies are analyzed (this addition originally landed in #106
    // and was inadvertently dropped during #115's review-fix
    // cherry-pick rebase).
    gui_tests_exe.root_module.addImport("nfd", nfd.module("nfd"));
    gui_tests_exe.root_module.addImport("engine", engine_module);

    // macOS-only frameworks — same set as the production `exe` above.
    // The iosurface dispatch test (PIE viewport) drives the real
    // `iosurface.Consumer` + `bindSurface`, which call into
    // `CGLTexImageIOSurface2D` / `CGLGetCurrentContext`. Without the
    // OpenGL framework, the gui-tests binary fails to link on macOS
    // even though only one TE test exercises the path. See
    // labelle-gui#108 for the upstream rationale.
    if (target.result.os.tag == .macos) {
        gui_tests_exe.root_module.linkFramework("IOSurface", .{});
        gui_tests_exe.root_module.linkFramework("CoreFoundation", .{});
        gui_tests_exe.root_module.linkFramework("OpenGL", .{});
    }

    const run_gui_tests = b.addRunArtifact(gui_tests_exe);
    const gui_test_step = b.step("gui-test", "Run the UI test runner");
    gui_test_step.dependOn(&run_gui_tests.step);

    // Build-only step for CI: produces `zig-out/bin/gui-tests` without
    // running it, so the artifact can be uploaded once by the `build`
    // job and reused by the `ui-tests` job (which then only needs Xvfb
    // and runtime libs, no Zig toolchain). Local dev still uses
    // `zig build gui-test` to build + run in one shot.
    const install_gui_tests = b.addInstallArtifact(gui_tests_exe, .{});
    const gui_test_build_step = b.step("gui-test-build", "Build the UI test runner binary (no run)");
    gui_test_build_step.dependOn(&install_gui_tests.step);

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
