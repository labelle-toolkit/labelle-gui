//! Compiler Output panel — first module wired through the Registry.
//!
//! The panel docks to the bottom edge of the work area when open, shows the
//! current compiler state, and streams the last `labelle build/run`
//! invocation's stdout/stderr. The `Build` menu also flips `is_open` to
//! true when the user starts a build, which auto-surfaces the panel.
//!
//! Live preview tail (#127): when an editor-side preview session is alive
//! (`.listening` / `.connecting` / `.running`), the panel also tails the
//! spawned `labelle run` subprocess's stderr live. The fix here is for
//! the user-perceived freeze during the CLI subprocess's cold `zig build`
//! phase (sokol+imgui cold builds run 30-60+ seconds) — previously the
//! Game View said "connecting…" for the whole window with zero feedback,
//! and stderr was only surfaced on `.crashed`. The `consumeStderr` cursor
//! advances each frame, so each panel render appends only the newly-
//! arrived bytes to `app.preview_tail` (the panel's tail buffer).

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const config = @import("../config.zig");

const panel_height: f32 = 200;

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "compiler_output",
        .display_name = "Compiler Output",
        .is_open = &app.show_compiler_output,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    const viewport = zgui.getMainViewport();
    const work_pos = viewport.getWorkPos();
    const work_size = viewport.getWorkSize();
    zgui.setNextWindowPos(.{
        .x = work_pos[0],
        .y = work_pos[1] + work_size[1] - config.ui.status_bar_height - panel_height,
    });
    zgui.setNextWindowSize(.{ .w = work_size[0], .h = panel_height });

    if (!zgui.begin("Compiler Output", .{
        .popen = &app.show_compiler_output,
        .flags = .{ .no_resize = true, .no_move = true, .no_collapse = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    // While preview is alive, the panel's status line reflects the
    // preview state — the build phase happens *inside* the subprocess
    // (`labelle run` runs `zig build` then exec's the game), so the
    // gui's own `compiler.state` stays `.idle` and would otherwise
    // read "Ready" while the user waits for a cold build. Render the
    // preview's state instead so the user has a single source of
    // truth.
    const preview_active = app.preview.isActive();
    if (preview_active) {
        switch (app.preview.state) {
            .listening => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Preview: building / waiting for engine...", .{}),
            .connecting => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Preview: engine connected, waiting for hello...", .{}),
            .running => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Preview: running", .{}),
            else => zgui.textDisabled("Preview: idle", .{}),
        }
    } else {
        switch (app.compiler.getState()) {
            .idle => zgui.textDisabled("Ready", .{}),
            .generating => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Generating...", .{}),
            .building => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Building...", .{}),
            .running => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Running...", .{}),
            .success => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Success", .{}),
            .failed => zgui.textColored(.{ 1.0, 0.0, 0.0, 1.0 }, "Failed", .{}),
        }
    }
    zgui.separator();

    // Tail any stderr bytes that arrived since the last frame into the
    // panel's display buffer. `consumeStderr` advances an internal
    // cursor so each byte is appended exactly once across the session;
    // `app.preview_tail` is reset on every fresh Run (`startPreview`).
    // Calling this unconditionally (not gated on `preview_active`) is
    // safe — when no session is alive `stderr_buf` is empty and
    // `consumeStderr` returns a zero-length slice.
    {
        const fresh = app.preview.consumeStderr();
        if (fresh.len > 0) {
            app.appendPreviewTail(fresh);
            app.compiler_output_scroll_to_bottom = true;
        }
    }

    if (zgui.beginChild("##output", .{ .h = -1 })) {
        var rendered_anything = false;

        // Live preview tail takes precedence during an active session
        // so the user sees what the subprocess is doing right now —
        // the manual-build artifact (`compiler.last_result`) is stale
        // when a preview is mid-flight.
        if (app.preview_tail.items.len > 0) {
            zgui.textUnformatted(app.preview_tail.items);
            rendered_anything = true;
        }

        if (app.compiler.last_result) |result| {
            if (result.errors.len > 0) {
                zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "{s}", .{result.errors});
                rendered_anything = true;
            }
            if (result.output.len > 0) {
                zgui.text("{s}", .{result.output});
                rendered_anything = true;
            }
        }

        if (!rendered_anything) zgui.textDisabled("No output", .{});

        if (app.compiler_output_scroll_to_bottom) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
            app.compiler_output_scroll_to_bottom = false;
        }
    }
    zgui.endChild();
}
