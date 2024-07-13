const std = @import("std");
const os = std.os;
const io = std.io;
const mem = std.mem;
const debug = std.debug;
const Termios = os.linux.termios;
const Allocator = std.mem.Allocator;

inline fn ctrlKey(comptime k: u8) u8 {
    return k & 0x1f;
}

const kilo_version = "0.0.1";

const editorKey = enum(u16) {
    ARROW_LEFT = 1000,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    _,
};

// Allocator
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

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

// Editor Row
const ERow = struct {
    size: usize,
    chars: []u8,

    pub fn init() ERow {
        return .{
            .size = 0,
            .chars = undefined
        };
    }
};

// Global Editor Config
const EditorConfig = struct {
    cx: usize,
    cy: usize,
    screenrows: usize,
    screencols: usize,
    orig_termios: os.termios,
    abuf: ABuf,
    numrows: usize,
    erow: ERow,

    pub fn init(alloc: Allocator) EditorConfig {
        return EditorConfig{
            .cx = 0,
            .cy = 0,
            .screenrows = 0,
            .screencols = 0,
            .orig_termios = undefined,
            .abuf = ABuf.init(alloc),
            .numrows = 0,
            .erow = ERow.init(),
        };
    }
};

// Initialize the global config
var config = EditorConfig.init(allocator);

fn initEditor() !void {
    if (!try getWindowSize(&config.screenrows, &config.screencols)) {
        return error.WindowSizeError;
    }
}

fn enableRawMode() !void {
    config.orig_termios = try os.tcgetattr(os.STDIN_FILENO);
    var raw = config.orig_termios;
    raw.iflag &= ~(@as(u32, os.linux.BRKINT | os.linux.ICRNL | os.linux.INPCK | os.linux.ISTRIP | os.linux.IXON));
    raw.oflag &= ~(@as(u32, os.linux.OPOST));
    raw.lflag &= ~(@as(u32, os.linux.ECHO | os.linux.ICANON | os.linux.IEXTEN | os.linux.ISIG));
    raw.cc[os.linux.V.MIN] = 0;
    raw.cc[os.linux.V.TIME] = 1;
    try os.tcsetattr(os.STDIN_FILENO, .FLUSH, raw);
}

fn disableRawMode() void {
    _ = os.write(os.STDOUT_FILENO, "\x1b[2J") catch {};
    _ = os.write(os.STDOUT_FILENO, "\x1b[H") catch {};
    os.tcsetattr(os.STDIN_FILENO, .FLUSH, config.orig_termios) catch |err| {
        debug.print("Error disabling raw mode: {}\n", .{err});
    };
}


fn getCursorPosition(rows: *usize, cols: *usize) !bool {
    const buf = "\x1b[6n";
    const written = try os.write(os.STDOUT_FILENO, buf);
    if (written != buf.len) return false;

    var response: [32]u8 = undefined;
    var i: usize = 0;
    while (i < response.len - 1) {
        const nread = try os.read(os.STDIN_FILENO, response[i..][0..1]);
        if (nread != 1) return false;
        if (response[i] == 'R') break;
        i += 1;
    }
    response[i + 1] = 0;

    if (response[0] != '\x1b' or response[1] != '[') return false;
    
    var iterator = mem.split(u8, response[2..i], ";");
    const row_str = iterator.next() orelse return false;
    const col_str = iterator.next() orelse return false;

    rows.* = try std.fmt.parseInt(usize, row_str, 10);
    cols.* = try std.fmt.parseInt(usize, col_str, 10);

    return true;
}

fn getWindowSize(rows: *usize, cols: *usize) !bool {
    var ws: os.linux.winsize = undefined;
    if (os.linux.ioctl(os.STDOUT_FILENO, os.linux.T.IOCGWINSZ, @intFromPtr(&ws)) == -1 or ws.ws_col == 0) {
        const buf = "\x1b[999C\x1b[999B";
        const written = try os.write(os.STDOUT_FILENO, buf);
        if (written != buf.len) return false;
        
        return try getCursorPosition(rows, cols);
    } else {
        cols.* = ws.ws_col;
        rows.* = ws.ws_row;
        return true;
    }
}

fn editorOpen(filename: []const u8, alloc: Allocator) !void {
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var line = try alloc.alloc(u8, 1024);
    errdefer alloc.free(line);

    const read_result = try file.read(line);
    var linelen: usize = read_result;

    while (linelen > 0 and (line[linelen - 1] == '\n' or line[linelen - 1] == '\r')) {
        linelen -= 1;
    }

    config.erow.size = linelen;
    config.erow.chars = try std.heap.page_allocator.alloc(u8, linelen + 1);
    std.mem.copy(u8, config.erow.chars[0..linelen], line[0..linelen]);
    config.erow.chars[linelen] = 0;
    config.numrows = 1;
}

fn editorMoveCursor(key: editorKey) void {
    switch (key) {
        .ARROW_LEFT => {
            if (config.cx > 0) config.cx -= 1;
        },
        .ARROW_RIGHT => {
            if (config.cx < config.screencols - 1) config.cx += 1;
        },
        .ARROW_UP => {
            if (config.cy > 0) config.cy -= 1;
        },
        .ARROW_DOWN => {
            if (config.cy < config.screenrows - 1) config.cy += 1;
        },
        else => {}
    }
}


fn editorReadKey() !u16 {
    var c: [1]u8 = undefined;
    while (true) {
        const nread = try os.read(os.STDIN_FILENO, &c);
        if (nread == 1) {
            if (c[0] == '\x1b') {
                var seq: [2]u8 = undefined;
                if (try os.read(os.STDIN_FILENO, seq[0..1]) != 1) return '\x1b';
                if (try os.read(os.STDIN_FILENO, seq[1..2]) != 1) return '\x1b';

                if (seq[0] == '[') {
                    switch (seq[1]) {
                        'A' => return @intFromEnum(editorKey.ARROW_UP),
                        'B' => return @intFromEnum(editorKey.ARROW_DOWN),
                        'C' => return @intFromEnum(editorKey.ARROW_RIGHT),
                        'D' => return @intFromEnum(editorKey.ARROW_LEFT),
                        else => return '\x1b',
                    }
                }
                return '\x1b';
            } else {
                return c[0];
            }
        }
    }
}

fn editorProcessKeypress() !bool {
    const c = try editorReadKey();
    if (c == ctrlKey('q')) return true;

    switch (@as(editorKey, @enumFromInt(c))) {
        .ARROW_UP, .ARROW_DOWN, .ARROW_RIGHT, .ARROW_LEFT => |key| {
            editorMoveCursor(key);
        },
        else => {},
    }
    return false;
}

fn editorDrawRows() !void {
    var y: usize = 0;
    while (y < config.screenrows) : (y += 1) {
        if(y > config.numrows) {
            if (config.numrows == 0 and y == config.screenrows / 3) {
                var welcome: [80]u8 = undefined;
                const welcome_msg = try std.fmt.bufPrint(
                    &welcome,
                    "KickAss Editor -- version {s}",
                    .{kilo_version}
                );
                const padding = @max(0, @divFloor(@as(usize, config.screencols) - @as(usize, welcome_msg.len), 2));
                const display_len = @min(welcome_msg.len, config.screencols);

                try config.abuf.abAppend("~");
                var i: usize = 0;
                while (i < padding - 1) : (i += 1) {
                    try config.abuf.abAppend(" ");
                }
                try config.abuf.abAppend(welcome_msg[0..display_len]);
            } else {
                try config.abuf.abAppend("~");
            }
        } else {
            var len: usize = config.erow.size;
            if(len > config.screencols) len = config.screencols;
            try config.abuf.abAppend(config.erow.chars);
        } 

        try config.abuf.abAppend("\x1b[K");
        if (y < config.screenrows - 1) {
            try config.abuf.abAppend("\r\n");
        }
    }
}

fn editorRefreshScreen() !void {
    _ = try config.abuf.abAppend("\x1b[?25l"); // Hide cursor
    _ = try config.abuf.abAppend("\x1b[H");    // Move cursor to top-left corner

    try editorDrawRows();

    var buff: [32]u8 = undefined;
    const written = try std.fmt.bufPrint(
        &buff,
        "\x1b[{d};{d}H",
        .{ config.cy + 1, config.cx + 1 }
    );
    _ = try config.abuf.abAppend(buff[0..written.len]);

    _ = try config.abuf.abAppend("\x1b[?25h"); // Show cursor

    _ = try os.write(os.STDOUT_FILENO, config.abuf.b);
    
    config.abuf.abFree();
}

pub fn main() !void {
    try enableRawMode();
    defer disableRawMode();
    try initEditor();
    try editorOpen("./sample.txt", allocator);

    while (true) {
        try editorRefreshScreen();
        if (try editorProcessKeypress()) break;

        std.time.sleep(std.time.ns_per_ms * 10);
    }
}
