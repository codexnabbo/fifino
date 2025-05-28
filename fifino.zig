const std = @import("std");

var orig_termios: std.c.termios = undefined;

fn die(s: []const u8) void {
    std.log.err("Error trying  to compute: {s}", .{s});
    std.process.exit(1);
}

fn disableRawMode() callconv(.c) void{
    if(std.c.tcsetattr(std.c.STDIN_FILENO,.FLUSH, &orig_termios) == -1) 
        die("tcsetattr");
    
    std.debug.print("Restore terminal settings\n", .{});
}

fn enableRawMode() void {

    if(std.c.tcgetattr(std.c.STDIN_FILENO, &orig_termios) == -1 ) 
        die("tcgetattr");
    if(std.c.tcsetattr(std.c.STDIN_FILENO, .FLUSH, &orig_termios) == -1)
        die("tcsetattr");

    var raw = orig_termios;
    
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


pub fn main() void{
   enableRawMode();
        
    while (true)
    {
        var c: [1]u8 = [_]u8{'\x00'};
        if(
            std.c.read(std.c.STDIN_FILENO, &c, 1) == -1 
        and std.c._errno().* != @intFromEnum(std.c.E.AGAIN)) 
            die("read");
        if (std.ascii.isControl(c[0])) {
            std.debug.print("{d}\r\n", .{c});
        } else {
         std.debug.print("{d} ('{c}')\r\n", .{c,c});
        }

        if(c[0] == 'q') break;
    }
    defer disableRawMode();
}
