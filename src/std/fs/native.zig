const std = @import("std");
const fs = @import("../../fs.zig");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");

pub const specifier: [:0]const u8 = "std:fs/native";

const alloc = std.heap.page_allocator;

const functions = [_]js_abi.Function{
    .{ .name = "existsSync", .callback = jsExistsSync, .length = 1 },
    .{ .name = "readFileSync", .callback = jsReadFileSync, .length = 1 },
    .{ .name = "writeFileSync", .callback = jsWriteFileSync, .length = 2 },
    .{ .name = "statSync", .callback = jsStatSync, .length = 1 },
    .{ .name = null, .callback = jsExistsSync },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
    &functions[1],
    &functions[2],
    &functions[3],
};

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &function_ptrs);
}

fn stringArg(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value, index: usize) ?[]const u8 {
    if (argc <= index) return null;
    return std.mem.span(ctx.api.to_string(ctx, argv[index]) orelse return null);
}

fn jsExistsSync(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const path = stringArg(ctx, argc, argv, 0) orelse return ctx.api.throw_type_error(ctx, "existsSync expects a path");
    return ctx.api.bool_value(ctx, if (fs.pathExists(path)) 1 else 0);
}

fn jsReadFileSync(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const path = stringArg(ctx, argc, argv, 0) orelse return ctx.api.throw_type_error(ctx, "readFileSync expects a path");
    const content = fs.readFileAlloc(alloc, path, 100 * 1024 * 1024) catch return ctx.api.throw_error(ctx, "failed to read file");
    defer alloc.free(content);
    const content_z = alloc.dupeZ(u8, content) catch return ctx.api.throw_error(ctx, "out of memory");
    defer alloc.free(content_z);
    return ctx.api.string_value(ctx, content_z.ptr);
}

fn jsWriteFileSync(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const path = stringArg(ctx, argc, argv, 0) orelse return ctx.api.throw_type_error(ctx, "writeFileSync expects a path");
    const data = stringArg(ctx, argc, argv, 1) orelse return ctx.api.throw_type_error(ctx, "writeFileSync expects data");
    fs.writeFile(path, data) catch return ctx.api.throw_error(ctx, "failed to write file");
    return ctx.api.undefined(ctx);
}

fn jsStatSync(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const path = stringArg(ctx, argc, argv, 0) orelse return ctx.api.throw_type_error(ctx, "statSync expects a path");
    const size = fs.fileSize(path) catch return ctx.api.throw_error(ctx, "failed to stat file");

    const obj = ctx.api.object_value(ctx);
    const size_value = ctx.api.float64_value(ctx, @floatFromInt(size));
    if (ctx.api.set_property(ctx, obj, "size", size_value) < 0) return ctx.api.throw_error(ctx, "failed to create stat");
    return obj;
}

test "std fs native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
