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

// Sizes
// content-box-size
// border-box-size

pub const StyleSize = union(enum) {
    px: u32,
    percent: u32,
    content: void,
};
pub const Style = struct {
    size: XY(StyleSize),
    padding: u32, // just 1 value for now
    border: u32, // just 1 value for now
    margin: u32, // just 1 value for now
    pub fn toBox(self: Style, dom_node: usize, parent_box: usize, parent_content_size: ContentSize) Box {
        return Box{
            .dom_node = dom_node,
            .parent_box = parent_box,
            .content_size = .{
                .x = switch (self.size.x) {
                    .px => |p| p,
                    .percent => parent_content_size.x,
                    .content => null,
                },
                .y = switch (self.size.y) {
                    .px => |p| p,
                    .percent => parent_content_size.y,
                    .content => null,
                },
            },
            .padding = self.padding,
            .border = self.border,
            .margin = self.margin,
        };
    }
};
pub const Styler = struct {

    html: Style = .{
        .size = .{ .x = .{ .percent = 100 }, .y = .content },
        .padding = 0,
        .border = 0,
        .margin = 0,
    },
    body: Style = .{
        .size = .{ .x = .{ .percent = 100 }, .y = .content },
        .padding = 0,
        .border = 0,
        .margin = 8,
    },

    pub fn getStyle(self: Styler, dom_nodes: []const dom.Node) Style {
        const tag = switch (dom_nodes[0]) {
            .start_tag => |tag| tag,
            else => unreachable,
        };

        // TODO: check for attributes
        for (dom_nodes[1..]) |node| switch (node) {
            .attr => |a| {
                std.log.info("TODO: handle attribute '{s}'", .{@tagName(a.id)});
            },
            else => break,
        };

        switch (tag.id) {
            .html => return self.html,
            .body => return self.body,
            else => {
                std.log.warn("TODO: return correct style for <{s}>", .{@tagName(tag.id)});
                if (dom.defaultDisplayIsBlock(tag.id)) return .{
                    .size = .{ .x = .{ .percent = 100 }, .y = .content },
                    .padding = 0,
                    .border = 0,
                    .margin = 0,
                };
                return .{
                    .size = .{ .x = .content, .y = .content },
                    .padding = 0,
                    .border = 0,
                    .margin = 0,
                };
            },
        }
    }
};

const default_font_size = 16;

fn pop(comptime T: type, al: *std.ArrayListUnmanaged(T)) void {
    std.debug.assert(al.items.len > 0);
    al.items.len -= 1;
}

const ContentSize = struct {
    x: ?u32,
    y: ?u32,
};

const Box = struct {
    dom_node: usize, // always a start tag right now
    parent_box: usize,
    content_size: ContentSize,
    padding: u32,
    border: u32,
    margin: u32,
};

pub const LayoutNode = union(enum) {
    box: Box,
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
    var nodes = std.ArrayListUnmanaged(LayoutNode){ };
    errdefer nodes.deinit(allocator);

    {
        const style = styler.getStyle(dom_nodes);
        const viewport_content_size = ContentSize{
            .x = viewport_size.x,
            .y = viewport_size.y,
        };
        try nodes.append(allocator, .{ .box = style.toBox(0, 0, viewport_content_size) });
    }

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
    {
        const style = styler.getStyle(dom_nodes);
        const parent_content_size = nodes.items[0].box.content_size;
        try nodes.append(allocator, .{ .box = style.toBox(dom_node_index, 0, parent_content_size) });
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
    var parent_box: usize = 1;

    body_loop:
    while (dom_node_index < dom_nodes.len) : (dom_node_index += 1) {
        const dom_node = &dom_nodes[dom_node_index];
        switch (dom_node.*) {
            .start_tag => |tag| {
                std.log.info("DEBUG: layout <{s}>", .{@tagName(tag.id)});

                const style = styler.getStyle(dom_nodes[dom_node_index..]);
                const parent_content_size = nodes.items[parent_box].box.content_size;
                try nodes.append(allocator, .{ .box = style.toBox(dom_node_index, parent_box, parent_content_size) });
                parent_box = nodes.items.len - 1;

                // TODO: this is old, probably remove this
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
            .attr => {},
            .end_tag => |id| {
                std.log.info("DEBUG: layout </{s}>", .{@tagName(id)});

                // content of parent box layout is done, finalize its size
                {
                    const parent_box_ref = &nodes.items[parent_box].box;
                    const dom_node_ref = &dom_nodes[parent_box_ref.dom_node].start_tag;
                    if (parent_box_ref.content_size.x == null or parent_box_ref.content_size.y == null) {
                        std.log.info("TODO: finalize parent box size for <{s}>", .{
                            @tagName(dom_node_ref.id)
                        });
                    }
                    parent_box = parent_box_ref.parent_box;
                    std.log.info("DEBUG:     restore parent box to <{s}> (index={})", .{
                        @tagName(dom_nodes[nodes.items[parent_box].box.dom_node].start_tag.id), parent_box,
                    });
                }


                if (dom.defaultDisplayIsBlock(id)) {
                    if (current_line_height) |h| {
                        render_cursor.x = 0;
                        render_cursor.y += h;
                        current_line_height = null;
                    }
                }
                switch (id) {
                    .html => break :body_loop,
                    .script => in_script = false,
                    .h1 => pop(StackState, &state_stack),
                    .svg => unreachable, // should be impossible
                    .div => {},
                    else => std.log.info("TODO: layout handle </{s}>", .{@tagName(id)}),
                }
            },
            .text => |span| {
                if (in_script) continue;

                const full_slice = span.slice(text);
                const slice = std.mem.trim(u8, full_slice, " \t\r\n");
                if (slice.len == 0) continue;

                std.log.info("DEBUG: layout text ({} chars)", .{slice.len});
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
            },
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
