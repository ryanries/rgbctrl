const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const abi = sdk.abi;
const win32 = sdk.win32;

comptime {
    if (!builtin.is_test) _ = @import("rt");
}

pub const panic = sdk.panic;

const pdh_success: u32 = 0;
const sensor_cpu_load = "cpu.load";
const sensor_cpu_frequency = "cpu.freq";
const sensor_memory_load = "mem.load";

const SystemTimes = struct {
    idle: u64,
    kernel: u64,
    user: u64,
};

const FrequencyMode = enum {
    actual,
    fallback,
};

const CounterRead = union(enum) {
    value: f64,
    status: u32,
};

fn computeCpuLoad(previous: ?SystemTimes, current: SystemTimes) ?f64 {
    const baseline = previous orelse return null;
    const idle_delta = current.idle -| baseline.idle;
    const kernel_delta = current.kernel -| baseline.kernel;
    const user_delta = current.user -| baseline.user;
    const total_delta = kernel_delta +| user_delta;
    if (total_delta == 0) return 0;
    const busy_delta = total_delta -| idle_delta;
    const load = @as(f64, @floatFromInt(busy_delta)) * 100.0 / @as(f64, @floatFromInt(total_delta));
    return clampPercent(load);
}

fn computeFallbackFrequency(base_frequency_mhz: f64, processor_performance_percent: f64) f64 {
    return clampFrequency(base_frequency_mhz * processor_performance_percent / 100.0);
}

fn clampPercent(value: f64) f64 {
    if (!(value == value) or value <= 0) return 0;
    if (value >= 100) return 100;
    return value;
}

fn clampFrequency(value: f64) f64 {
    if (!(value == value) or value <= 0) return 0;
    if (value >= 65535) return 65535;
    return value;
}

const Instance = struct {
    host: sdk.HostApi,
    cpu_times: ?SystemTimes = null,
    cpu_load_disabled: bool = false,
    frequency_query: ?*anyopaque = null,
    actual_frequency_counter: ?*anyopaque = null,
    base_frequency_counter: ?*anyopaque = null,
    performance_counter: ?*anyopaque = null,
    frequency_mode: FrequencyMode = .actual,
    frequency_has_sample: bool = false,
    frequency_disabled: bool = false,
    memory_load_disabled: bool = false,

    fn warnSensorFailure(self: *Instance, sensor_name: []const u8, status: u32) void {
        self.host.warn("{s} unavailable; status 0x{x:0>8}", .{ sensor_name, status });
    }

    fn disableCpuLoad(self: *Instance, status: u32) void {
        if (!self.cpu_load_disabled) self.warnSensorFailure(sensor_cpu_load, status);
        self.cpu_load_disabled = true;
    }

    fn disableFrequency(self: *Instance, status: u32) void {
        if (!self.frequency_disabled) self.warnSensorFailure(sensor_cpu_frequency, status);
        self.frequency_disabled = true;
        self.closeFrequencyQuery();
    }

    fn disableMemoryLoad(self: *Instance, status: u32) void {
        if (!self.memory_load_disabled) self.warnSensorFailure(sensor_memory_load, status);
        self.memory_load_disabled = true;
    }

    fn closeFrequencyQuery(self: *Instance) void {
        if (self.frequency_query) |query| _ = win32.PdhCloseQuery(query);
        self.frequency_query = null;
        self.actual_frequency_counter = null;
        self.base_frequency_counter = null;
        self.performance_counter = null;
        self.frequency_has_sample = false;
    }

    fn openFrequencyQuery(self: *Instance) void {
        var query: ?*anyopaque = null;
        var status = win32.PdhOpenQueryW(null, 0, &query);
        if (status != pdh_success) {
            self.disableFrequency(status);
            return;
        }
        self.frequency_query = query;
        var actual_counter: ?*anyopaque = null;
        status = win32.PdhAddEnglishCounterW(query.?, win32.L("\\Processor Information(_Total)\\Actual Frequency"), 0, &actual_counter);
        if (status == pdh_success) {
            self.actual_frequency_counter = actual_counter;
            self.frequency_mode = .actual;
            return;
        }
        var base_counter: ?*anyopaque = null;
        const base_status = win32.PdhAddEnglishCounterW(query.?, win32.L("\\Processor Information(_Total)\\Processor Frequency"), 0, &base_counter);
        var performance_counter: ?*anyopaque = null;
        const performance_status = win32.PdhAddEnglishCounterW(query.?, win32.L("\\Processor Information(_Total)\\% Processor Performance"), 0, &performance_counter);
        if (base_status == pdh_success and performance_status == pdh_success) {
            self.base_frequency_counter = base_counter;
            self.performance_counter = performance_counter;
            self.frequency_mode = .fallback;
            return;
        }
        self.disableFrequency(if (base_status != pdh_success) base_status else performance_status);
    }

    fn readSystemTimes(self: *Instance) ?SystemTimes {
        var idle: win32.FILETIME = .{};
        var kernel: win32.FILETIME = .{};
        var user: win32.FILETIME = .{};
        if (win32.GetSystemTimes(&idle, &kernel, &user) == win32.FALSE) {
            self.disableCpuLoad(win32.GetLastError());
            return null;
        }
        return .{ .idle = idle.toU64(), .kernel = kernel.toU64(), .user = user.toU64() };
    }

    fn tickCpuLoad(self: *Instance) void {
        if (self.cpu_load_disabled) return;
        const current = self.readSystemTimes() orelse return;
        if (computeCpuLoad(self.cpu_times, current)) |load| self.host.setSensor(sensor_cpu_load, load);
        self.cpu_times = current;
    }

    fn formattedCounterValue(counter: *anyopaque) CounterRead {
        var value: win32.PDH_FMT_COUNTERVALUE = .{};
        const status = win32.PdhGetFormattedCounterValue(counter, win32.PDH_FMT_DOUBLE, null, &value);
        if (status != pdh_success) return .{ .status = status };
        if (value.CStatus != pdh_success) return .{ .status = value.CStatus };
        return .{ .value = value.doubleValue };
    }

    fn tickFrequency(self: *Instance) void {
        if (self.frequency_disabled) return;
        const query = self.frequency_query orelse return;
        const status = win32.PdhCollectQueryData(query);
        if (status != pdh_success) {
            self.disableFrequency(status);
            return;
        }
        if (!self.frequency_has_sample) {
            self.frequency_has_sample = true;
            return;
        }
        const frequency = switch (self.frequency_mode) {
            .actual => switch (formattedCounterValue(self.actual_frequency_counter.?)) {
                .value => |value| clampFrequency(value),
                .status => |failure_status| {
                    self.disableFrequency(failure_status);
                    return;
                },
            },
            .fallback => blk: {
                const base = switch (formattedCounterValue(self.base_frequency_counter.?)) {
                    .value => |value| value,
                    .status => |failure_status| {
                        self.disableFrequency(failure_status);
                        return;
                    },
                };
                const performance = switch (formattedCounterValue(self.performance_counter.?)) {
                    .value => |value| value,
                    .status => |failure_status| {
                        self.disableFrequency(failure_status);
                        return;
                    },
                };
                break :blk computeFallbackFrequency(base, performance);
            },
        };
        self.host.setSensor(sensor_cpu_frequency, frequency);
    }

    fn tickMemoryLoad(self: *Instance) void {
        if (self.memory_load_disabled) return;
        var status: win32.MEMORYSTATUSEX = .{};
        if (win32.GlobalMemoryStatusEx(&status) == win32.FALSE) {
            self.disableMemoryLoad(win32.GetLastError());
            return;
        }
        self.host.setSensor(sensor_memory_load, clampPercent(@floatFromInt(status.dwMemoryLoad)));
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
    self.openFrequencyQuery();
    instance_out.* = self;
    return abi.status_ok;
}

fn close(pointer: ?*anyopaque, reason: u32) callconv(.c) void {
    _ = reason;
    const self = instanceFrom(pointer);
    self.closeFrequencyQuery();
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
    const self = instanceFrom(pointer);
    self.tickCpuLoad();
    self.tickFrequency();
    self.tickMemoryLoad();
    return abi.status_ok;
}

const plugin = abi.Plugin{
    .name = "windows_metrics",
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

test "cpu load stores the first sample as a baseline" {
    try std.testing.expectEqual(@as(?f64, null), computeCpuLoad(null, .{ .idle = 10, .kernel = 20, .user = 30 }));
}

test "cpu load returns zero when the total delta is zero" {
    const previous = SystemTimes{ .idle = 10, .kernel = 20, .user = 30 };
    const current = SystemTimes{ .idle = 10, .kernel = 20, .user = 30 };
    try std.testing.expectEqual(@as(f64, 0), computeCpuLoad(previous, current).?);
}

test "cpu load subtracts idle time from kernel plus user deltas" {
    const previous = SystemTimes{ .idle = 100, .kernel = 500, .user = 1000 };
    const current = SystemTimes{ .idle = 150, .kernel = 700, .user = 1100 };
    try std.testing.expectApproxEqAbs(@as(f64, 83.33333333333333), computeCpuLoad(previous, current).?, 0.000001);
}

test "percent values clamp outside the sensor range" {
    try std.testing.expectEqual(@as(f64, 0), clampPercent(-1));
    try std.testing.expectEqual(@as(f64, 0), clampPercent(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 100), clampPercent(120));
}

test "fallback frequency multiplies processor frequency by processor performance" {
    try std.testing.expectEqual(@as(f64, 3200), computeFallbackFrequency(4000, 80));
    try std.testing.expectEqual(@as(f64, 5000), computeFallbackFrequency(4000, 125));
}

test "frequency values clamp outside the published range" {
    try std.testing.expectEqual(@as(f64, 0), clampFrequency(-1));
    try std.testing.expectEqual(@as(f64, 0), clampFrequency(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 65535), clampFrequency(100000));
}
