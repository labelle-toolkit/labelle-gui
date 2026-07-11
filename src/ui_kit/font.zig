//! Proportional font metrics for `UiText` (issue #214, phase 2).
//!
//! This replaces the monospace fallback with real per-glyph advances driven
//! by a baked glyph table — the shape the engine's font loader produces
//! (labelle-engine `RFC-FONT-LOADER.md`, tracking issue labelle-engine#448).
//!
//! ## Layout compatibility with labelle-core (identity `@ptrCast`)
//!
//! `Glyph`, `CodepointEntry`, and `KernPair` below are byte-for-byte the
//! `extern struct`s canonicalised in `labelle-core/src/backend_contract.zig`
//! (aliased by `labelle-engine/src/font_types.zig`). They are redeclared here
//! — rather than imported — because `labelle-gui` cannot take a Zig-package
//! dependency on the engine without dragging its whole backend graph into the
//! editor build. The `extern` layout guarantee is what makes that safe: a
//! `[]const engine.Glyph` from a loaded font reinterprets to a
//! `[]const ui_kit.font.Glyph` as a plain `@ptrCast` (the RFC §3 identity
//! reinterpret), so wiring a really-loaded font into `FontMetrics` at the
//! engine boundary is a cast, not a copy. `layoutMatchesCore` (test below)
//! guards the field shape so drift is caught here.

const std = @import("std");
const text = @import("text.zig");

/// One baked glyph. UV rect in atlas *pixels* (not normalised); `xoff`/`yoff`
/// are pen-relative blit offsets; `advance` moves the pen for the next glyph.
/// Layout: `u16 × 4` then `f32 × 3`. Mirrors `labelle-core` `Glyph`.
pub const Glyph = extern struct {
    u0: u16,
    v0: u16,
    u1: u16,
    v1: u16,
    xoff: f32,
    yoff: f32,
    advance: f32,
};

/// Sorted (by `codepoint`) lookup from Unicode codepoint to dense glyph index.
/// Mirrors `labelle-core` `CodepointEntry`.
pub const CodepointEntry = extern struct {
    codepoint: u32,
    glyph_index: u32,
};

/// One GPOS kern pair — `advance` is added when `first` is followed by
/// `second`. Mirrors `labelle-core` `KernPair`.
pub const KernPair = extern struct {
    first: u32,
    second: u32,
    advance: f32,
};

/// A resolved font: the baked glyph table plus vertical metrics, all in the
/// pixel space of the size it was baked at (`pixel_height`). The metrics
/// provider scales advances/line-height from `pixel_height` to whatever size
/// a `UiText` requests, so one baked atlas serves nearby sizes.
///
/// This is the engine-facing bundle: a font backend fills it from a
/// `DecodedFont` (RFC §3) — `glyphs`/`codepoint_index`/`kerning` cast straight
/// across, the four scalars copy.
pub const FontMetrics = struct {
    /// Dense glyph array, addressed by `codepoint_index`.
    glyphs: []const Glyph,
    /// codepoint → glyph index, sorted ascending by codepoint for binary
    /// search on the hot path.
    codepoint_index: []const CodepointEntry,
    /// Sparse kern pairs; empty when the font has none.
    kerning: []const KernPair = &.{},

    /// The size these metrics were baked at, in pixels. Advances scale by
    /// `requested_size / pixel_height`.
    pixel_height: f32,
    ascent: f32 = 0,
    descent: f32 = 0, // negative (below baseline)
    line_gap: f32 = 0,
    /// Baseline-to-baseline distance at the baked size. If left 0 it is
    /// derived as `ascent - descent + line_gap`.
    line_height: f32 = 0,

    /// Baseline-to-baseline distance at the baked size, deriving from
    /// ascent/descent/gap when `line_height` was not supplied.
    pub fn bakedLineHeight(self: FontMetrics) f32 {
        if (self.line_height != 0) return self.line_height;
        return self.ascent - self.descent + self.line_gap;
    }

    /// Glyph index for `codepoint` via binary search, or null if unbaked.
    pub fn glyphIndex(self: FontMetrics, codepoint: u21) ?u32 {
        var lo: usize = 0;
        var hi: usize = self.codepoint_index.len;
        const key: u32 = codepoint;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const c = self.codepoint_index[mid].codepoint;
            if (c == key) return self.codepoint_index[mid].glyph_index;
            if (c < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Advance of `codepoint` at the baked size, in pixels. Unbaked glyphs
    /// advance 0 (the renderer draws nothing / a fallback box).
    pub fn bakedAdvance(self: FontMetrics, codepoint: u21) f32 {
        const gi = self.glyphIndex(codepoint) orelse return 0;
        if (gi >= self.glyphs.len) return 0;
        return self.glyphs[gi].advance;
    }

    /// Kern adjustment between `left` and `right` at the baked size (0 if the
    /// pair isn't in the table).
    pub fn bakedKern(self: FontMetrics, left: u21, right: u21) f32 {
        for (self.kerning) |k| {
            if (k.first == @as(u32, left) and k.second == @as(u32, right)) return k.advance;
        }
        return 0;
    }

    /// A `text.Metrics` view of this font that scales to the requested size.
    /// Borrows `self` — keep the `FontMetrics` alive for the view's lifetime.
    pub fn provider(self: *const FontMetrics) text.Metrics {
        return .{
            .context = self,
            .advanceFn = advanceThunk,
            .kernFn = kernThunk,
            .lineHeightFn = lineHeightThunk,
        };
    }
};

fn scale(self: *const FontMetrics, size_px: f32) f32 {
    if (self.pixel_height <= 0) return 1;
    return size_px / self.pixel_height;
}

fn advanceThunk(context: *const anyopaque, codepoint: u21, size_px: f32) f32 {
    const self: *const FontMetrics = @ptrCast(@alignCast(context));
    return self.bakedAdvance(codepoint) * scale(self, size_px);
}
fn kernThunk(context: *const anyopaque, left: u21, right: u21, size_px: f32) f32 {
    const self: *const FontMetrics = @ptrCast(@alignCast(context));
    return self.bakedKern(left, right) * scale(self, size_px);
}
fn lineHeightThunk(context: *const anyopaque, size_px: f32) f32 {
    const self: *const FontMetrics = @ptrCast(@alignCast(context));
    return self.bakedLineHeight() * scale(self, size_px);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "layout matches labelle-core canonical extern shapes" {
    // Field count + types + offsets must stay byte-identical to
    // labelle-core/src/backend_contract.zig for the cross-repo @ptrCast to be
    // an identity reinterpret (RFC-FONT-LOADER §3).
    try testing.expectEqual(@as(usize, 20), @sizeOf(Glyph)); // 4*u16 + 3*f32
    try testing.expectEqual(@offsetOf(Glyph, "u0"), 0);
    try testing.expectEqual(@offsetOf(Glyph, "xoff"), 8);
    try testing.expectEqual(@offsetOf(Glyph, "advance"), 16);
    try testing.expectEqual(@as(usize, 8), @sizeOf(CodepointEntry));
    try testing.expectEqual(@offsetOf(CodepointEntry, "glyph_index"), 4);
    try testing.expectEqual(@as(usize, 12), @sizeOf(KernPair));
    try testing.expectEqual(@offsetOf(KernPair, "advance"), 8);
}

// A tiny proportional font baked at 10px: 'i' narrow (4), 'W' wide (12),
// 'A'/'V' medium (8), with an A→V kern of -2.
fn fixtureFont() FontMetrics {
    const glyphs = &[_]Glyph{
        .{ .u0 = 0, .v0 = 0, .u1 = 4, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 4 }, // 0: 'i'
        .{ .u0 = 0, .v0 = 0, .u1 = 8, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 8 }, // 1: 'A'
        .{ .u0 = 0, .v0 = 0, .u1 = 8, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 8 }, // 2: 'V'
        .{ .u0 = 0, .v0 = 0, .u1 = 12, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 12 }, // 3: 'W'
    };
    // codepoint_index MUST be sorted by codepoint: 'A'=65,'V'=86,'W'=87,'i'=105
    const cps = &[_]CodepointEntry{
        .{ .codepoint = 'A', .glyph_index = 1 },
        .{ .codepoint = 'V', .glyph_index = 2 },
        .{ .codepoint = 'W', .glyph_index = 3 },
        .{ .codepoint = 'i', .glyph_index = 0 },
    };
    const kern = &[_]KernPair{
        .{ .first = 'A', .second = 'V', .advance = -2 },
    };
    return .{
        .glyphs = glyphs,
        .codepoint_index = cps,
        .kerning = kern,
        .pixel_height = 10,
        .ascent = 8,
        .descent = -2,
        .line_gap = 0,
    };
}

test "glyphIndex binary-searches the sorted codepoint table" {
    const f = fixtureFont();
    try testing.expectEqual(@as(?u32, 1), f.glyphIndex('A'));
    try testing.expectEqual(@as(?u32, 0), f.glyphIndex('i'));
    try testing.expectEqual(@as(?u32, 3), f.glyphIndex('W'));
    try testing.expect(f.glyphIndex('z') == null);
    try testing.expect(f.glyphIndex(0x1F600) == null);
}

test "proportional advances differ per glyph (not monospace)" {
    const f = fixtureFont();
    try testing.expectApproxEqAbs(@as(f32, 4), f.bakedAdvance('i'), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 12), f.bakedAdvance('W'), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), f.bakedAdvance('?'), 0.001); // unbaked
}

test "provider measures a run with true glyph widths at the baked size" {
    const f = fixtureFont();
    const m = f.provider();
    // "iW" = 4 + 12 = 16 at size 10 (baked size).
    try testing.expectApproxEqAbs(@as(f32, 16), text.measure("iW", 10, m), 0.001);
}

test "provider scales advances to the requested size" {
    const f = fixtureFont();
    const m = f.provider();
    // baked at 10px; at 20px everything doubles: "iW" = 32.
    try testing.expectApproxEqAbs(@as(f32, 32), text.measure("iW", 20, m), 0.001);
}

test "provider applies kerning between adjacent pairs" {
    const f = fixtureFont();
    const m = f.provider();
    // "AV": 8 + (-2 kern) + 8 = 14 at baked size.
    try testing.expectApproxEqAbs(@as(f32, 14), text.measure("AV", 10, m), 0.001);
    // "VA" has no kern pair: 8 + 8 = 16.
    try testing.expectApproxEqAbs(@as(f32, 16), text.measure("VA", 10, m), 0.001);
}

test "provider line height derives from ascent/descent/gap and scales" {
    const f = fixtureFont(); // ascent 8, descent -2, gap 0 → 10 at baked size
    const m = f.provider();
    try testing.expectApproxEqAbs(@as(f32, 10), m.lineHeight(10), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 20), m.lineHeight(20), 0.001);
}

test "proportional wrapping breaks on true widths, unlike monospace" {
    const f = fixtureFont();
    const m = f.provider();
    // "WWW ii": WWW = 36, space≈advance('  ')... space is unbaked (0). Use a
    // width that splits by real widths: 36 fits alone, "ii" (8) starts a new
    // line only if 36 + space + 8 > width. With space 0, 36+8=44. width 40 →
    // two lines.
    const lines = try text.wrap(testing.allocator, "WWW ii", 40, 10, m, true);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("WWW", lines[0].text);
    try testing.expectEqualStrings("ii", lines[1].text);
    try testing.expectApproxEqAbs(@as(f32, 36), lines[0].width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 8), lines[1].width, 0.001);
}
