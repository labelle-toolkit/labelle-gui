//! Shared 2D viewport — pan/zoom canvas with entity markers, hit-
//! testing, and drag-to-move. Used by the scene editor (operating on
//! `Scene.entities`) and the prefab editor (operating on
//! `LoadedPrefab.children`).
//!
//! Caller hands in pointers to its own pan/zoom/selection/dirty
//! state so the viewport reads + writes them in place. The caller
//! also handles the controls bar (Reset view / zoom buttons / Save)
//! — those vary per module.

const std = @import("std");
const zgui = @import("zgui");

const scene_io = @import("../scene_io.zig");

pub const min_h: f32 = 240;

/// Mutable per-tab state the viewport reads and writes.
pub const State = struct {
    pan: *[2]f32,
    zoom: *f32,
    selected_idx: *?usize,
    is_dirty: *bool,
    drag_armed: *bool,
};

/// Pixel radius around an entity marker that counts as a click.
pub const hit_radius: f32 = 10.0;

/// Render the viewport canvas for `entities` into the current
/// imgui window. Caller is responsible for the surrounding container
/// (e.g. a beginChild) and any controls bar.
pub fn render(state: State, entities: []scene_io.Entity) void {
    const avail = zgui.getContentRegionAvail();
    const canvas_h = @max(min_h, avail[1]);
    if (!zgui.beginChild("##canvas", .{
        .w = 0,
        .h = canvas_h,
        .child_flags = .{ .border = true },
    })) {
        zgui.endChild();
        return;
    }
    defer zgui.endChild();

    const dl = zgui.getWindowDrawList();
    const cur_pos = zgui.getCursorScreenPos();
    const canvas_size = zgui.getContentRegionAvail();
    const canvas_min = cur_pos;
    const canvas_max: [2]f32 = .{ cur_pos[0] + canvas_size[0], cur_pos[1] + canvas_size[1] };

    dl.addRectFilled(.{
        .pmin = canvas_min,
        .pmax = canvas_max,
        .col = 0xff202225,
    });

    drawGrid(dl, canvas_min, canvas_max, state.pan.*, state.zoom.*);
    drawEntities(dl, canvas_min, state, entities);

    _ = zgui.invisibleButton("##canvas_drag", .{ .w = canvas_size[0], .h = canvas_size[1], .flags = .{} });

    // Mouse-down: hit-test markers, arm drag-to-move only when the
    // click landed on an entity (otherwise drag in empty space
    // would drift the previously-selected entity).
    if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left)) {
        const mouse = zgui.getMousePos();
        const hit = hitTestEntity(entities, mouse, canvas_min, state.pan.*, state.zoom.*);
        state.selected_idx.* = hit;
        state.drag_armed.* = hit != null;
    }
    if (!zgui.isMouseDown(.left)) state.drag_armed.* = false;

    if (zgui.isItemActive()) {
        if (zgui.isMouseDragging(.middle, 0)) {
            const d = zgui.getMouseDragDelta(.middle, .{});
            state.pan[0] += d[0];
            state.pan[1] += d[1];
            zgui.resetMouseDragDelta(.middle);
        }
        if (state.drag_armed.*) {
            if (state.selected_idx.*) |idx| {
                if (idx < entities.len and zgui.isMouseDragging(.left, 0)) {
                    const e = &entities[idx];
                    if (e.position) |*pos| {
                        const d = zgui.getMouseDragDelta(.left, .{});
                        pos.x += d[0] / state.zoom.*;
                        // World +y is up; screen +y is down.
                        pos.y -= d[1] / state.zoom.*;
                        state.is_dirty.* = true;
                        zgui.resetMouseDragDelta(.left);
                    }
                }
            }
        }
    }
}

fn drawGrid(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, pan: [2]f32, zoom: f32) void {
    const grid_world: f32 = 64;
    const step = grid_world * zoom;
    if (step <= 4) return;

    const col_major: u32 = 0x40_ff_ff_ff;
    const origin_x = cmin[0] + pan[0];
    const origin_y = cmin[1] + pan[1];

    var x = origin_x;
    while (x > cmin[0]) : (x -= step) {}
    while (x < cmax[0]) : (x += step) {
        dl.addLine(.{
            .p1 = .{ x, cmin[1] },
            .p2 = .{ x, cmax[1] },
            .col = col_major,
            .thickness = 1.0,
        });
    }
    var y = origin_y;
    while (y > cmin[1]) : (y -= step) {}
    while (y < cmax[1]) : (y += step) {
        dl.addLine(.{
            .p1 = .{ cmin[0], y },
            .p2 = .{ cmax[0], y },
            .col = col_major,
            .thickness = 1.0,
        });
    }

    dl.addLine(.{ .p1 = .{ origin_x, cmin[1] }, .p2 = .{ origin_x, cmax[1] }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
    dl.addLine(.{ .p1 = .{ cmin[0], origin_y }, .p2 = .{ cmax[0], origin_y }, .col = 0x80_ff_ff_ff, .thickness = 1.0 });
}

fn drawEntities(dl: zgui.DrawList, cmin: [2]f32, state: State, entities: []scene_io.Entity) void {
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = cmin[0] + state.pan[0] + pos.x * state.zoom.*;
        const py = cmin[1] + state.pan[1] - pos.y * state.zoom.*;
        const col = colorForPrefab(e.prefab);
        dl.addCircleFilled(.{
            .p = .{ px, py },
            .r = 6,
            .col = col,
            .num_segments = 16,
        });
        if (state.selected_idx.* == i) {
            dl.addCircle(.{
                .p = .{ px, py },
                .r = 12,
                .col = 0xff_ff_d2_40,
                .num_segments = 24,
                .thickness = 2.0,
            });
        }
        if (e.prefab) |p| {
            dl.addText(.{ px + 8, py - 8 }, 0xff_e0_e0_e0, "{s}", .{p});
        }
    }
}

/// Return the index of the closest entity whose screen-space marker
/// is within `hit_radius` pixels of `mouse`, or null. Pure so zspec
/// can exercise the projection math.
pub fn hitTestEntity(
    entities: []scene_io.Entity,
    mouse: [2]f32,
    canvas_min: [2]f32,
    pan: [2]f32,
    zoom: f32,
) ?usize {
    var best: ?usize = null;
    var best_d2: f32 = hit_radius * hit_radius;
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = canvas_min[0] + pan[0] + pos.x * zoom;
        const py = canvas_min[1] + pan[1] - pos.y * zoom;
        const dx = mouse[0] - px;
        const dy = mouse[1] - py;
        const d2 = dx * dx + dy * dy;
        if (d2 < best_d2) {
            best_d2 = d2;
            best = i;
        }
    }
    return best;
}

fn colorForPrefab(prefab: ?[]const u8) u32 {
    const h = if (prefab) |p| std.hash.Wyhash.hash(0, p) else 0;
    const r: u8 = @truncate((h >> 0) | 0x80);
    const g: u8 = @truncate((h >> 8) | 0x80);
    const b: u8 = @truncate((h >> 16) | 0x80);
    return (@as(u32, 0xff) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}
