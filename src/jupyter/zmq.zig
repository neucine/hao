const std = @import("std");
const builtin = @import("builtin");

// ============================================================
// ZMQ constants
// ============================================================

pub const ZMQ_ROUTER = 6;
pub const ZMQ_PUB = 1;
pub const ZMQ_REP = 4;

pub const ZMQ_LINGER = 17;
pub const ZMQ_IDENTITY = 5;

pub const ZMQ_SNDMORE = 2;
pub const ZMQ_DONTWAIT = 1;

pub const ZMQ_POLLIN = 1;

// ============================================================
// ZMQ structs
// ============================================================

pub const zmq_msg_t = extern struct {
    _: [64]u8 = std.mem.zeroes([64]u8),
};

pub const zmq_pollitem_t = extern struct {
    socket: ?*anyopaque = null,
    fd: c_int = 0,
    events: c_short = 0,
    revents: c_short = 0,
};

// ============================================================
// ZMQ wrapper — dlopen libzmq at runtime
// ============================================================

pub const Zmq = struct {
    lib: std.DynLib,

    // Context
    ctx_new: *const fn () callconv(.c) ?*anyopaque,
    ctx_destroy: *const fn (?*anyopaque) callconv(.c) c_int,

    // Socket
    socket_fn: *const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque,
    close: *const fn (?*anyopaque) callconv(.c) c_int,
    bind: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int,
    setsockopt: *const fn (?*anyopaque, c_int, ?*const anyopaque, usize) callconv(.c) c_int,

    // Message I/O
    msg_init: *const fn (*zmq_msg_t) callconv(.c) c_int,
    msg_init_size: *const fn (*zmq_msg_t, usize) callconv(.c) c_int,
    msg_data: *const fn (*zmq_msg_t) callconv(.c) [*]u8,
    msg_size: *const fn (*zmq_msg_t) callconv(.c) usize,
    msg_recv: *const fn (*zmq_msg_t, ?*anyopaque, c_int) callconv(.c) c_int,
    msg_send: *const fn (*zmq_msg_t, ?*anyopaque, c_int) callconv(.c) c_int,
    msg_close: *const fn (*zmq_msg_t) callconv(.c) c_int,
    msg_more: *const fn (*zmq_msg_t) callconv(.c) c_int,

    // Poll
    poll: *const fn ([*]zmq_pollitem_t, c_int, c_long) callconv(.c) c_int,

    // Error
    errno_fn: *const fn () callconv(.c) c_int,
    strerror: *const fn (c_int) callconv(.c) [*:0]const u8,

    pub fn open() !Zmq {
        const lib_name: [:0]const u8 = if (builtin.os.tag == .macos)
            "libzmq.5.dylib"
        else
            "libzmq.so.5";

        var lib = std.DynLib.open(lib_name) catch blk: {
            // On macOS, try Homebrew paths as fallback
            if (builtin.os.tag == .macos) {
                break :blk std.DynLib.open("/opt/homebrew/lib/libzmq.5.dylib") catch {
                    break :blk std.DynLib.open("/usr/local/lib/libzmq.5.dylib") catch {
                        std.debug.print("Error: libzmq not found. Install with:\n  brew install zmq\n", .{});
                        return error.LibraryNotFound;
                    };
                };
            } else {
                std.debug.print("Error: libzmq not found. Install with:\n  apt install libzmq3-dev\n", .{});
                return error.LibraryNotFound;
            }
        };
        errdefer lib.close();

        return Zmq{
            .lib = lib,
            .ctx_new = lib.lookup(*const fn () callconv(.c) ?*anyopaque, "zmq_ctx_new") orelse return error.SymbolNotFound,
            .ctx_destroy = lib.lookup(*const fn (?*anyopaque) callconv(.c) c_int, "zmq_ctx_destroy") orelse return error.SymbolNotFound,
            .socket_fn = lib.lookup(*const fn (?*anyopaque, c_int) callconv(.c) ?*anyopaque, "zmq_socket") orelse return error.SymbolNotFound,
            .close = lib.lookup(*const fn (?*anyopaque) callconv(.c) c_int, "zmq_close") orelse return error.SymbolNotFound,
            .bind = lib.lookup(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) c_int, "zmq_bind") orelse return error.SymbolNotFound,
            .setsockopt = lib.lookup(*const fn (?*anyopaque, c_int, ?*const anyopaque, usize) callconv(.c) c_int, "zmq_setsockopt") orelse return error.SymbolNotFound,
            .msg_init = lib.lookup(*const fn (*zmq_msg_t) callconv(.c) c_int, "zmq_msg_init") orelse return error.SymbolNotFound,
            .msg_init_size = lib.lookup(*const fn (*zmq_msg_t, usize) callconv(.c) c_int, "zmq_msg_init_size") orelse return error.SymbolNotFound,
            .msg_data = lib.lookup(*const fn (*zmq_msg_t) callconv(.c) [*]u8, "zmq_msg_data") orelse return error.SymbolNotFound,
            .msg_size = lib.lookup(*const fn (*zmq_msg_t) callconv(.c) usize, "zmq_msg_size") orelse return error.SymbolNotFound,
            .msg_recv = lib.lookup(*const fn (*zmq_msg_t, ?*anyopaque, c_int) callconv(.c) c_int, "zmq_msg_recv") orelse return error.SymbolNotFound,
            .msg_send = lib.lookup(*const fn (*zmq_msg_t, ?*anyopaque, c_int) callconv(.c) c_int, "zmq_msg_send") orelse return error.SymbolNotFound,
            .msg_close = lib.lookup(*const fn (*zmq_msg_t) callconv(.c) c_int, "zmq_msg_close") orelse return error.SymbolNotFound,
            .msg_more = lib.lookup(*const fn (*zmq_msg_t) callconv(.c) c_int, "zmq_msg_more") orelse return error.SymbolNotFound,
            .poll = lib.lookup(*const fn ([*]zmq_pollitem_t, c_int, c_long) callconv(.c) c_int, "zmq_poll") orelse return error.SymbolNotFound,
            .errno_fn = lib.lookup(*const fn () callconv(.c) c_int, "zmq_errno") orelse return error.SymbolNotFound,
            .strerror = lib.lookup(*const fn (c_int) callconv(.c) [*:0]const u8, "zmq_strerror") orelse return error.SymbolNotFound,
        };
    }

    pub fn deinit(self: *Zmq) void {
        self.lib.close();
    }

    // ---- Convenience wrappers ----

    pub fn createContext(self: *const Zmq) !*anyopaque {
        return self.ctx_new() orelse return error.ZmqError;
    }

    pub fn destroyContext(self: *const Zmq, ctx: *anyopaque) void {
        _ = self.ctx_destroy(ctx);
    }

    pub fn createSocket(self: *const Zmq, ctx: *anyopaque, socket_type: c_int) !*anyopaque {
        return self.socket_fn(ctx, socket_type) orelse return error.ZmqError;
    }

    pub fn closeSocket(self: *const Zmq, sock: *anyopaque) void {
        _ = self.close(sock);
    }

    pub fn bindSocket(self: *const Zmq, sock: *anyopaque, endpoint: [*:0]const u8) !void {
        if (self.bind(sock, endpoint) != 0) return error.ZmqError;
    }

    pub fn setLinger(self: *const Zmq, sock: *anyopaque, linger_ms: c_int) !void {
        if (self.setsockopt(sock, ZMQ_LINGER, &linger_ms, @sizeOf(c_int)) != 0)
            return error.ZmqError;
    }

    /// Receive a single ZMQ frame. Returns the data slice (caller must call msg_close).
    pub fn recvFrame(self: *const Zmq, sock: *anyopaque, msg: *zmq_msg_t, flags: c_int) ![]const u8 {
        _ = self.msg_init(msg);
        const rc = self.msg_recv(msg, sock, flags);
        if (rc < 0) {
            _ = self.msg_close(msg);
            return error.ZmqError;
        }
        const size = self.msg_size(msg);
        const data = self.msg_data(msg);
        return data[0..size];
    }

    /// Send a single ZMQ frame.
    pub fn sendFrame(self: *const Zmq, sock: *anyopaque, data: []const u8, flags: c_int) !void {
        var msg: zmq_msg_t = .{};
        if (self.msg_init_size(&msg, data.len) != 0) return error.ZmqError;
        const buf = self.msg_data(&msg);
        @memcpy(buf[0..data.len], data);
        const rc = self.msg_send(&msg, sock, flags);
        if (rc < 0) {
            _ = self.msg_close(&msg);
            return error.ZmqError;
        }
    }

    /// Check if last received message has more parts.
    pub fn hasMore(self: *const Zmq, msg: *zmq_msg_t) bool {
        return self.msg_more(msg) != 0;
    }

    pub fn getError(self: *const Zmq) []const u8 {
        const err = self.errno_fn();
        const ptr = self.strerror(err);
        return std.mem.span(ptr);
    }
};
