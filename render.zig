const std = @import("std");
const dom = @import("dom.zig");
const layout = @import("layout.zig");
const XY = layout.XY;
const LayoutNode = layout.LayoutNode;

pub const Op = union(enum) {
    rect: struct {
        x: u32, y: u32,
        w: u32, h: u32,
        fill: bool,
        color: u32,
    },
    text: struct {
        x: u32, y: u32,
        size: u32,
        slice: []const u8,
    },
};

// TODO: it would be better to make this an iterator, but, that would be
//       more complex/harder to implement.  I can maybe do that later an
//       an improvement to the API.
pub fn render(
    html: []const u8,
    dom_nodes: []const dom.Node,
    layout_nodes: []const LayoutNode,
    comptime Ctx: type,
    onRender: anytype,
    ctx: Ctx,
) !void {
    _ = html;
    
    var next_color_index: usize = 0;
    var next_no_relative_position_box_y: usize = 200;

    var current_box_pos = XY(u32){ .x = 0, .y = 0 };
    _ = current_box_pos;

    for (layout_nodes) |node, node_index| switch (node) {
        .box => |b| {
            // TODO: offset current_box_pos
            if (b.content_size.x.getResolved() == null or b.content_size.y.getResolved() == null) {
                std.log.warn("box size at index {} not resolved, should be impossible once fully implemented", .{node_index});
            } else {
                const content_size = XY(u32){
                    .x = b.content_size.x.getResolved().?,
                    .y = b.content_size.y.getResolved().?,
                };

                const color = unique_colors[next_color_index];
                next_color_index = (next_color_index + 1) % unique_colors.len;

                // TODO: the x/y aren't right here yet
                const x = b.relative_content_pos.x;
                const explode_view = true;
                const y = blk: {
                    if (explode_view) {
                        const y = next_no_relative_position_box_y;
                        next_no_relative_position_box_y += content_size.y + 5;
                        break :blk @intCast(u32, y);
                    }
                    break :blk b.relative_content_pos.y;
                };
                try onRender(ctx, .{ .rect = .{ .x = x, .y = y, .w = content_size.x, .h = content_size.y, .fill = false, .color = color}});
                {
                    var text_buf: [300]u8 = undefined;
                    const msg = std.fmt.bufPrint(
                        &text_buf,
                        "box index={} {s} {}x{}", .{
                            node_index,
                            switch (dom_nodes[b.dom_node]) {
                                .start_tag => |t| @tagName(t.id),
                                .text => @as([]const u8, "text"),
                                else => unreachable,
                            },
                            content_size.x,
                            content_size.y,
                        },
                    ) catch unreachable;
                    const font_size = 10;
                    try onRender(ctx, .{ .text = .{ .x = x+1, .y = y+1, .size = font_size, .slice = msg}});
                }
            }
        },
        .end_box => |box_index| {
            // TODO: remove offset from current_box_pos
            _ = box_index;
            //const parent_box = layout_nodes.items[box_index].parent_box;
            //parent_box_content_pos = layout_nodes.items[parent_box].relative_content_pos;
        },
        .text => |t| {
            // TODO: offset x/y with current box position
            _ = t;
            //js.drawText(t.x, t.y + t.font_size, t.font_size, t.slice.ptr, t.slice.len);
        },
        .svg => {
            std.log.info("TODO: draw svg!", .{});
        },
    };
}

var unique_colors = [_]u32 {
    0xe6194b, 0x3cb44b, 0xffe119, 0x4363d8, 0xf58231, 0x911eb4, 0x46f0f0,
    0xf032e6, 0xbcf60c, 0xfabebe, 0x008080, 0xe6beff, 0x9a6324, 0xfffac8,
    0x800000, 0xaaffc3, 0x808000, 0xffd8b1, 0x000075, 0x808080,
};
