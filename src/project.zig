const std = @import("std");
const zon_scan = @import("zon_scan.zig");
const io_global = @import("io_global.zig");

pub const PROJECT_FILENAME = "project.labelle";

pub const ProjectFolders = struct {
    pub const assets = "assets";
    pub const components = "components";
    pub const fixtures = "fixtures";
    pub const gizmos = "gizmos";
    pub const prefabs = "prefabs";
    pub const scenes = "scenes";
    pub const scripts = "scripts";
    /// Nested subfolder under `scripts/` for visual-scripting
    /// `.flow.zon` files (issue #45 — Flows editor). Scaffolded as
    /// part of `ProjectFolders.all` so `createProjectFolders`
    /// creates it on new project, but `std.Io.Dir.createDirPath`
    /// will create the `scripts` parent if it's missing. The Flow
    /// tab router (`project_tree.isFlowPath`) requires this exact
    /// relative path.
    pub const scripts_flows = "scripts/flows";
    pub const resources = "resources";

    pub const all = [_][]const u8{
        assets,
        components,
        fixtures,
        gizmos,
        prefabs,
        scenes,
        scripts,
        scripts_flows,
        resources,
    };
};

/// Mirrors a subset of `labelle-assembler`'s `config.Backend` enum.
/// Order/spelling must match so the ZON `.backend = .raylib` literal parses
/// identically in both binaries.
pub const Backend = enum { raylib, sokol, sdl, bgfx, wgpu, null };

/// Mirrors `labelle-assembler`'s `config.EcsChoice`.
pub const EcsChoice = enum { mock, zig_ecs, zflecs, mr_ecs };

/// Mirrors `labelle-assembler`'s `config.ResourceDef`. The `lazy` flag is
/// omitted for now — the assembler infers it from scene asset blocks.
pub const ResourceDef = struct {
    name: []const u8,
    json: []const u8 = "",
    texture: []const u8 = "",
};

/// Project configuration written to `<project_dir>/project.labelle` in ZON
/// format. Schema-compatible with the subset of `labelle-assembler`'s
/// `ProjectConfig` that gui edits today; the assembler fills in defaults
/// for fields we omit (layers, resources, plugins, etc.).
///
/// The version pins MUST be emitted: without `assembler_version`, the
/// `labelle` launcher falls back to its own version when fetching the
/// assembler binary (see `labelle-cli/src/cli/cache.zig:29`), which fails
/// on any machine where CLI and assembler aren't lockstep. The defaults
/// below are the tested-coherent set from `labelle-cli/versions.zon` plus
/// the assembler pin from its `build.zig.zon`.
pub const ProjectConfig = struct {
    name: []const u8,
    description: []const u8 = "",
    title: []const u8 = "",
    width: u32 = 800,
    height: u32 = 600,
    target_fps: u32 = 60,
    backend: Backend = .raylib,
    ecs: EcsChoice = .zig_ecs,
    initial_scene: []const u8 = "main",
    core_version: []const u8 = "1.12.0",
    engine_version: []const u8 = "1.37.3",
    gfx_version: []const u8 = "1.10.0",
    assembler_version: []const u8 = "0.20.0",
    /// Sprite atlas resources — name + JSON manifest + texture file. The
    /// engine consumes these via the generated `main.zig` (see assembler
    /// codegen). Defaults to empty; the editor adds entries.
    resources: []const ResourceDef = &.{},
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    /// Owns every string in `config`, `extras`, and the `dir` field.
    /// Freed in `deinit`.
    arena: *std.heap.ArenaAllocator,
    /// Project directory (absolute path). null until the project is saved.
    dir: ?[]const u8,
    config: ProjectConfig,
    /// Verbatim text for top-level `project.labelle` fields the gui's
    /// `ProjectConfig` doesn't model (e.g. `states`, `plugins`, `layers`,
    /// `gui`, `ios`, `android`, `labelle_version`, `hidden`). Captured on
    /// `loadProject` and re-emitted on `saveProject` so external projects
    /// round-trip without data loss. Each element is one field's source
    /// text, starting at `.name` and ending right before the trailing
    /// comma. Empty for projects authored by the gui.
    extras: []const []const u8,
    is_dirty: bool,
    /// Cached result of `scenesAvailable`. Built lazily on first call;
    /// owned by the project's arena and invalidated implicitly when the
    /// Project is destroyed (project new/load/close bumps
    /// `ProjectManager.generation` and recreates the Project). Walks
    /// the top-level `<dir>/scenes/*.jsonc` only — subdirectory scenes
    /// (e.g. `scenes/debug/main.jsonc`) are out of scope for the v1
    /// picker; can grow later when the project tree starts exposing
    /// nested scene folders.
    scenes_cache: ?[]const []const u8 = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, name: []const u8) !*Self {
        const project = try allocator.create(Self);
        errdefer allocator.destroy(project);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const name_copy = try arena.allocator().dupe(u8, name);

        project.* = .{
            .allocator = allocator,
            .arena = arena,
            .dir = null,
            .config = .{ .name = name_copy },
            .extras = &.{},
            .is_dirty = true,
            .scenes_cache = null,
        };
        return project;
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.allocator.destroy(self);
    }

    pub fn markDirty(self: *Self) void {
        self.is_dirty = true;
    }

    pub fn getProjectDir(self: *const Self) ?[]const u8 {
        return self.dir;
    }

    /// Return the list of scene basenames (extension stripped) found at
    /// `<dir>/scenes/*.jsonc`, sorted alphabetically. Cached against the
    /// project's lifetime — the cache is built on the first call and
    /// owned by `arena`. Project transitions (new/load/close) recreate
    /// the Project entirely, so the cache invalidates implicitly.
    ///
    /// The `alloc` parameter is unused today (the arena is the real
    /// owner) but exposed in the signature so future callers can pass a
    /// short-lived allocator if cache-invalidation grows beyond
    /// per-project lifetime — e.g. a "Refresh" button.
    ///
    /// Returns an empty slice if `dir` is null (unsaved project) or the
    /// `scenes/` subdirectory is missing.
    pub fn scenesAvailable(self: *Self, alloc: std.mem.Allocator) ![]const []const u8 {
        _ = alloc;
        if (self.scenes_cache) |c| return c;

        const arena_alloc = self.arena.allocator();
        const dir_path = self.dir orelse {
            self.scenes_cache = &.{};
            return &.{};
        };

        const scenes_dir_path = std.fs.path.join(arena_alloc, &.{ dir_path, ProjectFolders.scenes }) catch {
            self.scenes_cache = &.{};
            return &.{};
        };

        const io = io_global.io();
        var scenes_dir = std.Io.Dir.cwd().openDir(io, scenes_dir_path, .{ .iterate = true }) catch {
            // Missing scenes/ subdir is the default for new projects —
            // not an error from the picker's perspective.
            self.scenes_cache = &.{};
            return &.{};
        };
        defer scenes_dir.close(io);

        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        // Names live in the arena, so no separate cleanup needed on the
        // success path — the arena deinit catches everything.

        var it = scenes_dir.iterate();
        while (it.next(io) catch null) |dirent| {
            if (dirent.kind != .file) continue;
            if (!std.mem.endsWith(u8, dirent.name, ".jsonc")) continue;
            const stem = dirent.name[0 .. dirent.name.len - ".jsonc".len];
            if (stem.len == 0) continue;
            const copy = arena_alloc.dupe(u8, stem) catch continue;
            names.append(arena_alloc, copy) catch continue;
        }

        const mut_slice: [][]const u8 = names.toOwnedSlice(arena_alloc) catch {
            self.scenes_cache = &.{};
            return &.{};
        };
        std.mem.sort([]const u8, mut_slice, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        const slice: []const []const u8 = mut_slice;
        self.scenes_cache = slice;
        return slice;
    }
};

pub const ProjectManager = struct {
    allocator: std.mem.Allocator,
    current_project: ?*Project,
    /// Monotonic counter bumped every time `current_project` is
    /// replaced (new / load / close). Modules that cache per-project
    /// state should track this rather than the raw `*Project` pointer —
    /// `DebugAllocator` can reuse an address after `deinit`,
    /// so two different projects can have the same pointer in
    /// sequence. Comparing the generation avoids that ABA trap.
    generation: u64,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .current_project = null,
            .generation = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.current_project) |project| project.deinit();
    }

    pub fn newProject(self: *Self, name: []const u8) !void {
        if (self.current_project) |project| project.deinit();
        self.current_project = try Project.create(self.allocator, name);
        self.generation +%= 1;
    }

    pub fn createProjectFolders(_: *Self, base_path: []const u8) !void {
        const io = io_global.io();
        var dir = try std.Io.Dir.cwd().openDir(io, base_path, .{});
        defer dir.close(io);

        // `createDirPath` instead of `createDir` so `scripts/flows`
        // creates the `scripts` parent if it's missing — and so
        // path separators in entries work on Windows (where
        // `createDir` only accepts a single component).
        for (ProjectFolders.all) |folder| {
            dir.createDirPath(io, folder) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }

    /// Save the current project to `<dir>/project.labelle` (ZON, assembler-compatible).
    /// Creates the directory's scaffold folders if they don't exist.
    pub fn saveProject(self: *Self, dir_path: []const u8) !void {
        const proj = self.current_project orelse return error.NoProjectOpen;

        const io = io_global.io();
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try self.createProjectFolders(dir_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, PROJECT_FILENAME });
        defer self.allocator.free(file_path);

        const content = try renderProjectLabelle(self.allocator, proj.config, proj.extras);
        defer self.allocator.free(content);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = file_path,
            .data = content,
        });

        proj.dir = try proj.arena.allocator().dupe(u8, dir_path);
        proj.is_dirty = false;
    }

    /// Load a project from `<dir>/project.labelle`. The argument may be the
    /// directory itself or the `project.labelle` file inside it — both are
    /// resolved to the containing directory.
    pub fn loadProject(self: *Self, path: []const u8) !void {
        const dir_path = if (std.mem.endsWith(u8, path, PROJECT_FILENAME))
            std.fs.path.dirname(path) orelse "."
        else
            path;

        const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, PROJECT_FILENAME });
        defer self.allocator.free(file_path);

        const io = io_global.io();
        // 16 MB cap is overkill for project.labelle (real ones are <10 KB)
        // but the bot reviewer flagged 1 MB as too tight for "robustness";
        // bumping it costs nothing and removes the question.
        const raw = try std.Io.Dir.cwd().readFileAlloc(io, file_path, self.allocator, .limited(16 * 1024 * 1024));
        defer self.allocator.free(raw);

        // Build the project up front so its arena owns every string we parse
        // into. Bail and tear it down on error so we don't leak.
        const project = try self.allocator.create(Project);
        errdefer self.allocator.destroy(project);

        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();

        const arena_alloc = arena.allocator();
        const source = try arena_alloc.dupeZ(u8, raw);

        // Real-world project.labelle files (e.g. ../flying-platform-labelle/)
        // carry fields the assembler models that we don't yet — states,
        // layers, plugins, gui, ios, android, labelle_version, hidden.
        // Default ZON parsing rejects unknown fields, so we'd refuse to
        // open any project that wasn't created by this gui. Tolerant
        // parse lets the user open them and edit the fields we *do*
        // know — at the cost of dropping the unknown ones on Save.
        // Saving an externally-authored project is therefore unsafe;
        // the editor needs full pass-through before we lift that caveat.
        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(arena_alloc);
        const parsed = std.zon.parse.fromSliceAlloc(ProjectConfig, arena_alloc, source, &diag, .{
            .ignore_unknown_fields = true,
        }) catch |err| {
            std.log.err("project.labelle parse failed at {s}: {s}", .{ file_path, @errorName(err) });
            return err;
        };

        // Capture text for any top-level field our ProjectConfig doesn't
        // model, so we can re-emit them on save without dropping data.
        const extras = extractUnmodeledFields(arena_alloc, source) catch |err| blk: {
            std.log.warn("project.labelle extras scan failed at {s}: {s} (saving will drop unknown fields)", .{ file_path, @errorName(err) });
            break :blk &.{};
        };

        project.* = .{
            .allocator = self.allocator,
            .arena = arena,
            .dir = try arena_alloc.dupe(u8, dir_path),
            .config = parsed,
            .extras = extras,
            .is_dirty = false,
            .scenes_cache = null,
        };

        if (self.current_project) |old| old.deinit();
        self.current_project = project;
        self.generation +%= 1;
    }

    pub fn closeProject(self: *Self) void {
        if (self.current_project) |project| {
            project.deinit();
            self.current_project = null;
            self.generation +%= 1;
        }
    }

    pub fn hasUnsavedChanges(self: *const Self) bool {
        if (self.current_project) |project| return project.is_dirty;
        return false;
    }

    pub fn getProjectName(self: *const Self) ?[]const u8 {
        if (self.current_project) |project| return project.config.name;
        return null;
    }
};

/// Field names we render explicitly via `renderProjectLabelle`. Any
/// top-level key in the loaded file that isn't in this set is captured
/// verbatim into `Project.extras` for round-trip preservation. Keep in
/// sync with the field list in `renderProjectLabelle` above — these are
/// the names of the fields we emit ourselves and must not duplicate.
const managed_field_names = [_][]const u8{
    "name",         "description",       "title",
    "width",        "height",            "target_fps",
    "backend",      "ecs",               "initial_scene",
    "core_version", "engine_version",    "gfx_version",
    "assembler_version",                 "resources",
};

fn isManaged(name: []const u8) bool {
    for (managed_field_names) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}

/// Extract verbatim source text for every top-level field in a ZON
/// document that the gui's `ProjectConfig` doesn't model. The returned
/// slices live in `arena` and each is the field's text starting at the
/// leading `.` and ending right before the trailing comma (or the
/// closing `}` for a final field).
///
/// Scope: handles the ZON dialect actually used in `project.labelle` —
/// `// ... \n` comments, `"..."` strings with `\"` escapes, and brace /
/// bracket / paren nesting in values. Multi-line strings (`\\...`) and
/// `'...'` character literals are not handled because the assembler's
/// project schema doesn't use them; if either appears in a future
/// schema, this scanner will need to grow.
fn extractUnmodeledFields(arena: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    var i: usize = 0;
    zon_scan.skipWsAndComments(raw, &i);
    // Top-level shape is `.{ ... }`. Bail quietly on anything else; the
    // caller treats a missing extras list as "no preservation possible".
    if (i + 1 >= raw.len or raw[i] != '.' or raw[i + 1] != '{') return &.{};
    i += 2;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(arena);

    while (i < raw.len) {
        // Mark the start of this field's "block" *before* skipping
        // leading whitespace + comments. We then skip past whitespace
        // (so blank lines between fields don't accumulate) and any
        // `//` comment lines, landing on the field's `.`. The captured
        // block runs from this marker through the field value — so any
        // comments directly above an unmodeled field travel with it,
        // not lost between save / load cycles.
        const block_start = i;
        skipWhitespace(raw, &i);
        while (i + 1 < raw.len and raw[i] == '/' and raw[i + 1] == '/') {
            while (i < raw.len and raw[i] != '\n') i += 1;
            skipWhitespace(raw, &i);
        }
        if (i >= raw.len) break;
        if (raw[i] == '}') break;
        if (raw[i] != '.') break; // unexpected; stop rather than mis-parse

        i += 1; // past '.'
        const name_start = i;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (!std.ascii.isAlphanumeric(c) and c != '_') break;
        }
        const name = raw[name_start..i];
        if (name.len == 0) break;

        zon_scan.skipWsAndComments(raw, &i);
        if (i >= raw.len or raw[i] != '=') break;
        i += 1; // past '='

        // Scan the value up to (but not including) the next top-level
        // `,` or the outer `}`. Brace/string/comment aware.
        zon_scan.scanValue(raw, &i);
        const field_end = i;

        // Consume optional trailing comma.
        const save = i;
        zon_scan.skipWsAndComments(raw, &i);
        if (i < raw.len and raw[i] == ',') {
            i += 1;
        } else {
            i = save;
        }

        if (!isManaged(name)) {
            // Trim outer whitespace but keep internal newlines so a
            // multi-line `// comment\n.field = .{ ... }` block stays
            // visually intact. The renderer prepends `"    "` to the
            // first line; subsequent lines retain their original
            // indentation from the source.
            const trimmed = std.mem.trim(u8, raw[block_start..field_end], " \t\r\n");
            if (trimmed.len > 0) {
                const text = try arena.dupe(u8, trimmed);
                try out.append(arena, text);
            }
        }
    }
    return out.toOwnedSlice(arena);
}

fn skipWhitespace(raw: []const u8, i: *usize) void {
    while (i.* < raw.len) {
        const c = raw[i.*];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
        i.* += 1;
    }
}

/// Format a `ProjectConfig` as ZON source matching `labelle-assembler`'s
/// expected schema. Omits fields the assembler can default so the file
/// stays minimal and hand-editable.
fn renderProjectLabelle(
    allocator: std.mem.Allocator,
    cfg: ProjectConfig,
    extras: []const []const u8,
) ![]u8 {
    const title = if (cfg.title.len > 0) cfg.title else cfg.name;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, ".{\n");
    try buf.print(allocator, "    .name = \"{s}\",\n", .{cfg.name});
    try buf.print(allocator, "    .description = \"{s}\",\n", .{cfg.description});
    try buf.print(allocator, "    .title = \"{s}\",\n", .{title});
    try buf.print(allocator, "    .width = {d},\n", .{cfg.width});
    try buf.print(allocator, "    .height = {d},\n", .{cfg.height});
    try buf.print(allocator, "    .target_fps = {d},\n", .{cfg.target_fps});
    try buf.print(allocator, "    .backend = .{s},\n", .{@tagName(cfg.backend)});
    try buf.print(allocator, "    .ecs = .{s},\n", .{@tagName(cfg.ecs)});
    try buf.print(allocator, "    .initial_scene = \"{s}\",\n", .{cfg.initial_scene});
    try buf.print(allocator, "    .core_version = \"{s}\",\n", .{cfg.core_version});
    try buf.print(allocator, "    .engine_version = \"{s}\",\n", .{cfg.engine_version});
    try buf.print(allocator, "    .gfx_version = \"{s}\",\n", .{cfg.gfx_version});
    try buf.print(allocator, "    .assembler_version = \"{s}\",\n", .{cfg.assembler_version});

    if (cfg.resources.len > 0) {
        try buf.appendSlice(allocator, "    .resources = .{\n");
        for (cfg.resources) |r| {
            try buf.print(allocator,
                "        .{{ .name = \"{s}\", .json = \"{s}\", .texture = \"{s}\" }},\n",
                .{ r.name, r.json, r.texture },
            );
        }
        try buf.appendSlice(allocator, "    },\n");
    }

    // Re-emit fields the gui doesn't model, verbatim from the source we
    // loaded. Captured text already starts at `.name` and excludes the
    // trailing comma; we just indent and add `,\n`. Multi-line values
    // (e.g. nested struct literals) keep their original line breaks but
    // not their original indentation level — good enough; the file is
    // still ZON-parseable and human-editable.
    for (extras) |field_text| {
        try buf.appendSlice(allocator, "    ");
        try buf.appendSlice(allocator, field_text);
        try buf.appendSlice(allocator, ",\n");
    }

    try buf.appendSlice(allocator, "}\n");
    return buf.toOwnedSlice(allocator);
}
