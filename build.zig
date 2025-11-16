const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(u16, "teacher_limit", b.option(u16, "teacher_limit", "Maximum amount of teachers that can be handled") orelse 255);
    options.addOption(u16, "class_limit", b.option(u16, "class_limit", "Maximum amount of classes that can be handled") orelse 63);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("options", options.createModule());

    const exe = b.addExecutable(.{
        .name = "KKP",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const exe_run = b.addRunArtifact(exe);
    if (b.args) |args| exe_run.addArgs(args);
    const run_step = b.step("run", "Run KKP");
    run_step.dependOn(&exe_run.step);
}
