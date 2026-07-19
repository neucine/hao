const std = @import("std");
const async_loop = @import("../../async/loop.zig");
const js_abi = @import("../../js/abi.zig");
const qjs_test = @import("../../qjs.zig");
// QuickJS access is kept behind the public JS ABI.

const runtime_allocator = @import("../../runtime_allocator.zig");
const trace = @import("../../telemetry/trace.zig");
const uv = @import("../../async/uv.zig").c;

const http = std.http;
const alloc = runtime_allocator.allocator();

pub const specifier: [:0]const u8 = "std:http/native";

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
    ctx: js_abi.JSContext,
    resolve: js_abi.JSValue,
    reject: js_abi.JSValue,
    request: HttpRequestOptions,
    io: std.Io,
    allocator: std.mem.Allocator,
    context: trace.Context,
    result: HttpRequestResult = .pending,

    fn destroy(self: *HttpRequestOp) void {
        js_abi.jsFreeValue(self.ctx, self.resolve);
        js_abi.jsFreeValue(self.ctx, self.reject);
        self.request.deinit();
        switch (self.result) {
            .success => |*response| response.deinit(),
            .failure => |msg| alloc.free(msg),
            .pending => {},
        }
        self.allocator.destroy(self);
    }
};

const functions = [_]js_abi.Function{
    .{ .name = "requestNative", .callback = jsRequest, .length = 1 },
    .{ .name = null, .callback = jsRequest },
};
const function_ptrs = [_]*const js_abi.Function{
    &functions[0],
};

pub fn attachIo(io: std.Io) void {
    current_io = io;
}

pub fn detachIo() void {
    current_io = null;
}

pub fn load(ctx: ?*anyopaque, module_name: [*c]const u8) ?*anyopaque {
    return @ptrCast(js_abi.createFunctionModule(runtime_allocator.allocator(), @ptrCast(ctx), module_name, &function_ptrs));
}

fn throwType(ctx: js_abi.JSContext, message: [:0]const u8) js_abi.JSValue {
    return js_abi.jsThrowTypeError(ctx, message.ptr);
}

fn throwInternal(ctx: js_abi.JSContext, message: [:0]const u8) js_abi.JSValue {
    return js_abi.jsThrowInternalError(ctx, message.ptr);
}

fn throwError(ctx: js_abi.JSContext, message: []const u8) js_abi.JSValue {
    const message_z = alloc.dupeZ(u8, message) catch return js_abi.jsThrowOutOfMemory(ctx);
    defer alloc.free(message_z);
    return js_abi.jsThrowInternalError(ctx, message_z.ptr);
}

fn jsRequest(ctx: *js_abi.Context, argc: c_int, argv: [*c]const js_abi.Value) callconv(.c) js_abi.Value {
    const qjs_ctx = js_abi.borrowContext(ctx);
    const io = current_io orelse return ctx.api.throw_error(ctx, "http.request requires attached IO");
    if (argc < 1 or ctx.api.is_object(ctx, argv[0]) == 0) {
        return ctx.api.throw_type_error(ctx, "http.request requires an options object");
    }
    const options = js_abi.borrowValue(ctx, argv[0]) orelse return ctx.api.throw_error(ctx, "http.request invalid options");

    if (async_loop.current()) |_| {
        return js_abi.adoptValue(ctx, jsRequestAsync(qjs_ctx, options, io));
    }

    var request = parseRequestOptions(qjs_ctx, options) catch {
        return ctx.api.throw_type_error(ctx, "http.request options are invalid");
    };
    defer request.deinit();

    var response = performRequest(io, &request) catch {
        return ctx.api.throw_error(ctx, "http.request error");
    };
    defer response.deinit();

    return js_abi.adoptValue(ctx, makeResponseObject(qjs_ctx, &response));
}

fn jsRequestAsync(ctx: js_abi.JSContext, options: js_abi.JSValueConst, io: std.Io) js_abi.JSValue {
    const loop = async_loop.current() orelse return throwInternal(ctx, "http.request requires an attached async loop");

    const request = parseRequestOptions(ctx, options) catch {
        return throwType(ctx, "http.request options are invalid");
    };

    var funcs: [2]js_abi.JSValue = undefined;
    const promise = js_abi.jsNewPromiseCapability(ctx, &funcs);
    if (js_abi.jsIsException(promise)) {
        var request_copy = request;
        request_copy.deinit();
        return promise;
    }
    defer js_abi.jsFreeValue(ctx, funcs[0]);
    defer js_abi.jsFreeValue(ctx, funcs[1]);

    const op = loop.allocator.create(HttpRequestOp) catch {
        var request_copy = request;
        request_copy.deinit();
        js_abi.jsFreeValue(ctx, promise);
        return js_abi.jsThrowOutOfMemory(ctx);
    };
    op.* = .{
        .req = std.mem.zeroes(uv.uv_work_t),
        .ctx = ctx,
        .resolve = js_abi.jsDupValue(ctx, funcs[0]),
        .reject = js_abi.jsDupValue(ctx, funcs[1]),
        .request = request,
        .io = io,
        .allocator = loop.allocator,
        .context = trace.currentContext(),
    };
    op.req.data = op;

    if (uv.uv_queue_work(loop.loop, &op.req, onRequestWork, onRequestDone) != 0) {
        op.destroy();
        js_abi.jsFreeValue(ctx, promise);
        return throwInternal(ctx, "http.request error");
    }

    return promise;
}

fn parseRequestOptions(ctx: js_abi.JSContext, options: js_abi.JSValueConst) !HttpRequestOptions {
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

fn getOptionalStringPropAlloc(ctx: js_abi.JSContext, obj: js_abi.JSValueConst, key: [:0]const u8) !?[]u8 {
    const value = js_abi.jsGetProperty(ctx, obj, key);
    defer js_abi.jsFreeValue(ctx, value);
    if (js_abi.jsIsUndefined(value) or js_abi.jsIsNull(value)) return null;
    return try js_abi.jsStringAlloc(ctx, value, alloc);
}

fn freeHeaders(headers: []HeaderPair) void {
    for (headers) |header| {
        alloc.free(header.name);
        alloc.free(header.value);
    }
    alloc.free(headers);
}

fn parseHeaders(ctx: js_abi.JSContext, obj: js_abi.JSValueConst) ![]HeaderPair {
    const value = js_abi.jsGetProperty(ctx, obj, "headers");
    defer js_abi.jsFreeValue(ctx, value);
    if (js_abi.jsIsUndefined(value) or js_abi.jsIsNull(value)) return alloc.alloc(HeaderPair, 0);
    if (!js_abi.jsIsObject(value)) return error.InvalidArgument;

    const length_value = js_abi.jsGetProperty(ctx, value, "length");
    defer js_abi.jsFreeValue(ctx, length_value);
    var length: i32 = 0;
    if (js_abi.jsToInt32(ctx, &length, length_value) < 0 or length < 0) return error.InvalidArgument;

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
        const pair_value = js_abi.jsGetArrayElement(ctx, value, @intCast(i));
        defer js_abi.jsFreeValue(ctx, pair_value);
        if (!js_abi.jsIsObject(pair_value)) return error.InvalidArgument;

        const name_value = js_abi.jsGetArrayElement(ctx, pair_value, 0);
        defer js_abi.jsFreeValue(ctx, name_value);
        const header_value = js_abi.jsGetArrayElement(ctx, pair_value, 1);
        defer js_abi.jsFreeValue(ctx, header_value);

        item.* = .{
            .name = try js_abi.jsStringAlloc(ctx, name_value, alloc),
            .value = try js_abi.jsStringAlloc(ctx, header_value, alloc),
        };
        built += 1;
    }
    return out;
}

fn parseOptionalBodyBytes(ctx: js_abi.JSContext, obj: js_abi.JSValueConst) !?[]u8 {
    const value = js_abi.jsGetProperty(ctx, obj, "bodyBytes");
    defer js_abi.jsFreeValue(ctx, value);
    if (js_abi.jsIsUndefined(value) or js_abi.jsIsNull(value)) return null;

    var offset: usize = 0;
    var size: usize = 0;
    const buffer = js_abi.jsGetTypedArrayBuffer(ctx, value, &offset, &size);
    if (js_abi.jsIsException(buffer)) {
        js_abi.jsFreeValue(ctx, buffer);
        return error.InvalidArgument;
    }
    defer js_abi.jsFreeValue(ctx, buffer);

    var buffer_size: usize = 0;
    const ptr = js_abi.jsGetArrayBuffer(ctx, &buffer_size, buffer) orelse return error.InvalidArgument;
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
    var context_scope = trace.ContextScope.enter(op.context);
    defer context_scope.exit();
    const response = performRequest(op.io, &op.request) catch |err| {
        op.result = .{ .failure = std.fmt.allocPrint(alloc, "http.request error: {s}", .{@errorName(err)}) catch @panic("alloc failed") };
        return;
    };
    op.result = .{ .success = response };
}

fn onRequestDone(req: ?*uv.uv_work_t, _: c_int) callconv(.c) void {
    const op: *HttpRequestOp = @ptrCast(@alignCast(req.?.data));
    defer op.destroy();
    var context_scope = trace.ContextScope.enter(op.context);
    defer context_scope.exit();

    const undef = js_abi.jsUndefined(op.ctx);
    switch (op.result) {
        .success => |*response| {
            const value = makeResponseObject(op.ctx, response);
            if (js_abi.jsIsException(value)) return;
            defer js_abi.jsFreeValue(op.ctx, value);
            const args = [_]js_abi.JSValueConst{value};
            const resolve_result = js_abi.jsCall(op.ctx, op.resolve, undef, &args);
            js_abi.jsFreeValue(op.ctx, resolve_result);
        },
        .failure => |message| {
            const err = throwError(op.ctx, message);
            if (js_abi.jsIsException(err)) {
                const exception = js_abi.jsGetException(op.ctx);
                defer js_abi.jsFreeValue(op.ctx, exception);
                const args = [_]js_abi.JSValueConst{exception};
                const reject_result = js_abi.jsCall(op.ctx, op.reject, undef, &args);
                js_abi.jsFreeValue(op.ctx, reject_result);
            }
        },
        .pending => {},
    }
}

fn appendHeaderValue(ctx: js_abi.JSContext, headers_obj: js_abi.JSValueConst, name: []const u8, value: []const u8) !void {
    const key = try alloc.dupeZ(u8, name);
    defer alloc.free(key);

    const existing = js_abi.jsGetProperty(ctx, headers_obj, key);
    defer js_abi.jsFreeValue(ctx, existing);
    if (js_abi.jsIsUndefined(existing)) {
        try js_abi.jsSetPropertyChecked(ctx, headers_obj, key, js_abi.jsString(ctx, value));
        return;
    }

    if (!js_abi.jsIsArray(ctx, existing)) {
        const array = js_abi.jsNewArray(ctx);
        if (js_abi.jsIsException(array)) return error.JavaScriptError;
        errdefer js_abi.jsFreeValue(ctx, array);
        if (js_abi.jsSetArrayIndex(ctx, array, 0, js_abi.jsDupValue(ctx, existing)) < 0) return error.JavaScriptError;
        if (js_abi.jsSetArrayIndex(ctx, array, 1, js_abi.jsString(ctx, value)) < 0) return error.JavaScriptError;
        try js_abi.jsSetPropertyChecked(ctx, headers_obj, key, array);
        return;
    }

    const length_value = js_abi.jsGetProperty(ctx, existing, "length");
    defer js_abi.jsFreeValue(ctx, length_value);
    var length: i32 = 0;
    if (js_abi.jsToInt32(ctx, &length, length_value) < 0 or length < 0) return error.JavaScriptError;
    if (js_abi.jsSetArrayIndex(ctx, existing, @intCast(length), js_abi.jsString(ctx, value)) < 0) return error.JavaScriptError;
}

fn responseHeadersObject(ctx: js_abi.JSContext, headers: []const HeaderPair) !js_abi.JSValue {
    const obj = js_abi.jsNewObject(ctx);
    if (js_abi.jsIsException(obj)) return error.JavaScriptError;
    errdefer js_abi.jsFreeValue(ctx, obj);

    for (headers) |header| {
        try appendHeaderValue(ctx, obj, header.name, header.value);
    }
    return obj;
}

fn makeResponseObject(ctx: js_abi.JSContext, response: *HttpResponseData) js_abi.JSValue {
    const obj = js_abi.jsNewObject(ctx);
    if (js_abi.jsIsException(obj)) return obj;
    errdefer js_abi.jsFreeValue(ctx, obj);

    js_abi.jsSetPropertyChecked(ctx, obj, "status", js_abi.jsInt32(ctx, @intCast(@intFromEnum(response.status)))) catch return js_abi.jsExceptionValue();
    js_abi.jsSetPropertyChecked(ctx, obj, "statusText", js_abi.jsString(ctx, response.reason)) catch return js_abi.jsExceptionValue();
    js_abi.jsSetPropertyChecked(ctx, obj, "ok", js_abi.jsBool(ctx, @intFromEnum(response.status) >= 200 and @intFromEnum(response.status) < 300)) catch return js_abi.jsExceptionValue();
    js_abi.jsSetPropertyChecked(ctx, obj, "url", js_abi.jsString(ctx, response.final_url)) catch return js_abi.jsExceptionValue();
    js_abi.jsSetPropertyChecked(ctx, obj, "bodyText", js_abi.jsString(ctx, response.body_bytes)) catch return js_abi.jsExceptionValue();

    const headers = responseHeadersObject(ctx, response.headers) catch return js_abi.jsExceptionValue();
    trySetOwned(ctx, obj, "headers", headers);

    const body_bytes: [*]const u8 = if (response.body_bytes.len == 0) undefined else response.body_bytes.ptr;
    const bytes_value = js_abi.jsNewUint8ArrayCopy(ctx, if (response.body_bytes.len == 0) null else body_bytes, response.body_bytes.len);
    if (js_abi.jsIsException(bytes_value)) return js_abi.jsExceptionValue();
    trySetOwned(ctx, obj, "bodyBytes", bytes_value);

    return obj;
}

fn trySetOwned(ctx: js_abi.JSContext, obj: js_abi.JSValueConst, key: [:0]const u8, value: js_abi.JSValue) void {
    js_abi.jsSetPropertyChecked(ctx, obj, key, value) catch {
        js_abi.jsFreeValue(ctx, value);
    };
}

test "std http native module can be created" {
    var runtime = try qjs_test.Runtime.init();
    defer runtime.deinit();

    const module = load(runtime.ctx, specifier.ptr);
    try std.testing.expect(module != null);
}
