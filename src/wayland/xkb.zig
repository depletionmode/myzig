//! Keyboard: the compositor sends a keymap, and libxkbcommon (opened at
//! run time) turns key codes into keysyms and text with it, dead keys and
//! compose sequences included.

const std = @import("std");
const env = @import("../env.zig");
const sys = @import("../sys.zig");

const Context = opaque {};
const Keymap = opaque {};
const State = opaque {};
const ComposeTable = opaque {};
const ComposeState = opaque {};

const Lib = struct {
    context_new: *const fn (flags: c_int) callconv(.c) ?*Context,
    context_unref: *const fn (*Context) callconv(.c) void,
    keymap_new_from_string: *const fn (*Context, [*:0]const u8, format: c_int, flags: c_int) callconv(.c) ?*Keymap,
    keymap_unref: *const fn (*Keymap) callconv(.c) void,
    keymap_key_repeats: *const fn (*Keymap, key: u32) callconv(.c) c_int,
    state_new: *const fn (*Keymap) callconv(.c) ?*State,
    state_unref: *const fn (*State) callconv(.c) void,
    state_update_mask: *const fn (*State, depressed: u32, latched: u32, locked: u32, dep_layout: u32, lat_layout: u32, lock_layout: u32) callconv(.c) c_int,
    state_key_get_one_sym: *const fn (*State, key: u32) callconv(.c) u32,
    state_key_get_utf8: *const fn (*State, key: u32, buf: [*]u8, size: usize) callconv(.c) c_int,
    state_mod_name_is_active: *const fn (*State, name: [*:0]const u8, kind: c_int) callconv(.c) c_int,
    keysym_to_utf8: *const fn (sym: u32, buf: [*]u8, size: usize) callconv(.c) c_int,
};

const ComposeLib = struct {
    compose_table_new_from_locale: *const fn (*Context, locale: [*:0]const u8, flags: c_int) callconv(.c) ?*ComposeTable,
    compose_table_unref: *const fn (*ComposeTable) callconv(.c) void,
    compose_state_new: *const fn (*ComposeTable, flags: c_int) callconv(.c) ?*ComposeState,
    compose_state_unref: *const fn (*ComposeState) callconv(.c) void,
    compose_state_feed: *const fn (*ComposeState, sym: u32) callconv(.c) c_int,
    compose_state_get_status: *const fn (*ComposeState) callconv(.c) c_int,
    compose_state_get_one_sym: *const fn (*ComposeState) callconv(.c) u32,
    compose_state_reset: *const fn (*ComposeState) callconv(.c) void,
};

const state_mods_effective: c_int = 1 << 3;
const compose_composing: c_int = 1;
const compose_composed: c_int = 2;
const compose_cancelled: c_int = 3;

pub const Mods = struct { shift: bool = false, ctrl: bool = false, alt: bool = false, super: bool = false };

/// Keyboard is the keymap the compositor sent and the state of its keys.
pub const Keyboard = struct {
    lib: Lib = undefined,
    compose_lib: ?ComposeLib = null,
    dl: ?std.DynLib = null,
    ctx: ?*Context = null,
    keymap: ?*Keymap = null,
    state: ?*State = null,
    compose_table: ?*ComposeTable = null,
    compose: ?*ComposeState = null,
    mods: Mods = .{},

    pub fn open() !Keyboard {
        var k = Keyboard{};
        var dl = std.DynLib.open("libxkbcommon.so.0") catch try std.DynLib.open("libxkbcommon.so");
        const lib_ti = @typeInfo(Lib).@"struct";
        inline for (lib_ti.field_names, lib_ti.field_types) |name, ftype| {
            @field(k.lib, name) = dl.lookup(ftype, "xkb_" ++ name) orelse {
                dl.close();
                return error.MissingSymbol;
            };
        }
        var cl: ComposeLib = undefined;
        var all = true;
        const compose_ti = @typeInfo(ComposeLib).@"struct";
        inline for (compose_ti.field_names, compose_ti.field_types) |name, ftype| {
            if (dl.lookup(ftype, "xkb_" ++ name)) |p| @field(cl, name) = p else all = false;
        }
        if (all) k.compose_lib = cl;
        k.dl = dl;
        k.ctx = k.lib.context_new(0) orelse return error.NoXkbContext;
        return k;
    }

    pub fn deinit(k: *Keyboard) void {
        k.drop();
        if (k.compose_lib) |cl| {
            if (k.compose) |c| cl.compose_state_unref(c);
            if (k.compose_table) |t| cl.compose_table_unref(t);
        }
        if (k.ctx) |c| k.lib.context_unref(c);
        if (k.dl) |*d| d.close();
    }

    fn drop(k: *Keyboard) void {
        if (k.state) |s| k.lib.state_unref(s);
        if (k.keymap) |m| k.lib.keymap_unref(m);
        k.state = null;
        k.keymap = null;
    }

    /// setKeymap takes the keymap the compositor shares in fd.
    pub fn setKeymap(k: *Keyboard, fd: i32, size: u32) void {
        defer sys.close(fd);
        const map = std.posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
        defer std.posix.munmap(map);
        const text: [*:0]const u8 = @ptrCast(map.ptr);
        const km = k.lib.keymap_new_from_string(k.ctx.?, text, 1, 0) orelse return;
        const st = k.lib.state_new(km) orelse {
            k.lib.keymap_unref(km);
            return;
        };
        k.drop();
        k.keymap = km;
        k.state = st;
        if (k.compose_lib) |cl| if (k.compose == null) {
            const locale = env.get("LC_ALL") orelse env.get("LC_CTYPE") orelse env.get("LANG") orelse "C";
            var buf: [64]u8 = undefined;
            const z = std.fmt.bufPrintSentinel(&buf, "{s}", .{locale}, 0) catch "C";
            k.compose_table = cl.compose_table_new_from_locale(k.ctx.?, z, 0);
            if (k.compose_table) |t| k.compose = cl.compose_state_new(t, 0);
        };
    }

    pub fn updateMods(k: *Keyboard, depressed: u32, latched: u32, locked: u32, group: u32) void {
        const st = k.state orelse return;
        _ = k.lib.state_update_mask(st, depressed, latched, locked, 0, 0, group);
        k.mods = .{
            .shift = k.lib.state_mod_name_is_active(st, "Shift", state_mods_effective) > 0,
            .ctrl = k.lib.state_mod_name_is_active(st, "Control", state_mods_effective) > 0,
            .alt = k.lib.state_mod_name_is_active(st, "Mod1", state_mods_effective) > 0,
            .super = k.lib.state_mod_name_is_active(st, "Mod4", state_mods_effective) > 0,
        };
    }

    /// Press is what a key press means: its keysym (with no modifier for
    /// shortcuts' sake, see sym), and the text it types, if any.
    pub const Press = struct { sym: u32, len: usize, repeats: bool };

    /// press reads key (an evdev code) pressed, its text into out.
    pub fn press(k: *Keyboard, key: u32, out: *[64]u8) Press {
        const st = k.state orelse return .{ .sym = 0, .len = 0, .repeats = false };
        const code = key + 8;
        const sym = k.lib.state_key_get_one_sym(st, code);
        const repeats = k.lib.keymap_key_repeats(k.keymap.?, code) != 0;
        var n: usize = 0;
        // Dead keys and compose sequences.
        if (k.compose_lib) |cl| if (k.compose) |c| {
            if (cl.compose_state_feed(c, sym) == 1) {
                switch (cl.compose_state_get_status(c)) {
                    compose_composing => return .{ .sym = sym, .len = 0, .repeats = false },
                    compose_composed => {
                        const r = cl.compose_state_get_one_sym(c);
                        cl.compose_state_reset(c);
                        const m = k.lib.keysym_to_utf8(r, out, out.len);
                        return .{ .sym = sym, .len = if (m > 1) @intCast(m - 1) else 0, .repeats = false };
                    },
                    compose_cancelled => {
                        cl.compose_state_reset(c);
                        return .{ .sym = sym, .len = 0, .repeats = false };
                    },
                    else => {},
                }
            }
        };
        const m = k.lib.state_key_get_utf8(st, code, out, out.len);
        if (m > 0) n = @intCast(@min(m, out.len - 1));
        // Control characters are not text.
        if (n == 1 and (out[0] < 0x20 or out[0] == 0x7f)) n = 0;
        return .{ .sym = sym, .len = n, .repeats = repeats };
    }
};
