//! Circle inspector section. Only renders when `entity.circle != null`.

const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");
const InspectorSection = @import("section.zig").InspectorSection;

fn isPresent(entity: *scene_io.Entity) bool {
    return entity.circle != null;
}

fn render(
    entity: *scene_io.Entity,
    is_dirty: *bool,
    _: ?*const atlas.Index,
) void {
    const circle = entity.circle.?;
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

pub fn section() InspectorSection {
    return .{
        .name = "Circle",
        .default_open = true,
        .is_present = isPresent,
        .render = render,
    };
}
