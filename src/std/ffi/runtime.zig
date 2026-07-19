const std = @import("std");
const qjs = @import("../../qjs.zig");
const runtime_allocator = @import("../../runtime_allocator.zig");
const types = @import("types.zig");
const trampoline = @import("trampoline.zig");
const Library = @import("Library.zig").Library;

const alloc = runtime_allocator.allocator();

const Binding = struct {
    fn_ptr: *anyopaque,
    arg_types: []const types.FFIType,
    return_type: types.FFIType,
};

const OpenLibrary = struct {
    lib: Library,
    name: []u8,
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
    closed: bool = false,

    fn deinit(self: *OpenLibrary) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.arg_types);
        }
        self.bindings.deinit(alloc);
        self.lib.deinit();
        alloc.free(self.name);
        alloc.destroy(self);
    }
};

var libraries: std.AutoHashMapUnmanaged(u32, *OpenLibrary) = .empty;
var next_library_id: u32 = 1;

fn throwType(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowTypeError(ctx, message.ptr);
}

fn throwInternal(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowInternalError(ctx, message.ptr);
}

pub fn openNative(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst) qjs.c.JSValue {
    if (argc < 2) return throwType(ctx, "dlopen requires 2 arguments: library name and descriptor");

    const name = qjs.valueToStringAlloc(ctx, argv[0], alloc) catch return throwType(ctx, "dlopen: invalid library name");
    errdefer alloc.free(name);

    if (!qjs.isObject(argv[1])) return throwType(ctx, "dlopen: descriptor must be an object");

    const lib_ptr = alloc.create(OpenLibrary) catch return qjs.c.JS_ThrowOutOfMemory(ctx);
    errdefer alloc.destroy(lib_ptr);

    lib_ptr.* = .{
        .lib = Library.open(name) catch {
            return throwInternal(ctx, "dlopen: failed to open library");
        },
        .name = name,
    };

    parseDescriptor(ctx, lib_ptr, argv[1]) catch |err| {
        lib_ptr.deinit();
        return switch (err) {
            error.JavaScriptError => qjs.exceptionValue(),
            else => throwInternal(ctx, "dlopen: invalid descriptor"),
        };
    };

    const id = next_library_id;
    next_library_id += 1;
    libraries.put(alloc, id, lib_ptr) catch {
        lib_ptr.deinit();
        return qjs.c.JS_ThrowOutOfMemory(ctx);
    };
    return qjs.c.JS_NewInt64(ctx, @intCast(id));
}

pub fn callNative(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst) qjs.c.JSValue {
    if (argc < 3) return throwType(ctx, "ffi.callNative requires handle, symbol, and args");

    const handle_id = parseHandleId(ctx, argv[0]) orelse return qjs.exceptionValue();
    const lib = libraries.getPtr(handle_id) orelse return throwType(ctx, "FFI: invalid library handle");
    if (lib.*.closed) return throwType(ctx, "FFI: library has been closed");

    const symbol = qjs.valueToStringAlloc(ctx, argv[1], alloc) catch return throwType(ctx, "FFI: symbol name must be a string");
    defer alloc.free(symbol);

    const binding = lib.*.bindings.get(symbol) orelse return throwType(ctx, "FFI: unknown symbol");
    if (!qjs.isArray(ctx, argv[2])) return throwType(ctx, "FFI: arguments must be an array");

    const arg_count = getArrayLength(ctx, argv[2]);
    if (arg_count != binding.arg_types.len) {
        return throwType(ctx, "FFI: wrong number of arguments");
    }

    var pack = trampoline.PackedArgs{};
    var temp_strings = std.ArrayList([]u8).empty;
    defer {
        for (temp_strings.items) |buf| alloc.free(buf);
        temp_strings.deinit(alloc);
    }

    for (binding.arg_types, 0..) |arg_type, i| {
        const value = qjs.c.JS_GetPropertyUint32(ctx, argv[2], @intCast(i));
        defer qjs.freeValue(ctx, value);
        if (marshalArg(ctx, value, arg_type, &pack, i, &temp_strings) < 0) return qjs.exceptionValue();
    }

    const result = trampoline.call(binding.fn_ptr, &pack, binding.arg_types.len, binding.return_type.returnClass()) orelse {
        return throwInternal(ctx, "FFI: mixed int/float arguments are not yet supported");
    };
    return marshalReturn(ctx, result, binding.return_type);
}

pub fn closeNative(ctx: ?*qjs.c.JSContext, argc: c_int, argv: [*c]qjs.c.JSValueConst) qjs.c.JSValue {
    if (argc < 1) return throwType(ctx, "ffi.closeNative requires a handle");
    const handle_id = parseHandleId(ctx, argv[0]) orelse return qjs.exceptionValue();
    const lib = libraries.getPtr(handle_id) orelse return qjs.undefinedValue(ctx);
    if (!lib.*.closed) {
        lib.*.closed = true;
        lib.*.lib.close();
    }
    return qjs.undefinedValue(ctx);
}

fn parseDescriptor(ctx: ?*qjs.c.JSContext, lib: *OpenLibrary, descriptor: qjs.c.JSValueConst) !void {
    const keys = try ownKeys(ctx, descriptor);
    defer freeOwnedStrings(keys);

    for (keys) |symbol| {
        const desc = getPropertyOwned(ctx, descriptor, symbol);
        defer qjs.freeValue(ctx, desc);
        if (!qjs.isObject(desc)) return error.JavaScriptError;

        const args_val = qjs.getProperty(ctx, desc, "args");
        defer qjs.freeValue(ctx, args_val);
        if (!qjs.isArray(ctx, args_val)) {
            _ = throwType(ctx, "dlopen: descriptor args must be an array");
            return error.JavaScriptError;
        }

        const return_val = qjs.getProperty(ctx, desc, "returns");
        defer qjs.freeValue(ctx, return_val);
        const return_type = parseType(ctx, return_val) orelse {
            _ = throwType(ctx, "dlopen: invalid return type");
            return error.JavaScriptError;
        };

        const arg_len = getArrayLength(ctx, args_val);
        const arg_types = try alloc.alloc(types.FFIType, arg_len);
        errdefer alloc.free(arg_types);
        for (0..arg_len) |i| {
            const arg = qjs.c.JS_GetPropertyUint32(ctx, args_val, @intCast(i));
            defer qjs.freeValue(ctx, arg);
            arg_types[i] = parseType(ctx, arg) orelse {
                _ = throwType(ctx, "dlopen: invalid argument type");
                return error.JavaScriptError;
            };
        }

        const sym_z = try alloc.dupeZ(u8, symbol);
        defer alloc.free(sym_z);
        const fn_ptr = lib.lib.lookupSymbol(sym_z) orelse {
            _ = throwInternal(ctx, "dlopen: symbol not found");
            return error.JavaScriptError;
        };

        try lib.bindings.put(alloc, try alloc.dupe(u8, symbol), .{
            .fn_ptr = fn_ptr,
            .arg_types = arg_types,
            .return_type = return_type,
        });
    }
}

fn ownKeys(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ![][]u8 {
    const keys_fn = qjs.eval(ctx, "Object.keys", "<std:ffi>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, keys_fn);
    if (qjs.isException(keys_fn) or !qjs.isFunction(ctx, keys_fn)) return error.JavaScriptError;

    const args = [_]qjs.c.JSValueConst{value};
    const keys = qjs.call(ctx, keys_fn, qjs.undefinedValue(ctx), &args);
    defer qjs.freeValue(ctx, keys);
    if (qjs.isException(keys) or !qjs.isObject(keys)) return error.JavaScriptError;

    const len = getArrayLength(ctx, keys);
    const out = try alloc.alloc([]u8, len);
    errdefer alloc.free(out);
    for (0..len) |i| {
        const key_val = qjs.c.JS_GetPropertyUint32(ctx, keys, @intCast(i));
        defer qjs.freeValue(ctx, key_val);
        out[i] = qjs.valueToStringAlloc(ctx, key_val, alloc) catch return error.JavaScriptError;
    }
    return out;
}

fn freeOwnedStrings(items: [][]u8) void {
    for (items) |item| alloc.free(item);
    alloc.free(items);
}

fn getPropertyOwned(ctx: ?*qjs.c.JSContext, object: qjs.c.JSValueConst, key: []const u8) qjs.c.JSValue {
    const z = alloc.dupeZ(u8, key) catch return qjs.undefinedValue(ctx);
    defer alloc.free(z);
    return qjs.getProperty(ctx, object, z);
}

fn getArrayLength(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) usize {
    const len_val = qjs.getProperty(ctx, value, "length");
    defer qjs.freeValue(ctx, len_val);
    var len_u32: u32 = 0;
    if (qjs.c.JS_ToUint32(ctx, &len_u32, len_val) < 0) return 0;
    return len_u32;
}

fn parseType(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ?types.FFIType {
    const text = qjs.valueToStringAlloc(ctx, value, alloc) catch return null;
    defer alloc.free(text);
    return std.meta.stringToEnum(types.FFIType, text);
}

fn parseHandleId(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ?u32 {
    var out: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &out, value) < 0 or out <= 0) {
        _ = throwType(ctx, "FFI: invalid library handle");
        return null;
    }
    return @intCast(out);
}

fn marshalArg(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    arg_type: types.FFIType,
    pack: *trampoline.PackedArgs,
    index: usize,
    temp_strings: *std.ArrayList([]u8),
) c_int {
    switch (arg_type) {
        .bool => pack.int_args[index] = if (qjs.c.JS_ToBool(ctx, value) == 1) 1 else 0,
        .i8, .i16, .i32, .i64 => {
            var out: i64 = 0;
            if (qjs.c.JS_ToInt64(ctx, &out, value) < 0) return -1;
            pack.int_args[index] = @bitCast(out);
        },
        .u8, .u16, .u32, .u64 => {
            const out = parseUnsignedArg(ctx, value) orelse return -1;
            pack.int_args[index] = out;
        },
        .ptr, .buffer => {
            const out = parseUnsignedArg(ctx, value) orelse {
                _ = throwType(ctx, "FFI: ptr/buffer arguments must be numeric pointer values");
                return -1;
            };
            pack.int_args[index] = out;
        },
        .f32, .f64 => {
            var out: f64 = 0;
            if (qjs.c.JS_ToFloat64(ctx, &out, value) < 0) return -1;
            pack.float_args[index] = out;
            pack.is_float[index] = true;
        },
        .cstring => {
            const text = qjs.valueToStringAlloc(ctx, value, alloc) catch return -1;
            const z = alloc.dupeZ(u8, text) catch {
                alloc.free(text);
                return -1;
            };
            alloc.free(text);
            temp_strings.append(alloc, z[0 .. z.len + 1]) catch {
                alloc.free(z);
                return -1;
            };
            pack.int_args[index] = @intFromPtr(z.ptr);
        },
        .void => {
            _ = throwType(ctx, "FFI: void is not a valid argument type");
            return -1;
        },
    }
    return 0;
}

fn parseUnsignedArg(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ?usize {
    var out: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &out, value) == 0) {
        if (out < 0) return null;
        return @intCast(out);
    }

    const text = qjs.valueToStringAlloc(ctx, value, alloc) catch return null;
    defer alloc.free(text);
    const trimmed = std.mem.trimEnd(u8, text, "n");
    if (trimmed.len == 0) return null;
    return std.fmt.parseUnsigned(usize, trimmed, 10) catch null;
}

fn marshalReturn(ctx: ?*qjs.c.JSContext, result: trampoline.CallResult, return_type: types.FFIType) qjs.c.JSValue {
    return switch (return_type) {
        .void => qjs.undefinedValue(ctx),
        .bool => qjs.boolValue(ctx, result.int_val != 0),
        .i8 => qjs.c.JS_NewInt32(ctx, @as(i8, @truncate(@as(i64, @bitCast(result.int_val))))),
        .i16 => qjs.c.JS_NewInt32(ctx, @as(i16, @truncate(@as(i64, @bitCast(result.int_val))))),
        .i32 => qjs.c.JS_NewInt32(ctx, @as(i32, @truncate(@as(i64, @bitCast(result.int_val))))),
        .i64 => qjs.c.JS_NewInt64(ctx, @as(i64, @bitCast(result.int_val))),
        .u8 => qjs.c.JS_NewInt32(ctx, @as(u8, @truncate(result.int_val))),
        .u16 => qjs.c.JS_NewInt32(ctx, @as(u16, @truncate(result.int_val))),
        .u32 => qjs.c.JS_NewInt64(ctx, @as(u32, @truncate(result.int_val))),
        .u64, .ptr, .buffer => qjs.c.JS_NewInt64(ctx, @intCast(result.int_val)),
        .f32, .f64 => qjs.c.JS_NewFloat64(ctx, result.float_val),
        .cstring => blk: {
            if (result.int_val == 0) break :blk qjs.nullValue(ctx);
            const raw: [*:0]const u8 = @ptrFromInt(result.int_val);
            break :blk qjs.createString(ctx, std.mem.span(raw));
        },
    };
}
