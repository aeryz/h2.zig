const std = @import("std");

/// This setting indicates the size of the largest frame payload that the sender is willing to
/// receive, in units of octets.
///
/// The initial value is 214 (16,384) octets. The value advertised by an endpoint
/// MUST be between this initial value and the maximum allowed frame size
/// (224-1 or 16,777,215 octets), inclusive. Values outside this range MUST be
/// treated as a connection error (Section 5.4.1) of type PROTOCOL_ERROR.
const SETTINGS_ENABLE_PUSH: u16 = 0x2;
const SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x4;
const SETTINGS_MAX_FRAME_SIZE: u16 = 0x5;
const MIN_MAX_FRAME_SIZE: u32 = 1 << 14;
const MAX_MAX_FRAME_SIZE: u32 = (1 << 24) - 1;
const MAX_INITIAL_WINDOW_SIZE: u32 = (1 << 31) - 1;
const FRAME_LEN: usize = 9;

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

// const FrameHeader = packed struct {
//     pub const RAW_LEN: usize = 9;
//     /// Frame-payload length
//     length: u24,
//     type: FrameType,
//     /// An 8-bit field reserved for boolean flags specific to the frame type.
//     flags: u8,
//     _reserved: u1 = 0,
//     stream_identifier: u31,

const Setting = struct {
    pub const RAW_LEN: usize = 6;

    identifier: u16,
    value: u32,

    fn validate(self: Setting) !void {
        switch (self.identifier) {
            SETTINGS_ENABLE_PUSH => {
                if (self.value > 1)
                    return error.ProtocolError;
            },
            SETTINGS_INITIAL_WINDOW_SIZE => {
                if (self.value > MAX_INITIAL_WINDOW_SIZE)
                    return error.FlowControlError;
            },
            SETTINGS_MAX_FRAME_SIZE => {
                if (self.value < MIN_MAX_FRAME_SIZE or self.value > MAX_MAX_FRAME_SIZE)
                    return error.ProtocolError;
            },
            else => {},
        }
    }
};

const Settings = struct {
    pub const FLAG_ACK: u8 = 0x01;

    frame: []const u8,

    pub fn init(frame: []const u8) !Settings {
        if (frame.len < FRAME_LEN)
            return error.InvalidFrameLength;

        const payload_len: usize = std.mem.readInt(u24, frame[0..3], .big);

        if (frame[3] != @intFromEnum(FrameType.settings))
            return error.ProtocolError;

        if (frame.len != FRAME_LEN + payload_len)
            return error.InvalidFrameLength;

        if (payload_len % Setting.RAW_LEN != 0)
            return error.InvalidSettingsLength;

        if (parse_stream_id(frame) != 0)
            return error.ProtocolError;

        const settings: Settings = .{ .frame = frame };
        if (settings.is_ack() and payload_len != 0)
            return error.FrameSizeError;

        return settings;
    }

    pub fn is_ack(self: Settings) bool {
        return self.frame[4] & FLAG_ACK != 0;
    }

    pub fn iterate(self: Settings) SettingsIterator {
        return .{ .remaining = self.frame[FRAME_LEN..] };
    }
};

const SettingsIterator = struct {
    remaining: []const u8,

    pub fn next(self: *SettingsIterator) !?Setting {
        if (self.remaining.len == 0)
            return null;

        const raw = self.remaining[0..Setting.RAW_LEN];
        self.remaining = self.remaining[Setting.RAW_LEN..];

        const setting: Setting = .{
            .identifier = std.mem.readInt(u16, raw[0..2], .big),
            .value = std.mem.readInt(u32, raw[2..6], .big),
        };
        try setting.validate();
        return setting;
    }
};

fn parse_stream_id(payload: []const u8) u31 {
    const reserved_plus_stream_id = std.mem.readInt(u32, payload[5..9], .big);
    return @truncate(reserved_plus_stream_id & 0x7fff_ffff);
}

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

    const expectSettings = struct {
        fn equal(payload: []const u8, expected: []const Setting) !void {
            var iterator = (try Settings.init(payload)).iterate();

            for (expected) |expected_setting| {
                try std.testing.expectEqual(expected_setting, (try iterator.next()).?);
            }
            try std.testing.expectEqual(null, try iterator.next());
        }
    }.equal;

    try expectSettings(&zero_settings, &.{});
    try expectSettings(&one_setting, &.{
        .{ .identifier = 0x01, .value = 4096 },
    });
    try expectSettings(&two_settings, &.{
        .{ .identifier = 0x01, .value = 4096 },
        .{ .identifier = 0x03, .value = 100 },
    });
    try expectSettings(&three_settings, &.{
        .{ .identifier = 0x01, .value = 4096 },
        .{ .identifier = 0x03, .value = 100 },
        .{ .identifier = 0x04, .value = 65535 },
    });
    try expectSettings(&four_settings, &.{
        .{ .identifier = 0x01, .value = 4096 },
        .{ .identifier = 0x02, .value = 0 },
        .{ .identifier = 0x03, .value = 100 },
        .{ .identifier = 0x04, .value = 65535 },
    });
}

test "settings frame validation works" {
    const settings = [_]u8{
        0x00, 0x00, 0x00,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const settings_ack = [_]u8{
        0x00, 0x00, 0x00,
        0x04, 0x01, 0x00,
        0x00, 0x00, 0x00,
    };
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x06,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,
    };
    const invalid_settings_length = [_]u8{
        0x00, 0x00, 0x01,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x00,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const nonzero_stream = [_]u8{
        0x00, 0x00, 0x00,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const ack_with_payload = [_]u8{
        0x00, 0x00, 0x06,
        0x04, 0x01, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x01, 0x00,
        0x00, 0x10, 0x00,
    };

    try std.testing.expect(!(try Settings.init(&settings)).is_ack());
    try std.testing.expect((try Settings.init(&settings_ack)).is_ack());
    try std.testing.expectError(error.InvalidFrameLength, Settings.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Settings.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, Settings.init(&extra_payload));
    try std.testing.expectError(error.InvalidSettingsLength, Settings.init(&invalid_settings_length));
    try std.testing.expectError(error.ProtocolError, Settings.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Settings.init(&nonzero_stream));
    try std.testing.expectError(error.FrameSizeError, Settings.init(&ack_with_payload));
}

test "setting values are validated" {
    const parseOne = struct {
        fn parse(identifier: u16, value: u32) !Setting {
            var frame = [_]u8{
                0x00, 0x00, 0x06,
                0x04, 0x00, 0x00,
                0x00, 0x00, 0x00,
                0x00, 0x00, 0x00,
                0x00, 0x00, 0x00,
            };
            std.mem.writeInt(u16, frame[9..11], identifier, .big);
            std.mem.writeInt(u32, frame[11..15], value, .big);

            var iterator = (try Settings.init(&frame)).iterate();
            return (try iterator.next()).?;
        }
    }.parse;

    try std.testing.expectEqual(
        Setting{ .identifier = SETTINGS_ENABLE_PUSH, .value = 1 },
        try parseOne(SETTINGS_ENABLE_PUSH, 1),
    );
    try std.testing.expectEqual(
        Setting{ .identifier = SETTINGS_INITIAL_WINDOW_SIZE, .value = MAX_INITIAL_WINDOW_SIZE },
        try parseOne(SETTINGS_INITIAL_WINDOW_SIZE, MAX_INITIAL_WINDOW_SIZE),
    );
    try std.testing.expectEqual(
        Setting{ .identifier = SETTINGS_MAX_FRAME_SIZE, .value = MIN_MAX_FRAME_SIZE },
        try parseOne(SETTINGS_MAX_FRAME_SIZE, MIN_MAX_FRAME_SIZE),
    );
    try std.testing.expectEqual(
        Setting{ .identifier = SETTINGS_MAX_FRAME_SIZE, .value = MAX_MAX_FRAME_SIZE },
        try parseOne(SETTINGS_MAX_FRAME_SIZE, MAX_MAX_FRAME_SIZE),
    );

    try std.testing.expectError(error.ProtocolError, parseOne(SETTINGS_ENABLE_PUSH, 2));
    try std.testing.expectError(
        error.FlowControlError,
        parseOne(SETTINGS_INITIAL_WINDOW_SIZE, MAX_INITIAL_WINDOW_SIZE + 1),
    );
    try std.testing.expectError(
        error.ProtocolError,
        parseOne(SETTINGS_MAX_FRAME_SIZE, MIN_MAX_FRAME_SIZE - 1),
    );
    try std.testing.expectError(
        error.ProtocolError,
        parseOne(SETTINGS_MAX_FRAME_SIZE, MAX_MAX_FRAME_SIZE + 1),
    );
}
