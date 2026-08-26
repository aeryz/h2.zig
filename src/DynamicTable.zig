const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

const HeaderField = types.HeaderField;
const HeaderFieldView = types.HeaderFieldView;

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

pub fn push(self: *DynamicTable, header_view: HeaderFieldView) !void {
    const name = try header_view.name.getOwned(self.allocator);
    errdefer self.allocator.free(name);

    const value = try header_view.value.getOwned(self.allocator);
    errdefer self.allocator.free(value);

    const header: HeaderField = .{
        .name = name,
        .value = value,
    };

    const header_len = header.len();
    if (self.current_len + header_len > self.capacity) {
        var current_len = self.current_len;
        const desired_len = self.capacity - header_len;
        while (current_len > desired_len) {
            const pop_item = self.list.popBack().?;
            current_len -= pop_item.len();
        }
        self.current_len = current_len;
    }
    self.current_len += header.len();

    try self.list.pushFront(self.allocator, header);
}

pub fn get(_: *DynamicTable, _: usize) ?*HeaderField {
    return null;
}

pub fn set_max_capacity(_: *DynamicTable, _: usize) void {}

pub fn deinit(self: *DynamicTable) void {
    self.list.deinit(self.allocator);
}

const testing = std.testing;
const expectEqual = testing.expectEqual;
