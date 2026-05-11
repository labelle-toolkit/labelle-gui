//! Prefab editor — per-tab state and rendering.
//!
//! A prefab is a single entity blueprint stored at
//! `<project>/prefabs/<name>.jsonc` with the shape
//! `{ "components": { ... }, "children": [ ... ] }`. The top-level
//! `components` is the prefab's own component set; the optional
//! `children` array is a list of sub-entities each with their own
//! Position and components (used heavily for visual decoration —
//! e.g. a room prefab whose Sprite tiles live as children).
//!
//! UX mirrors the scene editor: viewport on the left renders the
//! children with their positions (the prefab itself has no position
//! and sits implicitly at world origin), inspector on the right
//! shows the selected entity. When nothing is selected the inspector
//! shows the prefab's own components.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const scene_io = @import("../scene_io.zig");
const inspector = @import("inspector.zig");
const viewport = @import("viewport.zig");

const inspector_w: f32 = 300;
const split_gap: f32 = 8;

pub const PrefabState = struct {
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    display_name: []const u8,
    loaded: scene_io.LoadedPrefab,

    /// Index into `loaded.children`; null means "the prefab itself
    /// is selected" (inspector shows the prefab's own components).
    selected_child_idx: ?usize = null,
    is_dirty: bool = false,
    drag_armed: bool = false,
    pan: [2]f32 = .{ 320, 240 },
    zoom: f32 = 1.0,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !PrefabState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = scene_io.displayNameFromPath(path_dup);

        const loaded = try scene_io.loadPrefabFromFile(allocator, path);
        return .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .loaded = loaded,
        };
    }

    pub fn deinit(self: *PrefabState, allocator: std.mem.Allocator) void {
        self.loaded.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

pub fn render(s: *PrefabState, app: *App) void {
    zgui.text("Prefab: {s}", .{s.display_name});
    zgui.sameLine(.{});
    zgui.text("(children: {d})", .{s.loaded.children.len});
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
    if (zgui.button("Save", .{})) savePrefab(s, app);
    zgui.separator();

    // Two-column body, same shape as the scene editor.
    const total_w = zgui.getContentRegionAvail()[0];
    const viewport_w = @max(120.0, total_w - inspector_w - split_gap);

    if (zgui.beginChild("##prefab_viewport_col", .{ .w = viewport_w, .h = 0 })) {
        viewport.render(.{
            .pan = &s.pan,
            .zoom = &s.zoom,
            .selected_idx = &s.selected_child_idx,
            .is_dirty = &s.is_dirty,
            .drag_armed = &s.drag_armed,
        }, s.loaded.children);
    }
    zgui.endChild();
    zgui.sameLine(.{});
    if (zgui.beginChild("##prefab_inspector_col", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    })) {
        renderInspector(s);
    }
    zgui.endChild();
}

pub fn savePrefab(s: *PrefabState, app: *App) void {
    scene_io.savePrefab(app.allocator, s.path, s.loaded) catch |err| {
        std.log.err("Prefab save failed at {s}: {s}", .{ s.path, @errorName(err) });
        app.setStatus("Error saving prefab!");
        return;
    };
    s.is_dirty = false;
    app.setStatus("Prefab saved!");
}

fn renderInspector(s: *PrefabState) void {
    zgui.text("Inspector", .{});
    zgui.separator();

    if (s.selected_child_idx) |idx| {
        if (idx >= s.loaded.children.len) {
            s.selected_child_idx = null;
            zgui.textDisabled("(selection out of range)", .{});
            return;
        }

        if (zgui.smallButton("← Back to prefab")) {
            s.selected_child_idx = null;
        }
        zgui.separator();

        const child = &s.loaded.children[idx];
        const extras = if (idx < s.loaded.children_extras.len)
            s.loaded.children_extras[idx]
        else
            &[_]scene_io.ComponentExtra{};

        inspector.renderEntity(child, extras, &s.is_dirty, idx);
        return;
    }

    // Nothing selected → show the prefab's own components.
    zgui.text("Prefab body", .{});
    zgui.spacing();
    inspector.renderEntity(&s.loaded.entity, s.loaded.component_extras, &s.is_dirty, null);

    if (s.loaded.children.len > 0) {
        zgui.spacing();
        zgui.separator();
        zgui.textDisabled("Click a child in the viewport, or pick one below:", .{});
        for (s.loaded.children, 0..) |child, i| {
            var label_buf: [256:0]u8 = undefined;
            const label_text = if (child.prefab) |p| p else "(child)";
            const label = std.fmt.bufPrintZ(&label_buf, "#{d} {s}", .{ i, label_text }) catch continue;
            if (zgui.selectable(label, .{})) s.selected_child_idx = i;
        }
    }
}
