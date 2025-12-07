const std = @import("std");
const builtin = @import("builtin");
const api = @import("plugin_api.zig");

const DynLib = std.DynLib;

/// Loaded plugin instance
const LoadedPlugin = struct {
    handle: DynLib,
    info: *const api.PluginInfo,
    init_fn: ?api.InitFn,
    deinit_fn: ?api.DeinitFn,
    render_menu_fn: ?api.RenderMenuFn,
    render_panel_fn: ?api.RenderPanelFn,

    pub fn load(path: []const u8) !LoadedPlugin {
        var handle = try DynLib.open(path);
        errdefer handle.close();

        // Get plugin info
        const get_info_fn = handle.lookup(api.GetInfoFn, api.SYMBOL_GET_INFO) orelse {
            return error.MissingGetInfo;
        };

        const info = get_info_fn();

        // Verify API version
        if (info.api_version != api.PLUGIN_API_VERSION) {
            return error.IncompatibleVersion;
        }

        return LoadedPlugin{
            .handle = handle,
            .info = info,
            .init_fn = handle.lookup(api.InitFn, api.SYMBOL_INIT),
            .deinit_fn = handle.lookup(api.DeinitFn, api.SYMBOL_DEINIT),
            .render_menu_fn = handle.lookup(api.RenderMenuFn, api.SYMBOL_RENDER_MENU),
            .render_panel_fn = handle.lookup(api.RenderPanelFn, api.SYMBOL_RENDER_PANEL),
        };
    }

    pub fn unload(self: *LoadedPlugin) void {
        self.handle.close();
    }

    pub fn init(self: *const LoadedPlugin) void {
        if (self.init_fn) |f| f();
    }

    pub fn deinit(self: *const LoadedPlugin) void {
        if (self.deinit_fn) |f| f();
    }

    pub fn renderMenu(self: *const LoadedPlugin) void {
        if (self.render_menu_fn) |f| f();
    }

    pub fn renderPanel(self: *const LoadedPlugin) void {
        if (self.render_panel_fn) |f| f();
    }
};

pub fn main() !void {
    std.debug.print("=== Dynamic Loading Plugin System Spike ===\n\n", .{});

    // Determine library path based on platform
    const lib_name = switch (builtin.os.tag) {
        .macos => "zig-out/lib/libexample_plugin.dylib",
        .linux => "zig-out/lib/libexample_plugin.so",
        .windows => "zig-out/bin/example_plugin.dll",
        else => @compileError("Unsupported platform"),
    };

    std.debug.print("Loading plugin: {s}\n", .{lib_name});

    var plugin = LoadedPlugin.load(lib_name) catch |err| {
        std.debug.print("Failed to load plugin: {}\n", .{err});
        return err;
    };
    defer plugin.unload();

    const name = std.mem.span(plugin.info.name);
    const display_name = std.mem.span(plugin.info.display_name);
    const version = std.mem.span(plugin.info.version);

    std.debug.print("Loaded: {s} ({s}) v{s}\n", .{ display_name, name, version });
    std.debug.print("API version: {}\n\n", .{plugin.info.api_version});

    // Initialize
    std.debug.print("Initializing plugin...\n", .{});
    plugin.init();
    std.debug.print("\n", .{});

    // Simulate render loop
    std.debug.print("Simulating render loop (3 frames)...\n", .{});
    for (0..3) |frame| {
        std.debug.print("\n--- Frame {} ---\n", .{frame});
        plugin.renderMenu();
        plugin.renderPanel();
    }
    std.debug.print("\n", .{});

    // Deinitialize
    std.debug.print("Deinitializing plugin...\n", .{});
    plugin.deinit();

    std.debug.print("\n=== Spike Complete ===\n", .{});
}
