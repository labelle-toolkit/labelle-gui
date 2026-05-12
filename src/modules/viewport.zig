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
const gizmos = @import("../gizmos.zig");

pub const min_h: f32 = 240;

/// Mutable per-tab state the viewport reads and writes.
pub const State = struct {
    pan: *[2]f32,
    zoom: *f32,
    selected_idx: *?usize,
    is_dirty: *bool,
    drag_armed: *bool,
    /// Optional sink for right-click world coordinates. The viewport
    /// writes the world-space point when the user right-clicks an
    /// empty area of the canvas (no entity under the cursor); the
    /// caller is then responsible for opening its own context menu
    /// (e.g. via `zgui.openPopup`). Null when the caller doesn't
    /// care about right-clicks — the prefab editor sets this to
    /// null today.
    right_click_world: ?*?[2]f32 = null,
    /// Optional snap step in world units. When non-null and a drag is
    /// in progress, the dragged entity's running position is rounded to
    /// the nearest multiple of `snap_step` (relative to `snap_origin`)
    /// before being written back. Null disables snapping.
    snap_step: ?f32 = null,
    /// World-space origin for the snap grid. The default keeps the grid
    /// aligned to the world origin; callers can shift it later (no UI
    /// for this yet).
    snap_origin: [2]f32 = .{ 0, 0 },
};

/// Round a single 1-D world coordinate to the nearest snap step relative
/// to `origin`. Pulled out so zspec can exercise the math without an
/// imgui draw context. `step` must be > 0; callers guard with the
/// optional `snap_step` field of `State`.
pub fn snapValue(value: f32, origin: f32, step: f32) f32 {
    return origin + @round((value - origin) / step) * step;
}

/// Pixel radius around an entity marker that counts as a click.
pub const hit_radius: f32 = 10.0;

/// Which visual path `drawEntities` takes for one entity. Pulled out
/// so the priority + unresolved-sprite logic is testable without an
/// ImGui draw context.
pub const RenderPath = enum {
    /// Atlas-resolved sprite was drawn at the entity position.
    sprite,
    /// Sprite either wasn't declared or couldn't resolve; polygon
    /// geometry drew instead.
    polygon,
    /// No drawable component resolved; the colored prefab-tinted
    /// circle marker drew as a last resort.
    marker,
};

/// What `drawEntities` should put on the canvas for one entity, given
/// which components are present and whether the sprite atlas could
/// resolve. `sprite_resolved` is true only when an atlas-backed quad
/// will actually be drawn (atlas index present + name in atlas +
/// non-empty name); see `drawSpriteIfResolved` for the runtime check.
/// `overlay_question` mirrors the inline `?` overlay rule: any
/// declared-but-unresolved sprite gets it, no matter which fallback
/// drew the visual.
pub fn planRender(has_sprite: bool, sprite_resolved: bool, has_polygon: bool) struct {
    path: RenderPath,
    overlay_question: bool,
} {
    if (has_sprite and sprite_resolved) {
        return .{ .path = .sprite, .overlay_question = false };
    }
    const sprite_unresolved = has_sprite and !sprite_resolved;
    if (has_polygon) {
        return .{ .path = .polygon, .overlay_question = sprite_unresolved };
    }
    return .{ .path = .marker, .overlay_question = sprite_unresolved };
}

/// Render the viewport canvas for `entities` into the current
/// imgui window. Caller is responsible for the surrounding container
/// (e.g. a beginChild) and any controls bar.
pub fn render(
    state: State,
    entities: []scene_io.Entity,
    /// Parallel to `entities`: the unmodeled-component list per entity.
    /// Pass an empty slice when the caller doesn't track them
    /// (gizmo matching against unmodeled components is skipped).
    entity_extras: []const []const scene_io.ComponentExtra,
    atlas_index: ?*const atlas.Index,
    gizmo_index: ?*const gizmos.Index,
    show_gizmos: bool,
) void {
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
    if (show_gizmos) if (gizmo_index) |gi| {
        drawGizmoOverlay(dl, canvas_min, state, entities, entity_extras, gi);
    };

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

    // Right-click on empty canvas → caller-driven context menu. We
    // only fire when the click misses every entity marker; clicks
    // *on* an entity stay free for a future per-entity menu.
    if (state.right_click_world) |sink| {
        if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.right)) {
            const mouse = zgui.getMousePos();
            const hit = hitTestEntity(entities, mouse, canvas_min, state.pan.*, state.zoom.*);
            if (hit == null) {
                sink.* = worldFromScreen(mouse, canvas_min, state.pan.*, state.zoom.*);
            }
        }
    }

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
                        if (state.snap_step) |step| {
                            if (step > 0) {
                                pos.x = snapValue(pos.x, state.snap_origin[0], step);
                                pos.y = snapValue(pos.y, state.snap_origin[1], step);
                            }
                        }
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
        // atlas) > rectangle geometry > circle geometry > polygon
        // geometry > colored-circle marker. A declared-but-unresolved
        // sprite still gets a `?` overlay on whatever fallback it
        // falls into.
        const drew_sprite = drawSpriteIfResolved(dl, e, px, py, state.zoom.*, atlas_index);
        var drew_visual = drew_sprite;
        if (!drew_visual and e.rectangle != null) {
            drawRectangle(dl, e.rectangle.?.*, px, py, state.zoom.*);
            drew_visual = true;
        }
        if (!drew_visual and e.circle != null) {
            drawCircle(dl, e.circle.?.*, px, py, state.zoom.*);
            drew_visual = true;
        }
        if (!drew_visual and e.polygon != null) {
            drawPolygon(dl, e.polygon.?.*, px, py, state.zoom.*);
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

/// Draw a `Circle` geometry component centered on `(px, py)` in
/// screen space, scaled by `zoom`. Circle's pivot is implicitly its
/// center — same convention the engine uses for unconfigured shape
/// pivots.
fn drawCircle(dl: zgui.DrawList, circle: scene_io.Circle, px: f32, py: f32, zoom: f32) void {
    const r = circle.radius * zoom;
    // ImGui colors are 0xAABBGGRR. Build it from the u8 RGBA fields.
    const col: u32 = (@as(u32, circle.a) << 24) |
        (@as(u32, circle.b) << 16) |
        (@as(u32, circle.g) << 8) |
        @as(u32, circle.r);
    if (circle.filled) {
        dl.addCircleFilled(.{
            .p = .{ px, py },
            .r = r,
            .col = col,
            .num_segments = 32,
        });
    } else {
        dl.addCircle(.{
            .p = .{ px, py },
            .r = r,
            .col = col,
            .num_segments = 32,
            .thickness = 1.5,
        });
    }
}

/// Draw a `Polygon` geometry component anchored on `(px, py)` in
/// screen space, scaled by `zoom`. Each point is world-space relative
/// to the entity's position; the projection mirrors what `drawEntities`
/// does for the entity marker itself (X scales linearly with zoom; Y
/// is flipped because world +y is up and screen +y is down).
///
/// Filled rendering uses `addConvexPolyFilled` — **only correct for
/// convex polygons**. Authors of non-convex shapes (L-shapes, stars,
/// etc.) should set `filled: false`; the outline path uses a closed
/// polyline which handles both convex and concave geometry. Two or
/// fewer points fall back to an outline only because a filled poly
/// would degenerate. Empty polygons render nothing at all.
fn drawPolygon(dl: zgui.DrawList, poly: scene_io.Polygon, px: f32, py: f32, zoom: f32) void {
    if (poly.point_count == 0) return;

    // Project up to `polygon_max_points` points into a fixed-size
    // stack buffer. Matches the source-of-truth cap on `Polygon`
    // itself, so no allocator is needed.
    var pts: [scene_io.polygon_max_points][2]f32 = undefined;
    var i: u32 = 0;
    while (i < poly.point_count) : (i += 1) {
        pts[i][0] = px + poly.points[i].x * zoom;
        pts[i][1] = py - poly.points[i].y * zoom;
    }
    const live = pts[0..poly.point_count];

    // ImGui colors are 0xAABBGGRR. Build it from the u8 RGBA fields.
    const col: u32 = (@as(u32, poly.a) << 24) |
        (@as(u32, poly.b) << 16) |
        (@as(u32, poly.g) << 8) |
        @as(u32, poly.r);

    if (poly.filled and poly.point_count >= 3) {
        dl.addConvexPolyFilled(live, col);
    } else {
        // Closed polyline so the last segment connects back to the
        // first vertex. For 1–2 points this still gives the user a
        // visual cue (point or line) while they finish authoring.
        dl.addPolyline(live, .{
            .col = col,
            .flags = .{ .closed = poly.point_count >= 3 },
            .thickness = 1.5,
        });
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

/// Convert a screen-space point (`mouse`) back into world space using
/// the viewport's current pan/zoom + canvas origin. Inverse of the
/// `cmin + pan + pos * zoom` projection `drawEntities` does (with Y
/// flipped because world +y is up, screen +y is down). Pure so zspec
/// can exercise the round-trip.
pub fn worldFromScreen(
    mouse: [2]f32,
    canvas_min: [2]f32,
    pan: [2]f32,
    zoom: f32,
) [2]f32 {
    return .{
        (mouse[0] - canvas_min[0] - pan[0]) / zoom,
        -(mouse[1] - canvas_min[1] - pan[1]) / zoom,
    };
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

/// Walk every entity, check every gizmo's predicates, draw the gizmo's
/// Shape on each match. Uses a tiny per-entity scratch list for the
/// component-name set; the cost is O(entities × gizmos × names) but
/// the constants are small (real projects have <50 gizmos).
fn drawGizmoOverlay(
    dl: zgui.DrawList,
    cmin: [2]f32,
    state: State,
    entities: []scene_io.Entity,
    entity_extras: []const []const scene_io.ComponentExtra,
    index: *const gizmos.Index,
) void {
    if (index.entries.items.len == 0) return;

    var name_buf: [32][]const u8 = undefined;
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;

        // Build the entity's direct component name set into a stack
        // buffer — most entities have <8 components so 32 is plenty.
        // `pos` is non-null here (orelse-continue above), so Position
        // is always present.
        var n: usize = 0;
        if (n < name_buf.len) {
            name_buf[n] = "Position";
            n += 1;
        }
        if (e.sprite != null and n < name_buf.len) {
            name_buf[n] = "Sprite";
            n += 1;
        }
        if (i < entity_extras.len) {
            for (entity_extras[i]) |ex| {
                if (n >= name_buf.len) break;
                name_buf[n] = ex.name;
                n += 1;
            }
        }
        const names: []const []const u8 = name_buf[0..n];

        for (index.entries.items) |entry| {
            if (!gizmos.entityMatches(entry.match, entry.exclude, names)) continue;
            const px = cmin[0] + state.pan[0] + (pos.x + entry.offset_x) * state.zoom.*;
            // World +y is up; screen +y is down. Subtract for both
            // the entity's y and the gizmo offset's y.
            const py = cmin[1] + state.pan[1] - (pos.y + entry.offset_y) * state.zoom.*;
            drawShape(dl, entry.shape, entry.color, px, py, state.zoom.*);
        }
    }
}

fn drawShape(dl: zgui.DrawList, shape: gizmos.Shape, color: gizmos.Color, px: f32, py: f32, zoom: f32) void {
    const col: u32 = (@as(u32, color.a) << 24) |
        (@as(u32, color.b) << 16) |
        (@as(u32, color.g) << 8) |
        @as(u32, color.r);
    switch (shape) {
        .circle => |c| {
            const r = c.radius * zoom;
            if (c.fill == .filled) {
                dl.addCircleFilled(.{ .p = .{ px, py }, .r = r, .col = col, .num_segments = 32 });
            } else {
                dl.addCircle(.{ .p = .{ px, py }, .r = r, .col = col, .num_segments = 32, .thickness = c.thickness });
            }
        },
        .rectangle => |r| {
            const half_w = r.width * zoom * 0.5;
            const half_h = r.height * zoom * 0.5;
            const pmin: [2]f32 = .{ px - half_w, py - half_h };
            const pmax: [2]f32 = .{ px + half_w, py + half_h };
            if (r.fill == .filled) {
                dl.addRectFilled(.{ .pmin = pmin, .pmax = pmax, .col = col });
            } else {
                dl.addRect(.{ .pmin = pmin, .pmax = pmax, .col = col, .thickness = r.thickness });
            }
        },
        .line => |l| {
            dl.addLine(.{
                .p1 = .{ px, py },
                .p2 = .{ px + l.end.x * zoom, py - l.end.y * zoom },
                .col = col,
                .thickness = l.thickness,
            });
        },
        .triangle => |t| {
            const p1: [2]f32 = .{ px, py };
            const p2: [2]f32 = .{ px + t.p2.x * zoom, py - t.p2.y * zoom };
            const p3: [2]f32 = .{ px + t.p3.x * zoom, py - t.p3.y * zoom };
            if (t.fill == .filled) {
                dl.addTriangleFilled(.{ .p1 = p1, .p2 = p2, .p3 = p3, .col = col });
            } else {
                dl.addTriangle(.{ .p1 = p1, .p2 = p2, .p3 = p3, .col = col, .thickness = t.thickness });
            }
        },
        .polygon => |p| {
            // Regular n-gon: compute vertices on a circle of `radius`
            // around the entity, then either filled-fan or outline.
            const sides = std.math.clamp(p.sides, 3, 64);
            var pts: [64][2]f32 = undefined;
            var k: usize = 0;
            while (k < sides) : (k += 1) {
                const t: f32 = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(sides));
                const angle = t * std.math.tau;
                pts[k] = .{ px + @cos(angle) * p.radius * zoom, py - @sin(angle) * p.radius * zoom };
            }
            const slice = pts[0..@intCast(sides)];
            if (p.fill == .filled) {
                dl.addConvexPolyFilled(slice, col);
            } else {
                dl.addPolyline(slice, .{ .col = col, .flags = .{ .closed = true }, .thickness = p.thickness });
            }
        },
    }
}

fn colorForPrefab(prefab: ?[]const u8) u32 {
    const h = if (prefab) |p| std.hash.Wyhash.hash(0, p) else 0;
    const r: u8 = @truncate((h >> 0) | 0x80);
    const g: u8 = @truncate((h >> 8) | 0x80);
    const b: u8 = @truncate((h >> 16) | 0x80);
    return (@as(u32, 0xff) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}
