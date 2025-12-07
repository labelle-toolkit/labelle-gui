const std = @import("std");

/// This spike demonstrates the ARCHITECTURE for Lua scripting integration.
///
/// In a full implementation, this would use ziglua or similar bindings.
/// The key concepts demonstrated here are:
/// 1. Script file loading and parsing
/// 2. Plugin metadata extraction
/// 3. Callback registration for render/init/deinit
/// 4. How scripts would interact with the host application
///
/// For actual Lua integration, use:
/// - ziglua: https://github.com/natecraddock/ziglua (Zig 0.15.x compatible)
/// - zig-luajit: https://github.com/sackosoft/zig-luajit

/// Mock Lua plugin that simulates what a real Lua plugin would look like
const MockLuaPlugin = struct {
    name: []const u8,
    display_name: []const u8,
    version: []const u8,
    script_content: []const u8,
    allocator: std.mem.Allocator,

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !MockLuaPlugin {
        // Read the Lua script file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);

        // In real implementation, we'd parse Lua and extract Plugin table
        // For this spike, we'll extract metadata from comments
        var name: []const u8 = "unknown";
        var display_name: []const u8 = "Unknown Plugin";
        var version: []const u8 = "0.0.0";

        // Simple parsing to find Plugin table definition
        // Note: Check display_name before name since "name" is a substring of "display_name"
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "display_name = \"")) |start| {
                const value_start = start + 16;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    display_name = line[value_start .. value_start + end];
                }
            } else if (std.mem.indexOf(u8, line, "name = \"")) |start| {
                const value_start = start + 8;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    name = line[value_start .. value_start + end];
                }
            } else if (std.mem.indexOf(u8, line, "version = \"")) |start| {
                const value_start = start + 11;
                if (std.mem.indexOfScalar(u8, line[value_start..], '"')) |end| {
                    version = line[value_start .. value_start + end];
                }
            }
        }

        return MockLuaPlugin{
            .name = name,
            .display_name = display_name,
            .version = version,
            .script_content = content,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockLuaPlugin) void {
        self.allocator.free(self.script_content);
    }

    pub fn callInit(self: *const MockLuaPlugin) void {
        _ = self;
        // In real implementation: lua.getGlobal("Plugin"); lua.getField(-1, "on_init"); lua.call(0, 0);
        std.debug.print("[MockLua] Calling Plugin.on_init()\n", .{});
        std.debug.print("[LuaPlugin] Initialized!\n", .{});
    }

    pub fn callDeinit(self: *const MockLuaPlugin) void {
        _ = self;
        std.debug.print("[MockLua] Calling Plugin.on_deinit()\n", .{});
        std.debug.print("[LuaPlugin] Deinitialized!\n", .{});
    }

    pub fn renderMenu(self: *const MockLuaPlugin) void {
        _ = self;
        std.debug.print("[MockLua] Calling Plugin.render_menu()\n", .{});
        std.debug.print("[LuaPlugin] Rendering menu\n", .{});
    }

    pub fn renderPanel(self: *const MockLuaPlugin) void {
        _ = self;
        std.debug.print("[MockLua] Calling Plugin.render_panel()\n", .{});
        std.debug.print("[LuaPlugin] Rendering panel\n", .{});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== Lua Scripting Plugin System Spike ===\n", .{});
    std.debug.print("(Mock implementation - demonstrates architecture)\n\n", .{});

    std.debug.print("Loading Lua plugin: scripts/example_plugin.lua\n", .{});

    var plugin = MockLuaPlugin.loadFromFile(allocator, "scripts/example_plugin.lua") catch |err| {
        std.debug.print("Failed to load plugin: {}\n", .{err});
        return err;
    };
    defer plugin.deinit();

    std.debug.print("Loaded: {s} ({s}) v{s}\n\n", .{
        plugin.display_name,
        plugin.name,
        plugin.version,
    });

    // Initialize
    std.debug.print("Initializing plugin...\n", .{});
    plugin.callInit();
    std.debug.print("\n", .{});

    // Simulate render loop
    std.debug.print("Simulating render loop (3 frames)...\n", .{});
    for (0..3) |frame| {
        std.debug.print("\n--- Frame {} ---\n", .{frame});
        plugin.renderMenu();
        plugin.renderPanel();
    }
    std.debug.print("\n", .{});

    // Deinitialize
    std.debug.print("Deinitializing plugin...\n", .{});
    plugin.callDeinit();

    std.debug.print("\n=== Spike Complete ===\n", .{});
    std.debug.print("\nNOTE: For real Lua integration, use ziglua:\n", .{});
    std.debug.print("https://github.com/natecraddock/ziglua\n", .{});
}
