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
