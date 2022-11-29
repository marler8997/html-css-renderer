const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    {
        const exe = b.addExecutable("lint", "src/lint.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }
    {
        const exe = b.addExecutable("playground", "src/playground.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }

    const build_tools = b.step("buildtools", "build/install the build tools");
    {
        const exe = b.addExecutable("fsveil", "fsveil.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
        build_tools.dependOn(&exe.install_step.?.step);
    }
    {
        const exe = b.addExecutable("which", "which.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
        build_tools.dependOn(&exe.install_step.?.step);
    }
}
