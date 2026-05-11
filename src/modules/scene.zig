//! Scene module — togglable panel that lists `<project>/scenes/*.jsonc`,
//! parses a selected scene, and renders entity positions in a 2D
//! viewport. Read-only for this slice; editing (selection, drag-to-move,
//! save-back) is a follow-up.
//!
//! Memory model: the loaded scene owns an arena (see `scene_io.zig`)
//! that lives across frames until the user picks another scene or
//! closes the project. The module also keeps a `loaded_name` to detect
//! when the selection has changed and needs to be reloaded from disk.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const project = @import("../project.zig");
const scene_io = @import("../scene_io.zig");

const name_cap = 128;
const sidebar_w: f32 = 200;
const viewport_min_h: f32 = 240;

pub const SceneState = struct {
    /// Name (without extension) of the scene the user has clicked in
    /// the file list. Empty = nothing selected.
    selected_name: [name_cap:0]u8 = [_:0]u8{0} ** name_cap,
    /// Name of the scene currently held in `loaded`. When this differs
    /// from `selected_name`, the next `render` call reloads from disk.
    loaded_name: [name_cap:0]u8 = [_:0]u8{0} ** name_cap,
    loaded: ?scene_io.LoadedScene = null,
    /// Viewport pan / zoom state (world-space offset + scale factor).
    pan: [2]f32 = .{ 320, 240 },
    zoom: f32 = 1.0,
    /// Project pointer the selection was tracked against — closes
    /// `loaded` when the active project changes so we don't carry stale
    /// arena memory across project switches.
    last_synced: ?*const project.Project = null,

    pub fn deinit(self: *SceneState) void {
        if (self.loaded) |*l| l.deinit();
        self.loaded = null;
    }
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "scene",
        .display_name = "Scene",
        .is_open = &app.show_scene,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Scene", .{
        .popen = &app.show_scene,
        .flags = .{ .menu_bar = false },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const proj = app.project_manager.current_project orelse {
        zgui.textDisabled("No project open", .{});
        return;
    };

    syncProjectChange(&app.scene_state, proj);
    maybeLoadSelected(&app.scene_state, proj);

    renderFileList(&app.scene_state, proj);
    zgui.sameLine(.{});
    renderInspectorAndViewport(&app.scene_state);
}

fn syncProjectChange(s: *SceneState, proj: *project.Project) void {
    if (s.last_synced == proj) return;
    s.deinit();
    @memset(&s.selected_name, 0);
    @memset(&s.loaded_name, 0);
    s.last_synced = proj;
}

fn maybeLoadSelected(s: *SceneState, proj: *project.Project) void {
    const sel = std.mem.sliceTo(&s.selected_name, 0);
    const cur = std.mem.sliceTo(&s.loaded_name, 0);
    if (sel.len == 0) return;
    if (std.mem.eql(u8, sel, cur)) return;
    const dir = proj.dir orelse return;

    if (s.loaded) |*l| l.deinit();
    s.loaded = null;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}/{s}.jsonc", .{
        dir,
        project.ProjectFolders.scenes,
        sel,
    }) catch return;

    s.loaded = scene_io.loadFromFile(proj.allocator, path) catch |err| {
        std.log.warn("Scene module: failed to load {s}: {s}", .{ path, @errorName(err) });
        @memset(&s.loaded_name, 0);
        return;
    };
    copyToBuf(&s.loaded_name, sel);
}

// ─── File list ──────────────────────────────────────────────────────────

fn renderFileList(s: *SceneState, proj: *project.Project) void {
    _ = zgui.beginChild("##scene_files", .{
        .w = sidebar_w,
        .h = 0,
        .child_flags = .{ .border = true },
    });
    defer zgui.endChild();

    zgui.text("Scenes", .{});
    zgui.separator();

    const dir_path = proj.dir orelse return;
    var path_buf: [512]u8 = undefined;
    const scenes_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
        dir_path,
        project.ProjectFolders.scenes,
    }) catch return;

    var dir = std.fs.cwd().openDir(scenes_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonc")) continue;
        const stem = entry.name[0 .. entry.name.len - ".jsonc".len];

        var label_buf: [name_cap + 1]u8 = undefined;
        const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{stem}) catch continue;

        const is_selected = std.mem.eql(u8, std.mem.sliceTo(&s.selected_name, 0), stem);
        if (zgui.selectable(label, .{ .selected = is_selected })) {
            copyToBuf(&s.selected_name, stem);
        }
    }
}

// ─── Inspector + Viewport ───────────────────────────────────────────────

fn renderInspectorAndViewport(s: *SceneState) void {
    _ = zgui.beginChild("##scene_main", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    });
    defer zgui.endChild();

    const loaded = s.loaded orelse {
        zgui.textDisabled("Select a scene from the list.", .{});
        return;
    };

    zgui.text("Scene: {s}", .{loaded.scene.name});
    zgui.text("Entities: {d}", .{loaded.scene.entities.len});
    zgui.separator();

    // Pan/zoom controls. Scroll-wheel reading isn't exposed by zgui's
    // wrapper today, so we use buttons. Pan is middle-button drag in
    // the canvas below.
    if (zgui.button("Reset view", .{})) {
        s.pan = .{ 320, 240 };
        s.zoom = 1.0;
    }
    zgui.sameLine(.{});
    if (zgui.button("-", .{ .w = 24 })) s.zoom = @max(0.1, s.zoom * 0.8);
    zgui.sameLine(.{});
    if (zgui.button("+", .{ .w = 24 })) s.zoom = @min(8.0, s.zoom * 1.25);
    zgui.sameLine(.{});
    zgui.text("zoom: {d:.2}x", .{s.zoom});
    zgui.separator();

    renderEntityList(loaded);
    zgui.separator();
    renderViewport(s, loaded);
}

fn renderEntityList(loaded: scene_io.LoadedScene) void {
    if (loaded.scene.entities.len == 0) {
        zgui.textDisabled("(no entities)", .{});
        return;
    }
    if (!zgui.beginChild("##entity_list", .{ .w = 0, .h = 100 })) {
        zgui.endChild();
        return;
    }
    defer zgui.endChild();

    for (loaded.scene.entities, 0..) |e, i| {
        const prefab = e.prefab orelse "(no prefab)";
        if (e.position) |p| {
            zgui.text("{d}. {s} @ ({d:.0}, {d:.0})", .{ i, prefab, p.x, p.y });
        } else {
            zgui.text("{d}. {s}", .{ i, prefab });
        }
    }
}

fn renderViewport(s: *SceneState, loaded: scene_io.LoadedScene) void {
    const avail = zgui.getContentRegionAvail();
    const canvas_h = @max(viewport_min_h, avail[1]);
    if (!zgui.beginChild("##canvas", .{
        .w = 0,
        .h = canvas_h,
        .child_flags = .{ .border = true },
    })) {
        zgui.endChild();
        return;
    }
    defer zgui.endChild();

    const dl = zgui.getWindowDrawList();
    const cur_pos = zgui.getCursorScreenPos();
    const canvas_size = zgui.getContentRegionAvail();
    const canvas_min = cur_pos;
    const canvas_max: [2]f32 = .{ cur_pos[0] + canvas_size[0], cur_pos[1] + canvas_size[1] };

    // Background.
    dl.addRectFilled(.{
        .pmin = canvas_min,
        .pmax = canvas_max,
        .col = 0xff202225,
    });

    drawGrid(dl, canvas_min, canvas_max, s.*);
    drawEntities(dl, canvas_min, canvas_max, s.*, loaded);

    // Invisible button covering the canvas catches drag events for pan.
    _ = zgui.invisibleButton("##canvas_drag", .{ .w = canvas_size[0], .h = canvas_size[1], .flags = .{} });
    if (zgui.isItemActive() and zgui.isMouseDragging(.middle, 0)) {
        const d = zgui.getMouseDragDelta(.middle, .{});
        s.pan[0] += d[0];
        s.pan[1] += d[1];
        // resetMouseDragDelta isn't exposed; consume by tracking delta
        // each frame the user is dragging. This is "good enough" — the
        // delta resets when the drag ends.
        zgui.resetMouseDragDelta(.middle);
    }
}

fn drawGrid(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, s: SceneState) void {
    const grid_world: f32 = 64; // world units per cell
    const step = grid_world * s.zoom;
    if (step <= 4) return; // too dense to be useful

    const col_major: u32 = 0x40_ff_ff_ff;
    const col_minor: u32 = 0x20_ff_ff_ff;
    _ = col_minor;

    // Where world (0,0) lands in canvas space.
    const origin_x = cmin[0] + s.pan[0];
    const origin_y = cmin[1] + s.pan[1];

    // Vertical lines.
    var x = origin_x;
    while (x > cmin[0]) : (x -= step) {}
    while (x < cmax[0]) : (x += step) {
        dl.addLine(.{
            .p1 = .{ x, cmin[1] },
            .p2 = .{ x, cmax[1] },
            .col = col_major,
            .thickness = 1.0,
        });
    }
    // Horizontal lines.
    var y = origin_y;
    while (y > cmin[1]) : (y -= step) {}
    while (y < cmax[1]) : (y += step) {
        dl.addLine(.{
            .p1 = .{ cmin[0], y },
            .p2 = .{ cmax[0], y },
            .col = col_major,
            .thickness = 1.0,
        });
    }

    // Axis lines (slightly brighter) through world origin.
    dl.addLine(.{ .p1 = .{ origin_x, cmin[1] }, .p2 = .{ origin_x, cmax[1] }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
    dl.addLine(.{ .p1 = .{ cmin[0], origin_y }, .p2 = .{ cmax[0], origin_y }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
}

fn drawEntities(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, s: SceneState, loaded: scene_io.LoadedScene) void {
    _ = cmax;
    for (loaded.scene.entities) |e| {
        const pos = e.position orelse continue;
        const px = cmin[0] + s.pan[0] + pos.x * s.zoom;
        const py = cmin[1] + s.pan[1] + pos.y * s.zoom;
        const col = colorForPrefab(e.prefab);
        dl.addCircleFilled(.{
            .p = .{ px, py },
            .r = 6,
            .col = col,
            .num_segments = 16,
        });
        if (e.prefab) |p| {
            dl.addText(.{ px + 8, py - 8 }, 0xff_e0_e0_e0, "{s}", .{p});
        }
    }
}

/// Stable per-prefab color. Hashes the prefab name to a hue so distinct
/// prefabs visually separate without us shipping a palette table.
fn colorForPrefab(prefab: ?[]const u8) u32 {
    const h = if (prefab) |p| std.hash.Wyhash.hash(0, p) else 0;
    const r: u8 = @truncate((h >> 0) | 0x80);
    const g: u8 = @truncate((h >> 8) | 0x80);
    const b: u8 = @truncate((h >> 16) | 0x80);
    return (@as(u32, 0xff) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}

fn copyToBuf(buf: []u8, src: []const u8) void {
    @memset(buf, 0);
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
}
