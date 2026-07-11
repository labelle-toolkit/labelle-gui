//! Text layout for `UiText` — word wrapping + horizontal alignment.
//!
//! ## Metrics seam
//!
//! The wrapping/alignment logic here is metrics-agnostic: it asks a `Metrics`
//! provider for per-codepoint advances, per-pair kerning, and line height —
//! all parameterized by the requested `size_px`, so one provider serves every
//! font size. Two providers ship:
//!
//!  - `monospace(...)` — a fixed-ratio provider (tests, and a fallback until a
//!    font is loaded).
//!  - `font.FontMetrics.provider()` — real *proportional* metrics driven by a
//!    baked glyph table (the RFC-FONT-LOADER shape). This is what replaces the
//!    monospace fallback once a font asset is resolved; see `font.zig`.
//!
//! Explicit non-goals (v1, per issue #214): rich text, bidi, complex-script
//! shaping. Words longer than the wrap width are NOT split mid-glyph — they
//! overflow their line. Hard newlines (`\n`) always break.

const std = @import("std");
const root = @import("mod.zig");
const TextAlign = root.TextAlign;

/// Glyph-metrics provider — the seam between layout and a font. Every hook is
/// parameterized by `size_px` so a single provider handles all sizes (a
/// proportional font scales its baked advances; monospace multiplies a ratio).
///
///  - `advanceFn`    — horizontal pen advance for one codepoint.
///  - `kernFn`       — extra advance inserted between an adjacent pair
///                     (`left` then `right`); 0 when the font has no kerning.
///  - `lineHeightFn` — baseline-to-baseline distance for a line of text.
///
/// `context` carries the provider's backing data (a glyph table, a ratio
/// store, …) and must outlive the `Metrics`.
pub const Metrics = struct {
    context: *const anyopaque = undefined,
    advanceFn: *const fn (context: *const anyopaque, codepoint: u21, size_px: f32) f32,
    kernFn: *const fn (context: *const anyopaque, left: u21, right: u21, size_px: f32) f32 = zeroKern,
    lineHeightFn: *const fn (context: *const anyopaque, size_px: f32) f32,

    pub fn advance(self: Metrics, codepoint: u21, size_px: f32) f32 {
        return self.advanceFn(self.context, codepoint, size_px);
    }
    pub fn kern(self: Metrics, left: u21, right: u21, size_px: f32) f32 {
        return self.kernFn(self.context, left, right, size_px);
    }
    pub fn lineHeight(self: Metrics, size_px: f32) f32 {
        return self.lineHeightFn(self.context, size_px);
    }
};

fn zeroKern(context: *const anyopaque, left: u21, right: u21, size_px: f32) f32 {
    _ = context;
    _ = left;
    _ = right;
    _ = size_px;
    return 0;
}

// ─── Monospace provider (fallback / tests) ─────────────────────────────────

/// Backing store for `monospace`: every glyph advances `char_ratio * size_px`,
/// every line is `line_ratio * size_px` tall. Keep it alive for the Metrics'
/// lifetime.
pub const MonoStore = struct {
    char_ratio: f32,
    line_ratio: f32 = 1.2,
};

fn monoAdvance(context: *const anyopaque, codepoint: u21, size_px: f32) f32 {
    _ = codepoint;
    const s: *const MonoStore = @ptrCast(@alignCast(context));
    return s.char_ratio * size_px;
}
fn monoLineHeight(context: *const anyopaque, size_px: f32) f32 {
    const s: *const MonoStore = @ptrCast(@alignCast(context));
    return s.line_ratio * size_px;
}

/// A fixed-advance metrics provider. Handy for tests and as a placeholder
/// until a real font is resolved.
pub fn monospace(store: *const MonoStore) Metrics {
    return .{
        .context = store,
        .advanceFn = monoAdvance,
        .lineHeightFn = monoLineHeight,
    };
}

// ─── Measurement + wrapping ────────────────────────────────────────────────

/// One laid-out line: a slice into the original `content` plus its measured
/// width in pixels.
pub const Line = struct {
    text: []const u8,
    width: f32,
};

/// Total pixel width of a UTF-8 run at `size_px`, kerning included.
pub fn measure(run: []const u8, size_px: f32, metrics: Metrics) f32 {
    var w: f32 = 0;
    const view = std.unicode.Utf8View.init(run) catch {
        // Malformed UTF-8: fall back to byte-wise advance so we never crash
        // on user content. (A real font loader validates upstream.)
        for (run) |_| w += metrics.advance(' ', size_px);
        return w;
    };
    var it = view.iterator();
    var prev: ?u21 = null;
    while (it.nextCodepoint()) |cp| {
        if (prev) |p| w += metrics.kern(p, cp, size_px);
        w += metrics.advance(cp, size_px);
        prev = cp;
    }
    return w;
}

/// Word-wrap `content` to fit `max_width`, honoring hard `\n` breaks. When
/// `do_wrap` is false only hard breaks split the text. Caller owns the
/// returned slice (`allocator.free`); the `Line.text` slices point back into
/// `content`, so keep it alive too.
pub fn wrap(
    allocator: std.mem.Allocator,
    content: []const u8,
    max_width: f32,
    size_px: f32,
    metrics: Metrics,
    do_wrap: bool,
) ![]Line {
    var lines: std.ArrayList(Line) = .empty;
    errdefer lines.deinit(allocator);

    var seg_it = std.mem.splitScalar(u8, content, '\n');
    while (seg_it.next()) |segment| {
        if (!do_wrap) {
            try lines.append(allocator, .{ .text = segment, .width = measure(segment, size_px, metrics) });
            continue;
        }
        try wrapSegment(allocator, &lines, segment, max_width, size_px, metrics);
    }
    return lines.toOwnedSlice(allocator);
}

fn wrapSegment(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList(Line),
    segment: []const u8,
    max_width: f32,
    size_px: f32,
    metrics: Metrics,
) !void {
    const space_w = metrics.advance(' ', size_px);

    var line_start: usize = 0;
    var line_end: usize = 0; // exclusive, one past the last non-space char
    var line_w: f32 = 0;
    var has_word = false;

    var word_it = std.mem.tokenizeScalar(u8, segment, ' ');
    while (word_it.next()) |word| {
        const word_w = measure(word, size_px, metrics);
        const word_off = @intFromPtr(word.ptr) - @intFromPtr(segment.ptr);

        if (!has_word) {
            // First word on the (possibly fresh) line always fits.
            line_start = word_off;
            line_end = word_off + word.len;
            line_w = word_w;
            has_word = true;
            continue;
        }

        const tentative = line_w + space_w + word_w;
        if (tentative <= max_width) {
            line_end = word_off + word.len;
            line_w = tentative;
        } else {
            // Flush the current line and start a new one with this word.
            try lines.append(allocator, .{ .text = segment[line_start..line_end], .width = line_w });
            line_start = word_off;
            line_end = word_off + word.len;
            line_w = word_w;
        }
    }

    if (has_word) {
        try lines.append(allocator, .{ .text = segment[line_start..line_end], .width = line_w });
    } else {
        // Blank segment (e.g. a "\n\n") still occupies a line.
        try lines.append(allocator, .{ .text = segment[0..0], .width = 0 });
    }
}

/// Horizontal offset to apply to a line of `line_width` within a box of
/// `box_width` for the given alignment.
pub fn xOffset(halign: TextAlign, box_width: f32, line_width: f32) f32 {
    return switch (halign) {
        .left => 0,
        .center => (box_width - line_width) * 0.5,
        .right => box_width - line_width,
    };
}

/// Total laid-out height for `line_count` lines at `size_px`.
pub fn blockHeight(line_count: usize, metrics: Metrics, size_px: f32) f32 {
    return @as(f32, @floatFromInt(line_count)) * metrics.lineHeight(size_px);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// 1.0 char ratio, 1.6 line ratio → 10px/glyph and 16px lines at size 10.
var test_store: MonoStore = .{ .char_ratio = 1.0, .line_ratio = 1.6 };
fn testMetrics() Metrics {
    test_store = .{ .char_ratio = 1.0, .line_ratio = 1.6 };
    return monospace(&test_store);
}

test "measure sums per-glyph advances" {
    const m = testMetrics();
    try testing.expectApproxEqAbs(@as(f32, 50), measure("hello", 10, m), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), measure("", 10, m), 0.001);
}

test "measure scales with size_px" {
    const m = testMetrics();
    try testing.expectApproxEqAbs(@as(f32, 30), measure("abc", 10, m), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), measure("abc", 20, m), 0.001);
}

test "no-wrap keeps a single line but still splits on hard newlines" {
    const m = testMetrics();
    const lines = try wrap(testing.allocator, "one two", 30, 10, m, false);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 1), lines.len);
    try testing.expectEqualStrings("one two", lines[0].text);

    const two = try wrap(testing.allocator, "a\nb", 1000, 10, m, false);
    defer testing.allocator.free(two);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("a", two[0].text);
    try testing.expectEqualStrings("b", two[1].text);
}

test "word wrap breaks at the width boundary" {
    const m = testMetrics(); // 10px/char at size 10
    const lines = try wrap(testing.allocator, "aaa bbb ccc", 70, 10, m, true);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
    try testing.expectEqualStrings("aaa bbb", lines[0].text);
    try testing.expectEqualStrings("ccc", lines[1].text);
    try testing.expectApproxEqAbs(@as(f32, 70), lines[0].width, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), lines[1].width, 0.001);
}

test "a word longer than the width gets its own line (no mid-glyph split)" {
    const m = testMetrics();
    const lines = try wrap(testing.allocator, "hi wide ok", 20, 10, m, true);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expectEqualStrings("hi", lines[0].text);
    try testing.expectEqualStrings("wide", lines[1].text);
    try testing.expectEqualStrings("ok", lines[2].text);
}

test "hard newline forces a break even when the line would fit" {
    const m = testMetrics();
    const lines = try wrap(testing.allocator, "a\nb", 1000, 10, m, true);
    defer testing.allocator.free(lines);
    try testing.expectEqual(@as(usize, 2), lines.len);
}

test "xOffset aligns left / center / right" {
    try testing.expectApproxEqAbs(@as(f32, 0), xOffset(.left, 100, 40), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 30), xOffset(.center, 100, 40), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 60), xOffset(.right, 100, 40), 0.001);
}

test "blockHeight scales with line count and size" {
    const m = testMetrics(); // line_ratio 1.6
    try testing.expectApproxEqAbs(@as(f32, 48), blockHeight(3, m, 10), 0.001); // 3 * 16
    try testing.expectApproxEqAbs(@as(f32, 96), blockHeight(3, m, 20), 0.001); // 3 * 32
}
