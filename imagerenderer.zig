const builtin = @import("builtin");
const std = @import("std");

const dom = @import("dom.zig");
const layout = @import("layout.zig");
const XY = layout.XY;
const Styler = layout.Styler;
const render = @import("render.zig");
const alext = @import("alext.zig");

var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};

pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..]) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !u8 {
    var viewport_width: u32 = 600;
    const viewport_height: u32 = 600;

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
    if (args.len != 1) {
        try std.io.getStdErr().writer().writeAll("Usage: imagerenderer FILE\n");
        return 0xff;
    }
    const filename = std.mem.span(args[0]);

    const content = blk: {
        var file = std.fs.cwd().openFile(filename, .{}) catch |err|
            fatal("failed to open '{s}' with {s}", .{filename, @errorName(err)});
        defer file.close();
        break :blk try file.readToEndAlloc(global_arena.allocator(), std.math.maxInt(usize));
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
        .{ .x = viewport_width, .y = viewport_height },
        Styler{ },
    ) catch |err|
        // TODO: maybe draw this error as text?
        fatal("layout failed, error={s}", .{@errorName(err)});
    alext.unmanaged.finalize(layout.LayoutNode, &layout_nodes, global_arena.allocator());

    var render_ctx = RenderCtx {
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .stride = viewport_width * bytes_per_pixel,
        .image = try global_arena.allocator().alloc(
            u8,
            @intCast(usize, viewport_width) * @intCast(usize, viewport_height) * 3,
        ),
    };
    std.mem.set(u8, render_ctx.image, 0xff);
    try render.render(content, dom_nodes.items, layout_nodes.items, RenderCtx, &onRender, render_ctx);

    var out_file = try std.fs.cwd().createFile("render.ppm", .{});
    defer out_file.close();
    const writer = out_file.writer();
    try writer.print("P6\n{} {}\n255\n", .{viewport_width, viewport_height});
    try writer.writeAll(render_ctx.image);

    return 0;
}

const ParseContext = struct {
    filename: []const u8,
};

fn onParseError(context_ptr: ?*anyopaque, msg: []const u8) void {
    const context = @intToPtr(*ParseContext, @ptrToInt(context_ptr));
    std.io.getStdErr().writer().print("{s}: parse error: {s}\n", .{context.filename, msg}) catch |err|
        std.debug.panic("failed to print parse error with {s}", .{@errorName(err)});
}

const bytes_per_pixel = 3;

const RenderCtx = struct {
    viewport_width: u32,
    viewport_height: u32,
    stride: usize,
    image: []u8,
};

fn onRender(ctx: RenderCtx, op: render.Op) !void {
    switch (op) {
        .rect => |r| {
            if (r.fill) {
                @panic("todo");
            } else {
                var row: usize = 0;
                var image_offset: usize = (r.y * ctx.stride) + (r.x * bytes_per_pixel);
                drawRow(ctx.image[image_offset..], r.w, r.color);
                row += 1;
                image_offset += ctx.stride;
                while (row + 1 < r.h) : (row += 1) {
                    drawPixel(ctx.image[image_offset..], r.color);
                    drawPixel(ctx.image[image_offset + ((r.w - 1) * bytes_per_pixel)..], r.color);
                    image_offset += ctx.stride;
                }
                drawRow(ctx.image[image_offset..], r.w, r.color);
            }
        },
        .text => |t| {
            std.log.info("TODO: render text '{s}'", .{t.slice});
        },
    }
}

fn drawPixel(img: []u8, color: u32) void {
    img[0] = @intCast(u8, 0xff & (color >> 16));
    img[1] = @intCast(u8, 0xff & (color >>  8));
    img[2] = @intCast(u8, 0xff & (color >>  0));
}
fn drawRow(img: []u8, width: u32, color: u32) void {
    var offset: usize = 0;
    var limit: usize = width * bytes_per_pixel;
    while (offset < limit) : (offset += bytes_per_pixel) {
        drawPixel(img[offset..], color);
    }
}
