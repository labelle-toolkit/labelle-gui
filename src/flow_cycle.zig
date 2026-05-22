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
//!     `scripts/flows/<name>.flow.jsonc` file doesn't exist or won't
//!     parse. flow-codegen raises `UnknownFlowRef`.
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

/// Outcome of a cycle check.
pub const Status = union(enum) {
    /// No cycle, every transitively-referenced flow resolved.
    clean,
    /// A reference cycle was found. `chain` is the offending path of
    /// flow names, starting and ending with the same name
    /// (e.g. `a → b → a`).
    cycle: Chain,
    /// A `Subflow` referenced a flow that couldn't be resolved.
    /// `chain` is the path of flow names from the entry flow down to
    /// (and including) the unresolved name.
    unresolved: Chain,
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

    pub fn deinit(self: *Report) void {
        const child = self.arena.child_allocator;
        self.arena.deinit();
        child.destroy(self.arena);
    }

    pub fn allocator(self: *Report) std.mem.Allocator {
        return self.arena.allocator();
    }
};

/// Abstract source of a flow's outgoing `Subflow` references. The pure
/// `detectCycle` walk only needs this — it never touches the
/// filesystem. `refs` returns:
///   - the (possibly empty) list of flow names this flow references,
///   - or `null` when the named flow cannot be resolved at all.
/// The returned slice and its strings must outlive the `detectCycle`
/// call (the project resolver allocates them on the report arena).
pub const Resolver = struct {
    ctx: *anyopaque,
    refsFn: *const fn (ctx: *anyopaque, name: []const u8) anyerror!?[]const []const u8,

    fn refs(self: Resolver, name: []const u8) anyerror!?[]const []const u8 {
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

    const child_refs = (try resolver.refs(name)) orelse {
        // `name` itself couldn't be resolved. Report the path that led
        // here, including `name`.
        var chain: std.ArrayList([]const u8) = .empty;
        for (path.items) |n| {
            try chain.append(arena, try arena.dupe(u8, n));
        }
        try chain.append(arena, try arena.dupe(u8, name));
        return .{ .unresolved = .{ .names = try chain.toOwnedSlice(arena) } };
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

// ─── Project-backed resolver ────────────────────────────────────────────

/// Resolver context that reads `<flows_dir>/<name>.flow.jsonc` from
/// disk. Parses each file once and caches its `Subflow` references on
/// the report arena, so a diamond reference graph reads each file at
/// most once.
const ProjectResolver = struct {
    arena: std.mem.Allocator,
    /// Absolute path of the project's `scripts/flows/` directory.
    flows_dir: []const u8,
    /// flow name → its outgoing Subflow refs (`null` cached for a name
    /// whose file is missing or unparseable).
    cache: std.StringHashMapUnmanaged(?[]const []const u8) = .empty,

    fn refs(ctx: *anyopaque, name: []const u8) anyerror!?[]const []const u8 {
        const self: *ProjectResolver = @ptrCast(@alignCast(ctx));
        if (self.cache.get(name)) |cached| return cached;

        const result = self.loadRefs(name) catch null;
        try self.cache.put(self.arena, try self.arena.dupe(u8, name), result);
        return result;
    }

    /// Read and parse `<flows_dir>/<name>.flow.jsonc`, returning the
    /// distinct non-empty `Subflow` `flow_ref` values it contains.
    fn loadRefs(self: *ProjectResolver, name: []const u8) !?[]const []const u8 {
        const path = try std.fs.path.join(
            self.arena,
            &.{ self.flows_dir, name },
        );
        // `name` is a bare flow name; the on-disk file adds the
        // extension. Build `<flows_dir>/<name>.flow.jsonc`.
        const full = try std.fmt.allocPrint(
            self.arena,
            "{s}{s}",
            .{ path, flow_io.extension },
        );

        var doc = flow_io.loadFromFile(self.arena, full) catch return null;
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
        return try out.toOwnedSlice(self.arena);
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
            try refs_copy.toOwnedSlice(a),
        );
    }

    const resolver: Resolver = .{
        .ctx = resolver_ctx,
        .refsFn = ProjectResolver.refs,
    };

    const status = try detectCycle(a, entry_name, resolver);
    return .{ .arena = arena, .status = status };
}

// ─── Tests ──────────────────────────────────────────────────────────────

/// In-memory resolver for tests — a flow name → refs map. A name absent
/// from the map resolves to `null` (unresolved).
const MapResolver = struct {
    map: std.StringHashMapUnmanaged([]const []const u8),

    fn refs(ctx: *anyopaque, name: []const u8) anyerror!?[]const []const u8 {
        const self: *MapResolver = @ptrCast(@alignCast(ctx));
        return self.map.get(name);
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
