//! Load-time `Subflow` reference-cycle check for the `.flow.jsonc`
//! editor (issue #159).
//!
//! A `.flow.jsonc` flow can reference other flows through `Subflow`
//! nodes (`flow_io.Node.flow_ref`). flow-codegen rejects a cyclic
//! reference graph, but only at build time — by then the editor has
//! long since accepted the file. This module resolves the transitive
//! set of referenced flows and flags two problems the editor should
//! surface immediately:
//!
//!   - **A reference cycle** — `a → b → … → a`. flow-codegen raises
//!     `FlowReferenceCycle` for this; codegen can't generate a finite
//!     program from an infinitely-nested flow.
//!   - **An unresolved reference** — a `Subflow` names a flow whose
//!     effective registry name (RFC §5: the flow's top-level `name`,
//!     else its filename basename) matches no `.flow.jsonc` file under
//!     `scripts/flows/`. flow-codegen raises `UnknownFlowRef`.
//!   - **A broken referenced file** — a `Subflow` resolves to a file
//!     that exists on disk but fails to load/parse (a JSON or schema
//!     error). flow-codegen can't read it either; the editor surfaces
//!     this distinctly from a plain missing file so the author knows to
//!     fix the file rather than create one.
//!
//! The pure walk (`detectCycle`) is decoupled from the filesystem via
//! a `Resolver` callback so it can be unit-tested with an in-memory
//! reference graph. `analyzeProject` wires the callback to read flow
//! files from a project's `scripts/flows/` directory.
//!
//! Reusing flow-codegen's own registry was considered (the ticket
//! suggested it) but its published `v0.1.0` package predates the
//! `.flow.jsonc` schema — it still parses the older `.flow.zon`
//! format and exposes no registry / cycle-detection surface. An
//! equivalent depth-first walk is implemented here instead.

const std = @import("std");
const io_global = @import("io_global.zig");
const flow_io = @import("flow_io.zig");

/// Placeholder used as `DuplicateName.path_a` when the open flow tab
/// itself collides with an on-disk file. The open tab may be unsaved, so
/// it has no path to report — this marker tells the banner the conflict
/// involves the flow the user is editing.
pub const open_flow_marker = "<open flow>";

/// Outcome of a cycle check.
pub const Status = union(enum) {
    /// No cycle, every transitively-referenced flow resolved.
    clean,
    /// A reference cycle was found. `chain` is the offending path of
    /// flow names, starting and ending with the same name
    /// (e.g. `a → b → a`).
    cycle: Chain,
    /// A `Subflow` referenced a flow whose effective registry name
    /// matches no `.flow.jsonc` file on disk. `chain` is the path of
    /// flow names from the entry flow down to (and including) the
    /// missing name.
    unresolved: Chain,
    /// A `Subflow` referenced a flow whose file exists on disk but
    /// failed to load or parse (a JSON / schema error). `chain` is the
    /// path of flow names from the entry flow down to (and including)
    /// the broken flow's name. Distinct from `unresolved` so the editor
    /// can tell "fix this file" apart from "create this file".
    parse_failed: Chain,
    /// Two `.flow.jsonc` files under `scripts/flows/` resolve to the
    /// *same* effective registry name (RFC §5). flow-codegen's
    /// `FlowRegistry` rejects this as `DuplicateFlowName` — the project
    /// is invalid. The editor surfaces it because the silent
    /// first-file-wins index would otherwise let a cycle hide in the
    /// shadowed file (its `Subflow` refs are never consulted). The open
    /// tab's own `entry_name` colliding with an on-disk file is the same
    /// fault and is reported here too.
    duplicate_name: DuplicateName,
};

/// The two `.flow.jsonc` files that share one effective registry name.
/// All three strings are owned by the report arena.
pub const DuplicateName = struct {
    /// The effective registry name both files claim.
    name: []const u8,
    /// Absolute path of the file indexed first for `name`. For an
    /// `entry_name` collision this is the entry's own marker
    /// `"<open flow>"` (the open tab has no on-disk path here — it may
    /// be unsaved), with `path_b` the conflicting on-disk file.
    path_a: []const u8,
    /// Absolute path of the second file claiming `name`.
    path_b: []const u8,
};

/// A snapshot of one `.flow.jsonc` file the analysis read while
/// resolving references — its path plus the `mtime`/`size` observed at
/// read time. `refreshCycleCheck` keeps this set so it can cheaply tell
/// whether any referenced file changed on disk since the last check
/// (which can create or break a *transitive* cycle the open flow's own
/// reference set never reveals).
pub const FileStamp = struct {
    /// Absolute path of the file, owned by the report arena.
    path: []const u8,
    /// Last-modification time in nanoseconds (`Io.Timestamp`), or
    /// `null` when the file could not be stat'd (e.g. it is missing).
    mtime_ns: ?i96,
    /// File size in bytes, or `null` when the file could not be stat'd.
    size: ?u64,
};

/// A `.flow.jsonc` path a reference *expected* but the analysis could
/// not successfully read — either it does not exist (`unresolved`) or it
/// exists but failed to parse (`parse_failed`). `refreshCycleCheck`
/// keeps this set alongside `read_files`: a previously-missing target
/// that later *appears* on disk (or a parse-failed one whose content
/// changes) can newly resolve a reference — possibly introducing a
/// cycle — so its appearance must re-trigger the check even though
/// `read_files` never tracked it.
pub const MissingStamp = struct {
    /// The absolute `.flow.jsonc` path the resolver expected for the
    /// reference — `<flows_dir>/<flow_ref>.flow.jsonc` for a missing
    /// target (the filename-basename fallback, RFC §5), or the broken
    /// file's own path for a `parse_failed` one. Owned by the report
    /// arena.
    path: []const u8,
    /// `true` when a file exists at `path` but failed to parse
    /// (`parse_failed`); `false` when nothing exists there
    /// (`unresolved`). For a parse-failed target a *content change*
    /// re-triggers the check (the file may now parse); for a missing one
    /// the file *appearing at all* re-triggers it.
    parse_failed: bool,
    /// `mtime`/`size` observed at analysis time. For a missing target
    /// these are `null` (nothing to stat); for a parse-failed one they
    /// stamp the broken file so a later content edit is noticed.
    mtime_ns: ?i96 = null,
    size: ?u64 = null,
};

/// An ordered list of flow names describing an offending reference
/// path. Owned by the allocator passed to the analysis call.
pub const Chain = struct {
    names: [][]const u8,

    /// Render the chain as `a → b → c` into `out`.
    pub fn format(self: Chain, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
        for (self.names, 0..) |name, i| {
            if (i > 0) try out.appendSlice(a, " \u{2192} ");
            try out.appendSlice(a, name);
        }
    }
};

/// A full analysis result plus the arena that owns every name string
/// and the chain slice. Caller frees via `deinit`.
pub const Report = struct {
    arena: *std.heap.ArenaAllocator,
    status: Status,
    /// The offending chain rendered as `a → b → c`, built once when the
    /// report is generated (the chain only changes when the analysis
    /// re-runs). Empty for a `clean` status. Owned by `arena`, so the
    /// UI can display it every frame without re-allocating.
    chain_text: []const u8 = "",
    /// Every `.flow.jsonc` file the analysis stat'd while resolving
    /// referenced flows, with the `mtime`/`size` observed at read time.
    /// `refreshCycleCheck` keeps this so it can detect an on-disk edit
    /// to a *referenced* flow — which can create or break a transitive
    /// cycle the open flow's own reference set never reveals. Owned by
    /// `arena`.
    read_files: []const FileStamp = &.{},
    /// Every reference target the analysis could *not* successfully read
    /// — a missing flow file (`unresolved`) or one that exists but
    /// failed to parse (`parse_failed`) — with the `.flow.jsonc` path the
    /// resolver expected for it. `refreshCycleCheck` keeps this so it can
    /// detect a previously-missing target *appearing* on disk (or a
    /// parse-failed one changing): either can newly resolve a reference
    /// and so must re-trigger the check. `read_files` never tracks these
    /// (it only stamps files that were successfully read). Owned by
    /// `arena`.
    unresolved_targets: []const MissingStamp = &.{},

    pub fn deinit(self: *Report) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    pub fn allocator(self: *Report) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Result of resolving one flow name to its outgoing `Subflow`
/// references — the value the `Resolver` callback returns.
pub const RefResult = union(enum) {
    /// The flow resolved; `.refs` is its (possibly empty) list of
    /// referenced flow names. The slice and its strings must outlive
    /// the `detectCycle` call.
    ok: []const []const u8,
    /// No flow with this effective name exists on disk.
    missing,
    /// A flow file with this name exists but failed to load or parse
    /// (a JSON / schema error). Distinct from `missing` so the editor
    /// can surface "fix this file" rather than "create this file".
    parse_failed,
};

/// Abstract source of a flow's outgoing `Subflow` references. The pure
/// `detectCycle` walk only needs this — it never touches the
/// filesystem. `refs` returns a `RefResult` classifying the named flow
/// as resolved (with its references), missing, or present-but-broken.
/// The returned slice and its strings must outlive the `detectCycle`
/// call (the project resolver allocates them on the report arena).
pub const Resolver = struct {
    ctx: *anyopaque,
    refsFn: *const fn (ctx: *anyopaque, name: []const u8) anyerror!RefResult,

    fn refs(self: Resolver, name: []const u8) anyerror!RefResult {
        return self.refsFn(self.ctx, name);
    }
};

/// Walk the `Subflow` reference graph reachable from `entry` and
/// classify it. Pure over `resolver` — no filesystem access here.
///
/// `arena` owns the chain in any non-`clean` result; the caller is
/// expected to wrap the whole thing in a `Report`.
pub fn detectCycle(
    arena: std.mem.Allocator,
    entry: []const u8,
    resolver: Resolver,
) !Status {
    var visited: std.StringHashMapUnmanaged(void) = .empty;
    defer visited.deinit(arena);
    // The current DFS path — also the on-stack set for cycle detection.
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(arena);

    return walk(arena, entry, resolver, &visited, &path);
}

/// Recursive DFS body. `path` holds the names on the current branch
/// (entry-to-current); a name reappearing in `path` is a cycle.
/// `visited` is the global "fully explored, no cycle below" set so a
/// diamond-shaped reference graph isn't re-walked exponentially.
fn walk(
    arena: std.mem.Allocator,
    name: []const u8,
    resolver: Resolver,
    visited: *std.StringHashMapUnmanaged(void),
    path: *std.ArrayList([]const u8),
) !Status {
    // Cycle: `name` is already on the current branch. The offending
    // chain is the path from that earlier occurrence to here, plus
    // `name` again to close the loop.
    for (path.items, 0..) |on_path, i| {
        if (std.mem.eql(u8, on_path, name)) {
            var chain: std.ArrayList([]const u8) = .empty;
            for (path.items[i..]) |n| {
                try chain.append(arena, try arena.dupe(u8, n));
            }
            try chain.append(arena, try arena.dupe(u8, name));
            return .{ .cycle = .{ .names = try chain.toOwnedSlice(arena) } };
        }
    }

    // Already proven clean on an earlier branch — skip.
    if (visited.contains(name)) return .clean;

    const child_refs = switch (try resolver.refs(name)) {
        .ok => |refs| refs,
        // `name` names no flow file on disk. Report the path that led
        // here, including `name`.
        .missing => return .{
            .unresolved = .{ .names = try chainTo(arena, path, name) },
        },
        // `name`'s flow file exists but is broken. Same chain shape as
        // `unresolved`, but a distinct status so the banner can say
        // "fix this file" rather than "create this file".
        .parse_failed => return .{
            .parse_failed = .{ .names = try chainTo(arena, path, name) },
        },
    };

    try path.append(arena, name);
    defer _ = path.pop();

    for (child_refs) |ref| {
        const sub = try walk(arena, ref, resolver, visited, path);
        if (sub != .clean) return sub;
    }

    // Mark explored only after the whole subtree proved clean. Use an
    // arena-owned copy so the key outlives any borrowed slice.
    try visited.put(arena, try arena.dupe(u8, name), {});
    return .clean;
}

/// Build the offending chain for a non-resolving flow: every name on
/// the current DFS path, then `tail` (the offending name itself).
/// Strings are duped onto `arena` so the chain outlives the walk's
/// borrowed `path`.
fn chainTo(
    arena: std.mem.Allocator,
    path: *std.ArrayList([]const u8),
    tail: []const u8,
) ![][]const u8 {
    var chain: std.ArrayList([]const u8) = .empty;
    for (path.items) |n| {
        try chain.append(arena, try arena.dupe(u8, n));
    }
    try chain.append(arena, try arena.dupe(u8, tail));
    return chain.toOwnedSlice(arena);
}

// ─── Project-backed resolver ────────────────────────────────────────────

/// Resolver context that reads referenced flows from a project's
/// `scripts/flows/` directory.
///
/// A `Subflow`'s `flow_ref` is the referenced flow's *effective
/// registry name* (RFC §5) — its explicit top-level `name`, or the
/// filename basename when `name` is absent. The on-disk filename can
/// therefore differ from the registry name a `flow_ref` carries.
///
/// To resolve correctly the resolver scans `scripts/flows/*.flow.jsonc`
/// exactly once (lazily, on first use), parses each flow's effective
/// name, and builds a `name → path` index. `refs` then keys on that
/// index. Each referenced flow is parsed at most once; its `Subflow`
/// references are cached so a diamond reference graph stays cheap.
const ProjectResolver = struct {
    arena: std.mem.Allocator,
    /// Absolute path of the project's `scripts/flows/` directory.
    flows_dir: []const u8,
    /// Effective registry name of the open flow being analyzed. The
    /// directory scan checks every on-disk flow's effective name against
    /// this: a collision is the same `DuplicateFlowName` fault as two
    /// on-disk files clashing, and must be surfaced even though the open
    /// tab may be unsaved (so it has no entry in the on-disk index).
    entry_name: []const u8 = "",
    /// flow name → the cached `RefResult` for it (resolved refs,
    /// missing, or present-but-broken).
    cache: std.StringHashMapUnmanaged(RefResult) = .empty,
    /// First duplicate effective registry name found during the
    /// directory scan, if any. `ensureIndex` sets this when two
    /// `.flow.jsonc` files (or one file and the open tab) resolve to the
    /// same effective name. `analyze` reports it ahead of any cycle
    /// result — a duplicate name makes the registry itself invalid, and
    /// the silent first-file-wins index can hide a cycle in the
    /// shadowed file. All three strings are arena-owned.
    duplicate: ?DuplicateName = null,
    /// effective registry name → absolute file path. Built once by
    /// `ensureIndex`. `null` until the first `refs` call scans the dir.
    index: ?std.StringHashMapUnmanaged([]const u8) = null,
    /// filename basename (without `.flow.jsonc`) → absolute path, for
    /// every flow file that *failed to parse* during the directory
    /// scan. A flow whose file is broken can't contribute a registry
    /// `name`, so a reference to it only resolves when the `flow_ref`
    /// equals the broken file's basename — the same fallback rule
    /// `displayNameFromPath` applies to a nameless flow. Built by
    /// `ensureIndex` alongside `index`.
    broken: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Every `.flow.jsonc` file seen during the directory scan, with
    /// the `mtime`/`size` observed then. Surfaced on the `Report` so a
    /// later check can tell whether any referenced file changed.
    seen_files: std.ArrayListUnmanaged(FileStamp) = .empty,
    /// Every reference target that did *not* resolve to a readable flow
    /// — keyed by the `.flow.jsonc` path the resolver expected — with a
    /// `MissingStamp` recording whether a (broken) file exists there.
    /// Keyed by path (not by `flow_ref`) so a diamond of references that
    /// all miss the same file records the target once. Surfaced on the
    /// `Report` so a later check can notice the target appearing.
    missing_targets: std.StringHashMapUnmanaged(MissingStamp) = .empty,

    fn refs(ctx: *anyopaque, name: []const u8) anyerror!RefResult {
        const self: *ProjectResolver = @ptrCast(@alignCast(ctx));
        if (self.cache.get(name)) |cached| return cached;

        // A filesystem error while resolving is treated as `missing` —
        // the editor can't prove the flow is fine, so it flags it.
        const result = self.loadRefs(name) catch RefResult.missing;
        try self.cache.put(self.arena, try self.arena.dupe(u8, name), result);
        return result;
    }

    /// Record the `.flow.jsonc` path a non-resolving reference expected,
    /// so a later check can notice that target appearing (or, for a
    /// broken file, changing) on disk. `expected` for a `.missing`
    /// target is the filename-basename fallback path
    /// `<flows_dir>/<name>.flow.jsonc`; for a `.parse_failed` one it is
    /// the broken file's own path. Stamps the path so a parse-failed
    /// file's later content edit is also caught.
    fn recordMissing(
        self: *ProjectResolver,
        expected: []const u8,
        parse_failed: bool,
    ) !void {
        if (self.missing_targets.contains(expected)) return;
        const io = io_global.io();
        var stamp: MissingStamp = .{ .path = expected, .parse_failed = parse_failed };
        if (std.Io.Dir.cwd().statFile(io, expected, .{})) |st| {
            stamp.mtime_ns = st.mtime.nanoseconds;
            stamp.size = st.size;
        } else |_| {}
        try self.missing_targets.put(self.arena, expected, stamp);
    }

    /// The `.flow.jsonc` path the filename-basename fallback (RFC §5)
    /// would place a flow named `name` at — `<flows_dir>/<name>.flow.jsonc`.
    /// This is the path a *missing* reference expected, so a check can
    /// stat it later to notice the target appearing.
    fn expectedPath(self: *ProjectResolver, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(
            self.arena,
            "{s}{c}{s}{s}",
            .{ self.flows_dir, std.fs.path.sep, name, flow_io.extension },
        );
    }

    /// Scan `flows_dir` once and index every flow file by its effective
    /// registry name. A directory that can't be opened yields an empty
    /// index (every reference then resolves to `unresolved`). Files that
    /// fail to parse are recorded in `broken` (keyed by basename) rather
    /// than dropped, so a reference to a broken file is reported as
    /// `parse_failed`, not `missing`.
    fn ensureIndex(self: *ProjectResolver) !*std.StringHashMapUnmanaged([]const u8) {
        if (self.index) |*idx| return idx;
        self.index = .empty;
        const idx = &self.index.?;

        const io = io_global.io();
        var dir = std.Io.Dir.cwd().openDir(
            io,
            self.flows_dir,
            .{ .iterate = true },
        ) catch return idx;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, flow_io.extension)) continue;

            const full = try std.fs.path.join(
                self.arena,
                &.{ self.flows_dir, entry.name },
            );
            // Record the file's stamp before parsing — a referenced
            // file changing on disk (even one that now parses cleanly)
            // must invalidate a cached check.
            try self.recordStamp(full);

            const base = flow_io.displayNameFromPath(entry.name);
            // Effective name = top-level `name`, else filename basename.
            var doc = flow_io.loadFromFile(self.arena, full) catch {
                // The file exists but is broken. Index it by basename in
                // `broken` so a `flow_ref` matching that basename
                // resolves to `parse_failed` rather than `missing`.
                if (!self.broken.contains(base)) {
                    try self.broken.put(
                        self.arena,
                        try self.arena.dupe(u8, base),
                        full,
                    );
                }
                continue;
            };
            const eff = if (doc.name) |n|
                try self.arena.dupe(u8, n)
            else
                try self.arena.dupe(u8, base);
            doc.deinit();

            // Two `.flow.jsonc` files claiming the same effective
            // registry name is `DuplicateFlowName` — flow-codegen
            // rejects the project. Silently keeping the first file would
            // let a cycle hide in the shadowed one (its `Subflow` refs
            // are never resolved), so record the clash; `analyze` reports
            // it ahead of any cycle result. Keep the first one found.
            if (idx.get(eff)) |first_path| {
                if (self.duplicate == null) {
                    self.duplicate = .{
                        .name = eff,
                        .path_a = first_path,
                        .path_b = full,
                    };
                }
                continue;
            }
            // The open tab's effective name colliding with an on-disk
            // file is the same fault — and the open tab may be unsaved,
            // so it never appears in `idx`. Flag it before indexing the
            // file so the entry's `<open flow>` marker is `path_a`.
            if (self.entry_name.len > 0 and
                std.mem.eql(u8, eff, self.entry_name) and
                self.duplicate == null)
            {
                self.duplicate = .{
                    .name = eff,
                    .path_a = try self.arena.dupe(u8, open_flow_marker),
                    .path_b = full,
                };
            }
            try idx.put(self.arena, eff, full);
        }
        return idx;
    }

    /// `stat` `full` and append a `FileStamp` for it to `seen_files`. A
    /// stat failure still records the path (with null mtime/size) so the
    /// file is part of the "changed?" comparison set.
    fn recordStamp(self: *ProjectResolver, full: []const u8) !void {
        const io = io_global.io();
        const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch {
            try self.seen_files.append(self.arena, .{
                .path = full,
                .mtime_ns = null,
                .size = null,
            });
            return;
        };
        try self.seen_files.append(self.arena, .{
            .path = full,
            .mtime_ns = st.mtime.nanoseconds,
            .size = st.size,
        });
    }

    /// Resolve `name` to its flow file via the registry-name index,
    /// parse it, and return the distinct non-empty `Subflow` `flow_ref`
    /// values it contains. Returns `.missing` when no flow has that
    /// effective name and no broken file's basename matches, and
    /// `.parse_failed` when a file exists for it but failed to parse.
    fn loadRefs(self: *ProjectResolver, name: []const u8) !RefResult {
        const idx = try self.ensureIndex();
        const full = idx.get(name) orelse {
            // Not a resolvable registry name. If a *broken* file's
            // basename matches, the reference points at a present but
            // unparseable flow — surface that distinctly.
            if (self.broken.get(name)) |broken_path| {
                try self.recordMissing(broken_path, true);
                return .parse_failed;
            }
            // No file resolves this name. Record the path the
            // basename-fallback rule would expect, so a later check
            // notices the target appearing on disk.
            try self.recordMissing(try self.expectedPath(name), false);
            return .missing;
        };

        // The file parsed during the scan; a failure here means it
        // changed (or a transient IO error) between scan and re-read —
        // treat it as broken rather than missing.
        var doc = flow_io.loadFromFile(self.arena, full) catch {
            try self.recordMissing(full, true);
            return .parse_failed;
        };
        defer doc.deinit();

        var out: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(self.arena);
        for (doc.nodes) |node| {
            if (node.kind != .subflow) continue;
            if (node.flow_ref.len == 0) continue;
            if (seen.contains(node.flow_ref)) continue;
            const ref = try self.arena.dupe(u8, node.flow_ref);
            try seen.put(self.arena, ref, {});
            try out.append(self.arena, ref);
        }
        return .{ .ok = try out.toOwnedSlice(self.arena) };
    }
};

/// Analyze a single open flow document against the other flows in the
/// project. `entry_refs` is the *live* set of `Subflow` references on
/// the document being edited (read straight from `FlowDoc`, so an
/// in-editor edit is reflected without saving first). `flows_dir` is
/// the project's `scripts/flows/` directory; the referenced flows are
/// read from there.
///
/// The entry flow's references come from `entry_refs`; every
/// transitively-referenced flow is read from disk. This means an
/// unsaved edit to the open document is checked immediately, while
/// referenced flows reflect their on-disk state.
pub fn analyze(
    child_allocator: std.mem.Allocator,
    entry_name: []const u8,
    entry_refs: []const []const u8,
    flows_dir: []const u8,
) !Report {
    const arena = try child_allocator.create(std.heap.ArenaAllocator);
    errdefer child_allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(child_allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var resolver_ctx = try a.create(ProjectResolver);
    resolver_ctx.* = .{
        .arena = a,
        .flows_dir = try a.dupe(u8, flows_dir),
        // The scan checks every on-disk flow's effective name against
        // the open tab's name — a collision there is `DuplicateFlowName`
        // too, and the unsaved open tab is otherwise invisible to it.
        .entry_name = try a.dupe(u8, entry_name),
    };

    // Pre-seed the cache with the live (possibly unsaved) entry flow so
    // its references aren't re-read from a stale on-disk copy.
    {
        var refs_copy: std.ArrayList([]const u8) = .empty;
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(a);
        for (entry_refs) |r| {
            if (r.len == 0) continue;
            if (seen.contains(r)) continue;
            const dup = try a.dupe(u8, r);
            try seen.put(a, dup, {});
            try refs_copy.append(a, dup);
        }
        try resolver_ctx.cache.put(
            a,
            try a.dupe(u8, entry_name),
            .{ .ok = try refs_copy.toOwnedSlice(a) },
        );
    }

    const resolver: Resolver = .{
        .ctx = resolver_ctx,
        .refsFn = ProjectResolver.refs,
    };

    const walk_status = try detectCycle(a, entry_name, resolver);

    // The cycle walk only scans the flows directory when it actually
    // resolves a referenced flow — an entry with no `Subflow` refs never
    // triggers `ensureIndex`. Force the scan so a duplicate registry
    // name (or an entry-name collision) is detected regardless.
    _ = try resolver_ctx.ensureIndex();

    // A duplicate effective registry name makes the whole flow registry
    // invalid (flow-codegen rejects it) and the silent first-file-wins
    // index can hide a cycle in the shadowed file — report it ahead of
    // any cycle/unresolved/parse-failed result the walk produced.
    const status: Status = if (resolver_ctx.duplicate) |dup|
        .{ .duplicate_name = dup }
    else
        walk_status;

    // Render the offending chain once, here, while the report is
    // generated — the chain only changes when the analysis re-runs, so
    // the UI never needs to rebuild it per frame.
    var chain_text: []const u8 = "";
    const chain: ?Chain = switch (status) {
        .clean => null,
        .cycle => |c| c,
        .unresolved => |c| c,
        .parse_failed => |c| c,
        .duplicate_name => null,
    };
    if (chain) |c| {
        var out: std.ArrayList(u8) = .empty;
        try c.format(&out, a);
        chain_text = try out.toOwnedSlice(a);
    }

    // Hand the caller the set of files the resolver stat'd — the
    // resolver allocated the `FileStamp`s and their paths on the report
    // arena, so they outlive this call and `deinit` reclaims them.
    const read_files = try resolver_ctx.seen_files.toOwnedSlice(a);

    // Also hand over the targets that did *not* resolve, each with the
    // `.flow.jsonc` path the resolver expected. A later check stats
    // these so a previously-missing target appearing on disk re-triggers
    // the analysis (`read_files` can never cover them — they were never
    // read). All paths/stamps live on the report arena.
    var missing_targets: std.ArrayList(MissingStamp) = .empty;
    {
        var it = resolver_ctx.missing_targets.valueIterator();
        while (it.next()) |stamp| try missing_targets.append(a, stamp.*);
    }

    return .{
        .arena = arena,
        .status = status,
        .chain_text = chain_text,
        .read_files = read_files,
        .unresolved_targets = try missing_targets.toOwnedSlice(a),
    };
}

// ─── Tests ──────────────────────────────────────────────────────────────

/// In-memory resolver for tests — a flow name → refs map. A name absent
/// from the map resolves to `.missing`; a name present in `broken`
/// resolves to `.parse_failed`.
const MapResolver = struct {
    map: std.StringHashMapUnmanaged([]const []const u8),
    broken: std.StringHashMapUnmanaged(void) = .empty,

    fn refs(ctx: *anyopaque, name: []const u8) anyerror!RefResult {
        const self: *MapResolver = @ptrCast(@alignCast(ctx));
        if (self.map.get(name)) |r| return .{ .ok = r };
        if (self.broken.contains(name)) return .parse_failed;
        return .missing;
    }

    fn resolver(self: *MapResolver) Resolver {
        return .{ .ctx = self, .refsFn = MapResolver.refs };
    }
};

test "detectCycle: clean linear chain" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{"b"});
    try m.map.put(a, "b", &.{"c"});
    try m.map.put(a, "c", &.{});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .clean);
}

test "detectCycle: direct self-reference is a cycle" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{"a"});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .cycle);
    try std.testing.expectEqual(@as(usize, 2), status.cycle.names.len);
    try std.testing.expectEqualStrings("a", status.cycle.names[0]);
    try std.testing.expectEqualStrings("a", status.cycle.names[1]);
}

test "detectCycle: indirect cycle reports the offending chain" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{"b"});
    try m.map.put(a, "b", &.{"c"});
    try m.map.put(a, "c", &.{"a"});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .cycle);
    // Chain is a → b → c → a.
    try std.testing.expectEqual(@as(usize, 4), status.cycle.names.len);
    try std.testing.expectEqualStrings("a", status.cycle.names[0]);
    try std.testing.expectEqualStrings("b", status.cycle.names[1]);
    try std.testing.expectEqualStrings("c", status.cycle.names[2]);
    try std.testing.expectEqualStrings("a", status.cycle.names[3]);
}

test "detectCycle: cycle not involving the entry flow is still found" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    // entry → b → c → b  (the cycle is b↔c, entry is clean itself)
    try m.map.put(a, "entry", &.{"b"});
    try m.map.put(a, "b", &.{"c"});
    try m.map.put(a, "c", &.{"b"});

    const status = try detectCycle(a, "entry", m.resolver());
    try std.testing.expect(status == .cycle);
    try std.testing.expectEqualStrings("b", status.cycle.names[0]);
    try std.testing.expectEqualStrings("b", status.cycle.names[status.cycle.names.len - 1]);
}

test "detectCycle: unresolved reference is reported" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{"b"});
    try m.map.put(a, "b", &.{"missing"});
    // "missing" deliberately absent from the map.

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .unresolved);
    try std.testing.expectEqual(@as(usize, 3), status.unresolved.names.len);
    try std.testing.expectEqualStrings("missing", status.unresolved.names[2]);
}

test "detectCycle: a broken referenced flow reports parse_failed" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{"b"});
    try m.map.put(a, "b", &.{"broken"});
    // "broken" exists but won't parse — distinct from a missing file.
    try m.broken.put(a, "broken", {});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .parse_failed);
    try std.testing.expectEqual(@as(usize, 3), status.parse_failed.names.len);
    try std.testing.expectEqualStrings("broken", status.parse_failed.names[2]);
}

test "detectCycle: diamond reference graph is clean and walked once" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    // a → b → d, a → c → d. `d` is reachable two ways but no cycle.
    try m.map.put(a, "a", &.{ "b", "c" });
    try m.map.put(a, "b", &.{"d"});
    try m.map.put(a, "c", &.{"d"});
    try m.map.put(a, "d", &.{});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .clean);
}

test "detectCycle: cycle reachable only through a node first seen on a clean branch" {
    // Regression for the classic DFS three-state mistake: the `visited`
    // (done) set must mean "fully explored AND acyclic", never "seen".
    //
    //   entry → x → c        (c first encountered down a clean-looking
    //   entry → b → c → b     branch via x; the cycle is b → c → b)
    //
    // `x` is walked before `b`. While walking `x → c`, `c → b` is
    // explored — `b` is not yet on the path, so the walk descends into
    // `b → c`, finds `c` *is* on the path, and reports the cycle. `c`
    // must therefore never enter the `done` set, and the later
    // `entry → b` branch must still see the cycle. A walk that marked
    // `c` "done" on first sight would wrongly return `.clean`.
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "entry", &.{ "x", "b" });
    try m.map.put(a, "x", &.{"c"});
    try m.map.put(a, "b", &.{"c"});
    try m.map.put(a, "c", &.{"b"});

    const status = try detectCycle(a, "entry", m.resolver());
    try std.testing.expect(status == .cycle);
    // The offending chain is the b ↔ c loop. The walk descends
    // entry → x → c → b → c, so the back edge closes at `c`: the chain
    // is c → b → c, opening and closing on the same name.
    try std.testing.expectEqual(@as(usize, 3), status.cycle.names.len);
    try std.testing.expectEqualStrings("c", status.cycle.names[0]);
    try std.testing.expectEqualStrings("b", status.cycle.names[1]);
    try std.testing.expectEqualStrings(
        status.cycle.names[0],
        status.cycle.names[status.cycle.names.len - 1],
    );
}

test "detectCycle: cycle behind a node reached via two clean-prefix paths" {
    // A node (`c`) reachable via two paths, one of which closes a cycle.
    //
    //   entry → d           d's children are walked in order:
    //   d → c               (1) c → leaf, a genuinely clean subtree
    //   c → leaf            (2) e → d  closes the cycle d → e → d
    //   d → e
    //   e → d
    //
    // Child (1) leaves `c` (and `leaf`) in the `done` set. Child (2)
    // then finds the back edge to `d`. The earlier `done` marking of the
    // sibling subtree must not suppress the cycle on the later branch.
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "entry", &.{"d"});
    try m.map.put(a, "d", &.{ "c", "e" });
    try m.map.put(a, "c", &.{"leaf"});
    try m.map.put(a, "leaf", &.{});
    try m.map.put(a, "e", &.{"d"});

    const status = try detectCycle(a, "entry", m.resolver());
    try std.testing.expect(status == .cycle);
    try std.testing.expectEqualStrings("d", status.cycle.names[0]);
    try std.testing.expectEqualStrings(
        "d",
        status.cycle.names[status.cycle.names.len - 1],
    );
}

test "detectCycle: a node reached via two clean paths is not a false cycle" {
    // Counterpart to the regression above: a node (`c`) reached twice,
    // both paths genuinely acyclic, must stay `.clean`. The `done` set
    // is what makes the second visit a cheap skip — and that skip must
    // not be mistaken for, nor mistakenly upgraded to, a cycle.
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "a", &.{ "x", "y" });
    try m.map.put(a, "x", &.{"c"});
    try m.map.put(a, "y", &.{"c"});
    try m.map.put(a, "c", &.{"leaf"});
    try m.map.put(a, "leaf", &.{});

    const status = try detectCycle(a, "a", m.resolver());
    try std.testing.expect(status == .clean);
}

test "detectCycle: empty entry with no refs is clean" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    var m: MapResolver = .{ .map = .empty };
    try m.map.put(a, "solo", &.{});

    const status = try detectCycle(a, "solo", m.resolver());
    try std.testing.expect(status == .clean);
}

test "Chain.format renders names joined by an arrow" {
    var a_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer a_state.deinit();
    const a = a_state.allocator();

    const chain: Chain = .{ .names = @constCast(&[_][]const u8{ "a", "b", "a" }) };
    var out: std.ArrayList(u8) = .empty;
    try chain.format(&out, a);
    try std.testing.expectEqualStrings("a \u{2192} b \u{2192} a", out.items);
}
