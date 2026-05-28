//! Preferences modal — user-scoped settings that live across projects.
//!
//! Currently surfaces one knob: `font_scale`, a multiplier applied to
//! the entire UI on top of the DPI-derived base. The atlas is baked
//! once at launch at the DPI-scaled base size; `font_scale` rides on
//! top via `zgui.getStyle().font_scale_main` for text (ImGui 1.92's
//! per-frame draw multiplier) AND via `Style.scaleAllSizes` for
//! padding/spacing/borders so buttons + checkboxes track the text
//! instead of looking stranded at extreme slider values. Slider edits
//! re-enter the same code path so the change takes effect on the next
//! frame — no restart needed.
//!
//! Persistence is debounced: every drag frame applies the new value
//! live (visual feedback), but the platform-appropriate app-data dir
//! is written once on slider release / Reset click via `prefs.save`.
//! The next launch reads it from `prefs.loadOrDefault`.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const prefs_mod = @import("../prefs.zig");

/// Snapshot of `Style` taken on the first `applyLive` call, before any
/// font-scale multiplier has been applied. Resets to this on every
/// subsequent call so we scale relative to the DPI-only baseline
/// instead of compounding (`scaleAllSizes(2)` then `scaleAllSizes(0.5)`
/// would otherwise leave padding at 1× DPI when it should be 0.5×).
var baseline_style: ?zgui.Style = null;

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

/// Apply the user's `font_scale` to the entire ImGui style — text via
/// `font_scale_main` (the 1.92 dynamic atlas re-rasterises glyphs at
/// the new rendered size next frame, so text stays crisp) AND
/// padding/spacing/border sizes via `scaleAllSizes` so controls track
/// the text instead of looking stranded at extreme values.
///
/// First call captures the current style as the post-DPI baseline.
/// Subsequent calls reset to that baseline then re-scale, so the
/// transform is idempotent (`applyLive(2.0)` then `applyLive(0.5)`
/// lands at exactly 0.5× DPI, not 1× DPI from compounded scales).
/// Pub so `main.zig` calls it once at startup for the saved value
/// and the dialog's slider re-enters it for live edits.
pub fn applyLive(font_scale: f32) void {
    const style = zgui.getStyle();
    if (baseline_style == null) baseline_style = style.*;
    style.* = baseline_style.?;
    style.scaleAllSizes(font_scale);
    style.font_scale_main = font_scale;
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
