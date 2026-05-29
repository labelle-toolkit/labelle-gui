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

/// Append `chunk` to a rolling tail buffer, dropping from the front
/// when the result would exceed `cap`. Optional `cursor` is a
/// consumer-side read offset that gets shifted by the same amount
/// the front drops, so a paired (producer-here, consumer-elsewhere)
/// can keep emitting new bytes after a rotation instead of
/// re-emitting the survivors.
///
/// Behaviour summary:
///   - `chunk.len == 0`: no-op.
///   - `chunk.len >= cap`: clear `buf` and keep the tail of `chunk`
///     (the latest `cap` bytes). `cursor.*` resets to 0.
///   - `buf.len + chunk.len > cap`: drop just enough bytes from the
///     front to fit, copy the survivors forward in place, shift
///     `cursor.*` by the drop count (clamped to 0).
///   - Append `chunk` to whatever's left.
///
/// Allocation failures are silently dropped — same trade-off the
/// pre-refactor inline copies made (see #139 nit 4). Caller is
/// expected to have its own bounded retry path if it cares.
pub fn appendCapped(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    chunk: []const u8,
    cap: usize,
    cursor: ?*usize,
) void {
    if (chunk.len == 0) return;
    if (chunk.len >= cap) {
        list.clearRetainingCapacity();
        const tail_off = chunk.len - cap;
        list.appendSlice(allocator, chunk[tail_off..]) catch return;
        if (cursor) |c| c.* = 0;
        return;
    }
    if (list.items.len + chunk.len > cap) {
        const overflow = list.items.len + chunk.len - cap;
        const drop = @min(overflow, list.items.len);
        const remaining = list.items.len - drop;
        std.mem.copyForwards(u8, list.items[0..remaining], list.items[drop..]);
        list.shrinkRetainingCapacity(remaining);
        if (cursor) |c| {
            c.* = if (c.* > drop) c.* - drop else 0;
        }
    }
    list.appendSlice(allocator, chunk) catch return;
}

const testing = std.testing;

test "appendCapped no-op on empty chunk" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "abc");
    appendCapped(&list, testing.allocator, "", 100, null);
    try testing.expectEqualStrings("abc", list.items);
}

test "appendCapped fits within cap" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    appendCapped(&list, testing.allocator, "hello", 100, null);
    try testing.expectEqualStrings("hello", list.items);
}

test "appendCapped drops front when overflow" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "abcdefgh");
    appendCapped(&list, testing.allocator, "XYZ", 10, null); // 8+3 > 10 → drop 1
    try testing.expectEqualStrings("bcdefghXYZ", list.items);
}

test "appendCapped giant chunk keeps only the tail" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "old");
    appendCapped(&list, testing.allocator, "0123456789ABCDEF", 4, null);
    try testing.expectEqualStrings("CDEF", list.items);
}

test "appendCapped shifts cursor by drop amount" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "abcdefgh"); // len=8
    var cursor: usize = 5;
    appendCapped(&list, testing.allocator, "XYZ", 10, &cursor); // drop 1
    try testing.expectEqual(@as(usize, 4), cursor);
}

test "appendCapped resets cursor to 0 on giant chunk" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    var cursor: usize = 3;
    appendCapped(&list, testing.allocator, "0123456789", 4, &cursor);
    try testing.expectEqual(@as(usize, 0), cursor);
}

test "appendCapped clamps cursor to 0 when drop exceeds cursor" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);
    try list.appendSlice(testing.allocator, "abcdefgh");
    var cursor: usize = 2;
    appendCapped(&list, testing.allocator, "XYZ", 10, &cursor); // drop=1, cursor=2 → 1
    try testing.expectEqual(@as(usize, 1), cursor);
    // And a bigger drop that exceeds the cursor:
    appendCapped(&list, testing.allocator, "PPP", 10, &cursor); // drop=3, cursor=1 → 0
    try testing.expectEqual(@as(usize, 0), cursor);
}
