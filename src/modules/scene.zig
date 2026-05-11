//! Scene editor — per-tab state and rendering.
//!
//! Inspector body is delegated to `modules/inspector.zig`, which
//! is shared with the prefab editor. This module owns the
//! viewport (canvas, grid, pan/zoom, hit-test, drag-to-move) and
//! the scene-specific Save path.
//!
//! Opens as a tab when the user clicks a `.jsonc` file under
//! `<project>/scenes/`. `App` owns an `ArrayList(OpenTab)` whose
//! `.scene` variant wraps a `SceneState`; this module renders one
//! such state given a single value.
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
const inspector = @import("inspector.zig");
const viewport = @import("viewport.zig");

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

    const entity = &s.loaded.scene.entities[idx];
    const extras = if (idx < s.loaded.extras.entity_components.len)
        s.loaded.extras.entity_components[idx]
    else
        &[_]scene_io.ComponentExtra{};

    inspector.renderEntity(entity, extras, &s.is_dirty, idx);
}

fn renderViewport(s: *SceneState) void {
    viewport.render(.{
        .pan = &s.pan,
        .zoom = &s.zoom,
        .selected_idx = &s.selected_index,
        .is_dirty = &s.is_dirty,
        .drag_armed = &s.drag_armed,
    }, s.loaded.scene.entities);
}

/// Re-exported so existing zspec tests (and any other caller of
/// `scene_module.hitTestEntity`) keep working after the viewport
/// extraction.
pub const hitTestEntity = viewport.hitTestEntity;
