const std = @import("std");
const ast = @import("ast.zig");
const metadata = @import("metadata.zig");

pub const LowerError = error{
    OutOfMemory,
    UnknownFunctionOption,
} || metadata.LibrarySpec.ValidationError;

pub const LowerOptions = struct {
    search_strategy: metadata.SearchStrategy = .runtime_default,
    search_paths: []const []const u8 = &.{},
    function_options: []const FunctionOptions = &.{},
    handle_options: []const HandleOptions = &.{},
};

pub const FunctionOptions = struct {
    name: []const u8,
    return_policy: ?ReturnPolicyOption = null,
    error_policy: ?ErrorPolicyOption = null,
    buffer_policies: []const BufferPolicyOption = &.{},
};

pub const ReturnPolicyOption = union(enum) {
    direct,
    out: []const u8,
    out_many: []const []const u8,
    handle: HandleReturnPolicyOption,
};

pub const HandleReturnPolicyOption = struct {
    type_name: []const u8,
    ownership: metadata.Ownership = .owned,
};

pub const ErrorPolicyOption = union(enum) {
    status: StatusErrorPolicyOption,
    null: NullErrorPolicyOption,
    sentinel: SentinelErrorPolicyOption,
};

pub const StatusErrorPolicyOption = struct {
    ok: i64,
    code: []const u8,
    message: ?MessageSourceOption = null,
};

pub const NullErrorPolicyOption = struct {
    code: []const u8,
    message: ?MessageSourceOption = null,
};

pub const SentinelErrorPolicyOption = struct {
    value: i64,
    code: []const u8,
    message: ?MessageSourceOption = null,
};

pub const MessageSourceOption = union(enum) {
    static: []const u8,
    function: MessageFunctionSourceOption,
};

pub const MessageFunctionSourceOption = struct {
    function_name: []const u8,
    arg_name: ?[]const u8 = null,
};

pub const BufferPolicyOption = struct {
    pointer_param: []const u8,
    length_param: []const u8,
    element: metadata.BufferElementType,
    direction: metadata.BufferDirection = .in,
};

pub const HandleOptions = struct {
    type_name: []const u8,
    close_symbol: ?[]const u8 = null,
    ownership: metadata.Ownership = .owned,
    finalizer: metadata.FinalizerPolicy = .close,
};

pub const OwnedLibrarySpec = struct {
    allocator: std.mem.Allocator,
    spec: metadata.LibrarySpec,

    pub fn deinit(self: OwnedLibrarySpec) void {
        const allocator = self.allocator;
        allocator.free(self.spec.library_name);
        for (self.spec.search_paths) |path| allocator.free(path);
        allocator.free(self.spec.search_paths);

        for (self.spec.type_decls) |decl| {
            switch (decl) {
                .opaque_handle => |handle| allocator.free(handle.name),
                .pod_struct => |pod| {
                    allocator.free(pod.name);
                    for (pod.fields) |field| {
                        allocator.free(field.name);
                        freeTypeRef(allocator, field.ty);
                    }
                    allocator.free(pod.fields);
                },
            }
        }
        allocator.free(self.spec.type_decls);

        for (self.spec.handle_policies) |policy| {
            allocator.free(policy.type_name);
            if (policy.close_symbol) |close_symbol| allocator.free(close_symbol);
        }
        allocator.free(self.spec.handle_policies);

        for (self.spec.functions) |func| {
            allocator.free(func.name);
            for (func.params) |param| {
                allocator.free(param.name);
                freeTypeRef(allocator, param.ty);
            }
            allocator.free(func.params);
            freeTypeRef(allocator, func.return_type);
            freeReturnPolicy(allocator, func.return_policy);
            if (func.error_policy) |error_policy| freeErrorPolicy(allocator, error_policy);
            for (func.buffer_policies) |policy| {
                allocator.free(policy.pointer_param);
                allocator.free(policy.length_param);
            }
            allocator.free(func.buffer_policies);
        }
        allocator.free(self.spec.functions);
    }
};

pub fn lower(
    allocator: std.mem.Allocator,
    library_name: []const u8,
    unit: ast.TranslationUnit,
    options: LowerOptions,
) LowerError!OwnedLibrarySpec {
    var type_decls = std.ArrayList(metadata.TypeDecl).empty;
    defer type_decls.deinit(allocator);
    errdefer freeTypeDeclList(allocator, type_decls.items);
    var functions = std.ArrayList(metadata.FunctionSpec).empty;
    defer functions.deinit(allocator);
    errdefer freeFunctionList(allocator, functions.items);

    var used_function_options = try allocator.alloc(bool, options.function_options.len);
    defer allocator.free(used_function_options);
    @memset(used_function_options, false);

    for (unit.declarations) |decl| {
        switch (decl) {
            .type_decl => |type_decl| try type_decls.append(allocator, try lowerTypeDecl(allocator, type_decl)),
            .function => |func_decl| {
                const function_option, const option_index = findFunctionOption(options.function_options, func_decl.name);
                if (option_index) |i| used_function_options[i] = true;
                try functions.append(allocator, try lowerFunctionSpec(allocator, func_decl, function_option));
            },
        }
    }

    for (used_function_options, options.function_options) |used, option| {
        if (!used) return error.UnknownFunctionOption;
        _ = option;
    }

    const handle_policies = try lowerHandlePolicies(allocator, options.handle_options);
    errdefer freeHandlePolicies(allocator, handle_policies);

    const search_paths = try dupStringSlice(allocator, options.search_paths);
    errdefer {
        for (search_paths) |path| allocator.free(path);
        allocator.free(search_paths);
    }

    const owned = OwnedLibrarySpec{
        .allocator = allocator,
        .spec = .{
            .library_name = try allocator.dupe(u8, library_name),
            .search_strategy = options.search_strategy,
            .search_paths = search_paths,
            .type_decls = try type_decls.toOwnedSlice(allocator),
            .handle_policies = handle_policies,
            .functions = try functions.toOwnedSlice(allocator),
        },
    };
    errdefer owned.deinit();

    try owned.spec.validate();
    return owned;
}

fn lowerTypeDecl(allocator: std.mem.Allocator, decl: ast.TypeDecl) LowerError!metadata.TypeDecl {
    return switch (decl) {
        .opaque_handle => |handle| .{ .opaque_handle = .{
            .name = try allocator.dupe(u8, handle.name),
        } },
        .pod_struct => |pod| blk: {
            var fields = std.ArrayList(metadata.StructField).empty;
            defer fields.deinit(allocator);
            for (pod.fields) |field| {
                try fields.append(allocator, .{
                    .name = try allocator.dupe(u8, field.name),
                    .ty = try lowerTypeRef(allocator, field.ty),
                });
            }
            break :blk .{ .pod_struct = .{
                .name = try allocator.dupe(u8, pod.name),
                .fields = try fields.toOwnedSlice(allocator),
            } };
        },
    };
}

fn lowerFunctionSpec(
    allocator: std.mem.Allocator,
    decl: ast.FunctionDecl,
    option: ?FunctionOptions,
) LowerError!metadata.FunctionSpec {
    var params = std.ArrayList(metadata.ParamSpec).empty;
    defer params.deinit(allocator);
    errdefer freeParamSpecContents(allocator, params.items);
    for (decl.params) |param| {
        try params.append(allocator, .{
            .name = try allocator.dupe(u8, param.name),
            .ty = try lowerTypeRef(allocator, param.ty),
        });
    }

    const return_policy = if (option) |opts|
        try lowerReturnPolicy(allocator, opts.return_policy orelse .direct)
    else
        metadata.ReturnPolicy.direct;
    errdefer freeReturnPolicy(allocator, return_policy);

    const error_policy = if (option) |opts|
        if (opts.error_policy) |error_policy|
            try lowerErrorPolicy(allocator, error_policy)
        else
            null
    else
        null;
    errdefer if (error_policy) |policy| freeErrorPolicy(allocator, policy);

    const buffer_policies = if (option) |opts|
        try lowerBufferPolicies(allocator, opts.buffer_policies)
    else
        try allocator.dupe(metadata.BufferPolicy, &.{});
    errdefer freeBufferPolicies(allocator, buffer_policies);

    const name = try allocator.dupe(u8, decl.name);
    errdefer allocator.free(name);

    const params_slice = try params.toOwnedSlice(allocator);
    errdefer freeParamSpecList(allocator, params_slice);

    const return_type = try lowerTypeRef(allocator, decl.return_type);
    errdefer freeTypeRef(allocator, return_type);

    return .{
        .name = name,
        .params = params_slice,
        .return_type = return_type,
        .return_policy = return_policy,
        .error_policy = error_policy,
        .buffer_policies = buffer_policies,
    };
}

fn lowerTypeRef(allocator: std.mem.Allocator, ty: ast.TypeExpr) LowerError!metadata.TypeRef {
    if (ty.pointer_depth == 0) {
        return switch (ty.base) {
            .primitive => |primitive| .{ .primitive = lowerPrimitive(primitive) },
            .named => |name| .{ .named = try allocator.dupe(u8, name) },
        };
    }

    if (ty.pointer_depth == 1 and ty.is_const and ty.base == .primitive and ty.base.primitive == .char) {
        return .{ .pointer = .{
            .target = .cstring,
            .depth = 1,
            .is_const = true,
        } };
    }

    return .{ .pointer = .{
        .target = switch (ty.base) {
            .primitive => |primitive| .{ .primitive = lowerPrimitive(primitive) },
            .named => |name| .{ .named = try allocator.dupe(u8, name) },
        },
        .depth = ty.pointer_depth,
        .is_const = ty.is_const,
    } };
}

fn lowerPrimitive(primitive: ast.PrimitiveType) metadata.PrimitiveType {
    return @enumFromInt(@intFromEnum(primitive));
}

fn lowerReturnPolicy(allocator: std.mem.Allocator, policy: ReturnPolicyOption) LowerError!metadata.ReturnPolicy {
    return switch (policy) {
        .direct => .direct,
        .out => |name| .{ .out = try allocator.dupe(u8, name) },
        .out_many => |names| .{ .out_many = try dupStringSlice(allocator, names) },
        .handle => |handle| .{ .handle = .{
            .type_name = try allocator.dupe(u8, handle.type_name),
            .ownership = handle.ownership,
        } },
    };
}

fn lowerErrorPolicy(allocator: std.mem.Allocator, policy: ErrorPolicyOption) LowerError!?metadata.ErrorPolicy {
    return switch (policy) {
        .status => |status| .{ .status = .{
            .ok = status.ok,
            .code = try allocator.dupe(u8, status.code),
            .message = try lowerMessageSource(allocator, status.message),
        } },
        .null => |null_policy| .{ .null = .{
            .code = try allocator.dupe(u8, null_policy.code),
            .message = try lowerMessageSource(allocator, null_policy.message),
        } },
        .sentinel => |sentinel| .{ .sentinel = .{
            .value = sentinel.value,
            .code = try allocator.dupe(u8, sentinel.code),
            .message = try lowerMessageSource(allocator, sentinel.message),
        } },
    };
}

fn lowerMessageSource(allocator: std.mem.Allocator, maybe_source: ?MessageSourceOption) LowerError!?metadata.MessageSource {
    const source = maybe_source orelse return null;
    return switch (source) {
        .static => |message| .{ .static = try allocator.dupe(u8, message) },
        .function => |message_fn| .{ .function = .{
            .function_name = try allocator.dupe(u8, message_fn.function_name),
            .arg_name = if (message_fn.arg_name) |arg_name| try allocator.dupe(u8, arg_name) else null,
        } },
    };
}

fn lowerBufferPolicies(allocator: std.mem.Allocator, policies: []const BufferPolicyOption) LowerError![]const metadata.BufferPolicy {
    var out = std.ArrayList(metadata.BufferPolicy).empty;
    defer out.deinit(allocator);
    for (policies) |policy| {
        try out.append(allocator, .{
            .pointer_param = try allocator.dupe(u8, policy.pointer_param),
            .length_param = try allocator.dupe(u8, policy.length_param),
            .element = policy.element,
            .direction = policy.direction,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn lowerHandlePolicies(allocator: std.mem.Allocator, policies: []const HandleOptions) LowerError![]const metadata.HandlePolicy {
    var out = std.ArrayList(metadata.HandlePolicy).empty;
    defer out.deinit(allocator);
    for (policies) |policy| {
        try out.append(allocator, .{
            .type_name = try allocator.dupe(u8, policy.type_name),
            .close_symbol = if (policy.close_symbol) |close_symbol| try allocator.dupe(u8, close_symbol) else null,
            .ownership = policy.ownership,
            .finalizer = policy.finalizer,
        });
    }
    return out.toOwnedSlice(allocator);
}

fn dupStringSlice(allocator: std.mem.Allocator, items: []const []const u8) LowerError![]const []const u8 {
    const out = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| {
        out[i] = try allocator.dupe(u8, item);
    }
    return out;
}

fn freeTypeRef(allocator: std.mem.Allocator, ty: metadata.TypeRef) void {
    switch (ty) {
        .primitive => {},
        .named => |name| allocator.free(name),
        .pointer => |ptr| switch (ptr.target) {
            .primitive, .cstring, .raw => {},
            .named => |name| allocator.free(name),
        },
    }
}

fn freeReturnPolicy(allocator: std.mem.Allocator, policy: metadata.ReturnPolicy) void {
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

fn freeErrorPolicy(allocator: std.mem.Allocator, policy: metadata.ErrorPolicy) void {
    switch (policy) {
        .status => |status| {
            allocator.free(status.code);
            if (status.message) |message| freeMessageSource(allocator, message);
        },
        .null => |null_policy| {
            allocator.free(null_policy.code);
            if (null_policy.message) |message| freeMessageSource(allocator, message);
        },
        .sentinel => |sentinel| {
            allocator.free(sentinel.code);
            if (sentinel.message) |message| freeMessageSource(allocator, message);
        },
    }
}

fn freeMessageSource(allocator: std.mem.Allocator, source: metadata.MessageSource) void {
    switch (source) {
        .static => |message| allocator.free(message),
        .function => |message_fn| {
            allocator.free(message_fn.function_name);
            if (message_fn.arg_name) |arg_name| allocator.free(arg_name);
        },
    }
}

fn freeHandlePolicies(allocator: std.mem.Allocator, policies: []const metadata.HandlePolicy) void {
    for (policies) |policy| {
        allocator.free(policy.type_name);
        if (policy.close_symbol) |close_symbol| allocator.free(close_symbol);
    }
    allocator.free(policies);
}

fn freeBufferPolicies(allocator: std.mem.Allocator, policies: []const metadata.BufferPolicy) void {
    for (policies) |policy| {
        allocator.free(policy.pointer_param);
        allocator.free(policy.length_param);
    }
    allocator.free(policies);
}

fn freeParamSpecContents(allocator: std.mem.Allocator, params: []const metadata.ParamSpec) void {
    for (params) |param| {
        allocator.free(param.name);
        freeTypeRef(allocator, param.ty);
    }
}

fn freeParamSpecList(allocator: std.mem.Allocator, params: []const metadata.ParamSpec) void {
    freeParamSpecContents(allocator, params);
    allocator.free(params);
}

fn freeTypeDeclList(allocator: std.mem.Allocator, decls: []const metadata.TypeDecl) void {
    for (decls) |decl| {
        switch (decl) {
            .opaque_handle => |handle| allocator.free(handle.name),
            .pod_struct => |pod| {
                allocator.free(pod.name);
                for (pod.fields) |field| {
                    allocator.free(field.name);
                    freeTypeRef(allocator, field.ty);
                }
                allocator.free(pod.fields);
            },
        }
    }
}

fn freeFunctionList(allocator: std.mem.Allocator, functions: []const metadata.FunctionSpec) void {
    for (functions) |func| {
        allocator.free(func.name);
        freeParamSpecList(allocator, func.params);
        freeTypeRef(allocator, func.return_type);
        freeReturnPolicy(allocator, func.return_policy);
        if (func.error_policy) |error_policy| freeErrorPolicy(allocator, error_policy);
        freeBufferPolicies(allocator, func.buffer_policies);
    }
}

fn findFunctionOption(options: []const FunctionOptions, name: []const u8) struct { ?FunctionOptions, ?usize } {
    for (options, 0..) |option, i| {
        if (std.mem.eql(u8, option.name, name)) return .{ option, i };
    }
    return .{ null, null };
}

test "lower parses libm-style declarations into metadata" {
    const allocator = std.testing.allocator;
    const parsed = try @import("parser.zig").parse(allocator,
        \\double sqrt(double x);
        \\double pow(double x, double y);
    );
    defer parsed.unit.deinit(allocator);

    const lowered = try lower(allocator, "libm", parsed.unit, .{});
    defer lowered.deinit();

    try std.testing.expectEqual(@as(usize, 2), lowered.spec.functions.len);
    try std.testing.expectEqualStrings("sqrt", lowered.spec.functions[0].name);
    try std.testing.expectEqual(metadata.PrimitiveType.double, lowered.spec.functions[0].return_type.primitive);
}

test "lower applies handle, out-param, and error policies" {
    const allocator = std.testing.allocator;
    const parsed = try @import("parser.zig").parse(allocator,
        \\typedef struct sqlite3 sqlite3;
        \\int32_t sqlite3_open(const char* filename, sqlite3** out_db);
        \\int32_t sqlite3_close(sqlite3* db);
        \\const char* sqlite3_errmsg(sqlite3* db);
    );
    defer parsed.unit.deinit(allocator);

    const lowered = try lower(allocator, "sqlite3", parsed.unit, .{
        .function_options = &.{
            .{
                .name = "sqlite3_open",
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
        },
        .handle_options = &.{
            .{
                .type_name = "sqlite3",
                .close_symbol = "sqlite3_close",
            },
        },
    });
    defer lowered.deinit();

    try std.testing.expectEqual(@as(usize, 1), lowered.spec.type_decls.len);
    try std.testing.expectEqual(@as(usize, 1), lowered.spec.handle_policies.len);
    try std.testing.expectEqualStrings("sqlite3", lowered.spec.handle_policies[0].type_name);
    try std.testing.expectEqualStrings("out_db", lowered.spec.functions[0].return_policy.out);
    try std.testing.expectEqual(@as(u8, 2), lowered.spec.functions[0].params[1].ty.pointer.depth);
}

test "lower applies buffer policies" {
    const allocator = std.testing.allocator;
    const parsed = try @import("parser.zig").parse(allocator,
        \\uint64_t sum_bytes(const uint8_t* data, size_t len);
    );
    defer parsed.unit.deinit(allocator);

    const lowered = try lower(allocator, "sumlib", parsed.unit, .{
        .function_options = &.{
            .{
                .name = "sum_bytes",
                .buffer_policies = &.{
                    .{
                        .pointer_param = "data",
                        .length_param = "len",
                        .element = .u8,
                    },
                },
            },
        },
    });
    defer lowered.deinit();

    try std.testing.expectEqual(@as(usize, 1), lowered.spec.functions[0].buffer_policies.len);
    try std.testing.expectEqual(metadata.BufferElementType.u8, lowered.spec.functions[0].buffer_policies[0].element);
}

test "lower rejects function options that target missing functions" {
    const allocator = std.testing.allocator;
    const parsed = try @import("parser.zig").parse(allocator,
        \\double sqrt(double x);
    );
    defer parsed.unit.deinit(allocator);

    try std.testing.expectError(error.UnknownFunctionOption, lower(allocator, "libm", parsed.unit, .{
        .function_options = &.{
            .{
                .name = "pow",
                .return_policy = .direct,
            },
        },
    }));
}
