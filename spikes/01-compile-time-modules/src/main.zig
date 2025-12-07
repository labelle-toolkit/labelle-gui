const std = @import("std");
const module = @import("module.zig");

// Import all modules at compile time
const asset_browser = @import("modules/asset_browser.zig");
const console = @import("modules/console.zig");

// Register all modules at compile time
const registry = module.Registry.init(&.{
    asset_browser.asset_browser,
    console.console,
});

pub fn main() !void {
    std.debug.print("=== Compile-Time Module System Spike ===\n\n", .{});

    std.debug.print("Registered modules:\n", .{});
    for (registry.modules) |mod| {
        std.debug.print("  - {s} ({s})\n", .{ mod.display_name, mod.name });
    }
    std.debug.print("\n", .{});

    // Initialize all modules
    std.debug.print("Initializing modules...\n", .{});
    registry.initAll();
    std.debug.print("\n", .{});

    // Simulate frame loop
    std.debug.print("Simulating render loop (3 frames)...\n", .{});
    for (0..3) |frame| {
        std.debug.print("\n--- Frame {} ---\n", .{frame});
        registry.renderAllMenus();
        registry.renderAllPanels();
    }
    std.debug.print("\n", .{});

    // Deinitialize all modules
    std.debug.print("Deinitializing modules...\n", .{});
    registry.deinitAll();

    std.debug.print("\n=== Spike Complete ===\n", .{});
}
