pub fn limits_error(port: f64, max_connections: f64, timeout_ms: f64): i32 {
    if port > 65535 or max_connections < 1 or max_connections > 1024 or
        timeout_ms < 1 or timeout_ms > 3600000 { return 4; } // Invalid server limits
    return 0;
}

pub fn limits_error_c(port: c_double,
    max_connections: c_double, timeout_ms: c_double): c_int {
    return limits_error(port as f64, max_connections as f64, timeout_ms as f64) as c_int;
}
