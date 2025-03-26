const std = @import("std");
const Build = std.Build;
const Target = Build.ResolvedTarget;
const Optimize = std.builtin.OptimizeMode;

const TranslateC = struct {
    linux_if_arp: *Build.Step.TranslateC,
    libssh: *Build.Step.TranslateC,

    fn init(b: *Build, target: Target, optimize: Optimize) TranslateC {
        const linux_if_arp = b.addTranslateC(.{
            .root_source_file = b.path("include/linux/linux/if_arp.h"),
            .link_libc = false,
            .target = target,
            .optimize = optimize,
        });
        linux_if_arp.addIncludePath(b.path("include/linux"));
        linux_if_arp.addIncludePath(b.path("include/libc"));

        const libssh = b.addTranslateC(.{
            .root_source_file = b.path("include/libssh/libssh/libssh.h"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        });
        libssh.addIncludePath(b.path("include/libssh"));
        libssh.addIncludePath(b.path("include/libc"));

        return .{
            .linux_if_arp = linux_if_arp,
            .libssh = libssh,
        };
    }
};

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .os_tag = .linux,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const c = TranslateC.init(b, target, optimize);
    const zargs = b.dependency("zargs", .{});

    const larp = b.addExecutable(.{
        .name = "larp",
        .root_source_file = b.path("larp.zig"),
        .target = target,
        .optimize = optimize,
    });
    larp.root_module.addImport("linux_if_arp", c.linux_if_arp.createModule());
    larp.root_module.addImport("libssh", c.libssh.createModule());
    larp.root_module.addImport("zargs", zargs.module("zargs"));
    larp.addLibraryPath(b.path("lib/libssh"));
    larp.linkSystemLibrary("ssh");
    b.installArtifact(larp);

    const run_larp = b.addRunArtifact(larp);
    run_larp.step.dependOn(b.getInstallStep());
    const run_larp_step = b.step("larp", "Run larp");
    run_larp_step.dependOn(&run_larp.step);

    // const larpy = b.addExecutable(.{
    //     .name = "larpy",
    //     .root_source_file = b.path("larpy.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // larpy.root_module.addImport("zargs", zargs.module("zargs"));
    // b.installArtifact(larpy);
    //
    // const run_larpy = b.addRunArtifact(larpy);
    // run_larpy.step.dependOn(b.getInstallStep());
    // const run_larpy_step = b.step("larpy", "Run larpy");
    // run_larpy_step.dependOn(&run_larpy.step);
}
