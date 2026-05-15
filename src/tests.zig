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
const gizmos = @import("gizmos.zig");
const preview = @import("preview.zig");
const flow_projector = @import("flows/projector.zig");
const flow_types = @import("flows/types.zig");
const prefs = @import("prefs.zig");
const io_global = @import("io_global.zig");

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

        // Build a project with one resource directly via the arena so
        // the slice is owned correctly. Save then reload via a fresh
        // ProjectManager and assert the resource came back intact.
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.newProject("with_resources");

        const proj = pm.current_project.?;
        const a = proj.arena.allocator();
        const resources = try a.alloc(project.ResourceDef, 1);
        resources[0] = .{
            .name = try a.dupe(u8, "sprites"),
            .json = try a.dupe(u8, "assets/sprites.json"),
            .texture = try a.dupe(u8, "assets/sprites.png"),
        };
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

pub const PreferencesTests = struct {
    fn tmpPath(allocator: std.mem.Allocator, tmp: std.testing.TmpDir) ![]u8 {
        // `std.testing.tmpDir` plants the temp dir at `.zig-cache/tmp/<sub_path>`
        // (see std.testing.tmpDir in 0.16). Build the relative path string
        // directly rather than calling `realPathFileAlloc(io, ".")`, which
        // deadlocks on ubuntu CI under `std.testing.io` (a `Threaded` Io).
        // The downstream `prefs.loadFromPath` / `saveToPath` are happy with
        // a relative path — they use `std.Io.Dir.cwd().readFileAlloc(io, ...)`
        // which resolves it normally.
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
