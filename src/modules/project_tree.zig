//! Project Tree sidebar — togglable panel showing the project's file tree.
//!
//! Always rendered at x=0 with a fixed `sidebar_width`. When toggled off
//! via the View menu, the space is left empty — Main Content keeps its
//! hardcoded position. Re-enable to bring the tree back.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const config = @import("../config.zig");
const project = @import("../project.zig");

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "project_tree",
        .display_name = "Project Tree",
        .is_open = &app.show_project_tree,
        .render_panel = render,
    };
}

/// Return true when `path` is a `.jsonc` file under the project's
/// `scenes/` directory (including subdirectories — engine scenes
/// support nested fragments). Prefabs and other `.jsonc` files
/// elsewhere in the project return false; the caller skips opening
/// them as scenes.
pub fn isScenePath(proj_dir: ?[]const u8, path: []const u8) bool {
    return isUnderFolder(proj_dir, path, project.ProjectFolders.scenes);
}

/// Mirror of `isScenePath` for `prefabs/*.jsonc`. Used to route a
/// tree click on a prefab file into the prefab editor rather than
/// the scene editor.
pub fn isPrefabPath(proj_dir: ?[]const u8, path: []const u8) bool {
    return isUnderFolder(proj_dir, path, project.ProjectFolders.prefabs);
}

fn isUnderFolder(proj_dir: ?[]const u8, path: []const u8, folder: []const u8) bool {
    const dir = proj_dir orelse return false;
    if (!std.mem.endsWith(u8, path, ".jsonc")) return false;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/{s}/", .{ dir, folder }) catch return false;
    return std.mem.startsWith(u8, path, prefix);
}

fn render(app: *App) void {
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();
    zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] });
    zgui.setNextWindowSize(.{
        .w = config.ui.sidebar_width,
        .h = work_size[1] - config.ui.status_bar_height,
    });

    if (zgui.begin("Project", .{ .flags = .{
        .no_resize = true,
        .no_move = true,
        .no_collapse = true,
    } })) {
        if (app.project_manager.current_project) |proj| {
            // Tree returns true on the frame a file is newly clicked.
            // `.jsonc` files under `scenes/` route to the scene
            // editor; `.jsonc` files under `prefabs/` route to the
            // prefab editor. The two paths are mutually exclusive
            // (see `isScenePath` / `isPrefabPath`) so a single click
            // never opens both.
            if (app.tree_view.render(proj.getProjectDir())) {
                if (app.tree_view.getSelectedPath()) |path| {
                    const proj_dir = proj.getProjectDir();
                    if (isScenePath(proj_dir, path)) {
                        app.openScene(path) catch |err| {
                            std.log.err("Failed to open scene {s}: {s}", .{ path, @errorName(err) });
                            app.setStatus("Error opening scene!");
                        };
                    } else if (isPrefabPath(proj_dir, path)) {
                        app.openPrefab(path) catch |err| {
                            std.log.err("Failed to open prefab {s}: {s}", .{ path, @errorName(err) });
                            app.setStatus("Error opening prefab!");
                        };
                    }
                }
            }
        } else {
            zgui.textDisabled("No project open", .{});
        }
    }
    zgui.end();
}
