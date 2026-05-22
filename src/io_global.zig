const std = @import("std");
const builtin = @import("builtin");

/// Process-wide Io handle used by helpers that historically used
/// `std.fs.cwd()` (which was removed in Zig 0.16). Initialized from
/// `main()` via `init()` so the underlying Threaded impl sees the real
/// environment. Mirrors the pattern in labelle-cli's cli/config.zig.
///
/// Under `zig build test`, `std.testing.io` is used instead and `init`
/// is unnecessary.
var _global_threaded: std.Io.Threaded = undefined;
var _global_io: std.Io = undefined;
var _global_environ: std.process.Environ = .empty;
var _initialized: bool = false;

/// Initialize the process-wide Io. Must be called once from `main()`
/// before any helper invokes `io()`.
pub fn init(minimal: std.process.Init.Minimal) void {
    _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .init(minimal.args),
        .environ = minimal.environ,
    });
    _global_io = _global_threaded.io();
    _global_environ = minimal.environ;
    _initialized = true;
}

/// Lazy fallback used when neither `init()` nor the testing harness has
/// produced an `Io` yet. Creates a Threaded instance with empty
/// argv/environ.
fn initLazy() void {
    _global_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    _global_io = _global_threaded.io();
    _initialized = true;
}

pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;
    if (!_initialized) initLazy();
    return _global_io;
}

pub fn environ() std.process.Environ {
    if (!_initialized) initLazy();
    return _global_environ;
}

/// Monotonic counter so two atomic writes racing inside the same
/// process (or the same wall-clock nanosecond) never pick the same
/// temp-file name.
var _atomic_counter: std.atomic.Value(u64) = .init(0);

/// Write `data` to `path` atomically: render into a temporary file in
/// the *same directory* as `path`, then rename that temp file over
/// `path`. POSIX `rename` (and the Windows equivalent the stdlib uses)
/// replaces the destination in a single step, so a crash or I/O error
/// mid-write can only leave either the old file fully intact or the new
/// file fully in place — never a truncated, half-written destination.
///
/// The temp file lives next to `path` (not in `/tmp`) because `rename`
/// is only atomic *within one filesystem*; a temp file on a different
/// mount would force a non-atomic copy.
///
/// On any error before the rename succeeds the temp file is deleted, so
/// a failed save never leaves a stray `.tmp` sibling behind.
///
/// This does NOT create `path`'s parent directory — it matches the
/// plain-`writeFile` behaviour of the callers it replaced.
pub fn writeFileAtomic(
    dir: std.Io.Dir,
    handle: std.Io,
    path: []const u8,
    data: []const u8,
    allocator: std.mem.Allocator,
) !void {
    const dir_part = std.fs.path.dirname(path) orelse ".";
    const base_part = std.fs.path.basename(path);

    // `.<basename>.tmp.<pid>.<counter>` — dot-prefixed so it reads as a
    // hidden sibling, and disambiguated by pid + an in-process counter.
    const seq = _atomic_counter.fetchAdd(1, .monotonic);
    const tmp_name = try std.fmt.allocPrint(
        allocator,
        ".{s}.tmp.{d}.{d}",
        .{ base_part, std.Thread.getCurrentId(), seq },
    );
    defer allocator.free(tmp_name);

    const tmp_path = try std.fs.path.join(allocator, &.{ dir_part, tmp_name });
    defer allocator.free(tmp_path);

    // Write the full payload into the temp file. On any failure delete
    // the temp file so no stray `.tmp` is left behind.
    {
        errdefer dir.deleteFile(handle, tmp_path) catch {};
        try dir.writeFile(handle, .{ .sub_path = tmp_path, .data = data });
    }

    // Atomically swap the temp file into place. If the rename itself
    // fails, the temp file is still on disk — clean it up.
    errdefer dir.deleteFile(handle, tmp_path) catch {};
    try dir.rename(tmp_path, dir, path, handle);
}
