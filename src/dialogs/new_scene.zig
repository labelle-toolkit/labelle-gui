//! New Scene modal — opened from File > New Scene.
//!
//! Writes a `<project>/scenes/<name>.jsonc` file in the format
//! `labelle-engine`'s scene loader expects: a top-level JSON object with
//! `name` and `entities` (with `include` and `assets` reserved for
//! future use). New scenes are seeded with one commented-out entity so
//! the user has the shape in front of them — they're not loadable until
//! the user fills the entities list, which is fine for now (this is
//! just the file scaffold; rich editing is a later issue).

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const project = @import("../project.zig");
const io_global = @import("../io_global.zig");

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

    // Allocate via std.fs.path.join — handles arbitrary-length project
    // dirs and uses the platform's native separator.
    // App.new_scene_name is 128 bytes; ".jsonc" + slack lands inside 160.
    var file_name_buf: [160]u8 = undefined;
    const file_name = std.fmt.bufPrint(&file_name_buf, "{s}.jsonc", .{scene_name}) catch {
        app.setStatus("Scene name too long!");
        return;
    };
    const scene_path = std.fs.path.join(app.allocator, &.{
        proj_dir,
        project.ProjectFolders.scenes,
        file_name,
    }) catch {
        app.setStatus("Out of memory!");
        return;
    };
    defer app.allocator.free(scene_path);

    const content = renderSceneJsonc(app.allocator) catch {
        app.setStatus("Error formatting scene content!");
        return;
    };
    defer app.allocator.free(content);

    std.Io.Dir.cwd().writeFile(io_global.io(), .{
        .sub_path = scene_path,
        .data = content,
        .flags = .{ .exclusive = true },
    }) catch |err| {
        app.setStatus(if (err == error.PathAlreadyExists) "Scene already exists!" else "Error writing scene!");
        return;
    };
    app.setStatus("Scene created!");
    app.tree_view.refresh();
}

/// Format an engine-compatible JSONC scene scaffold in RFC #596
/// bundle shape (see `../scene_io.zig` for the schema). The scene's
/// identity comes from its filename, so no name field appears on
/// disk. The array body is empty but accompanied by one
/// commented-out example so the user can see how prefab + inline-
/// component entries are written without us guessing which prefabs
/// they registered.
///
/// Pure / no I/O so it can be exercised from zspec without touching the
/// filesystem.
pub fn renderSceneJsonc(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8,
        \\[
        \\    // { "meta": { "initial_state": "playing" } },
        \\    // { "prefab": "my_prefab", "Position": { "x": 0, "y": 0 } }
        \\]
        \\
    );
}
