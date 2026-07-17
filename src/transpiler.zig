const std = @import("std");

const backend = struct {
    extern fn hao_lookup_original_position(source_path: [*:0]const u8, generated_line: u32, generated_column: u32) ?[*:0]u8;
    extern fn hao_transpile_types_for_path(source: [*:0]const u8, source_path: [*:0]const u8) ?[*:0]u8;
    extern fn hao_transform_module(source: [*:0]const u8, source_path: [*:0]const u8, isolated: u8, namespace_root: [*:0]const u8) ?[*:0]u8;
    extern fn hao_transform_esm_module(source: [*:0]const u8, source_path: [*:0]const u8) ?[*:0]u8;
    extern fn hao_transpiler_last_error() ?[*:0]u8;
    extern fn hao_transpiler_free(ptr: [*:0]u8) void;
};

pub const OriginalPosition = struct {
    source: []const u8,
    line: u32,
    column: u32,

    pub fn deinit(self: OriginalPosition, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.source));
    }
};

/// Rust-owned module transform contract.
pub const ModuleTransformResult = struct {
    code: []u8,
    source_url: []u8,
    imports: []RuntimeImport,
    exports_slot: []u8,

    pub fn deinit(self: ModuleTransformResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.source_url);
        for (self.imports) |import_record| {
            allocator.free(import_record.slot);
            allocator.free(import_record.source);
        }
        allocator.free(self.imports);
        allocator.free(self.exports_slot);
    }
};

pub const RuntimeImport = struct {
    slot: []u8,
    source: []u8,
};

pub const ESMTransformResult = struct {
    code: []u8,
    source_url: []u8,

    pub fn deinit(self: ESMTransformResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.source_url);
    }
};

pub const ScriptTransformResult = struct {
    code: []u8,
    source_url: []u8,

    pub fn deinit(self: ScriptTransformResult, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.source_url);
    }
};

fn trackedDupe(comptime T: type, allocator: std.mem.Allocator, data: []const T) ![]T {
    const out = try allocator.alloc(T, data.len);
    @memcpy(out, data);
    return out;
}

pub fn deinitTranspilerString(value: []u8, allocator: std.mem.Allocator) void {
    allocator.free(value);
}

pub fn takeLastError(allocator: std.mem.Allocator) ?[]u8 {
    const result_ptr = backend.hao_transpiler_last_error() orelse return null;
    defer backend.hao_transpiler_free(result_ptr);
    return trackedDupe(u8, allocator, std.mem.span(result_ptr)) catch null;
}

pub fn deinitRuntimeImport(import_record: RuntimeImport, allocator: std.mem.Allocator) void {
    deinitTranspilerString(import_record.slot, allocator);
    deinitTranspilerString(import_record.source, allocator);
}

pub fn deinitRuntimeImports(imports: []RuntimeImport, allocator: std.mem.Allocator) void {
    allocator.free(imports);
}

pub fn transformModule(
    source: []const u8,
    path: []const u8,
    isolated: bool,
    namespace_root: []const u8,
    allocator: std.mem.Allocator,
) !ModuleTransformResult {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const namespace_root_z = try allocator.dupeZ(u8, namespace_root);
    defer allocator.free(namespace_root_z);

    const result_ptr = backend.hao_transform_module(
        source_z.ptr,
        path_z.ptr,
        if (isolated) 1 else 0,
        namespace_root_z.ptr,
    ) orelse return error.TranspileFailed;
    defer backend.hao_transpiler_free(result_ptr);

    const json = std.mem.span(result_ptr);
    const parsed = try std.json.parseFromSlice(ModuleTransformResult, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const imports = try allocator.alloc(RuntimeImport, parsed.value.imports.len);
    errdefer allocator.free(imports);
    var built: usize = 0;
    errdefer {
        for (imports[0..built]) |import_record| {
            allocator.free(import_record.slot);
            allocator.free(import_record.source);
        }
    }
    for (parsed.value.imports, 0..) |import_record, index| {
        imports[index] = .{
            .slot = try trackedDupe(u8, allocator, import_record.slot),
            .source = try trackedDupe(u8, allocator, import_record.source),
        };
        built += 1;
    }

    const code = try trackedDupe(u8, allocator, parsed.value.code);
    errdefer allocator.free(code);
    const source_url = try trackedDupe(u8, allocator, parsed.value.source_url);
    errdefer allocator.free(source_url);
    const exports_slot = try trackedDupe(u8, allocator, parsed.value.exports_slot);
    errdefer allocator.free(exports_slot);

    return .{
        .code = code,
        .source_url = source_url,
        .imports = imports,
        .exports_slot = exports_slot,
    };
}

pub fn remapGeneratedLocation(
    path: []const u8,
    generated_line: usize,
    generated_column: usize,
    allocator: std.mem.Allocator,
) !?OriginalPosition {
    if (generated_line == 0 or generated_column == 0) return null;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const result_ptr = backend.hao_lookup_original_position(
        path_z.ptr,
        @intCast(generated_line),
        @intCast(generated_column),
    ) orelse return null;
    defer backend.hao_transpiler_free(result_ptr);

    const json = std.mem.span(result_ptr);
    const parsed = try std.json.parseFromSlice(OriginalPosition, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const source_copy = try trackedDupe(u8, allocator, parsed.value.source);
    return .{
        .source = source_copy,
        .line = parsed.value.line,
        .column = parsed.value.column,
    };
}

pub fn transformEsmModule(
    source: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
) !ESMTransformResult {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const result_ptr = backend.hao_transform_esm_module(source_z.ptr, path_z.ptr) orelse return error.TranspileFailed;
    defer backend.hao_transpiler_free(result_ptr);

    const json = std.mem.span(result_ptr);
    const parsed = try std.json.parseFromSlice(ESMTransformResult, allocator, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const code = try trackedDupe(u8, allocator, parsed.value.code);
    errdefer allocator.free(code);
    const source_url = try trackedDupe(u8, allocator, parsed.value.source_url);
    return .{
        .code = code,
        .source_url = source_url,
    };
}

pub fn transpileScript(
    source: []const u8,
    path: []const u8,
    allocator: std.mem.Allocator,
) !ScriptTransformResult {
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);

    const result_ptr = backend.hao_transpile_types_for_path(source_z.ptr, path_z.ptr) orelse return error.TranspileFailed;
    defer backend.hao_transpiler_free(result_ptr);

    const code = try trackedDupe(u8, allocator, std.mem.span(result_ptr));
    errdefer allocator.free(code);
    const source_url = try trackedDupe(u8, allocator, path);
    return .{
        .code = code,
        .source_url = source_url,
    };
}

test "transpileScript strips TypeScript annotations" {
    const result = try transpileScript(
        "const value: number = 42; globalThis.__hao_ts_value = value;",
        "smoke.ts",
        std.testing.allocator,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.code, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.code, "__hao_ts_value") != null);
}
