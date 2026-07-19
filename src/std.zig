const ffi_native = @import("std/ffi/native.zig");
const ffi_c_native = @import("std/ffi/c_native.zig");
const fs_native = @import("std/fs/native.zig");
const http_native = @import("std/http/native.zig");
const package = @import("package.zig");
const process_native = @import("std/process/native.zig");
const test_native = @import("std/test/native.zig");
const test_registry = @import("std/test/registry.zig");
const telemetry_native = @import("std/telemetry/native.zig");
const util_native = @import("std/util/native.zig");

pub const sources = [_]package.SourceModule{
    .{
        .specifier = "std:runtime",
        .source = @embedFile("std/runtime/index.ts"),
    },
    .{
        .specifier = "std:fs",
        .source = @embedFile("std/fs/index.ts"),
    },
    .{
        .specifier = "std:process",
        .source = @embedFile("std/process/index.ts"),
    },
    .{
        .specifier = "std:http",
        .source = @embedFile("std/http/index.ts"),
    },
    .{
        .specifier = "std:util",
        .source = @embedFile("std/util/index.ts"),
    },
    .{
        .specifier = "std:plot",
        .source = @embedFile("std/plot/index.ts"),
    },
    .{
        .specifier = "std:test",
        .source = @embedFile("std/test/index.ts"),
    },
    .{
        .specifier = "std:ffi",
        .source = @embedFile("std/ffi/index.ts"),
    },
    .{
        .specifier = "std:ffi/c",
        .source = @embedFile("std/ffi/c.ts"),
    },
    .{
        .specifier = "std:telemetry",
        .source = @embedFile("std/telemetry/index.ts"),
    },
};

pub const native_modules = [_]package.NativeModule{
    .{
        .specifier = ffi_c_native.specifier,
        .load = ffi_c_native.load,
    },
    .{
        .specifier = ffi_native.specifier,
        .load = ffi_native.load,
    },
    .{
        .specifier = fs_native.specifier,
        .load = fs_native.load,
    },
    .{
        .specifier = process_native.specifier,
        .load = process_native.load,
    },
    .{
        .specifier = http_native.specifier,
        .load = http_native.load,
    },
    .{
        .specifier = util_native.specifier,
        .load = util_native.load,
    },
    .{
        .specifier = test_native.specifier,
        .load = test_native.load,
    },
    .{
        .specifier = telemetry_native.specifier,
        .load = telemetry_native.load,
    },
};

pub const package_descriptor = package.Package{
    .name = "std",
    .sources = &sources,
    .native_modules = &native_modules,
    .install = install,
    .deinit = deinit,
};

pub fn register(registry: *package.Registry) !void {
    try registry.register(package_descriptor);
}

fn install(context: *package.PackageContext) !void {
    try test_registry.ensureInit(context.allocator);
}

fn deinit(context: *package.PackageContext) void {
    test_registry.deinit(context.runtime.ctx);
}
