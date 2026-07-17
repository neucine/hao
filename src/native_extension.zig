const std = @import("std");
const qjs = @import("qjs.zig");

pub const load_symbol_name = "hao_load_module";

pub const LoadFn = *const fn (?*qjs.c.JSContext, [*c]const u8) callconv(.c) ?*qjs.c.JSModuleDef;

const Extension = struct {
    path: []u8,
    lib: std.DynLib,
    load: LoadFn,
};

var extensions: std.ArrayList(Extension) = .empty;
const allocator = std.heap.page_allocator;

pub fn isNativeExtensionPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".dylib") or
        std.mem.endsWith(u8, path, ".so") or
        std.mem.endsWith(u8, path, ".dll") or
        std.mem.endsWith(u8, path, ".node");
}

fn findLoaded(path: []const u8) ?*Extension {
    for (extensions.items) |*extension| {
        if (std.mem.eql(u8, extension.path, path)) return extension;
    }
    return null;
}

fn loadExtension(path: []const u8) !*Extension {
    if (findLoaded(path)) |existing| return existing;

    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    const load_fn = lib.lookup(LoadFn, load_symbol_name) orelse return error.NativeExtensionSymbolNotFound;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    try extensions.append(allocator, .{
        .path = owned_path,
        .lib = lib,
        .load = load_fn,
    });

    return &extensions.items[extensions.items.len - 1];
}

pub fn loadModule(
    ctx: ?*qjs.c.JSContext,
    path: []const u8,
    module_name: [*c]const u8,
) ?*qjs.c.JSModuleDef {
    const extension = loadExtension(path) catch return null;
    return extension.load(ctx, module_name);
}

pub fn cleanup() void {
    for (extensions.items) |*extension| {
        extension.lib.close();
        allocator.free(extension.path);
    }
    extensions.deinit(allocator);
    extensions = .empty;
}

test "native extension path detection" {
    try std.testing.expect(isNativeExtensionPath("pkg/native.dylib"));
    try std.testing.expect(isNativeExtensionPath("pkg/native.so"));
    try std.testing.expect(isNativeExtensionPath("pkg/native.dll"));
    try std.testing.expect(isNativeExtensionPath("pkg/native.node"));
    try std.testing.expect(!isNativeExtensionPath("pkg/index.ts"));
}
