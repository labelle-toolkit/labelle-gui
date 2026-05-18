//! User-scoped preferences for labelle-gui.
//!
//! Persisted as a small ZON file in the platform-specific app-data dir:
//!
//!   - macOS:   `~/Library/Application Support/labelle-gui/preferences.zon`
//!   - Linux:   `~/.local/share/labelle-gui/preferences.zon`
//!   - Windows: `%LOCALAPPDATA%\labelle-gui\preferences.zon`
//!
//! Read once at startup (via `loadOrDefault`) and re-written whenever the
//! Preferences dialog changes a value. The application reads the file's
//! `font_scale` to size the ImGui font atlas at startup; the atlas isn't
//! rebuilt mid-session, so changes take effect on next launch — matching
//! the existing DPI-change UX (see `dialogs/dpi_warning.zig`).
//!
//! Robust to a missing or malformed file: `loadOrDefault` always returns
//! a `Preferences` value, defaulting unknown / invalid fields. A bad file
//! is logged and overwritten the next time `save` is called, so manual
//! editing mistakes are self-healing.

const std = @import("std");
const builtin = @import("builtin");
const io_global = @import("io_global.zig");

pub const APP_DATA_NAME = "labelle-gui";
pub const PREFS_FILENAME = "preferences.zon";

/// Bounds for the user-controlled scaler. Clamped on both load and save
/// so a hand-edited file with `font_scale = 99.0` can't push the font
/// off the screen, and a `0.1` won't render unreadably small.
pub const min_font_scale: f32 = 0.5;
pub const max_font_scale: f32 = 3.0;
/// Default applied on first launch and by the "Reset to default" button.
/// `1.5` is the readable baseline on the displays the team uses; the
/// legacy `1.0` rendered too small at default DPI on most external
/// monitors.
pub const default_font_scale: f32 = 1.5;

/// Bounds for the editor inspector-column width. The lower bound keeps
/// the inspector usable (input fields stay readable); the upper bound
/// stops a malformed file from hiding the viewport entirely. Per-tab
/// clamping in the splitter handler also enforces a viewport-side
/// minimum so the two never fight.
pub const min_inspector_width: f32 = 200;
pub const max_inspector_width: f32 = 800;
/// Default applied on first launch and to fresh tabs when no
/// user-chosen width has been saved yet. Matches the previous
/// hardcoded value so the visual remains unchanged on first open.
pub const default_inspector_width: f32 = 300;

pub const Preferences = struct {
    /// Multiplier applied on top of the DPI-derived font size at
    /// startup. Larger values produce bigger text. The ImGui atlas is
    /// sized at startup so a change requires a restart to take effect.
    font_scale: f32 = default_font_scale,
    /// Width in pixels of the inspector column in the scene / prefab
    /// editor tabs. Updated when the user drags the splitter; new
    /// tabs read this on open so the chosen width persists across
    /// editor restarts (#140). Each open tab keeps its own copy so
    /// in-session drags don't reflow other tabs.
    inspector_width: f32 = default_inspector_width,
};

/// Replacement for `std.fs.getAppDataDir` which was removed in 0.16.
/// Reads the same platform-specific environment variables and returns
/// an absolute path joined with the application name.
fn getAppDataDir(allocator: std.mem.Allocator, appname: []const u8) ![]u8 {
    const env = io_global.environ();
    switch (builtin.os.tag) {
        .windows => {
            const local_app_data = env.getAlloc(allocator, "LOCALAPPDATA") catch return error.AppDataDirUnavailable;
            defer allocator.free(local_app_data);
            return std.fs.path.join(allocator, &.{ local_app_data, appname });
        },
        .macos, .ios, .tvos, .watchos, .visionos => {
            const home = env.getAlloc(allocator, "HOME") catch return error.AppDataDirUnavailable;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", appname });
        },
        else => {
            if (env.getAlloc(allocator, "XDG_DATA_HOME") catch null) |xdg| {
                defer allocator.free(xdg);
                if (xdg.len > 0) {
                    return std.fs.path.join(allocator, &.{ xdg, appname });
                }
            }
            const home = env.getAlloc(allocator, "HOME") catch return error.AppDataDirUnavailable;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".local", "share", appname });
        },
    }
}

/// Return the absolute path to the preferences file. Caller owns the
/// returned slice. The parent directory is NOT created — `save` does
/// that lazily so the read path stays fast on the common case where the
/// directory already exists.
pub fn pathOwned(allocator: std.mem.Allocator) ![]u8 {
    const dir = try getAppDataDir(allocator, APP_DATA_NAME);
    defer allocator.free(dir);
    return std.fs.path.join(allocator, &.{ dir, PREFS_FILENAME });
}

/// Load preferences from disk, falling back to defaults on any error
/// (file missing, parse failure, unreadable directory, etc.). Logs the
/// underlying error at `info` level on missing-file (expected first
/// run) and `warn` for everything else.
pub fn loadOrDefault(allocator: std.mem.Allocator) Preferences {
    const path = pathOwned(allocator) catch |err| {
        std.log.warn("prefs: could not resolve preferences path: {s}", .{@errorName(err)});
        return .{};
    };
    defer allocator.free(path);

    return loadFromPath(allocator, path);
}

/// Path-injectable variant of `loadOrDefault`. Used by tests to point
/// at a temp file; production callers go through `loadOrDefault`. The
/// path must be absolute — `getAppDataDir` returns one, and tests
/// build one from `realpathAlloc`.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) Preferences {
    const io = io_global.io();
    const raw = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 14)) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("prefs: no preferences file at {s}; using defaults", .{path});
        } else {
            std.log.warn("prefs: could not read {s}: {s}", .{ path, @errorName(err) });
        }
        return .{};
    };
    defer allocator.free(raw);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src = a.dupeZ(u8, raw) catch return .{};

    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(a);
    const parsed = std.zon.parse.fromSlice(Preferences, a, src, &diag, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        std.log.warn("prefs: parse {s} failed: {s} — using defaults", .{ path, @errorName(err) });
        return .{};
    };

    return .{
        .font_scale = std.math.clamp(parsed.font_scale, min_font_scale, max_font_scale),
        .inspector_width = std.math.clamp(parsed.inspector_width, min_inspector_width, max_inspector_width),
    };
}

/// Persist `prefs` to disk, creating the parent directory if needed.
/// Clamps `font_scale` to the documented bounds before writing so the
/// next read is self-healing.
pub fn save(allocator: std.mem.Allocator, prefs: Preferences) !void {
    const io = io_global.io();
    const dir = try getAppDataDir(allocator, APP_DATA_NAME);
    defer allocator.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const path = try std.fs.path.join(allocator, &.{ dir, PREFS_FILENAME });
    defer allocator.free(path);

    try saveToPath(allocator, path, prefs);
}

/// Path-injectable variant of `save`. The parent directory must already
/// exist; production callers go through `save` which createDirPath's first.
///
/// Writes atomically: emits to `<path>.tmp` first, then renames over the
/// real path. A crash mid-write leaves the previous-good preferences
/// intact (or no file at all on first run) rather than corrupting the
/// real file (gemini #72 medium).
pub fn saveToPath(allocator: std.mem.Allocator, path: []const u8, prefs: Preferences) !void {
    const clamped: Preferences = .{
        .font_scale = std.math.clamp(prefs.font_scale, min_font_scale, max_font_scale),
        .inspector_width = std.math.clamp(prefs.inspector_width, min_inspector_width, max_inspector_width),
    };

    // Hand-rolled emission keeps the file readable and avoids pulling in
    // `std.zon.stringify`'s broader formatting choices. Tiny fixed
    // schema; grows by hand if a new field lands.
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf,
        \\.{{
        \\    .font_scale = {d},
        \\    .inspector_width = {d},
        \\}}
        \\
    , .{ clamped.font_scale, clamped.inspector_width });

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const io = io_global.io();
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = tmp_path,
        .data = body,
    });
    const cwd = std.Io.Dir.cwd();
    try cwd.rename(tmp_path, cwd, path, io);
}
