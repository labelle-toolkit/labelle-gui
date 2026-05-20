//! Per-project atlas index. Each entry in `project.labelle.resources`
//! points at an atlas JSON manifest (TexturePacker shape) and the
//! corresponding texture PNG. On project open we walk those entries,
//! parse each JSON, decode the texture via zstbi, upload it to an
//! OpenGL texture, and fold every sprite name into a single combined
//! lookup so the inspector and viewport can resolve `sprite_name`
//! references without caring which atlas an entry came from.
//!
//! The cache is owned by `App` and bound to a `ProjectManager`
//! `generation`. When the generation bumps (project new/load/close)
//! the cache is invalidated and texture handles are freed.

const std = @import("std");
const zstbi = @import("zstbi");
const zopengl = @import("zopengl");
const io_global = @import("io_global.zig");

const gl = zopengl.bindings;

pub const Frame = struct {
    /// Pixel rect in the atlas texture.
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    /// 90° rotation flag — TexturePacker can rotate frames to pack tighter.
    rotated: bool = false,
    /// Whether transparent margins were trimmed off the source image.
    trimmed: bool = false,
    /// Pivot as a fraction of the sprite (0..1); defaults to centre.
    pivot: [2]f32 = .{ 0.5, 0.5 },
    /// Untrimmed source dimensions. Equal to `w`/`h` when not trimmed.
    source_w: u32 = 0,
    source_h: u32 = 0,
    /// Offset of the trimmed rect within the source (`spriteSourceSize`).
    offset_x: i32 = 0,
    offset_y: i32 = 0,
};

pub const SpriteRef = struct {
    /// Which loaded atlas owns this sprite (index into Index.atlases).
    atlas: u32,
    frame: Frame,
};

pub const Atlas = struct {
    /// `resources[i].name` from `project.labelle`. Useful for
    /// diagnostics — "sprite X belongs to atlas Y".
    name: []const u8,
    texture_id: c_uint,
    width: u32,
    height: u32,
    /// `name → Frame` for every entry in this atlas's JSON.
    frames: std.StringHashMapUnmanaged(Frame) = .empty,

    pub fn deinit(self: *Atlas, allocator: std.mem.Allocator) void {
        var it = self.frames.iterator();
        while (it.next()) |entry| allocator.free(entry.key_ptr.*);
        self.frames.deinit(allocator);
        allocator.free(self.name);
        if (self.texture_id != 0) {
            gl.deleteTextures(1, &self.texture_id);
        }
    }
};

/// The combined index: every sprite name across every atlas resolves
/// to an `(atlas_idx, frame)` pair. The hash map's keys live in the
/// owning Atlas's arena, so the index never needs its own allocations
/// for the names.
pub const Index = struct {
    allocator: std.mem.Allocator,
    atlases: std.ArrayListUnmanaged(Atlas) = .empty,
    by_name: std.StringHashMapUnmanaged(SpriteRef) = .empty,
    /// `ProjectManager.generation` this index was built against;
    /// non-zero. App invalidates when the live generation changes.
    generation: u64,

    pub fn deinit(self: *Index) void {
        for (self.atlases.items) |*a| a.deinit(self.allocator);
        self.atlases.deinit(self.allocator);
        self.by_name.deinit(self.allocator);
    }

    /// Build an index by loading every atlas referenced in the
    /// project's `resources` block. Caller frees via `deinit`.
    /// `project_dir` is used to resolve relative JSON / texture paths.
    pub fn build(
        allocator: std.mem.Allocator,
        project_dir: []const u8,
        resources: []const Resource,
        generation: u64,
    ) Index {
        var index: Index = .{ .allocator = allocator, .generation = generation };
        for (resources) |r| {
            var atlas = loadOne(allocator, project_dir, r) catch |err| {
                std.log.warn("Atlas '{s}' failed to load: {s}", .{ r.name, @errorName(err) });
                continue;
            };
            const atlas_idx: u32 = @intCast(index.atlases.items.len);
            // OOM in `append` would orphan the just-loaded atlas's GL
            // texture handle and dup'd name; tear it down before
            // dropping to the next resource.
            index.atlases.append(allocator, atlas) catch {
                atlas.deinit(allocator);
                continue;
            };

            // Mirror this atlas's name → frame map into the combined
            // lookup. First-atlas-wins on collisions; logged so the
            // user isn't surprised.
            var it = index.atlases.items[atlas_idx].frames.iterator();
            while (it.next()) |kv| {
                const gop = index.by_name.getOrPut(allocator, kv.key_ptr.*) catch continue;
                if (gop.found_existing) {
                    std.log.warn("Sprite name '{s}' duplicated across atlases; keeping first hit", .{kv.key_ptr.*});
                    continue;
                }
                gop.value_ptr.* = .{ .atlas = atlas_idx, .frame = kv.value_ptr.* };
            }
        }
        return index;
    }

    pub fn find(self: Index, sprite_name: []const u8) ?SpriteRef {
        return self.by_name.get(sprite_name);
    }

    pub fn textureFor(self: Index, ref: SpriteRef) c_uint {
        if (ref.atlas >= self.atlases.items.len) return 0;
        return self.atlases.items[ref.atlas].texture_id;
    }

    pub fn atlasSize(self: Index, ref: SpriteRef) [2]f32 {
        if (ref.atlas >= self.atlases.items.len) return .{ 1, 1 };
        const a = self.atlases.items[ref.atlas];
        return .{ @floatFromInt(a.width), @floatFromInt(a.height) };
    }
};

/// A subset of `project.ProjectConfig.resources` needed by the atlas
/// loader — kept local so this module doesn't depend on `project.zig`.
pub const Resource = struct {
    name: []const u8,
    json: []const u8,
    texture: []const u8,
};

fn loadOne(allocator: std.mem.Allocator, project_dir: []const u8, r: Resource) !Atlas {
    if (r.json.len == 0 or r.texture.len == 0) return error.MissingResourcePath;

    const json_path = try std.fs.path.join(allocator, &.{ project_dir, r.json });
    defer allocator.free(json_path);
    const tex_path = try std.fs.path.join(allocator, &.{ project_dir, r.texture });
    defer allocator.free(tex_path);

    return loadFromPaths(allocator, r.name, json_path, tex_path);
}

/// Load a single atlas from explicit JSON + PNG paths (not project-
/// relative). Used by the Atlas Viewer to show atlases that aren't in
/// the project's `resources` — e.g. a freshly packed sheet. Caller
/// frees the returned atlas via `Atlas.deinit`.
pub fn loadFromPaths(
    allocator: std.mem.Allocator,
    name: []const u8,
    json_path: []const u8,
    tex_path: []const u8,
) !Atlas {
    // Decode PNG. zstbi-backed; runs on the main thread for now —
    // editor atlases are small enough that synchronous load is fine.
    const tex_path_z = try allocator.dupeZ(u8, tex_path);
    defer allocator.free(tex_path_z);
    var img = try zstbi.Image.loadFromFile(tex_path_z, 4); // force RGBA
    defer img.deinit();

    // Upload to OpenGL. NEAREST filter so pixel art doesn't blur
    // at integer zoom levels; CLAMP_TO_EDGE so neighbour-frame
    // bleeding doesn't happen at frame boundaries.
    var tex_id: c_uint = 0;
    gl.genTextures(1, &tex_id);
    gl.bindTexture(gl.TEXTURE_2D, tex_id);
    gl.texImage2D(
        gl.TEXTURE_2D,
        0,
        gl.RGBA,
        @intCast(img.width),
        @intCast(img.height),
        0,
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        img.data.ptr,
    );
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);

    var atlas: Atlas = .{
        .name = try allocator.dupe(u8, name),
        .texture_id = tex_id,
        .width = img.width,
        .height = img.height,
    };
    errdefer atlas.deinit(allocator);

    try populateFramesFromJson(allocator, json_path, &atlas);
    return atlas;
}

/// Parse a TexturePacker-style JSON manifest into `atlas.frames`.
/// Format: `{ "frames": { "<sprite_name>": { "frame": {x,y,w,h}, ... }, ... } }`.
/// We intentionally only consume the `frame` rect — pivot / source-
/// size / trimmed are needed later for accurate placement but not
/// for the first slice of viewport rendering.
fn populateFramesFromJson(allocator: std.mem.Allocator, json_path: []const u8, atlas: *Atlas) !void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io_global.io(), json_path, allocator, .limited(16 * 1024 * 1024));
    defer allocator.free(raw);
    try parseFramesFromJsonText(allocator, raw, atlas);
}

/// Pure parsing variant: takes the JSON text directly, no GL or
/// filesystem dependency. Extracted so zspec can exercise the
/// manifest-shape contract without needing an OpenGL context or a
/// real PNG on disk.
pub fn parseFramesFromJsonText(allocator: std.mem.Allocator, raw: []const u8, atlas: *Atlas) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    const frames_obj = blk: {
        if (parsed.value != .object) return error.NotAnObject;
        const v = parsed.value.object.get("frames") orelse return error.MissingFramesKey;
        if (v != .object) return error.FramesNotAnObject;
        break :blk v.object;
    };

    var it = frames_obj.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (entry != .object) continue;
        const frame_v = entry.object.get("frame") orelse continue;
        if (frame_v != .object) continue;
        const x = jsonU32(frame_v.object.get("x")) orelse continue;
        const y = jsonU32(frame_v.object.get("y")) orelse continue;
        const w = jsonU32(frame_v.object.get("w")) orelse continue;
        const h = jsonU32(frame_v.object.get("h")) orelse continue;

        var frame: Frame = .{ .x = x, .y = y, .w = w, .h = h, .source_w = w, .source_h = h };
        if (entry.object.get("rotated")) |v| {
            if (v == .bool) frame.rotated = v.bool;
        }
        if (entry.object.get("trimmed")) |v| {
            if (v == .bool) frame.trimmed = v.bool;
        }
        if (entry.object.get("pivot")) |pv| {
            if (pv == .object) {
                if (jsonF32(pv.object.get("x"))) |fx| frame.pivot[0] = fx;
                if (jsonF32(pv.object.get("y"))) |fy| frame.pivot[1] = fy;
            }
        }
        if (entry.object.get("sourceSize")) |sv| {
            if (sv == .object) {
                if (jsonU32(sv.object.get("w"))) |sw| frame.source_w = sw;
                if (jsonU32(sv.object.get("h"))) |sh| frame.source_h = sh;
            }
        }
        if (entry.object.get("spriteSourceSize")) |sss| {
            if (sss == .object) {
                if (jsonI32(sss.object.get("x"))) |ox| frame.offset_x = ox;
                if (jsonI32(sss.object.get("y"))) |oy| frame.offset_y = oy;
            }
        }

        const name_copy = try allocator.dupe(u8, kv.key_ptr.*);
        errdefer allocator.free(name_copy);
        try atlas.frames.put(allocator, name_copy, frame);
    }
}

fn jsonU32(v: ?std.json.Value) ?u32 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn jsonI32(v: ?std.json.Value) ?i32 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jsonF32(v: ?std.json.Value) ?f32 {
    const val = v orelse return null;
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}
