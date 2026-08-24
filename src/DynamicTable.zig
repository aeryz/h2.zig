const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const HeaderField = types.HeaderField;

const DynamicTableList = std.Deque(HeaderField);

const DynamicTable = @This();

const DEFAULT_CAPACITY: usize = 4096;

list: DynamicTableList,
current_len: usize,
capacity: usize = DEFAULT_CAPACITY,
allocator: Allocator,

pub fn init(allocator: Allocator) !DynamicTable {
    return .{
        .list = try DynamicTableList.initCapacity(allocator, DEFAULT_CAPACITY / 32),
        .current_len = 0,
        .allocator = allocator,
    };
}

pub fn push(self: *DynamicTable, item: HeaderField) !void {
    const item_len = item.len();
    if (self.current_len + item_len > self.capacity) {
        var current_len = self.current_len;
        const desired_len = self.capacity - item_len;
        while (current_len > desired_len) {
            const pop_item = self.list.popBack().?;
            current_len -= pop_item.len();
        }
        self.current_len = current_len;
    }
    self.current_len += item.len();
    try self.list.pushFront(self.allocator, item);
}

pub fn get(_: *DynamicTable, _: usize) ?*HeaderField {
    return null;
}

pub fn set_max_cap(_: *DynamicTable, _: usize) void {}

pub fn deinit(self: *DynamicTable) void {
    self.list.deinit(self.allocator);
}

const testing = std.testing;
const expectEqual = testing.expectEqual;

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

    try expectEqual(first_string, table.list.at(0).name);

    try table.push(.{
        .name = second_string,
        .value = second_string,
    });

    try expectEqual(4 * 10 + 32 * 2, table.current_len);
    try expectEqual(second_string, table.list.at(0).name);
    try expectEqual(first_string, table.list.at(1).name);
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
    try expectEqual(2, table.list.len);
    try expectEqual(&third_string, table.list.at(0).name);
    try expectEqual(&second_string, table.list.at(1).name);
}
