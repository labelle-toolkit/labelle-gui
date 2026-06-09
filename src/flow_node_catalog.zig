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
const io_global = @import("io_global.zig");

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

// ─── Runtime catalog (labelle-assembler#178 sidecar) ────────────────────
//
// `entries` and `pin_styles` start out as slice views pointing at the
// static arrays above. When `App.openProject(dir)` finds a
// `flow_catalog.json` sidecar, it calls `setRuntime(loaded)` and the
// slices flip to the loaded catalog's owned arrays. Closing a project
// (or opening one without a sidecar) calls `setRuntime(null)` which
// restores the static view. `lookup` / `lookupStyle` / `isKnown` /
// every caller in `flow_doc.zig` reads through these slices, so no
// other call sites need to know whether the active catalog is static
// or dynamic.
//
// Why slice-of-const rather than a tagged union or a separate Module:
// the editor's API surface stays unchanged. `entries.len`,
// `for (entries) |e|`, and `&entries[i]` all keep working — only the
// underlying memory pointer moves. The `pub var` is process-global
// because the editor only has one active project at a time, and
// switching projects is a single-threaded `App.renderFrame` operation
// that's already serialised against everything else.

/// Owned heap-allocated catalog loaded from a project's
/// `flow_catalog.json` sidecar. Owns every string and slice inside;
/// the parent's `setRuntime` swaps it in and tears down the previous
/// one via `freeRuntimeCatalog`.
pub const RuntimeCatalog = struct {
    entries: []Entry,
    pin_styles: []PinStyleEntry,
    arena: std.heap.ArenaAllocator,
    /// Allocator the catalog's outer struct was created with (the
    /// one `loadFromPath` calls `aa.create(RuntimeCatalog)` on).
    /// `setRuntime` uses it to fully reclaim the heap box after the
    /// arena teardown; without it the struct itself leaks.
    box_allocator: std.mem.Allocator,

    pub fn deinit(self: *RuntimeCatalog) void {
        // Arena owns every string + slice inside; one teardown drops them all.
        self.arena.deinit();
        self.entries = &.{};
        self.pin_styles = &.{};
    }
};

/// Slice view the editor reads. Defaults to the static fallback;
/// flipped by `setRuntime` when a sidecar loads.
pub var entries: []const Entry = &static_entries;

/// Slice view the editor reads. Defaults to the static fallback;
/// flipped by `setRuntime` when a sidecar loads.
pub var pin_styles: []const PinStyleEntry = &static_pin_styles;

/// The currently-active runtime catalog (when non-null). Held here so
/// `setRuntime(null)` can free the prior one before installing a new
/// one or reverting to the static view. The App holds the
/// `RuntimeCatalog` itself; this pointer is just for ownership-aware
/// teardown on the next swap.
var current_runtime: ?*RuntimeCatalog = null;

/// Install a runtime catalog. Pass `null` to revert to the static
/// fallback (e.g. on project close). Frees the previously-active
/// runtime catalog (if any) before installing the new one — the
/// caller hands off ownership.
///
/// Safety: `cat`'s `entries` / `pin_styles` must outlive any pointer
/// returned by `lookup` / `lookupStyle`. Because the editor calls
/// `lookup` per-frame and `setRuntime` only fires on project
/// transitions (already a "close all tabs" boundary), pointer
/// invalidation is naturally bounded.
pub fn setRuntime(cat: ?*RuntimeCatalog) void {
    if (current_runtime) |old| {
        // The arena inside `old.deinit` owns every string + slice it
        // returned through the view; once we tear it down, the
        // `entries` / `pin_styles` slices below MUST point at fresh
        // memory before any caller reads them again. The outer
        // struct's box is freed via the saved `box_allocator`.
        const ba = old.box_allocator;
        old.deinit();
        ba.destroy(old);
    }
    if (cat) |c| {
        entries = c.entries;
        pin_styles = c.pin_styles;
        current_runtime = c;
    } else {
        entries = &static_entries;
        pin_styles = &static_pin_styles;
        current_runtime = null;
    }
}

/// Read `<project_dir>/.labelle/flow_catalog.json` and build a
/// `RuntimeCatalog` from it. Returns `null` when no sidecar is found,
/// leaving the editor on its static fallback.
///
/// The sidecar is **project-level** (one file per project, not one per
/// render-target backend) because a flow's catalog — plugin verbs,
/// events, pin types — is backend-independent. Every backend's
/// generated build sees the same FlowNodes declarations.
///
/// Caller owns the returned pointer — the typical lifecycle is:
/// `setRuntime(loadFromSidecar(allocator, dir) catch null)`.
///
/// Logging: on success, prints a single info line to stderr counting
/// the loaded entries — the verification path the editor uses to
/// confirm the sidecar loaded without needing visual inspection of
/// the palette.
pub fn loadFromSidecar(allocator: std.mem.Allocator, project_dir: []const u8) !?*RuntimeCatalog {
    const path = (try findSidecarPath(allocator, project_dir)) orelse return null;
    defer allocator.free(path);
    return try loadFromPath(allocator, path);
}

/// Load a sidecar from an explicit path. Exposed primarily for tests —
/// `loadFromSidecar` is the right entry point for production code.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !*RuntimeCatalog {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), path, aa, .limited(16 * 1024 * 1024));

    var parsed = try std.json.parseFromSlice(std.json.Value, aa, bytes, .{});
    defer parsed.deinit();

    var entries_list: std.ArrayList(Entry) = .empty;
    var styles_list: std.ArrayList(PinStyleEntry) = .empty;

    const root = switch (parsed.value) {
        .object => |obj| obj,
        else => return error.InvalidSidecar,
    };
    const plugins = if (root.get("plugins")) |p| switch (p) {
        .array => |a| a,
        else => return error.InvalidSidecar,
    } else return error.InvalidSidecar;

    for (plugins.items) |plugin_val| {
        const plugin = switch (plugin_val) {
            .object => |obj| obj,
            else => continue,
        };
        if (plugin.get("flow_nodes")) |fns_val| {
            if (fns_val == .array) {
                for (fns_val.array.items) |node_val| {
                    const entry = parseFlowNode(aa, node_val) catch continue;
                    try entries_list.append(aa, entry);
                }
            }
        }
        if (plugin.get("pin_styles")) |ps_val| {
            if (ps_val == .array) {
                for (ps_val.array.items) |style_val| {
                    const style = parsePinStyle(aa, style_val) catch continue;
                    try styles_list.append(aa, style);
                }
            }
        }
    }

    // Layer the loaded pin styles on top of the static defaults so a
    // sidecar that only ships plugin-specific styles (e.g. just
    // BodyId / RayResult) still gets primitives styled. Static entries
    // come first; loaded entries come last so `lookupStyle`'s
    // last-write-wins reverse walk picks them up first.
    var merged_styles: std.ArrayList(PinStyleEntry) = .empty;
    for (static_pin_styles) |s| try merged_styles.append(aa, s);
    for (styles_list.items) |s| try merged_styles.append(aa, s);

    // Materialize the owned slices BEFORE allocating the outer struct
    // so an OOM mid-finalize cleans up via the arena `errdefer` without
    // ever leaving a heap-allocated `cat` box outstanding. The earlier
    // ordering sat `try ...toOwnedSlice(aa)` inside the struct literal
    // *after* `allocator.create(RuntimeCatalog)`, which would leak the
    // freshly-created `RuntimeCatalog` if the slice call failed (the
    // arena `errdefer` correctly freed the arena memory, but the
    // outer box wasn't tracked). The arena's `remap` path means
    // current `toOwnedSlice` calls don't trip a fresh allocation —
    // they shrink in place — so the leak window is currently
    // unreachable from the standard `loadFromPath` driver; this
    // ordering keeps it unreachable even if the allocator (or
    // ArrayList growth strategy) changes.
    const owned_entries = try entries_list.toOwnedSlice(aa);
    const owned_styles = try merged_styles.toOwnedSlice(aa);

    const cat = try allocator.create(RuntimeCatalog);
    cat.* = .{
        .entries = owned_entries,
        .pin_styles = owned_styles,
        .arena = arena,
        .box_allocator = allocator,
    };

    std.log.info("flow_node_catalog: loaded {d} entries from {s}", .{ cat.entries.len, path });
    return cat;
}

/// Resolve `<project_dir>/.labelle/flow_catalog.json` if it exists.
/// Returns `null` when no sidecar is present — `App` treats that as
/// "stay on the static fallback."
///
/// The sidecar's project-level location is deliberate (was previously
/// `<project>/.labelle/<backend>/flow_catalog.json`, which forced the
/// editor to pick a backend it had no business knowing about — flows
/// are backend-independent).
fn findSidecarPath(allocator: std.mem.Allocator, project_dir: []const u8) !?[]u8 {
    const candidate = try std.fs.path.join(allocator, &.{ project_dir, ".labelle", "flow_catalog.json" });
    std.Io.Dir.cwd().access(io_global.io(), candidate, .{}) catch {
        allocator.free(candidate);
        return null;
    };
    return candidate;
}

fn parseFlowNode(aa: std.mem.Allocator, val: std.json.Value) !Entry {
    const obj = switch (val) {
        .object => |o| o,
        else => return error.InvalidEntry,
    };
    const qualified = (obj.get("qualified") orelse return error.InvalidEntry).string;
    const display_name = (obj.get("display_name") orelse return error.InvalidEntry).string;
    const category = (obj.get("category") orelse return error.InvalidEntry).string;
    const docs = if (obj.get("docs")) |d| switch (d) {
        .string => |s| s,
        else => "",
    } else "";
    const kind_str = (obj.get("kind") orelse return error.InvalidEntry).string;
    const kind: Kind = if (std.mem.eql(u8, kind_str, "reporter")) .reporter else .command;

    var pins: std.ArrayList(Pin) = .empty;
    if (obj.get("pins")) |pins_val| {
        if (pins_val == .array) {
            for (pins_val.array.items) |p_val| {
                const p = switch (p_val) {
                    .object => |o| o,
                    else => continue,
                };
                const name = (p.get("name") orelse continue).string;
                const label = (p.get("label") orelse continue).string;
                const zig_type = (p.get("zig_type") orelse continue).string;
                const dir_str = (p.get("dir") orelse continue).string;
                const dir: PinDir = if (std.mem.eql(u8, dir_str, "output")) .output else .input;
                try pins.append(aa, .{
                    .name = try aa.dupe(u8, name),
                    .label = try aa.dupe(u8, label),
                    .type_name = try aa.dupe(u8, zig_type),
                    .dir = dir,
                });
            }
        }
    }

    // Pass through O5's `constructs` hint when present. The sidecar
    // doesn't emit it yet (sibling agent's work) — when it does, we
    // pick it up; until then, the field stays null and the palette
    // suggestion code falls back to the static catalog's hand-coded
    // values for box2d.
    var constructs_val: ?[]const u8 = null;
    if (obj.get("return_type")) |rt| {
        // The current sidecar emits `return_type` but not `constructs`.
        // For reporters whose return type is a nominal (non-primitive)
        // type, we treat that return type AS the `constructs` value —
        // it's the right semantic: the node returns a value of that
        // type, which is what `constructs` means per RFC §1 / O5.
        switch (rt) {
            .string => |s| {
                if (isLikelyStructName(s)) {
                    constructs_val = try aa.dupe(u8, s);
                }
            },
            else => {},
        }
    }
    if (obj.get("constructs")) |c| {
        switch (c) {
            .string => |s| constructs_val = try aa.dupe(u8, s),
            else => {},
        }
    }

    return .{
        .name = try aa.dupe(u8, qualified),
        .category = try aa.dupe(u8, category),
        .display_name = try aa.dupe(u8, display_name),
        .docs = try aa.dupe(u8, docs),
        .kind = kind,
        .pins = try pins.toOwnedSlice(aa),
        .constructs = constructs_val,
    };
}

fn parsePinStyle(aa: std.mem.Allocator, val: std.json.Value) !PinStyleEntry {
    const obj = switch (val) {
        .object => |o| o,
        else => return error.InvalidPinStyle,
    };
    const zig_type = (obj.get("zig_type") orelse return error.InvalidPinStyle).string;
    const label = (obj.get("label") orelse return error.InvalidPinStyle).string;
    const color_val = obj.get("color") orelse return error.InvalidPinStyle;
    if (color_val != .array) return error.InvalidPinStyle;
    if (color_val.array.items.len < 3) return error.InvalidPinStyle;
    const r = parseU8FromJson(color_val.array.items[0]);
    const g = parseU8FromJson(color_val.array.items[1]);
    const b = parseU8FromJson(color_val.array.items[2]);
    return .{
        .type_name = try aa.dupe(u8, zig_type),
        .style = .{
            .label = try aa.dupe(u8, label),
            .color = .{ r, g, b },
        },
    };
}

fn parseU8FromJson(v: std.json.Value) u8 {
    return switch (v) {
        .integer => |i| @intCast(@as(i64, @intCast(std.math.clamp(i, 0, 255)))),
        .float => |f| @intFromFloat(std.math.clamp(f, 0, 255)),
        else => 0,
    };
}

/// Heuristic: a type name that doesn't look like a Zig primitive is
/// likely a struct or nominal type that flows would constructor-node
/// into. Used to infer `Entry.constructs` from `return_type` until the
/// sibling agent's `.constructs` extraction lands in the sidecar.
fn isLikelyStructName(name: []const u8) bool {
    if (name.len == 0) return false;
    const c = name[0];
    // Primitive families start with `i`/`u`/`f` + digits, or are one
    // of `bool`/`void` literally.
    if (std.mem.eql(u8, name, "bool")) return false;
    if (std.mem.eql(u8, name, "void")) return false;
    if (std.mem.eql(u8, name, "EntityId")) return false; // aliases u32
    if (std.mem.eql(u8, name, "[]const u8")) return false;
    if (c == 'i' or c == 'u' or c == 'f') {
        // Check if the rest is all digits — `i32`, `u64`, `f32`.
        const rest = name[1..];
        if (rest.len == 0) return true; // bare 'i'/'u'/'f' — uncommon, treat as struct
        var all_digits = true;
        for (rest) |ch| {
            if (ch < '0' or ch > '9') {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return false;
    }
    // Capitalised first letter → almost certainly a struct.
    if (c >= 'A' and c <= 'Z') return true;
    return true;
}

/// Lookup a catalog entry by its dotted name. Returns null when the
/// name isn't a known FlowNode — the editor surfaces that as a hint;
/// codegen rejects it at build time against the merged
/// `PluginFlowNodes` registry.
pub fn lookup(name: []const u8) ?*const Entry {
    for (entries) |*e| {
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
    for (entries) |e| {
        try std.testing.expect(e.pins.len > 0);
    }
}

// ─── Sidecar loader tests ───────────────────────────────────────────────

test "loadFromPath: parses a synthetic flow_catalog.json into the in-memory shape" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json =
        \\{
        \\  "generated_at": "2026-05-23T16:42:11Z",
        \\  "plugins": [
        \\    {
        \\      "name": "synthetic",
        \\      "flow_nodes": [
        \\        {
        \\          "qualified": "synthetic.do_thing",
        \\          "display_name": "Do Thing",
        \\          "category": "synthetic",
        \\          "docs": "Sample command.",
        \\          "kind": "command",
        \\          "pins": [
        \\            { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input", "default": null },
        \\            { "name": "value", "label": "Value", "zig_type": "f32", "dir": "input", "default": null }
        \\          ],
        \\          "return_type": null
        \\        },
        \\        {
        \\          "qualified": "synthetic.read_thing",
        \\          "display_name": "Read Thing",
        \\          "category": "synthetic",
        \\          "docs": "Sample reporter.",
        \\          "kind": "reporter",
        \\          "pins": [
        \\            { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input", "default": null },
        \\            { "name": "result", "label": "Result", "zig_type": "MyStruct", "dir": "output", "default": null }
        \\          ],
        \\          "return_type": "MyStruct"
        \\        }
        \\      ],
        \\      "pin_styles": [
        \\        { "zig_type": "MyStruct", "label": "My Struct", "color": [123, 45, 67] }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    ;
    try tmp.dir.writeFile(io_global.io(), .{ .sub_path = "flow_catalog.json", .data = json });
    const path = try tmp.dir.realPathFileAlloc(io_global.io(), "flow_catalog.json", aa);
    defer aa.free(path);

    const cat = try loadFromPath(aa, path);
    defer {
        const ba = cat.box_allocator;
        cat.deinit();
        ba.destroy(cat);
    }

    try std.testing.expectEqual(@as(usize, 2), cat.entries.len);
    try std.testing.expectEqualStrings("synthetic.do_thing", cat.entries[0].name);
    try std.testing.expectEqualStrings("Do Thing", cat.entries[0].display_name);
    try std.testing.expectEqual(Kind.command, cat.entries[0].kind);
    try std.testing.expectEqual(@as(usize, 2), cat.entries[0].pins.len);
    try std.testing.expectEqualStrings("u32", cat.entries[0].pins[0].type_name);

    try std.testing.expectEqual(Kind.reporter, cat.entries[1].kind);
    // O5 inference: a non-primitive return_type seeds `constructs`.
    try std.testing.expectEqualStrings("MyStruct", cat.entries[1].constructs.?);

    // Pin styles: merged on top of the static defaults (static count + 1).
    try std.testing.expectEqual(static_pin_styles.len + 1, cat.pin_styles.len);
    // Last one is the loaded MyStruct style.
    try std.testing.expectEqualStrings("MyStruct", cat.pin_styles[cat.pin_styles.len - 1].type_name);
    try std.testing.expectEqual(@as(u8, 123), cat.pin_styles[cat.pin_styles.len - 1].style.color[0]);
}

test "setRuntime: swap to runtime, then revert to static" {
    const aa = std.testing.allocator;

    // Baseline — static slice in place.
    const static_count = entries.len;
    try std.testing.expectEqual(@as(usize, 14), static_count);

    // Synthesize a minimal runtime catalog (1 entry) and install it.
    var arena = std.heap.ArenaAllocator.init(aa);
    const ag = arena.allocator();
    var es: std.ArrayList(Entry) = .empty;
    try es.append(ag, .{
        .name = "x.y",
        .category = "x",
        .display_name = "Y",
        .docs = "",
        .kind = .command,
        .pins = &[_]Pin{},
    });
    var ss: std.ArrayList(PinStyleEntry) = .empty;
    const cat = try aa.create(RuntimeCatalog);
    cat.* = .{
        .entries = try es.toOwnedSlice(ag),
        .pin_styles = try ss.toOwnedSlice(ag),
        .arena = arena,
        .box_allocator = aa,
    };

    setRuntime(cat);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("x.y", entries[0].name);

    // Revert — static slice back in place. `setRuntime(null)` frees the
    // previous runtime catalog (arena teardown drops every string +
    // slice; the saved `box_allocator` reclaims the outer struct).
    setRuntime(null);
    try std.testing.expectEqual(static_count, entries.len);
}

// Regression for labelle-gui#209: a runtime catalog installed by a
// project load (and never followed by another project transition) must
// be reclaimed at App shutdown. `App.deinit` now does this via a final
// `setRuntime(null)`. This test mirrors that lifecycle under
// `testing.allocator` — load a real sidecar, install it, then revert
// exactly once (as shutdown does). If the final revert is dropped, the
// catalog's arena (holding the ArrayList-grown `entries`/`pin_styles`
// slices) leaks and `testing.allocator` fails the test — which is the
// exact DebugAllocator leak the issue reported on window close.
test "setRuntime: shutdown revert frees a sidecar-loaded catalog (issue #209)" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const json =
        \\{
        \\  "generated_at": "2026-06-09T00:00:00Z",
        \\  "plugins": [
        \\    {
        \\      "name": "synthetic",
        \\      "flow_nodes": [
        \\        {
        \\          "qualified": "synthetic.do_thing",
        \\          "display_name": "Do Thing",
        \\          "category": "synthetic",
        \\          "docs": "",
        \\          "kind": "command",
        \\          "pins": [
        \\            { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input", "default": null }
        \\          ],
        \\          "return_type": null
        \\        }
        \\      ],
        \\      "pin_styles": [
        \\        { "zig_type": "MyStruct", "label": "My Struct", "color": [12, 34, 56] }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    ;
    try tmp.dir.writeFile(io_global.io(), .{ .sub_path = "flow_catalog.json", .data = json });
    const path = try tmp.dir.realPathFileAlloc(io_global.io(), "flow_catalog.json", aa);
    defer aa.free(path);

    // Project-load path: parse the sidecar and install it as the active
    // runtime catalog (what `App.reloadFlowNodeCatalog` does).
    const cat = try loadFromPath(aa, path);
    setRuntime(cat);
    // Guarantee cleanup even if an assertion below fails — otherwise an
    // early exit leaks `cat` and leaves `current_runtime` dirty for the
    // next test. `setRuntime` is idempotent, so this is a no-op after the
    // explicit revert succeeds (gemini #211).
    defer setRuntime(null);
    try std.testing.expect(current_runtime != null);
    try std.testing.expectEqualStrings("synthetic.do_thing", entries[0].name);

    // Shutdown path: the single revert `App.deinit` now performs. This
    // is the *only* free of `cat`'s arena — drop it and the test leaks.
    setRuntime(null);
    try std.testing.expect(current_runtime == null);
    try std.testing.expectEqual(static_pin_styles.len, pin_styles.len);
}

test "loadFromSidecar: returns null when no .labelle/* subdir has the file" {
    const aa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realPathFileAlloc(io_global.io(), ".", aa);
    defer aa.free(dir_path);

    // No .labelle/ created → loader returns null and the App stays on
    // the static fallback.
    const cat = try loadFromSidecar(aa, dir_path);
    try std.testing.expect(cat == null);
}

// ─── Allocator-failure leak regression ─────────────────────────────────
//
// Drives `loadFromPath` through every allocation point with
// `std.testing.checkAllAllocationFailures` to catch any cleanup hole
// introduced by future refactors. Today the leak window flagged by
// Wave 4 review (labelle-gui#170 phase 4 follow-up) — `cat` allocated
// before `try ...toOwnedSlice(aa)` in the struct literal — is
// unreachable because the arena's `remap` path means `toOwnedSlice`
// shrinks the existing arena buffer in place rather than allocating
// fresh memory. The defensive ordering in `loadFromPath`
// (materialize the slices *before* `allocator.create`) keeps the
// leak window unreachable even if the arena is swapped for a
// non-remap-capable allocator down the road. This test pins both
// the ordering invariant and the broader allocator-cleanup
// guarantee.

fn loadFromPathOomCase(allocator: std.mem.Allocator) !void {
    // Hermetic fixture: a minimal but realistic sidecar (one plugin,
    // one FlowNode, one PinStyle) so every allocation point in
    // `parseFlowNode` and `parsePinStyle` runs at least once.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const json =
        \\{
        \\  "generated_at": "2026-05-23T00:00:00Z",
        \\  "plugins": [
        \\    {
        \\      "name": "synthetic",
        \\      "flow_nodes": [
        \\        {
        \\          "qualified": "synthetic.do_thing",
        \\          "display_name": "Do Thing",
        \\          "category": "synthetic",
        \\          "docs": "",
        \\          "kind": "command",
        \\          "pins": [
        \\            { "name": "entity", "label": "Entity", "zig_type": "u32", "dir": "input", "default": null }
        \\          ],
        \\          "return_type": null
        \\        }
        \\      ],
        \\      "pin_styles": [
        \\        { "zig_type": "MyStruct", "label": "My Struct", "color": [12, 34, 56] }
        \\      ]
        \\    }
        \\  ]
        \\}
        \\
    ;
    try tmp.dir.writeFile(io_global.io(), .{ .sub_path = "flow_catalog.json", .data = json });
    const path = try tmp.dir.realPathFileAlloc(io_global.io(), "flow_catalog.json", allocator);
    defer allocator.free(path);

    const cat = try loadFromPath(allocator, path);
    const ba = cat.box_allocator;
    cat.deinit();
    ba.destroy(cat);
}

test "loadFromPath: no leaks at every allocation-failure point" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadFromPathOomCase, .{});
}
