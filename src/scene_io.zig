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
            var probe = i + key.len;
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
            // Not the entities key in object position — e.g. a string
            // value that happens to be `"entities"`. Keep scanning
            // past this token so a later real `"entities": [` is found.
            i += key.len;
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
/// where `key` isn't one of the names this gui models (`name`,
/// `entities`). Value text spans from the first non-whitespace byte
/// after `:` through to just before the trailing `,` or `}`.
fn extractTopLevelExtras(arena: std.mem.Allocator, raw: []const u8) ![]const TopLevelExtra {
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

        if (!isManagedTopLevelKey(key)) {
            try out.append(arena, .{
                .name = try arena.dupe(u8, key),
                .value_text = try arena.dupe(u8, std.mem.trim(u8, raw[value_start..value_end], " \t\r\n")),
            });
        }
    }
    return out.toOwnedSlice(arena);
}

/// Per-entity: scan each `{ ... }` in the entities array. Inside,
/// locate the `"components"` block, then capture every component
/// key+value pair that isn't `Position` (the only component the gui
/// models today).
fn extractEntityComponentExtras(arena: std.mem.Allocator, raw: []const u8) ![]const []const ComponentExtra {
    var out: std.ArrayList([]const ComponentExtra) = .{};
    errdefer out.deinit(arena);

    var i: usize = findEntitiesArray(raw) orelse return out.toOwnedSlice(arena);
    i += 1; // past '['

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

        if (!std.mem.eql(u8, key, "Position")) {
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
fn findKeyObject(body: []const u8, key: []const u8) ?usize {
    var i: usize = 0;
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
        const has_components = e.position != null or extras.len > 0;
        if (has_components) {
            if (!first) try w.writeAll(",");
            try w.writeAll(" \"components\": {");
            var c_first = true;
            if (e.position) |p| {
                try w.print(" \"Position\": {{ \"x\": {d}, \"y\": {d} }}", .{ p.x, p.y });
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
