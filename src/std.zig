const fs_native = @import("std/fs/native.zig");
const package = @import("package.zig");
const process_native = @import("std/process/native.zig");

pub const sources = [_]package.SourceModule{
    .{
        .specifier = "hao:runtime",
        .source = @embedFile("std/runtime/index.ts"),
    },
    .{
        .specifier = "hao:fs",
        .source = @embedFile("std/fs/index.ts"),
    },
    .{
        .specifier = "hao:process",
        .source = @embedFile("std/process/index.ts"),
    },
};

pub const native_modules = [_]package.NativeModule{
    .{
        .specifier = fs_native.specifier,
        .load = fs_native.load,
    },
    .{
        .specifier = process_native.specifier,
        .load = process_native.load,
    },
};

pub const package_descriptor = package.Package{
    .name = "hao",
    .sources = &sources,
    .native_modules = &native_modules,
};

pub fn register(registry: *package.Registry) !void {
    try registry.register(package_descriptor);
}
