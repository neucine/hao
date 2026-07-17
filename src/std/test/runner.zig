const std = @import("std");
const qjs = @import("../../qjs.zig");
const async_loop = @import("../../async/loop.zig");
const errors = @import("../../errors.zig");
const global_console = @import("../../global/console.zig");
const global_timer = @import("../../global/timer.zig");
const fs = @import("../../fs.zig");
const module_runtime = @import("../../module.zig");
const native_extension = @import("../../native_extension.zig");
const packages = @import("../../package.zig");
const hao_std = @import("../../std.zig");
const http_native = @import("../http/native.zig");
const process_native = @import("../process/native.zig");
const registry = @import("registry.zig");
const bindings = @import("native.zig");

const Failure = struct {
    phase: []const u8,
    message: []u8,
};

pub const RunResult = struct {
    passed: usize = 0,
    failed: usize = 0,
    file_failures: usize = 0,
    skipped: usize = 0,
    skipped_declared: usize = 0,
    skipped_filtered: usize = 0,
    skipped_blocked: usize = 0,
    duration_ns: u64 = 0,

    pub fn totalFailures(self: RunResult) usize {
        return self.failed + self.file_failures;
    }

    pub fn exitCode(self: RunResult) u8 {
        return if (self.totalFailures() > 0) 1 else 0;
    }
};

const RunOptions = struct {
    grep: ?[]const u8,
    only_mode: bool,
};

fn writeStdout(bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var size: u32 = std.Io.Dir.max_path_bytes;
    var buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) {
        allocator.free(buf);
        buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) return error.ExecutablePathUnavailable;
    }
    return try allocator.realloc(buf, std.mem.indexOfScalar(u8, buf, 0) orelse size);
}

fn exceptionSummaryAlloc(ctx: ?*qjs.c.JSContext, exception: qjs.c.JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    if (qjs.isException(exception)) {
        const actual = qjs.c.JS_GetException(ctx);
        defer qjs.freeValue(ctx, actual);
        return exceptionSummaryAlloc(ctx, actual, allocator);
    }
    if (qjs.isObject(exception)) {
        const message = qjs.getProperty(ctx, exception, "message");
        defer qjs.freeValue(ctx, message);
        if (!qjs.isUndefined(message) and !qjs.isNull(message)) {
            const text = qjs.valueToStringAlloc(ctx, message, allocator) catch null;
            if (text) |owned| {
                if (owned.len > 0) return owned;
                allocator.free(owned);
            }
        }
    }
    return qjs.valueToStringAlloc(ctx, exception, allocator);
}

fn makeFailure(ctx: ?*qjs.c.JSContext, allocator: std.mem.Allocator, phase: []const u8, exception: qjs.c.JSValueConst) !Failure {
    return .{
        .phase = phase,
        .message = try exceptionSummaryAlloc(ctx, exception, allocator),
    };
}

fn runTestFile(loader: *module_runtime.Loader, runtime: *qjs.Runtime, path: []const u8, allocator: std.mem.Allocator) !void {
    const abs_path = try allocator.dupe(u8, path);
    defer allocator.free(abs_path);
    registry.setCurrentFilePath(abs_path);
    bindings.setCurrentTestFilePath(abs_path);
    const source = try fs.readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(source);
    try module_runtime.evalModuleSource(loader, runtime, source, path);

    if (qjs.takeUnhandledException()) |pending| {
        defer qjs.freeValue(pending.ctx, pending.value);
        _ = qjs.c.JS_Throw(pending.ctx, qjs.dupValue(pending.ctx, pending.value));
        return error.JavaScriptError;
    }

    const probe = qjs.eval(runtime.ctx, "void 0", "<hao:test-qjs-load-probe>", qjs.EvalFlags.global);
    defer qjs.freeValue(runtime.ctx, probe);
    if (qjs.isException(probe)) return error.JavaScriptError;
}

fn isTestFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".test.ts");
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn appendDiscoveredTestDir(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    if (!@hasDecl(std.fs, "cwd")) return appendDiscoveredTestDirCompat(allocator, out, dir_path);

    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        switch (entry.kind) {
            .file => {
                if (isTestFile(child_path)) {
                    try out.append(allocator, child_path);
                } else {
                    allocator.free(child_path);
                }
            },
            .directory => {
                try appendDiscoveredTestDir(allocator, out, child_path);
                allocator.free(child_path);
            },
            else => allocator.free(child_path),
        }
    }
}

fn appendDiscoveredTestDirCompat(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), dir_path: []const u8) !void {
    const dir_path_z = try allocator.dupeZ(u8, dir_path);
    defer allocator.free(dir_path_z);
    const dir = std.c.opendir(dir_path_z.ptr) orelse return error.NotDir;
    defer _ = std.c.closedir(dir);

    while (std.c.readdir(dir)) |entry_ptr| {
        const entry = entry_ptr.*;
        const name = if (@hasField(std.c.dirent, "namlen"))
            entry.name[0..entry.namlen]
        else
            std.mem.sliceTo(&entry.name, 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

        const child_path = try std.fs.path.join(allocator, &.{ dir_path, name });
        if (isDirectoryCompat(child_path)) {
            try appendDiscoveredTestDirCompat(allocator, out, child_path);
            allocator.free(child_path);
        } else if (isTestFile(child_path)) {
            try out.append(allocator, child_path);
        } else {
            allocator.free(child_path);
        }
    }
}

fn isDirectoryCompat(path: []const u8) bool {
    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return false;
    defer std.heap.page_allocator.free(path_z);
    const dir = std.c.opendir(path_z.ptr) orelse return false;
    _ = std.c.closedir(dir);
    return true;
}

fn collectTestPaths(paths: [][]const u8, allocator: std.mem.Allocator) !std.ArrayList([]const u8) {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |path| allocator.free(path);
        out.deinit(allocator);
    }

    for (paths) |path| {
        if (isDirectoryCompat(path)) {
            try appendDiscoveredTestDirCompat(allocator, &out, path);
        } else if (fs.pathExists(path)) {
            try out.append(allocator, try allocator.dupe(u8, path));
        }
    }

    std.mem.sort([]const u8, out.items, {}, pathLessThan);
    return out;
}

fn isPromiseLike(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) bool {
    if (!qjs.isObject(value)) return false;
    const then_val = qjs.getProperty(ctx, value, "then");
    defer qjs.freeValue(ctx, then_val);
    return qjs.isFunction(ctx, then_val);
}

fn jsGetBool(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, key: [:0]const u8) bool {
    const value = qjs.getProperty(ctx, obj, key);
    defer qjs.freeValue(ctx, value);
    return qjs.c.JS_ToBool(ctx, value) == 1;
}

fn awaitPromise(runtime: *qjs.Runtime, loop: *async_loop.Loop, promise_value: qjs.c.JSValueConst, allocator: std.mem.Allocator, phase: []const u8) !?Failure {
    const ctx = runtime.ctx;
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const state = qjs.newObject(ctx);
    if (qjs.isException(state)) return Failure{ .phase = phase, .message = try allocator.dupe(u8, "failed to create async state") };
    defer qjs.freeValue(ctx, state);

    try qjs.setProperty(ctx, state, "settled", qjs.boolValue(ctx, false));
    try qjs.setProperty(ctx, state, "ok", qjs.boolValue(ctx, false));
    try qjs.setProperty(ctx, state, "error", qjs.undefinedValue(ctx));
    try qjs.setProperty(ctx, global, "__hao_test_async_state", qjs.dupValue(ctx, state));
    try qjs.setProperty(ctx, global, "__hao_test_async_promise", qjs.dupValue(ctx, promise_value));

    const bootstrap =
        \\Promise.resolve(globalThis.__hao_test_async_promise).then(
        \\  () => { globalThis.__hao_test_async_state.settled = true; globalThis.__hao_test_async_state.ok = true; },
        \\  (err) => { globalThis.__hao_test_async_state.settled = true; globalThis.__hao_test_async_state.ok = false; globalThis.__hao_test_async_state.error = err; },
        \\);
    ;
    const value = qjs.eval(ctx, bootstrap, "<hao:test>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, value);
    if (qjs.isException(value)) return try makeFailure(ctx, allocator, phase, value);

    while (true) {
        if (jsGetBool(ctx, state, "settled")) {
            if (jsGetBool(ctx, state, "ok")) return null;
            const err_val = qjs.getProperty(ctx, state, "error");
            defer qjs.freeValue(ctx, err_val);
            return try makeFailure(ctx, allocator, phase, err_val);
        }

        const ran_jobs = qjs.executePendingJobs(runtime.rt) catch |err| {
            if (err == error.JavaScriptError) {
                const exception = qjs.c.JS_GetException(ctx);
                defer qjs.freeValue(ctx, exception);
                return try makeFailure(ctx, allocator, phase, exception);
            }
            return err;
        };
        if (qjs.takeUnhandledException()) |pending| {
            defer qjs.freeValue(pending.ctx, pending.value);
            return try makeFailure(pending.ctx, allocator, phase, pending.value);
        }
        const ran_uv = loop.runOnce() catch return error.LibuvRunFailed;
        if (qjs.takeUnhandledException()) |pending| {
            defer qjs.freeValue(pending.ctx, pending.value);
            return try makeFailure(pending.ctx, allocator, phase, pending.value);
        }
        if (!ran_jobs and !ran_uv) {
            if (jsGetBool(ctx, state, "settled")) continue;
            return Failure{
                .phase = phase,
                .message = try allocator.dupe(u8, "Promise did not settle"),
            };
        }
    }
}

fn callFunction(runtime: *qjs.Runtime, loop: *async_loop.Loop, callback: qjs.c.JSValueConst, file_path: []const u8, allocator: std.mem.Allocator, phase: []const u8) !?Failure {
    bindings.setCurrentTestFilePath(file_path);
    const result = qjs.call(runtime.ctx, callback, qjs.undefinedValue(runtime.ctx), &.{});
    defer qjs.freeValue(runtime.ctx, result);
    if (qjs.isException(result)) return try makeFailure(runtime.ctx, allocator, phase, result);
    if (qjs.takeUnhandledException()) |pending| {
        defer qjs.freeValue(pending.ctx, pending.value);
        return try makeFailure(pending.ctx, allocator, phase, pending.value);
    }
    if (isPromiseLike(runtime.ctx, result)) {
        return try awaitPromise(runtime, loop, result, allocator, phase);
    }

    // Some native-throw/catch paths can leave a stale pending exception on the
    // QJS context even when the JS callback completed successfully. Probe with
    // a no-op eval so the runner does not leak one test's caught exception into
    // the next test case.
    const probe = qjs.eval(runtime.ctx, "void 0", "<hao:test-probe>", qjs.EvalFlags.global);
    defer qjs.freeValue(runtime.ctx, probe);
    if (qjs.isException(probe)) {
        const stray = qjs.c.JS_GetException(runtime.ctx);
        defer qjs.freeValue(runtime.ctx, stray);
    }
    if (qjs.takeUnhandledException()) |pending| {
        defer qjs.freeValue(pending.ctx, pending.value);
        return try makeFailure(pending.ctx, allocator, phase, pending.value);
    }
    return null;
}

fn buildSuiteChain(suite: *registry.Suite, list: *std.ArrayList(*registry.Suite), allocator: std.mem.Allocator) !void {
    if (suite.parent) |parent| try buildSuiteChain(parent, list, allocator);
    if (suite.parent != null) try list.append(allocator, suite);
}

pub fn formatDuration(buf: []u8, duration_ns: u64) ![]const u8 {
    if (duration_ns < std.time.ns_per_us) return std.fmt.bufPrint(buf, "{d}ns", .{duration_ns});
    if (duration_ns < std.time.ns_per_ms) {
        const whole = duration_ns / std.time.ns_per_us;
        const frac = (duration_ns % std.time.ns_per_us) / 10;
        return std.fmt.bufPrint(buf, "{d}.{d:0>2}us", .{ whole, frac });
    }
    if (duration_ns < std.time.ns_per_s) {
        const whole = duration_ns / std.time.ns_per_ms;
        const frac = (duration_ns % std.time.ns_per_ms) / 10_000;
        return std.fmt.bufPrint(buf, "{d}.{d:0>2}ms", .{ whole, frac });
    }
    const whole = duration_ns / std.time.ns_per_s;
    const frac = (duration_ns % std.time.ns_per_s) / 10_000_000;
    return std.fmt.bufPrint(buf, "{d}.{d:0>2}s", .{ whole, frac });
}

fn printIndent(depth: usize) void {
    var i: usize = 0;
    while (i < depth) : (i += 1) writeStdout("  ");
}

fn printDuration(duration_ns: u64) void {
    var buf: [64]u8 = undefined;
    writeStdout(" (");
    const line = formatDuration(&buf, duration_ns) catch return;
    writeStdout(line);
    writeStdout(")");
}

fn printFailure(depth: usize, failure: Failure) void {
    printIndent(depth);
    writeStdout(failure.phase);
    writeStdout(" failed: ");
    writeStdout(failure.message);
    writeStdout("\n");
}

fn printSkip(depth: usize, name: []const u8, reason: []const u8) void {
    printIndent(depth);
    writeStdout("- ");
    writeStdout(name);
    writeStdout(" (skipped: ");
    writeStdout(reason);
    writeStdout(")\n");
}

const SkipReason = enum { none, declared, filtered };

fn caseSelected(case_: registry.TestCase, opts: RunOptions) bool {
    if (case_.mode == .skip) return false;
    if (opts.only_mode and case_.mode != .only) return false;
    if (opts.grep) |pattern| {
        if (std.mem.indexOf(u8, case_.name, pattern) == null) return false;
    }
    return true;
}

fn caseSkipReason(case_: registry.TestCase, opts: RunOptions) SkipReason {
    if (case_.mode == .skip) return .declared;
    if (opts.only_mode and case_.mode != .only) return .filtered;
    if (opts.grep) |pattern| {
        if (std.mem.indexOf(u8, case_.name, pattern) == null) return .filtered;
    }
    return .none;
}

fn suiteHasSelectedCases(suite: *registry.Suite, opts: RunOptions) bool {
    for (suite.entries.items) |entry| switch (entry) {
        .case_index => |case_index| {
            const case_ = suite.cases.items[case_index];
            if (caseSelected(case_, opts)) return true;
        },
        .child => |child| if (suiteHasSelectedCases(child, opts)) return true,
    };
    return false;
}

fn addSkip(summary: *RunResult, reason: enum { declared, filtered, blocked }) void {
    summary.skipped += 1;
    switch (reason) {
        .declared => summary.skipped_declared += 1,
        .filtered => summary.skipped_filtered += 1,
        .blocked => summary.skipped_blocked += 1,
    }
}

fn addBlockedSelectedCases(summary: *RunResult, suite: *registry.Suite, opts: RunOptions) void {
    for (suite.entries.items) |entry| switch (entry) {
        .case_index => |case_index| {
            const case_ = suite.cases.items[case_index];
            if (caseSelected(case_, opts)) addSkip(summary, .blocked);
        },
        .child => |child| addBlockedSelectedCases(summary, child, opts),
    };
}

fn printBlockedSuite(suite: *registry.Suite, depth: usize, opts: RunOptions) !void {
    if (suite.name.len > 0) {
        printIndent(depth);
        writeStdout(suite.name);
        writeStdout("\n");
    }
    for (suite.entries.items) |entry| switch (entry) {
        .case_index => |case_index| {
            const case_ = suite.cases.items[case_index];
            if (caseSelected(case_, opts)) {
                printSkip(depth + 1, case_.name, "beforeAll");
            } else switch (caseSkipReason(case_, opts)) {
                .declared => printSkip(depth + 1, case_.name, "skip"),
                .filtered => printSkip(depth + 1, case_.name, if (opts.only_mode) "only" else "grep"),
                .none => {},
            }
        },
        .child => |child| try printBlockedSuite(child, depth + 1, opts),
    };
}

fn runCase(runtime: *qjs.Runtime, loop: *async_loop.Loop, suite: *registry.Suite, case_: registry.TestCase, depth: usize, allocator: std.mem.Allocator, summary: *RunResult) !void {
    var suite_chain = std.ArrayList(*registry.Suite).empty;
    defer suite_chain.deinit(allocator);
    try buildSuiteChain(suite, &suite_chain, allocator);

    const start_ns = nanoTimestamp();
    var primary_failure: ?Failure = null;
    var successful_scopes: usize = 0;

    suite_loop: for (suite_chain.items) |scope| {
        for (scope.before_each.items) |hook| {
            if (try callFunction(runtime, loop, hook.callback, hook.file_path, allocator, "beforeEach")) |failure| {
                primary_failure = failure;
                break :suite_loop;
            }
        }
        successful_scopes += 1;
    }

    if (primary_failure == null) {
        if (try callFunction(runtime, loop, case_.callback, case_.file_path, allocator, "test")) |failure| {
            primary_failure = failure;
        }
    }

    if (successful_scopes > 0) {
        var scope_index = successful_scopes;
        while (scope_index > 0) : (scope_index -= 1) {
            const scope = suite_chain.items[scope_index - 1];
            var hook_index = scope.after_each.items.len;
            while (hook_index > 0) : (hook_index -= 1) {
                const hook = scope.after_each.items[hook_index - 1];
                if (try callFunction(runtime, loop, hook.callback, hook.file_path, allocator, "afterEach")) |failure| {
                    if (primary_failure == null) primary_failure = failure else {
                        printFailure(depth + 1, failure);
                        allocator.free(failure.message);
                    }
                }
            }
        }
    }

    const duration_ns: u64 = @intCast(nanoTimestamp() - start_ns);
    printIndent(depth);
    if (primary_failure) |failure| {
        summary.failed += 1;
        writeStdout("x ");
        writeStdout(case_.name);
        printDuration(duration_ns);
        writeStdout("\n");
        printFailure(depth + 1, failure);
        allocator.free(failure.message);
    } else {
        summary.passed += 1;
        writeStdout("ok ");
        writeStdout(case_.name);
        printDuration(duration_ns);
        writeStdout("\n");
    }
}

fn runSuite(runtime: *qjs.Runtime, loop: *async_loop.Loop, suite: *registry.Suite, depth: usize, allocator: std.mem.Allocator, summary: *RunResult, opts: RunOptions) !void {
    const has_selected = suiteHasSelectedCases(suite, opts);

    if (suite.name.len > 0) {
        printIndent(depth);
        writeStdout(suite.name);
        writeStdout("\n");
    }

    if (!has_selected) {
        for (suite.entries.items) |entry| switch (entry) {
            .case_index => |case_index| {
                const case_ = suite.cases.items[case_index];
                switch (caseSkipReason(case_, opts)) {
                    .declared => {
                        addSkip(summary, .declared);
                        printSkip(depth + 1, case_.name, "skip");
                    },
                    .filtered => {
                        addSkip(summary, .filtered);
                        printSkip(depth + 1, case_.name, if (opts.only_mode) "only" else "grep");
                    },
                    .none => {},
                }
            },
            .child => |child| try runSuite(runtime, loop, child, depth + 1, allocator, summary, opts),
        };
        return;
    }

    var before_all_failed = false;
    for (suite.before_all.items) |hook| {
        if (try callFunction(runtime, loop, hook.callback, hook.file_path, allocator, "beforeAll")) |failure| {
            before_all_failed = true;
            summary.failed += 1;
            printIndent(depth + 1);
            writeStdout("x beforeAll\n");
            printFailure(depth + 2, failure);
            allocator.free(failure.message);
            for (suite.entries.items) |entry| switch (entry) {
                .case_index => |case_index| {
                    const case_ = suite.cases.items[case_index];
                    if (caseSelected(case_, opts)) {
                        addSkip(summary, .blocked);
                        printSkip(depth + 1, case_.name, "beforeAll");
                    } else switch (caseSkipReason(case_, opts)) {
                        .declared => {
                            addSkip(summary, .declared);
                            printSkip(depth + 1, case_.name, "skip");
                        },
                        .filtered => {
                            addSkip(summary, .filtered);
                            printSkip(depth + 1, case_.name, if (opts.only_mode) "only" else "grep");
                        },
                        .none => {},
                    }
                },
                .child => |child| {
                    if (suiteHasSelectedCases(child, opts)) {
                        addBlockedSelectedCases(summary, child, opts);
                        try printBlockedSuite(child, depth + 1, opts);
                    } else {
                        try runSuite(runtime, loop, child, depth + 1, allocator, summary, opts);
                    }
                },
            };
            break;
        }
    }

    if (!before_all_failed) {
        for (suite.entries.items) |entry| switch (entry) {
            .case_index => |case_index| {
                const case_ = suite.cases.items[case_index];
                if (caseSelected(case_, opts)) {
                    try runCase(runtime, loop, suite, case_, depth + 1, allocator, summary);
                } else switch (caseSkipReason(case_, opts)) {
                    .declared => {
                        addSkip(summary, .declared);
                        printSkip(depth + 1, case_.name, "skip");
                    },
                    .filtered => {
                        addSkip(summary, .filtered);
                        printSkip(depth + 1, case_.name, if (opts.only_mode) "only" else "grep");
                    },
                    .none => {},
                }
            },
            .child => |child| try runSuite(runtime, loop, child, depth + 1, allocator, summary, opts),
        };
    }

    for (suite.after_all.items) |hook| {
        if (try callFunction(runtime, loop, hook.callback, hook.file_path, allocator, "afterAll")) |failure| {
            summary.failed += 1;
            printIndent(depth + 1);
            writeStdout("x afterAll\n");
            printFailure(depth + 2, failure);
            allocator.free(failure.message);
        }
    }
}

pub fn run(paths: [][]const u8, grep: ?[]const u8, print_summary: bool, allocator: std.mem.Allocator, io: ?std.Io) !RunResult {
    const run_start_ns = nanoTimestamp();

    var test_paths = try collectTestPaths(paths, allocator);
    defer {
        for (test_paths.items) |path| allocator.free(path);
        test_paths.deinit(allocator);
    }

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();
    defer global_timer.cleanup(allocator);
    defer native_extension.cleanup();
    defer global_console.capture_state = null;

    var loop = try async_loop.Loop.init(allocator);
    defer loop.deinit();
    async_loop.attachCurrent(&loop);
    defer async_loop.detachCurrent();
    if (io) |attached_io| {
        http_native.attachIo(attached_io);
        process_native.attachIo(attached_io);
    }
    defer http_native.detachIo();
    defer process_native.detachIo();

    try registry.init(allocator);
    defer registry.deinit(runtime.ctx);

    const exe_path = try selfExePathAlloc(allocator);
    defer allocator.free(exe_path);
    bindings.setCurrentExecutablePath(exe_path);

    try errors.registerRuntimeError(runtime.ctx, allocator);
    try global_console.register(runtime.ctx);
    try global_timer.register(runtime.ctx);

    var package_registry = packages.Registry.init(allocator);
    defer package_registry.deinit();
    try hao_std.register(&package_registry);

    var loader = module_runtime.Loader{
        .allocator = allocator,
        .registry = &package_registry,
    };
    loader.install(&runtime);

    var summary: RunResult = .{};

    for (test_paths.items) |path| {
        runTestFile(&loader, &runtime, path, allocator) catch |err| {
            summary.file_failures += 1;
            if (err != error.JavaScriptError) return err;
            writeStdout("module evaluation failed: ");
            writeStdout(path);
            const exception = qjs.c.JS_GetException(runtime.ctx);
            defer qjs.freeValue(runtime.ctx, exception);
            const text = exceptionSummaryAlloc(runtime.ctx, exception, allocator) catch try allocator.dupe(u8, "[uninitialized]");
            defer allocator.free(text);
            writeStdout("\n  ");
            writeStdout(text);
            writeStdout("\n");
        };
    }

    const opts: RunOptions = .{
        .grep = grep,
        .only_mode = registry.hasOnlyTestsInSuite(registry.root()),
    };
    try runSuite(&runtime, &loop, registry.root(), 0, allocator, &summary, opts);

    summary.duration_ns = @intCast(nanoTimestamp() - run_start_ns);
    if (print_summary) {
        writeStdout("\nResults: ");
        var buf: [320]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d} passed, {d} failed, {d} skipped", .{ summary.passed, summary.failed + summary.file_failures, summary.skipped });
        writeStdout(line);
        writeStdout(" in ");
        const duration = try formatDuration(&buf, summary.duration_ns);
        writeStdout(duration);
        writeStdout("\n");
        if (summary.skipped > 0) {
            const detail = try std.fmt.bufPrint(&buf, "Skipped: {d} declared, {d} filtered, {d} blocked", .{ summary.skipped_declared, summary.skipped_filtered, summary.skipped_blocked });
            writeStdout(detail);
            writeStdout("\n");
        }
    }
    return summary;
}

test "test runner formats durations" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("42ns", try formatDuration(&buf, 42));
    try std.testing.expectEqualStrings("1.50us", try formatDuration(&buf, 1500));
    try std.testing.expectEqualStrings("2.50ms", try formatDuration(&buf, 2_500_000));
    try std.testing.expectEqualStrings("3.25s", try formatDuration(&buf, 3_250_000_000));
}
