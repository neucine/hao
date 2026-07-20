const builtin = @import("builtin");
const std = @import("std");

pub const Snapshot = struct {
    resident_bytes: u64 = 0,
    physical_footprint_bytes: u64 = 0,
};

pub fn snapshot() Snapshot {
    if (comptime builtin.os.tag == .macos) {
        return darwinSnapshot();
    }
    if (comptime builtin.os.tag == .linux) {
        return linuxSnapshot();
    }
    return .{};
}

fn linuxSnapshot() Snapshot {
    const file = std.c.fopen("/proc/self/statm", "r") orelse return .{};
    defer _ = std.c.fclose(file);

    var buffer: [128]u8 = undefined;
    const length = std.c.fread(&buffer, 1, buffer.len, file);
    var fields = std.mem.tokenizeScalar(u8, buffer[0..length], ' ');
    _ = fields.next();
    const resident_pages = std.fmt.parseInt(u64, fields.next() orelse return .{}, 10) catch return .{};
    return .{ .resident_bytes = resident_pages * std.heap.pageSize() };
}

fn darwinSnapshot() Snapshot {
    var basic = std.mem.zeroes(std.c.mach_task_basic_info);
    var basic_count: std.c.mach_msg_type_number_t = std.c.MACH.TASK.BASIC.INFO_COUNT;
    const basic_result = std.c.task_info(
        std.c.mach_task_self(),
        std.c.MACH.TASK.BASIC.INFO,
        @ptrCast(&basic),
        &basic_count,
    );

    var vm = std.mem.zeroes(std.c.task_vm_info_data_t);
    var vm_count: std.c.mach_msg_type_number_t = std.c.TASK.VM.INFO_COUNT;
    const vm_result = std.c.task_info(
        std.c.mach_task_self(),
        std.c.TASK.VM.INFO,
        @ptrCast(&vm),
        &vm_count,
    );

    return .{
        .resident_bytes = if (basic_result == 0) @intCast(basic.resident_size) else 0,
        .physical_footprint_bytes = if (vm_result == 0) @intCast(vm.phys_footprint) else 0,
    };
}
