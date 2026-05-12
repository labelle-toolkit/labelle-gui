//! Preview-mode session — Phase 1 of the PIE preview umbrella (#59 / #61).
//!
//! Owns the editor side of the "run with telemetry" handshake:
//!
//!   1. `start(project_dir)` binds a TCP listener on `127.0.0.1:0`, asks
//!      the kernel for a port, spawns `labelle run <dir> -- --preview-mode
//!      127.0.0.1:<port>` (mirroring `src/compiler.zig`'s subprocess
//!      pattern), and transitions to `listening`.
//!   2. `poll()` is called every frame. While `listening`, it non-blockingly
//!      accept()s; on a hit it transitions to `connecting`, then to
//!      `running` once a `hello` arrives. After `connecting_timeout_ms`
//!      with no client the child is killed and we land in `crashed`.
//!   3. While `running`, `poll()` drains any newline-delimited JSON the
//!      engine sent (`heartbeat`, `bye`, or unknown — which we ignore on
//!      purpose so Phase 2+ kinds don't break the editor). EOF without a
//!      `bye` → `crashed`. `bye` → `stopped`.
//!   4. `stop()` closes the stream, SIGTERMs the child, waits, transitions
//!      to `stopped`.
//!
//! Mock-friendly by design: the JSON message types live in `Message` so
//! the state-machine tests can drive transitions by feeding raw bytes
//! through `feedBytesForTest`. The end-to-end smoke against `labelle run
//! -- --preview-mode` is manual — sibling repos (#94, #193) haven't
//! landed it yet.

const std = @import("std");
const builtin = @import("builtin");
const project = @import("project.zig");

/// Lifecycle of one preview session. Strictly monotonic except for the
/// terminal `stopped`/`crashed` → `idle` reset that `stop()` does so the
/// user can press Run again.
pub const State = enum {
    idle,
    /// Listener is up, child is spawned, awaiting accept().
    listening,
    /// Client connected, waiting for `hello` frame.
    connecting,
    /// `hello` received; heartbeats are flowing.
    running,
    /// Stream EOFed before a `bye` arrived, or the connect timeout fired.
    crashed,
    /// Clean shutdown — engine sent `bye` and disconnected, or user
    /// pressed Stop.
    stopped,
};

pub const PreviewError = error{
    NoProjectPath,
    LauncherNotFound,
    AlreadyRunning,
    OutOfMemory,
};

/// Wire-protocol message kinds. We only enumerate what Phase 1 needs;
/// unknown kinds parse into `unknown` via `kind_tag` and are dropped.
/// These structs serve both as the JSON parse target *and* as the
/// owned-fields payload `handleFrame` consumes — strings inside are
/// always heap-allocated copies (see `parseKind`) so the session can
/// hold them across the parse-arena teardown.
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

/// How long we wait between spawning the child and getting an accept()
/// before declaring failure. Engine cold-start is dominated by package
/// cache resolution and build, so 2s is generous for the simple case
/// but real `labelle run` builds may need longer — bump if false
/// crashes show up in the field.
pub const connecting_timeout_ms: i64 = 2_000;

/// Cap on a single message frame size. Generous because the engine's
/// hello may eventually carry richer metadata; tight enough that a
/// runaway producer can't OOM the editor.
const max_frame_bytes: usize = 64 * 1024;

/// Read buffer growth chunk. One heartbeat is ~30 bytes, hellos are
/// ~100. A small chunk keeps per-frame syscalls quick without
/// re-allocating on every line.
const read_chunk: usize = 1024;

pub const PreviewSession = struct {
    allocator: std.mem.Allocator,
    state: State,

    server: ?std.net.Server,
    child: ?std.process.Child,
    stream: ?std.net.Stream,

    /// Port the kernel assigned at bind time. Captured so the test
    /// harness and the UI can both display it.
    port: ?u16,
    engine_pid: ?i64,
    /// Wall-clock milliseconds (std.time.milliTimestamp()) the last
    /// heartbeat (or hello) arrived. Used by the panel to render
    /// "X ms ago".
    last_heartbeat_ms: ?i64,
    /// Reported by the engine's hello; allocated in `allocator`.
    engine_version: ?[]u8,
    /// Reason carried by `bye`; allocated in `allocator`.
    bye_reason: ?[]u8,

    /// Timestamp when the listener went up; used to enforce the
    /// connect-out timeout while in `listening`/`connecting`.
    started_ms: ?i64,

    /// Sliding buffer of bytes pulled from `stream`. We split on '\n'
    /// inside `drainStream`; partial frames stay here until completed
    /// next frame.
    rx_buf: std.ArrayList(u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .idle,
            .server = null,
            .child = null,
            .stream = null,
            .port = null,
            .engine_pid = null,
            .last_heartbeat_ms = null,
            .engine_version = null,
            .bye_reason = null,
            .started_ms = null,
            .rx_buf = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.teardown();
        self.rx_buf.deinit(self.allocator);
    }

    /// Spawn a preview run for `proj`. Mirrors `Compiler.buildOrRun`'s
    /// shape: validate the project path, set up the IPC plumbing, spawn
    /// the launcher, return — the caller polls `poll()` each frame.
    pub fn start(self: *Self, proj: *const project.Project) PreviewError!void {
        if (self.state == .listening or self.state == .connecting or self.state == .running) {
            return error.AlreadyRunning;
        }
        const dir = proj.dir orelse return error.NoProjectPath;

        // Reset terminal state from the previous run.
        self.resetForRestart();

        const addr = std.net.Address.parseIp("127.0.0.1", 0) catch return error.OutOfMemory;
        var server = std.net.Address.listen(addr, .{
            .reuse_address = true,
            .force_nonblocking = true,
        }) catch |err| {
            std.log.err("preview: listen failed: {s}", .{@errorName(err)});
            return error.LauncherNotFound;
        };
        errdefer server.deinit();

        const assigned_port = server.listen_address.getPort();

        // `labelle run <dir> -- --preview-mode 127.0.0.1:<port>` — the
        // `--` passthrough is implemented in labelle-cli#193 (sibling
        // PR). Until that lands, `labelle run` will still spawn the
        // child but the engine won't know to connect back; the
        // connect-timeout path is what catches that.
        var port_buf: [32]u8 = undefined;
        const target = std.fmt.bufPrint(&port_buf, "127.0.0.1:{d}", .{assigned_port}) catch unreachable;

        var child = std.process.Child.init(&.{
            "labelle", "run", dir, "--", "--preview-mode", target,
        }, self.allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            else => {
                std.log.err("preview: spawn failed: {s}", .{@errorName(err)});
                return error.LauncherNotFound;
            },
        };

        self.server = server;
        self.child = child;
        self.port = assigned_port;
        self.started_ms = std.time.milliTimestamp();
        self.state = .listening;
    }

    /// Cooperatively shut down: close stream, SIGTERM child, wait. Safe
    /// to call from any non-`idle` state. After this returns the session
    /// is in `.stopped` (or stays in `.crashed` if it was already crashed).
    pub fn stop(self: *Self) void {
        self.teardownChildAndIo();
        if (self.state != .crashed) self.state = .stopped;
    }

    /// Returns true if the session is currently driving a running
    /// preview. Useful for menu enabling.
    pub fn isActive(self: *const Self) bool {
        return switch (self.state) {
            .listening, .connecting, .running => true,
            else => false,
        };
    }

    /// Per-frame tick. Drives accept on `listening`, hello-wait on
    /// `connecting`, and message drain on `running`. Bounded work per
    /// call — never blocks.
    pub fn poll(self: *Self) void {
        switch (self.state) {
            .idle, .stopped, .crashed => return,
            .listening => self.tickListening(),
            .connecting, .running => self.tickStream(),
        }
    }

    // ─── State driving ─────────────────────────────────────────────────

    fn tickListening(self: *Self) void {
        if (self.server == null) {
            self.state = .crashed;
            return;
        }
        const srv: *std.net.Server = &self.server.?;

        const conn = srv.accept() catch |err| switch (err) {
            error.WouldBlock => {
                self.checkConnectTimeout();
                return;
            },
            else => {
                std.log.err("preview: accept failed: {s}", .{@errorName(err)});
                self.failWithCrash();
                return;
            },
        };

        // Once a client is in, the listener is done — we only accept
        // one preview connection per session (#59 punts multi-session).
        srv.deinit();
        self.server = null;

        setNonBlock(conn.stream.handle) catch |err| {
            std.log.err("preview: NONBLOCK on stream failed: {s}", .{@errorName(err)});
            conn.stream.close();
            self.failWithCrash();
            return;
        };

        self.stream = conn.stream;
        self.state = .connecting;
    }

    fn tickStream(self: *Self) void {
        const stream = self.stream orelse {
            self.failWithCrash();
            return;
        };

        // Drain whatever's available, then split lines.
        var buf: [read_chunk]u8 = undefined;
        while (true) {
            const n = stream.read(&buf) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    std.log.err("preview: read failed: {s}", .{@errorName(err)});
                    self.failWithCrash();
                    return;
                },
            };
            if (n == 0) {
                // EOF. If we've already seen a `bye` (`bye_reason` set
                // and we transitioned to .stopped), nothing to do.
                if (self.state == .running) {
                    self.failWithCrash();
                }
                return;
            }
            self.rx_buf.appendSlice(self.allocator, buf[0..n]) catch {
                self.failWithCrash();
                return;
            };
            if (self.rx_buf.items.len > max_frame_bytes) {
                std.log.err("preview: rx buffer exceeded {d} bytes", .{max_frame_bytes});
                self.failWithCrash();
                return;
            }
        }

        self.consumeFrames();

        if (self.state == .connecting) self.checkConnectTimeout();
    }

    fn consumeFrames(self: *Self) void {
        var consumed: usize = 0;
        while (true) {
            const rest = self.rx_buf.items[consumed..];
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse break;
            const line = rest[0..nl];
            self.handleFrame(line);
            consumed += nl + 1;
            if (self.state == .stopped or self.state == .crashed) break;
        }
        if (consumed > 0) {
            const remaining = self.rx_buf.items.len - consumed;
            std.mem.copyForwards(u8, self.rx_buf.items[0..remaining], self.rx_buf.items[consumed..]);
            self.rx_buf.shrinkRetainingCapacity(remaining);
        }
    }

    fn handleFrame(self: *Self, raw: []const u8) void {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) return;

        const kind = parseKind(self.allocator, trimmed) catch |err| {
            std.log.warn("preview: bad frame ({s}): {s}", .{ @errorName(err), trimmed });
            return;
        };

        // `parseKind` returns string fields already dup'd in
        // `self.allocator`; we take ownership here (or free if we're
        // not keeping them). Don't double-dupe.
        switch (kind) {
            .hello => |h| {
                self.last_heartbeat_ms = std.time.milliTimestamp();
                self.engine_pid = h.pid;
                if (self.engine_version) |old| self.allocator.free(old);
                self.engine_version = h.engine_version;
                self.state = .running;
            },
            .heartbeat => {
                if (self.state == .running) self.last_heartbeat_ms = std.time.milliTimestamp();
            },
            .bye => |b| {
                if (self.bye_reason) |old| self.allocator.free(old);
                self.bye_reason = b.reason orelse (self.allocator.dupe(u8, "normal") catch null);
                // Treat bye as authoritative — engines that disconnect
                // immediately after bye get the same `stopped` state
                // as ones that keep the stream open for a few more ms.
                self.cleanShutdown();
            },
            .unknown => {},
        }
    }

    // ─── Lifecycle helpers ─────────────────────────────────────────────

    fn checkConnectTimeout(self: *Self) void {
        const started = self.started_ms orelse return;
        const now = std.time.milliTimestamp();
        if (now - started > connecting_timeout_ms) {
            std.log.err("preview: timeout waiting for engine to connect", .{});
            self.failWithCrash();
        }
    }

    fn failWithCrash(self: *Self) void {
        self.teardownChildAndIo();
        self.state = .crashed;
    }

    fn cleanShutdown(self: *Self) void {
        self.teardownChildAndIo();
        self.state = .stopped;
    }

    fn teardown(self: *Self) void {
        self.teardownChildAndIo();
        self.freeStrings();
    }

    fn teardownChildAndIo(self: *Self) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        if (self.server) |*srv| {
            srv.deinit();
            self.server = null;
        }
        if (self.child) |*c| {
            _ = c.kill() catch {};
            self.child = null;
        }
    }

    fn freeStrings(self: *Self) void {
        if (self.engine_version) |v| {
            self.allocator.free(v);
            self.engine_version = null;
        }
        if (self.bye_reason) |r| {
            self.allocator.free(r);
            self.bye_reason = null;
        }
    }

    fn resetForRestart(self: *Self) void {
        self.teardownChildAndIo();
        self.freeStrings();
        self.rx_buf.clearRetainingCapacity();
        self.port = null;
        self.engine_pid = null;
        self.last_heartbeat_ms = null;
        self.started_ms = null;
        self.state = .idle;
    }

    // ─── Testing surface ───────────────────────────────────────────────

    /// Mock-server entry point. The test harness drives one or more
    /// frames into a `PreviewSession` that's already wired to a real
    /// loopback `Stream` (no child process). Lets the state-machine
    /// tests skip launcher invocation entirely.
    pub fn attachForTest(self: *Self, stream: std.net.Stream) !void {
        self.resetForRestart();
        try setNonBlock(stream.handle);
        self.stream = stream;
        self.started_ms = std.time.milliTimestamp();
        self.state = .connecting;
    }
};

/// Tagged-union projection over the protocol's `kind` field. Unknown
/// kinds become `.unknown` rather than failing so the engine can grow
/// Phase 2+ messages without breaking us.
const Message = union(enum) {
    hello: Hello,
    heartbeat: Heartbeat,
    bye: Bye,
    unknown,
};

/// Parse-time mirrors of the wire structs — fields are `?[]const u8`
/// because the JSON parser hands back arena-owned slices. We dupe out
/// of the parse arena into `allocator` before returning the `Message`.
const HelloRaw = struct {
    engine_version: ?[]const u8 = null,
    pid: ?i64 = null,
    protocol_version: ?i64 = null,
};
const ByeRaw = struct {
    reason: ?[]const u8 = null,
};

fn parseKind(allocator: std.mem.Allocator, raw: []const u8) !Message {
    // Peek the `kind` field via Value so a missing-or-typo `kind` gives
    // us a structured error rather than a parse failure that aborts.
    // The body fields are then parsed via typed structs with
    // `ignore_unknown_fields = true`.
    var parsed_dyn = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed_dyn.deinit();

    const obj = switch (parsed_dyn.value) {
        .object => |o| o,
        else => return error.UnexpectedToken,
    };
    const kind_val = obj.get("kind") orelse return error.MissingField;
    const kind_str = switch (kind_val) {
        .string => |s| s,
        else => return error.UnexpectedToken,
    };

    if (std.mem.eql(u8, kind_str, "hello")) {
        const p = try std.json.parseFromSlice(HelloRaw, allocator, raw, .{ .ignore_unknown_fields = true });
        defer p.deinit();
        const ev: ?[]u8 = if (p.value.engine_version) |v| try allocator.dupe(u8, v) else null;
        return .{ .hello = .{ .engine_version = ev, .pid = p.value.pid, .protocol_version = p.value.protocol_version } };
    } else if (std.mem.eql(u8, kind_str, "heartbeat")) {
        const p = try std.json.parseFromSlice(Heartbeat, allocator, raw, .{ .ignore_unknown_fields = true });
        defer p.deinit();
        return .{ .heartbeat = .{ .t = p.value.t } };
    } else if (std.mem.eql(u8, kind_str, "bye")) {
        const p = try std.json.parseFromSlice(ByeRaw, allocator, raw, .{ .ignore_unknown_fields = true });
        defer p.deinit();
        const r: ?[]u8 = if (p.value.reason) |v| try allocator.dupe(u8, v) else null;
        return .{ .bye = .{ .reason = r } };
    }
    return .unknown;
}

/// Put a socket fd into non-blocking mode. Mirrors what
/// `posix.socket(SOCK.NONBLOCK)` does for listeners, except we need to
/// apply it after `accept()` returned a fresh fd. On Windows, would-be
/// callers go through ioctlsocket; the editor only runs on POSIX hosts
/// for now (raylib + zglfw on Win64 is supported but the preview path
/// hasn't been exercised there).
fn setNonBlock(fd: std.posix.fd_t) !void {
    if (builtin.os.tag == .windows) {
        // POSIX-only for now. Phase 2 can add the WSAIoctl call if a
        // Windows user surfaces.
        return;
    }
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const new_flags = flags | (1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, new_flags);
}
