const trace = @import("trace.zig");

pub const max_trace_records = 512;

var trace_storage: [max_trace_records]trace.RecordSlot = undefined;
var trace_buffer = trace.Buffer.init(&trace_storage);
var trace_tracer = trace.Tracer.init(&trace_buffer, 0x7e1e7);

pub fn buffer() *trace.Buffer {
    return &trace_buffer;
}

pub fn tracer() *trace.Tracer {
    return &trace_tracer;
}

pub fn clear() void {
    trace_buffer.clear();
}
