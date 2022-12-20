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
            .relative_content_pos = undefined,
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

    pub fn getFont(self: Styler, dom_nodes: []const dom.Node, node_index: usize) ?Font {
        _ = self;
        switch (dom_nodes[node_index]) {
            .start_tag => |tag| {
                switch (tag.id) {
                    .h1 => {
                        std.log.warn("returning hardcoded font size {} for h1", .{default_font_size*2});
                        return .{ .size = default_font_size * 2 };
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
    relative_content_pos: XY(u32),
    content_size: XY(ContentSize),
    mbp: MarginBorderPadding,
};

pub const LayoutNode = union(enum) {
    box: Box,
    end_box: usize,
    text: struct {
        slice: []const u8,
        font: Font,
        first_line_x: u32,
        first_line_height: u32,
        max_width: u32,
        relative_content_pos: XY(u32),
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
        nodes.items[0].box.relative_content_pos = .{ .x = 0, .y = 0 };
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

    var parent_box: usize = 1;

    body_loop:
    while (dom_node_index < dom_nodes.len) : (dom_node_index += 1) {
        const dom_node = &dom_nodes[dom_node_index];
        switch (dom_node.*) {
            .start_tag => |tag| {
                const parent_content_size = nodes.items[parent_box].box.content_size;
                try nodes.append(allocator, .{ .box = styler.getBox(dom_nodes, dom_node_index, parent_box, parent_content_size) });
                std.log.info("<{s}> content size is {?} x {?}", .{
                    @tagName(tag.id),
                    nodes.items[nodes.items.len - 1].box.content_size.x,
                    nodes.items[nodes.items.len - 1].box.content_size.y,
                });
                parent_box = nodes.items.len - 1;

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
                    else => {},
                }
            },
            .attr => {},
            .end_tag => |id| {
                std.log.info("DEBUG: layout </{s}>", .{@tagName(id)});
                endParentBox(text, dom_nodes, styler, nodes.items, parent_box);
                try nodes.append(allocator, .{ .end_box = parent_box });
                parent_box = nodes.items[parent_box].box.parent_box;
                if (parent_box == std.math.maxInt(usize))
                    break :body_loop;
                std.log.info("DEBUG:     restore parent box to <{s}> (index={})", .{
                    // all boxes that become "parents" should be start_tags I think?
                    @tagName(dom_nodes[nodes.items[parent_box].box.dom_node].start_tag.id), parent_box,
                });
                switch (id) {
                    .script => in_script = false,
                    .svg => unreachable, // should be impossible
                    else => {},
                }
            },
            .text => |span| {
                if (in_script) continue;

                const full_slice = span.slice(text);
                const slice = std.mem.trim(u8, full_slice, " \t\r\n");
                if (slice.len == 0) continue;
                try nodes.append(allocator, .{ .text = .{
                    .slice = slice,
                    .font = undefined,
                    .first_line_x = undefined,
                    .first_line_height = undefined,
                    .max_width = undefined,
                    .relative_content_pos = undefined,
                }});
            },
        }
    }

    return nodes;
}

fn resolveFont(opt_font: *?Font, dom_nodes: []const dom.Node, styler: Styler, nodes: []LayoutNode, first_parent_box: usize) Font {
    if (opt_font.* == null) {
        opt_font.* = getFont(dom_nodes, styler, nodes, first_parent_box);
    }
    return opt_font.*.?;
}

fn getFont(dom_nodes: []const dom.Node, styler: Styler, nodes: []LayoutNode, first_parent_box: usize) Font {
    std.debug.assert(nodes.len > 0);
    var it = layoutParentIterator(nodes[0 .. first_parent_box + 1]);
    while (it.next()) |parent_box| {
        //std.log.info("   parent it '{s}'", .{@tagName(dom_nodes[parent_box.dom_node].start_tag.id)});
        if (styler.getFont(dom_nodes, parent_box.dom_node)) |font| {
            return font;
        }
    }
    return .{ .size = default_font_size };
}

fn endParentBox(
    text: []const u8,
    dom_nodes: []const dom.Node,
    styler: Styler,
    nodes: []LayoutNode,
    parent_box_index: usize,
) void {
    _ = text;
    const parent_box = switch (nodes[parent_box_index]) {
        .box => |*b| b,
        else => unreachable,
    };
    const dom_node_ref = switch (dom_nodes[parent_box.dom_node]) {
        .start_tag => |*t| t,
        // all boxes that become "parents" should be start_tags I think?
        else => unreachable,
    };

    if (parent_box.content_size.x.getResolved() == null or parent_box.content_size.y.getResolved() == null) {

        const content_size_x = parent_box.content_size.x.getResolved() orelse {
            std.log.err("TODO: not having a resolved width is not implemented", .{});
            @panic("todo");
        };
        if (2 * parent_box.mbp.padding >= content_size_x) {
            std.log.err("TODO: no room for content", .{});
            @panic("todo");
        }
        const padded_content_size_x = content_size_x - 2 * parent_box.mbp.padding;

        var pos_y: u32 = parent_box.mbp.padding;
        const CurrentLine = struct {
            x: u32,
            max_height: u32,
        };
        var opt_current_line: ?CurrentLine = null;
        var cached_font: ?Font = null;

        var content_height: u32 = 2 * parent_box.mbp.margin + 2 * parent_box.mbp.border + 2 * parent_box.mbp.padding;
        var child_it = directChildIterator(nodes[parent_box_index..]);
        while (child_it.next()) |node_ref| {
            switch(node_ref.*) {
                .box => |*box| {
                    const box_content_size = XY(u32) {
                        // My algorithm should guarantee that content size MUST be set at this point
                        .x = box.content_size.x.getResolved().?,
                        .y = box.content_size.y.getResolved().?,
                    };

                    // TODO: does this box go on the current line or the next line
                    if (opt_current_line) |line| {
                        _ = line;
                        std.log.err("TODO: handle box when we have already started the line", .{});
                        @panic("todo");
                    }

                    box.relative_content_pos = .{
                        .x = parent_box.mbp.padding + box.mbp.margin + box.mbp.border,
                        .y = pos_y + box.mbp.margin + box.mbp.border,
                    };

                    content_height += box_content_size.y;
                    content_height += box.mbp.border + box.mbp.margin;

                    // if is block element
                    if (dom.defaultDisplayIsBlock(dom_nodes[box.dom_node].start_tag.id)) {
                        opt_current_line = null;
                    } else {
                        std.log.err("TODO: update the current line", .{});
                    }
                },
                .end_box => unreachable, // should be impossible
                .text => |*text_node| {
                    text_node.relative_content_pos = .{
                        .x = parent_box.mbp.padding,
                        .y = pos_y,
                    };
                    const current_line = opt_current_line orelse CurrentLine{ .x = 0, .max_height = 0 };
                    text_node.first_line_x = current_line.x;
                    text_node.max_width = padded_content_size_x;

                    text_node.font = resolveFont(&cached_font, dom_nodes, styler, nodes, parent_box_index);
                    var line_it = textLineIterator(text_node.font, current_line.x, padded_content_size_x, text_node.slice);

                    const first_line = line_it.first();
                    text_node.first_line_x = current_line.x;
                    opt_current_line = .{
                        .x = current_line.x + first_line.width,
                        .max_height = std.math.max(current_line.max_height, text_node.font.getLineHeight()),
                    };
                    // TODO: this value wont' be correct if there is another element
                    //       come after us on the same line with a higher height.
                    text_node.first_line_height = opt_current_line.?.max_height;
                    while (line_it.next()) |line| {
                        pos_y += opt_current_line.?.max_height;
                        opt_current_line = .{
                            .x = line.width,
                            .max_height = text_node.font.getLineHeight(),
                        };
                    }
                },
                .svg => {}, // ignore for now
            }
        }
        parent_box.content_size.y = .{ .resolved = content_height };
        std.log.info("content height for <{s}> resolved to {}", .{@tagName(dom_node_ref.id), content_height});
    }
}

pub const Font = struct {
    size: u32,
    pub fn getLineHeight(self: Font) u32 {
        // a silly hueristic
        return self.size;
    }
    pub fn getSpaceWidth(self: Font) u32 {
        // just a silly hueristic for now
        return @floatToInt(u32, @intToFloat(f32, self.size) * 0.48);
    }
};


pub const TextLineResult = struct {
    slice: []const u8,
    width: u32,
};
pub const TextLineIterator = struct {
    font: Font,
    start_x: u32,
    max_width: u32,
    slice: []const u8,
    index: usize,

    pub fn first(self: *TextLineIterator) TextLineResult {
        if (self.start_x == 0) {
            var r = self.next() orelse unreachable;
            return .{ .slice = r.slice, .width = r.width };
        }

        std.log.info("TODO: implement TextLineIterator.first", .{});
        self.start_x = 0; // allow next to be called now
        @panic("todo");
    }
    pub fn next(self: *TextLineIterator) ?TextLineResult {
        std.debug.assert(self.start_x == 0);
        if (self.index == self.slice.len) return null;

        const start = self.index;
        const line = calcTextLineWidth(self.font, self.slice[start..], self.max_width) catch unreachable;
        std.debug.assert(line.consumed > 0);
        self.index += line.consumed;

        return .{
            .slice = self.slice[start .. start + line.consumed],
            .width = line.width,
        };
    }
};
pub fn textLineIterator(font: Font, start_x: u32, max_width: u32, slice: []const u8) TextLineIterator {
    return .{
        .font = font,
        .start_x = start_x,
        .max_width = max_width,
        .slice = slice,
        .index = 0,
    };
}

const LineResult = struct {
    consumed: usize,
    width: u32,
};
fn calcTextLineWidth(font: Font, text: []const u8, max_width: u32) !LineResult {
    var total_width: u32 = 0;
    var it = HtmlCharIterator.init(text);

    while (true) {
        // skip whitespace
        const start = blk: {
            const start = it.index;
            while (try it.next()) |c| {
                if (!isWhitespace(c)) break :blk start;
            }
            return .{ .consumed = text.len, .width = total_width };
        };

        if (total_width > 0) {
            const next_width = total_width + font.getSpaceWidth();
            if (next_width >= max_width)
                return .{ .consumed = start, .width = total_width };
            total_width = next_width;
        }
        const word = try calcWordWidth(font, text[start..]);
        const next_width = total_width + word.width;
        if (total_width > 0) {
            if (next_width >= max_width)
                return .{ .consumed = start, .width = total_width };
        }
        total_width = next_width;
        it.index = start + word.byte_len;
    }
}

const WordWidth = struct {
    byte_len: usize,
    width: u32,
};
// assumption: text starts with at least one non-whitespace character
fn calcWordWidth(font: Font, text: []const u8) !WordWidth {
    std.debug.assert(text.len > 0);

    var it = HtmlCharIterator.init(text);
    var c = (it.next() catch unreachable).?;
    std.debug.assert(!isWhitespace(c));

    var total_width: u32 = 0;
    while (true) {
        total_width += calcCharWidth(font, c);
        c = (try it.next()) orelse break;
        if (isWhitespace(c)) break;
    }
    return .{ .byte_len = text.len, .width = total_width };
}

// NOTE! it's very possible that characters could be different widths depending on
//       their surrounding letters, but, for simplicity we'll just assume this for now
fn calcCharWidth(font: Font, char: u21) u32 {
    std.debug.assert(!isWhitespace(char));
    // this is not right, just an initial dumb implementation
    return font.getSpaceWidth();
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
    nodes: []LayoutNode,
    index: usize,
    last_node_was_container: bool,
    pub fn next(self: *DirectChildIterator) ?*LayoutNode {
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
fn directChildIterator(nodes: []LayoutNode) DirectChildIterator {
    std.debug.assert(nodes.len >= 1);
    switch (nodes[0]) {
        .box => {},
        .end_box => unreachable,
        .text => unreachable,
        .svg => unreachable,
    }
    return DirectChildIterator{ .nodes = nodes, .index = 1, .last_node_was_container = false };
}

fn isWhitespace(c: u21) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}
