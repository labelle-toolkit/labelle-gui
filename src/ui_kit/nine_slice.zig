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
//!
//! ## Stretch vs tile (`Mode`)
//!
//! Stretching the edges/center is right for flat or gradient art, but the
//! consuming games are pixel art: a patterned border (rivets, rope, chain)
//! or a textured fill smears when scaled. `.tile` mode instead repeats the
//! source cell at 1:1 scale — each edge emits ⌈len/segment⌉ quads along its
//! axis and the center emits a 2-D grid — and the final partial repeat is
//! **clipped** via its UV sub-rect rather than squashed, so the pattern's
//! pixel grid stays intact all the way to the seam. `slice` keeps the fixed
//! 3×3 output (indexable, and byte-identical to the pre-tiling behavior);
//! the variable-count tiled decomposition is `sliceTiled`/`sliceAlloc`.

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

// ─── Tile mode ─────────────────────────────────────────────────────────────

/// How the stretchable cells (edges + center) fill their destination span.
pub const Mode = enum {
    /// Scale the source cell to fit — the original behavior. Right for flat
    /// fills and gradients.
    stretch,
    /// Repeat the source cell at 1:1 source-pixel scale, clipping the final
    /// partial repeat via its UV sub-rect. Right for pixel-art patterns,
    /// which smear when scaled.
    tile,
};

/// Comparisons against destination extents / tile remainders treat anything
/// under this (in pixels / source pixels) as zero, so float residue from the
/// boundary subtraction never emits invisible sliver quads.
const tile_eps: f32 = 1e-4;

/// One axis of a 3×3 cell during tiled emission: the destination span, its
/// UV span, and the source-pixel length of one repeat. A non-tiled axis
/// (border bands, and both axes of a corner) emits a single cell covering
/// the whole span — for a border band that is 1:1 by construction, so only
/// the middle spans actually repeat.
const TileAxis = struct {
    start: f32,
    len: f32,
    uv0: f32,
    uv1: f32,
    /// Source-pixel length of one repeat (the frame's middle span). `<= 0`
    /// means the border consumed the whole frame: there is no pattern to
    /// repeat, so the axis degrades to a single stretched cell — exactly
    /// what `.stretch` mode would emit.
    seg: f32,
    tiled: bool,

    fn count(self: TileAxis) usize {
        if (self.len <= tile_eps) return 0;
        if (!self.tiled or self.seg <= tile_eps) return 1;
        const full: usize = @intFromFloat(@floor(self.len / self.seg));
        const rem = self.len - @as(f32, @floatFromInt(full)) * self.seg;
        return full + @intFromBool(rem > tile_eps);
    }

    const Cell = struct { pos: f32, len: f32, uv0: f32, uv1: f32 };

    fn cell(self: TileAxis, i: usize) Cell {
        if (!self.tiled or self.seg <= tile_eps) {
            return .{ .pos = self.start, .len = self.len, .uv0 = self.uv0, .uv1 = self.uv1 };
        }
        const offset = @as(f32, @floatFromInt(i)) * self.seg;
        const remaining = self.len - offset;
        if (remaining >= self.seg - tile_eps) {
            // Full repeat: whole source cell.
            return .{ .pos = self.start + offset, .len = self.seg, .uv0 = self.uv0, .uv1 = self.uv1 };
        }
        // Final partial repeat: CLIP the source cell by shrinking the UV
        // sub-rect proportionally — never squash a full cell into the
        // remainder, which would break the pattern's pixel grid.
        const frac = remaining / self.seg;
        return .{
            .pos = self.start + offset,
            .len = remaining,
            .uv0 = self.uv0,
            .uv1 = self.uv0 + frac * (self.uv1 - self.uv0),
        };
    }
};

/// Tiled 9-slice decomposition. Regions are walked in the same row-major
/// 3×3 order as `slice` (corners/edge bands share `slice`'s exact
/// boundaries), each region emitting its repeats row-major; zero-area cells
/// are skipped entirely, so every returned quad is drawable as-is. Caller
/// owns the returned slice (`allocator.free`).
///
/// Quad count grows with `dest extent / frame middle span` — a 16px-segment
/// frame over a 4k panel is a few hundred quads, which is still trivial for
/// any batcher, but hosts tiling *huge* rects from *tiny* frames should know
/// the cost lives here.
pub fn sliceTiled(
    allocator: std.mem.Allocator,
    dst: Rect,
    frame_uv: UvRect,
    frame_px: Vec2,
    border: Insets,
) std.mem.Allocator.Error![]Quad {
    // Reuse the stretch decomposition for every boundary: corners and border
    // bands are identical in both modes, and deriving the tiled spans from
    // the same cells keeps the two modes gap/overlap-consistent by
    // construction.
    const nine = slice(dst, frame_uv, frame_px, border);

    // Source-pixel length of one repeat = the frame's middle span. Same
    // frame-size normalization as `slice` so the two never disagree.
    const fw = if (frame_px.x > 0) frame_px.x else 1;
    const fh = if (frame_px.y > 0) frame_px.y else 1;
    const seg_w = fw - border.left - border.right;
    const seg_h = fh - border.top - border.bottom;

    var list: std.ArrayList(Quad) = .empty;
    errdefer list.deinit(allocator);

    var row: usize = 0;
    while (row < 3) : (row += 1) {
        var col: usize = 0;
        while (col < 3) : (col += 1) {
            const c = nine[row * 3 + col];
            const ax: TileAxis = .{
                .start = c.dst.x,
                .len = c.dst.w,
                .uv0 = c.uv.u0,
                .uv1 = c.uv.u1,
                .seg = seg_w,
                .tiled = col == 1,
            };
            const ay: TileAxis = .{
                .start = c.dst.y,
                .len = c.dst.h,
                .uv0 = c.uv.v0,
                .uv1 = c.uv.v1,
                .seg = seg_h,
                .tiled = row == 1,
            };
            var iy: usize = 0;
            while (iy < ay.count()) : (iy += 1) {
                const cy = ay.cell(iy);
                var ix: usize = 0;
                while (ix < ax.count()) : (ix += 1) {
                    const cx = ax.cell(ix);
                    try list.append(allocator, .{
                        .dst = .{ .x = cx.pos, .y = cy.pos, .w = cx.len, .h = cy.len },
                        .uv = .{ .u0 = cx.uv0, .v0 = cy.uv0, .u1 = cx.uv1, .v1 = cy.uv1 },
                    });
                }
            }
        }
    }
    return list.toOwnedSlice(allocator);
}

/// Mode-dispatching decomposition for callers that treat both modes
/// uniformly (the render pass). `.stretch` returns `slice`'s nine cells
/// verbatim — including zero-area ones, preserving the fixed-layout
/// contract — while `.tile` returns only drawable quads (see `sliceTiled`).
/// Caller owns the returned slice.
pub fn sliceAlloc(
    allocator: std.mem.Allocator,
    dst: Rect,
    frame_uv: UvRect,
    frame_px: Vec2,
    border: Insets,
    mode: Mode,
) std.mem.Allocator.Error![]Quad {
    switch (mode) {
        .stretch => {
            const nine = slice(dst, frame_uv, frame_px, border);
            return allocator.dupe(Quad, &nine);
        },
        .tile => return sliceTiled(allocator, dst, frame_uv, frame_px, border),
    }
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

// ─── Tile-mode tests ───────────────────────────────────────────────────────
//
// Shared fixture: a 32×32 frame with an 8px uniform border → a 16×16 middle
// segment, full-atlas UV. UV boundaries are then [0, 0.25, 0.75, 1] on both
// axes; the middle UV span is [0.25, 0.75].

const tile_frame: UvRect = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 };
const tile_frame_px: Vec2 = .{ .x = 32, .y = 32 };
const tile_border = Insets.uniform(8);

fn expectQuad(q: Quad, dst: Rect, uv: UvRect) !void {
    try testing.expectApproxEqAbs(dst.x, q.dst.x, 0.001);
    try testing.expectApproxEqAbs(dst.y, q.dst.y, 0.001);
    try testing.expectApproxEqAbs(dst.w, q.dst.w, 0.001);
    try testing.expectApproxEqAbs(dst.h, q.dst.h, 0.001);
    try testing.expectApproxEqAbs(uv.u0, q.uv.u0, 0.0001);
    try testing.expectApproxEqAbs(uv.v0, q.uv.v0, 0.0001);
    try testing.expectApproxEqAbs(uv.u1, q.uv.u1, 0.0001);
    try testing.expectApproxEqAbs(uv.v1, q.uv.v1, 0.0001);
}

test "tile: edges emit ceil(len/segment) quads, last one clipped via UV" {
    // dst 56×40 → center 40×24. seg 16 → x: 2 full + 8px partial (3 cells),
    // y: 1 full + 8px partial (2 cells).
    const q = try sliceTiled(testing.allocator, .{ .x = 0, .y = 0, .w = 56, .h = 40 }, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(q);
    // 4 corners + 3 top + 3 bottom + 2 left + 2 right + 3*2 center.
    try testing.expectEqual(@as(usize, 20), q.len);

    // Row-major region order → q[0] top-left corner, q[1..4] top edge.
    try expectQuad(q[0], .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .{ .u0 = 0, .v0 = 0, .u1 = 0.25, .v1 = 0.25 });
    try expectQuad(q[1], .{ .x = 8, .y = 0, .w = 16, .h = 8 }, .{ .u0 = 0.25, .v0 = 0, .u1 = 0.75, .v1 = 0.25 });
    try expectQuad(q[2], .{ .x = 24, .y = 0, .w = 16, .h = 8 }, .{ .u0 = 0.25, .v0 = 0, .u1 = 0.75, .v1 = 0.25 });
    // Partial: 8px of a 16px segment → half the UV span, clipped not squashed.
    try expectQuad(q[3], .{ .x = 40, .y = 0, .w = 8, .h = 8 }, .{ .u0 = 0.25, .v0 = 0, .u1 = 0.5, .v1 = 0.25 });
    // q[4] top-right corner closes the first region row.
    try expectQuad(q[4], .{ .x = 48, .y = 0, .w = 8, .h = 8 }, .{ .u0 = 0.75, .v0 = 0, .u1 = 1, .v1 = 0.25 });
}

test "tile: center emits a 2-D grid with the corner cell clipped on both axes" {
    const q = try sliceTiled(testing.allocator, .{ .x = 0, .y = 0, .w = 56, .h = 40 }, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(q);
    // Middle region row: q[5..7] left edge tiles? No — row-major regions:
    // left edge (2) at q[5], q[7]? Regions emit all their cells before the
    // next region: q[5..6] left edge, q[7..12] center grid, q[13..14] right.
    try expectQuad(q[5], .{ .x = 0, .y = 8, .w = 8, .h = 16 }, .{ .u0 = 0, .v0 = 0.25, .u1 = 0.25, .v1 = 0.75 });
    try expectQuad(q[6], .{ .x = 0, .y = 24, .w = 8, .h = 8 }, .{ .u0 = 0, .v0 = 0.25, .u1 = 0.25, .v1 = 0.5 });
    // Center grid, row-major: full, full, x-partial / y-partial row below.
    try expectQuad(q[7], .{ .x = 8, .y = 8, .w = 16, .h = 16 }, .{ .u0 = 0.25, .v0 = 0.25, .u1 = 0.75, .v1 = 0.75 });
    try expectQuad(q[9], .{ .x = 40, .y = 8, .w = 8, .h = 16 }, .{ .u0 = 0.25, .v0 = 0.25, .u1 = 0.5, .v1 = 0.75 });
    // Bottom-right center cell: partial on BOTH axes → UV clipped on both.
    try expectQuad(q[12], .{ .x = 40, .y = 24, .w = 8, .h = 8 }, .{ .u0 = 0.25, .v0 = 0.25, .u1 = 0.5, .v1 = 0.5 });
}

test "tile: quads cover the destination exactly — no gaps, no overlaps" {
    const dst: Rect = .{ .x = 10, .y = 20, .w = 56, .h = 40 };
    const q = try sliceTiled(testing.allocator, dst, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(q);
    // Total area matches, and no quad crosses another: with axis-aligned
    // cells from a shared boundary grid, area-sum + per-quad bounds checks
    // together pin the tiling as gap- and overlap-free.
    var total: f32 = 0;
    for (q) |cell| {
        total += quadArea(cell);
        try testing.expect(cell.dst.w > 0 and cell.dst.h > 0);
        try testing.expect(cell.dst.x >= dst.x - 0.001 and cell.dst.right() <= dst.right() + 0.001);
        try testing.expect(cell.dst.y >= dst.y - 0.001 and cell.dst.bottom() <= dst.bottom() + 0.001);
    }
    try testing.expectApproxEqAbs(@as(f32, 56 * 40), total, 0.01);
}

test "tile: exact multiple of the segment emits only full repeats" {
    // dst 48×48 → center 32×32 = exactly 2×2 segments: no partial cells.
    const q = try sliceTiled(testing.allocator, .{ .x = 0, .y = 0, .w = 48, .h = 48 }, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(q);
    // 4 corners + 4 edges × 2 + 2×2 center.
    try testing.expectEqual(@as(usize, 16), q.len);
    // Tile mode's defining invariant: every quad samples its source at 1:1 —
    // UV span × frame size == dest extent, for full and partial cells alike.
    for (q) |cell| {
        try testing.expectApproxEqAbs(cell.dst.w, (cell.uv.u1 - cell.uv.u0) * 32, 0.001);
        try testing.expectApproxEqAbs(cell.dst.h, (cell.uv.v1 - cell.uv.v0) * 32, 0.001);
    }
    // Top edge: both repeats full-width, full middle UV span.
    try expectQuad(q[1], .{ .x = 8, .y = 0, .w = 16, .h = 8 }, .{ .u0 = 0.25, .v0 = 0, .u1 = 0.75, .v1 = 0.25 });
    try expectQuad(q[2], .{ .x = 24, .y = 0, .w = 16, .h = 8 }, .{ .u0 = 0.25, .v0 = 0, .u1 = 0.75, .v1 = 0.25 });
}

test "tile: degenerate dest smaller than corners emits corners only" {
    // 10×10 dest with 8+8 borders → borders scale to 5, middle collapses to
    // zero → only the four (scaled) corners survive; no zero-area quads.
    const q = try sliceTiled(testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 10 }, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(q);
    try testing.expectEqual(@as(usize, 4), q.len);
    var total: f32 = 0;
    for (q) |cell| {
        try testing.expectApproxEqAbs(@as(f32, 5), cell.dst.w, 0.001);
        try testing.expectApproxEqAbs(@as(f32, 5), cell.dst.h, 0.001);
        total += quadArea(cell);
    }
    try testing.expectApproxEqAbs(@as(f32, 10 * 10), total, 0.01);
}

test "tile: zero middle segment (border consumes the frame) degrades to stretch" {
    // 16+16 border on a 32px frame → no middle pixels to repeat. Tiling is
    // undefined there, so each middle span falls back to one stretched quad —
    // i.e. the stretch decomposition, cell for cell.
    const dst: Rect = .{ .x = 0, .y = 0, .w = 64, .h = 64 };
    const q = try sliceTiled(testing.allocator, dst, tile_frame, tile_frame_px, Insets.uniform(16));
    defer testing.allocator.free(q);
    const nine = slice(dst, tile_frame, tile_frame_px, Insets.uniform(16));
    try testing.expectEqual(@as(usize, 9), q.len);
    for (nine, 0..) |expected, i| {
        try expectQuad(q[i], expected.dst, expected.uv);
    }
}

test "regression pin: sliceAlloc(.stretch) is byte-identical to slice()" {
    // The stretch path must not drift while tile mode exists alongside it —
    // consumers of the fixed 3×3 contract get the exact pre-tiling output.
    const dst: Rect = .{ .x = 3, .y = 7, .w = 200, .h = 100 };
    const frame: UvRect = .{ .u0 = 0.5, .v0 = 0.0, .u1 = 1.0, .v1 = 0.5 };
    const nine = slice(dst, frame, .{ .x = 64, .y = 64 }, Insets.uniform(16));
    const q = try sliceAlloc(testing.allocator, dst, frame, .{ .x = 64, .y = 64 }, Insets.uniform(16), .stretch);
    defer testing.allocator.free(q);
    try testing.expectEqual(@as(usize, 9), q.len);
    for (nine, q) |expected, got| {
        try testing.expect(std.meta.eql(expected, got));
    }
}

test "sliceAlloc(.tile) matches sliceTiled" {
    const dst: Rect = .{ .x = 0, .y = 0, .w = 56, .h = 40 };
    const a = try sliceAlloc(testing.allocator, dst, tile_frame, tile_frame_px, tile_border, .tile);
    defer testing.allocator.free(a);
    const b = try sliceTiled(testing.allocator, dst, tile_frame, tile_frame_px, tile_border);
    defer testing.allocator.free(b);
    try testing.expectEqual(b.len, a.len);
    for (a, b) |x, y| try testing.expect(std.meta.eql(x, y));
}
