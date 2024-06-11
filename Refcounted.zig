const Refcounted = @This();

const std = @import("std");
const arc = std.log.scoped(.arc);

const Metadata = struct {
    refcount: usize,
};
const alloc_prefix_len = std.mem.alignForward(usize, @sizeOf(Metadata), @alignOf(Metadata));

data_ptr: [*]u8,
pub fn alloc(allocator: std.mem.Allocator, len: usize) error{OutOfMemory}!Refcounted {
    const alloc_len = Refcounted.alloc_prefix_len + len;
    const full = try allocator.alignedAlloc(u8, @alignOf(Refcounted.Metadata), alloc_len);
    const buf = Refcounted{ .data_ptr = full.ptr + Refcounted.alloc_prefix_len };
    buf.getMetadataRef().refcount = 1;
    arc.debug(
        "alloc {} (full={}) returning data_ptr 0x{x}",
        .{len, alloc_len, @intFromPtr(buf.data_ptr)},
    );
    return buf;
}
pub fn getMetadataRef(self: Refcounted) *Metadata {
    const addr = @intFromPtr(self.data_ptr);
    return @ptrFromInt(addr - alloc_prefix_len);
}
pub fn addRef(self: Refcounted) void {
    // TODO: what is AtomicOrder supposed to be?
    const old_count = @atomicRmw(usize, &self.getMetadataRef().refcount, .Add, 1, .seq_cst);
    arc.debug("addRef data_ptr=0x{x} new_count={}", .{@intFromPtr(self.data_ptr), old_count + 1});
}
pub fn unref(self: Refcounted, allocator: std.mem.Allocator, len: usize) void {
    const base_addr = @intFromPtr(self.data_ptr) - alloc_prefix_len;
    // TODO: what is AtomicOrder supposed to be?
    const old_count = @atomicRmw(usize, &@as(*Metadata, @ptrFromInt(base_addr)).refcount, .Sub, 1, .seq_cst);
    std.debug.assert(old_count != 0);
    if (old_count == 1) {
        arc.debug("free full_len={} (data_ptr=0x{x})", .{alloc_prefix_len + len, @intFromPtr(self.data_ptr)});
        allocator.free(@as([*]u8, @ptrFromInt(base_addr))[0 .. alloc_prefix_len + len]);
    } else {
        arc.debug("unref full_len={} (data_ptr=0x{x}) new_count={}", .{
            alloc_prefix_len + len,
            @intFromPtr(self.data_ptr),
            old_count - 1,
        });
    }
}
