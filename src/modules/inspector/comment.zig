//! Comment inspector section. Always present — the comment buffer
//! lives on `Entity` itself (not behind an optional), so the section
//! shows up for every entity. Defaults to collapsed.

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
    if (zgui.inputTextMultiline("##comment", .{
        .buf = &entity.comment,
        .w = 0,
        .h = 80,
    })) is_dirty.* = true;
}

pub fn section() InspectorSection {
    return .{
        .name = "Comment",
        .default_open = false,
        .is_present = isPresent,
        .render = render,
    };
}
