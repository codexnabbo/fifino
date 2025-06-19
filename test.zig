const std = @import("std");
const Allocator = std.mem.Allocator;

const ABuf = struct {
    b: ?[]u8,
    len: usize,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .b = null,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn append(self: *Self, s: []const u8) !void {
        const new_len = self.len + s.len;
        
        if (self.b) |buffer| {
            // Realloc del buffer esistente
            if (self.allocator.realloc(buffer, new_len)) |new_buffer| {
                @memcpy(new_buffer[self.len..new_len], s);
                self.b = new_buffer;
                self.len = new_len;
            } else |_| {
                // Realloc fallita, proviamo ad allocare nuovo buffer
                const new_buffer = self.allocator.alloc(u8, new_len) catch return;
                @memcpy(new_buffer[0..self.len], buffer);
                @memcpy(new_buffer[self.len..new_len], s);
                self.allocator.free(buffer);
                self.b = new_buffer;
                self.len = new_len;
            }
        } else {
            // Prima allocazione
            const new_buffer = self.allocator.alloc(u8, s.len) catch return;
            @memcpy(new_buffer, s);
            self.b = new_buffer;
            self.len = s.len;
        }
    }

    pub fn free(self: *Self) void {
        if (self.b) |buffer| {
            self.allocator.free(buffer);
            self.b = null;
            self.len = 0;
        }
    }

    pub fn toString(self: Self) []const u8 {
        return if (self.b) |buffer| buffer[0..self.len] else "";
    }
};

// Esempio di utilizzo:
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var ab = ABuf.init(allocator);
    defer ab.free();

    try ab.append("Hello, ");
    try ab.append("World!");
    
    std.debug.print("Buffer: {s}\n", .{ab.toString()});
}


