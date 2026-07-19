const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const runtime_allocator = @import("../runtime_allocator.zig");
const metrics = @import("metrics.zig");
const store = @import("store.zig");

const net_available = @hasDecl(std.Io, "net");
const net = std.Io.net;

const page = @embedFile("dashboard.html");

fn runtimeAllocator() std.mem.Allocator {
    return runtime_allocator.allocator();
}

pub const Handle = struct {
    state: ?*State = null,

    pub fn deinit(self: *Handle) void {
        const state = self.state orelse return;
        state.stop.store(true, .release);
        // Wake a thread blocked in accept before joining it. Closing a listener
        // from another thread does not reliably interrupt accept on Linux.
        if (state.server.socket.address.connect(state.io, .{ .mode = .stream })) |stream| {
            stream.close(state.io);
        } else |_| {}
        if (state.thread) |thread| thread.join();
        state.server.deinit(state.io);
        state.allocator.destroy(state);
        self.* = .{};
    }

    pub fn port(self: Handle) ?u16 {
        const state = self.state orelse return null;
        return state.port;
    }

    pub fn url(self: Handle, buffer: []u8) ![]const u8 {
        const state = self.state orelse return error.TelemetryConsoleDisabled;
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/", .{state.port});
    }
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: net.Server,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    port: u16 = 0,
    thread: ?std.Thread = null,
};

const ConnectionTask = struct {
    io: std.Io,
    connection: net.Stream,
};

pub fn start(allocator: std.mem.Allocator, io: ?std.Io) !Handle {
    if (!config.config.telemetry.console_enabled or !net_available) return .{};
    const active_io = io orelse return .{};

    const address = try net.IpAddress.parseIp4("127.0.0.1", config.config.telemetry.console_port);
    var listener = try address.listen(active_io, .{
        .reuse_address = true,
    });
    const state = allocator.create(State) catch |err| {
        listener.deinit(active_io);
        return err;
    };
    errdefer {
        listener.deinit(active_io);
        allocator.destroy(state);
    }
    state.* = .{
        .allocator = allocator,
        .io = active_io,
        .server = listener,
        .port = listener.socket.address.getPort(),
    };
    state.thread = try std.Thread.spawn(.{}, run, .{state});
    return .{ .state = state };
}

fn run(state: *State) void {
    if (!builtin.is_test) {
        std.debug.print("Telemetry console listening on http://127.0.0.1:{d}/\n", .{state.port});
    }
    while (!state.stop.load(.acquire)) {
        const connection = state.server.accept(state.io) catch {
            if (state.stop.load(.acquire)) break;
            continue;
        };
        const task = std.heap.page_allocator.create(ConnectionTask) catch {
            connection.close(state.io);
            continue;
        };
        task.* = .{
            .io = state.io,
            .connection = connection,
        };
        const thread = std.Thread.spawn(.{}, runConnection, .{task}) catch {
            task.connection.close(task.io);
            std.heap.page_allocator.destroy(task);
            continue;
        };
        thread.detach();
    }
}

fn runConnection(task: *ConnectionTask) void {
    defer std.heap.page_allocator.destroy(task);
    handleConnection(task.io, task.connection) catch {};
}

fn handleConnection(io: std.Io, connection: net.Stream) !void {
    defer connection.close(io);

    var request_buffer: [8192]u8 = undefined;
    var segments = [_][]u8{request_buffer[0..]};
    const count = try io.vtable.netRead(io.userdata, connection.socket.handle, &segments);
    if (count == 0) return;
    const request = request_buffer[0..count];
    const line_end = std.mem.indexOf(u8, request, "\r\n") orelse return writeResponse(io, connection, 400, "text/plain", "bad request");
    var parts = std.mem.splitScalar(u8, request[0..line_end], ' ');
    const method: []const u8 = parts.next() orelse "";
    const target: []const u8 = parts.next() orelse "";

    if (!pathEquals(method, "GET")) {
        return writeJsonResponse(io, connection, 405, "{\"error\":\"method_not_allowed\"}");
    }
    if (pathEquals(target, "/") or pathEquals(target, "/index.html")) {
        return writeResponse(io, connection, 200, "text/html; charset=utf-8", page);
    }
    if (pathEquals(target, "/health") or pathEquals(target, "/api/health")) {
        return writeJsonResponse(io, connection, 200, "{\"ok\":true}");
    }
    if (pathEquals(target, "/metrics") or pathEquals(target, "/api/metrics")) {
        return writeMetricsResponse(io, connection);
    }
    if (std.mem.startsWith(u8, target, "/traces") or std.mem.startsWith(u8, target, "/api/traces")) {
        return writeTracesResponse(io, connection, target);
    }
    return writeJsonResponse(io, connection, 404, "{\"error\":\"not_found\"}");
}

fn writeMetricsResponse(io: std.Io, stream: net.Stream) !void {
    var snapshots: [metrics.max_metrics]metrics.Snapshot = undefined;
    const view = metrics.snapshot(&snapshots);
    var body = std.ArrayList(u8).empty;
    defer body.deinit(runtimeAllocator());
    try body.append(runtimeAllocator(), '[');
    for (view, 0..) |entry, index| {
        if (index != 0) try body.append(runtimeAllocator(), ',');
        try body.appendSlice(runtimeAllocator(), "{\"id\":");
        try body.print(runtimeAllocator(), "{d},\"scope\":", .{entry.id});
        try appendJsonString(&body, entry.scope);
        try body.appendSlice(runtimeAllocator(), ",\"name\":");
        try appendJsonString(&body, entry.name);
        try body.appendSlice(runtimeAllocator(), ",\"kind\":");
        try appendJsonString(&body, @tagName(entry.kind));
        try body.appendSlice(runtimeAllocator(), ",\"unit\":");
        try appendJsonString(&body, entry.unit);
        try body.print(runtimeAllocator(), ",\"value\":{d},\"count\":{d},\"sum\":{d},\"min\":{d},\"max\":{d}}}", .{
            entry.value,
            entry.count,
            entry.sum,
            entry.min,
            entry.max,
        });
    }
    try body.append(runtimeAllocator(), ']');
    try writeJsonResponse(io, stream, 200, body.items);
}

fn writeTracesResponse(io: std.Io, stream: net.Stream, target: []const u8) !void {
    const query = parseQuery(target);
    const limit = @min(query.limit, store.max_trace_records);
    var records: [store.max_trace_records]@import("trace.zig").RecordView = undefined;
    const result = store.buffer().snapshotAfter(query.since, records[0..limit]);

    var body = std.ArrayList(u8).empty;
    defer body.deinit(runtimeAllocator());
    try body.print(runtimeAllocator(), "{{\"next_cursor\":{d},\"missed\":{s},\"records\":[", .{
        result.next_cursor,
        if (result.missed) "true" else "false",
    });
    for (result.records, 0..) |record, index| {
        if (index != 0) try body.append(runtimeAllocator(), ',');
        try body.print(runtimeAllocator(), "{{\"sequence\":{d},\"kind\":", .{record.sequence});
        try appendJsonString(&body, @tagName(record.kind));
        try body.print(runtimeAllocator(), ",\"timestamp_ns\":{d},\"trace_id\":", .{record.timestamp_ns});
        try appendHexString(&body, &record.context.trace_id);
        try body.appendSlice(runtimeAllocator(), ",\"span_id\":");
        try appendHexString(&body, &record.context.span_id);
        try body.appendSlice(runtimeAllocator(), ",\"parent_span_id\":");
        try appendHexString(&body, &record.parent_span_id);
        try body.appendSlice(runtimeAllocator(), ",\"name\":");
        try appendJsonString(&body, record.name);
        try body.appendSlice(runtimeAllocator(), ",\"status\":");
        try appendJsonString(&body, @tagName(record.status));
        try body.append(runtimeAllocator(), '}');
    }
    try body.appendSlice(runtimeAllocator(), "]}");
    try writeJsonResponse(io, stream, 200, body.items);
}

const Query = struct {
    since: u64 = 0,
    limit: usize = store.max_trace_records,
};

fn parseQuery(target: []const u8) Query {
    var result = Query{};
    const question = std.mem.indexOfScalar(u8, target, '?') orelse return result;
    var pairs = std.mem.splitScalar(u8, target[question + 1 ..], '&');
    while (pairs.next()) |pair| {
        var values = std.mem.splitScalar(u8, pair, '=');
        const key = values.next() orelse continue;
        const value = values.next() orelse continue;
        if (std.mem.eql(u8, key, "since")) result.since = std.fmt.parseInt(u64, value, 10) catch result.since;
        if (std.mem.eql(u8, key, "limit")) result.limit = std.fmt.parseInt(usize, value, 10) catch result.limit;
    }
    if (result.limit == 0) result.limit = 1;
    return result;
}

fn pathEquals(value: []const u8, comptime expected: []const u8) bool {
    return value.len == expected.len and std.mem.eql(u8, value, expected);
}

fn appendJsonString(body: *std.ArrayList(u8), value: []const u8) !void {
    try body.append(runtimeAllocator(), '"');
    for (value) |byte| switch (byte) {
        '"' => try body.appendSlice(runtimeAllocator(), "\\\""),
        '\\' => try body.appendSlice(runtimeAllocator(), "\\\\"),
        '\n' => try body.appendSlice(runtimeAllocator(), "\\n"),
        '\r' => try body.appendSlice(runtimeAllocator(), "\\r"),
        '\t' => try body.appendSlice(runtimeAllocator(), "\\t"),
        else => if (byte < 0x20) {
            try body.print(runtimeAllocator(), "\\u{d:0>4}", .{byte});
        } else try body.append(runtimeAllocator(), byte),
    };
    try body.append(runtimeAllocator(), '"');
}

fn appendHexString(body: *std.ArrayList(u8), bytes: []const u8) !void {
    const hex = "0123456789abcdef";
    try body.append(runtimeAllocator(), '"');
    for (bytes) |byte| {
        try body.append(runtimeAllocator(), hex[byte >> 4]);
        try body.append(runtimeAllocator(), hex[byte & 0xf]);
    }
    try body.append(runtimeAllocator(), '"');
}

fn writeJsonResponse(io: std.Io, stream: net.Stream, status: u16, body: []const u8) !void {
    return writeResponse(io, stream, status, "application/json", body);
}

fn writeResponse(io: std.Io, stream: net.Stream, status: u16, content_type: []const u8, body: []const u8) !void {
    const reason = switch (status) {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        else => "OK",
    };
    var header: [256]u8 = undefined;
    const rendered = try std.fmt.bufPrint(&header, "HTTP/1.1 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ status, reason, content_type, body.len });
    var io_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &io_buffer);
    try writer.interface.writeAll(rendered);
    try writer.interface.writeAll(body);
    try writer.interface.flush();
}

test "telemetry console config starts an in-process HTTP server" {
    if (!net_available) return error.SkipZigTest;
    const old_enabled = config.config.telemetry.console_enabled;
    const old_port = config.config.telemetry.console_port;
    defer {
        config.config.telemetry.console_enabled = old_enabled;
        config.config.telemetry.console_port = old_port;
    }
    config.config.telemetry.console_enabled = true;
    config.config.telemetry.console_port = 0;

    var handle = try start(std.testing.allocator, std.testing.io);
    defer handle.deinit();
    const port = handle.port() orelse return error.TestExpectedPort;
    try std.testing.expect(port != 0);

    const address = try net.IpAddress.parseIp4("127.0.0.1", port);
    const stream = try address.connect(std.testing.io, .{ .mode = .stream });
    defer stream.close(std.testing.io);
    var write_buffer: [1024]u8 = undefined;
    var writer = stream.writer(std.testing.io, &write_buffer);
    try writer.interface.writeAll("GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    var response: [1024]u8 = undefined;
    var read_buffer: [1024]u8 = undefined;
    var reader = stream.reader(std.testing.io, &read_buffer);
    const count = try reader.interface.readSliceShort(&response);
    try std.testing.expect(std.mem.startsWith(u8, response[0..count], "HTTP/1.1 200 OK"));
}
