const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const heap = @import("heap.zig");
const ui = @import("gui/win32_ui.zig");
const window = @import("gui/window.zig");
const elevate = @import("gui/elevate.zig");

const win32 = sdk.win32;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

extern "shell32" fn CommandLineToArgvW(command_line: [*:0]const u16, count: *c_int) callconv(.winapi) ?[*][*:0]u16;

fn reportPanic(message: []const u8) void {
    const intro = "rgbctrl Settings ran into an internal error and has to close: ";
    var text: [512]u8 = undefined;
    const detail = sdk.text.utf8Prefix(message, text.len - intro.len);
    const shown = std.fmt.bufPrint(&text, intro ++ "{s}", .{detail}) catch return;
    var wide: [text.len + 1]u16 = undefined;
    const converted = sdk.text.utf8ToUtf16(&wide, shown) orelse return;
    _ = ui.MessageBoxW(null, converted.ptr, win32.L("rgbctrl Settings"), ui.MB_OK | ui.MB_ICONERROR);
}

pub fn main() u8 {
    _ = win32.SetDefaultDllDirectories(win32.LOAD_LIBRARY_SEARCH_SYSTEM32);
    sdk.panic.hook = reportPanic;
    var arena_state = std.heap.ArenaAllocator.init(heap.allocator);
    defer arena_state.deinit();
    const arguments = collectArguments(arena_state.allocator()) catch return 1;
    if (arguments.len >= 2 and std.mem.eql(u8, arguments[1], elevate.helper_flag)) {
        return @intCast(elevate.runHelper(arguments[2..]));
    }
    return window.run();
}

fn collectArguments(arena: std.mem.Allocator) ![]const []const u8 {
    var count: c_int = 0;
    const vector = CommandLineToArgvW(win32.GetCommandLineW(), &count) orelse return error.OutOfMemory;
    defer _ = win32.LocalFree(@ptrCast(vector));
    const total: usize = @intCast(@max(count, 0));
    const list = try arena.alloc([]const u8, total);
    for (list, 0..) |*argument, index| {
        const wide = std.mem.span(vector[index]);
        const utf8 = try arena.alloc(u8, wide.len * 3);
        argument.* = sdk.text.utf16ToUtf8(utf8, wide);
    }
    return list;
}
