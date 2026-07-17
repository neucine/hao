const std = @import("std");
const hao = @import("hao.zig");
const config = @import("config.zig");

const c = @cImport({
    @cInclude("stdio.h");
});

fn writeStderr(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const stderr = c.stderr();
    _ = c.fwrite(bytes.ptr, 1, bytes.len, stderr);
    _ = c.fflush(stderr);
}

fn writeStdout(bytes: []const u8) void {
    if (bytes.len == 0) return;
    const stdout = c.stdout();
    _ = c.fwrite(bytes.ptr, 1, bytes.len, stdout);
    _ = c.fflush(stdout);
}

fn usage() void {
    writeStderr(
        \\Usage:
        \\  hao <file.ts|file.js>
        \\  hao test [--grep pattern] <file-or-dir>...
        \\  hao jupyter --connection-file <file>
        \\  hao jupyter install
        \\  hao --version
        \\
    );
}

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    try config.loadFromEnv();
    const path = args.next() orelse {
        usage();
        std.process.exit(2);
    };
    if (std.mem.eql(u8, path, "--version") or std.mem.eql(u8, path, "-v")) {
        if (args.next() != null) {
            usage();
            std.process.exit(2);
        }
        writeStdout("hao ");
        writeStdout(hao.version);
        writeStdout("\n");
        return;
    }
    if (std.mem.eql(u8, path, "test")) {
        var test_paths = std.ArrayList([]const u8).empty;
        defer test_paths.deinit(allocator);
        var grep: ?[]const u8 = null;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--grep")) {
                grep = args.next() orelse {
                    usage();
                    std.process.exit(2);
                };
                continue;
            }
            try test_paths.append(allocator, arg);
        }
        if (test_paths.items.len == 0) {
            usage();
            std.process.exit(2);
        }
        const result = hao.test_runner.run(test_paths.items, grep, true, allocator, init.io) catch |err| {
            writeStderr(@errorName(err));
            writeStderr("\n");
            std.process.exit(1);
        };
        std.process.exit(result.exitCode());
    }
    if (std.mem.eql(u8, path, "jupyter")) {
        const subcommand = args.next() orelse {
            usage();
            std.process.exit(2);
        };
        if (std.mem.eql(u8, subcommand, "install")) {
            try hao.jupyter.install();
            return;
        }
        if (std.mem.eql(u8, subcommand, "--connection-file")) {
            const connection_file = args.next() orelse {
                usage();
                std.process.exit(2);
            };
            if (args.next() != null) {
                usage();
                std.process.exit(2);
            }
            try hao.jupyter.run(connection_file);
            return;
        }
        usage();
        std.process.exit(2);
    }

    if (args.next() != null) {
        usage();
        std.process.exit(2);
    }

    var host = try hao.StdHost.initWithIo(allocator, init.io);
    defer host.deinit();
    host.runFile(path) catch |err| {
        if (hao.module.lastError()) |message| {
            writeStderr(message);
            writeStderr("\n");
        } else if (err == error.JavaScriptError) {
            const message = hao.qjs.getExceptionAlloc(host.runtime.ctx, allocator) catch null;
            defer if (message) |text| allocator.free(text);
            if (message) |text| {
                writeStderr(text);
                writeStderr("\n");
            } else {
                writeStderr("JavaScript error\n");
            }
        } else {
            writeStderr(@errorName(err));
            writeStderr("\n");
        }
        std.process.exit(1);
    };
}
