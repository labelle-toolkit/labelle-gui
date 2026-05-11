//! Shared entity inspector — renders an entity's properties +
//! components into the current imgui window. Called from both the
//! Scene module (one selected entity at a time) and the Prefab
//! module (the prefab body itself or a selected child).
//!
//! `is_dirty` is a `*bool` so the caller can hand in whatever tracks
//! "needs save" on its side — `SceneState.is_dirty` for scenes,
//! `PrefabState.is_dirty` for prefabs. Any edit (Position input,
//! comment change) flips it.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../scene_io.zig");
const atlas = @import("../atlas.zig");

/// Canonical Sprite.pivot values, matching the engine's pivot enum
/// and the order in `modules/viewport.zig:pivotOffset`. Index 0
/// (`center`) is the default when the buffer is empty or unknown.
const pivot_names = [_][]const u8{
    "center",
    "bottom_center",
    "top_center",
    "bottom_left",
    "bottom_right",
    "top_left",
    "top_right",
    "left_center",
    "right_center",
};

/// Zero-separated, zero-terminated form of `pivot_names` for
/// `zgui.combo`'s `items_separated_by_zeros` argument.
const pivot_items: [:0]const u8 =
    "center\x00" ++
    "bottom_center\x00" ++
    "top_center\x00" ++
    "bottom_left\x00" ++
    "bottom_right\x00" ++
    "top_left\x00" ++
    "top_right\x00" ++
    "left_center\x00" ++
    "right_center\x00";

/// Render the editable surface for one entity:
///
/// - Heading: prefab name (plus optional `Entity #N` label for scene
///   entities; pass `null` for the lone entity in a prefab).
/// - `Position` collapsing header with x/y inputs.
/// - `Comment` collapsing header with the multiline comment buffer.
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
) void {
    if (entity_index) |n| {
        zgui.text("Entity #{d}", .{n});
    }
    if (entity.prefab) |p| {
        zgui.text("prefab: {s}", .{p});
    } else {
        zgui.textDisabled("(no prefab)", .{});
    }
    zgui.spacing();

    if (zgui.collapsingHeader("Position", .{ .default_open = true })) {
        if (entity.position) |*pos| {
            if (zgui.inputFloat("x", .{ .v = &pos.x })) is_dirty.* = true;
            if (zgui.inputFloat("y", .{ .v = &pos.y })) is_dirty.* = true;
        } else {
            zgui.textDisabled("(no Position component)", .{});
        }
    }

    if (entity.sprite) |sprite| {
        if (zgui.collapsingHeader("Sprite", .{ .default_open = true })) {
            if (zgui.inputText("sprite_name", .{ .buf = &sprite.sprite_name })) is_dirty.* = true;
            // Resolve the typed sprite name against the project's
            // atlas index; surface a soft `(missing)` hint when it
            // doesn't match anything. Doesn't block edits — the
            // engine ultimately decides what's valid; we just guide.
            if (atlas_index) |idx| {
                const name_str = std.mem.sliceTo(&sprite.sprite_name, 0);
                if (name_str.len > 0 and idx.find(name_str) == null) {
                    zgui.sameLine(.{});
                    zgui.textColored(.{ 1.0, 0.5, 0.4, 1.0 }, "(missing)", .{});
                }
            }
            // Pivot is a closed enum on the engine side — let the
            // user pick from the 9 valid names rather than free-type.
            // Order matches `pivotOffset` in modules/viewport.zig.
            const current_pivot = std.mem.sliceTo(&sprite.pivot, 0);
            var pivot_idx: i32 = for (pivot_names, 0..) |n, i| {
                if (std.mem.eql(u8, current_pivot, n)) break @intCast(i);
            } else 0;
            if (zgui.combo("pivot", .{
                .current_item = &pivot_idx,
                .items_separated_by_zeros = pivot_items,
            })) {
                const chosen = pivot_names[@intCast(pivot_idx)];
                @memset(&sprite.pivot, 0);
                @memcpy(sprite.pivot[0..chosen.len], chosen);
                is_dirty.* = true;
            }
            if (zgui.inputText("layer", .{ .buf = &sprite.layer })) is_dirty.* = true;

            // z_index is optional in the source; the checkbox toggles
            // whether we emit it at all. Editing the int alone (with
            // the box unchecked) doesn't suddenly add a `"z_index"`
            // key to the file — the user has to opt in explicitly.
            if (zgui.checkbox("z_index?", .{ .v = &sprite.has_z_index })) is_dirty.* = true;
            if (sprite.has_z_index) {
                zgui.sameLine(.{});
                if (zgui.inputInt("##z_index", .{ .v = &sprite.z_index })) is_dirty.* = true;
            }
        }
    }

    if (zgui.collapsingHeader("Comment", .{})) {
        if (zgui.inputTextMultiline("##comment", .{
            .buf = &entity.comment,
            .w = 0,
            .h = 80,
        })) is_dirty.* = true;
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
