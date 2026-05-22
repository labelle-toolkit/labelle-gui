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
//! Scope ceiling — this PR (#112) restored:
//!   - hello / heartbeat / bye   (engine→editor JSON control frames)
//!   - frame_offer               (engine→editor; #543 / drives
//!                                `on_frame_offer` callback the App
//!                                wires to `attachGameView`)
//!   - frame_published           (engine→editor; informational, no
//!                                state change in editor for v1)
//!
//! #117 extends the scope with the **binary telemetry plane** —
//! length-prefixed records led by an `ESC` (0x1B) magic byte. The
//! reader peeks byte 0 of the inbox: `0x1B` → decode header + payload
//! per `BinaryFrameKind`; `{` → newline-framed JSON as before. See the
//! engine-side `preview_mode.zig` top-doc for the wire format.
//!
//! Out of scope (kept stubbed so consumer code compiles):
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
extern "c" fn write(fd: c_int, buf: [*]const u8, len: usize) isize;
extern "c" fn __error() *c_int;
extern "c" fn __errno_location() *c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" var environ: [*]?[*:0]const u8;
/// libc `waitpid(2)` — used in non-blocking mode (`WNOHANG`) by
/// `tryWaitChild` to detect a subprocess that exited before the
/// editor's connecting-timeout fires. Returns the pid of a reaped
/// child, 0 when no child has exited yet, or -1 on error.
extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
/// `WNOHANG` is `1` on both Darwin and Linux — safe to hardcode here
/// rather than threading it through `std.posix.W` (which doesn't
/// re-export the value as a Zig constant).
const WNOHANG: c_int = 1;

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

/// How long to wait for the spawned `labelle run` subprocess to
/// dial back into the listener before declaring the preview
/// `.crashed`. The CLI runs `zig build` first (cold builds can take
/// 30-60+ seconds for a sokol+imgui game), so the timeout must cover
/// the build phase + the game's own startup, not just the network
/// connect. A proper fix would distinguish "build pending" (child
/// alive, no connection yet) from "really crashed" (child exited)
/// — see #134-follow-up. For now, generous flat budget.
pub const connecting_timeout_ms: i64 = 60_000;

/// Heartbeat watchdog window for the `.running` state (#79).
///
/// The engine emits a `heartbeat` frame every
/// `preview_mode.heartbeat_interval_ms` (250 ms today). If the editor
/// goes this long without receiving *any* inbound traffic — heartbeat,
/// frame_published, telemetry, anything — the engine is presumed dead
/// or wedged and the session is declared `.crashed`.
///
/// Why a watchdog is needed at all: a hard engine crash usually EOFs
/// the TCP socket, which `tryRead` already catches. But a *wedged*
/// engine (game-thread deadlock, infinite loop, paused under a
/// debugger) keeps the socket open with no data flowing — without
/// this watchdog the editor would sit in `.running` forever, showing
/// a stale "last heartbeat" the user can't tell is frozen.
///
/// The window is deliberately generous — 12 intervals — so a GC
/// pause, a slow frame, or a brief scheduler hiccup on the engine
/// side never trips a false `.crashed`. It only fires when the
/// engine has been silent for a span no live engine would produce.
pub const heartbeat_timeout_ms: i64 = 3_000;

/// Grace window for resolving a deferred socket EOF (#79).
///
/// `tryRead` records a socket EOF without an accompanying `bye` as
/// *pending* (`eof_at_ms`) rather than crashing immediately, because a
/// clean engine shutdown EOFs the socket before its process becomes a
/// reapable zombie. `poll` then waits for `tryWaitChild` to reap the
/// subprocess and report its true exit status. This is the upper bound
/// on that wait: once the socket has been EOFed this long and the child
/// *still* hasn't been reaped, the session resolves to `.crashed` as a
/// backstop (e.g. a wrapper process wedged after its child died). The
/// happy path resolves in the very next poll or two — a process whose
/// socket the kernel already closed is microseconds from reapable.
pub const eof_resolve_grace_ms: i64 = 2_000;

/// Callback slot — fires on the first `frame_offer` JSON frame the
/// engine sends after the `hello` handshake. The App wires this to
/// `attachGameView(shm_name, format)` (#107 → #112 end-to-end seam).
///
/// `shm_name` and `format` are borrowed — only valid for the call
/// duration. Copy before storing.
///
/// `format` mirrors the engine's `frame_offer.format` field. Today's
/// values:
///   - `"bgra8"` (default) → shm CPU upload path (`preview_shm.Consumer`).
///   - `"iosurface_bgra8"` → macOS zero-copy path (`iosurface.Consumer`).
/// Unknown formats should fall back to the SHM path on the consumer
/// side; `frame_offer` JSON without an explicit `format` key parses as
/// `"bgra8"` for backward compat with engines that predate the field.
pub const FrameOfferCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, shm_name: [:0]const u8, width: u32, height: u32, format: []const u8) void,
};

/// Callback invoked on `component_changed` binary frames (kind=3 of the
/// preview-mode binary plane). `name` and `bytes` are borrowed slices
/// into the inbox — valid only for the call duration. Copy before
/// storing. App wires this to `EntityInspector` (#84 / #91).
pub const ComponentChangedCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, entity_id: u64, name: []const u8, bytes: []const u8) void,
};

/// Callback invoked on `node_entered` binary frames (kind=4). `flow_name`
/// is a borrowed slice into the inbox — valid only for the call duration.
/// App wires this to `FlowRuntime` for the flow-node pulse (#91).
pub const NodeEnteredCallback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, flow_name: []const u8, node_id: u32) void,
};

/// Magic byte that flags a binary telemetry frame on the multiplexed
/// socket — must match `preview_mode.binary_magic` on the engine side.
/// `ESC` (0x1B) is chosen because no valid JSON document or whitespace
/// prefix can begin with it; the reader peeks the first inbox byte to
/// discriminate JSON vs binary.
pub const binary_magic: u8 = 0x1B;

/// Mirrors `preview_mode.BinaryFrameKind` on the engine side. Numbered
/// explicitly because these go on the wire — appending is safe,
/// reordering is a protocol break.
pub const BinaryFrameKind = enum(u8) {
    entity_created = 1,
    entity_destroyed = 2,
    component_changed = 3,
    node_entered = 4,
    pin_value = 5,
    _,
};

/// Fixed 6-byte header preceding each binary payload:
/// `[u8 magic] [u8 kind] [u32 length_LE]`. `length` covers the payload
/// only — not the header.
const binary_header_bytes: usize = 6;

/// Inbox buffer cap. JSON control frames are tiny (~100 B for hello,
/// ~80 B for frame_offer). Binary plane frames (component_changed
/// in particular) carry per-component serialized payloads — for the
/// scenes we ship today, a handful of components × a few hundred
/// bytes each. 16 KB gives plenty of headroom; bump if a single
/// component's serialized payload approaches that ceiling.
const inbox_cap: usize = 16 * 1024;

/// Compose the argv used to spawn `labelle run` for a preview session.
/// Extracted so the shape is regression-locked under unit test without
/// going through `std.process.spawn` (#131 / #132). The returned slice
/// references `argv_buf`, `scene_buf`, and the caller's `dir_path` +
/// `addr_str` — all must outlive the returned slice. Returns
/// `error.OutOfMemory` only if `scene` doesn't fit in `scene_buf`.
pub fn buildSpawnArgv(
    argv_buf: *[16][]const u8,
    scene_buf: *[128]u8,
    dir_path: []const u8,
    scene: ?[]const u8,
) error{OutOfMemory}![]const []const u8 {
    // Per #130: the labelle CLI doesn't define `--preview-mode`;
    // the host:port is propagated via `LABELLE_PREVIEW` env var
    // instead. So argv stays `["labelle", "run", <dir>]` plus the
    // optional `--scene=<name>` from #132.
    argv_buf[0] = "labelle";
    argv_buf[1] = "run";
    argv_buf[2] = dir_path;
    var n: usize = 3;
    if (scene) |s| {
        const flag = std.fmt.bufPrint(scene_buf, "--scene={s}", .{s}) catch
            return error.OutOfMemory;
        argv_buf[n] = flag;
        n += 1;
    }
    return argv_buf[0..n];
}

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
    /// Read cursor for `consumeStderr` — the next call returns bytes
    /// `stderr_buf.items[stderr_cursor..]` and advances the cursor.
    /// Reset alongside `stderr_buf` on every fresh `bindListener`
    /// (i.e. each Run cycle) so a stale tail from the previous session
    /// doesn't leak into the new one's live-tail consumer.
    stderr_cursor: usize = 0,
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
    /// Monotonic millisecond timestamp of the last inbound traffic
    /// while in `.running` (#79). Distinct from `last_heartbeat_ms`,
    /// which carries the engine's *own* `t` value off the heartbeat
    /// frame — that's the engine clock, not comparable to our clock
    /// and not advanced by non-heartbeat traffic. `last_rx_ms` is
    /// the editor's local receive clock, refreshed by *any* complete
    /// frame, and is what the heartbeat watchdog measures against.
    /// Set when the `hello` handshake completes; `null` before that.
    last_rx_ms: ?i64 = null,
    /// Monotonic millisecond timestamp of a *deferred* socket EOF (#79).
    ///
    /// When `tryRead` observes EOF on `conn_fd` in a non-terminal state
    /// without a preceding `bye`, it does NOT immediately `markCrashed`.
    /// A clean engine shutdown (Run → play → close window) closes its
    /// socket as part of process teardown — the kernel can deliver the
    /// socket FIN (so `read` returns 0) *before* the process becomes a
    /// reapable zombie, so `waitpid(WNOHANG)` still returns 0 at the
    /// poll that sees the EOF. Crashing on the EOF would misreport that
    /// clean exit as `.crashed` — the exact #79 bug.
    ///
    /// Instead the EOF is recorded here and the crashed-vs-stopped
    /// decision is deferred to `resolvePendingEof` in `poll`, which
    /// waits for `tryWaitChild` to reap the subprocess and read its real
    /// exit status (code 0 → `.stopped`, anything else → `.crashed`).
    /// If the child is already gone with no clean landing, or stays
    /// unreaped past `eof_resolve_grace_ms`, the EOF resolves to a
    /// genuine `.crashed`. `null` = no EOF pending.
    eof_at_ms: ?i64 = null,

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
        self.stderr_cursor = 0;
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
        // The heartbeat watchdog clock only runs in `.running`; clear
        // any stale value from a prior cycle so the first watchdog
        // check after `hello` measures from the handshake, not from a
        // previous session (#79).
        self.last_rx_ms = null;
        self.last_heartbeat_ms = null;
        // Drop any deferred-EOF marker from a prior cycle (#79) so the
        // first poll of this fresh Run can't resolve a stale EOF.
        self.eof_at_ms = null;
    }

    /// Production entry: bind + spawn `labelle run <project_dir>`
    /// (plus an optional `--scene=<name>` flag) with
    /// `LABELLE_PREVIEW=127.0.0.1:<port>` in the env. Captures the
    /// subprocess' stderr to surface on `.crashed` (currently the
    /// engine doesn't expose useful stderr — that's #79 territory —
    /// but the scaffolding is back in place).
    ///
    /// The labelle CLI's `run` subcommand doesn't define a
    /// `--preview-mode` flag (verified `labelle --help` — only
    /// `--timeout`, `--scene`, `--platform`, `--optimize`,
    /// `--docker`, `--target`, `-- <args>`). The assembler-generated
    /// game's main reads `LABELLE_PREVIEW` env var instead. Setting
    /// the env in the parent process before spawning makes the
    /// child + CLI subprocess + game subprocess all inherit it
    /// (POSIX fork+exec env propagation).
    ///
    /// `scene` is the optional scene picker override (#132). When
    /// non-null, `--scene=<name>` is appended to the argv. `null`
    /// (the default) leaves scene selection to `project.labelle`'s
    /// `initial_scene` field.
    pub fn start(self: *Self, proj: *const project.Project, scene: ?[]const u8) PreviewError!void {
        const dir_path = proj.dir orelse return error.NoProjectPath;

        try self.bindListener();
        errdefer self.stop();

        var addr_buf: [32]u8 = undefined;
        const addr_str = std.fmt.bufPrintZ(&addr_buf, "127.0.0.1:{d}", .{self.port.?}) catch
            return error.OutOfMemory;

        // Build an env Map by cloning the current process environ
        // and adding LABELLE_PREVIEW. Pass via SpawnOptions —
        // mutating the parent's environ via libc setenv() was
        // unreliable in practice (the spawned game's env didn't
        // see LABELLE_PREVIEW even though PATH propagated correctly,
        // suggesting std.process.spawn snapshots env in a way that
        // doesn't pick up runtime setenv calls on Darwin).
        _ = setenv("LABELLE_PREVIEW", addr_str.ptr, 1); // still set for the simpler propagation path
        var env_map = std.process.Environ.Map.init(self.allocator);
        defer env_map.deinit();
        // Copy the current environ into the Map. extern environ is
        // a null-terminated array of "KEY=VAL" strings.
        var i: usize = 0;
        while (environ[i]) |entry| : (i += 1) {
            const s = std.mem.span(entry);
            if (std.mem.indexOfScalar(u8, s, '=')) |eq| {
                env_map.put(s[0..eq], s[eq + 1 ..]) catch return error.OutOfMemory;
            }
        }
        env_map.put("LABELLE_PREVIEW", addr_str) catch return error.OutOfMemory;

        // `scene_buf` lives on this function's stack and is referenced
        // by `argv` until `std.process.spawn` returns. Spawn reads
        // argv during the syscall, so the stack lifetime is fine —
        // same pattern `addr_buf` already uses for the listener
        // address. 128 bytes is generous for a scene name (the
        // project tree's `isScenePath` only ever surfaces names that
        // fit in a file path).
        var scene_buf: [128]u8 = undefined;
        var argv_buf: [16][]const u8 = undefined;
        const argv = buildSpawnArgv(&argv_buf, &scene_buf, dir_path, scene) catch
            return error.OutOfMemory;

        const child = std.process.spawn(io_global.io(), .{
            .argv = argv,
            .environ_map = &env_map,
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
        // Symmetric with `start()`'s setenv. Multiple stops are safe
        // (unsetenv on an unset var is a no-op).
        _ = unsetenv("LABELLE_PREVIEW");
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
        // A manual Stop overrides any deferred-EOF resolution (#79).
        self.eof_at_ms = null;
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

        // Subprocess-exit detection (#127, extended for #79). If the
        // spawned `labelle run` exits — build failure, panic, an
        // immediate `error.FileNotFound` on the game binary, or a
        // mid-session crash of the game itself — `waitpid(WNOHANG)`
        // reaps it and lands the session in `.crashed` with the exit
        // code in `bye_reason`.
        //
        // This now also runs in `.running` (#79): a hard engine crash
        // *usually* EOFs the TCP socket, which `tryRead` catches — but
        // not always promptly. The kernel can keep a half-open
        // connection alive (no FIN delivered, or the game's grandchild
        // died while the CLI wrapper lingers) so `read` returns EAGAIN
        // forever and the session would otherwise sit in a stale
        // `.running`. Reaping the child directly closes that gap.
        // `tryWaitChild` itself early-returns when the child is still
        // alive, so this is cheap on the happy path.
        if (self.state == .listening or self.state == .connecting or self.state == .running) {
            self.tryWaitChild();
        }

        // Resolve a deferred socket EOF (#79). `tryRead` records an
        // unexpected EOF as *pending* rather than crashing on the spot,
        // because a clean engine shutdown closes its socket before its
        // process is reapable — see `eof_at_ms` / `resolvePendingEof`.
        // This runs after `tryWaitChild` above so the exit status it
        // reaped (clean → `.stopped`, crash → `.crashed`) is already
        // reflected in `self.state` by the time the EOF is settled.
        if (self.eof_at_ms != null) {
            self.resolvePendingEof();
        }

        // Heartbeat watchdog (#79). The engine emits a `heartbeat`
        // every ~250 ms; `tryRead` refreshes `last_rx_ms` on *any*
        // inbound frame. If that clock goes stale past
        // `heartbeat_timeout_ms` the engine is wedged (alive but not
        // talking — deadlock, infinite loop, paused under a debugger)
        // and we declare `.crashed` so the panel stops showing a
        // frozen "last heartbeat" the user can't distinguish from a
        // live one. A genuine engine *exit* is normally caught earlier
        // by the EOF path in `tryRead` or by `tryWaitChild` above;
        // this watchdog is the backstop for the silent-but-connected
        // case those two miss.
        if (self.state == .running) {
            if (self.last_rx_ms) |t_rx| {
                const silent = nowMs() - t_rx;
                if (silent > heartbeat_timeout_ms) {
                    self.markCrashed("engine heartbeat timed out");
                }
            }
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

    /// Milliseconds since the last inbound frame from the engine, or
    /// `null` before the `hello` handshake completes (#79). Measured
    /// against the editor's local monotonic clock — comparable to
    /// `heartbeat_timeout_ms`, unlike `last_heartbeat_ms` which holds
    /// the engine's own clock value. The preview panel surfaces this
    /// so a frozen engine shows a visibly-climbing age.
    pub fn heartbeatAgeMs(self: *const Self) ?i64 {
        const t_rx = self.last_rx_ms orelse return null;
        return nowMs() - t_rx;
    }

    /// Yield stderr bytes that have arrived since the last call and
    /// advance the internal cursor past them. Designed to be called
    /// once per editor frame from the Compiler Output panel so the
    /// build phase's progress (the `zig build` step running inside
    /// `labelle run`, which is cold-cache 30-60+ seconds for a
    /// sokol+imgui game) is visible live instead of only on `.crashed`.
    ///
    /// Returned slice borrows from `stderr_buf`; the caller must copy
    /// before the next `poll()` invocation if it needs to retain the
    /// bytes. Empty slice when no new bytes have arrived. Cursor is
    /// monotonic within a session and resets to 0 on `bindListener`
    /// (every fresh Run).
    pub fn consumeStderr(self: *Self) []const u8 {
        if (self.stderr_cursor >= self.stderr_buf.items.len) return &.{};
        const fresh = self.stderr_buf.items[self.stderr_cursor..];
        self.stderr_cursor = self.stderr_buf.items.len;
        return fresh;
    }

    // ── Phase-3 uplink stubs (out of scope for #112) ──────────────
    /// Send `{"kind":"frame_accept"}\n` to the engine, flipping its
    /// `frame_state` to `.accepted` so subsequent `publishFrame*` /
    /// `signalSlotReady` calls succeed instead of bouncing with
    /// `StreamNotActive`. Caller invokes this after `on_frame_offer`
    /// has run and the consumer side (SHM or IOSurface) has
    /// successfully attached.
    pub fn sendFrameAccept(self: *Self) void {
        if (self.conn_fd < 0) return;
        const msg: []const u8 = "{\"kind\":\"frame_accept\"}\n";
        var off: usize = 0;
        while (off < msg.len) {
            const n = write(self.conn_fd, msg.ptr + off, msg.len - off);
            if (n <= 0) return; // best-effort; drop on error
            off += @intCast(n);
        }
    }

    /// Send `{"kind":"mouse_pos","x":X,"y":Y}\n` to the engine.
    /// Drains best-effort; partial-write loss is acceptable for mouse
    /// telemetry. Coordinates are in IOSurface pixel space (not screen
    /// space) — the editor's Game View tab converts before calling.
    /// labelle-assembler#143.
    pub fn sendMousePos(self: *Self, x: f32, y: f32) void {
        if (self.conn_fd < 0) return;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"kind\":\"mouse_pos\",\"x\":{d:.2},\"y\":{d:.2}}}\n", .{ x, y }) catch return;
        var off: usize = 0;
        while (off < msg.len) {
            const n = write(self.conn_fd, msg.ptr + off, msg.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

    /// Send `{"kind":"mouse_button","button":B,"down":D}\n`.
    /// `button` follows ImGuiMouseButton convention (0 = left, 1 = right,
    /// 2 = middle). labelle-assembler#143.
    pub fn sendMouseButton(self: *Self, button: i32, down: bool) void {
        if (self.conn_fd < 0) return;
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{{\"kind\":\"mouse_button\",\"button\":{d},\"down\":{s}}}\n", .{ button, if (down) "true" else "false" }) catch return;
        var off: usize = 0;
        while (off < msg.len) {
            const n = write(self.conn_fd, msg.ptr + off, msg.len - off);
            if (n <= 0) return;
            off += @intCast(n);
        }
    }

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

        // Drain the inbox. Peek byte 0 of each pending record to
        // route — `binary_magic` (0x1B) → length-prefixed binary
        // frame; anything else → newline-framed JSON. Stops when no
        // complete frame is available (binary frame's length bytes
        // haven't all arrived yet, or no `\n` in the buffer).
        //
        // Every fully-decoded frame refreshes the heartbeat watchdog
        // clock (#79): any inbound traffic — heartbeat, frame frames,
        // telemetry — proves the engine is alive this instant, so the
        // watchdog measures silence, not specifically heartbeat gaps.
        while (self.inbox.items.len > 0) {
            if (self.inbox.items[0] == binary_magic) {
                if (!self.tryReadBinary()) break;
                self.last_rx_ms = nowMs();
            } else {
                const nl = std.mem.indexOfScalar(u8, self.inbox.items, '\n') orelse break;
                const line = self.inbox.items[0..nl];
                self.handleFrame(line);
                self.last_rx_ms = nowMs();
                const remaining = self.inbox.items.len - (nl + 1);
                std.mem.copyForwards(u8, self.inbox.items[0..remaining], self.inbox.items[nl + 1 ..]);
                self.inbox.shrinkRetainingCapacity(remaining);
            }
        }

        // Post-parse: if we hit EOF in the read loop, decide
        // crashed-vs-stopped. If a `bye` frame landed (handleFrame set
        // state=.stopped + bye_reason) or a manual `stop()` raced the
        // EOF, we're already terminal — nothing to do.
        if (saw_eof and self.state != .stopped and self.state != .crashed and self.bye_reason == null) {
            // A clean engine exit (Run → play → close window) closes
            // its socket as part of process teardown. The kernel can
            // deliver the socket FIN — so this `read` returns 0 — while
            // the engine process is still mid-exit and NOT yet a
            // reapable zombie. At that instant `waitpid(WNOHANG)` (in
            // `tryWaitChild`) returns 0, so calling it here would NOT
            // reap the child and NOT learn the exit code. Crashing on
            // the EOF unconditionally — or after a `tryWaitChild` that
            // can't yet see the exit — misreports a normal shutdown as
            // `.crashed`. That is the exact #79 race.
            //
            // So don't decide here. Record the EOF as pending and let
            // `poll`'s `resolvePendingEof` settle it once `tryWaitChild`
            // has actually reaped the subprocess and read its true exit
            // status: code 0 → `.stopped`, non-zero / signal → genuine
            // `.crashed`. The dead socket is closed now (no further
            // reads are possible on an EOFed fd) so a subsequent
            // `tryRead` early-returns on `conn_fd < 0`.
            if (self.eof_at_ms == null) self.eof_at_ms = nowMs();
            if (self.conn_fd >= 0) {
                _ = close(self.conn_fd);
                self.conn_fd = -1;
            }
        }
    }

    /// Settle a deferred socket EOF recorded by `tryRead` (#79). Called
    /// from `poll` *after* `tryWaitChild` has had its chance to reap the
    /// subprocess this tick.
    ///
    /// Resolution order:
    ///  - State already terminal (`.stopped`/`.crashed`) — `tryWaitChild`
    ///    or a late `bye` settled it. Clear the pending flag, done.
    ///  - Child reaped but the session is somehow still non-terminal, or
    ///    there is no child at all — the engine is gone and no clean
    ///    landing happened, so the EOF is a genuine crash.
    ///  - Child still alive/unreaped within the grace window — keep
    ///    waiting; the next poll's `tryWaitChild` should reap it.
    ///  - Grace window elapsed with the child still unreaped — backstop
    ///    crash (e.g. a wrapper process wedged after its child died).
    fn resolvePendingEof(self: *Self) void {
        const eof_t = self.eof_at_ms orelse return;

        // `tryWaitChild` (clean exit) or a late `bye` already landed us
        // in a terminal state — the pending EOF is moot.
        if (self.state == .stopped or self.state == .crashed) {
            self.eof_at_ms = null;
            return;
        }

        // Is the subprocess still around and reapable-pending? `child`
        // is null in the loopback test fixture; `child.id` is null once
        // `tryWaitChild` has reaped it. Either way there is no exit
        // status still coming, so the EOF is the final word: a crash.
        const child_pending = blk: {
            const child = self.child orelse break :blk false;
            break :blk child.id != null;
        };
        if (!child_pending) {
            self.markCrashed("connection closed");
            self.eof_at_ms = null;
            return;
        }

        // Child still alive — `tryWaitChild` ran this tick and saw
        // `waitpid` return 0. Give it more polls to reap, bounded so a
        // wrapper that EOFed its socket but never exits can't wedge the
        // session in a stale `.running` forever.
        if (nowMs() - eof_t > eof_resolve_grace_ms) {
            self.markCrashed("connection closed");
            self.eof_at_ms = null;
        }
    }

    /// Try to consume one binary frame from the head of the inbox.
    /// Returns `true` if a full frame was decoded (and the caller can
    /// loop for the next one), `false` if not enough bytes have
    /// arrived yet (caller should bail until the next `poll`). Bumps
    /// the session to `.crashed` on a malformed `kind`/`length`.
    fn tryReadBinary(self: *Self) bool {
        // Need the full 6-byte header before we can read `length`.
        if (self.inbox.items.len < binary_header_bytes) return false;

        // Header layout: [u8 magic=0x1B] [u8 kind] [u32 length-LE].
        const kind_byte = self.inbox.items[1];
        const length: u32 = std.mem.readInt(u32, self.inbox.items[2..6], .little);

        // Reject oversize lengths up front so a corrupted byte stream
        // doesn't park the decoder waiting forever for bytes the
        // engine will never send.
        if (binary_header_bytes + @as(usize, length) > inbox_cap) {
            self.markCrashed("binary frame too large");
            return false;
        }

        const total = binary_header_bytes + @as(usize, length);
        if (self.inbox.items.len < total) return false; // Wait for more.

        const payload = self.inbox.items[binary_header_bytes..total];
        const kind: BinaryFrameKind = @enumFromInt(kind_byte);
        self.handleBinaryFrame(kind, payload);

        // Consume the frame.
        const remaining = self.inbox.items.len - total;
        std.mem.copyForwards(u8, self.inbox.items[0..remaining], self.inbox.items[total..]);
        self.inbox.shrinkRetainingCapacity(remaining);
        return true;
    }

    fn handleBinaryFrame(self: *Self, kind: BinaryFrameKind, payload: []const u8) void {
        // Decoders consume `payload` in place — string slices are
        // borrowed views into the inbox, valid for the call duration.
        // No allocator needed today. Add a per-frame FBA scratch
        // here if a future decoder needs heap (#119 review).
        switch (kind) {
            .entity_created => self.decodeEntityCreated(payload),
            .entity_destroyed => self.decodeEntityDestroyed(payload),
            .component_changed => self.decodeComponentChanged(payload),
            .node_entered => self.decodeNodeEntered(payload),
            .pin_value => self.decodePinValue(payload),
            _ => {}, // Unknown kind — drop silently (forward-compat).
        }
    }

    /// Payload: `[u64 entity_id] [u16 name_len] [name_len bytes]`.
    /// No callback slot today (EntityInspector doesn't have a "new
    /// entity announced" hook yet) — consume the bytes so the decoder
    /// stays in sync.
    fn decodeEntityCreated(self: *Self, payload: []const u8) void {
        _ = self;
        if (payload.len < 10) return; // u64 + u16 minimum.
        // const entity_id = std.mem.readInt(u64, payload[0..8], .little);
        const name_len: u16 = std.mem.readInt(u16, payload[8..10], .little);
        if (10 + @as(usize, name_len) > payload.len) return;
        // Borrowed slice (unused for now): payload[10 .. 10 + name_len].
    }

    /// Payload: `[u64 entity_id]`. No callback today.
    fn decodeEntityDestroyed(self: *Self, payload: []const u8) void {
        _ = self;
        if (payload.len < 8) return;
        // const entity_id = std.mem.readInt(u64, payload[0..8], .little);
    }

    /// Payload: `[u64 entity_id] [u16 name_len] [name bytes] [u32 data_len] [data bytes]`.
    /// Fires `on_component_changed` with borrowed `name` + `bytes` slices.
    fn decodeComponentChanged(self: *Self, payload: []const u8) void {
        if (payload.len < 14) return; // u64 + u16 + u32 minimum.
        const entity_id = std.mem.readInt(u64, payload[0..8], .little);
        const name_len: u16 = std.mem.readInt(u16, payload[8..10], .little);
        var off: usize = 10;
        if (off + name_len > payload.len) return;
        const name = payload[off .. off + name_len];
        off += name_len;
        if (off + 4 > payload.len) return;
        const data_len: u32 = std.mem.readInt(u32, payload[off..][0..4], .little);
        off += 4;
        if (off + data_len > payload.len) return;
        const bytes = payload[off .. off + data_len];

        if (self.on_component_changed) |cb| {
            cb.func(cb.ctx, entity_id, name, bytes);
        }
    }

    /// Payload: `[u16 flow_name_len] [flow bytes] [u32 node_id]`.
    /// Fires `on_node_entered` with the borrowed `flow_name` slice.
    fn decodeNodeEntered(self: *Self, payload: []const u8) void {
        if (payload.len < 6) return; // u16 + u32 minimum.
        const flow_len: u16 = std.mem.readInt(u16, payload[0..2], .little);
        var off: usize = 2;
        if (off + flow_len > payload.len) return;
        const flow_name = payload[off .. off + flow_len];
        off += flow_len;
        if (off + 4 > payload.len) return;
        const node_id: u32 = std.mem.readInt(u32, payload[off..][0..4], .little);

        if (self.on_node_entered) |cb| {
            cb.func(cb.ctx, flow_name, node_id);
        }
    }

    /// Payload: `[u16 flow_name_len] [flow bytes] [u32 node_id]
    /// [u16 pin_name_len] [pin bytes] [f64 value]`. No callback slot
    /// today (consumer tracked in #100); consume the bytes correctly
    /// and drop the payload so the decoder stays in sync.
    fn decodePinValue(self: *Self, payload: []const u8) void {
        _ = self;
        if (payload.len < 2) return;
        const flow_len: u16 = std.mem.readInt(u16, payload[0..2], .little);
        var off: usize = 2;
        if (off + flow_len > payload.len) return;
        off += flow_len;
        if (off + 4 > payload.len) return;
        // const node_id = std.mem.readInt(u32, payload[off..][0..4], .little);
        off += 4;
        if (off + 2 > payload.len) return;
        const pin_len: u16 = std.mem.readInt(u16, payload[off..][0..2], .little);
        off += 2;
        if (off + pin_len > payload.len) return;
        off += pin_len;
        if (off + 8 > payload.len) return;
        // f64 bit-pattern as u64 little-endian — reverse the producer's
        // `@bitCast(u64, value)`:
        // const bits = std.mem.readInt(u64, payload[off..][0..8], .little);
        // const value: f64 = @bitCast(bits);
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
                /// `bgra8` (default — SHM CPU upload path) vs
                /// `iosurface_bgra8` (macOS zero-copy). Defaulted so
                /// engines that predate the field keep working. The
                /// borrowed slice into the parse arena is valid for
                /// the call into `on_frame_offer.func`; copy on the
                /// consumer side before storing.
                format: []const u8 = "bgra8",
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
                cb.func(cb.ctx, name_z, m.width, m.height, m.format);
            }
        } else if (std.mem.eql(u8, kind_only.kind, "frame_published")) {
            // Informational — editor consumer polls the SHM ring
            // directly. Drop silently.
        }
        // Unknown JSON kinds drop silently. Binary plane frames are
        // routed by `tryReadBinary` before they ever reach this path.
    }

    /// Non-blocking `waitpid` on the spawned subprocess. If the child
    /// has already exited, transition to a terminal state with the
    /// exit code (or signal number) embedded in `bye_reason`. No-op
    /// when there's no child (test fixtures call `bindListener`
    /// directly) or when the child is still alive.
    ///
    /// Terminal-state selection (#79): a child that exits with code 0
    /// while the session is `.running` shut itself down cleanly — the
    /// user closed the game window — so the session lands in
    /// `.stopped`, not `.crashed`. This keeps the "Run preview → play
    /// → close" cycle from misreporting as a crash even when the
    /// engine exits without sending an explicit `bye` frame, or when
    /// the process exit is observed before an in-flight `bye` is read.
    /// Any non-zero exit, any terminating signal, or an exit during
    /// the pre-handshake `.listening`/`.connecting` phase is a crash.
    ///
    /// Why bypass `std.process.Child.wait` here: that API blocks until
    /// termination and tears the Child down (sets `id = null`, closes
    /// stderr pipe). We need a *peek* — child may still be running
    /// the cold `zig build` step, and even when it has exited we want
    /// to drain the stderr pipe one more time on the next `poll` before
    /// `stop()` closes everything down. Calling `waitpid(WNOHANG)`
    /// directly leaves the Child's pipes intact and only reaps the
    /// zombie when the kernel has one.
    fn tryWaitChild(self: *Self) void {
        const child = if (self.child) |*c| c else return;
        const pid = child.id orelse return; // already waited/killed
        var status: c_int = 0;
        const rc = waitpid(@intCast(pid), &status, WNOHANG);
        if (rc <= 0) return; // 0 = still running; -1 = error (race with kill); leave for the next tick
        // Decode wait(2) status — same shape as `<sys/wait.h>` macros
        // (`WIFEXITED` / `WEXITSTATUS` / `WIFSIGNALED` / `WTERMSIG`).
        // The high byte is the exit code on a normal exit; the low 7
        // bits are the terminating signal otherwise. Keep the reason
        // string short — the panel surfaces it inline.
        var reason_buf: [64]u8 = undefined;
        const exited_normally = (status & 0x7F) == 0;
        const exit_code: c_int = (status >> 8) & 0xFF;
        const reason: []const u8 = blk: {
            if (exited_normally) {
                break :blk std.fmt.bufPrint(&reason_buf, "labelle exited (code {d})", .{exit_code}) catch "labelle exited";
            } else {
                const sig = status & 0x7F;
                break :blk std.fmt.bufPrint(&reason_buf, "labelle killed by signal {d}", .{sig}) catch "labelle killed";
            }
        };
        // A clean exit (code 0) from an already-`running` session is
        // the engine shutting itself down — land in `.stopped`. Every
        // other case (non-zero code, signal, exit before the `hello`
        // handshake) is a crash. See the doc comment above.
        const clean_shutdown = exited_normally and exit_code == 0 and self.state == .running;
        // One final stderr drain so the panel surfaces the *last*
        // bytes the child wrote before exiting. Without this, the
        // tail (often the compile error in the `zig build` step) can
        // sit in the pipe buffer past `markCrashed`'s teardown.
        self.drainChildStderr();
        // `waitpid` already reaped the zombie. We have to mirror
        // `std.process.Child.wait`'s post-condition exactly so a
        // subsequent `stop()` → `kill()` is a no-op (instead of
        // tripping the `child.stderr == null` assertion). That means
        // clearing `id` *and* closing all pipe fds the spawn opened.
        // Today only `stderr` is piped (start() uses `.pipe`); the
        // others are `.ignore`/`.inherit` so they're already `null`.
        if (child.stderr) |f| {
            f.close(io_global.io());
            child.stderr = null;
        }
        if (child.stdout) |f| {
            f.close(io_global.io());
            child.stdout = null;
        }
        if (child.stdin) |f| {
            f.close(io_global.io());
            child.stdin = null;
        }
        child.id = null;

        if (clean_shutdown) {
            // Engine exited cleanly without (or before) a `bye` frame.
            // Mirror the `bye`-handler's terminal landing: record the
            // reason, close the connection fd, drop the listener, and
            // settle in `.stopped`.
            if (self.bye_reason == null) {
                self.bye_reason = self.allocator.dupe(u8, reason) catch null;
            }
            self.state = .stopped;
            if (self.conn_fd >= 0) {
                _ = close(self.conn_fd);
                self.conn_fd = -1;
            }
            if (self.listener) |*l| {
                l.deinit(io_global.io());
                self.listener = null;
            }
            return;
        }
        self.markCrashed(reason);
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
            self.appendStderrChunk(buf[0..@intCast(n)]);
        }
    }

    /// Append `chunk` to `stderr_buf`, rotating from the front when the
    /// resulting size would exceed `stderr_cap`. Compile errors land
    /// at the END of stderr — a non-rotating buffer would freeze the
    /// live tail on the first 16 KiB of zig output and hide the actual
    /// failure. `stderr_cursor` is shifted by the dropped amount so
    /// `consumeStderr` keeps emitting only NEW bytes after a rotation
    /// (or returns nothing extra if the consumer was entirely inside
    /// the dropped prefix). `pub` so the tests can drive it without
    /// a real subprocess.
    pub fn appendStderrChunk(self: *Self, chunk: []const u8) void {
        const stderr_cap: usize = 16 * 1024;
        if (chunk.len == 0) return;
        if (chunk.len >= stderr_cap) {
            self.stderr_buf.clearRetainingCapacity();
            const tail_off = chunk.len - stderr_cap;
            self.stderr_buf.appendSlice(self.allocator, chunk[tail_off..]) catch return;
            self.stderr_cursor = 0;
            return;
        }
        if (self.stderr_buf.items.len + chunk.len > stderr_cap) {
            const overflow = self.stderr_buf.items.len + chunk.len - stderr_cap;
            const drop = @min(overflow, self.stderr_buf.items.len);
            const remaining = self.stderr_buf.items.len - drop;
            std.mem.copyForwards(
                u8,
                self.stderr_buf.items[0..remaining],
                self.stderr_buf.items[drop..],
            );
            self.stderr_buf.shrinkRetainingCapacity(remaining);
            self.stderr_cursor = if (self.stderr_cursor > drop) self.stderr_cursor - drop else 0;
        }
        self.stderr_buf.appendSlice(self.allocator, chunk) catch return;
    }

    fn markCrashed(self: *Self, reason: []const u8) void {
        std.log.warn("preview: markCrashed reason={s} state_before={s} stderr_capture={s}", .{
            reason,
            @tagName(self.state),
            self.stderr_buf.items[0..@min(self.stderr_buf.items.len, 512)],
        });
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
