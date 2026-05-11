//! Gizmo editor — per-tab state and rendering.
//!
//! A gizmo lives at `<project>/gizmos/<name>.zon` and tells the
//! engine: "any entity matching `.match` (and not matching
//! `.exclude`) gets the declared visual attached at runtime". See
//! `gizmo_io.zig` for the file shape and v1 verbatim pass-through.
//!
//! UX v1: a single-column inspector. The user can edit the
//! `match`/`exclude` lists (typed) but the entity/children Shape
//! blocks are read-only verbatim ZON. No viewport — gizmos describe
//! shapes relative to entities, and rendering one in isolation
//! against a placeholder entity would be misleading.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const gizmo_io = @import("../gizmo_io.zig");

/// Edit buffer size for a single match/exclude entry. Component
/// names are short identifiers in practice; 128 bytes is comfortable
/// headroom over what the engine accepts.
const tag_buf_len: usize = 128;

const TagBuf = [tag_buf_len:0]u8;

pub const GizmoState = struct {
    arena: *std.heap.ArenaAllocator,
    path: []const u8,
    display_name: []const u8,
    loaded: gizmo_io.LoadedGizmo,
    /// Mirror buffers for `loaded.gizmo.match`. inputText writes into
    /// these in place; on save we copy the buffer slices back into
    /// `loaded.gizmo.match` (arena-owned). Sized at load.
    match_bufs: []TagBuf = &.{},
    exclude_bufs: []TagBuf = &.{},
    /// Sentinel-terminated, mutable copies of the verbatim ZON blocks
    /// for `inputTextMultiline`. Sized to exactly fit the text — the
    /// previous fixed 4 KiB stack buffer truncated larger gizmos. Null
    /// when the corresponding block is absent. Owned by `arena`.
    entity_buf: ?[:0]u8 = null,
    children_buf: ?[:0]u8 = null,
    is_dirty: bool = false,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !GizmoState {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const a = arena.allocator();
        const path_dup = try a.dupe(u8, path);
        const display_name = gizmo_io.displayNameFromPath(path_dup);

        var loaded = try gizmo_io.loadFromFile(allocator, path);
        errdefer loaded.deinit();

        const match_bufs = try makeTagBufs(a, loaded.gizmo.match);
        const exclude_bufs = try makeTagBufs(a, loaded.gizmo.exclude);

        const entity_buf: ?[:0]u8 = if (loaded.gizmo.entity_verbatim) |t|
            try a.dupeZ(u8, t)
        else
            null;
        const children_buf: ?[:0]u8 = if (loaded.gizmo.children_verbatim) |t|
            try a.dupeZ(u8, t)
        else
            null;

        return .{
            .arena = arena,
            .path = path_dup,
            .display_name = display_name,
            .loaded = loaded,
            .match_bufs = match_bufs,
            .exclude_bufs = exclude_bufs,
            .entity_buf = entity_buf,
            .children_buf = children_buf,
        };
    }

    pub fn deinit(self: *GizmoState, allocator: std.mem.Allocator) void {
        self.loaded.deinit();
        self.arena.deinit();
        allocator.destroy(self.arena);
    }
};

fn makeTagBufs(arena: std.mem.Allocator, src: [][]const u8) ![]TagBuf {
    const out = try arena.alloc(TagBuf, src.len);
    for (out, src) |*buf, s| {
        @memset(buf, 0);
        const n = @min(buf.len - 1, s.len);
        @memcpy(buf[0..n], s[0..n]);
    }
    return out;
}

pub fn render(s: *GizmoState, app: *App) void {
    zgui.text("Gizmo: {s}", .{s.display_name});
    if (s.is_dirty) {
        zgui.sameLine(.{});
        zgui.textColored(.{ 1.0, 0.5, 0.0, 1.0 }, "(unsaved)", .{});
    }
    zgui.sameLine(.{});
    if (zgui.button("Save", .{})) saveGizmo(s, app);
    zgui.separator();

    renderTagList(s, .match);
    zgui.spacing();
    renderTagList(s, .exclude);

    zgui.spacing();
    zgui.separator();

    if (s.entity_buf) |buf| {
        if (zgui.collapsingHeader("Entity", .{ .default_open = true })) {
            zgui.textDisabled("(read-only — edit by hand for v1)", .{});
            renderReadOnlyMultiline("##gizmo_entity", buf);
        }
    }
    if (s.children_buf) |buf| {
        if (zgui.collapsingHeader("Children", .{ .default_open = true })) {
            zgui.textDisabled("(read-only — edit by hand for v1)", .{});
            renderReadOnlyMultiline("##gizmo_children", buf);
        }
    }
}

const TagKind = enum { match, exclude };

fn renderTagList(s: *GizmoState, kind: TagKind) void {
    const arena_alloc = s.arena.allocator();
    const label: []const u8 = switch (kind) {
        .match => "Match",
        .exclude => "Exclude",
    };
    zgui.text("{s}", .{label});

    const bufs = switch (kind) {
        .match => s.match_bufs,
        .exclude => s.exclude_bufs,
    };
    const tags = switch (kind) {
        .match => s.loaded.gizmo.match,
        .exclude => s.loaded.gizmo.exclude,
    };

    var remove_idx: ?usize = null;
    var id_buf: [64]u8 = undefined;

    for (bufs, 0..) |*buf, i| {
        zgui.pushIntId(@intCast(i));
        defer zgui.popId();

        const input_id = std.fmt.bufPrintZ(&id_buf, "##tag_{s}_{d}", .{ @tagName(kind), i }) catch "##tag";
        if (zgui.inputText(input_id, .{ .buf = buf })) {
            // Reflect edit into the typed tags slice. Lifetime is
            // pinned to the buffer (sentinel-terminated, never freed
            // until the tab closes), so a borrowed slice is safe.
            tags[i] = std.mem.sliceTo(buf, 0);
            s.is_dirty = true;
        }
        zgui.sameLine(.{});
        const x_id = std.fmt.bufPrintZ(&id_buf, "x##rm_{s}_{d}", .{ @tagName(kind), i }) catch "x";
        if (zgui.smallButton(x_id)) {
            remove_idx = i;
        }
    }

    const add_id: [:0]const u8 = switch (kind) {
        .match => "+ Add match",
        .exclude => "+ Add exclude",
    };
    if (zgui.button(add_id, .{})) {
        appendTag(s, kind, arena_alloc) catch |err| {
            std.log.err("gizmo: failed to grow {s} list: {s}", .{ @tagName(kind), @errorName(err) });
        };
    }

    if (remove_idx) |idx| {
        removeTag(s, kind, idx, arena_alloc) catch |err| {
            std.log.err("gizmo: failed to shrink {s} list: {s}", .{ @tagName(kind), @errorName(err) });
        };
    }
}

fn appendTag(s: *GizmoState, kind: TagKind, arena: std.mem.Allocator) !void {
    switch (kind) {
        .match => {
            s.loaded.gizmo.match = try growStrings(arena, s.loaded.gizmo.match, "");
            s.match_bufs = try growBufs(arena, s.match_bufs);
        },
        .exclude => {
            s.loaded.gizmo.exclude = try growStrings(arena, s.loaded.gizmo.exclude, "");
            s.exclude_bufs = try growBufs(arena, s.exclude_bufs);
        },
    }
    s.is_dirty = true;
}

fn removeTag(s: *GizmoState, kind: TagKind, idx: usize, arena: std.mem.Allocator) !void {
    switch (kind) {
        .match => {
            s.loaded.gizmo.match = try removeStrings(arena, s.loaded.gizmo.match, idx);
            s.match_bufs = try removeBufs(arena, s.match_bufs, idx);
        },
        .exclude => {
            s.loaded.gizmo.exclude = try removeStrings(arena, s.loaded.gizmo.exclude, idx);
            s.exclude_bufs = try removeBufs(arena, s.exclude_bufs, idx);
        },
    }
    s.is_dirty = true;
}

fn growStrings(arena: std.mem.Allocator, src: [][]const u8, addition: []const u8) ![][]const u8 {
    const out = try arena.alloc([]const u8, src.len + 1);
    @memcpy(out[0..src.len], src);
    out[src.len] = addition;
    return out;
}

fn growBufs(arena: std.mem.Allocator, src: []TagBuf) ![]TagBuf {
    const out = try arena.alloc(TagBuf, src.len + 1);
    @memcpy(out[0..src.len], src);
    @memset(&out[src.len], 0);
    return out;
}

fn removeStrings(arena: std.mem.Allocator, src: [][]const u8, idx: usize) ![][]const u8 {
    if (idx >= src.len) return src;
    const out = try arena.alloc([]const u8, src.len - 1);
    @memcpy(out[0..idx], src[0..idx]);
    @memcpy(out[idx..], src[idx + 1 ..]);
    return out;
}

fn removeBufs(arena: std.mem.Allocator, src: []TagBuf, idx: usize) ![]TagBuf {
    if (idx >= src.len) return src;
    const out = try arena.alloc(TagBuf, src.len - 1);
    @memcpy(out[0..idx], src[0..idx]);
    @memcpy(out[idx..], src[idx + 1 ..]);
    return out;
}

fn renderReadOnlyMultiline(id: [:0]const u8, buf: [:0]u8) void {
    // Read-only inputTextMultiline still requires a writable, sentinel-
    // terminated buffer (zgui copies into it for cursor state). The
    // buffer is precomputed and arena-owned by `GizmoState.open`, sized
    // to fit the full verbatim block — no truncation for large gizmos.

    // Approximate line count to size the widget. Clamped so a tiny
    // block doesn't render with a single-line slit and a huge one
    // doesn't dominate the inspector.
    var line_count: usize = 1;
    for (buf) |c| {
        if (c == '\n') line_count += 1;
    }
    const lines_clamped = @max(@min(line_count, @as(usize, 14)), @as(usize, 4));
    const h: f32 = @floatFromInt(@as(u32, @intCast(lines_clamped)) * 18);

    _ = zgui.inputTextMultiline(id, .{
        .buf = buf,
        .w = 0,
        .h = h,
        .flags = .{ .read_only = true },
    });
}

pub fn saveGizmo(s: *GizmoState, app: *App) void {
    gizmo_io.saveGizmo(app.allocator, s.path, s.loaded) catch |err| {
        std.log.err("Gizmo save failed at {s}: {s}", .{ s.path, @errorName(err) });
        app.setStatus("Error saving gizmo!");
        return;
    };
    s.is_dirty = false;
    app.rebuildGizmoIndex();
    app.setStatus("Gizmo saved!");
}
