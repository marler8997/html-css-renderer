const std = @import("std");

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

pub fn main() !u8 {
    const args = blk: {
        const all_args = try std.process.argsAlloc(arena.allocator());
        var non_option_len: usize = 0;
        for (all_args[1..]) |arg| {
            if (!std.mem.startsWith(u8, arg, "-")) {
                all_args[non_option_len] = arg;
                non_option_len += 1;
            } else {
                fatal("unknown cmdline option '{s}'", .{arg});
            }
        }
        break :blk all_args[0 .. non_option_len];
    };
    if (args.len != 3) {
        try std.io.getStdErr().writer().writeAll(
            "Usage: make-renderer-webpage WASM_FILE HTML_TEMPLATE OUT_FILE\n",
        );
        return 0xff;
    }
    const wasm_filename = args[0];
    const html_template_filename = args[1];
    const out_filename = args[2];
    const wasm_base64 = try getWasmBase64(wasm_filename);
    const html_template = try readFile(html_template_filename);
    const marker = "<@INSERT_WASM_HERE@>";
    const wasm_marker = std.mem.indexOf(u8, html_template, marker) orelse {
        std.log.err("{s} is missing wasm marker '{s}'", .{html_template_filename, marker});
        return 0xff;
    };
    {
        if (std.fs.path.dirname(out_filename)) |out_dir| {
            try std.fs.cwd().makePath(out_dir);
        }
        var out_file = try std.fs.cwd().createFile(out_filename, .{});
        defer out_file.close();
        try out_file.writer().writeAll(html_template[0 .. wasm_marker]);
        try out_file.writer().writeAll(wasm_base64);
        try out_file.writer().writeAll(html_template[wasm_marker + marker.len..]);
    }
    return 0;
}

fn getWasmBase64(filename: []const u8) ![]u8 {
    const bin = try readFile(filename);
    defer arena.allocator().free(bin);

    const encoder = &std.base64.standard.Encoder;
    const b64 = try arena.allocator().alloc(u8, encoder.calcSize(bin.len));
    const len = encoder.encode(b64, bin).len;
    std.debug.assert(len == b64.len);
    return b64;
}


fn readFile(filename: []const u8) ![]u8 {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();
    return file.readToEndAlloc(arena.allocator(), std.math.maxInt(usize));
}
