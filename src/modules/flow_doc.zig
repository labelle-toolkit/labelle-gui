//! `.flow.jsonc` flow-graph editor — per-tab state and rendering
//! (RFC: Flows as `.flow.jsonc`, issue #153).
//!
//! This is the *authoring* counterpart to `modules/flow.zig`. Where
//! `flow.zig` is a read-only viewer derived from a `.zig` script,
//! this editor loads, edits, and writes the `.flow.jsonc` content
//! format described by the RFC: a flat `nodes` + `edges` graph with a
//! top-level `event`, an optional subgraph `params` interface, and the
//! `Subflow` / `Param` / `Output` composition node types.
//!
//! Layout — two columns:
//!   - Left: an imgui-node-editor canvas. Each node is one editor
//!     node; positions persist into `flow_io.Node.pos` so a save keeps
//!     the layout. Edges are drawn from `flow_io.Edge`.
//!   - Right: an inspector. Top section is the subgraph `params`
//!     editor (declare name/type/default, RFC §3). Below it is the
//!     node palette (add `Subflow` / `Param` / `Output` / a custom
//!     typed node) and the selected node's editable fields.
//!
//! Scope (v1): structural editing — add/remove nodes, edit the typed
//! fields of the three composition node types, edit `params`, edit the
//! event type, move nodes on the canvas. Edge creation by dragging
//! pins and a load-time cycle check across `Subflow` references are
//! deferred — see the PR notes. Unknown node types (`BinOp`, …) and
//! their fields round-trip verbatim through `flow_io` but aren't
//! field-editable here.

const std = @import("std");
const zgui = @import("zgui");
const ne = zgui.node_editor;

const App = @import("../app.zig").App;
const flow_io = @import("../flow_io.zig");

const inspector_w: f32 = 340;
const split_gap: f32 = 8;

/// Edit-buffer size for short identifier fields (param names, type
/// names, flow refs). Comfortably above any realistic identifier.
const ident_buf_len: usize = 128;
const IdentBuf = [ident_buf_len:0]u8;

/// Edit-buffer size for a literal value (a `default` or a `binding`).
const value_buf_len: usize = 256;
const ValueBuf = [value_buf_len:0]u8;

/// One rendered pin on the canvas. The node editor only knows pins by
/// their opaque `u64` id; `pinId` is a one-way hash, so to map an
/// accepted/deleted link back to a `flow_io.Edge` we record every pin
/// we draw this frame and look the endpoint ids up here.
const PinEntry = struct {
    /// Editor pin id — what `pinId(...)` produced for this pin.
    id: u64,
    node_id: u32,
    /// Pin name. Borrowed from `doc` — only valid for the current frame.
    name: []const u8,
    dir: PinDir,
};

/// Per-tab state for an open `.flow.jsonc` file.
pub const FlowDocState = struct {
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    display_name: []const u8,
    /// The parsed + editable document. Owns its own arena.
    doc: flow_io.FlowDoc,
    /// imgui-node-editor per-canvas state — node positions, selection,
    /// view transform.
    editor: *ne.EditorContext,
    is_dirty: bool = false,
    /// True until the first frame applies node positions to the editor
    /// (the editor's node store starts empty; we seed it from
    /// `doc.nodes[].pos` once).
    needs_layout: bool = true,
    /// Every pin drawn on the canvas this frame, rebuilt at the top of
    /// `renderCanvas`. Used to resolve a node-editor pin id back to its
    /// `(node_id, name, dir)` when authoring or deleting edges. Backed
    /// by the doc arena; entries borrow `doc` node/pin strings so they
    /// are only valid within the frame that filled the list.
    pins: std.ArrayList(PinEntry) = .empty,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FlowDocState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = flow_io.displayNameFromPath(path_dup);

        var doc = try flow_io.loadFromFile(allocator, path);
        errdefer doc.deinit();

        const config: ne.Config = .{};
        const editor = ne.EditorContext.create(config);
        errdefer editor.destroy();

        return .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .doc = doc,
            .editor = editor,
        };
    }

    pub fn deinit(self: *FlowDocState, allocator: std.mem.Allocator) void {
        self.editor.destroy();
        self.doc.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// Public entry point — `OpenTab.render` dispatches here.
pub fn render(s: *FlowDocState, app: *App) void {
    zgui.text("Flow: {s}", .{s.display_name});
    if (s.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
    }
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) saveFlowDoc(s, app);
    zgui.sameLine(.{});
    zgui.textDisabled("(.flow.jsonc — flat graph editor)", .{});
    zgui.separator();

    const total_w = zgui.getContentRegionAvail()[0];
    const canvas_w = @max(160.0, total_w - inspector_w - split_gap);

    if (zgui.beginChild("##flowdoc_canvas", .{ .w = canvas_w, .h = 0 })) {
        renderCanvas(s);
    }
    zgui.endChild();
    zgui.sameLine(.{});
    if (zgui.beginChild("##flowdoc_inspector", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    })) {
        renderInspector(s);
    }
    zgui.endChild();
}

// ─── Canvas ─────────────────────────────────────────────────────────────

fn renderCanvas(s: *FlowDocState) void {
    ne.setCurrentEditor(s.editor);
    defer ne.setCurrentEditor(null);

    ne.begin("##flowdoc_canvas_ne", .{ 0, 0 });
    defer ne.end();

    // Seed positions from the document the first frame. After that the
    // editor owns positions; we read them back on save.
    if (s.needs_layout) {
        for (s.doc.nodes) |n| {
            ne.setNodePosition(@intCast(n.id), n.pos);
        }
        s.needs_layout = false;
    }

    // Pull live positions back into the document so a Save persists
    // the user's layout. Cheap — one lookup per node per frame.
    for (s.doc.nodes) |*n| {
        const p = ne.getNodePosition(@intCast(n.id));
        if (p[0] != n.pos[0] or p[1] != n.pos[1]) {
            n.pos = p;
            s.is_dirty = true;
        }
    }

    // Reset the per-frame pin registry; `renderNodeBody` (via
    // `recordPin`) refills it as it draws each node's pins.
    s.pins.clearRetainingCapacity();

    // Pin ids must be globally unique and stable. We derive them from
    // (node_id, pin_index, direction) — packed into the high bits so
    // they never collide with node ids or edge ids.
    for (s.doc.nodes) |n| {
        ne.beginNode(@intCast(n.id));
        renderNodeBody(s, n);
        ne.endNode();
    }

    // Edges. Pin ids are recomputed from the endpoint's node + pin
    // name; a pin that doesn't exist on the node still gets a stable
    // synthetic id so the link draws.
    for (s.doc.edges) |e| {
        const from_pin = pinId(e.from_node, e.from_pin, .output);
        const to_pin = pinId(e.to_node, e.to_pin, .input);
        _ = ne.link(linkId(e), from_pin, to_pin, .{ 0.4, 0.8, 1.0, 1.0 }, 1.5);
    }

    // Edge authoring (issue #158) — turn a pin drag into a new
    // `flow_io.Edge`, and a delete gesture into an edge removal. Both
    // gestures are inspected *after* nodes and links are emitted so the
    // editor has the full pin set for this frame.
    handleLinkCreate(s);
    handleLinkDelete(s);
}

/// Record a pin in the per-frame registry so a later `queryNewLink` /
/// `queryDeletedLink` id can be resolved back to `(node, name, dir)`.
/// Call once per `ne.beginPin` with the same id and direction.
fn recordPin(s: *FlowDocState, node_id: u32, name: []const u8, dir: PinDir) void {
    s.pins.append(s.doc.allocator(), .{
        .id = pinId(node_id, name, dir),
        .node_id = node_id,
        .name = name,
        .dir = dir,
    }) catch {};
}

/// Look an editor pin id up in the per-frame registry.
fn findPin(s: *FlowDocState, id: u64) ?PinEntry {
    for (s.pins.items) |p| {
        if (p.id == id) return p;
    }
    return null;
}

/// Whether an edge already wires this exact (output) → (input) pair.
fn edgeExists(s: *FlowDocState, from: PinEntry, to: PinEntry) bool {
    for (s.doc.edges) |e| {
        if (e.from_node == from.node_id and
            e.to_node == to.node_id and
            std.mem.eql(u8, e.from_pin, from.name) and
            std.mem.eql(u8, e.to_pin, to.name)) return true;
    }
    return false;
}

/// Drive the node-editor create-link query. On a valid accepted drag
/// (one output pin → one input pin on two different nodes) a fresh
/// `flow_io.Edge` is appended and the tab marked dirty.
fn handleLinkCreate(s: *FlowDocState) void {
    if (!ne.beginCreate()) {
        ne.endCreate();
        return;
    }
    defer ne.endCreate();

    var start_id: ?u64 = null;
    var end_id: ?u64 = null;
    if (!ne.queryNewLink(&start_id, &end_id)) return;
    // Both endpoints land only once the user releases over a pin.
    const sid = start_id orelse return;
    const eid = end_id orelse return;

    const sp = findPin(s, sid);
    const ep = findPin(s, eid);
    // An unknown pin id (a pin not drawn this frame) — reject.
    if (sp == null or ep == null) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }
    const a_pin = sp.?;
    const b_pin = ep.?;

    // Validate: exactly one input and one output, on two distinct
    // nodes, and not a duplicate of an existing edge. The drag may
    // start from either end, so figure out which is the output.
    const valid = a_pin.dir != b_pin.dir and
        a_pin.node_id != b_pin.node_id;
    if (!valid) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }
    const out_pin = if (a_pin.dir == .output) a_pin else b_pin;
    const in_pin = if (a_pin.dir == .output) b_pin else a_pin;
    if (edgeExists(s, out_pin, in_pin)) {
        _ = ne.rejectNewItem(.{ 1.0, 0.6, 0.2, 1.0 }, 2.0);
        return;
    }

    // `acceptNewItem` returns true on the frame the user releases the
    // drag — only then do we commit the edge.
    if (ne.acceptNewItem(.{ 0.3, 1.0, 0.4, 1.0 }, 2.0)) {
        appendEdge(s, out_pin, in_pin) catch |err| {
            std.log.err("flow: add edge failed: {s}", .{@errorName(err)});
        };
    }
}

/// Drive the node-editor delete query — removes any edge the user
/// selected and deleted on the canvas.
fn handleLinkDelete(s: *FlowDocState) void {
    if (!ne.beginDelete()) {
        ne.endDelete();
        return;
    }
    defer ne.endDelete();

    var del_id: u64 = 0;
    while (ne.queryDeletedLink(&del_id, null, null)) {
        if (ne.acceptDeletedItem(true)) {
            deleteEdgeByLinkId(s, del_id) catch |err| {
                std.log.err("flow: delete edge failed: {s}", .{@errorName(err)});
            };
        }
    }
    // Node deletion is handled by the inspector's "Delete node" button;
    // reject node-delete gestures here so a stray selection doesn't
    // silently drop a node behind the inspector's back.
    var del_node: u64 = 0;
    while (ne.queryDeletedNode(&del_node)) {
        ne.rejectDeletedItem();
    }
}

/// Deterministic global link id for an edge.
///
/// Derived from a hash of the edge's four endpoint components, with bit
/// 63 forced set so the id can never collide with a node id (small
/// integers) or a pin id (`pinId` only ever sets bits up to 62). Hashing
/// the endpoints — rather than using the edge's array index — keeps the
/// id stable when edges are added or removed, so the node editor's
/// per-link selection state doesn't jump to a different edge after an
/// edit.
fn linkId(e: flow_io.Edge) u64 {
    var h = std.hash.Wyhash.init(0x11f0);
    h.update(std.mem.asBytes(&e.from_node));
    h.update(e.from_pin);
    h.update(&[_]u8{0}); // delimiter so (pin "ab"|node) ≠ (pin "a"|"b"node)
    h.update(std.mem.asBytes(&e.to_node));
    h.update(e.to_pin);
    return (h.final() & 0x7FFF_FFFF_FFFF_FFFF) | (@as(u64, 1) << 63);
}

const PinDir = enum { input, output };

/// Deterministic global pin id from a node id, pin name, and
/// direction. Layout: bits 0–29 a name hash, bits 30–61 the node id,
/// bit 62 the direction (set for outputs). Bit 63 is left clear so the
/// whole pin-id space stays disjoint from link ids (`linkId` always
/// sets bit 63). Collisions within the name-hash bits are astronomically
/// unlikely and only cost a mis-drawn link, never data loss.
fn pinId(node: u32, name: []const u8, dir: PinDir) u64 {
    var h = std.hash.Wyhash.init(node);
    h.update(name);
    const base = (h.final() & 0x3FFF_FFFF) | (@as(u64, node) << 30);
    return if (dir == .output) base | (@as(u64, 1) << 62) else base;
}

fn renderNodeBody(s: *FlowDocState, n: flow_io.Node) void {
    zgui.text("[{d}] {s}", .{ n.id, n.type_name });
    switch (n.kind) {
        .subflow => {
            zgui.textDisabled("flow: {s}", .{n.flow_ref});
            // One input pin per binding; output pins are unknown to the
            // editor without resolving the referenced flow (deferred).
            for (n.bindings) |b| {
                ne.beginPin(pinId(n.id, b.name, .input), .input);
                zgui.text("> {s}", .{b.name});
                ne.endPin();
                recordPin(s, n.id, b.name, .input);
            }
        },
        .param => {
            zgui.textDisabled("param: {s}", .{n.param_ref});
            ne.beginPin(pinId(n.id, "value", .output), .output);
            zgui.text("value >", .{});
            ne.endPin();
            recordPin(s, n.id, "value", .output);
        },
        .output => {
            zgui.textDisabled("output: {s}", .{n.output_name});
            ne.beginPin(pinId(n.id, "value", .input), .input);
            zgui.text("> value", .{});
            ne.endPin();
            recordPin(s, n.id, "value", .input);
        },
        .other => {
            // Show extras as a compact hint so the user can tell nodes
            // apart even though the editor can't field-edit them.
            for (n.extras) |kv| {
                zgui.textDisabled("{s}: {s}", .{ kv.key, kv.value_text });
            }
        },
    }
}

// ─── Inspector ──────────────────────────────────────────────────────────

fn renderInspector(s: *FlowDocState) void {
    renderEventEditor(s);
    zgui.spacing();
    zgui.separator();
    renderParamsEditor(s);
    zgui.spacing();
    zgui.separator();
    renderNodePalette(s);
    zgui.spacing();
    zgui.separator();
    renderSelectedNode(s);
}

fn renderEventEditor(s: *FlowDocState) void {
    zgui.text("Event", .{});
    const a = s.doc.allocator();
    // Static event buffer — re-seeded each frame from the doc so an
    // external reload (none in v1) wouldn't desync, and so the buffer
    // tracks the current value.
    var buf: IdentBuf = undefined;
    seedBuf(&buf, s.doc.event.type_name);
    if (zgui.inputText("##flow_event_type", .{ .buf = &buf })) {
        s.doc.event.type_name = dupZ(a, &buf) catch s.doc.event.type_name;
        s.is_dirty = true;
    }
    zgui.sameLine(.{});
    zgui.textDisabled("type", .{});
}

fn renderParamsEditor(s: *FlowDocState) void {
    zgui.text("Parameters", .{});
    zgui.textDisabled("Subgraph input interface (RFC §3).", .{});

    const a = s.doc.allocator();
    var remove_idx: ?usize = null;
    var id_buf: [64]u8 = undefined;

    for (s.doc.params, 0..) |*p, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();

        zgui.setNextItemWidth(110);
        var name_buf: IdentBuf = undefined;
        seedBuf(&name_buf, p.name);
        const name_id = std.fmt.bufPrintZ(&id_buf, "##pname{d}", .{i}) catch "##pn";
        if (zgui.inputText(name_id, .{ .buf = &name_buf })) {
            p.name = dupZ(a, &name_buf) catch p.name;
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        zgui.setNextItemWidth(70);
        var type_buf: IdentBuf = undefined;
        seedBuf(&type_buf, p.type_name);
        const type_id = std.fmt.bufPrintZ(&id_buf, "##ptype{d}", .{i}) catch "##pt";
        if (zgui.inputText(type_id, .{ .buf = &type_buf })) {
            p.type_name = dupZ(a, &type_buf) catch p.type_name;
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        zgui.setNextItemWidth(80);
        var def_buf: ValueBuf = undefined;
        seedBuf(&def_buf, p.default_text orelse "");
        const def_id = std.fmt.bufPrintZ(&id_buf, "##pdef{d}", .{i}) catch "##pd";
        if (zgui.inputText(def_id, .{ .buf = &def_buf })) {
            const txt = std.mem.sliceTo(&def_buf, 0);
            // The raw text is normalised to canonical JSON value text so
            // a save can never emit invalid `.flow.jsonc` — a bare word
            // becomes a quoted string, `25` stays `25`. Blank → no
            // default (the param must then be wired or bound).
            p.default_text = if (txt.len == 0)
                null
            else
                (flow_io.normalizeValueText(a, txt) catch p.default_text);
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        const x_id = std.fmt.bufPrintZ(&id_buf, "x##prm{d}", .{i}) catch "x";
        if (zgui.smallButton(x_id)) remove_idx = i;
    }
    zgui.textDisabled("(name / type / default — default may be blank)", .{});

    if (zgui.button("+ Add parameter", .{})) {
        appendParam(s) catch |err| {
            std.log.err("flow: add param failed: {s}", .{@errorName(err)});
        };
    }
    if (remove_idx) |idx| {
        removeParam(s, idx) catch |err| {
            std.log.err("flow: remove param failed: {s}", .{@errorName(err)});
        };
    }
}

fn renderNodePalette(s: *FlowDocState) void {
    zgui.text("Add node", .{});
    if (zgui.button("+ Subflow", .{})) {
        addNode(s, .subflow) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Param", .{})) {
        addNode(s, .param) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Output", .{})) {
        addNode(s, .output) catch |err| nodeAddErr(err);
    }
}

fn nodeAddErr(err: anyerror) void {
    std.log.err("flow: add node failed: {s}", .{@errorName(err)});
}

fn renderSelectedNode(s: *FlowDocState) void {
    zgui.text("Selected node", .{});

    ne.setCurrentEditor(s.editor);
    var ids: [4]u64 = undefined;
    const count = ne.getSelectedNodes(ids[0..]);
    ne.setCurrentEditor(null);

    if (count <= 0) {
        zgui.textDisabled("Click a node on the canvas.", .{});
        return;
    }
    const sel_id: u32 = @intCast(ids[0]);
    var node: ?*flow_io.Node = null;
    for (s.doc.nodes) |*n| {
        if (n.id == sel_id) {
            node = n;
            break;
        }
    }
    const n = node orelse {
        zgui.textDisabled("Selection not found.", .{});
        return;
    };

    const a = s.doc.allocator();
    zgui.textDisabled("id {d} — type {s}", .{ n.id, n.type_name });

    switch (n.kind) {
        .subflow => {
            zgui.text("Referenced flow", .{});
            var fbuf: IdentBuf = undefined;
            seedBuf(&fbuf, n.flow_ref);
            if (zgui.inputText("##sf_flow", .{ .buf = &fbuf })) {
                n.flow_ref = dupZ(a, &fbuf) catch n.flow_ref;
                s.is_dirty = true;
            }
            zgui.spacing();
            zgui.text("Bindings (literal param values)", .{});
            renderBindingsEditor(s, n);
        },
        .param => {
            zgui.text("Reads parameter", .{});
            var pbuf: IdentBuf = undefined;
            seedBuf(&pbuf, n.param_ref);
            if (zgui.inputText("##pm_ref", .{ .buf = &pbuf })) {
                n.param_ref = dupZ(a, &pbuf) catch n.param_ref;
                s.is_dirty = true;
            }
            if (n.param_ref.len > 0 and !paramDeclared(s, n.param_ref)) {
                zgui.textColored(.{ 1.0, 0.4, 0.4, 1.0 }, "(undeclared parameter)", .{});
            }
        },
        .output => {
            zgui.text("Result pin name", .{});
            var obuf: IdentBuf = undefined;
            seedBuf(&obuf, n.output_name);
            if (zgui.inputText("##out_name", .{ .buf = &obuf })) {
                n.output_name = dupZ(a, &obuf) catch n.output_name;
                s.is_dirty = true;
            }
        },
        .other => {
            zgui.textDisabled("This node type is not field-editable in v1.", .{});
            zgui.textDisabled("Its fields round-trip verbatim:", .{});
            for (n.extras) |kv| {
                zgui.bulletText("{s}: {s}", .{ kv.key, kv.value_text });
            }
        },
    }

    zgui.spacing();
    if (zgui.button("Delete node", .{})) {
        deleteNode(s, n.id) catch |err| {
            std.log.err("flow: delete node failed: {s}", .{@errorName(err)});
        };
    }
}

fn renderBindingsEditor(s: *FlowDocState, n: *flow_io.Node) void {
    const a = s.doc.allocator();
    var remove_idx: ?usize = null;
    var id_buf: [64]u8 = undefined;

    for (n.bindings, 0..) |*b, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();

        zgui.setNextItemWidth(110);
        var name_buf: IdentBuf = undefined;
        seedBuf(&name_buf, b.name);
        const name_id = std.fmt.bufPrintZ(&id_buf, "##bn{d}", .{i}) catch "##bn";
        if (zgui.inputText(name_id, .{ .buf = &name_buf })) {
            b.name = dupZ(a, &name_buf) catch b.name;
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        zgui.setNextItemWidth(110);
        var val_buf: ValueBuf = undefined;
        seedBuf(&val_buf, b.value_text);
        const val_id = std.fmt.bufPrintZ(&id_buf, "##bv{d}", .{i}) catch "##bv";
        if (zgui.inputText(val_id, .{ .buf = &val_buf })) {
            // Normalise so the bound literal is always valid JSON text;
            // see `renderParamsEditor` for the rationale.
            const txt = std.mem.sliceTo(&val_buf, 0);
            b.value_text = flow_io.normalizeValueText(a, txt) catch b.value_text;
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        const x_id = std.fmt.bufPrintZ(&id_buf, "x##bx{d}", .{i}) catch "x";
        if (zgui.smallButton(x_id)) remove_idx = i;
    }
    zgui.textDisabled("(param name / JSON literal — e.g. 25 or \"txt\")", .{});

    if (zgui.button("+ Add binding", .{})) {
        // Only mark dirty if the grow actually succeeded — a failed
        // allocation leaves `n.bindings` unchanged.
        if (growBindings(a, n.bindings, .{
            .name = "param",
            .value_text = "0",
        })) |grown| {
            n.bindings = grown;
            s.is_dirty = true;
        } else |err| {
            std.log.err("flow: add binding failed: {s}", .{@errorName(err)});
        }
    }
    if (remove_idx) |idx| {
        if (removeAt(flow_io.Binding, a, n.bindings, idx)) |shrunk| {
            n.bindings = shrunk;
            s.is_dirty = true;
        } else |err| {
            std.log.err("flow: remove binding failed: {s}", .{@errorName(err)});
        }
    }
}

// ─── Mutators ───────────────────────────────────────────────────────────

fn appendParam(s: *FlowDocState) !void {
    const a = s.doc.allocator();
    s.doc.params = try growParams(a, s.doc.params, .{
        .name = try a.dupe(u8, "param"),
        .type_name = try a.dupe(u8, "f32"),
        .default_text = null,
    });
    s.is_dirty = true;
}

fn removeParam(s: *FlowDocState, idx: usize) !void {
    const a = s.doc.allocator();
    s.doc.params = try removeAt(flow_io.Param, a, s.doc.params, idx);
    s.is_dirty = true;
}

fn addNode(s: *FlowDocState, kind: flow_io.NodeKind) !void {
    const a = s.doc.allocator();
    const id = s.doc.nextNodeId();
    const type_name = kind.typeName() orelse return error.UnsupportedKind;

    // Place new nodes in a staggered cascade so they don't all stack
    // on the origin.
    const offset: f32 = @floatFromInt((s.doc.nodes.len % 8) * 30);
    var node: flow_io.Node = .{
        .id = id,
        .type_name = try a.dupe(u8, type_name),
        .kind = kind,
        .pos = .{ 40 + offset, 40 + offset },
    };
    switch (kind) {
        .subflow => node.flow_ref = try a.dupe(u8, ""),
        .param => node.param_ref = try a.dupe(u8, ""),
        .output => node.output_name = try a.dupe(u8, "result"),
        .other => unreachable,
    }
    s.doc.nodes = try growNodes(a, s.doc.nodes, node);
    s.needs_layout = true; // re-seed so the new node's pos is applied
    s.is_dirty = true;
}

fn deleteNode(s: *FlowDocState, id: u32) !void {
    const a = s.doc.allocator();
    // Find the index.
    var idx: ?usize = null;
    for (s.doc.nodes, 0..) |n, i| {
        if (n.id == id) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;
    s.doc.nodes = try removeAt(flow_io.Node, a, s.doc.nodes, i);
    // Drop any edges touching the deleted node.
    var kept: std.ArrayList(flow_io.Edge) = .empty;
    for (s.doc.edges) |e| {
        if (e.from_node == id or e.to_node == id) continue;
        try kept.append(a, e);
    }
    s.doc.edges = try kept.toOwnedSlice(a);
    s.is_dirty = true;
}

/// Append a `flow_io.Edge` from an output pin to an input pin. The
/// caller (`handleLinkCreate`) has already validated direction, node
/// distinctness and duplication; this only allocates and grows.
fn appendEdge(s: *FlowDocState, out_pin: PinEntry, in_pin: PinEntry) !void {
    const a = s.doc.allocator();
    const edge: flow_io.Edge = .{
        .from_node = out_pin.node_id,
        .from_pin = try a.dupe(u8, out_pin.name),
        .to_node = in_pin.node_id,
        .to_pin = try a.dupe(u8, in_pin.name),
    };
    s.doc.edges = try growEdges(a, s.doc.edges, edge);
    s.is_dirty = true;
}

/// Remove the edge whose `linkId` matches `id`. No-op when nothing
/// matches (the editor may report a delete for a link we don't own).
fn deleteEdgeByLinkId(s: *FlowDocState, id: u64) !void {
    const a = s.doc.allocator();
    var idx: ?usize = null;
    for (s.doc.edges, 0..) |e, i| {
        if (linkId(e) == id) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return;
    s.doc.edges = try removeAt(flow_io.Edge, a, s.doc.edges, i);
    s.is_dirty = true;
}

// ─── Slice helpers ──────────────────────────────────────────────────────

fn growNodes(a: std.mem.Allocator, src: []flow_io.Node, add: flow_io.Node) ![]flow_io.Node {
    const out = try a.alloc(flow_io.Node, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = add;
    return out;
}

fn growEdges(a: std.mem.Allocator, src: []flow_io.Edge, add: flow_io.Edge) ![]flow_io.Edge {
    const out = try a.alloc(flow_io.Edge, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = add;
    return out;
}

fn growParams(a: std.mem.Allocator, src: []flow_io.Param, add: flow_io.Param) ![]flow_io.Param {
    const out = try a.alloc(flow_io.Param, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = add;
    return out;
}

fn growBindings(a: std.mem.Allocator, src: []flow_io.Binding, add: flow_io.Binding) ![]flow_io.Binding {
    const out = try a.alloc(flow_io.Binding, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = .{
        .name = try a.dupe(u8, add.name),
        .value_text = try a.dupe(u8, add.value_text),
    };
    return out;
}

fn removeAt(comptime T: type, a: std.mem.Allocator, src: []T, idx: usize) ![]T {
    if (idx >= src.len) return src;
    const out = try a.alloc(T, src.len - 1);
    @memcpy(out[0..idx], src[0..idx]);
    @memcpy(out[idx..], src[idx + 1 ..]);
    return out;
}

fn paramDeclared(s: *FlowDocState, name: []const u8) bool {
    for (s.doc.params) |p| {
        if (std.mem.eql(u8, p.name, name)) return true;
    }
    return false;
}

// ─── Buffer helpers ─────────────────────────────────────────────────────

/// Copy `src` into a fixed-size sentinel buffer, zero-padding the rest.
fn seedBuf(buf: anytype, src: []const u8) void {
    @memset(buf, 0);
    const n = @min(buf.len - 1, src.len);
    @memcpy(buf[0..n], src[0..n]);
}

/// Duplicate the live text of a sentinel buffer onto `a`.
fn dupZ(a: std.mem.Allocator, buf: anytype) ![]const u8 {
    return a.dupe(u8, std.mem.sliceTo(buf, 0));
}

// ─── Save ───────────────────────────────────────────────────────────────

pub fn saveFlowDoc(s: *FlowDocState, app: *App) void {
    flow_io.saveToFile(app.allocator, s.path, s.doc) catch |err| {
        std.log.err("Flow save failed at {s}: {s}", .{ s.path, @errorName(err) });
        app.setStatus("Error saving flow!");
        return;
    };
    s.is_dirty = false;
    app.setStatus("Flow saved!");
}
