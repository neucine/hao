const fs_native = @import("std/fs_native.zig");
const package = @import("package.zig");

pub const runtime_source =
    \\export const name = "hao";
    \\export const namespace = "hao:";
    \\export default { name, namespace };
;

pub const fs_source =
    \\import * as native from "hao:fs/native";
    \\export const existsSync = native.existsSync;
    \\export const readFileSync = native.readFileSync;
    \\export const writeFileSync = native.writeFileSync;
    \\export const statSync = native.statSync;
    \\export default { existsSync, readFileSync, writeFileSync, statSync };
;

pub const sources = [_]package.SourceModule{
    .{
        .specifier = "hao:runtime",
        .source = runtime_source,
    },
    .{
        .specifier = "hao:fs",
        .source = fs_source,
    },
};

pub const native_modules = [_]package.NativeModule{.{
    .specifier = fs_native.specifier,
    .load = fs_native.load,
}};

pub const package_descriptor = package.Package{
    .name = "hao",
    .sources = &sources,
    .native_modules = &native_modules,
};

pub fn register(registry: *package.Registry) !void {
    try registry.register(package_descriptor);
}
