//! Preferences modal — user-scoped settings that live across projects.
//!
//! Currently surfaces one knob: `font_scale`, a multiplier applied on
//! top of the DPI-derived font size at startup. ImGui's font atlas is
//! sized once at app launch and rebuilt only on shutdown / restart, so
//! a change here does NOT take effect mid-session. The dialog flags a
//! "Restart to apply" line when the live value diverges from what was
//! loaded at startup, matching the existing DPI-change UX in
//! `dpi_warning.zig`.
//!
//! Persistence is per-edit: every slider tick writes the new value to
//! the platform-appropriate app-data dir via `prefs.save`. The next
//! launch reads it from `prefs.loadOrDefault`.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const prefs_mod = @import("../prefs.zig");

pub fn render(app: *App) void {
    if (app.show_preferences) zgui.openPopup("Preferences", .{});
    if (!zgui.beginPopupModal("Preferences", .{
        .popen = &app.show_preferences,
        .flags = .{ .always_auto_resize = true },
    })) return;
    defer zgui.endPopup();

    zgui.text("Font scale", .{});
    zgui.textDisabled(
        "Multiplier applied to the UI font size (on top of DPI).",
        .{},
    );

    // `sliderFloat` returns true on the frames the value changed. We
    // clamp before persisting so a hand-edited prefs file can't push the
    // slider past its bounds via a previous launch.
    var v: f32 = app.prefs.font_scale;
    const changed = zgui.sliderFloat("##font_scale", .{
        .v = &v,
        .min = prefs_mod.min_font_scale,
        .max = prefs_mod.max_font_scale,
        .cfmt = "%.2fx",
    });
    if (changed) {
        app.prefs.font_scale = std.math.clamp(
            v,
            prefs_mod.min_font_scale,
            prefs_mod.max_font_scale,
        );
        prefs_mod.save(app.allocator, app.prefs) catch |err| {
            std.log.err("prefs: save failed: {s}", .{@errorName(err)});
            app.setStatus("Could not save preferences!");
        };
    }

    if (zgui.button("Reset to default", .{})) {
        app.prefs.font_scale = prefs_mod.default_font_scale;
        prefs_mod.save(app.allocator, app.prefs) catch |err| {
            std.log.err("prefs: save failed: {s}", .{@errorName(err)});
            app.setStatus("Could not save preferences!");
        };
    }

    zgui.spacing();
    zgui.separator();
    zgui.spacing();

    if (app.prefs.font_scale != app.startup_prefs.font_scale) {
        zgui.textColored(
            .{ 1.0, 0.78, 0.25, 1.0 },
            "Restart the app for changes to take effect.",
            .{},
        );
    } else {
        zgui.textDisabled("No pending changes.", .{});
    }

    zgui.spacing();
    if (zgui.button("Close", .{ .w = 120 })) app.show_preferences = false;
}
