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
const scene_mod = @import("modules/scene.zig");
const prefab_mod = @import("modules/prefab.zig");

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
    // save path. Cleanup runs after engine drains. Honors $TMPDIR
    // (macOS sets it; most Unix shells respect it) with a /tmp fallback.
    const tmp_base = std.process.getEnvVarOwned(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const dir_name = try std.fmt.allocPrint(allocator, "labelle_gui_te_{x}", .{prng.random().int(u64)});
    defer allocator.free(dir_name);
    const tmp = try std.fs.path.join(allocator, &.{
        std.mem.trimRight(u8, tmp_base, "/\\"),
        dir_name,
    });
    defer allocator.free(tmp);
    try std.fs.cwd().makePath(tmp);
    defer std.fs.cwd().deleteTree(tmp) catch {};

    try app.project_manager.newProject("settings_te");
    try app.project_manager.saveProject(tmp);
    g_settings_project_dir = tmp;
    defer g_settings_project_dir = null;

    _ = engine.registerTest("phase3", "view_compiler_output_toggle", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
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

    // Drop a scene file with a Sprite component into the temp project
    // so the Scene module's save test can exercise round-trip
    // preservation through the Save button.
    {
        var scene_path_buf: [512]u8 = undefined;
        const scene_path = try std.fmt.bufPrint(&scene_path_buf, "{s}/scenes/scene_with_sprite.jsonc", .{tmp});
        const sf = try std.fs.cwd().createFile(scene_path, .{});
        try sf.writeAll(
            \\{
            \\    "name": "scene_with_sprite",
            \\    "entities": [
            \\        { "prefab": "coin", "components": { "Position": { "x": 1, "y": 2 }, "Sprite": { "n": "coin" } } }
            \\    ]
            \\}
        );
        sf.close();
    }

    // And a prefab with both top-level components and a children
    // array so the prefab editor's children-editing path has
    // something to test against (mirrors hydroponics-style prefabs
    // in real projects).
    {
        var prefab_path_buf: [512]u8 = undefined;
        const prefab_path = try std.fmt.bufPrint(&prefab_path_buf, "{s}/prefabs/coin.jsonc", .{tmp});
        const pf = try std.fs.cwd().createFile(prefab_path, .{});
        try pf.writeAll(
            \\{
            \\    "components": {
            \\        "Sprite": { "sprite_name": "coin", "pivot": "center" },
            \\        "Coin": {}
            \\    },
            \\    "children": [
            \\        { "components": { "Sprite": { "n": "deco" }, "Position": { "x": 1, "y": 2 } } }
            \\    ]
            \\}
        );
        pf.close();
    }

    _ = engine.registerTest("phase3", "prefab_open_save_preserves_extras", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/prefabs/coin.jsonc", .{dir}) catch return;

            a.openPrefab(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openPrefab must succeed");
                return;
            };
            ctx.yield(1);

            const opened_ok = a.open_tabs.items.len == 1 and
                a.open_tabs.items[0] == .prefab and
                a.open_tabs.items[0].prefab.loaded.component_extras.len == 2 and
                a.open_tabs.items[0].prefab.loaded.children.len == 1;
            _ = zgui.te.check(@src(), .{}, opened_ok, "prefab opened with 2 components + 1 child");

            // Move the child's Position, save through the public API,
            // and confirm the new position lands on disk while Sprite +
            // Coin survive verbatim.
            const tab = &a.open_tabs.items[0].prefab;
            tab.loaded.children[0].position.?.x = 999;
            tab.is_dirty = true;
            prefab_mod.savePrefab(tab, a);
            _ = zgui.te.check(@src(), .{}, !tab.is_dirty, "is_dirty cleared after Save");

            var file_buf: [4096]u8 = undefined;
            const file = std.fs.cwd().openFile(path, .{}) catch return;
            defer file.close();
            const n = file.read(&file_buf) catch return;
            const content = file_buf[0..n];

            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Sprite\"") != null, "Sprite preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Coin\"") != null, "Coin preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"x\": 999") != null, "child Position x persisted");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"children\":") != null, "children block emitted");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("phase3", "scene_open_save_preserves_extras", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/scenes/scene_with_sprite.jsonc", .{dir}) catch return;

            // Drive the public openScene API — same path the tree-click
            // handler uses, just bypassed for test setup.
            a.openScene(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openScene must succeed");
                return;
            };
            ctx.yield(1);

            const opened_ok = a.open_tabs.items.len == 1 and
                a.open_tabs.items[0] == .scene and
                a.open_tabs.items[0].scene.loaded.scene.entities.len == 1;
            _ = zgui.te.check(@src(), .{}, opened_ok, "scene opened with one entity");

            // Edit the in-memory position, then save via the module's
            // public saveScene (the same function the tab's Save button
            // calls). Driving the button via TE refs through the
            // nested tab-bar ID stack is brittle; saveScene is what we
            // actually care about here.
            const tab = &a.open_tabs.items[0].scene;
            tab.loaded.scene.entities[0].position.?.x = 999;
            tab.is_dirty = true;
            scene_mod.saveScene(tab, a);
            _ = zgui.te.check(@src(), .{}, !tab.is_dirty, "is_dirty cleared after Save");

            var file_buf: [4096]u8 = undefined;
            const file = std.fs.cwd().openFile(path, .{}) catch return;
            defer file.close();
            const n = file.read(&file_buf) catch return;
            const content = file_buf[0..n];

            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Sprite\"") != null, "Sprite preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"x\": 999") != null, "edited Position written");

            // Close the tab cleanly so subsequent tests see a fresh App.
            a.closeTab(0);
        }
    });

    _ = engine.registerTest("phase3", "resources_add_and_save", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
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

    // Preview panel — toggle from View menu and drive the Stop button
    // path. We deliberately don't drive Run preview here because that
    // would spawn the real `labelle` launcher (sibling repos #94/#193
    // haven't landed --preview-mode yet). Hand-injecting a state via
    // the public API keeps this test hermetic — same pattern the
    // scene/prefab tests use to avoid touching nfd.
    _ = engine.registerTest("phase3", "preview_panel_toggle_and_stop", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // Sanity: panel starts closed.
            _ = zgui.te.check(@src(), .{}, !a.show_preview, "Preview panel starts closed");

            // View menu toggle.
            ctx.menuAction(.click, "View/Preview");
            _ = zgui.te.check(@src(), .{}, a.show_preview, "View/Preview opens panel");

            // From idle, isActive must be false and Stop is a no-op
            // (state stays at .stopped after a stop call).
            _ = zgui.te.check(@src(), .{}, !a.preview.isActive(), "preview starts inactive");

            // Drive the Stop path through the App method — exercises
            // the same code the panel button hits.
            a.stopPreview();
            _ = zgui.te.check(@src(), .{}, a.preview.state == .stopped, "Stop preview lands at .stopped");

            // Toggle off again.
            ctx.menuAction(.click, "View/Preview");
            _ = zgui.te.check(@src(), .{}, !a.show_preview, "View/Preview closes panel");
        }
    });

    _ = engine.registerTest("phase3", "project_settings_edit_save", @src(), struct {
        fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
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
