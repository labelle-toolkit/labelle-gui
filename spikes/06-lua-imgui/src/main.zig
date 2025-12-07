const std = @import("std");
const zglfw = @import("zglfw");
const zopengl = @import("zopengl");
const zgui = @import("zgui");

const gl = zopengl.bindings;

/// Mock Lua script that simulates script state
/// In a real implementation, this would use ziglua to execute actual Lua
const LuaScript = struct {
    name: [:0]const u8,
    display_name: [:0]const u8,
    version: []const u8,
    plugin_type: PluginType,
    script_path: []const u8,
    is_open: bool = true,
    allocator: std.mem.Allocator,

    // Script state (simulated)
    counter_value: i32 = 0,
    color: [4]f32 = .{ 1.0, 0.5, 0.2, 1.0 },
    brightness: f32 = 1.0,
    notepad_text: [4096:0]u8 = [_:0]u8{0} ** 4096,
    word_wrap: bool = true,

    const PluginType = enum {
        counter,
        color,
        notepad,
        unknown,
    };

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !LuaScript {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            std.debug.print("Failed to open {s}: {}\n", .{ path, err });
            return err;
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 64);
        defer allocator.free(content);

        // Parse metadata from Lua script
        var name: [:0]const u8 = "unknown";
        var display_name: [:0]const u8 = "Unknown Script";
        var version: []const u8 = "0.0.0";
        var plugin_type: PluginType = .unknown;

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "display_name = \"")) |start| {
                const value_start = start + 16;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    display_name = try allocator.dupeZ(u8, line[value_start .. value_start + end]);
                }
            } else if (std.mem.indexOf(u8, line, "name = \"")) |start| {
                const value_start = start + 8;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    name = try allocator.dupeZ(u8, line[value_start .. value_start + end]);
                }
            } else if (std.mem.indexOf(u8, line, "version = \"")) |start| {
                const value_start = start + 11;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    version = try allocator.dupe(u8, line[value_start .. value_start + end]);
                }
            } else if (std.mem.indexOf(u8, line, "plugin_type = \"")) |start| {
                const value_start = start + 15;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    const type_str = line[value_start .. value_start + end];
                    if (std.mem.eql(u8, type_str, "counter")) {
                        plugin_type = .counter;
                    } else if (std.mem.eql(u8, type_str, "color")) {
                        plugin_type = .color;
                    } else if (std.mem.eql(u8, type_str, "notepad")) {
                        plugin_type = .notepad;
                    }
                }
            }
        }

        var script = LuaScript{
            .name = name,
            .display_name = display_name,
            .version = version,
            .plugin_type = plugin_type,
            .script_path = try allocator.dupe(u8, path),
            .allocator = allocator,
        };

        // Initialize notepad with default text
        if (plugin_type == .notepad) {
            const default_text = "Welcome to Lua Notepad!\n\nThis is powered by a Lua script.\n\nFeatures:\n- Edit text\n- Word wrap toggle\n- Character/line count";
            @memcpy(script.notepad_text[0..default_text.len], default_text);
        }

        return script;
    }

    pub fn deinit(self: *LuaScript) void {
        if (!std.mem.eql(u8, self.name, "unknown")) {
            self.allocator.free(self.name);
        }
        if (!std.mem.eql(u8, self.display_name, "Unknown Script")) {
            self.allocator.free(self.display_name);
        }
        if (!std.mem.eql(u8, self.version, "0.0.0")) {
            self.allocator.free(self.version);
        }
        self.allocator.free(self.script_path);
    }
};

const MAX_SCRIPTS = 16;

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

    const window = zglfw.createWindow(1024, 768, "Lua Scripting with ImGui (Mock)", null) catch {
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

    // Load Lua scripts
    var scripts: [MAX_SCRIPTS]?LuaScript = [_]?LuaScript{null} ** MAX_SCRIPTS;
    var script_count: usize = 0;

    std.debug.print("=== Lua Scripting with ImGui (Mock) ===\n\n", .{});

    const script_files = [_][]const u8{
        "scripts/counter.lua",
        "scripts/color.lua",
        "scripts/notepad.lua",
    };

    for (script_files) |path| {
        std.debug.print("Loading script: {s}\n", .{path});
        if (LuaScript.loadFromFile(allocator, path)) |script| {
            scripts[script_count] = script;
            script_count += 1;
            std.debug.print("  Loaded: {s} v{s} (type: {})\n", .{
                script.display_name,
                script.version,
                script.plugin_type,
            });
        } else |err| {
            std.debug.print("  Failed to load: {}\n", .{err});
        }
    }

    std.debug.print("\nLoaded {} scripts\n\n", .{script_count});

    // Console log buffer
    var console_log: [8192]u8 = undefined;
    var console_len: usize = 0;

    const initial_log = "[System] Lua scripting system initialized\n[System] Scripts are parsed but executed in mock mode\n[System] For real Lua, integrate ziglua\n\n";
    @memcpy(console_log[0..initial_log.len], initial_log);
    console_len = initial_log.len;

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

            if (zgui.beginMenu("Scripts", true)) {
                for (0..script_count) |i| {
                    if (scripts[i]) |*script| {
                        if (zgui.menuItem(script.display_name, .{ .selected = script.is_open })) {
                            script.is_open = !script.is_open;
                        }
                    }
                }
                zgui.separator();
                zgui.textDisabled("Loaded: {}", .{script_count});
                zgui.endMenu();
            }

            if (zgui.beginMenu("Help", true)) {
                if (zgui.menuItem("About", .{})) {}
                zgui.endMenu();
            }
            zgui.endMainMenuBar();
        }

        // Script Manager window
        {
            zgui.setNextWindowPos(.{ .x = 10, .y = 30 });
            zgui.setNextWindowSize(.{ .w = 300, .h = 220 });
            if (zgui.begin("Script Manager", .{})) {
                zgui.text("Lua Scripting System", .{});
                zgui.textColored(.{ 1.0, 1.0, 0.0, 1.0 }, "(Mock Implementation)", .{});
                zgui.separator();

                zgui.text("Loaded Scripts: {}", .{script_count});
                zgui.spacing();

                for (0..script_count) |i| {
                    if (scripts[i]) |*script| {
                        _ = zgui.checkbox(script.display_name, .{ .v = &script.is_open });
                        zgui.sameLine(.{});
                        zgui.textDisabled("v{s}", .{script.version});
                    }
                }

                zgui.spacing();
                zgui.separator();
                zgui.textWrapped("Scripts are loaded from scripts/ folder. UI is rendered by host based on script metadata.", .{});
            }
            zgui.end();
        }

        // Render script panels
        for (0..script_count) |i| {
            if (scripts[i]) |*script| {
                if (script.is_open) {
                    if (zgui.begin(script.display_name, .{ .popen = &script.is_open })) {
                        renderScriptPanel(script, &console_log, &console_len);
                    }
                    zgui.end();
                }
            }
        }

        // Console window
        {
            zgui.setNextWindowPos(.{ .x = 10, .y = 260 });
            zgui.setNextWindowSize(.{ .w = 300, .h = 200 });
            if (zgui.begin("Lua Console", .{})) {
                if (zgui.beginChild("##console_output", .{ .h = -30 })) {
                    zgui.textWrapped("{s}", .{console_log[0..console_len]});
                    if (zgui.getScrollY() >= zgui.getScrollMaxY()) {
                        zgui.setScrollHereY(.{ .center_y_ratio = 1.0 });
                    }
                }
                zgui.endChild();

                zgui.separator();
                if (zgui.button("Clear", .{ .w = 60 })) {
                    console_len = 0;
                }
            }
            zgui.end();
        }

        // Render
        gl.viewport(0, 0, fb_size[0], fb_size[1]);
        gl.clearColor(0.1, 0.1, 0.12, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        zgui.backend.draw();

        window.swapBuffers();
    }

    // Cleanup scripts
    for (0..script_count) |i| {
        if (scripts[i]) |*script| {
            std.debug.print("Unloading: {s}\n", .{script.display_name});
            script.deinit();
        }
    }

    std.debug.print("\n=== Spike Complete ===\n", .{});
}

fn appendLog(log: *[8192]u8, len: *usize, msg: []const u8) void {
    const remaining = log.len - len.*;
    const to_copy = @min(msg.len, remaining);
    @memcpy(log[len.*..][0..to_copy], msg[0..to_copy]);
    len.* += to_copy;
}

fn renderScriptPanel(script: *LuaScript, log: *[8192]u8, log_len: *usize) void {
    zgui.textDisabled("Script: {s}", .{script.script_path});
    zgui.separator();

    switch (script.plugin_type) {
        .counter => {
            zgui.text("Current Count: {}", .{script.counter_value});
            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            if (zgui.button("-10", .{ .w = 50 })) {
                script.counter_value -= 10;
                appendLog(log, log_len, "[Counter] Decremented by 10\n");
            }
            zgui.sameLine(.{});
            if (zgui.button("-1", .{ .w = 50 })) {
                script.counter_value -= 1;
                appendLog(log, log_len, "[Counter] Decremented by 1\n");
            }
            zgui.sameLine(.{});
            if (zgui.button("+1", .{ .w = 50 })) {
                script.counter_value += 1;
                appendLog(log, log_len, "[Counter] Incremented by 1\n");
            }
            zgui.sameLine(.{});
            if (zgui.button("+10", .{ .w = 50 })) {
                script.counter_value += 10;
                appendLog(log, log_len, "[Counter] Incremented by 10\n");
            }

            zgui.spacing();
            if (zgui.button("Reset", .{ .w = 100 })) {
                script.counter_value = 0;
                appendLog(log, log_len, "[Counter] Reset to 0\n");
            }

            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            _ = zgui.sliderInt("Adjust", .{
                .v = &script.counter_value,
                .min = -100,
                .max = 100,
            });
        },
        .color => {
            zgui.text("Select a color:", .{});
            zgui.spacing();

            if (zgui.colorEdit4("Color", .{ .col = &script.color })) {
                appendLog(log, log_len, "[Color] Color changed\n");
            }

            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            zgui.text("Preview:", .{});
            _ = zgui.colorButton("##preview", .{ .col = script.color, .w = 100, .h = 100 });

            zgui.spacing();
            zgui.separator();
            zgui.spacing();

            if (zgui.sliderFloat("Brightness", .{
                .v = &script.brightness,
                .min = 0.0,
                .max = 2.0,
            })) {
                appendLog(log, log_len, "[Color] Brightness adjusted\n");
            }

            zgui.spacing();
            zgui.text("Presets:", .{});
            if (zgui.button("Red", .{ .w = 60 })) {
                script.color = .{ 1.0, 0.0, 0.0, 1.0 };
                appendLog(log, log_len, "[Color] Set to Red\n");
            }
            zgui.sameLine(.{});
            if (zgui.button("Green", .{ .w = 60 })) {
                script.color = .{ 0.0, 1.0, 0.0, 1.0 };
                appendLog(log, log_len, "[Color] Set to Green\n");
            }
            zgui.sameLine(.{});
            if (zgui.button("Blue", .{ .w = 60 })) {
                script.color = .{ 0.0, 0.0, 1.0, 1.0 };
                appendLog(log, log_len, "[Color] Set to Blue\n");
            }

            zgui.spacing();
            zgui.text("RGB: {d:.0}, {d:.0}, {d:.0}", .{
                script.color[0] * 255,
                script.color[1] * 255,
                script.color[2] * 255,
            });
        },
        .notepad => {
            _ = zgui.checkbox("Word Wrap", .{ .v = &script.word_wrap });
            zgui.sameLine(.{});
            if (zgui.button("Clear", .{ .w = 60 })) {
                @memset(&script.notepad_text, 0);
                appendLog(log, log_len, "[Notepad] Cleared\n");
            }

            zgui.separator();

            // Text editor
            _ = zgui.inputTextMultiline("##editor", .{
                .buf = &script.notepad_text,
                .w = -1,
                .h = 200,
            });

            zgui.separator();

            // Stats
            const text = std.mem.sliceTo(&script.notepad_text, 0);
            var line_count: usize = 1;
            for (text) |c| {
                if (c == '\n') line_count += 1;
            }
            zgui.text("Characters: {} | Lines: {}", .{ text.len, line_count });
        },
        .unknown => {
            zgui.text("Unknown script type", .{});
            zgui.textWrapped("This script doesn't specify a known plugin_type.", .{});
        },
    }
}
