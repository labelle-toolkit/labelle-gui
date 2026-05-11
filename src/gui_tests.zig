//! UI test runner — Phase 1 hello-world for Dear ImGui Test Engine integration.
//!
//! Spins up a hidden GLFW window, initializes zgui with the bundled
//! Test Engine (`with_te = true`), registers a single trivial check,
//! drives the frame loop until the test queue drains, and exits with
//! the engine's pass/fail tally.
//!
//! Phase 2 will refactor `main.zig` so the real App can be driven from
//! here. For now this only proves the build wiring works end-to-end.

const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");

const gl_major = 4;
const gl_minor = 1;

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.context_version_major, gl_major);
    zglfw.windowHint(.context_version_minor, gl_minor);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.doublebuffer, true);
    // Hidden window — we need a real GL context but no on-screen presentation.
    zglfw.windowHint(.visible, false);

    const window = try zglfw.createWindow(640, 480, "labelle-gui tests", null, null);
    defer zglfw.destroyWindow(window);

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(0);

    try zopengl.loadCoreProfile(zglfw.getProcAddress, gl_major, gl_minor);
    const gl = zopengl.bindings;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // zgui.init() also brings up the Test Engine when zgui was built with
    // `with_te = true` (gui.zig: init() → te.init()). Calling te.init() a
    // second time here double-registers the "TestEnginePerfTool" settings
    // handler and trips an imgui assertion. So we just grab the engine
    // zgui already created.
    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    const engine = zgui.te.getTestEngine().?;
    engine.setRunSpeed(.fast);

    _ = engine.registerTest("phase1", "hello_world", @src(), struct {
        // No `gui` callback — this test doesn't need to render any widgets.
        // The `run` callback drives the assertions.
        fn run(ctx: *zgui.te.TestContext) !void {
            _ = ctx;
            _ = zgui.te.check(@src(), .{}, true, "trivially true");
        }
    });

    engine.queueTests(.tests, "all", .{});

    // Frame loop — drive imgui + the test engine until the queue drains.
    // 600 frames is ~10s at 60Hz; ample for any sensible Phase-1 test
    // and a guardrail against hangs.
    var frame: usize = 0;
    while (frame < 600) : (frame += 1) {
        zglfw.pollEvents();

        const fb = window.getFramebufferSize();
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.newFrame(@intCast(fb[0]), @intCast(fb[1]));
        zgui.backend.draw();

        zglfw.swapBuffers(window);
        engine.postSwap();

        if (engine.isTestQueueEmpty()) break;
    }

    var tested: c_int = 0;
    var succeeded: c_int = 0;
    engine.getResult(&tested, &succeeded);
    engine.printResultSummary();

    if (tested == 0) {
        std.log.err("no tests ran (frame budget exhausted)", .{});
        std.process.exit(2);
    }
    if (tested != succeeded) {
        std.log.err("{d}/{d} tests failed", .{ tested - succeeded, tested });
        std.process.exit(1);
    }
    std.log.info("all {d} tests passed", .{tested});
}
