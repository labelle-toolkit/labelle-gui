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
/// `zgui.combo`'s `items_separated_by_zeros` argument. Built at
/// comptime from `pivot_names` so the two lists can't drift.
const pivot_items: [:0]const u8 = blk: {
    var res: [:0]const u8 = "";
    for (pivot_names) |name| {
        res = res ++ name ++ "\x00";
    }
    break :blk res;
};

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

    if (entity.rectangle) |rect| {
        if (zgui.collapsingHeader("Rectangle", .{ .default_open = true })) {
            if (zgui.inputFloat("width", .{ .v = &rect.width })) is_dirty.* = true;
            if (zgui.inputFloat("height", .{ .v = &rect.height })) is_dirty.* = true;

            // Convert u8 RGBA to imgui's float-in-[0,1] color picker
            // and back. The reverse conversion rounds to the nearest
            // u8 so the source round-trip is stable across saves.
            var col4: [4]f32 = .{
                @as(f32, @floatFromInt(rect.r)) / 255.0,
                @as(f32, @floatFromInt(rect.g)) / 255.0,
                @as(f32, @floatFromInt(rect.b)) / 255.0,
                @as(f32, @floatFromInt(rect.a)) / 255.0,
            };
            if (zgui.colorEdit4("color", .{ .col = &col4 })) {
                // Clamp before casting: `@intFromFloat` is safety-checked
                // and would panic on values outside `[0, 255]`, which can
                // happen due to float precision or manual hex/int input.
                rect.r = @intFromFloat(@round(std.math.clamp(col4[0] * 255.0, 0.0, 255.0)));
                rect.g = @intFromFloat(@round(std.math.clamp(col4[1] * 255.0, 0.0, 255.0)));
                rect.b = @intFromFloat(@round(std.math.clamp(col4[2] * 255.0, 0.0, 255.0)));
                rect.a = @intFromFloat(@round(std.math.clamp(col4[3] * 255.0, 0.0, 255.0)));
                is_dirty.* = true;
            }
            if (zgui.checkbox("filled", .{ .v = &rect.filled })) is_dirty.* = true;
        }
    }

    if (entity.circle) |circle| {
        if (zgui.collapsingHeader("Circle", .{ .default_open = true })) {
            if (zgui.inputFloat("radius", .{ .v = &circle.radius })) is_dirty.* = true;

            var col4: [4]f32 = .{
                @as(f32, @floatFromInt(circle.r)) / 255.0,
                @as(f32, @floatFromInt(circle.g)) / 255.0,
                @as(f32, @floatFromInt(circle.b)) / 255.0,
                @as(f32, @floatFromInt(circle.a)) / 255.0,
            };
            if (zgui.colorEdit4("color", .{ .col = &col4 })) {
                circle.r = @intFromFloat(@round(col4[0] * 255.0));
                circle.g = @intFromFloat(@round(col4[1] * 255.0));
                circle.b = @intFromFloat(@round(col4[2] * 255.0));
                circle.a = @intFromFloat(@round(col4[3] * 255.0));
                is_dirty.* = true;
            }
            if (zgui.checkbox("filled", .{ .v = &circle.filled })) is_dirty.* = true;
        }
    }

    if (entity.polygon) |poly| {
        if (zgui.collapsingHeader("Polygon", .{ .default_open = true })) {
            // Render the points as a numbered list. Each row carries
            // two `inputFloat` widgets and a small `×` remove button.
            // We walk by index because the remove path needs to
            // shift the tail down (no realloc — fixed-cap inline
            // buffer, see scene_io.Polygon).
            var idx: u32 = 0;
            // ImGui needs distinct IDs per row; push the index as a
            // scope so the `x` / `y` / `×` labels can repeat.
            while (idx < poly.point_count) {
                zgui.pushIntId(@intCast(idx));
                defer zgui.popId();

                zgui.text("#{d}", .{idx});
                zgui.sameLine(.{});
                zgui.setNextItemWidth(80);
                if (zgui.inputFloat("x", .{ .v = &poly.points[idx].x })) is_dirty.* = true;
                zgui.sameLine(.{});
                zgui.setNextItemWidth(80);
                if (zgui.inputFloat("y", .{ .v = &poly.points[idx].y })) is_dirty.* = true;
                zgui.sameLine(.{});

                var removed = false;
                if (zgui.smallButton("x##rm")) {
                    // Shift the tail of the inline buffer down. Cheap:
                    // the cap is small (64), and removal is rare.
                    var k: u32 = idx;
                    while (k + 1 < poly.point_count) : (k += 1) {
                        poly.points[k] = poly.points[k + 1];
                    }
                    poly.point_count -= 1;
                    poly.points[poly.point_count] = .{};
                    is_dirty.* = true;
                    removed = true;
                }
                if (!removed) idx += 1;
            }

            // Add-point button. Hidden when the buffer is at cap so
            // the user can't drive past it silently.
            if (poly.point_count < scene_io.polygon_max_points) {
                if (zgui.button("+ Add point", .{})) {
                    poly.points[poly.point_count] = .{};
                    poly.point_count += 1;
                    is_dirty.* = true;
                }
            } else {
                zgui.textDisabled("(at cap: {d} points)", .{scene_io.polygon_max_points});
            }

            // Convert u8 RGBA to imgui's float color picker; same
            // round-to-nearest reverse conversion as Sprite/Rectangle
            // so the source round-trip is stable across saves.
            var col4: [4]f32 = .{
                @as(f32, @floatFromInt(poly.r)) / 255.0,
                @as(f32, @floatFromInt(poly.g)) / 255.0,
                @as(f32, @floatFromInt(poly.b)) / 255.0,
                @as(f32, @floatFromInt(poly.a)) / 255.0,
            };
            if (zgui.colorEdit4("color", .{ .col = &col4 })) {
                poly.r = @intFromFloat(@round(col4[0] * 255.0));
                poly.g = @intFromFloat(@round(col4[1] * 255.0));
                poly.b = @intFromFloat(@round(col4[2] * 255.0));
                poly.a = @intFromFloat(@round(col4[3] * 255.0));
                is_dirty.* = true;
            }
            if (zgui.checkbox("filled", .{ .v = &poly.filled })) is_dirty.* = true;
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
