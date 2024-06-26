const builtin = @import("builtin");
const std = @import("std");
const x11 = @import("x11");

const dom = @import("dom.zig");
const layout = @import("layout.zig");
const XY = layout.XY;
const Styler = layout.Styler;
const render = @import("render.zig");
const alext = @import("alext.zig");

var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const window_width = 600;
const window_height = 600;

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
    try x11.wsaStartup();
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
        try std.io.getStdErr().writer().writeAll("Usage: x11renderer FILE\n");
        return 0xff;
    }
    const filename = std.mem.span(args[0]);

    const content = blk: {
        var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
            std.log.err("failed to open '{s}' with {s}", .{filename, @errorName(err)});
            return 0xff;
        };
        defer file.close();
        break :blk try file.readToEndAlloc(global_arena.allocator(), std.math.maxInt(usize));
    };

    var parse_context = ParseContext{ .filename = filename };
    var nodes = dom.parse(global_arena.allocator(), content, .{
        .context = &parse_context,
        .on_error = onParseError,
    }) catch |err| switch (err) {
        error.ReportedParseError => return 0xff,
        else => |e| return e,
    };
    alext.unmanaged.finalize(dom.Node, &nodes, global_arena.allocator());

    //try dom.dump(content, nodes);
    return try renderNodes(content, nodes.items);
}

const ParseContext = struct {
    filename: []const u8,
};

fn onParseError(context_ptr: ?*anyopaque, msg: []const u8) void {
    const context: *ParseContext = @alignCast(@ptrCast(context_ptr));
    std.io.getStdErr().writer().print("{s}: parse error: {s}\n", .{context.filename, msg}) catch |err|
        std.debug.panic("failed to print parse error with {s}", .{@errorName(err)});
}


fn renderNodes(html_content: []const u8, html_nodes: []const dom.Node) !u8 {
    const conn = try connect(global_arena.allocator());
    defer x11.disconnect(conn.sock);

    const screen = blk: {
        const fixed = conn.setup.fixed();
        inline for (@typeInfo(@TypeOf(fixed.*)).Struct.fields) |field| {
            std.log.debug("{s}: {any}", .{field.name, @field(fixed, field.name)});
        }
        std.log.debug("vendor: {s}", .{try conn.setup.getVendorSlice(fixed.vendor_len)});
        const format_list_offset = x11.ConnectSetup.getFormatListOffset(fixed.vendor_len);
        const format_list_limit = x11.ConnectSetup.getFormatListLimit(format_list_offset, fixed.format_count);
        std.log.debug("fmt list off={} limit={}", .{format_list_offset, format_list_limit});
        const formats = try conn.setup.getFormatList(format_list_offset, format_list_limit);
        for (formats, 0..) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        const screen = conn.setup.getFirstScreenPtr(format_list_limit);
        inline for (@typeInfo(@TypeOf(screen.*)).Struct.fields) |field| {
            std.log.debug("SCREEN 0| {s}: {any}", .{field.name, @field(screen, field.name)});
        }
        break :blk screen;
    };

    // TODO: maybe need to call conn.setup.verify or something?

    const window_id = conn.setup.fixed().resource_id_base;
    {
        var msg_buf: [x11.create_window.max_len]u8 = undefined;
        const len = x11.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .depth = 0, // we don't care, just inherit from the parent
            .x = 0, .y = 0,
            .width = window_width, .height = window_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
            .bg_pixel = 0xffffff,
//            //.border_pixmap =
//            .border_pixel = 0x01fa8ec9,
//            .bit_gravity = .north_west,
//            .win_gravity = .east,
//            .backing_store = .when_mapped,
//            .backing_planes = 0x1234,
//            .backing_pixel = 0xbbeeeeff,
//            .override_redirect = true,
//            .save_under = true,
            .event_mask =
                  x11.event.key_press
                | x11.event.key_release
                | x11.event.button_press
                | x11.event.button_release
                | x11.event.enter_window
                | x11.event.leave_window
                | x11.event.pointer_motion
//                | x11.event.pointer_motion_hint WHAT THIS DO?
//                | x11.event.button1_motion  WHAT THIS DO?
//                | x11.event.button2_motion  WHAT THIS DO?
//                | x11.event.button3_motion  WHAT THIS DO?
//                | x11.event.button4_motion  WHAT THIS DO?
//                | x11.event.button5_motion  WHAT THIS DO?
//                | x11.event.button_motion  WHAT THIS DO?
                | x11.event.keymap_state
                | x11.event.exposure
                ,
//            .dont_propagate = 1,
        });
        try conn.send(msg_buf[0..len]);
    }

    const bg_gc_id = window_id + 1;
    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = bg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .foreground = screen.black_pixel,
        });
        try conn.send(msg_buf[0..len]);
    }
    const fg_gc_id = window_id + 2;
    {
        var msg_buf: [x11.create_gc.max_len]u8 = undefined;
        const len = x11.create_gc.serialize(&msg_buf, .{
            .gc_id = fg_gc_id,
            .drawable_id = screen.root,
        }, .{
            .background = 0xffffff,
            .foreground = 0x111111,
        });
        try conn.send(msg_buf[0..len]);
    }

    // get some font information
    {
        const text_literal = [_]u16 { 'm' };
        const text = x11.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x11.query_text_extents.getLen(text.len)]u8 = undefined;
        x11.query_text_extents.serialize(&msg, fg_gc_id, text);
        try conn.send(&msg);
    }

    const double_buf = try x11.DoubleBuffer.init(
        std.mem.alignForward(usize, 1000, std.mem.page_size),
        .{ .memfd_name = "ZigX11DoubleBuffer" },
    );
    // double_buf.deinit() (not necessary)
    std.log.info("read buffer capacity is {}", .{double_buf.half_len});
    var buf = double_buf.contiguousReadBuffer();
    // no need to deinit

    const font_dims: FontDims = blk: {
        _ = try x11.readOneMsg(conn.reader(), @alignCast(buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg: *x11.ServerMsg.QueryTextExtents = @ptrCast(msg_reply);
                break :blk .{
                    .width = @intCast(msg.overall_width),
                    .height = @intCast(msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(msg.overall_left),
                    .font_ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                return 1;
            },
        }
    };

    // TODO: set the window title
    //       extract the title from the dom nodes
    std.log.warn("TODO: set the window title", .{});

    {
        var msg: [x11.map_window.len]u8 = undefined;
        x11.map_window.serialize(&msg, window_id);
        try conn.send(&msg);
    }

    while (true) {
        {
            const recv_buf = buf.nextReadBuffer();
            if (recv_buf.len == 0) {
                std.log.err("buffer size {} not big enough!", .{buf.half_len});
                return 1;
            }
            const len = try x11.readSock(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            if (data.len < 32)
                break;
            const msg_len = x11.parseMsgLen(data[0..32].*);
            if (data.len < msg_len)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x11.serverMsgTaggedUnion(@alignCast(data.ptr))) {
                .err => |msg| {
                    std.log.err("{}", .{msg});
                    return 1;
                },
                .reply => |msg| {
                    std.log.info("todo: handle a reply message {}", .{msg});
                    return error.TodoHandleReplyMessage;
                },
                .key_press => |msg| {
                    std.log.info("key_press: keycode={}", .{msg.keycode});
                },
                .key_release => |msg| {
                    std.log.info("key_release: keycode={}", .{msg.keycode});
                },
                .button_press => |msg| {
                    std.log.info("button_press: {}", .{msg});
                },
                .button_release => |msg| {
                    std.log.info("button_release: {}", .{msg});
                },
                .enter_notify => |msg| {
                    std.log.info("enter_window: {}", .{msg});
                },
                .leave_notify => |msg| {
                    std.log.info("leave_window: {}", .{msg});
                },
                .motion_notify => |msg| {
                    // too much logging
                    _ = msg;
                    //std.log.info("pointer_motion: {}", .{msg});
                },
                .keymap_notify => |msg| {
                    std.log.info("keymap_state: {}", .{msg});
                },
                .expose => |msg| {
                    std.log.info("expose: {}", .{msg});
                    try doRender(conn.sock, window_id, fg_gc_id, font_dims, html_content, html_nodes);
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
                .no_exposure,
                .map_notify,
                .reparent_notify,
                .configure_notify,
                => unreachable, // did not register for these
            }
        }
    }
}

const FontDims = struct {
    width: u8,
    height: u8,
    font_left: i16, // pixels to the left of the text basepoint
    font_ascent: i16, // pixels up from the text basepoint to the top of the text
};

fn doRender(
    sock: std.posix.socket_t,
    drawable_id: u32,
    //bg_gc_id: u32,
    fg_gc_id: u32,
    font_dims: FontDims,
    html_content: []const u8,
    dom_nodes: []const dom.Node,
) !void {
    {
        var msg: [x11.clear_area.len]u8 = undefined;
        x11.clear_area.serialize(&msg, false, drawable_id, .{
            .x = 0, .y = 0, .width = window_width, .height = window_height,
        });
        try send(sock, &msg);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var layout_nodes = layout.layout(
        arena.allocator(),
        html_content,
        dom_nodes,
        .{ .x = window_width, .y = window_height },
        Styler{ },
    ) catch |err| {
        // TODO: maybe draw this error as text?
        std.log.err("layout failed, error={s}", .{@errorName(err)});
        return;
    };
    alext.unmanaged.finalize(layout.LayoutNode, &layout_nodes, arena.allocator());

    const render_ctx = RenderCtx {
        .sock = sock,
        .drawable_id = drawable_id,
        .fg_gc_id = fg_gc_id,
        .font_dims = font_dims,
    };
    try render.render(html_content, dom_nodes, layout_nodes.items, RenderCtx, &onRender, render_ctx);
}

const RenderCtx = struct {
    sock: std.posix.socket_t,
    drawable_id: u32,
    fg_gc_id: u32,
    font_dims: FontDims,
};

fn onRender(ctx: RenderCtx, op: render.Op) !void {
    switch (op) {
        .rect => |r| {
            try changeGcColor(ctx.sock, ctx.fg_gc_id, r.color, 0xffffff);
            const rectangles = [_]x11.Rectangle{.{
                .x = @intCast(r.x),
                .y = @intCast(r.y),
                .width = @intCast(r.w),
                .height = @intCast(r.h),
            }};
            if (r.fill) {
                var msg: [x11.poly_fill_rectangle.getLen(rectangles.len)]u8 = undefined;
                x11.poly_fill_rectangle.serialize(&msg, .{
                    .drawable_id = ctx.drawable_id,
                    .gc_id = ctx.fg_gc_id,
                    }, &rectangles);
                try send(ctx.sock, &msg);
            } else {
                var msg: [x11.poly_rectangle.getLen(rectangles.len)]u8 = undefined;
                x11.poly_rectangle.serialize(&msg, .{
                    .drawable_id = ctx.drawable_id,
                    .gc_id = ctx.fg_gc_id,
                    }, &rectangles);
                try send(ctx.sock, &msg);
            }
        },
        .text => |t| {
            const max_text_len = 255;
            const text_len = std.math.cast(u8, t.slice.len) orelse max_text_len;
            try changeGcColor(ctx.sock, ctx.fg_gc_id, 0x111111, 0xffffff);
            var msg: [x11.image_text8.getLen(max_text_len)]u8 = undefined;
            x11.image_text8.serialize(
                &msg,
                x11.Slice(u8, [*]const u8){ .ptr = t.slice.ptr, .len = text_len },
                .{
                    .drawable_id = ctx.drawable_id,
                    .gc_id = ctx.fg_gc_id,
                    .x = @intCast(t.x),
                    .y = @as(i16, @intCast(t.y)) + ctx.font_dims.font_ascent,
                },
            );
            try send(ctx.sock, msg[0 .. x11.image_text8.getLen(text_len)]);
        },
    }
}

fn changeGcColor(sock: std.posix.socket_t, gc_id: u32, fg_color: u32, bg_color: u32) !void {
    var msg_buf: [x11.change_gc.max_len]u8 = undefined;
    const len = x11.change_gc.serialize(&msg_buf, gc_id, .{
        .foreground = fg_color,
        .background = bg_color,
    });
    try send(sock, msg_buf[0..len]);
}

pub const SocketReader = std.io.Reader(std.posix.socket_t, std.posix.RecvFromError, readSocket);

pub fn send(sock: std.posix.socket_t, data: []const u8) !void {
    const sent = try x11.writeSock(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

const SelfModule = @This();
pub const ConnectResult = struct {
    sock: std.posix.socket_t,
    setup: x11.ConnectSetup,
    pub fn reader(self: ConnectResult) SocketReader {
        return .{ .context = self.sock };
    }
    pub fn send(self: ConnectResult, data: []const u8) !void {
        try SelfModule.send(self.sock, data);
    }
};

pub fn connect(allocator: std.mem.Allocator) !ConnectResult {
    const display = x11.getDisplay();
    const parsed_display = x11.parseDisplay(display) catch |err| {
        std.log.err("invalid display '{s}': {s}", .{display, @errorName(err)});
        std.process.exit(0xff);
    };

    const sock = x11.connect(display, parsed_display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.process.exit(0xff);
    };
    errdefer x11.disconnect(sock);

    {
        const len = comptime x11.connect_setup.getLen(0, 0);
        var msg: [len]u8 = undefined;
        x11.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        try send(sock, &msg);
    }

    const reader = SocketReader { .context = sock };
    const connect_setup_header = try x11.readConnectSetupHeader(reader, .{});
    switch (connect_setup_header.status) {
        .failed => {
            std.log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            return error.ConnectSetupFailed;
        },
        .authenticate => {
            std.log.err("AUTHENTICATE! not implemented", .{});
            return error.NotImplemetned;
        },
        .success => {
            // TODO: check version?
            std.log.debug("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
        },
        else => |status| {
            std.log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            return error.MalformedXReply;
        }
    }

    const connect_setup = x11.ConnectSetup {
        .buf = try allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null),
    };
    std.log.debug("connect setup reply is {} bytes", .{connect_setup.buf.len});
    try x11.readFull(reader, connect_setup.buf);

    return ConnectResult{ .sock = sock, .setup = connect_setup };
}
fn readSocket(sock: std.posix.socket_t, buffer: []u8) !usize {
    return x11.readSock(sock, buffer, 0);
}
