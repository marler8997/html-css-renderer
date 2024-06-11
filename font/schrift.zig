const builtin = @import("builtin");
const std = @import("std");

pub const Float = f64;

pub const TtfInfo = struct {
    units_per_em: u16,
    loca_format: i16,
    num_long_hmtx: u16,
};

const Point = struct { x: Float, y: Float };
const Line = struct {
    beg: u16,
    end: u16,
};
const Curve = struct {
    beg: u16,
    end: u16,
    ctrl: u16,
};

const Outline = struct {
    points: std.ArrayListUnmanaged(Point) = .{},
    curves: std.ArrayListUnmanaged(Curve) = .{},
    lines: std.ArrayListUnmanaged(Line) = .{},
    // TODO: original C implementation used an initial size of 64,
    //       now the initial size will be 8.
    pub fn appendPoint(self: *Outline, allocator: std.mem.Allocator, p: Point) !void {
        try self.points.append(allocator, p);
    }
    pub fn appendCurve(self: *Outline, allocator: std.mem.Allocator, cv: Curve) !void {
        try self.curves.append(allocator, cv);
    }
    pub fn appendLine(self: *Outline, allocator: std.mem.Allocator, l: Line) !void {
        try self.lines.append(allocator, l);
    }
    pub fn deinit(self: *Outline, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.curves.deinit(allocator);
        self.lines.deinit(allocator);
    }
};

const Cell = struct {
    area: Float,
    cover: Float,
};
const Raster = struct {
    cells: []Cell,
    size: XY(i32),
};

const ttf = struct {
    pub const file_magic_one = 0x00010000;
    pub const file_magic_two = 0x74727565;

    pub const horizonal_kerning = 0x01;
    pub const minimum_kerning = 0x02;
    pub const cross_stream_kerning = 0x04;
    pub const override_kerning = 0x08;

    pub const point_is_on_curve = 0x01;
    pub const x_change_is_small = 0x02;
    pub const y_change_is_small = 0x04;
    pub const repeat_flag = 0x08;
    pub const x_change_is_zero = 0x10;
    pub const x_change_is_positive = 0x10;
    pub const y_change_is_zero = 0x20;
    pub const y_change_is_positive = 0x20;

    pub const offsets_are_large = 0x001;
    pub const actual_xy_offsets = 0x002;
    pub const got_a_single_scale = 0x008;
    pub const there_are_more_components = 0x020;
    pub const got_an_x_and_y_scale = 0x040;
    pub const got_a_scale_matrix = 0x080;
};

pub const LMetrics = struct {
    ascender: Float,
    descender: Float,
    line_gap: Float,
};
pub fn lmetrics(ttf_mem: []const u8, info: TtfInfo, y_scale: Float) !LMetrics {
    const hhea: usize = (try getTable(ttf_mem, "hhea")) orelse
        return error.TtfNoHheaTable;
    const hhea_limit = hhea + 10;
    if (hhea_limit > ttf_mem.len)
        return error.TtfBadHheaTable;
    const factor = y_scale / @as(Float, @floatFromInt(info.units_per_em));
    return LMetrics{
        .ascender = factor * @as(Float, @floatFromInt(std.mem.readInt(i16, ttf_mem[hhea + 4 ..][0..2], .big))),
        .descender = factor * @as(Float, @floatFromInt(std.mem.readInt(i16, ttf_mem[hhea + 6 ..][0..2], .big))),
        .line_gap = factor * @as(Float, @floatFromInt(std.mem.readInt(i16, ttf_mem[hhea + 8 ..][0..2], .big))),
    };
}

pub fn XY(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

// TODO: document these fields
pub const GMetrics = struct {
    advance_width: Float,
    left_side_bearing: Float,
    y_offset: i32,
    // TODO: should this and min_height be unsigned?
    min_width: i32,
    min_height: i32,
};
pub fn gmetrics(
    ttf_mem: []const u8,
    info: TtfInfo,
    downward: bool,
    scale: XY(Float),
    offset: XY(Float),
    glyph: u32,
) !GMetrics {
    const hor = try horMetrics(ttf_mem, info, glyph);
    const x_scale_em = scale.x / @as(Float, @floatFromInt(info.units_per_em));

    const advance_width = @as(Float, @floatFromInt(hor.advance_width)) * x_scale_em;
    const left_side_bearing = @as(Float, @floatFromInt(hor.left_side_bearing)) * x_scale_em + offset.x;

    const outline = (try getOutlineOffset(ttf_mem, info, glyph)) orelse return GMetrics{
        .advance_width = advance_width,
        .left_side_bearing = left_side_bearing,
        .min_width = 0,
        .min_height = 0,
        .y_offset = 0,
    };
    const bbox = try getGlyphBbox(ttf_mem, info, scale, offset, outline);
    //std.debug.assert(bbox.x_min < bbox.x_max);
    //std.debug.assert(bbox.y_min < bbox.y_max);
    const y_min: i32 = @intFromFloat(bbox.y_min);
    const y_max: i32 = @intFromFloat(bbox.y_max);
    return GMetrics{
        .advance_width = advance_width,
        .left_side_bearing = left_side_bearing,
        .min_width = @as(i32, @intFromFloat(bbox.x_max)) - @as(i32, @intFromFloat(bbox.x_min)) + 1,
        .min_height = y_max - y_min + 1,
        .y_offset = if (downward) -y_max else y_min,
    };
}

pub fn kerning(
    ttf_mem: []const u8,
    info: TtfInfo,
    scale: XY(Float),
    left_glyph: u32,
    right_glyph: u32,
) !XY(Float) {
    var x_shift: Float = 0;
    var y_shift: Float = 0;

    var offset = try getTable(ttf_mem, "kern") orelse {
        return .{ .x = 0, .y = 0 };
    };

    if (offset + 4 > ttf_mem.len)
        return error.TtfBadKerning;
    var num_tables = readTtf(u16, ttf_mem[offset + 2 ..]);
    offset += 4;

    while (num_tables > 0) : (num_tables -= 1) {
        if (offset + 6 > ttf_mem.len)
            return error.TtfBadKerning;

        const length = readTtf(u16, ttf_mem[offset + 2 ..]);
        const format = readTtf(u8, ttf_mem[offset + 4 ..]);
        const flags = readTtf(u8, ttf_mem[offset + 5 ..]);
        offset += 6;

        if (format == 0 and
            (flags & ttf.horizonal_kerning) != 0 and
            (flags & ttf.minimum_kerning) == 0)
        {
            if (offset + 8 > ttf_mem.len)
                return error.TtfBadKerning;

            const num_pairs = readTtf(u16, ttf_mem[offset..]);
            offset += 8;

            const key: [4]u8 = .{
                @intCast((left_glyph >> 8) & 0xFF),
                @intCast(left_glyph & 0xFF),
                @intCast((right_glyph >> 8) & 0xFF),
                @intCast(right_glyph & 0xFF),
            };

            if (bsearch(&key, ttf_mem.ptr + offset, num_pairs, 6, cmpu32)) |match| {
                const value = readTtf(
                    i16,
                    ttf_mem[@intFromPtr(match) - @intFromPtr(ttf_mem.ptr) + 4 ..],
                );
                if (flags & ttf.cross_stream_kerning != 0) {
                    y_shift += @as(Float, value);
                } else {
                    x_shift += @as(Float, value);
                }
            }
        }

        offset += length;
    }

    return .{
        .x = x_shift / @as(Float, info.units_per_em) * scale.x,
        .y = y_shift / @as(Float, info.units_per_em) * scale.y,
    };
}

pub fn render(
    allocator: std.mem.Allocator,
    ttf_mem: []const u8,
    info: TtfInfo,
    downward: bool,
    scale: XY(Float),
    offset: XY(Float),
    out_pixels: []u8,
    out_size: XY(i32),
    glyph: u32,
) !void {
    std.debug.assert(out_size.x >= 0);
    std.debug.assert(out_size.y >= 0);
    std.debug.assert(out_pixels.len == @as(usize, @intCast(out_size.x)) * @as(usize, @intCast(out_size.y)));

    const outline_offset = (try getOutlineOffset(ttf_mem, info, glyph)) orelse return;
    const bbox = try getGlyphBbox(ttf_mem, info, scale, offset, outline_offset);

    // Set up the transformation matrix such that
    // the transformed bounding boxes min corner lines
    // up with the (0, 0) point.
    var transform: [6]Float = undefined;
    transform[0] = scale.x / @as(Float, @floatFromInt(info.units_per_em));
    transform[1] = 0.0;
    transform[2] = 0.0;
    transform[4] = offset.x - bbox.x_min;
    if (downward) {
        transform[3] = -scale.y / @as(Float, @floatFromInt(info.units_per_em));
        transform[5] = bbox.y_max - offset.y;
    } else {
        transform[3] = scale.y / @as(Float, @floatFromInt(info.units_per_em));
        transform[5] = offset.y - bbox.y_min;
    }

    var outl = Outline{};
    defer outl.deinit(allocator);

    try decodeOutline(allocator, ttf_mem, info, outline_offset, 0, &outl);
    try renderOutline(allocator, &outl, &transform, out_pixels.ptr, out_size);
}

fn readTtf(comptime T: type, ttf_mem: []const u8) T {
    std.debug.assert(ttf_mem.len >= @sizeOf(T));
    return std.mem.readInt(T, ttf_mem[0..@sizeOf(T)], .big);
}

pub fn getTtfInfo(ttf_mem: []const u8) !TtfInfo {
    if (ttf_mem.len < 12) return error.TtfTooSmall;

    // Check for a compatible scaler_type (magic number).
    const scaler_type = readTtf(u32, ttf_mem);
    if (scaler_type != ttf.file_magic_one and scaler_type != ttf.file_magic_two)
        return error.TtfBadMagic;
    const head: usize = (try getTable(ttf_mem, "head")) orelse
        return error.TtfNoHeadTable;
    const head_limit = head + 52;
    if (head_limit > ttf_mem.len)
        return error.TtfBadHeadTable;
    const hhea: usize = (try getTable(ttf_mem, "hhea")) orelse
        return error.TtfNoHheaTable;
    const hhea_limit = hhea + 36;
    if (hhea_limit > ttf_mem.len)
        return error.TtfBadHheaTable;
    return TtfInfo{
        .units_per_em = readTtf(u16, ttf_mem[head + 18 ..]),
        .num_long_hmtx = readTtf(u16, ttf_mem[hhea + 34 ..]),
        .loca_format = readTtf(i16, ttf_mem[head + 50 ..]),
    };
}

fn midpoint(a: Point, b: Point) Point {
    return .{
        .x = 0.5 * (a.x + b.x),
        .y = 0.5 * (a.y + b.y),
    };
}

// Applies an affine linear transformation matrix to a set of points.
fn transformPoints(points: []Point, trf: *const [6]Float) void {
    for (points) |*pt_ref| {
        const pt = pt_ref.*;
        pt_ref.* = .{
            .x = pt.x * trf[0] + pt.y * trf[2] + trf[4],
            .y = pt.x * trf[1] + pt.y * trf[3] + trf[5],
        };
    }
}

extern "c" fn nextafter(x: Float, y: Float) Float;

fn clipPoints(points: []Point, width: Float, height: Float) void {
    for (points) |*pt| {
        if (pt.x < 0.0) {
            pt.x = 0.0;
        } else if (pt.x >= width) {
            if (builtin.link_libc) {
                pt.x = nextafter(width, 0.0);
            } else {
                // not sure if this will still work but zig
                // doesn't seem to have a 'nextafter' equivalent
                // but it's *probabl* ok?
                pt.x = width;
            }
        }
        if (pt.y < 0.0) {
            pt.y = 0.0;
        } else if (pt.y >= height) {
            if (builtin.link_libc) {
                pt.y = nextafter(height, 0.0);
            } else {
                // not sure if this will still work but zig
                // doesn't seem to have a 'nextafter' equivalent
                // but it's *probabl* ok?
                pt.y = height;
            }
        }
    }
}

fn bsearch(
    key: [*]const u8,
    base: [*]const u8,
    nmemb: usize,
    size: usize,
    compar: *const fn ([*]const u8, [*]const u8) i2,
) ?[*]const u8 {
    var next_base = base;
    var nel = nmemb;
    while (nel > 0) {
        const t = next_base + size * (nel / 2);
        const s = compar(key, t);
        if (s < 0) {
            nel /= 2;
        } else if (s > 0) {
            next_base = t + size;
            nel -= nel / 2 + 1;
        } else {
            return t;
        }
    }
    return null;
}

// Like bsearch(), but returns the next highest element if key could not be found.
fn csearch(
    key: [*]const u8,
    base: [*]const u8,
    nmemb: usize,
    size: usize,
    compar: *const fn ([*]const u8, [*]const u8) i2,
) ?[*]const u8 {
    if (nmemb == 0) return null;

    const bytes = base;
    var low: usize = 0;
    var high: usize = nmemb - 1;
    while (low != high) {
        const mid = low + (high - low) / 2;
        const sample = bytes + mid * size;
        if (compar(key, sample) > 0) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return bytes + low * size;
}

fn memcmp(l: [*]const u8, r: [*]const u8, len: usize) i2 {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (i == len) return 0;
        if (l[i] > r[i]) return 1;
        if (l[i] < r[i]) return -1;
    }
}

// Used as a comparison function for [bc]search().
fn cmpu16(a: [*]const u8, b: [*]const u8) i2 {
    return memcmp(a, b, 2);
}

// Used as a comparison function for [bc]search().
fn cmpu32(a: [*]const u8, b: [*]const u8) i2 {
    return memcmp(a, b, 4);
}

const GetTableError = error{ TtfBadTables };
fn getTable(ttf_mem: []const u8, tag: *const [4]u8) GetTableError!?u32 {
    // No need to bounds-check access to the first 12 bytes - this gets already checked by init_font().
    const num_tables = readTtf(u16, ttf_mem[4..]);
    const limit = 12 + @as(usize, num_tables) * 16;
    if (limit > ttf_mem.len)
        return error.TtfBadTables;
    const match_ptr = bsearch(tag, ttf_mem.ptr + 12, num_tables, 16, cmpu32) orelse return null;
    return readTtf(u32, match_ptr[8..12]);
}

fn cmapFmt4(ttf_mem: []const u8, table: usize, char_code: u32) !u32 {
    // cmap format 4 only supports the Unicode BMP.
    if (char_code > 0xFFFF)
        return 0;

    if (table + 8 > ttf_mem.len)
        return error.TtfBadCmapTable;
    const seg_count_x2 = readTtf(u16, ttf_mem[table..]);
    if (((seg_count_x2 & 1) != 0) or (0 == seg_count_x2))
        return error.TtfBadCmapTable;

    // Find starting positions of the relevant arrays.
    const end_codes = table + 8;
    const start_codes = end_codes + seg_count_x2 + 2;
    const id_deltas = start_codes + seg_count_x2;
    const id_range_offsets = id_deltas + seg_count_x2;
    if (id_range_offsets + seg_count_x2 > ttf_mem.len)
        return error.TtfBadCmapTable;

    // Find the segment that contains shortCode by binary searching over
    // the highest codes in the segments.
    const key = [2]u8{
        @intCast((char_code >> 8) & 0xff),
        @intCast((char_code >> 0) & 0xff),
    };
    const seg_addr = @intFromPtr(csearch(&key, ttf_mem.ptr + end_codes, seg_count_x2 / 2, 2, cmpu16));
    const seg_idx_x2 = seg_addr - (@intFromPtr(ttf_mem.ptr) + end_codes);
    // Look up segment info from the arrays & short circuit if the spec requires.
    const start_code = readTtf(u16, ttf_mem[start_codes + seg_idx_x2 ..]);
    if (start_code > char_code)
        return 0;
    const id_delta: u32 = readTtf(u16, ttf_mem[id_deltas + seg_idx_x2 ..]);
    const id_range_offset = readTtf(u16, ttf_mem[id_range_offsets + seg_idx_x2 ..]);
    if (id_range_offset == 0) {
        // Intentional integer under- and overflow.
        // TODO: not sure if this is correct?
        return (char_code + id_delta) & 0xFFFF;
    }
    // Calculate offset into glyph array and determine ultimate value.
    const id_offset = id_range_offsets + seg_idx_x2 + id_range_offset + 2 * (char_code - start_code);
    if (id_offset + 2 > ttf_mem.len)
        return error.TtfBadCmapTable;
    const id: u32 = readTtf(u16, ttf_mem[id_offset..]);
    // Intentional integer under- and overflow.
    return if (id == 0) 0 else ((id + id_delta) & 0xFFFF);
}

fn cmapFmt12_13(table: []const u8, char_code: u32, which: c_int) !u32 {
    if (table.len < 16)
        return error.TtfBadCmapTable;
    const num_entries: usize = @intCast(readTtf(u32, table[12..]));
    if (16 + 12 * num_entries > table.len)
        return error.TtfBadCmapTable;
    var i: usize = 0;
    while (i < num_entries) : (i += 1) {
        const entry = 16 + i * 12;
        const first_code = readTtf(u32, table[entry + 0 ..]);
        const last_code = readTtf(u32, table[entry + 4 ..]);
        if (char_code < first_code or char_code > last_code)
            continue;
        const glyph_offset = readTtf(u32, table[entry + 8 ..]);
        return if (which == 12) (char_code - first_code) + glyph_offset else glyph_offset;
    }
    return 0;
}

// Maps Unicode code points to glyph indices.
pub fn lookupGlyph(ttf_mem: []const u8, char_code: u32) !u32 {
    const cmap: usize = (try getTable(ttf_mem, "cmap")) orelse
        return error.TtfNoCmapTable;
    const cmap_limit = cmap + 4;
    if (cmap_limit > ttf_mem.len)
        return error.TtfBadCmapTable;
    const num_entries: usize = readTtf(u16, ttf_mem[cmap + 2 ..]);

    const entries_limit = 4 + num_entries * 8;
    if (entries_limit > ttf_mem.len)
        return error.TtfBadCmapTable;

    // First look for a 'full repertoire'/non-BMP map.
    {
        var idx: usize = 0;
        while (idx < num_entries) : (idx += 1) {
            const entry = cmap + 4 + idx * 8;
            const etype = readTtf(u16, ttf_mem[entry..]) * 0o100 + readTtf(u16, ttf_mem[entry + 2 ..]);
            // Complete unicode map
            if (etype == 0o004 or etype == 0o312) {
                const table = cmap + readTtf(u32, ttf_mem[entry + 4 ..]);
                if (table + 2 > ttf_mem.len)
                    return error.TtfBadCmapTable;
                switch (readTtf(u16, ttf_mem[table..])) {
                    12 => return cmapFmt12_13(ttf_mem[table..], char_code, 12),
                    else => return error.TtfUnsupportedCmapFormat,
                }
            }
        }
    }

    // If no 'full repertoire' cmap was found, try looking for a BMP map.
    {
        var idx: usize = 0;
        while (idx < num_entries) : (idx += 1) {
            const entry = cmap + 4 + idx * 8;
            const etype = readTtf(u16, ttf_mem[entry..]) * 0o100 + readTtf(u16, ttf_mem[entry + 2 ..]);
            // Unicode BMP
            if (etype == 0o003 or etype == 0o301) {
                const table = cmap + readTtf(u32, ttf_mem[entry + 4 ..]);
                if (table + 6 > ttf_mem.len)
                    return error.TtfBadCmapTable;
                // Dispatch based on cmap format.
                switch (readTtf(u16, ttf_mem[table..])) {
                    4 => return cmapFmt4(ttf_mem, table + 6, char_code),
                    //6 => return cmap_fmt6(font, table + 6, char_code, glyph),
                    6 => @panic("todo"),
                    else => return error.TtfUnsupportedCmapFormat,
                }
            }
        }
    }

    return error.UnsupportedCharCode; // I guess?
}

const HorMetrics = struct {
    advance_width: u16,
    left_side_bearing: i16,
};
fn horMetrics(ttf_mem: []const u8, info: TtfInfo, glyph: u32) !HorMetrics {
    const hmtx: usize = (try getTable(ttf_mem, "hmtx")) orelse
        return error.TtfNoHmtxTable;

    if (glyph < info.num_long_hmtx) {
        // glyph is inside long metrics segment.
        const offset = hmtx + 4 * glyph;
        if (offset + 4 > ttf_mem.len)
            return error.TtfBadHmtxTable;
        return .{
            .advance_width = readTtf(u16, ttf_mem[offset + 0 ..]),
            .left_side_bearing = readTtf(i16, ttf_mem[offset + 2 ..]),
        };
    }

    // glyph is inside short metrics segment.
    const boundary = hmtx + 4 * @as(usize, info.num_long_hmtx);
    if (boundary < 4)
        return error.TtfBadHmtxTable;

    const width_offset = boundary - 4;
    if (width_offset + 2 > ttf_mem.len)
        return error.TtfBadHmtxTable;
    const bearing_offset = boundary + 2 * @as(usize, glyph - info.num_long_hmtx);
    if (bearing_offset + 2 > ttf_mem.len)
        return error.TtfBadHmtxTable;
    return .{
        .advance_width = readTtf(u16, ttf_mem[width_offset..]),
        .left_side_bearing = readTtf(i16, ttf_mem[bearing_offset..]),
    };
}

const Bbox = struct {
    x_min: Float,
    x_max: Float,
    y_min: Float,
    y_max: Float,
};
fn getGlyphBbox(ttf_mem: []const u8, info: TtfInfo, scale: XY(Float), offset: XY(Float), outline: usize) !Bbox {
    if (outline + 10 > ttf_mem.len)
        return error.TtfBadOutline;
    const box = [4]i16{
        readTtf(i16, ttf_mem[outline + 2 ..]),
        readTtf(i16, ttf_mem[outline + 4 ..]),
        readTtf(i16, ttf_mem[outline + 6 ..]),
        readTtf(i16, ttf_mem[outline + 8 ..]),
    };
    if (box[2] <= box[0] or box[3] <= box[1])
        return error.TtfBadBbox;
    const x_scale_em = scale.x / @as(Float, @floatFromInt(info.units_per_em));
    const y_scale_em = scale.y / @as(Float, @floatFromInt(info.units_per_em));
    return Bbox{
        .x_min = @floor(@as(Float, @floatFromInt(box[0])) * x_scale_em + offset.x),
        .x_max = @ceil(@as(Float, @floatFromInt(box[2])) * x_scale_em + offset.x),
        .y_min = @floor(@as(Float, @floatFromInt(box[1])) * y_scale_em + offset.y),
        .y_max = @ceil(@as(Float, @floatFromInt(box[3])) * y_scale_em + offset.y),
    };
}

const GetOutlineOffsetError = GetTableError || error {
    TtfNoLocaTable,
    TtfBadLocaTable,
    TtfNoGlyfTable,
};
// Returns the offset into the font that the glyph's outline is stored at.
fn getOutlineOffset(ttf_mem: []const u8, info: TtfInfo, glyph: u32) GetOutlineOffsetError!?usize {
    const loca: usize = (try getTable(ttf_mem, "loca")) orelse
        return error.TtfNoLocaTable;
    const glyf: usize = (try getTable(ttf_mem, "glyf")) orelse
        return error.TtfNoGlyfTable;

    const entry = blk: {
        if (info.loca_format == 0) {
            const base = loca + 2 * glyph;
            if (base + 4 > ttf_mem.len)
                return error.TtfBadLocaTable;
            break :blk .{
                .this = 2 * @as(u32, readTtf(u16, ttf_mem[base + 0 ..])),
                .next = 2 * @as(u32, readTtf(u16, ttf_mem[base + 2 ..])),
            };
        }

        const base = loca + 4 * glyph;
        if (base + 8 > ttf_mem.len)
            return error.TtfBadLocaTable;
        break :blk .{
            .this = readTtf(u32, ttf_mem[base + 0 ..]),
            .next = readTtf(u32, ttf_mem[base + 4 ..]),
        };
    };
    return if (entry.this == entry.next) null else glyf + entry.this;
}

// For a 'simple' outline, determines each point of the outline with a set of flags.
fn simpleFlags(ttf_mem: []const u8, offset: usize, num_pts: u16, flags: []u8) !usize {
    var off = offset;
    var repeat: u8 = 0;
    var value: u8 = 0;
    var point_index: u16 = 0;
    while (point_index < num_pts) : (point_index += 1) {
        if (repeat != 0) {
            repeat -= 1;
        } else {
            if (off + 1 > ttf_mem.len)
                return error.TtfBadOutline;
            value = ttf_mem[off];
            off += 1;
            if ((value & ttf.repeat_flag) != 0) {
                if (off + 1 > ttf_mem.len)
                    return error.TtfBadOutline;
                repeat = ttf_mem[off];
                off += 1;
            }
        }
        flags[point_index] = value;
    }
    return off;
}

fn resolveSign(comptime T: type, is_pos: bool, value: T) T {
    const all_ones: T = @bitCast(switch (T) {
        i32 => @as(u32, 0xffffffff),
        else => @compileError("not implemented"),
    });
    const xor_mask = if (is_pos) all_ones else 0;
    return (value ^ xor_mask) + @as(T, @intFromBool(is_pos));
}

// For a 'simple' outline, decodes both X and Y coordinates for each point of the outline. */
fn simplePoints(
    ttf_mem: []const u8,
    offset: usize,
    num_pts: u16,
    flags: []const u8,
    points: []Point,
) !void {
    var off = offset;
    const Accum = i32;
    {
        var accum: Accum = 0;
        var i: u16 = 0;
        while (i < num_pts) : (i += 1) {
            if ((flags[i] & ttf.x_change_is_small) != 0) {
                if (off + 1 > ttf_mem.len)
                    return error.TtfBadOutline;
                const value = ttf_mem[off];
                off += 1;
                const is_pos = (flags[i] & ttf.x_change_is_positive) != 0;
                accum -= resolveSign(Accum, is_pos, value);
            } else if (0 == (flags[i] & ttf.x_change_is_zero)) {
                if (off + 2 > ttf_mem.len)
                    return error.TtfBadOutline;
                accum += readTtf(i16, ttf_mem[off..]);
                off += 2;
            }
            points[i].x = @as(Float, @floatFromInt(accum));
        }
    }

    {
        var accum: Accum = 0;
        var i: u16 = 0;
        while (i < num_pts) : (i += 1) {
            if ((flags[i] & ttf.y_change_is_small) != 0) {
                if (off + 1 > ttf_mem.len)
                    return error.TtfBadOutline;
                const value = ttf_mem[off];
                off += 1;
                const is_pos = (flags[i] & ttf.y_change_is_positive) != 0;
                accum -= resolveSign(Accum, is_pos, value);
            } else if (0 == (flags[i] & ttf.y_change_is_zero)) {
                if (off + 2 > ttf_mem.len)
                    return error.TtfBadOutline;
                accum += readTtf(i16, ttf_mem[off..]);
                off += 2;
            }
            points[i].y = @as(Float, @floatFromInt(accum));
        }
    }
}

fn add(comptime T: type, a: T, b: T) ?T {
    const ov = @addWithOverflow(a, b);
    if (ov[1] != 0) return null;
    return ov[0];
}

fn decodeContour(
    allocator: std.mem.Allocator,
    flags_start: []const u8,
    base_point_start: u16,
    count_start: u16,
    outl: *Outline,
) !void {
    // Skip contours with less than two points, since the following algorithm can't handle them and
    // they should appear invisible either way (because they don't have any area).
    if (count_start < 2) return;
    std.debug.assert(base_point_start <= std.math.maxInt(u16) - count_start);

    var flags = flags_start;
    var base_point = base_point_start;
    var count = count_start;
    const loose_end: u16 = blk: {
        if (0 != (flags[0] & ttf.point_is_on_curve)) {
            base_point += 1;
            flags = flags[1..];
            count -= 1;
            break :blk base_point - 1;
        }
        if (0 != (flags[count - 1] & ttf.point_is_on_curve)) {
            count -= 1;
            break :blk add(u16, base_point, count) orelse return error.TtfTooManyPoints;
        }

        const loose_end = std.math.cast(u16, outl.points.items.len) orelse return error.TtfTooManyPoints;
        const new_point = midpoint(outl.points.items[base_point], outl.points.items[base_point + count - 1]);
        try outl.appendPoint(allocator, new_point);
        break :blk loose_end;
    };
    var beg = loose_end;
    var opt_ctrl: ?u16 = null;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        // cur can't overflow because we ensure that base_point + count < 0xFFFF before calling decodeContour().
        const cur = add(u16, base_point, i) orelse return error.TtfTooManyPoints;
        if (0 != (flags[i] & ttf.point_is_on_curve)) {
            if (opt_ctrl) |ctrl| {
                try outl.appendCurve(allocator, .{ .beg = beg, .end = cur, .ctrl = ctrl });
            } else {
                try outl.appendLine(allocator, .{ .beg = beg, .end = cur });
            }
            beg = cur;
            opt_ctrl = null;
        } else {
            if (opt_ctrl) |ctrl| {
                const center = std.math.cast(u16, outl.points.items.len) orelse return error.TtfTooManyPoints;
                const new_point = midpoint(outl.points.items.ptr[ctrl], outl.points.items.ptr[cur]);
                try outl.appendPoint(allocator, new_point);
                try outl.appendCurve(allocator, .{ .beg = beg, .end = center, .ctrl = ctrl });
                beg = center;
            }
            opt_ctrl = cur;
        }
    }
    if (opt_ctrl) |ctrl| {
        try outl.appendCurve(allocator, .{ .beg = beg, .end = loose_end, .ctrl = ctrl });
    } else {
        try outl.appendLine(allocator, .{ .beg = beg, .end = loose_end });
    }
}

fn StackBuf(comptime T: type, comptime stack_len: usize) type {
    return struct {
        buf: [stack_len]T = undefined,
        fn alloc(self: *@This(), allocator: std.mem.Allocator, len: usize) error{OutOfMemory}![]T {
            if (len <= stack_len) return &self.buf;
            return try allocator.alloc(T, len);
        }
        fn free(allocator: std.mem.Allocator, buf: []T) void {
            if (buf.len <= stack_len) return;
            allocator.free(buf);
        }
    };
}
fn stackBuf(comptime T: type, comptime stack_len: usize) StackBuf(T, stack_len) {
    return .{};
}

const SimpleOutlineError = error {
    OutOfMemory,
    TtfTooManyPoints,
    TtfBadOutline,
};
fn simpleOutline(
    allocator: std.mem.Allocator,
    ttf_mem: []const u8,
    offset_start: usize,
    num_contours: u15,
    outl: *Outline,
) SimpleOutlineError!void {
    std.debug.assert(num_contours > 0);
    const base_point = std.math.cast(u16, outl.points.items.len) orelse return error.TtfTooManyPoints;

    const limit = offset_start + num_contours * 2 + 2;
    if (limit > ttf_mem.len)
        return error.TtfBadOutline;
    const num_pts = blk: {
        const num = readTtf(u16, ttf_mem[offset_start + (num_contours - 1) * 2 ..]);
        break :blk add(u16, num, 1) orelse return error.TtfBadOutline;
    };
    if (outl.points.items.len + @as(usize, num_pts) > std.math.maxInt(u16))
        return error.TtfBadOutline;
    const new_points_len = add(u16, base_point, num_pts) orelse return error.TtfTooManyPoints;
    try outl.points.ensureTotalCapacity(allocator, new_points_len);

    // TODO: the following commented line should work but the zig compiler
    //       isn't optimizing it correctly which causes *extreme* slowdown
    //var end_pts_stack_buf = stackBuf(u16, 16);
    const PtsBuf = StackBuf(u16, 16);
    var end_pts_stack_buf: PtsBuf = undefined;
    const end_pts = try end_pts_stack_buf.alloc(allocator, num_contours);
    defer PtsBuf.free(allocator, end_pts);

    // TODO: the following commented line should work but the zig compiler
    //       isn't optimizing it correctly which causes *extreme* slowdown
    //var flags_stack_buf = stackBuf(u8, 128);
    const FlagsBuf = StackBuf(u8, 128);
    var flags_stack_buf: FlagsBuf = undefined;
    const flags = try flags_stack_buf.alloc(allocator, num_pts);
    defer FlagsBuf.free(allocator, flags);

    var offset = offset_start;
    {
        var i: c_uint = 0;
        while (i < num_contours) : (i += 1) {
            end_pts[i] = readTtf(u16, ttf_mem[offset..]);
            offset += 2;
        }
    }

    // Ensure that end_pts are never falling.
    // Falling end_pts have no sensible interpretation and most likely only occur in malicious input.
    // Therefore, we bail, should we ever encounter such input.
    {
        var i: @TypeOf(num_contours) = 0;
        while (i < num_contours - 1) : (i += 1) {
            const prev_limit = add(u16, end_pts[i], 1) orelse return error.TtfBadOutline;
            if (end_pts[i + 1] < prev_limit)
                return error.TtfBadOutline;
        }
    }
    offset += 2 + @as(usize, readTtf(u16, ttf_mem[offset..]));

    offset = try simpleFlags(ttf_mem, offset, num_pts, flags);
    outl.points.items.len = new_points_len;
    try simplePoints(ttf_mem, offset, num_pts, flags, outl.points.items[base_point..]);

    var beg: u16 = 0;
    {
        var i: @TypeOf(num_contours) = 0;
        while (i < num_contours) : (i += 1) {
            const count = std.math.cast(u16, end_pts[i] - beg + 1) orelse return error.TtfBadOutline;
            try decodeContour(
                allocator,
                flags[beg..],
                add(u16, base_point, beg) orelse return error.TtfTooManyPoints,
                count,
                outl,
            );
            beg = end_pts[i] + 1;
        }
    }
}

const OutlineError = SimpleOutlineError || error {
    TtfOutlineTooRecursive,
    TtfPointMatchingNotSupported,
    TtfBadTables,
    TtfNoLocaTable,
    TtfBadLocaTable,
    TtfNoGlyfTable,
};
fn compoundOutline(
    allocator: std.mem.Allocator,
    ttf_mem: []const u8,
    info: TtfInfo,
    offset_start: usize,
    rec_depth: u8,
    outl: *Outline,
) OutlineError!void {
    // Guard against infinite recursion (compound glyphs that have themselves as component).
    if (rec_depth >= 4)
        return error.TtfOutlineTooRecursive;
    var offset = offset_start;
    while (true) {
        var local = [_]Float{0} ** 6;
        if (offset + 4 > ttf_mem.len)
            return error.TtfBadOutline;
        const flags = readTtf(u16, ttf_mem[offset + 0 ..]);
        const glyph = readTtf(u16, ttf_mem[offset + 2 ..]);
        offset += 4;
        // We don't implement point matching, and neither does stb_truetype for that matter.
        if (0 == (flags & ttf.actual_xy_offsets))
            return error.TtfPointMatchingNotSupported;
        // Read additional X and Y offsets (in FUnits) of this component.
        if (0 != (flags & ttf.offsets_are_large)) {
            if (offset + 4 > ttf_mem.len)
                return error.TtfBadOutline;
            local[4] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 0 ..])));
            local[5] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 2 ..])));
            offset += 4;
        } else {
            if (offset + 2 > ttf_mem.len)
                return error.TtfBadOutline;
            local[4] = @floatFromInt(@as(i8, @bitCast(ttf_mem[offset + 0])));
            local[5] = @floatFromInt(@as(i8, @bitCast(ttf_mem[offset + 1])));
            offset += 2;
        }
        if (0 != (flags & ttf.got_a_single_scale)) {
            if (offset + 2 > ttf_mem.len)
                return error.TtfBadOutline;
            local[0] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset..]))) / 16384.0;
            local[3] = local[0];
            offset += 2;
        } else if (0 != (flags & ttf.got_an_x_and_y_scale)) {
            if (offset + 4 > ttf_mem.len)
                return error.TtfBadOutline;
            local[0] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 0 ..]))) / 16384.0;
            local[3] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 2 ..]))) / 16384.0;
            offset += 4;
        } else if (0 != (flags & ttf.got_a_scale_matrix)) {
            if (offset + 8 > ttf_mem.len)
                return error.TtfBadOutline;
            local[0] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 0 ..]))) / 16384.0;
            local[1] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 2 ..]))) / 16384.0;
            local[2] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 4 ..]))) / 16384.0;
            local[3] = @as(Float, @floatFromInt(readTtf(i16, ttf_mem[offset + 6 ..]))) / 16384.0;
            offset += 8;
        } else {
            local[0] = 1.0;
            local[3] = 1.0;
        }
        // At this point, Apple's spec more or less tells you to scale the matrix by its own L1 norm.
        // But stb_truetype scales by the L2 norm. And FreeType2 doesn't scale at all.
        // Furthermore, Microsoft's spec doesn't even mention anything like this.
        // It's almost as if nobody ever uses this feature anyway.
        if (try getOutlineOffset(ttf_mem, info, glyph)) |outline| {
            const base_point = outl.points.items.len;
            try decodeOutline(allocator, ttf_mem, info, outline, rec_depth + 1, outl);
            transformPoints(outl.points.items.ptr[base_point..outl.points.items.len], &local);
        }

        if (0 == (flags & ttf.there_are_more_components)) break;
    }
}

fn decodeOutline(
    allocator: std.mem.Allocator,
    ttf_mem: []const u8,
    info: TtfInfo,
    offset: usize,
    rec_depth: u8,
    outl: *Outline,
) OutlineError!void {
    if (offset + 10 > ttf_mem.len)
        return error.TtfBadOutline;
    const num_contours = readTtf(i16, ttf_mem[offset..]);
    if (num_contours > 0) {
        // Glyph has a 'simple' outline consisting of a number of contours.
        return simpleOutline(allocator, ttf_mem, offset + 10, @intCast(num_contours), outl);
    } else if (num_contours < 0) {
        // Glyph has a compound outline combined from mutiple other outlines.
        return compoundOutline(allocator, ttf_mem, info, offset + 10, rec_depth, outl);
    }
}

// A heuristic to tell whether a given curve can be approximated closely enough by a line.
fn isFlat(outline: Outline, curve: Curve) bool {
    const max_area2: Float = 2.0;
    const a = outline.points.items.ptr[curve.beg];
    const b = outline.points.items.ptr[curve.ctrl];
    const cpoint = outline.points.items.ptr[curve.end];
    const g = Point{ .x = b.x - a.x, .y = b.y - a.y };
    const h = Point{ .x = cpoint.x - a.x, .y = cpoint.y - a.y };
    const area2 = @abs(g.x * h.y - h.x * g.y);
    return area2 <= max_area2;
}

fn tesselateCurve(allocator: std.mem.Allocator, curve_in: Curve, outline: *Outline) !void {
    // From my tests I can conclude that this stack barely reaches a top height
    // of 4 elements even for the largest font sizes I'm willing to support. And
    // as space requirements should only grow logarithmically, I think 10 is
    // more than enough.
    const STACK_SIZE = 10;
    var stack: [STACK_SIZE]Curve = undefined;
    var top: usize = 0;
    var curve = curve_in;
    while (true) {
        if (isFlat(outline.*, curve) or top >= STACK_SIZE) {
            try outline.appendLine(allocator, .{ .beg = curve.beg, .end = curve.end });
            if (top == 0) break;
            top -= 1;
            curve = stack[top];
        } else {
            const ctrl0 = std.math.cast(u16, outline.points.items.len) orelse return error.TtfTooManyPoints;
            {
                const new_point = midpoint(outline.points.items.ptr[curve.beg], outline.points.items.ptr[curve.ctrl]);
                try outline.appendPoint(allocator, new_point);
            }
            const ctrl1 = std.math.cast(u16, outline.points.items.len) orelse return error.TtfTooManyPoints;
            {
                const new_point = midpoint(outline.points.items.ptr[curve.ctrl], outline.points.items.ptr[curve.end]);
                try outline.appendPoint(allocator, new_point);
            }
            const pivot = std.math.cast(u16, outline.points.items.len) orelse return error.TtfTooManyPoints;
            {
                const new_point = midpoint(outline.points.items.ptr[ctrl0], outline.points.items.ptr[ctrl1]);
                try outline.appendPoint(allocator, new_point);
            }
            stack[top] = .{ .beg = curve.beg, .end = pivot, .ctrl = ctrl0 };
            top += 1;
            curve = .{ .beg = pivot, .end = curve.end, .ctrl = ctrl1 };
        }
    }
}

fn sign(x: Float) i2 {
    if (x > 0) return 1;
    if (x < 0) return -1;
    return 0;
}
fn fastFloor(x: Float) c_int {
    return @intFromFloat(std.math.floor(x));
}
fn fastCeil(x: Float) c_int {
    return @intFromFloat(std.math.ceil(x));
}

// Draws a line into the buffer. Uses a custom 2D raycasting algorithm to do so.
fn drawLine(buf: Raster, origin: Point, goal: Point) void {
    const delta = Point{
        .x = goal.x - origin.x,
        .y = goal.y - origin.y,
    };
    const dir = struct { x: i2, y: i2 }{
        .x = sign(delta.x),
        .y = sign(delta.y),
    };

    if (dir.y == 0) {
        return;
    }
    const crossingIncr = Point{
        .x = if (dir.x != 0) @abs(1.0 / delta.x) else 1.0,
        .y = @abs(1.0 / delta.y),
    };

    var pixel: struct { x: i32, y: i32 } = undefined;
    var next_crossing: Point = undefined;
    var num_steps: c_int = 0;
    if (dir.x == 0) {
        pixel.x = fastFloor(origin.x);
        next_crossing.x = 100.0;
    } else {
        if (dir.x > 0) {
            pixel.x = fastFloor(origin.x);
            next_crossing.x = (origin.x - @as(Float, @floatFromInt(pixel.x))) * crossingIncr.x;
            next_crossing.x = crossingIncr.x - next_crossing.x;
            num_steps += fastCeil(goal.x) - fastFloor(origin.x) - 1;
        } else {
            pixel.x = fastCeil(origin.x) - 1;
            next_crossing.x = (origin.x - @as(Float, @floatFromInt(pixel.x))) * crossingIncr.x;
            num_steps += fastCeil(origin.x) - fastFloor(goal.x) - 1;
        }
    }

    if (dir.y > 0) {
        pixel.y = fastFloor(origin.y);
        next_crossing.y = (origin.y - @as(Float, @floatFromInt(pixel.y))) * crossingIncr.y;
        next_crossing.y = crossingIncr.y - next_crossing.y;
        num_steps += fastCeil(goal.y) - fastFloor(origin.y) - 1;
    } else {
        pixel.y = fastCeil(origin.y) - 1;
        next_crossing.y = (origin.y - @as(Float, @floatFromInt(pixel.y))) * crossingIncr.y;
        num_steps += fastCeil(origin.y) - fastFloor(goal.y) - 1;
    }

    var next_distance = @min(next_crossing.x, next_crossing.y);
    const half_delta_x = 0.5 * delta.x;
    var prev_distance: Float = 0.0;
    var step: c_int = 0;
    while (step < num_steps) : (step += 1) {
        var x_average = origin.x + (prev_distance + next_distance) * half_delta_x;
        const y_difference = (next_distance - prev_distance) * delta.y;
        const cptr = &buf.cells[@intCast(pixel.y * buf.size.x + pixel.x)];
        var cell = cptr.*;
        cell.cover += y_difference;
        x_average -= @as(Float, @floatFromInt(pixel.x));
        cell.area += (1.0 - x_average) * y_difference;
        cptr.* = cell;
        prev_distance = next_distance;
        const along_x = next_crossing.x < next_crossing.y;
        pixel.x += if (along_x) dir.x else 0;
        pixel.y += if (along_x) 0 else dir.y;
        next_crossing.x += if (along_x) crossingIncr.x else 0.0;
        next_crossing.y += if (along_x) 0.0 else crossingIncr.y;
        next_distance = @min(next_crossing.x, next_crossing.y);
    }

    var x_average = origin.x + (prev_distance + 1.0) * half_delta_x;
    const y_difference = (1.0 - prev_distance) * delta.y;
    const cptr = &buf.cells[@intCast(pixel.y * buf.size.x + pixel.x)];
    var cell = cptr.*;
    cell.cover += y_difference;
    x_average -= @as(Float, @floatFromInt(pixel.x));
    cell.area += (1.0 - x_average) * y_difference;
    cptr.* = cell;
}

fn drawLines(outline: *Outline, buf: Raster) void {
    var i: usize = 0;
    while (i < outline.lines.items.len) : (i += 1) {
        const line = outline.lines.items.ptr[i];
        const origin = outline.points.items.ptr[line.beg];
        const goal = outline.points.items.ptr[line.end];
        drawLine(buf, origin, goal);
    }
}

// Integrate the values in the buffer to arrive at the final grayscale image.
fn postProcess(buf: Raster, image: [*]u8) void {
    var accum: Float = 0;
    const num = @as(usize, @intCast(buf.size.x)) * @as(usize, @intCast(buf.size.y));
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const cell = buf.cells[i];
        var value = @abs(accum + cell.area);
        value = @min(value, 1.0);
        value = value * 255.0 + 0.5;
        image[i] = @intFromFloat(value);
        accum += cell.cover;
    }
}

fn renderOutline(
    allocator: std.mem.Allocator,
    outl: *Outline,
    transform: *const [6]Float,
    pixels: [*]u8,
    size: XY(i32),
) !void {
    transformPoints(outl.points.items.ptr[0..outl.points.items.len], transform);
    clipPoints(
        outl.points.items.ptr[0..outl.points.items.len],
        @as(Float, @floatFromInt(size.x)),
        @as(Float, @floatFromInt(size.y)),
    );

    {
        var i: usize = 0;
        while (i < outl.curves.items.len) : (i += 1) {
            try tesselateCurve(allocator, outl.curves.items.ptr[i], outl);
        }
    }

    const num_pixels = @as(usize, @intCast(size.x)) * @as(usize, @intCast(size.y));
    // TODO: the following commented line should work but the zig compiler
    //       isn't optimizing it correctly which causes *extreme* slowdown
    // Zig's 'undefined' debug checks make this ungodly slow
    const stack_len = if (builtin.mode == .Debug) 0 else 128 * 128;
    //var cellStackBuf = stackBuf(Cell, stack_len);
    const CellBuf = StackBuf(Cell, stack_len);
    var cell_stack_buf: CellBuf = undefined;
    const cells = try cell_stack_buf.alloc(allocator, num_pixels);
    defer CellBuf.free(allocator, cells);

    // TODO: I wonder if this could be removed?
    @memset(@as([*]u8, @ptrCast(cells))[0 .. num_pixels * @sizeOf(@TypeOf(cells[0]))], 0);
    const buf = Raster{
        .cells = cells,
        .size = size,
    };
    drawLines(outl, buf);
    postProcess(buf, pixels);
}
