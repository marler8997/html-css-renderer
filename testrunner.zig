const builtin = @import("builtin");
const std = @import("std");

//pub const log_level = .err;

const dom = @import("dom.zig");
const layout = @import("layout.zig");
const XY = layout.XY;
const Styler = layout.Styler;
const render = @import("render.zig");
const alext = @import("alext.zig");
const schrift = @import("font/schrift.zig");

var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};

pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..], 0..) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !u8 {
    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        for (all_args) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };

    if (args.len == 0) {
        try std.io.getStdErr().writer().writeAll("Usage: testrunner TEST_FILE\n");
        return 0xff;
    }
    if (args.len != 1)
        fatal("expected 1 cmd-line arg but got {}", .{args.len});

    const filename = std.mem.span(args[0]);

    const content = blk: {
        var file = std.fs.cwd().openFile(filename, .{}) catch |err|
            fatal("failed to open '{s}' with {s}", .{filename, @errorName(err)});
        defer file.close();
        break :blk try file.readToEndAlloc(global_arena.allocator(), std.math.maxInt(usize));
    };


    const Expected = struct {
        out: []const u8,
        viewport_size: XY(u32),
    };
    const expected: Expected = expected_blk: {
        var line_it = std.mem.split(u8, content, "\n");
        {
            const line = line_it.first();
            if (!std.mem.eql(u8, line, "<!DOCTYPE html>"))
                fatal("expected first line of test file to be '<!DOCTYPE html>' but got '{}'", .{std.zig.fmtEscapes(line)});
        }
        {
            const line = line_it.next() orelse fatal("test file is missing '<!--' to delimite expected output", .{});
            if (!std.mem.eql(u8, line, "<!--"))
                fatal("expected second line of test file to be '<!--' but got '{}'", .{std.zig.fmtEscapes(line)});
        }

        const viewport_size: XY(u32) = size_blk: {
            const size_line = line_it.next() orelse fatal("test file is missing viewport size line (WIDTHxHEIGHT)", .{});
            var dim_it = std.mem.split(u8, size_line, "x");
            const width_str = dim_it.first();
            const height_str = dim_it.next() orelse fatal("viewport size line '{s}' should be of the form WIDTHxHEIGHT", .{size_line});
            if (dim_it.next()) |_| fatal("viewport size line '{s}' should be of the form WIDTHxHEIGHT", .{size_line});
            break :size_blk XY(u32) {
                .x = std.fmt.parseInt(u32, width_str, 10) catch |err|
                    fatal("invalid width '{s}': {s}", .{width_str, @errorName(err)}),
                .y = std.fmt.parseInt(u32, height_str, 10) catch |err|
                    fatal("invalid height '{s}': {s}", .{height_str, @errorName(err)}),
            };
        };
        const start = line_it.index.?;
        while (true) {
            const last_start = line_it.index.?;
            const line = line_it.next() orelse
                fatal("test file is missing line '-->' to delimit end of expected output", .{});
            if (std.mem.eql(u8, line, "-->")) break :expected_blk .{
                .out = std.mem.trimRight(u8, content[start .. last_start], "\n"),
                .viewport_size = viewport_size,
            };
        }
    };

    var parse_context = ParseContext{ .filename = filename };
    var dom_nodes = dom.parse(global_arena.allocator(), content, .{
        .context = &parse_context,
        .on_error = onParseError,
    }) catch |err| switch (err) {
        error.ReportedParseError => return 0xff,
        else => |e| return e,
    };
    alext.unmanaged.finalize(dom.Node, &dom_nodes, global_arena.allocator());

    //try dom.dump(content, dom_nodes.items);
    var layout_nodes = layout.layout(
        global_arena.allocator(),
        content,
        dom_nodes.items,
        expected.viewport_size,
        Styler{ },
    ) catch |err|
        // TODO: maybe draw this error as text?
        fatal("layout failed, error={s}", .{@errorName(err)});
    alext.unmanaged.finalize(layout.LayoutNode, &layout_nodes, global_arena.allocator());

    var actual_out_al = std.ArrayListUnmanaged(u8){ };
    try actual_out_al.ensureTotalCapacity(global_arena.allocator(), expected.out.len);
    for (layout_nodes.items) |node| {
        try node.serialize(actual_out_al.writer(global_arena.allocator()));
    }
    const actual_out = std.mem.trimRight(u8, actual_out_al.items, "\n");

    const stdout = std.io.getStdOut().writer();
    if (std.mem.eql(u8, expected.out, actual_out)) {
        try stdout.writeAll("Success\n");
        return 0;
    }
    try stdout.writeAll("Layout Mismatch:\n");
    try stdout.print(
        \\------- expected -------
        \\{s}
        \\-------  actual  -------
        \\{s}
        \\------------------------
        \\
        , .{expected.out, actual_out});
    {
        var file = try std.fs.cwd().createFile("expected", .{});
        defer file.close();
        try file.writer().writeAll(expected.out);
    }
    {
        var file = try std.fs.cwd().createFile("actual", .{});
        defer file.close();
        try file.writer().writeAll(actual_out);
    }
    return 0xff;
}

const ParseContext = struct {
    filename: []const u8,
};

fn onParseError(context_ptr: ?*anyopaque, msg: []const u8) void {
    const context: *ParseContext = @alignCast(@ptrCast(context_ptr));
    std.io.getStdErr().writer().print("{s}: parse error: {s}\n", .{context.filename, msg}) catch |err|
        std.debug.panic("failed to print parse error with {s}", .{@errorName(err)});
}
