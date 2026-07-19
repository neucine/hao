const std = @import("std");
const abi = @import("abi.zig");
const qjs = @import("../qjs.zig");
const runtime_allocator = @import("../runtime_allocator.zig");

pub const register_symbol_name = abi.register_symbol_name;

const Extension = struct {
    path: []u8,
    lib: std.DynLib,
    modules: []abi.FunctionModule,
};

pub const ResolvedImport = struct {
    module_name: []u8,
    path: []u8,
    specifier: []u8,
};

var extensions: std.ArrayList(Extension) = .empty;
var resolved_imports: std.ArrayList(ResolvedImport) = .empty;

fn allocator() std.mem.Allocator {
    return runtime_allocator.allocator();
}

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

pub fn findResolvedImport(module_name: []const u8) ?ResolvedImport {
    for (resolved_imports.items) |entry| {
        if (std.mem.eql(u8, entry.module_name, module_name)) return entry;
    }
    return null;
}

fn findRememberedImport(path: []const u8, specifier: []const u8) ?ResolvedImport {
    for (resolved_imports.items) |entry| {
        if (std.mem.eql(u8, entry.path, path) and std.mem.eql(u8, entry.specifier, specifier)) return entry;
    }
    return null;
}

pub fn rememberResolvedImport(return_allocator: std.mem.Allocator, path: []const u8, specifier: []const u8) ![]u8 {
    if (findRememberedImport(path, specifier)) |existing| {
        return return_allocator.dupe(u8, existing.module_name);
    }

    const alloc = allocator();
    const module_name = try std.fmt.allocPrint(alloc, "addon:{s}\n{s}", .{ specifier, path });
    errdefer alloc.free(module_name);
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    const owned_specifier = try alloc.dupe(u8, specifier);
    errdefer alloc.free(owned_specifier);

    try resolved_imports.append(alloc, .{
        .module_name = module_name,
        .path = owned_path,
        .specifier = owned_specifier,
    });
    return return_allocator.dupe(u8, module_name);
}

fn loadExtension(path: []const u8) !*Extension {
    if (findLoaded(path)) |existing| return existing;

    var lib = try std.DynLib.open(path);
    errdefer lib.close();

    const register_fn = lib.lookup(abi.RegisterModulesFn, register_symbol_name) orelse return error.AddonSymbolNotFound;
    const alloc = allocator();
    var collector = abi.ModuleCollector.init(alloc);
    errdefer collector.deinit();
    var registry = collector.registry();
    if (register_fn(&registry) != 0) return error.AddonRegisterFailed;

    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);

    try extensions.append(alloc, .{
        .path = owned_path,
        .lib = lib,
        .modules = try collector.modules.toOwnedSlice(alloc),
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
    const requested_name = std.mem.span(module_name);
    const resolved_import = findResolvedImport(requested_name);
    const addon_path = if (resolved_import) |resolved| resolved.path else path;
    const addon_specifier = if (resolved_import) |resolved| resolved.specifier else requested_name;
    const extension = loadExtension(addon_path) catch return null;
    const module = findModule(extension, addon_specifier) orelse return null;
    return abi.createFunctionModule(allocator_, ctx, module_name, module.functions);
}

pub fn cleanup() void {
    const alloc = allocator();
    for (resolved_imports.items) |entry| {
        alloc.free(entry.module_name);
        alloc.free(entry.path);
        alloc.free(entry.specifier);
    }
    resolved_imports.deinit(alloc);
    resolved_imports = .empty;

    for (extensions.items) |*extension| {
        for (extension.modules) |module| {
            alloc.free(module.specifier);
            alloc.free(module.functions);
        }
        alloc.free(extension.modules);
        extension.lib.close();
        alloc.free(extension.path);
    }
    extensions.deinit(alloc);
    extensions = .empty;
}

test "addon path detection" {
    try std.testing.expect(isAddonPath("pkg/native.dylib"));
    try std.testing.expect(isAddonPath("pkg/native.so"));
    try std.testing.expect(isAddonPath("pkg/native.dll"));
    try std.testing.expect(isAddonPath("pkg/native.node"));
    try std.testing.expect(!isAddonPath("pkg/index.ts"));
}

test "resolved addon imports preserve requested specifier" {
    cleanup();
    defer cleanup();

    const first = try rememberResolvedImport(std.testing.allocator, "/pkg/native.dylib", "foo:native");
    defer std.testing.allocator.free(first);
    const second = try rememberResolvedImport(std.testing.allocator, "/pkg/native.dylib", "foo:extra");
    defer std.testing.allocator.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));

    const resolved_first = findResolvedImport(first).?;
    try std.testing.expectEqualStrings("/pkg/native.dylib", resolved_first.path);
    try std.testing.expectEqualStrings("foo:native", resolved_first.specifier);

    const resolved_second = findResolvedImport(second).?;
    try std.testing.expectEqualStrings("/pkg/native.dylib", resolved_second.path);
    try std.testing.expectEqualStrings("foo:extra", resolved_second.specifier);

    const again = try rememberResolvedImport(std.testing.allocator, "/pkg/native.dylib", "foo:native");
    defer std.testing.allocator.free(again);
    try std.testing.expectEqualStrings(first, again);
}
