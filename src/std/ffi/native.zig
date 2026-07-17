const std = @import("std");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");
const runtime = @import("runtime.zig");

pub const specifier: [:0]const u8 = "hao:ffi/native";

const functions = [_]js_abi.Function{
    .{ .name = "openNative", .callback = js_openNative, .length = 2 },
    .{ .name = "callNative", .callback = js_callNative, .length = 3 },
    .{ .name = "closeNative", .callback = js_closeNative, .length = 1 },
    .{ .name = null, .callback = js_closeNative },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
    &functions[1],
    &functions[2],
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &function_ptrs);
}

fn borrowedArgs(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value, comptime max_args: usize) ?[max_args]qjs.c.JSValueConst {
    if (argc > max_args) return null;
    var out: [max_args]qjs.c.JSValueConst = undefined;
    for (0..@as(usize, @intCast(@max(argc, 0)))) |index| {
        out[index] = js_abi.borrowValue(ctx, argv[index]) orelse return null;
    }
    return out;
}

fn pushResult(ctx: *js_abi.Context, result: qjs.c.JSValue) js_abi.Value {
    return js_abi.adoptValue(ctx, result);
}

fn js_openNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 2) orelse return ctx.api.throw_error(ctx, "invalid ffi arguments");
    return pushResult(ctx, runtime.openNative(js_abi.borrowContext(ctx), argc, &args));
}

fn js_callNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 3) orelse return ctx.api.throw_error(ctx, "invalid ffi arguments");
    return pushResult(ctx, runtime.callNative(js_abi.borrowContext(ctx), argc, &args));
}

fn js_closeNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 1) orelse return ctx.api.throw_error(ctx, "invalid ffi arguments");
    return pushResult(ctx, runtime.closeNative(js_abi.borrowContext(ctx), argc, &args));
}
