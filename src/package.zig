const std = @import("std");
const qjs = @import("qjs.zig");
const config = @import("config.zig");
const fs = @import("fs.zig");
const js_addon = @import("js/addon.zig");

pub const SourceModule = struct {
    specifier: []const u8,
    source: []const u8,
};

pub const NativeModule = struct {
    specifier: []const u8,
    // Keep the package boundary independent of the embedded JS engine type.
    // Implementations that need QuickJS may cast inside Hao itself.
    load: *const fn (ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque,
};

pub const PackageContext = struct {
    runtime: *qjs.Runtime,
    allocator: std.mem.Allocator,
};

pub const Package = struct {
    name: []const u8,
    sources: []const SourceModule = &.{},
    native_modules: []const NativeModule = &.{},
    install: ?*const fn (*PackageContext) anyerror!void = null,
    deinit: ?*const fn (*PackageContext) void = null,
};

pub fn isStdSpecifier(specifier: []const u8) bool {
    return std.mem.startsWith(u8, specifier, "std:");
}

pub fn isStdPackageName(name: []const u8) bool {
    return std.mem.eql(u8, name, "std");
}

fn ownsSpecifier(package_name: []const u8, specifier: []const u8) bool {
    if (isStdPackageName(package_name)) return isStdSpecifier(specifier);
    if (isStdSpecifier(specifier)) return false;
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

    pub fn installPackages(self: *const Registry, context: *PackageContext) !void {
        for (self.packages.items) |package| {
            if (package.install) |install| try install(context);
        }
    }

    pub fn deinitPackages(self: *const Registry, context: *PackageContext) void {
        var index = self.packages.items.len;
        while (index > 0) {
            index -= 1;
            if (self.packages.items[index].deinit) |deinit_package| deinit_package(context);
        }
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

pub const ResolveOptions = struct {
    package_path: ?[]const u8 = null,
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
    return resolveImportWithOptions(current_file, specifier, .{
        .package_path = config.config.package.path,
    }, allocator);
}

pub fn resolveImportWithOptions(
    current_file: []const u8,
    specifier: []const u8,
    options: ResolveOptions,
    allocator: std.mem.Allocator,
) !Resolution {
    const current_dir = std.fs.path.dirname(current_file) orelse ".";
    const package_name, const subpath = splitPackageSpecifier(specifier);

    if (options.package_path) |package_path| {
        if (try resolveFromPackagePath(package_path, package_name, subpath, allocator)) |resolved| return resolved;
    }

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

fn resolveFromPackagePath(
    package_path: []const u8,
    package_name: []const u8,
    subpath: []const u8,
    allocator: std.mem.Allocator,
) !?Resolution {
    var roots = std.mem.tokenizeScalar(u8, package_path, std.fs.path.delimiter);
    while (roots.next()) |root| {
        const trimmed = std.mem.trim(u8, root, " \t\r\n");
        if (trimmed.len == 0) continue;

        const package_root = try join(allocator, &.{ trimmed, package_name });
        defer allocator.free(package_root);
        if (!fs.pathExists(package_root)) continue;

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
    return null;
}

fn splitPackageSpecifier(specifier: []const u8) struct { []const u8, []const u8 } {
    if (specifier.len == 0) return .{ specifier, "" };

    if (specifier[0] == '@') {
        const scope_end = std.mem.indexOfScalar(u8, specifier, '/') orelse return .{ specifier, "" };
        const name_start = scope_end + 1;
        for (specifier[name_start..], name_start..) |ch, idx| {
            if (ch == ':' or ch == '/') return .{ specifier[0..idx], specifier[idx + 1 ..] };
        }
        return .{ specifier, "" };
    }

    if (std.mem.indexOfScalar(u8, specifier, ':')) |idx| {
        return .{ specifier[0..idx], specifier[idx + 1 ..] };
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
        error.FileNotFound => return error.PackageManifestNotFound,
        else => return err,
    };
    defer allocator.free(package_json);

    return resolvePackageSubpath(package_root, package_json, subpath, allocator);
}

fn resolvePackageSubpath(
    package_root: []const u8,
    package_json: []const u8,
    subpath: []const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, package_json, .{}) catch return error.InvalidPackageJson;
    defer parsed.deinit();
    const root = parsed.value;

    const pkg_type = jsonStringAt(root, &.{"type"});
    if (pkg_type) |value| {
        if (std.mem.eql(u8, value, "commonjs")) return error.UnsupportedCommonJS;
    }

    if (subpath.len != 0) {
        const export_key = try std.fmt.allocPrint(allocator, "./{s}", .{subpath});
        defer allocator.free(export_key);
        if (jsonStringAt(root, &.{ "exports", export_key, "import" })) |entry| {
            return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
        }
        if (jsonStringAt(root, &.{ "exports", export_key })) |entry| {
            return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
        }
        return error.PackageExportNotFound;
    }

    if (jsonStringAt(root, &.{ "exports", ".", "import" })) |entry| {
        return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
    }
    if (jsonStringAt(root, &.{ "exports", "." })) |entry| {
        return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
    }
    if (jsonStringAt(root, &.{"exports"})) |entry| {
        return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
    }
    if (jsonStringAt(root, &.{"main"})) |entry| {
        return resolveEsmPathWithExtensions(package_root, entry, pkg_type, allocator);
    }

    return error.PackageExportNotFound;
}

fn resolveEsmPathWithExtensions(package_root: []const u8, entry: []const u8, pkg_type: ?[]const u8, allocator: std.mem.Allocator) ![]u8 {
    const rel = try resolvePathWithExtensions(package_root, entry, allocator);
    errdefer allocator.free(rel);

    if (!isEsmPackageEntry(rel, pkg_type)) return error.UnsupportedPackageManifest;
    return rel;
}

fn isEsmPackageEntry(rel: []const u8, pkg_type: ?[]const u8) bool {
    if (js_addon.isAddonPath(rel)) return true;
    if (std.mem.endsWith(u8, rel, ".ts")) return true;
    if (std.mem.endsWith(u8, rel, ".mts")) return true;
    if (std.mem.endsWith(u8, rel, ".mjs")) return true;
    if (std.mem.endsWith(u8, rel, ".js")) {
        return if (pkg_type) |value| std.mem.eql(u8, value, "module") else false;
    }
    return false;
}

fn resolvePathWithExtensions(package_root: []const u8, entry: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const cleaned = if (std.mem.startsWith(u8, entry, "./")) entry[2..] else entry;
    const candidates = [_][]const u8{ "", ".ts", ".js", ".mts", ".mjs", ".dylib", ".so", ".dll", ".node" };

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

fn jsonStringAt(root: std.json.Value, path: []const []const u8) ?[]const u8 {
    var current = root;
    for (path) |segment| {
        switch (current) {
            .object => |object| current = object.get(segment) orelse escapedJsonKeyGet(object, segment) orelse return null,
            else => return null,
        }
    }
    return switch (current) {
        .string => |value| value,
        else => null,
    };
}

fn escapedJsonKeyGet(object: std.json.ObjectMap, segment: []const u8) ?std.json.Value {
    if (std.mem.eql(u8, segment, ".")) {
        if (object.get("\\u002e")) |value| return value;
        if (object.get("\\u002E")) |value| return value;
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

test "std module namespace is reserved" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const bad_sources = [_]SourceModule{.{
        .specifier = "std:runtime",
        .source = "",
    }};
    try std.testing.expectError(error.PackageSpecifierMismatch, registry.register(.{
        .name = "demo",
        .sources = &bad_sources,
    }));

    const good_sources = [_]SourceModule{.{
        .specifier = "std:runtime",
        .source = "",
    }};
    try registry.register(.{
        .name = "std",
        .sources = &good_sources,
    });
}

test "registry runs package installers" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();

    const Installer = struct {
        var called = false;

        fn install(_: *PackageContext) !void {
            called = true;
        }
    };

    try registry.register(.{
        .name = "demo",
        .install = Installer.install,
    });
    var context = PackageContext{ .runtime = &runtime, .allocator = std.testing.allocator };
    try registry.installPackages(&context);
    try std.testing.expect(Installer.called);
}

test "package resolver accepts addon entries" {
    const root = ".zig-cache/hao-tests/package-native";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo-native");
    try fs.writeFile(root ++ "/main.ts", "import 'demo-native';");
    try fs.writeFile(root ++ "/node_modules/demo-native/package.json", "{\"type\":\"module\",\"exports\":\"./native.dylib\"}");
    try fs.writeFile(root ++ "/node_modules/demo-native/native.dylib", "");

    const resolved = try resolveImport(root ++ "/main.ts", "demo-native", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(js_addon.isAddonPath(resolved.abs_path));
    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "native.dylib"));
}

test "package resolver accepts colon native subpaths" {
    const root = ".zig-cache/hao-tests/package-colon-native";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/foo");
    try fs.writeFile(root ++ "/main.ts", "import 'foo:native';");
    try fs.writeFile(root ++ "/node_modules/foo/package.json", "{\"type\":\"module\",\"exports\":{\"./native\":\"./native.dylib\"}}");
    try fs.writeFile(root ++ "/node_modules/foo/native.dylib", "");

    const resolved = try resolveImport(root ++ "/main.ts", "foo:native", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("foo", resolved.package_name);
    try std.testing.expect(js_addon.isAddonPath(resolved.abs_path));
    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "native.dylib"));
}

test "package resolver maps exported colon subpaths" {
    const root = ".zig-cache/hao-tests/package-colon-exports";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/foo");
    try fs.writeFile(root ++ "/main.ts", "import 'foo:native';");
    try fs.writeFile(root ++ "/node_modules/foo/package.json",
        \\{"type":"module","exports":{"./native":"./addon.dylib","./extra":{"import":"./addon.dylib"}}}
    );
    try fs.writeFile(root ++ "/node_modules/foo/addon.dylib", "");

    const native = try resolveImport(root ++ "/main.ts", "foo:native", std.testing.allocator);
    defer native.deinit(std.testing.allocator);
    const extra = try resolveImport(root ++ "/main.ts", "foo:extra", std.testing.allocator);
    defer extra.deinit(std.testing.allocator);

    try std.testing.expect(js_addon.isAddonPath(native.abs_path));
    try std.testing.expect(js_addon.isAddonPath(extra.abs_path));
    try std.testing.expect(std.mem.endsWith(u8, native.abs_path, "addon.dylib"));
    try std.testing.expect(std.mem.endsWith(u8, extra.abs_path, "addon.dylib"));
}

test "package resolver reads escaped package json strings" {
    const root = ".zig-cache/hao-tests/package-json-escaped";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo-json");
    try fs.writeFile(root ++ "/main.ts", "import 'demo-json';");
    try fs.writeFile(root ++ "/node_modules/demo-json/package.json",
        \\{"type":"module","exports":{"\\u002e":{"import":"./index.js"}}}
    );
    try fs.writeFile(root ++ "/node_modules/demo-json/index.js", "export const value = 1;");

    const resolved = try resolveImport(root ++ "/main.ts", "demo-json", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "index.js"));
}

test "package resolver requires package json manifest" {
    const root = ".zig-cache/hao-tests/package-manifest-required";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(root ++ "/node_modules/demo/index.js", "export const value = 1;");

    try std.testing.expectError(
        error.PackageManifestNotFound,
        resolveImport(root ++ "/main.ts", "demo", std.testing.allocator),
    );
}

test "package resolver accepts mjs packages without type module" {
    const root = ".zig-cache/hao-tests/package-mjs-no-type";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"exports\":\"./index.mjs\"}");
    try fs.writeFile(root ++ "/node_modules/demo/index.mjs", "export const value = 1;");

    const resolved = try resolveImport(root ++ "/main.ts", "demo", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "index.mjs"));
}

test "package resolver rejects ambiguous js packages without type module" {
    const root = ".zig-cache/hao-tests/package-ambiguous-js-rejected";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"exports\":\"./index.js\"}");
    try fs.writeFile(root ++ "/node_modules/demo/index.js", "export const value = 1;");

    try std.testing.expectError(
        error.UnsupportedPackageManifest,
        resolveImport(root ++ "/main.ts", "demo", std.testing.allocator),
    );
}

test "package resolver accepts js packages with type module" {
    const root = ".zig-cache/hao-tests/package-js-type-module";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"type\":\"module\",\"exports\":\"./index.js\"}");
    try fs.writeFile(root ++ "/node_modules/demo/index.js", "export const value = 1;");

    const resolved = try resolveImport(root ++ "/main.ts", "demo", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "index.js"));
}

test "package resolver accepts native addon exports without type module" {
    const root = ".zig-cache/hao-tests/package-native-no-type";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo:native';");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"exports\":{\"./native\":\"./native.dylib\"}}");
    try fs.writeFile(root ++ "/node_modules/demo/native.dylib", "");

    const resolved = try resolveImport(root ++ "/main.ts", "demo:native", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(js_addon.isAddonPath(resolved.abs_path));
    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "native.dylib"));
}

test "package resolver uses configured package path" {
    const root = ".zig-cache/hao-tests/package-config-path";
    const package_root = root ++ "/vendor/demo";
    try fs.makePath(std.testing.allocator, package_root);
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(package_root ++ "/package.json", "{\"exports\":\"./index.mjs\"}");
    try fs.writeFile(package_root ++ "/index.mjs", "export const value = 1;");

    const resolved = try resolveImportWithOptions(root ++ "/main.ts", "demo", .{
        .package_path = root ++ "/vendor",
    }, std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("demo", resolved.package_name);
    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "vendor/demo/index.mjs"));
}

test "package resolver package path precedes local node modules" {
    const root = ".zig-cache/hao-tests/package-config-path-precedence";
    try fs.makePath(std.testing.allocator, root ++ "/vendor/demo");
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo';");
    try fs.writeFile(root ++ "/vendor/demo/package.json", "{\"exports\":\"./vendor.mjs\"}");
    try fs.writeFile(root ++ "/vendor/demo/vendor.mjs", "export const value = 1;");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"exports\":\"./local.mjs\"}");
    try fs.writeFile(root ++ "/node_modules/demo/local.mjs", "export const value = 2;");

    const resolved = try resolveImportWithOptions(root ++ "/main.ts", "demo", .{
        .package_path = root ++ "/vendor",
    }, std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "vendor/demo/vendor.mjs"));
}

test "package resolver rejects unexported package subpaths" {
    const root = ".zig-cache/hao-tests/package-subpath-export-required";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/demo");
    try fs.writeFile(root ++ "/main.ts", "import 'demo/hidden';");
    try fs.writeFile(root ++ "/node_modules/demo/package.json", "{\"type\":\"module\",\"exports\":\"./index.js\"}");
    try fs.writeFile(root ++ "/node_modules/demo/hidden.js", "export const value = 1;");

    try std.testing.expectError(
        error.PackageExportNotFound,
        resolveImport(root ++ "/main.ts", "demo/hidden", std.testing.allocator),
    );
}

test "package resolver splits scoped colon subpaths" {
    const root = ".zig-cache/hao-tests/package-scoped-colon";
    try fs.makePath(std.testing.allocator, root ++ "/node_modules/@scope/foo");
    try fs.writeFile(root ++ "/main.ts", "import '@scope/foo:native';");
    try fs.writeFile(root ++ "/node_modules/@scope/foo/package.json", "{\"type\":\"module\",\"exports\":{\"./native\":\"./native.dylib\"}}");
    try fs.writeFile(root ++ "/node_modules/@scope/foo/native.dylib", "");

    const resolved = try resolveImport(root ++ "/main.ts", "@scope/foo:native", std.testing.allocator);
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("@scope/foo", resolved.package_name);
    try std.testing.expect(std.mem.endsWith(u8, resolved.abs_path, "native.dylib"));
}
