const std = @import("std");
const Tokenizer = @import("Tokenizer.zig");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const Styler = layout.Styler;
const LayoutNode = layout.LayoutNode;
const alext = @import("alext.zig");

const Refcounted = @import("Refcounted.zig");

const XY = layout.XY;

const js = struct {
    extern fn logWrite(ptr: [*]const u8, len: usize) void;
    extern fn logFlush() void;
    extern fn initCanvas() void;
    extern fn canvasClear() void;
    extern fn drawText(x: u32, y: u32, font_size: usize, ptr: [*]const u8, len: usize) void;
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

export fn onResize(width: u32, height: u32) void {
    const html_buf = global_opt_html_buf orelse {
        std.log.warn("onResize called without an html doc being loaded", .{});
        return;
    };
    const html = html_buf.buf.data_ptr[0 .. html_buf.len];
    const dom_nodes = global_opt_dom_nodes orelse {
        std.log.warn("onResize called but there's no dom nodes", .{});
        return;
    };

    render(html, XY(u32).init(width, height), dom_nodes.items);
}

var global_opt_html_buf: ?struct {
    buf: Refcounted,
    len: usize,
} = null;
var global_opt_dom_nodes: ?std.ArrayListUnmanaged(dom.Node) = null;

export fn loadHtml(
    name_ptr: [*]u8, name_len: usize,
    html_ptr: [*]u8, html_len: usize,
    viewport_width: u32, viewport_height: u32,
) void {
    const name = name_ptr[0 .. name_len];

    if (global_opt_html_buf) |html_buf| {
        html_buf.buf.unref(gpa.allocator(), html_buf.len);
        global_opt_html_buf = null;
    }
    global_opt_html_buf = .{ .buf = Refcounted{ .data_ptr = html_ptr }, .len = html_len };
    global_opt_html_buf.?.buf.addRef();

    loadHtmlSlice(name, html_ptr[0 .. html_len], XY(u32).init(viewport_width, viewport_height));
}

fn loadHtmlSlice(
    name: []const u8,
    html: []const u8,
    viewport_size: XY(u32),
) void {
    if (global_opt_dom_nodes) |*nodes| {
        nodes.deinit(gpa.allocator());
        global_opt_dom_nodes = null;
    }

    std.log.info("load html from '{s}'...", .{name});
    var parse_context = ParseContext{ .name = name };

    var nodes = dom.parse(gpa.allocator(), html, .{
        .context = &parse_context,
        .on_error = onParseError,
    }) catch |err| switch (err) {
        error.ReportedParseError => return,
        else => |e| {
            onParseError(&parse_context, @errorName(e));
            return;
        },
    };
    alext.unmanaged.finalize(dom.Node, &nodes, gpa.allocator());
    global_opt_dom_nodes = nodes;

    js.initCanvas();
    render(html, viewport_size, nodes.items);
}

fn render(
    html: []const u8,
    viewport_size: XY(u32),
    dom_nodes: []const dom.Node,
) void {
    js.canvasClear();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const layout_nodes = layout.layout(
        arena.allocator(),
        html,
        dom_nodes,
        viewport_size,
        Styler{ },
    ) catch |err| {
        // TODO: maybe draw this error as text?
        std.log.err("layout failed, error={s}", .{@errorName(err)});
        return;
    };

    for (layout_nodes.items) |node| switch (node) {
        .text => |t| {
            js.drawText(t.x, t.y + t.font_size, t.font_size, t.slice.ptr, t.slice.len);
        },
    };
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
