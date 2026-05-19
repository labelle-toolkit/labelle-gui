//! Game View panel — renders the live game frames the engine is
//! streaming through the PIE viewport pixel ring (#107).
//!
//! Two ImGui windows, both gated on `app.show_game_view`:
//!
//!   - "Game View"    : `zgui.image(...)` of the frame texture,
//!                      aspect-fit inside the available content
//!                      region.
//!   - "Game Stats"   : last/avg latency, presented FPS, dropped
//!                      frames, producer frame index.
//!
//! When the panel is open but the consumer hasn't attached yet,
//! the "Game View" window shows a paragraph explaining how to
//! attach — currently a manual hand-off via `App.attachGameView`
//! (or the `LABELLE_GAME_VIEW_SHM` environment variable on
//! startup). Auto-attach from a live `PreviewSession` is the
//! follow-up ticket (#107's body notes the existing transport
//! is stubbed pending #543/#544 merge).

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "game_view",
        .display_name = "Game View",
        .is_open = &app.show_game_view,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    // Drive the upload first so the stats window reads fresh values.
    _ = app.game_view.poll();

    renderViewport(app);
    renderStats(app);
}

/// Tab-mode entry — called from `OpenTab.render` when the active tab
/// is `.game_view`. The parent tab strip already wraps the body in a
/// window, so no `zgui.begin`/`end` here. Stats live in their own
/// floating window (still gated on `show_game_view`) so the user can
/// dock them wherever; the tab body is just the live frame.
pub fn renderTab(app: *App) void {
    _ = app.game_view.poll();
    renderViewportContent(app);
}

fn renderViewport(app: *App) void {
    zgui.setNextWindowSize(.{ .w = 720, .h = 460, .cond = .first_use_ever });
    if (!zgui.begin("Game View", .{ .popen = &app.show_game_view, .flags = .{} })) {
        zgui.end();
        return;
    }
    defer zgui.end();
    renderViewportContent(app);
}

// ── Drag-release tracking (cursor finding on labelle-gui#146) ──
// `isMouseReleased` was previously nested under `isItemHovered`, so a
// press-on-image → drag-off → release-outside sequence dropped the
// `down=false` event and the engine saw the button stuck down forever.
// We now track which buttons have an outstanding `down=true` that we
// emitted, and flush a `down=false` on the release frame regardless of
// hover. We also stash the last in-image IOSurface coords so the
// release-outside path can resend `sendMousePos` for positional
// context (the engine pairs button events with the most recent pos).
var button_down_sent: [3]bool = .{ false, false, false };
var last_in_image_sx: f32 = 0.0;
var last_in_image_sy: f32 = 0.0;

/// Inner content — drawn either inside the tab's container OR inside
/// the standalone panel's begin/end. No window chrome here.
fn renderViewportContent(app: *App) void {
    if (!app.game_view.isAttached()) {
        zgui.textWrapped(
            \\No engine attached.
            \\
            \\To watch a running game, either set the
            \\LABELLE_GAME_VIEW_SHM environment variable to the
            \\SHM name advertised in the engine's `frame_offer`
            \\and restart the editor, or call
            \\`App.attachGameView` from your wiring.
            \\
            \\Auto-attach from a live `PreviewSession` is tracked
            \\as a follow-up — the preview transport itself is
            \\currently stubbed (zig-0.16 migration).
            ,
            .{},
        );
        return;
    }

    const avail = zgui.getContentRegionAvail();
    const src_w: f32 = @floatFromInt(app.game_view.tex_w);
    const src_h: f32 = @floatFromInt(app.game_view.tex_h);
    // Guard the aspect-fit divisions: a tiny / collapsed window can
    // give a zero `avail[]`, and a malformed SHM header could (in
    // theory) hand us zero dims. Either lands NaN/inf in
    // `draw_w` / `draw_h` and inside `zgui.image` (#111 review).
    // Floor each dimension at 1 px so the math is well-defined; the
    // resulting image is invisible but the panel keeps rendering.
    const safe_src_w = @max(src_w, 1.0);
    const safe_src_h = @max(src_h, 1.0);
    const safe_avail_w = @max(avail[0], 1.0);
    const safe_avail_h = @max(avail[1], 1.0);
    // Aspect-fit inside the available content region; centre the
    // image rather than stretching to the panel dimensions.
    const aspect_src = safe_src_w / safe_src_h;
    const aspect_avail = safe_avail_w / safe_avail_h;
    var draw_w: f32 = safe_avail_w;
    var draw_h: f32 = safe_avail_h;
    if (aspect_src > aspect_avail) {
        draw_h = safe_avail_w / aspect_src;
    } else {
        draw_w = safe_avail_h * aspect_src;
    }
    // Centre with an InvisibleButton offset before the image.
    const dx = (avail[0] - draw_w) * 0.5;
    const dy = (avail[1] - draw_h) * 0.5;
    if (dx > 0 or dy > 0) {
        const cur = zgui.getCursorPos();
        zgui.setCursorPos(.{ cur[0] + dx, cur[1] + dy });
    }

    const tex_ref: zgui.TextureRef = .{
        .tex_data = null,
        .tex_id = @enumFromInt(@as(u64, app.game_view.tex_id)),
    };
    // Capture the image's screen-rect *before* drawing so we can map
    // mouse coords back into IOSurface space for the input-uplink
    // (labelle-assembler#143). `getCursorScreenPos` returns the
    // top-left of the next widget — that's the image origin.
    const img_screen_pos = zgui.getCursorScreenPos();
    zgui.image(tex_ref, .{ .w = draw_w, .h = draw_h });

    // ── Mouse → game input uplink (#143) ──
    // Hover-gated half: position uplink + click detection. Clicks only
    // count when the press starts on the image — otherwise UI clicks
    // anywhere on the editor would bleed into the game.
    if (zgui.isItemHovered(.{})) {
        const mp = zgui.getMousePos();
        const dx_img = mp[0] - img_screen_pos[0];
        const dy_img = mp[1] - img_screen_pos[1];
        const scale_x = src_w / draw_w;
        const scale_y = src_h / draw_h;
        const sx: f32 = dx_img * scale_x;
        const sy: f32 = dy_img * scale_y;
        app.preview.sendMousePos(sx, sy);
        // Stash for the release-outside path below.
        last_in_image_sx = sx;
        last_in_image_sy = sy;

        // ImGui mouse buttons: 0 = left, 1 = right, 2 = middle.
        // `isMouseClicked` fires on the exact frame of the press
        // transition; the matching `down=false` is sent below
        // regardless of hover (cursor finding on labelle-gui#146).
        inline for (.{
            .{ .btn = zgui.MouseButton.left, .idx = @as(i32, 0) },
            .{ .btn = zgui.MouseButton.right, .idx = @as(i32, 1) },
            .{ .btn = zgui.MouseButton.middle, .idx = @as(i32, 2) },
        }) |entry| {
            if (zgui.isMouseClicked(entry.btn)) {
                app.preview.sendMouseButton(entry.idx, true);
                button_down_sent[@intCast(entry.idx)] = true;
            }
        }
    }

    // Release flush — runs every frame, hover or not. If we ever sent
    // a `down=true` via this tab and ImGui now reports the release,
    // mirror a `down=false` so the engine doesn't keep the button
    // stuck after a press-drag-off-release. Pair it with one final
    // `sendMousePos` at the last in-image coord so the engine has
    // positional context for the click (#146).
    inline for (.{
        .{ .btn = zgui.MouseButton.left, .idx = @as(i32, 0) },
        .{ .btn = zgui.MouseButton.right, .idx = @as(i32, 1) },
        .{ .btn = zgui.MouseButton.middle, .idx = @as(i32, 2) },
    }) |entry| {
        const slot: usize = @intCast(entry.idx);
        if (button_down_sent[slot] and zgui.isMouseReleased(entry.btn)) {
            app.preview.sendMousePos(last_in_image_sx, last_in_image_sy);
            app.preview.sendMouseButton(entry.idx, false);
            button_down_sent[slot] = false;
        }
    }
}

fn renderStats(app: *App) void {
    zgui.setNextWindowSize(.{ .w = 280, .h = 180, .cond = .first_use_ever });
    if (!zgui.begin("Game Stats", .{ .popen = &app.show_game_view, .flags = .{} })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    if (!app.game_view.isAttached()) {
        zgui.text("Not attached.", .{});
        return;
    }

    const ns_per_ms: f64 = 1_000_000.0;
    const last_ms: f64 = @as(f64, @floatFromInt(app.game_view.last_latency_ns)) / ns_per_ms;
    const mean_ms: f64 = @as(f64, @floatFromInt(app.game_view.meanLatencyNs())) / ns_per_ms;

    if (app.game_view.last_frame_idx) |idx|
        zgui.text("frame_idx = {d}", .{idx})
    else
        zgui.text("frame_idx = (waiting for first frame)", .{});
    zgui.text("presented = {d}", .{app.game_view.presented});
    zgui.text("dropped   = {d}", .{app.game_view.dropped});
    zgui.text("dims      = {d}x{d}", .{ app.game_view.tex_w, app.game_view.tex_h });
    zgui.separator();
    zgui.text("last latency  = {d:.2} ms", .{last_ms});
    zgui.text("avg latency   = {d:.2} ms ({d} samples)", .{ mean_ms, app.game_view.latency_count });
}
