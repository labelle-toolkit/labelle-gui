const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");
const plugin_api = @import("plugin_api.zig");

const gl = zopengl.bindings;

const MAX_PLUGINS = 16;

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

    zglfw.windowHint(.context_version_major, 3);
    zglfw.windowHint(.context_version_minor, 3);
    zglfw.windowHint(.opengl_profile, .opengl_core_profile);
    zglfw.windowHint(.opengl_forward_compat, true);

    const window = zglfw.createWindow(1024, 768, "Dynamic Plugin System with ImGui", null) catch {
        std.debug.print("Failed to create GLFW window\n", .{});
        return error.WindowCreationFailed;
    };
    defer window.destroy();

    zglfw.makeContextCurrent(window);
    zglfw.swapInterval(1);

    zopengl.loadCoreProfile(zglfw.getProcAddress, 3, 3) catch {
        std.debug.print("Failed to load OpenGL\n", .{});
        return error.OpenGLLoadFailed;
    };

    zgui.init(allocator);
    defer zgui.deinit();

    zgui.io.setIniFilename(null);

    const scale_factor = window.getContentScale()[0];
    const font_size = 16.0 * scale_factor;

    var default_config = zgui.FontConfig.init();
    default_config.size_pixels = font_size;
    _ = zgui.io.addFontDefault(default_config);

    zgui.getStyle().scaleAllSizes(scale_factor);

    zgui.backend.init(window);
    defer zgui.backend.deinit();

    // Load plugins from zig-out/lib
    var plugins: [MAX_PLUGINS]?plugin_api.LoadedPlugin = [_]?plugin_api.LoadedPlugin{null} ** MAX_PLUGINS;
    var plugin_count: usize = 0;

    std.debug.print("=== Dynamic Plugin System with ImGui ===\n\n", .{});

    // Detect platform-specific library extension
    const lib_ext = switch (@import("builtin").os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };

    // Try to load plugins
    const plugin_names = [_][]const u8{ "counter_plugin", "color_plugin" };
    for (plugin_names) |name| {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "zig-out/lib/lib{s}{s}", .{ name, lib_ext }) catch continue;

        std.debug.print("Loading plugin: {s}\n", .{path});
        if (plugin_api.loadPlugin(path)) |plugin| {
            plugins[plugin_count] = plugin;
            plugin_count += 1;
            std.debug.print("  Loaded: {s} v{s}\n", .{
                std.mem.span(plugin.info.display_name),
                std.mem.span(plugin.info.version),
            });
        } else |err| {
            std.debug.print("  Failed to load: {}\n", .{err});
        }
    }

    std.debug.print("\nLoaded {} plugins\n\n", .{plugin_count});

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

            if (zgui.beginMenu("Plugins", true)) {
                for (0..plugin_count) |i| {
                    if (plugins[i]) |*plugin| {
                        if (zgui.menuItem(plugin.getDisplayName(), .{ .selected = plugin.is_open })) {
                            plugin.is_open = !plugin.is_open;
                        }
                    }
                }
                zgui.separator();
                zgui.textDisabled("Loaded: {}", .{plugin_count});
                zgui.endMenu();
            }

            if (zgui.beginMenu("Help", true)) {
                if (zgui.menuItem("About", .{})) {}
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }

        // Plugin info window
        {
            zgui.setNextWindowPos(.{ .x = 10, .y = 30 });
            zgui.setNextWindowSize(.{ .w = 280, .h = 200 });
            if (zgui.begin("Plugin Manager", .{})) {
                zgui.text("Dynamic Plugin System", .{});
                zgui.separator();

                zgui.text("Loaded Plugins: {}", .{plugin_count});
                zgui.spacing();

                for (0..plugin_count) |i| {
                    if (plugins[i]) |*plugin| {
                        const name = plugin.getDisplayName();
                        _ = zgui.checkbox(name, .{ .v = &plugin.is_open });
                        zgui.sameLine(.{});
                        zgui.textDisabled("v{s}", .{std.mem.span(plugin.info.version)});
                    }
                }

                zgui.spacing();
                zgui.separator();
                zgui.textWrapped("Plugins are loaded from zig-out/lib/ as shared libraries.", .{});
            }
            zgui.end();
        }

        // Render plugin panels
        for (0..plugin_count) |i| {
            if (plugins[i]) |*plugin| {
                if (plugin.is_open) {
                    if (zgui.begin(plugin.getDisplayName(), .{ .popen = &plugin.is_open })) {
                        renderPluginContent(plugin);
                    }
                    zgui.end();
                }
            }
        }

        // Render
        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.12, 0.12, 0.12, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }

    // Cleanup plugins
    for (0..plugin_count) |i| {
        if (plugins[i]) |*plugin| {
            std.debug.print("Unloading: {s}\n", .{plugin.getDisplayName()});
            plugin.deinit();
        }
    }

    std.debug.print("\n=== Spike Complete ===\n", .{});
}

/// Render plugin content based on plugin type
fn renderPluginContent(plugin: *plugin_api.LoadedPlugin) void {
    switch (plugin.info.plugin_type) {
        .counter => {
            if (plugin.get_counter_data) |get_data| {
                const data = get_data();
                zgui.text("Current Count: {}", .{data.value});
                zgui.spacing();
                zgui.separator();
                zgui.spacing();

                if (zgui.button("-10", .{ .w = 50 })) {
                    data.value -= 10;
                }
                zgui.sameLine(.{});
                if (zgui.button("-1", .{ .w = 50 })) {
                    data.value -= 1;
                }
                zgui.sameLine(.{});
                if (zgui.button("+1", .{ .w = 50 })) {
                    data.value += 1;
                }
                zgui.sameLine(.{});
                if (zgui.button("+10", .{ .w = 50 })) {
                    data.value += 10;
                }

                zgui.spacing();
                if (zgui.button("Reset", .{ .w = 100 })) {
                    data.value = 0;
                }

                zgui.spacing();
                zgui.separator();
                zgui.spacing();

                _ = zgui.sliderInt("Adjust", .{
                    .v = &data.value,
                    .min = data.min_value,
                    .max = data.max_value,
                });
            }
        },
        .color => {
            if (plugin.get_color_data) |get_data| {
                const data = get_data();
                var color = [4]f32{ data.r, data.g, data.b, data.a };

                zgui.text("Select a color:", .{});
                zgui.spacing();

                if (zgui.colorEdit4("Color", .{ .col = &color })) {
                    data.r = color[0];
                    data.g = color[1];
                    data.b = color[2];
                    data.a = color[3];
                }

                zgui.spacing();
                zgui.separator();
                zgui.spacing();

                zgui.text("Preview:", .{});
                zgui.spacing();

                _ = zgui.colorButton("##preview", .{ .col = color, .w = 100, .h = 100 });

                zgui.spacing();
                zgui.separator();
                zgui.spacing();

                _ = zgui.sliderFloat("Brightness", .{
                    .v = &data.brightness,
                    .min = 0.0,
                    .max = 2.0,
                });

                zgui.spacing();
                zgui.text("Presets:", .{});
                if (zgui.button("Red", .{ .w = 60 })) {
                    data.r = 1.0;
                    data.g = 0.0;
                    data.b = 0.0;
                    data.a = 1.0;
                }
                zgui.sameLine(.{});
                if (zgui.button("Green", .{ .w = 60 })) {
                    data.r = 0.0;
                    data.g = 1.0;
                    data.b = 0.0;
                    data.a = 1.0;
                }
                zgui.sameLine(.{});
                if (zgui.button("Blue", .{ .w = 60 })) {
                    data.r = 0.0;
                    data.g = 0.0;
                    data.b = 1.0;
                    data.a = 1.0;
                }

                zgui.spacing();
                zgui.text("RGB: {d:.0}, {d:.0}, {d:.0}", .{ data.r * 255, data.g * 255, data.b * 255 });
            }
        },
        .generic => {
            zgui.text("Generic plugin - no specialized UI", .{});
        },
    }
}
