//! UI test runner — drives the real `App` against the ImGui Test Engine.
//!
//! Boots a hidden GLFW window, constructs an `App`, registers TE tests
//! that drive menu actions and assert on App state, runs the frame loop
//! until the test queue drains. Exit code reflects pass/fail.

const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");

const App = @import("app.zig").App;

const gl_major = 4;
const gl_minor = 1;

/// Test callbacks run via a C ABI, so they reach the App through a
/// module-local pointer rather than a parameter. Set this once in `main`
/// before queueing tests, clear in the deferred teardown.
var g_app: ?*App = null;

/// Path to a temp project directory created for the project_settings
/// test. The test's `run` callback reads the file back from disk to
/// verify the Save button actually persisted, so the path needs to be
/// reachable from the C-ABI callback.
var g_settings_project_dir: ?[]const u8 = null;

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    zglfw.windowHint(.context_version_major, gl_major);
    zglfw.windowHint(.context_version_minor, gl_minor);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);
    zglfw.windowHint(.client_api, .opengl_api);
    zglfw.windowHint(.doublebuffer, true);
    zglfw.windowHint(.visible, false);

    const window = try zglfw.createWindow(1280, 720, "labelle-gui tests", null, null);
    defer zglfw.destroyWindow(window);

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(0);

    try zopengl.loadCoreProfile(zglfw.getProcAddress, gl_major, gl_minor);
    const gl = zopengl.bindings;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // zgui.init() already started the Test Engine because the test runner
    // builds zgui with `with_te = true`. Don't call te.init() again — it
    // double-registers settings handlers and trips an imgui assertion.
    const engine = zgui.te.getTestEngine().?;
    engine.setRunSpeed(.fast);

    const app = try App.init(allocator, window);
    defer app.deinit();
    g_app = app;
    defer g_app = null;

    _ = engine.registerTest("phase1", "hello_world", @src(), struct {
        fn run(_: *zgui.te.TestContext) !void {
            _ = zgui.te.check(@src(), .{}, true, "trivially true");
        }
    });

    // Project Settings test owns its own temp project on disk, written
    // via the gui's own ProjectManager so the test exercises the real
    // save path. Cleanup runs after engine drains.
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    var tmp_buf: [64]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "/tmp/labelle_gui_te_{x}", .{prng.random().int(u64)});
    try std.fs.cwd().makePath(tmp);
    defer std.fs.cwd().deleteTree(tmp) catch {};

    try app.project_manager.newProject("settings_te");
    try app.project_manager.saveProject(tmp);
    g_settings_project_dir = tmp;
    defer g_settings_project_dir = null;

    _ = engine.registerTest("phase3", "view_compiler_output_toggle", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame();
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // Sanity: panel starts closed.
            _ = zgui.te.check(@src(), .{}, !a.show_compiler_output, "panel starts closed");

            // Drive View > Compiler Output.
            ctx.menuAction(.click, "View/Compiler Output");

            // The toggle flips the same `bool` the panel reads, so the
            // assertion below sees the update without waiting on another
            // frame.
            _ = zgui.te.check(@src(), .{}, a.show_compiler_output, "View/Compiler Output opens panel");

            // Toggle off again to confirm the menu reflects current state.
            ctx.menuAction(.click, "View/Compiler Output");
            _ = zgui.te.check(@src(), .{}, !a.show_compiler_output, "View/Compiler Output closes panel");
        }
    });

    _ = engine.registerTest("phase3", "resources_add_and_save", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame();
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            ctx.menuAction(.click, "View/Resources");
            _ = zgui.te.check(@src(), .{}, a.show_resources, "panel opened");

            ctx.itemAction(.click, "Resources/Add", .{}, null);
            _ = zgui.te.check(@src(), .{}, a.resources_editor.count == 1, "Add created a slot");

            // Row 0's inputs live under the pushStrIdZ("row0") scope.
            ctx.itemInputStrValue("Resources/row0/name", "sprites");
            ctx.itemInputStrValue("Resources/row0/json", "assets/sprites.json");
            ctx.itemInputStrValue("Resources/row0/texture", "assets/sprites.png");

            ctx.itemAction(.click, "Resources/Save", .{}, null);

            const proj = a.project_manager.current_project.?;
            const in_memory = proj.config.resources.len == 1 and
                std.mem.eql(u8, proj.config.resources[0].name, "sprites");
            _ = zgui.te.check(@src(), .{}, in_memory, "config.resources updated in memory");

            // Read project.labelle off disk and confirm the resource line is there.
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/project.labelle", .{dir}) catch return;
            var file_buf: [4096]u8 = undefined;
            const file = std.fs.cwd().openFile(path, .{}) catch return;
            defer file.close();
            const n = file.read(&file_buf) catch return;
            const on_disk = std.mem.indexOf(u8, file_buf[0..n], "\"sprites\"") != null and
                std.mem.indexOf(u8, file_buf[0..n], "assets/sprites.json") != null;
            _ = zgui.te.check(@src(), .{}, on_disk, "project.labelle on disk has the resource");
        }
    });

    _ = engine.registerTest("phase3", "project_settings_edit_save", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame();
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // Open the panel.
            ctx.menuAction(.click, "View/Project Settings");
            _ = zgui.te.check(@src(), .{}, a.show_project_settings, "panel opened");

            // Type into the Title field and click Save. The button click
            // also drives the on-disk write via ProjectManager.saveProject.
            ctx.itemInputStrValue("Project Settings/Title", "Edited By TE");
            ctx.itemAction(.click, "Project Settings/Save", .{}, null);

            const proj = a.project_manager.current_project.?;
            const in_memory = std.mem.eql(u8, proj.config.title, "Edited By TE");
            _ = zgui.te.check(@src(), .{}, in_memory, "config.title updated in memory");

            // Reread project.labelle from disk and confirm the new title
            // landed there. Failure here means Save ran but didn't
            // persist (the integration we actually care about).
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/project.labelle", .{dir}) catch return;
            var file_buf: [4096]u8 = undefined;
            const file = std.fs.cwd().openFile(path, .{}) catch return;
            defer file.close();
            const n = file.read(&file_buf) catch return;
            const on_disk = std.mem.indexOf(u8, file_buf[0..n], "Edited By TE") != null;
            _ = zgui.te.check(@src(), .{}, on_disk, "project.labelle on disk has new title");
        }
    });

    // `"all"` is the canonical match-everything filter — passing "" matches
    // nothing because the filter parser treats it as "no include rule".
    engine.queueTests(.tests, "all", .{});

    // Frame loop. 1500 frames ≈ ample for any reasonable Phase-3 test;
    // the queue-empty check below is the real terminator.
    var frame: usize = 0;
    while (frame < 1500) : (frame += 1) {
        zglfw.pollEvents();

        const fb = window.getFramebufferSize();
        gl.viewport(0, 0, fb[0], fb[1]);
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
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
