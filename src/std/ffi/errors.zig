const qjs = @import("../../qjs.zig");

pub const ErrorCode = enum {
    invalid_arg,
    invalid_state,
    io_error,
    out_of_memory,
    internal,
};

pub fn jsError(
    ctx: ?*qjs.c.JSContext,
    code: ErrorCode,
    message: []const u8,
    _: anytype,
    _: anytype,
    _: anytype,
) qjs.c.JSValue {
    const message_z = std.heap.page_allocator.dupeZ(u8, message) catch return qjs.c.JS_ThrowOutOfMemory(ctx);
    defer std.heap.page_allocator.free(message_z);
    return switch (code) {
        .invalid_arg, .invalid_state => qjs.c.JS_ThrowTypeError(ctx, message_z.ptr),
        .out_of_memory => qjs.c.JS_ThrowOutOfMemory(ctx),
        .io_error, .internal => qjs.c.JS_ThrowInternalError(ctx, message_z.ptr),
    };
}

const std = @import("std");
