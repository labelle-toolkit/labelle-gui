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
const atlas = @import("../atlas.zig");

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
pub fn render(state: State, entities: []scene_io.Entity, atlas_index: ?*const atlas.Index) void {
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
    drawEntities(dl, canvas_min, state, entities, atlas_index);

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

fn drawEntities(
    dl: zgui.DrawList,
    cmin: [2]f32,
    state: State,
    entities: []scene_io.Entity,
    atlas_index: ?*const atlas.Index,
) void {
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = cmin[0] + state.pan[0] + pos.x * state.zoom.*;
        const py = cmin[1] + state.pan[1] - pos.y * state.zoom.*;
        const selected = state.selected_idx.* == i;

        // Render priority: sprite (when it resolves against the
        // atlas) > rectangle geometry > colored-circle marker.
        // A declared-but-unresolved sprite still gets a `?` overlay
        // on whatever fallback it falls into.
        const drew_sprite = drawSpriteIfResolved(dl, e, px, py, state.zoom.*, atlas_index);
        var drew_visual = drew_sprite;
        if (!drew_visual and e.rectangle != null) {
            drawRectangle(dl, e.rectangle.?.*, px, py, state.zoom.*);
            drew_visual = true;
        }
        if (!drew_visual) {
            const col = colorForPrefab(e.prefab);
            dl.addCircleFilled(.{
                .p = .{ px, py },
                .r = 6,
                .col = col,
                .num_segments = 16,
            });
        }
        if (!drew_sprite and e.sprite != null) {
            dl.addText(.{ px - 3, py - 7 }, 0xff_ff_ff_ff, "?", .{});
        }

        if (selected) {
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

/// Returns true if a textured quad was drawn at `(px, py)` for the
/// given entity. False means caller should fall back to the colored-
/// marker path.
fn drawSpriteIfResolved(
    dl: zgui.DrawList,
    e: scene_io.Entity,
    px: f32,
    py: f32,
    zoom: f32,
    atlas_index: ?*const atlas.Index,
) bool {
    const sprite = e.sprite orelse return false;
    const idx = atlas_index orelse return false;

    const name = std.mem.sliceTo(&sprite.sprite_name, 0);
    if (name.len == 0) return false;
    const ref = idx.find(name) orelse return false;

    const tex_id = idx.textureFor(ref);
    if (tex_id == 0) return false;
    const atlas_size = idx.atlasSize(ref);

    // World-space size of one screen pixel of the sprite. No DPI
    // factor — the canvas itself is screen-space.
    const w = @as(f32, @floatFromInt(ref.frame.w)) * zoom;
    const h = @as(f32, @floatFromInt(ref.frame.h)) * zoom;

    const pivot_name = std.mem.sliceTo(&sprite.pivot, 0);
    const pivot = pivotOffset(pivot_name);
    // pivot is the fraction of the sprite to the right/below the
    // anchor point. e.g. center → (0.5, 0.5); world +y is up, screen
    // +y is down, so we shift the rect down by pivot.y * h.
    const x0 = px - pivot[0] * w;
    const y0 = py - (1.0 - pivot[1]) * h;
    const x1 = x0 + w;
    const y1 = y0 + h;

    const uv0: [2]f32 = .{
        @as(f32, @floatFromInt(ref.frame.x)) / atlas_size[0],
        @as(f32, @floatFromInt(ref.frame.y)) / atlas_size[1],
    };
    const uv1: [2]f32 = .{
        @as(f32, @floatFromInt(ref.frame.x + ref.frame.w)) / atlas_size[0],
        @as(f32, @floatFromInt(ref.frame.y + ref.frame.h)) / atlas_size[1],
    };

    // ImGui 1.92+ TextureRef carries either a managed TextureData
    // pointer (new dynamic-texture API) or a raw backend handle in
    // `tex_id`. The opengl3 backend reads `tex_id` directly when
    // `tex_data` is null, which is exactly what we want for atlas
    // textures we manage ourselves.
    const tex_ref: zgui.TextureRef = .{
        .tex_data = null,
        .tex_id = @enumFromInt(@as(u64, tex_id)),
    };
    dl.addImage(tex_ref, .{
        .pmin = .{ x0, y0 },
        .pmax = .{ x1, y1 },
        .uvmin = uv0,
        .uvmax = uv1,
    });
    return true;
}

/// Draw a `Rectangle` geometry component centered on `(px, py)` in
/// screen space, scaled by `zoom`. Rectangle has no pivot in its
/// own component schema, so we center it on the entity's position —
/// same convention the engine uses for unconfigured shape pivots.
fn drawRectangle(dl: zgui.DrawList, rect: scene_io.Rectangle, px: f32, py: f32, zoom: f32) void {
    const half_w = rect.width * zoom * 0.5;
    const half_h = rect.height * zoom * 0.5;
    const pmin: [2]f32 = .{ px - half_w, py - half_h };
    const pmax: [2]f32 = .{ px + half_w, py + half_h };
    // ImGui colors are 0xAABBGGRR. Build it from the u8 RGBA fields.
    const col: u32 = (@as(u32, rect.a) << 24) |
        (@as(u32, rect.b) << 16) |
        (@as(u32, rect.g) << 8) |
        @as(u32, rect.r);
    if (rect.filled) {
        dl.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = col });
    } else {
        dl.addRect(.{ .pmin = pmin, .pmax = pmax, .col = col, .thickness = 1.5 });
    }
}

/// Convert a pivot name (matching labelle-gfx pivot enums) to a
/// (x, y) fraction in [0, 1] where (0, 0) is bottom-left and (1, 1)
/// is top-right of the sprite. Unknown → center.
fn pivotOffset(name: []const u8) [2]f32 {
    if (std.mem.eql(u8, name, "center")) return .{ 0.5, 0.5 };
    if (std.mem.eql(u8, name, "bottom_center")) return .{ 0.5, 0.0 };
    if (std.mem.eql(u8, name, "top_center")) return .{ 0.5, 1.0 };
    if (std.mem.eql(u8, name, "bottom_left")) return .{ 0.0, 0.0 };
    if (std.mem.eql(u8, name, "bottom_right")) return .{ 1.0, 0.0 };
    if (std.mem.eql(u8, name, "top_left")) return .{ 0.0, 1.0 };
    if (std.mem.eql(u8, name, "top_right")) return .{ 1.0, 1.0 };
    if (std.mem.eql(u8, name, "left_center")) return .{ 0.0, 0.5 };
    if (std.mem.eql(u8, name, "right_center")) return .{ 1.0, 0.5 };
    return .{ 0.5, 0.5 };
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
