const std = @import("std");
const abi = @import("../../js/abi.zig");
const loop_module = @import("../../async/loop.zig");
const alloc = @import("../../runtime_allocator.zig").allocator();
const uv = @import("server_uv.zig");
fn newTcp() !*uv.uv_tcp_t {
    return @ptrCast(try alloc.alignedAlloc(u8, .@"8", uv.uv_handle_size(uv.UV_TCP)));
}
fn freeTcp(tcp: *uv.uv_tcp_t) void {
    alloc.free(@as([*]align(8) u8, @ptrCast(tcp))[0..uv.uv_handle_size(uv.UV_TCP)]);
}
fn freeWrite(req: *uv.uv_write_t) void {
    alloc.free(@as([*]align(8) u8, @ptrCast(req))[0..uv.uv_req_size(uv.UV_WRITE)]);
}

var servers: std.AutoHashMapUnmanaged(i64, *Server) = .empty;
var clients: std.AutoHashMapUnmanaged(i64, *Client) = .empty;
var next_id: i64 = 1;
const Server = struct {
    tcp: *uv.uv_tcp_t,
    ctx: abi.JSContext,
    callback: abi.JSValue,
    id: i64,
    connections: usize = 0,
    max_connections: usize,
    timeout: u64,
    stopping: bool = false,
    listener_closed: bool = false,
};
const Client = struct {
    tcp: *uv.uv_tcp_t,
    timer: uv.uv_timer_t,
    server: *Server,
    id: i64,
    handles: usize = 1,
    closing: bool = false,
    paused: bool = false,
    responding: bool = false,
};
const Write = struct { req: *uv.uv_write_t, client: *Client, bytes: []u8 };
fn newId() i64 {
    const id = next_id;
    next_id += 1;
    return id;
}
fn getInt(ctx: abi.JSContext, val: abi.JSValueConst) ?i64 {
    var number: f64 = 0;
    if (!abi.jsIsNumber(val) or abi.jsToFloat64(ctx, &number, val) < 0 or !std.math.isFinite(number) or number < 0 or number > 9007199254740991 or @floor(number) != number) return null;
    return @intFromFloat(number);
}
fn propInt(ctx: abi.JSContext, obj: abi.JSValueConst, key: [:0]const u8) ?i64 {
    const value = abi.jsGetProperty(ctx, obj, key);
    defer abi.jsFreeValue(ctx, value);
    return getInt(ctx, value);
}
fn releaseServer(server: *Server) void {
    if (!server.listener_closed or server.connections != 0) return;
    _ = servers.remove(server.id);
    abi.jsFreeValue(server.ctx, server.callback);
    freeTcp(server.tcp);
    alloc.destroy(server);
    if (servers.count() == 0) servers.clearAndFree(alloc);
}
fn listenerClosed(handle: ?*uv.uv_handle_t) callconv(.c) void {
    const server: *Server = @ptrCast(@alignCast(handle.?.data));
    server.listener_closed = true;
    releaseServer(server);
}
fn clientClosed(handle: ?*uv.uv_handle_t) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(handle.?.data));
    client.handles -= 1;
    if (client.handles != 0) return;
    const server = client.server;
    server.connections -= 1;
    freeTcp(client.tcp);
    alloc.destroy(client);
    releaseServer(server);
}
fn notify(client: *Client, value: abi.JSValue) bool {
    const server = client.server;
    defer abi.jsFreeValue(server.ctx, value);
    if (server.stopping) return false;
    const id = abi.jsInt64(server.ctx, client.id);
    defer abi.jsFreeValue(server.ctx, id);
    const result = abi.jsCall(server.ctx, server.callback, abi.jsUndefined(server.ctx), &.{ id, value });
    defer abi.jsFreeValue(server.ctx, result);
    if (abi.jsIsException(result)) {
        const exception = abi.jsGetException(server.ctx);
        abi.jsFreeValue(server.ctx, exception);
        return false;
    }
    return true;
}
fn closeClient(client: *Client) void {
    if (client.closing) return;
    client.closing = true;
    _ = clients.remove(client.id);
    if (clients.count() == 0) clients.clearAndFree(alloc);
    _ = uv.uv_read_stop(@ptrCast(client.tcp));
    if (client.handles == 2) {
        _ = uv.uv_timer_stop(&client.timer);
        uv.uv_close(@ptrCast(&client.timer), clientClosed);
    }
    uv.uv_close(@ptrCast(client.tcp), clientClosed);
    _ = notify(client, abi.jsUndefined(client.server.ctx));
}
fn stopServer(server: *Server) void {
    if (server.stopping) return;
    server.stopping = true;
    // Closing mutates the client map; restart iteration after each removal.
    while (true) {
        var found: ?*Client = null;
        var iter = clients.valueIterator();
        while (iter.next()) |entry| {
            if (entry.*.server == server) {
                found = entry.*;
                break;
            }
        }
        if (found) |client| closeClient(client) else break;
    }
    uv.uv_close(@ptrCast(server.tcp), listenerClosed);
}
pub fn cleanup() void {
    var iter = servers.valueIterator();
    while (iter.next()) |server| stopServer(server.*);
}
fn timedOut(timer: ?*uv.uv_timer_t) callconv(.c) void {
    closeClient(@ptrCast(@alignCast(timer.?.data)));
}
fn allocate(_: ?*uv.uv_handle_t, _: usize, buf: [*c]uv.uv_buf_t) callconv(.c) void {
    const bytes = alloc.alloc(u8, 64 * 1024) catch {
        buf.* = .{ .base = null, .len = 0 };
        return;
    };
    buf.* = .{ .base = @ptrCast(bytes.ptr), .len = bytes.len };
}
fn read(stream: ?*uv.uv_stream_t, nread: isize, buf: [*c]const uv.uv_buf_t) callconv(.c) void {
    const client: *Client = @ptrCast(@alignCast(stream.?.data));
    defer if (buf.*.base != null) alloc.free(@as([*]u8, @ptrCast(buf.*.base))[0..buf.*.len]);
    if (nread < 0) {
        closeClient(client);
        return;
    }
    if (nread == 0) return;
    const value = abi.jsNewUint8ArrayCopy(client.server.ctx, @ptrCast(buf.*.base), @intCast(nread));
    if (abi.jsIsException(value)) {
        const err = abi.jsGetException(client.server.ctx);
        abi.jsFreeValue(client.server.ctx, err);
        closeClient(client);
        return;
    }
    if (!notify(client, value)) closeClient(client);
}
fn accept(stream: ?*uv.uv_stream_t, status: c_int) callconv(.c) void {
    if (status < 0) return;
    const server: *Server = @ptrCast(@alignCast(stream.?.data));
    const client = alloc.create(Client) catch return;
    const tcp = newTcp() catch {
        alloc.destroy(client);
        return;
    };
    client.* = .{ .tcp = tcp, .timer = undefined, .server = server, .id = newId() };
    if (uv.uv_tcp_init(uv.uv_handle_get_loop(stream.?), client.tcp) != 0) {
        freeTcp(client.tcp);
        alloc.destroy(client);
        return;
    }
    client.tcp.data = client;
    server.connections += 1;
    if (uv.uv_accept(stream, @ptrCast(client.tcp)) != 0 or server.stopping or server.connections > server.max_connections) {
        closeClient(client);
        return;
    }
    if (uv.uv_timer_init(uv.uv_handle_get_loop(stream.?), &client.timer) != 0) {
        closeClient(client);
        return;
    }
    client.handles = 2;
    client.timer.data = client;
    clients.put(alloc, client.id, client) catch {
        closeClient(client);
        return;
    };
    if (uv.uv_timer_start(&client.timer, timedOut, server.timeout, 0) != 0 or uv.uv_read_start(@ptrCast(client.tcp), allocate, read) != 0) closeClient(client);
}
pub fn serve(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    const loop = loop_module.current() orelse return ctx.api.throw_error(ctx, "http.serve requires an async loop");
    if (argc < 2) return ctx.api.throw_type_error(ctx, "Invalid server arguments");
    const js = abi.borrowContext(ctx);
    const options = abi.borrowValue(ctx, argv[0]) orelse return ctx.api.throw_type_error(ctx, "Invalid options");
    const callback = abi.borrowValue(ctx, argv[1]) orelse return ctx.api.throw_type_error(ctx, "Invalid callback");
    if (!abi.jsIsFunction(js, callback)) return ctx.api.throw_type_error(ctx, "Expected server callback");
    const port = propInt(js, options, "port") orelse return ctx.api.throw_type_error(ctx, "Invalid port");
    const max_connections = propInt(js, options, "maxConnections") orelse return ctx.api.throw_type_error(ctx, "Invalid connection limit");
    const timeout = propInt(js, options, "requestTimeoutMs") orelse return ctx.api.throw_type_error(ctx, "Invalid timeout");
    if (port > 65535 or max_connections < 1 or max_connections > 1024 or timeout < 1 or timeout > 3600000) return ctx.api.throw_type_error(ctx, "Invalid server limits");
    const hostname_value = abi.jsGetProperty(js, options, "hostname");
    defer abi.jsFreeValue(js, hostname_value);
    const hostname = abi.jsStringAlloc(js, hostname_value, alloc) catch return ctx.api.throw_type_error(ctx, "Invalid hostname");
    defer alloc.free(hostname);
    const host_z = alloc.dupeZ(u8, hostname) catch return ctx.api.throw_error(ctx, "Out of memory");
    defer alloc.free(host_z);
    if (std.mem.indexOfScalar(u8, hostname, 0) != null) return ctx.api.throw_type_error(ctx, "Invalid hostname");
    var address: [128]u8 align(8) = undefined;
    if (uv.uv_ip4_addr(host_z, @intCast(port), &address) != 0) return ctx.api.throw_type_error(ctx, "hostname must be an IPv4 address");
    const server = alloc.create(Server) catch return ctx.api.throw_error(ctx, "Out of memory");
    const tcp = newTcp() catch {
        alloc.destroy(server);
        return ctx.api.throw_error(ctx, "Out of memory");
    };
    server.* = .{ .tcp = tcp, .ctx = js, .callback = abi.jsDupValue(js, callback), .id = newId(), .max_connections = @intCast(max_connections), .timeout = @intCast(timeout) };
    if (uv.uv_tcp_init(@ptrCast(loop.loop), server.tcp) != 0) {
        abi.jsFreeValue(js, server.callback);
        freeTcp(server.tcp);
        alloc.destroy(server);
        return ctx.api.throw_error(ctx, "Could not create server");
    }
    server.tcp.data = server;
    servers.put(alloc, server.id, server) catch {
        stopServer(server);
        return ctx.api.throw_error(ctx, "Out of memory");
    };
    if (uv.uv_tcp_bind(server.tcp, @ptrCast(&address), 0) != 0 or uv.uv_listen(@ptrCast(server.tcp), 128, accept) != 0) {
        stopServer(server);
        return ctx.api.throw_error(ctx, "Could not bind/listen on HTTP port");
    }
    var length: c_int = address.len;
    if (uv.uv_tcp_getsockname(server.tcp, @ptrCast(&address), &length) != 0) {
        stopServer(server);
        return ctx.api.throw_error(ctx, "Could not get server address");
    }
    const result = abi.jsNewObject(js);
    abi.jsSetPropertyChecked(js, result, "id", abi.jsInt64(js, server.id)) catch {
        stopServer(server);
        return ctx.api.throw_error(ctx, "Out of memory");
    };
    abi.jsSetPropertyChecked(js, result, "port", abi.jsInt32(js, std.mem.readInt(u16, address[2..4], .big))) catch {
        stopServer(server);
        return ctx.api.throw_error(ctx, "Out of memory");
    };
    return abi.adoptValue(ctx, result);
}
fn idArg(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) ?i64 {
    if (argc < 1) return null;
    return getInt(abi.borrowContext(ctx), abi.borrowValue(ctx, argv[0]) orelse return null);
}
pub fn stop(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    if (idArg(ctx, argc, argv)) |id| {
        if (servers.get(id)) |server| stopServer(server);
    }
    return ctx.api.undefined(ctx);
}
pub fn pause(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    if (idArg(ctx, argc, argv)) |id| {
        if (clients.get(id)) |client| {
            client.paused = true;
            _ = uv.uv_read_stop(@ptrCast(client.tcp));
        }
    }
    return ctx.api.undefined(ctx);
}
fn copyBytes(ctx: abi.JSContext, value: abi.JSValueConst) ![]u8 {
    var offset: usize = 0;
    var size: usize = 0;
    const buffer = abi.jsGetTypedArrayBuffer(ctx, value, &offset, &size);
    defer abi.jsFreeValue(ctx, buffer);
    if (abi.jsIsException(buffer)) return error.InvalidBytes;
    var length: usize = 0;
    const pointer = abi.jsGetArrayBuffer(ctx, &length, buffer) orelse return error.InvalidBytes;
    if (offset > length or size > length - offset) return error.InvalidBytes;
    return alloc.dupe(u8, pointer[offset..][0..size]);
}
fn written(req: ?*uv.uv_write_t, _: c_int) callconv(.c) void {
    const write: *Write = @ptrCast(@alignCast(req.?.data));
    closeClient(write.client);
    alloc.free(write.bytes);
    freeWrite(write.req);
    alloc.destroy(write);
}
pub fn respond(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    const id = idArg(ctx, argc, argv) orelse return ctx.api.throw_type_error(ctx, "Invalid connection");
    const client = clients.get(id) orelse return ctx.api.bool_value(ctx, 0);
    if (client.responding) return ctx.api.bool_value(ctx, 0);
    if (argc < 2) return ctx.api.throw_type_error(ctx, "Missing response");
    const js = abi.borrowContext(ctx);
    const data = copyBytes(js, abi.borrowValue(ctx, argv[1]).?) catch return ctx.api.throw_type_error(ctx, "Expected bytes");
    const write = alloc.create(Write) catch {
        alloc.free(data);
        closeClient(client);
        return ctx.api.throw_error(ctx, "Out of memory");
    };
    const req: *uv.uv_write_t = @ptrCast(alloc.alignedAlloc(u8, .@"8", uv.uv_req_size(uv.UV_WRITE)) catch {
        alloc.free(data);
        alloc.destroy(write);
        closeClient(client);
        return ctx.api.throw_error(ctx, "Out of memory");
    });
    client.responding = true;
    write.* = .{ .req = req, .client = client, .bytes = data };
    write.req.data = write;
    _ = uv.uv_read_stop(@ptrCast(client.tcp));
    var buf: uv.uv_buf_t = .{ .base = @ptrCast(data.ptr), .len = data.len };
    if (uv.uv_write(write.req, @ptrCast(client.tcp), @ptrCast(&buf), 1, written) != 0) {
        alloc.free(data);
        freeWrite(write.req);
        alloc.destroy(write);
        closeClient(client);
    }
    return ctx.api.bool_value(ctx, 1);
}
pub fn encode(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    if (argc < 1) return ctx.api.throw_type_error(ctx, "Expected text");
    const js = abi.borrowContext(ctx);
    const data = abi.jsStringAlloc(js, abi.borrowValue(ctx, argv[0]).?, alloc) catch return ctx.api.throw_type_error(ctx, "Expected text");
    defer alloc.free(data);
    return abi.adoptValue(ctx, abi.jsNewUint8ArrayCopy(js, data.ptr, data.len));
}
pub fn decode(ctx: *abi.Context, argc: c_int, argv: [*c]const abi.Value) callconv(.c) abi.Value {
    if (argc < 1) return ctx.api.throw_type_error(ctx, "Expected bytes");
    const js = abi.borrowContext(ctx);
    const data = copyBytes(js, abi.borrowValue(ctx, argv[0]).?) catch return ctx.api.throw_type_error(ctx, "Expected bytes");
    defer alloc.free(data);
    return abi.adoptValue(ctx, abi.jsString(js, data));
}
