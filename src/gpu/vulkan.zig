//! The Vulkan renderer: instances.zig's scene as one instanced draw, the
//! same shader as OpenGL's compiled to SPIR-V (gpu/shaders). It draws to a
//! window's swapchain (X11's through VK_KHR_xlib_surface, Wayland's through
//! VK_KHR_wayland_surface, Windows' through
//! VK_KHR_win32_surface, a CAMetalLayer through MoltenVK's
//! VK_EXT_metal_surface), or to an image of its own when there is
//! no window (tests, and frames read back).
//!
//! Two frames are in flight: each has its command buffer, fence, the
//! semaphore its swapchain image is acquired with and the host-visible
//! buffers its instances and new glyphs are written to.

const std = @import("std");
const sys = @import("../sys.zig");
const builtin = @import("builtin");
const scene = @import("../scene.zig");
const text = @import("../text.zig");
const inst = @import("instances.zig");
const vk = @import("vk.zig");
const env = @import("../env.zig");

const vert_spv align(4) = @embedFile("shaders/box.vert.spv").*;
const frag_spv align(4) = @embedFile("shaders/box.frag.spv").*;

/// Surface is what the renderer draws to.
pub const Surface = union(enum) {
    xlib: struct { dpy: *anyopaque, window: c_ulong },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    win32: struct { hinstance: *anyopaque, hwnd: *anyopaque },
    /// metal draws to a CAMetalLayer, through MoltenVK on macOS.
    metal: struct { layer: *anyopaque },
    /// offscreen draws to an image of the renderer's, read with read().
    offscreen,
};

pub const Options = struct {
    /// vsync presents in step with the display (FIFO); without it frames
    /// replace each other (MAILBOX) or tear (IMMEDIATE), where supported.
    vsync: bool = true,
    /// validation enables VK_LAYER_KHRONOS_validation when it is installed.
    validation: bool = false,
};

const frames_in_flight = 2;

/// HostBuffer is a buffer the CPU writes and the GPU reads, mapped for as
/// long as it lives, grown by doubling.
const HostBuffer = struct {
    buffer: vk.Buffer = 0,
    memory: vk.DeviceMemory = 0,
    ptr: [*]u8 = undefined,
    size: usize = 0,
};

const Frame = struct {
    cmd: vk.CommandBuffer = undefined,
    fence: vk.Fence = 0,
    acquired: vk.Semaphore = 0,
    instances: HostBuffer = .{},
    staging: HostBuffer = .{},
};

/// Target is a swapchain image, or the offscreen image.
const Target = struct {
    image: vk.Image = 0,
    view: vk.ImageView = 0,
    framebuffer: vk.Framebuffer = 0,
    /// done is signaled when the frame drawn into this image is, for the
    /// presentation to wait on.
    done: vk.Semaphore = 0,
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    lib: sys.DynLib,
    get_instance_proc: *const fn (?vk.Instance, [*:0]const u8) callconv(vk.CC) ?*const anyopaque,
    i: vk.InstanceFns = undefined,
    d: vk.DeviceFns = undefined,
    instance: vk.Instance = undefined,
    surface: vk.SurfaceKHR = 0,
    physical: vk.PhysicalDevice = undefined,
    props: vk.PhysicalDeviceProperties = undefined,
    memory_props: vk.PhysicalDeviceMemoryProperties = undefined,
    device: vk.Device = undefined,
    queue: vk.Queue = undefined,
    family: u32 = 0,
    format: vk.Format = .b8g8r8a8_unorm,
    color_space: i32 = 0,
    present_mode: vk.PresentMode = .fifo,
    offscreen: bool,

    render_pass: vk.RenderPass = 0,
    set_layout: vk.DescriptorSetLayout = 0,
    pipeline_layout: vk.PipelineLayout = 0,
    pipeline: vk.Pipeline = 0,
    sampler: vk.Sampler = 0,
    /// image_sampler filters (images are drawn at any size); glyphs are
    /// drawn texel for pixel.
    image_sampler: vk.Sampler = 0,
    pool: vk.DescriptorPool = 0,
    set: vk.DescriptorSet = 0,
    cmd_pool: vk.CommandPool = 0,
    frames: [frames_in_flight]Frame = .{ .{}, .{} },
    frame: usize = 0,

    swapchain: vk.SwapchainKHR = 0,
    targets: std.ArrayListUnmanaged(Target) = .empty,
    /// target_memory backs the offscreen image.
    target_memory: vk.DeviceMemory = 0,
    extent: vk.Extent2D = .{ .width = 0, .height = 0 },
    stale: bool = false,

    atlas: inst.Atlas,
    atlas_image: vk.Image = 0,
    atlas_memory: vk.DeviceMemory = 0,
    atlas_view: vk.ImageView = 0,
    atlas_size: u32 = 0,
    atlas_fresh: bool = false,
    images: inst.ImageAtlas,
    images_image: vk.Image = 0,
    images_memory: vk.DeviceMemory = 0,
    images_view: vk.ImageView = 0,
    /// images_size is the image texture's side: 1 until an image is drawn.
    images_size: u32 = 0,
    images_fresh: bool = false,
    instances: std.ArrayListUnmanaged(inst.Instance) = .empty,

    /// capture, when set before draw, copies the frame drawn into readback
    /// for read().
    capture: bool = false,
    readback: HostBuffer = .{},
    readback_frame: ?usize = null,

    pub fn init(gpa: std.mem.Allocator, surface: Surface, width: i32, height: i32, opts: Options) !Renderer {
        var lib = try openLoader();
        errdefer lib.close();
        const gip = lib.lookup(*const fn (?vk.Instance, [*:0]const u8) callconv(vk.CC) ?*const anyopaque, "vkGetInstanceProcAddr") orelse return error.NoVulkan;
        var r = Renderer{
            .gpa = gpa,
            .lib = lib,
            .get_instance_proc = gip,
            .offscreen = surface == .offscreen,
            .atlas = .{ .gpa = gpa },
            .images = .{ .gpa = gpa },
        };
        try r.open(surface, opts);
        if (builtin.os.tag == .linux) r.onlyDriver(surface, opts) catch {};
        errdefer {
            _ = r.d.DeviceWaitIdle(r.device);
            r.destroyAll();
        }
        if (!r.offscreen) try r.pickSurfaceFormat(opts.vsync);
        try r.createPipeline();
        try r.createFrames();
        try r.resize(@intCast(@max(1, width)), @intCast(@max(1, height)));
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        _ = r.d.DeviceWaitIdle(r.device);
        r.destroyAll();
        r.lib.close();
        r.atlas.deinit();
        r.images.deinit();
        r.instances.deinit(r.gpa);
        r.targets.deinit(r.gpa);
    }

    fn destroyAll(r: *Renderer) void {
        const d = r.d;
        const dev = r.device;
        r.destroyTargets();
        if (r.swapchain != 0) d.DestroySwapchainKHR.?(dev, r.swapchain, null);
        r.destroyAtlas();
        r.destroyImages();
        r.freeHost(&r.readback);
        for (&r.frames) |*f| {
            r.freeHost(&f.instances);
            r.freeHost(&f.staging);
            if (f.fence != 0) d.DestroyFence(dev, f.fence, null);
            if (f.acquired != 0) d.DestroySemaphore(dev, f.acquired, null);
        }
        if (r.cmd_pool != 0) d.DestroyCommandPool(dev, r.cmd_pool, null);
        if (r.pool != 0) d.DestroyDescriptorPool(dev, r.pool, null);
        if (r.sampler != 0) d.DestroySampler(dev, r.sampler, null);
        if (r.image_sampler != 0) d.DestroySampler(dev, r.image_sampler, null);
        if (r.pipeline != 0) d.DestroyPipeline(dev, r.pipeline, null);
        if (r.pipeline_layout != 0) d.DestroyPipelineLayout(dev, r.pipeline_layout, null);
        if (r.set_layout != 0) d.DestroyDescriptorSetLayout(dev, r.set_layout, null);
        if (r.render_pass != 0) d.DestroyRenderPass(dev, r.render_pass, null);
        d.DestroyDevice(dev, null);
        if (r.surface != 0) r.i.DestroySurfaceKHR.?(r.instance, r.surface, null);
        r.i.DestroyInstance(r.instance, null);
    }

    /// name is the device's: "llvmpipe (LLVM ...)", "NVIDIA GeForce ...".
    pub fn name(r: *const Renderer) []const u8 {
        return std.mem.sliceTo(&r.props.device_name, 0);
    }

    /// software reports whether the device draws on the CPU (lavapipe,
    /// SwiftShader), where MyZig's own CPU renderer is cheaper.
    pub fn software(r: *const Renderer) bool {
        return r.props.device_type == .cpu;
    }

    fn open(r: *Renderer, surface: Surface, opts: Options) !void {
        try r.createInstance(surface, opts);
        errdefer r.i.DestroyInstance(r.instance, null);
        try r.createSurface(surface);
        errdefer if (r.surface != 0) r.i.DestroySurfaceKHR.?(r.instance, r.surface, null);
        try r.pickDevice();
        try r.createDevice();
    }

    fn close(r: *Renderer) void {
        r.d.DestroyDevice(r.device, null);
        if (r.surface != 0) r.i.DestroySurfaceKHR.?(r.instance, r.surface, null);
        r.i.DestroyInstance(r.instance, null);
        r.surface = 0;
    }

    /// onlyDriver opens Vulkan again with only the driver of the device
    /// picked: the loader loads every installed driver (llvmpipe's LLVM,
    /// nouveau, radeon, ...) and keeps them while an instance lives, some
    /// 10 to 30 MB the window never uses. Nothing is done when the user
    /// chose drivers themselves.
    fn onlyDriver(r: *Renderer, surface: Surface, opts: Options) !void {
        inline for (.{ "VK_DRIVER_FILES", "VK_ICD_FILENAMES", "VK_LOADER_DRIVERS_SELECT", "VK_ADD_DRIVER_FILES" }) |v|
            if (env.has(v)) return;
        var info: Dl_info = undefined;
        if (dladdr(@ptrCast(r.d.QueueSubmit), &info) == 0) return;
        const lib = std.fs.path.basename(std.mem.sliceTo(info.dli_fname orelse return, 0));
        var path_buf: [std.fs.max_path_bytes:0]u8 = undefined;
        const json = findDriverFile(r.gpa, lib, &path_buf) orelse return;
        const props = r.props;
        r.close();
        _ = setenv("VK_DRIVER_FILES", json, 1);
        _ = setenv("VK_ICD_FILENAMES", json, 1);
        defer {
            _ = unsetenv("VK_DRIVER_FILES");
            _ = unsetenv("VK_ICD_FILENAMES");
        }
        r.open(surface, opts) catch {
            // Every driver again, as at first.
            _ = unsetenv("VK_DRIVER_FILES");
            _ = unsetenv("VK_ICD_FILENAMES");
            return r.open(surface, opts);
        };
        if (r.props.device_id != props.device_id or r.props.vendor_id != props.vendor_id) {
            r.close();
            _ = unsetenv("VK_DRIVER_FILES");
            _ = unsetenv("VK_ICD_FILENAMES");
            return r.open(surface, opts);
        }
    }

    /// findDriverFile is the loader's manifest (icd.d/*.json) naming lib,
    /// in the directories the loader reads them from.
    fn findDriverFile(gpa: std.mem.Allocator, lib: []const u8, buf: *[std.fs.max_path_bytes:0]u8) ?[:0]const u8 {
        var dirs: [16][]const u8 = undefined;
        var n: usize = 0;
        dirs[n] = "/etc/vulkan/icd.d";
        n += 1;
        const data = env.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
        var it = std.mem.tokenizeScalar(u8, data, ':');
        var joined: [8][std.fs.max_path_bytes]u8 = undefined;
        var nj: usize = 0;
        while (it.next()) |d| {
            if (nj == joined.len) break;
            dirs[n] = std.fmt.bufPrint(&joined[nj], "{s}/vulkan/icd.d", .{d}) catch continue;
            n += 1;
            nj += 1;
        }
        for (dirs[0..n]) |dir| {
            var dir_z: [std.fs.max_path_bytes:0]u8 = undefined;
            const dz = std.fmt.bufPrintSentinel(&dir_z, "{s}", .{dir}, 0) catch continue;
            const d = std.c.opendir(dz) orelse continue;
            defer _ = std.c.closedir(d);
            while (readdir(d)) |e| {
                const name_ = std.mem.sliceTo(&e.name, 0);
                if (!std.mem.endsWith(u8, name_, ".json")) continue;
                const path = std.fmt.bufPrintSentinel(buf, "{s}/{s}", .{ dir, name_ }, 0) catch continue;
                const body = sys.readFile(gpa, path, 64 << 10) catch continue;
                defer gpa.free(body);
                const key = "\"library_path\"";
                const at = std.mem.indexOf(u8, body, key) orelse continue;
                const rest = body[at + key.len ..];
                const q0 = std.mem.indexOfScalarPos(u8, rest, std.mem.indexOfScalar(u8, rest, ':') orelse continue, '"') orelse continue;
                const q1 = std.mem.indexOfScalarPos(u8, rest, q0 + 1, '"') orelse continue;
                if (std.mem.eql(u8, std.fs.path.basename(rest[q0 + 1 .. q1]), lib)) return path;
            }
        }
        return null;
    }

    fn openLoader() !sys.DynLib {
        const names: []const []const u8 = switch (builtin.os.tag) {
            .windows => &.{"vulkan-1.dll"},
            // The loader, else MoltenVK itself; Homebrew's prefixes are
            // not on dlopen's default path.
            .macos => &.{
                "libvulkan.1.dylib",
                "/opt/homebrew/lib/libvulkan.1.dylib",
                "/usr/local/lib/libvulkan.1.dylib",
                "libMoltenVK.dylib",
                "/opt/homebrew/lib/libMoltenVK.dylib",
                "/usr/local/lib/libMoltenVK.dylib",
            },
            else => &.{ "libvulkan.so.1", "libvulkan.so" },
        };
        for (names) |n| return sys.DynLib.open(n) catch continue;
        return error.NoVulkan;
    }

    fn instanceProc(r: *Renderer, n: [*:0]const u8) ?*const anyopaque {
        return r.get_instance_proc(r.instance, n);
    }

    fn deviceProc(r: *Renderer, n: [*:0]const u8) ?*const anyopaque {
        return r.i.GetDeviceProcAddr(r.device, n);
    }

    fn createInstance(r: *Renderer, surface: Surface, opts: Options) !void {
        const base = try vk.load(vk.Base, r.get_instance_proc, struct {
            fn p(g: @TypeOf(r.get_instance_proc), n: [*:0]const u8) ?*const anyopaque {
                return g(null, n);
            }
        }.p);
        var exts: [3][*:0]const u8 = undefined;
        var n_ext: u32 = 0;
        switch (surface) {
            .xlib => {
                exts[0..2].* = .{ "VK_KHR_surface", "VK_KHR_xlib_surface" };
                n_ext = 2;
            },
            .wayland => {
                exts[0..2].* = .{ "VK_KHR_surface", "VK_KHR_wayland_surface" };
                n_ext = 2;
            },
            .win32 => {
                exts[0..2].* = .{ "VK_KHR_surface", "VK_KHR_win32_surface" };
                n_ext = 2;
            },
            .metal => {
                exts = .{ "VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_portability_enumeration" };
                n_ext = 3;
            },
            .offscreen => {},
        }
        const app = vk.ApplicationInfo{ .p_application_name = "myzig", .p_engine_name = "myzig", .api_version = vk.makeVersion(1, 0, 0) };
        const layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
        var info = vk.InstanceCreateInfo{
            .p_application_info = &app,
            .enabled_extension_count = n_ext,
            .pp_enabled_extension_names = &exts,
        };
        if (surface == .metal) info.flags = vk.INSTANCE_CREATE_ENUMERATE_PORTABILITY;
        if (opts.validation) {
            info.enabled_layer_count = 1;
            info.pp_enabled_layer_names = &layers;
            if (base.CreateInstance(&info, null, &r.instance) == vk.SUCCESS) {
                r.i = try vk.load(vk.InstanceFns, r, instanceProc);
                return;
            }
            sys.log(.warn, "myzig: no Vulkan validation layer", .{});
            info.enabled_layer_count = 0;
        }
        var res = base.CreateInstance(&info, null, &r.instance);
        if (res != vk.SUCCESS and surface == .metal) {
            // MoltenVK without the loader lists itself without the
            // portability extension.
            info.flags = 0;
            info.enabled_extension_count = 2;
            res = base.CreateInstance(&info, null, &r.instance);
        }
        try vk.check(res);
        r.i = try vk.load(vk.InstanceFns, r, instanceProc);
    }

    fn createSurface(r: *Renderer, surface: Surface) !void {
        switch (surface) {
            .xlib => |s| {
                const f = r.i.CreateXlibSurfaceKHR orelse return error.NoSurface;
                try vk.check(f(r.instance, &.{ .dpy = s.dpy, .window = s.window }, null, &r.surface));
            },
            .wayland => |s| {
                const f = r.i.CreateWaylandSurfaceKHR orelse return error.NoSurface;
                try vk.check(f(r.instance, &.{ .display = s.display, .surface = s.surface }, null, &r.surface));
            },
            .win32 => |s| {
                const f = r.i.CreateWin32SurfaceKHR orelse return error.NoSurface;
                try vk.check(f(r.instance, &.{ .hinstance = s.hinstance, .hwnd = s.hwnd }, null, &r.surface));
            },
            .metal => |s| {
                const f = r.i.CreateMetalSurfaceEXT orelse return error.NoSurface;
                try vk.check(f(r.instance, &.{ .layer = s.layer }, null, &r.surface));
            },
            .offscreen => {},
        }
    }

    /// pickDevice takes the first discrete GPU, else integrated, virtual
    /// and the CPU's last, with a queue that draws and presents.
    fn pickDevice(r: *Renderer) !void {
        var n: u32 = 0;
        try vk.check(r.i.EnumeratePhysicalDevices(r.instance, &n, null));
        var devs: [16]vk.PhysicalDevice = undefined;
        n = @min(n, devs.len);
        _ = r.i.EnumeratePhysicalDevices(r.instance, &n, &devs);
        var best: ?struct { dev: vk.PhysicalDevice, family: u32, rank: u32 } = null;
        for (devs[0..n]) |dev| {
            var p: vk.PhysicalDeviceProperties = undefined;
            r.i.GetPhysicalDeviceProperties(dev, &p);
            const family = r.drawingFamily(dev) orelse continue;
            const rank: u32 = switch (p.device_type) {
                .discrete_gpu => 0,
                .integrated_gpu => 1,
                .virtual_gpu => 2,
                .cpu => 4,
                else => 3,
            };
            if (best == null or rank < best.?.rank) best = .{ .dev = dev, .family = family, .rank = rank };
        }
        const b = best orelse return error.NoDevice;
        r.physical = b.dev;
        r.family = b.family;
        r.i.GetPhysicalDeviceProperties(b.dev, &r.props);
        r.i.GetPhysicalDeviceMemoryProperties(b.dev, &r.memory_props);
    }

    fn drawingFamily(r: *Renderer, dev: vk.PhysicalDevice) ?u32 {
        var n: u32 = 0;
        r.i.GetPhysicalDeviceQueueFamilyProperties(dev, &n, null);
        var fams: [16]vk.QueueFamilyProperties = undefined;
        n = @min(n, fams.len);
        r.i.GetPhysicalDeviceQueueFamilyProperties(dev, &n, &fams);
        for (fams[0..n], 0..) |f, idx| {
            if (f.queue_flags & vk.QUEUE_GRAPHICS == 0) continue;
            if (r.surface != 0) {
                var ok: vk.Bool32 = 0;
                _ = r.i.GetPhysicalDeviceSurfaceSupportKHR.?(dev, @intCast(idx), r.surface, &ok);
                if (ok == 0) continue;
            }
            return @intCast(idx);
        }
        return null;
    }

    fn createDevice(r: *Renderer) !void {
        const prio = [_]f32{1};
        const q = [_]vk.DeviceQueueCreateInfo{.{ .queue_family_index = r.family, .queue_count = 1, .p_queue_priorities = &prio }};
        const exts = [_][*:0]const u8{"VK_KHR_swapchain"};
        try vk.check(r.i.CreateDevice(r.physical, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &q,
            .enabled_extension_count = if (r.offscreen) 0 else 1,
            .pp_enabled_extension_names = &exts,
        }, null, &r.device));
        r.d = try vk.load(vk.DeviceFns, r, deviceProc);
        r.d.GetDeviceQueue(r.device, r.family, 0, &r.queue);
    }

    fn pickSurfaceFormat(r: *Renderer, vsync: bool) !void {
        var n: u32 = 0;
        try vk.check(r.i.GetPhysicalDeviceSurfaceFormatsKHR.?(r.physical, r.surface, &n, null));
        var fmts: [64]vk.SurfaceFormatKHR = undefined;
        n = @min(n, fmts.len);
        _ = r.i.GetPhysicalDeviceSurfaceFormatsKHR.?(r.physical, r.surface, &n, &fmts);
        if (n == 0) return error.NoSurfaceFormat;
        // UNORM, so blending is in the same space as the CPU renderer's.
        r.format = fmts[0].format;
        r.color_space = fmts[0].color_space;
        for (fmts[0..n]) |f| if (f.format == .b8g8r8a8_unorm or f.format == .r8g8b8a8_unorm) {
            r.format = f.format;
            r.color_space = f.color_space;
            break;
        };
        if (r.format == .undefined) r.format = .b8g8r8a8_unorm;
        r.present_mode = .fifo;
        if (!vsync) {
            var m: u32 = 0;
            _ = r.i.GetPhysicalDeviceSurfacePresentModesKHR.?(r.physical, r.surface, &m, null);
            var modes: [16]vk.PresentMode = undefined;
            m = @min(m, modes.len);
            _ = r.i.GetPhysicalDeviceSurfacePresentModesKHR.?(r.physical, r.surface, &m, &modes);
            for (modes[0..m]) |md| if (md == .mailbox) {
                r.present_mode = .mailbox;
            };
            if (r.present_mode == .fifo) for (modes[0..m]) |md| if (md == .immediate) {
                r.present_mode = .immediate;
            };
        }
    }

    fn createPipeline(r: *Renderer) !void {
        const d = r.d;
        const dev = r.device;
        const attachment = [_]vk.AttachmentDescription{.{
            .format = r.format,
            .load_op = vk.ATTACHMENT_LOAD_CLEAR,
            .store_op = vk.ATTACHMENT_STORE_STORE,
            .initial_layout = .undefined,
            .final_layout = if (r.offscreen) .transfer_src_optimal else .present_src_khr,
        }};
        const color_ref = [_]vk.AttachmentReference{.{ .attachment = 0, .layout = .color_attachment_optimal }};
        const subpass = [_]vk.SubpassDescription{.{ .color_attachment_count = 1, .p_color_attachments = &color_ref }};
        const deps = [_]vk.SubpassDependency{.{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = vk.STAGE_COLOR_ATTACHMENT_OUTPUT | vk.STAGE_TRANSFER,
            .dst_stage_mask = vk.STAGE_COLOR_ATTACHMENT_OUTPUT | vk.STAGE_FRAGMENT_SHADER,
            .src_access_mask = vk.ACCESS_TRANSFER_WRITE,
            .dst_access_mask = vk.ACCESS_COLOR_ATTACHMENT_WRITE | vk.ACCESS_SHADER_READ,
        }};
        try vk.check(d.CreateRenderPass(dev, &.{
            .attachment_count = 1,
            .p_attachments = &attachment,
            .subpass_count = 1,
            .p_subpasses = &subpass,
            .dependency_count = 1,
            .p_dependencies = &deps,
        }, null, &r.render_pass));

        const bindings = [_]vk.DescriptorSetLayoutBinding{ .{
            .binding = 0,
            .descriptor_type = vk.DESCRIPTOR_COMBINED_IMAGE_SAMPLER,
            .descriptor_count = 1,
            .stage_flags = vk.SHADER_STAGE_FRAGMENT,
        }, .{
            .binding = 1,
            .descriptor_type = vk.DESCRIPTOR_COMBINED_IMAGE_SAMPLER,
            .descriptor_count = 1,
            .stage_flags = vk.SHADER_STAGE_FRAGMENT,
        } };
        try vk.check(d.CreateDescriptorSetLayout(dev, &.{ .binding_count = bindings.len, .p_bindings = &bindings }, null, &r.set_layout));
        const push = [_]vk.PushConstantRange{.{ .stage_flags = vk.SHADER_STAGE_VERTEX, .offset = 0, .size = 8 }};
        const set_layouts = [_]vk.DescriptorSetLayout{r.set_layout};
        try vk.check(d.CreatePipelineLayout(dev, &.{
            .set_layout_count = 1,
            .p_set_layouts = &set_layouts,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = &push,
        }, null, &r.pipeline_layout));

        var vs: vk.ShaderModule = 0;
        var fs: vk.ShaderModule = 0;
        try vk.check(d.CreateShaderModule(dev, &.{ .code_size = vert_spv.len, .p_code = @ptrCast(&vert_spv) }, null, &vs));
        defer d.DestroyShaderModule(dev, vs, null);
        try vk.check(d.CreateShaderModule(dev, &.{ .code_size = frag_spv.len, .p_code = @ptrCast(&frag_spv) }, null, &fs));
        defer d.DestroyShaderModule(dev, fs, null);
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{ .stage = vk.SHADER_STAGE_VERTEX, .module = vs },
            .{ .stage = vk.SHADER_STAGE_FRAGMENT, .module = fs },
        };
        const vbind = [_]vk.VertexInputBindingDescription{.{ .binding = 0, .stride = @sizeOf(inst.Instance), .input_rate = vk.INPUT_RATE_INSTANCE }};
        var vattr: [6]vk.VertexInputAttributeDescription = undefined;
        for (&vattr, 0..) |*a, idx| a.* = .{ .location = @intCast(idx), .binding = 0, .format = .r32g32b32a32_sfloat, .offset = @intCast(idx * 16) };
        const vinput = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = &vbind,
            .vertex_attribute_description_count = vattr.len,
            .p_vertex_attribute_descriptions = &vattr,
        };
        const blend = [_]vk.PipelineColorBlendAttachmentState{.{
            .blend_enable = 1,
            .src_color_blend_factor = vk.BLEND_ONE,
            .dst_color_blend_factor = vk.BLEND_ONE_MINUS_SRC_ALPHA,
            .src_alpha_blend_factor = vk.BLEND_ONE,
            .dst_alpha_blend_factor = vk.BLEND_ONE_MINUS_SRC_ALPHA,
        }};
        const dynamic = [_]i32{ vk.DYNAMIC_VIEWPORT, vk.DYNAMIC_SCISSOR };
        const info = [_]vk.GraphicsPipelineCreateInfo{.{
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = &vinput,
            .p_input_assembly_state = &.{ .topology = vk.TOPOLOGY_TRIANGLE_STRIP },
            .p_viewport_state = &.{},
            .p_rasterization_state = &.{},
            .p_multisample_state = &.{},
            .p_color_blend_state = &.{ .attachment_count = 1, .p_attachments = &blend },
            .p_dynamic_state = &.{ .dynamic_state_count = dynamic.len, .p_dynamic_states = &dynamic },
            .layout = r.pipeline_layout,
            .render_pass = r.render_pass,
        }};
        var pipes = [_]vk.Pipeline{0};
        try vk.check(d.CreateGraphicsPipelines(dev, 0, 1, &info, null, &pipes));
        r.pipeline = pipes[0];

        try vk.check(d.CreateSampler(dev, &.{}, null, &r.sampler));
        try vk.check(d.CreateSampler(dev, &.{ .mag_filter = 1, .min_filter = 1 }, null, &r.image_sampler)); // linear
        const sizes = [_]vk.DescriptorPoolSize{.{ .type = vk.DESCRIPTOR_COMBINED_IMAGE_SAMPLER, .descriptor_count = 2 }};
        try vk.check(d.CreateDescriptorPool(dev, &.{ .max_sets = 1, .pool_size_count = 1, .p_pool_sizes = &sizes }, null, &r.pool));
        var sets = [_]vk.DescriptorSet{0};
        try vk.check(d.AllocateDescriptorSets(dev, &.{ .descriptor_pool = r.pool, .descriptor_set_count = 1, .p_set_layouts = &set_layouts }, &sets));
        r.set = sets[0];
    }

    fn createFrames(r: *Renderer) !void {
        const d = r.d;
        const dev = r.device;
        try vk.check(d.CreateCommandPool(dev, &.{ .flags = vk.COMMAND_POOL_RESET_BUFFER, .queue_family_index = r.family }, null, &r.cmd_pool));
        var cmds: [frames_in_flight]vk.CommandBuffer = undefined;
        try vk.check(d.AllocateCommandBuffers(dev, &.{ .command_pool = r.cmd_pool, .command_buffer_count = frames_in_flight }, &cmds));
        for (&r.frames, cmds) |*f, c| {
            f.cmd = c;
            try vk.check(d.CreateFence(dev, &.{ .flags = vk.FENCE_SIGNALED }, null, &f.fence));
            if (!r.offscreen) try vk.check(d.CreateSemaphore(dev, &.{}, null, &f.acquired));
        }
    }

    fn memoryType(r: *Renderer, bits: u32, want: vk.Flags) !u32 {
        for (r.memory_props.memory_types[0..r.memory_props.memory_type_count], 0..) |t, idx| {
            if (bits & (@as(u32, 1) << @intCast(idx)) != 0 and t.property_flags & want == want) return @intCast(idx);
        }
        return error.NoMemoryType;
    }

    /// ensureHost makes b at least size bytes.
    fn ensureHost(r: *Renderer, b: *HostBuffer, size: usize, usage: vk.Flags) !void {
        if (b.size >= size) return;
        var cap: usize = @max(b.size, 64 << 10);
        while (cap < size) cap *= 2;
        r.freeHost(b);
        const d = r.d;
        try vk.check(d.CreateBuffer(r.device, &.{ .size = cap, .usage = usage }, null, &b.buffer));
        var req: vk.MemoryRequirements = undefined;
        d.GetBufferMemoryRequirements(r.device, b.buffer, &req);
        const mt = try r.memoryType(req.memory_type_bits, vk.MEMORY_HOST_VISIBLE | vk.MEMORY_HOST_COHERENT);
        try vk.check(d.AllocateMemory(r.device, &.{ .allocation_size = req.size, .memory_type_index = mt }, null, &b.memory));
        try vk.check(d.BindBufferMemory(r.device, b.buffer, b.memory, 0));
        var p: ?*anyopaque = null;
        try vk.check(d.MapMemory(r.device, b.memory, 0, req.size, 0, &p));
        b.ptr = @ptrCast(p.?);
        b.size = cap;
    }

    fn freeHost(r: *Renderer, b: *HostBuffer) void {
        if (b.buffer != 0) r.d.DestroyBuffer(r.device, b.buffer, null);
        if (b.memory != 0) r.d.FreeMemory(r.device, b.memory, null); // unmaps
        b.* = .{};
    }

    fn deviceImage(r: *Renderer, format: vk.Format, w: u32, h: u32, usage: vk.Flags, image: *vk.Image, memory: *vk.DeviceMemory, view: *vk.ImageView) !void {
        const d = r.d;
        try vk.check(d.CreateImage(r.device, &.{ .format = format, .extent = .{ .width = w, .height = h, .depth = 1 }, .usage = usage }, null, image));
        var req: vk.MemoryRequirements = undefined;
        d.GetImageMemoryRequirements(r.device, image.*, &req);
        const mt = r.memoryType(req.memory_type_bits, vk.MEMORY_DEVICE_LOCAL) catch try r.memoryType(req.memory_type_bits, 0);
        try vk.check(d.AllocateMemory(r.device, &.{ .allocation_size = req.size, .memory_type_index = mt }, null, memory));
        try vk.check(d.BindImageMemory(r.device, image.*, memory.*, 0));
        try vk.check(d.CreateImageView(r.device, &.{ .image = image.*, .format = format }, null, view));
    }

    fn destroyTargets(r: *Renderer) void {
        const d = r.d;
        for (r.targets.items) |t| {
            if (t.framebuffer != 0) d.DestroyFramebuffer(r.device, t.framebuffer, null);
            if (t.view != 0) d.DestroyImageView(r.device, t.view, null);
            if (t.done != 0) d.DestroySemaphore(r.device, t.done, null);
            if (r.offscreen and t.image != 0) d.DestroyImage(r.device, t.image, null);
        }
        r.targets.clearRetainingCapacity();
        if (r.target_memory != 0) d.FreeMemory(r.device, r.target_memory, null);
        r.target_memory = 0;
    }

    /// resize makes the targets w×h: a new swapchain, or a new offscreen
    /// image. The device must be idle.
    fn resize(r: *Renderer, w: u32, h: u32) !void {
        const d = r.d;
        r.destroyTargets();
        r.stale = false;
        if (r.offscreen) {
            var t = Target{};
            try r.deviceImage(r.format, w, h, vk.IMAGE_USAGE_COLOR_ATTACHMENT | vk.IMAGE_USAGE_TRANSFER_SRC, &t.image, &r.target_memory, &t.view);
            try r.targets.append(r.gpa, t);
            r.extent = .{ .width = w, .height = h };
        } else {
            var caps: vk.SurfaceCapabilitiesKHR = undefined;
            try vk.check(r.i.GetPhysicalDeviceSurfaceCapabilitiesKHR.?(r.physical, r.surface, &caps));
            var extent = caps.current_extent;
            if (extent.width == 0xffff_ffff) extent = .{
                .width = std.math.clamp(w, caps.min_image_extent.width, caps.max_image_extent.width),
                .height = std.math.clamp(h, caps.min_image_extent.height, caps.max_image_extent.height),
            };
            r.extent = extent;
            if (extent.width == 0 or extent.height == 0) return; // minimized
            var count = caps.min_image_count + 1;
            if (caps.max_image_count != 0) count = @min(count, caps.max_image_count);
            const alpha: vk.Flags = if (caps.supported_composite_alpha & vk.COMPOSITE_ALPHA_OPAQUE != 0) vk.COMPOSITE_ALPHA_OPAQUE else caps.supported_composite_alpha & (~caps.supported_composite_alpha +% 1);
            const old = r.swapchain;
            try vk.check(d.CreateSwapchainKHR.?(r.device, &.{
                .surface = r.surface,
                .min_image_count = count,
                .image_format = r.format,
                .image_color_space = r.color_space,
                .image_extent = extent,
                .image_usage = vk.IMAGE_USAGE_COLOR_ATTACHMENT | (caps.supported_usage_flags & vk.IMAGE_USAGE_TRANSFER_SRC),
                .pre_transform = caps.current_transform,
                .composite_alpha = alpha,
                .present_mode = r.present_mode,
                .old_swapchain = old,
            }, null, &r.swapchain));
            if (old != 0) d.DestroySwapchainKHR.?(r.device, old, null);
            var n: u32 = 0;
            try vk.check(d.GetSwapchainImagesKHR.?(r.device, r.swapchain, &n, null));
            var images: [16]vk.Image = undefined;
            n = @min(n, images.len);
            try vk.check(d.GetSwapchainImagesKHR.?(r.device, r.swapchain, &n, &images));
            for (images[0..n]) |img| {
                var t = Target{ .image = img };
                try vk.check(d.CreateImageView(r.device, &.{ .image = img, .format = r.format }, null, &t.view));
                try vk.check(d.CreateSemaphore(r.device, &.{}, null, &t.done));
                try r.targets.append(r.gpa, t);
            }
        }
        for (r.targets.items) |*t| {
            const views = [_]vk.ImageView{t.view};
            try vk.check(d.CreateFramebuffer(r.device, &.{ .render_pass = r.render_pass, .p_attachments = &views, .width = r.extent.width, .height = r.extent.height }, null, &t.framebuffer));
        }
    }

    fn destroyAtlas(r: *Renderer) void {
        const d = r.d;
        if (r.atlas_view != 0) d.DestroyImageView(r.device, r.atlas_view, null);
        if (r.atlas_image != 0) d.DestroyImage(r.device, r.atlas_image, null);
        if (r.atlas_memory != 0) d.FreeMemory(r.device, r.atlas_memory, null);
        r.atlas_view = 0;
        r.atlas_image = 0;
        r.atlas_memory = 0;
        r.atlas_size = 0;
    }

    fn destroyImages(r: *Renderer) void {
        const d = r.d;
        if (r.images_view != 0) d.DestroyImageView(r.device, r.images_view, null);
        if (r.images_image != 0) d.DestroyImage(r.device, r.images_image, null);
        if (r.images_memory != 0) d.FreeMemory(r.device, r.images_memory, null);
        r.images_view = 0;
        r.images_image = 0;
        r.images_memory = 0;
        r.images_size = 0;
    }

    /// makeImages makes the image texture images.size texels a side (one
    /// texel while no image was drawn); the device must be idle.
    fn makeImages(r: *Renderer) !void {
        r.destroyImages();
        const sz = if (r.images.used) r.images.size else 1;
        try r.deviceImage(.b8g8r8a8_unorm, sz, sz, vk.IMAGE_USAGE_SAMPLED | vk.IMAGE_USAGE_TRANSFER_DST, &r.images_image, &r.images_memory, &r.images_view);
        r.images_size = sz;
        r.images_fresh = true;
        const img = [_]vk.DescriptorImageInfo{.{ .sampler = r.image_sampler, .image_view = r.images_view, .image_layout = .shader_read_only_optimal }};
        const w = [_]vk.WriteDescriptorSet{.{ .dst_set = r.set, .dst_binding = 1, .descriptor_count = 1, .descriptor_type = vk.DESCRIPTOR_COMBINED_IMAGE_SAMPLER, .p_image_info = &img }};
        r.d.UpdateDescriptorSets(r.device, 1, &w, 0, null);
    }

    /// upload clears a texture just made, and copies regions of the
    /// staging buffer into it.
    fn upload(r: *Renderer, cmd: vk.CommandBuffer, image: vk.Image, fresh: *bool, staging: vk.Buffer, copies: []const vk.BufferImageCopy) void {
        if (copies.len == 0 and !fresh.*) return;
        const d = r.d;
        const to_dst = [_]vk.ImageMemoryBarrier{.{
            .src_access_mask = if (fresh.*) 0 else vk.ACCESS_SHADER_READ,
            .dst_access_mask = vk.ACCESS_TRANSFER_WRITE,
            .old_layout = if (fresh.*) .undefined else .shader_read_only_optimal,
            .new_layout = .transfer_dst_optimal,
            .image = image,
        }};
        d.CmdPipelineBarrier(cmd, if (fresh.*) vk.STAGE_TOP_OF_PIPE else vk.STAGE_FRAGMENT_SHADER, vk.STAGE_TRANSFER, 0, 0, null, 0, null, 1, &to_dst);
        if (fresh.*) {
            const range = [_]vk.ImageSubresourceRange{.{}};
            d.CmdClearColorImage(cmd, image, .transfer_dst_optimal, &.{ .float32 = .{ 0, 0, 0, 0 } }, 1, &range);
            fresh.* = false;
        }
        if (copies.len > 0) d.CmdCopyBufferToImage(cmd, staging, image, .transfer_dst_optimal, @intCast(copies.len), copies.ptr);
        const to_read = [_]vk.ImageMemoryBarrier{.{
            .src_access_mask = vk.ACCESS_TRANSFER_WRITE,
            .dst_access_mask = vk.ACCESS_SHADER_READ,
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .image = image,
        }};
        d.CmdPipelineBarrier(cmd, vk.STAGE_TRANSFER, vk.STAGE_FRAGMENT_SHADER, 0, 0, null, 0, null, 1, &to_read);
    }

    /// makeAtlas makes the glyph texture atlas.size texels a side; the
    /// device must be idle (it is replaced only when it grows).
    fn makeAtlas(r: *Renderer) !void {
        r.destroyAtlas();
        const sz = r.atlas.size;
        try r.deviceImage(.r8_unorm, sz, sz, vk.IMAGE_USAGE_SAMPLED | vk.IMAGE_USAGE_TRANSFER_DST, &r.atlas_image, &r.atlas_memory, &r.atlas_view);
        r.atlas_size = sz;
        r.atlas_fresh = true;
        const img = [_]vk.DescriptorImageInfo{.{ .sampler = r.sampler, .image_view = r.atlas_view, .image_layout = .shader_read_only_optimal }};
        const w = [_]vk.WriteDescriptorSet{.{ .dst_set = r.set, .dst_binding = 0, .descriptor_count = 1, .descriptor_type = vk.DESCRIPTOR_COMBINED_IMAGE_SAMPLER, .p_image_info = &img }};
        r.d.UpdateDescriptorSets(r.device, 1, &w, 0, null);
    }

    /// draw draws s, width×height pixels, and presents it.
    pub fn draw(r: *Renderer, s: *const scene.Scene, fonts: *text.Fonts, width: i32, height: i32) !void {
        const d = r.d;
        const dev = r.device;
        try inst.build(s, fonts, &r.atlas, &r.images, &r.instances);
        const w: u32 = @intCast(@max(1, width));
        const h: u32 = @intCast(@max(1, height));

        const f = &r.frames[r.frame];
        try vk.check(d.WaitForFences(dev, 1, &.{f.fence}, 1, std.math.maxInt(u64)));
        if (r.readback_frame == r.frame) r.readback_frame = null;

        if (r.atlas.grown or r.atlas_size != r.atlas.size) {
            _ = d.DeviceWaitIdle(dev);
            try r.makeAtlas();
            r.atlas.grown = false;
        }
        const images_size = if (r.images.used) r.images.size else 1;
        if (r.images_size != images_size or (r.images.grown and r.images.used)) {
            _ = d.DeviceWaitIdle(dev);
            try r.makeImages();
            r.images.grown = false;
        }
        if (r.stale or r.extent.width != w or r.extent.height != h) {
            _ = d.DeviceWaitIdle(dev);
            try r.resize(w, h);
        }
        if (r.extent.width == 0 or r.extent.height == 0) return;

        var index: u32 = 0;
        if (!r.offscreen) {
            var res = d.AcquireNextImageKHR.?(dev, r.swapchain, std.math.maxInt(u64), f.acquired, 0, &index);
            if (res == vk.ERROR_OUT_OF_DATE_KHR) {
                _ = d.DeviceWaitIdle(dev);
                try r.resize(w, h);
                if (r.extent.width == 0 or r.extent.height == 0) return;
                res = d.AcquireNextImageKHR.?(dev, r.swapchain, std.math.maxInt(u64), f.acquired, 0, &index);
            }
            if (res != vk.SUCCESS and res != vk.SUBOPTIMAL_KHR) return vk.check(res);
        }
        const target = r.targets.items[index];

        // The instances, and the glyphs new this frame, into the frame's
        // buffers.
        const n = r.instances.items.len;
        try r.ensureHost(&f.instances, @max(1, n) * @sizeOf(inst.Instance), vk.BUFFER_USAGE_VERTEX);
        @memcpy(f.instances.ptr[0 .. n * @sizeOf(inst.Instance)], std.mem.sliceAsBytes(r.instances.items));
        var upload_bytes: usize = 0;
        for (r.atlas.uploads.items) |u| upload_bytes += std.mem.alignForward(usize, u.w * u.h, 4);
        for (r.images.uploads.items) |u| upload_bytes += u.image.pixels.len * 4;
        var copies: std.ArrayListUnmanaged(vk.BufferImageCopy) = .empty;
        defer copies.deinit(r.gpa);
        var glyph_copies: usize = 0;
        if (upload_bytes > 0) {
            try r.ensureHost(&f.staging, upload_bytes, vk.BUFFER_USAGE_TRANSFER_SRC);
            try copies.ensureTotalCapacity(r.gpa, r.atlas.uploads.items.len + r.images.uploads.items.len);
            var off: usize = 0;
            for (r.atlas.uploads.items) |u| {
                const len = u.w * u.h;
                @memcpy(f.staging.ptr[off..][0..len], fonts.coverage.items[u.off..][0..len]);
                copies.appendAssumeCapacity(.{
                    .buffer_offset = off,
                    .image_offset = .{ .x = @intCast(u.x), .y = @intCast(u.y), .z = 0 },
                    .image_extent = .{ .width = u.w, .height = u.h, .depth = 1 },
                });
                off += std.mem.alignForward(usize, len, 4);
            }
            glyph_copies = copies.items.len;
            for (r.images.uploads.items) |u| {
                const bytes = std.mem.sliceAsBytes(u.image.pixels);
                @memcpy(f.staging.ptr[off..][0..bytes.len], bytes);
                copies.appendAssumeCapacity(.{
                    .buffer_offset = off,
                    .image_offset = .{ .x = @intCast(u.x), .y = @intCast(u.y), .z = 0 },
                    .image_extent = .{ .width = u.image.width, .height = u.image.height, .depth = 1 },
                });
                off += bytes.len;
            }
        }
        r.atlas.uploads.clearRetainingCapacity();
        r.images.uploads.clearRetainingCapacity();
        if (r.capture) try r.ensureHost(&r.readback, r.extent.width * r.extent.height * 4, vk.BUFFER_USAGE_TRANSFER_DST);

        try vk.check(d.ResetFences(dev, 1, &.{f.fence}));
        const cmd = f.cmd;
        try vk.check(d.ResetCommandBuffer(cmd, 0));
        try vk.check(d.BeginCommandBuffer(cmd, &.{ .flags = vk.COMMAND_BUFFER_ONE_TIME }));

        r.upload(cmd, r.atlas_image, &r.atlas_fresh, f.staging.buffer, copies.items[0..glyph_copies]);
        r.upload(cmd, r.images_image, &r.images_fresh, f.staging.buffer, copies.items[glyph_copies..]);

        const bg = s.background;
        const clear = [_]vk.ClearValue{.{ .color = .{ @as(f32, @floatFromInt(bg.r)) / 255, @as(f32, @floatFromInt(bg.g)) / 255, @as(f32, @floatFromInt(bg.b)) / 255, 1 } }};
        const area = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = r.extent };
        d.CmdBeginRenderPass(cmd, &.{ .render_pass = r.render_pass, .framebuffer = target.framebuffer, .render_area = area, .clear_value_count = 1, .p_clear_values = &clear }, 0);
        if (n > 0) {
            const vp = [_]vk.Viewport{.{ .x = 0, .y = 0, .width = @floatFromInt(r.extent.width), .height = @floatFromInt(r.extent.height), .min_depth = 0, .max_depth = 1 }};
            d.CmdSetViewport(cmd, 0, 1, &vp);
            d.CmdSetScissor(cmd, 0, 1, &.{area});
            d.CmdBindPipeline(cmd, 0, r.pipeline);
            d.CmdBindDescriptorSets(cmd, 0, r.pipeline_layout, 0, 1, &.{r.set}, 0, null);
            d.CmdBindVertexBuffers(cmd, 0, 1, &.{f.instances.buffer}, &.{0});
            const viewport = [2]f32{ @floatFromInt(r.extent.width), @floatFromInt(r.extent.height) };
            d.CmdPushConstants(cmd, r.pipeline_layout, vk.SHADER_STAGE_VERTEX, 0, 8, &viewport);
            d.CmdDraw(cmd, 4, @intCast(n), 0, 0);
        }
        d.CmdEndRenderPass(cmd);

        if (r.capture) {
            const final: vk.ImageLayout = if (r.offscreen) .transfer_src_optimal else .present_src_khr;
            if (!r.offscreen) {
                const b = [_]vk.ImageMemoryBarrier{.{ .src_access_mask = vk.ACCESS_COLOR_ATTACHMENT_WRITE, .dst_access_mask = vk.ACCESS_TRANSFER_READ, .old_layout = final, .new_layout = .transfer_src_optimal, .image = target.image }};
                d.CmdPipelineBarrier(cmd, vk.STAGE_COLOR_ATTACHMENT_OUTPUT, vk.STAGE_TRANSFER, 0, 0, null, 0, null, 1, &b);
            }
            const region = [_]vk.BufferImageCopy{.{ .buffer_offset = 0, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = r.extent.width, .height = r.extent.height, .depth = 1 } }};
            d.CmdCopyImageToBuffer(cmd, target.image, .transfer_src_optimal, r.readback.buffer, 1, &region);
            if (!r.offscreen) {
                const b = [_]vk.ImageMemoryBarrier{.{ .src_access_mask = vk.ACCESS_TRANSFER_READ, .dst_access_mask = vk.ACCESS_MEMORY_READ, .old_layout = .transfer_src_optimal, .new_layout = final, .image = target.image }};
                d.CmdPipelineBarrier(cmd, vk.STAGE_TRANSFER, vk.STAGE_BOTTOM_OF_PIPE, 0, 0, null, 0, null, 1, &b);
            }
            r.readback_frame = r.frame;
        }
        try vk.check(d.EndCommandBuffer(cmd));

        const wait_stage = [_]vk.Flags{vk.STAGE_COLOR_ATTACHMENT_OUTPUT};
        const submit = [_]vk.SubmitInfo{if (r.offscreen) .{
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmd},
        } else .{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = &.{f.acquired},
            .p_wait_dst_stage_mask = &wait_stage,
            .command_buffer_count = 1,
            .p_command_buffers = &.{cmd},
            .signal_semaphore_count = 1,
            .p_signal_semaphores = &.{target.done},
        }};
        try vk.check(d.QueueSubmit(r.queue, 1, &submit, f.fence));

        if (!r.offscreen) {
            const res = d.QueuePresentKHR.?(r.queue, &.{
                .wait_semaphore_count = 1,
                .p_wait_semaphores = &.{target.done},
                .swapchain_count = 1,
                .p_swapchains = &.{r.swapchain},
                .p_image_indices = &.{index},
            });
            if (res == vk.ERROR_OUT_OF_DATE_KHR or res == vk.SUBOPTIMAL_KHR) r.stale = true else try vk.check(res);
        }
        r.frame = (r.frame + 1) % frames_in_flight;
    }

    /// read copies the last frame drawn with capture set into out, as
    /// 0x00RRGGBB, top row first.
    pub fn read(r: *Renderer, width: i32, height: i32, out: []u32) void {
        const fi = r.readback_frame orelse return;
        _ = r.d.WaitForFences(r.device, 1, &.{r.frames[fi].fence}, 1, std.math.maxInt(u64));
        const w: usize = @intCast(@min(width, @as(i32, @intCast(r.extent.width))));
        const h: usize = @intCast(@min(height, @as(i32, @intCast(r.extent.height))));
        const src: [*]const u32 = @ptrCast(@alignCast(r.readback.ptr));
        const stride: usize = r.extent.width;
        const swap = r.format == .r8g8b8a8_unorm;
        for (0..h) |y| for (0..w) |x| {
            const v = src[y * stride + x];
            out[y * @as(usize, @intCast(width)) + x] = if (swap) ((v & 0xff) << 16) | (v & 0xff00) | ((v >> 16) & 0xff) else v & 0xffffff;
        };
    }
};

test "offscreen Vulkan draws what the CPU renderer draws" {
    const gpa = std.testing.allocator;
    const geom = @import("../geom.zig");
    const raster = @import("../raster.zig");
    var r = Renderer.init(gpa, .offscreen, 320, 120, .{ .validation = env.has("MYZIG_VK_VALIDATION") }) catch |e| {
        sys.print("no Vulkan device ({s}); skipped\n", .{@errorName(e)});
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
    s.textRun(&fonts, 20, 80, "Vulkan · quick 123", 16, .regular, geom.Color.black);
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
    // Edges may round apart by a little; nothing else may differ.
    var worst: u32 = 0;
    for (gpu_px, cpu_px) |a, b| inline for (.{ 0, 8, 16 }) |sh| {
        const da: i32 = @intCast((a >> sh) & 0xff);
        const db: i32 = @intCast((b >> sh) & 0xff);
        worst = @max(worst, @abs(da - db));
    };
    if (env.get("MYZIG_DUMP")) |path| {
        var buf: [4096]u8 = undefined;
        var fw = try sys.create(path, &buf);
        defer fw.close();
        try fw.interface.print("P6\n320 240\n255\n", .{});
        for ([_][]const u32{ gpu_px, cpu_px }) |px| for (px) |p| try fw.interface.writeAll(&.{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) });
        try fw.interface.flush();
    }
    std.testing.expect(worst <= 8) catch |e| {
        sys.print("Vulkan and CPU pixels differ by up to {d}\n", .{worst});
        return e;
    };
    try std.testing.expectEqual(cpu_px[30 * 320 + 70], gpu_px[30 * 320 + 70]);
}

const Dl_info = extern struct {
    dli_fname: ?[*:0]const u8,
    dli_fbase: ?*anyopaque,
    dli_sname: ?[*:0]const u8,
    dli_saddr: ?*anyopaque,
};
extern "c" fn dladdr(addr: *const anyopaque, info: *Dl_info) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn readdir(dir: *std.c.DIR) ?*std.c.dirent;
