const std = @import("std");

/// Module interface that all plugins must implement
pub const Module = struct {
    /// Unique identifier for the module
    name: []const u8,

    /// Display name shown in UI
    display_name: []const u8,

    /// Called to render the module's menu items (if any)
    render_menu: ?*const fn () void = null,

    /// Called to render the module's panel content
    render_panel: ?*const fn () void = null,

    /// Called when module is initialized
    on_init: ?*const fn () void = null,

    /// Called when module is deinitialized
    on_deinit: ?*const fn () void = null,
};

/// Module registry - collects all registered modules at compile time
pub const Registry = struct {
    modules: []const Module,

    pub fn init(comptime modules: []const Module) Registry {
        return .{ .modules = modules };
    }

    pub fn getModule(self: *const Registry, name: []const u8) ?*const Module {
        for (self.modules) |*module| {
            if (std.mem.eql(u8, module.name, name)) {
                return module;
            }
        }
        return null;
    }

    pub fn initAll(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.on_init) |init_fn| {
                init_fn();
            }
        }
    }

    pub fn deinitAll(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.on_deinit) |deinit_fn| {
                deinit_fn();
            }
        }
    }

    pub fn renderAllMenus(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.render_menu) |render_fn| {
                render_fn();
            }
        }
    }

    pub fn renderAllPanels(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.render_panel) |render_fn| {
                render_fn();
            }
        }
    }
};
