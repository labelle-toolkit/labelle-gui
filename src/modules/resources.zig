//! Resources panel — edits `ProjectConfig.resources` (the sprite-atlas
//! manifest the engine consumes through generated `main.zig`).
//!
//! Each row carries its own sentinel-terminated edit buffers because
//! `zgui.inputText` writes in place. Buffers re-sync from the live
//! config whenever the active project pointer changes. Save dupes
//! buffers back into `Project.arena` and replaces `proj.config.resources`
//! with a fresh slice; old slices stay in the arena until project
//! close (arena leak is bounded — same model as Project Settings).
//!
//! Row count is capped at `max_slots` — the editor is for hand-curated
//! atlases, not a thousand-entry dataset. Bump the constant when a real
//! user runs into the cap.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const project = @import("../project.zig");
const buf = @import("../buf.zig");
const atlas = @import("../atlas.zig");
const atlas_ui = @import("../atlas_ui.zig");

/// Edge length (px) of the per-sprite thumbnail buttons rendered under
/// each resource row.
const thumb_size: f32 = 40;

const max_slots = 32;
const name_cap = 64;
const path_cap = 256;

const Slot = struct {
    name: [name_cap:0]u8 = [_:0]u8{0} ** name_cap,
    json: [path_cap:0]u8 = [_:0]u8{0} ** path_cap,
    texture: [path_cap:0]u8 = [_:0]u8{0} ** path_cap,
};

pub const ResourcesEditor = struct {
    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    count: usize = 0,
    /// `ProjectManager.generation` at the time the slots were filled.
    /// Compared to detect project transitions — using a counter rather
    /// than a `*Project` pointer side-steps the ABA case where GPA
    /// reuses an address across close/new cycles.
    last_generation: ?u64 = null,
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "resources",
        .display_name = "Resources",
        .is_open = &app.show_resources,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Resources", .{
        .popen = &app.show_resources,
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const proj = app.project_manager.current_project orelse {
        zgui.textDisabled("No project open", .{});
        return;
    };

    syncIfNeeded(&app.resources_editor, app.project_manager.generation, proj);
    const ed = &app.resources_editor;

    if (ed.count == 0) {
        zgui.textDisabled("No resources. Click Add to create one.", .{});
    }

    var i: usize = 0;
    var remove_idx: ?usize = null;
    while (i < ed.count) : (i += 1) {
        // String IDs (rather than pushIntId) so ImGui Test Engine refs
        // like "Resources/row0/name" resolve cleanly to a row's inputs.
        var id_buf: [16:0]u8 = undefined;
        const row_id = std.fmt.bufPrintZ(&id_buf, "row{d}", .{i}) catch "row?";
        zgui.pushStrIdZ(row_id);
        defer zgui.popId();

        zgui.separator();
        _ = zgui.inputText("name", .{ .buf = &ed.slots[i].name });
        _ = zgui.inputText("json", .{ .buf = &ed.slots[i].json });
        _ = zgui.inputText("texture", .{ .buf = &ed.slots[i].texture });
        renderThumbnails(app, bufStr(&ed.slots[i].name));
        if (zgui.button("Remove", .{ .w = 80 })) remove_idx = i;
    }
    if (remove_idx) |idx| removeAt(ed, idx);

    zgui.separator();
    if (zgui.button("Add", .{ .w = 80 })) addSlot(ed);
    zgui.sameLine(.{});
    if (zgui.button("Save", .{ .w = 80 })) saveAndPersist(app, proj);
    zgui.sameLine(.{});
    if (zgui.button("Revert", .{ .w = 80 })) {
        ed.last_generation = null; // resync next frame
    }
}

/// Render a row of sprite-frame thumbnails for the atlas whose
/// `resources[].name` equals `res_name`. Uses `atlas_ui.spriteButtonFrame`,
/// which draws the real atlas frame and falls back to a text button
/// when the frame can't be resolved.
///
/// Thumbnails are interactive `imageButton`s: clicking one copies the
/// sprite name onto the status bar — a contained first use that the
/// inspector's sprite-picker follow-up can build on. No-ops silently
/// when no atlas index is built yet or the row's name matches no
/// loaded atlas (e.g. an unsaved row, or a JSON that failed to load).
fn renderThumbnails(app: *App, res_name: []const u8) void {
    if (res_name.len == 0) return;
    const idx = if (app.atlas_index) |*p| p else return;

    // Locate the atlas this row's name refers to.
    const a: *const atlas.Atlas = blk: {
        for (idx.atlases.items) |*at| {
            if (std.mem.eql(u8, at.name, res_name)) break :blk at;
        }
        return; // not loaded (unsaved row, or failed JSON)
    };
    if (a.frames.count() == 0) return;

    // Wrap thumbnails to the panel width. Spacing comes from the live
    // ImGui style so the grid tracks theme / HiDPI changes.
    const avail_w = zgui.getContentRegionAvail()[0];
    const style_spacing = zgui.getStyle().item_spacing[0];
    const per_row: usize = @max(1, @as(usize, @intFromFloat(
        avail_w / (thumb_size + style_spacing),
    )));

    // Collect + sort the sprite names so thumbnails render in a
    // stable order — `StringHashMap` iteration order is not
    // deterministic, which would otherwise reshuffle the grid on
    // every atlas reload.
    var names = std.ArrayList([]const u8).initCapacity(app.allocator, a.frames.count()) catch return;
    defer names.deinit(app.allocator);
    var kit = a.frames.keyIterator();
    while (kit.next()) |k| names.appendAssumeCapacity(k.*);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);

    for (names.items, 0..) |sprite_name, shown| {
        const frame = a.frames.get(sprite_name) orelse continue;
        // Scope each thumbnail's imgui ID by sprite name — the row is
        // already inside its own `pushStrIdZ` scope, so this is unique
        // and avoids formatting a fresh string id every frame.
        zgui.pushStrId(sprite_name);
        defer zgui.popId();

        if (shown % per_row != 0) zgui.sameLine(.{});
        // Resolve against this row's atlas directly: a sprite name
        // shared with another atlas must draw *this* atlas's frame.
        if (atlas_ui.spriteButtonFrame("##thumb", a, sprite_name, frame, thumb_size, thumb_size)) {
            var status_buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrint(
                &status_buf,
                "Sprite: {s}",
                .{sprite_name},
            ) catch sprite_name;
            app.setStatus(msg);
        }
        if (zgui.isItemHovered(.{}) and zgui.beginTooltip()) {
            zgui.text("{s}", .{sprite_name});
            zgui.endTooltip();
        }
    }
}

fn syncIfNeeded(ed: *ResourcesEditor, gen: u64, proj: *project.Project) void {
    if (ed.last_generation) |g| {
        if (g == gen) return;
    }
    ed.count = @min(proj.config.resources.len, max_slots);
    for (proj.config.resources[0..ed.count], 0..) |r, i| {
        buf.writeZeroed(&ed.slots[i].name, r.name);
        buf.writeZeroed(&ed.slots[i].json, r.json);
        buf.writeZeroed(&ed.slots[i].texture, r.texture);
    }
    // Clear any leftover rows from a previous project so stale buffers
    // don't show up if the new project has fewer resources.
    var k = ed.count;
    while (k < max_slots) : (k += 1) ed.slots[k] = .{};
    ed.last_generation = gen;
}

fn addSlot(ed: *ResourcesEditor) void {
    if (ed.count >= max_slots) return;
    ed.slots[ed.count] = .{};
    ed.count += 1;
}

fn removeAt(ed: *ResourcesEditor, idx: usize) void {
    if (idx >= ed.count) return;
    // Shift later slots down; explicit copy keeps buffer contents
    // (each Slot is a value).
    var i = idx;
    while (i + 1 < ed.count) : (i += 1) ed.slots[i] = ed.slots[i + 1];
    ed.slots[ed.count - 1] = .{};
    ed.count -= 1;
}

fn saveAndPersist(app: *App, proj: *project.Project) void {
    applyBuffers(app, proj) catch |err| {
        std.log.err("Resources: apply failed: {s}", .{@errorName(err)});
        app.setStatus("Error applying resources!");
        return;
    };
    const dir = proj.dir orelse {
        app.setStatus("Project has no path — use Save As first");
        return;
    };
    app.project_manager.saveProject(dir) catch |err| {
        std.log.err("Resources: save failed: {s}", .{@errorName(err)});
        app.setStatus("Error saving project!");
        return;
    };
    app.setStatus("Resources saved!");
}

fn applyBuffers(app: *App, proj: *project.Project) !void {
    const a = proj.arena.allocator();
    const ed = &app.resources_editor;

    const resources = try a.alloc(project.ResourceDef, ed.count);
    for (resources, 0..) |*dst, i| {
        dst.* = .{
            .name = try a.dupe(u8, bufStr(&ed.slots[i].name)),
            .json = try a.dupe(u8, bufStr(&ed.slots[i].json)),
            .texture = try a.dupe(u8, bufStr(&ed.slots[i].texture)),
        };
    }
    proj.config.resources = resources;
    proj.markDirty();
}

fn bufStr(slice: []const u8) []const u8 {
    return std.mem.sliceTo(slice, 0);
}
