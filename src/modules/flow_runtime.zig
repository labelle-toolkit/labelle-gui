//! Flow Runtime panel (issue #84, Phase 3 editor side).
//!
//! Minimal UI for managing per-flow `subscribe_flow` state during a
//! preview session. Phase 3 MVP scope: the user types a flow name and
//! clicks Subscribe / Unsubscribe; the engine then streams
//! `node_entered` frames for that flow until the editor sends
//! `unsubscribe_flow` (or the session closes).
//!
//! Real flow discovery — listing flows referenced by the active scene,
//! pulling the live list from the engine — is a Phase 3+ polish. The
//! issue calls it out as "design TBD" so the MVP punts to typed input.
//!
//! The panel ALSO renders a short log of the last few `node_entered`
//! frames the session has received. That's the user-visible signal that
//! the wiring is live even when no flow editor tab is open; the
//! "pulse the node in the flow canvas" step runs in parallel inside
//! `modules/flow.zig`.

const std = @import("std");
const zgui = @import("zgui");

const App = @import("../app.zig").App;
const module = @import("../module.zig");
const preview = @import("../preview.zig");

const max_log_entries: usize = 16;
const max_flow_name_bytes: usize = 96;

pub const LogEntry = struct {
    flow_name: [max_flow_name_bytes]u8 = [_]u8{0} ** max_flow_name_bytes,
    flow_name_len: usize = 0,
    node_id: u32 = 0,
};

pub const FlowRuntime = struct {
    /// Input buffer for the "Subscribe to ..." form.
    flow_name_input: [max_flow_name_bytes:0]u8 = [_:0]u8{0} ** max_flow_name_bytes,
    /// Names the editor has subscribed to in the current session.
    /// Sized for a handful of flows — preview's typical workload is
    /// one or two flows under observation at once.
    subscribed: std.ArrayListUnmanaged([]u8) = .{},
    /// Rolling log of recent `node_entered` arrivals — newest at index
    /// `log_head - 1 (mod max)`. Drawn as a small read-only window so
    /// the user can see frames arriving even without a flow tab open.
    log: [max_log_entries]LogEntry = [_]LogEntry{.{}} ** max_log_entries,
    log_count: usize = 0,
    log_head: usize = 0,

    pub fn deinit(self: *FlowRuntime, allocator: std.mem.Allocator) void {
        for (self.subscribed.items) |name| allocator.free(name);
        self.subscribed.deinit(allocator);
    }

    /// Wire-arrival handler. Pushes one entry into the ring buffer.
    /// The flow editor's `pulseNode` (wired separately in app.zig) is
    /// the visible "highlight the node" path; this panel's log is the
    /// fallback / debug surface.
    pub fn onNodeEntered(self: *FlowRuntime, flow_name: []const u8, node_id: u32) void {
        const slot = self.log_head;
        const n = @min(flow_name.len, max_flow_name_bytes);
        self.log[slot] = .{};
        @memcpy(self.log[slot].flow_name[0..n], flow_name[0..n]);
        self.log[slot].flow_name_len = n;
        self.log[slot].node_id = node_id;
        self.log_head = (self.log_head + 1) % max_log_entries;
        if (self.log_count < max_log_entries) self.log_count += 1;
    }

    pub fn isSubscribed(self: *const FlowRuntime, flow_name: []const u8) bool {
        for (self.subscribed.items) |n| {
            if (std.mem.eql(u8, n, flow_name)) return true;
        }
        return false;
    }

    pub fn subscribe(self: *FlowRuntime, allocator: std.mem.Allocator, session: *preview.PreviewSession, flow_name: []const u8) !void {
        if (self.isSubscribed(flow_name)) return;
        // Wire write first. If it fails, local state is unchanged —
        // the engine isn't subscribed so keeping `subscribed` clean is
        // the correct consistent view (and avoids the dangling-pointer
        // risk of freeing `owned` via errdefer after it's been appended).
        try session.subscribeFlow(flow_name);
        const owned = try allocator.dupe(u8, flow_name);
        errdefer allocator.free(owned);
        try self.subscribed.append(allocator, owned);
    }

    pub fn unsubscribe(self: *FlowRuntime, allocator: std.mem.Allocator, session: *preview.PreviewSession, flow_name: []const u8) !void {
        // Send the wire frame first. If it fails, leave local state
        // unchanged — the engine is still subscribed, so keeping the
        // name in `subscribed` is the correct consistent view.
        try session.unsubscribeFlow(flow_name);
        for (self.subscribed.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, flow_name)) {
                allocator.free(n);
                _ = self.subscribed.orderedRemove(i);
                break;
            }
        }
    }
};

pub fn makeModule(app: *App) module.Module {
    return .{
        .name = "flow_runtime",
        .display_name = "Flow Runtime",
        .is_open = &app.show_flow_runtime,
        .render_panel = render,
    };
}

fn render(app: *App) void {
    if (!zgui.begin("Flow Runtime", .{
        .popen = &app.show_flow_runtime,
        .flags = .{ .always_auto_resize = true },
    })) {
        zgui.end();
        return;
    }
    defer zgui.end();

    const rt = &app.flow_runtime;
    const can_act = app.preview.isActive();

    if (!can_act) {
        zgui.textDisabled("Preview is not running. Start a preview to subscribe to flows.", .{});
    }

    zgui.text("Subscribe to flow:", .{});
    _ = zgui.inputText("##flow_runtime_input", .{
        .buf = &rt.flow_name_input,
    });
    zgui.sameLine(.{});

    const input_slice = std.mem.sliceTo(&rt.flow_name_input, 0);
    const subscribe_label = if (rt.isSubscribed(input_slice)) "Unsubscribe" else "Subscribe";
    if (zgui.button(subscribe_label, .{ .w = 110 })) {
        if (can_act and input_slice.len > 0) {
            if (rt.isSubscribed(input_slice)) {
                rt.unsubscribe(app.allocator, &app.preview, input_slice) catch |err| {
                    std.log.warn("flow_runtime: unsubscribe failed: {s}", .{@errorName(err)});
                };
            } else {
                rt.subscribe(app.allocator, &app.preview, input_slice) catch |err| {
                    std.log.warn("flow_runtime: subscribe failed: {s}", .{@errorName(err)});
                };
            }
        }
    }

    zgui.separator();
    zgui.text("Subscribed flows:", .{});
    if (rt.subscribed.items.len == 0) {
        zgui.textDisabled("  (none)", .{});
    } else {
        for (rt.subscribed.items) |name| {
            zgui.bulletText("{s}", .{name});
        }
    }

    zgui.separator();
    zgui.text("Recent node_entered frames:", .{});
    if (rt.log_count == 0) {
        zgui.textDisabled("  (none yet)", .{});
        return;
    }
    // Walk the ring oldest-to-newest. `log_head` points at the next
    // write slot, so the oldest live entry is `log_head - log_count
    // (mod max)`.
    var i: usize = 0;
    while (i < rt.log_count) : (i += 1) {
        const idx = (rt.log_head + max_log_entries - rt.log_count + i) % max_log_entries;
        const e = rt.log[idx];
        zgui.bulletText("{s}  node #{d}", .{ e.flow_name[0..e.flow_name_len], e.node_id });
    }
}
