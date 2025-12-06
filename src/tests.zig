const std = @import("std");
const zspec = @import("zspec");
const expect = zspec.expect;

const project = @import("project.zig");
const tree_view = @import("tree_view.zig");

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

    test "has 5 default folders" {
        try expect.equal(project.ProjectFolders.all.len, 5);
    }

    test "contains models folder" {
        try expect.toBeTrue(containsFolder("models"));
    }

    test "contains fixtures folder" {
        try expect.toBeTrue(containsFolder("fixtures"));
    }

    test "contains prefabs folder" {
        try expect.toBeTrue(containsFolder("prefabs"));
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
    test "models folder has theater mask icon" {
        const icon = tree_view.FolderIcons.forFolder("models");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.models));
    }

    test "fixtures folder has wrench icon" {
        const icon = tree_view.FolderIcons.forFolder("fixtures");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.fixtures));
    }

    test "prefabs folder has package icon" {
        const icon = tree_view.FolderIcons.forFolder("prefabs");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.prefabs));
    }

    test "scripts folder has scroll icon" {
        const icon = tree_view.FolderIcons.forFolder("scripts");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.scripts));
    }

    test "resources folder has folder icon" {
        const icon = tree_view.FolderIcons.forFolder("resources");
        try expect.toBeTrue(std.mem.eql(u8, icon, tree_view.FolderIcons.resources));
    }

    test "unknown folder returns default icon" {
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
