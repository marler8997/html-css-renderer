const std = @import("std");
const dom = @import("dom.zig");

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        pub fn init(x: T, y: T) @This() {
            return .{ .x = x, .y = y };
        }
    };
}
const Styler = struct {
};

const LayoutNode = union(enum) {
    
};
fn layout(
    allocator: std.mem.Allocator,
    text: []const u8,
    nodes: []const dom.Node,
    viewport_size: XY(u32),
    styler: Styler,
) []const LayoutNode {
    _ = allocator;
    _ = viewport_size;
    _ = styler;
    
    const font_height = 10;
    
    var in_body = false;
    var y: usize = 0;

    for (nodes) |node| {
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
                const full_slice = span.slice(text);
                const slice = std.mem.trim(u8, full_slice, " \t\r\n");
                if (slice.len > 0) {
                    //js.drawText(0, y + font_height, slice.ptr, slice.len);
                    std.log.warn("todo: append layout node", .{});
                    y += font_height;
                }
            },
            .tag => |tag| {
                std.log.info("todo: handle tag {s}", .{@tagName(tag.id)});
            },
            .attr => {},
        }
    }
}
