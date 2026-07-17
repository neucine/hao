const std = @import("std");
const async_loop = @import("../../async/loop.zig");
const native_module = @import("../../js/abi.zig");
const qjs = @import("../../qjs.zig");
const uv = @import("../../async/uv.zig").c;

const http = std.http;
const alloc = std.heap.page_allocator;

pub const specifier: [:0]const u8 = "hao:http/native";

var current_io: ?std.Io = null;

const HeaderPair = struct {
    name: []u8,
    value: []u8,
};

const HttpRequestOptions = struct {
    url: []u8,
    method: http.Method,
    headers: []HeaderPair,
    body_text: ?[]u8 = null,
    body_bytes: ?[]u8 = null,

    fn deinit(self: *HttpRequestOptions) void {
        alloc.free(self.url);
        for (self.headers) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        alloc.free(self.headers);
        if (self.body_text) |body| alloc.free(body);
        if (self.body_bytes) |body| alloc.free(body);
    }
};

const HttpResponseData = struct {
    final_url: []u8,
    status: http.Status,
    reason: []u8,
    headers: []HeaderPair,
    body_bytes: []u8,

    fn deinit(self: *HttpResponseData) void {
        alloc.free(self.final_url);
        alloc.free(self.reason);
        for (self.headers) |header| {
            alloc.free(header.name);
            alloc.free(header.value);
        }
        alloc.free(self.headers);
        alloc.free(self.body_bytes);
    }
};

const HttpRequestResult = union(enum) {
    pending,
    success: HttpResponseData,
    failure: []u8,
};

const HttpRequestOp = struct {
    req: uv.uv_work_t,
    ctx: ?*qjs.c.JSContext,
    resolve: qjs.c.JSValue,
    reject: qjs.c.JSValue,
    request: HttpRequestOptions,
    io: std.Io,
    allocator: std.mem.Allocator,
    result: HttpRequestResult = .pending,

    fn destroy(self: *HttpRequestOp) void {
        qjs.freeValue(self.ctx, self.resolve);
        qjs.freeValue(self.ctx, self.reject);
        self.request.deinit();
        switch (self.result) {
            .success => |*response| response.deinit(),
            .failure => |msg| alloc.free(msg),
            .pending => {},
        }
        self.allocator.destroy(self);
    }
};

const functions = [_]native_module.LegacyFunction{
    .{ .name = "requestNative", .function = jsRequest, .length = 1 },
};

pub fn attachIo(io: std.Io) void {
    current_io = io;
}

pub fn detachIo() void {
    current_io = null;
}

pub fn load(ctx: ?*qjs.c.JSContext, module_name: [*c]const u8) ?*qjs.c.JSModuleDef {
    return native_module.createLegacyFunctionModule(ctx, module_name, init, &functions);
}

fn init(ctx: ?*qjs.c.JSContext, module: ?*qjs.c.JSModuleDef) callconv(.c) c_int {
    return native_module.bindLegacyFunctionExports(ctx, module, &functions);
}

fn throwType(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowTypeError(ctx, message.ptr);
}

fn throwInternal(ctx: ?*qjs.c.JSContext, message: [:0]const u8) qjs.c.JSValue {
    return qjs.c.JS_ThrowInternalError(ctx, message.ptr);
}

fn throwError(ctx: ?*qjs.c.JSContext, message: []const u8) qjs.c.JSValue {
    const message_z = alloc.dupeZ(u8, message) catch return qjs.c.JS_ThrowOutOfMemory(ctx);
    defer alloc.free(message_z);
    return qjs.c.JS_ThrowInternalError(ctx, message_z.ptr);
}

fn jsRequest(ctx: ?*qjs.c.JSContext, _: qjs.c.JSValueConst, argc: c_int, argv: [*c]qjs.c.JSValueConst) callconv(.c) qjs.c.JSValue {
    const io = current_io orelse return throwInternal(ctx, "http.request requires attached IO");
    if (argc < 1 or !qjs.isObject(argv[0])) {
        return throwType(ctx, "http.request requires an options object");
    }

    if (async_loop.current()) |_| {
        return jsRequestAsync(ctx, argv[0], io);
    }

    var request = parseRequestOptions(ctx, argv[0]) catch {
        return throwType(ctx, "http.request options are invalid");
    };
    defer request.deinit();

    var response = performRequest(io, &request) catch {
        return throwInternal(ctx, "http.request error");
    };
    defer response.deinit();

    return makeResponseObject(ctx, &response);
}

fn jsRequestAsync(ctx: ?*qjs.c.JSContext, options: qjs.c.JSValueConst, io: std.Io) qjs.c.JSValue {
    const loop = async_loop.current() orelse return throwInternal(ctx, "http.request requires an attached async loop");

    const request = parseRequestOptions(ctx, options) catch {
        return throwType(ctx, "http.request options are invalid");
    };

    var funcs: [2]qjs.c.JSValue = undefined;
    const promise = qjs.c.JS_NewPromiseCapability(ctx, &funcs);
    if (qjs.isException(promise)) {
        var request_copy = request;
        request_copy.deinit();
        return promise;
    }
    defer qjs.freeValue(ctx, funcs[0]);
    defer qjs.freeValue(ctx, funcs[1]);

    const op = loop.allocator.create(HttpRequestOp) catch {
        var request_copy = request;
        request_copy.deinit();
        qjs.freeValue(ctx, promise);
        return qjs.c.JS_ThrowOutOfMemory(ctx);
    };
    op.* = .{
        .req = std.mem.zeroes(uv.uv_work_t),
        .ctx = ctx,
        .resolve = qjs.dupValue(ctx, funcs[0]),
        .reject = qjs.dupValue(ctx, funcs[1]),
        .request = request,
        .io = io,
        .allocator = loop.allocator,
    };
    op.req.data = op;

    if (uv.uv_queue_work(loop.loop, &op.req, onRequestWork, onRequestDone) != 0) {
        op.destroy();
        qjs.freeValue(ctx, promise);
        return throwInternal(ctx, "http.request error");
    }

    return promise;
}

fn parseRequestOptions(ctx: ?*qjs.c.JSContext, options: qjs.c.JSValueConst) !HttpRequestOptions {
    const url = try getOptionalStringPropAlloc(ctx, options, "url") orelse return error.MissingArgument;
    errdefer alloc.free(url);

    const method_name = try getOptionalStringPropAlloc(ctx, options, "method") orelse return error.MissingArgument;
    defer alloc.free(method_name);

    const headers = try parseHeaders(ctx, options);
    errdefer freeHeaders(headers);

    const body_text = try getOptionalStringPropAlloc(ctx, options, "bodyText");
    errdefer if (body_text) |body| alloc.free(body);

    const body_bytes = try parseOptionalBodyBytes(ctx, options);
    errdefer if (body_bytes) |body| alloc.free(body);

    return .{
        .url = url,
        .method = parseMethod(method_name) catch return error.InvalidArgument,
        .headers = headers,
        .body_text = body_text,
        .body_bytes = body_bytes,
    };
}

fn parseMethod(name: []const u8) !http.Method {
    return std.meta.stringToEnum(http.Method, name) orelse error.InvalidArgument;
}

fn getOptionalStringPropAlloc(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, key: [:0]const u8) !?[]u8 {
    const value = qjs.getProperty(ctx, obj, key);
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return null;
    return try qjs.valueToStringAlloc(ctx, value, alloc);
}

fn freeHeaders(headers: []HeaderPair) void {
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

fn parseHeaders(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst) ![]HeaderPair {
    const value = qjs.getProperty(ctx, obj, "headers");
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return alloc.alloc(HeaderPair, 0);
    if (!qjs.isObject(value)) return error.InvalidArgument;

    const length_value = qjs.getProperty(ctx, value, "length");
    defer qjs.freeValue(ctx, length_value);
    var length: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &length, length_value) < 0 or length < 0) return error.InvalidArgument;

    const out = try alloc.alloc(HeaderPair, @intCast(length));
    errdefer alloc.free(out);
    var built: usize = 0;
    errdefer {
        for (out[0..built]) |item| {
            alloc.free(item.name);
            alloc.free(item.value);
        }
    }

    for (out, 0..) |*item, i| {
        const pair_value = qjs.c.JS_GetPropertyUint32(ctx, value, @intCast(i));
        defer qjs.freeValue(ctx, pair_value);
        if (!qjs.isObject(pair_value)) return error.InvalidArgument;

        const name_value = qjs.c.JS_GetPropertyUint32(ctx, pair_value, 0);
        defer qjs.freeValue(ctx, name_value);
        const header_value = qjs.c.JS_GetPropertyUint32(ctx, pair_value, 1);
        defer qjs.freeValue(ctx, header_value);

        item.* = .{
            .name = try qjs.valueToStringAlloc(ctx, name_value, alloc),
            .value = try qjs.valueToStringAlloc(ctx, header_value, alloc),
        };
        built += 1;
    }
    return out;
}

fn parseOptionalBodyBytes(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst) !?[]u8 {
    const value = qjs.getProperty(ctx, obj, "bodyBytes");
    defer qjs.freeValue(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return null;

    var offset: usize = 0;
    var size: usize = 0;
    const buffer = qjs.c.JS_GetTypedArrayBuffer(ctx, value, &offset, &size, null);
    if (qjs.isException(buffer)) {
        qjs.freeValue(ctx, buffer);
        return error.InvalidArgument;
    }
    defer qjs.freeValue(ctx, buffer);

    var buffer_size: usize = 0;
    const ptr = qjs.c.JS_GetArrayBuffer(ctx, &buffer_size, buffer) orelse return error.InvalidArgument;
    const bytes: [*]const u8 = @ptrCast(ptr);
    if (offset > buffer_size or size > buffer_size - offset) return error.InvalidArgument;
    return try alloc.dupe(u8, bytes[offset .. offset + size]);
}

fn performRequest(io: std.Io, request: *const HttpRequestOptions) !HttpResponseData {
    var client: http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(request.url);
    var zig_headers = try alloc.alloc(http.Header, request.headers.len);
    defer alloc.free(zig_headers);
    for (request.headers, 0..) |header, i| {
        zig_headers[i] = .{ .name = header.name, .value = header.value };
    }

    var req = try client.request(request.method, uri, .{
        .headers = .{},
        .extra_headers = zig_headers,
        .redirect_behavior = http.Client.Request.RedirectBehavior.init(3),
    });
    defer req.deinit();

    const payload = request.body_bytes orelse request.body_text;
    if (payload) |body| {
        req.transfer_encoding = .{ .content_length = body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();
    } else {
        try req.sendBodiless();
    }

    var redirect_buffer: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    const reason = try alloc.dupe(u8, response.head.reason);
    errdefer alloc.free(reason);

    var uri_buf: std.ArrayList(u8) = .empty;
    defer uri_buf.deinit(alloc);
    try uri_buf.print(alloc, "{f}", .{req.uri});
    const final_uri = try uri_buf.toOwnedSlice(alloc);
    errdefer alloc.free(final_uri);

    var header_list: std.ArrayList(HeaderPair) = .empty;
    defer header_list.deinit(alloc);
    var iter = response.head.iterateHeaders();
    while (iter.next()) |header| {
        try header_list.append(alloc, .{
            .name = try alloc.dupe(u8, header.name),
            .value = try alloc.dupe(u8, header.value),
        });
    }
    const headers = try header_list.toOwnedSlice(alloc);
    errdefer freeHeaders(headers);

    var body_writer: std.Io.Writer.Allocating = .init(alloc);
    defer body_writer.deinit();
    var transfer_buffer: [64]u8 = undefined;
    var decompress: http.Decompress = undefined;
    const decompress_buffer = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(decompress_buffer);

    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    _ = reader.streamRemaining(&body_writer.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr() orelse error.Unexpected,
        else => return err,
    };

    const body_bytes = try body_writer.toOwnedSlice();
    return .{
        .final_url = final_uri,
        .status = response.head.status,
        .reason = reason,
        .headers = headers,
        .body_bytes = body_bytes,
    };
}

fn onRequestWork(req: ?*uv.uv_work_t) callconv(.c) void {
    const op: *HttpRequestOp = @ptrCast(@alignCast(req.?.data));
    const response = performRequest(op.io, &op.request) catch |err| {
        op.result = .{ .failure = std.fmt.allocPrint(alloc, "http.request error: {s}", .{@errorName(err)}) catch @panic("alloc failed") };
        return;
    };
    op.result = .{ .success = response };
}

fn onRequestDone(req: ?*uv.uv_work_t, _: c_int) callconv(.c) void {
    const op: *HttpRequestOp = @ptrCast(@alignCast(req.?.data));
    defer op.destroy();

    const undef = qjs.undefinedValue(op.ctx);
    switch (op.result) {
        .success => |*response| {
            const value = makeResponseObject(op.ctx, response);
            if (qjs.isException(value)) return;
            defer qjs.freeValue(op.ctx, value);
            const args = [_]qjs.c.JSValueConst{value};
            const resolve_result = qjs.call(op.ctx, op.resolve, undef, &args);
            qjs.freeValue(op.ctx, resolve_result);
        },
        .failure => |message| {
            const err = throwError(op.ctx, message);
            if (qjs.isException(err)) {
                const exception = qjs.c.JS_GetException(op.ctx);
                defer qjs.freeValue(op.ctx, exception);
                const args = [_]qjs.c.JSValueConst{exception};
                const reject_result = qjs.call(op.ctx, op.reject, undef, &args);
                qjs.freeValue(op.ctx, reject_result);
            }
        },
        .pending => {},
    }
}

fn appendHeaderValue(ctx: ?*qjs.c.JSContext, headers_obj: qjs.c.JSValueConst, name: []const u8, value: []const u8) !void {
    const key = try alloc.dupeZ(u8, name);
    defer alloc.free(key);

    const existing = qjs.getProperty(ctx, headers_obj, key);
    defer qjs.freeValue(ctx, existing);
    if (qjs.isUndefined(existing)) {
        try qjs.setProperty(ctx, headers_obj, key, qjs.createString(ctx, value));
        return;
    }

    if (!qjs.isArray(ctx, existing)) {
        const array = qjs.c.JS_NewArray(ctx);
        if (qjs.isException(array)) return error.JavaScriptError;
        errdefer qjs.freeValue(ctx, array);
        if (qjs.c.JS_SetPropertyUint32(ctx, array, 0, qjs.dupValue(ctx, existing)) < 0) return error.JavaScriptError;
        if (qjs.c.JS_SetPropertyUint32(ctx, array, 1, qjs.createString(ctx, value)) < 0) return error.JavaScriptError;
        try qjs.setProperty(ctx, headers_obj, key, array);
        return;
    }

    const length_value = qjs.getProperty(ctx, existing, "length");
    defer qjs.freeValue(ctx, length_value);
    var length: i32 = 0;
    if (qjs.c.JS_ToInt32(ctx, &length, length_value) < 0 or length < 0) return error.JavaScriptError;
    if (qjs.c.JS_SetPropertyUint32(ctx, existing, @intCast(length), qjs.createString(ctx, value)) < 0) return error.JavaScriptError;
}

fn responseHeadersObject(ctx: ?*qjs.c.JSContext, headers: []const HeaderPair) !qjs.c.JSValue {
    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj)) return error.JavaScriptError;
    errdefer qjs.freeValue(ctx, obj);

    for (headers) |header| {
        try appendHeaderValue(ctx, obj, header.name, header.value);
    }
    return obj;
}

fn makeResponseObject(ctx: ?*qjs.c.JSContext, response: *HttpResponseData) qjs.c.JSValue {
    const obj = qjs.newObject(ctx);
    if (qjs.isException(obj)) return obj;
    errdefer qjs.freeValue(ctx, obj);

    qjs.setProperty(ctx, obj, "status", qjs.c.JS_NewInt32(ctx, @intCast(@intFromEnum(response.status)))) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "statusText", qjs.createString(ctx, response.reason)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "ok", qjs.boolValue(ctx, @intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "url", qjs.createString(ctx, response.final_url)) catch return qjs.exceptionValue();
    qjs.setProperty(ctx, obj, "bodyText", qjs.createString(ctx, response.body_bytes)) catch return qjs.exceptionValue();

    const headers = responseHeadersObject(ctx, response.headers) catch return qjs.exceptionValue();
    trySetOwned(ctx, obj, "headers", headers);

    const body_bytes: [*]const u8 = if (response.body_bytes.len == 0) undefined else response.body_bytes.ptr;
    const bytes_value = qjs.c.JS_NewUint8ArrayCopy(ctx, if (response.body_bytes.len == 0) null else body_bytes, response.body_bytes.len);
    if (qjs.isException(bytes_value)) return qjs.exceptionValue();
    trySetOwned(ctx, obj, "bodyBytes", bytes_value);

    return obj;
}

fn trySetOwned(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, key: [:0]const u8, value: qjs.c.JSValue) void {
    qjs.setProperty(ctx, obj, key, value) catch {
        qjs.freeValue(ctx, value);
    };
}

test "hao http native module can be created" {
    var runtime = try qjs.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
