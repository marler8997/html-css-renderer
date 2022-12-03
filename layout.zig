const std = @import("std");
const dom = @import("dom.zig");
const revit = @import("revit.zig");

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        pub fn init(x: T, y: T) @This() {
            return .{ .x = x, .y = y };
        }
    };
}
pub const Styler = struct {
};

const default_font_size = 16;

fn pop(comptime T: type, al: *std.ArrayListUnmanaged(T)) void {
    std.debug.assert(al.items.len > 0);
    al.items.len -= 1;
}

pub const LayoutNode = union(enum) {
    text: struct {
        x: u32,
        y: u32,
        font_size: u32,
        slice: []const u8,
    },
    svg: struct {
        start_dom_node: usize,
    },
};
pub fn layout(
    allocator: std.mem.Allocator,
    text: []const u8,
    dom_nodes: []const dom.Node,
    viewport_size: XY(u32),
    styler: Styler,
) !std.ArrayListUnmanaged(LayoutNode) {
    _ = viewport_size;
    _ = styler;

    var nodes = std.ArrayListUnmanaged(LayoutNode){ };
    errdefer nodes.deinit(allocator);

    var dom_node_index: usize = 0;

    // find the body tag
    find_body_loop:
    while (true) : (dom_node_index += 1) {
        if (dom_node_index == dom_nodes.len) return nodes;
        switch (dom_nodes[dom_node_index]) {
            .start_tag => |t| if (t.id == .body) break :find_body_loop,
            else => {},
        }
    }
    dom_node_index += 1;

    // NOTE: we don't needs a stack for these states because they can only go 1 level deep
    var in_script = false;

    var render_cursor = XY(u32) { .x = 0, .y = 0 };
    var current_line_height: ?u32 = null;

    const StackState = union(enum) {
        font_size: u32,
    };
    var state_stack = std.ArrayListUnmanaged(StackState) { };

    body_loop:
    while (dom_node_index < dom_nodes.len) : (dom_node_index += 1) {
        const dom_node = &dom_nodes[dom_node_index];
        switch (dom_node.*) {
            .text => |span| if (!in_script) {
                const full_slice = span.slice(text);
                const slice = std.mem.trim(u8, full_slice, " \t\r\n");
                if (slice.len > 0) {
                    const font_size = blk: {
                        var it = revit.reverseIterator(state_stack.items);
                        while (it.next()) |s| switch (s) {
                            .font_size => |size| break :blk size,
                        };
                        break :blk default_font_size;
                    };
                    try nodes.append(allocator, .{ .text = .{
                        .x = render_cursor.x,
                        .y = render_cursor.y,
                        .font_size = font_size,
                        .slice = slice,
                    }});
                    render_cursor.x += calcTextWidth(font_size, slice) catch unreachable;
                    current_line_height = if (current_line_height) |h| std.math.max(font_size, h) else font_size;
                }
            },
            .start_tag => |tag| {
                if (dom.defaultDisplayIsBlock(tag.id)) {
                    if (current_line_height) |h| {
                        render_cursor.x = 0;
                        render_cursor.y += h;
                        current_line_height = null;
                    }
                }
                switch (tag.id) {
                    .script => in_script = true,
                    .h1 => try state_stack.append(allocator, .{ .font_size = 32 }),
                    .svg => {
                        const svg_start_node = dom_node_index;
                        find_svg_end_loop:
                        while (true) {
                            dom_node_index += 1;
                            switch (dom_nodes[dom_node_index]) {
                                .end_tag => |id| if (id == .svg) break :find_svg_end_loop,
                                else => {},
                            }
                        }
                        try nodes.append(allocator, .{ .svg = .{ .start_dom_node = svg_start_node } });
                    },
                    .div => {},
                    else => std.log.info("TODO: layout handle <{s}>", .{@tagName(tag.id)}),
                }
            },
            .end_tag => |id| {
                if (dom.defaultDisplayIsBlock(id)) {
                    if (current_line_height) |h| {
                        render_cursor.x = 0;
                        render_cursor.y += h;
                        current_line_height = null;
                    }
                }
                switch (id) {
                    .body => break :body_loop,
                    .script => in_script = false,
                    .h1 => pop(StackState, &state_stack),
                    .svg => unreachable, // should be impossible
                    .div => {},
                    else => std.log.info("TODO: layout handle </{s}>", .{@tagName(id)}),
                }
            },
            .attr => {},
        }
    }

    return nodes;
}

fn calcTextWidth(font_size: u32, text: []const u8) !u32 {
    // just a silly hueristic for now
    const char_count = try calcCharCount(u32, text);
    return @floatToInt(u32, @intToFloat(f32, font_size) * 0.48 * @intToFloat(f32, char_count));
}

fn calcCharCount(comptime T: type, text: []const u8) !T {
    var count: T = 0;
    var it = HtmlCharIterator.init(text);
    while (try it.next()) |_| {
        count += 1;
    }
    return count;
}

const HtmlCharIterator = struct {
    text: []const u8,
    index: usize,
    pub fn init(text: []const u8) HtmlCharIterator {
        return .{ .text = text, .index = 0 };
    }
    pub fn next(self: *HtmlCharIterator) !?u21 {
        if (self.index == self.text.len) return null;
        const len = try std.unicode.utf8CodepointSequenceLength(self.text[0]);
        if (self.index + len > self.text.len)
            return error.Utf8TruncatedInput;
        const c = try std.unicode.utf8Decode(self.text[0 .. len]);
        if (c == '&') {
            return error.ImplementCharReference;
        }
        self.index += len;
        return c;
    }
};
