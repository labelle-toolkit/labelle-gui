//! Engine-binding contract: retained `Tree` → flat draw list (issue #214).
//!
//! This is the single, documented surface a renderer consumes to draw an
//! in-game UI. `build` walks the retained tree in painter's order and emits a
//! `DrawList` of backend-agnostic `DrawCmd`s. A renderer iterates the list and
//! maps each command to its own draw call — nothing here touches GL, imgui, or
//! any GPU type, so the cross-repo binding (labelle-engine / any backend) is
//! unambiguous and this whole module is testable without a GPU.
//!
//! ## The contract
//!
//! Given a laid-out tree (run `layout.apply` first so every element's `rect`
//! is set) plus two resolver callbacks, `build` produces, per visible element:
//!
//!  - **`UiPanel`** → `textured_quad`s from the 9-slice decomposition when
//!    its sprite frame resolves; otherwise a single `solid_quad` placeholder
//!    tinted with the panel color (mirrors the editor's "unresolved sprite"
//!    fallback). Corners stay fixed; edges/center stretch (nine quads) or,
//!    with `Panel.tile`, repeat at 1:1 source scale (a variable count) — the
//!    commands are identical either way, so consumers don't care which mode
//!    produced them. See `nine_slice`.
//!  - **`UiText`** → one `text_line` per wrapped line, each carrying the
//!    line's screen rect (already offset for `halign`), the substring, color,
//!    size, and font name. Text glyphs are NOT rasterized here: the renderer's
//!    font backend owns glyph drawing (matching how `gui_mixin` hands text +
//!    `FontId` to the backend). Wrapping uses the resolved proportional font
//!    metrics when the font resolves, else the caller's default metrics.
//!  - **focused `UiButton`** → a `focus_highlight` for the focus ring.
//!
//! Draw order = element insertion order = parent-before-child (callers add
//! parents first), so later commands paint on top — standard painter's order.

const std = @import("std");
const root = @import("mod.zig");
const nine_slice = @import("nine_slice.zig");
const text = @import("text.zig");
const font = @import("font.zig");

const Tree = root.Tree;
const Element = root.Element;
const ElementId = root.ElementId;
const invalid_id = root.invalid_id;
const Rect = root.Rect;
const UvRect = root.UvRect;
const Vec2 = root.Vec2;
const Color = root.Color;

// ─── Draw commands ─────────────────────────────────────────────────────────

/// A textured quad: sample `uv` from the (host-known) atlas texture into `dst`
/// screen rect, modulated by `tint`. Panel 9-slice cells and images emit this.
pub const TexturedQuad = struct {
    dst: Rect,
    uv: UvRect,
    tint: Color,
};

/// A flat-colored quad — the fallback when a panel's sprite frame can't be
/// resolved (so a mis-authored theme still shows a visible box, not nothing).
pub const SolidQuad = struct {
    dst: Rect,
    color: Color,
};

/// One laid-out line of text. `dst.x`/`dst.y` is the line's top-left after
/// alignment; `dst.w` is the measured line width, `dst.h` the line height.
/// `content` points into the source `UiText.content` (keep the tree alive).
/// `font_name` is empty for the default font.
pub const TextLine = struct {
    dst: Rect,
    content: []const u8,
    color: Color,
    size_px: f32,
    font_name: []const u8,
};

pub const DrawCmd = union(enum) {
    textured_quad: TexturedQuad,
    solid_quad: SolidQuad,
    text_line: TextLine,
    focus_highlight: struct { id: ElementId, rect: Rect },
};

pub const DrawList = std.ArrayList(DrawCmd);

// ─── Resolvers (host-provided) ─────────────────────────────────────────────

/// A sprite frame resolved against the host atlas: `uv` sub-rect + source
/// frame size in pixels (needed to map a panel's pixel border into UV).
pub const ResolvedFrame = struct {
    uv: UvRect,
    frame_px: Vec2,
};

/// Resolves a `UiPanel.sprite_name` to atlas coordinates. In the editor this
/// wraps `atlas.Index`; in the engine it wraps the asset catalog.
pub const FrameResolver = struct {
    context: *const anyopaque = undefined,
    resolveFn: *const fn (context: *const anyopaque, name: []const u8) ?ResolvedFrame,

    pub fn resolve(self: FrameResolver, name: []const u8) ?ResolvedFrame {
        if (name.len == 0) return null;
        return self.resolveFn(self.context, name);
    }
};

/// Resolves a `UiText.font_name` to proportional glyph metrics.
pub const FontResolver = struct {
    context: *const anyopaque = undefined,
    resolveFn: *const fn (context: *const anyopaque, name: []const u8) ?*const font.FontMetrics,

    pub fn resolve(self: FontResolver, name: []const u8) ?*const font.FontMetrics {
        if (name.len == 0) return null;
        return self.resolveFn(self.context, name);
    }
};

pub const Options = struct {
    /// Resolves panel sprite frames. When null, every panel emits its solid
    /// placeholder quad.
    frames: ?FrameResolver = null,
    /// Resolves text fonts to proportional metrics. When a text element's
    /// font doesn't resolve (or this is null), `default_text_metrics` is used.
    fonts: ?FontResolver = null,
    /// Fallback text metrics (e.g. `text.monospace(...)`) for unresolved
    /// fonts. Required — text can't be wrapped without metrics.
    default_text_metrics: text.Metrics,
    /// The currently focused element; emits a `focus_highlight` when it is a
    /// visible button. `invalid_id` disables the ring.
    focused: ElementId = invalid_id,
};

/// Build a draw list for `tree`. Caller owns the returned `DrawList`
/// (`list.deinit(allocator)`); its `text_line.content`/`font_name` slices
/// borrow the tree, so keep the tree alive while consuming the list.
pub fn build(allocator: std.mem.Allocator, tree: *const Tree, opts: Options) !DrawList {
    var list: DrawList = .empty;
    errdefer list.deinit(allocator);

    for (tree.nodes.items) |*el| {
        if (!el.visible) continue;
        if (el.panel) |panel| try emitPanel(allocator, &list, el, panel, opts);
        if (el.text) |txt| try emitText(allocator, &list, el, txt, opts);
        if (el.button) |_| {
            if (opts.focused != invalid_id and el.id == opts.focused) {
                try list.append(allocator, .{ .focus_highlight = .{ .id = el.id, .rect = el.rect } });
            }
        }
    }
    return list;
}

fn emitPanel(
    allocator: std.mem.Allocator,
    list: *DrawList,
    el: *const Element,
    panel: root.Panel,
    opts: Options,
) !void {
    const resolved: ?ResolvedFrame = if (opts.frames) |fr| fr.resolve(panel.sprite_name) else null;
    if (resolved) |rf| {
        if (panel.tile) {
            // Tiled panels emit a variable quad count (repeats instead of
            // stretch), but each is still just a `textured_quad` — consumers
            // of the DrawList never see the difference.
            const quads = try nine_slice.sliceTiled(allocator, el.rect, rf.uv, rf.frame_px, panel.border);
            defer allocator.free(quads);
            for (quads) |q| {
                try list.append(allocator, .{ .textured_quad = .{ .dst = q.dst, .uv = q.uv, .tint = panel.tint } });
            }
            return;
        }
        const quads = nine_slice.slice(el.rect, rf.uv, rf.frame_px, panel.border);
        for (quads) |q| {
            // Skip degenerate cells (zero-area edges/center on tiny panels) so
            // the renderer isn't handed empty quads.
            if (q.dst.w <= 0 or q.dst.h <= 0) continue;
            try list.append(allocator, .{ .textured_quad = .{ .dst = q.dst, .uv = q.uv, .tint = panel.tint } });
        }
    } else {
        try list.append(allocator, .{ .solid_quad = .{ .dst = el.rect, .color = panel.tint } });
    }
}

fn emitText(
    allocator: std.mem.Allocator,
    list: *DrawList,
    el: *const Element,
    txt: root.Text,
    opts: Options,
) !void {
    const metrics: text.Metrics = blk: {
        if (opts.fonts) |fr| {
            if (fr.resolve(txt.font_name)) |fm| break :blk fm.provider();
        }
        break :blk opts.default_text_metrics;
    };

    const wrap_width: f32 = if (txt.wrap) el.rect.w else std.math.floatMax(f32);
    const lines = try text.wrap(allocator, txt.content, wrap_width, txt.size_px, metrics, txt.wrap);
    defer allocator.free(lines);

    const line_h = metrics.lineHeight(txt.size_px);
    var y = el.rect.y;
    for (lines) |line| {
        const xoff = text.xOffset(txt.halign, el.rect.w, line.width);
        try list.append(allocator, .{ .text_line = .{
            .dst = .{ .x = el.rect.x + xoff, .y = y, .w = line.width, .h = line_h },
            .content = line.text,
            .color = txt.color,
            .size_px = txt.size_px,
            .font_name = txt.font_name,
        } });
        y += line_h;
    }
}

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

// A frame resolver that only knows "panel_bg" (64px frame, full-UV).
fn fakeFrameResolve(context: *const anyopaque, name: []const u8) ?ResolvedFrame {
    _ = context;
    if (std.mem.eql(u8, name, "panel_bg")) {
        return .{ .uv = .{ .u0 = 0, .v0 = 0, .u1 = 1, .v1 = 1 }, .frame_px = .{ .x = 64, .y = 64 } };
    }
    return null;
}
fn fakeFrames() FrameResolver {
    return .{ .context = undefined, .resolveFn = fakeFrameResolve };
}

var mono_store: text.MonoStore = .{ .char_ratio = 1.0, .line_ratio = 1.5 };
fn defaultMetrics() text.Metrics {
    mono_store = .{ .char_ratio = 1.0, .line_ratio = 1.5 };
    return text.monospace(&mono_store);
}

fn countKind(list: DrawList, comptime tag: std.meta.Tag(DrawCmd)) usize {
    var n: usize = 0;
    for (list.items) |c| {
        if (c == tag) n += 1;
    }
    return n;
}

test "resolved panel emits nine textured quads" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .panel = .{ .sprite_name = "panel_bg", .border = root.Insets.uniform(16), .frame_px = .{ .x = 64, .y = 64 } },
    });
    var list = try build(testing.allocator, &t, .{ .frames = fakeFrames(), .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 9), countKind(list, .textured_quad));
    try testing.expectEqual(@as(usize, 0), countKind(list, .solid_quad));
}

test "tiled panel emits repeated quads through the same textured_quad command" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    // 64px frame, 16px border → 32px middle segment. 200×100 rect → center
    // 168×68 → 6 columns (5 full + partial) × 3 rows (2 full + partial).
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 },
        .panel = .{ .sprite_name = "panel_bg", .border = root.Insets.uniform(16), .tile = true },
    });
    var list = try build(testing.allocator, &t, .{ .frames = fakeFrames(), .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    // 4 corners + (6+6) horizontal edges + (3+3) vertical edges + 6×3 center.
    try testing.expectEqual(@as(usize, 40), countKind(list, .textured_quad));
    try testing.expectEqual(@as(usize, 0), countKind(list, .solid_quad));
}

test "unresolved panel falls back to one solid quad" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 },
        .panel = .{ .sprite_name = "missing", .tint = .{ .r = 0.2, .g = 0.4, .b = 0.6, .a = 1 } },
    });
    var list = try build(testing.allocator, &t, .{ .frames = fakeFrames(), .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countKind(list, .solid_quad));
    try testing.expectEqual(@as(usize, 0), countKind(list, .textured_quad));
    try testing.expectApproxEqAbs(@as(f32, 0.4), list.items[0].solid_quad.color.g, 0.001);
}

test "no frame resolver → panels are all solid placeholders" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .panel = .{ .sprite_name = "panel_bg" } });
    var list = try build(testing.allocator, &t, .{ .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countKind(list, .solid_quad));
}

test "text emits one command per wrapped line with aligned rects" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    // width 70, monospace 10px/char at size 10 → "aaa bbb" then "ccc".
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 5, .y = 20, .w = 70, .h = 100 },
        .text = .{ .content = "aaa bbb ccc", .size_px = 10, .halign = .left },
    });
    var list = try build(testing.allocator, &t, .{ .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), countKind(list, .text_line));
    const l0 = list.items[0].text_line;
    const l1 = list.items[1].text_line;
    try testing.expectEqualStrings("aaa bbb", l0.content);
    try testing.expectEqualStrings("ccc", l1.content);
    // line height = 1.5 * 10 = 15; first at y=20, second at y=35.
    try testing.expectApproxEqAbs(@as(f32, 20), l0.dst.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 35), l1.dst.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), l0.dst.x, 0.001); // left-aligned at rect.x
}

test "right-aligned text offsets each line by its own width" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 },
        .text = .{ .content = "ab", .size_px = 10, .halign = .right, .wrap = false },
    });
    var list = try build(testing.allocator, &t, .{ .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    // "ab" = 20 wide; right-aligned in 100 → x = 80.
    try testing.expectApproxEqAbs(@as(f32, 80), list.items[0].text_line.dst.x, 0.001);
}

test "focus highlight is emitted only for the focused button" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.add(invalid_id, .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 }, .button = .{ .action_id = "a" } });
    const b = try t.add(invalid_id, .{ .rect = .{ .x = 0, .y = 30, .w = 40, .h = 20 }, .button = .{ .action_id = "b" } });
    _ = a;
    var list = try build(testing.allocator, &t, .{ .default_text_metrics = defaultMetrics(), .focused = b });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), countKind(list, .focus_highlight));
    try testing.expectEqual(b, list.items[0].focus_highlight.id);
}

test "invisible elements emit nothing" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{ .visible = false, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .panel = .{ .sprite_name = "panel_bg" } });
    var list = try build(testing.allocator, &t, .{ .frames = fakeFrames(), .default_text_metrics = defaultMetrics() });
    defer list.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), list.items.len);
}

test "font resolver drives proportional wrapping when the font resolves" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    // A proportional font where 'W' is wide (12) and 'i' narrow (4), baked 10px.
    var fm = fontFixture();
    _ = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 40, .h = 100 },
        .text = .{ .content = "WWW ii", .size_px = 10, .font_name = "prop" },
    });
    var list = try build(testing.allocator, &t, .{
        .default_text_metrics = defaultMetrics(),
        .fonts = .{ .context = &fm, .resolveFn = fontResolve },
    });
    defer list.deinit(testing.allocator);
    // Proportional widths split "WWW" (36) from "ii" (8) at width 40.
    try testing.expectEqual(@as(usize, 2), countKind(list, .text_line));
    try testing.expectEqualStrings("WWW", list.items[0].text_line.content);
}

var g_font: font.FontMetrics = undefined;
fn fontFixture() font.FontMetrics {
    const glyphs = &[_]font.Glyph{
        .{ .u0 = 0, .v0 = 0, .u1 = 4, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 4 }, // 'i'
        .{ .u0 = 0, .v0 = 0, .u1 = 12, .v1 = 10, .xoff = 0, .yoff = 0, .advance = 12 }, // 'W'
    };
    const cps = &[_]font.CodepointEntry{
        .{ .codepoint = 'W', .glyph_index = 1 },
        .{ .codepoint = 'i', .glyph_index = 0 },
    };
    return .{ .glyphs = glyphs, .codepoint_index = cps, .pixel_height = 10, .ascent = 8, .descent = -2 };
}
fn fontResolve(context: *const anyopaque, name: []const u8) ?*const font.FontMetrics {
    if (!std.mem.eql(u8, name, "prop")) return null;
    return @ptrCast(@alignCast(context));
}
