const std = @import("std");
const htmlid = @import("htmlid.zig");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const id_maps_src = b.pathFromRoot("htmlidmaps.zig");
    const gen_id_maps = b.addWriteFile(id_maps_src, allocIdMapSource(b.allocator));

    {
        const exe = b.addExecutable(.{
            .name = "lint",
            .root_source_file = b.path("lint.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.step.dependOn(&gen_id_maps.step);
        b.installArtifact(exe);
    }

    {
        const exe = b.addExecutable(.{
            .name = "imagerenderer",
            .root_source_file = b.path("imagerenderer.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.step.dependOn(&gen_id_maps.step);
        const install = b.addInstallArtifact(exe, .{});
        b.step("image", "build/install imagerenderer").dependOn(&install.step);
    }

    const zigx_dep = b.dependency("zigx", .{});
    const zigx_mod = zigx_dep.module("zigx");

    {
        const exe = b.addExecutable(.{
            .name = "x11renderer",
            .root_source_file = b.path("x11renderer.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.step.dependOn(&gen_id_maps.step);
        exe.root_module.addImport("x11", zigx_mod);
        const install = b.addInstallArtifact(exe, .{});
        b.step("x11", "build/install the x11renderer").dependOn(&install.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "wasmrenderer",
            .root_source_file = b.path("wasmrenderer.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
        });
        exe.entry = .disabled;
        //exe.export_table = true;
        exe.root_module.export_symbol_names = &.{
            "alloc",
            "release",
            "onResize",
            "loadHtml",
        };

        const make_exe = b.addExecutable(.{
            .name = "make-renderer-webpage",
            .root_source_file = b.path("make-renderer-webpage.zig"),
            .target = b.graph.host,
        });
        const run = b.addRunArtifact(make_exe);
        run.addArtifactArg(exe);
        run.addFileArg(b.path("html-css-renderer.template.html"));
        run.addArg(b.pathJoin(&.{ b.install_path, "html-css-renderer.html" }));
        b.step("wasm", "build the wasm-based renderer").dependOn(&run.step);
    }

    {
        const exe = b.addExecutable(.{
            .name = "testrunner",
            .root_source_file = b.path("testrunner.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe.step.dependOn(&gen_id_maps.step);
        const install = b.addInstallArtifact(exe, .{});
        const test_step = b.step("test", "run tests");
        test_step.dependOn(&install.step); // make testrunner easily accessible
        inline for ([_][]const u8{"hello.html"}) |test_filename| {
            const run_step = b.addRunArtifact(exe);
            run_step.addFileArg(b.path("test/" ++  test_filename));
            run_step.expectStdOutEqual("Success\n");
            test_step.dependOn(&run_step.step);
        }
    }
}

fn allocIdMapSource(allocator: std.mem.Allocator) []const u8 {
    var src = std.ArrayList(u8).init(allocator);
    defer src.deinit();
    writeIdMapSource(src.writer()) catch unreachable;
    return src.toOwnedSlice() catch unreachable;
}

fn writeIdMapSource(writer: anytype) !void {
    try writer.writeAll(
        \\const std = @import("std");
        \\const htmlid = @import("htmlid.zig");
        \\
    );
    try writeIdEnum(writer, htmlid.TagId, "tag");
    try writeIdEnum(writer, htmlid.AttrId, "attr");
}
fn writeIdEnum(writer: anytype, comptime Enum: type, name: []const u8) !void {
    try writer.print(
        \\
        \\pub const {s} = struct {{
        \\    pub const Enum = {s};
        \\    pub const map = blk: {{
        \\        @setEvalBranchQuota(6000);
        \\        break :blk std.ComptimeStringMap(Enum, .{{
        \\
        , .{name, @typeName(Enum)});
    inline for (@typeInfo(Enum).Enum.fields) |field| {
        var lower_buf: [field.name.len]u8 = undefined;
        for (field.name, 0..) |c, i| {
            lower_buf[i] = std.ascii.toLower(c);
        }
        try writer.print("            .{{ \"{s}\", .{} }},\n", .{lower_buf, std.zig.fmtId(field.name)});
    }
    try writer.writeAll(
        \\        });
        \\    };
        \\};
        \\
    );
}
