//! The small row/column/anchor constraint pass for `UiLayout` (issue #214).
//!
//! Deliberately linear, not flexbox: a container with a `Layout` stacks its
//! direct children along one axis with a gap and content padding, and places
//! each child on the cross axis by an anchor (or stretches it). That is the
//! whole model — CSS-grade layout is an explicit v1 non-goal.
//!
//! `apply` walks the retained tree from a root, writing each element's
//! computed screen-space `rect` (the layout *output*) from its preferred
//! `size` and the parent's arrangement. Elements without a `Layout` still get
//! anchored inside the slot their parent hands them, so leaves (panels, text,
//! buttons) land correctly; containers with a `Layout` additionally arrange
//! their own children.

const std = @import("std");
const root = @import("mod.zig");
const Tree = root.Tree;
const Element = root.Element;
const ElementId = root.ElementId;
const invalid_id = root.invalid_id;
const Rect = root.Rect;
const Vec2 = root.Vec2;
const Anchor = root.Anchor;
const Direction = root.Direction;
const Layout = root.Layout;

/// Place a box of `size` inside `slot` per `anchor`. A zero size component
/// means "fill that axis of the slot".
fn anchorRect(size: Vec2, anchor: Anchor, slot: Rect) Rect {
    const w = if (size.x > 0) size.x else slot.w;
    const h = if (size.y > 0) size.y else slot.h;
    const f = anchor.fractions();
    return .{
        .x = slot.x + (slot.w - w) * f.x,
        .y = slot.y + (slot.h - h) * f.y,
        .w = w,
        .h = h,
    };
}

/// Compute layout for the subtree rooted at `root_id`, treating `screen` as
/// the slot the root is anchored within. Allocates a small scratch buffer per
/// container level (freed immediately), so a deep tree stays O(depth) in
/// scratch memory.
pub fn apply(tree: *Tree, root_id: ElementId, screen: Rect) !void {
    const el = tree.get(root_id) orelse return;
    el.rect = anchorRect(el.size, el.anchor, screen);
    try layoutChildren(tree, root_id);
}

fn layoutChildren(tree: *Tree, parent_id: ElementId) !void {
    const count = tree.childCount(parent_id);
    if (count == 0) return;

    const parent = tree.get(parent_id).?;
    const parent_rect = parent.rect;

    const ids = try tree.allocator.alloc(ElementId, count);
    defer tree.allocator.free(ids);
    _ = tree.childrenOf(parent_id, ids);

    if (parent.layout) |lay| {
        try arrangeLinear(tree, parent_rect, lay, ids);
    } else {
        // No arrangement: each child anchors inside the parent's whole rect.
        for (ids) |cid| {
            const child = tree.get(cid).?;
            child.rect = anchorRect(child.size, child.anchor, parent_rect);
        }
    }

    // Recurse: a child may itself be a container.
    for (ids) |cid| try layoutChildren(tree, cid);
}

fn arrangeLinear(tree: *Tree, parent_rect: Rect, lay: Layout, ids: []const ElementId) !void {
    const content = parent_rect.inset(lay.padding);
    const is_row = lay.direction == .row;
    const cross_frac = if (is_row) lay.cross_align.fractions().y else lay.cross_align.fractions().x;

    var cursor: f32 = if (is_row) content.x else content.y;
    for (ids) |cid| {
        const child = tree.get(cid).?;

        // Main-axis size comes from the child's preferred size along the
        // travel axis (0 → zero-sized track cell; authors give buttons/text
        // an explicit size, or wrap them in a sized container).
        const main_size = if (is_row) child.size.x else child.size.y;

        // Cross-axis: stretch to fill, or place by cross_align.
        const cross_extent = if (is_row) content.h else content.w;
        const cross_size = if (lay.stretch_cross)
            cross_extent
        else if (is_row)
            (if (child.size.y > 0) child.size.y else cross_extent)
        else
            (if (child.size.x > 0) child.size.x else cross_extent);
        const cross_start = (if (is_row) content.y else content.x) +
            (cross_extent - cross_size) * cross_frac;

        child.rect = if (is_row) .{
            .x = cursor,
            .y = cross_start,
            .w = main_size,
            .h = cross_size,
        } else .{
            .x = cross_start,
            .y = cursor,
            .w = cross_size,
            .h = main_size,
        };

        cursor += main_size + lay.gap;
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "root fills the screen when it has no explicit size" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{});
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    try testing.expect(t.get(r).?.rect.eqlApprox(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 0.001));
}

test "root anchors its explicit size within the screen" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{ .size = .{ .x = 200, .y = 100 }, .anchor = .center });
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 800, .h = 600 });
    // centered: (800-200)/2 = 300, (600-100)/2 = 250
    try testing.expect(t.get(r).?.rect.eqlApprox(.{ .x = 300, .y = 250, .w = 200, .h = 100 }, 0.001));
}

test "column stacks children with gap and padding" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{
        .layout = .{ .direction = .column, .gap = 10, .padding = root.Insets.uniform(5) },
    });
    const a = try t.add(r, .{ .size = .{ .x = 100, .y = 30 } });
    const b = try t.add(r, .{ .size = .{ .x = 100, .y = 40 } });
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 200, .h = 300 });

    // First child starts at padding origin (5,5).
    try testing.expectApproxEqAbs(@as(f32, 5), t.get(a).?.rect.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), t.get(a).?.rect.h, 0.001);
    // Second child = 5 + 30 + gap(10) = 45.
    try testing.expectApproxEqAbs(@as(f32, 45), t.get(b).?.rect.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 40), t.get(b).?.rect.h, 0.001);
}

test "row stacks children horizontally" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{ .layout = .{ .direction = .row, .gap = 8 } });
    const a = try t.add(r, .{ .size = .{ .x = 50, .y = 20 } });
    const b = try t.add(r, .{ .size = .{ .x = 60, .y = 20 } });
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 300, .h = 40 });
    try testing.expectApproxEqAbs(@as(f32, 0), t.get(a).?.rect.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 58), t.get(b).?.rect.x, 0.001); // 50 + gap 8
}

test "stretch_cross fills the cross axis" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{
        .layout = .{ .direction = .column, .stretch_cross = true, .padding = root.Insets.uniform(10) },
    });
    const a = try t.add(r, .{ .size = .{ .x = 50, .y = 30 } }); // x ignored under stretch
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 200, .h = 300 });
    // content width = 200 - 20 = 180, child stretched to it, x at padding.
    try testing.expectApproxEqAbs(@as(f32, 10), t.get(a).?.rect.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 180), t.get(a).?.rect.w, 0.001);
}

test "cross_align centers children on the cross axis" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const r = try t.add(invalid_id, .{
        .layout = .{ .direction = .column, .cross_align = .center },
    });
    const a = try t.add(r, .{ .size = .{ .x = 100, .y = 20 } });
    try apply(&t, r, .{ .x = 0, .y = 0, .w = 300, .h = 300 });
    // centered horizontally: (300-100)/2 = 100
    try testing.expectApproxEqAbs(@as(f32, 100), t.get(a).?.rect.x, 0.001);
}

test "nested containers lay out recursively" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const outer = try t.add(invalid_id, .{ .layout = .{ .direction = .column, .padding = root.Insets.uniform(10) } });
    const inner = try t.add(outer, .{ .size = .{ .x = 100, .y = 100 }, .layout = .{ .direction = .row, .gap = 5 } });
    const leaf = try t.add(inner, .{ .size = .{ .x = 20, .y = 20 } });
    try apply(&t, outer, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    // inner starts at outer's padding (10,10).
    try testing.expectApproxEqAbs(@as(f32, 10), t.get(inner).?.rect.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), t.get(inner).?.rect.y, 0.001);
    // leaf sits at inner's content origin (inner has no padding) → (10,10).
    try testing.expectApproxEqAbs(@as(f32, 10), t.get(leaf).?.rect.x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), t.get(leaf).?.rect.w, 0.001);
}
