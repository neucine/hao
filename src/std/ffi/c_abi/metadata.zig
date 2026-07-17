const std = @import("std");

pub const PrimitiveType = enum {
    void,
    bool,
    char,
    int8_t,
    int16_t,
    int32_t,
    int64_t,
    uint8_t,
    uint16_t,
    uint32_t,
    uint64_t,
    float,
    double,
    size_t,
};

pub const PointerTarget = union(enum) {
    primitive: PrimitiveType,
    named: []const u8,
    cstring,
    raw,
};

pub const PointerType = struct {
    target: PointerTarget,
    depth: u8 = 1,
    is_const: bool = false,
};

pub const TypeRef = union(enum) {
    primitive: PrimitiveType,
    named: []const u8,
    pointer: PointerType,
};

pub const TypeDecl = union(enum) {
    opaque_handle: OpaqueHandleDecl,
    pod_struct: PodStructDecl,
};

pub const OpaqueHandleDecl = struct {
    name: []const u8,
};

pub const PodStructDecl = struct {
    name: []const u8,
    fields: []const StructField,
};

pub const StructField = struct {
    name: []const u8,
    ty: TypeRef,
};

pub const ParamSpec = struct {
    name: []const u8,
    ty: TypeRef,
};

pub const ReturnPolicy = union(enum) {
    direct,
    out: []const u8,
    out_many: []const []const u8,
    handle: HandleReturnPolicy,
};

pub const HandleReturnPolicy = struct {
    type_name: []const u8,
    ownership: Ownership = .owned,
};

pub const Ownership = enum {
    owned,
    borrowed,
    manual,
};

pub const FinalizerPolicy = enum {
    none,
    close,
};

pub const HandlePolicy = struct {
    type_name: []const u8,
    close_symbol: ?[]const u8 = null,
    ownership: Ownership = .owned,
    finalizer: FinalizerPolicy = .close,
};

pub const BufferElementType = enum {
    u8,
    i8,
    u16,
    i16,
    u32,
    i32,
    u64,
    i64,
    f32,
    f64,
};

pub const BufferPolicy = struct {
    pointer_param: []const u8,
    length_param: []const u8,
    element: BufferElementType,
    direction: BufferDirection = .in,
};

pub const BufferDirection = enum {
    in,
    out,
    inout,
};

pub const MessageSource = union(enum) {
    static: []const u8,
    function: MessageFunctionSource,
};

pub const MessageFunctionSource = struct {
    function_name: []const u8,
    arg_name: ?[]const u8 = null,
};

pub const ErrorPolicy = union(enum) {
    status: StatusErrorPolicy,
    null: NullErrorPolicy,
    sentinel: SentinelErrorPolicy,
};

pub const StatusErrorPolicy = struct {
    ok: i64,
    code: []const u8,
    message: ?MessageSource = null,
};

pub const NullErrorPolicy = struct {
    code: []const u8,
    message: ?MessageSource = null,
};

pub const SentinelErrorPolicy = struct {
    value: i64,
    code: []const u8,
    message: ?MessageSource = null,
};

pub const FunctionSpec = struct {
    name: []const u8,
    params: []const ParamSpec,
    return_type: TypeRef,
    return_policy: ReturnPolicy = .direct,
    error_policy: ?ErrorPolicy = null,
    buffer_policies: []const BufferPolicy = &.{},
};

pub const SearchStrategy = enum {
    runtime_default,
    relative_first,
    system_first,
};

pub const LibrarySpec = struct {
    library_name: []const u8,
    search_strategy: SearchStrategy = .runtime_default,
    search_paths: []const []const u8 = &.{},
    type_decls: []const TypeDecl = &.{},
    handle_policies: []const HandlePolicy = &.{},
    functions: []const FunctionSpec,

    pub const ValidationError = error{
        EmptyLibraryName,
        MissingFunctionName,
        DuplicateFunctionName,
        MissingParamName,
        DuplicateParamName,
        DuplicateTypeName,
        DuplicateHandlePolicy,
        UnknownNamedType,
        UnknownHandleType,
        HandleTypeNotOpaque,
        UnknownCloseFunction,
        InvalidCloseFunction,
        UnknownOutParam,
        OutParamNotPointer,
        UnknownBufferPointerParam,
        UnknownBufferLengthParam,
        BufferPointerNotPointerLike,
        BufferLengthNotSizeLike,
        UnknownMessageFunction,
        UnknownMessageArg,
    };

    pub fn validate(self: LibrarySpec) ValidationError!void {
        if (self.library_name.len == 0) return error.EmptyLibraryName;

        for (self.type_decls, 0..) |decl, i| {
            const name = typeDeclName(decl);
            if (name.len == 0) return error.UnknownNamedType;
            for (self.type_decls[i + 1 ..]) |other| {
                if (std.mem.eql(u8, name, typeDeclName(other))) return error.DuplicateTypeName;
            }
            try validateTypeDecl(self, decl);
        }

        for (self.handle_policies, 0..) |policy, i| {
            try validateHandlePolicy(self, policy);
            for (self.handle_policies[i + 1 ..]) |other| {
                if (std.mem.eql(u8, policy.type_name, other.type_name)) return error.DuplicateHandlePolicy;
            }
        }

        for (self.functions, 0..) |func, i| {
            if (func.name.len == 0) return error.MissingFunctionName;
            for (self.functions[i + 1 ..]) |other| {
                if (std.mem.eql(u8, func.name, other.name)) return error.DuplicateFunctionName;
            }
            try validateFunction(self, func);
        }
    }
};

fn validateTypeDecl(spec: LibrarySpec, decl: TypeDecl) LibrarySpec.ValidationError!void {
    switch (decl) {
        .opaque_handle => {},
        .pod_struct => |pod| {
            for (pod.fields) |field| {
                if (field.name.len == 0) return error.MissingParamName;
                try validateTypeRef(spec, field.ty);
            }
        },
    }
}

fn validateHandlePolicy(spec: LibrarySpec, policy: HandlePolicy) LibrarySpec.ValidationError!void {
    const decl = findTypeDecl(spec, policy.type_name) orelse return error.UnknownHandleType;
    switch (decl.*) {
        .opaque_handle => {},
        else => return error.HandleTypeNotOpaque,
    }

    if (policy.close_symbol) |close_symbol| {
        const close_fn = findFunction(spec, close_symbol) orelse return error.UnknownCloseFunction;
        if (close_fn.params.len == 0) return error.InvalidCloseFunction;
        if (!isPointerToNamedType(close_fn.params[0].ty, policy.type_name)) return error.InvalidCloseFunction;
    }
}

fn validateFunction(spec: LibrarySpec, func: FunctionSpec) LibrarySpec.ValidationError!void {
    try validateTypeRef(spec, func.return_type);

    for (func.params, 0..) |param, i| {
        if (param.name.len == 0) return error.MissingParamName;
        for (func.params[i + 1 ..]) |other| {
            if (std.mem.eql(u8, param.name, other.name)) return error.DuplicateParamName;
        }
        try validateTypeRef(spec, param.ty);
    }

    switch (func.return_policy) {
        .direct => {},
        .out => |name| try validateOutParam(func, name),
        .out_many => |names| for (names) |name| try validateOutParam(func, name),
        .handle => |handle| {
            const decl = findTypeDecl(spec, handle.type_name) orelse return error.UnknownHandleType;
            switch (decl.*) {
                .opaque_handle => {},
                else => return error.HandleTypeNotOpaque,
            }
        },
    }

    for (func.buffer_policies) |policy| {
        const pointer_param = findParam(func, policy.pointer_param) orelse return error.UnknownBufferPointerParam;
        const length_param = findParam(func, policy.length_param) orelse return error.UnknownBufferLengthParam;
        if (!isPointerLike(pointer_param.ty)) return error.BufferPointerNotPointerLike;
        if (!isSizeLike(length_param.ty)) return error.BufferLengthNotSizeLike;
    }

    if (func.error_policy) |policy| {
        switch (policy) {
            .status => |status| try validateMessageSource(spec, func, status.message),
            .null => |null_policy| try validateMessageSource(spec, func, null_policy.message),
            .sentinel => |sentinel| try validateMessageSource(spec, func, sentinel.message),
        }
    }
}

fn validateMessageSource(
    spec: LibrarySpec,
    func: FunctionSpec,
    maybe_source: ?MessageSource,
) LibrarySpec.ValidationError!void {
    const source = maybe_source orelse return;
    switch (source) {
        .static => {},
        .function => |message_fn| {
            _ = findFunction(spec, message_fn.function_name) orelse return error.UnknownMessageFunction;
            if (message_fn.arg_name) |arg_name| {
                _ = findParam(func, arg_name) orelse return error.UnknownMessageArg;
            }
        },
    }
}

fn validateOutParam(func: FunctionSpec, name: []const u8) LibrarySpec.ValidationError!void {
    const param = findParam(func, name) orelse return error.UnknownOutParam;
    if (!isPointerLike(param.ty)) return error.OutParamNotPointer;
}

fn validateTypeRef(spec: LibrarySpec, ty: TypeRef) LibrarySpec.ValidationError!void {
    switch (ty) {
        .primitive => {},
        .pointer => |ptr| switch (ptr.target) {
            .primitive, .cstring, .raw => {},
            .named => |name| {
                if (findTypeDecl(spec, name) == null) return error.UnknownNamedType;
            },
        },
        .named => |name| {
            if (findTypeDecl(spec, name) == null) return error.UnknownNamedType;
        },
    }
}

fn findParam(func: FunctionSpec, name: []const u8) ?ParamSpec {
    for (func.params) |param| {
        if (std.mem.eql(u8, param.name, name)) return param;
    }
    return null;
}

fn typeDeclName(decl: TypeDecl) []const u8 {
    return switch (decl) {
        .opaque_handle => |handle| handle.name,
        .pod_struct => |pod| pod.name,
    };
}

fn isPointerLike(ty: TypeRef) bool {
    return switch (ty) {
        .pointer => true,
        else => false,
    };
}

fn isPointerToNamedType(ty: TypeRef, name: []const u8) bool {
    return switch (ty) {
        .pointer => |ptr| switch (ptr.target) {
            .named => |target| ptr.depth == 1 and std.mem.eql(u8, target, name),
            else => false,
        },
        else => false,
    };
}

fn isSizeLike(ty: TypeRef) bool {
    return switch (ty) {
        .primitive => |primitive| primitive == .size_t,
        else => false,
    };
}

fn findTypeDeclInSlice(type_decls: []const TypeDecl, name: []const u8) ?*const TypeDecl {
    for (type_decls) |*decl| {
        if (std.mem.eql(u8, typeDeclName(decl.*), name)) return decl;
    }
    return null;
}

fn findFunctionInSlice(functions: []const FunctionSpec, name: []const u8) ?*const FunctionSpec {
    for (functions) |*func| {
        if (std.mem.eql(u8, func.name, name)) return func;
    }
    return null;
}

pub fn findTypeDecl(spec: LibrarySpec, name: []const u8) ?*const TypeDecl {
    return findTypeDeclInSlice(spec.type_decls, name);
}

pub fn findFunction(spec: LibrarySpec, name: []const u8) ?*const FunctionSpec {
    return findFunctionInSlice(spec.functions, name);
}

test "metadata validates libm-style direct calls" {
    const functions = [_]FunctionSpec{
        .{
            .name = "sqrt",
            .params = &.{
                .{ .name = "x", .ty = .{ .primitive = .double } },
            },
            .return_type = .{ .primitive = .double },
        },
        .{
            .name = "pow",
            .params = &.{
                .{ .name = "x", .ty = .{ .primitive = .double } },
                .{ .name = "y", .ty = .{ .primitive = .double } },
            },
            .return_type = .{ .primitive = .double },
        },
    };

    const spec = LibrarySpec{
        .library_name = "libm",
        .functions = &functions,
    };

    try spec.validate();
}

test "metadata validates opaque handle api with out-param lifting and close policy" {
    const type_decls = [_]TypeDecl{
        .{ .opaque_handle = .{ .name = "sqlite3" } },
    };
    const handle_policies = [_]HandlePolicy{
        .{
            .type_name = "sqlite3",
            .close_symbol = "sqlite3_close",
            .ownership = .owned,
            .finalizer = .close,
        },
    };
    const functions = [_]FunctionSpec{
        .{
            .name = "sqlite3_open",
            .params = &.{
                .{ .name = "filename", .ty = .{ .pointer = .{ .target = .cstring, .depth = 1, .is_const = true } } },
                .{ .name = "out_db", .ty = .{ .pointer = .{ .target = .{ .named = "sqlite3" }, .depth = 2 } } },
            },
            .return_type = .{ .primitive = .int32_t },
            .return_policy = .{ .out = "out_db" },
            .error_policy = .{ .status = .{
                .ok = 0,
                .code = "io_error",
                .message = .{ .function = .{
                    .function_name = "sqlite3_errmsg",
                    .arg_name = "out_db",
                } },
            } },
        },
        .{
            .name = "sqlite3_close",
            .params = &.{
                .{ .name = "db", .ty = .{ .pointer = .{ .target = .{ .named = "sqlite3" }, .depth = 1 } } },
            },
            .return_type = .{ .primitive = .int32_t },
        },
        .{
            .name = "sqlite3_errmsg",
            .params = &.{
                .{ .name = "db", .ty = .{ .pointer = .{ .target = .{ .named = "sqlite3" }, .depth = 1 } } },
            },
            .return_type = .{ .pointer = .{ .target = .cstring, .depth = 1 } },
        },
    };

    const spec = LibrarySpec{
        .library_name = "sqlite3",
        .type_decls = &type_decls,
        .handle_policies = &handle_policies,
        .functions = &functions,
    };

    try spec.validate();
}

test "metadata validates pointer-plus-length buffer policy" {
    const functions = [_]FunctionSpec{
        .{
            .name = "sum_bytes",
            .params = &.{
                .{ .name = "data", .ty = .{ .pointer = .{ .target = .{ .primitive = .uint8_t }, .depth = 1 } } },
                .{ .name = "len", .ty = .{ .primitive = .size_t } },
            },
            .return_type = .{ .primitive = .uint64_t },
            .buffer_policies = &.{
                .{
                    .pointer_param = "data",
                    .length_param = "len",
                    .element = .u8,
                    .direction = .in,
                },
            },
        },
    };

    const spec = LibrarySpec{
        .library_name = "sumlib",
        .functions = &functions,
    };

    try spec.validate();
}

test "metadata rejects unknown out parameter" {
    const functions = [_]FunctionSpec{
        .{
            .name = "foo_create",
            .params = &.{
                .{ .name = "out_foo", .ty = .{ .pointer = .{ .target = .raw, .depth = 1 } } },
            },
            .return_type = .{ .primitive = .int32_t },
            .return_policy = .{ .out = "missing" },
        },
    };

    const spec = LibrarySpec{
        .library_name = "foo",
        .functions = &functions,
    };

    try std.testing.expectError(error.UnknownOutParam, spec.validate());
}

test "metadata rejects handle policy for non-opaque type" {
    const type_decls = [_]TypeDecl{
        .{ .pod_struct = .{
            .name = "Point",
            .fields = &.{
                .{ .name = "x", .ty = .{ .primitive = .double } },
                .{ .name = "y", .ty = .{ .primitive = .double } },
            },
        } },
    };
    const handle_policies = [_]HandlePolicy{
        .{
            .type_name = "Point",
            .close_symbol = null,
        },
    };
    const functions = [_]FunctionSpec{
        .{
            .name = "norm",
            .params = &.{
                .{ .name = "p", .ty = .{ .named = "Point" } },
            },
            .return_type = .{ .primitive = .double },
        },
    };

    const spec = LibrarySpec{
        .library_name = "geom",
        .type_decls = &type_decls,
        .handle_policies = &handle_policies,
        .functions = &functions,
    };

    try std.testing.expectError(error.HandleTypeNotOpaque, spec.validate());
}

test "metadata rejects buffer policy with non-size length param" {
    const functions = [_]FunctionSpec{
        .{
            .name = "sum_bytes",
            .params = &.{
                .{ .name = "data", .ty = .{ .pointer = .{ .target = .{ .primitive = .uint8_t }, .depth = 1 } } },
                .{ .name = "len", .ty = .{ .primitive = .uint32_t } },
            },
            .return_type = .{ .primitive = .uint64_t },
            .buffer_policies = &.{
                .{
                    .pointer_param = "data",
                    .length_param = "len",
                    .element = .u8,
                },
            },
        },
    };

    const spec = LibrarySpec{
        .library_name = "sumlib",
        .functions = &functions,
    };

    try std.testing.expectError(error.BufferLengthNotSizeLike, spec.validate());
}
