//! New Scene modal — opened from File > New Scene.
//!
//! Owns the file-creation side-effect because nothing else needs it.
//! Writes a minimal `.scene` stub next to the project's `scenes/` folder
//! and refreshes the tree view on success. Note: the stub format is the
//! pre-engine TOML-ish placeholder; migrating it to engine-compatible
//! `.zon` is tracked separately as issue #21.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const project = @import("../project.zig");

pub fn render(app: *App) void {
    if (app.show_new_scene_dialog) zgui.openPopup("New Scene", .{});
    if (!zgui.beginPopupModal("New Scene", .{
        .popen = &app.show_new_scene_dialog,
        .flags = .{ .always_auto_resize = true },
    })) return;
    defer zgui.endPopup();

    zgui.text("Enter scene name:", .{});
    zgui.spacing();
    if (zgui.isWindowAppearing()) zgui.setKeyboardFocusHere(0);

    const enter_pressed = zgui.inputText("##scene_name", .{
        .buf = &app.new_scene_name,
        .flags = .{ .enter_returns_true = true },
    });

    zgui.spacing();
    zgui.separator();
    zgui.spacing();

    if (zgui.button("Create", .{ .w = 120 }) or enter_pressed) {
        const scene_name = std.mem.sliceTo(&app.new_scene_name, 0);
        if (scene_name.len > 0) createScene(app, scene_name);
        zgui.closeCurrentPopup();
        app.show_new_scene_dialog = false;
    }
    zgui.sameLine(.{});
    if (zgui.button("Cancel", .{ .w = 120 })) {
        zgui.closeCurrentPopup();
        app.show_new_scene_dialog = false;
    }
}

fn createScene(app: *App, scene_name: []const u8) void {
    const proj = app.project_manager.current_project orelse return;
    const proj_dir = proj.getProjectDir() orelse return;

    var path_buf: [512]u8 = undefined;
    const scene_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.scene", .{
        proj_dir,
        project.ProjectFolders.scenes,
        scene_name,
    }) catch {
        app.setStatus("Path too long!");
        return;
    };

    const file = std.fs.cwd().createFile(scene_path, .{ .exclusive = true }) catch |err| {
        app.setStatus(if (err == error.PathAlreadyExists) "Scene already exists!" else "Error creating scene!");
        return;
    };
    defer file.close();

    var content_buf: [512]u8 = undefined;
    const content = std.fmt.bufPrint(&content_buf,
        \\# {s}
        \\# Scene created by Labelle GUI
        \\
        \\[scene]
        \\name = "{s}"
        \\
        \\[entities]
        \\# Define your entities here
        \\
    , .{ scene_name, scene_name }) catch {
        app.setStatus("Error formatting scene content!");
        return;
    };
    file.writeAll(content) catch {
        app.setStatus("Error writing scene file!");
        return;
    };
    app.setStatus("Scene created!");
    app.tree_view.refresh();
}
