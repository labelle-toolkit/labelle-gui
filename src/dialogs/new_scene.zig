//! New Scene modal — opened from File > New Scene.
//!
//! Writes a `<project>/scenes/<name>.zon` file in the format
//! `labelle-engine`'s `SceneLoader` expects: a top-level ZON struct with
//! `name` and `entities` (with `scripts` reserved for future use). New
//! scenes are seeded with one commented-out entity so the user has the
//! shape in front of them — they're not loadable until the user fills
//! the entities list, which is fine for now (this is just the file
//! scaffold; rich editing is a later issue).

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
    const scene_path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.zon", .{
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

    const content = renderSceneZon(app.allocator, scene_name) catch {
        app.setStatus("Error formatting scene content!");
        return;
    };
    defer app.allocator.free(content);

    file.writeAll(content) catch {
        app.setStatus("Error writing scene file!");
        return;
    };
    app.setStatus("Scene created!");
    app.tree_view.refresh();
}

/// Format an engine-compatible ZON scene scaffold for `scene_name`.
/// Top-level shape matches `labelle-engine`'s `SceneLoader` expectations
/// (see `labelle-engine/scene/src/types.zig`): `name`, `entities`, and
/// optional `scripts`. The `entities` list is empty but accompanied by
/// one commented-out example so the user can see how prefab + component
/// entries are written without us guessing which prefabs they registered.
///
/// Pure / no I/O so it can be exercised from zspec without touching the
/// filesystem.
pub fn renderSceneZon(allocator: std.mem.Allocator, scene_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = "{s}",
        \\    // .scripts = .{{ "my_script" }},
        \\    .entities = .{{
        \\        // .{{
        \\        //     .prefab = "my_prefab",
        \\        //     .components = .{{
        \\        //         .Position = .{{ .x = 0, .y = 0 }},
        \\        //     }},
        \\        // }},
        \\    }},
        \\}}
        \\
    , .{scene_name});
}
