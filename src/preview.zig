//! Preview-mode session — TCP listener for engine connections.
//!
//! Architecture (per labelle-gui#60): the editor binds a loopback
//! TCP listener and the engine dials out, so port selection lives
//! here. `start(project)` binds the listener, spawns
//! `labelle run <dir> --preview-mode 127.0.0.1:<port>`, transitions
//! to `.listening`, and lets `poll()` (called once per frame from
//! the main loop) drive state transitions via non-blocking I/O.
//!
//! Threading model: single-threaded. The listener FD is set to
//! `O_NONBLOCK` via libc `fcntl` (see #112 for the variadic-`fcntl`
//! ABI lesson re-learned in labelle-engine#545), so `poll()` returns
//! promptly even when nothing has connected yet.
//!
//! Scope ceiling — this PR (#112) restores:
//!   - hello / heartbeat / bye   (engine→editor JSON control frames)
//!   - frame_offer               (engine→editor; #543 / drives
//!                                `on_frame_offer` callback the App
//!                                wires to `attachGameView`)
//!   - frame_published           (engine→editor; informational, no
//!                                state change in editor for v1)
//!
//! Out of scope (kept stubbed so consumer code compiles):
//!   - binary plane frames (entity_created / entity_destroyed /
//!     component_changed / node_entered / pin_value) — `on_component
//!     _changed` / `on_node_entered` callback slots stay defined
//!     but never fire.
//!   - editor→engine uplink (subscribe / unsubscribe / watch_entity
//!     / subscribe_flow / subscribe_pin_values) — methods stay
//!     present but write nothing on the wire.
//!   - Auto-restart on disconnect.
//!
//! See #112 body for the deferred work list.

const std = @import("std");
const builtin = @import("builtin");
const project = @import("project.zig");
const io_global = @import("io_global.zig");

extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, len: usize) isize;
extern "c" fn __error() *c_int;
extern "c" fn __errno_location() *c_int;

fn libcErrno() c_int {
    return if (builtin.os.tag == .macos) __error().* else __errno_location().*;
}

// `fcntl` is variadic in libc. Declaring it non-variadic with a fixed
// third arg is a calling-convention mismatch on aarch64-darwin (and
// other ABIs that put variadic args on the stack), so the stdlib's
// correctly-declared decl gets used. See labelle-engine#545 for the
// same lesson on the engine side.
const c_fcntl = std.c.fcntl;
const F_GETFL: c_int = 3;
const F_SETFL: c_int = 4;
const O_NONBLOCK: c_int = if (builtin.os.tag == .macos) 4 else 2048;
const EAGAIN: c_int = if (builtin.os.tag == .macos) 35 else 11;

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

/// Callback slot — fires on the first `frame_offer` JSON frame the
/// engine sends after the `hello` handshake. The App wires this to
/// `attachGameView(shm_name)` (#107 → #112 end-to-end seam).
///
/// `shm_name` is borrowed — only valid for the call duration. Copy
/// before storing.
pub const FrameOfferCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, shm_name: [:0]const u8, width: u32, height: u32) void,
};

/// Callback invoked on `component_changed` binary frames. Stubbed —
/// the transport doesn't decode the binary plane yet. The field is
/// preserved so consumer code (entity_inspector, flow_runtime) compiles
/// against the post-Phase-3 API shape.
pub const ComponentChangedCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, entity_id: u64, name: []const u8, bytes: []const u8) void,
};

pub const NodeEnteredCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, flow_name: []const u8, node_id: u32) void,
};

/// Inbox buffer cap. JSON frames are tiny (~100 B for hello,
/// ~80 B for frame_offer); a few KB is plenty of slack.
const inbox_cap: usize = 4 * 1024;

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
    /// PIE viewport frame-offer hook (#112). App wires to
    /// `attachGameView` so the Game View panel auto-opens when the
    /// engine emits its `frame_offer`. `null` = ignore offers.
    on_frame_offer: ?FrameOfferCallback = null,
    /// Stubbed callbacks — binary plane is out of scope for #112.
    on_component_changed: ?ComponentChangedCallback = null,
    on_node_entered: ?NodeEnteredCallback = null,

    /// Active listener once `state >= .listening`. We don't keep the
    /// listener around after the editor's connection is accepted —
    /// preview is single-game-at-a-time.
    listener: ?std.Io.net.Server = null,
    /// Connected engine fd once `state >= .connecting`. -1 sentinel
    /// rather than ?fd_t to simplify the read path's signed-int
    /// compares.
    conn_fd: c_int = -1,
    /// Newline-framing buffer fed by the per-frame poll. Heap-
    /// allocated so we can grow on a giant message if needed.
    inbox: std.ArrayListUnmanaged(u8) = .empty,
    /// Spawned subprocess. `null` in tests (the loopback fixture
    /// dials the listener directly).
    child: ?std.process.Child = null,
    /// Monotonic millisecond clock at start() — used for the
    /// connecting-timeout check inside poll().
    connect_start_ms: ?i64 = null,

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
        self.stop();
        self.releaseOwnedStrings();
        self.stderr_buf.deinit(self.allocator);
        self.inbox.deinit(self.allocator);
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

    /// Bind a loopback TCP listener on a kernel-assigned port. Test
    /// hook — production callers go through `start` which also
    /// spawns the engine subprocess.
    pub fn bindListener(self: *Self) PreviewError!void {
        if (self.state != .idle and self.state != .stopped and self.state != .crashed) {
            return error.AlreadyRunning;
        }
        // Clean up leftover resources from a prior `.crashed` /
        // `.stopped` cycle. `markCrashed` doesn't kill the child
        // (it only manages the listener+conn fds), and the bye
        // path closed neither — both cases can leak through to a
        // fresh `start()` and leak a subprocess + fd (#113 review).
        if (self.child) |*c| {
            c.kill(io_global.io());
            self.child = null;
        }
        if (self.conn_fd >= 0) {
            _ = close(self.conn_fd);
            self.conn_fd = -1;
        }
        if (self.listener) |*l| {
            l.deinit(io_global.io());
            self.listener = null;
        }
        self.releaseOwnedStrings();
        self.stderr_buf.clearRetainingCapacity();
        self.inbox.clearRetainingCapacity();

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch unreachable;
        var server = addr.listen(io_global.io(), .{ .reuse_address = true }) catch
            return error.ListenFailed;

        // Read the OS-assigned port off the bound socket.
        var sa: std.posix.sockaddr.in = undefined;
        var sa_len: std.posix.socklen_t = @sizeOf(@TypeOf(sa));
        if (std.posix.system.getsockname(server.socket.handle, @ptrCast(&sa), &sa_len) != 0) {
            server.deinit(io_global.io());
            return error.ListenFailed;
        }
        const port = std.mem.bigToNative(u16, sa.port);

        // Non-blocking listener so `accept` in poll() returns
        // EAGAIN promptly instead of blocking the UI.
        const fd: c_int = @intCast(server.socket.handle);
        const orig_flags = c_fcntl(fd, F_GETFL, @as(c_int, 0));
        if (orig_flags >= 0) {
            _ = c_fcntl(fd, F_SETFL, @as(c_int, orig_flags | O_NONBLOCK));
        }

        self.listener = server;
        self.port = port;
        self.state = .listening;
        self.connect_start_ms = nowMs();
        self.started_ms = self.connect_start_ms;
    }

    /// Production entry: bind + spawn `labelle run <project_dir>
    /// --preview-mode 127.0.0.1:<port>`. Captures the subprocess'
    /// stderr to surface on `.crashed` (currently the engine doesn't
    /// expose useful stderr — that's #79 territory — but the
    /// scaffolding is back in place).
    pub fn start(self: *Self, proj: *const project.Project) PreviewError!void {
        const dir_path = proj.dir orelse return error.NoProjectPath;

        try self.bindListener();
        errdefer self.stop();

        // The engine's `--preview-mode` flag expects `host:port`, not
        // a bare port — `preview_mode.parseArgs` calls
        // `lastIndexOfScalar(':')` to split the value. Missing the
        // host prefix made the engine fail to parse and silently
        // fall through to non-preview mode (#113 review).
        var addr_buf: [32]u8 = undefined;
        const addr_str = std.fmt.bufPrint(&addr_buf, "127.0.0.1:{d}", .{self.port.?}) catch
            return error.OutOfMemory;

        var argv_buf: [16][]const u8 = undefined;
        const argv = blk: {
            argv_buf[0] = "labelle";
            argv_buf[1] = "run";
            argv_buf[2] = dir_path;
            argv_buf[3] = "--preview-mode";
            argv_buf[4] = addr_str;
            break :blk argv_buf[0..5];
        };

        const child = std.process.spawn(io_global.io(), .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .pipe,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ListenFailed,
        };
        self.child = child;
    }

    /// Kill any running subprocess, close listener + connection.
    /// Idempotent — safe to call from `.idle` or after a previous
    /// `.crashed`/`.stopped` landing.
    pub fn stop(self: *Self) void {
        if (self.child) |*c| {
            c.kill(io_global.io());
            self.child = null;
        }
        if (self.conn_fd >= 0) {
            _ = close(self.conn_fd);
            self.conn_fd = -1;
        }
        if (self.listener) |*l| {
            l.deinit(io_global.io());
            self.listener = null;
        }
        self.connect_start_ms = null;
        // Don't reset `state` if it's already `.crashed` — `poll`
        // landed us there for a reason and the UI still needs to
        // show "preview crashed". Only `.listening`/`.connecting`/
        // `.running` lift to `.stopped` here (the user pressed
        // Stop).
        if (self.state == .listening or self.state == .connecting or self.state == .running) {
            self.state = .stopped;
        }
    }

    /// Drives the state machine. Call once per editor frame.
    pub fn poll(self: *Self) void {
        // Drain subprocess stderr opportunistically. Always safe; if
        // the child piped stderr we'll see crash output the panel
        // can surface.
        self.drainChildStderr();

        switch (self.state) {
            .idle, .stopped, .crashed => return,
            .listening => self.tryAccept(),
            .connecting, .running => self.tryRead(),
        }

        // Connecting-timeout: if no client showed up — or accepted
        // but didn't `hello` — within the window, the subprocess
        // likely failed and we land in `.crashed`. Two cases share
        // the same deadline (#113 review uncovered the inner guard
        // restricted the timeout to `.listening` only, making it
        // dead code for `.connecting`):
        //
        //  - `.listening` — engine never opened the TCP connection.
        //  - `.connecting` — TCP handshake succeeded but `hello`
        //    never arrived (engine spawned, crashed before the
        //    handshake, or got stuck).
        if (self.state == .listening or self.state == .connecting) {
            if (self.connect_start_ms) |t0| {
                const elapsed = nowMs() - t0;
                if (elapsed > connecting_timeout_ms) {
                    const reason: []const u8 = if (self.state == .listening)
                        "engine never connected"
                    else
                        "engine connected but no hello";
                    self.markCrashed(reason);
                }
            }
        }
    }

    pub fn isActive(self: *const Self) bool {
        return switch (self.state) {
            .listening, .connecting, .running => true,
            else => false,
        };
    }

    pub fn capturedStderr(self: *const Self) []const u8 {
        return self.stderr_buf.items;
    }

    // ── Phase-3 uplink stubs (out of scope for #112) ──────────────
    pub fn watchEntity(self: *Self, entity_id: u64) !void {
        _ = self;
        _ = entity_id;
    }
    pub fn unwatchEntity(self: *Self, entity_id: u64) !void {
        _ = self;
        _ = entity_id;
    }
    pub fn subscribeComponent(self: *Self, name: []const u8) !void {
        _ = self;
        _ = name;
    }
    pub fn unsubscribeComponent(self: *Self, name: []const u8) !void {
        _ = self;
        _ = name;
    }
    pub fn subscribeFlow(self: *Self, flow_name: []const u8) !void {
        _ = self;
        _ = flow_name;
    }
    pub fn unsubscribeFlow(self: *Self, flow_name: []const u8) !void {
        _ = self;
        _ = flow_name;
    }

    // ── Internals ──────────────────────────────────────────────────

    fn tryAccept(self: *Self) void {
        const server = if (self.listener) |*l| l else return;
        // Non-blocking accept — relies on the O_NONBLOCK flag we set
        // in bindListener. `std.Io.net.Server.accept` doesn't
        // differentiate EAGAIN from real errors, so we sniff errno
        // directly via std.posix.system.accept to keep the polling
        // hot path branch-free.
        var addr: std.posix.sockaddr.in = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(@TypeOf(addr));
        const fd = std.posix.system.accept(
            server.socket.handle,
            @ptrCast(&addr),
            &addr_len,
        );
        if (fd < 0) {
            const errno = libcErrno();
            if (errno == EAGAIN) return; // No client yet.
            self.markCrashed("accept failed");
            return;
        }

        // Drop the listener now — we only handle one game per
        // session.
        if (self.listener) |*l| {
            l.deinit(io_global.io());
            self.listener = null;
        }

        self.conn_fd = @intCast(fd);
        // Keep the new fd blocking-mode so we can also handle test
        // fixtures that write small messages without retries —
        // we'll set non-blocking explicitly inside tryRead.
        const orig = c_fcntl(self.conn_fd, F_GETFL, @as(c_int, 0));
        if (orig >= 0) _ = c_fcntl(self.conn_fd, F_SETFL, @as(c_int, orig | O_NONBLOCK));
        self.state = .connecting;
    }

    fn tryRead(self: *Self) void {
        if (self.conn_fd < 0) return;
        var scratch: [1024]u8 = undefined;
        var saw_eof = false;
        // Loop: drain everything currently available. The connection
        // is non-blocking; EAGAIN ends the loop.
        while (true) {
            const n = read(self.conn_fd, @ptrCast(&scratch[0]), scratch.len);
            if (n < 0) {
                const errno = libcErrno();
                if (errno == EAGAIN) break;
                self.markCrashed("read failed");
                return;
            }
            if (n == 0) {
                // EOF — don't bail without parsing what's already in
                // the inbox. In the standard `bye + close` shutdown
                // the engine writes the bye frame then closes the
                // socket; on a fast cycle a single `poll` can see
                // both halves and would otherwise miss the bye
                // because `markCrashed` returned before the parsing
                // loop (#113 review). Break out of the read loop
                // here, parse below, and decide crashed-vs-stopped
                // based on whether the bye actually landed.
                saw_eof = true;
                break;
            }
            if (self.inbox.items.len + @as(usize, @intCast(n)) > inbox_cap) {
                self.markCrashed("inbox overflow");
                return;
            }
            self.inbox.appendSlice(self.allocator, scratch[0..@intCast(n)]) catch {
                self.markCrashed("OOM");
                return;
            };
        }

        // Parse all complete newline-framed JSON lines.
        while (std.mem.indexOfScalar(u8, self.inbox.items, '\n')) |nl| {
            const line = self.inbox.items[0..nl];
            self.handleFrame(line);
            const remaining = self.inbox.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.inbox.items[0..remaining], self.inbox.items[nl + 1 ..]);
            self.inbox.shrinkRetainingCapacity(remaining);
        }

        // Post-parse: if we hit EOF in the read loop, decide
        // crashed-vs-stopped based on whether the bye actually
        // landed (handleFrame sets state=.stopped + bye_reason).
        // The `.stopped` check matches both the bye-then-close
        // clean shutdown and a manual `stop()` racing the EOF.
        if (saw_eof and self.state != .stopped and self.bye_reason == null) {
            self.markCrashed("connection closed");
        }
    }

    fn handleFrame(self: *Self, line: []const u8) void {
        // Single-pass parse: discover the `kind`, then route. Use
        // `parseFromSliceLeaky` so the temporary allocations live
        // for one frame and free on the arena reset (we use a tiny
        // FBA-backed scratch arena rather than the persistent
        // allocator).
        var buf: [4 * 1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const alloc = fba.allocator();

        const KindOnly = struct { kind: []const u8 };
        const kind_only = std.json.parseFromSliceLeaky(KindOnly, alloc, line, .{
            .ignore_unknown_fields = true,
        }) catch return;

        if (std.mem.eql(u8, kind_only.kind, "hello")) {
            const Msg = struct {
                kind: []const u8,
                engine_version: []const u8 = "",
                pid: i64 = 0,
                protocol_version: u32 = 0,
            };
            const m = std.json.parseFromSliceLeaky(Msg, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return;
            self.engine_pid = m.pid;
            if (self.engine_version) |v| self.allocator.free(v);
            self.engine_version = self.allocator.dupe(u8, m.engine_version) catch null;
            self.state = .running;
        } else if (std.mem.eql(u8, kind_only.kind, "heartbeat")) {
            const Msg = struct { kind: []const u8, t: i64 = 0 };
            const m = std.json.parseFromSliceLeaky(Msg, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return;
            self.last_heartbeat_ms = m.t;
        } else if (std.mem.eql(u8, kind_only.kind, "bye")) {
            const Msg = struct { kind: []const u8, reason: []const u8 = "normal" };
            const m = std.json.parseFromSliceLeaky(Msg, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return;
            if (self.bye_reason) |r| self.allocator.free(r);
            self.bye_reason = self.allocator.dupe(u8, m.reason) catch null;
            self.state = .stopped;
            // Symmetric with `markCrashed`: close the connection fd
            // on clean shutdown too, so a "Run" re-press doesn't
            // inherit a leftover open fd (#113 review).
            if (self.conn_fd >= 0) {
                _ = close(self.conn_fd);
                self.conn_fd = -1;
            }
        } else if (std.mem.eql(u8, kind_only.kind, "frame_offer")) {
            const Msg = struct {
                kind: []const u8,
                shm_name: []const u8 = "",
                width: u32 = 0,
                height: u32 = 0,
            };
            const m = std.json.parseFromSliceLeaky(Msg, alloc, line, .{
                .ignore_unknown_fields = true,
            }) catch return;
            if (self.on_frame_offer) |cb| {
                // Promote the borrowed name into a NUL-terminated
                // slice so the App's `attachGameView` (which calls
                // `shm_open`) gets a stable pointer. Lives on the
                // stack of `handleFrame` — fine because attachGameView
                // dupes again into the GameView's owned buffer.
                var name_buf: [64]u8 = undefined;
                if (m.shm_name.len >= name_buf.len) return;
                @memcpy(name_buf[0..m.shm_name.len], m.shm_name);
                name_buf[m.shm_name.len] = 0;
                const name_z: [:0]const u8 = name_buf[0..m.shm_name.len :0];
                cb.func(cb.ctx, name_z, m.width, m.height);
            }
        } else if (std.mem.eql(u8, kind_only.kind, "frame_published")) {
            // Informational — editor consumer polls the SHM ring
            // directly. Drop silently.
        }
        // Unknown kinds (Phase 2 binary frames, etc.) drop silently.
    }

    fn drainChildStderr(self: *Self) void {
        const child = if (self.child) |*c| c else return;
        const stderr_file = child.stderr orelse return;
        // Best-effort non-blocking peek. `stderr_file.handle` is the
        // raw fd; switch to O_NONBLOCK around the read so a happy
        // path with nothing to read doesn't block.
        const fd: c_int = @intCast(stderr_file.handle);
        const orig = c_fcntl(fd, F_GETFL, @as(c_int, 0));
        if (orig < 0) return;
        _ = c_fcntl(fd, F_SETFL, @as(c_int, orig | O_NONBLOCK));
        defer _ = c_fcntl(fd, F_SETFL, @as(c_int, orig));
        var buf: [512]u8 = undefined;
        while (true) {
            const n = read(fd, @ptrCast(&buf[0]), buf.len);
            if (n <= 0) return;
            // Cap to keep the buffer from runaway-growing if the
            // subprocess spams stderr.
            const stderr_cap: usize = 16 * 1024;
            if (self.stderr_buf.items.len >= stderr_cap) return;
            const room = stderr_cap - self.stderr_buf.items.len;
            const take = @min(@as(usize, @intCast(n)), room);
            self.stderr_buf.appendSlice(self.allocator, buf[0..take]) catch return;
        }
    }

    fn markCrashed(self: *Self, reason: []const u8) void {
        if (self.bye_reason == null) {
            self.bye_reason = self.allocator.dupe(u8, reason) catch null;
        }
        self.state = .crashed;
        if (self.conn_fd >= 0) {
            _ = close(self.conn_fd);
            self.conn_fd = -1;
        }
        if (self.listener) |*l| {
            l.deinit(io_global.io());
            self.listener = null;
        }
    }
};

fn nowMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

comptime {
    _ = builtin;
}
