//! Wayland: a window as an xdg_toplevel, drawn with Vulkan, OpenGL (EGL)
//! or on the CPU into shared memory, paced by the compositor's frame
//! callbacks. Input comes from the seat (keys through xkbcommon, with
//! repeat done here, as Wayland leaves it to clients), text from an input
//! method through text-input-v3, the clipboard through the data device.
//! Where the compositor does not decorate windows (GNOME's), MyZig draws a
//! title bar and the window's edges resize it. libwayland-client and the
//! rest are opened at run time: a build runs where there is no Wayland.

const std = @import("std");
const sys = @import("sys.zig");
const env = @import("env.zig");
const ui = @import("ui.zig");
const text = @import("text.zig");
const scene = @import("scene.zig");
const raster = @import("raster.zig");
const geom = @import("geom.zig");
const choose = @import("gpu/choose.zig");
const backend = @import("gpu/backend.zig");
const glr = backend.glr;
const vulkan = backend.vulkan;
const Egl = @import("gpu/egl.zig").Egl;
const app = @import("app.zig");
const wl = @import("wayland/client.zig");
const p = @import("wayland/protocol.zig");
const xkb = @import("wayland/xkb.zig");

/// wanted reports whether the window should be a Wayland one: the session
/// is Wayland's, and MYZIG_BACKEND does not say x11.
pub fn wanted() bool {
    if (env.get("MYZIG_BACKEND")) |b| return std.mem.eql(u8, b, "wayland");
    return env.get("WAYLAND_DISPLAY") != null or env.get("WAYLAND_SOCKET") != null;
}

const title_h: f32 = 34;
const edge: f32 = 6;

const Output = struct {
    proxy: *p.wl_output,
    name: u32,
    scale: i32 = 1,
};

/// ShmBuffer is one of the buffers a CPU frame is copied into: the
/// compositor reads it until it releases it. missed is what changed in
/// frames it did not show.
const ShmBuffer = struct {
    buffer: ?*p.wl_buffer = null,
    pixels: []u32 = &.{},
    busy: bool = false,
    missed: geom.IRect = .{},
};

const Win = struct {
    gpa: std.mem.Allocator,
    display: *wl.Display,
    registry: *p.wl_registry = undefined,
    compositor: ?*p.wl_compositor = null,
    shm: ?*p.wl_shm = null,
    wm_base: ?*p.xdg_wm_base = null,
    seat: ?*p.wl_seat = null,
    ddm: ?*p.wl_data_device_manager = null,
    deco_mgr: ?*p.zxdg_decoration_manager_v1 = null,
    shape_mgr: ?*p.wp_cursor_shape_manager_v1 = null,
    frac_mgr: ?*p.wp_fractional_scale_manager_v1 = null,
    viewporter: ?*p.wp_viewporter = null,
    ti_mgr: ?*p.zwp_text_input_manager_v3 = null,
    outputs: [8]?Output = .{null} ** 8,

    surface: *p.wl_surface = undefined,
    xdg_surface: *p.xdg_surface = undefined,
    toplevel: *p.xdg_toplevel = undefined,
    decoration: ?*p.zxdg_toplevel_decoration_v1 = null,
    viewport: ?*p.wp_viewport = null,
    frac: ?*p.wp_fractional_scale_v1 = null,

    // The window's size in surface coordinates, and what the compositor
    // asked for in the configure being sent.
    w: i32 = 0,
    h: i32 = 0,
    /// the size the app asked for, its view's
    want_w: i32 = 0,
    want_h: i32 = 0,
    /// the size it had last when neither maximized nor tiled
    floating_w: i32 = 0,
    floating_h: i32 = 0,
    pending_w: i32 = 0,
    pending_h: i32 = 0,
    pending_max: bool = false,
    pending_full: bool = false,
    pending_tiled: bool = false,
    maximized: bool = false,
    fullscreen: bool = false,
    tiled: bool = false,
    configured: bool = false,
    reconfigured: bool = false,
    closed: bool = false,
    /// csd is set where MyZig draws the window's decorations.
    csd: bool = true,
    // Scale: an output's integer one (or the compositor's preferred), or a
    // fractional one with a viewport.
    entered: u8 = 0,
    preferred_int: i32 = 0,
    frac_120: u32 = 0,
    frame_cb: ?*p.wl_callback = null,

    // Input
    pointer: ?*p.wl_pointer = null,
    keyboard: ?*p.wl_keyboard = null,
    data_device: ?*p.wl_data_device = null,
    text_input: ?*p.zwp_text_input_v3 = null,
    shape_device: ?*p.wp_cursor_shape_device_v1 = null,
    pointer_serial: u32 = 0,
    serial: u32 = 0,
    px: f32 = -1,
    py: f32 = -1,
    inside: bool = false,
    pressed: u32 = 0,
    axis_dx: f64 = 0,
    axis_dy: f64 = 0,
    axis_120: [2]i32 = .{ 0, 0 },
    kb: ?xkb.Keyboard = null,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_key: u32 = 0,
    repeat_at: u64 = 0,
    focused: bool = false,
    // An input method's: what it composes, and what it commits, applied
    // at its done.
    ti_enabled: bool = false,
    ti_entered: bool = false,
    ti_preedit: std.ArrayListUnmanaged(u8) = .empty,
    ti_preedit_caret: usize = 0,
    ti_commit: std.ArrayListUnmanaged(u8) = .empty,
    ti_rect: [4]i32 = .{ -1, -1, -1, -1 },

    // Cursor
    cursor: ui.Cursor = .arrow,
    edge_shape: u32 = 0,
    shown_shape: u32 = 0,
    cursor_theme: CursorTheme = .{},

    // Clipboard
    offer: ?*p.wl_data_offer = null,
    offer_mime: ?[*:0]const u8 = null,
    new_offer: ?*p.wl_data_offer = null,
    new_offer_mime: ?[*:0]const u8 = null,
    source: ?*p.wl_data_source = null,
    owned: std.ArrayListUnmanaged(u8) = .empty,

    ctx: *ui.Context = undefined,
    timer: sys.Timer = undefined,
    need_frame: bool = true,

    /// decorates reports whether MyZig draws the title bar now.
    fn decorates(w: *const Win) bool {
        return w.csd and !w.fullscreen;
    }

    fn scale(w: *const Win) f32 {
        if (w.frac_120 != 0 and w.viewport != null) return @as(f32, @floatFromInt(w.frac_120)) / 120;
        return @floatFromInt(w.intScale());
    }

    fn intScale(w: *const Win) i32 {
        if (w.preferred_int > 0) return w.preferred_int;
        var s: i32 = 1;
        for (w.outputs, 0..) |o, i| if (o) |out| {
            if (w.entered & (@as(u8, 1) << @intCast(i)) != 0) s = @max(s, out.scale);
        };
        return s;
    }

    /// pixels is the window's size in buffer pixels.
    fn pixels(w: *const Win) [2]i32 {
        const s = w.scale();
        return .{
            @intFromFloat(@round(@as(f32, @floatFromInt(w.w)) * s)),
            @intFromFloat(@round(@as(f32, @floatFromInt(w.h)) * s)),
        };
    }

    fn now(w: *Win) u64 {
        return w.timer.read();
    }
};

// ---- the registry ----

fn eql(a: ?[*:0]const u8, b: [*:0]const u8) bool {
    return std.mem.orderZ(u8, a orelse return false, b) == .eq;
}

fn onRegistry(reg: *p.wl_registry, ev: p.wl_registry.Event, w: *Win) void {
    switch (ev) {
        .global => |g| {
            const iface = g.interface;
            if (eql(iface, "wl_compositor")) {
                w.compositor = reg.bind(g.name, p.wl_compositor, @min(g.version, 6));
            } else if (eql(iface, "wl_shm")) {
                w.shm = reg.bind(g.name, p.wl_shm, 1);
            } else if (eql(iface, "xdg_wm_base")) {
                w.wm_base = reg.bind(g.name, p.xdg_wm_base, @min(g.version, 6));
                if (w.wm_base) |b| b.setListener(*Win, onWmBase, w);
            } else if (eql(iface, "wl_seat")) {
                if (w.seat == null) {
                    w.seat = reg.bind(g.name, p.wl_seat, @min(g.version, 8));
                    if (w.seat) |s| s.setListener(*Win, onSeat, w);
                }
            } else if (eql(iface, "wl_data_device_manager")) {
                w.ddm = reg.bind(g.name, p.wl_data_device_manager, @min(g.version, 3));
            } else if (eql(iface, "zxdg_decoration_manager_v1")) {
                w.deco_mgr = reg.bind(g.name, p.zxdg_decoration_manager_v1, 1);
            } else if (eql(iface, "wp_cursor_shape_manager_v1")) {
                w.shape_mgr = reg.bind(g.name, p.wp_cursor_shape_manager_v1, 1);
            } else if (eql(iface, "wp_fractional_scale_manager_v1")) {
                w.frac_mgr = reg.bind(g.name, p.wp_fractional_scale_manager_v1, 1);
            } else if (eql(iface, "wp_viewporter")) {
                w.viewporter = reg.bind(g.name, p.wp_viewporter, 1);
            } else if (eql(iface, "zwp_text_input_manager_v3")) {
                w.ti_mgr = reg.bind(g.name, p.zwp_text_input_manager_v3, 1);
            } else if (eql(iface, "wl_output")) {
                for (&w.outputs) |*slot| if (slot.* == null) {
                    const o = reg.bind(g.name, p.wl_output, @min(g.version, 2)) orelse break;
                    slot.* = .{ .proxy = o, .name = g.name };
                    o.setListener(*Win, onOutput, w);
                    break;
                };
            }
        },
        .global_remove => |g| {
            for (&w.outputs, 0..) |*slot, i| if (slot.*) |o| if (o.name == g.name) {
                o.proxy.destroy();
                slot.* = null;
                w.entered &= ~(@as(u8, 1) << @intCast(i));
                w.need_frame = true;
            };
        },
    }
}

fn onWmBase(b: *p.xdg_wm_base, ev: p.xdg_wm_base.Event, _: *Win) void {
    switch (ev) {
        .ping => |e| b.pong(e.serial),
    }
}

fn onOutput(o: *p.wl_output, ev: p.wl_output.Event, w: *Win) void {
    switch (ev) {
        .scale => |e| for (&w.outputs) |*slot| if (slot.*) |*out| if (out.proxy == o) {
            out.scale = e.factor;
            w.need_frame = true;
        },
        else => {},
    }
}

// ---- the window ----

fn onSurface(_: *p.wl_surface, ev: p.wl_surface.Event, w: *Win) void {
    switch (ev) {
        .enter => |e| for (w.outputs, 0..) |o, i| if (o) |out| if (@as(?*p.wl_output, out.proxy) == e.output) {
            w.entered |= @as(u8, 1) << @intCast(i);
            w.need_frame = true;
        },
        .leave => |e| for (w.outputs, 0..) |o, i| if (o) |out| if (@as(?*p.wl_output, out.proxy) == e.output) {
            w.entered &= ~(@as(u8, 1) << @intCast(i));
            w.need_frame = true;
        },
        .preferred_buffer_scale => |e| {
            w.preferred_int = e.factor;
            w.need_frame = true;
        },
        .preferred_buffer_transform => {},
    }
}

fn onFractional(_: *p.wp_fractional_scale_v1, ev: p.wp_fractional_scale_v1.Event, w: *Win) void {
    switch (ev) {
        .preferred_scale => |e| {
            w.frac_120 = e.scale;
            w.need_frame = true;
        },
    }
}

fn onXdgSurface(s: *p.xdg_surface, ev: p.xdg_surface.Event, w: *Win) void {
    switch (ev) {
        .configure => |e| {
            s.ack_configure(e.serial);
            w.maximized = w.pending_max;
            w.fullscreen = w.pending_full;
            // A size of 0 is the window's to choose: the one it had before
            // it was maximized, or at first the view's and the title bar
            // over it.
            const free = !w.maximized and !w.fullscreen and !w.tiled;
            if (w.pending_w > 0) w.w = w.pending_w else if (!w.configured) w.w = w.want_w else if (free and w.floating_w > 0) w.w = w.floating_w;
            if (w.pending_h > 0) w.h = w.pending_h else if (!w.configured) w.h = w.want_h + if (w.decorates()) @as(i32, @intFromFloat(title_h)) else 0 else if (free and w.floating_h > 0) w.h = w.floating_h;
            if (free) {
                w.floating_w = w.w;
                w.floating_h = w.h;
            }
            w.tiled = w.pending_tiled;
            w.configured = true;
            w.reconfigured = true;
            w.need_frame = true;
        },
    }
}

fn onToplevel(_: *p.xdg_toplevel, ev: p.xdg_toplevel.Event, w: *Win) void {
    switch (ev) {
        .configure => |e| {
            w.pending_w = e.width;
            w.pending_h = e.height;
            w.pending_max = false;
            w.pending_full = false;
            w.pending_tiled = false;
            for (e.states.slice(u32)) |st| switch (st) {
                p.xdg_toplevel.State.maximized => w.pending_max = true,
                p.xdg_toplevel.State.fullscreen => w.pending_full = true,
                p.xdg_toplevel.State.tiled_left, p.xdg_toplevel.State.tiled_right, p.xdg_toplevel.State.tiled_top, p.xdg_toplevel.State.tiled_bottom => w.pending_tiled = true,
                else => {},
            };
        },
        .close => w.closed = true,
        else => {},
    }
}

fn onDecoration(_: *p.zxdg_toplevel_decoration_v1, ev: p.zxdg_toplevel_decoration_v1.Event, w: *Win) void {
    switch (ev) {
        .configure => |e| {
            const csd = e.mode == p.zxdg_toplevel_decoration_v1.Mode.client_side;
            if (csd != w.csd) w.need_frame = true;
            w.csd = csd;
        },
    }
}

fn onFrame(cb: *p.wl_callback, _: p.wl_callback.Event, w: *Win) void {
    cb.destroy();
    if (w.frame_cb == cb) w.frame_cb = null;
}

// ---- input ----

fn onSeat(s: *p.wl_seat, ev: p.wl_seat.Event, w: *Win) void {
    switch (ev) {
        .capabilities => |e| {
            const caps = e.capabilities;
            if (caps & p.wl_seat.Capability.pointer != 0 and w.pointer == null) {
                w.pointer = s.get_pointer();
                if (w.pointer) |ptr| {
                    ptr.setListener(*Win, onPointer, w);
                    if (w.shape_mgr) |m| w.shape_device = m.get_pointer(ptr);
                }
            }
            if (caps & p.wl_seat.Capability.keyboard != 0 and w.keyboard == null) {
                w.keyboard = s.get_keyboard();
                if (w.keyboard) |k| k.setListener(*Win, onKeyboard, w);
            }
        },
        .name => {},
    }
}

fn buttonOf(code: u32) ?ui.MouseButton {
    return switch (code) {
        0x110 => .left,
        0x111 => .right,
        0x112 => .middle,
        0x113, 0x116 => .back,
        0x114, 0x115 => .forward,
        else => null,
    };
}

/// edgeAt is the edge (xdg_toplevel's resize_edge) of a decorated window
/// at x, y, or 0.
fn edgeAt(w: *const Win, x: f32, y: f32) u32 {
    if (!w.decorates() or w.maximized or w.tiled) return 0;
    const fw: f32 = @floatFromInt(w.w);
    const fh: f32 = @floatFromInt(w.h);
    const E = p.xdg_toplevel.ResizeEdge;
    var e: u32 = 0;
    if (y < edge) e |= E.top else if (y >= fh - edge) e |= E.bottom;
    if (x < edge) e |= E.left else if (x >= fw - edge) e |= E.right;
    return e;
}

fn shapeOfEdge(e: u32) u32 {
    const E = p.xdg_toplevel.ResizeEdge;
    const S = p.wp_cursor_shape_device_v1.Shape;
    return switch (e) {
        E.top => S.n_resize,
        E.bottom => S.s_resize,
        E.left => S.w_resize,
        E.right => S.e_resize,
        E.top_left => S.nw_resize,
        E.top_right => S.ne_resize,
        E.bottom_left => S.sw_resize,
        E.bottom_right => S.se_resize,
        else => 0,
    };
}

fn onPointer(_: *p.wl_pointer, ev: p.wl_pointer.Event, w: *Win) void {
    switch (ev) {
        .enter => |e| {
            w.pointer_serial = e.serial;
            w.inside = true;
            w.shown_shape = 0;
            w.px = @floatCast(e.surface_x);
            w.py = @floatCast(e.surface_y);
            if (w.ctx.pointerMove(w.px, w.py)) w.need_frame = true;
            updateCursor(w);
        },
        .leave => {
            w.inside = false;
            if (w.ctx.pointerMove(-1, -1)) w.need_frame = true;
        },
        .motion => |e| {
            w.px = @floatCast(e.surface_x);
            w.py = @floatCast(e.surface_y);
            if (w.ctx.pointerMove(w.px, w.py)) w.need_frame = true;
            w.edge_shape = shapeOfEdge(edgeAt(w, w.px, w.py));
            updateCursor(w);
        },
        .button => |e| {
            w.serial = e.serial;
            const b = buttonOf(e.button) orelse return;
            const down = e.state == p.wl_pointer.ButtonState.pressed;
            if (down and w.decorates()) {
                // The window's edges resize it, its title bar moves it.
                const ed = edgeAt(w, w.px, w.py);
                if (b == .left and ed != 0) {
                    if (w.seat) |s| w.toplevel.resize(s, e.serial, ed);
                    return;
                }
                if (w.py < title_h and w.ctx.input.hot == 0) {
                    if (b == .right) {
                        if (w.seat) |s| w.toplevel.show_window_menu(s, e.serial, @intFromFloat(w.px), @intFromFloat(w.py));
                        return;
                    }
                    if (b == .left) {
                        if (titleDoubleClick(w)) {
                            if (w.maximized) w.toplevel.unset_maximized() else w.toplevel.set_maximized();
                        } else if (w.seat) |s| w.toplevel.move(s, e.serial);
                        return;
                    }
                }
            }
            if (down) {
                w.pressed += 1;
                if (w.ctx.pointerPress(w.px, w.py, b, 0)) w.need_frame = true;
            } else {
                if (w.pressed > 0) w.pressed -= 1;
                if (w.ctx.pointerRelease(w.px, w.py, b)) w.need_frame = true;
            }
        },
        .axis => |e| {
            if (e.axis == p.wl_pointer.Axis.vertical_scroll) w.axis_dy += e.value else w.axis_dx += e.value;
        },
        .axis_value120 => |e| {
            w.axis_120[if (e.axis == p.wl_pointer.Axis.vertical_scroll) 1 else 0] += e.value120;
        },
        // Before version 8, a wheel's notches.
        .axis_discrete => |e| {
            w.axis_120[if (e.axis == p.wl_pointer.Axis.vertical_scroll) 1 else 0] += e.discrete * 120;
        },
        .frame => {
            // Smooth deltas are in surface pixels already; a wheel's go by
            // its notches.
            var dx: f32 = @floatCast(w.axis_dx);
            var dy: f32 = @floatCast(w.axis_dy);
            if (w.axis_120[0] != 0) dx = @as(f32, @floatFromInt(w.axis_120[0])) / 120 * 48;
            if (w.axis_120[1] != 0) dy = @as(f32, @floatFromInt(w.axis_120[1])) / 120 * 48;
            w.axis_dx = 0;
            w.axis_dy = 0;
            w.axis_120 = .{ 0, 0 };
            if (dx != 0 or dy != 0) {
                if (w.kb) |k| if (k.mods.shift and dx == 0) {
                    dx = dy;
                    dy = 0;
                };
                if (w.ctx.scrollXY(w.px, w.py, dx, dy)) w.need_frame = true;
            }
        },
        else => {},
    }
}

var last_title_click: u64 = 0;

fn titleDoubleClick(w: *Win) bool {
    const t = w.now();
    const double = t - last_title_click < 400 * std.time.ns_per_ms;
    last_title_click = if (double) 0 else t;
    return double;
}

fn onKeyboard(_: *p.wl_keyboard, ev: p.wl_keyboard.Event, w: *Win) void {
    switch (ev) {
        .keymap => |e| {
            if (e.format != p.wl_keyboard.KeymapFormat.xkb_v1) {
                sys.close(e.fd);
                return;
            }
            if (w.kb == null) w.kb = xkb.Keyboard.open() catch |err| {
                sys.log(.warn, "myzig: no xkbcommon ({s}); the keyboard does nothing", .{@errorName(err)});
                sys.close(e.fd);
                return;
            };
            w.kb.?.setKeymap(e.fd, e.size);
        },
        .enter => |e| {
            w.serial = e.serial;
            w.focused = true;
        },
        .leave => {
            w.focused = false;
            w.repeat_key = 0;
        },
        .key => |e| {
            w.serial = e.serial;
            if (e.state == p.wl_keyboard.KeyState.pressed) {
                const repeats = keyPress(w, e.key);
                if (repeats and w.repeat_rate > 0) {
                    w.repeat_key = e.key;
                    w.repeat_at = w.now() + @as(u64, @intCast(w.repeat_delay)) * std.time.ns_per_ms;
                }
            } else if (e.key == w.repeat_key) {
                w.repeat_key = 0;
            }
        },
        .modifiers => |e| if (w.kb) |*k| {
            k.updateMods(e.mods_depressed, e.mods_latched, e.mods_locked, e.group);
            w.ctx.setMods(.{ .shift = k.mods.shift, .ctrl = k.mods.ctrl, .alt = k.mods.alt, .super = k.mods.super });
        },
        .repeat_info => |e| {
            w.repeat_rate = e.rate;
            w.repeat_delay = e.delay;
        },
    }
}

/// keyPress gives the view the key and its text; it reports whether the
/// key repeats.
fn keyPress(w: *Win, key: u32) bool {
    const k = if (w.kb) |*kb| kb else return false;
    var buf: [64]u8 = undefined;
    const press = k.press(key, &buf);
    const mods: ui.Mods = .{ .shift = k.mods.shift, .ctrl = k.mods.ctrl, .alt = k.mods.alt, .super = k.mods.super };
    if (w.ctx.keyDownMods(app.mapKey(press.sym), mods)) w.need_frame = true;
    if (press.len > 0 and !mods.ctrl and !mods.alt and !mods.super) {
        if (w.ctx.typeText(buf[0..press.len])) w.need_frame = true;
    }
    return press.repeats;
}

fn onTextInput(ti: *p.zwp_text_input_v3, ev: p.zwp_text_input_v3.Event, w: *Win) void {
    switch (ev) {
        .enter => {
            w.ti_entered = true;
            w.ti_enabled = false;
            syncTextInput(w);
        },
        .leave => {
            w.ti_entered = false;
            if (w.ti_enabled) {
                ti.disable();
                ti.commit();
            }
            w.ti_enabled = false;
            if (w.ctx.setPreedit("", 0)) w.need_frame = true;
        },
        .preedit_string => |e| {
            w.ti_preedit.clearRetainingCapacity();
            if (e.text) |t| w.ti_preedit.appendSlice(w.gpa, std.mem.span(t)) catch {};
            w.ti_preedit_caret = if (e.cursor_begin >= 0) @intCast(e.cursor_begin) else w.ti_preedit.items.len;
        },
        .commit_string => |e| {
            w.ti_commit.clearRetainingCapacity();
            if (e.text) |t| w.ti_commit.appendSlice(w.gpa, std.mem.span(t)) catch {};
        },
        .delete_surrounding_text => {},
        .done => {
            // What was committed is typed; what composes shows.
            if (w.ti_commit.items.len > 0) {
                if (w.ctx.typeText(w.ti_commit.items)) w.need_frame = true;
                w.ti_commit.clearRetainingCapacity();
            }
            if (w.ctx.setPreedit(w.ti_preedit.items, w.ti_preedit_caret)) w.need_frame = true;
            w.ti_preedit.clearRetainingCapacity();
        },
    }
}

/// syncTextInput turns the input method on while a text input has the
/// focus, and tells it where the caret is.
fn syncTextInput(w: *Win) void {
    const ti = w.text_input orelse return;
    if (!w.ti_entered) return;
    const want = w.ctx.input.text_focus;
    if (want != w.ti_enabled) {
        if (want) {
            ti.enable();
            const P = p.zwp_text_input_v3.ContentPurpose;
            ti.set_content_type(0, P.normal);
            w.ti_rect = .{ -1, -1, -1, -1 };
        } else ti.disable();
        w.ti_enabled = want;
        if (!want) {
            ti.commit();
            return;
        }
    }
    if (!want) return;
    const r = w.ctx.ime_rect orelse return;
    const rect = [4]i32{ @intFromFloat(r.x), @intFromFloat(r.y), @max(1, @as(i32, @intFromFloat(r.w))), @max(1, @as(i32, @intFromFloat(r.h))) };
    if (std.mem.eql(i32, &rect, &w.ti_rect)) return;
    w.ti_rect = rect;
    ti.set_cursor_rectangle(rect[0], rect[1], rect[2], rect[3]);
    ti.commit();
}

// ---- the cursor ----

/// CursorTheme draws the pointer from the cursor theme, through
/// libwayland-cursor, where the compositor has no cursor shapes.
const CursorTheme = struct {
    dl: ?std.DynLib = null,
    tried: bool = false,
    load: *const fn (?[*:0]const u8, c_int, *p.wl_shm) callconv(.c) ?*anyopaque = undefined,
    get: *const fn (*anyopaque, [*:0]const u8) callconv(.c) ?*Cursor = undefined,
    buffer: *const fn (*Image) callconv(.c) ?*p.wl_buffer = undefined,
    theme: ?*anyopaque = null,
    theme_scale: i32 = 0,
    surface: ?*p.wl_surface = null,

    const Image = extern struct { width: u32, height: u32, hotspot_x: u32, hotspot_y: u32, delay: u32 };
    const Cursor = extern struct { image_count: c_uint, images: [*]*Image, name: [*:0]const u8 };

    fn open(t: *CursorTheme) bool {
        if (t.tried) return t.dl != null;
        t.tried = true;
        var dl = std.DynLib.open("libwayland-cursor.so.0") catch return false;
        t.load = dl.lookup(@FieldType(CursorTheme, "load"), "wl_cursor_theme_load") orelse return false;
        t.get = dl.lookup(@FieldType(CursorTheme, "get"), "wl_cursor_theme_get_cursor") orelse return false;
        t.buffer = dl.lookup(@FieldType(CursorTheme, "buffer"), "wl_cursor_image_get_buffer") orelse return false;
        t.dl = dl;
        return true;
    }
};

fn shapeName(shape: u32) [*:0]const u8 {
    const S = p.wp_cursor_shape_device_v1.Shape;
    return switch (shape) {
        S.text => "xterm",
        S.pointer => "hand2",
        S.n_resize => "top_side",
        S.s_resize => "bottom_side",
        S.w_resize => "left_side",
        S.e_resize => "right_side",
        S.nw_resize => "top_left_corner",
        S.ne_resize => "top_right_corner",
        S.sw_resize => "bottom_left_corner",
        S.se_resize => "bottom_right_corner",
        else => "left_ptr",
    };
}

fn updateCursor(w: *Win) void {
    if (!w.inside) return;
    const S = p.wp_cursor_shape_device_v1.Shape;
    const shape: u32 = if (w.edge_shape != 0) w.edge_shape else switch (w.cursor) {
        .arrow => S.default,
        .text => S.text,
        .pointer => S.pointer,
    };
    if (shape == w.shown_shape) return;
    w.shown_shape = shape;
    if (w.shape_device) |d| {
        d.set_shape(w.pointer_serial, shape);
        return;
    }
    const ptr = w.pointer orelse return;
    const t = &w.cursor_theme;
    const shm = w.shm orelse return;
    if (!t.open()) return;
    const s = w.intScale();
    if (t.theme == null or t.theme_scale != s) {
        const size: i32 = if (env.get("XCURSOR_SIZE")) |v| std.fmt.parseInt(i32, v, 10) catch 24 else 24;
        const name: ?[*:0]const u8 = if (env.get("XCURSOR_THEME")) |v| v.ptr else null;
        t.theme = t.load(name, size * s, shm);
        t.theme_scale = s;
    }
    const theme = t.theme orelse return;
    const cur = t.get(theme, shapeName(shape)) orelse t.get(theme, "left_ptr") orelse return;
    const img = cur.images[0];
    const buf = t.buffer(img) orelse return;
    if (t.surface == null) t.surface = w.compositor.?.create_surface();
    const cs = t.surface orelse return;
    cs.set_buffer_scale(s);
    cs.attach(buf, 0, 0);
    cs.damage_buffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    cs.commit();
    ptr.set_cursor(w.pointer_serial, cs, @divTrunc(@as(i32, @intCast(img.hotspot_x)), s), @divTrunc(@as(i32, @intCast(img.hotspot_y)), s));
}

// ---- the clipboard ----

fn onDataDevice(_: *p.wl_data_device, ev: p.wl_data_device.Event, w: *Win) void {
    switch (ev) {
        .data_offer => |e| {
            w.new_offer = e.id;
            w.new_offer_mime = null;
            e.id.setListener(*Win, onOffer, w);
        },
        .selection => |e| {
            if (w.offer) |o| if (@as(?*p.wl_data_offer, o) != e.id) o.destroy();
            w.offer = e.id;
            w.offer_mime = if (e.id != null and e.id == w.new_offer) w.new_offer_mime else null;
        },
        // Drag and drop offers are not taken (yet).
        .enter => |e| if (e.id) |o| if (o != w.offer) o.destroy(),
        else => {},
    }
}

const text_mimes = [_][:0]const u8{ "text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING" };

fn onOffer(o: *p.wl_data_offer, ev: p.wl_data_offer.Event, w: *Win) void {
    switch (ev) {
        .offer => |e| if (o == w.new_offer) {
            // The best text type it offers.
            for (text_mimes, 0..) |m, rank| if (eql(e.mime_type, m.ptr)) {
                const cur = w.new_offer_mime;
                var better = cur == null;
                if (cur) |c| for (text_mimes, 0..) |m2, r2| if (eql(c, m2.ptr)) {
                    better = rank < r2;
                };
                if (better) w.new_offer_mime = m.ptr;
            };
        },
        else => {},
    }
}

fn onSource(src: *p.wl_data_source, ev: p.wl_data_source.Event, w: *Win) void {
    switch (ev) {
        .send => |e| {
            // Written whole, then closed: the reader takes it at its pace.
            var off: usize = 0;
            while (off < w.owned.items.len) {
                const n = sys.write(e.fd, w.owned.items[off..]) catch break;
                if (n == 0) break;
                off += n;
            }
            sys.close(e.fd);
        },
        .cancelled => {
            src.destroy();
            if (w.source == src) {
                w.source = null;
                w.owned.clearRetainingCapacity();
            }
        },
        else => {},
    }
}

fn clipSet(ctx: *anyopaque, s: []const u8) void {
    const w: *Win = @ptrCast(@alignCast(ctx));
    const ddm = w.ddm orelse return;
    const dev = w.data_device orelse return;
    w.owned.clearRetainingCapacity();
    w.owned.appendSlice(w.gpa, s) catch return;
    if (w.source) |old| old.destroy();
    const src = ddm.create_data_source() orelse return;
    for (text_mimes) |m| src.offer(m.ptr);
    src.setListener(*Win, onSource, w);
    dev.set_selection(src, w.serial);
    w.source = src;
}

fn clipGet(ctx: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    const w: *Win = @ptrCast(@alignCast(ctx));
    // Its own selection: the compositor would ask this very loop for it.
    if (w.source != null) return gpa.dupe(u8, w.owned.items) catch null;
    const offer = w.offer orelse return null;
    const mime = w.offer_mime orelse return null;
    const fds = sys.pipe() catch return null;
    offer.receive(mime, fds[1]);
    sys.close(fds[1]);
    _ = wl.lib.display_flush(w.display);
    defer sys.close(fds[0]);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [64 << 10]u8 = undefined;
    while (true) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, 2000) catch break;
        if (ready == 0) break; // the source went quiet
        const n = std.posix.read(fds[0], &buf) catch break;
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..n]) catch break;
    }
    return out.toOwnedSlice(gpa) catch null;
}

// ---- drawing on the CPU ----

/// openGpu opens the GPU renderer choice names for surface: Vulkan's,
/// else OpenGL's through EGL, each unloaded before the next is tried.
fn openGpu(gpa: std.mem.Allocator, display: *wl.Display, surface: *p.wl_surface, size: [2]i32, choice: choose.Choice, uncapped: bool, egl: *?Egl) ?backend.Gpu {
    if (choice.kind == .vulkan) vk: {
        const r = vulkan.Renderer.init(gpa, .{ .wayland = .{ .display = @ptrCast(display), .surface = @ptrCast(surface) } }, size[0], size[1], .{
            .vsync = !uncapped,
            .validation = env.has("MYZIG_VK_VALIDATION"),
        }) catch |e| {
            sys.log(.warn, "myzig: no Vulkan ({s})", .{@errorName(e)});
            break :vk;
        };
        return .{ .vulkan = r };
    }
    if (choice.kind != .gl and (choice.kind != .vulkan or choice.forced)) return null;
    var e = Egl.open() catch return null;
    const r = gl: {
        e.context(@ptrCast(display), @ptrCast(surface), size[0], size[1]) catch |err| {
            sys.log(.warn, "myzig: no OpenGL context ({s}); drawing on the CPU", .{@errorName(err)});
            break :gl null;
        };
        const gl = glr.Gl.load(&e, Egl.proc) catch break :gl null;
        break :gl glr.Renderer.init(gpa, gl) catch null;
    };
    if (r == null) {
        e.close();
        return null;
    }
    egl.* = e;
    return .{ .gl = r.? };
}

const Shm = struct {
    pool: ?*p.wl_shm_pool = null,
    map: []align(std.heap.page_size_min) u8 = &.{},
    bufs: [3]ShmBuffer = .{ .{}, .{}, .{} },
    width: i32 = 0,
    height: i32 = 0,
    canvas: []u32 = &.{},

    fn deinit(s: *Shm, gpa: std.mem.Allocator) void {
        for (&s.bufs) |*b| if (b.buffer) |bb| bb.destroy();
        if (s.pool) |pl| pl.destroy();
        if (s.map.len > 0) std.posix.munmap(s.map);
        if (s.canvas.len > 0) gpa.free(s.canvas);
        s.* = .{};
    }

    fn resize(s: *Shm, gpa: std.mem.Allocator, shm: *p.wl_shm, w: *Win, width: i32, height: i32) !void {
        if (width == s.width and height == s.height and s.pool != null) return;
        s.deinit(gpa);
        const size: usize = @intCast(width * height * 4);
        const fd = try std.posix.memfd_create("myzig", std.os.linux.MFD.CLOEXEC);
        defer sys.close(fd);
        try sys.ftruncate(fd, size * s.bufs.len);
        s.map = try std.posix.mmap(null, size * s.bufs.len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
        s.pool = shm.create_pool(fd, @intCast(size * s.bufs.len));
        const all: [*]u32 = @ptrCast(s.map.ptr);
        for (&s.bufs, 0..) |*b, i| {
            b.buffer = s.pool.?.create_buffer(@intCast(size * i), width, height, width * 4, p.wl_shm.Format.xrgb8888);
            b.pixels = all[size / 4 * i ..][0 .. size / 4];
            b.busy = false;
            b.missed = .{ .x0 = 0, .y0 = 0, .x1 = width, .y1 = height };
            if (b.buffer) |bb| bb.setListener(*Win, onBufferRelease, w);
        }
        s.canvas = try gpa.alloc(u32, size / 4);
        s.width = width;
        s.height = height;
    }

    fn free(s: *Shm) ?*ShmBuffer {
        for (&s.bufs) |*b| if (!b.busy and b.buffer != null) return b;
        return null;
    }
};

var shm_state: ?*Shm = null;

fn onBufferRelease(b: *p.wl_buffer, _: p.wl_buffer.Event, _: *Win) void {
    const s = shm_state orelse return;
    for (&s.bufs) |*sb| if (sb.buffer == b) {
        sb.busy = false;
    };
}

fn unite(a: geom.IRect, b: geom.IRect) geom.IRect {
    if (a.isEmpty()) return b;
    if (b.isEmpty()) return a;
    return .{ .x0 = @min(a.x0, b.x0), .y0 = @min(a.y0, b.y0), .x1 = @max(a.x1, b.x1), .y1 = @max(a.y1, b.y1) };
}

fn copyRect(dst: []u32, src: []const u32, stride: usize, r: geom.IRect) void {
    if (r.isEmpty()) return;
    var y: usize = @intCast(r.y0);
    while (y < @as(usize, @intCast(r.y1))) : (y += 1) {
        const a = y * stride + @as(usize, @intCast(r.x0));
        const b = y * stride + @as(usize, @intCast(r.x1));
        @memcpy(dst[a..b], src[a..b]);
    }
}

// ---- the title bar ----

/// Shell is the view with MyZig's title bar over it, where the window
/// decorates itself.
fn Shell(comptime S: type, comptime view: fn (S, *ui.Context) void) type {
    return struct {
        state: S,
        win: *Win,
        title: []const u8,

        fn build(sh: *@This(), c: *ui.Context) void {
            if (!sh.win.decorates()) return view(sh.state, c);
            const t = c.theme;
            c.column(.{ .fill = true, .@"align" = .stretch, .border = 1, .border_color = t.border });
            defer c.end();
            {
                c.row(.{ .height = title_h, .padding_x = 10, .gap = 4, .@"align" = .center, .background = t.surface });
                defer c.end();
                c.text(sh.title, .{ .bold = true });
                c.spacer();
                if (c.button("\u{2013}", .{ .key = "myzig.minimize" })) sh.win.toplevel.set_minimized();
                if (c.button("\u{25A1}", .{ .key = "myzig.maximize" })) {
                    if (sh.win.maximized) sh.win.toplevel.unset_maximized() else sh.win.toplevel.set_maximized();
                }
                if (c.button("\u{00D7}", .{ .key = "myzig.close" })) sh.win.closed = true;
            }
            c.column(.{ .grow = 1, .@"align" = .stretch, .clip = true });
            defer c.end();
            view(sh.state, c);
        }
    };
}

// ---- the loop ----

pub fn run(state: anytype, comptime view: fn (@TypeOf(state), *ui.Context) void, opts: app.WindowOptions) !void {
    const gpa = std.heap.c_allocator;
    const display = wl.connect() catch return error.NoWayland;
    defer wl.lib.display_disconnect(display);
    var w = Win{ .gpa = gpa, .display = display };
    w.timer = try sys.Timer.start();
    var fonts = try text.Fonts.init(gpa);
    defer fonts.deinit();
    var ctx = ui.Context.init(gpa, &fonts);
    defer ctx.deinit();
    w.ctx = &ctx;
    defer if (w.kb) |*k| k.deinit();
    defer w.ti_preedit.deinit(gpa);
    defer w.ti_commit.deinit(gpa);
    defer w.owned.deinit(gpa);

    const wdpy: *p.wl_display = @ptrCast(display);
    w.registry = wdpy.get_registry() orelse return error.NoRegistry;
    w.registry.setListener(*Win, onRegistry, &w);
    if (wl.lib.display_roundtrip(display) < 0) return error.WaylandRoundtrip;
    const compositor = w.compositor orelse return error.NoCompositor;
    const wm_base = w.wm_base orelse return error.NoXdgShell;
    // The seat's capabilities, and the outputs' scales.
    _ = wl.lib.display_roundtrip(display);

    w.surface = compositor.create_surface() orelse return error.NoSurface;
    w.surface.setListener(*Win, onSurface, &w);
    if (w.frac_mgr != null and w.viewporter != null) {
        w.frac = w.frac_mgr.?.get_fractional_scale(w.surface);
        w.viewport = w.viewporter.?.get_viewport(w.surface);
        if (w.frac) |f| f.setListener(*Win, onFractional, &w);
    }
    w.xdg_surface = wm_base.get_xdg_surface(w.surface) orelse return error.NoXdgSurface;
    w.xdg_surface.setListener(*Win, onXdgSurface, &w);
    w.toplevel = w.xdg_surface.get_toplevel() orelse return error.NoToplevel;
    w.toplevel.setListener(*Win, onToplevel, &w);
    w.toplevel.set_title(opts.title.ptr);
    var exe_buf: [4096]u8 = undefined;
    const exe = sys.exeName(&exe_buf);
    var app_id_buf: [64]u8 = undefined;
    const app_id = std.fmt.bufPrintZ(&app_id_buf, "{s}", .{exe[0..@min(exe.len, 60)]}) catch "myzig";
    w.toplevel.set_app_id(app_id.ptr);
    w.toplevel.set_min_size(160, 120);
    // MYZIG_CSD=1 draws MyZig's title bar where the compositor would decorate.
    if (w.deco_mgr) |m| if (env.get("MYZIG_CSD") == null) {
        w.decoration = m.get_toplevel_decoration(w.toplevel);
        if (w.decoration) |d| {
            d.setListener(*Win, onDecoration, &w);
            d.set_mode(p.zxdg_toplevel_decoration_v1.Mode.server_side);
        }
    };
    if (w.seat) |s| {
        if (w.ddm) |m| {
            w.data_device = m.get_data_device(s);
            if (w.data_device) |d| d.setListener(*Win, onDataDevice, &w);
        }
        if (w.ti_mgr) |m| {
            w.text_input = m.get_text_input(s);
            if (w.text_input) |t| t.setListener(*Win, onTextInput, &w);
        }
    }
    w.want_w = @intCast(opts.width);
    w.want_h = @intCast(opts.height);
    w.surface.commit();
    // The decoration's mode comes with the first configure: the window's
    // size waits for both.
    while (!w.configured) if (wl.lib.display_roundtrip(display) < 0) return error.WaylandRoundtrip;
    defer {
        if (w.decoration) |d| d.destroy();
        w.toplevel.destroy();
        w.xdg_surface.destroy();
        if (w.viewport) |v| v.destroy();
        if (w.frac) |f| f.destroy();
        w.surface.destroy();
        _ = wl.lib.display_flush(display);
    }

    ctx.clipboard = .{ .ctx = @ptrCast(&w), .get = clipGet, .set = clipSet };

    const uncapped = env.get("MYZIG_UNCAPPED") != null;
    const print_stats = env.get("MYZIG_STATS") != null;
    const exit_after_ns: ?u64 = if (env.get("MYZIG_EXIT_AFTER")) |s| @intFromFloat((std.fmt.parseFloat(f64, s) catch 0) * 1e9) else null;
    const dump = env.get("MYZIG_DUMP");

    var sc = scene.Scene{ .gpa = gpa };
    defer sc.deinit();
    var rend = scene.Renderer{ .gpa = gpa };
    defer rend.deinit();
    var shm = Shm{};
    shm_state = &shm;
    defer shm.deinit(gpa);

    // The GPU renderer: Vulkan's, else OpenGL's through EGL.
    const choice = choose.choose(opts.renderer);
    var size = w.pixels();
    var gpu: ?backend.Gpu = null;
    defer if (gpu) |*g| g.deinit();
    var egl: ?Egl = null;
    defer if (egl) |*e| e.close();
    if (choice.kind != .cpu) gpu = openGpu(gpa, display, w.surface, size, choice, uncapped, &egl);
    if (print_stats) sys.print("myzig: Wayland{s}, {s}\n", .{ if (w.csd) " (MyZig's decorations)" else "", if (gpu) |*g| g.api() else "drawing on the CPU" });
    if (gpu != null) {
        rend.raster = false;
        rend.retain_pixels = false;
    }
    if (dump != null) if (gpu) |*g| g.capture();

    const Sh = Shell(@TypeOf(state), view);
    var shell = Sh{ .state = state, .win = &w, .title = opts.title };

    var stats = app.Stats{};
    var window_stats = app.Stats{};
    var last_print: u64 = 0;
    const fd = wl.lib.display_get_fd(display);
    var drawn_scale: f32 = 0;

    while (!w.closed) {
        _ = wl.lib.display_dispatch_pending(display);
        if (wl.lib.display_get_error(display) != 0) return error.WaylandConnectionLost;
        const now = w.now();
        if (exit_after_ns) |limit| if (now >= limit) {
            if (print_stats) app.printStats("final", stats, now);
            return;
        };
        if (print_stats and now - last_print >= std.time.ns_per_s) {
            const d = app.Stats{
                .frames = stats.frames - window_stats.frames,
                .build_ns = stats.build_ns - window_stats.build_ns,
                .raster_ns = stats.raster_ns - window_stats.raster_ns,
                .present_ns = stats.present_ns - window_stats.present_ns,
                .pixels = stats.pixels - window_stats.pixels,
            };
            app.printStats("1s", d, now - last_print);
            window_stats = stats;
            last_print = now;
        }
        // Keys repeat here.
        if (w.repeat_key != 0 and w.focused and now >= w.repeat_at) {
            _ = keyPress(&w, w.repeat_key);
            const period = std.time.ns_per_s / @as(u64, @intCast(@max(1, w.repeat_rate)));
            w.repeat_at = @max(w.repeat_at + period, now);
        }
        if (ctx.wake_at != 0 and now >= ctx.wake_at) {
            ctx.wake_at = 0;
            w.need_frame = true;
        }

        // A frame when one is wanted and the compositor showed the last;
        // a new size is drawn at once, as the compositor waits for it.
        const can_draw = w.frame_cb == null or w.reconfigured or uncapped;
        if (w.need_frame and w.configured and can_draw) {
            w.need_frame = false;
            const s = w.scale();
            size = w.pixels();
            const resized = w.reconfigured or s != drawn_scale;
            w.reconfigured = false;
            if (resized) rend.invalidate();
            drawn_scale = s;
            // Where the buffer goes: integer scales by the buffer's scale,
            // fractional ones through the viewport.
            if (w.viewport != null and w.frac_120 != 0) {
                w.surface.set_buffer_scale(1);
                w.viewport.?.set_destination(w.w, w.h);
            } else {
                w.surface.set_buffer_scale(w.intScale());
            }
            const t0 = w.now();
            ctx.build(&shell, Sh.build, @floatFromInt(w.w), @floatFromInt(w.h), t0);
            sc.reset(size[0], size[1], s, ctx.theme.background);
            ctx.endFrame(&sc);
            const t1 = w.now();
            stats.frames += 1;
            stats.build_ns += t1 - t0;
            if (!uncapped) {
                w.frame_cb = w.surface.frame();
                if (w.frame_cb) |cb| cb.setListener(*Win, onFrame, &w);
            }
            if (gpu) |*g| {
                const cv = raster.Canvas{ .pixels = &.{}, .width = size[0], .height = size[1], .stride = @intCast(size[0]) };
                _ = rend.render(&sc, &fonts, &cv);
                if (rend.damage.items.len > 0 or resized) {
                    if (egl) |*e| if (resized) e.resize(size[0], size[1]);
                    g.draw(&sc, &fonts, size[0], size[1]) catch |e| {
                        sys.log(.err, "myzig: {s} frame: {s}; drawing on the CPU", .{ g.api(), @errorName(e) });
                        g.deinit();
                        gpu = null;
                        if (egl) |*eg| eg.close();
                        egl = null;
                        rend.raster = true;
                        rend.retain_pixels = true;
                        rend.invalidate();
                        w.need_frame = true;
                        w.reconfigured = true;
                        continue;
                    };
                    if (dump) |path| {
                        backend.writePPM(gpa, g, size[0], size[1], path) catch {};
                        return;
                    }
                    if (egl) |*e| e.swap();
                } else {
                    // Nothing changed: no frame to wait for.
                    w.surface.commit();
                }
                stats.raster_ns += w.now() - t1;
            } else {
                const wl_shm = w.shm orelse return error.NoShm;
                try shm.resize(gpa, wl_shm, &w, size[0], size[1]);
                const cv = raster.Canvas{ .pixels = shm.canvas, .width = size[0], .height = size[1], .stride = @intCast(size[0]) };
                const px_before = rend.stats.pixels;
                _ = rend.render(&sc, &fonts, &cv);
                const t2 = w.now();
                stats.raster_ns += t2 - t1;
                stats.pixels += rend.stats.pixels - px_before;
                var changed = geom.IRect{};
                for (rend.damage.items) |d| changed = unite(changed, d);
                for (rend.scrolls.items) |sl| changed = unite(changed, sl.clip);
                if (resized) changed = .{ .x0 = 0, .y0 = 0, .x1 = size[0], .y1 = size[1] };
                if (changed.isEmpty()) {
                    w.surface.commit();
                } else if (shm.free()) |b| {
                    // This buffer gets what changed now and what it missed.
                    const stride: usize = @intCast(size[0]);
                    copyRect(b.pixels, shm.canvas, stride, unite(b.missed, changed));
                    b.missed = .{};
                    for (&shm.bufs) |*o| if (o != b) {
                        o.missed = unite(o.missed, changed);
                    };
                    b.busy = true;
                    w.surface.attach(b.buffer, 0, 0);
                    if (resized) {
                        w.surface.damage_buffer(0, 0, size[0], size[1]);
                    } else {
                        for (rend.damage.items) |d| if (!d.isEmpty()) w.surface.damage_buffer(d.x0, d.y0, d.x1 - d.x0, d.y1 - d.y0);
                        for (rend.scrolls.items) |sl| w.surface.damage_buffer(sl.clip.x0, sl.clip.y0, sl.clip.x1 - sl.clip.x0, sl.clip.y1 - sl.clip.y0);
                    }
                    w.surface.commit();
                    if (dump) |path| {
                        app.writePixels(path, shm.canvas, size[0], size[1], stride) catch {};
                        return;
                    }
                } else {
                    // Every buffer is the compositor's still: the frame
                    // waits for one.
                    for (&shm.bufs) |*o| o.missed = unite(o.missed, changed);
                    w.surface.commit();
                    w.need_frame = true;
                }
                stats.present_ns += w.now() - t2;
            }
            if (ctx.animating or ctx.requested) w.need_frame = true;
            if (ctx.cursor != w.cursor) {
                w.cursor = ctx.cursor;
                updateCursor(&w);
            }
            syncTextInput(&w);
        }

        // Sleep until the compositor writes, a key repeats, or a timer.
        _ = wl.lib.display_flush(display);
        var timeout: i32 = -1;
        const t = w.now();
        if (ctx.wake_at != 0) timeout = msUntil(ctx.wake_at, t);
        if (w.repeat_key != 0 and w.focused) timeout = minTimeout(timeout, msUntil(w.repeat_at, t));
        if (exit_after_ns) |limit| timeout = minTimeout(timeout, msUntil(limit, t) + 1);
        if (print_stats) timeout = minTimeout(timeout, 1000);
        if (w.need_frame and (w.frame_cb == null or uncapped)) timeout = 0;
        while (wl.lib.display_prepare_read(display) != 0) _ = wl.lib.display_dispatch_pending(display);
        _ = wl.lib.display_flush(display);
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        const ready = std.posix.poll(&pfd, timeout) catch 0;
        if (ready > 0 and pfd[0].revents & std.posix.POLL.IN != 0) {
            if (wl.lib.display_read_events(display) < 0) return error.WaylandConnectionLost;
        } else {
            wl.lib.display_cancel_read(display);
            if (ready > 0 and pfd[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) return error.WaylandConnectionLost;
        }
    }
}

fn msUntil(at: u64, now: u64) i32 {
    if (at <= now) return 0;
    return @intCast(@min((at - now + 999_999) / 1_000_000, std.math.maxInt(i32)));
}

fn minTimeout(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return @min(a, b);
}
