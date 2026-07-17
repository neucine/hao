const std = @import("std");
const builtin = @import("builtin");
const fs = @import("fs.zig");

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

fn setProcessEnvIfMissing(key: []const u8, value: []const u8) !void {
    if (key.len == 0) return;
    if (std.mem.indexOfScalar(u8, key, 0) != null) return;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return;

    const key_z = try std.heap.page_allocator.dupeZ(u8, key);
    defer std.heap.page_allocator.free(key_z);
    if (getenv(key_z) != null) return;
    try setProcessEnv(key_z, value);
}

fn stripInlineComment(value: []const u8) []const u8 {
    var quote: ?u8 = null;
    var escaped = false;
    for (value, 0..) |ch, i| {
        if (escaped) {
            escaped = false;
            continue;
        }
        if (quote != null and ch == '\\') {
            escaped = true;
            continue;
        }
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '"' or ch == '\'') {
            quote = ch;
            continue;
        }
        if (ch == '#') {
            if (i == 0 or std.ascii.isWhitespace(value[i - 1])) {
                return std.mem.trim(u8, value[0..i], " \t\r");
            }
        }
    }
    return std.mem.trim(u8, value, " \t\r");
}

fn unquoteValue(value: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, value, " \t\r");
    if (trimmed.len >= 2) {
        const first = trimmed[0];
        const last = trimmed[trimmed.len - 1];
        if ((first == '"' and last == '"') or (first == '\'' and last == '\'')) {
            return trimmed[1 .. trimmed.len - 1];
        }
    }
    return trimmed;
}

fn parseDotenvLine(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    var trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    if (std.mem.startsWith(u8, trimmed, "export ")) {
        trimmed = std.mem.trim(u8, trimmed["export ".len..], " \t\r");
    }
    const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    const key = std.mem.trim(u8, trimmed[0..eq], " \t\r");
    if (key.len == 0) return null;
    const value = unquoteValue(stripInlineComment(trimmed[eq + 1 ..]));
    return .{ .key = key, .value = value };
}

fn loadDotenvFile(path: []const u8, required: bool) !void {
    const data = fs.readFileAlloc(std.heap.page_allocator, path, 1024 * 1024) catch |err| {
        if (!required and err == error.FileNotFound) return;
        return err;
    };
    defer std.heap.page_allocator.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const entry = parseDotenvLine(line) orelse continue;
        try setProcessEnvIfMissing(entry.key, entry.value);
    }
}

pub fn loadDotenv() !void {
    if (getenv("DOTENV")) |path| {
        if (path.len == 0) return;
        try loadDotenvFile(path, true);
        return;
    }
    try loadDotenvFile(".env", false);
}

pub fn syncLibuvThreadPoolEnv() !void {
    const size = config.libuv.thread_pool_size orelse return;
    var buf: [32]u8 = undefined;
    const value = try std.fmt.bufPrint(&buf, "{d}", .{size});
    try setProcessEnv("UV_THREADPOOL_SIZE", value);
}

pub fn loadFromEnv() !void {
    try loadDotenv();
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

test "parseDotenvLine handles comments quotes and export" {
    const plain = parseDotenvLine("HAO_QJS_STACK_SIZE=123 # comment").?;
    try std.testing.expectEqualStrings("HAO_QJS_STACK_SIZE", plain.key);
    try std.testing.expectEqualStrings("123", plain.value);

    const quoted = parseDotenvLine("export HAO_NATIVE_STACK_TRACE=\"true # kept\"").?;
    try std.testing.expectEqualStrings("HAO_NATIVE_STACK_TRACE", quoted.key);
    try std.testing.expectEqualStrings("true # kept", quoted.value);

    try std.testing.expect(parseDotenvLine("# ignored") == null);
}

test "loadDotenvFile loads missing keys without overriding environment" {
    const path = ".zig-cache/hao-tests/dotenv/config.env";
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/dotenv");
    try fs.writeFile(
        path,
        \\HAO_DOTENV_TEST_KEEP=from-file
        \\HAO_DOTENV_TEST_EXISTING=from-file
        \\
    );

    _ = c.unsetenv("HAO_DOTENV_TEST_KEEP");
    try setProcessEnv("HAO_DOTENV_TEST_EXISTING", "from-env");
    defer {
        _ = c.unsetenv("HAO_DOTENV_TEST_KEEP");
        _ = c.unsetenv("HAO_DOTENV_TEST_EXISTING");
    }

    try loadDotenvFile(path, true);
    try std.testing.expectEqualStrings("from-file", getenv("HAO_DOTENV_TEST_KEEP").?);
    try std.testing.expectEqualStrings("from-env", getenv("HAO_DOTENV_TEST_EXISTING").?);
}
