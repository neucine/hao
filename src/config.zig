const std = @import("std");
const zig_libs = @import("zig_libs");
const fs = @import("fs.zig");
const runtime_allocator = @import("runtime_allocator.zig");

const cfg = zig_libs.config;

pub const default_qjs_stack_size: usize = 8 * 1024 * 1024;

pub const Config = struct {
    qjs: QJS = .{},
    libuv: Libuv = .{},
    debug: Debug = .{},
    telemetry: Telemetry = .{},
    package: Package = .{},

    pub const QJS = struct {
        stack_size: cfg.Startup(usize, .{
            .env = "RUNTIME_QJS_STACK_SIZE",
            .default = default_qjs_stack_size,
            .parser = .positive_int,
        }) = .{},
        gc_threshold: cfg.Startup(?usize, .{
            .env = "RUNTIME_QJS_GC_THRESHOLD",
            .parser = .positive_int,
        }) = .{},
    };

    pub const Libuv = struct {
        thread_pool_size: cfg.Startup(?usize, .{
            .env = "RUNTIME_LIBUV_THREADPOOL_SIZE",
            .parser = .positive_int,
        }) = .{},
    };

    pub const Debug = struct {
        native_stack_trace: cfg.Runtime(bool, .{
            .env = "RUNTIME_NATIVE_STACK_TRACE",
        }) = .{},
    };

    pub const Telemetry = struct {
        console_enabled: cfg.Runtime(bool, .{
            .env = "RUNTIME_TELEMETRY_CONSOLE",
        }) = .{},
        console_port: cfg.Runtime(u16, .{
            .env = "RUNTIME_TELEMETRY_CONSOLE_PORT",
            .parser = .int_allow_zero,
        }) = .{},
    };

    pub const Package = struct {
        path: cfg.Runtime(?[]const u8, .{
            .env = "RUNTIME_PACKAGE_PATH",
            .parser = .non_empty_string,
        }) = .{},
    };
};

pub const RuntimeOptions = struct {
    qjs_stack_size: usize = default_qjs_stack_size,
    qjs_gc_threshold: ?usize = null,
};

pub var config = cfg.Store(Config).init();

fn allocator() std.mem.Allocator {
    return runtime_allocator.allocator();
}

pub fn loadDotenv() !void {
    _ = try cfg.loadDotenvFromEnv(allocator());
}

pub fn syncLibuvThreadPoolEnv() !void {
    try cfg.syncOptionalUsizeEnv("UV_THREADPOOL_SIZE", config.read().libuv.thread_pool_size.get());
}

pub fn loadFromEnv() !void {
    try loadDotenv();
    _ = try config.loadEnv();
    config.freezeStartup();
    try syncLibuvThreadPoolEnv();
}

pub fn runtimeOptions() RuntimeOptions {
    return .{
        .qjs_stack_size = config.read().qjs.stack_size.get(),
        .qjs_gc_threshold = config.read().qjs.gc_threshold.get(),
    };
}

test "Config defaults are correct" {
    const def = Config{};
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), def.qjs.stack_size.get());
    try std.testing.expectEqual(@as(?usize, null), def.libuv.thread_pool_size.get());
    try std.testing.expectEqual(false, def.debug.native_stack_trace.get());
    try std.testing.expectEqual(false, def.telemetry.console_enabled.get());
    try std.testing.expectEqual(@as(u16, 0), def.telemetry.console_port.get());
    try std.testing.expectEqual(@as(?[]const u8, null), def.package.path.get());
}

test "loadFromEnv reads schema-backed values" {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const old_stack = cfg.getenv("RUNTIME_QJS_STACK_SIZE");
    const old_gc = cfg.getenv("RUNTIME_QJS_GC_THRESHOLD");
    const old_trace = cfg.getenv("RUNTIME_NATIVE_STACK_TRACE");
    defer {
        if (old_stack) |value| {
            _ = c.setenv("RUNTIME_QJS_STACK_SIZE", value.ptr, 1);
        } else {
            _ = c.unsetenv("RUNTIME_QJS_STACK_SIZE");
        }
        if (old_gc) |value| {
            _ = c.setenv("RUNTIME_QJS_GC_THRESHOLD", value.ptr, 1);
        } else {
            _ = c.unsetenv("RUNTIME_QJS_GC_THRESHOLD");
        }
        if (old_trace) |value| {
            _ = c.setenv("RUNTIME_NATIVE_STACK_TRACE", value.ptr, 1);
        } else {
            _ = c.unsetenv("RUNTIME_NATIVE_STACK_TRACE");
        }
        config = cfg.Store(Config).init();
    }

    try cfg.setProcessEnv("RUNTIME_QJS_STACK_SIZE", "16");
    try cfg.setProcessEnv("RUNTIME_QJS_GC_THRESHOLD", "32");
    try cfg.setProcessEnv("RUNTIME_NATIVE_STACK_TRACE", "on");

    config = cfg.Store(Config).init();
    _ = try config.loadEnv();

    try std.testing.expectEqual(@as(usize, 16), config.read().qjs.stack_size.get());
    try std.testing.expectEqual(@as(?usize, 32), config.read().qjs.gc_threshold.get());
    try std.testing.expectEqual(true, config.read().debug.native_stack_trace.get());
}

test "syncLibuvThreadPoolEnv mirrors config into UV_THREADPOOL_SIZE" {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const old = cfg.getenv("UV_THREADPOOL_SIZE");
    defer {
        if (old) |value| {
            _ = c.setenv("UV_THREADPOOL_SIZE", value.ptr, 1);
        } else {
            _ = c.unsetenv("UV_THREADPOOL_SIZE");
        }
        config = cfg.Store(Config).init();
    }

    try config.set("libuv.thread_pool_size", @as(?usize, 7));
    try syncLibuvThreadPoolEnv();
    try std.testing.expectEqualStrings("7", cfg.getenv("UV_THREADPOOL_SIZE").?);
}

test "dotenv loader loads missing keys without overriding environment" {
    const c = @cImport({
        @cInclude("stdlib.h");
    });
    const path = ".zig-cache/hao-tests/dotenv/config.env";
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/dotenv");
    try fs.writeFile(path,
        \\RUNTIME_DOTENV_TEST_KEEP=from-file
        \\RUNTIME_DOTENV_TEST_EXISTING=from-file
        \\
    );

    _ = c.unsetenv("RUNTIME_DOTENV_TEST_KEEP");
    try cfg.setProcessEnv("RUNTIME_DOTENV_TEST_EXISTING", "from-env");
    defer {
        _ = c.unsetenv("RUNTIME_DOTENV_TEST_KEEP");
        _ = c.unsetenv("RUNTIME_DOTENV_TEST_EXISTING");
    }

    _ = try cfg.loadDotenvFile(allocator(), .{ .path = path, .required = true });
    try std.testing.expectEqualStrings("from-file", cfg.getenv("RUNTIME_DOTENV_TEST_KEEP").?);
    try std.testing.expectEqualStrings("from-env", cfg.getenv("RUNTIME_DOTENV_TEST_EXISTING").?);
}
