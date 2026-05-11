//! Project Settings panel — edits the current `ProjectConfig` and writes
//! `project.labelle` back to disk.
//!
//! The panel keeps its own sentinel-terminated string buffers because
//! `zgui.inputText` writes into the buffer in-place; we can't hand it
//! the arena-allocated `[]const u8` slices stored on `Project.config`.
//! Buffers re-sync from the live config whenever the active project
//! pointer changes. Save dupes the buffers back into `Project.arena`
//! (old strings stay in the arena until project close — acceptable
//! since the arena is short-lived).

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const project = @import("../project.zig");
const buf = @import("../buf.zig");

const name_cap = 128;
const description_cap = 256;
const title_cap = 128;
const scene_cap = 64;
const version_cap = 32;

pub const ProjectSettings = struct {
    name: [name_cap:0]u8 = [_:0]u8{0} ** name_cap,
    description: [description_cap:0]u8 = [_:0]u8{0} ** description_cap,
    title: [title_cap:0]u8 = [_:0]u8{0} ** title_cap,
    initial_scene: [scene_cap:0]u8 = [_:0]u8{0} ** scene_cap,
    core_version: [version_cap:0]u8 = [_:0]u8{0} ** version_cap,
    engine_version: [version_cap:0]u8 = [_:0]u8{0} ** version_cap,
    gfx_version: [version_cap:0]u8 = [_:0]u8{0} ** version_cap,
    assembler_version: [version_cap:0]u8 = [_:0]u8{0} ** version_cap,

    width: i32 = 800,
    height: i32 = 600,
    target_fps: i32 = 60,

    backend: project.Backend = .raylib,
    ecs: project.EcsChoice = .zig_ecs,

    /// `ProjectManager.generation` value at the time these buffers
    /// were filled. Comparing the counter instead of `*Project`
    /// avoids the ABA case where GPA hands back the same address
    /// after a close/new cycle and the panel would otherwise show
    /// the previous project's values.
    last_generation: ?u64 = null,
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "project_settings",
        .display_name = "Project Settings",
        .is_open = &app.show_project_settings,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Project Settings", .{
        .popen = &app.show_project_settings,
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const proj = app.project_manager.current_project orelse {
        zgui.textDisabled("No project open", .{});
        return;
    };

    syncIfNeeded(&app.project_settings, app.project_manager.generation, proj);
    const s = &app.project_settings;

    _ = zgui.inputText("Name", .{ .buf = &s.name });
    _ = zgui.inputText("Description", .{ .buf = &s.description });
    _ = zgui.inputText("Title", .{ .buf = &s.title });
    _ = zgui.inputText("Initial scene", .{ .buf = &s.initial_scene });

    zgui.separator();
    _ = zgui.inputInt("Width", .{ .v = &s.width });
    _ = zgui.inputInt("Height", .{ .v = &s.height });
    _ = zgui.inputInt("Target FPS", .{ .v = &s.target_fps });

    zgui.separator();
    _ = zgui.comboFromEnum("Backend", &s.backend);
    _ = zgui.comboFromEnum("ECS", &s.ecs);

    zgui.separator();
    _ = zgui.inputText("core_version", .{ .buf = &s.core_version });
    _ = zgui.inputText("engine_version", .{ .buf = &s.engine_version });
    _ = zgui.inputText("gfx_version", .{ .buf = &s.gfx_version });
    _ = zgui.inputText("assembler_version", .{ .buf = &s.assembler_version });

    zgui.separator();
    if (zgui.button("Save", .{ .w = 120 })) saveAndPersist(app, proj);
    zgui.sameLine(.{});
    if (zgui.button("Revert", .{ .w = 120 })) {
        s.last_generation = null; // force resync next frame
    }
}

fn syncIfNeeded(s: *ProjectSettings, gen: u64, proj: *project.Project) void {
    if (s.last_generation) |g| {
        if (g == gen) return;
    }
    syncFromConfig(s, proj);
    s.last_generation = gen;
}

fn syncFromConfig(s: *ProjectSettings, proj: *const project.Project) void {
    const c = proj.config;
    buf.writeZeroed(&s.name, c.name);
    buf.writeZeroed(&s.description, c.description);
    buf.writeZeroed(&s.title, c.title);
    buf.writeZeroed(&s.initial_scene, c.initial_scene);
    buf.writeZeroed(&s.core_version, c.core_version);
    buf.writeZeroed(&s.engine_version, c.engine_version);
    buf.writeZeroed(&s.gfx_version, c.gfx_version);
    buf.writeZeroed(&s.assembler_version, c.assembler_version);
    s.width = @intCast(c.width);
    s.height = @intCast(c.height);
    s.target_fps = @intCast(c.target_fps);
    s.backend = c.backend;
    s.ecs = c.ecs;
}

fn saveAndPersist(app: *App, proj: *project.Project) void {
    applyBuffers(app, proj) catch |err| {
        std.log.err("Project Settings: apply failed: {s}", .{@errorName(err)});
        app.setStatus("Error applying settings!");
        return;
    };
    const dir = proj.dir orelse {
        app.setStatus("Project has no path — use Save As first");
        return;
    };
    app.project_manager.saveProject(dir) catch |err| {
        std.log.err("Project Settings: save failed: {s}", .{@errorName(err)});
        app.setStatus("Error saving project!");
        return;
    };
    app.setStatus("Project settings saved!");
}

/// Write buffer values back into `proj.config`. Strings are duped into
/// the project's arena, so the original arena-allocated slices are not
/// freed — they're abandoned. That's intentional: ArenaAllocator
/// doesn't reclaim individual frees and the project's arena lives only
/// as long as the project itself, so the leak is bounded.
fn applyBuffers(app: *App, proj: *project.Project) !void {
    const a = proj.arena.allocator();
    const s = &app.project_settings;

    proj.config.name = try a.dupe(u8, bufStr(&s.name));
    proj.config.description = try a.dupe(u8, bufStr(&s.description));
    proj.config.title = try a.dupe(u8, bufStr(&s.title));
    proj.config.initial_scene = try a.dupe(u8, bufStr(&s.initial_scene));
    proj.config.core_version = try a.dupe(u8, bufStr(&s.core_version));
    proj.config.engine_version = try a.dupe(u8, bufStr(&s.engine_version));
    proj.config.gfx_version = try a.dupe(u8, bufStr(&s.gfx_version));
    proj.config.assembler_version = try a.dupe(u8, bufStr(&s.assembler_version));
    proj.config.width = @intCast(@max(s.width, 0));
    proj.config.height = @intCast(@max(s.height, 0));
    proj.config.target_fps = @intCast(@max(s.target_fps, 0));
    proj.config.backend = s.backend;
    proj.config.ecs = s.ecs;
    proj.markDirty();
}

fn bufStr(slice: []const u8) []const u8 {
    return std.mem.sliceTo(slice, 0);
}
