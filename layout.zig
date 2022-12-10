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
    mbp: MarginBorderPadding,
//    font_size: union(enum) {
//        px: u32,
//        em: f32,
//    },
};

const MarginBorderPadding = struct {
    margin: u32,
    border: u32,
    padding: u32,
};

pub const Styler = struct {

    html: Style = .{
        .size = .{ .x = .{ .parent_ratio = 1 }, .y = .content },
        .mbp = .{
            .margin = 0,
            .border = 0,
            .padding = 0,
        },
        //.font_size = .{ .em = 1 },
    },
    body: Style = .{
        .size = .{ .x = .{ .parent_ratio = 1 }, .y = .content },
        .mbp = .{
            .margin = 8,
            .border = 0,
            .padding = 0,
        },
        //.font_size = .{ .em = 1 },
    },

    pub fn getBox(
        self: Styler,
        dom_nodes: []const dom.Node,
        dom_node_index: usize,
        parent_box: usize,
        parent_content_size: XY(ContentSize),
    ) Box {
        const tag = switch (dom_nodes[dom_node_index]) {
            .start_tag => |tag| tag,
            else => @panic("todo or maybe unreachable?"),
        };

        var style_size: XY(StyleSize) = blk: {
            switch (tag.id) {
                .html => break :blk self.html.size,
                .body => break :blk self.body.size,
                else => {
                    std.log.warn("TODO: use correct style size for <{s}>", .{@tagName(tag.id)});
                    if (dom.defaultDisplayIsBlock(tag.id))
                        break :blk .{ .x = .{ .parent_ratio = 1 }, .y = .content };
                    break :blk .{ .x = .content, .y = .content };
                },
            }
        };
        var mbp: MarginBorderPadding = blk: {
            switch (tag.id) {
                .html => break :blk self.html.mbp,
                .body => break :blk self.body.mbp,
                .h1 => {
                    std.log.warn("using hardcoded margin/border/padding for <h1>", .{});
                    break :blk .{ .margin = 21, .border = 0, .padding = 0 };
                },
                .p => {
                    std.log.warn("using hardcoded margin/border/padding for <p>", .{});
                    // make margin 1em instead?
                    break :blk .{ .margin = 18, .border = 0, .padding = 0 };
                },
                else => {
                    std.log.warn("TODO: use correct margin/border/padding for <{s}>", .{@tagName(tag.id)});
                    break :blk .{ .margin = 0, .border = 0, .padding = 0 };
                },
            }
        };

        // TODO: check for attributes
        for (dom_nodes[dom_node_index + 1..]) |node| switch (node) {
            .attr => |a| {
                std.log.info("TODO: handle attribute '{s}'", .{@tagName(a.id)});
            },
            else => break,
        };

        return Box{
            .dom_node = dom_node_index,
            .parent_box = parent_box,
            .relative_content_pos = .{ .x = null, .y = null },
            .content_size = XY(ContentSize){
                .x = switch (style_size.x) {
                    .px => |p| .{ .resolved = p },
                    .parent_ratio => |r| switch (parent_content_size.x) {
                        .resolved => |x| .{ .resolved = roundedMult(r, x) - 2 * mbp.border - 2 * mbp.margin },
                        .unresolved => |u| .{ .unresolved = u },
                    },
                    .content => .{ .unresolved = .fit },
                },
                .y = switch (style_size.y) {
                    .px => |p| .{ .resolved = p },
                    .parent_ratio => |r| switch (parent_content_size.y) {
                        .resolved => |y| .{ .resolved = roundedMult(r, y) - 2 * mbp.border - 2 * mbp.margin },
                        .unresolved => |u| .{ .unresolved = u },
                    },
                    .content => .{ .unresolved = .fit },
                },
            },
            .mbp = mbp,
        };
    }

    pub fn getSizeY(self: Styler, dom_nodes: []const dom.Node) StyleSize {
        const tag = switch (dom_nodes[0]) {
            .start_tag => |tag| tag,
            else => @panic("todo or maybe unreachable?"),
        };

        // TODO: check for attributes
        for (dom_nodes[1..]) |node| switch (node) {
            .attr => |a| {
                std.log.info("TODO: handle attribute '{s}'", .{@tagName(a.id)});
            },
            else => break,
        };

        switch (tag.id) {
            .html => return self.html.size.y,
            .body => return self.body.size.y,
            else => {
                std.log.warn("TODO: return correct size y for <{s}>", .{@tagName(tag.id)});
                return .content;
            },
        }
    }

    pub fn getFontSize(self: Styler, dom_nodes: []const dom.Node, node_index: usize) ?u32 {
        _ = self;
        switch (dom_nodes[node_index]) {
            .start_tag => |tag| {
                switch (tag.id) {
                    .h1 => {
                        std.log.warn("returning hardcoded font size {} for h1", .{default_font_size*2});
                        return default_font_size * 2;
                    },
                    else => {},
                }
                std.log.warn("TODO: handle font size for <{s}>", .{@tagName(tag.id)});
                return null;
            },
            else => |n| std.debug.panic("todo handle {s}", .{@tagName(n)}),
        }
    }
};

const default_font_size = 16;

fn pop(comptime T: type, al: *std.ArrayListUnmanaged(T)) void {
    std.debug.assert(al.items.len > 0);
    al.items.len -= 1;
}

const ContentSize = union(enum) {
    resolved: u32,
    unresolved: enum { fit, min, max },
    pub fn getResolved(self: ContentSize) ?u32 {
        return switch (self) {
            .resolved => |r| r,
            .unresolved => null,
        };
    }
    pub fn format(
        self: ContentSize,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt; _ = options;
        switch (self) {
            .resolved => |r| try writer.print("{}", .{r}),
            .unresolved => |u| try writer.print("unresolved({s})", .{@tagName(u)}),
        }
    }
};

const Box = struct {
    dom_node: usize,
    parent_box: usize,
    relative_content_pos: XY(?u32),
    content_size: XY(ContentSize),
    mbp: MarginBorderPadding,
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
        var viewport_content_size = XY(ContentSize){
            .x = .{ .resolved = viewport_size.x },
            .y = .{ .resolved = viewport_size.y },
        };
        try nodes.append(allocator, .{ .box = styler.getBox(dom_nodes, 0, std.math.maxInt(usize), viewport_content_size)});
    }
    std.log.info("<html> content size is {} x {}", .{nodes.items[0].box.content_size.x, nodes.items[0].box.content_size.y});

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
        const parent_content_size = nodes.items[0].box.content_size;
        try nodes.append(allocator, .{ .box = styler.getBox(dom_nodes, dom_node_index, 0, parent_content_size) });
    }
    std.log.info("<body> content size is {?} x {?}", .{nodes.items[1].box.content_size.x, nodes.items[1].box.content_size.y});
    dom_node_index += 1;

    // NOTE: we don't needs a stack for these states because they can only go 1 level deep
    var in_script = false;

    // TODO: probably remove render_cursor?
    var render_cursor = XY(u32) { .x = 0, .y = 0 };
    var current_line_height: ?u32 = null;

    var parent_box: usize = 1;

    body_loop:
    while (dom_node_index < dom_nodes.len) : (dom_node_index += 1) {
        const dom_node = &dom_nodes[dom_node_index];
        switch (dom_node.*) {
            .start_tag => |tag| {
                //const style = styler.getTagStyle(dom_nodes[dom_node_index..]);
                const parent_content_size = nodes.items[parent_box].box.content_size;
                try nodes.append(allocator, .{ .box = styler.getBox(dom_nodes, dom_node_index, parent_box, parent_content_size) });
                std.log.info("<{s}> content size is {?} x {?}", .{
                    @tagName(tag.id),
                    nodes.items[nodes.items.len - 1].box.content_size.x,
                    nodes.items[nodes.items.len - 1].box.content_size.y,
                });
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
                endParentBox(text, dom_nodes, styler, nodes.items[parent_box..]);
                try nodes.append(allocator, .{ .end_box = parent_box });
                parent_box = nodes.items[parent_box].box.parent_box;
                if (parent_box == std.math.maxInt(usize))
                    break :body_loop;
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
                    .script => in_script = false,
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

                const font_size = getFontSize(dom_nodes, styler, nodes.items, parent_box);
                // TODO: we don't need to get the text_width here, do that when the parent box is resolving
                const text_width = calcTextWidth(font_size, slice) catch unreachable;
                std.log.info("DEBUG: layout text byte_len={} font_size={} width={}", .{slice.len, font_size, text_width});
                try nodes.append(allocator, .{ .text = .{
                    .x = render_cursor.x,
                    .y = render_cursor.y,
                    .font_size = font_size,
                    .slice = slice,
                }});
                render_cursor.x += text_width;
                current_line_height = if (current_line_height) |h| std.math.max(font_size, h) else font_size;
            },
        }
    }

    return nodes;
}

fn getFontSize(dom_nodes: []const dom.Node, styler: Styler, nodes: []LayoutNode, first_parent_box: usize) u32 {
    std.debug.assert(nodes.len > 0);
    var it = layoutParentIterator(nodes[0 .. first_parent_box + 1]);
    while (it.next()) |parent_box| {
        //std.log.info("   parent it '{s}'", .{@tagName(dom_nodes[parent_box.dom_node].start_tag.id)});
        if (styler.getFontSize(dom_nodes, parent_box.dom_node)) |font_size| {
            return font_size;
        }
    }
    return default_font_size;
}

fn endParentBox(
    text: []const u8,
    dom_nodes: []const dom.Node,
    styler: Styler,
    nodes: []LayoutNode,
) void {
    _ = text;
    const parent_box = switch (nodes[0]) {
        .box => |*b| b,
        else => unreachable,
    };
    const dom_node_ref = switch (dom_nodes[parent_box.dom_node]) {
        .start_tag => |*t| t,
        // all boxes that become "parents" should be start_tags I think?
        else => unreachable,
    };

    if (parent_box.content_size.x.getResolved() == null or parent_box.content_size.y.getResolved() == null) {

        // TODO:
        const style_size_y = styler.getSizeY(dom_nodes[parent_box.dom_node..]);
        //const mbp = styler.getMarginBorderPadding(dom_nodes[parent_box.dom_node..]);

        switch (style_size_y) {
            .px => @panic("should be impossible"), // unless this has changed since we set content_size?
            .parent_ratio => @panic("todo: endParentTag 'parent_ratio' style height"),
            .content => {
                var content_height: u32 = 2 * parent_box.mbp.margin + 2 * parent_box.mbp.border + 2 * parent_box.mbp.padding;
                var it = directChildIterator(nodes);
                while (it.next()) |node| {
                    switch(node.*) {
                        .box => |box| {
                            // I *think* my algorithm guarantees content size MUST be set at this point?
                            const y = box.content_size.y.getResolved() orelse unreachable;
                            // TODO: we only add the content height if this box is on its own line
                            //       we could maybe use display:block, but display:block might just translate
                            //       to witdh:100% so we might just be able to look at the width?
                            content_height += y + 2 * box.mbp.border + 2 * box.mbp.margin;
                        },
                        .end_box => unreachable, // should be impossible
                        .text => {

                        }, // ignore for now
                        .svg => {}, // ignore for now
                    }
                }
                parent_box.content_size.y = .{ .resolved = content_height };
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

const LayoutParentIterator = struct {
    ptr: [*]const LayoutNode,
    index: usize,
    pub fn next(self: *LayoutParentIterator) ?*const Box {
        if (self.index == std.math.maxInt(usize)) return null;

        switch (self.ptr[self.index]) {
            .box => |*box| {
                self.index = box.parent_box;
                return box;
            },
            else => unreachable,
        }
    }
};
fn layoutParentIterator(nodes: []const LayoutNode) LayoutParentIterator {
    std.debug.assert(nodes.len > 0);
    switch (nodes[nodes.len-1]) {
        .box => {},
        else => unreachable,
    }
    return LayoutParentIterator{ .ptr = nodes.ptr, .index = nodes.len - 1 };
}

const DirectChildIterator = struct {
    nodes: []const LayoutNode,
    index: usize,
    last_node_was_container: bool,
    pub fn next(self: *DirectChildIterator) ?*const LayoutNode {
        std.debug.assert(self.index != 0);
        if (self.last_node_was_container) {
            var depth: usize = 1;
            node_loop:
            while (true) {
                self.index += 1;
                switch (self.nodes[self.index - 1]) {
                    .box => depth += 1,
                    .end_box => {
                        depth -= 1;
                        if (depth == 0) break :node_loop;
                    },
                    .text => {},
                    .svg => {},
                }
                std.debug.assert(self.index < self.nodes.len);
            }
        }
        if (self.index == self.nodes.len) {
            self.last_node_was_container = false;
            return null;
        }
        self.last_node_was_container = switch (self.nodes[self.index]) {
            .box => true,
            // should be impossible because the list of nodes should not include the top-level box's end_box
            .end_box => unreachable,
            .text => false,
            .svg => false,
        };
        self.index += 1;
        return &self.nodes[self.index-1];
    }
};
fn directChildIterator(nodes: []const LayoutNode) DirectChildIterator {
    std.debug.assert(nodes.len >= 1);
    switch (nodes[0]) {
        .box => {},
        .end_box => unreachable,
        .text => unreachable,
        .svg => unreachable,
    }
    return DirectChildIterator{ .nodes = nodes, .index = 1, .last_node_was_container = false };
}
