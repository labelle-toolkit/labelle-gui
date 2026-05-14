//! Read/write loader for the Flow editor (`.flow.zon` files).
//!
//! Flows are authored, hand-edited, on-disk files that describe a
//! graph of nodes wired together by pins. A later issue (#50) will
//! consume `Flow` and emit a Zig source file; for now this module is
//! the authoritative parser + writer that the editor speaks to.
//!
//! File schema (see issue #46) — canonical field order is
//! `.event`, `.nodes`, `.links`:
//!
//! ```zon
//! .{
//!     .event = .{ .OnUpdate = .{ .arg_dt = "dt" } },
//!     .nodes = .{
//!         .{ .id = 1, .pos = .{120, 80}, .kind = .{ .GetComponent = .{ .type = "Position" } } },
//!     },
//!     .links = .{
//!         .{ .from = .{ .node = 1, .pin = "x" }, .to = .{ .node = 2, .pin = "a" } },
//!     },
//! }
//! ```
//!
//! Ownership pattern mirrors `gizmo_io.LoadedGizmo`: a heap-allocated
//! arena owns every slice the `Flow` references, and the caller frees
//! both via `LoadedFlow.deinit()`.
//!
//! `NodeKind` is intentionally narrow in v1 — just enough variants
//! to cover the issue sketch plus the obvious primitives a forward
//! codegen pass needs (Identifier / Literal / Call). Growing the
//! union is deliberate follow-up work and lands in lockstep with
//! whatever consumer needs the new shape.

const std = @import("std");

/// Tagged event entry point for a flow. Each variant names the
/// runtime hook the generated function will be wired into and the
/// names the codegen step should use for hook arguments. Defaults
/// match the canonical Zig identifiers (`dt`, `entity`) so freshly
/// authored flows render compactly.
pub const Event = union(enum) {
    OnUpdate: struct { arg_dt: []const u8 = "dt" },
    OnCreate: struct { arg_entity: []const u8 = "entity" },
    OnDestroy: struct { arg_entity: []const u8 = "entity" },
};

/// Binary operator for `NodeKind.BinOp`. Extending this is a
/// follow-up: once the codegen pass lands (#50) we'll know which
/// operators the renderer actually emits and can grow the set.
pub const BinOpKind = enum { add, sub, mul, div };

/// On-disk position. `.{120, 80}` in ZON parses straight into a
/// two-element array literal, which `std.zon.parse` happily coerces
/// into `[2]f32`. Index 0 is x, index 1 is y. Keeping it as a raw
/// array (rather than a named struct) is the "tuple trick" the
/// schema doc calls out — it round-trips byte-equivalent to the
/// hand-authored form.
pub const Pos = [2]f32;

/// Kind discriminator for a flow node. The variant body holds the
/// per-kind payload; pins are described separately by `Link`s.
///
/// v1 coverage:
///   - GetComponent / SetField — read and write ECS state
///   - BinOp                  — arithmetic combinator
///   - Literal                — verbatim Zig expression text
///                              (typed literals are a later issue)
///   - Identifier             — bare name reference
///   - Call                   — invoke a function by name
///
/// Adding variants is intentional follow-up work; each one should
/// land with the editor UI that authors it and the codegen path
/// that consumes it.
pub const NodeKind = union(enum) {
    GetComponent: struct { type: []const u8 },
    SetField: struct { target: []const u8 },
    BinOp: struct { op: BinOpKind },
    Literal: struct { value: []const u8 },
    Identifier: struct { name: []const u8 },
    Call: struct { callee: []const u8 },
};

/// One node in a flow graph. `id` is the on-disk source of truth —
/// the editor picks the next unused `u32` (max + 1) when creating
/// nodes and the parser preserves whatever shows up. ID `0` is
/// reserved for "unassigned" and rejected by `parseFlow`.
pub const Node = struct {
    id: u32,
    pos: Pos,
    kind: NodeKind,
};

/// One end of a `Link`. References a node by `id` and names the pin
/// on that node as a string (pins aren't enumerated structurally —
/// each `NodeKind` documents its pin set in the renderer).
pub const PinRef = struct {
    node: u32,
    pin: []const u8,
};

/// A directed connection between two pins. Cycles are *not* checked
/// here — that's a concern for the codegen pass, which can produce
/// a better diagnostic with full context.
pub const Link = struct {
    from: PinRef,
    to: PinRef,
};

/// A fully parsed flow. Every slice is owned by the surrounding
/// `LoadedFlow.arena`.
pub const Flow = struct {
    event: Event,
    nodes: []Node,
    links: []Link,
};

/// Parsed flow plus the arena that owns its memory. Caller frees
/// via `LoadedFlow.deinit()`.
pub const LoadedFlow = struct {
    arena: *std.heap.ArenaAllocator,
    flow: Flow,

    pub fn deinit(self: *LoadedFlow) void {
        const child_alloc = self.arena.child_allocator;
        self.arena.deinit();
        child_alloc.destroy(self.arena);
    }
};

pub const ParseError = error{
    /// Two nodes share the same `id` value. IDs must be unique.
    DuplicateNodeId,
    /// A node has `id == 0`, which is reserved for "unassigned".
    InvalidNodeId,
    /// A link references a `from.node` or `to.node` that has no
    /// matching `Node.id` in the file.
    DanglingLink,
};

/// Read `path` as ZON and parse it into a `LoadedFlow`. 16 MiB cap
/// matches `gizmo_io` — these files are tiny.
pub fn loadFromFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !LoadedFlow {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    return parseFlow(allocator, raw);
}

/// Parse a flow's ZON source into a `LoadedFlow`. Tolerant of
/// unknown fields (`ignore_unknown_fields = true`) so future schema
/// additions don't break older clients. Validates ID uniqueness,
/// `id != 0`, and that every `Link.from.node` / `Link.to.node`
/// resolves to a real node — returns one of the typed `ParseError`
/// variants on failure so the editor can surface a useful message.
pub fn parseFlow(allocator: std.mem.Allocator, raw: []const u8) !LoadedFlow {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const arena_alloc = arena.allocator();

    // `std.zon.parse.fromSlice` needs a sentinel-terminated slice for
    // its tokenizer. Copy into the arena so the parsed string slices
    // borrow lifetime from us.
    const source = try arena_alloc.dupeZ(u8, raw);

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena_alloc);
    const parsed = try std.zon.parse.fromSliceAlloc(Flow, arena_alloc, source, &diag, .{
        .ignore_unknown_fields = true,
    });

    try validate(parsed);

    return .{
        .arena = arena,
        .flow = parsed,
    };
}

fn validate(flow: Flow) ParseError!void {
    // Unique-ID + non-zero-ID check. O(n^2) is fine — flows are
    // hand-authored and stay small. If that ever stops being true,
    // sort `nodes` by `id` and scan in linear time.
    for (flow.nodes, 0..) |n, i| {
        if (n.id == 0) return error.InvalidNodeId;
        for (flow.nodes[i + 1 ..]) |m| {
            if (m.id == n.id) return error.DuplicateNodeId;
        }
    }

    // Every link endpoint must resolve to an existing node.
    for (flow.links) |l| {
        if (!hasNode(flow.nodes, l.from.node)) return error.DanglingLink;
        if (!hasNode(flow.nodes, l.to.node)) return error.DanglingLink;
    }
}

fn hasNode(nodes: []const Node, id: u32) bool {
    for (nodes) |n| {
        if (n.id == id) return true;
    }
    return false;
}

/// Render a `LoadedFlow` back to ZON source. Canonical field order
/// is `.event`, `.nodes`, `.links`. Nodes are emitted sorted by
/// `id`; links are emitted sorted by `(from.node, from.pin, to.node,
/// to.pin)`. Sorting is the easy way to get deterministic output
/// from in-memory edits — the diff between a save and the previous
/// save reflects the user's change, not insertion order. String
/// values run through `std.zig.fmtString` so a `"` or `\` inside an
/// identifier round-trips as valid ZON.
pub fn renderFlowZon(allocator: std.mem.Allocator, loaded: LoadedFlow) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(".{\n");

    try w.writeAll("    .event = ");
    try writeEvent(w, loaded.flow.event);
    try w.writeAll(",\n");

    // Sort nodes by id for stable output. Use caller's allocator for
    // the scratch slices so the LoadedFlow's arena stays unmodified
    // across multiple render calls (mirrors renderGizmoZon's pattern).
    const sorted_nodes = try allocator.dupe(Node, loaded.flow.nodes);
    defer allocator.free(sorted_nodes);
    std.mem.sort(Node, sorted_nodes, {}, lessThanNode);

    try w.writeAll("    .nodes = .{\n");
    for (sorted_nodes) |n| {
        try w.print("        .{{ .id = {d}, .pos = .{{{d}, {d}}}, .kind = ", .{ n.id, n.pos[0], n.pos[1] });
        try writeNodeKind(w, n.kind);
        try w.writeAll(" },\n");
    }
    try w.writeAll("    },\n");

    const sorted_links = try allocator.dupe(Link, loaded.flow.links);
    defer allocator.free(sorted_links);
    std.mem.sort(Link, sorted_links, {}, lessThanLink);

    try w.writeAll("    .links = .{\n");
    for (sorted_links) |l| {
        try w.print(
            "        .{{ .from = .{{ .node = {d}, .pin = \"{f}\" }}, .to = .{{ .node = {d}, .pin = \"{f}\" }} }},\n",
            .{
                l.from.node,
                std.zig.fmtString(l.from.pin),
                l.to.node,
                std.zig.fmtString(l.to.pin),
            },
        );
    }
    try w.writeAll("    },\n");

    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

fn lessThanNode(_: void, a: Node, b: Node) bool {
    return a.id < b.id;
}

fn lessThanLink(_: void, a: Link, b: Link) bool {
    if (a.from.node != b.from.node) return a.from.node < b.from.node;
    const fp = std.mem.order(u8, a.from.pin, b.from.pin);
    if (fp != .eq) return fp == .lt;
    if (a.to.node != b.to.node) return a.to.node < b.to.node;
    return std.mem.order(u8, a.to.pin, b.to.pin) == .lt;
}

fn writeEvent(w: anytype, ev: Event) !void {
    switch (ev) {
        .OnUpdate => |body| try w.print(
            ".{{ .OnUpdate = .{{ .arg_dt = \"{f}\" }} }}",
            .{std.zig.fmtString(body.arg_dt)},
        ),
        .OnCreate => |body| try w.print(
            ".{{ .OnCreate = .{{ .arg_entity = \"{f}\" }} }}",
            .{std.zig.fmtString(body.arg_entity)},
        ),
        .OnDestroy => |body| try w.print(
            ".{{ .OnDestroy = .{{ .arg_entity = \"{f}\" }} }}",
            .{std.zig.fmtString(body.arg_entity)},
        ),
    }
}

fn writeNodeKind(w: anytype, k: NodeKind) !void {
    switch (k) {
        .GetComponent => |b| try w.print(
            ".{{ .GetComponent = .{{ .type = \"{f}\" }} }}",
            .{std.zig.fmtString(b.type)},
        ),
        .SetField => |b| try w.print(
            ".{{ .SetField = .{{ .target = \"{f}\" }} }}",
            .{std.zig.fmtString(b.target)},
        ),
        .BinOp => |b| try w.print(
            ".{{ .BinOp = .{{ .op = .{s} }} }}",
            .{@tagName(b.op)},
        ),
        .Literal => |b| try w.print(
            ".{{ .Literal = .{{ .value = \"{f}\" }} }}",
            .{std.zig.fmtString(b.value)},
        ),
        .Identifier => |b| try w.print(
            ".{{ .Identifier = .{{ .name = \"{f}\" }} }}",
            .{std.zig.fmtString(b.name)},
        ),
        .Call => |b| try w.print(
            ".{{ .Call = .{{ .callee = \"{f}\" }} }}",
            .{std.zig.fmtString(b.callee)},
        ),
    }
}

/// Persist `loaded` to disk at `path`. Truncates any existing file.
pub fn saveFlow(io: std.Io, allocator: std.mem.Allocator, path: []const u8, loaded: LoadedFlow) !void {
    const text = try renderFlowZon(allocator, loaded);
    defer allocator.free(text);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
}

/// Strip the trailing `.flow.zon` double extension from a path's
/// basename and return the stem. e.g.
/// `"scripts/flows/move.flow.zon"` → `"move"`. Falls back to the
/// raw basename when the suffix isn't present so the editor still
/// has something to show.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".flow.zon";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return base;
}
