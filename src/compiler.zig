const std = @import("std");
const project = @import("project.zig");
const io_global = @import("io_global.zig");

pub const CompilerError = error{
    NoProjectOpen,
    NoProjectPath,
    InvalidProjectPath,
    LauncherNotFound,
    LauncherFailed,
    CompilationFailed,
    OutOfMemory,
} || std.Io.File.OpenError || std.Io.File.Writer.Error;

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
    /// In 0.16, std.process.run is synchronous. We retain a pending
    /// flag so pollBuild() returns the result exactly once after a
    /// build/run is requested, preserving the caller's polling shape.
    has_pending_result: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .state = .idle,
            .last_result = null,
            .has_pending_result = false,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_result) |*result| result.deinit(self.allocator);
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

        const result = std.process.run(self.allocator, io_global.io(), .{
            .argv = &.{ "labelle", "generate", dir },
        }) catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            else => return err,
        };

        const success = result.term == .exited and result.term.exited == 0;
        if (!success) self.state = .failed;
        return .{ .success = success, .output = result.stdout, .errors = result.stderr };
    }

    /// Spawn `labelle build` or `labelle run` in the project directory.
    /// Synchronous in 0.16 — the caller polls via `pollBuild` to fetch
    /// the result on a subsequent frame.
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

        const result = std.process.run(self.allocator, io_global.io(), .{
            .argv = argv,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.LauncherNotFound,
            else => return err,
        };

        const success = result.term == .exited and result.term.exited == 0;
        self.state = if (success) .success else .failed;
        self.last_result = .{ .success = success, .output = result.stdout, .errors = result.stderr };
        self.has_pending_result = true;
    }

    pub fn build(self: *Self, proj: *const project.Project) !void {
        return self.buildOrRun(proj, false);
    }

    pub fn run(self: *Self, proj: *const project.Project) !void {
        return self.buildOrRun(proj, true);
    }

    /// Return the most recent build/run result exactly once. The launcher
    /// already handles cache priming and fingerprint patching internally,
    /// so a non-zero exit is final — no retry pass needed.
    pub fn pollBuild(self: *Self) ?CompilationResult {
        if (!self.has_pending_result) return null;
        self.has_pending_result = false;
        return self.last_result;
    }

    pub fn getState(self: *const Self) CompilerState {
        return self.state;
    }

    pub fn isIdle(self: *const Self) bool {
        return self.state == .idle or self.state == .success or self.state == .failed;
    }
};
