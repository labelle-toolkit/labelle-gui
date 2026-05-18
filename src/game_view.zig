//! Embedded game-view panel state.
//!
//! Owns the consumer side of the PIE viewport pixel ring. Two transport
//! modes are supported via the `ConsumerMode` sum type:
//!
//!   - `.shm`         — `preview_shm.Consumer`. Engine memcpys BGRA8/
//!                       RGBA8 pixels into a POSIX shm ring; per frame
//!                       we `glTexSubImage2D` the latest slot into a
//!                       `GL_TEXTURE_2D`.
//!   - `.iosurface`   — macOS-only. `iosurface.Consumer` looks up an
//!                       IOSurface ring (id list lives in the shm
//!                       region's ControlBlock); each surface is
//!                       pre-bound to a `GL_TEXTURE_RECTANGLE` via
//!                       `CGLTexImageIOSurface2D`. Per frame we FBO-blit
//!                       the rectangle texture into a `GL_TEXTURE_2D`
//!                       (the target zgui.image actually samples, since
//!                       `imgui_impl_opengl3` hardcodes `GL_TEXTURE_2D`).
//!
//! The dispatch happens at `attach` time, driven by the `format` field
//! of the engine's `frame_offer` JSON frame: `"bgra8"` (or unset) takes
//! the SHM path, `"iosurface_bgra8"` takes the iosurface path on macOS.
//!
//! Pairs with `src/modules/game_view.zig` — that file wraps this state
//! in a togglable ImGui panel and registers it with the Module Registry.
//! This file is UI-free so the texture / consumer lifecycle is testable
//! headless.
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
const builtin = @import("builtin");
const zopengl = @import("zopengl");
const engine = @import("engine");
const iosurface = @import("iosurface.zig");
const shm = engine.preview_mode_mod.preview_shm;

const gl = zopengl.bindings;

const latency_ring_capacity: usize = 120;

/// Errors specific to `GameView.attach`. SHM-open / mmap failures
/// from `preview_shm.Consumer.init` (`error.ShmOpenFailed`, etc.)
/// propagate verbatim. IOSurface lookup failures from
/// `iosurface.Consumer.init` (`error.ControlBlockMissing`, etc.) join
/// the set. The shm_name-dupe step folds into `error.OutOfMemory`.
pub const AttachError = shm.Error || iosurface.Error || error{
    OutOfMemory,
    /// `GL_TEXTURE_RECTANGLE` ↔ `GL_TEXTURE_2D` FBO blit setup failed.
    /// Surfaces either a `CGLTexImageIOSurface2D` non-zero return or
    /// an incomplete framebuffer status — both are unrecoverable, so
    /// the consumer rolls back and the caller can fall back to SHM.
    IosurfaceGlBindFailed,
};

/// Which transport this `GameView` is currently fronting. Set at
/// `attach` time from the `format` argument; `detach` resets to the
/// implicit `.none` (the field is `?ConsumerMode = null` on `GameView`,
/// not an explicit variant).
pub const ConsumerMode = union(enum) {
    shm: shm.Consumer,
    /// macOS-only. The `iosurface.Consumer` owns the IOSurface refs
    /// (one CFRelease per ref on `deinit`); we layer rectangle GL
    /// textures + an FBO blit on top so ImGui can sample a
    /// `GL_TEXTURE_2D`.
    iosurface: iosurface.Consumer,
};

pub const GameView = struct {
    allocator: std.mem.Allocator,
    /// `null` until `attach` opens a consumer. Tagged by transport mode.
    consumer: ?ConsumerMode = null,
    /// Owned (allocator-allocated, NUL-terminated) duplicate of the
    /// shm_name passed to `attach`. Both consumer variants stash a
    /// copy of the name internally; we keep our own as the long-lived
    /// backing store so the caller's buffer can be ephemeral.
    owned_shm_name: ?[:0]u8 = null,
    /// GL texture handle for the displayed frame — always
    /// `GL_TEXTURE_2D`, regardless of transport. In shm mode we
    /// `glTexSubImage2D` straight into it; in iosurface mode we FBO-
    /// blit from a `GL_TEXTURE_RECTANGLE` into it.
    tex_id: gl.Uint = 0,
    tex_w: u32 = 0,
    tex_h: u32 = 0,
    /// iosurface mode: one rectangle texture per ring slot, pre-bound
    /// to its IOSurface via `CGLTexImageIOSurface2D`. The binding is
    /// "live" — producer writes become visible automatically; we
    /// rebind the source FBO each frame to pick up the new pixels.
    /// All slots are 0 in shm mode.
    rect_tex_ids: [iosurface.MAX_RING]gl.Uint = [_]gl.Uint{0} ** iosurface.MAX_RING,
    /// iosurface mode: ring size captured at attach. 0 in shm mode.
    /// Bounded by `iosurface.MAX_RING` upstream of here.
    rect_count: u32 = 0,
    /// iosurface mode: source-side FBO. Read attachment rotates per
    /// frame onto the slot's rectangle texture. 0 in shm mode.
    read_fbo: gl.Uint = 0,
    /// iosurface mode: destination-side FBO. Pre-attached at `attach`
    /// to `tex_id`; never re-attached. 0 in shm mode.
    draw_fbo: gl.Uint = 0,
    /// `null` before the first frame is uploaded; the frame_idx of
    /// the texture's current contents once a frame has been seen.
    /// Optional so a producer frame_idx of 0 doesn't collide with
    /// the "no frame received yet" sentinel — drops would otherwise
    /// undercount on the very first frame of a session (#111
    /// review). Test code reads this to assert "the editor is
    /// presenting new frames" without ever inspecting pixels (the
    /// zgui binding doesn't expose `ImGuiTestEngine_CaptureScreenshot`).
    last_frame_idx: ?u64 = null,
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

    /// Open the named region the engine advertised and stand up a
    /// matching `GL_TEXTURE_2D`. `format` is the `frame_offer.format`
    /// field (typically `"bgra8"` or `"iosurface_bgra8"`); an empty
    /// or unrecognised value falls back to the SHM CPU upload path.
    ///
    /// The GL context must be current on the calling thread (which it
    /// always is on the main thread for labelle-gui's frame loop).
    pub fn attach(self: *Self, shm_name: []const u8, format: []const u8) AttachError!void {
        // Auto-detach any prior session — the engine emits a fresh
        // `frame_offer` on resize / restart, and forcing the caller
        // to manually detach first would block routine resolution
        // changes (#111 review).
        if (self.consumer != null) self.detach();

        const owned = self.allocator.dupeZ(u8, shm_name) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);

        // Dispatch on the engine-advertised format. Non-macOS hosts
        // ignore `iosurface_bgra8` and fall back to SHM so a mixed
        // engine/editor pair doesn't deadlock — the engine producer
        // returns `error.PlatformUnsupported` if it can't build the
        // surface ring, so an iosurface-mode offer should only arrive
        // on macOS in practice. The fallback is belt-and-braces.
        const want_iosurface = std.mem.eql(u8, format, "iosurface_bgra8") and builtin.os.tag == .macos;

        if (want_iosurface) {
            try self.attachIosurface(owned);
        } else {
            try self.attachShm(owned);
        }
        self.owned_shm_name = owned;
        self.last_frame_idx = null;
        self.last_latency_ns = 0;
        self.dropped = 0;
        self.presented = 0;
        self.latency_head = 0;
        self.latency_count = 0;
    }

    fn attachShm(self: *Self, owned: [:0]u8) AttachError!void {
        var consumer = try shm.Consumer.init(owned);
        errdefer consumer.deinit();

        const w = consumer.header.width;
        const h = consumer.header.height;

        // Build a zero-initialized texture; per-frame uploads will
        // `glTexSubImage2D` into it. `GL_RGBA8` matches the SHM's
        // RGBA8 pixel format. `GL_CLAMP_TO_EDGE` avoids edge-bleed
        // when the panel renders the texture at a non-integer scale.
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

        self.consumer = .{ .shm = consumer };
        self.tex_id = tex;
        self.tex_w = w;
        self.tex_h = h;
    }

    fn attachIosurface(self: *Self, owned: [:0]u8) AttachError!void {
        // Non-macOS shouldn't reach here (`attach` gates on
        // `builtin.os.tag == .macos`), but the consumer init itself
        // guards too — returns `error.PlatformUnsupported` which
        // bubbles up through `AttachError`.
        var consumer = try iosurface.Consumer.init(owned);
        errdefer consumer.deinit();

        const w = consumer.width;
        const h = consumer.height;
        const ring = consumer.ring_size;

        // Destination GL_TEXTURE_2D — the handle imgui_impl_opengl3
        // ultimately samples. Per-frame FBO blit fills it from the
        // rectangle texture matching the freshest IOSurface slot.
        var tex: gl.Uint = 0;
        gl.genTextures(1, &tex);
        errdefer {
            if (tex != 0) gl.deleteTextures(1, &tex);
        }
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

        // One GL_TEXTURE_RECTANGLE per ring slot, each pre-bound to
        // its IOSurface. Stays bound for the consumer's lifetime —
        // producer pixel writes become visible automatically because
        // `CGLTexImageIOSurface2D` keeps the surface ↔ texture link
        // live. Caller's per-frame `poll` only rebinds the FBO's
        // source attachment to pick the current slot.
        var rect_tex_ids: [iosurface.MAX_RING]gl.Uint = [_]gl.Uint{0} ** iosurface.MAX_RING;
        var created: u32 = 0;
        errdefer {
            var i: u32 = 0;
            while (i < created) : (i += 1) {
                if (rect_tex_ids[i] != 0) gl.deleteTextures(1, &rect_tex_ids[i]);
            }
        }
        while (created < ring) : (created += 1) {
            gl.genTextures(1, &rect_tex_ids[created]);
            gl.bindTexture(iosurface.GL_TEXTURE_RECTANGLE, rect_tex_ids[created]);
            gl.texParameteri(iosurface.GL_TEXTURE_RECTANGLE, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
            gl.texParameteri(iosurface.GL_TEXTURE_RECTANGLE, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
            gl.texParameteri(iosurface.GL_TEXTURE_RECTANGLE, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
            gl.texParameteri(iosurface.GL_TEXTURE_RECTANGLE, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
            const surf = consumer.surfaceAt(created);
            const rc = iosurface.bindSurface(surf, w, h);
            if (rc != 0) {
                std.log.warn("iosurface: CGLTexImageIOSurface2D slot={d} rc={d}", .{ created, rc });
                return error.IosurfaceGlBindFailed;
            }
        }
        gl.bindTexture(iosurface.GL_TEXTURE_RECTANGLE, 0);

        // FBOs: pre-create both, pre-attach the destination 2D
        // texture; the source attachment rotates per frame in `poll`.
        var read_fbo: gl.Uint = 0;
        var draw_fbo: gl.Uint = 0;
        gl.genFramebuffers(1, &read_fbo);
        errdefer {
            if (read_fbo != 0) gl.deleteFramebuffers(1, &read_fbo);
        }
        gl.genFramebuffers(1, &draw_fbo);
        errdefer {
            if (draw_fbo != 0) gl.deleteFramebuffers(1, &draw_fbo);
        }
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, draw_fbo);
        gl.framebufferTexture2D(gl.DRAW_FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex, 0);
        const status = gl.checkFramebufferStatus(gl.DRAW_FRAMEBUFFER);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, 0);
        if (status != gl.FRAMEBUFFER_COMPLETE) {
            std.log.warn("iosurface: draw_fbo incomplete: 0x{x}", .{status});
            return error.IosurfaceGlBindFailed;
        }

        self.consumer = .{ .iosurface = consumer };
        self.tex_id = tex;
        self.tex_w = w;
        self.tex_h = h;
        self.rect_tex_ids = rect_tex_ids;
        self.rect_count = ring;
        self.read_fbo = read_fbo;
        self.draw_fbo = draw_fbo;
    }

    /// Tear down the consumer + GL texture. Safe to call when not
    /// attached; called by `deinit`.
    pub fn detach(self: *Self) void {
        if (self.consumer) |*c| {
            switch (c.*) {
                .shm => |*sc| sc.deinit(),
                .iosurface => |*ic| ic.deinit(),
            }
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
        // iosurface auxiliary state — no-ops in shm mode (handles are 0).
        var i: u32 = 0;
        while (i < self.rect_count) : (i += 1) {
            if (self.rect_tex_ids[i] != 0) {
                gl.deleteTextures(1, &self.rect_tex_ids[i]);
                self.rect_tex_ids[i] = 0;
            }
        }
        self.rect_count = 0;
        if (self.read_fbo != 0) {
            gl.deleteFramebuffers(1, &self.read_fbo);
            self.read_fbo = 0;
        }
        if (self.draw_fbo != 0) {
            gl.deleteFramebuffers(1, &self.draw_fbo);
            self.draw_fbo = 0;
        }
        self.tex_w = 0;
        self.tex_h = 0;
    }

    pub fn isAttached(self: *const Self) bool {
        return self.consumer != null;
    }

    /// Poll the active consumer for a newer frame. If one is available,
    /// either `glTexSubImage2D` (shm) or FBO-blit (iosurface) it onto
    /// `tex_id` and update the stats. Call once per editor frame from
    /// the main loop.
    ///
    /// Returns true when a new frame was uploaded — handy for tests
    /// + future "redraw only on new frame" optimization.
    pub fn poll(self: *Self) bool {
        const consumer_ptr = if (self.consumer) |*c| c else return false;
        return switch (consumer_ptr.*) {
            .shm => |*sc| self.pollShm(sc),
            .iosurface => |*ic| self.pollIosurface(ic),
        };
    }

    fn pollShm(self: *Self, consumer: *shm.Consumer) bool {
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

        self.recordFrameStats(frame.frame_idx, frame.produce_ns);
        return true;
    }

    fn pollIosurface(self: *Self, consumer: *iosurface.Consumer) bool {
        const frame = consumer.latest() orelse return false;
        if (frame.slot >= self.rect_count) return false;

        // Per Apple's CGLTexImageIOSurface2D contract: rebind the source
        // texture before sampling so the GL driver picks up the
        // producer's most recent IOSurface writes.
        gl.bindTexture(iosurface.GL_TEXTURE_RECTANGLE, self.rect_tex_ids[frame.slot]);

        // FBO blit: source = the slot's rectangle texture, dest = our
        // GL_TEXTURE_2D `tex_id`. One GPU-side copy, no CPU upload —
        // necessary because `imgui_impl_opengl3` hardcodes
        // `glBindTexture(GL_TEXTURE_2D, ...)` and won't sample a
        // RECTANGLE target directly. Pattern lifted verbatim from
        // `imgui-preview-poc/src/editor.zig` (validated at 1080p+).
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, self.read_fbo);
        gl.framebufferTexture2D(
            gl.READ_FRAMEBUFFER,
            gl.COLOR_ATTACHMENT0,
            iosurface.GL_TEXTURE_RECTANGLE,
            self.rect_tex_ids[frame.slot],
            0,
        );
        gl.readBuffer(gl.COLOR_ATTACHMENT0);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, self.draw_fbo);
        gl.drawBuffer(gl.COLOR_ATTACHMENT0);
        gl.blitFramebuffer(
            0,
            0,
            @intCast(frame.width),
            @intCast(frame.height),
            0,
            0,
            @intCast(frame.width),
            @intCast(frame.height),
            gl.COLOR_BUFFER_BIT,
            gl.NEAREST,
        );
        gl.bindFramebuffer(gl.READ_FRAMEBUFFER, 0);
        gl.bindFramebuffer(gl.DRAW_FRAMEBUFFER, 0);
        gl.bindTexture(iosurface.GL_TEXTURE_RECTANGLE, 0);

        self.recordFrameStats(frame.frame_idx, frame.produce_ns);
        return true;
    }

    /// Bookkeeping shared between the two upload paths: drop count,
    /// latency ring, presented counter.
    fn recordFrameStats(self: *Self, frame_idx: u64, produce_ns: u64) void {
        // Drop accounting: count producer frames we skipped between
        // the previous frame and this one. First frame after attach
        // (`last_frame_idx == null`) sets the counter but doesn't
        // count gaps — we have no prior baseline.
        if (self.last_frame_idx) |prior| {
            if (frame_idx > prior + 1) {
                self.dropped += frame_idx - prior - 1;
            }
        }
        self.last_frame_idx = frame_idx;

        const now_ns = shm.nowNs();
        if (now_ns > produce_ns) {
            self.last_latency_ns = now_ns - produce_ns;
            self.latency_ring[self.latency_head] = self.last_latency_ns;
            self.latency_head = (self.latency_head + 1) % latency_ring_capacity;
            if (self.latency_count < latency_ring_capacity) self.latency_count += 1;
        }
        self.presented += 1;
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
