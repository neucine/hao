const std = @import("std");
const fs = @import("../../fs.zig");
const native_module = @import("../../js/module.zig");
const qjs = @import("../../qjs.zig");

pub const specifier: [:0]const u8 = "hao:fs/native";

const alloc = std.heap.page_allocator;

const functions = [_]native_module.Function{
    .{ .name = "existsSync", .function = jsExistsSync, .length = 1 },
    .{ .name = "readFileSync", .function = jsReadFileSync, .length = 1 },
    .{ .name = "writeFileSync", .function = jsWriteFileSync, .length = 2 },
    .{ .name = "statSync", .function = jsStatSync, .length = 1 },
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return native_module.createFunctionModule(ctx, module_name, init, &functions);
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    return native_module.bindFunctionExports(ctx, module, &functions);
}

fn stringArg(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst, index: usize) ?[]u8 {
    if (argc <= index) return null;
    return qjs.valueToStringAlloc(ctx, argv[index], alloc) catch null;
}

fn jsExistsSync(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const path = stringArg(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    defer alloc.free(path);
    return qjs.boolValue(ctx, fs.pathExists(path));
}

fn jsReadFileSync(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const path = stringArg(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    defer alloc.free(path);
    const content = fs.readFileAlloc(alloc, path, 100 * 1024 * 1024) catch return qjs.exceptionValue();
    defer alloc.free(content);
    return qjs.createString(ctx, content);
}

fn jsWriteFileSync(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const path = stringArg(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    defer alloc.free(path);
    const data = stringArg(ctx, argc, argv, 1) orelse return qjs.exceptionValue();
    defer alloc.free(data);
    fs.writeFile(path, data) catch return qjs.exceptionValue();
    return qjs.undefinedValue(ctx);
}

fn jsStatSync(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const path = stringArg(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    defer alloc.free(path);
    const size = fs.fileSize(path) catch return qjs.exceptionValue();

    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj)) return obj;
    qjs.setProperty(ctx, obj, "size", qjs.c.JS_NewInt64(ctx, @intCast(size))) catch return qjs.exceptionValue();
    return obj;
}

test "hao fs native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
