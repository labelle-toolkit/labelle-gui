const std = @import("std");
const module = @import("../module.zig");

fn renderMenu() void {
    std.debug.print("[Console] Rendering menu\n", .{});
}

fn renderPanel() void {
    std.debug.print("[Console] Rendering panel\n", .{});
}

fn onInit() void {
    std.debug.print("[Console] Initialized\n", .{});
}

fn onDeinit() void {
    std.debug.print("[Console] Deinitialized\n", .{});
}

pub const console = module.Module{
    .name = "console",
    .display_name = "Console",
    .render_menu = renderMenu,
    .render_panel = renderPanel,
    .on_init = onInit,
    .on_deinit = onDeinit,
};
