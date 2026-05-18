//! macOS IOSurface-backed pixel ring consumer for the PIE viewport
//! (#108 — Phase 2 zero-copy fast path).
//!
//! The engine's iosurface producer (engine follow-up to #544; see
//! `imgui-preview-poc/src/iosurface.zig` for the reference) allocates
//! N `IOSurfaceRef` objects up front, lists their `IOSurfaceID`s in a
//! `ControlBlock` written into slot 0 of the existing
//! `preview_shm.Producer` ring, and per frame just updates the
//! ring's `Header.latest`. The editor:
//!
//!   1. opens the shm region as a normal `preview_shm.Consumer`,
//!   2. reads the ControlBlock and `IOSurfaceLookup`s each surface,
//!   3. binds each surface to a `GL_TEXTURE_RECTANGLE` once at
//!      startup via `CGLTexImageIOSurface2D`,
//!   4. per frame: reads `header.latest` to pick the slot, blits
//!      the matching RECTANGLE texture into a `GL_TEXTURE_2D` (the
//!      texture ImGui samples — `imgui_impl_opengl3.cpp:660`
//!      hardcodes `glBindTexture(GL_TEXTURE_2D, ...)`, so we can't
//!      pass the RECTANGLE handle directly to `zgui.image`).
//!
//! This saves the `glTexSubImage2D` upload that dominates the
//! consumer-side cost in SHM mode at 1080p+. Validated end-to-end in
//! `imgui-preview-poc/`; that experiment also documented the major
//! sharp edges this module inherits:
//!
//!   - `IOSurfaceLookup(id)` returns null across processes unless the
//!     producer either sets `kIOSurfaceIsGlobal = true` (deprecated/
//!     insecure shortcut — what's used in-tree for now) or hands off
//!     a mach port via `IOSurfaceCreateMachPort` + `bootstrap_check_in`.
//!     SCM_RIGHTS over Unix sockets does **not** carry mach ports.
//!     Mach-port hand-off is a follow-up; the consumer side already
//!     declares the externs for when that lands.
//!   - Pixel format is BGRA8 (lingua franca for `CGLTexImageIOSurface2D`).
//!     The engine producer's GL readback is RGBA, so it does a
//!     per-pixel swizzle; the editor just samples what's there.
//!   - macOS-only. On other platforms this module compiles to a
//!     stub-only shape — every public API returns
//!     `error.PlatformUnsupported`. The Game View module silently
//!     falls back to SHM mode if the engine offers iosurface format
//!     on a non-macOS editor.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine");
const shm = engine.preview_mode_mod.preview_shm;

pub const Error = error{
    PlatformUnsupported,
    ControlBlockMissing,
    RingSizeOutOfRange,
    PixelFormatMismatch,
    IOSurfaceLookupFailed,
} || shm.Error;

// ── CoreFoundation / IOSurface externs (macOS only) ───────────────

pub const IOSurfaceRef = ?*opaque {};
pub const CFTypeRef = ?*anyopaque;
pub const IOSurfaceID = u32;
pub const IOReturn = c_int;
pub const MachPort = u32;

/// 'BGRA' four-CC — what `CGLTexImageIOSurface2D` expects.
pub const kPixelFormat_BGRA8: u32 = 0x42475241;

pub const kIOSurfaceLockReadOnly: u32 = 0x1;
pub const kIOSurfaceLockAvoidSync: u32 = 0x2;

pub extern "c" fn IOSurfaceLookup(csid: IOSurfaceID) IOSurfaceRef;
pub extern "c" fn IOSurfaceLookupFromMachPort(port: MachPort) IOSurfaceRef;
pub extern "c" fn IOSurfaceGetWidth(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetHeight(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetBytesPerRow(buffer: IOSurfaceRef) usize;
pub extern "c" fn IOSurfaceGetSeed(buffer: IOSurfaceRef) u32;
pub extern "c" fn IOSurfaceLock(buffer: IOSurfaceRef, options: u32, seed: ?*u32) IOReturn;
pub extern "c" fn IOSurfaceUnlock(buffer: IOSurfaceRef, options: u32, seed: ?*u32) IOReturn;

pub extern "c" fn CFRelease(cf: CFTypeRef) void;

/// CGL GL/IOSurface interop. Requires `GL_TEXTURE_RECTANGLE_ARB` as the
/// target — the rectangle binding lives in `CGLIOSurface.h`. Internal
/// format must be `GL_RGBA`; pixel format combo for BGRA IOSurfaces is
/// `(GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV)`.
pub extern "c" fn CGLTexImageIOSurface2D(
    ctx: ?*anyopaque,
    target: c_uint,
    internal_format: c_int,
    width: c_int,
    height: c_int,
    format: c_uint,
    @"type": c_uint,
    ioSurface: IOSurfaceRef,
    plane: c_uint,
) c_int;
pub extern "c" fn CGLGetCurrentContext() ?*anyopaque;

// GL_TEXTURE_RECTANGLE / pixel-type constants — zopengl 3.3-core
// doesn't expose `GL_TEXTURE_RECTANGLE_ARB` (it's a 3.1+ extension)
// nor the matching `GL_UNSIGNED_INT_8_8_8_8_REV` pixel type for BGRA
// IOSurfaces, so name them locally.
pub const GL_TEXTURE_RECTANGLE: c_uint = 0x84F5;
pub const GL_UNSIGNED_INT_8_8_8_8_REV: c_uint = 0x8367;
pub const GL_BGRA: c_uint = 0x80E1;
pub const GL_RGBA: c_int = 0x1908;

/// Maximum supported ring size — matches the PoC. The protocol's
/// `ring_size` is bounded by this and the editor refuses larger.
pub const MAX_RING: u32 = 8;

/// Header written into the first shm slot's pixel area by the engine
/// producer (engine follow-up). Editor reads once at startup and then
/// only consults `Header.latest` per frame.
pub const ControlBlock = extern struct {
    magic: u64,
    ring_size: u32,
    pixel_format: u32,
    width: u32,
    height: u32,
    ids: [MAX_RING]IOSurfaceID,
    _pad: [16]u8 = [_]u8{0} ** 16,

    /// 'IOSRFCL1' — matches the PoC's ControlBlock.MAGIC. Bumping is
    /// a protocol break with the engine producer; coordinate.
    pub const MAGIC: u64 = 0x494F535246434C31;
};

comptime {
    std.debug.assert(@sizeOf(ControlBlock) == 24 + MAX_RING * 4 + 16);
}

// ── Consumer ───────────────────────────────────────────────────────

pub const Frame = struct {
    surface: IOSurfaceRef,
    slot: u32,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    frame_idx: u64,
    produce_ns: u64,
};

pub const Consumer = struct {
    shm_consumer: shm.Consumer,
    surfaces: [MAX_RING]IOSurfaceRef = [_]IOSurfaceRef{null} ** MAX_RING,
    ring_size: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    bytes_per_row: u32 = 0,
    /// Snapshot of `shm_consumer.header.slot_size` taken at init.
    /// Reading it once and stashing it locally protects `latest()`
    /// from a producer that mutates the shared header — the same
    /// TOCTOU class as `ring_size`. Computing `slot_base` from a
    /// racing slot_size could land the trailer pointer outside the
    /// mapped region (#115 review).
    slot_size: usize = 0,
    last_seen_frame: u64 = 0,

    /// Open the shm region the engine advertised, read its
    /// ControlBlock, lookup each IOSurface. Caller (typically the
    /// GameView module) creates `ring_size` `GL_TEXTURE_RECTANGLE`s
    /// and calls `bindSurface` for each.
    pub fn init(shm_name: [:0]const u8) Error!Consumer {
        if (builtin.os.tag != .macos) return error.PlatformUnsupported;

        var sc = try shm.Consumer.init(shm_name);
        errdefer sc.deinit();

        const ctrl: *const ControlBlock = @ptrCast(@alignCast(sc.base + @sizeOf(shm.Header)));
        if (@atomicLoad(u64, @constCast(&ctrl.magic), .acquire) != ControlBlock.MAGIC) {
            return error.ControlBlockMissing;
        }
        // Snapshot the producer-controlled fields once. The shm
        // region is shared with the producer process; a malicious or
        // misbehaving producer could mutate `ring_size` between the
        // bounds check and the lookup loop, leading to an OOB read on
        // `ctrl.ids` (#115 review, security-high TOCTOU). Width/height
        // also get captured so the consumer's view stays consistent
        // across a single attach.
        const ring_size = ctrl.ring_size;
        const width = ctrl.width;
        const height = ctrl.height;
        const pixel_format = ctrl.pixel_format;
        if (ring_size == 0 or ring_size > MAX_RING) return error.RingSizeOutOfRange;
        if (pixel_format != kPixelFormat_BGRA8) return error.PixelFormatMismatch;

        var surfaces: [MAX_RING]IOSurfaceRef = [_]IOSurfaceRef{null} ** MAX_RING;
        var looked_up: u32 = 0;
        errdefer {
            var i: u32 = 0;
            while (i < looked_up) : (i += 1) {
                if (surfaces[i]) |s| CFRelease(@ptrCast(s));
            }
        }
        while (looked_up < ring_size) : (looked_up += 1) {
            const id = ctrl.ids[looked_up];
            const ref = IOSurfaceLookup(id) orelse return error.IOSurfaceLookupFailed;
            surfaces[looked_up] = ref;
        }

        // `surfaces[0]` is guaranteed non-null here — the loop above
        // populates indices `[0, ring_size)` (asserted > 0) without
        // breaking. Unwrap explicitly so a future refactor that
        // changes the invariant trips at the `.?` rather than passing
        // null into `IOSurfaceGetBytesPerRow` (#115 review).
        const bpr: u32 = @intCast(IOSurfaceGetBytesPerRow(surfaces[0].?));

        // Snapshot the shm slot_size too — `latest()` uses it to
        // walk to the trailer; a racing producer mutating
        // `header.slot_size` between frames could otherwise put the
        // trailer pointer outside the mmap region (#115 review).
        const slot_size: usize = @intCast(sc.header.slot_size);

        return .{
            .shm_consumer = sc,
            .surfaces = surfaces,
            .ring_size = ring_size,
            .width = width,
            .height = height,
            .bytes_per_row = bpr,
            .slot_size = slot_size,
            .last_seen_frame = 0,
        };
    }

    pub fn deinit(self: *Consumer) void {
        // Same comptime-elimination pattern as `init` and `bindSurface`:
        // without this gate the Linux/Windows analyzer walks the
        // `CFRelease` call and the linker fails with an undefined
        // symbol once any caller exists (PR #124's `GameView.detach`
        // switch arm). The body only ever runs on macOS where
        // `init` would succeed.
        if (builtin.os.tag != .macos) return;
        var i: u32 = 0;
        while (i < self.ring_size) : (i += 1) {
            if (self.surfaces[i]) |s| CFRelease(@ptrCast(s));
            self.surfaces[i] = null;
        }
        self.ring_size = 0;
        self.shm_consumer.deinit();
    }

    /// Returns the IOSurface for slot `i` (caller already created a
    /// GL_TEXTURE_RECTANGLE; calls `CGLTexImageIOSurface2D` to wire
    /// them together once at startup).
    pub fn surfaceAt(self: *const Consumer, slot: u32) IOSurfaceRef {
        return if (slot < self.ring_size) self.surfaces[slot] else null;
    }

    /// Mailbox-style: returns the freshest slot since the last call,
    /// or null if no new frame has been published. The caller renders
    /// the matching pre-bound texture (no pixel copy).
    pub fn latest(self: *Consumer) ?Frame {
        const fc = @atomicLoad(u64, &self.shm_consumer.header.frame_count, .acquire);
        if (fc <= self.last_seen_frame) return null;
        const slot = @atomicLoad(u32, &self.shm_consumer.header.latest, .acquire);
        // Bound against `self.ring_size` (the count captured at
        // `init` time when we looked up IOSurfaces), NOT
        // `shm_consumer.header.ring_size`. The two come from
        // separately-sourced fields in the same shm region and a
        // racing producer could leave header.ring_size > self.ring_size,
        // which would index `self.surfaces` past the populated slots
        // (#115 review, cursor HIGH).
        if (slot >= self.ring_size) return null;

        // The shm slot's pixel area is unused in iosurface mode, but
        // the trailer still carries (frame_idx, produce_ns) so the
        // latency stat path is identical to shm mode.
        // Use the init-time snapshot of slot_size (see field doc)
        // rather than re-reading `header.slot_size` each frame.
        const slot_base = self.shm_consumer.base + @sizeOf(shm.Header) + @as(usize, slot) * self.slot_size;
        const trailer: *const shm.SlotTrailer = @ptrCast(@alignCast(slot_base + self.slot_size - @sizeOf(shm.SlotTrailer)));
        const frame_idx = trailer.frame_idx;
        if (frame_idx <= self.last_seen_frame) return null;
        self.last_seen_frame = frame_idx;

        return .{
            .surface = self.surfaces[slot],
            .slot = slot,
            .width = self.width,
            .height = self.height,
            .bytes_per_row = self.bytes_per_row,
            .frame_idx = frame_idx,
            .produce_ns = trailer.produce_ns,
        };
    }
};

/// Wire an existing GL_TEXTURE_RECTANGLE texture (caller allocated via
/// glGenTextures) to an IOSurface. The texture must be bound to
/// `GL_TEXTURE_RECTANGLE` by the caller before this call. Returns 0
/// on success, non-zero CGL error code on failure (including the
/// "no GL context current" case — `kCGLBadContext == 10001`).
pub fn bindSurface(surface: IOSurfaceRef, width: u32, height: u32) c_int {
    if (builtin.os.tag != .macos) return 1;
    // `CGLGetCurrentContext` returns null when no GL context is
    // current on the calling thread. Passing null into
    // `CGLTexImageIOSurface2D` is undefined behavior; surface the
    // bad-context error explicitly instead (#115 review).
    const ctx = CGLGetCurrentContext() orelse return 10001;
    return CGLTexImageIOSurface2D(
        ctx,
        GL_TEXTURE_RECTANGLE,
        GL_RGBA,
        @intCast(width),
        @intCast(height),
        GL_BGRA,
        GL_UNSIGNED_INT_8_8_8_8_REV,
        surface,
        0,
    );
}
