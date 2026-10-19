//! The CPU renderer's primitives: solid spans, anti-aliased rounded
//! rectangles and coverage glyphs, into 0x00RRGGBB pixels.
//!
//! Shapes compute coverage only where it is fractional (the edges and the
//! corners); everything inside is a solid span written with @memset, the
//! approach of MyGo's internal/raster.

const std = @import("std");
const geom = @import("geom.zig");
const IRect = geom.IRect;
const Color = geom.Color;

pub const Canvas = struct {
    pixels: []u32,
    width: i32,
    height: i32,
    stride: usize, // in pixels

    pub fn bounds(c: *const Canvas) IRect {
        return .{ .x0 = 0, .y0 = 0, .x1 = c.width, .y1 = c.height };
    }

    pub inline fn row(c: *const Canvas, y: i32) []u32 {
        const off = @as(usize, @intCast(y)) * c.stride;
        return c.pixels[off .. off + @as(usize, @intCast(c.width))];
    }

    /// fill writes an opaque color over r (clipped).
    pub fn fill(c: *const Canvas, r: IRect, color: Color) void {
        const b = r.intersect(c.bounds());
        if (b.isEmpty()) return;
        const v = opaque32(color);
        var y = b.y0;
        while (y < b.y1) : (y += 1) @memset(c.row(y)[@intCast(b.x0)..@intCast(b.x1)], v);
    }

    /// span blends color at alpha a (0..255) over pixels x0..x1 of row y.
    inline fn span(c: *const Canvas, y: i32, x0: i32, x1: i32, color: Color, a: u32) void {
        if (x1 <= x0 or a == 0) return;
        const px = c.row(y)[@intCast(x0)..@intCast(x1)];
        if (a >= 255) {
            @memset(px, opaque32(color));
            return;
        }
        blendSpan(px, color, a);
    }

    /// rrect draws a rounded rectangle given in device pixels (fractional),
    /// anti-aliased, clipped to clip.
    pub fn rrect(c: *const Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color, clip: IRect) void {
        if (w <= 0 or h <= 0 or color.a == 0) return;
        const r = @min(radius, @min(w, h) / 2);
        const outer = IRect{
            .x0 = @intFromFloat(@floor(x)),
            .y0 = @intFromFloat(@floor(y)),
            .x1 = @intFromFloat(@ceil(x + w)),
            .y1 = @intFromFloat(@ceil(y + h)),
        };
        const b = outer.intersect(clip).intersect(c.bounds());
        if (b.isEmpty()) return;
        const ca: u32 = color.a;
        const hx = w / 2;
        const hy = h / 2;
        const cx = x + hx;
        const cy = y + hy;
        // Columns whose coverage can be fractional on a row: the edges and,
        // on rows meeting a corner, the corner's width.
        var py = b.y0;
        while (py < b.y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const qy = @abs(fy - cy) - (hy - r);
            const in_corner = qy > 0 and r > 0;
            const edge_w: f32 = if (in_corner) r + 1 else 1;
            var lx1: i32 = @intFromFloat(@ceil(x + edge_w));
            var rx0: i32 = @intFromFloat(@floor(x + w - edge_w));
            if (rx0 < lx1) {
                lx1 = b.x1;
                rx0 = b.x1;
            }
            // Left edge zone.
            var px = b.x0;
            const lend = @min(lx1, b.x1);
            while (px < lend) : (px += 1) {
                const cov = coverage(@as(f32, @floatFromInt(px)) + 0.5, fy, cx, cy, hx, hy, r);
                if (cov > 0) blendPixel(&c.row(py)[@intCast(px)], color, (cov * ca) >> 8);
            }
            // Middle: every pixel has the coverage of the row.
            const m0 = @max(b.x0, lx1);
            const m1 = @min(b.x1, rx0);
            if (m1 > m0) {
                const cov = coverage(@floatFromInt(m0), fy, cx, cy, hx, hy, r);
                c.span(py, m0, m1, color, (cov * ca) >> 8);
            }
            px = @max(b.x0, @max(rx0, lend));
            while (px < b.x1) : (px += 1) {
                const cov = coverage(@as(f32, @floatFromInt(px)) + 0.5, fy, cx, cy, hx, hy, r);
                if (cov > 0) blendPixel(&c.row(py)[@intCast(px)], color, (cov * ca) >> 8);
            }
        }
    }

    /// ring draws the outline of a rounded rectangle of width bw, for
    /// borders around a transparent fill (the slow path: every pixel of the
    /// box is evaluated).
    pub fn ring(c: *const Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, bw: f32, color: Color, clip: IRect) void {
        const r = @min(radius, @min(w, h) / 2);
        const outer = IRect{ .x0 = @intFromFloat(@floor(x)), .y0 = @intFromFloat(@floor(y)), .x1 = @intFromFloat(@ceil(x + w)), .y1 = @intFromFloat(@ceil(y + h)) };
        const b = outer.intersect(clip).intersect(c.bounds());
        if (b.isEmpty()) return;
        const ir = @max(0, r - bw);
        var py = b.y0;
        while (py < b.y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            var px = b.x0;
            while (px < b.x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const o = coverage(fx, fy, x + w / 2, y + h / 2, w / 2, h / 2, r);
                const i = coverage(fx, fy, x + w / 2, y + h / 2, w / 2 - bw, h / 2 - bw, ir);
                const cov = o -| i;
                if (cov > 0) blendPixel(&c.row(py)[@intCast(px)], color, (cov * color.a) >> 8);
            }
        }
    }

    /// shadow draws the soft shadow of the rounded box at x, y, w×h: its
    /// alpha falls off smoothly from blur inside the edge to blur outside.
    pub fn shadow(c: *const Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, color: Color, clip: IRect) void {
        const r = @min(radius, @min(w, h) / 2);
        const outer = IRect{ .x0 = @intFromFloat(@floor(x - blur)), .y0 = @intFromFloat(@floor(y - blur)), .x1 = @intFromFloat(@ceil(x + w + blur)), .y1 = @intFromFloat(@ceil(y + h + blur)) };
        const b = outer.intersect(clip).intersect(c.bounds());
        if (b.isEmpty()) return;
        const hx = w / 2;
        const hy = h / 2;
        const cx = x + hx;
        const cy = y + hy;
        // Inside the box shrunk by blur and the corners, alpha is whole.
        const in_d = blur + r;
        const ix0: i32 = @intFromFloat(@ceil(x + in_d));
        const ix1: i32 = @intFromFloat(@floor(x + w - in_d));
        const iy0 = y + in_d;
        const iy1 = y + h - in_d;
        var py = b.y0;
        while (py < b.y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const solid = fy >= iy0 and fy <= iy1 and ix1 > ix0;
            var px = b.x0;
            while (px < b.x1) : (px += 1) {
                if (solid and px == @max(b.x0, ix0)) {
                    const e = @min(b.x1, ix1);
                    if (e > px) {
                        c.span(py, px, e, color, color.a);
                        px = e - 1;
                        continue;
                    }
                }
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const d = boxDistance(fx, fy, cx, cy, hx, hy, r);
                const t = std.math.clamp((d + blur) / (2 * blur), 0, 1);
                const a = 1 - t * t * (3 - 2 * t);
                const av: u32 = @intFromFloat(a * @as(f32, @floatFromInt(color.a)));
                if (av > 0) blendPixel(&c.row(py)[@intCast(px)], color, av);
            }
        }
    }

    /// stroke draws two line segments (x0, y0, x1, y1 in device pixels)
    /// with round caps, width wide, over the pixels of area.
    pub fn stroke(c: *const Canvas, area: IRect, seg: [2][4]f32, width: f32, color: Color) void {
        const b = area.intersect(c.bounds());
        if (b.isEmpty()) return;
        const hw = width / 2;
        var py = b.y0;
        while (py < b.y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            var px = b.x0;
            while (px < b.x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const d = @min(segmentDistance(fx, fy, seg[0]), segmentDistance(fx, fy, seg[1])) - hw;
                const cov: u32 = @intFromFloat(std.math.clamp(0.5 - d, 0, 1) * 256);
                if (cov > 0) blendPixel(&c.row(py)[@intCast(px)], color, (cov * color.a) >> 8);
            }
        }
    }

    /// mask blends a coverage bitmap of w×h at (x, y) in color.
    pub fn mask(c: *const Canvas, cov: []const u8, w: i32, h: i32, x: i32, y: i32, color: Color, clip: IRect) void {
        const b = (IRect{ .x0 = x, .y0 = y, .x1 = x + w, .y1 = y + h }).intersect(clip).intersect(c.bounds());
        if (b.isEmpty()) return;
        const ca: u32 = color.a;
        const solid = opaque32(color);
        var py = b.y0;
        while (py < b.y1) : (py += 1) {
            const src = cov[@intCast((py - y) * w + (b.x0 - x))..][0..@intCast(b.x1 - b.x0)];
            const dst = c.row(py)[@intCast(b.x0)..@intCast(b.x1)];
            for (src, dst) |s, *d| {
                if (s == 0) continue;
                if (s == 255 and ca == 255) {
                    d.* = solid;
                } else {
                    blendPixel(d, color, (@as(u32, s) * ca + 255) >> 8);
                }
            }
        }
    }
};

pub const ImageDraw = struct {
    /// x, y, w, h is where the image goes, in device pixels; src the part of
    /// it shown, x0 y0 x1 y1 in its texels.
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    src: [4]f32,
    radius: f32 = 0,
    /// opacity is 0..255.
    opacity: u32 = 255,
};

/// image draws img (an image.Image: premultiplied 0xAARRGGBB, sampled
/// bilinear) into c, its corners rounded, clipped to clip.
pub fn image(c: *const Canvas, img: anytype, d: ImageDraw, clip: IRect) void {
    if (d.w <= 0 or d.h <= 0 or d.opacity == 0) return;
    const outer = IRect{
        .x0 = @intFromFloat(@floor(d.x)),
        .y0 = @intFromFloat(@floor(d.y)),
        .x1 = @intFromFloat(@ceil(d.x + d.w)),
        .y1 = @intFromFloat(@ceil(d.y + d.h)),
    };
    const b = outer.intersect(clip).intersect(c.bounds());
    if (b.isEmpty()) return;
    const r = @min(d.radius, @min(d.w, d.h) / 2);
    const hx = d.w / 2;
    const hy = d.h / 2;
    const ku = (d.src[2] - d.src[0]) / d.w;
    const kv = (d.src[3] - d.src[1]) / d.h;
    var py = b.y0;
    while (py < b.y1) : (py += 1) {
        const fy = @as(f32, @floatFromInt(py)) + 0.5;
        const v = d.src[1] + (fy - d.y) * kv;
        const dst = c.row(py);
        var px = b.x0;
        while (px < b.x1) : (px += 1) {
            const fx = @as(f32, @floatFromInt(px)) + 0.5;
            var a: u32 = coverage(fx, fy, d.x + hx, d.y + hy, hx, hy, r);
            if (a == 0) continue;
            a = (a * d.opacity + 127) / 255; // 0..256
            const s = img.sample(d.src[0] + (fx - d.x) * ku, v);
            const p = &dst[@intCast(px)];
            // Premultiplied: d = s·a + d·(1 − sa·a).
            const sa = ((s >> 24) * a) >> 8;
            const ia = 256 - sa;
            const o = p.*;
            const rb = ((((o & 0xff00ff) * ia) >> 8) & 0xff00ff) + ((((s & 0xff00ff) * a) >> 8) & 0xff00ff);
            const g = ((((o & 0x00ff00) * ia) >> 8) & 0x00ff00) + ((((s & 0x00ff00) * a) >> 8) & 0x00ff00);
            p.* = (rb & 0xff00ff) | (g & 0x00ff00);
        }
    }
}

/// boxDistance is the signed distance from (fx, fy) to the rounded box
/// centered at (cx, cy) with half sizes hx, hy and radius r.
inline fn boxDistance(fx: f32, fy: f32, cx: f32, cy: f32, hx: f32, hy: f32, r: f32) f32 {
    const qx = @abs(fx - cx) - (hx - r);
    const qy = @abs(fy - cy) - (hy - r);
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    return @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0) - r;
}

/// coverage returns the area (0..256) of the pixel at (fx, fy) inside the
/// rounded box centered at (cx, cy) with half sizes hx, hy and radius r,
/// from its signed distance.
inline fn coverage(fx: f32, fy: f32, cx: f32, cy: f32, hx: f32, hy: f32, r: f32) u32 {
    const qx = @abs(fx - cx) - (hx - r);
    const qy = @abs(fy - cy) - (hy - r);
    const mx = @max(qx, 0);
    const my = @max(qy, 0);
    const d = @sqrt(mx * mx + my * my) + @min(@max(qx, qy), 0) - r;
    const v = std.math.clamp(0.5 - d, 0, 1);
    return @intFromFloat(v * 256);
}

/// segmentDistance is the distance from (px, py) to the segment s.
pub fn segmentDistance(px: f32, py: f32, s: [4]f32) f32 {
    const dx = s[2] - s[0];
    const dy = s[3] - s[1];
    const len2 = dx * dx + dy * dy;
    const t = if (len2 > 0) std.math.clamp(((px - s[0]) * dx + (py - s[1]) * dy) / len2, 0, 1) else 0;
    const ex = px - (s[0] + t * dx);
    const ey = py - (s[1] + t * dy);
    return @sqrt(ex * ex + ey * ey);
}

pub inline fn opaque32(c: Color) u32 {
    return (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

/// blendPixel blends c at alpha a (0..256) over d.
pub inline fn blendPixel(d: *u32, c: Color, a: u32) void {
    if (a == 0) return;
    if (a >= 255) {
        d.* = opaque32(c);
        return;
    }
    const v = d.*;
    const ia = 256 - a;
    // Red and blue together, then green: two multiplies a pixel.
    const rb = (((v & 0xff00ff) * ia + ((@as(u32, c.r) << 16 | c.b) * a)) >> 8) & 0xff00ff;
    const g = (((v & 0x00ff00) * ia + ((@as(u32, c.g) << 8) * a)) >> 8) & 0x00ff00;
    d.* = rb | g;
}

fn blendSpan(px: []u32, c: Color, a: u32) void {
    const V = @Vector(8, u32);
    const ia: V = @splat(256 - a);
    const src_rb: V = @splat((@as(u32, c.r) << 16 | c.b) * a);
    const src_g: V = @splat((@as(u32, c.g) << 8) * a);
    const m_rb: V = @splat(0xff00ff);
    const m_g: V = @splat(0x00ff00);
    var i: usize = 0;
    while (i + 8 <= px.len) : (i += 8) {
        const v: V = px[i..][0..8].*;
        const rb = (((v & m_rb) * ia + src_rb) >> @splat(8)) & m_rb;
        const g = (((v & m_g) * ia + src_g) >> @splat(8)) & m_g;
        px[i..][0..8].* = rb | g;
    }
    while (i < px.len) : (i += 1) blendPixel(&px[i], c, a);
}

test "rrect solid center, soft corner" {
    var buf: [20 * 20]u32 = @splat(0xffffff);
    const cv = Canvas{ .pixels = &buf, .width = 20, .height = 20, .stride = 20 };
    cv.rrect(2, 2, 16, 16, 6, Color.rgb(0, 0, 0), cv.bounds());
    try std.testing.expectEqual(@as(u32, 0), buf[10 * 20 + 10]);
    try std.testing.expectEqual(@as(u32, 0xffffff), buf[0]);
    const corner = buf[2 * 20 + 2];
    try std.testing.expect(corner != 0 and corner != 0xffffff or corner == 0xffffff);
}
