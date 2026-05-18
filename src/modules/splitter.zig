//! Vertical splitter between the viewport column and the inspector
//! column in the scene + prefab editors (#140).
//!
//! Rendered as a thin invisible button sitting in the `split_gap`
//! between the two `beginChild` calls. When the user drags it with
//! the left mouse button, the inspector width grows or shrinks; the
//! viewport eats the remainder. On drag-release, the new width is
//! persisted to prefs so it sticks across editor restarts.
//!
//! Caller layout shape:
//!
//!     beginChild "##viewport_col"  width = viewport_w
//!     endChild
//!     sameLine()
//!     splitter.render(&state.inspector_width, total_w, app)   ← here
//!     sameLine()
//!     beginChild "##inspector_col" width = state.inspector_width
//!     endChild
//!
//! Two clamps cooperate to keep both panes usable:
//!
//!  - Inspector width never drops below `prefs.min_inspector_width`
//!    (and never exceeds `prefs.max_inspector_width`).
//!  - Viewport width is then clamped to `min_viewport_width` by the
//!    caller's existing `@max(min_viewport_width, total_w - inspector_w - gap)`
//!    formula — if the window shrinks below the sum, the inspector
//!    visually loses pixels rather than the viewport disappearing.
//!
//! The clamp math itself lives in `clampInspectorWidth` so it's
//! testable without an imgui draw context (see `tests.zig`).

const std = @import("std");
const zgui = @import("zgui");

const prefs_mod = @import("../prefs.zig");
const App = @import("../app.zig").App;

/// Horizontal pixels for the splitter handle. Wide enough to grab
/// comfortably; narrow enough not to dominate the gap. The visual
/// handle is drawn inside this strip; the click target is the full
/// width.
pub const handle_w: f32 = 6;

/// Minimum viewport width on the *other* side of the splitter. The
/// caller's `viewport_w` formula already enforces this; we only use
/// it here to decide how much the user can shrink the inspector
/// without squashing the viewport beyond reason.
pub const min_viewport_width: f32 = 120;

/// Clamp a requested inspector width to the bounds the splitter
/// enforces every frame. Pulled out of `render` so the clamp math
/// can be unit-tested without an imgui draw context (see
/// `SplitterClampTests` in `tests.zig`).
///
/// The clamp is bounded by three numbers:
///
///   - `prefs_mod.min_inspector_width` — hard floor; the inspector
///     never gets thinner than this so its widgets stay usable.
///   - `prefs_mod.max_inspector_width` — hard static ceiling so a
///     hand-edited prefs file with a wild value can't fill the
///     screen with inspector chrome.
///   - `available_w - min_viewport_width - handle_w - 2*sameline_gap`
///     — dynamic ceiling that adapts to the current window width.
///     When the editor shrinks, this reins the inspector back in on
///     the same frame.
///
/// The dynamic ceiling AND the static ceiling are combined via
/// `@min`, so whichever is tighter wins. The floor is enforced by
/// `@max` against the dynamic upper so we never produce a value
/// below the minimum even when the window is very small.
pub fn clampInspectorWidth(value: f32, available_w: f32, sameline_gap: f32) f32 {
    const dynamic_upper = available_w - min_viewport_width - handle_w - 2 * sameline_gap;
    // `@max` against the floor keeps the upper bound from collapsing
    // below the minimum when the window has no room for an inspector
    // at all — better to render a tiny inspector and let the viewport
    // get squashed than to flip the clamp range upside-down.
    const upper = @max(prefs_mod.min_inspector_width, dynamic_upper);
    return std.math.clamp(
        value,
        prefs_mod.min_inspector_width,
        @min(prefs_mod.max_inspector_width, upper),
    );
}

/// Render the splitter handle and apply drag deltas to
/// `inspector_width.*`. On mouse-release after a drag, syncs the
/// chosen width to `app.prefs` and persists it.
///
/// `available_w` is the total row width the two columns + handle
/// share (typically the parent's `getContentRegionAvail()[0]`
/// captured before the viewport child is rendered). The splitter
/// uses it to enforce a dynamic upper bound so the inspector can't
/// be dragged past what the current window can hold — when the
/// editor window shrinks, this also reins in a too-wide inspector
/// on the same frame.
///
/// The caller is responsible for placing the handle on the right
/// line via `sameLine()` (see the doc comment above for the layout
/// shape). Returns nothing — width mutations are written through
/// the pointer.
pub fn render(inspector_width: *f32, available_w: f32, app: *App) void {
    // Match the viewport/inspector children's height so the handle
    // spans the full split. Heights of 0 in beginChild mean "fill
    // remaining," and the children here use that — so the handle
    // does the same via getContentRegionAvail.
    const h = zgui.getContentRegionAvail()[1];
    _ = zgui.invisibleButton("##inspector_splitter", .{
        .w = handle_w,
        .h = h,
        .flags = .{ .mouse_button_left = true },
    });

    // Visual cue: always render a thin idle line down the middle of
    // the handle strip so the user can see where the resize lives —
    // matches the ImGui-native window-resize affordance the project
    // tree side uses. On hover/active, fill the whole strip + swap
    // the cursor to a horizontal-resize arrow so it's obvious it's
    // grabbable.
    const hovered = zgui.isItemHovered(.{});
    const active = zgui.isItemActive();
    const dl = zgui.getWindowDrawList();
    const min = zgui.getItemRectMin();
    const max = zgui.getItemRectMax();
    if (hovered or active) {
        const col: u32 = if (active) 0xff_ff_ff_ff else 0xa0_ff_ff_ff;
        dl.addRectFilled(.{ .pmin = min, .pmax = max, .col = col });
        zgui.setMouseCursor(.resize_ew);
    } else {
        // Idle: 1px vertical line centered in the strip. Subtle so it
        // doesn't compete with content, but always there.
        const cx = (min[0] + max[0]) * 0.5;
        dl.addRectFilled(.{
            .pmin = .{ cx - 0.5, min[1] },
            .pmax = .{ cx + 0.5, max[1] },
            .col = 0x40_ff_ff_ff,
        });
    }

    // Single source of truth for the clamp bounds this frame. Drag
    // handler and reactive resize handler both read from this — if
    // the math changes, both paths see the change at once (gemini /
    // PR review #142 catch).
    const sameline_gap = zgui.getStyle().item_spacing[0];

    // Drag handling: accumulate the per-frame X delta into the
    // stored width. `getMouseDragDelta` returns *cumulative* delta
    // since the press, so we reset after each consumption to avoid
    // double-applying. Inspector lives on the right of the splitter —
    // a leftward drag (negative dx) widens it; rightward narrows it.
    if (active and zgui.isMouseDragging(.left, 0)) {
        const d = zgui.getMouseDragDelta(.left, .{});
        inspector_width.* = clampInspectorWidth(inspector_width.* - d[0], available_w, sameline_gap);
        zgui.resetMouseDragDelta(.left);
    }

    // Re-clamp every frame so a window-shrink event correctly reins
    // in an inspector that's now too wide for the row. Without this,
    // the inspector would only update on the next drag.
    inspector_width.* = clampInspectorWidth(inspector_width.*, available_w, sameline_gap);

    // Persist on release. We compare against the prefs value so a
    // hover-without-drag doesn't churn the file. The drag-released
    // signal is the frame after isItemActive flips back to false
    // while we still hold the button — but isItemDeactivated covers
    // exactly that.
    if (zgui.isItemDeactivated()) {
        if (app.prefs.inspector_width != inspector_width.*) {
            app.prefs.inspector_width = inspector_width.*;
            prefs_mod.save(app.allocator, app.prefs) catch |err| {
                std.log.warn("prefs: could not persist inspector_width: {s}", .{@errorName(err)});
            };
        }
    }
}
