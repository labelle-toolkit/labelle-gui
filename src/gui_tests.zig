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
const io_global = @import("io_global.zig");
const engine_mod = @import("engine");
const shm_mod = engine_mod.preview_mode_mod.preview_shm;

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

/// In-process synthetic SHM producer used by the PIE viewport tests
/// (#109). Tests can't drive a real engine subprocess from TE, so the
/// run callbacks stand up a `preview_shm.Producer` directly, hand its
/// shm_name to `App.attachGameView`, and publish frames between
/// yields to advance the consumer. `null` between tests; managed by
/// the `piePreview*` helpers below.
///
/// Threading note: TE runs `run` callbacks on a coroutine thread that
/// does NOT have the GL context current — `GameView.attach` /
/// `detach` call `glGenTextures` / `glDeleteTextures`, so the `run`
/// callback sets `g_pie_pending_attach` / `g_pie_pending_detach` and
/// the `gui` callback (which DOES run on the GL thread) services
/// them inside `pieServicePending`. Test code yields a frame to
/// let the request land. SHM region create + publish is GL-free and
/// stays in the `run` callback.
var g_pie_producer: ?shm_mod.Producer = null;
var g_pie_pending_attach: bool = false;
var g_pie_pending_detach: bool = false;

/// macOS caps POSIX shm names at PSHMNAMLEN (≈31 chars including the
/// leading '/'). Producer.init pre-`shm_unlink`s any stale region
/// from a previous run, so reuse across tests is safe.
const pie_shm_name: [:0]const u8 = "/lbl-gui-te-viewport";

/// Run-callback-side setup: create the SHM region (no GL), then
/// request the consumer-side attach on the next gui frame.
fn piePreviewStart(width: u32, height: u32) !void {
    if (g_pie_producer != null) {
        // Force a synchronous tear-down of any leftover from a prior
        // test. Detach happens on the gui side; producer-side cleanup
        // is fine here.
        g_pie_pending_detach = true;
        if (g_pie_producer) |*p| {
            shm_mod.signalShutdown(p.header);
            p.deinit();
            g_pie_producer = null;
        }
    }
    g_pie_producer = try shm_mod.Producer.init(pie_shm_name, .{
        .width = width,
        .height = height,
        .ring_size = 3,
    });
    g_pie_pending_attach = true;
}

/// Run-callback-side teardown: drop the producer mapping, request
/// consumer detach on the next gui frame. Idempotent.
fn piePreviewStop() void {
    g_pie_pending_detach = true;
    if (g_pie_producer) |*p| {
        shm_mod.signalShutdown(p.header);
        p.deinit();
        g_pie_producer = null;
    }
}

/// Service pending attach/detach requests from the gui (main / GL)
/// thread. Called at the top of each PIE-test `gui` callback before
/// `renderFrame`. Failing attaches surface as silent no-ops here and
/// turn into a failing `isAttached` assertion in the test.
fn pieServicePending() void {
    const app = g_app orelse return;
    if (g_pie_pending_detach) {
        app.game_view.detach();
        g_pie_pending_detach = false;
    }
    if (g_pie_pending_attach) {
        app.attachGameView(pie_shm_name) catch {};
        g_pie_pending_attach = false;
    }
}

/// Publish one frame with a known fill pattern. SHM publish is
/// GL-free, so run-callback-side. Returns the producer's
/// `frame_count` after publish, i.e. the frame_idx the consumer will
/// see on the next `poll`.
fn piePreviewPublish(byte: u8) u64 {
    const p = &(g_pie_producer.?);
    const pixels = p.pixelsPtr();
    const total: usize = @intCast(@as(u64, p.opts.width) * @as(u64, p.opts.height) * 4);
    @memset(pixels[0..total], byte);
    p.publish(true);
    return p.header.frame_count;
}

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

    var gpa: std.heap.DebugAllocator(.{}) = .init;
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

    const app = try App.init(allocator, window, .{});
    defer app.deinit();
    g_app = app;
    defer g_app = null;

    _ = engine.registerTest("phase1", "hello_world", @src(), struct {
        pub fn run(_: *zgui.te.TestContext) !void {
            _ = zgui.te.check(@src(), .{}, true, "trivially true");
        }
    });

    // Project Settings test owns its own temp project on disk, written
    // via the gui's own ProjectManager so the test exercises the real
    // save path. Cleanup runs after engine drains. Honors $TMPDIR
    // (macOS sets it; most Unix shells respect it) with a /tmp fallback.
    const tmp_base = io_global.environ().getAlloc(allocator, "TMPDIR") catch try allocator.dupe(u8, "/tmp");
    defer allocator.free(tmp_base);
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    var prng = std.Random.DefaultPrng.init(@intCast(ts.nsec));
    const dir_name = try std.fmt.allocPrint(allocator, "labelle_gui_te_{x}", .{prng.random().int(u64)});
    defer allocator.free(dir_name);
    const tmp = try std.fs.path.join(allocator, &.{
        std.mem.trimEnd(u8, tmp_base, "/\\"),
        dir_name,
    });
    defer allocator.free(tmp);
    try std.Io.Dir.cwd().createDirPath(io_global.io(), tmp);
    defer std.Io.Dir.cwd().deleteTree(io_global.io(), tmp) catch {};

    try app.project_manager.newProject("settings_te");
    try app.project_manager.saveProject(tmp);
    g_settings_project_dir = tmp;
    defer g_settings_project_dir = null;

    // Defensive: if a PIE viewport test panics mid-run and skips its
    // defer, ensure the producer mapping is torn down before the
    // process exits so the next run gets a clean shm slot.
    defer piePreviewStop();

    _ = engine.registerTest("phase3", "view_compiler_output_toggle", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // `MenuAction` walks relative to the test context's `RefID`;
            // unset RefID makes the path's first segment be interpreted
            // as a window name (e.g. "View" would be looked up as a
            // top-level window), so anchor it to the main menu bar
            // explicitly. The `ctx.yield(1)` after each click gives
            // ImGui one frame to update the menu open/close state
            // before the next item lookup.
            ctx.setRef("//##MainMenuBar");

            // Sanity: panel starts closed.
            _ = zgui.te.check(@src(), .{}, !a.show_compiler_output, "panel starts closed");

            // Drive View > Compiler Output.
            ctx.menuAction(.click, "View/Compiler Output");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, a.show_compiler_output, "View/Compiler Output opens panel");

            // Toggle off again to confirm the menu reflects current state.
            ctx.menuAction(.click, "View/Compiler Output");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, !a.show_compiler_output, "View/Compiler Output closes panel");
        }
    });

    // Drop a scene file with a Sprite component into the temp project
    // so the Scene module's save test can exercise round-trip
    // preservation through the Save button.
    {
        var scene_path_buf: [512]u8 = undefined;
        const scene_path = try std.fmt.bufPrint(&scene_path_buf, "{s}/scenes/scene_with_sprite.jsonc", .{tmp});
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = scene_path,
            .data = 
            \\{
            \\    "name": "scene_with_sprite",
            \\    "entities": [
            \\        { "prefab": "coin", "components": { "Position": { "x": 1, "y": 2 }, "Sprite": { "n": "coin" } } }
            \\    ]
            \\}
        ,
        });
    }

    // Drop a tiny Zig script into `scripts/flows/` so the Flow
    // viewer's open path has a real file to parse. The script is
    // intentionally minimal — one entry-point fn with an `if` —
    // because the assertion below only confirms the graph rendered,
    // not its exact topology.
    {
        var flow_path_buf: [512]u8 = undefined;
        const flow_path = try std.fmt.bufPrint(&flow_path_buf, "{s}/scripts/flows/sample.zig", .{tmp});
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = flow_path,
            .data =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    if (dt > 0) {
            \\        _ = dt;
            \\    }
            \\}
        ,
        });
    }

    // And a prefab with both top-level components and a children
    // array so the prefab editor's children-editing path has
    // something to test against (mirrors hydroponics-style prefabs
    // in real projects).
    {
        var prefab_path_buf: [512]u8 = undefined;
        const prefab_path = try std.fmt.bufPrint(&prefab_path_buf, "{s}/prefabs/coin.jsonc", .{tmp});
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = prefab_path,
            .data = 
            \\{
            \\    "components": {
            \\        "Sprite": { "sprite_name": "coin", "pivot": "center" },
            \\        "Coin": {}
            \\    },
            \\    "children": [
            \\        { "components": { "Sprite": { "n": "deco" }, "Position": { "x": 1, "y": 2 } } }
            \\    ]
            \\}
        ,
        });
    }

    _ = engine.registerTest("phase3", "prefab_open_save_preserves_extras", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
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

            // Sprite is a typed/managed component so it round-trips
            // through `loaded.entity.sprite`, not `component_extras`.
            // The fixture has two top-level components (Sprite +
            // Coin) but only Coin lands in extras.
            const opened_ok = a.open_tabs.items.len == 1 and
                a.open_tabs.items[0] == .prefab and
                a.open_tabs.items[0].prefab.loaded.component_extras.len == 1 and
                a.open_tabs.items[0].prefab.loaded.children.len == 1;
            _ = zgui.te.check(@src(), .{}, opened_ok, "prefab opened with 1 extra (Coin) + 1 child");

            // Move the child's Position, save through the public API,
            // and confirm the new position lands on disk while Sprite +
            // Coin survive verbatim.
            const tab = &a.open_tabs.items[0].prefab;
            tab.loaded.children[0].position.?.x = 999;
            tab.is_dirty = true;
            prefab_mod.savePrefab(tab, a);
            _ = zgui.te.check(@src(), .{}, !tab.is_dirty, "is_dirty cleared after Save");

            const content = std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, a.allocator, .limited(4096)) catch return;
            defer a.allocator.free(content);

            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Sprite\"") != null, "Sprite preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Coin\"") != null, "Coin preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"x\": 999") != null, "child Position x persisted");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"children\":") != null, "children block emitted");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("phase3", "scene_open_save_preserves_extras", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
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

            const content = std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, a.allocator, .limited(4096)) catch return;
            defer a.allocator.free(content);

            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"Sprite\"") != null, "Sprite preserved on disk");
            _ = zgui.te.check(@src(), .{}, std.mem.indexOf(u8, content, "\"x\": 999") != null, "edited Position written");

            // Close the tab cleanly so subsequent tests see a fresh App.
            a.closeTab(0);
        }
    });

    _ = engine.registerTest("phase3", "resources_add_and_save", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            ctx.setRef("//##MainMenuBar");
            ctx.menuAction(.click, "View/Resources");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, a.show_resources, "panel opened");

            // The panel's own widgets live under the "Resources" window
            // — point the test ref there so itemAction can resolve
            // "Add" / "row0/name" / etc. without spelling out the
            // window every time.
            ctx.setRef("Resources");

            ctx.itemAction(.click, "Add", .{}, null);
            _ = zgui.te.check(@src(), .{}, a.resources_editor.count == 1, "Add created a slot");

            // Use the same fixture values the unit test in src/tests.zig
            // round-trips (see "resources round-trip through save +
            // load") so the on-disk values line up with
            // ResourceFactory's defaults. Row 0's inputs live under
            // the pushStrIdZ("row0") scope.
            ctx.itemInputStrValue("row0/name", "sprites");
            ctx.itemInputStrValue("row0/json", "assets/sprites.json");
            ctx.itemInputStrValue("row0/texture", "assets/sprites.png");

            ctx.itemAction(.click, "Save", .{}, null);

            const proj = a.project_manager.current_project.?;
            const in_memory = proj.config.resources.len == 1 and
                std.mem.eql(u8, proj.config.resources[0].name, "sprites");
            _ = zgui.te.check(@src(), .{}, in_memory, "config.resources updated in memory");

            // Read project.labelle off disk and confirm the resource line is there.
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/project.labelle", .{dir}) catch return;
            const content = std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, a.allocator, .limited(4096)) catch return;
            defer a.allocator.free(content);
            const on_disk = std.mem.indexOf(u8, content, "\"sprites\"") != null and
                std.mem.indexOf(u8, content, "assets/sprites.json") != null;
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
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            ctx.setRef("//##MainMenuBar");

            // Sanity: panel starts closed.
            _ = zgui.te.check(@src(), .{}, !a.show_preview, "Preview panel starts closed");

            // View menu toggle.
            ctx.menuAction(.click, "View/Preview");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, a.show_preview, "View/Preview opens panel");

            // From idle, isActive must be false.
            _ = zgui.te.check(@src(), .{}, !a.preview.isActive(), "preview starts inactive");

            a.stopPreview();
            _ = zgui.te.check(@src(), .{}, !a.preview.isActive(), "preview still inactive after Stop");

            // Toggle off again.
            ctx.menuAction(.click, "View/Preview");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, !a.show_preview, "View/Preview closes panel");
        }
    });

    _ = engine.registerTest("phase3", "flow_opens_and_renders_graph", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/sample.zig", .{dir}) catch return;

            a.openFlow(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlow must succeed");
                return;
            };
            ctx.yield(2);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow tab opened");
            if (!opened_ok) return;

            const tab = &a.open_tabs.items[0].flow;
            const has_graph = tab.graph != null;
            _ = zgui.te.check(@src(), .{}, has_graph, "graph derived from source");
            if (has_graph) {
                const g = tab.graph.?;
                _ = zgui.te.check(@src(), .{}, g.entry_points.len >= 1, "at least one entry point");
                _ = zgui.te.check(@src(), .{}, g.nodes.len >= 1, "at least one node");
            }

            // save/isDirty are no-ops for flows — just confirm they
            // don't blow up.
            _ = zgui.te.check(@src(), .{}, !a.open_tabs.items[0].isDirty(), "flow is never dirty");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("phase3", "project_settings_edit_save", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            // Synthetic dt; tests don't observe status_timer decay.
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            ctx.setRef("//##MainMenuBar");
            // Open the panel.
            ctx.menuAction(.click, "View/Project Settings");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, a.show_project_settings, "panel opened");

            // Type into the Title field and click Save. The button click
            // also drives the on-disk write via ProjectManager.saveProject.
            ctx.setRef("Project Settings");
            ctx.itemInputStrValue("Title", "Edited By TE");
            ctx.itemAction(.click, "Save", .{}, null);

            const proj = a.project_manager.current_project.?;
            const in_memory = std.mem.eql(u8, proj.config.title, "Edited By TE");
            _ = zgui.te.check(@src(), .{}, in_memory, "config.title updated in memory");

            // Reread project.labelle from disk and confirm the new title
            // landed there. Failure here means Save ran but didn't
            // persist (the integration we actually care about).
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/project.labelle", .{dir}) catch return;
            const content = std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, a.allocator, .limited(4096)) catch return;
            defer a.allocator.free(content);
            const on_disk = std.mem.indexOf(u8, content, "Edited By TE") != null;
            _ = zgui.te.check(@src(), .{}, on_disk, "project.labelle on disk has new title");
        }
    });

    // ── PIE viewport tests (#109) ──────────────────────────────────
    //
    // Cover the Game View panel (#111 / src/modules/game_view.zig)
    // against an in-process synthetic SHM producer. The zgui binding
    // doesn't expose `ImGuiTestEngine_CaptureScreenshot` and has no
    // window-by-name introspection, so each test asserts on the
    // Zig-level state mirror (`GameView.isAttached`, `last_frame_idx`,
    // `last_latency_ns`) rather than on rendered pixels or scraped
    // ImGui text. The rendered text in the Stats window is fed
    // verbatim from those same fields (`renderStats` in
    // `src/modules/game_view.zig`), so a mirror assertion is
    // equivalent to a screenshot for our purposes.

    _ = engine.registerTest("pie", "viewport/renders_on_attach", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            piePreviewStart(64, 64) catch {
                _ = zgui.te.check(@src(), .{}, false, "piePreviewStart must succeed");
                return;
            };
            defer piePreviewStop();
            // Two yields: first lets the gui callback service the
            // pending attach (which does GL work and must run on
            // the main thread), second lets the panel render.
            ctx.yield(2);

            // Equivalent of TE window introspection: attachGameView
            // toggles `show_game_view` on AND the consumer's
            // isAttached() flips true. The Game View module's
            // `render` is gated on `is_open.*` from
            // Registry.renderAllPanels, so these two flags together
            // are the editor-side proof that the panel rendered for
            // this frame.
            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "consumer attached after producer detected");
            _ = zgui.te.check(@src(), .{}, a.show_game_view, "Game View panel auto-opens on attach");

            // Let the deferred detach land before the next test
            // observes a stale attachment.
            ctx.yield(1);
        }
    });

    _ = engine.registerTest("pie", "viewport/frame_idx_advances", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            piePreviewStart(64, 64) catch {
                _ = zgui.te.check(@src(), .{}, false, "piePreviewStart must succeed");
                return;
            };
            defer piePreviewStop();
            ctx.yield(2); // service the deferred attach + render once.

            // Drive 60 publishes interleaved with yields. Each yield
            // runs one gui-callback frame which invokes
            // `App.renderFrame` -> registry.renderAllPanels ->
            // game_view.render -> `app.game_view.poll()`. The
            // consumer's `last_frame_idx` is the only test surface
            // (no pixel diff), so we just confirm it advances
            // monotonically across the window.
            var prev_idx: ?u64 = null;
            var saw_increase: bool = false;
            var i: usize = 0;
            while (i < 60) : (i += 1) {
                _ = piePreviewPublish(@intCast(i & 0xFF));
                ctx.yield(1);

                const cur = a.game_view.last_frame_idx orelse continue;
                if (prev_idx) |p| {
                    if (cur > p) saw_increase = true;
                    // Monotonic: never decrease.
                    if (cur < p) {
                        _ = zgui.te.check(@src(), .{}, false, "last_frame_idx must not decrease");
                    }
                }
                prev_idx = cur;
            }
            _ = zgui.te.check(@src(), .{}, prev_idx != null, "consumer saw at least one frame");
            _ = zgui.te.check(@src(), .{}, saw_increase, "last_frame_idx advanced across the window");

            ctx.yield(1);
        }
    });

    _ = engine.registerTest("pie", "viewport/latency_stat_visible", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            piePreviewStart(64, 64) catch {
                _ = zgui.te.check(@src(), .{}, false, "piePreviewStart must succeed");
                return;
            };
            defer piePreviewStop();
            ctx.yield(2); // service the deferred attach.

            _ = piePreviewPublish(0xAA);
            ctx.yield(2);

            // The Stats window prints
            //     "last latency  = {d:.2} ms"
            // from `last_latency_ns`. A non-zero `last_latency_ns`
            // after a real publish + poll is the test surface that
            // proves the stat line rendered with a real reading
            // (rather than the "Not attached." fallback or the
            // pre-first-frame zero path). The zgui binding has no
            // window-text introspection so a literal substring
            // match isn't reachable from here — the underlying
            // state mirror is the next best thing.
            _ = zgui.te.check(@src(), .{}, a.show_game_view, "Stats window's parent Game View panel is open");
            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "consumer attached so Stats window shows live numbers");
            _ = zgui.te.check(@src(), .{}, a.game_view.last_latency_ns > 0, "last_latency_ns populated from a real frame");

            ctx.yield(1);
        }
    });

    _ = engine.registerTest("pie", "viewport/disconnect_handled_cleanly", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            piePreviewStart(64, 64) catch {
                _ = zgui.te.check(@src(), .{}, false, "piePreviewStart must succeed");
                return;
            };
            // Defer-stop covers any early-return slip-through;
            // explicit drop below tears the producer down mid-test
            // to simulate SIGTERM.
            defer piePreviewStop();
            ctx.yield(2); // service the deferred attach.

            _ = piePreviewPublish(0x55);
            ctx.yield(2);
            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "attached after first publish");
            _ = zgui.te.check(@src(), .{}, a.game_view.last_frame_idx != null, "saw a frame before disconnect");

            // Simulate the engine dying mid-session: producer
            // munmap + shm_unlink. The consumer's mmap stays valid
            // (POSIX: unlink removes the name, not pages held by
            // existing mappings) so polling won't crash — it just
            // sees `frame_count` flat-line. `signalShutdown` runs
            // here too, but the gui consumer doesn't poll the
            // shutdown flag; the editor-side disconnect signal
            // comes from the preview-mode TCP transport (#112)
            // which isn't wired through here.
            if (g_pie_producer) |*p| {
                shm_mod.signalShutdown(p.header);
                p.deinit();
                g_pie_producer = null;
            }

            // Yield a handful of frames against the orphaned
            // mapping. A bug that read past the unmapped region
            // would segfault here; the assertion is implicit
            // (we get to the next line without crashing).
            ctx.yield(10);

            // The editor reaches a "no preview" state when
            // `App.attachGameView`'s future re-attach hook decides
            // the producer is gone. That hook isn't wired yet
            // (it's the follow-up to #112's TCP transport restore
            // — see the comment above `attachGameView` in
            // `src/app.zig`), so the test exercises the manual
            // detach path: `game_view.detach()` is what that hook
            // will call. Detach does GL work so we route it
            // through the gui-thread flag, same as attach.
            g_pie_pending_detach = true;
            ctx.yield(2);
            _ = zgui.te.check(@src(), .{}, !a.game_view.isAttached(), "consumer reports detached after teardown");
            _ = zgui.te.check(@src(), .{}, a.game_view.tex_id == 0, "GL texture released on detach");
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
