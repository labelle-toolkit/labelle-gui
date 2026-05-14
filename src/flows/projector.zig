//! AST → graph projector for the Flows visualization layer (issue #48 + #49).
//!
//! `project(allocator, source)` parses a `.zig` source file via
//! `std.zig.Ast`, walks every top-level function declaration that
//! matches an entry-point name (`update`, `tick`, `init`, `deinit`,
//! or any function whose first param is `*Game`), recursively walks
//! the body, and emits a `Graph` of `GraphNodeSpec` + `EdgeSpec`.
//!
//! The renderer set (`renderers.zig`) does the per-AST-tag emission;
//! this file is the orchestration — node-id allocation, the visit
//! recursion, identifier-to-var_decl binding, and entry-point
//! detection.

const std = @import("std");
const Ast = std.zig.Ast;

const types = @import("types.zig");
const renderers = @import("renderers.zig");

pub const Graph = types.Graph;
pub const GraphNodeSpec = types.GraphNodeSpec;
pub const EdgeSpec = types.EdgeSpec;
pub const PinSpec = types.PinSpec;

/// State threaded through every renderer call. The renderer set
/// appends nodes + edges through this, allocates labels off the
/// arena, and consults `var_outputs` to bind identifiers back to
/// the declaration that produced them.
pub const Projector = struct {
    /// Arena owned by the eventual `Graph`. All node labels, pin
    /// names, slices and the final `nodes`/`edges` arrays are
    /// allocated here.
    arena: std.mem.Allocator,
    ast: *const Ast,

    nodes: std.ArrayList(GraphNodeSpec) = .empty,
    edges: std.ArrayList(EdgeSpec) = .empty,
    entry_points: std.ArrayList(u32) = .empty,

    /// Maps a variable name (the identifier token slice of a
    /// `var_decl`) to `(node_id, output_pin_id)`. The
    /// `identifier`-renderer uses this to wire references back to
    /// their declaration. Lexical scoping is approximated as a flat
    /// map — the projector handles nested blocks by passing distinct
    /// scopes via `pushScope` / `popScope`.
    scopes: std.ArrayList(Scope) = .empty,

    next_node_id: u32 = 1,
    next_pin_id: u32 = 1,

    pub const VarBinding = struct { node: u32, pin: u32 };

    /// One lexical scope frame. Identifiers resolve against the
    /// topmost scope first, falling back to enclosing scopes. We
    /// don't currently model shadowing across `if`/`while` blocks
    /// because the graph treats each branch as a single visited
    /// subtree — adequate for v1.
    pub const Scope = struct {
        bindings: std.StringHashMapUnmanaged(VarBinding) = .empty,
    };

    pub fn init(arena: std.mem.Allocator, ast: *const Ast) Projector {
        return .{ .arena = arena, .ast = ast };
    }

    /// Allocate a fresh `GraphNodeSpec.id`. Sequential allocation
    /// gives identical-source graphs identical id sequences, which
    /// keeps the node-editor's saved layout stable across reparses.
    pub fn newNodeId(self: *Projector) u32 {
        const id = self.next_node_id;
        self.next_node_id += 1;
        return id;
    }

    pub fn newPinId(self: *Projector) u32 {
        const id = self.next_pin_id;
        self.next_pin_id += 1;
        return id;
    }

    /// Append a node spec to the accumulator. The renderer set
    /// constructs it (`renderers.zig`); this just owns the storage.
    pub fn emitNode(self: *Projector, node: GraphNodeSpec) !void {
        try self.nodes.append(self.arena, node);
        if (node.category == .entry_point) {
            try self.entry_points.append(self.arena, node.id);
        }
    }

    pub fn emitEdge(self: *Projector, edge: EdgeSpec) !void {
        try self.edges.append(self.arena, edge);
    }

    pub fn pushScope(self: *Projector) !void {
        try self.scopes.append(self.arena, .{});
    }

    pub fn popScope(self: *Projector) void {
        if (self.scopes.items.len == 0) return;
        // The map sits inside an arena — no need to deinit individual
        // entries, dropping the frame is enough.
        _ = self.scopes.pop();
    }

    pub fn bindVar(self: *Projector, name: []const u8, binding: VarBinding) !void {
        if (self.scopes.items.len == 0) try self.pushScope();
        const top = &self.scopes.items[self.scopes.items.len - 1];
        try top.bindings.put(self.arena, name, binding);
    }

    /// Look up `name` in the scope stack, top to bottom. Returns null
    /// when the identifier was never declared in the current
    /// function — usually means a parameter, a module-level decl, or
    /// an imported symbol.
    pub fn lookupVar(self: *const Projector, name: []const u8) ?VarBinding {
        var i: usize = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].bindings.get(name)) |b| return b;
        }
        return null;
    }

    /// 1-based source line for `node`. The node-editor sidebar shows
    /// this; the inspector uses it to render the surrounding snippet.
    pub fn sourceLineOf(self: *const Projector, node: Ast.Node.Index) u32 {
        const main_token = self.ast.nodeMainToken(node);
        const loc = self.ast.tokenLocation(0, main_token);
        // tokenLocation returns 0-based line; bump to 1-based for
        // user-facing display.
        return @intCast(loc.line + 1);
    }
};

/// Names that mark a function as a graph entry point even when its
/// signature doesn't follow the `*Game` convention. Mirrors the
/// engine's hook list (see `labelle-engine`'s `MergeEngineHooks`).
const entry_point_names = [_][]const u8{
    "update",
    "tick",
    "init",
    "deinit",
    "render",
    "onUpdate",
    "onCreate",
    "onDestroy",
};

/// Public entry point. Parses `source` and returns a `Graph` keyed
/// off `source`'s lexical structure. Caller owns the returned graph
/// (`graph.deinit()` to free).
///
/// `source` must be 0-terminated — `std.zig.Ast.parse` requires it.
/// Callers reading files should append a 0 byte before calling.
pub fn project(allocator: std.mem.Allocator, source: [:0]const u8) !Graph {
    // The Ast lives in `allocator` (the parent), not the arena, so it
    // can be freed independently. Everything the graph references
    // (labels, pin slices, the final node/edge arrays) goes on the
    // arena.
    var arena_obj = std.heap.ArenaAllocator.init(allocator);
    errdefer arena_obj.deinit();
    const arena = arena_obj.allocator();

    var ast = try Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);

    var p = Projector.init(arena, &ast);

    // Walk top-level decls, project each entry-point function. We
    // copy the label and slice ownership into the arena before
    // returning so the caller can drop the Ast.
    for (ast.rootDecls()) |decl| {
        if (ast.nodeTag(decl) != .fn_decl) continue;
        if (!isEntryPointFn(&ast, decl)) continue;

        try p.pushScope();
        defer p.popScope();

        // Emit the entry-point node first so its id sits at the start
        // of the function's subgraph. The body is walked under it.
        const entry_node_id = try renderers.renderFunctionEntry(&p, decl);
        try walkFnBody(&p, decl, entry_node_id);
    }

    const nodes_slice = try p.nodes.toOwnedSlice(arena);
    const edges_slice = try p.edges.toOwnedSlice(arena);
    const entries_slice = try p.entry_points.toOwnedSlice(arena);

    return .{
        .arena = arena_obj,
        .nodes = nodes_slice,
        .edges = edges_slice,
        .entry_points = entries_slice,
    };
}

/// True when `decl` (a `.fn_decl`) is one the projector should
/// promote into a graph root. Either the name appears in
/// `entry_point_names`, or the first param's type is `*Game` (the
/// engine's convention for scripts that receive the game handle).
fn isEntryPointFn(ast: *const Ast, decl: Ast.Node.Index) bool {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = ast.fullFnProto(&buf, decl) orelse return false;
    const name_tok = proto.name_token orelse return false;
    const name = ast.tokenSlice(name_tok);

    for (entry_point_names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }

    // First-param-is-Game heuristic — scripts like
    // `pub fn tick(game: anytype, dt: f32) void` slip past the name
    // check (`tick` is in the list), but bespoke handler names like
    // `kitchenGate(game: anytype, ...)` are picked up here.
    //
    // We tokenize the type-expr source on whitespace + the pointer /
    // const decorators so we match `Game` as a whole word — naive
    // substring matched `NotAGame` / `MyGameController` (gemini #63
    // medium).
    var it = proto.iterate(ast);
    if (it.next()) |first_param| {
        if (first_param.type_expr) |type_node| {
            const text = ast.getNodeSource(type_node);
            var tok = std.mem.tokenizeAny(u8, text, " \t\r\n*?!&[](),.");
            while (tok.next()) |word| {
                if (std.mem.eql(u8, word, "const")) continue;
                if (std.mem.eql(u8, word, "Game")) return true;
            }
            // `anytype` params are encoded as `anytype_ellipsis3`, no
            // type_expr. We treat them as entry-point candidates
            // because in practice that's what scripts use.
        } else if (first_param.anytype_ellipsis3 != null) {
            return true;
        }
    }
    return false;
}

/// Walk a `.fn_decl`'s body block, dispatching every statement to
/// the renderer set. `entry_id` is the function's entry node — body
/// statements are recorded as children of it for layout purposes
/// (the renderer can choose how to thread them).
fn walkFnBody(p: *Projector, decl: Ast.Node.Index, entry_id: u32) !void {
    const ast = p.ast;
    // `fn_decl` data is `node_and_node = (fn_proto, block)`. The
    // block can be one of several block tags.
    const data = ast.nodeData(decl);
    const fn_data = data.node_and_node;
    const body_node = fn_data[1];

    try walkStatement(p, body_node, entry_id);
}

/// Visit `node` and decide whether to recurse into its children.
/// Blocks fan out their statements; expressions delegate to the
/// renderer dispatch table.
pub fn walkStatement(p: *Projector, node: Ast.Node.Index, parent_id: u32) anyerror!void {
    const ast = p.ast;
    const tag = ast.nodeTag(node);

    switch (tag) {
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => try walkBlock(p, node, parent_id),

        else => {
            _ = try renderers.dispatch(p, node, parent_id);
        },
    }
}

/// True when `tag` is one of the block flavours we fan out per-stmt.
/// Renderers consult this when wiring exec edges into a body that
/// might be a `{...}` block rather than a single expression.
pub fn isBlockTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
        .block, .block_semicolon, .block_two, .block_two_semicolon => true,
        else => false,
    };
}

pub fn walkBlock(p: *Projector, block: Ast.Node.Index, parent_id: u32) anyerror!void {
    const ast = p.ast;
    const tag = ast.nodeTag(block);

    switch (tag) {
        .block, .block_semicolon => {
            const range = ast.nodeData(block).extra_range;
            const stmts = ast.extraDataSlice(range, Ast.Node.Index);
            for (stmts) |stmt| try walkStatement(p, stmt, parent_id);
        },
        .block_two, .block_two_semicolon => {
            const pair = ast.nodeData(block).opt_node_and_opt_node;
            if (pair[0].unwrap()) |s1| try walkStatement(p, s1, parent_id);
            if (pair[1].unwrap()) |s2| try walkStatement(p, s2, parent_id);
        },
        else => {},
    }
}
