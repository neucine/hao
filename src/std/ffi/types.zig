const std = @import("std");

pub const FFIType = enum {
    void,
    bool,
    i8,
    i16,
    i32,
    i64,
    u8,
    u16,
    u32,
    u64,
    f32,
    f64,
    ptr,
    cstring,
    buffer,

    /// Classify into ABI return category for trampoline dispatch.
    pub fn returnClass(self: FFIType) ReturnClass {
        return switch (self) {
            .f32, .f64 => .float,
            .void => .void,
            else => .integer,
        };
    }
};

pub const ReturnClass = enum { void, integer, float };

pub const FnBinding = struct {
    fn_ptr: *anyopaque,
    arg_types: []const FFIType,
    return_type: FFIType,
    name: []const u8,
    closed: *bool,
};

test "FFIType returnClass" {
    const t = std.testing;
    try t.expectEqual(FFIType.i32.returnClass(), .integer);
    try t.expectEqual(FFIType.f64.returnClass(), .float);
    try t.expectEqual(FFIType.void.returnClass(), .void);
    try t.expectEqual(FFIType.ptr.returnClass(), .integer);
    try t.expectEqual(FFIType.cstring.returnClass(), .integer);
}
