/// Plugin API - shared between host and plugins
/// This defines the ABI contract for dynamic plugins

pub const PLUGIN_API_VERSION: u32 = 1;

/// Plugin information structure
pub const PluginInfo = extern struct {
    api_version: u32,
    name: [*:0]const u8,
    display_name: [*:0]const u8,
    version: [*:0]const u8,
};

/// Function pointer types for plugin callbacks
pub const InitFn = *const fn () callconv(.c) void;
pub const DeinitFn = *const fn () callconv(.c) void;
pub const RenderMenuFn = *const fn () callconv(.c) void;
pub const RenderPanelFn = *const fn () callconv(.c) void;
pub const GetInfoFn = *const fn () callconv(.c) *const PluginInfo;

/// Symbols that plugins must export
pub const SYMBOL_GET_INFO = "plugin_get_info";
pub const SYMBOL_INIT = "plugin_init";
pub const SYMBOL_DEINIT = "plugin_deinit";
pub const SYMBOL_RENDER_MENU = "plugin_render_menu";
pub const SYMBOL_RENDER_PANEL = "plugin_render_panel";
