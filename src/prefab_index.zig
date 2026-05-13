//! Per-project prefab cache. Walks `<project>/prefabs/**/*.jsonc` on
//! project load, parses each via `scene_io.loadPrefabFromFile`, and
//! stores the result keyed by filename stem (the same name the engine
//! uses when a scene entity writes `{ "prefab": "canteen" }`).
//!
//! The viewport uses this so that scene entities referencing a prefab
//! display the prefab's image(s) at their position instead of the
//! generic colored marker. Sprite resolution is recursive: when a
//! prefab itself has no Sprite but has children that do (or that
//! reference further prefabs), those are drawn at their child-position
//! offsets relative to the scene entity's world position.
//!
//! The cache is owned by `App` and bound to a `ProjectManager`
//! `generation`. When the generation bumps (project new/load/close)
//! the cache is invalidated and rebuilt.

const std = @import("std");

const scene_io = @import("scene_io.zig");

/// One cached prefab entry. `path` is owned by the index (heap dup);
/// `loaded` carries its own arena. Both freed by `Index.deinit`.
pub const Entry = struct {
    path: []const u8,
    loaded: scene_io.LoadedPrefab,
};

pub const Index = struct {
    allocator: std.mem.Allocator,
    /// Owns every `Entry.loaded.arena` + `Entry.path` + key string in
    /// `by_name`. `Entry.loaded.deinit` is called for each on
    /// `Index.deinit`.
    entries: std.StringHashMapUnmanaged(Entry) = .{},
    /// `ProjectManager.generation` this index was built against. App
    /// invalidates when the live generation changes.
    generation: u64,

    pub fn deinit(self: *Index) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.loaded.deinit();
            self.allocator.free(entry.value_ptr.path);
            self.allocator.free(entry.key_ptr.*);
        }
        self.entries.deinit(self.allocator);
    }

    /// Returns the cached prefab body by name (filename stem), or
    /// null when the project has no prefab with that name. Kept for
    /// call sites that only care about the parsed body; use
    /// `findEntry` when you also need the source path.
    pub fn find(self: *const Index, name: []const u8) ?*const scene_io.LoadedPrefab {
        return if (self.entries.getPtr(name)) |e| &e.loaded else null;
    }

    /// Like `find`, but returns both the parsed body and the source
    /// path so callers (e.g. "double-click → open prefab tab") can
    /// drive `app.openPrefab` without re-walking the filesystem.
    pub fn findEntry(self: *const Index, name: []const u8) ?*const Entry {
        return self.entries.getPtr(name);
    }

    /// Walk `<project_dir>/prefabs/` recursively and load every
    /// `.jsonc` file. Errors on a single file are logged and skipped —
    /// same tolerance the atlas and gizmo loaders use. The key is the
    /// file's stem (basename minus `.jsonc`); collisions across
    /// subdirectories keep the first hit and log a warning.
    pub fn build(
        allocator: std.mem.Allocator,
        project_dir: []const u8,
        generation: u64,
    ) Index {
        var idx: Index = .{ .allocator = allocator, .generation = generation };

        const prefabs_dir = std.fs.path.join(allocator, &.{ project_dir, "prefabs" }) catch return idx;
        defer allocator.free(prefabs_dir);

        walk(allocator, &idx, prefabs_dir);
        return idx;
    }
};

/// Recursive directory walk. Picked over `std.fs.Dir.walk` because the
/// latter allocates a queue and we want to keep the call site simple +
/// errors locally absorbed.
fn walk(allocator: std.mem.Allocator, idx: *Index, path: []const u8) void {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |dirent| {
        const full = std.fs.path.join(allocator, &.{ path, dirent.name }) catch continue;
        defer allocator.free(full);

        switch (dirent.kind) {
            .directory => walk(allocator, idx, full),
            .file => {
                if (!std.mem.endsWith(u8, dirent.name, ".jsonc")) continue;
                loadOne(allocator, idx, full, dirent.name) catch |err| {
                    std.log.warn("Prefab '{s}' failed to load: {s}", .{ full, @errorName(err) });
                };
            },
            else => {},
        }
    }
}

fn loadOne(
    allocator: std.mem.Allocator,
    idx: *Index,
    full_path: []const u8,
    basename: []const u8,
) !void {
    // Filename stem = basename minus `.jsonc` extension. Matches how
    // the engine/assembler resolves `{ "prefab": "<stem>" }` lookups.
    const stem = basename[0 .. basename.len - ".jsonc".len];

    const gop = try idx.entries.getOrPut(allocator, stem);
    if (gop.found_existing) {
        std.log.warn("Prefab name '{s}' duplicated across subfolders; keeping first hit", .{stem});
        return;
    }
    // getOrPut wrote the input slice as the key — replace it with an
    // owned copy so the slot survives `basename`'s caller-owned buffer.
    const owned_key = allocator.dupe(u8, stem) catch |err| {
        _ = idx.entries.remove(stem);
        return err;
    };
    gop.key_ptr.* = owned_key;

    const owned_path = allocator.dupe(u8, full_path) catch |err| {
        _ = idx.entries.remove(owned_key);
        allocator.free(owned_key);
        return err;
    };
    const loaded = scene_io.loadPrefabFromFile(allocator, full_path) catch |err| {
        allocator.free(owned_path);
        _ = idx.entries.remove(owned_key);
        allocator.free(owned_key);
        return err;
    };
    gop.value_ptr.* = .{ .path = owned_path, .loaded = loaded };
}
