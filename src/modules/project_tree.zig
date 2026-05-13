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
    return isUnderFolder(proj_dir, path, project.ProjectFolders.scenes, ".jsonc");
}

/// Mirror of `isScenePath` for `prefabs/*.jsonc`. Used to route a
/// tree click on a prefab file into the prefab editor rather than
/// the scene editor.
pub fn isPrefabPath(proj_dir: ?[]const u8, path: []const u8) bool {
    return isUnderFolder(proj_dir, path, project.ProjectFolders.prefabs, ".jsonc");
}

/// Return true when `path` is a `.zig` file under the project's
/// `scripts/flows/` directory. Drives routing of tree clicks into
/// the Flow viewer (issues #48 + #49, umbrella #42).
///
/// Schema choice: the visualization layer is *derived* from Zig
/// scripts. There is no `.flow.*` file format — the source of
/// truth is the underlying Zig the engine actually compiles. The
/// gui's projector (`src/flows/projector.zig`) parses the file via
/// `std.zig.Ast` and renders it as a node graph.
pub fn isFlowPath(proj_dir: ?[]const u8, path: []const u8) bool {
    const dir = proj_dir orelse return false;
    if (!std.mem.endsWith(u8, path, ".zig")) return false;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(
        &prefix_buf,
        "{s}/{s}/{s}/",
        .{ dir, project.ProjectFolders.scripts, "flows" },
    ) catch return false;
    return std.mem.startsWith(u8, path, prefix);
}

/// Return true when `path` is a `.zon` file under the project's
/// `gizmos/` directory. Gizmos are ZON, not JSONC, so this is the
/// one router arm that uses a different extension. The folder name
/// is hardcoded here rather than pulled from `project.ProjectFolders`
/// to keep this PR independent of the parallel scaffold/folder-listing
/// change a sibling PR is making — both PRs can land in either order.
pub fn isGizmoPath(proj_dir: ?[]const u8, path: []const u8) bool {
    return isUnderFolder(proj_dir, path, "gizmos", ".zon");
}

fn isUnderFolder(proj_dir: ?[]const u8, path: []const u8, folder: []const u8, ext: []const u8) bool {
    const dir = proj_dir orelse return false;
    if (!std.mem.endsWith(u8, path, ext)) return false;
    var prefix_buf: [std.fs.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/{s}/", .{ dir, folder }) catch return false;
    return std.mem.startsWith(u8, path, prefix);
}

fn render(app: *App) void {
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();
    // Clamp the persisted width to a sane range every frame so a
    // pathological resize (e.g. dragging past the editor area) recovers
    // on the next frame.
    const min_w: f32 = 120.0;
    const max_w: f32 = work_size[0] * 0.6;
    app.sidebar_width = std.math.clamp(app.sidebar_width, min_w, max_w);
    zgui.setNextWindowPos(.{ .x = work_pos[0], .y = work_pos[1] });
    zgui.setNextWindowSize(.{
        .w = app.sidebar_width,
        .h = work_size[1] - config.ui.status_bar_height,
        .cond = .always,
    });

    if (zgui.begin("Project", .{ .flags = .{
        .no_move = true,
        .no_collapse = true,
    } })) {
        // Read back the live window width — ImGui updates this in-place
        // while the user drags the right edge — so the main content
        // window can shift to follow on the same frame.
        app.sidebar_width = zgui.getWindowSize()[0];
        if (app.project_manager.current_project) |proj| {
            // Tree returns true on the frame a file is newly clicked.
            // `.jsonc` files under `scenes/` route to the scene
            // editor; `.jsonc` files under `prefabs/` route to the
            // prefab editor; `.zon` files under `gizmos/` route to
            // the gizmo editor. The three are mutually exclusive
            // (different folders and/or extensions) so a single
            // click never opens more than one.
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
                    } else if (isFlowPath(proj_dir, path)) {
                        app.openFlow(path) catch |err| {
                            std.log.err("Failed to open flow {s}: {s}", .{ path, @errorName(err) });
                            app.setStatus("Error opening flow!");
                        };
                    } else if (isGizmoPath(proj_dir, path)) {
                        app.openGizmo(path) catch |err| {
                            std.log.err("Failed to open gizmo {s}: {s}", .{ path, @errorName(err) });
                            app.setStatus("Error opening gizmo!");
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
