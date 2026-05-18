//! Forward codegen for the Flow editor (`.flow.zon` → Zig source).
//!
//! `renderFlowZig` turns a parsed `flow_io.Flow` into a complete `.zig`
//! file: imports + one `pub fn` matching the flow's `Event`. The
//! assembler (separate, follow-up issue) calls this at
//! `zig build generate` time and writes the result under
//! `zig-out/.../flows/<name>.zig`.
//!
//! ## Pipeline
//!
//! 1. Index nodes by id and build the consumer→producer pin map from
//!    the link list.
//! 2. Topologically sort the nodes (Kahn's algorithm) so a node's
//!    inputs are always defined before the node itself emits.
//! 3. For each node, in topo order:
//!    - emit the preview pulse preamble (folded from #90 — see below);
//!    - emit the node's Zig template with input pins resolved to
//!      either the producing node's variable, or a per-kind default.
//!
//! ## Preview pulse (folded from former issue #90)
//!
//! Each emitted node body is preceded by:
//!
//! ```zig
//! if (game.preview) |*_p| {
//!     _p.emitNodeEntered("<flow_name>", <node_id>) catch {};
//! }
//! ```
//!
//! The `catch {}` keeps gameplay alive when the preview socket has
//! closed; the `if (game.preview)` guard means a production build
//! (no `--preview-mode` on argv) pays zero cost.
//!
//! ## Pin variables
//!
//! Pin values live in `n<node_id>_<pin>` locals. References between
//! nodes are entirely by-name (the topo sort guarantees the producing
//! `const` has executed). `GetComponent` is a special case — it
//! produces a single `n<id>_value` binding for the whole component,
//! and downstream consumers can ask for any pin name on that node;
//! the codegen treats non-`value` pin names as field accesses
//! (`n<id>_value.<pin>`). This is what makes the issue #46 sketch
//! (with `GetComponent → BinOp.a` via pin `"x"`) emit sensible Zig.
//!
//! ## Entity resolution (v1)
//!
//! `GetComponent` and `SetField` need an entity. The resolution is
//! intentionally minimal in v1:
//!
//! - For `.OnCreate` / `.OnDestroy`, the event's `arg_entity` is the
//!   identifier name used in the emitted code.
//! - For `.OnUpdate`, there's no obvious entity context yet. If any
//!   node needs one, the codegen emits a stub
//!   `const entity: EntityId = undefined; // TODO(#42)` so the file
//!   still parses; system-style iteration (`for (game.entitiesWith…) |…|`)
//!   is deferred until the engine API lands.
//!
//! ## Disconnected pins
//!
//! Per-kind defaults — the renderer is forgiving where it can be:
//!
//! - `BinOp.a` / `BinOp.b`: default to `0` (numeric identity-ish).
//! - `Call.arg<k>`: default to `undefined` (caller already chose the
//!   shape of the call).
//! - `SetField.value`: no default — disconnected `value` is an error
//!   (`DanglingPin`) because a write with no input is meaningless.

const std = @import("std");
const flow_io = @import("flow_io.zig");

/// Format string for `@import` paths to component type files in the
/// assembler's project layout. Zig resolves `@import` paths relative
/// to the importing file's directory, and generated flows live at
/// `<project>/scripts/flows/<name>.zig` (the v1 convention enforced
/// by `flow_scanner` in labelle-assembler). Components live at
/// `<project>/components/<Name>.zig` — two directories up. The `{s}`
/// substitutes the component type name (`Position`, `Velocity`, …).
const components_import_path_fmt = "../../components/{s}.zig";

/// Caller-facing configuration. `flow_name` is the stem of the
/// source `.flow.zon` file — used as the first argument to
/// `Preview.emitNodeEntered` so the editor can correlate node-entered
/// events with the on-disk flow. Callers typically derive it via
/// `flow_io.displayNameFromPath`.
pub const Options = struct {
    flow_name: []const u8,
};

/// Codegen-side failure modes. Allocation failures from the supplied
/// allocator are merged via `CodegenError || std.mem.Allocator.Error`
/// on the public signature.
pub const CodegenError = error{
    /// Topo sort couldn't make progress — the graph contains a cycle.
    CycleDetected,
    /// A required input pin has no incoming link and no per-kind
    /// default (e.g. `SetField.value`).
    DanglingPin,
    /// A link names a `to.pin` that isn't part of the consumer
    /// node's input pin signature.
    UnknownPin,
    /// A `GetComponent` / `SetField` references a type name that
    /// contains a `.` (namespaced like `foo.bar.Baz`). v1 codegen
    /// emits `const <Name> = @import(...);` lines for each referenced
    /// type, and `const foo.bar.Baz = ...` isn't valid Zig. Bare
    /// component names only for now; namespaced types are a follow-up.
    NamespacedComponentType,
    /// Future-proofing for additional `NodeKind` variants. v1 never
    /// raises this — every shipped variant has a template.
    UnsupportedNodeKind,
};

/// Render a parsed flow as a Zig source file. Caller owns the
/// returned bytes (`allocator.free`).
pub fn renderFlowZig(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    options: Options,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
    // Index, validate, and topo-sort up front so we can stream the
    // output linearly without back-patching. `index` lives on the
    // caller's allocator (small, freed before return).
    var index = try buildIndex(allocator, flow);
    defer index.deinit();

    const order = try topoSort(allocator, flow, &index);
    defer allocator.free(order);

    // Validate every link's pin names against the consumer's input
    // pin signature. Output-side pin names are intentionally NOT
    // validated — GetComponent treats any output pin as a field
    // accessor (see module doc), so anything else would be a false
    // negative.
    for (flow.links) |l| {
        const consumer = index.byId(l.to.node) orelse unreachable; // validated upstream
        if (!isInputPin(consumer.kind, l.to.pin)) return error.UnknownPin;
    }

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    // File header. The `Game` / `EntityId` types are conventionally
    // imported from the consuming project; we re-export the
    // assumption here so the emitted file is self-contained as far
    // as Zig is concerned. The assembler will replace these imports
    // with project-specific ones later.
    try w.writeAll("//! Generated by labelle-gui codegen — DO NOT EDIT.\n");
    try w.writeAll("//! Source: ");
    try w.print("{f}", .{std.zig.fmtString(options.flow_name)});
    try w.writeAll(".flow.zon\n\n");
    try w.writeAll("const std = @import(\"std\");\n");
    try w.writeAll("const game_mod = @import(\"game\");\n");
    try w.writeAll("const Game = game_mod.Game;\n");
    try w.writeAll("const EntityId = game_mod.EntityId;\n");

    // Component imports: every type-name referenced by a
    // `GetComponent` or `SetField` node needs a matching
    // `@import("../../components/<Name>.zig").<Name>` so the generated
    // file resolves under the assembler's project layout. We sort
    // for deterministic output and de-duplicate so a single type
    // referenced from multiple nodes emits only one import. See
    // issue #101.
    const component_types = try collectComponentTypes(allocator, flow);
    defer allocator.free(component_types);
    for (component_types) |type_name| {
        try w.writeAll("const ");
        try w.writeAll(type_name);
        try w.writeAll(" = @import(\"");
        try w.print(components_import_path_fmt, .{type_name});
        try w.writeAll("\").");
        try w.writeAll(type_name);
        try w.writeAll(";\n");
    }
    try w.writeAll("\n");

    // Function signature, derived from the event variant.
    try writeFnHeader(w, flow.event);

    // Node templates reference a local `entity` binding. For OnUpdate
    // there's no inherent entity, so we emit a TODO stub. For
    // OnCreate/OnDestroy we alias the user-chosen `arg_entity` name
    // to `entity` so the templates work regardless of whether the
    // flow named the parameter `entity`, `self`, `victim`, etc.
    if (anyNodeNeedsEntity(flow.nodes)) {
        switch (flow.event) {
            .OnUpdate => {
                try w.writeAll("    // TODO(#42): real entity selection for OnUpdate flows.\n");
                try w.writeAll("    const entity: EntityId = undefined;\n");
            },
            .OnCreate => |b| {
                if (!std.mem.eql(u8, b.arg_entity, "entity")) {
                    try w.print("    const entity = {s};\n", .{b.arg_entity});
                }
            },
            .OnDestroy => |b| {
                if (!std.mem.eql(u8, b.arg_entity, "entity")) {
                    try w.print("    const entity = {s};\n", .{b.arg_entity});
                }
            },
        }
    }

    // Walk in topo order, emitting preview pulse + node body for each.
    // Per-node scratch arena keeps the small string allocations from
    // pin-resolution from churning the caller's allocator.
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (order) |id| {
        const node = index.byId(id) orelse unreachable;
        try writePreviewPulse(w, options.flow_name, node.id);
        try writeNodeBody(w, node, flow, &index, scratch.allocator());
        _ = scratch.reset(.retain_capacity);
    }

    try w.writeAll("}\n");
    return aw.toOwnedSlice();
}

// =====================================================================
// Index + topo sort
// =====================================================================

/// Lookup helpers used during codegen. Owns no flow memory — every
/// slice borrows lifetime from the caller's `Flow`.
const Index = struct {
    allocator: std.mem.Allocator,
    by_id: std.AutoHashMap(u32, *const flow_io.Node),
    /// `(to.node, to.pin) → from-node-id`. The key includes both
    /// fields because a single consumer node may have several input
    /// pins, each fed by a different producer.
    producers: std.HashMap(EdgeKey, *const flow_io.Link, EdgeKeyContext, std.hash_map.default_max_load_percentage),

    fn deinit(self: *Index) void {
        self.by_id.deinit();
        self.producers.deinit();
    }

    fn byId(self: *const Index, id: u32) ?*const flow_io.Node {
        return self.by_id.get(id);
    }

    fn producerOf(self: *const Index, consumer: u32, pin: []const u8) ?*const flow_io.Link {
        return self.producers.get(.{ .node = consumer, .pin = pin });
    }
};

const EdgeKey = struct {
    node: u32,
    pin: []const u8,
};

const EdgeKeyContext = struct {
    pub fn hash(_: EdgeKeyContext, k: EdgeKey) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.node));
        h.update(k.pin);
        return h.final();
    }
    pub fn eql(_: EdgeKeyContext, a: EdgeKey, b: EdgeKey) bool {
        return a.node == b.node and std.mem.eql(u8, a.pin, b.pin);
    }
};

fn buildIndex(allocator: std.mem.Allocator, flow: flow_io.Flow) !Index {
    var idx: Index = .{
        .allocator = allocator,
        .by_id = std.AutoHashMap(u32, *const flow_io.Node).init(allocator),
        .producers = std.HashMap(EdgeKey, *const flow_io.Link, EdgeKeyContext, std.hash_map.default_max_load_percentage).init(allocator),
    };
    errdefer idx.deinit();

    for (flow.nodes) |*n| {
        try idx.by_id.put(n.id, n);
    }
    // Links borrow `to.pin` straight from the flow's arena, which
    // outlives the index, so the hash map can store the slice
    // without copying.
    for (flow.links) |*l| {
        try idx.producers.put(.{ .node = l.to.node, .pin = l.to.pin }, l);
    }
    return idx;
}

/// Kahn's algorithm — produces an order where every node's
/// dependencies appear before it. Ties break by ascending node id so
/// the output is deterministic.
fn topoSort(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
    index: *const Index,
) (CodegenError || std.mem.Allocator.Error)![]u32 {
    // In-degree count: for each node, how many of its input pins
    // are fed by an incoming link. We don't care about pin identity
    // here, just the count.
    var indeg = std.AutoHashMap(u32, usize).init(allocator);
    defer indeg.deinit();
    for (flow.nodes) |n| {
        try indeg.put(n.id, 0);
    }
    for (flow.links) |l| {
        const entry = indeg.getPtr(l.to.node) orelse return error.CycleDetected;
        entry.* += 1;
    }

    // Seed the ready set with every zero-indegree node, sorted by id
    // for deterministic output.
    var ready: std.ArrayList(u32) = .empty;
    defer ready.deinit(allocator);
    for (flow.nodes) |n| {
        if (indeg.get(n.id).? == 0) try ready.append(allocator, n.id);
    }
    std.mem.sort(u32, ready.items, {}, std.sort.asc(u32));

    const order = try allocator.alloc(u32, flow.nodes.len);
    errdefer allocator.free(order);
    var emitted: usize = 0;

    while (ready.items.len > 0) {
        // Pop the smallest id to keep the sort stable.
        const next = ready.orderedRemove(0);
        order[emitted] = next;
        emitted += 1;

        // Decrement the indegree of every node `next` feeds. Any
        // that hit zero join the ready set in id order.
        var added: std.ArrayList(u32) = .empty;
        defer added.deinit(allocator);
        for (flow.links) |l| {
            if (l.from.node != next) continue;
            const e = indeg.getPtr(l.to.node).?;
            if (e.* > 0) {
                e.* -= 1;
                if (e.* == 0) try added.append(allocator, l.to.node);
            }
        }
        std.mem.sort(u32, added.items, {}, std.sort.asc(u32));
        // Merge `added` into `ready` keeping the latter sorted. A
        // small list — linear insertion is fine.
        for (added.items) |id| {
            var i: usize = 0;
            while (i < ready.items.len and ready.items[i] < id) : (i += 1) {}
            try ready.insert(allocator, i, id);
        }
    }

    if (emitted != flow.nodes.len) {
        return error.CycleDetected; // errdefer above frees `order`
    }

    _ = index; // unused but kept in the signature for future heuristics
    return order;
}

// =====================================================================
// Emission helpers
// =====================================================================

fn writeFnHeader(w: anytype, ev: flow_io.Event) !void {
    switch (ev) {
        .OnUpdate => |b| try w.print(
            "pub fn onUpdate(game: *Game, {s}: f32) void {{\n",
            .{b.arg_dt},
        ),
        .OnCreate => |b| try w.print(
            "pub fn onCreate(game: *Game, {s}: EntityId) void {{\n",
            .{b.arg_entity},
        ),
        .OnDestroy => |b| try w.print(
            "pub fn onDestroy(game: *Game, {s}: EntityId) void {{\n",
            .{b.arg_entity},
        ),
    }
}

/// Folded from former issue #90 — pulse the preview socket on every
/// node entry. Failure is swallowed (`catch {}`) so a closed socket
/// is invisible to gameplay; the `if (game.preview)` guard skips
/// the work entirely in production builds.
fn writePreviewPulse(w: anytype, flow_name: []const u8, node_id: u32) !void {
    try w.writeAll("    if (game.preview) |*_p| {\n");
    try w.print(
        "        _p.emitNodeEntered(\"{f}\", {d}) catch {{}};\n",
        .{ std.zig.fmtString(flow_name), node_id },
    );
    try w.writeAll("    }\n");
}

fn writeNodeBody(
    w: anytype,
    node: *const flow_io.Node,
    flow: flow_io.Flow,
    index: *const Index,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    switch (node.kind) {
        .GetComponent => |b| try w.print(
            "    const n{d}_value = game.getComponent(entity, {s}) orelse return;\n",
            .{ node.id, b.type },
        ),
        .SetField => |b| {
            // `target` is "T.field"; split on the last `.` so type
            // names with their own dots (`foo.bar.Baz.field`) work.
            const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse return error.UnknownPin;
            const type_name = b.target[0..dot];
            const field_name = b.target[dot + 1 ..];

            const value_expr = (try resolveInput(node, "value", flow, index, scratch)) orelse return error.DanglingPin;
            try w.print(
                "    game.setField({s}, .{s}, entity, {s});\n",
                .{ type_name, field_name, value_expr },
            );
        },
        .BinOp => |b| {
            const a_expr = (try resolveInput(node, "a", flow, index, scratch)) orelse "0";
            const b_expr = (try resolveInput(node, "b", flow, index, scratch)) orelse "0";
            const op_text: []const u8 = switch (b.op) {
                .add => "+",
                .sub => "-",
                .mul => "*",
                .div => "/",
            };
            try w.print(
                "    const n{d}_result = {s} {s} {s};\n",
                .{ node.id, a_expr, op_text, b_expr },
            );
        },
        .Literal => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.value },
        ),
        .Identifier => |b| try w.print(
            "    const n{d}_value = {s};\n",
            .{ node.id, b.name },
        ),
        .Call => |b| {
            // Highest connected `arg<k>` index sets the arity (see
            // `countCallArgs`); gaps fill with `undefined`, matching
            // the disconnected-pin default rule.
            const arity = countCallArgs(flow, node.id);
            try w.print("    const n{d}_result = {s}(", .{ node.id, b.callee });
            var i: usize = 0;
            while (i < arity) : (i += 1) {
                if (i > 0) try w.writeAll(", ");
                // 16 bytes fits "arg" + max-width usize comfortably;
                // overflow here would be a logic bug, not a runtime
                // condition the caller can hit.
                var buf: [16]u8 = undefined;
                const pin = std.fmt.bufPrint(&buf, "arg{d}", .{i}) catch unreachable;
                const expr = (try resolveInput(node, pin, flow, index, scratch)) orelse "undefined";
                try w.writeAll(expr);
            }
            try w.writeAll(");\n");
        },
    }
}

/// Resolve `pin` on `consumer` to a Zig expression string. Returns
/// `null` if the pin is disconnected (the caller decides whether
/// that's an error or a default). The returned slice is allocated
/// on `scratch`; the caller's per-node arena reset reclaims it.
fn resolveInput(
    consumer: *const flow_io.Node,
    pin: []const u8,
    flow: flow_io.Flow,
    index: *const Index,
    scratch: std.mem.Allocator,
) (CodegenError || std.mem.Allocator.Error)!?[]const u8 {
    _ = flow;
    const link = index.producerOf(consumer.id, pin) orelse return null;
    const producer = index.byId(link.from.node) orelse return error.UnknownPin;

    // Producer-side default: every kind ships with a "primary"
    // output pin; if the link names it, the local variable is the
    // value. Otherwise we fall through to per-kind special cases.
    const primary = primaryOutputPin(producer.kind);
    if (std.mem.eql(u8, link.from.pin, primary)) {
        return try std.fmt.allocPrint(scratch, "n{d}_{s}", .{ producer.id, primary });
    }

    // GetComponent treats non-`value` output pins as field
    // accessors on the bound component value. This is what makes
    // the #46 sketch (`GetComponent → BinOp.a` via pin `"x"`)
    // produce `n1_value.x` rather than UnknownPin.
    switch (producer.kind) {
        .GetComponent => {
            return try std.fmt.allocPrint(
                scratch,
                "n{d}_value.{s}",
                .{ producer.id, link.from.pin },
            );
        },
        else => return error.UnknownPin,
    }
}

fn primaryOutputPin(k: flow_io.NodeKind) []const u8 {
    return switch (k) {
        .GetComponent, .Literal, .Identifier => "value",
        .BinOp, .Call => "result",
        // SetField has no outputs; "primary" is a no-op for it
        // (resolveInput never asks because consumers can't link
        // *from* a SetField in any kind we ship).
        .SetField => "",
    };
}

fn isInputPin(k: flow_io.NodeKind, pin: []const u8) bool {
    return switch (k) {
        // Producers — no inputs.
        .GetComponent, .Literal, .Identifier => false,
        .SetField => std.mem.eql(u8, pin, "value"),
        .BinOp => std.mem.eql(u8, pin, "a") or std.mem.eql(u8, pin, "b"),
        .Call => isCallArgPin(pin),
    };
}

/// `arg0`, `arg1`, … `arg<u32>`. Anything else is rejected.
fn isCallArgPin(pin: []const u8) bool {
    if (!std.mem.startsWith(u8, pin, "arg")) return false;
    const tail = pin[3..];
    if (tail.len == 0) return false;
    for (tail) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

/// Largest `arg<k>` index linking *into* `node_id`, plus one. So a
/// node with `arg0` and `arg2` connected returns 3 — arity is set by
/// the highest connected index, not the count of present links, so
/// argument positions stay stable.
fn countCallArgs(flow: flow_io.Flow, node_id: u32) usize {
    var max_idx: ?usize = null;
    for (flow.links) |l| {
        if (l.to.node != node_id) continue;
        if (!std.mem.startsWith(u8, l.to.pin, "arg")) continue;
        const tail = l.to.pin[3..];
        const idx = std.fmt.parseInt(usize, tail, 10) catch continue;
        if (max_idx == null or idx > max_idx.?) max_idx = idx;
    }
    return if (max_idx) |m| m + 1 else 0;
}

/// Walk the flow's nodes and collect every component type-name
/// referenced by `GetComponent` (verbatim `type` field) or
/// `SetField` (the segment of `target` left of the LAST `.`, matching
/// the split rule used by the `SetField` template — see
/// `writeNodeBody`). The returned slice is allocated on `allocator`,
/// is alphabetically sorted, and contains no duplicates so the
/// caller can emit one `@import` per name with deterministic order.
///
/// `SetField.target` values without any `.` are skipped — they're
/// rejected as `UnknownPin` further down the pipeline, and we don't
/// want to crash building the import set on a flow that's about to
/// fail validation anyway.
fn collectComponentTypes(
    allocator: std.mem.Allocator,
    flow: flow_io.Flow,
) (CodegenError || std.mem.Allocator.Error)![][]const u8 {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(allocator);

    for (flow.nodes) |n| {
        const type_name: ?[]const u8 = switch (n.kind) {
            .GetComponent => |b| b.type,
            .SetField => |b| blk: {
                const dot = std.mem.lastIndexOfScalar(u8, b.target, '.') orelse break :blk null;
                break :blk b.target[0..dot];
            },
            else => null,
        };
        if (type_name) |t| {
            if (t.len == 0) continue;
            // Bare identifiers only — namespaced types (`foo.bar.Baz`)
            // would emit `const foo.bar.Baz = @import(...);`, which
            // isn't valid Zig. Surface as a typed error so the
            // assembler can give a useful diagnostic; tracked for v2.
            if (std.mem.indexOfScalar(u8, t, '.') != null) return error.NamespacedComponentType;
            const gop = try seen.getOrPut(t);
            if (!gop.found_existing) try list.append(allocator, t);
        }
    }

    const out = try list.toOwnedSlice(allocator);
    std.mem.sort([]const u8, out, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return out;
}

fn anyNodeNeedsEntity(nodes: []const flow_io.Node) bool {
    for (nodes) |n| {
        switch (n.kind) {
            .GetComponent, .SetField => return true,
            else => {},
        }
    }
    return false;
}
