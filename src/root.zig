pub const frame = @import("frame.zig");
pub const types = @import("types.zig");
pub const hpack_encoder = @import("hpack_encoder.zig");
pub const hpack_decoder = @import("hpack_decoder.zig");
pub const DynamicTable = @import("dynamic_table.zig");

const ErrorCode = enum {
    NoError,
    ProtocolError,
    InternalError,
    FlowControlError,
    SettingsTimeout,
    StreamClosed,
    FrameSizeError,
    RefusedStream,
    Cancel,
    CompressionError,
    ConnectError,
    EnhanceYourCalm,
    InadequateSecurity,
    Http11Required,
};
