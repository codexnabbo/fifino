const std = @import("std");
const Allocator = std.mem.Allocator;

const version = "0.0.1";

const editorConfig = struct {
    cursorX: u16,
    cursorY: u16,
    screenrows: u16,
    screencols: u16,
    numrows: u16,
    row: EditorRow,
    orig_termios: std.c.termios = undefined,

};

const editorKey = enum(u16) {
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
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator, content: []const u8) !Self {
        const chars = try allocator.dupe(u8, content);
        return Self{
            .chars = chars,
           .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.chars);
    }
    
    pub fn append(self: *Self, s: []const u8) !void {
        const new_size = self.chars.len + s.len;
        self.chars = try self.allocator.realloc(self.chars, new_size);
        @memcpy(self.chars[self.chars.len - s.len..], s);
    }

};

const abuf = struct {
    b: ?[]u8,
    len: usize,
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self{
        return Self{
            .b = null,
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn append(self: *Self, s: []const u8) !void {
        const new_len = self.len + s.len;

        if (self.b)  |buffer| {
            // We try to realloc the existent buffer
            if (self.allocator.realloc(buffer, new_len)) |new_buffer| {
                @memcpy(new_buffer[self.len..new_len] , s);
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
       return if(self.b) |buffer| buffer[0..self.len] else "";
    }
};

var E: editorConfig = undefined;

// ------- Data -------- //

fn ctrlKey(k: u8) u8 {
    return k & 0x1f;
}

fn sscan(c: []u8) !void{
    var token = std.mem.splitScalar(u8, c, ';');
    E.screenrows = try std.fmt.parseInt(u16, token.next().?, 10);
    E.screencols = try std.fmt.parseInt(u16, sliceUntilEnd(token.next().?), 10);
}

// ------- terminal ---------//

fn die(s: []const u8) void {
    _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[2J", 4);
    _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[H", 3);
    std.log.err("Error trying  to compute: {s}", .{s});
    exit(1);
}

fn sliceUntilEnd(buf: []const u8) []const u8 {
    var i: usize = 0;
    while (i < buf.len and buf[i] != 0x00) : (i += 1) {}
    return buf[0..i];
}

fn disableRawMode() callconv(.c) void{
    if(std.c.tcsetattr(std.c.STDIN_FILENO,.FLUSH, &E.orig_termios) == -1) 
        die("tcsetattr");
    
    std.debug.print("Restore terminal settings\n", .{});
}

fn exit(i: c_int) void {
    disableRawMode();
    std.c.exit(i);
}

fn getCursorPosition() !i8 {
    var buf: [32]u8 = undefined;
    var i: usize = 0;

    if (std.c.write(std.c.STDOUT_FILENO, "\x1b[6n", 4) != 4) return -1;

    while (i < std.zig.c_translation.sizeof(buf) - 1) : (i+=1){
        if(std.c.read(std.c.STDIN_FILENO,buf[i..][0..1].ptr,1) != 1) break;
        if(buf[i] == 'R') break;
    }

    buf[i] = '\x00';
    if(buf[0] != '\x1b' or buf[1] != '[') return -1;
    try sscan(buf[2..8]);
    return 0;
}


fn getWindowSize(rows: *u16, cols: *u16) !i8 {
    var ws: std.c.winsize = undefined;

    if (std.c.ioctl(std.c.STDOUT_FILENO, std.c.T.IOCGWINSZ, &ws) == -1 or ws.col == 0) {
        if(std.c.write(std.c.STDOUT_FILENO,"\x1b[999C\x1b[999B", 12) != 12) return -1;
        return getCursorPosition();
    } else {
        rows.* = ws.row;
        cols.* = ws.col;
    }
    return 0;
}
// ------- file i/o ----- //
    
fn editorOpen(allocator: Allocator, file_path: []const u8) !void {
    const fp = std.fs.cwd().openFile(file_path, .{ .mode = std.fs.File.OpenMode.read_only}) catch |err| {
        switch (err) {
            error.FileNotFound => die("OpenFile: File not Found"),
            error.AccessDenied => die("OpenFIle: Access denied"),
            else => die("OpenFile: Unknow Error"),
        }
        return err;
    };
    defer fp.close();

    var buf_reader = std.io.bufferedReader(fp.reader());
    var in_stream = buf_reader.reader();

    var line_buffer: [4096]u8 = undefined;

    if(in_stream.readUntilDelimiterOrEof(line_buffer[0..], '\n')) |maybe_line| {
        if(maybe_line) |line| {
            var linelen = line.len;

            while (linelen > 0 and (line[linelen - 1] == '\n' or line[linelen - 1] == '\r')) {
                linelen -= 1;
            }

            std.debug.print("{s}", .{line});
            E.row.chars = try allocator.alloc(u8, linelen+1);
            try E.row.append(line);
            E.row.chars[linelen] = 0;
            E.numrows = 1;
        }
    } else |_| {}
}

// ------- output ------- //

fn editorDrawRows(ab: *abuf) !void {

    for(0..E.screenrows) |index| {
        //_ = std.c.write(std.c.STDIN_FILENO, "~",1);
        var buf: [80]u8 = undefined;
        if (index >= E.numrows) {
        if(index == E.screenrows / 3){
            const slice = try std.fmt.bufPrint(&buf,"Fifino editor - version: {s}", .{version});
            var welcome_len = slice.len;
            if(welcome_len > E.screencols) welcome_len = E.screencols;
            var padding = (E.screencols - welcome_len) / 2;
            if(padding > 0) try ab.append("~");
            while (padding > 0) : (padding -= 1) {
                try ab.append(" ");
            }
            try ab.append(slice);
        }else{
        try ab.append("~");
        }
    } else {
            var len = E.row.chars.len;
            if(len > E.screencols) len = E.screencols;
            try ab.append(E.row.chars);
        }
        try ab.append("\x1b[K");
        if(index < E.screenrows - 1 ){
            //_ = std.c.write(std.c.STDIN_FILENO,"\r\n", 2);
            try ab.append("\r\n");
        }
    }
}

fn editorRefreshScreen(allocator: Allocator) !void {

    
    var ab = abuf.init(allocator);
    defer ab.free();

    try ab.append("\x1b[?25l");
    try ab.append("\x1b[H");

    try editorDrawRows(&ab);

    var buf: [32]u8 = undefined;
    const movedCursor = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{E.cursorY + 1, E.cursorX + 1});
    try ab.append(movedCursor);

    try ab.append("\x1b[?25h");   

    try std.io.getStdOut().writer().print("{s}", .{ab.toString()});
    
}

// ------- input --------//

fn enableRawMode() void {

    if(std.c.tcgetattr(std.c.STDIN_FILENO, &E.orig_termios) == -1 ) 
        die("tcgetattr");
    if(std.c.tcsetattr(std.c.STDIN_FILENO, .FLUSH, &E.orig_termios) == -1)
        die("tcsetattr");

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
    raw.cc[@intFromEnum(std.c.V.TIME)] = 1;
    if(std.c.tcsetattr(std.c.STDIN_FILENO,.FLUSH,&raw) == -1) 
        die("tcsetattr");

}
fn editorReadKey() !u16 {
    var c: [1]u8 = undefined;

    while (true){
        const nread = try std.posix.read(std.c.STDIN_FILENO, &c);
        if (nread == 1) break;
        if(nread == -1 and std.c._errno().* != @intFromEnum(std.c.E.AGAIN)) 
            die("read");
    }
    if(c[0] == '\x1b'){
        var seq: [3]u8 = undefined;
        var nread = try std.posix.read(std.c.STDIN_FILENO, seq[0..1]);
        if (nread != 1) return '\x1b';

        nread = try std.posix.read(std.c.STDIN_FILENO, seq[1..2]);
        if (nread != 1) return '\x1b';

        if (seq[0] == '[') {
            if(seq[1] >= '0' and  seq[1] <= '9'){
                nread = try std.posix.read(std.c.STDIN_FILENO, seq[2..]);
                if(nread != 1) return '\x1b';
                if(seq[2] == '~'){
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
                    'A' => return  @intFromEnum(editorKey.ARROW_UP),
                    'B' => return @intFromEnum(editorKey.ARROW_DOWN),
                    'C' => return @intFromEnum(editorKey.ARROW_RIGHT),
                    'D' => return @intFromEnum(editorKey.ARROW_LEFT),
                    'H' => return @intFromEnum(editorKey.HOME_KEY),
                    'F' => return @intFromEnum(editorKey.END_KEY),

                    else => {},
                }
            }

        } else if(seq[0] == 'O') {
             switch (seq[1]) {
                'H' => return @intFromEnum(editorKey.HOME_KEY),
                'F' => return @intFromEnum(editorKey.END_KEY),

                else =>{} ,
            }

        }
        return '\x1b';
    } else {
        return c[0];
    }
}

fn editorMoveCursor(key: u16) void {

    switch (key) {
        @intFromEnum(editorKey.ARROW_LEFT) => {if(E.cursorX != 0)  E.cursorX -= 1;},
        @intFromEnum(editorKey.ARROW_RIGHT) => {if(E.cursorX != E.screencols - 1) E.cursorX += 1;},
        @intFromEnum(editorKey.ARROW_UP) => {if(E.cursorY != 0) E.cursorY -= 1;},
        @intFromEnum(editorKey.ARROW_DOWN) =>{ if(E.cursorY != E.screenrows - 1 ) E.cursorY += 1;},
        else => unreachable,
    }
}

fn editorProcessKeypress() !void {

    const c = try editorReadKey();

    switch (c) {
        ctrlKey('q') => {

            _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[2J", 4);
            _ = std.c.write(std.c.STDOUT_FILENO, "\x1b[H", 3);
            exit(0);
        },
        @intFromEnum(editorKey.ARROW_UP),
        @intFromEnum(editorKey.ARROW_DOWN),
        @intFromEnum(editorKey.ARROW_RIGHT),
        @intFromEnum(editorKey.ARROW_LEFT) => |char| { editorMoveCursor(char); },

        @intFromEnum(editorKey.PAGE_UP),
        @intFromEnum(editorKey.PAGE_DOWN) => {
            for(0..E.screenrows) |_| {
                editorMoveCursor(if(c == @intFromEnum(editorKey.PAGE_UP))  @intFromEnum(editorKey.ARROW_UP) else  @intFromEnum(editorKey.ARROW_DOWN));  
            } 
        },
        @intFromEnum(editorKey.HOME_KEY) => E.cursorX = 0,
        @intFromEnum(editorKey.END_KEY) => E.cursorX = E.screencols - 1,
        else => {},
    } 

}


// ------- init --------//

fn initEditor(allocator: Allocator) !void {
    E.cursorX = 0;
    E.cursorY =0;
    E.numrows = 0;
    E.row = try EditorRow.init(allocator, "");
    if (try getWindowSize(&E.screenrows, &E.screencols) == -1) die("getWindowSize");
}

pub fn main() !void{
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer {
        const check = gpa.deinit();
        switch (check) {
            .leak =>  std.io.getStdErr().writer().print("Memory leak detected", .{}) catch {},
            .ok => {},
        }
    }
    const allocator = gpa.allocator();

    enableRawMode();
    try initEditor(allocator);
    if (std.os.argv.len > 1) try editorOpen(allocator, std.mem.span(std.os.argv[1]));
    while (true) {
        try editorRefreshScreen(allocator);
        try editorProcessKeypress();
        
    }
    defer exit(0);
}
