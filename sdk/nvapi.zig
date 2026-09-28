const std = @import("std");
const win32 = @import("win32.zig");

pub const id_initialize: u32 = 0x0150E828;
pub const id_unload: u32 = 0xD22BDD7E;
pub const id_enum_physical_gpus: u32 = 0xE5AC921F;
pub const id_get_pci_identifiers: u32 = 0x2DDFB66E;
pub const id_get_full_name: u32 = 0xCEEE8E9F;
pub const id_i2c_write_ex: u32 = 0x283AC65A;
pub const id_i2c_read_ex: u32 = 0x4D7B0709;

pub const max_gpus = 64;
pub const gpu_port: u8 = 1;
pub const i2c_info_version: u32 = @sizeOf(I2cInfoV3) | (3 << 16);
// NV_I2C_SPEED values: the default keeps the bus at its current speed.
pub const i2c_speed_default: u32 = 0;
pub const i2c_speed_400khz: u32 = 6;

pub const GpuHandle = *anyopaque;

pub const I2cInfoV3 = extern struct {
    version: u32 = i2c_info_version,
    display_mask: u32 = 0,
    is_ddc_port: u8 = 0,
    i2c_dev_address: u8,
    reg_address: ?[*]u8 = null,
    reg_address_size: u32 = 0,
    data: ?[*]u8,
    size: u32,
    speed: u32 = 0xFFFF,
    speed_khz: u32 = 0,
    port_id: u8 = gpu_port,
    is_port_id_set: u32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(I2cInfoV3) == 64);
    std.debug.assert(@offsetOf(I2cInfoV3, "display_mask") == 4);
    std.debug.assert(@offsetOf(I2cInfoV3, "is_ddc_port") == 8);
    std.debug.assert(@offsetOf(I2cInfoV3, "i2c_dev_address") == 9);
    std.debug.assert(@offsetOf(I2cInfoV3, "reg_address") == 16);
    std.debug.assert(@offsetOf(I2cInfoV3, "reg_address_size") == 24);
    std.debug.assert(@offsetOf(I2cInfoV3, "data") == 32);
    std.debug.assert(@offsetOf(I2cInfoV3, "size") == 40);
    std.debug.assert(@offsetOf(I2cInfoV3, "speed") == 44);
    std.debug.assert(@offsetOf(I2cInfoV3, "speed_khz") == 48);
    std.debug.assert(@offsetOf(I2cInfoV3, "port_id") == 52);
    std.debug.assert(@offsetOf(I2cInfoV3, "is_port_id_set") == 56);
    std.debug.assert(i2c_info_version == 0x00030040);
}

pub fn wireAddress(address7: u7) u8 {
    return @as(u8, address7) << 1;
}

pub const PciIds = struct {
    device_id: u32,
    subsystem_id: u32,
    revision: u32,

    pub fn vendor(self: PciIds) u16 {
        return @truncate(self.device_id);
    }

    pub fn device(self: PciIds) u16 {
        return @truncate(self.device_id >> 16);
    }

    pub fn subvendor(self: PciIds) u16 {
        return @truncate(self.subsystem_id);
    }

    pub fn subdevice(self: PciIds) u16 {
        return @truncate(self.subsystem_id >> 16);
    }
};

const QueryFn = *const fn (id: u32) callconv(.c) ?*const anyopaque;
const StatusFn = *const fn () callconv(.c) i32;
const EnumFn = *const fn (handles: *[max_gpus]?GpuHandle, count: *u32) callconv(.c) i32;
const PciFn = *const fn (gpu: GpuHandle, device_id: *u32, subsystem_id: *u32, revision: *u32, ext_device_id: *u32) callconv(.c) i32;
const NameFn = *const fn (gpu: GpuHandle, name: *[64]u8) callconv(.c) i32;
const I2cFn = *const fn (gpu: GpuHandle, info: *I2cInfoV3, extra: *[2]u32) callconv(.c) i32;

pub const LoadError = error{ NotInstalled, MissingFunction, InitializeFailed, BusLockUnavailable };

pub const Nvapi = struct {
    module: win32.HMODULE,
    unload: ?StatusFn,
    enum_gpus: EnumFn,
    get_pci: PciFn,
    get_name: ?NameFn,
    i2c_write: I2cFn,
    i2c_read: I2cFn,
    bus_lock: ?win32.HANDLE,
    last_status: i32 = 0,
    speed: u32 = i2c_speed_default,

    pub fn load() LoadError!Nvapi {
        const bus_lock = win32.CreateMutexW(null, win32.FALSE, win32.L("Local\\rgbctrl.nvapi.i2c")) orelse return error.BusLockUnavailable;
        errdefer _ = win32.CloseHandle(bus_lock);
        const module = win32.LoadLibraryExW(win32.L("nvapi64.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse return error.NotInstalled;
        errdefer _ = win32.FreeLibrary(module);
        const query_address = win32.GetProcAddress(module, "nvapi_QueryInterface") orelse return error.MissingFunction;
        const query: QueryFn = @ptrCast(query_address);
        const initialize: StatusFn = @ptrCast(query(id_initialize) orelse return error.MissingFunction);
        if (initialize() != 0) return error.InitializeFailed;
        return .{
            .module = module,
            .unload = if (query(id_unload)) |address| @ptrCast(address) else null,
            .enum_gpus = @ptrCast(query(id_enum_physical_gpus) orelse return error.MissingFunction),
            .get_pci = @ptrCast(query(id_get_pci_identifiers) orelse return error.MissingFunction),
            .get_name = if (query(id_get_full_name)) |address| @ptrCast(address) else null,
            .i2c_write = @ptrCast(query(id_i2c_write_ex) orelse return error.MissingFunction),
            .i2c_read = @ptrCast(query(id_i2c_read_ex) orelse return error.MissingFunction),
            .bus_lock = bus_lock,
        };
    }

    pub fn deinit(self: *Nvapi) void {
        if (self.unload) |unload| _ = unload();
        if (self.bus_lock) |mutex| _ = win32.CloseHandle(mutex);
        _ = win32.FreeLibrary(self.module);
        self.* = undefined;
    }

    pub fn gpus(self: *Nvapi, out: *[max_gpus]?GpuHandle) usize {
        var count: u32 = 0;
        @memset(out, null);
        if (self.enum_gpus(out, &count) != 0) return 0;
        return @min(count, max_gpus);
    }

    pub fn pciIds(self: *Nvapi, gpu: GpuHandle) ?PciIds {
        var device_id: u32 = 0;
        var subsystem_id: u32 = 0;
        var revision: u32 = 0;
        var ext_device_id: u32 = 0;
        if (self.get_pci(gpu, &device_id, &subsystem_id, &revision, &ext_device_id) != 0) return null;
        return .{ .device_id = device_id, .subsystem_id = subsystem_id, .revision = revision };
    }

    pub fn fullName(self: *Nvapi, gpu: GpuHandle, buffer: *[64]u8) []const u8 {
        @memset(buffer, 0);
        const get_name = self.get_name orelse return "";
        if (get_name(gpu, buffer) != 0) return "";
        return std.mem.sliceTo(buffer, 0);
    }

    pub fn write(self: *Nvapi, gpu: GpuHandle, address7: u7, data: []const u8) bool {
        if (!self.lock()) return false;
        defer self.unlock();
        return self.writeLocked(gpu, address7, data);
    }

    pub fn writeThenRead(self: *Nvapi, gpu: GpuHandle, address7: u7, request: []const u8, response: []u8) bool {
        if (!self.lock()) return false;
        defer self.unlock();
        if (!self.writeLocked(gpu, address7, request)) return false;
        var info = I2cInfoV3{ .i2c_dev_address = wireAddress(address7), .data = response.ptr, .size = @intCast(response.len), .speed_khz = self.speed };
        var extra = [2]u32{ 0, 0 };
        self.last_status = self.i2c_read(gpu, &info, &extra);
        return self.last_status == 0;
    }

    fn writeLocked(self: *Nvapi, gpu: GpuHandle, address7: u7, data: []const u8) bool {
        var copy: [256]u8 = undefined;
        if (data.len > copy.len) return false;
        @memcpy(copy[0..data.len], data);
        var info = I2cInfoV3{ .i2c_dev_address = wireAddress(address7), .data = &copy, .size = @intCast(data.len), .speed_khz = self.speed };
        var extra = [2]u32{ 0, 0 };
        self.last_status = self.i2c_write(gpu, &info, &extra);
        return self.last_status == 0;
    }

    fn lock(self: *Nvapi) bool {
        const handle = self.bus_lock orelse return false;
        const result = win32.WaitForSingleObject(handle, 1000);
        return result == win32.WAIT_OBJECT_0 or result == win32.WAIT_ABANDONED;
    }

    fn unlock(self: *Nvapi) void {
        if (self.bus_lock) |handle| _ = win32.ReleaseMutex(handle);
    }
};

test "wireAddress shifts the 7-bit address into the NVAPI address byte" {
    try std.testing.expectEqual(@as(u8, 0xE2), wireAddress(0x71));
    try std.testing.expectEqual(@as(u8, 0xEA), wireAddress(0x75));
    try std.testing.expectEqual(@as(u8, 0xC2), wireAddress(0x61));
}

test "PciIds splits the NVAPI device and subsystem words" {
    const ids = PciIds{ .device_id = 0x2C0210DE, .subsystem_id = 0x418C1458, .revision = 0 };
    try std.testing.expectEqual(@as(u16, 0x10DE), ids.vendor());
    try std.testing.expectEqual(@as(u16, 0x2C02), ids.device());
    try std.testing.expectEqual(@as(u16, 0x1458), ids.subvendor());
    try std.testing.expectEqual(@as(u16, 0x418C), ids.subdevice());
}
