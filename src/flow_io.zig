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
    /// Fires a custom event by dotted name (RFC-PLUGIN-EVENTS §8). The
    /// node's input pins are the payload struct's fields — derived
    /// editor-side by `event_catalog` from the resolved event name. The
    /// codegen reflects the same fields from the assembler-built
    /// `PluginEvents` / `GameEvents` union at build time.
    emit,
    /// Graph-level event trigger (RFC-FLOW-VOCABULARY §3). Replaces the
    /// file-level `event:` header for new-form flows. Carries the dotted
    /// event name in `event_ref`; payload fields are surfaced as output
    /// pins reflected from the editor's event catalog (same source the
    /// `Emit` node uses for its inputs).
    event,
    /// Read a declared `Variable` (RFC-FLOW-VOCABULARY §4). Reporter
    /// node — one output pin `value` typed to the variable's declared
    /// type. The targeted variable name lives in `variable_ref`.
    get_variable,
    /// Write a declared `Variable` (RFC-FLOW-VOCABULARY §4). Command
    /// node — one input pin `value`. Targets `variable_ref`.
    set_variable,
    /// Increment/toggle a declared `Variable` (RFC-FLOW-VOCABULARY §4).
    /// Command node. The increment is the wired `by` input pin or, when
    /// no wire is attached, the inline `by_text` literal (the
    /// Scratch-style "change X by [1]" knob). Defaults to `"1"`.
    change_variable,
    /// Clear a nullable `?T` `Variable` (RFC-FLOW-VOCABULARY §4 —
    /// nullable variable operations). Command node, no extra pins.
    clear_variable,
    /// Reporter on a nullable `?T` `Variable` — `bool` output pin
    /// `value` evaluating to `<var> != null`.
    has_value_variable,
    /// Plugin- or game-script-contributed `FlowNode` (RFC-FLOW-VOCABULARY
    /// §1, §6). Names a `pub const` decl on some module's `FlowNodes`
    /// block by its dotted form (`"box2d.apply_impulse"`) — codegen
    /// resolves it through the assembler-emitted `PluginFlowNodes`
    /// registry at build time. The editor uses a static catalog
    /// (`flow_node_catalog`) to surface pin labels + command/reporter
    /// kind until the assembler-emitted sidecar lands.
    custom_node,
    /// Any other node type — kind preserved as a string in `type_name`.
    other,

    pub fn fromTypeName(name: []const u8) NodeKind {
        if (std.mem.eql(u8, name, "Subflow")) return .subflow;
        if (std.mem.eql(u8, name, "Param")) return .param;
        if (std.mem.eql(u8, name, "Output")) return .output;
        if (std.mem.eql(u8, name, "Emit")) return .emit;
        if (std.mem.eql(u8, name, "Event")) return .event;
        if (std.mem.eql(u8, name, "GetVariable")) return .get_variable;
        if (std.mem.eql(u8, name, "SetVariable")) return .set_variable;
        if (std.mem.eql(u8, name, "ChangeVariable")) return .change_variable;
        if (std.mem.eql(u8, name, "ClearVariable")) return .clear_variable;
        if (std.mem.eql(u8, name, "HasValueVariable")) return .has_value_variable;
        if (std.mem.eql(u8, name, "CustomNode")) return .custom_node;
        return .other;
    }

    /// Canonical `type` string for a structurally-understood kind.
    /// `.other` has no canonical name — callers use `Node.type_name`.
    pub fn typeName(self: NodeKind) ?[]const u8 {
        return switch (self) {
            .subflow => "Subflow",
            .param => "Param",
            .output => "Output",
            .emit => "Emit",
            .event => "Event",
            .get_variable => "GetVariable",
            .set_variable => "SetVariable",
            .change_variable => "ChangeVariable",
            .clear_variable => "ClearVariable",
            .has_value_variable => "HasValueVariable",
            .custom_node => "CustomNode",
            .other => null,
        };
    }

    /// True when this kind is a *command* (mutation, void-return,
    /// rectangular silhouette per RFC-FLOW-VOCABULARY §6). Commands sit
    /// on the execution-flow spine and get top/bottom exec anchors;
    /// reporters (pure value, rounded silhouette) get only data pins.
    ///
    /// `.custom_node` is ambiguous from this enum alone — the catalog
    /// resolves the per-entry `kind`. Callers that need the catalog's
    /// answer should consult `flow_node_catalog.lookup(...).kind`
    /// directly; `isCommandKind` returns false for `.custom_node` so the
    /// generic classifier never accidentally awards exec anchors to a
    /// reporter-kind custom node.
    ///
    /// `.other` is also false — opaque nodes (`BinOp`, `Literal`, …)
    /// have no declared command/reporter polarity in the editor.
    pub fn isCommandKind(self: NodeKind) bool {
        return switch (self) {
            .event,
            .emit,
            .set_variable,
            .change_variable,
            .clear_variable,
            .subflow,
            .output,
            => true,
            .get_variable,
            .has_value_variable,
            .param,
            .custom_node,
            .other,
            => false,
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

    // ── Emit-specific / Event-specific ──
    /// Dotted event name (`"<plugin>.<event>"` or a bare game event name).
    /// Used by `Emit` (the event the node fires) and `Event` (the trigger
    /// the flow handles, RFC-FLOW-VOCABULARY §3). Empty for other kinds.
    event_ref: []const u8 = "",

    // ── Variable-op-specific ──
    /// The declared variable this node reads or writes (RFC-FLOW-VOCABULARY
    /// §4). Set on `GetVariable` / `SetVariable` / `ChangeVariable` /
    /// `ClearVariable` / `HasValueVariable`. Empty otherwise.
    variable_ref: []const u8 = "",
    /// Inline increment literal for `ChangeVariable`. Canonical JSON value
    /// text — defaults to `"1"` when the node is created without one,
    /// matching codegen's default. An incoming wire on the `by` pin still
    /// takes precedence at codegen time. Empty for other kinds.
    by_text: []const u8 = "",

    // ── CustomNode-specific ──
    /// Dotted plugin-FlowNode name (`"box2d.apply_impulse"`) when this is
    /// a `CustomNode`. The editor resolves it through `flow_node_catalog`
    /// to draw pin labels; codegen resolves it through the assembler's
    /// `PluginFlowNodes.resolve` at build time. Empty for other kinds.
    custom_name: []const u8 = "",

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

/// One declared flow-scope variable (RFC-FLOW-VOCABULARY §4 — top-level
/// `variables` block). Lowers in codegen to a file-scope
/// `var <name>: <type> = <default>;` in the generated `.zig` module —
/// persistent across handler invocations, invisible to other flows.
/// `GetVariable` / `SetVariable` / `ChangeVariable` / `ClearVariable` /
/// `HasValueVariable` nodes read and write it.
pub const Variable = struct {
    /// Zig identifier — the variable's symbol in the generated module.
    name: []const u8,
    /// Zig type-name text — `"i32"`, `"f32"`, `"bool"`, `"?EntityId"`, …
    /// Stored verbatim; codegen emits it unchanged. A leading `?` marks
    /// a nullable variable (the only kind `ClearVariable` /
    /// `HasValueVariable` accept).
    type_name: []const u8,
    /// Canonical JSON text of the variable's initial value (e.g. `0`,
    /// `true`, `null`, `1.5`, `"idle"`). Same encoding as `Param.default`.
    /// Required by codegen — every variable declares a default — so the
    /// editor enforces a non-null `default_text` on save.
    default_text: []const u8,

    /// True when this variable's `type_name` starts with `?` — the only
    /// shape `ClearVariable` and `HasValueVariable` accept. Pure helper
    /// so callers don't sprinkle `startsWith(?)` checks across the UI.
    pub fn isNullable(self: Variable) bool {
        return self.type_name.len > 0 and self.type_name[0] == '?';
    }
};

// ─── Typed editing of `.other` node fields ─────────────────────────────
//
// `Subflow`/`Param`/`Output` are modeled structurally above. Every other
// node type is `.other` and carries its type-specific keys verbatim in
// `extras`. The editor still wants to *field-edit* a handful of common
// node types — without promoting them to first-class `NodeKind`s, which
// would mean per-type writer branches. Instead the editor uses the
// `OtherFieldSpec` table: for a recognised `type_name` it names the one
// key the inspector exposes as a widget; the value stays in `extras`, so
// the existing deterministic writer emits it unchanged and genuinely
// unknown keys keep round-tripping verbatim.

/// How the inspector should render a recognised `.other` field.
pub const OtherFieldWidget = enum {
    /// Free-form text edited as a JSON string value.
    text,
    /// A fixed choice list (currently only `BinOp.op`).
    op_combo,
    /// A JSON literal of any type (`Literal.value`) — normalised on edit.
    literal,
};

/// Names the single editable field for a recognised `.other` node type.
pub const OtherFieldSpec = struct {
    /// The node `type` string this spec matches (e.g. `"BinOp"`).
    type_name: []const u8,
    /// The `extras` key the inspector edits (e.g. `"op"`).
    key: []const u8,
    /// Inspector label shown next to the widget.
    label: []const u8,
    widget: OtherFieldWidget,
    /// Closed choice list for `.op_combo` (empty for other widgets).
    choices: []const []const u8 = &.{},
};

/// The closed list of `BinOp.op` values offered by the combo box.
pub const bin_ops = [_][]const u8{ "add", "sub", "mul", "div" };

/// `Compare.op` values — comparison operators (flow-codegen#7).
pub const compare_ops = [_][]const u8{ "eq", "ne", "lt", "le", "gt", "ge" };

/// `Logic.op` values — boolean operators (flow-codegen#7).
pub const logic_ops = [_][]const u8{ "and", "or", "not" };

/// Recognised `.other` node types and their one editable field. Keeping
/// this in `flow_io` (next to the model) makes it unit-testable without
/// a GUI and keeps the editor a thin consumer.
pub const other_field_specs = [_]OtherFieldSpec{
    .{ .type_name = "BinOp", .key = "op", .label = "Operator", .widget = .op_combo, .choices = &bin_ops },
    .{ .type_name = "Compare", .key = "op", .label = "Comparison", .widget = .op_combo, .choices = &compare_ops },
    .{ .type_name = "Logic", .key = "op", .label = "Logic", .widget = .op_combo, .choices = &logic_ops },
    .{ .type_name = "GetComponent", .key = "component", .label = "Component", .widget = .text },
    .{ .type_name = "SetField", .key = "target", .label = "Target", .widget = .text },
    .{ .type_name = "Literal", .key = "value", .label = "Value", .widget = .literal },
    .{ .type_name = "Identifier", .key = "name", .label = "Name", .widget = .text },
    .{ .type_name = "Call", .key = "callee", .label = "Callee", .widget = .text },
};

/// Return the editable-field spec for a node `type_name`, or null when
/// the type is genuinely unknown (the inspector then shows the verbatim
/// fallback view).
pub fn otherFieldSpec(type_name: []const u8) ?OtherFieldSpec {
    for (other_field_specs) |spec| {
        if (std.mem.eql(u8, spec.type_name, type_name)) return spec;
    }
    return null;
}

/// Look up the verbatim value text of an `extras` key, or null when the
/// node doesn't carry that key.
pub fn extraValue(node: Node, key: []const u8) ?[]const u8 {
    for (node.extras) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.value_text;
    }
    return null;
}

/// Set (or insert) an `extras` key on `node` to `value_text`, keeping the
/// slice sorted so the writer stays deterministic. `value_text` must
/// already be canonical JSON value text — callers pass the output of
/// `jsonValueToText` or `normalizeValueText`. The new slice and its
/// strings are allocated on `a`; the previous slice is left for the
/// arena to reclaim.
pub fn setExtraValue(
    a: std.mem.Allocator,
    node: *Node,
    key: []const u8,
    value_text: []const u8,
) !void {
    for (node.extras) |*kv| {
        if (std.mem.eql(u8, kv.key, key)) {
            kv.value_text = try a.dupe(u8, value_text);
            return;
        }
    }
    const out = try a.alloc(KeyValue, node.extras.len + 1);
    @memcpy(out[0..node.extras.len], node.extras);
    out[node.extras.len] = .{
        .key = try a.dupe(u8, key),
        .value_text = try a.dupe(u8, value_text),
    };
    sortKeyValues(out);
    node.extras = out;
}

/// Append a fresh `.other`-kind node carrying `type_name` plus the seeded
/// `default_extras`, returning the new node's id. The expression/control
/// node kinds (`BinOp`, `Compare`, `Logic`, `Literal`, `Identifier`,
/// `SetField`, `Branch`, `ForRange`, `While`, …) are all `.other`, so they
/// can't route through `NodeKind.typeName()` (null for `.other`) — the
/// editor names the type directly and seeds the one editable extra the
/// inspector exposes via `otherFieldSpec`.
///
/// `default_extras` values must already be canonical JSON value text (the
/// same shape `setExtraValue` / the inspector widgets write): a JSON
/// string for `op`/`name`/`target` (`"add"`, `""`), a bare JSON literal
/// for `Literal.value` (`0`). Each key + value is duped onto the doc arena
/// so the caller's slices needn't outlive this call, and the extras stay
/// sorted so the deterministic writer emits them unchanged. Control nodes
/// (`Branch`/`ForRange`/`While`) pass an empty `default_extras` — their
/// wiring is pins + exec edges, with no editable field.
///
/// Pure over `FlowDoc` (no editor/imgui dependency) so it's exercisable in
/// the `zig build test` target, which excludes the zgui stack.
pub fn appendOtherNode(
    doc: *FlowDoc,
    type_name: []const u8,
    default_extras: []const KeyValue,
) !u32 {
    const a = doc.allocator();
    const id = doc.nextNodeId();

    // Place new nodes in a staggered cascade so they don't all stack on
    // the origin — mirrors `flow_doc.addNode`.
    const offset: f32 = @floatFromInt((doc.nodes.len % 8) * 30);
    var node: Node = .{
        .id = id,
        .type_name = try a.dupe(u8, type_name),
        .kind = .other,
        .pos = .{ 40 + offset, 40 + offset },
    };
    for (default_extras) |kv| {
        // `setExtraValue` dupes key + value onto `a` and keeps the slice
        // sorted; seeding through it keeps the on-disk extras byte-identical
        // to an inspector-edited node.
        try setExtraValue(a, &node, kv.key, kv.value_text);
    }

    const out = try a.alloc(Node, doc.nodes.len + 1);
    @memcpy(out[0..doc.nodes.len], doc.nodes);
    out[doc.nodes.len] = node;
    doc.nodes = out;
    return id;
}

/// Decode a JSON-string `extras` value (e.g. `"add"`) back to its raw
/// inner text for display in a text widget. When the stored value isn't
/// a JSON string (a `Literal.value` may be a number or bool) the
/// canonical text is returned unchanged. Result is owned by `a`.
pub fn decodeStringValue(a: std.mem.Allocator, value_text: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, value_text, " \t\r\n");
    if (trimmed.len < 2 or trimmed[0] != '"') return a.dupe(u8, trimmed);
    var parsed = std.json.parseFromSlice(std.json.Value, a, trimmed, .{}) catch {
        return a.dupe(u8, trimmed);
    };
    defer parsed.deinit();
    if (parsed.value != .string) return a.dupe(u8, trimmed);
    return a.dupe(u8, parsed.value.string);
}

/// Buffer-backed variant of `decodeStringValue` — decodes a JSON-string
/// `extras` value into the caller-provided `buf` and returns a slice
/// into it, allocating nothing on any persistent allocator. Used by
/// per-frame inspector widgets so they don't leak onto the document
/// arena (one decode per frame for as long as a node stays selected).
///
/// The transient JSON parse runs against an internal stack-backed
/// `FixedBufferAllocator` whose scratch space is reclaimed on return —
/// nothing it allocates escapes.
///
/// When the stored value isn't a JSON string, or the decoded text would
/// not fit in `buf`, the canonical text is copied verbatim (truncated to
/// `buf` if necessary) — the same fall-through `decodeStringValue` uses.
///
/// `buf` is written as a valid NUL-terminated edit buffer: one byte is
/// reserved for the `0` sentinel, so the copied text is at most
/// `buf.len - 1` bytes and a `0` is always written immediately after it.
/// This lets a widget consume `buf` directly via `inputText` / `sliceTo`
/// without trailing garbage past the value.
pub fn decodeStringValueBuf(buf: []u8, value_text: []const u8) []const u8 {
    std.debug.assert(buf.len > 0);
    // One byte is reserved for the editor's NUL sentinel.
    const cap = buf.len - 1;
    const trimmed = std.mem.trim(u8, value_text, " \t\r\n");
    const verbatim = blk: {
        const n = @min(cap, trimmed.len);
        @memcpy(buf[0..n], trimmed[0..n]);
        buf[n] = 0;
        break :blk buf[0..n];
    };
    if (trimmed.len < 2 or trimmed[0] != '"') return verbatim;

    // Scratch space for the transient parse. A JSON-string `extras`
    // value is small (an operator word, a component/identifier name);
    // 1 KiB comfortably covers any realistic field plus parser slack,
    // and the fall-through handles anything larger gracefully.
    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        fba.allocator(),
        trimmed,
        .{},
    ) catch return verbatim;
    defer parsed.deinit();
    if (parsed.value != .string) return verbatim;
    const inner = parsed.value.string;
    if (inner.len > cap) return verbatim;
    @memcpy(buf[0..inner.len], inner);
    buf[inner.len] = 0;
    return buf[0..inner.len];
}

/// Result of `decodeStringValueBufChecked` — the decoded slice plus a
/// flag telling the caller the value did not fit the buffer verbatim.
pub const DecodedValue = struct {
    /// The decoded (or, on fall-through, verbatim) text — a slice into
    /// the caller's buffer, possibly truncated.
    text: []const u8,
    /// True when the canonical/decoded text was longer than the buffer
    /// and `text` is therefore a truncated, lossy view. A caller that
    /// would write `text` back must instead treat the field as
    /// read-only so the original value round-trips untouched.
    truncated: bool,
};

/// Like `decodeStringValueBuf`, but also reports whether the value was
/// too long to represent in `buf` without loss. An inline editor must
/// check `truncated` and refuse to write the field when it is set —
/// editing a truncated view and saving it would corrupt the stored
/// value (silent data loss).
///
/// `truncated` is true when either the decoded inner string, or the
/// verbatim canonical text used on fall-through, would not fit in
/// `buf` (which always reserves one byte for the input-widget
/// sentinel). When false the returned `text` is the exact, complete
/// value and is safe to edit.
///
/// The returned text is always written as a valid NUL-terminated edit
/// buffer: a `0` sentinel is placed immediately after the copied text
/// (within the byte reserved for it), so a caller may hand `buf`
/// straight to `inputText` / `sliceTo` without trailing garbage past
/// the value.
pub fn decodeStringValueBufChecked(buf: []u8, value_text: []const u8) DecodedValue {
    std.debug.assert(buf.len > 0);
    // One byte is reserved for the editor's NUL sentinel, so a value of
    // exactly `buf.len` would still be truncated by the widget.
    const cap = buf.len - 1;
    const trimmed = std.mem.trim(u8, value_text, " \t\r\n");

    // Copy at most `cap` bytes of `text` into `buf`, write the `0`
    // sentinel after it, and return the result as a `DecodedValue`.
    const verbatim = struct {
        fn fill(b: []u8, c: usize, text: []const u8, lossy: bool) DecodedValue {
            const n = @min(c, text.len);
            @memcpy(b[0..n], text[0..n]);
            b[n] = 0;
            return .{ .text = b[0..n], .truncated = lossy };
        }
    }.fill;

    // Non-string canonical values (numbers, bools, null) are edited
    // verbatim; they fit only when shorter than the editable capacity.
    if (trimmed.len < 2 or trimmed[0] != '"') {
        return verbatim(buf, cap, trimmed, trimmed.len > cap);
    }

    var scratch: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        fba.allocator(),
        trimmed,
        .{},
    ) catch {
        // Unparseable — fall through to the verbatim canonical text.
        return verbatim(buf, cap, trimmed, trimmed.len > cap);
    };
    defer parsed.deinit();
    if (parsed.value != .string) {
        return verbatim(buf, cap, trimmed, trimmed.len > cap);
    }
    const inner = parsed.value.string;
    if (inner.len > cap) {
        // The decoded text won't fit; surface a truncated verbatim view
        // and mark it lossy so the editor stays read-only.
        return verbatim(buf, cap, trimmed, true);
    }
    @memcpy(buf[0..inner.len], inner);
    buf[inner.len] = 0;
    return .{ .text = buf[0..inner.len], .truncated = false };
}

/// Canonical JSON text for a plain string value — the form a `.text`
/// widget's input must be stored as so the writer emits valid JSON.
pub fn encodeStringValue(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try writeJsonString(a, &out, raw);
    return out.toOwnedSlice(a);
}

/// One graph edge — same `{node, pin}` shape on both ends as `.flow.zon`
/// used (RFC §2, `links` → `edges` is a rename only).
pub const Edge = struct {
    from_node: u32,
    from_pin: []const u8,
    to_node: u32,
    to_pin: []const u8,
};

/// One control-flow (execution) edge — the top-level `exec_edges` block
/// (flow-codegen#8, #21). Distinct from a data `Edge`: the source is a
/// named exec-output pin on a `Branch` (`then`/`else`) or loop
/// (`ForRange`/`While` → `body`); the target is a *bare* node ref (the
/// node is *entered*, not wired to an input pin), so there's no
/// `to_pin`. Mirrors flow-codegen's `ExecEdge`
/// (`flow-codegen/src/flow_io.zig`), flattened to match the shape of
/// `Edge` above.
pub const ExecEdge = struct {
    from_node: u32,
    from_pin: []const u8,
    to_node: u32,
};

/// A purely-cosmetic comment / group frame (labelle-gui#188). Editor-only
/// annotation: a labeled, translucent rounded rectangle drawn *behind* the
/// nodes at `x`/`y` with size `w`/`h`. Persisted in the top-level
/// `comments` block of the `.flow.jsonc`; flow-codegen ignores the key
/// (`ignore_unknown_fields = true`), so it has no codegen effect. `color`
/// is a packed `0xRRGGBBAA` value — null → the editor's default frame tint.
///
/// `id` is a stable, monotonically-assigned identifier (labelle-gui#188)
/// used to key the editor's group node so the editor's per-frame
/// drag/resize state follows the *frame*, not its slice index. Deleting a
/// non-last comment shifts indices, so an index-derived editor id would
/// make a surviving frame inherit the deleted frame's editor state —
/// hence a stable id. Persisted in the `comments` block; a value of `0`
/// means "unassigned" (a pre-id file, or a default-constructed entry) and
/// the loader assigns a fresh id on load so older files stay compatible.
pub const Comment = struct {
    text: []const u8 = "",
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 200,
    h: f32 = 120,
    color: ?u32 = null,
    id: u32 = 0,
};

/// The flow's entry point. `type` is a lifecycle event name (e.g.
/// `OnCreate`) or `OnCall` for a subgraph (RFC §3). `arg_entity` and any
/// other event keys are captured in `extras` so they round-trip.
///
/// `OnEvent` has two forms (RFC-PLUGIN-EVENTS §7):
///
/// - **New form** — `name` set (`"<plugin>.<event>"`), legacy fields
///   absent. Codegen resolves the name through the assembler's
///   `PluginEvents` / `GameEvents` union and reflects the handler
///   signature.
/// - **Legacy form** — `module` + `callback` set, optional `params`
///   listing the callback's signature. v1 behaviour: binds the flow to
///   a plugin's `pub var ?*const fn` slot. Dropped in phase 6; for now
///   the editor round-trips it and offers a "Convert to new form"
///   button.
///
/// `module` / `callback` / `params` / `name` are *not* duped into
/// `extras` — they ride in their own structurally-modeled fields so
/// the editor can validate "exactly one form" and offer the dropdown
/// without rummaging through arbitrary keys. Genuinely-unknown event
/// keys (e.g. `arg_entity` on `OnCreate`) still round-trip via
/// `extras` as before.
pub const Event = struct {
    type_name: []const u8 = "OnCreate",
    extras: []KeyValue = &.{},

    /// `OnEvent` new-form name (RFC-PLUGIN-EVENTS §7). Null for every
    /// other event type or for a legacy-form `OnEvent`.
    name: ?[]const u8 = null,
    /// `OnEvent` legacy `module` field — the plugin's `@import` name
    /// (e.g. `"box2d"`). Null for every other event type or for a
    /// new-form `OnEvent`.
    module: ?[]const u8 = null,
    /// `OnEvent` legacy `callback` field — the `pub var` slot name
    /// (e.g. `"on_collision_begin"`). Null for every other event type
    /// or for a new-form `OnEvent`.
    callback: ?[]const u8 = null,
    /// `OnEvent` legacy `params` list — the callback's signature. Empty
    /// for every other event type or for a new-form `OnEvent`.
    params: []Param = &.{},
};

/// A fully parsed flow graph plus the arena that owns every slice and
/// string it points at. Caller frees via `deinit`.
pub const FlowDoc = struct {
    arena: *std.heap.ArenaAllocator,
    /// Optional top-level `name` (registry key). Null → effective name
    /// is the filename basename (RFC §5).
    name: ?[]const u8 = null,
    event: Event = .{},
    /// True when the source file carried a `"event"` header — the
    /// editor needs to track this separately so a flow that declares
    /// its trigger via in-graph `Event` nodes (RFC-FLOW-VOCABULARY §3)
    /// doesn't get an `OnCreate` header injected on save. The writer
    /// emits the header only when `event_present` is true.
    event_present: bool = false,
    params: []Param = &.{},
    /// Top-level declared variables (RFC-FLOW-VOCABULARY §4). Empty for
    /// flows that declare none — absence in the source file is
    /// indistinguishable from `"variables": []`.
    variables: []Variable = &.{},
    nodes: []Node = &.{},
    edges: []Edge = &.{},
    /// Control-flow (execution) edges (flow-codegen#8, #21). Empty for
    /// every flow that declares no `Branch`/`ForRange`/`While` node — the
    /// default and the only shape that existed before control flow.
    /// Absence in the source file is indistinguishable from
    /// `"exec_edges": []`; the writer emits the key only when non-empty so
    /// pre-control-flow files round-trip byte-for-byte.
    exec_edges: []ExecEdge = &.{},
    /// Editor-only comment / group frames (labelle-gui#188). Empty for every
    /// flow that declares none — the default and the only shape that
    /// existed before comment frames. Absence in the source file is
    /// indistinguishable from `"comments": []`; the writer emits the key
    /// only when non-empty so pre-comment files round-trip byte-for-byte.
    /// flow-codegen ignores the key, so it has no codegen effect.
    comments: []Comment = &.{},
    /// Highest node id seen — the editor allocates fresh ids above this.
    max_node_id: u32 = 0,
    /// Highest comment id seen (labelle-gui#188). Comment ids live in their
    /// own namespace (they're not node ids), so they get their own
    /// monotonic counter. Seeded from the loaded `comments` block and
    /// bumped by `nextCommentId` so a fresh frame never reuses an id.
    max_comment_id: u32 = 0,

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

    /// Allocate a fresh comment id one above the current maximum
    /// (labelle-gui#188). Bumps `max_comment_id` so successive calls — and
    /// any id-on-load assignment — never collide. Ids are 1-based; `0`
    /// stays reserved as the "unassigned" sentinel.
    pub fn nextCommentId(self: *FlowDoc) u32 {
        self.max_comment_id += 1;
        return self.max_comment_id;
    }
};

// ─── Reader ─────────────────────────────────────────────────────────────

pub const ParseError = error{
    NotAnObject,
    MissingNodeId,
    DuplicateNodeId,
    BadNodeType,
    BadEdge,
    /// A top-level key (`name`, `event`, `params`, `nodes`, `edges`) or a
    /// nested field held a value of the wrong JSON type. The parser
    /// rejects malformed schema rather than silently substituting a
    /// default — a silent default would mask data the author intended.
    BadSchema,
    /// An `OnEvent` event has neither `name` nor `module`+`callback`, or
    /// it has both, or only one of `module`/`callback` is set. The two
    /// forms are mutually exclusive (RFC-PLUGIN-EVENTS §7).
    MalformedFlow,
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
        if (v != .string) return ParseError.BadSchema;
        doc.name = try a.dupe(u8, v.string);
    }

    // ── event ──
    if (root.get("event")) |v| {
        if (v != .object) return ParseError.BadSchema;
        doc.event = try parseEvent(a, v.object);
        doc.event_present = true;
    }

    // ── params ──
    if (root.get("params")) |v| {
        if (v != .array) return ParseError.BadSchema;
        doc.params = try parseParams(a, v.array);
    }

    // ── variables ── (RFC-FLOW-VOCABULARY §4)
    if (root.get("variables")) |v| {
        if (v != .array) return ParseError.BadSchema;
        doc.variables = try parseVariables(a, v.array);
    }

    // ── nodes ──
    if (root.get("nodes")) |v| {
        if (v != .array) return ParseError.BadSchema;
        const r = try parseNodes(a, v.array);
        doc.nodes = r.nodes;
        doc.max_node_id = r.max_id;
    }

    // ── edges ──
    if (root.get("edges")) |v| {
        if (v != .array) return ParseError.BadSchema;
        doc.edges = try parseEdges(a, v.array);
    }

    // ── exec_edges ── (flow-codegen#8, #21) Control-flow edges. Absent →
    // empty slice; the writer then omits the key so the file round-trips
    // byte-for-byte.
    if (root.get("exec_edges")) |v| {
        if (v != .array) return ParseError.BadSchema;
        doc.exec_edges = try parseExecEdges(a, v.array);
    }

    // ── comments ── (labelle-gui#188) Editor-only comment / group frames.
    // Absent → empty slice; the writer then omits the key so the file
    // round-trips byte-for-byte. flow-codegen ignores the key entirely.
    if (root.get("comments")) |v| {
        if (v != .array) return ParseError.BadSchema;
        doc.comments = try parseComments(a, v.array);
        // Seed the comment-id counter from the highest persisted id, then
        // backfill ids for any pre-id / unassigned (`0`) entries so every
        // comment carries a stable, unique editor id (labelle-gui#188).
        for (doc.comments) |c| {
            if (c.id > doc.max_comment_id) doc.max_comment_id = c.id;
        }
        for (doc.comments) |*c| {
            if (c.id == 0) c.id = doc.nextCommentId();
        }
    }

    return doc;
}

fn parseEvent(a: std.mem.Allocator, obj: std.json.ObjectMap) !Event {
    var ev: Event = .{};
    var extras: std.ArrayList(KeyValue) = .empty;

    // First pass — pull `type` out so we can dispatch on it.
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) {
            if (entry.value_ptr.* != .string) return ParseError.BadSchema;
            ev.type_name = try a.dupe(u8, entry.value_ptr.string);
            break;
        }
    }
    const is_on_event = std.mem.eql(u8, ev.type_name, "OnEvent");

    // Second pass — model `OnEvent`'s structural fields
    // (`name`/`module`/`callback`/`params`) separately from `extras` so
    // the editor can validate the two-form rule and offer the dropdown.
    // Every other event type (`OnCreate`/`OnUpdate`/`OnDestroy`/`OnCall`)
    // keeps the pre-RFC behaviour: all non-`type` keys ride in `extras`.
    it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "type")) continue;

        if (is_on_event) {
            if (std.mem.eql(u8, key, "name")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                ev.name = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (std.mem.eql(u8, key, "module")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                ev.module = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (std.mem.eql(u8, key, "callback")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                ev.callback = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (std.mem.eql(u8, key, "params")) {
                if (entry.value_ptr.* != .array) return ParseError.BadSchema;
                ev.params = try parseParams(a, entry.value_ptr.array);
                continue;
            }
        }

        try extras.append(a, .{
            .key = try a.dupe(u8, key),
            .value_text = try jsonValueToText(a, entry.value_ptr.*),
        });
    }
    sortKeyValues(extras.items);
    ev.extras = try extras.toOwnedSlice(a);

    // `OnEvent` two-form rule (RFC-PLUGIN-EVENTS §7): `name` XOR
    // (`module` + `callback`). Both set, neither set, or only one of
    // `module`/`callback` set is `MalformedFlow`. This is the same
    // validation `flow-codegen`'s `buildEvent` enforces (`flow-codegen`
    // `flow_io.zig:342-353`).
    if (is_on_event) {
        const has_new = ev.name != null;
        const has_legacy_complete = ev.module != null and ev.callback != null;
        const has_legacy_partial = (ev.module != null) != (ev.callback != null);
        if (has_legacy_partial) return ParseError.MalformedFlow;
        if (has_new and (ev.module != null or ev.callback != null))
            return ParseError.MalformedFlow;
        if (!has_new and !has_legacy_complete) return ParseError.MalformedFlow;
    }

    return ev;
}

fn parseVariables(a: std.mem.Allocator, arr: std.json.Array) ![]Variable {
    var out: std.ArrayList(Variable) = .empty;
    for (arr.items) |item| {
        if (item != .object) return ParseError.BadSchema;
        const o = item.object;
        const name_v = o.get("name") orelse return ParseError.BadSchema;
        const type_v = o.get("type") orelse return ParseError.BadSchema;
        // codegen rejects a variable without a `default` — the same
        // contract holds here so a save can't produce a flow codegen
        // refuses (every variable must declare an initial value).
        const default_v = o.get("default") orelse return ParseError.BadSchema;
        if (name_v != .string or type_v != .string) return ParseError.BadSchema;
        try out.append(a, .{
            .name = try a.dupe(u8, name_v.string),
            .type_name = try a.dupe(u8, type_v.string),
            .default_text = try jsonValueToText(a, default_v),
        });
    }
    return out.toOwnedSlice(a);
}

fn parseParams(a: std.mem.Allocator, arr: std.json.Array) ![]Param {
    var out: std.ArrayList(Param) = .empty;
    for (arr.items) |item| {
        if (item != .object) return ParseError.BadSchema;
        const o = item.object;
        // `name` and `type` are required identifier strings — a missing
        // or wrong-typed field is malformed schema, not a defaultable
        // omission.
        const name_v = o.get("name") orelse return ParseError.BadSchema;
        if (name_v != .string) return ParseError.BadSchema;
        const type_v = o.get("type") orelse return ParseError.BadSchema;
        if (type_v != .string) return ParseError.BadSchema;
        var p: Param = .{
            .name = try a.dupe(u8, name_v.string),
            .type_name = try a.dupe(u8, type_v.string),
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
    defer seen.deinit(a);
    var max_id: u32 = 0;

    for (arr.items) |item| {
        if (item != .object) return ParseError.BadNodeType;
        const o = item.object;

        const id_v = o.get("id") orelse return ParseError.MissingNodeId;
        const id = jsonIntId(id_v) orelse return ParseError.MissingNodeId;
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

            // A modeled structural key with the wrong JSON type is
            // malformed schema. Tolerating it would route the value
            // into `extras` and emit a duplicate key on the next save.
            if (kind == .subflow and std.mem.eql(u8, key, "flow")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.flow_ref = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (kind == .subflow and std.mem.eql(u8, key, "bindings")) {
                if (entry.value_ptr.* != .object) return ParseError.BadSchema;
                node.bindings = try parseBindings(a, entry.value_ptr.object);
                continue;
            }
            if (kind == .param and std.mem.eql(u8, key, "param")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.param_ref = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (kind == .output and std.mem.eql(u8, key, "name")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.output_name = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (kind == .emit and std.mem.eql(u8, key, "event")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.event_ref = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            // `Event` (RFC-FLOW-VOCABULARY §3) — the dotted event name
            // lives in `name`, not `event` (that key is the discriminator).
            if (kind == .event and std.mem.eql(u8, key, "name")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.event_ref = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            // Variable-op nodes (RFC-FLOW-VOCABULARY §4) — all use a
            // `name` field naming the targeted variable. `ChangeVariable`
            // additionally carries the inline `by` literal.
            if ((kind == .get_variable or kind == .set_variable or
                kind == .change_variable or kind == .clear_variable or
                kind == .has_value_variable) and std.mem.eql(u8, key, "name"))
            {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.variable_ref = try a.dupe(u8, entry.value_ptr.string);
                continue;
            }
            if (kind == .change_variable and std.mem.eql(u8, key, "by")) {
                // `by` is JSON-native (number, bool, …) — captured as
                // canonical text the writer splices verbatim.
                node.by_text = try jsonValueToText(a, entry.value_ptr.*);
                continue;
            }
            // `CustomNode` (RFC-FLOW-VOCABULARY §1, §6) — the dotted
            // plugin/script-FlowNode name lives in `name`.
            if (kind == .custom_node and std.mem.eql(u8, key, "name")) {
                if (entry.value_ptr.* != .string) return ParseError.BadSchema;
                node.custom_name = try a.dupe(u8, entry.value_ptr.string);
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
    // Sort by name for a stable writer order. The writer re-sorts too
    // (the editor can reorder bindings between parse and save).
    std.mem.sort(Binding, out.items, {}, bindingLessThan);
    return out.toOwnedSlice(a);
}

fn bindingLessThan(_: void, x: Binding, y: Binding) bool {
    return std.mem.lessThan(u8, x.name, y.name);
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
    const node = jsonIntId(node_v) orelse return ParseError.BadEdge;
    const pin_v = obj.get("pin") orelse return ParseError.BadEdge;
    if (pin_v != .string) return ParseError.BadEdge;
    return .{ .node = node, .pin = try a.dupe(u8, pin_v.string) };
}

/// Parse the top-level `exec_edges` array (flow-codegen#8, #21). Each
/// entry is `{ "from": { "node", "pin" }, "to": { "node" } }`: `from` is
/// a full pin ref (the named exec output — `then`/`else`/`body`); `to` is
/// a *bare* node ref with no `pin` (the target node is entered, not wired
/// to an input).
fn parseExecEdges(a: std.mem.Allocator, arr: std.json.Array) ![]ExecEdge {
    var out: std.ArrayList(ExecEdge) = .empty;
    for (arr.items) |item| {
        if (item != .object) return ParseError.BadEdge;
        const o = item.object;
        const from = o.get("from") orelse return ParseError.BadEdge;
        const to = o.get("to") orelse return ParseError.BadEdge;
        if (from != .object or to != .object) return ParseError.BadEdge;
        const fe = try parseEndpoint(a, from.object);
        const to_node_v = to.object.get("node") orelse return ParseError.BadEdge;
        const to_node = jsonIntId(to_node_v) orelse return ParseError.BadEdge;
        try out.append(a, .{
            .from_node = fe.node,
            .from_pin = fe.pin,
            .to_node = to_node,
        });
    }
    return out.toOwnedSlice(a);
}

/// Parse the top-level `comments` array (labelle-gui#188). Each entry is
/// `{ "text": "...", "x": N, "y": N, "w": N, "h": N, "color"?: N }`. `text`
/// defaults to empty; the geometry fields fall back to the `Comment`
/// defaults when absent; `color` is an optional packed `0xRRGGBBAA`.
fn parseComments(a: std.mem.Allocator, arr: std.json.Array) ![]Comment {
    var out: std.ArrayList(Comment) = .empty;
    for (arr.items) |item| {
        if (item != .object) return ParseError.BadSchema;
        const o = item.object;
        var c: Comment = .{};
        if (o.get("text")) |t| {
            if (t != .string) return ParseError.BadSchema;
            c.text = try a.dupe(u8, t.string);
        }
        if (o.get("x")) |v| c.x = jsonNumberAsF32(v) orelse return ParseError.BadSchema;
        if (o.get("y")) |v| c.y = jsonNumberAsF32(v) orelse return ParseError.BadSchema;
        if (o.get("w")) |v| c.w = jsonNumberAsF32(v) orelse return ParseError.BadSchema;
        if (o.get("h")) |v| c.h = jsonNumberAsF32(v) orelse return ParseError.BadSchema;
        if (o.get("color")) |v| {
            if (v == .null) {
                c.color = null;
            } else {
                c.color = jsonIntId(v) orelse return ParseError.BadSchema;
            }
        }
        // Stable editor id (labelle-gui#188). Absent / `0` → "unassigned";
        // the caller fills it in on load so pre-id files stay compatible.
        if (o.get("id")) |v| c.id = jsonIntId(v) orelse return ParseError.BadSchema;
        try out.append(a, c);
    }
    return out.toOwnedSlice(a);
}

/// Read a JSON number expected to be a non-negative `u32` node id.
/// Accepts a plain integer, and also a float (or `number_string`) that
/// has no fractional part — hand-authored files and exporters often
/// write `1.0` where the writer would emit `1`. Returns null when the
/// value is not a whole number in `u32` range.
fn jsonIntId(v: std.json.Value) ?u32 {
    switch (v) {
        .integer => |n| return std.math.cast(u32, n),
        .float => |f| {
            if (@floor(f) != f or f < 0 or f > std.math.maxInt(u32)) return null;
            return @intFromFloat(f);
        },
        .number_string => |s| {
            const n = std.fmt.parseInt(i64, s, 10) catch {
                const f = std.fmt.parseFloat(f64, s) catch return null;
                if (@floor(f) != f or f < 0 or f > std.math.maxInt(u32)) return null;
                return @intFromFloat(f);
            };
            return std.math.cast(u32, n);
        },
        else => return null,
    }
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

/// Normalise free-form editor input into canonical JSON value text
/// safe to splice into a `.flow.jsonc` file.
///
/// `default`s and `Subflow` bindings are typed into a text box by the
/// user; that raw text must never reach the writer verbatim, or a save
/// can produce invalid JSON (e.g. an unquoted word, an unterminated
/// string). The rule:
///   - If `input` parses as a single JSON value, return its canonical
///     text (the same form `jsonValueToText` produces — sorted object
///     keys, escaped strings, compact).
///   - Otherwise treat `input` as a plain string literal and return it
///     JSON-quoted and escaped.
///
/// This means `25` → `25`, `10.5` → `10.5`, `true` → `true`,
/// `"hi"` → `"hi"`, but a bare `hello` → `"hello"` and a stray `"`
/// → `"\""` rather than corrupting the file. The result is owned by
/// `a`. An empty / whitespace-only input yields `""` (empty JSON
/// string) so the field still round-trips as valid JSON.
pub fn normalizeValueText(a: std.mem.Allocator, input: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");
    if (trimmed.len == 0) {
        return a.dupe(u8, "\"\"");
    }
    var parsed = std.json.parseFromSlice(std.json.Value, a, trimmed, .{}) catch {
        // Not valid JSON — fall back to a quoted string literal.
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try writeJsonString(a, &out, trimmed);
        return out.toOwnedSlice(a);
    };
    defer parsed.deinit();
    return jsonValueToText(a, parsed.value);
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

    // event — emitted only when the file carries one (RFC-FLOW-VOCABULARY
    // §3: new-form flows declare their trigger via in-graph `Event`
    // nodes and have no `event:` header). `OnEvent`'s structural fields
    // (`name` / `module` / `callback` / `params`) are emitted in a fixed
    // order so a re-save is byte-stable regardless of edit history.
    // Generic `extras` keys (alphabetical, e.g. `arg_entity` on
    // `OnCreate`) follow. `parseEvent` already enforces the two-form
    // rule for `OnEvent`, so the writer just renders what's set.
    if (doc.event_present) {
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"event\": { \"type\": ");
        try writeJsonString(a, &out, doc.event.type_name);
        if (doc.event.name) |n| {
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, &out, n);
        }
        if (doc.event.module) |m| {
            try out.appendSlice(a, ", \"module\": ");
            try writeJsonString(a, &out, m);
        }
        if (doc.event.callback) |c| {
            try out.appendSlice(a, ", \"callback\": ");
            try writeJsonString(a, &out, c);
        }
        if (doc.event.params.len > 0) {
            try out.appendSlice(a, ", \"params\": [");
            for (doc.event.params, 0..) |p, i| {
                if (i > 0) try out.append(a, ',');
                try out.appendSlice(a, " { \"name\": ");
                try writeJsonString(a, &out, p.name);
                try out.appendSlice(a, ", \"type\": ");
                try writeJsonString(a, &out, p.type_name);
                if (p.default_text) |d| {
                    try out.appendSlice(a, ", \"default\": ");
                    try out.appendSlice(a, d);
                }
                try out.appendSlice(a, " }");
            }
            try out.appendSlice(a, " ]");
        }
        for (doc.event.extras) |kv| {
            try out.appendSlice(a, ", ");
            try writeJsonString(a, &out, kv.key);
            try out.appendSlice(a, ": ");
            try out.appendSlice(a, kv.value_text);
        }
        try out.appendSlice(a, " },\n");
    }

    // variables (optional — omitted entirely when empty)
    // RFC-FLOW-VOCABULARY §4 — top-level flow-scope variable declarations.
    if (doc.variables.len > 0) {
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"variables\": [\n");
        for (doc.variables, 0..) |v, i| {
            try out.appendSlice(a, indent_unit ** 2);
            try out.appendSlice(a, "{ \"name\": ");
            try writeJsonString(a, &out, v.name);
            try out.appendSlice(a, ", \"type\": ");
            try writeJsonString(a, &out, v.type_name);
            try out.appendSlice(a, ", \"default\": ");
            try out.appendSlice(a, v.default_text);
            try out.appendSlice(a, " }");
            if (i + 1 < doc.variables.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "],\n");
    }

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
    //
    // The `edges` block carries a trailing comma only when an `exec_edges`
    // block follows it — emitted (below) only when non-empty so
    // pre-control-flow files round-trip byte-for-byte. This mirrors
    // flow-codegen's writer (`renderFlowJsonc` → the `flow.exec_edges.len
    // == 0` branch).
    const has_exec = doc.exec_edges.len > 0;
    const has_comments = doc.comments.len > 0;
    // `edges` keeps a trailing comma when *any* block follows it; `exec_edges`
    // keeps one only when `comments` follows.
    const edges_trailer: []const u8 = if (has_exec or has_comments) "],\n" else "]\n";
    try out.appendSlice(a, indent_unit);
    try out.appendSlice(a, "\"edges\": [");
    if (doc.edges.len == 0) {
        try out.appendSlice(a, edges_trailer);
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
        try out.appendSlice(a, edges_trailer);
    }

    // exec_edges (flow-codegen#8, #21) — control-flow edges. Emitted only
    // when non-empty, deterministically sorted to match flow-codegen's
    // `lessThanExecEdge` (by source node id, then exec pin lexically —
    // `else` < `then` — then target node) so editor re-saves stay
    // diff-clean and byte-compatible with codegen's own writer. Each entry
    // is `{ "from": { "node": N, "pin": "<pin>" }, "to": { "node": M } }`
    // (bare target node ref, no `pin`).
    if (has_exec) {
        const sorted = try a.dupe(ExecEdge, doc.exec_edges);
        defer a.free(sorted);
        std.mem.sort(ExecEdge, sorted, {}, execEdgeLessThan);

        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"exec_edges\": [\n");
        for (sorted, 0..) |x, i| {
            try out.appendSlice(a, indent_unit ** 2);
            try out.print(a, "{{ \"from\": {{ \"node\": {d}, \"pin\": ", .{x.from_node});
            try writeJsonString(a, &out, x.from_pin);
            try out.print(a, " }}, \"to\": {{ \"node\": {d} }} }}", .{x.to_node});
            if (i + 1 < sorted.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, if (has_comments) "],\n" else "]\n");
    }

    // comments (labelle-gui#188) — editor-only comment / group frames.
    // Emitted only when non-empty, in insertion order (the editor appends
    // new frames at the end, so a re-save is diff-clean). Each entry is
    // `{ "text": "...", "x": N, "y": N, "w": N, "h": N }` plus an optional
    // `"color"` packed `0xRRGGBBAA`. flow-codegen ignores this key.
    if (has_comments) {
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "\"comments\": [\n");
        for (doc.comments, 0..) |c, i| {
            try out.appendSlice(a, indent_unit ** 2);
            try out.appendSlice(a, "{ \"text\": ");
            try writeJsonString(a, &out, c.text);
            try out.appendSlice(a, ", \"x\": ");
            try writeCoord(a, &out, c.x);
            try out.appendSlice(a, ", \"y\": ");
            try writeCoord(a, &out, c.y);
            try out.appendSlice(a, ", \"w\": ");
            try writeCoord(a, &out, c.w);
            try out.appendSlice(a, ", \"h\": ");
            try writeCoord(a, &out, c.h);
            if (c.color) |col| {
                try out.print(a, ", \"color\": {d}", .{col});
            }
            // Stable editor id (labelle-gui#188). Emitted only when
            // assigned (`!= 0`) so a hand-authored file with no ids still
            // round-trips identically until the editor touches it.
            if (c.id != 0) {
                try out.print(a, ", \"id\": {d}", .{c.id});
            }
            try out.appendSlice(a, " }");
            if (i + 1 < doc.comments.len) try out.append(a, ',');
            try out.append(a, '\n');
        }
        try out.appendSlice(a, indent_unit);
        try out.appendSlice(a, "]\n");
    }

    try out.appendSlice(a, "}\n");
    return out.toOwnedSlice(a);
}

/// Deterministic order for exec edges (flow-codegen#8) — by source node
/// id, then exec pin lexically (`else` < `then`; `body` is the loops'
/// only pin), then target node. Mirrors flow-codegen's `lessThanExecEdge`
/// so editor re-saves stay byte-compatible with codegen's writer.
fn execEdgeLessThan(_: void, x: ExecEdge, y: ExecEdge) bool {
    if (x.from_node != y.from_node) return x.from_node < y.from_node;
    const fp = std.mem.order(u8, x.from_pin, y.from_pin);
    if (fp != .eq) return fp == .lt;
    return x.to_node < y.to_node;
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
                // The editor may have renamed or appended bindings since
                // parse, leaving `n.bindings` unsorted. Sort a local copy
                // here so the on-disk key order is deterministic and a
                // re-save is idempotent regardless of edit history.
                const sorted = try a.dupe(Binding, n.bindings);
                defer a.free(sorted);
                std.mem.sort(Binding, sorted, {}, bindingLessThan);
                try out.appendSlice(a, ", \"bindings\": { ");
                for (sorted, 0..) |b, i| {
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
        .emit => {
            try out.appendSlice(a, ", \"event\": ");
            try writeJsonString(a, out, n.event_ref);
        },
        .event => {
            // `Event` (RFC-FLOW-VOCABULARY §3) — the dotted event name
            // is the node's `name`. (Don't confuse with the discriminator
            // key `type`, which holds `"Event"` itself.)
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, out, n.event_ref);
        },
        .get_variable, .set_variable, .clear_variable, .has_value_variable => {
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, out, n.variable_ref);
        },
        .change_variable => {
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, out, n.variable_ref);
            // `by` is the inline-default increment (RFC-FLOW-VOCABULARY
            // §4). Always emitted so the file is self-describing; defaults
            // to `"1"` when a fresh node is created.
            const by = if (n.by_text.len > 0) n.by_text else "1";
            try out.appendSlice(a, ", \"by\": ");
            try out.appendSlice(a, by);
        },
        .custom_node => {
            try out.appendSlice(a, ", \"name\": ");
            try writeJsonString(a, out, n.custom_name);
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

/// Write `doc` back to disk at `path`, replacing any existing file.
/// The write is atomic — see `io_global.writeFileAtomic` — so a crash
/// mid-save can never corrupt the flow graph on disk.
pub fn saveToFile(child_allocator: std.mem.Allocator, path: []const u8, doc: FlowDoc) !void {
    const text = try render(child_allocator, doc);
    defer child_allocator.free(text);
    try io_global.writeFileAtomic(
        std.Io.Dir.cwd(),
        io_global.io(),
        path,
        text,
        child_allocator,
    );
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

// ─── Legacy OnEvent converter ───────────────────────────────────────────

pub const ConvertError = error{
    /// The event is not `OnEvent`. Only `OnEvent` has the two-form
    /// structure to convert away from.
    NotOnEvent,
    /// The event is already in new form (`name` set, legacy fields
    /// absent). No conversion needed.
    AlreadyNewForm,
    /// The legacy `callback` is empty or equals `"on_"` — there is no
    /// event stem to map. `flow-codegen` reports the same case.
    MalformedCallback,
};

/// Rewrite an `OnEvent` event from the legacy `module`+`callback`
/// (+`params`) form to the new-form `name` shape (RFC-PLUGIN-EVENTS §7).
/// In-place on `ev`; strings are duped onto `a` so the result outlives
/// the source extras for as long as `a` does.
///
/// **Name mapping** (mirrors `flow-codegen`'s `legacy_onevent_to_name`):
/// the dotted name is `<module>.<event>` where `<event>` is `callback`
/// with its `on_` prefix stripped — `on_collision_begin` →
/// `collision_begin`. A `callback` that doesn't start with `on_` passes
/// through verbatim; any mismatch surfaces at codegen against the
/// `PluginEvents` union.
///
/// **Validation.** The editor runs without a `PluginEvents` handle, so
/// it does not validate the rewritten name against the discovered event
/// set — that is codegen's job. The converter rejects only the
/// structural-error cases (`NotOnEvent`, `AlreadyNewForm`,
/// `MalformedCallback`).
pub fn legacy_onevent_to_name(a: std.mem.Allocator, ev: *Event) ConvertError!void {
    if (!std.mem.eql(u8, ev.type_name, "OnEvent")) return ConvertError.NotOnEvent;
    if (ev.name != null) return ConvertError.AlreadyNewForm;

    // `parseEvent`'s two-form rule guarantees both `module` and `callback`
    // are set on the legacy form. A bare `error.MalformedCallback` here
    // would only fire on a hand-constructed `Event` value that bypassed
    // the parser — guard anyway so misuse fails loudly.
    const module = ev.module orelse return ConvertError.MalformedCallback;
    const callback = ev.callback orelse return ConvertError.MalformedCallback;

    const stem = if (std.mem.startsWith(u8, callback, "on_"))
        callback[3..]
    else
        callback;
    if (stem.len == 0) return ConvertError.MalformedCallback;

    const dotted = std.fmt.allocPrint(a, "{s}.{s}", .{ module, stem }) catch
        return ConvertError.MalformedCallback;

    ev.name = dotted;
    ev.module = null;
    ev.callback = null;
    ev.params = &.{};
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

test "exec_edges round-trip preserves a Branch's then/else control flow" {
    // A Branch flow: `cond` is a data edge into node 4; `then`/`else` are
    // exec edges (flow-codegen#8). Loading then saving must NOT drop the
    // `exec_edges` block — doing so silently corrupts the control flow.
    const src =
        \\{
        \\  "event": { "type": "OnUpdate" },
        \\  "nodes": [
        \\    { "id": 1, "type": "Literal", "pos": [0, 0] },
        \\    { "id": 4, "type": "Branch", "pos": [5, 0] },
        \\    { "id": 6, "type": "Print", "pos": [10, 0] },
        \\    { "id": 7, "type": "Print", "pos": [10, 5] }
        \\  ],
        \\  "edges": [
        \\    { "from": { "node": 1, "pin": "value" }, "to": { "node": 4, "pin": "cond" } }
        \\  ],
        \\  "exec_edges": [
        \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } },
        \\    { "from": { "node": 4, "pin": "else" }, "to": { "node": 7 } }
        \\  ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.exec_edges.len);
    // Parsed in source order (sorting happens at render time).
    try std.testing.expectEqual(@as(u32, 4), doc.exec_edges[0].from_node);
    try std.testing.expectEqualStrings("then", doc.exec_edges[0].from_pin);
    try std.testing.expectEqual(@as(u32, 6), doc.exec_edges[0].to_node);
    try std.testing.expectEqual(@as(u32, 4), doc.exec_edges[1].from_node);
    try std.testing.expectEqualStrings("else", doc.exec_edges[1].from_pin);
    try std.testing.expectEqual(@as(u32, 7), doc.exec_edges[1].to_node);

    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);

    // The writer must emit the `exec_edges` block, deterministically
    // sorted (`else` < `then`) to match flow-codegen's `lessThanExecEdge`,
    // with `to` as a bare node ref (no `pin`).
    const expected =
        \\  "exec_edges": [
        \\    { "from": { "node": 4, "pin": "else" }, "to": { "node": 7 } },
        \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } }
        \\  ]
    ;
    try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);

    // Round-trip stability: re-parse + re-render is byte-identical, and
    // the entries survive unchanged.
    var doc2 = try parse(std.testing.allocator, text);
    defer doc2.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc2.exec_edges.len);
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "exec_edges sort is stable across unsorted input (body + then/else)" {
    // Deliberately out-of-order input — the writer sorts by from_node,
    // then pin lexically, then to_node (matching flow-codegen).
    const src =
        \\{
        \\  "nodes": [
        \\    { "id": 2, "type": "ForRange", "pos": [0, 0] },
        \\    { "id": 5, "type": "Branch", "pos": [0, 0] }
        \\  ],
        \\  "edges": [],
        \\  "exec_edges": [
        \\    { "from": { "node": 5, "pin": "then" }, "to": { "node": 9 } },
        \\    { "from": { "node": 2, "pin": "body" }, "to": { "node": 8 } },
        \\    { "from": { "node": 5, "pin": "else" }, "to": { "node": 3 } }
        \\  ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);

    const expected =
        \\  "exec_edges": [
        \\    { "from": { "node": 2, "pin": "body" }, "to": { "node": 8 } },
        \\    { "from": { "node": 5, "pin": "else" }, "to": { "node": 3 } },
        \\    { "from": { "node": 5, "pin": "then" }, "to": { "node": 9 } }
        \\  ]
    ;
    try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);
}

test "absence of exec_edges is preserved (no key emitted)" {
    // A flow with no control-flow nodes must NOT gain an `exec_edges`
    // key — pre-control-flow files round-trip byte-for-byte, and the
    // `edges` block keeps its no-trailing-comma close.
    const src =
        \\{ "event": { "type": "OnCreate" }, "nodes": [], "edges": [] }
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.exec_edges.len);
    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "exec_edges") == null);
    // `edges` closes with `]` (no trailing comma) when no exec block follows.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"edges\": []\n") != null);
}

test "a programmatically-added exec edge renders back out (author round-trip)" {
    // Drag-authoring an exec edge (labelle-gui#196) appends an
    // `ExecEdge` to `doc.exec_edges`; the writer must then emit it just
    // like a hand-authored / codegen-emitted one. Build a Branch flow
    // with no exec edges, add one on the doc arena (as `appendExecEdge`
    // does), and assert it renders and re-parses cleanly.
    const src =
        \\{
        \\  "event": { "type": "OnUpdate" },
        \\  "nodes": [
        \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
        \\    { "id": 6, "type": "Print", "pos": [10, 0] }
        \\  ],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.exec_edges.len);

    // Add Branch(4).then -> 6 on the doc's own arena, mirroring the
    // editor's author path.
    const a = doc.arena.allocator();
    const added = try a.alloc(ExecEdge, 1);
    added[0] = .{ .from_node = 4, .from_pin = try a.dupe(u8, "then"), .to_node = 6 };
    doc.exec_edges = added;

    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);

    // The writer emits the block with `to` as a bare node ref (no pin).
    const expected =
        \\  "exec_edges": [
        \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } }
        \\  ]
    ;
    try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);

    // Re-parsing the rendered text recovers the authored edge unchanged.
    var doc2 = try parse(std.testing.allocator, text);
    defer doc2.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc2.exec_edges.len);
    try std.testing.expectEqual(@as(u32, 4), doc2.exec_edges[0].from_node);
    try std.testing.expectEqualStrings("then", doc2.exec_edges[0].from_pin);
    try std.testing.expectEqual(@as(u32, 6), doc2.exec_edges[0].to_node);
}

test "exec_edges parser rejects malformed entries" {
    // Non-array exec_edges.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "exec_edges": {} }
    ));
    // Missing `to`.
    try std.testing.expectError(ParseError.BadEdge, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "exec_edges": [ { "from": { "node": 1, "pin": "then" } } ] }
    ));
    // `from` missing pin.
    try std.testing.expectError(ParseError.BadEdge, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "exec_edges": [ { "from": { "node": 1 }, "to": { "node": 2 } } ] }
    ));
    // `to` missing node.
    try std.testing.expectError(ParseError.BadEdge, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "exec_edges": [ { "from": { "node": 1, "pin": "then" }, "to": {} } ] }
    ));
}

test "comments round-trip preserves editor-only frames" {
    // A flow carrying a top-level `comments` block (labelle-gui#188) must
    // round-trip it — a save that drops comments loses the user's
    // annotations. The block is editor metadata; flow-codegen ignores it.
    const src =
        \\{
        \\  "event": { "type": "OnCreate" },
        \\  "nodes": [],
        \\  "edges": [],
        \\  "comments": [
        \\    { "text": "spawn logic", "x": 40, "y": 40, "w": 220, "h": 140 },
        \\    { "text": "cleanup", "x": 300, "y": 80, "w": 180, "h": 100, "color": 4278190335 }
        \\  ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.comments.len);
    try std.testing.expectEqualStrings("spawn logic", doc.comments[0].text);
    try std.testing.expectEqual(@as(f32, 40), doc.comments[0].x);
    try std.testing.expectEqual(@as(f32, 40), doc.comments[0].y);
    try std.testing.expectEqual(@as(f32, 220), doc.comments[0].w);
    try std.testing.expectEqual(@as(f32, 140), doc.comments[0].h);
    try std.testing.expectEqual(@as(?u32, null), doc.comments[0].color);
    try std.testing.expectEqualStrings("cleanup", doc.comments[1].text);
    try std.testing.expectEqual(@as(?u32, 4278190335), doc.comments[1].color);
    // The source carried no `id`s, so the loader assigned fresh ones in
    // order (labelle-gui#188) — the editor needs a stable per-frame key.
    try std.testing.expectEqual(@as(u32, 1), doc.comments[0].id);
    try std.testing.expectEqual(@as(u32, 2), doc.comments[1].id);

    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);

    // The writer emits the block in insertion order, geometry as bare
    // integers, with `color` only on the entry that carries one and the
    // load-assigned `id` last.
    const expected =
        \\  "comments": [
        \\    { "text": "spawn logic", "x": 40, "y": 40, "w": 220, "h": 140, "id": 1 },
        \\    { "text": "cleanup", "x": 300, "y": 80, "w": 180, "h": 100, "color": 4278190335, "id": 2 }
        \\  ]
    ;
    try std.testing.expect(std.mem.indexOf(u8, text, expected) != null);

    // Round-trip stability: re-parse + re-render is byte-identical and the
    // frames survive unchanged.
    var doc2 = try parse(std.testing.allocator, text);
    defer doc2.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc2.comments.len);
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "absence of comments is preserved (no key emitted)" {
    // A flow with no comment frames must NOT gain a `comments` key —
    // pre-comment files round-trip byte-for-byte. Absence in the source
    // is indistinguishable from `"comments": []`.
    const src =
        \\{ "event": { "type": "OnCreate" }, "nodes": [], "edges": [] }
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.comments.len);
    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "comments") == null);
    // `edges` keeps its no-trailing-comma close when no block follows.
    try std.testing.expect(std.mem.indexOf(u8, text, "\"edges\": []\n") != null);
}

test "comments coexist with exec_edges (both blocks, correct commas)" {
    // When a flow carries both an `exec_edges` block and a `comments`
    // block, `edges` and `exec_edges` each need a trailing comma so the
    // JSON stays well-formed. Assert the full byte-stable round-trip.
    const src =
        \\{
        \\  "nodes": [
        \\    { "id": 4, "type": "Branch", "pos": [0, 0] },
        \\    { "id": 6, "type": "Print", "pos": [10, 0] }
        \\  ],
        \\  "edges": [],
        \\  "exec_edges": [
        \\    { "from": { "node": 4, "pin": "then" }, "to": { "node": 6 } }
        \\  ],
        \\  "comments": [
        \\    { "text": "note", "x": 0, "y": 0, "w": 200, "h": 120 }
        \\  ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.exec_edges.len);
    try std.testing.expectEqual(@as(usize, 1), doc.comments.len);

    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);
    // `exec_edges` closes with a trailing comma because `comments` follows.
    try std.testing.expect(std.mem.indexOf(u8, text, "} }\n  ],\n  \"comments\"") != null);

    var doc2 = try parse(std.testing.allocator, text);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text, text2);
}

test "comments parser rejects malformed entries" {
    // Non-array comments.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "comments": {} }
    ));
    // A non-object entry.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "comments": [ 1 ] }
    ));
    // A non-string `text`.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "comments": [ { "text": 5 } ] }
    ));
    // A non-number geometry field.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [], "edges": [], "comments": [ { "x": "nope" } ] }
    ));
}

test "comments with all defaults round-trip (sparse entry)" {
    // A comment entry may omit any field — `text` defaults empty, geometry
    // to the `Comment` defaults. The writer still emits a complete entry,
    // and a re-parse is byte-stable.
    const src =
        \\{ "nodes": [], "edges": [], "comments": [ {} ] }
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.comments.len);
    try std.testing.expectEqualStrings("", doc.comments[0].text);
    try std.testing.expectEqual(@as(f32, 200), doc.comments[0].w);

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

test "parser rejects malformed schema instead of defaulting" {
    // Wrong-typed top-level keys must error, not silently default.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "name": 42, "nodes": [], "edges": [] }
    ));
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": {}, "edges": [] }
    ));
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "event": "OnCreate", "nodes": [], "edges": [] }
    ));
    // Non-string event type.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "event": { "type": 3 }, "nodes": [], "edges": [] }
    ));
    // Param missing required name/type.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "params": [ { "type": "f32" } ], "nodes": [], "edges": [] }
    ));
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "params": [ { "name": 1, "type": "f32" } ], "nodes": [], "edges": [] }
    ));
    // Subflow `flow` with the wrong type would otherwise leak into extras.
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "nodes": [ { "id": 1, "type": "Subflow", "flow": 9 } ], "edges": [] }
    ));
}

test "node and edge ids tolerate float-formatted integers" {
    const src =
        \\{
        \\  "nodes": [ { "id": 1.0, "type": "BinOp" }, { "id": 2.0, "type": "BinOp" } ],
        \\  "edges": [ { "from": { "node": 1.0, "pin": "x" }, "to": { "node": 2.0, "pin": "a" } } ]
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(@as(u32, 1), doc.nodes[0].id);
    try std.testing.expectEqual(@as(u32, 2), doc.max_node_id);
    try std.testing.expectEqual(@as(u32, 1), doc.edges[0].from_node);
    // A genuine fractional id is still rejected.
    try std.testing.expectError(ParseError.MissingNodeId, parse(std.testing.allocator,
        \\{ "nodes": [ { "id": 1.5, "type": "BinOp" } ], "edges": [] }
    ));
}

test "normalizeValueText keeps valid JSON, quotes anything else" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "25", .out = "25" },
        .{ .in = "  10.5 ", .out = "10.5" },
        .{ .in = "true", .out = "true" },
        .{ .in = "\"hi\"", .out = "\"hi\"" },
        .{ .in = "hello", .out = "\"hello\"" }, // bare word → quoted
        .{ .in = "\"", .out = "\"\\\"\"" }, // stray quote → escaped
        .{ .in = "", .out = "\"\"" }, // blank → empty JSON string
        .{ .in = "  ", .out = "\"\"" },
    };
    for (cases) |c| {
        const got = try normalizeValueText(a, c.in);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.out, got);
    }
}

test "huge flow file saves and round-trips at scale" {
    const a = std.testing.allocator;

    // Build a large `.flow.jsonc` source programmatically — ~2000 nodes
    // and ~2000 edges chaining them. Node ids are deliberately sparse
    // (id = (i + 1) * 3) so `max_node_id` and id sampling are non-trivial.
    // Node types cycle through several kinds so the parser exercises both
    // structurally-modeled nodes and `.other` capture. We accumulate the
    // string with the same ArrayList/Writer idiom `render` uses.
    const node_count: usize = 2000;
    const types = [_][]const u8{ "GetComponent", "BinOp", "Literal", "SetComponent" };

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(a);
    try src.appendSlice(a, "{\n  \"name\": \"huge_flow\",\n");
    try src.appendSlice(a, "  \"event\": { \"type\": \"OnCreate\" },\n");
    try src.appendSlice(a, "  \"nodes\": [\n");
    for (0..node_count) |i| {
        const id: u32 = @intCast((i + 1) * 3);
        const tname = types[i % types.len];
        // pos: x integral, y fractional — both must survive the trip.
        const px: i64 = @intCast(i * 40);
        const py = @as(f32, @floatFromInt(i)) * 1.5;
        try src.print(a, "    {{ \"id\": {d}, \"type\": \"{s}\", \"pos\": [{d}, {d}], \"slot\": {d} }}", .{ id, tname, px, py, i });
        if (i + 1 < node_count) try src.append(a, ',');
        try src.append(a, '\n');
    }
    try src.appendSlice(a, "  ],\n  \"edges\": [\n");
    // Chain each node to the next: ~node_count-1 edges.
    const edge_count = node_count - 1;
    for (0..edge_count) |i| {
        const from_id: u32 = @intCast((i + 1) * 3);
        const to_id: u32 = @intCast((i + 2) * 3);
        try src.print(a, "    {{ \"from\": {{ \"node\": {d}, \"pin\": \"out\" }}, \"to\": {{ \"node\": {d}, \"pin\": \"in\" }} }}", .{ from_id, to_id });
        if (i + 1 < edge_count) try src.append(a, ',');
        try src.append(a, '\n');
    }
    try src.appendSlice(a, "  ]\n}\n");

    // ── 1. Parse the huge source ──
    var doc = try parse(a, src.items);
    defer doc.deinit();

    try std.testing.expectEqualStrings("huge_flow", doc.name.?);
    try std.testing.expectEqual(node_count, doc.nodes.len);
    try std.testing.expectEqual(edge_count, doc.edges.len);
    // Highest id = (node_count) * 3.
    try std.testing.expectEqual(@as(u32, @intCast(node_count * 3)), doc.max_node_id);

    // Sample a spread of node ids / positions / types.
    const sample_idx = [_]usize{ 0, 1, 777, 1000, node_count - 1 };
    for (sample_idx) |idx| {
        try std.testing.expectEqual(@as(u32, @intCast((idx + 1) * 3)), doc.nodes[idx].id);
        try std.testing.expectEqual(@as(f32, @floatFromInt(idx * 40)), doc.nodes[idx].pos[0]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(idx)) * 1.5, doc.nodes[idx].pos[1]);
        try std.testing.expectEqualStrings(types[idx % types.len], doc.nodes[idx].type_name);
    }
    // Sample an edge endpoint.
    try std.testing.expectEqual(@as(u32, 3), doc.edges[0].from_node);
    try std.testing.expectEqual(@as(u32, 6), doc.edges[0].to_node);
    try std.testing.expectEqual(@as(u32, @intCast(node_count * 3)), doc.edges[edge_count - 1].to_node);

    // ── 2. Render — this is the editor's Save serialization. ──
    const text1 = try render(a, doc);
    defer a.free(text1);
    // The output must be genuinely large and non-trivial.
    try std.testing.expect(text1.len > 100 * 1024);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"huge_flow\"") != null);

    // ── 3. Parse the rendered text — full integrity must survive. ──
    var doc2 = try parse(a, text1);
    defer doc2.deinit();
    try std.testing.expectEqualStrings("huge_flow", doc2.name.?);
    try std.testing.expectEqual(node_count, doc2.nodes.len);
    try std.testing.expectEqual(edge_count, doc2.edges.len);
    try std.testing.expectEqual(doc.max_node_id, doc2.max_node_id);
    for (sample_idx) |idx| {
        try std.testing.expectEqual(doc.nodes[idx].id, doc2.nodes[idx].id);
        try std.testing.expectEqual(doc.nodes[idx].pos[0], doc2.nodes[idx].pos[0]);
        try std.testing.expectEqual(doc.nodes[idx].pos[1], doc2.nodes[idx].pos[1]);
        try std.testing.expectEqualStrings(doc.nodes[idx].type_name, doc2.nodes[idx].type_name);
    }
    for ([_]usize{ 0, 999, edge_count - 1 }) |idx| {
        try std.testing.expectEqual(doc.edges[idx].from_node, doc2.edges[idx].from_node);
        try std.testing.expectEqual(doc.edges[idx].to_node, doc2.edges[idx].to_node);
    }

    // ── 4. A second render must be byte-identical at scale. ──
    const text2 = try render(a, doc2);
    defer a.free(text2);
    try std.testing.expectEqualStrings(text1, text2);

    // ── 5. Real on-disk path: saveToFile → loadFromFile. ──
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fs.path.join(a, &.{
        ".zig-cache", "tmp", &tmp.sub_path, "huge.flow.jsonc",
    });
    defer a.free(path);

    try saveToFile(a, path, doc);
    var disk_doc = try loadFromFile(a, path);
    defer disk_doc.deinit();
    try std.testing.expectEqual(node_count, disk_doc.nodes.len);
    try std.testing.expectEqual(edge_count, disk_doc.edges.len);
    try std.testing.expectEqual(doc.max_node_id, disk_doc.max_node_id);
    const disk_text = try render(a, disk_doc);
    defer a.free(disk_text);
    try std.testing.expectEqualStrings(text1, disk_text);
}

test "otherFieldSpec recognises the field-editable .other node types" {
    try std.testing.expectEqual(OtherFieldWidget.op_combo, otherFieldSpec("BinOp").?.widget);
    try std.testing.expectEqualStrings("op", otherFieldSpec("BinOp").?.key);
    try std.testing.expectEqualStrings("component", otherFieldSpec("GetComponent").?.key);
    try std.testing.expectEqualStrings("target", otherFieldSpec("SetField").?.key);
    try std.testing.expectEqual(OtherFieldWidget.literal, otherFieldSpec("Literal").?.widget);
    try std.testing.expectEqualStrings("name", otherFieldSpec("Identifier").?.key);
    try std.testing.expectEqualStrings("callee", otherFieldSpec("Call").?.key);
    // A genuinely-unknown type has no spec — inspector falls back to the
    // verbatim view.
    try std.testing.expect(otherFieldSpec("SomeFutureNode") == null);
}

test "setExtraValue updates an existing key and keeps extras sorted" {
    const src =
        \\{
        \\  "nodes": [ { "id": 1, "type": "BinOp", "op": "add", "zlast": 1, "pos": [0, 0] } ],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const a = doc.allocator();

    try std.testing.expectEqualStrings("\"add\"", extraValue(doc.nodes[0], "op").?);
    try setExtraValue(a, &doc.nodes[0], "op", "\"mul\"");
    try std.testing.expectEqualStrings("\"mul\"", extraValue(doc.nodes[0], "op").?);

    // The edited graph still renders to deterministic, idempotent text.
    const text1 = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text1);
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"op\": \"mul\"") != null);
}

test "setExtraValue inserts a missing key in sorted order" {
    const src =
        \\{ "nodes": [ { "id": 1, "type": "GetComponent", "pos": [0, 0] } ], "edges": [] }
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    const a = doc.allocator();

    try std.testing.expect(extraValue(doc.nodes[0], "component") == null);
    try setExtraValue(a, &doc.nodes[0], "component", "\"Position\"");
    try std.testing.expectEqualStrings("\"Position\"", extraValue(doc.nodes[0], "component").?);

    const text = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"component\": \"Position\"") != null);
}

test "decodeStringValue / encodeStringValue round-trip" {
    const a = std.testing.allocator;
    const decoded = try decodeStringValue(a, "\"Position\"");
    defer a.free(decoded);
    try std.testing.expectEqualStrings("Position", decoded);

    const encoded = try encodeStringValue(a, "Position");
    defer a.free(encoded);
    try std.testing.expectEqualStrings("\"Position\"", encoded);

    // A non-string literal value is returned as-is by decode.
    const num = try decodeStringValue(a, "1.5");
    defer a.free(num);
    try std.testing.expectEqualStrings("1.5", num);
}

test "OnEvent new-form round-trips with name" {
    const src =
        \\{
        \\  "name": "hit_counter",
        \\  "event": { "type": "OnEvent", "name": "box2d.collision_begin" },
        \\  "nodes": [],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqualStrings("OnEvent", doc.event.type_name);
    try std.testing.expectEqualStrings("box2d.collision_begin", doc.event.name.?);
    try std.testing.expect(doc.event.module == null);
    try std.testing.expect(doc.event.callback == null);
    try std.testing.expectEqual(@as(usize, 0), doc.event.params.len);

    // Idempotent re-render.
    const text1 = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text1);
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"name\": \"box2d.collision_begin\"") != null);
}

test "OnEvent legacy form round-trips with module+callback+params" {
    const src =
        \\{
        \\  "event": {
        \\    "type": "OnEvent",
        \\    "module": "box2d",
        \\    "callback": "on_collision_begin",
        \\    "params": [
        \\      { "name": "entity_a", "type": "u32" },
        \\      { "name": "entity_b", "type": "u32" }
        \\    ]
        \\  },
        \\  "nodes": [],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expect(doc.event.name == null);
    try std.testing.expectEqualStrings("box2d", doc.event.module.?);
    try std.testing.expectEqualStrings("on_collision_begin", doc.event.callback.?);
    try std.testing.expectEqual(@as(usize, 2), doc.event.params.len);
    try std.testing.expectEqualStrings("entity_a", doc.event.params[0].name);

    // Idempotent re-render.
    const text1 = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text1);
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2);
}

test "OnEvent rejects malformed two-form combinations" {
    // Both forms set.
    try std.testing.expectError(ParseError.MalformedFlow, parse(std.testing.allocator,
        \\{ "event": { "type": "OnEvent", "name": "box2d.collision_begin", "module": "box2d", "callback": "on_collision_begin" }, "nodes": [], "edges": [] }
    ));
    // Neither form set.
    try std.testing.expectError(ParseError.MalformedFlow, parse(std.testing.allocator,
        \\{ "event": { "type": "OnEvent" }, "nodes": [], "edges": [] }
    ));
    // Only module, no callback.
    try std.testing.expectError(ParseError.MalformedFlow, parse(std.testing.allocator,
        \\{ "event": { "type": "OnEvent", "module": "box2d" }, "nodes": [], "edges": [] }
    ));
    // Only callback, no module.
    try std.testing.expectError(ParseError.MalformedFlow, parse(std.testing.allocator,
        \\{ "event": { "type": "OnEvent", "callback": "on_collision_begin" }, "nodes": [], "edges": [] }
    ));
    // `name` plus a legacy field.
    try std.testing.expectError(ParseError.MalformedFlow, parse(std.testing.allocator,
        \\{ "event": { "type": "OnEvent", "name": "box2d.collision_begin", "module": "box2d" }, "nodes": [], "edges": [] }
    ));
}

test "Emit node parses and round-trips" {
    const src =
        \\{
        \\  "event": { "type": "OnUpdate" },
        \\  "nodes": [
        \\    { "id": 1, "type": "Emit", "event": "my_game.player_attacked", "pos": [400, 200] }
        \\  ],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqual(NodeKind.emit, doc.nodes[0].kind);
    try std.testing.expectEqualStrings("my_game.player_attacked", doc.nodes[0].event_ref);

    const text1 = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text1);
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"type\": \"Emit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"event\": \"my_game.player_attacked\"") != null);
}

test "Emit rejects a non-string event field" {
    try std.testing.expectError(ParseError.BadSchema, parse(std.testing.allocator,
        \\{ "event": { "type": "OnUpdate" }, "nodes": [ { "id": 1, "type": "Emit", "event": 9 } ], "edges": [] }
    ));
}

test "legacy_onevent_to_name converts the canonical mapping" {
    const src =
        \\{
        \\  "event": { "type": "OnEvent", "module": "box2d", "callback": "on_collision_begin" },
        \\  "nodes": [],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try legacy_onevent_to_name(doc.allocator(), &doc.event);
    try std.testing.expectEqualStrings("box2d.collision_begin", doc.event.name.?);
    try std.testing.expect(doc.event.module == null);
    try std.testing.expect(doc.event.callback == null);
    try std.testing.expectEqual(@as(usize, 0), doc.event.params.len);
}

test "legacy_onevent_to_name passes a non-on_-prefixed callback through" {
    const src =
        \\{
        \\  "event": { "type": "OnEvent", "module": "physics", "callback": "explode" },
        \\  "nodes": [],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();
    try legacy_onevent_to_name(doc.allocator(), &doc.event);
    try std.testing.expectEqualStrings("physics.explode", doc.event.name.?);
}

test "legacy_onevent_to_name rejects already-new and non-OnEvent" {
    {
        const src =
            \\{ "event": { "type": "OnEvent", "name": "box2d.collision_begin" }, "nodes": [], "edges": [] }
        ;
        var doc = try parse(std.testing.allocator, src);
        defer doc.deinit();
        try std.testing.expectError(ConvertError.AlreadyNewForm, legacy_onevent_to_name(doc.allocator(), &doc.event));
    }
    {
        const src =
            \\{ "event": { "type": "OnCreate", "arg_entity": "entity" }, "nodes": [], "edges": [] }
        ;
        var doc = try parse(std.testing.allocator, src);
        defer doc.deinit();
        try std.testing.expectError(ConvertError.NotOnEvent, legacy_onevent_to_name(doc.allocator(), &doc.event));
    }
}

test "binding order is deterministic after an edit reorders the slice" {
    const src =
        \\{
        \\  "nodes": [
        \\    { "id": 1, "type": "Subflow", "flow": "f",
        \\      "bindings": { "a": 1, "b": 2 }, "pos": [0, 0] }
        \\  ],
        \\  "edges": []
        \\}
    ;
    var doc = try parse(std.testing.allocator, src);
    defer doc.deinit();

    // Simulate an editor edit that leaves the slice out of sorted order.
    try std.testing.expectEqual(@as(usize, 2), doc.nodes[0].bindings.len);
    std.mem.swap(Binding, &doc.nodes[0].bindings[0], &doc.nodes[0].bindings[1]);

    // The writer must still emit a sorted, idempotent result.
    const text1 = try render(std.testing.allocator, doc);
    defer std.testing.allocator.free(text1);
    var doc2 = try parse(std.testing.allocator, text1);
    defer doc2.deinit();
    const text2 = try render(std.testing.allocator, doc2);
    defer std.testing.allocator.free(text2);
    try std.testing.expectEqualStrings(text1, text2);
    try std.testing.expect(std.mem.indexOf(u8, text1, "\"a\": 1, \"b\": 2") != null);
}
