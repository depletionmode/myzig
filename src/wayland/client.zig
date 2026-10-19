//! The parts of libwayland-client MyZig calls, opened at run time: the
//! connection, and proxies that send requests from argument arrays and
//! take events through one dispatcher each. The protocols' interfaces and
//! typed requests and events are generated into protocol.zig.

const std = @import("std");

pub const Interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const Message,
    event_count: c_int,
    events: ?[*]const Message,
};

pub const Message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: ?[*]const ?*const Interface,
};

pub const Array = extern struct {
    size: usize,
    alloc: usize,
    data: ?*anyopaque,

    pub fn slice(a: *const Array, comptime T: type) []const T {
        const p: [*]const T = @ptrCast(@alignCast(a.data orelse return &.{}));
        return p[0 .. a.size / @sizeOf(T)];
    }
};

pub const Argument = extern union {
    i: i32,
    u: u32,
    f: i32,
    s: ?[*:0]const u8,
    o: ?*anyopaque,
    n: u32,
    a: ?*Array,
    h: i32,
};

pub const Dispatcher = *const fn (impl: ?*const anyopaque, proxy: ?*anyopaque, opcode: u32, msg: ?*const Message, args: [*]Argument) callconv(.c) c_int;

pub const Display = opaque {};

pub const marshal_destroy: u32 = 1;

const Lib = struct {
    display_connect: *const fn (name: ?[*:0]const u8) callconv(.c) ?*Display,
    display_disconnect: *const fn (*Display) callconv(.c) void,
    display_get_fd: *const fn (*Display) callconv(.c) c_int,
    display_dispatch_pending: *const fn (*Display) callconv(.c) c_int,
    display_roundtrip: *const fn (*Display) callconv(.c) c_int,
    display_flush: *const fn (*Display) callconv(.c) c_int,
    display_prepare_read: *const fn (*Display) callconv(.c) c_int,
    display_read_events: *const fn (*Display) callconv(.c) c_int,
    display_cancel_read: *const fn (*Display) callconv(.c) void,
    display_get_error: *const fn (*Display) callconv(.c) c_int,
    proxy_marshal_array_flags: *const fn (proxy: *anyopaque, opcode: u32, interface: ?*const Interface, version: u32, flags: u32, args: [*]Argument) callconv(.c) ?*anyopaque,
    proxy_add_dispatcher: *const fn (proxy: *anyopaque, dispatcher: Dispatcher, impl: ?*const anyopaque, data: ?*anyopaque) callconv(.c) c_int,
    proxy_get_user_data: *const fn (proxy: *anyopaque) callconv(.c) ?*anyopaque,
    proxy_get_version: *const fn (proxy: *anyopaque) callconv(.c) u32,
    proxy_destroy: *const fn (proxy: *anyopaque) callconv(.c) void,
};

pub var lib: Lib = undefined;
var opened: ?std.DynLib = null;

/// open loads libwayland-client; it fails where there is none.
pub fn open() !void {
    if (opened != null) return;
    var dl = std.DynLib.open("libwayland-client.so.0") catch try std.DynLib.open("libwayland-client.so");
    errdefer dl.close();
    const ti = @typeInfo(Lib).@"struct";
    inline for (ti.field_names, ti.field_types) |name, ftype| {
        @field(lib, name) = dl.lookup(ftype, "wl_" ++ name) orelse return error.MissingSymbol;
    }
    opened = dl;
}

pub fn connect() !*Display {
    try open();
    return lib.display_connect(null) orelse error.NoWaylandDisplay;
}

/// marshal sends request opcode of proxy with args; for one that makes
/// an object, interface is the new object's and the result is it.
pub fn marshal(proxy: anytype, opcode: u32, interface: ?*const Interface, ver: u32, flags: u32, args: []Argument) ?*anyopaque {
    return lib.proxy_marshal_array_flags(@ptrCast(proxy), opcode, interface, ver, flags, args.ptr);
}

pub fn version(proxy: anytype) u32 {
    return lib.proxy_get_version(@ptrCast(proxy));
}

pub fn fixedToFloat(f: i32) f64 {
    return @as(f64, @floatFromInt(f)) / 256.0;
}

pub fn floatToFixed(v: f64) i32 {
    return @intFromFloat(@round(v * 256.0));
}
