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

    // NOTE: we don't needs a stack for these states because they can only go 1 level deep
    var in_body = false;
    var in_script = false;

    var render_cursor = XY(u32) { .x = 0, .y = 0 };
    var current_line_height: ?u32 = null;

    const StackState = union(enum) {
        font_size: u32,
    };
    var state_stack = std.ArrayListUnmanaged(StackState) { };

    for (dom_nodes) |node| {
        if (!in_body) {
            switch (node) {
                .start_tag => |t| {
                    if (t.id == .body) in_body = true;
                },
                .end_tag => {},
                .attr => {},
                .text => {},
            }
            continue;
        }
        switch (node) {
            .text => |span| if (in_body and !in_script) {
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
                    .body => in_body = true,
                    .script => in_script = true,
                    .h1 => try state_stack.append(allocator, .{ .font_size = 32 }),
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
                    .body => in_body = false,
                    .script => in_script = false,
                    .h1 => pop(StackState, &state_stack),
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
