const std = @import("std");
const fs = @import("../fs.zig");

pub const ConnectionInfo = struct {
    transport: []const u8,
    ip: []const u8,
    shell_port: u16,
    control_port: u16,
    iopub_port: u16,
    stdin_port: u16,
    hb_port: u16,
    key: []const u8,
    signature_scheme: []const u8,

    /// Format an endpoint string like "tcp://127.0.0.1:57503"
    pub fn endpoint(self: *const ConnectionInfo, port: u16, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}://{s}:{d}", .{ self.transport, self.ip, port });
    }
};

/// Parse Jupyter connection file JSON. Minimal scan-based parser for known keys.
pub fn parse(allocator: std.mem.Allocator, path: []const u8) !ConnectionInfo {
    const data = try fs.readFileAlloc(allocator, path, 64 * 1024);
    defer allocator.free(data);

    return ConnectionInfo{
        .transport = try extractStringDupe(allocator, data, "transport") orelse try allocator.dupe(u8, "tcp"),
        .ip = try extractStringDupe(allocator, data, "ip") orelse try allocator.dupe(u8, "127.0.0.1"),
        .shell_port = extractInt(u16, data, "shell_port") orelse return error.MissingField,
        .control_port = extractInt(u16, data, "control_port") orelse return error.MissingField,
        .iopub_port = extractInt(u16, data, "iopub_port") orelse return error.MissingField,
        .stdin_port = extractInt(u16, data, "stdin_port") orelse return error.MissingField,
        .hb_port = extractInt(u16, data, "hb_port") orelse return error.MissingField,
        .key = try extractStringDupe(allocator, data, "key") orelse try allocator.dupe(u8, ""),
        .signature_scheme = try extractStringDupe(allocator, data, "signature_scheme") orelse try allocator.dupe(u8, "hmac-sha256"),
    };
}

pub fn deinit(info: *ConnectionInfo, allocator: std.mem.Allocator) void {
    if (info.transport.len > 0) allocator.free(info.transport);
    if (info.ip.len > 0) allocator.free(info.ip);
    if (info.key.len > 0) allocator.free(info.key);
    if (info.signature_scheme.len > 0) allocator.free(info.signature_scheme);
}

// ---- Minimal JSON field extraction ----

/// Find "key": "value" and return a duped copy of value.
fn extractStringDupe(allocator: std.mem.Allocator, json: []const u8, key: []const u8) !?[]const u8 {
    const val = extractString(json, key) orelse return null;
    return try allocator.dupe(u8, val);
}

/// Find "key": "value" and return slice into json.
fn extractString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key"
    var i: usize = 0;
    while (i + key.len + 2 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            // Found "key", now find the value after : "
            var j = i + 1 + key.len + 1; // past closing "
            // Skip whitespace and colon
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t' or json[j] == '\n' or json[j] == '\r')) : (j += 1) {}
            if (j < json.len and json[j] == '"') {
                // String value
                const start = j + 1;
                var end = start;
                while (end < json.len and json[end] != '"') : (end += 1) {}
                return json[start..end];
            }
        }
    }
    return null;
}

/// Find "key": 12345 and parse as integer.
fn extractInt(comptime T: type, json: []const u8, key: []const u8) ?T {
    var i: usize = 0;
    while (i + key.len + 2 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t' or json[j] == '\n' or json[j] == '\r')) : (j += 1) {}
            // Parse integer
            var end = j;
            while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
            if (end > j) {
                return std.fmt.parseInt(T, json[j..end], 10) catch null;
            }
        }
    }
    return null;
}

test "jupyter connection parser reads ports and defaults owned strings" {
    const root = ".zig-cache/hao-tests/jupyter-connection";
    try fs.makePath(std.testing.allocator, root);
    const path = root ++ "/kernel.json";
    try fs.writeFile(path,
        \\{
        \\  "shell_port": 57503,
        \\  "control_port": 57504,
        \\  "iopub_port": 57505,
        \\  "stdin_port": 57506,
        \\  "hb_port": 57507
        \\}
    );

    var info = try parse(std.testing.allocator, path);
    defer deinit(&info, std.testing.allocator);

    try std.testing.expectEqualStrings("tcp", info.transport);
    try std.testing.expectEqualStrings("127.0.0.1", info.ip);
    try std.testing.expectEqual(@as(u16, 57503), info.shell_port);
    try std.testing.expectEqual(@as(u16, 57504), info.control_port);
    try std.testing.expectEqual(@as(u16, 57505), info.iopub_port);
    try std.testing.expectEqual(@as(u16, 57506), info.stdin_port);
    try std.testing.expectEqual(@as(u16, 57507), info.hb_port);
    try std.testing.expectEqualStrings("", info.key);
    try std.testing.expectEqualStrings("hmac-sha256", info.signature_scheme);

    var endpoint_buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("tcp://127.0.0.1:57503", try info.endpoint(info.shell_port, &endpoint_buf));
}

test "jupyter connection parser reads explicit transport and key fields" {
    const root = ".zig-cache/hao-tests/jupyter-connection";
    try fs.makePath(std.testing.allocator, root);
    const path = root ++ "/explicit.json";
    try fs.writeFile(path,
        \\{
        \\  "transport": "ipc",
        \\  "ip": "0.0.0.0",
        \\  "shell_port": 1,
        \\  "control_port": 2,
        \\  "iopub_port": 3,
        \\  "stdin_port": 4,
        \\  "hb_port": 5,
        \\  "key": "secret",
        \\  "signature_scheme": "hmac-sha256"
        \\}
    );

    var info = try parse(std.testing.allocator, path);
    defer deinit(&info, std.testing.allocator);

    try std.testing.expectEqualStrings("ipc", info.transport);
    try std.testing.expectEqualStrings("0.0.0.0", info.ip);
    try std.testing.expectEqualStrings("secret", info.key);
    try std.testing.expectEqualStrings("hmac-sha256", info.signature_scheme);
}
