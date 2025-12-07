const zgui = @import("zgui");

/// Module interface for ImGui-based panels and menus
pub const Module = struct {
    name: []const u8,
    display_name: [:0]const u8,

    /// Render menu items (called inside a menu)
    render_menu: ?*const fn () void = null,

    /// Render panel content (called inside a window)
    render_panel: ?*const fn () void = null,

    /// Check if panel should be shown
    is_open: *bool,

    /// Called once on initialization
    on_init: ?*const fn () void = null,

    /// Called once on shutdown
    on_deinit: ?*const fn () void = null,
};

/// Registry of compile-time modules
pub const Registry = struct {
    modules: []const Module,

    pub fn init(comptime modules: []const Module) Registry {
        return .{ .modules = modules };
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

    /// Render the View menu with module toggles
    pub fn renderViewMenu(self: *const Registry) void {
        if (zgui.beginMenu("View", true)) {
            for (self.modules) |module| {
                if (zgui.menuItem(module.display_name, .{ .selected = module.is_open.* })) {
                    module.is_open.* = !module.is_open.*;
                }
            }
            zgui.endMenu();
        }
    }

    /// Render custom menu items from all modules
    pub fn renderAllMenus(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.render_menu) |render_fn| {
                render_fn();
            }
        }
    }

    /// Render all open panels as separate windows
    pub fn renderAllPanels(self: *const Registry) void {
        for (self.modules) |module| {
            if (module.is_open.*) {
                if (module.render_panel) |render_fn| {
                    if (zgui.begin(module.display_name, .{ .popen = module.is_open })) {
                        render_fn();
                    }
                    zgui.end();
                }
            }
        }
    }
};
