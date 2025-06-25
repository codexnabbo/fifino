const std = @import("std");

pub const Logger = struct {
    allocator: std.mem.Allocator,
    filename: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, filename: []const u8) Self {
        return Self{
            .allocator = allocator,
            .filename = filename,
        };
    }

    pub fn log(self: *Self, message: []const u8) !void {
        const file = std.fs.cwd().openFile(self.filename, .{
            .mode = .write_only,
        }) catch |err| switch (err) {
            error.FileNotFound => {
                const new_file = try std.fs.cwd().createFile(self.filename, .{});
                defer new_file.close();
                try new_file.writeAll(message);
                try new_file.writeAll("\n");
                return;
            },
            else => return err,
        };

        defer file.close();

        try file.seekFromEnd(0);

        try file.writeAll(message);
        try file.writeAll("\n");
    }

    pub fn logf(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.log(message);
    }

    pub fn logWithTimestamp(self: *Self, message: []const u8) !void {
        const timestamp = std.time.timestamp();
        const log_message = try std.fmt.allocPrint(self.allocator, "[{d}] {s}", .{ timestamp, message });
        defer self.allocator.free(log_message);
        try self.log(log_message);
    }

    pub fn logWithTimestampf(self: *Self, comptime fmt: []const u8, args: anytype) !void {
        const message = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(message);
        try self.logWithTimestamp(message);
    }

    pub fn logSeparator(self: *Self) !void {
        try self.log("----------------------------------------");
    }

    pub fn logSection(self: *Self, section_name: []const u8) !void {
        try self.logSeparator();
        try self.logf("=== {s} ===", .{section_name});
        try self.logSeparator();
    }

    pub fn logClearFile(self: *Self) !void {
        try std.fs.cwd().deleteFile(self.filename);
    }
};

test "Logger initialization" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const logger = Logger.init(allocator, "test.log");

    try std.testing.expectEqualStrings("test.log", logger.filename);
    try std.testing.expect(logger.allocator.ptr == allocator.ptr);
}

test "Logger create a file and write a message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var logger = Logger.init(allocator, "test.log");

    try logger.log("First Log");
}
