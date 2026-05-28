//! UI test runner — drives the real `App` against the ImGui Test Engine.
//!
//! Boots a hidden GLFW window, constructs an `App`, registers TE tests
//! that drive menu actions and assert on App state, runs the frame loop
//! until the test queue drains. Exit code reflects pass/fail.

const std = @import("std");
const builtin = @import("builtin");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");

const App = @import("app.zig").App;
const scene_mod = @import("modules/scene.zig");
const prefab_mod = @import("modules/prefab.zig");
const io_global = @import("io_global.zig");
const flow_io = @import("flow_io.zig");
const node_catalog = @import("flow_node_catalog.zig");
const engine_mod = @import("engine");
const shm_mod = engine_mod.preview_mode_mod.preview_shm;
const iosurface_producer_mod = engine_mod.preview_mode_mod.preview_iosurface;

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
        // Shm transport: the synthetic producer publishes BGRA8/RGBA8
        // bytes into the ring directly. The iosurface dispatch lives
        // in its own dedicated test below.
        app.attachGameView(pie_shm_name, "bgra8") catch {};
        g_pie_pending_attach = false;
    }
    if (g_pie_pending_ios_attach) {
        app.attachGameView(pie_ios_shm_name, "iosurface_bgra8") catch {};
        g_pie_pending_ios_attach = false;
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

// ── iosurface synthetic producer (macOS-only) ──────────────────────
//
// Parallels the shm helpers above. Runs the engine's iosurface
// producer in-process so the TE iosurface dispatch test can drive
// `App.attachGameView(name, "iosurface_bgra8")` and observe the
// consumer flip into the rectangle-texture + FBO blit path. Lookups
// rely on `kIOSurfaceIsGlobal = true` (the engine producer sets it),
// which works in-process and is what `iosurface.Consumer.init`
// expects. On non-macOS hosts these globals stay null and the test
// skips itself.

var g_pie_ios_producer: ?iosurface_producer_mod.Producer = null;

const pie_ios_shm_name: [:0]const u8 = "/lbl-gui-te-ios";

fn pieIosStart(width: u32, height: u32) !void {
    if (builtin.os.tag != .macos) return;
    if (g_pie_ios_producer != null) {
        g_pie_pending_detach = true;
        if (g_pie_ios_producer) |*p| {
            shm_mod.signalShutdown(p.shm_producer.header);
            p.deinit();
            g_pie_ios_producer = null;
        }
    }
    g_pie_ios_producer = try iosurface_producer_mod.Producer.init(pie_ios_shm_name, .{
        .width = width,
        .height = height,
        .ring_size = 3,
    });
    g_pie_pending_ios_attach = true;
}

fn pieIosStop() void {
    if (builtin.os.tag != .macos) return;
    g_pie_pending_detach = true;
    if (g_pie_ios_producer) |*p| {
        shm_mod.signalShutdown(p.shm_producer.header);
        p.deinit();
        g_pie_ios_producer = null;
    }
}

/// Lock the next IOSurface, fill with a flat byte (B = G = R = A =
/// byte → easy to recognise in a pixel inspector if a later test
/// adds capture), publish. Returns the producer's frame_count.
fn pieIosPublish(byte: u8) u64 {
    if (builtin.os.tag != .macos) return 0;
    const p = &(g_pie_ios_producer.?);
    const locked = p.pixelsPtr() catch return p.shm_producer.header.frame_count;
    // BGRA8 — bytes_per_row may pad past width*4.
    const rows: usize = @intCast(p.height);
    const row_bytes: usize = @intCast(p.width * 4);
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        const row_base: [*]u8 = locked.base + y * locked.bytes_per_row;
        @memset(row_base[0..row_bytes], byte);
    }
    p.publish(true) catch {};
    return p.shm_producer.header.frame_count;
}

/// Pending attach flag for the iosurface path — services on the GL
/// thread via `pieServicePending`. Separate from the shm flag so the
/// two paths can coexist in the same test binary without clobbering
/// each other.
var g_pie_pending_ios_attach: bool = false;

/// Pending close request for the Game View tab (#128). Set from the
/// run-callback thread, serviced in the gui callback because
/// `closeTab`'s `.game_view` arm calls `game_view.detach()` which is
/// GL-thread work.
var g_pending_game_view_close: bool = false;

/// Count `.game_view` entries in `App.open_tabs`. Used by the #128
/// tests to assert tab dedup without taking a dep on absolute index
/// (other tests may leave document tabs lying around).
fn countGameViewTabs(a: *App) usize {
    var n: usize = 0;
    for (a.open_tabs.items) |t| switch (t) {
        .game_view => n += 1,
        else => {},
    };
    return n;
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
    defer pieIosStop();

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

    _ = engine.registerTest("phase3", "view_atlas_viewer_toggle", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };
            ctx.setRef("//##MainMenuBar");

            _ = zgui.te.check(@src(), .{}, !a.show_atlas_viewer, "panel starts closed");

            // Open it — with no project loaded the panel takes the
            // "no atlases" path; yielding a few frames exercises the
            // render code and would trip any imgui assertion.
            ctx.menuAction(.click, "View/Atlas Viewer");
            ctx.yield(3);
            _ = zgui.te.check(@src(), .{}, a.show_atlas_viewer, "View/Atlas Viewer opens panel");

            ctx.menuAction(.click, "View/Atlas Viewer");
            ctx.yield(1);
            _ = zgui.te.check(@src(), .{}, !a.show_atlas_viewer, "View/Atlas Viewer closes panel");
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
            \\[
            \\    { "prefab": "coin", "Position": { "x": 1, "y": 2 }, "Sprite": { "sprite_name": "coin" } }
            \\]
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

    // ── RFC-FLOW-VOCABULARY phase 4 fixtures (#171) ────────────────
    //
    // Three `.flow.jsonc` files covering the new editor surfaces:
    //
    //   - `hit_counter.flow.jsonc`: canonical 2-node v2 doc — one
    //     `Event` trigger, one `ChangeVariable` action, one declared
    //     `variables[]` entry. Drives the variables-sidebar +
    //     event-trigger + command-visual tests.
    //   - `wire_fit_ok.flow.jsonc`: two CustomNode nodes whose pin
    //     types match (Event.entity:EntityId → apply_impulse.entity:EntityId),
    //     edge present. Drives the "compatible drop" test.
    //   - `wire_fit_bad.flow.jsonc`: same shape but with a `Literal`
    //     string driving an i32 pin — no edge, since the editor
    //     should refuse it. Drives the "incompatible drop" test.
    {
        var fp_buf: [512]u8 = undefined;
        const hit_counter_path = try std.fmt.bufPrint(&fp_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{tmp});
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = hit_counter_path,
            .data =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "pos": [40, 40], "name": "game.on_tick" },
            \\    { "id": 2, "type": "ChangeVariable", "pos": [240, 40], "name": "hits", "by": 1 }
            \\  ],
            \\  "edges": []
            \\}
        ,
        });
    }
    {
        var fp_buf: [512]u8 = undefined;
        const ok_path = try std.fmt.bufPrint(&fp_buf, "{s}/scripts/flows/wire_fit_ok.flow.jsonc", .{tmp});
        // Two `ChangeVariable` nodes on an `i32` var — `by` is an i32
        // input pin on both. (The editor surfaces variable-op pin types
        // from the declared variable.) Edge wires node 2's reporter
        // shape against itself trivially; this fixture only proves the
        // file round-trips with an edge in place.
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = ok_path,
            .data =
            \\{
            \\  "name": "wire_fit_ok",
            \\  "variables": [
            \\    { "name": "counter", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "pos": [40, 40], "name": "game.on_tick" },
            \\    { "id": 2, "type": "ChangeVariable", "pos": [240, 40], "name": "counter", "by": 1 }
            \\  ],
            \\  "edges": []
            \\}
        ,
        });
    }
    {
        var fp_buf: [512]u8 = undefined;
        const bad_path = try std.fmt.bufPrint(&fp_buf, "{s}/scripts/flows/wire_fit_bad.flow.jsonc", .{tmp});
        // A `Literal` carrying a string value next to a `ChangeVariable`
        // on an `i32`. The string→i32 wire is the canonical "refuse"
        // case the editor's wire-fit logic must catch. No edges in the
        // file — the test asserts the editor would refuse to add one.
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = bad_path,
            .data =
            \\{
            \\  "name": "wire_fit_bad",
            \\  "variables": [
            \\    { "name": "counter", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Literal", "pos": [40, 40], "value": "\"hello\"" },
            \\    { "id": 2, "type": "ChangeVariable", "pos": [240, 40], "name": "counter", "by": 1 }
            \\  ],
            \\  "edges": []
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
            \\    "Sprite": { "sprite_name": "coin", "pivot": "center" },
            \\    "Coin": {},
            \\    "children": [
            \\        { "Sprite": { "sprite_name": "deco" }, "Position": { "x": 1, "y": 2 } }
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

    // ── RFC-FLOW-VOCABULARY phase 4 editor tests (#171) ───────────────
    //
    // Phase 4 (commit 9555e68) shipped the `.flow.jsonc` editor with a
    // pile of new surfaces — Event/ChangeVariable/CustomNode kinds, the
    // variables sidebar with `+ Get`/`+ Set`/`+ Change` drop buttons, a
    // plugin palette section, wire-fit type checks, "Add raw call…"
    // modal escape hatch — covered by file-format tests but not by a
    // UI driver. These tests drive `App` against the same hidden window
    // and assert on the editor's state at the `FlowDoc` level.
    //
    // Pixel/style checks (e.g. command vs reporter visual silhouette)
    // are skipped — TE has no zgui-exposed style introspection and a
    // pixel diff would be brittle. Instead the tests assert on the
    // `NodeKind` (the value that drives the visual), which is what a
    // regression would actually corrupt.

    _ = engine.registerTest("flow_vocab", "flow_doc_opens_v2_canonical", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;

            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            ctx.yield(2);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }

            const tab = &a.open_tabs.items[0].flow_doc;
            // v2 docs use on-canvas `Event` nodes — no file-level
            // header — so `event_present` must be false even though
            // the doc loaded successfully.
            _ = zgui.te.check(@src(), .{}, !tab.doc.event_present, "v2 doc has no file-level event header");
            _ = zgui.te.check(@src(), .{}, tab.doc.nodes.len == 2, "hit_counter has exactly two nodes");
            if (tab.doc.nodes.len == 2) {
                // First node is an Event triggered by "game.on_tick".
                _ = zgui.te.check(@src(), .{}, tab.doc.nodes[0].kind == .event, "node[0] is .event");
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, tab.doc.nodes[0].event_ref, "game.on_tick"),
                    "node[0] event_ref is game.on_tick",
                );
                // Second node is a ChangeVariable targeting "hits"
                // with the canonical `by: 1` inline literal.
                _ = zgui.te.check(@src(), .{}, tab.doc.nodes[1].kind == .change_variable, "node[1] is .change_variable");
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, tab.doc.nodes[1].variable_ref, "hits"),
                    "node[1] variable_ref is hits",
                );
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, tab.doc.nodes[1].by_text, "1"),
                    "ChangeVariable by_text is canonical \"1\"",
                );
            }
            // Edges block is present but empty in the fixture; no
            // wires were authored.
            _ = zgui.te.check(@src(), .{}, tab.doc.edges.len == 0, "no edges in fixture");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "variables_sidebar_renders_declared_vars", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;

            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            // A few frames so `renderVariablesSidebar` actually runs.
            // The sidebar widget doesn't expose its rendered rows to
            // TE introspection, so we yield to catch any imgui
            // assertion the renderer would trip on a v2 doc with
            // declared variables, then assert on the underlying
            // `doc.variables` slice — what the sidebar reads from.
            ctx.yield(3);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }

            const tab = &a.open_tabs.items[0].flow_doc;
            _ = zgui.te.check(@src(), .{}, tab.doc.variables.len == 1, "exactly one declared variable");
            if (tab.doc.variables.len == 1) {
                const v = tab.doc.variables[0];
                _ = zgui.te.check(@src(), .{}, std.mem.eql(u8, v.name, "hits"), "variable name is hits");
                _ = zgui.te.check(@src(), .{}, std.mem.eql(u8, v.type_name, "i32"), "variable type is i32");
                _ = zgui.te.check(@src(), .{}, std.mem.eql(u8, v.default_text, "0"), "variable default is 0");
                _ = zgui.te.check(@src(), .{}, !v.isNullable(), "i32 var is not nullable");
            }
            // Loading a v2 doc must not have flipped `is_dirty` — a
            // round-trip check piggybacked on the render frames.
            _ = zgui.te.check(@src(), .{}, !tab.is_dirty, "fresh-loaded doc is not dirty");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "variables_sidebar_button_emits_node", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;

            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            ctx.yield(3);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }

            const tab = &a.open_tabs.items[0].flow_doc;
            const nodes_before = tab.doc.nodes.len;
            const edges_before = tab.doc.edges.len;

            // Drive the `+ Get` button. The variables sidebar lives
            // inside the `##flowdoc_inspector` child window of `##main`;
            // the button label `Get##g0` (sidebar index 0 for the first
            // variable) is unique within the tab body. Use the `**/`
            // wildcard so TE searches across windows for the matching
            // label — the inspector child has no stable absolute ref
            // path because it nests inside an unnamed tab item.
            ctx.itemAction(.click, "**/Get##g0", .{}, null);
            ctx.yield(2);

            // The new node lands on the same FlowDoc. `addVarOpNode`
            // pre-names it to the variable, so the sidebar's
            // synthesized node carries `variable_ref == "hits"`.
            // (When TE can't resolve the button — e.g. on a future
            // refactor that renames it — the count stays equal and
            // this assertion fails loudly with a useful message.)
            _ = zgui.te.check(
                @src(),
                .{},
                tab.doc.nodes.len == nodes_before + 1,
                "+ Get adds exactly one node",
            );
            _ = zgui.te.check(
                @src(),
                .{},
                tab.doc.edges.len == edges_before,
                "+ Get does not add edges",
            );
            if (tab.doc.nodes.len == nodes_before + 1) {
                const added = tab.doc.nodes[nodes_before];
                _ = zgui.te.check(
                    @src(),
                    .{},
                    added.kind == .get_variable,
                    "added node is .get_variable",
                );
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, added.variable_ref, "hits"),
                    "added node variable_ref is hits",
                );
                _ = zgui.te.check(@src(), .{}, tab.is_dirty, "tab marked dirty after button");
            }

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "palette_has_plugin_section", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // The palette section is rendered every frame from
            // `flow_node_catalog.entries`. Opening any flow doc lets
            // `renderNodePalette` run — yielding a few frames catches
            // any assertion on the per-plugin section drawing.
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;
            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            ctx.yield(3);

            // Catalog API: the static catalog must list the box2d
            // FlowNode the RFC calls out (phase 4 entry point).
            const apply_impulse = node_catalog.lookup("box2d.apply_impulse");
            _ = zgui.te.check(@src(), .{}, apply_impulse != null, "catalog has box2d.apply_impulse");
            if (apply_impulse) |entry| {
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, entry.category, "box2d"),
                    "apply_impulse category is box2d",
                );
                _ = zgui.te.check(
                    @src(),
                    .{},
                    entry.kind == .command,
                    "apply_impulse is a command",
                );
            }

            // The palette section iteration logic groups by category.
            // Verify at least one `box2d` entry exists in the static
            // catalog so the section is non-empty (a regression that
            // dropped the box2d category would render an empty
            // `Plugins` header — silent UX rot the file-format tests
            // wouldn't catch).
            var box2d_count: usize = 0;
            for (node_catalog.entries) |e| {
                if (std.mem.eql(u8, e.category, "box2d")) box2d_count += 1;
            }
            _ = zgui.te.check(@src(), .{}, box2d_count >= 1, "palette has at least one box2d entry");

            // Spot-check the "Add raw call…" button label is present
            // by driving it through TE. Clicking it opens the modal
            // popup (verified via the next test's separate fixture).
            // Here we just confirm the label resolves — a refactor
            // that renamed the button would fail this lookup.
            ctx.itemAction(.click, "**/+ Add raw call...", .{}, null);
            ctx.yield(2);
            // Close the modal so it doesn't leak into the next test.
            // The modal doesn't auto-close on its own; sending the
            // Cancel button keeps state clean.
            ctx.itemAction(.click, "**/Cancel", .{}, null);
            ctx.yield(1);

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "wire_fit_refuses_incompatible_drop", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/wire_fit_bad.flow.jsonc", .{dir}) catch return;
            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            ctx.yield(2);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }

            // The fixture pairs a `Literal` (string) with a
            // `ChangeVariable` on an `i32`. No edge in the file —
            // the test asserts the wire-fit rule the editor uses
            // (`flow_node_catalog.typesFit`) refuses string→i32, so
            // a drag of that pin pair would not commit.
            //
            // We can't synthesize a drag through the imgui-node-editor
            // primitives from TE (the create gesture requires
            // interactive input the test engine doesn't simulate).
            // The next-best regression catcher is to assert on the
            // catalog rule itself, plus confirm the file loads
            // without an edge sneaking in. A change to typesFit that
            // accidentally allowed string→i32 would fail here even
            // though the file-format tests wouldn't notice.
            const tab = &a.open_tabs.items[0].flow_doc;
            _ = zgui.te.check(@src(), .{}, tab.doc.edges.len == 0, "no edges loaded from fixture");
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("[]const u8", "i32"),
                "wire-fit refuses string → i32",
            );
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("bool", "i32"),
                "wire-fit refuses bool → i32",
            );
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("f32", "i32"),
                "wire-fit refuses f32 → i32 (precision loss)",
            );
            // O1 update: int ↔ float is now refused in *either* direction
            // — even the safe-looking `i32 → f64` requires an explicit
            // conversion node. Mirror the codegen-side contract here.
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("i32", "f32"),
                "wire-fit refuses i32 → f32 (int ↔ float requires explicit conversion)",
            );
            // Narrowing in either direction.
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("i64", "i32"),
                "wire-fit refuses i64 → i32 (narrowing)",
            );
            // Signed → unsigned drops the sign — refused.
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("i32", "u32"),
                "wire-fit refuses signed → unsigned",
            );
            // BodyId and EntityId are distinct nominal plugin types —
            // neither is `u32`-aliased, so a wire between them is refused.
            _ = zgui.te.check(
                @src(),
                .{},
                !node_catalog.typesFit("BodyId", "EntityId"),
                "wire-fit refuses BodyId → EntityId (distinct nominal types)",
            );

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "wire_fit_accepts_compatible_drop", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/wire_fit_ok.flow.jsonc", .{dir}) catch return;
            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            ctx.yield(2);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }

            // Confirm the catalog accepts the safe-widening cases the
            // RFC §2 / O1 contract names: equality, same-sign integer
            // widening, float widening, unsigned → strictly-larger
            // signed, and the `EntityId ↔ u32` alias. Int ↔ float is
            // explicitly refused (covered in the companion test) and
            // sits below.
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("i32", "i32"), "equality fits");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("i32", "i64"), "i32 → i64 widens (signed)");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("u32", "u64"), "u32 → u64 widens (unsigned)");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("f32", "f64"), "f32 → f64 widens (float)");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("u32", "i64"), "u32 → i64 widens (unsigned → strictly-larger signed)");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("EntityId", "u32"), "EntityId ↔ u32 (alias)");
            _ = zgui.te.check(@src(), .{}, node_catalog.typesFit("u32", "EntityId"), "u32 ↔ EntityId (alias)");

            const tab = &a.open_tabs.items[0].flow_doc;
            // The fixture has no edge — proves an editor save without
            // a created wire leaves the edge list untouched. (The
            // companion "incompatible" test guards the refusal path;
            // here we mostly care that the doc loads clean and the
            // catalog still accepts the cases the RFC says it should.)
            _ = zgui.te.check(@src(), .{}, tab.doc.edges.len == 0, "fixture loaded with no edges");
            _ = zgui.te.check(@src(), .{}, tab.doc.nodes.len == 2, "fixture loaded with two nodes");

            a.closeTab(0);
        }
    });

    _ = engine.registerTest("flow_vocab", "palette_excludes_raw_call_from_default", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(_: *zgui.te.TestContext) !void {
            // RFC §7: raw `Call` is *off* the default palette — it
            // surfaces only through the "Add raw call…" modal. The
            // `NodeKind` enum reflects that contract: there is no
            // canonical `.call` kind, so `Call` always falls into
            // `.other`. A regression that promoted raw Call to a
            // first-class palette button would also have to promote
            // it to a NodeKind, so this assertion catches the wider
            // surface change.
            const call_kind = flow_io.NodeKind.fromTypeName("Call");
            _ = zgui.te.check(
                @src(),
                .{},
                call_kind == .other,
                "raw Call is .other (not a first-class palette kind)",
            );

            // Spot-check the v2 palette node types are all
            // structurally-modeled — these are the labels the palette
            // button bar materialises (`+ Event`, `+ Subflow`, etc.).
            inline for (.{
                .{ "Event", flow_io.NodeKind.event },
                .{ "Subflow", flow_io.NodeKind.subflow },
                .{ "Param", flow_io.NodeKind.param },
                .{ "Output", flow_io.NodeKind.output },
                .{ "Emit", flow_io.NodeKind.emit },
                .{ "GetVariable", flow_io.NodeKind.get_variable },
                .{ "SetVariable", flow_io.NodeKind.set_variable },
                .{ "ChangeVariable", flow_io.NodeKind.change_variable },
                .{ "ClearVariable", flow_io.NodeKind.clear_variable },
                .{ "HasValueVariable", flow_io.NodeKind.has_value_variable },
                .{ "CustomNode", flow_io.NodeKind.custom_node },
            }) |pair| {
                _ = zgui.te.check(
                    @src(),
                    .{},
                    flow_io.NodeKind.fromTypeName(pair[0]) == pair[1],
                    "palette type " ++ pair[0] ++ " maps to its structural NodeKind",
                );
            }

            // `Call` and other unrecognised type names ride along as
            // `.other` and field-edit via `flow_io.otherFieldSpec`.
            // The escape-hatch dialog wires the same path — the
            // `addRawCallNode` mutator builds an `.other` node with
            // `type_name = "Call"` and stashes `callee` in extras.
            const spec = flow_io.otherFieldSpec("Call");
            _ = zgui.te.check(
                @src(),
                .{},
                spec != null,
                "Call has a field-edit spec (the escape-hatch's inspector surface)",
            );
            if (spec) |s| {
                _ = zgui.te.check(
                    @src(),
                    .{},
                    std.mem.eql(u8, s.key, "callee"),
                    "Call's edited field is `callee`",
                );
            }
        }
    });

    _ = engine.registerTest("flow_vocab", "event_node_command_visual", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // RFC §6: the Event node is a *command* — rectangular
            // silhouette, has execution-flow output. The actual visual
            // is pushed through imgui's style stack inside the
            // node-editor canvas; zgui doesn't expose a style-state
            // inspector, so a true pixel/style assertion isn't tractable
            // from TE.
            //
            // TODO(pixel/style introspection): once the zgui binding
            // gains a way to sample the per-node style state pushed
            // by the canvas renderer, replace this with a check on
            // the rounding/border color the Event node was drawn
            // with. Tracking with the catalog test below — keeping it
            // alongside the `flow_vocab` group so it lives next to the
            // surface it's about.
            //
            // For now: assert the underlying `kind` field that drives
            // the visual is preserved through load. A regression that
            // demoted Event to `.other` (the visual fall-through path)
            // would fail this check, which is the failure mode the
            // file-format tests *don't* catch.
            const dir = g_settings_project_dir.?;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;
            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            // Render at least one frame so `renderNodeBody`'s Event
            // arm runs against the loaded node. A crash in that arm
            // (e.g. event_catalog regression) would trip an assert
            // before the run callback resumes.
            ctx.yield(3);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }
            const tab = &a.open_tabs.items[0].flow_doc;

            // Find the Event node and confirm its kind survived load.
            var found_event: bool = false;
            for (tab.doc.nodes) |n| {
                if (n.kind == .event) {
                    found_event = true;
                    _ = zgui.te.check(
                        @src(),
                        .{},
                        std.mem.eql(u8, n.type_name, "Event"),
                        "Event node's type_name is canonical \"Event\"",
                    );
                }
            }
            _ = zgui.te.check(@src(), .{}, found_event, "doc carries an Event node (command-visual driver)");

            // CustomNode/box2d.apply_impulse is the canonical command
            // entry in the static catalog — a flip to `.reporter`
            // would mis-style the palette entries shipped today.
            const apply_impulse = node_catalog.lookup("box2d.apply_impulse").?;
            _ = zgui.te.check(
                @src(),
                .{},
                apply_impulse.kind == .command,
                "box2d.apply_impulse stays a command (rectangular)",
            );
            // …and a reporter from the same catalog stays a reporter,
            // so the command/reporter distinction itself isn't lost.
            const get_position = node_catalog.lookup("box2d.get_position").?;
            _ = zgui.te.check(
                @src(),
                .{},
                get_position.kind == .reporter,
                "box2d.get_position stays a reporter (rounded)",
            );

            a.closeTab(0);
        }
    });

    // Issue #172: derived execution-flow arrows on command nodes (RFC §6
    // deferral). Open the canonical `hit_counter.flow.jsonc` fixture
    // (Event + ChangeVariable, no on-disk edges), drive a few frames,
    // and assert the canvas rendered exactly one synthetic exec link —
    // the white arrow from the Event node's bottom anchor into the
    // ChangeVariable's top anchor. The count lives on
    // `FlowDocState.exec_links_last_frame`, set by `renderExecEdges`.
    _ = engine.registerTest("flow_vocab", "exec_arrow_between_event_and_change_variable", @src(), struct {
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
            const path = std.fmt.bufPrint(&path_buf, "{s}/scripts/flows/hit_counter.flow.jsonc", .{dir}) catch return;

            a.openFlowDoc(path) catch {
                _ = zgui.te.check(@src(), .{}, false, "openFlowDoc must succeed");
                return;
            };
            // Several frames so `renderCanvas` -> `renderExecEdges` has
            // run at least once after the doc finished its
            // first-frame layout pass. The counter is set fresh inside
            // every `renderExecEdges` invocation, so any post-load
            // frame is enough.
            ctx.yield(3);

            const opened_ok = a.open_tabs.items.len == 1 and a.open_tabs.items[0] == .flow_doc;
            _ = zgui.te.check(@src(), .{}, opened_ok, "flow_doc tab opened");
            if (!opened_ok) {
                a.closeTab(0);
                return;
            }
            const tab = &a.open_tabs.items[0].flow_doc;

            // The fixture has two command-kind nodes (Event +
            // ChangeVariable) and no data edges. The topo sort puts
            // them in document order (smaller id first), and the
            // synthetic exec layer connects consecutive commands — so
            // exactly one exec link is drawn.
            _ = zgui.te.check(
                @src(),
                .{},
                tab.exec_links_last_frame == 1,
                "hit_counter renders exactly one exec arrow (Event -> ChangeVariable)",
            );

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
            // pushes a `.game_view` tab AND the consumer's
            // isAttached() flips true. The tab body is gated on the
            // `.game_view` variant in `open_tabs` (rendered via
            // `OpenTab.render`), so these two together are the
            // editor-side proof that the live frame surfaces this
            // frame. The floating Module-Registry panel is NOT
            // auto-opened (#145) — it's the manual View-menu opt-in
            // surface, so `show_game_view` stays false here.
            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "consumer attached after producer detected");
            _ = zgui.te.check(@src(), .{}, !a.show_game_view, "floating Game View panel stays closed (#145 — tab is the default surface)");
            _ = zgui.te.check(@src(), .{}, countGameViewTabs(a) >= 1, "Game View tab auto-opened on attach");

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
            // #145: floating panel doesn't auto-open; the tab is the
            // default surface, and `renderViewportContent` (shared
            // with the panel) is what populates `last_latency_ns`
            // via `game_view.poll()`. The tab body renders through
            // the same path as the panel, so the live-numbers proof
            // is the latency stat, not which surface is on screen.
            _ = zgui.te.check(@src(), .{}, countGameViewTabs(a) >= 1, "Game View tab open so Stats area shows live numbers");
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

    // ── iosurface dispatch (macOS-only) ────────────────────────────
    //
    // Asserts the format-dispatch wiring: when the engine emits
    // `format = "iosurface_bgra8"`, App.attachGameView opens an
    // `iosurface.Consumer` (not a `shm.Consumer`), allocates the
    // rectangle textures + FBOs, and the per-frame FBO blit fills the
    // GL_TEXTURE_2D that imgui samples. On non-macOS hosts the engine
    // producer returns `error.PlatformUnsupported` at init, so this
    // test skips cleanly.
    _ = engine.registerTest("pie", "viewport/iosurface_dispatch", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            if (builtin.os.tag != .macos) {
                _ = zgui.te.check(@src(), .{}, true, "iosurface path is macOS-only — skipped");
                return;
            }
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            pieIosStart(64, 64) catch |err| {
                // CFAllocationFailed / IOSurfaceCreateFailed can happen
                // under sandboxes that disable IOSurface — treat as a
                // skip rather than a failure so CI on locked-down
                // runners doesn't break.
                std.log.warn("iosurface producer init failed: {s} — skipping", .{@errorName(err)});
                _ = zgui.te.check(@src(), .{}, true, "iosurface producer unavailable on this host");
                return;
            };
            defer pieIosStop();
            ctx.yield(2); // service the deferred attach (GL work).

            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "iosurface consumer attached");
            // #145: tab is the auto-open surface; floating panel stays closed.
            _ = zgui.te.check(@src(), .{}, countGameViewTabs(a) >= 1, "Game View tab opened on iosurface attach");
            _ = zgui.te.check(@src(), .{}, !a.show_game_view, "floating panel not auto-opened on iosurface attach (#145)");
            // Rectangle textures + draw FBO only exist in iosurface
            // mode — they're the smoking gun that we took the right
            // dispatch branch.
            _ = zgui.te.check(@src(), .{}, a.game_view.rect_count > 0, "rectangle textures allocated for iosurface ring");
            _ = zgui.te.check(@src(), .{}, a.game_view.draw_fbo != 0, "draw FBO allocated for iosurface blit");
            _ = zgui.te.check(@src(), .{}, a.game_view.tex_id != 0, "destination GL_TEXTURE_2D allocated");

            // Drive a handful of publishes; assert frame_idx advances
            // through the FBO blit (i.e. `poll()` walked the iosurface
            // branch and reached `recordFrameStats`).
            var prev_idx: ?u64 = null;
            var saw_increase: bool = false;
            var i: usize = 0;
            while (i < 20) : (i += 1) {
                _ = pieIosPublish(@intCast(i & 0xFF));
                ctx.yield(1);
                const cur = a.game_view.last_frame_idx orelse continue;
                if (prev_idx) |p| {
                    if (cur > p) saw_increase = true;
                }
                prev_idx = cur;
            }
            _ = zgui.te.check(@src(), .{}, prev_idx != null, "iosurface consumer saw at least one frame");
            _ = zgui.te.check(@src(), .{}, saw_increase, "iosurface frame_idx advanced across the window");
            _ = zgui.te.check(@src(), .{}, a.game_view.last_latency_ns > 0, "iosurface latency stat populated");

            // Detach explicitly so the next test starts from clean
            // GL state. detach() runs on the gui (GL) thread.
            g_pie_pending_detach = true;
            ctx.yield(2);
            _ = zgui.te.check(@src(), .{}, !a.game_view.isAttached(), "iosurface consumer detached cleanly");
            _ = zgui.te.check(@src(), .{}, a.game_view.rect_count == 0, "rectangle textures freed on detach");
            _ = zgui.te.check(@src(), .{}, a.game_view.draw_fbo == 0, "draw FBO freed on detach");
        }
    });

    // ── Game View tab (#128) ───────────────────────────────────────
    //
    // `attachGameView` now pushes an `OpenTab.game_view` entry onto
    // `open_tabs` (in addition to the legacy `show_game_view` panel
    // toggle) so the live frame surfaces inside the main content
    // area's TabBar. Closing the tab eagerly stops the preview
    // subprocess + detaches the consumer.
    //
    // The actual `closeTab` invocation has to land on the gui (GL)
    // thread because the `.game_view` arm calls `game_view.detach()`
    // which deletes GL textures. The pattern matches the existing
    // PIE viewport tests: set a flag on the run thread, service it
    // on the gui-callback frame.
    _ = engine.registerTest("pie", "tab/opens_on_attach", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            if (g_app) |a| a.renderFrame(1.0 / 60.0);
        }
        pub fn run(ctx: *zgui.te.TestContext) !void {
            const a = g_app orelse {
                _ = zgui.te.check(@src(), .{}, false, "g_app must be set");
                return;
            };

            // Earlier PIE viewport tests may have attached + detached
            // the consumer, which under #128 also pushes a `.game_view`
            // tab onto `open_tabs`. The tab persists after detach
            // (close-on-detach would be wrong: detach is normal during
            // resize). Count `.game_view` tabs as the invariant, not
            // total tab length, so this test stays robust to leftover
            // tabs.
            const game_view_tabs_before = countGameViewTabs(a);

            piePreviewStart(64, 64) catch {
                _ = zgui.te.check(@src(), .{}, false, "piePreviewStart must succeed");
                return;
            };
            defer piePreviewStop();
            ctx.yield(2);

            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "consumer attached");
            const expected_tabs: usize = if (game_view_tabs_before == 0) 1 else game_view_tabs_before;
            _ = zgui.te.check(@src(), .{}, countGameViewTabs(a) == expected_tabs, "exactly one .game_view tab present (new or refocused)");

            // Re-attach with the same name should refocus, not
            // duplicate. attach() inside game_view.attach auto-detaches
            // first — that's GL work, so route via the pending flag.
            g_pie_pending_attach = true;
            ctx.yield(2);
            _ = zgui.te.check(@src(), .{}, countGameViewTabs(a) == expected_tabs, "re-attach refocuses instead of duplicating");

            // Cleanup: tear down via the detach flag (GL work) so the
            // next test starts clean. The .game_view tab will still be
            // present in open_tabs after detach; the close-stops-preview
            // test below exercises the close path.
            g_pie_pending_detach = true;
            ctx.yield(2);
        }
    });

    _ = engine.registerTest("pie", "tab/close_stops_preview", @src(), struct {
        pub fn gui(_: *zgui.te.TestContext) !void {
            pieServicePending();
            // closeTab's .game_view arm runs game_view.detach (GL
            // work) — service it here, on the GL thread, when the
            // run callback flags an outstanding close request.
            if (g_pending_game_view_close) {
                g_pending_game_view_close = false;
                if (g_app) |a| {
                    var i: usize = 0;
                    while (i < a.open_tabs.items.len) {
                        switch (a.open_tabs.items[i]) {
                            .game_view => {
                                a.closeTab(i);
                                break;
                            },
                            else => i += 1,
                        }
                    }
                }
            }
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
            ctx.yield(2);

            // Pre-close sanity.
            _ = zgui.te.check(@src(), .{}, a.game_view.isAttached(), "consumer attached pre-close");
            var found_pre: bool = false;
            for (a.open_tabs.items) |t| switch (t) {
                .game_view => {
                    found_pre = true;
                    break;
                },
                else => {},
            };
            _ = zgui.te.check(@src(), .{}, found_pre, "game_view tab present pre-close");

            // Drive the production close path through the gui frame
            // so detach() lands on the GL thread.
            g_pending_game_view_close = true;
            ctx.yield(2);

            _ = zgui.te.check(@src(), .{}, !a.game_view.isAttached(), "consumer detached on tab close");
            _ = zgui.te.check(@src(), .{}, !a.show_game_view, "floating panel stays closed across tab close (#145)");
            _ = zgui.te.check(@src(), .{}, !a.preview.isActive(), "preview reports inactive after stop()");

            // No .game_view tab remains. Other test-leftover tabs
            // (scene, prefab) are out of scope here.
            var still_there: bool = false;
            for (a.open_tabs.items) |t| switch (t) {
                .game_view => {
                    still_there = true;
                    break;
                },
                else => {},
            };
            _ = zgui.te.check(@src(), .{}, !still_there, "no .game_view tab remains after closeTab");
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
