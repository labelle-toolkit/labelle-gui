//! Preview panel — status line + Run/Stop buttons for the editor-side
//! preview-mode TCP session (issue #61).
//!
//! Reads `app.preview` (a `PreviewSession`) and renders one of:
//!   - "Idle"
//!   - "Listening on 127.0.0.1:PORT, waiting for engine..."
//!   - "Connecting — engine connected, waiting for hello..."
//!   - "Preview running (engine PID NNNN, last heartbeat Xms ago)"
//!   - "Preview crashed"
//!   - "Preview stopped"
//!
//! Buttons:
//!   - Run preview — enabled when a project is open and no preview is
//!     active. Delegates to `App.startPreview` (the same path the
//!     Build menu uses).
//!   - Stop preview — enabled while listening/connecting/running.
//!     Delegates to `App.stopPreview`.
//!
//! No game pixels here — Phase 2+ (#59 umbrella) lands texture-mirror.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const preview = @import("../preview.zig");

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "preview",
        .display_name = "Preview",
        .is_open = &app.show_preview,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Preview", .{
        .popen = &app.show_preview,
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    renderStatus(&app.preview);
    zgui.separator();
    renderButtons(app);
}

fn renderStatus(p: *const preview.PreviewSession) void {
    switch (p.state) {
        .idle => zgui.textDisabled("Idle", .{}),
        .listening => {
            const port = p.port orelse 0;
            zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Listening on 127.0.0.1:{d}, waiting for engine...", .{port});
        },
        .connecting => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Connecting — engine connected, waiting for hello...", .{}),
        .running => {
            const pid = p.engine_pid orelse 0;
            const ago: i64 = if (p.last_heartbeat_ms) |hb| std.time.milliTimestamp() - hb else 0;
            zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Preview running (engine PID {d}, last heartbeat {d}ms ago)", .{ pid, ago });
            if (p.engine_version) |v| zgui.text("Engine version: {s}", .{v});
        },
        .crashed => {
            zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "Preview crashed", .{});
            renderCapturedStderr(p);
        },
        .stopped => {
            if (p.bye_reason) |r| {
                zgui.textDisabled("Preview stopped ({s})", .{r});
            } else {
                zgui.textDisabled("Preview stopped", .{});
            }
        },
    }
}

/// Surface the child's captured stderr tail when a session has
/// failed. Empty buffer → the child either never produced output
/// before it was killed, OR it was the connect-timeout path with a
/// well-behaved launcher that just didn't pass the args through —
/// fall back to a hint instead of an empty rectangle so the user
/// always sees *some* signal about what went wrong.
fn renderCapturedStderr(p: *const preview.PreviewSession) void {
    const captured = p.capturedStderr();
    zgui.spacing();
    zgui.textDisabled("Launcher / engine output:", .{});
    if (captured.len == 0) {
        zgui.textDisabled("  (no stderr captured — child may have exited silently or never started)", .{});
        return;
    }
    // Bounded child-window so a long stderr tail doesn't push the
    // Run/Stop buttons off-screen. Read-only — the user can scroll
    // through and copy/paste, no editing.
    if (zgui.beginChild("##preview_stderr", .{ .w = 0, .h = 160, .child_flags = .{ .border = true } })) {
        zgui.textUnformatted(captured);
    }
    zgui.endChild();
}

fn renderButtons(app: *App) void {
    const has_project = app.project_manager.current_project != null;
    const active = app.preview.isActive();

    if (!active) {
        if (zgui.button("Run preview##preview_run", .{ .w = 140 })) {
            if (has_project) app.startPreview();
        }
        if (!has_project) {
            zgui.sameLine(.{});
            zgui.textDisabled("(no project open)", .{});
        }
    } else {
        if (zgui.button("Stop preview##preview_stop", .{ .w = 140 })) {
            app.stopPreview();
        }
    }
}
