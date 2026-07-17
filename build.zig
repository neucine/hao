const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libuv_dep = b.dependency("libuv", .{});
    const quickjs_dep = b.dependency("quickjs", .{});

    const hao = b.addModule("hao", .{
        .root_source_file = b.path("src/hao.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    hao.addIncludePath(libuv_dep.path("include"));
    hao.addIncludePath(quickjs_dep.path("."));
    hao.addIncludePath(b.path("include"));

    const libuv = b.addLibrary(.{
        .name = "uv",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    libuv.root_module.addIncludePath(libuv_dep.path("include"));
    libuv.root_module.addIncludePath(libuv_dep.path("src"));
    libuv.root_module.addIncludePath(libuv_dep.path("src/unix"));
    libuv.root_module.addCSourceFiles(.{
        .root = libuv_dep.path("."),
        .files = &.{
            "src/fs-poll.c",
            "src/idna.c",
            "src/inet.c",
            "src/random.c",
            "src/strscpy.c",
            "src/strtok.c",
            "src/thread-common.c",
            "src/threadpool.c",
            "src/timer.c",
            "src/uv-common.c",
            "src/uv-data-getter-setters.c",
            "src/version.c",
            "src/unix/async.c",
            "src/unix/core.c",
            "src/unix/dl.c",
            "src/unix/fs.c",
            "src/unix/getaddrinfo.c",
            "src/unix/getnameinfo.c",
            "src/unix/loop-watcher.c",
            "src/unix/loop.c",
            "src/unix/pipe.c",
            "src/unix/poll.c",
            "src/unix/process.c",
            "src/unix/random-devurandom.c",
            "src/unix/signal.c",
            "src/unix/stream.c",
            "src/unix/tcp.c",
            "src/unix/thread.c",
            "src/unix/tty.c",
            "src/unix/udp.c",
        },
        .flags = &.{
            "-std=gnu11",
            "-D_FILE_OFFSET_BITS=64",
            "-D_LARGEFILE_SOURCE",
            "-D_GNU_SOURCE",
        },
    });
    if (target.result.os.tag == .macos) {
        libuv.root_module.addCSourceFiles(.{
            .root = libuv_dep.path("."),
            .files = &.{
                "src/unix/proctitle.c",
                "src/unix/bsd-ifaddrs.c",
                "src/unix/kqueue.c",
                "src/unix/random-getentropy.c",
                "src/unix/darwin-proctitle.c",
                "src/unix/darwin.c",
                "src/unix/fsevents.c",
            },
            .flags = &.{
                "-std=gnu11",
                "-D_FILE_OFFSET_BITS=64",
                "-D_LARGEFILE_SOURCE",
                "-D_DARWIN_UNLIMITED_SELECT=1",
                "-D_DARWIN_USE_64_BIT_INODE=1",
            },
        });
        libuv.root_module.linkFramework("CoreFoundation", .{});
        libuv.root_module.linkFramework("CoreServices", .{});
    } else if (target.result.os.tag == .linux) {
        libuv.root_module.addCSourceFiles(.{
            .root = libuv_dep.path("."),
            .files = &.{
                "src/unix/proctitle.c",
                "src/unix/linux.c",
                "src/unix/procfs-exepath.c",
                "src/unix/random-getrandom.c",
                "src/unix/random-sysctl-linux.c",
            },
            .flags = &.{
                "-std=gnu11",
                "-D_FILE_OFFSET_BITS=64",
                "-D_LARGEFILE_SOURCE",
                "-D_GNU_SOURCE",
                "-D_POSIX_C_SOURCE=200112",
            },
        });
        libuv.root_module.linkSystemLibrary("dl", .{});
        libuv.root_module.linkSystemLibrary("rt", .{});
    }

    const quickjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    quickjs.root_module.addIncludePath(quickjs_dep.path("."));
    quickjs.root_module.addCSourceFiles(.{
        .root = quickjs_dep.path("."),
        .files = &.{
            "quickjs.c",
            "libregexp.c",
            "libunicode.c",
            "dtoa.c",
        },
        .flags = &.{
            "-std=gnu11",
            "-fwrapv",
            "-D_GNU_SOURCE",
            "-DCONFIG_VERSION=\"0.13.0\"",
        },
    });

    const build_transpiler = b.addSystemCommand(&.{
        "cargo",
        "build",
        "--release",
        "--quiet",
    });
    build_transpiler.setCwd(b.path("libs/transpiler"));

    const exe = b.addExecutable(.{
        .name = "hao",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addIncludePath(libuv_dep.path("include"));
    exe.root_module.addIncludePath(quickjs_dep.path("."));
    exe.root_module.addIncludePath(b.path("include"));
    exe.root_module.linkLibrary(libuv);
    exe.root_module.linkLibrary(quickjs);
    exe.root_module.addLibraryPath(b.path("libs/transpiler/target/release"));
    exe.root_module.linkSystemLibrary("hao_transpiler", .{});
    exe.step.dependOn(&build_transpiler.step);

    if (target.result.os.tag == .macos) {
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("Security", .{});
        exe.root_module.linkSystemLibrary("iconv", .{});
    }

    b.installFile("include/addon.h", "include/addon.h");
    b.installFile("include/hao.h", "include/hao.h");
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hao.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addIncludePath(libuv_dep.path("include"));
    tests.root_module.addIncludePath(quickjs_dep.path("."));
    tests.root_module.addIncludePath(b.path("include"));
    tests.root_module.linkLibrary(libuv);
    tests.root_module.linkLibrary(quickjs);
    tests.root_module.addLibraryPath(b.path("libs/transpiler/target/release"));
    tests.root_module.linkSystemLibrary("hao_transpiler", .{});
    tests.step.dependOn(&build_transpiler.step);

    if (target.result.os.tag == .macos) {
        tests.root_module.linkFramework("CoreFoundation", .{});
        tests.root_module.linkFramework("Security", .{});
        tests.root_module.linkSystemLibrary("iconv", .{});
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Hao tests");
    test_step.dependOn(&run_tests.step);

    const run_step = b.step("run", "Run Hao");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
