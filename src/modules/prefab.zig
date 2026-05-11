//! Prefab editor — per-tab state and rendering.
//!
//! A prefab is a single entity blueprint stored at
//! `<project>/prefabs/<name>.jsonc` with the shape
//! `{ "components": { ... } }`. Conceptually it's "one entity worth
//! of components" that scenes instance by reference. The Prefab tab
//! is therefore just the shared `inspector` view — no viewport, no
//! position-on-grid, since a prefab doesn't position itself.
//!
//! Each `PrefabState` owns:
//!   - an arena for `path` + `display_name`,
//!   - a `LoadedPrefab` (its own arena for parsed body + extras).
//!
//! `deinit(allocator)` frees both.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const scene_io = @import("../scene_io.zig");
const inspector = @import("inspector.zig");

pub const PrefabState = struct {
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    display_name: []const u8,
    loaded: scene_io.LoadedPrefab,
    is_dirty: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !PrefabState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = deriveDisplayName(path_dup);

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

fn deriveDisplayName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".jsonc";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

/// Render a prefab tab. Layout is header + Save button + the shared
/// entity inspector — same renderer the scene editor uses for its
/// selected entity.
pub fn render(s: *PrefabState, app: *App) void {
    zgui.text("Prefab: {s}", .{s.display_name});
    if (s.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
    }
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) savePrefab(s, app);
    zgui.separator();

    inspector.renderEntity(&s.loaded.entity, s.loaded.component_extras, &s.is_dirty, null);
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
