// Minimal libuv ABI. Handle/request storage uses libuv's runtime size queries,
// avoiding platform-specific private layouts and platform SDK C imports.
pub const UV_TCP = 12;
pub const UV_WRITE = 3;
const base = @import("../../async/uv.zig").c;
pub const uv_handle_t = base.uv_handle_t;
pub const uv_timer_t = base.uv_timer_t;
pub const uv_tcp_t = extern struct { data: ?*anyopaque };
pub const uv_stream_t = uv_tcp_t;
pub const uv_write_t = extern struct { data: ?*anyopaque };
pub const uv_buf_t = extern struct { base: ?[*]u8, len: usize };
pub const uv_close = base.uv_close;
pub const uv_timer_init = base.uv_timer_init;
pub const uv_timer_start = base.uv_timer_start;
pub const uv_timer_stop = base.uv_timer_stop;
pub extern "c" fn uv_handle_size(kind: c_int) usize;
pub extern "c" fn uv_req_size(kind: c_int) usize;
pub extern "c" fn uv_handle_get_loop(handle: *uv_stream_t) *base.uv_loop_t;
pub extern "c" fn uv_tcp_init(loop: *base.uv_loop_t, handle: *uv_tcp_t) c_int;
pub extern "c" fn uv_ip4_addr(ip: [*:0]const u8, port: c_int, address: *anyopaque) c_int;
pub extern "c" fn uv_tcp_bind(handle: *uv_tcp_t, address: *const anyopaque, flags: c_uint) c_int;
pub extern "c" fn uv_tcp_getsockname(handle: *uv_tcp_t, address: *anyopaque, length: *c_int) c_int;
pub extern "c" fn uv_listen(stream: *uv_stream_t, backlog: c_int, cb: *const fn (?*uv_stream_t, c_int) callconv(.c) void) c_int;
pub extern "c" fn uv_accept(server: ?*uv_stream_t, client: *uv_stream_t) c_int;
pub extern "c" fn uv_read_stop(stream: *uv_stream_t) c_int;
pub extern "c" fn uv_read_start(stream: *uv_stream_t, alloc_cb: *const fn (?*uv_handle_t, usize, [*c]uv_buf_t) callconv(.c) void, read_cb: *const fn (?*uv_stream_t, isize, [*c]const uv_buf_t) callconv(.c) void) c_int;
pub extern "c" fn uv_write(req: *uv_write_t, stream: *uv_stream_t, buffers: [*]const uv_buf_t, count: c_uint, cb: *const fn (?*uv_write_t, c_int) callconv(.c) void) c_int;
