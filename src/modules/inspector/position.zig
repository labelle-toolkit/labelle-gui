//! Position inspector section. Always present — when `entity.position`
//! is null the body shows a "(no Position component)" hint instead of
//! editor widgets, matching the pre-refactor behavior.

const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const atlas = @import("../../atlas.zig");
const InspectorSection = @import("section.zig").InspectorSection;

fn isPresent(_: *scene_io.Entity) bool {
    return true;
}

fn render(
    entity: *scene_io.Entity,
    is_dirty: *bool,
    _: ?*const atlas.Index,
) void {
    if (entity.position) |*pos| {
        if (zgui.inputFloat("x", .{ .v = &pos.x })) is_dirty.* = true;
        if (zgui.inputFloat("y", .{ .v = &pos.y })) is_dirty.* = true;
    } else {
        zgui.textDisabled("(no Position component)", .{});
    }
}

pub fn section() InspectorSection {
    return .{
        .name = "Position",
        .default_open = true,
        .is_present = isPresent,
        .render = render,
    };
}
