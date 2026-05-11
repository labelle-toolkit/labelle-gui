//! DPI change warning modal. Set `app.show_dpi_warning = true` from the
//! GLFW content-scale callback in `main.zig`; this dialog handles the
//! one-shot display + dismiss.

const zgui = @import("zgui");

const App = @import("../app.zig").App;

pub fn render(app: *App) void {
    if (app.show_dpi_warning) zgui.openPopup("Display Scale Changed", .{});
    if (!zgui.beginPopupModal("Display Scale Changed", .{
        .popen = &app.show_dpi_warning,
        .flags = .{ .always_auto_resize = true },
    })) return;
    defer zgui.endPopup();

    zgui.text("The display scale has changed.", .{});
    zgui.text("For best results, please restart the application.", .{});
    zgui.spacing();
    zgui.separator();
    zgui.spacing();
    if (zgui.button("OK", .{ .w = 120 })) app.show_dpi_warning = false;
}
