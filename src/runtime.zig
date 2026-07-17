const std = @import("std");
const fs = @import("fs.zig");
const qjs = @import("qjs.zig");
const async_loop = @import("async/loop.zig");
const global_console = @import("global/console.zig");
const global_timer = @import("global/timer.zig");
const module = @import("module.zig");
const packages = @import("package.zig");
const hao_std = @import("std.zig");
const http_native = @import("std/http/native.zig");
const process_native = @import("std/process/native.zig");
const test_registry = @import("std/test/registry.zig");
const util_native = @import("std/util/native.zig");

pub const Host = struct {
    runtime: qjs.Runtime,
    loop: async_loop.Loop,
    allocator: std.mem.Allocator,
    io: ?std.Io = null,

    pub fn init(allocator: std.mem.Allocator) !Host {
        return initWithIo(allocator, null);
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: ?std.Io) !Host {
        var runtime = try qjs.Runtime.init();
        errdefer runtime.deinit();

        var loop = try async_loop.Loop.init(allocator);
        errdefer loop.deinit();

        try test_registry.init(allocator);
        errdefer test_registry.deinit(runtime.ctx);

        return .{
            .runtime = runtime,
            .loop = loop,
            .allocator = allocator,
            .io = io,
        };
    }

    pub fn deinit(self: *Host) void {
        async_loop.detachCurrent();
        http_native.detachIo();
        process_native.detachIo();
        global_console.capture_state = null;
        global_timer.cleanup(self.allocator);
        test_registry.deinit(self.runtime.ctx);
        self.loop.deinit();
        self.runtime.deinit();
        self.* = undefined;
    }

    pub fn installGlobals(self: *Host) !void {
        async_loop.attachCurrent(&self.loop);
        if (self.io) |io| http_native.attachIo(io);
        if (self.io) |io| process_native.attachIo(io);
        try global_console.register(self.runtime.ctx);
        try global_timer.register(self.runtime.ctx);
    }

    pub fn evalModuleSourceWithRegistry(
        self: *Host,
        source: []const u8,
        source_name: []const u8,
        registry: *const packages.Registry,
    ) !void {
        var loader = module.Loader{
            .allocator = self.allocator,
            .registry = registry,
        };
        loader.install(&self.runtime);
        async_loop.attachCurrent(&self.loop);
        if (self.io) |io| http_native.attachIo(io);
        if (self.io) |io| process_native.attachIo(io);
        try global_console.register(self.runtime.ctx);
        try module.evalModuleSource(&loader, &self.runtime, source, source_name);
    }

    pub fn evalModuleSource(self: *Host, source: []const u8, source_name: []const u8) !void {
        var registry = packages.Registry.init(self.allocator);
        defer registry.deinit();
        try hao_std.register(&registry);
        try self.evalModuleSourceWithRegistry(source, source_name, &registry);
    }

    pub fn runFileWithRegistry(self: *Host, path: []const u8, registry: *const packages.Registry) !void {
        try self.installGlobals();
        const source = try fs.readFileAlloc(self.allocator, path, 10 * 1024 * 1024);
        defer self.allocator.free(source);
        try self.evalModuleSourceWithRegistry(source, path, registry);
        try self.runUntilIdle();
    }

    pub fn runFile(self: *Host, path: []const u8) !void {
        var registry = packages.Registry.init(self.allocator);
        defer registry.deinit();
        try hao_std.register(&registry);
        try self.runFileWithRegistry(path, &registry);
    }

    pub fn runUntilIdle(self: *Host) !void {
        async_loop.attachCurrent(&self.loop);
        if (self.io) |io| http_native.attachIo(io);
        if (self.io) |io| process_native.attachIo(io);
        defer async_loop.detachCurrent();
        defer http_native.detachIo();
        defer process_native.detachIo();

        while (true) {
            const ran_jobs = try qjs.executePendingJobs(self.runtime.rt);
            if (qjs.takeUnhandledException()) |pending| {
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            const ran_uv = try self.loop.runUntilIdle();
            if (qjs.takeUnhandledException()) |pending| {
                defer qjs.freeValue(pending.ctx, pending.value);
                return error.JavaScriptError;
            }
            if (!ran_jobs and !ran_uv) break;
        }
    }
};

test "runtime host runs timer callbacks until idle" {
    var host = try Host.init(std.testing.allocator);
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

test "runtime host runs a TypeScript entry file" {
    const root = ".zig-cache/hao-tests/runtime-run-file";
    try fs.makePath(std.testing.allocator, root);
    try fs.writeFile(
        root ++ "/main.ts",
        \\const value: number = 40;
        \\setTimeout(() => { globalThis.__hao_run_file_value = value + 2; }, 1);
        ,
    );

    var host = try Host.init(std.testing.allocator);
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

test "runtime host includes hao namespace modules by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        "import { namespace } from 'hao:runtime'; globalThis.__hao_namespace_value = namespace;",
        "<hao-runtime-test>",
    );

    const global = qjs.c.JS_GetGlobalObject(host.runtime.ctx);
    defer qjs.freeValue(host.runtime.ctx, global);
    const result = qjs.getProperty(host.runtime.ctx, global, "__hao_namespace_value");
    defer qjs.freeValue(host.runtime.ctx, result);
    const text = try qjs.valueToStringAlloc(host.runtime.ctx, result, std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hao:", text);
}

test "runtime host includes hao fs module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/hao-fs");
    try host.evalModuleSource(
        \\import { existsSync, readFileSync, statSync, writeFileSync } from "hao:fs";
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

test "runtime host includes hao process module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import process, { getEnv } from "hao:process";
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

test "runtime host includes hao http module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import http, { get, post, request } from "hao:http";
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

test "runtime host includes hao util module by default" {
    util_native.defaults = .{};
    defer util_native.defaults = .{};

    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import util, { inspect, getInspectOptions, setInspectOptions } from "hao:util";
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

test "runtime host includes hao plot module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try fs.makePath(std.testing.allocator, ".zig-cache/hao-tests/hao-plot");
    try host.evalModuleSource(
        \\import { figure, plot, render, savefig } from "hao:plot";
        \\import { existsSync, readFileSync } from "hao:fs";
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

test "runtime host includes hao ffi module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import ffi, { dlopen, c } from "hao:ffi";
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

test "runtime host includes hao ffi c declaration module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import cmod, { decl } from "hao:ffi/c";
        \\import { prepareNative } from "hao:ffi/c/native";
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

test "runtime host includes hao test module by default" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import { describe, test, expect, mock } from "hao:test";
        \\import { getRegisteredCounts } from "hao:test/native";
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

test "runtime host captures console output through hao test module" {
    var host = try Host.init(std.testing.allocator);
    defer host.deinit();
    try host.evalModuleSource(
        \\import { captureOutput, expect } from "hao:test";
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

test "runtime host runs child process through hao process module" {
    var host = try Host.initWithIo(std.testing.allocator, std.testing.io);
    defer host.deinit();
    try host.evalModuleSource(
        \\import process, { run } from "hao:process";
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
