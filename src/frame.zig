const std = @import("std");

/// This setting indicates the size of the largest frame payload that the sender is willing to
/// receive, in units of octets.
///
/// The initial value is 214 (16,384) octets. The value advertised by an endpoint
/// MUST be between this initial value and the maximum allowed frame size
/// (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be
/// treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
const SETTINGS_MAX_FRAME_SIZE: usize = 0x5;

const FrameType = enum(u8) {
    data = 0x0,
    headers = 0x1,
    priority = 0x2,
    rst_stream = 0x3,
    settings = 0x4,
    push_promise = 0x5,
    ping = 0x6,
    goaway = 0x7,
    window_update = 0x8,
    continuation = 0x9,

    pub fn fromU8(raw: u8) ?FrameType {
        if (raw <= @intFromEnum(FrameType.continuation)) {
            return @enumFromInt(raw);
        } else {
            return null;
        }
    }
};

const FrameHeader = struct {
    pub const RAW_LEN: usize = 9;
    /// Frame-payload length
    length: u24,
    type: FrameType,
    /// An 8-bit field reserved for boolean flags specific to the frame type.
    flags: u8,
    _reserved: u1 = 0,
    stream_identifier: u31,

    pub fn parse(bytes: []const u8) !FrameHeader {
        if (bytes.len < FrameHeader.RAW_LEN) {
            unreachable;
        }

        const len = std.mem.readInt(u24, bytes[0..3], .big);
        // TODO: len validation

        const ty = std.mem.readInt(u8, bytes[3..4], .big);

        const reserved_plus_stream_id = std.mem.readInt(u32, bytes[5..9], .big);
        const stream_id: u31 = @truncate(reserved_plus_stream_id & 0x7fff_ffff);

        return .{
            .length = len,
            .type = FrameType.fromU8(ty) orelse unreachable,
            // flags are validated if/when a certain frame is used
            .flags = std.mem.readInt(u8, bytes[4..5], .big),
            .stream_identifier = stream_id,
        };
    }
};

const Settings = struct {
    pub const TYPE: u8 = 0x04;

    frame: FrameHeader,

    pub fn init(frame: FrameHeader) !Settings {
        if (frame.length % Setting.RAW_LEN != 0) {
            unreachable;
        }

        return .{ .frame = frame };
    }

    pub fn iterate(self: *const Settings) SettingsIterator {
        const settings_start: [*]u8 = @ptrFromInt(@intFromPtr(self) + @sizeOf(FrameHeader));

        return .{
            .payload = settings_start[0..self.frame.length],
        };
    }
};

const Setting = struct {
    pub const RAW_LEN: usize = 3;

    identifier: u16,
    value: u32,
};

const SettingsIterator = struct {
    payload: []u8,
    index: usize = 0,

    pub fn next(self: *SettingsIterator) ?Setting {
        if (self.index >= self.payload.len)
            return null;

        const setting: Setting = .{
            .identifier = std.mem.readInt(u16, self.payload[self.index..][0..2], .big),
            .value = std.mem.readInt(u32, self.payload[self.index + 2 ..][0..4], .big),
        };

        self.index += 6;

        return setting;
    }
};

// Order of impl
// ---------------
// SETTINGS
// PING
// GOAWAY
// RST_STREAM
// WINDOW_UPDATE
// DATA
// HEADERS
// CONTINUATION
// ---------------

test "valid frames can be parsed" {
    const cases = [_][9]u8{
        // SETTINGS, empty payload
        // length=0, type=0x4, flags=0, stream=0
        .{ 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },

        // SETTINGS ACK
        // length=0, type=0x4, flags=ACK(0x1), stream=0
        .{ 0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00 },

        // SETTINGS with one setting
        // payload length=6
        .{ 0x00, 0x00, 0x06, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },

        // PING
        // length=8, type=0x6, flags=0, stream=0
        .{ 0x00, 0x00, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00 },

        // PING ACK
        .{ 0x00, 0x00, 0x08, 0x06, 0x01, 0x00, 0x00, 0x00, 0x00 },

        // DATA on stream 1, 16-byte payload
        .{ 0x00, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 },

        // DATA on stream 1 with END_STREAM
        .{ 0x00, 0x00, 0x10, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01 },

        // HEADERS on stream 1, 20-byte HPACK fragment
        // END_HEADERS = 0x4
        .{ 0x00, 0x00, 0x14, 0x01, 0x04, 0x00, 0x00, 0x00, 0x01 },

        // HEADERS on stream 3, END_STREAM | END_HEADERS
        // flags = 0x1 | 0x4 = 0x5
        .{ 0x00, 0x00, 0x0a, 0x01, 0x05, 0x00, 0x00, 0x00, 0x03 },

        // RST_STREAM on stream 5
        // payload must be exactly 4 bytes
        .{ 0x00, 0x00, 0x04, 0x03, 0x00, 0x00, 0x00, 0x00, 0x05 },

        // WINDOW_UPDATE on stream 1
        // payload must be 4 bytes
        .{ 0x00, 0x00, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00, 0x01 },

        // CONTINUATION on stream 1, 32-byte fragment, END_HEADERS
        .{ 0x00, 0x00, 0x20, 0x09, 0x04, 0x00, 0x00, 0x00, 0x01 },
    };

    for (cases) |case| {
        _ = try FrameHeader.parse(&case);
    }
}

test "reserved field is ignored" {
    const cases = [_][9]u8{
        .{ 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 },

        .{ 0x00, 0x00, 0x00, 0x04, 0x00, 0xff, 0x00, 0x00, 0x00 },
    };

    for (cases) |case| {
        const header = try FrameHeader.parse(&case);
        try std.testing.expectEqual(0, header._reserved);
    }
}

test "setting iteration works" {
    const zero_settings = [_]u8{
        // Header: length=0, SETTINGS, flags=0, stream=0
        0x00, 0x00, 0x00,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };

    const one_setting = [_]u8{
        // Header: length=6
        0x00, 0x00, 0x06,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,

        // SETTINGS_HEADER_TABLE_SIZE = 4096
        // Setting{ .identifier = 0x0001, .value = 4096 }
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,
    };

    const two_settings = [_]u8{
        // Header: length=12
        0x00, 0x00, 0x0c,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,

        // SETTINGS_HEADER_TABLE_SIZE = 4096
        // Setting{ .identifier = 0x0001, .value = 4096 }
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,

        // SETTINGS_MAX_CONCURRENT_STREAMS = 100
        // Setting{ .identifier = 0x0003, .value = 100 }
        0x00, 0x03, 0x00,
        0x00, 0x00, 0x64,
    };

    const three_settings = [_]u8{
        // Header: length=18
        0x00, 0x00, 0x12,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,

        // SETTINGS_HEADER_TABLE_SIZE = 4096
        // Setting{ .identifier = 0x0001, .value = 4096 }
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,

        // SETTINGS_MAX_CONCURRENT_STREAMS = 100
        // Setting{ .identifier = 0x0003, .value = 100 }
        0x00, 0x03, 0x00,
        0x00, 0x00, 0x64,

        // SETTINGS_INITIAL_WINDOW_SIZE = 65535
        // Setting{ .identifier = 0x0004, .value = 65535 }
        0x00, 0x04, 0x00,
        0x00, 0xff, 0xff,
    };

    const four_settings = [_]u8{
        // Header: length=24
        0x00, 0x00, 0x18,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,

        // SETTINGS_HEADER_TABLE_SIZE = 4096
        // Setting{ .identifier = 0x0001, .value = 4096 }
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,

        // SETTINGS_ENABLE_PUSH = 0
        // Setting{ .identifier = 0x0002, .value = 0 }
        0x00, 0x02, 0x00,
        0x00, 0x00, 0x00,

        // SETTINGS_MAX_CONCURRENT_STREAMS = 100
        // Setting{ .identifier = 0x0003, .value = 100 }
        0x00, 0x03, 0x00,
        0x00, 0x00, 0x64,

        // SETTINGS_INITIAL_WINDOW_SIZE = 65535
        // Setting{ .identifier = 0x0004, .value = 65535 }
        0x00, 0x04, 0x00,
        0x00, 0xff, 0xff,
    };

    const settings_zero = try Settings.init(try FrameHeader.parse(&zero_settings));
    const settings_one = try Settings.init(try FrameHeader.parse(&one_setting));
    _ = try Settings.init(try FrameHeader.parse(&two_settings));
    _ = try Settings.init(try FrameHeader.parse(&three_settings));
    _ = try Settings.init(try FrameHeader.parse(&four_settings));

    var settings_zero_iter = settings_zero.iterate();
    try std.testing.expectEqual(null, settings_zero_iter.next());

    var settings_one_iter = settings_one.iterate();
    try std.testing.expectEqual(
        Setting{
            .identifier = 0x01,
            .value = 4096,
        },
        settings_one_iter.next().?,
    );
    try std.testing.expectEqual(null, settings_one_iter.next());
}
