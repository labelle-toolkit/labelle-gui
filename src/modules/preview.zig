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
            // Age of the last inbound frame, measured against the
            // editor's local monotonic clock (#79). `last_rx_ms` is
            // refreshed by any engine traffic, so this is a true
            // "engine last heard from Xms ago" — it climbs visibly
            // when the engine wedges, right up to the heartbeat
            // watchdog firing at `heartbeat_timeout_ms`.
            const ago: i64 = p.heartbeatAgeMs() orelse 0;
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
        zgui.sameLine(.{});
        renderScenePicker(app);
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

/// Scene picker dropdown to the right of "Run preview" (#132). Lists the
/// project's `scenes/*.jsonc` files; the chosen entry sets
/// `App.preview_scene_override`, which `startPreview` forwards to
/// `labelle run --scene=<name>`. The `<initial>` entry resets the
/// override to null so the next Run falls back to `project.labelle`'s
/// `initial_scene` field.
fn renderScenePicker(app: *App) void {
    const proj = app.project_manager.current_project orelse {
        // No project open — picker is meaningless. Don't crowd the
        // panel; the "(no project open)" hint already shows.
        return;
    };

    // Resolve the scene list lazily. `scenesAvailable` caches against
    // the project's lifetime; the call is cheap on repeat renders.
    const scenes = proj.scenesAvailable(app.allocator) catch &[_][]const u8{};

    // Preview label — the picker shows `<initial>` when no override is
    // set, otherwise the current chosen scene name. Bounded buffer so
    // we can null-terminate for the C combo API.
    var preview_buf: [160]u8 = undefined;
    const preview_str: [:0]const u8 = blk: {
        const src: []const u8 = app.preview_scene_override orelse "<initial>";
        const n = @min(src.len, preview_buf.len - 1);
        @memcpy(preview_buf[0..n], src[0..n]);
        preview_buf[n] = 0;
        break :blk preview_buf[0..n :0];
    };

    zgui.setNextItemWidth(160);
    if (!zgui.beginCombo("##preview_scene", .{ .preview_value = preview_str.ptr })) return;
    defer zgui.endCombo();

    // `<initial>` resets the override to null — produces argv without
    // `--scene=…` so the launcher honors `project.labelle`'s
    // `initial_scene` field. This is the v1-shipping default; we want
    // it to be the very first item so users can always get back to it.
    if (zgui.selectable("<initial>", .{ .selected = app.preview_scene_override == null })) {
        app.preview_scene_override = null;
    }

    for (scenes) |name| {
        // Each entry needs a NUL-terminated label for selectable's
        // C ABI. Names from `scenesAvailable` are arena-allocated
        // without a NUL sentinel; copy into a per-iteration buffer.
        var label_buf: [128]u8 = undefined;
        if (name.len >= label_buf.len) continue;
        @memcpy(label_buf[0..name.len], name);
        label_buf[name.len] = 0;
        const label = label_buf[0..name.len :0];

        const selected =
            app.preview_scene_override != null and
            std.mem.eql(u8, app.preview_scene_override.?, name);
        if (zgui.selectable(label, .{ .selected = selected })) {
            // Borrow from the project arena — the slice lives until
            // the next project transition (which clears the override).
            app.preview_scene_override = name;
        }
    }
}
