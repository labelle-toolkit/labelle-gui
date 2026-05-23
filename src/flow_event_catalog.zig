//! Catalog of plugin- and game-declared event names the flow editor
//! offers in its `OnEvent` / `Emit` dropdowns (RFC-PLUGIN-EVENTS §1, §8;
//! GUI #169 — closes RFC open question O6).
//!
//! ## Why a catalog?
//!
//! The assembler builds a `pub const PluginEvents` union over every
//! plugin's `pub const Events` block at codegen time. Codegen-side that
//! union is the source of truth: an `OnEvent` flow's `name` resolves to
//! a variant of that union, and an `Emit` node's pin set reflects the
//! variant's payload struct fields.
//!
//! The flow editor is a separate tool and does not import the
//! game's generated module — to do so it would have to spin up the full
//! assembler. So for v1 the editor consumes a **hard-coded static
//! table** of known plugin events plus an empty list of game events;
//! the assembler-derived list is the future option (a comptime sidecar
//! emitted alongside the build) but is out of scope for this phase.
//! Tracked as the TODO below.
//!
//! ## Shape
//!
//! Each entry is a dotted name (`"<plugin>.<event>"` for a plugin
//! event, or a bare `"<event>"` for a game-declared `events/*.zig`
//! event) plus the payload struct's field list. Field types are spelled
//! the same way they appear in the plugin source so a future scan-based
//! catalog can emit the same shape.
//!
//! For now the catalog mirrors **`labelle-box2d`**'s shipped
//! `pub const Events` (Phase 2, RFC §1, `labelle-box2d/src/root.zig:93-125`)
//! and nothing else. Adding a new plugin event means adding an entry
//! here until the dynamic scan lands.

const std = @import("std");

/// One payload field on a catalog entry — the same shape an `Emit`
/// node's input pin takes.
pub const PayloadField = struct {
    name: []const u8,
    /// Zig type name as it appears in the plugin's `pub const Events`
    /// payload struct (`u32`, `f32`, …). Surfaced next to the pin label
    /// so the editor's user sees what they are wiring into.
    type_name: []const u8,
};

/// One catalog entry — a known event the editor can offer in its
/// dropdowns. `name` is the dotted form the on-disk `.flow.jsonc` uses
/// (`box2d.collision_begin`). The qualified-tag form the assembler
/// emits in `PluginEvents` (`box2d__collision_begin`) is a mechanical
/// rewrite (`.` → `__`); codegen reflects that internally.
pub const Entry = struct {
    /// Dotted event name as it appears in the `.flow.jsonc` file.
    name: []const u8,
    /// Optional human-readable summary surfaced as a tooltip on the
    /// dropdown row. Doc-comment-derived in a future scan-based
    /// catalog; hand-written for now.
    description: []const u8 = "",
    /// Payload struct fields, in declaration order — drives `Emit` pin
    /// emission.
    fields: []const PayloadField,
};

/// Static catalog of known events. Update alongside any new plugin
/// that ships a `pub const Events` declaration until the dynamic
/// scan lands.
///
/// TODO(O6 follow-up): replace with an assembler-emitted sidecar (the
/// dotted-name list plus payload-field reflection) so the editor's
/// dropdown automatically tracks every plugin the project links —
/// `labelle-box2d`, future plugins, and the game's own `events/*.zig`
/// declarations. See `labelle-assembler#174` for the producer side.
pub const entries = [_]Entry{
    .{
        .name = "box2d.collision_begin",
        .description = "Two entities started touching.",
        .fields = &.{
            .{ .name = "entity_a", .type_name = "u32" },
            .{ .name = "entity_b", .type_name = "u32" },
        },
    },
    .{
        .name = "box2d.collision_end",
        .description = "Two entities stopped touching.",
        .fields = &.{
            .{ .name = "entity_a", .type_name = "u32" },
            .{ .name = "entity_b", .type_name = "u32" },
        },
    },
    .{
        .name = "box2d.collision_hit",
        .description = "Solver-reported hit event (large impact); carries contact point, surface normal, and approach speed.",
        .fields = &.{
            .{ .name = "entity_a", .type_name = "u32" },
            .{ .name = "entity_b", .type_name = "u32" },
            .{ .name = "point_x", .type_name = "f32" },
            .{ .name = "point_y", .type_name = "f32" },
            .{ .name = "normal_x", .type_name = "f32" },
            .{ .name = "normal_y", .type_name = "f32" },
            .{ .name = "speed", .type_name = "f32" },
        },
    },
    .{
        .name = "box2d.sensor_enter",
        .description = "A visitor entity entered a sensor trigger volume.",
        .fields = &.{
            .{ .name = "sensor_entity", .type_name = "u32" },
            .{ .name = "visitor_entity", .type_name = "u32" },
        },
    },
    .{
        .name = "box2d.sensor_exit",
        .description = "A visitor entity exited a sensor trigger volume.",
        .fields = &.{
            .{ .name = "sensor_entity", .type_name = "u32" },
            .{ .name = "visitor_entity", .type_name = "u32" },
        },
    },
};

/// Lookup `name` in the catalog. Returns null when the name isn't a
/// known event — the editor surfaces that as a warning hint, the
/// codegen rejects it at build time against the merged `PluginEvents`
/// union.
pub fn lookup(name: []const u8) ?*const Entry {
    for (&entries) |*e| {
        if (std.mem.eql(u8, e.name, name)) return e;
    }
    return null;
}

/// True when `name` matches some catalog entry. Sugar for callers that
/// only want a yes/no without the entry body.
pub fn isKnown(name: []const u8) bool {
    return lookup(name) != null;
}

// ─── Tests ─────────────────────────────────────────────────────────────

test "lookup finds a known box2d event" {
    const e = lookup("box2d.collision_begin") orelse unreachable;
    try std.testing.expectEqualStrings("box2d.collision_begin", e.name);
    try std.testing.expectEqual(@as(usize, 2), e.fields.len);
    try std.testing.expectEqualStrings("entity_a", e.fields[0].name);
    try std.testing.expectEqualStrings("u32", e.fields[0].type_name);
}

test "lookup misses an unknown name" {
    try std.testing.expect(lookup("nope.never") == null);
    try std.testing.expect(!isKnown("nope.never"));
}

test "every catalog entry has at least one payload field" {
    // A payload-less event would have nothing to reflect into an `Emit`
    // node's input pins — guard against an empty entry slipping in.
    for (&entries) |e| try std.testing.expect(e.fields.len > 0);
}

test "collision_hit reflects the full 7-field payload" {
    const e = lookup("box2d.collision_hit") orelse unreachable;
    try std.testing.expectEqual(@as(usize, 7), e.fields.len);
    try std.testing.expectEqualStrings("speed", e.fields[6].name);
    try std.testing.expectEqualStrings("f32", e.fields[6].type_name);
}
