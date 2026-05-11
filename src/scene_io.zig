//! Read-only JSONC scene loader for the Scene module.
//!
//! `labelle-engine` scenes live at `<project>/scenes/<name>.jsonc` in the
//! shape `{ "name": "...", "entities": [ ... ] }`. Each entity is an
//! object with an optional `"prefab"` reference and a `"components"`
//! map keyed by component name. The component value shape is
//! type-specific; we only deserialize the components we draw in the
//! viewport (today: `Position`). Unknown component keys are tolerated.
//!
//! `parseScene` strips `//`-to-EOL comments because `std.json` rejects
//! them. Block-comment style `/* ... */` isn't used in the toolkit's
//! schema and isn't handled here — extend later if it appears.

const std = @import("std");
const buf = @import("buf.zig");

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Maximum bytes (excluding the sentinel) for the per-entity comment
/// editor. 1 KiB fits the typical 1–3 short lines we see in real
/// scenes with room to grow.
pub const comment_cap = 1024;

/// Buffer sizes for the typed Sprite component. The inspector edits
/// these in place via `zgui.inputText`, so the buffers live on the
/// Sprite struct itself rather than as caller-owned scratch.
pub const sprite_name_cap = 128;
pub const sprite_pivot_cap = 32;
pub const sprite_layer_cap = 32;

/// Typed model of the `Sprite` component (issue #31, slice 1).
/// Parsed verbatim into the edit buffers when a scene/prefab loads;
/// re-emitted from the buffers on save. Sub-fields beyond these
/// four (sprite_name / pivot / layer / z_index) are not preserved
/// yet — slice 2's merge work picks that up. Most real Sprite
/// blocks use only the four below, so the immediate data loss
/// risk is small.
pub const Sprite = struct {
    sprite_name: [sprite_name_cap:0]u8 = [_:0]u8{0} ** sprite_name_cap,
    pivot: [sprite_pivot_cap:0]u8 = [_:0]u8{0} ** sprite_pivot_cap,
    layer: [sprite_layer_cap:0]u8 = [_:0]u8{0} ** sprite_layer_cap,
    z_index: i32 = 0,
    has_z_index: bool = false,
};

/// Typed model of the `Rectangle` geometry component (issue #6).
/// Shape on disk:
/// `{ "width": N, "height": N, "color": { "r": .., "g": .., "b": .., "a": .. }, "filled": bool }`
/// Color matches labelle-gfx's u8 RGBA convention so values flow
/// straight through to the engine's renderer.
pub const Rectangle = struct {
    width: f32 = 0,
    height: f32 = 0,
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
    filled: bool = true,
};

/// Typed model of the `Circle` geometry component (issue #6, slice 2).
/// Shape on disk:
/// `{ "radius": N, "color": { "r": .., "g": .., "b": .., "a": .. }, "filled": bool }`
/// Color matches labelle-gfx's u8 RGBA convention so values flow
/// straight through to the engine's renderer.
pub const Circle = struct {
    radius: f32 = 0,
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
    filled: bool = true,
};

/// Hard cap on how many points a single `Polygon` component can hold.
/// We use a fixed-capacity inline array instead of an arena-grown slice
/// so the inspector can add/remove points without re-allocating in the
/// LoadedScene/LoadedPrefab arena. 64 is well above what any hand-
/// authored geometry needs (real-world platformer collision polys top
/// out around a dozen vertices); if a future use case wants more, bump
/// the cap or migrate to an arena-realloc strategy.
pub const polygon_max_points: u32 = 64;

/// Typed model of the `Polygon` geometry component (issue #6, slice 3).
/// Shape on disk:
/// `{ "points": [ { "x": N, "y": N }, ... ], "color": { "r": .., "g": .., "b": .., "a": .. }, "filled": bool }`
///
/// Points are world-space offsets from the entity's `Position`. Color
/// matches labelle-gfx's u8 RGBA convention so values flow straight
/// through to the engine's renderer.
///
/// Storage: fixed-capacity inline buffer (`polygon_max_points`) with a
/// `point_count` cursor. The inspector can add/remove points in place
/// without touching the arena — same lifecycle story as `Sprite`'s
/// inline char buffers. `points[0..point_count]` is the live slice;
/// entries beyond `point_count` are undefined and must not be read.
pub const Polygon = struct {
    points: [polygon_max_points]Position = [_]Position{.{}} ** polygon_max_points,
    point_count: u32 = 0,
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
    filled: bool = true,

    pub fn livePoints(self: *const Polygon) []const Position {
        return self.points[0..self.point_count];
    }
};

pub const Entity = struct {
    prefab: ?[]const u8 = null,
    /// Parsed once on load; viewport reads it when drawing the entity
    /// marker. Components that aren't known to this struct are ignored,
    /// which lets the gui open scenes that reference component types
    /// we don't model yet (Shape, user-defined components).
    position: ?Position = null,
    /// Typed `Sprite` component when the source had one. Null
    /// otherwise. Heap-allocated in the LoadedScene/LoadedPrefab
    /// arena so the inspector can edit the buffers in place.
    sprite: ?*Sprite = null,
    /// Typed `Rectangle` geometry component (issue #6). Same
    /// arena-ownership story as `sprite`.
    rectangle: ?*Rectangle = null,
    /// Typed `Circle` geometry component (issue #6). Same
    /// arena-ownership story as `sprite`.
    circle: ?*Circle = null,
    /// Typed `Polygon` geometry component (issue #6, slice 3). Same
    /// arena-ownership story as `sprite`: the struct itself lives in
    /// the arena, but its fixed-cap point buffer lives inline so
    /// adding / removing points doesn't need a realloc.
    polygon: ?*Polygon = null,
    /// Leading `//` comments captured from the source file, attached
    /// to the first entity that follows them — same rule we use for
    /// project.labelle pass-through. Lines keep their `//` markers and
    /// are joined by `\n`. The buffer is mutable so the inspector can
    /// edit it directly; size-bounded to avoid heap churn.
    comment: [comment_cap:0]u8 = [_:0]u8{0} ** comment_cap,
};

pub const Scene = struct {
    name: []const u8 = "",
    /// Mutable so the Scene module can edit positions in place. Memory
    /// is arena-owned (see `LoadedScene`); modifying entries here is
    /// safe as long as the LoadedScene is alive.
    entities: []Entity = &.{},
};

/// A top-level JSON key+value the gui doesn't model (e.g. `include`,
/// any user-defined scene-level keys). The value text is verbatim
/// source between `:` and the next sibling `,` or `}`.
pub const TopLevelExtra = struct {
    name: []const u8,
    value_text: []const u8,
};

/// A `components`-object entry the gui doesn't model (everything other
/// than `Position`). Captured per-entity at load time and re-emitted
/// verbatim on save so Sprite / Shape / user components survive
/// round-trips through an edit.
pub const ComponentExtra = struct {
    name: []const u8,
    value_text: []const u8,
};

pub const SceneExtras = struct {
    /// Captured verbatim text for top-level scene keys we don't model.
    top_level: []const TopLevelExtra = &.{},
    /// Per-entity components we don't model. Indexed by source order.
    /// Inner slice may be empty when an entity has only modeled
    /// components (or no components block at all).
    entity_components: []const []const ComponentExtra = &.{},
};

/// Loaded scene plus the arena that owns its memory. Caller frees via
/// `LoadedScene.deinit()`.
pub const LoadedScene = struct {
    arena: *std.heap.ArenaAllocator,
    scene: Scene,
    extras: SceneExtras = .{},

    pub fn deinit(self: *LoadedScene) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !LoadedScene {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(raw);
    return parseScene(allocator, raw);
}

// ─── Prefabs ───────────────────────────────────────────────────────────
//
// Prefabs live at `<project>/prefabs/<name>.jsonc` with the shape
// `{ "components": { ... } }` — a single entity template, no `name`
// field, no `entities` array. Conceptually they're "one entity worth
// of components" that scenes instance by reference. Our model: load
// the prefab as a `LoadedPrefab` carrying one `Entity` plus the same
// `ComponentExtra` list we use for scene entities. Position is
// typically absent in prefabs (scenes set position per-instance).

pub const LoadedPrefab = struct {
    arena: *std.heap.ArenaAllocator,
    /// The prefab's body, modeled as a single entity so the inspector
    /// can render it with the same code that handles scene entities.
    /// `entity.prefab` is unused (prefabs don't reference other
    /// prefabs in this format); `entity.position` is usually null.
    entity: Entity,
    /// Components other than `Position` captured verbatim, same as
    /// scene-side extras. On save, these splice back into the
    /// emitted `components: { ... }` block.
    component_extras: []const ComponentExtra,
    /// Optional `children: [...]` array — a prefab can hold sub-
    /// entities with their own positions and components (e.g.
    /// hydroponics has Sprite children that decorate the room).
    /// Mutable in place so the editor can drag-to-move them.
    children: []Entity,
    /// Per-child unmodeled components, parallel to `children`.
    children_extras: []const []const ComponentExtra,
    /// Top-level keys other than `components` / `children` that the
    /// gui doesn't model (custom prefab metadata, future schema
    /// extensions). Captured verbatim at load and re-emitted on save
    /// so editing a prefab never silently drops fields the gui
    /// doesn't know about — same contract scenes use.
    top_level_extras: []const TopLevelExtra = &.{},

    pub fn deinit(self: *LoadedPrefab) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub fn loadPrefabFromFile(allocator: std.mem.Allocator, path: []const u8) !LoadedPrefab {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(raw);
    return parsePrefab(allocator, raw);
}

pub fn parsePrefab(allocator: std.mem.Allocator, raw: []const u8) !LoadedPrefab {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const stripped = try stripLineComments(arena.allocator(), raw);

    const Intermediate = struct {
        components: ?std.json.Value = null,
        children: []const struct {
            prefab: ?[]const u8 = null,
            components: ?std.json.Value = null,
        } = &.{},
    };
    var parsed = try std.json.parseFromSlice(Intermediate, arena.allocator(), stripped, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const entity: Entity = .{
        .position = readPosition(parsed.value.components),
        .sprite = try readSprite(arena.allocator(), parsed.value.components),
        .rectangle = try readRectangle(arena.allocator(), parsed.value.components),
        .circle = try readCircle(arena.allocator(), parsed.value.components),
        .polygon = try readPolygon(arena.allocator(), parsed.value.components),
    };

    // Re-use the entity-body scanner — walks `{ ... }`, finds the
    // `components` key, captures every non-managed entry as verbatim
    // extras. Works the same for prefab body and child bodies.
    const component_extras = try extractComponentExtras(arena.allocator(), raw);

    // Children: mutable so the editor can drag-to-move them. Each
    // child gets its leading `//` comment block attached via the
    // same rule scenes use.
    const child_comments = try extractChildComments(arena.allocator(), raw);
    const child_extras = try extractChildComponentExtras(arena.allocator(), raw);
    var children = try arena.allocator().alloc(Entity, parsed.value.children.len);
    for (parsed.value.children, 0..) |c, i| {
        children[i] = .{
            .prefab = if (c.prefab) |p| try arena.allocator().dupe(u8, p) else null,
            .position = readPosition(c.components),
            .sprite = try readSprite(arena.allocator(), c.components),
            .rectangle = try readRectangle(arena.allocator(), c.components),
            .circle = try readCircle(arena.allocator(), c.components),
            .polygon = try readPolygon(arena.allocator(), c.components),
        };
        if (i < child_comments.len) {
            buf.writeZeroed(&children[i].comment, child_comments[i]);
        }
    }

    // Capture every other top-level key verbatim so the writer can
    // splice them back in unchanged. Closes the data-loss gap where
    // editing+saving a prefab would silently drop schema fields the
    // gui doesn't model.
    const top_level_extras = try extractPrefabTopLevelExtras(arena.allocator(), raw);

    return .{
        .arena = arena,
        .entity = entity,
        .component_extras = component_extras,
        .children = children,
        .children_extras = child_extras,
        .top_level_extras = top_level_extras,
    };
}

pub fn savePrefab(allocator: std.mem.Allocator, path: []const u8, loaded: LoadedPrefab) !void {
    const text = try renderPrefabJsonc(allocator, loaded);
    defer allocator.free(text);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);
}

/// Emit the prefab as `{ "components": { ... }, "children": [ ... ] }`.
/// The `components` block mirrors a scene entity's; the `children`
/// array (omitted when empty) emits one entry per child with its
/// modeled Position + verbatim component extras + leading comment.
pub fn renderPrefabJsonc(allocator: std.mem.Allocator, loaded: LoadedPrefab) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("{\n");
    try w.writeAll("    \"components\": {");
    var first = true;
    if (loaded.entity.position) |p| {
        try w.print(" \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
        first = false;
    }
    if (loaded.entity.sprite) |sp| {
        if (!first) try w.writeAll(",");
        _ = try emitSprite(&w, sp.*);
        first = false;
    }
    if (loaded.entity.rectangle) |re| {
        if (!first) try w.writeAll(",");
        _ = try emitRectangle(&w, re.*);
        first = false;
    }
    if (loaded.entity.circle) |ci| {
        if (!first) try w.writeAll(",");
        _ = try emitCircle(&w, ci.*);
        first = false;
    }
    if (loaded.entity.polygon) |po| {
        if (!first) try w.writeAll(",");
        _ = try emitPolygon(&w, po.*);
        first = false;
    }
    for (loaded.component_extras) |extra| {
        if (!first) try w.writeAll(",");
        try w.print(" \"{s}\": {s}", .{ extra.name, extra.value_text });
        first = false;
    }
    if (first) try w.writeAll(" ");
    try w.writeAll(" }");

    if (loaded.children.len > 0) {
        try w.writeAll(",\n");
        try w.writeAll("    \"children\": [\n");
        for (loaded.children, 0..) |child, i| {
            const comment = std.mem.sliceTo(&child.comment, 0);
            if (comment.len > 0) {
                var lines = std.mem.splitScalar(u8, std.mem.trim(u8, comment, " \t\r\n"), '\n');
                while (lines.next()) |line| {
                    try w.print("        {s}\n", .{std.mem.trim(u8, line, " \t\r")});
                }
            }

            try w.writeAll("        {");
            var c_first = true;
            if (child.prefab) |p| {
                try w.print(" \"prefab\": \"{s}\"", .{p});
                c_first = false;
            }
            const cextras = if (i < loaded.children_extras.len)
                loaded.children_extras[i]
            else
                &[_]ComponentExtra{};
            const has_components = child.position != null or
                child.sprite != null or
                child.rectangle != null or
                child.circle != null or
                child.polygon != null or
                cextras.len > 0;
            if (has_components) {
                if (!c_first) try w.writeAll(",");
                try w.writeAll(" \"components\": {");
                var cc_first = true;
                if (child.position) |p| {
                    try w.print(" \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
                    cc_first = false;
                }
                if (child.sprite) |sp| {
                    if (!cc_first) try w.writeAll(",");
                    _ = try emitSprite(&w, sp.*);
                    cc_first = false;
                }
                if (child.rectangle) |re| {
                    if (!cc_first) try w.writeAll(",");
                    _ = try emitRectangle(&w, re.*);
                    cc_first = false;
                }
                if (child.circle) |ci| {
                    if (!cc_first) try w.writeAll(",");
                    _ = try emitCircle(&w, ci.*);
                    cc_first = false;
                }
                if (child.polygon) |po| {
                    if (!cc_first) try w.writeAll(",");
                    _ = try emitPolygon(&w, po.*);
                    cc_first = false;
                }
                for (cextras) |extra| {
                    if (!cc_first) try w.writeAll(",");
                    try w.print(" \"{s}\": {s}", .{ extra.name, extra.value_text });
                    cc_first = false;
                }
                try w.writeAll(" }");
                c_first = false;
            }
            if (c_first) try w.writeAll(" ");
            try w.writeAll(" }");
            if (i + 1 < loaded.children.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("    ]");
    }

    // Splice unmodeled top-level keys back in, after the modeled
    // fields. Order shifts relative to the source (managed first)
    // but the content is faithful — same trade-off scenes make.
    for (loaded.top_level_extras) |kv| {
        try w.writeAll(",\n");
        try w.print("    \"{s}\": {s}", .{ kv.name, kv.value_text });
    }

    try w.writeAll("\n}\n");
    return out.toOwnedSlice(allocator);
}

pub fn parseScene(allocator: std.mem.Allocator, raw: []const u8) !LoadedScene {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const stripped = try stripLineComments(arena.allocator(), raw);
    // The intermediate JSON deserialization needs both fields & ignore-unknowns
    // because real scenes carry component keys (Sprite, Shape, …) we don't model.
    const Intermediate = struct {
        name: []const u8 = "",
        entities: []const struct {
            prefab: ?[]const u8 = null,
            components: ?std.json.Value = null,
        } = &.{},
    };

    var parsed = try std.json.parseFromSlice(Intermediate, arena.allocator(), stripped, .{
        .ignore_unknown_fields = true,
    });
    // `parsed.deinit` is functionally a no-op here because the inner
    // arena std.json creates is backed by our outer arena (which is
    // freed wholesale on `LoadedScene.deinit`). Calling it anyway keeps
    // the ownership story consistent with other call sites.
    defer parsed.deinit();

    // Walk the source a second time to pluck out each entity's leading
    // comments. Done as a separate pass over the *raw* (pre-stripped)
    // text — the stripped buffer has spaces where `//` lines used to be,
    // so we can't recover comments from it.
    const comments = try extractEntityComments(arena.allocator(), raw);

    var entities = try arena.allocator().alloc(Entity, parsed.value.entities.len);
    for (parsed.value.entities, 0..) |e, i| {
        entities[i] = .{
            .prefab = if (e.prefab) |p| try arena.allocator().dupe(u8, p) else null,
            .position = readPosition(e.components),
            .sprite = try readSprite(arena.allocator(), e.components),
            .rectangle = try readRectangle(arena.allocator(), e.components),
            .circle = try readCircle(arena.allocator(), e.components),
            .polygon = try readPolygon(arena.allocator(), e.components),
        };
        // Comments are extracted on a best-effort basis: if the scanner
        // landed fewer entries than parser saw entities (recovery from
        // a malformed scene mid-stream), the remaining entries simply
        // get empty comment buffers.
        if (i < comments.len) buf.writeZeroed(&entities[i].comment, comments[i]);
    }

    // Pass-through captures: top-level keys we don't model (e.g.
    // `include`) and per-entity components other than `Position`. Both
    // get re-emitted verbatim on save so external scenes round-trip
    // without losing data the gui doesn't yet know how to edit.
    const top_level_extras = try extractTopLevelExtras(arena.allocator(), raw);
    const entity_components_extras = try extractEntityComponentExtras(arena.allocator(), raw);

    return .{
        .arena = arena,
        .scene = .{
            .name = try arena.allocator().dupe(u8, parsed.value.name),
            .entities = entities,
        },
        .extras = .{
            .top_level = top_level_extras,
            .entity_components = entity_components_extras,
        },
    };
}

fn readPosition(components: ?std.json.Value) ?Position {
    const c = components orelse return null;
    if (c != .object) return null;
    const pos = c.object.get("Position") orelse return null;
    if (pos != .object) return null;
    return .{
        .x = jsonNumberAsF32(pos.object.get("x")) orelse 0,
        .y = jsonNumberAsF32(pos.object.get("y")) orelse 0,
    };
}

fn readSprite(arena: std.mem.Allocator, components: ?std.json.Value) !?*Sprite {
    const c = components orelse return null;
    if (c != .object) return null;
    const s_val = c.object.get("Sprite") orelse return null;
    if (s_val != .object) return null;

    const out = try arena.create(Sprite);
    out.* = .{};
    if (s_val.object.get("sprite_name")) |v| if (v == .string) buf.writeZeroed(&out.sprite_name, v.string);
    if (s_val.object.get("pivot")) |v| if (v == .string) buf.writeZeroed(&out.pivot, v.string);
    if (s_val.object.get("layer")) |v| if (v == .string) buf.writeZeroed(&out.layer, v.string);
    if (s_val.object.get("z_index")) |v| switch (v) {
        .integer => |i| {
            out.z_index = @intCast(i);
            out.has_z_index = true;
        },
        else => {},
    };
    return out;
}

fn jsonNumberAsF32(v: ?std.json.Value) ?f32 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

fn jsonNumberAsU8(v: ?std.json.Value) ?u8 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| if (i >= 0 and i <= 255) @intCast(i) else null,
        .float => |f| if (f >= 0 and f <= 255) @intFromFloat(f) else null,
        else => null,
    };
}

fn readRectangle(arena: std.mem.Allocator, components: ?std.json.Value) !?*Rectangle {
    const c = components orelse return null;
    if (c != .object) return null;
    const r_val = c.object.get("Rectangle") orelse return null;
    if (r_val != .object) return null;

    const out = try arena.create(Rectangle);
    out.* = .{};
    if (jsonNumberAsF32(r_val.object.get("width"))) |w| out.width = w;
    if (jsonNumberAsF32(r_val.object.get("height"))) |h| out.height = h;
    if (r_val.object.get("color")) |col| if (col == .object) {
        if (jsonNumberAsU8(col.object.get("r"))) |x| out.r = x;
        if (jsonNumberAsU8(col.object.get("g"))) |x| out.g = x;
        if (jsonNumberAsU8(col.object.get("b"))) |x| out.b = x;
        if (jsonNumberAsU8(col.object.get("a"))) |x| out.a = x;
    };
    if (r_val.object.get("filled")) |v| if (v == .bool) {
        out.filled = v.bool;
    };
    return out;
}

fn readCircle(arena: std.mem.Allocator, components: ?std.json.Value) !?*Circle {
    const c = components orelse return null;
    if (c != .object) return null;
    const c_val = c.object.get("Circle") orelse return null;
    if (c_val != .object) return null;

    const out = try arena.create(Circle);
    out.* = .{};
    if (jsonNumberAsF32(c_val.object.get("radius"))) |rv| out.radius = rv;
    if (c_val.object.get("color")) |col| if (col == .object) {
        if (jsonNumberAsU8(col.object.get("r"))) |x| out.r = x;
        if (jsonNumberAsU8(col.object.get("g"))) |x| out.g = x;
        if (jsonNumberAsU8(col.object.get("b"))) |x| out.b = x;
        if (jsonNumberAsU8(col.object.get("a"))) |x| out.a = x;
    };
    if (c_val.object.get("filled")) |v| if (v == .bool) {
        out.filled = v.bool;
    };
    return out;
}

/// Read a `Polygon` component out of the parsed `components` object,
/// allocating into `arena`. Returns null when the entity has no
/// `Polygon` key. Points beyond `polygon_max_points` are dropped with
/// no warning — the cap is documented on `Polygon` itself; in practice
/// no hand-authored geometry hits it.
fn readPolygon(arena: std.mem.Allocator, components: ?std.json.Value) !?*Polygon {
    const c = components orelse return null;
    if (c != .object) return null;
    const p_val = c.object.get("Polygon") orelse return null;
    if (p_val != .object) return null;

    const out = try arena.create(Polygon);
    out.* = .{};
    if (p_val.object.get("points")) |pts| if (pts == .array) {
        var n: u32 = 0;
        for (pts.array.items) |item| {
            if (n >= polygon_max_points) break;
            if (item != .object) continue;
            const x = jsonNumberAsF32(item.object.get("x")) orelse 0;
            const y = jsonNumberAsF32(item.object.get("y")) orelse 0;
            out.points[n] = .{ .x = x, .y = y };
            n += 1;
        }
        out.point_count = n;
    };
    if (p_val.object.get("color")) |col| if (col == .object) {
        if (jsonNumberAsU8(col.object.get("r"))) |x| out.r = x;
        if (jsonNumberAsU8(col.object.get("g"))) |x| out.g = x;
        if (jsonNumberAsU8(col.object.get("b"))) |x| out.b = x;
        if (jsonNumberAsU8(col.object.get("a"))) |x| out.a = x;
    };
    if (p_val.object.get("filled")) |v| if (v == .bool) {
        out.filled = v.bool;
    };
    return out;
}

/// Emit `s` as a JSON-escaped string literal (`"..."`) into `writer`.
/// Handles the escapes the JSON spec requires for byte values < 0x20
/// plus the two embeddable bytes (`"` and `\`); leaves the rest of
/// the UTF-8 stream untouched. Sufficient for the inspector-driven
/// short identifier fields on `Sprite` — the assembler's parser is
/// a standard JSON reader, so anything we escape per the spec
/// round-trips faithfully.
fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

/// Emit `"Sprite": { ... }` into `writer` from the typed sprite
/// fields. Used by both the scene and prefab writers as part of
/// the per-entity `components` block. Returns `true` if anything
/// was written so the caller can manage commas between sibling
/// components — an entirely-empty Sprite still emits `"Sprite": {}`
/// because we know the entity *has* a Sprite component, just no
/// non-default fields.
fn emitSprite(writer: anytype, sprite: Sprite) !bool {
    const name = std.mem.sliceTo(&sprite.sprite_name, 0);
    const pivot = std.mem.sliceTo(&sprite.pivot, 0);
    const layer = std.mem.sliceTo(&sprite.layer, 0);

    try writer.writeAll(" \"Sprite\": {");
    var first = true;
    // sprite_name / pivot / layer come straight from inspector text
    // buffers, so they can in principle hold a `"` or `\`. Escape
    // them so the rendered file stays valid JSONC even with hostile
    // input.
    if (name.len > 0) {
        try writer.writeAll(" \"sprite_name\": ");
        try writeJsonString(writer, name);
        first = false;
    }
    if (pivot.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" \"pivot\": ");
        try writeJsonString(writer, pivot);
        first = false;
    }
    if (layer.len > 0) {
        if (!first) try writer.writeAll(",");
        try writer.writeAll(" \"layer\": ");
        try writeJsonString(writer, layer);
        first = false;
    }
    if (sprite.has_z_index) {
        if (!first) try writer.writeAll(",");
        try writer.print(" \"z_index\": {d}", .{sprite.z_index});
        first = false;
    }
    if (first) try writer.writeAll(" ");
    try writer.writeAll(" }");
    return true;
}

/// Emit `"Rectangle": { ... }` into `writer` from the typed
/// geometry fields. Same comma-management contract as `emitSprite`.
/// The struct's defaults match the engine's defaults — width 0,
/// height 0, white opaque, filled — so we still emit all fields
/// every time. That keeps the file self-describing and lets the
/// inspector show what was actually saved without inferring.
fn emitRectangle(writer: anytype, rect: Rectangle) !bool {
    try writer.writeAll(" \"Rectangle\": {");
    try writer.print(" \"width\": {d}, \"height\": {d},", .{ rect.width, rect.height });
    try writer.print(" \"color\": {{ \"r\": {d}, \"g\": {d}, \"b\": {d}, \"a\": {d} }},", .{
        rect.r, rect.g, rect.b, rect.a,
    });
    try writer.print(" \"filled\": {s}", .{if (rect.filled) "true" else "false"});
    try writer.writeAll(" }");
    return true;
}

/// Emit `"Circle": { ... }` into `writer` from the typed geometry
/// fields. Same comma-management contract as `emitSprite`. All
/// fields are always emitted so the file is self-describing and
/// the inspector shows what was actually saved without inferring.
fn emitCircle(writer: anytype, circle: Circle) !bool {
    try writer.writeAll(" \"Circle\": {");
    try writer.print(" \"radius\": {d},", .{circle.radius});
    try writer.print(" \"color\": {{ \"r\": {d}, \"g\": {d}, \"b\": {d}, \"a\": {d} }},", .{
        circle.r, circle.g, circle.b, circle.a,
    });
    try writer.print(" \"filled\": {s}", .{if (circle.filled) "true" else "false"});
    try writer.writeAll(" }");
    return true;
}

/// Emit `"Polygon": { ... }` into `writer` from the typed polygon
/// fields. Same comma-management contract as `emitSprite`. We always
/// emit `points`, `color`, and `filled` so the file is self-describing
/// — an empty point list still renders `"points": []`, which makes
/// the disk shape obvious and lets the inspector show what was saved
/// without inferring defaults.
fn emitPolygon(writer: anytype, poly: Polygon) !bool {
    try writer.writeAll(" \"Polygon\": {");
    try writer.writeAll(" \"points\": [");
    var first_pt = true;
    var i: u32 = 0;
    while (i < poly.point_count) : (i += 1) {
        if (!first_pt) try writer.writeAll(",");
        try writer.print(" {{ \"x\": {d}, \"y\": {d} }}", .{ poly.points[i].x, poly.points[i].y });
        first_pt = false;
    }
    if (poly.point_count == 0) try writer.writeAll(" ");
    try writer.writeAll(" ],");
    try writer.print(" \"color\": {{ \"r\": {d}, \"g\": {d}, \"b\": {d}, \"a\": {d} }},", .{
        poly.r, poly.g, poly.b, poly.a,
    });
    try writer.print(" \"filled\": {s}", .{if (poly.filled) "true" else "false"});
    try writer.writeAll(" }");
    return true;
}

/// Strip a trailing `.jsonc` extension from a path's basename and
/// return the resulting stem (e.g. `"a/b/main.jsonc"` → `"main"`).
/// Used by Scene + Prefab tabs for the display label; lifted here
/// so they share the implementation rather than duplicating it.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".jsonc";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

/// Walk the JSONC source and capture `// ...` comment blocks that
/// precede each top-level entity in `entities: [ ... ]`. Returns one
/// string per entity in source order; entries are empty when an entity
/// had no leading comments. Lines keep their `//` marker.
///
/// Scope: JSONC subset we actually see — strings with `\"` escape,
/// `//` to EOL comments. Doesn't handle `/* ... */` (the toolkit
/// schema doesn't use them) or trailing comments on the same line as
/// an entity opening brace (uncommon and would conflate with the
/// previous entity).
pub fn extractEntityComments(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    return extractArrayItemComments(arena, raw, findEntitiesArray(raw) orelse return &.{});
}

/// Same shape as `extractEntityComments` but rooted at a prefab's
/// `children` array. Returns one comment block per child in source
/// order; entries are empty when a child had no leading comment.
pub fn extractChildComments(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    return extractArrayItemComments(arena, raw, findChildrenArray(raw) orelse return &.{});
}

fn extractArrayItemComments(
    arena: std.mem.Allocator,
    raw: []const u8,
    array_lbracket: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .{};
    errdefer out.deinit(arena);

    var i: usize = array_lbracket + 1; // past '['

    while (i < raw.len) {
        skipWhitespaceJson(raw, &i);
        const comment_start = i;
        skipCommentBlock(raw, &i);
        const comment_end = i;
        skipWhitespaceJson(raw, &i);

        if (i >= raw.len) break;
        if (raw[i] == ']') break;
        if (raw[i] == ',') {
            i += 1;
            continue;
        }
        if (raw[i] != '{') break;

        const trimmed = std.mem.trim(u8, raw[comment_start..comment_end], " \t\r\n");
        try out.append(arena, try arena.dupe(u8, trimmed));

        scanBalanced(raw, &i, '{', '}');
    }
    return out.toOwnedSlice(arena);
}

/// Locate a `"<key>": [` array in `raw` and return the byte offset
/// of the opening `[`. Used for both scene entities and prefab
/// children — same scanner, different key. False-positive guard:
/// a literal string value equal to the key (e.g. `"tag":
/// "entities"`) is skipped past so a real later occurrence still
/// resolves.
fn findArrayByKey(raw: []const u8, key_with_quotes: []const u8) ?usize {
    const klen = key_with_quotes.len;
    var i: usize = 0;
    while (i + klen <= raw.len) {
        if (std.mem.eql(u8, raw[i .. i + klen], key_with_quotes)) {
            var probe = i + klen;
            skipWhitespaceJson(raw, &probe);
            skipCommentBlock(raw, &probe);
            skipWhitespaceJson(raw, &probe);
            if (probe < raw.len and raw[probe] == ':') {
                probe += 1;
                skipWhitespaceJson(raw, &probe);
                skipCommentBlock(raw, &probe);
                skipWhitespaceJson(raw, &probe);
                if (probe < raw.len and raw[probe] == '[') return probe;
            }
            i += klen;
            continue;
        }
        if (raw[i] == '"') {
            skipString(raw, &i);
            continue;
        }
        i += 1;
    }
    return null;
}

fn findEntitiesArray(raw: []const u8) ?usize {
    return findArrayByKey(raw, "\"entities\"");
}

fn findChildrenArray(raw: []const u8) ?usize {
    return findArrayByKey(raw, "\"children\"");
}

fn skipWhitespaceJson(raw: []const u8, i: *usize) void {
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        i.* += 1;
    }
}

fn skipCommentBlock(raw: []const u8, i: *usize) void {
    while (i.* + 1 < raw.len and raw[i.*] == '/' and raw[i.* + 1] == '/') {
        while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        if (i.* < raw.len) i.* += 1; // consume newline so consecutive lines flow
        skipWhitespaceJson(raw, i);
    }
}

fn skipString(raw: []const u8, i: *usize) void {
    // Assumes raw[i.*] == '"'.
    i.* += 1;
    while (i.* < raw.len) {
        if (raw[i.*] == '\\' and i.* + 1 < raw.len) {
            i.* += 2;
        } else if (raw[i.*] == '"') {
            i.* += 1;
            return;
        } else {
            i.* += 1;
        }
    }
}

fn scanBalanced(raw: []const u8, i: *usize, open: u8, close: u8) void {
    // Assumes raw[i.*] == open.
    var depth: i32 = 0;
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == open) {
            depth += 1;
            i.* += 1;
        } else if (c == close) {
            depth -= 1;
            i.* += 1;
            if (depth == 0) return;
        } else if (c == '"') {
            skipString(raw, i);
        } else if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        } else {
            i.* += 1;
        }
    }
}


/// Return a fresh allocator-owned copy of `src` with each `//`-to-EOL
/// comment replaced by spaces. Preserves byte offsets so any later
/// parser diagnostics still align with column numbers in the source.
///
/// String-aware: a `//` sequence that appears inside a `"..."` string
/// literal is left intact (think `"https://example.com"`). Escape
/// sequences within strings (`\"`, `\\`) are honored so a backslash
/// followed by a quote doesn't prematurely close the string.
pub fn stripLineComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, src);
    var i: usize = 0;
    var in_string = false;
    var escaped = false;
    while (i < out.len) {
        const c = out[i];
        if (escaped) {
            escaped = false;
            i += 1;
            continue;
        }
        if (in_string) {
            if (c == '\\') {
                escaped = true;
            } else if (c == '"') {
                in_string = false;
            }
            i += 1;
            continue;
        }
        if (c == '"') {
            in_string = true;
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            var j = i;
            while (j < out.len and out[j] != '\n') : (j += 1) out[j] = ' ';
            i = j;
            continue;
        }
        i += 1;
    }
    return out;
}

// ─── Pass-through extras: capture + writer ─────────────────────────────

/// Scan the top-level JSON object and capture every `"key": value` pair
/// whose key the caller's `isManaged` predicate doesn't claim. Value
/// text spans from the first non-whitespace byte after `:` through to
/// just before the trailing `,` or `}`. Scenes and prefabs share this
/// scanner — they differ only in which keys count as managed.
fn extractTopLevelExtrasFiltered(
    arena: std.mem.Allocator,
    raw: []const u8,
    isManaged: *const fn ([]const u8) bool,
) ![]const TopLevelExtra {
    var out: std.ArrayList(TopLevelExtra) = .{};
    errdefer out.deinit(arena);

    var i: usize = 0;
    skipWhitespaceJson(raw, &i);
    skipCommentBlock(raw, &i);
    skipWhitespaceJson(raw, &i);
    if (i >= raw.len or raw[i] != '{') return out.toOwnedSlice(arena);
    i += 1;

    while (i < raw.len) {
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);
        if (i >= raw.len) break;
        if (raw[i] == '}') break;
        if (raw[i] == ',') {
            i += 1;
            continue;
        }
        if (raw[i] != '"') break;

        // Capture key.
        const key = parseStringLiteral(raw, &i) orelse break;

        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);
        if (i >= raw.len or raw[i] != ':') break;
        i += 1;
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);

        const value_start = i;
        scanValueJson(raw, &i);
        const value_end = i;

        if (!isManaged(key)) {
            try out.append(arena, .{
                .name = try arena.dupe(u8, key),
                .value_text = try arena.dupe(u8, std.mem.trim(u8, raw[value_start..value_end], " \t\r\n")),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

fn extractTopLevelExtras(arena: std.mem.Allocator, raw: []const u8) ![]const TopLevelExtra {
    return extractTopLevelExtrasFiltered(arena, raw, isManagedTopLevelKey);
}

fn extractPrefabTopLevelExtras(arena: std.mem.Allocator, raw: []const u8) ![]const TopLevelExtra {
    return extractTopLevelExtrasFiltered(arena, raw, isManagedPrefabTopLevelKey);
}

/// Per-entity: scan each `{ ... }` in the entities array. Inside,
/// locate the `"components"` block, then capture every component
/// key+value pair that isn't `Position` (the only component the gui
/// models today).
fn extractEntityComponentExtras(arena: std.mem.Allocator, raw: []const u8) ![]const []const ComponentExtra {
    return extractArrayItemComponentExtras(arena, raw, findEntitiesArray(raw) orelse return &.{});
}

/// Per-child component extras for prefabs. Same scanner the scene
/// side uses, just rooted at the `children` array instead of
/// `entities`.
pub fn extractChildComponentExtras(arena: std.mem.Allocator, raw: []const u8) ![]const []const ComponentExtra {
    return extractArrayItemComponentExtras(arena, raw, findChildrenArray(raw) orelse return &.{});
}

/// Shared body for entity / child component extraction. Caller passes
/// the byte offset of the opening `[` of the array to walk.
fn extractArrayItemComponentExtras(
    arena: std.mem.Allocator,
    raw: []const u8,
    array_lbracket: usize,
) ![]const []const ComponentExtra {
    var out: std.ArrayList([]const ComponentExtra) = .{};
    errdefer out.deinit(arena);

    var i: usize = array_lbracket + 1; // past '['

    while (i < raw.len) {
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);
        if (i >= raw.len) break;
        if (raw[i] == ']') break;
        if (raw[i] == ',') {
            i += 1;
            continue;
        }
        if (raw[i] != '{') break;

        const entity_start = i;
        scanBalanced(raw, &i, '{', '}');
        const entity_end = i;
        const entity_body = raw[entity_start..entity_end];

        try out.append(arena, try extractComponentExtras(arena, entity_body));
    }
    return out.toOwnedSlice(arena);
}

fn extractComponentExtras(arena: std.mem.Allocator, entity_body: []const u8) ![]const ComponentExtra {
    var out: std.ArrayList(ComponentExtra) = .{};
    errdefer out.deinit(arena);

    // Find `"components"` key inside the entity body.
    const components_obj_start = findKeyObject(entity_body, "components") orelse return out.toOwnedSlice(arena);
    var i: usize = components_obj_start + 1; // past '{'

    while (i < entity_body.len) {
        skipWhitespaceJson(entity_body, &i);
        skipCommentBlock(entity_body, &i);
        skipWhitespaceJson(entity_body, &i);
        if (i >= entity_body.len) break;
        if (entity_body[i] == '}') break;
        if (entity_body[i] == ',') {
            i += 1;
            continue;
        }
        if (entity_body[i] != '"') break;

        const key = parseStringLiteral(entity_body, &i) orelse break;

        skipWhitespaceJson(entity_body, &i);
        if (i >= entity_body.len or entity_body[i] != ':') break;
        i += 1;
        skipWhitespaceJson(entity_body, &i);

        const value_start = i;
        scanValueJson(entity_body, &i);
        const value_end = i;

        // Skip components the gui models structurally; their fields
        // are re-emitted by the writer from the typed Entity, so
        // capturing them as extras would round-trip them twice.
        const is_managed = std.mem.eql(u8, key, "Position") or
            std.mem.eql(u8, key, "Sprite") or
            std.mem.eql(u8, key, "Rectangle") or
            std.mem.eql(u8, key, "Circle") or
            std.mem.eql(u8, key, "Polygon");
        if (!is_managed) {
            try out.append(arena, .{
                .name = try arena.dupe(u8, key),
                .value_text = try arena.dupe(u8, std.mem.trim(u8, entity_body[value_start..value_end], " \t\r\n")),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Find `"<key>": {` inside an object body. Returns the byte offset
/// of the opening `{`, or null when the key isn't present.
///
/// Tolerates leading whitespace / `//` comments / BOM-style padding
/// before the outer `{`. Scene-entity callers pass a body that
/// already starts at the opening brace (sliced by `scanBalanced`);
/// the prefab path passes the full raw file, which may have a
/// header comment or whitespace before `{`. Without the skip below
/// the prefab path returned null and silently produced empty
/// extras — data-destructive on save.
fn findKeyObject(body: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
    skipWhitespaceJson(body, &i);
    skipCommentBlock(body, &i);
    skipWhitespaceJson(body, &i);
    if (i < body.len and body[i] == '{') i += 1;
    while (i < body.len) {
        skipWhitespaceJson(body, &i);
        skipCommentBlock(body, &i);
        skipWhitespaceJson(body, &i);
        if (i >= body.len) return null;
        if (body[i] == '}') return null;
        if (body[i] == ',') {
            i += 1;
            continue;
        }
        if (body[i] != '"') return null;

        const cursor_before_key = i;
        const this_key = parseStringLiteral(body, &i) orelse return null;
        skipWhitespaceJson(body, &i);
        if (i >= body.len or body[i] != ':') return null;
        i += 1;
        skipWhitespaceJson(body, &i);

        if (std.mem.eql(u8, this_key, key)) {
            if (i < body.len and body[i] == '{') return i;
            return null;
        }
        _ = cursor_before_key;
        scanValueJson(body, &i);
    }
    return null;
}

/// Parse a `"..."` string literal starting at `raw[i.*]`. Advances `i`
/// past the closing quote. Returns the contents (without quotes), or
/// null when the buffer doesn't start with `"`.
fn parseStringLiteral(raw: []const u8, i: *usize) ?[]const u8 {
    if (i.* >= raw.len or raw[i.*] != '"') return null;
    const start = i.* + 1;
    i.* += 1;
    while (i.* < raw.len) {
        if (raw[i.*] == '\\' and i.* + 1 < raw.len) {
            i.* += 2;
        } else if (raw[i.*] == '"') {
            const out = raw[start..i.*];
            i.* += 1;
            return out;
        } else {
            i.* += 1;
        }
    }
    return null;
}

/// Variant of `scanValue` aimed at JSON: advances `i` until the next
/// top-level `,` or `}` (or `]`), respecting strings and `[]/{}`.
fn scanValueJson(raw: []const u8, i: *usize) void {
    var depth: i32 = 0;
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == '"') {
            _ = parseStringLiteral(raw, i);
            continue;
        }
        if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
            continue;
        }
        if (c == '{' or c == '[') {
            depth += 1;
            i.* += 1;
            continue;
        }
        if (c == '}' or c == ']') {
            if (depth == 0) return;
            depth -= 1;
            i.* += 1;
            continue;
        }
        if (c == ',' and depth == 0) return;
        i.* += 1;
    }
}

fn isManagedTopLevelKey(name: []const u8) bool {
    return std.mem.eql(u8, name, "name") or std.mem.eql(u8, name, "entities");
}

fn isManagedPrefabTopLevelKey(name: []const u8) bool {
    return std.mem.eql(u8, name, "components") or std.mem.eql(u8, name, "children");
}

// ─── Writer ────────────────────────────────────────────────────────────

/// Write the in-memory scene + extras back to disk at `path`. Truncates
/// any existing file at the path.
pub fn saveScene(allocator: std.mem.Allocator, path: []const u8, loaded: LoadedScene) !void {
    const text = try renderSceneJsonc(allocator, loaded);
    defer allocator.free(text);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);
}

/// Render the loaded scene back to JSONC. Managed fields (`name`,
/// per-entity `prefab` and `Position`) come from the typed model;
/// everything else (top-level keys other than `name`/`entities`, and
/// per-entity components other than `Position`) is spliced verbatim
/// from the extras captured at load time. Per-entity comments are
/// emitted at the entities-array indent above their owning entity.
pub fn renderSceneJsonc(allocator: std.mem.Allocator, loaded: LoadedScene) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll("{\n");
    try w.print("    \"name\": \"{s}\",\n", .{loaded.scene.name});

    for (loaded.extras.top_level) |kv| {
        try w.print("    \"{s}\": {s},\n", .{ kv.name, kv.value_text });
    }

    try w.writeAll("    \"entities\": [");
    if (loaded.scene.entities.len == 0) {
        try w.writeAll("]\n}\n");
        return out.toOwnedSlice(allocator);
    }
    try w.writeAll("\n");

    for (loaded.scene.entities, 0..) |e, i| {
        // Comment lines first (each at the entities-array indent).
        const comment = std.mem.sliceTo(&e.comment, 0);
        if (comment.len > 0) {
            var lines = std.mem.splitScalar(u8, std.mem.trim(u8, comment, " \t\r\n"), '\n');
            while (lines.next()) |line| {
                try w.print("        {s}\n", .{std.mem.trim(u8, line, " \t\r")});
            }
        }

        try w.writeAll("        {");
        var first = true;
        if (e.prefab) |p| {
            try w.print(" \"prefab\": \"{s}\"", .{p});
            first = false;
        }
        const extras = if (i < loaded.extras.entity_components.len)
            loaded.extras.entity_components[i]
        else
            &[_]ComponentExtra{};
        const has_components = e.position != null or
            e.sprite != null or
            e.rectangle != null or
            e.circle != null or
            e.polygon != null or
            extras.len > 0;
        if (has_components) {
            if (!first) try w.writeAll(",");
            try w.writeAll(" \"components\": {");
            var c_first = true;
            if (e.position) |p| {
                try w.print(" \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
                c_first = false;
            }
            if (e.sprite) |sp| {
                if (!c_first) try w.writeAll(",");
                _ = try emitSprite(&w, sp.*);
                c_first = false;
            }
            if (e.rectangle) |re| {
                if (!c_first) try w.writeAll(",");
                _ = try emitRectangle(&w, re.*);
                c_first = false;
            }
            if (e.circle) |ci| {
                if (!c_first) try w.writeAll(",");
                _ = try emitCircle(&w, ci.*);
                c_first = false;
            }
            if (e.polygon) |po| {
                if (!c_first) try w.writeAll(",");
                _ = try emitPolygon(&w, po.*);
                c_first = false;
            }
            for (extras) |extra| {
                if (!c_first) try w.writeAll(",");
                try w.print(" \"{s}\": {s}", .{ extra.name, extra.value_text });
                c_first = false;
            }
            try w.writeAll(" }");
            first = false;
        }
        if (first) try w.writeAll(" "); // empty entity body — keep braces apart
        try w.writeAll(" }");
        if (i + 1 < loaded.scene.entities.len) try w.writeAll(",");
        try w.writeAll("\n");
    }
    try w.writeAll("    ]\n}\n");

    return out.toOwnedSlice(allocator);
}
