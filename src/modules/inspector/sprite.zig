//! Sprite inspector section. Only renders when `entity.sprite != null`.
//!
//! Surfaces a soft "(missing)" hint when the typed `sprite_name`
//! doesn't resolve against the project's atlas index — doesn't block
//! edits (the engine ultimately decides what's valid; we just guide).

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");
const InspectorSection = @import("section.zig").InspectorSection;

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
/// `zgui.combo`'s `items_separated_by_zeros` argument. Built at
/// comptime from `pivot_names` so the two lists can't drift.
const pivot_items: [:0]const u8 = blk: {
    var res: [:0]const u8 = "";
    for (pivot_names) |name| {
        res = res ++ name ++ "\x00";
    }
    break :blk res;
};

fn isPresent(entity: *scene_io.Entity) bool {
    return entity.sprite != null;
}

fn render(
    entity: *scene_io.Entity,
    is_dirty: *bool,
    atlas_index: ?*const atlas.Index,
) void {
    const sprite = entity.sprite.?;
    if (zgui.inputText("sprite_name", .{ .buf = &sprite.sprite_name })) is_dirty.* = true;
    // Resolve the typed sprite name against the project's atlas
    // index; surface a soft `(missing)` hint when it doesn't match
    // anything. Doesn't block edits — the engine ultimately decides
    // what's valid; we just guide.
    if (atlas_index) |idx| {
        const name_str = std.mem.sliceTo(&sprite.sprite_name, 0);
        if (name_str.len > 0 and idx.find(name_str) == null) {
            zgui.sameLine(.{});
            zgui.textColored(.{ 1.0, 0.5, 0.4, 1.0 }, "(missing)", .{});
        }
    }
    // Pivot is a closed enum on the engine side — let the user pick
    // from the 9 valid names rather than free-type. Order matches
    // `pivotOffset` in modules/viewport.zig.
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

    // z_index is optional in the source; the checkbox toggles whether
    // we emit it at all. Editing the int alone (with the box unchecked)
    // doesn't suddenly add a `"z_index"` key to the file — the user has
    // to opt in explicitly.
    if (zgui.checkbox("z_index?", .{ .v = &sprite.has_z_index })) is_dirty.* = true;
    if (sprite.has_z_index) {
        zgui.sameLine(.{});
        if (zgui.inputInt("##z_index", .{ .v = &sprite.z_index })) is_dirty.* = true;
    }
}

pub fn section() InspectorSection {
    return .{
        .name = "Sprite",
        .default_open = true,
        .is_present = isPresent,
        .render = render,
    };
}
