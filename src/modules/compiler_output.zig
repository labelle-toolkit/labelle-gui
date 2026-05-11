//! Compiler Output panel — first module wired through the Registry.
//!
//! The panel docks to the bottom edge of the work area when open, shows the
//! current compiler state, and streams the last `labelle build/run`
//! invocation's stdout/stderr. The `Build` menu also flips `is_open` to
//! true when the user starts a build, which auto-surfaces the panel.

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

    switch (app.compiler.getState()) {
        .idle => zgui.textDisabled("Ready", .{}),
        .generating => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Generating...", .{}),
        .building => zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "Building...", .{}),
        .running => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Running...", .{}),
        .success => zgui.textColored(.{ 0.0, 1.0, 0.0, 1.0 }, "Success", .{}),
        .failed => zgui.textColored(.{ 1.0, 0.0, 0.0, 1.0 }, "Failed", .{}),
    }
    zgui.separator();

    if (zgui.beginChild("##output", .{ .h = -1 })) {
        if (app.compiler.last_result) |result| {
            if (result.errors.len > 0) zgui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, "{s}", .{result.errors});
            if (result.output.len > 0) zgui.text("{s}", .{result.output});
        } else {
            zgui.textDisabled("No output", .{});
        }
        if (app.compiler_output_scroll_to_bottom) {
            zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
            app.compiler_output_scroll_to_bottom = false;
        }
    }
    zgui.endChild();
}
