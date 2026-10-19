//! Display lists, what a frame paints, and their diff into damage.
//!
//! A frame paints into a Scene. The renderer compares it with the scene it
//! drew last: an op whose content, place and clip are unchanged hashes the
//! same and costs nothing, and only the bounds of ops that came, went or
//! changed are redrawn and presented. This is the retained part of an
//! immediate-mode toolkit: the view is rebuilt, the pixels are not.

const std = @import("std");
const geom = @import("geom.zig");
const text = @import("text.zig");
const raster = @import("raster.zig");
const Image = @import("image.zig").Image;
const Rect = geom.Rect;
const IRect = geom.IRect;
const Color = geom.Color;

pub const Op = struct {
    kind: enum(u8) { rect, text, stroke, image },
    weight: text.Weight = .regular,
    color: Color,
    border_color: Color = .transparent,
    rect: Rect, // logical; for text: x = pen origin, y = baseline, w = width
    radius: f32 = 0,
    border: f32 = 0,
    size: f32 = 0,
    str_off: u32 = 0,
    str_len: u32 = 0,
    clip: IRect,
    bounds: IRect, // device pixels, clipped
    hash: u64 = 0,
    /// layer is 1 + the index of the scroll layer the op is in, 0 for none.
    layer: u16 = 0,
    /// seg is a stroke's two segments, x0 y0 x1 y1 each, in fractions of
    /// rect (so they move with it); its width is border.
    seg: [2][4]f32 = .{ .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 } },
    /// image is an image op's; seg[0] the part of it shown, in texels.
    image: ?*Image = null,
};

/// Layer is a scrolled area: its ops hash where they are in its content,
/// not on screen, so that scrolling it changes none of them, and the
/// renderer moves its pixels instead of drawing them again (the scroll
/// layers of gpui-fast, on the CPU).
pub const Layer = struct {
    key: u64,
    clip: IRect,
    /// offset is how far the content is scrolled, in logical pixels.
    offset: f32,
};

pub const Scene = struct {
    gpa: std.mem.Allocator,
    ops: std.ArrayListUnmanaged(Op) = .empty,
    strings: std.ArrayListUnmanaged(u8) = .empty,
    scale: f32 = 1,
    clip_stack: std.ArrayListUnmanaged(IRect) = .empty,
    full: IRect = .{},
    background: Color = Color.white,
    layers: std.ArrayListUnmanaged(Layer) = .empty,
    layer_stack: std.ArrayListUnmanaged(u16) = .empty,

    pub fn deinit(s: *Scene) void {
        s.ops.deinit(s.gpa);
        s.strings.deinit(s.gpa);
        s.clip_stack.deinit(s.gpa);
        s.layers.deinit(s.gpa);
        s.layer_stack.deinit(s.gpa);
    }

    pub fn reset(s: *Scene, width: i32, height: i32, scale: f32, bg: Color) void {
        s.ops.clearRetainingCapacity();
        s.strings.clearRetainingCapacity();
        s.clip_stack.clearRetainingCapacity();
        s.layers.clearRetainingCapacity();
        s.layer_stack.clearRetainingCapacity();
        s.scale = scale;
        s.full = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
        s.background = bg;
    }

    pub fn clip(s: *const Scene) IRect {
        return if (s.clip_stack.items.len > 0) s.clip_stack.items[s.clip_stack.items.len - 1] else s.full;
    }

    pub fn pushClip(s: *Scene, r: Rect) void {
        const c = IRect.fromRect(r, s.scale).intersect(s.clip());
        s.clip_stack.append(s.gpa, c) catch {};
    }

    pub fn popClip(s: *Scene) void {
        _ = s.clip_stack.pop();
    }

    /// pushLayer starts a scroll layer clipped to r, its content scrolled
    /// by offset; key identifies it from frame to frame.
    pub fn pushLayer(s: *Scene, key: u64, r: Rect, offset: f32) void {
        s.pushClip(r);
        s.layers.append(s.gpa, .{ .key = key, .clip = s.clip(), .offset = offset }) catch return;
        s.layer_stack.append(s.gpa, @intCast(s.layers.items.len)) catch {};
    }

    pub fn popLayer(s: *Scene) void {
        _ = s.layer_stack.pop();
        s.popClip();
    }

    fn currentLayer(s: *const Scene) u16 {
        return if (s.layer_stack.items.len > 0) s.layer_stack.items[s.layer_stack.items.len - 1] else 0;
    }

    fn finish(s: *Scene, op: *Op, str: []const u8) void {
        op.layer = s.currentLayer();
        if (op.layer == 0) {
            op.hash = hashOp(op, str, 0, null);
        } else {
            const l = &s.layers.items[op.layer - 1];
            op.hash = hashOp(op, str, l.key, l.offset);
        }
        s.ops.append(s.gpa, op.*) catch {};
    }

    pub fn rect(s: *Scene, r: Rect, color: Color, radius: f32, border: f32, border_color: Color) void {
        if (color.a == 0 and (border == 0 or border_color.a == 0)) return;
        const c = s.clip();
        const b = IRect.fromRect(r, s.scale).intersect(c);
        if (b.isEmpty()) return;
        var op = Op{ .kind = .rect, .color = color, .rect = r, .radius = radius, .border = border, .border_color = border_color, .clip = c, .bounds = b };
        s.finish(&op, "");
    }

    /// shadow paints the soft shadow of a rounded rectangle r: its color
    /// fades out over blur on both sides of r's edge. Paint it under r.
    pub fn shadow(s: *Scene, r: Rect, radius: f32, blur: f32, color: Color) void {
        if (color.a == 0 or blur <= 0) return;
        const c = s.clip();
        const b = IRect.fromRect(.{ .x = r.x - blur, .y = r.y - blur, .w = r.w + 2 * blur, .h = r.h + 2 * blur }, s.scale).intersect(c);
        if (b.isEmpty()) return;
        var op = Op{ .kind = .rect, .color = color, .rect = r, .radius = radius, .size = blur, .clip = c, .bounds = b };
        s.finish(&op, "");
    }

    /// stroke paints up to two line segments with round caps, width wide,
    /// placed in r: icons (a check mark, chevrons, a cross) at any scale.
    /// Segments are x0, y0, x1, y1 in fractions of r.
    pub fn stroke(s: *Scene, r: Rect, seg: [2][4]f32, width: f32, color: Color) void {
        if (color.a == 0) return;
        const c = s.clip();
        const pad = width;
        const b = IRect.fromRect(.{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = r.h + 2 * pad }, s.scale).intersect(c);
        if (b.isEmpty()) return;
        var op = Op{ .kind = .stroke, .color = color, .rect = r, .border = width, .seg = seg, .clip = c, .bounds = b };
        s.finish(&op, "");
    }

    /// text paints str with its pen at x and its baseline at y.
    pub fn textRun(s: *Scene, fonts: *text.Fonts, x: f32, y: f32, str: []const u8, size: f32, weight: text.Weight, color: Color) void {
        if (str.len == 0 or color.a == 0) return;
        const m = fonts.metrics(weight, size);
        const w = fonts.measure(weight, size, str);
        const c = s.clip();
        const box = Rect{ .x = x - 2, .y = y - m.ascent - 2, .w = w + 4, .h = m.ascent + m.descent + 4 };
        const b = IRect.fromRect(box, s.scale).intersect(c);
        if (b.isEmpty()) return;
        const off: u32 = @intCast(s.strings.items.len);
        s.strings.appendSlice(s.gpa, str) catch return;
        var op = Op{ .kind = .text, .color = color, .rect = .{ .x = x, .y = y, .w = w }, .size = size, .weight = weight, .str_off = off, .str_len = @intCast(str.len), .clip = c, .bounds = b };
        s.finish(&op, str);
    }

    /// image paints the part src (x0 y0 x1 y1, in texels) of img into r, its
    /// corners rounded by radius, at opacity (0..255).
    pub fn image(s: *Scene, r: Rect, img: *Image, src: [4]f32, radius: f32, opacity: u8) void {
        if (opacity == 0 or r.w <= 0 or r.h <= 0) return;
        const c = s.clip();
        const b = IRect.fromRect(r, s.scale).intersect(c);
        if (b.isEmpty()) return;
        var op = Op{ .kind = .image, .color = .{ .r = 255, .g = 255, .b = 255, .a = opacity }, .rect = r, .radius = radius, .seg = .{ src, .{ 0, 0, 0, 0 } }, .image = img, .clip = c, .bounds = b };
        s.finish(&op, "");
    }

    pub fn string(s: *const Scene, op: *const Op) []const u8 {
        return s.strings.items[op.str_off..][0..op.str_len];
    }
};

fn hashOp(op: *const Op, str: []const u8, layer_key: u64, offset: ?f32) u64 {
    var h = std.hash.Wyhash.init(@intFromEnum(op.kind) ^ layer_key);
    h.update(std.mem.asBytes(&op.color));
    h.update(std.mem.asBytes(&op.border_color));
    var r = op.rect;
    if (offset) |o| r.y += o; // where it is in the layer's content
    h.update(std.mem.asBytes(&r));
    h.update(std.mem.asBytes(&op.radius));
    h.update(std.mem.asBytes(&op.border));
    h.update(std.mem.asBytes(&op.size));
    h.update(std.mem.asBytes(&op.weight));
    h.update(std.mem.asBytes(&op.clip));
    if (op.kind == .stroke or op.kind == .image) h.update(std.mem.asBytes(&op.seg));
    if (op.image) |img| h.update(std.mem.asBytes(&img.id));
    h.update(str);
    return h.final();
}

/// Renderer keeps the last scene drawn into a canvas and redraws only
/// what changed.
const max_damage = 32;

pub const Scroll = struct { clip: IRect, dy: i32 };

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    last: std.ArrayListUnmanaged(Op) = .empty,
    last_layers: std.ArrayListUnmanaged(Layer) = .empty,
    shifts: [16]i32 = @splat(0),
    /// scrolls are the layers whose pixels moved this frame: a window
    /// presenting the damage moves them on its side first.
    scrolls: std.ArrayListUnmanaged(Scroll) = .empty,
    /// retain_pixels keeps the whole canvas up to date. A window turns it
    /// off: it only ever presents what was drawn this frame, and the
    /// server moves scrolled pixels itself, so the canvas need not.
    retain_pixels: bool = true,
    /// raster draws the damage on the CPU. A GPU renderer turns it off and
    /// uses the damage only to know whether the frame changed at all.
    raster: bool = true,
    last_hashes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    cur_hashes: std.AutoHashMapUnmanaged(u64, void) = .empty,
    damage: std.ArrayListUnmanaged(IRect) = .empty,
    valid: bool = false,
    last_bg: Color = Color.white,
    stats: Stats = .{},

    pub const Stats = struct { frames: u64 = 0, pixels: u64 = 0, ops_drawn: u64 = 0 };

    pub fn deinit(r: *Renderer) void {
        r.last.deinit(r.gpa);
        r.last_layers.deinit(r.gpa);
        r.scrolls.deinit(r.gpa);
        r.last_hashes.deinit(r.gpa);
        r.cur_hashes.deinit(r.gpa);
        r.damage.deinit(r.gpa);
    }

    pub fn invalidate(r: *Renderer) void {
        r.valid = false;
    }

    /// render draws scene into canvas and returns the rectangles it changed.
    pub fn render(r: *Renderer, s: *const Scene, fonts: *text.Fonts, cv: *const raster.Canvas) []const IRect {
        r.damage.clearRetainingCapacity();
        r.scrolls.clearRetainingCapacity();
        r.stats.frames += 1;
        if (!r.valid or !r.last_bg.eql(s.background)) {
            r.addDamage(cv.bounds());
        } else {
            r.scrollLayers(s, cv);
            r.cur_hashes.clearRetainingCapacity();
            r.cur_hashes.ensureTotalCapacity(r.gpa, @intCast(s.ops.items.len)) catch {};
            for (s.ops.items) |*op| r.cur_hashes.putAssumeCapacity(op.hash, {});
            for (s.ops.items) |*op| if (!r.last_hashes.contains(op.hash)) r.addDamage(op.bounds);
            for (r.last.items) |*op| if (!r.cur_hashes.contains(op.hash)) r.addDamage(r.moved(op));
        }
        r.mergeDamage(cv.bounds());
        if (r.raster) for (r.damage.items) |d| r.drawArea(s, fonts, cv, d);
        // Keep this scene for the next diff.
        r.last.clearRetainingCapacity();
        r.last_layers.clearRetainingCapacity();
        r.last.appendSlice(r.gpa, s.ops.items) catch {
            r.valid = false;
            return r.damage.items;
        };
        r.last_layers.appendSlice(r.gpa, s.layers.items) catch {
            r.valid = false;
            return r.damage.items;
        };
        r.last_hashes.clearRetainingCapacity();
        r.last_hashes.ensureTotalCapacity(r.gpa, @intCast(s.ops.items.len)) catch {};
        for (s.ops.items) |*op| r.last_hashes.putAssumeCapacity(op.hash, {});
        r.valid = true;
        r.last_bg = s.background;
        return r.damage.items;
    }

    /// moved is where the pixels of an op of the last frame are now: moved
    /// with its layer when the layer's pixels were moved.
    fn moved(r: *const Renderer, op: *const Op) IRect {
        if (op.layer == 0) return op.bounds;
        const d = r.shifts[@min(op.layer - 1, r.shifts.len - 1)];
        if (d == 0) return op.bounds;
        const l = r.last_layers.items[op.layer - 1];
        var b = op.bounds;
        b.y0 -= d;
        b.y1 -= d;
        return b.intersect(l.clip);
    }

    /// scrollLayers moves the pixels of each layer scrolled since the last
    /// frame, and damages what that uncovers or carried along with them.
    fn scrollLayers(r: *Renderer, s: *const Scene, cv: *const raster.Canvas) void {
        @memset(&r.shifts, 0);
        for (r.last_layers.items, 0..) |old, li| {
            var cur: ?Layer = null;
            for (s.layers.items) |l| if (l.key == old.key) {
                cur = l;
                break;
            };
            const l = cur orelse continue;
            if (l.offset == old.offset) continue;
            const fd = (l.offset - old.offset) * s.scale;
            const d: i32 = @intFromFloat(@round(fd));
            const clip = l.clip.intersect(cv.bounds());
            const h = clip.y1 - clip.y0;
            if (!std.meta.eql(l.clip, old.clip) or @abs(fd - @as(f32, @floatFromInt(d))) > 0.001 or @abs(d) >= h or li >= r.shifts.len) {
                // Not a whole number of pixels, or too far: draw it again.
                r.addDamage(old.clip);
                r.addDamage(l.clip);
                continue;
            }
            r.shifts[li] = d;
            if (r.retain_pixels) shiftRows(cv, clip, d);
            r.scrolls.append(r.gpa, .{ .clip = clip, .dy = d }) catch {
                r.valid = false;
            };
            if (d > 0) {
                r.addDamage(.{ .x0 = clip.x0, .y0 = clip.y1 - d, .x1 = clip.x1, .y1 = clip.y1 });
            } else {
                r.addDamage(.{ .x0 = clip.x0, .y0 = clip.y0, .x1 = clip.x1, .y1 = clip.y0 - d });
            }
            // Ops outside the layer drawn over or under it moved too.
            for (r.last.items) |*op| {
                if (op.layer == li + 1 or !op.bounds.overlaps(clip)) continue;
                if (op.kind == .rect and op.radius == 0 and op.color.a == 255 and op.border == 0 and contains(op.bounds, clip)) continue;
                r.addDamage(op.bounds.intersect(clip));
                var b = op.bounds;
                b.y0 -= d;
                b.y1 -= d;
                r.addDamage(b.intersect(clip));
            }
        }
    }

    fn addDamage(r: *Renderer, d: IRect) void {
        if (d.isEmpty()) return;
        r.damage.append(r.gpa, d) catch {};
    }

    /// mergeDamage joins rectangles that overlap or whose union wastes
    /// little, so an area is never drawn twice and presents stay few.
    fn mergeDamage(r: *Renderer, full: IRect) void {
        var items = r.damage.items;
        var n = items.len;
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                var j = i + 1;
                while (j < n) {
                    const u = items[i].unite(items[j]);
                    if (items[i].overlaps(items[j]) or u.area() <= @divTrunc((items[i].area() + items[j].area()) * 3, 2)) {
                        items[i] = u;
                        items[j] = items[n - 1];
                        n -= 1;
                        changed = true;
                    } else j += 1;
                }
            }
        }
        // Too many: join the pairs whose union wastes least.
        while (n > max_damage) {
            var bi: usize = 0;
            var bj: usize = 1;
            var best: i64 = std.math.maxInt(i64);
            for (0..n) |i| for (i + 1..n) |j| {
                const waste = items[i].unite(items[j]).area() - items[i].area() - items[j].area();
                if (waste < best) {
                    best = waste;
                    bi = i;
                    bj = j;
                }
            };
            items[bi] = items[bi].unite(items[bj]);
            items[bj] = items[n - 1];
            n -= 1;
        }
        for (items[0..n]) |*d| d.* = d.intersect(full);
        r.damage.shrinkRetainingCapacity(n);
    }

    fn drawArea(r: *Renderer, s: *const Scene, fonts: *text.Fonts, cv: *const raster.Canvas, area: IRect) void {
        if (area.isEmpty()) return;
        r.stats.pixels += @intCast(area.area());
        cv.fill(area, s.background);
        for (s.ops.items) |*op| {
            if (!op.bounds.overlaps(area)) continue;
            r.stats.ops_drawn += 1;
            drawOp(s, fonts, cv, op, op.clip.intersect(area));
        }
    }
};

fn contains(outer: IRect, inner: IRect) bool {
    return outer.x0 <= inner.x0 and outer.y0 <= inner.y0 and outer.x1 >= inner.x1 and outer.y1 >= inner.y1;
}

/// shiftRows moves the pixels inside clip up by d rows (down when d < 0).
fn shiftRows(cv: *const raster.Canvas, clip: IRect, d: i32) void {
    const x0: usize = @intCast(clip.x0);
    const x1: usize = @intCast(clip.x1);
    if (d > 0) {
        var y = clip.y0;
        while (y < clip.y1 - d) : (y += 1) @memcpy(cv.row(y)[x0..x1], cv.row(y + d)[x0..x1]);
    } else {
        var y = clip.y1 - 1;
        while (y >= clip.y0 - d) : (y -= 1) @memcpy(cv.row(y)[x0..x1], cv.row(y + d)[x0..x1]);
    }
}

pub fn drawOp(s: *const Scene, fonts: *text.Fonts, cv: *const raster.Canvas, op: *const Op, clip: IRect) void {
    const k = s.scale;
    switch (op.kind) {
        .rect => {
            const x = op.rect.x * k;
            const y = op.rect.y * k;
            const w = op.rect.w * k;
            const h = op.rect.h * k;
            const rad = op.radius * k;
            if (op.size > 0) return cv.shadow(x, y, w, h, rad, op.size * k, op.color, clip);
            if (op.border > 0 and op.border_color.a > 0) {
                const bw = op.border * k;
                if (op.color.a == 255) {
                    cv.rrect(x, y, w, h, rad, op.border_color, clip);
                    cv.rrect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, @max(0, rad - bw), op.color, clip);
                } else {
                    cv.rrect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, @max(0, rad - bw), op.color, clip);
                    cv.ring(x, y, w, h, rad, bw, op.border_color, clip);
                }
            } else {
                cv.rrect(x, y, w, h, rad, op.color, clip);
            }
        },
        .image => raster.image(cv, op.image.?, .{
            .x = op.rect.x * k,
            .y = op.rect.y * k,
            .w = op.rect.w * k,
            .h = op.rect.h * k,
            .src = op.seg[0],
            .radius = op.radius * k,
            .opacity = op.color.a,
        }, clip),
        .stroke => {
            const r = op.rect;
            var segs: [2][4]f32 = undefined;
            for (op.seg, 0..) |sg, i| segs[i] = .{ (r.x + sg[0] * r.w) * k, (r.y + sg[1] * r.h) * k, (r.x + sg[2] * r.w) * k, (r.y + sg[3] * r.h) * k };
            cv.stroke(op.bounds.intersect(clip), segs, op.border * k, op.color);
        },
        .text => {
            const Ctx = struct {
                cv: *const raster.Canvas,
                fonts: *text.Fonts,
                color: Color,
                clip: IRect,
                fn glyph(c: @This(), gx: i32, gy: i32, gl: text.Glyph) void {
                    c.cv.mask(c.fonts.coverage.items[gl.off..][0 .. @as(usize, gl.w) * gl.h], gl.w, gl.h, gx, gy, c.color, c.clip);
                }
            };
            glyphs(s, fonts, op, Ctx{ .cv = cv, .fonts = fonts, .color = op.color, .clip = clip }, Ctx.glyph);
        },
    }
}

/// glyphs lays out the text of op, as every renderer draws it: each glyph
/// at a whole device pixel, rasterized at the quarter pixel of its pen.
pub fn glyphs(s: *const Scene, fonts: *text.Fonts, op: *const Op, ctx: anytype, comptime emit: fn (@TypeOf(ctx), i32, i32, text.Glyph) void) void {
    const k = s.scale;
    const px = op.size * k;
    const face = fonts.face(op.weight);
    const sc = face.scale(px);
    var pen = op.rect.x * k;
    const base: i32 = @intFromFloat(@round(op.rect.y * k));
    var prev: u32 = 0;
    var it = text.Utf8Iter{ .s = s.string(op) };
    while (it.next()) |cp| {
        const g = face.glyph(cp);
        if (prev != 0) pen += fonts.kern(op.weight, prev, g) * sc;
        prev = g;
        const fl = @floor(pen);
        const phase: u2 = @intFromFloat(@min(3, @floor((pen - fl) * 4)));
        if (fonts.glyphAt(op.weight, px, g, phase)) |gl| {
            if (gl.w > 0 and gl.h > 0) emit(ctx, @as(i32, @intFromFloat(fl)) + gl.x0, base + gl.y0, gl);
        }
        pen += face.advance(cp, g) * sc;
    }
}
