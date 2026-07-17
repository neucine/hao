const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const default_quickjs_stack_size: usize = 8 * 1024 * 1024;

pub const Config = struct {
    quickjs: QuickJS = .{},
    libuv: Libuv = .{},
    debug: Debug = .{},

    pub const QuickJS = struct {
        stack_size: usize = default_quickjs_stack_size,
    };

    pub const Libuv = struct {
        thread_pool_size: ?usize = null,
    };

    pub const Debug = struct {
        native_stack_trace: bool = false,
    };
};

pub const RuntimeOptions = struct {
    quickjs_stack_size: usize = default_quickjs_stack_size,
};

pub var config: Config = .{};

fn getenv(key: [:0]const u8) ?[]const u8 {
    const value = c.getenv(key.ptr) orelse return null;
    return std.mem.span(value);
}

fn parsePositiveUsize(s: []const u8) ?usize {
    const n = std.fmt.parseInt(usize, s, 10) catch return null;
    if (n == 0) return null;
    return n;
}

fn parseBool(s: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(s, "1")) return true;
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "on")) return true;
    if (std.ascii.eqlIgnoreCase(s, "0")) return false;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    if (std.ascii.eqlIgnoreCase(s, "no")) return false;
    if (std.ascii.eqlIgnoreCase(s, "off")) return false;
    return null;
}

fn loadUsize(key: [:0]const u8, dest: *usize) void {
    const val = getenv(key) orelse return;
    if (parsePositiveUsize(val)) |n| dest.* = n;
}

fn loadOptionalUsize(key: [:0]const u8, dest: *?usize) void {
    const val = getenv(key) orelse return;
    if (parsePositiveUsize(val)) |n| dest.* = n;
}

fn loadBool(key: [:0]const u8, dest: *bool) void {
    const val = getenv(key) orelse return;
    if (parseBool(val)) |flag| dest.* = flag;
}

fn setProcessEnv(key: [:0]const u8, value: []const u8) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;

    var value_z = try std.heap.page_allocator.alloc(u8, value.len + 1);
    defer std.heap.page_allocator.free(value_z);
    @memcpy(value_z[0..value.len], value);
    value_z[value.len] = 0;

    if (c.setenv(key.ptr, value_z.ptr, 1) != 0) return error.SetEnvFailed;
}

pub fn syncLibuvThreadPoolEnv() !void {
    const size = config.libuv.thread_pool_size orelse return;
    var buf: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d}", .{size});
    try setProcessEnv("UV_THREADPOOL_SIZE", value);
}

pub fn loadFromEnv() !void {
    loadUsize("HAO_QJS_STACK_SIZE", &config.quickjs.stack_size);
    loadOptionalUsize("HAO_LIBUV_THREADPOOL_SIZE", &config.libuv.thread_pool_size);
    loadBool("HAO_NATIVE_STACK_TRACE", &config.debug.native_stack_trace);
    try syncLibuvThreadPoolEnv();
}

pub fn runtimeOptions() RuntimeOptions {
    return .{
        .quickjs_stack_size = config.quickjs.stack_size,
    };
}

test "Config defaults are correct" {
    const def = Config{};
    try std.testing.expectEqual(@as(usize, 8 * 1024 * 1024), def.quickjs.stack_size);
    try std.testing.expectEqual(@as(?usize, null), def.libuv.thread_pool_size);
    try std.testing.expectEqual(false, def.debug.native_stack_trace);
}

test "loadUsize ignores missing env key" {
    var dest: usize = 42;
    loadUsize("HAO_NONEXISTENT_KEY_ZZZYYYXXX", &dest);
    try std.testing.expectEqual(@as(usize, 42), dest);
}

test "loadOptionalUsize ignores missing env key" {
    var dest: ?usize = 42;
    loadOptionalUsize("HAO_NONEXISTENT_OPTIONAL_KEY_ZZZYYYXXX", &dest);
    try std.testing.expectEqual(@as(?usize, 42), dest);
}

test "parsePositiveUsize rejects zero" {
    try std.testing.expectEqual(@as(?usize, null), parsePositiveUsize("0"));
}

test "parsePositiveUsize rejects non-numeric" {
    try std.testing.expectEqual(@as(?usize, null), parsePositiveUsize("notanumber"));
}

test "parsePositiveUsize accepts positive integer" {
    try std.testing.expectEqual(@as(?usize, 256), parsePositiveUsize("256"));
}

test "parseBool accepts common true and false values" {
    try std.testing.expectEqual(@as(?bool, true), parseBool("1"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("true"));
    try std.testing.expectEqual(@as(?bool, true), parseBool("YES"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("0"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("false"));
    try std.testing.expectEqual(@as(?bool, false), parseBool("Off"));
    try std.testing.expectEqual(@as(?bool, null), parseBool("maybe"));
}

test "syncLibuvThreadPoolEnv mirrors config into UV_THREADPOOL_SIZE" {
    const old = getenv("UV_THREADPOOL_SIZE");
    defer {
        if (old) |value| {
            _ = c.setenv("UV_THREADPOOL_SIZE", value.ptr, 1);
        } else {
            _ = c.unsetenv("UV_THREADPOOL_SIZE");
        }
        config.libuv.thread_pool_size = null;
    }

    config.libuv.thread_pool_size = 7;
    try syncLibuvThreadPoolEnv();
    try std.testing.expectEqualStrings("7", getenv("UV_THREADPOOL_SIZE").?);
}
