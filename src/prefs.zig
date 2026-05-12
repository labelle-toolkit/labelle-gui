//! User-scoped preferences for labelle-gui.
//!
//! Persisted as a small ZON file in the platform-specific app-data dir
//! resolved by `std.fs.getAppDataDir`:
//!
//!   - macOS:   `~/Library/Application Support/labelle-gui/preferences.zon`
//!   - Linux:   `~/.config/labelle-gui/preferences.zon`
//!   - Windows: `%APPDATA%\labelle-gui\preferences.zon`
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

pub const Preferences = struct {
    /// Multiplier applied on top of the DPI-derived font size at
    /// startup. Larger values produce bigger text. The ImGui atlas is
    /// sized at startup so a change requires a restart to take effect.
    font_scale: f32 = default_font_scale,
};

/// Return the absolute path to the preferences file. Caller owns the
/// returned slice. The parent directory is NOT created — `save` does
/// that lazily so the read path stays fast on the common case where the
/// directory already exists.
pub fn pathOwned(allocator: std.mem.Allocator) ![]u8 {
    const dir = try std.fs.getAppDataDir(allocator, APP_DATA_NAME);
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
/// at a temp file; production callers go through `loadOrDefault`.
pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) Preferences {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("prefs: no preferences file at {s}; using defaults", .{path});
        } else {
            std.log.warn("prefs: could not open {s}: {s}", .{ path, @errorName(err) });
        }
        return .{};
    };
    defer file.close();

    const max_bytes: usize = 1 << 14; // 16 KiB — preferences are tiny.
    const raw = file.readToEndAlloc(allocator, max_bytes) catch |err| {
        std.log.warn("prefs: read {s} failed: {s}", .{ path, @errorName(err) });
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
    };
}

/// Persist `prefs` to disk, creating the parent directory if needed.
/// Clamps `font_scale` to the documented bounds before writing so the
/// next read is self-healing.
pub fn save(allocator: std.mem.Allocator, prefs: Preferences) !void {
    const dir = try std.fs.getAppDataDir(allocator, APP_DATA_NAME);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try std.fs.path.join(allocator, &.{ dir, PREFS_FILENAME });
    defer allocator.free(path);

    try saveToPath(path, prefs);
}

/// Path-injectable variant of `save`. The parent directory must already
/// exist; production callers go through `save` which makePath's first.
pub fn saveToPath(path: []const u8, prefs: Preferences) !void {
    const clamped: Preferences = .{
        .font_scale = std.math.clamp(prefs.font_scale, min_font_scale, max_font_scale),
    };

    // Hand-rolled emission keeps the file readable and avoids pulling in
    // `std.zon.stringify`'s broader formatting choices. We only have one
    // field and the format is dirt-simple.
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf,
        \\.{{
        \\    .font_scale = {d},
        \\}}
        \\
    , .{clamped.font_scale});

    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);
}

