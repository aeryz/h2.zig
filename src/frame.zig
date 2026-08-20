const std = @import("std");

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
};

pub const Settings = struct {
    pub const FLAG_ACK: u8 = 0x01;

    frame: []const u8,

    pub fn init(frame: []const u8) !Settings {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.settings, frame);

        const payload_len = parse_payload_len(frame);

        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len % Setting.RAW_LEN != 0) {
            return error.InvalidSettingsLength;
        }

        if (parse_stream_id(frame) != 0) {
            return error.ProtocolError;
        }

        const settings: Settings = .{ .frame = frame };
        if (settings.is_ack() and payload_len != 0) {
            return error.FrameSizeError;
        }

        return settings;
    }

    pub fn is_ack(self: Settings) bool {
        return self.frame[4] & FLAG_ACK != 0;
    }

    pub fn iterate(self: Settings) SettingsIterator {
        return .{ .remaining = self.frame[FRAME_LEN..] };
    }
};

pub const SettingsIterator = struct {
    remaining: []const u8,

    pub fn next(self: *SettingsIterator) !?Setting {
        if (self.remaining.len == 0) {
            return null;
        }

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

pub const Setting = struct {
    pub const RAW_LEN: usize = 6;

    identifier: u16,
    value: u32,

    fn validate(self: Setting) !void {
        switch (self.identifier) {
            SETTINGS_ENABLE_PUSH => {
                if (self.value > 1) {
                    return error.ProtocolError;
                }
            },
            SETTINGS_INITIAL_WINDOW_SIZE => {
                if (self.value > MAX_INITIAL_WINDOW_SIZE) {
                    return error.FlowControlError;
                }
            },
            SETTINGS_MAX_FRAME_SIZE => {
                if (self.value < MIN_MAX_FRAME_SIZE or self.value > MAX_MAX_FRAME_SIZE) {
                    return error.ProtocolError;
                }
            },
            else => {},
        }
    }
};

pub const Ping = struct {
    const FLAG_ACK: u8 = 0x01;
    const DATA_LEN: usize = 8;

    frame: []const u8,

    pub fn init(frame: []const u8) !Ping {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.ping, frame);

        const payload_len = parse_payload_len(frame);

        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parse_stream_id(frame) != 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn is_ack(self: Ping) bool {
        return self.frame[4] & FLAG_ACK != 0;
    }

    pub fn data(self: Ping) *const [DATA_LEN]u8 {
        return self.frame[FRAME_LEN..][0..DATA_LEN];
    }
};

pub const GoAway = struct {
    const FIXED_DATA_LEN: usize = 8;

    frame: []const u8,

    pub fn init(frame: []const u8) !GoAway {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.goaway, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len < FIXED_DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parse_stream_id(frame) != 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn last_stream_id(self: GoAway) u31 {
        const reserved_plus_stream_id = std.mem.readInt(
            u32,
            self.frame[FRAME_LEN..][0..4],
            .big,
        );
        return @truncate(reserved_plus_stream_id & 0x7fff_ffff);
    }

    pub fn error_code(self: GoAway) u32 {
        return std.mem.readInt(
            u32,
            self.frame[FRAME_LEN + 4 ..][0..4],
            .big,
        );
    }

    pub fn debug_data(self: GoAway) []const u8 {
        return self.frame[FRAME_LEN + FIXED_DATA_LEN ..];
    }
};

pub const RstStream = struct {
    const DATA_LEN: usize = 4;

    frame: []const u8,

    pub fn init(frame: []const u8) !RstStream {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.rst_stream, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parse_stream_id(frame) == 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn stream_id(self: RstStream) u31 {
        return parse_stream_id(self.frame);
    }

    pub fn error_code(self: RstStream) u32 {
        return std.mem.readInt(
            u32,
            self.frame[FRAME_LEN..][0..DATA_LEN],
            .big,
        );
    }
};

pub const WindowUpdate = struct {
    const DATA_LEN: usize = 4;

    frame: []const u8,

    pub fn init(frame: []const u8) !WindowUpdate {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.window_update, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        const window_update: WindowUpdate = .{ .frame = frame };
        if (window_update.increment() == 0) {
            return error.ProtocolError;
        }

        return window_update;
    }

    pub fn stream_id(self: WindowUpdate) u31 {
        return parse_stream_id(self.frame);
    }

    pub fn increment(self: WindowUpdate) u31 {
        const reserved_plus_increment = std.mem.readInt(
            u32,
            self.frame[FRAME_LEN..][0..DATA_LEN],
            .big,
        );
        return @truncate(reserved_plus_increment & 0x7fff_ffff);
    }
};

pub const Data = struct {
    const FLAG_END_STREAM: u8 = 0x01;
    const FLAG_PADDED: u8 = 0x08;

    frame: []const u8,

    pub fn init(frame: []const u8) !Data {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.data, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parse_stream_id(frame) == 0) {
            return error.ProtocolError;
        }

        const data_frame: Data = .{ .frame = frame };
        if (data_frame.is_padded()) {
            if (payload_len == 0) {
                return error.ProtocolError;
            }

            if (data_frame.padding_len() >= payload_len) {
                return error.ProtocolError;
            }
        }

        return data_frame;
    }

    pub fn stream_id(self: Data) u31 {
        return parse_stream_id(self.frame);
    }

    pub fn is_end_stream(self: Data) bool {
        return self.frame[4] & FLAG_END_STREAM != 0;
    }

    pub fn is_padded(self: Data) bool {
        return self.frame[4] & FLAG_PADDED != 0;
    }

    pub fn data(self: Data) []const u8 {
        if (!self.is_padded()) {
            return self.frame[FRAME_LEN..];
        }

        const start = FRAME_LEN + 1;
        const end = self.frame.len - self.padding_len();
        return self.frame[start..end];
    }

    fn padding_len(self: Data) usize {
        return self.frame[FRAME_LEN];
    }
};

pub const Headers = struct {
    const FLAG_END_STREAM: u8 = 0x01;
    const FLAG_END_HEADERS: u8 = 0x04;
    const FLAG_PADDED: u8 = 0x08;
    const FLAG_PRIORITY: u8 = 0x20;
    const PRIORITY_LEN: usize = 5;

    pub const Priority = struct {
        exclusive: bool,
        stream_dependency: u31,
        weight: u16,
    };

    frame: []const u8,

    pub fn init(frame: []const u8) !Headers {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.headers, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parse_stream_id(frame) == 0) {
            return error.ProtocolError;
        }

        const headers: Headers = .{ .frame = frame };
        const fields_len = headers.prefix_len();
        if (payload_len < fields_len) {
            return error.ProtocolError;
        }

        if (headers.padding_len() > payload_len - fields_len) {
            return error.ProtocolError;
        }

        if (headers.priority()) |priority_info| {
            if (priority_info.stream_dependency == headers.stream_id()) {
                return error.ProtocolError;
            }
        }

        return headers;
    }

    pub fn stream_id(self: Headers) u31 {
        return parse_stream_id(self.frame);
    }

    pub fn is_end_stream(self: Headers) bool {
        return self.frame[4] & FLAG_END_STREAM != 0;
    }

    pub fn is_end_headers(self: Headers) bool {
        return self.frame[4] & FLAG_END_HEADERS != 0;
    }

    pub fn is_padded(self: Headers) bool {
        return self.frame[4] & FLAG_PADDED != 0;
    }

    pub fn has_priority(self: Headers) bool {
        return self.frame[4] & FLAG_PRIORITY != 0;
    }

    pub fn priority(self: Headers) ?Priority {
        if (!self.has_priority()) {
            return null;
        }

        const offset = FRAME_LEN + self.padding_prefix_len();
        const exclusive_plus_dependency = std.mem.readInt(
            u32,
            self.frame[offset..][0..4],
            .big,
        );

        return .{
            .exclusive = exclusive_plus_dependency & 0x8000_0000 != 0,
            .stream_dependency = @truncate(exclusive_plus_dependency & 0x7fff_ffff),
            .weight = @as(u16, self.frame[offset + 4]) + 1,
        };
    }

    pub fn header_block_fragment(self: Headers) []const u8 {
        const start = FRAME_LEN + self.prefix_len();
        const end = self.frame.len - self.padding_len();
        return self.frame[start..end];
    }

    fn prefix_len(self: Headers) usize {
        return self.padding_prefix_len() + self.priority_prefix_len();
    }

    fn padding_prefix_len(self: Headers) usize {
        if (self.is_padded()) {
            return 1;
        }
        return 0;
    }

    fn priority_prefix_len(self: Headers) usize {
        if (self.has_priority()) {
            return PRIORITY_LEN;
        }
        return 0;
    }

    fn padding_len(self: Headers) usize {
        if (!self.is_padded()) {
            return 0;
        }
        return self.frame[FRAME_LEN];
    }
};

pub const Continuation = struct {
    const FLAG_END_HEADERS: u8 = 0x04;

    frame: []const u8,

    pub fn init(frame: []const u8) !Continuation {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validate_frame_type(.continuation, frame);

        const payload_len = parse_payload_len(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parse_stream_id(frame) == 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn stream_id(self: Continuation) u31 {
        return parse_stream_id(self.frame);
    }

    pub fn is_end_headers(self: Continuation) bool {
        return self.frame[4] & FLAG_END_HEADERS != 0;
    }

    pub fn header_block_fragment(self: Continuation) []const u8 {
        return self.frame[FRAME_LEN..];
    }
};

fn validate_frame_type(expected: FrameType, frame: []const u8) !void {
    if (frame[3] != @intFromEnum(expected)) {
        return error.ProtocolError;
    }
}

fn parse_payload_len(frame: []const u8) usize {
    return std.mem.readInt(u24, frame[0..3], .big);
}

fn parse_stream_id(payload: []const u8) u31 {
    const reserved_plus_stream_id = std.mem.readInt(u32, payload[5..9], .big);
    return @truncate(reserved_plus_stream_id & 0x7fff_ffff);
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

test "ping exposes acknowledgment and opaque data" {
    const opaque_data = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0xaa, 0xbb, 0xcc, 0xdd };
    const frame = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
    } ++ opaque_data;
    const ack_frame = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x01, 0x80,
        0x00, 0x00, 0x00,
    } ++ opaque_data;

    const ping = try Ping.init(&frame);
    try std.testing.expect(!ping.is_ack());
    try std.testing.expectEqualSlices(u8, &opaque_data, ping.data());

    const ack = try Ping.init(&ack_frame);
    try std.testing.expect(ack.is_ack());
    try std.testing.expectEqualSlices(u8, &opaque_data, ack.data());
}

test "ping frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_data = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const extra_data = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const wrong_payload_length = [_]u8{
        0x00, 0x00, 0x07,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x08,
        0x04, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    const nonzero_stream = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, Ping.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Ping.init(&missing_data));
    try std.testing.expectError(error.InvalidFrameLength, Ping.init(&extra_data));
    try std.testing.expectError(error.FrameSizeError, Ping.init(&wrong_payload_length));
    try std.testing.expectError(error.ProtocolError, Ping.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Ping.init(&nonzero_stream));
}

test "goaway exposes fixed fields and debug data" {
    const frame = [_]u8{
        0x00, 0x00, 0x08,
        0x07, 0x00, 0x80,
        0x00, 0x00, 0x00,
        0x81, 0x02, 0x03,
        0x04, 0x00, 0x00,
        0x00, 0x08,
    };
    const debug_bytes = [_]u8{ 0x00, 0xff, 0x41, 0x42, 0x43 };
    const frame_with_debug_data = [_]u8{
        0x00, 0x00, 0x0d,
        0x07, 0xa5, 0x00,
        0x00, 0x00, 0x00,
        0xff, 0xff, 0xff,
        0xff, 0xde, 0xad,
        0xbe, 0xef,
    } ++ debug_bytes;

    const goaway = try GoAway.init(&frame);
    try std.testing.expectEqual(@as(u31, 0x0102_0304), goaway.last_stream_id());
    try std.testing.expectEqual(@as(u32, 0x0000_0008), goaway.error_code());
    try std.testing.expectEqualSlices(u8, &.{}, goaway.debug_data());

    const goaway_with_debug_data = try GoAway.init(&frame_with_debug_data);
    try std.testing.expectEqual(
        @as(u31, 0x7fff_ffff),
        goaway_with_debug_data.last_stream_id(),
    );
    try std.testing.expectEqual(
        @as(u32, 0xdead_beef),
        goaway_with_debug_data.error_code(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &debug_bytes,
        goaway_with_debug_data.debug_data(),
    );
}

test "goaway frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x08,
        0x07, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x08,
        0x07, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const short_payload = [_]u8{
        0x00, 0x00, 0x07,
        0x07, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x08,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    const nonzero_stream = [_]u8{
        0x00, 0x00, 0x08,
        0x07, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, GoAway.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, GoAway.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, GoAway.init(&extra_payload));
    try std.testing.expectError(error.FrameSizeError, GoAway.init(&short_payload));
    try std.testing.expectError(error.ProtocolError, GoAway.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, GoAway.init(&nonzero_stream));
}

test "rst_stream exposes stream and error code" {
    const frame = [_]u8{
        0x00, 0x00, 0x04,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x08,
    };
    const frame_with_reserved_bit = [_]u8{
        0x00, 0x00, 0x04,
        0x03, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0xde, 0xad, 0xbe,
        0xef,
    };

    const rst_stream = try RstStream.init(&frame);
    try std.testing.expectEqual(@as(u31, 1), rst_stream.stream_id());
    try std.testing.expectEqual(@as(u32, 0x0000_0008), rst_stream.error_code());

    const rst_stream_with_reserved_bit = try RstStream.init(&frame_with_reserved_bit);
    try std.testing.expectEqual(
        @as(u31, 0x7fff_ffff),
        rst_stream_with_reserved_bit.stream_id(),
    );
    try std.testing.expectEqual(
        @as(u32, 0xdead_beef),
        rst_stream_with_reserved_bit.error_code(),
    );
}

test "rst_stream frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    const wrong_payload_length = [_]u8{
        0x00, 0x00, 0x03,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x04,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x04,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, RstStream.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, RstStream.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, RstStream.init(&extra_payload));
    try std.testing.expectError(error.FrameSizeError, RstStream.init(&wrong_payload_length));
    try std.testing.expectError(error.ProtocolError, RstStream.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, RstStream.init(&zero_stream));
}

test "window_update exposes stream and increment" {
    const connection_update_frame = [_]u8{
        0x00, 0x00, 0x04,
        0x08, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x01,
    };
    const stream_update_frame = [_]u8{
        0x00, 0x00, 0x04,
        0x08, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0xff,
    };

    const connection_update = try WindowUpdate.init(&connection_update_frame);
    try std.testing.expectEqual(@as(u31, 0), connection_update.stream_id());
    try std.testing.expectEqual(@as(u31, 1), connection_update.increment());

    const stream_update = try WindowUpdate.init(&stream_update_frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), stream_update.stream_id());
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), stream_update.increment());
}

test "window_update frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x08, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x08, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x01, 0x00,
    };
    const wrong_payload_length = [_]u8{
        0x00, 0x00, 0x03,
        0x08, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x04,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x01,
    };
    const zero_increment = [_]u8{
        0x00, 0x00, 0x04,
        0x08, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x80, 0x00, 0x00,
        0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, WindowUpdate.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, WindowUpdate.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, WindowUpdate.init(&extra_payload));
    try std.testing.expectError(error.FrameSizeError, WindowUpdate.init(&wrong_payload_length));
    try std.testing.expectError(error.ProtocolError, WindowUpdate.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, WindowUpdate.init(&zero_increment));
}

test "data exposes payload and flags" {
    const empty_frame = [_]u8{
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const frame = [_]u8{
        0x00, 0x00, 0x04,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x01,
    } ++ payload;
    const padded_payload = [_]u8{ 0xaa, 0xbb };
    const padded_frame = [_]u8{
        0x00, 0x00, 0x06,
        0x00, 0x09, 0xff,
        0xff, 0xff, 0xff,
        0x03,
    } ++ padded_payload ++ [_]u8{ 0x00, 0x00, 0x00 };
    const padded_empty_frame = [_]u8{
        0x00, 0x00, 0x02,
        0x00, 0x08, 0x00,
        0x00, 0x00, 0x03,
        0x01, 0x00,
    };

    const empty_data = try Data.init(&empty_frame);
    try std.testing.expectEqual(@as(u31, 1), empty_data.stream_id());
    try std.testing.expect(!empty_data.is_end_stream());
    try std.testing.expect(!empty_data.is_padded());
    try std.testing.expectEqualSlices(u8, &.{}, empty_data.data());

    const data = try Data.init(&frame);
    try std.testing.expectEqualSlices(u8, &payload, data.data());

    const padded_data = try Data.init(&padded_frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), padded_data.stream_id());
    try std.testing.expect(padded_data.is_end_stream());
    try std.testing.expect(padded_data.is_padded());
    try std.testing.expectEqualSlices(u8, &padded_payload, padded_data.data());

    const padded_empty_data = try Data.init(&padded_empty_frame);
    try std.testing.expectEqualSlices(u8, &.{}, padded_empty_data.data());
}

test "data frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x00,
        0x06, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const padded_without_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x00, 0x08, 0x00,
        0x00, 0x00, 0x01,
    };
    const excessive_padding = [_]u8{
        0x00, 0x00, 0x02,
        0x00, 0x08, 0x00,
        0x00, 0x00, 0x01,
        0x02, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, Data.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Data.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, Data.init(&extra_payload));
    try std.testing.expectError(error.ProtocolError, Data.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Data.init(&zero_stream));
    try std.testing.expectError(error.ProtocolError, Data.init(&padded_without_payload));
    try std.testing.expectError(error.ProtocolError, Data.init(&excessive_padding));
}

test "headers exposes flags priority and header block fragment" {
    const fragment = [_]u8{ 0x82, 0x86, 0x84 };
    const frame = [_]u8{
        0x00, 0x00, 0x03,
        0x01, 0x05, 0x00,
        0x00, 0x00, 0x01,
    } ++ fragment;
    const padded_fragment = [_]u8{ 0xaa, 0xbb };
    const padded_priority_frame = [_]u8{
        0x00, 0x00, 0x0a,
        0x01, 0x2d, 0x80,
        0x00, 0x00, 0x05,
        0x02, 0x80, 0x00,
        0x00, 0x03, 0xff,
    } ++ padded_fragment ++ [_]u8{ 0x00, 0x00 };

    const headers = try Headers.init(&frame);
    try std.testing.expectEqual(@as(u31, 1), headers.stream_id());
    try std.testing.expect(headers.is_end_stream());
    try std.testing.expect(headers.is_end_headers());
    try std.testing.expect(!headers.is_padded());
    try std.testing.expect(!headers.has_priority());
    try std.testing.expectEqual(null, headers.priority());
    try std.testing.expectEqualSlices(u8, &fragment, headers.header_block_fragment());

    const padded_headers = try Headers.init(&padded_priority_frame);
    try std.testing.expectEqual(@as(u31, 5), padded_headers.stream_id());
    try std.testing.expect(padded_headers.is_padded());
    try std.testing.expect(padded_headers.has_priority());
    try std.testing.expectEqual(
        Headers.Priority{
            .exclusive = true,
            .stream_dependency = 3,
            .weight = 256,
        },
        padded_headers.priority().?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &padded_fragment,
        padded_headers.header_block_fragment(),
    );
}

test "headers frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x01,
        0x01, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x01, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x00,
        0x09, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x00,
        0x01, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const padded_without_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x01, 0x08, 0x00,
        0x00, 0x00, 0x01,
    };
    const short_priority = [_]u8{
        0x00, 0x00, 0x04,
        0x01, 0x20, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00,
    };
    const excessive_padding = [_]u8{
        0x00, 0x00, 0x02,
        0x01, 0x08, 0x00,
        0x00, 0x00, 0x01,
        0x02, 0x00,
    };
    const self_dependency = [_]u8{
        0x00, 0x00, 0x05,
        0x01, 0x20, 0x00,
        0x00, 0x00, 0x03,
        0x80, 0x00, 0x00,
        0x03, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, Headers.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Headers.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, Headers.init(&extra_payload));
    try std.testing.expectError(error.ProtocolError, Headers.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Headers.init(&zero_stream));
    try std.testing.expectError(error.ProtocolError, Headers.init(&padded_without_payload));
    try std.testing.expectError(error.ProtocolError, Headers.init(&short_priority));
    try std.testing.expectError(error.ProtocolError, Headers.init(&excessive_padding));
    try std.testing.expectError(error.ProtocolError, Headers.init(&self_dependency));
}

test "continuation exposes flags and header block fragment" {
    const empty_frame = [_]u8{
        0x00, 0x00, 0x00,
        0x09, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const fragment = [_]u8{ 0x82, 0x86, 0x84 };
    const frame = [_]u8{
        0x00, 0x00, 0x03,
        0x09, 0xff, 0xff,
        0xff, 0xff, 0xff,
    } ++ fragment;

    const empty_continuation = try Continuation.init(&empty_frame);
    try std.testing.expectEqual(@as(u31, 1), empty_continuation.stream_id());
    try std.testing.expect(!empty_continuation.is_end_headers());
    try std.testing.expectEqualSlices(
        u8,
        &.{},
        empty_continuation.header_block_fragment(),
    );

    const continuation = try Continuation.init(&frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), continuation.stream_id());
    try std.testing.expect(continuation.is_end_headers());
    try std.testing.expectEqualSlices(
        u8,
        &fragment,
        continuation.header_block_fragment(),
    );
}

test "continuation frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x01,
        0x09, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x00,
        0x09, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x00,
        0x01, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x00,
        0x09, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, Continuation.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Continuation.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, Continuation.init(&extra_payload));
    try std.testing.expectError(error.ProtocolError, Continuation.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Continuation.init(&zero_stream));
}
