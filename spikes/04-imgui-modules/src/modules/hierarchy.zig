const zgui = @import("zgui");
const module = @import("../module.zig");

var is_open: bool = true;
var selected_entity: ?usize = null;

const Entity = struct {
    name: [:0]const u8,
    children: []const Entity = &.{},
};

// Example scene hierarchy
const scene_root = [_]Entity{
    .{
        .name = "Main Camera",
    },
    .{
        .name = "Directional Light",
    },
    .{
        .name = "Player",
        .children = &.{
            .{ .name = "Body" },
            .{ .name = "Head" },
            .{
                .name = "Weapon",
                .children = &.{
                    .{ .name = "Muzzle" },
                },
            },
        },
    },
    .{
        .name = "Environment",
        .children = &.{
            .{ .name = "Ground" },
            .{ .name = "Trees" },
            .{ .name = "Buildings" },
        },
    },
    .{
        .name = "UI Canvas",
    },
};

fn renderEntity(entity: *const Entity, id: usize) void {
    const has_children = entity.children.len > 0;
    const is_selected = selected_entity == id;

    if (has_children) {
        // Use tree node for entities with children
        const open = zgui.treeNode(entity.name);

        if (zgui.isItemClicked(.left)) {
            selected_entity = id;
        }

        // Show selection highlight
        if (is_selected) {
            zgui.sameLine(.{});
            zgui.textColored(.{ 0.3, 0.7, 1.0, 1.0 }, "<-", .{});
        }

        if (open) {
            for (entity.children, 0..) |*child, i| {
                renderEntity(child, id * 100 + i + 1);
            }
            zgui.treePop();
        }
    } else {
        // Use bullet for leaf entities
        zgui.bulletText("{s}", .{entity.name});

        if (zgui.isItemClicked(.left)) {
            selected_entity = id;
        }

        // Show selection highlight
        if (is_selected) {
            zgui.sameLine(.{});
            zgui.textColored(.{ 0.3, 0.7, 1.0, 1.0 }, "<-", .{});
        }
    }
}

fn renderPanel() void {
    zgui.text("Scene Hierarchy", .{});
    zgui.separator();

    // Toolbar
    if (zgui.button("+", .{ .w = 25 })) {
        // Add entity
    }
    zgui.sameLine(.{});
    if (zgui.button("-", .{ .w = 25 })) {
        // Remove entity
    }
    zgui.sameLine(.{});
    if (zgui.button("D", .{ .w = 25 })) {
        // Duplicate
    }

    zgui.separator();

    // Tree view
    for (&scene_root, 0..) |*entity, i| {
        renderEntity(entity, i + 1);
    }
}

pub const hierarchy_module = module.Module{
    .name = "hierarchy",
    .display_name = "Hierarchy",
    .render_panel = renderPanel,
    .is_open = &is_open,
};
