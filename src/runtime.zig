const std = @import("std");
const fs = @import("fs.zig");
const qjs = @import("qjs.zig");
const async_loop = @import("async/loop.zig");
const global_timer = @import("global/timer.zig");
const module = @import("module.zig");
const packages = @import("package.zig");

pub const Host = struct {
    runtime: qjs.Runtime,
    loop: async_loop.Loop,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Host {
        var runtime = try qjs.Runtime.init();
        errdefer runtime.deinit();

        var loop = try async_loop.Loop.init(allocator);
        errdefer loop.deinit();

        return .{
            .runtime = runtime,
            .loop = loop,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Host) void {
        async_loop.detachCurrent();
        global_timer.cleanup(self.allocator);
        self.loop.deinit();
        self.runtime.deinit();
        self.* = undefined;
    }

    pub fn installGlobals(self: *Host) !void {
        async_loop.attachCurrent(&self.loop);
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
        try module.evalModuleSource(&loader, &self.runtime, source, source_name);
    }

    pub fn evalModuleSource(self: *Host, source: []const u8, source_name: []const u8) !void {
        var registry = packages.Registry.init(self.allocator);
        defer registry.deinit();
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
        try self.runFileWithRegistry(path, &registry);
    }

    pub fn runUntilIdle(self: *Host) !void {
        async_loop.attachCurrent(&self.loop);
        defer async_loop.detachCurrent();

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
