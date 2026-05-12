//! Rectangle inspector section. Only renders when `entity.rectangle != null`.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");
const InspectorSection = @import("section.zig").InspectorSection;

fn isPresent(entity: *scene_io.Entity) bool {
    return entity.rectangle != null;
}

fn render(
    entity: *scene_io.Entity,
    is_dirty: *bool,
    _: ?*const atlas.Index,
) void {
    const rect = entity.rectangle.?;
    if (zgui.inputFloat("width", .{ .v = &rect.width })) is_dirty.* = true;
    if (zgui.inputFloat("height", .{ .v = &rect.height })) is_dirty.* = true;

    // Convert u8 RGBA to imgui's float-in-[0,1] color picker and back.
    // The reverse conversion rounds to the nearest u8 so the source
    // round-trip is stable across saves.
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

pub fn section() InspectorSection {
    return .{
        .name = "Rectangle",
        .default_open = true,
        .is_present = isPresent,
        .render = render,
    };
}
