const package = @import("package.zig");

pub const runtime_source =
    \\export const name = "hao";
    \\export const namespace = "hao:";
    \\export default { name, namespace };
;

pub const sources = [_]package.SourceModule{.{
    .specifier = "hao:runtime",
    .source = runtime_source,
}};

pub const package_descriptor = package.Package{
    .name = "hao",
    .sources = &sources,
};

pub fn register(registry: *package.Registry) !void {
    try registry.register(package_descriptor);
}
