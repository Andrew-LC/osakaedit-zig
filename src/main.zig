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

const kilo_tab_stop = 12;

const kilo_version = "0.0.1";

const editorKey = enum(u16) {
    BACKSPACE = 127,
    ARROW_LEFT = 1000,
    ARROW_RIGHT,
    ARROW_UP,
    ARROW_DOWN,
    DEL_KEY,
    HOME,
    END,
    PAGE_UP,
    PAGE_DOWN,
    _
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
    rsize: usize,
    chars: []u8,
    render: []u8,

    pub fn init(alloc: Allocator, s: []const u8) !ERow {
        return ERow{
            .size = s.len,
            .rsize = 0,
            .chars = try alloc.dupe(u8, s),
            .render = undefined
        };
    }
};

// Global Editor Config
const EditorConfig = struct {
    cx: usize,
    cy: usize,
    rx: usize,
    rowoff: usize,
    coloff: usize,
    screenrows: usize,
    screencols: usize,
    orig_termios: os.termios,
    abuf: ABuf,
    numrows: usize,
    erows: std.ArrayList(ERow),
    filename: ?[]const u8,

    pub fn init(alloc: Allocator) EditorConfig {
        return EditorConfig{
            .cx = 0,
            .cy = 0,
            .rx = 0,
            .rowoff = 0,
            .coloff = 0,
            .screenrows = 0,
            .screencols = 0,
            .orig_termios = undefined,
            .abuf = ABuf.init(alloc),
            .numrows = 0,
            .erows = std.ArrayList(ERow).init(alloc),
            .filename = undefined,
        };
    }
};

// Initialize the global config
var config = EditorConfig.init(allocator);

fn initEditor() !void {
    if (!try getWindowSize(&config.screenrows, &config.screencols)) {
        return error.WindowSizeError;
    }
    config.screenrows -= 1;
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

fn editorRowCxToRx(row: *const ERow, cx: usize) usize {
    var rx: usize = 0;
    for (row.chars[0..cx]) |char| {
        if (char == '\t') {
            rx += (kilo_tab_stop - 1) - (rx % kilo_tab_stop);
        }
        rx += 1;
    }
    return rx;
}

fn editorUpdateRow(row: *ERow) !void {
    var tabs: usize = 0;
    for (row.chars) |char| {
        if (char == '\t') tabs += 1;
    }
    
    row.render = try allocator.alloc(u8, row.size + tabs * (kilo_tab_stop));
    
    var idx: usize = 0;
    for (row.chars) |char| {
        if (char == '\t') {
            row.render[idx] = ' ';
            idx += 1;
            while (idx % kilo_tab_stop != 0) {
                if (idx >= row.render.len) break;
                row.render[idx] = ' ';
                idx += 1;
            }
        } else {
            if (idx >= row.render.len) break;
            row.render[idx] = char;
            idx += 1;
        }
    } 
    row.rsize = idx;
}

fn editorAppendRow(s: []const u8) !void {
    var new_row = try ERow.init(allocator, s);
    try config.erows.append(new_row);
    try editorUpdateRow(&config.erows.items[config.erows.items.len - 1]);
    config.numrows += 1;
}

fn editorOpen(filename: []const u8) !void {
    config.filename = filename;
    var file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var buffer: [1024]u8 = undefined;
    while (try file.reader().readUntilDelimiterOrEof(&buffer, '\n')) |line| {
        try editorAppendRow(line);
    }
}

fn editorRowInsertChar(row: *ERow, at: usize, c: u8) !void {
    if (at > row.size) return;
    
    const new_chars = try allocator.alloc(u8, row.size + 1);
    defer allocator.free(row.chars); // Free the old buffer

    @memcpy(new_chars[0..at], row.chars[0..at]);
    new_chars[at] = c;
    @memcpy(new_chars[at+1..], row.chars[at..]);

    row.chars = new_chars;
    row.size += 1;
    try editorUpdateRow(row);
}

fn editorInsertChar(c: u16) !void {
    if (config.cy == config.numrows) {
        try editorAppendRow(&[_]u8{});
    }
    
    const char: u8 = @truncate(c);
    
    try editorRowInsertChar(&config.erows.items[config.cy], config.cx, char);
    config.cx += 1;
}

fn editorMoveCursor(key: editorKey) void {
    const row = if (config.cy < config.numrows) config.erows.items[config.cy] else null;

    switch (key) {
        .ARROW_LEFT => {
            if (config.cx != 0) {
                config.cx -= 1;
            } else if (config.cy > 0) {
                config.cy -= 1;
                config.cx= config.erows.items[config.cy].size;
            }
        },
        .ARROW_RIGHT => {
            if (row) |r| {
                if (config.cx < r.size) {
                    config.cx += 1;
                } else if (config.cy < config.numrows - 1) {
                    config.cy += 1;
                    config.cx = 0;
                }
            }
        },
        .ARROW_UP => {
            if (config.cy > 0) config.cy -= 1;
        },
        .ARROW_DOWN => {
            if (config.cy < config.numrows - 1) config.cy += 1;
        },
        else => {},
    }

    // Snap cursor to end of line
    const newrow = if (config.cy < config.numrows) config.erows.items[config.cy] else null;
    const rowlen = if (newrow) |r| r.size else 0;
    if (config.cx > rowlen) {
        config.cx = rowlen;
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
    if (c == ctrlKey('l')) return true;
    std.debug.print("Read key: {}\n", .{c});


    switch (@as(editorKey, @enumFromInt(c))) {
        .ARROW_UP, .ARROW_DOWN, .ARROW_RIGHT, .ARROW_LEFT => |key| {
            editorMoveCursor(key);
        },
        .BACKSPACE => {
            
        },
        else => {
            _ = try editorInsertChar(c);
        },
    }
    return false;
}


fn editorScroll() !void {
    config.rx = 0;
    if (config.cy < config.numrows) {
        config.rx = editorRowCxToRx(&config.erows.items[config.cy], config.cx);
    }
    
    if(config.cy < config.rowoff) {
        config.rowoff = config.cy;
    }
    if (config.cy >= config.rowoff + config.screenrows) {
        config.rowoff = config.cy - config.screenrows + 1;
    }
    if(config.rx < config.coloff) {
        config.coloff = config.rx;
    }
    if (config.rx >= config.coloff + config.screencols) {
        config.coloff = config.rx - config.screencols + 1;
    }
}

fn editorDrawRows() !void {
    var y: usize = 0;
    while (y < config.screenrows) : (y += 1) {
        var filerow: usize = y + config.rowoff;
        if (filerow >= config.numrows) {
            if (config.numrows == 0 and y == config.screenrows / 3) {
                var welcome: [80]u8 = undefined;
                const welcome_msg = try std.fmt.bufPrint(
                    &welcome,
                    "OSAKA Editor -- version {s}",
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
            const row = &config.erows.items[filerow];
            var len: usize = if (row.rsize > config.coloff) row.rsize - config.coloff else 0;
            if (len > config.screencols) len = config.screencols;
            if (len > 0) {
                try config.abuf.abAppend(row.render[config.coloff..][0..len]);
            }
        }

        try config.abuf.abAppend("\x1b[K");
        try config.abuf.abAppend("\r\n");
    }
}

fn editorDrawStatusBar() !void {
    _ = try config.abuf.abAppend("\x1b[7m");
    
    var status: [80]u8 = undefined;
    var rstatus: [80]u8 = undefined;
    const len = std.fmt.bufPrint(
        &status,
        "{s:.20} - {} lines | kevin's a fatty btw",
        .{
            if (config.filename) |f| f else "[No Name]",
            config.numrows
        }
    ) catch unreachable;
    const rlen = std.fmt.bufPrint(
        &rstatus, // Changed from &status to &rstatus
        "{}/{}", // Changed format string
        .{config.cy + 1, config.numrows}
    ) catch unreachable;
    const display_len = @min(len.len, config.screencols);
    _ = try config.abuf.abAppend(status[0..display_len]);
    
    var i: usize = display_len;
    while (i < config.screencols) : (i += 1) {
        if (config.screencols - i == rlen.len) {
            _ = try config.abuf.abAppend(rstatus[0..rlen.len]);
            break;
        } else {
            _ = try config.abuf.abAppend(" ");
        }
    }
    _ = try config.abuf.abAppend("\x1b[m");
}

fn editorRefreshScreen() !void {
    _ = try editorScroll();
    
    _ = try config.abuf.abAppend("\x1b[?25l"); // Hide cursor
    _ = try config.abuf.abAppend("\x1b[H");    // Move cursor to top-left corner

    try editorDrawRows();
    try editorDrawStatusBar();

    var buff: [32]u8 = undefined;
    const written = try std.fmt.bufPrint(
        &buff,
        "\x1b[{d};{d}H",
        .{ (config.cy - config.rowoff) + 1, (config.rx - config.coloff) + 1 }
    );
    _ = try config.abuf.abAppend(buff[0..written.len]);

    _ = try config.abuf.abAppend("\x1b[?25h"); // Show cursor

    _ = try os.write(os.STDOUT_FILENO, config.abuf.b);
    
    config.abuf.abFree();
}

pub fn main() !void {
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <filename>\n", .{args[0]});
        std.os.exit(1);
    }

    try enableRawMode();
    defer disableRawMode();
    try initEditor();
    try editorOpen(args[1]);

    while (true) {
        try editorRefreshScreen();
        if (try editorProcessKeypress()) break;
    }
}
