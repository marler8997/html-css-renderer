const builtin = @import("builtin");
const std = @import("std");

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

fn getCmdOpt(args: [][*:0]u8, i: *usize) []u8 {
    i.* += 1;
    if (i.* == args.len) {
        std.log.err("cmdline option '{s}' requires an argument", .{args[i.* - 1]});
        std.process.exit(0xff);
    }
    return std.mem.span(args[i.*]);
}

pub fn main() !u8 {
    const viewport_width: u32 = 600;
    var viewport_height: u32 = 600;

    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        var i: usize = 0;
        while (i < all_args.len) : (i += 1) {
            const arg = std.mem.span(all_args[i]);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else if (std.mem.eql(u8, arg, "--height")) {
                const str = getCmdOpt(all_args, &i);
                viewport_height = std.fmt.parseInt(u32, str, 10) catch |err|
                    fatal("invalid height '{s}': {s}", .{ str, @errorName(err) });
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

    const render_ctx = RenderCtx {
        .viewport_width = viewport_width,
        .viewport_height = viewport_height,
        .stride = viewport_width * bytes_per_pixel,
        .image = try global_arena.allocator().alloc(
            u8,
            @as(usize, viewport_width) * @as(usize, viewport_height) * 3,
        ),
    };
    @memset(render_ctx.image, 0xff);
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
    const context: *ParseContext = @alignCast(@ptrCast(context_ptr));
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
            // TODO: adjust the rectangle to make sure we only render
            //       what's visible in the viewport
            var image_offset: usize = (r.y * ctx.stride) + (r.x * bytes_per_pixel);
            if (r.fill) {
                var row: usize = 0;
                while (row < r.h) : (row += 1) {
                    if (image_offset >= ctx.image.len) return;
                    drawRow(ctx.image[image_offset..], r.w, r.color);
                    image_offset += ctx.stride;
                }
            } else {
                if (image_offset >= ctx.image.len) return;
                drawRow(ctx.image[image_offset..], r.w, r.color);
                var row: usize = 1;
                image_offset += ctx.stride;
                while (row + 1 < r.h) : (row += 1) {
                    if (image_offset >= ctx.image.len) return;
                    drawPixel(ctx.image[image_offset..], r.color);
                    const right = image_offset + ((r.w - 1) * bytes_per_pixel);
                    if (right >= ctx.image.len) return;
                    drawPixel(ctx.image[right..], r.color);
                    image_offset += ctx.stride;
                }
                if (image_offset >= ctx.image.len) return;
                drawRow(ctx.image[image_offset..], r.w, r.color);
            }
        },
        .text => |t| {
            // TODO: maybe don't remap/unmap pages for each drawText call?
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            drawText(arena.allocator(), ctx.image, ctx.stride, t.x, t.y, t.size, t.slice);
        },
    }
}

fn drawPixel(img: []u8, color: u32) void {
    img[0] = @as(u8, @intCast(0xff & (color >> 16)));
    img[1] = @as(u8, @intCast(0xff & (color >>  8)));
    img[2] = @as(u8, @intCast(0xff & (color >>  0)));
}
fn drawRow(img: []u8, width: u32, color: u32) void {
    var offset: usize = 0;
    const limit: usize = width * bytes_per_pixel;
    while (offset < limit) : (offset += bytes_per_pixel) {
        drawPixel(img[offset..], color);
    }
}

const times_new_roman = struct {
    pub const ttf = @embedFile("font/times-new-roman.ttf");
    pub const info = schrift.getTtfInfo(ttf) catch unreachable;
};
fn drawText(
    allocator: std.mem.Allocator,
    img: []u8,
    img_stride: usize,
    x: u32, y: u32,
    font_size: u32,
    text: []const u8,
) void {
    //std.log.info("drawText at {}, {} size={} text='{s}'", .{x, y, font_size, text});
    const scale: f64 = @floatFromInt(font_size);

    var pixels_array_list = std.ArrayListUnmanaged(u8){ };

    const lmetrics = schrift.lmetrics(times_new_roman.ttf, times_new_roman.info, scale) catch |err|
        std.debug.panic("failed to get lmetrics with {s}", .{@errorName(err)});
    var next_x = x;

    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (it.nextCodepoint()) |c| {
        const gid = schrift.lookupGlyph(times_new_roman.ttf, c) catch |err|
            std.debug.panic("failed to get glyph id for {}: {s}", .{c, @errorName(err)});
        const downward = true;
        const gmetrics = schrift.gmetrics(
            times_new_roman.ttf,
            times_new_roman.info,
            downward,
            .{ .x = scale, .y = scale },
            .{ .x = 0, .y = 0 },
            gid,
        ) catch |err| std.debug.panic("gmetrics for char {} failed with {s}", .{c, @errorName(err)});
        const glyph_size = layout.XY(u32) {
            .x = std.mem.alignForward(u32, @intCast(gmetrics.min_width), 4),
            .y = @intCast(gmetrics.min_height),
        };
        //std.log.info("  c={} size={}x{} adv={d:.0}", .{c, glyph_size.x, glyph_size.y, @ceil(gmetrics.advance_width)});
        const pixel_len = @as(usize, glyph_size.x) * @as(usize, glyph_size.y);
        pixels_array_list.ensureTotalCapacity(allocator, pixel_len) catch |e| oom(e);
        const pixels = pixels_array_list.items.ptr[0 .. pixel_len];
        schrift.render(
            allocator,
            times_new_roman.ttf,
            times_new_roman.info,
            downward,
            .{ .x = scale, .y = scale },
            .{ .x = 0, .y = 0 },
            pixels,
            .{ .x = @intCast(glyph_size.x), .y = @intCast(glyph_size.y) },
            gid,
        ) catch |err| std.debug.panic("render for char {} failed with {s}", .{c, @errorName(err)});

        {
            var glyph_y: usize = 0;
            while (glyph_y < glyph_size.y) : (glyph_y += 1) {
                const row_offset_i32 = (
                    @as(i32, @intCast(y)) +
                    @as(i32, @intFromFloat(@ceil(lmetrics.ascender))) +
                    gmetrics.y_offset +
                    @as(i32, @intCast(glyph_y))
                ) * @as(i32, @intCast(img_stride));
                if (row_offset_i32 < 0) continue;

                const row_offset: usize = @intCast(row_offset_i32);

                var glyph_x: usize = 0;
                while (glyph_x < glyph_size.x) : (glyph_x += 1) {
                    const image_pos = row_offset + (next_x + glyph_x) * bytes_per_pixel;
                    if (image_pos + bytes_per_pixel <= img.len) {
                        const grayscale = 255 - pixels[glyph_y * glyph_size.x + glyph_x];
                        const color =
                            (@as(u32, grayscale) << 16) |
                            (@as(u32, grayscale) <<  8) |
                            (@as(u32, grayscale) <<  0) ;
                        drawPixel(img[image_pos..], color);
                    }
                }
            }
        }
        next_x += @intFromFloat(@ceil(gmetrics.advance_width));
    }
}
