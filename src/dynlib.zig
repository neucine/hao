const std = @import("std");
const builtin = @import("builtin");

const Windows = struct {
    handle: *anyopaque,

    extern "kernel32" fn LoadLibraryA(path: [*:0]const u8) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
    extern "kernel32" fn FreeLibrary(handle: *anyopaque) c_int;

    pub fn open(path: []const u8) !Windows {
        const path_z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(path_z);
        return .{ .handle = LoadLibraryA(path_z.ptr) orelse return error.FileNotFound };
    }

    pub fn lookup(self: *Windows, comptime T: type, name: [:0]const u8) ?T {
        const symbol = GetProcAddress(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(symbol));
    }

    pub fn close(self: *Windows) void {
        _ = FreeLibrary(self.handle);
    }
};

const Posix = struct {
    handle: *anyopaque,

    extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
    extern "c" fn dlsym(handle: *anyopaque, name: [*:0]const u8) ?*anyopaque;
    extern "c" fn dlclose(handle: *anyopaque) c_int;

    pub fn open(path: []const u8) !Posix {
        const path_z = try std.heap.page_allocator.dupeSentinel(u8, path, 0);
        defer std.heap.page_allocator.free(path_z);
        return .{ .handle = dlopen(path_z.ptr, 2) orelse return error.FileNotFound };
    }

    pub fn lookup(self: *Posix, comptime T: type, name: [:0]const u8) ?T {
        const symbol = dlsym(self.handle, name.ptr) orelse return null;
        return @ptrCast(@alignCast(symbol));
    }

    pub fn close(self: *Posix) void {
        _ = dlclose(self.handle);
    }
};

pub const DynLib = if (builtin.os.tag == .windows) Windows else Posix;
