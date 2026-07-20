const std = @import("std");
const builtin = @import("builtin");
const js_abi = @import("../../js/abi.zig");
const qjs_test = @import("../../qjs.zig");
const async_loop = @import("../../async/loop.zig");
const errors = @import("../../errors.zig");
const global_console = @import("../../global/console.zig");
const global_timer = @import("../../global/timer.zig");
const fs = @import("../../fs.zig");
const module_runtime = @import("../../module.zig");
const js_addon = @import("../../js/addon.zig");
const packages = @import("../../package.zig");
const runtime_allocator = @import("../../runtime_allocator.zig");
const hao_std = @import("../../std.zig");
const http_native = @import("../http/native.zig");
const process_native = @import("../process/native.zig");
const registry = @import("registry.zig");
const bindings = @import("native.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const Failure = struct {
    phase: []const u8,
    message: []u8,
};

pub const RunResult = struct {
    files_total: usize = 0,
    files_loaded: usize = 0,
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

pub const PackageRegistrar = *const fn (*packages.Registry) anyerror!void;

const RunOptions = struct {
    grep: ?[]const u8,
    only_mode: bool,
};

const CaseCounts = struct {
    total: usize = 0,
    selected: usize = 0,
    declared_skip: usize = 0,
    filtered: usize = 0,
};

const ReporterGlyphs = struct {
    pass: []const u8 = "✓",
    fail: []const u8 = "✕",
    skip: []const u8 = "↷",
    load: []const u8 = "→",
};

const glyphs = ReporterGlyphs{};

const ReporterMode = enum {
    plain,
    ansi,
};

var reporter_mode: ReporterMode = .plain;

const ansi = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const green = "\x1b[32m";
    const red = "\x1b[31m";
    const yellow = "\x1b[33m";
    const cyan = "\x1b[36m";
};

fn writeStdout(bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

fn getenv(key: [:0]const u8) ?[]const u8 {
    const value = c.getenv(key.ptr) orelse return null;
    return std.mem.span(value);
}

fn reporterModeFromEnv() ReporterMode {
    const value = getenv("HAO_TEST_REPORTER") orelse return .ansi;
    if (std.ascii.eqlIgnoreCase(value, "plain")) return .plain;
    if (std.ascii.eqlIgnoreCase(value, "ansi")) return .ansi;
    return .ansi;
}

fn styled(style: []const u8, text: []const u8) void {
    if (reporter_mode == .ansi) writeStdout(style);
    writeStdout(text);
    if (reporter_mode == .ansi) writeStdout(ansi.reset);
}

fn writePassGlyph() void {
    styled(ansi.green, glyphs.pass);
}

fn writeFailGlyph() void {
    styled(ansi.red, glyphs.fail);
}

fn writeSkipGlyph() void {
    styled(ansi.yellow, glyphs.skip);
}

fn writeLoadGlyph() void {
    styled(ansi.cyan, glyphs.load);
}

fn writeLabel(label: []const u8) void {
    styled(ansi.bold, label);
}

fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn selfExePathAlloc(allocator: std.mem.Allocator, io: ?std.Io) ![]u8 {
    if (builtin.os.tag == .macos) {
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

    const resolved = try std.process.executablePathAlloc(io orelse return error.ExecutablePathUnavailable, allocator);
    defer allocator.free(resolved);
    return try allocator.dupe(u8, resolved[0..resolved.len]);
}

fn exceptionSummaryAlloc(ctx: js_abi.JSContext, exception: js_abi.JSValueConst, allocator: std.mem.Allocator) ![]u8 {
    if (js_abi.jsIsException(exception)) {
        const actual = js_abi.jsGetException(ctx);
        defer js_abi.jsFreeValue(ctx, actual);
        return exceptionSummaryAlloc(ctx, actual, allocator);
    }
    if (js_abi.jsIsObject(exception)) {
        const message = js_abi.jsGetProperty(ctx, exception, "message");
        defer js_abi.jsFreeValue(ctx, message);
        if (!js_abi.jsIsUndefined(message) and !js_abi.jsIsNull(message)) {
            const text = js_abi.jsStringAlloc(ctx, message, allocator) catch null;
            if (text) |owned| {
                if (owned.len > 0) return owned;
                allocator.free(owned);
            }
        }
    }
    return js_abi.jsStringAlloc(ctx, exception, allocator);
}

fn makeFailure(ctx: js_abi.JSContext, allocator: std.mem.Allocator, phase: []const u8, exception: js_abi.JSValueConst) !Failure {
    return .{
        .phase = phase,
        .message = try exceptionSummaryAlloc(ctx, exception, allocator),
    };
}

fn runTestFile(loader: *module_runtime.Loader, runtime: *qjs_test.Runtime, path: []const u8, allocator: std.mem.Allocator) !void {
    const abs_path = try allocator.dupe(u8, path);
    defer allocator.free(abs_path);
    registry.setCurrentFilePath(abs_path);
    bindings.setCurrentTestFilePath(abs_path);
    const source = try fs.readFileAlloc(allocator, path, 10 * 1024 * 1024);
    defer allocator.free(source);
    try module_runtime.evalModuleSource(loader, runtime, source, path);

    if (qjs_test.takeUnhandledException()) |pending| {
        defer js_abi.jsFreeValue(pending.ctx, pending.value);
        _ = js_abi.jsThrow(pending.ctx, js_abi.jsDupValue(pending.ctx, pending.value));
        return error.JavaScriptError;
    }

    const probe = js_abi.jsEvalGlobal(
        runtime.ctx,
        "void 0",
        "<std:test-qjs-load-probe>",
    );
    defer js_abi.jsFreeValue(runtime.ctx, probe);
    if (js_abi.jsIsException(probe)) return error.JavaScriptError;
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
    const alloc = runtime_allocator.allocator();
    const path_z = alloc.dupeZ(u8, path) catch return false;
    defer alloc.free(path_z);
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

fn isPromiseLike(ctx: js_abi.JSContext, value: js_abi.JSValueConst) bool {
    if (!js_abi.jsIsObject(value)) return false;
    const then_val = js_abi.jsGetProperty(ctx, value, "then");
    defer js_abi.jsFreeValue(ctx, then_val);
    return js_abi.jsIsFunction(ctx, then_val);
}

fn jsGetBool(ctx: js_abi.JSContext, obj: js_abi.JSValueConst, key: [:0]const u8) bool {
    const value = js_abi.jsGetProperty(ctx, obj, key);
    defer js_abi.jsFreeValue(ctx, value);
    var result = false;
    return js_abi.jsToBool(ctx, &result, value) >= 0 and result;
}

fn awaitPromise(runtime: *qjs_test.Runtime, loop: *async_loop.Loop, promise_value: js_abi.JSValueConst, allocator: std.mem.Allocator, phase: []const u8) !?Failure {
    const ctx = runtime.ctx;
    const global = js_abi.jsGlobalObject(ctx);
    defer js_abi.jsFreeValue(ctx, global);

    const state = js_abi.jsNewObject(ctx);
    if (js_abi.jsIsException(state)) return Failure{ .phase = phase, .message = try allocator.dupe(u8, "failed to create async state") };
    defer js_abi.jsFreeValue(ctx, state);

    try js_abi.jsSetPropertyChecked(ctx, state, "settled", js_abi.jsBool(ctx, false));
    try js_abi.jsSetPropertyChecked(ctx, state, "ok", js_abi.jsBool(ctx, false));
    try js_abi.jsSetPropertyChecked(ctx, state, "error", js_abi.jsUndefined(ctx));
    try js_abi.jsSetPropertyChecked(ctx, global, "__hao_test_async_state", js_abi.jsDupValue(ctx, state));
    try js_abi.jsSetPropertyChecked(ctx, global, "__hao_test_async_promise", js_abi.jsDupValue(ctx, promise_value));

    const bootstrap =
        \\Promise.resolve(globalThis.__hao_test_async_promise).then(
        \\  () => { globalThis.__hao_test_async_state.settled = true; globalThis.__hao_test_async_state.ok = true; },
        \\  (err) => { globalThis.__hao_test_async_state.settled = true; globalThis.__hao_test_async_state.ok = false; globalThis.__hao_test_async_state.error = err; },
        \\);
    ;
    const value = js_abi.jsEvalGlobal(
        ctx,
        bootstrap,
        "<std:test>",
    );
    defer js_abi.jsFreeValue(ctx, value);
    if (js_abi.jsIsException(value)) return try makeFailure(ctx, allocator, phase, value);

    while (true) {
        if (jsGetBool(ctx, state, "settled")) {
            if (jsGetBool(ctx, state, "ok")) return null;
            const err_val = js_abi.jsGetProperty(ctx, state, "error");
            defer js_abi.jsFreeValue(ctx, err_val);
            return try makeFailure(ctx, allocator, phase, err_val);
        }

        const ran_jobs = qjs_test.executePendingJobs(runtime.rt) catch |err| {
            if (err == error.JavaScriptError) {
                const exception = js_abi.jsGetException(ctx);
                defer js_abi.jsFreeValue(ctx, exception);
                return try makeFailure(ctx, allocator, phase, exception);
            }
            return err;
        };
        if (qjs_test.takeUnhandledException()) |pending| {
            defer js_abi.jsFreeValue(pending.ctx, pending.value);
            return try makeFailure(pending.ctx, allocator, phase, pending.value);
        }
        const ran_uv = loop.runOnce() catch return error.LibuvRunFailed;
        if (qjs_test.takeUnhandledException()) |pending| {
            defer js_abi.jsFreeValue(pending.ctx, pending.value);
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

fn callFunction(runtime: *qjs_test.Runtime, loop: *async_loop.Loop, callback: js_abi.JSValueConst, file_path: []const u8, allocator: std.mem.Allocator, phase: []const u8) !?Failure {
    bindings.setCurrentTestFilePath(file_path);
    const result = js_abi.jsCall(runtime.ctx, callback, js_abi.jsUndefined(runtime.ctx), &.{});
    defer js_abi.jsFreeValue(runtime.ctx, result);
    if (js_abi.jsIsException(result)) return try makeFailure(runtime.ctx, allocator, phase, result);
    if (qjs_test.takeUnhandledException()) |pending| {
        defer js_abi.jsFreeValue(pending.ctx, pending.value);
        return try makeFailure(pending.ctx, allocator, phase, pending.value);
    }
    if (isPromiseLike(runtime.ctx, result)) {
        return try awaitPromise(runtime, loop, result, allocator, phase);
    }

    // Some native-throw/catch paths can leave a stale pending exception on the
    // QJS context even when the JS callback completed successfully. Probe with
    // a no-op eval so the runner does not leak one test's caught exception into
    // the next test case.
    const probe = js_abi.jsEvalGlobal(
        runtime.ctx,
        "void 0",
        "<std:test-probe>",
    );
    defer js_abi.jsFreeValue(runtime.ctx, probe);
    if (js_abi.jsIsException(probe)) {
        const stray = js_abi.jsGetException(runtime.ctx);
        defer js_abi.jsFreeValue(runtime.ctx, stray);
    }
    if (qjs_test.takeUnhandledException()) |pending| {
        defer js_abi.jsFreeValue(pending.ctx, pending.value);
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
    writeSkipGlyph();
    writeStdout(" ");
    writeStdout(name);
    writeStdout(" (skipped: ");
    writeStdout(reason);
    writeStdout(")\n");
}

fn printLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeStdout(line);
    writeStdout("\n");
}

fn printPathProgress(prefix: []const u8, index: usize, total: usize, path: []const u8) void {
    var buf: [1024]u8 = undefined;
    writeLoadGlyph();
    writeStdout(" ");
    const line = std.fmt.bufPrint(&buf, "{s} [{d}/{d}] {s}", .{ prefix, index, total, path }) catch return;
    writeStdout(line);
    writeStdout("\n");
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

fn countCases(suite: *registry.Suite, opts: RunOptions) CaseCounts {
    var counts: CaseCounts = .{};
    for (suite.entries.items) |entry| switch (entry) {
        .case_index => |case_index| {
            const case_ = suite.cases.items[case_index];
            counts.total += 1;
            if (caseSelected(case_, opts)) {
                counts.selected += 1;
            } else switch (caseSkipReason(case_, opts)) {
                .declared => counts.declared_skip += 1,
                .filtered => counts.filtered += 1,
                .none => {},
            }
        },
        .child => |child| {
            const child_counts = countCases(child, opts);
            counts.total += child_counts.total;
            counts.selected += child_counts.selected;
            counts.declared_skip += child_counts.declared_skip;
            counts.filtered += child_counts.filtered;
        },
    };
    return counts;
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

fn runCase(runtime: *qjs_test.Runtime, loop: *async_loop.Loop, suite: *registry.Suite, case_: registry.TestCase, depth: usize, allocator: std.mem.Allocator, summary: *RunResult) !void {
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
        writeFailGlyph();
        writeStdout(" ");
        writeStdout(case_.name);
        printDuration(duration_ns);
        writeStdout("\n");
        printFailure(depth + 1, failure);
        allocator.free(failure.message);
    } else {
        summary.passed += 1;
        writePassGlyph();
        writeStdout(" ");
        writeStdout(case_.name);
        printDuration(duration_ns);
        writeStdout("\n");
    }
}

fn runSuite(runtime: *qjs_test.Runtime, loop: *async_loop.Loop, suite: *registry.Suite, depth: usize, allocator: std.mem.Allocator, summary: *RunResult, opts: RunOptions) !void {
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
            writeFailGlyph();
            writeStdout(" beforeAll\n");
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
            writeFailGlyph();
            writeStdout(" afterAll\n");
            printFailure(depth + 2, failure);
            allocator.free(failure.message);
        }
    }
}

pub fn run(paths: [][]const u8, grep: ?[]const u8, print_summary: bool, allocator: std.mem.Allocator, io: ?std.Io) !RunResult {
    return runWithPackageRegistrar(paths, grep, print_summary, allocator, io, null);
}

pub fn runWithPackageRegistrar(
    paths: [][]const u8,
    grep: ?[]const u8,
    print_summary: bool,
    allocator: std.mem.Allocator,
    io: ?std.Io,
    package_registrar: ?PackageRegistrar,
) !RunResult {
    reporter_mode = reporterModeFromEnv();
    const run_start_ns = nanoTimestamp();

    var test_paths = try collectTestPaths(paths, allocator);
    defer {
        for (test_paths.items) |path| allocator.free(path);
        test_paths.deinit(allocator);
    }

    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();
    defer global_timer.cleanup(allocator);
    defer js_addon.cleanup();
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

    const exe_path = try selfExePathAlloc(allocator, io);
    defer allocator.free(exe_path);
    bindings.setCurrentExecutablePath(exe_path);

    try errors.registerRuntimeError(runtime.ctx, allocator);
    try global_console.register(runtime.ctx);
    try global_timer.register(runtime.ctx);

    var package_registry = packages.Registry.init(allocator);
    defer package_registry.deinit();
    try hao_std.register(&package_registry);
    if (package_registrar) |registrar| try registrar(&package_registry);

    var loader = module_runtime.Loader{
        .allocator = allocator,
        .registry = &package_registry,
    };
    loader.install(&runtime);

    var summary: RunResult = .{};
    summary.files_total = test_paths.items.len;

    if (print_summary) {
        printLine("Found {d} test file(s)", .{test_paths.items.len});
    }

    file_loop: for (test_paths.items, 0..) |path, index| {
        if (print_summary) printPathProgress("Load", index + 1, test_paths.items.len, path);
        runTestFile(&loader, &runtime, path, allocator) catch |err| {
            summary.file_failures += 1;
            if (err != error.JavaScriptError) return err;
            writeFailGlyph();
            writeStdout(" module ");
            writeStdout(path);
            const exception = js_abi.jsGetException(runtime.ctx);
            defer js_abi.jsFreeValue(runtime.ctx, exception);
            const text = if (module_runtime.lastError()) |message|
                try allocator.dupe(u8, message)
            else
                exceptionSummaryAlloc(runtime.ctx, exception, allocator) catch try allocator.dupe(u8, "[uninitialized]");
            defer allocator.free(text);
            writeStdout("\n  ");
            writeStdout(text);
            writeStdout("\n");
            continue :file_loop;
        };
        summary.files_loaded += 1;
    }

    const opts: RunOptions = .{
        .grep = grep,
        .only_mode = registry.hasOnlyTestsInSuite(registry.root()),
    };
    if (print_summary) {
        const counts = countCases(registry.root(), opts);
        if (opts.grep) |pattern| {
            printLine("Filter: grep \"{s}\"", .{pattern});
        }
        if (opts.only_mode) {
            writeStdout("Filter: only mode\n");
        }
        printLine("Run {d}/{d} test case(s)", .{ counts.selected, counts.total });
        if (counts.declared_skip > 0 or counts.filtered > 0) {
            printLine("Skip before run: {d} declared, {d} filtered", .{ counts.declared_skip, counts.filtered });
        }
        writeStdout("\n");
    }
    try runSuite(&runtime, &loop, registry.root(), 0, allocator, &summary, opts);

    summary.duration_ns = @intCast(nanoTimestamp() - run_start_ns);
    if (print_summary) {
        var buf: [320]u8 = undefined;
        writeStdout("\n");
        writeLabel("Test Files:");
        writeStdout(" ");
        const files_line = try std.fmt.bufPrint(&buf, "{d} loaded, {d} failed, {d} total", .{ summary.files_loaded, summary.file_failures, summary.files_total });
        writeStdout(files_line);
        writeStdout("\n");

        writeLabel("Tests:");
        writeStdout(" ");
        const tests_line = try std.fmt.bufPrint(&buf, "{d} passed, {d} failed, {d} skipped", .{ summary.passed, summary.failed, summary.skipped });
        writeStdout(tests_line);
        writeStdout("\n");

        writeLabel("Time:");
        writeStdout(" ");
        const duration = try formatDuration(&buf, summary.duration_ns);
        writeStdout(duration);
        writeStdout("\n");

        if (summary.skipped > 0) {
            writeLabel("Skipped:");
            writeStdout(" ");
            const detail = try std.fmt.bufPrint(&buf, "{d} declared, {d} filtered, {d} blocked", .{ summary.skipped_declared, summary.skipped_filtered, summary.skipped_blocked });
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
