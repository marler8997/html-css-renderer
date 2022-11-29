const std = @import("std");
const os = std.os;

pub const log_level: std.log.Level = .warn;

fn usage() void {
    std.io.getStdErr().writer().writeAll("Usage: fsveil [OPTIONS...] FILES DIRS -- CMD...\n");
}

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn getCmdlineOption(i: *usize) [*:0]u8 {
    i.* += 1;
    if (i.* >= os.argv.len) {
        std.log.err("command-line option '{s}' requires an argument", .{os.argv[i.* - 1]});
        os.exit(0xff);
    }
    return os.argv[i.*];
}
pub fn main() !void {
    const Link = struct {
        to: [*:0]u8,
        from: [:0]u8,
    };
    var links = std.ArrayListUnmanaged(Link){};
    var opt: struct {
        //sysroot_path: ?[:0]const u8 = null,
        next_argv: ?[*:null]?[*:0]u8 = null,
        keep_readwrite: bool = false,
    } = .{};

    var new_argc: usize = 1;
    {
        var arg_index: usize = 1;
        while (arg_index < os.argv.len) : (arg_index += 1) {
            const arg = std.mem.span(os.argv[arg_index]);
            if (std.mem.eql(u8, arg, "--")) {
                opt.next_argv = @ptrCast([*:null]?[*:0]u8, os.argv[arg_index + 1 ..].ptr);
                break;
            } else if (std.mem.eql(u8, arg, "--link")) {
                const to = getCmdlineOption(&arg_index);
                const from = std.mem.span(getCmdlineOption(&arg_index));
                try links.append(arena.allocator(), .{ .to = to, .from = from });
            } else if (std.mem.eql(u8, arg, "--keep-rw")) {
                opt.keep_readwrite = true;
            } else {
                os.argv[new_argc] = arg.ptr;
                new_argc += 1;
            }
        }
    }

    const next_argv = opt.next_argv orelse {
        std.log.err("missing '--' to delineate a command to execute", .{});
        os.exit(0xff);
    };
    const next_program = next_argv[0] orelse {
        std.log.err("missing program after '--'", .{});
        os.exit(0xff);
    };

    const sysroot_path = blk: {
        if (std.fs.accessAbsolute("/mnt", .{})) {
            break :blk "/mnt";
        } else |_| {}
        // NOTE: temporary hack to make sure we don't have any conflicts
        //       as of this moment, we don't need any files from /root
        break :blk "/root";
    };
    try std.fs.cwd().makePath(sysroot_path);

    const pre_unshare_uids = getUids();
    std.log.info("PreUnshare Uids: {}", .{pre_unshare_uids});
    const pre_unshare_gids = getGids();
    std.log.info("PreUnshare Gids: {}", .{pre_unshare_gids});

    // NEWPID might be necessary for mounting /proc in some cases
    switch (os.errno(os.linux.unshare(os.linux.CLONE.NEWUSER | os.linux.CLONE.NEWNS))) {
        .SUCCESS => {},
        else => |e| {
            std.log.err("unshare failed, errno={}", .{e});
            os.exit(0xff);
        },
    }
    {
        const uids = getUids();
        std.log.info("PostUnshare Uids: {}", .{uids});
    }
    {
        var fd = try os.open("/proc/self/setgroups", os.O.WRONLY, 0);
        defer os.close(fd);
        const content = "deny";
        const written = try os.write(fd, content);
        std.debug.assert(written == content.len);
    }
    {
        var fd = try os.open("/proc/self/uid_map", os.O.WRONLY, 0);
        defer os.close(fd);
        var buf: [200]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf, "{} {0} 1", .{pre_unshare_uids.real});
        const written = try os.write(fd, content);
        std.debug.assert(written == content.len);
    }
    {
        const uids = getUids();
        std.log.info("PostSetUidMap Uids: {}", .{uids});
    }
    {
        var fd = try os.open("/proc/self/gid_map", os.O.WRONLY, 0);
        defer os.close(fd);
        var buf: [200]u8 = undefined;
        const content = try std.fmt.bufPrint(&buf, "0 {} 1", .{pre_unshare_gids.real});
        const written = try os.write(fd, content);
        std.debug.assert(written == content.len);
    }

    // let's mark all of our mounts as private
    std.log.info("marking all mounts as private", .{});
    switch (os.errno(mount("none", "/", null, os.linux.MS.REC | os.linux.MS.PRIVATE, 0))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("mount failed with E{s}", .{@tagName(errno)});
            os.exit(0xff);
        },
    }

    std.log.info("mounting tmpfs to '{s}'", .{sysroot_path});
    switch (os.errno(os.linux.mount("none", sysroot_path, "tmpfs", 0, 0))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("mount failed with E{s}", .{@tagName(errno)});
            os.exit(0xff);
        },
    }

    //try shell("sh");

    for (os.argv[1..new_argc]) |path_ptr| {
        var stat: os.linux.Stat = undefined;
        switch (os.errno(os.linux.stat(path_ptr, &stat))) {
            .SUCCESS => {},
            else => |errno| {
                std.log.err("stat '{s}' failed with E{s}", .{ path_ptr, @tagName(errno) });
                os.exit(0xff);
            },
        }

        const path = std.mem.span(path_ptr);
        var path_in_sysroot_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const path_in_sysroot = try std.fmt.bufPrintZ(&path_in_sysroot_buf, "{s}{s}", .{ sysroot_path, path });

        if ((stat.mode & os.linux.S.IFREG) != 0) {
            if (std.fs.path.dirname(path_in_sysroot)) |parent_dir_in_sysroot| {
                std.log.info("mkdir -p {s}...", .{parent_dir_in_sysroot});
                try std.fs.cwd().makePath(parent_dir_in_sysroot);
            }
            std.log.info("copying file '{s}'", .{path});
            var src_file = try std.fs.cwd().openFile(path, .{});
            defer src_file.close();
            var dst_file = try std.fs.cwd().createFile(path_in_sysroot, .{});
            defer dst_file.close();
            var buf: [std.mem.page_size]u8 = undefined;
            var total_copied: u64 = 0;
            while (true) {
                const len = try os.read(src_file.handle, &buf);
                if (len == 0) break;
                try dst_file.writer().writeAll(buf[0..len]);
                total_copied += len;
            }
            std.log.info("copied {} bytes", .{total_copied});
            try os.fchmod(dst_file.handle, stat.mode);
        } else if ((stat.mode & os.linux.S.IFDIR) != 0) {
            std.log.info("mkdir -p {s}...", .{path_in_sysroot});
            try std.fs.cwd().makePath(path_in_sysroot);
            std.log.info("mount --bind '{s}' to '{s}'", .{ path, path_in_sysroot });
            var flags: u32 = os.linux.MS.BIND;
            if (std.mem.eql(u8, path, "/proc") or
                std.mem.eql(u8, path, "/dev") or
                std.mem.eql(u8, path, "/sys") or
                std.mem.eql(u8, path, "/tmp") or
                // TODO: provide command-line interface to make any mount restricted like this
                std.mem.eql(u8, path, "/run") or
                std.mem.startsWith(u8, path, "/run/"))
            {
                flags |= os.linux.MS.NOSUID | os.linux.MS.NOEXEC | os.linux.MS.NODEV | os.linux.MS.REC | os.linux.MS.PRIVATE;
            }

            switch (os.errno(mount(path, path_in_sysroot, null, flags, 0))) {
                .SUCCESS => {},
                else => |errno| {
                    // for some reason I can bind mount /proc on my NixOS machine but not my Ubuntu machine?
                    if (std.mem.eql(u8, path, "/proc")) {
                        std.log.warn("failed to bind mount /proc with E{s}, gonna try to mount it directly", .{@tagName(errno)});
                        switch (os.errno(mount("none", "/proc", null, os.linux.MS.PRIVATE | os.linux.MS.REC, 0))) {
                            .SUCCESS => {},
                            else => |errno2| {
                                std.log.warn("failed to mount it directly(at 0) also with E{s}", .{@tagName(errno2)});
                                try shell("sh");
                                os.exit(0xff);
                            },
                        }
                        switch (os.errno(mount("proc", path_in_sysroot, "proc", os.linux.MS.NOSUID | os.linux.MS.NOEXEC | os.linux.MS.NODEV, 0))) {
                            .SUCCESS => {},
                            else => |errno2| {
                                std.log.warn("failed to mount it directly(at 1) also with E{s}", .{@tagName(errno2)});
                                try shell("sh");
                                os.exit(0xff);
                            },
                        }
                        continue;
                    }
                    std.log.err("mount failed, errno=E{s}", .{@tagName(errno)});
                    os.exit(0xff);
                },
            }
        } else {
            std.log.err("unknown file type 0x{x}", .{stat.mode & os.linux.S.IFMT});
            os.exit(0xff);
        }
    }

    var cwd_path_buf: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
    const cwd_path = try std.process.getCwd(cwd_path_buf[0 .. cwd_path_buf.len - 1]);
    cwd_path_buf[cwd_path.len] = 0;
    {
        var sysroot_cwd_path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const sysroot_cwd_path = try std.fmt.bufPrintZ(&sysroot_cwd_path_buf, "{s}{s}", .{ sysroot_path, cwd_path });
        std.log.info("creating {s}...", .{sysroot_cwd_path});
        try std.fs.cwd().makePath(sysroot_cwd_path);
    }

    for (links.items) |link| {
        std.log.info("ln -s '{s}' '{s}'", .{ std.mem.span(link.to), link.from });
        var from_path_buf: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
        const from_path = try std.fmt.bufPrintZ(&from_path_buf, "{s}{s}", .{ sysroot_path, std.mem.span(link.from) });
        if (std.fs.path.dirname(from_path)) |from_dir| {
            try std.fs.cwd().makePath(from_dir);
        }
        switch (os.errno(os.linux.symlink(link.to, from_path))) {
            .SUCCESS => {},
            else => |errno| {
                std.log.err("symlink from '{s}' to '{s}' failed, errno={}", .{ from_path, std.mem.span(link.to), errno });
                os.exit(0xff);
            },
        }
    }

    // TODO: make an option to disable this for debugging purposes and such
    //       we might be able to do this after chrooting
    if (opt.keep_readwrite) {
        std.log.warn("keeping veil root writable", .{});
    } else {
        std.log.info("remounting veil root as readonly...", .{});
        switch (os.errno(mount("none", sysroot_path, null, os.linux.MS.REMOUNT | os.linux.MS.RDONLY, 0))) {
            .SUCCESS => {},
            else => |errno| {
                std.log.err("remount viel root as readonly failed with E{s}", .{@tagName(errno)});
                os.exit(0xff);
            },
        }
    }

    //try shell();

    switch (os.errno(os.linux.chroot(sysroot_path))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("chroot '{s}' failed, errno={}", .{ sysroot_path, errno });
            os.exit(0xff);
        },
    }
    std.log.info("chroot successful!", .{});

    std.log.info("cd '{s}'", .{cwd_path});
    try os.chdirZ(std.meta.assumeSentinel(cwd_path, 0));

    std.log.info("execve '{s}'", .{next_program});
    const errno = os.linux.execve(
        next_program,
        next_argv,
        @ptrCast([*:null]const ?[*:0]const u8, os.environ.ptr),
    );
    std.log.err("execve failed, errno={}", .{errno});
    os.exit(0xff);
}

fn shell(name: []const u8) !void {
    var child = std.ChildProcess.init(&[_][]const u8{name}, std.heap.page_allocator);
    try child.spawn();
    const result = child.wait();
    std.log.info("shell exited with {}", .{result});
    os.exit(0);
}

const Ids = struct {
    real: os.uid_t,
    effective: os.uid_t,
    saved: os.uid_t,

    pub fn isSuid(self: Ids) bool {
        return self.real != self.effective or self.real != self.saved;
    }
};

fn getUids() Ids {
    var ids: Ids = undefined;
    switch (os.errno(os.linux.getresuid(&ids.real, &ids.effective, &ids.saved))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("getresuid failed, errno={}", .{errno});
            os.exit(0xff);
        },
    }
    return ids;
}

fn getGids() Ids {
    var ids: Ids = undefined;
    switch (os.errno(os.linux.getresgid(&ids.real, &ids.effective, &ids.saved))) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("getresgid failed, errno={}", .{errno});
            os.exit(0xff);
        },
    }
    return ids;
}

// TODO: workaround non-optional fstype argument: https://github.com/ziglang/zig/pull/11889
pub fn mount(special: [*:0]const u8, dir: [*:0]const u8, fstype: ?[*:0]const u8, flags: u32, data: usize) usize {
    return os.linux.syscall5(.mount, @ptrToInt(special), @ptrToInt(dir), @ptrToInt(fstype), flags, data);
}
