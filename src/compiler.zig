const std = @import("std");
const project = @import("project.zig");

pub const CompilerError = error{
    NoProjectOpen,
    NoProjectPath,
    InvalidProjectPath,
    FailedToCreateBuildFiles,
    FailedToRunBuild,
    CompilationFailed,
    OutOfMemory,
} || std.fs.File.OpenError || std.fs.File.WriteError;

pub const CompilationResult = struct {
    success: bool,
    output: []const u8,
    errors: []const u8,

    pub fn deinit(self: *CompilationResult, allocator: std.mem.Allocator) void {
        if (self.output.len > 0) allocator.free(self.output);
        if (self.errors.len > 0) allocator.free(self.errors);
    }
};

pub const CompilerState = enum {
    idle,
    generating,
    building,
    running,
    failed,
    success,
};

pub const Compiler = struct {
    allocator: std.mem.Allocator,
    state: CompilerState,
    last_result: ?CompilationResult,
    build_process: ?std.process.Child,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .idle,
            .last_result = null,
            .build_process = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_result) |*result| {
            result.deinit(self.allocator);
        }
        if (self.build_process) |*proc| {
            _ = proc.kill() catch {};
        }
    }

    /// Generate build.zig for the project (only if it doesn't exist)
    pub fn generateBuildZig(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const build_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "build.zig" });
        defer proj.allocator.free(build_path);

        // Don't overwrite existing build.zig to preserve user modifications
        if (std.fs.cwd().access(build_path, .{})) {
            return;
        } else |_| {}

        const file = try std.fs.cwd().createFile(build_path, .{});
        defer file.close();

        const build_content = try std.fmt.allocPrint(proj.allocator,
            \\const std = @import("std");
            \\
            \\pub fn build(b: *std.Build) void {{
            \\    const target = b.standardTargetOptions(.{{}});
            \\    const optimize = b.standardOptimizeOption(.{{}});
            \\
            \\    // Dependencies
            \\    const labelle_engine_dep = b.dependency("labelle_engine", .{{
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    const labelle_engine = labelle_engine_dep.module("labelle-engine");
            \\
            \\    const labelle_dep = b.dependency("labelle-gfx", .{{
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    const labelle = labelle_dep.module("labelle");
            \\
            \\    const ecs_dep = b.dependency("zig_ecs", .{{
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    const ecs = ecs_dep.module("zig-ecs");
            \\
            \\    // Main executable
            \\    const exe = b.addExecutable(.{{
            \\        .name = "{s}",
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("main.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\            .imports = &.{{
            \\                .{{ .name = "labelle-engine", .module = labelle_engine }},
            \\                .{{ .name = "labelle", .module = labelle }},
            \\                .{{ .name = "ecs", .module = ecs }},
            \\            }},
            \\        }}),
            \\    }});
            \\
            \\    b.installArtifact(exe);
            \\
            \\    const run_exe = b.addRunArtifact(exe);
            \\    run_exe.step.dependOn(b.getInstallStep());
            \\
            \\    if (b.args) |args| {{
            \\        run_exe.addArgs(args);
            \\    }}
            \\
            \\    const run_step = b.step("run", "Run the game");
            \\    run_step.dependOn(&run_exe.step);
            \\}}
            \\
        , .{proj.metadata.name});
        defer proj.allocator.free(build_content);

        try file.writeAll(build_content);
    }

    /// Generate build.zig.zon for the project (only if it doesn't exist)
    pub fn generateBuildZigZon(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const zon_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "build.zig.zon" });
        defer proj.allocator.free(zon_path);

        // Don't overwrite existing build.zig.zon to preserve fingerprint and user modifications
        if (std.fs.cwd().access(zon_path, .{})) {
            return;
        } else |_| {}

        const file = try std.fs.cwd().createFile(zon_path, .{});
        defer file.close();

        // Generate a deterministic fingerprint from the project name using Wyhash
        // This ensures the fingerprint doesn't change between runs
        // Note: Zig may still suggest a different fingerprint on first build
        const fingerprint = std.hash.Wyhash.hash(0xcafe_babe_dead_beef, proj.metadata.name);

        const zon_content = try std.fmt.allocPrint(proj.allocator,
            \\.{{
            \\    .fingerprint = 0x{x},
            \\    .name = .{s},
            \\    .version = "0.1.0",
            \\    .minimum_zig_version = "0.15.2",
            \\    .dependencies = .{{
            \\        .labelle_engine = .{{
            \\            .url = "git+https://github.com/labelle-toolkit/labelle-engine#main",
            \\            .hash = "labelle_engine-0.2.0-rhO5vroRAgBDibpf32FtJr-Z7YFVzvDgEg_UftNxYbpg",
            \\        }},
            \\        .@"labelle-gfx" = .{{
            \\            .url = "git+https://github.com/labelle-toolkit/labelle-gfx?ref=v0.10.0#2bc00d41de2f067f72aa55629167b0b61e3f4d42",
            \\            .hash = "labelle-0.10.0-2bWPIhW2BAB16mnfjuJYX1meUv3k_EQPzY-oJQXjBL76",
            \\        }},
            \\        .zig_ecs = .{{
            \\            .url = "git+https://github.com/prime31/zig-ecs#dbf3647c2cc4f327fe87067e40f8436c7f87f209",
            \\            .hash = "entt-1.0.0-qJPtbNLVAgDPXaUbyRSsBTK75Cr1WujUA92kToJugWry",
            \\        }},
            \\    }},
            \\    .paths = .{{
            \\        "build.zig",
            \\        "build.zig.zon",
            \\        "main.zig",
            \\        "scenes",
            \\        "components",
            \\        "scripts",
            \\        "prefabs",
            \\        "assets",
            \\    }},
            \\}}
            \\
        , .{ fingerprint, proj.metadata.name });
        defer proj.allocator.free(zon_content);

        try file.writeAll(zon_content);
    }

    /// Generate main.zig entry point (at project root, following engine example_5 pattern)
    /// Only generates if the file doesn't exist
    pub fn generateMainZig(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const main_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "main.zig" });
        defer proj.allocator.free(main_path);

        // Don't overwrite existing main.zig to preserve user modifications
        if (std.fs.cwd().access(main_path, .{})) {
            return;
        } else |_| {}

        const file = try std.fs.cwd().createFile(main_path, .{});
        defer file.close();

        const main_content = try std.fmt.allocPrint(proj.allocator,
            \\// {s} - Generated by Labelle GUI
            \\//
            \\// This is the main entry point for your game.
            \\// Edit this file to customize game initialization and behavior.
            \\
            \\const std = @import("std");
            \\const engine = @import("labelle-engine");
            \\const labelle = @import("labelle");
            \\
            \\// Import components from the components/ folder
            \\// Example: const velocity = @import("components/velocity.zig");
            \\
            \\// Component registry - add your components here
            \\const Components = engine.ComponentRegistry(struct {{
            \\    // Example: pub const Velocity = velocity.Velocity;
            \\}});
            \\
            \\// Prefab registry - add your prefabs here
            \\const Prefabs = engine.PrefabRegistry(.{{}});
            \\
            \\// Script registry - add your scripts here
            \\const Scripts = engine.ScriptRegistry(struct {{}});
            \\
            \\// Scene loader type
            \\const Loader = engine.SceneLoader(Prefabs, Components, Scripts);
            \\
            \\pub fn main() !void {{
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{{}}){{}};
            \\    defer _ = gpa.deinit();
            \\    const allocator = gpa.allocator();
            \\
            \\    // Initialize game with the Game facade
            \\    var game = try engine.Game.init(allocator, .{{
            \\        .window = .{{
            \\            .width = 1280,
            \\            .height = 720,
            \\            .title = "{s}",
            \\        }},
            \\        .clear_color = .{{ .r = 30, .g = 35, .b = 45 }},
            \\    }});
            \\    defer game.deinit();
            \\
            \\    // Register scenes - import your scene .zon files here
            \\    try game.registerSceneSimple("main", Loader, @import("scenes/main.zon"));
            \\
            \\    // Start with main scene
            \\    try game.setScene("main");
            \\
            \\    // Run the game loop
            \\    try game.run();
            \\}}
            \\
        , .{ proj.metadata.name, proj.metadata.name });
        defer proj.allocator.free(main_content);

        try file.writeAll(main_content);
    }

    /// Create project folder structure using ProjectFolders.all
    pub fn createProjectFolders(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        // Create all folders defined in ProjectFolders.all
        for (project.ProjectFolders.all) |folder| {
            const folder_path = try std.fs.path.join(proj.allocator, &.{ project_dir, folder });
            defer proj.allocator.free(folder_path);

            std.fs.cwd().makeDir(folder_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };

            // Create a .gitkeep file to preserve empty directories in git
            const gitkeep_path = try std.fs.path.join(proj.allocator, &.{ folder_path, ".gitkeep" });
            defer proj.allocator.free(gitkeep_path);

            // Attempt to create gitkeep, ignore if it already exists or fails
            if (std.fs.cwd().createFile(gitkeep_path, .{ .exclusive = true })) |gitkeep| {
                gitkeep.close();
            } else |_| {}
        }
    }

    /// Generate a default scene .zon file (compile-time scene format)
    pub fn generateDefaultScene(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const scenes_dir = try std.fs.path.join(proj.allocator, &.{ project_dir, project.ProjectFolders.scenes });
        defer proj.allocator.free(scenes_dir);

        const scene_path = try std.fs.path.join(proj.allocator, &.{ scenes_dir, "main.zon" });
        defer proj.allocator.free(scene_path);

        // Check if scene already exists
        if (std.fs.cwd().access(scene_path, .{})) {
            return;
        } else |_| {}

        const file = try std.fs.cwd().createFile(scene_path, .{});
        defer file.close();

        // Generate a .zon scene file in the format expected by labelle-engine
        const scene_content =
            \\.{
            \\    .name = "main",
            \\    .entities = .{
            \\        // Example entity: a blue rectangle
            \\        .{
            \\            .shape = .{
            \\                .type = .rectangle,
            \\                .x = 400,
            \\                .y = 300,
            \\                .width = 100,
            \\                .height = 100,
            \\                .color = .{ .r = 100, .g = 149, .b = 237, .a = 255 },
            \\                .filled = true,
            \\            },
            \\            // Add components here:
            \\            // .components = .{
            \\            //     .Velocity = .{ .x = 0, .y = 0 },
            \\            // },
            \\        },
            \\    },
            \\}
            \\
        ;

        try file.writeAll(scene_content);
    }

    /// Generate all build files for the project
    pub fn generateAllBuildFiles(self: *Self, proj: *const project.Project) !void {
        self.state = .generating;
        errdefer self.state = .failed;

        try self.generateBuildZig(proj);
        try self.generateBuildZigZon(proj);
        try self.generateMainZig(proj);
        try self.createProjectFolders(proj);
        try self.generateDefaultScene(proj);

        self.state = .idle;
    }

    /// Build the project using zig build
    pub fn build(self: *Self, proj: *const project.Project) !void {
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        self.state = .building;
        errdefer self.state = .failed;

        // Clear previous result
        if (self.last_result) |*result| {
            result.deinit(self.allocator);
            self.last_result = null;
        }

        var child = std.process.Child.init(&.{ "zig", "build" }, self.allocator);
        child.cwd = project_dir;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();
        self.build_process = child;
    }

    /// Check if build is complete and get result.
    /// Note: This uses a blocking wait. For long builds, the UI may briefly pause.
    pub fn pollBuild(self: *Self) ?CompilationResult {
        if (self.state != .building) {
            return null;
        }

        if (self.build_process) |*proc| {
            // Wait for process to complete (blocking)
            const result = proc.wait() catch |err| {
                self.state = .failed;
                self.build_process = null;
                self.last_result = .{
                    .success = false,
                    .output = "",
                    .errors = std.fmt.allocPrint(self.allocator, "Process error: {}", .{err}) catch "",
                };
                return self.last_result;
            };

            // Read output
            const stdout = if (proc.stdout) |stdout_file| blk: {
                break :blk stdout_file.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
            } else "";
            const stderr = if (proc.stderr) |stderr_file| blk: {
                break :blk stderr_file.readToEndAlloc(self.allocator, 1024 * 1024) catch "";
            } else "";

            self.build_process = null;
            const success = result == .Exited and result.Exited == 0;
            self.state = if (success) .success else .failed;
            self.last_result = .{
                .success = success,
                .output = stdout,
                .errors = stderr,
            };
            return self.last_result;
        }
        return null;
    }

    /// Run the built game
    pub fn run(self: *Self, proj: *const project.Project) !void {
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        self.state = .running;

        var child = std.process.Child.init(&.{ "zig", "build", "run" }, self.allocator);
        child.cwd = project_dir;
        child.stderr_behavior = .Inherit;
        child.stdout_behavior = .Inherit;

        try child.spawn();
        self.build_process = child;
    }

    /// Build and run synchronously (blocking)
    pub fn buildSync(self: *Self, proj: *const project.Project) !CompilationResult {
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        self.state = .building;
        errdefer self.state = .failed;

        // Clear previous result
        if (self.last_result) |*result| {
            result.deinit(self.allocator);
            self.last_result = null;
        }

        var child = std.process.Child.init(&.{ "zig", "build" }, self.allocator);
        child.cwd = project_dir;
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;

        try child.spawn();

        const result = try child.wait();

        // Read output
        const stdout = if (child.stdout) |stdout_file| try stdout_file.readToEndAlloc(self.allocator, 1024 * 1024) else "";
        const stderr = if (child.stderr) |stderr_file| try stderr_file.readToEndAlloc(self.allocator, 1024 * 1024) else "";

        const success = result == .Exited and result.Exited == 0;
        self.state = if (success) .success else .failed;
        self.last_result = .{
            .success = success,
            .output = stdout,
            .errors = stderr,
        };

        return self.last_result.?;
    }

    pub fn getState(self: *const Self) CompilerState {
        return self.state;
    }

    pub fn isIdle(self: *const Self) bool {
        return self.state == .idle or self.state == .success or self.state == .failed;
    }
};
