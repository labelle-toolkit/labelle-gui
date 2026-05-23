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
//! function attached. flow-codegen will eventually consume that
//! registry when lowering `CustomNode` nodes to direct calls.
//!
//! The flow editor is a separate tool and does *not* import the game's
//! generated module — doing so would spin up the full assembler. So
//! for phase 4 the editor consumes a **hard-coded static table**
//! mirroring `labelle-box2d`'s 14 shipped FlowNodes plus the two pin
//! styles it declares. The assembler-emitted sidecar (a comptime
//! catalog file alongside `game.zig`) is the future option; tracking
//! it is out of scope for this phase. See the TODO below.
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
pub const pin_styles = [_]PinStyleEntry{
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

/// Every FlowNode declared on a plugin's `pub const FlowNodes` block
/// the editor knows about. Update alongside any new plugin ship until
/// the assembler-emitted sidecar replaces this list.
///
/// TODO(O1 follow-up): replace with an assembler-emitted sidecar that
/// dumps the discovered `PluginFlowNodes` registry as a `.zon` file
/// alongside `game.zig`. Tracking issue: `labelle-assembler#178`.
pub const entries = [_]Entry{
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

// ─── Wire-fit type check (RFC §2) ───────────────────────────────────────
//
// Editor-side type compatibility check the canvas runs on every wire
// drop. Equality always fits. Numeric widening fits in the safe
// direction (`i32 → i64`, `f32 → f64`, integer → float of equal-or-greater
// width). Otherwise the drop is refused.
//
// Exhaustive set per RFC open question O1 (deferred). For phase 4 MVP
// this is the safe subset; growing the table doesn't change the
// editor's UX — it only widens what the user can wire.

/// True when a value of `from_type` can be wired into an input pin of
/// `to_type` per the editor's wire-fit rule. Plain equality plus the
/// numeric-widening pairs listed below.
pub fn typesFit(from_type: []const u8, to_type: []const u8) bool {
    if (std.mem.eql(u8, from_type, to_type)) return true;
    // Hand-rolled widening table. Pairs are `(from, to)`.
    const widening = [_][2][]const u8{
        // Integers — widen to the larger same-sign type.
        .{ "i32", "i64" },
        .{ "u32", "u64" },
        // Integer → float: safe at equal or greater width.
        .{ "i32", "f32" },
        .{ "i32", "f64" },
        .{ "i64", "f64" },
        .{ "u32", "f32" },
        .{ "u32", "f64" },
        .{ "u64", "f64" },
        // Float widening.
        .{ "f32", "f64" },
        // `EntityId` is `u32` in the toolkit's convention.
        .{ "EntityId", "u32" },
        .{ "u32", "EntityId" },
        .{ "EntityId", "u64" },
        .{ "EntityId", "f32" },
        .{ "EntityId", "f64" },
    };
    for (widening) |w| {
        if (std.mem.eql(u8, from_type, w[0]) and std.mem.eql(u8, to_type, w[1])) return true;
    }
    return false;
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

test "wire-fit accepts equality + safe widening + refuses incompatibles" {
    // Equality always fits.
    try std.testing.expect(typesFit("i32", "i32"));
    try std.testing.expect(typesFit("f32", "f32"));
    try std.testing.expect(typesFit("EntityId", "EntityId"));
    // Safe widening.
    try std.testing.expect(typesFit("i32", "i64"));
    try std.testing.expect(typesFit("f32", "f64"));
    try std.testing.expect(typesFit("i32", "f64"));
    // EntityId ↔ u32 (toolkit convention).
    try std.testing.expect(typesFit("EntityId", "u32"));
    try std.testing.expect(typesFit("u32", "EntityId"));
    // Narrowing refused.
    try std.testing.expect(!typesFit("i64", "i32"));
    try std.testing.expect(!typesFit("f64", "f32"));
    // Float → int refused (precision loss).
    try std.testing.expect(!typesFit("f32", "i32"));
    // Distinct types refused.
    try std.testing.expect(!typesFit("BodyId", "EntityId"));
    try std.testing.expect(!typesFit("RayResult", "f32"));
}

test "every catalog entry's pins include at least one user-visible pin" {
    // A FlowNode with no params and no return value would be a strange
    // "fire-and-forget no-op" — guard against accidentally adding one
    // until reflection lands and proves the case is reachable.
    for (&entries) |e| {
        try std.testing.expect(e.pins.len > 0);
    }
}
