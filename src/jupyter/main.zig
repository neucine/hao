const std = @import("std");
const builtin = @import("builtin");
const qjs = @import("../qjs.zig");
const zmq = @import("zmq.zig");
const wire = @import("wire.zig");
const connection = @import("connection.zig");
const fs = @import("../fs.zig");
const global_console = @import("../global/console.zig");
const module_runtime = @import("../module.zig");
const packages = @import("../package.zig");
const async_loop = @import("../async/loop.zig");
const global_timer = @import("../global/timer.zig");
const hao_std = @import("../std.zig");
const util_native = @import("../std/util/native.zig");

const c = @cImport({
    @cInclude("stdlib.h");
});

const alloc = std.heap.page_allocator;

// ============================================================
// Kernel state
// ============================================================

var session_id: [32]u8 = undefined;
var execution_count: u32 = 0;

// JS runtime (persistent across cells)
var runtime: qjs.Runtime = undefined;
var runtime_ready: bool = false;
var runtime_loop: async_loop.Loop = undefined;
var loader: module_runtime.Loader = undefined;
var registry: packages.Registry = undefined;
var registry_ready: bool = false;

// Sockets
var shell_sock: *anyopaque = undefined;
var control_sock: *anyopaque = undefined;
var iopub_sock: *anyopaque = undefined;
var stdin_sock: *anyopaque = undefined;
var hb_sock: *anyopaque = undefined;

var conn_info: connection.ConnectionInfo = undefined;
var running: bool = true;

fn writeStdout(bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

fn writeStderr(bytes: []const u8) void {
    std.debug.print("{s}", .{bytes});
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const resolved = c.realpath(path_z.ptr, null) orelse return error.FileNotFound;
    defer c.free(resolved);
    return try allocator.dupe(u8, std.mem.span(resolved));
}

fn selfExePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag == .macos) {
        var size: u32 = std.Io.Dir.max_path_bytes;
        var buf = try allocator.alloc(u8, size);
        errdefer allocator.free(buf);
        if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) {
            allocator.free(buf);
            buf = try allocator.alloc(u8, size);
            errdefer allocator.free(buf);
            if (std.c._NSGetExecutablePath(buf.ptr, &size) != 0) return error.ExecutablePathUnavailable;
        }
        return try allocator.realloc(buf, std.mem.indexOfScalar(u8, buf, 0) orelse size);
    }

    return realpathAlloc(allocator, "/proc/self/exe");
}

// ============================================================
// Entry point
// ============================================================

pub fn run(connection_file: []const u8) !void {
    // Parse connection file
    conn_info = try connection.parse(alloc, connection_file);

    // Open libzmq
    var z = try zmq.Zmq.open();
    defer z.deinit();

    // Create ZMQ context
    const zmq_ctx = try z.createContext();
    defer z.destroyContext(zmq_ctx);

    // Create and bind sockets
    shell_sock = try z.createSocket(zmq_ctx, zmq.ZMQ_ROUTER);
    control_sock = try z.createSocket(zmq_ctx, zmq.ZMQ_ROUTER);
    iopub_sock = try z.createSocket(zmq_ctx, zmq.ZMQ_PUB);
    stdin_sock = try z.createSocket(zmq_ctx, zmq.ZMQ_ROUTER);
    hb_sock = try z.createSocket(zmq_ctx, zmq.ZMQ_REP);

    defer {
        z.closeSocket(shell_sock);
        z.closeSocket(control_sock);
        z.closeSocket(iopub_sock);
        z.closeSocket(stdin_sock);
        z.closeSocket(hb_sock);
    }

    try z.setLinger(shell_sock, 1000);
    try z.setLinger(control_sock, 1000);
    try z.setLinger(iopub_sock, 1000);
    try z.setLinger(stdin_sock, 1000);
    try z.setLinger(hb_sock, 1000);

    var ep_buf: [128]u8 = undefined;

    const shell_ep = try conn_info.endpoint(conn_info.shell_port, &ep_buf);
    const shell_ep_z = try alloc.dupeZ(u8, shell_ep);
    defer alloc.free(shell_ep_z);
    try z.bindSocket(shell_sock, shell_ep_z);

    const control_ep = try conn_info.endpoint(conn_info.control_port, &ep_buf);
    const control_ep_z = try alloc.dupeZ(u8, control_ep);
    defer alloc.free(control_ep_z);
    try z.bindSocket(control_sock, control_ep_z);

    const iopub_ep = try conn_info.endpoint(conn_info.iopub_port, &ep_buf);
    const iopub_ep_z = try alloc.dupeZ(u8, iopub_ep);
    defer alloc.free(iopub_ep_z);
    try z.bindSocket(iopub_sock, iopub_ep_z);

    const stdin_ep = try conn_info.endpoint(conn_info.stdin_port, &ep_buf);
    const stdin_ep_z = try alloc.dupeZ(u8, stdin_ep);
    defer alloc.free(stdin_ep_z);
    try z.bindSocket(stdin_sock, stdin_ep_z);

    const hb_ep = try conn_info.endpoint(conn_info.hb_port, &ep_buf);
    const hb_ep_z = try alloc.dupeZ(u8, hb_ep);
    defer alloc.free(hb_ep_z);
    try z.bindSocket(hb_sock, hb_ep_z);

    // Initialize QuickJS
    runtime = try qjs.Runtime.init();
    runtime_ready = true;
    runtime_loop = try async_loop.Loop.init(alloc);
    async_loop.attachCurrent(&runtime_loop);
    try global_console.register(runtime.ctx);
    try global_timer.register(runtime.ctx);
    registry = packages.Registry.init(alloc);
    registry_ready = true;
    try hao_std.register(&registry);
    loader = .{ .allocator = alloc, .registry = &registry };
    loader.install(&runtime);

    defer {
        if (runtime_ready) {
            async_loop.detachCurrent();
            global_timer.cleanup(alloc);
            runtime_loop.deinit();
            runtime.deinit();
            runtime_ready = false;
        }
        if (registry_ready) {
            registry.deinit();
            registry_ready = false;
        }
    }

    // Generate session ID
    wire.generateId(&session_id);

    writeStderr("hao kernel started\n");

    // Message loop
    var poll_items = [_]zmq.zmq_pollitem_t{
        .{ .socket = hb_sock, .events = zmq.ZMQ_POLLIN },
        .{ .socket = control_sock, .events = zmq.ZMQ_POLLIN },
        .{ .socket = shell_sock, .events = zmq.ZMQ_POLLIN },
    };

    while (running) {
        const rc = z.poll(&poll_items, 3, -1);
        if (rc < 0) break;

        // Heartbeat: echo back
        if (poll_items[0].revents & zmq.ZMQ_POLLIN != 0) {
            var msg: zmq.zmq_msg_t = .{};
            const data = z.recvFrame(hb_sock, &msg, 0) catch continue;
            z.sendFrame(hb_sock, data, 0) catch {};
            _ = z.msg_close(&msg);
        }

        // Control channel
        if (poll_items[1].revents & zmq.ZMQ_POLLIN != 0) {
            var msg = wire.recvMessage(&z, control_sock, alloc) catch continue;
            defer msg.deinit();
            handleControl(&z, &msg) catch |err| {
                var buf: [128]u8 = undefined;
                const warn_msg = std.fmt.bufPrint(&buf, "kernel control handler failed: {s}", .{@errorName(err)}) catch "kernel control handler failed";
                std.debug.print("{s}\n", .{warn_msg});
            };
        }

        // Shell channel
        if (poll_items[2].revents & zmq.ZMQ_POLLIN != 0) {
            var msg = wire.recvMessage(&z, shell_sock, alloc) catch continue;
            defer msg.deinit();
            handleShell(&z, &msg) catch |err| {
                var buf: [128]u8 = undefined;
                const warn_msg = std.fmt.bufPrint(&buf, "kernel shell handler failed: {s}", .{@errorName(err)}) catch "kernel shell handler failed";
                std.debug.print("{s}\n", .{warn_msg});
            };
        }
    }

    writeStderr("hao kernel shutting down\n");
}

// ============================================================
// Handler dispatch
// ============================================================

fn handleControl(z: *const zmq.Zmq, msg: *wire.Message) !void {
    const msg_type = wire.jsonExtractString(msg.header, "msg_type") orelse return;

    if (std.mem.eql(u8, msg_type, "shutdown_request")) {
        try sendReply(z, control_sock, msg, "shutdown_reply",
            \\{"status": "ok", "restart": false}
        );
        running = false;
    }
}

fn handleShell(z: *const zmq.Zmq, msg: *wire.Message) !void {
    const msg_type = wire.jsonExtractString(msg.header, "msg_type") orelse return;

    if (std.mem.eql(u8, msg_type, "kernel_info_request")) {
        try handleKernelInfo(z, msg);
    } else if (std.mem.eql(u8, msg_type, "execute_request")) {
        try handleExecute(z, msg);
    } else if (std.mem.eql(u8, msg_type, "is_complete_request")) {
        try sendReply(z, shell_sock, msg, "is_complete_reply",
            \\{"status": "complete"}
        );
    } else if (std.mem.eql(u8, msg_type, "comm_info_request")) {
        try sendReply(z, shell_sock, msg, "comm_info_reply",
            \\{"comms": {}, "status": "ok"}
        );
    }
}

// ============================================================
// kernel_info_reply
// ============================================================

fn handleKernelInfo(z: *const zmq.Zmq, msg: *wire.Message) !void {
    try publishStatus(z, msg, "busy");

    const content = comptime std.fmt.comptimePrint(
        \\{{"protocol_version": "5.3", "implementation": "hao", "implementation_version": "{s}",
        \\ "language_info": {{"name": "typescript", "version": "5.0", "mimetype": "text/typescript",
        \\  "file_extension": ".ts", "codemirror_mode": {{"name": "javascript", "typescript": true}}}},
        \\ "banner": "Hao JS - embedded TypeScript/JavaScript runtime",
        \\ "status": "ok"}}
    , .{"0.1.0"});
    try sendReply(z, shell_sock, msg, "kernel_info_reply", content);

    try publishStatus(z, msg, "idle");
}

// ============================================================
// execute_request
// ============================================================

fn handleExecute(z: *const zmq.Zmq, msg: *wire.Message) !void {
    const code_raw = wire.jsonExtractString(msg.content, "code") orelse return;
    // Unescape JSON string (e.g. \n -> newline, \" -> quote)
    const code = wire.jsonUnescapeAlloc(alloc, code_raw) catch return;
    defer alloc.free(code);

    execution_count += 1;

    // Publish status: busy
    try publishStatus(z, msg, "busy");

    // Publish execute_input
    {
        var buf: [8192]u8 = undefined;
        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(alloc);
        try jsonEscape(&escaped, code);
        const content = std.fmt.bufPrint(&buf,
            \\{{"code": "{s}", "execution_count": {d}}}
        , .{ escaped.items, execution_count }) catch return;
        try publishMessage(z, msg, "execute_input", content);
    }

    const cwd = try realpathAlloc(alloc, ".");
    defer alloc.free(cwd);
    const cell_file = try std.fmt.allocPrint(alloc, "__hao_kernel_cell_{d}.ts", .{execution_count});
    defer alloc.free(cell_file);
    const cell_path = try std.fs.path.join(alloc, &.{ cwd, cell_file });
    defer alloc.free(cell_path);

    var capture_out = std.ArrayList(u8).empty;
    defer capture_out.deinit(alloc);
    var capture_err = std.ArrayList(u8).empty;
    defer capture_err.deinit(alloc);
    global_console.capture_state = .{
        .target = .both,
        .stdout = &capture_out,
        .stderr = &capture_err,
    };
    defer global_console.capture_state = null;

    var exception_text: ?[]u8 = null;
    defer if (exception_text) |text| alloc.free(text);

    const transformed_opt: ?module_runtime.PreparedNotebookCell = module_runtime.prepareNotebookCell(&loader, &runtime, code, cell_path) catch |err| blk: {
        if (module_runtime.lastError()) |last_err| {
            exception_text = try alloc.dupe(u8, last_err);
            break :blk null;
        }
        if (err == error.JavaScriptError) {
            exception_text = formatJsException(runtime.ctx, alloc) catch try alloc.dupe(u8, "unknown error");
            break :blk null;
        }
        exception_text = try alloc.dupe(u8, @errorName(err));
        break :blk null;
    };
    defer if (transformed_opt) |prepared| prepared.deinit(alloc);

    var result = qjs.undefinedValue(runtime.ctx);
    defer qjs.freeValue(runtime.ctx, result);
    var display_value = qjs.undefinedValue(runtime.ctx);
    defer qjs.freeValue(runtime.ctx, display_value);
    var eval_source_for_diag = try alloc.dupe(u8, "");
    defer alloc.free(eval_source_for_diag);

    if (exception_text == null) {
        const transformed = transformed_opt.?;
        const notebook_safe = rewriteTopLevelDecls(transformed.code, alloc) catch try alloc.dupe(u8, transformed.code);
        defer alloc.free(notebook_safe);

        alloc.free(eval_source_for_diag);
        eval_source_for_diag = try alloc.dupe(u8, notebook_safe);
        const source_url: []const u8 = transformed.source_url;
        const source_z = try alloc.dupeZ(u8, notebook_safe);
        defer alloc.free(source_z);
        const file_name_z = try alloc.dupeZ(u8, source_url);
        defer alloc.free(file_name_z);
        result = qjs.eval(runtime.ctx, source_z, file_name_z, qjs.EvalFlags.global);
        qjs.freeValue(runtime.ctx, display_value);
        display_value = qjs.dupValue(runtime.ctx, result);
    }

    if (exception_text == null and qjs.isException(result)) {
        exception_text = formatJsException(runtime.ctx, alloc) catch try alloc.dupe(u8, "unknown error");
    } else if (exception_text == null) {
        if (isPromiseLike(runtime.ctx, result)) {
            if (try awaitNotebookPromise(&runtime, &runtime_loop, result, alloc)) |await_err| {
                defer alloc.free(await_err);
                exception_text = try alloc.dupe(u8, await_err);
            } else {
                const global = qjs.c.JS_GetGlobalObject(runtime.ctx);
                defer qjs.freeValue(runtime.ctx, global);
                const settled = qjs.getProperty(runtime.ctx, global, "__hao_nb_async_value");
                qjs.freeValue(runtime.ctx, display_value);
                display_value = settled;
            }
        }
        var idle_uv_rounds: usize = 0;
        var drain_steps: usize = 0;
        while (true) {
            drain_steps += 1;
            // Keep notebook cells responsive even if JS schedules endless microtasks.
            if (drain_steps >= 10_000) break;
            const ran_jobs = qjs.executePendingJobs(runtime.rt) catch {
                exception_text = formatJsException(runtime.ctx, alloc) catch try alloc.dupe(u8, "unknown error");
                break;
            };
            if (qjs.takeUnhandledException()) |pending| {
                defer qjs.freeValue(pending.ctx, pending.value);
                exception_text = qjs.valueToStringAlloc(pending.ctx, pending.value, alloc) catch try alloc.dupe(u8, "unknown error");
                break;
            }
            const ran_uv = runtime_loop.runNowait() catch {
                exception_text = try alloc.dupe(u8, "libuv run failed");
                break;
            };
            if (qjs.takeUnhandledException()) |pending| {
                defer qjs.freeValue(pending.ctx, pending.value);
                exception_text = qjs.valueToStringAlloc(pending.ctx, pending.value, alloc) catch try alloc.dupe(u8, "unknown error");
                break;
            }
            if (!ran_jobs and !ran_uv) break;
            if (!ran_jobs and ran_uv) {
                idle_uv_rounds += 1;
                // Avoid hanging notebook cells on long-lived libuv handles.
                if (idle_uv_rounds >= 64) break;
            } else {
                idle_uv_rounds = 0;
            }
        }
    }

    // Flush captured stdout as stream
    if (capture_out.items.len > 0) {
        var stream_buf: [16384]u8 = undefined;
        var escaped_out = std.ArrayList(u8).empty;
        defer escaped_out.deinit(alloc);
        try jsonEscape(&escaped_out, capture_out.items);
        const stream_content = std.fmt.bufPrint(&stream_buf,
            \\{{"name": "stdout", "text": "{s}"}}
        , .{escaped_out.items}) catch null;
        if (stream_content) |sc| {
            try publishMessage(z, msg, "stream", sc);
        }
    }
    if (capture_err.items.len > 0) {
        var stream_buf: [16384]u8 = undefined;
        var escaped_err_stream = std.ArrayList(u8).empty;
        defer escaped_err_stream.deinit(alloc);
        try jsonEscape(&escaped_err_stream, capture_err.items);
        const stream_content = std.fmt.bufPrint(&stream_buf,
            \\{{"name": "stderr", "text": "{s}"}}
        , .{escaped_err_stream.items}) catch null;
        if (stream_content) |sc| {
            try publishMessage(z, msg, "stream", sc);
        }
    }

    if (exception_text != null) {
        // Error path
        var err_builder = std.ArrayList(u8).empty;
        defer err_builder.deinit(alloc);
        try err_builder.appendSlice(alloc, exception_text.?);
        if (std.mem.indexOf(u8, exception_text.?, "invalid UTF-8 sequence") != null) {
            try err_builder.appendSlice(alloc, "\n\n--- eval source preview ---\n");
            try err_builder.appendSlice(alloc, eval_source_for_diag);
            try err_builder.appendSlice(alloc, "\n\n--- eval source hex (first 256 bytes) ---\n");
            const max_len: usize = @min(eval_source_for_diag.len, 256);
            for (eval_source_for_diag[0..max_len], 0..) |b, i| {
                const part = try std.fmt.allocPrint(alloc, "{x:0>2}", .{b});
                defer alloc.free(part);
                try err_builder.appendSlice(alloc, part);
                if (i + 1 < max_len) try err_builder.appendSlice(alloc, " ");
            }
            try err_builder.append(alloc, '\n');
        }
        const err_text = try err_builder.toOwnedSlice(alloc);
        defer alloc.free(err_text);

        var escaped_err = std.ArrayList(u8).empty;
        defer escaped_err.deinit(alloc);
        try jsonEscape(&escaped_err, err_text);

        var buf: [8192]u8 = undefined;
        const err_content = std.fmt.bufPrint(&buf,
            \\{{"ename": "Error", "evalue": "{s}", "traceback": ["{s}"]}}
        , .{ escaped_err.items, escaped_err.items }) catch return;
        try publishMessage(z, msg, "error", err_content);

        const reply_content = std.fmt.bufPrint(&buf,
            \\{{"status": "error", "execution_count": {d}, "ename": "Error", "evalue": "{s}", "traceback": ["{s}"]}}
        , .{ execution_count, escaped_err.items, escaped_err.items }) catch return;
        try sendReply(z, shell_sock, msg, "execute_reply", reply_content);
    } else {
        // Success path — check for displayable result
        if (!qjs.isUndefined(display_value) and !qjs.isNull(display_value)) {
            if (try formatNotebookResult(runtime.ctx, display_value, execution_count)) |formatted| {
                defer formatted.deinit();
                switch (formatted) {
                    .execute_result => |content| try publishMessage(z, msg, "execute_result", content),
                    .display_data => |content| try publishMessage(z, msg, "display_data", content),
                }
            }
        }

        var buf: [256]u8 = undefined;
        const reply_content = std.fmt.bufPrint(&buf,
            \\{{"status": "ok", "execution_count": {d}, "user_expressions": {{}}}}
        , .{execution_count}) catch return;
        try sendReply(z, shell_sock, msg, "execute_reply", reply_content);
    }

    // Publish status: idle
    try publishStatus(z, msg, "idle");
}

fn isPromiseLike(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) bool {
    if (!qjs.isObject(value)) return false;
    const then_val = qjs.getProperty(ctx, value, "then");
    defer qjs.freeValue(ctx, then_val);
    return qjs.isFunction(ctx, then_val);
}

fn jsGetBool(ctx: ?*qjs.c.JSContext, obj: qjs.c.JSValueConst, key: [:0]const u8) bool {
    const value = qjs.getProperty(ctx, obj, key);
    defer qjs.freeValue(ctx, value);
    return qjs.c.JS_ToBool(ctx, value) == 1;
}

fn awaitNotebookPromise(qruntime: *qjs.Runtime, loop: *async_loop.Loop, promise_value: qjs.c.JSValueConst, allocator: std.mem.Allocator) !?[]u8 {
    const ctx = qruntime.ctx;
    const global = qjs.c.JS_GetGlobalObject(ctx);
    defer qjs.freeValue(ctx, global);

    const state = qjs.newObject(ctx);
    if (qjs.isException(state)) return try allocator.dupe(u8, "failed to create async state");
    defer qjs.freeValue(ctx, state);

    try qjs.setProperty(ctx, state, "settled", qjs.boolValue(ctx, false));
    try qjs.setProperty(ctx, state, "ok", qjs.boolValue(ctx, false));
    try qjs.setProperty(ctx, state, "value", qjs.undefinedValue(ctx));
    try qjs.setProperty(ctx, state, "error", qjs.undefinedValue(ctx));
    try qjs.setProperty(ctx, global, "__hao_nb_async_state", qjs.dupValue(ctx, state));
    try qjs.setProperty(ctx, global, "__hao_nb_async_promise", qjs.dupValue(ctx, promise_value));
    try qjs.setProperty(ctx, global, "__hao_nb_async_value", qjs.undefinedValue(ctx));

    const bootstrap =
        \\Promise.resolve(globalThis.__hao_nb_async_promise).then(
        \\  (value) => { globalThis.__hao_nb_async_state.settled = true; globalThis.__hao_nb_async_state.ok = true; globalThis.__hao_nb_async_state.value = value; globalThis.__hao_nb_async_value = value; },
        \\  (err) => { globalThis.__hao_nb_async_state.settled = true; globalThis.__hao_nb_async_state.ok = false; globalThis.__hao_nb_async_state.error = err; },
        \\);
    ;
    const value = qjs.eval(ctx, bootstrap, "<hao-jupyter>", qjs.EvalFlags.global);
    defer qjs.freeValue(ctx, value);
    if (qjs.isException(value)) {
        return formatJsException(ctx, allocator) catch try allocator.dupe(u8, "unknown error");
    }

    var idle_rounds: usize = 0;
    var settle_steps: usize = 0;
    while (true) {
        settle_steps += 1;
        if (settle_steps >= 10_000) return try allocator.dupe(u8, "Promise did not settle");
        if (jsGetBool(ctx, state, "settled")) {
            if (jsGetBool(ctx, state, "ok")) return null;
            const err_val = qjs.getProperty(ctx, state, "error");
            defer qjs.freeValue(ctx, err_val);
            return qjs.valueToStringAlloc(ctx, err_val, allocator) catch try allocator.dupe(u8, "unknown error");
        }

        const ran_jobs = qjs.executePendingJobs(qruntime.rt) catch {
            return formatJsException(ctx, allocator) catch try allocator.dupe(u8, "unknown error");
        };
        if (qjs.takeUnhandledException()) |pending| {
            defer qjs.freeValue(pending.ctx, pending.value);
            return qjs.valueToStringAlloc(pending.ctx, pending.value, allocator) catch try allocator.dupe(u8, "unknown error");
        }
        const ran_uv = loop.runNowait() catch return try allocator.dupe(u8, "libuv run failed");
        if (qjs.takeUnhandledException()) |pending| {
            defer qjs.freeValue(pending.ctx, pending.value);
            return qjs.valueToStringAlloc(pending.ctx, pending.value, allocator) catch try allocator.dupe(u8, "unknown error");
        }
        if (!ran_jobs and !ran_uv) {
            if (jsGetBool(ctx, state, "settled")) continue;
            idle_rounds += 1;
            if (idle_rounds >= 64) return try allocator.dupe(u8, "Promise did not settle");
        } else {
            idle_rounds = 0;
        }
    }
}

fn formatJsException(ctx: ?*qjs.c.JSContext, allocator: std.mem.Allocator) ![]u8 {
    const ex = qjs.c.JS_GetException(ctx);
    defer qjs.freeValue(ctx, ex);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    if (qjs.isObject(ex)) {
        const name = qjs.getProperty(ctx, ex, "name");
        defer qjs.freeValue(ctx, name);
        const message = qjs.getProperty(ctx, ex, "message");
        defer qjs.freeValue(ctx, message);
        const stack = qjs.getProperty(ctx, ex, "stack");
        defer qjs.freeValue(ctx, stack);

        const name_s = if (!qjs.isUndefined(name) and !qjs.isNull(name)) qjs.valueToStringAlloc(ctx, name, allocator) catch null else null;
        defer if (name_s) |s| allocator.free(s);
        const msg_s = if (!qjs.isUndefined(message) and !qjs.isNull(message)) qjs.valueToStringAlloc(ctx, message, allocator) catch null else null;
        defer if (msg_s) |s| allocator.free(s);
        const stack_s = if (!qjs.isUndefined(stack) and !qjs.isNull(stack)) qjs.valueToStringAlloc(ctx, stack, allocator) catch null else null;
        defer if (stack_s) |s| allocator.free(s);

        if (name_s != null or msg_s != null) {
            try out.appendSlice(allocator, name_s orelse "Error");
            if (msg_s) |m| {
                try out.appendSlice(allocator, ": ");
                try out.appendSlice(allocator, m);
            }
            try out.append(allocator, '\n');
        }
        if (stack_s) |s| {
            try out.appendSlice(allocator, s);
            return out.toOwnedSlice(allocator);
        }
    }

    const fallback = qjs.valueToStringAlloc(ctx, ex, allocator) catch try allocator.dupe(u8, "unknown error");
    defer allocator.free(fallback);
    try out.appendSlice(allocator, fallback);
    return out.toOwnedSlice(allocator);
}

// ============================================================
// Helper: rewrite top-level const/let to var for cell persistence
// ============================================================

fn rewriteTopLevelDecls(source: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        // Only rewrite lines at column 0 (no indentation) to avoid touching nested scopes
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
            if (std.mem.startsWith(u8, trimmed, "const ")) {
                try out.appendSlice(allocator, "var ");
                try out.appendSlice(allocator, trimmed["const ".len..]);
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "let ")) {
                try out.appendSlice(allocator, "var ");
                try out.appendSlice(allocator, trimmed["let ".len..]);
                continue;
            }
            // class Foo { / class Foo extends Bar {  →  var Foo = class Foo { / ...
            if (std.mem.startsWith(u8, trimmed, "class ")) {
                const rest = trimmed["class ".len..];
                // Find class name (ends at space or {)
                var name_end: usize = 0;
                while (name_end < rest.len and rest[name_end] != ' ' and rest[name_end] != '{') : (name_end += 1) {}
                if (name_end > 0) {
                    const name = rest[0..name_end];
                    try out.appendSlice(allocator, "var ");
                    try out.appendSlice(allocator, name);
                    try out.appendSlice(allocator, " = class ");
                    try out.appendSlice(allocator, rest);
                    continue;
                }
            }
        }
        try out.appendSlice(allocator, line);
    }

    return out.toOwnedSlice(allocator);
}

// Rewrites only transpiler-generated helper bindings so repeated notebook cells
// can re-run static-import code without lexical redeclaration failures.
fn rewriteNotebookHelperDecls(source: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;

        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (line.len > 0 and line[0] != ' ' and line[0] != '\t') {
            if (std.mem.startsWith(u8, trimmed, "const __hao_")) {
                try out.appendSlice(allocator, "var ");
                try out.appendSlice(allocator, trimmed["const ".len..]);
                continue;
            }
            if (std.mem.startsWith(u8, trimmed, "let __hao_")) {
                try out.appendSlice(allocator, "var ");
                try out.appendSlice(allocator, trimmed["let ".len..]);
                continue;
            }
        }
        try out.appendSlice(allocator, line);
    }

    return out.toOwnedSlice(allocator);
}

// ============================================================
// Helper: call repr protocol on a JS value
// ============================================================

const ReprOutput = struct {
    mime: []u8,
    data: []u8,
};

const NotebookResult = union(enum) {
    execute_result: []u8,
    display_data: []u8,

    fn deinit(self: NotebookResult) void {
        switch (self) {
            .execute_result => |content| alloc.free(content),
            .display_data => |content| alloc.free(content),
        }
    }
};

fn callRepr(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst) !?ReprOutput {
    if (qjs.isObject(value)) {
        const repr_fn = qjs.getProperty(ctx, value, "repr");
        defer qjs.freeValue(ctx, repr_fn);

        if (!qjs.isUndefined(repr_fn) and !qjs.isNull(repr_fn) and qjs.isFunction(ctx, repr_fn)) {
            const repr_opts = qjs.newObject(ctx);
            if (qjs.isException(repr_opts)) return error.JavaScriptError;
            defer qjs.freeValue(ctx, repr_opts);
            try qjs.setProperty(ctx, repr_opts, "mode", qjs.createString(ctx, "text"));
            const args = [_]qjs.c.JSValueConst{repr_opts};
            const repr_value = qjs.call(ctx, repr_fn, value, &args);
            defer qjs.freeValue(ctx, repr_value);
            if (qjs.isException(repr_value)) return error.JavaScriptError;

            if (qjs.isString(repr_value)) {
                const data = try qjs.valueToStringAlloc(ctx, repr_value, alloc);
                return .{ .mime = try alloc.dupe(u8, "text/plain"), .data = data };
            }
            if (qjs.isObject(repr_value)) {
                const mime_value = qjs.getProperty(ctx, repr_value, "mime");
                defer qjs.freeValue(ctx, mime_value);
                const data_value = qjs.getProperty(ctx, repr_value, "data");
                defer qjs.freeValue(ctx, data_value);

                if (!qjs.isUndefined(mime_value) and !qjs.isNull(mime_value) and !qjs.isUndefined(data_value) and !qjs.isNull(data_value)) {
                    const mime = try qjs.valueToStringAlloc(ctx, mime_value, alloc);
                    errdefer alloc.free(mime);
                    const data = try qjs.valueToStringAlloc(ctx, data_value, alloc);
                    return .{ .mime = mime, .data = data };
                }
            }
        }
    }

    return null;
}

fn formatNotebookResult(ctx: ?*qjs.c.JSContext, value: qjs.c.JSValueConst, exec_count: u32) !?NotebookResult {
    const repr_result = try callRepr(ctx, value);
    if (repr_result) |repr| {
        defer alloc.free(repr.mime);
        defer alloc.free(repr.data);
        if (std.mem.eql(u8, repr.mime, "text/plain")) {
            var escaped = std.ArrayList(u8).empty;
            defer escaped.deinit(alloc);
            try jsonEscape(&escaped, repr.data);
            return .{
                .execute_result = try std.fmt.allocPrint(
                    alloc,
                    \\{{"execution_count": {d}, "data": {{"text/plain": "{s}"}}, "metadata": {{}}}}
                ,
                    .{ exec_count, escaped.items },
                ),
            };
        }

        var escaped = std.ArrayList(u8).empty;
        defer escaped.deinit(alloc);
        try jsonEscape(&escaped, repr.data);
        return .{
            .display_data = try std.fmt.allocPrint(
                alloc,
                \\{{"data": {{"{s}": "{s}"}}, "metadata": {{}}, "transient": {{}}}}
            ,
                .{ repr.mime, escaped.items },
            ),
        };
    }

    const res_text = if (qjs.isObject(value))
        try util_native.inspectAlloc(ctx, value, null, alloc)
    else
        try qjs.valueToStringAlloc(ctx, value, alloc);
    defer alloc.free(res_text);
    if (res_text.len == 0) return null;

    var escaped = std.ArrayList(u8).empty;
    defer escaped.deinit(alloc);
    try jsonEscape(&escaped, res_text);
    return .{
        .execute_result = try std.fmt.allocPrint(
            alloc,
            \\{{"execution_count": {d}, "data": {{"text/plain": "{s}"}}, "metadata": {{}}}}
        ,
            .{ exec_count, escaped.items },
        ),
    };
}

// ============================================================
// Helper: JSON-escape a string into an ArrayList
// ============================================================

fn jsonEscape(out: *std.ArrayList(u8), input: []const u8) !void {
    for (input) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, ch),
        }
    }
}

// ============================================================
// Helper: send a reply on a ROUTER socket
// ============================================================

fn sendReply(z: *const zmq.Zmq, sock: *anyopaque, parent: *wire.Message, msg_type: []const u8, content: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    wire.generateId(&id_buf);

    const header = try wire.makeHeader(&header_buf, msg_type, &id_buf, &session_id);

    try wire.sendMessage(z, sock, parent.identities.items, header, parent.header, "{}", content, conn_info.key);
}

// ============================================================
// Helper: publish on iopub
// ============================================================

fn publishMessage(z: *const zmq.Zmq, parent: *wire.Message, msg_type: []const u8, content: []const u8) !void {
    var header_buf: [512]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    wire.generateId(&id_buf);

    const header = try wire.makeHeader(&header_buf, msg_type, &id_buf, &session_id);

    try wire.sendMessage(z, iopub_sock, &.{}, header, parent.header, "{}", content, conn_info.key);
}

fn publishStatus(z: *const zmq.Zmq, parent: *wire.Message, state: []const u8) !void {
    var buf: [128]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf,
        \\{{"execution_state": "{s}"}}
    , .{state});
    try publishMessage(z, parent, "status", content);
}

fn publishDisplayData(z: *const zmq.Zmq, parent: *wire.Message, mime: []const u8, data: []const u8) !void {
    var escaped = std.ArrayList(u8).empty;
    defer escaped.deinit(alloc);
    try jsonEscape(&escaped, data);

    var buf: [65536]u8 = undefined;
    const content = std.fmt.bufPrint(&buf,
        \\{{"data": {{"{s}": "{s}"}}, "metadata": {{}}, "transient": {{}}}}
    , .{ mime, escaped.items }) catch return;
    try publishMessage(z, parent, "display_data", content);
}

// ============================================================
// kernel install
// ============================================================

fn kernelspecDir(home: []const u8, buf: []u8) ![]const u8 {
    return if (builtin.os.tag == .macos)
        std.fmt.bufPrint(buf, "{s}/Library/Jupyter/kernels/hao", .{home})
    else
        std.fmt.bufPrint(buf, "{s}/.local/share/jupyter/kernels/hao", .{home});
}

fn kernelJsonPath(kernels_dir: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}/kernel.json", .{kernels_dir});
}

fn renderKernelJson(exe_path: []const u8, buf: []u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{
        \\  "argv": ["{s}", "jupyter", "--connection-file", "{{connection_file}}"],
        \\  "display_name": "Hao (TypeScript)",
        \\  "language": "typescript",
        \\  "metadata": {{"debugger": false}}
        \\}}
        \\
    , .{exe_path});
}

pub fn install() !void {

    // Get hao binary path
    const exe_path_owned = try selfExePathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(exe_path_owned);
    const exe_path = exe_path_owned;

    // Determine kernels directory
    const home = if (c.getenv("HOME")) |value| std.mem.span(value) else return error.NoHome;
    var path_buf: [4096]u8 = undefined;
    const kernels_dir = try kernelspecDir(home, &path_buf);

    // Create directory
    fs.makePath(std.heap.page_allocator, kernels_dir) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    // Write kernel.json
    var json_path_buf: [4096]u8 = undefined;
    const json_path = try kernelJsonPath(kernels_dir, &json_path_buf);

    var write_buf: [4096]u8 = undefined;
    const json_content = try renderKernelJson(exe_path, &write_buf);

    try fs.writeFile(json_path, json_content);

    writeStdout("Installed hao kernel to ");
    writeStdout(json_path);
    writeStdout("\n");
}

test "jupyter kernelspec helpers render hao runtime command" {
    var dir_buf: [4096]u8 = undefined;
    const kernels_dir = try kernelspecDir("/tmp/hao-home", &dir_buf);
    try std.testing.expect(std.mem.endsWith(u8, kernels_dir, "/kernels/hao"));
    try std.testing.expect(std.mem.indexOf(u8, kernels_dir, "std:") == null);

    var path_buf: [4096]u8 = undefined;
    const path = try kernelJsonPath(kernels_dir, &path_buf);
    try std.testing.expect(std.mem.endsWith(u8, path, "/kernels/hao/kernel.json"));

    var json_buf: [4096]u8 = undefined;
    const json = try renderKernelJson("/usr/local/bin/hao", &json_buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"/usr/local/bin/hao\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"jupyter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"--connection-file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"{connection_file}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Hao (TypeScript)") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "std:") == null);
}

test "callRepr extracts generic svg repr object on qjs jupyter path" {
    var test_runtime = try qjs.Runtime.init();
    defer test_runtime.deinit();

    try global_console.register(test_runtime.ctx);

    const value = qjs.eval(
        test_runtime.ctx,
        "globalThis.__hao_svg_obj = { repr() { return { mime: 'image/svg+xml', data: '<svg><circle /></svg>' }; } };",
        "<jupyter-svg-repr>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(test_runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const global = qjs.c.JS_GetGlobalObject(test_runtime.ctx);
    defer qjs.freeValue(test_runtime.ctx, global);
    const obj = qjs.getProperty(test_runtime.ctx, global, "__hao_svg_obj");
    defer qjs.freeValue(test_runtime.ctx, obj);

    const repr = (try callRepr(test_runtime.ctx, obj)).?;
    defer alloc.free(repr.mime);
    defer alloc.free(repr.data);

    try std.testing.expectEqualStrings("image/svg+xml", repr.mime);
    try std.testing.expectEqualStrings("<svg><circle /></svg>", repr.data);
}

test "callRepr preserves plot show svg through prepared notebook cell" {
    var test_runtime = try qjs.Runtime.init();
    defer test_runtime.deinit();

    try global_console.register(test_runtime.ctx);

    var test_registry = packages.Registry.init(std.testing.allocator);
    defer test_registry.deinit();
    try hao_std.register(&test_registry);

    var test_loader = module_runtime.Loader{ .allocator = std.testing.allocator, .registry = &test_registry };
    test_loader.install(&test_runtime);

    var prepared = try module_runtime.prepareNotebookCell(
        &test_loader,
        &test_runtime,
        \\import { figure, plot, show } from 'std:plot';
        \\figure({ width: 120, height: 80 });
        \\plot([0, 1], [0, 1]);
        \\show();
    ,
        "<plot-notebook-cell>",
    );
    defer prepared.deinit(std.testing.allocator);

    const result = qjs.eval(test_runtime.ctx, prepared.code, prepared.source_url, qjs.EvalFlags.global);
    defer qjs.freeValue(test_runtime.ctx, result);
    try std.testing.expect(!qjs.isException(result));

    const repr = (try callRepr(test_runtime.ctx, result)).?;
    defer alloc.free(repr.mime);
    defer alloc.free(repr.data);

    try std.testing.expectEqualStrings("image/svg+xml", repr.mime);
    try std.testing.expect(std.mem.startsWith(u8, repr.data, "<svg"));
}

test "formatNotebookResult returns display_data for generic svg repr" {
    var test_runtime = try qjs.Runtime.init();
    defer test_runtime.deinit();

    try global_console.register(test_runtime.ctx);

    const value = qjs.eval(
        test_runtime.ctx,
        "({ repr() { return { mime: 'image/svg+xml', data: '<svg><rect/></svg>' }; } })",
        "<notebook-svg>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(test_runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const formatted = (try formatNotebookResult(test_runtime.ctx, value, 7)).?;
    defer formatted.deinit();
    switch (formatted) {
        .display_data => |content| {
            try std.testing.expect(std.mem.indexOf(u8, content, "\"image/svg+xml\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "<svg><rect/></svg>") != null);
        },
        else => return error.UnexpectedResult,
    }
}

test "formatNotebookResult uses inspect instead of object toString fallback" {
    var test_runtime = try qjs.Runtime.init();
    defer test_runtime.deinit();

    try global_console.register(test_runtime.ctx);

    const value = qjs.eval(
        test_runtime.ctx,
        "globalThis.__hao_nb_object = { a: 1, toString() { return 'bad fallback'; } };",
        "<notebook-object>",
        qjs.EvalFlags.global,
    );
    defer qjs.freeValue(test_runtime.ctx, value);
    try std.testing.expect(!qjs.isException(value));

    const global = qjs.c.JS_GetGlobalObject(test_runtime.ctx);
    defer qjs.freeValue(test_runtime.ctx, global);
    const object = qjs.getProperty(test_runtime.ctx, global, "__hao_nb_object");
    defer qjs.freeValue(test_runtime.ctx, object);

    const formatted = (try formatNotebookResult(test_runtime.ctx, object, 6)).?;
    defer formatted.deinit();
    switch (formatted) {
        .execute_result => |content| {
            try std.testing.expect(std.mem.indexOf(u8, content, "\"text/plain\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "{ a: 1, toString: [Function: toString] }") != null);
            try std.testing.expect(std.mem.indexOf(u8, content, "bad fallback") == null);
        },
        else => return error.UnexpectedResult,
    }
}
