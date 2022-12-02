const std = @import("std");

pub const unmanaged = struct {
    pub fn finalize(comptime T: type, self: *std.ArrayListUnmanaged(T), allocator: std.mem.Allocator) void {
        const old_memory = self.allocatedSlice();
        if (allocator.resize(old_memory, self.items.len)) {
            self.capacity = self.items.len;
        }
    }
};
