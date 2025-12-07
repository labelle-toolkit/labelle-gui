const zgui = @import("zgui");
const module = @import("../module.zig");

var is_open: bool = false; // Start closed to show toggle works
var selected_asset: ?usize = null;

const Asset = struct {
    name: [:0]const u8,
    asset_type: AssetType,
};

const AssetType = enum {
    folder,
    scene,
    script,
    texture,
    model,
    audio,
};

fn getAssetIcon(asset_type: AssetType) []const u8 {
    return switch (asset_type) {
        .folder => "[D]",
        .scene => "[S]",
        .script => "[C]",
        .texture => "[T]",
        .model => "[M]",
        .audio => "[A]",
    };
}

const assets = [_]Asset{
    .{ .name = "Scenes", .asset_type = .folder },
    .{ .name = "Scripts", .asset_type = .folder },
    .{ .name = "Textures", .asset_type = .folder },
    .{ .name = "main.scene", .asset_type = .scene },
    .{ .name = "level1.scene", .asset_type = .scene },
    .{ .name = "player.zig", .asset_type = .script },
    .{ .name = "enemy.zig", .asset_type = .script },
    .{ .name = "grass.png", .asset_type = .texture },
    .{ .name = "player.obj", .asset_type = .model },
    .{ .name = "music.ogg", .asset_type = .audio },
};

fn renderMenu() void {
    if (zgui.beginMenu("Assets", true)) {
        if (zgui.menuItem("Import...", .{})) {
            // Import asset
        }
        if (zgui.menuItem("Create Folder", .{})) {
            // Create folder
        }
        zgui.separator();
        if (zgui.menuItem("Refresh", .{})) {
            // Refresh
        }
        zgui.endMenu();
    }
}

fn renderPanel() void {
    // Path breadcrumb
    zgui.text("Assets > Project", .{});
    zgui.separator();

    // List view of assets
    for (assets, 0..) |asset, i| {
        const is_selected = selected_asset == i;

        // Show icon and name
        zgui.text("{s} ", .{getAssetIcon(asset.asset_type)});
        zgui.sameLine(.{});

        if (zgui.selectable(asset.name, .{ .selected = is_selected })) {
            selected_asset = i;
        }
    }
}

pub const asset_browser_module = module.Module{
    .name = "asset_browser",
    .display_name = "Asset Browser",
    .render_menu = renderMenu,
    .render_panel = renderPanel,
    .is_open = &is_open,
};
