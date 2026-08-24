pub const Cow = union(enum) {
    borrowed: []const u8,
    owned: []const u8,
};

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,

    pub fn len(self: *const HeaderField) usize {
        return self.name.len + self.value.len + 32;
    }
};

pub const HeaderFieldReprType = union(u8) {
    indexed,
    literal_with_indexing,
    literal_without_indexing,
    literal_never_indexed,
};

pub const HeaderFieldView = struct {
    type: HeaderFieldReprType,
    name: Cow,
    value: Cow,
};

pub const HeaderFieldRepr = union(enum) {
    string: []const u8,
    int: usize,
};
