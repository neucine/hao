const std = @import("std");
const qjs = @import("qjs.zig");

pub const Function = struct {
    name: [:0]const u8,
    function: *const fn (?*qjs.c.JSContext, qjs.c.JSValueConst, c_int, [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue,
    length: c_int = 0,
};

pub fn addFunctionExports(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef, functions: []const Function) void {
    for (functions) |exported| {
        _ = qjs.c.JS_AddModuleExport(ctx, module, exported.name.ptr);
    }
}

pub fn bindFunctionExports(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef, functions: []const Function) c_int {
    for (functions) |exported| {
        const value = qjs.c.JS_NewCFunction(ctx, exported.function, exported.name.ptr, exported.length);
        if (qjs.isException(value)) return -1;
        if (qjs.c.JS_SetModuleExport(ctx, module, exported.name.ptr, value) < 0) return -1;
    }
    return 0;
}

pub fn createFunctionModule(
    ctx: ?*qjs.c.JSContext,
    module_name: [*c]const u8,
    init: *const fn (?*qjs.c.JSContext, ?*qjs.c.JSModuleDef) callconv(.c) c_int,
    functions: []const Function,
) ?*qjs.c.JSModuleDef {
    const module = qjs.c.JS_NewCModule(ctx, module_name, init) orelse return null;
    addFunctionExports(ctx, module, functions);
    return module;
}

test "function export helper creates a module" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const funcs = [_]Function{.{
        .name = "noop",
        .function = struct {
            fn call(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, _: c_int, _: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
                return qjs.undefinedValue(ctx);
            }
        }.call,
    }};
    const module = createFunctionModule(runtime.ctx, "hao:test/native", struct {
        fn init(ctx: ?*qjs.c.JSContext, mod: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
            return bindFunctionExports(ctx, mod, &funcs);
        }
    }.init, &funcs);
    try std.testing.expect(module != null);
}
