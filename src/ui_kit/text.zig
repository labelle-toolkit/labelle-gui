//! Text layout for `UiText` — word wrapping + horizontal alignment.
//!
//! ## Status: functional first cut, metrics seam pending a font loader
//!
//! The wrapping/alignment logic here is complete and tested. What it does
//! *not* do yet is own real glyph metrics — those come from the font loader
//! (RFC-FONT-LOADER, referenced by issue #214). Until that lands, callers
//! supply a `Metrics` provider: a tiny interface of "advance width of a
//! codepoint at a size" + "line height". `monospace(...)` is a built-in
//! provider used by the tests and usable as a fallback; the real font loader
//! will supply a proportional provider backed by the atlas'd glyph table.
//!
//! Explicit non-goals (v1, per the ticket): rich text. Words longer than the
//! wrap width are NOT split mid-glyph — they overflow their line. Hard
//! newlines (`\n`) in the content always break.

const std = @import("std");
const root = @import("mod.zig");
const TextAlign = root.TextAlign;

/// Glyph-metrics provider. `advanceFn` returns the horizontal advance of one
/// codepoint rendered at `size_px`; `context` lets a real font loader carry
/// its glyph table. This is the seam RFC-FONT-LOADER plugs into — nothing in
/// the layout code assumes monospace.
pub const Metrics = struct {
    line_height: f32,
    context: *const anyopaque = undefined,
    advanceFn: *const fn (context: *const anyopaque, codepoint: u21, size_px: f32) f32,

    pub fn advance(self: Metrics, codepoint: u21, size_px: f32) f32 {
        return self.advanceFn(self.context, codepoint, size_px);
    }
};

fn monoAdvance(context: *const anyopaque, codepoint: u21, size_px: f32) f32 {
    _ = codepoint;
    const ratio: *const f32 = @ptrCast(@alignCast(context));
    return ratio.* * size_px;
}

/// A fixed-advance provider: every glyph is `char_ratio * size_px` wide, each
/// line `line_ratio * size_px` tall. Handy for tests and as a placeholder
/// until the font loader supplies proportional metrics. The returned Metrics
/// borrows `store` — keep it alive for the Metrics' lifetime.
pub const MonoStore = struct { char_ratio: f32 };

pub fn monospace(store: *const MonoStore, line_ratio_px: f32) Metrics {
    return .{
        .line_height = line_ratio_px,
        .context = &store.char_ratio,
        .advanceFn = monoAdvance,
    };
}

/// One laid-out line: a slice into the original `content` plus its measured
/// width in pixels.
pub const Line = struct {
    text: []const u8,
    width: f32,
};

/// Total pixel width of a UTF-8 run at `size_px` under `metrics`.
pub fn measure(run: []const u8, size_px: f32, metrics: Metrics) f32 {
    var w: f32 = 0;
    const view = std.unicode.Utf8View.init(run) catch {
        // Malformed UTF-8: fall back to byte-wise advance so we never crash
        // on user content. (The font loader will validate upstream.)
        for (run) |_| w += metrics.advance(' ', size_px);
        return w;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| w += metrics.advance(cp, size_px);
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

/// Total laid-out height for `line_count` lines under `metrics`.
pub fn blockHeight(line_count: usize, metrics: Metrics) f32 {
    return @as(f32, @floatFromInt(line_count)) * metrics.line_height;
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// 10px-per-glyph, 16px line height — round numbers make expectations obvious.
var test_store: MonoStore = .{ .char_ratio = 1.0 };
fn testMetrics() Metrics {
    test_store = .{ .char_ratio = 1.0 };
    return monospace(&test_store, 16);
}

test "measure sums per-glyph advances" {
    const m = testMetrics(); // 1.0 * size → 10px per char at size 10
    try testing.expectApproxEqAbs(@as(f32, 50), measure("hello", 10, m), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), measure("", 10, m), 0.001);
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
    // "aaa bbb ccc": each word 30px, space 10px. Width 70 fits two words
    // (30 + 10 + 30 = 70) but not three.
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
    // "wide" is 40px but max width is 20 → still one line, overflowing.
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

test "blockHeight scales with line count" {
    const m = testMetrics();
    try testing.expectApproxEqAbs(@as(f32, 48), blockHeight(3, m), 0.001);
}
