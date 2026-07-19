const std = @import("std");
const errors = @import("../../../errors.zig");
const qjs = @import("../../../qjs.zig");
const runtime_allocator = @import("../../../runtime_allocator.zig");
const metadata = @import("metadata.zig");

const alloc = runtime_allocator.allocator();

pub const TempStructArg = struct {
    spec: metadata.LibrarySpec,
    decl: *const metadata.PodStructDecl,
    js_value: qjs.c.JSValue,
    storage: []align(8) u8,
};

const PrimitiveLayout = struct {
    size: usize,
    alignment: usize,
};

const PodStructLayout = struct {
    size: usize,
    alignment: usize,
};

const LayoutError = error{UnsupportedFeature};

pub fn podStructPointerDecl(spec: metadata.LibrarySpec, ty: metadata.TypeRef) ?*const metadata.PodStructDecl {
    return switch (ty) {
        .pointer => |ptr| switch (ptr.target) {
            .named => |name| blk: {
                if (ptr.depth != 1) break :blk null;
                const decl = metadata.findTypeDecl(spec, name) orelse break :blk null;
                switch (decl.*) {
                    .pod_struct => |*pod| break :blk pod,
                    else => break :blk null,
                }
            },
            else => null,
        },
        else => null,
    };
}

pub fn marshalPodStructPointerArg(
    ctx: ?*qjs.c.JSContext,
    value: qjs.c.JSValueConst,
    spec: metadata.LibrarySpec,
    ty: metadata.TypeRef,
    int_args: []usize,
    index: usize,
    temp_structs: *std.ArrayList(TempStructArg),
) c_int {
    const pod = podStructPointerDecl(spec, ty) orelse return 1;
    if (!qjs.isObject(value) or qjs.isNull(value)) return 1;

    const layout = computePodStructLayout(spec, pod) catch {
        _ = errors.jsError(ctx, .invalid_arg, "C: unsupported POD struct layout for runtime marshaling", null, null, null);
        return -1;
    };
    _ = layout.alignment;
    const storage = alloc.alignedAlloc(u8, .@"8", layout.size) catch {
        _ = errors.jsError(ctx, .out_of_memory, "C: failed to allocate POD struct staging storage", error.OutOfMemory, null, null);
        return -1;
    };
    @memset(storage, 0);
    errdefer alloc.free(storage);

    if (writePodStructFromObject(ctx, spec, pod, storage, value) < 0) return -1;

    const duped = qjs.dupValue(ctx, value);
    temp_structs.append(alloc, .{
        .spec = spec,
        .decl = pod,
        .js_value = duped,
        .storage = storage,
    }) catch {
        qjs.freeValue(ctx, duped);
        _ = errors.jsError(ctx, .out_of_memory, "C: failed to retain POD struct state", error.OutOfMemory, null, null);
        return -1;
    };

    int_args[index] = @intFromPtr(storage.ptr);
    return 0;
}

pub fn applyPodStructOutputs(ctx: ?*qjs.c.JSContext, state: TempStructArg) c_int {
    for (state.decl.fields) |field| {
        const offset = podStructFieldOffset(state.spec, state.decl, field.name) orelse {
            _ = errors.jsError(ctx, .internal, "C: missing POD struct field offset", null, null, null);
            return -1;
        };
        const js_value = readPodStructField(ctx, state.spec, field.ty, state.storage, offset) catch return -1;
        const key = alloc.dupeZ(u8, field.name) catch {
            qjs.freeValue(ctx, js_value);
            _ = errors.jsError(ctx, .out_of_memory, "C: failed to allocate POD struct field key", error.OutOfMemory, null, null);
            return -1;
        };
        defer alloc.free(key);
        qjs.setProperty(ctx, state.js_value, key, js_value) catch {
            qjs.freeValue(ctx, js_value);
            _ = errors.jsError(ctx, .internal, "C: failed to write POD struct field back to JS object", null, null, @errorReturnTrace());
            return -1;
        };
    }
    return 0;
}

pub fn freeTempStructs(ctx: ?*qjs.c.JSContext, temp_structs: *std.ArrayList(TempStructArg)) void {
    for (temp_structs.items) |state| {
        qjs.freeValue(ctx, state.js_value);
        alloc.free(state.storage);
    }
    temp_structs.deinit(alloc);
}

fn computePodStructLayout(spec: metadata.LibrarySpec, pod: *const metadata.PodStructDecl) LayoutError!PodStructLayout {
    var offset: usize = 0;
    var max_align: usize = 1;
    for (pod.fields) |field| {
        const layout = try layoutForTypeRef(spec, field.ty);
        offset = std.mem.alignForward(usize, offset, layout.alignment);
        offset += layout.size;
        if (layout.alignment > max_align) max_align = layout.alignment;
    }
    return .{
        .size = std.mem.alignForward(usize, offset, max_align),
        .alignment = max_align,
    };
}

fn podStructFieldOffset(spec: metadata.LibrarySpec, pod: *const metadata.PodStructDecl, field_name: []const u8) ?usize {
    var offset: usize = 0;
    for (pod.fields) |field| {
        const layout = layoutForTypeRef(spec, field.ty) catch return null;
        offset = std.mem.alignForward(usize, offset, layout.alignment);
        if (std.mem.eql(u8, field.name, field_name)) return offset;
        offset += layout.size;
    }
    return null;
}

fn layoutForTypeRef(spec: metadata.LibrarySpec, ty: metadata.TypeRef) LayoutError!PrimitiveLayout {
    return switch (ty) {
        .primitive => |primitive| switch (primitive) {
            .void => error.UnsupportedFeature,
            .bool, .char, .int8_t, .uint8_t => .{ .size = 1, .alignment = 1 },
            .int16_t, .uint16_t => .{ .size = 2, .alignment = 2 },
            .int32_t, .uint32_t, .float => .{ .size = 4, .alignment = 4 },
            .int64_t, .uint64_t, .double, .size_t => .{ .size = 8, .alignment = 8 },
        },
        .named => |name| blk: {
            const decl = metadata.findTypeDecl(spec, name) orelse return error.UnsupportedFeature;
            switch (decl.*) {
                .pod_struct => |*pod| {
                    const layout = try computePodStructLayout(spec, pod);
                    break :blk .{ .size = layout.size, .alignment = layout.alignment };
                },
                else => return error.UnsupportedFeature,
            }
        },
        else => error.UnsupportedFeature,
    };
}

fn writePodStructFromObject(
    ctx: ?*qjs.c.JSContext,
    spec: metadata.LibrarySpec,
    pod: *const metadata.PodStructDecl,
    storage: []align(8) u8,
    value: qjs.c.JSValueConst,
) c_int {
    return writePodStructFromObjectAtOffset(ctx, spec, pod, storage, 0, value);
}

fn writePodStructFromObjectAtOffset(
    ctx: ?*qjs.c.JSContext,
    spec: metadata.LibrarySpec,
    pod: *const metadata.PodStructDecl,
    storage: []align(8) u8,
    base_offset: usize,
    value: qjs.c.JSValueConst,
) c_int {
    for (pod.fields) |field| {
        const offset = podStructFieldOffset(spec, pod, field.name) orelse {
            _ = errors.jsError(ctx, .internal, "C: missing POD struct field offset", null, null, null);
            return -1;
        };
        const key = alloc.dupeZ(u8, field.name) catch {
            _ = errors.jsError(ctx, .out_of_memory, "C: failed to allocate POD struct field key", error.OutOfMemory, null, null);
            return -1;
        };
        defer alloc.free(key);
        const field_value = qjs.getProperty(ctx, value, key);
        defer qjs.freeValue(ctx, field_value);
        if (qjs.isUndefined(field_value)) {
            _ = errors.jsError(ctx, .invalid_arg, "C: missing POD struct field", null, null, null);
            return -1;
        }
        if (writePodStructField(ctx, spec, field.ty, storage, base_offset + offset, field_value) < 0) return -1;
    }
    return 0;
}

fn writePodStructField(
    ctx: ?*qjs.c.JSContext,
    spec: metadata.LibrarySpec,
    ty: metadata.TypeRef,
    storage: []align(8) u8,
    offset: usize,
    value: qjs.c.JSValueConst,
) c_int {
    return switch (ty) {
        .primitive => |primitive| switch (primitive) {
            .bool => blk: {
                storage[offset] = if (qjs.c.JS_ToBool(ctx, value) == 1) 1 else 0;
                break :blk 0;
            },
            .char, .uint8_t => blk: {
                const out = parseUnsignedArg(ctx, value) orelse return -1;
                storage[offset] = @truncate(out);
                break :blk 0;
            },
            .int8_t => blk: {
                var out: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &out, value) < 0) return -1;
                storage[offset] = @bitCast(@as(i8, @truncate(out)));
                break :blk 0;
            },
            .int16_t => blk: {
                var out: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &out, value) < 0) return -1;
                std.mem.writeInt(i16, storage[offset..][0..2], @truncate(out), .little);
                break :blk 0;
            },
            .uint16_t => blk: {
                const out = parseUnsignedArg(ctx, value) orelse return -1;
                std.mem.writeInt(u16, storage[offset..][0..2], @truncate(out), .little);
                break :blk 0;
            },
            .int32_t => blk: {
                var out: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &out, value) < 0) return -1;
                std.mem.writeInt(i32, storage[offset..][0..4], @truncate(out), .little);
                break :blk 0;
            },
            .uint32_t => blk: {
                const out = parseUnsignedArg(ctx, value) orelse return -1;
                std.mem.writeInt(u32, storage[offset..][0..4], @truncate(out), .little);
                break :blk 0;
            },
            .int64_t => blk: {
                var out: i64 = 0;
                if (qjs.c.JS_ToInt64(ctx, &out, value) < 0) return -1;
                std.mem.writeInt(i64, storage[offset..][0..8], out, .little);
                break :blk 0;
            },
            .uint64_t, .size_t => blk: {
                const out = parseUnsignedArg(ctx, value) orelse return -1;
                std.mem.writeInt(u64, storage[offset..][0..8], @intCast(out), .little);
                break :blk 0;
            },
            .float => blk: {
                var out: f64 = 0;
                if (qjs.c.JS_ToFloat64(ctx, &out, value) < 0) return -1;
                const casted: f32 = @floatCast(out);
                std.mem.writeInt(u32, storage[offset..][0..4], @bitCast(casted), .little);
                break :blk 0;
            },
            .double => blk: {
                var out: f64 = 0;
                if (qjs.c.JS_ToFloat64(ctx, &out, value) < 0) return -1;
                std.mem.writeInt(u64, storage[offset..][0..8], @bitCast(out), .little);
                break :blk 0;
            },
            .void => {
                _ = errors.jsError(ctx, .invalid_arg, "C: void is not a valid POD struct field type", null, null, null);
                return -1;
            },
        },
        .named => |name| blk: {
            const decl = metadata.findTypeDecl(spec, name) orelse {
                _ = errors.jsError(ctx, .invalid_arg, "C: unknown POD struct field type", null, null, null);
                return -1;
            };
            switch (decl.*) {
                .pod_struct => |*pod| {
                    if (!qjs.isObject(value) or qjs.isNull(value)) {
                        _ = errors.jsError(ctx, .invalid_arg, "C: nested POD struct fields require JS objects", null, null, null);
                        return -1;
                    }
                    break :blk writePodStructFromObjectAtOffset(ctx, spec, pod, storage, offset, value);
                },
                else => {
                    _ = errors.jsError(ctx, .invalid_arg, "C: only POD struct field types are supported in nested runtime marshaling", null, null, null);
                    return -1;
                },
            }
        },
        else => {
            _ = errors.jsError(ctx, .invalid_arg, "C: only primitive fields and nested named POD structs are currently supported at runtime", null, null, null);
            return -1;
        },
    };
}

fn readPodStructField(
    ctx: ?*qjs.c.JSContext,
    spec: metadata.LibrarySpec,
    ty: metadata.TypeRef,
    storage: []align(8) u8,
    offset: usize,
) !qjs.c.JSValue {
    return switch (ty) {
        .primitive => |primitive| switch (primitive) {
            .bool => qjs.boolValue(ctx, storage[offset] != 0),
            .char, .uint8_t => qjs.c.JS_NewInt32(ctx, storage[offset]),
            .int8_t => qjs.c.JS_NewInt32(ctx, @as(i8, @bitCast(storage[offset]))),
            .int16_t => qjs.c.JS_NewInt32(ctx, std.mem.readInt(i16, storage[offset..][0..2], .little)),
            .uint16_t => qjs.c.JS_NewInt32(ctx, std.mem.readInt(u16, storage[offset..][0..2], .little)),
            .int32_t => qjs.c.JS_NewInt32(ctx, std.mem.readInt(i32, storage[offset..][0..4], .little)),
            .uint32_t => qjs.c.JS_NewInt64(ctx, std.mem.readInt(u32, storage[offset..][0..4], .little)),
            .int64_t => qjs.c.JS_NewInt64(ctx, std.mem.readInt(i64, storage[offset..][0..8], .little)),
            .uint64_t, .size_t => qjs.c.JS_NewInt64(ctx, @intCast(std.mem.readInt(u64, storage[offset..][0..8], .little))),
            .float => qjs.c.JS_NewFloat64(ctx, @as(f32, @bitCast(std.mem.readInt(u32, storage[offset..][0..4], .little)))),
            .double => qjs.c.JS_NewFloat64(ctx, @bitCast(std.mem.readInt(u64, storage[offset..][0..8], .little))),
            .void => return error.UnsupportedFeature,
        },
        .named => |name| blk: {
            const decl = metadata.findTypeDecl(spec, name) orelse return error.UnsupportedFeature;
            switch (decl.*) {
                .pod_struct => |*pod| {
                    const obj = qjs.newObject(ctx);
                    errdefer qjs.freeValue(ctx, obj);
                    for (pod.fields) |field| {
                        const field_offset = podStructFieldOffset(spec, pod, field.name) orelse return error.UnsupportedFeature;
                        const js_value = try readPodStructField(ctx, spec, field.ty, storage, offset + field_offset);
                        const key = try alloc.dupeZ(u8, field.name);
                        defer alloc.free(key);
                        try qjs.setProperty(ctx, obj, key, js_value);
                    }
                    break :blk obj;
                },
                else => return error.UnsupportedFeature,
            }
        },
        else => return error.UnsupportedFeature,
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

test "nested POD struct pointer marshaling stages and copies back through JS objects" {
    const inner_decl = metadata.TypeDecl{
        .pod_struct = .{
            .name = "Inner",
            .fields = &.{
                .{ .name = "x", .ty = .{ .primitive = .int32_t } },
                .{ .name = "y", .ty = .{ .primitive = .int32_t } },
            },
        },
    };
    const outer_decl = metadata.TypeDecl{
        .pod_struct = .{
            .name = "Outer",
            .fields = &.{
                .{ .name = "inner", .ty = .{ .named = "Inner" } },
                .{ .name = "scale", .ty = .{ .primitive = .double } },
            },
        },
    };
    const spec = metadata.LibrarySpec{
        .library_name = "test",
        .type_decls = &.{ inner_decl, outer_decl },
        .functions = &.{},
    };

    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const value = qjs.eval(runtime.ctx, "({ inner: { x: 1, y: 2 }, scale: 3 })", "<test>", qjs.EvalFlags.global);
    defer qjs.freeValue(runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    var int_args = [_]usize{0};
    var temp_structs = std.ArrayList(TempStructArg).empty;
    defer freeTempStructs(runtime.ctx, &temp_structs);

    const outer_ty = metadata.TypeRef{
        .pointer = .{
            .target = .{ .named = "Outer" },
            .depth = 1,
        },
    };
    try std.testing.expectEqual(@as(c_int, 0), marshalPodStructPointerArg(runtime.ctx, value, spec, outer_ty, &int_args, 0, &temp_structs));
    try std.testing.expectEqual(@as(usize, 1), temp_structs.items.len);

    const storage = temp_structs.items[0].storage;
    std.mem.writeInt(i32, storage[0..4], 10, .little);
    std.mem.writeInt(i32, storage[4..8], 20, .little);
    std.mem.writeInt(u64, storage[8..16], @bitCast(@as(f64, 6.5)), .little);

    try std.testing.expectEqual(@as(c_int, 0), applyPodStructOutputs(runtime.ctx, temp_structs.items[0]));

    const inner = qjs.getProperty(runtime.ctx, value, "inner");
    defer qjs.freeValue(runtime.ctx, inner);
    const x = qjs.getProperty(runtime.ctx, inner, "x");
    defer qjs.freeValue(runtime.ctx, x);
    const y = qjs.getProperty(runtime.ctx, inner, "y");
    defer qjs.freeValue(runtime.ctx, y);
    const scale = qjs.getProperty(runtime.ctx, value, "scale");
    defer qjs.freeValue(runtime.ctx, scale);

    var x_num: i64 = 0;
    var y_num: i64 = 0;
    var scale_num: f64 = 0;
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToInt64(runtime.ctx, &x_num, x));
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToInt64(runtime.ctx, &y_num, y));
    try std.testing.expectEqual(@as(c_int, 0), qjs.c.JS_ToFloat64(runtime.ctx, &scale_num, scale));
    try std.testing.expectEqual(@as(i64, 10), x_num);
    try std.testing.expectEqual(@as(i64, 20), y_num);
    try std.testing.expectEqual(@as(f64, 6.5), scale_num);
}
