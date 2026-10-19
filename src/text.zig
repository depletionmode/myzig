//! Fonts, text measurement and the glyph cache.
//!
//! Glyphs are rasterized once per (face, glyph, size, subpixel phase) into a
//! coverage cache that lives as long as the window; text widths are memoized
//! per (face, size, string), so a frame that shows the same labels as the
//! last one shapes nothing (the retained text measurement of gpui-fast).

const std = @import("std");
const sys = @import("sys.zig");
const env = @import("env.zig");

extern fn mz_font_init(data: [*]const u8, index: c_int) ?*anyopaque;
extern fn mz_scale_em(fi: *anyopaque, px: f32) f32;
extern fn mz_vmetrics(fi: *anyopaque, asc: *c_int, desc: *c_int, gap: *c_int) void;
extern fn mz_glyph_index(fi: *anyopaque, cp: c_int) c_int;
extern fn mz_hmetrics(fi: *anyopaque, g: c_int, adv: *c_int, lsb: *c_int) void;
extern fn mz_kern(fi: *anyopaque, g1: c_int, g2: c_int) c_int;
extern fn mz_glyph_box(fi: *anyopaque, g: c_int, s: f32, shift_x: f32, x0: *c_int, y0: *c_int, x1: *c_int, y1: *c_int) void;
extern fn mz_glyph_render(fi: *anyopaque, out: [*]u8, w: c_int, h: c_int, stride: c_int, s: f32, shift_x: f32, g: c_int) void;

pub const Weight = enum(u1) { regular, bold };

const os = @import("builtin").os.tag;
const windows = os == .windows;

// A path may name a face of a collection by its index: "fonts.ttc#1".
const regular_paths: []const []const u8 = if (windows) &.{
    "C:\\Windows\\Fonts\\segoeui.ttf",
    "C:\\Windows\\Fonts\\arial.ttf",
} else if (os == .macos) &.{
    "/System/Library/Fonts/HelveticaNeue.ttc#0",
    "/System/Library/Fonts/Helvetica.ttc#0",
    "/System/Library/Fonts/Supplemental/Arial.ttf",
    "/Library/Fonts/Arial.ttf",
} else &.{
    "/usr/share/fonts/opentype/inter/Inter-Regular.otf",
    "/usr/share/fonts/truetype/inter/Inter-Regular.ttf",
    "/usr/share/fonts/TTF/Inter-Regular.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/TTF/DejaVuSans.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSans.ttf",
};
const bold_paths: []const []const u8 = if (windows) &.{
    "C:\\Windows\\Fonts\\segoeuib.ttf",
    "C:\\Windows\\Fonts\\arialbd.ttf",
} else if (os == .macos) &.{
    "/System/Library/Fonts/HelveticaNeue.ttc#1",
    "/System/Library/Fonts/Helvetica.ttc#1",
    "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
    "/Library/Fonts/Arial Bold.ttf",
} else &.{
    "/usr/share/fonts/opentype/inter/Inter-Bold.otf",
    "/usr/share/fonts/truetype/inter/Inter-Bold.ttf",
    "/usr/share/fonts/TTF/Inter-Bold.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
};

pub const Face = struct {
    data: []const u8,
    info: *anyopaque,
    ascent: f32, // in font units
    descent: f32,
    gap: f32,
    /// ASCII glyph indices and advances, looked up once.
    ascii_glyph: [128]u16,
    ascii_adv: [128]i16,

    fn load(gpa: std.mem.Allocator, override: ?[]const u8, paths: []const []const u8) !Face {
        _ = gpa;
        var data: ?[]const u8 = null;
        var index: c_int = 0;
        errdefer if (data) |d| sys.unmapFile(d);
        if (override) |p| data = readFace(p, &index);
        for (paths) |p| {
            if (data != null) break;
            data = readFace(p, &index);
        }
        const d = data orelse return error.NoFont;
        const info = mz_font_init(d.ptr, index) orelse return error.BadFont;
        var a: c_int = 0;
        var de: c_int = 0;
        var g: c_int = 0;
        mz_vmetrics(info, &a, &de, &g);
        var f = Face{ .data = d, .info = info, .ascent = @floatFromInt(a), .descent = @floatFromInt(de), .gap = @floatFromInt(g), .ascii_glyph = undefined, .ascii_adv = undefined };
        for (0..128) |cp| {
            const gi = mz_glyph_index(info, @intCast(cp));
            var adv: c_int = 0;
            var lsb: c_int = 0;
            mz_hmetrics(info, gi, &adv, &lsb);
            f.ascii_glyph[cp] = @intCast(gi);
            f.ascii_adv[cp] = @intCast(adv);
        }
        return f;
    }

    /// readFace maps the font file spec names (a path, with #n for the
    /// nth face of a collection).
    fn readFace(spec: []const u8, index: *c_int) ?[]const u8 {
        var path = spec;
        index.* = 0;
        if (std.mem.lastIndexOfScalar(u8, spec, '#')) |i| {
            index.* = std.fmt.parseInt(c_int, spec[i + 1 ..], 10) catch 0;
            path = spec[0..i];
        }
        return sys.mapFile(path) catch null;
    }

    pub fn glyph(f: *const Face, cp: u21) u32 {
        if (cp < 128) return f.ascii_glyph[cp];
        return @intCast(mz_glyph_index(f.info, cp));
    }

    pub fn advance(f: *const Face, cp: u21, g: u32) f32 {
        if (cp < 128) return @floatFromInt(f.ascii_adv[cp]);
        var adv: c_int = 0;
        var lsb: c_int = 0;
        mz_hmetrics(f.info, @intCast(g), &adv, &lsb);
        return @floatFromInt(adv);
    }

    pub fn scale(f: *const Face, px: f32) f32 {
        return mz_scale_em(f.info, px);
    }
};

pub const Metrics = struct { ascent: f32, descent: f32, line_height: f32 };

pub const Glyph = struct {
    x0: i16,
    y0: i16,
    w: u16,
    h: u16,
    off: u32, // into Fonts.coverage
};

const GlyphKey = packed struct(u64) { glyph: u32, size_q: u16, phase: u2, weight: u1, _pad: u13 = 0 };

const MeasureKey = struct { hash: u64, size_q: u16, weight: u1 };

pub const Fonts = struct {
    gpa: std.mem.Allocator,
    faces: [2]Face,
    glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .empty,
    coverage: std.ArrayListUnmanaged(u8) = .empty,
    widths: std.AutoHashMapUnmanaged(MeasureKey, f32) = .empty,
    measure_hits: u64 = 0,
    measure_misses: u64 = 0,

    pub fn init(gpa: std.mem.Allocator) !Fonts {
        const reg = try Face.load(gpa, env.get("MYZIG_FONT"), regular_paths);
        const bold = Face.load(gpa, env.get("MYZIG_FONT_BOLD"), bold_paths) catch reg;
        return .{ .gpa = gpa, .faces = .{ reg, bold } };
    }

    pub fn deinit(f: *Fonts) void {
        const same = f.faces[0].info == f.faces[1].info;
        for (f.faces[0..if (same) 1 else 2]) |fc| {
            std.c.free(fc.info);
            sys.unmapFile(fc.data);
        }
        f.glyphs.deinit(f.gpa);
        f.coverage.deinit(f.gpa);
        f.widths.deinit(f.gpa);
    }

    pub fn face(f: *Fonts, w: Weight) *const Face {
        return &f.faces[@intFromEnum(w)];
    }

    pub fn metrics(f: *Fonts, w: Weight, px: f32) Metrics {
        const fc = f.face(w);
        const s = fc.scale(px);
        const asc = fc.ascent * s;
        const desc = -fc.descent * s;
        return .{ .ascent = asc, .descent = desc, .line_height = @ceil(asc + desc + fc.gap * s) };
    }

    /// measure returns the advance width of s at px (in the same units as px),
    /// memoized: labels that come back frame after frame cost a hash lookup.
    pub fn measure(f: *Fonts, w: Weight, px: f32, s: []const u8) f32 {
        const key = MeasureKey{ .hash = std.hash.Wyhash.hash(0, s), .size_q = quant(px), .weight = @intFromEnum(w) };
        if (f.widths.get(key)) |v| {
            f.measure_hits += 1;
            return v;
        }
        f.measure_misses += 1;
        const v = f.measureUncached(w, px, s);
        if (f.widths.count() > 1 << 16) f.widths.clearRetainingCapacity();
        f.widths.put(f.gpa, key, v) catch {};
        return v;
    }

    /// prefixWidth is the advance of s[0..end], not memoized: for carets,
    /// whose prefixes would crowd the memo out.
    pub fn prefixWidth(f: *Fonts, w: Weight, px: f32, s: []const u8, end: usize) f32 {
        return f.measureUncached(w, px, s[0..@min(end, s.len)]);
    }

    /// indexAt returns the byte offset in s of the caret position nearest
    /// x, a boundary between code points.
    pub fn indexAt(f: *Fonts, w: Weight, px: f32, s: []const u8, x: f32) usize {
        const fc = f.face(w);
        const sc = fc.scale(px);
        var pen: f32 = 0;
        var prev: u32 = 0;
        var it = Utf8Iter{ .s = s };
        var at: usize = 0;
        while (it.next()) |cp| {
            const g = fc.glyph(cp);
            if (prev != 0) pen += @as(f32, @floatFromInt(mz_kern(fc.info, @intCast(prev), @intCast(g)))) * sc;
            const adv = fc.advance(cp, g) * sc;
            if (x < pen + adv / 2) return at;
            pen += adv;
            prev = g;
            at = it.i;
        }
        return s.len;
    }

    fn measureUncached(f: *Fonts, w: Weight, px: f32, s: []const u8) f32 {
        const fc = f.face(w);
        const sc = fc.scale(px);
        var x: f32 = 0;
        var prev: u32 = 0;
        var it = Utf8Iter{ .s = s };
        while (it.next()) |cp| {
            const g = fc.glyph(cp);
            if (prev != 0) x += @as(f32, @floatFromInt(mz_kern(fc.info, @intCast(prev), @intCast(g)))) * sc;
            x += fc.advance(cp, g) * sc;
            prev = g;
        }
        return x;
    }

    /// glyphAt returns the cached coverage of glyph g at px, rasterized at
    /// the subpixel phase (quarter pixels) of its pen position.
    pub fn glyphAt(f: *Fonts, w: Weight, px: f32, g: u32, phase: u2) ?Glyph {
        const key = GlyphKey{ .glyph = g, .size_q = quant(px), .phase = phase, .weight = @intFromEnum(w) };
        if (f.glyphs.get(key)) |v| return v;
        const fc = f.face(w);
        const sc = fc.scale(px);
        const shift = @as(f32, @floatFromInt(phase)) * 0.25;
        var x0: c_int = 0;
        var y0: c_int = 0;
        var x1: c_int = 0;
        var y1: c_int = 0;
        mz_glyph_box(fc.info, @intCast(g), sc, shift, &x0, &y0, &x1, &y1);
        const gw: usize = @intCast(@max(0, x1 - x0));
        const gh: usize = @intCast(@max(0, y1 - y0));
        const off = f.coverage.items.len;
        if (gw > 0 and gh > 0) {
            f.coverage.appendNTimes(f.gpa, 0, gw * gh) catch return null;
            mz_glyph_render(fc.info, f.coverage.items[off..].ptr, @intCast(gw), @intCast(gh), @intCast(gw), sc, shift, @intCast(g));
        }
        const v = Glyph{ .x0 = @intCast(x0), .y0 = @intCast(y0), .w = @intCast(gw), .h = @intCast(gh), .off = @intCast(off) };
        f.glyphs.put(f.gpa, key, v) catch {};
        return v;
    }

    pub fn kern(f: *Fonts, w: Weight, a: u32, b: u32) f32 {
        const fc = f.face(w);
        return @floatFromInt(mz_kern(fc.info, @intCast(a), @intCast(b)));
    }

    fn quant(px: f32) u16 {
        return @intFromFloat(@round(px * 4));
    }
};

pub const Utf8Iter = struct {
    s: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8Iter) ?u21 {
        if (it.i >= it.s.len) return null;
        const c = it.s[it.i];
        if (c < 0x80) {
            it.i += 1;
            return c;
        }
        const n = std.unicode.utf8ByteSequenceLength(c) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + n > it.s.len) {
            it.i = it.s.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.s[it.i .. it.i + n]) catch 0xfffd;
        it.i += n;
        return cp;
    }
};
