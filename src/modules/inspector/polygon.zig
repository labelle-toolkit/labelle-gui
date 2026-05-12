//! Polygon inspector section. Only renders when `entity.polygon != null`.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");
const InspectorSection = @import("section.zig").InspectorSection;

fn isPresent(entity: *scene_io.Entity) bool {
    return entity.polygon != null;
}

fn render(
    entity: *scene_io.Entity,
    is_dirty: *bool,
    _: ?*const atlas.Index,
) void {
    const poly = entity.polygon.?;
    // Render the points as a numbered list. Each row carries two
    // `inputFloat` widgets and a small `×` remove button. We walk
    // by index because the remove path needs to shift the tail down
    // (no realloc — fixed-cap inline buffer, see scene_io.Polygon).
    var idx: u32 = 0;
    // ImGui needs distinct IDs per row; push the index as a scope
    // so the `x` / `y` / `×` labels can repeat.
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
            // Shift the tail of the inline buffer down. Cheap: the
            // cap is small (64), and removal is rare.
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

    // Add-point button. Hidden when the buffer is at cap so the
    // user can't drive past it silently.
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
    // round-to-nearest reverse conversion as Sprite/Rectangle so
    // the source round-trip is stable across saves.
    var col4: [4]f32 = .{
        @as(f32, @floatFromInt(poly.r)) / 255.0,
        @as(f32, @floatFromInt(poly.g)) / 255.0,
        @as(f32, @floatFromInt(poly.b)) / 255.0,
        @as(f32, @floatFromInt(poly.a)) / 255.0,
    };
    if (zgui.colorEdit4("color", .{ .col = &col4 })) {
        // Clamp before casting — see comment in inspector/rectangle.zig.
        poly.r = @intFromFloat(@round(std.math.clamp(col4[0] * 255.0, 0.0, 255.0)));
        poly.g = @intFromFloat(@round(std.math.clamp(col4[1] * 255.0, 0.0, 255.0)));
        poly.b = @intFromFloat(@round(std.math.clamp(col4[2] * 255.0, 0.0, 255.0)));
        poly.a = @intFromFloat(@round(std.math.clamp(col4[3] * 255.0, 0.0, 255.0)));
        is_dirty.* = true;
    }
    if (zgui.checkbox("filled", .{ .v = &poly.filled })) is_dirty.* = true;
}

pub fn section() InspectorSection {
    return .{
        .name = "Polygon",
        .default_open = true,
        .is_present = isPresent,
        .render = render,
    };
}
