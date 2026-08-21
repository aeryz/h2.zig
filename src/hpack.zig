const std = @import("std");
const Allocator = std.mem.Allocator;

const DEFAULT_MAX_LEN: usize = 4096;

const HeaderField = struct {
    name: []const u8,
    value: []const u8,

    pub fn len(self: *const HeaderField) usize {
        return self.name.len + self.value.len + 32;
    }
};

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

// TODO: still not sure if we could manage to
const DynamicTableList = std.Deque(HeaderField);

const DynamicTable = struct {
    list: DynamicTableList,
    current_len: usize,
    max_len: usize = DEFAULT_MAX_LEN,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !DynamicTable {
        return .{ .list = try DynamicTableList.initCapacity(allocator, DEFAULT_MAX_LEN / 32), .current_len = 0, .allocator = allocator };
    }

    pub fn push(self: *DynamicTable, item: HeaderField) !void {
        const item_len = item.len();
        if (self.current_len + item_len > self.max_len) {
            var current_len = self.current_len;
            const desired_len = self.max_len - item_len;
            while (current_len > desired_len) {
                const pop_item = self.list.popBack().?;
                current_len -= pop_item.len();
            }
            self.current_len = current_len;
        }
        self.current_len += item.len();
        try self.list.pushFront(self.allocator, item);
    }

    pub fn deinit(self: *DynamicTable) void {
        self.list.deinit(self.allocator);
    }
};

pub const HPack = struct {
    dynamic_table: DynamicTable,
    allocator: Allocator,

    fn init(allocator: Allocator) !HPack {
        return .{
            .list = DynamicTableList.initCapacity(allocator, DEFAULT_MAX_LEN / @sizeOf(HeaderField)),
            .current_len = 0,
        };
    }
};

fn decode_integer_value(comptime N: usize, buffer: []const u8) ?usize {
    comptime {
        if (N > 7) {
            @compileError("N must be < 8");
        }
    }

    if (buffer.len == 0) {
        return null;
    }

    const mask = (@as(usize, 1) << N) - 1;
    var val = mask & @as(usize, buffer[0]);
    if (val != mask) {
        return val;
    }

    var shift: usize = 0;

    for (buffer[1..]) |byte| {
        const chunk = @as(usize, byte & 0b0111_1111);

        val += chunk << @intCast(shift);

        if (byte & 0b1000_0000 == 0) {
            return val;
        }

        shift += 7;

        if (shift >= @bitSizeOf(usize)) {
            return null;
        }
    }

    return null;
}

test "dynamic table inserts from front" {
    const allocator = std.testing.allocator;
    var table = try DynamicTable.init(allocator);
    defer table.deinit();

    const first_string = "helloworld";
    const second_string = "worldhello";

    try table.push(.{
        .name = first_string,
        .value = first_string,
    });

    try std.testing.expectEqual(first_string, table.list.at(0).name);

    try table.push(.{
        .name = second_string,
        .value = second_string,
    });

    try std.testing.expectEqual(4 * 10 + 32 * 2, table.current_len);
    try std.testing.expectEqual(second_string, table.list.at(0).name);
    try std.testing.expectEqual(first_string, table.list.at(1).name);
}

test "dynamic table evicts from the back" {
    const allocator = std.testing.allocator;
    var table = try DynamicTable.init(allocator);
    defer table.deinit();

    const first_string: [950]u8 = @splat('a');
    const second_string: [950]u8 = @splat('b');
    const third_string: [950]u8 = @splat('c');

    try table.push(.{
        .name = &first_string,
        .value = &first_string,
    });

    try table.push(.{
        .name = &second_string,
        .value = &second_string,
    });

    try table.push(.{
        .name = &third_string,
        .value = &third_string,
    });

    // len is 2 because the first string is evicted
    try std.testing.expectEqual(2, table.list.len);
    try std.testing.expectEqual(&third_string, table.list.at(0).name);
    try std.testing.expectEqual(&second_string, table.list.at(1).name);
}

test "decode integer value - 1337" {
    const encoded = [_]u8{
        0b0001_1111,
        0b1001_1010,
        0b0000_1010,
    };

    try std.testing.expectEqual(
        @as(?usize, 1337),
        decode_integer_value(5, &encoded),
    );
}
