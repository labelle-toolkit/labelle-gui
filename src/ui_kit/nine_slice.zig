//! 9-slice decomposition for `UiPanel` (issue #214).
//!
//! Turns one atlas frame plus a border margin into the nine textured quads a
//! resizable panel needs: four fixed corners, four edges that stretch along
//! one axis, and a center that stretches along both. This is the geometry
//! half of a 9-slice panel — the host (editor viewport or engine renderer)
//! uploads the quads; nothing here touches GL.
//!
//! Layout of the returned array (row-major, `row*3 + col`):
//!
//!     0 top-left     1 top        2 top-right
//!     3 left         4 center     5 right
//!     6 bottom-left  7 bottom     8 bottom-right
//!
//! Borders are specified in *source pixels* (how much of the frame stays
//! un-stretched at each edge) and are applied 1:1 to the destination. When
//! the destination is smaller than the combined borders on an axis, the
//! borders are scaled down proportionally so corners never overlap.

const std = @import("std");
const root = @import("mod.zig");
const Rect = root.Rect;
const UvRect = root.UvRect;
const Vec2 = root.Vec2;
const Insets = root.Insets;
const Panel = root.Panel;

pub const Quad = struct {
    dst: Rect,
    uv: UvRect,
};

/// Decompose `dst` into nine quads sampling `frame_uv` from a source frame of
/// `frame_px` size, keeping `border` (source pixels) un-stretched per edge.
pub fn slice(dst: Rect, frame_uv: UvRect, frame_px: Vec2, border: Insets) [9]Quad {
    const fw = if (frame_px.x > 0) frame_px.x else 1;
    const fh = if (frame_px.y > 0) frame_px.y else 1;

    // Destination border widths, scaled down so opposing borders never
    // exceed the available extent (prevents corner overlap on tiny panels).
    var bl = border.left;
    var br = border.right;
    if (bl + br > dst.w and (bl + br) > 0) {
        const s = dst.w / (bl + br);
        bl *= s;
        br *= s;
    }
    var bt = border.top;
    var bb = border.bottom;
    if (bt + bb > dst.h and (bt + bb) > 0) {
        const s = dst.h / (bt + bb);
        bt *= s;
        bb *= s;
    }

    // Destination boundaries.
    const dx = [4]f32{ dst.x, dst.x + bl, dst.right() - br, dst.right() };
    const dy = [4]f32{ dst.y, dst.y + bt, dst.bottom() - bb, dst.bottom() };

    // Source UV boundaries: border pixels → fraction of the frame's UV span.
    const uspan = frame_uv.u1 - frame_uv.u0;
    const vspan = frame_uv.v1 - frame_uv.v0;
    const ux = [4]f32{
        frame_uv.u0,
        frame_uv.u0 + (border.left / fw) * uspan,
        frame_uv.u1 - (border.right / fw) * uspan,
        frame_uv.u1,
    };
    const uy = [4]f32{
        frame_uv.v0,
        frame_uv.v0 + (border.top / fh) * vspan,
        frame_uv.v1 - (border.bottom / fh) * vspan,
        frame_uv.v1,
    };

    var quads: [9]Quad = undefined;
    var row: usize = 0;
    while (row < 3) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            quads[row * 3 + col] = .{
                .dst = .{
                    .x = dx[col],
                    .y = dy[row],
                    .w = dx[col + 1] - dx[col],
                    .h = dy[row + 1] - dy[row],
                },
                .uv = .{
                    .u0 = ux[col],
                    .v0 = uy[row],
                    .u1 = ux[col + 1],
                    .v1 = uy[row + 1],
                },
            };
        }
    }
    return quads;
}

/// Convenience wrapper for an authored `Panel` whose `sprite_name` the host
/// has already resolved to `frame_uv`.
pub fn slicePanel(panel: Panel, frame_uv: UvRect, dst: Rect) [9]Quad {
    return slice(dst, frame_uv, panel.frame_px, panel.border);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

fn quadArea(q: Quad) f32 {
    return q.dst.w * q.dst.h;
}

test "nine quads tile the destination with no gaps or overlaps" {
    const dst: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const q = slice(dst, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 }, .{ .x = 48, .y = 48 }, Insets.uniform(16));

    // Areas of the nine cells sum to the whole destination.
    var total: f32 = 0;
    for (q) |cell| total += quadArea(cell);
    try testing.expectApproxEqAbs(@as(f32, 200 * 100), total, 0.01);

    // Corners keep their source-pixel size (16x16) on the destination.
    try testing.expectApproxEqAbs(@as(f32, 16), q[0].dst.w, 0.001); // top-left
    try testing.expectApproxEqAbs(@as(f32, 16), q[0].dst.h, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 16), q[8].dst.w, 0.001); // bottom-right
    try testing.expectApproxEqAbs(@as(f32, 16), q[8].dst.h, 0.001);

    // Center absorbs the remaining stretch: 200-32 x 100-32.
    try testing.expectApproxEqAbs(@as(f32, 168), q[4].dst.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 68), q[4].dst.h, 0.001);
}

test "adjacent cells share edges (continuous boundaries)" {
    const dst: Rect = .{ .x = 10, .y = 20, .w = 200, .h = 100 };
    const q = slice(dst, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 }, .{ .x = 48, .y = 48 }, Insets.uniform(16));
    // top-left right edge == top-center left edge
    try testing.expectApproxEqAbs(q[0].dst.right(), q[1].dst.x, 0.001);
    // top-center right edge == top-right left edge
    try testing.expectApproxEqAbs(q[1].dst.right(), q[2].dst.x, 0.001);
    // left column bottom == middle column top
    try testing.expectApproxEqAbs(q[0].dst.bottom(), q[3].dst.y, 0.001);
    // whole thing starts at dst origin and ends at dst extent
    try testing.expectApproxEqAbs(@as(f32, 10), q[0].dst.x, 0.001);
    try testing.expectApproxEqAbs(dst.right(), q[2].dst.right(), 0.001);
    try testing.expectApproxEqAbs(dst.bottom(), q[8].dst.bottom(), 0.001);
}

test "uv border maps pixel border into the frame's uv sub-rect" {
    // Frame occupies UV [0.5,1.0] x [0.0,0.5], 64px square, 16px border.
    const frame: UvRect = .{ .u0 = 0.5, .v0 = 0.0, .u1 = 1.0, .v1 = 0.5 };
    const q = slice(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, frame, .{ .x = 64, .y = 64 }, Insets.uniform(16));
    // 16/64 = 0.25 of the 0.5-wide UV span = 0.125 UV. Left border ends at
    // u0 + 0.125 = 0.625.
    try testing.expectApproxEqAbs(@as(f32, 0.625), q[0].uv.u1, 0.0001);
    // Right border starts at u1 - 0.125 = 0.875.
    try testing.expectApproxEqAbs(@as(f32, 0.875), q[2].uv.u0, 0.0001);
    // The center cell samples the frame's inner UV region.
    try testing.expectApproxEqAbs(@as(f32, 0.625), q[4].uv.u0, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.875), q[4].uv.u1, 0.0001);
}

test "borders scale down when destination is smaller than combined borders" {
    // 16+16 = 32 border but only 20px wide → borders scale to 10 each.
    const q = slice(.{ .x = 0, .y = 0, .w = 20, .h = 200 }, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 }, .{ .x = 48, .y = 48 }, Insets.uniform(16));
    try testing.expectApproxEqAbs(@as(f32, 10), q[0].dst.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10), q[2].dst.w, 0.001);
    // Center collapses to zero width but stays non-negative.
    try testing.expectApproxEqAbs(@as(f32, 0), q[4].dst.w, 0.001);
    // Vertical axis is unaffected (200 >> 32).
    try testing.expectApproxEqAbs(@as(f32, 16), q[0].dst.h, 0.001);
    // Still tiles the full destination.
    var total: f32 = 0;
    for (q) |cell| total += quadArea(cell);
    try testing.expectApproxEqAbs(@as(f32, 20 * 200), total, 0.01);
}

test "slicePanel forwards the panel's border and frame size" {
    const panel: Panel = .{ .border = Insets.uniform(8), .frame_px = .{ .x = 32, .y = 32 } };
    const q = slicePanel(panel, .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 }, .{ .x = 0, .y = 0, .w = 64, .h = 64 });
    try testing.expectApproxEqAbs(@as(f32, 8), q[0].dst.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), q[0].uv.u1, 0.0001); // 8/32
}
