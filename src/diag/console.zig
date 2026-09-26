const std = @import("std");
const formatting = @import("format.zig");
const sdk = @import("sdk");

const win32 = sdk.win32;

extern "kernel32" fn GetConsoleMode(console: win32.HANDLE, mode: *u32) callconv(.winapi) win32.BOOL;
extern "kernel32" fn WriteConsoleW(console: win32.HANDLE, buffer: [*]const u16, count: u32, written: ?*u32, reserved: ?*anyopaque) callconv(.winapi) win32.BOOL;

const Stream = enum { out, err };

fn hasConsole() bool {
    return win32.GetConsoleWindow() != null;
}

pub fn hasStandardError() bool {
    return handleFor(.err) != null;
}

fn handleFor(stream: Stream) ?win32.HANDLE {
    const handle = win32.GetStdHandle(if (stream == .out) win32.STD_OUTPUT_HANDLE else win32.STD_ERROR_HANDLE) orelse return null;
    if (!win32.isValid(handle)) return null;
    return handle;
}

pub fn write(stream: Stream, text: []const u8) void {
    const handle = handleFor(stream) orelse return;
    var mode: u32 = 0;
    if (GetConsoleMode(handle, &mode) != 0) {
        var wide: [1024]u16 = undefined;
        var remaining = text;
        while (remaining.len > 0) {
            var consumed: usize = 0;
            var produced: usize = 0;
            while (consumed < remaining.len and produced + 2 <= wide.len) {
                const length = std.unicode.utf8ByteSequenceLength(remaining[consumed]) catch 1;
                if (consumed + length > remaining.len) {
                    wide[produced] = 0xFFFD;
                    produced += 1;
                    consumed = remaining.len;
                    break;
                }
                const code_point = std.unicode.utf8Decode(remaining[consumed .. consumed + length]) catch 0xFFFD;
                if (code_point >= 0x10000) {
                    const offset = code_point - 0x10000;
                    wide[produced] = @intCast(0xD800 + (offset >> 10));
                    wide[produced + 1] = @intCast(0xDC00 + (offset & 0x3FF));
                    produced += 2;
                } else {
                    wide[produced] = @intCast(code_point);
                    produced += 1;
                }
                consumed += length;
            }
            _ = WriteConsoleW(handle, &wide, @intCast(produced), null, null);
            remaining = remaining[consumed..];
        }
        return;
    }
    var offset: usize = 0;
    while (offset < text.len) {
        var written: u32 = 0;
        const chunk: u32 = @intCast(@min(text.len - offset, 1 << 20));
        if (win32.WriteFile(handle, text[offset..].ptr, chunk, &written, null) == 0 or written == 0) return;
        offset += written;
    }
}

pub fn print(stream: Stream, comptime format: []const u8, args: anytype) void {
    var buffer: [4096]u8 = undefined;
    write(stream, formatting.print(&buffer, format, args));
}
