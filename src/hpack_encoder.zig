const std = @import("std");

const hpack_decoder = @import("hpack_decoder.zig");

const Allocator = std.mem.Allocator;

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
