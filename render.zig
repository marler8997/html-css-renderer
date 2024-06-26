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
    var next_no_relative_position_box_y: i32 = 200;

    var current_box_content_pos = XY(i32){ .x = 0, .y = 0 };

    for (layout_nodes, 0..) |node, node_index| switch (node) {
        .box => |b| {
            if (b.content_size.x.getResolved() == null or b.content_size.y.getResolved() == null) {
                std.log.warn("box size at index {} not resolved, should be impossible once fully implemented", .{node_index});
            } else {
                const content_size = XY(u32){
                    .x = b.content_size.x.getResolved().?,
                    .y = b.content_size.y.getResolved().?,
                };

                const color = unique_colors[next_color_index];
                next_color_index = (next_color_index + 1) % unique_colors.len;

                const x = current_box_content_pos.x + @as(i32, @intCast(b.relative_content_pos.x));
                {
                    const y = current_box_content_pos.y + @as(i32, @intCast(b.relative_content_pos.y));
                    try onRender(ctx, .{ .rect = .{
                        .x = @intCast(x), .y = @intCast(y),
                        .w = content_size.x, .h = content_size.y,
                        .fill = true, .color = color,
                    }});
                }

                const explode_view = true;
                if (explode_view) {
                    const y = next_no_relative_position_box_y;
                    next_no_relative_position_box_y += @as(i32, @intCast(content_size.y)) + 5;

                    try onRender(ctx, .{ .rect = .{
                        .x = @intCast(x), .y = @intCast(y),
                        .w = content_size.x, .h = content_size.y,
                        .fill = false, .color = color,
                    }});
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
                    try onRender(ctx, .{ .text = .{
                        .x = @as(u32, @intCast(x))+1, .y = @as(u32, @intCast(y))+1,
                        .size = font_size, .slice = msg,
                    }});
                }
            }

            current_box_content_pos = .{
                .x = current_box_content_pos.x + @as(i32, @intCast(b.relative_content_pos.x)),
                .y = current_box_content_pos.y + @as(i32, @intCast(b.relative_content_pos.y)),
            };
        },
        .end_box => |box_index| {
            const b = switch (layout_nodes[box_index]) {
                .box => |*b| b,
                else => unreachable,
            };
            current_box_content_pos = .{
                .x = current_box_content_pos.x - @as(i32, @intCast(b.relative_content_pos.x)),
                .y = current_box_content_pos.y - @as(i32, @intCast(b.relative_content_pos.y)),
            };
        },
        .text => |t| {
            var line_it = layout.textLineIterator(t.font, t.first_line_x, t.max_width, t.slice);

            const first_line = line_it.first();
            // TODO: set this correctly
            const abs_x_i32 = current_box_content_pos.x + @as(i32, @intCast(t.relative_content_pos.x));
            var abs_y_i32 = current_box_content_pos.y + @as(i32, @intCast(t.relative_content_pos.y));
            // TODO: abs_x should be signed
            const abs_x_u32: u32 = @intCast(abs_x_i32);
            // TODO: abs_y should be signed
            var abs_y_u32: u32 = @intCast(abs_y_i32);
            try onRender(ctx, .{ .text = .{ .x = abs_x_u32 + t.first_line_x, .y = abs_y_u32, .size = t.font.size, .slice = first_line.slice }});
            // TODO: this first_line_height won't be correct right now if there
            //       is another element after us on the same line with a bigger height
            abs_y_i32 += @intCast(t.first_line_height);
            abs_y_u32 += t.first_line_height;
            while (line_it.next()) |line| {
                try onRender(ctx, .{ .text = .{ .x = abs_x_u32, .y = abs_y_u32, .size = t.font.size, .slice = line.slice }});
                abs_y_i32 += @intCast(t.font.getLineHeight());
                abs_y_u32 += t.font.getLineHeight();
            }
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
