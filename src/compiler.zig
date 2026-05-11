const std = @import("std");
const project = @import("project.zig");

pub const CompilerError = error{
    NoProjectOpen,
    NoProjectPath,
    InvalidProjectPath,
    LauncherNotFound,
    LauncherFailed,
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

/// Drives the `labelle` CLI launcher to generate/build/run a project.
///
/// We invoke the launcher rather than the bare `labelle-assembler` binary
/// because the assembler's `generate` step depends on a populated package
/// cache at `~/.labelle/packages/<name>/<version>/` and on the right
/// assembler binary being resolved at `~/.labelle/assembler/<version>/`.
/// The launcher is what wires those layers up — see
/// `labelle-cli/src/cli/cache.zig` for the resolution logic. Calling the
/// bare assembler from here fails on any machine that hasn't already run
/// the launcher to prime the cache, which is unworkable as a default flow.
///
/// Versions are pinned in `project.labelle` (set by `ProjectConfig`'s
/// defaults). The launcher reads them via `assembler_version`,
/// `core_version`, `engine_version`, `gfx_version` and fetches matching
/// artifacts on demand.
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
        if (self.last_result) |*result| result.deinit(self.allocator);
        if (self.build_process) |*proc| {
            _ = proc.kill() catch {};
        }
    }

    /// Ensure the project on disk reflects the in-memory config: writes
    /// `project.labelle` and creates the scaffold folders. Idempotent.
    pub fn syncProjectFiles(self: *Self, pm: *project.ProjectManager) !void {
        _ = self;
        const dir = blk: {
            const proj = pm.current_project orelse return error.NoProjectOpen;
            break :blk proj.dir orelse return error.NoProjectPath;
        };
        try pm.saveProject(dir);
    }

    /// Run `labelle generate <project_dir>` synchronously. Surfaces output
    /// via the returned result; the caller frees with `result.deinit`.
    pub fn launcherGenerate(self: *Self, proj: *const project.Project) !CompilationResult {
        const dir = proj.dir orelse return error.NoProjectPath;

        self.state = .generating;
        errdefer self.state = .failed;

        var child = std.process.Child.init(&.{ "labelle", "generate", dir }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            else => return err,
        };

        const result = try child.wait();
        const stdout = if (child.stdout) |f| try f.readToEndAlloc(self.allocator, 1024 * 1024) else "";
        const stderr = if (child.stderr) |f| try f.readToEndAlloc(self.allocator, 1024 * 1024) else "";

        const success = result == .Exited and result.Exited == 0;
        if (!success) self.state = .failed;
        return .{ .success = success, .output = stdout, .errors = stderr };
    }

    /// Spawn `labelle build` or `labelle run` in the project directory.
    /// Returns once the child is spawned; the caller polls via `pollBuild`.
    fn buildOrRun(self: *Self, proj: *const project.Project, comptime is_run: bool) !void {
        const dir = proj.dir orelse return error.NoProjectPath;

        if (self.last_result) |*r| {
            r.deinit(self.allocator);
            self.last_result = null;
        }

        self.state = if (is_run) .running else .building;
        errdefer self.state = .failed;

        const argv: []const []const u8 = if (is_run)
            &.{ "labelle", "run", dir }
        else
            &.{ "labelle", "build", dir };

        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        child.spawn() catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            else => return err,
        };
        self.build_process = child;
    }

    pub fn build(self: *Self, proj: *const project.Project) !void {
        return self.buildOrRun(proj, false);
    }

    pub fn run(self: *Self, proj: *const project.Project) !void {
        return self.buildOrRun(proj, true);
    }

    /// Wait for the spawned `labelle build`/`labelle run` child to exit and
    /// capture its output. The launcher already handles cache priming and
    /// fingerprint patching internally, so a non-zero exit is final — no
    /// retry pass needed.
    pub fn pollBuild(self: *Self) ?CompilationResult {
        if (self.state != .building and self.state != .running) return null;
        if (self.build_process == null) return null;

        var child = self.build_process.?;
        const wait_result = child.wait() catch |err| {
            self.build_process = null;
            self.state = .failed;
            self.last_result = .{
                .success = false,
                .output = "",
                .errors = std.fmt.allocPrint(self.allocator, "Process error: {}", .{err}) catch "",
            };
            return self.last_result;
        };

        const stdout = if (child.stdout) |f| f.readToEndAlloc(self.allocator, 1024 * 1024) catch "" else "";
        const stderr = if (child.stderr) |f| f.readToEndAlloc(self.allocator, 1024 * 1024) catch "" else "";
        self.build_process = null;

        const success = wait_result == .Exited and wait_result.Exited == 0;
        self.state = if (success) .success else .failed;
        self.last_result = .{ .success = success, .output = stdout, .errors = stderr };
        return self.last_result;
    }

    pub fn getState(self: *const Self) CompilerState {
        return self.state;
    }

    pub fn isIdle(self: *const Self) bool {
        return self.state == .idle or self.state == .success or self.state == .failed;
    }
};
