const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");

const module = @import("module.zig");
const console = @import("modules/console.zig");
const inspector = @import("modules/inspector.zig");
const hierarchy = @import("modules/hierarchy.zig");
const asset_browser = @import("modules/asset_browser.zig");

const gl = zopengl.bindings;

/// All modules registered at compile time
const modules = [_]module.Module{
    hierarchy.hierarchy_module,
    inspector.inspector_module,
    console.console_module,
    asset_browser.asset_browser_module,
};

const registry = module.Registry.init(&modules);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize GLFW
    zglfw.init() catch {
        std.debug.print("Failed to initialize GLFW\n", .{});
        return error.GlfwInitFailed;
    };
    defer zglfw.terminate();

    // Set window hints for OpenGL
    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);

    // Create window
    const window = zglfw.createWindow(1280, 720, "ImGui Modules Spike", null) catch {
        std.debug.print("Failed to create GLFW window\n", .{});
        return error.WindowCreationFailed;
    };
    defer window.destroy();

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);

    // Load OpenGL
    zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3) catch {
        std.debug.print("Failed to load OpenGL\n", .{});
        return error.OpenGLLoadFailed;
    };

    // Initialize ImGui
    zgui.init(allocator);
    defer zgui.deinit();

    // Disable ini file
    zgui.io.setIniFilename(null);

    const scale_factor = window.getContentScale()[0];
    const font_size = 16.0 * scale_factor;

    var default_config = zgui.FontConfig.init();
    default_config.size_pixels = font_size;
    _ = zgui.io.addFontDefault(default_config);

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // Initialize all modules
    registry.initAll();
    defer registry.deinitAll();

    std.debug.print("=== ImGui Modules Spike ===\n", .{});
    std.debug.print("Registered {} modules:\n", .{modules.len});
    for (modules) |m| {
        std.debug.print("  - {s}\n", .{m.display_name});
    }
    std.debug.print("\nUse View menu to toggle panels\n", .{});

    // Main loop
    while (!window.shouldClose()) {
        zglfw.pollEvents();

        const win_size = window.getSize();
        const fb_size = window.getFramebufferSize();
        zgui.backend.newFrame(@intCast(win_size[0]), @intCast(win_size[1]));

        const fb_scale_x = @as(f32, @floatFromInt(fb_size[0])) / @as(f32, @floatFromInt(win_size[0]));
        const fb_scale_y = @as(f32, @floatFromInt(fb_size[1])) / @as(f32, @floatFromInt(win_size[1]));
        zgui.io.setDisplayFramebufferScale(fb_scale_x, fb_scale_y);

        // Main menu bar
        if (zgui.beginMainMenuBar()) {
            if (zgui.beginMenu("File", true)) {
                if (zgui.menuItem("Exit", .{})) {
                    window.setShouldClose(true);
                }
                zgui.endMenu();
            }

            // View menu with module toggles (provided by registry)
            registry.renderViewMenu();

            // Custom menus from modules (e.g., Assets menu)
            registry.renderAllMenus();

            if (zgui.beginMenu("Help", true)) {
                if (zgui.menuItem("About", .{})) {}
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }

        // Render all module panels
        registry.renderAllPanels();

        // Demo window showing all registered modules
        {
            zgui.setNextWindowPos(.{ .x = 10, .y = 30 });
            zgui.setNextWindowSize(.{ .w = 250, .h = 150 });
            if (zgui.begin("Module System Info", .{})) {
                zgui.text("Compile-time Modules: {}", .{modules.len});
                zgui.separator();
                zgui.textWrapped("This spike demonstrates how modules can add their own panels and menu items at compile time.", .{});
                zgui.spacing();
                zgui.text("Toggle panels in View menu", .{});
            }
            zgui.end();
        }

        // Render
        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.15, 0.15, 0.15, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }

    std.debug.print("\n=== Spike Complete ===\n", .{});
}
