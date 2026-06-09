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
//! Scope: structural editing — add/remove nodes, edit the typed fields
//! of the three composition node types, edit `params`, edit the event
//! type, move nodes on the canvas. The inspector also field-edits a set
//! of recognised non-composition node types (`BinOp`, `GetComponent`,
//! `SetField`, `Literal`, `Identifier`, `Call`) via the
//! `flow_io.other_field_specs` table — each exposes one widget over its
//! `extras` value, so the deterministic writer emits it unchanged.
//! Genuinely-unknown node types still fall back to the verbatim view.
//! Edge creation by dragging pins and a load-time cycle check across
//! `Subflow` references are deferred — see the PR notes.

const std = @import("std");
const zgui = @import("zgui");
const ne = zgui.node_editor;

const App = @import("../app.zig").App;
const flow_io = @import("../flow_io.zig");
const io_global = @import("../io_global.zig");
const flow_cycle = @import("../flow_cycle.zig");
const event_catalog = @import("../flow_event_catalog.zig");
const node_catalog = @import("../flow_node_catalog.zig");

const inspector_w: f32 = 340;
const split_gap: f32 = 8;

/// Edit-buffer size for short identifier fields (param names, type
/// names, flow refs). Comfortably above any realistic identifier.
const ident_buf_len: usize = 128;
const IdentBuf = [ident_buf_len:0]u8;

/// Edit-buffer size for a literal value (a `default` or a `binding`).
const value_buf_len: usize = 256;
const ValueBuf = [value_buf_len:0]u8;

/// Whether a recorded pin carries data (a `flow_io.Edge` endpoint) or
/// execution flow (a `flow_io.ExecEdge` endpoint). Authoring keeps the
/// two namespaces disjoint: a data drag only resolves to data pins, an
/// exec drag only to exec pins, and a mixed drag (exec→data or vice
/// versa) is rejected. Without this flag `handleLinkCreate` couldn't
/// tell a control edge from a wire when both endpoints live in the one
/// `s.pins` registry (issue #196).
const PinKind = enum { data, exec };

/// One rendered pin on the canvas. The node editor only knows pins by
/// their opaque `u64` id; `pinId` is a one-way hash, so to map an
/// accepted/deleted link back to a `flow_io.Edge` (or `ExecEdge`) we
/// record every pin we draw this frame and look the endpoint ids up
/// here.
const PinEntry = struct {
    /// Editor pin id — what `pinId(...)` / `execPinId(...)` produced.
    id: u64,
    node_id: u32,
    /// Pin name. Borrowed from `doc` — only valid for the current frame.
    /// For an exec-IN anchor (a bare node target with no `to_pin`) this
    /// is the empty string.
    name: []const u8,
    dir: PinDir,
    /// Data vs exec namespace — gates cross-wiring (issue #196).
    kind: PinKind = .data,
};

/// One cached resolution of a `Subflow` node's referenced flow (issue
/// #161). A `Subflow` node only stores the *name* of the flow it
/// references; to draw the node's true pin interface — one input pin
/// per declared `param`, one output pin per `Output` node — the editor
/// must load and parse the referenced `.flow.jsonc` file.
///
/// Resolution is keyed by `(name, mtime, size)`: the parse is reused
/// across frames and only redone when the referenced file changes on
/// disk, mirroring the mtime-keyed re-derivation pattern `flow.zig`
/// uses for its `.zig` source. Size is part of the key so a same-tick
/// rewrite that doesn't advance the mtime still re-resolves. `doc` is
/// null when the referenced file is
/// missing or unparseable — the renderer then falls back to the
/// binding-derived input pins and shows an "unresolved" hint.
///
/// Within a single frame the resolution (stat + reuse-or-parse) for a
/// given name runs at most once: the first `resolveSubflow` for a name
/// stamps `frame_seq` with the current frame counter, and subsequent
/// nodes that reference the same flow that frame skip the `stat`
/// syscall entirely and reuse the entry. So N nodes referencing one
/// flow cost one stat per frame, not N.
const ResolvedFlow = struct {
    /// The referenced flow's name (the `flow` field of the Subflow
    /// node). Owned by the enclosing `FlowDocState.arena`.
    name: []const u8,
    /// Last-observed mtime of the referenced file (nanoseconds since
    /// the unix epoch). Null when the file could not be stat'd.
    mtime: ?i96 = null,
    /// Last-observed byte size of the referenced file. Compared
    /// alongside `mtime`: a same-tick rewrite (two writes within one
    /// filesystem mtime granule, or a tool that preserves mtime) leaves
    /// `mtime` unmoved but almost always changes the content length, so
    /// pairing the two catches stale parses `mtime` alone would miss.
    /// Null when the file could not be stat'd.
    size: ?u64 = null,
    /// The parsed referenced flow, or null when it could not be loaded
    /// or parsed. Owns its own arena — freed + replaced on re-resolve
    /// and on tab close.
    doc: ?flow_io.FlowDoc = null,
    /// True when `doc` is the result of a *successful* load. Only then
    /// are `mtime` + `size` authoritative: a failed load leaves this
    /// false so the next frame re-attempts the load instead of trusting
    /// a stale mtime/size (a fixed-contents file must recover even if
    /// its mtime hasn't moved).
    loaded_ok: bool = false,
    /// The `FlowDocState.frame_seq` value at which this entry was last
    /// resolved. Used to collapse repeated resolutions of the same flow
    /// within one frame to a single `stat`.
    last_frame: u64 = 0,

    fn deinit(self: *ResolvedFlow) void {
        if (self.doc) |*d| {
            d.deinit();
            self.doc = null;
        }
        self.loaded_ok = false;
    }
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
    /// Set on the same frame that seeds positions; consumed the frame
    /// *after* so `navigateToContent` runs once node sizes are known
    /// (sizes come from `beginNode`/`endNode`; the layout frame sets
    /// positions only). Without this, opening a flow whose nodes sit
    /// far from the editor's default view (e.g. positions near `0,0`
    /// when the default view is far away, or vice-versa) renders an
    /// apparently-empty canvas — the nodes are there, just off-screen.
    needs_fit_to_content: bool = false,
    /// Every pin drawn on the canvas this frame, rebuilt at the top of
    /// `renderCanvas`. Used to resolve a node-editor pin id back to its
    /// `(node_id, name, dir)` when authoring or deleting edges. Backed
    /// by the doc arena; entries borrow `doc` node/pin strings so they
    /// are only valid within the frame that filled the list.
    pins: std.ArrayList(PinEntry) = .empty,
    /// Cache of referenced flows resolved for `Subflow` nodes (issue
    /// #161), keyed by name. Each entry owns a `flow_io.FlowDoc` arena;
    /// `deinit` frees every one. Small — one entry per distinct
    /// referenced flow name across all the tab's Subflow nodes.
    resolved: std.ArrayList(ResolvedFlow) = .empty,
    /// Monotonic frame counter, bumped once per `render`. `resolveSubflow`
    /// stamps each cache entry with the frame it last resolved at, so the
    /// same referenced flow is stat'd at most once per frame regardless of
    /// how many `Subflow` nodes point at it.
    frame_seq: u64 = 0,
    /// Result of the most recent `Subflow` reference-cycle check
    /// (issue #159). Null until the first check runs. A `clean` status
    /// is kept (rather than null) so the UI can tell "checked, fine"
    /// apart from "not yet checked". Owns its own arena. The report's
    /// `read_files` field carries the on-disk stamps the check ran
    /// against — `refreshCycleCheck` re-runs when any of them changes.
    cycle_report: ?flow_cycle.Report = null,
    /// Snapshot of the `Subflow` `flow_ref` set the last cycle check
    /// ran against, encoded by `buildRefsFingerprint` (each ref
    /// length-prefixed so the encoding is unambiguous for any ref
    /// content). When the live set diverges from this the check is
    /// re-run. Owned by the child/GPA allocator
    /// (`arena.child_allocator`), *not* the tab arena: it is replaced on
    /// every actual re-check, and arena `free` is a no-op, so persisting
    /// it on the arena would leak the prior snapshot on each
    /// invalidation. `refreshCycleCheck` frees the previous snapshot
    /// before storing a new one; `deinit` frees the last one.
    cycle_refs_snapshot: []const u8 = "",
    /// Count of execution-flow arrows emitted by `renderExecEdges` on
    /// the most recent frame (issue #172). Public so the gui-test
    /// runner can assert on the canvas state without poking into the
    /// node editor's opaque link store. Re-set to zero at the top of
    /// `renderExecEdges` so a flow that loses its last command pair
    /// reports zero rather than a stale prior frame's count.
    exec_links_last_frame: usize = 0,

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
        // Free every resolved-flow arena before the state's own arena
        // goes away (the `ResolvedFlow` list lives off `allocator`, its
        // `name` strings off `arena`).
        for (self.resolved.items) |*r| r.deinit();
        self.resolved.deinit(allocator);
        self.editor.destroy();
        if (self.cycle_report) |*r| r.deinit();
        // The snapshot lives on the child/GPA allocator (see the field
        // doc), so it must be freed explicitly — the arena does not own
        // it. Freeing an empty `""` slice is a safe no-op.
        if (self.cycle_refs_snapshot.len > 0) {
            self.arena.child_allocator.free(self.cycle_refs_snapshot);
        }
        self.doc.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

/// Build the bare-name `Subflow` reference list of the open document
/// (its live, possibly-unsaved state). Empty refs are skipped here so
/// the snapshot and the analysis input agree. Owned by `a`.
fn liveSubflowRefs(a: std.mem.Allocator, doc: flow_io.FlowDoc) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (doc.nodes) |n| {
        if (n.kind != .subflow) continue;
        if (n.flow_ref.len == 0) continue;
        try out.append(a, n.flow_ref);
    }
    return out.toOwnedSlice(a);
}

/// The flow document's effective name — the explicit top-level `name`
/// or, failing that, the filename basename (RFC §5, mirrored by
/// `flow_io.displayNameFromPath`).
fn effectiveName(s: *const FlowDocState) []const u8 {
    return s.doc.name orelse s.display_name;
}

/// True when any `.flow.jsonc` file the last check read has changed on
/// disk since — a different `mtime`, a different `size`, or a file that
/// is now stat-able when it wasn't (or vice versa). An on-disk edit to
/// a *referenced* flow can create or break a transitive cycle the open
/// document's own `Subflow` reference set never reveals, so the banner
/// must not trust a cached "clean" once any referenced file moves.
///
/// Also re-triggers when a reference target the last check could *not*
/// read becomes readable: a previously-missing `.flow.jsonc` appearing
/// on disk, or a parse-failed one whose content changed. `read_files`
/// can never catch these — it only stamps files that were successfully
/// read — so `unresolved_targets` is checked alongside it. A target
/// appearing can newly resolve a reference (and even introduce a
/// cycle), so the stale "unresolved" banner must not survive it.
///
/// Cheap: one `statFile` per tracked path (read files plus unresolved
/// targets). A flow graph references a handful of files at most, so this
/// stays well within an immediate-mode frame budget.
pub fn referencedFilesChanged(report: *const flow_cycle.Report) bool {
    const io = io_global.io();
    for (report.read_files) |f| {
        const st = std.Io.Dir.cwd().statFile(io, f.path, .{}) catch {
            // The file is no longer stat-able. Stale only if it *was*
            // stat-able at check time.
            if (f.mtime_ns != null or f.size != null) return true;
            continue;
        };
        // The file became stat-able since the check, or its mtime/size
        // moved — either way the cached result may be stale.
        if (f.mtime_ns == null or f.size == null) return true;
        if (f.mtime_ns.? != st.mtime.nanoseconds) return true;
        if (f.size.? != st.size) return true;
    }
    // A target the check could not read may now be readable.
    for (report.unresolved_targets) |t| {
        const st = std.Io.Dir.cwd().statFile(io, t.path, .{}) catch {
            // Still not stat-able. Stale only if a (broken) file *was*
            // present there at check time and has since vanished.
            if (t.mtime_ns != null or t.size != null) return true;
            continue;
        };
        // A previously-missing target now exists, or a parse-failed
        // one's mtime/size moved (its content may now parse) — either
        // way a reference that didn't resolve might now resolve.
        if (t.mtime_ns == null or t.size == null) return true;
        if (t.mtime_ns.? != st.mtime.nanoseconds) return true;
        if (t.size.? != st.size) return true;
    }
    return false;
}

/// Build the invalidation fingerprint of the open document's live
/// `Subflow` `flow_ref` set. `refreshCycleCheck` compares this against
/// the stored `cycle_refs_snapshot` to decide whether the reference set
/// changed since the last check.
///
/// Each ref is **length-prefixed** — its byte length as a fixed-width
/// little-endian `u64`, then the raw bytes — so the encoding is
/// unambiguous for any `flow_ref` content. A plain separator (newline,
/// NUL, …) is not enough: a `flow_ref` is a JSON string and may contain
/// that separator byte itself, so one ref `"a\nb"` would otherwise
/// encode the exact same bytes as two refs `"a"`, `"b"` and the check
/// would wrongly skip re-analysis. With the length prefix no
/// concatenation of one ref set can collide with a different set.
///
/// Empty refs are skipped — same filter as `liveSubflowRefs`, so the
/// fingerprint and the analysis input agree. Owned by `a`.
pub fn buildRefsFingerprint(a: std.mem.Allocator, doc: flow_io.FlowDoc) !std.ArrayList(u8) {
    var snap: std.ArrayList(u8) = .empty;
    errdefer snap.deinit(a);
    for (doc.nodes) |n| {
        if (n.kind != .subflow or n.flow_ref.len == 0) continue;
        var len_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &len_buf, n.flow_ref.len, .little);
        try snap.appendSlice(a, &len_buf);
        try snap.appendSlice(a, n.flow_ref);
    }
    return snap;
}

/// Re-run the `Subflow` reference-cycle check if the live reference set
/// has changed since the last run, if any referenced flow file changed
/// on disk, or if no check has run yet. Resolves referenced flows from
/// the open document's own `scripts/flows/` directory — derived from the
/// document path's parent.
///
/// Cheap to call every frame: when nothing changed this only builds and
/// compares a short length-prefixed fingerprint and stats a handful of
/// files.
fn refreshCycleCheck(s: *FlowDocState) void {
    // The tab arena (`ArenaAllocator.free` is a no-op) is never used
    // for the cycle-check scratch *or* the persisted snapshot — both
    // live on the child/GPA allocator. Per-frame scratch is freed
    // before this returns; the single stored snapshot is freed and
    // replaced on each actual re-check (and on `deinit`). Keeping it
    // off the arena means an editing session does not accumulate one
    // dead snapshot per invalidation.
    const child = s.arena.child_allocator;

    // Build a length-prefixed fingerprint of the current Subflow refs
    // on the child allocator so it is reclaimed every frame. The
    // length prefix keeps the encoding unambiguous for any ref content
    // (see `buildRefsFingerprint`).
    var snap = buildRefsFingerprint(child, s.doc) catch return;
    defer snap.deinit(child);

    // Skip the re-analysis only when a check has run, the open flow's
    // own reference set is unchanged, *and* none of the referenced
    // files moved on disk. The disk-stamp check guards against a stale
    // "clean" banner when a transitively-referenced flow is edited.
    if (s.cycle_report) |*report| {
        if (std.mem.eql(u8, snap.items, s.cycle_refs_snapshot) and
            !referencedFilesChanged(report)) return;
    }

    // Reference set changed, a referenced file changed, or first run —
    // re-analyze.
    var refs_arena = std.heap.ArenaAllocator.init(child);
    defer refs_arena.deinit();
    const refs = liveSubflowRefs(refs_arena.allocator(), s.doc) catch return;

    // The flow file lives at `<flows_dir>/<name>.flow.jsonc`; the
    // referenced flows resolve from the same directory.
    const flows_dir = std.fs.path.dirname(s.path) orelse ".";

    const new_report = flow_cycle.analyze(
        child,
        effectiveName(s),
        refs,
        flows_dir,
        s.path,
    ) catch |err| {
        // The check failed (e.g. OOM, a filesystem error). Drop the
        // stale report so the banner reflects "not checked" rather than
        // a now-incorrect cycle/unresolved status, and clear the
        // snapshot so the next frame retries instead of trusting a
        // result that was never produced.
        std.log.err("flow: cycle check failed: {s}", .{@errorName(err)});
        if (s.cycle_report) |*old| old.deinit();
        s.cycle_report = null;
        if (s.cycle_refs_snapshot.len > 0) child.free(s.cycle_refs_snapshot);
        s.cycle_refs_snapshot = "";
        return;
    };

    // Duplicate the snapshot onto the child/GPA allocator *before*
    // committing the new report — if the dup fails we keep the old
    // report/snapshot pair consistent (rather than leaving an empty
    // snapshot that would re-run the disk-backed analysis every
    // subsequent frame). The snapshot stays off the tab arena so the
    // prior one can actually be reclaimed below.
    const new_snapshot = child.dupe(u8, snap.items) catch {
        std.log.err("flow: cycle snapshot alloc failed; keeping prior result", .{});
        var report = new_report;
        report.deinit();
        return;
    };

    if (s.cycle_report) |*old| old.deinit();
    // Free the previous snapshot before replacing it — without this the
    // child allocator would accumulate one dead snapshot per re-check.
    if (s.cycle_refs_snapshot.len > 0) child.free(s.cycle_refs_snapshot);
    s.cycle_report = new_report;
    s.cycle_refs_snapshot = new_snapshot;
}

/// Public entry point — `OpenTab.render` dispatches here.
pub fn render(s: *FlowDocState, app: *App) void {
    // Advance the per-frame counter so `resolveSubflow` stats each
    // distinct referenced flow at most once this frame.
    s.frame_seq +%= 1;

    zgui.text("Flow: {s}", .{s.display_name});
    if (s.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
    }
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) saveFlowDoc(s, app);
    zgui.sameLine(.{});
    zgui.textDisabled("(.flow.jsonc — flat graph editor)", .{});

    // Re-run the Subflow reference-cycle check whenever the live set of
    // `Subflow` references changes (issue #159). Cheap when unchanged.
    refreshCycleCheck(s);
    renderCycleBanner(s);

    zgui.separator();

    const total_w = zgui.getContentRegionAvail()[0];
    const canvas_w = @max(160.0, total_w - inspector_w - split_gap);

    if (zgui.beginChild("##flowdoc_canvas", .{ .w = canvas_w, .h = 0 })) {
        renderCanvas(s, app.allocator);
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

/// Draw a warning banner when the most recent `Subflow` reference
/// check found a cycle or an unresolved reference. A clean (or
/// not-yet-run) check draws nothing — the editor stays quiet when the
/// flow graph is fine (issue #159).
fn renderCycleBanner(s: *FlowDocState) void {
    const report = &(if (s.cycle_report) |*r| r else return).*;
    // `chain_text` was rendered once when the report was generated
    // (`flow_cycle.analyze`) — the banner just displays it, so the tab
    // arena doesn't grow per frame. A blank string only happens on a
    // formatting-alloc failure inside `analyze`; show a placeholder.
    const text = if (report.chain_text.len > 0) report.chain_text else "?";
    switch (report.status) {
        .clean => return,
        .cycle => {
            zgui.textColored(
                .{ 1.0, 0.35, 0.35, 1.0 },
                "Subflow reference cycle: {s}",
                .{text},
            );
            zgui.textDisabled(
                "A cyclic flow graph is rejected by codegen at build time.",
                .{},
            );
        },
        .unresolved => {
            zgui.textColored(
                .{ 1.0, 0.65, 0.2, 1.0 },
                "Unresolved Subflow reference: {s}",
                .{text},
            );
            zgui.textDisabled(
                "The last flow in the chain has no scripts/flows/<name>.flow.jsonc file.",
                .{},
            );
        },
        .parse_failed => {
            zgui.textColored(
                .{ 1.0, 0.65, 0.2, 1.0 },
                "Broken Subflow reference: {s}",
                .{text},
            );
            zgui.textDisabled(
                "The last flow in the chain has a .flow.jsonc file that failed to parse — fix that file.",
                .{},
            );
        },
        .duplicate_name => |dup| {
            zgui.textColored(
                .{ 1.0, 0.35, 0.35, 1.0 },
                "Duplicate flow name: two flows share the name '{s}' — rename one.",
                .{dup.name},
            );
            zgui.textDisabled("  {s}", .{dup.path_a});
            zgui.textDisabled("  {s}", .{dup.path_b});
            zgui.textDisabled(
                "A flow's registry name is its top-level `name`, else its filename. " ++
                    "codegen rejects two flows resolving to the same name.",
                .{},
            );
        },
    }
}

// ─── Canvas ─────────────────────────────────────────────────────────────

fn renderCanvas(s: *FlowDocState, allocator: std.mem.Allocator) void {
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
        // NB: `needs_layout` is *not* cleared here. Comment frames seed
        // their persisted `x`/`y` off the same flag inside `renderComments`
        // (called further down), so clearing it before that runs would let
        // the editor's default position be read back and stomp the stored
        // geometry on the seeding frame (labelle-gui#188). The flag is
        // cleared *after* `renderComments`.
        // Defer the viewport fit to the next frame — `navigateToContent`
        // needs node *sizes*, which the editor only learns once
        // `beginNode`/`endNode` have run.
        if (s.doc.nodes.len > 0 or s.doc.comments.len > 0) s.needs_fit_to_content = true;
    } else if (s.needs_fit_to_content) {
        ne.navigateToContent(0.0);
        s.needs_fit_to_content = false;
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
    //
    // Command vs reporter visual (RFC §6 — phase 4 item 6): commands
    // are rectangular (small corner radius), reporters rounded (large
    // corner radius). The Event node gets a third treatment — the same
    // rectangular command shape with a warm border color to read as the
    // trigger. Command nodes also carry execution-flow anchors (top
    // exec-in, bottom exec-out — `Event` is exec-out only since it's the
    // trigger); see `renderNodeBody`. Synthetic exec arrows are emitted
    // below the data-edge loop based on the topo order of the command
    // spine (RFC §6 deferral, issue #172).
    // Comment / group frames (labelle-gui#188) — emitted *before* the
    // nodes so the editor draws them behind. Purely cosmetic; ignored by
    // codegen. Seeds comment positions off `needs_layout`, so it must run
    // while the flag is still set.
    renderComments(s);

    // The layout/seed handoff is complete for *both* nodes and comment
    // frames; from the next frame the editor owns positions and we only
    // read them back. Clearing here (not right after the node seed above)
    // is what lets `renderComments` apply persisted comment geometry on the
    // seeding frame instead of the editor's default (labelle-gui#188).
    s.needs_layout = false;

    for (s.doc.nodes) |n| {
        const visual = nodeVisual(n);
        ne.pushStyleVar1f(.node_rounding, visual.rounding);
        ne.pushStyleColor(.node_border, visual.border);
        defer {
            ne.popStyleColor(1);
            ne.popStyleVar(1);
        }
        ne.beginNode(@intCast(n.id));
        renderNodeBody(s, allocator, n);
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

    // Derived execution-flow arrows (issue #172, RFC-FLOW-VOCABULARY §6
    // deferral). The codegen emits node bodies in topo order over data
    // edges with document-order as the tiebreak; we mirror that algorithm
    // locally (see `topoCommandOrder`) and draw a thick white arrow
    // between consecutive command-kind nodes in that order. The arrows
    // are *derived* — there's no on-disk `exec_edges` block — so any
    // re-route / delete gesture on one is rejected (exec pin ids are not
    // recorded in `s.pins`, and exec link ids don't match any
    // `doc.edges[i]` — both gesture paths bottom out in "unknown id" and
    // a graceful reject).
    renderExecEdges(s, allocator);

    // Explicit control-flow arrows (issues #193, #194). The on-disk
    // `exec_edges` block wires a `Branch`'s `then`/`else` or a loop's
    // `body` to the entered node. Drawn after the derived spine so a
    // target node that is an explicit exec-edge destination shows the
    // real branch/loop arrow instead of (or in addition to) the linear
    // derived arrow `renderExecEdges` would otherwise imply.
    renderExplicitExecEdges(s);

    // Edge authoring (issue #158) — turn a pin drag into a new
    // `flow_io.Edge`, re-route an existing edge's endpoint, or a delete
    // gesture into an edge removal. All gestures are inspected *after*
    // nodes and links are emitted so the editor has the full pin set for
    // this frame. `handleLinkCreate` also covers re-routing — see its
    // doc comment for why both ride the same create query.
    handleLinkCreate(s);
    handleLinkDelete(s);
}

/// Compute and draw execution-flow arrows for the open document
/// (issue #172). Re-run unconditionally each frame — the cost is
/// O(N + E) over the small command graph, and `ne.link` dedupes
/// repeated ids across frames so there's no flicker.
fn renderExecEdges(s: *FlowDocState, allocator: std.mem.Allocator) void {
    s.exec_links_last_frame = 0;
    const order = topoCommandOrder(s, allocator) catch |err| {
        // A cycle in the data edges or an OOM scratch alloc — neither
        // is fatal for the canvas. Skip the exec layer this frame; the
        // data edges and the nodes themselves still rendered above.
        // TODO #172 follow-up: surface cycle status in the canvas
        // banner the same way `cycle_report` does for Subflow refs.
        std.log.debug("flow: exec topo skipped: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(order);

    if (order.len < 2) return;
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const from = order[i - 1];
        const to = order[i];
        // Reconcile with explicit control flow (issues #193, #194): a
        // node that is the *target* of an `exec_edge` is entered by a
        // branch/loop arrow, not by the linear command spine — drawing a
        // derived arrow into it from its topo predecessor would
        // double/contradict the control flow. Suppress it; the explicit
        // arrow is drawn by `renderExplicitExecEdges`. (Branch/loop nodes
        // themselves are `.other`, already off the command spine, so
        // their outgoing flow never appears here.)
        if (isExplicitExecTarget(s.doc.exec_edges, to)) continue;
        const from_pin = execPinId(from, .output);
        const to_pin = execPinId(to, .input);
        _ = ne.link(
            execLinkId(from, to),
            from_pin,
            to_pin,
            .{ 1.0, 1.0, 1.0, 1.0 },
            2.5,
        );
        s.exec_links_last_frame += 1;
    }
}

/// Whether `node_id` is the target of any on-disk `exec_edge` — i.e.
/// it is entered by a `Branch`/`ForRange`/`While` control arrow rather
/// than by the linear command spine. Used to suppress a contradictory
/// derived arrow into it (issues #193, #194).
pub fn isExplicitExecTarget(exec_edges: []const flow_io.ExecEdge, node_id: u32) bool {
    for (exec_edges) |x| {
        if (x.to_node == node_id) return true;
    }
    return false;
}

/// The valid exec OUTPUT pin names for a control node, given its
/// `type_name`. A `Branch` forks `then`/`else`; the loops (`ForRange`,
/// `While`) enter their `body`. `Switch` (flow-codegen#22) is matched
/// loosely — its arm pins are `case<N>` / `default`, which a static
/// list can't enumerate, so the names are validated by prefix in
/// `execPinValidFor`. A non-control node returns an empty slice.
///
/// Kept in lockstep with the pins `renderExecOutPin` actually draws so
/// the editor never records a source pin the validator would reject.
fn controlExecPinNames(type_name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, type_name, "Branch")) return &.{ "then", "else" };
    if (std.mem.eql(u8, type_name, "ForRange")) return &.{"body"};
    if (std.mem.eql(u8, type_name, "While")) return &.{"body"};
    // Time-control command nodes (flow-codegen#47, #48). Each has a single
    // `body` exec output — the codegen contract — that wires to the guarded
    // step (`Delay`'s `body` must reach a `Subflow`, enforced by codegen).
    if (std.mem.eql(u8, type_name, "Once")) return &.{"body"};
    if (std.mem.eql(u8, type_name, "Cooldown")) return &.{"body"};
    if (std.mem.eql(u8, type_name, "Delay")) return &.{"body"};
    return &.{};
}

/// Upper bound on the number of `case<N>` exec outputs a `Switch` will
/// render, so a hand-edited file with an absurd case index can't ask the
/// editor to draw thousands of pins.
const max_case_outputs: u32 = 64;

/// Static `case0`..`case<max_case_outputs-1>` pin-name literals. Built at
/// comptime so each rendered/recorded `case<N>` pin name is a 'static
/// slice that outlives the frame — `recordExecOutPin` borrows the name
/// into the pin registry, so a per-frame formatted string would dangle
/// (mirrors the `arg_pin_names` static table the Call node uses).
const case_pin_names: [max_case_outputs][]const u8 = blk: {
    @setEvalBranchQuota(max_case_outputs * 2000);
    var names: [max_case_outputs][]const u8 = undefined;
    for (0..max_case_outputs) |i| {
        names[i] = std.fmt.comptimePrint("case{d}", .{i});
    }
    break :blk names;
};

/// Parse a `case<N>` exec-pin name to its index `N`, or null if `pin`
/// isn't a well-formed `case<N>` name (`default`, `then`, garbage). The
/// digit run must be non-empty and all-decimal — matching the shape
/// `execPinValidFor` accepts. Overflow (an absurdly long digit run)
/// yields null rather than wrapping.
pub fn caseIndexOf(pin: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, pin, "case")) return null;
    const digits = pin[4..];
    if (digits.len == 0) return null;
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// How many `case<N>` exec outputs a `Switch` node should render, given
/// the document's exec edges. A Switch's cases are dynamic, so we can't
/// statically enumerate them; instead we derive the count from which
/// `case<N>` arms are already wired *from this node*, then add one spare
/// slot so a fresh (or just-extended) Switch is always wireable.
///
/// Rule: count = (highest wired `case<N>` index + 1) + 1 spare. The
/// rendered case pins are then `case0` .. `case<count-1>`, plus a
/// `default` the caller always draws. Consequences:
///   - No exec edges → count 1 → renders `case0` (the spare) + default,
///     so a brand-new Switch is immediately wireable.
///   - `case0` + `case2` wired (sparse) → highest is 2 → count 4 →
///     renders `case0`,`case1`,`case2` (filling the gap) + `case3`
///     (spare) + default.
/// Bounded by `max_case_outputs` so a hand-edited file with an absurd
/// index can't ask the editor to draw thousands of pins.
pub fn switchCaseOutputCount(node_id: u32, exec_edges: []const flow_io.ExecEdge) u32 {
    var highest: ?u32 = null;
    for (exec_edges) |x| {
        if (x.from_node != node_id) continue;
        const idx = caseIndexOf(x.from_pin) orelse continue;
        if (highest == null or idx > highest.?) highest = idx;
    }
    // Saturating adds: a hand-edited `case<N>` pin can parse to a huge
    // index (execPinValidFor accepts any `case<digits>`), and an
    // unchecked `+ 1` would panic in safe builds before the clamp runs
    // (bugbot). `+|` saturates at u32 max, then `@min` clamps to the cap.
    const wired_span: u32 = if (highest) |h| h +| 1 else 0;
    const count = wired_span +| 1; // + one spare empty case slot
    return @min(count, max_case_outputs);
}

/// Upper bound on the number of `arg<N>` data inputs a variadic reporter
/// (`Concat` / `Format`, flow-codegen#26) will render, so a hand-edited
/// file with an absurd arg index can't ask the editor to draw thousands
/// of pins.
const max_arg_inputs: u32 = 64;

/// Static `arg0`..`arg<max_arg_inputs-1>` pin-name literals. Built at
/// comptime so each rendered/recorded `arg<N>` pin name is a 'static
/// slice that outlives the frame — `recordPin` borrows the name into the
/// pin registry, so a per-frame formatted string would dangle (mirrors
/// the `case_pin_names` table the Switch node uses, and the inline
/// `arg0..arg15` table the CustomNode renderer uses).
const var_arg_pin_names: [max_arg_inputs][]const u8 = blk: {
    @setEvalBranchQuota(max_arg_inputs * 2000);
    var names: [max_arg_inputs][]const u8 = undefined;
    for (0..max_arg_inputs) |i| {
        names[i] = std.fmt.comptimePrint("arg{d}", .{i});
    }
    break :blk names;
};

/// Parse an `arg<N>` data-pin name to its index `N`, or null if `pin`
/// isn't a well-formed `arg<N>` name. The digit run must be non-empty
/// and all-decimal; overflow yields null rather than wrapping. Mirrors
/// `caseIndexOf`'s shape for the variadic reporters.
pub fn argIndexOf(pin: []const u8) ?u32 {
    if (!std.mem.startsWith(u8, pin, "arg")) return null;
    const digits = pin[3..];
    if (digits.len == 0) return null;
    // Digits-only — `parseInt` would otherwise accept a leading `+`
    // (`arg+1` → 1). Matches `caseIndexOf`/codegen's `isCaseExecPin`
    // strictness (gemini #207).
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(u32, digits, 10) catch null;
}

/// How many `arg<N>` data inputs a variadic reporter (`Concat` /
/// `Format`, flow-codegen#26) should render, given the document's data
/// edges. The arg count is dynamic — codegen joins however many are
/// wired — so we can't statically enumerate them; instead we derive the
/// count from which `arg<N>` pins already have an incoming data edge
/// *into this node*, then add one spare slot so a fresh (or
/// just-extended) node is always wireable.
///
/// Rule: count = (highest wired `arg<N>` index + 1) + 1 spare. The
/// rendered arg pins are then `arg0` .. `arg<count-1>`. Consequences:
///   - No data edges → count 1 → renders `arg0` (the spare), so a
///     brand-new `Concat`/`Format` is immediately wireable.
///   - `arg0` + `arg2` wired (sparse) → highest is 2 → count 4 →
///     renders `arg0`,`arg1`,`arg2` (filling the gap) + `arg3` (spare).
/// Bounded by `max_arg_inputs` so a hand-edited file with an absurd
/// index can't ask the editor to draw thousands of pins.
pub fn varArgInputCount(node_id: u32, edges: []const flow_io.Edge) u32 {
    var highest: ?u32 = null;
    for (edges) |e| {
        if (e.to_node != node_id) continue;
        const idx = argIndexOf(e.to_pin) orelse continue;
        highest = if (highest) |h| @max(h, idx) else idx;
    }
    // Saturating adds mirror `switchCaseOutputCount`: a hand-edited
    // `arg<N>` pin can parse to a huge index, and an unchecked `+ 1`
    // would panic in safe builds before the clamp runs.
    const wired_span: u32 = if (highest) |h| h +| 1 else 0;
    const count = wired_span +| 1; // + one spare empty arg slot
    return @min(count, max_arg_inputs);
}

/// Whether `pin` is a legal exec-output pin name on a node of
/// `type_name`. Branch/loop pins are matched against
/// `controlExecPinNames`; `Switch` arm pins (`case<N>` / `default`)
/// are matched by shape so the editor can author a control edge from a
/// switch arm whose index it doesn't statically know
/// (flow-codegen#22).
fn execPinValidFor(type_name: []const u8, pin: []const u8) bool {
    for (controlExecPinNames(type_name)) |name| {
        if (std.mem.eql(u8, name, pin)) return true;
    }
    if (std.mem.eql(u8, type_name, "Switch")) {
        if (std.mem.eql(u8, pin, "default")) return true;
        if (std.mem.startsWith(u8, pin, "case") and pin.len > 4) {
            for (pin[4..]) |c| if (!std.ascii.isDigit(c)) return false;
            return true;
        }
    }
    return false;
}

/// Whether a node is a *control* node — the only legal SOURCE of an
/// `ExecEdge` (a `Branch`, `ForRange`, `While`, or `Switch`). These are
/// all `.other`-kind nodes distinguished by `type_name`. Mirrors the
/// set flow-codegen's `validate` recognises as exec-edge sources.
fn isControlNode(n: flow_io.Node) bool {
    if (n.kind != .other) return false;
    return controlExecPinNames(n.type_name).len > 0 or
        std.mem.eql(u8, n.type_name, "Switch");
}

/// Why a proposed `ExecEdge` is illegal — surfaced so `handleExecLink`
/// can reject the drag with the right visual feedback and a log line.
const ExecEdgeError = error{
    /// The source node isn't a `Branch`/`ForRange`/`While`/`Switch`, or
    /// the named exec pin doesn't exist on it.
    NotAControlSource,
    /// The target is already the exec-target of another edge —
    /// flow-codegen enforces at-most-one exec parent per node, so a
    /// second would lower to a `MalformedFlow`.
    DuplicateExecParent,
    /// Source and target are the same node.
    SelfLoop,
    /// This exact (source pin → target) edge already exists.
    DuplicateEdge,
    /// Neither endpoint resolves to a node in the document.
    UnknownNode,
};

/// Pure validation of a candidate `ExecEdge` against the document —
/// the rules flow-codegen's `validate` enforces, applied at author
/// time so the editor never writes a flow codegen would reject as
/// `MalformedFlow` (issue #196). Takes the raw `nodes` + `exec_edges`
/// slices (not `FlowDocState`) so it is trivially unit-testable.
///
///   (a) the source must be a control node (`Branch`/`ForRange`/
///       `While`/`Switch`) carrying a valid exec pin `from_pin`,
///   (b) no self-loop (`from_node` != `to_node`),
///   (c) at-most-one exec parent: `to_node` must not already be the
///       target of another exec edge,
///   (d) no duplicate of an identical existing exec edge.
///
/// Returns void on a legal edge; an `ExecEdgeError` otherwise.
pub fn validateExecEdge(
    nodes: []const flow_io.Node,
    exec_edges: []const flow_io.ExecEdge,
    from_node: u32,
    from_pin: []const u8,
    to_node: u32,
) ExecEdgeError!void {
    // (b) self-loop.
    if (from_node == to_node) return error.SelfLoop;

    // (a) source must be a control node with this exec pin, and the
    // target must exist.
    var src: ?flow_io.Node = null;
    var dst_found = false;
    for (nodes) |n| {
        if (n.id == from_node) src = n;
        if (n.id == to_node) dst_found = true;
    }
    const s = src orelse return error.UnknownNode;
    if (!dst_found) return error.UnknownNode;
    if (!isControlNode(s)) return error.NotAControlSource;
    if (!execPinValidFor(s.type_name, from_pin)) return error.NotAControlSource;

    for (exec_edges) |x| {
        // (d) exact duplicate.
        if (x.from_node == from_node and
            x.to_node == to_node and
            std.mem.eql(u8, x.from_pin, from_pin)) return error.DuplicateEdge;
        // (c) at-most-one exec parent.
        if (x.to_node == to_node) return error.DuplicateExecParent;
    }
}

/// Draw the on-disk `exec_edges` as control arrows (issues #193, #194):
/// for each edge, a link from the source node's named exec-output pin
/// (`then`/`else`/`body`, drawn by `renderExecOutPin`) to the TARGET
/// node's exec-in anchor. Visually distinct from the cyan data edges:
/// a thick warm-amber arrow (versus the white derived spine and the
/// cyan data links) so control branches read at a glance. Like the
/// derived arrows these are read-only — the link ids don't match any
/// `doc.edges[i]`, so a delete/re-route gesture bottoms out in
/// "unknown id" and is gracefully rejected.
fn renderExplicitExecEdges(s: *FlowDocState) void {
    for (s.doc.exec_edges) |x| {
        const from_pin = pinId(x.from_node, x.from_pin, .output);
        const to_pin = execPinId(x.to_node, .input);
        _ = ne.link(
            explicitExecLinkId(x.from_node, x.from_pin, x.to_node),
            from_pin,
            to_pin,
            .{ 1.0, 0.65, 0.2, 1.0 },
            3.0,
        );
    }
}

/// Topologically sort the command-kind nodes (issue #172). Mirrors
/// `flow-codegen/src/codegen.zig:topoSort` so what the canvas shows
/// matches what codegen emits — but lives here, not as a runtime
/// import of `flow_codegen`, so the gui keeps its existing module
/// boundaries (codegen owns the `.flow.jsonc` → `.zig` pipeline; the
/// editor owns the canvas).
///
/// Algorithm: Kahn's, with the document-order tiebreak (within a
/// ready set, pick the smallest node id) that codegen uses. Returns
/// only command-kind ids — reporters slot into a command's data
/// inputs in the codegen lowering and don't need their own exec
/// step.
///
/// The caller frees the returned slice.
fn topoCommandOrder(s: *FlowDocState, allocator: std.mem.Allocator) ![]u32 {
    const nodes = s.doc.nodes;
    if (nodes.len == 0) return try allocator.alloc(u32, 0);

    var indeg = std.AutoHashMap(u32, usize).init(allocator);
    defer indeg.deinit();
    for (nodes) |n| try indeg.put(n.id, 0);
    for (s.doc.edges) |e| {
        const entry = indeg.getPtr(e.to_node) orelse continue;
        entry.* += 1;
    }

    var ready: std.ArrayList(u32) = .empty;
    defer ready.deinit(allocator);
    for (nodes) |n| {
        if (indeg.get(n.id).? == 0) try ready.append(allocator, n.id);
    }
    std.mem.sort(u32, ready.items, {}, std.sort.asc(u32));

    var full_order: std.ArrayList(u32) = .empty;
    defer full_order.deinit(allocator);
    try full_order.ensureTotalCapacity(allocator, nodes.len);

    while (ready.items.len > 0) {
        const next = ready.orderedRemove(0);
        try full_order.append(allocator, next);

        var added: std.ArrayList(u32) = .empty;
        defer added.deinit(allocator);
        for (s.doc.edges) |e| {
            if (e.from_node != next) continue;
            const d = indeg.getPtr(e.to_node) orelse continue;
            if (d.* > 0) {
                d.* -= 1;
                if (d.* == 0) try added.append(allocator, e.to_node);
            }
        }
        std.mem.sort(u32, added.items, {}, std.sort.asc(u32));
        for (added.items) |id| {
            var ins: usize = 0;
            while (ins < ready.items.len and ready.items[ins] < id) : (ins += 1) {}
            try ready.insert(allocator, ins, id);
        }
    }

    // A cycle leaves nodes un-emitted; fall back to document order so
    // the canvas still draws *some* exec spine and the user can see the
    // partial flow. The cycle is surfaced separately (TODO #172
    // follow-up) — silently dropping the layer would be worse.
    if (full_order.items.len != nodes.len) {
        full_order.clearRetainingCapacity();
        for (nodes) |n| try full_order.append(allocator, n.id);
    }

    // Filter down to command-kind nodes, in the topo order we just
    // computed. Reporters are filtered out — they're values inlined
    // into a command's data inputs by codegen, not exec steps.
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(allocator);
    for (full_order.items) |id| {
        for (nodes) |n| {
            if (n.id != id) continue;
            if (isCommandNode(n)) try out.append(allocator, id);
            break;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// True when a node is a command-kind (RFC §6) for exec-anchor
/// purposes. Mirrors `flow_io.NodeKind.isCommandKind` but resolves
/// `.custom_node` through the static catalog — a catalog entry with
/// `kind = .reporter` keeps its rounded silhouette and stays off the
/// exec spine, while a `.command` entry joins it. An unknown
/// `custom_name` defaults to command (matching `nodeVisual`'s neutral
/// fall-through, which uses the rectangular silhouette).
fn isCommandNode(n: flow_io.Node) bool {
    return switch (n.kind) {
        .custom_node => blk: {
            const entry = node_catalog.lookup(n.custom_name) orelse break :blk true;
            break :blk entry.kind == .command;
        },
        else => n.kind.isCommandKind(),
    };
}

/// Synthetic pin id for a node's top-center (exec-in) or
/// bottom-center (exec-out) execution-flow anchor. Disjoint from
/// `pinId`'s data-pin id space:
///
///   - data:  bits 0–29 = `wyhash(name) & 0x3FFF_FFFF`, bits 30–61 =
///     node id, bit 62 = direction, bit 63 = 0.
///   - exec:  bits 0–29 = a fixed sentinel value (`0x3EC0_EC1F` for
///     exec-in, `0x3EC0_EC07` for exec-out — both fit in 30 bits and
///     are vanishingly unlikely to match a `wyhash` output), bits
///     30–61 = node id, bit 62 = direction, bit 63 = 0.
///
/// A real pin name would have to wyhash-collide into exactly one of
/// those sentinel values to clash, which is a ~1 in 10⁹ event per
/// name; the editor's worst-case failure mode on collision is a
/// single mis-drawn exec arrow, never data corruption (the document
/// itself never references exec pin ids — they only live in the
/// editor's per-frame link table).
fn execPinId(node_id: u32, dir: PinDir) u64 {
    const marker: u64 = if (dir == .input) 0x3EC0_EC1F else 0x3EC0_EC07;
    const base: u64 = marker | (@as(u64, node_id) << 30);
    return if (dir == .output) base | (@as(u64, 1) << 62) else base;
}

/// Draw a *named* exec OUTPUT pin (`then` / `else` on a `Branch`,
/// `body` on a `ForRange` / `While`) — the source side of an on-disk
/// `exec_edge` (issues #193, #194). Distinct from `execPinId`'s
/// top/bottom command anchors: a named exec output sits inline in the
/// node body next to its label, so its id is `pinId(node, name,
/// .output)` (the loop/branch nodes carry no *data* output pin with
/// these names, so there's no clash — `ForRange.index` is the one data
/// output and is named differently).
///
/// Recorded into `s.pins` as an `.exec` output pin (issue #196) so a
/// drag *from* it is accepted as the source of a new `ExecEdge`. The
/// `.exec` tag keeps it from cross-wiring into a data input — only an
/// exec-IN anchor is a legal drop target. (Before #196 these were
/// deliberately unrecorded and thus read-only; the DERIVED #172
/// arrows remain read-only because they use `execPinId` anchors that
/// are *not* recorded as a drag source.)
fn renderExecOutPin(s: *FlowDocState, node_id: u32, name: []const u8) void {
    ne.beginPin(pinId(node_id, name, .output), .output);
    zgui.text("{s} ▸", .{name});
    ne.endPin();
    recordExecOutPin(s, node_id, name);
}

/// Synthetic link id for a derived exec arrow from `from_node`'s
/// exec-out to `to_node`'s exec-in. Lives in the link namespace
/// (bit 63 = 1) like `linkId`, hashed off the two endpoints so the
/// id is stable across frames — the node editor's internal link
/// store dedupes by id, so re-emitting the same id every frame is a
/// no-op (no flicker).
///
/// Derived from a Wyhash with a distinct seed (`0xEC1Ed6e`) from
/// `linkId`'s `0x11f0`. A collision with a data link id is harmless:
/// the user's delete gesture on an exec link routes through
/// `deleteEdgeByLinkId`, which only matches against `s.doc.edges` —
/// an unmatched id is silently rejected, which is exactly the
/// behaviour we want for a read-only derived edge.
fn execLinkId(from_node: u32, to_node: u32) u64 {
    var h = std.hash.Wyhash.init(0xEC1ED6E);
    h.update(std.mem.asBytes(&from_node));
    h.update(std.mem.asBytes(&to_node));
    return (h.final() & 0x7FFF_FFFF_FFFF_FFFF) | (@as(u64, 1) << 63);
}

/// Synthetic link id for an *explicit* exec arrow from a named exec
/// output pin (`then`/`else`/`body`) to its target node's exec-in
/// (issues #193, #194). Distinct seed from `execLinkId` so a derived
/// and an explicit arrow between the same node pair never collide on
/// one id; the `from_pin` is mixed in so a Branch's `then` and `else`
/// arrows to the *same* target stay distinct. Lives in the link
/// namespace (bit 63 = 1) like `linkId`/`execLinkId`.
fn explicitExecLinkId(from_node: u32, from_pin: []const u8, to_node: u32) u64 {
    var h = std.hash.Wyhash.init(0xE6E07);
    h.update(std.mem.asBytes(&from_node));
    h.update(from_pin);
    h.update(&[_]u8{0}); // delimiter, as in `linkId`
    h.update(std.mem.asBytes(&to_node));
    return (h.final() & 0x7FFF_FFFF_FFFF_FFFF) | (@as(u64, 1) << 63);
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
        .kind = .data,
    }) catch |err| {
        // A dropped pin can't be resolved this frame, so a drag onto it
        // silently rejects — surface the cause rather than swallowing it.
        std.log.err("flow: record pin failed: {s}", .{@errorName(err)});
    };
}

/// Record a *named* exec OUTPUT pin (`then`/`else`/`body`/`case<N>`/
/// `default`) so a drag from it is accepted as the *source* of an
/// `ExecEdge` (issue #196). Its editor id is `pinId(node, name,
/// .output)` — the same id `renderExecOutPin` draws and
/// `renderExplicitExecEdges` wires — but it's tagged `.exec` so it
/// can't be cross-wired to a data input. The borrowed `name` must
/// outlive the frame (the control-pin names are static literals).
fn recordExecOutPin(s: *FlowDocState, node_id: u32, name: []const u8) void {
    s.pins.append(s.doc.allocator(), .{
        .id = pinId(node_id, name, .output),
        .node_id = node_id,
        .name = name,
        .dir = .output,
        .kind = .exec,
    }) catch |err| {
        std.log.err("flow: record exec-out pin failed: {s}", .{@errorName(err)});
    };
}

/// Record a node's exec-IN anchor (the `▼` top-center anchor) as a
/// droppable exec *input* target so an `ExecEdge` drag can land on it
/// (issue #196). An exec target is a *bare* node ref — it has no
/// `to_pin` — so the entry's `name` is the empty string. Its id is
/// `execPinId(node, .input)`, matching the anchor `renderNodeBody`
/// draws and the target side `renderExplicitExecEdges` wires.
fn recordExecInPin(s: *FlowDocState, node_id: u32) void {
    s.pins.append(s.doc.allocator(), .{
        .id = execPinId(node_id, .input),
        .node_id = node_id,
        .name = "",
        .dir = .input,
        .kind = .exec,
    }) catch |err| {
        std.log.err("flow: record exec-in pin failed: {s}", .{@errorName(err)});
    };
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
    return edgeIndex(s, from, to) != null;
}

/// Index of the edge wiring this exact (output) → (input) pair, if any.
fn edgeIndex(s: *FlowDocState, from: PinEntry, to: PinEntry) ?usize {
    for (s.doc.edges, 0..) |e, i| {
        if (e.from_node == from.node_id and
            e.to_node == to.node_id and
            std.mem.eql(u8, e.from_pin, from.name) and
            std.mem.eql(u8, e.to_pin, to.name)) return i;
    }
    return null;
}

/// Whether `e` has `pin` as the endpoint on the side that agrees with
/// the pin's direction — an output pin matches `from`, an input pin
/// matches `to`.
fn edgeTouchesPin(e: flow_io.Edge, pin: PinEntry) bool {
    return switch (pin.dir) {
        .output => e.from_node == pin.node_id and
            std.mem.eql(u8, e.from_pin, pin.name),
        .input => e.to_node == pin.node_id and
            std.mem.eql(u8, e.to_pin, pin.name),
    };
}

/// Resolve the single edge a re-route gesture grabbed by its `pin`
/// endpoint. The node editor has no native link-reconnect gesture: a
/// re-route surfaces as a plain same-direction pin drag, so all the
/// editor reports is the *pin* the drag started on — never which link
/// on that pin the user grabbed. When the pin owns exactly one edge
/// that is unambiguous. When it owns several — fan-out from one output,
/// or fan-in into one input — the gesture genuinely can't be resolved,
/// so this returns `.ambiguous` rather than guessing and rewriting an
/// arbitrary (wrong) edge. A pin with no edge yields `.none`.
const EndpointEdge = union(enum) {
    /// No edge on this pin — a same-direction drag from it is invalid.
    none,
    /// Exactly one edge on this pin — re-route it.
    one: usize,
    /// Several edges share this pin — which one was grabbed is unknown.
    ambiguous,
};

fn edgeWithEndpoint(s: *FlowDocState, pin: PinEntry) EndpointEdge {
    var found: ?usize = null;
    for (s.doc.edges, 0..) |e, i| {
        if (!edgeTouchesPin(e, pin)) continue;
        if (found != null) return .ambiguous;
        found = i;
    }
    return if (found) |i| .{ .one = i } else .none;
}

/// Drive the node-editor create-link query. This handles both edge
/// **creation** and edge **re-routing** — `imgui-node-editor` (this
/// binding's version) has no native link-reconnect gesture, so a
/// re-route surfaces through the very same `queryNewLink` query as a
/// create, distinguished only by what the two endpoints are:
///
///   - opposite-direction pins on distinct nodes → create a fresh
///     `flow_io.Edge` (an output → input wire).
///   - same-direction pins where the drag *started* on a pin that
///     already owns an edge → re-route that edge's endpoint. The user
///     grabbed one end of an existing link (which `CreateItemAction`
///     models as a new drag starting from that pin) and dropped it on
///     another pin of the same direction; we move that endpoint.
///
/// Either way an invalid drop is rejected and leaves the document
/// unchanged. The tab is only marked dirty once a mutation commits.
fn handleLinkCreate(s: *FlowDocState) void {
    // `endCreate` must pair with EVERY `beginCreate`, not just the ones
    // that returned true. Looking at `imgui_node_editor.cpp:4736-4751`
    // (`ed::CreateItemAction::Begin`), `m_InActive` is set to `true`
    // *before* the `if (m_CurrentStage == None) return false;` — so
    // `beginCreate()` leaves the action mid-Begin regardless of return
    // value. Skipping `endCreate` then makes the next frame's
    // `beginCreate` trip its `IM_ASSERT(false == m_InActive)` and
    // SIGABRT the GUI. Defer `endCreate` first, then early-return on
    // the create-not-active path.
    const create_active = ne.beginCreate();
    defer ne.endCreate();
    if (!create_active) return;

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

    // Data and exec pins live in one registry but two namespaces: a
    // control (exec) edge can't terminate on a data pin and a data wire
    // can't terminate on an exec anchor (issue #196). A mixed-kind drag
    // is therefore always invalid — reject before either the data or the
    // exec path runs.
    if (a_pin.kind != b_pin.kind) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }

    // Both endpoints exec: this is a control-edge author/re-route. The
    // data-edge rules don't apply (an exec target is a bare node, not a
    // typed pin), so it gets its own path.
    if (a_pin.kind == .exec) {
        handleExecLinkCreate(s, a_pin, b_pin);
        return;
    }

    // Same-direction drag: not a create. If the dragged-from pin owns
    // an existing edge this is a re-route of that edge's endpoint;
    // otherwise it's an invalid create and must be rejected.
    if (a_pin.dir == b_pin.dir) {
        handleLinkReroute(s, a_pin, b_pin);
        return;
    }

    // Opposite-direction drag → create. Validate: two distinct nodes
    // and not a duplicate of an existing edge. The drag may start from
    // either end, so figure out which pin is the output.
    if (a_pin.node_id == b_pin.node_id) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }
    const out_pin = if (a_pin.dir == .output) a_pin else b_pin;
    const in_pin = if (a_pin.dir == .output) b_pin else a_pin;
    if (edgeExists(s, out_pin, in_pin)) {
        _ = ne.rejectNewItem(.{ 1.0, 0.6, 0.2, 1.0 }, 2.0);
        return;
    }
    // Wire-fit type check (RFC §2 — phase 4 item 5). When both pins
    // belong to nodes with known catalog entries, refuse a drop that
    // would wire incompatible Zig types. Unknown-type pins (e.g.
    // `Subflow`'s reflected params with no static type info) skip the
    // check and fall back to the prior behaviour — the editor never
    // blocks editing of a still-unfinished graph. The red flash on
    // refusal is the visual feedback the RFC calls for.
    if (pinsFitForWire(s, out_pin, in_pin) == .no) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }

    // `acceptNewItem` returns true on the frame the user releases the
    // drag — only then is there an edge to commit. The node editor does
    // not retain links itself: `doc.edges` is the sole source of truth,
    // re-emitted via `ne.link()` every frame. So a failed `appendEdge`
    // can't leave the canvas and the document disagreeing — the edge is
    // simply absent on the next frame's link pass. Log and move on.
    if (ne.acceptNewItem(.{ 0.3, 1.0, 0.4, 1.0 }, 2.0)) {
        appendEdge(s, out_pin, in_pin) catch |err| {
            std.log.err("flow: add edge failed: {s}", .{@errorName(err)});
        };
    }
}

/// Author a control (`ExecEdge`) edge from a named exec OUTPUT pin to a
/// node's exec-IN anchor (issue #196). Both `a_pin` and `b_pin` are
/// already known to be `.exec`-kind. A valid control edge runs from an
/// exec output (the `then`/`else`/`body`/`case<N>`/`default` source) to
/// an exec input (the `▼` anchor — a bare node target with empty
/// `name`); `validateExecEdge` then enforces the same rules
/// flow-codegen's `validate` does so the editor can never write a flow
/// codegen rejects as `MalformedFlow`.
fn handleExecLinkCreate(s: *FlowDocState, a_pin: PinEntry, b_pin: PinEntry) void {
    // An exec output → exec input is the only legal shape. Two outputs
    // or two inputs is not a create (and an exec edge has no re-route-by-
    // same-direction gesture — re-routing is delete + re-drag), so reject.
    if (a_pin.dir == b_pin.dir) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }
    const out_pin = if (a_pin.dir == .output) a_pin else b_pin;
    const in_pin = if (a_pin.dir == .output) b_pin else a_pin;

    // Enforce the flow-codegen rules at author time (control source,
    // no self-loop, at-most-one exec parent, no duplicate). On any
    // violation reject the drop and leave `exec_edges` untouched — the
    // red flash is the user-facing feedback (the editor has no toast
    // path; rejection is how every other invalid drag surfaces).
    validateExecEdge(
        s.doc.nodes,
        s.doc.exec_edges,
        out_pin.node_id,
        out_pin.name,
        in_pin.node_id,
    ) catch {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    };

    if (ne.acceptNewItem(.{ 0.3, 1.0, 0.4, 1.0 }, 2.0)) {
        appendExecEdge(s, out_pin.node_id, out_pin.name, in_pin.node_id) catch |err| {
            std.log.err("flow: add exec edge failed: {s}", .{@errorName(err)});
        };
    }
}

/// Three-valued wire-fit result so the caller can distinguish a known
/// reject from "unknown — let it through". The editor is intentionally
/// permissive: it only refuses when *both* pin types are known and the
/// pair is incompatible. A pin whose type the static catalog doesn't
/// know (e.g. a Subflow's reflected `param`) is treated as a wildcard
/// so an in-progress graph stays editable.
const WireFit = enum { yes, unknown, no };

fn pinsFitForWire(s: *FlowDocState, out_pin: PinEntry, in_pin: PinEntry) WireFit {
    const out_type = pinZigType(s, out_pin) orelse return .unknown;
    const in_type = pinZigType(s, in_pin) orelse return .unknown;
    return if (node_catalog.typesFit(out_type, in_type)) .yes else .no;
}

/// Best-effort resolution of a pin's Zig type from the document. Walks
/// the per-kind sources the catalog uses to draw the pin (event payload
/// fields for `Event` / `Emit`, the targeted variable's declared type
/// for the variable ops, the CustomNode catalog entry's pin list).
/// Returns null when no static source covers the pin — wire-fit then
/// falls back to permissive behaviour.
fn pinZigType(s: *FlowDocState, pin: PinEntry) ?[]const u8 {
    var node: ?flow_io.Node = null;
    for (s.doc.nodes) |n| {
        if (n.id == pin.node_id) {
            node = n;
            break;
        }
    }
    const n = node orelse return null;
    switch (n.kind) {
        .event => {
            if (event_catalog.lookup(n.event_ref)) |entry| {
                for (entry.fields) |f| if (std.mem.eql(u8, f.name, pin.name)) return f.type_name;
            }
            return null;
        },
        .emit => {
            if (event_catalog.lookup(n.event_ref)) |entry| {
                for (entry.fields) |f| if (std.mem.eql(u8, f.name, pin.name)) return f.type_name;
            }
            return null;
        },
        .get_variable, .set_variable, .change_variable, .has_value_variable => {
            // The variable-op pins (`value` / `by`) are typed by the
            // declared variable. `HasValueVariable.value` is always
            // `bool` per RFC §4.
            if (n.kind == .has_value_variable) return "bool";
            return lookupVariableType(s, n.variable_ref);
        },
        .custom_node => {
            if (node_catalog.lookup(n.custom_name)) |entry| {
                for (entry.pins) |p| if (std.mem.eql(u8, p.name, pin.name)) return p.type_name;
            }
            return null;
        },
        else => return null,
    }
}

/// Handle a same-direction pin drag as an edge re-route. `from_pin` is
/// the pin the drag started on (the grabbed link end); `to_pin` is
/// where it was dropped. To be a valid re-route:
///
///   - `from_pin` must own **exactly one** edge — the edge being
///     re-routed. The node editor reports only the grabbed *pin*, not
///     which link on it the user grabbed, so when the pin owns several
///     edges (fan-out from an output, fan-in into an input) the gesture
///     is ambiguous and is rejected rather than rewriting a guessed,
///     possibly wrong edge,
///   - `to_pin` must be a different pin from `from_pin`,
///   - the rewritten edge must still join two distinct nodes and not
///     duplicate another existing edge.
///
/// On a rejected drop the original edge is left untouched — we only
/// call `acceptNewItem` (which commits) for a valid re-route; every
/// other path calls `rejectNewItem`. The same validation as
/// `handleLinkCreate` therefore guards both gestures.
fn handleLinkReroute(s: *FlowDocState, from_pin: PinEntry, to_pin: PinEntry) void {
    // Dropping back on the originating pin is a no-op, not a re-route.
    if (from_pin.id == to_pin.id) {
        _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
        return;
    }
    // The grabbed pin must own exactly one edge. `.none` → nothing to
    // re-route (an invalid same-direction drag); `.ambiguous` → the pin
    // is shared by several edges and the editor can't tell us which one
    // was grabbed, so decline rather than rewrite the wrong link.
    const edge_idx = switch (edgeWithEndpoint(s, from_pin)) {
        .one => |i| i,
        .none, .ambiguous => {
            _ = ne.rejectNewItem(.{ 1.0, 0.3, 0.3, 1.0 }, 2.0);
            return;
        },
    };

    // Compute the post-reroute endpoints and validate them exactly as a
    // create would: distinct nodes, no duplicate edge.
    const e = s.doc.edges[edge_idx];
    const out_pin: PinEntry, const in_pin: PinEntry = switch (from_pin.dir) {
        // Re-routing the input side: keep `from`, move `to` to `to_pin`.
        .input => .{
            .{ .id = 0, .node_id = e.from_node, .name = e.from_pin, .dir = .output },
            to_pin,
        },
        // Re-routing the output side: keep `to`, move `from` to `to_pin`.
        .output => .{
            to_pin,
            .{ .id = 0, .node_id = e.to_node, .name = e.to_pin, .dir = .input },
        },
    };
    if (out_pin.node_id == in_pin.node_id or edgeExists(s, out_pin, in_pin)) {
        _ = ne.rejectNewItem(.{ 1.0, 0.6, 0.2, 1.0 }, 2.0);
        return;
    }

    if (ne.acceptNewItem(.{ 0.3, 1.0, 0.4, 1.0 }, 2.0)) {
        rerouteEdge(s, edge_idx, out_pin, in_pin) catch |err| {
            std.log.err("flow: reroute edge failed: {s}", .{@errorName(err)});
        };
    }
}

/// Drive the node-editor delete query — removes any edge the user
/// selected and deleted on the canvas.
fn handleLinkDelete(s: *FlowDocState) void {
    // Same asymmetry as `handleLinkCreate`: `beginDelete` leaves the
    // delete-action mid-Begin regardless of its return value, so
    // `endDelete` MUST run on every call. Defer first, then early-
    // return on the delete-not-active path. (See the
    // `imgui_node_editor.cpp` `Begin`/`End` assertions in any of the
    // ItemAction classes.)
    const delete_active = ne.beginDelete();
    defer ne.endDelete();
    if (!delete_active) return;

    var del_id: u64 = 0;
    while (ne.queryDeletedLink(&del_id, null, null)) {
        // Mutate the document first; only commit the editor's delete
        // (`acceptDeletedItem`) once the edge is actually gone, and
        // reject it otherwise — so the canvas and `doc.edges` can never
        // disagree after a failed mutation.
        //
        // `del_id` is a `linkId` captured when the link was emitted at
        // the top of this frame. `handleLinkCreate` runs *before* this
        // and can re-route an edge — which changes that edge's `linkId`
        // (the id is a hash of the edge's endpoints). So a stale
        // `del_id` may now match nothing. A no-match must be *rejected*,
        // not accepted: accepting a no-op delete would leave the edge in
        // `doc.edges` while the editor believed it gone. `false` here
        // means "no edge matched"; only `true` is a real removal.
        if (deleteLinkByLinkId(s, del_id)) |removed| {
            if (removed) {
                _ = ne.acceptDeletedItem(true);
            } else {
                ne.rejectDeletedItem();
            }
        } else |err| {
            std.log.err("flow: delete edge failed: {s}", .{@errorName(err)});
            ne.rejectDeletedItem();
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

/// Map a comment's *stable* id (`Comment.id`, labelle-gui#188) into the
/// node-editor's id namespace. Keyed by the stable id — never the slice
/// index — so deleting a non-last comment doesn't shift surviving frames
/// onto another frame's editor (drag/resize) state.
///
/// Comment frames are rendered as imgui-node-editor *group* nodes so the
/// editor drags/resizes them natively, but they're not `flow_io.Node`s —
/// they need `NodeId`s that can't collide with a real node's id
/// (`@intCast(n.id)`) OR a pin id (`pinId` packs `node_id << 30 | hash`,
/// reaching 2^40 once a node id hits ~1024). The old scheme offset comment
/// ids by 2^40, which sits *inside* that pin space and collided in flows
/// with ~1024+ nodes (labelle-gui#203). Instead, comments now draw their
/// id from the SAME counter as nodes (`nextNodeId`/`max_node_id`), so the
/// identity map below is both small (below the 2^30 pin floor) and unique
/// against node ids by construction — no separate region, no collision.
pub fn commentNodeId(comment_id: u32) u64 {
    return @as(u64, comment_id);
}

pub const PinDir = enum { input, output };

/// A frame-scoped set of pin names, used to de-duplicate the pins a
/// `Subflow` node emits within one direction. Keyed by the name bytes;
/// keys borrow the referenced doc's storage (valid for the frame) so
/// nothing is duped into the set.
const PinNameSet = std.StringHashMap(void);

/// Deterministic global pin id from a node id, pin name, and
/// direction. Layout: bits 0–29 a name hash, bits 30–61 the node id,
/// bit 62 the direction (set for outputs). Bit 63 is left clear so the
/// whole pin-id space stays disjoint from link ids (`linkId` always
/// sets bit 63). Collisions within the name-hash bits are astronomically
/// unlikely and only cost a mis-drawn link, never data loss.
pub fn pinId(node: u32, name: []const u8, dir: PinDir) u64 {
    var h = std.hash.Wyhash.init(node);
    h.update(name);
    const base = (h.final() & 0x3FFF_FFFF) | (@as(u64, node) << 30);
    return if (dir == .output) base | (@as(u64, 1) << 62) else base;
}

/// The editor's default comment-frame tint when a `Comment` carries no
/// explicit `color` — a soft, low-alpha amber so the frame reads as an
/// annotation behind the nodes without obscuring them.
const default_comment_fill: [4]f32 = .{ 0.95, 0.80, 0.35, 0.12 };
const default_comment_border: [4]f32 = .{ 0.95, 0.80, 0.35, 0.45 };

/// Unpack a packed `0xRRGGBBAA` color into a normalized `[4]f32` rgba.
fn unpackRgba(packed_rgba: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((packed_rgba >> 24) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((packed_rgba >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((packed_rgba >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(packed_rgba & 0xFF)) / 255.0,
    };
}

/// Render every comment / group frame as an imgui-node-editor *group*
/// node (labelle-gui#188). Group nodes are translucent, labeled,
/// resizable rectangles the editor draws *behind* ordinary nodes and
/// drags/resizes natively — exactly the v1 "cosmetic backdrop" shape.
///
/// Called before the node loop in `renderCanvas` so the groups are
/// emitted first (and so drawn behind). Position is seeded from each
/// `Comment`'s `x`/`y` on the layout frame, then read back every frame
/// (along with the live group size) so a drag or resize updates the
/// `Comment` and marks the doc dirty — a Save then persists the change.
fn renderComments(s: *FlowDocState) void {
    for (s.doc.comments) |*c| {
        // A defensively-assigned id for any frame that somehow reached the
        // canvas without one (id `0` is the "unassigned" sentinel). The
        // loader and `appendComment` both assign ids, so this is belt-and-
        // braces — but a `0` id would map every such frame onto node-editor
        // id 0 and bleed editor state. Shares the node id counter (#203).
        if (c.id == 0) c.id = s.doc.nextNodeId();
        const id = commentNodeId(c.id);

        // Seed the editor's position from the doc the first frame, the
        // same handoff the node loop uses (`needs_layout`). After that the
        // editor owns position; we read it back below.
        if (s.needs_layout) {
            ne.setNodePosition(id, .{ c.x, c.y });
        }

        const fill = if (c.color) |col| unpackRgba(col) else default_comment_fill;
        const border = if (c.color) |col| brighten(unpackRgba(col)) else default_comment_border;

        ne.pushStyleColor(.group_bg, fill);
        ne.pushStyleColor(.group_border, border);
        ne.pushStyleVar1f(.group_rounding, 6.0);
        defer {
            ne.popStyleVar(1);
            ne.popStyleColor(2);
        }

        ne.beginNode(id);
        // Header label sits at the group's top-left, drawn above the
        // translucent backdrop the `ne.group` call lays down.
        const label = if (c.text.len > 0) c.text else "(comment)";
        zgui.textUnformatted(label);
        ne.group(.{ c.w, c.h });
        ne.endNode();

        // Pull live position back so a drag persists. Size is NOT read
        // back: `getNodeSize` reports content + header/padding chrome
        // (always >= the requested group size), so adopting it would
        // feedback-loop (grow every frame); guarding it grow-only — the
        // prior approach — instead silently blocked shrinking (bugbot).
        // v1 makes the inspector w/h authoritative (both grow AND shrink
        // work, and aren't overwritten); canvas drag-resize persistence
        // is a tracked follow-up.
        const pos = ne.getNodePosition(id);
        if (pos[0] != c.x or pos[1] != c.y) {
            c.x = pos[0];
            c.y = pos[1];
            s.is_dirty = true;
        }
    }
}

/// Lift a fill color's alpha toward opacity for use as a border tint, so
/// a low-alpha fill still gets a visible edge.
fn brighten(rgba: [4]f32) [4]f32 {
    return .{ rgba[0], rgba[1], rgba[2], @min(1.0, rgba[3] + 0.4) };
}

fn renderNodeBody(s: *FlowDocState, allocator: std.mem.Allocator, n: flow_io.Node) void {
    // Execution-flow anchors (issue #172, RFC §6 deferral). Top-center
    // *exec-in* anchor on every command node except `Event` (which is
    // the trigger — exec-out only); bottom-center *exec-out* anchor on
    // every command node. Reporters skip both — they're values inlined
    // into a command's data inputs by codegen, not exec steps. The
    // anchors emit *before* and *after* the data-pin block so the node
    // editor's vertical layout puts the in-anchor at the top edge and
    // the out-anchor at the bottom edge. The synthetic exec link
    // between consecutive command nodes is drawn by `renderExecEdges`
    // after the data-edge loop in `renderCanvas`.
    //
    // The exec-OUT command anchor (`execPinId(.output)`) drives the
    // *derived* #172 spine and stays read-only: it is never recorded, so
    // a drag from it fails the `findPin` lookup in `handleLinkCreate` and
    // is rejected — the user can't author the linear spine, only see what
    // the topo sort produced. The exec-IN anchor below, by contrast, is a
    // recorded drop *target* for an authored `ExecEdge` (issue #196).
    const is_command = isCommandNode(n);
    // The exec-in anchor is where an incoming control arrow lands. Emit it
    // for command nodes (the derived linear spine) AND for any explicit
    // `exec_edge` target — a branch/loop body node may be `.other` (e.g. a
    // nested Branch/loop) and still needs the anchor, else the amber
    // control arrow has nothing to attach to (labelle-gui#193/#194, bugbot).
    //
    // It is recorded as an `.exec` input for *every* such node — not just
    // existing targets — so a control drag can land on a node that has no
    // incoming exec edge yet (authoring the first one, issue #196).
    // Control nodes (Branch/ForRange/While/Switch and the time-control
    // Once/Cooldown/Delay, flow-codegen#47/#48) are `.other`-kind, so
    // `isCommandNode` is false for them — but they sit on the exec spine
    // and must expose an exec-in anchor even when freshly placed, else the
    // first incoming control arrow has nothing to land on and the node
    // silently can't be wired. Treat any control node as needing the
    // anchor, the same way a command node does.
    const needs_exec_in = (is_command or isControlNode(n) or
        isExplicitExecTarget(s.doc.exec_edges, n.id)) and n.kind != .event;
    if (needs_exec_in) {
        ne.beginPin(execPinId(n.id, .input), .input);
        zgui.text("▼", .{});
        ne.endPin();
        recordExecInPin(s, n.id);
    }
    zgui.text("[{d}] {s}", .{ n.id, n.type_name });
    // Emit the exec-out anchor at the *end* of the body via `defer` so
    // a switch arm that early-returns (e.g. the "no event selected"
    // hint on a freshly-placed Emit) still gets its bottom-edge
    // anchor. Keeping the anchor on every command node — even one with
    // no resolvable pins — means the exec spine still connects through
    // the unfinished node instead of breaking the visual flow.
    defer if (is_command) {
        ne.beginPin(execPinId(n.id, .output), .output);
        zgui.text("▼", .{});
        ne.endPin();
    };
    switch (n.kind) {
        .subflow => {
            zgui.textDisabled("flow: {s}", .{n.flow_ref});
            // Resolve the referenced flow (issue #161) so the node
            // shows its *true* pin interface — one input pin per
            // declared `param`, one output pin per `Output` node —
            // rather than only the input pins implied by its existing
            // `bindings`. Every pin drawn is also recorded (issue #158)
            // so edge authoring can map a pin id back to its node.
            const resolved = resolveSubflow(s, allocator, n.flow_ref);
            if (resolved) |ref_doc| {
                // A `pinId` is a hash of (node id, name, direction) —
                // two pins on this node that share a name *and*
                // direction collide on the same id, which makes the
                // node editor mis-associate links. A referenced flow
                // with duplicate `param` names or duplicate `Output`
                // names would do exactly that, so de-duplicate by name
                // within each direction before emitting pins. (Input
                // vs output never collide: `pinId` puts direction in
                // bit 62, so a param and an Output sharing a name still
                // get distinct ids — only same-direction names need
                // de-duplication.)
                var seen_in = PinNameSet.init(allocator);
                defer seen_in.deinit();
                var seen_out = PinNameSet.init(allocator);
                defer seen_out.deinit();

                // Inputs: one pin per declared parameter of the
                // referenced flow.
                for (ref_doc.params) |p| {
                    const dup = (seen_in.fetchPut(p.name, {}) catch null) != null;
                    if (dup) continue;
                    ne.beginPin(pinId(n.id, p.name, .input), .input);
                    zgui.text("> {s}", .{p.name});
                    ne.endPin();
                    recordPin(s, n.id, p.name, .input);
                }
                // Outputs: one pin per `Output` node of the referenced
                // flow, named by the Output node's result-pin name.
                for (ref_doc.nodes) |rn| {
                    if (rn.kind != .output) continue;
                    const dup = (seen_out.fetchPut(rn.output_name, {}) catch null) != null;
                    if (dup) continue;
                    ne.beginPin(pinId(n.id, rn.output_name, .output), .output);
                    zgui.text("{s} >", .{rn.output_name});
                    ne.endPin();
                    recordPin(s, n.id, rn.output_name, .output);
                }
            } else {
                // Unresolved — referenced file missing or unparseable.
                // Fall back to the binding-derived input pins so the
                // node still wires, and show a subtle hint. Bindings
                // are de-duplicated by name for the same reason as the
                // resolved-pin path above.
                zgui.textDisabled("(unresolved — pins from bindings)", .{});
                var seen_bind = PinNameSet.init(allocator);
                defer seen_bind.deinit();
                for (n.bindings) |b| {
                    const dup = (seen_bind.fetchPut(b.name, {}) catch null) != null;
                    if (dup) continue;
                    ne.beginPin(pinId(n.id, b.name, .input), .input);
                    zgui.text("> {s}", .{b.name});
                    ne.endPin();
                    recordPin(s, n.id, b.name, .input);
                }
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
        .emit => {
            // `Emit` fires a custom event (RFC-PLUGIN-EVENTS §8). The
            // node's input pins are the payload struct's fields, derived
            // from the editor's static event catalog. An unresolved event
            // name (the dropdown lets a user type a name that isn't yet
            // in the catalog) renders no pins and surfaces a hint so the
            // unwired Emit can still be saved and inspected.
            if (n.event_ref.len == 0) {
                zgui.textDisabled("(no event selected)", .{});
                return;
            }
            zgui.textDisabled("event: {s}", .{n.event_ref});
            const entry = event_catalog.lookup(n.event_ref) orelse {
                zgui.textDisabled("(unknown event — no pins)", .{});
                return;
            };
            // Payload fields are an `Emit` node's *inputs* — the flow
            // author wires a value to every field, and codegen lowers
            // the node to `game.emit(.{ .<tag> = .{ .<field> = ... } })`.
            // De-duplicate by name (a same-name field appearing twice
            // would collide on `pinId`) — the static catalog is
            // hand-written, but a future scan-based catalog might admit
            // a malformed payload struct and we want the editor to stay
            // robust either way.
            var seen = PinNameSet.init(allocator);
            defer seen.deinit();
            for (entry.fields) |f| {
                const dup = (seen.fetchPut(f.name, {}) catch null) != null;
                if (dup) continue;
                ne.beginPin(pinId(n.id, f.name, .input), .input);
                zgui.text("> {s}: {s}", .{ f.name, f.type_name });
                ne.endPin();
                recordPin(s, n.id, f.name, .input);
            }
        },
        .event => {
            // RFC-FLOW-VOCABULARY §3 — graph-level trigger. Visual cue:
            // a trigger glyph and the dotted event name. Output pins
            // are the event's payload fields (same source the `Emit`
            // node's inputs use).
            if (n.event_ref.len == 0) {
                zgui.textDisabled("(no event selected)", .{});
                return;
            }
            zgui.textColored(.{ 1.0, 0.78, 0.2, 1.0 }, ">>> {s}", .{n.event_ref});
            const entry = event_catalog.lookup(n.event_ref) orelse {
                zgui.textDisabled("(unknown event — no pins)", .{});
                return;
            };
            var seen = PinNameSet.init(allocator);
            defer seen.deinit();
            for (entry.fields) |f| {
                const dup = (seen.fetchPut(f.name, {}) catch null) != null;
                if (dup) continue;
                ne.beginPin(pinId(n.id, f.name, .output), .output);
                zgui.text("{s}: {s} >", .{ f.name, f.type_name });
                ne.endPin();
                recordPin(s, n.id, f.name, .output);
            }
        },
        .get_variable => {
            // Reporter — one output pin `value`, typed to the variable.
            zgui.textDisabled("get: {s}", .{n.variable_ref});
            ne.beginPin(pinId(n.id, "value", .output), .output);
            const var_type = lookupVariableType(s, n.variable_ref) orelse "?";
            zgui.text("value: {s} >", .{var_type});
            ne.endPin();
            recordPin(s, n.id, "value", .output);
        },
        .set_variable => {
            // Command — one input pin `value`, typed to the variable.
            zgui.textDisabled("set: {s}", .{n.variable_ref});
            ne.beginPin(pinId(n.id, "value", .input), .input);
            const var_type = lookupVariableType(s, n.variable_ref) orelse "?";
            zgui.text("> value: {s}", .{var_type});
            ne.endPin();
            recordPin(s, n.id, "value", .input);
        },
        .change_variable => {
            zgui.textDisabled("change: {s} by {s}", .{ n.variable_ref, n.by_text });
            ne.beginPin(pinId(n.id, "by", .input), .input);
            const var_type = lookupVariableType(s, n.variable_ref) orelse "?";
            zgui.text("> by: {s}", .{var_type});
            ne.endPin();
            recordPin(s, n.id, "by", .input);
        },
        .clear_variable => {
            zgui.textDisabled("clear: {s}", .{n.variable_ref});
        },
        .has_value_variable => {
            zgui.textDisabled("has value: {s}", .{n.variable_ref});
            ne.beginPin(pinId(n.id, "value", .output), .output);
            zgui.text("value: bool >", .{});
            ne.endPin();
            recordPin(s, n.id, "value", .output);
        },
        .custom_node => {
            // Plugin/script-contributed FlowNode (RFC §1, §6). Render
            // the catalog-derived pins: inputs above, output below. An
            // unknown name renders no pins and surfaces a hint so the
            // node still saves but the user knows it's unresolved.
            if (n.custom_name.len == 0) {
                zgui.textDisabled("(no FlowNode chosen)", .{});
                return;
            }
            const entry = node_catalog.lookup(n.custom_name) orelse {
                zgui.textDisabled("custom: {s}", .{n.custom_name});
                zgui.textDisabled("(unknown FlowNode — codegen will validate)", .{});
                return;
            };
            zgui.text("{s}", .{entry.display_name});
            zgui.textDisabled("{s}", .{entry.name});
            var seen_in = PinNameSet.init(allocator);
            defer seen_in.deinit();
            var seen_out = PinNameSet.init(allocator);
            defer seen_out.deinit();
            // On-disk `.flow.jsonc` edges + flow-codegen address CustomNode
            // inputs *positionally* (`arg0`, `arg1`, …; codegen resolves
            // `arg{d}`), not by catalog pin name. Render each input pin under
            // its positional id so data edges resolve, while showing the
            // catalog label for the human (labelle-gui#189). Static names
            // keep `recordPin`'s borrowed slice valid past this frame.
            const arg_pin_names = [_][]const u8{
                "arg0", "arg1", "arg2",  "arg3",  "arg4",  "arg5",  "arg6",  "arg7",
                "arg8", "arg9", "arg10", "arg11", "arg12", "arg13", "arg14", "arg15",
            };
            var in_idx: usize = 0;
            for (entry.pins) |p| switch (p.dir) {
                .input => {
                    if (in_idx >= arg_pin_names.len) continue;
                    const arg_name = arg_pin_names[in_idx];
                    in_idx += 1;
                    const dup = (seen_in.fetchPut(arg_name, {}) catch null) != null;
                    if (dup) continue;
                    ne.beginPin(pinId(n.id, arg_name, .input), .input);
                    zgui.text("> {s}: {s}", .{ p.label, p.type_name });
                    ne.endPin();
                    recordPin(s, n.id, arg_name, .input);
                },
                .output => {
                    const dup = (seen_out.fetchPut(p.name, {}) catch null) != null;
                    if (dup) continue;
                    ne.beginPin(pinId(n.id, p.name, .output), .output);
                    zgui.text("{s}: {s} >", .{ p.label, p.type_name });
                    ne.endPin();
                    recordPin(s, n.id, p.name, .output);
                },
            };
        },
        .other => {
            // Value/expression node kinds the model doesn't field-edit but
            // that DO carry data pins the edges reference. Pin names mirror
            // flow-codegen's convention so links resolve (labelle-gui#189).
            // String literals are static, so `recordPin`'s borrowed slice
            // stays valid.
            if (std.mem.eql(u8, n.type_name, "BinOp") or
                std.mem.eql(u8, n.type_name, "Compare"))
            {
                // Arithmetic (BinOp) and comparison (Compare) share the
                // binary a/b -> result shape (flow-codegen#7).
                ne.beginPin(pinId(n.id, "a", .input), .input);
                zgui.text("> a", .{});
                ne.endPin();
                recordPin(s, n.id, "a", .input);
                ne.beginPin(pinId(n.id, "b", .input), .input);
                zgui.text("> b", .{});
                ne.endPin();
                recordPin(s, n.id, "b", .input);
                ne.beginPin(pinId(n.id, "result", .output), .output);
                zgui.text("result >", .{});
                ne.endPin();
                recordPin(s, n.id, "result", .output);
            } else if (std.mem.eql(u8, n.type_name, "Logic")) {
                // Boolean logic (flow-codegen#7): `not` is unary (`a`
                // only), `and`/`or` are binary. Read the op from extras to
                // decide whether to expose the `b` pin.
                var logic_unary = false;
                for (n.extras) |kv| {
                    if (std.mem.eql(u8, kv.key, "op") and
                        std.mem.eql(u8, kv.value_text, "not")) logic_unary = true;
                }
                ne.beginPin(pinId(n.id, "a", .input), .input);
                zgui.text("> a", .{});
                ne.endPin();
                recordPin(s, n.id, "a", .input);
                if (!logic_unary) {
                    ne.beginPin(pinId(n.id, "b", .input), .input);
                    zgui.text("> b", .{});
                    ne.endPin();
                    recordPin(s, n.id, "b", .input);
                }
                ne.beginPin(pinId(n.id, "result", .output), .output);
                zgui.text("result >", .{});
                ne.endPin();
                recordPin(s, n.id, "result", .output);
            } else if (std.mem.eql(u8, n.type_name, "Literal") or
                std.mem.eql(u8, n.type_name, "Identifier"))
            {
                ne.beginPin(pinId(n.id, "value", .output), .output);
                zgui.text("value >", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .output);
            } else if (std.mem.eql(u8, n.type_name, "IntToString") or
                std.mem.eql(u8, n.type_name, "FloatToString"))
            {
                // Scalar-to-string reporters (flow-codegen#26). One data
                // INPUT `value` (the number to stringify) + one data
                // OUTPUT `value` (the `[]const u8` result). Both share the
                // name `value`; the pin id encodes direction, so input and
                // output are distinct ids and codegen reads them by
                // direction the same way. No exec pins — they render as
                // rounded reporters (see `nodeVisual` / `isReporterTypeName`).
                ne.beginPin(pinId(n.id, "value", .input), .input);
                zgui.text("> value", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .input);
                ne.beginPin(pinId(n.id, "value", .output), .output);
                zgui.text("value >", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .output);
            } else if (std.mem.eql(u8, n.type_name, "Concat") or
                std.mem.eql(u8, n.type_name, "Format"))
            {
                // Variadic string reporters (flow-codegen#26). A dynamic
                // set of `arg<N>` data INPUT pins (codegen joins them, in
                // order) + one `value` data OUTPUT (`[]const u8`). The arg
                // count is derived from the data edges already wired into
                // this node, plus one spare slot so a fresh node is always
                // wireable (`varArgInputCount`). `Format` additionally
                // carries a `template` field (the `std.fmt` format string),
                // shown in the inspector + the extras hint below. No exec
                // pins — rounded reporters (see `isReporterTypeName`).
                const arg_count = varArgInputCount(n.id, s.doc.edges);
                for (0..arg_count) |i| {
                    ne.beginPin(pinId(n.id, var_arg_pin_names[i], .input), .input);
                    zgui.text("> {s}", .{var_arg_pin_names[i]});
                    ne.endPin();
                    recordPin(s, n.id, var_arg_pin_names[i], .input);
                }
                ne.beginPin(pinId(n.id, "value", .output), .output);
                zgui.text("value >", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .output);
            } else if (isInputReporter(n.type_name)) {
                // Input reporters (labelle-gui#208 / flow-codegen#51). They
                // poll the raylib-style input mixin and produce a single
                // `value` data OUTPUT — bool for the `IsKey*`/`IsMouseButton*`
                // predicates, f32 for the `GetMouse*` getters. They take NO
                // data input pins: the `IsKey*` `key` (a `KeyboardKey` tag)
                // and `IsMouseButton*` `button` (a `MouseButton` tag) are
                // on-node FIELDs (see `other_field_specs`), spliced inline by
                // codegen; `GetMouse*` carry no field at all. No exec pins —
                // rounded reporters (see `isReporterTypeName`).
                ne.beginPin(pinId(n.id, "value", .output), .output);
                zgui.text("value >", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .output);
            } else if (std.mem.eql(u8, n.type_name, "SetField")) {
                ne.beginPin(pinId(n.id, "entity", .input), .input);
                zgui.text("> entity", .{});
                ne.endPin();
                recordPin(s, n.id, "entity", .input);
                ne.beginPin(pinId(n.id, "value", .input), .input);
                zgui.text("> value", .{});
                ne.endPin();
                recordPin(s, n.id, "value", .input);
            } else if (std.mem.eql(u8, n.type_name, "Branch")) {
                // Control-flow if/then-else (flow-codegen#8, issue #193).
                // Data INPUT `cond`; two exec OUTPUT pins `then`/`else`.
                // The `cond` pin is recorded as a data input so wires into
                // it can be authored; the `then`/`else` exec outputs are
                // recorded as `.exec` outputs by `renderExecOutPin` so a
                // control edge can be dragged *from* them (issue #196).
                ne.beginPin(pinId(n.id, "cond", .input), .input);
                zgui.text("> cond", .{});
                ne.endPin();
                recordPin(s, n.id, "cond", .input);
                renderExecOutPin(s, n.id, "then");
                renderExecOutPin(s, n.id, "else");
            } else if (std.mem.eql(u8, n.type_name, "ForRange")) {
                // Counted loop (flow-codegen#21, issue #194). Data inputs
                // `start`/`end`/`step`; data OUTPUT `index`; exec OUTPUT
                // `body` (the loop body's entry).
                ne.beginPin(pinId(n.id, "start", .input), .input);
                zgui.text("> start", .{});
                ne.endPin();
                recordPin(s, n.id, "start", .input);
                ne.beginPin(pinId(n.id, "end", .input), .input);
                zgui.text("> end", .{});
                ne.endPin();
                recordPin(s, n.id, "end", .input);
                ne.beginPin(pinId(n.id, "step", .input), .input);
                zgui.text("> step", .{});
                ne.endPin();
                recordPin(s, n.id, "step", .input);
                ne.beginPin(pinId(n.id, "index", .output), .output);
                zgui.text("index >", .{});
                ne.endPin();
                recordPin(s, n.id, "index", .output);
                renderExecOutPin(s, n.id, "body");
            } else if (std.mem.eql(u8, n.type_name, "While")) {
                // Conditional loop (flow-codegen#21, issue #194). Data
                // input `cond`; exec OUTPUT `body`.
                ne.beginPin(pinId(n.id, "cond", .input), .input);
                zgui.text("> cond", .{});
                ne.endPin();
                recordPin(s, n.id, "cond", .input);
                renderExecOutPin(s, n.id, "body");
            } else if (std.mem.eql(u8, n.type_name, "Once") or
                std.mem.eql(u8, n.type_name, "Cooldown") or
                std.mem.eql(u8, n.type_name, "Delay"))
            {
                // Time-control command nodes (flow-codegen#47, #48). No data
                // pins; one exec OUTPUT `body` (the guarded step). The
                // exec-IN anchor is emitted by the generic command/control
                // header above (`needs_exec_in`), so these render as
                // rectangular command nodes with an exec-in + `body`
                // exec-out — matching ForRange/While's silhouette. The
                // `Cooldown`/`Delay` `seconds` field shows in the inspector
                // (a `.literal` widget) and in the extras hint below.
                renderExecOutPin(s, n.id, "body");
            } else if (std.mem.eql(u8, n.type_name, "Switch")) {
                // Multi-way control (flow-codegen#22, issue #199). One
                // data INPUT `selector` (the value switched on, wired
                // like Branch's `cond`); N `case<N>` + a `default` exec
                // OUTPUT pin, each an amber control-flow source drawn
                // like Branch's `then`/`else` (draggable via #196).
                //
                // Cases are dynamic, so the rendered `case<N>` count is
                // derived from the exec edges already wired *from* this
                // node, plus one spare slot (so a fresh Switch with no
                // edges still shows `case0` to wire into) — see
                // `switchCaseOutputCount`. `default` always renders.
                ne.beginPin(pinId(n.id, "selector", .input), .input);
                zgui.text("> selector", .{});
                ne.endPin();
                recordPin(s, n.id, "selector", .input);
                const case_count = switchCaseOutputCount(n.id, s.doc.exec_edges);
                for (0..case_count) |i| {
                    renderExecOutPin(s, n.id, case_pin_names[i]);
                }
                renderExecOutPin(s, n.id, "default");
            }
            // Show extras as a compact hint (e.g. BinOp `op`, Literal
            // `value`) so the user can tell nodes apart.
            for (n.extras) |kv| {
                zgui.textDisabled("{s}: {s}", .{ kv.key, kv.value_text });
            }
        },
    }
}

/// Per-node visual style — corner radius + border color. Drives the
/// command vs reporter visual difference (RFC §6, phase 4 item 6).
pub const NodeVisual = struct {
    rounding: f32,
    border: [4]f32,
};

/// Whether a built-in `.other`-kind node renders as a *reporter* (rounded
/// silhouette, data-only, off the exec spine) rather than a command.
/// `.other` carries no command/reporter polarity in `NodeKind`, so the
/// editor classifies these expression nodes by `type_name` — the same set
/// flow-codegen treats as pure-value reporters. The string/text reporters
/// (`Concat`/`Format`/`IntToString`/`FloatToString`, flow-codegen#26) and the
/// input reporters (`IsKeyDown`/`IsKeyPressed`/`IsKeyReleased`,
/// `IsMouseButtonDown`/`IsMouseButtonPressed`/`IsMouseButtonReleased`,
/// `GetMouseX`/`GetMouseY`/`GetMouseWheel`, labelle-gui#208 / flow-codegen#51)
/// join this set so `nodeVisual` gives them the rounded shape and the generic
/// classifier never awards them an exec-in anchor (they're not
/// `isControlNode`, so `needs_exec_in` stays false).
pub fn isReporterTypeName(type_name: []const u8) bool {
    const reporters = [_][]const u8{
        "BinOp",                  "Compare",               "Logic",                "Literal",
        "Identifier",             "GetComponent",          "Concat",               "Format",
        "IntToString",            "FloatToString",
        // Input reporters (labelle-gui#208 / flow-codegen#51): bool key/mouse
        // predicates + f32 mouse getters, read inside per-frame flows.
        "IsKeyDown",              "IsKeyPressed",          "IsKeyReleased",
        "IsMouseButtonDown",      "IsMouseButtonPressed",  "IsMouseButtonReleased",
        "GetMouseX",              "GetMouseY",             "GetMouseWheel",
    };
    for (reporters) |r| {
        if (std.mem.eql(u8, type_name, r)) return true;
    }
    return false;
}

/// The input reporter type names (labelle-gui#208 / flow-codegen#51, #52) —
/// `IsKey*`/`IsMouseButton*` predicates + `GetMouse*` getters. Each renders
/// a single `value` data OUTPUT and no data inputs. Kept as a small set
/// (mirrors `isReporterTypeName`) so the `.other` pin-render arm reads as a
/// call, not a 9-way `or` chain (gemini #212).
fn isInputReporter(type_name: []const u8) bool {
    const names = [_][]const u8{
        "IsKeyDown",         "IsKeyPressed",         "IsKeyReleased",
        "IsMouseButtonDown", "IsMouseButtonPressed", "IsMouseButtonReleased",
        "GetMouseX",         "GetMouseY",            "GetMouseWheel",
    };
    for (names) |n| {
        if (std.mem.eql(u8, type_name, n)) return true;
    }
    return false;
}

/// Map a node kind to its visual treatment. Commands are rectangular
/// (rounding 4), reporters rounded (rounding 14), the `Event` trigger
/// stays command-shaped but with a warm border color so the entry point
/// reads at a glance. Unknown kinds get the neutral default.
pub fn nodeVisual(n: flow_io.Node) NodeVisual {
    const command_round: f32 = 4.0;
    const reporter_round: f32 = 14.0;
    const neutral_border: [4]f32 = .{ 0.4, 0.4, 0.45, 1.0 };
    const reporter_border: [4]f32 = .{ 0.4, 0.65, 0.45, 1.0 };
    const command_border: [4]f32 = .{ 0.4, 0.55, 0.85, 1.0 };
    const trigger_border: [4]f32 = .{ 0.95, 0.74, 0.2, 1.0 };

    // `.other` expression reporters (BinOp/Compare/Logic/Literal/Identifier
    // and the string/text reporters, flow-codegen#26) are classified by
    // `type_name` — they carry no polarity in `NodeKind`. Round them and
    // give them the reporter border so they read as pure-value nodes.
    if (n.kind == .other and isReporterTypeName(n.type_name)) return .{
        .rounding = reporter_round,
        .border = reporter_border,
    };

    switch (n.kind) {
        // Reporter ops (RFC §6) — rounded, green-ish border.
        .get_variable, .has_value_variable, .param => return .{
            .rounding = reporter_round,
            .border = reporter_border,
        },
        // Command ops — rectangular, blue-ish border.
        .set_variable, .change_variable, .clear_variable, .emit, .subflow, .output => return .{
            .rounding = command_round,
            .border = command_border,
        },
        // Event trigger — command shape with the warm "trigger" border.
        .event => return .{
            .rounding = command_round,
            .border = trigger_border,
        },
        // CustomNode shape follows the catalog entry's kind. An unknown
        // entry falls through to neutral so the user can still place it.
        .custom_node => {
            const entry = node_catalog.lookup(n.custom_name) orelse return .{
                .rounding = command_round,
                .border = neutral_border,
            };
            return switch (entry.kind) {
                .command => .{ .rounding = command_round, .border = command_border },
                .reporter => .{ .rounding = reporter_round, .border = reporter_border },
            };
        },
        else => return .{
            .rounding = command_round,
            .border = neutral_border,
        },
    }
}

/// Look up the declared Zig type of a flow-scope variable by name.
/// Returns null when the variable isn't declared — the canvas displays
/// the value pin with a `?` placeholder so the unresolved binding is
/// visible at a glance.
fn lookupVariableType(s: *FlowDocState, name: []const u8) ?[]const u8 {
    for (s.doc.variables) |v| {
        if (std.mem.eql(u8, v.name, name)) return v.type_name;
    }
    return null;
}

// ─── Subflow reference resolution ───────────────────────────────────────

/// Resolve a `Subflow` node's referenced-flow name to a parsed
/// `flow_io.FlowDoc` (issue #161). Returns null when the name is empty
/// or the referenced file is missing / unparseable — the caller then
/// falls back to the binding-derived pins.
///
/// The result is cached on `FlowDocState.resolved`, keyed by name plus
/// the referenced file's mtime + size: the file is parsed once and the
/// parse reused across frames, re-done only when the file changes on
/// disk (mirroring `flow.zig`'s mtime-keyed re-derivation; size is in
/// the key too so a same-tick rewrite still re-resolves). The returned
/// pointer borrows the cache entry's arena — valid until the next call
/// that re-resolves the same name or the tab closes.
///
/// Two cost-control properties:
///   - Within one frame, each distinct `flow_ref` is stat'd at most
///     once. The first call for a name this frame stamps the entry's
///     `last_frame`; later nodes referencing the same flow reuse the
///     stamped entry and skip the `stat` syscall.
///   - A failed load is *not* pinned to the file's current mtime. The
///     entry stays `loaded_ok = false`, so the next frame re-attempts
///     the load — a referenced file fixed in place (contents changed,
///     mtime unchanged) recovers instead of staying unresolved.
fn resolveSubflow(
    s: *FlowDocState,
    allocator: std.mem.Allocator,
    flow_ref: []const u8,
) ?*const flow_io.FlowDoc {
    return resolveSubflowImpl(s, allocator, flow_ref);
}

/// Decide whether a cached `ResolvedFlow` can be reused without
/// re-parsing the referenced file.
///
/// A cache entry is fresh only when its last load *succeeded*
/// (`loaded_ok`) **and** the referenced file's currently-observed
/// `mtime` *and* `size` both still match what was cached. Size is
/// compared alongside mtime so a same-tick rewrite — two writes within
/// one filesystem mtime granule, or a tool that preserves mtime — is
/// still detected: the content length changes even when the mtime
/// doesn't. A failed load (`loaded_ok = false`) is never fresh, so a
/// fixed-contents file recovers on the next frame even if its mtime +
/// size haven't moved.
///
/// Pure so the no-zgui `zig build test` target can exercise it (the
/// rest of `resolveSubflow` touches `FlowDocState`, which pulls in the
/// imgui stack that target excludes).
pub fn resolvedFlowIsFresh(
    loaded_ok: bool,
    cached_mtime: ?i96,
    cached_size: ?u64,
    cur_mtime: ?i96,
    cur_size: ?u64,
) bool {
    if (!loaded_ok) return false;
    // A failed stat leaves both observations null; a null cached side
    // means nothing authoritative was ever recorded. Either way, don't
    // trust the cache — re-resolve.
    if (cur_mtime == null or cur_size == null) return false;
    if (cached_mtime == null or cached_size == null) return false;
    return cached_mtime == cur_mtime and cached_size == cur_size;
}

fn resolveSubflowImpl(
    s: *FlowDocState,
    allocator: std.mem.Allocator,
    flow_ref: []const u8,
) ?*const flow_io.FlowDoc {
    if (flow_ref.len == 0) return null;

    // Find an existing cache entry for this name.
    var entry: ?*ResolvedFlow = null;
    for (s.resolved.items) |*r| {
        if (std.mem.eql(u8, r.name, flow_ref)) {
            entry = r;
            break;
        }
    }

    // Already resolved this frame — reuse without a second `stat`. This
    // is the common case when many `Subflow` nodes share one flow.
    if (entry) |e| {
        if (e.last_frame == s.frame_seq) {
            return if (e.doc) |*d| d else null;
        }
    }

    // Referenced flows live alongside this flow in `scripts/flows/`;
    // the path is `<dir of this flow>/<name>.flow.jsonc`.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const ref_path = referencedFlowPath(&path_buf, s.path, flow_ref) orelse return null;

    // A flow may not reference itself — that would recurse and is a
    // malformed graph anyway. Treat it as unresolved. The comparison
    // canonicalizes both paths (`.`, `..`, symlinks) so a self-reference
    // reached through a non-canonical `flow_ref` — e.g. `./enemy_tick`
    // or `../flows/enemy_tick` — is still caught and doesn't make the
    // node display the *current* flow's own pins.
    if (sameFileOnDisk(ref_path, s.path)) return null;

    // Stat the referenced file for its mtime + size. A failed stat
    // (missing file) leaves both null — still cacheable as "unresolved".
    // Size is compared alongside mtime so a same-tick rewrite that
    // doesn't advance the mtime still re-resolves (content length
    // changes even when the mtime granule doesn't).
    const cur_mtime: ?i96, const cur_size: ?u64 = blk: {
        const io = io_global.io();
        const file = std.Io.Dir.cwd().openFile(io, ref_path, .{}) catch break :blk .{ null, null };
        defer file.close(io);
        const st = file.stat(io) catch break :blk .{ null, null };
        break :blk .{ st.mtime.nanoseconds, st.size };
    };

    if (entry) |e| {
        // Cache hit (first time this frame). Reuse the existing parse
        // only when the previous load *succeeded* and the file hasn't
        // changed on disk — both mtime *and* size must match. A
        // previously failed load (`loaded_ok` false) always re-attempts
        // — a fixed file must recover even if its mtime didn't move.
        if (resolvedFlowIsFresh(e.loaded_ok, e.mtime, e.size, cur_mtime, cur_size)) {
            e.last_frame = s.frame_seq;
            return if (e.doc) |*d| d else null;
        }
        // Stale or previously failed: drop any old parse and re-resolve.
        e.deinit();
        e.doc = loadReferencedFlow(allocator, ref_path);
        e.loaded_ok = e.doc != null;
        // Only pin the mtime + size when the load succeeded; on failure
        // leave them untouched so the next frame's freshness comparison
        // can't short-circuit the retry.
        if (e.loaded_ok) {
            e.mtime = cur_mtime;
            e.size = cur_size;
        }
        e.last_frame = s.frame_seq;
        return if (e.doc) |*d| d else null;
    }

    // Cache miss — add a new entry. `name` is duped onto the tab arena
    // so it outlives `flow_ref` (which points into the editable doc and
    // can be reallocated by an edit).
    const name_dup = s.doc.allocator().dupe(u8, flow_ref) catch return null;
    var new_entry: ResolvedFlow = .{ .name = name_dup, .last_frame = s.frame_seq };
    new_entry.doc = loadReferencedFlow(allocator, ref_path);
    new_entry.loaded_ok = new_entry.doc != null;
    // Only treat the mtime + size as authoritative on a successful load
    // (see above) — a failed first load keeps them null and `loaded_ok`
    // false so the next frame retries.
    if (new_entry.loaded_ok) {
        new_entry.mtime = cur_mtime;
        new_entry.size = cur_size;
    }
    s.resolved.append(allocator, new_entry) catch {
        // Append failed — free the parse we just did rather than leak.
        var tmp = new_entry;
        tmp.deinit();
        return null;
    };
    const stored = &s.resolved.items[s.resolved.items.len - 1];
    return if (stored.doc) |*d| d else null;
}

/// Load + parse the referenced flow file. Returns null on any failure
/// (missing file, unparseable JSON, malformed schema) — resolution is
/// best-effort and a bad reference must never crash the editor.
fn loadReferencedFlow(allocator: std.mem.Allocator, ref_path: []const u8) ?flow_io.FlowDoc {
    return flow_io.loadFromFile(allocator, ref_path) catch |err| {
        std.log.warn("flow: subflow reference {s} unresolved: {s}", .{ ref_path, @errorName(err) });
        return null;
    };
}

/// Build the on-disk path of a referenced flow: the directory holding
/// the current flow file, plus `<name>.flow.jsonc`. Returns null when
/// the current path has no directory component or the result would
/// overflow `buf`. Public for unit testing.
pub fn referencedFlowPath(buf: []u8, current_path: []const u8, flow_ref: []const u8) ?[]const u8 {
    const dir = std.fs.path.dirname(current_path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}/{s}{s}", .{ dir, flow_ref, flow_io.extension }) catch null;
}

/// True when `a` and `b` name the *same file on disk*. Both paths are
/// canonicalized (resolving `.`, `..`, and symlinks via `realPathFile`)
/// before comparison, so a self-reference reached through a
/// non-canonical `flow_ref` is detected even though the raw path
/// strings differ.
///
/// When either path can't be canonicalized — most commonly because the
/// referenced file doesn't exist yet — the canonical comparison is
/// impossible, so this falls back to a raw byte-equality check. That
/// fallback is conservative: an unresolvable `ref_path` simply isn't
/// flagged as a self-reference and `resolveSubflow` then fails its
/// `stat` and reports the node as unresolved anyway.
///
/// Public for unit testing.
pub fn sameFileOnDisk(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    const io = io_global.io();
    const cwd = std.Io.Dir.cwd();
    var buf_a: [std.fs.max_path_bytes]u8 = undefined;
    var buf_b: [std.fs.max_path_bytes]u8 = undefined;
    const len_a = cwd.realPathFile(io, a, &buf_a) catch return false;
    const len_b = cwd.realPathFile(io, b, &buf_b) catch return false;
    return std.mem.eql(u8, buf_a[0..len_a], buf_b[0..len_b]);
}

// ─── Inspector ──────────────────────────────────────────────────────────

fn renderInspector(s: *FlowDocState) void {
    renderEventEditor(s);
    zgui.spacing();
    zgui.separator();
    renderVariablesSidebar(s);
    zgui.spacing();
    zgui.separator();
    renderParamsEditor(s);
    zgui.spacing();
    zgui.separator();
    renderNodePalette(s);
    zgui.spacing();
    zgui.separator();
    renderCommentsInspector(s);
    zgui.spacing();
    zgui.separator();
    renderSelectedNode(s);
}

/// Inspector section for the comment / group frames (labelle-gui#188).
/// Lists every frame with editable `text` and `x`/`y`/`w`/`h` geometry,
/// plus a delete button. The canvas-side `renderComments` already moves
/// frames by drag; this gives precise edits and is the editing surface
/// when a frame is dragged behind the nodes and hard to grab. Editing any
/// field marks the doc dirty and re-seeds the layout so the canvas picks
/// up the new geometry next frame.
fn renderCommentsInspector(s: *FlowDocState) void {
    const a = s.doc.allocator();
    zgui.text("Comments ({d})", .{s.doc.comments.len});
    if (s.doc.comments.len == 0) {
        zgui.textDisabled("(none — \"+ Comment\" adds a frame)", .{});
        return;
    }

    var id_buf: [64]u8 = undefined;
    var remove_idx: ?usize = null;
    for (s.doc.comments, 0..) |*c, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();

        zgui.setNextItemWidth(180);
        var text_buf: ValueBuf = undefined;
        seedBuf(&text_buf, c.text);
        if (zgui.inputText("##cmt_text", .{ .buf = &text_buf })) {
            c.text = dupZ(a, &text_buf) catch c.text;
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        const x_id = std.fmt.bufPrintZ(&id_buf, "x##cmt{d}", .{i}) catch "x";
        if (zgui.smallButton(x_id)) remove_idx = i;

        zgui.setNextItemWidth(140);
        if (zgui.dragFloat("xy##cmt", .{ .v = &c.x, .cfmt = "%.0f" })) {
            s.is_dirty = true;
            s.needs_layout = true;
        }
        zgui.sameLine(.{});
        zgui.setNextItemWidth(70);
        if (zgui.dragFloat("##cmt_y", .{ .v = &c.y, .cfmt = "%.0f" })) {
            s.is_dirty = true;
            s.needs_layout = true;
        }

        zgui.setNextItemWidth(140);
        if (zgui.dragFloat("wh##cmt", .{ .v = &c.w, .min = 40, .cfmt = "%.0f" })) {
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        zgui.setNextItemWidth(70);
        if (zgui.dragFloat("##cmt_h", .{ .v = &c.h, .min = 40, .cfmt = "%.0f" })) {
            s.is_dirty = true;
        }
        zgui.separator();
    }

    if (remove_idx) |idx| {
        deleteComment(s, idx) catch |err| {
            std.log.err("flow: delete comment failed: {s}", .{@errorName(err)});
        };
    }
}

fn renderEventEditor(s: *FlowDocState) void {
    zgui.text("Event", .{});
    const a = s.doc.allocator();

    // v2-form flows (RFC-FLOW-VOCABULARY §3) declare their trigger ON
    // the canvas as one or more `Event` nodes — no file-level header.
    // Show a hint surfacing the on-canvas trigger(s) and offer to opt
    // back into the legacy header for projects that still need it.
    if (!s.doc.event_present) {
        var event_node_count: usize = 0;
        var first_name: []const u8 = "";
        for (s.doc.nodes) |n| if (n.kind == .event) {
            if (event_node_count == 0) first_name = n.event_ref;
            event_node_count += 1;
        };
        if (event_node_count == 0) {
            zgui.textColored(
                .{ 1.0, 0.65, 0.2, 1.0 },
                "(no trigger — add an Event node or restore the legacy header)",
                .{},
            );
        } else if (event_node_count == 1) {
            zgui.textDisabled(
                "Trigger on canvas: Event \"{s}\"",
                .{first_name},
            );
        } else {
            zgui.textDisabled(
                "Multi-trigger flow ({d} Event nodes on canvas)",
                .{event_node_count},
            );
        }
        if (zgui.smallButton("+ Restore legacy event header")) {
            s.doc.event = .{
                .type_name = a.dupe(u8, "OnCreate") catch s.doc.event.type_name,
            };
            s.doc.event_present = true;
            s.is_dirty = true;
        }
        return;
    }

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

    // `OnEvent` carries two forms (RFC-PLUGIN-EVENTS §7): the new
    // dotted-name form and the legacy `module`+`callback`+`params`
    // form. The editor offers the dropdown when the event is — or is
    // newly switched to — `OnEvent`; a legacy-form flow gets a banner
    // explaining what it is plus a one-click converter.
    if (std.mem.eql(u8, s.doc.event.type_name, "OnEvent")) {
        renderOnEventEditor(s);
    }
}

/// Variables sidebar (RFC-FLOW-VOCABULARY §4, item 3) — list the flow's
/// declared `variables` grouped by Zig type, with `+ Get` / `+ Set` /
/// `+ Change` (and `+ Clear` / `+ Has Value` for nullables) drop
/// buttons that synthesize a variable-op node onto the canvas.
fn renderVariablesSidebar(s: *FlowDocState) void {
    zgui.text("Variables", .{});
    zgui.textDisabled("Flow-scope persistent state (RFC §4).", .{});

    const a = s.doc.allocator();
    var remove_idx: ?usize = null;
    var id_buf: [64]u8 = undefined;

    if (s.doc.variables.len == 0) {
        zgui.textDisabled("(none — add one below)", .{});
    }

    // Group by `type_name` so two `i32` vars sit under one heading. The
    // assembler's discovery walk is unsorted; we list types in their
    // first-appearance order for stable rendering. Backed by a stack
    // buffer — a flow with >32 distinct variable types is implausible
    // in practice, and the overflow falls through silently (the variable
    // still renders, just under no type heading).
    var type_buf: [32][]const u8 = undefined;
    var type_count: usize = 0;
    for (s.doc.variables) |v| {
        var already = false;
        for (type_buf[0..type_count]) |t| if (std.mem.eql(u8, t, v.type_name)) {
            already = true;
            break;
        };
        if (!already and type_count < type_buf.len) {
            type_buf[type_count] = v.type_name;
            type_count += 1;
        }
    }

    for (type_buf[0..type_count]) |type_name| {
        zgui.textColored(.{ 0.6, 0.85, 1.0, 1.0 }, "  {s}", .{type_name});
        for (s.doc.variables, 0..) |*v, i| {
            if (!std.mem.eql(u8, v.type_name, type_name)) continue;
            zgui.pushIntId(@intCast(i));
            defer zgui.popId();

            // Name editor.
            zgui.setNextItemWidth(120);
            var name_buf: IdentBuf = undefined;
            seedBuf(&name_buf, v.name);
            const name_id = std.fmt.bufPrintZ(&id_buf, "##vname{d}", .{i}) catch "##vn";
            if (zgui.inputText(name_id, .{ .buf = &name_buf })) {
                v.name = dupZ(a, &name_buf) catch v.name;
                s.is_dirty = true;
            }
            zgui.sameLine(.{});

            // Default editor (canonical JSON text).
            zgui.setNextItemWidth(90);
            var def_buf: ValueBuf = undefined;
            seedBuf(&def_buf, v.default_text);
            const def_id = std.fmt.bufPrintZ(&id_buf, "##vdef{d}", .{i}) catch "##vd";
            if (zgui.inputText(def_id, .{ .buf = &def_buf })) {
                const txt = std.mem.sliceTo(&def_buf, 0);
                v.default_text = flow_io.normalizeValueText(a, txt) catch v.default_text;
                s.is_dirty = true;
            }
            zgui.sameLine(.{});
            const x_id = std.fmt.bufPrintZ(&id_buf, "x##vx{d}", .{i}) catch "x";
            if (zgui.smallButton(x_id)) remove_idx = i;

            // `+ Get / + Set / + Change` (+ Clear / Has Value for nullables)
            // synthesize one of the variable-op nodes (RFC §4) pre-named
            // to this variable, so the author isn't retyping a name.
            const get_id = std.fmt.bufPrintZ(&id_buf, "Get##g{d}", .{i}) catch "Get";
            if (zgui.smallButton(get_id)) addVarOpNode(s, .get_variable, v.name) catch |err| nodeAddErr(err);
            zgui.sameLine(.{});
            const set_id = std.fmt.bufPrintZ(&id_buf, "Set##s{d}", .{i}) catch "Set";
            if (zgui.smallButton(set_id)) addVarOpNode(s, .set_variable, v.name) catch |err| nodeAddErr(err);
            zgui.sameLine(.{});
            const chg_id = std.fmt.bufPrintZ(&id_buf, "Change##c{d}", .{i}) catch "Change";
            if (zgui.smallButton(chg_id)) addVarOpNode(s, .change_variable, v.name) catch |err| nodeAddErr(err);
            if (v.isNullable()) {
                zgui.sameLine(.{});
                const clr_id = std.fmt.bufPrintZ(&id_buf, "Clear##cl{d}", .{i}) catch "Clear";
                if (zgui.smallButton(clr_id)) addVarOpNode(s, .clear_variable, v.name) catch |err| nodeAddErr(err);
                zgui.sameLine(.{});
                const hv_id = std.fmt.bufPrintZ(&id_buf, "HasValue##hv{d}", .{i}) catch "HasValue";
                if (zgui.smallButton(hv_id)) addVarOpNode(s, .has_value_variable, v.name) catch |err| nodeAddErr(err);
            }
        }
    }

    if (zgui.button("+ Add variable", .{})) {
        appendVariable(s) catch |err| {
            std.log.err("flow: add variable failed: {s}", .{@errorName(err)});
        };
    }
    if (remove_idx) |idx| {
        removeVariable(s, idx) catch |err| {
            std.log.err("flow: remove variable failed: {s}", .{@errorName(err)});
        };
    }
}

/// Editor surface specific to `OnEvent` (RFC-PLUGIN-EVENTS §7). Renders
/// either the new-form name dropdown or the legacy-form fallback view
/// depending on which form the doc currently holds. Migrating a doc to
/// `OnEvent` for the first time (e.g. via the event-type text box above)
/// leaves it in *neither* form — the editor seeds the new form on the
/// next frame so the user only sees the dropdown.
fn renderOnEventEditor(s: *FlowDocState) void {
    const a = s.doc.allocator();
    const ev = &s.doc.event;

    // Seed the new form on a fresh switch to `OnEvent`. `parseEvent`
    // would have rejected a malformed `OnEvent` at load time, so an
    // in-memory `OnEvent` with neither form set only happens when the
    // user just retyped the type. Allocate a tiny empty-name marker so
    // a save is structurally valid (codegen will reject the empty name
    // explicitly — better than a `MalformedFlow` save).
    if (ev.name == null and ev.module == null and ev.callback == null) {
        ev.name = a.dupe(u8, "") catch null;
        s.is_dirty = true;
    }

    if (ev.module != null or ev.callback != null) {
        // Legacy form. Show the raw fields read-only and a converter
        // button — phase 6 will drop the legacy path entirely; for now
        // the editor round-trips it untouched and helps the user
        // migrate.
        zgui.spacing();
        zgui.textColored(
            .{ 1.0, 0.65, 0.2, 1.0 },
            "Legacy OnEvent form (module + callback)",
            .{},
        );
        zgui.textDisabled(
            "Phase 6 will drop this form. Use Convert to migrate.",
            .{},
        );
        if (ev.module) |m| zgui.bulletText("module: {s}", .{m});
        if (ev.callback) |c| zgui.bulletText("callback: {s}", .{c});
        for (ev.params) |p| {
            zgui.bulletText("param: {s}: {s}", .{ p.name, p.type_name });
        }
        if (zgui.button("Convert to new form", .{})) {
            flow_io.legacy_onevent_to_name(a, ev) catch |err| {
                std.log.err("flow: OnEvent convert failed: {s}", .{@errorName(err)});
                return;
            };
            s.is_dirty = true;
        }
        return;
    }

    // New form — event-name dropdown sourced from the static catalog
    // (`flow_event_catalog`). Picks resolve through the same combo
    // helper an `Emit` node uses, so the two sites stay byte-identical
    // in shape (RFC O6 — "the editor offers the discovered event names
    // as a dropdown").
    zgui.spacing();
    zgui.text("Event name", .{});
    // `renderEventNameCombo` takes a `*[]const u8` it can re-point on
    // selection. `ev.name` is `?[]const u8`, so route through a local
    // and write back. A `null` was already replaced with `""` above,
    // so the `orelse` here just satisfies the compiler.
    var name_buf: []const u8 = ev.name orelse "";
    renderEventNameCombo(s, "##onevent_name", &name_buf);
    ev.name = name_buf;
    if (name_buf.len > 0 and !event_catalog.isKnown(name_buf)) {
        zgui.textColored(
            .{ 1.0, 0.65, 0.2, 1.0 },
            "(unknown event — codegen will validate against PluginEvents)",
            .{},
        );
    }
    if (event_catalog.lookup(name_buf)) |entry| {
        if (entry.description.len > 0) {
            zgui.textDisabled("— {s}", .{entry.description});
        }
        zgui.textDisabled("Payload fields the flow can read via Param nodes:", .{});
        for (entry.fields) |f| {
            zgui.bulletText("{s}: {s}", .{ f.name, f.type_name });
        }
    }
}

/// Shared event-name dropdown — used by both `OnEvent`'s event editor
/// and the `Emit` node inspector (RFC O6). `event_ref` is mutated in
/// place to the new selection (a dup'd slice on the doc arena); the
/// caller decides what to do on change. A free-text fallback covers
/// names not yet in the catalog so a project-local game event isn't
/// blocked on the catalog catching up.
fn renderEventNameCombo(s: *FlowDocState, label: [:0]const u8, event_ref: *[]const u8) void {
    const a = s.doc.allocator();
    // Show the current selection — empty for a brand-new node/event.
    var preview: IdentBuf = undefined;
    seedBuf(&preview, event_ref.*);
    if (zgui.beginCombo(label, .{ .preview_value = &preview })) {
        // First row: blank "<choose>" so a node mid-authoring can clear
        // its selection without a manual delete.
        if (zgui.selectable("<choose>", .{ .selected = event_ref.*.len == 0 })) {
            if (event_ref.*.len != 0) {
                event_ref.* = a.dupe(u8, "") catch event_ref.*;
                s.is_dirty = true;
            }
        }
        for (&event_catalog.entries) |entry| {
            var row: IdentBuf = undefined;
            seedBuf(&row, entry.name);
            const sel = std.mem.eql(u8, entry.name, event_ref.*);
            if (zgui.selectable(&row, .{ .selected = sel })) {
                if (!sel) {
                    event_ref.* = a.dupe(u8, entry.name) catch event_ref.*;
                    s.is_dirty = true;
                }
            }
            if (entry.description.len > 0 and zgui.isItemHovered(.{})) {
                if (zgui.beginTooltip()) {
                    zgui.text("{s}", .{entry.description});
                    zgui.endTooltip();
                }
            }
        }
        zgui.endCombo();
    }
    // Free-text fallback — pick a name not yet in the catalog (a
    // project-local game event, or a plugin event the editor doesn't
    // yet know about). Editing this writes through to the same
    // `event_ref` so the dropdown and the text input stay in sync.
    var custom: IdentBuf = undefined;
    seedBuf(&custom, event_ref.*);
    zgui.setNextItemWidth(220);
    var name_id_buf: [48]u8 = undefined;
    const custom_id = std.fmt.bufPrintZ(
        &name_id_buf,
        "{s}_custom",
        .{label},
    ) catch label;
    if (zgui.inputText(custom_id, .{ .buf = &custom })) {
        const raw = std.mem.sliceTo(&custom, 0);
        event_ref.* = a.dupe(u8, raw) catch event_ref.*;
        s.is_dirty = true;
    }
    zgui.sameLine(.{});
    zgui.textDisabled("(or type a name)", .{});
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
    zgui.text("Palette", .{});
    zgui.textDisabled("Built-in node types.", .{});

    // ── Built-in section ──
    // Composition + control: Event (trigger), the variable ops, Subflow,
    // Param, Output, Emit. The raw `Call` escape hatch lives under
    // "Add raw call…" below, not on the default palette (RFC §7).
    if (zgui.button("+ Event", .{})) {
        addNode(s, .event) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Subflow", .{})) addNode(s, .subflow) catch |err| nodeAddErr(err);
    zgui.sameLine(.{});
    if (zgui.button("+ Param", .{})) addNode(s, .param) catch |err| nodeAddErr(err);
    zgui.sameLine(.{});
    if (zgui.button("+ Output", .{})) addNode(s, .output) catch |err| nodeAddErr(err);
    if (zgui.button("+ Emit", .{})) addNode(s, .emit) catch |err| nodeAddErr(err);
    zgui.sameLine(.{});
    if (zgui.button("+ Get/Set/Change Variable", .{})) addNode(s, .get_variable) catch |err| nodeAddErr(err);

    // ── Expression / control section (issue #192) ──
    // The value/expression/control node kinds are all `.other` — they
    // render + inspect already, but `addNode` can't create them
    // (`kind.typeName()` is null for `.other`). `addOtherNode` seeds an
    // `.other` node with the one editable extra each kind's
    // `flow_io.otherFieldSpec` exposes, so a fresh node is immediately
    // valid + inspector-editable. Defaults are canonical JSON value text:
    // a JSON string for `op`/`name`/`target`, a bare literal for `value`.
    // Control nodes (Branch/ForRange/While) carry no editable field — their
    // wiring is pins + exec edges (authoring those edges is #196).
    zgui.spacing();
    zgui.separator();

    zgui.text("Math / Logic", .{});
    if (zgui.button("+ BinOp", .{})) {
        addOtherNode(s, "BinOp", &.{.{ .key = "op", .value_text = "\"add\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Compare", .{})) {
        addOtherNode(s, "Compare", &.{.{ .key = "op", .value_text = "\"eq\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Logic", .{})) {
        addOtherNode(s, "Logic", &.{.{ .key = "op", .value_text = "\"and\"" }}) catch |err| nodeAddErr(err);
    }

    zgui.text("Values", .{});
    if (zgui.button("+ Literal", .{})) {
        addOtherNode(s, "Literal", &.{.{ .key = "value", .value_text = "0" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Identifier", .{})) {
        addOtherNode(s, "Identifier", &.{.{ .key = "name", .value_text = "\"\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ SetField", .{})) {
        addOtherNode(s, "SetField", &.{.{ .key = "target", .value_text = "\"\"" }}) catch |err| nodeAddErr(err);
    }

    zgui.text("Control", .{});
    if (zgui.button("+ Branch", .{})) {
        addOtherNode(s, "Branch", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ ForRange", .{})) {
        addOtherNode(s, "ForRange", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ While", .{})) {
        addOtherNode(s, "While", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    // Switch (flow-codegen#22, issue #199). Like the other control
    // nodes it carries no editable field — its arms are pins + exec
    // edges. A fresh Switch has no exec edges, so the renderer shows a
    // single spare `case0` + `default` until the user wires more.
    if (zgui.button("+ Switch", .{})) {
        addOtherNode(s, "Switch", &.{}) catch |err| nodeAddErr(err);
    }

    // ── Time section (flow-codegen#47, #48) ──
    // Time-control command nodes. `Once` gates its `body` to fire a single
    // time; `Cooldown`/`Delay` carry a `seconds` (f64) field seeded to
    // `1.0` — the same canonical JSON value text codegen parses
    // (`{ "type": "Cooldown", "seconds": 1.0 }`). Like the other control
    // nodes their wiring is the `body` exec edge; `Delay`'s `body` is meant
    // to reach a `Subflow` (enforced by codegen, not the editor).
    zgui.text("Time", .{});
    if (zgui.button("+ Once", .{})) {
        addOtherNode(s, "Once", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Cooldown", .{})) {
        addOtherNode(s, "Cooldown", &.{.{ .key = "seconds", .value_text = "1" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Delay", .{})) {
        addOtherNode(s, "Delay", &.{.{ .key = "seconds", .value_text = "1" }}) catch |err| nodeAddErr(err);
    }

    // ── Text section (flow-codegen#26) ──
    // String/text reporter nodes — rounded, produce a `value` ([]const u8)
    // output that wires into command data inputs (`Log`/`Emit`/
    // `SetVariable`, …). `Format` seeds an empty Zig string literal
    // `template` (the `std.fmt` format string, edited via the `.text`
    // widget — matches `Identifier`'s `""` name seed); the others carry no
    // editable field — their inputs are data pins (`Concat`/`Format` are
    // variadic `arg<N>`; `IntToString`/`FloatToString` take one `value`).
    zgui.text("Text", .{});
    if (zgui.button("+ Format", .{})) {
        addOtherNode(s, "Format", &.{.{ .key = "template", .value_text = "\"\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ Concat", .{})) {
        addOtherNode(s, "Concat", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ IntToString", .{})) {
        addOtherNode(s, "IntToString", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ FloatToString", .{})) {
        addOtherNode(s, "FloatToString", &.{}) catch |err| nodeAddErr(err);
    }

    // ── Input section (labelle-gui#208 / flow-codegen#51) ──
    // Input reporter nodes — rounded, poll the input mixin and produce a
    // `value` output read inside per-frame flows. `IsKey*` carry a `key`
    // FIELD (a `KeyboardKey` tag, seeded `"space"`); `IsMouseButton*` carry
    // a `button` FIELD (a `MouseButton` tag, seeded `"left"`) — both stored
    // as JSON strings, edited via the `.text` widget the same way
    // `Identifier.name` is. `GetMouse*` take no field. The seeded
    // `key`/`button` are quoted JSON-string value-text (`"\"space\""` →
    // `"key": "space"`), matching codegen's `{ "type": "IsKeyDown",
    // "key": "space" }` contract.
    zgui.text("Input", .{});
    if (zgui.button("+ IsKeyDown", .{})) {
        addOtherNode(s, "IsKeyDown", &.{.{ .key = "key", .value_text = "\"space\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ IsKeyPressed", .{})) {
        addOtherNode(s, "IsKeyPressed", &.{.{ .key = "key", .value_text = "\"space\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ IsKeyReleased", .{})) {
        addOtherNode(s, "IsKeyReleased", &.{.{ .key = "key", .value_text = "\"space\"" }}) catch |err| nodeAddErr(err);
    }
    if (zgui.button("+ IsMouseButtonDown", .{})) {
        addOtherNode(s, "IsMouseButtonDown", &.{.{ .key = "button", .value_text = "\"left\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ IsMouseButtonPressed", .{})) {
        addOtherNode(s, "IsMouseButtonPressed", &.{.{ .key = "button", .value_text = "\"left\"" }}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ IsMouseButtonReleased", .{})) {
        addOtherNode(s, "IsMouseButtonReleased", &.{.{ .key = "button", .value_text = "\"left\"" }}) catch |err| nodeAddErr(err);
    }
    if (zgui.button("+ GetMouseX", .{})) {
        addOtherNode(s, "GetMouseX", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ GetMouseY", .{})) {
        addOtherNode(s, "GetMouseY", &.{}) catch |err| nodeAddErr(err);
    }
    zgui.sameLine(.{});
    if (zgui.button("+ GetMouseWheel", .{})) {
        addOtherNode(s, "GetMouseWheel", &.{}) catch |err| nodeAddErr(err);
    }

    // Raw `Call` escape hatch (RFC §7) — surfaced separately so a user
    // who finds it has knowingly opted into raw Zig source rather than
    // mistaking it for a normal palette entry.
    zgui.spacing();
    if (zgui.button("+ Add raw call...", .{})) {
        zgui.openPopup("##raw_call_dialog", .{});
    }
    zgui.sameLine(.{});
    zgui.textDisabled("(escape hatch — drops Zig source)", .{});
    renderRawCallDialog(s);

    // ── Annotations section (labelle-gui#188) ──
    // Comment / group frames — purely cosmetic backdrops behind the
    // nodes, ignored by codegen. A "+ Comment" drops a default-sized
    // frame; editing happens in the selected-comment inspector below.
    zgui.spacing();
    zgui.separator();
    zgui.text("Annotations", .{});
    if (zgui.button("+ Comment", .{})) {
        appendComment(s) catch |err| {
            std.log.err("flow: add comment failed: {s}", .{@errorName(err)});
        };
    }
    zgui.sameLine(.{});
    zgui.textDisabled("(cosmetic frame — ignored by codegen)", .{});

    // ── Per-plugin sections (RFC §1, §6) ──
    // For phase 4 MVP this walks the static `flow_node_catalog`.
    // TODO(O1 follow-up): replace with an assembler-emitted sidecar so
    // the palette tracks every plugin the project links —
    // labelle-box2d, future plugins, and the game's own
    // `scripts/<module>.zig` FlowNodes blocks.
    zgui.spacing();
    zgui.separator();
    zgui.text("Plugins", .{});
    renderPluginPaletteSections(s);
}

/// Render one collapsible header per discovered category (RFC §6 —
/// palette grouped by plugin / category). Walks the static
/// `flow_node_catalog.entries`.
fn renderPluginPaletteSections(s: *FlowDocState) void {
    // Walk categories in order of first appearance — same order the
    // static catalog lists them, which is the assembler's discovery
    // order in practice. Stack-buffered cap of 16 categories
    // comfortably covers labelle-box2d + a future handful of plugins.
    var cat_buf: [16][]const u8 = undefined;
    var cat_count: usize = 0;
    for (node_catalog.entries) |e| {
        var already = false;
        for (cat_buf[0..cat_count]) |c| if (std.mem.eql(u8, c, e.category)) {
            already = true;
            break;
        };
        if (!already and cat_count < cat_buf.len) {
            cat_buf[cat_count] = e.category;
            cat_count += 1;
        }
    }

    var label_buf: [128:0]u8 = undefined;
    for (cat_buf[0..cat_count]) |category| {
        const label = std.fmt.bufPrintZ(&label_buf, "{s}##cat_{s}", .{ category, category }) catch continue;
        if (zgui.collapsingHeader(label, .{ .default_open = true })) {
            for (node_catalog.entries) |e| {
                if (!std.mem.eql(u8, e.category, category)) continue;

                // Color-code by command/reporter so a glance at the
                // palette communicates the visual shape the canvas will
                // give the dropped node (RFC §6).
                const kind_color: [4]f32 = switch (e.kind) {
                    .command => .{ 0.6, 0.85, 1.0, 1.0 },
                    .reporter => .{ 0.7, 0.95, 0.7, 1.0 },
                };
                _ = kind_color;

                // Button label includes the display name; the dotted
                // form goes in the tooltip.
                var btn_buf: [256:0]u8 = undefined;
                const btn = std.fmt.bufPrintZ(
                    &btn_buf,
                    "+ {s}##plug_{s}",
                    .{ e.display_name, e.name },
                ) catch continue;
                if (zgui.button(btn, .{})) {
                    addCustomNode(s, e.name) catch |err| nodeAddErr(err);
                }
                if (zgui.isItemHovered(.{})) {
                    if (zgui.beginTooltip()) {
                        zgui.text("{s}", .{e.name});
                        if (e.docs.len > 0) {
                            zgui.spacing();
                            zgui.text("{s}", .{e.docs});
                        }
                        zgui.spacing();
                        zgui.textDisabled("{s}", .{@tagName(e.kind)});
                        zgui.endTooltip();
                    }
                }
            }
        }
    }
    if (cat_count == 0) {
        zgui.textDisabled("(no plugin FlowNodes discovered)", .{});
    }
}

/// "Add raw call…" modal (RFC §7). Captures the Zig source text the
/// `Call` node's `callee` field will hold. The raw Call node is *off*
/// the default palette — surfaced here so a user has to knowingly opt
/// in rather than misuse it as a generic node.
fn renderRawCallDialog(s: *FlowDocState) void {
    // One stable buffer per session — the modal is non-modal, so the
    // user can type freely and we don't lose state on a missed click.
    // Buffer is `static`-equivalent via a `struct {}` namespace.
    const dlg = struct {
        var text: [256:0]u8 = .{0} ** 256;
    };

    if (zgui.beginPopupModal("##raw_call_dialog", .{ .flags = .{ .always_auto_resize = true } })) {
        zgui.text("Add raw Call node (RFC §7 escape hatch)", .{});
        zgui.textDisabled("Drops a `Call` node carrying the Zig source text below.", .{});
        zgui.textDisabled("Pin interface is unknown to the editor — codegen lowers it directly.", .{});
        zgui.spacing();
        zgui.setNextItemWidth(360);
        _ = zgui.inputText("##raw_call_text", .{ .buf = &dlg.text });
        zgui.sameLine(.{});
        zgui.textDisabled("callee (Zig expression)", .{});
        zgui.spacing();
        if (zgui.button("Add", .{})) {
            const txt = std.mem.sliceTo(&dlg.text, 0);
            if (txt.len > 0) {
                addRawCallNode(s, txt) catch |err| {
                    std.log.err("flow: add raw call failed: {s}", .{@errorName(err)});
                };
                @memset(&dlg.text, 0);
            }
            zgui.closeCurrentPopup();
        }
        zgui.sameLine(.{});
        if (zgui.button("Cancel", .{})) {
            zgui.closeCurrentPopup();
        }
        zgui.endPopup();
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
        .emit => {
            zgui.text("Event", .{});
            // Event-name dropdown — the same picker `renderEventEditor`
            // uses for `OnEvent`. A free-text fallback covers events not
            // yet in the catalog (a project-local event the static table
            // doesn't know about); the editor stores whatever the user
            // picks/types verbatim and codegen validates against the
            // assembler-built union.
            renderEventNameCombo(s, "##emit_event", &n.event_ref);
            if (n.event_ref.len > 0 and !event_catalog.isKnown(n.event_ref)) {
                zgui.textColored(
                    .{ 1.0, 0.65, 0.2, 1.0 },
                    "(unknown event — pins blank, codegen will validate)",
                    .{},
                );
            }
            if (event_catalog.lookup(n.event_ref)) |entry| {
                zgui.spacing();
                zgui.textDisabled("Payload fields (wire each input pin):", .{});
                for (entry.fields) |f| {
                    zgui.bulletText("{s}: {s}", .{ f.name, f.type_name });
                }
                if (entry.description.len > 0) {
                    zgui.spacing();
                    zgui.textDisabled("— {s}", .{entry.description});
                }
            }
        },
        .event => {
            // RFC-FLOW-VOCABULARY §3 — graph-level trigger. Same picker
            // as `Emit`, different role (output pins, not input).
            zgui.text("Event name", .{});
            renderEventNameCombo(s, "##event_node_name", &n.event_ref);
            if (n.event_ref.len > 0 and !event_catalog.isKnown(n.event_ref)) {
                zgui.textColored(
                    .{ 1.0, 0.65, 0.2, 1.0 },
                    "(unknown event — codegen will validate against PluginEvents)",
                    .{},
                );
            }
            if (event_catalog.lookup(n.event_ref)) |entry| {
                zgui.spacing();
                zgui.textDisabled("Payload (exposed as output pins):", .{});
                for (entry.fields) |f| {
                    zgui.bulletText("{s}: {s}", .{ f.name, f.type_name });
                }
                if (entry.description.len > 0) {
                    zgui.spacing();
                    zgui.textDisabled("— {s}", .{entry.description});
                }
            }
        },
        .get_variable, .set_variable, .change_variable, .clear_variable, .has_value_variable => {
            renderVariableOpInspector(s, n);
        },
        .custom_node => {
            renderCustomNodeInspector(s, n);
        },
        .other => {
            if (flow_io.otherFieldSpec(n.type_name)) |spec| {
                renderOtherField(s, n, spec);
            } else {
                // A genuinely-unknown node type: no widget, just the
                // verbatim round-tripped fields.
                zgui.textDisabled("This node type is not field-editable.", .{});
                zgui.textDisabled("Its fields round-trip verbatim:", .{});
                for (n.extras) |kv| {
                    zgui.bulletText("{s}: {s}", .{ kv.key, kv.value_text });
                }
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

/// Inspector editing for a recognised `.other` node type (`BinOp`,
/// `GetComponent`, `SetField`, `Literal`, `Identifier`, `Call`). The
/// value lives in `n.extras` under `spec.key`; the widget writes the
/// canonical JSON text back there via `flow_io.setExtraValue`, so the
/// deterministic writer emits it unchanged and any other (genuinely
/// unknown) key on the node still round-trips verbatim.
fn renderOtherField(s: *FlowDocState, n: *flow_io.Node, spec: flow_io.OtherFieldSpec) void {
    const a = s.doc.allocator();
    const current = flow_io.extraValue(n.*, spec.key) orelse "";

    zgui.text("{s}", .{spec.label});
    switch (spec.widget) {
        .op_combo => {
            // `op` is stored as a JSON string (`"add"`); decode to the
            // bare word to match against the choice list. Decode into a
            // stack buffer — this runs every frame, so allocating on the
            // doc arena here would leak for as long as the node stays
            // selected.
            var decode_buf: IdentBuf = undefined;
            const decoded = flow_io.decodeStringValueBufChecked(&decode_buf, current);
            if (decoded.truncated) {
                // A stored `op` longer than the identifier buffer can't
                // be matched against the choice list without loss — the
                // combo would show a blank selection, and picking any
                // operator would silently overwrite the full stored
                // value on save. Treat it like the `.text` too-long case:
                // show a read-only view and write nothing, so the
                // original `op` round-trips verbatim.
                renderTooLongField(current);
            } else {
                // A missing or invalid stored `op` is treated as *no
                // selection* (blank preview) rather than silently
                // previewing the first choice. Otherwise picking the
                // displayed default (`add`) wouldn't register as a change
                // and could never be committed — the combo would show
                // `add` without it ever being written to the node.
                var sel: ?usize = null;
                for (spec.choices, 0..) |op, i| {
                    if (std.mem.eql(u8, op, decoded.text)) sel = i;
                }
                var preview_z: IdentBuf = undefined;
                seedBuf(&preview_z, if (sel) |i| spec.choices[i] else "");
                if (zgui.beginCombo("##other_op", .{ .preview_value = &preview_z })) {
                    for (spec.choices, 0..) |op, i| {
                        var op_z: IdentBuf = undefined;
                        seedBuf(&op_z, op);
                        if (zgui.selectable(&op_z, .{ .selected = sel == i })) {
                            // `selectable` fires on every click — commit
                            // even when the picked op equals the previewed
                            // one, so selecting `add` on a node with no
                            // valid `op` still writes and marks dirty.
                            const encoded = flow_io.encodeStringValue(a, op) catch return;
                            flow_io.setExtraValue(a, n, spec.key, encoded) catch return;
                            s.is_dirty = true;
                        }
                    }
                    zgui.endCombo();
                }
            }
        },
        .text => {
            // Identifier-like fields are stored as JSON strings; the
            // widget edits the bare inner text. Decode into a stack
            // buffer — see `.op_combo` above: a per-frame doc-arena
            // allocation here would leak while the node stays selected.
            var buf: IdentBuf = undefined;
            const decoded = flow_io.decodeStringValueBufChecked(&buf, current);
            if (decoded.truncated) {
                // The value is longer than the inline editor can hold.
                // Editing the truncated view and saving would overwrite
                // the real stored value with a partial copy — silent
                // data loss. Show a read-only, disabled widget instead
                // so the original `extras` value round-trips untouched.
                renderTooLongField(current);
            } else if (zgui.inputText("##other_text", .{ .buf = &buf })) {
                const raw = std.mem.sliceTo(&buf, 0);
                const encoded = flow_io.encodeStringValue(a, raw) catch return;
                flow_io.setExtraValue(a, n, spec.key, encoded) catch return;
                s.is_dirty = true;
            }
        },
        .literal => {
            // `Literal.value` is any JSON type — edit the canonical text
            // directly and normalise so a save can't emit invalid JSON.
            var buf: ValueBuf = undefined;
            // `ValueBuf` reserves one byte for the widget's NUL
            // sentinel; a `value` of `buf.len` chars or more can't be
            // seeded losslessly, so seeding it and committing on the
            // first `inputText` keystroke would write back a truncated
            // literal. Detect that and fall back to a read-only view.
            if (current.len > buf.len - 1) {
                renderTooLongField(current);
            } else {
                seedBuf(&buf, current);
                if (zgui.inputText("##other_literal", .{ .buf = &buf })) {
                    const raw = std.mem.sliceTo(&buf, 0);
                    const norm = flow_io.normalizeValueText(a, raw) catch return;
                    flow_io.setExtraValue(a, n, spec.key, norm) catch return;
                    s.is_dirty = true;
                }
                zgui.textDisabled("(JSON literal — e.g. 25, 1.5, \"txt\", true)", .{});
            }
        },
    }

    // Any other keys on the node (beyond the one editable field) still
    // round-trip; surface them so the user sees nothing is hidden.
    var has_other = false;
    for (n.extras) |kv| {
        if (std.mem.eql(u8, kv.key, spec.key)) continue;
        has_other = true;
    }
    if (has_other) {
        zgui.spacing();
        zgui.textDisabled("Other fields (round-trip verbatim):", .{});
        for (n.extras) |kv| {
            if (std.mem.eql(u8, kv.key, spec.key)) continue;
            zgui.bulletText("{s}: {s}", .{ kv.key, kv.value_text });
        }
    }
}

/// Inspector for the variable-op nodes (RFC §4). Lets the user pick
/// which declared variable to target (with a free-text fallback so a
/// project-local variable not in `s.doc.variables` doesn't deadlock the
/// editor) and edit the inline `by` literal on `ChangeVariable`. A
/// `ClearVariable` / `HasValueVariable` on a non-nullable variable is
/// flagged — codegen rejects it at build time per RFC §4.
fn renderVariableOpInspector(s: *FlowDocState, n: *flow_io.Node) void {
    const a = s.doc.allocator();
    zgui.text("Variable", .{});
    var preview: IdentBuf = undefined;
    seedBuf(&preview, n.variable_ref);
    if (zgui.beginCombo("##var_target", .{ .preview_value = &preview })) {
        if (zgui.selectable("<choose>", .{ .selected = n.variable_ref.len == 0 })) {
            n.variable_ref = a.dupe(u8, "") catch n.variable_ref;
            s.is_dirty = true;
        }
        for (s.doc.variables) |v| {
            var row: IdentBuf = undefined;
            seedBuf(&row, v.name);
            const sel = std.mem.eql(u8, v.name, n.variable_ref);
            if (zgui.selectable(&row, .{ .selected = sel })) {
                if (!sel) {
                    n.variable_ref = a.dupe(u8, v.name) catch n.variable_ref;
                    s.is_dirty = true;
                }
            }
            if (zgui.isItemHovered(.{})) {
                if (zgui.beginTooltip()) {
                    zgui.text("{s}: {s}", .{ v.name, v.type_name });
                    zgui.endTooltip();
                }
            }
        }
        zgui.endCombo();
    }
    // Free-text fallback so a variable declared in a referenced file (or
    // not yet declared) doesn't block authoring.
    var fb_buf: IdentBuf = undefined;
    seedBuf(&fb_buf, n.variable_ref);
    zgui.setNextItemWidth(160);
    if (zgui.inputText("##var_target_text", .{ .buf = &fb_buf })) {
        const raw = std.mem.sliceTo(&fb_buf, 0);
        n.variable_ref = a.dupe(u8, raw) catch n.variable_ref;
        s.is_dirty = true;
    }
    zgui.sameLine(.{});
    zgui.textDisabled("(or type a name)", .{});

    // Surface the variable's type when known so the inspector reads at
    // a glance.
    for (s.doc.variables) |v| {
        if (std.mem.eql(u8, v.name, n.variable_ref)) {
            zgui.textDisabled("type: {s}", .{v.type_name});
            // Nullability gate for Clear/HasValue (RFC §4).
            if ((n.kind == .clear_variable or n.kind == .has_value_variable) and !v.isNullable()) {
                zgui.textColored(
                    .{ 1.0, 0.4, 0.4, 1.0 },
                    "(needs a nullable `?T` variable)",
                    .{},
                );
            }
            break;
        }
    } else {
        if (n.variable_ref.len > 0) {
            zgui.textColored(
                .{ 1.0, 0.65, 0.2, 1.0 },
                "(undeclared — declare it in the Variables panel)",
                .{},
            );
        }
    }

    // `ChangeVariable.by` inline literal — Scratch-style "change X by [N]".
    if (n.kind == .change_variable) {
        zgui.spacing();
        zgui.text("Inline `by` (JSON literal)", .{});
        var by_buf: ValueBuf = undefined;
        seedBuf(&by_buf, n.by_text);
        if (zgui.inputText("##var_by", .{ .buf = &by_buf })) {
            const txt = std.mem.sliceTo(&by_buf, 0);
            n.by_text = if (txt.len == 0)
                (a.dupe(u8, "1") catch n.by_text)
            else
                (flow_io.normalizeValueText(a, txt) catch n.by_text);
            s.is_dirty = true;
        }
    }
}

/// Inspector for plugin/script-contributed FlowNode references
/// (`CustomNode` — RFC §1, §6). Dropdown sourced from
/// `flow_node_catalog`, free-text fallback for entries not yet in the
/// static catalog.
fn renderCustomNodeInspector(s: *FlowDocState, n: *flow_io.Node) void {
    const a = s.doc.allocator();
    zgui.text("FlowNode (dotted name)", .{});

    var preview: IdentBuf = undefined;
    seedBuf(&preview, n.custom_name);
    if (zgui.beginCombo("##custom_target", .{ .preview_value = &preview })) {
        if (zgui.selectable("<choose>", .{ .selected = n.custom_name.len == 0 })) {
            n.custom_name = a.dupe(u8, "") catch n.custom_name;
            s.is_dirty = true;
        }
        for (node_catalog.entries) |entry| {
            var row: IdentBuf = undefined;
            seedBuf(&row, entry.name);
            const sel = std.mem.eql(u8, entry.name, n.custom_name);
            if (zgui.selectable(&row, .{ .selected = sel })) {
                if (!sel) {
                    n.custom_name = a.dupe(u8, entry.name) catch n.custom_name;
                    s.is_dirty = true;
                }
            }
            if (entry.docs.len > 0 and zgui.isItemHovered(.{})) {
                if (zgui.beginTooltip()) {
                    zgui.text("{s}", .{entry.docs});
                    zgui.endTooltip();
                }
            }
        }
        zgui.endCombo();
    }
    var fb_buf: IdentBuf = undefined;
    seedBuf(&fb_buf, n.custom_name);
    zgui.setNextItemWidth(200);
    if (zgui.inputText("##custom_target_text", .{ .buf = &fb_buf })) {
        const raw = std.mem.sliceTo(&fb_buf, 0);
        n.custom_name = a.dupe(u8, raw) catch n.custom_name;
        s.is_dirty = true;
    }
    zgui.sameLine(.{});
    zgui.textDisabled("(or type a dotted name)", .{});

    if (node_catalog.lookup(n.custom_name)) |entry| {
        zgui.spacing();
        zgui.textDisabled("Kind: {s}", .{@tagName(entry.kind)});
        if (entry.docs.len > 0) zgui.textDisabled("— {s}", .{entry.docs});
        zgui.spacing();
        zgui.textDisabled("Pins:", .{});
        for (entry.pins) |p| {
            const arrow: []const u8 = if (p.dir == .input) "→" else "←";
            zgui.bulletText("{s} {s}: {s}", .{ arrow, p.label, p.type_name });
        }
    } else if (n.custom_name.len > 0) {
        zgui.textColored(
            .{ 1.0, 0.65, 0.2, 1.0 },
            "(unknown FlowNode — codegen will validate against PluginFlowNodes)",
            .{},
        );
    }
}

/// Render a recognised field whose stored value is too long for the
/// inline editor. The value is shown in a disabled (read-only) input so
/// the user can see it in full-ish, with a hint explaining why it can't
/// be edited here. Crucially, nothing is written back: the original
/// `extras` value is left untouched so a save round-trips it verbatim.
fn renderTooLongField(value: []const u8) void {
    zgui.beginDisabled(.{ .disabled = true });
    // A stack buffer just for display — wider than the edit buffers so
    // the user sees as much as practical. The widget is disabled, so
    // even a truncated preview here can never be committed.
    var view: [1024:0]u8 = undefined;
    seedBuf(&view, value);
    _ = zgui.inputText("##other_too_long", .{ .buf = &view });
    zgui.endDisabled();
    zgui.textDisabled(
        "(value too long to edit inline — edit the .flow.jsonc file directly)",
        .{},
    );
}

// ─── Mutators ───────────────────────────────────────────────────────────

fn appendVariable(s: *FlowDocState) !void {
    const a = s.doc.allocator();
    const out = try a.alloc(flow_io.Variable, s.doc.variables.len + 1);
    @memcpy(out[0..s.doc.variables.len], s.doc.variables);
    out[s.doc.variables.len] = .{
        .name = try a.dupe(u8, "var"),
        .type_name = try a.dupe(u8, "i32"),
        .default_text = try a.dupe(u8, "0"),
    };
    s.doc.variables = out;
    s.is_dirty = true;
}

fn removeVariable(s: *FlowDocState, idx: usize) !void {
    const a = s.doc.allocator();
    s.doc.variables = try removeAt(flow_io.Variable, a, s.doc.variables, idx);
    s.is_dirty = true;
}

/// Synthesize a variable-op node (RFC §4) pre-named to `var_name`. The
/// variables sidebar uses this so the user doesn't retype the variable
/// name once it is already declared.
fn addVarOpNode(s: *FlowDocState, kind: flow_io.NodeKind, var_name: []const u8) !void {
    const a = s.doc.allocator();
    const id = s.doc.nextNodeId();
    const type_name = kind.typeName() orelse return error.UnsupportedKind;
    const offset: f32 = @floatFromInt((s.doc.nodes.len % 8) * 30);
    var node: flow_io.Node = .{
        .id = id,
        .type_name = try a.dupe(u8, type_name),
        .kind = kind,
        .pos = .{ 240 + offset, 40 + offset },
        .variable_ref = try a.dupe(u8, var_name),
    };
    // `ChangeVariable` defaults to `by: 1` — codegen treats omitted `by`
    // the same way, but materialize it on save so the file is
    // self-describing (see the RFC-vocabulary "ChangeVariable defaults
    // to by:1" round-trip test).
    if (kind == .change_variable) node.by_text = try a.dupe(u8, "1");
    s.doc.nodes = try growNodes(a, s.doc.nodes, node);
    s.needs_layout = true;
    s.is_dirty = true;
}

/// Synthesize a `CustomNode` for the named plugin FlowNode. The palette
/// section per-plugin uses this when the user clicks an entry.
fn addCustomNode(s: *FlowDocState, name: []const u8) !void {
    const a = s.doc.allocator();
    const id = s.doc.nextNodeId();
    const offset: f32 = @floatFromInt((s.doc.nodes.len % 8) * 30);
    const node: flow_io.Node = .{
        .id = id,
        .type_name = try a.dupe(u8, "CustomNode"),
        .kind = .custom_node,
        .pos = .{ 240 + offset, 60 + offset },
        .custom_name = try a.dupe(u8, name),
    };
    s.doc.nodes = try growNodes(a, s.doc.nodes, node);
    s.needs_layout = true;
    s.is_dirty = true;
}

/// Synthesize a raw `Call` node (RFC §7 escape hatch). The `callee`
/// text is whatever the dialog captured — Zig source, evaluated by the
/// generated module's surrounding scope.
fn addRawCallNode(s: *FlowDocState, callee: []const u8) !void {
    const a = s.doc.allocator();
    const id = s.doc.nextNodeId();
    const offset: f32 = @floatFromInt((s.doc.nodes.len % 8) * 30);

    // Encode the callee as a JSON-string extras value so the
    // deterministic writer emits it verbatim. `Call` is registered as
    // an `.other` kind with `callee` in `extras`.
    var encoded_buf: std.ArrayList(u8) = .empty;
    defer encoded_buf.deinit(a);
    {
        // Inline JSON-string-quote `callee` into `encoded_buf`. Keep
        // the encoder in step with flow_io.encodeStringValue.
        const encoded = try flow_io.encodeStringValue(a, callee);
        defer a.free(encoded);
        try encoded_buf.appendSlice(a, encoded);
    }

    var node: flow_io.Node = .{
        .id = id,
        .type_name = try a.dupe(u8, "Call"),
        .kind = .other,
        .pos = .{ 240 + offset, 60 + offset },
    };
    // Put the `callee` key in extras — `flow_io.other_field_specs` already
    // declares "Call" as field-editable on `callee`.
    try flow_io.setExtraValue(a, &node, "callee", encoded_buf.items);
    s.doc.nodes = try growNodes(a, s.doc.nodes, node);
    s.needs_layout = true;
    s.is_dirty = true;
}

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
        // A fresh `Emit` starts with no event chosen — the inspector
        // dropdown will let the user pick one from the catalog. Codegen
        // would reject an unwired Emit at build time; the editor surfaces
        // a "no event selected" hint on the canvas in the meantime.
        .emit, .event => node.event_ref = try a.dupe(u8, ""),
        .get_variable, .set_variable, .clear_variable, .has_value_variable => {
            node.variable_ref = try a.dupe(u8, "");
        },
        .change_variable => {
            node.variable_ref = try a.dupe(u8, "");
            node.by_text = try a.dupe(u8, "1");
        },
        .custom_node => node.custom_name = try a.dupe(u8, ""),
        .other => unreachable,
    }
    s.doc.nodes = try growNodes(a, s.doc.nodes, node);
    s.needs_layout = true; // re-seed so the new node's pos is applied
    s.is_dirty = true;
}

/// Palette path for the `.other`-kind expression/control nodes (`BinOp`,
/// `Compare`, `Logic`, `Literal`, `Identifier`, `SetField`, `Branch`,
/// `ForRange`, `While`). `addNode` can't reach these — it routes through
/// `kind.typeName()`, which is null for `.other` — so this seeds an
/// `.other` node with `type_name` plus the editable extras the inspector
/// exposes via `flow_io.otherFieldSpec`, leaving the node immediately
/// valid and inspector-editable. The heavy lifting (id allocation,
/// staggered pos, arena-duped extras) lives in the pure
/// `flow_io.appendOtherNode`; this only flips the editor's layout/dirty
/// flags so the new node's position seeds onto the canvas.
fn addOtherNode(
    s: *FlowDocState,
    type_name: []const u8,
    default_extras: []const flow_io.KeyValue,
) !void {
    _ = try flow_io.appendOtherNode(&s.doc, type_name, default_extras);
    s.needs_layout = true; // re-seed so the new node's pos is applied
    s.is_dirty = true;
}

/// Append a fresh comment / group frame (labelle-gui#188) at a staggered
/// default position so successive adds don't stack on one spot. Marks the
/// doc dirty and re-seeds the layout so the new frame's position is
/// applied to the canvas. Independent of nodes — a flow with no nodes can
/// still carry comments.
fn appendComment(s: *FlowDocState) !void {
    const a = s.doc.allocator();
    const offset: f32 = @floatFromInt((s.doc.comments.len % 8) * 24);
    const c: flow_io.Comment = .{
        .text = try a.dupe(u8, "Comment"),
        .x = 24 + offset,
        .y = 24 + offset,
        .w = 220,
        .h = 140,
        // Stable editor id (labelle-gui#188) — drawn from the shared node
        // id counter (`nextNodeId`, labelle-gui#203) so the comment's
        // node-editor id can't collide with a node's id or a pin id.
        // Persisted so it survives loads and never aliases another frame's
        // editor state after a sibling delete.
        .id = s.doc.nextNodeId(),
    };
    s.doc.comments = try growComments(a, s.doc.comments, c);
    s.needs_layout = true; // re-seed so the new frame's pos is applied
    s.is_dirty = true;
}

fn deleteComment(s: *FlowDocState, idx: usize) !void {
    const a = s.doc.allocator();
    s.doc.comments = try removeAt(flow_io.Comment, a, s.doc.comments, idx);
    // Surviving frames keep their *stable* ids (labelle-gui#188), so the
    // editor's per-frame state stays bound to the right frame — no index
    // shift, no editor-state bleed. Re-seed positions anyway so the
    // persisted geometry is re-applied on the next layout pass.
    s.needs_layout = true;
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
    // Drop any exec edges touching the deleted node too — otherwise a
    // dangling `exec_edges` entry survives the delete and corrupts the
    // control flow on save (flow-codegen#8/#21, bugbot).
    var kept_exec: std.ArrayList(flow_io.ExecEdge) = .empty;
    for (s.doc.exec_edges) |x| {
        if (x.from_node == id or x.to_node == id) continue;
        try kept_exec.append(a, x);
    }
    s.doc.exec_edges = try kept_exec.toOwnedSlice(a);
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

/// Append a control `flow_io.ExecEdge` from a named exec output pin to
/// a bare target node (issue #196). The caller (`handleExecLinkCreate`)
/// has already validated the edge via `validateExecEdge`; this only
/// dupes the pin name into the doc arena and grows the slice.
fn appendExecEdge(s: *FlowDocState, from_node: u32, from_pin: []const u8, to_node: u32) !void {
    const a = s.doc.allocator();
    const edge: flow_io.ExecEdge = .{
        .from_node = from_node,
        .from_pin = try a.dupe(u8, from_pin),
        .to_node = to_node,
    };
    s.doc.exec_edges = try growExecEdges(a, s.doc.exec_edges, edge);
    s.is_dirty = true;
}

/// Remove the control `ExecEdge` whose `explicitExecLinkId` matches
/// `id` (issue #196). Returns `true` when one matched and was removed,
/// `false` otherwise — the caller rejects the editor's delete on
/// `false` so the canvas and `exec_edges` stay in agreement (mirrors
/// `deleteEdgeByLinkId` for data edges). The *derived* #172 arrows use
/// `execLinkId` ids that never match here, so they stay read-only.
fn deleteExecEdgeByLinkId(s: *FlowDocState, id: u64) !bool {
    const a = s.doc.allocator();
    var idx: ?usize = null;
    for (s.doc.exec_edges, 0..) |x, i| {
        if (explicitExecLinkId(x.from_node, x.from_pin, x.to_node) == id) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return false;
    s.doc.exec_edges = try removeAt(flow_io.ExecEdge, a, s.doc.exec_edges, i);
    s.is_dirty = true;
    return true;
}

/// Rewrite the edge at `idx` so it wires `out_pin` → `in_pin`. The
/// caller (`handleLinkReroute`) has already validated direction, node
/// distinctness and duplication; this only re-dupes the endpoint
/// strings into the doc arena and overwrites the edge in place. Editing
/// in place keeps the edge's array slot — only its endpoints change —
/// so node/pin positions and selection stay stable.
fn rerouteEdge(s: *FlowDocState, idx: usize, out_pin: PinEntry, in_pin: PinEntry) !void {
    const a = s.doc.allocator();
    const from_pin = try a.dupe(u8, out_pin.name);
    const to_pin = try a.dupe(u8, in_pin.name);
    // Both dupes succeeded — commit atomically so a partial failure
    // can't leave the edge half-rewritten.
    s.doc.edges[idx] = .{
        .from_node = out_pin.node_id,
        .from_pin = from_pin,
        .to_node = in_pin.node_id,
        .to_pin = to_pin,
    };
    s.is_dirty = true;
}

/// Remove whatever link `id` names — a data `Edge` or an explicit
/// control `ExecEdge` (issue #196). Tries the data edges first (the
/// common case), then the explicit exec edges. Returns `true` when one
/// matched and was removed, `false` when nothing did — the *derived*
/// #172 exec spine uses `execLinkId` ids that match neither table, so
/// those arrows stay read-only and a delete on them is rejected. The
/// caller rejects the editor's delete on `false`.
fn deleteLinkByLinkId(s: *FlowDocState, id: u64) !bool {
    if (try deleteEdgeByLinkId(s, id)) return true;
    return deleteExecEdgeByLinkId(s, id);
}

/// Remove the edge whose `linkId` matches `id`. Returns `true` when an
/// edge matched and was removed, `false` when nothing matched — the
/// editor may report a delete for a link we don't own, or for an id
/// that went stale after a same-frame re-route changed the edge's
/// `linkId`. The caller must reject the editor's delete on `false` so
/// the canvas and `doc.edges` stay in agreement.
fn deleteEdgeByLinkId(s: *FlowDocState, id: u64) !bool {
    const a = s.doc.allocator();
    var idx: ?usize = null;
    for (s.doc.edges, 0..) |e, i| {
        if (linkId(e) == id) {
            idx = i;
            break;
        }
    }
    const i = idx orelse return false;
    s.doc.edges = try removeAt(flow_io.Edge, a, s.doc.edges, i);
    s.is_dirty = true;
    return true;
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

fn growExecEdges(a: std.mem.Allocator, src: []flow_io.ExecEdge, add: flow_io.ExecEdge) ![]flow_io.ExecEdge {
    const out = try a.alloc(flow_io.ExecEdge, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = add;
    return out;
}

fn growComments(a: std.mem.Allocator, src: []flow_io.Comment, add: flow_io.Comment) ![]flow_io.Comment {
    const out = try a.alloc(flow_io.Comment, src.len + 1);
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
