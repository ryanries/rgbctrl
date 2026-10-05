const std = @import("std");
const sdk = @import("sdk");
const json = @import("../config/json.zig");
const platform = @import("../platform.zig");
const heap = @import("../heap.zig");
const safe_open = @import("../security/safe_open.zig");
const install_check = @import("../security/install_check.zig");
const inventory = @import("../runtime/inventory.zig");

const win32 = sdk.win32;

pub const ReadError = error{ OutOfMemory, TooLarge, Unreadable };

/// The content of the file at path, or null when there is none.
pub fn readText(allocator: std.mem.Allocator, path: [:0]const u16) ReadError!?[]u8 {
    const opened = safe_open.openPlain(path.ptr) catch |err| switch (err) {
        error.NotFound => return null,
        else => return error.Unreadable,
    };
    defer opened.close();
    return safe_open.readAll(allocator, opened.handle, json.max_source_bytes) catch |err| switch (err) {
        error.TooLarge => error.TooLarge,
        error.OutOfMemory => error.OutOfMemory,
        else => error.Unreadable,
    };
}

pub const Times = struct {
    write_time: u64,
    size: u64,
};

pub fn times(path: [:0]const u16) ?Times {
    var data: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    if (win32.GetFileAttributesExW(path.ptr, win32.GET_FILE_EX_INFO_STANDARD, &data) == 0) return null;
    return .{ .write_time = data.ftLastWriteTime.toU64(), .size = (@as(u64, data.nFileSizeHigh) << 32) | data.nFileSizeLow };
}

/// The file's stamp as the inventory reports it (see inventory.formatStamp).
pub fn stampText(buffer: []u8, path: [:0]const u16) []const u8 {
    const found = times(path) orelse return "";
    return inventory.formatStamp(buffer, true, found.write_time, found.size);
}

/// Replaces the file's content in one step, creating its folder when needed. An elevated caller
/// passes no_reparse, as rgbctrl reads files while elevated (see safe_open.ReplaceOptions).
pub fn writeText(path: [:0]const u16, content: []const u8, no_reparse: bool) safe_open.Error!void {
    var folder = platform.PathBuffer{};
    if (folder.set(platform.directoryOf(path))) _ = platform.ensureDirectory(folder.terminated());
    try safe_open.replaceContents(path, content, .{ .no_reparse = no_reparse });
}

/// Whether an rgbctrl instance (run, apply or list) holds the instance lock.
pub fn instanceRunning() bool {
    const mutex = win32.OpenMutexW(win32.SYNCHRONIZE, win32.FALSE, win32.L("Global\\rgbctrl.instance")) orelse return win32.GetLastError() == win32.ERROR_ACCESS_DENIED;
    _ = win32.CloseHandle(mutex);
    return true;
}

pub fn defaultUserConfig(out: *platform.PathBuffer) bool {
    return platform.knownFolder(&platform.folder_local_app_data, out) and out.append(win32.L("rgbctrl")) and out.append(win32.L("rgbctrl.json"));
}

pub fn baseConfig(out: *platform.PathBuffer) bool {
    return baseFolder(out) and out.append(win32.L("rgbctrl.json"));
}

pub fn baseFolder(out: *platform.PathBuffer) bool {
    return platform.knownFolder(&platform.folder_program_data, out) and out.append(win32.L("rgbctrl"));
}

pub const InventorySearch = struct {
    /// The write time and size of the inventory chosen, whose path is in the output buffer.
    found: ?Times = null,
    /// An elevated rgbctrl-gui passed over an inventory that other accounts can change.
    skipped_untrusted: bool = false,
};

/// The newest inventory among the folders a resident rgbctrl writes it to (next to its log):
/// the folder of rgbctrl-gui.exe, which is installed next to rgbctrl.exe, the default install
/// folder, and %LOCALAPPDATA%\rgbctrl for an unelevated rgbctrl that cannot write next to itself.
/// Save writes to the settings file an inventory names, so an elevated rgbctrl-gui only takes one
/// that only administrators can change, as an rgbctrl running elevated or as SYSTEM writes it.
pub fn findInventory(out: *platform.PathBuffer, elevated: bool) InventorySearch {
    var candidates: [3]platform.PathBuffer = .{ .{}, .{}, .{} };
    var exe = platform.PathBuffer{};
    const have = [3]bool{
        platform.executablePath(&exe) and candidates[0].set(platform.directoryOf(exe.slice())),
        platform.knownFolder(&platform.folder_program_files, &candidates[1]) and candidates[1].append(win32.L("rgbctrl")),
        platform.knownFolder(&platform.folder_local_app_data, &candidates[2]) and candidates[2].append(win32.L("rgbctrl")),
    };
    var scratch = std.heap.ArenaAllocator.init(heap.allocator);
    defer scratch.deinit();
    var search = InventorySearch{};
    for (&candidates, have) |*candidate, usable| {
        if (!usable or !candidate.append(win32.L(inventory.file_name))) continue;
        const found = times(candidate.terminated()) orelse continue;
        if (elevated and !(install_check.adminOnlyFile(scratch.allocator(), candidate.slice()) catch false)) {
            search.skipped_untrusted = true;
            continue;
        }
        if (search.found == null or found.write_time > search.found.?.write_time) {
            search.found = found;
            _ = out.set(candidate.slice());
        }
    }
    return search;
}

test "a missing file reads as null and an existing one as its content" {
    var path = platform.PathBuffer{};
    try std.testing.expect(platform.knownFolder(&platform.folder_local_app_data, &path));
    _ = path.append(win32.L("rgbctrl-gui-files-test.json"));
    const terminated = path.terminated();
    _ = win32.DeleteFileW(terminated.ptr);
    defer _ = win32.DeleteFileW(terminated.ptr);
    try std.testing.expect((try readText(std.testing.allocator, terminated)) == null);
    try writeText(terminated, "{ \"a\": 1 }", false);
    const content = (try readText(std.testing.allocator, terminated)).?;
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("{ \"a\": 1 }", content);
    var stamp_buffer: [48]u8 = undefined;
    const stamp = stampText(&stamp_buffer, terminated);
    try std.testing.expect(std.mem.endsWith(u8, stamp, ":10"));
}
