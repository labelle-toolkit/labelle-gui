//! Project Tree sidebar — togglable panel showing the project's file tree.
//!
//! Always rendered at x=0 with a fixed `sidebar_width`. When toggled off
//! via the View menu, the space is left empty — Main Content keeps its
//! hardcoded position. Re-enable to bring the tree back.

const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const config = @import("../config.zig");

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "project_tree",
        .display_name = "Project Tree",
        .is_open = &app.show_project_tree,
        .render_panel = render,
    };
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
            _ = app.tree_view.render(proj.getProjectDir());
        } else {
            zgui.textDisabled("No project open", .{});
        }
    }
    zgui.end();
}
