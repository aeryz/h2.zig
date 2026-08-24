const std = @import("std");

const types = @import("types.zig");
const DynamicTable = @import("DynamicTable.zig");

const HeaderField = types.HeaderField;
const Cow = types.Cow;
const HeaderFieldView = types.HeaderFieldView;

const STATIC_TABLE = [_]HeaderField{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

// encoding:
// - header_field -> union(liteal | ref to the table)
// - [header_field] -> "literal", ref, ref, "literal"...
//
// !encoder is responsible for deciding which header fields to insert
// as new entries in the header field tables
//
// decoder executes the
// modifications to the header field tables prescribed by the encoder,
//
// Meaning:
// encoder -> insert this boss -> decoder -> ok boss

const Decoder = struct {
    dynamic_table: DynamicTable,

    pub fn start_decoding() DecoderIterator {}

    fn decode_string_value(buffer: []const u8) ?Cow {
        if (buffer.len == 0) {
            return null;
        }

        var str_len: usize = undefined;
        const n_bytes = decode_integer_value(7, buffer, &str_len);
        if (n_bytes == 0) {
            return null;
        }

        return .{ .borrowed = buffer[n_bytes..(n_bytes + str_len)] };
    }

    fn decode_integer_value(comptime N: usize, buffer: []const u8, out_val: *usize) usize {
        comptime {
            if (N > 7) {
                @compileError("N must be < 8");
            }
        }

        if (buffer.len == 0) {
            return 0;
        }

        const mask = (@as(usize, 1) << N) - 1;
        var val = mask & @as(usize, buffer[0]);
        if (val != mask) {
            out_val.* = val;
            return 1;
        }

        var shift: usize = 0;

        // TODO: this should be simd-able but I don't know simd
        for (buffer[1..]) |byte| {
            const chunk = @as(usize, byte & 0b0111_1111);

            val += chunk << @intCast(shift);

            if (byte & 0b1000_0000 == 0) {
                out_val.* = val;
                return shift / 7 + 2;
            }

            shift += 7;

            if (shift >= @bitSizeOf(usize)) {
                return 0;
            }
        }

        return 0;
    }
};

const DecoderIterator = struct {
    remaining: []const u8,
    dynamic_table: *DynamicTable,

    pub fn next(self: *DecoderIterator) ?HeaderFieldView {
        if (self.remaining.len == 0) {
            return null;
        }

        var used = 0;

        if (self.remaining[0] & 0b1 == 0b1) {
            var index: usize = undefined;
            used = Decoder.decode_integer_value(7, self.remaining, &index);
            if (index == 0) {
                // decode error
                return null;
            }

            const item = if (index > STATIC_TABLE.len) self.dynamic_table.get(index).? else &STATIC_TABLE[index];

            return .{
                .type = .indexed,
                .name = .{ .borrowed = item.name },
                .value = .{ .borrowed = item.value },
            };
        } else if (self.remaining[0] & 0b11 == 0b01) {
            // Literal Header Field with Incremental Indexing

            var header_view: HeaderFieldView = .{ .type = .literal_with_indexing };
            used = self.decode_header_field_repr(6, self.remaining, &header_view);

            // TODO: lifetime issue, need to alloc. but we can't simply
            // alloc here (maybe?) because there's also huffman
            self.dynamic_table.add(header_view);

            self.remaining = self.remaining[used..];

            return header_view;
        } else if (self.remaining[0] & 0b1111 == 0b0000) {
            var header_view: HeaderFieldView = .{ .type = .literal_without_indexing };
            used = self.decode_header_field_repr(4, self.remaining, &header_view);

            self.remaining = self.remaining[used..];

            return header_view;
        } else if (self.remaining[0] & 0b1111 == 0b0001) {
            var header_view: HeaderFieldView = .{ .type = .literal_never_indexed };
            used = self.decode_header_field_repr(4, self.remaining, &header_view);

            self.remaining = self.remaining[used..];

            return header_view;
        } else if (self.remaining[0] & 0b111 == 0b001) {
            var max_cap: usize = undefined;
            used = Decoder.decode_integer_value(5, self.remaining, &max_cap) - 1;
            self.dynamic_table.set_max_capacity(max_cap);

            return self.next();
        }

        // decode error
        return null;
    }

    fn decode_header_field_repr(
        self: *DecoderIterator,
        comptime N: usize,
        buffer: []const u8,
        header_field: *HeaderFieldView,
    ) usize {
        var used = 0;

        var idx: usize = undefined;
        used += Decoder.decode_integer_value(N, buffer[0], &idx) - 1;
        const name: Cow = if (idx == 0)
            Decoder.decode_string_value(buffer[used + 1 ..]).?
        else if (idx > STATIC_TABLE.len)
            .{ .borrowed = self.dynamic_table.get(idx).?.name }
        else
            .{ .borrowed = STATIC_TABLE[idx - 1].name };

        used += name.len;

        const value = Decoder.decode_string_value(buffer[used..]).?;
        used += value.len;

        self.remaining = self.remaining[used..];

        header_field.name = name;
        header_field.value = value;

        return used;
    }
};

test "decoder decodes" {
    _ = [_]u8{
        0x82, // :method: GET        (static table index 2)
        0x87, // :scheme: https      (static table index 7)
        0x84, // :path: /            (static table index 4)

        // Literal Header Field with Incremental Indexing
        // indexed name: :authority (static table index 1)
        0x41,

        // value length = 15, Huffman bit = 0
        0x0f,

        // "www.example.com"
        'w',
        'w',
        'w',
        '.',
        'e',
        'x',
        'a',
        'm',
        'p',
        'l',
        'e',
        '.',
        'c',
        'o',
        'm',
    };
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

test "decode integer value - 1337" {
    const encoded = [_]u8{
        0b0001_1111,
        0b1001_1010,
        0b0000_1010,
    };

    var val: usize = undefined;
    _ = Decoder.decode_integer_value(5, &encoded, &val);
    try expectEqual(@as(?usize, 1337), val);
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
    try testing.expectEqualSlices(
        u8,
        "hello",
        Decoder.decode_string_value(&hello).?.borrowed,
    );

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
    try testing.expectEqualSlices(
        u8,
        "content-type",
        Decoder.decode_string_value(&content_type).?.borrowed,
    );

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

    try testing.expectEqualSlices(
        u8,
        "application/json",
        Decoder.decode_string_value(&application_json).?.borrowed,
    );
}
