//! Preview-mode session — stubbed for Zig 0.16 migration.
//!
//! The original preview module used `std.net.Server` with
//! `force_nonblocking`, `std.process.Child` async stdio drains, and
//! `std.time.milliTimestamp` — all reshaped in Zig 0.16 such that a
//! full rewrite is needed. To unblock the rest of the migration we
//! keep the public API surface (so `App`, `modules/preview.zig`, and
//! `gui_tests.zig` still compile) but make every operation a no-op
//! that lands in `crashed` with a "preview disabled" reason.
//!
//! TODO: restore real preview behavior on top of `std.Io.net.Server`
//! (blocking accept under a background thread, or a poll-based
//! integration via the new `Io` cancellation handles) and
//! `std.process.spawn` with manually drained pipes. The state machine
//! shape can stay identical to the pre-rebase HEAD design — only the
//! transport plumbing changes.

const std = @import("std");
const builtin = @import("builtin");
const project = @import("project.zig");

/// Lifecycle of one preview session. Strictly monotonic except for the
/// terminal `stopped`/`crashed` → `idle` reset that `stop()` does so the
/// user can press Run again.
pub const State = enum {
    idle,
    listening,
    connecting,
    running,
    crashed,
    stopped,
};

pub const PreviewError = error{
    NoProjectPath,
    LauncherNotFound,
    ListenFailed,
    AlreadyRunning,
    OutOfMemory,
};

pub const Hello = struct {
    engine_version: ?[]u8 = null,
    pid: ?i64 = null,
    protocol_version: ?i64 = null,
};

pub const Heartbeat = struct {
    t: ?i64 = null,
};

pub const Bye = struct {
    reason: ?[]u8 = null,
};

pub const connecting_timeout_ms: i64 = 2_000;

pub const PreviewSession = struct {
    allocator: std.mem.Allocator,
    state: State,
    port: ?u16,
    engine_pid: ?i64,
    last_heartbeat_ms: ?i64,
    engine_version: ?[]u8,
    bye_reason: ?[]u8,
    started_ms: ?i64,
    stderr_buf: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .idle,
            .port = null,
            .engine_pid = null,
            .last_heartbeat_ms = null,
            .engine_version = null,
            .bye_reason = null,
            .started_ms = null,
            .stderr_buf = .empty,
        };
    }

    pub fn deinit(self: *Self) void {
        self.releaseOwnedStrings();
        self.stderr_buf.deinit(self.allocator);
    }

    fn releaseOwnedStrings(self: *Self) void {
        if (self.engine_version) |v| {
            self.allocator.free(v);
            self.engine_version = null;
        }
        if (self.bye_reason) |r| {
            self.allocator.free(r);
            self.bye_reason = null;
        }
    }

    /// Stubbed — the preview feature is disabled during the 0.16
    /// migration. Returns success and lands in `.crashed` so the panel
    /// surfaces the "disabled" message without throwing.
    pub fn start(self: *Self, proj: *const project.Project) PreviewError!void {
        _ = proj;
        self.releaseOwnedStrings();
        self.stderr_buf.clearRetainingCapacity();
        self.state = .crashed;
        self.bye_reason = self.allocator.dupe(u8, "preview disabled — 0.16 migration WIP") catch null;
    }

    pub fn stop(self: *Self) void {
        self.releaseOwnedStrings();
        self.stderr_buf.clearRetainingCapacity();
        self.state = .stopped;
    }

    pub fn poll(self: *Self) void {
        _ = self;
    }

    pub fn isActive(self: *const Self) bool {
        return switch (self.state) {
            .listening, .connecting, .running => true,
            else => false,
        };
    }

    /// Bytes captured from the child's stderr; surfaced by the
    /// preview panel when a session lands in `crashed`. Always empty
    /// in the stub.
    pub fn capturedStderr(self: *const Self) []const u8 {
        return self.stderr_buf.items;
    }
};

// Suppress unused-import warning while the stub stays minimal.
comptime {
    _ = builtin;
}
