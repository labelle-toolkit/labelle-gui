const zgui = @import("zgui");
const module = @import("../module.zig");

var is_open: bool = true;

// Example entity properties
var position: [3]f32 = .{ 0.0, 0.0, 0.0 };
var rotation: [3]f32 = .{ 0.0, 0.0, 0.0 };
var scale: [3]f32 = .{ 1.0, 1.0, 1.0 };
var entity_name: [64:0]u8 = [_:0]u8{0} ** 64;
var is_visible: bool = true;
var color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 };

pub fn init() void {
    @memcpy(entity_name[0..6], "Player");
}

pub fn deinit() void {}

fn renderPanel() void {
    zgui.text("Entity Properties", .{});
    zgui.separator();

    // Name field
    _ = zgui.inputText("Name", .{ .buf = &entity_name });

    zgui.spacing();
    zgui.text("Transform", .{});
    zgui.separator();

    // Transform properties
    _ = zgui.dragFloat3("Position", .{ .v = &position, .speed = 0.1 });
    _ = zgui.dragFloat3("Rotation", .{ .v = &rotation, .speed = 1.0 });
    _ = zgui.dragFloat3("Scale", .{ .v = &scale, .speed = 0.05 });

    zgui.spacing();
    zgui.text("Rendering", .{});
    zgui.separator();

    _ = zgui.checkbox("Visible", .{ .v = &is_visible });
    _ = zgui.colorEdit4("Color", .{ .col = &color });

    zgui.spacing();
    zgui.separator();

    if (zgui.button("Reset Transform", .{ .w = -1 })) {
        position = .{ 0.0, 0.0, 0.0 };
        rotation = .{ 0.0, 0.0, 0.0 };
        scale = .{ 1.0, 1.0, 1.0 };
    }
}

pub const inspector_module = module.Module{
    .name = "inspector",
    .display_name = "Inspector",
    .render_panel = renderPanel,
    .is_open = &is_open,
    .on_init = init,
    .on_deinit = deinit,
};
