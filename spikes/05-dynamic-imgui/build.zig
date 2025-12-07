const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
    });

    const zopengl = b.dependency("zopengl", .{});

    const zgui = b.dependency("zgui", .{
        .target = target,
        .optimize = optimize,
        .backend = .glfw_opengl3,
    });

    // Build the host application
    const exe = b.addExecutable(.{
        .name = "dynamic-imgui-spike",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zglfw", zglfw.module("root"));
    exe.linkLibrary(zglfw.artifact("glfw"));

    exe.root_module.addImport("zopengl", zopengl.module("root"));

    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    b.installArtifact(exe);

    // Build example plugins as shared libraries
    const plugin1 = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "counter_plugin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/counter_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(plugin1);

    const plugin2 = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "color_plugin",
        .root_module = b.createModule(.{
            .root_source_file = b.path("plugins/color_plugin.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(plugin2);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the spike");
    run_step.dependOn(&run_cmd.step);
}
