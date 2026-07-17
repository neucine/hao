const std = @import("std");

const c = @cImport({
    @cInclude("errno.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub fn pathExists(path: []const u8) bool {
    var buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return c.access(&buf, c.F_OK) == 0;
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = c.fopen(&path_buf, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileReadFailed;
    const size_raw = c.ftell(file);
    if (size_raw < 0) return error.FileReadFailed;
    const size: usize = @intCast(size_raw);
    if (size > max_bytes) return error.StreamTooLong;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.FileReadFailed;

    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    if (size == 0) return out;
    const read_count = c.fread(out.ptr, 1, size, file);
    if (read_count != size) return error.FileReadFailed;
    return out;
}

pub fn fileSize(path: []const u8) !usize {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = c.fopen(&path_buf, "rb") orelse return error.FileNotFound;
    defer _ = c.fclose(file);

    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileReadFailed;
    const size_raw = c.ftell(file);
    if (size_raw < 0) return error.FileReadFailed;
    return @intCast(size_raw);
}

pub fn makeDir(path: []const u8) !void {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    if (c.mkdir(&path_buf, 0o755) != 0 and c.__error().* != c.EEXIST) {
        return error.MakeDirFailed;
    }
}

pub fn makePath(allocator: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0) return;
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    var parts = std.mem.splitScalar(u8, path, std.fs.path.sep);
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (current.items.len != 0) try current.append(allocator, std.fs.path.sep);
        try current.appendSlice(allocator, part);
        try makeDir(current.items);
    }
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    var path_buf: [std.Io.Dir.max_path_bytes + 1]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const file = c.fopen(&path_buf, "wb") orelse return error.FileWriteFailed;
    defer _ = c.fclose(file);
    if (data.len == 0) return;
    const written = c.fwrite(data.ptr, 1, data.len, file);
    if (written != data.len) return error.FileWriteFailed;
}

test "readFileAlloc reads a temp file" {
    try makePath(std.testing.allocator, ".zig-cache/hao-tests/fs");
    const path = ".zig-cache/hao-tests/fs/hello.txt";
    try writeFile(path, "hao");

    const source = try readFileAlloc(std.testing.allocator, path, 1024);
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings("hao", source);
    try std.testing.expect(pathExists(path));
    try std.testing.expectEqual(@as(usize, 3), try fileSize(path));
}
