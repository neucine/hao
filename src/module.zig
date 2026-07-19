const std = @import("std");
const fs = @import("fs.zig");
const js_abi = @import("js/abi.zig");
const js_addon = @import("js/addon.zig");
const qjs = @import("qjs.zig");
const packages = @import("package.zig");
const runtime_allocator = @import("runtime_allocator.zig");
const transpiler = @import("transpiler.zig");

var last_error_storage: [4096]u8 = undefined;
var last_error_len: usize = 0;
const notebook_namespace_name = "__hao_jupyter_module_cache";
var jupyter_import_seq: u64 = 0;

pub const PreparedNotebookCell = struct {
    code: []u8,
    source_url: []u8,

    pub fn deinit(self: PreparedNotebookCell, allocator: std.mem.Allocator) void {
        transpiler.deinitTranspilerString(self.code, allocator);
        transpiler.deinitTranspilerString(self.source_url, allocator);
    }
};

pub const Loader = struct {
    allocator: std.mem.Allocator,
    registry: *const packages.Registry,
    native_cache: ?*NativeModuleCache = null,

    pub fn install(self: *Loader, runtime: *qjs.Runtime) void {
        qjs.c.JS_SetModuleLoaderFunc(runtime.rt, normalizeModule, loadModule, self);
    }
};

pub const NativeModuleCache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry),

    const Entry = struct { specifier: []u8, module: *qjs.c.JSModuleDef };

    pub fn init(allocator: std.mem.Allocator) NativeModuleCache {
        return .{ .allocator = allocator, .entries = .empty };
    }

    pub fn deinit(self: *NativeModuleCache) void {
        for (self.entries.items) |entry| self.allocator.free(entry.specifier);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn get(self: *const NativeModuleCache, specifier: []const u8) ?*qjs.c.JSModuleDef {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.specifier, specifier)) return entry.module;
        }
        return null;
    }

    fn put(self: *NativeModuleCache, specifier: []const u8, module: *qjs.c.JSModuleDef) !void {
        try self.entries.append(self.allocator, .{
            .specifier = try self.allocator.dupe(u8, specifier),
            .module = module,
        });
    }
};

pub fn clearLastError() void {
    last_error_len = 0;
}

pub fn lastError() ?[]const u8 {
    if (last_error_len == 0) return null;
    return last_error_storage[0..last_error_len];
}

fn rememberLastError(message: []const u8) void {
    last_error_len = @min(message.len, last_error_storage.len);
    @memcpy(last_error_storage[0..last_error_len], message[0..last_error_len]);
}

fn rememberTranspileFailure(allocator: std.mem.Allocator, fallback_path: []const u8) void {
    if (transpiler.takeLastError(allocator)) |message| {
        defer allocator.free(message);
        rememberLastError(message);
        return;
    }

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "Transpile failed in {s}", .{fallback_path}) catch "Transpile failed";
    rememberLastError(msg);
}

fn rememberJavaScriptException(ctx: ?*qjs.c.JSContext, allocator: std.mem.Allocator, fallback: []const u8) void {
    const message = qjs.getExceptionAlloc(ctx, allocator) catch {
        rememberLastError(fallback);
        return;
    };
    defer allocator.free(message);
    rememberLastError(message);
}

pub fn evalModuleSource(
    loader: *Loader,
    runtime: *qjs.Runtime,
    source: []const u8,
    source_name: []const u8,
) !void {
    clearLastError();
    qjs.updateStackTop(runtime.rt);

    const transformed = transpiler.transformEsmModule(source, source_name, loader.allocator) catch |err| {
        if (err == error.TranspileFailed) rememberTranspileFailure(loader.allocator, source_name);
        return err;
    };
    defer transformed.deinit(loader.allocator);

    const source_z = try loader.allocator.dupeZ(u8, transformed.code);
    defer loader.allocator.free(source_z);
    const file_name = try loader.allocator.dupeZ(u8, transformed.source_url);
    defer loader.allocator.free(file_name);

    const compiled = qjs.eval(runtime.ctx, source_z, file_name, qjs.EvalFlags.module_compile_only);
    if (qjs.isException(compiled)) {
        rememberJavaScriptException(runtime.ctx, loader.allocator, "JavaScript module compilation failed");
        return error.JavaScriptError;
    }
    defer qjs.freeValue(runtime.ctx, compiled);

    const value = qjs.c.JS_EvalFunction(runtime.ctx, qjs.dupValue(runtime.ctx, compiled));
    defer qjs.freeValue(runtime.ctx, value);
    if (qjs.isException(value)) {
        rememberJavaScriptException(runtime.ctx, loader.allocator, "JavaScript module evaluation failed");
        return error.JavaScriptError;
    }
}

pub fn evalPackageModule(loader: *Loader, runtime: *qjs.Runtime, specifier: []const u8) !void {
    const source = loader.registry.findSource(specifier) orelse {
        rememberLastError("Package module not found");
        return error.ModuleNotFound;
    };
    try evalModuleSource(loader, runtime, source.source, source.specifier);
}

pub fn prepareNotebookCell(loader: *Loader, runtime: *qjs.Runtime, source: []const u8, source_path: []const u8) !PreparedNotebookCell {
    clearLastError();
    qjs.updateStackTop(runtime.rt);

    const transformed = transpiler.transformModule(
        source,
        source_path,
        false,
        notebook_namespace_name,
        loader.allocator,
    ) catch |err| {
        if (err == error.TranspileFailed) rememberTranspileFailure(loader.allocator, source_path);
        return err;
    };
    errdefer transformed.deinit(loader.allocator);

    try ensureNotebookNamespace(runtime.ctx);

    for (transformed.imports) |import_record| {
        const value = try importNamespace(loader, runtime, source_path, import_record.source);
        errdefer qjs.freeValue(runtime.ctx, value);
        try setNotebookNamespaceValue(runtime.ctx, import_record.slot, value);
    }

    const exports_obj = qjs.newObject(runtime.ctx);
    if (qjs.isException(exports_obj)) return error.JavaScriptError;
    errdefer qjs.freeValue(runtime.ctx, exports_obj);
    try setNotebookNamespaceValue(runtime.ctx, transformed.exports_slot, exports_obj);

    for (transformed.imports) |import_record| {
        transpiler.deinitRuntimeImport(import_record, loader.allocator);
    }
    transpiler.deinitRuntimeImports(transformed.imports, loader.allocator);
    transpiler.deinitTranspilerString(transformed.exports_slot, loader.allocator);

    return .{
        .code = transformed.code,
        .source_url = transformed.source_url,
    };
}

fn ensureNotebookNamespace(ctx: ?*qjs.c.JSContext) !void {
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const existing = qjs.getProperty(ctx, global, notebook_namespace_name);
    defer qjs.freeValue(ctx, existing);
    if (!qjs.isUndefined(existing) and !qjs.isNull(existing)) return;

    const namespace = qjs.newObject(ctx);
    if (qjs.isException(namespace)) return error.JavaScriptError;
    try qjs.setProperty(ctx, global, notebook_namespace_name, namespace);
}

fn setNotebookNamespaceValue(ctx: ?*qjs.c.JSContext, slot: []const u8, value: qjs.c.JSValue) !void {
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const namespace = qjs.getProperty(ctx, global, notebook_namespace_name);
    defer qjs.freeValue(ctx, namespace);
    if (qjs.isUndefined(namespace) or qjs.isNull(namespace)) return error.JavaScriptError;

    const alloc = runtime_allocator.allocator();
    const slot_z = try alloc.dupeZ(u8, slot);
    defer alloc.free(slot_z);
    try qjs.setProperty(ctx, namespace, slot_z, value);
}

fn importNamespace(loader: *Loader, runtime: *qjs.Runtime, current_file: []const u8, specifier: []const u8) !qjs.c.JSValue {
    const resolved = try resolveSpecifier(loader, current_file, specifier);
    defer freeTrackedModuleResolution(loader.allocator, resolved);

    const helper_specifier = if (loader.registry.findSource(specifier) != null or loader.registry.findNativeModule(specifier) != null)
        specifier
    else
        resolved;

    const quoted = try quoteJsString(loader.allocator, helper_specifier);
    defer loader.allocator.free(quoted);
    const source = try std.fmt.allocPrint(
        loader.allocator,
        "import * as __hao_ns from {s}; globalThis.__hao_jupyter_import = __hao_ns;",
        .{quoted},
    );
    defer loader.allocator.free(source);

    jupyter_import_seq += 1;
    const file_name = try std.fmt.allocPrint(loader.allocator, "<hao-jupyter-import-{d}>", .{jupyter_import_seq});
    defer loader.allocator.free(file_name);
    const source_z = try loader.allocator.dupeZ(u8, source);
    defer loader.allocator.free(source_z);
    const file_name_z = try loader.allocator.dupeZ(u8, file_name);
    defer loader.allocator.free(file_name_z);

    const compiled = qjs.eval(runtime.ctx, source_z, file_name_z, qjs.EvalFlags.module_compile_only);
    if (qjs.isException(compiled)) {
        rememberJavaScriptException(runtime.ctx, loader.allocator, "JavaScript notebook import compilation failed");
        return error.JavaScriptError;
    }
    defer qjs.freeValue(runtime.ctx, compiled);

    const result = qjs.c.JS_EvalFunction(runtime.ctx, qjs.dupValue(runtime.ctx, compiled));
    defer qjs.freeValue(runtime.ctx, result);
    if (qjs.isException(result)) {
        rememberJavaScriptException(runtime.ctx, loader.allocator, "JavaScript notebook import failed");
        return error.JavaScriptError;
    }

    const global = qjs.c.JS_GetGlobalObject(runtime.ctx);
    defer qjs.freeValue(runtime.ctx, global);
    const value = qjs.getProperty(runtime.ctx, global, "__hao_jupyter_import");
    if (qjs.isException(value)) {
        rememberJavaScriptException(runtime.ctx, loader.allocator, "JavaScript notebook import value failed");
        return error.JavaScriptError;
    }
    return value;
}

fn quoteJsString(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn trackedModuleResolutionCopy(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, value.len);
    @memcpy(out, value);
    return out;
}

fn freeTrackedModuleResolution(allocator: std.mem.Allocator, value: []u8) void {
    allocator.free(value);
}

fn readFileSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fs.readFileAlloc(allocator, path, 10 * 1024 * 1024);
}

fn normalizeModule(
    ctx: ?*qjs.c.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    loader_opaque: ?*anyopaque,
) callconv(.c) [*c]u8 {
    const loader: *Loader = @ptrCast(@alignCast(loader_opaque orelse return null));
    const qjs_ctx = ctx orelse return null;
    if (module_base_name == null or module_name == null) return null;

    const base = std.mem.span(module_base_name);
    const specifier = std.mem.span(module_name);
    const resolved = resolveSpecifier(loader, base, specifier) catch return null;
    defer freeTrackedModuleResolution(loader.allocator, resolved);

    const out = qjs.c.js_malloc(qjs_ctx, resolved.len + 1) orelse return null;
    const buffer: [*]u8 = @ptrCast(out);
    @memcpy(buffer[0..resolved.len], resolved);
    buffer[resolved.len] = 0;
    return @ptrCast(buffer);
}

fn loadModule(
    ctx: ?*qjs.c.JSContext,
    module_name: [*c]const u8,
    loader_opaque: ?*anyopaque,
) callconv(.c) ?*qjs.c.JSModuleDef {
    const loader: *Loader = @ptrCast(@alignCast(loader_opaque orelse return null));
    qjs.updateStackTop(qjs.c.JS_GetRuntime(ctx));
    if (module_name == null) return null;
    const name = std.mem.span(module_name);

    if (loader.registry.findNativeModule(name)) |native| {
        if (loader.native_cache) |cache| {
            if (cache.get(name)) |cached| return cached;
        }
        const name_z = loader.allocator.dupeZ(u8, native.specifier) catch return null;
        defer loader.allocator.free(name_z);
        const module = native.load(@ptrCast(ctx), name_z.ptr) orelse return null;
        const module_def: *qjs.c.JSModuleDef = @ptrCast(@alignCast(module));
        if (loader.native_cache) |cache| cache.put(name, module_def) catch return null;
        return module_def;
    }

    if (js_addon.isAddonPath(name)) {
        return js_addon.loadModule(loader.allocator, ctx, name, module_name);
    }

    const source_info = loader.registry.findSource(name);
    const source = if (source_info) |entry|
        entry.source
    else
        readFileSource(loader.allocator, name) catch {
            rememberLastError("Module source not found");
            return null;
        };
    defer if (source_info == null) loader.allocator.free(@constCast(source));

    const source_name = if (source_info) |entry| entry.specifier else name;
    const transformed = transpiler.transformEsmModule(source, source_name, loader.allocator) catch |err| {
        if (err == error.TranspileFailed) rememberTranspileFailure(loader.allocator, source_name) else rememberLastError("Failed to transform module");
        return null;
    };
    defer transformed.deinit(loader.allocator);

    const source_z = loader.allocator.dupeZ(u8, transformed.code) catch return null;
    defer loader.allocator.free(source_z);
    const file_name = loader.allocator.dupeZ(u8, transformed.source_url) catch return null;
    defer loader.allocator.free(file_name);

    const compiled = qjs.eval(ctx, source_z, file_name, qjs.EvalFlags.module_compile_only);
    if (qjs.isException(compiled)) return null;
    defer qjs.freeValue(ctx, compiled);

    return @ptrCast(@alignCast(qjs.c.JS_VALUE_GET_PTR(compiled)));
}

fn resolveSpecifier(loader: *const Loader, current_file: []const u8, specifier: []const u8) ![]u8 {
    if (loader.registry.findSource(specifier) != null or loader.registry.findNativeModule(specifier) != null) {
        return trackedModuleResolutionCopy(loader.allocator, specifier);
    }

    if (std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../")) {
        const current_dir = std.fs.path.dirname(current_file) orelse ".";
        const joined = try std.fs.path.resolve(loader.allocator, &.{ current_dir, specifier });
        errdefer loader.allocator.free(joined);
        return joined;
    }

    const resolved = packages.resolveImport(current_file, specifier, loader.allocator) catch |err| {
        rememberLastError(switch (err) {
            error.UnsupportedCommonJS => "CommonJS packages are not supported",
            error.UnsupportedPackageManifest => "Package must declare type: module",
            error.PackageManifestNotFound => "Package manifest not found",
            error.PackageExportNotFound => "Package export not found",
            else => "Cannot resolve module",
        });
        return err;
    };
    defer resolved.deinit(loader.allocator);
    if (js_addon.isAddonPath(resolved.abs_path)) {
        return js_addon.rememberResolvedImport(loader.allocator, resolved.abs_path, specifier);
    }
    return trackedModuleResolutionCopy(loader.allocator, resolved.abs_path);
}

test "loader resolves package addon entries" {
    defer js_addon.cleanup();

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const root = ".zig-cache/hao-tests/module-native-extension";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo-native");
    try fs.writeFile(root ++ "/main.ts", "import 'demo-native';");
    try fs.writeFile(root ++ "/node_modules/demo-native/package.json", "{\"type\":\"module\",\"exports\":\"./native.dylib\"}");
    try fs.writeFile(root ++ "/node_modules/demo-native/native.dylib", "");

    var registry = packages.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var loader = Loader{
        .allocator = std.testing.allocator,
        .registry = &registry,
    };
    loader.install(&runtime);

    const resolved = try resolveSpecifier(&loader, root ++ "/main.ts", "demo-native");
    defer loader.allocator.free(resolved);

    const resolved_addon = js_addon.findResolvedImport(resolved).?;
    try std.testing.expect(std.mem.endsWith(u8, resolved_addon.path, "native.dylib"));
    try std.testing.expectEqualStrings("demo-native", resolved_addon.specifier);
}

fn getGlobalNumber(ctx: ?*qjs.c.JSContext, name: [:0]const u8) !f64 {
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);
    const value = qjs.getProperty(ctx, global, name);
    defer qjs.freeValue(ctx, value);

    var out: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(ctx, &out, value));
    return out;
}

test "loader imports package source module" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const sources = [_]packages.SourceModule{.{
        .specifier = "demo:math",
        .source = "export const value = 21;",
    }};
    var registry = packages.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .name = "demo",
        .sources = &sources,
    });

    var loader = Loader{
        .allocator = std.testing.allocator,
        .registry = &registry,
    };
    loader.install(&runtime);

    try evalModuleSource(
        &loader,
        &runtime,
        "import { value } from 'demo:math'; globalThis.__hao_loader_value = value * 2;",
        "<test-entry>",
    );

    try std.testing.expectEqual(@as(f64, 42), try getGlobalNumber(runtime.ctx, "__hao_loader_value"));
}

test "loader resolves relative TypeScript files and node_modules packages" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const root = ".zig-cache/hao-tests/module-loader";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo-pkg");
    try fs.writeFile(root ++ "/dep.ts", "export const localValue: number = 20;");
    try fs.writeFile(
        root ++ "/main.ts",
        \\import { localValue } from './dep.ts';
        \\import { packageValue } from 'demo-pkg';
        \\globalThis.__hao_file_loader_value = localValue + packageValue;
        ,
    );
    try fs.writeFile(root ++ "/node_modules/demo-pkg/package.json", "{\"type\":\"module\",\"exports\":\"./index.ts\"}");
    try fs.writeFile(root ++ "/node_modules/demo-pkg/index.ts", "export const packageValue: number = 22;");

    const entry_path = root ++ "/main.ts";
    const entry_source = try readFileSource(std.testing.allocator, entry_path);
    defer std.testing.allocator.free(entry_source);

    var registry = packages.Registry.init(std.testing.allocator);
    defer registry.deinit();
    var loader = Loader{
        .allocator = std.testing.allocator,
        .registry = &registry,
    };
    loader.install(&runtime);

    try evalModuleSource(&loader, &runtime, entry_source, entry_path);

    try std.testing.expectEqual(@as(f64, 42), try getGlobalNumber(runtime.ctx, "__hao_file_loader_value"));
}

const fixture_abi_functions = [_]js_abi.Function{
    .{
        .name = "nativeValue",
        .callback = fixtureAbiNativeValue,
        .length = 0,
    },
    .{
        .name = null,
        .callback = fixtureAbiNativeValue,
        .length = 0,
    },
};
const fixture_abi_function_ptrs = [_]*const js_abi.Function{&fixture_abi_functions[0]};

fn fixtureNativeLoad(ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque {
    return @ptrCast(js_abi.createFunctionModule(std.heap.page_allocator, @ptrCast(ctx), module_name, &fixture_abi_function_ptrs));
}

fn fixtureAbiNativeValue(ctx: *js_abi.Context, _: c_int, _: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    return ctx.api.int32_value(ctx, 42);
}

test "loader composes source modules with native package modules" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const sources = [_]packages.SourceModule{.{
        .specifier = "demo:index",
        .source =
        \\import { nativeValue } from 'demo:native';
        \\globalThis.__hao_native_package_value = nativeValue();
        ,
    }};
    const native_modules = [_]packages.NativeModule{.{
        .specifier = "demo:native",
        .load = fixtureNativeLoad,
    }};
    var registry = packages.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{
        .name = "demo",
        .sources = &sources,
        .native_modules = &native_modules,
    });

    var loader = Loader{
        .allocator = std.testing.allocator,
        .registry = &registry,
    };
    loader.install(&runtime);

    try evalPackageModule(&loader, &runtime, "demo:index");

    try std.testing.expectEqual(@as(f64, 42), try getGlobalNumber(runtime.ctx, "__hao_native_package_value"));
}
