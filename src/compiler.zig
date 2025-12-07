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

    /// Generate build.zig for the project
    pub fn generateBuildZig(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const build_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "build.zig" });
        defer proj.allocator.free(build_path);

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
            \\    const labelle_gfx = b.dependency("labelle-gfx", .{{
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    const labelle_engine = b.dependency("labelle-engine", .{{
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\
            \\    // Main executable
            \\    const exe = b.addExecutable(.{{
            \\        .name = "{s}",
            \\        .root_module = b.createModule(.{{
            \\            .root_source_file = b.path("src/main.zig"),
            \\            .target = target,
            \\            .optimize = optimize,
            \\        }}),
            \\    }});
            \\
            \\    // Link dependencies
            \\    exe.root_module.addImport("labelle-gfx", labelle_gfx.module("root"));
            \\    exe.root_module.addImport("labelle-engine", labelle_engine.module("root"));
            \\
            \\    // Add user scripts module
            \\    const scripts_module = b.createModule(.{{
            \\        .root_source_file = b.path("scripts/root.zig"),
            \\        .target = target,
            \\        .optimize = optimize,
            \\    }});
            \\    scripts_module.addImport("labelle-gfx", labelle_gfx.module("root"));
            \\    scripts_module.addImport("labelle-engine", labelle_engine.module("root"));
            \\    exe.root_module.addImport("scripts", scripts_module);
            \\
            \\    // Install
            \\    b.installArtifact(exe);
            \\
            \\    // Run step
            \\    const run_cmd = b.addRunArtifact(exe);
            \\    run_cmd.step.dependOn(b.getInstallStep());
            \\    if (b.args) |args| {{
            \\        run_cmd.addArgs(args);
            \\    }}
            \\    const run_step = b.step("run", "Run the game");
            \\    run_step.dependOn(&run_cmd.step);
            \\}}
            \\
        , .{proj.metadata.name});
        defer proj.allocator.free(build_content);

        try file.writeAll(build_content);
    }

    /// Generate build.zig.zon for the project
    pub fn generateBuildZigZon(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const zon_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "build.zig.zon" });
        defer proj.allocator.free(zon_path);

        const file = try std.fs.cwd().createFile(zon_path, .{});
        defer file.close();

        const zon_content = try std.fmt.allocPrint(proj.allocator,
            \\.{{
            \\    .name = .{{ '{s}' }},
            \\    .version = "0.1.0",
            \\    .dependencies = .{{
            \\        .@"labelle-gfx" = .{{
            \\            .url = "https://github.com/labelle-toolkit/labelle-gfx/archive/refs/heads/main.tar.gz",
            \\            // Update hash after first build attempt
            \\            // .hash = "",
            \\        }},
            \\        .@"labelle-engine" = .{{
            \\            .url = "https://github.com/labelle-toolkit/labelle-engine/archive/refs/heads/main.tar.gz",
            \\            // Update hash after first build attempt
            \\            // .hash = "",
            \\        }},
            \\    }},
            \\    .paths = .{{ "." }},
            \\}}
            \\
        , .{proj.metadata.name});
        defer proj.allocator.free(zon_content);

        try file.writeAll(zon_content);
    }

    /// Generate src/main.zig entry point
    pub fn generateMainZig(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        // Create src directory
        const src_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "src" });
        defer proj.allocator.free(src_path);

        std.fs.cwd().makeDir(src_path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };

        const main_path = try std.fs.path.join(proj.allocator, &.{ project_dir, "src", "main.zig" });
        defer proj.allocator.free(main_path);

        const file = try std.fs.cwd().createFile(main_path, .{});
        defer file.close();

        const main_content = try std.fmt.allocPrint(proj.allocator,
            \\const std = @import("std");
            \\const gfx = @import("labelle-gfx");
            \\const engine = @import("labelle-engine");
            \\const scripts = @import("scripts");
            \\
            \\pub fn main() !void {{
            \\    var gpa = std.heap.GeneralPurposeAllocator(.{{}}){{}};
            \\    defer _ = gpa.deinit();
            \\    const allocator = gpa.allocator();
            \\
            \\    // Initialize the engine
            \\    var game_engine = try engine.Engine.init(allocator, .{{
            \\        .title = "{s}",
            \\        .width = 1280,
            \\        .height = 720,
            \\    }});
            \\    defer game_engine.deinit();
            \\
            \\    // Register user scripts
            \\    scripts.registerAll(&game_engine);
            \\
            \\    // Load initial scene
            \\    try game_engine.loadScene("scenes/main.scene");
            \\
            \\    // Run the game loop
            \\    try game_engine.run();
            \\}}
            \\
        , .{proj.metadata.name});
        defer proj.allocator.free(main_content);

        try file.writeAll(main_content);
    }

    /// Generate scripts/root.zig that exports all user scripts
    pub fn generateScriptsRoot(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const scripts_dir = try std.fs.path.join(proj.allocator, &.{ project_dir, project.ProjectFolders.scripts });
        defer proj.allocator.free(scripts_dir);

        const root_path = try std.fs.path.join(proj.allocator, &.{ scripts_dir, "root.zig" });
        defer proj.allocator.free(root_path);

        // Check if root.zig already exists
        if (std.fs.cwd().access(root_path, .{})) {
            // File exists, don't overwrite user modifications
            return;
        } else |_| {
            // File doesn't exist, create it
        }

        const file = try std.fs.cwd().createFile(root_path, .{});
        defer file.close();

        const root_content =
            \\const std = @import("std");
            \\const engine = @import("labelle-engine");
            \\
            \\// Import your script modules here
            \\// pub const player = @import("player.zig");
            \\// pub const enemy = @import("enemy.zig");
            \\
            \\/// Register all scripts with the engine
            \\pub fn registerAll(game_engine: *engine.Engine) void {
            \\    _ = game_engine;
            \\    // Register your scripts here
            \\    // game_engine.registerScript("Player", player.Player);
            \\    // game_engine.registerScript("Enemy", enemy.Enemy);
            \\}
            \\
        ;

        try file.writeAll(root_content);
    }

    /// Generate a default scene file
    pub fn generateDefaultScene(self: *Self, proj: *const project.Project) !void {
        _ = self;
        const project_dir = proj.getProjectDir() orelse return error.NoProjectPath;

        const scenes_dir = try std.fs.path.join(proj.allocator, &.{ project_dir, project.ProjectFolders.scenes });
        defer proj.allocator.free(scenes_dir);

        const scene_path = try std.fs.path.join(proj.allocator, &.{ scenes_dir, "main.scene" });
        defer proj.allocator.free(scene_path);

        // Check if scene already exists
        if (std.fs.cwd().access(scene_path, .{})) {
            return;
        } else |_| {}

        const file = try std.fs.cwd().createFile(scene_path, .{});
        defer file.close();

        const scene_content = try std.fmt.allocPrint(proj.allocator,
            \\# {s} - Main Scene
            \\# This is the default scene loaded when the game starts
            \\
            \\[scene]
            \\name = "Main"
            \\
            \\[entities]
            \\# Define your entities here
            \\# Example:
            \\# [[entity]]
            \\# name = "Player"
            \\# prefab = "prefabs/player.prefab"
            \\# position = {{ x = 0, y = 0, z = 0 }}
            \\
        , .{proj.metadata.name});
        defer proj.allocator.free(scene_content);

        try file.writeAll(scene_content);
    }

    /// Generate all build files for the project
    pub fn generateAllBuildFiles(self: *Self, proj: *const project.Project) !void {
        self.state = .generating;
        errdefer self.state = .failed;

        try self.generateBuildZig(proj);
        try self.generateBuildZigZon(proj);
        try self.generateMainZig(proj);
        try self.generateScriptsRoot(proj);
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
