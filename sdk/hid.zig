const std = @import("std");
const win32 = @import("win32.zig");

pub const Info = struct {
    vendor_id: u16,
    product_id: u16,
    version: u16,
    usage_page: u16,
    usage: u16,
    input_length: u16,
    output_length: u16,
    feature_length: u16,
};

pub const OpenError = error{ NotFound, AccessDenied, SharingViolation, Failed };
pub const IoError = error{ Timeout, Disconnected, Failed };

pub const hid_interface_guid = win32.GUID{ .data1 = 0x4D1E55B2, .data2 = 0xF16F, .data3 = 0x11CF, .data4 = .{ 0x88, 0xCB, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30 } };

const ListSizeFn = *const fn (length: *u32, guid: *const win32.GUID, device_id: ?[*:0]const u16, flags: u32) callconv(.winapi) u32;
const ListFn = *const fn (guid: *const win32.GUID, device_id: ?[*:0]const u16, buffer: [*]u16, length: u32, flags: u32) callconv(.winapi) u32;

const ConfigManager = struct {
    list_size: ListSizeFn,
    list: ListFn,
};

var config_manager: ?ConfigManager = null;

fn configManager() ?ConfigManager {
    if (config_manager) |functions| return functions;
    const module = win32.LoadLibraryExW(win32.L("cfgmgr32.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return null;
    const size_address = win32.GetProcAddress(module, "CM_Get_Device_Interface_List_SizeW") orelse return null;
    const list_address = win32.GetProcAddress(module, "CM_Get_Device_Interface_ListW") orelse return null;
    config_manager = .{ .list_size = @ptrCast(size_address), .list = @ptrCast(list_address) };
    return config_manager;
}

pub const InterfaceList = struct {
    buffer: []u16,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) error{ OutOfMemory, Failed }!InterfaceList {
        const functions = configManager() orelse return error.Failed;
        var attempt: usize = 0;
        while (attempt < 4) : (attempt += 1) {
            var length: u32 = 0;
            if (functions.list_size(&length, &hid_interface_guid, null, win32.CM_GET_DEVICE_INTERFACE_LIST_PRESENT) != win32.CR_SUCCESS) return error.Failed;
            if (length == 0) length = 1;
            const buffer = try allocator.alloc(u16, length);
            @memset(buffer, 0);
            const result = functions.list(&hid_interface_guid, null, buffer.ptr, length, win32.CM_GET_DEVICE_INTERFACE_LIST_PRESENT);
            if (result == win32.CR_SUCCESS) return .{ .buffer = buffer, .allocator = allocator };
            allocator.free(buffer);
        }
        return error.Failed;
    }

    pub fn deinit(self: *InterfaceList) void {
        self.allocator.free(self.buffer);
        self.* = undefined;
    }

    pub fn contents(self: *const InterfaceList) []const u16 {
        return listContents(self.buffer);
    }

    pub fn iterator(self: *const InterfaceList) Iterator {
        return .{ .buffer = self.buffer, .position = 0 };
    }

    pub const Iterator = struct {
        buffer: []const u16,
        position: usize,

        pub fn next(self: *Iterator) ?[:0]const u16 {
            if (self.position >= self.buffer.len or self.buffer[self.position] == 0) return null;
            const start = self.position;
            while (self.position < self.buffer.len and self.buffer[self.position] != 0) self.position += 1;
            if (self.position >= self.buffer.len) return null;
            const path = self.buffer[start..self.position :0];
            self.position += 1;
            return path;
        }
    };
};

pub fn listContents(buffer: []const u16) []const u16 {
    for (buffer, 0..) |unit, index| {
        if (unit == 0 and (index == 0 or buffer[index - 1] == 0)) return buffer[0 .. index + 1];
    }
    return buffer;
}

pub fn contentHash(buffer: []const u16) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (buffer) |unit| {
        hash ^= unit & 0xFF;
        hash *%= 0x100000001b3;
        hash ^= unit >> 8;
        hash *%= 0x100000001b3;
    }
    return hash;
}

pub fn queryInfo(path: [*:0]const u16) ?Info {
    const handle = win32.CreateFileW(path, 0, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (!win32.isValid(handle)) return null;
    defer _ = win32.CloseHandle(handle);
    return infoFromHandle(handle);
}

fn infoFromHandle(handle: win32.HANDLE) ?Info {
    var attributes: win32.HIDD_ATTRIBUTES = .{};
    if (win32.HidD_GetAttributes(handle, &attributes) == 0) return null;
    var preparsed: ?*anyopaque = null;
    if (win32.HidD_GetPreparsedData(handle, &preparsed) == 0) return null;
    const data = preparsed orelse return null;
    defer _ = win32.HidD_FreePreparsedData(data);
    var caps: win32.HIDP_CAPS = undefined;
    if (win32.HidP_GetCaps(data, &caps) != win32.HIDP_STATUS_SUCCESS) return null;
    return .{
        .vendor_id = attributes.VendorID,
        .product_id = attributes.ProductID,
        .version = attributes.VersionNumber,
        .usage_page = caps.UsagePage,
        .usage = caps.Usage,
        .input_length = caps.InputReportByteLength,
        .output_length = caps.OutputReportByteLength,
        .feature_length = caps.FeatureReportByteLength,
    };
}

pub const Device = struct {
    handle: win32.HANDLE,
    event: win32.HANDLE,
    info: Info,
    last_error: u32 = 0,

    pub fn open(path: [*:0]const u16, exclusive: bool) OpenError!Device {
        const share: u32 = if (exclusive) 0 else win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE;
        const handle = win32.CreateFileW(path, win32.GENERIC_READ | win32.GENERIC_WRITE, share, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OVERLAPPED, null);
        if (!win32.isValid(handle)) {
            return switch (win32.GetLastError()) {
                win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND, win32.ERROR_DEVICE_NOT_CONNECTED => error.NotFound,
                win32.ERROR_ACCESS_DENIED => error.AccessDenied,
                win32.ERROR_SHARING_VIOLATION => error.SharingViolation,
                else => error.Failed,
            };
        }
        const info = infoFromHandle(handle) orelse {
            _ = win32.CloseHandle(handle);
            return error.Failed;
        };
        const event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse {
            _ = win32.CloseHandle(handle);
            return error.Failed;
        };
        return .{ .handle = handle, .event = event, .info = info };
    }

    pub fn close(self: *Device) void {
        _ = win32.CancelIoEx(self.handle, null);
        _ = win32.CloseHandle(self.handle);
        _ = win32.CloseHandle(self.event);
        self.* = undefined;
    }

    pub fn write(self: *Device, report: []const u8, timeout_ms: u32) IoError!void {
        var overlapped: win32.OVERLAPPED = .{ .hEvent = self.event };
        _ = win32.ResetEvent(self.event);
        if (win32.WriteFile(self.handle, report.ptr, @intCast(report.len), null, &overlapped) == 0) {
            const code = win32.GetLastError();
            if (code != win32.ERROR_IO_PENDING) return self.fail(code);
        }
        _ = try self.complete(&overlapped, timeout_ms);
    }

    pub fn read(self: *Device, buffer: []u8, timeout_ms: u32) IoError!usize {
        var overlapped: win32.OVERLAPPED = .{ .hEvent = self.event };
        _ = win32.ResetEvent(self.event);
        if (win32.ReadFile(self.handle, buffer.ptr, @intCast(buffer.len), null, &overlapped) == 0) {
            const code = win32.GetLastError();
            if (code != win32.ERROR_IO_PENDING) return self.fail(code);
        }
        return self.complete(&overlapped, timeout_ms);
    }

    pub fn getFeature(self: *Device, buffer: []u8, timeout_ms: u32) IoError!usize {
        var overlapped: win32.OVERLAPPED = .{ .hEvent = self.event };
        _ = win32.ResetEvent(self.event);
        if (win32.DeviceIoControl(self.handle, win32.IOCTL_HID_GET_FEATURE, buffer.ptr, @intCast(buffer.len), buffer.ptr, @intCast(buffer.len), null, &overlapped) == 0) {
            const code = win32.GetLastError();
            if (code != win32.ERROR_IO_PENDING) return self.fail(code);
        }
        return self.complete(&overlapped, timeout_ms);
    }

    pub fn setFeature(self: *Device, report: []u8) IoError!void {
        if (win32.HidD_SetFeature(self.handle, report.ptr, @intCast(report.len)) == 0) return self.fail(win32.GetLastError());
    }

    pub fn productString(self: *Device, buffer: *[128]u16) []const u16 {
        @memset(buffer, 0);
        if (win32.HidD_GetProductString(self.handle, buffer, @sizeOf([128]u16)) == 0) return &.{};
        return std.mem.sliceTo(buffer, 0);
    }

    fn complete(self: *Device, overlapped: *win32.OVERLAPPED, timeout_ms: u32) IoError!usize {
        var transferred: u32 = 0;
        const wait = win32.WaitForSingleObject(self.event, timeout_ms);
        if (wait == win32.WAIT_TIMEOUT) {
            _ = win32.CancelIoEx(self.handle, overlapped);
            _ = win32.GetOverlappedResult(self.handle, overlapped, &transferred, win32.TRUE);
            self.last_error = win32.ERROR_OPERATION_ABORTED;
            return error.Timeout;
        }
        if (win32.GetOverlappedResult(self.handle, overlapped, &transferred, win32.FALSE) == 0) return self.fail(win32.GetLastError());
        return transferred;
    }

    fn fail(self: *Device, code: u32) IoError {
        self.last_error = code;
        return switch (code) {
            win32.ERROR_DEVICE_NOT_CONNECTED, win32.ERROR_FILE_NOT_FOUND, win32.ERROR_INVALID_HANDLE, 31 => error.Disconnected,
            else => error.Failed,
        };
    }
};

pub fn pathContainsIds(path: []const u16, vendor_id: u16, product_id: u16) bool {
    var needle_buffer: [17]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "vid_{x:0>4}&pid_{x:0>4}", .{ vendor_id, product_id }) catch return false;
    return pathContains(path, needle);
}

/// True when the device path contains `needle`, ignoring ASCII case; `needle` must be lowercase.
/// For example "&mi_01" selects interface 1 of a composite USB device.
pub fn pathContains(path: []const u16, needle: []const u8) bool {
    if (path.len < needle.len) return false;
    var start: usize = 0;
    while (start + needle.len <= path.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |char, offset| {
            const unit = path[start + offset];
            const lowered: u16 = if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
            if (lowered != char) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

test "InterfaceList iterator yields each NUL-terminated path and stops at the double NUL" {
    const units = [_]u16{ 'a', 'b', 0, 'c', 0, 0 };
    var list = InterfaceList{ .buffer = @constCast(&units), .allocator = std.testing.allocator };
    var iterator = list.iterator();
    try std.testing.expectEqualSlices(u16, &.{ 'a', 'b' }, iterator.next().?);
    try std.testing.expectEqualSlices(u16, &.{'c'}, iterator.next().?);
    try std.testing.expect(iterator.next() == null);
}

test "contentHash changes when one interface path is swapped for a different one of equal length" {
    const first = [_]u16{ 'a', 'b', 0, 0 };
    const second = [_]u16{ 'a', 'c', 0, 0 };
    try std.testing.expect(contentHash(&first) != contentHash(&second));
    try std.testing.expectEqual(contentHash(&first), contentHash(&first));
}

test "pathContainsIds matches the VID and PID case-insensitively" {
    const path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_381C&PID_0003#7&abc#{4d1e55b2}");
    try std.testing.expect(pathContainsIds(path, 0x381C, 0x0003));
    try std.testing.expect(!pathContainsIds(path, 0x381C, 0x0004));
}

test "pathContains finds the interface number of a composite device" {
    const path = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\HID#VID_1038&PID_1610&MI_01#8&1a2b3c4d&0&0000#{4d1e55b2}");
    try std.testing.expect(pathContains(path, "&mi_01"));
    try std.testing.expect(!pathContains(path, "&mi_02"));
    try std.testing.expect(!pathContains(std.unicode.utf8ToUtf16LeStringLiteral("&MI_0"), "&mi_01"));
}

test "listContents stops at the double NUL so unused buffer space never changes the hash" {
    const first = [_]u16{ 'a', 0, 'b', 0, 0, 0x1234, 0x5678 };
    const second = [_]u16{ 'a', 0, 'b', 0, 0, 0x9999, 0x0001 };
    try std.testing.expectEqual(@as(usize, 5), listContents(&first).len);
    try std.testing.expectEqual(contentHash(listContents(&first)), contentHash(listContents(&second)));
    const empty = [_]u16{ 0, 0x4444 };
    try std.testing.expectEqual(@as(usize, 1), listContents(&empty).len);
}

test "the built-in HID interface GUID matches the one Windows reports" {
    var guid: win32.GUID = undefined;
    win32.HidD_GetHidGuid(&guid);
    try std.testing.expectEqual(guid.data1, hid_interface_guid.data1);
    try std.testing.expectEqual(guid.data2, hid_interface_guid.data2);
    try std.testing.expectEqual(guid.data3, hid_interface_guid.data3);
    try std.testing.expectEqualSlices(u8, &guid.data4, &hid_interface_guid.data4);
}
