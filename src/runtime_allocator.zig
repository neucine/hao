//! Central accounting facade for Hao-owned Zig allocations.
//!
//! Embedders provide one backing allocator when they create a runtime
//! environment. Hao wraps that allocator here and routes runtime-owned Zig
//! allocations through this module so they can be accounted consistently.
//! QuickJS uses its own allocator and is reported separately from
//! `qjs.computeMemoryUsage`; host-owned allocations remain outside this scope.

const std = @import("std");

pub const Stats = struct {
    active_size: usize,
    peak_size: usize,
    allocated_size: usize,
    freed_size: usize,
    allocation_count: u64,
    free_count: u64,
};

var backing_allocator: std.mem.Allocator = std.heap.page_allocator;
var active_size = std.atomic.Value(usize).init(0);
var peak_size = std.atomic.Value(usize).init(0);
var allocated_size = std.atomic.Value(usize).init(0);
var freed_size = std.atomic.Value(usize).init(0);
var allocation_count = std.atomic.Value(u64).init(0);
var free_count = std.atomic.Value(u64).init(0);

const vtable = std.mem.Allocator.VTable{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

pub fn init(backing: std.mem.Allocator) void {
    backing_allocator = backing;
    resetStats();
}

pub fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &vtable,
    };
}

pub fn stats() Stats {
    return .{
        .active_size = active_size.load(.monotonic),
        .peak_size = peak_size.load(.monotonic),
        .allocated_size = allocated_size.load(.monotonic),
        .freed_size = freed_size.load(.monotonic),
        .allocation_count = allocation_count.load(.monotonic),
        .free_count = free_count.load(.monotonic),
    };
}

pub fn resetStats() void {
    active_size.store(0, .monotonic);
    peak_size.store(0, .monotonic);
    allocated_size.store(0, .monotonic);
    freed_size.store(0, .monotonic);
    allocation_count.store(0, .monotonic);
    free_count.store(0, .monotonic);
}

fn recordAlloc(len: usize) void {
    _ = allocated_size.fetchAdd(len, .monotonic);
    _ = allocation_count.fetchAdd(1, .monotonic);
    increaseActive(len);
}

fn increaseActive(len: usize) void {
    const current = active_size.fetchAdd(len, .monotonic) + len;
    while (true) {
        const peak = peak_size.load(.monotonic);
        if (current <= peak) break;
        if (peak_size.cmpxchgWeak(peak, current, .monotonic, .monotonic) == null) break;
    }
}

fn recordFree(len: usize) void {
    _ = freed_size.fetchAdd(len, .monotonic);
    _ = free_count.fetchAdd(1, .monotonic);
    decreaseActive(len);
}

fn decreaseActive(len: usize) void {
    _ = active_size.fetchSub(len, .monotonic);
}

fn recordResize(old_len: usize, new_len: usize) void {
    if (new_len > old_len) {
        const delta = new_len - old_len;
        _ = allocated_size.fetchAdd(delta, .monotonic);
        increaseActive(delta);
    } else if (old_len > new_len) {
        const delta = old_len - new_len;
        _ = freed_size.fetchAdd(delta, .monotonic);
        decreaseActive(delta);
    }
}

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    const ptr = backing_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;
    recordAlloc(len);
    return ptr;
}

fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    if (!backing_allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;
    recordResize(memory.len, new_len);
    return true;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    const ptr = backing_allocator.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
    recordResize(memory.len, new_len);
    return ptr;
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    backing_allocator.rawFree(memory, alignment, ret_addr);
    recordFree(memory.len);
}

test "runtime allocator records active and peak bytes" {
    init(std.testing.allocator);
    defer init(std.heap.page_allocator);

    const alloc_ = allocator();
    const bytes = try alloc_.alloc(u8, 64);
    try std.testing.expectEqual(@as(usize, 64), stats().active_size);
    try std.testing.expectEqual(@as(usize, 64), stats().peak_size);

    alloc_.free(bytes);
    try std.testing.expectEqual(@as(usize, 0), stats().active_size);
    try std.testing.expectEqual(@as(usize, 64), stats().peak_size);
}
