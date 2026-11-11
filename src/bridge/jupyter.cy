// ZeroMQ native transport used by the Jupyter kernel.
pub extern c("hao_jupyter_wire_open") fn wire_open(transport: *const c_uchar, transport_len: c_size_t,
    ip: *const c_uchar, ip_len: c_size_t, shell_port: c_ushort, control_port: c_ushort,
    iopub_port: c_ushort, stdin_port: c_ushort, hb_port: c_ushort,
    key: *const c_uchar, key_len: c_size_t): c_size_t;
pub extern c("hao_jupyter_wire_close") fn wire_close(handle: c_size_t): void;
pub extern c("hao_jupyter_wire_poll") fn wire_poll(handle: c_size_t, timeout_ms: c_int): c_int;
pub extern c("hao_jupyter_wire_field_length") fn wire_field_length(handle: c_size_t, field: c_int): c_size_t;
pub extern c("hao_jupyter_wire_field_view") fn wire_field(handle: c_size_t, field: c_int): ?*const c_uchar;
pub extern c("hao_jupyter_wire_send") fn wire_send(handle: c_size_t, channel: c_int,
    kind: *const c_uchar, kind_len: c_size_t, content: *const c_uchar, content_len: c_size_t): c_int;
