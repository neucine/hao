const qjs = @import("qjs.zig");

pub const ClassSlot = enum {
    file,
    trace_handle,
};

var class_ids = [_]qjs.c.JSClassID{0} ** @typeInfo(ClassSlot).@"enum".fields.len;
var ready = [_]bool{false} ** @typeInfo(ClassSlot).@"enum".fields.len;

pub fn ensureRegistered(rt: ?*qjs.c.JSRuntime) void {
    inline for (@typeInfo(ClassSlot).@"enum".fields) |field| {
        _ = ensureClassId(rt, @enumFromInt(field.value));
    }
}

pub fn ensureClassId(rt: ?*qjs.c.JSRuntime, slot: ClassSlot) qjs.c.JSClassID {
    const idx = @intFromEnum(slot);
    if (!ready[idx]) {
        _ = qjs.c.JS_NewClassID(@ptrCast(rt), &class_ids[idx]);
        ready[idx] = true;
    }
    return class_ids[idx];
}
