//! Comptime worst-case text sizing across locales.
//!
//! The consuming games translate menu strings through the labelle i18n
//! system: a comptime `t(K.menu.x)` lookup into a *rectangular* all-locales
//! table in the assembler-generated module. A menu panel sized to one
//! locale's string resizes the moment the player switches language — ugly,
//! and fatal for pixel-art layouts where every rect is hand-tuned. The fix
//! is to size the panel **once, at comptime, to the widest locale**, so a
//! language switch never moves a pixel.
//!
//! Byte length is the wrong proxy for that: with proportional metrics a
//! longer string can be *narrower* in pixels ("iiiiii" vs "WWW" — six
//! narrow glyphs lose to three wide ones). So everything here measures in
//! pixels against the same baked glyph table (`font.FontMetrics`) the
//! renderer will draw with.
//!
//! ## The seam
//!
//! ui_kit must stay dependency-free, so it never imports the generated i18n
//! module. Instead the *caller* extracts one key's row — the generated
//! table is rectangular, `[key_count][locale_count][:0]const u8`, so a row
//! is simply `table[key]` — and hands it to `maxWidth`/`maxWrappedHeight`
//! together with comptime-known baked metrics. Intended call shape against
//! the generated module:
//!
//! ```zig
//! const i18n = @import("i18n"); // assembler-generated; ui_kit never sees it
//! const ui_kit = @import("ui_kit/mod.zig");
//!
//! // i18n.table: [key_count][locale_count][:0]const u8 — one row per key,
//! // one column per locale. A row plugs in directly:
//! const w = comptime ui_kit.i18n_sizing.maxWidth(
//!     i18n.table[i18n.K.menu.start], menu_font_baked, 16);
//! const h = comptime ui_kit.i18n_sizing.maxWrappedHeight(
//!     i18n.table[i18n.K.menu.tooltip], menu_font_baked, 16, w);
//! // panel.size = .{ .x = w + padding, .y = h + padding } — fixed forever.
//! ```
//!
//! Ad-hoc tuples of string literals (`.{ "New Game", "Nouvelle partie" }`)
//! work too; `strings` only needs comptime length + indexable UTF-8 items.
//!
//! ## Comptime vs the `text.Metrics` seam
//!
//! `text.zig` measures through a type-erased provider (`*const anyopaque` +
//! function pointers) — the right seam at runtime, but hostile to comptime
//! evaluation. So the comptime path here restates the same measurement
//! directly against the `FontMetrics` table (`measureBaked`), and the
//! wrap-height path restates `text.wrap`'s greedy algorithm as a pure line
//! *count* (`wrappedLineCountBaked`) — no allocation, so it runs at
//! comptime. Tests below pin both against their `text.zig` counterparts so
//! the two implementations cannot drift apart. For dynamic strings at
//! runtime, use the thin `text.zig` wrappers (`maxWidthRuntime`,
//! `maxWrappedHeightRuntime`).

const std = @import("std");
const font = @import("font.zig");
const text = @import("text.zig");

// ─── Measurement primitives (comptime- and runtime-callable) ───────────────

fn scaleOf(m: font.FontMetrics, size_px: f32) f32 {
    if (m.pixel_height <= 0) return 1;
    return size_px / m.pixel_height;
}

/// Pixel width of one UTF-8 run measured directly against a baked glyph
/// table, kerning included, scaled to `size_px`. Same math as
/// `text.measure` over `FontMetrics.provider()` (pinned by test), restated
/// without the type-erased provider so it evaluates at comptime.
///
/// A *run* is one rendered line: like `text.measure`, this does not split
/// on `\n` (the wrap pass owns line breaking). For multi-line content use
/// `widestLineBaked` — summing across a newline would report the two
/// lines' combined width.
pub fn measureBaked(run: []const u8, m: font.FontMetrics, size_px: f32) f32 {
    const s = scaleOf(m, size_px);
    var w: f32 = 0;
    const view = std.unicode.Utf8View.init(run) catch {
        // Malformed UTF-8: byte-wise space advance, mirroring text.measure's
        // never-crash fallback.
        for (run) |_| w += m.bakedAdvance(' ') * s;
        return w;
    };
    var it = view.iterator();
    var prev: ?u21 = null;
    while (it.nextCodepoint()) |cp| {
        if (prev) |p| w += m.bakedKern(p, cp) * s;
        w += m.bakedAdvance(cp) * s;
        prev = cp;
    }
    return w;
}

/// Widest hard-newline-delimited line of `content` — the width the
/// renderer actually needs, since `text.wrap` always breaks on `\n`:
/// measuring the whole string as one run would *sum* the lines and
/// oversize the panel. Kerning resets at each break, exactly as drawn.
pub fn widestLineBaked(content: []const u8, m: font.FontMetrics, size_px: f32) f32 {
    var max: f32 = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| max = @max(max, measureBaked(line, m, size_px));
    return max;
}

/// Number of lines `content` occupies when word-wrapped to `wrap_width` —
/// `text.wrap`'s greedy algorithm (first word always fits, hard `\n` always
/// breaks, over-long words overflow their line) restated as a pure count so
/// it needs no allocator and therefore runs at comptime. Pinned against
/// `text.wrap` by test.
pub fn wrappedLineCountBaked(content: []const u8, m: font.FontMetrics, size_px: f32, wrap_width: f32) usize {
    var count: usize = 0;
    var seg_it = std.mem.splitScalar(u8, content, '\n');
    while (seg_it.next()) |segment| {
        count += segmentLineCount(segment, m, size_px, wrap_width);
    }
    return count;
}

fn segmentLineCount(segment: []const u8, m: font.FontMetrics, size_px: f32, max_width: f32) usize {
    const space_w = m.bakedAdvance(' ') * scaleOf(m, size_px);
    var lines: usize = 0;
    var line_w: f32 = 0;
    var has_word = false;
    var word_it = std.mem.tokenizeScalar(u8, segment, ' ');
    while (word_it.next()) |word| {
        const word_w = measureBaked(word, m, size_px);
        if (!has_word) {
            line_w = word_w;
            has_word = true;
            continue;
        }
        const tentative = line_w + space_w + word_w;
        if (tentative <= max_width) {
            line_w = tentative;
        } else {
            lines += 1;
            line_w = word_w;
        }
    }
    // The trailing line — or, for a blank segment (e.g. "\n\n"), the empty
    // line it still occupies, matching text.wrapSegment.
    return lines + 1;
}

/// Baseline-to-baseline line height at `size_px` for a baked table.
pub fn lineHeightBaked(m: font.FontMetrics, size_px: f32) f32 {
    return m.bakedLineHeight() * scaleOf(m, size_px);
}

// ─── Comptime worst-case helpers ───────────────────────────────────────────

/// Normalize any comptime string collection (generated `[N][:0]const u8`
/// row, tuple of literals, array of slices) into a uniform slice array —
/// the one seam-shaping step, so every helper below accepts the generated
/// table's rows directly.
fn toSlices(comptime strings: anytype) [strings.len][]const u8 {
    var out: [strings.len][]const u8 = undefined;
    inline for (strings, 0..) |s, i| out[i] = s;
    return out;
}

/// Long tables would exhaust the default 1000-branch comptime quota mid-
/// measure; raise it up front, proportional to the input, so callers never
/// have to sprinkle `@setEvalBranchQuota` themselves. The cost per measured
/// codepoint is a bounded handful of branches (UTF-8 decode + binary glyph
/// lookup) *plus* a linear scan of the kerning table for the pair lookup —
/// so the quota must scale with the font's kern-pair count too, or a
/// richly-kerned font would blow the quota on a short label.
fn raiseQuota(comptime list: []const []const u8, comptime m: font.FontMetrics) void {
    comptime var total: usize = 0;
    inline for (list) |s| total += s.len;
    const per_byte = 100 + 8 * m.kerning.len;
    const quota = @max(2000, (total + list.len + 1) * per_byte);
    @setEvalBranchQuota(@intCast(@min(quota, std.math.maxInt(u32))));
}

/// Max pixel width over every locale's text for one key, at comptime. This
/// is the number to size a menu panel with: the widest translation defines
/// the panel, so a runtime language switch never resizes it. Multi-line
/// translations (hard `\n`) contribute their widest *line*, matching how
/// the wrap pass renders them.
pub fn maxWidth(comptime strings: anytype, comptime m: font.FontMetrics, comptime size_px: f32) f32 {
    comptime {
        const list = toSlices(strings);
        raiseQuota(&list, m);
        var max: f32 = 0;
        for (list) |s| max = @max(max, widestLineBaked(s, m, size_px));
        return max;
    }
}

/// Max wrapped line count over every locale's text at `wrap_width`, at
/// comptime. Exposed separately from the height so callers snapping to
/// whole text rows (pixel-art grids) can work in lines.
pub fn maxWrappedLineCount(comptime strings: anytype, comptime m: font.FontMetrics, comptime size_px: f32, comptime wrap_width: f32) usize {
    comptime {
        const list = toSlices(strings);
        raiseQuota(&list, m);
        var max: usize = 0;
        for (list) |s| max = @max(max, wrappedLineCountBaked(s, m, size_px, wrap_width));
        return max;
    }
}

/// Max wrapped pixel height over every locale's text at `wrap_width`, at
/// comptime — the vertical companion to `maxWidth` for multi-line strings
/// (dialog bodies, tooltips).
pub fn maxWrappedHeight(comptime strings: anytype, comptime m: font.FontMetrics, comptime size_px: f32, comptime wrap_width: f32) f32 {
    const lines = maxWrappedLineCount(strings, m, size_px, wrap_width);
    return @as(f32, @floatFromInt(lines)) * lineHeightBaked(m, size_px);
}

// ─── Runtime variants (dynamic strings) ────────────────────────────────────

/// Runtime `maxWidth` for strings that only exist at runtime (player names,
/// downloaded locale packs). Thin wrapper over `text.measure`, so it works
/// with any `text.Metrics` provider, not just baked tables. Hard newlines
/// split into separately-measured lines, mirroring `maxWidth`.
pub fn maxWidthRuntime(strings: []const []const u8, size_px: f32, metrics: text.Metrics) f32 {
    var max: f32 = 0;
    for (strings) |s| {
        var it = std.mem.splitScalar(u8, s, '\n');
        while (it.next()) |line| max = @max(max, text.measure(line, size_px, metrics));
    }
    return max;
}

/// Runtime `maxWrappedHeight` — thin wrapper over `text.wrap` +
/// `text.blockHeight`. Allocates transiently per string (wrap's line list),
/// freeing before return.
pub fn maxWrappedHeightRuntime(
    allocator: std.mem.Allocator,
    strings: []const []const u8,
    size_px: f32,
    wrap_width: f32,
    metrics: text.Metrics,
) std.mem.Allocator.Error!f32 {
    var max: f32 = 0;
    for (strings) |s| {
        const lines = try text.wrap(allocator, s, wrap_width, size_px, metrics, true);
        defer allocator.free(lines);
        max = @max(max, text.blockHeight(lines.len, metrics, size_px));
    }
    return max;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// A tiny baked table with deliberately varied advances so pixel width and
// byte length disagree: 'i' 4px, 'A'/'V' 8px, 'W' 12px, space 2px, and an
// A→V kern of -2. Baked at 10px, line height 10 (ascent 8 − descent −2).
fn fixture() font.FontMetrics {
    const glyphs = &[_]font.Glyph{
        .{ .u0 = 0, .v0 = 0, .u1 = 2, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 2 }, // 0: ' '
        .{ .u0 = 0, .v0 = 0, .u1 = 4, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 4 }, // 1: 'i'
        .{ .u0 = 0, .v0 = 0, .u1 = 8, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 8 }, // 2: 'A'
        .{ .u0 = 0, .v0 = 0, .u1 = 8, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 8 }, // 3: 'V'
        .{ .u0 = 0, .v0 = 0, .u1 = 12, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 12 }, // 4: 'W'
    };
    // Sorted by codepoint: ' '=32, 'A'=65, 'V'=86, 'W'=87, 'i'=105.
    const cps = &[_]font.CodepointEntry{
        .{ .codepoint = ' ', .glyph_index = 0 },
        .{ .codepoint = 'A', .glyph_index = 2 },
        .{ .codepoint = 'V', .glyph_index = 3 },
        .{ .codepoint = 'W', .glyph_index = 4 },
        .{ .codepoint = 'i', .glyph_index = 1 },
    };
    const kern = &[_]font.KernPair{
        .{ .first = 'A', .second = 'V', .advance = -2 },
    };
    return .{
        .glyphs = glyphs,
        .codepoint_index = cps,
        .kerning = kern,
        .pixel_height = 10,
        .ascent = 8,
        .descent = -2,
    };
}

test "longer-in-bytes can be narrower in pixels — why byte-length sizing is wrong" {
    // "iiiiii": 6 bytes, 6×4 = 24px. "WWW": 3 bytes, 3×12 = 36px. A byte
    // count would size the panel to the wrong string; pixel metrics don't.
    const w = comptime maxWidth(.{ "iiiiii", "WWW" }, fixture(), 10);
    try testing.expectApproxEqAbs(@as(f32, 36), w, 0.001);
    // And the whole point holds at comptime — usable as a struct field /
    // array length seed with zero runtime cost.
    comptime std.debug.assert(w == 36);
    comptime std.debug.assert(maxWidth(.{"iiiiii"}, fixture(), 10) == 24);
}

test "maxWidth accepts the generated table's row shape ([N][:0]const u8)" {
    // Exactly what `i18n.table[key]` yields: an array of sentinel-terminated
    // slices, one per locale.
    const row = [_][:0]const u8{ "WW", "iiii", "AV" };
    // "WW"=24, "iiii"=16, "AV"=8−2+8=14 (kerned) → 24.
    const w = comptime maxWidth(row, fixture(), 10);
    try testing.expectApproxEqAbs(@as(f32, 24), w, 0.001);
}

test "maxWidth of a multi-line translation is its widest line, not the sum" {
    // "W\nW" renders as two 12px lines; the panel needs 12, not 24. And a
    // hard break resets kerning: "A\nV" is 8/8, the A→V pair never touches.
    const w = comptime maxWidth(.{"W\nW"}, fixture(), 10);
    try testing.expectApproxEqAbs(@as(f32, 12), w, 0.001);
    const kerned = comptime maxWidth(.{"A\nV"}, fixture(), 10);
    try testing.expectApproxEqAbs(@as(f32, 8), kerned, 0.001);

    var m = fixture();
    const rt = maxWidthRuntime(&[_][]const u8{"W\nW"}, 10, m.provider());
    try testing.expectApproxEqAbs(@as(f32, 12), rt, 0.001);
}

test "maxWidth scales with the requested size and applies kerning" {
    // "AV" kerned = 14 at baked 10px → 28 at 20px.
    const w = comptime maxWidth(.{"AV"}, fixture(), 20);
    try testing.expectApproxEqAbs(@as(f32, 28), w, 0.001);
}

test "maxWrappedHeight: tallest locale after wrapping wins" {
    // At width 40: "WWW ii" → "WWW"(36) then "ii"(8) = 2 lines; "ii" = 1
    // line. Line height 10 at size 10 → 20px.
    const h = comptime maxWrappedHeight(.{ "WWW ii", "ii" }, fixture(), 10, 40);
    try testing.expectApproxEqAbs(@as(f32, 20), h, 0.001);
    const lines = comptime maxWrappedLineCount(.{ "WWW ii", "ii" }, fixture(), 10, 40);
    try testing.expectEqual(@as(usize, 2), lines);
}

test "wrapped line count honors hard newlines and blank segments" {
    const n = comptime wrappedLineCountBaked("A\n\nV", fixture(), 10, 1000);
    try testing.expectEqual(@as(usize, 3), n);
}

test "comptime measurement agrees with text.measure over the provider seam" {
    // The comptime path restates text.zig's math; this pins them together so
    // a change to either implementation breaks loudly instead of letting
    // comptime panel sizes drift from what the renderer draws.
    const ct_w = comptime measureBaked("WiAV Wi", fixture(), 13);
    var m = fixture();
    const rt_w = text.measure("WiAV Wi", 13, m.provider());
    try testing.expectApproxEqAbs(rt_w, ct_w, 0.0001);
}

test "comptime line count agrees with text.wrap" {
    const content = "WWW ii iiii\nAV WW iiiiii W";
    const ct = comptime wrappedLineCountBaked(content, fixture(), 10, 44);
    var m = fixture();
    const lines = try text.wrap(testing.allocator, content, 44, 10, m.provider(), true);
    defer testing.allocator.free(lines);
    try testing.expectEqual(lines.len, ct);
}

test "runtime variants match the comptime results on the same inputs" {
    var m = fixture();
    const strings = [_][]const u8{ "iiiiii", "WWW" };
    const rt_w = maxWidthRuntime(&strings, 10, m.provider());
    try testing.expectApproxEqAbs(@as(f32, 36), rt_w, 0.001);

    const wrapped = [_][]const u8{ "WWW ii", "ii" };
    const rt_h = try maxWrappedHeightRuntime(testing.allocator, &wrapped, 10, 40, m.provider());
    try testing.expectApproxEqAbs(@as(f32, 20), rt_h, 0.001);
}
