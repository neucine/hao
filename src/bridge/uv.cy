// libuv loop entry points used by the Cyna event loop.
pub extern c("uv_loop_size") fn loop_size(): c_size_t;
pub extern c("uv_loop_init") fn loop_init(loop: *c_void): c_int;
pub extern c("uv_loop_close") fn loop_close(loop: *c_void): c_int;
pub extern c("uv_loop_alive") fn loop_alive(loop: *c_void): c_int;
pub extern c("uv_run") fn uv_run(loop: *c_void, mode: c_int): c_int;
