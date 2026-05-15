//! Embedded game-view panel state.
//!
//! Owns the consumer side of the PIE viewport pixel ring: opens an
//! `engine.preview_mode.preview_shm.Consumer` against a SHM region
//! the engine allocated, mirrors each new frame into a `GL_TEXTURE_2D`
//! via `glTexSubImage2D`, and tracks end-to-end latency for the
//! Stats overlay.
//!
//! Pairs with `src/modules/game_view.zig` — that file wraps this
//! state in a togglable ImGui panel and registers it with the
//! Module Registry. This file is UI-free so the texture / consumer
//! lifecycle is testable headless.
//!
//! Architecture validated end-to-end in `imgui-preview-poc/src/editor.zig`
//! at 1280×720@60 with raw-IPC p50=5µs on Apple Silicon. This module
//! is a direct port of that pattern, minus the PoC's standalone
//! GLFW window since labelle-gui's frame loop already owns the GL
//! context.
//!
//! See labelle-engine#544 for the producer side and the protocol
//! handshake (#543) that delivers `frame_offer` payloads.

const std = @import("std");
const zopengl = @import("zopengl");
const engine = @import("engine");
const shm = engine.preview_mode_mod.preview_shm;

const gl = zopengl.bindings;

const latency_ring_capacity: usize = 120;

/// Errors specific to `GameView.attach`. SHM-open / mmap failures
/// from `preview_shm.Consumer.init` (`error.ShmOpenFailed`, etc.)
/// propagate verbatim.
pub const AttachError = shm.Error || error{AlreadyAttached};

pub const GameView = struct {
    allocator: std.mem.Allocator,
    /// `null` until `attach` opens a consumer.
    consumer: ?shm.Consumer = null,
    /// Owned (allocator-allocated, NUL-terminated) duplicate of the
    /// shm_name passed to `attach`. `engine.preview_shm.Consumer`
    /// stashes the name slice and we want a stable pointer for the
    /// lifetime of the consumer — caller-provided buffers might be
    /// stack-allocated or env-var scratch space.
    owned_shm_name: ?[:0]u8 = null,
    /// GL texture handle for the displayed frame. Zero when no texture
    /// is currently allocated. Width/height kept alongside so a
    /// frame_resize landed on the SHM ring lets us re-allocate the
    /// texture instead of misaligned `glTexSubImage2D` uploads.
    tex_id: gl.Uint = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    /// Monotonic — the frame_idx the texture currently contains.
    /// Test code reads this to assert "the editor is presenting new
    /// frames" without ever inspecting pixels (the zgui binding
    /// doesn't expose `ImGuiTestEngine_CaptureScreenshot`).
    last_frame_idx: u64 = 0,
    last_latency_ns: u64 = 0,
    /// Frames the producer outran us on — `frame.frame_idx -
    /// prior_idx - 1` summed over the session.
    dropped: u64 = 0,
    /// Frames uploaded by `poll`. Bumps once per successful texture
    /// upload — used for the FPS reading on the Stats overlay.
    presented: u64 = 0,
    /// Circular buffer of recent end-to-end latency samples in ns.
    /// Sized to 120 — at 60 Hz that's a 2-second window which is
    /// sticky enough to read on screen without averaging away spikes.
    latency_ring: [latency_ring_capacity]u64 = [_]u64{0} ** latency_ring_capacity,
    latency_head: usize = 0,
    latency_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.detach();
    }

    /// Open the named SHM region the engine allocated for this
    /// session and stand up a matching `GL_TEXTURE_2D`. The GL
    /// context must be current on the calling thread (which it
    /// always is on the main thread for labelle-gui's frame loop).
    pub fn attach(self: *Self, shm_name: [:0]const u8) AttachError!void {
        if (self.consumer != null) return error.AlreadyAttached;

        const owned = self.allocator.dupeZ(u8, shm_name) catch return error.MmapFailed;
        errdefer self.allocator.free(owned);

        var consumer = try shm.Consumer.init(owned);
        errdefer consumer.deinit();

        const w = consumer.header.width;
        const h = consumer.header.height;

        // Build a zero-initialized texture; per-frame uploads will
        // `glTexSubImage2D` into it. `GL_RGBA8` matches the SHM's
        // RGBA8 pixel format. `GL_CLAMP_TO_EDGE` avoids edge-bleed
        // when the panel renders the texture at a non-integer
        // scale.
        var tex: gl.Uint = 0;
        gl.genTextures(1, &tex);
        gl.bindTexture(gl.TEXTURE_2D, tex);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        gl.texImage2D(
            gl.TEXTURE_2D,
            0,
            gl.RGBA8,
            @intCast(w),
            @intCast(h),
            0,
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            null,
        );

        self.consumer = consumer;
        self.owned_shm_name = owned;
        self.tex_id = tex;
        self.tex_w = w;
        self.tex_h = h;
        self.last_frame_idx = 0;
        self.last_latency_ns = 0;
        self.dropped = 0;
        self.presented = 0;
        self.latency_head = 0;
        self.latency_count = 0;
    }

    /// Tear down the consumer + GL texture. Safe to call when not
    /// attached; called by `deinit`.
    pub fn detach(self: *Self) void {
        if (self.consumer) |*c| {
            c.deinit();
            self.consumer = null;
        }
        if (self.owned_shm_name) |n| {
            self.allocator.free(n);
            self.owned_shm_name = null;
        }
        if (self.tex_id != 0) {
            gl.deleteTextures(1, &self.tex_id);
            self.tex_id = 0;
        }
        self.tex_w = 0;
        self.tex_h = 0;
    }

    pub fn isAttached(self: *const Self) bool {
        return self.consumer != null;
    }

    /// Poll the SHM ring for a newer frame. If one is available,
    /// upload it to the texture and update the stats. Call once per
    /// editor frame from the main loop.
    ///
    /// Returns true when a new frame was uploaded — handy for tests
    /// + future "redraw only on new frame" optimization.
    pub fn poll(self: *Self) bool {
        const consumer = if (self.consumer) |*c| c else return false;
        const frame = consumer.latest() orelse return false;

        // Defensive: producer's resize should have triggered a re-
        // attach (engine sends a fresh `frame_offer` on resize) but
        // skip mid-resize frames just in case.
        if (frame.width != self.tex_w or frame.height != self.tex_h) return false;

        gl.bindTexture(gl.TEXTURE_2D, self.tex_id);
        gl.texSubImage2D(
            gl.TEXTURE_2D,
            0,
            0,
            0,
            @intCast(frame.width),
            @intCast(frame.height),
            gl.RGBA,
            gl.UNSIGNED_BYTE,
            frame.pixels,
        );

        // Drop accounting: how many producer frames did we skip
        // between `last_frame_idx` and this one? First frame after
        // attach has `last_frame_idx == 0` so the gap-from-zero math
        // is correct.
        if (self.last_frame_idx > 0 and frame.frame_idx > self.last_frame_idx + 1) {
            self.dropped += frame.frame_idx - self.last_frame_idx - 1;
        }
        self.last_frame_idx = frame.frame_idx;

        const now_ns = shm.nowNs();
        if (now_ns > frame.produce_ns) {
            self.last_latency_ns = now_ns - frame.produce_ns;
            self.latency_ring[self.latency_head] = self.last_latency_ns;
            self.latency_head = (self.latency_head + 1) % latency_ring_capacity;
            if (self.latency_count < latency_ring_capacity) self.latency_count += 1;
        }
        self.presented += 1;
        return true;
    }

    /// Mean end-to-end latency in nanoseconds over the most recent
    /// `latency_ring_capacity` samples. Returns 0 before the first
    /// frame is uploaded.
    pub fn meanLatencyNs(self: *const Self) u64 {
        if (self.latency_count == 0) return 0;
        var sum: u128 = 0;
        for (self.latency_ring[0..self.latency_count]) |v| sum += v;
        return @intCast(sum / @as(u128, self.latency_count));
    }
};
