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

pub const BaseType = union(enum) {
    primitive: PrimitiveType,
    named: []const u8,
};

pub const TypeExpr = struct {
    base: BaseType,
    pointer_depth: u8 = 0,
    is_const: bool = false,
};

pub const StructField = struct {
    name: []const u8,
    ty: TypeExpr,
};

pub const ParamDecl = struct {
    name: []const u8,
    ty: TypeExpr,
};

pub const FunctionDecl = struct {
    name: []const u8,
    return_type: TypeExpr,
    params: []const ParamDecl,
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

pub const Declaration = union(enum) {
    function: FunctionDecl,
    type_decl: TypeDecl,
};

pub const TranslationUnit = struct {
    declarations: []const Declaration,

    pub fn deinit(self: TranslationUnit, allocator: std.mem.Allocator) void {
        for (self.declarations) |decl| {
            switch (decl) {
                .function => |func| {
                    freeTypeExpr(allocator, func.return_type);
                    allocator.free(func.name);
                    for (func.params) |param| {
                        freeTypeExpr(allocator, param.ty);
                        allocator.free(param.name);
                    }
                    allocator.free(func.params);
                },
                .type_decl => |type_decl| switch (type_decl) {
                    .opaque_handle => |handle| allocator.free(handle.name),
                    .pod_struct => |pod| {
                        allocator.free(pod.name);
                        for (pod.fields) |field| {
                            freeTypeExpr(allocator, field.ty);
                            allocator.free(field.name);
                        }
                        allocator.free(pod.fields);
                    },
                },
            }
        }
        allocator.free(self.declarations);
    }
};

fn freeTypeExpr(allocator: std.mem.Allocator, ty: TypeExpr) void {
    switch (ty.base) {
        .primitive => {},
        .named => |name| allocator.free(name),
    }
}
