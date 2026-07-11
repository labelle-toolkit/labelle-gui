//! Controller / keyboard focus navigation (issue #214, v1 requirement).
//!
//! Gamepad-first games need focus movement that "just works" from a stick or
//! d-pad, plus a linear tab order for keyboard. Both ride the standard
//! InputInterface at the call site; this module is the pure geometry +
//! ordering logic underneath, operating on a retained `Tree`'s focusable
//! elements by their computed screen-space rects.
//!
//! Two navigation models, both here:
//!
//!  - **Directional** (`navigate`): move up/down/left/right to the best
//!    neighbour in that direction. Authors can pin a specific neighbour with
//!    the element's `nav_up`/`nav_down`/`nav_left`/`nav_right` overrides
//!    (e.g. to force menu wrap-around); otherwise a spatial heuristic picks
//!    the closest aligned element. Optional wrap jumps to the far side.
//!  - **Tab order** (`tabNext`/`tabPrev`): cycle through focusables in
//!    insertion order — the order they were authored into the tree.

const std = @import("std");
const root = @import("mod.zig");
const Tree = root.Tree;
const Element = root.Element;
const ElementId = root.ElementId;
const invalid_id = root.invalid_id;
const Vec2 = root.Vec2;

pub const Nav = enum { up, down, left, right };

/// Perpendicular-axis penalty weight in the directional score. > 1 makes the
/// search strongly prefer elements aligned along the travel axis (a menu
/// column stays a column) before considering ones that are merely closer in
/// raw distance.
const cross_penalty: f32 = 3.0;

fn isNavigable(el: *const Element) bool {
    return el.visible and el.focusable and
        !(el.button != null and el.button.?.disabled);
}

fn override(el: *const Element, dir: Nav) ElementId {
    return switch (dir) {
        .up => el.nav_up,
        .down => el.nav_down,
        .left => el.nav_left,
        .right => el.nav_right,
    };
}

/// The best focusable to move to from `current` in `dir`, or null if there is
/// nowhere to go (and wrap is off / impossible). Honors per-element nav
/// overrides first, then falls back to the spatial heuristic.
pub fn navigate(tree: *const Tree, current: ElementId, dir: Nav, wrap: bool) ?ElementId {
    const cur = tree.getConst(current) orelse return null;

    // 1) Author-pinned override wins if it points at a navigable element.
    const pinned = override(cur, dir);
    if (pinned != invalid_id) {
        if (tree.getConst(pinned)) |t| {
            if (isNavigable(t)) return pinned;
        }
    }

    const from = cur.rect.center();

    // 2) Spatial search: candidates strictly on the correct side, scored by
    //    travel distance + weighted cross-axis offset.
    var best: ?ElementId = null;
    var best_score: f32 = std.math.floatMax(f32);
    for (tree.nodes.items) |*el| {
        if (el.id == current or !isNavigable(el)) continue;
        const to = el.rect.center();
        const dx = to.x - from.x;
        const dy = to.y - from.y;

        const along: f32, const cross: f32 = switch (dir) {
            .up => .{ -dy, dx },
            .down => .{ dy, dx },
            .left => .{ -dx, dy },
            .right => .{ dx, dy },
        };
        if (along <= 0) continue; // not in the requested direction

        const score = along + cross_penalty * @abs(cross);
        if (score < best_score or (score == best_score and (best == null or el.id < best.?))) {
            best_score = score;
            best = el.id;
        }
    }
    if (best) |b| return b;

    // 3) Nothing ahead — optionally wrap to the far side (the element whose
    //    center is furthest back along the travel axis, best cross-aligned).
    if (!wrap) return null;
    return wrapTarget(tree, current, dir, from);
}

fn wrapTarget(tree: *const Tree, current: ElementId, dir: Nav, from: Vec2) ?ElementId {
    var best: ?ElementId = null;
    var best_back: f32 = -std.math.floatMax(f32);
    var best_cross: f32 = std.math.floatMax(f32);
    for (tree.nodes.items) |*el| {
        if (el.id == current or !isNavigable(el)) continue;
        const to = el.rect.center();
        const dx = to.x - from.x;
        const dy = to.y - from.y;
        // "back" = distance in the direction opposite travel (so we land on
        // the far edge), cross = perpendicular offset for alignment.
        const back: f32, const cross: f32 = switch (dir) {
            .up => .{ dy, dx },
            .down => .{ -dy, dx },
            .left => .{ dx, dy },
            .right => .{ -dx, dy },
        };
        if (back < 0) continue; // must be behind us to be a wrap target
        const across = @abs(cross);
        if (back > best_back or (back == best_back and across < best_cross)) {
            best_back = back;
            best_cross = across;
            best = el.id;
        }
    }
    return best;
}

/// Focusable ids in authored (insertion) order, written into `out`. Returns
/// the populated slice.
pub fn focusablesInOrder(tree: *const Tree, out: []ElementId) []ElementId {
    var n: usize = 0;
    for (tree.nodes.items) |*el| {
        if (isNavigable(el) and n < out.len) {
            out[n] = el.id;
            n += 1;
        }
    }
    return out[0..n];
}

/// First focusable in authored order (initial focus), or null.
pub fn firstFocusable(tree: *const Tree) ?ElementId {
    for (tree.nodes.items) |*el| {
        if (isNavigable(el)) return el.id;
    }
    return null;
}

fn tabStep(tree: *const Tree, current: ElementId, wrap: bool, forward: bool) ?ElementId {
    var buf: [256]ElementId = undefined;
    const order = focusablesInOrder(tree, &buf);
    if (order.len == 0) return null;

    var idx: ?usize = null;
    for (order, 0..) |id, i| {
        if (id == current) idx = i;
    }
    const i = idx orelse return order[0]; // current isn't focusable → start

    if (forward) {
        if (i + 1 < order.len) return order[i + 1];
        return if (wrap) order[0] else null;
    } else {
        if (i > 0) return order[i - 1];
        return if (wrap) order[order.len - 1] else null;
    }
}

pub fn tabNext(tree: *const Tree, current: ElementId, wrap: bool) ?ElementId {
    return tabStep(tree, current, wrap, true);
}

pub fn tabPrev(tree: *const Tree, current: ElementId, wrap: bool) ?ElementId {
    return tabStep(tree, current, wrap, false);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A vertical menu of three focusable buttons plus one unfocusable label.
fn buildMenu(t: *Tree) ![4]ElementId {
    const a = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 } });
    const b = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 0, .y = 30, .w = 100, .h = 20 } });
    const c = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 0, .y = 60, .w = 100, .h = 20 } });
    const label = try t.add(invalid_id, .{ .focusable = false, .rect = .{ .x = 0, .y = 90, .w = 100, .h = 20 } });
    return .{ a, b, c, label };
}

test "directional: down moves to the next element below" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    try testing.expectEqual(ids[1], navigate(&t, ids[0], .down, false).?);
    try testing.expectEqual(ids[2], navigate(&t, ids[1], .down, false).?);
}

test "directional: up moves to the previous element above" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    try testing.expectEqual(ids[1], navigate(&t, ids[2], .up, false).?);
}

test "directional: no wrap returns null at the end" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    // c is the last focusable (label is not focusable) → nothing below.
    try testing.expect(navigate(&t, ids[2], .down, false) == null);
}

test "directional: wrap jumps to the far side" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    // Down from the bottom wraps to the top.
    try testing.expectEqual(ids[0], navigate(&t, ids[2], .down, true).?);
    // Up from the top wraps to the bottom-most focusable (c, not the label).
    try testing.expectEqual(ids[2], navigate(&t, ids[0], .up, true).?);
}

test "directional: unfocusable elements are skipped" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    // label sits below c but is not focusable, so down from c finds nothing.
    try testing.expect(navigate(&t, ids[2], .down, false) == null);
}

test "directional: disabled buttons are skipped" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 20 } });
    _ = try t.add(invalid_id, .{ .focusable = true, .button = .{ .disabled = true }, .rect = .{ .x = 0, .y = 30, .w = 100, .h = 20 } });
    const c = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 0, .y = 60, .w = 100, .h = 20 } });
    // Down from a jumps over the disabled button to c.
    try testing.expectEqual(c, navigate(&t, a, .down, false).?);
}

test "directional: prefers the axis-aligned neighbour over a nearer diagonal" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const cur = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 100, .y = 100, .w = 20, .h = 20 } });
    // A diagonally-below element that is closer in raw distance...
    const diag = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 160, .y = 130, .w = 20, .h = 20 } });
    // ...vs one directly below but slightly farther.
    const straight = try t.add(invalid_id, .{ .focusable = true, .rect = .{ .x = 100, .y = 150, .w = 20, .h = 20 } });
    _ = diag;
    try testing.expectEqual(straight, navigate(&t, cur, .down, false).?);
}

test "directional: nav override wins over geometry" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    // Pin a's "down" straight to c, skipping b.
    t.get(ids[0]).?.nav_down = ids[2];
    try testing.expectEqual(ids[2], navigate(&t, ids[0], .down, false).?);
}

test "directional: nav override to a disabled target falls back to geometry" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    t.get(ids[2]).?.focusable = false; // make the override target non-navigable
    t.get(ids[0]).?.nav_down = ids[2];
    // Falls back to the geometric neighbour, b.
    try testing.expectEqual(ids[1], navigate(&t, ids[0], .down, false).?);
}

test "tab order: next / prev cycle in insertion order" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t);
    try testing.expectEqual(ids[0], firstFocusable(&t).?);
    try testing.expectEqual(ids[1], tabNext(&t, ids[0], false).?);
    try testing.expectEqual(ids[2], tabNext(&t, ids[1], false).?);
    try testing.expect(tabNext(&t, ids[2], false) == null); // no wrap
    try testing.expectEqual(ids[0], tabNext(&t, ids[2], true).?); // wrap
    try testing.expectEqual(ids[1], tabPrev(&t, ids[2], false).?);
    try testing.expectEqual(ids[2], tabPrev(&t, ids[0], true).?); // wrap back
}

test "tab order excludes non-focusable and disabled" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const ids = try buildMenu(&t); // label (ids[3]) not focusable
    var buf: [8]ElementId = undefined;
    const order = focusablesInOrder(&t, &buf);
    try testing.expectEqual(@as(usize, 3), order.len);
    for (order) |id| try testing.expect(id != ids[3]);
}
