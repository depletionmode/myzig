const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from executables") orelse (optimize != .debug);

    const mod = b.addModule("myzig", .{
        .root_source_file = b.path("src/myzig.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addCSourceFile(.{ .file = b.path("vendor/stb_truetype.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    mod.addCSourceFile(.{ .file = b.path("vendor/stb_image.c"), .flags = &.{ "-O2", "-fno-sanitize=undefined" } });
    if (target.result.os.tag == .windows) {
        mod.linkSystemLibrary("user32", .{});
        mod.linkSystemLibrary("gdi32", .{});
        mod.linkSystemLibrary("dwmapi", .{});
        mod.linkSystemLibrary("winmm", .{});
        mod.linkSystemLibrary("imm32", .{});
    } else if (target.result.os.tag == .macos) {
        // Cocoa, Metal and the Objective-C runtime are opened at run time
        // (src/mac/objc.zig): building for macOS needs no SDK.
    } else {
        mod.linkSystemLibrary("X11", .{});
        mod.linkSystemLibrary("Xext", .{});
    }

    const only = b.option([]const u8, "only", "Build only this example (and no benchmark)");
    const examples = [_][]const u8{ "counter", "quotes", "list", "gallery", "events", "editor" };
    const test_step = b.step("test", "Run the tests");
    inline for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip,
                .imports = &.{.{ .name = "myzig", .module = mod }},
            }),
        });
        if (only == null or std.mem.eql(u8, only.?, name)) b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        // Arguments after `--` on the zig build command line are passed
        // through to run steps automatically (no b.args in 0.17).
        b.step(name, "Run the " ++ name ++ " example").dependOn(&run.step);
        const t = b.addTest(.{ .root_module = exe.root_module });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    const bench = b.addExecutable(.{
        .name = "frames",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/frames.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{.{ .name = "myzig", .module = mod }},
        }),
    });
    bench.root_module.addAnonymousImport("counter", .{ .root_source_file = b.path("examples/counter.zig"), .imports = &.{.{ .name = "myzig", .module = mod }} });
    bench.root_module.addAnonymousImport("quotes", .{ .root_source_file = b.path("examples/quotes.zig"), .imports = &.{.{ .name = "myzig", .module = mod }} });
    bench.root_module.addAnonymousImport("list", .{ .root_source_file = b.path("examples/list.zig"), .imports = &.{.{ .name = "myzig", .module = mod }} });
    if (only == null) b.installArtifact(bench);
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Time headless frames of each workload").dependOn(&run_bench.step);

    // The Vulkan shaders are checked in as SPIR-V, so building needs no
    // shader compiler; after editing src/gpu/shaders, run this step.
    const shaders = b.step("shaders", "Compile the Vulkan shaders to SPIR-V (needs glslangValidator)");
    inline for (.{ "box.vert", "box.frag" }) |sh| {
        const c = b.addSystemCommand(&.{ "glslangValidator", "-V", "--quiet", "-o" });
        c.addFileArg(b.path("src/gpu/shaders/" ++ sh ++ ".spv"));
        c.addFileArg(b.path("src/gpu/shaders/" ++ sh));
        shaders.dependOn(&c.step);
    }

    const unit = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(unit).step);
}
