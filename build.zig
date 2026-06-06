const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "muzer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // zigzag
    const zigzag = b.dependency("zigzag", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("zigzag", zigzag.module("zigzag"));
    // zigzag


    // ma
    const ma = b.createModule(.{
        .root_source_file = b.path("src/ma.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("ma", ma);
    // ma

    // miniaudio
    const miniaudio = b.addTranslateC(.{
        .root_source_file = b.path("src/miniaudio.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }).createModule();

    miniaudio.addCSourceFile(.{
        .file = b.path("src/miniaudio.c"),
        .flags = &.{},
        .language = .c,
    });

    ma.addImport("miniaudio", miniaudio);
    // miniaudio

    b.installArtifact(exe);

    // Run
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    // Tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
}
