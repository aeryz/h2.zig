const std = @import("std");

const hpack_decoder = @import("hpack_decoder.zig");

const Allocator = std.mem.Allocator;

const STATIC_TABLE = [_]HeaderField{};

const Decoder = struct {
    max_table_size: usize,

    pub fn init(max_table_size: usize) Decoder {
        return .{
            .max_table_size = max_table_size,
        };
    }
};

pub const HPack = struct {
    dynamic_table: hpack_decoder.DynamicTable,
    allocator: Allocator,

    fn init(allocator: Allocator) !HPack {
        return .{
            .list = DynamicTableList.initCapacity(allocator, DEFAULT_MAX_LEN / @sizeOf(HeaderField)),
            .current_len = 0,
        };
    }
};

fn encode_integer_value(
    comptime N: usize,
    value: usize,
    prefix: u8,
    buffer: []u8,
) ?usize {
    comptime {
        if (N == 0 or N > 7) {
            @compileError("N must be in 1..7");
        }
    }

    if (buffer.len == 0) {
        return null;
    }

    const mask: usize = (@as(usize, 1) << N) - 1;

    if (value < mask) {
        buffer[0] = prefix | @as(u8, @intCast(value));
        return 1;
    }

    buffer[0] = prefix | @as(u8, @intCast(mask));

    var remaining = value - mask;
    var i: usize = 1;

    while (remaining >= 128) {
        if (i >= buffer.len) {
            return null;
        }

        buffer[i] =
            @as(u8, @intCast(remaining & 0b0111_1111)) |
            0b1000_0000;

        remaining >>= 7;
        i += 1;
    }

    if (i >= buffer.len) {
        return null;
    }

    buffer[i] = @intCast(remaining);
    return i + 1;
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "encode integer value - 1337" {
    var buffer: [16]u8 = undefined;

    const len = encode_integer_value(
        5,
        1337,
        0,
        &buffer,
    ).?;

    try expectEqual(@as(usize, 3), len);

    try testing.expectEqualSlices(
        u8,
        &[_]u8{
            0b0001_1111,
            0b1001_1010,
            0b0000_1010,
        },
        buffer[0..len],
    );
}

test "integer encode/decode round trip" {
    var buffer: [16]u8 = undefined;

    const len = encode_integer_value(5, 1337, 0, &buffer).?;

    var int: usize = undefined;
    _ = decode_integer_value(5, buffer[0..len], &int);
    try expectEqual(@as(?usize, 1337), int);
}

test "string literal no-huffman decoding works" {
    // "hello"
    const hello = [_]u8{
        0b0000_0101,
        'h',
        'e',
        'l',
        'l',
        'o',
    };
    try testing.expectEqualSlices(u8, "hello", decode_string_value(&hello).?);

    // "content-type"
    const content_type = [_]u8{
        0b0000_1100, // 12 bytes
        'c',
        'o',
        'n',
        't',
        'e',
        'n',
        't',
        '-',
        't',
        'y',
        'p',
        'e',
    };
    try testing.expectEqualSlices(u8, "content-type", decode_string_value(&content_type).?);

    // "application/json"
    const application_json = [_]u8{
        0b0001_0000, // 16 bytes
        'a',
        'p',
        'p',
        'l',
        'i',
        'c',
        'a',
        't',
        'i',
        'o',
        'n',
        '/',
        'j',
        's',
        'o',
        'n',
    };

    try testing.expectEqualSlices(u8, "application/json", decode_string_value(&application_json).?);
}
