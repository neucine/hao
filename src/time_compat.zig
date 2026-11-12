const std = @import("std");
const builtin = @import("builtin");

const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn GetSystemTimeAsFileTime(*FileTime) void;
extern "kernel32" fn QueryPerformanceCounter(*i64) c_int;
extern "kernel32" fn QueryPerformanceFrequency(*i64) c_int;

pub fn monotonicNanoseconds() i128 {
    if (builtin.os.tag == .windows) {
        var ticks: i64 = 0;
        var frequency: i64 = 0;
        if (QueryPerformanceCounter(&ticks) == 0 or QueryPerformanceFrequency(&frequency) == 0 or frequency <= 0) return 0;
        return @divTrunc(@as(i128, ticks) * std.time.ns_per_s, frequency);
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

pub fn realtimeNanoseconds() i128 {
    if (builtin.os.tag == .windows) {
        var timestamp: FileTime = undefined;
        GetSystemTimeAsFileTime(&timestamp);
        const ticks: u64 = (@as(u64, timestamp.high) << 32) | timestamp.low;
        return (@as(i128, ticks) - 116444736000000000) * 100;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return 0;
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}
