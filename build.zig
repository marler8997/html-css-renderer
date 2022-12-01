const std = @import("std");
const htmlid = @import("src/htmlid.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    {
        const exe = b.addExecutable("lint", "src/lint.zig");
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }

    const id_maps_src = b.pathJoin(&.{ b.build_root, "src", "htmlidmaps.zig"});
    const gen_id_maps = GenIdMapsStep.create(b, id_maps_src);

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

const GenIdMapsStep = struct {
    step: std.build.Step,
    out_file: []const u8,
    pub fn create(b: *std.build.Builder, out_file: []const u8) *GenIdMapsStep {
        const step = b.allocator.create(GenIdMapsStep) catch unreachable;
        step.* = .{
            .step = std.build.Step.init(.custom, "generate id maps", b.allocator, make),
            .out_file = out_file,
        };
        return step;
    }
    fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(GenIdMapsStep, "step", step);

        // TODO: cache this result
        var file = try std.fs.cwd().createFile(self.out_file, .{});
        defer file.close();
        const out = file.writer();
        try out.writeAll(
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
            try out.print("        .{{ \"{s}\", .{} }},\n", .{lower_buf, std.zig.fmtId(field.name)});
        }
        try out.writeAll(
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
            try out.print("        .{{ \"{s}\", .{} }},\n", .{lower_buf, std.zig.fmtId(field.name)});
        }
        try out.writeAll(
            \\    });
            \\};
            \\
        );
    }
};
