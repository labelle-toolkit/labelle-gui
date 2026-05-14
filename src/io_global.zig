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
