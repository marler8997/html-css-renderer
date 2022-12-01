const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");
const htmlid = @import("src/htmlid.zig");

pub fn build(b: *std.build.Builder) void {
    const build_tools = b.step("buildtools", "build/install the build tools");
    {
        const exe = b.addExecutable("fsveil", "fsveil.zig");
        const install = b.addInstallArtifact(exe);
        build_tools.dependOn(&install.step);
    }
    {
        const exe = b.addExecutable("which", "which.zig");
        const install = b.addInstallArtifact(exe);
        build_tools.dependOn(&install.step);
    }

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

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "28096f1ef60bbf688adf83b9593587c3f155f57b",
        .fetch_enabled = true,
    });
    {
        const exe = b.addExecutable("x11renderer", "src/x11renderer.zig");
        exe.step.dependOn(&gen_id_maps.step);
        exe.step.dependOn(&zigx_repo.step);
        exe.addPackagePath("x11", b.pathJoin(&.{ zigx_repo.path, "x.zig" }));
        exe.setTarget(target);
        exe.setBuildMode(mode);
        const install = b.addInstallArtifact(exe);
        b.step("x11", "build/install the x11renderer").dependOn(&install.step);
    }

    {
        const exe = b.addSharedLibrary("wasmrenderer", "src/wasmrenderer.zig", .unversioned);
        exe.setBuildMode(mode);
        exe.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });

        const make_exe = b.addExecutable("make-renderer-webpage", "src/make-renderer-webpage.zig");
        const run = make_exe.run();
        run.addArtifactArg(exe);
        run.addFileSourceArg(.{ .path = "src/renderer.template.html"});
        run.addArg(b.pathJoin(&.{ b.build_root, "html-css-renderer.html" }));
        b.step("wasm", "build the wasm-based renderer").dependOn(&run.step);
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
