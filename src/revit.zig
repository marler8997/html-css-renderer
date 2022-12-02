// PR to add this to std here: https://github.com/ziglang/zig/pull/13743
fn ReverseIterator(comptime T: type) type {
    const info: struct { Child: type, Pointer: type } = blk: {
        switch (@typeInfo(T)) {
            .Pointer => |info| switch (info.size) {
                .Slice => break :blk .{
                    .Child = info.child,
                    .Pointer = @Type(.{ .Pointer = .{
                        .size = .Many,
                        .is_const = info.is_const,
                        .is_volatile = info.is_volatile,
                        .alignment = info.alignment,
                        .address_space = info.address_space,
                        .child = info.child,
                        .is_allowzero = info.is_allowzero,
                        .sentinel = info.sentinel,
                    }}),
                },
                else => {},
            },
            else => {},
        }
        @compileError("reverse iterator expects slice, found " ++ @typeName(T));
    };
    return struct {
        ptr: info.Pointer,
        index: usize,
        pub fn next(self: *@This()) ?info.Child {
            if (self.index == 0) return null;
            self.index -= 1;
            return self.ptr[self.index];
        }
    };
}
pub fn reverseIterator(slice: anytype) ReverseIterator(@TypeOf(slice)) {
    return .{ .ptr = slice.ptr, .index = slice.len };
}
