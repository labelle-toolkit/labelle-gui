const std = @import("std");

pub const PROJECT_FILENAME = "project.labelle";

pub const ProjectFolders = struct {
    pub const assets = "assets";
    pub const components = "components";
    pub const fixtures = "fixtures";
    pub const prefabs = "prefabs";
    pub const scenes = "scenes";
    pub const scripts = "scripts";
    pub const resources = "resources";

    pub const all = [_][]const u8{
        assets,
        components,
        fixtures,
        prefabs,
        scenes,
        scripts,
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
    core_version: []const u8 = "1.10.0",
    engine_version: []const u8 = "1.21.0",
    gfx_version: []const u8 = "1.7.0",
    assembler_version: []const u8 = "0.8.0",
    /// Sprite atlas resources — name + JSON manifest + texture file. The
    /// engine consumes these via the generated `main.zig` (see assembler
    /// codegen). Defaults to empty; the editor adds entries.
    resources: []const ResourceDef = &.{},
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    /// Owns every string in `config` and the `dir` field. Freed in `deinit`.
    arena: *std.heap.ArenaAllocator,
    /// Project directory (absolute path). null until the project is saved.
    dir: ?[]const u8,
    config: ProjectConfig,
    is_dirty: bool,

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
            .is_dirty = true,
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
};

pub const ProjectManager = struct {
    allocator: std.mem.Allocator,
    current_project: ?*Project,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .current_project = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.current_project) |project| project.deinit();
    }

    pub fn newProject(self: *Self, name: []const u8) !void {
        if (self.current_project) |project| project.deinit();
        self.current_project = try Project.create(self.allocator, name);
    }

    pub fn createProjectFolders(_: *Self, base_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(base_path, .{});
        defer dir.close();

        for (ProjectFolders.all) |folder| {
            dir.makeDir(folder) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
        }
    }

    /// Save the current project to `<dir>/project.labelle` (ZON, assembler-compatible).
    /// Creates the directory's scaffold folders if they don't exist.
    pub fn saveProject(self: *Self, dir_path: []const u8) !void {
        const proj = self.current_project orelse return error.NoProjectOpen;

        std.fs.cwd().makePath(dir_path) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try self.createProjectFolders(dir_path);

        const file_path = try std.fs.path.join(self.allocator, &.{ dir_path, PROJECT_FILENAME });
        defer self.allocator.free(file_path);

        const content = try renderProjectLabelle(self.allocator, proj.config);
        defer self.allocator.free(content);

        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll(content);

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

        const raw = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 1024 * 1024);
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

        var diag: std.zon.parse.Diagnostics = .{};
        defer diag.deinit(arena_alloc);
        const parsed = try std.zon.parse.fromSlice(ProjectConfig, arena_alloc, source, &diag, .{});

        project.* = .{
            .allocator = self.allocator,
            .arena = arena,
            .dir = try arena_alloc.dupe(u8, dir_path),
            .config = parsed,
            .is_dirty = false,
        };

        if (self.current_project) |old| old.deinit();
        self.current_project = project;
    }

    pub fn closeProject(self: *Self) void {
        if (self.current_project) |project| {
            project.deinit();
            self.current_project = null;
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

/// Format a `ProjectConfig` as ZON source matching `labelle-assembler`'s
/// expected schema. Omits fields the assembler can default so the file
/// stays minimal and hand-editable.
fn renderProjectLabelle(allocator: std.mem.Allocator, cfg: ProjectConfig) ![]u8 {
    const title = if (cfg.title.len > 0) cfg.title else cfg.name;
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(".{\n");
    try w.print("    .name = \"{s}\",\n", .{cfg.name});
    try w.print("    .description = \"{s}\",\n", .{cfg.description});
    try w.print("    .title = \"{s}\",\n", .{title});
    try w.print("    .width = {d},\n", .{cfg.width});
    try w.print("    .height = {d},\n", .{cfg.height});
    try w.print("    .target_fps = {d},\n", .{cfg.target_fps});
    try w.print("    .backend = .{s},\n", .{@tagName(cfg.backend)});
    try w.print("    .ecs = .{s},\n", .{@tagName(cfg.ecs)});
    try w.print("    .initial_scene = \"{s}\",\n", .{cfg.initial_scene});
    try w.print("    .core_version = \"{s}\",\n", .{cfg.core_version});
    try w.print("    .engine_version = \"{s}\",\n", .{cfg.engine_version});
    try w.print("    .gfx_version = \"{s}\",\n", .{cfg.gfx_version});
    try w.print("    .assembler_version = \"{s}\",\n", .{cfg.assembler_version});

    if (cfg.resources.len > 0) {
        try w.writeAll("    .resources = .{\n");
        for (cfg.resources) |r| {
            try w.print(
                "        .{{ .name = \"{s}\", .json = \"{s}\", .texture = \"{s}\" }},\n",
                .{ r.name, r.json, r.texture },
            );
        }
        try w.writeAll("    },\n");
    }

    try w.writeAll("}\n");
    return buf.toOwnedSlice(allocator);
}
