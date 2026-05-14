//! Read-only "Prefab contents" section for the scene-editor inspector.
//! When a scene entity references a prefab (e.g. `{ "prefab": "canteen" }`),
//! the scene-side inspector only shows that entity's overridable surface
//! (Position, Sprite, Comment). This section lets the user see *what's
//! inside* the referenced prefab — every typed/extras component on the
//! root, plus each child's components — without leaving the scene tab.
//!
//! Children that themselves reference prefabs recurse, depth-capped so
//! accidental cycles can't hang the UI. Consecutive children sharing a
//! prefab name collapse into a `name (prefab × N)` leaf to keep the
//! panel readable on rooms with many `movement_node` / `seat` instances.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../../scene_io.zig");
const prefab_index = @import("../../prefab_index.zig");

const max_depth: u8 = 5;

/// Render the collapsing header + tree. Caller guarantees `prefab_name`
/// is non-null on the entity; this function takes the name directly so
/// the gating in `inspector.renderEntity` stays a single boolean check.
pub fn render(prefab_name: []const u8, idx: *const prefab_index.Index) void {
    if (!zgui.collapsingHeader("Prefab contents##prefab_contents_section", .{})) return;
    renderNode(prefab_name, idx, 0, 1);
}

fn renderNode(name: []const u8, idx: *const prefab_index.Index, depth: u8, repeat_count: u32) void {
    if (depth >= max_depth) {
        zgui.bullet();
        zgui.textDisabled("… (max depth reached at {s})", .{name});
        return;
    }

    // Grouped repeats render as a non-expandable leaf — we don't want
    // identical chairs to dominate the panel with N copies of the same
    // body.
    if (repeat_count > 1) {
        zgui.bullet();
        zgui.text("{s} (prefab × {d})", .{ name, repeat_count });
        return;
    }

    const entry = idx.find(name) orelse {
        zgui.bullet();
        zgui.textDisabled("{s} (prefab not found in cache)", .{name});
        return;
    };

    var label_buf: [256:0]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "{s}", .{name}) catch return;
    if (!zgui.treeNode(label)) return;
    defer zgui.treePop();

    renderComponents(&entry.entity, entry.component_extras);
    renderChildren(entry.children, entry.children_extras, idx, depth + 1);
}

fn renderComponents(entity: *const scene_io.Entity, extras: []const scene_io.ComponentExtra) void {
    if (entity.position) |p| {
        zgui.bullet();
        zgui.text("Position {{ x: {d:.0}, y: {d:.0} }}", .{ p.x, p.y });
    }
    if (entity.sprite) |s| {
        const sprite_name = std.mem.sliceTo(&s.sprite_name, 0);
        zgui.bullet();
        zgui.text("Sprite \"{s}\"", .{sprite_name});
    }
    if (entity.rectangle) |r| {
        zgui.bullet();
        zgui.text("Rectangle {d:.0}×{d:.0}", .{ r.width, r.height });
    }
    if (entity.circle) |c| {
        zgui.bullet();
        zgui.text("Circle r={d:.0}", .{c.radius});
    }
    if (entity.polygon) |p| {
        zgui.bullet();
        zgui.text("Polygon {d} pts", .{p.point_count});
    }
    for (extras) |e| {
        zgui.bullet();
        zgui.text("{s}", .{e.name});
    }
}

fn renderChildren(
    children: []const scene_io.Entity,
    children_extras: []const []const scene_io.ComponentExtra,
    idx: *const prefab_index.Index,
    depth: u8,
) void {
    if (children.len == 0) return;

    var label_buf: [64:0]u8 = undefined;
    const label = std.fmt.bufPrintZ(&label_buf, "children ({d})", .{children.len}) catch return;
    if (!zgui.treeNode(label)) return;
    defer zgui.treePop();

    var i: usize = 0;
    while (i < children.len) {
        const child = &children[i];

        if (child.prefab) |child_prefab| {
            const run_end = consecutivePrefabRunEnd(children, i, child_prefab);
            const count: u32 = @intCast(run_end - i);
            renderNode(child_prefab, idx, depth, count);
            i = run_end;
        } else {
            // No prefab ref — render the child's own components inline.
            const child_extras = if (i < children_extras.len)
                children_extras[i]
            else
                &[_]scene_io.ComponentExtra{};
            var inline_label_buf: [64:0]u8 = undefined;
            const inline_label = std.fmt.bufPrintZ(&inline_label_buf, "child #{d}", .{i}) catch {
                i += 1;
                continue;
            };
            if (zgui.treeNode(inline_label)) {
                renderComponents(child, child_extras);
                zgui.treePop();
            }
            i += 1;
        }
    }
}

/// Find the end index (exclusive) of the run of consecutive children
/// starting at `start` whose `prefab` field equals `name`. Children
/// without a prefab reference break the run. Pub so the central test
/// file can exercise it without going through imgui.
pub fn consecutivePrefabRunEnd(children: []const scene_io.Entity, start: usize, name: []const u8) usize {
    var end = start + 1;
    while (end < children.len) : (end += 1) {
        const next_name = children[end].prefab orelse return end;
        if (!std.mem.eql(u8, next_name, name)) return end;
    }
    return end;
}

