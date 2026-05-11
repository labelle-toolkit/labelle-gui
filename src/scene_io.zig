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

/// Maximum bytes (excluding the sentinel) for the per-entity comment
/// editor. 1 KiB fits the typical 1–3 short lines we see in real
/// scenes with room to grow.
pub const comment_cap = 1024;

pub const Entity = struct {
    prefab: ?[]const u8 = null,
    /// Parsed once on load; viewport reads it when drawing the entity
    /// marker. Components that aren't known to this struct are ignored,
    /// which lets the gui open scenes that reference component types
    /// we don't model yet (Sprite, Shape, user-defined components).
    position: ?Position = null,
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
        };
        // Comments are extracted on a best-effort basis: if the scanner
        // landed fewer entries than parser saw entities (recovery from
        // a malformed scene mid-stream), the remaining entries simply
        // get empty comment buffers.
        if (i < comments.len) copyToCommentBuf(&entities[i].comment, comments[i]);
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
    var out: std.ArrayList([]const u8) = .{};
    errdefer out.deinit(arena);

    var i: usize = findEntitiesArray(raw) orelse return out.toOwnedSlice(arena);
    i += 1; // past '['

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
        if (raw[i] != '{') break; // unexpected — bail gracefully

        const trimmed = std.mem.trim(u8, raw[comment_start..comment_end], " \t\r\n");
        try out.append(arena, try arena.dupe(u8, trimmed));

        scanBalanced(raw, &i, '{', '}');
    }
    return out.toOwnedSlice(arena);
}

fn findEntitiesArray(raw: []const u8) ?usize {
    const key = "\"entities\"";
    var i: usize = 0;
    while (i + key.len <= raw.len) {
        // Match the key as-a-string first so a literal `"entities"` —
        // which IS a `"`-prefixed token — isn't eaten by the
        // string-skip branch below. For any other string we encounter
        // (e.g. `"name"`, a string *value*), skipString advances past
        // it so its contents don't false-match.
        if (std.mem.eql(u8, raw[i .. i + key.len], key)) {
            i += key.len;
            skipWhitespaceJson(raw, &i);
            skipCommentBlock(raw, &i);
            skipWhitespaceJson(raw, &i);
            if (i < raw.len and raw[i] == ':') {
                i += 1;
                skipWhitespaceJson(raw, &i);
                skipCommentBlock(raw, &i);
                skipWhitespaceJson(raw, &i);
                if (i < raw.len and raw[i] == '[') return i;
            }
            return null;
        }
        if (raw[i] == '"') {
            skipString(raw, &i);
            continue;
        }
        i += 1;
    }
    return null;
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

fn copyToCommentBuf(buf: []u8, src: []const u8) void {
    @memset(buf, 0);
    const n = @min(buf.len, src.len);
    @memcpy(buf[0..n], src[0..n]);
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
