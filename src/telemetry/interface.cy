import { native_metric, native_span_start, native_span_trace, native_span_id, native_span_sampled, native_span_pending, native_event_start, native_attribute, native_record_finish, native_span_end } from .telemetry.native;
import { Backend, Metric, SpanHandle, SpanKind, SpanStatus, TraceContext, Attribute } from std.telemetry;


fn emit_metric(context: usize, metric: Metric, value: i64, set: c_int): void {
    const scope = metric.group.bytes();
    const name = metric.name.bytes();
    native_metric(context as c_size_t, scope.ptr as! *const c_uchar, scope.len() as c_size_t,
        name.ptr as! *const c_uchar, name.len() as c_size_t, metric.kind as c_int,
        metric.unit as c_int, value as c_llong, set);
}

fn metric_add(context: usize, metric: Metric, value: i64): void {
    emit_metric(context, metric, value, 0);
}

fn metric_set(context: usize, metric: Metric, value: i64): void {
    emit_metric(context, metric, value, 1);
}

fn append_attributes(record: c_size_t, attributes: []const Attribute): void {
    for attribute in attributes {
        const key = attribute.key.bytes();
        const value = attribute.text.bytes();
        var boolean: c_int = 0;
        if attribute.boolean { boolean = 1; }
        native_attribute(record, key.ptr as! *const c_uchar, key.len() as c_size_t,
            attribute.kind as c_int, boolean, attribute.integer as c_llong, attribute.float as c_double,
            value.ptr as! *const c_uchar, value.len() as c_size_t);
    }
}

fn span_start(context: usize, parent: TraceContext, timestamp: i64, name: string,
    kind: SpanKind, attributes: []const Attribute): SpanHandle {
    const bytes = name.bytes();
    var sampled: c_int = 0;
    if parent.sampled { sampled = 1; }
    const handle = native_span_start(context as c_size_t, parent.trace_id as c_ullong, parent.span_id as c_ullong,
        sampled, timestamp as c_llong, bytes.ptr as! *const c_uchar, bytes.len() as c_size_t, kind as c_int);
    if handle == 0 {
        return SpanHandle { id: 0, context: parent };
    }
    const pending = native_span_pending(handle);
    if pending != 0 {
        append_attributes(pending, attributes);
        native_record_finish(handle, pending);
    }
    return SpanHandle {
        id: handle as usize,
        context: TraceContext {
            trace_id: native_span_trace(handle) as u64,
            span_id: native_span_id(handle) as u64,
            sampled: native_span_sampled(handle) != 0
        }
    };
}

fn span_event(context: usize, handle: usize, timestamp: i64, name: string,
    attributes: []const Attribute): void {
    const bytes = name.bytes();
    const record = native_event_start(handle as c_size_t, timestamp as c_llong,
        bytes.ptr as! *const c_uchar, bytes.len() as c_size_t);
    if record == 0 { return; }
    append_attributes(record, attributes);
    native_record_finish(handle as c_size_t, record);
}

fn span_end(context: usize, handle: usize, timestamp: i64, status: SpanStatus): void {
    native_span_end(handle as c_size_t, timestamp as c_llong, status as c_int);
}

pub fn host(runtime_handle: usize): Backend {
    return Backend {
        context: runtime_handle,
        metric_add: metric_add,
        metric_set: metric_set,
        span_start: span_start,
        span_event: span_event,
        span_end: span_end
    };
}
