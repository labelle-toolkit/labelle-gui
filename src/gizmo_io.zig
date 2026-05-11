//! Read/write loader for the Gizmo editor.
//!
//! `labelle-engine` gizmos live at `<project>/gizmos/<name>.zon`. They
//! declare a Shape (or set of children) that the engine attaches at
//! runtime to any entity whose components match `.match` and don't
//! match `.exclude`. Shape semantics are owned by
//! `../labelle-gfx/src/visuals.zig` — a tagged union of
//! `circle`/`rectangle`/`triangle`/`line`/`polygon`.
//!
//! v1 scope: model `.match` / `.exclude` as typed string lists so the
//! inspector can edit them, but capture `.entity` and `.children` as
//! verbatim ZON text. The Shape union isn't modeled structurally yet
//! (deliberately — competing geometry models are still in flight in
//! sibling PRs). Verbatim pass-through round-trips faithfully and
//! unblocks the editor without committing to a typed Shape today.
//!
//! Same pattern as `src/project.zig`'s `extractUnmodeledFields` for
//! `project.labelle` — pull out the bits we know how to render and
//! splice the rest back in unchanged.

const std = @import("std");

/// One parsed gizmo. `match` and `exclude` are typed string lists
/// owned by the surrounding `LoadedGizmo.arena`. `entity_verbatim` and
/// `children_verbatim` hold the raw ZON source text of those value
/// expressions (e.g. `.{ .Shape = .{ ... } }`) — the writer splices
/// them back into the saved file unchanged.
pub const Gizmo = struct {
    match: [][]const u8 = &.{},
    exclude: [][]const u8 = &.{},
    /// Verbatim ZON for the `.entity = <value>` right-hand side, with
    /// any leading/trailing whitespace trimmed. Null when the source
    /// had no `.entity` field.
    entity_verbatim: ?[]const u8 = null,
    /// Verbatim ZON for the `.children = <value>` right-hand side,
    /// same trim rule. Null when absent.
    children_verbatim: ?[]const u8 = null,
};

/// Loaded gizmo plus the arena that owns its memory. Caller frees via
/// `LoadedGizmo.deinit()`. Mirrors `scene_io.LoadedScene`'s ownership
/// pattern so the tab module can pair this with its own arena.
pub const LoadedGizmo = struct {
    arena: *std.heap.ArenaAllocator,
    gizmo: Gizmo,

    pub fn deinit(self: *LoadedGizmo) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !LoadedGizmo {
    const raw = try std.fs.cwd().readFileAlloc(allocator, path, 16 * 1024 * 1024);
    defer allocator.free(raw);
    return parseGizmo(allocator, raw);
}

/// Parse a gizmo's ZON source into a `LoadedGizmo`. Pulls `.match` /
/// `.exclude` through `std.zon.parse.fromSlice` (tolerant of unknown
/// fields so `.entity` / `.children` don't trip it up), then re-scans
/// the source byte-wise to capture the verbatim text of the
/// `.entity` and `.children` value expressions for round-tripping.
pub fn parseGizmo(allocator: std.mem.Allocator, raw: []const u8) !LoadedGizmo {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_alloc = arena.allocator();

    // `std.zon.parse.fromSlice` needs a sentinel-terminated slice for
    // its tokenizer — same as `project.zig`. Copy into the arena so
    // the parsed string slices borrow lifetime from us.
    const source = try arena_alloc.dupeZ(u8, raw);

    const Intermediate = struct {
        match: [][]const u8 = &.{},
        exclude: [][]const u8 = &.{},
    };

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena_alloc);
    const parsed = try std.zon.parse.fromSlice(Intermediate, arena_alloc, source, &diag, .{
        .ignore_unknown_fields = true,
    });

    const entity_verbatim = try extractFieldValueVerbatim(arena_alloc, raw, "entity");
    const children_verbatim = try extractFieldValueVerbatim(arena_alloc, raw, "children");

    return .{
        .arena = arena,
        .gizmo = .{
            .match = parsed.match,
            .exclude = parsed.exclude,
            .entity_verbatim = entity_verbatim,
            .children_verbatim = children_verbatim,
        },
    };
}

/// Render a `LoadedGizmo` back to ZON source. Field order is
/// canonical: `.match`, then `.exclude` (only when non-empty), then
/// `.entity` (only when present), then `.children` (only when
/// present). Mirrors `project.zig`'s `renderProjectLabelle` layout.
pub fn renderGizmoZon(allocator: std.mem.Allocator, loaded: LoadedGizmo) ![]u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    const w = out.writer(allocator);

    try w.writeAll(".{\n");

    // .match — always emitted (the engine requires it).
    try w.writeAll("    .match = .{");
    for (loaded.gizmo.match, 0..) |s, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("\"{s}\"", .{s});
    }
    try w.writeAll("},\n");

    if (loaded.gizmo.exclude.len > 0) {
        try w.writeAll("    .exclude = .{");
        for (loaded.gizmo.exclude, 0..) |s, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("\"{s}\"", .{s});
        }
        try w.writeAll("},\n");
    }

    if (loaded.gizmo.entity_verbatim) |text| {
        try w.print("    .entity = {s},\n", .{text});
    }

    if (loaded.gizmo.children_verbatim) |text| {
        try w.print("    .children = {s},\n", .{text});
    }

    try w.writeAll("}\n");
    return out.toOwnedSlice(allocator);
}

/// Write `loaded` back to disk at `path`. Truncates any existing file.
pub fn saveGizmo(allocator: std.mem.Allocator, path: []const u8, loaded: LoadedGizmo) !void {
    const text = try renderGizmoZon(allocator, loaded);
    defer allocator.free(text);
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(text);
}

/// Strip a trailing `.zon` extension from a path's basename and
/// return the stem (e.g. `"a/b/workstation.zon"` → `"workstation"`).
/// Used by the gizmo tab for its display label.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".zon";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}

// ─── Verbatim scanner ──────────────────────────────────────────────────
//
// Same dialect handling as `project.zig`'s top-level scanner: ZON with
// `// ... \n` comments, `"..."` strings with `\"` escapes, and brace /
// bracket / paren nesting in values. Multi-line strings (`\\...`) and
// `'...'` character literals aren't handled because the gizmo schema
// doesn't use them — extend if a future schema needs them.

/// Locate the top-level field named `field_name` and return the
/// verbatim source text of its value (trimmed of surrounding
/// whitespace). Returns null when the field is absent.
fn extractFieldValueVerbatim(
    arena: std.mem.Allocator,
    raw: []const u8,
    field_name: []const u8,
) !?[]const u8 {
    var i: usize = 0;
    skipWsAndComments(raw, &i);
    if (i + 1 >= raw.len or raw[i] != '.' or raw[i + 1] != '{') return null;
    i += 2;

    while (i < raw.len) {
        skipWsAndComments(raw, &i);
        if (i >= raw.len) break;
        if (raw[i] == '}') break;
        if (raw[i] == ',') {
            i += 1;
            continue;
        }
        if (raw[i] != '.') break; // unexpected; bail rather than mis-parse

        i += 1; // past '.'
        const name_start = i;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        }
        const name = raw[name_start..i];
        if (name.len == 0) break;

        skipWsAndComments(raw, &i);
        if (i >= raw.len or raw[i] != '=') break;
        i += 1; // past '='
        skipWsAndComments(raw, &i);

        const value_start = i;
        scanValue(raw, &i);
        const value_end = i;

        if (std.mem.eql(u8, name, field_name)) {
            const trimmed = std.mem.trim(u8, raw[value_start..value_end], " \t\r\n");
            return try arena.dupe(u8, trimmed);
        }

        // Optional trailing comma between fields.
        const save = i;
        skipWsAndComments(raw, &i);
        if (i < raw.len and raw[i] == ',') {
            i += 1;
        } else {
            i = save;
        }
    }
    return null;
}

fn skipWsAndComments(raw: []const u8, i: *usize) void {
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i.* += 1;
        } else if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        } else break;
    }
}

fn scanValue(raw: []const u8, i: *usize) void {
    var depth: usize = 0;
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c == '"') {
            i.* += 1;
            while (i.* < raw.len) {
                if (raw[i.*] == '\\' and i.* + 1 < raw.len) {
                    i.* += 2;
                } else if (raw[i.*] == '"') {
                    i.* += 1;
                    break;
                } else {
                    i.* += 1;
                }
            }
        } else if (c == '/' and i.* + 1 < raw.len and raw[i.* + 1] == '/') {
            while (i.* < raw.len and raw[i.*] != '\n') i.* += 1;
        } else if (c == '{' or c == '[' or c == '(') {
            depth += 1;
            i.* += 1;
        } else if (c == '}' or c == ']' or c == ')') {
            if (depth == 0) return; // outer `}` — stop without consuming
            depth -= 1;
            i.* += 1;
        } else if (c == ',' and depth == 0) {
            return;
        } else {
            i.* += 1;
        }
    }
}
