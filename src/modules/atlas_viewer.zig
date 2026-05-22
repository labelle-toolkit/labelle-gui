//! Atlas Viewer panel — inspect packed sprite atlases (labelle-gui#148).
//!
//! Shows the project's atlases (live from `App.atlas_index`) plus any
//! atlas packed-and-opened during this session. For the selected atlas
//! it renders the sheet with per-frame rect overlays, a sprite list,
//! and a detail readout (rect, pivot, trim, source size) for the
//! selected sprite.
//!
//! "Pack folder…" shells out to `labelle pack` — the same subprocess
//! pattern `compiler.zig` uses for `labelle build`/`run` — then loads
//! the resulting `.atlas.png`/`.json` pair into the viewer.

const std = @import("std");
const zgui = @import("zgui");
const nfd = @import("nfd");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const atlas = @import("../atlas.zig");
const io_global = @import("../io_global.zig");

/// Panel-local state. One instance lives on `App`.
pub const AtlasViewer = struct {
    /// Atlases opened outside the project (packed-and-viewed sheets).
    /// Project atlases are read live from `App.atlas_index`.
    loaded: std.ArrayListUnmanaged(atlas.Atlas) = .empty,
    /// Index into the combined list: project atlases, then `loaded`.
    selected: usize = 0,
    /// `ProjectManager.generation` the `selected` index was last valid
    /// against. When the project changes, the index points into a
    /// different atlas set, so we reset selection + sprite.
    last_generation: ?u64 = null,
    /// Selected sprite — a frame key in the current atlas.
    sprite_buf: [512]u8 = undefined,
    sprite_len: usize = 0,
    /// Pixels-per-texel for the sheet view.
    zoom: f32 = 1.0,
    /// Last pack/open result line.
    status_buf: [256]u8 = undefined,
    status_len: usize = 0,
    status_ok: bool = true,

    pub fn deinit(self: *AtlasViewer, allocator: std.mem.Allocator) void {
        for (self.loaded.items) |*a| a.deinit(allocator);
        self.loaded.deinit(allocator);
    }

    fn selectedSprite(self: *const AtlasViewer) []const u8 {
        return self.sprite_buf[0..self.sprite_len];
    }
    fn setSprite(self: *AtlasViewer, name: []const u8) void {
        const n = @min(name.len, self.sprite_buf.len);
        @memcpy(self.sprite_buf[0..n], name[0..n]);
        self.sprite_len = n;
    }
    fn setStatus(self: *AtlasViewer, ok: bool, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch self.status_buf[0..0];
        self.status_len = s.len;
        self.status_ok = ok;
    }
    fn clearSprite(self: *AtlasViewer) void {
        self.sprite_len = 0;
    }
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "atlas_viewer",
        .display_name = "Atlas Viewer",
        .is_open = &app.show_atlas_viewer,
        .render_panel = render,
        .on_deinit = onDeinit,
    };
}

fn onDeinit(app: *App) void {
    app.atlas_viewer.deinit(app.allocator);
}

fn atlasAt(project: []const atlas.Atlas, loaded: []const atlas.Atlas, idx: usize) *const atlas.Atlas {
    return if (idx < project.len) &project[idx] else &loaded[idx - project.len];
}

fn render(app: *App) void {
    if (!zgui.begin("Atlas Viewer", .{ .popen = &app.show_atlas_viewer })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const v = &app.atlas_viewer;

    // Project transitions re-key `App.atlas_index`; the `selected`
    // index then points into a different atlas set (or a now-shorter
    // list). Reset selection + sprite when the generation changes so
    // the viewer never shows an unintended atlas/sprite.
    const generation = app.project_manager.generation;
    if (v.last_generation != generation) {
        v.last_generation = generation;
        v.selected = 0;
        v.clearSprite();
    }

    // ── Toolbar ──────────────────────────────────────────────────
    if (zgui.button("Pack folder...", .{})) packFolder(app);
    if (v.status_len > 0) {
        zgui.sameLine(.{});
        const col: [4]f32 = if (v.status_ok) .{ 0.6, 1.0, 0.6, 1.0 } else .{ 1.0, 0.5, 0.5, 1.0 };
        zgui.textColored(col, "{s}", .{v.status_buf[0..v.status_len]});
    }
    zgui.separator();

    const project_atlases: []const atlas.Atlas =
        if (app.atlas_index) |*idx| idx.atlases.items else &.{};
    const total = project_atlases.len + v.loaded.items.len;
    if (total == 0) {
        zgui.textDisabled("No atlases. Open a project with atlas resources, or pack a folder.", .{});
        return;
    }
    if (v.selected >= total) {
        v.selected = 0;
        v.clearSprite();
    }

    // ── Atlas picker + zoom ──────────────────────────────────────
    // Resolve `cur` *after* the picker buttons so the header name,
    // index, dimensions and sprite list all reflect the same atlas.
    if (zgui.button("<", .{})) {
        v.selected = (v.selected + total - 1) % total;
        v.clearSprite();
    }
    zgui.sameLine(.{});
    if (zgui.button(">", .{})) {
        v.selected = (v.selected + 1) % total;
        v.clearSprite();
    }
    zgui.sameLine(.{});
    const cur = atlasAt(project_atlases, v.loaded.items, v.selected);
    const origin_tag: []const u8 = if (v.selected < project_atlases.len) "project" else "packed";
    zgui.text("{s}  ({d}/{d}, {s})", .{ cur.name, v.selected + 1, total, origin_tag });

    zgui.sameLine(.{});
    zgui.text("   |   {d}x{d}, {d} sprites", .{ cur.width, cur.height, cur.frames.count() });

    zgui.sameLine(.{});
    if (zgui.button("-", .{ .w = 26 })) v.zoom = @max(0.1, v.zoom * 0.8);
    zgui.sameLine(.{});
    zgui.text("{d:.2}x", .{v.zoom});
    zgui.sameLine(.{});
    if (zgui.button("+", .{ .w = 26 })) v.zoom = @min(16.0, v.zoom * 1.25);
    zgui.separator();

    // ── Split: sprite list + detail | sheet ──────────────────────
    _ = zgui.beginChild("##atlas-left", .{ .w = 240, .child_flags = .{ .border = true } });
    renderSpriteList(app, v, cur);
    zgui.endChild();

    zgui.sameLine(.{});

    _ = zgui.beginChild("##atlas-right", .{ .child_flags = .{ .border = true } });
    renderSheet(v, cur);
    zgui.endChild();
}

/// Left column: scrollable sprite list (upper) + selected-sprite
/// detail (lower).
fn renderSpriteList(app: *App, v: *AtlasViewer, cur: *const atlas.Atlas) void {
    // Sorted frame names — hash-map order is otherwise arbitrary.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(app.allocator);
    {
        var it = cur.frames.iterator();
        while (it.next()) |kv| names.append(app.allocator, kv.key_ptr.*) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, lessName);

    const detail_h: f32 = 140;
    _ = zgui.beginChild("##sprite-list", .{ .h = -detail_h });
    var lbl: [544]u8 = undefined;
    for (names.items) |name| {
        const selected = std.mem.eql(u8, name, v.selectedSprite());
        const z = std.fmt.bufPrintZ(&lbl, "{s}", .{name}) catch continue;
        if (zgui.selectable(z, .{ .selected = selected })) v.setSprite(name);
    }
    zgui.endChild();

    zgui.separator();

    // Detail readout for the selected sprite.
    if (cur.frames.get(v.selectedSprite())) |f| {
        zgui.textWrapped("{s}", .{v.selectedSprite()});
        zgui.text("rect:   {d}, {d}  {d}x{d}", .{ f.x, f.y, f.w, f.h });
        zgui.text("pivot:  {d:.3}, {d:.3}", .{ f.pivot[0], f.pivot[1] });
        zgui.text("source: {d}x{d}", .{ f.source_w, f.source_h });
        zgui.text("offset: {d}, {d}", .{ f.offset_x, f.offset_y });
        zgui.text("rotated: {}   trimmed: {}", .{ f.rotated, f.trimmed });
    } else {
        zgui.textDisabled("No sprite selected", .{});
    }
}

/// Right column: the atlas sheet with per-frame rect overlays. Clicking
/// inside a frame selects that sprite.
fn renderSheet(v: *AtlasViewer, cur: *const atlas.Atlas) void {
    if (cur.texture_id == 0) {
        zgui.textDisabled("Atlas has no texture", .{});
        return;
    }
    const tw: f32 = @floatFromInt(cur.width);
    const th: f32 = @floatFromInt(cur.height);
    const sheet_w = tw * v.zoom;
    const sheet_h = th * v.zoom;

    const origin = zgui.getCursorScreenPos();
    const dl = zgui.getWindowDrawList();
    // Dark backing so transparent regions read as empty, not as the
    // window background.
    dl.addRectFilled(.{
        .pmin = origin,
        .pmax = .{ origin[0] + sheet_w, origin[1] + sheet_h },
        .col = 0xff_1a_1a_1a,
    });

    const tex_ref: zgui.TextureRef = .{
        .tex_data = null,
        .tex_id = @enumFromInt(@as(u64, cur.texture_id)),
    };
    zgui.image(tex_ref, .{ .w = sheet_w, .h = sheet_h });

    // Click-to-select: map the click to a texel, hit-test the frames.
    if (zgui.isItemHovered(.{}) and zgui.isMouseClicked(.left)) {
        const mp = zgui.getMousePos();
        const tx = (mp[0] - origin[0]) / v.zoom;
        const ty = (mp[1] - origin[1]) / v.zoom;
        var it = cur.frames.iterator();
        while (it.next()) |kv| {
            const f = kv.value_ptr.*;
            const fx: f32 = @floatFromInt(f.x);
            const fy: f32 = @floatFromInt(f.y);
            if (tx >= fx and ty >= fy and
                tx < fx + @as(f32, @floatFromInt(f.w)) and
                ty < fy + @as(f32, @floatFromInt(f.h)))
            {
                v.setSprite(kv.key_ptr.*);
                break;
            }
        }
    }

    // Frame outlines; the selected frame gets a bright, thicker box.
    var it = cur.frames.iterator();
    while (it.next()) |kv| {
        const f = kv.value_ptr.*;
        const selected = std.mem.eql(u8, kv.key_ptr.*, v.selectedSprite());
        const pmin: [2]f32 = .{
            origin[0] + @as(f32, @floatFromInt(f.x)) * v.zoom,
            origin[1] + @as(f32, @floatFromInt(f.y)) * v.zoom,
        };
        const pmax: [2]f32 = .{
            pmin[0] + @as(f32, @floatFromInt(f.w)) * v.zoom,
            pmin[1] + @as(f32, @floatFromInt(f.h)) * v.zoom,
        };
        dl.addRect(.{
            .pmin = pmin,
            .pmax = pmax,
            .col = if (selected) 0xff_40_d2_ff else 0x60_ff_ff_ff,
            .thickness = if (selected) 2.0 else 1.0,
        });
    }
}

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Pick a folder, run `labelle pack` on it, and load the result.
fn packFolder(app: *App) void {
    const v = &app.atlas_viewer;

    const maybe = nfd.openFolderDialog(null) catch {
        v.setStatus(false, "folder dialog failed", .{});
        return;
    };
    const folder = maybe orelse return;
    defer nfd.freePath(folder);

    const name = std.fs.path.basename(folder);
    if (name.len == 0) {
        v.setStatus(false, "could not derive an atlas name from the folder", .{});
        return;
    }

    const result = std.process.run(app.allocator, io_global.io(), .{
        .argv = &.{ "labelle", "pack", folder, "-o", name, "--out-dir", folder },
    }) catch |err| {
        v.setStatus(false, "labelle pack failed to launch: {s}", .{@errorName(err)});
        return;
    };
    defer app.allocator.free(result.stdout);
    defer app.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        v.setStatus(false, "labelle pack failed (see terminal)", .{});
        return;
    }

    const json_name = std.fmt.allocPrint(app.allocator, "{s}.atlas.json", .{name}) catch {
        v.setStatus(false, "packed ok, but out of memory building the atlas path", .{});
        return;
    };
    defer app.allocator.free(json_name);
    const json_path = std.fs.path.join(app.allocator, &.{ folder, json_name }) catch {
        v.setStatus(false, "packed ok, but out of memory building the atlas path", .{});
        return;
    };
    defer app.allocator.free(json_path);

    const png_name = std.fmt.allocPrint(app.allocator, "{s}.atlas.png", .{name}) catch {
        v.setStatus(false, "packed ok, but out of memory building the atlas path", .{});
        return;
    };
    defer app.allocator.free(png_name);
    const png_path = std.fs.path.join(app.allocator, &.{ folder, png_name }) catch {
        v.setStatus(false, "packed ok, but out of memory building the atlas path", .{});
        return;
    };
    defer app.allocator.free(png_path);

    var loaded = atlas.loadFromPaths(app.allocator, name, json_path, png_path) catch |err| {
        v.setStatus(false, "packed ok, but loading the atlas failed: {s}", .{@errorName(err)});
        return;
    };
    const sprite_count = loaded.frames.count();

    // Re-packing the same folder must not accumulate duplicate atlases
    // (and leak their GL textures). Replace any prior `loaded` entry
    // with the same name in place.
    var replaced = false;
    for (v.loaded.items) |*existing| {
        if (std.mem.eql(u8, existing.name, name)) {
            existing.deinit(app.allocator);
            existing.* = loaded;
            replaced = true;
            break;
        }
    }
    if (!replaced) {
        v.loaded.append(app.allocator, loaded) catch {
            loaded.deinit(app.allocator);
            v.setStatus(false, "out of memory", .{});
            return;
        };
    }

    // Select the freshly packed atlas. After a replace its slot is
    // unchanged; locate it so the index is correct either way.
    const project_count = if (app.atlas_index) |*idx| idx.atlases.items.len else 0;
    for (v.loaded.items, 0..) |*a, i| {
        if (std.mem.eql(u8, a.name, name)) {
            v.selected = project_count + i;
            break;
        }
    }
    v.clearSprite();
    v.setStatus(true, "packed '{s}' — {d} sprites", .{ name, sprite_count });
}
