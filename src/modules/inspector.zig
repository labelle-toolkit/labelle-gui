//! Shared entity inspector — renders an entity's properties +
//! components into the current imgui window. Called from both the
//! Scene module (one selected entity at a time) and the Prefab
//! module (the prefab body itself or a selected child).
//!
//! `is_dirty` is a `*bool` so the caller can hand in whatever tracks
//! "needs save" on its side — `SceneState.is_dirty` for scenes,
//! `PrefabState.is_dirty` for prefabs. Any edit (Position input,
//! comment change) flips it.
//!
//! Layout note: each typed-component section lives in its own file
//! under `inspector/` and exposes a `section()` constructor that
//! returns an `InspectorSection`. This file just walks the registry
//! and dispatches — adding a new typed component is one new file +
//! one line in the `sections` array. See issue #38 for the
//! parallel-development motivation. The Module/Registry pattern in
//! `../module.zig` is the template.
//!
//! The trailing "Other components (N)" group isn't a registry entry —
//! it walks the `component_extras` slice rather than a typed `Entity`
//! field, so it's special-cased as the closing block of `renderEntity`.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../scene_io.zig");
const atlas = @import("../atlas.zig");
const prefab_index = @import("../prefab_index.zig");
const prefab_contents = @import("inspector/prefab_contents.zig");

pub const InspectorSection = @import("inspector/section.zig").InspectorSection;

/// Registry of typed-component sections, rendered in this order.
/// Adding a new typed component: drop a file in `inspector/`, export
/// `section()`, and append it here. No other files need to change.
pub const sections = [_]InspectorSection{
    @import("inspector/position.zig").section(),
    @import("inspector/sprite.zig").section(),
    @import("inspector/rectangle.zig").section(),
    @import("inspector/circle.zig").section(),
    @import("inspector/polygon.zig").section(),
    @import("inspector/comment.zig").section(),
};

/// Render the editable surface for one entity:
///
/// - Heading: prefab name (plus optional `Entity #N` label for scene
///   entities; pass `null` for the lone entity in a prefab).
/// - One collapsing header per registered `InspectorSection` whose
///   `is_present` returns true for `entity`.
/// - `Other components (N)` group with a collapsing header per
///   unmodeled component, body shown verbatim (read-only for v1).
///
/// Caller controls window placement; this just paints into whatever
/// container is active.
pub fn renderEntity(
    entity: *scene_io.Entity,
    component_extras: []const scene_io.ComponentExtra,
    is_dirty: *bool,
    entity_index: ?usize,
    atlas_index: ?*const atlas.Index,
    /// Optional sink: when non-null AND the entity references a
    /// prefab, the inspector renders an "Edit prefab" button next to
    /// the prefab name. Clicking it writes the prefab name into the
    /// sink; the caller resolves the file path and opens the prefab
    /// as a tab. The scene editor wires this; the prefab editor passes
    /// null because there's no further level to descend into.
    request_open_prefab: ?*?[]const u8,
    /// Optional sink: when non-null, the inspector renders a small
    /// "Delete" button below the entity header. Clicking it flips the
    /// flag; the caller (the scene editor) opens its own confirmation
    /// modal and removes the entity on accept. Decoupled so the
    /// inspector doesn't need to know about modal state or
    /// scene-vs-prefab routing — the prefab editor passes null
    /// because per-child delete inside a prefab is handled by the
    /// prefab editor's own UI flow.
    request_delete: ?*bool,
    /// Optional prefab cache. When the entity references a prefab and
    /// this is non-null, the inspector renders a read-only
    /// "Prefab contents" section listing every component on the
    /// referenced prefab tree (issue #86). The scene editor wires its
    /// `app.prefab_index`; the prefab editor passes null — there's no
    /// need to display "contents of yourself" inside the prefab tab.
    prefab_idx: ?*const prefab_index.Index,
) void {
    if (entity_index) |n| {
        zgui.text("Entity #{d}", .{n});
    }
    if (entity.prefab) |p| {
        zgui.text("prefab: {s}", .{p});
        if (request_open_prefab) |sink| {
            zgui.sameLine(.{});
            // ImGui identifies buttons by label; the "##..." suffix is
            // a hidden discriminator so the button's ID stays stable
            // even if a future Sprite section also wants to surface
            // an "Edit prefab" affordance.
            if (zgui.smallButton("Edit prefab##inspector_edit_prefab")) {
                sink.* = p;
            }
        }
    } else {
        zgui.textDisabled("(no prefab)", .{});
    }
    if (request_delete) |sink| {
        if (zgui.smallButton("Delete##inspector_delete_entity")) {
            sink.* = true;
        }
    }
    zgui.spacing();

    inline for (sections) |s| {
        if (s.is_present(entity)) {
            if (zgui.collapsingHeader(s.name, .{ .default_open = s.default_open })) {
                s.render(entity, is_dirty, atlas_index);
            }
        }
    }

    if (entity.prefab) |p| {
        if (prefab_idx) |idx| prefab_contents.render(p, idx);
    }

    if (component_extras.len > 0) {
        zgui.spacing();
        zgui.separator();
        zgui.textDisabled("Other components ({d})", .{component_extras.len});
        for (component_extras) |extra| {
            // Component names are short in practice (Sprite, Coin,
            // Room…), but allow longer custom names — 256 bytes
            // covers any reasonable identifier.
            var label_buf: [256:0]u8 = undefined;
            const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{extra.name}) catch continue;
            if (zgui.collapsingHeader(label, .{})) {
                zgui.textUnformatted(extra.value_text);
            }
        }
    }
}
