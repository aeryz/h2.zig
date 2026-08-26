const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Cow = union(enum) {
    borrowed: []const u8,
    owned: []const u8,

    pub fn getOwned(self: *const Cow, allocator: Allocator) ![]const u8 {
        const ret = switch (self.*) {
            .borrowed => |value| try allocator.dupe(u8, value),
            .owned => |value| value,
        };

        return ret;
    }

    pub fn len(self: *const Cow) usize {
        const ret = switch (self.*) {
            .borrowed => |value| value.len,
            .owned => |value| value.len,
        };

        return ret;
    }
};

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,

    pub fn len(self: *const HeaderField) usize {
        return self.name.len + self.value.len + 32;
    }
};

pub const HeaderFieldReprType = enum {
    indexed,
    literal_with_indexing,
    literal_without_indexing,
    literal_never_indexed,
};

pub const HeaderFieldView = struct {
    type: HeaderFieldReprType,
    name: Cow,
    value: Cow,

    pub fn len(self: *const HeaderFieldView) usize {
        return self.name.len() + self.value.len() + 32;
    }
};

pub const HeaderFieldRepr = union(enum) {
    string: []const u8,
    int: usize,
};
