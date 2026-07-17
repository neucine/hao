const std = @import("std");
const native_module = @import("../../addon/module.zig");
const qjs = @import("../../qjs.zig");
const runtime = @import("runtime.zig");

pub const specifier: [:0]const u8 = "hao:ffi/native";

const functions = [_]native_module.Function{
    .{ .name = "openNative", .function = js_openNative, .length = 2 },
    .{ .name = "callNative", .function = js_callNative, .length = 3 },
    .{ .name = "closeNative", .function = js_closeNative, .length = 1 },
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return native_module.createFunctionModule(ctx, module_name, init, &functions);
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    return native_module.bindFunctionExports(ctx, module, &functions);
}

fn js_openNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return runtime.openNative(ctx, argc, argv);
}

fn js_callNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return runtime.callNative(ctx, argc, argv);
}

fn js_closeNative(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    return runtime.closeNative(ctx, argc, argv);
}
