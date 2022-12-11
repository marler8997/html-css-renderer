const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");
const htmlid = @import("htmlid.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const id_maps_src = b.pathJoin(&.{ b.build_root, "htmlidmaps.zig"});
    const gen_id_maps = b.addWriteFile(id_maps_src, allocIdMapSource(b.allocator));

    {
        const exe = b.addExecutable("lint", "lint.zig");
        exe.step.dependOn(&gen_id_maps.step);
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.install();
    }

    const schrift_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/tomolt/libschrift",
        .branch = null,
        .sha = "abbf37b8aab0c077adfb40bfc7a50dcaccb69e2a",
        .fetch_enabled = true,
    });
    const libschrift = addLibschrift(b, schrift_repo, &[_][]const u8 {});
    libschrift.setBuildMode(mode);
    libschrift.setTarget(target);

    const zigx_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/marler8997/zigx",
        .branch = null,
        .sha = "ae6556f75f0e65082cea7724e46b9ca16da9220b",
        .fetch_enabled = true,
    });
    {
        const exe = b.addExecutable("x11renderer", "x11renderer.zig");
        exe.step.dependOn(&gen_id_maps.step);
        exe.step.dependOn(&zigx_repo.step);
        //exe.step.dependOn(&schrift_repo.step);
        exe.linkLibrary(libschrift);
        exe.addPackagePath("x11", b.pathJoin(&.{ zigx_repo.path, "x.zig" }));
        exe.setTarget(target);
        exe.setBuildMode(mode);
        const install = b.addInstallArtifact(exe);
        b.step("x11", "build/install the x11renderer").dependOn(&install.step);
    }

    {
        const wasm_target = std.zig.CrossTarget{ .cpu_arch = .wasm32, .os_tag = .freestanding };

        const libschrift_wasm = addLibschrift(b, schrift_repo, &[_][]const u8 {
            // workaround https://github.com/ziglang/zig/issues/13890
            "-DENOMEM=12",
        });
        libschrift_wasm.setBuildMode(mode);
        libschrift_wasm.setTarget(wasm_target);

        const exe = b.addSharedLibrary("wasmrenderer", "wasmrenderer.zig", .unversioned);
        exe.step.dependOn(&gen_id_maps.step);
        exe.linkLibrary(libschrift_wasm);
        exe.linkLibC();
        exe.addIncludePath(schrift_repo.path);
        exe.setBuildMode(mode);
        exe.setTarget(wasm_target);

        const make_exe = b.addExecutable("make-renderer-webpage", "make-renderer-webpage.zig");
        const run = make_exe.run();
        run.addArtifactArg(exe);
        run.addFileSourceArg(.{ .path = "html-css-renderer.template.html"});
        run.addArg(b.pathJoin(&.{ b.install_path, "html-css-renderer.html" }));
        b.step("wasm", "build the wasm-based renderer").dependOn(&run.step);
    }
}

fn addLibschrift(
    b: *std.build.Builder,
    schrift_repo: *GitRepoStep,
    comptime extra_cflags: []const []const u8,
) *std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("schrift", null);
    lib.addCSourceFiles(&[_][]const u8 {
        b.pathJoin(&.{schrift_repo.path, "schrift.c"}),
    }, &[_][]const u8 {
        "-std=c99", "-pedantic", "-Wall", "-Wextra", "-Wconversion",
    } ++ extra_cflags);
    lib.linkLibC();
    {
        //cc -c -g -Os -std=c99 -pedantic -Wall -Wextra demo.c -o demo.o -I./ -I/usr/include/X11
        //cc -Os -std=c99 -pedantic -Wall -Wextra -Wconversion   -c -o schrift.o schrift.c
        //ar rc libschrift.a schrift.o
        //ranlib libschrift.a
        //cc -g -Os demo.o -o demo -L/usr/lib/X11 -L. -lX11 -lXrender -lschrift -lm
    }
    lib.step.dependOn(&schrift_repo.step);
    return lib;
}

fn allocIdMapSource(allocator: std.mem.Allocator) []const u8 {
    var src = std.ArrayList(u8).init(allocator);
    errdefer src.deinit();
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
        for (field.name) |c, i| {
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
