const std = @import("std");
const types = @import("types.zig");

pub const MAX_ARGS = 8;

pub const PackedArgs = struct {
    int_args: [MAX_ARGS]usize = .{0} ** MAX_ARGS,
    float_args: [MAX_ARGS]f64 = .{0.0} ** MAX_ARGS,
    is_float: [MAX_ARGS]bool = .{false} ** MAX_ARGS,
};

pub const CallResult = union {
    int_val: usize,
    float_val: f64,
    void_val: void,
};

/// Dispatch an FFI call through a comptime-generated typed trampoline.
///
/// Checks `is_float` flags to determine whether to use the all-integer or
/// all-float dispatch path. Mixed int/float argument lists are not yet
/// supported and will return an error-style zero result.
pub fn call(
    fn_ptr: *anyopaque,
    args: *const PackedArgs,
    arg_count: usize,
    return_class: types.ReturnClass,
) ?CallResult {
    if (arg_count > MAX_ARGS) {
        return null;
    }

    // Determine whether all args are float, all int, or mixed.
    var all_float = true;
    var all_int = true;
    for (0..arg_count) |i| {
        if (args.is_float[i]) {
            all_int = false;
        } else {
            all_float = false;
        }
    }

    // 0-arg case: trivially "all int"
    if (arg_count == 0) {
        all_int = true;
        all_float = false;
    }

    if (all_int) {
        return callAllInt(fn_ptr, args, arg_count, return_class);
    } else if (all_float) {
        return callAllFloat(fn_ptr, args, arg_count, return_class);
    } else {
        // Mixed int/float args not yet supported.
        return null;
    }
}

// ---------------------------------------------------------------------------
// All-integer dispatch (all args are usize)
// ---------------------------------------------------------------------------

fn callAllInt(
    fn_ptr: *anyopaque,
    args: *const PackedArgs,
    arg_count: usize,
    return_class: types.ReturnClass,
) CallResult {
    return switch (return_class) {
        .void => blk: {
            dispatchInt(void, fn_ptr, args, arg_count);
            break :blk CallResult{ .void_val = {} };
        },
        .integer => CallResult{ .int_val = dispatchInt(usize, fn_ptr, args, arg_count) },
        .float => CallResult{ .float_val = dispatchInt(f64, fn_ptr, args, arg_count) },
    };
}

fn dispatchInt(comptime RetT: type, fn_ptr: *anyopaque, args: *const PackedArgs, arg_count: usize) RetT {
    switch (arg_count) {
        inline 0...MAX_ARGS => |n| {
            const FnPtr = IntFnPtr(n, RetT);
            const typed: FnPtr = @ptrCast(@alignCast(fn_ptr));
            const call_args = intArgs(n, args);
            return @call(.auto, typed, call_args);
        },
        else => unreachable,
    }
}

/// Build a function pointer type: `*const fn(usize, usize, ...) callconv(.c) RetT`
fn IntFnPtr(comptime n: usize, comptime RetT: type) type {
    return switch (n) {
        0 => *const fn () callconv(.c) RetT,
        1 => *const fn (usize) callconv(.c) RetT,
        2 => *const fn (usize, usize) callconv(.c) RetT,
        3 => *const fn (usize, usize, usize) callconv(.c) RetT,
        4 => *const fn (usize, usize, usize, usize) callconv(.c) RetT,
        5 => *const fn (usize, usize, usize, usize, usize) callconv(.c) RetT,
        6 => *const fn (usize, usize, usize, usize, usize, usize) callconv(.c) RetT,
        7 => *const fn (usize, usize, usize, usize, usize, usize, usize) callconv(.c) RetT,
        8 => *const fn (usize, usize, usize, usize, usize, usize, usize, usize) callconv(.c) RetT,
        else => unreachable,
    };
}

fn intArgs(comptime n: usize, args: *const PackedArgs) IntArgsTuple(n) {
    var t: IntArgsTuple(n) = undefined;
    inline for (0..n) |i| {
        t[i] = args.int_args[i];
    }
    return t;
}

fn IntArgsTuple(comptime n: usize) type {
    var fields: [n]type = undefined;
    for (&fields) |*f| {
        f.* = usize;
    }
    return std.meta.Tuple(&fields);
}

// ---------------------------------------------------------------------------
// All-float dispatch (all args are f64)
// ---------------------------------------------------------------------------

fn callAllFloat(
    fn_ptr: *anyopaque,
    args: *const PackedArgs,
    arg_count: usize,
    return_class: types.ReturnClass,
) CallResult {
    return switch (return_class) {
        .void => blk: {
            dispatchFloat(void, fn_ptr, args, arg_count);
            break :blk CallResult{ .void_val = {} };
        },
        .integer => CallResult{ .int_val = dispatchFloat(usize, fn_ptr, args, arg_count) },
        .float => CallResult{ .float_val = dispatchFloat(f64, fn_ptr, args, arg_count) },
    };
}

fn dispatchFloat(comptime RetT: type, fn_ptr: *anyopaque, args: *const PackedArgs, arg_count: usize) RetT {
    switch (arg_count) {
        inline 0...MAX_ARGS => |n| {
            const FnPtr = FloatFnPtr(n, RetT);
            const typed: FnPtr = @ptrCast(@alignCast(fn_ptr));
            const call_args = floatArgs(n, args);
            return @call(.auto, typed, call_args);
        },
        else => unreachable,
    }
}

fn FloatFnPtr(comptime n: usize, comptime RetT: type) type {
    return switch (n) {
        0 => *const fn () callconv(.c) RetT,
        1 => *const fn (f64) callconv(.c) RetT,
        2 => *const fn (f64, f64) callconv(.c) RetT,
        3 => *const fn (f64, f64, f64) callconv(.c) RetT,
        4 => *const fn (f64, f64, f64, f64) callconv(.c) RetT,
        5 => *const fn (f64, f64, f64, f64, f64) callconv(.c) RetT,
        6 => *const fn (f64, f64, f64, f64, f64, f64) callconv(.c) RetT,
        7 => *const fn (f64, f64, f64, f64, f64, f64, f64) callconv(.c) RetT,
        8 => *const fn (f64, f64, f64, f64, f64, f64, f64, f64) callconv(.c) RetT,
        else => unreachable,
    };
}

fn floatArgs(comptime n: usize, args: *const PackedArgs) FloatArgsTuple(n) {
    var t: FloatArgsTuple(n) = undefined;
    inline for (0..n) |i| {
        t[i] = args.float_args[i];
    }
    return t;
}

fn FloatArgsTuple(comptime n: usize) type {
    var fields: [n]type = undefined;
    for (&fields) |*f| {
        f.* = f64;
    }
    return std.meta.Tuple(&fields);
}

// ===========================================================================
// Tests
// ===========================================================================

fn toOpaque(comptime FnT: type, f: *const FnT) *anyopaque {
    return @ptrCast(@constCast(f));
}

test "trampoline call void fn with 0 args" {
    const f = struct {
        var called = false;
        fn impl() callconv(.c) void {
            called = true;
        }
    };
    f.called = false;
    var args = PackedArgs{};
    _ = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 0, .void);
    try std.testing.expect(f.called);
}

test "trampoline call int fn with 2 args" {
    const f = struct {
        fn impl(a: usize, b: usize) callconv(.c) usize {
            return a + b;
        }
    };
    var args = PackedArgs{};
    args.int_args[0] = 3;
    args.int_args[1] = 4;
    const result = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 2, .integer).?;
    try std.testing.expectEqual(@as(usize, 7), result.int_val);
}

test "trampoline call float fn with 1 arg" {
    const f = struct {
        fn impl(a: f64) callconv(.c) f64 {
            return a * 2.0;
        }
    };
    var args = PackedArgs{};
    args.float_args[0] = 3.14;
    args.is_float[0] = true;
    const result = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 1, .float).?;
    try std.testing.expectApproxEqAbs(@as(f64, 6.28), result.float_val, 0.001);
}

test "trampoline call int fn with 0 args returning int" {
    const f = struct {
        fn impl() callconv(.c) usize {
            return 42;
        }
    };
    var args = PackedArgs{};
    const result = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 0, .integer).?;
    try std.testing.expectEqual(@as(usize, 42), result.int_val);
}

test "trampoline call float fn with 2 args" {
    const f = struct {
        fn impl(a: f64, b: f64) callconv(.c) f64 {
            return a + b;
        }
    };
    var args = PackedArgs{};
    args.float_args[0] = 1.5;
    args.float_args[1] = 2.5;
    args.is_float[0] = true;
    args.is_float[1] = true;
    const result = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 2, .float).?;
    try std.testing.expectApproxEqAbs(@as(f64, 4.0), result.float_val, 0.001);
}

test "trampoline call void fn with 1 int arg" {
    const f = struct {
        var last_val: usize = 0;
        fn impl(a: usize) callconv(.c) void {
            last_val = a;
        }
    };
    f.last_val = 0;
    var args = PackedArgs{};
    args.int_args[0] = 99;
    _ = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, 1, .void);
    try std.testing.expectEqual(@as(usize, 99), f.last_val);
}

test "trampoline mixed args returns null (unsupported)" {
    const dummy = struct {
        fn impl() callconv(.c) usize {
            return 999;
        }
    };
    var args = PackedArgs{};
    args.int_args[0] = 1;
    args.float_args[1] = 2.0;
    args.is_float[0] = false;
    args.is_float[1] = true;
    // Mixed is not supported yet — should return null without calling the function.
    const result = call(toOpaque(@TypeOf(dummy.impl), &dummy.impl), &args, 2, .integer);
    try std.testing.expect(result == null);
}

test "trampoline too many args returns null" {
    const dummy = struct {
        fn impl() callconv(.c) usize {
            return 999;
        }
    };
    var args = PackedArgs{};
    const result = call(toOpaque(@TypeOf(dummy.impl), &dummy.impl), &args, MAX_ARGS + 1, .integer);
    try std.testing.expect(result == null);
}

test "trampoline call int fn with max args" {
    const f = struct {
        fn impl(a0: usize, a1: usize, a2: usize, a3: usize, a4: usize, a5: usize, a6: usize, a7: usize) callconv(.c) usize {
            return a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
        }
    };
    var args = PackedArgs{};
    for (0..MAX_ARGS) |i| {
        args.int_args[i] = i + 1;
    }
    const result = call(toOpaque(@TypeOf(f.impl), &f.impl), &args, MAX_ARGS, .integer).?;
    // 1+2+3+4+5+6+7+8 = 36
    try std.testing.expectEqual(@as(usize, 36), result.int_val);
}
