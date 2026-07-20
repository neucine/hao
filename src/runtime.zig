const std = @import("std");
const builtin = @import("builtin");
const errors = @import("errors.zig");
const fs = @import("fs.zig");
const qjs = @import("qjs.zig");
const async_loop = @import("async/loop.zig");
const global_console = @import("global/console.zig");
const global_timer = @import("global/timer.zig");
const module = @import("module.zig");
const js_addon = @import("js/addon.zig");
const packages = @import("package.zig");
const runtime_allocator = @import("runtime_allocator.zig");
const telemetry_metrics = @import("telemetry/metrics.zig");
const telemetry_store = @import("telemetry/store.zig");
const telemetry_interface = @import("telemetry/interface.zig");
const hao_std = @import("std.zig");
const http_native = @import("std/http/native.zig");
const process_native = @import("std/process/native.zig");
const util_native = @import("std/util/native.zig");
const telemetry_server = @import("telemetry/server.zig");

const CoreEnvironment = struct {
    runtime: qjs.Runtime,
    loop: async_loop.Loop,
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    telemetry_console: telemetry_server.Handle = .{},
    native_cache: module.NativeModuleCache,

    pub fn init(allocator: std.mem.Allocator) !CoreEnvironment {
        return initWithIo(allocator, null);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: ?std.Io) !CoreEnvironment {
        runtime_allocator.init(allocator);
        telemetry_metrics.init(allocator);
        @import("zig_libs").telemetry.install(telemetry_interface.host());
        var runtime = try qjs.Runtime.init();
        errdefer runtime.deinit();

        var loop = try async_loop.Loop.init(allocator);
        errdefer loop.deinit();
        const telemetry_console = try telemetry_server.start(allocator, io);
        const native_cache = module.NativeModuleCache.init(allocator);

        return .{
            .runtime = runtime,
            .loop = loop,
            .allocator = allocator,
            .io = io,
            .telemetry_console = telemetry_console,
            .native_cache = native_cache,
        };
    }

    pub fn deinit(self: *CoreEnvironment) void {
        async_loop.detachCurrent();
        self.telemetry_console.deinit();
        global_console.capture_state = null;
        global_timer.cleanup(self.allocator);
        js_addon.cleanup();
        self.loop.deinit();
        self.native_cache.deinit();
        self.runtime.deinit();
        telemetry_metrics.clear();
        telemetry_store.clear();
        @import("zig_libs").telemetry.install(.{});
        self.* = undefined;
    }

    pub fn installGlobals(self: *CoreEnvironment) !void {
        async_loop.attachCurrent(&self.loop);
        try errors.registerRuntimeError(self.runtime.ctx, self.allocator);
        try global_console.register(self.runtime.ctx);
        try global_timer.register(self.runtime.ctx);
    }

    pub fn evalModuleSourceWithRegistry(
        self: *CoreEnvironment,
        source: []const u8,
        source_name: []const u8,
        registry: *const packages.Registry,
    ) !void {
        var loader = module.Loader{
            .allocator = self.allocator,
            .registry = registry,
            .native_cache = &self.native_cache,
        };
        loader.install(&self.runtime);
        async_loop.attachCurrent(&self.loop);
        var package_context = packages.PackageContext{ .runtime = &self.runtime, .allocator = self.allocator };
        try registry.installPackages(&package_context);
        try errors.registerRuntimeError(self.runtime.ctx, self.allocator);
        try global_console.register(self.runtime.ctx);
        try module.evalModuleSource(&loader, &self.runtime, source, source_name);
    }

    pub fn runFileWithRegistry(self: *CoreEnvironment, path: []const u8, registry: *const packages.Registry) !void {
        try self.installGlobals();
        const source = try fs.readFileAlloc(self.allocator, path, 10 * 1024 * 1024);
        defer self.allocator.free(source);
        try self.evalModuleSourceWithRegistry(source, path, registry);
        try self.runUntilIdle();
    }

    pub fn runUntilIdle(self: *CoreEnvironment) !void {
        async_loop.attachCurrent(&self.loop);
        defer async_loop.detachCurrent();

        while (true) {
            const ran_jobs = try qjs.executePendingJobs(self.runtime.rt);
            if (qjs.takeUnhandledException()) |pending| {
                module.rememberUnhandledException(pending.ctx, pending.value, self.allocator);
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            const ran_uv = try self.loop.runUntilIdle();
            if (qjs.takeUnhandledException()) |pending| {
                module.rememberUnhandledException(pending.ctx, pending.value, self.allocator);
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            if (!ran_jobs and !ran_uv) break;
        }
    }
};

pub const RuntimeEnvironment = struct {
    runtime: qjs.Runtime,
    loop: async_loop.Loop,
    allocator: std.mem.Allocator,
    io: ?std.Io = null,
    std_enabled: bool = false,
    registry: packages.Registry,
    telemetry_console: telemetry_server.Handle = .{},
    native_cache: module.NativeModuleCache,

    pub const Options = struct {
        std: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !RuntimeEnvironment {
        return initWithIo(allocator, null, options);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: ?std.Io, options: Options) !RuntimeEnvironment {
        var core = try CoreEnvironment.initWithIo(allocator, io);
        errdefer core.deinit();

        var registry = packages.Registry.init(allocator);
        errdefer registry.deinit();
        if (options.std) try hao_std.register(&registry);

        return .{
            .runtime = core.runtime,
            .loop = core.loop,
            .allocator = core.allocator,
            .io = core.io,
            .std_enabled = options.std,
            .registry = registry,
            .telemetry_console = core.telemetry_console,
            .native_cache = core.native_cache,
        };
    }

    pub fn deinit(self: *RuntimeEnvironment) void {
        async_loop.detachCurrent();
        self.telemetry_console.deinit();
        if (self.std_enabled) {
            http_native.detachIo();
            process_native.detachIo();
        }
        global_console.capture_state = null;
        global_timer.cleanup(self.allocator);
        js_addon.cleanup();
        var package_context = packages.PackageContext{ .runtime = &self.runtime, .allocator = self.allocator };
        self.registry.deinitPackages(&package_context);
        self.registry.deinit();
        self.loop.deinit();
        self.native_cache.deinit();
        self.runtime.deinit();
        telemetry_metrics.clear();
        telemetry_store.clear();
        self.* = undefined;
    }

    fn attachStdIo(self: *RuntimeEnvironment) void {
        if (!self.std_enabled) return;
        if (self.io) |io| {
            http_native.attachIo(io);
            process_native.attachIo(io);
        }
    }

    pub fn installGlobals(self: *RuntimeEnvironment) !void {
        async_loop.attachCurrent(&self.loop);
        self.attachStdIo();
        try errors.registerRuntimeError(self.runtime.ctx, self.allocator);
        try global_console.register(self.runtime.ctx);
        try global_timer.register(self.runtime.ctx);
    }

    pub fn registerPackage(self: *RuntimeEnvironment, package: packages.Package) !void {
        try self.registry.register(package);
    }

    pub fn evalModuleSourceWithRegistry(
        self: *RuntimeEnvironment,
        source: []const u8,
        source_name: []const u8,
        registry: *const packages.Registry,
    ) !void {
        var loader = module.Loader{
            .allocator = self.allocator,
            .registry = registry,
            .native_cache = &self.native_cache,
        };
        loader.install(&self.runtime);
        async_loop.attachCurrent(&self.loop);
        self.attachStdIo();
        var package_context = packages.PackageContext{ .runtime = &self.runtime, .allocator = self.allocator };
        try registry.installPackages(&package_context);
        try errors.registerRuntimeError(self.runtime.ctx, self.allocator);
        try global_console.register(self.runtime.ctx);
        try module.evalModuleSource(&loader, &self.runtime, source, source_name);
    }

    pub fn evalModuleSource(self: *RuntimeEnvironment, source: []const u8, source_name: []const u8) !void {
        try self.evalModuleSourceWithRegistry(source, source_name, &self.registry);
    }

    pub fn runFileWithRegistry(self: *RuntimeEnvironment, path: []const u8, registry: *const packages.Registry) !void {
        try self.installGlobals();
        const source = try fs.readFileAlloc(self.allocator, path, 10 * 1024 * 1024);
        defer self.allocator.free(source);
        try self.evalModuleSourceWithRegistry(source, path, registry);
        try self.runUntilIdle();
    }

    pub fn runFile(self: *RuntimeEnvironment, path: []const u8) !void {
        try self.runFileWithRegistry(path, &self.registry);
    }

    pub fn runUntilIdle(self: *RuntimeEnvironment) !void {
        async_loop.attachCurrent(&self.loop);
        self.attachStdIo();
        defer async_loop.detachCurrent();
        defer if (self.std_enabled) http_native.detachIo();
        defer if (self.std_enabled) process_native.detachIo();

        while (true) {
            const ran_jobs = try qjs.executePendingJobs(self.runtime.rt);
            if (qjs.takeUnhandledException()) |pending| {
                module.rememberUnhandledException(pending.ctx, pending.value, self.allocator);
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            const ran_uv = try self.loop.runUntilIdle();
            if (qjs.takeUnhandledException()) |pending| {
                module.rememberUnhandledException(pending.ctx, pending.value, self.allocator);
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            if (!ran_jobs and !ran_uv) break;
        }
    }
};

test "core host runs without standard module wiring" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = false });
    defer host.deinit();
    try host.installGlobals();

    const value = qjs.eval(
        host.runtime.ctx,
        "globalThis.__hao_core_value = typeof console.log === 'function' && typeof setTimeout === 'function';",
        "<core-host-test>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(host.runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const result = qjs.getProperty(host.runtime.ctx, global, "__hao_core_value");
    defer qjs.freeValue(host.runtime.ctx, result);
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, result));
}

test "runtime environment runs timer callbacks until idle" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.installGlobals();

    const value = qjs.eval(
        host.runtime.ctx,
        "globalThis.__hao_timer_value = 0; setTimeout(() => { globalThis.__hao_timer_value = 42; }, 1);",
        "<timer-test>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(host.runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    try host.runUntilIdle();

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const result = qjs.getProperty(host.runtime.ctx, global, "__hao_timer_value");
    defer qjs.freeValue(host.runtime.ctx, result);
    var out: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &out, result));
    try std.testing.expectEqual(@as(f64, 42), out);
}

test "runtime environment runs a TypeScript entry file" {
    const root = ".zig-cache/hao-tests/runtime-run-file";
    try fs.makePath(std.testing.allocator, root);
    try fs.writeFile(
        root ++ "/main.ts",
        \\const value: number = 40;
        \\setTimeout(() => { globalThis.__hao_run_file_value = value + 2; }, 1);
        ,
    );

    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.runFile(root ++ "/main.ts");

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const result = qjs.getProperty(host.runtime.ctx, global, "__hao_run_file_value");
    defer qjs.freeValue(host.runtime.ctx, result);
    var out: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &out, result));
    try std.testing.expectEqual(@as(f64, 42), out);
}

test "runtime environment includes std module namespace by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        "import { namespace } from 'std:runtime'; globalThis.__hao_namespace_value = namespace;",
        "<hao-runtime-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const result = qjs.getProperty(host.runtime.ctx, global, "__hao_namespace_value");
    defer qjs.freeValue(host.runtime.ctx, result);
    const text = try qjs.valueToStringAlloc(host.runtime.ctx, result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("std:", text);
}

test "runtime telemetry reports tracked Zig allocator stats" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();

    const alloc = runtime_allocator.allocator();
    const bytes = try alloc.alloc(u8, 4096);
    defer alloc.free(bytes);

    try host.evalModuleSource(
        \\import { metrics } from "std:telemetry";
        \\const snapshot = metrics();
        \\globalThis.__hao_allocator_active_bytes = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "allocator_active_bytes")?.value ?? -1;
        \\globalThis.__hao_allocator_peak_bytes = snapshot.find((metric) => metric.scope === "runtime.memory" && metric.name === "allocator_peak_bytes")?.value ?? -1;
    ,
        "<hao-telemetry-memory-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const active_value = qjs.getProperty(host.runtime.ctx, global, "__hao_allocator_active_bytes");
    defer qjs.freeValue(host.runtime.ctx, active_value);
    var active: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &active, active_value));
    try std.testing.expect(active >= 4096);

    const peak_value = qjs.getProperty(host.runtime.ctx, global, "__hao_allocator_peak_bytes");
    defer qjs.freeValue(host.runtime.ctx, peak_value);
    var peak: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &peak, peak_value));
    try std.testing.expect(peak >= active);
}

test "runtime environment includes std fs module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/hao-fs");
    try host.evalModuleSource(
        \\import { existsSync, readFileSync, statSync, writeFileSync } from "std:fs";
        \\const path = ".zig-cache/hao-tests/hao-fs/default.txt";
        \\writeFileSync(path, "hello from hao");
        \\globalThis.__hao_fs_exists = existsSync(path);
        \\globalThis.__hao_fs_text = readFileSync(path);
        \\globalThis.__hao_fs_size = statSync(path).size;
    ,
        "<hao-fs-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const exists = qjs.getProperty(host.runtime.ctx, global, "__hao_fs_exists");
    defer qjs.freeValue(host.runtime.ctx, exists);
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, exists));

    const text_value = qjs.getProperty(host.runtime.ctx, global, "__hao_fs_text");
    defer qjs.freeValue(host.runtime.ctx, text_value);
    const text = try qjs.valueToStringAlloc(host.runtime.ctx, text_value, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello from hao", text);

    const size_value = qjs.getProperty(host.runtime.ctx, global, "__hao_fs_size");
    defer qjs.freeValue(host.runtime.ctx, size_value);
    var size: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &size, size_value));
    try std.testing.expectEqual(@as(f64, 14), size);
}

test "runtime environment includes std process module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import process, { getEnv } from "std:process";
        \\globalThis.__hao_process_path_named = getEnv("PATH") !== null;
        \\globalThis.__hao_process_path_default = process.getEnv("PATH") !== null;
        \\globalThis.__hao_process_missing = getEnv("__HAO_ENV_MISSING_TEST_KEY__");
    ,
        "<hao-process-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const named = qjs.getProperty(host.runtime.ctx, global, "__hao_process_path_named");
    defer qjs.freeValue(host.runtime.ctx, named);
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, named));

    const default = qjs.getProperty(host.runtime.ctx, global, "__hao_process_path_default");
    defer qjs.freeValue(host.runtime.ctx, default);
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, default));

    const missing = qjs.getProperty(host.runtime.ctx, global, "__hao_process_missing");
    defer qjs.freeValue(host.runtime.ctx, missing);
    try std.testing.expect(qjs.isNull(missing));
}

test "runtime environment includes std http module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import http, { get, post, request } from "std:http";
        \\globalThis.__hao_http_get = typeof get;
        \\globalThis.__hao_http_post = typeof post;
        \\globalThis.__hao_http_request = typeof request;
        \\globalThis.__hao_http_default = typeof http.request;
    ,
        "<hao-http-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    inline for ([_][:0]const u8{
        "__hao_http_get",
        "__hao_http_post",
        "__hao_http_request",
        "__hao_http_default",
    }) |key| {
        const value = qjs.getProperty(host.runtime.ctx, global, key);
        defer qjs.freeValue(host.runtime.ctx, value);
        const text = try qjs.valueToStringAlloc(host.runtime.ctx, value, std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("function", text);
    }
}

test "runtime environment includes std util module by default" {
    util_native.defaults = .{};
    defer util_native.defaults = .{};

    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import util, { inspect, getInspectOptions, setInspectOptions } from "std:util";
        \\setInspectOptions({ maxArrayLength: 2 });
        \\globalThis.__hao_util_text = inspect([1, 2, 3]);
        \\globalThis.__hao_util_default = typeof util.inspect;
        \\globalThis.__hao_util_options = getInspectOptions().maxArrayLength;
    ,
        "<hao-util-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const text_value = qjs.getProperty(host.runtime.ctx, global, "__hao_util_text");
    defer qjs.freeValue(host.runtime.ctx, text_value);
    const text = try qjs.valueToStringAlloc(host.runtime.ctx, text_value, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("[ 1, 2, ... 1 more items ]", text);

    const default_value = qjs.getProperty(host.runtime.ctx, global, "__hao_util_default");
    defer qjs.freeValue(host.runtime.ctx, default_value);
    const default_text = try qjs.valueToStringAlloc(host.runtime.ctx, default_value, std.testing.allocator);
    defer std.testing.allocator.free(default_text);
    try std.testing.expectEqualStrings("function", default_text);

    const options_value = qjs.getProperty(host.runtime.ctx, global, "__hao_util_options");
    defer qjs.freeValue(host.runtime.ctx, options_value);
    var options: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &options, options_value));
    try std.testing.expectEqual(@as(f64, 2), options);
}

test "runtime environment includes std plot module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/hao-plot");
    try host.evalModuleSource(
        \\import { figure, plot, render, savefig } from "std:plot";
        \\import { existsSync, readFileSync } from "std:fs";
        \\figure({ width: 320, height: 240, title: "Hao" });
        \\plot([1, 4, 2], { label: "data", color: "#ff0000" });
        \\const svg = render();
        \\globalThis.__hao_plot_has_svg = svg.includes("<svg") && svg.includes("Hao");
        \\savefig(".zig-cache/hao-tests/hao-plot/out.svg");
        \\globalThis.__hao_plot_saved = existsSync(".zig-cache/hao-tests/hao-plot/out.svg");
        \\globalThis.__hao_plot_file_has_svg = readFileSync(".zig-cache/hao-tests/hao-plot/out.svg").includes("<svg");
    ,
        "<hao-plot-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    inline for ([_][:0]const u8{
        "__hao_plot_has_svg",
        "__hao_plot_saved",
        "__hao_plot_file_has_svg",
    }) |key| {
        const value = qjs.getProperty(host.runtime.ctx, global, key);
        defer qjs.freeValue(host.runtime.ctx, value);
        try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, value));
    }
}

test "runtime environment includes std ffi module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import ffi, { dlopen, c } from "std:ffi";
        \\globalThis.__hao_ffi_dlopen = typeof dlopen;
        \\globalThis.__hao_ffi_default = typeof ffi.dlopen;
        \\let unsupported = false;
        \\try { c.decl("x", "int x(void);"); } catch { unsupported = true; }
        \\globalThis.__hao_ffi_c_unsupported = unsupported;
    ,
        "<hao-ffi-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    inline for ([_][:0]const u8{
        "__hao_ffi_dlopen",
        "__hao_ffi_default",
    }) |key| {
        const value = qjs.getProperty(host.runtime.ctx, global, key);
        defer qjs.freeValue(host.runtime.ctx, value);
        const text = try qjs.valueToStringAlloc(host.runtime.ctx, value, std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("function", text);
    }

    const unsupported_value = qjs.getProperty(host.runtime.ctx, global, "__hao_ffi_c_unsupported");
    defer qjs.freeValue(host.runtime.ctx, unsupported_value);
    try std.testing.expectEqual(@as(c_int, 1), qjs.c.JS_ToBool(host.runtime.ctx, unsupported_value));
}

test "runtime environment includes std ffi c declaration module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import cmod, { decl } from "std:ffi/c";
        \\import { prepareNative } from "std:ffi/c/native";
        \\const prepared = prepareNative("x", "int32_t add(int32_t a, int32_t b);");
        \\globalThis.__hao_ffi_c_decl = typeof decl;
        \\globalThis.__hao_ffi_c_default = typeof cmod.decl;
        \\globalThis.__hao_ffi_c_returns = prepared.descriptor.add.returns;
    ,
        "<hao-ffi-c-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    inline for ([_][:0]const u8{
        "__hao_ffi_c_decl",
        "__hao_ffi_c_default",
    }) |key| {
        const value = qjs.getProperty(host.runtime.ctx, global, key);
        defer qjs.freeValue(host.runtime.ctx, value);
        const text = try qjs.valueToStringAlloc(host.runtime.ctx, value, std.testing.allocator);
        defer std.testing.allocator.free(text);
        try std.testing.expectEqualStrings("function", text);
    }

    const returns_value = qjs.getProperty(host.runtime.ctx, global, "__hao_ffi_c_returns");
    defer qjs.freeValue(host.runtime.ctx, returns_value);
    const returns_text = try qjs.valueToStringAlloc(host.runtime.ctx, returns_value, std.testing.allocator);
    defer std.testing.allocator.free(returns_text);
    try std.testing.expectEqualStrings("i32", returns_text);
}

test "runtime environment includes std test module by default" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import { describe, test, expect, mock } from "std:test";
        \\import { getRegisteredCounts } from "std:test/native";
        \\describe("math", () => {
        \\  test("adds", () => expect(1 + 1).toBe(2));
        \\});
        \\const fn = mock.fn(() => 42);
        \\fn();
        \\expect(fn).toHaveBeenCalledTimes(1);
        \\globalThis.__hao_test_counts = getRegisteredCounts();
    ,
        "<hao-test-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const counts = qjs.getProperty(host.runtime.ctx, global, "__hao_test_counts");
    defer qjs.freeValue(host.runtime.ctx, counts);

    const registered_tests = qjs.getProperty(host.runtime.ctx, counts, "registeredTests");
    defer qjs.freeValue(host.runtime.ctx, registered_tests);
    var tests_count: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &tests_count, registered_tests));
    try std.testing.expectEqual(@as(f64, 1), tests_count);

    const registered_hooks = qjs.getProperty(host.runtime.ctx, counts, "registeredHooks");
    defer qjs.freeValue(host.runtime.ctx, registered_hooks);
    var hooks_count: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &hooks_count, registered_hooks));
    try std.testing.expectEqual(@as(f64, 1), hooks_count);
}

test "runtime environment evaluates registered packages without std" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = false });
    defer host.deinit();

    const sources = [_]packages.SourceModule{.{
        .specifier = "app:main",
        .source = "globalThis.__hao_app_value = 42;",
    }};
    try host.registerPackage(.{
        .name = "app",
        .sources = &sources,
    });
    try host.evalModuleSource("import 'app:main';", "<app>");

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const value = qjs.getProperty(host.runtime.ctx, global, "__hao_app_value");
    defer qjs.freeValue(host.runtime.ctx, value);
    var number: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &number, value));
    try std.testing.expectEqual(@as(f64, 42), number);
}

test "standard module install initializes hao test registry" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();

    var registry = packages.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try hao_std.register(&registry);
    var package_context = packages.PackageContext{ .runtime = &host.runtime, .allocator = host.allocator };
    defer registry.deinitPackages(&package_context);

    try host.evalModuleSourceWithRegistry(
        \\import { test } from "std:test";
        \\import { getRegisteredCounts } from "std:test/native";
        \\test("registered by package install", () => {});
        \\globalThis.__hao_test_install_counts = getRegisteredCounts();
    ,
        "<hao-test-install-test>",
        &registry,
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const counts = qjs.getProperty(host.runtime.ctx, global, "__hao_test_install_counts");
    defer qjs.freeValue(host.runtime.ctx, counts);
    const registered_tests = qjs.getProperty(host.runtime.ctx, counts, "registeredTests");
    defer qjs.freeValue(host.runtime.ctx, registered_tests);
    var tests_count: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &tests_count, registered_tests));
    try std.testing.expectEqual(@as(f64, 1), tests_count);
}

test "runtime environment captures console output through std test module" {
    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import { captureOutput, expect } from "std:test";
        \\captureOutput(() => {
        \\  console.log("hello", { value: 42 });
        \\  console.error("bad");
        \\}, { target: "both" }).then((captured) => {
        \\  expect(captured.exitCode).toBe(0);
        \\  globalThis.__hao_capture_stdout = captured.stdout;
        \\  globalThis.__hao_capture_stderr = captured.stderr;
        \\  globalThis.__hao_capture_combined = captured.combined;
        \\});
    ,
        "<hao-test-capture-test>",
    );
    try host.runUntilIdle();

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const stdout_value = qjs.getProperty(host.runtime.ctx, global, "__hao_capture_stdout");
    defer qjs.freeValue(host.runtime.ctx, stdout_value);
    const stdout_text = try qjs.valueToStringAlloc(host.runtime.ctx, stdout_value, std.testing.allocator);
    defer std.testing.allocator.free(stdout_text);
    try std.testing.expect(std.mem.indexOf(u8, stdout_text, "hello { value: 42 }") != null);

    const stderr_value = qjs.getProperty(host.runtime.ctx, global, "__hao_capture_stderr");
    defer qjs.freeValue(host.runtime.ctx, stderr_value);
    const stderr_text = try qjs.valueToStringAlloc(host.runtime.ctx, stderr_value, std.testing.allocator);
    defer std.testing.allocator.free(stderr_text);
    try std.testing.expect(std.mem.indexOf(u8, stderr_text, "bad") != null);

    const combined_value = qjs.getProperty(host.runtime.ctx, global, "__hao_capture_combined");
    defer qjs.freeValue(host.runtime.ctx, combined_value);
    const combined_text = try qjs.valueToStringAlloc(host.runtime.ctx, combined_value, std.testing.allocator);
    defer std.testing.allocator.free(combined_text);
    try std.testing.expect(std.mem.indexOf(u8, combined_text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, combined_text, "bad") != null);
}

test "runtime environment runs child process through std process module" {
    var host = try RuntimeEnvironment.initWithIo(std.testing.allocator, std.testing.io, .{ .std = true });
    defer host.deinit();
    try host.evalModuleSource(
        \\import process, { run } from "std:process";
        \\run({ cmd: "printf", args: ["42"] }).text().then((text) => {
        \\  globalThis.__hao_process_run_named = text;
        \\});
        \\process.run("printf default").text().then((text) => {
        \\  globalThis.__hao_process_run_default = text;
        \\});
    ,
        "<hao-process-run-test>",
    );
    try host.runUntilIdle();

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const named_value = qjs.getProperty(host.runtime.ctx, global, "__hao_process_run_named");
    defer qjs.freeValue(host.runtime.ctx, named_value);
    const named = try qjs.valueToStringAlloc(host.runtime.ctx, named_value, std.testing.allocator);
    defer std.testing.allocator.free(named);
    try std.testing.expectEqualStrings("42", named);

    const default_value = qjs.getProperty(host.runtime.ctx, global, "__hao_process_run_default");
    defer qjs.freeValue(host.runtime.ctx, default_value);
    const default = try qjs.valueToStringAlloc(host.runtime.ctx, default_value, std.testing.allocator);
    defer std.testing.allocator.free(default);
    try std.testing.expectEqualStrings("default", default);
}

test "runtime environment imports dynamic native addon package" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const root = ".zig-cache/hao-tests/runtime-native-addon";
    const package_root = root ++ "/node_modules/foo";
    try fs.makePath(std.testing.allocator, package_root);
    try fs.writeFile(root ++ "/main.ts",
        \\import native from "foo:native";
        \\import extra from "foo:extra";
        \\globalThis.__hao_addon_foo = native.foo();
        \\globalThis.__hao_addon_sum = native.add(20, 22);
        \\globalThis.__hao_addon_pair = native.pair("left", "right").join(":");
        \\globalThis.__hao_addon_extra = extra.label();
    );

    const lib_path = switch (builtin.os.tag) {
        .macos => package_root ++ "/native.dylib",
        else => package_root ++ "/native.so",
    };
    const package_json = switch (builtin.os.tag) {
        .macos => "{\"type\":\"module\",\"exports\":{\"./native\":\"./native.dylib\",\"./extra\":\"./native.dylib\"}}",
        else => "{\"type\":\"module\",\"exports\":{\"./native\":\"./native.so\",\"./extra\":\"./native.so\"}}",
    };
    try fs.writeFile(package_root ++ "/package.json", package_json);
    const compile_args = switch (builtin.os.tag) {
        .macos => &[_][]const u8{ "cc", "-Iinclude", "-dynamiclib", "examples/native-addon/native.c", "-o", lib_path },
        else => &[_][]const u8{ "cc", "-Iinclude", "-shared", "-fPIC", "examples/native-addon/native.c", "-o", lib_path },
    };
    const compile = try std.process.run(std.testing.allocator, std.testing.io, .{ .argv = compile_args });
    defer {
        std.testing.allocator.free(compile.stdout);
        std.testing.allocator.free(compile.stderr);
    }
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, compile.term);

    var host = try RuntimeEnvironment.init(std.testing.allocator, .{ .std = true });
    defer host.deinit();
    try host.runFile(root ++ "/main.ts");

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);

    const foo_value = qjs.getProperty(host.runtime.ctx, global, "__hao_addon_foo");
    defer qjs.freeValue(host.runtime.ctx, foo_value);
    const foo_text = try qjs.valueToStringAlloc(host.runtime.ctx, foo_value, std.testing.allocator);
    defer std.testing.allocator.free(foo_text);
    try std.testing.expectEqualStrings("hao", foo_text);

    const sum_value = qjs.getProperty(host.runtime.ctx, global, "__hao_addon_sum");
    defer qjs.freeValue(host.runtime.ctx, sum_value);
    var sum: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(host.runtime.ctx, &sum, sum_value));
    try std.testing.expectEqual(@as(f64, 42), sum);

    const pair_value = qjs.getProperty(host.runtime.ctx, global, "__hao_addon_pair");
    defer qjs.freeValue(host.runtime.ctx, pair_value);
    const pair_text = try qjs.valueToStringAlloc(host.runtime.ctx, pair_value, std.testing.allocator);
    defer std.testing.allocator.free(pair_text);
    try std.testing.expectEqualStrings("left:right", pair_text);

    const extra_value = qjs.getProperty(host.runtime.ctx, global, "__hao_addon_extra");
    defer qjs.freeValue(host.runtime.ctx, extra_value);
    const extra_text = try qjs.valueToStringAlloc(host.runtime.ctx, extra_value, std.testing.allocator);
    defer std.testing.allocator.free(extra_text);
    try std.testing.expectEqualStrings("extra", extra_text);
}
