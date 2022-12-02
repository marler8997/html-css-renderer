const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Refcounted = @import("Refcounted.zig");

const XY = layout.XY;

const js = struct {
    extern fn logWrite(ptr: [*]const u8, len: usize) void;
    extern fn logFlush() void;
    extern fn initCanvas() void;
    extern fn canvasClear() void;
    extern fn drawText(x: usize, y: usize, ptr: [*]const u8, len: usize) void;
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){ };

export fn alloc(len: usize) ?[*]u8 {
    //std.log.debug("alloc {}", .{len});
    const buf = Refcounted.alloc(gpa.allocator(), len) catch {
        std.log.warn("alloc failed with OutOfMemory", .{});
        return null;
    };
    //std.log.debug("alloc returning 0x{x}", .{@ptrToInt(buf.data_ptr)});
    return buf.data_ptr;
}
export fn release(ptr: [*]u8, len: usize) void {
    //std.log.debug("free {} (ptr=0x{x})", .{len, ptr});
    const buf = Refcounted{ .data_ptr = ptr };
    buf.unref(gpa.allocator(), len);
}

export fn onResize(width: usize, height: usize) void {
    const html_buf = global_opt_html_buf orelse {
        std.log.warn("onResize called without an html doc being loaded", .{});
        return;
    };
    const html = html_buf.buf.data_ptr[0 .. html_buf.len];
    const dom_nodes = global_opt_dom_nodes orelse {
        std.log.warn("onResize called but there's no dom nodes", .{});
        return;
    };

    render(html, XY(usize).init(width, height), dom_nodes);
}

var global_opt_html_buf: ?struct {
    buf: Refcounted,
    len: usize,
} = null;
var global_opt_dom_nodes: ?[]dom.Node = null;

export fn loadHtml(
    name_ptr: [*]u8, name_len: usize,
    html_ptr: [*]u8, html_len: usize,
    viewport_width: usize, viewport_height: usize,
) void {
    const name = name_ptr[0 .. name_len];

    if (global_opt_html_buf) |html_buf| {
        html_buf.buf.unref(gpa.allocator(), html_buf.len);
        global_opt_html_buf = null;
    }
    global_opt_html_buf = .{ .buf = Refcounted{ .data_ptr = html_ptr }, .len = html_len };
    global_opt_html_buf.?.buf.addRef();

    loadHtmlSlice(name, html_ptr[0 .. html_len], XY(usize).init(viewport_width, viewport_height));
}

fn loadHtmlSlice(
    name: []const u8,
    html: []const u8,
    viewport_size: XY(usize),
) void {
    if (global_opt_dom_nodes) |nodes| {
        gpa.allocator().free(nodes);
        global_opt_dom_nodes = null;
    }

    std.log.info("load html from '{s}'...", .{name});
    var parse_context = ParseContext{ .name = name };
    global_opt_dom_nodes = dom.parse(gpa.allocator(), html, .{
        .context = &parse_context,
        .on_error = onParseError,
    }) catch |err| switch (err) {
        error.ReportedParseError => return,
        else => |e| {
            onParseError(&parse_context, @errorName(e));
            return;
        },
    };

    js.initCanvas();
    render(html, viewport_size, global_opt_dom_nodes.?);
}

fn render(
    html: []const u8,
    viewport_size: XY(usize),
    dom_nodes: []const dom.Node,
) void {
    js.canvasClear();

    _ = viewport_size;
    //const layout_nodes = layout.layout(
    //    arena.allocator(),
    //    html,
    //    dom_nodes,

    // default font for html5 canvas is "10px sans-serif"
    const font_height = 10; // hardcoded for now
    var in_body = false;
    var y: usize = 0;
    for (dom_nodes) |node| {
        if (!in_body) {
            switch (node) {
                .tag => |t| {
                    if (t.id == .body) in_body = true;
                },
                .attr => {},
                .text => {},
            }
            continue;
        }
        switch (node) {
            .text => |span| {
                const full_slice = span.slice(html);
                const slice = std.mem.trim(u8, full_slice, " \t\r\n");
                if (slice.len > 0) {
                    js.drawText(0, y + font_height, slice.ptr, slice.len);
                    y += font_height;
                }
            },
            .tag => {},
            .attr => {},
        }
    }

}

const ParseContext = struct {
    name: []const u8,
};
fn onParseError(context_ptr: ?*anyopaque, msg: []const u8) void {
    const context = @intToPtr(*ParseContext, @ptrToInt(context_ptr));
    std.log.err("{s}: parse error: {s}", .{context.name, msg});
}

const JsLogWriter = std.io.Writer(void, error{}, jsLogWrite);
fn jsLogWrite(context: void, bytes: []const u8) !usize {
    _ = context;
    js.logWrite(bytes.ptr, bytes.len);
    return bytes.len;
}
pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    const log_fmt = level_txt ++ prefix ++ format;
    const writer = JsLogWriter{ .context = {} };
    std.fmt.format(writer, log_fmt, args) catch unreachable;
    js.logFlush();
}
