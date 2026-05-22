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
const atlas_ui = @import("../atlas_ui.zig");
const gizmos = @import("../gizmos.zig");
const prefab_index_mod = @import("../prefab_index.zig");
const dnd = @import("dnd.zig");

pub const min_h: f32 = 240;

/// One-shot sink for a component drag-drop that landed on the canvas
/// (#143). The caller passes `&slot` through `State.component_drop`;
/// after `render` returns, the caller checks `slot.*` and (if set)
/// appends a new child entity carrying the component. The name is
/// copied into a fixed buffer so the receiver doesn't depend on
/// ImGui's payload buffer staying alive past the accept callback.
pub const ComponentDrop = struct {
    name_buf: [dnd.PAYLOAD_NAME_CAP]u8 = [_]u8{0} ** dnd.PAYLOAD_NAME_CAP,
    name_len: u8 = 0,

    pub fn name(self: *const ComponentDrop) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

/// Mutable per-tab state the viewport reads and writes.
pub const State = struct {
    pan: *[2]f32,
    zoom: *f32,
    selected_idx: *?usize,
    is_dirty: *bool,
    drag_armed: *bool,
    /// World-space position of the dragged entity at the moment the
    /// drag was armed. The drag handler computes the live target as
    /// `drag_start_world + total_drag_delta / zoom` (snapped when
    /// applicable) rather than accumulating incremental deltas onto
    /// the entity's running position; the accumulated approach
    /// silently breaks snap because the running position keeps
    /// rounding back to the same cell while the cursor drifts.
    drag_start_world: *[2]f32,
    /// Optional sink for right-click world coordinates. The viewport
    /// writes the world-space point when the user right-clicks an
    /// empty area of the canvas (no entity under the cursor); the
    /// caller is then responsible for opening its own context menu
    /// (e.g. via `zgui.openPopup`). Null when the caller doesn't
    /// care about right-clicks — the prefab editor sets this to
    /// null today.
    right_click_world: ?*?[2]f32 = null,
    /// Optional sink for "double-click on a scene entity that
    /// references a prefab". The viewport writes the entity index
    /// when the user double-clicks inside the AABB of a prefab-
    /// referencing scene entity; the caller is then responsible for
    /// opening the prefab editor for `entities[idx].prefab`. Null
    /// when the caller doesn't want the descend-into-prefab path
    /// (the prefab editor itself sets this to null — there's no
    /// further level to descend into).
    double_click_entity: ?*?usize = null,
    /// Optional sink for "right-click on a scene entity". The
    /// viewport writes the entity index when the right-click lands
    /// on an entity (AABB or radial hit), so the caller can open a
    /// per-entity context menu (e.g. Delete) at the click site.
    /// `right_click_world` continues to fire for *empty-canvas* right-
    /// clicks; the two sinks are mutually exclusive on any given
    /// click — entity-hit goes to `right_click_entity`, miss goes to
    /// `right_click_world`.
    right_click_entity: ?*?usize = null,
    /// Optional sink for "a component dragged from the project tree's
    /// components/ folder was dropped on the canvas" (#143). The
    /// viewport fills the `ComponentDrop` with the component name;
    /// the caller appends a new child entity with the matching
    /// prefab's body Sprite and the component as an unmodeled extra.
    /// Null in editor tabs that don't accept component drops.
    component_drop: ?*?ComponentDrop = null,
    /// World-space spacing for the visual grid AND, when snapping is on,
    /// the snap step. One number drives both so the grid the user sees
    /// is the grid their drags land on. Default 16 matches what most 2D
    /// engines treat as a pixel-tile baseline; flying-platform-labelle's
    /// world is much smaller-stepped so users will typically dial this
    /// down. Must be > 0.
    grid_step: f32 = 16,
    /// When true, the dragged entity's running position is rounded to
    /// the nearest multiple of `grid_step` (relative to `snap_origin`)
    /// before being written back. The visual grid is always drawn.
    snap_enabled: bool = false,
    /// World-space origin for the grid. The default keeps the grid
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
    prefab_index: ?*const prefab_index_mod.Index,
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

    drawGrid(dl, canvas_min, canvas_max, state.pan.*, state.zoom.*, state.grid_step);
    drawEntities(dl, canvas_min, state, entities, atlas_index, prefab_index);
    if (show_gizmos) if (gizmo_index) |gi| {
        drawGizmoOverlay(dl, canvas_min, state, entities, entity_extras, gi);
    };

    // Accept middle-button as well as left so the middle-mouse pan
    // handler below (`isItemActive()` block) is reachable. ImGui
    // requires explicit opt-in for any non-left button on
    // InvisibleButton — without `mouse_button_middle`, `isItemActive`
    // never goes true under a middle-only drag.
    _ = zgui.invisibleButton("##canvas_drag", .{
        .w = canvas_size[0],
        .h = canvas_size[1],
        .flags = .{ .mouse_button_left = true, .mouse_button_middle = true },
    });

    // Drag-drop target for components from the project tree (#143).
    // Must attach to the LAST submitted item (the invisibleButton
    // above) so `beginDragDropTarget` picks up the canvas region.
    // Gated on `component_drop` being non-null — only editors that
    // know how to consume the drop (the prefab editor today) wire
    // this sink.
    if (state.component_drop) |sink| {
        if (zgui.beginDragDropTarget()) {
            defer zgui.endDragDropTarget();
            if (zgui.acceptDragDropPayload(dnd.COMPONENT_TYPE, .{})) |raw| {
                if (raw.data) |ptr| {
                    const p: *const dnd.ComponentPayload = @ptrCast(@alignCast(ptr));
                    const stem = dnd.unpackComponent(p);
                    var out: ComponentDrop = .{};
                    const n = @min(stem.len, out.name_buf.len);
                    @memcpy(out.name_buf[0..n], stem[0..n]);
                    out.name_len = @intCast(n);
                    sink.* = out;
                }
            }
        }
    }

    // Holding Space turns left-click+drag into a pan grab — Figma /
    // Photoshop convention, works on any input device (Mac trackpads
    // have no middle button, so middle-mouse alone leaves panning
    // unreachable for the majority of users on this platform).
    const space_held = zgui.isKeyDown(.space);

    // Mouse-down: hit-test entity AABBs first (so a click anywhere on
    // an expanded prefab's visual footprint grabs the whole room),
    // fall back to the radial marker hit-test for degenerate cases
    // (no sprite, no prefab — the AABB collapses to a point and
    // `entityWorldAabb` returns the radial-equivalent box). Arm
    // drag-to-move only when the click landed on something AND Space
    // isn't held — Space + left-click is reserved for panning.
    if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left) and !space_held) {
        const mouse = zgui.getMousePos();
        const hit = hitTestEntityAabb(entities, mouse, canvas_min, state.pan.*, state.zoom.*, atlas_index, prefab_index) orelse
            hitTestEntity(entities, mouse, canvas_min, state.pan.*, state.zoom.*);
        state.selected_idx.* = hit;
        state.drag_armed.* = hit != null;
        // Snapshot the entity's starting world position so the drag
        // handler can compute the live target from total delta. ImGui
        // also begins accumulating mouse-drag delta from this click,
        // so the math lines up: position = start + delta/zoom.
        if (hit) |idx| {
            if (idx < entities.len) {
                if (entities[idx].position) |p| {
                    state.drag_start_world.* = .{ p.x, p.y };
                }
            }
        }
    }
    if (!zgui.isMouseDown(.left)) state.drag_armed.* = false;

    // Double-click on a scene entity whose AABB contains the cursor
    // surfaces the index to the caller, which opens the entity's
    // referenced prefab as a tab (only the scene editor wires this —
    // the prefab editor passes null because there's no further level
    // to descend into).
    if (state.double_click_entity) |sink| {
        if (zgui.isItemHovered(.{}) and zgui.isMouseDoubleClicked(.left) and !space_held) {
            const mouse = zgui.getMousePos();
            // Same fallback chain the single + right-click handlers
            // use: AABB first, then radial. Without the radial chain a
            // degenerate entity (no AABB resolves) would be
            // single-clickable but un-double-clickable, even though
            // its `prefab` field may still be set and openable.
            sink.* = hitTestEntityAabb(entities, mouse, canvas_min, state.pan.*, state.zoom.*, atlas_index, prefab_index) orelse
                hitTestEntity(entities, mouse, canvas_min, state.pan.*, state.zoom.*);
        }
    }

    // Right-click splits two ways: empty canvas → world-pos sink for
    // the caller's "add entity here" menu; on-entity → entity-index
    // sink for the caller's per-entity menu (Delete, etc.). Mutually
    // exclusive — a single click fills only one sink.
    if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.right)) {
        const mouse = zgui.getMousePos();
        const hit = hitTestEntityAabb(entities, mouse, canvas_min, state.pan.*, state.zoom.*, atlas_index, prefab_index) orelse
            hitTestEntity(entities, mouse, canvas_min, state.pan.*, state.zoom.*);
        if (hit) |idx| {
            if (state.right_click_entity) |sink| sink.* = idx;
        } else if (state.right_click_world) |sink| {
            sink.* = worldFromScreen(mouse, canvas_min, state.pan.*, state.zoom.*);
        }
    }

    if (zgui.isItemActive()) {
        if (zgui.isMouseDragging(.middle, 0)) {
            const d = zgui.getMouseDragDelta(.middle, .{});
            state.pan[0] += d[0];
            state.pan[1] += d[1];
            zgui.resetMouseDragDelta(.middle);
        }
        // Space + left-drag pan. `!drag_armed` keeps an in-flight
        // drag-to-move exclusive: pressing Space mid-drag must not
        // hijack the left button and call `resetMouseDragDelta(.left)`,
        // which would corrupt the delta drag-to-move reads each frame
        // (see comment in the drag-to-move branch below — that delta
        // is deliberately never reset). Combined with the click-time
        // `!space_held` gate, this means: drag-to-move owns the left
        // button from press to release; pan owns it from press (with
        // Space) to release.
        else if (space_held and !state.drag_armed.* and zgui.isMouseDragging(.left, 0)) {
            const d = zgui.getMouseDragDelta(.left, .{});
            state.pan[0] += d[0];
            state.pan[1] += d[1];
            zgui.resetMouseDragDelta(.left);
        } else if (state.drag_armed.*) {
            if (state.selected_idx.*) |idx| {
                if (idx < entities.len and zgui.isMouseDragging(.left, 0)) {
                    const e = &entities[idx];
                    if (e.position) |*pos| {
                        // Total delta in screen pixels since the
                        // drag started — NOT incremental. We DON'T
                        // reset it, so each frame we compute the
                        // live target from the snapshot, which makes
                        // snap behave (the running position would
                        // otherwise round back to its cell every
                        // frame while the cursor drifted away).
                        const d = zgui.getMouseDragDelta(.left, .{});
                        var nx = state.drag_start_world[0] + d[0] / state.zoom.*;
                        // World +y is up; screen +y is down.
                        var ny = state.drag_start_world[1] - d[1] / state.zoom.*;
                        if (state.snap_enabled and state.grid_step > 0) {
                            nx = snapValue(nx, state.snap_origin[0], state.grid_step);
                            ny = snapValue(ny, state.snap_origin[1], state.grid_step);
                        }
                        if (pos.x != nx or pos.y != ny) {
                            pos.x = nx;
                            pos.y = ny;
                            state.is_dirty.* = true;
                        }
                    }
                }
            }
        }
    }
}

fn drawGrid(dl: zgui.DrawList, cmin: [2]f32, cmax: [2]f32, pan: [2]f32, zoom: f32, grid_world: f32) void {
    if (grid_world <= 0) return;
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
    prefab_index: ?*const prefab_index_mod.Index,
) void {
    for (entities, 0..) |e, i| {
        const pos = e.position orelse continue;
        const px = cmin[0] + state.pan[0] + pos.x * state.zoom.*;
        const py = cmin[1] + state.pan[1] - pos.y * state.zoom.*;
        const selected = state.selected_idx.* == i;

        // Render priority: sprite (when it resolves against the
        // atlas) > rectangle geometry > circle geometry > polygon
        // geometry > expanded prefab tree (if the entity references a
        // prefab) > colored-circle marker. A declared-but-unresolved
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
        if (!drew_visual and e.prefab != null and atlas_index != null and prefab_index != null) {
            drew_visual = drawPrefabAtPosition(
                dl,
                e.prefab.?,
                px,
                py,
                state.zoom.*,
                atlas_index.?,
                prefab_index.?,
                0,
            );
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
            // Outline the entity's full footprint (AABB of its sprite
            // or expanded prefab tree) so the user can see the whole
            // grabbable region. Falls back to a circle around the
            // anchor when no AABB resolves (point-only entities).
            if (entityWorldAabb(e, atlas_index, prefab_index)) |aabb| {
                const sx0 = cmin[0] + state.pan[0] + aabb.min[0] * state.zoom.*;
                const sy0 = cmin[1] + state.pan[1] - aabb.max[1] * state.zoom.*; // world y_max → screen y_min
                const sx1 = cmin[0] + state.pan[0] + aabb.max[0] * state.zoom.*;
                const sy1 = cmin[1] + state.pan[1] - aabb.min[1] * state.zoom.*;
                dl.addRect(.{
                    .pmin = .{ sx0, sy0 },
                    .pmax = .{ sx1, sy1 },
                    .col = 0xff_ff_d2_40,
                    .thickness = 2.0,
                });
            } else {
                dl.addCircle(.{
                    .p = .{ px, py },
                    .r = 12,
                    .col = 0xff_ff_d2_40,
                    .num_segments = 24,
                    .thickness = 2.0,
                });
            }
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
    return drawSpriteValueAt(dl, sprite.*, px, py, zoom, idx);
}

/// Lower-level sprite draw: takes the Sprite value directly so callers
/// that aren't iterating `Entity`s (e.g. the prefab-child walker) can
/// reuse the atlas resolve + UV math. Returns true on a hit.
fn drawSpriteValueAt(
    dl: zgui.DrawList,
    sprite: scene_io.Sprite,
    px: f32,
    py: f32,
    zoom: f32,
    idx: *const atlas.Index,
) bool {
    const name = std.mem.sliceTo(&sprite.sprite_name, 0);
    // Resolve the sprite name → TextureRef + UV rect via the shared
    // atlas_ui helper (the same resolve the resources panel's sprite
    // thumbnails use).
    const r = atlas_ui.resolve(idx, name) orelse return false;

    // World-space size of one screen pixel of the sprite. No DPI
    // factor — the canvas itself is screen-space.
    const w = @as(f32, @floatFromInt(r.frame_w)) * zoom;
    const h = @as(f32, @floatFromInt(r.frame_h)) * zoom;

    const pivot_name = std.mem.sliceTo(&sprite.pivot, 0);
    const pivot = pivotOffset(pivot_name);
    // pivot is the fraction of the sprite to the right/below the
    // anchor point. e.g. center → (0.5, 0.5); world +y is up, screen
    // +y is down, so we shift the rect down by pivot.y * h.
    const x0 = px - pivot[0] * w;
    const y0 = py - (1.0 - pivot[1]) * h;
    const x1 = x0 + w;
    const y1 = y0 + h;

    dl.addImage(r.tex_ref, .{
        .pmin = .{ x0, y0 },
        .pmax = .{ x1, y1 },
        .uvmin = r.uv0,
        .uvmax = r.uv1,
    });
    return true;
}

/// Walk a prefab tree starting at `(px, py)` (screen space), drawing
/// every Sprite encountered at its child-offset position. When a child
/// itself references another prefab (no Sprite of its own), recurses
/// into that prefab using the child's Position as the offset. Returns
/// true if at least one sprite was actually drawn — caller uses that
/// to decide whether the generic colored marker is still needed.
///
/// The depth limit is a guard against pathological cycles
/// (`prefab A` referencing `B` referencing `A`). Real prefab trees in
/// the example projects bottom out in 2–3 levels.
const max_prefab_depth: u32 = 8;

fn drawPrefabAtPosition(
    dl: zgui.DrawList,
    prefab_name: []const u8,
    px: f32,
    py: f32,
    zoom: f32,
    atlas_index: *const atlas.Index,
    pfx_index: *const prefab_index_mod.Index,
    depth: u32,
) bool {
    if (depth >= max_prefab_depth) return false;
    const pfx = pfx_index.find(prefab_name) orelse return false;

    var drew_any = false;

    // 1. Root sprite (most prefabs that visually represent a single
    // object live here — e.g. `background_sky`).
    if (pfx.entity.sprite) |s| {
        if (drawSpriteValueAt(dl, s.*, px, py, zoom, atlas_index)) drew_any = true;
    }

    // 2. Children: each one has its own Position offset relative to
    // the prefab root. Render its Sprite if present, otherwise recurse
    // into its referenced prefab.
    for (pfx.children) |child| {
        const off = child.position orelse continue;
        const cx = px + off.x * zoom;
        const cy = py - off.y * zoom;
        if (child.sprite) |cs| {
            if (drawSpriteValueAt(dl, cs.*, cx, cy, zoom, atlas_index)) {
                drew_any = true;
                continue;
            }
        }
        if (child.prefab) |sub_name| {
            if (drawPrefabAtPosition(dl, sub_name, cx, cy, zoom, atlas_index, pfx_index, depth + 1)) {
                drew_any = true;
            }
        }
    }

    return drew_any;
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

/// Axis-aligned bounding box in *world* coordinates. World +y is up
/// (same convention `drawEntities` uses for the world→screen map).
pub const WorldAabb = struct {
    min: [2]f32,
    max: [2]f32,

    pub fn expandToInclude(self: *WorldAabb, p: [2]f32) void {
        self.min[0] = @min(self.min[0], p[0]);
        self.min[1] = @min(self.min[1], p[1]);
        self.max[0] = @max(self.max[0], p[0]);
        self.max[1] = @max(self.max[1], p[1]);
    }

    pub fn merge(self: *WorldAabb, other: WorldAabb) void {
        self.expandToInclude(other.min);
        self.expandToInclude(other.max);
    }
};

/// Sprite footprint in world coordinates around `anchor_world`,
/// respecting the named pivot. `pivot.x` is the fraction of the
/// sprite to the right of the anchor; `pivot.y` is the fraction
/// above the anchor (world +y up). E.g. `bottom_center` →
/// `(0.5, 0)` puts the anchor at the sprite's bottom midpoint, so
/// the sprite extends `w/2` left, `w/2` right, `h` up, `0` down.
fn spriteWorldAabb(sprite: scene_io.Sprite, anchor_world: [2]f32, ref: atlas.SpriteRef) WorldAabb {
    const w: f32 = @floatFromInt(ref.frame.w);
    const h: f32 = @floatFromInt(ref.frame.h);
    const pivot_name = std.mem.sliceTo(&sprite.pivot, 0);
    const pivot = pivotOffset(pivot_name);
    return .{
        .min = .{
            anchor_world[0] - pivot[0] * w,
            anchor_world[1] - pivot[1] * h,
        },
        .max = .{
            anchor_world[0] + (1.0 - pivot[0]) * w,
            anchor_world[1] + (1.0 - pivot[1]) * h,
        },
    };
}

/// Walk the prefab tree the same way `drawPrefabAtPosition` does,
/// but accumulate AABBs of every resolvable sprite instead of issuing
/// draw calls. Returns null when nothing in the tree resolves to a
/// drawable sprite — caller can then fall back to a point-radius
/// AABB. Depth-limited by `max_prefab_depth` to guard against cycles.
fn prefabWorldAabb(
    prefab_name: []const u8,
    anchor_world: [2]f32,
    atlas_idx: *const atlas.Index,
    pfx_index: *const prefab_index_mod.Index,
    depth: u32,
) ?WorldAabb {
    if (depth >= max_prefab_depth) return null;
    const pfx = pfx_index.find(prefab_name) orelse return null;

    var box: ?WorldAabb = null;

    if (pfx.entity.sprite) |s| {
        const name = std.mem.sliceTo(&s.sprite_name, 0);
        if (name.len > 0) {
            if (atlas_idx.find(name)) |ref| {
                const sub = spriteWorldAabb(s.*, anchor_world, ref);
                if (box) |*b| b.merge(sub) else box = sub;
            }
        }
    }

    for (pfx.children) |child| {
        const off = child.position orelse continue;
        const child_anchor: [2]f32 = .{ anchor_world[0] + off.x, anchor_world[1] + off.y };
        if (child.sprite) |cs| {
            const cname = std.mem.sliceTo(&cs.sprite_name, 0);
            if (cname.len > 0) {
                if (atlas_idx.find(cname)) |cref| {
                    const sub = spriteWorldAabb(cs.*, child_anchor, cref);
                    if (box) |*b| b.merge(sub) else box = sub;
                    continue;
                }
            }
        }
        if (child.prefab) |sub_name| {
            if (prefabWorldAabb(sub_name, child_anchor, atlas_idx, pfx_index, depth + 1)) |sub| {
                if (box) |*b| b.merge(sub) else box = sub;
            }
        }
    }

    return box;
}

/// World-space AABB of a single scene entity. Matches the visual
/// priority `drawEntities` uses (sprite → rectangle → circle →
/// polygon → expanded prefab tree → degenerate marker box), so the
/// selection outline + hit-test region always agree with what's
/// actually painted on the canvas. Returns null when the entity has
/// no Position — same skip `drawEntities` applies.
pub fn entityWorldAabb(
    entity: scene_io.Entity,
    atlas_idx: ?*const atlas.Index,
    pfx_index: ?*const prefab_index_mod.Index,
) ?WorldAabb {
    const pos = entity.position orelse return null;
    const anchor: [2]f32 = .{ pos.x, pos.y };

    if (entity.sprite) |s| {
        if (atlas_idx) |ai| {
            const name = std.mem.sliceTo(&s.sprite_name, 0);
            if (name.len > 0) {
                if (ai.find(name)) |ref| {
                    return spriteWorldAabb(s.*, anchor, ref);
                }
            }
        }
    }

    // Rectangle is centered on the anchor (see `drawRectangle`).
    if (entity.rectangle) |r| {
        const half_w = r.width * 0.5;
        const half_h = r.height * 0.5;
        return .{
            .min = .{ anchor[0] - half_w, anchor[1] - half_h },
            .max = .{ anchor[0] + half_w, anchor[1] + half_h },
        };
    }

    // Circle is centered on the anchor with `radius` (see `drawCircle`).
    if (entity.circle) |c| {
        const rad = c.radius;
        return .{
            .min = .{ anchor[0] - rad, anchor[1] - rad },
            .max = .{ anchor[0] + rad, anchor[1] + rad },
        };
    }

    // Polygon points are world-space offsets from the anchor; bounds
    // come from the actual point set rather than a constructed
    // rectangle (see `drawPolygon`'s `px + points[i].x * zoom` map).
    if (entity.polygon) |p| {
        if (p.point_count > 0) {
            const first = p.points[0];
            var box: WorldAabb = .{
                .min = .{ anchor[0] + first.x, anchor[1] + first.y },
                .max = .{ anchor[0] + first.x, anchor[1] + first.y },
            };
            var i: u32 = 1;
            while (i < p.point_count) : (i += 1) {
                const pt = p.points[i];
                box.expandToInclude(.{ anchor[0] + pt.x, anchor[1] + pt.y });
            }
            return box;
        }
    }

    if (entity.prefab) |p| {
        if (atlas_idx) |ai| if (pfx_index) |pi| {
            if (prefabWorldAabb(p, anchor, ai, pi, 0)) |b| return b;
        };
    }

    // No drawable shape resolved: return null rather than a fake
    // world-space radius. The screen-pixel `hit_radius` constant is
    // not a world quantity, so using it here scaled the hit region
    // wildly with zoom (huge at 10×, sub-marker at 0.1×) and made
    // the circle-fallback selection draw dead code. Caller chains
    // `hitTestEntityAabb(...) orelse hitTestEntity(...)`, so a null
    // here cleanly hands these degenerate entities back to the
    // existing radial hit test, and the `else` branch in the
    // selection draw renders the small circle around the anchor.
    return null;
}

/// AABB hit-test: pick the topmost (last in iteration order) entity
/// whose world-AABB contains the mouse position. Used by the scene
/// viewport so room-sized prefab footprints become clickable
/// everywhere they paint, not just within `hit_radius` of the
/// anchor.
pub fn hitTestEntityAabb(
    entities: []scene_io.Entity,
    mouse: [2]f32,
    canvas_min: [2]f32,
    pan: [2]f32,
    zoom: f32,
    atlas_idx: ?*const atlas.Index,
    pfx_index: ?*const prefab_index_mod.Index,
) ?usize {
    // World-space mouse so we compare in the same coords the AABB is
    // computed in. World +y is up; screen +y is down, hence the flip.
    const mouse_world: [2]f32 = .{
        (mouse[0] - canvas_min[0] - pan[0]) / zoom,
        -(mouse[1] - canvas_min[1] - pan[1]) / zoom,
    };
    // Reverse iter so overlapping rooms select the one drawn last
    // (= the one painted on top).
    var i: usize = entities.len;
    while (i > 0) {
        i -= 1;
        const aabb = entityWorldAabb(entities[i], atlas_idx, pfx_index) orelse continue;
        if (mouse_world[0] >= aabb.min[0] and mouse_world[0] <= aabb.max[0] and
            mouse_world[1] >= aabb.min[1] and mouse_world[1] <= aabb.max[1])
        {
            return i;
        }
    }
    return null;
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
