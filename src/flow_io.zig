//! Read/write loader for `.flow.jsonc` flow graphs (RFC: Flows as
//! `.flow.jsonc`, issue #153).
//!
//! Flow graphs are *editor-authored content* — a flat `nodes` + `edges`
//! graph, parsed at build time by flow-codegen into Zig and never read
//! by the shipped game. The on-disk schema (RFC §2/§3):
//!
//! ```jsonc
//! {
//!   "name": "enemy_tick",              // optional registry key
//!   "event": { "type": "OnCreate", "arg_entity": "entity" },
//!   "params": [                        // optional subgraph interface
//!     { "name": "damage", "type": "f32", "default": 10.0 }
//!   ],
//!   "nodes": [
//!     { "id": 1, "type": "GetComponent", "pos": [0,0], "component": "Position" }
//!   ],
//!   "edges": [
//!     { "from": { "node": 1, "pin": "x" }, "to": { "node": 3, "pin": "a" } }
//!   ]
//! }
//! ```
//!
//! This module owns three things the editor needs:
//!
//!  1. **A typed model** (`FlowDoc`) of the schema — `name`, `event`,
//!     `params`, `nodes`, `edges`. Node types the editor understands
//!     structurally are `Subflow`, `Param`, and `Output` (RFC §3); every
//!     other node `type` rides along with its unknown keys captured
//!     verbatim so an editor save never drops data flow-codegen needs.
//!  2. **A JSONC reader** — strips `//` line comments (the engine's
//!     scenes/prefabs do the same) then parses with `std.json`.
//!  3. **A deterministic writer** — stable key order, fixed two-space
//!     indent. The same file re-saved byte-for-byte produces the same
//!     bytes, so editor round-trips keep diffs minimal (RFC open
//!     question §3, "editor round-trip").
//!
//! Determinism rule: every object's keys are emitted in a fixed order
//! (defined per struct below), node `extras` keys are emitted sorted,
//! and numbers are formatted canonically (integers without a decimal
//! point, floats with the minimal representation `std.fmt` gives). A
//! file authored by hand with a different key order will normalise to
//! the canonical order on its first editor save — a one-time diff,
//! stable thereafter.

const std = @import("std");
const io_global = @import("io_global.zig");
const scene_io = @import("scene_io.zig");

/// Maximum file size we will read. Flow graphs are tiny hand-authored
/// documents; 4 MiB is far above anything realistic and guards against
/// a pathological file.
const max_flow_bytes: usize = 4 * 1024 * 1024;

/// File extension that marks a flow graph. Used by the project tree
/// router and the tab display-name helper.
pub const extension = ".flow.jsonc";

// ─── Typed model ───────────────────────────────────────────────────────

/// A node's structurally-understood `type`. `other` covers every node
/// `type` the editor doesn't model (BinOp, GetComponent, Literal, …) —
/// those still round-trip via `Node.extras`, the editor just can't add
/// or edit their type-specific fields beyond raw key/value.
pub const NodeKind = enum {
    /// References another flow by name and binds its `params` (RFC §3).
    subflow,
    /// Reads a declared subgraph parameter, exposing it as a pin output.
    param,
    /// Names one of the subgraph's result pins.
    output,
    /// Any other node type — kind preserved as a string in `type_name`.
    other,

    pub fn fromTypeName(name: []const u8) NodeKind {
        if (std.mem.eql(u8, name, "Subflow")) return .subflow;
        if (std.mem.eql(u8, name, "Param")) return .param;
        if (std.mem.eql(u8, name, "Output")) return .output;
        return .other;
    }

    /// Canonical `type` string for a structurally-understood kind.
    /// `.other` has no canonical name — callers use `Node.type_name`.
    pub fn typeName(self: NodeKind) ?[]const u8 {
        return switch (self) {
            .subflow => "Subflow",
            .param => "Param",
            .output => "Output",
            .other => null,
        };
    }
};

/// One literal binding on a `Subflow` node — a parameter *name* paired
/// with a JSON-native literal (RFC §3, `bindings`). Stored as the
/// verbatim JSON text of the value so any literal type round-trips
/// without the editor needing to model it.
pub const Binding = struct {
    name: []const u8,
    /// Canonical JSON text of the bound value (e.g. `25`, `10.5`,
    /// `"hello"`, `true`). Produced by `jsonValueToText`.
    value_text: []const u8,
};

/// One declared subgraph parameter (RFC §3, top-level `params`). Its
/// `name` becomes an input pin on every `Subflow` node referencing the
/// flow; `type` is a Zig type name; `default` is an optional
/// JSON-native literal used when a param pin is neither wired nor bound.
pub const Param = struct {
    name: []const u8,
    /// Zig type name, e.g. `"f32"`, `"i32"`, `"bool"`.
    type_name: []const u8,
    /// Canonical JSON text of the default value, or null when the
    /// parameter has no default (then it must be wired or bound).
    default_text: ?[]const u8 = null,
};

/// One node in the flat graph. Fields the editor models structurally
/// live in typed fields; everything else (a node `type`'s own keys, or
/// keys on a modeled node we don't recognise) is captured in `extras`
/// so a save round-trips.
pub const Node = struct {
    id: u32,
    /// The raw `type` string from the file. Always set, even for
    /// structurally-modeled kinds (it equals `kind.typeName()` then).
    type_name: []const u8,
    kind: NodeKind,
    /// Editor canvas position. Defaults to the origin when the file
    /// omits `pos` (a fresh hand-authored node).
    pos: [2]f32 = .{ 0, 0 },

    // ── Subflow-specific ──
    /// The referenced flow's effective name. Empty for non-Subflow.
    flow_ref: []const u8 = "",
    /// Literal param bindings (RFC §3). Empty for non-Subflow.
    bindings: []Binding = &.{},

    // ── Param-specific ──
    /// The declared parameter this node reads. Empty for non-Param.
    param_ref: []const u8 = "",

    // ── Output-specific ──
    /// The result-pin name this node names. Empty for non-Output.
    output_name: []const u8 = "",

    /// Verbatim key/value pairs not modeled above. Keys are emitted in
    /// sorted order so the writer is deterministic. Values are canonical
    /// JSON text.
    extras: []KeyValue = &.{},
};

/// A captured-verbatim object entry — a key plus the canonical JSON
/// text of its value.
pub const KeyValue = struct {
    key: []const u8,
    value_text: []const u8,
};

/// One graph edge — same `{node, pin}` shape on both ends as `.flow.zon`
/// used (RFC §2, `links` → `edges` is a rename only).
pub const Edge = struct {
    from_node: u32,
    from_pin: []const u8,
    to_node: u32,
    to_pin: []const u8,
};

/// The flow's entry point. `type` is a lifecycle event name (e.g.
/// `OnCreate`) or `OnCall` for a subgraph (RFC §3). `arg_entity` and any
/// other event keys are captured in `extras` so they round-trip.
pub const Event = struct {
    type_name: []const u8 = "OnCreate",
    extras: []KeyValue = &.{},
};

/// A fully parsed flow graph plus the arena that owns every slice and
/// string it points at. Caller frees via `deinit`.
pub const FlowDoc = struct {
    arena: *std.heap.ArenaAllocator,
    /// Optional top-level `name` (registry key). Null → effective name
    /// is the filename basename (RFC §5).
    name: ?[]const u8 = null,
    event: Event = .{},
    params: []Param = &.{},
    nodes: []Node = &.{},
    edges: []Edge = &.{},
    /// Highest node id seen — the editor allocates fresh ids above this.
    max_node_id: u32 = 0,

    pub fn deinit(self: *FlowDoc) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    pub fn allocator(self: *FlowDoc) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Allocate a fresh node id one above the current maximum. Bumps
    /// `max_node_id` so successive calls don't collide.
    pub fn nextNodeId(self: *FlowDoc) u32 {
        self.max_node_id += 1;
        return self.max_node_id;
    }
};

// ─── Reader ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    NotAnObject,
    MissingNodeId,
    DuplicateNodeId,
    BadNodeType,
    BadEdge,
} || std.json.ParseError(std.json.Scanner) || std.mem.Allocator.Error;

/// Read and parse a `.flow.jsonc` file from disk.
pub fn loadFromFile(child_allocator: std.mem.Allocator, path: []const u8) !FlowDoc {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        io_global.io(),
        path,
        child_allocator,
        .limited(max_flow_bytes),
    );
    defer child_allocator.free(raw);
    return parse(child_allocator, raw);
}

/// Parse JSONC `raw` into a `FlowDoc`. The returned doc owns an arena;
/// `raw` is not borrowed past this call.
pub fn parse(child_allocator: std.mem.Allocator, raw: []const u8) !FlowDoc {
    const arena = try child_allocator.create(std.heap.ArenaAllocator);
    errdefer child_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    // `std.json` rejects comments — strip `//`-to-EOL first, the same
    // pre-pass `scene_io` runs for scenes and prefabs.
    const stripped = try scene_io.stripLineComments(a, raw);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, stripped, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return ParseError.NotAnObject;
    const root = parsed.value.object;

    var doc: FlowDoc = .{ .arena = arena };

    // ── name ──
    if (root.get("name")) |v| {
        if (v == .string) doc.name = try a.dupe(u8, v.string);
    }

    // ── event ──
    if (root.get("event")) |v| {
        if (v == .object) doc.event = try parseEvent(a, v.object);
    }

    // ── params ──
    if (root.get("params")) |v| {
        if (v == .array) doc.params = try parseParams(a, v.array);
    }

    // ── nodes ──
    if (root.get("nodes")) |v| {
        if (v == .array) {
            const r = try parseNodes(a, v.array);
            doc.nodes = r.nodes;
            doc.max_node_id = r.max_id;
        }
    }

    // ── edges ──
    if (root.get("edges")) |v| {
        if (v == .array) doc.edges = try parseEdges(a, v.array);
    }

    return doc;
}

fn parseEvent(a: std.mem.Allocator, obj: std.json.ObjectMap) !Event {
    var ev: Event = .{};
    var extras: std.ArrayList(KeyValue) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            if (entry.value_ptr.* == .string) {
                ev.type_name = try a.dupe(u8, entry.value_ptr.string);
            }
            continue;
        }
        try extras.append(a, .{
            .key = try a.dupe(u8, key),
            .value_text = try jsonValueToText(a, entry.value_ptr.*),
        });
    }
    sortKeyValues(extras.items);
    ev.extras = try extras.toOwnedSlice(a);
    return ev;
}

fn parseParams(a: std.mem.Allocator, arr: std.json.Array) ![]Param {
    var out: std.ArrayList(Param) = .empty;
    for (arr.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const name = if (o.get("name")) |n| (if (n == .string) n.string else "") else "";
        const type_name = if (o.get("type")) |t| (if (t == .string) t.string else "f32") else "f32";
        var p: Param = .{
            .name = try a.dupe(u8, name),
            .type_name = try a.dupe(u8, type_name),
        };
        if (o.get("default")) |d| {
            p.default_text = try jsonValueToText(a, d);
        }
        try out.append(a, p);
    }
    return out.toOwnedSlice(a);
}

const NodesResult = struct { nodes: []Node, max_id: u32 };

fn parseNodes(a: std.mem.Allocator, arr: std.json.Array) !NodesResult {
    var out: std.ArrayList(Node) = .empty;
    var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
    var max_id: u32 = 0;

    for (arr.items) |item| {
        if (item != .object) return ParseError.BadNodeType;
        const o = item.object;

        const id_v = o.get("id") orelse return ParseError.MissingNodeId;
        const id: u32 = switch (id_v) {
            .integer => |n| std.math.cast(u32, n) orelse return ParseError.MissingNodeId,
            else => return ParseError.MissingNodeId,
        };
        if (seen.contains(id)) return ParseError.DuplicateNodeId;
        try seen.put(a, id, {});
        if (id > max_id) max_id = id;

        const type_v = o.get("type") orelse return ParseError.BadNodeType;
        if (type_v != .string) return ParseError.BadNodeType;
        const type_name = try a.dupe(u8, type_v.string);
        const kind = NodeKind.fromTypeName(type_name);

        var node: Node = .{ .id = id, .type_name = type_name, .kind = kind };

        // pos
        if (o.get("pos")) |pv| {
            if (pv == .array and pv.array.items.len >= 2) {
                node.pos = .{
                    jsonNumberAsF32(pv.array.items[0]) orelse 0,
                    jsonNumberAsF32(pv.array.items[1]) orelse 0,
                };
            }
        }

        // Per-kind structural fields. Keys consumed here are *not*
        // pushed into extras.
        var extras: std.ArrayList(KeyValue) = .empty;
        var it = o.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "id") or
                std.mem.eql(u8, key, "type") or
                std.mem.eql(u8, key, "pos")) continue;

            if (kind == .subflow and std.mem.eql(u8, key, "flow")) {
                if (entry.value_ptr.* == .string) {
                    node.flow_ref = try a.dupe(u8, entry.value_ptr.string);
                }
                continue;
            }
            if (kind == .subflow and std.mem.eql(u8, key, "bindings")) {
                if (entry.value_ptr.* == .object) {
                    node.bindings = try parseBindings(a, entry.value_ptr.object);
                }
                continue;
            }
            if (kind == .param and std.mem.eql(u8, key, "param")) {
                if (entry.value_ptr.* == .string) {
                    node.param_ref = try a.dupe(u8, entry.value_ptr.string);
                }
                continue;
            }
            if (kind == .output and std.mem.eql(u8, key, "name")) {
                if (entry.value_ptr.* == .string) {
                    node.output_name = try a.dupe(u8, entry.value_ptr.string);
                }
                continue;
            }

            try extras.append(a, .{
                .key = try a.dupe(u8, key),
                .value_text = try jsonValueToText(a, entry.value_ptr.*),
            });
        }
        sortKeyValues(extras.items);
        node.extras = try extras.toOwnedSlice(a);

        try out.append(a, node);
    }

    return .{ .nodes = try out.toOwnedSlice(a), .max_id = max_id };
}

fn parseBindings(a: std.mem.Allocator, obj: std.json.ObjectMap) ![]Binding {
    var out: std.ArrayList(Binding) = .empty;
    var it = obj.iterator();
    while (it.next()) |entry| {
        try out.append(a, .{
            .name = try a.dupe(u8, entry.key_ptr.*),
            .value_text = try jsonValueToText(a, entry.value_ptr.*),
        });
    }
    // Sort by name for a stable writer order.
    std.mem.sort(Binding, out.items, {}, struct {
        fn lt(_: void, x: Binding, y: Binding) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    return out.toOwnedSlice(a);
}

fn parseEdges(a: std.mem.Allocator, arr: std.json.Array) ![]Edge {
    var out: std.ArrayList(Edge) = .empty;
    for (arr.items) |item| {
        if (item != .object) return ParseError.BadEdge;
        const o = item.object;
        const from = o.get("from") orelse return ParseError.BadEdge;
        const to = o.get("to") orelse return ParseError.BadEdge;
        if (from != .object or to != .object) return ParseError.BadEdge;
        const fe = try parseEndpoint(a, from.object);
        const te = try parseEndpoint(a, to.object);
        try out.append(a, .{
            .from_node = fe.node,
            .from_pin = fe.pin,
            .to_node = te.node,
            .to_pin = te.pin,
        });
    }
    return out.toOwnedSlice(a);
}

const Endpoint = struct { node: u32, pin: []const u8 };

fn parseEndpoint(a: std.mem.Allocator, obj: std.json.ObjectMap) !Endpoint {
    const node_v = obj.get("node") orelse return ParseError.BadEdge;
    const node: u32 = switch (node_v) {
        .integer => |n| std.math.cast(u32, n) orelse return ParseError.BadEdge,
        else => return ParseError.BadEdge,
    };
    const pin_v = obj.get("pin") orelse return ParseError.BadEdge;
    if (pin_v != .string) return ParseError.BadEdge;
    return .{ .node = node, .pin = try a.dupe(u8, pin_v.string) };
}

fn jsonNumberAsF32(v: std.json.Value) ?f32 {
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| @floatCast(f),
        else => null,
    };
}

// ─── Canonical JSON value text ─────────────────────────────────────────

/// Render a `std.json.Value` to canonical JSON text — the form the
/// writer splices verbatim. Determinism rules:
///   - object keys sorted ascending,
///   - integers without a fractional part,
///   - floats via `std.fmt`'s shortest round-trippable form,
///   - strings escaped per JSON,
///   - no insignificant whitespace inside the value (compact form).
pub fn jsonValueToText(a: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try writeJsonValue(a, &out, v);
    return out.toOwnedSlice(a);
}

fn writeJsonValue(a: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) !void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| try out.print(a, "{d}", .{n}),
        .float => |f| try out.print(a, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(a, s),
        .string => |s| try writeJsonString(a, out, s),
        .array => |arr| {
            try out.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try writeJsonValue(a, out, item);
            }
            try out.append(a, ']');
        },
        .object => |obj| {
            // Sort keys for determinism.
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(a);
            var it = obj.iterator();
            while (it.next()) |e| try keys.append(a, e.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn lt(_: void, x: []const u8, y: []const u8) bool {
                    return std.mem.lessThan(u8, x, y);
                }
            }.lt);
            try out.append(a, '{');
            for (keys.items, 0..) |k, i| {
                if (i > 0) try out.append(a, ',');
                try writeJsonString(a, out, k);
                try out.append(a, ':');
                try writeJsonValue(a, out, obj.get(k).?);
            }
            try out.append(a, '}');
        },
    }
}

fn writeJsonString(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            0x08 => try out.appendSlice(a, "\\b"),
            0x0C => try out.appendSlice(a, "\\f"),
            else => {
                if (c < 0x20) {
                    try out.print(a, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(a, c);
                }
            },
        }
    }
    try out.append(a, '"');
}

fn sortKeyValues(items: []KeyValue) void {
    std.mem.sort(KeyValue, items, {}, struct {
        fn lt(_: void, x: KeyValue, y: KeyValue) bool {
            return std.mem.lessThan(u8, x.key, y.key);
        }
    }.lt);
}

// ─── Writer ─────────────────────────────────────────────────────────────

const indent_unit = "  ";

/// Render `doc` back to deterministic `.flow.jsonc` text. Key order is
/// fixed: top-level is `name`, `event`, `params`, `nodes`, `edges`; each
/// node is `id`, `type`, `pos`, then kind fields, then sorted `extras`.
/// Re-rendering the output of `parse` is idempotent.
pub fn render(child_allocator: std.mem.Allocator, doc: FlowDoc) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(child_allocator);
    const a = child_allocator;

    try out.appendSlice(a, "{\n");

    // name (optional)
    if (doc.name) |name| {
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"name\": ");
        try writeJsonString(a, &out, name);
        try out.appendSlice(a, ",\n");
    }

    // event
    try out.appendSlice(a, indent_unit);
    try out.appendSlice(a, "\"event\": { \"type\": ");
    try writeJsonString(a, &out, doc.event.type_name);
    for (doc.event.extras) |kv| {
        try out.appendSlice(a, ", ");
        try writeJsonString(a, &out, kv.key);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, kv.value_text);
    }
    try out.appendSlice(a, " },\n");

    // params (optional — omitted entirely when empty)
    if (doc.params.len > 0) {
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"params\": [\n");
        for (doc.params, 0..) |p, i| {
            try out.appendSlice(a, indent_unit ** 2);
            try out.appendSlice(a, "{ \"name\": ");
            try writeJsonString(a, &out, p.name);
            try out.appendSlice(a, ", \"type\": ");
            try writeJsonString(a, &out, p.type_name);
            if (p.default_text) |d| {
                try out.appendSlice(a, ", \"default\": ");
                try out.appendSlice(a, d);
            }
            try out.appendSlice(a, " }");
            if (i + 1 < doc.params.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "],\n");
    }

    // nodes
    try out.appendSlice(a, indent_unit);
    try out.appendSlice(a, "\"nodes\": [");
    if (doc.nodes.len == 0) {
        try out.appendSlice(a, "],\n");
    } else {
        try out.append(a, '\n');
        for (doc.nodes, 0..) |n, i| {
            try renderNode(a, &out, n);
            if (i + 1 < doc.nodes.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "],\n");
    }

    // edges
    try out.appendSlice(a, indent_unit);
    try out.appendSlice(a, "\"edges\": [");
    if (doc.edges.len == 0) {
        try out.appendSlice(a, "]\n");
    } else {
        try out.append(a, '\n');
        for (doc.edges, 0..) |e, i| {
            try out.appendSlice(a, indent_unit ** 2);
            try out.print(a, "{{ \"from\": {{ \"node\": {d}, \"pin\": ", .{e.from_node});
            try writeJsonString(a, &out, e.from_pin);
            try out.print(a, " }}, \"to\": {{ \"node\": {d}, \"pin\": ", .{e.to_node});
            try writeJsonString(a, &out, e.to_pin);
            try out.appendSlice(a, " } }");
            if (i + 1 < doc.edges.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "]\n");
    }

    try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

fn renderNode(a: std.mem.Allocator, out: *std.ArrayList(u8), n: Node) !void {
    try out.appendSlice(a, indent_unit ** 2);
    try out.print(a, "{{ \"id\": {d}, \"type\": ", .{n.id});
    try writeJsonString(a, out, n.type_name);

    // pos — always emitted so a fresh node's origin is explicit.
    try out.appendSlice(a, ", \"pos\": [");
    try writeCoord(a, out, n.pos[0]);
    try out.appendSlice(a, ", ");
    try writeCoord(a, out, n.pos[1]);
    try out.append(a, ']');

    switch (n.kind) {
        .subflow => {
            try out.appendSlice(a, ", \"flow\": ");
            try writeJsonString(a, out, n.flow_ref);
            if (n.bindings.len > 0) {
                try out.appendSlice(a, ", \"bindings\": { ");
                for (n.bindings, 0..) |b, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try writeJsonString(a, out, b.name);
                    try out.appendSlice(a, ": ");
                    try out.appendSlice(a, b.value_text);
                }
                try out.appendSlice(a, " }");
            }
        },
        .param => {
            try out.appendSlice(a, ", \"param\": ");
            try writeJsonString(a, out, n.param_ref);
        },
        .output => {
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, out, n.output_name);
        },
        .other => {},
    }

    for (n.extras) |kv| {
        try out.appendSlice(a, ", ");
        try writeJsonString(a, out, kv.key);
        try out.appendSlice(a, ": ");
        try out.appendSlice(a, kv.value_text);
    }

    try out.appendSlice(a, " }");
}

/// Write a canvas coordinate: integral values lose the `.0` so a
/// hand-authored `[0, 0]` round-trips unchanged.
fn writeCoord(a: std.mem.Allocator, out: *std.ArrayList(u8), v: f32) !void {
    const rounded = @round(v);
    if (rounded == v and @abs(v) < 1e9) {
        try out.print(a, "{d}", .{@as(i64, @intFromFloat(rounded))});
    } else {
        try out.print(a, "{d}", .{v});
    }
}

/// Write `doc` back to disk at `path`, truncating any existing file.
pub fn saveToFile(child_allocator: std.mem.Allocator, path: []const u8, doc: FlowDoc) !void {
    const text = try render(child_allocator, doc);
    defer child_allocator.free(text);
    try std.Io.Dir.cwd().writeFile(io_global.io(), .{
        .sub_path = path,
        .data = text,
    });
}

// ─── Path helpers ──────────────────────────────────────────────────────

/// `foo.flow.jsonc` → `foo`. Falls back to the plain basename when the
/// extension doesn't match.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.endsWith(u8, base, extension)) {
        return base[0 .. base.len - extension.len];
    }
    return base;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "parse flat schema" {
    const src =
        \\{
        \\  // a comment
        \\  "name": "enemy_tick",
        \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
        \\  "nodes": [
        \\    { "id": 1, "type": "GetComponent", "pos": [0, 0], "component": "Position" },
        \\    { "id": 3, "type": "BinOp", "op": "add", "pos": [10, 20] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 1, "pin": "x" }, "to": { "node": 3, "pin": "a" } }
        \\  ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqualStrings("enemy_tick", doc.name.?);
    try std.testing.expectEqualStrings("OnCreate", doc.event.type_name);
    try std.testing.expectEqual(@as(usize, 2), doc.nodes.len);
    try std.testing.expectEqual(@as(u32, 3), doc.max_node_id);
    try std.testing.expectEqual(@as(usize, 1), doc.edges.len);
    try std.testing.expectEqualStrings("BinOp", doc.nodes[1].type_name);
    try std.testing.expectEqual(NodeKind.other, doc.nodes[1].kind);
    try std.testing.expectEqual(@as(f32, 10), doc.nodes[1].pos[0]);
}

test "parse subflow / param / output" {
    const src =
        \\{
        \\  "name": "combat_subgraph",
        \\  "event": { "type": "OnCall" },
        \\  "params": [ { "name": "damage", "type": "f32", "default": 10.0 } ],
        \\  "nodes": [
        \\    { "id": 2, "type": "Param", "param": "damage", "pos": [0, 0] },
        \\    { "id": 9, "type": "Output", "name": "dealt", "pos": [0, 0] },
        \\    { "id": 7, "type": "Subflow", "flow": "combat_subgraph", "bindings": { "damage": 25.0 }, "pos": [240, 60] }
        \\  ],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.params.len);
    try std.testing.expectEqualStrings("damage", doc.params[0].name);
    try std.testing.expectEqualStrings("f32", doc.params[0].type_name);
    try std.testing.expect(doc.params[0].default_text != null);

    try std.testing.expectEqual(NodeKind.param, doc.nodes[0].kind);
    try std.testing.expectEqualStrings("damage", doc.nodes[0].param_ref);

    try std.testing.expectEqual(NodeKind.output, doc.nodes[1].kind);
    try std.testing.expectEqualStrings("dealt", doc.nodes[1].output_name);

    try std.testing.expectEqual(NodeKind.subflow, doc.nodes[2].kind);
    try std.testing.expectEqualStrings("combat_subgraph", doc.nodes[2].flow_ref);
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[2].bindings.len);
    try std.testing.expectEqualStrings("damage", doc.nodes[2].bindings[0].name);
}

test "render is deterministic and idempotent" {
    const src =
        \\{
        \\  "name": "x",
        \\  "event": { "type": "OnCreate", "arg_entity": "entity" },
        \\  "params": [ { "name": "p", "type": "i32", "default": 3 } ],
        \\  "nodes": [
        \\    { "id": 1, "type": "Param", "param": "p", "pos": [0, 0] },
        \\    { "id": 2, "type": "BinOp", "op": "add", "pos": [5, 7] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 2, "pin": "a" } }
        \\  ]
        \\}
    ;
    var doc1 = try parse(std.testing.allocator, src);
    defer doc1.deinit();
    const text1 = try render(std.testing.allocator, doc1);
    defer std.testing.allocator.free(text1);

    // Re-parse the rendered text and re-render — must be byte-identical.
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2);
}

test "empty graph round-trips" {
    const src =
        \\{ "event": { "type": "OnCall" }, "nodes": [], "edges": [] }
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);

    var doc2 = try parse(std.testing.allocator, text);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "displayNameFromPath strips extension" {
    try std.testing.expectEqualStrings("enemy_tick", displayNameFromPath("a/b/enemy_tick.flow.jsonc"));
    try std.testing.expectEqualStrings("other.zig", displayNameFromPath("x/other.zig"));
}
