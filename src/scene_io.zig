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

pub const Position = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Entity = struct {
    prefab: ?[]const u8 = null,
    /// Parsed once on load; viewport reads it when drawing the entity
    /// marker. Components that aren't known to this struct are ignored,
    /// which lets the gui open scenes that reference component types
    /// we don't model yet (Sprite, Shape, user-defined components).
    position: ?Position = null,
};

pub const Scene = struct {
    name: []const u8 = "",
    entities: []const Entity = &.{},
};

/// Loaded scene plus the arena that owns its memory. Caller frees via
/// `LoadedScene.deinit()`.
pub const LoadedScene = struct {
    arena: *std.heap.ArenaAllocator,
    scene: Scene,

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

    const parsed = try std.json.parseFromSlice(Intermediate, arena.allocator(), stripped, .{
        .ignore_unknown_fields = true,
    });

    var entities = try arena.allocator().alloc(Entity, parsed.value.entities.len);
    for (parsed.value.entities, 0..) |e, i| {
        entities[i] = .{
            .prefab = if (e.prefab) |p| try arena.allocator().dupe(u8, p) else null,
            .position = readPosition(e.components),
        };
    }

    return .{
        .arena = arena,
        .scene = .{
            .name = try arena.allocator().dupe(u8, parsed.value.name),
            .entities = entities,
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

fn jsonNumberAsF32(v: ?std.json.Value) ?f32 {
    const value = v orelse return null;
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}

/// Return a fresh allocator-owned copy of `src` with each `//`-to-EOL
/// comment replaced by spaces. Preserves byte offsets so any later
/// parser diagnostics still align with column numbers in the source.
pub fn stripLineComments(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, src);
    var i: usize = 0;
    while (i + 1 < out.len) : (i += 1) {
        if (out[i] == '/' and out[i + 1] == '/') {
            var j = i;
            while (j < out.len and out[j] != '\n') : (j += 1) out[j] = ' ';
            i = j;
        }
    }
    return out;
}
