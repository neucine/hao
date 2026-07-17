const std = @import("std");
const native_module = @import("../native_module.zig");
const qjs = @import("../qjs.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

pub const specifier: [:0]const u8 = "hao:process/native";

const alloc = std.heap.page_allocator;

const functions = [_]native_module.Function{
    .{ .name = "getEnvNative", .function = jsGetEnvNative, .length = 1 },
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return native_module.createFunctionModule(ctx, module_name, init, &functions);
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    return native_module.bindFunctionExports(ctx, module, &functions);
}

fn jsGetEnvNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    if (argc < 1) return qjs.exceptionValue();
    const name = qjs.valueToStringAlloc(ctx, argv[0], alloc) catch return qjs.exceptionValue();
    defer alloc.free(name);
    const name_z = alloc.dupeZ(u8, name) catch return qjs.exceptionValue();
    defer alloc.free(name_z);

    const value = c.getenv(name_z.ptr) orelse return qjs.nullValue(ctx);
    return qjs.createString(ctx, std.mem.span(value));
}

test "hao process native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
