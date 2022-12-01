const std = @import("std");
const htmlid = @import("src/htmlid.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const id_maps_src = b.pathJoin(&.{ b.build_root, "src", "htmlidmaps.zig"});
    const gen_id_maps = b.addWriteFile(id_maps_src, allocIdMapSource(b.allocator));

    {
        const exe = b.addExecutable("lint", "src/lint.zig");
        exe.step.dependOn(&gen_id_maps.step);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }

    {
        const exe = b.addExecutable("playground", "src/playground.zig");
        exe.step.dependOn(&gen_id_maps.step);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }

    const build_tools = b.step("buildtools", "build/install the build tools");
    {
        const exe = b.addExecutable("fsveil", "fsveil.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        const install = b.addInstallArtifact(exe);
        build_tools.dependOn(&install.step);
    }
    {
        const exe = b.addExecutable("which", "which.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        const install = b.addInstallArtifact(exe);
        build_tools.dependOn(&install.step);
    }
}

fn allocIdMapSource(allocator: std.mem.Allocator) []const u8 {
    var src = std.ArrayList(u8).init(allocator);
    errdefer src.deinit();
    writeIdMapSource(src.writer()) catch unreachable;
    return src.toOwnedSlice();
}

fn writeIdMapSource(writer: anytype) !void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const htmlid = @import("htmlid.zig");
        \\pub const tag_id_map = blk: {
        \\    @setEvalBranchQuota(3000);
        \\    break :blk std.ComptimeStringMap(htmlid.TagId, .{
        \\
    );
    inline for (@typeInfo(htmlid.TagId).Enum.fields) |field| {
        var lower_buf: [field.name.len]u8 = undefined;
        for (field.name) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        try writer.print("        .{{ \"{s}\", .{} }},\n", .{lower_buf, std.zig.fmtId(field.name)});
    }
    try writer.writeAll(
        \\    });
        \\};
        \\pub const attr_id_map = blk: {
        \\    @setEvalBranchQuota(4000);
        \\    break :blk std.ComptimeStringMap(htmlid.AttrId, .{
        \\
    );
    inline for (@typeInfo(htmlid.AttrId).Enum.fields) |field| {
        var lower_buf: [field.name.len]u8 = undefined;
        for (field.name) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        try writer.print("        .{{ \"{s}\", .{} }},\n", .{lower_buf, std.zig.fmtId(field.name)});
    }
    try writer.writeAll(
        \\    });
        \\};
        \\
    );
}
