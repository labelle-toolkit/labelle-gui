//! Flow viewer — per-tab state and rendering for the Flows
//! visualization layer (issues #48 + #49, umbrella #42).
//!
//! Phase 1: parses a `.zig` file from `<project>/scripts/flows/` via
//! `std.zig.Ast`, projects every entry-point function body into a
//! `Graph` (`src/flows/projector.zig`), and draws the graph in an
//! imgui-node-editor canvas. **Read-only** — save/dirty are no-ops.
//!
//! Layout:
//!   - Top bar: the loaded file's display name + "Reparse" button.
//!   - Left column: the node-editor canvas. Each `GraphNodeSpec`
//!     emits one editor node; positions come from a top-down DAG
//!     layout computed once per (re)derivation.
//!   - Right column: inspector showing the selected node's source
//!     line + raw Zig snippet and a sidebar list of every
//!     `entry_point` node (click → centre the canvas on that root).
//!     The selected-node inspector also carries an "Open in editor"
//!     button (issue #42, Phase 4 — reverse navigation): it hands the
//!     source file + the node's line off to the user's external
//!     editor via `src/flows/reveal.zig`, closing the loop from the
//!     derived graph back to the Zig the LLM wrote.
//!
//! `FlowState` owns:
//!   - an arena for path/display name + source bytes
//!   - the `EditorContext` (visual layout state)
//!   - the loaded source (0-terminated, off arena)
//!   - the current `Graph` (its own arena)
//!
//! Mtime-keyed re-derivation: every render checks the source
//! file's mtime; when it changes the source is reread and the
//! graph is reprojected. Cheap (the Ast parse is fast and the file
//! is small).

const std = @import("std");
const zgui = @import("zgui");
const ne = zgui.node_editor;

const App = @import("../app.zig").App;
const scene_io = @import("../scene_io.zig");
const projector = @import("../flows/projector.zig");
const flow_types = @import("../flows/types.zig");
const reveal = @import("../flows/reveal.zig");
const io_global = @import("../io_global.zig");

const Graph = flow_types.Graph;
const GraphNodeSpec = flow_types.GraphNodeSpec;

const inspector_w: f32 = 320;
const split_gap: f32 = 8;

/// Duration of the active-node pulse highlight (issue #84). 300ms is
/// long enough to register at 60Hz frame rates without trailing
/// previous fires when nodes step every couple of frames.
pub const pulse_duration_ms: i64 = 300;

pub const FlowState = struct {
    arena: *std.heap.ArenaAllocator,
    /// Absolute path on disk. Read-only; used for tab dedup and for
    /// reparses.
    path: []const u8,
    /// Filename stem without `.zig`. Used for the tab label.
    display_name: []const u8,
    /// imgui-node-editor's per-canvas state. Holds positions,
    /// selection, view transform.
    editor: *ne.EditorContext,
    /// Last-observed mtime of `path` (in nanoseconds since the unix
    /// epoch — `std.fs.File.Stat.mtime`). Render reparses when this
    /// changes. Null until the first read succeeds.
    last_mtime: ?i96 = null,
    /// 0-terminated source text. Re-allocated off `arena` on every
    /// (re)read. `std.zig.Ast.parse` requires the `[:0]const u8`
    /// shape so we keep a sentinel here rather than re-terminating
    /// on each parse.
    source: ?[:0]const u8 = null,
    /// Currently-projected graph. Has its own arena which is freed
    /// + replaced on every reparse.
    graph: ?Graph = null,
    /// `false` always — flows are derived from Zig, never authored
    /// here. Kept to satisfy `OpenTab.isDirty`.
    is_dirty: bool = false,

    /// Phase 3 (#84): id of the node currently being pulse-highlighted
    /// because the engine just sent a `node_entered` frame for it.
    /// `null` while no pulse is in progress. The actual node is looked
    /// up by id at render time so a graph reparse doesn't dangle the
    /// reference.
    pulse_node_id: ?u32 = null,
    /// Wall-clock ms (std.time.milliTimestamp()) when the current
    /// pulse started. Used to compute the alpha falloff. Together with
    /// `pulse_node_id` defines an active pulse.
    pulse_started_ms: ?i64 = null,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FlowState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = displayNameFromPath(path_dup);

        // No node-editor settings file — we don't persist layout
        // across sessions yet. Phase 4 may revisit.
        const config: ne.Config = .{};
        const editor = ne.EditorContext.create(config);
        errdefer editor.destroy();

        var state: FlowState = .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .editor = editor,
        };
        // First load + parse. Failures here don't propagate — the
        // file might not exist yet, the user might delete it, etc.
        // We surface that as an empty graph + a status line.
        loadAndProject(&state, allocator) catch |err| {
            std.log.warn("flow {s}: initial parse failed: {s}", .{ path_dup, @errorName(err) });
        };
        return state;
    }

    pub fn deinit(self: *FlowState, allocator: std.mem.Allocator) void {
        if (self.graph) |*g| g.deinit();
        self.editor.destroy();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// `foo.zig` → `foo`. Matches the convention used by `scene.zig`'s
/// `displayNameFromPath` so the tab label looks consistent.
pub fn displayNameFromPath(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const ext = ".zig";
    if (std.mem.endsWith(u8, base, ext)) return base[0 .. base.len - ext.len];
    return scene_io.displayNameFromPath(path);
}

/// (Re)load the source from disk and project it into a graph. Frees
/// the previous source + graph (if any). On failure leaves the
/// state's source/graph cleared so the caller can render an empty
/// canvas.
pub fn loadAndProject(s: *FlowState, allocator: std.mem.Allocator) !void {
    // Drop the old graph first so its arena is reclaimed before the
    // new one gets allocated.
    if (s.graph) |*g| {
        g.deinit();
        s.graph = null;
    }

    const io = io_global.io();
    const max_bytes: usize = 1 << 20; // 1 MiB — scripts are tiny.
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, s.path, allocator, .limited(max_bytes));
    defer allocator.free(raw);
    // Re-stat to record mtime — cheap and avoids opening the file twice
    // in the common case.
    const stat_file = try std.Io.Dir.cwd().openFile(io, s.path, .{ .mode = .read_only });
    defer stat_file.close(io);
    const stat = try stat_file.stat(io);

    // Duplicate into the arena with an explicit 0 sentinel for
    // `std.zig.Ast.parse`. Source must outlive the parse but not
    // the graph (which keeps its own arena).
    const a = s.arena.allocator();
    const src = try a.allocSentinel(u8, raw.len, 0);
    @memcpy(src[0..raw.len], raw);

    s.source = src;

    // Project first, then commit the mtime. If projection fails the
    // mtime stays at its previous value so `maybeReparse` will
    // retry next time the file changes — otherwise we'd silently
    // freeze in the failed-parse state until a manual Reparse click
    // (cursor bugbot #63 low).
    s.graph = try projector.project(allocator, src);
    s.last_mtime = stat.mtime.nanoseconds;
}

/// Per-frame mtime check. Cheap — `stat` is one syscall and we
/// only reparse on change. Errors are swallowed (logged once) to
/// keep the UI responsive when the file disappears mid-session.
fn maybeReparse(s: *FlowState, allocator: std.mem.Allocator) void {
    const io = io_global.io();
    const file = std.Io.Dir.cwd().openFile(io, s.path, .{}) catch return;
    defer file.close(io);
    const stat = file.stat(io) catch return;
    if (s.last_mtime) |prev| {
        if (prev == stat.mtime.nanoseconds) return;
    }
    loadAndProject(s, allocator) catch |err| {
        std.log.warn("flow {s}: reparse failed: {s}", .{ s.path, @errorName(err) });
    };
}

pub fn render(s: *FlowState, app: *App) void {
    maybeReparse(s, app.allocator);

    zgui.text("Flow: {s}", .{s.display_name});
    zgui.sameLine(.{});
    zgui.textDisabled("(read-only — derived from Zig source)", .{});
    zgui.sameLine(.{});
    if (zgui.button("Reparse", .{})) {
        loadAndProject(s, app.allocator) catch |err| {
            std.log.warn("flow {s}: manual reparse failed: {s}", .{ s.path, @errorName(err) });
        };
    }
    zgui.separator();

    const total_w = zgui.getContentRegionAvail()[0];
    const canvas_w = @max(120.0, total_w - inspector_w - split_gap);

    if (zgui.beginChild("##flow_canvas_col", .{ .w = canvas_w, .h = 0 })) {
        renderCanvas(s, app.allocator);
    }
    zgui.endChild();
    zgui.sameLine(.{});
    if (zgui.beginChild("##flow_sidebar", .{
        .w = 0,
        .h = 0,
        .child_flags = .{ .border = true },
    })) {
        renderSidebar(s, app);
    }
    zgui.endChild();
}

fn renderCanvas(s: *FlowState, allocator: std.mem.Allocator) void {
    // Bind the per-tab editor before any node-editor call. The
    // library threads its state through a global; nested editors
    // would clobber each other.
    ne.setCurrentEditor(s.editor);
    defer ne.setCurrentEditor(null);

    ne.begin("##flow_canvas", .{ 0, 0 });
    defer ne.end();

    const graph = s.graph orelse {
        return; // Empty canvas — first parse failed or file missing.
    };

    if (graph.nodes.len == 0) return;

    // Top-down layout: lay nodes out by depth in the graph DAG.
    // Computed once per frame — graphs are small enough that the
    // O(N * E) pass is invisible. Buffers are heap-allocated off
    // the App allocator so graphs larger than the previous 256-node
    // ceiling render correctly (gemini #63 medium).
    const positions = layoutNodes(allocator, graph) catch &[_][2]f32{};
    defer if (positions.len > 0) allocator.free(positions);

    for (graph.nodes, 0..) |gn, i| {
        const node_id: u64 = @intCast(gn.id);
        // Apply the computed position only on the first frame the
        // node appears (when its current x is exactly 0 0 — the
        // node-editor's "uninitialized" sentinel) so user drags
        // stick.
        const current = ne.getNodePosition(node_id);
        if (current[0] == 0 and current[1] == 0 and i < positions.len) {
            ne.setNodePosition(node_id, positions[i]);
        }

        ne.beginNode(node_id);
        zgui.text("{s}", .{gn.label});
        zgui.textDisabled("L{d}", .{gn.source_line});

        // Render input pins, then output pins. Same row works at
        // this scale; the editor's auto-layout takes care of the
        // visual gap.
        for (gn.input_pins) |pin| {
            ne.beginPin(@intCast(pin.id), .input);
            zgui.text("> {s}", .{pin.name});
            ne.endPin();
        }
        for (gn.output_pins) |pin| {
            ne.beginPin(@intCast(pin.id), .output);
            zgui.text("{s} >", .{pin.name});
            ne.endPin();
        }
        ne.endNode();
    }

    // Edges: stable ids keyed by from_pin + to_pin so the editor
    // doesn't see them as new links each frame. The top 32 bits of
    // the u64 hold from_pin, the bottom 32 hold to_pin.
    for (graph.edges) |e| {
        const link_id: u64 = (@as(u64, e.from_pin) << 32) | @as(u64, e.to_pin);
        const colour: [4]f32 = switch (e.kind) {
            .data => .{ 0.4, 0.8, 1.0, 1.0 },
            .execution => .{ 1.0, 0.7, 0.2, 1.0 },
        };
        _ = ne.link(link_id, @intCast(e.from_pin), @intCast(e.to_pin), colour, 1.5);
    }

    // Active-node pulse (Phase 3, #84). Drawn after nodes/edges so
    // the highlight overlays the node's own border.
    renderPulse(s);
}

fn renderSidebar(s: *FlowState, app: *App) void {
    zgui.text("Entry points", .{});
    zgui.separator();

    const graph = s.graph orelse {
        zgui.textDisabled("No graph — file not parsed.", .{});
        return;
    };

    if (graph.entry_points.len == 0) {
        zgui.textDisabled("No matching entry points found.", .{});
    } else {
        for (graph.entry_points) |eid| {
            const node = findNode(graph, eid) orelse continue;
            // Buttons act as the click-to-scroll mechanism. ImGui
            // labels need null termination — use a temp buffer.
            var label_buf: [192]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}  (L{d})", .{ node.label, node.source_line }) catch continue;
            if (zgui.button(label, .{ .w = -1 })) {
                ne.setCurrentEditor(s.editor);
                ne.selectNode(@intCast(eid), false);
                ne.navigateToSelection(false, 0.0);
                ne.setCurrentEditor(null);
            }
        }
    }

    zgui.separator();
    zgui.text("Selection", .{});
    zgui.separator();
    renderSelectedInspector(s, app);
}

fn renderSelectedInspector(s: *FlowState, app: *App) void {
    const graph = s.graph orelse return;
    // Read the editor's current selection. We need to bind the
    // editor first because `getSelectedNodes` is global state.
    ne.setCurrentEditor(s.editor);
    defer ne.setCurrentEditor(null);

    var ids: [4]u64 = undefined;
    const count = ne.getSelectedNodes(ids[0..]);
    if (count <= 0) {
        zgui.textDisabled("Click a node to inspect.", .{});
        return;
    }
    const selected_id: u32 = @intCast(ids[0]);
    const node = findNode(graph, selected_id) orelse {
        zgui.textDisabled("Selection lost (graph re-derived).", .{});
        return;
    };

    zgui.text("{s}", .{node.label});
    zgui.textDisabled("category: {s}", .{@tagName(node.category)});
    zgui.textDisabled("source line: {d}", .{node.source_line});

    // Reverse navigation (issue #42, Phase 4): hand the source file +
    // line off to the user's external editor. The graph is a derived
    // view; "jump to source" closes the loop back to the Zig the LLM
    // (or a human) actually wrote. `revealSelected` reports failure
    // through the status bar — there's no built-in editor to fall
    // back to.
    if (zgui.button("Open in editor", .{ .w = -1 })) {
        revealSelected(s, app, node.source_line);
    }
    zgui.separator();

    if (s.source) |src| {
        const line_text = lineAt(src, node.source_line);
        zgui.textWrapped("{s}", .{line_text});
    }
}

/// Reveal the flow's source file at `line` in the user's editor.
/// Best-effort: a launch failure is logged + surfaced on the status
/// bar rather than propagated — a missing `$EDITOR` / `xdg-open`
/// shouldn't take the gui down. See `src/flows/reveal.zig`.
fn revealSelected(s: *FlowState, app: *App, line: u32) void {
    const result = reveal.reveal(app.allocator, s.path, line) catch |err| {
        std.log.warn("flow {s}: open-in-editor failed: {s}", .{ s.path, @errorName(err) });
        app.setStatus("Could not open the source file in an editor.");
        return;
    };
    if (result.has_line) {
        app.setStatus("Opened source at the selected line.");
    } else {
        // The OS file handler can't be told a line — say so, so the
        // user isn't surprised the cursor didn't move.
        app.setStatus("Opened source file (set $EDITOR for line-precise jumps).");
    }
}

/// Return the n-th 1-based line of `source`, trimmed of its
/// trailing newline. Falls back to an empty slice when out of
/// range. Cheap linear scan — the inspector calls this at most once
/// per frame.
fn lineAt(source: []const u8, line_1based: u32) []const u8 {
    var line: u32 = 1;
    var start: usize = 0;
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            if (line == line_1based) return source[start..i];
            line += 1;
            start = i + 1;
        }
    }
    if (line == line_1based) return source[start..source.len];
    return "";
}

/// Look up a node by id. The projector allocates ids sequentially
/// starting at 1 and pushes them into `graph.nodes` in the same
/// order, so `nodes[id - 1]` is the matching entry. The assert
/// guards against future allocators that violate that invariant
/// (gemini #63 critical — replaces the O(N) scan that ran in the
/// layout inner loop).
fn findNode(graph: Graph, id: u32) ?*const GraphNodeSpec {
    const idx = indexOfNode(graph, id) orelse return null;
    return &graph.nodes[idx];
}

fn indexOfNode(graph: Graph, id: u32) ?usize {
    if (id == 0 or id > graph.nodes.len) return null;
    const i: usize = @as(usize, id) - 1;
    std.debug.assert(graph.nodes[i].id == id);
    return i;
}

/// Top-down DAG layout. We picked the simpler of the two options
/// mentioned in the issue (force-directed vs DAG): a deterministic
/// depth-vs-order grid keyed off longest-path depth.
///
/// Algorithm:
///   1. Walk the edges, propagating "longest path from any root"
///      depths into a heap-allocated buffer. Bounded by node count.
///   2. Emit positions on a simple grid: x = depth * column_w,
///      y = order_in_layer * row_h.
///
/// Allocates `depths`, `layer_counts`, and the returned `positions`
/// slice off `allocator`. Caller owns and frees the returned slice
/// when non-empty.
fn layoutNodes(allocator: std.mem.Allocator, graph: Graph) ![][2]f32 {
    const column_w: f32 = 260.0;
    const row_h: f32 = 110.0;
    const n = graph.nodes.len;
    if (n == 0) return &[_][2]f32{};

    const positions = try allocator.alloc([2]f32, n);
    errdefer allocator.free(positions);

    const depths = try allocator.alloc(u32, n);
    defer allocator.free(depths);
    @memset(depths, 0);

    // Iterate until depths stop changing or we hit a pass cap. A
    // DAG of N nodes converges in ≤ N passes; cycles (from
    // identifier back-refs) just freeze the depth at the cap.
    var pass: usize = 0;
    while (pass < n) : (pass += 1) {
        var changed = false;
        for (graph.edges) |e| {
            const from_idx = indexOfNode(graph, e.from_node) orelse continue;
            const to_idx = indexOfNode(graph, e.to_node) orelse continue;
            const candidate = depths[from_idx] + 1;
            if (depths[to_idx] < candidate) {
                depths[to_idx] = candidate;
                changed = true;
            }
        }
        if (!changed) break;
    }

    // Count how many nodes have already been placed at each depth
    // so we can stack rows without rescanning the depth array. Max
    // depth is bounded by node count, so n slots is always enough.
    const layer_counts = try allocator.alloc(u32, n);
    defer allocator.free(layer_counts);
    @memset(layer_counts, 0);

    for (graph.nodes, 0..) |_, i| {
        const d = depths[i];
        const slot = layer_counts[d];
        positions[i] = .{
            @as(f32, @floatFromInt(d)) * column_w + 40.0,
            @as(f32, @floatFromInt(slot)) * row_h + 40.0,
        };
        layer_counts[d] += 1;
    }
    return positions;
}

/// No-op — flows are derived, not authored. Kept so `OpenTab.save`
/// has a function to dispatch to.
pub fn saveFlow(s: *FlowState, app: *App) void {
    _ = s;
    _ = app;
}

/// Phase 3 (#84): trigger a brief pulse highlight on `node_id`. The
/// pulse fades over `pulse_duration_ms`; the falloff is computed at
/// render time from `pulse_started_ms`. Calling again with the same
/// or a different id restarts the fade — back-to-back step traces
/// re-pulse without trailing.
// std.time.milliTimestamp was removed in Zig 0.16. Use clock_gettime
// directly — matches the pattern in src/tests.zig timestampSeconds.
fn nowMillis() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.REALTIME, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

pub fn pulseNode(s: *FlowState, node_id: u32) void {
    s.pulse_node_id = node_id;
    s.pulse_started_ms = nowMillis();
}

/// Render the active pulse, if any, as a faded border over the node's
/// editor rect. Cheap — one `getNodePosition`+`getNodeSize` lookup
/// plus an `addRect` on the foreground draw list. Returns silently
/// when no pulse is active or it has decayed past the duration.
fn renderPulse(s: *FlowState) void {
    const id = s.pulse_node_id orelse return;
    const started = s.pulse_started_ms orelse return;
    const now = nowMillis();
    const elapsed = now - started;
    if (elapsed < 0 or elapsed > pulse_duration_ms) {
        // Decayed — clear so we don't keep computing a zero-alpha
        // border each frame.
        s.pulse_node_id = null;
        s.pulse_started_ms = null;
        return;
    }
    const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(pulse_duration_ms));
    const alpha: f32 = 1.0 - t;

    // Position + size come from the node editor's per-node state.
    const pos = ne.getNodePosition(@intCast(id));
    const size = ne.getNodeSize(@intCast(id));
    if (size[0] <= 0 or size[1] <= 0) return;
    // Use the editor's hint foreground draw list so the pulse stays
    // anchored in canvas-space when the user pans or zooms, and
    // overlays node bodies. `getWindowDrawList` would draw in
    // screen-space and drift relative to the nodes.
    const dl: zgui.DrawList = @ptrCast(ne.getHintForegroundDrawList());
    const col = zgui.colorConvertFloat4ToU32(.{ 1.0, 0.8, 0.2, alpha });
    dl.addRect(.{
        .pmin = .{ pos[0], pos[1] },
        .pmax = .{ pos[0] + size[0], pos[1] + size[1] },
        .col = col,
        .thickness = 3.0,
    });
}
