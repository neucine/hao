pub extern c("hao_telemetry_metric") fn native_metric(handle: c_size_t, scope: *const c_uchar, scope_len: c_size_t,
    name: *const c_uchar, name_len: c_size_t, kind: c_int, unit: c_int, value: c_llong, set: c_int): void;
pub extern c("hao_telemetry_span_start") fn native_span_start(handle: c_size_t, parent_trace: c_ullong, parent_span: c_ullong,
    parent_sampled: c_int, timestamp: c_llong, name: *const c_uchar, name_len: c_size_t, kind: c_int): c_size_t;
pub extern c("hao_telemetry_span_trace") fn native_span_trace(handle: c_size_t): c_ullong;
pub extern c("hao_telemetry_span_id") fn native_span_id(handle: c_size_t): c_ullong;
pub extern c("hao_telemetry_span_sampled") fn native_span_sampled(handle: c_size_t): c_int;
pub extern c("hao_telemetry_span_pending") fn native_span_pending(handle: c_size_t): c_size_t;
pub extern c("hao_telemetry_event_start") fn native_event_start(handle: c_size_t, timestamp: c_llong,
    name: *const c_uchar, name_len: c_size_t): c_size_t;
pub extern c("hao_telemetry_attribute") fn native_attribute(record: c_size_t, key: *const c_uchar,
    key_len: c_size_t, kind: c_int, boolean: c_int, integer: c_llong, floating: c_double,
    text: *const c_uchar, text_len: c_size_t): void;
pub extern c("hao_telemetry_record_finish") fn native_record_finish(handle: c_size_t, record: c_size_t): void;
pub extern c("hao_telemetry_span_end") fn native_span_end(handle: c_size_t, timestamp: c_llong, status: c_int): void;
