const std = @import("std");
const win32 = @import("win32.zig");

pub const device_path = win32.L("\\\\?\\GLOBALROOT\\Device\\PawnIO");
pub const ioctl_load: u32 = 0xA1B22084;
pub const ioctl_execute: u32 = 0xA1B22104;
pub const ioctl_version: u32 = 0xA1B22184;
pub const max_module_bytes = 256 * 1024;
pub const max_cells = 32;
pub const function_name_bytes = 32;

pub const ModuleId = struct {
    file_name: []const u8,
    sha256: [32]u8,
};

pub const amd_family17 = ModuleId{
    .file_name = "AMDFamily17.bin",
    .sha256 = hexDigest("dae74615761b78bdf064dfb3e136252ddcc6fc727d88f14738d0e5800d427a91"),
};

pub const smbus_piix4 = ModuleId{
    .file_name = "SmbusPIIX4.bin",
    .sha256 = hexDigest("91f9b4b1c39e3d399ce48477a89d8f6bd3e58a2241064a4daec3a1513dff56e5"),
};

pub const OpenError = error{ NotInstalled, AccessDenied, ModuleMissing, ModuleHashMismatch, LoadFailed, OutOfMemory };
pub const ExecuteError = error{ Failed, BadArgument };

pub const Module = struct {
    handle: win32.HANDLE,
    last_status: win32.NTSTATUS = 0,

    pub fn open(allocator: std.mem.Allocator, host_dir: []const u16, id: ModuleId, status_out: *win32.NTSTATUS) OpenError!Module {
        const handle = win32.CreateFileW(device_path, win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
        if (!win32.isValid(handle)) {
            return switch (win32.GetLastError()) {
                win32.ERROR_ACCESS_DENIED => error.AccessDenied,
                else => error.NotInstalled,
            };
        }
        errdefer _ = win32.CloseHandle(handle);
        const blob = try readModule(allocator, host_dir, id);
        defer allocator.free(blob);
        var status_block: win32.IO_STATUS_BLOCK = .{};
        const status = win32.NtDeviceIoControlFile(handle, null, null, null, &status_block, ioctl_load, blob.ptr, @intCast(blob.len), null, 0);
        status_out.* = status;
        if (status != 0) return error.LoadFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: *Module) void {
        _ = win32.CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn execute(self: *Module, name: []const u8, input: []const u64, output: []u64) ExecuteError!void {
        if (name.len >= function_name_bytes or input.len > max_cells or output.len > max_cells) return error.BadArgument;
        var request: [4 + max_cells]u64 = @splat(0);
        const name_bytes = std.mem.sliceAsBytes(request[0..4]);
        @memcpy(name_bytes[0..name.len], name);
        @memcpy(request[4 .. 4 + input.len], input);
        var response: [max_cells]u64 = @splat(0);
        var status_block: win32.IO_STATUS_BLOCK = .{};
        const in_bytes: u32 = @intCast((4 + input.len) * 8);
        const out_bytes: u32 = @intCast(output.len * 8);
        const status = win32.NtDeviceIoControlFile(self.handle, null, null, null, &status_block, ioctl_execute, &request, in_bytes, if (output.len == 0) null else &response, out_bytes);
        self.last_status = status;
        if (status != 0) return error.Failed;
        @memcpy(output, response[0..output.len]);
    }
};

pub fn driverVersion() ?u32 {
    const handle = win32.CreateFileW(device_path, win32.GENERIC_READ | win32.GENERIC_WRITE, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (!win32.isValid(handle)) return null;
    defer _ = win32.CloseHandle(handle);
    var version: u32 = 0;
    var status_block: win32.IO_STATUS_BLOCK = .{};
    const status = win32.NtDeviceIoControlFile(handle, null, null, null, &status_block, ioctl_version, null, 0, &version, @sizeOf(u32));
    if (status != 0) return null;
    return version;
}

pub fn deviceExists() bool {
    const handle = win32.CreateFileW(device_path, 0, win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE, null, win32.OPEN_EXISTING, 0, null);
    if (win32.isValid(handle)) {
        _ = win32.CloseHandle(handle);
        return true;
    }
    return win32.GetLastError() == win32.ERROR_ACCESS_DENIED;
}

fn readModule(allocator: std.mem.Allocator, host_dir: []const u16, id: ModuleId) OpenError![]u8 {
    var path_buffer: [1024]u16 = undefined;
    const path = modulePath(&path_buffer, host_dir, id.file_name) orelse return error.ModuleMissing;
    const file = win32.CreateFileW(path, win32.GENERIC_READ, win32.FILE_SHARE_READ, null, win32.OPEN_EXISTING, win32.FILE_ATTRIBUTE_NORMAL, null);
    if (!win32.isValid(file)) return error.ModuleMissing;
    defer _ = win32.CloseHandle(file);
    var size: i64 = 0;
    if (win32.GetFileSizeEx(file, &size) == 0 or size <= 0 or size > max_module_bytes) return error.ModuleMissing;
    const buffer = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buffer);
    var total: usize = 0;
    while (total < buffer.len) {
        var read: u32 = 0;
        if (win32.ReadFile(file, buffer[total..].ptr, @intCast(buffer.len - total), &read, null) == 0 or read == 0) return error.ModuleMissing;
        total += read;
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(buffer, &digest, .{});
    if (!std.mem.eql(u8, &digest, &id.sha256)) return error.ModuleHashMismatch;
    return buffer;
}

fn modulePath(buffer: []u16, host_dir: []const u16, file_name: []const u8) ?[*:0]const u16 {
    const middle = std.unicode.utf8ToUtf16LeStringLiteral("\\pawnio\\");
    const needed = host_dir.len + middle.len + file_name.len + 1;
    if (needed > buffer.len) return null;
    @memcpy(buffer[0..host_dir.len], host_dir);
    @memcpy(buffer[host_dir.len .. host_dir.len + middle.len], middle);
    for (file_name, 0..) |char, index| buffer[host_dir.len + middle.len + index] = char;
    buffer[needed - 1] = 0;
    return buffer[0 .. needed - 1 :0];
}

pub const InteropMutex = struct {
    handle: ?win32.HANDLE,

    pub fn open(name: [*:0]const u16) InteropMutex {
        if (win32.CreateMutexW(null, win32.FALSE, name)) |handle| return .{ .handle = handle };
        return .{ .handle = win32.OpenMutexW(win32.SYNCHRONIZE | 0x0001, win32.FALSE, name) };
    }

    pub fn isUsable(self: InteropMutex) bool {
        return self.handle != null;
    }

    pub fn acquire(self: InteropMutex, timeout_ms: u32) bool {
        const handle = self.handle orelse return false;
        const result = win32.WaitForSingleObject(handle, timeout_ms);
        return result == win32.WAIT_OBJECT_0 or result == win32.WAIT_ABANDONED;
    }

    pub fn release(self: InteropMutex) void {
        if (self.handle) |handle| _ = win32.ReleaseMutex(handle);
    }

    pub fn close(self: *InteropMutex) void {
        if (self.handle) |handle| _ = win32.CloseHandle(handle);
        self.handle = null;
    }
};

pub const smbus_mutex_name = win32.L("Global\\Access_SMBUS.HTP.Method");
pub const pci_mutex_name = win32.L("Global\\Access_PCI");

fn hexDigest(comptime text: []const u8) [32]u8 {
    @setEvalBranchQuota(10000);
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, text) catch unreachable;
    return digest;
}

pub fn describeOpenError(err: OpenError) []const u8 {
    return switch (err) {
        error.NotInstalled => "PawnIO driver not installed (winget install namazso.PawnIO)",
        error.AccessDenied => "PawnIO requires rgbctrl to run elevated (administrator or SYSTEM)",
        error.ModuleMissing => "PawnIO module file missing from the pawnio folder next to rgbctrl.exe",
        error.ModuleHashMismatch => "PawnIO module file does not match the pinned SHA-256",
        error.LoadFailed => "PawnIO rejected the module (wrong hardware or signature)",
        error.OutOfMemory => "out of memory reading the PawnIO module",
    };
}

test "modulePath joins the host directory, the pawnio folder and the file name" {
    var buffer: [64]u16 = undefined;
    const dir = std.unicode.utf8ToUtf16LeStringLiteral("C:\\x");
    const path = modulePath(&buffer, dir, "A.bin").?;
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\x\\pawnio\\A.bin"), std.mem.span(path));
}

test "module digests decode to the pinned bytes" {
    try std.testing.expectEqual(@as(u8, 0xda), amd_family17.sha256[0]);
    try std.testing.expectEqual(@as(u8, 0x91), amd_family17.sha256[31]);
    try std.testing.expectEqual(@as(u8, 0x91), smbus_piix4.sha256[0]);
    try std.testing.expectEqual(@as(u8, 0xe5), smbus_piix4.sha256[31]);
}
