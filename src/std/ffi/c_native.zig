const std = @import("std");
const errors = @import("../../errors.zig");
const js_abi = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");
const parser = @import("c_abi/parser.zig");
const lower = @import("c_abi/lower.zig");
const metadata = @import("c_abi/metadata.zig");
const struct_runtime = @import("c_abi/struct_runtime.zig");
const ffi_types = @import("types.zig");
const trampoline = @import("trampoline.zig");
const Library = @import("Library.zig").Library;

pub const specifier: [:0]const u8 = "std:ffi/c/native";

const alloc = std.heap.page_allocator;

const module_functions = [_]js_abi.Function{
    .{ .name = "openNative", .callback = js_openNative, .length = 3 },
    .{ .name = "callNative", .callback = js_callNative, .length = 3 },
    .{ .name = "closeNative", .callback = js_closeNative, .length = 1 },
    .{ .name = "prepareNative", .callback = js_prepareNative, .length = 2 },
    .{ .name = null, .callback = js_prepareNative },
};
const module_function_ptrs = [_]*const js_abi.Function{
    &module_functions[0],
    &module_functions[1],
    &module_functions[2],
    &module_functions[3],
};

const Binding = struct {
    fn_ptr: *anyopaque,
    arg_types: []const ffi_types.FFIType,
    return_type: ffi_types.FFIType,
    func_index: usize,
};

const OpenCLibrary = struct {
    lib: Library,
    owned_spec: lower.OwnedLibrarySpec,
    bindings: std.StringHashMapUnmanaged(Binding) = .empty,
    closed: bool = false,

    fn deinit(self: *OpenCLibrary) void {
        var it = self.bindings.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.arg_types);
        }
        self.bindings.deinit(alloc);
        self.lib.deinit();
        self.owned_spec.deinit();
        alloc.destroy(self);
    }
};

var libraries: std.AutoHashMapUnmanaged(u32, *OpenCLibrary) = .empty;
var next_library_id: u32 = 1;

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return js_abi.createFunctionModule(std.heap.page_allocator, ctx, module_name, &module_function_ptrs);
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

fn js_prepareNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 3) orelse return ctx.api.throw_error(ctx, "invalid ffi.c arguments");
    const qjs_ctx = js_abi.borrowContext(ctx);
    return pushResult(ctx, qjs_prepareNative(qjs_ctx, qjs.undefinedValue(qjs_ctx), argc, &args));
}

fn js_openNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 3) orelse return ctx.api.throw_error(ctx, "invalid ffi.c arguments");
    const qjs_ctx = js_abi.borrowContext(ctx);
    return pushResult(ctx, qjs_openNative(qjs_ctx, qjs.undefinedValue(qjs_ctx), argc, &args));
}

fn js_callNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 3) orelse return ctx.api.throw_error(ctx, "invalid ffi.c arguments");
    const qjs_ctx = js_abi.borrowContext(ctx);
    return pushResult(ctx, qjs_callNative(qjs_ctx, qjs.undefinedValue(qjs_ctx), argc, &args));
}

fn js_closeNative(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    var args = borrowedArgs(ctx, argc, argv, 1) orelse return ctx.api.throw_error(ctx, "invalid ffi.c arguments");
    const qjs_ctx = js_abi.borrowContext(ctx);
    return pushResult(ctx, qjs_closeNative(qjs_ctx, qjs.undefinedValue(qjs_ctx), argc, &args));
}

fn qjs_prepareNative(
    ctx: ?*qjs.c.JSContext,
    _: qjs.c.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.c.JSValueConst,
) callconv(.c) qjs.c.JSValue {
    if (argc < 2) return errors.jsError(ctx, .invalid_arg, "prepareNative requires library name and declarations", null, null, null);

    const library_name = qjs.valueToStringAlloc(ctx, argv[0], alloc) catch {
        return errors.jsError(ctx, .invalid_arg, "prepareNative: invalid library name", null, null, null);
    };
    defer alloc.free(library_name);

    const declarations = qjs.valueToStringAlloc(ctx, argv[1], alloc) catch {
        return errors.jsError(ctx, .invalid_arg, "prepareNative: invalid declarations", null, null, null);
    };
    defer alloc.free(declarations);

    const parsed = parser.parse(alloc, declarations) catch |err| {
        return switch (err) {
            error.SyntaxError, error.UnsupportedFeature => errors.jsError(ctx, .invalid_arg, "prepareNative: unsupported or invalid C declarations", err, null, null),
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "prepareNative: out of memory", err, null, null),
        };
    };
    defer parsed.unit.deinit(alloc);

    const options = parseLowerOptions(ctx, if (argc >= 3) argv[2] else qjs.nullValue(ctx)) catch |err| {
        return switch (err) {
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "prepareNative: out of memory", err, null, null),
            else => errors.jsError(ctx, .invalid_arg, "prepareNative: invalid options", err, null, null),
        };
    };
    defer options.deinit();

    const lowered = lower.lower(alloc, library_name, parsed.unit, options.value) catch |err| {
        return switch (err) {
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "prepareNative: out of memory", err, null, null),
            else => errors.jsError(ctx, .invalid_arg, "prepareNative: declaration lowering failed", err, null, null),
        };
    };
    defer lowered.deinit();

    return makePreparedObject(ctx, lowered.spec) catch {
        return errors.jsError(ctx, .internal, "prepareNative: failed to build descriptor", null, null, @errorReturnTrace());
    };
}

fn qjs_openNative(
    ctx: ?*qjs.c.JSContext,
    _: qjs.c.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.c.JSValueConst,
) callconv(.c) qjs.c.JSValue {
    if (argc < 2) return errors.jsError(ctx, .invalid_arg, "openNative requires library name and declarations", null, null, null);

    const library_name = qjs.valueToStringAlloc(ctx, argv[0], alloc) catch {
        return errors.jsError(ctx, .invalid_arg, "openNative: invalid library name", null, null, null);
    };
    defer alloc.free(library_name);

    const declarations = qjs.valueToStringAlloc(ctx, argv[1], alloc) catch {
        return errors.jsError(ctx, .invalid_arg, "openNative: invalid declarations", null, null, null);
    };
    defer alloc.free(declarations);

    const parsed = parser.parse(alloc, declarations) catch |err| {
        return switch (err) {
            error.SyntaxError, error.UnsupportedFeature => errors.jsError(ctx, .invalid_arg, "openNative: unsupported or invalid C declarations", err, null, null),
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "openNative: out of memory", err, null, null),
        };
    };
    defer parsed.unit.deinit(alloc);

    const options = parseLowerOptions(ctx, if (argc >= 3) argv[2] else qjs.nullValue(ctx)) catch |err| {
        return switch (err) {
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "openNative: out of memory", err, null, null),
            else => errors.jsError(ctx, .invalid_arg, "openNative: invalid options", err, null, null),
        };
    };
    defer options.deinit();

    const owned_spec = lower.lower(alloc, library_name, parsed.unit, options.value) catch |err| {
        return switch (err) {
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "openNative: out of memory", err, null, null),
            else => errors.jsError(ctx, .invalid_arg, "openNative: declaration lowering failed", err, null, null),
        };
    };
    errdefer owned_spec.deinit();

    validateBindingsSupported(owned_spec.spec) catch |err| {
        return errors.jsError(ctx, .invalid_arg, "openNative: unsupported function policy in runtime path", err, null, null);
    };

    const lib_ptr = alloc.create(OpenCLibrary) catch return errors.jsError(ctx, .out_of_memory, "openNative: out of memory", error.OutOfMemory, null, null);
    errdefer alloc.destroy(lib_ptr);
    lib_ptr.* = .{
        .lib = openResolvedLibrary(owned_spec.spec) catch {
            return errors.jsError(ctx, .io_error, "openNative: failed to open library", null, null, null);
        },
        .owned_spec = owned_spec,
    };
    errdefer lib_ptr.deinit();

    buildBindings(lib_ptr) catch |err| {
        return switch (err) {
            error.SymbolNotFound => errors.jsError(ctx, .io_error, "openNative: symbol not found", err, null, null),
            error.UnsupportedFeature => errors.jsError(ctx, .invalid_arg, "openNative: unsupported function policy in runtime path", err, null, null),
            error.OutOfMemory => errors.jsError(ctx, .out_of_memory, "openNative: out of memory", err, null, null),
        };
    };

    const id = next_library_id;
    next_library_id += 1;
    libraries.put(alloc, id, lib_ptr) catch {
        lib_ptr.deinit();
        return errors.jsError(ctx, .out_of_memory, "openNative: out of memory", error.OutOfMemory, null, null);
    };

    return makeOpenObject(ctx, id, lib_ptr.owned_spec.spec) catch {
        return errors.jsError(ctx, .internal, "openNative: failed to build open object", null, null, @errorReturnTrace());
    };
}

fn qjs_callNative(
    ctx: ?*qjs.c.JSContext,
    _: qjs.c.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.c.JSValueConst,
) callconv(.c) qjs.c.JSValue {
    if (argc < 3) return errors.jsError(ctx, .invalid_arg, "callNative requires handle, symbol, and args", null, null, null);
    const handle_id = parseHandleId(ctx, argv[0]) orelse return qjs.exceptionValue();
    const lib_slot = libraries.getPtr(handle_id) orelse return errors.jsError(ctx, .invalid_arg, "C: invalid library handle", null, null, null);
    const lib = lib_slot.*;
    if (lib.closed) return errors.jsError(ctx, .invalid_arg, "C: library has been closed", null, null, null);

    const symbol = qjs.valueToStringAlloc(ctx, argv[1], alloc) catch return errors.jsError(ctx, .invalid_arg, "C: symbol name must be a string", null, null, null);
    defer alloc.free(symbol);
    const binding = lib.bindings.get(symbol) orelse return errors.jsError(ctx, .invalid_arg, "C: unknown symbol", null, null, null);
    if (!qjs.isArray(ctx, argv[2])) return errors.jsError(ctx, .invalid_arg, "C: arguments must be an array", null, null, null);

    const func = &lib.owned_spec.spec.functions[binding.func_index];
    const visible_arg_count = expectedVisibleArgCount(func);
    const user_arg_count = getArrayLength(ctx, argv[2]);
    if (user_arg_count != visible_arg_count) {
        return errors.jsError(ctx, .invalid_arg, "C: wrong number of arguments", null, null, null);
    }

    var pack = trampoline.PackedArgs{};
    var temp_strings = std.ArrayList([]u8).empty;
    var temp_structs = std.ArrayList(struct_runtime.TempStructArg).empty;
    defer {
        for (temp_strings.items) |buf| alloc.free(buf);
        temp_strings.deinit(alloc);
        struct_runtime.freeTempStructs(ctx, &temp_structs);
    }

    var out_ptr_value: usize = 0;
    var user_index: usize = 0;
    for (func.params, 0..) |param, i| {
        if (isHiddenOutParam(func.return_policy, param.name)) {
            pack.int_args[i] = @intFromPtr(&out_ptr_value);
            continue;
        }
        if (isHiddenBufferLengthParam(func.buffer_policies, param.name)) {
            const buffer_policy = findBufferPolicyByLengthParam(func.buffer_policies, param.name) orelse {
                return errors.jsError(ctx, .internal, "C: missing buffer policy for hidden length parameter", null, null, null);
            };
            const visible_index = visibleArgIndexForParam(func, buffer_policy.pointer_param) orelse {
                return errors.jsError(ctx, .internal, "C: failed to resolve buffer argument position", null, null, null);
            };
            const buffer_value = qjs.c.JS_GetPropertyUint32(ctx, argv[2], @intCast(visible_index));
            defer qjs.freeValue(ctx, buffer_value);
            const elem_count = marshalBufferLengthArg(ctx, buffer_value, buffer_policy) orelse return qjs.exceptionValue();
            pack.int_args[i] = elem_count;
            continue;
        }
        const value = qjs.c.JS_GetPropertyUint32(ctx, argv[2], @intCast(user_index));
        defer qjs.freeValue(ctx, value);
        if (findBufferPolicyByPointerParam(func.buffer_policies, param.name)) |buffer_policy| {
            if (marshalBufferPointerArg(ctx, value, buffer_policy, &pack, i) < 0) return qjs.exceptionValue();
        } else {
            const pod_result = struct_runtime.marshalPodStructPointerArg(ctx, value, lib.owned_spec.spec, param.ty, &pack.int_args, i, &temp_structs);
            if (pod_result < 0) return qjs.exceptionValue();
            if (pod_result > 0) {
                if (marshalArg(ctx, value, binding.arg_types[i], &pack, i, &temp_strings) < 0) return qjs.exceptionValue();
            }
        }
        user_index += 1;
    }

    const result = trampoline.call(binding.fn_ptr, &pack, binding.arg_types.len, binding.return_type.returnClass()) orelse {
        return errors.jsError(ctx, .internal, "C: mixed int/float arguments are not yet supported", null, null, @errorReturnTrace());
    };

    if (func.error_policy) |error_policy| {
        if (shouldThrowForErrorPolicy(error_policy, result, binding.return_type)) {
            const code = parseErrorCode(errorPolicyCode(error_policy));
            const message = buildErrorMessage(ctx, lib, func, error_policy, &pack, out_ptr_value) catch null;
            defer if (message) |owned| alloc.free(owned);
            const fallback = "C: native call failed";
            return errors.jsError(ctx, code, message orelse fallback, null, null, null);
        }
    }

    for (temp_structs.items) |state| {
        if (struct_runtime.applyPodStructOutputs(ctx, state) < 0) return qjs.exceptionValue();
    }

    return switch (func.return_policy) {
        .out => qjs.c.JS_NewInt64(ctx, @intCast(out_ptr_value)),
        .handle => marshalReturn(ctx, result, binding.return_type),
        .direct => marshalReturn(ctx, result, binding.return_type),
        else => errors.jsError(ctx, .invalid_arg, "C: unsupported return policy in runtime path", null, null, null),
    };
}

fn qjs_closeNative(
    ctx: ?*qjs.c.JSContext,
    _: qjs.c.JSValueConst,
    argc: c_int,
    argv: [*c]qjs.c.JSValueConst,
) callconv(.c) qjs.c.JSValue {
    if (argc < 1) return errors.jsError(ctx, .invalid_arg, "closeNative requires a handle", null, null, null);
    const handle_id = parseHandleId(ctx, argv[0]) orelse return qjs.exceptionValue();
    const lib = libraries.fetchRemove(handle_id) orelse return qjs.undefinedValue(ctx);
    lib.value.deinit();
    return qjs.undefinedValue(ctx);
}

fn makePreparedObject(ctx: ?*qjs.c.JSContext, spec: metadata.LibrarySpec) !qjs.c.JSValue {
    const out = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, out);

    const descriptor = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, descriptor);
    const policies = try makePoliciesObject(ctx, spec);
    errdefer qjs.freeValue(ctx, policies);

    for (spec.functions) |func| {
        const fn_desc = try makeFunctionDescriptor(ctx, func);
        errdefer qjs.freeValue(ctx, fn_desc);
        const key = try alloc.dupeZ(u8, func.name);
        defer alloc.free(key);
        try qjs.setProperty(ctx, descriptor, key, fn_desc);
    }

    try qjs.setProperty(ctx, out, "descriptor", descriptor);
    try qjs.setProperty(ctx, out, "policies", policies);
    return out;
}

fn makePoliciesObject(ctx: ?*qjs.c.JSContext, spec: metadata.LibrarySpec) !qjs.c.JSValue {
    const out = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, out);

    const handles = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, handles);
    for (spec.handle_policies) |policy| {
        const handle_obj = qjs.newObject(ctx);
        errdefer qjs.freeValue(ctx, handle_obj);
        if (policy.close_symbol) |close_symbol| {
            try qjs.setProperty(ctx, handle_obj, "close", qjs.createString(ctx, close_symbol));
        }
        const key = try alloc.dupeZ(u8, policy.type_name);
        defer alloc.free(key);
        try qjs.setProperty(ctx, handles, key, handle_obj);
    }

    const functions = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, functions);
    for (spec.functions) |func| {
        if (inferHandleReturnType(spec, func)) |handle_type| {
            const fn_policy = qjs.newObject(ctx);
            errdefer qjs.freeValue(ctx, fn_policy);
            const returns = qjs.newObject(ctx);
            errdefer qjs.freeValue(ctx, returns);
            try qjs.setProperty(ctx, returns, "kind", qjs.createString(ctx, "handle"));
            try qjs.setProperty(ctx, returns, "type", qjs.createString(ctx, handle_type));
            try qjs.setProperty(ctx, fn_policy, "returns", returns);
            const key = try alloc.dupeZ(u8, func.name);
            defer alloc.free(key);
            try qjs.setProperty(ctx, functions, key, fn_policy);
        }
    }

    try qjs.setProperty(ctx, out, "handles", handles);
    try qjs.setProperty(ctx, out, "functions", functions);
    return out;
}

fn makeFunctionDescriptor(ctx: ?*qjs.c.JSContext, func: metadata.FunctionSpec) !qjs.c.JSValue {
    if (!(func.return_policy == .direct or func.return_policy == .handle or func.return_policy == .out)) return error.UnsupportedFeature;
    if (func.error_policy != null) return error.UnsupportedFeature;
    if (func.buffer_policies.len != 0) return error.UnsupportedFeature;

    const obj = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, obj);

    const args_array = qjs.c.JS_NewArray(ctx);
    errdefer qjs.freeValue(ctx, args_array);

    for (func.params, 0..) |param, i| {
        const ffi_type = try mapTypeRef(param.ty);
        const ffi_text = @tagName(ffi_type);
        if (qjs.c.JS_SetPropertyUint32(ctx, args_array, @intCast(i), qjs.createString(ctx, ffi_text)) < 0) {
            return error.JavaScriptError;
        }
    }

    const return_ffi_type = try mapTypeRef(func.return_type);
    try qjs.setProperty(ctx, obj, "args", args_array);
    try qjs.setProperty(ctx, obj, "returns", qjs.createString(ctx, @tagName(return_ffi_type)));
    return obj;
}

fn buildBindings(open_lib: *OpenCLibrary) !void {
    for (open_lib.owned_spec.spec.functions, 0..) |func, func_index| {
        if (!(func.return_policy == .direct or func.return_policy == .handle or func.return_policy == .out)) {
            return error.UnsupportedFeature;
        }

        const sym_z = try alloc.dupeZ(u8, func.name);
        defer alloc.free(sym_z);
        const fn_ptr = open_lib.lib.lookupSymbol(sym_z) orelse return error.SymbolNotFound;

        const arg_types = try alloc.alloc(ffi_types.FFIType, func.params.len);
        errdefer alloc.free(arg_types);
        for (func.params, 0..) |param, i| {
            arg_types[i] = try mapTypeRef(param.ty);
        }

        try open_lib.bindings.put(alloc, try alloc.dupe(u8, func.name), .{
            .fn_ptr = fn_ptr,
            .arg_types = arg_types,
            .return_type = try mapTypeRef(func.return_type),
            .func_index = func_index,
        });
    }
}

fn validateBindingsSupported(spec: metadata.LibrarySpec) !void {
    for (spec.functions) |func| {
        if (!(func.return_policy == .direct or func.return_policy == .handle or func.return_policy == .out)) {
            return error.UnsupportedFeature;
        }
        _ = try mapTypeRef(func.return_type);
        for (func.params) |param| {
            _ = try mapTypeRef(param.ty);
        }
    }
}

fn makeOpenObject(ctx: ?*qjs.c.JSContext, handle_id: u32, spec: metadata.LibrarySpec) !qjs.c.JSValue {
    const out = qjs.newObject(ctx);
    errdefer qjs.freeValue(ctx, out);

    try qjs.setProperty(ctx, out, "handle", qjs.c.JS_NewInt64(ctx, @intCast(handle_id)));
    const symbols = qjs.c.JS_NewArray(ctx);
    errdefer qjs.freeValue(ctx, symbols);
    for (spec.functions, 0..) |func, i| {
        if (qjs.c.JS_SetPropertyUint32(ctx, symbols, @intCast(i), qjs.createString(ctx, func.name)) < 0) {
            return error.JavaScriptError;
        }
    }
    const policies = try makePoliciesObject(ctx, spec);
    errdefer qjs.freeValue(ctx, policies);

    try qjs.setProperty(ctx, out, "symbols", symbols);
    try qjs.setProperty(ctx, out, "policies", policies);
    return out;
}

fn inferHandleReturnType(spec: metadata.LibrarySpec, func: metadata.FunctionSpec) ?[]const u8 {
    return switch (func.return_policy) {
        .handle => |handle| handle.type_name,
        .out => |name| blk: {
            for (func.params) |param| {
                if (!std.mem.eql(u8, param.name, name)) continue;
                switch (param.ty) {
                    .pointer => |ptr| switch (ptr.target) {
                        .named => |type_name| {
                            if (ptr.depth != 2) break :blk null;
                            const decl = metadata.findTypeDecl(spec, type_name) orelse break :blk null;
                            if (decl.* != .opaque_handle) break :blk null;
                            break :blk type_name;
                        },
                        else => break :blk null,
                    },
                    else => break :blk null,
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn expectedVisibleArgCount(func: *const metadata.FunctionSpec) usize {
    var hidden: usize = 0;
    switch (func.return_policy) {
        .out => hidden += 1,
        else => {},
    }
    hidden += hiddenBufferLengthParamCount(func.buffer_policies);
    return func.params.len - hidden;
}

fn isHiddenOutParam(policy: metadata.ReturnPolicy, name: []const u8) bool {
    return switch (policy) {
        .out => |out_name| std.mem.eql(u8, out_name, name),
        else => false,
    };
}

fn hiddenBufferLengthParamCount(policies: []const metadata.BufferPolicy) usize {
    var count: usize = 0;
    for (policies, 0..) |policy, i| {
        var seen = false;
        for (policies[0..i]) |prior| {
            if (std.mem.eql(u8, prior.length_param, policy.length_param)) {
                seen = true;
                break;
            }
        }
        if (!seen) count += 1;
    }
    return count;
}

fn findBufferPolicyByPointerParam(
    policies: []const metadata.BufferPolicy,
    pointer_param: []const u8,
) ?metadata.BufferPolicy {
    for (policies) |policy| {
        if (std.mem.eql(u8, policy.pointer_param, pointer_param)) return policy;
    }
    return null;
}

fn findBufferPolicyByLengthParam(
    policies: []const metadata.BufferPolicy,
    length_param: []const u8,
) ?metadata.BufferPolicy {
    for (policies) |policy| {
        if (std.mem.eql(u8, policy.length_param, length_param)) return policy;
    }
    return null;
}

fn isHiddenBufferLengthParam(policies: []const metadata.BufferPolicy, name: []const u8) bool {
    return findBufferPolicyByLengthParam(policies, name) != null;
}

const ParsedLowerOptions = struct {
    allocator: std.mem.Allocator,
    value: lower.LowerOptions,
    function_options: []const lower.FunctionOptions,
    handle_options: []const lower.HandleOptions,
    search_paths: []const []const u8,

    fn deinit(self: ParsedLowerOptions) void {
        for (self.function_options) |option| {
            self.allocator.free(option.name);
            if (option.return_policy) |policy| freeReturnPolicyOption(self.allocator, policy);
            if (option.error_policy) |policy| freeErrorPolicyOption(self.allocator, policy);
            for (option.buffer_policies) |buffer| {
                self.allocator.free(buffer.pointer_param);
                self.allocator.free(buffer.length_param);
            }
            self.allocator.free(option.buffer_policies);
        }
        self.allocator.free(self.function_options);

        for (self.handle_options) |option| {
            self.allocator.free(option.type_name);
            if (option.close_symbol) |close_symbol| self.allocator.free(close_symbol);
        }
        self.allocator.free(self.handle_options);

        for (self.search_paths) |path| self.allocator.free(path);
        self.allocator.free(self.search_paths);
    }
};

fn parseLowerOptions(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) !ParsedLowerOptions {
    if (qjs.isNull(value) or qjs.isUndefined(value)) {
        const function_options = try alloc.dupe(lower.FunctionOptions, &.{});
        errdefer alloc.free(function_options);
        const handle_options = try alloc.dupe(lower.HandleOptions, &.{});
        errdefer alloc.free(handle_options);
        const search_paths = try alloc.dupe([]const u8, &.{});
        errdefer alloc.free(search_paths);
        return .{
            .allocator = alloc,
            .value = .{
                .function_options = function_options,
                .handle_options = handle_options,
                .search_paths = search_paths,
            },
            .function_options = function_options,
            .handle_options = handle_options,
            .search_paths = search_paths,
        };
    }
    if (!qjs.isObject(value)) return error.InvalidArgument;

    const function_options = try parseFunctionOptions(ctx, value);
    errdefer freeParsedFunctionOptions(function_options);
    const handle_options = try parseHandleOptions(ctx, value);
    errdefer freeParsedHandleOptions(handle_options);
    const search_strategy, const search_paths = try parseSearchOptions(ctx, value);
    errdefer {
        for (search_paths) |path| alloc.free(path);
        alloc.free(search_paths);
    }

    return .{
        .allocator = alloc,
        .value = .{
            .function_options = function_options,
            .handle_options = handle_options,
            .search_strategy = search_strategy,
            .search_paths = search_paths,
        },
        .function_options = function_options,
        .handle_options = handle_options,
        .search_paths = search_paths,
    };
}

fn parseFunctionOptions(ctx: ?*qjs.c.JSContext, options_obj: qjs.c.JSValueConst) ![]const lower.FunctionOptions {
    const functions_val = qjs.getProperty(ctx, options_obj, "functions");
    defer qjs.freeValue(ctx, functions_val);
    if (qjs.isUndefined(functions_val) or qjs.isNull(functions_val)) return try alloc.dupe(lower.FunctionOptions, &.{});
    if (!qjs.isObject(functions_val)) return error.InvalidArgument;

    const keys = try ownKeys(ctx, functions_val);
    defer freeOwnedStrings(keys);

    var out = std.ArrayList(lower.FunctionOptions).empty;
    defer out.deinit(alloc);
    errdefer freeParsedFunctionOptions(out.items);

    for (keys) |fn_name| {
        const fn_obj = getPropertyOwned(ctx, functions_val, fn_name);
        defer qjs.freeValue(ctx, fn_obj);
        if (!qjs.isObject(fn_obj)) return error.InvalidArgument;

        const returns_obj = qjs.getProperty(ctx, fn_obj, "returns");
        defer qjs.freeValue(ctx, returns_obj);
        const errors_obj = qjs.getProperty(ctx, fn_obj, "errors");
        defer qjs.freeValue(ctx, errors_obj);
        const buffers_obj = qjs.getProperty(ctx, fn_obj, "buffers");
        defer qjs.freeValue(ctx, buffers_obj);

        var return_policy: ?lower.ReturnPolicyOption = null;
        if (!qjs.isUndefined(returns_obj) and !qjs.isNull(returns_obj)) {
            if (!qjs.isObject(returns_obj)) return error.InvalidArgument;
            const out_val = qjs.getProperty(ctx, returns_obj, "out");
            defer qjs.freeValue(ctx, out_val);
            if (!qjs.isUndefined(out_val) and !qjs.isNull(out_val)) {
                const out_name = qjs.valueToStringAlloc(ctx, out_val, alloc) catch return error.InvalidArgument;
                return_policy = .{ .out = out_name };
            }

            const kind_val = qjs.getProperty(ctx, returns_obj, "kind");
            defer qjs.freeValue(ctx, kind_val);
            if (!qjs.isUndefined(kind_val) and !qjs.isNull(kind_val)) {
                const kind = qjs.valueToStringAlloc(ctx, kind_val, alloc) catch return error.InvalidArgument;
                defer alloc.free(kind);
                if (std.mem.eql(u8, kind, "handle")) {
                    const type_val = qjs.getProperty(ctx, returns_obj, "type");
                    defer qjs.freeValue(ctx, type_val);
                    const type_name = qjs.valueToStringAlloc(ctx, type_val, alloc) catch return error.InvalidArgument;
                    if (return_policy != null) freeReturnPolicyOption(alloc, return_policy.?);
                    return_policy = .{ .handle = .{ .type_name = type_name } };
                } else {
                    return error.InvalidArgument;
                }
            }
        }

        var error_policy: ?lower.ErrorPolicyOption = null;
        if (!qjs.isUndefined(errors_obj) and !qjs.isNull(errors_obj)) {
            if (!qjs.isObject(errors_obj)) return error.InvalidArgument;
            const kind_val = qjs.getProperty(ctx, errors_obj, "kind");
            defer qjs.freeValue(ctx, kind_val);
            const kind = qjs.valueToStringAlloc(ctx, kind_val, alloc) catch return error.InvalidArgument;
            defer alloc.free(kind);

            const code_val = qjs.getProperty(ctx, errors_obj, "code");
            defer qjs.freeValue(ctx, code_val);
            const code = qjs.valueToStringAlloc(ctx, code_val, alloc) catch return error.InvalidArgument;

            const message_val = qjs.getProperty(ctx, errors_obj, "message");
            defer qjs.freeValue(ctx, message_val);
            const message = if (!qjs.isUndefined(message_val) and !qjs.isNull(message_val))
                try parseMessageSourceOption(ctx, message_val)
            else
                null;

            if (std.mem.eql(u8, kind, "status")) {
                const ok_val = qjs.getProperty(ctx, errors_obj, "ok");
                defer qjs.freeValue(ctx, ok_val);
                var ok: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &ok, ok_val) < 0) return error.InvalidArgument;
                error_policy = .{ .status = .{
                    .ok = ok,
                    .code = code,
                    .message = message,
                } };
            } else if (std.mem.eql(u8, kind, "null")) {
                error_policy = .{ .null = .{
                    .code = code,
                    .message = message,
                } };
            } else if (std.mem.eql(u8, kind, "sentinel")) {
                const value_val = qjs.getProperty(ctx, errors_obj, "value");
                defer qjs.freeValue(ctx, value_val);
                var sentinel_value: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &sentinel_value, value_val) < 0) return error.InvalidArgument;
                error_policy = .{ .sentinel = .{
                    .value = sentinel_value,
                    .code = code,
                    .message = message,
                } };
            } else {
                alloc.free(code);
                if (message) |msg| freeMessageSourceOption(alloc, msg);
                return error.InvalidArgument;
            }
        }

        var buffer_policies = try alloc.dupe(lower.BufferPolicyOption, &.{});
        errdefer {
            for (buffer_policies) |buffer| {
                alloc.free(buffer.pointer_param);
                alloc.free(buffer.length_param);
            }
            alloc.free(buffer_policies);
        }
        if (!qjs.isUndefined(buffers_obj) and !qjs.isNull(buffers_obj)) {
            if (!qjs.isObject(buffers_obj)) return error.InvalidArgument;
            const buffer_keys = try ownKeys(ctx, buffers_obj);
            defer freeOwnedStrings(buffer_keys);

            var parsed_buffers = std.ArrayList(lower.BufferPolicyOption).empty;
            defer parsed_buffers.deinit(alloc);

            for (buffer_keys) |pointer_name| {
                const buffer_obj = getPropertyOwned(ctx, buffers_obj, pointer_name);
                defer qjs.freeValue(ctx, buffer_obj);
                if (!qjs.isObject(buffer_obj)) return error.InvalidArgument;

                const length_val = qjs.getProperty(ctx, buffer_obj, "length");
                defer qjs.freeValue(ctx, length_val);
                const length_param = qjs.valueToStringAlloc(ctx, length_val, alloc) catch return error.InvalidArgument;

                const element_val = qjs.getProperty(ctx, buffer_obj, "element");
                defer qjs.freeValue(ctx, element_val);
                const element_text = qjs.valueToStringAlloc(ctx, element_val, alloc) catch {
                    alloc.free(length_param);
                    return error.InvalidArgument;
                };
                defer alloc.free(element_text);

                const direction_val = qjs.getProperty(ctx, buffer_obj, "direction");
                defer qjs.freeValue(ctx, direction_val);
                const direction = if (!qjs.isUndefined(direction_val) and !qjs.isNull(direction_val)) blk: {
                    const direction_text = qjs.valueToStringAlloc(ctx, direction_val, alloc) catch {
                        alloc.free(length_param);
                        return error.InvalidArgument;
                    };
                    defer alloc.free(direction_text);
                    if (std.mem.eql(u8, direction_text, "in")) break :blk metadata.BufferDirection.in;
                    if (std.mem.eql(u8, direction_text, "out")) break :blk metadata.BufferDirection.out;
                    if (std.mem.eql(u8, direction_text, "inout")) break :blk metadata.BufferDirection.inout;
                    alloc.free(length_param);
                    return error.InvalidArgument;
                } else metadata.BufferDirection.in;

                try parsed_buffers.append(alloc, .{
                    .pointer_param = try alloc.dupe(u8, pointer_name),
                    .length_param = length_param,
                    .element = parseBufferElementType(element_text) orelse {
                        alloc.free(length_param);
                        return error.InvalidArgument;
                    },
                    .direction = direction,
                });
            }

            buffer_policies = try parsed_buffers.toOwnedSlice(alloc);
        }

        try out.append(alloc, .{
            .name = try alloc.dupe(u8, fn_name),
            .return_policy = return_policy,
            .error_policy = error_policy,
            .buffer_policies = buffer_policies,
        });
    }

    return out.toOwnedSlice(alloc);
}

fn parseHandleOptions(ctx: ?*qjs.c.JSContext, options_obj: qjs.c.JSValueConst) ![]const lower.HandleOptions {
    const handles_val = qjs.getProperty(ctx, options_obj, "handles");
    defer qjs.freeValue(ctx, handles_val);
    if (qjs.isUndefined(handles_val) or qjs.isNull(handles_val)) return try alloc.dupe(lower.HandleOptions, &.{});
    if (!qjs.isObject(handles_val)) return error.InvalidArgument;

    const keys = try ownKeys(ctx, handles_val);
    defer freeOwnedStrings(keys);

    var out = std.ArrayList(lower.HandleOptions).empty;
    defer out.deinit(alloc);
    errdefer freeParsedHandleOptions(out.items);

    for (keys) |type_name| {
        const handle_obj = getPropertyOwned(ctx, handles_val, type_name);
        defer qjs.freeValue(ctx, handle_obj);
        if (!qjs.isObject(handle_obj)) return error.InvalidArgument;

        const close_val = qjs.getProperty(ctx, handle_obj, "close");
        defer qjs.freeValue(ctx, close_val);
        const close_symbol = if (!qjs.isUndefined(close_val) and !qjs.isNull(close_val))
            qjs.valueToStringAlloc(ctx, close_val, alloc) catch return error.InvalidArgument
        else
            null;

        try out.append(alloc, .{
            .type_name = try alloc.dupe(u8, type_name),
            .close_symbol = close_symbol,
        });
    }

    return out.toOwnedSlice(alloc);
}

fn parseSearchOptions(
    ctx: ?*qjs.c.JSContext,
    options_obj: qjs.c.JSValueConst,
) !struct { metadata.SearchStrategy, []const []const u8 } {
    const search_val = qjs.getProperty(ctx, options_obj, "search");
    defer qjs.freeValue(ctx, search_val);
    if (qjs.isUndefined(search_val) or qjs.isNull(search_val)) {
        return .{ .runtime_default, try alloc.dupe([]const u8, &.{}) };
    }
    if (!qjs.isObject(search_val)) return error.InvalidArgument;

    var strategy: metadata.SearchStrategy = .runtime_default;
    const strategy_val = qjs.getProperty(ctx, search_val, "strategy");
    defer qjs.freeValue(ctx, strategy_val);
    if (!qjs.isUndefined(strategy_val) and !qjs.isNull(strategy_val)) {
        const strategy_text = qjs.valueToStringAlloc(ctx, strategy_val, alloc) catch return error.InvalidArgument;
        defer alloc.free(strategy_text);
        if (std.mem.eql(u8, strategy_text, "runtime-default")) {
            strategy = .runtime_default;
        } else if (std.mem.eql(u8, strategy_text, "relative-first")) {
            strategy = .relative_first;
        } else if (std.mem.eql(u8, strategy_text, "system-first")) {
            strategy = .system_first;
        } else {
            return error.InvalidArgument;
        }
    }

    const paths_val = qjs.getProperty(ctx, search_val, "paths");
    defer qjs.freeValue(ctx, paths_val);
    if (qjs.isUndefined(paths_val) or qjs.isNull(paths_val)) {
        return .{ strategy, try alloc.dupe([]const u8, &.{}) };
    }
    if (!qjs.isArray(ctx, paths_val)) return error.InvalidArgument;

    const len = getArrayLength(ctx, paths_val);
    const out = try alloc.alloc([]const u8, len);
    errdefer alloc.free(out);
    for (0..len) |i| {
        const path_val = qjs.c.JS_GetPropertyUint32(ctx, paths_val, @intCast(i));
        defer qjs.freeValue(ctx, path_val);
        out[i] = qjs.valueToStringAlloc(ctx, path_val, alloc) catch return error.InvalidArgument;
    }
    return .{ strategy, out };
}

fn ownKeys(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ![][]u8 {
    const keys_fn = qjs.eval(ctx, "Object.keys", "<std:ffi/c>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, keys_fn);
    if (qjs.isException(keys_fn) or !qjs.isFunction(ctx, keys_fn)) return error.InvalidArgument;

    const args = [_]qjs.c.JSValueConst{value};
    const keys = qjs.call(ctx, keys_fn, qjs.undefinedValue(ctx), &args);
    defer qjs.freeValue(ctx, keys);
    if (qjs.isException(keys) or !qjs.isObject(keys)) return error.InvalidArgument;

    const len = getArrayLength(ctx, keys);
    const out = try alloc.alloc([]u8, len);
    errdefer alloc.free(out);
    for (0..len) |i| {
        const key_val = qjs.c.JS_GetPropertyUint32(ctx, keys, @intCast(i));
        defer qjs.freeValue(ctx, key_val);
        out[i] = qjs.valueToStringAlloc(ctx, key_val, alloc) catch return error.InvalidArgument;
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

fn freeParsedFunctionOptions(options: []const lower.FunctionOptions) void {
    for (options) |option| {
        alloc.free(option.name);
        if (option.return_policy) |policy| freeReturnPolicyOption(alloc, policy);
        if (option.error_policy) |policy| freeErrorPolicyOption(alloc, policy);
        for (option.buffer_policies) |buffer| {
            alloc.free(buffer.pointer_param);
            alloc.free(buffer.length_param);
        }
        alloc.free(option.buffer_policies);
    }
}

fn parseBufferElementType(value: []const u8) ?metadata.BufferElementType {
    if (std.mem.eql(u8, value, "u8")) return .u8;
    if (std.mem.eql(u8, value, "i8")) return .i8;
    if (std.mem.eql(u8, value, "u16")) return .u16;
    if (std.mem.eql(u8, value, "i16")) return .i16;
    if (std.mem.eql(u8, value, "u32")) return .u32;
    if (std.mem.eql(u8, value, "i32")) return .i32;
    if (std.mem.eql(u8, value, "u64")) return .u64;
    if (std.mem.eql(u8, value, "i64")) return .i64;
    if (std.mem.eql(u8, value, "f32")) return .f32;
    if (std.mem.eql(u8, value, "f64")) return .f64;
    return null;
}

fn openResolvedLibrary(spec: metadata.LibrarySpec) !Library {
    if (isExplicitLibraryPath(spec.library_name)) {
        return Library.open(spec.library_name);
    }

    switch (spec.search_strategy) {
        .runtime_default => return Library.open(spec.library_name),
        .relative_first => {
            if (try tryOpenFromSearchPaths(spec)) |lib| return lib;
            return Library.open(spec.library_name);
        },
        .system_first => {
            if (Library.open(spec.library_name)) |lib| return lib else |_| {}
            if (try tryOpenFromSearchPaths(spec)) |lib| return lib;
            return Library.open(spec.library_name);
        },
    }
}

fn tryOpenFromSearchPaths(spec: metadata.LibrarySpec) !?Library {
    const resolved_name = try resolveLibraryBasename(spec.library_name);
    defer if (resolved_name.ptr != spec.library_name.ptr) alloc.free(resolved_name);

    for (spec.search_paths) |search_path| {
        const full_path = try std.fs.path.join(alloc, &.{ search_path, resolved_name });
        defer alloc.free(full_path);
        if (Library.openPath(full_path, spec.library_name)) |lib| return lib else |_| {}
    }
    return null;
}

fn isExplicitLibraryPath(name: []const u8) bool {
    for (name) |ch| {
        if (ch == '/' or ch == '.') return true;
    }
    return false;
}

fn resolveLibraryBasename(name: []const u8) ![]const u8 {
    if (isExplicitLibraryPath(name)) return name;
    const ext = if (@import("builtin").os.tag == .macos) ".dylib" else ".so";
    return std.fmt.allocPrint(alloc, "lib{s}{s}", .{ name, ext });
}

fn parseMessageSourceOption(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) !?lower.MessageSourceOption {
    if (qjs.isString(value)) {
        return .{ .static = try qjs.valueToStringAlloc(ctx, value, alloc) };
    }
    if (!qjs.isObject(value)) return error.InvalidArgument;
    const from_val = qjs.getProperty(ctx, value, "from");
    defer qjs.freeValue(ctx, from_val);
    const from = qjs.valueToStringAlloc(ctx, from_val, alloc) catch return error.InvalidArgument;
    const arg_val = qjs.getProperty(ctx, value, "arg");
    defer qjs.freeValue(ctx, arg_val);
    const arg_name = if (!qjs.isUndefined(arg_val) and !qjs.isNull(arg_val))
        qjs.valueToStringAlloc(ctx, arg_val, alloc) catch return error.InvalidArgument
    else
        null;
    return .{ .function = .{
        .function_name = from,
        .arg_name = arg_name,
    } };
}

fn freeParsedHandleOptions(options: []const lower.HandleOptions) void {
    for (options) |option| {
        alloc.free(option.type_name);
        if (option.close_symbol) |close_symbol| alloc.free(close_symbol);
    }
}

fn freeReturnPolicyOption(allocator: std.mem.Allocator, policy: lower.ReturnPolicyOption) void {
    switch (policy) {
        .direct => {},
        .out => |name| allocator.free(name),
        .out_many => |names| {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        },
        .handle => |handle| allocator.free(handle.type_name),
    }
}

fn freeErrorPolicyOption(allocator: std.mem.Allocator, policy: lower.ErrorPolicyOption) void {
    switch (policy) {
        .status => |status| {
            allocator.free(status.code);
            if (status.message) |message| freeMessageSourceOption(allocator, message);
        },
        .null => |null_policy| {
            allocator.free(null_policy.code);
            if (null_policy.message) |message| freeMessageSourceOption(allocator, message);
        },
        .sentinel => |sentinel| {
            allocator.free(sentinel.code);
            if (sentinel.message) |message| freeMessageSourceOption(allocator, message);
        },
    }
}

fn freeMessageSourceOption(allocator: std.mem.Allocator, source: lower.MessageSourceOption) void {
    switch (source) {
        .static => |message| allocator.free(message),
        .function => |message_fn| {
            allocator.free(message_fn.function_name);
            if (message_fn.arg_name) |arg_name| allocator.free(arg_name);
        },
    }
}

fn visibleArgIndexForParam(func: *const metadata.FunctionSpec, target_name: []const u8) ?usize {
    var visible_index: usize = 0;
    for (func.params) |param| {
        if (isHiddenOutParam(func.return_policy, param.name) or isHiddenBufferLengthParam(func.buffer_policies, param.name)) {
            continue;
        }
        if (std.mem.eql(u8, param.name, target_name)) return visible_index;
        visible_index += 1;
    }
    return null;
}

fn parseHandleId(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ?u32 {
    var out: i64 = 0;
    if (qjs.c.JS_ToInt64(ctx, &out, value) < 0 or out <= 0) {
        _ = errors.jsError(ctx, .invalid_arg, "C: invalid library handle", null, null, null);
        return null;
    }
    return @intCast(out);
}

fn marshalArg(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    arg_type: ffi_types.FFIType,
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
                _ = errors.jsError(ctx, .invalid_arg, "C: ptr/buffer arguments must be numeric pointer values", null, null, null);
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
            _ = errors.jsError(ctx, .invalid_arg, "C: void is not a valid argument type", null, null, null);
            return -1;
        },
    }
    return 0;
}

const TypedArrayBufferInfo = struct {
    ptr: usize,
    byte_len: usize,
};

fn marshalBufferPointerArg(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    policy: metadata.BufferPolicy,
    pack: *trampoline.PackedArgs,
    index: usize,
) c_int {
    const buffer = getTypedArrayBufferInfo(ctx, value) orelse return -1;
    const elem_size = bufferElementByteSize(policy.element);
    if (elem_size == 0 or (buffer.byte_len % elem_size) != 0) {
        _ = errors.jsError(ctx, .invalid_arg, "C: typed-array byte length must align with declared buffer element size", null, null, null);
        return -1;
    }
    pack.int_args[index] = buffer.ptr;
    return 0;
}

fn marshalBufferLengthArg(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    policy: metadata.BufferPolicy,
) ?usize {
    const buffer = getTypedArrayBufferInfo(ctx, value) orelse return null;
    const elem_size = bufferElementByteSize(policy.element);
    if (elem_size == 0 or (buffer.byte_len % elem_size) != 0) {
        _ = errors.jsError(ctx, .invalid_arg, "C: typed-array byte length must align with declared buffer element size", null, null, null);
        return null;
    }
    return buffer.byte_len / elem_size;
}

fn getTypedArrayBufferInfo(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) ?TypedArrayBufferInfo {
    var offset: usize = 0;
    var size: usize = 0;
    const buffer = qjs.c.JS_GetTypedArrayBuffer(ctx, value, &offset, &size, null);
    if (qjs.isException(buffer)) {
        qjs.freeValue(ctx, buffer);
        _ = errors.jsError(ctx, .invalid_arg, "C: buffer arguments must be typed arrays or ArrayBuffer-backed views", null, null, null);
        return null;
    }
    defer qjs.freeValue(ctx, buffer);

    var buffer_size_unused: usize = 0;
    const ptr = qjs.c.JS_GetArrayBuffer(ctx, &buffer_size_unused, buffer) orelse {
        _ = errors.jsError(ctx, .invalid_arg, "C: failed to access typed-array storage", null, null, null);
        return null;
    };
    return .{
        .ptr = @intFromPtr(ptr) + offset,
        .byte_len = size,
    };
}

fn bufferElementByteSize(element: metadata.BufferElementType) usize {
    return switch (element) {
        .u8, .i8 => 1,
        .u16, .i16 => 2,
        .u32, .i32, .f32 => 4,
        .u64, .i64, .f64 => 8,
    };
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

fn marshalReturn(ctx: ?*qjs.c.JSContext, result: trampoline.CallResult, return_type: ffi_types.FFIType) qjs.c.JSValue {
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

fn shouldThrowForErrorPolicy(
    policy: metadata.ErrorPolicy,
    result: trampoline.CallResult,
    return_type: ffi_types.FFIType,
) bool {
    return switch (policy) {
        .status => |status| @as(i64, @bitCast(result.int_val)) != status.ok,
        .null => switch (return_type) {
            .ptr, .buffer, .cstring => result.int_val == 0,
            else => false,
        },
        .sentinel => |sentinel| @as(i64, @bitCast(result.int_val)) == sentinel.value,
    };
}

fn errorPolicyCode(policy: metadata.ErrorPolicy) []const u8 {
    return switch (policy) {
        .status => |status| status.code,
        .null => |null_policy| null_policy.code,
        .sentinel => |sentinel| sentinel.code,
    };
}

fn parseErrorCode(code: []const u8) errors.ErrorCode {
    return std.meta.stringToEnum(errors.ErrorCode, code) orelse .internal;
}

fn buildErrorMessage(
    ctx: ?*qjs.c.JSContext,
    lib: *const OpenCLibrary,
    func: *const metadata.FunctionSpec,
    policy: metadata.ErrorPolicy,
    pack: *const trampoline.PackedArgs,
    out_ptr_value: usize,
) !?[]u8 {
    const source = switch (policy) {
        .status => |status| status.message,
        .null => |null_policy| null_policy.message,
        .sentinel => |sentinel| sentinel.message,
    } orelse return null;

    return switch (source) {
        .static => |message| try alloc.dupe(u8, message),
        .function => |message_fn| try invokeMessageFunction(ctx, lib, func, message_fn, pack, out_ptr_value),
    };
}

fn invokeMessageFunction(
    ctx: ?*qjs.c.JSContext,
    lib: *const OpenCLibrary,
    func: *const metadata.FunctionSpec,
    message_fn: metadata.MessageFunctionSource,
    pack: *const trampoline.PackedArgs,
    out_ptr_value: usize,
) !?[]u8 {
    _ = ctx;
    const helper = lib.bindings.get(message_fn.function_name) orelse return null;
    var helper_pack = trampoline.PackedArgs{};

    const helper_func = &lib.owned_spec.spec.functions[helper.func_index];
    if (helper_func.params.len > 1) return null;
    if (helper_func.params.len == 1) {
        const arg_name = message_fn.arg_name orelse return null;
        helper_pack.int_args[0] = try resolveMessageArg(func, arg_name, pack, out_ptr_value);
    }

    const result = trampoline.call(helper.fn_ptr, &helper_pack, helper.arg_types.len, helper.return_type.returnClass()) orelse return null;
    return switch (helper.return_type) {
        .cstring => if (result.int_val == 0)
            null
        else
            try alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrFromInt(result.int_val)))),
        else => null,
    };
}

fn resolveMessageArg(
    func: *const metadata.FunctionSpec,
    arg_name: []const u8,
    pack: *const trampoline.PackedArgs,
    out_ptr_value: usize,
) !usize {
    for (func.params, 0..) |param, i| {
        if (!std.mem.eql(u8, param.name, arg_name)) continue;
        if (isHiddenOutParam(func.return_policy, param.name)) return out_ptr_value;
        return pack.int_args[i];
    }
    return error.InvalidArgument;
}

fn mapTypeRef(ty: metadata.TypeRef) !ffi_types.FFIType {
    return switch (ty) {
        .primitive => |primitive| switch (primitive) {
            .void => .void,
            .bool => .bool,
            .char => .u8,
            .int8_t => .i8,
            .int16_t => .i16,
            .int32_t => .i32,
            .int64_t => .i64,
            .uint8_t => .u8,
            .uint16_t => .u16,
            .uint32_t => .u32,
            .uint64_t => .u64,
            .float => .f32,
            .double => .f64,
            .size_t => .u64,
        },
        .named => error.UnsupportedFeature,
        .pointer => |ptr| switch (ptr.target) {
            .cstring => if (ptr.depth == 1) .cstring else error.UnsupportedFeature,
            .primitive, .named, .raw => .ptr,
        },
    };
}
