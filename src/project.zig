const std = @import("std");

pub const PROJECT_EXTENSION = ".labelle";
pub const PROJECT_VERSION = 1;

pub const ProjectFolders = struct {
    pub const components = "components";
    pub const fixtures = "fixtures";
    pub const prefabs = "prefabs";
    pub const scenes = "scenes";
    pub const scripts = "scripts";
    pub const resources = "resources";

    pub const all = [_][]const u8{
        components,
        fixtures,
        prefabs,
        scenes,
        scripts,
        resources,
    };
};

pub const ProjectMetadata = struct {
    version: u32 = PROJECT_VERSION,
    name: []const u8,
    created_at: i64,
    modified_at: i64,
    description: []const u8 = "",
};

pub const Project = struct {
    allocator: std.mem.Allocator,
    path: ?[]const u8,
    metadata: ProjectMetadata,
    is_dirty: bool,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, name: []const u8) !*Self {
        const project = try allocator.create(Self);
        const timestamp = std.time.timestamp();

        const name_copy = try allocator.dupe(u8, name);

        project.* = .{
            .allocator = allocator,
            .path = null,
            .metadata = .{
                .name = name_copy,
                .created_at = timestamp,
                .modified_at = timestamp,
            },
            .is_dirty = true,
        };

        return project;
    }

    pub fn deinit(self: *Self) void {
        if (self.path) |p| {
            self.allocator.free(p);
        }
        self.allocator.free(self.metadata.name);
        if (self.metadata.description.len > 0) {
            self.allocator.free(self.metadata.description);
        }
        self.allocator.destroy(self);
    }

    pub fn markDirty(self: *Self) void {
        self.is_dirty = true;
        self.metadata.modified_at = std.time.timestamp();
    }

    pub fn getProjectDir(self: *const Self) ?[]const u8 {
        if (self.path) |p| {
            return std.fs.path.dirname(p);
        }
        return null;
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
        if (self.current_project) |project| {
            project.deinit();
        }
    }

    pub fn newProject(self: *Self, name: []const u8) !void {
        if (self.current_project) |project| {
            project.deinit();
        }

        self.current_project = try Project.create(self.allocator, name);
    }

    pub fn createProjectFolders(_: *Self, base_path: []const u8) !void {
        var dir = try std.fs.cwd().openDir(base_path, .{});
        defer dir.close();

        for (ProjectFolders.all) |folder| {
            dir.makeDir(folder) catch |err| {
                if (err != error.PathAlreadyExists) {
                    return err;
                }
            };
        }
    }

    pub fn saveProject(self: *Self, path: []const u8) !void {
        const proj = self.current_project orelse return error.NoProjectOpen;

        // Ensure path ends with .labelle
        var save_path: []const u8 = undefined;
        var allocated_path = false;

        if (std.mem.endsWith(u8, path, PROJECT_EXTENSION)) {
            save_path = path;
        } else {
            save_path = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ path, PROJECT_EXTENSION });
            allocated_path = true;
        }
        defer if (allocated_path) self.allocator.free(save_path);

        // Get directory for project folders
        const dir_path = std.fs.path.dirname(save_path) orelse ".";

        // Create project folders
        try self.createProjectFolders(dir_path);

        // Write project file as simple text format
        const file = try std.fs.cwd().createFile(save_path, .{});
        defer file.close();

        // Format content
        const content = try std.fmt.allocPrint(self.allocator, "version={d}\nname={s}\ncreated_at={d}\nmodified_at={d}\ndescription={s}\n", .{
            proj.metadata.version,
            proj.metadata.name,
            proj.metadata.created_at,
            proj.metadata.modified_at,
            proj.metadata.description,
        });
        defer self.allocator.free(content);

        try file.writeAll(content);

        // Update project path
        if (proj.path) |old_path| {
            self.allocator.free(old_path);
        }
        proj.path = try self.allocator.dupe(u8, save_path);
        proj.is_dirty = false;

        std.debug.print("Project saved to: {s}\n", .{save_path});
    }

    pub fn loadProject(self: *Self, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(content);

        // Parse simple text format
        var version: u32 = PROJECT_VERSION;
        var name: []const u8 = "";
        var created_at: i64 = 0;
        var modified_at: i64 = 0;
        var description: []const u8 = "";

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "=")) |eq_pos| {
                const key = line[0..eq_pos];
                const value = line[eq_pos + 1 ..];

                if (std.mem.eql(u8, key, "version")) {
                    version = std.fmt.parseInt(u32, value, 10) catch PROJECT_VERSION;
                } else if (std.mem.eql(u8, key, "name")) {
                    name = value;
                } else if (std.mem.eql(u8, key, "created_at")) {
                    created_at = std.fmt.parseInt(i64, value, 10) catch 0;
                } else if (std.mem.eql(u8, key, "modified_at")) {
                    modified_at = std.fmt.parseInt(i64, value, 10) catch 0;
                } else if (std.mem.eql(u8, key, "description")) {
                    description = value;
                }
            }
        }

        // Close existing project
        if (self.current_project) |project| {
            project.deinit();
        }

        // Create new project with loaded data
        const project = try self.allocator.create(Project);
        project.* = .{
            .allocator = self.allocator,
            .path = try self.allocator.dupe(u8, path),
            .metadata = .{
                .version = version,
                .name = try self.allocator.dupe(u8, name),
                .created_at = created_at,
                .modified_at = modified_at,
                .description = if (description.len > 0)
                    try self.allocator.dupe(u8, description)
                else
                    "",
            },
            .is_dirty = false,
        };

        self.current_project = project;

        std.debug.print("Project loaded: {s}\n", .{project.metadata.name});
    }

    pub fn closeProject(self: *Self) void {
        if (self.current_project) |project| {
            project.deinit();
            self.current_project = null;
        }
    }

    pub fn hasUnsavedChanges(self: *const Self) bool {
        if (self.current_project) |project| {
            return project.is_dirty;
        }
        return false;
    }

    pub fn getProjectName(self: *const Self) ?[]const u8 {
        if (self.current_project) |project| {
            return project.metadata.name;
        }
        return null;
    }
};
