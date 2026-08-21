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

        try validateFrameType(.settings, frame);

        const payload_len = parsePayloadLen(frame);

        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len % Setting.RAW_LEN != 0) {
            return error.InvalidSettingsLength;
        }

        if (parseStreamId(frame) != 0) {
            return error.ProtocolError;
        }

        const settings: Settings = .{ .frame = frame };
        if (settings.isAck() and payload_len != 0) {
            return error.FrameSizeError;
        }

        return settings;
    }

    pub fn isAck(self: Settings) bool {
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

        try validateFrameType(.ping, frame);

        const payload_len = parsePayloadLen(frame);

        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parseStreamId(frame) != 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn isAck(self: Ping) bool {
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

        try validateFrameType(.goaway, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len < FIXED_DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parseStreamId(frame) != 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn lastStreamId(self: GoAway) u31 {
        const reserved_plus_stream_id = std.mem.readInt(
            u32,
            self.frame[FRAME_LEN..][0..4],
            .big,
        );
        return @truncate(reserved_plus_stream_id & 0x7fff_ffff);
    }

    pub fn errorCode(self: GoAway) u32 {
        return std.mem.readInt(
            u32,
            self.frame[FRAME_LEN + 4 ..][0..4],
            .big,
        );
    }

    pub fn debugData(self: GoAway) []const u8 {
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

        try validateFrameType(.rst_stream, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn streamId(self: RstStream) u31 {
        return parseStreamId(self.frame);
    }

    pub fn errorCode(self: RstStream) u32 {
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

        try validateFrameType(.window_update, frame);

        const payload_len = parsePayloadLen(frame);
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

    pub fn streamId(self: WindowUpdate) u31 {
        return parseStreamId(self.frame);
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

        try validateFrameType(.data, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        const data_frame: Data = .{ .frame = frame };
        if (data_frame.isPadded()) {
            if (payload_len == 0) {
                return error.ProtocolError;
            }

            if (data_frame.paddingLen() >= payload_len) {
                return error.ProtocolError;
            }
        }

        return data_frame;
    }

    pub fn streamId(self: Data) u31 {
        return parseStreamId(self.frame);
    }

    pub fn isEndStream(self: Data) bool {
        return self.frame[4] & FLAG_END_STREAM != 0;
    }

    pub fn isPadded(self: Data) bool {
        return self.frame[4] & FLAG_PADDED != 0;
    }

    pub fn data(self: Data) []const u8 {
        if (!self.isPadded()) {
            return self.frame[FRAME_LEN..];
        }

        const start = FRAME_LEN + 1;
        const end = self.frame.len - self.paddingLen();
        return self.frame[start..end];
    }

    fn paddingLen(self: Data) usize {
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

        try validateFrameType(.headers, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        const headers: Headers = .{ .frame = frame };
        const fields_len = headers.prefixLen();
        if (payload_len < fields_len) {
            return error.ProtocolError;
        }

        if (headers.paddingLen() > payload_len - fields_len) {
            return error.ProtocolError;
        }

        if (headers.priority()) |priority_info| {
            if (priority_info.stream_dependency == headers.streamId()) {
                return error.ProtocolError;
            }
        }

        return headers;
    }

    pub fn streamId(self: Headers) u31 {
        return parseStreamId(self.frame);
    }

    pub fn isEndStream(self: Headers) bool {
        return self.frame[4] & FLAG_END_STREAM != 0;
    }

    pub fn isEndHeaders(self: Headers) bool {
        return self.frame[4] & FLAG_END_HEADERS != 0;
    }

    pub fn isPadded(self: Headers) bool {
        return self.frame[4] & FLAG_PADDED != 0;
    }

    pub fn hasPriority(self: Headers) bool {
        return self.frame[4] & FLAG_PRIORITY != 0;
    }

    pub fn priority(self: Headers) ?Headers.Priority {
        if (!self.hasPriority()) {
            return null;
        }

        const offset = FRAME_LEN + self.paddingPrefixLen();
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

    pub fn headerBlockFragment(self: Headers) []const u8 {
        const start = FRAME_LEN + self.prefixLen();
        const end = self.frame.len - self.paddingLen();
        return self.frame[start..end];
    }

    fn prefixLen(self: Headers) usize {
        return self.paddingPrefixLen() + self.priorityPrefixLen();
    }

    fn paddingPrefixLen(self: Headers) usize {
        if (self.isPadded()) {
            return 1;
        }
        return 0;
    }

    fn priorityPrefixLen(self: Headers) usize {
        if (self.hasPriority()) {
            return PRIORITY_LEN;
        }
        return 0;
    }

    fn paddingLen(self: Headers) usize {
        if (!self.isPadded()) {
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

        try validateFrameType(.continuation, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        return .{ .frame = frame };
    }

    pub fn streamId(self: Continuation) u31 {
        return parseStreamId(self.frame);
    }

    pub fn isEndHeaders(self: Continuation) bool {
        return self.frame[4] & FLAG_END_HEADERS != 0;
    }

    pub fn headerBlockFragment(self: Continuation) []const u8 {
        return self.frame[FRAME_LEN..];
    }
};

pub const PushPromise = struct {
    const FLAG_END_HEADERS: u8 = 0x04;
    const FLAG_PADDED: u8 = 0x08;
    const PROMISED_STREAM_ID_LEN: usize = 4;

    frame: []const u8,

    pub fn init(frame: []const u8) !PushPromise {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validateFrameType(.push_promise, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        const push_promise: PushPromise = .{ .frame = frame };
        const fields_len = push_promise.prefixLen();
        if (payload_len < fields_len) {
            return error.FrameSizeError;
        }

        if (push_promise.paddingLen() > payload_len - fields_len) {
            return error.ProtocolError;
        }

        if (push_promise.promisedStreamId() == 0) {
            return error.ProtocolError;
        }

        return push_promise;
    }

    pub fn streamId(self: PushPromise) u31 {
        return parseStreamId(self.frame);
    }

    pub fn isEndHeaders(self: PushPromise) bool {
        return self.frame[4] & FLAG_END_HEADERS != 0;
    }

    pub fn isPadded(self: PushPromise) bool {
        return self.frame[4] & FLAG_PADDED != 0;
    }

    pub fn promisedStreamId(self: PushPromise) u31 {
        const offset = FRAME_LEN + self.paddingPrefixLen();
        const reserved_plus_stream_id = std.mem.readInt(
            u32,
            self.frame[offset..][0..PROMISED_STREAM_ID_LEN],
            .big,
        );
        return @truncate(reserved_plus_stream_id & 0x7fff_ffff);
    }

    pub fn headerBlockFragment(self: PushPromise) []const u8 {
        const start = FRAME_LEN + self.prefixLen();
        const end = self.frame.len - self.paddingLen();
        return self.frame[start..end];
    }

    fn prefixLen(self: PushPromise) usize {
        return self.paddingPrefixLen() + PROMISED_STREAM_ID_LEN;
    }

    fn paddingPrefixLen(self: PushPromise) usize {
        if (self.isPadded()) {
            return 1;
        }
        return 0;
    }

    fn paddingLen(self: PushPromise) usize {
        if (!self.isPadded()) {
            return 0;
        }
        return self.frame[FRAME_LEN];
    }
};

pub const Priority = struct {
    const DATA_LEN: usize = 5;

    frame: []const u8,

    pub fn init(frame: []const u8) !Priority {
        if (frame.len < FRAME_LEN) {
            return error.InvalidFrameLength;
        }

        try validateFrameType(.priority, frame);

        const payload_len = parsePayloadLen(frame);
        if (frame.len != FRAME_LEN + payload_len) {
            return error.InvalidFrameLength;
        }

        if (payload_len != DATA_LEN) {
            return error.FrameSizeError;
        }

        if (parseStreamId(frame) == 0) {
            return error.ProtocolError;
        }

        const priority: Priority = .{ .frame = frame };
        if (priority.streamDependency() == priority.streamId()) {
            return error.ProtocolError;
        }

        return priority;
    }

    pub fn streamId(self: Priority) u31 {
        return parseStreamId(self.frame);
    }

    pub fn isExclusive(self: Priority) bool {
        return self.rawDependency() & 0x8000_0000 != 0;
    }

    pub fn streamDependency(self: Priority) u31 {
        return @truncate(self.rawDependency() & 0x7fff_ffff);
    }

    pub fn weight(self: Priority) u16 {
        return @as(u16, self.frame[FRAME_LEN + 4]) + 1;
    }

    fn rawDependency(self: Priority) u32 {
        return std.mem.readInt(
            u32,
            self.frame[FRAME_LEN..][0..4],
            .big,
        );
    }
};

fn validateFrameType(expected: FrameType, frame: []const u8) !void {
    if (frame[3] != @intFromEnum(expected)) {
        return error.ProtocolError;
    }
}

fn parsePayloadLen(frame: []const u8) usize {
    return std.mem.readInt(u24, frame[0..3], .big);
}

fn parseStreamId(payload: []const u8) u31 {
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

    try std.testing.expect(!(try Settings.init(&settings)).isAck());
    try std.testing.expect((try Settings.init(&settings_ack)).isAck());
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
    try std.testing.expect(!ping.isAck());
    try std.testing.expectEqualSlices(u8, &opaque_data, ping.data());

    const ack = try Ping.init(&ack_frame);
    try std.testing.expect(ack.isAck());
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
    try std.testing.expectEqual(@as(u31, 0x0102_0304), goaway.lastStreamId());
    try std.testing.expectEqual(@as(u32, 0x0000_0008), goaway.errorCode());
    try std.testing.expectEqualSlices(u8, &.{}, goaway.debugData());

    const goaway_with_debug_data = try GoAway.init(&frame_with_debug_data);
    try std.testing.expectEqual(
        @as(u31, 0x7fff_ffff),
        goaway_with_debug_data.lastStreamId(),
    );
    try std.testing.expectEqual(
        @as(u32, 0xdead_beef),
        goaway_with_debug_data.errorCode(),
    );
    try std.testing.expectEqualSlices(
        u8,
        &debug_bytes,
        goaway_with_debug_data.debugData(),
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
    try std.testing.expectEqual(@as(u31, 1), rst_stream.streamId());
    try std.testing.expectEqual(@as(u32, 0x0000_0008), rst_stream.errorCode());

    const rst_stream_with_reserved_bit = try RstStream.init(&frame_with_reserved_bit);
    try std.testing.expectEqual(
        @as(u31, 0x7fff_ffff),
        rst_stream_with_reserved_bit.streamId(),
    );
    try std.testing.expectEqual(
        @as(u32, 0xdead_beef),
        rst_stream_with_reserved_bit.errorCode(),
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
    try std.testing.expectEqual(@as(u31, 0), connection_update.streamId());
    try std.testing.expectEqual(@as(u31, 1), connection_update.increment());

    const stream_update = try WindowUpdate.init(&stream_update_frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), stream_update.streamId());
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
    try std.testing.expectEqual(@as(u31, 1), empty_data.streamId());
    try std.testing.expect(!empty_data.isEndStream());
    try std.testing.expect(!empty_data.isPadded());
    try std.testing.expectEqualSlices(u8, &.{}, empty_data.data());

    const data = try Data.init(&frame);
    try std.testing.expectEqualSlices(u8, &payload, data.data());

    const padded_data = try Data.init(&padded_frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), padded_data.streamId());
    try std.testing.expect(padded_data.isEndStream());
    try std.testing.expect(padded_data.isPadded());
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
    try std.testing.expectEqual(@as(u31, 1), headers.streamId());
    try std.testing.expect(headers.isEndStream());
    try std.testing.expect(headers.isEndHeaders());
    try std.testing.expect(!headers.isPadded());
    try std.testing.expect(!headers.hasPriority());
    try std.testing.expectEqual(null, headers.priority());
    try std.testing.expectEqualSlices(u8, &fragment, headers.headerBlockFragment());

    const padded_headers = try Headers.init(&padded_priority_frame);
    try std.testing.expectEqual(@as(u31, 5), padded_headers.streamId());
    try std.testing.expect(padded_headers.isPadded());
    try std.testing.expect(padded_headers.hasPriority());
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
        padded_headers.headerBlockFragment(),
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
    try std.testing.expectEqual(@as(u31, 1), empty_continuation.streamId());
    try std.testing.expect(!empty_continuation.isEndHeaders());
    try std.testing.expectEqualSlices(
        u8,
        &.{},
        empty_continuation.headerBlockFragment(),
    );

    const continuation = try Continuation.init(&frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), continuation.streamId());
    try std.testing.expect(continuation.isEndHeaders());
    try std.testing.expectEqualSlices(
        u8,
        &fragment,
        continuation.headerBlockFragment(),
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

test "push_promise exposes promised stream and header block fragment" {
    const frame = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x02,
    };
    const fragment = [_]u8{ 0x82, 0x86, 0x84 };
    const padded_frame = [_]u8{
        0x00, 0x00, 0x0a,
        0x05, 0x0c, 0x80,
        0x00, 0x00, 0x01,
        0x02, 0x80, 0x00,
        0x00, 0x02,
    } ++ fragment ++ [_]u8{ 0x00, 0x00 };

    const push_promise = try PushPromise.init(&frame);
    try std.testing.expectEqual(@as(u31, 1), push_promise.streamId());
    try std.testing.expectEqual(@as(u31, 2), push_promise.promisedStreamId());
    try std.testing.expect(!push_promise.isEndHeaders());
    try std.testing.expect(!push_promise.isPadded());
    try std.testing.expectEqualSlices(u8, &.{}, push_promise.headerBlockFragment());

    const padded_push_promise = try PushPromise.init(&padded_frame);
    try std.testing.expectEqual(@as(u31, 1), padded_push_promise.streamId());
    try std.testing.expectEqual(@as(u31, 2), padded_push_promise.promisedStreamId());
    try std.testing.expect(padded_push_promise.isEndHeaders());
    try std.testing.expect(padded_push_promise.isPadded());
    try std.testing.expectEqualSlices(
        u8,
        &fragment,
        padded_push_promise.headerBlockFragment(),
    );
}

test "push_promise frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x02, 0x00,
    };
    const short_payload = [_]u8{
        0x00, 0x00, 0x03,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x02,
    };
    const short_padded_payload = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x08, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x02,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x04,
        0x01, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x02,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x02,
    };
    const zero_promised_stream = [_]u8{
        0x00, 0x00, 0x04,
        0x05, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x80, 0x00, 0x00,
        0x00,
    };
    const excessive_padding = [_]u8{
        0x00, 0x00, 0x06,
        0x05, 0x08, 0x00,
        0x00, 0x00, 0x01,
        0x02, 0x00, 0x00,
        0x00, 0x02, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, PushPromise.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, PushPromise.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, PushPromise.init(&extra_payload));
    try std.testing.expectError(error.FrameSizeError, PushPromise.init(&short_payload));
    try std.testing.expectError(error.FrameSizeError, PushPromise.init(&short_padded_payload));
    try std.testing.expectError(error.ProtocolError, PushPromise.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, PushPromise.init(&zero_stream));
    try std.testing.expectError(error.ProtocolError, PushPromise.init(&zero_promised_stream));
    try std.testing.expectError(error.ProtocolError, PushPromise.init(&excessive_padding));
}

test "priority exposes dependency and weight" {
    const frame = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x03,
        0x00, 0x00, 0x00,
        0x01, 0x00,
    };
    const exclusive_frame = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0xff, 0xff,
        0xff, 0xff, 0xff,
        0x80, 0x00, 0x00,
        0x00, 0xff,
    };

    const priority = try Priority.init(&frame);
    try std.testing.expectEqual(@as(u31, 3), priority.streamId());
    try std.testing.expect(!priority.isExclusive());
    try std.testing.expectEqual(@as(u31, 1), priority.streamDependency());
    try std.testing.expectEqual(@as(u16, 1), priority.weight());

    const exclusive_priority = try Priority.init(&exclusive_frame);
    try std.testing.expectEqual(@as(u31, 0x7fff_ffff), exclusive_priority.streamId());
    try std.testing.expect(exclusive_priority.isExclusive());
    try std.testing.expectEqual(@as(u31, 0), exclusive_priority.streamDependency());
    try std.testing.expectEqual(@as(u16, 256), exclusive_priority.weight());
}

test "priority frame validation works" {
    const too_short = [_]u8{0} ** (FRAME_LEN - 1);
    const missing_payload = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x01,
    };
    const extra_payload = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
    };
    const wrong_payload_length = [_]u8{
        0x00, 0x00, 0x04,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00,
    };
    const wrong_type = [_]u8{
        0x00, 0x00, 0x05,
        0x03, 0x00, 0x00,
        0x00, 0x00, 0x01,
        0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    const zero_stream = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x00, 0x00, 0x00,
        0x01, 0x00,
    };
    const self_dependency = [_]u8{
        0x00, 0x00, 0x05,
        0x02, 0x00, 0x00,
        0x00, 0x00, 0x03,
        0x80, 0x00, 0x00,
        0x03, 0x00,
    };

    try std.testing.expectError(error.InvalidFrameLength, Priority.init(&too_short));
    try std.testing.expectError(error.InvalidFrameLength, Priority.init(&missing_payload));
    try std.testing.expectError(error.InvalidFrameLength, Priority.init(&extra_payload));
    try std.testing.expectError(error.FrameSizeError, Priority.init(&wrong_payload_length));
    try std.testing.expectError(error.ProtocolError, Priority.init(&wrong_type));
    try std.testing.expectError(error.ProtocolError, Priority.init(&zero_stream));
    try std.testing.expectError(error.ProtocolError, Priority.init(&self_dependency));
}
