//! In-game UI kit — retained game UI as entities (issue #214).
//!
//! This is the **content-first** model for menus / HUD / dialogs that the
//! Bevy gap analysis (2026-07-10, rank 3) called out: UI elements as
//! entities on screen-space layers rather than a hand-built sprite +
//! imgui affair. It is deliberately *not* a widget framework and *not*
//! immediate-mode — `labelle-gui`/imgui keeps the tooling-UI role.
//!
//! ## What lives here
//!
//! A dependency-free, pure-Zig core that both the editor (authoring UI
//! entities into scenes/prefabs) and the engine (running them) can share.
//! Nothing in this directory imports GL, imgui, a font rasterizer, or an
//! allocator-of-record beyond what each function is handed — everything is
//! unit-testable in isolation.
//!
//! - `mod.zig`         — geometry primitives, the retained `Tree`, the
//!                       component data (`Panel`/`Text`/`Button`/`Layout`),
//!                       and the `ui__clicked` event queue.
//! - `nine_slice.zig`  — 9-slice quad decomposition (COMPLETE, tested).
//! - `focus.zig`       — controller/keyboard focus navigation (COMPLETE,
//!                       tested): directional move + tab order + wrap.
//! - `layout.zig`      — the small row/column/anchor constraint pass
//!                       (COMPLETE, tested). NOT flexbox — see non-goals.
//! - `text.zig`        — text wrapping + alignment against a size-parameterized
//!                       glyph-metrics seam (COMPLETE, tested).
//! - `font.zig`        — real proportional metrics behind that seam, driven by
//!                       a baked glyph table whose `extern` layout matches
//!                       labelle-core so a loaded font casts straight in
//!                       (COMPLETE, tested).
//! - `render.zig`      — the engine-binding contract: walks a laid-out tree
//!                       into a flat, backend-agnostic `DrawList` (COMPLETE,
//!                       tested). This is the surface a renderer consumes.
//!
//! ## Consuming from a renderer (the engine binding)
//!
//! 1. Build/mutate a `Tree` of elements (authored from a scene/prefab).
//! 2. `layout.apply(&tree, root, screen)` to compute every `rect`.
//! 3. Feed input: `focus.navigate` / `tree.pointerRelease` (drains
//!    `ui__clicked` events for the game / Lua bus).
//! 4. `render.build(alloc, &tree, .{...})` → a `DrawList`; iterate it and map
//!    each `DrawCmd` to a backend draw call. That call site is the only
//!    cross-repo seam, and it is GPU-type-free by construction.
//!
//! ## Retained, not immediate
//!
//! A `Tree` is built once, then mutated across frames — element identity
//! (`ElementId`) is stable, so gameplay code, Lua (via the #237 event
//! contract), and the layout/focus passes all key off ids that persist.
//! This mirrors how the engine treats other entities and is what lets a
//! HUD element be flipped visible/invisible or re-themed without a rebuild.

const std = @import("std");

/// Pull the sibling subsystems' `test` blocks into the test root. Zig only
/// walks *used* decls for test discovery, and `tests.zig` references this
/// file via `comptime { _ = ui_kit; }` — so re-exporting here is what makes
/// the whole kit's tests reachable from `zig build test`.
pub const nine_slice = @import("nine_slice.zig");
pub const focus = @import("focus.zig");
pub const layout = @import("layout.zig");
pub const text = @import("text.zig");
pub const font = @import("font.zig");
pub const render = @import("render.zig");

comptime {
    _ = nine_slice;
    _ = focus;
    _ = layout;
    _ = text;
    _ = font;
    _ = render;
}

// ─── Geometry primitives ──────────────────────────────────────────────────

pub const Vec2 = struct {
    x: f32 = 0,
    y: f32 = 0,
};

/// Screen-space rectangle. Origin is top-left, +y points down (screen
/// convention — note this is the *opposite* of the world-space viewport in
/// `modules/viewport.zig`, because UI is pinned to the screen/camera layer).
pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    w: f32 = 0,
    h: f32 = 0,

    pub fn right(self: Rect) f32 {
        return self.x + self.w;
    }
    pub fn bottom(self: Rect) f32 {
        return self.y + self.h;
    }
    pub fn center(self: Rect) Vec2 {
        return .{ .x = self.x + self.w * 0.5, .y = self.y + self.h * 0.5 };
    }
    pub fn contains(self: Rect, p: Vec2) bool {
        return p.x >= self.x and p.x <= self.right() and
            p.y >= self.y and p.y <= self.bottom();
    }
    /// Shrink by `i` on every side (used to turn a panel's outer rect into
    /// its content rect). Never produces negative extents.
    pub fn inset(self: Rect, i: Insets) Rect {
        const w = @max(0, self.w - i.left - i.right);
        const h = @max(0, self.h - i.top - i.bottom);
        return .{ .x = self.x + i.left, .y = self.y + i.top, .w = w, .h = h };
    }
    pub fn eqlApprox(self: Rect, other: Rect, eps: f32) bool {
        return @abs(self.x - other.x) <= eps and @abs(self.y - other.y) <= eps and
            @abs(self.w - other.w) <= eps and @abs(self.h - other.h) <= eps;
    }
};

pub const Insets = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,

    pub fn uniform(v: f32) Insets {
        return .{ .left = v, .right = v, .top = v, .bottom = v };
    }
    pub fn horizontal(self: Insets) f32 {
        return self.left + self.right;
    }
    pub fn vertical(self: Insets) f32 {
        return self.top + self.bottom;
    }
};

/// Straight (non-premultiplied) RGBA, components in 0..1. Kept as f32 so a
/// theme pack can express tints without an 8-bit round-trip; the renderer
/// quantizes at upload.
pub const Color = struct {
    r: f32 = 1,
    g: f32 = 1,
    b: f32 = 1,
    a: f32 = 1,

    pub const white: Color = .{};
    pub const transparent: Color = .{ .a = 0 };

    /// 8-bit RGBA, matching the engine's `gui_types.GuiColor` (0..255). The
    /// renderer boundary quantizes here so authored f32 tints round-trip to
    /// the backend's color type.
    pub const Rgba8 = struct { r: u8 = 255, g: u8 = 255, b: u8 = 255, a: u8 = 255 };

    pub fn toU8(self: Color) Rgba8 {
        return .{
            .r = quant(self.r),
            .g = quant(self.g),
            .b = quant(self.b),
            .a = quant(self.a),
        };
    }

    fn quant(v: f32) u8 {
        const clamped = @max(0, @min(1, v));
        return @intFromFloat(@round(clamped * 255));
    }
};

/// Where a child sits inside the space its parent's layout hands it (and,
/// for the root, inside the screen). Mirrors the nine box-model anchors
/// most game UIs expose.
pub const Anchor = enum {
    top_left,
    top,
    top_right,
    left,
    center,
    right,
    bottom_left,
    bottom,
    bottom_right,

    pub fn fractions(self: Anchor) Vec2 {
        return switch (self) {
            .top_left => .{ .x = 0, .y = 0 },
            .top => .{ .x = 0.5, .y = 0 },
            .top_right => .{ .x = 1, .y = 0 },
            .left => .{ .x = 0, .y = 0.5 },
            .center => .{ .x = 0.5, .y = 0.5 },
            .right => .{ .x = 1, .y = 0.5 },
            .bottom_left => .{ .x = 0, .y = 1 },
            .bottom => .{ .x = 0.5, .y = 1 },
            .bottom_right => .{ .x = 1, .y = 1 },
        };
    }
};

// ─── Component data (the "kit") ────────────────────────────────────────────

/// A rectangle in an atlas texture, in normalized UV (0..1). This is what an
/// authored element references by name; the editor's `atlas.Index` resolves
/// the name → these coordinates, exactly like `Sprite` today.
pub const UvRect = struct {
    u0: f32 = 0,
    v0: f32 = 0,
    u1: f32 = 1,
    v1: f32 = 1,
};

/// `UiPanel` — a 9-slice background drawn from an atlas frame. `border` is
/// the un-stretched margin (in source pixels) that maps to the frame's four
/// corners; the middle stretches (or tiles) to fill. The actual quad
/// decomposition is `nine_slice.slice`.
pub const Panel = struct {
    /// Atlas frame name, resolved by the host (editor/engine) to `frame_uv`.
    sprite_name: []const u8 = "",
    /// Source-pixel border widths that stay un-stretched at each edge.
    border: Insets = .{},
    /// Source frame size in pixels — needed to convert `border` (pixels)
    /// into UV space. Defaults keep the math well-defined if unset.
    frame_px: Vec2 = .{ .x = 1, .y = 1 },
    tint: Color = .white,
    /// When true, edges/center repeat instead of stretch (v1 supports the
    /// flag in the model; the stretch path is what `nine_slice` emits and
    /// the tiling path is left to the renderer).
    tile: bool = false,
};

pub const TextAlign = enum { left, center, right };

/// `UiText` — wrapping text content. Real glyph metrics come from the font
/// loader (RFC-FONT-LOADER); `text.zig` does the wrapping/alignment against
/// whatever metrics it is handed.
pub const Text = struct {
    content: []const u8 = "",
    /// Font size in logical pixels (line advance is derived from metrics).
    size_px: f32 = 16,
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    /// Name of a font asset (resolved by the host to real glyph metrics — see
    /// `font.FontMetrics` and `render.FontResolver`). Empty = the renderer's
    /// default font, matching `gui_types.Label.font == null`.
    font_name: []const u8 = "",
    halign: TextAlign = .left,
    /// When true, break on word boundaries to fit the element's content
    /// width; when false, render single-line (clip/overflow is the host's
    /// problem).
    wrap: bool = true,
};

/// Interaction state for a `UiButton`. Retained on the element so the
/// renderer can pick the right visual and gameplay can read it.
pub const ButtonState = enum { normal, hovered, focused, pressed, disabled };

/// `UiButton` — a focusable, clickable element. On release-inside it emits
/// `ui__clicked {id}` onto the tree's event queue; the standard event bus /
/// Lua bindings (#237) turn that into game reactions with no engine changes.
pub const Button = struct {
    /// Stable string id used in the emitted event payload (`{id}`), distinct
    /// from the numeric `ElementId` so content authors control it.
    action_id: []const u8 = "",
    state: ButtonState = .normal,
    disabled: bool = false,
};

pub const Direction = enum { row, column };

/// `UiLayout` — the small constraint pass. Arranges an element's *direct*
/// children along one axis with a gap and content padding, optionally
/// stretching them across the cross axis. This is intentionally linear:
/// CSS-grade layout is an explicit v1 non-goal.
pub const Layout = struct {
    direction: Direction = .column,
    gap: f32 = 0,
    padding: Insets = .{},
    /// Cross-axis placement of each child within the track.
    cross_align: Anchor = .top_left,
    /// When true, children are stretched to fill the cross-axis extent
    /// (their own `size` cross component is ignored).
    stretch_cross: bool = false,
};

// ─── The retained entity model ─────────────────────────────────────────────

pub const ElementId = u32;
pub const invalid_id: ElementId = 0;

/// A UI entity. Components are optional and typed, mirroring `scene_io.zig`'s
/// "typed component or nothing" shape. `size` is the element's preferred
/// size, consumed by a parent's `Layout`; `rect` is the *computed*
/// screen-space box written by the layout pass and read by rendering + focus.
pub const Element = struct {
    id: ElementId = invalid_id,
    parent: ElementId = invalid_id,

    /// Preferred size (layout input). A zero component means "let the layout
    /// decide / stretch".
    size: Vec2 = .{},
    /// Where this element anchors within the slot its parent gives it.
    anchor: Anchor = .top_left,
    /// Computed screen-space rect (layout output). Retained across frames.
    rect: Rect = .{},

    visible: bool = true,
    focusable: bool = false,

    // Optional components — the "kit" pieces.
    layout: ?Layout = null,
    panel: ?Panel = null,
    text: ?Text = null,
    button: ?Button = null,

    /// Directional-nav overrides. When set, focus navigation uses the named
    /// neighbour instead of the geometric best guess (lets an author pin
    /// menu wrap-around). `invalid_id` means "compute it".
    nav_up: ElementId = invalid_id,
    nav_down: ElementId = invalid_id,
    nav_left: ElementId = invalid_id,
    nav_right: ElementId = invalid_id,
};

pub const Event = union(enum) {
    /// Emitted by a `Button` on release-inside. `action_id` points into the
    /// button's own storage (tree-owned) — copy it if it must outlive the
    /// element.
    clicked: struct { id: ElementId, action_id: []const u8 },
};

/// A retained tree of UI entities. Ids are stable and never reused within a
/// tree's lifetime, so external references (focus, gameplay, Lua) stay valid
/// as children are added/removed. Children are tracked as a flat parent
/// pointer plus a per-node order index; `childrenOf` reconstructs order.
pub const Tree = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayList(Element) = .empty,
    events: std.ArrayList(Event) = .empty,
    next_id: ElementId = invalid_id + 1,

    pub fn init(allocator: std.mem.Allocator) Tree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    /// Add an element under `parent` (`invalid_id` for a root). The caller's
    /// `id`/`parent` fields are overwritten with the assigned values.
    pub fn add(self: *Tree, parent: ElementId, element: Element) !ElementId {
        const id = self.next_id;
        self.next_id += 1;
        var el = element;
        el.id = id;
        el.parent = parent;
        try self.nodes.append(self.allocator, el);
        return id;
    }

    pub fn get(self: *Tree, id: ElementId) ?*Element {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    pub fn getConst(self: *const Tree, id: ElementId) ?*const Element {
        for (self.nodes.items) |*n| {
            if (n.id == id) return n;
        }
        return null;
    }

    /// Number of direct children of `parent`.
    pub fn childCount(self: *const Tree, parent: ElementId) usize {
        var n: usize = 0;
        for (self.nodes.items) |*e| {
            if (e.parent == parent) n += 1;
        }
        return n;
    }

    /// Append the ids of `parent`'s direct children (in insertion order)
    /// into `out`. Returns the slice actually written.
    pub fn childrenOf(self: *const Tree, parent: ElementId, out: []ElementId) []ElementId {
        var n: usize = 0;
        for (self.nodes.items) |*e| {
            if (e.parent == parent and n < out.len) {
                out[n] = e.id;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// Feed a pointer-release into the button under `p` (if any). Returns the
    /// clicked id and pushes a `ui__clicked` event. `pressed_id` is the
    /// element that received the press, so a drag-off-and-release does not
    /// fire (standard button semantics).
    pub fn pointerRelease(self: *Tree, p: Vec2, pressed_id: ElementId) !?ElementId {
        const hit = self.hitTest(p) orelse return null;
        if (hit != pressed_id) return null;
        const el = self.get(hit) orelse return null;
        const btn = el.button orelse return null;
        if (btn.disabled) return null;
        try self.events.append(self.allocator, .{ .clicked = .{
            .id = hit,
            .action_id = btn.action_id,
        } });
        return hit;
    }

    /// Topmost visible element whose computed rect contains `p`. "Topmost" =
    /// last in insertion order among matches (later siblings/children draw on
    /// top), matching painter's-order rendering.
    pub fn hitTest(self: *const Tree, p: Vec2) ?ElementId {
        var found: ?ElementId = null;
        for (self.nodes.items) |*e| {
            if (e.visible and e.rect.contains(p)) found = e.id;
        }
        return found;
    }

    pub fn clearEvents(self: *Tree) void {
        self.events.clearRetainingCapacity();
    }
};

// ─── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "Rect helpers: right/bottom/center/contains" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 40 };
    try testing.expectEqual(@as(f32, 110), r.right());
    try testing.expectEqual(@as(f32, 60), r.bottom());
    try testing.expectEqual(@as(f32, 60), r.center().x);
    try testing.expectEqual(@as(f32, 40), r.center().y);
    try testing.expect(r.contains(.{ .x = 10, .y = 20 }));
    try testing.expect(r.contains(.{ .x = 60, .y = 40 }));
    try testing.expect(!r.contains(.{ .x = 9, .y = 40 }));
    try testing.expect(!r.contains(.{ .x = 60, .y = 61 }));
}

test "Rect.inset never goes negative" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const small = r.inset(Insets.uniform(20));
    try testing.expectEqual(@as(f32, 0), small.w);
    try testing.expectEqual(@as(f32, 0), small.h);
    const ok = r.inset(.{ .left = 2, .top = 3 });
    try testing.expect(ok.eqlApprox(.{ .x = 2, .y = 3, .w = 8, .h = 7 }, 0.0001));
}

test "Tree.add assigns stable, non-reused ids and wires parent" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const root = try t.add(invalid_id, .{});
    const a = try t.add(root, .{});
    const b = try t.add(root, .{});
    try testing.expect(root != a and a != b);
    try testing.expectEqual(root, t.get(a).?.parent);
    try testing.expectEqual(@as(usize, 2), t.childCount(root));

    var buf: [8]ElementId = undefined;
    const kids = t.childrenOf(root, &buf);
    try testing.expectEqual(@as(usize, 2), kids.len);
    try testing.expectEqual(a, kids[0]);
    try testing.expectEqual(b, kids[1]);
}

test "hitTest returns the topmost (last-added) match" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    _ = try t.add(invalid_id, .{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } });
    const top = try t.add(invalid_id, .{ .rect = .{ .x = 40, .y = 40, .w = 20, .h = 20 } });
    try testing.expectEqual(top, t.hitTest(.{ .x = 50, .y = 50 }).?);
    // Outside the top rect but inside the base still hits the base.
    const base_hit = t.hitTest(.{ .x = 10, .y = 10 }).?;
    try testing.expect(base_hit != top);
}

test "hitTest skips invisible elements" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const a = try t.add(invalid_id, .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } });
    const hidden = try t.add(invalid_id, .{ .visible = false, .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } });
    _ = hidden;
    try testing.expectEqual(a, t.hitTest(.{ .x = 5, .y = 5 }).?);
}

test "button click emits ui__clicked only on release over the pressed element" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const btn = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
        .focusable = true,
        .button = .{ .action_id = "start" },
    });
    // Press and release inside → click fires.
    const clicked = try t.pointerRelease(.{ .x = 10, .y = 10 }, btn);
    try testing.expectEqual(btn, clicked.?);
    try testing.expectEqual(@as(usize, 1), t.events.items.len);
    try testing.expectEqualStrings("start", t.events.items[0].clicked.action_id);

    // Release outside the pressed element → no new event.
    t.clearEvents();
    const miss = try t.pointerRelease(.{ .x = 999, .y = 999 }, btn);
    try testing.expect(miss == null);
    try testing.expectEqual(@as(usize, 0), t.events.items.len);
}

test "disabled button does not emit" {
    var t = Tree.init(testing.allocator);
    defer t.deinit();
    const btn = try t.add(invalid_id, .{
        .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 },
        .button = .{ .action_id = "x", .disabled = true },
    });
    const clicked = try t.pointerRelease(.{ .x = 5, .y = 5 }, btn);
    try testing.expect(clicked == null);
    try testing.expectEqual(@as(usize, 0), t.events.items.len);
}
