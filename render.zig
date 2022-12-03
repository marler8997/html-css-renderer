const std = @import("std");
const dom = @import("dom.zig");

pub fn dump(content: []const u8, nodes: []const dom.Node) !void {
    const stdout = std.io.getStdOut().writer();
    for (nodes) |node| {
        switch (node) {
            .start_tag => |t| {
                const close: []const u8 = if (t.self_closing) " /" else "";
                try stdout.print("<{s}{s}>\n", .{@tagName(t.id), close});
            },
            .end_tag => |id| try stdout.print("</{s}>\n", .{@tagName(id)}),
            .attr => |a| {
                if (a.value) |v| {
                    try stdout.print("  {s}=\"{s}\"\n", .{@tagName(a.id), v.slice(content)});
                } else {
                    try stdout.print("  {s}=\n", .{@tagName(a.id)});
                }
            },
            .text => |t| {
                try stdout.print("---text---\n{s}\n----------\n", .{t.slice(content)});
            },
        }
    }
}
