/// Counter Plugin - Provides counter data to host
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

const CounterData = extern struct {
    value: i32,
    min_value: i32,
    max_value: i32,
};

const plugin_info = PluginInfo{
    .api_version = PLUGIN_API_VERSION,
    .name = "counter_plugin",
    .display_name = "Counter",
    .version = "1.0.0",
    .plugin_type = .counter,
};

var counter_data = CounterData{
    .value = 0,
    .min_value = -100,
    .max_value = 100,
};

export fn plugin_get_info() *const PluginInfo {
    return &plugin_info;
}

export fn plugin_init() void {
    std.debug.print("[CounterPlugin] Initialized!\n", .{});
    counter_data.value = 0;
}

export fn plugin_deinit() void {
    std.debug.print("[CounterPlugin] Deinitialized! Final count: {}\n", .{counter_data.value});
}

export fn plugin_get_counter_data() *CounterData {
    return &counter_data;
}
