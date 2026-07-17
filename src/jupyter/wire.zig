const std = @import("std");
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const zmq = @import("zmq.zig");

const DELIMITER = "<IDS|MSG>";

fn nanoTimestamp() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @intCast(@as(i128, ts.sec) * std.time.ns_per_s + ts.nsec);
}

// ============================================================
// Message struct
// ============================================================

pub const Message = struct {
    identities: std.ArrayList([]const u8),
    header: []const u8,
    parent_header: []const u8,
    metadata: []const u8,
    content: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        for (self.identities.items) |id| self.allocator.free(id);
        self.identities.deinit(self.allocator);
        self.allocator.free(self.header);
        self.allocator.free(self.parent_header);
        self.allocator.free(self.metadata);
        self.allocator.free(self.content);
    }
};

// ============================================================
// Receive a multipart Jupyter message
// ============================================================

pub fn recvMessage(z: *const zmq.Zmq, sock: *anyopaque, allocator: std.mem.Allocator) !Message {
    var frames = std.ArrayList([]const u8).empty;
    defer {
        for (frames.items) |f| allocator.free(f);
        frames.deinit(allocator);
    }

    // Read all multipart frames
    while (true) {
        var msg: zmq.zmq_msg_t = .{};
        const data = try z.recvFrame(sock, &msg, 0);
        const copy = try allocator.dupe(u8, data);
        const more = z.hasMore(&msg);
        _ = z.msg_close(&msg);
        try frames.append(allocator, copy);
        if (!more) break;
    }

    // Find delimiter
    var delim_idx: usize = 0;
    for (frames.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f, DELIMITER)) {
            delim_idx = idx;
            break;
        }
    }

    // identities = frames[0..delim_idx]
    // signature  = frames[delim_idx + 1]
    // header     = frames[delim_idx + 2]
    // parent     = frames[delim_idx + 3]
    // metadata   = frames[delim_idx + 4]
    // content    = frames[delim_idx + 5]

    if (frames.items.len < delim_idx + 6) return error.MalformedMessage;

    var identities = std.ArrayList([]const u8).empty;
    for (0..delim_idx) |i| {
        try identities.append(allocator, try allocator.dupe(u8, frames.items[i]));
    }

    return Message{
        .identities = identities,
        .header = try allocator.dupe(u8, frames.items[delim_idx + 2]),
        .parent_header = try allocator.dupe(u8, frames.items[delim_idx + 3]),
        .metadata = try allocator.dupe(u8, frames.items[delim_idx + 4]),
        .content = try allocator.dupe(u8, frames.items[delim_idx + 5]),
        .allocator = allocator,
    };
}

// ============================================================
// Send a multipart Jupyter message
// ============================================================

pub fn sendMessage(
    z: *const zmq.Zmq,
    sock: *anyopaque,
    identities: []const []const u8,
    header: []const u8,
    parent_header: []const u8,
    metadata: []const u8,
    content: []const u8,
    key: []const u8,
) !void {
    // Send identity frames
    for (identities) |id| {
        try z.sendFrame(sock, id, zmq.ZMQ_SNDMORE);
    }

    // Delimiter
    try z.sendFrame(sock, DELIMITER, zmq.ZMQ_SNDMORE);

    // HMAC signature
    const sig = computeSignature(key, header, parent_header, metadata, content);
    try z.sendFrame(sock, &sig, zmq.ZMQ_SNDMORE);

    // header, parent_header, metadata, content
    try z.sendFrame(sock, header, zmq.ZMQ_SNDMORE);
    try z.sendFrame(sock, parent_header, zmq.ZMQ_SNDMORE);
    try z.sendFrame(sock, metadata, zmq.ZMQ_SNDMORE);
    try z.sendFrame(sock, content, 0); // last frame, no SNDMORE
}

// ============================================================
// HMAC-SHA256 signature
// ============================================================

fn computeSignature(
    key: []const u8,
    header: []const u8,
    parent_header: []const u8,
    metadata: []const u8,
    content: []const u8,
) [64]u8 {
    if (key.len == 0) return std.mem.zeroes([64]u8);

    var hmac = HmacSha256.init(key);
    hmac.update(header);
    hmac.update(parent_header);
    hmac.update(metadata);
    hmac.update(content);
    var digest: [32]u8 = undefined;
    hmac.final(&digest);

    // Encode as lowercase hex
    var hex: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return hex;
}

// ============================================================
// Minimal JSON helpers
// ============================================================

/// Extract a string value for a given key from JSON.
/// Returns the raw JSON string content (with escape sequences intact).
pub fn jsonExtractString(json: []const u8, key: []const u8) ?[]const u8 {
    // Search for "key"
    var i: usize = 0;
    while (i + key.len + 3 < json.len) : (i += 1) {
        if (json[i] == '"' and i + 1 + key.len < json.len and
            std.mem.eql(u8, json[i + 1 .. i + 1 + key.len], key) and
            json[i + 1 + key.len] == '"')
        {
            var j = i + 1 + key.len + 1;
            while (j < json.len and (json[j] == ' ' or json[j] == ':' or json[j] == '\t')) : (j += 1) {}
            if (j < json.len and json[j] == '"') {
                const start = j + 1;
                var end = start;
                // Properly skip escape sequences (e.g. \" inside the string)
                while (end < json.len) {
                    if (json[end] == '\\') {
                        end += 2; // skip escaped character
                    } else if (json[end] == '"') {
                        break;
                    } else {
                        end += 1;
                    }
                }
                return json[start..end];
            }
        }
    }
    return null;
}

/// Unescape a JSON string value in-place into an allocated buffer.
/// Converts \n to newline, \t to tab, \" to quote, \\ to backslash, etc.
pub fn jsonUnescapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            switch (s[i + 1]) {
                'n' => try out.append(allocator, '\n'),
                't' => try out.append(allocator, '\t'),
                'r' => try out.append(allocator, '\r'),
                '"' => try out.append(allocator, '"'),
                '\\' => try out.append(allocator, '\\'),
                '/' => try out.append(allocator, '/'),
                else => {
                    // Unknown escape, keep as-is
                    try out.append(allocator, s[i]);
                    try out.append(allocator, s[i + 1]);
                },
            }
            i += 2;
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Build a JSON header for a Jupyter message.
pub fn makeHeader(
    buf: []u8,
    msg_type: []const u8,
    msg_id: []const u8,
    session: []const u8,
) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"msg_id": "{s}", "session": "{s}", "username": "hao", "date": "", "msg_type": "{s}", "version": "5.3"}}
    , .{ msg_id, session, msg_type });
}

/// Generate a simple hex ID from random bytes.
pub fn generateId(buf: *[32]u8) void {
    var random_bytes: [16]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(nanoTimestamp());
    prng.random().bytes(&random_bytes);
    const hex_chars = "0123456789abcdef";
    for (random_bytes, 0..) |byte, i| {
        buf[i * 2] = hex_chars[byte >> 4];
        buf[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
}
