//! Public types for the Flows visualization layer (issues #48 + #49).
//!
//! The projector (`projector.zig`) walks a parsed `std.zig.Ast`, hands
//! each AST node it visits to a renderer (`renderers.zig`), and the
//! renderer emits one or more `GraphNodeSpec`s + `EdgeSpec`s into a
//! `Graph`. The Flow tab (`modules/flow.zig`) consumes the resulting
//! graph and lays it out in the imgui-node-editor canvas.
//!
//! Phase 1 — read-only viewer. No pin-value flow, no live overlay,
//! no authoring. The Zig source is the source of truth; the graph is
//! derived.

const std = @import("std");

/// One renderable node in the projected graph. Maps 1-to-1 to a
/// specific AST construct in the source. `id` is unique within a
/// single `Graph` and stable across re-derivations of the same source
/// (we allocate IDs in pre-order traversal so identical structures
/// get identical IDs).
pub const GraphNodeSpec = struct {
    id: u32,
    /// Human-readable label drawn on the node header. Arena-allocated
    /// off the projector's arena — owned by the `Graph`.
    label: []const u8,
    /// 1-based source line for the AST construct. Used by the sidebar
    /// (`click to jump`) and the inspector's source snippet.
    source_line: u32,
    /// Coarse classification — drives node colour and inspector
    /// labelling. The renderer set picks the category; the tab body
    /// reads it.
    category: Category,
    input_pins: []const PinSpec,
    output_pins: []const PinSpec,

    pub const Category = enum {
        entry_point,
        call,
        binop,
        unop,
        branch,
        loop,
        var_decl,
        identifier,
        field_access,
        struct_init,
        terminator,
        generic,
    };
};

pub const PinSpec = struct {
    /// Unique within the owning `Graph` (not just within the node).
    /// The node-editor binding wants unique pin ids globally.
    id: u32,
    /// Pin label, arena-allocated off the projector's arena.
    name: []const u8,
    /// Best-effort Zig type. `"?unknown"` when the projector can't
    /// infer it from the AST alone (most cases — full type inference
    /// is sema's job, not the gui's).
    type_name: []const u8,
};

pub const EdgeSpec = struct {
    from_node: u32,
    from_pin: u32,
    to_node: u32,
    to_pin: u32,
    kind: Kind,

    pub const Kind = enum {
        /// Value flows along this edge — `var x = y` makes a data edge
        /// from `y`'s output to `x`'s init input.
        data,
        /// Control flows along this edge — `if (cond) body` makes an
        /// execution edge from the branch's `then` output to `body`'s
        /// entry input.
        execution,
    };
};

/// The complete projected graph for a single `.zig` source file.
/// Owns its `nodes` and `edges` slices plus the labels they point at;
/// everything is allocated off the arena built in `projector.project`.
pub const Graph = struct {
    arena: std.heap.ArenaAllocator,
    nodes: []GraphNodeSpec,
    edges: []EdgeSpec,
    /// Node IDs of every node whose `category == .entry_point`. The
    /// sidebar uses this for the "scroll to root" list. Stored
    /// separately so the sidebar doesn't re-scan every frame.
    entry_points: []u32,

    pub fn deinit(self: *Graph) void {
        // arena.deinit() reclaims everything in one shot — `nodes`,
        // `edges`, `entry_points`, labels, pin slices.
        self.arena.deinit();
        self.* = undefined;
    }
};
