//! Catalog of plugin- and game-script-declared FlowNodes the flow
//! editor surfaces in its palette + on `CustomNode` nodes
//! (RFC-FLOW-VOCABULARY §1, §6 — phase 4, GUI #170).
//!
//! ## Why a catalog?
//!
//! The assembler walks every plugin and `scripts/` module at codegen
//! time and emits a `PluginFlowNodes = struct { ... }` block in the
//! generated `game` module — each entry aliases a
//! `core.flow.FlowNode(.{ ... })` factory value with its `impl`
//! function attached. flow-codegen consumes that registry when
//! lowering `CustomNode` nodes to direct calls.
//!
//! The flow editor is a separate tool and does *not* import the game's
//! generated module — doing so would spin up the full assembler. Two
//! data paths feed the palette:
//!
//!   1. **Per-project sidecar** (labelle-assembler#178): the assembler
//!      writes a `flow_catalog.json` next to the generated `main.zig`
//!      every time it regenerates. `App.openProject(dir)` walks
//!      `<dir>/.labelle/*/flow_catalog.json` and loads the file into a
//!      `RuntimeCatalog` via `loadFromSidecar`. The catalog's
//!      `entries` / `pin_styles` slices then point at the loaded
//!      data, so the palette tracks whatever the project's plugins +
//!      `scripts/` contribute — labelle-box2d, future plugins, the
//!      game's own modules, all per-project.
//!   2. **Static fallback** below — `static_entries` /
//!      `static_pin_styles` mirror labelle-box2d's 14 shipped
//!      FlowNodes verbatim. Used when the project hasn't been
//!      regenerated since the sidecar feature landed, or when the
//!      editor opens a project whose `.labelle/` directory was
//!      cleaned. Projects that just ran `labelle generate` /
//!      `labelle build` get the dynamic path; everyone else stays on
//!      the hand-maintained mirror until they regenerate.
//!
//! ## Shape
//!
//! Each `Entry` mirrors one `pub const <name> = core.flow.FlowNode(...)`
//! decl: a dotted `"<module>.<name>"` form (so the on-disk
//! `CustomNode.name` field matches verbatim), the
//! command/reporter `Kind` (rectangular vs rounded visual, RFC §6),
//! an optional docs string for the palette tooltip, and the pin list
//! (label, Zig type name as it appears in source, direction). The
//! editor reads pin types as **bare Zig text** — no parsing — because
//! that is exactly the form the flow file references them in
//! (e.g. `i32`, `f32`, `bool`, `EntityId`).
//!
//! ## Pin styles
//!
//! `pin_styles` maps a Zig type name to the color the editor draws the
//! pin in. The defaults from `labelle-core/src/flow.zig`'s
//! `default_pin_styles` are baked in alongside the box2d-shipped
//! overrides (BodyId, RayResult) so a complete style lookup is
//! available without importing labelle-core at editor build time.

const std = @import("std");

/// Command (rectangular, has execution flow) vs reporter (rounded,
/// data-only). Matches `core.flow.FlowNodeKind`.
pub const Kind = enum { command, reporter };

/// One pin's direction. Plugin FlowNodes have one direction per pin:
/// every parameter (after the implicit `game: anytype`) is an input
/// pin; the return value (if non-void) is the single output pin.
pub const PinDir = enum { input, output };

/// One pin on a catalog entry. Direction + label + Zig type name as it
/// appears in source.
pub const Pin = struct {
    name: []const u8,
    /// Display label — the FlowNode's `PinSpec.label` override, or the
    /// pin name titlecased when null on the source side.
    label: []const u8,
    /// The Zig type name as the plugin source spells it (`i32`, `f32`,
    /// `EntityId`, `BodyId`, …). Used both for the pin's display style
    /// (lookup against `pin_styles`) and for wire-fit type checks.
    type_name: []const u8,
    dir: PinDir,
};

/// One catalog entry — a plugin- or game-script-contributed FlowNode.
pub const Entry = struct {
    /// Dotted form the on-disk `CustomNode.name` field uses
    /// (`"box2d.apply_impulse"`). The assembler emits the qualified
    /// underscore form (`"box2d__apply_impulse"`) on `PluginFlowNodes`;
    /// the editor keeps the dotted form because that's what the user
    /// types.
    name: []const u8,
    /// Palette section label — typically the contributing module name
    /// (`"box2d"`, `"my_game"`). The editor groups palette entries by
    /// this.
    category: []const u8,
    /// Human-readable label for the palette + node body. Defaults to
    /// the bare decl name when the FlowNode declares no `display_name`.
    display_name: []const u8,
    /// Docs (RFC §1 `FlowNode.docs`) — palette tooltip text.
    docs: []const u8 = "",
    /// Command (rectangular, execution-flow pins) vs reporter (rounded,
    /// only data pins). RFC §6.
    kind: Kind,
    /// Pin definitions in display order. Inputs first, output(s) after.
    pins: []const Pin,
    /// Fully-qualified Zig type name this node constructs, or `null`
    /// when it doesn't (RFC-FLOW-VOCABULARY §1, open question O5).
    /// Mirrors `core.flow.FlowNode.constructs`. Used by the palette to
    /// suggest constructor nodes when the user creates a `SetVariable`
    /// on a struct-typed variable (which can't have an inline default
    /// widget per the "structs must be wired" rule).
    constructs: ?[]const u8 = null,
};

/// Per-Zig-type display metadata (color, label). The editor renders a
/// pin in its type's color so the canvas reads at a glance.
pub const PinStyle = struct {
    label: []const u8,
    /// RGB display color the editor draws the pin shape in. 8-bit per
    /// channel; opaque alpha implied.
    color: [3]u8,
};

/// One row of the type-name → style table.
pub const PinStyleEntry = struct {
    type_name: []const u8,
    style: PinStyle,
};

/// Default pin styles — `labelle-core/src/flow.zig`'s `default_pin_styles`
/// (primitives + `EntityId`) plus `labelle-box2d`'s two overrides
/// (`BodyId`, `RayResult`). Later entries win — last write wins —
/// matching the assembler's deduplication rule (RFC §1 contract).
///
/// `pin_styles` (below) is a slice view that points here by default
/// and gets replaced by `setRuntime` when a project's
/// `flow_catalog.json` loads.
const static_pin_styles = [_]PinStyleEntry{
    // ─── Primitives (default_pin_styles) ───
    .{ .type_name = "u32", .style = .{ .label = "Integer", .color = .{ 90, 156, 196 } } },
    .{ .type_name = "i32", .style = .{ .label = "Integer", .color = .{ 90, 156, 196 } } },
    .{ .type_name = "u64", .style = .{ .label = "Integer", .color = .{ 90, 156, 196 } } },
    .{ .type_name = "i64", .style = .{ .label = "Integer", .color = .{ 90, 156, 196 } } },
    .{ .type_name = "f32", .style = .{ .label = "Number", .color = .{ 230, 145, 56 } } },
    .{ .type_name = "f64", .style = .{ .label = "Number", .color = .{ 230, 145, 56 } } },
    .{ .type_name = "bool", .style = .{ .label = "Bool", .color = .{ 106, 168, 79 } } },
    .{ .type_name = "[]const u8", .style = .{ .label = "Text", .color = .{ 142, 124, 195 } } },
    .{ .type_name = "EntityId", .style = .{ .label = "Entity", .color = .{ 241, 194, 50 } } },

    // ─── labelle-box2d overrides (root.zig:252-270) ───
    .{ .type_name = "BodyId", .style = .{ .label = "Body", .color = .{ 80, 200, 200 } } },
    .{ .type_name = "JointId", .style = .{ .label = "Joint", .color = .{ 80, 200, 200 } } },
    .{ .type_name = "RayResult", .style = .{ .label = "Ray Result", .color = .{ 198, 100, 196 } } },
};

/// Lookup a pin style by Zig type name. Returns null when the type
/// isn't styled; the editor renders an unstyled pin in a neutral gray.
pub fn lookupStyle(type_name: []const u8) ?PinStyle {
    // Walk in reverse so "last write wins" — a later entry overrides
    // an earlier one with the same `type_name`.
    var i: usize = pin_styles.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, pin_styles[i].type_name, type_name)) return pin_styles[i].style;
    }
    return null;
}

// ─── Static FlowNode catalog ────────────────────────────────────────────
//
// Mirrors `labelle-box2d/src/root.zig:127-239`'s `pub const FlowNodes`.
// Adding a new plugin FlowNode means adding an entry here until the
// dynamic scan lands.
//
// **First-param convention** (RFC §1): every plugin `impl` takes
// `game: anytype` first — that is the implicit game-pointer the
// flow-codegen lowering threads in. The remaining params are the
// input pins; the return value (when non-void) is the single output
// pin. The catalog table reflects this: the `pins` array lists only
// the user-visible pins.

/// `box2d.apply_impulse` (root.zig:148).
const box2d_apply_impulse_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "ix", .label = "Impulse X", .type_name = "f32", .dir = .input },
    .{ .name = "iy", .label = "Impulse Y", .type_name = "f32", .dir = .input },
};

/// `box2d.apply_force` (root.zig:157).
const box2d_apply_force_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "fx", .label = "Force X", .type_name = "f32", .dir = .input },
    .{ .name = "fy", .label = "Force Y", .type_name = "f32", .dir = .input },
};

/// `box2d.apply_torque` (root.zig:166).
const box2d_apply_torque_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "torque", .label = "Torque", .type_name = "f32", .dir = .input },
};

/// `box2d.set_velocity` (root.zig:171).
const box2d_set_velocity_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "vx", .label = "Velocity X", .type_name = "f32", .dir = .input },
    .{ .name = "vy", .label = "Velocity Y", .type_name = "f32", .dir = .input },
};

/// `box2d.get_velocity` (root.zig:180) — reporter returning a 2D vector.
const box2d_get_velocity_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "x", .label = "X", .type_name = "f32", .dir = .output },
    .{ .name = "y", .label = "Y", .type_name = "f32", .dir = .output },
};

/// `box2d.get_angular_velocity` (root.zig:185).
const box2d_get_angular_velocity_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "value", .label = "Angular Velocity", .type_name = "f32", .dir = .output },
};

/// `box2d.get_position` (root.zig:190).
const box2d_get_position_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "x", .label = "X", .type_name = "f32", .dir = .output },
    .{ .name = "y", .label = "Y", .type_name = "f32", .dir = .output },
};

/// `box2d.set_position` (root.zig:195).
const box2d_set_position_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "x", .label = "X", .type_name = "f32", .dir = .input },
    .{ .name = "y", .label = "Y", .type_name = "f32", .dir = .input },
};

/// `box2d.get_angle` (root.zig:200).
const box2d_get_angle_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "value", .label = "Angle", .type_name = "f32", .dir = .output },
};

/// `box2d.set_angle` (root.zig:205).
const box2d_set_angle_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "angle", .label = "Angle", .type_name = "f32", .dir = .input },
};

/// `box2d.get_mass` (root.zig:210).
const box2d_get_mass_pins = [_]Pin{
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .input },
    .{ .name = "value", .label = "Mass", .type_name = "f32", .dir = .output },
};

/// `box2d.ray_cast` (root.zig:215).
const box2d_ray_cast_pins = [_]Pin{
    .{ .name = "origin_x", .label = "Origin X", .type_name = "f32", .dir = .input },
    .{ .name = "origin_y", .label = "Origin Y", .type_name = "f32", .dir = .input },
    .{ .name = "target_x", .label = "Target X", .type_name = "f32", .dir = .input },
    .{ .name = "target_y", .label = "Target Y", .type_name = "f32", .dir = .input },
    .{ .name = "result", .label = "Result", .type_name = "RayResult", .dir = .output },
};

/// `box2d.body_at` (root.zig:226).
const box2d_body_at_pins = [_]Pin{
    .{ .name = "x", .label = "X", .type_name = "f32", .dir = .input },
    .{ .name = "y", .label = "Y", .type_name = "f32", .dir = .input },
    .{ .name = "entity", .label = "Entity", .type_name = "EntityId", .dir = .output },
};

/// `box2d.set_gravity` (root.zig:231).
const box2d_set_gravity_pins = [_]Pin{
    .{ .name = "gx", .label = "Gravity X", .type_name = "f32", .dir = .input },
    .{ .name = "gy", .label = "Gravity Y", .type_name = "f32", .dir = .input },
};

/// Static FlowNode catalog — used as the fallback when no
/// `flow_catalog.json` sidecar is loaded. `entries` (below) is a slice
/// view that points at this array by default and gets swapped to the
/// sidecar's owned slice by `setRuntime` when a project opens.
///
/// Mirrors `labelle-box2d/src/root.zig:127-239`'s `pub const FlowNodes`.
/// Adding a new plugin FlowNode here is now optional — projects that
/// have regenerated since labelle-assembler#178 landed surface every
/// plugin / script FlowNode via the dynamic catalog. Keeping the
/// static list in sync is only required for the "no sidecar" path
/// (older projects, fresh checkouts before `labelle generate`).
const static_entries = [_]Entry{
    .{
        .name = "box2d.apply_impulse",
        .category = "box2d",
        .display_name = "Apply Impulse",
        .docs = "Apply a linear impulse to the body's center of mass (pixels/s).",
        .kind = .command,
        .pins = &box2d_apply_impulse_pins,
    },
    .{
        .name = "box2d.apply_force",
        .category = "box2d",
        .display_name = "Apply Force",
        .docs = "Apply a force to the body's center of mass (pixels/s²).",
        .kind = .command,
        .pins = &box2d_apply_force_pins,
    },
    .{
        .name = "box2d.apply_torque",
        .category = "box2d",
        .display_name = "Apply Torque",
        .docs = "Apply a rotational torque to the body.",
        .kind = .command,
        .pins = &box2d_apply_torque_pins,
    },
    .{
        .name = "box2d.set_velocity",
        .category = "box2d",
        .display_name = "Set Velocity",
        .docs = "Set the body's linear velocity directly (pixels/s).",
        .kind = .command,
        .pins = &box2d_set_velocity_pins,
    },
    .{
        .name = "box2d.get_velocity",
        .category = "box2d",
        .display_name = "Get Velocity",
        .docs = "Read the body's linear velocity (pixels/s).",
        .kind = .reporter,
        .pins = &box2d_get_velocity_pins,
    },
    .{
        .name = "box2d.get_angular_velocity",
        .category = "box2d",
        .display_name = "Get Angular Velocity",
        .docs = "Read the body's angular velocity (radians/s).",
        .kind = .reporter,
        .pins = &box2d_get_angular_velocity_pins,
    },
    .{
        .name = "box2d.get_position",
        .category = "box2d",
        .display_name = "Get Position",
        .docs = "Read the entity's world-space position (pixels).",
        .kind = .reporter,
        .pins = &box2d_get_position_pins,
    },
    .{
        .name = "box2d.set_position",
        .category = "box2d",
        .display_name = "Set Position",
        .docs = "Teleport the body to a new world-space position (pixels).",
        .kind = .command,
        .pins = &box2d_set_position_pins,
    },
    .{
        .name = "box2d.get_angle",
        .category = "box2d",
        .display_name = "Get Angle",
        .docs = "Read the body's rotation angle (radians).",
        .kind = .reporter,
        .pins = &box2d_get_angle_pins,
    },
    .{
        .name = "box2d.set_angle",
        .category = "box2d",
        .display_name = "Set Angle",
        .docs = "Set the body's rotation angle (radians).",
        .kind = .command,
        .pins = &box2d_set_angle_pins,
    },
    .{
        .name = "box2d.get_mass",
        .category = "box2d",
        .display_name = "Get Mass",
        .docs = "Read the body's mass (kg).",
        .kind = .reporter,
        .pins = &box2d_get_mass_pins,
    },
    .{
        .name = "box2d.ray_cast",
        .category = "box2d",
        .display_name = "Ray Cast",
        .docs = "Cast a ray from origin to target (pixels). Returns the closest hit.",
        .kind = .reporter,
        .pins = &box2d_ray_cast_pins,
        // RFC-FLOW-VOCABULARY §1 / O5 — `ray_cast` returns a `RayResult`
        // struct. Editor uses this to suggest the node from the palette
        // when the user creates a `SetVariable` on a `RayResult`-typed
        // variable. TODO(O5 follow-up): the palette suggestion UX itself
        // is a phase-4 polish item — for v1 we just thread this through
        // and surface it via `lookup(...).constructs`.
        .constructs = "labelle_box2d.RayResult",
    },
    .{
        .name = "box2d.body_at",
        .category = "box2d",
        .display_name = "Body At",
        .docs = "Return the entity whose body contains the given world-space point, or 0 if none.",
        .kind = .reporter,
        .pins = &box2d_body_at_pins,
    },
    .{
        .name = "box2d.set_gravity",
        .category = "box2d",
        .display_name = "Set Gravity",
        .docs = "Set world gravity (pixels/s²).",
        .kind = .command,
        .pins = &box2d_set_gravity_pins,
    },
};

/// Lookup a catalog entry by its dotted name. Returns null when the
/// name isn't a known FlowNode — the editor surfaces that as a hint;
/// codegen rejects it at build time against the merged
/// `PluginFlowNodes` registry.
pub fn lookup(name: []const u8) ?*const Entry {
    for (&entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// True when `name` matches some catalog entry. Sugar for callers that
/// only want a yes/no.
pub fn isKnown(name: []const u8) bool {
    return lookup(name) != null;
}

// ─── Wire-fit type check (RFC §2, open question O1 resolved) ────────────
//
// Editor-side type compatibility check the canvas runs on every wire
// drop. Equality always fits. Numeric widening fits in the safe
// direction. Otherwise the drop is refused.
//
// **Auto-accepted** (mirrors `labelle-core/src/flow.zig:numericFits` —
// the codegen-side source of truth):
// - Same-sign integer widening (`i8 → i16 → i32 → i64 → i128`,
//   `u8 → u16 → u32 → u64 → u128`).
// - Unsigned → strictly-larger signed (`u8 → i16/i32/i64/i128`, …).
// - Float widening (`f32 → f64`).
//
// **Explicitly refused** (require an explicit conversion node):
// - Int ↔ float in either direction (lossy / surprising).
// - Signed → unsigned (sign loss).
// - Narrowing in either direction.
//
// Aliases (`EntityId == u32`) collapse via Zig type equality at codegen
// time. The editor mirrors the convention with explicit `EntityId ↔ u32`
// pairs so a wire from a `u32` literal into an `EntityId` pin (or the
// reverse) reads the same way to the canvas as it does to codegen.

/// Classify a primitive Zig type name into a `(kind, bits)` tuple.
/// Returns `null` for anything that isn't one of the auto-accepted
/// primitive families — strings, structs, plugin nominal types
/// (`BodyId`, `RayResult`, …) all return `null` so they fall through
/// to the equality-only path in `typesFit`. `EntityId` is collapsed
/// to `u32` per the toolkit's convention (`labelle-core` aliases
/// `pub const EntityId = u32`).
const NumericKind = enum { signed_int, unsigned_int, float };
const NumericInfo = struct { kind: NumericKind, bits: u16 };

fn parsePrimitive(type_name: []const u8) ?NumericInfo {
    // `EntityId` collapses to `u32` — same convention codegen uses.
    if (std.mem.eql(u8, type_name, "EntityId")) {
        return .{ .kind = .unsigned_int, .bits = 32 };
    }
    if (type_name.len < 2) return null;
    const first = type_name[0];
    const kind: NumericKind = switch (first) {
        'i' => .signed_int,
        'u' => .unsigned_int,
        'f' => .float,
        else => return null,
    };
    const bits = std.fmt.parseInt(u16, type_name[1..], 10) catch return null;
    // Sanity-bound the bit width to the Zig 0.16 supported set so a
    // bogus `i7` from a typo doesn't silently fit `i8`. Auto-accepted
    // widths are 8/16/32/64/128 for ints and 16/32/64/80/128 for floats.
    switch (kind) {
        .signed_int, .unsigned_int => switch (bits) {
            8, 16, 32, 64, 128 => return .{ .kind = kind, .bits = bits },
            else => return null,
        },
        .float => switch (bits) {
            16, 32, 64, 80, 128 => return .{ .kind = .float, .bits = bits },
            else => return null,
        },
    }
}

/// True when a value of `from_type` can be wired into an input pin of
/// `to_type` per the editor's wire-fit rule. Equality plus the
/// `numericFits` (RFC §2 / O1) widening set; everything else is refused.
pub fn typesFit(from_type: []const u8, to_type: []const u8) bool {
    if (std.mem.eql(u8, from_type, to_type)) return true;

    // `EntityId` is an alias for `u32`; the canonical equality check in
    // codegen collapses them via Zig type identity. Mirror it here.
    const f_norm = if (std.mem.eql(u8, from_type, "EntityId")) "u32" else from_type;
    const t_norm = if (std.mem.eql(u8, to_type, "EntityId")) "u32" else to_type;
    if (std.mem.eql(u8, f_norm, t_norm)) return true;

    const f = parsePrimitive(from_type) orelse return false;
    const t = parsePrimitive(to_type) orelse return false;

    // Mirror of `labelle-core/src/flow.zig:numericFits`. Keep both
    // implementations in lock-step — the catalog can't import core
    // (the editor doesn't pull in the assembled game's deps), so the
    // contract is documented + tested on both sides.
    if (f.kind == .signed_int and t.kind == .signed_int) return t.bits >= f.bits;
    if (f.kind == .unsigned_int and t.kind == .unsigned_int) return t.bits >= f.bits;
    if (f.kind == .unsigned_int and t.kind == .signed_int) return t.bits > f.bits;
    // Signed → unsigned: sign loss. Int ↔ float: lossy/surprising.
    if (f.kind == .signed_int and t.kind == .unsigned_int) return false;
    if (f.kind == .float and t.kind == .float) return t.bits >= f.bits;
    return false; // int <-> float
}

// ─── Tests ──────────────────────────────────────────────────────────────

test "catalog covers every shipped box2d FlowNode" {
    // Mirror of `labelle-box2d/src/root.zig:147-239`'s `pub const FlowNodes`.
    // Adding a new decl there means adding an entry here until the
    // assembler-emitted sidecar replaces this hand-written list.
    const expected = [_][]const u8{
        "box2d.apply_impulse",
        "box2d.apply_force",
        "box2d.apply_torque",
        "box2d.set_velocity",
        "box2d.get_velocity",
        "box2d.get_angular_velocity",
        "box2d.get_position",
        "box2d.set_position",
        "box2d.get_angle",
        "box2d.set_angle",
        "box2d.get_mass",
        "box2d.ray_cast",
        "box2d.body_at",
        "box2d.set_gravity",
    };
    for (expected) |name| {
        try std.testing.expect(isKnown(name));
    }
    // Spot-check the 14-count is exactly what the plugin ships.
    try std.testing.expectEqual(@as(usize, 14), entries.len);
}

test "lookup misses an unknown name" {
    try std.testing.expect(lookup("never.heard.of.it") == null);
    try std.testing.expect(!isKnown("never.heard.of.it"));
}

test "command vs reporter classification" {
    // `set_velocity` writes — command.
    try std.testing.expectEqual(Kind.command, lookup("box2d.set_velocity").?.kind);
    // `get_position` reads — reporter.
    try std.testing.expectEqual(Kind.reporter, lookup("box2d.get_position").?.kind);
    // `ray_cast` returns a value — reporter.
    try std.testing.expectEqual(Kind.reporter, lookup("box2d.ray_cast").?.kind);
}

test "pin styles cover primitives and box2d types" {
    // Default integer style — teal-blue.
    const i32_style = lookupStyle("i32").?;
    try std.testing.expectEqualStrings("Integer", i32_style.label);
    // Float style — orange.
    const f32_style = lookupStyle("f32").?;
    try std.testing.expectEqualStrings("Number", f32_style.label);
    // box2d override — Joint cyan.
    const joint = lookupStyle("JointId").?;
    try std.testing.expectEqualStrings("Joint", joint.label);
    // Unknown type — null (editor renders neutral).
    try std.testing.expect(lookupStyle("SomeUnknownType") == null);
}

test "wire-fit: equality always fits (RFC §2 rule 1)" {
    try std.testing.expect(typesFit("i32", "i32"));
    try std.testing.expect(typesFit("f32", "f32"));
    try std.testing.expect(typesFit("bool", "bool"));
    try std.testing.expect(typesFit("EntityId", "EntityId"));
    try std.testing.expect(typesFit("BodyId", "BodyId"));
    try std.testing.expect(typesFit("RayResult", "RayResult"));
}

test "wire-fit: same-sign integer widening accepted (O1)" {
    // Mirror of labelle-core/numericFits — keep these tests in sync
    // with `test/root_test.zig`'s "numericFits: same-sign integer
    // widening accepted" block.
    try std.testing.expect(typesFit("i8", "i16"));
    try std.testing.expect(typesFit("i8", "i32"));
    try std.testing.expect(typesFit("i16", "i32"));
    try std.testing.expect(typesFit("i32", "i64"));
    try std.testing.expect(typesFit("i64", "i128"));

    try std.testing.expect(typesFit("u8", "u16"));
    try std.testing.expect(typesFit("u8", "u32"));
    try std.testing.expect(typesFit("u16", "u32"));
    try std.testing.expect(typesFit("u32", "u64"));
    try std.testing.expect(typesFit("u64", "u128"));
}

test "wire-fit: unsigned to strictly-larger signed accepted (O1)" {
    try std.testing.expect(typesFit("u8", "i16"));
    try std.testing.expect(typesFit("u8", "i32"));
    try std.testing.expect(typesFit("u16", "i32"));
    try std.testing.expect(typesFit("u32", "i64"));
    try std.testing.expect(typesFit("u32", "i128"));
    try std.testing.expect(typesFit("u64", "i128"));
}

test "wire-fit: unsigned to equal-or-smaller signed refused (O1)" {
    // Equal-width unsigned → signed loses the high bit.
    try std.testing.expect(!typesFit("u8", "i8"));
    try std.testing.expect(!typesFit("u32", "i32"));
    try std.testing.expect(!typesFit("u32", "i16"));
}

test "wire-fit: signed to unsigned refused (sign loss, O1)" {
    try std.testing.expect(!typesFit("i8", "u8"));
    try std.testing.expect(!typesFit("i32", "u32"));
    try std.testing.expect(!typesFit("i32", "u64"));
}

test "wire-fit: float widening accepted, narrowing refused (O1)" {
    try std.testing.expect(typesFit("f32", "f64"));
    try std.testing.expect(!typesFit("f64", "f32"));
}

test "wire-fit: int <-> float refused in both directions (O1)" {
    // Int → float: lossy for large ints.
    try std.testing.expect(!typesFit("i32", "f32"));
    try std.testing.expect(!typesFit("i32", "f64"));
    try std.testing.expect(!typesFit("u32", "f32"));
    try std.testing.expect(!typesFit("u32", "f64"));
    try std.testing.expect(!typesFit("u64", "f64"));
    // Float → int: truncation surprises.
    try std.testing.expect(!typesFit("f32", "i32"));
    try std.testing.expect(!typesFit("f64", "i64"));
}

test "wire-fit: integer narrowing refused (O1)" {
    try std.testing.expect(!typesFit("i64", "i32"));
    try std.testing.expect(!typesFit("u64", "u32"));
}

test "wire-fit: EntityId aliases u32 per toolkit convention" {
    try std.testing.expect(typesFit("EntityId", "u32"));
    try std.testing.expect(typesFit("u32", "EntityId"));
    // EntityId widens to u64 the same way u32 does.
    try std.testing.expect(typesFit("EntityId", "u64"));
    // EntityId → i64 (u32 → i64 widens cleanly).
    try std.testing.expect(typesFit("EntityId", "i64"));
    // EntityId → i32: same as u32 → i32, sign-bit collision — refused
    // (this is a tightening from the pre-O1 catalog, which accepted it).
    try std.testing.expect(!typesFit("EntityId", "i32"));
}

test "wire-fit: distinct nominal types refused" {
    try std.testing.expect(!typesFit("BodyId", "EntityId"));
    try std.testing.expect(!typesFit("RayResult", "f32"));
    try std.testing.expect(!typesFit("BodyId", "u32"));
}

test "constructs hint: ray_cast reports its return type (O5)" {
    // RFC-FLOW-VOCABULARY §1 / O5 — the editor consults `constructs` to
    // know which palette entries return a value of a given type, so a
    // `SetVariable` on a struct-typed variable can suggest matching
    // constructor nodes. `ray_cast` is the only constructor in the
    // shipped box2d set; the rest are commands or scalar reporters.
    const ray_cast = lookup("box2d.ray_cast").?;
    try std.testing.expect(ray_cast.constructs != null);
    try std.testing.expectEqualStrings("labelle_box2d.RayResult", ray_cast.constructs.?);

    // Spot-check that non-constructor entries leave `constructs` null
    // so the palette suggestion code knows to skip them. A SetVariable
    // on a `RayResult` var would suggest `ray_cast`, not `set_velocity`.
    try std.testing.expect(lookup("box2d.set_velocity").?.constructs == null);
    try std.testing.expect(lookup("box2d.apply_impulse").?.constructs == null);
    try std.testing.expect(lookup("box2d.get_position").?.constructs == null);
}

test "every catalog entry's pins include at least one user-visible pin" {
    // A FlowNode with no params and no return value would be a strange
    // "fire-and-forget no-op" — guard against accidentally adding one
    // until reflection lands and proves the case is reachable.
    for (&entries) |e| {
        try std.testing.expect(e.pins.len > 0);
    }
}
