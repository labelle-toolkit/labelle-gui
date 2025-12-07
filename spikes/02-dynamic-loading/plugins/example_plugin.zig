const std = @import("std");

/// Plugin information - must match the API version
const plugin_info = PluginInfo{
    .api_version = 1,
    .name = "example_plugin",
    .display_name = "Example Plugin",
    .version = "1.0.0",
};

const PluginInfo = extern struct {
    api_version: u32,
    name: [*:0]const u8,
    display_name: [*:0]const u8,
    version: [*:0]const u8,
};

export fn plugin_get_info() *const PluginInfo {
    return &plugin_info;
}

export fn plugin_init() void {
    std.debug.print("[ExamplePlugin] Initialized!\n", .{});
}

export fn plugin_deinit() void {
    std.debug.print("[ExamplePlugin] Deinitialized!\n", .{});
}

export fn plugin_render_menu() void {
    std.debug.print("[ExamplePlugin] Rendering menu\n", .{});
}

export fn plugin_render_panel() void {
    std.debug.print("[ExamplePlugin] Rendering panel\n", .{});
}
