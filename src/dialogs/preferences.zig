//! Preferences modal — user-scoped settings that live across projects.
//!
//! Currently surfaces one knob: `font_scale`, a multiplier applied to
//! the entire UI on top of the DPI-derived base. The atlas is baked
//! once at launch at the DPI-scaled base size; `font_scale` rides on
//! top via `zgui.getStyle().font_scale_main` for text (ImGui 1.92's
//! per-frame draw multiplier) AND via `Style.scaleAllSizes` for
//! padding/spacing/borders so buttons + checkboxes track the text
//! instead of looking stranded at extreme slider values.
//!
//! Slider editing is split across two entry points to avoid the
//! Preferences modal (which is `always_auto_resize`) jittering under
//! the user's cursor mid-drag:
//!
//! - `applyDragPreview` runs on every drag frame, writes only
//!   `font_scale_main` — text rescales smoothly while the modal's
//!   bounds stay constant, so the slider knob stays put.
//! - `applyLive` runs once on slider release (and on Reset / startup),
//!   resets to the captured baseline and re-runs `scaleAllSizes` so
//!   padding/spacing snap to the final value.
//!
//! Persistence is debounced to the same release event via
//! `isItemDeactivatedAfterEdit` so an interactive drag doesn't
//! atomic-write the prefs file dozens of times. The next launch
//! reads back from `prefs.loadOrDefault`.

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

    // Pin the modal at a size large enough for the 3× extreme so the
    // window doesn't auto-resize as the slider changes `font_scale_main`
    // mid-drag — auto-resize was the root cause of the user-visible
    // flicker (modal grew/shrank → slider knob moved out from under
    // the cursor → drag delta jittered). At 1× the modal has some
    // unused vertical space; that's an explicit trade for stable drag.
    // `.always` forces the size every frame so the user can't manual-
    // resize into a too-small layout either.
    zgui.setNextWindowSize(.{ .w = 380, .h = 200, .cond = .always });
    if (!zgui.beginPopupModal("Preferences", .{
        .popen = &app.show_preferences,
        .flags = .{},
    })) return;
    defer zgui.endPopup();

    zgui.text("Font scale", .{});
    zgui.textDisabled(
        "Multiplier applied to the UI font size (on top of DPI).",
        .{},
    );

    // `sliderFloat` returns true on every frame the value changed
    // during a drag. Disk persistence is debounced to slider release
    // (`isItemDeactivatedAfterEdit`) so an interactive drag doesn't
    // atomic-write the prefs file dozens of times. Clamp on every
    // input path so a hand-edited prefs file can't push values past
    // the documented bounds.
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
        // Text-only preview during the drag — keeps widget dimensions
        // (and therefore the slider knob's screen position) constant
        // so the cursor doesn't drift off the knob mid-drag. Padding
        // catches up on release below.
        applyDragPreview(app.prefs.font_scale);
    }
    if (zgui.isItemDeactivatedAfterEdit()) {
        applyLive(app.prefs.font_scale);
        persist(app);
    }

    // Numeric entry for the user who knows the exact value they want.
    // ImGui's `inputFloat` already fires its return value only on
    // commit (Enter, focus-loss, or a step button click) — it
    // explicitly asserts `EnterReturnsTrue` is NOT set, since the
    // widget owns its own commit timing. So the callback fires once
    // per committed edit, and we treat each like a slider release:
    // full scale apply + persist, no per-keystroke disk writes.
    var typed: f32 = app.prefs.font_scale;
    zgui.setNextItemWidth(120);
    if (zgui.inputFloat("##font_scale_input", .{
        .v = &typed,
        .step = 0.05,
        .step_fast = 0.25,
        .cfmt = "%.2f",
    })) {
        app.prefs.font_scale = std.math.clamp(
            typed,
            prefs_mod.min_font_scale,
            prefs_mod.max_font_scale,
        );
        applyLive(app.prefs.font_scale);
        persist(app);
    }

    zgui.spacing();
    if (zgui.button("Reset to default", .{})) {
        app.prefs.font_scale = prefs_mod.default_font_scale;
        // Single click — no drag to keep stable. Full scale immediately.
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
/// and the dialog uses it on slider release / Reset click.
pub fn applyLive(font_scale: f32) void {
    const style = zgui.getStyle();
    if (baseline_style == null) baseline_style = style.*;
    style.* = baseline_style.?;
    style.scaleAllSizes(font_scale);
    style.font_scale_main = font_scale;
}

/// Text-only preview for mid-drag use: writes `font_scale_main` so
/// glyphs re-rasterise next frame, but leaves padding/spacing/borders
/// alone. Calling `scaleAllSizes` on every drag frame resizes the
/// Preferences modal (it's `always_auto_resize`) every frame, which
/// shifts the slider knob out from under the user's cursor mid-drag
/// and produces visible jitter / flicker. Drag uses this entry; the
/// slider's `isItemDeactivatedAfterEdit` then calls `applyLive` once
/// on release so the rest of the UI catches up to the final value.
pub fn applyDragPreview(font_scale: f32) void {
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
