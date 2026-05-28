const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const compiler = @import("compiler.zig");
const new_scene = @import("dialogs/new_scene.zig");
const scene_io = @import("scene_io.zig");
const scene_module = @import("modules/scene.zig");
const project_tree = @import("modules/project_tree.zig");
const viewport = @import("modules/viewport.zig");
const atlas = @import("atlas.zig");
const gizmo_io = @import("gizmo_io.zig");
const flow_io = @import("flow_io.zig");
const flow_doc = @import("modules/flow_doc.zig");
const flow_cycle = @import("flow_cycle.zig");
const event_catalog = @import("flow_event_catalog.zig");
const node_catalog = @import("flow_node_catalog.zig");

// Reference the node catalog at file scope so its module-level
// `test "…"` blocks become reachable from the test root and are
// included in `builtin.test_functions`. `@import` alone isn't always
// enough — the Zig test discovery only walks decls that are *used*.
comptime {
    _ = node_catalog;
}
const gizmos = @import("gizmos.zig");
const preview = @import("preview.zig");
const flow_projector = @import("flows/projector.zig");
const flow_types = @import("flows/types.zig");
const flow_reveal = @import("flows/reveal.zig");
const prefs = @import("prefs.zig");
const prefab_contents = @import("modules/inspector/prefab_contents.zig");
const io_global = @import("io_global.zig");
const game_view = @import("game_view.zig");
const test_fixtures = @import("test_fixtures.zig");
const dnd = @import("modules/dnd.zig");
const prefab_index = @import("prefab_index.zig");
const splitter = @import("modules/splitter.zig");

/// Wall-clock seconds since the Unix epoch; replacement for the
/// `std.time.timestamp` helper removed in Zig 0.16. Used only to
/// generate unique scratch directory names in tests.
fn timestampSeconds() i64 {
    const native_os = @import("builtin").os.tag;
    switch (native_os) {
        .windows => {
            var ft: std.os.windows.FILETIME = undefined;
            std.os.windows.kernel32.GetSystemTimeAsFileTime(&ft);
            const ticks: i64 = (@as(i64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
            const unix_epoch_offset: i64 = 11644473600;
            return @divTrunc(ticks, 10_000_000) - unix_epoch_offset;
        },
        else => {
            var ts: std.posix.timespec = undefined;
            _ = std.posix.system.clock_gettime(.REALTIME, &ts);
            return ts.sec;
        },
    }
}

test {
    zspec.runAll(@This());
}

// Global beforeAll hook for zspec — fires once before the first test
// of any scope (zspec's hookAppliesToTest matches on prefix, and every
// scope in this file starts with "tests").
//
// Initializes `std.testing.io_instance`. In Zig 0.16, `std.testing.io`
// is `const io = io_instance.io()` (testing.zig:34-35) — the `io()`
// method bakes `&io_instance` into the returned Io's `userdata` at
// comptime. With no runtime init, the global memory at that address
// stays zero-initialized — `worker_threads = null`, etc. — and every
// operation that needs the thread pool (createDirPathOpen for nested
// cache dirs, realpath, file-not-found readFileAlloc, writes under a
// tmpDir) deadlocks on Linux. macOS lets more zero-init paths through.
//
// The stdlib's own terminal runner (lib/compiler/test_runner.zig:273-282)
// does `testing.io_instance = .init(testing.allocator, .{...})` before
// every test. zspec's `mode: .simple` runner skips that, so we do it
// once at the top-level scope. Same memory address, just now actually
// initialized — the `.userdata` pointers baked at comptime now point
// at a Threaded with a real worker pool. See discussion in
// codeberg ziglang/zig#31718 for the related Io.Threaded poll issue.
test "tests:beforeAll" {
    std.testing.io_instance = .init(std.testing.allocator, .{});
}

pub const ProjectConfigTests = struct {
    test "defaults to raylib backend" {
        const cfg = project.ProjectConfig{ .name = "test" };
        try expect.equal(cfg.backend, .raylib);
    }

    test "defaults to zig_ecs" {
        const cfg = project.ProjectConfig{ .name = "test" };
        try expect.equal(cfg.ecs, .zig_ecs);
    }

    test "defaults to 800x600 at 60fps" {
        const cfg = project.ProjectConfig{ .name = "test" };
        try expect.equal(cfg.width, 800);
        try expect.equal(cfg.height, 600);
        try expect.equal(cfg.target_fps, 60);
    }

    test "defaults initial_scene to main" {
        const cfg = project.ProjectConfig{ .name = "test" };
        try expect.toBeTrue(std.mem.eql(u8, cfg.initial_scene, "main"));
    }
};

pub const ProjectFoldersTests = struct {
    fn containsFolder(name: []const u8) bool {
        for (project.ProjectFolders.all) |folder| {
            if (std.mem.eql(u8, folder, name)) return true;
        }
        return false;
    }

    test "has 9 default folders" {
        try expect.equal(project.ProjectFolders.all.len, 9);
    }

    test "contains assets folder" {
        try expect.toBeTrue(containsFolder("assets"));
    }

    test "contains components folder" {
        try expect.toBeTrue(containsFolder("components"));
    }

    test "contains fixtures folder" {
        try expect.toBeTrue(containsFolder("fixtures"));
    }

    test "contains gizmos folder" {
        try expect.toBeTrue(containsFolder("gizmos"));
    }

    test "contains prefabs folder" {
        try expect.toBeTrue(containsFolder("prefabs"));
    }

    test "contains scenes folder" {
        try expect.toBeTrue(containsFolder("scenes"));
    }

    test "contains scripts folder" {
        try expect.toBeTrue(containsFolder("scripts"));
    }

    test "contains scripts/flows folder" {
        try expect.toBeTrue(containsFolder("scripts/flows"));
    }

    test "contains resources folder" {
        try expect.toBeTrue(containsFolder("resources"));
    }
};

pub const ProjectTests = struct {
    test "can be created with a name" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "TestProject");
        defer proj.deinit();

        try expect.toBeTrue(std.mem.eql(u8, proj.config.name, "TestProject"));
    }

    test "is marked dirty on creation" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "TestProject");
        defer proj.deinit();

        try expect.toBeTrue(proj.is_dirty);
    }

    test "has no dir on creation" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "TestProject");
        defer proj.deinit();

        try expect.toBeTrue(proj.dir == null);
    }
};

pub const ProjectManagerTests = struct {
    test "starts with no project" {
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try expect.toBeTrue(pm.current_project == null);
    }

    test "can create new project" {
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("NewProject");

        try expect.toBeTrue(pm.current_project != null);
    }

    test "can close project" {
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("NewProject");
        pm.closeProject();

        try expect.toBeTrue(pm.current_project == null);
    }

    test "reports no unsaved changes when no project" {
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try expect.toBeFalse(pm.hasUnsavedChanges());
    }

    test "generation increments on new / close / reopen" {
        // Regression: cursor[bot] flagged that pointer-identity
        // comparison can ABA across project close/new cycles when
        // GeneralPurposeAllocator reuses the same address. Modules
        // track ProjectManager.generation instead, which must bump on
        // every transition.
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try expect.equal(pm.generation, 0);

        try pm.newProject("a");
        try expect.equal(pm.generation, 1);

        pm.closeProject();
        try expect.equal(pm.generation, 2);

        try pm.newProject("b");
        try expect.equal(pm.generation, 3);

        // closeProject on an already-empty manager is a no-op and must
        // not bump.
        pm.closeProject(); // closes "b" → gen 4
        pm.closeProject(); // no-op, still gen 4
        try expect.equal(pm.generation, 4);
    }

    test "reports unsaved changes for new project" {
        const allocator = std.testing.allocator;
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("NewProject");

        try expect.toBeTrue(pm.hasUnsavedChanges());
    }
};

pub const ConstantsTests = struct {
    test "PROJECT_FILENAME is project.labelle" {
        try expect.toBeTrue(std.mem.eql(u8, project.PROJECT_FILENAME, "project.labelle"));
    }
};

pub const FolderIconsTests = struct {
    test "folder constant is FA_FOLDER glyph" {
        try expect.toBeTrue(std.mem.eql(u8, tree_view.FolderIcons.folder, "\u{f07b}"));
    }

    test "file constant is FA_FILE glyph" {
        try expect.toBeTrue(std.mem.eql(u8, tree_view.FolderIcons.file, "\u{f15b}"));
    }
};

pub const TreeViewTests = struct {
    test "initializes with no selected path" {
        const allocator = std.testing.allocator;
        var tv = tree_view.TreeView.init(allocator);
        defer tv.deinit();

        try expect.toBeTrue(tv.getSelectedPath() == null);
    }

    test "initializes needing refresh" {
        const allocator = std.testing.allocator;
        var tv = tree_view.TreeView.init(allocator);
        defer tv.deinit();

        try expect.toBeTrue(tv.needs_refresh);
    }

    test "refresh sets needs_refresh flag" {
        const allocator = std.testing.allocator;
        var tv = tree_view.TreeView.init(allocator);
        defer tv.deinit();

        tv.needs_refresh = false;
        tv.refresh();

        try expect.toBeTrue(tv.needs_refresh);
    }
};

pub const CompilerTests = struct {
    test "initializes in idle state" {
        const allocator = std.testing.allocator;
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try expect.equal(comp.getState(), .idle);
    }

    test "isIdle returns true for idle state" {
        const allocator = std.testing.allocator;
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try expect.toBeTrue(comp.isIdle());
    }

    test "has no last result initially" {
        const allocator = std.testing.allocator;
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try expect.toBeTrue(comp.last_result == null);
    }

    test "has no build process initially" {
        const allocator = std.testing.allocator;
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try expect.toBeFalse(comp.has_pending_result);
    }
};

pub const CompilerStateTests = struct {
    test "idle state is initial state" {
        try expect.equal(@intFromEnum(compiler.CompilerState.idle), 0);
    }

    test "all states are distinct" {
        try expect.notEqual(@intFromEnum(compiler.CompilerState.idle), @intFromEnum(compiler.CompilerState.generating));
        try expect.notEqual(@intFromEnum(compiler.CompilerState.generating), @intFromEnum(compiler.CompilerState.building));
        try expect.notEqual(@intFromEnum(compiler.CompilerState.building), @intFromEnum(compiler.CompilerState.running));
        try expect.notEqual(@intFromEnum(compiler.CompilerState.running), @intFromEnum(compiler.CompilerState.failed));
        try expect.notEqual(@intFromEnum(compiler.CompilerState.failed), @intFromEnum(compiler.CompilerState.success));
    }
};

/// End-to-end tests for save → load → folder scaffold of the assembler-compatible
/// `project.labelle` file. These do real filesystem work in /tmp.
pub const SceneIoTests = struct {
    test "parses a minimal scene" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "main",
            \\    "entities": []
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(std.mem.eql(u8, loaded.scene.name, "main"));
        try expect.equal(loaded.scene.entities.len, 0);
    }

    test "extracts prefab + Position from entities" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "prefab": "wall", "components": { "Position": { "x": 100, "y": 200 } } },
            \\        { "components": { "Position": { "x": 50, "y": 75 }, "Sprite": { "sprite_name": "coin" } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.scene.entities.len, 2);

        try expect.toBeTrue(loaded.scene.entities[0].prefab != null);
        try expect.toBeTrue(std.mem.eql(u8, loaded.scene.entities[0].prefab.?, "wall"));
        try expect.toBeTrue(loaded.scene.entities[0].position != null);
        try expect.equal(loaded.scene.entities[0].position.?.x, 100);
        try expect.equal(loaded.scene.entities[0].position.?.y, 200);

        // Second entity: no prefab, but Position present alongside an
        // unmodeled Sprite component — both must parse without errors.
        try expect.toBeTrue(loaded.scene.entities[1].prefab == null);
        try expect.toBeTrue(loaded.scene.entities[1].position != null);
        try expect.equal(loaded.scene.entities[1].position.?.x, 50);
    }

    test "stripLineComments leaves // inside string literals alone" {
        // Regression: a URL like "https://example.com" must survive
        // intact. Naive `//` replacement would mangle it.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "prefab": "wall", "components": { "Position": { "x": 0, "y": 0 } }, "url": "https://labelle.games/docs" }
            \\    ]
            \\}
        ;
        const stripped = try scene_io.stripLineComments(allocator, src);
        defer allocator.free(stripped);
        try expect.toBeTrue(std.mem.indexOf(u8, stripped, "https://labelle.games/docs") != null);
    }

    test "stripLineComments respects escape sequences" {
        // A backslash-escaped quote inside a string must NOT close the
        // string, so a following `//` stays inside the literal.
        const allocator = std.testing.allocator;
        const src = "{ \"k\": \"\\\"//not-a-comment\" }";
        const stripped = try scene_io.stripLineComments(allocator, src);
        defer allocator.free(stripped);
        try expect.toBeTrue(std.mem.indexOf(u8, stripped, "//not-a-comment") != null);
    }

    test "tolerates // line comments" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    // top-level comment
            \\    "name": "commented",
            \\    "entities": [
            \\        // entity below
            \\        { "prefab": "p" }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(std.mem.eql(u8, loaded.scene.name, "commented"));
        try expect.equal(loaded.scene.entities.len, 1);
    }

    test "extracts leading // comments per entity" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        // Walls — red rectangles
            \\        { "prefab": "wall", "components": { "Position": { "x": 100, "y": 100 } } },
            \\        { "prefab": "wall", "components": { "Position": { "x": 200, "y": 200 } } },
            \\        // Player — blue square
            \\        { "prefab": "player", "components": { "Position": { "x": 50, "y": 50 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.scene.entities.len, 3);

        const c0 = std.mem.sliceTo(&loaded.scene.entities[0].comment, 0);
        const c1 = std.mem.sliceTo(&loaded.scene.entities[1].comment, 0);
        const c2 = std.mem.sliceTo(&loaded.scene.entities[2].comment, 0);

        try expect.toBeTrue(std.mem.indexOf(u8, c0, "Walls") != null);
        try expect.equal(c1.len, 0);
        try expect.toBeTrue(std.mem.indexOf(u8, c2, "Player") != null);
    }

    test "ignores false 'entities' literal before the real key" {
        // Regression: a value containing the literal string `"entities"`
        // must not stop the scanner from finding the real `entities: [`
        // later in the document.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "tag": "entities",
            \\    "name": "x",
            \\    "entities": [
            \\        // comment
            \\        { "prefab": "p" }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.scene.entities.len, 1);
        const c = std.mem.sliceTo(&loaded.scene.entities[0].comment, 0);
        try expect.toBeTrue(std.mem.indexOf(u8, c, "comment") != null);
    }

    test "multi-line comment block attaches as one string" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        // line 1
            \\        // line 2
            \\        // line 3
            \\        { "prefab": "obj" }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        const c = std.mem.sliceTo(&loaded.scene.entities[0].comment, 0);
        try expect.toBeTrue(std.mem.indexOf(u8, c, "line 1") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, c, "line 3") != null);
    }

    test "renderSceneJsonc round-trips Sprite + Shape components verbatim" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "lab",
            \\    "entities": [
            \\        // Collectible
            \\        {
            \\            "prefab": "coin",
            \\            "components": {
            \\                "Position": { "x": 100, "y": 200 },
            \\                "Sprite": { "sprite_name": "coin", "pivot": "center" },
            \\                "Coin": {}
            \\            }
            \\        }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);

        // Managed fields landed in canonical form.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"name\": \"lab\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"prefab\": \"coin\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Position\":") != null);

        // Unmodeled components round-tripped verbatim.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Sprite\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"coin\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Coin\":") != null);

        // Comment preserved at the entities-array indent.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "// Collectible") != null);
    }

    test "renderSceneJsonc reflects in-memory Position edits" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "prefab": "p", "components": { "Position": { "x": 0, "y": 0 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        loaded.scene.entities[0].position.?.x = 999;
        loaded.scene.entities[0].position.?.y = 42;

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);

        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 999") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"y\": 42") != null);
        // Old zero values must not appear (would mean the writer ignored
        // the in-memory edit and re-emitted the original).
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 0,") == null);
    }

    test "renderSceneJsonc preserves top-level include" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "main",
            \\    "include": ["scenes/obstacles.jsonc", "scenes/extras.jsonc"],
            \\    "entities": []
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"include\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "scenes/obstacles.jsonc") != null);
    }

    test "Sprite component round-trips with all four typed fields" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "components": { "Position": { "x": 0, "y": 0 }, "Sprite": { "sprite_name": "coin", "pivot": "center", "layer": "world", "z_index": -5 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        const sprite = loaded.scene.entities[0].sprite orelse return error.MissingSprite;
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&sprite.sprite_name, 0), "coin"));
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&sprite.pivot, 0), "center"));
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&sprite.layer, 0), "world"));
        try expect.toBeTrue(sprite.has_z_index);
        try expect.equal(sprite.z_index, -5);

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"coin\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"pivot\": \"center\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"layer\": \"world\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"z_index\": -5") != null);
    }

    test "Rectangle round-trips with all fields through a prefab" {
        // Geometry slice 1 (issue #6): a prefab carrying a Rectangle
        // component must parse into the typed model with every field
        // populated, and the writer must emit it back in the same
        // shape — width/height as numbers, color as nested object,
        // filled as bool.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Rectangle": { "width": 32, "height": 18, "color": { "r": 200, "g": 50, "b": 25, "a": 240 }, "filled": false }
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        const rect = loaded.entity.rectangle orelse return error.MissingRectangle;
        try expect.equal(rect.width, 32);
        try expect.equal(rect.height, 18);
        try expect.equal(rect.r, 200);
        try expect.equal(rect.g, 50);
        try expect.equal(rect.b, 25);
        try expect.equal(rect.a, 240);
        try expect.toBeFalse(rect.filled);

        // Rectangle is managed → must NOT end up in component_extras.
        try expect.equal(loaded.component_extras.len, 0);

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Rectangle\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"width\": 32") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 200") != null);

        // Re-parse the rendered output — same shape, same values.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        const rect2 = loaded2.entity.rectangle orelse return error.MissingRectangle;
        try expect.equal(rect2.width, 32);
        try expect.equal(rect2.b, 25);
        try expect.toBeFalse(rect2.filled);
    }

    test "Rectangle alongside Sprite and Position on a scene entity" {
        // Multiple managed components on the same entity must all
        // round-trip; none of them should leak into component_extras.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        {
            \\            "components": {
            \\                "Position": { "x": 10, "y": 20 },
            \\                "Sprite": { "sprite_name": "coin" },
            \\                "Rectangle": { "width": 64, "height": 64, "color": { "r": 0, "g": 0, "b": 255, "a": 255 }, "filled": true }
            \\            }
            \\        }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const e = &loaded.scene.entities[0];
        try expect.toBeTrue(e.position != null);
        try expect.toBeTrue(e.sprite != null);
        try expect.toBeTrue(e.rectangle != null);
        try expect.equal(loaded.extras.entity_components[0].len, 0);
        try expect.equal(e.rectangle.?.b, 255);
    }

    test "edit Rectangle in memory; saved output reflects it" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Rectangle": { "width": 0, "height": 0, "color": { "r": 0, "g": 0, "b": 0, "a": 0 }, "filled": true } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        const rect = loaded.entity.rectangle orelse return error.MissingRectangle;
        rect.width = 99;
        rect.r = 128;
        rect.filled = false;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"width\": 99") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 128") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
    }

    test "Circle round-trips with all fields through a prefab" {
        // Geometry slice 2 (issue #6): a prefab carrying a Circle
        // component must parse into the typed model with every field
        // populated, and the writer must emit it back in the same
        // shape — radius as number, color as nested object, filled
        // as bool.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Circle": { "radius": 24, "color": { "r": 200, "g": 50, "b": 25, "a": 240 }, "filled": false }
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        const circle = loaded.entity.circle orelse return error.MissingCircle;
        try expect.equal(circle.radius, 24);
        try expect.equal(circle.r, 200);
        try expect.equal(circle.g, 50);
        try expect.equal(circle.b, 25);
        try expect.equal(circle.a, 240);
        try expect.toBeFalse(circle.filled);

        // Circle is managed → must NOT end up in component_extras.
        try expect.equal(loaded.component_extras.len, 0);

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Circle\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"radius\": 24") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 200") != null);

        // Re-parse the rendered output — same shape, same values.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        const circle2 = loaded2.entity.circle orelse return error.MissingCircle;
        try expect.equal(circle2.radius, 24);
        try expect.equal(circle2.b, 25);
        try expect.toBeFalse(circle2.filled);
    }

    test "Circle alongside Sprite and Position on a scene entity" {
        // Multiple managed components on the same entity must all
        // round-trip; none of them should leak into component_extras.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        {
            \\            "components": {
            \\                "Position": { "x": 10, "y": 20 },
            \\                "Sprite": { "sprite_name": "coin" },
            \\                "Circle": { "radius": 12, "color": { "r": 0, "g": 0, "b": 255, "a": 255 }, "filled": true }
            \\            }
            \\        }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const e = &loaded.scene.entities[0];
        try expect.toBeTrue(e.position != null);
        try expect.toBeTrue(e.sprite != null);
        try expect.toBeTrue(e.circle != null);
        try expect.equal(loaded.extras.entity_components[0].len, 0);
        try expect.equal(e.circle.?.b, 255);
    }

    test "edit Circle in memory; saved output reflects it" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Circle": { "radius": 0, "color": { "r": 0, "g": 0, "b": 0, "a": 0 }, "filled": true } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        const circle = loaded.entity.circle orelse return error.MissingCircle;
        circle.radius = 99;
        circle.r = 128;
        circle.filled = false;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"radius\": 99") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 128") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
    }

    test "Sprite string fields are JSON-escaped on emit" {
        // Regression for gemini PR #32 review: sprite_name/pivot/layer
        // come from inspector text buffers and may contain `"` or `\`.
        // The writer must escape them so the rendered .jsonc stays
        // parseable.
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Sprite": { "sprite_name": "x" } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        const sprite = loaded.entity.sprite orelse return error.MissingSprite;

        // Stuff a hostile name (quote + backslash) into the buffer.
        @memset(&sprite.sprite_name, 0);
        const hostile = "weird\"\\name";
        @memcpy(sprite.sprite_name[0..hostile.len], hostile);

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);

        // Output must escape both bytes — the resulting file must
        // re-parse cleanly through the same path.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\\\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\\\\") != null);

        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        const sprite2 = loaded2.entity.sprite orelse return error.MissingSprite;
        const name2 = std.mem.sliceTo(&sprite2.sprite_name, 0);
        try expect.toBeTrue(std.mem.eql(u8, name2, hostile));
    }

    test "edit Sprite.sprite_name in memory; saved output reflects it" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Sprite": { "sprite_name": "old" } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        // In-place edit via the inspector's path (mutate the buffer).
        const sprite = loaded.entity.sprite orelse return error.MissingSprite;
        @memset(&sprite.sprite_name, 0);
        const new_name = "new";
        @memcpy(sprite.sprite_name[0..new_name.len], new_name);

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"new\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"old\"") == null);
    }

    test "entity without Sprite component leaves sprite null" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Coin": {} } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(loaded.entity.sprite == null);
    }

    test "renderSceneJsonc output re-parses cleanly" {
        // End-to-end: scene → render → re-parse → render again
        // should give us the same managed state plus the same extras.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        // c
            \\        { "prefab": "p", "components": { "Position": { "x": 1, "y": 2 }, "Sprite": { "sprite_name": "s" } } }
            \\    ]
            \\}
        ;
        var loaded1 = try scene_io.parseScene(allocator, src);
        defer loaded1.deinit();
        const t1 = try scene_io.renderSceneJsonc(allocator, loaded1);
        defer allocator.free(t1);

        var loaded2 = try scene_io.parseScene(allocator, t1);
        defer loaded2.deinit();
        try expect.equal(loaded2.scene.entities.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded2.scene.entities[0].prefab.?, "p"));
        try expect.equal(loaded2.scene.entities[0].position.?.x, 1);
        try expect.equal(loaded2.scene.entities[0].position.?.y, 2);
        // Sprite is typed now, so it's read out of the entity, not
        // captured in extras. Entity should carry the typed Sprite
        // with `sprite_name` round-tripped from the source.
        try expect.equal(loaded2.extras.entity_components[0].len, 0);
        try expect.toBeTrue(loaded2.scene.entities[0].sprite != null);
        const sprite_name = std.mem.sliceTo(&loaded2.scene.entities[0].sprite.?.sprite_name, 0);
        try expect.toBeTrue(std.mem.eql(u8, sprite_name, "s"));
    }

    test "parsePrefab reads Position + extras from a prefab body" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Position": { "x": 5, "y": 10 },
            \\        "Sprite": { "sprite_name": "coin", "pivot": "center" },
            \\        "Coin": {}
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(loaded.entity.position != null);
        try expect.equal(loaded.entity.position.?.x, 5);
        try expect.equal(loaded.entity.position.?.y, 10);
        // Sprite is typed (issue #31 slice 1) so it lives on
        // entity.sprite, not in extras. Coin remains an unmodeled
        // extra.
        try expect.equal(loaded.component_extras.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded.component_extras[0].name, "Coin"));
        try expect.toBeTrue(loaded.entity.sprite != null);
        const sn = std.mem.sliceTo(&loaded.entity.sprite.?.sprite_name, 0);
        const pv = std.mem.sliceTo(&loaded.entity.sprite.?.pivot, 0);
        try expect.toBeTrue(std.mem.eql(u8, sn, "coin"));
        try expect.toBeTrue(std.mem.eql(u8, pv, "center"));
    }

    test "renderPrefabJsonc round-trips a prefab with extras" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Sprite": { "sprite_name": "coin" },
            \\        "Coin": {}
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);

        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"components\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Sprite\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"coin\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Coin\"") != null);

        // Re-parse the rendered text to confirm the writer's output
        // is self-consistent — Sprite back on entity.sprite, Coin
        // back in extras.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.component_extras.len, 1);
        try expect.toBeTrue(loaded2.entity.sprite != null);
    }

    test "parsePrefab reads children with positions and extras" {
        // hydroponics-style: prefab body + a children array whose
        // entries each have a Position and a Sprite. Position is
        // modeled; Sprite rides along as a component extra.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Room": { "room_type": "hydroponics" }
            \\    },
            \\    "children": [
            \\        // Room background
            \\        {
            \\            "components": {
            \\                "Sprite": { "sprite_name": "bg.png" },
            \\                "Position": { "x": 15, "y": 0 }
            \\            }
            \\        },
            \\        // Pots
            \\        {
            \\            "components": {
            \\                "Sprite": { "sprite_name": "pots.png" },
            \\                "Position": { "x": 39, "y": 12 }
            \\            }
            \\        }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.children.len, 2);
        try expect.equal(loaded.children[0].position.?.x, 15);
        try expect.equal(loaded.children[1].position.?.y, 12);

        // Sprite is typed now (#31 slice 1) — sits on
        // child.sprite, not in children_extras.
        try expect.equal(loaded.children_extras.len, 2);
        try expect.equal(loaded.children_extras[0].len, 0);
        try expect.toBeTrue(loaded.children[0].sprite != null);
        const sn = std.mem.sliceTo(&loaded.children[0].sprite.?.sprite_name, 0);
        try expect.toBeTrue(std.mem.eql(u8, sn, "bg.png"));

        // Leading // comments ride along with the child they precede.
        const c0 = std.mem.sliceTo(&loaded.children[0].comment, 0);
        const c1 = std.mem.sliceTo(&loaded.children[1].comment, 0);
        try expect.toBeTrue(std.mem.indexOf(u8, c0, "background") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, c1, "Pots") != null);
    }

    test "renderPrefabJsonc round-trips children + extras" {
        // Uses real Sprite fields (sprite_name) since the typed
        // model only round-trips the four canonical fields; unmodeled
        // sub-fields like `n` would be silently dropped (#31 follow-up).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": { "Room": { "room_type": "x" } },
            \\    "children": [
            \\        { "components": { "Sprite": { "sprite_name": "a" }, "Position": { "x": 1, "y": 2 } } },
            \\        { "components": { "Sprite": { "sprite_name": "b" }, "Position": { "x": 3, "y": 4 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        // Move child 0; expect the output to reflect the new position
        // AND preserve Sprite on both children.
        loaded.children[0].position.?.x = 99;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);

        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"children\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 99") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"a\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"sprite_name\": \"b\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Room\":") != null);

        // Re-parse the rendered text — same shape, same children
        // count, edited Position preserved.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.children.len, 2);
        try expect.equal(loaded2.children[0].position.?.x, 99);
    }

    test "parsePrefab preserves unmodeled top-level keys verbatim" {
        // Regression for copilot PR #30 review: a prefab with custom
        // top-level keys (metadata, schema_version, anything outside
        // `components` / `children`) must round-trip those fields
        // unchanged. Without this, editing+saving a prefab would
        // silently drop everything the gui doesn't model.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": { "Coin": {} },
            \\    "metadata": { "author": "alex", "tags": ["currency", "pickup"] },
            \\    "schema_version": 3
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        try expect.equal(loaded.top_level_extras.len, 2);
        try expect.toBeTrue(std.mem.eql(u8, loaded.top_level_extras[0].name, "metadata"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.top_level_extras[1].name, "schema_version"));

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);

        // Both extras must reappear in the output…
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"metadata\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"author\": \"alex\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"schema_version\": 3") != null);
        // …and the output must re-parse cleanly, with the same
        // extras captured the second time.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.top_level_extras.len, 2);
    }

    test "parsePrefab captures extras when file has leading whitespace + comment" {
        // Regression for cursor[bot] PR #30 review: findKeyObject
        // used to bail when the body didn't start with `{` (because
        // it only consumed an outer brace right at position 0).
        // Prefabs whose source had a header comment or leading
        // whitespace silently produced empty extras → all non-
        // Position components got dropped on save.
        const allocator = std.testing.allocator;
        const src =
            \\// header comment
            \\
            \\{
            \\    "components": {
            \\        "Sprite": { "sprite_name": "x" },
            \\        "Coin": {}
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        // Sprite typed → on entity. Coin unmodeled → still in extras.
        try expect.equal(loaded.component_extras.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded.component_extras[0].name, "Coin"));
        try expect.toBeTrue(loaded.entity.sprite != null);
    }

    test "renderPrefabJsonc reflects in-memory Position edits" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Position": { "x": 0, "y": 0 } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        loaded.entity.position.?.x = 42;
        loaded.entity.position.?.y = 84;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 42") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"y\": 84") != null);
    }

    test "entity without Position has null position" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [ { "prefab": "abstract" } ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.toBeTrue(loaded.scene.entities[0].position == null);
    }

    test "Polygon round-trips with points + color + filled through a prefab" {
        // Geometry slice 3 (issue #6): a prefab carrying a Polygon
        // component must parse into the typed model with every field
        // populated, and the writer must emit it back in the same
        // shape — `points` as an array of `{x,y}` objects, color as a
        // nested object, filled as bool. Polygon is managed so it
        // must NOT leak into component_extras.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "components": {
            \\        "Polygon": { "points": [ { "x": 0, "y": 0 }, { "x": 10, "y": 0 }, { "x": 5, "y": 8 } ], "color": { "r": 200, "g": 50, "b": 25, "a": 240 }, "filled": false }
            \\    }
            \\}
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();

        const poly = loaded.entity.polygon orelse return error.MissingPolygon;
        try expect.equal(poly.point_count, 3);
        try expect.equal(poly.points[0].x, 0);
        try expect.equal(poly.points[1].x, 10);
        try expect.equal(poly.points[2].y, 8);
        try expect.equal(poly.r, 200);
        try expect.equal(poly.g, 50);
        try expect.equal(poly.b, 25);
        try expect.equal(poly.a, 240);
        try expect.toBeFalse(poly.filled);

        try expect.equal(loaded.component_extras.len, 0);

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"Polygon\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"points\":") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 10") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 200") != null);

        // Re-parse the rendered output — same shape, same values.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        const poly2 = loaded2.entity.polygon orelse return error.MissingPolygon;
        try expect.equal(poly2.point_count, 3);
        try expect.equal(poly2.points[2].y, 8);
        try expect.equal(poly2.b, 25);
        try expect.toBeFalse(poly2.filled);
    }

    test "Polygon add + remove point survives a save / load round-trip" {
        // The inspector's add-point / remove-point actions mutate the
        // fixed-cap inline buffer in place. The saved output must
        // reflect whatever the live slice (`points[0..point_count]`)
        // contains at save time — not the original parsed source.
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Polygon": { "points": [ { "x": 0, "y": 0 }, { "x": 1, "y": 1 } ], "color": { "r": 0, "g": 0, "b": 0, "a": 255 }, "filled": true } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        const poly = loaded.entity.polygon orelse return error.MissingPolygon;
        try expect.equal(poly.point_count, 2);

        // Add a point.
        poly.points[poly.point_count] = .{ .x = 7, .y = 9 };
        poly.point_count += 1;
        try expect.equal(poly.point_count, 3);

        // Remove the first point (shift tail down — same path the
        // inspector takes when the user clicks `×` on row 0).
        var k: u32 = 0;
        while (k + 1 < poly.point_count) : (k += 1) {
            poly.points[k] = poly.points[k + 1];
        }
        poly.point_count -= 1;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        // Original `(0, 0)` first point must be gone; the appended
        // `(7, 9)` must be present.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 7") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"y\": 9") != null);

        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        const poly2 = loaded2.entity.polygon orelse return error.MissingPolygon;
        try expect.equal(poly2.point_count, 2);
        try expect.equal(poly2.points[0].x, 1);
        try expect.equal(poly2.points[1].x, 7);
    }

    test "edit Polygon color in memory; saved output reflects it" {
        const allocator = std.testing.allocator;
        const src =
            \\{ "components": { "Polygon": { "points": [], "color": { "r": 0, "g": 0, "b": 0, "a": 255 }, "filled": true } } }
        ;
        var loaded = try scene_io.parsePrefab(allocator, src);
        defer loaded.deinit();
        const poly = loaded.entity.polygon orelse return error.MissingPolygon;
        poly.r = 128;
        poly.g = 64;
        poly.filled = false;

        const text = try scene_io.renderPrefabJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"r\": 128") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"g\": 64") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"filled\": false") != null);
    }

    test "insertEntity appends to entities and extras in lockstep" {
        // Right-click → "Add entity here" path: the new entity must
        // grow both arrays so the writer never reads past
        // entity_components when emitting verbatim component blocks.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "components": { "Position": { "x": 1, "y": 2 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.scene.entities.len, 1);
        try expect.equal(loaded.extras.entity_components.len, 1);

        try scene_io.insertEntity(&loaded, .{
            .position = .{ .x = 50, .y = 75 },
        });

        try expect.equal(loaded.scene.entities.len, 2);
        try expect.equal(loaded.extras.entity_components.len, 2);
        try expect.equal(loaded.extras.entity_components[1].len, 0);
        try expect.toBeTrue(loaded.scene.entities[1].position != null);
        try expect.equal(loaded.scene.entities[1].position.?.x, 50);
        try expect.equal(loaded.scene.entities[1].position.?.y, 75);
        try expect.toBeTrue(loaded.scene.entities[1].prefab == null);
    }

    test "insertEntity with prefab name (arena-owned) round-trips" {
        // "Add entity from prefab" path: the prefab slice must
        // survive across renders because it lives in the LoadedScene's
        // arena. Saving and reparsing exercises the same lifetime
        // contract the editor relies on.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": []
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const prefab_name = try loaded.arena.allocator().dupe(u8, "coin");
        try scene_io.insertEntity(&loaded, .{
            .prefab = prefab_name,
            .position = .{ .x = 12, .y = 34 },
        });

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"prefab\": \"coin\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"x\": 12") != null);

        var loaded2 = try scene_io.parseScene(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.scene.entities.len, 1);
        try expect.toBeTrue(loaded2.scene.entities[0].prefab != null);
        try expect.toBeTrue(std.mem.eql(u8, loaded2.scene.entities[0].prefab.?, "coin"));
    }

    test "removeEntity pops entities and extras together" {
        // Delete-key path: dropping entity at idx 1 must also drop the
        // parallel extras[1], otherwise the writer would splice the
        // wrong unmodeled components onto the now-shifted entity.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        { "components": { "Position": { "x": 1, "y": 2 } } },
            \\        { "components": { "Position": { "x": 3, "y": 4 }, "Coin": {} } },
            \\        { "components": { "Position": { "x": 5, "y": 6 } } }
            \\    ]
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();
        try expect.equal(loaded.scene.entities.len, 3);
        try expect.equal(loaded.extras.entity_components.len, 3);
        try expect.equal(loaded.extras.entity_components[1].len, 1);

        try scene_io.removeEntity(&loaded, 1);

        try expect.equal(loaded.scene.entities.len, 2);
        try expect.equal(loaded.extras.entity_components.len, 2);
        // After removal, the survivors must be the entities with x=1 and x=5.
        try expect.equal(loaded.scene.entities[0].position.?.x, 1);
        try expect.equal(loaded.scene.entities[1].position.?.x, 5);
        // And their extras must be the parallel-array versions — neither
        // should now reference the dropped Coin slot.
        try expect.equal(loaded.extras.entity_components[0].len, 0);
        try expect.equal(loaded.extras.entity_components[1].len, 0);
    }

    test "removeEntity returns error on out-of-bounds index" {
        // Defensive: the editor's selected_index can in principle drift
        // (project switch, undo replay later). Out-of-bounds removal
        // must surface as an error, not silently corrupt the slice.
        const allocator = std.testing.allocator;
        const src =
            \\{ "name": "x", "entities": [] }
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        try std.testing.expectError(error.IndexOutOfBounds, scene_io.removeEntity(&loaded, 0));
        try std.testing.expectError(error.IndexOutOfBounds, scene_io.removeEntity(&loaded, 42));
    }

    test "insertEntity then removeEntity round-trip through save / load" {
        // The full editor add-and-delete cycle: add a prefab entity,
        // then remove it again, then save. The output should match
        // the original empty-entities form (modulo writer-driven
        // formatting). Reparsing must yield zero entities.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": []
            \\}
        ;
        var loaded = try scene_io.parseScene(allocator, src);
        defer loaded.deinit();

        const name = try loaded.arena.allocator().dupe(u8, "wall");
        try scene_io.insertEntity(&loaded, .{
            .prefab = name,
            .position = .{ .x = 7, .y = 8 },
        });
        try expect.equal(loaded.scene.entities.len, 1);
        try scene_io.removeEntity(&loaded, 0);
        try expect.equal(loaded.scene.entities.len, 0);
        try expect.equal(loaded.extras.entity_components.len, 0);

        const text = try scene_io.renderSceneJsonc(allocator, loaded);
        defer allocator.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"wall\"") == null);

        var loaded2 = try scene_io.parseScene(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.scene.entities.len, 0);
    }
};

pub const AtlasJsonTests = struct {
    fn emptyAtlas(allocator: std.mem.Allocator) !atlas.Atlas {
        return .{
            // Atlas.deinit frees `name`; dupe a placeholder so the
            // test cleanup path matches the production path. texture_id
            // stays 0 → deinit skips the GL call.
            .name = try allocator.dupe(u8, "test"),
            .texture_id = 0,
            .width = 0,
            .height = 0,
        };
    }

    test "parses TexturePacker frames into the atlas map" {
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "frames": {
            \\    "coin": { "frame": { "x": 0, "y": 0, "w": 16, "h": 16 } },
            \\    "wall": { "frame": { "x": 16, "y": 0, "w": 32, "h": 32 } }
            \\  },
            \\  "meta": { "image": "sprites.png" }
            \\}
        ;
        var a = try emptyAtlas(allocator);
        defer a.deinit(allocator);
        try atlas.parseFramesFromJsonText(allocator, src, &a);

        try expect.equal(a.frames.count(), 2);
        const coin = a.frames.get("coin") orelse return error.MissingFrame;
        try expect.equal(coin.x, 0);
        try expect.equal(coin.w, 16);
        const wall = a.frames.get("wall") orelse return error.MissingFrame;
        try expect.equal(wall.x, 16);
        try expect.equal(wall.h, 32);
    }

    test "missing frames key returns an error" {
        // A manifest without the top-level "frames" object isn't a
        // valid TexturePacker file — surface a typed error so the
        // loader can warn and continue instead of silently producing
        // an empty atlas.
        const allocator = std.testing.allocator;
        const src = "{ \"meta\": {} }";
        var a = try emptyAtlas(allocator);
        defer a.deinit(allocator);
        try expect.toBeTrue(std.meta.isError(atlas.parseFramesFromJsonText(allocator, src, &a)));
    }

    test "skips entries without a frame rect" {
        // Malformed entries inside an otherwise-valid manifest should
        // be skipped, not abort the whole parse. This keeps a single
        // bad sprite from taking out every other sprite in the atlas.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "frames": {
            \\    "ok": { "frame": { "x": 1, "y": 2, "w": 3, "h": 4 } },
            \\    "no_frame": { "rotated": false },
            \\    "negative_x": { "frame": { "x": -1, "y": 0, "w": 8, "h": 8 } }
            \\  }
            \\}
        ;
        var a = try emptyAtlas(allocator);
        defer a.deinit(allocator);
        try atlas.parseFramesFromJsonText(allocator, src, &a);

        // Only `ok` survives — the other two are malformed in
        // ways the parser is documented to ignore.
        try expect.equal(a.frames.count(), 1);
        try expect.toBeTrue(a.frames.get("ok") != null);
    }

    test "accepts float coordinates produced by some exporters" {
        // Some exporters emit `1.0` instead of `1` for integer
        // coordinates. The parser should accept both shapes (and
        // truncate floats to u32).
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\  "frames": {
            \\    "tile": { "frame": { "x": 10.0, "y": 20.0, "w": 8.0, "h": 8.0 } }
            \\  }
            \\}
        ;
        var a = try emptyAtlas(allocator);
        defer a.deinit(allocator);
        try atlas.parseFramesFromJsonText(allocator, src, &a);

        const tile = a.frames.get("tile") orelse return error.MissingFrame;
        try expect.equal(tile.x, 10);
        try expect.equal(tile.w, 8);
    }

    test "top-level not-an-object surfaces a typed error" {
        const allocator = std.testing.allocator;
        const src = "[]";
        var a = try emptyAtlas(allocator);
        defer a.deinit(allocator);
        try expect.toBeTrue(std.meta.isError(atlas.parseFramesFromJsonText(allocator, src, &a)));
    }
};

pub const SceneRoutingTests = struct {
    test "scene path under scenes/ is accepted" {
        try expect.toBeTrue(project_tree.isScenePath("/p", "/p/scenes/main.jsonc"));
        try expect.toBeTrue(project_tree.isScenePath("/p", "/p/scenes/sub/fragment.jsonc"));
    }

    test "prefab path is rejected" {
        // Same extension, different folder — must not open as a scene
        // (would otherwise be data-destructive on Save).
        try expect.toBeFalse(project_tree.isScenePath("/p", "/p/prefabs/coin.jsonc"));
    }

    test "non-jsonc files are rejected" {
        try expect.toBeFalse(project_tree.isScenePath("/p", "/p/scenes/main.json"));
        try expect.toBeFalse(project_tree.isScenePath("/p", "/p/scenes/notes.md"));
    }

    test "no project dir → no scene routing" {
        try expect.toBeFalse(project_tree.isScenePath(null, "/p/scenes/main.jsonc"));
    }

    test "prefab path under prefabs/ is accepted" {
        try expect.toBeTrue(project_tree.isPrefabPath("/p", "/p/prefabs/coin.jsonc"));
        try expect.toBeTrue(project_tree.isPrefabPath("/p", "/p/prefabs/enemies/goblin.jsonc"));
    }

    test "scene path is not a prefab path" {
        try expect.toBeFalse(project_tree.isPrefabPath("/p", "/p/scenes/main.jsonc"));
    }

    test "scene-vs-prefab routing is mutually exclusive" {
        // No path is both — the caller's if/else if doesn't risk
        // double-dispatch through a single click.
        const samples = [_][]const u8{
            "/p/scenes/main.jsonc",
            "/p/prefabs/coin.jsonc",
            "/p/components/foo.zig",
            "/p/random.jsonc",
        };
        for (samples) |sample| {
            const sc = project_tree.isScenePath("/p", sample);
            const pf = project_tree.isPrefabPath("/p", sample);
            try expect.toBeFalse(sc and pf);
        }
    }

    test "flow path under scripts/flows/ is accepted" {
        try expect.toBeTrue(project_tree.isFlowPath("/p", "/p/scripts/flows/foo.zig"));
        try expect.toBeTrue(project_tree.isFlowPath("/p", "/p/scripts/flows/sub/bar.zig"));
    }

    test "non-flow-extension under scripts/flows is rejected" {
        try expect.toBeFalse(project_tree.isFlowPath("/p", "/p/scripts/flows/notes.md"));
        try expect.toBeFalse(project_tree.isFlowPath("/p", "/p/scripts/flows/main.zon"));
    }

    test "flow path outside scripts/flows/ is rejected" {
        try expect.toBeFalse(project_tree.isFlowPath("/p", "/p/scripts/foo.zig"));
        try expect.toBeFalse(project_tree.isFlowPath("/p", "/p/scenes/foo.zig"));
    }

    test "no project dir → no flow routing" {
        try expect.toBeFalse(project_tree.isFlowPath(null, "/p/scripts/flows/foo.zig"));
    }

    test "gizmo path under gizmos/ is accepted" {
        try expect.toBeTrue(project_tree.isGizmoPath("/p", "/p/gizmos/workstation.zon"));
        try expect.toBeTrue(project_tree.isGizmoPath("/p", "/p/gizmos/sub/room.zon"));
    }

    test "gizmo path under prefabs/ is rejected" {
        // Gizmos live under their own folder; a `.zon` file under
        // prefabs/ (or anywhere else) must not open as a gizmo.
        try expect.toBeFalse(project_tree.isGizmoPath("/p", "/p/prefabs/coin.zon"));
        try expect.toBeFalse(project_tree.isGizmoPath("/p", "/p/scenes/main.zon"));
        try expect.toBeFalse(project_tree.isGizmoPath("/p", "/p/random.zon"));
    }

    test "gizmo path rejects non-.zon files" {
        // `.jsonc` files under gizmos/ are not gizmos — the engine's
        // GizmoRegistry only compiles `.zon`. project.labelle lives
        // at the project root, never under gizmos/, but defend
        // anyway.
        try expect.toBeFalse(project_tree.isGizmoPath("/p", "/p/gizmos/workstation.jsonc"));
        try expect.toBeFalse(project_tree.isGizmoPath("/p", "/p/gizmos/notes.md"));
    }

    test "no project dir → no gizmo routing" {
        try expect.toBeFalse(project_tree.isGizmoPath(null, "/p/gizmos/workstation.zon"));
    }
};

pub const SceneHitTestTests = struct {
    fn makeEntities(allocator: std.mem.Allocator, positions: []const [2]f32) ![]scene_io.Entity {
        const out = try allocator.alloc(scene_io.Entity, positions.len);
        for (positions, 0..) |p, i| {
            out[i] = .{ .position = .{ .x = p[0], .y = p[1] } };
        }
        return out;
    }

    test "returns null when no entity is within hit radius" {
        const allocator = std.testing.allocator;
        const entities = try makeEntities(allocator, &.{ .{ 0, 0 }, .{ 100, 100 } });
        defer allocator.free(entities);
        const hit = scene_module.hitTestEntity(
            entities,
            .{ 200, 200 },
            .{ 0, 0 },
            .{ 0, 0 },
            1.0,
        );
        try expect.toBeTrue(hit == null);
    }

    test "returns the nearest entity inside hit radius" {
        const allocator = std.testing.allocator;
        const entities = try makeEntities(allocator, &.{ .{ 0, 0 }, .{ 50, 0 } });
        defer allocator.free(entities);
        // Mouse at world (48, 0) → entity 1 is closer.
        const hit = scene_module.hitTestEntity(
            entities,
            .{ 48, 0 },
            .{ 0, 0 },
            .{ 0, 0 },
            1.0,
        );
        try expect.toBeTrue(hit != null);
        try expect.equal(hit.?, 1);
    }

    test "pan + zoom affect the hit projection (Y flipped)" {
        const allocator = std.testing.allocator;
        const entities = try makeEntities(allocator, &.{.{ 10, 10 }});
        defer allocator.free(entities);
        // World +y goes up. World (10,10) projected with zoom=2 and
        // pan=(100,100) lands at (100 + 10*2, 100 - 10*2) = (120, 80)
        // in screen space.
        const hit = scene_module.hitTestEntity(
            entities,
            .{ 120, 80 },
            .{ 0, 0 },
            .{ 100, 100 },
            2.0,
        );
        try expect.toBeTrue(hit != null);
        try expect.equal(hit.?, 0);
    }

    test "skips entities with no Position" {
        const allocator = std.testing.allocator;
        const entities = try allocator.alloc(scene_io.Entity, 2);
        defer allocator.free(entities);
        entities[0] = .{}; // no position
        entities[1] = .{ .position = .{ .x = 0, .y = 0 } };
        const hit = scene_module.hitTestEntity(
            entities,
            .{ 0, 0 },
            .{ 0, 0 },
            .{ 0, 0 },
            1.0,
        );
        try expect.toBeTrue(hit != null);
        try expect.equal(hit.?, 1);
    }
};

pub const ViewportRenderPlanTests = struct {
    // Regression coverage for the render-priority + `?` overlay logic
    // in `drawEntities`. PR #37 review (Cursor Bugbot) flagged that
    // when a sprite was declared-but-unresolved AND a polygon was
    // present, the polygon fallback used to suppress the `?` overlay.

    test "resolved sprite wins; no question mark overlay" {
        const plan = viewport.planRender(true, true, false);
        try expect.equal(plan.path, .sprite);
        try expect.toBeFalse(plan.overlay_question);
    }

    test "no sprite, polygon present → polygon path, no overlay" {
        const plan = viewport.planRender(false, false, true);
        try expect.equal(plan.path, .polygon);
        try expect.toBeFalse(plan.overlay_question);
    }

    test "no components at all → marker path, no overlay" {
        const plan = viewport.planRender(false, false, false);
        try expect.equal(plan.path, .marker);
        try expect.toBeFalse(plan.overlay_question);
    }

    test "unresolved sprite + no polygon → marker path with overlay" {
        const plan = viewport.planRender(true, false, false);
        try expect.equal(plan.path, .marker);
        try expect.toBeTrue(plan.overlay_question);
    }

    test "unresolved sprite + polygon → polygon path STILL shows overlay" {
        // The bug Cursor Bugbot caught: this case used to silently
        // render the polygon with no `?` indicator that the sprite
        // failed to resolve.
        const plan = viewport.planRender(true, false, true);
        try expect.equal(plan.path, .polygon);
        try expect.toBeTrue(plan.overlay_question);
    }

    test "resolved sprite + polygon → sprite wins (polygon ignored)" {
        const plan = viewport.planRender(true, true, true);
        try expect.equal(plan.path, .sprite);
        try expect.toBeFalse(plan.overlay_question);
    }
};

pub const ViewportSnapTests = struct {
    // Snap-to-grid math — exercised independently of the imgui draw
    // path. Drag-to-move calls `snapValue` once per axis with the
    // user's step and origin; the formula is
    //   snapped = origin + round((value - origin) / step) * step
    // so the snap grid is aligned to `origin` (defaults to world 0).

    test "rounds to nearest multiple of step at origin 0" {
        try expect.equal(viewport.snapValue(0, 0, 16), 0);
        try expect.equal(viewport.snapValue(7, 0, 16), 0);
        try expect.equal(viewport.snapValue(8, 0, 16), 16); // ties-away (zig @round)
        try expect.equal(viewport.snapValue(9, 0, 16), 16);
        try expect.equal(viewport.snapValue(23, 0, 16), 16);
        try expect.equal(viewport.snapValue(24, 0, 16), 32);
    }

    test "negative values snap symmetrically" {
        try expect.equal(viewport.snapValue(-7, 0, 16), 0);
        try expect.equal(viewport.snapValue(-9, 0, 16), -16);
        try expect.equal(viewport.snapValue(-16, 0, 16), -16);
    }

    test "non-zero origin shifts the grid" {
        // origin=5, step=10 → grid is { ..., -5, 5, 15, 25, ... }.
        try expect.equal(viewport.snapValue(6, 5, 10), 5);
        try expect.equal(viewport.snapValue(11, 5, 10), 15);
        try expect.equal(viewport.snapValue(0, 5, 10), -5);
    }

    test "values already on a grid line stay put" {
        try expect.equal(viewport.snapValue(32, 0, 16), 32);
        try expect.equal(viewport.snapValue(-48, 0, 16), -48);
    }

    test "non-integer step rounds to that step" {
        // Use loose tolerance: 0.5 floating ops are exact in f32.
        try expect.equal(viewport.snapValue(1.2, 0, 0.5), 1.0);
        try expect.equal(viewport.snapValue(1.3, 0, 0.5), 1.5);
    }
};

pub const SceneTemplateTests = struct {
    /// Strip `//`-to-end-of-line comments so the JSONC template can be
    /// fed to std.json (which doesn't accept comments). Replaces the
    /// comment bytes with spaces so column/line offsets — and therefore
    /// any later parser diagnostics — match the original.
    fn stripLineComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
        const out = try allocator.dupe(u8, src);
        var i: usize = 0;
        while (i + 1 < out.len) : (i += 1) {
            if (out[i] == '/' and out[i + 1] == '/') {
                var j = i;
                while (j < out.len and out[j] != '\n') : (j += 1) out[j] = ' ';
                i = j;
            }
        }
        return out;
    }

    test "renders scene name into name field" {
        const allocator = std.testing.allocator;
        const out = try new_scene.renderSceneJsonc(allocator, "my_scene");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "\"name\": \"my_scene\"") != null);
    }

    test "includes an entities array" {
        const allocator = std.testing.allocator;
        const out = try new_scene.renderSceneJsonc(allocator, "anything");
        defer allocator.free(out);
        try expect.toBeTrue(std.mem.indexOf(u8, out, "\"entities\":") != null);
    }

    test "uses .jsonc-compatible content (parses as JSON after stripping comments)" {
        const allocator = std.testing.allocator;
        const out = try new_scene.renderSceneJsonc(allocator, "parse_check");
        defer allocator.free(out);

        const stripped = try stripLineComments(allocator, out);
        defer allocator.free(stripped);

        const SceneSchema = struct {
            name: []const u8,
            entities: []const struct {} = &.{},
        };

        const parsed = try std.json.parseFromSlice(SceneSchema, allocator, stripped, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        try expect.toBeTrue(std.mem.eql(u8, parsed.value.name, "parse_check"));
        try expect.equal(parsed.value.entities.len, 0);
    }
};

pub const ProjectFileTests = struct {
    fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const tmp_base = "/tmp";
        const ts = timestampSeconds();
        const dir_name = try std.fmt.allocPrint(allocator, "{s}/labelle_test_{d}", .{ tmp_base, ts });
        try std.Io.Dir.cwd().createDir(io_global.io(), dir_name, .default_dir);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.Io.Dir.cwd().deleteTree(io_global.io(), dir_path) catch {};
        allocator.free(dir_path);
    }

    test "saveProject writes project.labelle in the directory" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("test_project");
        try pm.saveProject(temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const content = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        try expect.toBeTrue(std.mem.indexOf(u8, content, ".name = \"test_project\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".backend = .raylib") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".ecs = .zig_ecs") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".initial_scene = \"main\"") != null);
    }

    test "saveProject creates scaffold folders" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("test_project");
        try pm.saveProject(temp_dir);

        for (project.ProjectFolders.all) |folder| {
            const folder_path = try std.fs.path.join(allocator, &.{ temp_dir, folder });
            defer allocator.free(folder_path);

            const io = io_global.io();
            var dir = std.Io.Dir.cwd().openDir(io, folder_path, .{}) catch {
                std.debug.print("Missing folder: {s}\n", .{folder});
                return error.MissingFolder;
            };
            dir.close(io);
        }
    }

    test "saveProject stores directory on the project" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("test_project");
        try pm.saveProject(temp_dir);

        try expect.toBeTrue(pm.current_project.?.dir != null);
        try expect.toBeTrue(std.mem.eql(u8, pm.current_project.?.dir.?, temp_dir));
        try expect.toBeFalse(pm.current_project.?.is_dirty);
    }

    test "saveProject omits empty resources block" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("no_resources");
        try pm.saveProject(temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);
        const content = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(content);

        try expect.toBeTrue(std.mem.indexOf(u8, content, ".resources") == null);
    }

    test "resources round-trip through save + load" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Save a project carrying one Factory-built ResourceDef, reload
        // via a fresh ProjectManager, assert the resource came back
        // intact. Factory.defineFrom validates each field name against
        // ResourceDef at comptime — a typo in `test_fixtures/resource.zon`
        // fails the build, not the test.
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("with_resources");

        const proj = pm.current_project.?;
        const a = proj.arena.allocator();
        const resources = try a.alloc(project.ResourceDef, 1);
        resources[0] = test_fixtures.ResourceFactory.build(.{});
        proj.config.resources = resources;

        try pm.saveProject(temp_dir);

        var pm2 = project.ProjectManager.init(allocator);
        defer pm2.deinit();
        try pm2.loadProject(temp_dir);

        const loaded = pm2.current_project.?.config.resources;
        try expect.equal(loaded.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded[0].name, "sprites"));
        try expect.toBeTrue(std.mem.eql(u8, loaded[0].json, "assets/sprites.json"));
        try expect.toBeTrue(std.mem.eql(u8, loaded[0].texture, "assets/sprites.png"));
    }

    test "ProjectConfigFactory overrides round-trip through save + load" {
        // Proof-of-value for the Factory pattern (precursor to #120's
        // `project_settings_edit_save` triage): build a non-default
        // ProjectConfig with several overrides via Factory.build,
        // round-trip through saveProject/loadProject, assert every
        // override survived. Replaces what would otherwise be a
        // multi-line struct literal plus arena.dupe per string field.
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("factory_overrides");

        const proj = pm.current_project.?;
        proj.config = test_fixtures.ProjectConfigFactory.build(.{
            .name = "factory_overrides",
            .title = "Factory Overrides",
            .width = 1920,
            .height = 1080,
            .backend = .sokol,
            .initial_scene = "splash",
            .engine_version = "1.36.0",
        });

        try pm.saveProject(temp_dir);

        var pm2 = project.ProjectManager.init(allocator);
        defer pm2.deinit();
        try pm2.loadProject(temp_dir);

        const cfg = pm2.current_project.?.config;
        try expect.toBeTrue(std.mem.eql(u8, cfg.name, "factory_overrides"));
        try expect.toBeTrue(std.mem.eql(u8, cfg.title, "Factory Overrides"));
        try expect.equal(cfg.width, 1920);
        try expect.equal(cfg.height, 1080);
        try expect.equal(cfg.backend, .sokol);
        try expect.toBeTrue(std.mem.eql(u8, cfg.initial_scene, "splash"));
        try expect.toBeTrue(std.mem.eql(u8, cfg.engine_version, "1.36.0"));
        // Non-overridden fields keep their ProjectConfigFactory
        // defaults — proves the factory's defaults pass through
        // saveProject + loadProject untouched.
        try expect.equal(cfg.ecs, .zig_ecs);
        try expect.equal(cfg.target_fps, 60);
        try expect.toBeTrue(std.mem.eql(u8, cfg.description, ""));
        try expect.toBeTrue(std.mem.eql(u8, cfg.core_version, "1.12.0"));
        try expect.toBeTrue(std.mem.eql(u8, cfg.gfx_version, "1.10.0"));
        try expect.toBeTrue(std.mem.eql(u8, cfg.assembler_version, "0.20.0"));
        try expect.equal(cfg.resources.len, 0);
    }

    // Regression: ../flying-platform-labelle/project.labelle (and any
    // project authored by the assembler / CLI) carries fields like
    // `states`, `layers`, `plugins`, `gui`, `labelle_version`, etc. that
    // our minimal ProjectConfig doesn't model. Default ZON parsing
    // rejects unknown fields, which made every real project fail to
    // open. Load must tolerate those fields and recover the ones we do
    // model.
    test "loadProject ignores unknown ZON fields" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        // Hand-written project.labelle mimicking what flying-platform
        // and the assembler examples ship: every modeled field plus a
        // representative set of unmodeled ones.
        const synthetic =
            \\.{
            \\    .name = "external_project",
            \\    .title = "External",
            \\    .width = 1024,
            \\    .height = 768,
            \\    .target_fps = 60,
            \\    .backend = .sokol,
            \\    .ecs = .zig_ecs,
            \\    .initial_scene = "loading",
            \\    .states = .{ "loading", "playing" },
            \\    .gui = .{ .plugin = "imgui" },
            \\    .resources = .{
            \\        .{ .name = "sprites", .json = "assets/sprites.json", .texture = "assets/sprites.png" },
            \\    },
            \\    .plugins = .{
            \\        .{ .name = "imgui", .repo = "local:../labelle-imgui" },
            \\    },
            \\    .layers = .{
            \\        .{ .name = "world", .order = 0, .space = .world },
            \\    },
            \\    .core_version = "1.10.0",
            \\    .engine_version = "1.21.0",
            \\    .gfx_version = "1.7.0",
            \\    .labelle_version = "1.36.0",
            \\    .assembler_version = "0.8.0",
            \\    .hidden = false,
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = synthetic,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);

        const cfg = pm.current_project.?.config;
        try expect.toBeTrue(std.mem.eql(u8, cfg.name, "external_project"));
        try expect.equal(cfg.backend, .sokol);
        try expect.equal(cfg.ecs, .zig_ecs);
        try expect.toBeTrue(std.mem.eql(u8, cfg.initial_scene, "loading"));
        try expect.equal(cfg.resources.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, cfg.resources[0].name, "sprites"));
    }

    test "saveProject preserves unmodeled fields verbatim (round-trip)" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "external_project",
            \\    .title = "External",
            \\    .width = 1024,
            \\    .height = 768,
            \\    .target_fps = 60,
            \\    .backend = .sokol,
            \\    .ecs = .zig_ecs,
            \\    .initial_scene = "loading",
            \\    .states = .{ "loading", "playing" },
            \\    .gui = .{ .plugin = "imgui" },
            \\    .plugins = .{
            \\        .{ .name = "imgui", .repo = "local:../labelle-imgui" },
            \\    },
            \\    .layers = .{
            \\        .{ .name = "world", .order = 0, .space = .world },
            \\    },
            \\    .core_version = "1.10.0",
            \\    .engine_version = "1.21.0",
            \\    .gfx_version = "1.7.0",
            \\    .labelle_version = "1.36.0",
            \\    .assembler_version = "0.8.0",
            \\    .hidden = false,
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const saved = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(saved);

        // The five unmodeled fields must survive a save+load cycle.
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".states") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".gui") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".plugins") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".layers") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".labelle_version") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".hidden") != null);
        // And the unmodeled struct literals must still be there.
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "\"loading\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "imgui") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "local:../labelle-imgui") != null);
    }

    test "saveProject re-parses cleanly after extras round-trip" {
        // Belt-and-suspenders: after save, loading the saved file again
        // must succeed. Catches accidental syntax breakage in the
        // verbatim-extras emission (missing commas, wrong braces, etc.).
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "x",
            \\    .states = .{ "menu", "playing" },
            \\    .gui = .{ .plugin = "imgui" },
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        var pm2 = project.ProjectManager.init(allocator);
        defer pm2.deinit();
        try pm2.loadProject(temp_dir);
        try expect.toBeTrue(std.mem.eql(u8, pm2.current_project.?.config.name, "x"));
    }

    test "saveProject preserves comments attached to unmodeled fields" {
        // The flying-platform regression: comments directly above an
        // unmodeled field must travel with it through save/load.
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "x",
            \\    .initial_scene = "loading",
            \\    // Loading scene runs first; controller swaps to main
            \\    // once the manifest is ready.
            \\    .states = .{ "loading", "playing" },
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const saved = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(saved);

        try expect.toBeTrue(std.mem.indexOf(u8, saved, "// Loading scene runs first; controller swaps to main") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "// once the manifest is ready.") != null);
    }

    test "saveProject keeps extras when a modeled field changes" {
        // Editing .title via the gui must not collateral-damage .states/.gui.
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "x",
            \\    .title = "Old Title",
            \\    .states = .{ "menu" },
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);

        const proj = pm.current_project.?;
        proj.config.title = try proj.arena.allocator().dupe(u8, "New Title");

        try pm.saveProject(temp_dir);

        const saved = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(saved);

        try expect.toBeTrue(std.mem.indexOf(u8, saved, "\"New Title\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".states") != null);
    }

    test "loadProject still errors on malformed ZON" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        // Unbalanced braces — syntactically invalid ZON, not just an
        // unknown field. ignore_unknown_fields must not mask this.
        const broken = ".{ .name = \"oops\",";
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = broken,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        const got = pm.loadProject(temp_dir);
        try expect.toBeTrue(std.meta.isError(got));
    }

    test "loadProject round-trips a saved project" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        {
            var pm = project.ProjectManager.init(allocator);
            defer pm.deinit();
            try pm.newProject("round_trip");
            try pm.saveProject(temp_dir);
        }

        var pm2 = project.ProjectManager.init(allocator);
        defer pm2.deinit();
        try pm2.loadProject(temp_dir);

        try expect.toBeTrue(pm2.current_project != null);
        try expect.toBeTrue(std.mem.eql(u8, pm2.current_project.?.config.name, "round_trip"));
        try expect.equal(pm2.current_project.?.config.backend, .raylib);
        try expect.equal(pm2.current_project.?.config.ecs, .zig_ecs);
    }

    // Regression for #125: opening flying-platform-labelle in the gui
    // and triggering a save silently overwrote `engine_version` /
    // `assembler_version` / etc. with the gui's compiled-in defaults.
    // Load + save must preserve non-default version pins on the
    // managed modeled fields.
    test "loadProject preserves non-default version pins through save round-trip" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        // Pin every version field to an obviously-non-default value so
        // a load that silently fell back to defaults would be caught
        // immediately on any field. Field order mirrors the real
        // flying-platform-labelle file (versions trail the body and
        // `.labelle_version` is interspersed with the managed pins).
        const original =
            \\.{
            \\    .name = "pinned_project",
            \\    .title = "Pinned",
            \\    .width = 1024,
            \\    .height = 768,
            \\    .target_fps = 60,
            \\    .backend = .sokol,
            \\    .ecs = .zig_ecs,
            \\    .initial_scene = "loading",
            \\    .states = .{ "loading", "playing" },
            \\    .core_version = "9.9.9",
            \\    .engine_version = "1.99.0",
            \\    .gfx_version = "9.9.9",
            \\    .labelle_version = "1.36.0",
            \\    .assembler_version = "9.9.9",
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        // Step 1 of the triage: assert the load picked the pins up,
        // not the ProjectConfig defaults. Catches a regression in
        // either the parser call or the field name list.
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);

        const loaded_cfg = pm.current_project.?.config;
        try expect.toBeTrue(std.mem.eql(u8, loaded_cfg.engine_version, "1.99.0"));
        try expect.toBeTrue(std.mem.eql(u8, loaded_cfg.assembler_version, "9.9.9"));
        try expect.toBeTrue(std.mem.eql(u8, loaded_cfg.core_version, "9.9.9"));
        try expect.toBeTrue(std.mem.eql(u8, loaded_cfg.gfx_version, "9.9.9"));

        // Step 2: round-trip through save + load and re-assert. Save
        // emits from the in-memory ProjectConfig; if a downstream
        // code path is overwriting it with defaults, this catches it.
        try pm.saveProject(temp_dir);

        var pm2 = project.ProjectManager.init(allocator);
        defer pm2.deinit();
        try pm2.loadProject(temp_dir);

        const reloaded = pm2.current_project.?.config;
        try expect.toBeTrue(std.mem.eql(u8, reloaded.engine_version, "1.99.0"));
        try expect.toBeTrue(std.mem.eql(u8, reloaded.assembler_version, "9.9.9"));
        try expect.toBeTrue(std.mem.eql(u8, reloaded.core_version, "9.9.9"));
        try expect.toBeTrue(std.mem.eql(u8, reloaded.gfx_version, "9.9.9"));
    }

    // Same as the previous test but mirroring the exact layout of
    // ../flying-platform-labelle/project.labelle (resources block,
    // plugins block, layers block between top fields and version
    // pins). Catches any save-order or extras-interaction bug that
    // a minimal synthetic file wouldn't hit.
    test "flying-platform-shaped project preserves version pins" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "flying_platform",
            \\    .title = "Flying Platform",
            \\    .width = 1024,
            \\    .height = 768,
            \\    .target_fps = 60,
            \\    .backend = .sokol,
            \\    .ecs = .zig_ecs,
            \\    .initial_scene = "loading",
            \\    .states = .{ "loading", "playing", "debug", "menu" },
            \\    .gui = .{ .plugin = "imgui" },
            \\    .resources = .{
            \\        .{ .name = "background", .json = "assets/background.json", .texture = "assets/background.png" },
            \\    },
            \\    .plugins = .{
            \\        .{ .name = "imgui", .repo = "github.com/labelle-toolkit/labelle-imgui", .version = "0.3.1" },
            \\    },
            \\    .layers = .{
            \\        .{ .name = "world", .order = 1, .space = .world },
            \\    },
            \\    .core_version = "1.12.0",
            \\    .engine_version = "1.37.3",
            \\    .gfx_version = "1.10.0",
            \\    .labelle_version = "1.36.0",
            \\    .assembler_version = "0.20.0",
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const saved = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(saved);

        // Managed pins must survive intact.
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".engine_version = \"1.37.3\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".assembler_version = \"0.20.0\"") != null);
        // Plugin .version must survive intact (unmodeled extras).
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".version = \"0.3.1\"") != null);
    }

    // Regression for #125 (plugin half): plugins are unmodeled in the
    // gui's ProjectConfig, so each plugin entry — including its
    // `.version` sub-field — must survive a load/save round-trip
    // verbatim via the extras pass-through.
    test "plugin entry .version survives load/save round-trip" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        const labelle_path = try std.fs.path.join(allocator, &.{ temp_dir, "project.labelle" });
        defer allocator.free(labelle_path);

        const original =
            \\.{
            \\    .name = "plugged",
            \\    .plugins = .{
            \\        .{ .name = "imgui", .repo = "github.com/labelle-toolkit/labelle-imgui", .version = "0.3.1" },
            \\        .{ .name = "fsm", .repo = "github.com/labelle-toolkit/labelle-fsm", .version = "0.1.0" },
            \\    },
            \\}
            \\
        ;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = labelle_path,
            .data = original,
        }) catch unreachable;

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const saved = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), labelle_path, allocator, .limited(1024 * 1024));
        defer allocator.free(saved);

        // Plugin entry `.version` must be byte-identical to the input
        // for both plugins.
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".version = \"0.3.1\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, ".version = \"0.1.0\"") != null);
        // And the rest of each plugin entry must also survive.
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "github.com/labelle-toolkit/labelle-imgui") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, saved, "github.com/labelle-toolkit/labelle-fsm") != null);
    }
};

pub const GizmoIoTests = struct {
    // Verbatim is the key contract: gizmos may carry a Shape union
    // we don't model structurally yet, so the parser must capture
    // `.entity` / `.children` blocks unchanged and the writer must
    // splice them back in faithfully.

    const sample_workstation =
        \\.{
        \\    .match = .{"Workstation"},
        \\    .entity = .{
        \\        .Shape = .{
        \\            .x = 0,
        \\            .y = 0,
        \\            .shape = .{ .triangle = .{ .p2 = .{ .x = 12, .y = -20 }, .p3 = .{ .x = -12, .y = -20 } } },
        \\            .color = .{ .r = 255, .g = 150, .b = 50, .a = 220 },
        \\        },
        \\    },
        \\}
        \\
    ;

    const sample_with_exclude =
        \\.{
        \\    .match = .{"Room", "Quarters"},
        \\    .exclude = .{"Hidden"},
        \\    .entity = .{
        \\        .Shape = .{ .shape = .{ .circle = .{ .radius = 8 } } },
        \\    },
        \\}
        \\
    ;

    test "parses match into a typed list" {
        const allocator = std.testing.allocator;
        var loaded = try gizmo_io.parseGizmo(allocator, sample_workstation);
        defer loaded.deinit();

        try expect.equal(loaded.gizmo.match.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded.gizmo.match[0], "Workstation"));
        try expect.equal(loaded.gizmo.exclude.len, 0);
    }

    test "parses exclude when present" {
        const allocator = std.testing.allocator;
        var loaded = try gizmo_io.parseGizmo(allocator, sample_with_exclude);
        defer loaded.deinit();

        try expect.equal(loaded.gizmo.match.len, 2);
        try expect.toBeTrue(std.mem.eql(u8, loaded.gizmo.match[0], "Room"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.gizmo.match[1], "Quarters"));
        try expect.equal(loaded.gizmo.exclude.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded.gizmo.exclude[0], "Hidden"));
    }

    test "captures .entity block verbatim" {
        const allocator = std.testing.allocator;
        var loaded = try gizmo_io.parseGizmo(allocator, sample_workstation);
        defer loaded.deinit();

        try expect.toBeTrue(loaded.gizmo.entity_verbatim != null);
        const text = loaded.gizmo.entity_verbatim.?;
        // Spot-check distinctive substrings from the Shape body so a
        // future writer refactor that drops bytes is caught.
        try expect.toBeTrue(std.mem.indexOf(u8, text, ".triangle") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, ".x = 12") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text, ".r = 255") != null);
    }

    test "round-trip parse → render → parse preserves match/exclude/entity" {
        const allocator = std.testing.allocator;

        var loaded1 = try gizmo_io.parseGizmo(allocator, sample_with_exclude);
        defer loaded1.deinit();
        const rendered = try gizmo_io.renderGizmoZon(allocator, loaded1);
        defer allocator.free(rendered);

        var loaded2 = try gizmo_io.parseGizmo(allocator, rendered);
        defer loaded2.deinit();

        try expect.equal(loaded2.gizmo.match.len, loaded1.gizmo.match.len);
        for (loaded1.gizmo.match, loaded2.gizmo.match) |a, b| {
            try expect.toBeTrue(std.mem.eql(u8, a, b));
        }
        try expect.equal(loaded2.gizmo.exclude.len, loaded1.gizmo.exclude.len);
        for (loaded1.gizmo.exclude, loaded2.gizmo.exclude) |a, b| {
            try expect.toBeTrue(std.mem.eql(u8, a, b));
        }
        try expect.toBeTrue(loaded2.gizmo.entity_verbatim != null);
        try expect.toBeTrue(std.mem.eql(
            u8,
            loaded2.gizmo.entity_verbatim.?,
            loaded1.gizmo.entity_verbatim.?,
        ));
    }

    test "editing a match entry shows up in saved output" {
        const allocator = std.testing.allocator;
        var loaded = try gizmo_io.parseGizmo(allocator, sample_workstation);
        defer loaded.deinit();

        // Mutate match in place (using the same arena lifetime the
        // module owns) and re-render. The new string must appear and
        // the old one must not.
        const new_str = try loaded.arena.allocator().dupe(u8, "DiningTable");
        loaded.gizmo.match[0] = new_str;

        const rendered = try gizmo_io.renderGizmoZon(allocator, loaded);
        defer allocator.free(rendered);

        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"DiningTable\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "\"Workstation\"") == null);
    }

    test "omits exclude/entity/children when not present" {
        const allocator = std.testing.allocator;
        const minimal = ".{ .match = .{\"Foo\"} }\n";
        var loaded = try gizmo_io.parseGizmo(allocator, minimal);
        defer loaded.deinit();

        const rendered = try gizmo_io.renderGizmoZon(allocator, loaded);
        defer allocator.free(rendered);

        try expect.toBeTrue(std.mem.indexOf(u8, rendered, ".match") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, ".exclude") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, ".entity") == null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, ".children") == null);
    }

    test "displayNameFromPath strips .zon extension" {
        try expect.toBeTrue(std.mem.eql(u8, gizmo_io.displayNameFromPath("/p/gizmos/workstation.zon"), "workstation"));
        try expect.toBeTrue(std.mem.eql(u8, gizmo_io.displayNameFromPath("room.zon"), "room"));
        try expect.toBeTrue(std.mem.eql(u8, gizmo_io.displayNameFromPath("noext"), "noext"));
    }

    test "renderGizmoZon escapes hostile characters in match/exclude" {
        // Regression for gemini review: the writer used to interpolate
        // strings raw, so a `"` or `\` in a tag name would break the
        // file. `std.zig.fmtString` escapes those, and the rendered ZON
        // must re-parse to the same byte sequence.
        const allocator = std.testing.allocator;
        const source = ".{ .match = .{\"Foo\"} }\n";
        var loaded = try gizmo_io.parseGizmo(allocator, source);
        defer loaded.deinit();

        const hostile = try loaded.arena.allocator().dupe(u8, "Quote\"Backslash\\End");
        loaded.gizmo.match[0] = hostile;
        loaded.gizmo.exclude = try loaded.arena.allocator().alloc([]const u8, 1);
        loaded.gizmo.exclude[0] = try loaded.arena.allocator().dupe(u8, "Tab\there");

        const rendered = try gizmo_io.renderGizmoZon(allocator, loaded);
        defer allocator.free(rendered);

        // No unescaped `"` should appear inside our match value beyond
        // the surrounding delimiters — escaping turned it into `\"`.
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "Quote\\\"Backslash\\\\End") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, rendered, "Tab\\there") != null);

        // Round-trip back through the parser and confirm the strings
        // decode to the originals.
        var reparsed = try gizmo_io.parseGizmo(allocator, rendered);
        defer reparsed.deinit();
        try expect.equal(reparsed.gizmo.match.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, reparsed.gizmo.match[0], hostile));
        try expect.equal(reparsed.gizmo.exclude.len, 1);
        try expect.toBeTrue(std.mem.eql(u8, reparsed.gizmo.exclude[0], "Tab\there"));
    }
};

pub const GizmoMatchTests = struct {
    test "match accepts an entity whose components include a match name" {
        const present = [_][]const u8{ "Position", "Workstation" };
        const m = [_][]const u8{"Workstation"};
        const x: [0][]const u8 = .{};
        try expect.toBeTrue(gizmos.entityMatches(&m, &x, &present));
    }

    test "match rejects when none of the match names are present" {
        const present = [_][]const u8{ "Position", "Sprite" };
        const m = [_][]const u8{"Workstation"};
        const x: [0][]const u8 = .{};
        try expect.toBeFalse(gizmos.entityMatches(&m, &x, &present));
    }

    test "exclude vetoes an otherwise-matching entity" {
        const present = [_][]const u8{ "Item", "Stored" };
        const m = [_][]const u8{"Item"};
        const x = [_][]const u8{"Stored"};
        try expect.toBeFalse(gizmos.entityMatches(&m, &x, &present));
    }

    test "empty match matches every non-excluded entity" {
        // Mirrors the engine convention: an absent `.match` field is
        // treated as a catch-all.
        const present = [_][]const u8{ "Position", "Sprite" };
        const m: [0][]const u8 = .{};
        const x: [0][]const u8 = .{};
        try expect.toBeTrue(gizmos.entityMatches(&m, &x, &present));
    }
};

pub const GizmosIndexTests = struct {
    test "build against a missing gizmos/ dir returns an empty index" {
        // Regression: the loader has to tolerate projects without a
        // gizmos/ subtree (the common case). `Index.deinit` must be
        // safe on the resulting empty struct.
        //
        // The original test used `std.testing.tmpDir(...)` and then
        // `realPathFileAlloc(io_global.io(), ".", ...)` to materialize a
        // dir path for the empty-case input. Under Zig 0.16 that routes
        // through `std.testing.io` (a `Threaded` Io) which deadlocks on
        // Linux CI but works on macOS. The test only needs a path that
        // *doesn't* contain a gizmos/ subtree — a known-nonexistent
        // string is equivalent for the assertion and skips the Io path.
        const dir_path = "/labelle-gui-test-no-such-dir";
        var idx = gizmos.Index.build(std.testing.allocator, dir_path, 1);
        defer idx.deinit();
        try expect.toBeEmpty(idx.entries.items);
        try expect.toBeEmpty(idx.arenas.items);
        try expect.equal(idx.generation, @as(u64, 1));
    }

    test "deinit frees per-entry arenas without double-free" {
        // Regression for PR #41 review: prior to the fix, an OOM
        // between `arenas.append` and `entries.append` left a dangling
        // arena pointer; the errdefer for the loop arena and the
        // index's own deinit would each free it. We can't easily
        // force an OOM here, but we can stand up an Index manually
        // with one valid arena+entry and prove deinit walks the
        // arena list and frees cleanly.
        var idx: gizmos.Index = .{
            .allocator = std.testing.allocator,
            .generation = 7,
        };
        const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
        const a = arena.allocator();

        const match_one = try a.alloc([]const u8, 1);
        match_one[0] = try a.dupe(u8, "Workstation");
        const empty: [][]const u8 = &.{};
        const source_owned = try a.dupe(u8, "/dev/null/test.zon");

        try idx.arenas.append(std.testing.allocator, arena);
        try idx.entries.append(std.testing.allocator, .{
            .source = source_owned,
            .match = match_one,
            .exclude = empty,
            .shape = .{ .circle = .{ .radius = 8 } },
        });
        idx.deinit();
        // Reaching here without leaks (std.testing.allocator is the
        // GPA) is the assertion.
    }
};

// ─── Flows projector + renderers (issues #48 + #49) ───────────────────

fn projectStr(source: [:0]const u8) !flow_types.Graph {
    return try flow_projector.project(std.testing.allocator, source);
}

fn countCategory(graph: flow_types.Graph, cat: flow_types.GraphNodeSpec.Category) usize {
    var n: usize = 0;
    for (graph.nodes) |node| if (node.category == cat) {
        n += 1;
    };
    return n;
}

pub const FlowsProjectorTests = struct {
    test "empty source produces an empty graph" {
        var g = try projectStr("");
        defer g.deinit();
        try expect.equal(g.nodes.len, 0);
        try expect.equal(g.edges.len, 0);
        try expect.equal(g.entry_points.len, 0);
    }

    test "non-entry-point function is skipped" {
        // `helper` doesn't match the name list and doesn't take a
        // *Game first param — the projector ignores it.
        const source =
            \\fn helper(a: i32, b: i32) i32 {
            \\    return a + b;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.equal(g.entry_points.len, 0);
    }

    test "tick(game, dt) becomes an entry point with two params" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.equal(g.entry_points.len, 1);

        const root = g.nodes[0];
        try expect.toBeTrue(root.category == .entry_point);
        try expect.equal(root.input_pins.len, 2);
    }

    test "*Game first param promotes to entry point" {
        const source =
            \\const Game = opaque {};
            \\pub fn customHandler(g: *Game, x: i32) void {
            \\    _ = g;
            \\    _ = x;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        // `customHandler` isn't in the name list but its first param
        // type text contains "Game" → entry point.
        try expect.equal(g.entry_points.len, 1);
    }

    test "binary op produces a binop node with two inputs and one output" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    const x = 1 + 2;
            \\    _ = x;
            \\    _ = dt;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.toBeTrue(countCategory(g, .binop) >= 1);
    }

    test "if branch produces a branch node with two execution outputs" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    if (dt > 0) {
            \\        _ = dt;
            \\    }
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.toBeTrue(countCategory(g, .branch) >= 1);
    }

    test "while loop produces a loop node" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\    var i: i32 = 0;
            \\    while (i < 3) {
            \\        i += 1;
            \\    }
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.toBeTrue(countCategory(g, .loop) >= 1);
    }

    test "function call produces a call node labelled with the callee" {
        const source =
            \\fn helper() void {}
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\    helper();
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();

        var found = false;
        for (g.nodes) |node| {
            if (node.category == .call and std.mem.eql(u8, node.label, "helper")) {
                found = true;
                break;
            }
        }
        try expect.toBeTrue(found);
    }

    test "var_decl produces a var_decl node and binds its identifier" {
        // `dt + 1` exercises the binop path which dispatches `dt` as
        // a child — that's how identifier references reach the
        // renderer. A bare `_ = x;` would wrap x in an assign-discard
        // and bypass the identifier renderer.
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    const x = dt + 1;
            \\    const y = x + 2;
            \\    _ = y;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.toBeTrue(countCategory(g, .var_decl) >= 2);
        try expect.toBeTrue(countCategory(g, .identifier) >= 1);
    }

    test "return emits a terminator node" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) i32 {
            \\    _ = game;
            \\    _ = dt;
            \\    return 0;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.toBeTrue(countCategory(g, .terminator) >= 1);
    }

    test "source_line is 1-based and lands on the construct's main token" {
        // Line 1: comment. Line 2: blank. Line 3: fn header. Body
        // starts at line 4. The `if` is on line 4 (or 5 depending on
        // brace placement). Just confirm we get something > 1.
        const source =
            \\// header comment
            \\
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    if (dt > 0) {}
            \\    _ = game;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        var branch_line: u32 = 0;
        for (g.nodes) |node| {
            if (node.category == .branch) {
                branch_line = node.source_line;
                break;
            }
        }
        try expect.toBeTrue(branch_line >= 4);
    }
};

pub const FlowsRendererTests = struct {
    test "every node carries arena-allocated label and pins" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        for (g.nodes) |node| {
            try expect.toBeTrue(node.label.len > 0);
        }
    }

    test "ids are unique across nodes and across pins" {
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    const x = dt + 1;
            \\    _ = x;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();

        // Quadratic scan is fine — the test graph is small.
        for (g.nodes, 0..) |a, i| {
            for (g.nodes[i + 1 ..]) |b| {
                try expect.toBeTrue(a.id != b.id);
            }
        }

        // Collect every pin id from every node, then check
        // uniqueness. We allocate the buffer on the heap because
        // it's bounded by node count × pin count.
        var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
        defer seen.deinit();
        for (g.nodes) |node| {
            for (node.input_pins) |pin| {
                const gop = try seen.getOrPut(pin.id);
                try expect.toBeFalse(gop.found_existing);
            }
            for (node.output_pins) |pin| {
                const gop = try seen.getOrPut(pin.id);
                try expect.toBeFalse(gop.found_existing);
            }
        }
    }

    test "generic fallback fires for tags not in the renderer set" {
        // `orelse` is intentionally outside the v1 binop list —
        // the projector must route it through the generic renderer
        // rather than crashing.
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    const x: ?f32 = dt;
            \\    const y = x orelse 0;
            \\    _ = y;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        // Reaching here without crashing is the assertion.
        try expect.toBeTrue(g.nodes.len > 0);
    }

    test "if body block fans its statements out (no generic blob)" {
        // Regression for cursor bugbot #63: previously, an `if`
        // body that was a block fell through `dispatch` to
        // `renderGeneric`, collapsing the body into one opaque
        // node. The fix in `renderBranch` walks the block's
        // statements directly so the inner `helper()` call
        // renders as a `.call` node.
        const source =
            \\fn helper() void {}
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    if (dt > 0) {
            \\        helper();
            \\    }
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();

        var found_helper = false;
        for (g.nodes) |node| {
            if (node.category == .call and std.mem.eql(u8, node.label, "helper")) {
                found_helper = true;
                break;
            }
        }
        try expect.toBeTrue(found_helper);
    }

    test "while body block fans its statements out (no generic blob)" {
        // Same regression as the `if` case, for `while` bodies.
        const source =
            \\fn helper() void {}
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    _ = dt;
            \\    var i: i32 = 0;
            \\    while (i < 3) {
            \\        helper();
            \\        i += 1;
            \\    }
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();

        var found_helper = false;
        for (g.nodes) |node| {
            if (node.category == .call and std.mem.eql(u8, node.label, "helper")) {
                found_helper = true;
                break;
            }
        }
        try expect.toBeTrue(found_helper);
    }

    test "identifier nodes have a ref input pin (gemini #63 high)" {
        // Identifier references previously emitted an
        // output-pin→output-pin edge from the binding. The fix
        // adds an input `ref` pin that the binding wires into; the
        // output pin then propagates downstream.
        const source =
            \\pub fn tick(game: anytype, dt: f32) void {
            \\    _ = game;
            \\    const x = dt + 1;
            \\    const y = x + 2;
            \\    _ = y;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();

        var saw_identifier_with_ref_input = false;
        for (g.nodes) |node| {
            if (node.category == .identifier) {
                try expect.equal(node.input_pins.len, 1);
                if (node.input_pins.len == 1 and std.mem.eql(u8, node.input_pins[0].name, "ref")) {
                    saw_identifier_with_ref_input = true;
                }
            }
        }
        try expect.toBeTrue(saw_identifier_with_ref_input);
    }

    test "entry-point heuristic doesn't false-positive on Game-substring types" {
        // `NotAGame` and `MyGameController` both contain "Game" as
        // a substring; the refined word-tokenizing heuristic should
        // reject them.
        const source =
            \\const NotAGame = opaque {};
            \\fn spurious(g: *NotAGame, x: i32) void {
            \\    _ = g;
            \\    _ = x;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.equal(g.entry_points.len, 0);
    }

    test "entry-point heuristic still matches *const Game" {
        // The tokenizer skips `const` and pointer punctuation so
        // `*const Game` still resolves to the `Game` word.
        const source =
            \\const Game = opaque {};
            \\fn handler(g: *const Game, dt: f32) void {
            \\    _ = g;
            \\    _ = dt;
            \\}
        ;
        var g = try projectStr(source);
        defer g.deinit();
        try expect.equal(g.entry_points.len, 1);
    }
};

// ─── Flows reverse navigation (issue #42, Phase 4) ────────────────────

pub const FlowsRevealTests = struct {
    test "vscode-style editor gets --goto file:line" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "code", "/p/scripts/flows/a.zig", 42);
        try expect.toBeTrue(plan.has_line);
        try expect.equal(plan.argv.len, @as(usize, 3));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[0], "code"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "--goto"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[2], "/p/scripts/flows/a.zig:42"));
    }

    test "vim-style editor gets +line before the file" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "nvim", "a.zig", 7);
        try expect.toBeTrue(plan.has_line);
        try expect.equal(plan.argv.len, @as(usize, 3));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "+7"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[2], "a.zig"));
    }

    test "sublime-style editor gets --line N file" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "subl", "a.zig", 12);
        try expect.toBeTrue(plan.has_line);
        try expect.equal(plan.argv.len, @as(usize, 4));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "--line"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[2], "12"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[3], "a.zig"));
    }

    test "editor command with embedded flags keeps the flags" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "code --wait", "a.zig", 3);
        try expect.toBeTrue(plan.has_line);
        try expect.equal(plan.argv.len, @as(usize, 4));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[0], "code"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "--wait"));
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[2], "--goto"));
    }

    test "absolute editor path is matched by basename" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "/usr/local/bin/cursor", "a.zig", 9);
        try expect.toBeTrue(plan.has_line);
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "--goto"));
    }

    test "Windows .exe suffix is stripped before matching" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "Code.exe", "a.zig", 1);
        try expect.toBeTrue(plan.has_line);
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[1], "--goto"));
    }

    test "null editor falls back to the OS file handler" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, null, "a.zig", 5);
        try expect.toBeFalse(plan.has_line);
        try expect.toBeTrue(plan.argv.len >= 2);
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[plan.argv.len - 1], "a.zig"));
    }

    test "unknown editor falls back to the OS file handler" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "some-exotic-editor", "a.zig", 5);
        try expect.toBeFalse(plan.has_line);
        try expect.toBeTrue(std.mem.eql(u8, plan.argv[plan.argv.len - 1], "a.zig"));
    }

    test "empty editor string falls back to the OS file handler" {
        var argv_buf: [8][]const u8 = undefined;
        var scratch: [128]u8 = undefined;
        const plan = flow_reveal.planReveal(&argv_buf, &scratch, "", "a.zig", 5);
        try expect.toBeFalse(plan.has_line);
    }
};

pub const PreferencesTests = struct {
    fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        return std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp.sub_path, prefs.PREFS_FILENAME });
    }

    test "defaults when file is missing" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(std.testing.allocator, tmp);
        defer std.testing.allocator.free(path);

        const loaded = prefs.loadFromPath(std.testing.allocator, path);
        try expect.equal(loaded.font_scale, prefs.default_font_scale);
    }

    test "round-trip preserves value" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(std.testing.allocator, tmp);
        defer std.testing.allocator.free(path);

        try prefs.saveToPath(std.testing.allocator, path, .{ .font_scale = 1.5 });

        const loaded = prefs.loadFromPath(std.testing.allocator, path);
        try expect.equal(loaded.font_scale, @as(f32, 1.5));
    }

    test "save clamps oversized values" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(std.testing.allocator, tmp);
        defer std.testing.allocator.free(path);

        try prefs.saveToPath(std.testing.allocator, path, .{ .font_scale = 9.0 });

        const loaded = prefs.loadFromPath(std.testing.allocator, path);
        try expect.equal(loaded.font_scale, prefs.max_font_scale);
    }

    test "load clamps undersized values" {
        // Simulates a hand-edited prefs file with an out-of-bounds value
        // — load is expected to clamp on the way in so the rest of the
        // app sees only valid scales.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(std.testing.allocator, tmp);
        defer std.testing.allocator.free(path);

        const hand_edited = ".{ .font_scale = 0.1 }\n";
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = hand_edited,
        });

        const loaded = prefs.loadFromPath(std.testing.allocator, path);
        try expect.equal(loaded.font_scale, prefs.min_font_scale);
    }

    test "malformed file falls back to defaults" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const path = try tmpPath(std.testing.allocator, tmp);
        defer std.testing.allocator.free(path);

        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = "this is not zon",
        });

        const loaded = prefs.loadFromPath(std.testing.allocator, path);
        try expect.equal(loaded.font_scale, prefs.default_font_scale);
    }
};

pub const PrefabContentsTests = struct {
    test "consecutivePrefabRunEnd groups consecutive same-prefab children" {
        const children = [_]scene_io.Entity{
            .{ .prefab = "seat" },
            .{ .prefab = "seat" },
            .{ .prefab = "seat" },
            .{ .prefab = "table" },
        };
        try expect.equal(prefab_contents.consecutivePrefabRunEnd(&children, 0, "seat"), 3);
        try expect.equal(prefab_contents.consecutivePrefabRunEnd(&children, 3, "table"), 4);
    }

    test "consecutivePrefabRunEnd stops at a child without a prefab" {
        const children = [_]scene_io.Entity{
            .{ .prefab = "seat" },
            .{ .prefab = null },
            .{ .prefab = "seat" },
        };
        try expect.equal(prefab_contents.consecutivePrefabRunEnd(&children, 0, "seat"), 1);
    }

    test "consecutivePrefabRunEnd returns end of slice for a single trailing run" {
        const children = [_]scene_io.Entity{
            .{ .prefab = "only" },
        };
        try expect.equal(prefab_contents.consecutivePrefabRunEnd(&children, 0, "only"), 1);
    }
};

pub const ScenesAvailableTests = struct {
    // `Project.scenesAvailable` is the data source for the Run-button
    // scene picker (#132). The picker assumes basenames, alphabetical
    // order, top-level `.jsonc` only. These tests lock those shape
    // contracts so a future tweak (e.g. recursing into subdirs) flags
    // up before it surprises the UI code.

    fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const tmp_base = "/tmp";
        const ts = timestampSeconds();
        // Disambiguate by both ts and an incrementing index so two tests
        // running back-to-back inside the same second don't collide on
        // the same temp dir.
        const Counter = struct {
            var i: u64 = 0;
        };
        Counter.i += 1;
        const dir_name = try std.fmt.allocPrint(allocator, "{s}/labelle_scenes_{d}_{d}", .{ tmp_base, ts, Counter.i });
        try std.Io.Dir.cwd().createDir(io_global.io(), dir_name, .default_dir);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.Io.Dir.cwd().deleteTree(io_global.io(), dir_path) catch {};
        allocator.free(dir_path);
    }

    fn touchFile(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) !void {
        const path = try std.fs.path.join(allocator, &.{ dir_path, name });
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = "{ \"entities\": {} }\n",
        });
    }

    test "returns empty slice when project has no dir" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "no_dir");
        defer proj.deinit();
        const scenes = try proj.scenesAvailable(allocator);
        try expect.equal(scenes.len, 0);
    }

    test "returns empty slice when scenes/ is missing" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("missing_scenes");
        // Don't call saveProject — it scaffolds `scenes/`. Force-set the
        // dir so the lookup runs.
        pm.current_project.?.dir = try pm.current_project.?.arena.allocator().dupe(u8, temp_dir);

        const scenes = try pm.current_project.?.scenesAvailable(allocator);
        try expect.equal(scenes.len, 0);
    }

    test "lists *.jsonc files alphabetically by stem" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("scenes_test");
        try pm.saveProject(temp_dir);

        const scenes_dir = try std.fs.path.join(allocator, &.{ temp_dir, "scenes" });
        defer allocator.free(scenes_dir);

        // Drop files in a non-alphabetical order to prove the sort step
        // runs.
        try touchFile(allocator, scenes_dir, "main.jsonc");
        try touchFile(allocator, scenes_dir, "debug.jsonc");
        try touchFile(allocator, scenes_dir, "menu.jsonc");

        const scenes = try pm.current_project.?.scenesAvailable(allocator);
        try expect.equal(scenes.len, 3);
        try std.testing.expectEqualStrings(scenes[0], "debug");
        try std.testing.expectEqualStrings(scenes[1], "main");
        try std.testing.expectEqualStrings(scenes[2], "menu");
    }

    test "ignores non-jsonc files and subdirectories" {
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("scenes_test");
        try pm.saveProject(temp_dir);

        const scenes_dir = try std.fs.path.join(allocator, &.{ temp_dir, "scenes" });
        defer allocator.free(scenes_dir);

        try touchFile(allocator, scenes_dir, "main.jsonc");
        try touchFile(allocator, scenes_dir, "README.md");
        try touchFile(allocator, scenes_dir, "main.json"); // wrong extension

        // Subdir scenes are out of scope for the v1 picker — the
        // launcher's `--scene=<name>` flag only accepts a single name,
        // not a path. Drop a nested file to assert it's skipped.
        const nested = try std.fs.path.join(allocator, &.{ scenes_dir, "debug" });
        defer allocator.free(nested);
        try std.Io.Dir.cwd().createDir(io_global.io(), nested, .default_dir);
        try touchFile(allocator, nested, "main.jsonc");

        const scenes = try pm.current_project.?.scenesAvailable(allocator);
        try expect.equal(scenes.len, 1);
        try std.testing.expectEqualStrings(scenes[0], "main");
    }

    test "caches the result across repeated calls" {
        // The picker hits this on every render; make sure repeat calls
        // return the same slice (identity check) rather than re-walking
        // the filesystem and reallocating.
        const allocator = std.testing.allocator;
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("scenes_cache");
        try pm.saveProject(temp_dir);

        const scenes_dir = try std.fs.path.join(allocator, &.{ temp_dir, "scenes" });
        defer allocator.free(scenes_dir);
        try touchFile(allocator, scenes_dir, "main.jsonc");

        const first = try pm.current_project.?.scenesAvailable(allocator);
        const second = try pm.current_project.?.scenesAvailable(allocator);
        try expect.equal(first.ptr, second.ptr);
        try expect.equal(first.len, second.len);
    }
};

pub const PreviewSpawnArgvTests = struct {
    // Regression-lock the argv shape `preview.start` passes to
    // `std.process.spawn` (#131 / #132). The launcher integration is
    // covered by `zig build smoke`; this is the pure-formatter side.

    test "no scene override matches the post-#130 argv shape (env-var, no --preview-mode)" {
        var argv_buf: [16][]const u8 = undefined;
        var scene_buf: [128]u8 = undefined;
        const argv = try preview.buildSpawnArgv(
            &argv_buf,
            &scene_buf,
            "/projects/game",
            null,
        );
        try expect.equal(argv.len, 3);
        try std.testing.expectEqualStrings(argv[0], "labelle");
        try std.testing.expectEqualStrings(argv[1], "run");
        try std.testing.expectEqualStrings(argv[2], "/projects/game");
        // Regression-lock the bug from PR #130: argv MUST NOT include
        // `--preview-mode` — the labelle CLI doesn't define it. The
        // host:port goes through `LABELLE_PREVIEW` env var instead.
        for (argv) |a| try expect.toBeFalse(std.mem.eql(u8, a, "--preview-mode"));
    }

    test "scene override appends --scene=<name>" {
        var argv_buf: [16][]const u8 = undefined;
        var scene_buf: [128]u8 = undefined;
        const argv = try preview.buildSpawnArgv(
            &argv_buf,
            &scene_buf,
            "/projects/game",
            "level2",
        );
        try expect.equal(argv.len, 4);
        try std.testing.expectEqualStrings(argv[3], "--scene=level2");
    }

    test "OOM when scene name overflows the scene buffer" {
        // Names this long can't reach the launcher (the picker only
        // surfaces filenames the OS already accepted), but the bounded
        // buffer should reject them cleanly rather than truncating.
        var argv_buf: [16][]const u8 = undefined;
        var scene_buf: [128]u8 = undefined;
        const oversize = "x" ** 200;
        const got = preview.buildSpawnArgv(
            &argv_buf,
            &scene_buf,
            "/d",
            oversize[0..],
        );
        try std.testing.expectError(error.OutOfMemory, got);
    }
};

pub const PreviewTransportTests = struct {
    // Drives `PreviewSession` end-to-end against an in-test fake
    // engine that dials the editor's listener and writes JSON
    // frames. Subprocess spawn is **not** exercised here — tests
    // use `bindListener` instead of `start(proj)` to skip the
    // `labelle run` invocation.

    const Timespec = extern struct { sec: isize, nsec: isize };
    extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
    fn sleepMs(ms: u64) void {
        const ts: Timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = nanosleep(&ts, null);
    }

    extern "c" fn connect(fd: c_int, addr: *const std.posix.sockaddr.in, len: std.posix.socklen_t) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn close(fd: c_int) c_int;

    /// Dial the editor's listener as if we were a freshly-spawned
    /// engine. Returns the connected fd; caller writes JSON frames
    /// via `write(2)`.
    fn dialEditor(port: u16) !c_int {
        const sock_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (sock_fd < 0) return error.SocketFailed;
        const addr: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        const rc = connect(@intCast(sock_fd), &addr, @sizeOf(@TypeOf(addr)));
        if (rc < 0) return error.ConnectFailed;
        return @intCast(sock_fd);
    }

    fn sendJsonLine(fd: c_int, body: []const u8) !void {
        var off: usize = 0;
        while (off < body.len) {
            const n = write(fd, body.ptr + off, body.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    /// Poll the session until `predicate` returns true or the
    /// deadline expires. Mirrors the engine-side `waitFor` pattern.
    fn waitUntilState(p: *preview.PreviewSession, target: preview.State, deadline_ms: u64) !void {
        var slept: u64 = 0;
        while (slept < deadline_ms) {
            p.poll();
            if (p.state == target) return;
            sleepMs(2);
            slept += 2;
        }
        return error.DeadlineExceeded;
    }

    test "bindListener picks a port and lands in .listening" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();

        try sess.bindListener();
        try expect.equal(sess.state, preview.State.listening);
        try expect.toBeTrue(sess.port != null);
        try expect.toBeTrue(sess.port.? != 0);
    }

    test "hello frame transitions .connecting → .running and records engine_pid" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        const port = sess.port.?;
        const fd = try dialEditor(port);
        // give the kernel a beat to land the SYN
        try waitUntilState(&sess, .connecting, 500);

        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"1.37.1\",\"pid\":12345,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);
        try expect.equal(sess.engine_pid.?, @as(i64, 12345));

        _ = close(fd);
    }

    test "frame_offer fires on_frame_offer callback with shm_name + dims + format" {
        const Capture = struct {
            var got_name: [64]u8 = [_]u8{0} ** 64;
            var got_name_len: usize = 0;
            var got_width: u32 = 0;
            var got_height: u32 = 0;
            var got_format: [64]u8 = [_]u8{0} ** 64;
            var got_format_len: usize = 0;
            var fired: bool = false;

            fn cb(_: *anyopaque, name: [:0]const u8, w: u32, h: u32, format: []const u8) void {
                fired = true;
                got_name_len = @min(name.len, got_name.len);
                @memcpy(got_name[0..got_name_len], name[0..got_name_len]);
                got_width = w;
                got_height = h;
                got_format_len = @min(format.len, got_format.len);
                @memcpy(got_format[0..got_format_len], format[0..got_format_len]);
            }
        };
        Capture.fired = false;
        Capture.got_name_len = 0;
        Capture.got_width = 0;
        Capture.got_height = 0;
        Capture.got_format_len = 0;

        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();
        sess.on_frame_offer = .{ .ctx = &Capture.fired, .func = Capture.cb };

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"x\",\"pid\":1,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        try sendJsonLine(fd,
            "{\"kind\":\"frame_offer\",\"shm_name\":\"/lbl-test\",\"width\":640,\"height\":360,\"format\":\"bgra8\",\"ring_size\":3,\"slot_size_bytes\":921600}\n");

        // poll for ~500 ms waiting for the callback
        var i: u32 = 0;
        while (i < 250 and !Capture.fired) : (i += 1) {
            sess.poll();
            sleepMs(2);
        }
        try expect.toBeTrue(Capture.fired);
        try std.testing.expectEqualStrings(Capture.got_name[0..Capture.got_name_len], "/lbl-test");
        try expect.equal(Capture.got_width, @as(u32, 640));
        try expect.equal(Capture.got_height, @as(u32, 360));
        try std.testing.expectEqualStrings(Capture.got_format[0..Capture.got_format_len], "bgra8");

        _ = close(fd);
    }

    test "frame_offer forwards format=iosurface_bgra8 to the callback" {
        // The format-dispatch wiring lives in App.attachGameView / the
        // GameView consumer; this test stops one level shy of that, at
        // the JSON parser. We assert the parser hands the borrowed
        // slice through verbatim — App reads it to pick shm vs iosurface
        // transport (`src/game_view.zig`).
        const Capture = struct {
            var got_format: [64]u8 = [_]u8{0} ** 64;
            var got_format_len: usize = 0;
            var fired: bool = false;

            fn cb(_: *anyopaque, _: [:0]const u8, _: u32, _: u32, format: []const u8) void {
                fired = true;
                got_format_len = @min(format.len, got_format.len);
                @memcpy(got_format[0..got_format_len], format[0..got_format_len]);
            }
        };
        Capture.fired = false;
        Capture.got_format_len = 0;

        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();
        sess.on_frame_offer = .{ .ctx = &Capture.fired, .func = Capture.cb };

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"x\",\"pid\":1,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        try sendJsonLine(fd,
            "{\"kind\":\"frame_offer\",\"shm_name\":\"/lbl-ios\",\"width\":1280,\"height\":720,\"format\":\"iosurface_bgra8\",\"ring_size\":3}\n");

        var i: u32 = 0;
        while (i < 250 and !Capture.fired) : (i += 1) {
            sess.poll();
            sleepMs(2);
        }
        try expect.toBeTrue(Capture.fired);
        try std.testing.expectEqualStrings(Capture.got_format[0..Capture.got_format_len], "iosurface_bgra8");

        _ = close(fd);
    }

    test "bye frame transitions .running → .stopped and records reason" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":7,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);
        try sendJsonLine(fd, "{\"kind\":\"bye\",\"reason\":\"normal\"}\n");
        try waitUntilState(&sess, .stopped, 500);
        try std.testing.expectEqualStrings(sess.bye_reason.?, "normal");

        _ = close(fd);
    }

    test "EOF without bye lands in .crashed" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":7,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // Hard-close the engine fd without bye.
        _ = close(fd);
        try waitUntilState(&sess, .crashed, 500);
    }

    // ── #79: heartbeat watchdog ───────────────────────────────────
    // A `.running` session whose engine goes silent (socket still
    // open, no traffic) must land in `.crashed` once the watchdog
    // window elapses — without this the editor sat in a stale
    // `.running` forever showing a frozen "last heartbeat".

    test "heartbeat watchdog fires when a connected engine goes silent" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":7,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // Engine never writes again, but the socket stays open — the
        // wedged-but-connected case. The watchdog should trip after
        // `heartbeat_timeout_ms`. Poll well past the window.
        const deadline: u64 = @intCast(preview.heartbeat_timeout_ms + 2_000);
        try waitUntilState(&sess, .crashed, deadline);
        const reason = sess.bye_reason orelse "";
        try expect.toBeTrue(std.mem.indexOf(u8, reason, "heartbeat") != null);

        _ = close(fd);
    }

    test "heartbeat traffic keeps a session in .running past the watchdog window" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":7,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // Drip heartbeats for longer than `heartbeat_timeout_ms`,
        // spaced well inside the window. The session must NOT trip
        // the watchdog — a live engine should never see a false
        // `.crashed`.
        const span: i64 = preview.heartbeat_timeout_ms + 1_000;
        var elapsed: i64 = 0;
        const step: i64 = @divTrunc(preview.heartbeat_timeout_ms, 4);
        while (elapsed < span) : (elapsed += step) {
            try sendJsonLine(fd, "{\"kind\":\"heartbeat\",\"t\":1}\n");
            var s: i64 = 0;
            while (s < step) : (s += 10) {
                sess.poll();
                sleepMs(10);
            }
            try expect.equal(sess.state, preview.State.running);
        }

        try sendJsonLine(fd, "{\"kind\":\"bye\",\"reason\":\"normal\"}\n");
        try waitUntilState(&sess, .stopped, 500);

        _ = close(fd);
    }

    test "heartbeatAgeMs is null before hello and bounded after" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();
        // No engine yet — no receive clock.
        try expect.toBeTrue(sess.heartbeatAgeMs() == null);

        const fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":7,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // After the handshake the age is a real, small value.
        const age = sess.heartbeatAgeMs() orelse return error.AgeMissing;
        try expect.toBeTrue(age >= 0);
        try expect.toBeTrue(age < preview.heartbeat_timeout_ms);

        _ = close(fd);
    }
};

pub const PreviewLiveStderrTests = struct {
    // Covers the #127 live-tail mechanism:
    //  - `consumeStderr` returns newly-arrived bytes once and advances
    //    the internal cursor so a second call returns an empty slice.
    //  - The cursor resets on `bindListener` so a fresh Run doesn't
    //    inherit a stale cursor.
    //
    // Driven directly against `stderr_buf` (an exported field on the
    // session struct) so the test stays hermetic — no real subprocess
    // is spawned. The end-to-end `drainChildStderr` path is exercised
    // by the subprocess-exit test below and by `zig build smoke`.

    test "consumeStderr yields fresh bytes once and advances the cursor" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();

        // Simulate two batches of stderr arriving from a hypothetical
        // subprocess. `drainChildStderr` would do this for us in the
        // production path; we inject directly to stay subprocess-free.
        try sess.stderr_buf.appendSlice(std.testing.allocator, "compiling foo.zig\n");
        const first = sess.consumeStderr();
        try std.testing.expectEqualStrings(first, "compiling foo.zig\n");

        // No new bytes arrived since the last consume — the next call
        // returns an empty slice (panel renders nothing new this frame).
        const empty = sess.consumeStderr();
        try expect.equal(empty.len, @as(usize, 0));

        // A second batch arrives. `consumeStderr` returns only the new
        // bytes, not the original batch (cursor was advanced past it).
        try sess.stderr_buf.appendSlice(std.testing.allocator, "compiling bar.zig\n");
        const second = sess.consumeStderr();
        try std.testing.expectEqualStrings(second, "compiling bar.zig\n");

        // The full buffer is still accessible via `capturedStderr`
        // (the crash-tail surface) so the on-crash panel still shows
        // everything the subprocess wrote across the whole session.
        try std.testing.expectEqualStrings(sess.capturedStderr(), "compiling foo.zig\ncompiling bar.zig\n");
    }

    test "bindListener resets the consumeStderr cursor and buffer" {
        // Run #1 leaves a non-empty stderr_buf and a partially-consumed
        // cursor. Run #2 (`bindListener`) must reset both — otherwise
        // the panel would see stale bytes from the previous build.
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();
        try sess.stderr_buf.appendSlice(std.testing.allocator, "stale output\n");
        _ = sess.consumeStderr();
        try expect.equal(sess.stderr_cursor, @as(usize, "stale output\n".len));

        // Land in `.stopped` (the legal restart-from state) before the
        // fresh `bindListener` — same path the user takes when they
        // press Stop and then Run again.
        sess.stop();
        try sess.bindListener();
        try expect.equal(sess.stderr_buf.items.len, @as(usize, 0));
        try expect.equal(sess.stderr_cursor, @as(usize, 0));
        const fresh = sess.consumeStderr();
        try expect.equal(fresh.len, @as(usize, 0));
    }

    // tryWaitChild integration: a real subprocess (`/usr/bin/false`)
    // is spawned, it exits with code 1 immediately, and `poll` is
    // expected to land the session in `.crashed` *before* the
    // 60-second `connecting_timeout_ms` window — the whole point of
    // the subprocess-exit early-crash detection (#127, #136).
    //
    // `/usr/bin/false` is part of the POSIX base on every machine
    // this codebase is expected to run on (macOS, Linux, CI). No
    // network or labelle-cli needed.
    const Timespec = extern struct { sec: isize, nsec: isize };
    extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
    fn sleepMs(ms: u64) void {
        const ts: Timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = nanosleep(&ts, null);
    }

    extern "c" fn connect(fd: c_int, addr: *const std.posix.sockaddr.in, len: std.posix.socklen_t) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn close(fd: c_int) c_int;

    /// Dial the editor's listener as a freshly-spawned engine would.
    /// Mirrors `PreviewTransportTests.dialEditor`.
    fn dialEditor(port: u16) !c_int {
        const sock_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (sock_fd < 0) return error.SocketFailed;
        const addr: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        const rc = connect(@intCast(sock_fd), &addr, @sizeOf(@TypeOf(addr)));
        if (rc < 0) return error.ConnectFailed;
        return @intCast(sock_fd);
    }

    fn sendJsonLine(fd: c_int, body: []const u8) !void {
        var off: usize = 0;
        while (off < body.len) {
            const n = write(fd, body.ptr + off, body.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn waitUntilState(p: *preview.PreviewSession, target: preview.State, deadline_ms: u64) !void {
        var slept: u64 = 0;
        while (slept < deadline_ms) {
            p.poll();
            if (p.state == target) return;
            sleepMs(2);
            slept += 2;
        }
        return error.DeadlineExceeded;
    }

    test "stderr_buf rotates when over cap so live tail keeps surfacing recent bytes" {
        // The non-rotating version of `drainChildStderr` froze at 16
        // KiB — once full it stopped appending, hiding the build
        // error that lands at the END of zig's output. The rotating
        // version drops oldest bytes from the front and adjusts the
        // consumeStderr cursor so the live-tail consumer keeps
        // observing fresh data.
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();

        // Fill exactly to the cap with 'A's, drain via consumeStderr
        // so the cursor advances to the end, then push 1024 'B's
        // past the cap.
        const cap: usize = 16 * 1024;
        var filler: [1024]u8 = undefined;
        @memset(&filler, 'A');
        var pushed: usize = 0;
        while (pushed < cap) {
            sess.appendStderrChunk(&filler);
            pushed += filler.len;
        }
        try expect.equal(sess.stderr_buf.items.len, cap);
        const drained_first = sess.consumeStderr();
        try expect.equal(drained_first.len, cap);
        try expect.equal(sess.stderr_cursor, cap);

        // Push a B-block past the cap — front should drop and the
        // cursor should slide back so subsequent reads see ONLY the
        // freshly-arrived bytes (not stale A's).
        var b_block: [1024]u8 = undefined;
        @memset(&b_block, 'B');
        sess.appendStderrChunk(&b_block);
        try expect.equal(sess.stderr_buf.items.len, cap);
        // Last 1024 bytes are B's, rest are still A's.
        try expect.toBeTrue(sess.stderr_buf.items[cap - 1] == 'B');
        try expect.toBeTrue(sess.stderr_buf.items[0] == 'A');
        const drained_second = sess.consumeStderr();
        // We dropped 1024 from the front and appended 1024 — cursor
        // had been at `cap` (i.e. fully drained), shifted to
        // `cap - 1024`, then `appendSlice` grew the buffer to `cap`
        // again. So fresh = exactly the 1024 newest bytes.
        try expect.equal(drained_second.len, @as(usize, 1024));
        try expect.toBeTrue(drained_second[0] == 'B');
        try expect.toBeTrue(drained_second[drained_second.len - 1] == 'B');
    }

    test "a single oversized chunk keeps only the tail of the chunk" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        const cap: usize = 16 * 1024;
        const chunk = std.testing.allocator.alloc(u8, cap + 4096) catch unreachable;
        defer std.testing.allocator.free(chunk);
        @memset(chunk[0..4096], 'A');
        @memset(chunk[4096..], 'B');
        sess.appendStderrChunk(chunk);
        // The leading 'A's should be entirely dropped — only the
        // tail 16 KiB of 'B's survives.
        try expect.equal(sess.stderr_buf.items.len, cap);
        try expect.toBeTrue(sess.stderr_buf.items[0] == 'B');
        try expect.toBeTrue(sess.stderr_buf.items[cap - 1] == 'B');
        try expect.equal(sess.stderr_cursor, @as(usize, 0));
    }

    test "subprocess-exit early detection transitions .listening → .crashed before the 60s timeout" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        try sess.bindListener();
        try expect.equal(sess.state, preview.State.listening);

        // Spawn a child that exits immediately with a non-zero code.
        // The `/usr/bin/false` binary is present on macOS, Linux,
        // and the CI image. Stderr piped so `drainChildStderr` has a
        // valid fd to poll (the production path always pipes stderr).
        const argv = &[_][]const u8{"/usr/bin/false"};
        const child = std.process.spawn(io_global.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            // If we're on an exotic platform without /usr/bin/false,
            // skip rather than fail — the production preview path
            // depends on `labelle` being on PATH anyway, which is
            // a stricter environmental assumption.
            std.debug.print("skip: /usr/bin/false unavailable ({s})\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        sess.child = child;

        // Wait for the child to exit and `poll` to observe it via
        // `waitpid(WNOHANG)`. 2 s is generous — `/usr/bin/false`
        // exits in microseconds, and the cap is intentionally far
        // below the 60 s `connecting_timeout_ms` backstop so the
        // assertion proves the early-detection path (not the fallback).
        var slept: u64 = 0;
        while (slept < 2000) {
            sess.poll();
            if (sess.state == .crashed) break;
            sleepMs(5);
            slept += 5;
        }
        try expect.equal(sess.state, preview.State.crashed);
        // The reason should reflect the exit code, not the timeout
        // message ("engine never connected") — that's how we know
        // the early-detection branch fired.
        const reason = sess.bye_reason orelse "";
        try expect.toBeTrue(std.mem.indexOf(u8, reason, "labelle exited") != null);
    }

    // #79: a clean (code 0) child exit while the session is `.running`
    // is the engine shutting itself down — the user closed the game
    // window. It must land in `.stopped`, NOT `.crashed`, even when no
    // `bye` frame ever arrives.
    //
    // This drives the *real* EOF-vs-waitpid race deterministically. A
    // genuine engine shutdown closes its TCP socket as part of process
    // teardown — the kernel can deliver the socket FIN (so `read`
    // returns 0) while the process is still mid-exit and NOT yet a
    // reapable zombie. At the `poll` that sees that EOF,
    // `waitpid(WNOHANG)` still returns 0. The buggy code `markCrashed`s
    // on that EOF (`tryWaitChild` can't yet see the exit code) and lands
    // `.crashed`; the fixed code records the EOF as *pending*, waits for
    // a later poll to reap the child, and lands `.stopped` with the real
    // exit code.
    //
    // Two subtleties this test gets right (the earlier version got both
    // wrong, so it passed even with the bug present):
    //
    //  1. The child is spawned AFTER `bindListener` but BEFORE the
    //     engine socket is dialed. After `dialEditor`, a freshly forked
    //     child would inherit a copy of the connection fd (no
    //     `O_CLOEXEC`), so `close(engine_fd)` in the test would NOT
    //     deliver a FIN — the editor's `conn_fd` would never see EOF
    //     until the child itself exited, and by then `waitpid` reaps it
    //     the same tick. No race. Spawning before `dialEditor` means the
    //     connection fd doesn't exist at fork time. (Spawning before
    //     `bindListener` doesn't work either — `bindListener` kills and
    //     nulls any pre-existing `sess.child` as leftover-cycle cleanup.)
    //
    //  2. `close(engine_fd)` happens while the child is provably still
    //     sleeping, and a short sleep guarantees the loopback FIN is
    //     delivered before the racing `poll`. That poll sees EOF with
    //     the child un-reapable — the precise #79 window.
    test "clean child exit while running lands in .stopped not .crashed (EOF races waitpid)" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();

        // Bind the listener first (it would kill a pre-existing child),
        // then spawn the engine subprocess — before any connection
        // socket exists — so the child cannot inherit the connection fd.
        // The child stays alive ~800 ms then exits cleanly (code 0): the
        // subprocess half of a normal Run → play → close-window
        // shutdown, slow enough that the race window is open during the
        // handshake + the racing poll below.
        try sess.bindListener();
        const argv = &[_][]const u8{ "/bin/sleep", "0.8" };
        const child = std.process.spawn(io_global.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            std.debug.print("skip: /bin/sleep unavailable ({s})\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        sess.child = child;

        // Now establish a real connected engine socket and reach
        // `.running` via the `hello` handshake, so `sess.conn_fd >= 0`
        // and `tryRead` is live. This connection fd post-dates the fork,
        // so the child does not hold a copy of it.
        const engine_fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(engine_fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":1,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // Close the engine-side socket NOW, while the child is still
        // sleeping (not yet a zombie). The short sleep guarantees the
        // loopback FIN has been delivered so the next `poll`'s `tryRead`
        // deterministically observes EOF — but it's far below the
        // child's 0.8 s lifetime, so `waitpid(WNOHANG)` still returns 0
        // (child un-reapable) at that same poll. That is the exact #79
        // race. The buggy code crashes here; the fixed code records the
        // EOF as pending and stays `.running`.
        _ = close(engine_fd);
        sleepMs(40);
        sess.poll();
        // Right after the racing poll: the buggy build has already
        // transitioned to `.crashed` on the EOF. The fixed build is
        // still `.running` with the EOF deferred — this is the
        // assertion that actually catches the bug.
        try expect.equal(sess.state, preview.State.running);

        // Now let the sleep finish and subsequent polls reap it.
        var slept: u64 = 0;
        while (slept < 3000) {
            sess.poll();
            if (sess.state != .running) break;
            sleepMs(5);
            slept += 5;
        }
        try expect.equal(sess.state, preview.State.stopped);
        // The reason must come from the clean exit-code path, not the
        // EOF "connection closed" crash string — that's how we know
        // the deferred EOF resolved via `tryWaitChild`'s exit status.
        const reason = sess.bye_reason orelse "";
        try expect.toBeTrue(std.mem.indexOf(u8, reason, "labelle exited") != null);
    }

    // #79 counterpart: the deferred-EOF fix must NOT swallow a genuine
    // mid-session crash. Same race ordering — socket EOF observed while
    // the child is still un-reapable — but here the child exits with a
    // non-zero code. The session must still land `.crashed`, and the
    // reason must carry the exit code (proving the crash verdict came
    // from the reaped exit status, not the generic EOF string).
    test "non-zero child exit while running still lands in .crashed (EOF races waitpid)" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();

        // Bind first, then spawn before dialing (see the clean-exit test
        // above for the fd-inheritance / `bindListener`-kill reasons).
        // `sh -c 'sleep 0.8; exit 3'` — alive long enough to lose the
        // race, then a non-zero exit standing in for a real engine
        // crash.
        try sess.bindListener();
        const argv = &[_][]const u8{ "/bin/sh", "-c", "sleep 0.8; exit 3" };
        const child = std.process.spawn(io_global.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        }) catch |err| {
            std.debug.print("skip: /bin/sh unavailable ({s})\n", .{@errorName(err)});
            return error.SkipZigTest;
        };
        sess.child = child;

        const engine_fd = try dialEditor(sess.port.?);
        try waitUntilState(&sess, .connecting, 500);
        try sendJsonLine(engine_fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":1,\"protocol_version\":1}\n");
        try waitUntilState(&sess, .running, 500);

        // EOF the socket while the child is still running, then poll
        // into the race window — same ordering as the clean-exit test.
        _ = close(engine_fd);
        sleepMs(40);
        sess.poll();
        // The deferred-EOF fix keeps the session `.running` here — the
        // crash verdict must come from the reaped exit code, not the EOF.
        try expect.equal(sess.state, preview.State.running);

        var slept: u64 = 0;
        while (slept < 3000) {
            sess.poll();
            if (sess.state != .running) break;
            sleepMs(5);
            slept += 5;
        }
        try expect.equal(sess.state, preview.State.crashed);
        // Exit code 3 must surface — confirms the crash verdict came
        // from the reaped exit status, not the "connection closed" EOF
        // fallback.
        const reason = sess.bye_reason orelse "";
        try expect.toBeTrue(std.mem.indexOf(u8, reason, "code 3") != null);
    }
};

pub const IOSurfaceLayoutTests = struct {
    // The iosurface.ControlBlock layout has to match what the engine's
    // (future) iosurface producer writes into shm slot 0. Layout
    // changes break the protocol — keep these comptime-correlated to
    // catch a drift between either side.

    const iosurface = @import("iosurface.zig");

    test "ControlBlock magic is the four-CC the producer expects" {
        // 'IOSRFCL1' big-endian → 0x494F535246434C31. The PoC's
        // producer expects this exact value; the engine producer
        // follow-up will match.
        try expect.equal(iosurface.ControlBlock.MAGIC, @as(u64, 0x494F535246434C31));
    }

    test "ControlBlock size matches the documented layout" {
        // 24 fixed bytes (magic + ring_size + pixel_format + width +
        // height) + MAX_RING * 4 (ids) + 16 pad. The comptime assert
        // inside iosurface.zig guards this; the test reads the asserted
        // value so a drift surfaces as a test failure too.
        const expected = 24 + iosurface.MAX_RING * 4 + 16;
        try expect.equal(@sizeOf(iosurface.ControlBlock), expected);
    }

    test "BGRA8 pixel format constant matches CGLTexImageIOSurface2D's expectation" {
        // 'BGRA' four-CC = 0x42475241.
        try expect.equal(iosurface.kPixelFormat_BGRA8, @as(u32, 0x42475241));
    }

    test "MAX_RING bounds the ControlBlock id array" {
        // Catches a silent reduction of MAX_RING that'd shrink the
        // struct under what the engine producer might still send.
        try expect.equal(iosurface.MAX_RING, @as(u32, 8));
    }
};

pub const PreviewBinaryPlaneTests = struct {
    // Drives `PreviewSession` end-to-end against an in-test fake
    // engine that dials the editor's listener and writes hand-built
    // binary plane frames (the format `labelle-engine`'s
    // `preview_mode.zig` emits via `writeBinaryFrame`). Mirrors
    // `PreviewTransportTests` for the JSON control plane (#112).

    const Timespec = extern struct { sec: isize, nsec: isize };
    extern "c" fn nanosleep(req: *const Timespec, rem: ?*Timespec) c_int;
    fn sleepMs(ms: u64) void {
        const ts: Timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
        _ = nanosleep(&ts, null);
    }

    extern "c" fn connect(fd: c_int, addr: *const std.posix.sockaddr.in, len: std.posix.socklen_t) c_int;
    extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
    extern "c" fn close(fd: c_int) c_int;

    fn dialEditor(port: u16) !c_int {
        const sock_fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (sock_fd < 0) return error.SocketFailed;
        const addr: std.posix.sockaddr.in = .{
            .family = std.posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
            .zero = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };
        const rc = connect(@intCast(sock_fd), &addr, @sizeOf(@TypeOf(addr)));
        if (rc < 0) return error.ConnectFailed;
        return @intCast(sock_fd);
    }

    fn writeAll(fd: c_int, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = write(fd, bytes.ptr + off, bytes.len - off);
            if (n <= 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn waitUntilState(p: *preview.PreviewSession, target: preview.State, deadline_ms: u64) !void {
        var slept: u64 = 0;
        while (slept < deadline_ms) {
            p.poll();
            if (p.state == target) return;
            sleepMs(2);
            slept += 2;
        }
        return error.DeadlineExceeded;
    }

    // Boilerplate: bind editor listener, dial from the fake engine,
    // send `hello`, wait until `.running`. Returns the engine-side
    // fd. Caller closes it.
    fn connectPair(sess: *preview.PreviewSession) !c_int {
        try sess.bindListener();
        const fd = try dialEditor(sess.port.?);
        try waitUntilState(sess, .connecting, 500);
        try writeAll(fd, "{\"kind\":\"hello\",\"engine_version\":\"\",\"pid\":1,\"protocol_version\":1}\n");
        try waitUntilState(sess, .running, 500);
        return fd;
    }

    // Write a binary frame header [u8 magic] [u8 kind] [u32 len-LE]
    // followed by `payload`, mirroring engine-side `writeBinaryFrame`.
    fn writeBinaryFrame(fd: c_int, kind: preview.BinaryFrameKind, payload: []const u8) !void {
        var header: [6]u8 = undefined;
        header[0] = preview.binary_magic;
        header[1] = @intFromEnum(kind);
        std.mem.writeInt(u32, header[2..6], @intCast(payload.len), .little);
        try writeAll(fd, &header);
        if (payload.len > 0) try writeAll(fd, payload);
    }

    // Poll the session until `predicate` returns true or the deadline
    // expires. Used for callback-firing tests where state doesn't
    // transition.
    fn waitUntil(sess: *preview.PreviewSession, ctx: anytype, predicate: *const fn (@TypeOf(ctx)) bool, deadline_ms: u64) !void {
        var slept: u64 = 0;
        while (slept < deadline_ms) {
            sess.poll();
            if (predicate(ctx)) return;
            sleepMs(2);
            slept += 2;
        }
        return error.DeadlineExceeded;
    }

    test "component_changed binary frame fires on_component_changed callback" {
        const Capture = struct {
            var fired: bool = false;
            var got_entity: u64 = 0;
            var got_name: [64]u8 = [_]u8{0} ** 64;
            var got_name_len: usize = 0;
            var got_bytes: [128]u8 = [_]u8{0} ** 128;
            var got_bytes_len: usize = 0;

            fn cb(_: *anyopaque, entity_id: u64, name: []const u8, bytes: []const u8) void {
                fired = true;
                got_entity = entity_id;
                got_name_len = @min(name.len, got_name.len);
                @memcpy(got_name[0..got_name_len], name[0..got_name_len]);
                got_bytes_len = @min(bytes.len, got_bytes.len);
                @memcpy(got_bytes[0..got_bytes_len], bytes[0..got_bytes_len]);
            }
        };
        Capture.fired = false;
        Capture.got_entity = 0;
        Capture.got_name_len = 0;
        Capture.got_bytes_len = 0;

        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        sess.on_component_changed = .{ .ctx = &Capture.fired, .func = Capture.cb };
        const fd = try connectPair(&sess);
        defer _ = close(fd);

        // Payload: [u64 entity_id=42] [u16 name_len=8] ["Position"]
        //          [u32 data_len=4] [0xDE 0xAD 0xBE 0xEF]
        const name = "Position";
        const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
        var payload_buf: [256]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u64, payload_buf[off..][0..8], 42, .little);
        off += 8;
        std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(name.len), .little);
        off += 2;
        @memcpy(payload_buf[off .. off + name.len], name);
        off += name.len;
        std.mem.writeInt(u32, payload_buf[off..][0..4], @intCast(data.len), .little);
        off += 4;
        @memcpy(payload_buf[off .. off + data.len], &data);
        off += data.len;

        try writeBinaryFrame(fd, .component_changed, payload_buf[0..off]);

        const wait = struct {
            fn fired(_: *bool) bool {
                return Capture.fired;
            }
        };
        try waitUntil(&sess, &Capture.fired, wait.fired, 500);

        try expect.toBeTrue(Capture.fired);
        try expect.equal(Capture.got_entity, @as(u64, 42));
        try std.testing.expectEqualStrings(Capture.got_name[0..Capture.got_name_len], "Position");
        try std.testing.expectEqualSlices(u8, Capture.got_bytes[0..Capture.got_bytes_len], &data);
    }

    test "node_entered binary frame fires on_node_entered callback" {
        const Capture = struct {
            var fired: bool = false;
            var got_flow: [64]u8 = [_]u8{0} ** 64;
            var got_flow_len: usize = 0;
            var got_node: u32 = 0;

            fn cb(_: *anyopaque, flow_name: []const u8, node_id: u32) void {
                fired = true;
                got_flow_len = @min(flow_name.len, got_flow.len);
                @memcpy(got_flow[0..got_flow_len], flow_name[0..got_flow_len]);
                got_node = node_id;
            }
        };
        Capture.fired = false;
        Capture.got_flow_len = 0;
        Capture.got_node = 0;

        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        sess.on_node_entered = .{ .ctx = &Capture.fired, .func = Capture.cb };
        const fd = try connectPair(&sess);
        defer _ = close(fd);

        // Payload: [u16 flow_name_len=20] ["player_state_machine"] [u32 node_id=7]
        const flow_name = "player_state_machine";
        var payload_buf: [128]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(flow_name.len), .little);
        off += 2;
        @memcpy(payload_buf[off .. off + flow_name.len], flow_name);
        off += flow_name.len;
        std.mem.writeInt(u32, payload_buf[off..][0..4], 7, .little);
        off += 4;

        try writeBinaryFrame(fd, .node_entered, payload_buf[0..off]);

        const wait = struct {
            fn fired(_: *bool) bool {
                return Capture.fired;
            }
        };
        try waitUntil(&sess, &Capture.fired, wait.fired, 500);

        try expect.toBeTrue(Capture.fired);
        try std.testing.expectEqualStrings(Capture.got_flow[0..Capture.got_flow_len], "player_state_machine");
        try expect.equal(Capture.got_node, @as(u32, 7));
    }

    // `entity_created` doesn't have a callback slot today (the
    // Entity Inspector doesn't model "new entity announced" yet) —
    // just verify the decoder consumes the bytes so following
    // frames stay aligned.
    test "entity_created binary frame is consumed (no callback)" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        const fd = try connectPair(&sess);
        defer _ = close(fd);

        // [u64 entity_id=99] [u16 name_len=6] ["player"]
        const name = "player";
        var payload_buf: [64]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u64, payload_buf[off..][0..8], 99, .little);
        off += 8;
        std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(name.len), .little);
        off += 2;
        @memcpy(payload_buf[off .. off + name.len], name);
        off += name.len;

        try writeBinaryFrame(fd, .entity_created, payload_buf[0..off]);

        // Follow up with a heartbeat — the only way to confirm the
        // decoder didn't get stuck on the binary frame's length
        // prefix is to see a later JSON frame still parses.
        try writeAll(fd, "{\"kind\":\"heartbeat\",\"t\":555}\n");
        const wait = struct {
            fn hb(p: *preview.PreviewSession) bool {
                return (p.last_heartbeat_ms orelse 0) == 555;
            }
        };
        try waitUntil(&sess, &sess, wait.hb, 500);
        try expect.equal(sess.last_heartbeat_ms.?, @as(i64, 555));
        try expect.equal(sess.state, preview.State.running);
    }

    // `entity_destroyed` has no callback slot today either — confirm
    // the 8-byte payload is consumed and the stream stays aligned.
    test "entity_destroyed binary frame is consumed (no callback)" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        const fd = try connectPair(&sess);
        defer _ = close(fd);

        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, 123, .little);
        try writeBinaryFrame(fd, .entity_destroyed, &payload);

        try writeAll(fd, "{\"kind\":\"heartbeat\",\"t\":777}\n");
        const wait = struct {
            fn hb(p: *preview.PreviewSession) bool {
                return (p.last_heartbeat_ms orelse 0) == 777;
            }
        };
        try waitUntil(&sess, &sess, wait.hb, 500);
        try expect.equal(sess.last_heartbeat_ms.?, @as(i64, 777));
    }

    // `pin_value` has no callback slot today (consumer tracked in
    // #100) — confirm the variable-length payload is fully consumed
    // so the stream stays aligned for the next frame.
    test "pin_value binary frame is consumed (no callback)" {
        var sess = preview.PreviewSession.init(std.testing.allocator);
        defer sess.deinit();
        const fd = try connectPair(&sess);
        defer _ = close(fd);

        // Payload: [u16 flow_len] [flow bytes] [u32 node_id]
        //          [u16 pin_len] [pin bytes] [f64 value bits]
        const flow_name = "main_flow";
        const pin_name = "out";
        var payload_buf: [128]u8 = undefined;
        var off: usize = 0;
        std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(flow_name.len), .little);
        off += 2;
        @memcpy(payload_buf[off .. off + flow_name.len], flow_name);
        off += flow_name.len;
        std.mem.writeInt(u32, payload_buf[off..][0..4], 13, .little);
        off += 4;
        std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(pin_name.len), .little);
        off += 2;
        @memcpy(payload_buf[off .. off + pin_name.len], pin_name);
        off += pin_name.len;
        const value: f64 = 3.14;
        const bits: u64 = @bitCast(value);
        std.mem.writeInt(u64, payload_buf[off..][0..8], bits, .little);
        off += 8;

        try writeBinaryFrame(fd, .pin_value, payload_buf[0..off]);

        try writeAll(fd, "{\"kind\":\"heartbeat\",\"t\":1234}\n");
        const wait = struct {
            fn hb(p: *preview.PreviewSession) bool {
                return (p.last_heartbeat_ms orelse 0) == 1234;
            }
        };
        try waitUntil(&sess, &sess, wait.hb, 500);
        try expect.equal(sess.last_heartbeat_ms.?, @as(i64, 1234));
    }
};

pub const GameViewLatencyTests = struct {
    // GameView.meanLatencyNs is pure math over its latency_ring; no
    // GL context needed. Compose the struct manually to test the
    // bookkeeping in isolation. attach()/poll() are exercised
    // end-to-end in the gui-tests TE binary (display + headless GL).

    test "meanLatencyNs returns 0 before any samples" {
        var gv = game_view.GameView.init(std.testing.allocator);
        defer gv.deinit();
        try expect.equal(gv.meanLatencyNs(), @as(u64, 0));
    }

    test "meanLatencyNs averages every populated slot" {
        var gv = game_view.GameView.init(std.testing.allocator);
        defer gv.deinit();
        gv.latency_ring[0] = 1_000_000;
        gv.latency_ring[1] = 2_000_000;
        gv.latency_ring[2] = 3_000_000;
        gv.latency_count = 3;
        // (1 + 2 + 3) / 3 == 2 ms.
        try expect.equal(gv.meanLatencyNs(), @as(u64, 2_000_000));
    }

    test "meanLatencyNs uses latency_count, not the full capacity" {
        // Guards against averaging across uninitialized slots after a
        // fresh attach but before the ring fills.
        var gv = game_view.GameView.init(std.testing.allocator);
        defer gv.deinit();
        gv.latency_ring[0] = 5_000_000;
        // Slots [1..120) are zero-initialized; only slot 0 counts.
        gv.latency_count = 1;
        try expect.equal(gv.meanLatencyNs(), @as(u64, 5_000_000));
    }
};

pub const ComponentDndTests = struct {
    // pack/unpack are the contract between the project tree (drag
    // source) and the prefab canvas (drop target). No ImGui context
    // needed — these are pure data helpers.

    test "packComponent round-trips a short stem" {
        const stem = "bed";
        const p = dnd.packComponent(stem);
        try expect.equal(@as(usize, p.name_len), stem.len);
        try expect.equal(std.mem.eql(u8, dnd.unpackComponent(&p), stem), true);
    }

    test "packComponent round-trips a snake_case stem" {
        // Component files often have underscores (e.g.
        // bandit_combat.zig). Pack must preserve them verbatim.
        const stem = "bandit_combat";
        const p = dnd.packComponent(stem);
        try expect.equal(@as(usize, p.name_len), stem.len);
        try expect.equal(std.mem.eql(u8, dnd.unpackComponent(&p), stem), true);
    }

    test "packComponent truncates a stem longer than PAYLOAD_NAME_CAP" {
        var oversize: [dnd.PAYLOAD_NAME_CAP + 1]u8 = undefined;
        @memset(&oversize, 'x');
        const p = dnd.packComponent(&oversize);
        try expect.equal(@as(usize, p.name_len), dnd.PAYLOAD_NAME_CAP);
    }

    test "packComponent zero-pads the unused tail" {
        const p = dnd.packComponent("bed");
        // Bytes past `name_len` must be zero — the struct is memcpy'd
        // into ImGui's buffer wholesale, and we don't want stale
        // stack noise riding along.
        try expect.equal(p.name[3], @as(u8, 0));
        try expect.equal(p.name[p.name.len - 1], @as(u8, 0));
    }
};

pub const PrefabDndTests = struct {
    // Mirrors `ComponentDndTests`. pack/unpack are the contract
    // between the project tree (drag source on `prefabs/**/*.jsonc`)
    // and the scene viewport (drop target). Pure data helpers — no
    // ImGui context needed.

    test "packPrefab round-trips a short stem" {
        const stem = "canteen";
        const p = dnd.packPrefab(stem);
        try expect.equal(@as(usize, p.name_len), stem.len);
        try expect.equal(std.mem.eql(u8, dnd.unpackPrefab(&p), stem), true);
    }

    test "packPrefab round-trips a snake_case stem" {
        // Real prefab names use snake_case (e.g. movement_node,
        // bandit_raid_enabled). Pack must preserve underscores.
        const stem = "movement_node";
        const p = dnd.packPrefab(stem);
        try expect.equal(@as(usize, p.name_len), stem.len);
        try expect.equal(std.mem.eql(u8, dnd.unpackPrefab(&p), stem), true);
    }

    test "packPrefab truncates a stem longer than PAYLOAD_NAME_CAP" {
        var oversize: [dnd.PAYLOAD_NAME_CAP + 1]u8 = undefined;
        @memset(&oversize, 'x');
        const p = dnd.packPrefab(&oversize);
        try expect.equal(@as(usize, p.name_len), dnd.PAYLOAD_NAME_CAP);
    }

    test "packPrefab zero-pads the unused tail" {
        const p = dnd.packPrefab("canteen");
        // Tail must be zeroed for the same reason packComponent's is —
        // the struct is memcpy'd into ImGui's buffer wholesale.
        try expect.equal(p.name[7], @as(u8, 0));
        try expect.equal(p.name[p.name.len - 1], @as(u8, 0));
    }
};

pub const TreeViewClassifierTests = struct {
    // `isComponentFile` / `isPrefabFile` decide which file leaves
    // become drag sources. They're `pub fn` to be reachable from
    // here; the production code only calls them from `renderFolder`.

    test "isComponentFile accepts a top-level .zig under components/" {
        const prefix = "/proj/components/";
        try expect.toBeTrue(tree_view.isComponentFile(
            "/proj/components/bed.zig",
            "bed.zig",
            prefix,
        ));
    }

    test "isComponentFile rejects a .zig in a subfolder" {
        // Non-recursive by design — only top-level component files
        // are draggable. Nested .zig (e.g. shared helpers) shouldn't
        // surface as a drag source.
        const prefix = "/proj/components/";
        try expect.toBeFalse(tree_view.isComponentFile(
            "/proj/components/shared/helper.zig",
            "helper.zig",
            prefix,
        ));
    }

    test "isComponentFile rejects non-.zig files" {
        const prefix = "/proj/components/";
        try expect.toBeFalse(tree_view.isComponentFile(
            "/proj/components/notes.md",
            "notes.md",
            prefix,
        ));
    }

    test "isComponentFile rejects when prefix is empty (bufPrint failure)" {
        try expect.toBeFalse(tree_view.isComponentFile(
            "/proj/components/bed.zig",
            "bed.zig",
            "",
        ));
    }

    test "isPrefabFile accepts a .jsonc directly under prefabs/" {
        const prefix = "/proj/prefabs/";
        try expect.toBeTrue(tree_view.isPrefabFile(
            "/proj/prefabs/canteen.jsonc",
            "canteen.jsonc",
            prefix,
        ));
    }

    test "isPrefabFile accepts a .jsonc in a subfolder (recursive)" {
        // Real projects nest prefabs (e.g.
        // flying-platform-labelle/prefabs/rooms/canteen.jsonc).
        // This is the key behavioral difference from
        // `isComponentFile`.
        const prefix = "/proj/prefabs/";
        try expect.toBeTrue(tree_view.isPrefabFile(
            "/proj/prefabs/rooms/canteen.jsonc",
            "canteen.jsonc",
            prefix,
        ));
    }

    test "isPrefabFile rejects non-.jsonc files" {
        const prefix = "/proj/prefabs/";
        try expect.toBeFalse(tree_view.isPrefabFile(
            "/proj/prefabs/notes.md",
            "notes.md",
            prefix,
        ));
    }

    test "isPrefabFile rejects .jsonc outside prefabs/" {
        // Scene .jsonc files share the extension but live under
        // scenes/. They must not become drag sources for the
        // viewport.
        const prefix = "/proj/prefabs/";
        try expect.toBeFalse(tree_view.isPrefabFile(
            "/proj/scenes/main.jsonc",
            "main.jsonc",
            prefix,
        ));
    }

    test "isPrefabFile rejects when prefix is empty (bufPrint failure)" {
        try expect.toBeFalse(tree_view.isPrefabFile(
            "/proj/prefabs/canteen.jsonc",
            "canteen.jsonc",
            "",
        ));
    }
};

pub const MatchingPrefabSpriteTests = struct {
    // Helper covers the "drop component → find same-named prefab →
    // copy its body Sprite" pairing. Full happy path needs a real
    // LoadedPrefab (which carries an arena and a parsed body),
    // exercised end-to-end via the editor's visual test. Here we
    // pin the cheap null-cases.

    test "copySpriteFromMatchingPrefab returns null on null index" {
        const result = scene_io.copySpriteFromMatchingPrefab(
            std.testing.allocator,
            "bed",
            null,
        );
        try expect.toBeTrue(result == null);
    }

    test "copySpriteFromMatchingPrefab returns null when prefab not found" {
        // Empty index — nothing resolves. Tests the orelse-null
        // arm in the helper.
        var idx: prefab_index.Index = .{
            .allocator = std.testing.allocator,
            .generation = 1,
        };
        defer idx.entries.deinit(std.testing.allocator);

        const result = scene_io.copySpriteFromMatchingPrefab(
            std.testing.allocator,
            "bed",
            &idx,
        );
        try expect.toBeTrue(result == null);
    }
};

pub const SplitterClampTests = struct {
    // The splitter's clamp math is pure (no imgui draw context),
    // so we exercise it directly. Three bounds cooperate — static
    // ceiling (`prefs.max_inspector_width`), dynamic ceiling derived
    // from window width, static floor (`prefs.min_inspector_width`).
    // Each test pins one bound in the driver's seat. Spacing of 8
    // matches ImGui's default `item_spacing.x` so the dynamic_upper
    // computation in `clampInspectorWidth` matches real frames.
    const default_gap: f32 = 8;

    test "typical case passes through unchanged" {
        // Plenty of room on a 1600px row → requested 400 is well within
        // both static and dynamic ceilings. Returned verbatim.
        const result = splitter.clampInspectorWidth(400, 1600, default_gap);
        try expect.equal(result, @as(f32, 400));
    }

    test "shrunk window: dynamic ceiling clamps before the static max" {
        // 600px row, requested 700. The dynamic ceiling is
        // 600 - min_viewport_width(120) - handle_w(6) - 2*8 = 458.
        // 700 → clamped to 458, well below the static 800 ceiling.
        const result = splitter.clampInspectorWidth(700, 600, default_gap);
        try expect.equal(result, @as(f32, 458));
    }

    test "huge window: static max_inspector_width wins" {
        // 4000px row, requested 1500. Dynamic ceiling allows ~3858,
        // but the static max (800) wins as the tighter cap.
        const result = splitter.clampInspectorWidth(1500, 4000, default_gap);
        try expect.equal(result, @as(f32, prefs.max_inspector_width));
    }

    test "below minimum clamps to the floor" {
        // Requested 50 (way under the floor). Returned 200, the static
        // minimum, regardless of how much room the row has.
        const result = splitter.clampInspectorWidth(50, 1600, default_gap);
        try expect.equal(result, @as(f32, prefs.min_inspector_width));
    }

    test "extremely narrow window keeps floor stable" {
        // 100px row — narrower than `min_viewport_width + handle_w`.
        // Dynamic ceiling would go negative; the @max-with-floor in
        // `clampInspectorWidth` keeps the bound at min_inspector_width
        // so the clamp range stays consistent. Result: the floor.
        const result = splitter.clampInspectorWidth(500, 100, default_gap);
        try expect.equal(result, @as(f32, prefs.min_inspector_width));
    }
};

// ─── flow_io: .flow.jsonc reader / writer (RFC issue #153) ──────────────

/// Covers `flow_io.parse` / `flow_io.render` — the `.flow.jsonc` flat
/// `nodes`+`edges` schema, the `Subflow`/`Param`/`Output` node types,
/// and the determinism guarantee that a re-save produces stable bytes.
pub const FlowIoTests = struct {
    test "parses the flat nodes+edges schema" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  // leading comment
            \\  "name": "enemy_tick",
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "nodes": [
            \\    { "id": 1, "type": "GetComponent", "pos": [0, 0], "component": "Position" },
            \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [10, 20] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "x" }, "to": { "node": 3, "pin": "a" } }
            \\  ]
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(std.mem.eql(u8, doc.name.?, "enemy_tick"));
        try expect.toBeTrue(std.mem.eql(u8, doc.event.type_name, "OnCreate"));
        try expect.equal(doc.nodes.len, @as(usize, 2));
        try expect.equal(doc.edges.len, @as(usize, 1));
        try expect.equal(doc.max_node_id, @as(u32, 3));
    }

    test "recognises Subflow / Param / Output node types" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "name": "combat_subgraph",
            \\  "event": { "type": "OnCall" },
            \\  "params": [ { "name": "damage", "type": "f32", "default": 10.0 } ],
            \\  "nodes": [
            \\    { "id": 2, "type": "Param", "param": "damage", "pos": [0, 0] },
            \\    { "id": 9, "type": "Output", "name": "dealt", "pos": [0, 0] },
            \\    { "id": 7, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 25.0 }, "pos": [240, 60] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.equal(doc.params.len, @as(usize, 1));
        try expect.toBeTrue(std.mem.eql(u8, doc.params[0].name, "damage"));
        try expect.toBeTrue(doc.params[0].default_text != null);
        try expect.toBeTrue(doc.nodes[0].kind == .param);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].param_ref, "damage"));
        try expect.toBeTrue(doc.nodes[1].kind == .output);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[1].output_name, "dealt"));
        try expect.toBeTrue(doc.nodes[2].kind == .subflow);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[2].flow_ref, "combat_subgraph"));
        try expect.equal(doc.nodes[2].bindings.len, @as(usize, 1));
    }

    test "re-save is deterministic and idempotent" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "name": "x",
            \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
            \\  "params": [ { "name": "p", "type": "i32", "default": 3 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Param", "param": "p", "pos": [0, 0] },
            \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [5, 7] }
            \\  ],
            \\  "edges": [
            \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "a" } }
            \\  ]
            \\}
        ;
        var doc1 = try flow_io.parse(a, src);
        defer doc1.deinit();
        const text1 = try flow_io.render(a, doc1);
        defer a.free(text1);

        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);

        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
    }

    test "unknown node fields round-trip verbatim" {
        const a = std.testing.allocator;
        const src =
            \\{ "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Literal", "value": 1.5, "pos": [0, 0] } ],
            \\  "edges": [] }
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        const text = try flow_io.render(a, doc);
        defer a.free(text);
        // The `value` key survived even though the editor doesn't model it.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"value\"") != null);
    }

    test "otherFieldSpec maps field-editable node types to one extras key" {
        try expect.toBeTrue(flow_io.otherFieldSpec("BinOp").?.widget == .op_combo);
        try expect.toBeTrue(std.mem.eql(u8, flow_io.otherFieldSpec("BinOp").?.key, "op"));
        try expect.toBeTrue(std.mem.eql(u8, flow_io.otherFieldSpec("GetComponent").?.key, "component"));
        try expect.toBeTrue(std.mem.eql(u8, flow_io.otherFieldSpec("SetField").?.key, "target"));
        try expect.toBeTrue(flow_io.otherFieldSpec("Literal").?.widget == .literal);
        try expect.toBeTrue(std.mem.eql(u8, flow_io.otherFieldSpec("Identifier").?.key, "name"));
        try expect.toBeTrue(std.mem.eql(u8, flow_io.otherFieldSpec("Call").?.key, "callee"));
        // A genuinely-unknown node type has no spec → verbatim fallback.
        try expect.toBeTrue(flow_io.otherFieldSpec("MysteryNode") == null);
    }

    test "editing an .other field via setExtraValue stays deterministic" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnCreate" },
            \\  "nodes": [
            \\    { "id": 1, "type": "BinOp", "op": "add", "pos": [0, 0] },
            \\    { "id": 2, "type": "GetComponent", "pos": [10, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        const da = doc.allocator();

        // Edit BinOp.op (existing key) and GetComponent.component (new key).
        try flow_io.setExtraValue(da, &doc.nodes[0], "op", "\"mul\"");
        try flow_io.setExtraValue(da, &doc.nodes[1], "component", "\"Position\"");

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);

        // Re-save is byte-identical and the edits are present.
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"op\": \"mul\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"component\": \"Position\"") != null);
    }

    test "editing an .other field keeps unrelated extras keys verbatim" {
        const a = std.testing.allocator;
        const src =
            \\{ "event": { "type": "OnCall" },
            \\  "nodes": [ { "id": 1, "type": "Literal", "value": 1, "note": "keep me", "pos": [0, 0] } ],
            \\  "edges": [] }
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        const da = doc.allocator();

        try flow_io.setExtraValue(da, &doc.nodes[0], "value", "2.5");
        const text = try flow_io.render(a, doc);
        defer a.free(text);

        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"value\": 2.5") != null);
        // The unknown `note` key is untouched.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"note\": \"keep me\"") != null);
    }

    test "string value text decodes and re-encodes round-trip" {
        const a = std.testing.allocator;
        const decoded = try flow_io.decodeStringValue(a, "\"Position\"");
        defer a.free(decoded);
        try expect.toBeTrue(std.mem.eql(u8, decoded, "Position"));

        const encoded = try flow_io.encodeStringValue(a, "Velocity");
        defer a.free(encoded);
        try expect.toBeTrue(std.mem.eql(u8, encoded, "\"Velocity\""));
    }

    test "decodeStringValueBuf decodes into a stack buffer without allocating" {
        var buf: [128]u8 = undefined;

        // A JSON string decodes to its bare inner text.
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.decodeStringValueBuf(&buf, "\"Position\""),
            "Position",
        ));
        // Whitespace around the value is trimmed before decoding.
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.decodeStringValueBuf(&buf, "  \"add\" "),
            "add",
        ));
        // A non-string canonical value (number/bool) comes back verbatim.
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.decodeStringValueBuf(&buf, "42"),
            "42",
        ));
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.decodeStringValueBuf(&buf, "true"),
            "true",
        ));
        // An empty value yields an empty slice (no out-of-bounds).
        try expect.toBeTrue(flow_io.decodeStringValueBuf(&buf, "").len == 0);
    }

    test "decodeStringValueBuf NUL-terminates the result for edit reuse" {
        // The result must be a valid NUL-terminated edit buffer: a `0`
        // sentinel sits immediately after the copied text so a widget can
        // consume `buf` directly without trailing garbage past the value.
        var buf: [128]u8 = undefined;
        @memset(&buf, 0xAA); // poison so a missing sentinel would show

        const decoded = flow_io.decodeStringValueBuf(&buf, "\"Position\"");
        try expect.toBeTrue(buf[decoded.len] == 0);
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&buf, 0), "Position"));

        @memset(&buf, 0xAA);
        const num = flow_io.decodeStringValueBuf(&buf, "42");
        try expect.toBeTrue(buf[num.len] == 0);
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&buf, 0), "42"));

        // Even the verbatim overflow fall-through terminates within the
        // reserved sentinel byte.
        var small: [4]u8 = undefined;
        @memset(&small, 0xAA);
        const over = flow_io.decodeStringValueBuf(&small, "\"abcdefghij\"");
        try expect.toBeTrue(over.len < small.len);
        try expect.toBeTrue(small[over.len] == 0);
    }

    test "decodeStringValueBuf falls through when the decoded text overflows buf" {
        // A decoded string longer than the buffer can't be copied in;
        // the canonical (quoted) text is returned verbatim, truncated to
        // the buffer rather than overrunning it.
        var small: [4]u8 = undefined;
        const out = flow_io.decodeStringValueBuf(&small, "\"abcdefghij\"");
        try expect.toBeTrue(out.len <= small.len);
        // Verbatim fall-through keeps the leading quote of the raw text.
        try expect.toBeTrue(out[0] == '"');
    }

    test "decodeStringValueBuf agrees with decodeStringValue" {
        const a = std.testing.allocator;
        const cases = [_][]const u8{
            "\"Position\"", "\"add\"", "123", "false", "\"\"",
        };
        for (cases) |c| {
            var buf: [128]u8 = undefined;
            const allocd = try flow_io.decodeStringValue(a, c);
            defer a.free(allocd);
            try expect.toBeTrue(std.mem.eql(
                u8,
                flow_io.decodeStringValueBuf(&buf, c),
                allocd,
            ));
        }
    }

    test "decodeStringValueBufChecked reports a clean fit as not truncated" {
        var buf: [128]u8 = undefined;
        // A short JSON string decodes and fits — safe to edit.
        const got = flow_io.decodeStringValueBufChecked(&buf, "\"Position\"");
        try expect.toBeTrue(!got.truncated);
        try expect.toBeTrue(std.mem.eql(u8, got.text, "Position"));

        // A short non-string canonical value fits verbatim.
        const num = flow_io.decodeStringValueBufChecked(&buf, "42");
        try expect.toBeTrue(!num.truncated);
        try expect.toBeTrue(std.mem.eql(u8, num.text, "42"));
    }

    test "decodeStringValueBufChecked NUL-terminates the result for edit reuse" {
        // The `.text` inspector hands this buffer straight to `inputText`
        // / `sliceTo`; a `0` sentinel must sit immediately after the
        // decoded text so the widget shows no trailing garbage and a save
        // can't persist a corrupted `extras` string.
        var buf: [128]u8 = undefined;
        @memset(&buf, 0xAA); // poison so a missing sentinel would show

        const got = flow_io.decodeStringValueBufChecked(&buf, "\"Position\"");
        try expect.toBeTrue(!got.truncated);
        try expect.toBeTrue(buf[got.text.len] == 0);
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&buf, 0), "Position"));

        // Non-string verbatim path also terminates.
        @memset(&buf, 0xAA);
        const num = flow_io.decodeStringValueBufChecked(&buf, "1.5");
        try expect.toBeTrue(buf[num.text.len] == 0);
        try expect.toBeTrue(std.mem.eql(u8, std.mem.sliceTo(&buf, 0), "1.5"));

        // A truncated (too-long) decoded view still terminates within the
        // reserved sentinel byte — the view never overruns the buffer.
        var small: [4]u8 = undefined;
        @memset(&small, 0xAA);
        const over = flow_io.decodeStringValueBufChecked(&small, "\"abcdefghij\"");
        try expect.toBeTrue(over.truncated);
        try expect.toBeTrue(over.text.len < small.len);
        try expect.toBeTrue(small[over.text.len] == 0);
    }

    test "decodeStringValueBufChecked flags a too-long decoded string" {
        // The decoded inner text (`abcdefghij`, 10 chars) exceeds the
        // editable capacity of a 4-byte buffer (3 usable chars).
        var small: [4]u8 = undefined;
        const got = flow_io.decodeStringValueBufChecked(&small, "\"abcdefghij\"");
        try expect.toBeTrue(got.truncated);
        // The view never overruns the buffer.
        try expect.toBeTrue(got.text.len <= small.len);
    }

    test "decodeStringValueBufChecked flags a too-long non-string literal" {
        // A bare number longer than the editable capacity is truncated
        // — editing it would corrupt the literal, so it's flagged.
        var small: [4]u8 = undefined;
        const got = flow_io.decodeStringValueBufChecked(&small, "123456789");
        try expect.toBeTrue(got.truncated);

        // A value of exactly `buf.len` chars still doesn't fit: one byte
        // is reserved for the editor's NUL sentinel.
        var four: [4]u8 = undefined;
        const exact = flow_io.decodeStringValueBufChecked(&four, "1234");
        try expect.toBeTrue(exact.truncated);
    }

    test "a too-long .text field value survives a load -> save round-trip" {
        const a = std.testing.allocator;
        // A `GetComponent.component` whose decoded string is far longer
        // than the inspector's 128-byte identifier edit buffer. The
        // inspector must refuse to edit it; the writer must still emit
        // it unchanged.
        const long_name = "X" ** 300;
        const src = std.fmt.allocPrint(a,
            \\{{ "event": {{ "type": "OnCreate" }},
            \\  "nodes": [ {{ "id": 1, "type": "GetComponent", "component": "{s}", "pos": [0, 0] }} ],
            \\  "edges": [] }}
        , .{long_name}) catch unreachable;
        defer a.free(src);

        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        // The inspector's `.text` path would decode into an `IdentBuf`
        // (128 bytes); a 300-char value must come back flagged.
        const stored = flow_io.extraValue(doc.nodes[0], "component").?;
        var ident_buf: [128]u8 = undefined;
        const decoded = flow_io.decodeStringValueBufChecked(&ident_buf, stored);
        try expect.toBeTrue(decoded.truncated);

        // An untouched too-long value must round-trip verbatim — the
        // editor skips the write, so `extras` is unchanged.
        const text = try flow_io.render(a, doc);
        defer a.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, long_name) != null);

        // And the re-save stays deterministic.
        var doc2 = try flow_io.parse(a, text);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text, text2));
    }

    test "a too-long Literal value survives a load -> save round-trip" {
        const a = std.testing.allocator;
        // A `Literal.value` JSON string longer than the inspector's
        // 256-byte `ValueBuf`. Seeding it would truncate; the inspector
        // must keep the field read-only and leave `extras` untouched.
        const long_lit = "\"" ++ ("y" ** 400) ++ "\"";
        const src = std.fmt.allocPrint(a,
            \\{{ "event": {{ "type": "OnCall" }},
            \\  "nodes": [ {{ "id": 1, "type": "Literal", "value": {s}, "pos": [0, 0] }} ],
            \\  "edges": [] }}
        , .{long_lit}) catch unreachable;
        defer a.free(src);

        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        // The stored canonical text is longer than the 256-byte buffer
        // (255 usable) — the inspector's literal path treats it as
        // read-only.
        const stored = flow_io.extraValue(doc.nodes[0], "value").?;
        try expect.toBeTrue(stored.len > 255);

        // The untouched literal round-trips verbatim and deterministically.
        const text = try flow_io.render(a, doc);
        defer a.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, "y" ** 400) != null);

        var doc2 = try flow_io.parse(a, text);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text, text2));
    }

    test "a too-long BinOp op survives a load -> save round-trip" {
        const a = std.testing.allocator;
        // A `BinOp.op` JSON string whose decoded text is far longer than
        // the inspector's 128-byte identifier edit buffer. The `.op_combo`
        // path must detect the truncation (via `decodeStringValueBufChecked`)
        // and refuse to write — picking an operator would otherwise
        // silently clobber the full stored value on save.
        const long_op = "z" ** 300;
        const src = std.fmt.allocPrint(a,
            \\{{ "event": {{ "type": "OnCreate" }},
            \\  "nodes": [ {{ "id": 1, "type": "BinOp", "op": "{s}", "pos": [0, 0] }} ],
            \\  "edges": [] }}
        , .{long_op}) catch unreachable;
        defer a.free(src);

        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        // The inspector's `.op_combo` path decodes into an `IdentBuf`
        // (128 bytes); a 300-char value must come back flagged truncated
        // so the combo goes read-only instead of allowing a write.
        const stored = flow_io.extraValue(doc.nodes[0], "op").?;
        var ident_buf: [128]u8 = undefined;
        const decoded = flow_io.decodeStringValueBufChecked(&ident_buf, stored);
        try expect.toBeTrue(decoded.truncated);

        // An untouched too-long `op` must round-trip verbatim — the
        // editor skips the write, so `extras` is unchanged.
        const text = try flow_io.render(a, doc);
        defer a.free(text);
        try expect.toBeTrue(std.mem.indexOf(u8, text, long_op) != null);

        // And the re-save stays deterministic.
        var doc2 = try flow_io.parse(a, text);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text, text2));
    }

    test "displayNameFromPath strips the .flow.jsonc extension" {
        try expect.toBeTrue(std.mem.eql(
            u8,
            flow_io.displayNameFromPath("a/b/enemy_tick.flow.jsonc"),
            "enemy_tick",
        ));
    }

    test "isFlowDocPath matches only .flow.jsonc under scripts/flows" {
        const dir = "/proj";
        try expect.toBeTrue(project_tree.isFlowDocPath(dir, "/proj/scripts/flows/a.flow.jsonc"));
        try expect.toBeTrue(!project_tree.isFlowDocPath(dir, "/proj/scripts/flows/a.zig"));
        try expect.toBeTrue(!project_tree.isFlowDocPath(dir, "/proj/scenes/a.jsonc"));
    }
};

// ─── RFC-PLUGIN-EVENTS (issue #169 — closes O6): flow editor event-name
//     dropdown + new-form `OnEvent` + `Emit` node ───────────────────────

/// Cover the editor-side surface for RFC-PLUGIN-EVENTS phase 5:
///
///   - `flow_io.zig` models `OnEvent`'s two forms (new `name`-form,
///     legacy `module`+`callback`+`params`) as first-class fields and
///     rejects malformed combinations.
///   - `flow_io.zig` models the `Emit` node structurally; both shapes
///     round-trip through `parse` → `render` byte-stably.
///   - The static `flow_event_catalog` drives the editor's event-name
///     dropdown until the assembler-derived sidecar lands.
///   - `flow_io.legacy_onevent_to_name` migrates a legacy `OnEvent` to
///     the new form (mirrors `flow-codegen`'s converter).
pub const PluginEventsRfcTests = struct {
    test "OnEvent new-form round-trips with name" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(std.mem.eql(u8, doc.event.type_name, "OnEvent"));
        try expect.toBeTrue(doc.event.name != null);
        try expect.toBeTrue(std.mem.eql(u8, doc.event.name.?, "box2d.collision_begin"));
        try expect.toBeTrue(doc.event.module == null);
        try expect.toBeTrue(doc.event.callback == null);
        try expect.equal(doc.event.params.len, @as(usize, 0));

        // Re-render is byte-stable so a Save → reopen leaves no diff.
        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"name\": \"box2d.collision_begin\"") != null);
    }

    test "OnEvent legacy form round-trips with module+callback+params" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "event": {
            \\    "type": "OnEvent",
            \\    "module": "box2d",
            \\    "callback": "on_collision_begin",
            \\    "params": [
            \\      { "name": "entity_a", "type": "u32" },
            \\      { "name": "entity_b", "type": "u32" }
            \\    ]
            \\  },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(doc.event.name == null);
        try expect.toBeTrue(std.mem.eql(u8, doc.event.module.?, "box2d"));
        try expect.toBeTrue(std.mem.eql(u8, doc.event.callback.?, "on_collision_begin"));
        try expect.equal(doc.event.params.len, @as(usize, 2));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
    }

    test "OnEvent rejects malformed two-form combinations" {
        const a = std.testing.allocator;
        // Both forms.
        try expect.toReturnError(flow_io.parse(a,
            \\{ "event": { "type": "OnEvent", "name": "box2d.collision_begin", "module": "box2d", "callback": "on_collision_begin" }, "nodes": [], "edges": [] }
        ), error.MalformedFlow);
        // Neither.
        try expect.toReturnError(flow_io.parse(a,
            \\{ "event": { "type": "OnEvent" }, "nodes": [], "edges": [] }
        ), error.MalformedFlow);
        // Partial legacy.
        try expect.toReturnError(flow_io.parse(a,
            \\{ "event": { "type": "OnEvent", "module": "box2d" }, "nodes": [], "edges": [] }
        ), error.MalformedFlow);
        try expect.toReturnError(flow_io.parse(a,
            \\{ "event": { "type": "OnEvent", "callback": "on_collision_begin" }, "nodes": [], "edges": [] }
        ), error.MalformedFlow);
    }

    test "Emit node parses, exposes event_ref, and round-trips" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnUpdate" },
            \\  "nodes": [
            \\    { "id": 1, "type": "Emit", "event": "box2d.collision_begin", "pos": [400, 200] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(doc.nodes[0].kind == .emit);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].event_ref, "box2d.collision_begin"));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"type\": \"Emit\"") != null);
    }

    test "legacy_onevent_to_name maps module + on_callback to dotted name" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "event": { "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin" },
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try flow_io.legacy_onevent_to_name(doc.allocator(), &doc.event);
        try expect.toBeTrue(std.mem.eql(u8, doc.event.name.?, "box2d.collision_begin"));
        try expect.toBeTrue(doc.event.module == null);
        try expect.toBeTrue(doc.event.callback == null);
        try expect.equal(doc.event.params.len, @as(usize, 0));
    }

    test "event_catalog covers shipped labelle-box2d events" {
        // Every plugin event `labelle-box2d` ships in `pub const Events`
        // (root.zig:93-125) must appear in the catalog — the editor's
        // dropdown is the user-facing surface of phase 1's discovery
        // until the assembler-emitted sidecar lands.
        try expect.toBeTrue(event_catalog.isKnown("box2d.collision_begin"));
        try expect.toBeTrue(event_catalog.isKnown("box2d.collision_end"));
        try expect.toBeTrue(event_catalog.isKnown("box2d.collision_hit"));
        try expect.toBeTrue(event_catalog.isKnown("box2d.sensor_enter"));
        try expect.toBeTrue(event_catalog.isKnown("box2d.sensor_exit"));
        try expect.toBeTrue(!event_catalog.isKnown("not_a_real.event"));
    }

    test "event_catalog reflects collision_hit's 7-field payload" {
        const e = event_catalog.lookup("box2d.collision_hit").?;
        try expect.equal(e.fields.len, @as(usize, 7));
        try expect.toBeTrue(std.mem.eql(u8, e.fields[0].name, "entity_a"));
        try expect.toBeTrue(std.mem.eql(u8, e.fields[6].name, "speed"));
        try expect.toBeTrue(std.mem.eql(u8, e.fields[6].type_name, "f32"));
    }

    test "bouncing-ball hit_counter.flow.jsonc parses as v2-form (Event node + variables)" {
        // Real-file ingestion test — flow-codegen `a8be4c1` migrated
        // this in-tree example to the v2 vocabulary (RFC-FLOW-VOCABULARY
        // phase 3): the trigger lives ON the canvas as an `Event` node
        // and the counter is a declared top-level `Variable`, not a
        // sidecar `.zig`. The editor must load it without the legacy
        // `event:` header.
        const a = std.testing.allocator;
        const path = "../bouncing-ball/scripts/flows/hit_counter.flow.jsonc";

        var doc = flow_io.loadFromFile(a, path) catch |err| switch (err) {
            // Other repos in the toolkit may not be checked out alongside
            // labelle-gui in every CI matrix slot. Skip — the test still
            // executes in dev environments where the example exists.
            error.FileNotFound => return,
            else => return err,
        };
        defer doc.deinit();

        // No file-level event header — the trigger is on-canvas now.
        try expect.toBeTrue(!doc.event_present);

        // Two nodes: the `Event` trigger + the `ChangeVariable` action.
        try expect.equal(doc.nodes.len, @as(usize, 2));
        try expect.toBeTrue(doc.nodes[0].kind == .event);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].event_ref, "box2d.collision_begin"));
        try expect.toBeTrue(doc.nodes[1].kind == .change_variable);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[1].variable_ref, "hits"));

        // One declared variable.
        try expect.equal(doc.variables.len, @as(usize, 1));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[0].name, "hits"));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[0].type_name, "i32"));
    }
};

/// RFC-FLOW-VOCABULARY phase 4 — editor support for the new node
/// vocabulary (Event-as-node, variables block, CustomNode, the variable
/// ops, and the v1→v2 form where the trigger lives on the canvas).
/// Round-trip tests are organized the same way as `PluginEventsRfcTests`
/// above so they are easy to find next to phase 3.
pub const FlowVocabularyRfcTests = struct {
    test "top-level variables block parses and round-trips" {
        // RFC §4 — the canonical shape: name + Zig type text + JSON-native
        // default. Codegen lowers each entry to a file-scope `var` in the
        // generated `.zig`. The editor preserves the JSON-native form
        // verbatim through the writer so re-saves don't churn defaults.
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 },
            \\    { "name": "ready", "type": "bool", "default": true },
            \\    { "name": "name", "type": "?[]const u8", "default": null }
            \\  ],
            \\  "nodes": [],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.equal(doc.variables.len, @as(usize, 3));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[0].name, "hits"));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[0].type_name, "i32"));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[0].default_text, "0"));
        try expect.toBeTrue(std.mem.eql(u8, doc.variables[2].default_text, "null"));
        try expect.toBeTrue(doc.variables[2].isNullable());
        try expect.toBeTrue(!doc.variables[0].isNullable());

        // Re-save is byte-stable.
        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        // Variables block survived the round-trip.
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"variables\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"hits\"") != null);
    }

    test "variables block rejects a missing default (codegen requires one)" {
        const a = std.testing.allocator;
        // Every variable must declare a default — codegen will refuse
        // an undeclared one (RFC §4). The editor enforces the same at
        // parse time so a save can't produce a flow codegen would reject.
        try expect.toReturnError(flow_io.parse(a,
            \\{ "variables": [ { "name": "hits", "type": "i32" } ], "nodes": [], "edges": [] }
        ), error.BadSchema);
    }

    test "Event node (graph-level trigger) parses and round-trips" {
        // RFC §3 — new-form flows declare their trigger ON the canvas as
        // an `Event` node, not via a file-level `event:` header. The
        // editor must round-trip this without injecting a header.
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        try expect.toBeTrue(!doc.event_present);
        try expect.equal(doc.nodes.len, @as(usize, 1));
        try expect.toBeTrue(doc.nodes[0].kind == .event);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].event_ref, "box2d.collision_begin"));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        // No legacy header was injected.
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"event\":") == null);
        // Event node survived with its dotted name in `name`.
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"type\": \"Event\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"name\": \"box2d.collision_begin\"") != null);

        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
    }

    test "GetVariable / SetVariable / ChangeVariable parse and round-trip" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [ { "name": "hits", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "GetVariable", "name": "hits", "pos": [0, 0] },
            \\    { "id": 2, "type": "SetVariable", "name": "hits", "pos": [120, 0] },
            \\    { "id": 3, "type": "ChangeVariable", "name": "hits", "by": 5, "pos": [240, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        try expect.toBeTrue(doc.nodes[0].kind == .get_variable);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].variable_ref, "hits"));
        try expect.toBeTrue(doc.nodes[1].kind == .set_variable);
        try expect.toBeTrue(doc.nodes[2].kind == .change_variable);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[2].by_text, "5"));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"by\": 5") != null);
    }

    test "ChangeVariable defaults to by:1 when omitted on a fresh save" {
        // codegen treats a missing `by` as `1` (RFC §4 Scratch-style
        // increment). The editor's writer emits the field unconditionally
        // so the file is self-describing — never invisible state.
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [ { "name": "hits", "type": "i32", "default": 0 } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "ChangeVariable", "name": "hits", "pos": [0, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        const text = try flow_io.render(a, doc);
        defer a.free(text);
        // The implicit `by` is materialized on save so the next reader
        // doesn't have to guess.
        try expect.toBeTrue(std.mem.indexOf(u8, text, "\"by\": 1") != null);
    }

    test "ClearVariable and HasValueVariable round-trip with the variable name" {
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "variables": [ { "name": "target", "type": "?EntityId", "default": null } ],
            \\  "nodes": [
            \\    { "id": 1, "type": "ClearVariable", "name": "target", "pos": [0, 0] },
            \\    { "id": 2, "type": "HasValueVariable", "name": "target", "pos": [200, 0] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(doc.nodes[0].kind == .clear_variable);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].variable_ref, "target"));
        try expect.toBeTrue(doc.nodes[1].kind == .has_value_variable);

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"type\": \"ClearVariable\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"type\": \"HasValueVariable\"") != null);
    }

    test "CustomNode parses with the sibling-agent's dotted JSONC shape" {
        // RFC §1, §6 — plugin/script-contributed FlowNode reference.
        // Shape per the task body + sibling-agent coordination: the
        // dotted plugin name lives in `name`, not the discriminator
        // `type` (which holds `"CustomNode"`). flow-codegen consumes
        // the same shape via `PluginFlowNodes.resolve(name)` at build
        // time.
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "nodes": [
            \\    { "id": 1, "type": "CustomNode", "name": "box2d.apply_impulse", "pos": [40, 40] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();
        try expect.toBeTrue(doc.nodes[0].kind == .custom_node);
        try expect.toBeTrue(std.mem.eql(u8, doc.nodes[0].custom_name, "box2d.apply_impulse"));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"type\": \"CustomNode\"") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"name\": \"box2d.apply_impulse\"") != null);
    }

    test "v2-form flow (no event header, Event node + variables) round-trips byte-stably" {
        // The full new-form shape: no legacy `event:` header, trigger
        // on-canvas, variables block at the top. This is exactly the
        // bouncing-ball `hit_counter.flow.jsonc` template.
        const a = std.testing.allocator;
        const src =
            \\{
            \\  "name": "hit_counter",
            \\  "variables": [
            \\    { "name": "hits", "type": "i32", "default": 0 }
            \\  ],
            \\  "nodes": [
            \\    { "id": 1, "type": "Event", "name": "box2d.collision_begin", "pos": [40, 40] },
            \\    { "id": 2, "type": "ChangeVariable", "name": "hits", "by": 1, "pos": [40, 160] }
            \\  ],
            \\  "edges": []
            \\}
        ;
        var doc = try flow_io.parse(a, src);
        defer doc.deinit();

        try expect.toBeTrue(!doc.event_present);
        try expect.equal(doc.variables.len, @as(usize, 1));
        try expect.equal(doc.nodes.len, @as(usize, 2));

        const text1 = try flow_io.render(a, doc);
        defer a.free(text1);
        // No legacy event header in the output.
        try expect.toBeTrue(std.mem.indexOf(u8, text1, "\"event\":") == null);

        var doc2 = try flow_io.parse(a, text1);
        defer doc2.deinit();
        const text2 = try flow_io.render(a, doc2);
        defer a.free(text2);
        try expect.toBeTrue(std.mem.eql(u8, text1, text2));
    }

    test "node_catalog covers every shipped labelle-box2d FlowNode" {
        // Every FlowNode `labelle-box2d` ships in `pub const FlowNodes`
        // (root.zig:147-239) must appear in the catalog — the editor's
        // palette is the user-facing surface of phase 1's discovery
        // until the assembler-emitted sidecar lands.
        try expect.toBeTrue(node_catalog.isKnown("box2d.apply_impulse"));
        try expect.toBeTrue(node_catalog.isKnown("box2d.ray_cast"));
        try expect.toBeTrue(node_catalog.isKnown("box2d.set_gravity"));
        try expect.toBeTrue(!node_catalog.isKnown("never.heard.of.it"));
        // The full count must equal the plugin's shipped decl count.
        try expect.equal(@as(usize, 14), node_catalog.entries.len);
    }

    test "node_catalog wire-fit accepts safe widenings only" {
        // RFC-FLOW-VOCABULARY §2 / O1 resolved: same-sign integer
        // widening, unsigned → strictly-larger signed, and float
        // widening are auto-accepted. Int ↔ float in either direction
        // requires an explicit conversion node and is refused.
        try expect.toBeTrue(node_catalog.typesFit("i32", "i32"));
        try expect.toBeTrue(node_catalog.typesFit("i32", "i64"));
        try expect.toBeTrue(node_catalog.typesFit("u8", "i16"));
        try expect.toBeTrue(node_catalog.typesFit("f32", "f64"));
        try expect.toBeTrue(node_catalog.typesFit("EntityId", "u32"));
        // O1 explicitly forbids int → float (lossy for large ints).
        try expect.toBeTrue(!node_catalog.typesFit("i32", "f64"));
        try expect.toBeTrue(!node_catalog.typesFit("f32", "i32"));
        try expect.toBeTrue(!node_catalog.typesFit("RayResult", "BodyId"));
    }
};

/// Covers `io_global.writeFileAtomic` — the shared atomic-save helper
/// behind `flow_io.saveToFile`, `scene_io.saveScene`, and
/// `scene_io.savePrefab` (issue #166). The crash-safety guarantee can't
/// be exercised without fault injection, so these tests pin the
/// observable contract: the right bytes land at `path`, an overwrite
/// fully replaces the previous content, and a successful save leaves no
/// `.tmp` sibling behind.
pub const AtomicWriteTests = struct {
    fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const ts = timestampSeconds();
        const Counter = struct {
            var i: u64 = 0;
        };
        Counter.i += 1;
        const dir_name = try std.fmt.allocPrint(
            allocator,
            "/tmp/labelle_atomic_{d}_{d}",
            .{ ts, Counter.i },
        );
        try std.Io.Dir.cwd().createDir(io_global.io(), dir_name, .default_dir);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.Io.Dir.cwd().deleteTree(io_global.io(), dir_path) catch {};
        allocator.free(dir_path);
    }

    fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            io_global.io(),
            path,
            allocator,
            .limited(1024 * 1024),
        );
    }

    /// Number of directory entries whose name contains ".tmp" — a
    /// successful atomic save must leave zero of these.
    fn countTempFiles(dir_path: []const u8) !usize {
        var dir = try std.Io.Dir.cwd().openDir(io_global.io(), dir_path, .{ .iterate = true });
        defer dir.close(io_global.io());
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next(io_global.io())) |entry| {
            if (std.mem.indexOf(u8, entry.name, ".tmp") != null) count += 1;
        }
        return count;
    }

    test "writes content to a fresh file" {
        const allocator = std.testing.allocator;
        const tmp = try createTempDir(allocator);
        defer deleteTempDir(allocator, tmp);

        const path = try std.fs.path.join(allocator, &.{ tmp, "out.txt" });
        defer allocator.free(path);

        try io_global.writeFileAtomic(
            std.Io.Dir.cwd(),
            io_global.io(),
            path,
            "hello atomic world",
            allocator,
        );

        const got = try readFile(allocator, path);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("hello atomic world", got);
    }

    test "overwriting an existing file replaces its content" {
        const allocator = std.testing.allocator;
        const tmp = try createTempDir(allocator);
        defer deleteTempDir(allocator, tmp);

        const path = try std.fs.path.join(allocator, &.{ tmp, "scene.jsonc" });
        defer allocator.free(path);

        // Seed a longer original — a non-atomic truncating write would
        // leave trailing stale bytes if the new payload were shorter.
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = "ORIGINAL CONTENT THAT IS FAIRLY LONG AND SHOULD BE GONE",
        });

        try io_global.writeFileAtomic(
            std.Io.Dir.cwd(),
            io_global.io(),
            path,
            "new",
            allocator,
        );

        const got = try readFile(allocator, path);
        defer allocator.free(got);
        try std.testing.expectEqualStrings("new", got);
    }

    test "successful save leaves no leftover temp file" {
        const allocator = std.testing.allocator;
        const tmp = try createTempDir(allocator);
        defer deleteTempDir(allocator, tmp);

        const path = try std.fs.path.join(allocator, &.{ tmp, "prefab.jsonc" });
        defer allocator.free(path);

        try io_global.writeFileAtomic(
            std.Io.Dir.cwd(),
            io_global.io(),
            path,
            "{ \"components\": {} }\n",
            allocator,
        );

        // Only the destination file should remain — the `.tmp` sibling
        // must have been renamed away, not left in the directory.
        try expect.equal(try countTempFiles(tmp), 0);
    }

    test "scene_io.saveScene writes atomically with no temp leftover" {
        const allocator = std.testing.allocator;
        const tmp = try createTempDir(allocator);
        defer deleteTempDir(allocator, tmp);

        const path = try std.fs.path.join(allocator, &.{ tmp, "main.jsonc" });
        defer allocator.free(path);

        const src = "{ \"name\": \"main\", \"entities\": [] }\n";
        var scene = try scene_io.parseScene(allocator, src);
        defer scene.deinit();

        try scene_io.saveScene(allocator, path, scene);

        const got = try readFile(allocator, path);
        defer allocator.free(got);
        try expect.toBeTrue(std.mem.indexOf(u8, got, "\"main\"") != null);
        try expect.equal(try countTempFiles(tmp), 0);
    }
};

// ─── flow_doc: Subflow reference resolution (issue #161) ────────────────

/// Covers `flow_doc.referencedFlowPath` — the helper that maps a
/// `Subflow` node's referenced-flow *name* to the on-disk path of the
/// `.flow.jsonc` file (a sibling in the same `scripts/flows/` dir).
pub const FlowDocSubflowTests = struct {
    test "referencedFlowPath resolves a sibling .flow.jsonc" {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const got = flow_doc.referencedFlowPath(
            &buf,
            "/proj/scripts/flows/enemy_tick.flow.jsonc",
            "combat_subgraph",
        );
        try expect.toBeTrue(got != null);
        try expect.toBeTrue(std.mem.eql(
            u8,
            got.?,
            "/proj/scripts/flows/combat_subgraph.flow.jsonc",
        ));
    }

    test "referencedFlowPath returns null when the path has no directory" {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        try expect.toBeTrue(flow_doc.referencedFlowPath(&buf, "bare.flow.jsonc", "x") == null);
    }

    test "sameFileOnDisk detects identical path strings" {
        try expect.toBeTrue(flow_doc.sameFileOnDisk(
            "/proj/scripts/flows/a.flow.jsonc",
            "/proj/scripts/flows/a.flow.jsonc",
        ));
    }

    test "sameFileOnDisk catches a self-reference reached via a non-canonical path" {
        // A `flow_ref` that resolves to the *same file on disk* through
        // `.`/`..` segments must still be flagged: a raw byte compare
        // would miss it and the Subflow node would mis-show the current
        // flow's own pins.
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try std.fs.path.join(std.testing.allocator, &.{
            ".zig-cache", "tmp", &tmp.sub_path,
        });
        defer std.testing.allocator.free(dir);

        const canonical = try std.fs.path.join(std.testing.allocator, &.{
            dir, "self.flow.jsonc",
        });
        defer std.testing.allocator.free(canonical);
        std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = canonical,
            .data = "{ \"event\": \"on_tick\", \"nodes\": [], \"edges\": [] }",
        }) catch unreachable;

        // Same file, reached through a `.` segment in the directory.
        const non_canonical = try std.fs.path.join(std.testing.allocator, &.{
            dir, ".", "self.flow.jsonc",
        });
        defer std.testing.allocator.free(non_canonical);

        try expect.toBeTrue(flow_doc.sameFileOnDisk(canonical, non_canonical));
    }

    test "sameFileOnDisk distinguishes two different existing files" {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try std.fs.path.join(std.testing.allocator, &.{
            ".zig-cache", "tmp", &tmp.sub_path,
        });
        defer std.testing.allocator.free(dir);

        const a = try std.fs.path.join(std.testing.allocator, &.{ dir, "a.flow.jsonc" });
        defer std.testing.allocator.free(a);
        const b = try std.fs.path.join(std.testing.allocator, &.{ dir, "b.flow.jsonc" });
        defer std.testing.allocator.free(b);
        const body = "{ \"event\": \"on_tick\", \"nodes\": [], \"edges\": [] }";
        std.Io.Dir.cwd().writeFile(io_global.io(), .{ .sub_path = a, .data = body }) catch unreachable;
        std.Io.Dir.cwd().writeFile(io_global.io(), .{ .sub_path = b, .data = body }) catch unreachable;

        try expect.toBeTrue(!flow_doc.sameFileOnDisk(a, b));
    }

    test "sameFileOnDisk falls back to raw compare when a path is missing" {
        // Neither file exists — canonicalization is impossible, so the
        // helper falls back to a raw byte compare. Distinct strings are
        // (conservatively) reported as different files.
        try expect.toBeTrue(!flow_doc.sameFileOnDisk(
            "/no/such/dir/a.flow.jsonc",
            "/no/such/dir/b.flow.jsonc",
        ));
    }

    // ── ResolvedFlow cache-freshness (issue #161 follow-up) ─────────────
    //
    // `resolveSubflow` itself touches `FlowDocState`, which transitively
    // pulls in the imgui/zgui stack the `zig build test` target
    // deliberately excludes (build.zig issue #94 note). The staleness
    // decision is therefore factored into the pure `resolvedFlowIsFresh`
    // helper, which these tests exercise directly.

    test "resolvedFlowIsFresh: a successful load with matching mtime + size is fresh" {
        try expect.toBeTrue(flow_doc.resolvedFlowIsFresh(
            true, // loaded_ok
            123, // cached mtime
            456, // cached size
            123, // current mtime
            456, // current size
        ));
    }

    test "resolvedFlowIsFresh: same mtime but a changed size is stale" {
        // The same-tick / mtime-preserving rewrite case: the referenced
        // file's contents changed (size moved) without its mtime
        // advancing. mtime alone would wrongly report the cache fresh;
        // pairing it with size catches the rewrite and forces a
        // re-resolve so the Subflow node's pins stay current.
        try expect.toBeTrue(!flow_doc.resolvedFlowIsFresh(
            true,
            123,
            456,
            123, // mtime unchanged
            512, // size grew
        ));
    }

    test "resolvedFlowIsFresh: a changed mtime is stale even when size matches" {
        try expect.toBeTrue(!flow_doc.resolvedFlowIsFresh(
            true,
            123,
            456,
            999, // mtime moved
            456, // size unchanged
        ));
    }

    test "resolvedFlowIsFresh: a previously failed load is never fresh" {
        // `loaded_ok = false` must always re-attempt — a fixed-contents
        // file has to recover even if mtime + size are unchanged.
        try expect.toBeTrue(!flow_doc.resolvedFlowIsFresh(
            false,
            123,
            456,
            123,
            456,
        ));
    }

    test "resolvedFlowIsFresh: a failed stat (null mtime + size) is never fresh" {
        // A missing/unstattable file leaves both observations null.
        // Even against a cache entry that also has nulls, treat it as
        // stale so the next frame re-attempts the load.
        try expect.toBeTrue(!flow_doc.resolvedFlowIsFresh(
            true,
            null,
            null,
            null,
            null,
        ));
    }
};

// ─── flow_cycle: Subflow reference-cycle check (issue #159) ──────────────

/// Covers `flow_cycle.detectCycle` (the pure DFS walk over the
/// `Subflow` reference graph) and `flow_cycle.analyze` (the on-disk,
/// project-backed resolver). The pure walk is exercised with an
/// in-memory reference map; `analyze` is exercised against real
/// `.flow.jsonc` files in a temp `scripts/flows/` directory.
pub const FlowCycleTests = struct {
    /// In-memory `flow_cycle.Resolver` backing — a flow name → refs
    /// map. A name absent from the map resolves to `.missing`; a name
    /// in `broken` resolves to `.parse_failed`.
    const MapResolver = struct {
        map: std.StringHashMapUnmanaged([]const []const u8),
        broken: std.StringHashMapUnmanaged(void) = .empty,

        fn refs(ctx: *anyopaque, name: []const u8) anyerror!flow_cycle.RefResult {
            const self: *MapResolver = @ptrCast(@alignCast(ctx));
            if (self.map.get(name)) |r| return .{ .ok = r };
            if (self.broken.contains(name)) return .parse_failed;
            return .missing;
        }

        fn resolver(self: *MapResolver) flow_cycle.Resolver {
            return .{ .ctx = self, .refsFn = MapResolver.refs };
        }
    };

    test "detectCycle reports a clean linear chain" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{"b"});
        try m.map.put(a, "b", &.{"c"});
        try m.map.put(a, "c", &.{});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .clean);
    }

    test "detectCycle flags a direct self-reference" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{"a"});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .cycle);
        try expect.equal(status.cycle.names.len, @as(usize, 2));
    }

    test "detectCycle reports the offending chain for an indirect cycle" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{"b"});
        try m.map.put(a, "b", &.{"c"});
        try m.map.put(a, "c", &.{"a"});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .cycle);
        // a → b → c → a
        try expect.equal(status.cycle.names.len, @as(usize, 4));
        try expect.toBeTrue(std.mem.eql(u8, status.cycle.names[0], "a"));
        try expect.toBeTrue(std.mem.eql(u8, status.cycle.names[3], "a"));
    }

    test "detectCycle finds a cycle that does not include the entry flow" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "entry", &.{"b"});
        try m.map.put(a, "b", &.{"c"});
        try m.map.put(a, "c", &.{"b"});

        const status = try flow_cycle.detectCycle(a, "entry", m.resolver());
        try expect.toBeTrue(status == .cycle);
    }

    test "detectCycle reports an unresolved reference" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{"b"});
        try m.map.put(a, "b", &.{"missing"});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .unresolved);
        try expect.toBeTrue(std.mem.eql(
            u8,
            status.unresolved.names[status.unresolved.names.len - 1],
            "missing",
        ));
    }

    test "detectCycle treats a diamond reference graph as clean" {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{ "b", "c" });
        try m.map.put(a, "b", &.{"d"});
        try m.map.put(a, "c", &.{"d"});
        try m.map.put(a, "d", &.{});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .clean);
    }

    test "detectCycle catches a cycle reachable only through a node first seen on a clean branch" {
        // Regression for the classic three-state DFS mistake: the
        // "done" set must mean "fully explored AND acyclic", never just
        // "seen". `c` is first reached down the clean-looking `entry →
        // x → c` branch; the real cycle is `b → c → b`. A walk that
        // marked `c` done on first sight would skip `c` on the later
        // `entry → b` branch and wrongly report `.clean`.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "entry", &.{ "x", "b" });
        try m.map.put(a, "x", &.{"c"});
        try m.map.put(a, "b", &.{"c"});
        try m.map.put(a, "c", &.{"b"});

        const status = try flow_cycle.detectCycle(a, "entry", m.resolver());
        try expect.toBeTrue(status == .cycle);
        // Walk descends entry → x → c → b → c; the back edge closes at
        // `c`, so the offending chain is c → b → c.
        try expect.equal(status.cycle.names.len, @as(usize, 3));
        try expect.toBeTrue(std.mem.eql(u8, status.cycle.names[0], "c"));
        try expect.toBeTrue(std.mem.eql(
            u8,
            status.cycle.names[status.cycle.names.len - 1],
            "c",
        ));
    }

    test "detectCycle catches a cycle behind a node reached via two clean-prefix paths" {
        // `d`'s children are walked in order: (1) `c → leaf` is a
        // genuinely clean subtree that leaves `c`/`leaf` in the done
        // set; (2) `e → d` then closes the `d → e → d` cycle. The
        // earlier done-marking of the sibling subtree must not suppress
        // the cycle on the later branch.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "entry", &.{"d"});
        try m.map.put(a, "d", &.{ "c", "e" });
        try m.map.put(a, "c", &.{"leaf"});
        try m.map.put(a, "leaf", &.{});
        try m.map.put(a, "e", &.{"d"});

        const status = try flow_cycle.detectCycle(a, "entry", m.resolver());
        try expect.toBeTrue(status == .cycle);
        try expect.toBeTrue(std.mem.eql(u8, status.cycle.names[0], "d"));
        try expect.toBeTrue(std.mem.eql(
            u8,
            status.cycle.names[status.cycle.names.len - 1],
            "d",
        ));
    }

    test "detectCycle treats a node reached via two genuinely clean paths as clean" {
        // Counterpart false-positive guard: `c` is reached twice, both
        // paths acyclic. The done-set skip on the second visit must not
        // be mistaken for a cycle.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var m: MapResolver = .{ .map = .empty };
        try m.map.put(a, "a", &.{ "x", "y" });
        try m.map.put(a, "x", &.{"c"});
        try m.map.put(a, "y", &.{"c"});
        try m.map.put(a, "c", &.{"leaf"});
        try m.map.put(a, "leaf", &.{});

        const status = try flow_cycle.detectCycle(a, "a", m.resolver());
        try expect.toBeTrue(status == .clean);
    }

    /// Build a `flow_io.FlowDoc` carrying one `Subflow` node per entry
    /// in `flow_refs`. Only `nodes` is populated — `buildRefsFingerprint`
    /// reads nothing else. Caller owns `nodes` (allocated on `a`).
    fn docWithSubflowRefs(
        a: std.mem.Allocator,
        flow_refs: []const []const u8,
    ) !flow_io.FlowDoc {
        const nodes = try a.alloc(flow_io.Node, flow_refs.len);
        for (flow_refs, 0..) |r, i| {
            nodes[i] = .{
                .id = @intCast(i + 1),
                .type_name = "Subflow",
                .kind = .subflow,
                .flow_ref = r,
            };
        }
        return .{ .arena = undefined, .nodes = nodes };
    }

    test "buildRefsFingerprint distinguishes ref sets that collide under newline-joining" {
        // A `flow_ref` is a JSON string and may contain a newline.
        // Joining refs with `\n` is ambiguous: one ref "a\nb" produces
        // the exact same bytes as two refs "a", "b". The fingerprint
        // must keep these distinct so a changed reference set is never
        // mistaken for "unchanged" and the cycle check re-runs.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const doc_one = try docWithSubflowRefs(a, &.{"a\nb"});
        const doc_two = try docWithSubflowRefs(a, &.{ "a", "b" });

        var fp_one = try flow_doc.buildRefsFingerprint(a, doc_one);
        defer fp_one.deinit(a);
        var fp_two = try flow_doc.buildRefsFingerprint(a, doc_two);
        defer fp_two.deinit(a);

        try expect.toBeTrue(!std.mem.eql(u8, fp_one.items, fp_two.items));
    }

    test "buildRefsFingerprint is stable for an identical ref set" {
        // Same refs in the same order must produce identical bytes —
        // otherwise the check would re-run every frame.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const doc_a = try docWithSubflowRefs(a, &.{ "alpha", "beta\ngamma" });
        const doc_b = try docWithSubflowRefs(a, &.{ "alpha", "beta\ngamma" });

        var fp_a = try flow_doc.buildRefsFingerprint(a, doc_a);
        defer fp_a.deinit(a);
        var fp_b = try flow_doc.buildRefsFingerprint(a, doc_b);
        defer fp_b.deinit(a);

        try expect.toBeTrue(std.mem.eql(u8, fp_a.items, fp_b.items));
    }

    test "buildRefsFingerprint encoding cannot be reproduced by a different ref split" {
        // Length-prefixing must defeat *every* re-split, not just the
        // newline case. A plain NUL separator is also insufficient — a
        // `flow_ref` may contain a NUL — so ["x\x00y"] and ["x", "y"]
        // must differ too, as must order-only changes.
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const sets = [_][]const []const u8{
            &.{"xy"},
            &.{ "x", "y" },
            &.{ "y", "x" },
            &.{"x\x00y"},
            &.{ "x\ny", "z" },
            &.{ "x", "y\nz" },
        };
        var seen: std.ArrayList([]const u8) = .empty;
        defer {
            for (seen.items) |s| a.free(s);
            seen.deinit(a);
        }
        for (sets) |set| {
            const doc = try docWithSubflowRefs(a, set);
            var fp = try flow_doc.buildRefsFingerprint(a, doc);
            defer fp.deinit(a);
            for (seen.items) |prev| {
                try expect.toBeTrue(!std.mem.eql(u8, prev, fp.items));
            }
            try seen.append(a, try a.dupe(u8, fp.items));
        }
    }

    fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const ts = timestampSeconds();
        const dir_name = try std.fmt.allocPrint(
            allocator,
            "/tmp/labelle_flowcycle_{d}",
            .{ts},
        );
        try std.Io.Dir.cwd().createDir(io_global.io(), dir_name, .default_dir);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.Io.Dir.cwd().deleteTree(io_global.io(), dir_path) catch {};
        allocator.free(dir_path);
    }

    /// Write `<flows_dir>/<name>.flow.jsonc` with a `Subflow` node per
    /// entry in `refs`.
    fn writeFlow(
        allocator: std.mem.Allocator,
        flows_dir: []const u8,
        name: []const u8,
        refs: []const []const u8,
    ) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.appendSlice(allocator, "{ \"event\": { \"type\": \"OnCall\" }, \"nodes\": [");
        for (refs, 0..) |r, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(allocator,
                " {{ \"id\": {d}, \"type\": \"Subflow\", \"flow\": \"{s}\", \"pos\": [0, 0] }}",
                .{ i + 1, r });
        }
        try buf.appendSlice(allocator, " ], \"edges\": [] }\n");

        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}{s}",
            .{ flows_dir, name, flow_io.extension },
        );
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = buf.items,
        });
    }

    test "analyze reads referenced flows from disk and reports a cycle" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // a → b → a, written as real .flow.jsonc files.
        try writeFlow(allocator, flows_dir, "b", &.{"a"});

        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"b"}, // live (unsaved) Subflow refs of the open doc "a"
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .cycle);
    }

    test "analyze reports an unresolved reference for a missing file" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // "a" references "ghost" — no ghost.flow.jsonc on disk.
        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"ghost"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .unresolved);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.unresolved.names[report.status.unresolved.names.len - 1],
            "ghost",
        ));
    }

    test "analyze reports clean for an acyclic on-disk reference graph" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // a → b → c, all real files, no cycle.
        try writeFlow(allocator, flows_dir, "b", &.{"c"});
        try writeFlow(allocator, flows_dir, "c", &.{});

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
    }

    /// Write `<flows_dir>/<file>.flow.jsonc` carrying an explicit
    /// top-level `name` (its effective registry name) that differs from
    /// the filename, with a `Subflow` node per entry in `refs`.
    fn writeNamedFlow(
        allocator: std.mem.Allocator,
        flows_dir: []const u8,
        file: []const u8,
        reg_name: []const u8,
        refs: []const []const u8,
    ) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);
        try buf.print(allocator,
            "{{ \"name\": \"{s}\", \"event\": {{ \"type\": \"OnCall\" }}, \"nodes\": [",
            .{reg_name});
        for (refs, 0..) |r, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.print(allocator,
                " {{ \"id\": {d}, \"type\": \"Subflow\", \"flow\": \"{s}\", \"pos\": [0, 0] }}",
                .{ i + 1, r });
        }
        try buf.appendSlice(allocator, " ], \"edges\": [] }\n");

        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}{s}",
            .{ flows_dir, file, flow_io.extension },
        );
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = buf.items,
        });
    }

    test "analyze resolves a reference by registry name, not filename" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // The open doc "a" references "tick_logic" — a registry name.
        // On disk that flow lives in `b_file.flow.jsonc`, whose
        // top-level `name` is "tick_logic". Keying on the filename
        // would mis-report this as unresolved.
        try writeNamedFlow(allocator, flows_dir, "b_file", "tick_logic", &.{});

        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"tick_logic"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
    }

    test "analyze detects a cycle through registry-name resolution" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // a → reg_b → a, where reg_b's flow file is `b_file.flow.jsonc`
        // (filename ≠ registry name) and it Subflow-references "a".
        try writeNamedFlow(allocator, flows_dir, "b_file", "reg_b", &.{"a"});

        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"reg_b"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .cycle);
    }

    test "analyze flags a reference that matches a filename but not a registry name" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // `b_file.flow.jsonc` has registry name "reg_b". A Subflow that
        // references the *filename* "b_file" must NOT resolve — only the
        // effective registry name "reg_b" is a valid target.
        try writeNamedFlow(allocator, flows_dir, "b_file", "reg_b", &.{});

        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"b_file"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .unresolved);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.unresolved.names[report.status.unresolved.names.len - 1],
            "b_file",
        ));
    }

    test "analyze still resolves a flow with no name by its filename" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // `plain.flow.jsonc` has no top-level `name`; its effective
        // registry name falls back to the filename basename "plain".
        try writeFlow(allocator, flows_dir, "plain", &.{});

        var report = try flow_cycle.analyze(
            allocator,
            "a",
            &.{"plain"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
    }

    test "analyze populates chain_text once for a cycle" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        try writeFlow(allocator, flows_dir, "b", &.{"a"});

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .cycle);
        // chain_text is rendered at analysis time: a → b → a.
        try expect.toBeTrue(report.chain_text.len > 0);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.chain_text,
            "a \u{2192} b \u{2192} a",
        ));
    }

    /// Write `<flows_dir>/<name>.flow.jsonc` with deliberately broken
    /// content — valid as a file on disk, but not parseable as a flow
    /// (here: a top-level array, not an object).
    fn writeBrokenFlow(
        allocator: std.mem.Allocator,
        flows_dir: []const u8,
        name: []const u8,
    ) !void {
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}{s}",
            .{ flows_dir, name, flow_io.extension },
        );
        defer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io_global.io(), .{
            .sub_path = path,
            .data = "[ this is not valid flow json ]\n",
        });
    }

    test "analyze flags a referenced file that exists but fails to parse" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // "a" references "b"; b.flow.jsonc exists on disk but its
        // content is not parseable. This must be reported distinctly
        // from a plain missing file — `parse_failed`, not `unresolved`.
        try writeBrokenFlow(allocator, flows_dir, "b");

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .parse_failed);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.parse_failed.names[
                report.status.parse_failed.names.len - 1
            ],
            "b",
        ));
        // A genuinely missing file is still `unresolved`, not
        // `parse_failed` — the two stay distinct.
        var missing = try flow_cycle.analyze(allocator, "a", &.{"ghost"}, flows_dir, "");
        defer missing.deinit();
        try expect.toBeTrue(missing.status == .unresolved);
    }

    test "analyze records the referenced files it read on the report" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        try writeFlow(allocator, flows_dir, "b", &.{"c"});
        try writeFlow(allocator, flows_dir, "c", &.{});

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        // The resolver scans every `.flow.jsonc` in `flows_dir` to build
        // its registry-name index, so both files are recorded with a
        // stat-able mtime.
        try expect.toBeTrue(report.read_files.len == 2);
        for (report.read_files) |f| {
            try expect.toBeTrue(f.mtime_ns != null);
            try expect.toBeTrue(f.size != null);
        }
    }

    test "referencedFilesChanged re-triggers when a referenced file changes on disk" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // Initial graph: a → b → c, acyclic and clean.
        try writeFlow(allocator, flows_dir, "b", &.{"c"});
        try writeFlow(allocator, flows_dir, "c", &.{});

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
        // Nothing has changed on disk yet — no re-trigger.
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&report));

        // Edit a *transitively*-referenced flow so it now closes a cycle
        // (c → a). The open flow's own Subflow refs ({"b"}) are
        // unchanged, so only the on-disk stamp reveals the staleness.
        // `writeFlow` truncates and rewrites `c.flow.jsonc`.
        try writeFlow(allocator, flows_dir, "c", &.{"a"});
        try expect.toBeTrue(flow_doc.referencedFilesChanged(&report));

        // Re-running the check now sees the cycle the stale report
        // missed.
        var fresh = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer fresh.deinit();
        try expect.toBeTrue(fresh.status == .cycle);
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&fresh));
    }

    test "referencedFilesChanged re-triggers when a previously-missing referenced file is created" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // The open doc "a" references "b", but b.flow.jsonc does not
        // exist yet — the check reports `unresolved`. `read_files` only
        // stamps files that were successfully read (here just none, or
        // whatever the directory scan saw), so it can never notice "b"
        // appearing; `unresolved_targets` must carry the expected path.
        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .unresolved);
        // The missing target is recorded with its expected `.flow.jsonc`
        // path so a later check can stat it.
        try expect.toBeTrue(report.unresolved_targets.len == 1);
        try expect.toBeFalse(report.unresolved_targets[0].parse_failed);
        // Nothing has appeared on disk yet — no re-trigger.
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&report));

        // Create the previously-missing referenced flow. It even closes
        // a cycle (b → a). The open flow's own Subflow refs ({"b"}) are
        // unchanged, so only the appearance of the missing target can
        // reveal the staleness.
        try writeFlow(allocator, flows_dir, "b", &.{"a"});
        try expect.toBeTrue(flow_doc.referencedFilesChanged(&report));

        // Re-running the check now resolves "b" and sees the cycle the
        // stale "unresolved" report could not.
        var fresh = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer fresh.deinit();
        try expect.toBeTrue(fresh.status == .cycle);
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&fresh));
    }

    test "referencedFilesChanged re-triggers when a parse-failed referenced file is fixed" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // "a" references "b"; b.flow.jsonc exists but does not parse —
        // the check reports `parse_failed` and stamps the broken file.
        try writeBrokenFlow(allocator, flows_dir, "b");

        var report = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .parse_failed);
        try expect.toBeTrue(report.unresolved_targets.len == 1);
        try expect.toBeTrue(report.unresolved_targets[0].parse_failed);
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&report));

        // Rewrite the broken file with valid, acyclic content.
        try writeFlow(allocator, flows_dir, "b", &.{});
        try expect.toBeTrue(flow_doc.referencedFilesChanged(&report));

        var fresh = try flow_cycle.analyze(allocator, "a", &.{"b"}, flows_dir, "");
        defer fresh.deinit();
        try expect.toBeTrue(fresh.status == .clean);
        try expect.toBeFalse(flow_doc.referencedFilesChanged(&fresh));
    }

    test "analyze flags two on-disk flows sharing one effective registry name" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // Two distinct files, `one.flow.jsonc` and `two.flow.jsonc`,
        // both carry the explicit top-level name "shared" — so they
        // resolve to the *same* effective registry name. flow-codegen's
        // FlowRegistry rejects this as DuplicateFlowName; the editor's
        // first-file-wins index would otherwise silently shadow `two`,
        // potentially hiding a cycle in its `Subflow` refs.
        try writeNamedFlow(allocator, flows_dir, "one", "shared", &.{});
        try writeNamedFlow(allocator, flows_dir, "two", "shared", &.{});

        var report = try flow_cycle.analyze(allocator, "entry", &.{}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .duplicate_name);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.duplicate_name.name,
            "shared",
        ));
        // Both offending files are reported, by their on-disk paths.
        try expect.toBeTrue(std.mem.endsWith(
            u8,
            report.status.duplicate_name.path_a,
            flow_io.extension,
        ));
        try expect.toBeTrue(std.mem.endsWith(
            u8,
            report.status.duplicate_name.path_b,
            flow_io.extension,
        ));
        try expect.toBeFalse(std.mem.eql(
            u8,
            report.status.duplicate_name.path_a,
            report.status.duplicate_name.path_b,
        ));
    }

    test "analyze surfaces a duplicate name ahead of a cycle hidden in the shadowed file" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // `first.flow.jsonc` (name "dup") is clean; `second.flow.jsonc`
        // (also name "dup") Subflow-references "entry", which would close
        // a cycle entry → dup → entry. The first-file-wins index keeps
        // `first`, so the cycle in `second` is never walked — exactly the
        // hazard the duplicate-name check exists to surface. The report
        // must call out the duplicate rather than a misleading clean.
        try writeNamedFlow(allocator, flows_dir, "first", "dup", &.{});
        try writeNamedFlow(allocator, flows_dir, "second", "dup", &.{"entry"});

        var report = try flow_cycle.analyze(
            allocator,
            "entry",
            &.{"dup"},
            flows_dir,
            "",
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .duplicate_name);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.duplicate_name.name,
            "dup",
        ));
    }

    test "analyze flags the open flow's name colliding with an on-disk file" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // The open (possibly unsaved) tab is being edited as "tick". An
        // on-disk `other.flow.jsonc` already claims the registry name
        // "tick" via its top-level `name`. That is the same
        // DuplicateFlowName fault and must be reported even though the
        // open tab itself has no entry in the on-disk index.
        try writeNamedFlow(allocator, flows_dir, "other", "tick", &.{});

        var report = try flow_cycle.analyze(allocator, "tick", &.{}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .duplicate_name);
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.duplicate_name.name,
            "tick",
        ));
        // The open tab has no on-disk path here — it is reported via the
        // `<open flow>` marker, with the conflicting file as `path_b`.
        try expect.toBeTrue(std.mem.eql(
            u8,
            report.status.duplicate_name.path_a,
            flow_cycle.open_flow_marker,
        ));
        try expect.toBeTrue(std.mem.endsWith(
            u8,
            report.status.duplicate_name.path_b,
            flow_io.extension,
        ));
    }

    test "analyze stays clean when every flow has a distinct registry name" {
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // Distinct names — no duplicate, no entry-name collision.
        try writeNamedFlow(allocator, flows_dir, "one", "alpha", &.{});
        try writeNamedFlow(allocator, flows_dir, "two", "beta", &.{});

        var report = try flow_cycle.analyze(allocator, "entry", &.{}, flows_dir, "");
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
    }

    test "analyze does not flag a saved tab as duplicate against its own on-disk file" {
        // Regression: an open flow tab backed by a saved file on disk
        // (e.g. `scripts/flows/hit_counter.flow.jsonc`) caused the
        // editor's banner to fire `duplicate_name` against itself —
        // `ensureIndex` walked the directory, found the tab's own file,
        // and matched its effective name (`"hit_counter"`) against the
        // entry name. The fix threads the tab's on-disk path through to
        // the resolver so a same-path match is skipped. This pins the
        // contract: when `entry_path` IS the on-disk file's path, the
        // report status stays clean.
        const allocator = std.testing.allocator;
        const flows_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, flows_dir);

        // One on-disk file whose effective name is "hit_counter" —
        // claimed via the top-level `name`, matching what the open tab
        // would carry once loaded.
        try writeNamedFlow(allocator, flows_dir, "hit_counter", "hit_counter", &.{});

        // Reconstruct the path `ensureIndex` would join when iterating
        // the directory — `<flows_dir>/<file>.flow.jsonc`. Pass it as
        // `entry_path` so the resolver's same-path check fires.
        const entry_path = try std.fs.path.join(
            allocator,
            &.{ flows_dir, "hit_counter" ++ flow_io.extension },
        );
        defer allocator.free(entry_path);

        var report = try flow_cycle.analyze(
            allocator,
            "hit_counter",
            &.{},
            flows_dir,
            entry_path,
        );
        defer report.deinit();
        try expect.toBeTrue(report.status == .clean);
    }
};
