// Single Buffer update for writes
const ABuf = struct {
    b: []u8,
    len: usize,
    allocator: Allocator,

    pub fn init(alloc: Allocator) ABuf {
        return .{
            .b = &[_]u8{},
            .len = 0,
            .allocator = alloc,
        };
    }

    pub fn abAppend(self: *ABuf, s: []const u8) !void {
        const new_len = self.len + s.len;
        self.b = try self.allocator.realloc(self.b, new_len);
        @memcpy(self.b[self.len..new_len], s);
        self.len = new_len;
    }

    pub fn abFree(self: *ABuf) void {
        self.allocator.free(self.b);
        self.* = ABuf.init(self.allocator);
    }
};
