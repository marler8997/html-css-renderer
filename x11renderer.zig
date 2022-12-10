const builtin = @import("builtin");
const std = @import("std");
const x11 = @import("x11");
const Memfd = x11.Memfd;
const ContiguousReadBuffer = x11.ContiguousReadBuffer;

const dom = @import("dom.zig");
const layout = @import("layout.zig");
const XY = layout.XY;
const Styler = layout.Styler;
const alext = @import("alext.zig");

var global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

const window_width = 600;
const window_height = 600;

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
    const context = @intToPtr(*ParseContext, @ptrToInt(context_ptr));
    std.io.getStdErr().writer().print("{s}: parse error: {s}\n", .{context.filename, msg}) catch |err|
        std.debug.panic("failed to print parse error with {s}", .{@errorName(err)});
}


fn renderNodes(html_content: []const u8, html_nodes: []const dom.Node) !u8 {
    const conn = try connect(global_arena.allocator());
    defer std.os.shutdown(conn.sock, .both) catch {};

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
        for (formats) |format, i| {
            std.log.debug("format[{}] depth={:3} bpp={:3} scanpad={:3}", .{i, format.depth, format.bits_per_pixel, format.scanline_pad});
        }
        var screen = conn.setup.getFirstScreenPtr(format_list_limit);
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

    const buf_memfd = try Memfd.init("ZigX11DoubleBuffer");
    // no need to deinit
    const buffer_capacity = std.mem.alignForward(1000, std.mem.page_size);
    std.log.info("buffer capacity is {}", .{buffer_capacity});
    var buf = ContiguousReadBuffer { .double_buffer_ptr = try buf_memfd.toDoubleBuffer(buffer_capacity), .half_size = buffer_capacity };

    const font_dims: FontDims = blk: {
        _ = try x11.readOneMsg(conn.reader(), @alignCast(4, buf.nextReadBuffer()));
        switch (x11.serverMsgTaggedUnion(@alignCast(4, buf.double_buffer_ptr))) {
            .reply => |msg_reply| {
                const msg = @ptrCast(*x11.ServerMsg.QueryTextExtents, msg_reply);
                break :blk .{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .font_left = @intCast(i16, msg.overall_left),
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
                std.log.err("buffer size {} not big enough!", .{buf.half_size});
                return 1;
            }
            const len = try std.os.recv(conn.sock, recv_buf, 0);
            if (len == 0) {
                std.log.info("X server connection closed", .{});
                return 0;
            }
            buf.reserve(len);
        }
        while (true) {
            const data = buf.nextReservedBuffer();
            const msg_len = x11.parseMsgLen(@alignCast(4, data));
            if (msg_len == 0)
                break;
            buf.release(msg_len);
            //buf.resetIfEmpty();
            switch (x11.serverMsgTaggedUnion(@alignCast(4, data.ptr))) {
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
                    try render(conn.sock, window_id, fg_gc_id, font_dims, html_content, html_nodes);
                },
                .mapping_notify => |msg| {
                    std.log.info("mapping_notify: {}", .{msg});
                },
                .unhandled => |msg| {
                    std.log.info("todo: server msg {}", .{msg});
                    return error.UnhandledServerMsg;
                },
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

fn render(
    sock: std.os.socket_t,
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

    const layout_nodes = layout.layout(
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

    var next_color_index: usize = 0;
    var next_no_relative_position_box_y: usize = 200;

    for (layout_nodes.items) |node, node_index| switch (node) {
        .box => |b| {
            if (b.content_size.x.getResolved() == null or b.content_size.y.getResolved() == null) {
                std.log.warn("box size at index {} not resolved, should be impossible once fully implemented", .{node_index});
            } else {
                const content_size = XY(u32){
                    .x = b.content_size.x.getResolved().?,
                    .y = b.content_size.y.getResolved().?,
                };

                try changeGcColor(sock, fg_gc_id, unique_colors[next_color_index], 0xffffff);
                next_color_index = (next_color_index + 1) % unique_colors.len;
                std.log.info("x/y={}/{}", .{b.relative_content_pos.x, b.relative_content_pos.y});
                const x = @intCast(i16, b.relative_content_pos.x);
                const explode_view = true;
                const y = @intCast(i16, blk: {
                    if (explode_view) {
                        const y = next_no_relative_position_box_y;
                        next_no_relative_position_box_y += content_size.y + 5;
                        break :blk y;
                    }
                    break :blk b.relative_content_pos.y;
                });
                {
                    const rectangles = [_]x11.Rectangle{.{
                        .x = x, .y = y,
                        .width = @intCast(u16, content_size.x),
                        .height = @intCast(u16, content_size.y),
                    }};
                    var msg: [x11.poly_rectangle.getLen(rectangles.len)]u8 = undefined;
                    x11.poly_rectangle.serialize(&msg, .{
                        .drawable_id = drawable_id,
                        .gc_id = fg_gc_id,
                        }, &rectangles);
                    try send(sock, &msg);
                }
                {
                    const max_text_len = 255;
                    var msg_buf: [x11.image_text8.getLen(max_text_len)]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        msg_buf[x11.image_text8.text_offset..],
                        "box index={} {s} {}x{}", .{
                            node_index,
                            switch (dom_nodes[b.dom_node]) {
                                .start_tag => |t| @tagName(t.id),
                                .text => @as([]const u8, "text"),
                                else => unreachable,
                            },
                            content_size.x,
                            content_size.y,
                        },
                    ) catch unreachable;
                    const text_len = @intCast(u8, msg.len);
                    x11.image_text8.serializeNoTextCopy(&msg_buf, text_len, .{
                            .drawable_id = drawable_id,
                            .gc_id = fg_gc_id,
                            .x = @intCast(i16, x) + 1,
                            .y = @intCast(i16, y) + font_dims.font_ascent + 1,
                    });
                    try send(sock, msg_buf[0 .. x11.image_text8.getLen(text_len)]);
                }
            }
        }, // TODO
        .end_box => {}, // TODO
        .text => |t| {
            _ = t;
            // TODO: handle font slice
//            const max_text_len = 255;
//            const text_len = std.math.cast(u8, t.slice.len) orelse max_text_len;
//
//            try changeGcColor(sock, fg_gc_id, 0x111111, 0xffffff);
//            var msg: [x11.image_text8.getLen(max_text_len)]u8 = undefined;
//            x11.image_text8.serialize(
//                &msg,
//                x11.Slice(u8, [*]const u8){ .ptr = t.slice.ptr, .len = text_len },
//                .{
//                    .drawable_id = drawable_id,
//                    .gc_id = fg_gc_id,
//                    .x = @intCast(i16, t.x),
//                    .y = @intCast(i16, t.y) + font_dims.font_ascent,
//                },
//            );
//            try send(sock, msg[0 .. x11.image_text8.getLen(text_len)]);
        },
        .svg => {
            std.log.warn("TODO: render svg!", .{});
        },
    };
}

fn changeGcColor(sock: std.os.socket_t, gc_id: u32, fg_color: u32, bg_color: u32) !void {
    var msg_buf: [x11.change_gc.max_len]u8 = undefined;
    const len = x11.change_gc.serialize(&msg_buf, gc_id, .{
        .foreground = fg_color,
        .background = bg_color,
    });
    try send(sock, msg_buf[0..len]);
}

var unique_colors = [_]u32 {
    0xe6194b, 0x3cb44b, 0xffe119, 0x4363d8, 0xf58231, 0x911eb4, 0x46f0f0,
    0xf032e6, 0xbcf60c, 0xfabebe, 0x008080, 0xe6beff, 0x9a6324, 0xfffac8,
    0x800000, 0xaaffc3, 0x808000, 0xffd8b1, 0x000075, 0x808080,
};

pub const SocketReader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket);

pub fn send(sock: std.os.socket_t, data: []const u8) !void {
    const sent = try std.os.send(sock, data, 0);
    if (sent != data.len) {
        std.log.err("send {} only sent {}\n", .{data.len, sent});
        return error.DidNotSendAllData;
    }
}

const SelfModule = @This();
pub const ConnectResult = struct {
    sock: std.os.socket_t,
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

    const sock = x11.connect(display) catch |err| {
        std.log.err("failed to connect to display '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };

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

fn readSocket(sock: std.os.socket_t, buffer: []u8) !usize {
    return std.os.recv(sock, buffer, 0);
}
