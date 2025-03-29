const std = @import("std");
const Build = std.Build;
const Target = Build.ResolvedTarget;
const Optimize = std.builtin.OptimizeMode;

fn libpath(key: []const u8) !Build.LazyPath {
    const path = std.posix.getenv(key) orelse return error.MissingEnv;
    return .{ .cwd_relative = path };
}

const TranslateC = struct {
    linux_if_arp: *Build.Step.TranslateC,
    libssh: *Build.Step.TranslateC,

    fn init(b: *Build, target: Target, optimize: Optimize) !TranslateC {
        const linux_include = try libpath("LINUX_INCLUDE_DIR");
        const libc_include = try libpath("LIBC_INCLUDE_DIR");
        const libssh_include = try libpath("LIBSSH_INCLUDE_DIR");

        const linux_if_arp = b.addTranslateC(.{
            .root_source_file = b.path("translate-c/linux/if_arp.h"),
            .link_libc = false,
            .target = target,
            .optimize = optimize,
        });
        linux_if_arp.addIncludePath(linux_include);
        linux_if_arp.addIncludePath(libc_include);

        const libssh = b.addTranslateC(.{
            .root_source_file = b.path("translate-c/libssh/libssh.h"),
            .link_libc = true,
            .target = target,
            .optimize = optimize,
        });
        libssh.addIncludePath(libssh_include);
        libssh.addIncludePath(libc_include);

        return .{
            .linux_if_arp = linux_if_arp,
            .libssh = libssh,
        };
    }
};

pub fn build(b: *Build) !void {
    const libssh = try libpath("LIBSSH_DIR");
    const target = b.standardTargetOptions(.{
        .default_target = .{
            .abi = .gnu,
            .os_tag = .linux,
        },
    });
    const optimize = b.standardOptimizeOption(.{});
    const c = try TranslateC.init(b, target, optimize);
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
    larp.addLibraryPath(libssh);
    larp.linkSystemLibrary("ssh");
    b.installArtifact(larp);
}
