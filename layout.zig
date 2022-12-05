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

fn roundedMult(float: f32, int: anytype) @TypeOf(int) {
    return @floatToInt(@TypeOf(int), @round(float * @intToFloat(f32, int)));
}


pub const StyleSize = union(enum) {
    px: u32,
    parent_ratio: f32, // represents percentage-based sizes
    content: void,
};
pub const Style = struct {
    size: XY(StyleSize),
    padding: u32, // just 1 value for now
    border: u32, // just 1 value for now
    margin: u32, // just 1 value for now
    pub fn toBox(
        self: Style,
        dom_node: usize,
        parent_box: usize,
        parent_content_size: XY(?u32),
    ) Box {
        return Box{
            .dom_node = dom_node,
            .parent_box = parent_box,
            .relative_content_pos = .{ .x = null, .y = null },
            .content_size = .{
                .x = switch (self.size.x) {
                    .px => |p| p,
                    .parent_ratio => |r| if (parent_content_size.x) |x|
                        roundedMult(r, x) - 2 * self.border else null,
                    .content => null,
                },
                .y = switch (self.size.y) {
                    .px => |p| p,
                    .parent_ratio => |r| if (parent_content_size.y) |y|
                        roundedMult(r, y) - 2 * self.border else null,
                    .content => null,
                },
            },
            .style_size = self.size,
            .padding = self.padding,
            .border = self.border,
            .margin = self.margin,
        };
    }
};
pub const Styler = struct {

    html: Style = .{
        .size = .{ .x = .{ .parent_ratio = 1 }, .y = .content },
        .padding = 0,
        .border = 0,
        .margin = 0,
    },
    body: Style = .{
        .size = .{ .x = .{ .parent_ratio = 1 }, .y = .content },
        .padding = 0,
        .border = 0,
        .margin = 8,
    },

    // TODO: probably pass in the parent tag dom_node?
    pub fn getTextStyle(self: Styler) Style {
        _ = self;
        std.log.warn("TODO: return correct style for text", .{});
        return .{
            .size = .{ .x = .content, .y = .content },
            .padding = 0,
            .border = 0,
            .margin = 0,
        };
    }
    pub fn getTagStyle(self: Styler, dom_nodes: []const dom.Node) Style {
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
                    .size = .{ .x = .{ .parent_ratio = 1 }, .y = .content },
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

const Box = struct {
    dom_node: usize,
    parent_box: usize,
    relative_content_pos: XY(?u32),
    content_size: XY(?u32),
    style_size: XY(StyleSize),
    padding: u32,
    border: u32,
    margin: u32,
};

pub const LayoutNode = union(enum) {
    box: Box,
    end_box: usize,
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

// Layout Algorithm:
// ================================================================================
// We traverse the DOM tree depth first.
//
// When we visit a node on our way "down" the tree, we create a box in the "layout" tree.
//
// We determine the size/position if possible and continue down the tree.
// Note that for "tag nodes" that can have children, we could only determine the size/position
// it's only dependent on the parent node (i.e. `width: 100%`).
//
// Before any node returns back up the tree, it must determine its content size.
//
// This means that all parent nodes can use their children content sizes to determine its
// own position/size and reposition all the children.
//
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
        const style = styler.getTagStyle(dom_nodes);
        var viewport_content_size = XY(?u32){
            .x = viewport_size.x,
            .y = viewport_size.y,
        };
        try nodes.append(allocator, .{ .box = style.toBox(0, 0, viewport_content_size)});
    }
    std.log.info("<html> content size is {?} x {?}", .{nodes.items[0].box.content_size.x, nodes.items[0].box.content_size.y});

    var dom_node_index: usize = 0;

    find_body_loop:
    while (true) : (dom_node_index += 1) {
        if (dom_node_index == dom_nodes.len) return nodes;
        switch (dom_nodes[dom_node_index]) {
            .start_tag => |t| if (t.id == .body) break :find_body_loop,
            else => {},
        }
    }
    {
        const style = styler.getTagStyle(dom_nodes);
        const parent_content_size = nodes.items[0].box.content_size;
        try nodes.append(allocator, .{ .box = style.toBox(dom_node_index, 0, parent_content_size) });
    }
    dom_node_index += 1;

    // NOTE: we don't needs a stack for these states because they can only go 1 level deep
    var in_script = false;

    // TODO: probably remove render_cursor?
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

                const style = styler.getTagStyle(dom_nodes[dom_node_index..]);
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
                endParentBox(text, dom_nodes, nodes.items[parent_box..]);
                try nodes.append(allocator, .{ .end_box = parent_box });
                parent_box = nodes.items[parent_box].box.parent_box;
                std.log.info("DEBUG:     restore parent box to <{s}> (index={})", .{
                    // all boxes that become "parents" should be start_tags I think?
                    @tagName(dom_nodes[nodes.items[parent_box].box.dom_node].start_tag.id), parent_box,
                });

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

                const style = styler.getTextStyle();

                std.log.info("DEBUG: layout text ({} chars)", .{slice.len});
                const font_size = blk: {
                    var it = revit.reverseIterator(state_stack.items);
                    while (it.next()) |s| switch (s) {
                        .font_size => |size| break :blk size,
                    };
                    break :blk default_font_size;
                };
                // TODO: don't ignore style
                const text_width = calcTextWidth(font_size, slice) catch unreachable;
                try nodes.append(allocator, .{ .box = .{
                    .dom_node = dom_node_index,
                    .parent_box = parent_box,
                    .relative_content_pos = .{ .x = null, .y = null},
                    .content_size = .{ .x = text_width, .y = font_size },
                    .style_size = style.size,
                    .padding = style.padding,
                    .border = style.border,
                    .margin = style.margin,
                }});
                const this_box_index = nodes.items.len - 1;
                try nodes.append(allocator, .{ .text = .{
                    .x = render_cursor.x,
                    .y = render_cursor.y,
                    .font_size = font_size,
                    .slice = slice,
                }});
                try nodes.append(allocator, .{ .end_box = this_box_index });
                render_cursor.x += text_width;
                current_line_height = if (current_line_height) |h| std.math.max(font_size, h) else font_size;
            },
        }
    }

    return nodes;
}

fn endParentBox(
    text: []const u8,
    dom_nodes: []const dom.Node,
    nodes: []LayoutNode,
) void {
    _ = text;
    const parent_box = &nodes[0].box;
    const dom_node_ref = switch (dom_nodes[parent_box.dom_node]) {
        .start_tag => |*t| t,
        // all boxes that become "parents" should be start_tags I think?
        else => unreachable,
    };
//    if (parent_box.content_size.x == null or parent_box.content_size.y == null) {
//        // !!!
//        std.log.info("TODO: finalize parent box size for <{s}> width={} height={}", .{
//            @tagName(dom_node_ref.id),
//            parent_box.style_size.x,
//            parent_box.style_size.y,
//        });
//    }
    if (parent_box.content_size.x == null) {
        std.log.warn("TODO: get content size x for <{s}>", .{@tagName(dom_node_ref.id)});
        //return error.TodoGetContentSizeX;
    }
    if (parent_box.content_size.y == null) {
        switch (parent_box.style_size.y) {
            .px => @panic("should be impossible"), // unless this has changed since we set content_size?
            .parent_ratio => @panic("todo: endParentTag 'parent_ratio' style height"),
            .content => {
                var content_height: u32 = 0;
                var depth: u32 = 0;
                for (nodes[1..]) |node| {
                    switch(node) {
                        .box => |box| {
                            if (depth == 0) {
                                if (box.content_size.y) |y| {
                                    content_height += y + 2 * box.border + 2 * box.margin;
                                } else switch (box.style_size.y) {
                                    // I *think* my algorithm guarantees content size MUST be set at this point?
                                    //.px => @panic("should be impossible"), // unless this has changed since we set content_size?
                                    //.percent => return error.Todo,
                                    //.content => {
                                    else => @panic("here"),
                                }
                            }
                            depth += 1;
                        },
                        .end_box => {
                            depth -= 1;
                        },
                        .text => {}, // ignore for now
                        .svg => {}, // ignore for now
                    }
                }
                std.debug.assert(depth == 0);
                parent_box.content_size.y = content_height;
                std.log.info("content height for <{s}> resolved to {}", .{@tagName(dom_node_ref.id), content_height});
            },
        }
    }
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
