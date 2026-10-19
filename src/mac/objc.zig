//! The Objective-C runtime, from Zig: classes looked up by name, messages
//! sent through objc_msgSend cast to each call's own C signature, and
//! classes of MyZig's own with methods written in Zig.
//!
//! libobjc and the frameworks (AppKit, QuartzCore, Metal, CoreGraphics)
//! are opened at run time, as the Vulkan and OpenGL drivers are elsewhere:
//! building for macOS needs no SDK, so it cross-compiles from Linux and
//! Windows too.

const std = @import("std");
const builtin = @import("builtin");

pub const Id = ?*anyopaque;
pub const Sel = ?*anyopaque;
pub const Class = ?*anyopaque;
/// BOOL is a byte that is 0 or 1 (a signed char on x86_64, bool on arm64;
/// both are passed the same way).
pub const BOOL = u8;
pub const YES: BOOL = 1;
pub const NO: BOOL = 0;
pub const NSInteger = isize;
pub const NSUInteger = usize;
pub const CGFloat = f64;

pub const NSPoint = extern struct { x: CGFloat = 0, y: CGFloat = 0 };
pub const NSSize = extern struct { width: CGFloat = 0, height: CGFloat = 0 };
pub const NSRect = extern struct { origin: NSPoint = .{}, size: NSSize = .{} };
pub const NSRange = extern struct { location: NSUInteger = 0, length: NSUInteger = 0 };
/// NSNotFound marks an empty range.
pub const NSNotFound: NSUInteger = @as(NSUInteger, std.math.maxInt(NSInteger));

const Fns = struct {
    objc_getClass: *const fn ([*:0]const u8) callconv(.c) Class,
    objc_getProtocol: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    sel_registerName: *const fn ([*:0]const u8) callconv(.c) Sel,
    objc_allocateClassPair: *const fn (Class, [*:0]const u8, usize) callconv(.c) Class,
    objc_registerClassPair: *const fn (Class) callconv(.c) void,
    class_addMethod: *const fn (Class, Sel, *const anyopaque, [*:0]const u8) callconv(.c) BOOL,
    class_addProtocol: *const fn (Class, ?*anyopaque) callconv(.c) BOOL,
    objc_autoreleasePoolPush: *const fn () callconv(.c) ?*anyopaque,
    objc_autoreleasePoolPop: *const fn (?*anyopaque) callconv(.c) void,
    objc_msgSend: *const anyopaque,
};

var fns: Fns = undefined;
/// msg_stret is objc_msgSend_stret, which x86_64 sends the messages that
/// return a struct in memory with.
var msg_stret: ?*const anyopaque = null;
var libs: [6]?std.DynLib = @splat(null);
var loaded = false;

const framework_paths = [_][]const u8{
    "/System/Library/Frameworks/Foundation.framework/Foundation",
    "/System/Library/Frameworks/AppKit.framework/AppKit",
    "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/Frameworks/Metal.framework/Metal",
};

/// load opens the runtime and the frameworks, once.
pub fn load() !void {
    if (loaded) return;
    var objc = try std.DynLib.open("/usr/lib/libobjc.A.dylib");
    const fns_ti = @typeInfo(Fns).@"struct";
    inline for (fns_ti.field_names, fns_ti.field_types) |name, ftype| {
        @field(fns, name) = objc.lookup(ftype, name) orelse return error.NoObjcRuntime;
    }
    if (builtin.cpu.arch == .x86_64) msg_stret = objc.lookup(*const anyopaque, "objc_msgSend_stret");
    libs[0] = objc;
    for (framework_paths, 1..) |p, i| libs[i] = std.DynLib.open(p) catch null;
    if (libs[2] == null) return error.NoAppKit;
    loaded = true;
}

/// symbol looks a C function or global up in the frameworks.
pub fn symbol(comptime T: type, name: [:0]const u8) ?T {
    for (&libs) |*l| if (l.*) |*lib| if (lib.lookup(T, name)) |s| return s;
    return null;
}

/// constant is a framework's global object (an NSString constant).
pub fn constant(name: [:0]const u8) Id {
    const p = symbol(*const Id, name) orelse return null;
    return p.*;
}

pub fn class(name: [*:0]const u8) Class {
    return fns.objc_getClass(name);
}

/// sel is the selector named name, registered once.
pub fn sel(comptime name: [:0]const u8) Sel {
    // S names the selector, so that each name has its own S (a struct
    // that captured nothing would be one type for every name).
    const S = struct {
        const n = name;
        var s: Sel = null;
    };
    if (S.s == null) S.s = fns.sel_registerName(S.n);
    return S.s;
}

fn stret(comptime R: type) bool {
    if (builtin.cpu.arch != .x86_64) return false;
    return switch (@typeInfo(R)) {
        .@"struct" => @sizeOf(R) > 16,
        else => false,
    };
}

/// msg sends the message name to target with args, as the C function
/// R (id, SEL, args...).
pub fn msg(comptime R: type, target: anytype, comptime name: [:0]const u8, args: anytype) R {
    const t: Id = @ptrCast(target);
    const s = sel(name);
    const fp = if (comptime stret(R)) msg_stret.? else fns.objc_msgSend;
    const A = @TypeOf(args);
    const f = @typeInfo(A).@"struct".field_types;
    inline for (f) |ftype| {
        if (ftype == comptime_int or ftype == comptime_float) @compileError("give " ++ name ++ "'s arguments their types");
    }
    switch (f.len) {
        0 => return @as(*const fn (Id, Sel) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s),
        1 => return @as(*const fn (Id, Sel, f[0]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0]),
        2 => return @as(*const fn (Id, Sel, f[0], f[1]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1]),
        3 => return @as(*const fn (Id, Sel, f[0], f[1], f[2]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2]),
        4 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3]),
        5 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3], f[4]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3], args[4]),
        6 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3], f[4], f[5]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5]),
        7 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3], f[4], f[5], f[6]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5], args[6]),
        8 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7]),
        9 => return @as(*const fn (Id, Sel, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8]) callconv(.c) R, @ptrCast(@alignCast(fp)))(t, s, args[0], args[1], args[2], args[3], args[4], args[5], args[6], args[7], args[8]),
        else => @compileError("too many arguments"),
    }
}

/// send is msg for the messages that return an object.
pub fn send(target: anytype, comptime name: [:0]const u8, args: anytype) Id {
    return msg(Id, target, name, args);
}

/// new is [[name alloc] init].
pub fn new(name: [*:0]const u8) Id {
    return send(send(class(name), "alloc", .{}), "init", .{});
}

pub fn release(o: Id) void {
    if (o != null) msg(void, o, "release", .{});
}

pub fn retain(o: Id) Id {
    return if (o != null) send(o, "retain", .{}) else null;
}

/// string is an autoreleased NSString of s.
pub fn string(s: []const u8) Id {
    const str = send(class("NSString"), "alloc", .{});
    return send(send(str, "initWithBytes:length:encoding:", .{ @as(?*const anyopaque, s.ptr), @as(NSUInteger, s.len), @as(NSUInteger, 4) }), "autorelease", .{});
}

/// utf8 is the text of an NSString, valid while the string is.
pub fn utf8(str: Id) []const u8 {
    if (str == null) return "";
    const p = msg(?[*:0]const u8, str, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

pub const Pool = struct {
    p: ?*anyopaque,
    pub fn push() Pool {
        return .{ .p = fns.objc_autoreleasePoolPush() };
    }
    pub fn pop(pool: Pool) void {
        fns.objc_autoreleasePoolPop(pool.p);
    }
};

pub const Method = struct {
    name: [:0]const u8,
    imp: *const anyopaque,
    /// types is the method's type encoding ("v@:@" for a void method of
    /// one object).
    types: [:0]const u8,
};

/// define makes the class name, a subclass of super, with methods and
/// protocols. A class of that name already made is returned as it is.
pub fn define(name: [*:0]const u8, super: [*:0]const u8, methods: []const Method, protocols: []const [*:0]const u8) !Class {
    if (class(name)) |c| return c;
    const c = fns.objc_allocateClassPair(class(super), name, 0) orelse return error.NoClass;
    for (methods) |m| _ = fns.class_addMethod(c, fns.sel_registerName(m.name), m.imp, m.types);
    for (protocols) |p| if (fns.objc_getProtocol(p)) |proto| {
        _ = fns.class_addProtocol(c, proto);
    };
    fns.objc_registerClassPair(c);
    return c;
}
