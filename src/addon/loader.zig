const std = @import("std");
const abi = @import("abi.zig");
const qjs = @import("../qjs.zig");

pub const register_symbol_name = abi.register_symbol_name;

const Extension = struct {
    path: []u8,
    lib: std.DynLib,
    modules: []abi.FunctionModule,
};

var extensions: std.ArrayList(Extension) = .empty;
const allocator = std.heap.page_allocator;

pub fn isAddonPath(path: []const u8) bool {
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

    const register_fn = lib.lookup(abi.RegisterModulesFn, register_symbol_name) orelse return error.AddonSymbolNotFound;
    var collector = abi.ModuleCollector.init(allocator);
    errdefer collector.deinit();
    var registry = collector.registry();
    if (register_fn(&registry) != 0) return error.AddonRegisterFailed;

    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);

    try extensions.append(allocator, .{
        .path = owned_path,
        .lib = lib,
        .modules = try collector.modules.toOwnedSlice(allocator),
    });

    return &extensions.items[extensions.items.len - 1];
}

fn findModule(extension: *const Extension, module_name: []const u8) ?abi.FunctionModule {
    for (extension.modules) |module| {
        if (std.mem.eql(u8, module.specifier, module_name)) return module;
    }
    if (extension.modules.len == 1) return extension.modules[0];
    return null;
}

pub fn loadModule(
    allocator_: std.mem.Allocator,
    ctx: ?*qjs.c.JSContext,
    path: []const u8,
    module_name: [*c]const u8,
) ?*qjs.c.JSModuleDef {
    const extension = loadExtension(path) catch return null;
    const module = findModule(extension, std.mem.span(module_name)) orelse return null;
    return abi.createFunctionModule(allocator_, ctx, module_name, module.functions);
}

pub fn cleanup() void {
    for (extensions.items) |*extension| {
        for (extension.modules) |module| {
            allocator.free(module.specifier);
            allocator.free(module.functions);
        }
        allocator.free(extension.modules);
        extension.lib.close();
        allocator.free(extension.path);
    }
    extensions.deinit(allocator);
    extensions = .empty;
}

test "addon path detection" {
    try std.testing.expect(isAddonPath("pkg/native.dylib"));
    try std.testing.expect(isAddonPath("pkg/native.so"));
    try std.testing.expect(isAddonPath("pkg/native.dll"));
    try std.testing.expect(isAddonPath("pkg/native.node"));
    try std.testing.expect(!isAddonPath("pkg/index.ts"));
}
