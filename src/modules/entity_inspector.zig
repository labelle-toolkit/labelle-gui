//! Entity Inspector panel (issue #84, Phase 3 editor side).
//!
//! Reflects the live state of one watched entity over the preview
//! channel. Workflow:
//!
//!   1. Editor calls `onEntitySelected(entity_id)` — the panel sends
//!      `{"kind":"watch_entity","id":<id>}` to the engine and clears
//!      its component table.
//!   2. Engine emits one `component_changed` per currently-tracked
//!      component on that entity (the one-shot snapshot fan-out from
//!      `Preview.emitEntitySnapshot`).
//!   3. As mutations land, the engine streams more `component_changed`
//!      frames. The panel's `onComponentChanged` callback (wired from
//!      `PreviewSession.on_component_changed`) writes each one into the
//!      table, replacing any previous value for that name.
//!   4. `onEntityDeselected()` sends `unwatch_entity` and drops the
//!      table.
//!
//! Rendering is intentionally minimal for the MVP: one ImGui line per
//! component showing the raw bytes as hex. A typed renderer per
//! component (matching `modules/inspector.zig`'s typed sections) is the
//! Phase 4 follow-up — the wire shape is already enough to drive it.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const preview = @import("../preview.zig");

/// Entries are heap-allocated `[]u8` so the panel survives the
/// per-frame parse arena teardown on the `PreviewSession` side. Keys
/// are also owned (dup'd from the wire-borrowed `comp_name`).
pub const EntityInspector = struct {
    allocator: std.mem.Allocator,
    /// Currently-watched entity id. `null` means no selection. Setting
    /// this to a new id from outside still requires going through
    /// `onEntitySelected` so the engine gets the matching protocol
    /// frame.
    watched_entity: ?u64 = null,
    /// Component name → last-known raw bytes. Both key and value are
    /// owned by `allocator`; cleared on selection change / deinit.
    components: std.StringHashMap([]u8),
    /// Back-pointer to the preview session. Stored so the inspector
    /// can talk back to the engine (`watch_entity`/`unwatch_entity`)
    /// without threading the App through every call site.
    session: *preview.PreviewSession,

    pub fn init(allocator: std.mem.Allocator, session: *preview.PreviewSession) EntityInspector {
        return .{
            .allocator = allocator,
            .components = std.StringHashMap([]u8).init(allocator),
            .session = session,
        };
    }

    pub fn deinit(self: *EntityInspector) void {
        self.clearComponents();
        self.components.deinit();
    }

    /// Mark `entity_id` as the one we want to track. Sends the
    /// `watch_entity` JSON frame on the wire so the engine starts
    /// emitting filtered `component_changed`. Previous selection is
    /// `unwatch_entity`'d so the engine isn't left tracking a stale
    /// id.
    pub fn onEntitySelected(self: *EntityInspector, entity_id: u64) !void {
        if (self.watched_entity) |prev| {
            // Best-effort — if the wire is gone, dropping the unwatch
            // is harmless (the engine state goes away with the
            // session).
            self.session.unwatchEntity(prev) catch {};
        }
        self.clearComponents();
        // Set watched_entity only after the wire write succeeds so the
        // inspector never believes it is watching an entity the engine
        // never heard about (which would silently drop every subsequent
        // component_changed frame for that entity).
        self.watched_entity = null;
        try self.session.watchEntity(entity_id);
        self.watched_entity = entity_id;
    }

    /// Clear selection and tell the engine to stop emitting filtered
    /// frames for the previously-watched entity.
    pub fn onEntityDeselected(self: *EntityInspector) void {
        if (self.watched_entity) |id| {
            self.session.unwatchEntity(id) catch {};
        }
        self.watched_entity = null;
        self.clearComponents();
    }

    /// Wire-arrival handler. Drops frames for entities other than the
    /// one we asked to watch — the engine's filter already does this
    /// when `watched_entities` is non-empty, but the editor guards as
    /// well so a stale frame (sent before the engine processed an
    /// `unwatch_entity`) can't pollute the panel.
    pub fn onComponentChanged(self: *EntityInspector, entity_id: u64, name: []const u8, bytes: []const u8) void {
        const watched = self.watched_entity orelse return;
        if (watched != entity_id) return;

        const owned_bytes = self.allocator.dupe(u8, bytes) catch return;

        const gop = self.components.getOrPut(name) catch {
            self.allocator.free(owned_bytes);
            return;
        };
        if (gop.found_existing) {
            // Replace the old bytes in place; key stays the same.
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = owned_bytes;
        } else {
            // First time we see this component — dup the name so the
            // hashmap doesn't dangle when the engine's wire buffer
            // gets reused.
            const owned_name = self.allocator.dupe(u8, name) catch {
                self.allocator.free(owned_bytes);
                _ = self.components.remove(name);
                return;
            };
            gop.key_ptr.* = owned_name;
            gop.value_ptr.* = owned_bytes;
        }
    }

    fn clearComponents(self: *EntityInspector) void {
        var it = self.components.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.components.clearRetainingCapacity();
    }
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "entity_inspector",
        .display_name = "Entity Inspector",
        .is_open = &app.show_entity_inspector,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Entity Inspector", .{
        .popen = &app.show_entity_inspector,
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const insp = &app.entity_inspector;

    if (insp.watched_entity) |id| {
        zgui.text("Watching entity #{d}", .{id});
        if (zgui.button("Stop watching##entity_inspector_stop", .{})) {
            insp.onEntityDeselected();
        }
    } else {
        zgui.textDisabled("No entity selected. Click an entity in the scene viewport to watch live values.", .{});
        return;
    }

    zgui.separator();

    if (insp.components.count() == 0) {
        zgui.textDisabled("Awaiting first component snapshot...", .{});
        return;
    }

    var it = insp.components.iterator();
    while (it.next()) |entry| {
        renderComponentRow(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn renderComponentRow(name: []const u8, bytes: []const u8) void {
    zgui.text("{s}", .{name});
    // Hex dump — typed rendering is a Phase 4 follow-up. Cap the
    // display at 64 bytes so a fat blob doesn't blow out the panel.
    const max_show: usize = 64;
    var hex_buf: [3 * max_show + 8]u8 = undefined;
    const limit = @min(bytes.len, max_show);
    var written: usize = 0;
    for (bytes[0..limit], 0..) |b, i| {
        if (i > 0) {
            hex_buf[written] = ' ';
            written += 1;
        }
        const slice = std.fmt.bufPrint(hex_buf[written..], "{x:0>2}", .{b}) catch break;
        written += slice.len;
    }
    if (bytes.len > limit) {
        const tail = " ...";
        if (written + tail.len <= hex_buf.len) {
            @memcpy(hex_buf[written..][0..tail.len], tail);
            written += tail.len;
        }
    }
    zgui.indent(.{});
    zgui.textDisabled("{s}", .{hex_buf[0..written]});
    zgui.unindent(.{});
}
