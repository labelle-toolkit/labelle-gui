const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const project = @import("project.zig");
const tree_view = @import("tree_view.zig");
const compiler = @import("compiler.zig");

test {
    zspec.runAll(@This());
}

pub const ProjectMetadataTests = struct {
    test "has correct default version" {
        const metadata = project.ProjectMetadata{
            .name = "test",
            .created_at = 0,
            .modified_at = 0,
        };
        try expect.equal(metadata.version, project.PROJECT_VERSION);
    }

    test "has empty description by default" {
        const metadata = project.ProjectMetadata{
            .name = "test",
            .created_at = 0,
            .modified_at = 0,
        };
        try expect.equal(metadata.description.len, 0);
    }
};

pub const ProjectFoldersTests = struct {
    fn containsFolder(name: []const u8) bool {
        for (project.ProjectFolders.all) |folder| {
            if (std.mem.eql(u8, folder, name)) return true;
        }
        return false;
    }

    test "has 6 default folders" {
        try expect.equal(project.ProjectFolders.all.len, 6);
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

        try expect.toBeTrue(std.mem.eql(u8, proj.metadata.name, "TestProject"));
    }

    test "is marked dirty on creation" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "TestProject");
        defer proj.deinit();

        try expect.toBeTrue(proj.is_dirty);
    }

    test "has no path on creation" {
        const allocator = std.testing.allocator;
        const proj = try project.Project.create(allocator, "TestProject");
        defer proj.deinit();

        try expect.toBeTrue(proj.path == null);
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
    test "PROJECT_EXTENSION is .labelle" {
        try expect.toBeTrue(std.mem.eql(u8, project.PROJECT_EXTENSION, ".labelle"));
    }

    test "PROJECT_VERSION is 1" {
        try expect.equal(project.PROJECT_VERSION, 1);
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

/// System tests for end-to-end project compilation
pub const ProjectCompilationTests = struct {
    fn createTempDir(allocator: std.mem.Allocator) ![]const u8 {
        const tmp_base = "/tmp";
        const timestamp = std.time.timestamp();
        const dir_name = try std.fmt.allocPrint(allocator, "{s}/labelle_test_{d}", .{ tmp_base, timestamp });

        try std.fs.cwd().makeDir(dir_name);
        return dir_name;
    }

    fn deleteTempDir(allocator: std.mem.Allocator, dir_path: []const u8) void {
        std.fs.cwd().deleteTree(dir_path) catch {};
        allocator.free(dir_path);
    }

    test "generates valid build.zig" {
        const allocator = std.testing.allocator;

        // Create temp directory
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Create project
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("test_project");

        // Save project to temp directory
        const project_path = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_dir});
        defer allocator.free(project_path);

        try pm.saveProject(project_path);

        // Generate build files
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try comp.generateAllBuildFiles(pm.current_project.?);

        // Verify build.zig exists
        const build_zig_path = try std.fmt.allocPrint(allocator, "{s}/build.zig", .{temp_dir});
        defer allocator.free(build_zig_path);

        const build_zig = try std.fs.cwd().openFile(build_zig_path, .{});
        defer build_zig.close();

        const content = try build_zig.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Verify key parts of build.zig
        try expect.toBeTrue(std.mem.indexOf(u8, content, "labelle_engine") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "labelle-gfx") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "zig_ecs") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "main.zig") != null);
    }

    test "generates valid build.zig.zon with fingerprint" {
        const allocator = std.testing.allocator;

        // Create temp directory
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Create project
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("test_project");

        // Save project
        const project_path = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_dir});
        defer allocator.free(project_path);

        try pm.saveProject(project_path);

        // Generate build files
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try comp.generateAllBuildFiles(pm.current_project.?);

        // Verify build.zig.zon exists and has correct content
        const zon_path = try std.fmt.allocPrint(allocator, "{s}/build.zig.zon", .{temp_dir});
        defer allocator.free(zon_path);

        const zon_file = try std.fs.cwd().openFile(zon_path, .{});
        defer zon_file.close();

        const content = try zon_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Verify key parts of build.zig.zon
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".fingerprint") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".name = .test_project") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "labelle_engine") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "labelle-gfx") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "zig_ecs") != null);
        // Verify hashes are present
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".hash = ") != null);
    }

    test "generates main.zig with Game facade" {
        const allocator = std.testing.allocator;

        // Create temp directory
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Create project
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("test_project");

        // Save project
        const project_path = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_dir});
        defer allocator.free(project_path);

        try pm.saveProject(project_path);

        // Generate build files
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try comp.generateAllBuildFiles(pm.current_project.?);

        // Verify main.zig exists at root (not in src/)
        const main_path = try std.fmt.allocPrint(allocator, "{s}/main.zig", .{temp_dir});
        defer allocator.free(main_path);

        const main_file = try std.fs.cwd().openFile(main_path, .{});
        defer main_file.close();

        const content = try main_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Verify main.zig uses Game facade
        try expect.toBeTrue(std.mem.indexOf(u8, content, "engine.Game.init") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "ComponentRegistry") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "SceneLoader") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, "scenes/main.zon") != null);
    }

    test "generates scene .zon file" {
        const allocator = std.testing.allocator;

        // Create temp directory
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Create project
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("test_project");

        // Save project
        const project_path = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_dir});
        defer allocator.free(project_path);

        try pm.saveProject(project_path);

        // Generate build files
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try comp.generateAllBuildFiles(pm.current_project.?);

        // Verify main.zon scene exists
        const scene_path = try std.fmt.allocPrint(allocator, "{s}/scenes/main.zon", .{temp_dir});
        defer allocator.free(scene_path);

        const scene_file = try std.fs.cwd().openFile(scene_path, .{});
        defer scene_file.close();

        const content = try scene_file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        // Verify scene has valid structure
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".name = ") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".entities = ") != null);
        try expect.toBeTrue(std.mem.indexOf(u8, content, ".shape = ") != null);
    }

    test "creates project folder structure" {
        const allocator = std.testing.allocator;

        // Create temp directory
        const temp_dir = try createTempDir(allocator);
        defer deleteTempDir(allocator, temp_dir);

        // Create project
        var pm = project.ProjectManager.init(allocator);
        defer pm.deinit();

        try pm.newProject("test_project");

        // Save project
        const project_path = try std.fmt.allocPrint(allocator, "{s}/project", .{temp_dir});
        defer allocator.free(project_path);

        try pm.saveProject(project_path);

        // Generate build files
        var comp = compiler.Compiler.init(allocator);
        defer comp.deinit();

        try comp.generateAllBuildFiles(pm.current_project.?);

        // Verify folder structure
        const folders = [_][]const u8{ "components", "scripts", "prefabs", "assets", "scenes" };
        for (folders) |folder| {
            const folder_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ temp_dir, folder });
            defer allocator.free(folder_path);

            var dir = std.fs.cwd().openDir(folder_path, .{}) catch {
                std.debug.print("Missing folder: {s}\n", .{folder});
                return error.MissingFolder;
            };
            dir.close();
        }
    }
};
