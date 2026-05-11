//! Tiny buffer helpers shared across the panel modules. Centralized
//! so the same trivial "write a string into a sentinel-terminated
//! buffer" operation isn't reimplemented in every editor.

const std = @import("std");

/// Zero `dst`, then copy up to `dst.len` bytes from `src`. Designed
/// for writing into a `[N:0]u8` edit buffer — the trailing zeros from
/// the memset preserve the sentinel and clear stale tail bytes left
/// over from a longer previous value.
pub fn writeZeroed(dst: []u8, src: []const u8) void {
    @memset(dst, 0);
    const n = @min(dst.len, src.len);
    @memcpy(dst[0..n], src[0..n]);
}
