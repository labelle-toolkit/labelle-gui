//! Preferences modal — user-scoped settings that live across projects.
//!
//! Currently surfaces one knob: `font_scale`, a multiplier applied on
//! top of the DPI-derived font size. The atlas is baked once at
//! launch at DPI-scaled base size; `font_scale` rides on top via
//! `zgui.getStyle().font_scale_main`, ImGui 1.92's per-frame draw
//! multiplier. Slider edits write the live style field so the change
//! takes effect on the next frame — no restart needed.
//!
//! Persistence is debounced: every drag frame applies the new value
//! live (visual feedback), but the platform-appropriate app-data dir
//! is written once on slider release / Reset click via `prefs.save`.
//! The next launch reads it from `prefs.loadOrDefault`.

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

    // `sliderFloat` returns true on every frame the value changed
    // during a drag — we apply the new size live each frame so the
    // user sees their slider move in real time. Disk persistence is
    // debounced to slider release (`isItemDeactivatedAfterEdit`) so
    // an interactive drag doesn't atomic-write the prefs file dozens
    // of times. Clamp on both paths so a hand-edited prefs file
    // can't push the slider past its bounds via a previous launch.
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
        applyLive(app.prefs.font_scale);
    }
    if (zgui.isItemDeactivatedAfterEdit()) {
        persist(app);
    }

    if (zgui.button("Reset to default", .{})) {
        app.prefs.font_scale = prefs_mod.default_font_scale;
        applyLive(app.prefs.font_scale);
        persist(app);
    }

    zgui.spacing();
    if (zgui.button("Close", .{ .w = 120 })) app.show_preferences = false;
}

/// Push the user's `font_scale` to ImGui's per-frame text-size
/// multiplier. The 1.92 dynamic atlas re-rasterises glyphs at the
/// new rendered size on the next frame, so text stays crisp instead
/// of bilinear-blurring through the old atlas.
fn applyLive(font_scale: f32) void {
    zgui.getStyle().font_scale_main = font_scale;
}

/// Atomic-write the current prefs to disk and surface any failure
/// through the status bar. Called once per slider-release / Reset
/// click — not on every drag frame, to keep the prefs file off the
/// disk-write hot path during interactive editing.
fn persist(app: *App) void {
    prefs_mod.save(app.allocator, app.prefs) catch |err| {
        std.log.err("prefs: save failed: {s}", .{@errorName(err)});
        app.setStatus("Could not save preferences!");
    };
}
