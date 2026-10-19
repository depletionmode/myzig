//! Smooth scrolling on X11 through the X Input extension 2.1: a wheel or a
//! trackpad moves scroll valuators, by fractions of a notch for a
//! trackpad, horizontally too. libXi is opened at run time; without it, or
//! without the extension, the core protocol's wheel buttons (4 to 7) scroll
//! a notch at a time.

const std = @import("std");
const x = @import("../x11.zig");

const Display = x.Display;

const AnyClassInfo = extern struct { type: c_int, sourceid: c_int };
const ValuatorClassInfo = extern struct {
    type: c_int,
    sourceid: c_int,
    number: c_int,
    label: x.Atom,
    min: f64,
    max: f64,
    value: f64,
    resolution: c_int,
    mode: c_int,
};
const ScrollClassInfo = extern struct {
    type: c_int,
    sourceid: c_int,
    number: c_int,
    scroll_type: c_int,
    increment: f64,
    flags: c_int,
};
const DeviceInfo = extern struct {
    deviceid: c_int,
    name: ?[*:0]u8,
    use: c_int,
    attachment: c_int,
    enabled: c_int,
    num_classes: c_int,
    classes: [*]*AnyClassInfo,
};
const EventMask = extern struct { deviceid: c_int, mask_len: c_int, mask: [*]u8 };

pub const DeviceEvent = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    extension: c_int,
    evtype: c_int,
    time: c_ulong,
    deviceid: c_int,
    sourceid: c_int,
    detail: c_int,
    root: x.Window,
    event: x.Window,
    child: x.Window,
    root_x: f64,
    root_y: f64,
    event_x: f64,
    event_y: f64,
    flags: c_int,
    buttons: extern struct { mask_len: c_int, mask: ?[*]u8 },
    valuators: extern struct { mask_len: c_int, mask: ?[*]u8, values: ?[*]f64 },
    mods: extern struct { base: c_int, latched: c_int, locked: c_int, effective: c_int },
    group: extern struct { base: c_int, latched: c_int, locked: c_int, effective: c_int },
};

pub const GenericEventCookie = extern struct {
    type: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    extension: c_int,
    evtype: c_int,
    cookie: c_uint,
    data: ?*anyopaque,
};

pub const GenericEvent = 35;
const XIAllMasterDevices = 1;
const XIMasterPointer = 1;
const XIValuatorClass = 2;
const XIScrollClass = 3;
const XIScrollTypeVertical = 1;
pub const XI_DeviceChanged = 1;
pub const XI_Motion = 6;

extern "X11" fn XQueryExtension(d: *Display, name: [*:0]const u8, opcode: *c_int, event: *c_int, err: *c_int) c_int;
pub extern "X11" fn XGetEventData(d: *Display, cookie: *GenericEventCookie) c_int;
pub extern "X11" fn XFreeEventData(d: *Display, cookie: *GenericEventCookie) void;

const Fns = struct {
    XIQueryVersion: *const fn (*Display, *c_int, *c_int) callconv(.c) c_int,
    XISelectEvents: *const fn (*Display, x.Window, *EventMask, c_int) callconv(.c) c_int,
    XIQueryDevice: *const fn (*Display, c_int, *c_int) callconv(.c) ?[*]DeviceInfo,
    XIFreeDeviceInfo: *const fn ([*]DeviceInfo) callconv(.c) void,
};

/// Axis is a scroll valuator: its number, how much of it is a notch, and
/// where it was (null until it is first seen, after the pointer enters).
const Axis = struct { number: u16, horizontal: bool, increment: f64, last: ?f64 = null };

pub const Smooth = struct {
    lib: std.DynLib,
    fns: Fns,
    opcode: c_int,
    axes: [8]Axis = undefined,
    naxes: usize = 0,

    /// open selects the pointer's motion on win through XI2, and reports
    /// the scroll valuators there are; null without XI 2.1.
    pub fn open(dpy: *Display, win: x.Window) ?Smooth {
        var opcode: c_int = 0;
        var ev: c_int = 0;
        var err: c_int = 0;
        if (XQueryExtension(dpy, "XInputExtension", &opcode, &ev, &err) == 0) return null;
        var lib = std.DynLib.open("libXi.so.6") catch return null;
        var s = Smooth{ .lib = lib, .fns = undefined, .opcode = opcode };
        const ti = @typeInfo(Fns).@"struct";
        inline for (ti.field_names, ti.field_types) |name, ftype| {
            @field(s.fns, name) = lib.lookup(ftype, name) orelse {
                lib.close();
                return null;
            };
        }
        var major: c_int = 2;
        var minor: c_int = 1;
        // From here libXi stays loaded: the display calls into it when it
        // closes.
        if (s.fns.XIQueryVersion(dpy, &major, &minor) != 0 or (major == 2 and minor < 1)) return null;
        s.scan(dpy);
        if (s.naxes == 0) return null;
        var bits = [_]u8{ (1 << XI_Motion) | (1 << XI_DeviceChanged), 0, 0, 0 };
        var mask = EventMask{ .deviceid = XIAllMasterDevices, .mask_len = bits.len, .mask = &bits };
        _ = s.fns.XISelectEvents(dpy, win, &mask, 1);
        return s;
    }

    /// close leaves libXi loaded: the display calls into it when it closes.
    pub fn close(s: *Smooth) void {
        _ = s;
    }

    /// scan finds the master pointer's scroll valuators.
    pub fn scan(s: *Smooth, dpy: *Display) void {
        s.naxes = 0;
        var n: c_int = 0;
        const devs = s.fns.XIQueryDevice(dpy, XIAllMasterDevices, &n) orelse return;
        defer s.fns.XIFreeDeviceInfo(devs);
        for (devs[0..@intCast(n)]) |d| {
            if (d.use != XIMasterPointer) continue;
            for (d.classes[0..@intCast(d.num_classes)]) |cl| {
                if (cl.type != XIScrollClass or s.naxes == s.axes.len) continue;
                const sc: *const ScrollClassInfo = @ptrCast(@alignCast(cl));
                if (sc.increment == 0) continue;
                s.axes[s.naxes] = .{ .number = @intCast(sc.number), .horizontal = sc.scroll_type != XIScrollTypeVertical, .increment = sc.increment };
                s.naxes += 1;
            }
        }
    }

    /// reset forgets where the valuators were: they move while the
    /// pointer is in other windows.
    pub fn reset(s: *Smooth) void {
        for (s.axes[0..s.naxes]) |*a| a.last = null;
    }

    /// scroll is how far a motion event scrolled, in notches (a fraction
    /// for a trackpad), down and right positive.
    pub fn scroll(s: *Smooth, e: *const DeviceEvent) [2]f64 {
        var d = [2]f64{ 0, 0 };
        const mask = e.valuators.mask orelse return d;
        const values = e.valuators.values orelse return d;
        var k: usize = 0;
        const bits: usize = @intCast(e.valuators.mask_len * 8);
        for (0..bits) |i| {
            if (mask[i / 8] & (@as(u8, 1) << @intCast(i % 8)) == 0) continue;
            const v = values[k];
            k += 1;
            for (s.axes[0..s.naxes]) |*a| if (a.number == i) {
                if (a.last) |last| d[@intFromBool(!a.horizontal)] += (v - last) / a.increment;
                a.last = v;
            };
        }
        return d;
    }
};

test "XI2's structs are laid out as libXi's headers say (x86_64)" {
    if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
    try std.testing.expectEqual(200, @sizeOf(DeviceEvent));
    try std.testing.expectEqual(104, @offsetOf(DeviceEvent, "event_x"));
    try std.testing.expectEqual(144, @offsetOf(DeviceEvent, "valuators"));
    try std.testing.expectEqual(168, @offsetOf(DeviceEvent, "mods"));
    try std.testing.expectEqual(32, @sizeOf(ScrollClassInfo));
    try std.testing.expectEqual(16, @offsetOf(ScrollClassInfo, "increment"));
    try std.testing.expectEqual(40, @sizeOf(DeviceInfo));
    try std.testing.expectEqual(32, @offsetOf(DeviceInfo, "classes"));
    try std.testing.expectEqual(48, @offsetOf(GenericEventCookie, "data"));
}

test "scroll valuators move by notches, from where they were" {
    var s = Smooth{ .lib = undefined, .fns = undefined, .opcode = 0 };
    s.axes[0] = .{ .number = 2, .horizontal = true, .increment = 15 };
    s.axes[1] = .{ .number = 3, .horizontal = false, .increment = 15 };
    s.naxes = 2;
    // Valuators 0 (x), 2 and 3 set.
    var mask = [_]u8{0b1101};
    var values = [_]f64{ 10, 100, 200 };
    var e = std.mem.zeroes(DeviceEvent);
    e.valuators = .{ .mask_len = 1, .mask = &mask, .values = &values };
    // The first event only says where they are.
    try std.testing.expectEqual([2]f64{ 0, 0 }, s.scroll(&e));
    values = .{ 12, 107.5, 230 };
    try std.testing.expectEqual([2]f64{ 0.5, 2 }, s.scroll(&e));
    s.reset();
    values = .{ 12, 0, 0 };
    try std.testing.expectEqual([2]f64{ 0, 0 }, s.scroll(&e));
}
