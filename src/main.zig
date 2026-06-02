const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const zstbi = @import("zstbi");

const icons = @import("icons.zig");
const config = @import("config.zig");
const prefs_mod = @import("prefs.zig");
const App = @import("app.zig").App;
const io_global = @import("io_global.zig");
const preferences_dialog = @import("dialogs/preferences.zig");

const gl = zopengl.bindings;

pub const std_options: std.Options = .{ .log_level = .info };

// ── DPI ───────────────────────────────────────────────────────────────
// GLFW's content-scale callback fires on a background thread, so we hand
// the change off via atomics; the next renderFrame() reads them.
const dpi_epsilon: f32 = 1e-6;
const dpi_change_threshold: f32 = 0.05;

var g_initial_scale: f32 = 1.0;
var g_current_scale: std.atomic.Value(f32) = std.atomic.Value(f32).init(1.0);
var g_dpi_changed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn contentScaleCallback(_: *zglfw.Window, xscale: f32, _: f32) callconv(.c) void {
    g_current_scale.store(xscale, .release);
    g_dpi_changed.store(true, .release);
}

/// Startup args parsed from argv. Both fields are optional; either or
/// both may be absent. String slices live as long as the iterator's
/// internal buffer — `StartupArgs.parse` duplicates each value into
/// the caller-provided arena so the values outlive the iterator.
const StartupArgs = struct {
    project_dir: ?[]const u8 = null,
    open_flow: ?[]const u8 = null,

    /// `--project <dir>` — open the project at this folder right after
    /// `App.init`, before the main loop starts. `--open-flow <path>` —
    /// open this `.flow.jsonc` as a flow-editor tab after the project
    /// loads. Anything else is rejected with a usage line, so a typo
    /// surfaces loudly instead of silently launching the empty GUI.
    ///
    /// `args_vector` is `proc_init.args`; `arena` owns the duplicated
    /// strings the caller will read after `parse` returns.
    fn parse(args_vector: std.process.Args, arena: std.mem.Allocator) !StartupArgs {
        var out: StartupArgs = .{};
        var iter = try std.process.Args.Iterator.initAllocator(args_vector, arena);
        defer iter.deinit();
        _ = iter.skip(); // argv[0] is the binary path

        while (iter.next()) |a| {
            if (std.mem.eql(u8, a, "--project")) {
                const v = iter.next() orelse return error.MissingValue;
                out.project_dir = try arena.dupe(u8, v);
            } else if (std.mem.eql(u8, a, "--open-flow")) {
                const v = iter.next() orelse return error.MissingValue;
                out.open_flow = try arena.dupe(u8, v);
            } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
                printUsage();
                return error.HelpRequested;
            } else {
                std.log.err("labelle-gui: unknown argument: {s}", .{a});
                printUsage();
                return error.UnknownArgument;
            }
        }
        return out;
    }
};

fn printUsage() void {
    const msg =
        \\labelle-gui — the labelle-toolkit project editor.
        \\
        \\Usage:
        \\  labelle-gui [--project <dir>] [--open-flow <flow.flow.jsonc>]
        \\
        \\Options:
        \\  --project <dir>             Open the project folder at startup (skips the picker).
        \\  --open-flow <path>          Open a `.flow.jsonc` as a flow-editor tab at startup.
        \\                              Pair with --project so the editor has palette context.
        \\  -h, --help                  Print this and exit.
        \\
    ;
    std.debug.print("{s}", .{msg});
}

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the process-wide Io for filesystem helpers that
    // previously used std.fs.cwd() (removed in Zig 0.16).
    io_global.init(proc_init);

    // Startup args (`--project <dir>`, `--open-flow <path>`) — parsed
    // up front so a typo bails before we initialize GLFW + zgui. The
    // slices live in `args_arena` and are read once after `App.init`
    // returns, so the arena outlives the read but not the main loop.
    var args_arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer args_arena_state.deinit();
    const startup = StartupArgs.parse(proc_init.args, args_arena_state.allocator()) catch |err| switch (err) {
        error.HelpRequested => return,
        else => return err,
    };

    zglfw.init() catch {
        std.log.err("Failed to initialize GLFW", .{});
        return error.GlfwInitFailed;
    };
    defer zglfw.terminate();

    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);

    const window = zglfw.createWindow(1280, 720, "Labelle", null, null) catch {
        std.log.err("Failed to create GLFW window", .{});
        return error.WindowCreationFailed;
    };
    defer window.destroy();

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);

    zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3) catch {
        std.log.err("Failed to load OpenGL", .{});
        return error.OpenGLLoadFailed;
    };

    zgui.init(allocator);
    defer zgui.deinit();
    zgui.io.setIniFilename(null);

    // stb_image needs a global allocator before any `Image.loadFromFile`.
    // The atlas module decodes PNGs through this, so init it once
    // at startup; the call is idempotent across the gui lifetime.
    zstbi.init(io_global.io(), allocator);
    defer zstbi.deinit();

    const scale_factor = window.getContentScale()[0];
    g_initial_scale = scale_factor;
    g_current_scale.store(scale_factor, .release);
    _ = window.setContentScaleCallback(contentScaleCallback);

    // Load user preferences before sizing fonts. The atlas is baked
    // at the DPI-scaled base size; `font_scale` rides on top of that
    // at draw time via `style.font_scale_main` (ImGui 1.92's dynamic
    // atlas re-rasterises glyphs at any requested rendered size, so
    // slider drags reflect crisply on the next frame — no rebuild).
    // On first run or any read error this falls back to defaults, so
    // the GUI always starts.
    const user_prefs = prefs_mod.loadOrDefault(allocator);
    const font_size = config.ui.base_font_size * scale_factor;

    var default_config = zgui.FontConfig.init();
    default_config.size_pixels = font_size;
    _ = zgui.io.addFontDefault(default_config);

    var fa_config = zgui.FontConfig.init();
    fa_config.merge_mode = true;
    fa_config.pixel_snap_h = true;
    fa_config.glyph_min_advance_x = font_size;
    // FontAwesome glyphs sit above the default text baseline because the
    // icon designs center on the glyph box's visual middle while letters
    // hang from the cap line. Push the merged icon range down by ~10 %
    // of the atlas-bake font size so folder/file icons sit centered
    // against the x-height of their accompanying text. Computed against
    // the unscaled font_size so the offset scales uniformly with text
    // when `font_scale_main` changes at runtime — icons follow text.
    fa_config.glyph_offset = .{ 0.0, font_size * 0.1 };
    _ = zgui.io.addFontFromFileWithConfig(
        "assets/fonts/fa-solid-900.ttf",
        font_size,
        fa_config,
        &icons.FA_ICON_RANGES,
    );

    // DPI scale lands on padding/border/spacing first so it forms the
    // "natural" baseline that future font-scale changes scale on top
    // of. `preferences_dialog.applyLive` captures the current style as
    // the baseline on its first call, then applies the user's saved
    // font_scale uniformly — text (via `style.font_scale_main`) AND
    // padding/spacing (via `scaleAllSizes`). The Preferences dialog
    // re-enters the same path on every slider edit so the whole layout
    // (not just text) tracks the slider.
    zgui.getStyle().scaleAllSizes(scale_factor);
    preferences_dialog.applyLive(user_prefs.font_scale);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    const app = try App.init(allocator, window, user_prefs);
    defer app.deinit();

    // Apply startup args after init. Failures log and continue —
    // dropping into an empty editor is still useful, and surfacing the
    // error in the terminal beats a silent abort. The flow tab is
    // skipped if the project load failed, since the editor needs the
    // project's palette context to render the graph meaningfully.
    if (startup.project_dir) |dir| {
        app.openProjectPath(dir) catch |err| {
            std.log.err("--project: failed to load {s}: {}", .{ dir, err });
        };
    }
    if (startup.open_flow) |flow_path| {
        app.openFlowDoc(flow_path) catch |err| {
            std.log.err("--open-flow: failed to open {s}: {}", .{ flow_path, err });
        };
    }

    std.log.info("Labelle started", .{});

    var prev_time = zglfw.getTime();

    while (!window.shouldClose()) {
        zglfw.pollEvents();

        if (g_dpi_changed.swap(false, .acquire)) {
            const new_scale = g_current_scale.load(.acquire);
            if (g_initial_scale > dpi_epsilon and @abs(new_scale - g_initial_scale) / g_initial_scale > dpi_change_threshold) {
                app.show_dpi_warning = true;
            }
        }

        const now = zglfw.getTime();
        const dt_seconds: f32 = @floatCast(now - prev_time);
        prev_time = now;

        const win_size = window.getSize();
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(win_size[0]), @intCast(win_size[1]));

        const fb_scale_x = @as(f32, @floatFromInt(fb_size[0])) / @as(f32, @floatFromInt(win_size[0]));
        const fb_scale_y = @as(f32, @floatFromInt(fb_size[1])) / @as(f32, @floatFromInt(win_size[1]));
        zgui.io.setDisplayFramebufferScale(fb_scale_x, fb_scale_y);

        app.renderFrame(dt_seconds);

        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.1, 0.1, 0.1, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();
        window.swapBuffers();
    }

    std.log.info("Labelle closed", .{});
}
