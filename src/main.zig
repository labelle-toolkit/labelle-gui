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

pub fn main(proc_init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize the process-wide Io for filesystem helpers that
    // previously used std.fs.cwd() (removed in Zig 0.16).
    io_global.init(proc_init);


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

    // Load user preferences before sizing fonts — `font_scale` rides on
    // top of the DPI factor (see `src/prefs.zig`). On first run or any
    // read error this falls back to defaults, so the GUI always starts.
    const user_prefs = prefs_mod.loadOrDefault(allocator);
    const font_size = config.ui.base_font_size * scale_factor * user_prefs.font_scale;

    var default_config = zgui.FontConfig.init();
    default_config.size_pixels = font_size;
    _ = zgui.io.addFontDefault(default_config);

    var fa_config = zgui.FontConfig.init();
    fa_config.merge_mode = true;
    fa_config.pixel_snap_h = true;
    fa_config.glyph_min_advance_x = font_size;
    // FontAwesome glyphs sit above the default text baseline because the
    // icon designs center on the glyph box's visual middle while letters
    // hang from the cap line. Push the merged icon range down by ~25 %
    // of the active font size so folder/file icons sit centered against
    // the x-height of their accompanying text (in the tree view and
    // elsewhere). Proportional to font_size, so it scales correctly with
    // DPI and the user's font-scale preference.
    fa_config.glyph_offset = .{ 0.0, font_size * 0.1 };
    _ = zgui.io.addFontFromFileWithConfig(
        "assets/fonts/fa-solid-900.ttf",
        font_size,
        fa_config,
        &icons.FA_ICON_RANGES,
    );

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    const app = try App.init(allocator, window, user_prefs);
    defer app.deinit();

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
