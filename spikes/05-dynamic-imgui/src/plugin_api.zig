/// Plugin API for dynamic ImGui plugins
/// Plugins provide data/state, host does ImGui rendering
const std = @import("std");

pub const PLUGIN_API_VERSION: u32 = 1;

/// Plugin metadata - must be extern for ABI stability
pub const PluginInfo = extern struct {
    api_version: u32,
    name: [*:0]const u8,
    display_name: [*:0]const u8,
    version: [*:0]const u8,
    plugin_type: PluginType,
};

pub const PluginType = enum(u8) {
    counter = 0,
    color = 1,
    generic = 255,
};

/// Counter plugin data
pub const CounterData = extern struct {
    value: i32,
    min_value: i32,
    max_value: i32,
};

/// Color plugin data
pub const ColorData = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    brightness: f32,
};

/// Function pointer types
pub const GetInfoFn = *const fn () callconv(.c) *const PluginInfo;
pub const InitFn = *const fn () callconv(.c) void;
pub const DeinitFn = *const fn () callconv(.c) void;
pub const GetCounterDataFn = *const fn () callconv(.c) *CounterData;
pub const GetColorDataFn = *const fn () callconv(.c) *ColorData;

/// Loaded plugin instance
pub const LoadedPlugin = struct {
    handle: std.DynLib,
    info: *const PluginInfo,
    on_deinit: ?DeinitFn,
    get_counter_data: ?GetCounterDataFn,
    get_color_data: ?GetColorDataFn,
    is_open: bool = true,

    pub fn getName(self: *const LoadedPlugin) [:0]const u8 {
        return std.mem.span(self.info.name);
    }

    pub fn getDisplayName(self: *const LoadedPlugin) [:0]const u8 {
        return std.mem.span(self.info.display_name);
    }

    pub fn deinit(self: *LoadedPlugin) void {
        if (self.on_deinit) |deinit_fn| {
            deinit_fn();
        }
        self.handle.close();
    }
};

/// Load a plugin from a dynamic library
pub fn loadPlugin(path: []const u8) !LoadedPlugin {
    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    // Get required symbols
    const get_info = lib.lookup(GetInfoFn, "plugin_get_info") orelse {
        return error.MissingSymbol;
    };

    const info = get_info();

    // Verify API version
    if (info.api_version != PLUGIN_API_VERSION) {
        return error.IncompatibleApiVersion;
    }

    // Get optional symbols
    const on_init = lib.lookup(InitFn, "plugin_init");
    const on_deinit = lib.lookup(DeinitFn, "plugin_deinit");
    const get_counter_data = lib.lookup(GetCounterDataFn, "plugin_get_counter_data");
    const get_color_data = lib.lookup(GetColorDataFn, "plugin_get_color_data");

    // Initialize plugin
    if (on_init) |init_fn| {
        init_fn();
    }

    return LoadedPlugin{
        .handle = lib,
        .info = info,
        .on_deinit = on_deinit,
        .get_counter_data = get_counter_data,
        .get_color_data = get_color_data,
    };
}
