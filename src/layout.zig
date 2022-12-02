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

    var in_body = false;
    var y: u32 = 0;

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
            .text => |span| {
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
                        .x = 0, .y = y, .font_size = font_size, .slice = slice,
                    }});
                    y += font_size;
                }
            },
            .start_tag => |tag| {
                switch (tag.id) {
                    .h1 => try state_stack.append(allocator, .{ .font_size = 32 }),
                    else => std.log.info("todo: handle tag {s}", .{@tagName(tag.id)}),
                }
            },
            .end_tag => |id| {
                switch (id) {
                    .h1 => pop(StackState, &state_stack),
                    else => std.log.info("TODO: handle end tag '{s}'", .{@tagName(id)}),
                }
            },
            .attr => {},
        }
    }

    return nodes;
}
