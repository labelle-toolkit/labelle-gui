//! Vertical splitter between the viewport column and the inspector
//! column in the scene + prefab editors (#140).
//!
//! Rendered as a thin invisible button sitting in the `split_gap`
//! between the two `beginChild` calls. When the user drags it with
//! the left mouse button, the inspector width grows or shrinks; the
//! viewport eats the remainder. `render` returns `true` on the frame
//! the drag releases — the caller persists the new width to prefs at
//! its own discretion, keeping prefs I/O out of this widget.
//!
//! Caller layout shape:
//!
//!     const viewport_w = splitter.viewportWidth(total_w, state.inspector_width, sameline_gap);
//!     beginChild "##viewport_col"  width = viewport_w
//!     endChild
//!     sameLine()
//!     const released = splitter.render(&state.inspector_width, total_w);   ← here
//!     sameLine()
//!     beginChild "##inspector_col" width = state.inspector_width
//!     endChild
//!     if (released) save_prefs(...);
//!
//! Two clamps cooperate to keep both panes usable:
//!
//!  - Inspector width never drops below `prefs.min_inspector_width`
//!    (and never exceeds `prefs.max_inspector_width`).
//!  - Viewport width is then clamped to `min_viewport_width` by the
//!    `viewportWidth` helper — if the window shrinks below the sum,
//!    the inspector visually loses pixels rather than the viewport
//!    disappearing.
//!
//! The clamp math itself lives in `clampInspectorWidth` so it's
//! testable without an imgui draw context (see `tests.zig`).

const std = @import("std");
const zgui = @import("zgui");

const prefs_mod = @import("../prefs.zig");

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

/// Width to hand to `beginChild "##viewport_col"`. Both editors
/// share this formula; centralizing it here means a layout tweak
/// (extra `sameLine`, padding shift) lands in one place instead of
/// drifting across call sites.
pub fn viewportWidth(total_w: f32, inspector_width: f32, sameline_gap: f32) f32 {
    return @max(min_viewport_width, total_w - inspector_width - handle_w - 2 * sameline_gap);
}

// zgui packs colors as ABGR: IM_COL32(R,G,B,A) = (A<<24) | (B<<16) | (G<<8) | R,
// i.e. `0xAA_BB_GG_RR`. The splitter only ever paints white-with-alpha, so a
// tiny helper keeps the literal alpha-byte readable at the call sites.
fn whiteWithAlpha(alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | 0x00_ff_ff_ff;
}

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
/// `inspector_width.*`. Returns `true` on the frame the drag
/// releases so the caller can persist the new width — the splitter
/// itself never touches prefs or the filesystem.
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
/// shape).
pub fn render(inspector_width: *f32, available_w: f32) bool {
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
        const col: u32 = if (active) whiteWithAlpha(0xff) else whiteWithAlpha(0xa0);
        dl.addRectFilled(.{ .pmin = min, .pmax = max, .col = col });
        zgui.setMouseCursor(.resize_ew);
    } else {
        // Idle: 1px vertical line centered in the strip. Subtle so it
        // doesn't compete with content, but always there.
        const cx = (min[0] + max[0]) * 0.5;
        dl.addRectFilled(.{
            .pmin = .{ cx - 0.5, min[1] },
            .pmax = .{ cx + 0.5, max[1] },
            .col = whiteWithAlpha(0x40),
        });
    }

    // Single source of truth for the clamp bounds this frame. Drag
    // handler and reactive resize handler both read from this — if
    // the math changes, both paths see the change at once.
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

    // Drag-released signal: the frame after `isItemActive` flips back
    // to false while the user still holds the button. The caller
    // owns the persistence decision (e.g. compare against prefs and
    // skip a no-op write).
    return zgui.isItemDeactivated();
}
