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

    test "has 7 default folders" {
        try expect.equal(project.ProjectFolders.all.len, 7);
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

    test "contains prefabs folder" {
        try expect.toBeTrue(containsFolder("prefabs"));
    }

    test "contains scenes folder" {
        try expect.toBeTrue(containsFolder("scenes"));
    }

    test "contains scripts folder" {
        try expect.toBeTrue(containsFolder("scripts"));
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
    test "components folder has cube icon" {
        const icon = tree_view.FolderIcons.forFolder("components");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.components));
    }

    test "fixtures folder has wrench icon" {
        const icon = tree_view.FolderIcons.forFolder("fixtures");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.fixtures));
    }

    test "prefabs folder has box icon" {
        const icon = tree_view.FolderIcons.forFolder("prefabs");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.prefabs));
    }

    test "scenes folder has film icon" {
        const icon = tree_view.FolderIcons.forFolder("scenes");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.scenes));
    }

    test "scripts folder has scroll icon" {
        const icon = tree_view.FolderIcons.forFolder("scripts");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.scripts));
    }

    test "resources folder has database icon" {
        const icon = tree_view.FolderIcons.forFolder("resources");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.resources));
    }

    test "unknown folder returns default folder icon" {
        const icon = tree_view.FolderIcons.forFolder("unknown");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.folder_closed));
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

        try expect.toBeTrue(comp.build_process == null);
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

    test "renderSceneJsonc output re-parses cleanly" {
        // End-to-end: scene → render → re-parse → render again
        // should give us the same managed state plus the same extras.
        const allocator = std.testing.allocator;
        const src =
            \\{
            \\    "name": "x",
            \\    "entities": [
            \\        // c
            \\        { "prefab": "p", "components": { "Position": { "x": 1, "y": 2 }, "Sprite": { "n": "s" } } }
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
        try expect.equal(loaded2.extras.entity_components[0].len, 1);
        try expect.toBeTrue(std.mem.eql(u8, loaded2.extras.entity_components[0][0].name, "Sprite"));
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
        try expect.equal(loaded.component_extras.len, 2);
        // Order matches source: Sprite first, then Coin.
        try expect.toBeTrue(std.mem.eql(u8, loaded.component_extras[0].name, "Sprite"));
        try expect.toBeTrue(std.mem.eql(u8, loaded.component_extras[1].name, "Coin"));
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

        // Re-parse the rendered text to confirm the writer's output is
        // self-consistent — same shape, same extras.
        var loaded2 = try scene_io.parsePrefab(allocator, text);
        defer loaded2.deinit();
        try expect.equal(loaded2.component_extras.len, 2);
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
        const ts = std.time.nanoTimestamp();
        const dir_name = try std.fmt.allocPrint(allocator, "{s}/labelle_test_{d}", .{ tmp_base, ts });
        try std.fs.cwd().makeDir(dir_name);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.fs.cwd().deleteTree(dir_path) catch {};
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

        const file = try std.fs.cwd().openFile(labelle_path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
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

            var dir = std.fs.cwd().openDir(folder_path, .{}) catch {
                std.debug.print("Missing folder: {s}\n", .{folder});
                return error.MissingFolder;
            };
            dir.close();
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
        const file = try std.fs.cwd().openFile(labelle_path, .{});
        defer file.close();
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(synthetic) catch unreachable;
        file.close();

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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(original) catch unreachable;
        file.close();

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const reread = try std.fs.cwd().openFile(labelle_path, .{});
        defer reread.close();
        const saved = try reread.readToEndAlloc(allocator, 1024 * 1024);
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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(original) catch unreachable;
        file.close();

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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(original) catch unreachable;
        file.close();

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);
        try pm.saveProject(temp_dir);

        const reread = try std.fs.cwd().openFile(labelle_path, .{});
        defer reread.close();
        const saved = try reread.readToEndAlloc(allocator, 1024 * 1024);
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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(original) catch unreachable;
        file.close();

        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();
        try pm.loadProject(temp_dir);

        const proj = pm.current_project.?;
        proj.config.title = try proj.arena.allocator().dupe(u8, "New Title");

        try pm.saveProject(temp_dir);

        const reread = try std.fs.cwd().openFile(labelle_path, .{});
        defer reread.close();
        const saved = try reread.readToEndAlloc(allocator, 1024 * 1024);
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
        const file = try std.fs.cwd().createFile(labelle_path, .{});
        file.writeAll(broken) catch unreachable;
        file.close();

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
