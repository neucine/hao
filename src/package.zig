const std = @import("std");
const qjs = @import("qjs.zig");
const fs = @import("fs.zig");

pub const SourceModule = struct {
    specifier: []const u8,
    source: []const u8,
};

pub const NativeModule = struct {
    specifier: []const u8,
    load: *const fn (ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef,
};

pub const Package = struct {
    name: []const u8,
    sources: []const SourceModule = &.{},
    native_modules: []const NativeModule = &.{},
    install: ?*const fn (*qjs.Runtime) anyerror!void = null,
};

pub fn isHaoSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "hao:");
}

pub fn isHaoPackageName(name: []const u8) bool {
    return std.mem.eql(u8, name, "hao");
}

fn ownsSpecifier(package_name: []const u8, specifier: []const u8) bool {
    if (isHaoPackageName(package_name)) return isHaoSpecifier(specifier);
    if (isHaoSpecifier(specifier)) return false;
    if (!std.mem.startsWith(u8, specifier, package_name)) return false;
    return specifier.len == package_name.len or specifier[package_name.len] == ':';
}

pub const Registry = struct {
    allocator: std.mem.Allocator,
    packages: std.ArrayList(Package),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .packages = .empty,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.packages.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn register(self: *Registry, package: Package) !void {
        if (package.name.len == 0) return error.EmptyPackageName;
        if (self.findPackage(package.name) != null) return error.DuplicatePackage;
        for (package.sources) |source| {
            if (!ownsSpecifier(package.name, source.specifier)) return error.PackageSpecifierMismatch;
        }
        for (package.native_modules) |native_module| {
            if (!ownsSpecifier(package.name, native_module.specifier)) return error.PackageSpecifierMismatch;
        }
        try self.packages.append(self.allocator, package);
    }

    pub fn findPackage(self: *const Registry, name: []const u8) ?Package {
        for (self.packages.items) |package| {
            if (std.mem.eql(u8, package.name, name)) return package;
        }
        return null;
    }

    pub fn findSource(self: *const Registry, specifier: []const u8) ?SourceModule {
        for (self.packages.items) |package| {
            for (package.sources) |source| {
                if (std.mem.eql(u8, source.specifier, specifier)) return source;
            }
        }
        return null;
    }

    pub fn findNativeModule(self: *const Registry, specifier: []const u8) ?NativeModule {
        for (self.packages.items) |package| {
            for (package.native_modules) |native_module| {
                if (std.mem.eql(u8, native_module.specifier, specifier)) return native_module;
            }
        }
        return null;
    }
};

pub const Resolution = struct {
    abs_path: []u8,
    package_name: []u8,

    pub fn deinit(self: Resolution, allocator: std.mem.Allocator) void {
        allocator.free(self.abs_path);
        allocator.free(self.package_name);
    }
};

fn copy(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, value.len);
    @memcpy(out, value);
    return out;
}

fn join(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    const raw = try std.fs.path.join(allocator, parts);
    defer allocator.free(raw);
    return copy(allocator, raw);
}

fn allocPrint(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const raw = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(raw);
    return copy(allocator, raw);
}

fn readPackageJson(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return fs.readFileAlloc(allocator, path, 256 * 1024);
}

pub fn resolveImport(current_file: []const u8, specifier: []const u8, allocator: std.mem.Allocator) !Resolution {
    const current_dir = std.fs.path.dirname(current_file) orelse ".";
    const package_name, const subpath = splitPackageSpecifier(specifier);

    var dir = try copy(allocator, current_dir);
    defer allocator.free(dir);

    while (true) {
        const package_root = try join(allocator, &.{ dir, "node_modules", package_name });
        defer allocator.free(package_root);

        if (fs.pathExists(package_root)) {
            const entry_rel = try resolveEntry(package_root, subpath, allocator);
            defer allocator.free(entry_rel);

            const abs_path = try join(allocator, &.{ package_root, entry_rel });
            errdefer allocator.free(abs_path);
            const package_name_copy = try copy(allocator, package_name);
            errdefer allocator.free(package_name_copy);
            return .{
                .abs_path = abs_path,
                .package_name = package_name_copy,
            };
        }

        const parent = std.fs.path.dirname(dir) orelse break;
        if (parent.len == dir.len and std.mem.eql(u8, parent, dir)) break;
        const next_dir = try copy(allocator, parent);
        allocator.free(dir);
        dir = next_dir;
    }

    return error.PackageNotFound;
}

fn splitPackageSpecifier(specifier: []const u8) struct { []const u8, []const u8 } {
    if (specifier.len == 0) return .{ specifier, "" };

    if (specifier[0] == '@') {
        var slash_count: usize = 0;
        for (specifier, 0..) |ch, idx| {
            if (ch == '/') {
                slash_count += 1;
                if (slash_count == 2) {
                    return .{ specifier[0..idx], specifier[idx + 1 ..] };
                }
            }
        }
        return .{ specifier, "" };
    }

    if (std.mem.indexOfScalar(u8, specifier, '/')) |idx| {
        return .{ specifier[0..idx], specifier[idx + 1 ..] };
    }
    return .{ specifier, "" };
}

fn resolveEntry(package_root: []const u8, subpath: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const package_json_path = try join(allocator, &.{ package_root, "package.json" });
    defer allocator.free(package_json_path);

    const package_json = readPackageJson(allocator, package_json_path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    defer if (package_json) |json| allocator.free(json);

    return resolvePackageSubpath(package_root, package_json, subpath, allocator);
}

fn resolvePackageSubpath(
    package_root: []const u8,
    package_json: ?[]const u8,
    subpath: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (subpath.len != 0) {
        return resolvePathWithExtensions(package_root, subpath, allocator);
    }

    const json = package_json orelse return resolvePathWithExtensions(package_root, "index", allocator);

    if (extractTopLevelString(json, "\"type\"")) |pkg_type| {
        if (std.mem.eql(u8, pkg_type, "commonjs")) return error.UnsupportedCommonJS;
    }

    if (extractJsonStringByPath(json, "\"exports\"", &.{ "\".\"", "\"import\"" })) |entry| {
        return resolvePathWithExtensions(package_root, entry, allocator);
    }
    if (extractJsonStringByPath(json, "\"exports\"", &.{"\".\""})) |entry| {
        return resolvePathWithExtensions(package_root, entry, allocator);
    }
    if (extractTopLevelString(json, "\"exports\"")) |entry| {
        return resolvePathWithExtensions(package_root, entry, allocator);
    }
    if (extractTopLevelString(json, "\"main\"")) |entry| {
        return resolvePathWithExtensions(package_root, entry, allocator);
    }

    return resolvePathWithExtensions(package_root, "index", allocator);
}

fn resolvePathWithExtensions(package_root: []const u8, entry: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const cleaned = if (std.mem.startsWith(u8, entry, "./")) entry[2..] else entry;
    const candidates = [_][]const u8{ "", ".ts", ".js", ".mts", ".mjs" };

    for (candidates) |ext| {
        const rel = if (ext.len == 0) try copy(allocator, cleaned) else try allocPrint(allocator, "{s}{s}", .{ cleaned, ext });
        defer allocator.free(rel);

        const abs = try join(allocator, &.{ package_root, rel });
        defer allocator.free(abs);

        if (fs.pathExists(abs)) {
            return copy(allocator, rel);
        }
    }

    return error.PackageEntryNotFound;
}

fn extractTopLevelString(json: []const u8, key: []const u8) ?[]const u8 {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < json.len) : (i += 1) {
        switch (json[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth > 0) depth -= 1;
            },
            '"' => {
                if (depth == 1 and i + key.len <= json.len and std.mem.eql(u8, json[i .. i + key.len], key)) {
                    var j: usize = i + key.len;
                    while (j < json.len and (std.ascii.isWhitespace(json[j]) or json[j] == ':')) : (j += 1) {}
                    if (j < json.len and json[j] == '"') {
                        const start = j + 1;
                        var end = start;
                        while (end < json.len and json[end] != '"') : (end += 1) {}
                        if (end <= json.len) return json[start..end];
                    }
                }
            },
            else => {},
        }
    }
    return null;
}

fn extractJsonStringByPath(json: []const u8, top_key: []const u8, path: []const []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, json, top_key)) |top_pos| {
        if (std.mem.indexOfScalarPos(u8, json, top_pos, '{')) |obj_start| {
            if (findMatchingBrace(json, obj_start)) |obj_end| {
                var slice = json[obj_start .. obj_end + 1];
                for (path, 0..) |key, idx| {
                    if (std.mem.indexOf(u8, slice, key)) |key_pos| {
                        if (idx == path.len - 1) {
                            var j: usize = key_pos + key.len;
                            while (j < slice.len and (std.ascii.isWhitespace(slice[j]) or slice[j] == ':')) : (j += 1) {}
                            if (j < slice.len and slice[j] == '"') {
                                const start = j + 1;
                                var end = start;
                                while (end < slice.len and slice[end] != '"') : (end += 1) {}
                                if (end <= slice.len) return slice[start..end];
                            }
                            return null;
                        }
                        if (std.mem.indexOfScalarPos(u8, slice, key_pos, '{')) |nested_start| {
                            if (findMatchingBrace(slice, nested_start)) |nested_end| {
                                slice = slice[nested_start .. nested_end + 1];
                                continue;
                            }
                        }
                        return null;
                    }
                    return null;
                }
            }
        }
    }
    return null;
}

fn findMatchingBrace(s: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var i = start;
    while (i < s.len) : (i += 1) {
        if (s[i] == '{') {
            depth += 1;
        } else if (s[i] == '}') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

test "registry stores source modules by specifier" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const sources = [_]SourceModule{.{
        .specifier = "demo:hello",
        .source = "export const hello = 'hao';",
    }};
    try registry.register(.{
        .name = "demo",
        .sources = &sources,
    });

    try std.testing.expect(registry.findPackage("demo") != null);
    try std.testing.expectEqualStrings("export const hello = 'hao';", registry.findSource("demo:hello").?.source);
    try std.testing.expect(registry.findSource("missing") == null);
}

test "registry rejects package-owned modules outside package prefix" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const sources = [_]SourceModule{.{
        .specifier = "other:hello",
        .source = "",
    }};
    try std.testing.expectError(error.PackageSpecifierMismatch, registry.register(.{
        .name = "demo",
        .sources = &sources,
    }));
}

test "hao namespace is reserved for the hao package" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const bad_sources = [_]SourceModule{.{
        .specifier = "hao:runtime",
        .source = "",
    }};
    try std.testing.expectError(error.PackageSpecifierMismatch, registry.register(.{
        .name = "demo",
        .sources = &bad_sources,
    }));

    const good_sources = [_]SourceModule{.{
        .specifier = "hao:runtime",
        .source = "",
    }};
    try registry.register(.{
        .name = "hao",
        .sources = &good_sources,
    });
}
