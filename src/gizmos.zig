//! Per-project gizmo index. On project open we walk `<project>/gizmos/*.zon`,
//! parse each file's `.match` / `.exclude` predicates, and extract a typed
//! `Shape` from the `.entity` block so the viewport can overlay debug
//! visualizations on scene/prefab entities whose components match.
//!
//! Shape semantics mirror `../labelle-gfx/src/visuals.zig` — a tagged
//! union of `circle`/`rectangle`/`triangle`/`line`/`polygon` (the
//! engine's polygon is a regular n-gon, not an arbitrary point list).
//!
//! `gizmo_io.zig` continues to round-trip the gizmo file verbatim (with
//! `entity_verbatim` preserving the source text); this module pulls the
//! typed bits out for drawing without disrupting that round-trip.
//!
//! Like `src/atlas.zig`, the index is owned by `App` and keyed by
//! `ProjectManager.generation` so project new/close/load invalidates it.
//!
//! Known v1 limitation: matching is against an entity's *direct*
//! component name set. We don't follow `prefab:` references to gather
//! the prefab's components, so an entity like `{ prefab: "workstation" }`
//! that doesn't inline the `Workstation` component won't match a
//! `.match = .{"Workstation"}` gizmo. The engine matches after prefab
//! instantiation; we'd need a prefab index to do the same. Tracked for
//! a follow-up.

const std = @import("std");

const gizmo_io = @import("gizmo_io.zig");

pub const FillMode = enum {
    filled,
    outline,
};

/// Shape primitives — mirrors `../labelle-gfx/src/visuals.zig:11`. Field
/// names and defaults match so a future round-trip via the typed model
/// will agree with what the engine ships.
pub const Shape = union(enum) {
    circle: Circle,
    rectangle: Rectangle,
    line: Line,
    triangle: Triangle,
    polygon: Polygon,

    pub const Circle = struct {
        radius: f32,
        fill: FillMode = .filled,
        thickness: f32 = 1.0,
    };
    pub const Rectangle = struct {
        width: f32,
        height: f32,
        fill: FillMode = .filled,
        thickness: f32 = 1.0,
    };
    pub const Line = struct {
        end: Point = .{},
        thickness: f32 = 1.0,
    };
    pub const Triangle = struct {
        p2: Point = .{},
        p3: Point = .{},
        fill: FillMode = .filled,
        thickness: f32 = 1.0,
    };
    pub const Polygon = struct {
        sides: i32 = 3,
        radius: f32 = 10,
        fill: FillMode = .filled,
        thickness: f32 = 1.0,
    };
};

/// Engine uses `Position` for points inside Shape variants; mirror.
pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Color = struct {
    r: u8 = 255,
    g: u8 = 255,
    b: u8 = 255,
    a: u8 = 255,
};

/// One gizmo entry usable by the viewport. `match` / `exclude` are
/// the predicates from the source file; `shape` is the typed render
/// data extracted from `.entity.Shape.shape`. Color and offset come
/// from `.entity.Shape.{color, x, y}` — both with engine defaults.
pub const Entry = struct {
    /// Source path. Useful for diagnostics; keys live in the index
    /// arena.
    source: []const u8,
    match: []const []const u8,
    exclude: []const []const u8,
    shape: Shape,
    color: Color = .{},
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .{},
    /// `ProjectManager.generation` this index was built against. App
    /// invalidates when the live generation changes.
    generation: u64,
    /// Per-entry arenas so each gizmo's string lifetimes are bounded
    /// to its own slot — same shape `atlas.Index` uses.
    arenas: std.ArrayListUnmanaged(*std.heap.ArenaAllocator) = .{},

    pub fn deinit(self: *Index) void {
        for (self.arenas.items) |a| {
            a.deinit();
            self.allocator.destroy(a);
        }
        self.arenas.deinit(self.allocator);
        self.entries.deinit(self.allocator);
    }

    /// Walk `<project_dir>/gizmos/` and load every `.zon` file. Errors
    /// on a single file are logged and skipped — same tolerance the
    /// atlas loader uses for malformed entries.
    pub fn build(
        allocator: std.mem.Allocator,
        project_dir: []const u8,
        generation: u64,
    ) Index {
        var idx: Index = .{ .allocator = allocator, .generation = generation };

        const gizmos_dir = std.fs.path.join(allocator, &.{ project_dir, "gizmos" }) catch return idx;
        defer allocator.free(gizmos_dir);

        var dir = std.fs.cwd().openDir(gizmos_dir, .{ .iterate = true }) catch return idx;
        defer dir.close();

        var it = dir.iterate();
        while (it.next() catch null) |dirent| {
            if (dirent.kind != .file) continue;
            if (!std.mem.endsWith(u8, dirent.name, ".zon")) continue;

            const full = std.fs.path.join(allocator, &.{ gizmos_dir, dirent.name }) catch continue;
            defer allocator.free(full);

            loadOne(allocator, &idx, full) catch |err| {
                std.log.warn("Gizmo '{s}' failed to load: {s}", .{ full, @errorName(err) });
                continue;
            };
        }
        return idx;
    }
};

fn loadOne(allocator: std.mem.Allocator, idx: *Index, path: []const u8) !void {
    var loaded = try gizmo_io.loadFromFile(allocator, path);
    defer loaded.deinit();

    const entity_text = loaded.gizmo.entity_verbatim orelse {
        // Gizmo with no `.entity` block — could still have `.children`,
        // but we don't support multi-shape gizmos yet. Skip.
        return;
    };

    // Stand up a fresh arena to own the entry's typed data. We move
    // the match/exclude lists across by deep-copying into this arena;
    // then `loaded` can be freed by the defer above. This keeps the
    // per-entry lifetime tidy independent of the source.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const match_owned = try dupeStrings(a, loaded.gizmo.match);
    const exclude_owned = try dupeStrings(a, loaded.gizmo.exclude);

    const parsed = try parseEntityBlock(a, entity_text);
    const source_owned = try a.dupe(u8, path);

    // Reserve both list slots up front so the two appends below are
    // infallible — otherwise an OOM between the two would leave the
    // arena tracked in `idx.arenas` while also being freed by the
    // arena errdefers above (dangling pointer on next `Index.deinit`).
    try idx.arenas.ensureUnusedCapacity(allocator, 1);
    try idx.entries.ensureUnusedCapacity(allocator, 1);
    idx.arenas.appendAssumeCapacity(arena);
    idx.entries.appendAssumeCapacity(.{
        .source = source_owned,
        .match = match_owned,
        .exclude = exclude_owned,
        .shape = parsed.shape,
        .color = parsed.color,
        .offset_x = parsed.offset_x,
        .offset_y = parsed.offset_y,
    });
}

fn dupeStrings(arena: std.mem.Allocator, src: [][]const u8) ![][]const u8 {
    const out = try arena.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
    return out;
}

const ParsedEntity = struct {
    shape: Shape,
    color: Color,
    offset_x: f32,
    offset_y: f32,
};

/// Parse the verbatim ZON text of `.entity` (e.g. `.{ .Shape = .{ ... } }`)
/// into typed render data. The standard library's ZON parser handles
/// tagged unions, structs, and primitive coercion; we just spell out
/// the expected schema.
fn parseEntityBlock(arena: std.mem.Allocator, verbatim: []const u8) !ParsedEntity {
    // Note: `Color` and `Point` use field defaults so an absent field
    // (or zero) parses cleanly. `Shape` is required.
    const ShapeBlock = struct {
        x: f32 = 0,
        y: f32 = 0,
        shape: Shape,
        color: Color = .{},
    };
    const Entity = struct {
        Shape: ShapeBlock,
    };

    const source = try arena.dupeZ(u8, verbatim);
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    const parsed = std.zon.parse.fromSlice(Entity, arena, source, &diag, .{
        .ignore_unknown_fields = true,
    }) catch return error.UnsupportedEntityShape;

    return .{
        .shape = parsed.Shape.shape,
        .color = parsed.Shape.color,
        .offset_x = parsed.Shape.x,
        .offset_y = parsed.Shape.y,
    };
}

// ─── Match logic ───────────────────────────────────────────────────────

/// Returns true when at least one `match` name is in `present` and
/// no `exclude` name is. Empty `match` is treated as "matches
/// everything" — the engine convention.
pub fn entityMatches(
    match: []const []const u8,
    exclude: []const []const u8,
    present: []const []const u8,
) bool {
    // Reject first if any exclude matches.
    for (exclude) |x| if (contains(present, x)) return false;
    if (match.len == 0) return true;
    for (match) |m| if (contains(present, m)) return true;
    return false;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}
