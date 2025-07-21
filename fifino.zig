const std = @import("std");
const Allocator = std.mem.Allocator;

const Config = @import("constant.zig");
const Logger = @import("logger.zig").Logger;


var log: Logger = undefined;
const editorConfig = struct {
    cursorX: u16,
    cursorY: u16,
    renderX: u16,
    rowoff: u16,
    coloff: u16,
    screenrows: u16,
    screencols: u16,
    numrows: u16,
    row: []EditorRow,
    dirty: u16,
    filename: ?[]u8,
    statusmsg: [80]u8,
    statusmsg_time: i64,
    orig_termios: std.c.termios = undefined,
};

const editorKey = enum(u16) {
    BACKSPACE = 127,
    ARROW_LEFT = 1000,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    PAGE_UP,
    PAGE_DOWN,
    HOME_KEY,
    END_KEY,
    DEL_KEY,
};

const EditorRow = struct {
    chars: []u8,
    rsize: u16,
    render: []u8,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, content: []const u8) !Self {
        const chars = try allocator.dupe(u8, content);
        return Self{
            .chars = chars,
            .rsize = 0,
            .render = undefined,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.chars);
    }

    pub fn append(self: *Self, s: []const u8) !void {
        const new_size = self.chars.len + s.len;

        self.chars = try self.allocator.realloc(self.chars, new_size);
        @memcpy(self.chars[self.chars.len - s.len ..], s);
    }

    pub fn appendAt(self: *Self, c: u8, at: usize) !void {
        const insert_pos = if (at > self.chars.len) self.chars.len else at;
        const old_len = self.chars.len;
        self.chars = try self.allocator.realloc(self.chars, self.chars.len + 1);

        if (insert_pos < old_len) {
            std.mem.copyBackwards(u8, self.chars[insert_pos + 1 ..], self.chars[insert_pos .. old_len - 1]);
        }
        self.chars[insert_pos] = c;
    }
};

const abuf = struct {
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
            // We try to realloc the existent buffer
            if (self.allocator.realloc(buffer, new_len)) |new_buffer| {
                @memcpy(new_buffer[self.len..new_len], s);
                self.b = new_buffer;
                self.len = new_len;
            } else |_| {

                // Realloc failed, manual reallocation of the new buffer
                const new_buffer = self.allocator.alloc(u8, new_len) catch return;
                @memcpy(new_buffer[0..self.len], buffer);
                @memcpy(new_buffer[self.len..new_len], s);
                self.allocator.free(buffer);
                self.b = new_buffer;
                self.len = new_len;
            }
        } else {
            // self.b is not allocated so we need to do the first allocation
            const new_buffer = self.allocator.alloc(u8, new_len) catch return;
            @memcpy(new_buffer, s);
            self.b = new_buffer;
            self.len = new_len;
        }
    }

    pub fn free(self: *Self) void {
        if (self.b) |buffer| {
            self.allocator.free(buffer);
            self.b = null;
            self.len = 0;
        }
    }

    pub fn toString(self: *Self) []const u8 {
        return if (self.b) |buffer| buffer[0..self.len] else "";
    }
};

var E: editorConfig = undefined;

// ------- Data -------- //

fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

fn sscan(c: []u8) !void {
    var token = std.mem.splitScalar(u8, c, ';');
    E.screenrows = try std.fmt.parseInt(u16, token.next().?, 10);
    E.screencols = try std.fmt.parseInt(u16, sliceUntilEnd(token.next().?), 10);
}

// ------- terminal ---------//

fn die(s: []const u8) !void {
    _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[2J", 4);
    _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[H", 3);
    try log.logWithTimestampf("Error trying  to compute: {s}", .{s});
    try exit(1);
}

fn sliceUntilEnd(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0x00) : (i += 1) {}
    return buf[0..i];
}

fn disableRawMode() callconv(.c) void {
    if (std.c.tcsetattr(std.c.STDIN_FILENO, .FLUSH, &E.orig_termios) == -1)
        die("tcsetattr") catch {};

    std.debug.print("Restore terminal settings\n", .{});
}

fn exit(i: c_int) !void {
    disableRawMode();
    std.c.exit(i);
}

fn getCursorPosition() !i8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;

    if (std.c.write(std.c.STDOUT_FILENO, "\x1b[6n", 4) != 4) return -1;

    while (i < std.zig.c_translation.sizeof(buf) - 1) : (i += 1) {
        if (std.c.read(std.c.STDIN_FILENO, buf[i..][0..1].ptr, 1) != 1) break;
        if (buf[i] == 'R') break;
    }

    buf[i] = '\x00';
    if (buf[0] != '\x1b' or buf[1] != '[') return -1;
    try sscan(buf[2..8]);
    return 0;
}

fn getWindowSize(rows: *u16, cols: *u16) !i8 {
    var ws: std.c.winsize = undefined;

    if (std.c.ioctl(std.c.STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) == -1 or ws.col == 0) {
        if (std.c.write(std.c.STDOUT_FILENO, "\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition();
    } else {
        rows.* = ws.row;
        cols.* = ws.col;
    }
    return 0;
}

fn editorRowCxToRx(row: *EditorRow, cx: u16) u16 {
    var rx: u16 = 0;
    for (0..cx) |i| {
        if (row.chars[i] == '\t')
            rx += (Config.TAB_STOP - 1) - (rx % Config.TAB_STOP);

        rx += 1;
    }

    return rx;
}

fn editorUpdateRow(row: *EditorRow) !void {
    var tabs: u16 = 0;

    for (0..row.chars.len) |i| {
        if (row.chars[i] == '\t') tabs += 1;
    }

    row.render = try row.allocator.alloc(u8, row.chars.len + tabs * (Config.TAB_STOP - 1) + 1);

    var idx: u16 = 0;
    for (0..row.chars.len) |i| {
        if (row.chars[i] == '\t') {
            row.render[idx] = ' ';
            idx += 1;
            while (idx % Config.TAB_STOP != 0) : (idx += 1) {
                row.render[idx] = ' ';
            }
        } else {
            row.render[idx] = row.chars[i];
            idx += 1;
        }
    }
    row.render[idx] = 0;
    row.rsize = idx;
}

fn editorInsertRow(allocator: Allocator, at: usize, line: []const u8, len: usize) !void {
    if (at > E.numrows) return;

    const new_size = std.math.mul(usize, E.numrows + 1, @sizeOf(EditorRow)) catch {
        return error.CalculationOverflow;
    };
    E.row = try allocator.realloc(E.row, new_size);

    if (at < E.numrows) {
        std.mem.copyBackwards(EditorRow, E.row[at + 1 .. E.numrows + 1], E.row[at..E.numrows]);
    }

    E.row = try allocator.realloc(E.row, new_size);

    E.row[at] = try EditorRow.init(allocator, line[0..len]);
    E.row[at].rsize = 0;
    E.row[at].render = undefined;
    try editorUpdateRow(&E.row[at]);
    E.numrows += 1;
    E.dirty += 1;
}

fn editorDelRow(allocator: Allocator, at: usize) !void {
    if (at >= E.numrows) return;
    E.row[at].deinit();
    if (at < E.numrows - 1) {
        std.mem.copyForwards(EditorRow, E.row[at..], E.row[at + 1 ..]);
    }
    E.numrows -= 1;
    if (E.numrows > 0) {
        const new_size = E.numrows * @sizeOf(EditorRow);
        E.row = try allocator.realloc(E.row, new_size);
    } else {
        allocator.free(E.row);
        E.row = &[_]EditorRow{};
    }

    E.dirty += 1;
}

fn editorRowInsertChar(row: *EditorRow, at: usize, c: u8) !void {
    const new_at = if (at < 0 or at > row.chars.len) row.chars.len else at;
    try row.appendAt(c, new_at);

    try editorUpdateRow(row);
    E.dirty += 1;
}

fn editorRowAppendString(row: *EditorRow, chars: []u8) !void {
    try row.append(chars);
    try row.appendAt(0, row.chars.len);
    try editorUpdateRow(row);

    E.dirty += 1;
}

fn editorRowDelChar(row: *EditorRow, at: usize) !void {
    if (at > row.chars.len) return;
    try log.logWithTimestampf("Before delete: pos={d}, len={d}, content='{s}'", .{ at, row.chars.len, row.chars });
    std.mem.copyForwards(u8, row.chars[at..], row.chars[at + 1 ..]);
    row.chars = try row.allocator.realloc(row.chars, row.chars.len - 1);
    try log.logWithTimestampf("After delete: len={d}, content='{s}'", .{ row.chars.len, row.chars });
    try editorUpdateRow(row);
    E.dirty += 1;
}
// ------- editor operations ------ //

fn editorInsertChar(allocator: Allocator, c: u16) !void {
    if (E.cursorY == E.numrows) {
        try editorInsertRow(allocator, E.numrows, "", 0);
    }
    try editorRowInsertChar(&E.row[E.cursorY], E.cursorX, @intCast(c));
    E.cursorX += 1;
}

fn editorInsertNewLine(allocator: Allocator) !void {
    if (E.cursorX == 0) {
        try editorInsertRow(allocator, E.cursorY, "", 0);
    } else {
        var row: *EditorRow = &E.row[E.cursorY];
        try editorInsertRow(allocator, E.cursorY + 1, row.chars[E.cursorX..], row.chars.len - E.cursorX);
        row = &E.row[E.cursorY];
        row.chars = try row.allocator.realloc(row.chars, E.cursorX);
        try editorUpdateRow(row);
    }
    E.cursorY += 1;
    E.cursorX = 0;
}

fn editorDelChar(allocator: Allocator) !void {
    if (E.cursorY == E.numrows) return;
    if (E.cursorX == 0 and E.cursorY == 0) return;
    try log.logWithTimestampf("editorDelChar: cursorY={d}, cursorX={d}, numrows={d}", .{ E.cursorY, E.cursorX, E.numrows });
    const row: *EditorRow = &E.row[E.cursorY];
    if (E.cursorX > 0) {
        try log.logWithTimestamp("Deleting character in current row");
        try editorRowDelChar(row, E.cursorX - 1);
        E.cursorX -= 1;
    } else {
        try log.logWithTimestamp("Moving to previous row and appending");
        E.cursorX = @intCast(E.row[E.cursorY - 1].chars.len);
        try editorRowAppendString(&E.row[E.cursorY - 1], row.chars);
        try editorDelRow(allocator, E.cursorY);
        E.cursorY -= 1;
    }
}
// ------- file i/o ----- //

fn editorRowsToString(allocator: Allocator) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    try log.logWithTimestampf("Saving {d} rows to file", .{E.numrows});
    for (E.row[0..E.numrows], 0..) |row, i| {
        try log.logWithTimestampf("Row {d}: len={d}, content='{s}'", .{ i, row.chars.len, row.chars });

        try result.appendSlice(row.chars[0..row.chars.len]);
        try result.append('\n');
    }
    const final_content = try result.toOwnedSlice();

    try log.logWithTimestampf("Final content length: {d}", .{final_content.len});
    return final_content;
}

fn editorOpen(allocator: Allocator, file_path: []const u8) !void {
    E.filename = try allocator.dupe(u8, file_path);
    const fp = std.fs.cwd().openFile(file_path, .{ .mode = std.fs.File.OpenMode.read_only }) catch |err| {
        switch (err) {
            error.FileNotFound => try die("OpenFile: File not Found"),
            error.AccessDenied => try die("OpenFIle: Access denied"),
            else => try die("OpenFile: Unknow Error"),
        }
        return err;
    };
    defer fp.close();

    var buf_reader = std.io.bufferedReader(fp.reader());
    var in_stream = buf_reader.reader();

    var line_buffer: [4096]u8 = undefined;

    while (true) {
        if (in_stream.readUntilDelimiterOrEof(line_buffer[0..], '\n')) |maybe_line| {
            if (maybe_line) |line| {
                var linelen = line.len;

                while (linelen > 0 and (line[linelen - 1] == '\n' or line[linelen - 1] == '\r')) {
                    linelen -= 1;
                }
                try editorInsertRow(allocator, E.numrows, line, linelen);
            } else {
                break;
            }
        } else |_| {}
    }
    E.dirty = 0;
}

fn editorSave(allocator: Allocator) !void {
    if (E.filename == null) return;

    const buf = editorRowsToString(allocator) catch |err| {
        switch (err) {
            error.OutOfMemory => {
                try editorSetStatusMessage("Save failed: Out Of Memory", .{});
                return;
            },
            else => {
                try editorSetStatusMessage("Save failed: Out Of Memory", .{});
                return;
            },
        }
    };
    defer allocator.free(buf);
try log.logWithTimestampf("About to save {d} bytes to file: '{s}'", .{ buf.len, E.filename.? });
    try log.logWithTimestampf("Content preview: '{s}'", .{buf});

    const fp = std.fs.cwd().createFile(E.filename.?, .{ .read = true, .truncate = true }) catch |err| {
        switch (err) {
            error.AccessDenied => {
                try editorSetStatusMessage("Save Failed: Access Denied", .{});
                return;
            },
            error.NoSpaceLeft => {
                try editorSetStatusMessage("Save failed: No space left on device", .{});
                return;
            },
            else => {
                try editorSetStatusMessage("Save failed: Unknown error", .{});
                return;
            },
        }
    };
    defer fp.close();

    fp.writeAll(buf) catch |err| {
        switch (err) {
            error.AccessDenied => {
                try editorSetStatusMessage("Save Failed: Access Denied", .{});
                return;
            },
            error.NoSpaceLeft => {
                try editorSetStatusMessage("Save failed: No space left on device", .{});
                return;
            },
            else => {
                try editorSetStatusMessage("Save failed: Unknown error", .{});
                return;
            },
        }
    };
    try fp.sync();
    try editorSetStatusMessage("File saved successfully: {s}", .{E.filename.?});
    E.dirty = 0;
}

// ------- output ------- //
fn editorScroll() void {
    E.renderX = 0;
    if (E.cursorY < E.numrows) {
        E.renderX = editorRowCxToRx(&E.row[E.cursorY], E.cursorX);
    }

    if (E.cursorY < E.rowoff) {
        E.rowoff = E.cursorY;
    }
    if (E.cursorY >= E.rowoff + E.screenrows) {
        E.rowoff = E.cursorY - E.screenrows + 1;
    }
    if (E.renderX < E.coloff) {
        E.coloff = E.renderX;
    }
    if (E.renderX >= E.coloff + E.screencols) {
        E.coloff = E.renderX - E.screencols + 1;
    }
}

fn editorDrawRows(ab: *abuf) !void {
    for (0..E.screenrows) |index| {
        //_ = std.c.write(std.c.STDIN_FILENO, "~",1);
        const filerow = index + E.rowoff;
        var buf: [80]u8 = undefined;
        if (filerow >= E.numrows) {
            if (E.numrows == 0 and index == E.screenrows / 3) {
                const slice = try std.fmt.bufPrint(&buf, "Fifino editor - version: {s}", .{Config.VERSION});
                var welcome_len = slice.len;
                if (welcome_len > E.screencols) welcome_len = E.screencols;
                var padding = (E.screencols - welcome_len) / 2;
                if (padding > 0) try ab.append("~");
                while (padding > 0) : (padding -= 1) {
                    try ab.append(" ");
                }
                try ab.append(slice);
            } else {
                try ab.append("~");
            }
        } else {
            const row = &E.row[filerow];
            const row_len = row.render.len;

            if (@as(usize, E.coloff) < row_len) {
                const start = @as(usize, E.coloff);
                const available_chars = row_len - start;
                const chars_to_show = @min(available_chars, @as(usize, E.screencols));
                const end = start + chars_to_show;
                try ab.append(row.render[start..end]);
            }
            //try ab.append(E.row[filerow].chars[start..end]);
        }
        try ab.append("\x1b[K");
        //_ = std.c.write(std.c.STDIN_FILENO,"\r\n", 2);
        try ab.append("\r\n");
    }
}

fn editorDrawStatusBar(ab: *abuf) !void {
    try ab.append("\x1b[7m");
    var len: usize = 0;

    var buf: [80]u8 = undefined;
    var status: [80]u8 = undefined;
    const fname = try std.fmt.bufPrint(&buf, "{s:.20} - {d} lines {s}", .{ if (E.filename) |f| f else "[No Name]", E.numrows, if (E.dirty > 0) "(modified)" else "" });
    const lnumber = try std.fmt.bufPrint(&status, "{d}/{d}", .{ E.cursorY + 1, E.numrows });
    try ab.append(fname);

    len = fname.len;
    while (len < E.screencols) : (len += 1) {
        if (E.screencols - len == lnumber.len) {
            try ab.append(lnumber);
            break;
        } else {
            try ab.append(" ");
        }
    }
    try ab.append("\x1b[m");
    try ab.append("\r\n");
}

fn editorDrawMessageBar(ab: *abuf) !void {
    try log.logWithTimestamp("Show Message bar");
    try ab.append("\x1b[K");

    const msglen = if (E.statusmsg.len > E.screencols) E.screencols else E.statusmsg.len;
    if (std.time.timestamp() - E.statusmsg_time < 5)
        try ab.append(E.statusmsg[0..msglen]);
}
fn editorRefreshScreen(allocator: Allocator) !void {
    editorScroll();

    var ab = abuf.init(allocator);
    defer ab.free();

    try ab.append("\x1b[?25l");
    try ab.append("\x1b[H");

    try editorDrawRows(&ab);
    try editorDrawStatusBar(&ab);
    try editorDrawMessageBar(&ab);

    var buf: [32]u8 = undefined;
    const movedCursor = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ (E.cursorY - E.rowoff) + 1, (E.renderX - E.coloff) + 1 });
    try ab.append(movedCursor);

    try ab.append("\x1b[?25h");

    try std.io.getStdOut().writer().print("{s}", .{ab.toString()});
}

fn editorSetStatusMessage(comptime fmt: []const u8, args: anytype) !void {
    try log.logWithTimestampf("Message to display: {s}", .{fmt});
    const message = std.fmt.bufPrint(&E.statusmsg, fmt, args) catch {
        // Handle overflow by truncating
        const truncated = "Message too long...";
        @memcpy(E.statusmsg[0..truncated.len], truncated);
        E.statusmsg[truncated.len] = 0;
        try log.logWithTimestamp("Message too long..");
        return;
    };

    // Null-terminate the string
    if (message.len < E.statusmsg.len) {
        E.statusmsg[message.len] = 0;
    }

    E.statusmsg_time = std.time.timestamp();
}
// ------- input --------//

fn enableRawMode() !void {
    try log.logWithTimestamp("[enableRawMode] starting raw mode...");
    if (std.c.tcgetattr(std.c.STDIN_FILENO, &E.orig_termios) == -1)
        try die("tcgetattr");
    if (std.c.tcsetattr(std.c.STDIN_FILENO, .FLUSH, &E.orig_termios) == -1)
        try die("tcsetattr");

    var raw = E.orig_termios;

    raw.iflag.BRKINT = false;
    raw.iflag.ICRNL = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSTOPB = true;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.ICANON = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.c.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
    if (std.c.tcsetattr(std.c.STDIN_FILENO, .FLUSH, &raw) == -1)
        try die("tcsetattr");

    try log.logWithTimestamp("[enableRawMode] ... finish config");
}
fn editorReadKey() !u16 {
    var c: [1]u8 = undefined;

    while (true) {
        const nread = try std.posix.read(std.c.STDIN_FILENO, &c);
        if (nread == 1) break;
        if (nread == -1 and std.c._errno().* != @intFromEnum(std.c.E.AGAIN))
            try die("read");
    }
    if (c[0] == '\x1b') {
        var seq: [3]u8 = undefined;
        var nread = try std.posix.read(std.c.STDIN_FILENO, seq[0..1]);
        if (nread != 1) return '\x1b';

        nread = try std.posix.read(std.c.STDIN_FILENO, seq[1..2]);
        if (nread != 1) return '\x1b';

        if (seq[0] == '[') {
            if (seq[1] >= '0' and seq[1] <= '9') {
                nread = try std.posix.read(std.c.STDIN_FILENO, seq[2..]);
                if (nread != 1) return '\x1b';
                if (seq[2] == '~') {
                    switch (seq[1]) {
                        '1' => return @intFromEnum(editorKey.HOME_KEY),
                        '3' => return @intFromEnum(editorKey.DEL_KEY),
                        '4' => return @intFromEnum(editorKey.END_KEY),
                        '5' => return @intFromEnum(editorKey.PAGE_UP),
                        '6' => return @intFromEnum(editorKey.PAGE_DOWN),
                        '7' => return @intFromEnum(editorKey.HOME_KEY),
                        '8' => return @intFromEnum(editorKey.END_KEY),
                        else => {},
                    }
                }
            } else {
                switch (seq[1]) {
                    'A' => return @intFromEnum(editorKey.ARROW_UP),
                    'B' => return @intFromEnum(editorKey.ARROW_DOWN),
                    'C' => return @intFromEnum(editorKey.ARROW_RIGHT),
                    'D' => return @intFromEnum(editorKey.ARROW_LEFT),
                    'H' => return @intFromEnum(editorKey.HOME_KEY),
                    'F' => return @intFromEnum(editorKey.END_KEY),

                    else => {},
                }
            }
        } else if (seq[0] == 'O') {
            switch (seq[1]) {
                'H' => return @intFromEnum(editorKey.HOME_KEY),
                'F' => return @intFromEnum(editorKey.END_KEY),

                else => {},
            }
        }
        return '\x1b';
    } else {
        return c[0];
    }
}

fn editorMoveCursor(key: u16) void {
    var row: ?*EditorRow = if (E.cursorY >= E.numrows) null else &E.row[E.cursorY];

    switch (key) {
        @intFromEnum(editorKey.ARROW_LEFT) => {
            if (E.cursorX != 0) {
                E.cursorX -= 1;
            } else if (E.cursorY > 0) {
                E.cursorY -= 1;
                E.cursorX = @intCast(E.row[E.cursorY].chars.len);
            }
        },
        @intFromEnum(editorKey.ARROW_RIGHT) => {
            if (row) |r| {
                if (E.cursorX < r.chars.len) {
                    E.cursorX += 1;
                } else if (E.cursorX == r.chars.len) {
                    E.cursorY += 1;
                    E.cursorX = 0;
                }
            }
        },
        @intFromEnum(editorKey.ARROW_UP) => {
            if (E.cursorY != 0) E.cursorY -= 1;
        },
        @intFromEnum(editorKey.ARROW_DOWN) => {
            if (E.cursorY < E.numrows) E.cursorY += 1;
        },
        else => unreachable,
    }

    row = if (E.cursorY >= E.numrows) null else &E.row[E.cursorY];

    if (row) |r| {
        if (E.cursorX > r.chars.len) E.cursorX = @intCast(r.chars.len);
    }
}

fn editorProcessKeypress(allocator: Allocator) !void {
    const quit_times = struct {
        var times: u32 = Config.QUIT_TIMES;
    };
    const c = try editorReadKey();

    switch (c) {
        '\r' => {
            try editorInsertNewLine(allocator);
        },
        ctrlKey('q') => {
            if (E.dirty > 0 and quit_times.times > 0) {
                try editorSetStatusMessage("WARNING!!! File have unsaved changes. Press Ctrl-Q {d} more times to quit", .{quit_times.times});
                quit_times.times -= 1;
                return;
            }
            _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[2J", 4);
            _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[H", 3);
            try exit(0);
        },
        ctrlKey('s') => try editorSave(allocator),
        @intFromEnum(editorKey.ARROW_UP), @intFromEnum(editorKey.ARROW_DOWN), @intFromEnum(editorKey.ARROW_RIGHT), @intFromEnum(editorKey.ARROW_LEFT) => |char| {
            editorMoveCursor(char);
        },

        @intFromEnum(editorKey.BACKSPACE), ctrlKey('h'), @intFromEnum(editorKey.DEL_KEY) => {
            if (@intFromEnum(editorKey.DEL_KEY) == c) {
                editorMoveCursor(@intFromEnum(editorKey.ARROW_RIGHT));
                try log.logWithTimestamp("DEL key pressed - moving cursor right then deleting");
            } else {
                try log.logWithTimestamp("BACKSPACE key pressed");
            }
            try editorDelChar(allocator);
        },

        @intFromEnum(editorKey.PAGE_UP), @intFromEnum(editorKey.PAGE_DOWN) => {
            if (c == @intFromEnum(editorKey.PAGE_UP)) {
                E.cursorY = E.rowoff;
            } else if (c == @intFromEnum(editorKey.PAGE_DOWN)) {
                E.cursorY = E.rowoff + E.screenrows - 1;
                if (E.cursorY > E.numrows) E.cursorY = E.numrows;
            }
            for (0..E.screenrows) |_| {
                editorMoveCursor(if (c == @intFromEnum(editorKey.PAGE_UP)) @intFromEnum(editorKey.ARROW_UP) else @intFromEnum(editorKey.ARROW_DOWN));
            }
        },
        @intFromEnum(editorKey.HOME_KEY) => E.cursorX = 0,
        @intFromEnum(editorKey.END_KEY) => {
            if (E.cursorY < E.numrows) {
                E.cursorX = @intCast(E.row[E.cursorY].chars.len);
            }
        },
        ctrlKey('l'), '\x1b' => {},
        else => {
            try editorInsertChar(allocator, c);
        },
    }
    quit_times.times = Config.QUIT_TIMES;
}

// ------- init --------//

fn initEditor() !void {
    try log.logWithTimestamp("[InitEditor()] : start Editor config)");
    E.cursorX = 0;
    E.cursorY = 0;
    E.renderX = 0;
    E.rowoff = 0;
    E.coloff = 0;
    E.numrows = 0;
    E.row = &[_]EditorRow{};
    E.dirty = 0;
    E.statusmsg[0] = 0;
    E.statusmsg_time = 0;
    E.filename = null;
    if (try getWindowSize(&E.screenrows, &E.screencols) == -1) try die("getWindowSize");
    E.screenrows -= 2;
    try log.logWithTimestamp("[InitEditor()] : end Editor config)");
}

fn startEditor() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const check = gpa.deinit();
        switch (check) {
            .leak => std.io.getStdErr().writer().print("Memory leak detected", .{}) catch {},
            .ok => {},
        }
    }
    const allocator = gpa.allocator();

    log = Logger.init(allocator, "fifino.log");

    try log.logSection("Fifino 25-Giu-25");
    defer log.logSeparator() catch {};

    try enableRawMode();
    try initEditor();
    if (std.os.argv.len > 1) try editorOpen(allocator, std.mem.span(std.os.argv[1]));
    try editorSetStatusMessage("HELP: Ctrl-Q = quit | Ctrl-S = save", .{});
    while (true) {
        try editorRefreshScreen(allocator);
        try editorProcessKeypress(allocator);
        try log.logWithTimestamp("Refresh all the screen");
    }
    defer exit(0) catch {};
}
pub fn main() !void {
    startEditor() catch {
        try exit(1);
    };
}
