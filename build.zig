const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library: the UI-agnostic "session server" that platform shells
    // (macOS Swift app, Linux GTK app, dev CLI) link against.
    const core = b.addModule("zidely", .{
        .root_source_file = b.path("src/zidely.zig"),
        .target = target,
        .optimize = optimize,
        // PTY layer uses libc (openpty, ioctl); ghostty-vt's SIMD needs it too.
        .link_libc = true,
    });

    // Ghostty's VT engine (terminal state machine), pinned to v1.3.1.
    // The emit flags must be false: their Darwin defaults are true, which
    // makes Ghostty's build construct xcframework/app steps that require
    // full Xcode (iOS SDK) even when only the vt module is consumed.
    const ghostty_dep = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    core.addImport("ghostty-vt", ghostty_dep.module("ghostty-vt"));

    // Event loop (kqueue/epoll/io_uring), same commit Ghostty pins.
    const libxev_dep = b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    });
    core.addImport("xev", libxev_dep.module("xev"));

    // Dev CLI: temporary entry point for exercising the core before the
    // native shells exist.
    const exe = b.addExecutable(.{
        .name = "zidely",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zidely", .module = core },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the dev CLI");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{ .root_module = core });
    const run_core_tests = b.addRunArtifact(core_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
