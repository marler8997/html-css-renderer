const c = @cImport({ @cInclude("schrift.h"); });

pub const Font = c.SFT_Font;

pub fn loadmem(mem: []const u8) ?*Font {
    return c.sft_loadmem(mem.ptr, mem.len);
}
pub fn free(font: *Font) void {
    c.sft_freefont(font);
}
