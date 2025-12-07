const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the host application
    const exe = b.addExecutable(.{
        .name = "dynamic-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Build the example plugin as a shared library
    const plugin = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "example_plugin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/example_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(plugin);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the spike");
    run_step.dependOn(&run_cmd.step);
}
