const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const abi = sdk.abi;
const win32 = sdk.win32;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const nvml_success: i32 = 0;
const nvml_error_not_supported: i32 = 3;
const temperature_gpu: u32 = 0;
const clock_graphics: u32 = 0;
const clock_memory: u32 = 2;
const max_fans: u32 = 8;

const Memory = extern struct { total: u64, free: u64, used: u64 };
const Utilization = extern struct { gpu: u32, memory: u32 };
const FanSpeedInfo = extern struct { version: u32, fan: u32, speed: u32 };
// NVML_STRUCT_VERSION(FanSpeedInfo, 1): the struct size with the version in the top byte.
const fan_speed_info_v1: u32 = @sizeOf(FanSpeedInfo) | (1 << 24);

const NvmlDevice = *anyopaque;
const StatusFn = *const fn () callconv(.c) i32;
const HandleFn = *const fn (index: u32, device: *?NvmlDevice) callconv(.c) i32;
const NameFn = *const fn (device: NvmlDevice, name: [*]u8, length: u32) callconv(.c) i32;
const ValueFn = *const fn (device: NvmlDevice, value: *u32) callconv(.c) i32;
const KindValueFn = *const fn (device: NvmlDevice, kind: u32, value: *u32) callconv(.c) i32;
const UtilizationFn = *const fn (device: NvmlDevice, utilization: *Utilization) callconv(.c) i32;
const MemoryFn = *const fn (device: NvmlDevice, memory: *Memory) callconv(.c) i32;
const FanRpmFn = *const fn (device: NvmlDevice, info: *FanSpeedInfo) callconv(.c) i32;

const Sensor = enum { temp, load, power, fan, freq, mem_freq, mem_load };
const sensor_names = [_][]const u8{ "gpu.temp", "gpu.load", "gpu.power", "gpu.fan", "gpu.freq", "gpu.mem.freq", "gpu.mem.load" };

const Api = struct {
    shutdown: StatusFn,
    temperature: ?KindValueFn,
    utilization: ?UtilizationFn,
    power: ?ValueFn,
    clock: ?KindValueFn,
    memory: ?MemoryFn,
    fan_rpm: ?FanRpmFn,
};

fn symbol(comptime T: type, module: win32.HMODULE, name: [*:0]const u8) ?T {
    const address = win32.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}

fn vramLoadPercent(memory: Memory) ?f64 {
    if (memory.total == 0) return null;
    const used = @min(memory.used, memory.total);
    return @as(f64, @floatFromInt(used)) * 100.0 / @as(f64, @floatFromInt(memory.total));
}

const Instance = struct {
    host: sdk.HostApi,
    module: ?win32.HMODULE = null,
    api: ?Api = null,
    device: ?NvmlDevice = null,
    fan_count: u32 = 1,
    failed: [sensor_names.len]bool = @splat(false),

    fn load(self: *Instance) void {
        const module = win32.LoadLibraryExW(win32.L("nvml.dll"), null, win32.LOAD_LIBRARY_SEARCH_SYSTEM32) orelse {
            self.host.info("nvml.dll not found (no NVIDIA driver); GPU sensors are unavailable", .{});
            return;
        };
        const initialize = symbol(StatusFn, module, "nvmlInit_v2");
        const shutdown = symbol(StatusFn, module, "nvmlShutdown");
        const get_handle = symbol(HandleFn, module, "nvmlDeviceGetHandleByIndex_v2");
        if (initialize == null or shutdown == null or get_handle == null) {
            self.host.warn("nvml.dll lacks nvmlInit_v2, nvmlShutdown or nvmlDeviceGetHandleByIndex_v2; GPU sensors are unavailable", .{});
            _ = win32.FreeLibrary(module);
            return;
        }
        const init_status = initialize.?();
        if (init_status != nvml_success) {
            self.host.warn("nvmlInit_v2 failed (NVML error {d}); GPU sensors are unavailable", .{init_status});
            _ = win32.FreeLibrary(module);
            return;
        }
        var device: ?NvmlDevice = null;
        const handle_status = get_handle.?(0, &device);
        if (handle_status != nvml_success or device == null) {
            self.host.info("NVML found no GPU (NVML error {d}); GPU sensors are unavailable", .{handle_status});
            _ = shutdown.?();
            _ = win32.FreeLibrary(module);
            return;
        }
        self.module = module;
        self.device = device;
        self.api = .{
            .shutdown = shutdown.?,
            .temperature = symbol(KindValueFn, module, "nvmlDeviceGetTemperature"),
            .utilization = symbol(UtilizationFn, module, "nvmlDeviceGetUtilizationRates"),
            .power = symbol(ValueFn, module, "nvmlDeviceGetPowerUsage"),
            .clock = symbol(KindValueFn, module, "nvmlDeviceGetClockInfo"),
            .memory = symbol(MemoryFn, module, "nvmlDeviceGetMemoryInfo"),
            .fan_rpm = symbol(FanRpmFn, module, "nvmlDeviceGetFanSpeedRPM"),
        };
        if (symbol(ValueFn, module, "nvmlDeviceGetNumFans")) |get_fan_count| {
            var count: u32 = 0;
            if (get_fan_count(device.?, &count) == nvml_success and count > 0) self.fan_count = @min(count, max_fans);
        }
        if (symbol(NameFn, module, "nvmlDeviceGetName")) |get_name| {
            var name: [96]u8 = @splat(0);
            if (get_name(device.?, &name, name.len) == nvml_success) self.host.debug("reading the sensors of {s} ({d} fans)", .{ std.mem.sliceTo(&name, 0), self.fan_count });
        }
    }

    fn unload(self: *Instance) void {
        if (self.api) |api| _ = api.shutdown();
        if (self.module) |module| _ = win32.FreeLibrary(module);
        self.api = null;
        self.module = null;
        self.device = null;
    }

    fn publish(self: *Instance, sensor: Sensor, status: i32, value: f64) void {
        const index = @intFromEnum(sensor);
        if (status == nvml_success) {
            self.host.setSensor(sensor_names[index], value);
            self.failed[index] = false;
            return;
        }
        if (self.failed[index]) return;
        self.failed[index] = true;
        if (status == nvml_error_not_supported) {
            self.host.info("{s} is not supported by this GPU", .{sensor_names[index]});
        } else {
            self.host.warn("{s} unavailable (NVML error {d})", .{ sensor_names[index], status });
        }
    }

    fn publishFan(self: *Instance, api: Api, device: NvmlDevice) void {
        const get_rpm = api.fan_rpm orelse return;
        var highest: u32 = 0;
        var status: i32 = nvml_error_not_supported;
        var fan: u32 = 0;
        while (fan < self.fan_count) : (fan += 1) {
            var info = FanSpeedInfo{ .version = fan_speed_info_v1, .fan = fan, .speed = 0 };
            const fan_status = get_rpm(device, &info);
            if (fan_status == nvml_success) {
                status = nvml_success;
                highest = @max(highest, info.speed);
            } else if (status != nvml_success) {
                status = fan_status;
            }
        }
        self.publish(.fan, status, @floatFromInt(highest));
    }

    fn sample(self: *Instance) void {
        const api = self.api orelse return;
        const device = self.device orelse return;
        var value: u32 = 0;
        if (api.temperature) |get| {
            const status = get(device, temperature_gpu, &value);
            self.publish(.temp, status, @floatFromInt(value));
        }
        if (api.utilization) |get| {
            var utilization = Utilization{ .gpu = 0, .memory = 0 };
            const status = get(device, &utilization);
            self.publish(.load, status, @floatFromInt(@min(utilization.gpu, 100)));
        }
        if (api.power) |get| {
            const status = get(device, &value);
            self.publish(.power, status, @as(f64, @floatFromInt(value)) / 1000.0);
        }
        self.publishFan(api, device);
        if (api.clock) |get| {
            const graphics_status = get(device, clock_graphics, &value);
            self.publish(.freq, graphics_status, @floatFromInt(value));
            const memory_status = get(device, clock_memory, &value);
            self.publish(.mem_freq, memory_status, @floatFromInt(value));
        }
        if (api.memory) |get| {
            var memory = Memory{ .total = 0, .free = 0, .used = 0 };
            const status = get(device, &memory);
            const percent = vramLoadPercent(memory);
            self.publish(.mem_load, if (status == nvml_success and percent == null) nvml_error_not_supported else status, percent orelse 0);
        }
    }
};

var panic_host: ?*const abi.Host = null;

fn reportPanic(message: []const u8) void {
    const host = panic_host orelse return;
    host.log(host.ctx, @intFromEnum(abi.LogLevel.err), message.ptr, message.len);
}

fn instanceFrom(pointer: ?*anyopaque) *Instance {
    return @ptrCast(@alignCast(pointer.?));
}

fn open(host: *const abi.Host, config: ?*const abi.Json, instance_out: *?*anyopaque) callconv(.c) i32 {
    _ = config;
    panic_host = host;
    sdk.panic.hook = reportPanic;
    const self = std.heap.page_allocator.create(Instance) catch return abi.status_fail;
    self.* = .{ .host = .{ .host = host } };
    self.load();
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    self.unload();
    std.heap.page_allocator.destroy(self);
}

fn deviceCount(pointer: ?*anyopaque) callconv(.c) u32 {
    _ = pointer;
    return 0;
}

fn deviceInfo(pointer: ?*anyopaque, device_index: u32) callconv(.c) ?*const abi.DeviceInfo {
    _ = pointer;
    _ = device_index;
    return null;
}

fn tick(pointer: ?*anyopaque, now_ms: u64) callconv(.c) i32 {
    _ = now_ms;
    instanceFrom(pointer).sample();
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "nvidia_gpu",
    .version = "0.1.0",
    .flags = abi.plugin_sensor_source,
    .tick_interval_ms = 1000,
    .transports = abi.transport_os,
    .open = open,
    .close = close,
    .device_count = deviceCount,
    .device_info = deviceInfo,
    .tick = tick,
};

export fn rgbctrl_plugin_entry(host_abi_version: u32) callconv(.c) ?*const abi.Plugin {
    if (host_abi_version < 1) return null;
    return &plugin;
}

test "NVML structs match the C layouts and the fan speed version word" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Memory));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Utilization));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(FanSpeedInfo));
    try std.testing.expectEqual(@as(u32, 0x0100000C), fan_speed_info_v1);
}

test "VRAM load is the used share of the total and unknown without a total" {
    try std.testing.expectEqual(@as(?f64, 25), vramLoadPercent(.{ .total = 16 << 30, .free = 12 << 30, .used = 4 << 30 }));
    try std.testing.expectEqual(@as(?f64, 100), vramLoadPercent(.{ .total = 8, .free = 0, .used = 9 }));
    try std.testing.expectEqual(@as(?f64, null), vramLoadPercent(.{ .total = 0, .free = 0, .used = 0 }));
}

test "sensor names are the standard gpu names in enum order" {
    try std.testing.expectEqual(@as(usize, @typeInfo(Sensor).@"enum".field_names.len), sensor_names.len);
    try std.testing.expectEqualStrings("gpu.fan", sensor_names[@intFromEnum(Sensor.fan)]);
    try std.testing.expectEqualStrings("gpu.mem.load", sensor_names[@intFromEnum(Sensor.mem_load)]);
}
