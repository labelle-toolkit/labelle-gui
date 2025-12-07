/// Color Plugin - Provides color data to host
const std = @import("std");

const PLUGIN_API_VERSION: u32 = 1;

const PluginType = enum(u8) {
    counter = 0,
    color = 1,
    generic = 255,
};

const PluginInfo = extern struct {
    api_version: u32,
    name: [*:0]const u8,
    display_name: [*:0]const u8,
    version: [*:0]const u8,
    plugin_type: PluginType,
};

const ColorData = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    brightness: f32,
};

const plugin_info = PluginInfo{
    .api_version = PLUGIN_API_VERSION,
    .name = "color_plugin",
    .display_name = "Color Picker",
    .version = "1.0.0",
    .plugin_type = .color,
};

var color_data = ColorData{
    .r = 1.0,
    .g = 0.5,
    .b = 0.2,
    .a = 1.0,
    .brightness = 1.0,
};

export fn plugin_get_info() *const PluginInfo {
    return &plugin_info;
}

export fn plugin_init() void {
    std.debug.print("[ColorPlugin] Initialized!\n", .{});
}

export fn plugin_deinit() void {
    std.debug.print("[ColorPlugin] Deinitialized!\n", .{});
}

export fn plugin_get_color_data() *ColorData {
    return &color_data;
}
