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
const io_global = @import("io_global.zig");
const prefab_index_mod = @import("prefab_index.zig");

/// Thin adapter that lets the per-component `emit*` helpers keep their
/// existing `writer.writeAll(...) / writer.print(...) / writer.writeByte(...)`
/// shape while writing into an unmanaged `std.ArrayList(u8)` — the
/// 0.16 ArrayList API requires an allocator on each call, so we pin
/// both here and forward.
const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,

    pub fn writeAll(self: ListWriter, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.list.appendSlice(self.allocator, bytes);
    }

    pub fn writeByte(self: ListWriter, byte: u8) std.mem.Allocator.Error!void {
        try self.list.append(self.allocator, byte);
    }

    pub fn print(self: ListWriter, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        try self.list.print(self.allocator, fmt, args);
    }
};

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
    /// Optional inline child entities — populated when a scene entity
    /// (or a prefab body) has stamped sub-entities. Empty when the
    /// entity is a leaf or a bare prefab ref. Recursive in shape;
    /// the scene parser fills one level today, deeper levels stay
    /// default-empty until the stamp UI / inspector grows them. The
    /// prefab side keeps using `LoadedPrefab.children` for its
    /// top-level children (#143 Phase 2); the field here exists so
    /// scene entities can carry stamped bodies under #143 Phase 5.
    children: []Entity = &.{},
    /// Per-child unmodeled components, parallel to `children`. Empty
    /// when `children` is empty. On save the writer splices each
    /// slot back into its corresponding child's `components: { ... }`
    /// block — same contract scene-level `entity_components` extras
    /// use.
    children_extras: []const []const ComponentExtra = &.{},
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
    /// Used by legacy + RFC #560 reads where file-level metadata
    /// (`include`, `assets`, ...) sits as siblings of `root`. Bundle
    /// scenes (RFC #596) carry these inside the leading
    /// `{ "meta": { ... } }` entry instead — see `meta` below.
    top_level: []const TopLevelExtra = &.{},
    /// Per-entity components we don't model. Indexed by source order.
    /// Inner slice may be empty when an entity has only modeled
    /// components (or no components block at all).
    entity_components: []const []const ComponentExtra = &.{},
    /// RFC #596 bundle scenes encode file-level directives as a leading
    /// `{ "meta": { ... } }` array entry. Each key+value pair is
    /// captured here verbatim and re-emitted on save. Empty for
    /// non-bundle scenes (where `top_level` carries the same data).
    meta: []const TopLevelExtra = &.{},
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

/// Append `entity` to `loaded.scene.entities` and grow the parallel
/// `extras.entity_components` list with an empty per-entity extras
/// slice so the two arrays stay lock-step on save.
///
/// **Arena lifetime**: `entity.prefab` (if non-null) must outlive the
/// `LoadedScene`. Pass an already-arena-allocated slice, or use the
/// arena directly: `try loaded.arena.allocator().dupe(u8, name)`.
/// `Position` and other scalar component buffers are by-value so they
/// move into the array without further allocation.
pub fn insertEntity(loaded: *LoadedScene, entity: Entity) !void {
    const a = loaded.arena.allocator();
    const old_entities = loaded.scene.entities;
    const new_entities = try a.alloc(Entity, old_entities.len + 1);
    @memcpy(new_entities[0..old_entities.len], old_entities);
    new_entities[old_entities.len] = entity;
    loaded.scene.entities = new_entities;

    // Grow extras.entity_components in lockstep. Old entries copy
    // through by value (they're slices pointing into the parse arena);
    // the new tail is an empty extras list.
    const old_extras = loaded.extras.entity_components;
    const new_extras = try a.alloc([]const ComponentExtra, old_extras.len + 1);
    @memcpy(new_extras[0..old_extras.len], old_extras);
    new_extras[old_extras.len] = &.{};
    loaded.extras.entity_components = new_extras;
}

/// Remove the entity at `idx` from `loaded.scene.entities` and the
/// parallel `extras.entity_components` entry (when present). Returns
/// `error.IndexOutOfBounds` if `idx` is past the end of either array.
///
/// Memory: the removed entries are simply skipped — the parse arena
/// keeps holding their bytes until the whole `LoadedScene` is freed.
/// That's fine for the editor's lifetime; a long-running session that
/// adds + removes many entities would still bound to the file size
/// because saves arena-reset on the next reload.
pub fn removeEntity(loaded: *LoadedScene, idx: usize) !void {
    const entities = loaded.scene.entities;
    if (idx >= entities.len) return error.IndexOutOfBounds;

    const a = loaded.arena.allocator();
    const new_entities = try a.alloc(Entity, entities.len - 1);
    @memcpy(new_entities[0..idx], entities[0..idx]);
    @memcpy(new_entities[idx..], entities[idx + 1 ..]);
    loaded.scene.entities = new_entities;

    const old_extras = loaded.extras.entity_components;
    if (idx < old_extras.len) {
        const new_extras = try a.alloc([]const ComponentExtra, old_extras.len - 1);
        @memcpy(new_extras[0..idx], old_extras[0..idx]);
        @memcpy(new_extras[idx..], old_extras[idx + 1 ..]);
        loaded.extras.entity_components = new_extras;
    }
}

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !LoadedScene {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    return parseScene(allocator, raw);
}

/// Append a child `Entity` to a `LoadedPrefab`'s `children` array,
/// growing `children_extras` with an empty extras slot in lockstep.
/// Mirrors `insertEntity` for prefabs — used by the prefab editor's
/// component-drop handler that needs a bare new child before
/// attaching its component as an unmodeled extra (#143).
pub fn insertChild(loaded: *LoadedPrefab, child: Entity) !void {
    const a = loaded.arena.allocator();
    const old_children = loaded.children;
    const new_children = try a.alloc(Entity, old_children.len + 1);
    @memcpy(new_children[0..old_children.len], old_children);
    new_children[old_children.len] = child;
    loaded.children = new_children;

    // Bring `children_extras` fully into lockstep with `children`.
    // Older prefab files may carry an extras slice shorter than the
    // children slice; sizing the new slice to `new_children.len`
    // (rather than `old_extras.len + 1`) pads every missing slot with
    // an empty extras entry so the two arrays end up the same length
    // regardless of the starting mismatch.
    const old_extras = loaded.children_extras;
    const new_extras = try a.alloc([]const ComponentExtra, new_children.len);
    const copy_len = @min(old_extras.len, new_extras.len);
    @memcpy(new_extras[0..copy_len], old_extras[0..copy_len]);
    for (new_extras[copy_len..]) |*slot| slot.* = &.{};
    loaded.children_extras = new_extras;
}

/// Look up `component_name` in the prefab cache and return a fresh
/// arena-owned copy of its body's Sprite, if any. The flying-platform-
/// labelle convention pairs many components with same-named prefabs
/// (`components/bed.zig` ↔ `prefabs/furniture/bed.jsonc`), so a
/// dropped component can render with the matching prefab's actual
/// atlas key instead of a placeholder (#143). Returns null when no
/// matching prefab exists, or when the matching prefab has no body
/// Sprite — caller falls through to "no visual," and the editor
/// renders the entity as a marker on the canvas until the user adds
/// a Sprite manually.
pub fn copySpriteFromMatchingPrefab(
    arena_allocator: std.mem.Allocator,
    component_name: []const u8,
    idx: ?*const prefab_index_mod.Index,
) ?*Sprite {
    const i = idx orelse return null;
    const pfx = i.find(component_name) orelse return null;
    const body_sprite = pfx.entity.sprite orelse return null;
    const p = arena_allocator.create(Sprite) catch return null;
    p.* = body_sprite.*;
    return p;
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
    const raw = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    return parsePrefab(allocator, raw);
}

pub fn parsePrefab(allocator: std.mem.Allocator, raw: []const u8) !LoadedPrefab {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const stripped = try stripLineComments(arena.allocator(), raw);

    // RFC #596 bundle prefab shape: inline PascalCase component keys
    // at top-level, no `root`/`components` wrapper. Detected by
    // absence of both wrapper keys; dispatched to a separate code
    // path that walks each key directly. The #175 path below stays
    // unchanged for legacy + RFC #560 inputs.
    if (isBundlePrefab(stripped)) {
        return parsePrefabBundle(arena, raw, stripped);
    }

    // RFC #560 unified prefab/scene format: entity content is wrapped
    // in a top-level `root: { ... }` object. The intermediate JSON
    // schema accepts both shapes — `root` (unified) and direct
    // `components`/`children` (legacy) — and the read-side picks
    // whichever the file actually carries. `ignore_unknown_fields`
    // keeps untouched-by-us metadata (name, version, etc.) flowing
    // through `extractPrefabTopLevelExtras` unchanged.
    const ChildEntry = struct {
        prefab: ?[]const u8 = null,
        components: ?std.json.Value = null,
        // Unified prefab refs spell `components` as `overrides`
        // (RFC #560 §B2). The reader accepts both keys on either
        // entry shape — strict §B2 enforcement is the engine
        // loader's job, the editor stays permissive so a hand-
        // edited prefab with the wrong-mode key doesn't refuse to
        // open. `components orelse overrides` resolves whichever
        // is populated; the writer always normalises on emit
        // (refs → overrides, inline → components).
        overrides: ?std.json.Value = null,
    };
    const Intermediate = struct {
        components: ?std.json.Value = null,
        children: []const ChildEntry = &.{},
        root: ?struct {
            components: ?std.json.Value = null,
            children: []const ChildEntry = &.{},
        } = null,
    };
    var parsed = try std.json.parseFromSlice(Intermediate, arena.allocator(), stripped, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    // Legacy schema → one warning per load so a contributor on an
    // older branch sees they're not yet on the unified format
    // (issue #174 acceptance bullet). The writer always normalises
    // on save, so the warning fires on read but not subsequent
    // saves of the same file.
    if (parsed.value.root == null) {
        std.log.warn("scene_io: prefab parsed in legacy schema (no `root` wrapper); will re-emit as unified RFC #560 on save", .{});
    }

    const eff_components: ?std.json.Value = if (parsed.value.root) |r| r.components else parsed.value.components;
    const eff_children: []const ChildEntry = if (parsed.value.root) |r| r.children else parsed.value.children;

    const entity: Entity = .{
        .position = readPosition(eff_components),
        .sprite = try readSprite(arena.allocator(), eff_components),
        .rectangle = try readRectangle(arena.allocator(), eff_components),
        .circle = try readCircle(arena.allocator(), eff_components),
        .polygon = try readPolygon(arena.allocator(), eff_components),
    };

    // Entity-level scanners walk the prefab body (inside root if
    // unified; the file top otherwise). Top-level extras still run
    // against the full raw because they need to capture metadata
    // that sits *outside* root in unified files.
    const scope = entityScope(raw);

    // Re-use the entity-body scanner — walks `{ ... }`, finds the
    // `components` key, captures every non-managed entry as verbatim
    // extras. Works the same for prefab body and child bodies.
    const component_extras = try extractComponentExtras(arena.allocator(), scope);

    // Children: mutable so the editor can drag-to-move them. Each
    // child gets its leading `//` comment block attached via the
    // same rule scenes use.
    const child_comments = try extractChildComments(arena.allocator(), scope);
    const child_extras = try extractChildComponentExtras(arena.allocator(), scope);
    var children = try arena.allocator().alloc(Entity, eff_children.len);
    for (eff_children, 0..) |c, i| {
        // Refs carry their data under `overrides`; inline children
        // use `components`. The reader doesn't care which spelling
        // appeared — pick whichever is populated.
        const co = c.components orelse c.overrides;
        children[i] = .{
            .prefab = if (c.prefab) |p| try arena.allocator().dupe(u8, p) else null,
            .position = readPosition(co),
            .sprite = try readSprite(arena.allocator(), co),
            .rectangle = try readRectangle(arena.allocator(), co),
            .circle = try readCircle(arena.allocator(), co),
            .polygon = try readPolygon(arena.allocator(), co),
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

/// RFC #596 bundle prefab parser. Top-level object IS the components
/// map directly — no `components`/`overrides` wrapper, no `root`.
/// PascalCase keys are components; `children` (when present) is the
/// sub-entity array with the same scene-entry shape used by
/// `parseSceneBundle`. The caller (`parsePrefab`) set up the arena
/// and stripped comments.
fn parsePrefabBundle(
    arena: *std.heap.ArenaAllocator,
    raw: []const u8,
    stripped: []const u8,
) !LoadedPrefab {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.PrefabNotAnObject;

    const top = parsed.value;
    const entity: Entity = .{
        .position = readPosition(top),
        .sprite = try readSprite(arena.allocator(), top),
        .rectangle = try readRectangle(arena.allocator(), top),
        .circle = try readCircle(arena.allocator(), top),
        .polygon = try readPolygon(arena.allocator(), top),
    };

    // Component extras: every top-level key except `prefab`,
    // `children`, and the five typed components rides along verbatim.
    const component_extras = try extractInlineComponentExtras(arena.allocator(), raw);

    // Children entries use the same inline-key shape as scene entries.
    const child_comments = try extractChildComments(arena.allocator(), raw);
    const child_extras = try extractChildBundleEntryComponentExtras(arena.allocator(), raw);
    const children_items: []std.json.Value = if (top.object.get("children")) |c|
        if (c == .array) c.array.items else &.{}
    else
        &.{};
    var children = try arena.allocator().alloc(Entity, children_items.len);
    for (children_items, 0..) |c, i| {
        children[i] = try parseBundleEntryToEntity(arena.allocator(), c);
        if (i < child_comments.len) {
            buf.writeZeroed(&children[i].comment, child_comments[i]);
        }
    }

    return .{
        .arena = arena,
        .entity = entity,
        .component_extras = component_extras,
        .children = children,
        .children_extras = child_extras,
        // RFC #596 collapses top-level prefab keys into components +
        // children; no separate "metadata above components" channel
        // exists, so this is always empty for bundle prefabs.
        .top_level_extras = &.{},
    };
}

pub fn savePrefab(allocator: std.mem.Allocator, path: []const u8, loaded: LoadedPrefab) !void {
    const text = try renderPrefabJsonc(allocator, loaded);
    defer allocator.free(text);
    try io_global.writeFileAtomic(
        std.Io.Dir.cwd(),
        io_global.io(),
        path,
        text,
        allocator,
    );
}

/// Emit the prefab in RFC #596 bundle shape: a top-level object whose
/// PascalCase keys are component blocks (no `components:` wrapper, no
/// `root:` wrapper), with `children: [...]` (when non-empty) carrying
/// sub-entities in the same scene-entry shape. All saves migrate
/// legacy + RFC #560 inputs to this canonical form — flying-platform
/// and the rest of the toolkit already moved to it.
pub fn renderPrefabJsonc(allocator: std.mem.Allocator, loaded: LoadedPrefab) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w: ListWriter = .{ .list = &out, .allocator = allocator };

    try out.appendSlice(allocator, "{");

    var first = true;
    if (loaded.entity.position) |p| {
        try out.print(allocator, "\n    \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
        first = false;
    }
    if (loaded.entity.sprite) |sp| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n   ");
        _ = try emitSprite(w, sp.*);
        first = false;
    }
    if (loaded.entity.rectangle) |re| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n   ");
        _ = try emitRectangle(w, re.*);
        first = false;
    }
    if (loaded.entity.circle) |ci| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n   ");
        _ = try emitCircle(w, ci.*);
        first = false;
    }
    if (loaded.entity.polygon) |po| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n   ");
        _ = try emitPolygon(w, po.*);
        first = false;
    }
    // `top_level_extras` only populates from legacy / RFC #560 reads.
    // Bundle prefabs collapse everything into components, so on a
    // bundle round-trip this is empty. Emit them as additional inline
    // keys when present — same shape as component extras.
    for (loaded.top_level_extras) |kv| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.print(allocator, "\n    \"{s}\": {s}", .{ kv.name, kv.value_text });
        first = false;
    }
    for (loaded.component_extras) |extra| {
        if (!first) try out.appendSlice(allocator, ",");
        try out.print(allocator, "\n    \"{s}\": {s}", .{ extra.name, extra.value_text });
        first = false;
    }

    if (loaded.children.len > 0) {
        if (!first) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n    \"children\": [\n");
        for (loaded.children, 0..) |child, i| {
            const comment = std.mem.sliceTo(&child.comment, 0);
            if (comment.len > 0) {
                var lines = std.mem.splitScalar(u8, std.mem.trim(u8, comment, " \t\r\n"), '\n');
                while (lines.next()) |line| {
                    try out.print(allocator, "        {s}\n", .{std.mem.trim(u8, line, " \t\r")});
                }
            }

            try out.appendSlice(allocator, "        {");
            try emitEntityBody(w, child, sliceExtrasAt(loaded.children_extras, i));
            try out.appendSlice(allocator, " }");
            if (i + 1 < loaded.children.len) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, "\n");
        }
        try out.appendSlice(allocator, "    ]");
        first = false;
    }

    if (first) {
        try out.appendSlice(allocator, "}\n");
    } else {
        try out.appendSlice(allocator, "\n}\n");
    }
    return out.toOwnedSlice(allocator);
}

fn sliceExtrasAt(table: []const []const ComponentExtra, i: usize) []const ComponentExtra {
    return if (i < table.len) table[i] else &.{};
}

/// Emit the inside of one entity object `{ ... }` — optional `prefab`
/// key plus inline PascalCase component keys (typed + verbatim
/// extras). Caller owns the surrounding `{` `}`. Used by both the
/// scene-entity and prefab-child writers.
fn emitEntityBody(w: ListWriter, e: Entity, extras: []const ComponentExtra) !void {
    var first = true;
    if (e.prefab) |p| {
        try w.print(" \"prefab\": \"{s}\"", .{p});
        first = false;
    }
    if (e.position) |p| {
        if (!first) try w.writeAll(",");
        try w.print(" \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
        first = false;
    }
    if (e.sprite) |sp| {
        if (!first) try w.writeAll(",");
        _ = try emitSprite(w, sp.*);
        first = false;
    }
    if (e.rectangle) |re| {
        if (!first) try w.writeAll(",");
        _ = try emitRectangle(w, re.*);
        first = false;
    }
    if (e.circle) |ci| {
        if (!first) try w.writeAll(",");
        _ = try emitCircle(w, ci.*);
        first = false;
    }
    if (e.polygon) |po| {
        if (!first) try w.writeAll(",");
        _ = try emitPolygon(w, po.*);
        first = false;
    }
    for (extras) |extra| {
        if (!first) try w.writeAll(",");
        try w.print(" \"{s}\": {s}", .{ extra.name, extra.value_text });
        first = false;
    }
    // Recursive children block (#143 Phase 5). Emits inline within the
    // entity body the same way components do — `"children": [...]` is
    // just one more key on the bundle entity. Each child round-trips
    // through `emitEntityBody` itself, so nesting is supported even
    // though `Entity.children` only carries one level of modeled data
    // today (grandchildren still ride in extras).
    if (e.children.len > 0) {
        if (!first) try w.writeAll(",");
        try w.writeAll(" \"children\": [\n");
        for (e.children, 0..) |child, ci| {
            const cextras = if (ci < e.children_extras.len) e.children_extras[ci] else &[_]ComponentExtra{};
            try w.writeAll("        {");
            try emitEntityBody(w, child, cextras);
            try w.writeAll(" }");
            if (ci + 1 < e.children.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("    ]");
        first = false;
    }
    if (first) try w.writeAll(" ");
}

pub fn parseScene(allocator: std.mem.Allocator, raw: []const u8) !LoadedScene {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const stripped = try stripLineComments(arena.allocator(), raw);

    // RFC #596 bundle scene shape: top-level JSON array, optional
    // leading `{ "meta": { ... } }` entry, inline PascalCase component
    // keys per entity (no `root`/`children`/`components` wrappers).
    // Detected by the first non-trivia token being `[`. Dispatched to
    // a separate parser; the #175 path below stays untouched for
    // legacy + RFC #560 inputs.
    if (isBundleScene(stripped)) {
        return parseSceneBundle(arena, raw, stripped);
    }

    // The intermediate JSON deserialization needs both fields & ignore-unknowns
    // because real scenes carry component keys (Sprite, Shape, …) we don't model.
    //
    // Accepts both layouts (RFC #560):
    //   - Legacy: `{ "name": "...", "entities": [ ... ] }`
    //   - Unified: `{ "name": "...", "root": { "children": [ ... ] } }`
    // The reader picks whichever the file actually carries; refs
    // inside `children` may spell `components` as `overrides` —
    // both fields are present on `SceneEntry` and the read-side
    // takes whichever is populated. `children` rides as raw
    // json.Value so the reader can walk it without declaring a
    // recursive schema — see `readEntityChildren` below (#143 Phase 5).
    const SceneEntry = struct {
        prefab: ?[]const u8 = null,
        components: ?std.json.Value = null,
        overrides: ?std.json.Value = null,
        children: ?std.json.Value = null,
    };
    const Intermediate = struct {
        name: []const u8 = "",
        entities: []const SceneEntry = &.{},
        root: ?struct {
            children: []const SceneEntry = &.{},
        } = null,
    };

    var parsed = try std.json.parseFromSlice(Intermediate, arena.allocator(), stripped, .{
        .ignore_unknown_fields = true,
    });
    // `parsed.deinit` is functionally a no-op here because the inner
    // arena std.json creates is backed by our outer arena (which is
    // freed wholesale on `LoadedScene.deinit`). Calling it anyway keeps
    // the ownership story consistent with other call sites.
    defer parsed.deinit();

    // Legacy schema → one warning per load (issue #174 acceptance).
    // Saves always re-emit as unified, so the warning fires on read
    // but not on subsequent saves of the same file.
    if (parsed.value.root == null) {
        std.log.warn("scene_io: scene parsed in legacy schema (no `root` wrapper); will re-emit as unified RFC #560 on save", .{});
    }

    const eff_entries: []const SceneEntry = if (parsed.value.root) |r| r.children else parsed.value.entities;

    // Entity-level scanners walk inside the root wrapper when present,
    // and the full file otherwise. `extractTopLevelExtras` keeps the
    // raw scope so metadata sibling to `root` (e.g. `assets`,
    // `include`) is preserved.
    const scope = entityScope(raw);

    // Walk the source a second time to pluck out each entity's leading
    // comments. Done as a separate pass over the *raw* (pre-stripped)
    // text — the stripped buffer has spaces where `//` lines used to be,
    // so we can't recover comments from it.
    const comments = try extractEntityComments(arena.allocator(), scope);
    // Per-entity child extras: parallel to the entities slice. Each
    // slot is the list of unmodeled component-extras for each child of
    // that entity. Empty when an entity has no children. Same shape
    // the prefab side already uses for its single `children:` array,
    // just walked per entity. Scans the raw source so embedded
    // comments / formatting in a child component value survive the
    // round-trip (#143 Phase 5).
    const children_extras_per_entity = try extractEntityChildrenExtras(arena.allocator(), raw);

    var entities = try arena.allocator().alloc(Entity, eff_entries.len);
    for (eff_entries, 0..) |e, i| {
        const oc = e.components orelse e.overrides;
        entities[i] = .{
            .prefab = if (e.prefab) |p| try arena.allocator().dupe(u8, p) else null,
            .position = readPosition(oc),
            .sprite = try readSprite(arena.allocator(), oc),
            .rectangle = try readRectangle(arena.allocator(), oc),
            .circle = try readCircle(arena.allocator(), oc),
            .polygon = try readPolygon(arena.allocator(), oc),
            .children = try readEntityChildren(arena.allocator(), e.children),
            .children_extras = if (i < children_extras_per_entity.len)
                children_extras_per_entity[i]
            else
                &.{},
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
    const entity_components_extras = try extractEntityComponentExtras(arena.allocator(), scope);

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

/// RFC #596 bundle scene parser. Reads a top-level JSON array,
/// splits off the optional leading `{ "meta": { ... } }` directive
/// entry, and turns each remaining array item into an `Entity` with
/// inline PascalCase component keys (no `components`/`overrides`
/// wrapper). The caller (`parseScene`) has already set up the arena
/// and stripped comments.
fn parseSceneBundle(
    arena: *std.heap.ArenaAllocator,
    raw: []const u8,
    stripped: []const u8,
) !LoadedScene {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), stripped, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.SceneNotAnArray;

    var first_entity_idx: usize = 0;
    var meta_entries: []const TopLevelExtra = &.{};
    if (parsed.value.array.items.len > 0) {
        const first = parsed.value.array.items[0];
        if (first == .object and first.object.get("meta") != null) {
            meta_entries = try extractMetaEntries(arena.allocator(), raw);
            first_entity_idx = 1;
        }
    }

    const entity_items = parsed.value.array.items[first_entity_idx..];
    var entities = try arena.allocator().alloc(Entity, entity_items.len);
    for (entity_items, 0..) |entry, i| {
        entities[i] = try parseBundleEntryToEntity(arena.allocator(), entry);
    }

    // Per-entity scanners walk the top-level array, skipping the meta
    // entry when present so the resulting per-entity slices line up
    // with `entities` above.
    const comments = try extractBundleEntryComments(arena.allocator(), raw, first_entity_idx);
    for (entities, 0..) |*e, i| {
        if (i < comments.len) buf.writeZeroed(&e.comment, comments[i]);
    }
    const entity_components_extras = try extractBundleEntryComponentExtras(arena.allocator(), raw, first_entity_idx);

    return .{
        .arena = arena,
        .scene = .{ .entities = entities },
        .extras = .{
            .meta = meta_entries,
            .entity_components = entity_components_extras,
        },
    };
}

/// Build an `Entity` from a single bundle-shape entry object. Entry
/// shape is `{ "prefab"?: string, "ComponentName": {...}, ... }` —
/// inline PascalCase keys sit alongside the optional `prefab`
/// reference. The typed component readers only look up their own
/// key on the passed value, so handing them the whole entry is
/// correct.
fn parseBundleEntryToEntity(arena: std.mem.Allocator, entry: std.json.Value) !Entity {
    if (entry != .object) return error.EntityNotAnObject;
    const prefab: ?[]const u8 = blk: {
        if (entry.object.get("prefab")) |p| {
            if (p == .string) break :blk try arena.dupe(u8, p.string);
        }
        break :blk null;
    };
    return .{
        .prefab = prefab,
        .position = readPosition(entry),
        .sprite = try readSprite(arena, entry),
        .rectangle = try readRectangle(arena, entry),
        .circle = try readCircle(arena, entry),
        .polygon = try readPolygon(arena, entry),
        // #143 Phase 5: bundle entities carry `children` as the same
        // inline array shape `readEntityChildren` already walks for
        // the legacy/#560 path. `children_extras` is best-effort here
        // — the bundle source-text scanner that would surface them
        // isn't wired yet; downstream code tolerates an empty extras
        // slice (the writer just emits modeled components for each
        // child).
        .children = try readEntityChildren(arena, entry.object.get("children")),
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
    // Unified scenes (RFC #560) name the array `children` (inside
    // `root: { ... }`); legacy scenes use `entities`. Either resolves.
    return extractArrayItemComments(arena, raw, findSceneEntriesArray(raw) orelse return &.{});
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
    return extractArrayItemCommentsSkip(arena, raw, array_lbracket, 0);
}

/// Same as `extractArrayItemComments` but skips the first `skip`
/// items before recording comments. Bundle scenes use this with
/// `skip = 1` when a leading `{ "meta": { ... } }` directive entry
/// is present so the returned per-entity comment list lines up with
/// `loaded.scene.entities`.
fn extractArrayItemCommentsSkip(
    arena: std.mem.Allocator,
    raw: []const u8,
    array_lbracket: usize,
    skip: usize,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);

    var i: usize = array_lbracket + 1; // past '['
    var item_index: usize = 0;

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

        if (item_index >= skip) {
            const trimmed = std.mem.trim(u8, raw[comment_start..comment_end], " \t\r\n");
            try out.append(arena, try arena.dupe(u8, trimmed));
        }
        item_index += 1;

        scanBalanced(raw, &i, '{', '}');
    }
    return out.toOwnedSlice(arena);
}

/// Bundle-scene per-entity comments. Walks the top-level array,
/// dropping the leading meta entry when present.
fn extractBundleEntryComments(
    arena: std.mem.Allocator,
    raw: []const u8,
    skip: usize,
) ![]const []const u8 {
    return extractArrayItemCommentsSkip(arena, raw, findTopLevelArrayStart(raw) orelse return &.{}, skip);
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

/// Scene-side array of top-level entries. Legacy scenes call it
/// `entities`; unified scenes (RFC #560) wrap the array under
/// `root: { "children": [...] }`. The caller is expected to pass
/// the in-scope body (root body if unified, the file root if legacy);
/// either name resolves so a single helper covers both eras.
fn findSceneEntriesArray(scope: []const u8) ?usize {
    return findEntitiesArray(scope) orelse findChildrenArray(scope);
}

/// When `raw` is wrapped in a top-level `"root": { ... }` (RFC #560
/// unified prefab/scene format), return the slice spanning the body
/// of that wrapper inclusive of the outer braces. Returns null for
/// legacy files, signalling the caller to keep scanning the entire
/// `raw` buffer.
///
/// The returned slice is a view into `raw` — no allocation. Callers
/// that need a scope-for-scanners convenience should use
/// `entityScope` below, which folds the null case into `raw` itself.
fn findRootBraceBody(raw: []const u8) ?[]const u8 {
    var i: usize = 0;
    skipWhitespaceJson(raw, &i);
    skipCommentBlock(raw, &i);
    skipWhitespaceJson(raw, &i);
    if (i >= raw.len or raw[i] != '{') return null;
    i += 1;

    while (i < raw.len) {
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);
        if (i >= raw.len) return null;
        if (raw[i] == '}') return null;
        if (raw[i] == ',') {
            i += 1;
            continue;
        }
        if (raw[i] != '"') return null;

        const key = parseStringLiteral(raw, &i) orelse return null;
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);
        if (i >= raw.len or raw[i] != ':') return null;
        i += 1;
        skipWhitespaceJson(raw, &i);
        skipCommentBlock(raw, &i);
        skipWhitespaceJson(raw, &i);

        if (std.mem.eql(u8, key, "root")) {
            if (i >= raw.len or raw[i] != '{') return null;
            const start = i;
            scanBalanced(raw, &i, '{', '}');
            return raw[start..i];
        }
        // Not root — skip its value and keep looking.
        scanValueJson(raw, &i);
    }
    return null;
}

/// Convenience wrapper: returns the root body slice when present, or
/// `raw` itself otherwise. Entity-level scanners
/// (`extractEntityComments`, `extractComponentExtras`, etc.) should
/// run against this scope so they look inside the `root` wrapper on
/// unified files and against the legacy top-level otherwise.
fn entityScope(raw: []const u8) []const u8 {
    return findRootBraceBody(raw) orelse raw;
}

// ─── RFC #596 bundle detection ─────────────────────────────────────────

/// True when `raw` (already comment-stripped) opens with `[` after
/// any leading whitespace/comments — i.e. a bundle-shape scene per
/// RFC #596. Cheap one-pass scan; the parser dispatches on this.
fn isBundleScene(raw: []const u8) bool {
    return findTopLevelArrayStart(raw) != null;
}

/// Locate the opening `[` of a bundle scene's top-level array.
/// Skips leading whitespace + `//` comments. Returns null when the
/// first non-trivia byte isn't `[`.
fn findTopLevelArrayStart(raw: []const u8) ?usize {
    var i: usize = 0;
    skipWhitespaceJson(raw, &i);
    skipCommentBlock(raw, &i);
    skipWhitespaceJson(raw, &i);
    if (i < raw.len and raw[i] == '[') return i;
    return null;
}

/// True when `raw` (already comment-stripped) is a JSON object whose
/// top-level lacks both `root` and `components` keys — i.e. a
/// bundle-shape prefab per RFC #596. Bundle prefabs hoist component
/// blocks to the top level as inline PascalCase keys, so any prefab
/// without a wrapper key takes the bundle path. Empty `{}` also
/// matches and parses harmlessly as a no-op prefab.
fn isBundlePrefab(raw: []const u8) bool {
    var i: usize = 0;
    skipWhitespaceJson(raw, &i);
    skipCommentBlock(raw, &i);
    skipWhitespaceJson(raw, &i);
    if (i >= raw.len or raw[i] != '{') return false;
    return findKeyObject(raw, "root") == null and
        findKeyObject(raw, "components") == null;
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
    var out: std.ArrayList(TopLevelExtra) = .empty;
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
    // Unified scenes (#560) spell the scene-entities array `children`
    // (inside `root: { ... }`); legacy scenes use `entities` at the
    // file root. `findSceneEntriesArray` accepts either.
    return extractArrayItemComponentExtras(arena, raw, findSceneEntriesArray(raw) orelse return &.{});
}

/// Per-entity, per-child component extras. Walks the scene's
/// `entities: [...]` array; for each entity body, locates its
/// `children: [...]` sub-array (if any) and captures the unmodeled
/// component keys on each child. Result shape: outer slot per entity
/// in source order, inner slot per child of that entity, innermost
/// the verbatim `ComponentExtra` list. Entities without children get
/// an empty inner slice. Used by `parseScene` to feed
/// `Entity.children_extras` so per-child verbatim components round-trip
/// even when the gui doesn't model them. (#143 Phase 5)
fn extractEntityChildrenExtras(arena: std.mem.Allocator, raw: []const u8) ![]const []const []const ComponentExtra {
    var out: std.ArrayList([]const []const ComponentExtra) = .empty;
    errdefer out.deinit(arena);

    const entities_lbracket = findEntitiesArray(raw) orelse return out.toOwnedSlice(arena);
    var i: usize = entities_lbracket + 1; // past '['

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

        if (findArrayByKey(entity_body, "\"children\"")) |lbracket| {
            const per_child = try extractArrayItemComponentExtras(arena, entity_body, lbracket);
            try out.append(arena, per_child);
        } else {
            try out.append(arena, &.{});
        }
    }
    return out.toOwnedSlice(arena);
}

/// Read a scene entity's `children: [...]` JSON value into a slice
/// of modeled `Entity` records. One level deep — children's children
/// (grandchildren) ride along via `children_extras` if any, modeled
/// fields stay default-empty. Mirrors how `parsePrefab` reads the
/// prefab body's children, but driven off `std.json.Value` so the
/// caller doesn't need to declare a recursive schema. (#143 Phase 5)
fn readEntityChildren(arena: std.mem.Allocator, children_val: ?std.json.Value) ![]Entity {
    const v = children_val orelse return &.{};
    if (v != .array) return &.{};
    const arr = v.array.items;
    var out = try arena.alloc(Entity, arr.len);
    for (arr, 0..) |item, i| {
        if (item != .object) {
            out[i] = .{};
            continue;
        }
        const prefab_val = item.object.get("prefab");
        // Accept both shapes per child entry:
        //   - Legacy/#560: components live under a `components` (or
        //     `overrides` for refs) sub-object.
        //   - Bundle (#596): no wrapper — component keys sit inline on
        //     the entry itself.
        // Fallback chain handles both so a scene fed in as legacy
        // round-trips back through bundle output without the children
        // becoming naked rows on the second read (#143 Phase 5).
        const components_val: ?std.json.Value = item.object.get("components") orelse
            item.object.get("overrides") orelse
            item;
        out[i] = .{
            .prefab = if (prefab_val) |pv|
                (if (pv == .string) try arena.dupe(u8, pv.string) else null)
            else
                null,
            .position = readPosition(components_val),
            .sprite = try readSprite(arena, components_val),
            .rectangle = try readRectangle(arena, components_val),
            .circle = try readCircle(arena, components_val),
            .polygon = try readPolygon(arena, components_val),
        };
    }
    return out;
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
    return extractArrayItemComponentExtrasSkip(arena, raw, array_lbracket, 0, extractComponentExtras);
}

/// Same as `extractArrayItemComponentExtras` but skips the first
/// `skip` items and runs the caller-supplied per-entity extractor on
/// the rest. Bundle scenes use this with the inline-keys extractor;
/// legacy/#560 scenes use it with the `components`-wrapper one.
fn extractArrayItemComponentExtrasSkip(
    arena: std.mem.Allocator,
    raw: []const u8,
    array_lbracket: usize,
    skip: usize,
    perEntity: *const fn (std.mem.Allocator, []const u8) anyerror![]const ComponentExtra,
) ![]const []const ComponentExtra {
    var out: std.ArrayList([]const ComponentExtra) = .empty;
    errdefer out.deinit(arena);

    var i: usize = array_lbracket + 1; // past '['
    var item_index: usize = 0;

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
        if (item_index >= skip) {
            try out.append(arena, try perEntity(arena, raw[entity_start..entity_end]));
        }
        item_index += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Bundle-scene per-entity component extras. Walks the top-level
/// array, drops the leading meta entry when present, and captures
/// each entity's unmodeled components via the inline-key extractor.
fn extractBundleEntryComponentExtras(
    arena: std.mem.Allocator,
    raw: []const u8,
    skip: usize,
) ![]const []const ComponentExtra {
    return extractArrayItemComponentExtrasSkip(
        arena,
        raw,
        findTopLevelArrayStart(raw) orelse return &.{},
        skip,
        extractInlineComponentExtras,
    );
}

/// Bundle-prefab per-child component extras. Walks the `children:`
/// array (still keyed by name in bundle prefabs) and runs the
/// inline-key extractor on each entry.
fn extractChildBundleEntryComponentExtras(
    arena: std.mem.Allocator,
    raw: []const u8,
) ![]const []const ComponentExtra {
    return extractArrayItemComponentExtrasSkip(
        arena,
        raw,
        findChildrenArray(raw) orelse return &.{},
        0,
        extractInlineComponentExtras,
    );
}

/// Walk an object body and capture every key+value pair whose key
/// isn't a typed component (`Position`, `Sprite`, `Rectangle`,
/// `Circle`, `Polygon`) or an entry-level reserved key (`prefab`,
/// `children`). `body` may begin with leading whitespace / `//`
/// comments before its outer `{`. Used by the RFC #596 bundle paths
/// where component blocks sit inline rather than under a wrapper.
fn extractInlineComponentExtras(arena: std.mem.Allocator, body: []const u8) anyerror![]const ComponentExtra {
    var out: std.ArrayList(ComponentExtra) = .empty;
    errdefer out.deinit(arena);

    var i: usize = 0;
    skipWhitespaceJson(body, &i);
    skipCommentBlock(body, &i);
    skipWhitespaceJson(body, &i);
    if (i < body.len and body[i] == '{') i += 1;

    while (i < body.len) {
        skipWhitespaceJson(body, &i);
        skipCommentBlock(body, &i);
        skipWhitespaceJson(body, &i);
        if (i >= body.len) break;
        if (body[i] == '}') break;
        if (body[i] == ',') {
            i += 1;
            continue;
        }
        if (body[i] != '"') break;

        const key = parseStringLiteral(body, &i) orelse break;

        skipWhitespaceJson(body, &i);
        if (i >= body.len or body[i] != ':') break;
        i += 1;
        skipWhitespaceJson(body, &i);

        const value_start = i;
        scanValueJson(body, &i);
        const value_end = i;

        const is_reserved = std.mem.eql(u8, key, "prefab") or std.mem.eql(u8, key, "children");
        const is_typed = std.mem.eql(u8, key, "Position") or
            std.mem.eql(u8, key, "Sprite") or
            std.mem.eql(u8, key, "Rectangle") or
            std.mem.eql(u8, key, "Circle") or
            std.mem.eql(u8, key, "Polygon");
        if (!is_reserved and !is_typed) {
            try out.append(arena, .{
                .name = try arena.dupe(u8, key),
                .value_text = try arena.dupe(u8, std.mem.trim(u8, body[value_start..value_end], " \t\r\n")),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Capture key+value pairs of the leading `{ "meta": { ... } }` entry
/// of a bundle scene. Caller has already confirmed (via the parsed
/// JSON) that a meta entry exists; this scanner finds it in raw
/// text so embedded comments / formatting survive the round-trip.
fn extractMetaEntries(arena: std.mem.Allocator, raw: []const u8) ![]const TopLevelExtra {
    const array_start = findTopLevelArrayStart(raw) orelse return &.{};
    var i: usize = array_start + 1;
    skipWhitespaceJson(raw, &i);
    skipCommentBlock(raw, &i);
    skipWhitespaceJson(raw, &i);
    if (i >= raw.len or raw[i] != '{') return &.{};

    const entry_start = i;
    var probe = i;
    scanBalanced(raw, &probe, '{', '}');
    const entry_body = raw[entry_start..probe];

    const meta_obj_start = findKeyObject(entry_body, "meta") orelse return &.{};
    // Walk the meta object body and capture every key+value pair
    // verbatim. Unlike `extractInlineComponentExtras`, nothing is
    // filtered — meta is fully pass-through.
    var out: std.ArrayList(TopLevelExtra) = .empty;
    errdefer out.deinit(arena);

    var j: usize = meta_obj_start + 1; // past '{'
    while (j < entry_body.len) {
        skipWhitespaceJson(entry_body, &j);
        skipCommentBlock(entry_body, &j);
        skipWhitespaceJson(entry_body, &j);
        if (j >= entry_body.len) break;
        if (entry_body[j] == '}') break;
        if (entry_body[j] == ',') {
            j += 1;
            continue;
        }
        if (entry_body[j] != '"') break;

        const key = parseStringLiteral(entry_body, &j) orelse break;
        skipWhitespaceJson(entry_body, &j);
        if (j >= entry_body.len or entry_body[j] != ':') break;
        j += 1;
        skipWhitespaceJson(entry_body, &j);

        const value_start = j;
        scanValueJson(entry_body, &j);
        const value_end = j;

        try out.append(arena, .{
            .name = try arena.dupe(u8, key),
            .value_text = try arena.dupe(u8, std.mem.trim(u8, entry_body[value_start..value_end], " \t\r\n")),
        });
    }
    return out.toOwnedSlice(arena);
}

fn extractComponentExtras(arena: std.mem.Allocator, entity_body: []const u8) ![]const ComponentExtra {
    var out: std.ArrayList(ComponentExtra) = .empty;
    errdefer out.deinit(arena);

    // Find `"components"` key inside the entity body. Unified prefab
    // refs (RFC #560) spell this as `overrides`; either name resolves
    // to the same shape of object so we accept whichever is present.
    const components_obj_start = findKeyObject(entity_body, "components") orelse
        findKeyObject(entity_body, "overrides") orelse
        return out.toOwnedSlice(arena);
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
    // `root` is the RFC #560 unified-format wrapper holding entities
    // (under `children` inside it). The writer re-emits it from the
    // modeled scene, so capturing it as a pass-through extra would
    // double-emit on save.
    return std.mem.eql(u8, name, "name") or
        std.mem.eql(u8, name, "entities") or
        std.mem.eql(u8, name, "root");
}

fn isManagedPrefabTopLevelKey(name: []const u8) bool {
    // Same reasoning: `root` is the unified wrapper and gets
    // re-emitted by the writer from the modeled prefab body.
    return std.mem.eql(u8, name, "components") or
        std.mem.eql(u8, name, "children") or
        std.mem.eql(u8, name, "root");
}

// ─── Writer ────────────────────────────────────────────────────────────

/// Write the in-memory scene + extras back to disk at `path`, replacing
/// any existing file. The write is atomic — see
/// `io_global.writeFileAtomic` — so a crash mid-save can never corrupt
/// the scene on disk.
pub fn saveScene(allocator: std.mem.Allocator, path: []const u8, loaded: LoadedScene) !void {
    const text = try renderSceneJsonc(allocator, loaded);
    defer allocator.free(text);
    try io_global.writeFileAtomic(
        std.Io.Dir.cwd(),
        io_global.io(),
        path,
        text,
        allocator,
    );
}

/// Render the loaded scene back to JSONC in RFC #596 bundle shape: a
/// top-level JSON array. When meta or legacy top-level extras exist a
/// leading `{ "meta": { ... } }` entry is emitted first, carrying
/// every directive verbatim. Each entity then becomes one array entry
/// with optional `prefab` plus inline PascalCase component keys — no
/// `components`/`overrides`/`root` wrappers. All saves migrate legacy
/// + RFC #560 inputs to this canonical form.
pub fn renderSceneJsonc(allocator: std.mem.Allocator, loaded: LoadedScene) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const w: ListWriter = .{ .list = &out, .allocator = allocator };

    const meta_count = loaded.extras.meta.len + loaded.extras.top_level.len;
    const has_meta = meta_count > 0;
    const total_items: usize = loaded.scene.entities.len + @as(usize, if (has_meta) 1 else 0);

    try out.appendSlice(allocator, "[");
    if (total_items == 0) {
        try out.appendSlice(allocator, "]\n");
        return out.toOwnedSlice(allocator);
    }
    try out.appendSlice(allocator, "\n");

    if (has_meta) {
        try out.appendSlice(allocator, "    { \"meta\": {");
        var mi: usize = 0;
        // Native bundle meta entries first; then legacy/#560 top-level
        // extras (`include`, `assets`, ...) folded under the same key
        // so a #560 scene saved through here ends up with directives
        // canonicalised into `meta`.
        for (loaded.extras.meta) |kv| {
            if (mi > 0) try out.appendSlice(allocator, ",");
            try out.print(allocator, " \"{s}\": {s}", .{ kv.name, kv.value_text });
            mi += 1;
        }
        for (loaded.extras.top_level) |kv| {
            if (mi > 0) try out.appendSlice(allocator, ",");
            try out.print(allocator, " \"{s}\": {s}", .{ kv.name, kv.value_text });
            mi += 1;
        }
        try out.appendSlice(allocator, " } }");
        if (loaded.scene.entities.len > 0) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n");
    }

    for (loaded.scene.entities, 0..) |e, i| {
        // Comment lines first, at the array indent.
        const comment = std.mem.sliceTo(&e.comment, 0);
        if (comment.len > 0) {
            var lines = std.mem.splitScalar(u8, std.mem.trim(u8, comment, " \t\r\n"), '\n');
            while (lines.next()) |line| {
                try out.print(allocator, "    {s}\n", .{std.mem.trim(u8, line, " \t\r")});
            }
        }

        try out.appendSlice(allocator, "    {");
        try emitEntityBody(w, e, sliceExtrasAt(loaded.extras.entity_components, i));
        try out.appendSlice(allocator, " }");
        if (i + 1 < loaded.scene.entities.len) try out.appendSlice(allocator, ",");
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "]\n");

    return out.toOwnedSlice(allocator);
}
