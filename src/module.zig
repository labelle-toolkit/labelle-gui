//! Compile-time module / panel registry (issue #22).
//!
//! Each module owns a togglable panel and reports its display label to the
//! main menu bar's View menu. The `is_open` pointer is shared between the
//! menu toggle and the panel's `popen` flag, so closing the panel window
//! and unchecking the menu item stay in sync.
//!
//! State backing `is_open` is held by `App` (so two `App` instances — main
//! window and the TE test runner — don't fight over a single global). Each
//! module's `makeModule(app)` wires up the pointers when the App is
//! constructed.

const zgui = @import("zgui");
const App = @import("app.zig").App;

pub const Module = struct {
    name: []const u8,
    display_name: [:0]const u8,
    is_open: *bool,
    render_panel: ?*const fn (*App) void = null,
    on_init: ?*const fn (*App) void = null,
    on_deinit: ?*const fn (*App) void = null,
};

pub const Registry = struct {
    modules: []const Module,

    pub fn initAll(self: Registry, app: *App) void {
        for (self.modules) |m| if (m.on_init) |f| f(app);
    }

    pub fn deinitAll(self: Registry, app: *App) void {
        for (self.modules) |m| if (m.on_deinit) |f| f(app);
    }

    pub fn renderViewMenu(self: Registry) void {
        if (!zgui.beginMenu("View", true)) return;
        defer zgui.endMenu();
        for (self.modules) |m| {
            if (zgui.menuItem(m.display_name, .{ .selected = m.is_open.* })) {
                m.is_open.* = !m.is_open.*;
            }
        }
    }

    pub fn renderAllPanels(self: Registry, app: *App) void {
        for (self.modules) |m| {
            if (m.is_open.*) if (m.render_panel) |f| f(app);
        }
    }
};
