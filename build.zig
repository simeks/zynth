const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const dep_pulseaudio = b.dependency("pulseaudio", .{});

    const exe = b.addExecutable(.{
        .name = "zynth",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{
                    .name = "pulseaudio",
                    .module = dep_pulseaudio.module("pulseaudio"),
                },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run app");

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_exe.step);
}
