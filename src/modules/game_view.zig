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

fn renderViewport(app: *App) void {
    zgui.setNextWindowSize(.{ .w = 720, .h = 460, .cond = .first_use_ever });
    if (!zgui.begin("Game View", .{ .popen = &app.show_game_view, .flags = .{} })) {
        zgui.end();
        return;
    }
    defer zgui.end();

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
    zgui.image(tex_ref, .{ .w = draw_w, .h = draw_h });
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
