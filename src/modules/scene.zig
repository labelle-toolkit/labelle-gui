//! Scene editor — per-tab state and rendering.
//!
//! No longer a top-level View-menu panel. The Scene editor opens as a
//! tab in the main content area when the user clicks a `.jsonc` file
//! in the project tree. `App` owns an `ArrayList(SceneState)` of open
//! tabs; this module renders one tab's body (inspector + viewport)
//! given a single state.
//!
//! Each `SceneState` carries its own arena (for path/display name
//! strings) and a `LoadedScene` (which carries its own arena for the
//! parsed scene data). `deinit(allocator)` frees both.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const project = @import("../project.zig");
const scene_io = @import("../scene_io.zig");
const config = @import("../config.zig");

const viewport_min_h: f32 = 240;

pub const SceneState = struct {
    /// Owns `path` and `display_name`. `loaded` has its own internal
    /// arena (created by scene_io.parseScene) for the parsed scene.
    arena: *std.heap.ArenaAllocator,
    /// Absolute path on disk. Used for Save and for dedup when opening.
    path: []const u8,
    /// Stem without `.jsonc` extension. Used for the tab label.
    display_name: []const u8,
    loaded: scene_io.LoadedScene,

    /// Index into `loaded.scene.entities`; null = nothing selected.
    selected_index: ?usize = null,
    /// True after any in-memory edit (drag, inspector input, comment).
    /// Cleared on successful Save. Drives the dirty indicator + the
    /// close-tab confirmation dialog.
    is_dirty: bool = false,
    /// Set between mouse-down on a selected entity and mouse-up so a
    /// drag started in empty canvas space doesn't move the previously
    /// selected entity by accident.
    drag_armed: bool = false,
    /// Viewport pan / zoom state. Per-tab — each open scene keeps its
    /// own camera.
    pan: [2]f32 = .{ 320, 240 },
    zoom: f32 = 1.0,

    /// Load a scene from disk and wrap it in a fresh SceneState. The
    /// returned state owns an arena holding the path + display name,
    /// plus the LoadedScene's own arena for parsed data.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SceneState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = deriveDisplayName(path_dup);

        const loaded = try scene_io.loadFromFile(allocator, path);
        return .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .loaded = loaded,
        };
    }

    pub fn deinit(self: *SceneState, allocator: std.mem.Allocator) void {
        self.loaded.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// Returns the file basename with its `.jsonc` extension stripped.
/// `path` must outlive the returned slice (we just slice into it).
fn deriveDisplayName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".jsonc";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

const inspector_w: f32 = 300;
const split_gap: f32 = 8;

/// Render a single open scene as the content of a tab. Caller has
/// already entered the tab item; we just paint the body. Layout is
/// scene-level header + controls across the top, then a viewport
/// child on the left and an inspector child on the right.
pub fn render(s: *SceneState, app: *App) void {
    zgui.text("Scene: {s}", .{s.loaded.scene.name});
    zgui.sameLine(.{});
    zgui.text("(entities: {d})", .{s.loaded.scene.entities.len});
    if (s.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
    }
    zgui.separator();

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
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) saveScene(s, app);
    zgui.separator();

    // Two-column body: viewport on the left, inspector on the right.
    const total_w = zgui.getContentRegionAvail()[0];
    const viewport_w = @max(120.0, total_w - inspector_w - split_gap);

    if (zgui.beginChild("##viewport_col", .{ .w = viewport_w, .h = 0 })) {
        renderViewport(s);
    }
    zgui.endChild();
    zgui.sameLine(.{});
    if (zgui.beginChild("##inspector_col", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    })) {
        renderInspector(s);
    }
    zgui.endChild();
}

/// Write the current scene back to its source path. Clears the dirty
/// flag and posts a status message on success.
pub fn saveScene(s: *SceneState, app: *App) void {
    scene_io.saveScene(app.allocator, s.path, s.loaded) catch |err| {
        std.log.err("Scene save failed at {s}: {s}", .{ s.path, @errorName(err) });
        app.setStatus("Error saving scene!");
        return;
    };
    s.is_dirty = false;
    app.setStatus("Scene saved!");
}

fn renderInspector(s: *SceneState) void {
    zgui.text("Inspector", .{});
    zgui.separator();

    const idx = s.selected_index orelse {
        zgui.textDisabled("Click an entity in the viewport to select.", .{});
        return;
    };
    if (idx >= s.loaded.scene.entities.len) {
        s.selected_index = null;
        zgui.textDisabled("(selection out of range)", .{});
        return;
    }
    const e = &s.loaded.scene.entities[idx];
    const prefab = e.prefab orelse "(no prefab)";
    zgui.text("Entity #{d}", .{idx});
    if (e.prefab) |p| zgui.text("prefab: {s}", .{p}) else {
        _ = prefab;
        zgui.textDisabled("(no prefab)", .{});
    }
    zgui.spacing();

    // Position is the only component the gui models structurally.
    // Other components are read from the captured extras list and
    // rendered as collapsible value previews.
    if (zgui.collapsingHeader("Position", .{ .default_open = true })) {
        if (e.position) |*pos| {
            if (zgui.inputFloat("x", .{ .v = &pos.x })) s.is_dirty = true;
            if (zgui.inputFloat("y", .{ .v = &pos.y })) s.is_dirty = true;
        } else {
            zgui.textDisabled("(no Position component)", .{});
        }
    }

    if (zgui.collapsingHeader("Comment", .{})) {
        if (zgui.inputTextMultiline("##comment", .{
            .buf = &e.comment,
            .w = 0,
            .h = 80,
        })) s.is_dirty = true;
    }

    // Per-entity unmodeled components captured verbatim at load time
    // (Sprite, Shape, user-defined). Read-only display for now —
    // structured editing of these is a follow-up; users can still
    // hand-edit the .jsonc directly and reopen the scene.
    if (idx < s.loaded.extras.entity_components.len) {
        const extras = s.loaded.extras.entity_components[idx];
        if (extras.len > 0) {
            zgui.spacing();
            zgui.separator();
            zgui.textDisabled("Other components ({d})", .{extras.len});
            for (extras) |extra| {
                var label_buf: [128:0]u8 = undefined;
                const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{extra.name}) catch continue;
                if (zgui.collapsingHeader(label, .{})) {
                    zgui.textUnformatted(extra.value_text);
                }
            }
        }
    }
}

fn renderViewport(s: *SceneState) void {
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

    dl.addRectFilled(.{
        .pmin = canvas_min,
        .pmax = canvas_max,
        .col = 0xff202225,
    });

    drawGrid(dl, canvas_min, canvas_max, s.*);
    drawEntities(dl, canvas_min, canvas_max, s.*, s.loaded);

    _ = zgui.invisibleButton("##canvas_drag", .{ .w = canvas_size[0], .h = canvas_size[1], .flags = .{} });

    // Mouse-down: hit-test entity markers, arm drag-to-move only when
    // the click landed on an entity.
    if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left)) {
        const mouse = zgui.getMousePos();
        const hit = hitTestEntity(s.loaded.scene.entities, mouse, canvas_min, s.pan, s.zoom);
        s.selected_index = hit;
        s.drag_armed = hit != null;
    }
    if (!zgui.isMouseDown(.left)) s.drag_armed = false;

    if (zgui.isItemActive()) {
        if (zgui.isMouseDragging(.middle, 0)) {
            const d = zgui.getMouseDragDelta(.middle, .{});
            s.pan[0] += d[0];
            s.pan[1] += d[1];
            zgui.resetMouseDragDelta(.middle);
        }
        if (s.drag_armed) {
            if (s.selected_index) |idx| {
                if (idx < s.loaded.scene.entities.len and zgui.isMouseDragging(.left, 0)) {
                    const e = &s.loaded.scene.entities[idx];
                    if (e.position) |*pos| {
                        const d = zgui.getMouseDragDelta(.left, .{});
                        pos.x += d[0] / s.zoom;
                        // World +y is up; screen +y is down.
                        pos.y -= d[1] / s.zoom;
                        s.is_dirty = true;
                        zgui.resetMouseDragDelta(.left);
                    }
                }
            }
        }
    }
}

fn drawGrid(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, s: SceneState) void {
    const grid_world: f32 = 64;
    const step = grid_world * s.zoom;
    if (step <= 4) return;

    const col_major: u32 = 0x40_ff_ff_ff;

    const origin_x = cmin[0] + s.pan[0];
    const origin_y = cmin[1] + s.pan[1];

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

    dl.addLine(.{ .p1 = .{ origin_x, cmin[1] }, .p2 = .{ origin_x, cmax[1] }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
    dl.addLine(.{ .p1 = .{ cmin[0], origin_y }, .p2 = .{ cmax[0], origin_y }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
}

fn drawEntities(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, s: SceneState, loaded: scene_io.LoadedScene) void {
    _ = cmax;
    for (loaded.scene.entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = cmin[0] + s.pan[0] + pos.x * s.zoom;
        // World +y is up.
        const py = cmin[1] + s.pan[1] - pos.y * s.zoom;
        const col = colorForPrefab(e.prefab);
        dl.addCircleFilled(.{
            .p = .{ px, py },
            .r = 6,
            .col = col,
            .num_segments = 16,
        });
        if (s.selected_index == i) {
            dl.addCircle(.{
                .p = .{ px, py },
                .r = 12,
                .col = 0xff_ff_d2_40,
                .num_segments = 24,
                .thickness = 2.0,
            });
        }
        if (e.prefab) |p| {
            dl.addText(.{ px + 8, py - 8 }, 0xff_e0_e0_e0, "{s}", .{p});
        }
    }
}

pub const hit_radius: f32 = 10.0;

pub fn hitTestEntity(
    entities: []scene_io.Entity,
    mouse: [2]f32,
    canvas_min: [2]f32,
    pan: [2]f32,
    zoom: f32,
) ?usize {
    var best: ?usize = null;
    var best_d2: f32 = hit_radius * hit_radius;
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = canvas_min[0] + pan[0] + pos.x * zoom;
        const py = canvas_min[1] + pan[1] - pos.y * zoom;
        const dx = mouse[0] - px;
        const dy = mouse[1] - py;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = i;
        }
    }
    return best;
}

fn colorForPrefab(prefab: ?[]const u8) u32 {
    const h = if (prefab) |p| std.hash.Wyhash.hash(0, p) else 0;
    const r: u8 = @truncate((h >> 0) | 0x80);
    const g: u8 = @truncate((h >> 8) | 0x80);
    const b: u8 = @truncate((h >> 16) | 0x80);
    return (@as(u32, 0xff) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}
