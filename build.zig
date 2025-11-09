const std = @import("std");
const simeks = @import("simeks");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const pulseaudio_dep = b.dependency("pulseaudio", .{
        .target = target,
        .optimize = optimize,
    });
    const simeks_dep = b.dependency("simeks", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zynth",
        .root_module = b.createModule(.{
            .optimize = optimize,
            .target = target,
            .root_source_file = b.path("src/main.zig"),
        }),
    });

    exe.root_module.addImport("pulseaudio", pulseaudio_dep.module("pulseaudio"));
    exe.root_module.addImport("score", simeks_dep.module("core"));
    exe.root_module.addImport("smath", simeks_dep.module("math"));
    exe.root_module.addImport("sgpu", simeks_dep.module("gpu"));
    exe.root_module.addImport("sgui", simeks_dep.module("gui"));
    exe.root_module.addImport("sos", simeks_dep.module("os"));

    simeks.linkSystemLibraries(exe);

    b.installArtifact(exe);

    const shader_step = b.step("shaders", "Build shaders");
    const shaders = .{
        "gui.vert",
        "gui.frag",
    };
    inline for (shaders) |shader| {
        const step = buildShader(b, b.path("src/shaders/" ++ shader), shader ++ ".spv");
        shader_step.dependOn(step);
    }
    b.getInstallStep().dependOn(shader_step);

    const run_step = b.step("run", "Run app");
    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_exe.step);
}

fn buildShader(
    b: *std.Build,
    glsl_path: std.Build.LazyPath,
    install_name: []const u8,
) *std.Build.Step {
    const cmd = b.addSystemCommand(&.{
        "glslc",
        "-fentry-point=main",
        "--target-env=vulkan1.2",
        "-o",
    });
    const spv = cmd.addOutputFileArg("shader.spv");
    cmd.addFileArg(glsl_path);

    const install = b.addInstallBinFile(spv, install_name);
    return &install.step;
}
