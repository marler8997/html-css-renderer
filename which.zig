const std = @import("std");

pub fn main() !u8 {
    if (std.os.argv.len <= 1) {
        return 1;
    }
    const PATH = std.os.getenvZ("PATH") orelse return 1;

    var got_error = false;
  prog_loop:
    for (std.os.argv.ptr[1..std.os.argv.len]) |prog_ptr| {
        const prog = std.mem.span(prog_ptr);
        var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        var it = std.mem.tokenize(u8, PATH, ":");
        while (it.next()) |search_path| {
            const path_len = search_path.len + prog.len + 1;
            if (path_buf.len < path_len + 1) continue;
            std.mem.copy(u8, &path_buf, search_path);
            path_buf[search_path.len] = '/';
            std.mem.copy(u8, path_buf[search_path.len + 1 ..], prog);
            path_buf[path_len] = 0;
            const full_path = path_buf[0..path_len :0].ptr;
            std.fs.cwd().accessZ(full_path, .{}) catch {
                continue;
            };
            try std.io.getStdOut().writer().print("{s}\n", .{std.mem.span(full_path)});
            continue :prog_loop;
        }
        got_error = true;
    }
    return if (got_error) 1 else 0;
}
