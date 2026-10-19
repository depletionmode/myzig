//! The Metal renderer, macOS's GPU API: instances.zig's scene as one
//! instanced draw, its shader in Metal's language (compiled when the
//! renderer starts, so building needs no Metal toolchain). It draws to a
//! window's CAMetalLayer, or to a texture of its own when there is no
//! window (tests, and frames read back).
//!
//! Three frames may be in flight: each has its instance buffer, reused
//! once the command buffer that last read it completed. Glyphs go into an
//! R8 atlas the CPU writes straight into; the atlas only grows into
//! texels no frame in flight samples, and a grown atlas is a new texture.

const std = @import("std");
const sys = @import("../sys.zig");
const objc = @import("../mac/objc.zig");
const scene = @import("../scene.zig");
const text = @import("../text.zig");
const inst = @import("instances.zig");
const env = @import("../env.zig");

const Id = objc.Id;
const send = objc.send;
const msg = objc.msg;
const UInt = objc.NSUInteger;

const MTLOrigin = extern struct { x: UInt = 0, y: UInt = 0, z: UInt = 0 };
const MTLSize = extern struct { width: UInt, height: UInt, depth: UInt = 1 };
const MTLRegion = extern struct { origin: MTLOrigin, size: MTLSize };
const MTLClearColor = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };

const pixel_bgra8 = 80; // MTLPixelFormatBGRA8Unorm
const pixel_r8 = 10; // MTLPixelFormatR8Unorm
const storage_shared: UInt = 0; // MTLResourceStorageModeShared
const frames_in_flight = 3;

pub const msl =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct Instance { float4 rect; float4 clip; float4 color; float4 border_color; float4 params; float4 uv; };
    \\struct VOut {
    \\    float4 position [[position]];
    \\    float2 pos;
    \\    float2 uv;
    \\    float4 rect [[flat]];
    \\    float4 clip [[flat]];
    \\    float4 color [[flat]];
    \\    float4 border_color [[flat]];
    \\    float4 params [[flat]];
    \\    float4 seg [[flat]];
    \\};
    \\vertex VOut box_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                       const device Instance* insts [[buffer(0)]],
    \\                       constant float2& viewport [[buffer(1)]]) {
    \\    Instance a = insts[iid];
    \\    float2 corner = float2(float(vid & 1), float((vid >> 1) & 1));
    \\    float2 p = a.rect.xy + corner * a.rect.zw;
    \\    VOut o;
    \\    o.pos = p;
    \\    o.uv = mix(a.uv.xy, a.uv.zw, corner);
    \\    o.rect = a.rect;
    \\    o.clip = a.clip;
    \\    o.color = a.color;
    \\    o.border_color = a.border_color;
    \\    o.params = a.params;
    \\    o.seg = a.uv;
    \\    float2 ndc = p / viewport * 2.0 - 1.0;
    \\    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    \\    return o;
    \\}
    \\static float box(float2 p, float2 c, float2 h, float r) {
    \\    float2 q = abs(p - c) - (h - r);
    \\    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    \\}
    \\static float segment(float2 p, float4 rect, float4 s) {
    \\    float2 a = rect.xy + s.xy * rect.zw;
    \\    float2 d = rect.xy + s.zw * rect.zw - a;
    \\    float l2 = dot(d, d);
    \\    float t = l2 > 0.0 ? clamp(dot(p - a, d) / l2, 0.0, 1.0) : 0.0;
    \\    return length(p - a - t * d);
    \\}
    \\fragment float4 box_fragment(VOut v [[stage_in]], texture2d<float> atlas [[texture(0)]], texture2d<float> images [[texture(1)]]) {
    \\    constexpr sampler smp(filter::nearest, address::clamp_to_edge);
    \\    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    \\    if (v.pos.x < v.clip.x || v.pos.y < v.clip.y || v.pos.x >= v.clip.z || v.pos.y >= v.clip.w) discard_fragment();
    \\    float4 fill = float4(v.color.rgb * v.color.a, v.color.a);
    \\    if (v.params.z > 3.5) {
    \\        float2 half_texel = 0.5 / float2(images.get_width(), images.get_height());
    \\        float2 uv = clamp(v.uv, min(v.seg.xy, v.seg.zw) + half_texel, max(v.seg.xy, v.seg.zw) - half_texel);
    \\        float2 h = v.rect.zw * 0.5;
    \\        float cover = clamp(0.5 - box(v.pos, v.rect.xy + h, h, v.params.x), 0.0, 1.0);
    \\        return images.sample(linear, uv) * (v.color.a * cover);
    \\    }
    \\    if (v.params.z > 2.5) {
    \\        float2 h = v.seg.zw * 0.5;
    \\        float d = box(v.pos, v.seg.xy + h, h, v.params.x);
    \\        return fill * (1.0 - smoothstep(-v.params.w, v.params.w, d));
    \\    }
    \\    if (v.params.z > 1.5) {
    \\        float d = min(segment(v.pos, v.rect, v.seg), segment(v.pos, v.rect, v.border_color)) - v.params.y * 0.5;
    \\        return fill * clamp(0.5 - d, 0.0, 1.0);
    \\    }
    \\    if (v.params.z > 0.5) return fill * atlas.sample(smp, v.uv).r;
    \\    float2 h = v.rect.zw * 0.5;
    \\    float2 ctr = v.rect.xy + h;
    \\    float r = v.params.x;
    \\    float bw = v.params.y;
    \\    float outer = clamp(0.5 - box(v.pos, ctr, h, r), 0.0, 1.0);
    \\    if (bw > 0.0) {
    \\        float4 border = float4(v.border_color.rgb * v.border_color.a, v.border_color.a);
    \\        float inner = clamp(0.5 - box(v.pos, ctr, h - bw, max(r - bw, 0.0)), 0.0, 1.0);
    \\        return mix(border, fill, inner) * outer;
    \\    }
    \\    return fill * outer;
    \\}
;

pub const Options = struct {
    /// vsync presents in step with the display.
    vsync: bool = true,
};

const Frame = struct {
    buffer: Id = null,
    size: usize = 0,
    /// cmd is the command buffer that last read buffer, retained.
    cmd: Id = null,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    pipeline: Id,
    /// layer is the CAMetalLayer drawn to; null draws offscreen.
    layer: Id,
    atlas: inst.Atlas,
    atlas_tex: Id = null,
    atlas_size: u32 = 0,
    images: inst.ImageAtlas,
    images_tex: Id = null,
    /// images_size is the image texture's side: 1 until an image is drawn.
    images_size: u32 = 0,
    instances: std.ArrayListUnmanaged(inst.Instance) = .empty,
    frames: [frames_in_flight]Frame = @splat(.{}),
    frame: usize = 0,
    /// offscreen is the texture drawn to without a layer.
    offscreen: Id = null,
    extent: [2]u32 = .{ 0, 0 },
    /// capture copies each frame into readback, for read().
    capture: bool = false,
    readable: bool = false,
    readback: Id = null,
    readback_size: usize = 0,
    last: Id = null,
    name_buf: [128]u8 = undefined,
    name_len: usize = 0,

    /// init makes a renderer drawing to layer, a CAMetalLayer, or offscreen
    /// when layer is null.
    pub fn init(gpa: std.mem.Allocator, layer: Id, opts: Options) !Renderer {
        try objc.load();
        const create = objc.symbol(*const fn () callconv(.c) Id, "MTLCreateSystemDefaultDevice") orelse return error.NoMetal;
        const device = create() orelse return error.NoMetalDevice;
        errdefer objc.release(device);
        const pool = objc.Pool.push();
        defer pool.pop();

        var err: Id = null;
        const lib = send(device, "newLibraryWithSource:options:error:", .{ objc.string(msl), @as(Id, null), &err });
        if (lib == null) {
            sys.log(.err, "myzig: Metal shader: {s}", .{objc.utf8(send(err, "localizedDescription", .{}))});
            return error.MetalShader;
        }
        defer objc.release(lib);
        const vfn = send(lib, "newFunctionWithName:", .{objc.string("box_vertex")});
        defer objc.release(vfn);
        const ffn = send(lib, "newFunctionWithName:", .{objc.string("box_fragment")});
        defer objc.release(ffn);
        const desc = objc.new("MTLRenderPipelineDescriptor");
        defer objc.release(desc);
        msg(void, desc, "setVertexFunction:", .{vfn});
        msg(void, desc, "setFragmentFunction:", .{ffn});
        const ca = send(send(desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(UInt, 0)});
        msg(void, ca, "setPixelFormat:", .{@as(UInt, pixel_bgra8)});
        msg(void, ca, "setBlendingEnabled:", .{objc.YES});
        // Premultiplied: one, one minus the source's alpha.
        msg(void, ca, "setSourceRGBBlendFactor:", .{@as(UInt, 1)});
        msg(void, ca, "setSourceAlphaBlendFactor:", .{@as(UInt, 1)});
        msg(void, ca, "setDestinationRGBBlendFactor:", .{@as(UInt, 5)});
        msg(void, ca, "setDestinationAlphaBlendFactor:", .{@as(UInt, 5)});
        const pipeline = send(device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
        if (pipeline == null) {
            sys.log(.err, "myzig: Metal pipeline: {s}", .{objc.utf8(send(err, "localizedDescription", .{}))});
            return error.MetalPipeline;
        }

        var r = Renderer{
            .gpa = gpa,
            .device = device,
            .queue = send(device, "newCommandQueue", .{}),
            .pipeline = pipeline,
            .layer = layer,
            .atlas = .{ .gpa = gpa },
            .images = .{ .gpa = gpa },
        };
        const n = objc.utf8(send(device, "name", .{}));
        r.name_len = @min(n.len, r.name_buf.len);
        @memcpy(r.name_buf[0..r.name_len], n[0..r.name_len]);
        if (layer) |l| {
            msg(void, l, "setDevice:", .{device});
            msg(void, l, "setPixelFormat:", .{@as(UInt, pixel_bgra8)});
            msg(void, l, "setDisplaySyncEnabled:", .{if (opts.vsync) objc.YES else objc.NO});
            msg(void, l, "setMaximumDrawableCount:", .{@as(UInt, 3)});
            // Opaque, so the compositor can show it directly; sized with
            // the view it hosts.
            msg(void, l, "setOpaque:", .{objc.YES});
            msg(void, l, "setNeedsDisplayOnBoundsChange:", .{objc.YES});
            msg(void, l, "setAutoresizingMask:", .{@as(u32, 2 | 16)}); // width and height sizable
        }
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        if (r.last) |c| msg(void, c, "waitUntilCompleted", .{});
        for (&r.frames) |*f| {
            objc.release(f.cmd);
            objc.release(f.buffer);
        }
        objc.release(r.last);
        objc.release(r.readback);
        objc.release(r.offscreen);
        objc.release(r.atlas_tex);
        objc.release(r.images_tex);
        objc.release(r.pipeline);
        objc.release(r.queue);
        objc.release(r.device);
        r.atlas.deinit();
        r.images.deinit();
        r.instances.deinit(r.gpa);
    }

    pub fn name(r: *const Renderer) []const u8 {
        return r.name_buf[0..r.name_len];
    }

    /// software is false: Metal always has a GPU under it.
    pub fn software(_: *const Renderer) bool {
        return false;
    }

    fn texture(r: *Renderer, format: UInt, w: u32, h: u32, usage: UInt) Id {
        const d = send(objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ format, @as(UInt, w), @as(UInt, h), objc.NO });
        msg(void, d, "setUsage:", .{usage});
        return send(r.device, "newTextureWithDescriptor:", .{d});
    }

    fn makeAtlas(r: *Renderer) void {
        objc.release(r.atlas_tex);
        const sz = r.atlas.size;
        r.atlas_tex = r.texture(pixel_r8, sz, sz, 1); // MTLTextureUsageShaderRead
        r.atlas_size = sz;
        // Textures start undefined: clear it, so no stray texel shows.
        const zeros = r.gpa.alloc(u8, sz) catch return;
        defer r.gpa.free(zeros);
        @memset(zeros, 0);
        for (0..sz) |y| msg(void, r.atlas_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            MTLRegion{ .origin = .{ .y = y }, .size = .{ .width = sz, .height = 1 } }, @as(UInt, 0), @as(?*const anyopaque, zeros.ptr), @as(UInt, sz),
        });
    }

    /// makeImages makes the image texture images.size texels a side (one
    /// while no image was drawn), cleared.
    fn makeImages(r: *Renderer) void {
        objc.release(r.images_tex);
        const sz = if (r.images.used) r.images.size else 1;
        r.images_tex = r.texture(pixel_bgra8, sz, sz, 1);
        r.images_size = sz;
        const zeros = r.gpa.alloc(u8, @as(usize, sz) * 4) catch return;
        defer r.gpa.free(zeros);
        @memset(zeros, 0);
        for (0..sz) |y| msg(void, r.images_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
            MTLRegion{ .origin = .{ .y = y }, .size = .{ .width = sz, .height = 1 } }, @as(UInt, 0), @as(?*const anyopaque, zeros.ptr), @as(UInt, sz * 4),
        });
    }

    /// draw draws s, width×height pixels, and presents it.
    pub fn draw(r: *Renderer, s: *const scene.Scene, fonts: *text.Fonts, width: i32, height: i32) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        try inst.build(s, fonts, &r.atlas, &r.images, &r.instances);
        const w: u32 = @intCast(@max(1, width));
        const h: u32 = @intCast(@max(1, height));

        // The frame's buffer, once the GPU is done with it.
        const f = &r.frames[r.frame];
        if (f.cmd) |c| {
            msg(void, c, "waitUntilCompleted", .{});
            objc.release(c);
            f.cmd = null;
        }

        if (r.atlas.grown or r.atlas_size != r.atlas.size) {
            r.makeAtlas();
            r.atlas.grown = false;
        }
        for (r.atlas.uploads.items) |u| {
            msg(void, r.atlas_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                MTLRegion{ .origin = .{ .x = u.x, .y = u.y }, .size = .{ .width = u.w, .height = u.h } },
                @as(UInt, 0),
                @as(?*const anyopaque, fonts.coverage.items[u.off..].ptr),
                @as(UInt, u.w),
            });
        }
        r.atlas.uploads.clearRetainingCapacity();
        // Images, like glyphs, only go where no frame in flight samples:
        // a grown atlas is a new texture.
        const images_size = if (r.images.used) r.images.size else 1;
        if (r.images_size != images_size or (r.images.grown and r.images.used)) {
            r.makeImages();
            r.images.grown = false;
        }
        for (r.images.uploads.items) |u| {
            msg(void, r.images_tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{
                MTLRegion{ .origin = .{ .x = u.x, .y = u.y }, .size = .{ .width = u.image.width, .height = u.image.height } },
                @as(UInt, 0),
                @as(?*const anyopaque, u.image.pixels.ptr),
                @as(UInt, u.image.width * 4),
            });
        }
        r.images.uploads.clearRetainingCapacity();

        const n = r.instances.items.len;
        const bytes = @max(1, n) * @sizeOf(inst.Instance);
        if (f.size < bytes) {
            objc.release(f.buffer);
            f.size = std.math.ceilPowerOfTwo(usize, bytes) catch bytes;
            f.buffer = send(r.device, "newBufferWithLength:options:", .{ @as(UInt, f.size), storage_shared });
            if (f.buffer == null) return error.OutOfMemory;
        }
        const contents: [*]u8 = @ptrCast(msg(?*anyopaque, f.buffer, "contents", .{}) orelse return error.OutOfMemory);
        @memcpy(contents[0 .. n * @sizeOf(inst.Instance)], std.mem.sliceAsBytes(r.instances.items));

        // The target: the layer's next drawable, or the offscreen texture.
        var drawable: Id = null;
        var target: Id = null;
        if (r.layer) |l| {
            if (r.extent[0] != w or r.extent[1] != h) {
                msg(void, l, "setDrawableSize:", .{objc.NSSize{ .width = @floatFromInt(w), .height = @floatFromInt(h) }});
                r.extent = .{ w, h };
            }
            // Drawables are only read back when a frame is captured.
            if (r.capture and !r.readable) {
                msg(void, l, "setFramebufferOnly:", .{objc.NO});
                r.readable = true;
            }
            drawable = send(l, "nextDrawable", .{});
            if (drawable == null) return; // the window is hidden
            target = send(drawable, "texture", .{});
        } else {
            if (r.offscreen == null or r.extent[0] != w or r.extent[1] != h) {
                objc.release(r.offscreen);
                r.offscreen = r.texture(pixel_bgra8, w, h, 4 | 1); // render target, shader read
                r.extent = .{ w, h };
            }
            target = r.offscreen;
        }

        const cmd = send(r.queue, "commandBuffer", .{});
        const rpd = send(objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
        const ca = send(send(rpd, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{@as(UInt, 0)});
        msg(void, ca, "setTexture:", .{target});
        msg(void, ca, "setLoadAction:", .{@as(UInt, 2)}); // clear
        msg(void, ca, "setStoreAction:", .{@as(UInt, 1)}); // store
        const bg = s.background;
        msg(void, ca, "setClearColor:", .{MTLClearColor{
            .red = @as(f64, @floatFromInt(bg.r)) / 255,
            .green = @as(f64, @floatFromInt(bg.g)) / 255,
            .blue = @as(f64, @floatFromInt(bg.b)) / 255,
            .alpha = 1,
        }});
        const enc = send(cmd, "renderCommandEncoderWithDescriptor:", .{rpd});
        if (n > 0) {
            msg(void, enc, "setRenderPipelineState:", .{r.pipeline});
            msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ f.buffer, @as(UInt, 0), @as(UInt, 0) });
            const viewport = [2]f32{ @floatFromInt(w), @floatFromInt(h) };
            msg(void, enc, "setVertexBytes:length:atIndex:", .{ @as(?*const anyopaque, &viewport), @as(UInt, 8), @as(UInt, 1) });
            msg(void, enc, "setFragmentTexture:atIndex:", .{ r.atlas_tex, @as(UInt, 0) });
            msg(void, enc, "setFragmentTexture:atIndex:", .{ r.images_tex, @as(UInt, 1) });
            // MTLPrimitiveTypeTriangleStrip
            msg(void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ @as(UInt, 4), @as(UInt, 0), @as(UInt, 4), @as(UInt, n) });
        }
        msg(void, enc, "endEncoding", .{});

        if (r.capture) {
            const size: usize = @as(usize, w) * h * 4;
            if (r.readback_size < size) {
                objc.release(r.readback);
                r.readback = send(r.device, "newBufferWithLength:options:", .{ @as(UInt, size), storage_shared });
                r.readback_size = size;
            }
            const blit = send(cmd, "blitCommandEncoder", .{});
            msg(void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
                target,     @as(UInt, 0), @as(UInt, 0),     MTLOrigin{},     MTLSize{ .width = w, .height = h },
                r.readback, @as(UInt, 0), @as(UInt, w * 4), @as(UInt, size),
            });
            msg(void, blit, "endEncoding", .{});
        }
        if (drawable != null) msg(void, cmd, "presentDrawable:", .{drawable});
        msg(void, cmd, "commit", .{});
        f.cmd = objc.retain(cmd);
        objc.release(r.last);
        r.last = objc.retain(cmd);
        r.frame = (r.frame + 1) % frames_in_flight;
    }

    /// read copies the last frame drawn with capture set into out, as
    /// 0x00RRGGBB, top row first.
    pub fn read(r: *Renderer, width: i32, height: i32, out: []u32) void {
        const c = r.last orelse return;
        if (r.readback == null) return;
        msg(void, c, "waitUntilCompleted", .{});
        const src: [*]const u32 = @ptrCast(@alignCast(msg(?*anyopaque, r.readback, "contents", .{}) orelse return));
        const w: usize = @intCast(@min(width, @as(i32, @intCast(r.extent[0]))));
        const h: usize = @intCast(@min(height, @as(i32, @intCast(r.extent[1]))));
        for (0..h) |y| for (0..w) |x| {
            out[y * @as(usize, @intCast(width)) + x] = src[y * r.extent[0] + x] & 0xffffff;
        };
    }
};

test "offscreen Metal draws what the CPU renderer draws" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const geom = @import("../geom.zig");
    const raster = @import("../raster.zig");
    var r = Renderer.init(gpa, null, .{}) catch |e| {
        sys.print("no Metal device ({s}); skipped\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer r.deinit();
    var fonts = try text.Fonts.init(gpa);
    defer fonts.deinit();
    var s = scene.Scene{ .gpa = gpa };
    defer s.deinit();
    s.reset(320, 120, 1, geom.Color.white);
    s.rect(.{ .x = 10, .y = 10, .w = 120, .h = 40 }, (comptime geom.Color.hex("#2563eb")), 8, 2, (comptime geom.Color.hex("#111827")));
    s.rect(.{ .x = 150, .y = 10, .w = 60, .h = 40 }, geom.Color.rgba(220, 38, 38, 0.5), 20, 0, geom.Color.black);
    s.textRun(&fonts, 20, 80, "Metal · quick 123", 16, .regular, geom.Color.black);
    s.shadow(.{ .x = 260, .y = 60, .w = 40, .h = 30 }, 6, 10, geom.Color.rgba(0, 0, 0, 0.4));
    s.stroke(.{ .x = 230, .y = 14, .w = 24, .h = 24 }, .{ .{ 0.1, 0.55, 0.4, 0.85 }, .{ 0.4, 0.85, 0.9, 0.15 } }, 3, geom.Color.black);
    // An image, scaled up, its corners rounded, half of it see-through.
    var rgba: [16 * 16 * 4]u8 = undefined;
    for (0..16) |y| for (0..16) |x| {
        const i = (y * 16 + x) * 4;
        rgba[i..][0..4].* = .{ @intCast(x * 16), @intCast(y * 16), 200, if (x < 8) 255 else 128 };
    };
    const img = try @import("../image.zig").Image.fromRgba(gpa, 16, 16, &rgba);
    defer img.deinit();
    s.image(.{ .x = 214, .y = 58, .w = 40, .h = 40 }, img, .{ 0, 0, 16, 16 }, 8, 230);
    r.capture = true;
    try r.draw(&s, &fonts, 320, 120);
    const gpu_px = try gpa.alloc(u32, 320 * 120);
    defer gpa.free(gpu_px);
    r.read(320, 120, gpu_px);

    var rend = scene.Renderer{ .gpa = gpa };
    defer rend.deinit();
    const cpu_px = try gpa.alloc(u32, 320 * 120);
    defer gpa.free(cpu_px);
    var cv = raster.Canvas{ .pixels = cpu_px, .width = 320, .height = 120, .stride = 320 };
    @memset(cpu_px, 0xffffff);
    _ = rend.render(&s, &fonts, &cv);
    var worst: u32 = 0;
    for (gpu_px, cpu_px) |a, b| inline for (.{ 0, 8, 16 }) |sh| {
        const da: i32 = @intCast((a >> sh) & 0xff);
        const db: i32 = @intCast((b >> sh) & 0xff);
        worst = @max(worst, @abs(da - db));
    };
    std.testing.expect(worst <= 8) catch |e| {
        sys.print("Metal and CPU pixels differ by up to {d}\n", .{worst});
        return e;
    };
    try std.testing.expectEqual(cpu_px[30 * 320 + 70], gpu_px[30 * 320 + 70]);
}
