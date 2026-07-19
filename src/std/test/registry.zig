const std = @import("std");
const js_abi = @import("../../js/abi.zig");

pub const HookKind = enum {
    before_all,
    after_all,
    before_each,
    after_each,
};

pub const TestMode = enum {
    normal,
    skip,
    only,
};

pub const TestCase = struct {
    name: []const u8,
    callback: js_abi.JSValue,
    mode: TestMode,
    file_path: []const u8,
};

pub const Hook = struct {
    callback: js_abi.JSValue,
    file_path: []const u8,
};

pub const SuiteEntry = union(enum) {
    case_index: usize,
    child: *Suite,
};

pub const Suite = struct {
    name: []const u8,
    parent: ?*Suite,
    entries: std.ArrayList(SuiteEntry),
    children: std.ArrayList(*Suite),
    cases: std.ArrayList(TestCase),
    before_all: std.ArrayList(Hook),
    after_all: std.ArrayList(Hook),
    before_each: std.ArrayList(Hook),
    after_each: std.ArrayList(Hook),
};

var gpa: ?std.mem.Allocator = null;
var root_suite_ptr: ?*Suite = null;
var current_suite_ptr: ?*Suite = null;
var current_file_path: []const u8 = "";

fn allocator() std.mem.Allocator {
    return gpa orelse @panic("qjs test registry not initialized");
}

fn initSuite(name: []const u8, parent: ?*Suite) !*Suite {
    const alloc = allocator();
    const suite = try alloc.create(Suite);
    suite.* = .{
        .name = try alloc.dupe(u8, name),
        .parent = parent,
        .entries = .empty,
        .children = .empty,
        .cases = .empty,
        .before_all = .empty,
        .after_all = .empty,
        .before_each = .empty,
        .after_each = .empty,
    };
    return suite;
}

pub fn init(alloc: std.mem.Allocator) !void {
    gpa = alloc;
    const root_suite = try initSuite("", null);
    root_suite_ptr = root_suite;
    current_suite_ptr = root_suite;
    current_file_path = "";
}

pub fn ensureInit(alloc: std.mem.Allocator) !void {
    if (root_suite_ptr != null) return;
    try init(alloc);
}

fn deinitSuite(ctx: js_abi.JSContext, suite: *Suite) void {
    const alloc = allocator();
    for (suite.children.items) |child| deinitSuite(ctx, child);
    suite.entries.deinit(alloc);
    suite.children.deinit(alloc);

    for (suite.cases.items) |case_| {
        js_abi.jsFreeValue(ctx, case_.callback);
        alloc.free(case_.name);
        alloc.free(case_.file_path);
    }
    suite.cases.deinit(alloc);

    for (suite.before_all.items) |hook| {
        js_abi.jsFreeValue(ctx, hook.callback);
        alloc.free(hook.file_path);
    }
    for (suite.after_all.items) |hook| {
        js_abi.jsFreeValue(ctx, hook.callback);
        alloc.free(hook.file_path);
    }
    for (suite.before_each.items) |hook| {
        js_abi.jsFreeValue(ctx, hook.callback);
        alloc.free(hook.file_path);
    }
    for (suite.after_each.items) |hook| {
        js_abi.jsFreeValue(ctx, hook.callback);
        alloc.free(hook.file_path);
    }
    suite.before_all.deinit(alloc);
    suite.after_all.deinit(alloc);
    suite.before_each.deinit(alloc);
    suite.after_each.deinit(alloc);

    alloc.free(suite.name);
    alloc.destroy(suite);
}

pub fn deinit(ctx: js_abi.JSContext) void {
    if (root_suite_ptr) |root_suite| deinitSuite(ctx, root_suite);
    root_suite_ptr = null;
    current_suite_ptr = null;
    gpa = null;
    current_file_path = "";
}

pub fn setCurrentFilePath(path: []const u8) void {
    current_file_path = path;
}

pub fn root() *Suite {
    return root_suite_ptr orelse @panic("qjs test registry not initialized");
}

pub fn pushSuite(name: []const u8) !void {
    const parent = current_suite_ptr orelse return error.InvalidState;
    const child = try initSuite(name, parent);
    try parent.children.append(allocator(), child);
    try parent.entries.append(allocator(), .{ .child = child });
    current_suite_ptr = child;
}

pub fn popSuite() !void {
    const current = current_suite_ptr orelse return error.InvalidState;
    current_suite_ptr = current.parent orelse return error.InvalidState;
}

pub fn registerTest(ctx: js_abi.JSContext, name: []const u8, callback: js_abi.JSValueConst, mode: TestMode) !void {
    const current = current_suite_ptr orelse return error.InvalidState;
    try current.cases.append(allocator(), .{
        .name = try allocator().dupe(u8, name),
        .callback = js_abi.jsDupValue(ctx, callback),
        .mode = mode,
        .file_path = try allocator().dupe(u8, current_file_path),
    });
    try current.entries.append(allocator(), .{ .case_index = current.cases.items.len - 1 });
}

pub fn registerHook(ctx: js_abi.JSContext, kind: HookKind, callback: js_abi.JSValueConst) !void {
    const current = current_suite_ptr orelse return error.InvalidState;
    const hook: Hook = .{
        .callback = js_abi.jsDupValue(ctx, callback),
        .file_path = try allocator().dupe(u8, current_file_path),
    };
    switch (kind) {
        .before_all => try current.before_all.append(allocator(), hook),
        .after_all => try current.after_all.append(allocator(), hook),
        .before_each => try current.before_each.append(allocator(), hook),
        .after_each => try current.after_each.append(allocator(), hook),
    }
}

pub fn hasOnlyTestsInSuite(suite: *Suite) bool {
    for (suite.cases.items) |case_| {
        if (case_.mode == .only) return true;
    }
    for (suite.children.items) |child| {
        if (hasOnlyTestsInSuite(child)) return true;
    }
    return false;
}
