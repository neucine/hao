const std = @import("std");
const builtin = @import("builtin");

const alloc = std.heap.page_allocator;

pub const Library = struct {
    dynlib: std.DynLib,
    name: []const u8,
    closed: bool,

    pub fn open(lib_name: []const u8) !Library {
        const path = try resolvePath(lib_name);
        const needs_free = path.ptr != lib_name.ptr;
        defer if (needs_free) alloc.free(path);

        const dynlib = try std.DynLib.open(path);
        return Library{
            .dynlib = dynlib,
            .name = lib_name,
            .closed = false,
        };
    }

    pub fn openPath(path: []const u8, logical_name: []const u8) !Library {
        const dynlib = try std.DynLib.open(path);
        return Library{
            .dynlib = dynlib,
            .name = logical_name,
            .closed = false,
        };
    }

    pub fn lookupSymbol(self: *Library, name: [:0]const u8) ?*anyopaque {
        return self.dynlib.lookup(*anyopaque, name);
    }

    pub fn close(self: *Library) void {
        if (!self.closed) {
            self.dynlib.close();
            self.closed = true;
        }
    }

    pub fn deinit(self: *Library) void {
        self.close();
    }

    fn resolvePath(name: []const u8) ![]const u8 {
        // If name contains / or ., treat as explicit path
        for (name) |ch| {
            if (ch == '/' or ch == '.') return name;
        }
        // Platform-specific: prepend "lib", append ".dylib" or ".so"
        const ext = if (builtin.os.tag == .macos) ".dylib" else ".so";
        return std.fmt.allocPrint(alloc, "lib{s}{s}", .{ name, ext });
    }
};
