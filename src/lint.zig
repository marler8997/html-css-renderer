const builtin = @import("builtin");
const std = @import("std");

const Tokenizer = @import("Tokenizer.zig");

pub fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}

pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.os.exit(0xff);
}

var windows_args_arena = if (builtin.os.tag == .windows)
    std.heap.ArenaAllocator.init(std.heap.page_allocator) else struct{}{};

pub fn cmdlineArgs() [][*:0]u8 {
    if (builtin.os.tag == .windows) {
        const slices = std.process.argsAlloc(windows_args_arena.allocator()) catch |err| switch (err) {
            error.OutOfMemory => oom(error.OutOfMemory),
            error.InvalidCmdLine => @panic("InvalidCmdLine"),
            error.Overflow => @panic("Overflow while parsing command line"),
        };
        const args = windows_args_arena.allocator().alloc([*:0]u8, slices.len - 1) catch |e| oom(e);
        for (slices[1..]) |slice, i| {
            args[i] = slice.ptr;
        }
        return args;
    }
    return std.os.argv.ptr[1 .. std.os.argv.len];
}

pub fn main() !u8 {
    const args = blk: {
        const all_args = cmdlineArgs();
        var non_option_len: usize = 0;
        for (all_args) |arg_ptr| {
            const arg = std.mem.span(arg_ptr);
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };
    for (args) |arg| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const filename = std.mem.span(arg);

        const content = blk: {
            var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
                std.log.err("failed to open '{s}' with {s}", .{filename, @errorName(err)});
                return 0xff;
            };
            defer file.close();
            break :blk try file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
        };

        var tokenizer = Tokenizer.init(content);
        while (try tokenizer.next()) |token| {
            switch (token) {
                .doctype => |d| {
                    const name = if (d.name_raw) |n| n.slice(content) else "<none>";
                    std.log.info("Doctype: name={s}", .{name});
                },
                .start_tag => |t| {
                    std.log.info("StartTag: name={s}", .{t.name_raw.slice(content)});
                },
                .attr => |a| {
                    const value = if (a.value_raw) |v| v.slice(content) else "<none>";
                    std.log.info("    Attr: name={s} value='{s}'", .{a.name_raw.slice(content), value});
                },
                .start_tag_end => |self_close| {
                    std.log.info("StartTagEnd: self_close={}", .{self_close});
                },
                .char => |c| {
                    var s: [10]u8 = undefined;
                    const len = std.unicode.utf8Encode(c, &s) catch unreachable;
                    std.log.info("Char: '{}'", .{std.zig.fmtEscapes(s[0 .. len])});
                },
                else => |t| {
                    std.log.info("{}", .{t});
                },
            }
        }
    }
    return 0;
}
