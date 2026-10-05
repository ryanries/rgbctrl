const std = @import("std");
const formatting = @import("../diag/format.zig");
const sdk = @import("sdk");
const acl_policy = @import("acl_policy.zig");

const win32 = sdk.win32;

extern "kernel32" fn GetFullPathNameW(name: [*:0]const u16, length: u32, buffer: [*]u16, file_part: ?*?[*:0]u16) callconv(.winapi) u32;

pub const Error = error{ NotFound, AccessDenied, SharingViolation, NotDisk, ReparsePoint, HardLinked, NotFixedDrive, PathMismatch, TooLarge, ReadFailed, WriteFailed, NotAdminOnly, PathTooLong, Failed, OutOfMemory };

pub fn describe(err: Error) []const u8 {
    return switch (err) {
        error.NotFound => "file not found",
        error.AccessDenied => "access denied",
        error.SharingViolation => "file is locked by another process",
        error.NotDisk => "not a regular disk file",
        error.ReparsePoint => "file is a reparse point (symbolic link or junction)",
        error.HardLinked => "file has more than one hard link",
        error.NotFixedDrive => "file is not on a fixed local drive",
        error.PathMismatch => "the opened file resolves to a different path",
        error.TooLarge => "file is larger than 1 MiB",
        error.ReadFailed => "read failed",
        error.WriteFailed => "write failed",
        error.NotAdminOnly => "the new file would not be admin-only, because of the access rules of its folder",
        error.PathTooLong => "path is too long",
        error.Failed => "could not open the file",
        error.OutOfMemory => "out of memory",
    };
}

fn openError() Error {
    return switch (win32.GetLastError()) {
        win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND => error.NotFound,
        win32.ERROR_ACCESS_DENIED => error.AccessDenied,
        win32.ERROR_SHARING_VIOLATION => error.SharingViolation,
        else => error.Failed,
    };
}

pub fn checkPlainFile(handle: win32.HANDLE) Error!win32.BY_HANDLE_FILE_INFORMATION {
    if (win32.GetFileType(handle) != win32.FILE_TYPE_DISK) return error.NotDisk;
    var information: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(handle, &information) == 0) return error.Failed;
    if (information.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return error.ReparsePoint;
    if (information.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) return error.NotDisk;
    if (information.nNumberOfLinks != 1) return error.HardLinked;
    return information;
}

pub fn openAppend(path: [*:0]const u16) Error!win32.HANDLE {
    const access = win32.FILE_APPEND_DATA | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE;
    const handle = win32.CreateFileW(path, access, win32.FILE_SHARE_READ | win32.FILE_SHARE_DELETE, null, win32.OPEN_ALWAYS, win32.FILE_ATTRIBUTE_NORMAL | win32.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (!win32.isValid(handle)) return openError();
    errdefer _ = win32.CloseHandle(handle);
    _ = try checkPlainFile(handle);
    return handle;
}

fn fullPath(buffer: []u16, path: [*:0]const u16) Error![:0]const u16 {
    const length = GetFullPathNameW(path, @intCast(buffer.len), buffer.ptr, null);
    if (length == 0) return error.Failed;
    if (length >= buffer.len) return error.PathTooLong;
    return buffer[0..length :0];
}

const file_name_opened: u32 = 0x8;

fn finalPathMatches(handle: win32.HANDLE, expected_full_path: []const u16) Error!void {
    var buffer: [1024]u16 = undefined;
    // Opened name, not normalized: OBJ_DONT_REPARSE already blocks redirection, so only 8.3 or case spellings differ.
    const length = win32.GetFinalPathNameByHandleW(handle, &buffer, buffer.len, file_name_opened | win32.VOLUME_NAME_DOS);
    if (length == 0) return error.Failed;
    if (length >= buffer.len) return error.PathTooLong;
    var final_path: []const u16 = buffer[0..length];
    const long_prefix = win32.L("\\\\?\\");
    if (std.mem.startsWith(u16, final_path, long_prefix)) final_path = final_path[long_prefix.len..];
    if (!equalIgnoreCase(final_path, expected_full_path)) return error.PathMismatch;
}

fn equalIgnoreCase(first: []const u16, second: []const u16) bool {
    if (first.len != second.len) return false;
    for (first, second) |a, b| {
        if (upper(a) != upper(b)) return false;
    }
    return true;
}

fn upper(unit: u16) u16 {
    return if (unit >= 'a' and unit <= 'z') unit - 32 else unit;
}

fn driveIsFixed(full_path: []const u16) bool {
    if (full_path.len < 3 or full_path[1] != ':' or full_path[2] != '\\') return false;
    var root = [_:0]u16{ full_path[0], ':', '\\' };
    return win32.GetDriveTypeW(&root) == win32.DRIVE_FIXED;
}

pub fn readAll(allocator: std.mem.Allocator, handle: win32.HANDLE, max_bytes: usize) Error![]u8 {
    var size: i64 = 0;
    if (win32.GetFileSizeEx(handle, &size) == 0) return error.ReadFailed;
    if (size < 0 or size > max_bytes) return error.TooLarge;
    const buffer = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buffer);
    var total: usize = 0;
    while (total < buffer.len) {
        var read: u32 = 0;
        if (win32.ReadFile(handle, buffer[total..].ptr, @intCast(buffer.len - total), &read, null) == 0) return error.ReadFailed;
        if (read == 0) break;
        total += read;
    }
    return buffer[0..total];
}

const OpenedFile = struct {
    handle: win32.HANDLE,

    pub fn close(self: OpenedFile) void {
        _ = win32.CloseHandle(self.handle);
    }
};

extern "kernel32" fn QueryDosDeviceW(device: [*:0]const u16, target: [*]u16, length: u32) callconv(.winapi) u32;
extern "ntdll" fn NtCreateFile(file: *win32.HANDLE, access: u32, attributes: *ObjectAttributes, status: *win32.IO_STATUS_BLOCK, allocation_size: ?*i64, file_attributes: u32, share_access: u32, disposition: u32, options: u32, extended_attributes: ?*anyopaque, extended_length: u32) callconv(.winapi) win32.NTSTATUS;

const UnicodeString = extern struct {
    length: u16,
    maximum_length: u16,
    buffer: [*]u16,
};

const ObjectAttributes = extern struct {
    length: u32 = @sizeOf(ObjectAttributes),
    root_directory: ?win32.HANDLE = null,
    object_name: *UnicodeString,
    attributes: u32,
    security_descriptor: ?*anyopaque = null,
    security_quality_of_service: ?*anyopaque = null,
};

const obj_case_insensitive: u32 = 0x40;
const obj_dont_reparse: u32 = 0x1000;
const file_open_disposition: u32 = 1;
const file_non_directory_file: u32 = 0x40;
const file_synchronous_io_nonalert: u32 = 0x20;
const file_open_reparse_point: u32 = 0x00200000;
const status_object_name_not_found: u32 = 0xC0000034;
const status_object_path_not_found: u32 = 0xC000003A;
const status_access_denied: u32 = 0xC0000022;
const status_sharing_violation: u32 = 0xC0000043;
const status_reparse_point_encountered: u32 = 0xC000050B;
const status_file_is_a_directory: u32 = 0xC00000BA;

fn statusError(status: win32.NTSTATUS) Error {
    return switch (@as(u32, @bitCast(status))) {
        status_object_name_not_found, status_object_path_not_found => error.NotFound,
        status_access_denied => error.AccessDenied,
        status_sharing_violation => error.SharingViolation,
        status_reparse_point_encountered => error.ReparsePoint,
        status_file_is_a_directory => error.NotDisk,
        else => error.Failed,
    };
}

fn devicePath(buffer: []u16, full: []const u16) Error![]u16 {
    var drive = [_:0]u16{ full[0], ':' };
    const written = QueryDosDeviceW(&drive, buffer.ptr, @intCast(buffer.len));
    if (written == 0) return error.Failed;
    const device = std.mem.sliceTo(buffer[0..written], 0);
    const rest = full[2..];
    if (device.len + rest.len > buffer.len) return error.PathTooLong;
    @memcpy(buffer[device.len .. device.len + rest.len], rest);
    return buffer[0 .. device.len + rest.len];
}

fn openWithoutReparse(full: [:0]const u16, access: u32) Error!win32.HANDLE {
    if (!driveIsFixed(full)) return error.NotFixedDrive;
    var device_buffer: [1100]u16 = undefined;
    const device = try devicePath(&device_buffer, full);
    if (device.len * 2 > std.math.maxInt(u16)) return error.PathTooLong;
    var name = UnicodeString{ .length = @intCast(device.len * 2), .maximum_length = @intCast(device.len * 2), .buffer = device.ptr };
    var attributes = ObjectAttributes{ .object_name = &name, .attributes = obj_case_insensitive | obj_dont_reparse };
    var status_block = win32.IO_STATUS_BLOCK{};
    var handle: win32.HANDLE = undefined;
    const status = NtCreateFile(&handle, access | win32.SYNCHRONIZE, &attributes, &status_block, null, 0, win32.FILE_SHARE_READ, file_open_disposition, file_non_directory_file | file_synchronous_io_nonalert | file_open_reparse_point, null, 0);
    if (status != 0) return statusError(status);
    return handle;
}

pub fn openUntrusted(path: [*:0]const u16) Error!OpenedFile {
    var full_buffer: [1024]u16 = undefined;
    const full = try fullPath(&full_buffer, path);
    const handle = try openWithoutReparse(full, win32.GENERIC_READ);
    errdefer _ = win32.CloseHandle(handle);
    _ = try checkPlainFile(handle);
    try finalPathMatches(handle, full);
    return .{ .handle = handle };
}

const Stamp = struct {
    exists: bool = false,
    write_time: u64 = 0,
    size: u64 = 0,
};

pub fn stampUntrusted(path: [*:0]const u16) Stamp {
    var full_buffer: [1024]u16 = undefined;
    const full = fullPath(&full_buffer, path) catch return .{};
    const handle = openWithoutReparse(full, win32.FILE_READ_ATTRIBUTES) catch return .{};
    defer _ = win32.CloseHandle(handle);
    var information: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(handle, &information) == 0) return .{};
    return .{ .exists = true, .write_time = information.ftLastWriteTime.toU64(), .size = (@as(u64, information.nFileSizeHigh) << 32) | information.nFileSizeLow };
}

pub fn openPlain(path: [*:0]const u16) Error!OpenedFile {
    const handle = win32.CreateFileW(path, win32.GENERIC_READ, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (!win32.isValid(handle)) return openError();
    return .{ .handle = handle };
}

extern "kernel32" fn FlushFileBuffers(file: win32.HANDLE) callconv(.winapi) win32.BOOL;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "advapi32" fn SetSecurityInfo(handle: win32.HANDLE, object_type: u32, info: u32, owner: ?win32.PSID, group: ?win32.PSID, dacl: ?*win32.ACL, sacl: ?*win32.ACL) callconv(.winapi) u32;
extern "ntdll" fn NtSetInformationFile(file: win32.HANDLE, status: *win32.IO_STATUS_BLOCK, information: *const anyopaque, length: u32, class: u32) callconv(.winapi) win32.NTSTATUS;

const file_list_directory: u32 = 0x1;
const file_traverse: u32 = 0x20;
const file_create_disposition: u32 = 2;
const file_directory_file: u32 = 0x1;
const file_rename_information: u32 = 10;
const file_disposition_information: u32 = 13;
const status_object_name_collision: u32 = 0xC0000035;

pub const ReplaceOptions = struct {
    /// Refuses a reparse point anywhere in the folder's path, as rgbctrl does for the files it
    /// reads while elevated, and so needs a fixed local drive. Without it the folder's path may
    /// lead through junctions, such as a relocated AppData folder.
    no_reparse: bool = false,
    /// The new file must be admin-only: BUILTIN\Administrators becomes its owner, and it must
    /// pass the checks rgbctrl applies to its base configuration before it replaces the old file.
    admin_only: bool = false,
};

var temporary_counter = std.atomic.Value(u32).init(0);

/// Replaces the file at path with content, so a reader sees either the old or the new file. The
/// content goes to a new file with a name of its own in the same folder, created through a handle
/// to the folder, and that file is renamed over path through its handle: nothing can swap either
/// file in between, and a link at path is replaced rather than written through.
pub fn replaceContents(path: [:0]const u16, content: []const u8, options: ReplaceOptions) Error!void {
    var full_buffer: [1024]u16 = undefined;
    const full = try fullPath(&full_buffer, path.ptr);
    const separator = std.mem.lastIndexOfScalar(u16, full, '\\') orelse return error.Failed;
    const leaf = full[separator + 1 ..];
    if (leaf.len == 0) return error.Failed;
    var directory_buffer: [1024]u16 = undefined;
    // A file in a drive's root keeps the backslash of its folder: "C:\".
    const directory_length = if (separator == 2 and full[1] == ':') separator + 1 else separator;
    @memcpy(directory_buffer[0..directory_length], full[0..directory_length]);
    directory_buffer[directory_length] = 0;
    const folder = try openFolder(directory_buffer[0..directory_length :0], options.no_reparse);
    defer _ = win32.CloseHandle(folder);
    const temporary = try createTemporary(folder, leaf, options.admin_only);
    var renamed = false;
    defer {
        if (!renamed) deleteByHandle(temporary);
        _ = win32.CloseHandle(temporary);
    }
    _ = try checkPlainFile(temporary);
    var total: usize = 0;
    while (total < content.len) {
        var written: u32 = 0;
        const chunk: u32 = @intCast(@min(content.len - total, 1 << 20));
        if (win32.WriteFile(temporary, content[total..].ptr, chunk, &written, null) == 0 or written == 0) return error.WriteFailed;
        total += written;
    }
    if (FlushFileBuffers(temporary) == 0) return error.WriteFailed;
    if (options.admin_only) try makeAdminOnly(temporary);
    try renameByHandle(temporary, folder, leaf);
    renamed = true;
}

fn openFolder(directory: [:0]const u16, no_reparse: bool) Error!win32.HANDLE {
    const access = file_list_directory | file_traverse | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE;
    // Without FILE_SHARE_DELETE nobody can rename or delete the folder while it is in use.
    const share = win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE;
    const handle = if (!no_reparse) blk: {
        const opened = win32.CreateFileW(directory.ptr, access, share, null, win32.OPEN_EXISTING, win32.FILE_FLAG_BACKUP_SEMANTICS, null);
        if (!win32.isValid(opened)) return openError();
        break :blk opened;
    } else blk: {
        if (!driveIsFixed(directory)) return error.NotFixedDrive;
        var device_buffer: [1100]u16 = undefined;
        const device = try devicePath(&device_buffer, directory);
        if (device.len * 2 > std.math.maxInt(u16)) return error.PathTooLong;
        var name = UnicodeString{ .length = @intCast(device.len * 2), .maximum_length = @intCast(device.len * 2), .buffer = device.ptr };
        var attributes = ObjectAttributes{ .object_name = &name, .attributes = obj_case_insensitive | obj_dont_reparse };
        var status_block = win32.IO_STATUS_BLOCK{};
        var opened: win32.HANDLE = undefined;
        const status = NtCreateFile(&opened, access, &attributes, &status_block, null, 0, share, file_open_disposition, file_directory_file | file_synchronous_io_nonalert, null, 0);
        if (status != 0) return statusError(status);
        break :blk opened;
    };
    errdefer _ = win32.CloseHandle(handle);
    var information: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(handle, &information) == 0) return error.Failed;
    if (information.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotDisk;
    if (no_reparse and information.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return error.ReparsePoint;
    return handle;
}

/// "<leaf>.<process id>-<counter>.tmp", created new in the folder.
fn createTemporary(folder: win32.HANDLE, leaf: []const u16, admin_only: bool) Error!win32.HANDLE {
    const access = win32.GENERIC_WRITE | win32.DELETE | win32.READ_CONTROL | win32.FILE_READ_ATTRIBUTES | win32.SYNCHRONIZE | (if (admin_only) win32.WRITE_OWNER else 0);
    var attempt: u32 = 0;
    while (attempt < 8) : (attempt += 1) {
        var suffix_buffer: [32]u8 = undefined;
        const suffix = formatting.bufPrint(&suffix_buffer, ".{x}-{x}.tmp", .{ GetCurrentProcessId(), temporary_counter.fetchAdd(1, .monotonic) }) catch return error.Failed;
        var name_buffer: [300]u16 = undefined;
        if (leaf.len + suffix.len > name_buffer.len) return error.PathTooLong;
        @memcpy(name_buffer[0..leaf.len], leaf);
        for (suffix, name_buffer[leaf.len..][0..suffix.len]) |char, *unit| unit.* = char;
        const length = leaf.len + suffix.len;
        var name = UnicodeString{ .length = @intCast(length * 2), .maximum_length = @intCast(length * 2), .buffer = &name_buffer };
        var attributes = ObjectAttributes{ .root_directory = folder, .object_name = &name, .attributes = obj_case_insensitive | obj_dont_reparse };
        var status_block = win32.IO_STATUS_BLOCK{};
        var handle: win32.HANDLE = undefined;
        const status = NtCreateFile(&handle, access, &attributes, &status_block, null, win32.FILE_ATTRIBUTE_NORMAL, 0, file_create_disposition, file_non_directory_file | file_synchronous_io_nonalert, null, 0);
        if (status == 0) return handle;
        if (@as(u32, @bitCast(status)) != status_object_name_collision) return statusError(status);
    }
    return error.Failed;
}

fn makeAdminOnly(handle: win32.HANDLE) Error!void {
    var sid_buffer: [win32.SECURITY_MAX_SID_SIZE]u8 align(4) = undefined;
    var sid_size: u32 = sid_buffer.len;
    if (win32.CreateWellKnownSid(win32.WIN_BUILTIN_ADMINISTRATORS_SID, null, @ptrCast(&sid_buffer), &sid_size) == 0) return error.Failed;
    if (SetSecurityInfo(handle, win32.SE_FILE_OBJECT, win32.OWNER_SECURITY_INFORMATION, @ptrCast(&sid_buffer), null, null, null) != win32.ERROR_SUCCESS) return error.AccessDenied;
    var owner: ?win32.PSID = null;
    var dacl: ?*win32.ACL = null;
    var descriptor: ?*anyopaque = null;
    if (win32.GetSecurityInfo(handle, win32.SE_FILE_OBJECT, win32.OWNER_SECURITY_INFORMATION | win32.DACL_SECURITY_INFORMATION, &owner, null, &dacl, null, &descriptor) != win32.ERROR_SUCCESS) return error.Failed;
    defer _ = win32.LocalFree(descriptor);
    if (acl_policy.evaluate(owner, dacl, .file) != .none) return error.NotAdminOnly;
}

const RenameInformation = extern struct {
    replace_if_exists: u32,
    root_directory: ?win32.HANDLE,
    file_name_length: u32,
    file_name: [260]u16,
};

fn renameByHandle(handle: win32.HANDLE, folder: win32.HANDLE, leaf: []const u16) Error!void {
    var information = RenameInformation{ .replace_if_exists = 1, .root_directory = folder, .file_name_length = @intCast(leaf.len * 2), .file_name = undefined };
    if (leaf.len > information.file_name.len) return error.PathTooLong;
    @memcpy(information.file_name[0..leaf.len], leaf);
    const length: u32 = @intCast(@offsetOf(RenameInformation, "file_name") + leaf.len * 2);
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        var status_block = win32.IO_STATUS_BLOCK{};
        const status = NtSetInformationFile(handle, &status_block, &information, length, file_rename_information);
        if (status == 0) return;
        const err = statusError(status);
        // A reader that opened the old file without sharing deletion holds it only for a moment.
        if ((err == error.AccessDenied or err == error.SharingViolation) and attempt < 5) {
            win32.Sleep(40);
            continue;
        }
        return err;
    }
}

fn deleteByHandle(handle: win32.HANDLE) void {
    const delete_file: u8 = 1;
    var status_block = win32.IO_STATUS_BLOCK{};
    _ = NtSetInformationFile(handle, &status_block, &delete_file, 1, file_disposition_information);
}

const testing = std.testing;

fn temporaryPath(buffer: []u16, name: []const u8) ![:0]const u16 {
    var directory: [512]u16 = undefined;
    const length = win32.GetEnvironmentVariableW(win32.L("TEMP"), &directory, directory.len);
    if (length == 0 or length >= directory.len) return error.SkipZigTest;
    var directory_utf8: [1024]u8 = undefined;
    var joined_buffer: [1200]u8 = undefined;
    const joined = try formatting.bufPrint(&joined_buffer, "{s}\\{s}", .{ sdk.text.utf16ToUtf8(&directory_utf8, directory[0..length]), name });
    return sdk.text.utf8ToUtf16(buffer, joined) orelse error.SkipZigTest;
}

test "openUntrusted reads a plain file and openAppend appends to it" {
    var path_buffer: [600]u16 = undefined;
    const path = try temporaryPath(&path_buffer, "rgbctrl_safe_open_test.txt");
    _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    const appender = try openAppend(path.ptr);
    var written: u32 = 0;
    _ = win32.WriteFile(appender, "hello", 5, &written, null);
    _ = win32.CloseHandle(appender);
    const opened = try openUntrusted(path.ptr);
    defer opened.close();
    const content = try readAll(testing.allocator, opened.handle, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("hello", content);
}

fn expectFileContent(path: [:0]const u16, expected: []const u8) !void {
    const opened = try openUntrusted(path.ptr);
    defer opened.close();
    const content = try readAll(testing.allocator, opened.handle, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(expected, content);
}

fn anyFileMatches(pattern: [:0]const u16) bool {
    var data: win32.WIN32_FIND_DATAW = undefined;
    const find = win32.FindFirstFileW(pattern.ptr, &data);
    if (!win32.isValid(find)) return false;
    _ = win32.FindClose(find);
    return true;
}

test "replaceContents creates and replaces a file, and leaves other files and none of its own" {
    var path_buffer: [600]u16 = undefined;
    const path = try temporaryPath(&path_buffer, "rgbctrl_replace_test.json");
    var other_buffer: [600]u16 = undefined;
    const other = try temporaryPath(&other_buffer, "rgbctrl_replace_test.json.tmp");
    var pattern_buffer: [600]u16 = undefined;
    const own_temporaries = try temporaryPath(&pattern_buffer, "rgbctrl_replace_test.json.*-*.tmp");
    _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    try createFileWithContent(other, "another program's file");
    defer _ = win32.DeleteFileW(other.ptr);
    try replaceContents(path, "{ \"first\": 1 }", .{});
    try expectFileContent(path, "{ \"first\": 1 }");
    try replaceContents(path, "{}", .{ .no_reparse = true });
    try expectFileContent(path, "{}");
    try expectFileContent(other, "another program's file");
    try testing.expect(!anyFileMatches(own_temporaries));
}

test "an admin-only replacement that other accounts could change is refused and the old file stays" {
    var path_buffer: [600]u16 = undefined;
    const path = try temporaryPath(&path_buffer, "rgbctrl_replace_admin_test.json");
    var pattern_buffer: [600]u16 = undefined;
    const own_temporaries = try temporaryPath(&pattern_buffer, "rgbctrl_replace_admin_test.json.*-*.tmp");
    try createFileWithContent(path, "old");
    defer _ = win32.DeleteFileW(path.ptr);
    // Elevated, the owner changes but TEMP lets its user change the new file; unelevated, the
    // owner cannot change.
    if (replaceContents(path, "new", .{ .admin_only = true })) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try testing.expect(err == error.NotAdminOnly or err == error.AccessDenied);
    }
    try expectFileContent(path, "old");
    try testing.expect(!anyFileMatches(own_temporaries));
}

test "replaceContents replaces a symbolic link at the path instead of writing through it" {
    var target_buffer: [600]u16 = undefined;
    const target = try temporaryPath(&target_buffer, "rgbctrl_replace_link_target.json");
    var link_buffer: [600]u16 = undefined;
    const link = try temporaryPath(&link_buffer, "rgbctrl_replace_link.json");
    try createFileWithContent(target, "original");
    defer _ = win32.DeleteFileW(target.ptr);
    _ = win32.DeleteFileW(link.ptr);
    if (CreateSymbolicLinkW(link.ptr, target.ptr, 0x2) == 0) return error.SkipZigTest;
    defer _ = win32.DeleteFileW(link.ptr);
    try replaceContents(link, "replaced", .{});
    try expectFileContent(target, "original");
    try expectFileContent(link, "replaced");
}

test "readAll refuses files above the size limit" {
    var path_buffer: [600]u16 = undefined;
    const path = try temporaryPath(&path_buffer, "rgbctrl_safe_open_large.txt");
    _ = win32.DeleteFileW(path.ptr);
    defer _ = win32.DeleteFileW(path.ptr);
    const appender = try openAppend(path.ptr);
    var written: u32 = 0;
    _ = win32.WriteFile(appender, "0123456789", 10, &written, null);
    _ = win32.CloseHandle(appender);
    const opened = try openUntrusted(path.ptr);
    defer opened.close();
    try testing.expectError(error.TooLarge, readAll(testing.allocator, opened.handle, 4));
}

test "equalIgnoreCase compares drive letters and ASCII names without case" {
    try testing.expect(equalIgnoreCase(win32.L("C:\\Users\\A.json"), win32.L("c:\\users\\a.JSON")));
    try testing.expect(!equalIgnoreCase(win32.L("C:\\x"), win32.L("C:\\y")));
}

extern "kernel32" fn CreateHardLinkW(link: [*:0]const u16, existing: [*:0]const u16, security: ?*anyopaque) callconv(.winapi) win32.BOOL;
extern "kernel32" fn CreateSymbolicLinkW(link: [*:0]const u16, target: [*:0]const u16, flags: u32) callconv(.winapi) u8;

fn createFileWithContent(path: [:0]const u16, content: []const u8) !void {
    _ = win32.DeleteFileW(path.ptr);
    const handle = try openAppend(path.ptr);
    defer _ = win32.CloseHandle(handle);
    var written: u32 = 0;
    _ = win32.WriteFile(handle, content.ptr, @intCast(content.len), &written, null);
}

test "a file with a second hard link is refused for reading and appending" {
    var path_buffer: [600]u16 = undefined;
    const path = try temporaryPath(&path_buffer, "rgbctrl_hard_link_source.json");
    var link_buffer: [600]u16 = undefined;
    const link = try temporaryPath(&link_buffer, "rgbctrl_hard_link_alias.json");
    try createFileWithContent(path, "{}");
    defer _ = win32.DeleteFileW(path.ptr);
    _ = win32.DeleteFileW(link.ptr);
    if (CreateHardLinkW(link.ptr, path.ptr, null) == 0) return error.SkipZigTest;
    defer _ = win32.DeleteFileW(link.ptr);
    try testing.expectError(error.HardLinked, openUntrusted(path.ptr));
    try testing.expectError(error.HardLinked, openAppend(link.ptr));
}

test "a symbolic link is refused instead of followed" {
    var target_buffer: [600]u16 = undefined;
    const target = try temporaryPath(&target_buffer, "rgbctrl_symlink_target.json");
    var link_buffer: [600]u16 = undefined;
    const link = try temporaryPath(&link_buffer, "rgbctrl_symlink_alias.json");
    try createFileWithContent(target, "{}");
    defer _ = win32.DeleteFileW(target.ptr);
    _ = win32.DeleteFileW(link.ptr);
    if (CreateSymbolicLinkW(link.ptr, target.ptr, 0x2) == 0) return error.SkipZigTest;
    defer _ = win32.DeleteFileW(link.ptr);
    try testing.expectError(error.ReparsePoint, openUntrusted(link.ptr));
    try testing.expectError(error.ReparsePoint, openAppend(link.ptr));
}

test "network paths and devices are refused" {
    try testing.expectError(error.NotFixedDrive, openUntrusted(win32.L("\\\\localhost\\C$\\Windows\\win.ini")));
    try testing.expectError(error.NotDisk, openAppend(win32.L("\\\\.\\NUL")));
}

extern "kernel32" fn RemoveDirectoryW(path: [*:0]const u16) callconv(.winapi) win32.BOOL;

fn createJunction(link: [:0]const u16, target: []const u16) !void {
    if (win32.CreateDirectoryW(link.ptr, null) == 0) return error.SkipZigTest;
    errdefer _ = RemoveDirectoryW(link.ptr);
    const handle = win32.CreateFileW(link.ptr, win32.GENERIC_WRITE, 0, null, win32.OPEN_EXISTING, win32.FILE_FLAG_OPEN_REPARSE_POINT | win32.FILE_FLAG_BACKUP_SEMANTICS, null);
    if (!win32.isValid(handle)) return error.SkipZigTest;
    defer _ = win32.CloseHandle(handle);
    const prefix = win32.L("\\??\\");
    var names: [600]u16 = undefined;
    @memcpy(names[0..prefix.len], prefix);
    @memcpy(names[prefix.len .. prefix.len + target.len], target);
    const substitute_length = prefix.len + target.len;
    names[substitute_length] = 0;
    names[substitute_length + 1] = 0;
    var buffer: [1400]u8 align(4) = undefined;
    const data_length: u16 = @intCast(8 + (substitute_length + 1) * 2 + 2);
    std.mem.writeInt(u32, buffer[0..4], 0xA0000003, .little);
    std.mem.writeInt(u16, buffer[4..6], data_length, .little);
    std.mem.writeInt(u16, buffer[6..8], 0, .little);
    std.mem.writeInt(u16, buffer[8..10], 0, .little);
    std.mem.writeInt(u16, buffer[10..12], @intCast(substitute_length * 2), .little);
    std.mem.writeInt(u16, buffer[12..14], @intCast((substitute_length + 1) * 2), .little);
    std.mem.writeInt(u16, buffer[14..16], 0, .little);
    @memcpy(buffer[16 .. 16 + (substitute_length + 2) * 2], std.mem.sliceAsBytes(names[0 .. substitute_length + 2]));
    var returned: u32 = 0;
    if (win32.DeviceIoControl(handle, 0x000900A4, &buffer, 8 + @as(u32, data_length), null, 0, &returned, null) == 0) return error.SkipZigTest;
}

test "a junction anywhere in the path is refused without being followed" {
    var target_buffer: [600]u16 = undefined;
    const target = try temporaryPath(&target_buffer, "rgbctrl_junction_target");
    var link_buffer: [600]u16 = undefined;
    const link = try temporaryPath(&link_buffer, "rgbctrl_junction_link");
    var inside_buffer: [700]u16 = undefined;
    var linked_buffer: [700]u16 = undefined;
    const inside_name = win32.L("\\rgbctrl.json");
    @memcpy(inside_buffer[0..target.len], target);
    @memcpy(inside_buffer[target.len .. target.len + inside_name.len], inside_name);
    inside_buffer[target.len + inside_name.len] = 0;
    const inside = inside_buffer[0 .. target.len + inside_name.len :0];
    @memcpy(linked_buffer[0..link.len], link);
    @memcpy(linked_buffer[link.len .. link.len + inside_name.len], inside_name);
    linked_buffer[link.len + inside_name.len] = 0;
    const linked = linked_buffer[0 .. link.len + inside_name.len :0];
    _ = RemoveDirectoryW(link.ptr);
    _ = win32.DeleteFileW(inside.ptr);
    _ = RemoveDirectoryW(target.ptr);
    if (win32.CreateDirectoryW(target.ptr, null) == 0) return error.SkipZigTest;
    defer _ = RemoveDirectoryW(target.ptr);
    try createFileWithContent(inside, "{}");
    defer _ = win32.DeleteFileW(inside.ptr);
    try createJunction(link, target);
    defer _ = RemoveDirectoryW(link.ptr);
    const direct = try openUntrusted(inside.ptr);
    direct.close();
    try testing.expectError(error.ReparsePoint, openUntrusted(linked.ptr));
    try testing.expect(stampUntrusted(linked.ptr).exists == false);
    try testing.expect(stampUntrusted(inside.ptr).exists);
    try testing.expectError(error.ReparsePoint, replaceContents(linked, "strict", .{ .no_reparse = true }));
    try expectFileContent(inside, "{}");
    try replaceContents(linked, "followed", .{});
    try expectFileContent(inside, "followed");
}

extern "kernel32" fn GetShortPathNameW(long_path: [*:0]const u16, short_path: [*]u16, length: u32) callconv(.winapi) u32;

test "openUntrusted accepts a path spelled with 8.3 short names" {
    var directory_buffer: [600]u16 = undefined;
    const directory = try temporaryPath(&directory_buffer, "rgbctrl short name test directory");
    var file_buffer: [700]u16 = undefined;
    const file = try temporaryPath(&file_buffer, "rgbctrl short name test directory\\rgbctrl short name config.json");
    _ = win32.DeleteFileW(file.ptr);
    _ = RemoveDirectoryW(directory.ptr);
    if (win32.CreateDirectoryW(directory.ptr, null) == 0) return error.SkipZigTest;
    defer _ = RemoveDirectoryW(directory.ptr);
    try createFileWithContent(file, "{}");
    defer _ = win32.DeleteFileW(file.ptr);
    var short_buffer: [700]u16 = undefined;
    const length = GetShortPathNameW(file.ptr, &short_buffer, short_buffer.len);
    if (length == 0 or length >= short_buffer.len) return error.SkipZigTest;
    short_buffer[length] = 0;
    const short = short_buffer[0..length :0];
    if (std.mem.eql(u16, short, file)) return error.SkipZigTest;
    const opened = try openUntrusted(short.ptr);
    defer opened.close();
    const content = try readAll(testing.allocator, opened.handle, 1024);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("{}", content);
    try testing.expect(stampUntrusted(short.ptr).exists);
}
