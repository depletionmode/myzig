//! The OpenGL renderer: OpenGL 3.3 core (or a compatibility context of 3.3
//! and later), the whole scene in one instanced draw of instances.zig's
//! shader. Functions are loaded at run time, so an app that draws on the
//! CPU never maps the driver.

const std = @import("std");
const sys = @import("../sys.zig");
const scene = @import("../scene.zig");
const text = @import("../text.zig");
const inst = @import("instances.zig");

const GLenum = u32;
const GLuint = u32;
const GLint = i32;
const GLsizei = i32;
const CC: std.builtin.CallingConvention = if (@import("builtin").os.tag == .windows) .winapi else .c;

/// Gl holds the functions the renderer calls, each looked up by its name
/// with "gl" before it.
pub const Gl = struct {
    CreateShader: *const fn (GLenum) callconv(CC) GLuint,
    ShaderSource: *const fn (GLuint, GLsizei, *const [*:0]const u8, ?*const GLint) callconv(CC) void,
    CompileShader: *const fn (GLuint) callconv(CC) void,
    GetShaderiv: *const fn (GLuint, GLenum, *GLint) callconv(CC) void,
    GetShaderInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(CC) void,
    CreateProgram: *const fn () callconv(CC) GLuint,
    AttachShader: *const fn (GLuint, GLuint) callconv(CC) void,
    LinkProgram: *const fn (GLuint) callconv(CC) void,
    GetProgramiv: *const fn (GLuint, GLenum, *GLint) callconv(CC) void,
    GetProgramInfoLog: *const fn (GLuint, GLsizei, ?*GLsizei, [*]u8) callconv(CC) void,
    UseProgram: *const fn (GLuint) callconv(CC) void,
    GetUniformLocation: *const fn (GLuint, [*:0]const u8) callconv(CC) GLint,
    Uniform2f: *const fn (GLint, f32, f32) callconv(CC) void,
    Uniform1i: *const fn (GLint, GLint) callconv(CC) void,
    GenVertexArrays: *const fn (GLsizei, *GLuint) callconv(CC) void,
    BindVertexArray: *const fn (GLuint) callconv(CC) void,
    GenBuffers: *const fn (GLsizei, *GLuint) callconv(CC) void,
    BindBuffer: *const fn (GLenum, GLuint) callconv(CC) void,
    BufferData: *const fn (GLenum, isize, ?*const anyopaque, GLenum) callconv(CC) void,
    VertexAttribPointer: *const fn (GLuint, GLint, GLenum, u8, GLsizei, usize) callconv(CC) void,
    EnableVertexAttribArray: *const fn (GLuint) callconv(CC) void,
    VertexAttribDivisor: *const fn (GLuint, GLuint) callconv(CC) void,
    DrawArraysInstanced: *const fn (GLenum, GLint, GLsizei, GLsizei) callconv(CC) void,
    GenTextures: *const fn (GLsizei, *GLuint) callconv(CC) void,
    BindTexture: *const fn (GLenum, GLuint) callconv(CC) void,
    TexImage2D: *const fn (GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, ?*const anyopaque) callconv(CC) void,
    TexSubImage2D: *const fn (GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*const anyopaque) callconv(CC) void,
    TexParameteri: *const fn (GLenum, GLenum, GLint) callconv(CC) void,
    PixelStorei: *const fn (GLenum, GLint) callconv(CC) void,
    ActiveTexture: *const fn (GLenum) callconv(CC) void,
    Viewport: *const fn (GLint, GLint, GLsizei, GLsizei) callconv(CC) void,
    ClearColor: *const fn (f32, f32, f32, f32) callconv(CC) void,
    Clear: *const fn (GLenum) callconv(CC) void,
    Enable: *const fn (GLenum) callconv(CC) void,
    Disable: *const fn (GLenum) callconv(CC) void,
    BlendFunc: *const fn (GLenum, GLenum) callconv(CC) void,
    GetString: *const fn (GLenum) callconv(CC) ?[*:0]const u8,
    ReadPixels: *const fn (GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, ?*anyopaque) callconv(CC) void,
    Finish: *const fn () callconv(CC) void,

    /// load looks every function up with proc, which returns null for a
    /// function the driver lacks.
    pub fn load(ctx: anytype, comptime proc: fn (@TypeOf(ctx), [*:0]const u8) ?*const anyopaque) !Gl {
        var g: Gl = undefined;
        const ti = @typeInfo(Gl).@"struct";
        inline for (ti.field_names) |name| {
            const p = proc(ctx, "gl" ++ name) orelse {
                sys.log(.err, "myzig: OpenGL has no gl{s}", .{name});
                return error.MissingFunction;
            };
            @field(g, name) = @ptrCast(@alignCast(p));
        }
        return g;
    }
};

const GL_FRAGMENT_SHADER = 0x8B30;
const GL_VERTEX_SHADER = 0x8B31;
const GL_COMPILE_STATUS = 0x8B81;
const GL_LINK_STATUS = 0x8B82;
const GL_ARRAY_BUFFER = 0x8892;
const GL_STREAM_DRAW = 0x88E0;
const GL_FLOAT = 0x1406;
const GL_TRIANGLE_STRIP = 0x0005;
const GL_TEXTURE_2D = 0x0DE1;
const GL_TEXTURE0 = 0x84C0;
const GL_R8 = 0x8229;
const GL_RED = 0x1903;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_RGBA = 0x1908;
const GL_TEXTURE_MIN_FILTER = 0x2801;
const GL_TEXTURE_MAG_FILTER = 0x2800;
const GL_TEXTURE_WRAP_S = 0x2802;
const GL_TEXTURE_WRAP_T = 0x2803;
const GL_NEAREST = 0x2600;
const GL_CLAMP_TO_EDGE = 0x812F;
const GL_UNPACK_ALIGNMENT = 0x0CF5;
const GL_UNPACK_ROW_LENGTH = 0x0CF2;
const GL_PACK_ALIGNMENT = 0x0D05;
const GL_COLOR_BUFFER_BIT = 0x4000;
const GL_BLEND = 0x0BE2;
const GL_ONE = 1;
const GL_ONE_MINUS_SRC_ALPHA = 0x0303;
const GL_DEPTH_TEST = 0x0B71;
const GL_RENDERER = 0x1F01;
const GL_VERSION = 0x1F02;
const GL_SCISSOR_TEST = 0x0C11;
const GL_TEXTURE1 = 0x84C1;
const GL_LINEAR = 0x2601;
const GL_RGBA8 = 0x8058;
const GL_BGRA = 0x80E1;

pub const Renderer = struct {
    gl: Gl,
    gpa: std.mem.Allocator,
    program: GLuint = 0,
    vao: GLuint = 0,
    vbo: GLuint = 0,
    texture: GLuint = 0,
    /// images is the image atlas's texture, on unit 1.
    images_tex: GLuint = 0,
    images: inst.ImageAtlas,
    images_size: u32 = 0,
    u_viewport: GLint = -1,
    atlas: inst.Atlas,
    instances: std.ArrayListUnmanaged(inst.Instance) = .empty,
    staging: std.ArrayListUnmanaged(u8) = .empty,
    tex_size: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, gl: Gl) !Renderer {
        var r = Renderer{ .gl = gl, .gpa = gpa, .atlas = .{ .gpa = gpa }, .images = .{ .gpa = gpa } };
        const vs = try r.shader(GL_VERTEX_SHADER, inst.glsl_vertex);
        const fs = try r.shader(GL_FRAGMENT_SHADER, inst.glsl_fragment);
        r.program = gl.CreateProgram();
        gl.AttachShader(r.program, vs);
        gl.AttachShader(r.program, fs);
        gl.LinkProgram(r.program);
        var ok: GLint = 0;
        gl.GetProgramiv(r.program, GL_LINK_STATUS, &ok);
        if (ok == 0) {
            var log: [1024]u8 = undefined;
            var n: GLsizei = 0;
            gl.GetProgramInfoLog(r.program, log.len, &n, &log);
            sys.log(.err, "myzig: OpenGL link: {s}", .{log[0..@intCast(n)]});
            return error.ShaderLink;
        }
        gl.UseProgram(r.program);
        r.u_viewport = gl.GetUniformLocation(r.program, "u_viewport");
        gl.Uniform1i(gl.GetUniformLocation(r.program, "u_atlas"), 0);
        gl.Uniform1i(gl.GetUniformLocation(r.program, "u_images"), 1);
        gl.GenVertexArrays(1, &r.vao);
        gl.BindVertexArray(r.vao);
        gl.GenBuffers(1, &r.vbo);
        gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
        inline for (0..6) |i| {
            gl.VertexAttribPointer(i, 4, GL_FLOAT, 0, @sizeOf(inst.Instance), i * 16);
            gl.EnableVertexAttribArray(i);
            gl.VertexAttribDivisor(i, 1);
        }
        gl.GenTextures(1, &r.texture);
        gl.ActiveTexture(GL_TEXTURE0);
        gl.BindTexture(GL_TEXTURE_2D, r.texture);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.GenTextures(1, &r.images_tex);
        gl.ActiveTexture(GL_TEXTURE1);
        gl.BindTexture(GL_TEXTURE_2D, r.images_tex);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
        gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
        gl.ActiveTexture(GL_TEXTURE0);
        gl.PixelStorei(GL_UNPACK_ALIGNMENT, 1);
        gl.PixelStorei(GL_PACK_ALIGNMENT, 4);
        gl.Disable(GL_DEPTH_TEST);
        gl.Disable(GL_SCISSOR_TEST);
        gl.Enable(GL_BLEND);
        gl.BlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        r.atlas.deinit();
        r.images.deinit();
        r.instances.deinit(r.gpa);
        r.staging.deinit(r.gpa);
    }

    /// name says which OpenGL draws: its renderer and version.
    pub fn name(r: *const Renderer) []const u8 {
        const s = r.gl.GetString(GL_RENDERER) orelse return "?";
        return std.mem.span(s);
    }

    fn shader(r: *Renderer, kind: GLenum, src: [*:0]const u8) !GLuint {
        const gl = r.gl;
        const s = gl.CreateShader(kind);
        gl.ShaderSource(s, 1, &src, null);
        gl.CompileShader(s);
        var ok: GLint = 0;
        gl.GetShaderiv(s, GL_COMPILE_STATUS, &ok);
        if (ok == 0) {
            var log: [1024]u8 = undefined;
            var n: GLsizei = 0;
            gl.GetShaderInfoLog(s, log.len, &n, &log);
            sys.log(.err, "myzig: OpenGL shader: {s}", .{log[0..@intCast(n)]});
            return error.ShaderCompile;
        }
        return s;
    }

    /// draw draws s into the current framebuffer, of width×height pixels.
    pub fn draw(r: *Renderer, s: *const scene.Scene, fonts: *text.Fonts, width: i32, height: i32) !void {
        const gl = r.gl;
        try inst.build(s, fonts, &r.atlas, &r.images, &r.instances);
        gl.BindTexture(GL_TEXTURE_2D, r.texture);
        if (r.atlas.grown or r.tex_size != r.atlas.size) {
            gl.TexImage2D(GL_TEXTURE_2D, 0, GL_R8, @intCast(r.atlas.size), @intCast(r.atlas.size), 0, GL_RED, GL_UNSIGNED_BYTE, null);
            r.tex_size = r.atlas.size;
            r.atlas.grown = false;
        }
        for (r.atlas.uploads.items) |u| {
            const px = fonts.coverage.items[u.off..][0 .. u.w * u.h];
            gl.TexSubImage2D(GL_TEXTURE_2D, 0, @intCast(u.x), @intCast(u.y), @intCast(u.w), @intCast(u.h), GL_RED, GL_UNSIGNED_BYTE, px.ptr);
        }
        r.atlas.uploads.clearRetainingCapacity();
        // Images, on unit 1: one texel until one is drawn.
        const images_size = if (r.images.used) r.images.size else 1;
        if (r.images_size != images_size or (r.images.grown and r.images.used) or r.images.uploads.items.len > 0) {
            gl.ActiveTexture(GL_TEXTURE1);
            defer gl.ActiveTexture(GL_TEXTURE0);
            gl.BindTexture(GL_TEXTURE_2D, r.images_tex);
            if (r.images_size != images_size or r.images.grown) {
                const sz: GLsizei = @intCast(images_size);
                const zero = try r.gpa.alloc(u8, @as(usize, images_size) * images_size * 4);
                defer r.gpa.free(zero);
                @memset(zero, 0);
                gl.TexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, sz, sz, 0, GL_BGRA, GL_UNSIGNED_BYTE, zero.ptr);
                r.images_size = images_size;
                r.images.grown = false;
            }
            for (r.images.uploads.items) |u| {
                gl.TexSubImage2D(GL_TEXTURE_2D, 0, @intCast(u.x), @intCast(u.y), @intCast(u.image.width), @intCast(u.image.height), GL_BGRA, GL_UNSIGNED_BYTE, u.image.pixels.ptr);
            }
            r.images.uploads.clearRetainingCapacity();
        }

        gl.Viewport(0, 0, width, height);
        const bg = s.background;
        gl.ClearColor(@as(f32, @floatFromInt(bg.r)) / 255, @as(f32, @floatFromInt(bg.g)) / 255, @as(f32, @floatFromInt(bg.b)) / 255, 1);
        gl.Clear(GL_COLOR_BUFFER_BIT);
        if (r.instances.items.len == 0) return;
        gl.UseProgram(r.program);
        gl.Uniform2f(r.u_viewport, @floatFromInt(width), @floatFromInt(height));
        gl.BindVertexArray(r.vao);
        gl.BindBuffer(GL_ARRAY_BUFFER, r.vbo);
        gl.BufferData(GL_ARRAY_BUFFER, @intCast(r.instances.items.len * @sizeOf(inst.Instance)), r.instances.items.ptr, GL_STREAM_DRAW);
        gl.DrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 4, @intCast(r.instances.items.len));
    }

    /// read copies the framebuffer into out as 0x00RRGGBB, top row first.
    pub fn read(r: *Renderer, width: i32, height: i32, out: []u32) void {
        const w: usize = @intCast(width);
        const h: usize = @intCast(height);
        r.gl.ReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, out.ptr);
        // RGBA bytes, bottom row first: to BGRX, top first.
        for (0..h / 2) |y| {
            const a = out[y * w ..][0..w];
            const b = out[(h - 1 - y) * w ..][0..w];
            for (a, b) |*p, *q| std.mem.swap(u32, p, q);
        }
        for (out[0 .. w * h]) |*p| {
            const v = p.*;
            p.* = ((v & 0xff) << 16) | (v & 0xff00) | ((v >> 16) & 0xff);
        }
    }
};

/// software reports whether OpenGL draws on the CPU (llvmpipe, softpipe,
/// SwiftShader, Microsoft's GDI renderer), where MyZig's own CPU renderer,
/// which draws only what changed, is cheaper.
pub fn software(renderer_name: []const u8) bool {
    const names = [_][]const u8{ "llvmpipe", "softpipe", "SwiftShader", "GDI Generic", "Software Rasterizer" };
    for (names) |n| if (std.mem.indexOf(u8, renderer_name, n) != null) return true;
    return false;
}
