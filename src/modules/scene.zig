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

/// Maximum number of `.jsonc` files we'll surface in the prefab
/// picker that opens from the right-click context menu. Real projects
/// in the toolkit (flying-platform etc.) carry well under 100; the
/// cap keeps the popup bounded without an allocator on the menu path.
const max_prefab_picker_entries: usize = 256;
/// Per-entry stem buffer for the prefab picker. Long enough to hold
/// the typical `<stem>.jsonc` filenames in the toolkit (most under
/// 32 chars); names beyond this are truncated for display + selection.
const prefab_picker_name_cap: usize = 64;

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
    /// World-space coordinates of the most recent empty-canvas right-
    /// click. Set by `viewport.render`; consumed by the context menu
    /// when "Add entity here" / "Add entity from prefab…" fires.
    /// Cleared back to null after the popup closes so a stale click
    /// can't be re-used.
    context_menu_world_pos: ?[2]f32 = null,
    /// True while the prefab picker popup is open. We render it as a
    /// nested popup off the context menu so dismissing the picker
    /// doesn't immediately reopen the parent menu.
    show_prefab_picker: bool = false,
    /// Cached `.jsonc` stems under `<project>/prefabs/`, scanned once
    /// when the picker opens. Bounded — see `max_prefab_picker_entries`.
    prefab_picker_names: [max_prefab_picker_entries][prefab_picker_name_cap:0]u8 = undefined,
    /// Number of valid entries in `prefab_picker_names`. Zero means
    /// the scan hasn't run yet (or returned nothing).
    prefab_picker_count: usize = 0,
    /// Filter buffer for the picker's search box. Stays sticky across
    /// reopenings — same convenience the resources panel has.
    prefab_picker_filter: [64:0]u8 = [_:0]u8{0} ** 64,

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
        const display_name = scene_io.displayNameFromPath(path_dup);

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
    _ = zgui.checkbox("gizmos", .{ .v = &app.show_gizmos });
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) saveScene(s, app);
    zgui.separator();

    // Two-column body: viewport on the left, inspector on the right.
    const total_w = zgui.getContentRegionAvail()[0];
    const viewport_w = @max(120.0, total_w - inspector_w - split_gap);

    const atlas_index_ptr: ?*const @import("../atlas.zig").Index = if (app.atlas_index) |*ix| ix else null;
    const gizmo_index_ptr: ?*const @import("../gizmos.zig").Index = if (app.gizmo_index) |*ix| ix else null;

    if (zgui.beginChild("##viewport_col", .{ .w = viewport_w, .h = 0 })) {
        renderViewport(s, atlas_index_ptr, gizmo_index_ptr, app.show_gizmos);
        renderContextMenu(s, app);
        handleDeleteKey(s);
    }
    zgui.endChild();
    zgui.sameLine(.{});
    if (zgui.beginChild("##inspector_col", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    })) {
        renderInspector(s, atlas_index_ptr);
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

fn renderInspector(s: *SceneState, atlas_index: ?*const @import("../atlas.zig").Index) void {
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

    inspector.renderEntity(entity, extras, &s.is_dirty, idx, atlas_index);
}

fn renderViewport(
    s: *SceneState,
    atlas_index: ?*const @import("../atlas.zig").Index,
    gizmo_index: ?*const @import("../gizmos.zig").Index,
    show_gizmos: bool,
) void {
    // Capture right-click world-pos out-of-band; if the viewport sets
    // it this frame we open the context menu before its child closes
    // so the popup roots at the canvas, not at the scene tab body.
    var right_click: ?[2]f32 = null;
    viewport.render(
        .{
            .pan = &s.pan,
            .zoom = &s.zoom,
            .selected_idx = &s.selected_index,
            .is_dirty = &s.is_dirty,
            .drag_armed = &s.drag_armed,
            .right_click_world = &right_click,
        },
        s.loaded.scene.entities,
        s.loaded.extras.entity_components,
        atlas_index,
        gizmo_index,
        show_gizmos,
    );
    if (right_click) |world| {
        s.context_menu_world_pos = world;
        zgui.openPopup("##scene_context", .{});
    }
}

/// Context-menu popup that fires after a right-click in empty canvas
/// space. Rendered outside the canvas child so the popup window roots
/// at the scene tab, not the canvas (which closes its own ID stack).
/// "Add entity here" appends an empty `Entity` carrying just the
/// recorded position; "Add entity from prefab…" opens a nested
/// picker. The picker scans `<project>/prefabs/` lazily — once per
/// open — so a project with many prefabs doesn't penalize every frame.
fn renderContextMenu(s: *SceneState, app: *App) void {
    if (zgui.beginPopup("##scene_context", .{})) {
        defer zgui.endPopup();
        if (zgui.menuItem("Add entity here", .{})) {
            if (s.context_menu_world_pos) |p| {
                addBlankEntity(s, p) catch |err| {
                    std.log.err("addEntity failed: {s}", .{@errorName(err)});
                    app.setStatus("Add entity failed!");
                };
            }
            s.context_menu_world_pos = null;
        }
        if (zgui.menuItem("Add entity from prefab...", .{})) {
            scanPrefabPickerNames(s, app);
            s.show_prefab_picker = true;
        }
    } else {
        // Popup is closed (either by selection or click-away). Drop
        // the cached world-pos so the next right-click reads fresh.
        if (!s.show_prefab_picker) s.context_menu_world_pos = null;
    }
    renderPrefabPicker(s, app);
}

fn renderPrefabPicker(s: *SceneState, app: *App) void {
    if (s.show_prefab_picker) zgui.openPopup("##scene_prefab_picker", .{});
    if (!zgui.beginPopup("##scene_prefab_picker", .{})) {
        s.show_prefab_picker = false;
        return;
    }
    defer zgui.endPopup();

    zgui.text("Select a prefab:", .{});
    _ = zgui.inputText("##prefab_filter", .{ .buf = &s.prefab_picker_filter });
    zgui.separator();

    const filter = std.mem.sliceTo(&s.prefab_picker_filter, 0);
    var any_shown: bool = false;
    var i: usize = 0;
    while (i < s.prefab_picker_count) : (i += 1) {
        const name_buf = &s.prefab_picker_names[i];
        const name = std.mem.sliceTo(name_buf, 0);
        if (filter.len > 0 and std.mem.indexOf(u8, name, filter) == null) continue;
        any_shown = true;
        // The stored buffer is [prefab_picker_name_cap:0]u8, so its
        // contents are sentinel-terminated already — just hand the
        // sentinel-typed slice to `selectable`.
        const label: [:0]const u8 = name_buf[0..name.len :0];
        if (zgui.selectable(label, .{})) {
            const pos = s.context_menu_world_pos orelse .{ 0, 0 };
            addPrefabEntity(s, name, pos) catch |err| {
                std.log.err("addPrefabEntity failed: {s}", .{@errorName(err)});
                app.setStatus("Add entity failed!");
            };
            s.show_prefab_picker = false;
            s.context_menu_world_pos = null;
            zgui.closeCurrentPopup();
            break;
        }
    }
    if (!any_shown) zgui.textDisabled("(no prefabs found)", .{});
}

/// Walk `<project>/prefabs/` and fold each `.jsonc` filename's stem
/// into `s.prefab_picker_names`. Errors (missing folder, permission
/// problems) are swallowed and reported as an empty picker — same
/// tolerance the tree view + gizmo loader use.
fn scanPrefabPickerNames(s: *SceneState, app: *App) void {
    s.prefab_picker_count = 0;
    const proj = app.project_manager.current_project orelse return;
    const proj_dir = proj.getProjectDir() orelse return;
    const prefabs_dir = std.fs.path.join(app.allocator, &.{
        proj_dir,
        project.ProjectFolders.prefabs,
    }) catch return;
    defer app.allocator.free(prefabs_dir);

    var dir = std.fs.cwd().openDir(prefabs_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |dirent| {
        if (s.prefab_picker_count >= max_prefab_picker_entries) break;
        if (dirent.kind != .file) continue;
        if (!std.mem.endsWith(u8, dirent.name, ".jsonc")) continue;
        const stem = dirent.name[0 .. dirent.name.len - ".jsonc".len];
        const slot = &s.prefab_picker_names[s.prefab_picker_count];
        @memset(slot, 0);
        const n = @min(stem.len, prefab_picker_name_cap);
        @memcpy(slot[0..n], stem[0..n]);
        s.prefab_picker_count += 1;
    }
}

fn addBlankEntity(s: *SceneState, world: [2]f32) !void {
    // No prefab name, just a Position — by-value, no arena alloc needed.
    try scene_io.insertEntity(&s.loaded, .{
        .position = .{ .x = world[0], .y = world[1] },
    });
    s.selected_index = s.loaded.scene.entities.len - 1;
    s.is_dirty = true;
}

fn addPrefabEntity(s: *SceneState, name: []const u8, world: [2]f32) !void {
    // Prefab name must live as long as the LoadedScene — dupe into
    // the scene's arena so it survives across renders. Position is a
    // by-value scalar so no allocation needed for it.
    const arena = s.loaded.arena.allocator();
    const dup = try arena.dupe(u8, name);
    try scene_io.insertEntity(&s.loaded, .{
        .prefab = dup,
        .position = .{ .x = world[0], .y = world[1] },
    });
    s.selected_index = s.loaded.scene.entities.len - 1;
    s.is_dirty = true;
}

fn handleDeleteKey(s: *SceneState) void {
    // Delete-key path: trigger only when the canvas (or one of its
    // children) is hovered so the inspector's text fields aren't
    // disrupted by an entity-targeting Delete. `isKeyPressed(repeat=false)`
    // intentionally rejects key-repeat — one press, one entity.
    if (!zgui.isWindowHovered(.{ .child_windows = true })) return;
    if (!zgui.isKeyPressed(.delete, false)) return;
    const idx = s.selected_index orelse return;
    scene_io.removeEntity(&s.loaded, idx) catch return;
    s.selected_index = null;
    s.is_dirty = true;
}

/// Re-exported so existing zspec tests (and any other caller of
/// `scene_module.hitTestEntity`) keep working after the viewport
/// extraction.
pub const hitTestEntity = viewport.hitTestEntity;
