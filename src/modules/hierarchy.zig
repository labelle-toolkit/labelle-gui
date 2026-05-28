//! Hierarchy panel — flat searchable list of every entity in the
//! active scene/prefab tab (#144). Solves selection failures on the
//! canvas when entities overlap, sit off-viewport, or carry no
//! visible footprint.
//!
//! Selection state is mirrored, not stored: clicking a row writes
//! through to the active tab's existing `selected_index` /
//! `selected_child_idx` field, so the canvas and the panel share
//! one source of truth. The inspector reads from that same field,
//! which gives the bidirectional sync for free.
//!
//! No effect when the active tab is anything other than a scene or
//! prefab editor (the flow / gizmo tabs have their own selection
//! models). The panel still renders, just with an "Open a scene
//! or prefab to browse its entities" placeholder.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const scene_io = @import("../scene_io.zig");
const scene_mod = @import("scene.zig");
const prefab_mod = @import("prefab.zig");

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "hierarchy",
        .display_name = "Hierarchy",
        .is_open = &app.show_hierarchy,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Hierarchy", .{
        .popen = &app.show_hierarchy,
        .flags = .{},
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    // Search bar — case-insensitive substring match against the row
    // label below. Buffer is owned by App so the filter survives
    // panel close/reopen, matching the resources panel's pattern.
    _ = zgui.inputTextWithHint("##hierarchy_filter", .{
        .hint = "filter…",
        .buf = &app.hierarchy_filter,
    });
    zgui.separator();

    const tab_idx = app.active_tab_idx orelse {
        zgui.textDisabled("Open a scene or prefab to browse its entities.", .{});
        return;
    };
    if (tab_idx >= app.open_tabs.items.len) {
        zgui.textDisabled("(no active tab)", .{});
        return;
    }

    const filter = std.mem.sliceTo(&app.hierarchy_filter, 0);

    switch (app.open_tabs.items[tab_idx]) {
        .scene => |*s| renderSceneRows(s, filter),
        .prefab => |*p| renderPrefabRows(p, filter),
        else => zgui.textDisabled("Active tab has no entity tree.", .{}),
    }
}

fn renderSceneRows(s: *scene_mod.SceneState, filter: []const u8) void {
    if (s.loaded.scene.entities.len == 0) {
        zgui.textDisabled("(scene is empty)", .{});
        return;
    }

    // Auto-scroll on externally-driven selection changes (e.g. user
    // clicked an entity on the canvas). `last_seen_selected_index`
    // mirrors the field the previous frame saw — when the live value
    // diverges and was NOT set by clicking a row in this panel, the
    // selectable for that row calls `setScrollHereY` so the user
    // gets visual confirmation that the click registered, even when
    // the panel is unfocused / dimmed behind the canvas.
    const auto_scroll_to: ?usize = if (s.selected_index) |cur|
        if (s.hierarchy_last_seen != cur) cur else null
    else
        null;
    s.hierarchy_last_seen = s.selected_index;

    var visible: usize = 0;
    for (s.loaded.scene.entities, 0..) |*entity, i| {
        var label_buf: [512:0]u8 = undefined;
        const label = entityLabel(&label_buf, i, entity) catch continue;
        if (filter.len > 0 and !matchesFilter(label, filter)) continue;

        const selected = if (s.selected_index) |sel| sel == i else false;
        if (zgui.selectable(label, .{ .selected = selected })) {
            s.selected_index = i;
            // Update the mirror so the auto-scroll branch above
            // doesn't fire next frame for an in-panel click.
            s.hierarchy_last_seen = i;
        }
        if (auto_scroll_to) |target| {
            if (target == i) zgui.setScrollHereY(.{});
        }
        visible += 1;
    }

    if (visible == 0) {
        zgui.textDisabled("(no entities match filter)", .{});
    }
}

fn renderPrefabRows(p: *prefab_mod.PrefabState, filter: []const u8) void {
    // Auto-scroll on externally-driven selection changes. Unlike the
    // scene panel (which only has child rows), the prefab panel has
    // an extra `(prefab body)` row that represents `selected_child_idx
    // == null`. Tracking the mirror as a bare `?usize` would conflate
    // "no selection yet" with "body row picked" and skip scroll-to-
    // body, so the target is encoded as a tagged union and the change
    // detection compares both nullness and value.
    const Target = union(enum) { body, child: usize };
    const changed = blk: {
        const a = p.hierarchy_last_seen;
        const b = p.selected_child_idx;
        if (a == null and b == null) break :blk false;
        if (a == null or b == null) break :blk true;
        break :blk a.? != b.?;
    };
    const auto_scroll_to: ?Target = if (changed)
        (if (p.selected_child_idx) |cur| Target{ .child = cur } else .body)
    else
        null;
    p.hierarchy_last_seen = p.selected_child_idx;

    // The prefab body itself is row #0 (`null` selection on the
    // canvas), so the panel offers a way back to it after navigating
    // a child without having to click the canvas's empty background.
    const body_label = "(prefab body)";
    const body_selected = p.selected_child_idx == null;
    if (filter.len == 0 or matchesFilter(body_label, filter)) {
        if (zgui.selectable(body_label, .{ .selected = body_selected })) {
            p.selected_child_idx = null;
            p.hierarchy_last_seen = null;
        }
        if (auto_scroll_to) |target| {
            if (target == .body) zgui.setScrollHereY(.{});
        }
    }

    if (p.loaded.children.len == 0) {
        if (filter.len > 0) zgui.textDisabled("(prefab has no children)", .{});
        return;
    }

    var visible: usize = 0;
    for (p.loaded.children, 0..) |*child, i| {
        var label_buf: [512:0]u8 = undefined;
        const label = entityLabel(&label_buf, i, child) catch continue;
        if (filter.len > 0 and !matchesFilter(label, filter)) continue;

        const selected = if (p.selected_child_idx) |sel| sel == i else false;
        if (zgui.selectable(label, .{ .selected = selected })) {
            p.selected_child_idx = i;
            p.hierarchy_last_seen = i;
        }
        if (auto_scroll_to) |target| switch (target) {
            .child => |idx| if (idx == i) zgui.setScrollHereY(.{}),
            .body => {},
        };
        visible += 1;
    }

    if (visible == 0 and filter.len > 0) {
        zgui.textDisabled("(no children match filter)", .{});
    }
}

/// `#N <prefab_name>` for prefab refs; `#N (inline)` for entities
/// without a prefab field. The comment buffer's first non-empty line
/// rides along as a hint when present so authored notes stay
/// discoverable in the list. Separator stays ASCII (`-`) — the
/// emdash glyph isn't covered by ImGui's default font and renders
/// as `?` on the panel.
fn entityLabel(buf: *[512:0]u8, idx: usize, entity: *const scene_io.Entity) ![:0]u8 {
    const name: []const u8 = entity.prefab orelse "(inline)";
    const comment = std.mem.sliceTo(&entity.comment, 0);
    const hint = firstCommentLine(comment);
    if (hint.len == 0) {
        return std.fmt.bufPrintZ(buf, "#{d} {s}", .{ idx, name });
    }
    return std.fmt.bufPrintZ(buf, "#{d} {s}  - {s}", .{ idx, name, hint });
}

/// Return the first non-empty, comment-marker-stripped line from a
/// captured comment block, capped to 60 chars so a long block doesn't
/// blow the row layout. Returns an empty slice when nothing useful
/// survives the trim. Pub so `tests.zig` can exercise without imgui.
pub fn firstCommentLine(comment: []const u8) []const u8 {
    var it = std.mem.splitScalar(u8, comment, '\n');
    while (it.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        // Strip the `//` marker and any leading whitespace after it.
        if (std.mem.startsWith(u8, line, "//")) line = std.mem.trim(u8, line[2..], " \t\r");
        if (line.len == 0) continue;
        if (line.len > 60) {
            // Walk back while byte at `limit` is a UTF-8 continuation
            // byte (top bits 10xxxxxx) so we never slice mid-codepoint
            // — ImGui chokes on invalid UTF-8 and shows tofu/glitches.
            var limit: usize = 60;
            while (limit > 0 and (line[limit] & 0xC0) == 0x80) : (limit -= 1) {}
            return line[0..limit];
        }
        return line;
    }
    return &.{};
}

/// Case-insensitive substring match. Iterates the haystack once
/// matching against `needle`; cheap on the scale of a hierarchy
/// panel (hundreds of entries) without pulling in a regex engine.
/// Pub so `tests.zig` can exercise without imgui.
pub fn matchesFilter(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const a = std.ascii.toLower(haystack[i + j]);
            const b = std.ascii.toLower(needle[j]);
            if (a != b) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

