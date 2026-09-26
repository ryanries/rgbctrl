const std = @import("std");
const sdk = @import("sdk");

const win32 = sdk.win32;

extern "shell32" fn SHGetKnownFolderPath(folder: *const win32.GUID, flags: u32, token: ?win32.HANDLE, path: *?[*:0]u16) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(memory: ?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, length: u32, buffer: [*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) u32;

const path_capacity = 1024;

pub const folder_program_data = win32.GUID{ .data1 = 0x62AB5D82, .data2 = 0xFDC1, .data3 = 0x4DC3, .data4 = .{ 0xA9, 0xDD, 0x07, 0x0D, 0x1D, 0x49, 0x5D, 0x97 } };
pub const folder_local_app_data = win32.GUID{ .data1 = 0xF1B32785, .data2 = 0x6FBA, .data3 = 0x4FCF, .data4 = .{ 0x9D, 0x55, 0x7B, 0x8E, 0x7F, 0x15, 0x70, 0x91 } };

pub const PathBuffer = struct {
    buffer: [path_capacity]u16 = undefined,
    len: usize = 0,

    pub fn slice(self: *const PathBuffer) []const u16 {
        return self.buffer[0..self.len];
    }

    pub fn terminated(self: *PathBuffer) [:0]const u16 {
        self.buffer[self.len] = 0;
        return self.buffer[0..self.len :0];
    }

    pub fn set(self: *PathBuffer, value: []const u16) bool {
        if (value.len + 1 > self.buffer.len) return false;
        @memcpy(self.buffer[0..value.len], value);
        self.len = value.len;
        self.buffer[self.len] = 0;
        return true;
    }

    pub fn append(self: *PathBuffer, component: []const u16) bool {
        const needs_separator = self.len > 0 and self.buffer[self.len - 1] != '\\';
        const total = self.len + @intFromBool(needs_separator) + component.len;
        if (total + 1 > self.buffer.len) return false;
        if (needs_separator) {
            self.buffer[self.len] = '\\';
            self.len += 1;
        }
        @memcpy(self.buffer[self.len .. self.len + component.len], component);
        self.len = total;
        self.buffer[self.len] = 0;
        return true;
    }

    pub fn utf8(self: *const PathBuffer, out: []u8) []const u8 {
        return sdk.text.utf16ToUtf8(out, self.slice());
    }
};

pub fn executablePath(out: *PathBuffer) bool {
    const length = win32.GetModuleFileNameW(null, &out.buffer, out.buffer.len);
    if (length == 0 or length >= out.buffer.len) return false;
    out.len = length;
    out.buffer[length] = 0;
    return true;
}

pub fn directoryOf(path: []const u16) []const u16 {
    const separator = std.mem.lastIndexOfScalar(u16, path, '\\') orelse return path;
    return path[0..separator];
}

pub fn knownFolder(folder: *const win32.GUID, out: *PathBuffer) bool {
    var result: ?[*:0]u16 = null;
    if (SHGetKnownFolderPath(folder, 0, null, &result) != 0) {
        CoTaskMemFree(result);
        return false;
    }
    defer CoTaskMemFree(result);
    return out.set(std.mem.span(result.?));
}

pub fn fullPathFromUtf8(text: []const u8, out: *PathBuffer) bool {
    var wide: [path_capacity]u16 = undefined;
    const converted = sdk.text.utf8ToUtf16(&wide, text) orelse return false;
    const length = GetFullPathNameW(converted.ptr, out.buffer.len, &out.buffer, null);
    if (length == 0 or length >= out.buffer.len) return false;
    out.len = length;
    out.buffer[length] = 0;
    return true;
}

pub const Privilege = struct {
    elevated: bool,
    system: bool,
};

pub fn currentPrivilege() Privilege {
    var token: win32.HANDLE = undefined;
    if (win32.OpenProcessToken(win32.GetCurrentProcess(), win32.TOKEN_QUERY, &token) == 0) return .{ .elevated = false, .system = false };
    defer _ = win32.CloseHandle(token);
    var elevation = win32.TOKEN_ELEVATION{};
    var returned: u32 = 0;
    const elevated = win32.GetTokenInformation(token, win32.TOKEN_ELEVATION_CLASS, &elevation, @sizeOf(win32.TOKEN_ELEVATION), &returned) != 0 and elevation.TokenIsElevated != 0;
    var user_buffer: [128]u8 align(8) = undefined;
    var system = false;
    if (win32.GetTokenInformation(token, win32.TOKEN_USER_CLASS, &user_buffer, user_buffer.len, &returned) != 0) {
        const user: *const win32.TOKEN_USER = @ptrCast(&user_buffer);
        if (user.User.Sid) |sid| {
            const bytes: [*]const u8 = @ptrCast(sid);
            system = std.mem.eql(u8, bytes[0..12], &[_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 });
        }
    }
    return .{ .elevated = elevated or system, .system = system };
}

pub fn windowsBuild() u32 {
    var info = win32.RTL_OSVERSIONINFOW{};
    if (win32.RtlGetVersion(&info) != 0) return 0;
    return info.dwBuildNumber;
}

pub fn ensureDirectory(path: [:0]const u16) bool {
    if (win32.CreateDirectoryW(path.ptr, null) != 0) return true;
    return win32.GetLastError() == win32.ERROR_ALREADY_EXISTS;
}

test "PathBuffer appends components with a single separator" {
    var path = PathBuffer{};
    try std.testing.expect(path.set(win32.L("C:\\ProgramData")));
    try std.testing.expect(path.append(win32.L("rgbctrl")));
    try std.testing.expect(path.append(win32.L("rgbctrl.json")));
    try std.testing.expectEqualSlices(u16, win32.L("C:\\ProgramData\\rgbctrl\\rgbctrl.json"), path.slice());
    try std.testing.expectEqualSlices(u16, win32.L("C:\\ProgramData\\rgbctrl"), directoryOf(path.slice()));
}

test "known folders resolve on this machine" {
    var path = PathBuffer{};
    try std.testing.expect(knownFolder(&folder_program_data, &path));
    try std.testing.expect(path.len > 3);
}
