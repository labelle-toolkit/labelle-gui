const std = @import("std");
const module = @import("../module.zig");

fn renderMenu() void {
    std.debug.print("[AssetBrowser] Rendering menu\n", .{});
}

fn renderPanel() void {
    std.debug.print("[AssetBrowser] Rendering panel\n", .{});
}

fn onInit() void {
    std.debug.print("[AssetBrowser] Initialized\n", .{});
}

fn onDeinit() void {
    std.debug.print("[AssetBrowser] Deinitialized\n", .{});
}

pub const asset_browser = module.Module{
    .name = "asset_browser",
    .display_name = "Asset Browser",
    .render_menu = renderMenu,
    .render_panel = renderPanel,
    .on_init = onInit,
    .on_deinit = onDeinit,
};
