const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const compiler = @import("compiler.zig");
const new_scene = @import("dialogs/new_scene.zig");

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
